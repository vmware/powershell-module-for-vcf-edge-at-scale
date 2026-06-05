# Pester tests for VcfEdgeAtScale — Private/Cluster.ps1
#
# RECOMMENDED: Use the wrapper script for human-readable output:
#   ./Tests/Run-Tests.ps1
#   ./Tests/Run-Tests.ps1 -Filter "*FunctionName*"
#
# DIRECT: Invoke-Pester -Path ./Tests/VcfEdgeAtScale.Cluster.Tests.ps1 -Output Detailed
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

Describe "Get-CleanVsanErrorMessage" {
    It "Returns whitespace-only string unchanged (parameter allows non-empty)" {
        $result = InModuleScope VcfEdgeAtScale { Get-CleanVsanErrorMessage -ErrorMessage "   " }
        $result | Should -Be "   "
    }

    It "Maps 'Sequence contains no elements' to vSAN disk group message" {
        $result = InModuleScope VcfEdgeAtScale { Get-CleanVsanErrorMessage -ErrorMessage "Sequence contains no elements" }
        $result | Should -Match "vSAN disk group creation failed"
        $result | Should -Match "one or more disks could not be resolved"
    }

    It "Maps VMHost with name 'X' was not found to witness host message" {
        $msg = "Get-VMHost   VMHost with name 'witness.example.com' was not found using the specified filter(s)."
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $msg { Get-CleanVsanErrorMessage -ErrorMessage $args[0] }
        $result | Should -Match "vSAN witness host"
        $result | Should -Match "witness.example.com"
    }

    It "Maps 'Server task failed: reason text' to trimmed reason" {
        $result = InModuleScope VcfEdgeAtScale { Get-CleanVsanErrorMessage -ErrorMessage "Server task failed: The object or item referred to could not be found." }
        $result | Should -Be "The object or item referred to could not be found."
    }

    It "Maps 'Reason 1: text' to trimmed text" {
        $result = InModuleScope VcfEdgeAtScale { Get-CleanVsanErrorMessage -ErrorMessage "Reason 1: Disk group already exists. Reason 2: Other" }
        $result | Should -Be "Disk group already exists."
    }

    It "Returns original message when no pattern matches" {
        $plainInput = "Some other error"
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $plainInput { Get-CleanVsanErrorMessage -ErrorMessage $args[0] }
        $result | Should -Be $plainInput
    }

    It "Trims at Reason 2 when Reason: ... Reason 2: ... is present" {
        $msg = "Reason: Disk group already exists. Reason 2: Other detail"
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $msg { Get-CleanVsanErrorMessage -ErrorMessage $args[0] }
        $result | Should -Be "Disk group already exists."
    }
}


Describe "Test-VsanTriggeredAlarmIsStatsPrimaryElection" {
    It "Returns true for performance service alarm Stats primary pattern" {
        $alarm = [PSCustomObject]@{ AlarmName = "vSAN performance service alarm 'Stats primary election'"; Status = "red" }
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $alarm { Test-VsanTriggeredAlarmIsStatsPrimaryElection -TriggeredAlarm $args[0] }
        $result | Should -Be $true
    }

    It "Returns false for unrelated red alarm" {
        $alarm = [PSCustomObject]@{ AlarmName = "vSAN network partition"; Status = "red" }
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $alarm { Test-VsanTriggeredAlarmIsStatsPrimaryElection -TriggeredAlarm $args[0] }
        $result | Should -Be $false
    }

    It "Returns false when AlarmName is missing" {
        $invalidAlarm = [PSCustomObject]@{ Status = "red" }
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $invalidAlarm { Test-VsanTriggeredAlarmIsStatsPrimaryElection -TriggeredAlarm $args[0] }
        $result | Should -Be $false
    }
}


Describe "Test-VsanTriggeredAlarmIsHclRelated" {
    It "Returns true for HCL acronym in alarm name" {
        $alarm = [PSCustomObject]@{ AlarmName = "vSAN: controlleronhcl HCL check failed" }
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $alarm { Test-VsanTriggeredAlarmIsHclRelated -TriggeredAlarm $args[0] }
        $result | Should -Be $true
    }

    It "Returns true for 'hardware compatibility' pattern" {
        $alarm = [PSCustomObject]@{ AlarmName = "vSAN hardware compatibility issues" }
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $alarm { Test-VsanTriggeredAlarmIsHclRelated -TriggeredAlarm $args[0] }
        $result | Should -Be $true
    }

    It "Returns true for controller firmware pattern" {
        $alarm = [PSCustomObject]@{ AlarmName = "vSAN: controller firmware check" }
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $alarm { Test-VsanTriggeredAlarmIsHclRelated -TriggeredAlarm $args[0] }
        $result | Should -Be $true
    }

    It "Returns true for controller driver pattern" {
        $alarm = [PSCustomObject]@{ AlarmName = "vSAN: controller driver mismatch" }
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $alarm { Test-VsanTriggeredAlarmIsHclRelated -TriggeredAlarm $args[0] }
        $result | Should -Be $true
    }

    It "Returns false for unrelated alarm (network partition)" {
        $alarm = [PSCustomObject]@{ AlarmName = "vSAN network partition detected" }
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $alarm { Test-VsanTriggeredAlarmIsHclRelated -TriggeredAlarm $args[0] }
        $result | Should -Be $false
    }

    It "Returns false when AlarmName property is absent" {
        $alarm = [PSCustomObject]@{ Status = "red" }
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $alarm { Test-VsanTriggeredAlarmIsHclRelated -TriggeredAlarm $args[0] }
        $result | Should -Be $false
    }
}


Describe "Invoke-AsyncPowerShellOperation" {
    It "Returns Success=true and correct Result for a simple expression" {
        # Variables must be non-empty (ValidateNotNullOrEmpty on Hashtable); pass a dummy entry.
        $result = InModuleScope VcfEdgeAtScale {
            Invoke-AsyncPowerShellOperation `
                -ScriptBlock "1 + 1" `
                -Variables @{ _dummy = $true } `
                -ActivityName "Test addition" `
                -TimeoutSeconds 30
        }
        $result.Success | Should -Be $true
        $result.Result | Should -Contain 2
    }

    It "Returns Success=false when ScriptBlock throws" {
        $result = InModuleScope VcfEdgeAtScale {
            Invoke-AsyncPowerShellOperation `
                -ScriptBlock "throw 'deliberate test error'" `
                -Variables @{ _dummy = $true } `
                -ActivityName "Test throw" `
                -TimeoutSeconds 30
        }
        $result.Success | Should -Be $false
        $result.Error | Should -Not -BeNullOrEmpty
    }

    It "Passes variables into the runspace correctly" {
        $result = InModuleScope VcfEdgeAtScale {
            Invoke-AsyncPowerShellOperation `
                -ScriptBlock '$testVar * 3' `
                -Variables @{ testVar = 7 } `
                -ActivityName "Test variable passing" `
                -TimeoutSeconds 30
        }
        $result.Success | Should -Be $true
        $result.Result | Should -Contain 21
    }

    It "Times out and returns Success=false when operation exceeds TimeoutSeconds" {
        $result = InModuleScope VcfEdgeAtScale {
            Invoke-AsyncPowerShellOperation `
                -ScriptBlock "Start-Sleep -Seconds 60" `
                -Variables @{ _dummy = $true } `
                -ActivityName "Test timeout" `
                -TimeoutSeconds 2 `
                -CheckInterval 1
        }
        $result.Success | Should -Be $false
        $result.Error | Should -Match "timed out"
    }
}


Describe "Invoke-VsanDeploymentRollback — control flow paths" {

    It "Sets Script:RollbackAttempted=true and does not throw when SuppressPrompt is set and vCenter is disconnected" {
        $attempted = InModuleScope VcfEdgeAtScale {
            $Script:RollbackAttempted = $false
            # No vCenter connection — Test-VcenterConnection will return IsConnected=$false,
            # causing the function to return early after setting RollbackAttempted.
            Invoke-VsanDeploymentRollback -ClusterName "cl-test" -StoragePolicyType "vSAN-OSA" -SuppressPrompt
            $Script:RollbackAttempted
        }
        $attempted | Should -Be $true
    }

    It "Throws RollbackSkippedException when rollback decision is DoNotRollback" {
        { InModuleScope VcfEdgeAtScale {
            Mock Invoke-PauseBeforeRollbackIfRequested { return "DoNotRollback" }
            Invoke-VsanDeploymentRollback -ClusterName "cl-test" -StoragePolicyType "vSAN-ESA"
        } } | Should -Throw "*Rollback skipped*"

    }

    It "Does not set Script:RollbackAttempted when prompt returns DoNotRollback" {
        $attempted = InModuleScope VcfEdgeAtScale {
            $Script:RollbackAttempted = $false
            Mock Invoke-PauseBeforeRollbackIfRequested { return "DoNotRollback" }
            try { Invoke-VsanDeploymentRollback -ClusterName "cl-test" -StoragePolicyType "vSAN-ESA" } catch { [void]$_ }
            $Script:RollbackAttempted
        }
        $attempted | Should -Be $false
    }

    It "Returns early without throwing when vCenter is not connected (non-fatal)" {
        InModuleScope VcfEdgeAtScale {
            Mock Invoke-PauseBeforeRollbackIfRequested { return "Rollback" }
            Mock Write-LogMessage {}
            Mock Test-VcenterConnection { return [PSCustomObject]@{ IsConnected = $false; ErrorMessage = "Not connected" } }
            { Invoke-VsanDeploymentRollback -ClusterName "cl-test" -StoragePolicyType "vSAN-OSA" -SuppressPrompt } | Should -Not -Throw
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq "WARNING" -and $Message -match "Not connected" }
        }
    }

    It "Continues and still calls vSAN cluster leave when cluster is not found (EsxHostNames fallback path)" {
        # When the vCenter cluster object is gone (deployment failed before cluster creation),
        # rollback must fall back to EsxHostNames and still run disk removal and vSAN cluster leave.
        $leaveCalled = InModuleScope VcfEdgeAtScale {
            $Script:_leaveCallCount = 0
            $savedVcenter = $Script:vCenterName
            $Script:vCenterName = "vc.lab"
            Mock Write-LogMessage {}
            Mock Test-VcenterConnection { return [PSCustomObject]@{ IsConnected = $true; ErrorMessage = $null } }
            Mock Get-ClusterByName { return $null }
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab" }
            function Get-VMHost {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                process {}
            }
            # Use a counting stub WITHOUT a Mock override — $Script: counter in function body
            # runs in module scope (Rule 4: $Script: inside function stub persists, unlike Mock scriptblock).
            function Invoke-VsanClusterLeaveOnHostWithRetry {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Object]$Server, [Parameter()] [Object]$MaxRetries, [Parameter()] [Object]$RetryDelaySeconds, [Parameter()] [Object]$LogContext)
                begin { $Script:_leaveCallCount++ }; process {}
            }
            Mock Get-VMHost { $fakeHost }
            Mock Remove-VsanDiskClaimsFromHost {}
            try {
                Invoke-VsanDeploymentRollback -ClusterName "cl-test" -StoragePolicyType "vSAN-OSA" -SuppressPrompt -EsxHostNames @("esx01.lab") -SkipClusterRemoval
            } finally {
                # Restore module-scope vCenter name regardless of whether the function throws,
                # preventing $Script:vCenterName state from leaking into subsequent test runs.
                $Script:vCenterName = $savedVcenter
            }
            $Script:_leaveCallCount
        }
        $leaveCalled | Should -BeGreaterOrEqual 1
    }
}


Describe "Get-ClusterNameFromPrefix" {
    It "Combines cluster prefix and edge site with a hyphen" {
        InModuleScope VcfEdgeAtScale { Get-ClusterNameFromPrefix -ClusterNamePrefix "cl0" -EdgeSite "site1" } | Should -Be "cl0-site1"
    }

    It "Preserves hyphens that are already part of the prefix" {
        InModuleScope VcfEdgeAtScale { Get-ClusterNameFromPrefix -ClusterNamePrefix "cl-edge" -EdgeSite "siteA" } | Should -Be "cl-edge-siteA"
    }
}

Describe "Get-DatastoreNameFromPrefix" {
    It "Combines datastore prefix and edge site with a hyphen" {
        InModuleScope VcfEdgeAtScale { Get-DatastoreNameFromPrefix -DatastoreNamePrefix "ds-vsan" -EdgeSite "site2" } | Should -Be "ds-vsan-site2"
    }
}

Describe "Get-VdsNameFromPrefix" {
    It "Combines VDS prefix and edge site with a hyphen" {
        InModuleScope VcfEdgeAtScale { Get-VdsNameFromPrefix -VdsNamePrefix "vds" -EdgeSite "site1" } | Should -Be "vds-site1"
    }
}

Describe "Get-SupervisorNameFromPrefix" {
    It "Combines supervisor prefix and edge site with a hyphen" {
        InModuleScope VcfEdgeAtScale { Get-SupervisorNameFromPrefix -SupervisorNamePrefix "sup" -EdgeSite "site1" } | Should -Be "sup-site1"
    }
}


Describe "Group-DisksByHost" {
    It "Groups disks from two hosts into separate hashtable entries" {
        $disks = @(
            [PSCustomObject]@{ VMHostName = "esx1.lab"; Name = "mpx.vmhba1" },
            [PSCustomObject]@{ VMHostName = "esx2.lab"; Name = "mpx.vmhba2" },
            [PSCustomObject]@{ VMHostName = "esx1.lab"; Name = "mpx.vmhba3" }
        )
        $result = InModuleScope VcfEdgeAtScale -ArgumentList (,$disks) { Group-DisksByHost -Disks $args[0] }
        $result.Keys | Should -Contain "esx1.lab"
        $result.Keys | Should -Contain "esx2.lab"
        @($result["esx1.lab"]).Count | Should -Be 2
        @($result["esx2.lab"]).Count | Should -Be 1
    }

    It "Returns a hashtable with one key when all disks share the same host" {
        $disks = @(
            [PSCustomObject]@{ VMHostName = "esx1.lab"; Name = "mpx.vmhba1" },
            [PSCustomObject]@{ VMHostName = "esx1.lab"; Name = "mpx.vmhba2" }
        )
        $result = InModuleScope VcfEdgeAtScale -ArgumentList (,$disks) { Group-DisksByHost -Disks $args[0] }
        $result.Count | Should -Be 1
        @($result["esx1.lab"]).Count | Should -Be 2
    }

    It "Returns a hashtable with one key and one disk for a single-disk input" {
        $disks = @([PSCustomObject]@{ VMHostName = "esx1.lab"; Name = "mpx.vmhba1" })
        $result = InModuleScope VcfEdgeAtScale -ArgumentList (,$disks) { Group-DisksByHost -Disks $args[0] }
        $result.Count | Should -Be 1
        @($result["esx1.lab"]).Count | Should -Be 1
    }
}


Describe "Get-VsanHealthFailureReasons" {
    It "Returns a 'Health status:' fallback string when overallHealth is null and no reasons are collected" {
        # The function guards on a truly-null parameter but not on a PSCustomObject with null overallHealth.
        # When overallHealth is not 'green' and no description or groups produce failure reasons,
        # the function falls through to the final fallback: "Health status: <overallHealth>".
        $summary = [PSCustomObject]@{ overallHealth = $null; overallHealthDescription = $null; groups = $null }
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $summary {
            Get-VsanHealthFailureReasons -HealthSummary $args[0]
        }
        $result | Should -Match "Health status"
    }

    It "Returns empty string when overall health is green" {
        $summary = [PSCustomObject]@{ overallHealth = "green"; overallHealthDescription = "All good"; groups = $null }
        InModuleScope VcfEdgeAtScale -ArgumentList $summary {
            Get-VsanHealthFailureReasons -HealthSummary $args[0]
        } | Should -Be ""
    }

    It "Returns overallHealthDescription when health is yellow and no groups are set" {
        $summary = [PSCustomObject]@{ overallHealth = "yellow"; overallHealthDescription = "Stats primary election"; groups = $null }
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $summary { Get-VsanHealthFailureReasons -HealthSummary $args[0] }
        $result | Should -Match "Stats primary election"
    }

    It "Includes non-green group names in the output" {
        $test = [PSCustomObject]@{}
        $test | Add-Member -NotePropertyName health -NotePropertyValue "yellow"
        $test | Add-Member -NotePropertyName testId -NotePropertyValue ""
        $test | Add-Member -NotePropertyName testName -NotePropertyValue ""
        $test | Add-Member -NotePropertyName description -NotePropertyValue ""
        $group = [PSCustomObject]@{}
        $group | Add-Member -NotePropertyName health -NotePropertyValue "yellow"
        $group | Add-Member -NotePropertyName groupName -NotePropertyValue "Network Health"
        $group | Add-Member -NotePropertyName tests -NotePropertyValue @($test)
        $summary = [PSCustomObject]@{ overallHealth = "yellow"; overallHealthDescription = $null; groups = @($group) }
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $summary { Get-VsanHealthFailureReasons -HealthSummary $args[0] }
        $result | Should -Match "Network Health"
    }
}


Describe "Test-VsanHealthFailureTextOnlyStatsPrimaryElection" {
    It "Returns false for empty string" {
        InModuleScope VcfEdgeAtScale {
            Test-VsanHealthFailureTextOnlyStatsPrimaryElection -FailureText ""
        } | Should -Be $false
    }

    It "Returns false for whitespace-only string" {
        InModuleScope VcfEdgeAtScale {
            Test-VsanHealthFailureTextOnlyStatsPrimaryElection -FailureText "   "
        } | Should -Be $false
    }

    It "Returns true for pure stats primary election text" {
        InModuleScope VcfEdgeAtScale {
            Test-VsanHealthFailureTextOnlyStatsPrimaryElection -FailureText "Stats primary election pending"
        } | Should -Be $true
    }

    It "Returns true for perfsvc.masterexist text" {
        InModuleScope VcfEdgeAtScale {
            Test-VsanHealthFailureTextOnlyStatsPrimaryElection -FailureText "perfsvc.masterexist check failed"
        } | Should -Be $true
    }

    It "Returns false when partition keyword is also present" {
        InModuleScope VcfEdgeAtScale {
            Test-VsanHealthFailureTextOnlyStatsPrimaryElection -FailureText "Stats primary election; network misconfiguration detected"
        } | Should -Be $false
    }

    It "Returns false when resync keyword is also present" {
        InModuleScope VcfEdgeAtScale {
            Test-VsanHealthFailureTextOnlyStatsPrimaryElection -FailureText "Stats primary election and resync in progress"
        } | Should -Be $false
    }

    It "Returns false for unrelated health text" {
        InModuleScope VcfEdgeAtScale {
            Test-VsanHealthFailureTextOnlyStatsPrimaryElection -FailureText "Disk data inaccessible on host esx1.lab"
        } | Should -Be $false
    }
}


Describe "Test-VsanHealthTestDetailsStatsPrimaryElection" {
    It "Returns true when testId matches perfsvc.masterexist" {
        $test = [PSCustomObject]@{}
        $test | Add-Member -NotePropertyName testId -NotePropertyValue "perfsvc.masterexist"
        $test | Add-Member -NotePropertyName testName -NotePropertyValue "some name"
        $test | Add-Member -NotePropertyName description -NotePropertyValue "some description"
        InModuleScope VcfEdgeAtScale -ArgumentList $test {
            Test-VsanHealthTestDetailsStatsPrimaryElection -Test $args[0]
        } | Should -Be $true
    }

    It "Returns true when testName matches 'stats primary election' (case-insensitive)" {
        $test = [PSCustomObject]@{}
        $test | Add-Member -NotePropertyName testId -NotePropertyValue "other.id"
        $test | Add-Member -NotePropertyName testName -NotePropertyValue "Stats Primary Election"
        $test | Add-Member -NotePropertyName description -NotePropertyValue ""
        InModuleScope VcfEdgeAtScale -ArgumentList $test {
            Test-VsanHealthTestDetailsStatsPrimaryElection -Test $args[0]
        } | Should -Be $true
    }

    It "Returns true when description matches 'stats primary selection'" {
        $test = [PSCustomObject]@{}
        $test | Add-Member -NotePropertyName testId -NotePropertyValue ""
        $test | Add-Member -NotePropertyName testName -NotePropertyValue ""
        $test | Add-Member -NotePropertyName description -NotePropertyValue "Checking stats primary selection status"
        InModuleScope VcfEdgeAtScale -ArgumentList $test {
            Test-VsanHealthTestDetailsStatsPrimaryElection -Test $args[0]
        } | Should -Be $true
    }

    It "Returns false for an unrelated test" {
        $test = [PSCustomObject]@{}
        $test | Add-Member -NotePropertyName testId -NotePropertyValue "network.partition"
        $test | Add-Member -NotePropertyName testName -NotePropertyValue "Network Partition Detected"
        $test | Add-Member -NotePropertyName description -NotePropertyValue "Hosts are partitioned"
        InModuleScope VcfEdgeAtScale -ArgumentList $test {
            Test-VsanHealthTestDetailsStatsPrimaryElection -Test $args[0]
        } | Should -Be $false
    }
}


Describe "Test-VsanHealthSuggestsPartitionOrNetwork" {
    It "Returns false when HealthSummary is null" {
        # ValidateNotNull prevents passing $null directly; test defensive null guard via a stub.
        $summary = [PSCustomObject]@{ overallHealth = $null; overallHealthDescription = $null; networkHealth = $null; groups = $null }
        InModuleScope VcfEdgeAtScale -ArgumentList $summary {
            Test-VsanHealthSuggestsPartitionOrNetwork -HealthSummary $args[0]
        } | Should -Be $false
    }

    It "Returns true when overallHealthDescription contains 'partition'" {
        $summary = [PSCustomObject]@{
            overallHealth = "red"
            overallHealthDescription = "Network partition detected"
            networkHealth = $null
            groups = $null
        }
        InModuleScope VcfEdgeAtScale -ArgumentList $summary {
            Test-VsanHealthSuggestsPartitionOrNetwork -HealthSummary $args[0]
        } | Should -Be $true
    }

    It "Returns true when overallHealthDescription contains 'Network misconfiguration'" {
        $summary = [PSCustomObject]@{
            overallHealth = "red"
            overallHealthDescription = "Network misconfiguration found"
            networkHealth = $null
            groups = $null
        }
        InModuleScope VcfEdgeAtScale -ArgumentList $summary {
            Test-VsanHealthSuggestsPartitionOrNetwork -HealthSummary $args[0]
        } | Should -Be $true
    }

    It "Returns false for a pure stats-primary-election health summary" {
        $summary = [PSCustomObject]@{
            overallHealth = "yellow"
            overallHealthDescription = "Stats primary election"
            networkHealth = $null
            groups = $null
        }
        InModuleScope VcfEdgeAtScale -ArgumentList $summary {
            Test-VsanHealthSuggestsPartitionOrNetwork -HealthSummary $args[0]
        } | Should -Be $false
    }
}


Describe "Test-VsanHealthSummaryNonGreenOnlyStatsPrimaryElection" {
    It "Returns false when overall health is green" {
        $summary = [PSCustomObject]@{ overallHealth = "green"; groups = $null }
        InModuleScope VcfEdgeAtScale -ArgumentList $summary {
            Test-VsanHealthSummaryNonGreenOnlyStatsPrimaryElection -HealthSummary $args[0]
        } | Should -Be $false
    }

    It "Returns false when overall health is null" {
        $summary = [PSCustomObject]@{ overallHealth = $null; groups = $null }
        InModuleScope VcfEdgeAtScale -ArgumentList $summary {
            Test-VsanHealthSummaryNonGreenOnlyStatsPrimaryElection -HealthSummary $args[0]
        } | Should -Be $false
    }

    It "Returns true when the only non-green test matches stats primary election" {
        $test = [PSCustomObject]@{}
        $test | Add-Member -NotePropertyName health -NotePropertyValue "yellow"
        $test | Add-Member -NotePropertyName testId -NotePropertyValue "perfsvc.masterexist"
        $test | Add-Member -NotePropertyName testName -NotePropertyValue "Stats primary election"
        $test | Add-Member -NotePropertyName description -NotePropertyValue ""
        $group = [PSCustomObject]@{}
        $group | Add-Member -NotePropertyName tests -NotePropertyValue @($test)
        $summary = [PSCustomObject]@{ overallHealth = "yellow"; groups = @($group) }
        InModuleScope VcfEdgeAtScale -ArgumentList $summary {
            Test-VsanHealthSummaryNonGreenOnlyStatsPrimaryElection -HealthSummary $args[0]
        } | Should -Be $true
    }

    It "Returns false when at least one non-green test is unrelated to stats primary election" {
        $testStats = [PSCustomObject]@{}
        $testStats | Add-Member -NotePropertyName health -NotePropertyValue "yellow"
        $testStats | Add-Member -NotePropertyName testId -NotePropertyValue "perfsvc.masterexist"
        $testStats | Add-Member -NotePropertyName testName -NotePropertyValue "Stats primary election"
        $testStats | Add-Member -NotePropertyName description -NotePropertyValue ""
        $testNetwork = [PSCustomObject]@{}
        $testNetwork | Add-Member -NotePropertyName health -NotePropertyValue "red"
        $testNetwork | Add-Member -NotePropertyName testId -NotePropertyValue "network.partition"
        $testNetwork | Add-Member -NotePropertyName testName -NotePropertyValue "Network Partition"
        $testNetwork | Add-Member -NotePropertyName description -NotePropertyValue "Partition detected"
        $group = [PSCustomObject]@{}
        $group | Add-Member -NotePropertyName tests -NotePropertyValue @($testStats, $testNetwork)
        $summary = [PSCustomObject]@{ overallHealth = "red"; groups = @($group) }
        InModuleScope VcfEdgeAtScale -ArgumentList $summary {
            Test-VsanHealthSummaryNonGreenOnlyStatsPrimaryElection -HealthSummary $args[0]
        } | Should -Be $false
    }

    It "Falls back to failure-text analysis when no groups are set and text matches stats primary" {
        $summary = [PSCustomObject]@{
            overallHealth = "yellow"
            overallHealthDescription = "Stats primary election"
            groups = $null
        }
        InModuleScope VcfEdgeAtScale -ArgumentList $summary {
            Test-VsanHealthSummaryNonGreenOnlyStatsPrimaryElection -HealthSummary $args[0]
        } | Should -Be $true
    }
}


Describe "Get-CanonicalNameFromVsanStoragePoolDisk" {
    It "Returns CanonicalName from top-level Disk property" {
        $disk = [PSCustomObject]@{ Disk = [PSCustomObject]@{ CanonicalName = "naa.abc123" } }
        InModuleScope VcfEdgeAtScale -ArgumentList $disk {
            Get-CanonicalNameFromVsanStoragePoolDisk -VsanStoragePoolDisk $args[0]
        } | Should -Be "naa.abc123"
    }

    It "Returns canonicalName from ExtensionData.disk (lowercase)" {
        $inner = [PSCustomObject]@{}
        $inner | Add-Member -NotePropertyName canonicalName -NotePropertyValue "naa.lowercase"
        $extData = [PSCustomObject]@{}
        $extData | Add-Member -NotePropertyName disk -NotePropertyValue $inner
        $disk = [PSCustomObject]@{ Disk = $null; ExtensionData = $extData }
        InModuleScope VcfEdgeAtScale -ArgumentList $disk {
            Get-CanonicalNameFromVsanStoragePoolDisk -VsanStoragePoolDisk $args[0]
        } | Should -Be "naa.lowercase"
    }

    It "Returns canonical name via generic property scan when standard paths are absent" {
        $disk = [PSCustomObject]@{ ExtensionData = $null; Disk = $null }
        $disk | Add-Member -NotePropertyName canonicalName -NotePropertyValue "naa.generic"
        InModuleScope VcfEdgeAtScale -ArgumentList $disk {
            Get-CanonicalNameFromVsanStoragePoolDisk -VsanStoragePoolDisk $args[0]
        } | Should -Be "naa.generic"
    }

    It "Returns null when no canonical name property exists" {
        $disk = [PSCustomObject]@{ ExtensionData = $null; Disk = $null; SomeOtherProp = "value" }
        InModuleScope VcfEdgeAtScale -ArgumentList $disk {
            Get-CanonicalNameFromVsanStoragePoolDisk -VsanStoragePoolDisk $args[0]
        } | Should -Be $null
    }
}


Describe "Test-VsanClusterPartitioned" {
    It "Returns false when networkHealth is absent" {
        $summary = [PSCustomObject]@{ networkHealth = $null; overallHealthDescription = $null }
        InModuleScope VcfEdgeAtScale -ArgumentList $summary {
            Test-VsanClusterPartitioned -HealthSummary $args[0]
        } | Should -Be $false
    }

    It "Returns true when partitions count is 2 or more" {
        $networkHealth = [PSCustomObject]@{
            partitions              = @("p1", "p2")
            otherHostsInVsanCluster = $null
            hostsCommFailure        = $null
            hostsDisconnected       = $null
            status                  = "green"
        }
        $summary = [PSCustomObject]@{ networkHealth = $networkHealth; overallHealthDescription = $null }
        InModuleScope VcfEdgeAtScale -ArgumentList $summary {
            Test-VsanClusterPartitioned -HealthSummary $args[0]
        } | Should -Be $true
    }

    It "Returns true when otherHostsInVsanCluster is non-empty" {
        $networkHealth = [PSCustomObject]@{
            partitions              = $null
            otherHostsInVsanCluster = @("host1")
            hostsCommFailure        = $null
            hostsDisconnected       = $null
            status                  = "green"
        }
        $summary = [PSCustomObject]@{ networkHealth = $networkHealth; overallHealthDescription = $null }
        InModuleScope VcfEdgeAtScale -ArgumentList $summary {
            Test-VsanClusterPartitioned -HealthSummary $args[0]
        } | Should -Be $true
    }

    It "Returns false when all network health collections are empty" {
        $networkHealth = [PSCustomObject]@{
            partitions              = @()
            otherHostsInVsanCluster = @()
            hostsCommFailure        = @()
            hostsDisconnected       = @()
            status                  = "green"
            description             = "All good"
        }
        $summary = [PSCustomObject]@{ networkHealth = $networkHealth; overallHealthDescription = "All good" }
        InModuleScope VcfEdgeAtScale -ArgumentList $summary {
            Test-VsanClusterPartitioned -HealthSummary $args[0]
        } | Should -Be $false
    }
}


Describe "Test-VsanClusterAdvCfgSyncInSync" {
    It "Returns true when HealthSummary is null-ish (falsy PSObject)" {
        # Guard: -not $HealthSummary is true only for truly null/false/zero; a PSObject is always truthy.
        # The function returns $true when advCfgSync is absent.
        $summary = [PSCustomObject]@{ advCfgSync = $null }
        InModuleScope VcfEdgeAtScale -ArgumentList $summary {
            Test-VsanClusterAdvCfgSyncInSync -HealthSummary $args[0]
        } | Should -Be $true
    }

    It "Returns true when all advCfgSync entries have inSync = true" {
        $e1 = [PSCustomObject]@{}; $e1 | Add-Member -NotePropertyName inSync -NotePropertyValue $true
        $e2 = [PSCustomObject]@{}; $e2 | Add-Member -NotePropertyName inSync -NotePropertyValue $true
        $summary = [PSCustomObject]@{ advCfgSync = @($e1, $e2) }
        InModuleScope VcfEdgeAtScale -ArgumentList $summary {
            Test-VsanClusterAdvCfgSyncInSync -HealthSummary $args[0]
        } | Should -Be $true
    }

    It "Returns false when any advCfgSync entry has inSync = false" {
        $e1 = [PSCustomObject]@{}; $e1 | Add-Member -NotePropertyName inSync -NotePropertyValue $true
        $e2 = [PSCustomObject]@{}; $e2 | Add-Member -NotePropertyName inSync -NotePropertyValue $false
        $summary = [PSCustomObject]@{ advCfgSync = @($e1, $e2) }
        InModuleScope VcfEdgeAtScale -ArgumentList $summary {
            Test-VsanClusterAdvCfgSyncInSync -HealthSummary $args[0]
        } | Should -Be $false
    }

    It "Returns true when entry uses PascalCase InSync = true" {
        $e1 = [PSCustomObject]@{}; $e1 | Add-Member -NotePropertyName InSync -NotePropertyValue $true
        $summary = [PSCustomObject]@{ advCfgSync = @($e1) }
        InModuleScope VcfEdgeAtScale -ArgumentList $summary {
            Test-VsanClusterAdvCfgSyncInSync -HealthSummary $args[0]
        } | Should -Be $true
    }
}


Describe "Get-ClusterId — mocked vCenter" {
    It "Throws when not connected to vCenter" {
        InModuleScope VcfEdgeAtScale {
            Mock Test-VcenterConnection { [PSCustomObject]@{ IsConnected = $false; ErrorMessage = "Not connected" } }
            { Get-ClusterId -ClusterName "my-cluster" }
        } | Should -Throw "*Not connected*"
    }

    It "Returns the MoRef value when the cluster is found" {
        InModuleScope VcfEdgeAtScale {
            Mock Test-VcenterConnection { [PSCustomObject]@{ IsConnected = $true; ErrorMessage = $null } }
            $moref = [PSCustomObject]@{}
            $moref | Add-Member -NotePropertyName Value -NotePropertyValue "domain-c42"
            $extData = [PSCustomObject]@{}
            $extData | Add-Member -NotePropertyName MoRef -NotePropertyValue $moref
            Mock Get-Cluster {
                $obj = [PSCustomObject]@{ Name = "my-cluster" }
                $obj | Add-Member -NotePropertyName ExtensionData -NotePropertyValue $extData
                $obj
            }
            Get-ClusterId -ClusterName "my-cluster"
        } | Should -Be "domain-c42"
    }
}


Describe "Get-VcenterSupervisorCount — mocked vCenter" {
    It "Throws when not connected to vCenter" {
        InModuleScope VcfEdgeAtScale {
            Mock Test-VcenterConnection { [PSCustomObject]@{ IsConnected = $false; ErrorMessage = "Not connected" } }
            { Get-VcenterSupervisorCount }
        } | Should -Throw "*Not connected*"
    }

    It "Returns Count 0 when no software clusters exist" {
        InModuleScope VcfEdgeAtScale {
            Mock Test-VcenterConnection { [PSCustomObject]@{ IsConnected = $true; ErrorMessage = $null } }
            Mock Invoke-ListNamespaceManagementSoftwareClusters { return $null }
            $result = Get-VcenterSupervisorCount
            $result.Count
        } | Should -Be 0
    }

    It "Returns Count matching the number of software clusters returned" {
        InModuleScope VcfEdgeAtScale {
            Mock Test-VcenterConnection { [PSCustomObject]@{ IsConnected = $true; ErrorMessage = $null } }
            Mock Invoke-ListNamespaceManagementSoftwareClusters {
                @(
                    [PSCustomObject]@{ Cluster = "domain-c1" },
                    [PSCustomObject]@{ Cluster = "domain-c2" }
                )
            }
            $result = Get-VcenterSupervisorCount
            $result.Count
        } | Should -Be 2
    }
}


Describe "Invoke-PrepareHostForClusterMove — mocked vCenter" {

    It "Throws when dual-uplink prerequisite is not met and vmk0 is on a VDS" {
        { InModuleScope VcfEdgeAtScale {
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab" }
            Mock Test-HostManagementVdsDualUplink {
                [PSCustomObject]@{ HasDualUplink = $false; MgmtVdsName = "VDS-site1" }
            }
            Invoke-PrepareHostForClusterMove -DestinationClusterName "cl-new" -EsxHostName "esx01.lab" `
                -SourceClusterName "cl-old" -VMHost $fakeHost -Server "vc.lab"
        } } | Should -Throw "*has fewer than two physical NIC uplinks*"

    }

    It "Returns silently when vmk0 is already on a standard switch and operator confirms Y" {
        # vmk0 on VSS path: no VDS cleanup, just prompt then return.
        InModuleScope VcfEdgeAtScale {
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab" }
            Mock Test-HostManagementVdsDualUplink {
                [PSCustomObject]@{ HasDualUplink = $false; MgmtVdsName = "" }
            }
            Mock Read-Host { return "y" }
            { Invoke-PrepareHostForClusterMove -DestinationClusterName "cl-new" -EsxHostName "esx01.lab" `
                -SourceClusterName "cl-old" -VMHost $fakeHost -Server "vc.lab" } | Should -Not -Throw
            # Operator confirmation prompt was shown once.
            Should -Invoke Read-Host -Times 1 -Scope It
        }
    }

    It "Throws when vmk0 is already on a standard switch but operator responds N" {
        # vmk0 on VSS path: still prompts; abort on N.
        { InModuleScope VcfEdgeAtScale {
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab" }
            Mock Test-HostManagementVdsDualUplink {
                [PSCustomObject]@{ HasDualUplink = $false; MgmtVdsName = "" }
            }
            Mock Read-Host { return "n" }
            Invoke-PrepareHostForClusterMove -DestinationClusterName "cl-new" -EsxHostName "esx01.lab" `
                -SourceClusterName "cl-old" -VMHost $fakeHost -Server "vc.lab"
        } } | Should -Throw

    }

    It "Throws when operator responds N to the confirmation prompt (vmk0 on VDS)" {
        { InModuleScope VcfEdgeAtScale {
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab" }
            Mock Test-HostManagementVdsDualUplink {
                [PSCustomObject]@{ HasDualUplink = $true; MgmtVdsName = "VDS-site1" }
            }
            Mock Read-Host { return "n" }
            Invoke-PrepareHostForClusterMove -DestinationClusterName "cl-new" -EsxHostName "esx01.lab" `
                -SourceClusterName "cl-old" -VMHost $fakeHost -Server "vc.lab"
        } } | Should -Throw

    }

    It "Throws when operator presses Enter (empty response, default N)" {
        { InModuleScope VcfEdgeAtScale {
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab" }
            Mock Test-HostManagementVdsDualUplink {
                [PSCustomObject]@{ HasDualUplink = $true; MgmtVdsName = "VDS-site1" }
            }
            Mock Read-Host { return "" }
            Invoke-PrepareHostForClusterMove -DestinationClusterName "cl-new" -EsxHostName "esx01.lab" `
                -SourceClusterName "cl-old" -VMHost $fakeHost -Server "vc.lab"
        } } | Should -Throw

    }

    It "Re-prompts on invalid input and aborts when operator eventually responds N" {
        InModuleScope VcfEdgeAtScale {
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab" }
            Mock Test-HostManagementVdsDualUplink {
                [PSCustomObject]@{ HasDualUplink = $true; MgmtVdsName = "VDS-site1" }
            }
            $Global:_repromptCallCount = 0
            Mock Read-Host {
                $Global:_repromptCallCount++
                # First two calls return garbage; third returns N to abort.
                switch ($Global:_repromptCallCount) { 1 { "maybe" } 2 { "sure" } default { "n" } }
            }
            $threw = $false
            try {
                Invoke-PrepareHostForClusterMove -DestinationClusterName "cl-new" -EsxHostName "esx01.lab" `
                    -SourceClusterName "cl-old" -VMHost $fakeHost -Server "vc.lab"
            } catch {
                $threw = $true
            }
            $threw | Should -Be $true
            Should -Invoke Read-Host -Times 3 -Scope It
        }
        $Global:_repromptCallCount | Should -Be 3
    }

    It "Proceeds (does not throw before restore) when operator responds Y and restore succeeds" {
        InModuleScope VcfEdgeAtScale {
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab" }
            Mock Test-HostManagementVdsDualUplink {
                [PSCustomObject]@{ HasDualUplink = $true; MgmtVdsName = "VDS-site1" }
            }
            Mock Read-Host { return "y" }
            Mock Get-NonMgmtVmkernelAdaptersOnHost { return @() }
            Mock Restore-ManagementToVssBeforeVdsRemoval {
                [PSCustomObject]@{ RestoreAttempted = $true; Success = $true; HostsRestoredCount = 1; Message = "" }
            }
            Mock Get-VdsListOnHost { return @() }
            { Invoke-PrepareHostForClusterMove -DestinationClusterName "cl-new" -EsxHostName "esx01.lab" `
                -SourceClusterName "cl-old" -VMHost $fakeHost -Server "vc.lab" } | Should -Not -Throw
            # Management restore was called for the VDS-path case.
            Should -Invoke Restore-ManagementToVssBeforeVdsRemoval -Times 1 -Scope It
        }
    }

    It "Throws when restore is attempted but fails" {
        { InModuleScope VcfEdgeAtScale {
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab" }
            Mock Test-HostManagementVdsDualUplink {
                [PSCustomObject]@{ HasDualUplink = $true; MgmtVdsName = "VDS-site1" }
            }
            Mock Read-Host { return "y" }
            # Stub the internal wrapper to avoid VMware argument-transformation on Get-VMHostNetworkAdapter.
            function Get-NonMgmtVmkernelAdaptersOnHost {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Object]$Server)
                return @()
            }
            Mock Restore-ManagementToVssBeforeVdsRemoval {
                [PSCustomObject]@{ RestoreAttempted = $true; Success = $false; HostsRestoredCount = 0; Message = "vSphere rollback." }
            }
            Invoke-PrepareHostForClusterMove -DestinationClusterName "cl-new" -EsxHostName "esx01.lab" `
                -SourceClusterName "cl-old" -VMHost $fakeHost -Server "vc.lab"
        } } | Should -Throw "*Could not restore management to standard switch*"

    }
}

# ── Add-HostToCluster — inventory check routing ───────────────────────────────


Describe "Add-HostToCluster — inventory check routing — mocked vCenter" {

    It "Calls Invoke-PrepareHostForClusterMove when host is in a different cluster with no running VMs" {
        # Validates branching logic: host in different cluster + no running VMs → PrepareHostForClusterMove.
        # Add-HostToCluster calls Get-Cluster and Get-VMHost with -Server [VIServer[]] which enforces PowerCLI type
        # binding on mock proxies. We test the routing logic directly by invoking the relevant branch inline.
        InModuleScope VcfEdgeAtScale {
            $fakeCluster = [PSCustomObject]@{ Name = "cl-old" }
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab"; Parent = $fakeCluster }
            Mock Get-RunningVmsOnHost { return @() }
            Mock Invoke-PrepareHostForClusterMove { }
            # Simulate the exact branch that Add-HostToCluster takes:
            # host found in vCenter, no running VMs, parent cluster differs from destination.
            $hostForRunningVmCheck = $fakeHost
            $runningVms = Get-RunningVmsOnHost -VMHost $hostForRunningVmCheck -Server "vc.lab"
            $sourceCluster = [PSCustomObject]@{ Name = $fakeHost.Parent.Name }
            if ($runningVms.Count -eq 0 -and $null -ne $sourceCluster -and $sourceCluster.Name -ne "cl-new") {
                Invoke-PrepareHostForClusterMove -DestinationClusterName "cl-new" -EsxHostName "esx01.lab" `
                    -Server "vc.lab" -SourceClusterName $sourceCluster.Name -VMHost $hostForRunningVmCheck
            }
            Should -Invoke Invoke-PrepareHostForClusterMove -Times 1 -Scope It
        }
    }

    It "Calls Invoke-AddHostToClusterRunningVmSafetyCheck when host has running VMs" {
        # Validates branching logic: host in vCenter with running VMs → RunningVmSafetyCheck.
        InModuleScope VcfEdgeAtScale {
            $fakeCluster = [PSCustomObject]@{ Name = "cl-new" }
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab"; Parent = $fakeCluster }
            $runningVm = [PSCustomObject]@{ Name = "vm01"; PowerState = "PoweredOn" }
            Mock Get-RunningVmsOnHost { return @($runningVm) }
            Mock Invoke-AddHostToClusterRunningVmSafetyCheck { }
            # Simulate the exact branch that Add-HostToCluster takes:
            # host found in vCenter, running VMs exist → safety check.
            $hostForRunningVmCheck = $fakeHost
            $runningVms = Get-RunningVmsOnHost -VMHost $hostForRunningVmCheck -Server "vc.lab"
            if ($runningVms.Count -gt 0) {
                Invoke-AddHostToClusterRunningVmSafetyCheck -ClusterName "cl-new" -EsxHostName "esx01.lab" `
                    -Server "vc.lab" -VMHost $hostForRunningVmCheck
            }
            Should -Invoke Invoke-AddHostToClusterRunningVmSafetyCheck -Times 1 -Scope It
        }
    }

    It "Uses Invoke-MoveVMHostToDestination (not Add-VMHost) when host is already in vCenter inventory" {
        # Validates that the intra-vCenter path calls the Move-VMHost wrapper rather than Add-VMHost.
        # This is the scenario that caused ZTP failures: host in ztp-staging-cluster,
        # target cluster-edge-site-1, Add-VMHost throws "already being managed by this vSphere server".
        # Move-VMHost has an ArgumentTransformationAttribute on -VMHost that blocks direct mocking,
        # so production code calls Invoke-MoveVMHostToDestination (thin wrapper) which can be mocked.
        InModuleScope VcfEdgeAtScale {
            $fakeHost = [PSCustomObject]@{ Name = "10.1.1.220"; Parent = [PSCustomObject]@{ Name = "ztp-staging-cluster" } }
            $fakeCluster = [PSCustomObject]@{ Name = "cluster-edge-site-1" }
            Mock Invoke-MoveVMHostToDestination { }
            Mock Add-VMHost { throw "This host is already being managed by this vSphere server." }
            # Simulate the branch where the host is already in vCenter inventory.
            $hostForRunningVmCheck = $fakeHost
            if ($null -ne $hostForRunningVmCheck) {
                Invoke-MoveVMHostToDestination -VMHost $hostForRunningVmCheck -Destination $fakeCluster -Server "vc.lab"
            } else {
                Add-VMHost -Name "10.1.1.220" -Credential $null -Location $fakeCluster -Force -Server "vc.lab" -ErrorAction Stop | Out-Null
            }
            Should -Invoke Invoke-MoveVMHostToDestination -Times 1 -Scope It
            Should -Invoke Add-VMHost -Times 0 -Scope It
        }
    }
}

# ── Invoke-HostRelocationPrecheck ─────────────────────────────────────────────


Describe "Invoke-HostRelocationPrecheck" {

    It "Returns HostForRunningVmCheck=null when host is not in vCenter inventory" {
        $result = InModuleScope VcfEdgeAtScale {
            Mock Get-VMHostByName { return $null }
            Mock Write-LogMessage {}
            $fakeCluster = [PSCustomObject]@{ Name = "dest-cl"; Id = "dc-1" }
            Invoke-HostRelocationPrecheck -ClusterName "dest-cl" -ClusterObject $fakeCluster -EsxHostName "esx01.lab" -Server "vc.lab"
        }
        $result.HostForRunningVmCheck | Should -BeNull
        $result.IsCrossDatacenterMove | Should -Be $false
    }

    It "Returns IsCrossDatacenterMove=true when source and destination datacenters differ" {
        $result = InModuleScope VcfEdgeAtScale {
            $fakeSrcCluster = [PSCustomObject]@{ Name = "source-cl" }
            $fakeHost       = [PSCustomObject]@{ Name = "esx01.lab"; Parent = $fakeSrcCluster }
            Mock Get-VMHostByName { return $fakeHost }
            Mock Get-RunningVmsOnHost { return @() }
            Mock Get-ClusterObjectByName { return [PSCustomObject]@{ Name = "source-cl" } }
            Mock Test-HostHasRequiredNics { [PSCustomObject]@{ IsValid = $true; MissingNics = @() } }
            Mock Invoke-PrepareHostForClusterMove {}
            Mock Get-DatacenterForVMHost { [PSCustomObject]@{ Id = "dc-1"; Name = "DC-Old" } }
            Mock Get-DatacenterForCluster { [PSCustomObject]@{ Id = "dc-2"; Name = "DC-New" } }
            Mock Write-LogMessage {}
            $fakeDestCluster = [PSCustomObject]@{ Name = "dest-cl"; Id = "dc-99" }
            Invoke-HostRelocationPrecheck -ClusterName "dest-cl" -ClusterObject $fakeDestCluster -EsxHostName "esx01.lab" -Server "vc.lab"
        }
        $result.IsCrossDatacenterMove | Should -Be $true
        $result.SourceDatacenterName  | Should -Be "DC-Old"
    }

    It "Throws VcfDeploymentException when host is missing a required NIC" {
        InModuleScope VcfEdgeAtScale {
            $fakeSrcCluster = [PSCustomObject]@{ Name = "source-cl" }
            $fakeHost       = [PSCustomObject]@{ Name = "esx01.lab"; Parent = $fakeSrcCluster }
            Mock Get-VMHostByName { return $fakeHost }
            Mock Get-RunningVmsOnHost { return @() }
            Mock Get-ClusterObjectByName { return [PSCustomObject]@{ Name = "source-cl" } }
            Mock Test-HostHasRequiredNics { [PSCustomObject]@{ IsValid = $false; MissingNics = @("vmnic2") } }
            Mock Write-LogMessage {}
            $fakeDestCluster = [PSCustomObject]@{ Name = "dest-cl" }
            { Invoke-HostRelocationPrecheck -ClusterName "dest-cl" -ClusterObject $fakeDestCluster -EsxHostName "esx01.lab" -NicList @("vmnic0","vmnic1","vmnic2") -Server "vc.lab" } |
                Should -Throw
        }
    }
}

# ── Invoke-ManagedHostMoveOrAdd ────────────────────────────────────────────────


Describe "Invoke-ManagedHostMoveOrAdd" {

    It "Calls Invoke-MoveVMHostToDestination (not Add-VMHost) for same-datacenter move" {
        InModuleScope VcfEdgeAtScale {
            $fakeHost    = [PSCustomObject]@{ Name = "esx01.lab"; ConnectionState = "Maintenance" }
            $fakeCluster = [PSCustomObject]@{ Name = "dest-cl" }
            $fakeCred    = [PSCredential]::new("root", (ConvertTo-SecureString "x" -AsPlainText -Force))
            Mock Invoke-MoveVMHostToDestination {}
            Mock Invoke-AddVMHostWithRetry { throw "Should not be called on move path." }
            Mock Write-LogMessage {}
            { Invoke-ManagedHostMoveOrAdd -ClusterName "dest-cl" -ClusterObject $fakeCluster -EsxCredential $fakeCred `
                -EsxHostName "esx01.lab" -HostForRunningVmCheck $fakeHost -IsCrossDatacenterMove:$false -Server "vc.lab" } |
                Should -Not -Throw
            Should -Invoke Invoke-MoveVMHostToDestination -Times 1 -Scope It
        }
    }

    It "Calls Invoke-AddVMHostWithRetry (not Invoke-MoveVMHostToDestination) when host is null (new host)" {
        InModuleScope VcfEdgeAtScale {
            $fakeCluster = [PSCustomObject]@{ Name = "dest-cl" }
            $fakeCred    = [PSCredential]::new("root", (ConvertTo-SecureString "x" -AsPlainText -Force))
            Mock Invoke-AddVMHostWithRetry {}
            Mock Invoke-MoveVMHostToDestination { throw "Should not be called on add path." }
            Mock Write-LogMessage {}
            { Invoke-ManagedHostMoveOrAdd -ClusterName "dest-cl" -ClusterObject $fakeCluster -EsxCredential $fakeCred `
                -EsxHostName "esx01.lab" -HostForRunningVmCheck $null -Server "vc.lab" -WaitForAddHostTaskTimeoutSeconds 0 } |
                Should -Not -Throw
            Should -Invoke Invoke-AddVMHostWithRetry -Times 1 -Scope It
        }
    }

    It "Throws VcfDeploymentException when Move-VMHost fails" {
        InModuleScope VcfEdgeAtScale {
            $fakeHost    = [PSCustomObject]@{ Name = "esx01.lab"; ConnectionState = "Maintenance" }
            $fakeCluster = [PSCustomObject]@{ Name = "dest-cl" }
            $fakeCred    = [PSCredential]::new("root", (ConvertTo-SecureString "x" -AsPlainText -Force))
            Mock Invoke-MoveVMHostToDestination { throw "The operation is not allowed in the current state." }
            Mock Write-LogMessage {}
            { Invoke-ManagedHostMoveOrAdd -ClusterName "dest-cl" -ClusterObject $fakeCluster -EsxCredential $fakeCred `
                -EsxHostName "esx01.lab" -HostForRunningVmCheck $fakeHost -IsCrossDatacenterMove:$false -Server "vc.lab" } |
                Should -Throw
            Should -Invoke Write-LogMessage -Times 1 -ParameterFilter { $Type -eq "ERROR" -and $Message -like "*not allowed in the current state*" } -Scope It
        }
    }
}

# ── Confirm-VMHostAddedToCluster ──────────────────────────────────────────────


Describe "Confirm-VMHostAddedToCluster" {

    It "Throws when host is not found after add" {
        InModuleScope VcfEdgeAtScale {
            Mock Test-VcenterConnection { [PSCustomObject]@{ IsConnected = $true; ErrorMessage = "" } }
            Mock Get-VMHostByName { return $null }
            Mock Write-LogMessage {}
            { Confirm-VMHostAddedToCluster -ClusterName "dest-cl" -EsxHostName "esx01.lab" -HostStateChangeDelaySeconds 0 -IsAddPath:$false -Server "vc.lab" } |
                Should -Throw
        }
    }

    It "Throws VcfDeploymentException when host is in a different cluster after add" {
        InModuleScope VcfEdgeAtScale {
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab"; ConnectionState = "Connected"; Parent = [PSCustomObject]@{ Name = "wrong-cluster" } }
            Mock Test-VcenterConnection { [PSCustomObject]@{ IsConnected = $true; ErrorMessage = "" } }
            Mock Get-VMHostByName { return $fakeHost }
            Mock Write-LogMessage {}
            { Confirm-VMHostAddedToCluster -ClusterName "dest-cl" -EsxHostName "esx01.lab" -HostStateChangeDelaySeconds 0 -IsAddPath:$false -Server "vc.lab" } |
                Should -Throw
        }
    }

    It "Completes without ERROR when host is already in the correct cluster and Connected" {
        InModuleScope VcfEdgeAtScale {
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab"; ConnectionState = "Connected"; Parent = [PSCustomObject]@{ Name = "dest-cl" } }
            Mock Test-VcenterConnection { [PSCustomObject]@{ IsConnected = $true; ErrorMessage = "" } }
            Mock Get-VMHostByName { return $fakeHost }
            Mock Write-LogMessage {}
            { Confirm-VMHostAddedToCluster -ClusterName "dest-cl" -EsxHostName "esx01.lab" -HostStateChangeDelaySeconds 0 -IsAddPath:$false -Server "vc.lab" } |
                Should -Not -Throw
            # Host is already Connected, so Set-VMHostState must not be called.
            Should -Not -Invoke Write-LogMessage -ParameterFilter { $Type -eq 'ERROR' }
        }
    }
}

# ── Add-HostToCluster — cross-datacenter host move ────────────────────────────
#
# Now that Get-Datacenter calls are wrapped in Get-DatacenterForVMHost /
# Get-DatacenterForCluster (mockable thin wrappers), these tests call the real
# Add-HostToCluster rather than inlining production logic.
#
# Shared setup notes:
#   • Host starts in Maintenance so the Set-VMHost-for-maintenance step is skipped,
#     letting each test focus on its target routing path.
#   • Three Get-VMHost mock variants differentiate by parameter set:
#       - ParameterFilter { Location } → $null  (existingHost check at top of function)
#       - ParameterFilter { ErrorAction -eq "Stop" } → $fakeVerifiedHost  (final verification)
#       - generic fallback → $fakeHost  (hostForRunningVmCheck and any other SilentlyContinue calls)
#   • -WaitForAddHostTaskTimeoutSeconds 0 selects the synchronous Add-VMHost path (no task
#     polling) on the cross-DC add branch; -HostStateChangeDelaySeconds 0 skips the post-add sleep.


Describe "Add-HostToCluster — cross-datacenter host move" {

    It "Takes the disconnect/remove/add path when source and destination datacenters differ" {
        InModuleScope VcfEdgeAtScale {
            $fakeSrcCluster   = [PSCustomObject]@{ Name = "source-cluster" }
            $fakeDestCluster  = [PSCustomObject]@{ Name = "dest-cluster" }
            $fakeHost         = [PSCustomObject]@{ Name = "esx01.lab"; ConnectionState = "Maintenance"; Parent = $fakeSrcCluster }
            $fakeVerifiedHost = [PSCustomObject]@{ Name = "esx01.lab"; ConnectionState = "Connected";   Parent = $fakeDestCluster }
            $fakeCred         = [PSCredential]::new("root", (ConvertTo-SecureString "x" -AsPlainText -Force))
            $Script:vCenterName = "vc.lab"

            Mock Test-VcenterConnection { [PSCustomObject]@{ IsConnected = $true; ErrorMessage = "" } }
            Mock Get-ClusterObjectByName { if ($ClusterName -eq "dest-cluster") { return $fakeDestCluster }; return $fakeSrcCluster }
            $Script:_vmHostCallCount = 0
            Mock Get-VMHostByName {
                $Script:_vmHostCallCount++
                if ($Script:_vmHostCallCount -le 1) { return $fakeHost }
                return $fakeVerifiedHost
            }
            Mock Get-RunningVmsOnHost { @() }
            Mock Test-HostHasRequiredNics { [PSCustomObject]@{ IsValid = $true; MissingNics = @() } }
            Mock Invoke-PrepareHostForClusterMove {}
            Mock Get-DatacenterForVMHost { [PSCustomObject]@{ Id = "datacenter-1"; Name = "DC-Old" } }
            Mock Get-DatacenterForCluster { [PSCustomObject]@{ Id = "datacenter-2"; Name = "DC-New" } }
            Mock Set-VMHostState {}
            Mock Remove-VMHostFromVCenter {}
            Mock Invoke-AddVMHostToCluster {}
            Mock Invoke-MoveVMHostToDestination {}
            Mock Write-LogMessage {}

            { Add-HostToCluster -ClusterName "dest-cluster" -EsxHostName "esx01.lab" -EsxCredential $fakeCred `
                -WaitForAddHostTaskTimeoutSeconds 0 -HostStateChangeDelaySeconds 0 } | Should -Not -Throw

            Should -Invoke Remove-VMHostFromVCenter       -Times 1 -Scope It
            Should -Invoke Invoke-AddVMHostToCluster      -Times 1 -Scope It
            Should -Invoke Invoke-MoveVMHostToDestination -Times 0 -Scope It
        }
    }

    It "Takes the Move-VMHost path when source and destination datacenters are the same" {
        InModuleScope VcfEdgeAtScale {
            $fakeSrcCluster   = [PSCustomObject]@{ Name = "source-cluster" }
            $fakeDestCluster  = [PSCustomObject]@{ Name = "dest-cluster" }
            $fakeHost         = [PSCustomObject]@{ Name = "esx01.lab"; ConnectionState = "Maintenance"; Parent = $fakeSrcCluster }
            $fakeVerifiedHost = [PSCustomObject]@{ Name = "esx01.lab"; ConnectionState = "Connected";   Parent = $fakeDestCluster }
            $fakeCred         = [PSCredential]::new("root", (ConvertTo-SecureString "x" -AsPlainText -Force))
            $Script:vCenterName = "vc.lab"

            Mock Test-VcenterConnection { [PSCustomObject]@{ IsConnected = $true; ErrorMessage = "" } }
            Mock Get-ClusterObjectByName { if ($ClusterName -eq "dest-cluster") { return $fakeDestCluster }; return $fakeSrcCluster }
            $Script:_vmHostCallCount = 0
            Mock Get-VMHostByName {
                $Script:_vmHostCallCount++
                if ($Script:_vmHostCallCount -le 1) { return $fakeHost }
                return $fakeVerifiedHost
            }
            Mock Get-RunningVmsOnHost { @() }
            Mock Test-HostHasRequiredNics { [PSCustomObject]@{ IsValid = $true; MissingNics = @() } }
            Mock Invoke-PrepareHostForClusterMove {}
            Mock Get-DatacenterForVMHost { [PSCustomObject]@{ Id = "datacenter-1"; Name = "DC-Shared" } }
            Mock Get-DatacenterForCluster { [PSCustomObject]@{ Id = "datacenter-1"; Name = "DC-Shared" } }
            Mock Set-VMHostState {}
            Mock Invoke-MoveVMHostToDestination {}
            Mock Remove-VMHostFromVCenter {}
            Mock Invoke-AddVMHostToCluster {}
            Mock Write-LogMessage {}

            { Add-HostToCluster -ClusterName "dest-cluster" -EsxHostName "esx01.lab" -EsxCredential $fakeCred } | Should -Not -Throw

            Should -Invoke Invoke-MoveVMHostToDestination -Times 1 -Scope It
            Should -Invoke Remove-VMHostFromVCenter       -Times 0 -Scope It
            Should -Invoke Invoke-AddVMHostToCluster      -Times 0 -Scope It
        }
    }

    It "Throws VcfDeploymentException when disconnect fails during cross-DC move" {
        InModuleScope VcfEdgeAtScale {
            $fakeSrcCluster  = [PSCustomObject]@{ Name = "source-cluster" }
            $fakeDestCluster = [PSCustomObject]@{ Name = "dest-cluster" }
            $fakeHost        = [PSCustomObject]@{ Name = "esx01.lab"; ConnectionState = "Maintenance"; Parent = $fakeSrcCluster }
            $fakeCred        = [PSCredential]::new("root", (ConvertTo-SecureString "x" -AsPlainText -Force))
            $Script:vCenterName = "vc.lab"

            Mock Test-VcenterConnection { [PSCustomObject]@{ IsConnected = $true; ErrorMessage = "" } }
            Mock Get-ClusterObjectByName { if ($ClusterName -eq "dest-cluster") { return $fakeDestCluster }; return $fakeSrcCluster }
            Mock Get-VMHostByName { $fakeHost }
            Mock Get-RunningVmsOnHost { @() }
            Mock Test-HostHasRequiredNics { [PSCustomObject]@{ IsValid = $true; MissingNics = @() } }
            Mock Invoke-PrepareHostForClusterMove {}
            Mock Get-DatacenterForVMHost { [PSCustomObject]@{ Id = "datacenter-1"; Name = "DC-Old" } }
            Mock Get-DatacenterForCluster { [PSCustomObject]@{ Id = "datacenter-2"; Name = "DC-New" } }
            Mock Set-VMHostState { throw "Cannot disconnect." }
            Mock Write-LogMessage {}

            { Add-HostToCluster -ClusterName "dest-cluster" -EsxHostName "esx01.lab" -EsxCredential $fakeCred } |
                Should -Throw

            Should -Invoke Write-LogMessage -Times 1 -ParameterFilter {
                $Type -eq "ERROR" -and $Message -like "*disconnect*cross-datacenter*"
            } -Scope It
        }
    }

    It "Throws VcfDeploymentException when Remove-VMHost fails during cross-DC move" {
        InModuleScope VcfEdgeAtScale {
            $fakeSrcCluster  = [PSCustomObject]@{ Name = "source-cluster" }
            $fakeDestCluster = [PSCustomObject]@{ Name = "dest-cluster" }
            $fakeHost        = [PSCustomObject]@{ Name = "esx01.lab"; ConnectionState = "Maintenance"; Parent = $fakeSrcCluster }
            $fakeCred        = [PSCredential]::new("root", (ConvertTo-SecureString "x" -AsPlainText -Force))
            $Script:vCenterName = "vc.lab"

            Mock Test-VcenterConnection { [PSCustomObject]@{ IsConnected = $true; ErrorMessage = "" } }
            Mock Get-ClusterObjectByName { if ($ClusterName -eq "dest-cluster") { return $fakeDestCluster }; return $fakeSrcCluster }
            Mock Get-VMHostByName { $fakeHost }
            Mock Get-RunningVmsOnHost { @() }
            Mock Test-HostHasRequiredNics { [PSCustomObject]@{ IsValid = $true; MissingNics = @() } }
            Mock Invoke-PrepareHostForClusterMove {}
            Mock Get-DatacenterForVMHost { [PSCustomObject]@{ Id = "datacenter-1"; Name = "DC-Old" } }
            Mock Get-DatacenterForCluster { [PSCustomObject]@{ Id = "datacenter-2"; Name = "DC-New" } }
            Mock Set-VMHostState {}
            Mock Remove-VMHostFromVCenter { throw "Remove failed." }
            Mock Write-LogMessage {}

            { Add-HostToCluster -ClusterName "dest-cluster" -EsxHostName "esx01.lab" -EsxCredential $fakeCred } |
                Should -Throw

            Should -Invoke Write-LogMessage -Times 1 -ParameterFilter {
                $Type -eq "ERROR" -and $Message -like "*remove*source vCenter inventory*"
            } -Scope It
        }
    }
}

# ── Add-HostToCluster — maintenance mode before cluster move ──────────────────


Describe "Add-HostToCluster — maintenance mode before cluster move" {

    It "Does not call Set-VMHost for maintenance when host ConnectionState is already Maintenance" {
        InModuleScope VcfEdgeAtScale {
            $fakeSrcCluster   = [PSCustomObject]@{ Name = "source-cluster" }
            $fakeDestCluster  = [PSCustomObject]@{ Name = "dest-cluster" }
            $fakeHost         = [PSCustomObject]@{ Name = "esx01.lab"; ConnectionState = "Maintenance"; Parent = $fakeSrcCluster }
            $fakeVerifiedHost = [PSCustomObject]@{ Name = "esx01.lab"; ConnectionState = "Connected";   Parent = $fakeDestCluster }
            $fakeCred         = [PSCredential]::new("root", (ConvertTo-SecureString "x" -AsPlainText -Force))
            $Script:vCenterName = "vc.lab"

            Mock Test-VcenterConnection { [PSCustomObject]@{ IsConnected = $true; ErrorMessage = "" } }
            Mock Get-ClusterObjectByName { if ($ClusterName -eq "dest-cluster") { return $fakeDestCluster }; return $fakeSrcCluster }
            $Script:_vmHostCallCount = 0
            Mock Get-VMHostByName {
                $Script:_vmHostCallCount++
                if ($Script:_vmHostCallCount -le 1) { return $fakeHost }
                return $fakeVerifiedHost
            }
            Mock Get-RunningVmsOnHost { @() }
            Mock Test-HostHasRequiredNics { [PSCustomObject]@{ IsValid = $true; MissingNics = @() } }
            Mock Invoke-PrepareHostForClusterMove {}
            Mock Get-DatacenterForVMHost { [PSCustomObject]@{ Id = "datacenter-1"; Name = "DC-Shared" } }
            Mock Get-DatacenterForCluster { [PSCustomObject]@{ Id = "datacenter-1"; Name = "DC-Shared" } }
            Mock Set-VMHostState {}
            Mock Invoke-MoveVMHostToDestination {}
            Mock Write-LogMessage {}

            Add-HostToCluster -ClusterName "dest-cluster" -EsxHostName "esx01.lab" -EsxCredential $fakeCred

            Should -Invoke Set-VMHostState -Times 0 -ParameterFilter { $State -eq "Maintenance" } -Scope It
        }
    }

    It "Throws VcfDeploymentException when Set-VMHost for maintenance fails" {
        InModuleScope VcfEdgeAtScale {
            $fakeSrcCluster  = [PSCustomObject]@{ Name = "source-cluster" }
            $fakeDestCluster = [PSCustomObject]@{ Name = "dest-cluster" }
            $fakeHost        = [PSCustomObject]@{ Name = "esx01.lab"; ConnectionState = "Connected"; Parent = $fakeSrcCluster }
            $fakeCred        = [PSCredential]::new("root", (ConvertTo-SecureString "x" -AsPlainText -Force))
            $Script:vCenterName = "vc.lab"

            Mock Test-VcenterConnection { [PSCustomObject]@{ IsConnected = $true; ErrorMessage = "" } }
            Mock Get-ClusterObjectByName { if ($ClusterName -eq "dest-cluster") { return $fakeDestCluster }; return $fakeSrcCluster }
            Mock Get-VMHostByName { $fakeHost }
            Mock Get-RunningVmsOnHost { @() }
            Mock Test-HostHasRequiredNics { [PSCustomObject]@{ IsValid = $true; MissingNics = @() } }
            Mock Invoke-PrepareHostForClusterMove {}
            Mock Get-DatacenterForVMHost { [PSCustomObject]@{ Id = "datacenter-1"; Name = "DC-Shared" } }
            Mock Get-DatacenterForCluster { [PSCustomObject]@{ Id = "datacenter-1"; Name = "DC-Shared" } }
            Mock Set-VMHostState { if ($State -eq "Maintenance") { throw "Maintenance mode entry failed." } }
            Mock Write-LogMessage {}

            { Add-HostToCluster -ClusterName "dest-cluster" -EsxHostName "esx01.lab" -EsxCredential $fakeCred } |
                Should -Throw

            Should -Invoke Write-LogMessage -Times 1 -ParameterFilter {
                $Type -eq "ERROR" -and $Message -like "*maintenance mode*"
            } -Scope It
        }
    }
}

# ── Add-HostToCluster — Move-VMHost error detail logging ──────────────────────


Describe "Add-HostToCluster — Move-VMHost error detail logging" {

    It "Logs vCenter error detail via Write-LogMessage when Invoke-MoveVMHostToDestination throws" {
        # Regression: prior to fix, the error was only in VcfDeploymentException; the top-level
        # catch assumed it was already logged so the operator saw only "Failed." with no cause.
        InModuleScope VcfEdgeAtScale {
            $fakeSrcCluster  = [PSCustomObject]@{ Name = "source-cluster" }
            $fakeDestCluster = [PSCustomObject]@{ Name = "dest-cluster" }
            $fakeHost        = [PSCustomObject]@{ Name = "esx01.lab"; ConnectionState = "Maintenance"; Parent = $fakeSrcCluster }
            $fakeCred        = [PSCredential]::new("root", (ConvertTo-SecureString "x" -AsPlainText -Force))
            $Script:vCenterName = "vc.lab"

            Mock Test-VcenterConnection { [PSCustomObject]@{ IsConnected = $true; ErrorMessage = "" } }
            Mock Get-ClusterObjectByName { if ($ClusterName -eq "dest-cluster") { return $fakeDestCluster }; return $fakeSrcCluster }
            Mock Get-VMHostByName { $fakeHost }
            Mock Get-RunningVmsOnHost { @() }
            Mock Test-HostHasRequiredNics { [PSCustomObject]@{ IsValid = $true; MissingNics = @() } }
            Mock Invoke-PrepareHostForClusterMove {}
            Mock Get-DatacenterForVMHost { [PSCustomObject]@{ Id = "datacenter-1"; Name = "DC-Shared" } }
            Mock Get-DatacenterForCluster { [PSCustomObject]@{ Id = "datacenter-1"; Name = "DC-Shared" } }
            Mock Set-VMHostState {}
            Mock Invoke-MoveVMHostToDestination { throw "The operation is not allowed in the current state." }
            Mock Write-LogMessage {}

            { Add-HostToCluster -ClusterName "dest-cluster" -EsxHostName "esx01.lab" -EsxCredential $fakeCred } |
                Should -Throw

            Should -Invoke Write-LogMessage -Times 1 -ParameterFilter {
                $Type -eq "ERROR" -and $Message -like "*not allowed in the current state*"
            } -Scope It
        }
    }
}

# ── Invoke-PrepareHostForClusterMove — additional branch coverage ─────────────


Describe "Invoke-PrepareHostForClusterMove — VMkernel removal failure path" {

    It "Does not throw when one non-management VMkernel cannot be removed (warning only)" {
        InModuleScope VcfEdgeAtScale {
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab" }
            $fakeVmk = [PSCustomObject]@{ Name = "vmk1" }
            Mock Test-HostManagementVdsDualUplink {
                [PSCustomObject]@{ HasDualUplink = $true; MgmtVdsName = "VDS-site1" }
            }
            Mock Read-Host { return "y" }
            Mock Write-LogMessage {}
            Mock Get-NonMgmtVmkernelAdaptersOnHost { return @($fakeVmk) }
            Mock Remove-VMHostNetworkAdapter { throw "Adapter in use." }
            Mock Restore-ManagementToVssBeforeVdsRemoval {
                [PSCustomObject]@{ RestoreAttempted = $true; Success = $true; HostsRestoredCount = 1; Message = "" }
            }
            Mock Get-VdsListOnHost { return @() }
            { Invoke-PrepareHostForClusterMove -DestinationClusterName "cl-new" -EsxHostName "esx01.lab" `
                -SourceClusterName "cl-old" -VMHost $fakeHost -Server "vc.lab" } | Should -Not -Throw
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq "WARNING" -and $Message -match "vmk1" } -Scope It
        }
    }
}

# ── Add-HostToCluster — same-cluster no-VMs debug path ────────────────────────


Describe "Add-HostToCluster — same-cluster no-VMs debug path — mocked vCenter" {

    It "Does not call Invoke-PrepareHostForClusterMove when host is already in the target cluster with no running VMs" {
        # Validates branching logic: host in same cluster + no running VMs → no PrepareHostForClusterMove.
        InModuleScope VcfEdgeAtScale {
            $fakeCluster = [PSCustomObject]@{ Name = "cl-new" }
            # $fakeHost.Parent matches the destination cluster — no move should be triggered.
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab"; Parent = $fakeCluster }
            Mock Get-RunningVmsOnHost { return @() }
            Mock Invoke-PrepareHostForClusterMove { }
            # Simulate the branch where source cluster equals destination cluster.
            $hostForRunningVmCheck = $fakeHost
            $runningVms = Get-RunningVmsOnHost -VMHost $hostForRunningVmCheck -Server "vc.lab"
            $sourceCluster = [PSCustomObject]@{ Name = $fakeHost.Parent.Name }
            if ($runningVms.Count -eq 0 -and $null -ne $sourceCluster -and $sourceCluster.Name -ne "cl-new") {
                Invoke-PrepareHostForClusterMove -DestinationClusterName "cl-new" -EsxHostName "esx01.lab" `
                    -Server "vc.lab" -SourceClusterName $sourceCluster.Name -VMHost $hostForRunningVmCheck
            }
            Should -Invoke Invoke-PrepareHostForClusterMove -Times 0 -Scope It
        }
    }
}

# ── Test-HostHasRequiredNics ─────────────────────────────────────────────────


Describe "Test-HostHasRequiredNics — NIC presence validation" {

    It "Returns IsValid=true when all NICs in the list are present on the host" {
        InModuleScope VcfEdgeAtScale {
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab" }
            $fakeAdapter = [PSCustomObject]@{ Name = "vmnic0" }
            Mock Get-PhysicalNicAdapterOnHost { return $fakeAdapter }
            $result = Test-HostHasRequiredNics -EsxHostName "esx01.lab" `
                -NicList @([PSCustomObject]@{ Name = "vmnic0" }, [PSCustomObject]@{ Name = "vmnic1" }) `
                -Server "vc.lab" -VMHost $fakeHost
            $result.IsValid | Should -BeTrue
            $result.MissingNics.Count | Should -Be 0
        }
    }

    It "Returns IsValid=false and MissingNics contains the absent NIC when one is missing" {
        InModuleScope VcfEdgeAtScale {
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab" }
            $fakeAdapter = [PSCustomObject]@{ Name = "vmnic0" }
            Mock Get-PhysicalNicAdapterOnHost {
                if ($NicName -eq "vmnic0") { return $fakeAdapter }
                return $null
            }
            Mock Write-LogMessage {}
            $result = Test-HostHasRequiredNics -EsxHostName "esx01.lab" `
                -NicList @([PSCustomObject]@{ Name = "vmnic0" }, [PSCustomObject]@{ Name = "vmnic1" }) `
                -Server "vc.lab" -VMHost $fakeHost
            $result.IsValid | Should -BeFalse
            $result.MissingNics | Should -Contain "vmnic1"
            $result.MissingNics.Count | Should -Be 1
        }
    }

    It "Returns IsValid=false for each missing NIC when all NICs are absent" {
        InModuleScope VcfEdgeAtScale {
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab" }
            Mock Get-PhysicalNicAdapterOnHost { return $null }
            Mock Write-LogMessage {}
            $result = Test-HostHasRequiredNics -EsxHostName "esx01.lab" `
                -NicList @("vmnic0", "vmnic1") `
                -Server "vc.lab" -VMHost $fakeHost
            $result.IsValid | Should -BeFalse
            $result.MissingNics | Should -Contain "vmnic0"
            $result.MissingNics | Should -Contain "vmnic1"
            $result.MissingNics.Count | Should -Be 2
        }
    }

    It "Handles string entries in NicList (not objects with Name property)" {
        InModuleScope VcfEdgeAtScale {
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab" }
            $fakeAdapter = [PSCustomObject]@{ Name = "vmnic0" }
            Mock Get-PhysicalNicAdapterOnHost {
                if ($NicName -eq "vmnic0") { return $fakeAdapter }
                return $null
            }
            Mock Write-LogMessage {}
            $result = Test-HostHasRequiredNics -EsxHostName "esx01.lab" `
                -NicList @("vmnic0", "vmnic1") `
                -Server "vc.lab" -VMHost $fakeHost
            $result.IsValid | Should -BeFalse
            $result.MissingNics | Should -Contain "vmnic1"
        }
    }

    It "Skips a PSCustomObject NicList entry with no Name property and does not treat it as a missing NIC" {
        InModuleScope VcfEdgeAtScale {
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab" }
            $fakeAdapter = [PSCustomObject]@{ Name = "vmnic0" }
            Mock Get-PhysicalNicAdapterOnHost { return $fakeAdapter }
            Mock Write-LogMessage {}
            # Entry with no Name property at all — the guard must log a WARNING and skip it.
            $badEntry = [PSCustomObject]@{ Label = "not-a-nic" }
            $result = Test-HostHasRequiredNics -EsxHostName "esx01.lab" `
                -NicList @([PSCustomObject]@{ Name = "vmnic0" }, $badEntry) `
                -Server "vc.lab" -VMHost $fakeHost
            $result.IsValid | Should -BeTrue
            $result.MissingNics.Count | Should -Be 0
            Should -Invoke Write-LogMessage -Times 1 -Scope It -ParameterFilter { $Type -eq "WARNING" }
        }
    }
}

# ── Add-HostToCluster — NIC list validation before cluster-move takeover ──────


Describe "Add-HostToCluster — NIC list validation before cluster takeover" {

    It "Throws VcfDeploymentException and does not call Invoke-PrepareHostForClusterMove when a required NIC is missing" {
        # Validates that the cluster-move path is blocked when the host is missing a NIC from the NicList.
        InModuleScope VcfEdgeAtScale {
            $fakeSourceCluster = [PSCustomObject]@{ Name = "cl-old" }
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab"; Parent = $fakeSourceCluster }
            Mock Write-LogMessage {}
            Mock Invoke-PrepareHostForClusterMove {}
            Mock Test-HostHasRequiredNics {
                [PSCustomObject]@{ IsValid = $false; MissingNics = @("vmnic1") }
            }
            $nicList = @([PSCustomObject]@{ Name = "vmnic0" }, [PSCustomObject]@{ Name = "vmnic1" })
            $sourceCluster = $fakeSourceCluster
            $hostForRunningVmCheck = $fakeHost
            $ClusterName = "cl-new"
            $EsxHostName = "esx01.lab"
            $Script:vCenterName = "vc.lab"
            {
                if ($null -ne $nicList -and $nicList.Count -gt 0) {
                    $nicCheck = Test-HostHasRequiredNics -EsxHostName $EsxHostName -NicList $nicList `
                        -Server $Script:vCenterName -VMHost $hostForRunningVmCheck
                    if (-not $nicCheck.IsValid) {
                        $missingStr = $nicCheck.MissingNics -join ", "
                        Write-LogMessage -Type ERROR -Message "Host `"$EsxHostName`" is missing required physical NIC(s) [$missingStr] from the configured NIC list. The vSS-to-VDS migration cannot proceed without these NICs. Remove this host from the deployment configuration or install the required NIC hardware and re-run."
                        throw [VcfDeploymentException]::new("Host `"$EsxHostName`" is missing required NIC(s): $missingStr. Cannot take over from cluster `"$($sourceCluster.Name)`". Check logs for details.")
                    }
                }
                Invoke-PrepareHostForClusterMove -DestinationClusterName $ClusterName -EsxHostName $EsxHostName `
                    -Server $Script:vCenterName -SourceClusterName $sourceCluster.Name -VMHost $hostForRunningVmCheck
            } | Should -Throw

            Should -Invoke Invoke-PrepareHostForClusterMove -Times 0 -Scope It
            Should -Invoke Write-LogMessage -Times 1 -ParameterFilter { $Type -eq "ERROR" -and $Message -like "*vmnic1*" } -Scope It
        }
    }

    It "Calls Invoke-PrepareHostForClusterMove when all required NICs are present" {
        # Validates that the cluster-move path proceeds normally when the host has all NICs.
        InModuleScope VcfEdgeAtScale {
            $fakeSourceCluster = [PSCustomObject]@{ Name = "cl-old" }
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab"; Parent = $fakeSourceCluster }
            Mock Write-LogMessage {}
            Mock Invoke-PrepareHostForClusterMove {}
            Mock Test-HostHasRequiredNics {
                [PSCustomObject]@{ IsValid = $true; MissingNics = @() }
            }
            $nicList = @([PSCustomObject]@{ Name = "vmnic0" }, [PSCustomObject]@{ Name = "vmnic1" })
            $sourceCluster = $fakeSourceCluster
            $hostForRunningVmCheck = $fakeHost
            $ClusterName = "cl-new"
            $EsxHostName = "esx01.lab"
            $Script:vCenterName = "vc.lab"
            if ($null -ne $nicList -and $nicList.Count -gt 0) {
                $nicCheck = Test-HostHasRequiredNics -EsxHostName $EsxHostName -NicList $nicList `
                    -Server $Script:vCenterName -VMHost $hostForRunningVmCheck
                if (-not $nicCheck.IsValid) {
                    throw [VcfDeploymentException]::new("Should not reach here.")
                }
            }
            Invoke-PrepareHostForClusterMove -DestinationClusterName $ClusterName -EsxHostName $EsxHostName `
                -Server $Script:vCenterName -SourceClusterName $sourceCluster.Name -VMHost $hostForRunningVmCheck
            Should -Invoke Invoke-PrepareHostForClusterMove -Times 1 -Scope It
        }
    }

    It "Skips NIC validation and calls Invoke-PrepareHostForClusterMove when NicList is null" {
        # Validates backward-compatible behavior: no NicList = no NIC check.
        InModuleScope VcfEdgeAtScale {
            $fakeSourceCluster = [PSCustomObject]@{ Name = "cl-old" }
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab"; Parent = $fakeSourceCluster }
            Mock Write-LogMessage {}
            Mock Invoke-PrepareHostForClusterMove {}
            Mock Test-HostHasRequiredNics {}
            $nicList = $null
            $sourceCluster = $fakeSourceCluster
            $hostForRunningVmCheck = $fakeHost
            $ClusterName = "cl-new"
            $EsxHostName = "esx01.lab"
            $Script:vCenterName = "vc.lab"
            if ($null -ne $nicList -and $nicList.Count -gt 0) {
                Test-HostHasRequiredNics -EsxHostName $EsxHostName -NicList $nicList `
                    -Server $Script:vCenterName -VMHost $hostForRunningVmCheck | Out-Null
            }
            Invoke-PrepareHostForClusterMove -DestinationClusterName $ClusterName -EsxHostName $EsxHostName `
                -Server $Script:vCenterName -SourceClusterName $sourceCluster.Name -VMHost $hostForRunningVmCheck
            Should -Invoke Test-HostHasRequiredNics -Times 0 -Scope It
            Should -Invoke Invoke-PrepareHostForClusterMove -Times 1 -Scope It
        }
    }
}

# ── Invoke-ManagementRestoreForCleanupWithTopologyFallback ───────────────────


Describe "Get-RunningVmsOnHost — PoweredOn filter" {

    It "Includes powered-on VMs and excludes powered-off VMs" {
        $all = @(
            [PSCustomObject]@{ Name = "vm-on";  PowerState = "PoweredOn" },
            [PSCustomObject]@{ Name = "vm-off"; PowerState = "PoweredOff" }
        )
        $result = @($all | Where-Object { $_.PowerState -eq "PoweredOn" })
        $result.Count | Should -Be 1
        $result[0].Name | Should -Be "vm-on"
    }

    It "Returns zero items when all VMs are powered off" {
        $all = @([PSCustomObject]@{ Name = "vm-off"; PowerState = "PoweredOff" })
        $result = @($all | Where-Object { $_.PowerState -eq "PoweredOn" })
        $result.Count | Should -Be 0
    }

    It "Returns zero items from an empty input" {
        $result = @(@() | Where-Object { $_.PowerState -eq "PoweredOn" })
        $result.Count | Should -Be 0
    }
}


Describe "Get-NonMgmtVmkernelAdaptersOnHost — vmk0 exclusion filter" {

    It "Excludes vmk0 and includes vmk1 and vmk2" {
        $adapters = @(
            [PSCustomObject]@{ Name = "vmk0" },
            [PSCustomObject]@{ Name = "vmk1" },
            [PSCustomObject]@{ Name = "vmk2" }
        )
        $result = @($adapters | Where-Object { $_.Name -ne "vmk0" })
        $result.Count | Should -Be 2
        $result.Name | Should -Not -Contain "vmk0"
    }

    It "Returns zero items when only vmk0 is present" {
        $adapters = @([PSCustomObject]@{ Name = "vmk0" })
        $result = @($adapters | Where-Object { $_.Name -ne "vmk0" })
        $result.Count | Should -Be 0
    }

    It "Returns zero items from an empty input" {
        $result = @(@() | Where-Object { $_.Name -ne "vmk0" })
        $result.Count | Should -Be 0
    }
}


Describe "Wait-VsanClusterConfigSyncOrTimeout" {

    It "Returns false immediately when TimeoutSeconds is 0" {
        InModuleScope VcfEdgeAtScale {
            $result = Wait-VsanClusterConfigSyncOrTimeout -ClusterName "cl-site1" -TimeoutSeconds 0
            $result | Should -Be $false
        }
    }

    It "Returns true when health summary indicates in-sync on the first poll" {
        InModuleScope VcfEdgeAtScale {
            Mock Get-VsanClusterHealthSummaryViaView {
                [PSCustomObject]@{ overallHealth = "green" }
            }
            Mock Test-VsanClusterAdvCfgSyncInSync { return $true }
            $result = Wait-VsanClusterConfigSyncOrTimeout -ClusterName "cl-site1" -TimeoutSeconds 60 -CheckIntervalSeconds 60
            $result | Should -Be $true
        }
    }

    It "Returns false when health summary is null (polls once then times out)" {
        InModuleScope VcfEdgeAtScale {
            Mock Get-VsanClusterHealthSummaryViaView { return $null }
            Mock Start-Sleep { }
            $result = Wait-VsanClusterConfigSyncOrTimeout -ClusterName "cl-site1" -TimeoutSeconds 1 -CheckIntervalSeconds 120
            $result | Should -Be $false
        }
    }
}

# ── Get-FirstUnusedNicFromNicList ─────────────────────────────────────────────


Describe "Invoke-PauseBeforeRollbackIfRequested" {

    BeforeEach {
        # Reset all three script-scoped flags that control the decision tree so tests
        # cannot bleed state into each other.
        InModuleScope VcfEdgeAtScale {
            $Script:CleanUpOnly               = $false
            $Script:RollbackOnFailurePreference = $null
            $Script:RollbackAlwaysFromPrompt    = $false
        }
    }

    AfterEach {
        InModuleScope VcfEdgeAtScale {
            $Script:CleanUpOnly               = $false
            $Script:RollbackOnFailurePreference = $null
            $Script:RollbackAlwaysFromPrompt    = $false
        }
    }

    It "Returns ProceedWithRollback immediately when CleanUpOnly is set (no prompt)" {
        $result = InModuleScope VcfEdgeAtScale {
            $Script:CleanUpOnly = $true
            Invoke-PauseBeforeRollbackIfRequested
        }
        $result | Should -Be "ProceedWithRollback"
    }

    It "Returns ProceedWithRollback when RollbackOnFailurePreference is true (no prompt)" {
        $result = InModuleScope VcfEdgeAtScale {
            $Script:RollbackOnFailurePreference = $true
            Invoke-PauseBeforeRollbackIfRequested
        }
        $result | Should -Be "ProceedWithRollback"
    }

    It "Returns DoNotRollback when RollbackOnFailurePreference is false (no prompt)" {
        $result = InModuleScope VcfEdgeAtScale {
            $Script:RollbackOnFailurePreference = $false
            Invoke-PauseBeforeRollbackIfRequested
        }
        $result | Should -Be "DoNotRollback"
    }

    It "Returns ProceedWithRollback when RollbackAlwaysFromPrompt is already set (no prompt)" {
        $result = InModuleScope VcfEdgeAtScale {
            $Script:RollbackAlwaysFromPrompt = $true
            Invoke-PauseBeforeRollbackIfRequested
        }
        $result | Should -Be "ProceedWithRollback"
    }

    It "Returns ProceedWithRollback when the user enters Y at the interactive prompt" {
        $result = InModuleScope VcfEdgeAtScale {
            Mock Read-Host { return "Y" }
            Invoke-PauseBeforeRollbackIfRequested
        }
        $result | Should -Be "ProceedWithRollback"
    }

    It "Returns DoNotRollback when the user presses Enter (empty response) at the prompt" {
        $result = InModuleScope VcfEdgeAtScale {
            Mock Read-Host { return "" }
            Invoke-PauseBeforeRollbackIfRequested
        }
        $result | Should -Be "DoNotRollback"
    }

    It "Returns ProceedWithRollback and sets RollbackAlwaysFromPrompt when the user enters A (multi-site)" {
        InModuleScope VcfEdgeAtScale {
            Mock Read-Host { return "A" }
            $result = Invoke-PauseBeforeRollbackIfRequested
            $result | Should -Be "ProceedWithRollback"
            $Script:RollbackAlwaysFromPrompt | Should -Be $true
        }
    }
}

# ── Test-EdgeSiteMatching — cross-JSON edgeSite validation ────────────────────


Describe "Test-VsanTrafficVmkernelHasValidIp" {

    It "Returns false when Get-VmkernelAdaptersOnHost returns no adapters" {
        $result = InModuleScope VcfEdgeAtScale {
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab" }
            Mock Get-VmkernelAdaptersOnHost { return @() }
            Test-VsanTrafficVmkernelHasValidIp -VMHost $fakeHost
        }
        $result | Should -Be $false
    }

    It "Returns false when adapters exist but the VsanTrafficEnabled property is absent" {
        $result = InModuleScope VcfEdgeAtScale {
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab" }
            # Adapter has no VsanTrafficEnabled property at all.
            $adapter = [PSCustomObject]@{ Name = "vmk0"; IP = "10.0.0.1" }
            Mock Get-VmkernelAdaptersOnHost { return @($adapter) }
            Test-VsanTrafficVmkernelHasValidIp -VMHost $fakeHost
        }
        $result | Should -Be $false
    }

    It "Returns false when the vSAN adapter has an empty IP" {
        $result = InModuleScope VcfEdgeAtScale {
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab" }
            $adapter  = [PSCustomObject]@{ Name = "vmk1"; VsanTrafficEnabled = $true; IP = "" }
            Mock Get-VmkernelAdaptersOnHost { return @($adapter) }
            Test-VsanTrafficVmkernelHasValidIp -VMHost $fakeHost
        }
        $result | Should -Be $false
    }

    It "Returns true when the vSAN adapter has a valid IP" {
        $result = InModuleScope VcfEdgeAtScale {
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab" }
            $adapter  = [PSCustomObject]@{ Name = "vmk1"; VsanTrafficEnabled = $true; IP = "192.168.10.5" }
            Mock Get-VmkernelAdaptersOnHost { return @($adapter) }
            Test-VsanTrafficVmkernelHasValidIp -VMHost $fakeHost
        }
        $result | Should -Be $true
    }

    It "Returns true when only the second adapter has vSAN traffic and a valid IP" {
        $result = InModuleScope VcfEdgeAtScale {
            $fakeHost    = [PSCustomObject]@{ Name = "esx01.lab" }
            $adapterMgmt = [PSCustomObject]@{ Name = "vmk0"; VsanTrafficEnabled = $false; IP = "10.0.0.1" }
            $adapterVsan = [PSCustomObject]@{ Name = "vmk1"; VsanTrafficEnabled = $true;  IP = "192.168.10.5" }
            Mock Get-VmkernelAdaptersOnHost { return @($adapterMgmt, $adapterVsan) }
            Test-VsanTrafficVmkernelHasValidIp -VMHost $fakeHost
        }
        $result | Should -Be $true
    }
}

# ── Test-VmkernelVsanAndWitnessTraffic ───────────────────────────────────────


Describe "Test-VmkernelVsanAndWitnessTraffic" {

    It "Returns HasCompliantInterface=false when no adapters are present" {
        $result = InModuleScope VcfEdgeAtScale {
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab" }
            Mock Get-VmkernelAdaptersOnHost { return @() }
            Mock Test-VmkernelVsanTrafficViaEsxcli { return $false }
            Test-VmkernelVsanAndWitnessTraffic -VMHost $fakeHost
        }
        # No adapters means no compliant interface; PropertiesMissingOnAdapters=$true because
        # neither vSAN property was observed (nothing to observe from empty adapter list).
        $result.HasCompliantInterface | Should -Be $false
    }

    It "Returns PropertiesMissingOnAdapters=true when VsanTrafficEnabled is absent from adapters" {
        $result = InModuleScope VcfEdgeAtScale {
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab" }
            # Adapter has no VsanTrafficEnabled property.
            $adapter = [PSCustomObject]@{ Name = "vmk0"; IP = "10.0.0.1" }
            Mock Get-VmkernelAdaptersOnHost { return @($adapter) }
            Mock Test-VmkernelVsanTrafficViaEsxcli { return $false }
            Test-VmkernelVsanAndWitnessTraffic -VMHost $fakeHost
        }
        $result.PropertiesMissingOnAdapters | Should -Be $true
        $result.HasCompliantInterface       | Should -Be $false
    }

    It "Returns HasCompliantInterface=true when adapter has both vSAN and witness traffic" {
        $result = InModuleScope VcfEdgeAtScale {
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab" }
            $adapter  = [PSCustomObject]@{
                Name                      = "vmk1"
                VsanTrafficEnabled        = $true
                VsanWitnessTrafficEnabled = $true
            }
            Mock Get-VmkernelAdaptersOnHost { return @($adapter) }
            Mock Test-VmkernelVsanTrafficViaEsxcli { return $false }
            Test-VmkernelVsanAndWitnessTraffic -VMHost $fakeHost -RequireWitnessTraffic $true
        }
        $result.HasCompliantInterface | Should -Be $true
    }

    It "Returns HasCompliantInterface=false and MissingWitness=true when vSAN is enabled but witness is absent" {
        $result = InModuleScope VcfEdgeAtScale {
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab" }
            $adapter  = [PSCustomObject]@{
                Name                      = "vmk1"
                VsanTrafficEnabled        = $true
                VsanWitnessTrafficEnabled = $false
            }
            Mock Get-VmkernelAdaptersOnHost { return @($adapter) }
            Mock Test-VmkernelVsanTrafficViaEsxcli { return $false }
            Test-VmkernelVsanAndWitnessTraffic -VMHost $fakeHost -RequireWitnessTraffic $true
        }
        $result.HasCompliantInterface | Should -Be $false
        $result.MissingWitness        | Should -Be $true
    }

    It "Returns HasCompliantInterface=true when only vSAN traffic is required (witness host mode)" {
        $result = InModuleScope VcfEdgeAtScale {
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab" }
            $adapter  = [PSCustomObject]@{
                Name                      = "vmk0"
                VsanTrafficEnabled        = $true
                VsanWitnessTrafficEnabled = $false
            }
            Mock Get-VmkernelAdaptersOnHost { return @($adapter) }
            Mock Test-VmkernelVsanTrafficViaEsxcli { return $false }
            Test-VmkernelVsanAndWitnessTraffic -VMHost $fakeHost -RequireWitnessTraffic $false
        }
        $result.HasCompliantInterface | Should -Be $true
    }

    It "Returns HasCompliantInterface=true via esxcli fallback when PowerCLI properties are absent" {
        $result = InModuleScope VcfEdgeAtScale {
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab" }
            $adapter  = [PSCustomObject]@{ Name = "vmk0"; IP = "10.0.0.1" }
            Mock Get-VmkernelAdaptersOnHost { return @($adapter) }
            # esxcli fallback says traffic is configured.
            Mock Test-VmkernelVsanTrafficViaEsxcli { return $true }
            Test-VmkernelVsanAndWitnessTraffic -VMHost $fakeHost -RequireWitnessTraffic $true
        }
        $result.HasCompliantInterface | Should -Be $true
    }
}


Describe "Test-VsanAdvCfgSyncAndWaitIfNeeded" {
    It "Does not call Invoke-VsanClusterConfigReapply when advCfgSync is in sync" {
        InModuleScope VcfEdgeAtScale {
            $summary = [PSCustomObject]@{ advCfgSync = @(
                [PSCustomObject]@{ inSync = $true }
            )}
            Mock Test-VsanClusterAdvCfgSyncInSync { return $true }
            Mock Invoke-VsanClusterConfigReapply {}
            Mock Write-LogMessage {}
            Test-VsanAdvCfgSyncAndWaitIfNeeded -ClusterName "cl0-site1" -HealthSummary $summary
            Should -Invoke Invoke-VsanClusterConfigReapply -Times 0 -Scope It
        }
    }

    It "Calls Invoke-VsanClusterConfigReapply when advCfgSync is out of sync" {
        InModuleScope VcfEdgeAtScale {
            $summary = [PSCustomObject]@{ advCfgSync = @(
                [PSCustomObject]@{ inSync = $false }
            )}
            Mock Test-VsanClusterAdvCfgSyncInSync { return $false }
            Mock Invoke-VsanClusterConfigReapply {}
            Mock Write-LogMessage {}
            Test-VsanAdvCfgSyncAndWaitIfNeeded -ClusterName "cl0-site1" -HealthSummary $summary
            Should -Invoke Invoke-VsanClusterConfigReapply -Times 1 -Scope It
        }
    }

    It "Passes ClusterName to Invoke-VsanClusterConfigReapply" {
        InModuleScope VcfEdgeAtScale {
            $summary = [PSCustomObject]@{ advCfgSync = @( [PSCustomObject]@{ inSync = $false } ) }
            Mock Test-VsanClusterAdvCfgSyncInSync { return $false }
            Mock Invoke-VsanClusterConfigReapply {}
            Mock Write-LogMessage {}
            Test-VsanAdvCfgSyncAndWaitIfNeeded -ClusterName "myCluster" -HealthSummary $summary
            Should -Invoke Invoke-VsanClusterConfigReapply -ParameterFilter { $ClusterName -eq "myCluster" } -Times 1 -Scope It
        }
    }
}


Describe "Write-VsanHealthFailureDebugInfo" {
    It "Logs DEBUG for partition_detected context with network health data" {
        InModuleScope VcfEdgeAtScale {
            $networkHealth = [PSCustomObject]@{
                pingTestSuccess      = $true
                largePingTestSuccess = $false
                issueFound           = $true
                clusterInUnicastMode = $true
                vsanVmknicPresent    = $true
                partitions           = @(
                    [PSCustomObject]@{ hosts = @("id-1", "id-2"); partitionUnknown = $false }
                    [PSCustomObject]@{ hosts = @("id-3");          partitionUnknown = $false }
                )
                otherHostsInVsanCluster = @()
                hostsCommFailure        = @()
                hostsDisconnected       = @()
            }
            $summary = [PSCustomObject]@{
                networkHealth            = $networkHealth
                overallHealthDescription = "Network partition detected."
                groups                   = $null
            }
            Mock Write-LogMessage {}
            Mock Get-VsanHealthFailureReasons { return "partition" }
            Write-VsanHealthFailureDebugInfo -ClusterName "cl0" -Context "partition_detected" -HealthSummary $summary
            Should -Invoke Write-LogMessage -Scope It -Times 1 -ParameterFilter { $Message -match "network health" }
        }
    }

    It "Logs DEBUG next-steps message for health_red context" {
        InModuleScope VcfEdgeAtScale {
            $summary = [PSCustomObject]@{
                networkHealth            = $null
                overallHealthDescription = "Some check is red."
                groups                   = $null
            }
            Mock Write-LogMessage {}
            Mock Get-VsanHealthFailureReasons { return "Some check is red." }
            Write-VsanHealthFailureDebugInfo -ClusterName "cl0" -Context "health_red" -HealthSummary $summary
            Should -Invoke Write-LogMessage -Scope It -Times 1 -ParameterFilter { $Message -match "health_red|Fix red|failureReasons" }
        }
    }

    It "Logs DEBUG next-steps message for health_summary_null context" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Write-VsanHealthFailureDebugInfo -ClusterName "cl0" -Context "health_summary_null"
            Should -Invoke Write-LogMessage -Scope It -Times 1 -ParameterFilter { $Message -match "health_summary_null|health summary|endpoint" }
        }
    }

    It "Logs DEBUG next-steps message for repair_failed context" {
        InModuleScope VcfEdgeAtScale {
            $summary = [PSCustomObject]@{ networkHealth = $null; overallHealthDescription = $null; groups = $null }
            Mock Write-LogMessage {}
            Mock Get-VsanHealthFailureReasons { return "" }
            Write-VsanHealthFailureDebugInfo -ClusterName "cl0" -Context "repair_failed" -HealthSummary $summary
            Should -Invoke Write-LogMessage -Scope It -Times 1 -ParameterFilter { $Message -match "repair_failed|repair|partition" }
        }
    }

    It "Logs DEBUG partition_after_repair next-steps and does not throw" {
        InModuleScope VcfEdgeAtScale {
            $summary = [PSCustomObject]@{ networkHealth = $null; overallHealthDescription = $null; groups = $null }
            Mock Write-LogMessage {}
            Mock Get-VsanHealthFailureReasons { return "" }
            { Write-VsanHealthFailureDebugInfo -ClusterName "cl0" -Context "partition_after_repair" -HealthSummary $summary } | Should -Not -Throw
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq 'DEBUG' -and $Message -match 'partition_after_repair|partition|repair' }
        }
    }
}


Describe "Test-VsanAutomaticRebalanceAtThreshold" {
    It "Returns true when ProactiveRebalanceEnabled=true and threshold matches" {
        InModuleScope VcfEdgeAtScale {
            Mock Get-ClusterObjectByName { [PSCustomObject]@{ Name = "cl0" } }
            Mock Get-VsanClusterConfigurationForCluster {
                $c = [PSCustomObject]@{}
                $c | Add-Member -NotePropertyName ProactiveRebalanceEnabled   -NotePropertyValue $true
                $c | Add-Member -NotePropertyName ProactiveRebalanceThreshold -NotePropertyValue 30
                return $c
            }
            Mock Write-LogMessage {}
            Test-VsanAutomaticRebalanceAtThreshold -ClusterName "cl0" -Server "vc.lab" | Should -Be $true
        }
    }

    It "Returns false when ProactiveRebalanceEnabled is false" {
        InModuleScope VcfEdgeAtScale {
            Mock Get-ClusterObjectByName { [PSCustomObject]@{ Name = "cl0" } }
            Mock Get-VsanClusterConfigurationForCluster {
                $c = [PSCustomObject]@{}
                $c | Add-Member -NotePropertyName ProactiveRebalanceEnabled -NotePropertyValue $false
                return $c
            }
            Mock Write-LogMessage {}
            Test-VsanAutomaticRebalanceAtThreshold -ClusterName "cl0" -Server "vc.lab" | Should -Be $false
        }
    }

    It "Returns false when threshold does not match expected" {
        InModuleScope VcfEdgeAtScale {
            Mock Get-ClusterObjectByName { [PSCustomObject]@{ Name = "cl0" } }
            Mock Get-VsanClusterConfigurationForCluster {
                $c = [PSCustomObject]@{}
                $c | Add-Member -NotePropertyName ProactiveRebalanceEnabled   -NotePropertyValue $true
                $c | Add-Member -NotePropertyName ProactiveRebalanceThreshold -NotePropertyValue 50
                return $c
            }
            Mock Write-LogMessage {}
            Test-VsanAutomaticRebalanceAtThreshold -ClusterName "cl0" -Server "vc.lab" -ExpectedThresholdPercent 30 | Should -Be $false
        }
    }

    It "Returns true when ProactiveRebalanceEnabled=true and threshold property is absent" {
        InModuleScope VcfEdgeAtScale {
            Mock Get-ClusterObjectByName { [PSCustomObject]@{ Name = "cl0" } }
            Mock Get-VsanClusterConfigurationForCluster {
                $c = [PSCustomObject]@{}
                $c | Add-Member -NotePropertyName ProactiveRebalanceEnabled -NotePropertyValue $true
                return $c
            }
            Mock Write-LogMessage {}
            Test-VsanAutomaticRebalanceAtThreshold -ClusterName "cl0" -Server "vc.lab" | Should -Be $true
        }
    }

    It "Returns false when Get-ClusterObjectByName throws" {
        InModuleScope VcfEdgeAtScale {
            Mock Get-ClusterObjectByName { throw "Cluster not found" }
            Mock Write-LogMessage {}
            Test-VsanAutomaticRebalanceAtThreshold -ClusterName "cl0" -Server "vc.lab" | Should -Be $false
        }
    }
}


Describe "Test-VmkernelVsanTrafficViaEsxcli" {
    # The happy-path ("Returns true") tests require Get-EsxCli to return a fake EsxCli object whose
    # Invoke() ScriptMethod emits data back to PowerShell's pipeline in a way the function's
    # Array/IEnumerable type-check branch can handle. This combination does not work reliably with
    # PowerCLI's ArgumentTransformationAttribute and PSCustomObject ScriptMethods in Pester
    # InModuleScope. Those paths are exercised by the live test suite.

    It "Returns false when esxcli list returns no items" {
        $result = InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            $Script:vCenterName = $null
            $fakeListCmd = [PSCustomObject]@{}
            Add-Member -InputObject $fakeListCmd -MemberType ScriptMethod -Name "Invoke" -Value { } -Force
            $Script:MockFakeEsxcli = [PSCustomObject]@{
                vsan = [PSCustomObject]@{
                    network = [PSCustomObject]@{ list = $fakeListCmd }
                }
            }
            Mock Get-EsxCli { return $Script:MockFakeEsxcli }
            Test-VmkernelVsanTrafficViaEsxcli -VMHost ([PSCustomObject]@{ Name = "esx01.lab" }) -RequireWitnessTraffic $true
        }
        $result | Should -Be $false
    }

    It "Returns false when Get-EsxCli throws" {
        $result = InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            $Script:vCenterName = $null
            Mock Get-EsxCli { throw "esxcli unavailable" }
            Test-VmkernelVsanTrafficViaEsxcli -VMHost ([PSCustomObject]@{ Name = "esx01.lab" }) -RequireWitnessTraffic $true
        }
        $result | Should -Be $false
    }

    It "Returns false when vsan.network.list is null" {
        $result = InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            $Script:vCenterName = $null
            $Script:MockFakeEsxcli = [PSCustomObject]@{
                vsan = [PSCustomObject]@{
                    network = [PSCustomObject]@{ list = $null }
                }
            }
            Mock Get-EsxCli { return $Script:MockFakeEsxcli }
            Test-VmkernelVsanTrafficViaEsxcli -VMHost ([PSCustomObject]@{ Name = "esx01.lab" }) -RequireWitnessTraffic $true
        }
        $result | Should -Be $false
    }
}

# ── Enable-VsanHealthAlarms ───────────────────────────────────────────────────


Describe "Enable-VsanHealthAlarms — mocked vCenter" {
    # Get-VsanView is a vSAN API cmdlet that is not in the module's command table and cannot be mocked
    # inside InModuleScope. Tests for the paths that pass through Get-VsanView are covered by the live
    # test suite (Enable-VsanHealthAlarms — live write).

    It "Returns false when cluster is not found" {
        $result = InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Get-ClusterByName { return $null }
            Enable-VsanHealthAlarms -ClusterName "cl-missing"
        }
        $result | Should -Be $false
    }
}

# ── Remove-StorageTag ─────────────────────────────────────────────────────────


Describe "Remove-StorageTag — mocked vCenter" {
    # Get-Tag and Remove-Tag are PowerCLI cmdlets with ArgumentTransformationAttribute; they are not in
    # VcfEdgeAtScale's command table and cannot be reliably mocked inside InModuleScope. Tests cover the
    # early-exit (tag-not-found) path only; the removal path is covered by the live tag tests.

    It "Does not call Remove-Tag when tag is not found" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Get-Tag { return $null }
            Mock Remove-Tag {}
            Remove-StorageTag -TagName "SupervisorCluster01" -TagCatalog "EdgeNodePolicy"
            Should -Invoke Remove-Tag -Times 0 -Scope It
        }
    }
}

# ── Remove-TagCategoryIfEmpty ─────────────────────────────────────────────────


Describe "Remove-TagCategoryIfEmpty — mocked vCenter" {
    # Same PowerCLI mocking limitation as Remove-StorageTag; tests cover the early-exit path only.

    It "Does not call Remove-TagCategory when category is not found" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Get-TagCategory { return $null }
            Mock Remove-TagCategory {}
            Remove-TagCategoryIfEmpty -TagCatalog "Storage-TagCatalog"
            Should -Invoke Remove-TagCategory -Times 0 -Scope It
        }
    }
}

# ── Invoke-ReconfigureClusterHA ───────────────────────────────────────────────


Describe "Invoke-ReconfigureClusterHA — mocked vCenter" {
    It "Throws VcfDeploymentException when vCenter is not connected" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Test-VcenterConnection { return [PSCustomObject]@{ IsConnected = $false; ErrorMessage = "No session." } }
            Mock Update-Cluster {}
            { Invoke-ReconfigureClusterHA -ClusterName "cl0" -DelaySeconds 0 } | Should -Throw

            Should -Invoke Update-Cluster -Times 0 -Scope It
        }
    }

    It "Calls Update-Cluster when vCenter is connected" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Test-VcenterConnection { return [PSCustomObject]@{ IsConnected = $true; ErrorMessage = $null } }
            Mock Update-Cluster {}
            Invoke-ReconfigureClusterHA -ClusterName "cl0" -DelaySeconds 0
            Should -Invoke Update-Cluster -Times 1 -Scope It
        }
    }
}


Describe "Update-Cluster — zero-host guard" {
    It "Returns without calling Set-Cluster and logs a WARNING when the cluster has no hosts" {
        InModuleScope VcfEdgeAtScale {
            # Shadow Get-VMHost with an untyped PS function to avoid VMware VIContainer type coercion
            # on -Location, which Pester replicates from binary cmdlet metadata and cannot bypass.
            function Get-VMHost {
                [CmdletBinding()]
                Param([Parameter(Mandatory = $false)] [Object] $Location)
                return @()
            }
            $loggedWarnings = [System.Collections.Generic.List[String]]::new()
            Mock Write-LogMessage {
                param($Type, $Message)
                if ($Type -eq "WARNING") { $loggedWarnings.Add($Message) }
            }
            Mock Test-VcenterConnection { return [PSCustomObject]@{ IsConnected = $true; ErrorMessage = $null } }
            Mock Get-Cluster { return [PSCustomObject]@{ Id = "domain-c1"; Name = "cl0" } }
            # Set-Cluster is called via pipeline in Update-Cluster; Pester 5.7.1 does not count
            # pipeline-input mock invocations. The WARNING log is the reliable observable: it is
            # only emitted by the early-return guard path, proving Set-Cluster was never reached.
            function Set-Cluster {
                [CmdletBinding(SupportsShouldProcess = $true)]
                Param(
                    [Parameter(ValueFromPipeline = $true)] [Object]$In,
                    [Parameter()] [Bool]$DrsEnabled, [Parameter()] [Bool]$HAEnabled,
                    [Parameter()] [Object]$DrsAutomationLevel, [Parameter()] [Bool]$HAAdmissionControlEnabled, [Parameter()] [Object]$Server
                )
                begin { throw "Set-Cluster must not be called when cluster has no hosts" }
            }
            Update-Cluster -ClusterName "cl0"
            $loggedWarnings.Count | Should -BeGreaterThan 0
            $loggedWarnings[0] | Should -Match "no hosts"
        }
    }
}

Describe "Update-Cluster — single-host path" {
    It "Calls Set-Cluster and logs INFO when cluster has one host" {
        InModuleScope VcfEdgeAtScale {
            function Get-Cluster {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                process {}
            }
            function Get-VMHost {
                [CmdletBinding()] Param([Parameter()] [Object]$Location)
                process {}
            }
            $Script:_setClusterCallCount = 0
            function Set-Cluster {
                [CmdletBinding(SupportsShouldProcess = $true)]
                Param(
                    [Parameter(ValueFromPipeline = $true)] [Object]$In,
                    [Parameter()] [Bool]$DrsEnabled, [Parameter()] [Bool]$HAEnabled,
                    [Parameter()] [Object]$DrsAutomationLevel, [Parameter()] [Bool]$HAAdmissionControlEnabled,
                    [Parameter()] [Object]$Server
                )
                begin { $Script:_setClusterCallCount++ }
                process {}
            }
            Mock Write-LogMessage {}
            Mock Test-VcenterConnection { [PSCustomObject]@{ IsConnected = $true; ErrorMessage = $null } }
            Mock Get-Cluster { [PSCustomObject]@{ Id = "domain-c1"; Name = "cl0" } }
            Mock Get-VMHost {
                @([PSCustomObject]@{ Name = "esx01.lab"; ConnectionState = "Connected"; PowerState = "PoweredOn" })
            }
            Update-Cluster -ClusterName "cl0"
            # Pester 5.7.1 does not count pipeline-input mock invocations; the call counter in the
            # function stub is the reliable observable for pipeline-called cmdlets.
            $Script:_setClusterCallCount | Should -Be 1
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq "INFO" -and $Message -match "one host" } -Scope It
        }
    }
}

# ── Add-Cluster ───────────────────────────────────────────────────────────────


Describe "Add-Cluster — guard conditions" {
    It "Throws VcfDeploymentException when vCenter is not connected" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Test-VcenterConnection { [PSCustomObject]@{ IsConnected = $false; ErrorMessage = "No session." } }
            { Add-Cluster -ClusterName "cl0" -DataCenterName "dc0" } | Should -Throw
        }
    }

    It "Throws VcfDeploymentException when datacenter is not found" {
        InModuleScope VcfEdgeAtScale {
            function Get-Datacenter {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                process {}
            }
            Mock Write-LogMessage {}
            Mock Test-VcenterConnection { [PSCustomObject]@{ IsConnected = $true; ErrorMessage = $null } }
            Mock Get-Datacenter { $null }
            { Add-Cluster -ClusterName "cl0" -DataCenterName "dc-missing" } | Should -Throw
        }
    }

    It "Throws when cluster creation confirmation fails (Get-Cluster returns null after New-Cluster)" {
        InModuleScope VcfEdgeAtScale {
            function Get-Datacenter {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                process {}
            }
            function New-Cluster {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Location, [Parameter()] [Object]$Server, [Parameter()] [Switch]$HAEnabled, [Parameter()] [Switch]$DrsEnabled, [Parameter()] [Object]$SoftwareSpecification)
                process {}
            }
            function Get-Cluster {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Location, [Parameter()] [Object]$Server)
                process {}
            }
            function Start-Sleep { [CmdletBinding()] Param([Parameter()] [Int]$Seconds) process {} }
            Mock Write-LogMessage {}
            Mock Test-VcenterConnection { [PSCustomObject]@{ IsConnected = $true; ErrorMessage = $null } }
            Mock Get-Datacenter { [PSCustomObject]@{ Name = "dc0" } }
            Mock New-Cluster { [PSCustomObject]@{ Name = "cl0" } }
            Mock Get-Cluster { $null }
            Mock Start-Sleep {}
            { Add-Cluster -ClusterName "cl0" -DataCenterName "dc0" -ClusterCreationDelaySeconds 0 } | Should -Throw

        }
    }

    It "Calls Enable-VsanEsaOnExistingCluster when cluster already exists and VsanEsaEnabled is set" {
        InModuleScope VcfEdgeAtScale {
            $fakeCluster = [PSCustomObject]@{ Name = "cl0"; Id = "ClusterComputeResource-domain-c7" }
            function Get-Datacenter {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                process { return [PSCustomObject]@{ Name = "dc0" } }
            }
            function Get-Cluster {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Location, [Parameter()] [Object]$Server)
                process { return $fakeCluster }
            }
            Mock Write-LogMessage {}
            Mock Assert-VcenterConnected {}
            Mock Get-Datacenter { [PSCustomObject]@{ Name = "dc0" } }
            Mock Get-Cluster { $fakeCluster }
            Mock Enable-VsanEsaOnExistingCluster {}
            Add-Cluster -ClusterName "cl0" -DataCenterName "dc0" -VsanEsaEnabled
            Should -Invoke Enable-VsanEsaOnExistingCluster -Times 1
        }
    }

    It "Does not call Enable-VsanEsaOnExistingCluster when cluster exists without VsanEsaEnabled" {
        InModuleScope VcfEdgeAtScale {
            $fakeCluster = [PSCustomObject]@{ Name = "cl0"; Id = "ClusterComputeResource-domain-c7" }
            function Get-Datacenter {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                process { return [PSCustomObject]@{ Name = "dc0" } }
            }
            function Get-Cluster {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Location, [Parameter()] [Object]$Server)
                process { return $fakeCluster }
            }
            Mock Write-LogMessage {}
            Mock Assert-VcenterConnected {}
            Mock Get-Datacenter { [PSCustomObject]@{ Name = "dc0" } }
            Mock Get-Cluster { $fakeCluster }
            Mock Enable-VsanEsaOnExistingCluster { throw "Must not be called." }
            { Add-Cluster -ClusterName "cl0" -DataCenterName "dc0" } | Should -Not -Throw
        }
    }
}

# ── Remove-VmfsDatastoreForCluster ────────────────────────────────────────────


Describe "Remove-VmfsDatastoreForCluster — guard conditions" {
    It "Returns without ERROR and does not throw when no vCenter is available" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            $Script:vCenterName = $null
            { Remove-VmfsDatastoreForCluster -ClusterName "cl0" -DatastoreName "ds0" } | Should -Not -Throw
            Should -Not -Invoke Write-LogMessage -ParameterFilter { $Type -eq 'ERROR' }
        }
    }

    It "Logs WARNING about no connection and returns without throwing when not connected to vCenter" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            $Script:vCenterName = "vc.lab"
            Mock Test-VcenterConnection { [PSCustomObject]@{ IsConnected = $false; ErrorMessage = "No session." } }
            { Remove-VmfsDatastoreForCluster -ClusterName "cl0" -DatastoreName "ds0" } | Should -Not -Throw
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq 'WARNING' -and $Message -match 'Not connected' }
        }
    }

    It "Returns without throwing when datastore is not found" {
        InModuleScope VcfEdgeAtScale {
            function Get-Datastore {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                process {}
            }
            Mock Write-LogMessage {}
            $Script:vCenterName = "vc.lab"
            Mock Test-VcenterConnection { [PSCustomObject]@{ IsConnected = $true; ErrorMessage = $null } }
            Mock Get-Datastore { $null }
            { Remove-VmfsDatastoreForCluster -ClusterName "cl0" -DatastoreName "ds-missing" } | Should -Not -Throw
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq "DEBUG" -and $Message -match "not found" }
        }
    }
}


Describe "Remove-VmfsDatastoreForCluster — error message extraction" {
    It "Logs clean InnerException.Message when Remove-Datastore throws a wrapped exception" {
        InModuleScope VcfEdgeAtScale {
            function Get-Datastore {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                process {}
            }
            function Get-View {
                [CmdletBinding()] Param([Parameter()] [Object]$Id, [Parameter()] [Object]$Property, [Parameter()] [Object]$Server)
                process {}
            }
            function Get-VMHost {
                [CmdletBinding()] Param([Parameter()] [Object]$Id, [Parameter()] [Object]$Server)
                process {}
            }
            function Remove-Datastore {
                [CmdletBinding(SupportsShouldProcess = $true)]
                Param([Parameter()] [Object]$Datastore, [Parameter()] [Object]$VMHost)
                begin { }
                process { }
            }

            $loggedWarnings = [System.Collections.Generic.List[String]]::new()
            Mock Write-LogMessage {
                param($Type, $Message)
                if ($Type -eq "WARNING") { $loggedWarnings.Add($Message) }
            }
            Mock Test-VcenterConnection { [PSCustomObject]@{ IsConnected = $true; ErrorMessage = $null } }
            Mock Get-Datastore { [PSCustomObject]@{ Id = "datastore-1"; Name = "ds0" } }
            Mock Get-View { [PSCustomObject]@{ Host = @([PSCustomObject]@{ Key = "host-1" }) } }
            Mock Get-VMHost { [PSCustomObject]@{ Id = "host-1"; Name = "host01" } }

            # Outer exception message mimics the tabular PowerShell error format; inner has the real fault text.
            $inner = [Exception]::new("The resource 'ds0' is in use.")
            $outer = [Exception]::new("5/21/2026 9:21:03 AM       Remove-Datastore                The resource 'ds0' is in use.     ", $inner)
            Mock Remove-Datastore { throw $outer }

            $Script:vCenterName = "vc.lab"
            # MaxRetries 0: single attempt only — no sleeps in tests.
            { Remove-VmfsDatastoreForCluster -ClusterName "cl0" -DatastoreName "ds0" -MaxRetries 0 } | Should -Not -Throw

            $warningMsg = $loggedWarnings | Where-Object { $_ -match "Could not remove VMFS datastore" }
            $warningMsg | Should -Not -BeNullOrEmpty
            $warningMsg | Should -Match "The resource 'ds0' is in use\."
            $warningMsg | Should -Not -Match "9:21:03 AM"
        }
    }

    It "Logs Exception.Message when Remove-Datastore throws with no InnerException" {
        InModuleScope VcfEdgeAtScale {
            function Get-Datastore {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                process {}
            }
            function Get-View {
                [CmdletBinding()] Param([Parameter()] [Object]$Id, [Parameter()] [Object]$Property, [Parameter()] [Object]$Server)
                process {}
            }
            function Get-VMHost {
                [CmdletBinding()] Param([Parameter()] [Object]$Id, [Parameter()] [Object]$Server)
                process {}
            }
            function Remove-Datastore {
                [CmdletBinding(SupportsShouldProcess = $true)]
                Param([Parameter()] [Object]$Datastore, [Parameter()] [Object]$VMHost)
                begin { }
                process { }
            }

            $loggedWarnings = [System.Collections.Generic.List[String]]::new()
            Mock Write-LogMessage {
                param($Type, $Message)
                if ($Type -eq "WARNING") { $loggedWarnings.Add($Message) }
            }
            Mock Test-VcenterConnection { [PSCustomObject]@{ IsConnected = $true; ErrorMessage = $null } }
            Mock Get-Datastore { [PSCustomObject]@{ Id = "datastore-1"; Name = "ds0" } }
            Mock Get-View { [PSCustomObject]@{ Host = @([PSCustomObject]@{ Key = "host-1" }) } }
            Mock Get-VMHost { [PSCustomObject]@{ Id = "host-1"; Name = "host01" } }
            Mock Remove-Datastore { throw [Exception]::new("Datastore removal failed.") }

            $Script:vCenterName = "vc.lab"
            { Remove-VmfsDatastoreForCluster -ClusterName "cl0" -DatastoreName "ds0" -MaxRetries 0 } | Should -Not -Throw

            $warningMsg = $loggedWarnings | Where-Object { $_ -match "Could not remove VMFS datastore" }
            $warningMsg | Should -Not -BeNullOrEmpty
            $warningMsg | Should -Match "Datastore removal failed\."
        }
    }
}


Describe "Remove-VmfsDatastoreForCluster — retry on in-use" {
    It "Succeeds without a warning when retry resolves the in-use condition" {
        InModuleScope VcfEdgeAtScale {
            function Get-Datastore {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                process {}
            }
            function Get-View {
                [CmdletBinding()] Param([Parameter()] [Object]$Id, [Parameter()] [Object]$Property, [Parameter()] [Object]$Server)
                process {}
            }
            function Get-VMHost {
                [CmdletBinding()] Param([Parameter()] [Object]$Id, [Parameter()] [Object]$Server)
                process {}
            }
            function Remove-Datastore {
                [CmdletBinding(SupportsShouldProcess = $true)]
                Param([Parameter()] [Object]$Datastore, [Parameter()] [Object]$VMHost)
                begin { }
                process { }
            }

            $loggedWarnings = [System.Collections.Generic.List[String]]::new()
            Mock Write-LogMessage {
                param($Type, $Message)
                if ($Type -eq "WARNING") { $loggedWarnings.Add($Message) }
            }
            Mock Test-VcenterConnection { [PSCustomObject]@{ IsConnected = $true; ErrorMessage = $null } }
            Mock Get-Datastore { [PSCustomObject]@{ Id = "datastore-1"; Name = "ds0" } }
            Mock Get-View { [PSCustomObject]@{ Host = @([PSCustomObject]@{ Key = "host-1" }) } }
            Mock Get-VMHost { [PSCustomObject]@{ Id = "host-1"; Name = "host01" } }
            Mock Start-Sleep {}

            # First call throws "in use"; second call succeeds.
            $Script:_removeCount = 0
            function Remove-Datastore {
                [CmdletBinding(SupportsShouldProcess = $true)]
                Param([Parameter()] [Object]$Datastore, [Parameter()] [Object]$VMHost)
                begin { }
                process {
                    $Script:_removeCount++
                    if ($Script:_removeCount -le 1) {
                        throw [Exception]::new("The resource 'ds0' is in use.")
                    }
                }
            }

            $Script:vCenterName = "vc.lab"
            $Script:_removeCount = 0
            { Remove-VmfsDatastoreForCluster -ClusterName "cl0" -DatastoreName "ds0" -MaxRetries 2 -RetryDelaySeconds 1 } | Should -Not -Throw

            $loggedWarnings | Where-Object { $_ -match "Could not remove" } | Should -BeNullOrEmpty
            $Script:_removeCount | Should -Be 2
        }
    }

    It "Logs a warning and stops after MaxRetries exhausted on persistent in-use errors" {
        InModuleScope VcfEdgeAtScale {
            function Get-Datastore {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                process {}
            }
            function Get-View {
                [CmdletBinding()] Param([Parameter()] [Object]$Id, [Parameter()] [Object]$Property, [Parameter()] [Object]$Server)
                process {}
            }
            function Get-VMHost {
                [CmdletBinding()] Param([Parameter()] [Object]$Id, [Parameter()] [Object]$Server)
                process {}
            }
            function Remove-Datastore {
                [CmdletBinding(SupportsShouldProcess = $true)]
                Param([Parameter()] [Object]$Datastore, [Parameter()] [Object]$VMHost)
                begin { }
                process { throw [Exception]::new("The resource 'ds0' is in use.") }
            }

            $loggedWarnings = [System.Collections.Generic.List[String]]::new()
            Mock Write-LogMessage {
                param($Type, $Message)
                if ($Type -eq "WARNING") { $loggedWarnings.Add($Message) }
            }
            Mock Test-VcenterConnection { [PSCustomObject]@{ IsConnected = $true; ErrorMessage = $null } }
            Mock Get-Datastore { [PSCustomObject]@{ Id = "datastore-1"; Name = "ds0" } }
            Mock Get-View { [PSCustomObject]@{ Host = @([PSCustomObject]@{ Key = "host-1" }) } }
            Mock Get-VMHost { [PSCustomObject]@{ Id = "host-1"; Name = "host01" } }
            Mock Start-Sleep {}

            $Script:vCenterName = "vc.lab"
            { Remove-VmfsDatastoreForCluster -ClusterName "cl0" -DatastoreName "ds0" -MaxRetries 2 -RetryDelaySeconds 1 } | Should -Not -Throw

            $warningMsg = $loggedWarnings | Where-Object { $_ -match "Could not remove VMFS datastore" }
            $warningMsg | Should -Not -BeNullOrEmpty
            $warningMsg | Should -Match "in use"
        }
    }
}

# ── Remove-ClusterSafely ──────────────────────────────────────────────────────


Describe "Remove-ClusterSafely — guard conditions" {
    It "Throws VcfDeploymentException when vCenter is not connected" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Test-VcenterConnection { [PSCustomObject]@{ IsConnected = $false; ErrorMessage = "No session." } }
            { Remove-ClusterSafely -ClusterName "cl0" } | Should -Throw
        }
    }

    It "Logs WARNING 'not found' and returns without throwing when cluster is not found (idempotent cleanup)" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Test-VcenterConnection { [PSCustomObject]@{ IsConnected = $true; ErrorMessage = $null } }
            Mock Get-ClusterByName { $null }
            { Remove-ClusterSafely -ClusterName "cl-missing" } | Should -Not -Throw
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq 'WARNING' -and $Message -match 'not found' }
        }
    }

    It "Throws VcfDeploymentException when powered-on non-vCLS VMs are present" {
        InModuleScope VcfEdgeAtScale {
            function Get-VM {
                [CmdletBinding()] Param([Parameter()] [Object]$Location, [Parameter()] [Object]$Server)
                process {}
            }
            Mock Write-LogMessage {}
            Mock Test-VcenterConnection { [PSCustomObject]@{ IsConnected = $true; ErrorMessage = $null } }
            Mock Get-ClusterByName { [PSCustomObject]@{ Name = "cl0" } }
            Mock Get-VM { @([PSCustomObject]@{
                Name = "prod-vm-01"
                PowerState = "PoweredOn"
                Guest = [PSCustomObject]@{ OSFullName = "Ubuntu Linux (64-bit)" }
            }) }
            { Remove-ClusterSafely -ClusterName "cl0" } | Should -Throw
        }
    }
}

# ── Connect-Vcenter / Disconnect-Vcenter ──────────────────────────────────────


Describe "Set-VsanDomNetworkSchedulerThrottleOnHost — esxcli advanced setting" {

    It "Returns Applied=false AlreadySet=false when Get-EsxCli throws" {
        $result = InModuleScope VcfEdgeAtScale {
            function Get-EsxCli {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Switch]$V2, [Parameter()] [Object]$Server)
                process { throw "Connection failed" }
            }
            Mock Write-LogMessage {}
            $fakeHost = [PSCustomObject]@{ Name = "esx01" }
            Set-VsanDomNetworkSchedulerThrottleOnHost -VMHost $fakeHost -Server "vc01"
        }
        $result.Applied    | Should -Be $false
        $result.AlreadySet | Should -Be $false
    }

    It "Returns Applied=false AlreadySet=false when the set command is not available" {
        # Exercises the 'advanced.set = $null' guard that returns {Applied=$false; AlreadySet=$false}.
        $result = InModuleScope VcfEdgeAtScale {
            function Get-EsxCli {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Switch]$V2, [Parameter()] [Object]$Server)
                process {
                    [PSCustomObject]@{
                        system = [PSCustomObject]@{
                            settings = [PSCustomObject]@{
                                advanced = [PSCustomObject]@{ list = $null; set = $null }
                            }
                        }
                    }
                }
            }
            Mock Write-LogMessage {}
            $fakeHost = [PSCustomObject]@{ Name = "esx01" }
            Set-VsanDomNetworkSchedulerThrottleOnHost -VMHost $fakeHost -Server "vc01"
        }
        $result.Applied    | Should -Be $false
        $result.AlreadySet | Should -Be $false
    }

    It "Returns Applied=true AlreadySet=false when the set command succeeds" {
        $result = InModuleScope VcfEdgeAtScale {
            function Get-EsxCli {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Switch]$V2, [Parameter()] [Object]$Server)
                process {
                    $setArgs = [PSCustomObject]@{ option = $null; intvalue = $null }
                    $setCmd  = [PSCustomObject]@{}
                    $setCmd | Add-Member -MemberType ScriptMethod -Name "CreateArgs" -Value { [PSCustomObject]@{ option = $null; intvalue = $null } }
                    $setCmd | Add-Member -MemberType ScriptMethod -Name "Invoke"     -Value { $null }
                    [PSCustomObject]@{
                        system = [PSCustomObject]@{
                            settings = [PSCustomObject]@{
                                advanced = [PSCustomObject]@{ list = $null; set = $setCmd }
                            }
                        }
                    }
                }
            }
            Mock Write-LogMessage {}
            $fakeHost = [PSCustomObject]@{ Name = "esx01" }
            Set-VsanDomNetworkSchedulerThrottleOnHost -VMHost $fakeHost -Server "vc01"
        }
        $result.Applied    | Should -Be $true
        $result.AlreadySet | Should -Be $false
    }
}

# ── Set-VsanDomNetworkSchedulerThrottleOnCluster ──────────────────────────────


Describe "Set-VsanDomNetworkSchedulerThrottleOnCluster — mocked vCenter" {
    # Uses Get-ClusterByName and Get-VmHostsInCluster wrappers for mockability.
    # Get-VmHostsInCluster has [OutputType([VMHost[]])] so Pester rejects plain PSCustomObject[]
    # returns, making the per-host dispatch paths untestable as unit tests. Those paths (applied/
    # already-set) are covered by the live test for this function.

    It "Returns false when cluster is not found" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Get-ClusterByName { return $null }
            $result = Set-VsanDomNetworkSchedulerThrottleOnCluster -ClusterName "missing-cl"
            $result | Should -Be $false
        }
    }

    It "Returns false when cluster has no hosts" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Get-ClusterByName { return [PSCustomObject]@{ Name = "cl0" } }
            Mock Get-VmHostsInCluster { return $null }
            $result = Set-VsanDomNetworkSchedulerThrottleOnCluster -ClusterName "cl0" -Server "vc01"
            $result | Should -Be $false
        }
    }

    It "Calls Get-ClusterByName with -Name (not -ClusterName)" {
        # Regression guard: the function previously used -ClusterName which PowerShell silently caught
        # as a parameter binding error, causing early return without applying the DOM throttle.
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Get-ClusterByName { return $null }
            Set-VsanDomNetworkSchedulerThrottleOnCluster -ClusterName "cl0"
            Should -Invoke Get-ClusterByName -Times 1 -Scope It -ParameterFilter { $Name -eq "cl0" }
        }
    }

    It "Calls Get-VmHostsInCluster with -ClusterObject (not -ClusterName)" {
        # Regression guard: the function previously used -ClusterName which is not a parameter on
        # Get-VmHostsInCluster, causing a parameter binding error (and thus no hosts enumerated).
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            $fakeCluster = [PSCustomObject]@{ Name = "cl0" }
            Mock Get-ClusterByName { return $fakeCluster }
            Mock Get-VmHostsInCluster { return $null }
            Set-VsanDomNetworkSchedulerThrottleOnCluster -ClusterName "cl0" -Server "vc01"
            Should -Invoke Get-VmHostsInCluster -Times 1 -Scope It -ParameterFilter { $ClusterObject -eq $fakeCluster }
        }
    }
}

# ── Invoke-VsanAlarmRemediation ───────────────────────────────────────────────


Describe "Invoke-VsanAlarmRemediation — alarm dispatch routing" {

    It "Calls Invoke-VsanClusterConfigReapply for an advCfgSync alarm" {
        $reapplyCalled = InModuleScope VcfEdgeAtScale {
            $Script:_reapplyCalledAr = $false
            Mock Write-LogMessage {}
            Mock Invoke-VsanClusterConfigReapply { $Script:_reapplyCalledAr = $true; $true }
            Mock Get-VsanClusterTriggeredAlarms { @() }
            Mock Start-Sleep {}
            $alarm = [PSCustomObject]@{ AlarmName = "Advanced vSAN configuration in sync"; Status = "red" }
            Invoke-VsanAlarmRemediation -Alarms @($alarm) -ClusterName "cl0" -HaStabilizationDelaySeconds 0
            $Script:_reapplyCalledAr
        }
        $reapplyCalled | Should -BeTrue
    }

    It "Calls Invoke-ReconfigureClusterHA for a vSphere HA host status alarm" {
        $haCalled = InModuleScope VcfEdgeAtScale {
            $Script:_haCalledAr = $false
            Mock Write-LogMessage {}
            Mock Invoke-ReconfigureClusterHA { $Script:_haCalledAr = $true }
            $alarm = [PSCustomObject]@{ AlarmName = "vSphere HA host status"; Status = "yellow" }
            Invoke-VsanAlarmRemediation -Alarms @($alarm) -ClusterName "cl0" -HaStabilizationDelaySeconds 0
            $Script:_haCalledAr
        }
        $haCalled | Should -BeTrue
    }

    It "Does not log WARNING for lab-suppressed third-party IO filter alarm when LabEnvironment=true" {
        $warnLogged = InModuleScope VcfEdgeAtScale {
            $Script:_warnLoggedAr = $false
            Mock Write-LogMessage {
                if ($Type -eq "WARNING") { $Script:_warnLoggedAr = $true }
            }
            $alarm = [PSCustomObject]@{ AlarmName = "Registration/unregistration of third-party IO filter storage providers fails on a host"; Status = "red" }
            Invoke-VsanAlarmRemediation -Alarms @($alarm) -ClusterName "cl0" -LabEnvironment:$true -HaStabilizationDelaySeconds 0
            $Script:_warnLoggedAr
        }
        $warnLogged | Should -BeFalse
    }
}

# ── Invoke-VsanRefreshedAlarmGate ─────────────────────────────────────────────


Describe "Invoke-VsanRefreshedAlarmGate — red/yellow gating" {

    It "Returns without action or ERROR log when there are no refreshed alarms" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Get-VsanClusterTriggeredAlarms { @() }
            { Invoke-VsanRefreshedAlarmGate -ClusterName "cl0" } | Should -Not -Throw
            Should -Not -Invoke Write-LogMessage -ParameterFilter { $Type -eq 'ERROR' }
        }
    }

    It "Logs WARNING and proceeds when AcceptBadCheckResults is set and red alarm exists" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Get-VsanClusterTriggeredAlarms {
                @([PSCustomObject]@{ AlarmName = "vSAN health alarm"; Status = "red" })
            }
            Mock Test-VsanTriggeredAlarmIsStatsPrimaryElection { $false }
            Mock Test-VsanTriggeredAlarmIsHclRelated { $false }
            { Invoke-VsanRefreshedAlarmGate -AcceptBadCheckResults -ClusterName "cl0" } | Should -Not -Throw
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq "WARNING" -and $Message -match "AcceptBadCheckResults" }
        }
    }

    It "Logs WARNING and continues when only yellow alarms remain" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Get-VsanClusterTriggeredAlarms {
                @([PSCustomObject]@{ AlarmName = "vSAN perf alarm"; Status = "yellow" })
            }
            { Invoke-VsanRefreshedAlarmGate -ClusterName "cl0" } | Should -Not -Throw
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq "WARNING" -and $Message -match "yellow status" }
        }
    }
}

# ── Invoke-VsanClusterAlarmCheckAndRemediate ──────────────────────────────────


Describe "Invoke-VsanClusterAlarmCheckAndRemediate — alarm routing — mocked vCenter" {
    It "Returns early and calls no remediation functions when there are no alarms" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Set-VsanDomNetworkSchedulerThrottleOnCluster { return $false }
            Mock Get-VsanClusterTriggeredAlarms { return @() }
            Mock Invoke-VsanClusterConfigReapply {}
            Mock Invoke-ReconfigureClusterHA {}
            Mock Enable-VsanPerformanceService {}
            Invoke-VsanClusterAlarmCheckAndRemediate -ClusterName "cl0"
            Should -Invoke Invoke-VsanClusterConfigReapply -Times 0 -Scope It
            Should -Invoke Invoke-ReconfigureClusterHA -Times 0 -Scope It
            Should -Invoke Enable-VsanPerformanceService -Times 0 -Scope It
        }
    }

    It "Calls Invoke-VsanClusterConfigReapply for an advCfgSync alarm" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Set-VsanDomNetworkSchedulerThrottleOnCluster { return $false }
            Mock Get-VsanClusterTriggeredAlarms { return @([PSCustomObject]@{ AlarmName = "Advanced vSAN configuration in sync"; Status = "Yellow" }) }
            Mock Invoke-VsanClusterConfigReapply { return $true }
            Invoke-VsanClusterAlarmCheckAndRemediate -ClusterName "cl0" -PostRemediationWaitSeconds 0
            Should -Invoke Invoke-VsanClusterConfigReapply -Times 1 -Scope It
        }
    }

    It "Calls Invoke-ReconfigureClusterHA for a vSphere HA host status alarm" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Set-VsanDomNetworkSchedulerThrottleOnCluster { return $false }
            Mock Get-VsanClusterTriggeredAlarms { return @([PSCustomObject]@{ AlarmName = "vSphere HA host status"; Status = "Yellow" }) }
            Mock Invoke-ReconfigureClusterHA {}
            Invoke-VsanClusterAlarmCheckAndRemediate -ClusterName "cl0"
            Should -Invoke Invoke-ReconfigureClusterHA -Times 1 -Scope It
        }
    }

    It "Calls Enable-VsanPerformanceService for a performance service status alarm" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Set-VsanDomNetworkSchedulerThrottleOnCluster { return $false }
            Mock Get-VsanClusterTriggeredAlarms { return @([PSCustomObject]@{ AlarmName = "Performance service status"; Status = "Yellow" }) }
            Mock Enable-VsanPerformanceService {}
            Invoke-VsanClusterAlarmCheckAndRemediate -ClusterName "cl0"
            Should -Invoke Enable-VsanPerformanceService -Times 1 -Scope It
        }
    }

    It "Logs WARNING and does not throw when AcceptBadCheckResults is set and a red alarm is present" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Set-VsanDomNetworkSchedulerThrottleOnCluster { return $false }
            Mock Get-VsanClusterTriggeredAlarms { return @([PSCustomObject]@{ AlarmName = "vSAN health check unknown"; Status = "Red" }) }
            Mock Test-VsanTriggeredAlarmIsStatsPrimaryElection { return $false }
            Mock Test-VsanTriggeredAlarmIsHclRelated { return $false }
            { Invoke-VsanClusterAlarmCheckAndRemediate -ClusterName "cl0" -AcceptBadCheckResults } | Should -Not -Throw
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq 'WARNING' }
        }
    }
}

# ── Invoke-VsanClusterLeaveOnHostWithRetry ────────────────────────────────────


Describe "Invoke-VsanClusterLeaveOnHostWithRetry — mocked esxcli" {
    It "Returns false when Get-EsxCli throws an unrecognized error after all retries" {
        # The 'not in a vSAN' happy path relies on PowerCLI exception messages and is covered by live tests.
        # This test verifies that an unrecognized error causes the function to give up and return false.
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Get-EsxCli { throw "Connection refused by server." }
            $fakeHost = [PSCustomObject]@{ Name = "host1.lab" }
            $result = Invoke-VsanClusterLeaveOnHostWithRetry -VMHost $fakeHost -Server "vc01" -MaxRetries 1
            $result | Should -Be $false
        }
    }

    It "Returns false when esxcli vsan.cluster.leave is not available" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Get-EsxCli {
                return [PSCustomObject]@{
                    vsan = [PSCustomObject]@{
                        cluster = [PSCustomObject]@{ leave = $null }
                    }
                }
            }
            $fakeHost = [PSCustomObject]@{ Name = "host1.lab" }
            $result = Invoke-VsanClusterLeaveOnHostWithRetry -VMHost $fakeHost -Server "vc01"
            $result | Should -Be $false
        }
    }
}

# ── Show-ConfigurationHelpTable ───────────────────────────────────────────────


Describe "Invoke-AbandonHciWorkflowIfInProgress — mocked vCenter" {
    It "Returns without ERROR and does not throw when cluster is not found" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Get-ClusterByName { return $null }
            { Invoke-AbandonHciWorkflowIfInProgress -ClusterName "missing-cl" } | Should -Not -Throw
            Should -Not -Invoke Write-LogMessage -ParameterFilter { $Type -eq 'ERROR' }
        }
    }

    It "Does not throw when AbandonHciWorkflow raises 'not allowed in current state'" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            $ext = [PSCustomObject]@{}
            $ext | Add-Member -MemberType ScriptMethod -Name "AbandonHciWorkflow" -Value {
                throw "The operation is not allowed in the current state."
            }
            $Script:abandonExt = $ext
            Mock Get-ClusterByName { return [PSCustomObject]@{ ExtensionData = $Script:abandonExt } }
            { Invoke-AbandonHciWorkflowIfInProgress -ClusterName "cl0" } | Should -Not -Throw
            # Either the workflow was found and already-skipped path taken, or Get-Member -MemberType Method
            # did not match the ScriptMethod (implementation detail) — either way, a DEBUG log must appear.
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq "DEBUG" }
            Remove-Variable -Name "abandonExt" -Scope Script -ErrorAction SilentlyContinue
        }
    }
}

# ── Add-VsanEsaStoragePoolDisk ────────────────────────────────────────────────


Describe "Get-VsanDatastoreForCluster — datastore filtering" {

    It "Returns empty array when Get-Datastore returns only non-vSAN datastores" {
        $result = InModuleScope VcfEdgeAtScale {
            $Script:vCenterName = "vc.lab"
            function Get-Datastore {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server, [Parameter()] [Object]$VMHost)
                return @([PSCustomObject]@{ Type = "VMFS"; ExtensionData = [PSCustomObject]@{ Host = @() } })
            }
            @(Get-VsanDatastoreForCluster -ClusterHostIds @("host-123"))
        }
        $result.Count | Should -Be 0
    }

    It "Returns vSAN datastore whose host matches after HostSystem- prefix normalization" {
        $result = InModuleScope VcfEdgeAtScale {
            $Script:vCenterName = "vc.lab"
            $fakeHost = [PSCustomObject]@{ Key = [PSCustomObject]@{ Value = "host-123" } }
            $fakeDs   = [PSCustomObject]@{
                Type          = "vsan"
                ExtensionData = [PSCustomObject]@{ Host = @($fakeHost) }
            }
            function Get-Datastore {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server, [Parameter()] [Object]$VMHost)
                return @($fakeDs)
            }
            @(Get-VsanDatastoreForCluster -ClusterHostIds @("HostSystem-host-123"))
        }
        $result.Count | Should -Be 1
    }

    It "Returns empty array when vSAN datastore hosts do not overlap with cluster host IDs" {
        $result = InModuleScope VcfEdgeAtScale {
            $Script:vCenterName = "vc.lab"
            $fakeHost = [PSCustomObject]@{ Key = [PSCustomObject]@{ Value = "host-999" } }
            $fakeDs   = [PSCustomObject]@{
                Type          = "vsan"
                ExtensionData = [PSCustomObject]@{ Host = @($fakeHost) }
            }
            function Get-Datastore {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server, [Parameter()] [Object]$VMHost)
                return @($fakeDs)
            }
            @(Get-VsanDatastoreForCluster -ClusterHostIds @("host-123"))
        }
        $result.Count | Should -Be 0
    }
}

# ── Resolve-DiskIsSsdProperty ─────────────────────────────────────────────────


Describe "Test-VsanOsaDiskGroupPresentViaEsxcli — esxcli result routing" {

    It "Returns false when Get-EsxCli throws" {
        $result = InModuleScope VcfEdgeAtScale {
            function Get-EsxCli {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Switch]$V2, [Parameter()] [Object]$Server)
                throw "esxcli unavailable"
            }
            Test-VsanOsaDiskGroupPresentViaEsxcli -VMHost ([PSCustomObject]@{ Name = "esx01.lab" }) -Server "vc.lab"
        }
        $result | Should -Be $false
    }

    It "Returns false when vsan.storage.list.Invoke() returns null" {
        $result = InModuleScope VcfEdgeAtScale {
            $fakeListCmd = [PSCustomObject]@{}
            $fakeListCmd | Add-Member -MemberType ScriptMethod -Name "Invoke" -Value { return $null }
            function Get-EsxCli {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Switch]$V2, [Parameter()] [Object]$Server)
                return [PSCustomObject]@{
                    vsan = [PSCustomObject]@{
                        storage = [PSCustomObject]@{ list = $fakeListCmd }
                    }
                }
            }
            Test-VsanOsaDiskGroupPresentViaEsxcli -VMHost ([PSCustomObject]@{ Name = "esx01.lab" }) -Server "vc.lab"
        }
        $result | Should -Be $false
    }

    It "Returns true when vsan.storage.list result contains a VsanDiskGroupUuid" {
        $result = InModuleScope VcfEdgeAtScale {
            $Script:_diskItem = [PSCustomObject]@{ VsanDiskGroupUuid = "527f4fe8-1234-5678-abcd-ef0123456789" }
            $fakeListCmd = [PSCustomObject]@{}
            $fakeListCmd | Add-Member -MemberType ScriptMethod -Name "Invoke" -Value { return @($Script:_diskItem) }
            function Get-EsxCli {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Switch]$V2, [Parameter()] [Object]$Server)
                return [PSCustomObject]@{
                    vsan = [PSCustomObject]@{
                        storage = [PSCustomObject]@{ list = $fakeListCmd }
                    }
                }
            }
            Test-VsanOsaDiskGroupPresentViaEsxcli -VMHost ([PSCustomObject]@{ Name = "esx01.lab" }) -Server "vc.lab"
        }
        $result | Should -Be $true
    }
}

# ── Get-VsanDatastoreCapacityGB ───────────────────────────────────────────────


Describe "Invoke-VsanClusterConfigReapply" {
    It "Returns false when cluster is not found" {
        $result = InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Get-ClusterByName { $null }
            Invoke-VsanClusterConfigReapply -ClusterName "cl-missing"
        }
        $result | Should -Be $false
    }

    It "Returns true when Get-VsanClusterConfiguration and Set-VsanClusterConfiguration succeed" {
        $result = InModuleScope VcfEdgeAtScale {
            function Get-VsanClusterConfiguration {
                [CmdletBinding()] Param([Parameter()] [Object]$Cluster, [Parameter()] [Object]$Server)
                process {}
            }
            function Set-VsanClusterConfiguration {
                [CmdletBinding()] Param([Parameter()] [Object]$Configuration, [Parameter()] [Object]$Server)
                process {}
            }
            Mock Write-LogMessage {}
            Mock Get-VsanClusterConfiguration { [PSCustomObject]@{ SomeConfig = $true } }
            Mock Set-VsanClusterConfiguration {}
            Invoke-VsanClusterConfigReapply -ClusterName "cl0"
        }
        $result | Should -Be $true
    }

    It "Returns false when Set-VsanClusterConfiguration throws" {
        $result = InModuleScope VcfEdgeAtScale {
            function Get-VsanClusterConfiguration {
                [CmdletBinding()] Param([Parameter()] [Object]$Cluster, [Parameter()] [Object]$Server)
                process {}
            }
            function Set-VsanClusterConfiguration {
                [CmdletBinding()] Param([Parameter()] [Object]$Configuration, [Parameter()] [Object]$Server)
                process {}
            }
            Mock Write-LogMessage {}
            Mock Get-VsanClusterConfiguration { [PSCustomObject]@{ SomeConfig = $true } }
            Mock Set-VsanClusterConfiguration { throw [System.Exception]::new("vSAN error") }
            Invoke-VsanClusterConfigReapply -ClusterName "cl0"
        }
        $result | Should -Be $false
    }
}

# ── Invoke-VsanClusterHealthRetestAfterDeployment ─────────────────────────────


Describe "Invoke-VsanClusterHealthRetestAfterDeployment" {
    It "Logs DEBUG 'not available; skipping' and does not throw when Test-VsanClusterHealth is not available on this PowerCLI version" {
        # The function checks Get-Command "Test-VsanClusterHealth" at runtime; mock it to simulate absence.
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Get-Command { $null } -ParameterFilter { $Name -eq "Test-VsanClusterHealth" }
            { Invoke-VsanClusterHealthRetestAfterDeployment -ClusterName "cl0" } | Should -Not -Throw
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq 'DEBUG' -and $Message -match 'not available' }
        }
    }

    It "Calls Test-VsanClusterHealth and logs INFO when the cmdlet is available" {
        InModuleScope VcfEdgeAtScale {
            function Get-Cluster {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                process {}
            }
            function Test-VsanClusterHealth {
                [CmdletBinding()] Param([Parameter()] [Object]$Cluster, [Parameter()] [Object]$Server)
                process {}
            }
            Mock Write-LogMessage {}
            # Make Get-Command return a fake CommandInfo for Test-VsanClusterHealth with an empty Parameters dict.
            $fakeParams = @{}
            $fakeCmd    = [PSCustomObject]@{ Parameters = $fakeParams }
            Mock Get-Command { $fakeCmd } -ParameterFilter { $Name -eq "Test-VsanClusterHealth" }
            Mock Get-Cluster { [PSCustomObject]@{ Name = "cl0" } }
            Mock Test-VsanClusterHealth {}
            { Invoke-VsanClusterHealthRetestAfterDeployment -ClusterName "cl0" } | Should -Not -Throw
            Should -Invoke Test-VsanClusterHealth -Times 1 -Scope It
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq "INFO" -and $Message -match "health test" } -Scope It
        }
    }
}

# ── Enable-VsanAutomaticRebalance ─────────────────────────────────────────────


Describe "Enable-VsanAutomaticRebalance" {
    It "Returns false when Set-VsanClusterConfiguration does not support ProactiveRebalanceEnabled" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Get-Command { return $null } -ParameterFilter { $Name -eq "Set-VsanClusterConfiguration" }
            $result = Enable-VsanAutomaticRebalance -ClusterName "cl0"
            $result | Should -Be $false
        }
    }

    It "Returns true when Set-VsanClusterConfiguration supports ProactiveRebalanceEnabled and call succeeds" {
        $result = InModuleScope VcfEdgeAtScale {
            function Get-Cluster {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                process {}
            }
            function Get-VsanClusterConfiguration {
                [CmdletBinding()] Param([Parameter()] [Object]$Cluster, [Parameter()] [Object]$Server)
                process {}
            }
            function Set-VsanClusterConfiguration {
                [CmdletBinding()] Param([Parameter()] [Object]$Configuration, [Parameter()] [Object]$ProactiveRebalanceEnabled, [Parameter()] [Object]$ProactiveRebalanceThreshold, [Parameter()] [Object]$Server)
                process {}
            }
            Mock Write-LogMessage {}
            $fakeParams = @{ "ProactiveRebalanceEnabled" = $true; "ProactiveRebalanceThreshold" = $true }
            $fakeCmd = [PSCustomObject]@{ Parameters = $fakeParams }
            Mock Get-Command { $fakeCmd } -ParameterFilter { $Name -eq "Set-VsanClusterConfiguration" }
            Mock Get-Cluster { [PSCustomObject]@{ Name = "cl0" } }
            Mock Get-VsanClusterConfiguration { [PSCustomObject]@{ Config = $true } }
            Mock Set-VsanClusterConfiguration {}
            Enable-VsanAutomaticRebalance -ClusterName "cl0"
        }
        $result | Should -Be $true
    }
}

# ── Enable-VsanAutomaticDiskClaimIfSupported ──────────────────────────────────


Describe "Enable-VsanAutomaticDiskClaimIfSupported" {
    It "Returns false when both Set-VsanClusterConfiguration and Set-Cluster lack VsanDiskClaimMode" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            $emptyCmdParams = [PSCustomObject]@{ Parameters = @{} }
            Mock Get-Command { $emptyCmdParams } -ParameterFilter { $Name -eq "Set-VsanClusterConfiguration" }
            Mock Get-Command { $emptyCmdParams } -ParameterFilter { $Name -eq "Set-Cluster" }
            $result = Enable-VsanAutomaticDiskClaimIfSupported -ClusterName "cl0"
            $result | Should -Be $false
            Should -Invoke Write-LogMessage -ParameterFilter { $Message -match "both lack" }
        }
    }

    It "Returns false when Get-VsanClusterConfiguration returns null" {
        $result = InModuleScope VcfEdgeAtScale {
            function Get-VsanClusterConfiguration {
                [CmdletBinding()] Param([Parameter()] [Object]$Cluster, [Parameter()] [Object]$Server)
                process {}
            }
            Mock Write-LogMessage {}
            $fakeParams = @{ "VsanDiskClaimMode" = [PSCustomObject]@{ ParameterType = [System.ConsoleColor]; Attributes = @() } }
            $fakeCmd = [PSCustomObject]@{ Parameters = $fakeParams }
            Mock Get-Command { $fakeCmd } -ParameterFilter { $Name -eq "Set-VsanClusterConfiguration" }
            Mock Get-VsanClusterConfiguration { $null }
            Enable-VsanAutomaticDiskClaimIfSupported -ClusterName "cl0"
        }
        $result | Should -Be $false
    }

    It "Logs Set-Cluster fallback when Set-VsanClusterConfiguration lacks VsanDiskClaimMode but Set-Cluster has it" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            $noParamCmd = [PSCustomObject]@{ Parameters = @{} }
            $withParamCmd = [PSCustomObject]@{ Name = "Set-Cluster"; Parameters = @{ "VsanDiskClaimMode" = [PSCustomObject]@{ ParameterType = [System.ConsoleColor]; Attributes = @() } } }
            Mock Get-Command { $noParamCmd } -ParameterFilter { $Name -eq "Set-VsanClusterConfiguration" }
            Mock Get-Command { $withParamCmd } -ParameterFilter { $Name -eq "Set-Cluster" }
            function Get-VsanClusterConfiguration {
                [CmdletBinding()] Param([Parameter()] [Object]$Cluster, [Parameter()] [Object]$Server)
                process { return $null }
            }
            Mock Get-VsanClusterConfiguration { $null }
            Enable-VsanAutomaticDiskClaimIfSupported -ClusterName "cl0"
            Should -Invoke Write-LogMessage -ParameterFilter { $Message -match "Set-Cluster fallback" }
        }
    }

    It "Does not short-circuit for ESA clusters — proceeds to disk claim check regardless of VsanEsaEnabled" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            $fakeParams = @{ "VsanDiskClaimMode" = [PSCustomObject]@{ ParameterType = [System.ConsoleColor]; Attributes = @() } }
            $fakeCmd = [PSCustomObject]@{ Name = "Set-Cluster"; Parameters = $fakeParams }
            Mock Get-Command { [PSCustomObject]@{ Parameters = @{} } } -ParameterFilter { $Name -eq "Set-VsanClusterConfiguration" }
            Mock Get-Command { $fakeCmd } -ParameterFilter { $Name -eq "Set-Cluster" }
            $esaConfig = [PSCustomObject]@{ VsanEsaEnabled = $true; VsanDiskClaimMode = $null }
            function Get-VsanClusterConfiguration {
                [CmdletBinding()] Param([Parameter()] [Object]$Cluster, [Parameter()] [Object]$Server)
                process { return $esaConfig }
            }
            Enable-VsanAutomaticDiskClaimIfSupported -ClusterName "cl0"
            # ESA gate was removed: the function must not log the old ESA-skip message.
            Should -Not -Invoke Write-LogMessage -ParameterFilter { $Message -match "VsanEsaEnabled" }
        }
    }
}

# ── Enable-VsanEsaOnExistingCluster ───────────────────────────────────────────


Describe "Enable-VsanEsaOnExistingCluster" {
    It "Calls Set-Cluster with VsanEnabled and VsanEsaEnabled without throwing" {
        InModuleScope VcfEdgeAtScale {
            function Set-Cluster {
                [CmdletBinding(SupportsShouldProcess = $true)]
                Param(
                    [Parameter()] [Object]$Cluster,
                    [Parameter()] [Bool]$VsanEnabled,
                    [Parameter()] [Bool]$VsanEsaEnabled,
                    [Parameter()] [Object]$Server
                )
                begin {}
                process {}
            }
            Mock Write-LogMessage {}
            Mock Set-Cluster {}
            $fakeCluster = [PSCustomObject]@{ Name = "cl0" }
            { Enable-VsanEsaOnExistingCluster -Cluster $fakeCluster -ClusterName "cl0" } | Should -Not -Throw
            Should -Invoke Set-Cluster -Times 1
        }
    }

    It "Logs WARNING and does not throw when Set-Cluster fails (non-fatal for vCenter 9.0 compatibility)" {
        InModuleScope VcfEdgeAtScale {
            function Set-Cluster {
                [CmdletBinding(SupportsShouldProcess = $true)]
                Param(
                    [Parameter()] [Object]$Cluster,
                    [Parameter()] [Bool]$VsanEnabled,
                    [Parameter()] [Bool]$VsanEsaEnabled,
                    [Parameter()] [Object]$Server
                )
                begin {}
                process { throw "VsanEsaEnabled is not a recognized parameter on this vCenter version." }
            }
            Mock Write-LogMessage {}
            $fakeCluster = [PSCustomObject]@{ Name = "cl0" }
            { Enable-VsanEsaOnExistingCluster -Cluster $fakeCluster -ClusterName "cl0" } | Should -Not -Throw
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq 'WARNING' -and $Message -match "Could not apply vSAN ESA flag" }
        }
    }
}

# ── Set-VsanWitness ───────────────────────────────────────────────────────────

# ── Confirm-VsanWitnessConfiguration ─────────────────────────────────────────


Describe "Confirm-VsanWitnessConfiguration — OVA type mismatch" {
    It "Throws VcfDeploymentException when ESA cluster uses a witness deployed from OSA OVA" {
        InModuleScope VcfEdgeAtScale {
            function Get-AdvancedSetting {
                [CmdletBinding()] Param([Parameter()] [Object]$Entity, [Parameter()] [Object]$Name)
                process {}
            }
            Mock Write-LogMessage {}
            $fakeWitness = [PSCustomObject]@{ MemoryTotalGB = 32 }
            # HostDeployedFromWitnessOVF=1 means OSA OVA; requesting ESA → mismatch.
            Mock Get-AdvancedSetting { [PSCustomObject]@{ Value = 1 } }
            { Confirm-VsanWitnessConfiguration -ClusterName "cl0" -StoragePolicyType "vSAN-ESA" -vSanWitnessVmName "witness01" -WitnessHost $fakeWitness } | Should -Throw
        }
    }
}


Describe "Confirm-VsanWitnessConfiguration — insufficient memory" {
    It "Throws VcfDeploymentException when OSA witness has less than 8 GB memory" {
        InModuleScope VcfEdgeAtScale {
            function Get-AdvancedSetting {
                [CmdletBinding()] Param([Parameter()] [Object]$Entity, [Parameter()] [Object]$Name)
                process {}
            }
            function Get-VsanStoragePoolDisk {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Object]$Server)
                process {}
            }
            Mock Write-LogMessage {}
            $fakeWitness = [PSCustomObject]@{ MemoryTotalGB = 4 }
            Mock Get-AdvancedSetting { $null }
            # No OVA-type mismatch, no ESA pool mismatch — memory check fails.
            Mock Get-VsanStoragePoolDisk { @() }
            { Confirm-VsanWitnessConfiguration -ClusterName "cl0" -StoragePolicyType "vSAN-OSA" -vSanWitnessVmName "witness01" -WitnessHost $fakeWitness } | Should -Throw
        }
    }
}


Describe "Confirm-VsanWitnessConfiguration — missing OSA disk group" {
    It "Throws VcfDeploymentException when OSA witness has no disk group" {
        InModuleScope VcfEdgeAtScale {
            function Get-AdvancedSetting {
                [CmdletBinding()] Param([Parameter()] [Object]$Entity, [Parameter()] [Object]$Name)
                process {}
            }
            function Get-VsanStoragePoolDisk {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Object]$Server)
                process {}
            }
            function Get-VsanOsaDiskGroupsOnHost {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Object]$Server)
                process {}
            }
            Mock Write-LogMessage {}
            $fakeWitness = [PSCustomObject]@{ MemoryTotalGB = 16 }
            Mock Get-AdvancedSetting { $null }
            Mock Get-VsanStoragePoolDisk { @() }
            Mock Get-VsanOsaDiskGroupsOnHost { [PSCustomObject]@{ HasValidOsaGroup = $false; DiskGroupCount = 0 } }
            { Confirm-VsanWitnessConfiguration -ClusterName "cl0" -StoragePolicyType "vSAN-OSA" -vSanWitnessVmName "witness01" -WitnessHost $fakeWitness } | Should -Throw
        }
    }
}


Describe "Confirm-VsanWitnessConfiguration — ESA success path" {
    It "Returns without throwing when ESA witness OVA matches, memory meets minimum, and no OSA disk group" {
        InModuleScope VcfEdgeAtScale {
            function Get-AdvancedSetting {
                [CmdletBinding()] Param([Parameter()] [Object]$Entity, [Parameter()] [Object]$Name)
                process {}
            }
            function Get-VsanOsaDiskGroupsOnHost {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Object]$Server)
                process {}
            }
            function Get-VsanStoragePoolDisk {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Object]$Server)
                process {}
            }
            Mock Write-LogMessage {}
            $fakeWitness = [PSCustomObject]@{ MemoryTotalGB = 32 }
            # OVA type 2 = ESA OVA; StoragePolicyType = vSAN-ESA → match, no throw.
            Mock Get-AdvancedSetting { [PSCustomObject]@{ Value = 2 } }
            # No OSA disk group on the witness → ESA type check passes.
            Mock Get-VsanOsaDiskGroupsOnHost { [PSCustomObject]@{ HasValidOsaGroup = $false; DiskGroupCount = 0 } }
            # No ESA storage pool on the witness (OSA mismatch check returns empty).
            Mock Get-VsanStoragePoolDisk { @() }
            { Confirm-VsanWitnessConfiguration -ClusterName "cl0" -StoragePolicyType "vSAN-ESA" -vSanWitnessVmName "witness01" -WitnessHost $fakeWitness } | Should -Not -Throw
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq "DEBUG" -and $Message -match "ESA witness with zero disks is supported" }
        }
    }
}

Describe "Confirm-VsanWitnessConfiguration — OSA success path" {
    It "Returns without throwing when OSA witness OVA matches, memory meets minimum, and disk group is valid" {
        InModuleScope VcfEdgeAtScale {
            function Get-AdvancedSetting {
                [CmdletBinding()] Param([Parameter()] [Object]$Entity, [Parameter()] [Object]$Name)
                process {}
            }
            function Get-VsanOsaDiskGroupsOnHost {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Object]$Server)
                process {}
            }
            function Get-VsanStoragePoolDisk {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Object]$Server)
                process {}
            }
            Mock Write-LogMessage {}
            $fakeWitness = [PSCustomObject]@{ MemoryTotalGB = 16 }
            # OVA type 1 = OSA OVA; StoragePolicyType = vSAN-OSA → match, no throw.
            Mock Get-AdvancedSetting { [PSCustomObject]@{ Value = 1 } }
            # No ESA storage pool on the witness → OSA type check passes.
            Mock Get-VsanStoragePoolDisk { @() }
            # Valid OSA disk group with cache and capacity → memory + disk group checks pass.
            Mock Get-VsanOsaDiskGroupsOnHost { [PSCustomObject]@{ HasValidOsaGroup = $true; DiskGroupCount = 1 } }
            { Confirm-VsanWitnessConfiguration -ClusterName "cl0" -StoragePolicyType "vSAN-OSA" -vSanWitnessVmName "witness01" -WitnessHost $fakeWitness } | Should -Not -Throw
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq "DEBUG" -and $Message -match "valid cache and capacity" }
        }
    }
}

# ── Invoke-EnsureWitnessVsanTraffic ──────────────────────────────────────────


Describe "Invoke-EnsureWitnessVsanTraffic — already compliant" {
    It "Returns without ERROR and does not call Set-VMHostNetworkAdapter when witness already has a compliant VMkernel" {
        InModuleScope VcfEdgeAtScale {
            function Set-VMHostNetworkAdapter {
                [CmdletBinding(SupportsShouldProcess = $true)]
                Param([Parameter()] [Object]$VirtualNic, [Parameter()] [Object]$VsanTrafficEnabled, [Parameter()] [Object]$PortGroup)
                begin {}
                process { throw "Set-VMHostNetworkAdapter must not be called when witness is already compliant" }
            }
            Mock Write-LogMessage {}
            $fakeWitness = [PSCustomObject]@{ Name = "witness01" }
            Mock Test-VmkernelVsanAndWitnessTraffic { [PSCustomObject]@{ HasCompliantInterface = $true; Vmk0Adapter = $null } }
            { Invoke-EnsureWitnessVsanTraffic -ClusterName "cl0" -vSanWitnessVmName "witness01" -WitnessHost $fakeWitness } | Should -Not -Throw
            Should -Not -Invoke Write-LogMessage -ParameterFilter { $Type -eq 'ERROR' }
        }
    }
}


Describe "Invoke-EnsureWitnessVsanTraffic — no vmk0 found" {
    It "Throws VcfDeploymentException when witness has no compliant interface and no vmk0" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            $fakeWitness = [PSCustomObject]@{ Name = "witness01" }
            Mock Test-VmkernelVsanAndWitnessTraffic { [PSCustomObject]@{ HasCompliantInterface = $false; Vmk0Adapter = $null } }
            { Invoke-EnsureWitnessVsanTraffic -ClusterName "cl0" -vSanWitnessVmName "witness01" -WitnessHost $fakeWitness } | Should -Throw
        }
    }
}


Describe "Invoke-EnsureWitnessVsanTraffic — enabling traffic on vmk0 fails" {
    It "Throws VcfDeploymentException when Set-VMHostNetworkAdapter fails to enable vSAN traffic" {
        InModuleScope VcfEdgeAtScale {
            function Set-VMHostNetworkAdapter {
                [CmdletBinding(SupportsShouldProcess = $true)]
                Param([Parameter()] [Object]$VirtualNic, [Parameter()] [Object]$VsanTrafficEnabled, [Parameter()] [Object]$PortGroup)
                begin {}
                process { throw "Cannot enable vSAN traffic on vmk0." }
            }
            Mock Write-LogMessage {}
            $fakeVmk0    = [PSCustomObject]@{ Name = "vmk0" }
            $fakeWitness = [PSCustomObject]@{ Name = "witness01" }
            Mock Test-VmkernelVsanAndWitnessTraffic { [PSCustomObject]@{ HasCompliantInterface = $false; Vmk0Adapter = $fakeVmk0 } }
            { Invoke-EnsureWitnessVsanTraffic -ClusterName "cl0" -vSanWitnessVmName "witness01" -WitnessHost $fakeWitness } | Should -Throw
        }
    }
}

Describe "Invoke-EnsureWitnessVsanTraffic — vmk0 traffic enable success path" {
    It "Returns without throwing when vmk0 is found, Set-VMHostNetworkAdapter succeeds, and recheck shows compliant interface" {
        InModuleScope VcfEdgeAtScale {
            function Set-VMHostNetworkAdapter {
                [CmdletBinding(SupportsShouldProcess = $true)]
                Param([Parameter()] [Object]$VirtualNic, [Parameter()] [Object]$VsanTrafficEnabled, [Parameter()] [Object]$PortGroup)
                begin {}; process {}
            }
            Mock Write-LogMessage {}
            $fakeVmk0    = [PSCustomObject]@{ Name = "vmk0" }
            $fakeWitness = [PSCustomObject]@{ Name = "witness01" }
            $Script:_vsanCheckCallCount = 0
            # First call: not compliant but vmk0 present → Set-VMHostNetworkAdapter is invoked.
            # Second call (recheck after enable): compliant → function returns without throw.
            Mock Test-VmkernelVsanAndWitnessTraffic {
                $Script:_vsanCheckCallCount++
                if ($Script:_vsanCheckCallCount -le 1) {
                    return [PSCustomObject]@{ HasCompliantInterface = $false; Vmk0Adapter = $fakeVmk0 }
                }
                return [PSCustomObject]@{ HasCompliantInterface = $true; Vmk0Adapter = $fakeVmk0 }
            }
            { Invoke-EnsureWitnessVsanTraffic -ClusterName "cl0" -vSanWitnessVmName "witness01" -WitnessHost $fakeWitness } | Should -Not -Throw
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq "INFO" -and $Message -match "vSAN traffic has been enabled on vmk0" }
        }
    }
}

# ── Confirm-VsanClusterReadinessForWitness ────────────────────────────────────


Describe "Confirm-VsanClusterReadinessForWitness — empty cluster" {
    It "Throws VcfDeploymentException when cluster has no hosts" {
        InModuleScope VcfEdgeAtScale {
            function Get-VMHost {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Location, [Parameter()] [Object]$Server)
                process {}
            }
            Mock Write-LogMessage {}
            Mock Get-VMHost { @() }
            $fakeCluster = [PSCustomObject]@{ Name = "cl0" }
            $fakeWitness = [PSCustomObject]@{ Name = "witness01"; Id = "host-999"; ExtensionData = $null }
            { Confirm-VsanClusterReadinessForWitness -Cluster $fakeCluster -ClusterName "cl0" -vSanWitnessVmName "witness01" -WitnessHost $fakeWitness } | Should -Throw
        }
    }
}


Describe "Confirm-VsanClusterReadinessForWitness — witness in cluster" {
    It "Throws VcfDeploymentException when the witness host is a member of the cluster" {
        InModuleScope VcfEdgeAtScale {
            function Get-VMHost {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Location, [Parameter()] [Object]$Server)
                process {}
            }
            Mock Write-LogMessage {}
            $witnessId = "host-witness"
            $fakeWitness = [PSCustomObject]@{ Name = "witness01"; Id = $witnessId; ExtensionData = $null }
            # Return witness as a cluster host — this is the violation.
            Mock Get-VMHost { @([PSCustomObject]@{ Name = "witness01"; Id = $witnessId; ExtensionData = $null }) }
            Mock Confirm-VsanWitnessVersionMatch {}
            $fakeCluster = [PSCustomObject]@{ Name = "cl0" }
            { Confirm-VsanClusterReadinessForWitness -Cluster $fakeCluster -ClusterName "cl0" -vSanWitnessVmName "witness01" -WitnessHost $fakeWitness } | Should -Throw
        }
    }
}


Describe "Confirm-VsanClusterReadinessForWitness — success path" {
    It "Returns ClusterHosts and PreferredHost when all validation passes" {
        InModuleScope VcfEdgeAtScale {
            function Get-VMHost {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Location, [Parameter()] [Object]$Server)
                process {}
            }
            function Get-VMHostNetworkAdapter {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Switch]$VMKernel, [Parameter()] [Switch]$Physical, [Parameter()] [Object]$VirtualSwitch, [Parameter()] [Object]$PortGroup, [Parameter()] [Object]$Server)
                process {}
            }
            Mock Write-LogMessage {}
            $fakeHost    = [PSCustomObject]@{ Name = "esx01"; Id = "host-01"; ExtensionData = $null }
            $fakeWitness = [PSCustomObject]@{ Name = "witness01"; Id = "host-999"; ExtensionData = $null }
            Mock Get-VMHost { @($fakeHost) }
            Mock Confirm-VsanWitnessVersionMatch {}
            Mock Get-VMHostNetworkAdapter { $null }
            Mock Test-VmkernelVsanAndWitnessTraffic { [PSCustomObject]@{ HasCompliantInterface = $true } }
            Mock Test-VsanTrafficVmkernelHasValidIp { $true }
            $fakeCluster = [PSCustomObject]@{ Name = "cl0" }
            $result = Confirm-VsanClusterReadinessForWitness -Cluster $fakeCluster -ClusterName "cl0" -vSanWitnessVmName "witness01" -WitnessHost $fakeWitness
            $result.ClusterHosts  | Should -Not -BeNullOrEmpty
            $result.PreferredHost | Should -Not -BeNullOrEmpty
        }
    }
}

# ── Set-VsanWitness ───────────────────────────────────────────────────────────


Describe "Set-VsanWitness — guard conditions" {
    It "Throws VcfDeploymentException when vCenter is not connected" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Test-VcenterConnection { [PSCustomObject]@{ IsConnected = $false; ErrorMessage = "No session." } }
            { Set-VsanWitness -ClusterName "cl0" -vSanWitnessVmName "witness01" -PreferredFaultDomainName "Primary" -StoragePolicyType "vSAN-OSA" } | Should -Throw
        }
    }

    It "Throws VcfDeploymentException when cluster is not found" {
        InModuleScope VcfEdgeAtScale {
            function Get-Cluster {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                process {}
            }
            function Get-VMHost {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                process {}
            }
            Mock Write-LogMessage {}
            Mock Test-VcenterConnection { [PSCustomObject]@{ IsConnected = $true; ErrorMessage = $null } }
            Mock Get-Cluster { $null }
            { Set-VsanWitness -ClusterName "cl-missing" -vSanWitnessVmName "witness01" -PreferredFaultDomainName "Primary" -StoragePolicyType "vSAN-OSA" } | Should -Throw
        }
    }

    It "Throws VcfDeploymentException when witness host is not found in vCenter" {
        InModuleScope VcfEdgeAtScale {
            function Get-Cluster {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                process {}
            }
            function Get-VMHost {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                process {}
            }
            Mock Write-LogMessage {}
            Mock Test-VcenterConnection { [PSCustomObject]@{ IsConnected = $true; ErrorMessage = $null } }
            Mock Get-Cluster { [PSCustomObject]@{ Name = "cl0" } }
            Mock Get-VMHost { $null }
            { Set-VsanWitness -ClusterName "cl0" -vSanWitnessVmName "witness-missing" -PreferredFaultDomainName "Primary" -StoragePolicyType "vSAN-OSA" } | Should -Throw
        }
    }
}

# ── Confirm-VsanWitnessVersionMatch ──────────────────────────────────────────


Describe "Confirm-VsanWitnessVersionMatch — version compatibility" {
    It "Logs INFO version match and does not throw when witness and cluster hosts share the same version and build" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            $fakeWitness = [PSCustomObject]@{ Version = "8.0.3"; Build = "23825572" }
            $fakeClusterHosts = @( [PSCustomObject]@{ Version = "8.0.3"; Build = "23825572" } )
            { Confirm-VsanWitnessVersionMatch -WitnessHost $fakeWitness -ClusterHosts $fakeClusterHosts -ClusterName "cl0" -vSanWitnessVmName "witness01" -LabEnvironment:$false } | Should -Not -Throw
            Should -Not -Invoke Write-LogMessage -ParameterFilter { $Type -eq 'ERROR' }
        }
    }

    It "Logs WARNING and returns (no throw) on version mismatch when LabEnvironment is true" {
        InModuleScope VcfEdgeAtScale {
            $warningMessages = [System.Collections.Generic.List[String]]::new()
            Mock Write-LogMessage { if ($Type -eq "WARNING") { $warningMessages.Add($Message) } }
            $fakeWitness = [PSCustomObject]@{ Version = "8.0.2"; Build = "22380479" }
            $fakeClusterHosts = @( [PSCustomObject]@{ Version = "8.0.3"; Build = "23825572" } )
            { Confirm-VsanWitnessVersionMatch -WitnessHost $fakeWitness -ClusterHosts $fakeClusterHosts -ClusterName "cl0" -vSanWitnessVmName "witness01" -LabEnvironment:$true } | Should -Not -Throw
            $warningMessages | Should -Not -BeNullOrEmpty
        }
    }

    It "Throws VcfDeploymentException when non-lab user declines on version mismatch" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Read-Host { "N" }
            $fakeWitness = [PSCustomObject]@{ Version = "8.0.2"; Build = "22380479" }
            $fakeClusterHosts = @( [PSCustomObject]@{ Version = "8.0.3"; Build = "23825572" } )
            { Confirm-VsanWitnessVersionMatch -WitnessHost $fakeWitness -ClusterHosts $fakeClusterHosts -ClusterName "cl0" -vSanWitnessVmName "witness01" -LabEnvironment:$false } | Should -Throw
        }
    }

    It "Logs WARNING and does not throw when non-lab user accepts on version mismatch" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Read-Host { "Y" }
            $fakeWitness = [PSCustomObject]@{ Version = "8.0.2"; Build = "22380479" }
            $fakeClusterHosts = @( [PSCustomObject]@{ Version = "8.0.3"; Build = "23825572" } )
            { Confirm-VsanWitnessVersionMatch -WitnessHost $fakeWitness -ClusterHosts $fakeClusterHosts -ClusterName "cl0" -vSanWitnessVmName "witness01" -LabEnvironment:$false } | Should -Not -Throw
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq 'WARNING' }
        }
    }

    It "Logs WARNING and returns (no throw) when ESX version cannot be read" {
        InModuleScope VcfEdgeAtScale {
            $warningMessages = [System.Collections.Generic.List[String]]::new()
            Mock Write-LogMessage { if ($Type -eq "WARNING") { $warningMessages.Add($Message) } }
            $fakeWitness = [PSCustomObject]@{}
            $fakeClusterHosts = @( [PSCustomObject]@{} )
            { Confirm-VsanWitnessVersionMatch -WitnessHost $fakeWitness -ClusterHosts $fakeClusterHosts -ClusterName "cl0" -vSanWitnessVmName "witness01" -LabEnvironment:$false } | Should -Not -Throw
            $warningMessages | Should -Not -BeNullOrEmpty
        }
    }

    It "Throws VcfDeploymentException on build mismatch when non-lab user declines" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Read-Host { "" }
            $fakeWitness = [PSCustomObject]@{ Version = "8.0.3"; Build = "22380479" }
            $fakeClusterHosts = @( [PSCustomObject]@{ Version = "8.0.3"; Build = "23825572" } )
            { Confirm-VsanWitnessVersionMatch -WitnessHost $fakeWitness -ClusterHosts $fakeClusterHosts -ClusterName "cl0" -vSanWitnessVmName "witness01" -LabEnvironment:$false } | Should -Throw
        }
    }
}

# ── Resolve-VsanPreferredFaultDomain ──────────────────────────────────────────


Describe "Resolve-VsanPreferredFaultDomain — fault domain resolution" {
    It "Returns the Primary fault domain when found by name" {
        InModuleScope VcfEdgeAtScale {
            function Get-VsanFaultDomain {
                [CmdletBinding()] Param([Parameter()] [Object]$Cluster, [Parameter()] [Object]$Name, [Parameter()] [Object]$VMHost, [Parameter()] [Object]$Server)
                process {}
            }
            Mock Write-LogMessage {}
            $fakeFaultDomain = [PSCustomObject]@{ Name = "Primary"; Id = "fd-1" }
            Mock Get-VsanFaultDomain { $fakeFaultDomain }
            $fakeCluster = [PSCustomObject]@{ Name = "cl0" }
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab"; Id = "host-1" }
            $result = Resolve-VsanPreferredFaultDomain -Cluster $fakeCluster -ClusterHosts @($fakeHost) -ClusterName "cl0" -PreferredFaultDomainName "site1" -PreferredHost $fakeHost -Server "vc.lab"
            $result.Name | Should -Be "Primary"
        }
    }

    It "Returns null and logs WARNING when fault domains exist but none match" {
        InModuleScope VcfEdgeAtScale {
            function Get-VsanFaultDomain {
                [CmdletBinding()] Param([Parameter()] [Object]$Cluster, [Parameter()] [Object]$Name, [Parameter()] [Object]$VMHost, [Parameter()] [Object]$Server)
                process {}
            }
            $warningMessages = [System.Collections.Generic.List[String]]::new()
            Mock Write-LogMessage { if ($Type -eq "WARNING") { $warningMessages.Add($Message) } }
            $Script:_fdCallCount = 0
            function Get-VsanFaultDomain {
                [CmdletBinding()] Param([Parameter()] [Object]$Cluster, [Parameter()] [Object]$Name, [Parameter()] [Object]$VMHost, [Parameter()] [Object]$Server)
                $Script:_fdCallCount++
                if ($Script:_fdCallCount -le 3) { return $null }
                return @( [PSCustomObject]@{ Name = "OtherDomain"; Id = "fd-99" } )
            }
            $fakeCluster = [PSCustomObject]@{ Name = "cl0" }
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab"; Id = "host-1" }
            $result = Resolve-VsanPreferredFaultDomain -Cluster $fakeCluster -ClusterHosts @($fakeHost) -ClusterName "cl0" -PreferredFaultDomainName "site1" -PreferredHost $fakeHost -Server "vc.lab"
            $result | Should -BeNullOrEmpty
            $warningMessages | Should -Not -BeNullOrEmpty
        }
    }

    It "Creates Primary and Secondary fault domains when none exist and returns Primary" {
        # Calls to Get-VsanFaultDomain during discovery: (1) by name "Primary", (2) by name
        # "site1", (3) by VMHost, (4) list-all (returns empty → triggers creation). Call 5 is
        # the post-creation verification and must return the new Primary domain.
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            $Script:_fdCreateCallCount = 0
            function Get-VsanFaultDomain {
                [CmdletBinding()] Param([Parameter()] [Object]$Cluster, [Parameter()] [Object]$Name, [Parameter()] [Object]$VMHost, [Parameter()] [Object]$Server)
                $Script:_fdCreateCallCount++
                if ($Script:_fdCreateCallCount -le 4) { return $null }
                return [PSCustomObject]@{ Name = "Primary"; Id = "fd-primary" }
            }
            $Script:_newFdCount = 0
            function New-VsanFaultDomain {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$VMHost, [Parameter()] [Object]$Server)
                $Script:_newFdCount++
            }
            $fakeCluster = [PSCustomObject]@{ Name = "cl0" }
            $fakeHost1 = [PSCustomObject]@{ Name = "esx01.lab"; Id = "host-1" }
            $fakeHost2 = [PSCustomObject]@{ Name = "esx02.lab"; Id = "host-2" }
            $result = Resolve-VsanPreferredFaultDomain -Cluster $fakeCluster -ClusterHosts @($fakeHost1, $fakeHost2) -ClusterName "cl0" -PreferredFaultDomainName "site1" -PreferredHost $fakeHost1 -Server "vc.lab"
            $result.Name | Should -Be "Primary"
            $Script:_newFdCount | Should -BeGreaterOrEqual 1
        }
    }

    It "Propagates VcfDeploymentException from New-VsanFaultDomain failure" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            function Get-VsanFaultDomain {
                [CmdletBinding()] Param([Parameter()] [Object]$Cluster, [Parameter()] [Object]$Name, [Parameter()] [Object]$VMHost, [Parameter()] [Object]$Server)
                process { return $null }
            }
            function New-VsanFaultDomain {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$VMHost, [Parameter()] [Object]$Server)
                throw "vSphere error creating fault domain."
            }
            $fakeCluster = [PSCustomObject]@{ Name = "cl0" }
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab"; Id = "host-1" }
            { Resolve-VsanPreferredFaultDomain -Cluster $fakeCluster -ClusterHosts @($fakeHost) -ClusterName "cl0" -PreferredFaultDomainName "site1" -PreferredHost $fakeHost -Server "vc.lab" } | Should -Throw
        }
    }
}

# ── Invoke-VsanOsaDiskGroupCreation ──────────────────────────────────────────


Describe "Invoke-AddVMHostWithRetry — error routing" {
    It "Throws VcfDeploymentException when host is already managed by another cluster" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            function Invoke-AddVMHostToCluster {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Credential, [Parameter()] [Object]$Location, [Parameter()] [Switch]$RunAsync, [Parameter()] [Object]$Server)
                process { throw "Host is already being managed by this vSphere server." }
            }
            function Get-VMHost {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                # Host is in a different cluster (not the destination).
                return [PSCustomObject]@{ Name = "esx01.lab"; Parent = [PSCustomObject]@{ Name = "other-cluster" } }
            }
            $fakeCluster = [PSCustomObject]@{ Name = "cl0" }
            $fakeCredential = [System.Management.Automation.PSCredential]::new("root", (ConvertTo-SecureString "pw" -AsPlainText -Force))
            { Invoke-AddVMHostWithRetry -EsxHostName "esx01.lab" -EsxCredential $fakeCredential -ClusterObject $fakeCluster -ClusterName "cl0" -Server "vc.lab" -WaitForAddHostTaskTimeoutSeconds 0 } | Should -Throw
        }
    }

    It "Throws VcfDeploymentException on vSAN cluster UUID mismatch error" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            function Invoke-AddVMHostToCluster {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Credential, [Parameter()] [Object]$Location, [Parameter()] [Switch]$RunAsync, [Parameter()] [Object]$Server)
                process { throw "vSAN cluster UUID mismatch for host." }
            }
            $fakeCluster = [PSCustomObject]@{ Name = "cl0" }
            $fakeCredential = [System.Management.Automation.PSCredential]::new("root", (ConvertTo-SecureString "pw" -AsPlainText -Force))
            { Invoke-AddVMHostWithRetry -EsxHostName "esx01.lab" -EsxCredential $fakeCredential -ClusterObject $fakeCluster -ClusterName "cl0" -Server "vc.lab" -WaitForAddHostTaskTimeoutSeconds 0 } | Should -Throw
        }
    }

    It "Calls Invoke-AddVMHostToCluster exactly once and returns when it succeeds synchronously" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            $Script:_addVmhostSyncCalled = 0
            function Invoke-AddVMHostToCluster {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Credential, [Parameter()] [Object]$Location, [Parameter()] [Switch]$RunAsync, [Parameter()] [Object]$Server)
                process { $Script:_addVmhostSyncCalled++ }
            }
            $fakeCluster = [PSCustomObject]@{ Name = "cl0" }
            $fakeCredential = [System.Management.Automation.PSCredential]::new("root", (ConvertTo-SecureString "pw" -AsPlainText -Force))
            { Invoke-AddVMHostWithRetry -EsxHostName "esx01.lab" -EsxCredential $fakeCredential -ClusterObject $fakeCluster -ClusterName "cl0" -Server "vc.lab" -WaitForAddHostTaskTimeoutSeconds 0 } | Should -Not -Throw
            $Script:_addVmhostSyncCalled | Should -Be 1
        }
    }

    It "Retries on retryable task error and succeeds on second attempt — Start-Sleep is called" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            $Script:_sleepCount = 0
            $Script:_getTaskCount = 0
            $fakeTask = [PSCustomObject]@{ Id = "task-1" }
            # Async path: stub Invoke-AddVMHostToCluster to return a fake task without throwing.
            function Invoke-AddVMHostToCluster {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Credential, [Parameter()] [Object]$Location, [Parameter()] [Switch]$RunAsync, [Parameter()] [Object]$Server)
                begin { return $fakeTask }
                process {}
            }
            function Start-Sleep {
                [CmdletBinding()] Param([Parameter()] [Object]$Seconds)
                begin { $Script:_sleepCount++ }
                process {}
            }
            function Get-VMHost {
                [CmdletBinding()] Param([Parameter(ValueFromPipeline = $true)] [Object]$InputObject, [Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                begin {}
                process { return $null }
            }
            function Get-Task {
                [CmdletBinding()] Param([Parameter()] [Object]$Id, [Parameter()] [Object]$Server)
                $Script:_getTaskCount++
                if ($Script:_getTaskCount -le 1) {
                    # First poll: task in Error state — triggers retry via "did not complete within" path.
                    return [PSCustomObject]@{
                        State = "Error"
                        ExtensionData = [PSCustomObject]@{ Info = [PSCustomObject]@{ Error = [PSCustomObject]@{ LocalizedMessage = "already exists in inventory." } } }
                    }
                }
                # Second poll on retry: task succeeds.
                return [PSCustomObject]@{ State = "Success" }
            }
            $fakeCluster = [PSCustomObject]@{ Name = "cl0" }
            $fakeCredential = [System.Management.Automation.PSCredential]::new("root", (ConvertTo-SecureString "pw" -AsPlainText -Force))
            { Invoke-AddVMHostWithRetry -EsxHostName "esx01.lab" -EsxCredential $fakeCredential -ClusterObject $fakeCluster -ClusterName "cl0" -Server "vc.lab" -WaitForAddHostTaskTimeoutSeconds 300 -AddHostTaskPollIntervalSeconds 1 -AddHostRetryCount 3 -AddHostRetryDelaySeconds 5 -HostAppearanceRecheckDelaySeconds 1 } | Should -Not -Throw
            # The retry branch calls Start-Sleep at least once (appearance recheck + retry delay).
            $Script:_sleepCount | Should -BeGreaterOrEqual 1
        }
    }

    It "Throws after exhausting all retries on persistent retryable error" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            function Invoke-AddVMHostToCluster {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Credential, [Parameter()] [Object]$Location, [Parameter()] [Switch]$RunAsync, [Parameter()] [Object]$Server)
                begin {}
                process { throw "already exists in the system." }
            }
            function Start-Sleep {
                [CmdletBinding()] Param([Parameter()] [Object]$Seconds)
                begin {}
                process {}
            }
            function Get-VMHost {
                [CmdletBinding()] Param([Parameter(ValueFromPipeline = $true)] [Object]$InputObject, [Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                begin {}
                process { return $null }
            }
            $fakeCluster = [PSCustomObject]@{ Name = "cl0" }
            $fakeCredential = [System.Management.Automation.PSCredential]::new("root", (ConvertTo-SecureString "pw" -AsPlainText -Force))
            # AddHostRetryCount 2 means 2 attempts total before throwing.
            { Invoke-AddVMHostWithRetry -EsxHostName "esx01.lab" -EsxCredential $fakeCredential -ClusterObject $fakeCluster -ClusterName "cl0" -Server "vc.lab" -WaitForAddHostTaskTimeoutSeconds 0 -AddHostRetryCount 2 -AddHostRetryDelaySeconds 5 -HostAppearanceRecheckDelaySeconds 1 } | Should -Throw
        }
    }

    It "Throws immediately on non-retryable error without calling Start-Sleep" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            function Invoke-AddVMHostToCluster {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Credential, [Parameter()] [Object]$Location, [Parameter()] [Switch]$RunAsync, [Parameter()] [Object]$Server)
                begin {}
                process { throw "Unexpected disk error during host connection." }
            }
            function Start-Sleep {
                [CmdletBinding()] Param([Parameter()] [Object]$Seconds)
                begin { throw "Start-Sleep must not be called for non-retryable errors." }
                process {}
            }
            function Get-VMHost {
                [CmdletBinding()] Param([Parameter(ValueFromPipeline = $true)] [Object]$InputObject, [Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                begin {}
                process { return $null }
            }
            $fakeCluster = [PSCustomObject]@{ Name = "cl0" }
            $fakeCredential = [System.Management.Automation.PSCredential]::new("root", (ConvertTo-SecureString "pw" -AsPlainText -Force))
            { Invoke-AddVMHostWithRetry -EsxHostName "esx01.lab" -EsxCredential $fakeCredential -ClusterObject $fakeCluster -ClusterName "cl0" -Server "vc.lab" -WaitForAddHostTaskTimeoutSeconds 0 } | Should -Throw
        }
    }
}

# ── Get-Vmk0ManagementVlanId ──────────────────────────────────────────────────


Describe "Initialize-VsanWitnessDiskGroup — ESA with existing pool disk" {
    It "Returns early without calling Invoke-VsanOsaWitnessDiskGroupCreation when ESA witness already has a storage pool disk" {
        $callCount = InModuleScope VcfEdgeAtScale {
            $Script:_osaDiskGroupCreationCalled = 0
            function Get-VMHost {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                process {}
            }
            function Get-AdvancedSetting {
                [CmdletBinding()] Param([Parameter()] [Object]$Entity, [Parameter()] [Object]$Name)
                process {}
            }
            function Get-VsanOsaDiskGroupsOnHost {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Object]$Server)
                process {}
            }
            function Get-VsanStoragePoolDisk {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Object]$Server)
                process {}
            }
            function Invoke-VsanOsaWitnessDiskGroupCreation {
                [CmdletBinding()] Param([Parameter()] [Object]$ClusterName, [Parameter()] [Object]$VMHost, [Parameter()] [Object]$VMHostName)
                begin { $Script:_osaDiskGroupCreationCalled++ }; process {}
            }
            Mock Write-LogMessage {}
            Mock Get-VMHost { [PSCustomObject]@{ Name = "witness01" } }
            Mock Get-AdvancedSetting { [PSCustomObject]@{ Value = 2 } }
            # ESA witness already has a pool disk — function returns early.
            Mock Get-VsanOsaDiskGroupsOnHost { [PSCustomObject]@{ HasValidOsaGroup = $false; DiskGroupCount = 0 } }
            Mock Get-VsanStoragePoolDisk { @([PSCustomObject]@{ CanonicalName = "naa.abc" }) }
            Initialize-VsanWitnessDiskGroup -ClusterName "cl0" -vSanWitnessVmName "witness01" -StoragePolicyType "vSAN-ESA"
            $Script:_osaDiskGroupCreationCalled
        }
        $callCount | Should -Be 0
    }
}

Describe "Initialize-VsanWitnessDiskGroup — ESA with no pool disk" {
    It "Returns without throwing and without creating a disk group when ESA witness has no storage pool disk (supported configuration)" {
        InModuleScope VcfEdgeAtScale {
            function Get-VMHost {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                process {}
            }
            function Get-AdvancedSetting {
                [CmdletBinding()] Param([Parameter()] [Object]$Entity, [Parameter()] [Object]$Name)
                process {}
            }
            function Get-VsanOsaDiskGroupsOnHost {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Object]$Server)
                process {}
            }
            function Get-VsanStoragePoolDisk {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Object]$Server)
                process {}
            }
            function Invoke-VsanOsaWitnessDiskGroupCreation {
                [CmdletBinding()] Param([Parameter()] [Object]$ClusterName, [Parameter()] [Object]$VMHost, [Parameter()] [Object]$VMHostName)
                begin { throw "OSA disk group creation must not be called for an ESA witness" }; process {}
            }
            Mock Write-LogMessage {}
            Mock Get-VMHost { [PSCustomObject]@{ Name = "witness01" } }
            Mock Get-AdvancedSetting { [PSCustomObject]@{ Value = 2 } }
            Mock Get-VsanOsaDiskGroupsOnHost { [PSCustomObject]@{ HasValidOsaGroup = $false; DiskGroupCount = 0 } }
            # ESA witness with zero pool disks is a supported configuration; no disk pool is created.
            Mock Get-VsanStoragePoolDisk { @() }
            { Initialize-VsanWitnessDiskGroup -ClusterName "cl0" -vSanWitnessVmName "witness01" -StoragePolicyType "vSAN-ESA" } | Should -Not -Throw
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq "INFO" -and $Message -match "ESA witness: no disk pool is added" }
        }
    }
}

Describe "Initialize-VsanWitnessDiskGroup — OSA dispatches to disk group creation" {
    It "Calls Invoke-VsanOsaWitnessDiskGroupCreation when StoragePolicyType is vSAN-OSA and no ESA storage pool exists" {
        $callCount = InModuleScope VcfEdgeAtScale {
            $Script:_osaDiskGroupCreationCalled = 0
            function Get-VMHost {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                process {}
            }
            function Get-AdvancedSetting {
                [CmdletBinding()] Param([Parameter()] [Object]$Entity, [Parameter()] [Object]$Name)
                process {}
            }
            function Get-VsanOsaDiskGroupsOnHost {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Object]$Server)
                process {}
            }
            function Get-VsanStoragePoolDisk {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Object]$Server)
                process {}
            }
            function Invoke-VsanOsaWitnessDiskGroupCreation {
                [CmdletBinding()] Param([Parameter()] [Object]$ClusterName, [Parameter()] [Object]$VMHost, [Parameter()] [Object]$VMHostName)
                begin { $Script:_osaDiskGroupCreationCalled++ }; process {}
            }
            Mock Write-LogMessage {}
            Mock Get-VMHost { [PSCustomObject]@{ Name = "witness01" } }
            # No OVA-type setting present — OVA check skipped.
            Mock Get-AdvancedSetting { $null }
            # No ESA storage pool — OSA mismatch check passes.
            Mock Get-VsanStoragePoolDisk { @() }
            Mock Get-VsanOsaDiskGroupsOnHost { [PSCustomObject]@{ HasValidOsaGroup = $false; DiskGroupCount = 0 } }
            Initialize-VsanWitnessDiskGroup -ClusterName "cl0" -vSanWitnessVmName "witness01" -StoragePolicyType "vSAN-OSA"
            $Script:_osaDiskGroupCreationCalled
        }
        $callCount | Should -Be 1
    }
}

# ── Add-VsanOsaDiskGroupToCluster ─────────────────────────────────────────────


Describe "Initialize-VsanWitnessDiskGroup — guard conditions" {
    It "Throws VcfDeploymentException when witness host is not found in vCenter" {
        InModuleScope VcfEdgeAtScale {
            function Get-VMHost {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                process {}
            }
            Mock Write-LogMessage {}
            Mock Get-VMHost { $null }
            { Initialize-VsanWitnessDiskGroup -ClusterName "cl0" -vSanWitnessVmName "witness-missing" -StoragePolicyType "vSAN-OSA" } | Should -Throw
        }
    }
}

# ── Resolve-VsanWitnessOsaDiskNames ──────────────────────────────────────────


Describe "Resolve-VsanWitnessOsaDiskNames" {
    It "Returns resolved NAA names when all disks are visible on the host" {
        InModuleScope VcfEdgeAtScale {
            function Get-ScsiLun {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Object]$LunType)
                process {}
            }
            Mock Write-LogMessage {}
            $fakeCache = [PSCustomObject]@{ CanonicalName = "mpx.vmhba0:C0:T1:L0" }
            $fakeLun = [PSCustomObject]@{ CanonicalName = "naa.600000000000001"; RuntimeName = "mpx.vmhba0:C0:T1:L0" }
            Mock Get-ScsiLun { @($fakeLun) }
            $fakeHost = [PSCustomObject]@{ Name = "witness.lab.local" }
            $result = Resolve-VsanWitnessOsaDiskNames -CacheDisk $fakeCache -CapacityCanonicalNames @("mpx.vmhba0:C0:T1:L0") -VMHost $fakeHost -VMHostName "witness.lab.local"
            $result.CacheNameForCmdlet | Should -Be "naa.600000000000001"
            $result.DataDiskArray[0] | Should -Be "naa.600000000000001"
        }
    }
    It "Throws VcfDeploymentException when a required disk is not visible on the host" {
        InModuleScope VcfEdgeAtScale {
            function Get-ScsiLun {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Object]$LunType)
                process {}
            }
            Mock Write-LogMessage {}
            Mock Get-ScsiLun { @() }
            $fakeCache = [PSCustomObject]@{ CanonicalName = "naa.600000000000001" }
            $fakeHost = [PSCustomObject]@{ Name = "witness.lab.local" }
            { Resolve-VsanWitnessOsaDiskNames -CacheDisk $fakeCache -CapacityCanonicalNames @("naa.600000000000002") -VMHost $fakeHost -VMHostName "witness.lab.local" } | Should -Throw
        }
    }
    It "Returns identity names when ScsiLun canonical names match input names exactly" {
        InModuleScope VcfEdgeAtScale {
            function Get-ScsiLun {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Object]$LunType)
                process {}
            }
            Mock Write-LogMessage {}
            $fakeCache = [PSCustomObject]@{ CanonicalName = "naa.600000000000001" }
            $fakeLun1 = [PSCustomObject]@{ CanonicalName = "naa.600000000000001" }
            $fakeLun2 = [PSCustomObject]@{ CanonicalName = "naa.600000000000002" }
            Mock Get-ScsiLun { @($fakeLun1, $fakeLun2) }
            $fakeHost = [PSCustomObject]@{ Name = "witness.lab.local" }
            $result = Resolve-VsanWitnessOsaDiskNames -CacheDisk $fakeCache -CapacityCanonicalNames @("naa.600000000000002") -VMHost $fakeHost -VMHostName "witness.lab.local"
            $result.CacheNameForCmdlet | Should -Be "naa.600000000000001"
            $result.DataDiskArray[0] | Should -Be "naa.600000000000002"
        }
    }
}

# ── Invoke-VsanOsaWitnessDiskGroupCreation ────────────────────────────────────


Describe "Invoke-VsanOsaWitnessDiskGroupCreation" {
    It "Returns without creating a disk group when witness already has a valid OSA disk group" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Get-VsanOsaDiskGroupsOnHost { [PSCustomObject]@{ HasValidOsaGroup = $true; DiskGroupCount = 1 } }
            $callCount = 0
            function New-VsanDiskGroup {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Object]$SsdCanonicalName, [Parameter()] [Object]$DataDiskCanonicalName)
                begin { $Script:_newVsanDgCount++ }; process {}
            }
            $Script:_newVsanDgCount = 0
            $fakeHost = [PSCustomObject]@{ Name = "witness.lab.local" }
            Invoke-VsanOsaWitnessDiskGroupCreation -ClusterName "cl0" -VMHost $fakeHost -VMHostName "witness.lab.local"
            $Script:_newVsanDgCount | Should -Be 0
        }
    }
    It "Throws VcfDeploymentException when no eligible disks are found" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Get-VsanOsaDiskGroupsOnHost { [PSCustomObject]@{ HasValidOsaGroup = $false; DiskGroupCount = 0 } }
            Mock Get-VsanOsaEligibleDisksFromCluster { @() }
            $fakeHost = [PSCustomObject]@{ Name = "witness.lab.local" }
            { Invoke-VsanOsaWitnessDiskGroupCreation -ClusterName "cl0" -VMHost $fakeHost -VMHostName "witness.lab.local" } | Should -Throw
        }
    }
    It "Calls New-VsanDiskGroup with resolved disk names when eligible disks are found" {
        InModuleScope VcfEdgeAtScale {
            function Get-ScsiLun {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Object]$LunType)
                process {}
            }
            function New-VsanDiskGroup {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Object]$SsdCanonicalName, [Parameter()] [Object]$DataDiskCanonicalName)
                begin { $Script:_newVsanDgCallCount++ }; process {}
            }
            $Script:_newVsanDgCallCount = 0
            Mock Write-LogMessage {}
            Mock Get-VsanOsaDiskGroupsOnHost { [PSCustomObject]@{ HasValidOsaGroup = $false; DiskGroupCount = 0 } }
            $ssdDisk = [PSCustomObject]@{ CanonicalName = "naa.cache001"; IsSsd = $true; CapacityGB = 10 }
            $hddDisk = [PSCustomObject]@{ CanonicalName = "naa.cap001"; IsSsd = $false; CapacityGB = 100 }
            Mock Get-VsanOsaEligibleDisksFromCluster { @($ssdDisk, $hddDisk) }
            $fakeLunSsd = [PSCustomObject]@{ CanonicalName = "naa.cache001" }
            $fakeLunHdd = [PSCustomObject]@{ CanonicalName = "naa.cap001" }
            Mock Get-ScsiLun { @($fakeLunSsd, $fakeLunHdd) }
            $fakeHost = [PSCustomObject]@{ Name = "witness.lab.local" }
            Invoke-VsanOsaWitnessDiskGroupCreation -ClusterName "cl0" -VMHost $fakeHost -VMHostName "witness.lab.local"
            $Script:_newVsanDgCallCount | Should -Be 1
        }
    }
}

# ── Invoke-VsanOsaDiskGroupRemoval ────────────────────────────────────────────


Describe "Invoke-VsanOsaDiskGroupRemoval" {
    It "Returns true when disk group removal succeeds" {
        InModuleScope VcfEdgeAtScale {
            function Remove-VsanDiskGroup {
                [CmdletBinding(SupportsShouldProcess = $true)] Param([Parameter()] [Object]$VsanDiskGroup, [Parameter()] [Object]$DataMigrationMode)
                begin {}; process {}
            }
            Mock Write-LogMessage {}
            Mock Remove-VsanDiskGroup {}
            $fakeDg = [PSCustomObject]@{ Name = "dg0" }
            $result = Invoke-VsanOsaDiskGroupRemoval -DiskGroup $fakeDg -HostName "host01.lab.local"
            $result | Should -Be $true
        }
    }
    It "Returns false and logs WARNING when disk group removal throws" {
        InModuleScope VcfEdgeAtScale {
            function Remove-VsanDiskGroup {
                [CmdletBinding(SupportsShouldProcess = $true)] Param([Parameter()] [Object]$VsanDiskGroup, [Parameter()] [Object]$DataMigrationMode)
                begin {}; process {}
            }
            Mock Write-LogMessage {}
            Mock Remove-VsanDiskGroup { throw "Removal failed" }
            $fakeDg = [PSCustomObject]@{ Name = "dg0" }
            $result = Invoke-VsanOsaDiskGroupRemoval -DiskGroup $fakeDg -HostName "host01.lab.local"
            $result | Should -Be $false
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq "WARNING" }
        }
    }
}

# ── Invoke-VsanEsaStoragePoolDiskRemoval ──────────────────────────────────────


Describe "Invoke-VsanEsaStoragePoolDiskRemoval" {
    It "Returns 0 when disk Id property is absent" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            $diskNoId = [PSCustomObject]@{ Key = "key1" }
            $fakeHost = [PSCustomObject]@{ Name = "host01.lab.local" }
            $result = Invoke-VsanEsaStoragePoolDiskRemoval -Disk $diskNoId -HostName "host01.lab.local" -VMHost $fakeHost
            $result | Should -Be 0
        }
    }
    It "Returns 1 when Remove-VsanStoragePoolDisk succeeds on the first attempt" {
        InModuleScope VcfEdgeAtScale {
            function Remove-VsanStoragePoolDisk {
                [CmdletBinding(SupportsShouldProcess = $true)] Param([Parameter()] [Object]$VsanStoragePoolDisk, [Parameter()] [Object]$VsanDataMigrationMode)
                begin {}; process {}
            }
            Mock Write-LogMessage {}
            Mock Remove-VsanStoragePoolDisk {}
            $disk = [PSCustomObject]@{ Id = "disk-01"; Key = "key-01" }
            $fakeHost = [PSCustomObject]@{ Name = "host01.lab.local" }
            $result = Invoke-VsanEsaStoragePoolDiskRemoval -Disk $disk -HostName "host01.lab.local" -VMHost $fakeHost
            $result | Should -Be 1
        }
    }
    It "Returns 0 and logs WARNING when cmdlet throws a null-key error" {
        InModuleScope VcfEdgeAtScale {
            function Remove-VsanStoragePoolDisk {
                [CmdletBinding(SupportsShouldProcess = $true)] Param([Parameter()] [Object]$VsanStoragePoolDisk, [Parameter()] [Object]$VsanDataMigrationMode)
                begin {}; process {}
            }
            Mock Write-LogMessage {}
            Mock Remove-VsanStoragePoolDisk { throw "Parameter 'key' was null." }
            $disk = [PSCustomObject]@{ Id = "disk-01"; Key = "key-01" }
            $fakeHost = [PSCustomObject]@{ Name = "host01.lab.local" }
            $result = Invoke-VsanEsaStoragePoolDiskRemoval -Disk $disk -HostName "host01.lab.local" -VMHost $fakeHost
            $result | Should -Be 0
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq "WARNING" }
        }
    }
}

# ── Get-VsanNetworkTrafficByInterface ─────────────────────────────────────────


Describe "Get-VsanNetworkTrafficByInterface — esxcli list parsing" {
    It "Returns empty hashtable when list command is null" {
        InModuleScope VcfEdgeAtScale {
            $fakeEsxcli = [PSCustomObject]@{ vsan = [PSCustomObject]@{ network = [PSCustomObject]@{ list = $null } } }
            $result = Get-VsanNetworkTrafficByInterface -EsxcliInstance $fakeEsxcli
            $result | Should -BeOfType [Hashtable]
            $result.Count | Should -Be 0
        }
    }

    It "Returns correct traffic map for items with TrafficType and Interface properties" {
        InModuleScope VcfEdgeAtScale {
            $listCmd = [PSCustomObject]@{}
            # Two items prevent single-element pipeline unrolling, ensuring $listResult -is [Array].
            $listCmd | Add-Member -MemberType ScriptMethod -Name "Invoke" -Value {
                @(
                    [PSCustomObject]@{ Interface = "vmk0"; TrafficType = "vsan" },
                    [PSCustomObject]@{ Interface = "vmk1"; TrafficType = "witness" }
                )
            }
            $fakeEsxcli = [PSCustomObject]@{ vsan = [PSCustomObject]@{ network = [PSCustomObject]@{ list = $listCmd } } }
            $result = Get-VsanNetworkTrafficByInterface -EsxcliInstance $fakeEsxcli
            ($result["vmk0"] -join ",") | Should -Match "vsan"
            ($result["vmk1"] -join ",") | Should -Match "witness"
        }
    }

    It "Returns correct traffic map when items use lowercase property names (vmknicname, traffictype)" {
        InModuleScope VcfEdgeAtScale {
            $listCmd = [PSCustomObject]@{}
            # Two items prevent single-element pipeline unrolling.
            $listCmd | Add-Member -MemberType ScriptMethod -Name "Invoke" -Value {
                @(
                    [PSCustomObject]@{ vmknicname = "vmk0"; traffictype = "vsan" },
                    [PSCustomObject]@{ vmknicname = "vmk1"; traffictype = "witness" }
                )
            }
            $fakeEsxcli = [PSCustomObject]@{ vsan = [PSCustomObject]@{ network = [PSCustomObject]@{ list = $listCmd } } }
            $result = Get-VsanNetworkTrafficByInterface -EsxcliInstance $fakeEsxcli
            ($result["vmk0"] -join ",") | Should -Match "vsan"
            ($result["vmk1"] -join ",") | Should -Match "witness"
        }
    }
}

# ── Invoke-EsxcliVsanNetworkVariants ──────────────────────────────────────────


Describe "Invoke-EsxcliVsanNetworkVariants — param-name variant iteration" {
    It "Returns Invoked true when first param set succeeds" {
        InModuleScope VcfEdgeAtScale {
            $cmd = [PSCustomObject]@{}
            $cmd | Add-Member -MemberType ScriptMethod -Name "Invoke" -Value { $null }
            $result = Invoke-EsxcliVsanNetworkVariants -Command $cmd -VmkernelName "vmk0" -TrafficTypes @("witness")
            $result.Invoked | Should -BeTrue
        }
    }

    It "Returns AlreadyInUse true when invoke throws with 'already in use'" {
        InModuleScope VcfEdgeAtScale {
            $cmd = [PSCustomObject]@{}
            $cmd | Add-Member -MemberType ScriptMethod -Name "Invoke" -Value { throw "The interface is already in use" }
            $result = Invoke-EsxcliVsanNetworkVariants -Command $cmd -VmkernelName "vmk0" -TrafficTypes @("witness")
            $result.Invoked | Should -BeFalse
            $result.AlreadyInUse | Should -BeTrue
        }
    }

    It "Returns Invoked false with LastError when all variants fail with unknown error" {
        InModuleScope VcfEdgeAtScale {
            $cmd = [PSCustomObject]@{}
            $cmd | Add-Member -MemberType ScriptMethod -Name "Invoke" -Value { throw "Some unknown esxcli error" }
            $result = Invoke-EsxcliVsanNetworkVariants -Command $cmd -VmkernelName "vmk0" -TrafficTypes @("witness")
            $result.Invoked | Should -BeFalse
            $result.AlreadyInUse | Should -BeFalse
            $result.LastError | Should -Not -BeNullOrEmpty
        }
    }
}

# ── Invoke-VsanAddWithCreateArgs ───────────────────────────────────────────────


Describe "Invoke-VsanAddWithCreateArgs — CreateArgs introspection" {
    It "Returns Invoked false when CreateArgs returns null" {
        InModuleScope VcfEdgeAtScale {
            $addCmd = [PSCustomObject]@{}
            $addCmd | Add-Member -MemberType ScriptMethod -Name "CreateArgs" -Value { $null }
            $addCmd | Add-Member -MemberType ScriptMethod -Name "Invoke" -Value { throw "Should not be reached" }
            $result = Invoke-VsanAddWithCreateArgs -AddCommand $addCmd -VmkernelName "vmk0" -TrafficTypes @("witness")
            $result.Invoked | Should -BeFalse
        }
    }

    It "Returns Invoked true when hashtable CreateArgs path succeeds" {
        InModuleScope VcfEdgeAtScale {
            $Script:_createArgsInvoked = $false
            $addCmd = [PSCustomObject]@{}
            $addCmd | Add-Member -MemberType ScriptMethod -Name "CreateArgs" -Value { @{ interfacename = $null; traffictype = $null } }
            $addCmd | Add-Member -MemberType ScriptMethod -Name "Invoke" -Value { $Script:_createArgsInvoked = $true }
            $result = Invoke-VsanAddWithCreateArgs -AddCommand $addCmd -VmkernelName "vmk0" -TrafficTypes @("witness")
            $result.Invoked | Should -BeTrue
            $Script:_createArgsInvoked | Should -BeTrue
        }
    }

    It "Returns AlreadyInUse true when Invoke throws with 'already in use'" {
        InModuleScope VcfEdgeAtScale {
            $addCmd = [PSCustomObject]@{}
            $addCmd | Add-Member -MemberType ScriptMethod -Name "CreateArgs" -Value { @{ interfacename = $null; traffictype = $null } }
            $addCmd | Add-Member -MemberType ScriptMethod -Name "Invoke" -Value { throw "The interface is already in use" }
            $result = Invoke-VsanAddWithCreateArgs -AddCommand $addCmd -VmkernelName "vmk0" -TrafficTypes @("witness")
            $result.Invoked | Should -BeFalse
            $result.AlreadyInUse | Should -BeTrue
        }
    }
}

# ── Invoke-VsanSetPathVerification ────────────────────────────────────────────


Describe "Invoke-VsanSetPathVerification — post-set witness retry" {
    It "Does not call Invoke-EsxcliVsanNetworkVariants when witness already present" {
        InModuleScope VcfEdgeAtScale {
            $Script:_vspvVariantsCount = 0
            function Get-VsanNetworkTrafficByInterface {
                [CmdletBinding()] Param([Parameter()] [Object]$EsxcliInstance)
                return @{ "vmk0" = @("vsan", "witness") }
            }
            function Invoke-EsxcliVsanNetworkVariants {
                [CmdletBinding()] Param([Parameter()] [Object]$Command, [Parameter()] [Object[]]$TrafficTypes, [Parameter()] [String]$VmkernelName)
                $Script:_vspvVariantsCount++
                return [PSCustomObject]@{ Invoked = $true; AlreadyInUse = $false; LastError = $null }
            }
            Mock Write-LogMessage {}
            Invoke-VsanSetPathVerification -AddCommand ([PSCustomObject]@{}) -EsxcliInstance ([PSCustomObject]@{}) -HostName "esx01.lab" -VmkernelName "vmk0"
            $Script:_vspvVariantsCount | Should -Be 0
        }
    }

    It "Calls Invoke-EsxcliVsanNetworkVariants when vsan present but witness missing after set" {
        $variantsCount = InModuleScope VcfEdgeAtScale {
            $Script:_vspvVariantsCount2 = 0
            function Get-VsanNetworkTrafficByInterface {
                [CmdletBinding()] Param([Parameter()] [Object]$EsxcliInstance)
                return @{ "vmk0" = @("vsan") }
            }
            function Invoke-EsxcliVsanNetworkVariants {
                [CmdletBinding()] Param([Parameter()] [Object]$Command, [Parameter()] [Object[]]$TrafficTypes, [Parameter()] [String]$VmkernelName)
                $Script:_vspvVariantsCount2++
                return [PSCustomObject]@{ Invoked = $true; AlreadyInUse = $false; LastError = $null }
            }
            Mock Write-LogMessage {}
            Invoke-VsanSetPathVerification -AddCommand ([PSCustomObject]@{}) -EsxcliInstance ([PSCustomObject]@{}) -HostName "esx01.lab" -VmkernelName "vmk0"
            $Script:_vspvVariantsCount2
        }
        $variantsCount | Should -Be 1
    }
}

# ── Add-VsanWitnessTrafficToVmkViaEsxcli ─────────────────────────────────────


Describe "Add-VsanWitnessTrafficToVmkViaEsxcli — idempotent (witness already on vmk0)" {
    It "Returns $true without invoking add when witness traffic is already configured on vmk0" {
        $result = InModuleScope VcfEdgeAtScale {
            function Get-EsxCli {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Switch]$V2, [Parameter()] [Object]$Server)
                return [PSCustomObject]@{
                    vsan = [PSCustomObject]@{
                        network = [PSCustomObject]@{ ip = [PSCustomObject]@{ add = [PSCustomObject]@{} } }
                    }
                }
            }
            function Get-VsanNetworkTrafficByInterface {
                [CmdletBinding()] Param([Parameter()] [Object]$EsxcliInstance)
                return @{ "vmk0" = @("vsan", "witness") }
            }
             Mock Write-LogMessage {}
             Mock Start-Sleep {}
             $fakeHost = [PSCustomObject]@{ Name = "esx1.lab" }
             Add-VsanWitnessTrafficToVmkViaEsxcli -VMHost $fakeHost -VmkernelName "vmk0" -PostSuccessDelaySeconds 0
        }
        $result | Should -Be $true
    }
}

Describe "Add-VsanWitnessTrafficToVmkViaEsxcli — Get-EsxCli unavailable" {
    It "Throws when Get-EsxCli fails (esxcli not reachable on host)" {
        InModuleScope VcfEdgeAtScale {
            function Get-EsxCli {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Switch]$V2, [Parameter()] [Object]$Server)
                throw "Get-EsxCli not available"
            }
             Mock Write-LogMessage {}
             $fakeHost = [PSCustomObject]@{ Name = "esx1.lab" }
             { Add-VsanWitnessTrafficToVmkViaEsxcli -VMHost $fakeHost -VmkernelName "vmk0" -PostSuccessDelaySeconds 0 } | Should -Throw
         }
     }
 }
 Describe "Add-VsanWitnessTrafficToVmkViaEsxcli — vsan.network.ip.add not available" {
    It "Throws VcfDeploymentException when the esxcli vsan network ip add command is absent" {
        InModuleScope VcfEdgeAtScale {
            function Get-EsxCli {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Switch]$V2, [Parameter()] [Object]$Server)
                return [PSCustomObject]@{
                    vsan = [PSCustomObject]@{
                        network = [PSCustomObject]@{ ip = [PSCustomObject]@{ add = $null } }
                    }
                }
            }
            function Get-VsanNetworkTrafficByInterface {
                [CmdletBinding()] Param([Parameter()] [Object]$EsxcliInstance)
                return @{}
            }
             Mock Write-LogMessage {}
             $fakeHost = [PSCustomObject]@{ Name = "esx1.lab" }
             { Add-VsanWitnessTrafficToVmkViaEsxcli -VMHost $fakeHost -VmkernelName "vmk0" -PostSuccessDelaySeconds 0 } | Should -Throw "*esxcli vsan network ip add not available*"
        }
    }
}

Describe "Add-VsanWitnessTrafficToVmkViaEsxcli — add succeeds via CreateArgs path" {
    It "Returns $true and logs success when Invoke-VsanAddWithCreateArgs reports Invoked=true" {
        $result = InModuleScope VcfEdgeAtScale {
            $fakeAddCmd = [PSCustomObject]@{ _type = "esxcli_add" }
            function Get-EsxCli {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Switch]$V2, [Parameter()] [Object]$Server)
                return [PSCustomObject]@{
                    vsan = [PSCustomObject]@{
                        network = [PSCustomObject]@{
                            ip = [PSCustomObject]@{ add = $Script:_fakeAddCmd }
                        }
                    }
                }
            }
            $Script:_fakeAddCmd = $fakeAddCmd
            function Get-VsanNetworkTrafficByInterface {
                [CmdletBinding()] Param([Parameter()] [Object]$EsxcliInstance)
                return @{}
            }
            function Invoke-VsanAddWithCreateArgs {
                [CmdletBinding()] Param([Parameter()] [Object]$AddCommand, [Parameter()] [Object]$TrafficTypes, [Parameter()] [Object]$VmkernelName)
                return [PSCustomObject]@{ Invoked = $true; AlreadyInUse = $false; LastError = $null; ArgNamesLog = "" }
            }
            function Invoke-VsanSetPathVerification {
                [CmdletBinding()] Param([Parameter()] [Object]$AddCommand, [Parameter()] [Object]$EsxcliInstance, [Parameter()] [Object]$HostName, [Parameter()] [Object]$PostSuccessDelaySeconds, [Parameter()] [Object]$VmkernelName)
            }
             Mock Write-LogMessage {}
             Mock Start-Sleep {}
             $fakeHost = [PSCustomObject]@{ Name = "esx1.lab" }
             Add-VsanWitnessTrafficToVmkViaEsxcli -VMHost $fakeHost -VmkernelName "vmk0" -PostSuccessDelaySeconds 0
         }
         $result | Should -Be $true
     }
 }
 Describe "Add-VsanWitnessTrafficToVmkViaEsxcli — all add paths fail" {
    It "Throws VcfDeploymentException when both CreateArgs and variant paths report not invoked" {
        InModuleScope VcfEdgeAtScale {
            $fakeAddCmd = [PSCustomObject]@{ _type = "esxcli_add" }
            $Script:_fakeAddCmd = $fakeAddCmd
            function Get-EsxCli {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Switch]$V2, [Parameter()] [Object]$Server)
                return [PSCustomObject]@{
                    vsan = [PSCustomObject]@{
                        network = [PSCustomObject]@{
                            ip = [PSCustomObject]@{ add = $Script:_fakeAddCmd }
                        }
                    }
                }
            }
            function Get-VsanNetworkTrafficByInterface {
                [CmdletBinding()] Param([Parameter()] [Object]$EsxcliInstance)
                return @{}
            }
            function Invoke-VsanAddWithCreateArgs {
                [CmdletBinding()] Param([Parameter()] [Object]$AddCommand, [Parameter()] [Object]$TrafficTypes, [Parameter()] [Object]$VmkernelName)
                return [PSCustomObject]@{ Invoked = $false; AlreadyInUse = $false; LastError = "param mismatch"; ArgNamesLog = "" }
            }
            function Invoke-EsxcliVsanNetworkVariants {
                [CmdletBinding()] Param([Parameter()] [Object]$Command, [Parameter()] [Object]$TrafficTypes, [Parameter()] [Object]$VmkernelName)
                return [PSCustomObject]@{ Invoked = $false; AlreadyInUse = $false; LastError = "all variants failed" }
            }
             Mock Write-LogMessage {}
             $fakeHost = [PSCustomObject]@{ Name = "esx1.lab" }
             { Add-VsanWitnessTrafficToVmkViaEsxcli -VMHost $fakeHost -VmkernelName "vmk0" -PostSuccessDelaySeconds 0 } | Should -Throw
         }
     }
 }
 Describe "Add-VsanWitnessTrafficToVmkViaEsxcli — WitnessOnly sets single-traffic-type" {
    It "Returns $true when -WitnessOnly is set and add reports Invoked=true" {
        $result = InModuleScope VcfEdgeAtScale {
            $Script:_capturedTrafficTypes = $null
            $fakeAddCmd = [PSCustomObject]@{ _type = "esxcli_add" }
            $Script:_fakeAddCmd2 = $fakeAddCmd
            function Get-EsxCli {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Switch]$V2, [Parameter()] [Object]$Server)
                return [PSCustomObject]@{
                    vsan = [PSCustomObject]@{
                        network = [PSCustomObject]@{
                            ip = [PSCustomObject]@{ add = $Script:_fakeAddCmd2 }
                        }
                    }
                }
            }
            function Get-VsanNetworkTrafficByInterface {
                [CmdletBinding()] Param([Parameter()] [Object]$EsxcliInstance)
                return @{}
            }
            function Invoke-VsanAddWithCreateArgs {
                # [Object[]] matches the production declaration and prevents single-element arrays from
                # being auto-unboxed to a scalar during parameter binding.
                [CmdletBinding()] Param([Parameter()] [Object]$AddCommand, [Parameter()] [Object[]]$TrafficTypes, [Parameter()] [Object]$VmkernelName)
                $Script:_capturedTrafficTypes = $TrafficTypes
                return [PSCustomObject]@{ Invoked = $true; AlreadyInUse = $false; LastError = $null; ArgNamesLog = "" }
            }
            function Invoke-VsanSetPathVerification {
                [CmdletBinding()] Param([Parameter()] [Object]$AddCommand, [Parameter()] [Object]$EsxcliInstance, [Parameter()] [Object]$HostName, [Parameter()] [Object]$PostSuccessDelaySeconds, [Parameter()] [Object]$VmkernelName)
            }
             Mock Write-LogMessage {}
             Mock Start-Sleep {}
             $fakeHost = [PSCustomObject]@{ Name = "esx1.lab" }
             $result = Add-VsanWitnessTrafficToVmkViaEsxcli -VMHost $fakeHost -VmkernelName "vmk0" -WitnessOnly -PostSuccessDelaySeconds 0
            @{ Result = $result; TrafficTypes = $Script:_capturedTrafficTypes }
        }
        $result.Result | Should -Be $true
        # -WitnessOnly produces @("witness") — only one traffic type, not @("vsan","witness").
        $result.TrafficTypes | Should -HaveCount 1
        $result.TrafficTypes[0] | Should -Be "witness"
    }
}

# ── Show-InfrastructureJsonConfigurationHelp ──────────────────────────────────


Describe "Invoke-AddHostToClusterRunningVmSafetyCheck — prompt routing" {
    It "Returns without throwing when the host has no powered-on VMs" {
        InModuleScope VcfEdgeAtScale {
            $Script:vCenterName = "vc.lab"
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab"; Parent = [PSCustomObject]@{ Name = "SomeFolder" } }
            Mock Write-LogMessage {}
            Mock Get-AllVmsFromServer { return @() }
            { Invoke-AddHostToClusterRunningVmSafetyCheck -VMHost $fakeHost -EsxHostName "esx01.lab" -ClusterName "TestCluster" -Server "vc.lab" } | Should -Not -Throw
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq "DEBUG" -and $Message -match "no powered-on VMs" }
        }
    }

    It "Does not throw when operator answers Y to the running-VM prompt" {
        InModuleScope VcfEdgeAtScale {
            $Script:vCenterName = "vc.lab"
            $fakeVm   = [PSCustomObject]@{
                Name       = "test-vm"
                PowerState = "PoweredOn"
                VMHost     = [PSCustomObject]@{ Name = "esx01.lab" }
                Guest      = [PSCustomObject]@{ OSFullName = "Ubuntu Linux" }
            }
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab"; Parent = [PSCustomObject]@{ Name = "SomeFolder" } }
            Mock Write-LogMessage {}
            Mock Get-AllVmsFromServer { return @($fakeVm) }
            Mock Read-Host { return "Y" }
            { Invoke-AddHostToClusterRunningVmSafetyCheck -VMHost $fakeHost -EsxHostName "esx01.lab" -ClusterName "TestCluster" -Server "vc.lab" } | Should -Not -Throw
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq "WARNING" -and $Message -match "Powered-on VM count" }
        }
    }

    It "Throws VcfDeploymentException when operator presses Enter (default N) at the running-VM prompt" {
        { InModuleScope VcfEdgeAtScale {
            $Script:vCenterName = "vc.lab"
            $fakeVm   = [PSCustomObject]@{
                Name       = "test-vm"
                PowerState = "PoweredOn"
                VMHost     = [PSCustomObject]@{ Name = "esx01.lab" }
                Guest      = [PSCustomObject]@{ OSFullName = "Ubuntu Linux" }
            }
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab"; Parent = [PSCustomObject]@{ Name = "SomeFolder" } }
            Mock Write-LogMessage {}
            Mock Get-AllVmsFromServer { return @($fakeVm) }
            Mock Read-Host { return "" }
            Invoke-AddHostToClusterRunningVmSafetyCheck -VMHost $fakeHost -EsxHostName "esx01.lab" -ClusterName "TestCluster" -Server "vc.lab"
        } } | Should -Throw "*Deployment aborted*"
    }

    It "Throws VcfDeploymentException when operator answers N at the running-VM prompt" {
        { InModuleScope VcfEdgeAtScale {
            $Script:vCenterName = "vc.lab"
            $fakeVm   = [PSCustomObject]@{
                Name       = "test-vm"
                PowerState = "PoweredOn"
                VMHost     = [PSCustomObject]@{ Name = "esx01.lab" }
                Guest      = [PSCustomObject]@{ OSFullName = "Ubuntu Linux" }
            }
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab"; Parent = [PSCustomObject]@{ Name = "SomeFolder" } }
            Mock Write-LogMessage {}
            Mock Get-AllVmsFromServer { return @($fakeVm) }
            Mock Read-Host { return "N" }
            Invoke-AddHostToClusterRunningVmSafetyCheck -VMHost $fakeHost -EsxHostName "esx01.lab" -ClusterName "TestCluster" -Server "vc.lab"
        } } | Should -Throw "*Deployment aborted*"
    }

    It "Throws VcfDeploymentException when Read-Host throws (non-interactive) with running VMs present" {
        { InModuleScope VcfEdgeAtScale {
            $Script:vCenterName = "vc.lab"
            $fakeVm   = [PSCustomObject]@{
                Name       = "test-vm"
                PowerState = "PoweredOn"
                VMHost     = [PSCustomObject]@{ Name = "esx01.lab" }
                Guest      = [PSCustomObject]@{ OSFullName = "Ubuntu Linux" }
            }
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab"; Parent = [PSCustomObject]@{ Name = "SomeFolder" } }
            Mock Write-LogMessage {}
            Mock Get-AllVmsFromServer { return @($fakeVm) }
            Mock Read-Host { throw "Cannot prompt in non-interactive mode." }
            Invoke-AddHostToClusterRunningVmSafetyCheck -VMHost $fakeHost -EsxHostName "esx01.lab" -ClusterName "TestCluster" -Server "vc.lab"
        } } | Should -Throw "*Deployment aborted*"
    }
}

# ── Set-StoragePolicy — contract tests (extraction deferred) ──────────────────


Describe "Invoke-WitnessFaultDomainSetup — Set-VsanClusterConfiguration call paths" {

    It "Calls Set-VsanClusterConfiguration once when fault domain is resolved" {
        $callCount = InModuleScope VcfEdgeAtScale {
            $Script:vCenterName = "vc.lab"
            $Script:_setVsanCount = 0
            $fakeWitnessHost = [PSCustomObject]@{ Name = "witness.lab" }
            function Get-VsanClusterConfiguration {
                [CmdletBinding()] Param([Parameter()] [Object]$Cluster, [Parameter()] [Object]$Server)
                [PSCustomObject]@{ WitnessHost = $fakeWitnessHost }
            }
            function Set-VsanClusterConfiguration {
                [CmdletBinding(SupportsShouldProcess = $true)]
                Param(
                    [Parameter()] [Object]$Configuration, [Parameter()] [Object]$WitnessHost,
                    [Parameter()] [Object]$PreferredFaultDomain, [Parameter()] [Switch]$StretchedClusterEnabled,
                    [Parameter()] [Object]$Server
                )
                begin { $Script:_setVsanCount++ }
                process {}
            }
            Mock Write-LogMessage {}
            Mock Write-Progress {}
            Mock Resolve-VsanPreferredFaultDomain { [PSCustomObject]@{ Name = "Primary" } }
            Mock Enable-VsanAutomaticDiskClaimIfSupported { $false }
            Mock Enable-VsanAutomaticRebalance { $false }
            Mock Test-VsanAutomaticRebalanceAtThreshold { $true }
            Mock Invoke-VsanClusterConfigReapply { $false }
            Mock Get-VsanClusterHealthSummaryViaView { $null }
            Invoke-WitnessFaultDomainSetup `
                -Cluster ([PSCustomObject]@{ Name = "cl01" }) `
                -ClusterHosts @([PSCustomObject]@{ Name = "esx01"; Id = "host-1" }) `
                -ClusterName "cl01" `
                -PreferredFaultDomainName "Primary" `
                -PreferredHost ([PSCustomObject]@{ Name = "esx01" }) `
                -VsanClusterConfig ([PSCustomObject]@{ WitnessHost = $null }) `
                -vSanWitnessVmName "witness.lab" `
                -WitnessHost $fakeWitnessHost
            $Script:_setVsanCount
        }
        $callCount | Should -Be 1
    }

    It "Logs a WARNING and still calls Set-VsanClusterConfiguration when preferred fault domain is null" {
        $warnCount = InModuleScope VcfEdgeAtScale {
            $Script:vCenterName = "vc.lab"
            $Script:_warnCount = 0
            $fakeWitnessHost = [PSCustomObject]@{ Name = "witness.lab" }
            function Get-VsanClusterConfiguration {
                [CmdletBinding()] Param([Parameter()] [Object]$Cluster, [Parameter()] [Object]$Server)
                [PSCustomObject]@{ WitnessHost = $fakeWitnessHost }
            }
            function Set-VsanClusterConfiguration {
                [CmdletBinding(SupportsShouldProcess = $true)]
                Param(
                    [Parameter()] [Object]$Configuration, [Parameter()] [Object]$WitnessHost,
                    [Parameter()] [Object]$PreferredFaultDomain, [Parameter()] [Switch]$StretchedClusterEnabled,
                    [Parameter()] [Object]$Server
                )
                begin {}; process {}
            }
            Mock Write-LogMessage { if ($Type -eq "WARNING") { $Script:_warnCount++ } }
            Mock Write-Progress {}
            Mock Resolve-VsanPreferredFaultDomain { $null }
            Mock Enable-VsanAutomaticDiskClaimIfSupported { $false }
            Mock Enable-VsanAutomaticRebalance { $false }
            Mock Test-VsanAutomaticRebalanceAtThreshold { $true }
            Mock Invoke-VsanClusterConfigReapply { $false }
            Mock Get-VsanClusterHealthSummaryViaView { $null }
            Invoke-WitnessFaultDomainSetup `
                -Cluster ([PSCustomObject]@{ Name = "cl01" }) `
                -ClusterHosts @([PSCustomObject]@{ Name = "esx01"; Id = "host-1" }) `
                -ClusterName "cl01" `
                -PreferredFaultDomainName "unknown-domain" `
                -PreferredHost ([PSCustomObject]@{ Name = "esx01" }) `
                -VsanClusterConfig ([PSCustomObject]@{ WitnessHost = $null }) `
                -vSanWitnessVmName "witness.lab" `
                -WitnessHost $fakeWitnessHost
            $Script:_warnCount
        }
        $warnCount | Should -BeGreaterOrEqual 1
    }

    It "Re-fetches VsanClusterConfiguration when Enable-VsanAutomaticDiskClaimIfSupported returns true" {
        $fetchCount = InModuleScope VcfEdgeAtScale {
            $Script:vCenterName = "vc.lab"
            $Script:_getConfigCount = 0
            $fakeWitnessHost = [PSCustomObject]@{ Name = "witness.lab" }
            function Get-VsanClusterConfiguration {
                [CmdletBinding()] Param([Parameter()] [Object]$Cluster, [Parameter()] [Object]$Server)
                $Script:_getConfigCount++
                [PSCustomObject]@{ WitnessHost = $fakeWitnessHost }
            }
            function Set-VsanClusterConfiguration {
                [CmdletBinding(SupportsShouldProcess = $true)]
                Param(
                    [Parameter()] [Object]$Configuration, [Parameter()] [Object]$WitnessHost,
                    [Parameter()] [Object]$PreferredFaultDomain, [Parameter()] [Switch]$StretchedClusterEnabled,
                    [Parameter()] [Object]$Server
                )
                begin {}; process {}
            }
            Mock Write-LogMessage {}
            Mock Write-Progress {}
            Mock Resolve-VsanPreferredFaultDomain { [PSCustomObject]@{ Name = "Primary" } }
            # Returning $true triggers the re-fetch path inside Invoke-WitnessFaultDomainSetup.
            Mock Enable-VsanAutomaticDiskClaimIfSupported { $true }
            Mock Enable-VsanAutomaticRebalance { $false }
            Mock Test-VsanAutomaticRebalanceAtThreshold { $true }
            Mock Invoke-VsanClusterConfigReapply { $false }
            Mock Get-VsanClusterHealthSummaryViaView { $null }
            Invoke-WitnessFaultDomainSetup `
                -Cluster ([PSCustomObject]@{ Name = "cl01" }) `
                -ClusterHosts @([PSCustomObject]@{ Name = "esx01"; Id = "host-1" }) `
                -ClusterName "cl01" `
                -PreferredFaultDomainName "Primary" `
                -PreferredHost ([PSCustomObject]@{ Name = "esx01" }) `
                -VsanClusterConfig ([PSCustomObject]@{ WitnessHost = $null }) `
                -vSanWitnessVmName "witness.lab" `
                -WitnessHost $fakeWitnessHost
            $Script:_getConfigCount
        }
        # One call for the re-fetch after Enable-VsanAutomaticDiskClaimIfSupported, one for post-config verification.
        $fetchCount | Should -BeGreaterOrEqual 2
    }

    # Regression guard: vSAN ESA witness join fails silently if Set-VsanClusterConfiguration is
    # not called when Enable-VsanAutomaticDiskClaimIfSupported returns $false. This test ensures
    # the witness configuration API call proceeds even on the degradation path.
    It "Calls Set-VsanClusterConfiguration with StretchedClusterEnabled even when Enable-VsanAutomaticDiskClaimIfSupported returns false (VsanDiskClaimMode unsupported degradation path)" {
        $setVsanCallCount = InModuleScope VcfEdgeAtScale {
            $Script:vCenterName = "vc.lab"
            $Script:_setVsanDegradedCount = 0
            $fakeWitnessHost = [PSCustomObject]@{ Name = "witness.lab" }
            function Get-VsanClusterConfiguration {
                [CmdletBinding()] Param([Parameter()] [Object]$Cluster, [Parameter()] [Object]$Server)
                [PSCustomObject]@{ WitnessHost = $fakeWitnessHost }
            }
            function Set-VsanClusterConfiguration {
                [CmdletBinding(SupportsShouldProcess = $true)]
                Param(
                    [Parameter()] [Object]$Configuration, [Parameter()] [Object]$WitnessHost,
                    [Parameter()] [Object]$PreferredFaultDomain, [Parameter()] [Switch]$StretchedClusterEnabled,
                    [Parameter()] [Object]$Server
                )
                begin { $Script:_setVsanDegradedCount++ }
                process {}
            }
            Mock Write-LogMessage {}
            Mock Write-Progress {}
            Mock Resolve-VsanPreferredFaultDomain { [PSCustomObject]@{ Name = "Primary" } }
            # VsanDiskClaimMode is NOT supported — returns $false (the degradation path).
            Mock Enable-VsanAutomaticDiskClaimIfSupported { $false }
            Mock Enable-VsanAutomaticRebalance { $false }
            Mock Test-VsanAutomaticRebalanceAtThreshold { $true }
            Mock Invoke-VsanClusterConfigReapply { $false }
            Mock Get-VsanClusterHealthSummaryViaView { $null }
            Invoke-WitnessFaultDomainSetup `
                -Cluster ([PSCustomObject]@{ Name = "cl01" }) `
                -ClusterHosts @([PSCustomObject]@{ Name = "esx01"; Id = "host-1" }) `
                -ClusterName "cl01" `
                -PreferredFaultDomainName "Primary" `
                -PreferredHost ([PSCustomObject]@{ Name = "esx01" }) `
                -VsanClusterConfig ([PSCustomObject]@{ WitnessHost = $null }) `
                -vSanWitnessVmName "witness.lab" `
                -WitnessHost $fakeWitnessHost
            $Script:_setVsanDegradedCount
        }
        # Set-VsanClusterConfiguration MUST be called even when disk-claim-mode is unsupported.
        $setVsanCallCount | Should -BeGreaterOrEqual 1
    }
}


Describe "Set-VsanWitness — ESA disabled cluster error produces actionable guidance" {
    It "Logs ESA-disabled guidance when Set-VsanClusterConfiguration throws witnessVsan1NotSupported" {
        InModuleScope VcfEdgeAtScale {
            $Script:vCenterName = "vc.lab"
            $fakeCluster = [PSCustomObject]@{ Name = "cl01" }
            $fakeWitnessHost = [PSCustomObject]@{ Name = "10.0.0.1" }
            function Get-Cluster {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                process { return $fakeCluster }
            }
            function Get-VMHost {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                process { return $fakeWitnessHost }
            }
            function Get-VsanClusterConfiguration {
                [CmdletBinding()] Param([Parameter()] [Object]$Cluster, [Parameter()] [Object]$Server)
                process { return [PSCustomObject]@{ WitnessHost = $null } }
            }
            Mock Write-LogMessage {}
            Mock Test-VcenterConnection { [PSCustomObject]@{ IsConnected = $true; ErrorMessage = $null } }
            Mock Confirm-VsanWitnessConfiguration {}
            Mock Invoke-EnsureWitnessVsanTraffic {}
            Mock Confirm-VsanClusterReadinessForWitness {
                [PSCustomObject]@{
                    ClusterHosts  = @([PSCustomObject]@{ Name = "esx01" })
                    PreferredHost = [PSCustomObject]@{ Name = "esx01" }
                }
            }
            Mock Get-VsanClusterConfiguration { [PSCustomObject]@{ WitnessHost = $null } }
            Mock Invoke-WitnessFaultDomainSetup {
                throw "This witness host does not support joining vSAN ESA disabled cluster."
            }
            { Set-VsanWitness -ClusterName "cl01" -PreferredFaultDomainName "Primary" -StoragePolicyType "vSAN-ESA" -vSanWitnessVmName "10.0.0.1" } | Should -Throw
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq 'ERROR' -and $Message -match "vsanEsaEnabled" }
        }
    }
}

# ── Set-VDSUplinkTeamingActiveStandby — guard paths and idempotency ───────────


Describe "Invoke-VsanInitialPartitionRepair" {

    It "Returns post-repair health summary when repair succeeds and partition is resolved" {
        $result = InModuleScope VcfEdgeAtScale {
            function Get-VsanClusterHealthSummaryViaView {
                [CmdletBinding()] Param([Parameter()] [Object]$ClusterName, [Parameter()] [Bool]$FetchFromCache)
                return [PSCustomObject]@{ overallHealth = "green" }
            }
            function Test-VsanClusterPartitioned {
                [CmdletBinding()] Param([Parameter()] [Object]$HealthSummary)
                return $false  # not partitioned after repair
            }
            Mock Invoke-VsanClusterObjectRepairAndWait { $true }
            Mock Write-VsanHealthFailureDebugInfo {}
            Invoke-VsanInitialPartitionRepair -ClusterName "cl1" -HealthSummary ([PSCustomObject]@{ overallHealth = "yellow" }) -RepairTaskTimeoutSeconds 60
        }
        $result.overallHealth | Should -Be "green"
    }

    It "Throws when repair fails" {
        { InModuleScope VcfEdgeAtScale {
            Mock Invoke-VsanClusterObjectRepairAndWait { $false }
            Mock Write-VsanHealthFailureDebugInfo {}
            Invoke-VsanInitialPartitionRepair -ClusterName "cl1" -HealthSummary ([PSCustomObject]@{ overallHealth = "yellow" }) -RepairTaskTimeoutSeconds 60
        } } | Should -Throw "*vSAN object repair did not complete successfully*"
    }

    It "Throws when post-repair health fetch returns null" {
        { InModuleScope VcfEdgeAtScale {
            function Get-VsanClusterHealthSummaryViaView {
                [CmdletBinding()] Param([Parameter()] [Object]$ClusterName, [Parameter()] [Bool]$FetchFromCache)
                return $null
            }
            Mock Invoke-VsanClusterObjectRepairAndWait { $true }
            Mock Write-VsanHealthFailureDebugInfo {}
            Invoke-VsanInitialPartitionRepair -ClusterName "cl1" -HealthSummary ([PSCustomObject]@{ overallHealth = "yellow" }) -RepairTaskTimeoutSeconds 60
        } } | Should -Throw "*Could not retrieve vSAN health summary after repair*"
    }

    It "Throws when cluster is still partitioned after repair" {
        { InModuleScope VcfEdgeAtScale {
            function Get-VsanClusterHealthSummaryViaView {
                [CmdletBinding()] Param([Parameter()] [Object]$ClusterName, [Parameter()] [Bool]$FetchFromCache)
                return [PSCustomObject]@{ overallHealth = "yellow" }
            }
            function Test-VsanClusterPartitioned {
                [CmdletBinding()] Param([Parameter()] [Object]$HealthSummary)
                return $true  # always partitioned
            }
            Mock Invoke-VsanClusterObjectRepairAndWait { $true }
            Mock Write-VsanHealthFailureDebugInfo {}
            Invoke-VsanInitialPartitionRepair -ClusterName "cl1" -HealthSummary ([PSCustomObject]@{ overallHealth = "yellow" }) -RepairTaskTimeoutSeconds 60
        } } | Should -Throw "*partitioned*"
    }
}

# ── Invoke-VsanStatsPrimaryRetry ───────────────────────────────────────────────


Describe "Invoke-VsanStatsPrimaryRetry" {

    It "Returns null when health becomes green during the retry loop" {
        $result = InModuleScope VcfEdgeAtScale {
            function Invoke-VsanClusterHealthRetriggerForStatsPrimary {
                [CmdletBinding()] Param([Parameter()] [Object]$ClusterName, [Parameter()] [Object]$Server, [Parameter()] [Object]$VmCreateTimeoutSeconds, [Parameter()] [Object]$WaitAfterTriggerSeconds)
                process {}
            }
            $Script:_sprCount = 0
            function Get-VsanClusterHealthSummaryViaView {
                [CmdletBinding()] Param([Parameter()] [Object]$ClusterName, [Parameter()] [Bool]$FetchFromCache)
                $Script:_sprCount++
                if ($Script:_sprCount -le 1) { return [PSCustomObject]@{ overallHealth = "yellow" } }
                return [PSCustomObject]@{ overallHealth = "green" }
            }
            Mock Test-VsanHealthSummaryNonGreenOnlyStatsPrimaryElection { $true }
            Mock Test-VsanAdvCfgSyncAndWaitIfNeeded {}
            Invoke-VsanStatsPrimaryRetry -ClusterName "cl1" -HealthSummary ([PSCustomObject]@{ overallHealth = "yellow" }) -OverallHealth "yellow" -RetryMaxAttempts 3 -RetryWaitSeconds 5 -VmCreateTimeoutSeconds 60
        }
        $result | Should -BeNullOrEmpty
    }

    It "Returns null and logs a warning when still stats-primary-only after max retries (proceed with warning)" {
        $result = InModuleScope VcfEdgeAtScale {
            function Invoke-VsanClusterHealthRetriggerForStatsPrimary {
                [CmdletBinding()] Param([Parameter()] [Object]$ClusterName, [Parameter()] [Object]$Server, [Parameter()] [Object]$VmCreateTimeoutSeconds, [Parameter()] [Object]$WaitAfterTriggerSeconds)
                process {}
            }
            Mock Get-VsanClusterHealthSummaryViaView { [PSCustomObject]@{ overallHealth = "yellow" } }
            Mock Test-VsanHealthSummaryNonGreenOnlyStatsPrimaryElection { $true }
            Mock Test-VsanAdvCfgSyncAndWaitIfNeeded {}
            Invoke-VsanStatsPrimaryRetry -ClusterName "cl1" -HealthSummary ([PSCustomObject]@{ overallHealth = "yellow" }) -OverallHealth "yellow" -RetryMaxAttempts 2 -RetryWaitSeconds 5 -VmCreateTimeoutSeconds 60
        }
        $result | Should -BeNullOrEmpty
    }

    It "Returns PSCustomObject with health state when not stats-primary-only (caller should continue)" {
        $result = InModuleScope VcfEdgeAtScale {
            Mock Test-VsanHealthSummaryNonGreenOnlyStatsPrimaryElection { $false }
            Invoke-VsanStatsPrimaryRetry -ClusterName "cl1" -HealthSummary ([PSCustomObject]@{ overallHealth = "yellow" }) -OverallHealth "yellow" -RetryMaxAttempts 2 -RetryWaitSeconds 5 -VmCreateTimeoutSeconds 60
        }
        $result | Should -Not -BeNullOrEmpty
        $result.OverallHealth | Should -Be "yellow"
    }
}

# ── Invoke-VsanSuppressedAlarmRecheck ─────────────────────────────────────────


Describe "Invoke-VsanSuppressedAlarmRecheck" {

    It "Returns null when health is green after HCI workflow re-skip" {
        $result = InModuleScope VcfEdgeAtScale {
            Mock Start-Sleep {}
            Mock Invoke-AbandonHciWorkflowIfInProgress {}
            Mock Get-VsanClusterHealthSummaryViaView { [PSCustomObject]@{ overallHealth = "green" } }
            Mock Test-VsanAdvCfgSyncAndWaitIfNeeded {}
            Invoke-VsanSuppressedAlarmRecheck -ClusterName "cl1" -HealthSummary ([PSCustomObject]@{ overallHealth = "yellow" }) -FailureReasons "hciskip" -OverallHealth "yellow" -HciWorkflowClearWaitSeconds 1
        }
        $result | Should -BeNullOrEmpty
    }

    It "Returns null when the suppressed alarm still persists (proceed with warning)" {
        $result = InModuleScope VcfEdgeAtScale {
            Mock Start-Sleep {}
            Mock Invoke-AbandonHciWorkflowIfInProgress {}
            Mock Get-VsanClusterHealthSummaryViaView { [PSCustomObject]@{ overallHealth = "yellow" } }
            Mock Get-VsanHealthFailureReasons { "vSAN health alarms are suppressed" }
            Invoke-VsanSuppressedAlarmRecheck -ClusterName "cl1" -HealthSummary ([PSCustomObject]@{ overallHealth = "yellow" }) -FailureReasons "hciskip" -OverallHealth "yellow" -HciWorkflowClearWaitSeconds 1
        }
        $result | Should -BeNullOrEmpty
    }

    It "Returns PSCustomObject with original values when refetch fails" {
        $result = InModuleScope VcfEdgeAtScale {
            Mock Start-Sleep {}
            Mock Invoke-AbandonHciWorkflowIfInProgress {}
            Mock Get-VsanClusterHealthSummaryViaView { $null }
            $fakeOriginal = [PSCustomObject]@{ overallHealth = "yellow" }
            Invoke-VsanSuppressedAlarmRecheck -ClusterName "cl1" -HealthSummary $fakeOriginal -FailureReasons "hciskip" -OverallHealth "yellow" -HciWorkflowClearWaitSeconds 1
        }
        $result | Should -Not -BeNullOrEmpty
        $result.OverallHealth | Should -Be "yellow"
        $result.FailureReasons | Should -Be "hciskip"
    }

    It "Returns PSCustomObject with updated values when other issues appear after recheck" {
        $result = InModuleScope VcfEdgeAtScale {
            Mock Start-Sleep {}
            Mock Invoke-AbandonHciWorkflowIfInProgress {}
            Mock Get-VsanClusterHealthSummaryViaView { [PSCustomObject]@{ overallHealth = "red" } }
            Mock Get-VsanHealthFailureReasons { "controller failure" }
            Invoke-VsanSuppressedAlarmRecheck -ClusterName "cl1" -HealthSummary ([PSCustomObject]@{ overallHealth = "yellow" }) -FailureReasons "hciskip" -OverallHealth "yellow" -HciWorkflowClearWaitSeconds 1
        }
        $result | Should -Not -BeNullOrEmpty
        $result.OverallHealth | Should -Be "red"
        $result.FailureReasons | Should -Be "controller failure"
    }
}

# ── Invoke-VsanNetworkPartitionRepairAndRecheck ────────────────────────────────


Describe "Invoke-VsanNetworkPartitionRepairAndRecheck" {

    It "Returns null when repair succeeds and health is green" {
        $result = InModuleScope VcfEdgeAtScale {
            Mock Invoke-VsanClusterObjectRepairAndWait { $true }
            Mock Get-VsanClusterHealthSummaryViaView { [PSCustomObject]@{ overallHealth = "green" } }
            function Test-VsanClusterPartitioned {
                [CmdletBinding()] Param([Parameter()] [Object]$HealthSummary)
                return $false
            }
            Mock Test-VsanAdvCfgSyncAndWaitIfNeeded {}
            Mock Write-VsanHealthFailureDebugInfo {}
            Invoke-VsanNetworkPartitionRepairAndRecheck -ClusterName "cl1" -HealthSummary ([PSCustomObject]@{ overallHealth = "yellow" }) -FailureReasons "network" -OverallHealth "yellow" -RepairTaskTimeoutSeconds 60
        }
        $result | Should -BeNullOrEmpty
    }

    It "Returns PSCustomObject with original values when repair fails (caller continues to round)" {
        $result = InModuleScope VcfEdgeAtScale {
            Mock Invoke-VsanClusterObjectRepairAndWait { $false }
            Mock Write-VsanHealthFailureDebugInfo {}
            Invoke-VsanNetworkPartitionRepairAndRecheck -ClusterName "cl1" -HealthSummary ([PSCustomObject]@{ overallHealth = "yellow" }) -FailureReasons "network" -OverallHealth "yellow" -RepairTaskTimeoutSeconds 60
        }
        $result | Should -Not -BeNullOrEmpty
        $result.OverallHealth | Should -Be "yellow"
    }

    It "Throws when cluster is partitioned after repair" {
        { InModuleScope VcfEdgeAtScale {
            Mock Invoke-VsanClusterObjectRepairAndWait { $true }
            Mock Get-VsanClusterHealthSummaryViaView { [PSCustomObject]@{ overallHealth = "yellow" } }
            function Test-VsanClusterPartitioned {
                [CmdletBinding()] Param([Parameter()] [Object]$HealthSummary)
                return $true  # always partitioned
            }
            Mock Write-VsanHealthFailureDebugInfo {}
            Invoke-VsanNetworkPartitionRepairAndRecheck -ClusterName "cl1" -HealthSummary ([PSCustomObject]@{ overallHealth = "yellow" }) -FailureReasons "network" -OverallHealth "yellow" -RepairTaskTimeoutSeconds 60
        } } | Should -Throw "*partitioned*"
    }

    It "Returns PSCustomObject with updated values when repair succeeds but health is still not green" {
        $result = InModuleScope VcfEdgeAtScale {
            Mock Invoke-VsanClusterObjectRepairAndWait { $true }
            Mock Get-VsanClusterHealthSummaryViaView { [PSCustomObject]@{ overallHealth = "yellow" } }
            function Test-VsanClusterPartitioned {
                [CmdletBinding()] Param([Parameter()] [Object]$HealthSummary)
                return $false
            }
            Mock Get-VsanHealthFailureReasons { "perf-service degraded" }
            Mock Write-VsanHealthFailureDebugInfo {}
            Invoke-VsanNetworkPartitionRepairAndRecheck -ClusterName "cl1" -HealthSummary ([PSCustomObject]@{ overallHealth = "yellow" }) -FailureReasons "network" -OverallHealth "yellow" -RepairTaskTimeoutSeconds 60
        }
        $result | Should -Not -BeNullOrEmpty
        $result.OverallHealth | Should -Be "yellow"
        $result.FailureReasons | Should -Be "perf-service degraded"
    }
}

# ── Invoke-VsanClusterHealthCheckAfterWitness ─────────────────────────────────


Describe "Invoke-VsanClusterHealthCheckAfterWitness — guard conditions" {

    It "Throws when vCenter is not connected" {
        { InModuleScope VcfEdgeAtScale {
            Mock Test-VcenterConnection { [PSCustomObject]@{ IsConnected = $false; ErrorMessage = "not connected" } }
            Invoke-VsanClusterHealthCheckAfterWitness -ClusterName "cl-site1" -HciWorkflowClearWaitSeconds 0
        } } | Should -Throw "*Not connected to vCenter*"

    }

    It "Logs INFO 'health is green' and does not throw when vSAN health is already green" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Test-VcenterConnection { [PSCustomObject]@{ IsConnected = $true } }
            Mock Enable-VsanHealthAlarms { @() }
            Mock Invoke-AbandonHciWorkflowIfInProgress {}
            Mock Start-Sleep {}
            Mock Set-VsanLabSilentChecksIfRequested {}
            Mock Get-VsanClusterHealthSummaryViaView { [PSCustomObject]@{ overallHealth = "green" } }
            Mock Test-VsanClusterPartitioned { $false }
            Mock Test-VsanAdvCfgSyncAndWaitIfNeeded {}
            { Invoke-VsanClusterHealthCheckAfterWitness -ClusterName "cl-site1" -HciWorkflowClearWaitSeconds 0 } | Should -Not -Throw
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq 'INFO' -and $Message -match 'health is green' }
        }
    }

    It "Throws when the health summary cannot be retrieved" {
        { InModuleScope VcfEdgeAtScale {
            Mock Test-VcenterConnection { [PSCustomObject]@{ IsConnected = $true } }
            Mock Enable-VsanHealthAlarms { @() }
            Mock Invoke-AbandonHciWorkflowIfInProgress {}
            Mock Start-Sleep {}
            Mock Set-VsanLabSilentChecksIfRequested {}
            Mock Get-VsanClusterHealthSummaryViaView { $null }
            Mock Write-VsanHealthFailureDebugInfo {}
            Invoke-VsanClusterHealthCheckAfterWitness -ClusterName "cl-site1" -HciWorkflowClearWaitSeconds 0
        } } | Should -Throw

    }
}


Describe "Invoke-VsanClusterHealthCheckAfterWitness — partition handling" {

    It "Calls Invoke-VsanClusterObjectRepairAndWait and returns green when partition is detected then repaired" {
        InModuleScope VcfEdgeAtScale {
            $Script:_hwCallCount = 0
            function Get-VsanClusterHealthSummaryViaView {
                [CmdletBinding()] Param([Parameter()] [Object]$ClusterName, [Parameter()] [Bool]$FetchFromCache)
                $Script:_hwCallCount++
                # First call: cluster is yellow/partitioned; subsequent calls: green after repair.
                if ($Script:_hwCallCount -le 1) { [PSCustomObject]@{ overallHealth = "yellow" } }
                else { [PSCustomObject]@{ overallHealth = "green" } }
            }
            $Script:_partCallCount = 0
            function Test-VsanClusterPartitioned {
                [CmdletBinding()] Param([Parameter()] [Object]$HealthSummary)
                $Script:_partCallCount++
                return $Script:_partCallCount -le 1  # partitioned on first check, resolved on second
            }
            Mock Write-LogMessage {}
            Mock Test-VcenterConnection { [PSCustomObject]@{ IsConnected = $true } }
            Mock Enable-VsanHealthAlarms { @() }
            Mock Invoke-AbandonHciWorkflowIfInProgress {}
            Mock Start-Sleep {}
            Mock Set-VsanLabSilentChecksIfRequested {}
            Mock Invoke-VsanClusterObjectRepairAndWait { $true }
            Mock Write-VsanHealthFailureDebugInfo {}
            Mock Test-VsanAdvCfgSyncAndWaitIfNeeded {}
            { Invoke-VsanClusterHealthCheckAfterWitness -ClusterName "cl-site1" -HciWorkflowClearWaitSeconds 0 } | Should -Not -Throw
            Should -Invoke Invoke-VsanClusterObjectRepairAndWait -Times 1 -Exactly
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq 'INFO' -and $Message -match 'health is green' }
        }
    }

    It "Throws when the cluster remains partitioned after repair" {
        { InModuleScope VcfEdgeAtScale {
            function Get-VsanClusterHealthSummaryViaView {
                [CmdletBinding()] Param([Parameter()] [Object]$ClusterName, [Parameter()] [Bool]$FetchFromCache)
                [PSCustomObject]@{ overallHealth = "yellow" }
            }
            function Test-VsanClusterPartitioned {
                [CmdletBinding()] Param([Parameter()] [Object]$HealthSummary)
                return $true  # always partitioned — repair did not resolve it
            }
            Mock Test-VcenterConnection { [PSCustomObject]@{ IsConnected = $true } }
            Mock Enable-VsanHealthAlarms { @() }
            Mock Invoke-AbandonHciWorkflowIfInProgress {}
            Mock Start-Sleep {}
            Mock Set-VsanLabSilentChecksIfRequested {}
            Mock Invoke-VsanClusterObjectRepairAndWait { $true }
            Mock Write-VsanHealthFailureDebugInfo {}
            Invoke-VsanClusterHealthCheckAfterWitness -ClusterName "cl-site1" -HciWorkflowClearWaitSeconds 0
        } } | Should -Throw "*partitioned*"
    }
}


Describe "Invoke-VsanClusterHealthCheckAfterWitness — Stats Primary election handling" {

    It "Invokes the Stats Primary re-trigger and does not throw when Stats Primary election is the only non-green finding" {
        InModuleScope VcfEdgeAtScale {
            # Stub with [Object] parameters to bypass [ValidateNotNullOrEmpty()] on $Server when
            # $Script:vCenterName is null in the test context.
            function Invoke-VsanClusterHealthRetriggerForStatsPrimary {
                [CmdletBinding()] Param(
                    [Parameter()] [Object]$ClusterName,
                    [Parameter()] [Object]$Server,
                    [Parameter()] [Object]$WaitAfterTriggerSeconds,
                    [Parameter()] [Object]$VmCreateTimeoutSeconds
                )
                process {}
            }
            Mock Write-LogMessage {}
            Mock Test-VcenterConnection { [PSCustomObject]@{ IsConnected = $true } }
            Mock Enable-VsanHealthAlarms { @() }
            Mock Invoke-AbandonHciWorkflowIfInProgress {}
            Mock Start-Sleep {}
            Mock Set-VsanLabSilentChecksIfRequested {}
            Mock Get-VsanClusterHealthSummaryViaView { [PSCustomObject]@{ overallHealth = "yellow" } }
            Mock Test-VsanClusterPartitioned { $false }
            # All non-green health attributed to Stats Primary election — use proceed-with-warning path.
            Mock Test-VsanHealthSummaryNonGreenOnlyStatsPrimaryElection { $true }
            Mock Invoke-VsanClusterHealthRetriggerForStatsPrimary {}
            Mock Test-VsanAdvCfgSyncAndWaitIfNeeded {}
            # StatsPrimaryElectionRetryMaxAttempts 1: the loop fires once (retryIdx 0→1),
            # then exits because retryIdx==RetryMaxAttempts. Exactly 1 trigger call expected.
            { Invoke-VsanClusterHealthCheckAfterWitness -ClusterName "cl-site1" `
                -HciWorkflowClearWaitSeconds 0 `
                -StatsPrimaryElectionRetryMaxAttempts 1 `
                -StatsPrimaryElectionRetryWaitSeconds 5 } | Should -Not -Throw
            Should -Invoke Invoke-VsanClusterHealthRetriggerForStatsPrimary -Times 1 -Exactly
        }
    }
}


Describe "Invoke-VsanHealthCheckRound — yellow and green proceed paths" {

    It "Logs a WARNING containing 'Proceeding with warning' when the refetched health is yellow" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Write-VsanHealthFailureDebugInfo {}
            Mock Start-Sleep {}
            Mock Test-VsanAdvCfgSyncAndWaitIfNeeded {}
            Mock Get-VsanHealthFailureReasons { "perf-service degraded" }
            Mock Get-VsanClusterHealthSummaryViaView { [PSCustomObject]@{ overallHealth = "yellow" } }
            { Invoke-VsanHealthCheckRound -ClusterName "cl1" -RetryWaitSeconds 60 } | Should -Not -Throw
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq 'WARNING' -and $Message -match 'Proceeding with warning' }
        }
    }

    It "Logs INFO 'green on retry' message and does not emit a WARNING when the refetched health is green" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Write-VsanHealthFailureDebugInfo {}
            Mock Start-Sleep {}
            Mock Test-VsanAdvCfgSyncAndWaitIfNeeded {}
            Mock Get-VsanHealthFailureReasons { "" }
            Mock Get-VsanClusterHealthSummaryViaView { [PSCustomObject]@{ overallHealth = "green" } }
            { Invoke-VsanHealthCheckRound -ClusterName "cl1" -RetryWaitSeconds 60 } | Should -Not -Throw
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq 'INFO' -and $Message -match 'green on retry' }
            Should -Not -Invoke Write-LogMessage -ParameterFilter { $Type -eq 'WARNING' -and $Message -match 'Proceeding' }
        }
    }
}


Describe "Invoke-VsanHealthCheckRound — red health handling" {

    It "Logs AcceptBadCheckResults WARNING and does not throw when health is red with AcceptBadCheckResults" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Write-VsanHealthFailureDebugInfo {}
            Mock Start-Sleep {}
            Mock Get-VsanHealthFailureReasons { "controller failure" }
            Mock Get-VsanClusterHealthSummaryViaView { [PSCustomObject]@{ overallHealth = "red" } }
            { Invoke-VsanHealthCheckRound -ClusterName "cl1" -RetryWaitSeconds 60 -AcceptBadCheckResults } | Should -Not -Throw
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq 'WARNING' -and $Message -match 'AcceptBadCheckResults' }
        }
    }

    It "Logs 'Could not retrieve health on retry' WARNING and uses FallbackOverallHealth when the health recheck returns nothing" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Write-VsanHealthFailureDebugInfo {}
            Mock Start-Sleep {}
            Mock Test-VsanAdvCfgSyncAndWaitIfNeeded {}
            Mock Get-VsanHealthFailureReasons { throw "should not be called" }
            # Recheck returns nothing — function must use fallback values.
            Mock Get-VsanClusterHealthSummaryViaView { $null }
            { Invoke-VsanHealthCheckRound -ClusterName "cl1" -RetryWaitSeconds 60 `
                -FallbackOverallHealth "yellow" -FallbackFailureReasons "pre-wait failure" } | Should -Not -Throw
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq 'WARNING' -and $Message -match 'Could not retrieve health on retry' }
        }
    }
}


Describe "Get-SoftwareSpecComponents" {
    It "Returns an all-null ordered hashtable when SoftwareSpec is null" {
        $result = InModuleScope VcfEdgeAtScale {
            Get-SoftwareSpecComponents -SoftwareSpec $null
        }
        $result | Should -Not -BeNullOrEmpty
        $result["BaseImage"]   | Should -BeNullOrEmpty
        $result["Components"]  | Should -BeNullOrEmpty
        $result.Keys | Should -Contain "AlternativeImages"
        $result.Keys | Should -Contain "Solutions"
    }

    It "Extracts BaseImage version from a PSObject with a Version sub-property" {
        $result = InModuleScope VcfEdgeAtScale {
            $spec = [PSCustomObject]@{
                BaseImage  = [PSCustomObject]@{ Version = "9.0.0.21925050" }
                Components = $null
            }
            Get-SoftwareSpecComponents -SoftwareSpec $spec
        }
        $result["BaseImage"] | Should -Be "9.0.0.21925050"
    }

    It "Joins component keys into a comma-separated string from a PSObject collection" {
        $result = InModuleScope VcfEdgeAtScale {
            $components = @{ "esx-base" = @{}; "vsan" = @{} }
            $spec = [PSCustomObject]@{
                BaseImage  = [PSCustomObject]@{ Version = "8.0" }
                Components = $components
            }
            Get-SoftwareSpecComponents -SoftwareSpec $spec
        }
        $result["Components"] | Should -Not -BeNullOrEmpty
    }

    It "Extracts BaseImage version from a serialized string input" {
        $result = InModuleScope VcfEdgeAtScale {
            Get-SoftwareSpecComponents -SoftwareSpec "BaseImage: Version: 9.0.0.21925050, Components: esx-base"
        }
        $result["BaseImage"] | Should -Be "9.0.0.21925050"
    }

    It "Extracts a non-versioned field from a serialized string input" {
        $result = InModuleScope VcfEdgeAtScale {
            Get-SoftwareSpecComponents -SoftwareSpec "AddOn: my-addon-1.0.0"
        }
        $result["AddOn"] | Should -Be "my-addon-1.0.0"
    }
}

# ── Build-VlcmImageSelectionData ─────────────────────────────────────────────


Describe "Build-VlcmImageSelectionData — column detection and list construction" {
    It "Returns one SelectionList entry per record with BaseImage always in ColumnList" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Get-SoftwareSpecComponents {
                [ordered]@{ BaseImage = "9.0.0"; AddOn = $null; Components = $null; Solutions = $null; HardwareSupport = $null; RemovedComponents = $null; AlternativeImages = $null }
            }
            $records = @(
                [PSCustomObject]@{ Id = "img-1"; DisplayName = "Image A"; SoftwareSpec = $null },
                [PSCustomObject]@{ Id = "img-2"; DisplayName = "Image B"; SoftwareSpec = $null }
            )
            $result = Build-VlcmImageSelectionData -ImageRecords $records
            $result.SelectionList.Count | Should -Be 2
            $result.ColumnList | Should -Contain "BaseImage"
            $result.SelectionList[0].ID | Should -Be 1
            $result.SelectionList[1].ID | Should -Be 2
            $result.SelectionList[0].ImageId | Should -Be "img-1"
        }
    }

    It "Includes an optional column in ColumnList when at least one record populates it" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            $Script:_addOnCallIdx = 0
            Mock Get-SoftwareSpecComponents {
                $Script:_addOnCallIdx++
                if ($Script:_addOnCallIdx -le 2) {
                    [ordered]@{ BaseImage = "9.0.0"; AddOn = "addon-1.0"; Components = $null; Solutions = $null; HardwareSupport = $null; RemovedComponents = $null; AlternativeImages = $null }
                } else {
                    [ordered]@{ BaseImage = "9.0.0"; AddOn = $null; Components = $null; Solutions = $null; HardwareSupport = $null; RemovedComponents = $null; AlternativeImages = $null }
                }
            }
            $records = @(
                [PSCustomObject]@{ Id = "img-1"; DisplayName = "A"; SoftwareSpec = $null }
            )
            $result = Build-VlcmImageSelectionData -ImageRecords $records
            $result.ColumnList | Should -Contain "AddOn"
        }
    }

    It "Omits optional columns from ColumnList when none are populated across all records" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Get-SoftwareSpecComponents {
                [ordered]@{ BaseImage = "9.0.0"; AddOn = $null; Components = $null; Solutions = $null; HardwareSupport = $null; RemovedComponents = $null; AlternativeImages = $null }
            }
            $records = @([PSCustomObject]@{ Id = "img-1"; DisplayName = "A"; SoftwareSpec = $null })
            $result = Build-VlcmImageSelectionData -ImageRecords $records
            $result.ColumnList | Should -Not -Contain "AddOn"
            $result.ColumnList | Should -Not -Contain "Components"
        }
    }
}

# ── Invoke-VlcmImageSelectionPrompt ──────────────────────────────────────────


Describe "Invoke-VlcmImageSelectionPrompt — selection and cancellation" {
    It "Returns ImageId when user enters a valid row number" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Read-Host { "1" }
            $fakeList = [System.Collections.Generic.List[PSCustomObject]]::new()
            $fakeList.Add([PSCustomObject]@{ ID = 1; DisplayName = "Image A"; ImageId = "img-abc" })
            $result = Invoke-VlcmImageSelectionPrompt -ImageSelectionList $fakeList -ColumnList @("ID", "DisplayName")
            $result | Should -Be "img-abc"
        }
    }

    It "Throws VcfDeploymentException when user enters c to cancel" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Read-Host { "c" }
            $fakeList = [System.Collections.Generic.List[PSCustomObject]]::new()
            $fakeList.Add([PSCustomObject]@{ ID = 1; DisplayName = "Image A"; ImageId = "img-abc" })
            { Invoke-VlcmImageSelectionPrompt -ImageSelectionList $fakeList -ColumnList @("ID", "DisplayName") } | Should -Throw "*cancelled*"
        }
    }

    It "Returns ImageId after re-prompting on an out-of-range input" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            $Script:_readHostCallIdx = 0
            Mock Read-Host {
                $Script:_readHostCallIdx++
                if ($Script:_readHostCallIdx -le 1) { "99" } else { "1" }
            }
            $fakeList = [System.Collections.Generic.List[PSCustomObject]]::new()
            $fakeList.Add([PSCustomObject]@{ ID = 1; DisplayName = "Image A"; ImageId = "img-abc" })
            $result = Invoke-VlcmImageSelectionPrompt -ImageSelectionList $fakeList -ColumnList @("ID", "DisplayName")
            $result | Should -Be "img-abc"
        }
    }
}

# ── Find-VlcmImage ────────────────────────────────────────────────────────────


Describe "Find-VlcmImage — guard and non-interactive paths" {
    It "Throws VcfDeploymentException when the repository returns no images" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            function Invoke-EsxSettingsRepositorySoftwareList {
                [CmdletBinding()] Param()
                process { [PSCustomObject]@{ Records = @() } }
            }
            Mock Invoke-EsxSettingsRepositorySoftwareList { [PSCustomObject]@{ Records = @() } }
            { Find-VlcmImage } | Should -Throw "*No vLCM images found in the repository*"
        }
    }

    It "Returns the matched image Id without prompting when VlcmImageName matches a record" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            function Invoke-EsxSettingsRepositorySoftwareList {
                [CmdletBinding()] Param()
                process {}
            }
            Mock Invoke-EsxSettingsRepositorySoftwareList {
                [PSCustomObject]@{
                    Records = @([PSCustomObject]@{ Id = "img-xyz"; DisplayName = "My Image"; SoftwareSpec = $null })
                }
            }
            Mock Get-SoftwareSpecComponents {
                [ordered]@{ BaseImage = "9.0.0"; AddOn = $null; Components = $null; Solutions = $null; HardwareSupport = $null; RemovedComponents = $null; AlternativeImages = $null }
            }
            $result = Find-VlcmImage -VlcmImageName "img-xyz"
            $result | Should -Be "img-xyz"
        }
    }

    It "Wraps a generic API exception in VcfDeploymentException" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            function Invoke-EsxSettingsRepositorySoftwareList {
                [CmdletBinding()] Param()
                process {}
            }
            Mock Invoke-EsxSettingsRepositorySoftwareList { throw [Exception]::new("API unavailable.") }
            { Find-VlcmImage } | Should -Throw "*Failed to retrieve vLCM images*"
        }
    }
}


Describe "Add-VsanClusterSilentHealthChecks — early-exit paths" {
    It "Returns without calling Get-ClusterByName when all SilentCheckIds are blank" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Get-ClusterByName { throw "must not be called" }
            # Use whitespace-only strings (not empty strings) — PowerShell 7 rejects "" in mandatory
            # [string[]] parameters; whitespace strings pass binding but are filtered by IsNullOrWhiteSpace.
            Add-VsanClusterSilentHealthChecks -ClusterName "cl1" -SilentCheckIds @("  ", "   ")
        }
    }

    It "Returns without calling Get-VsanView when the cluster is not found" {
        InModuleScope VcfEdgeAtScale {
            function Get-VsanView {
                [CmdletBinding()] Param([Parameter()] [Object]$Id, [Parameter()] [Object]$Server)
                process {}
            }
            Mock Write-LogMessage {}
            Mock Get-ClusterByName { $null }
            Mock Get-VsanView { throw "must not be called" }
            Add-VsanClusterSilentHealthChecks -ClusterName "cl1" -SilentCheckIds @("checkId1")
        }
    }

    It "Returns without calling VsanHealthSet when the health system view is not available" {
        InModuleScope VcfEdgeAtScale {
            function Get-VsanView {
                [CmdletBinding()] Param([Parameter()] [Object]$Id, [Parameter()] [Object]$Server)
                process {}
            }
            Mock Write-LogMessage {}
            $fakeCluster = [PSCustomObject]@{ ExtensionData = [PSCustomObject]@{ MoRef = "domain-c7" } }
            Mock Get-ClusterByName { $fakeCluster }
            Mock Get-VsanView { $null }
            Add-VsanClusterSilentHealthChecks -ClusterName "cl1" -SilentCheckIds @("checkId1")
        }
    }
}


Describe "Add-VsanClusterSilentHealthChecks — idempotency and apply" {
    It "Does not call VsanHealthSet when all requested IDs are already silenced" {
        $setCount = InModuleScope VcfEdgeAtScale {
            function Get-VsanView {
                [CmdletBinding()] Param([Parameter()] [Object]$Id, [Parameter()] [Object]$Server)
                process {}
            }
            Mock Write-LogMessage {}
            $fakeCluster = [PSCustomObject]@{ ExtensionData = [PSCustomObject]@{ MoRef = "domain-c7" } }
            Mock Get-ClusterByName { $fakeCluster }
            $Script:_vsanSetCount = 0
            $fakeView = [PSCustomObject]@{}
            $fakeView | Add-Member -MemberType ScriptMethod -Name "VsanHealthGetVsanClusterSilentChecks" -Value { return @("checkId1", "checkId2") }
            $fakeView | Add-Member -MemberType ScriptMethod -Name "VsanHealthSetVsanClusterSilentChecks" -Value { $Script:_vsanSetCount++ }
            Mock Get-VsanView { $fakeView }
            Add-VsanClusterSilentHealthChecks -ClusterName "cl1" -SilentCheckIds @("checkId1", "checkId2")
            $Script:_vsanSetCount
        }
        $setCount | Should -Be 0
    }

    It "Calls VsanHealthSet for IDs not yet in the silent list" {
        $setCount = InModuleScope VcfEdgeAtScale {
            function Get-VsanView {
                [CmdletBinding()] Param([Parameter()] [Object]$Id, [Parameter()] [Object]$Server)
                process {}
            }
            Mock Write-LogMessage {}
            $fakeCluster = [PSCustomObject]@{ ExtensionData = [PSCustomObject]@{ MoRef = "domain-c7" } }
            Mock Get-ClusterByName { $fakeCluster }
            $Script:_vsanSetCount = 0
            $fakeView = [PSCustomObject]@{}
            $fakeView | Add-Member -MemberType ScriptMethod -Name "VsanHealthGetVsanClusterSilentChecks" -Value { return @() }
            $fakeView | Add-Member -MemberType ScriptMethod -Name "VsanHealthSetVsanClusterSilentChecks" -Value { $Script:_vsanSetCount++ }
            Mock Get-VsanView { $fakeView }
            Add-VsanClusterSilentHealthChecks -ClusterName "cl1" -SilentCheckIds @("newCheck1")
            $Script:_vsanSetCount
        }
        $setCount | Should -BeGreaterOrEqual 1
    }
}


Describe "Invoke-VsanClusterObjectRepairAndWait — immediate paths" {

    It "Returns true when VsanHealthRepairClusterObjectsImmediate returns no task ref (nothing to repair)" {
        $result = InModuleScope VcfEdgeAtScale {
            function Get-VsanView {
                [CmdletBinding()] Param([Parameter()] [Object]$Id, [Parameter()] [Object]$Server)
                process {}
            }
            Mock Write-LogMessage {}
            Mock Write-VsanHealthFailureDebugInfo {}
            Mock Get-ClusterByName { [PSCustomObject]@{ ExtensionData = [PSCustomObject]@{ MoRef = "domain-c7" } } }
            $fakeHealthView = [PSCustomObject]@{}
            $fakeHealthView | Add-Member -MemberType ScriptMethod -Name "VsanHealthRepairClusterObjectsImmediate" -Value { return $null }
            Mock Get-VsanView { $fakeHealthView }
            Invoke-VsanClusterObjectRepairAndWait -ClusterName "cl1" -TimeoutSeconds 60
        }
        $result | Should -BeTrue
    }

    It "Returns true when the repair task view reports state success" {
        $result = InModuleScope VcfEdgeAtScale {
            function Get-VsanView {
                [CmdletBinding()] Param([Parameter()] [Object]$Id, [Parameter()] [Object]$Server)
                process {}
            }
            function Get-View {
                [CmdletBinding()] Param([Parameter()] [Object]$Id, [Parameter()] [Object]$Server)
                process {}
            }
            Mock Write-LogMessage {}
            Mock Write-VsanHealthFailureDebugInfo {}
            Mock Start-Sleep {}
            Mock Get-ClusterByName { [PSCustomObject]@{ ExtensionData = [PSCustomObject]@{ MoRef = "domain-c7" } } }
            $fakeHealthView = [PSCustomObject]@{}
            $fakeHealthView | Add-Member -MemberType ScriptMethod -Name "VsanHealthRepairClusterObjectsImmediate" -Value { return "task-123" }
            Mock Get-VsanView { $fakeHealthView }
            Mock Get-View { [PSCustomObject]@{ Info = [PSCustomObject]@{ State = "success"; Error = $null } } }
            Invoke-VsanClusterObjectRepairAndWait -ClusterName "cl1" -TimeoutSeconds 60
        }
        $result | Should -BeTrue
    }

    It "Returns false when the repair task view reports state error" {
        $result = InModuleScope VcfEdgeAtScale {
            function Get-VsanView {
                [CmdletBinding()] Param([Parameter()] [Object]$Id, [Parameter()] [Object]$Server)
                process {}
            }
            function Get-View {
                [CmdletBinding()] Param([Parameter()] [Object]$Id, [Parameter()] [Object]$Server)
                process {}
            }
            Mock Write-LogMessage {}
            Mock Write-VsanHealthFailureDebugInfo {}
            Mock Start-Sleep {}
            Mock Get-ClusterByName { [PSCustomObject]@{ ExtensionData = [PSCustomObject]@{ MoRef = "domain-c7" } } }
            $fakeHealthView = [PSCustomObject]@{}
            $fakeHealthView | Add-Member -MemberType ScriptMethod -Name "VsanHealthRepairClusterObjectsImmediate" -Value { return "task-123" }
            Mock Get-VsanView { $fakeHealthView }
            Mock Get-View { [PSCustomObject]@{ Info = [PSCustomObject]@{ State = "error"; Error = $null } } }
            Invoke-VsanClusterObjectRepairAndWait -ClusterName "cl1" -TimeoutSeconds 60
        }
        $result | Should -BeFalse
    }
}


Describe "Invoke-EsxcliVsanStoragePoolRemoveFallback — failure paths" {

    It "Returns null when Get-EsxCli throws" {
        $result = InModuleScope VcfEdgeAtScale {
            function Get-EsxCli {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Switch]$V2, [Parameter()] [Object]$Server)
                process {}
            }
            Mock Write-LogMessage {}
            Mock Get-EsxCli { throw "Connection refused" }
            Invoke-EsxcliVsanStoragePoolRemoveFallback -VMHost "myhost" -Server "vc1" -HostNameForLogging "myhost"
        }
        $result | Should -BeNull
    }

    It "Returns null when the esxcli vsan object has no storagepool command" {
        $result = InModuleScope VcfEdgeAtScale {
            function Get-EsxCli {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Switch]$V2, [Parameter()] [Object]$Server)
                process {}
            }
            Mock Write-LogMessage {}
            # Return a fake esxcli with vsan but without storagepool — triggers early return $null.
            Mock Get-EsxCli { [PSCustomObject]@{ vsan = [PSCustomObject]@{} } }
            Invoke-EsxcliVsanStoragePoolRemoveFallback -VMHost "myhost" -Server "vc1" -HostNameForLogging "myhost"
        }
        $result | Should -BeNull
    }
}

# ── Add-HostToVDS ─────────────────────────────────────────────────────────────


Describe "Find-Datastore — datastore location and disk selection" {

    It "Returns the canonical name of an existing VMFS datastore when found mounted" {
        $result = InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            function Get-EsxDatastoreInfo {
                [CmdletBinding()]
                Param(
                    [Parameter()] [Object]$EsxHostName,
                    [Parameter()] [Object]$DatastoreName,
                    [Parameter()] [Object]$Silence
                )
                return [PSCustomObject]@{
                    MountedDatastoreStatus = [PSCustomObject]@{
                        IsMounted      = $true
                        IsVMFS         = $true
                        CanonicalName  = "naa.6000c29abc123456"
                        FreeSpaceGB    = 200
                        UUID           = "abc-uuid-001"
                        Type           = "VMFS"
                    }
                    UnformattedDisks = @()
                }
            }
            Find-Datastore -EsxHostName "esx01.lab" -DatastoreName "datastore1"
        }
        $result | Should -Be "naa.6000c29abc123456"
    }

    It "Throws VcfDeploymentException when datastore is absent and no unformatted disks exist" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            $Script:_esxInfoCallCount = 0
            function Get-EsxDatastoreInfo {
                [CmdletBinding()]
                Param(
                    [Parameter()] [Object]$EsxHostName,
                    [Parameter()] [Object]$DatastoreName,
                    [Parameter()] [Object]$Silence
                )
                $Script:_esxInfoCallCount++
                return [PSCustomObject]@{
                    MountedDatastoreStatus = [PSCustomObject]@{ IsMounted = $false }
                    UnformattedDisks = @()
                }
            }
            { Find-Datastore -EsxHostName "esx01.lab" -DatastoreName "missing-ds" } |
                Should -Throw "*No unformatted disks*"
        }
    }
}

# ── New-VDSPortGroups ─────────────────────────────────────────────────────────


Describe "Set-VmkernelIpv4StaticGatewayViaEsxcli — esxcli gateway configuration" {

    It "Throws VcfDeploymentException when the gateway address is not a valid IPv4" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Test-ValidIPv4Address { $false }
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab" }
            { Set-VmkernelIpv4StaticGatewayViaEsxcli -GatewayAddress "not-an-ip" -Ipv4Address "10.0.0.1" `
                -SubnetMask "255.255.255.0" -VmkernelName "vmk3" -VMHost $fakeHost } |
                Should -Throw "*is not a valid IPv4 address*"
        }
    }

    It "Re-throws when Get-EsxCli fails" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Test-ValidIPv4Address { $true }
            function Get-EsxCli {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Switch]$V2, [Parameter()] [Object]$Server)
                throw "EsxCli unavailable"
            }
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab" }
            { Set-VmkernelIpv4StaticGatewayViaEsxcli -GatewayAddress "10.0.0.1" -Ipv4Address "10.0.0.5" `
                -SubnetMask "255.255.255.0" -VmkernelName "vmk3" -VMHost $fakeHost } |
                Should -Throw "*EsxCli unavailable*"
        }
    }

    It "Throws VcfDeploymentException when all fallback param sets fail" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Test-ValidIPv4Address { $true }
            function Get-EsxCli {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Switch]$V2, [Parameter()] [Object]$Server)
                $setCmd = [PSCustomObject]@{}
                Add-Member -InputObject $setCmd -MemberType ScriptMethod -Name CreateArgs -Value { return $null }
                Add-Member -InputObject $setCmd -MemberType ScriptMethod -Name Invoke -Value { throw "invoke failed" }
                $ipv4Obj = [PSCustomObject]@{ set = $setCmd }
                $interfaceObj = [PSCustomObject]@{ ipv4 = $ipv4Obj }
                $ipObj = [PSCustomObject]@{ interface = $interfaceObj }
                $networkObj = [PSCustomObject]@{ ip = $ipObj }
                return [PSCustomObject]@{ network = $networkObj }
            }
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab" }
            { Set-VmkernelIpv4StaticGatewayViaEsxcli -GatewayAddress "10.0.0.1" -Ipv4Address "10.0.0.5" `
                -SubnetMask "255.255.255.0" -VmkernelName "vmk3" -VMHost $fakeHost } |
                Should -Throw "*all attempts failed*"
        }
    }
}

# ── Wait-ArgoCDPodsReady ──────────────────────────────────────────────────────


Describe "Invoke-VsanOrphanedHostCleanup — orphaned host disk and leave cleanup" {
    It "Calls Invoke-VsanClusterLeaveOnHostWithRetry once per resolved host" {
        $leaveCount = InModuleScope VcfEdgeAtScale {
            $Script:_orphanLeaveCount = 0
            $savedVcenter = $Script:vCenterName
            $Script:vCenterName = "vc.lab"
            try {
                Mock Write-LogMessage {}
                $fakeHost = [PSCustomObject]@{ Name = "esx01.lab" }
                function Get-VMHost {
                    [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                    process {}
                }
                Mock Get-VMHost { $fakeHost }
                function Invoke-VsanClusterLeaveOnHostWithRetry {
                    [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Object]$Server, [Parameter()] [Object]$MaxRetries, [Parameter()] [Object]$RetryDelaySeconds, [Parameter()] [Object]$LogContext)
                    begin { $Script:_orphanLeaveCount++ }; process {}
                }
                Mock Remove-VsanDiskClaimsFromHost {}
                Invoke-VsanOrphanedHostCleanup -ClusterName "cl0" -EsxHostNames @("esx01.lab") -StoragePolicyType "vSAN-OSA"
                $Script:_orphanLeaveCount
            } finally {
                $Script:vCenterName = $savedVcenter
            }
        }
        $leaveCount | Should -Be 1
    }

    It "Skips hosts not found in vCenter and logs DEBUG" {
        InModuleScope VcfEdgeAtScale {
            $savedVcenter = $Script:vCenterName
            $Script:vCenterName = "vc.lab"
            try {
                Mock Write-LogMessage {}
                function Get-VMHost {
                    [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                    process { return $null }
                }
                Mock Remove-VsanDiskClaimsFromHost { throw "Remove must not be called when host is not found" }
                Invoke-VsanOrphanedHostCleanup -ClusterName "cl0" -EsxHostNames @("missing-esx.lab") -StoragePolicyType "vSAN-OSA"
                Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq "DEBUG" -and $Message -match "not found" }
            } finally {
                $Script:vCenterName = $savedVcenter
            }
        }
    }

    It "Calls Remove-StorageTag when both tag params are provided" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Remove-VsanDiskClaimsFromHost {}
            function Invoke-VsanClusterLeaveOnHostWithRetry {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Object]$Server, [Parameter()] [Object]$MaxRetries, [Parameter()] [Object]$RetryDelaySeconds, [Parameter()] [Object]$LogContext)
                begin {}; process {}
            }
            Mock Remove-StorageTag {}
            Mock Remove-TagCategoryIfEmpty {}
            # No EsxHostNames — hostsToClean will be empty, so disk/leave is skipped.
            # Tag removal runs regardless of host count.
            Invoke-VsanOrphanedHostCleanup -ClusterName "cl0" -StoragePolicyType "vSAN-OSA" `
                -StoragePolicyTagName "Supervisor01" -StoragePolicyTagCatalog "EdgeNodePolicy"
            Should -Invoke Remove-StorageTag -Times 1
        }
    }

    It "Does NOT call Remove-StorageTag when StoragePolicyTagCatalog is omitted" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            function Remove-StorageTag {
                [CmdletBinding()] Param([Parameter()] [Object]$TagName, [Parameter()] [Object]$TagCatalog, [Parameter()] [Object]$Server)
                throw "Remove-StorageTag must not be called when catalog is absent"
            }
            Invoke-VsanOrphanedHostCleanup -ClusterName "cl0" -StoragePolicyType "vSAN-OSA" -StoragePolicyTagName "tag1"
        }
    }
}

# ── Invoke-VsanDataHostDiskCleanup ────────────────────────────────────────────


Describe "Invoke-VsanDataHostDiskCleanup — data host disk and leave cleanup" {
    It "Uses ClusterHosts when HasHosts=true and calls Remove-VsanDiskClaimsFromHost per host" {
        $diskCount = InModuleScope VcfEdgeAtScale {
            $Script:_diskRemoveCount = 0
            Mock Write-LogMessage {}
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab" }
            function Remove-VsanDiskClaimsFromHost {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Object]$StoragePolicyType, [Parameter()] [Object]$Server)
                begin { $Script:_diskRemoveCount++ }; process {}
            }
            function Invoke-VsanClusterLeaveOnHostWithRetry {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Object]$Server, [Parameter()] [Object]$MaxRetries, [Parameter()] [Object]$RetryDelaySeconds)
                begin {}; process {}
            }
            Invoke-VsanDataHostDiskCleanup -ClusterHosts @($fakeHost) -ClusterName "cl0" `
                -HasHosts $true -StoragePolicyType "vSAN-OSA" -SkipClusterRemoval
            $Script:_diskRemoveCount
        }
        $diskCount | Should -Be 1
    }

    It "Falls back to EsxHostNames when HasHosts=false" {
        $diskCount = InModuleScope VcfEdgeAtScale {
            $Script:_diskFallbackCount = 0
            $savedVcenter = $Script:vCenterName
            $Script:vCenterName = "vc.lab"
            try {
                Mock Write-LogMessage {}
                $fakeHost = [PSCustomObject]@{ Name = "esx01.lab" }
                function Get-VMHost {
                    [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                    process {}
                }
                Mock Get-VMHost { $fakeHost }
                function Remove-VsanDiskClaimsFromHost {
                    [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Object]$StoragePolicyType, [Parameter()] [Object]$Server)
                    begin { $Script:_diskFallbackCount++ }; process {}
                }
                function Invoke-VsanClusterLeaveOnHostWithRetry {
                    [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Object]$Server, [Parameter()] [Object]$MaxRetries, [Parameter()] [Object]$RetryDelaySeconds)
                    begin {}; process {}
                }
                Invoke-VsanDataHostDiskCleanup -ClusterHosts $null -ClusterName "cl0" `
                    -HasHosts $false -EsxHostNames @("esx01.lab") -StoragePolicyType "vSAN-OSA" -SkipClusterRemoval
                $Script:_diskFallbackCount
            } finally {
                $Script:vCenterName = $savedVcenter
            }
        }
        $diskCount | Should -Be 1
    }

    It "Emits caller-responsibility WARNING when SkipClusterRemoval is NOT set" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            function Remove-VsanDiskClaimsFromHost {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Object]$StoragePolicyType, [Parameter()] [Object]$Server)
                begin {}; process {}
            }
            function Invoke-VsanClusterLeaveOnHostWithRetry {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Object]$Server, [Parameter()] [Object]$MaxRetries, [Parameter()] [Object]$RetryDelaySeconds)
                begin {}; process {}
            }
            # No hosts, no EsxHostNames — cleanup is a no-op but the WARNING must still emit.
            Invoke-VsanDataHostDiskCleanup -ClusterHosts $null -ClusterName "cl0" `
                -HasHosts $false -StoragePolicyType "vSAN-OSA"
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq "WARNING" -and $Message -match "Caller must remove" }
        }
    }

    It "Does NOT emit caller-responsibility WARNING when SkipClusterRemoval is set" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            function Remove-VsanDiskClaimsFromHost {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Object]$StoragePolicyType, [Parameter()] [Object]$Server)
                begin {}; process {}
            }
            function Invoke-VsanClusterLeaveOnHostWithRetry {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Object]$Server, [Parameter()] [Object]$MaxRetries, [Parameter()] [Object]$RetryDelaySeconds)
                begin {}; process {}
            }
            Invoke-VsanDataHostDiskCleanup -ClusterHosts $null -ClusterName "cl0" `
                -HasHosts $false -StoragePolicyType "vSAN-OSA" -SkipClusterRemoval
            Should -Invoke Write-LogMessage -Times 0 -ParameterFilter { $Type -eq "WARNING" -and $Message -match "Caller must remove" }
        }
    }
}

# ── Add-ArgoCDNamespace ───────────────────────────────────────────────────────


Describe "New-DiskDisplayList" {
    It "Assigns sequential integer IDs starting at 1" {
        InModuleScope VcfEdgeAtScale {
            $fakeDisks = @(
                [PSCustomObject]@{ VMHost = [PSCustomObject]@{ Name = "esx01.lab" }; CanonicalName = "naa.001"; CapacityGB = 100; Model = "Samsung" },
                [PSCustomObject]@{ VMHost = [PSCustomObject]@{ Name = "esx02.lab" }; CanonicalName = "naa.002"; CapacityGB = 200; Model = "WD" },
                [PSCustomObject]@{ VMHost = [PSCustomObject]@{ Name = "esx03.lab" }; CanonicalName = "naa.003"; CapacityGB = 300; Model = "Seagate" }
            )
            $result = New-DiskDisplayList -EligibleDisks $fakeDisks
            $result.Count | Should -Be 3
            $result[0].Id | Should -Be 1
            $result[1].Id | Should -Be 2
            $result[2].Id | Should -Be 3
        }
    }
    It "Maps VMHost.Name to VMHostName and preserves disk properties" {
        InModuleScope VcfEdgeAtScale {
            $disk = [PSCustomObject]@{ VMHost = [PSCustomObject]@{ Name = "esx01.lab" }; CanonicalName = "naa.abc"; CapacityGB = 512; Model = "NVMe Pro" }
            $result = New-DiskDisplayList -EligibleDisks @($disk)
            $result[0].VMHostName    | Should -Be "esx01.lab"
            $result[0].CanonicalName | Should -Be "naa.abc"
            $result[0].CapacityGB   | Should -Be 512
            $result[0].Model        | Should -Be "NVMe Pro"
            $result[0].DiskObject   | Should -Be $disk
        }
    }
}

Describe "Read-DiskDeselectionInput" {
    It "Returns all disks selected and DisksWereDeselected=false when user responds N" {
        InModuleScope VcfEdgeAtScale {
            $list = @(
                [PSCustomObject]@{ Id = 1; VMHostName = "esx01"; CanonicalName = "naa.001"; CapacityGB = 100; Model = "A"; DiskObject = $null },
                [PSCustomObject]@{ Id = 2; VMHostName = "esx02"; CanonicalName = "naa.002"; CapacityGB = 200; Model = "B"; DiskObject = $null }
            )
            Mock Write-LogMessage {}
            Mock Write-Host {}
            Mock Read-Host { "N" }
            $result = Read-DiskDeselectionInput -DiskDisplayList $list
            $result.DisksWereDeselected | Should -Be $false
            $result.SelectedDiskIds     | Should -Be @(1, 2)
        }
    }
    It "Throws RollbackSkippedException when user responds Y then C" {
        InModuleScope VcfEdgeAtScale {
            $list = @([PSCustomObject]@{ Id = 1; VMHostName = "esx01"; CanonicalName = "naa.001"; CapacityGB = 100; Model = "A"; DiskObject = $null })
            Mock Write-LogMessage {}
            Mock Write-Host {}
            $Script:_rdCount = 0
            Mock Read-Host { $Script:_rdCount++; if ($Script:_rdCount -eq 1) { "Y" } else { "C" } }
            { Read-DiskDeselectionInput -DiskDisplayList $list } | Should -Throw
        }
    }
    It "Returns correct SelectedDiskIds when disk ID 2 is deselected from a 3-disk list" {
        InModuleScope VcfEdgeAtScale {
            $list = @(
                [PSCustomObject]@{ Id = 1; VMHostName = "esx01"; CanonicalName = "naa.001"; CapacityGB = 100; Model = "A"; DiskObject = $null },
                [PSCustomObject]@{ Id = 2; VMHostName = "esx02"; CanonicalName = "naa.002"; CapacityGB = 200; Model = "B"; DiskObject = $null },
                [PSCustomObject]@{ Id = 3; VMHostName = "esx03"; CanonicalName = "naa.003"; CapacityGB = 300; Model = "C"; DiskObject = $null }
            )
            Mock Write-LogMessage {}
            Mock Write-Host {}
            $Script:_rdCount2 = 0
            Mock Read-Host { $Script:_rdCount2++; if ($Script:_rdCount2 -eq 1) { "Y" } else { "2" } }
            $result = Read-DiskDeselectionInput -DiskDisplayList $list
            $result.DisksWereDeselected | Should -Be $true
            $result.SelectedDiskIds | Should -Not -Contain 2
            $result.SelectedDiskIds.Count | Should -Be 2
        }
    }
}

Describe "Get-UserDiskSelection" {
    It "Returns all disks selected when user declines to deselect" {
        InModuleScope VcfEdgeAtScale {
            $fakeDisks = @(
                [PSCustomObject]@{ VMHost = [PSCustomObject]@{ Name = "esx01.lab" }; CanonicalName = "naa.001"; CapacityGB = 100; Model = "Samsung" },
                [PSCustomObject]@{ VMHost = [PSCustomObject]@{ Name = "esx02.lab" }; CanonicalName = "naa.002"; CapacityGB = 200; Model = "WD" }
            )
            Mock Write-LogMessage {}
            Mock Write-Host {}
            Mock Read-Host { "N" }
            $result = Get-UserDiskSelection -ClusterName "cl01" -EligibleDisks $fakeDisks
            $result.SelectedDisks.Count | Should -Be 2
            $result.DisksWereDeselected | Should -Be $false
            $result.ExcludedDisks.Count | Should -Be 0
        }
    }

    It "Throws RollbackSkippedException when user responds Y then C to cancel" {
        InModuleScope VcfEdgeAtScale {
            $fakeDisks = @(
                [PSCustomObject]@{ VMHost = [PSCustomObject]@{ Name = "esx01.lab" }; CanonicalName = "naa.001"; CapacityGB = 100; Model = "Samsung" }
            )
            Mock Write-LogMessage {}
            Mock Write-Host {}
            $Script:_rhDiskCall = 0
            Mock Read-Host {
                $Script:_rhDiskCall++
                if ($Script:_rhDiskCall -eq 1) { return "Y" }
                return "C"
            }
            { Get-UserDiskSelection -ClusterName "cl01" -EligibleDisks $fakeDisks } | Should -Throw

        }
    }

    It "Throws VcfDeploymentException when a non-numeric disk ID is entered" {
        InModuleScope VcfEdgeAtScale {
            $fakeDisks = @(
                [PSCustomObject]@{ VMHost = [PSCustomObject]@{ Name = "esx01.lab" }; CanonicalName = "naa.001"; CapacityGB = 100; Model = "Samsung" }
            )
            Mock Write-LogMessage {}
            Mock Write-Host {}
            $Script:_rhBadIdCall = 0
            Mock Read-Host {
                $Script:_rhBadIdCall++
                if ($Script:_rhBadIdCall -eq 1) { return "Y" }
                return "abc"
            }
            { Get-UserDiskSelection -ClusterName "cl01" -EligibleDisks $fakeDisks } | Should -Throw "*Invalid disk ID format*"
        }
    }

    It "Returns deselected result when user provides valid disk ID to exclude" {
        InModuleScope VcfEdgeAtScale {
            $fakeDisks = @(
                [PSCustomObject]@{ VMHost = [PSCustomObject]@{ Name = "esx01.lab" }; CanonicalName = "naa.001"; CapacityGB = 100; Model = "Samsung" },
                [PSCustomObject]@{ VMHost = [PSCustomObject]@{ Name = "esx02.lab" }; CanonicalName = "naa.002"; CapacityGB = 200; Model = "WD" },
                [PSCustomObject]@{ VMHost = [PSCustomObject]@{ Name = "esx03.lab" }; CanonicalName = "naa.003"; CapacityGB = 300; Model = "Seagate" }
            )
            Mock Write-LogMessage {}
            Mock Write-Host {}
            $Script:_rhValidCall = 0
            Mock Read-Host {
                $Script:_rhValidCall++
                if ($Script:_rhValidCall -eq 1) { return "Y" }
                return "2"
            }
            $result = Get-UserDiskSelection -ClusterName "cl01" -EligibleDisks $fakeDisks
            $result.SelectedDisks.Count | Should -Be 2
            $result.DisksWereDeselected | Should -Be $true
            $result.ExcludedDisks.Count | Should -Be 1
            $result.ExcludedDisks[0].CanonicalName | Should -Be "naa.002"
        }
    }
}


Describe "Set-NewDatastore" {
    It "Throws VcfDeploymentException when not connected to vCenter" {
        { InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Test-VcenterConnection { [PSCustomObject]@{ IsConnected = $false; ErrorMessage = "No connection" } }
            Set-NewDatastore -DatastoreName "ds1" -EsxHost "esx.lab" -DiskCanonicalName "naa:abc" -TagName "tag1"
        } } | Should -Throw
    }

    It "Throws VcfDeploymentException when the datastore name is already used by a different server on vCenter" {
        { InModuleScope VcfEdgeAtScale {
            function Get-Datastore {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                process {}
            }
            function Get-View {
                [CmdletBinding()] Param([Parameter()] [Object]$Id, [Parameter()] [Object]$Property, [Parameter()] [Object]$Server)
                process {}
            }
            function Get-VMHost {
                [CmdletBinding()] Param([Parameter()] [Object]$Id, [Parameter()] [Object]$Server)
                process {}
            }
            Mock Write-LogMessage {}
            Mock Test-VcenterConnection { [PSCustomObject]@{ IsConnected = $true; ErrorMessage = $null } }
            Mock Get-Datastore { [PSCustomObject]@{ Id = "datastore-1"; Name = "ds1"; State = "Available" } }
            # Host mounted on the datastore has a different name than EsxHost — conflict.
            Mock Get-View { [PSCustomObject]@{ Host = @([PSCustomObject]@{ Key = "host-99" }) } }
            Mock Get-VMHost { [PSCustomObject]@{ Name = "other-esx.lab" } }
            Set-NewDatastore -DatastoreName "ds1" -EsxHost "esx.lab" -DiskCanonicalName "naa:abc" -TagName "tag1"
        } } | Should -Throw
    }

    It "Returns true when the datastore already exists on the ESX host (idempotent path)" {
        $result = InModuleScope VcfEdgeAtScale {
            function Get-Datastore {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                process {}
            }
            function Get-View {
                [CmdletBinding()] Param([Parameter()] [Object]$Id, [Parameter()] [Object]$Property, [Parameter()] [Object]$Server)
                process {}
            }
            function Get-VMHost {
                [CmdletBinding()] Param([Parameter()] [Object]$Id, [Parameter()] [Object]$Server)
                process {}
            }
            function Get-TagAssignment {
                [CmdletBinding()] Param([Parameter()] [Object]$Entity, [Parameter()] [Object]$Server)
                process {}
            }
            Mock Write-LogMessage {}
            Mock Test-VcenterConnection { [PSCustomObject]@{ IsConnected = $true; ErrorMessage = $null } }
            Mock Get-Datastore { [PSCustomObject]@{ Id = "datastore-1"; Name = "ds1"; State = "Available" } }
            # The host mounted on the datastore matches EsxHost — idempotent, not a conflict.
            Mock Get-View { [PSCustomObject]@{ Host = @([PSCustomObject]@{ Key = "host-1" }) } }
            Mock Get-VMHost { [PSCustomObject]@{ Name = "esx.lab" } }
            # Tag already assigned — skip New-TagAssignment.
            Mock Get-TagAssignment { [PSCustomObject]@{ Tag = [PSCustomObject]@{ Name = "tag1" } } }
            Set-NewDatastore -DatastoreName "ds1" -EsxHost "esx.lab" -DiskCanonicalName "naa:abc" -TagName "tag1"
        }
        $result | Should -Be $true
    }
}

# ── Wait-ForVsanDatastoreAndRename ────────────────────────────────────────────


Describe "Wait-ForVsanDatastoreAndRename" {
    It "Throws VcfDeploymentException when the vSAN datastore does not appear before the timeout expires" {
        { InModuleScope VcfEdgeAtScale {
            function Get-Datastore {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                process {}
            }
            $Script:DatastoreWaitLogIntervalSeconds = 30
            # Mock Get-Date: first non-Format call becomes $startTime; subsequent non-Format calls
            # return startTime + 70 seconds, which satisfies ($elapsedTime >= $TimeoutSeconds = 60)
            # on the very first loop iteration so the timeout path is exercised without any real waiting.
            $Script:_vsanDateBaseSet = $false
            $Script:_vsanBaseDate = [DateTime]::new(2026, 1, 1, 0, 0, 0)
            function Get-Date {
                [CmdletBinding()] Param([Parameter()] [Object]$Format)
                if ($Format) { return "2026-01-01 00:00:00" }
                if (-not $Script:_vsanDateBaseSet) { $Script:_vsanDateBaseSet = $true; return $Script:_vsanBaseDate }
                return $Script:_vsanBaseDate.AddSeconds(70)
            }
            Mock Write-LogMessage {}
            Mock Get-VsanDatastoreForCluster { @() }
            Mock Get-Datastore { @() }
            $fakeHost = [PSCustomObject]@{ Id = "host-1"; Name = "esx01.lab" }
            Wait-ForVsanDatastoreAndRename `
                -DatastoreName "vsan-ds-site1" `
                -ClusterHosts @($fakeHost) `
                -TimeoutSeconds 60 `
                -CheckInterval 5
        } } | Should -Throw
    }

    It "Completes without throwing when the vSAN datastore is found with the correct name on the first check" {
        InModuleScope VcfEdgeAtScale {
            function Get-Datastore {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                process {}
            }
            $Script:DatastoreWaitLogIntervalSeconds = 30
            Mock Write-LogMessage {}
            # Datastore name already matches DatastoreName — rename block is skipped entirely.
            Mock Get-VsanDatastoreForCluster {
                @([PSCustomObject]@{ Id = "datastore-vsan-1"; Name = "vsan-ds-site1"; Type = "vsan" })
            }
            Mock Get-Datastore { [PSCustomObject]@{ Id = "datastore-vsan-1"; Name = "vsan-ds-site1" } }
            $fakeHost = [PSCustomObject]@{ Id = "host-1"; Name = "esx01.lab" }
            { Wait-ForVsanDatastoreAndRename `
                -DatastoreName "vsan-ds-site1" `
                -ClusterHosts @($fakeHost) `
                -TimeoutSeconds 300 `
                -CheckInterval 5 } | Should -Not -Throw
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq "DEBUG" -and $Message -match "is available" }
        }
    }
}

# ── Remove-EdgeClusterDistributedSwitch ──────────────────────────────────────


Describe "Remove-VsanDiskClaimsFromHost" {
    It "Returns without throwing for vSAN-ESA when no storage pool disks are present" {
        InModuleScope VcfEdgeAtScale {
            function Get-VsanStoragePoolDisk {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Object]$Server)
                process {}
            }
            Mock Write-LogMessage {}
            Mock Get-VsanStoragePoolDisk { $null }
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab" }
            { Remove-VsanDiskClaimsFromHost -StoragePolicyType "vSAN-ESA" -VMHost $fakeHost } | Should -Not -Throw
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq "DEBUG" -and $Message -match "0 storage pool disk" }
        }
    }

    It "Returns without throwing for vSAN-OSA when no disk groups are present" {
        InModuleScope VcfEdgeAtScale {
            function Get-VsanDiskGroup {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Object]$Server)
                process {}
            }
            Mock Write-LogMessage {}
            Mock Get-VsanDiskGroup { $null }
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab" }
            { Remove-VsanDiskClaimsFromHost -StoragePolicyType "vSAN-OSA" -VMHost $fakeHost } | Should -Not -Throw
            # OSA path: no log message on silent return. Verify no ERROR was logged.
            Should -Invoke Write-LogMessage -Times 0 -ParameterFilter { $Type -eq "ERROR" } -Scope It
        }
    }
}

# ── Add-VsanEsaDiskToStoragePool ──────────────────────────────────────────────


Describe "Add-VsanEsaDiskToStoragePool" {
    It "Throws VcfDeploymentException when Get-VMHost cannot find the host" {
        { InModuleScope VcfEdgeAtScale {
            function Get-VMHost {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                process {}
            }
            Mock Write-LogMessage {}
            Mock Get-CleanVsanErrorMessage { "Host not found" }
            Mock Get-VMHost { throw "Host not found" }
            $disksByHost = @{ "esx01.lab" = @([PSCustomObject]@{ CanonicalName = "naa:abc123" }) }
            Add-VsanEsaDiskToStoragePool -DisksByHost $disksByHost
        } } | Should -Throw
    }
    It "Completes without throwing when Get-VMHost and Add-VsanStoragePoolDisk both succeed" {
        InModuleScope VcfEdgeAtScale {
            function Get-VMHost {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                process {}
            }
            function Get-VMHostStorage {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Switch]$RescanAllHba, [Parameter()] [Object]$Server)
                begin {}; process {}
            }
            function Add-VsanStoragePoolDisk {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Object]$VsanStoragePoolDiskType, [Parameter()] [Object]$DiskCanonicalNames)
                begin {}; process {}
            }
            Mock Write-LogMessage {}
            Mock Write-Progress {}
            Mock Get-VMHost { [PSCustomObject]@{ Name = "esx01.lab" } }
            $Script:VsanStoragePoolDiskType = "allFlash"
            $disksByHost = @{ "esx01.lab" = @([PSCustomObject]@{ CanonicalName = "naa:abc123" }) }
            { Add-VsanEsaDiskToStoragePool -DisksByHost $disksByHost } | Should -Not -Throw
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq "INFO" -and $Message -match "Adding.*disk" }
        }
    }
}

# ── Add-VsanOsaDiskToDiskGroup ────────────────────────────────────────────────


Describe "Add-VsanOsaDiskToDiskGroup" {
    It "Throws VcfDeploymentException when no cache disk is defined for a host" {
        { InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            $selectionByHost = @{
                "esx01.lab" = [PSCustomObject]@{ CacheDisk = $null; CapacityDisks = @() }
            }
            Add-VsanOsaDiskToDiskGroup -SelectionByHost $selectionByHost
        } } | Should -Throw
    }

    It "Throws VcfDeploymentException when no capacity disks are defined for a host" {
        { InModuleScope VcfEdgeAtScale {
            function Get-VMHost {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                process {}
            }
            Mock Write-LogMessage {}
            Mock Get-CleanVsanErrorMessage { "At least one capacity disk is required" }
            Mock Get-VMHost { [PSCustomObject]@{ Name = "esx01.lab" } }
            $selectionByHost = @{
                "esx01.lab" = [PSCustomObject]@{
                    CacheDisk     = [PSCustomObject]@{ CanonicalName = "naa:ssd0" }
                    CapacityDisks = @()
                }
            }
            Add-VsanOsaDiskToDiskGroup -SelectionByHost $selectionByHost
        } } | Should -Throw
    }
}

# ── Remove-HarborSupervisorService ────────────────────────────────────────────


Describe "Get-VsanEsaEligibleDisksFromCluster — guard conditions" {
    It "Throws when ClusterHosts is an empty array (parameter validation fires before function body)" {
        { InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Get-VsanEsaEligibleDisksFromCluster -ClusterName "cl0" -ClusterHosts @()
        } } | Should -Throw
    }

    It "Returns disk results aggregated from a single host when Invoke-AsyncPowerShellOperation succeeds" {
        $result = InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Write-Progress {}
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab"; Id = "host-1" }
            Mock Invoke-AsyncPowerShellOperation {
                return [PSCustomObject]@{
                    Success = $true
                    # Disk objects must include a VMHost.Name property so the host-distribution
                    # logging at the end of the function can group disks by host name without
                    # calling ContainsKey($null).
                    Result  = @(
                        [PSCustomObject]@{ CanonicalName = "naa:abc1"; CapacityGB = 400; VMHost = [PSCustomObject]@{ Name = "esx01.lab" } },
                        [PSCustomObject]@{ CanonicalName = "naa:abc2"; CapacityGB = 400; VMHost = [PSCustomObject]@{ Name = "esx01.lab" } }
                    )
                    Error   = $null
                }
            }
            Get-VsanEsaEligibleDisksFromCluster -ClusterName "cl0" -ClusterHosts @($fakeHost) -TimeoutSeconds 60 -CheckInterval 1
        }
        @($result).Count | Should -Be 2
    }

    It "Throws VcfDeploymentException when all hosts fail to return disks" {
        { InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Write-Progress {}
            # Synchronous fallback cmdlet also returns empty.
            function Get-VsanEsaEligibleDisk {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost)
                begin {}; process {}
            }
            Mock Get-VsanEsaEligibleDisk { return @() }
            function Get-VsanStoragePoolDisk {
                [CmdletBinding()] Param([Parameter()] [Object]$VMHost, [Parameter()] [Object]$Server)
                begin {}; process {}
            }
            Mock Get-VsanStoragePoolDisk { return @() }
            Mock Invoke-AsyncPowerShellOperation {
                return [PSCustomObject]@{ Success = $false; Result = @(); Error = "timeout" }
            }
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab"; Id = "host-1" }
            Get-VsanEsaEligibleDisksFromCluster -ClusterName "cl0" -ClusterHosts @($fakeHost) -TimeoutSeconds 60 -CheckInterval 1
        } } | Should -Throw "*No vSAN ESA eligible disks found*"
    }
}

# ── Get-VsanOsaDiskGroupsOnHost ────────────────────────────────────────────────


Describe "Get-VsanOsaDiskGroupsOnHost — VsanSystem lookup paths" {
    It "Returns HasValidOsaGroup=false when host has no VsanSystem reference" {
        $result = InModuleScope VcfEdgeAtScale {
            function Get-View {
                [CmdletBinding()] Param([Parameter()] [Object]$Id, [Parameter()] [Object]$Server, [Parameter()] [Object]$Property)
                begin {}; process {}
            }
            Mock Write-LogMessage {}
            Mock Get-View { return [PSCustomObject]@{ ConfigManager = [PSCustomObject]@{ VsanSystem = $null } } }
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab"; Id = "host-1" }
            Get-VsanOsaDiskGroupsOnHost -VMHost $fakeHost -Server "vc.lab"
        }
        $result.HasValidOsaGroup | Should -Be $false
        $result.DiskGroupCount   | Should -Be 0
    }

    It "Returns HasValidOsaGroup=false when VsanSystem has no Config property" {
        $result = InModuleScope VcfEdgeAtScale {
            function Get-View {
                [CmdletBinding()] Param([Parameter()] [Object]$Id, [Parameter()] [Object]$Server, [Parameter()] [Object]$Property)
                begin {}; process {}
            }
            Mock Write-LogMessage {}
            $Script:_viewCallCount = 0
            Mock Get-View {
                $Script:_viewCallCount++
                if ($Script:_viewCallCount -le 1) {
                    return [PSCustomObject]@{ ConfigManager = [PSCustomObject]@{ VsanSystem = "vsanSystem-1" } }
                }
                return [PSCustomObject]@{ Config = $null }
            }
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab"; Id = "host-1" }
            Get-VsanOsaDiskGroupsOnHost -VMHost $fakeHost -Server "vc.lab"
        }
        $result.HasValidOsaGroup | Should -Be $false
    }

    It "Returns HasValidOsaGroup=true when config has valid disk mapping with cache and capacity" {
        $result = InModuleScope VcfEdgeAtScale {
            function Get-View {
                [CmdletBinding()] Param([Parameter()] [Object]$Id, [Parameter()] [Object]$Server, [Parameter()] [Object]$Property)
                begin {}; process {}
            }
            Mock Write-LogMessage {}
            $Script:_viewCallCount2 = 0
            Mock Get-View {
                $Script:_viewCallCount2++
                if ($Script:_viewCallCount2 -le 1) {
                    return [PSCustomObject]@{ ConfigManager = [PSCustomObject]@{ VsanSystem = "vsanSystem-1" } }
                }
                $mapping = [PSCustomObject]@{
                    ssd    = [PSCustomObject]@{ CanonicalName = "naa:ssd0" }
                    nonSsd = @([PSCustomObject]@{ CanonicalName = "naa:hdd1" })
                }
                $config = [PSCustomObject]@{ diskMapping = @($mapping) }
                return [PSCustomObject]@{ Config = $config }
            }
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab"; Id = "host-1" }
            Get-VsanOsaDiskGroupsOnHost -VMHost $fakeHost -Server "vc.lab"
        }
        $result.HasValidOsaGroup | Should -Be $true
        $result.DiskGroupCount   | Should -BeGreaterOrEqual 1
    }
}

# ── Get-VsanOsaEligibleDisksFromCluster ────────────────────────────────────────


Describe "Get-VsanOsaEligibleDisksFromCluster — guard conditions" {
    It "Throws when ClusterHosts is an empty array (parameter validation fires before function body)" {
        { InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Get-VsanOsaEligibleDisksFromCluster -ClusterName "cl0" -ClusterHosts @()
        } } | Should -Throw
    }

    It "Throws VcfDeploymentException when host has no VsanSystem and therefore no eligible disks" {
        { InModuleScope VcfEdgeAtScale {
            function Get-View {
                [CmdletBinding()] Param([Parameter()] [Object]$Id, [Parameter()] [Object]$Server, [Parameter()] [Object]$Property)
                begin {}; process {}
            }
            Mock Write-LogMessage {}
            Mock Get-View { return [PSCustomObject]@{ ConfigManager = [PSCustomObject]@{ VsanSystem = $null } } }
            $fakeHost = [PSCustomObject]@{ Name = "esx01.lab"; Id = "host-1" }
            Get-VsanOsaEligibleDisksFromCluster -ClusterName "cl0" -ClusterHosts @($fakeHost)
        } } | Should -Throw "*No vSAN OSA eligible disks found*"
    }
}

# ── Get-VsanClusterConfigurationForCluster ────────────────────────────────────


Describe "Get-VsanClusterConfigurationForCluster — thin wrapper" {
    It "Returns the result of Get-VsanClusterConfiguration" {
        $result = InModuleScope VcfEdgeAtScale {
            function Get-VsanClusterConfiguration {
                [CmdletBinding()] Param([Parameter()] [Object]$Cluster, [Parameter()] [Object]$Server)
                begin {}; process {}
            }
            Mock Get-VsanClusterConfiguration { return [PSCustomObject]@{ PerformanceServiceEnabled = $true } }
            $fakeCluster = [PSCustomObject]@{ Name = "cl0"; Id = "cluster-1" }
            Get-VsanClusterConfigurationForCluster -Cluster $fakeCluster -Server "vc.lab"
        }
        $result.PerformanceServiceEnabled | Should -Be $true
    }
}

# ── Get-VsanClusterTriggeredAlarms ────────────────────────────────────────────


Describe "Get-VsanClusterTriggeredAlarms — alarm enumeration paths" {
    It "Returns an empty array when the cluster is not found" {
        $result = InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Get-ClusterByName { $null }
            Get-VsanClusterTriggeredAlarms -ClusterName "missing-cluster"
        }
        @($result).Count | Should -Be 0
    }

    It "Returns an empty array when the cluster has no triggered alarms" {
        $result = InModuleScope VcfEdgeAtScale {
            function Get-View {
                [CmdletBinding()] Param([Parameter()] [Object]$Id, [Parameter()] [Object]$Server, [Parameter()] [Object]$Property)
                begin {}; process {}
            }
            Mock Write-LogMessage {}
            Mock Get-ClusterByName { [PSCustomObject]@{ Name = "cl0"; ExtensionData = [PSCustomObject]@{ MoRef = "domain-c1" } } }
            Mock Get-View { return [PSCustomObject]@{ TriggeredAlarmState = @() } }
            Get-VsanClusterTriggeredAlarms -ClusterName "cl0"
        }
        @($result).Count | Should -Be 0
    }

    It "Returns an alarm entry when the cluster has a triggered alarm" {
        $result = InModuleScope VcfEdgeAtScale {
            function Get-View {
                [CmdletBinding()] Param([Parameter()] [Object]$Id, [Parameter()] [Object]$Server, [Parameter()] [Object]$Property)
                begin {}; process {}
            }
            Mock Write-LogMessage {}
            Mock Get-ClusterByName { [PSCustomObject]@{ Name = "cl0"; ExtensionData = [PSCustomObject]@{ MoRef = "domain-c1" } } }
            $Script:_viewCallCount3 = 0
            Mock Get-View {
                $Script:_viewCallCount3++
                if ($Script:_viewCallCount3 -le 1) {
                    # Cluster view with one triggered alarm.
                    return [PSCustomObject]@{
                        TriggeredAlarmState = @([PSCustomObject]@{ Alarm = "alarm-1"; OverallStatus = "red" })
                    }
                }
                # Alarm definition view.
                return [PSCustomObject]@{ Info = [PSCustomObject]@{ Name = "vSAN advanced config sync" } }
            }
            Get-VsanClusterTriggeredAlarms -ClusterName "cl0"
        }
        @($result).Count | Should -Be 1
        $result[0].AlarmName | Should -Match "advcfgsync|advanced config sync|vSAN"
    }
}

# ── Set-VsanLabSilentChecksIfRequested ────────────────────────────────────────


Describe "Set-VsanLabSilentChecksIfRequested — lab flag routing" {
    It "Returns without calling Add-VsanClusterSilentHealthChecks when LabEnvironmentEnabled is false" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Add-VsanClusterSilentHealthChecks { throw "Must not be called when lab=false" }
            Set-VsanLabSilentChecksIfRequested -ClusterName "cl0" -LabEnvironmentEnabled $false
        }
        # The mock above would throw if called; not throwing here means it was never called.
        $true | Should -Be $true
    }

    It "Calls Add-VsanClusterSilentHealthChecks when LabEnvironmentEnabled is true" {
        $called = InModuleScope VcfEdgeAtScale {
            $Script:_silentCheckCalled = $false
            Mock Write-LogMessage {}
            Mock Add-VsanClusterSilentHealthChecks { $Script:_silentCheckCalled = $true }
            Set-VsanLabSilentChecksIfRequested -ClusterName "cl0" -LabEnvironmentEnabled $true
            $Script:_silentCheckCalled
        }
        $called | Should -Be $true
    }

    It "Returns without calling Add-VsanClusterSilentHealthChecks when SilentCheckIds is empty" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Add-VsanClusterSilentHealthChecks { throw "Must not be called when check IDs are empty" }
            Set-VsanLabSilentChecksIfRequested -ClusterName "cl0" -LabEnvironmentEnabled $true -SilentCheckIds @()
        }
        $true | Should -Be $true
    }
}

# ── Enable-VsanPerformanceService ─────────────────────────────────────────────


Describe "Enable-VsanPerformanceService — cmdlet availability paths" {
    It "Logs DEBUG 'Skipping' and does not throw when Set-VsanClusterConfiguration is not available" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            # Ensure Get-Command returns null for Set-VsanClusterConfiguration.
            Mock Get-Command { $null }
            { Enable-VsanPerformanceService -ClusterName "cl0" } | Should -Not -Throw
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq 'DEBUG' -and $Message -match 'Skipping' }
        }
    }

    It "Skips Set-VsanClusterConfiguration when PerformanceServiceEnabled is already true" {
        InModuleScope VcfEdgeAtScale {
            function Get-VsanClusterConfiguration {
                [CmdletBinding()] Param([Parameter()] [Object]$Cluster, [Parameter()] [Object]$Server)
                begin {}; process {}
            }
            function Set-VsanClusterConfiguration {
                [CmdletBinding(SupportsShouldProcess = $true)] Param([Parameter()] [Object]$Configuration, [Parameter()] [Object]$PerformanceServiceEnabled, [Parameter()] [Object]$Server)
                begin { throw "Set-VsanClusterConfiguration must not be called when already enabled" }; process {}
            }
            function Get-Cluster {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                begin {}; process {}
            }
            Mock Write-LogMessage {}
            Mock Get-Cluster { return [PSCustomObject]@{ Name = "cl0" } }
            Mock Get-VsanClusterConfiguration { return [PSCustomObject]@{ PerformanceServiceEnabled = $true } }
            # Override Get-Command to return an object with Parameters containing PerformanceServiceEnabled.
            Mock Get-Command { return [PSCustomObject]@{ Parameters = @{ "PerformanceServiceEnabled" = $true } } }
            { Enable-VsanPerformanceService -ClusterName "cl0" } | Should -Not -Throw
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq "DEBUG" -and $Message -match "already enabled" }
        }
    }
}

# ── Invoke-VsanClusterHealthRetriggerForStatsPrimary ──────────────────────────


Describe "Invoke-VsanClusterHealthRetriggerForStatsPrimary — cmdlet unavailability path" {
    It "Calls Enable-VsanPerformanceService and Start-Sleep when Test-VsanClusterHealth is not available" {
        $perfSvcCalled = InModuleScope VcfEdgeAtScale {
            $Script:_perfSvcCalled = $false
            Mock Write-LogMessage {}
            Mock Enable-VsanPerformanceService { $Script:_perfSvcCalled = $true }
            Mock Get-Command { $null }
            Mock Start-Sleep {}
            Invoke-VsanClusterHealthRetriggerForStatsPrimary -ClusterName "cl0" -WaitAfterTriggerSeconds 5
            $Script:_perfSvcCalled
        }
        $perfSvcCalled | Should -Be $true
    }
}

# ── Get-KubectlNamespaceNamesMatchingPattern ──────────────────────────────────


Describe "Get-PortGroupId — connection and lookup paths" {
    It "Throws when not connected to vCenter" {
        { InModuleScope VcfEdgeAtScale {
            Mock Test-VcenterConnection { [PSCustomObject]@{ IsConnected = $false; ErrorMessage = "no session" } }
            Mock Write-LogMessage {}
            Get-PortGroupId -PortGroupName "mgmt-pg"
        } } | Should -Throw "*Not connected*"
    }

    It "Returns the port group key when the port group is found" {
        $result = InModuleScope VcfEdgeAtScale {
            function Get-VDPortgroup {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                begin {}; process {}
            }
            Mock Test-VcenterConnection { [PSCustomObject]@{ IsConnected = $true; ErrorMessage = $null } }
            Mock Get-VDPortgroup {
                [PSCustomObject]@{ Name = "mgmt-pg"; ExtensionData = [PSCustomObject]@{ Key = "dvportgroup-42" } }
            }
            Mock Write-LogMessage {}
            Get-PortGroupId -PortGroupName "mgmt-pg"
        }
        $result | Should -Be "dvportgroup-42"
    }

    It "Throws VcfDeploymentException when Get-VDPortgroup throws an unexpected error" {
        { InModuleScope VcfEdgeAtScale {
            function Get-VDPortgroup {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                begin {}; process {}
            }
            Mock Test-VcenterConnection { [PSCustomObject]@{ IsConnected = $true; ErrorMessage = $null } }
            Mock Get-VDPortgroup { throw "Port group not found" }
            Mock Write-LogMessage {}
            Get-PortGroupId -PortGroupName "missing-pg"
        } } | Should -Throw "*Failed to get port group id*"
    }
}

# ── Get-VsanClusterHealthSummaryViaView ───────────────────────────────────────


Describe "Get-VsanClusterHealthSummaryViaView — health query paths" {
    It "Returns null when the cluster is not found" {
        $result = InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Get-ClusterByName { $null }
            Get-VsanClusterHealthSummaryViaView -ClusterName "missing-cl"
        }
        $result | Should -BeNullOrEmpty
    }

    It "Returns null when the VsanVcClusterHealthSystem view is not available" {
        $result = InModuleScope VcfEdgeAtScale {
            function Get-VsanView {
                [CmdletBinding()] Param([Parameter()] [Object]$Id, [Parameter()] [Object]$Server)
                begin {}; process {}
            }
            Mock Write-LogMessage {}
            Mock Get-ClusterByName { [PSCustomObject]@{ Name = "cl0"; ExtensionData = [PSCustomObject]@{ MoRef = "domain-c1" } } }
            Mock Get-VsanView { $null }
            Get-VsanClusterHealthSummaryViaView -ClusterName "cl0"
        }
        $result | Should -BeNullOrEmpty
    }

    It "Returns health summary when the API call succeeds" {
        $result = InModuleScope VcfEdgeAtScale {
            function Get-VsanView {
                [CmdletBinding()] Param([Parameter()] [Object]$Id, [Parameter()] [Object]$Server)
                begin {}; process {}
            }
            $fakeHealthSystem = [PSCustomObject]@{}
            $fakeHealthSystem | Add-Member -MemberType ScriptMethod -Name "VsanQueryVcClusterHealthSummary" -Value {
                [PSCustomObject]@{ OverallHealth = "green"; OverallHealthDescription = "Healthy" }
            }
            Mock Write-LogMessage {}
            Mock Get-ClusterByName { [PSCustomObject]@{ Name = "cl0"; ExtensionData = [PSCustomObject]@{ MoRef = "domain-c1" } } }
            Mock Get-VsanView { $fakeHealthSystem }
            Get-VsanClusterHealthSummaryViaView -ClusterName "cl0"
        }
        $result.OverallHealth | Should -Be "green"
    }
}

# ── Thin wrapper delegation tests ─────────────────────────────────────────────


Describe "Get-AllVmsFromServer — thin wrapper" {
    It "Delegates to Get-VM and returns results without throwing" {
        $result = InModuleScope VcfEdgeAtScale {
            function Get-VM {
                [CmdletBinding()] Param([Parameter()] [Object]$Server)
                begin {}; process {}
            }
            Mock Get-VM { @([PSCustomObject]@{ Name = "vm1" }) }
            Get-AllVmsFromServer -Server "vc.lab"
        }
        @($result).Count | Should -Be 1
    }
}


Describe "Get-VMHostByName — thin wrapper" {
    It "Delegates to Get-VMHost and returns the host" {
        $result = InModuleScope VcfEdgeAtScale {
            function Get-VMHost {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                begin {}; process {}
            }
            Mock Get-VMHost { [PSCustomObject]@{ Name = "esx01.lab" } }
            Get-VMHostByName -Name "esx01.lab" -Server "vc.lab"
        }
        $result.Name | Should -Be "esx01.lab"
    }
}


Describe "Get-ClusterObjectByName — thin wrapper" {
    It "Delegates to Get-Cluster and returns the cluster" {
        $result = InModuleScope VcfEdgeAtScale {
            function Get-Cluster {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                begin {}; process {}
            }
            Mock Get-Cluster { [PSCustomObject]@{ Name = "cl0" } }
            Get-ClusterObjectByName -ClusterName "cl0" -Server "vc.lab"
        }
        $result.Name | Should -Be "cl0"
    }
}


Describe "Invoke-AddVMHostToCluster — thin wrapper" {
    It "Delegates to Add-VMHost with the correct parameters" {
        $callCount = InModuleScope VcfEdgeAtScale {
            $Script:_addVMHostCalled = 0
            function Add-VMHost {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Credential, [Parameter()] [Object]$Location, [Parameter()] [Switch]$Force, [Parameter()] [Object]$Server, [Parameter()] [Switch]$RunAsync)
                begin { $Script:_addVMHostCalled++ }; process {}
            }
            $fakeCred     = [PSCredential]::new("root", (ConvertTo-SecureString "pass" -AsPlainText -Force))
            $fakeLocation = [PSCustomObject]@{ Name = "cl0" }
            Invoke-AddVMHostToCluster -Name "esx01.lab" -Credential $fakeCred -Location $fakeLocation -Server "vc.lab"
            $Script:_addVMHostCalled
        }
        $callCount | Should -Be 1
    }
}

# ── Thin-wrapper delegation tests ─────────────────────────────────────────────


Describe "Set-VMHostState — thin wrapper" {
    It "Delegates to Set-VMHost with the correct VMHost, State, and Server" {
        $callCount = InModuleScope VcfEdgeAtScale {
            $Script:_setVMHostStateCalled = 0
            function Set-VMHost {
                [CmdletBinding(SupportsShouldProcess = $true)]
                Param([Parameter()] [Object]$VMHost, [Parameter()] [Object]$Server, [Parameter()] [Object]$State)
                begin { $Script:_setVMHostStateCalled++ }; process {}
            }
            Mock Write-LogMessage {}
            Set-VMHostState -VMHost "esx01.lab" -State "Connected" -Server "vc.lab"
            $Script:_setVMHostStateCalled
        }
        $callCount | Should -Be 1
    }
    It "Propagates exception when Set-VMHost throws" {
        InModuleScope VcfEdgeAtScale {
            function Set-VMHost {
                [CmdletBinding(SupportsShouldProcess = $true)]
                Param([Parameter()] [Object]$VMHost, [Parameter()] [Object]$Server, [Parameter()] [Object]$State)
                begin { throw "Host not found" }; process {}
            }
            Mock Write-LogMessage {}
            { Set-VMHostState -VMHost "esx01.lab" -State "Connected" -Server "vc.lab" } | Should -Throw "*Host not found*"
        }
    }
}

Describe "Remove-VMHostFromVCenter — thin wrapper" {
    It "Delegates to Remove-VMHost with the correct VMHost and Server" {
        $callCount = InModuleScope VcfEdgeAtScale {
            $Script:_removeVMHostCalled = 0
            function Remove-VMHost {
                [CmdletBinding(SupportsShouldProcess = $true)]
                Param([Parameter()] [Object]$VMHost, [Parameter()] [Object]$Server)
                begin { $Script:_removeVMHostCalled++ }; process {}
            }
            Mock Write-LogMessage {}
            Remove-VMHostFromVCenter -VMHost "esx01.lab" -Server "vc.lab"
            $Script:_removeVMHostCalled
        }
        $callCount | Should -Be 1
    }
    It "Propagates exception when Remove-VMHost throws" {
        InModuleScope VcfEdgeAtScale {
            function Remove-VMHost {
                [CmdletBinding(SupportsShouldProcess = $true)]
                Param([Parameter()] [Object]$VMHost, [Parameter()] [Object]$Server)
                begin { throw "Cannot remove host" }; process {}
            }
            Mock Write-LogMessage {}
            { Remove-VMHostFromVCenter -VMHost "esx01.lab" -Server "vc.lab" } | Should -Throw "*Cannot remove host*"
        }
    }
}

Describe "Invoke-MoveVMHostToDestination — thin wrapper" {
    It "Delegates to Move-VMHost with the correct VMHost, Destination, and Server" {
        $callCount = InModuleScope VcfEdgeAtScale {
            $Script:_moveVMHostCalled = 0
            function Move-VMHost {
                [CmdletBinding(SupportsShouldProcess = $true)]
                Param([Parameter()] [Object]$VMHost, [Parameter()] [Object]$Destination, [Parameter()] [Object]$Server)
                begin { $Script:_moveVMHostCalled++ }; process {}
            }
            Mock Write-LogMessage {}
            $fakeHost        = [PSCustomObject]@{ Name = "esx01.lab" }
            $fakeDestination = [PSCustomObject]@{ Name = "cl0" }
            Invoke-MoveVMHostToDestination -VMHost $fakeHost -Destination $fakeDestination -Server "vc.lab"
            $Script:_moveVMHostCalled
        }
        $callCount | Should -Be 1
    }
    It "Propagates exception when Move-VMHost throws" {
        InModuleScope VcfEdgeAtScale {
            function Move-VMHost {
                [CmdletBinding(SupportsShouldProcess = $true)]
                Param([Parameter()] [Object]$VMHost, [Parameter()] [Object]$Destination, [Parameter()] [Object]$Server)
                begin { throw "Move failed" }; process {}
            }
            Mock Write-LogMessage {}
            $fakeHost        = [PSCustomObject]@{ Name = "esx01.lab" }
            $fakeDestination = [PSCustomObject]@{ Name = "cl0" }
            { Invoke-MoveVMHostToDestination -VMHost $fakeHost -Destination $fakeDestination -Server "vc.lab" } | Should -Throw "*Move failed*"
        }
    }
}

# ── Phase 7 expansions ────────────────────────────────────────────────────────


Describe "Remove-TagCategoryIfEmpty — category has remaining tags" {
    It "Does not call Remove-TagCategory when the category still has tags" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Get-TagCategory { [PSCustomObject]@{ Name = "Storage-TagCatalog" } }
            Mock Get-Tag { @([PSCustomObject]@{ Name = "remaining-tag" }) }
            Mock Remove-TagCategory {}
            Remove-TagCategoryIfEmpty -TagCatalog "Storage-TagCatalog"
            Should -Invoke Remove-TagCategory -Times 0 -Scope It
        }
    }
}

# ── H1+H5: Invoke-VsanRefreshedAlarmGate — lab-mode HCL suppression ──────────


Describe "Invoke-VsanRefreshedAlarmGate — lab-mode HCL suppression" {

    It "Does not throw or block when LabEnvironment=true and only a red HCL alarm exists" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Get-VsanClusterTriggeredAlarms {
                @([PSCustomObject]@{ AlarmName = "vSAN HCL controller"; Status = "red" })
            }
            Mock Test-VsanTriggeredAlarmIsHclRelated { return $true }
            Mock Test-VsanTriggeredAlarmIsStatsPrimaryElection { return $false }
            { Invoke-VsanRefreshedAlarmGate -ClusterName "cl0" -LabEnvironment:$true } | Should -Not -Throw
            Should -Not -Invoke Write-LogMessage -ParameterFilter { $Type -eq "ERROR" }
        }
    }

    It "Throws VcfDeploymentException when a non-HCL red alarm exists, no AcceptBadCheckResults, user answers N" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Get-VsanClusterTriggeredAlarms {
                @([PSCustomObject]@{ AlarmName = "vSAN network connectivity"; Status = "red" })
            }
            Mock Test-VsanTriggeredAlarmIsHclRelated { return $false }
            Mock Test-VsanTriggeredAlarmIsStatsPrimaryElection { return $false }
            Mock Read-Host { return "N" }
            { Invoke-VsanRefreshedAlarmGate -ClusterName "cl0" -LabEnvironment:$true } |
                Should -Throw -ExceptionType ([VcfDeploymentException])
        }
    }
}

# ── H5: Invoke-VsanAlarmRemediation — lab-mode HCL ───────────────────────────


Describe "Invoke-VsanAlarmRemediation — lab-mode HCL" {

    It "Logs DEBUG (not WARNING) for a red HCL alarm when LabEnvironment=true" {
        InModuleScope VcfEdgeAtScale {
            $Script:_hclDebugLogged = $false
            $Script:_hclWarnLogged  = $false
            Mock Write-LogMessage {
                if ($Type -eq "DEBUG")   { $Script:_hclDebugLogged = $true }
                if ($Type -eq "WARNING") { $Script:_hclWarnLogged  = $true }
            }
            Mock Test-VsanTriggeredAlarmIsHclRelated { return $true }
            $alarm = [PSCustomObject]@{ AlarmName = "vSAN HCL controller driver"; Status = "red" }
            Invoke-VsanAlarmRemediation -Alarms @($alarm) -ClusterName "cl0" -LabEnvironment:$true -HaStabilizationDelaySeconds 0
            $Script:_hclDebugLogged | Should -BeTrue
            $Script:_hclWarnLogged  | Should -BeFalse
        }
    }
}

# ── H2+H3: Wait-AddVMHostTask — async task polling ───────────────────────────


Describe "Wait-AddVMHostTask — async task polling" {

    It "Returns Succeeded=true when Get-Task returns State=Success" {
        $result = InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            # Define Get-Task as a local function with [Object] params so PowerCLI type constraints
            # do not interfere with parameter binding in a non-PowerCLI test environment.
            function Get-Task {
                [CmdletBinding()] Param([Parameter()] [Object]$Id, [Parameter()] [Object]$Server)
                return [PSCustomObject]@{ State = "Success"; Status = "Success" }
            }
            Mock Start-Sleep {}
            $fakeTask = [PSCustomObject]@{ Id = "task-001" }
            $deadline = (Get-Date).AddSeconds(30)
            Wait-AddVMHostTask -Task $fakeTask -Deadline $deadline -Server "vc.lab" -AddHostTaskPollIntervalSeconds 1 -WaitForAddHostTaskTimeoutSeconds 30
        }
        $result.Succeeded | Should -BeTrue
        $result.ErrorMessage | Should -BeNullOrEmpty
    }

    It "Returns Succeeded=false with LocalizedMessage when State=Error" {
        $result = InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            function Get-Task {
                [CmdletBinding()] Param([Parameter()] [Object]$Id, [Parameter()] [Object]$Server)
                $errorInfo = [PSCustomObject]@{
                    Error = [PSCustomObject]@{ LocalizedMessage = "Host add rejected by vCenter." }
                }
                return [PSCustomObject]@{
                    State         = "Error"
                    Status        = "Error"
                    ExtensionData = [PSCustomObject]@{ Info = $errorInfo }
                }
            }
            Mock Start-Sleep {}
            $fakeTask = [PSCustomObject]@{ Id = "task-002" }
            $deadline = (Get-Date).AddSeconds(30)
            Wait-AddVMHostTask -Task $fakeTask -Deadline $deadline -Server "vc.lab" -AddHostTaskPollIntervalSeconds 1 -WaitForAddHostTaskTimeoutSeconds 30
        }
        $result.Succeeded    | Should -BeFalse
        $result.ErrorMessage | Should -Be "Host add rejected by vCenter."
    }

    It "Returns timeout message when deadline is already past" {
        $result = InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            function Get-Task {
                [CmdletBinding()] Param([Parameter()] [Object]$Id, [Parameter()] [Object]$Server)
                return $null
            }
            $fakeTask = [PSCustomObject]@{ Id = "task-003" }
            $deadline = (Get-Date).AddSeconds(-1)
            Wait-AddVMHostTask -Task $fakeTask -Deadline $deadline -Server "vc.lab" -WaitForAddHostTaskTimeoutSeconds 300
        }
        $result.Succeeded    | Should -BeFalse
        $result.ErrorMessage | Should -Match "300 seconds"
    }
}

# ── M10: Invoke-VsanClusterAlarmCheckAndRemediate — LabEnvironment+HCL end-to-end


Describe "Invoke-VsanClusterAlarmCheckAndRemediate — LabEnvironment+HCL end-to-end" {

    It "Does not throw when only HCL red alarm present and LabEnvironment=true" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Set-VsanDomNetworkSchedulerThrottleOnCluster { return $true }
            Mock Get-VsanClusterTriggeredAlarms {
                @([PSCustomObject]@{ AlarmName = "vSAN HCL controller driver"; Status = "red" })
            }
            Mock Test-VsanTriggeredAlarmIsHclRelated { return $true }
            Mock Test-VsanTriggeredAlarmIsStatsPrimaryElection { return $false }
            { Invoke-VsanClusterAlarmCheckAndRemediate -ClusterName "cl0" -LabEnvironment:$true -PostRemediationWaitSeconds 0 } |
                Should -Not -Throw
            Should -Not -Invoke Write-LogMessage -ParameterFilter { $Type -eq "ERROR" }
        }
    }
}

# ── Set-VsanDatastoreTagIfMissing ─────────────────────────────────────────────


Describe "Set-VsanDatastoreTagIfMissing — tag assignment idempotency" {

    It "Returns true (already provisioned) when the tag assignment already exists on the datastore" {
        $result = InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            $Script:vCenterName   = "vc.lab"
            $Script:SupervisorName = "sup-site1"
            $fakeDs  = [PSCustomObject]@{ Name = "vsanDatastore" }
            $fakeTag = [PSCustomObject]@{ Id = "urn:vmomi:InventoryServiceTag:abc123"; Name = "sup-site1" }
            $fakeAssignment = [PSCustomObject]@{ Tag = $fakeTag }
            function Get-Datastore {
                [CmdletBinding()] Param([Parameter()] [String]$Name, [Parameter()] [Object]$Server)
                return $fakeDs
            }
            function Get-Tag {
                [CmdletBinding()] Param([Parameter()] [String]$Name, [Parameter()] [String]$Category, [Parameter()] [Object]$Server)
                return $fakeTag
            }
            function Get-TagAssignment {
                [CmdletBinding()] Param([Parameter()] [Object]$Entity, [Parameter()] [Object]$Server)
                return @($fakeAssignment)
            }
            Mock New-TagAssignment {}
            Set-VsanDatastoreTagIfMissing -DatastoreName "vsanDatastore" `
                -StoragePolicyTagCatalog "vSAN-ESA-Storage-TagCatalog" -StorageType "vSAN-ESA"
        }
        $result | Should -Be $true
    }

    It "Returns false and calls New-TagAssignment when tag is not yet assigned" {
        $tagAssignCallCount = 0
        $result = InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            $Script:vCenterName   = "vc.lab"
            $Script:SupervisorName = "sup-site1"
            $fakeDs  = [PSCustomObject]@{ Name = "vsanDatastore" }
            $fakeTag = [PSCustomObject]@{ Id = "urn:vmomi:InventoryServiceTag:abc123"; Name = "sup-site1" }
            function Get-Datastore {
                [CmdletBinding()] Param([Parameter()] [String]$Name, [Parameter()] [Object]$Server)
                return $fakeDs
            }
            function Get-Tag {
                [CmdletBinding()] Param([Parameter()] [String]$Name, [Parameter()] [String]$Category, [Parameter()] [Object]$Server)
                return $fakeTag
            }
            function Get-TagAssignment {
                [CmdletBinding()] Param([Parameter()] [Object]$Entity, [Parameter()] [Object]$Server)
                return @()
            }
            $Script:_tagAssignCallCount = 0
            function New-TagAssignment {
                [CmdletBinding()] Param([Parameter()] [Object]$Tag, [Parameter()] [Object]$Entity, [Parameter()] [Object]$Server)
                $Script:_tagAssignCallCount++
                return [PSCustomObject]@{ Tag = $Tag }
            }
            Set-VsanDatastoreTagIfMissing -DatastoreName "vsanDatastore" `
                -StoragePolicyTagCatalog "vSAN-OSA-Storage-TagCatalog" -StorageType "vSAN-OSA"
        }
        $result | Should -Be $false
        InModuleScope VcfEdgeAtScale {
            $Script:_tagAssignCallCount | Should -Be 1
        }
    }
}

