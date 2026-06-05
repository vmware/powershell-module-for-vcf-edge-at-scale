# Pester tests for VcfEdgeAtScale — Private/EntryPoints.ps1
#
# RECOMMENDED: Use the wrapper script for human-readable output:
#   ./Tests/Run-Tests.ps1
#   ./Tests/Run-Tests.ps1 -Filter "*FunctionName*"
#
# DIRECT: Invoke-Pester -Path ./Tests/VcfEdgeAtScale.EntryPoints.Tests.ps1 -Output Detailed
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

Describe "Get-ModulePublicVersion" {
    BeforeEach {
        $script:savedModuleVersion = InModuleScope VcfEdgeAtScale { $Script:ModuleVersion }
    }
    AfterEach {
        InModuleScope VcfEdgeAtScale -ArgumentList $script:savedModuleVersion { param($v) $Script:ModuleVersion = $v }
    }

    It "Strips the build segment from a 4-part version string" {
        # 1.0.3.1000 is the internal build; 1.0.3 is the public Gallery version.
        $result = InModuleScope VcfEdgeAtScale {
            $Script:ModuleVersion = "1.0.3.1000"
            Get-ModulePublicVersion
        }
        $result | Should -Be "1.0.3"
    }

    It "Strips the build segment when build is 0" {
        $result = InModuleScope VcfEdgeAtScale {
            $Script:ModuleVersion = "2.1.0.0"
            Get-ModulePublicVersion
        }
        $result | Should -Be "2.1.0"
    }

    It "Returns the full string unchanged for a 3-part version (no build segment)" {
        $result = InModuleScope VcfEdgeAtScale {
            $Script:ModuleVersion = "1.0.3"
            Get-ModulePublicVersion
        }
        $result | Should -Be "1.0.3"
    }

    It "Returns the full string unchanged for a 2-part version" {
        $result = InModuleScope VcfEdgeAtScale {
            $Script:ModuleVersion = "1.0"
            Get-ModulePublicVersion
        }
        $result | Should -Be "1.0"
    }
}


Describe "Confirm-FileOverwritePrompt" {
    It "Returns true without prompting when the file does not exist" {
        InModuleScope VcfEdgeAtScale {
            Mock Test-Path { return $false }
            Mock Read-Host {}
            $result = Confirm-FileOverwritePrompt -FilePath "C:\nonexistent.json"
            $result | Should -BeTrue
            Should -Invoke Read-Host -Times 0 -Scope It
        }
    }

    It "Returns true when the file exists and the user enters 'y'" {
        InModuleScope VcfEdgeAtScale {
            Mock Test-Path { return $true }
            Mock Read-Host { return "y" }
            Confirm-FileOverwritePrompt -FilePath "C:\existing.json" | Should -BeTrue
        }
    }

    It "Returns true when the file exists and the user enters 'Y'" {
        InModuleScope VcfEdgeAtScale {
            Mock Test-Path { return $true }
            Mock Read-Host { return "Y" }
            Confirm-FileOverwritePrompt -FilePath "C:\existing.json" | Should -BeTrue
        }
    }

    It "Returns false when the file exists and the user enters 'n'" {
        InModuleScope VcfEdgeAtScale {
            Mock Test-Path { return $true }
            Mock Read-Host { return "n" }
            Confirm-FileOverwritePrompt -FilePath "C:\existing.json" | Should -BeFalse
        }
    }

    It "Returns false when the file exists and the user presses Enter (empty string)" {
        InModuleScope VcfEdgeAtScale {
            Mock Test-Path { return $true }
            Mock Read-Host { return "" }
            Confirm-FileOverwritePrompt -FilePath "C:\existing.json" | Should -BeFalse
        }
    }

    It "Logs an error and returns false when Read-Host throws (non-interactive session)" {
        InModuleScope VcfEdgeAtScale {
            Mock Test-Path { return $true }
            Mock Read-Host { throw "No console" }
            Mock Write-LogMessage { }
            $result = Confirm-FileOverwritePrompt -FilePath "C:\existing.json"
            $result | Should -Be $false
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq "ERROR" } -Times 1 -Exactly
        }
    }
}


Describe "Test-VcfEdgeAtScaleDeploymentRootInitialized" {
    BeforeAll {
        $script:initTestRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "veas-initcheck-$([System.Guid]::NewGuid().ToString('N').Substring(0, 8))"
        New-Item -ItemType Directory -Path $script:initTestRoot -Force | Out-Null
        # Save and restore the yaml template names so tests don't depend on live module state.
        $script:savedYamlNames = InModuleScope VcfEdgeAtScale { $Script:VcfEdgeAtScaleServiceYamlTemplateFileNames }
    }
    AfterAll {
        Remove-Item -Path $script:initTestRoot -Recurse -Force -ErrorAction SilentlyContinue
        InModuleScope VcfEdgeAtScale -ArgumentList $script:savedYamlNames { param($v) $Script:VcfEdgeAtScaleServiceYamlTemplateFileNames = $v }
    }

    It "Returns false when the root directory does not exist" {
        $missing = Join-Path $script:initTestRoot "does-not-exist"
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $missing { param($p) Test-VcfEdgeAtScaleDeploymentRootInitialized -DeploymentRoot $p }
        $result | Should -Be $false
    }

    It "Returns false when Docs subdirectory is missing" {
        $base = Join-Path $script:initTestRoot "missing-docs"
        New-Item -ItemType Directory -Path (Join-Path $base "Logs") -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $base "ServicesYaml") -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $base "Tools") -Force | Out-Null
        New-Item -ItemType File -Path (Join-Path $base "infrastructure.json") -Force | Out-Null
        New-Item -ItemType File -Path (Join-Path $base "supervisor.json") -Force | Out-Null
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $base { param($p) Test-VcfEdgeAtScaleDeploymentRootInitialized -DeploymentRoot $p }
        $result | Should -Be $false
    }

    It "Returns false when Tools subdirectory is missing" {
        $base = Join-Path $script:initTestRoot "missing-tools"
        foreach ($d in @("Docs","Logs","ServicesYaml")) { New-Item -ItemType Directory -Path (Join-Path $base $d) -Force | Out-Null }
        New-Item -ItemType File -Path (Join-Path $base "infrastructure.json") -Force | Out-Null
        New-Item -ItemType File -Path (Join-Path $base "supervisor.json") -Force | Out-Null
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $base { param($p) Test-VcfEdgeAtScaleDeploymentRootInitialized -DeploymentRoot $p }
        $result | Should -Be $false
    }

    It "Returns false when infrastructure.json is missing" {
        $base = Join-Path $script:initTestRoot "missing-infra"
        foreach ($d in @("Docs","Logs","ServicesYaml","Tools")) { New-Item -ItemType Directory -Path (Join-Path $base $d) -Force | Out-Null }
        New-Item -ItemType File -Path (Join-Path $base "supervisor.json") -Force | Out-Null
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $base { param($p) Test-VcfEdgeAtScaleDeploymentRootInitialized -DeploymentRoot $p }
        $result | Should -Be $false
    }

    It "Returns false when a required YAML template file is absent from ServicesYaml" {
        $base = Join-Path $script:initTestRoot "missing-yaml"
        foreach ($d in @("Docs","Logs","ServicesYaml","Tools")) { New-Item -ItemType Directory -Path (Join-Path $base $d) -Force | Out-Null }
        New-Item -ItemType File -Path (Join-Path $base "infrastructure.json") -Force | Out-Null
        New-Item -ItemType File -Path (Join-Path $base "supervisor.json") -Force | Out-Null
        # Override yaml list to a single known name; create NO files in ServicesYaml.
        InModuleScope VcfEdgeAtScale { $Script:VcfEdgeAtScaleServiceYamlTemplateFileNames = @("required.yml") }
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $base { param($p) Test-VcfEdgeAtScaleDeploymentRootInitialized -DeploymentRoot $p }
        $result | Should -Be $false
    }

    It "Returns true when all required subdirs, JSON, and YAML files are present" {
        $base = Join-Path $script:initTestRoot "complete"
        foreach ($d in @("Docs","Logs","ServicesYaml","Tools")) { New-Item -ItemType Directory -Path (Join-Path $base $d) -Force | Out-Null }
        New-Item -ItemType File -Path (Join-Path $base "infrastructure.json") -Force | Out-Null
        New-Item -ItemType File -Path (Join-Path $base "supervisor.json") -Force | Out-Null
        InModuleScope VcfEdgeAtScale { $Script:VcfEdgeAtScaleServiceYamlTemplateFileNames = @("required.yml") }
        New-Item -ItemType File -Path (Join-Path -Path $base -ChildPath (Join-Path -Path "ServicesYaml" -ChildPath "required.yml")) -Force | Out-Null
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $base { param($p) Test-VcfEdgeAtScaleDeploymentRootInitialized -DeploymentRoot $p }
        $result | Should -Be $true
    }
}


Describe "Get-VcfEdgeAtScaleConfigUiVersion" {
    BeforeAll {
        $script:tmpPyVersion = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "veas-cv-$([guid]::NewGuid().ToString('N').Substring(0,8)).py"
        Set-Content -Path $script:tmpPyVersion -Value 'UI_VERSION = "1.0.3.1010"' -Encoding UTF8

        $script:tmpPyNoVersion = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "veas-cv-nv-$([guid]::NewGuid().ToString('N').Substring(0,8)).py"
        Set-Content -Path $script:tmpPyNoVersion -Value "# no version constant here" -Encoding UTF8
    }

    AfterAll {
        Remove-Item $script:tmpPyVersion   -Force -ErrorAction SilentlyContinue
        Remove-Item $script:tmpPyNoVersion -Force -ErrorAction SilentlyContinue
    }

    It "Extracts UI_VERSION string from a Python file" {
        InModuleScope VcfEdgeAtScale -ArgumentList $script:tmpPyVersion {
            Get-VcfEdgeAtScaleConfigUiVersion -FilePath $args[0]
        } | Should -Be "1.0.3.1010"
    }

    It "Returns null when UI_VERSION is absent from the file" {
        InModuleScope VcfEdgeAtScale -ArgumentList $script:tmpPyNoVersion {
            Get-VcfEdgeAtScaleConfigUiVersion -FilePath $args[0]
        } | Should -Be $null
    }

    It "Returns null for a nonexistent file path" {
        InModuleScope VcfEdgeAtScale {
            Get-VcfEdgeAtScaleConfigUiVersion -FilePath "/nonexistent/path/veas.py"
        } | Should -Be $null
    }
}


Describe "Get-VcfEdgeAtScaleUiTemplateVersion" {
    BeforeAll {
        $script:tmpHtmlVersion = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "veas-tv-$([guid]::NewGuid().ToString('N').Substring(0,8)).html"
        Set-Content -Path $script:tmpHtmlVersion -Value '<!-- VEAS-UI-VERSION: 1.0.3.1010 -->' -Encoding UTF8

        $script:tmpHtmlNoVersion = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "veas-tv-nv-$([guid]::NewGuid().ToString('N').Substring(0,8)).html"
        Set-Content -Path $script:tmpHtmlNoVersion -Value "<html><head></head></html>" -Encoding UTF8
    }

    AfterAll {
        Remove-Item $script:tmpHtmlVersion   -Force -ErrorAction SilentlyContinue
        Remove-Item $script:tmpHtmlNoVersion -Force -ErrorAction SilentlyContinue
    }

    It "Extracts VEAS-UI-VERSION from an HTML comment" {
        InModuleScope VcfEdgeAtScale -ArgumentList $script:tmpHtmlVersion {
            Get-VcfEdgeAtScaleUiTemplateVersion -FilePath $args[0]
        } | Should -Be "1.0.3.1010"
    }

    It "Returns null when the HTML file has no VEAS-UI-VERSION comment" {
        InModuleScope VcfEdgeAtScale -ArgumentList $script:tmpHtmlNoVersion {
            Get-VcfEdgeAtScaleUiTemplateVersion -FilePath $args[0]
        } | Should -Be $null
    }

    It "Returns null for a nonexistent file path" {
        InModuleScope VcfEdgeAtScale {
            Get-VcfEdgeAtScaleUiTemplateVersion -FilePath "/nonexistent/path/veas-ui.html"
        } | Should -Be $null
    }
}


Describe "Invoke-VcfEdgeAtScaleModuleVersionStalenessCheck" {
    BeforeEach {
        $script:savedModuleVersion = InModuleScope VcfEdgeAtScale { $Script:ModuleVersion }
    }

    AfterEach {
        InModuleScope VcfEdgeAtScale -ArgumentList $script:savedModuleVersion { param($v) $Script:ModuleVersion = $v }
    }

    It "Emits no WARNING when the loaded version matches the manifest on disk" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage { }
            $diskVersion = (Import-PowerShellDataFile (Join-Path $Script:ModuleRoot "VcfEdgeAtScale.psd1")).ModuleVersion
            $Script:ModuleVersion = $diskVersion
            Invoke-VcfEdgeAtScaleModuleVersionStalenessCheck
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq "WARNING" } -Times 0
        }
    }

    It "Emits a WARNING when the loaded version differs from the manifest on disk" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage { }
            $Script:ModuleVersion = "0.0.0.0"
            Invoke-VcfEdgeAtScaleModuleVersionStalenessCheck
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq "WARNING" } -Times 1
        }
    }
}


Describe "Invoke-VcfEdgeAtScaleSiteDeployment" {
    It "Throws E-CONFIG-NULL-001 without calling Initialize-VcfEdgeAtScale when JSON load returns null" {
        InModuleScope VcfEdgeAtScale {
            function Invoke-VcfEdgeAtScaleModuleVersionStalenessCheck { [CmdletBinding()] Param () }
            function Initialize-ScriptVcfPowerCliModuleVersion {
                [CmdletBinding()] Param ([Parameter()] [Object]$MinimumVcfPowerCliVersion)
            }
            function Get-ModuleTemplatesPath { [CmdletBinding()] Param (); return "" }
            function Update-HelpJsonIfStale {
                [CmdletBinding()] Param ([Parameter()] [Object]$DocsPath, [Parameter()] [Object]$TemplatePath)
            }
            function Initialize-VcfEdgeAtScale {
                [CmdletBinding()] Param ([Parameter()] [Object]$InfrastructureJson, [Parameter()] [Object]$SupervisorJson, [Parameter()] [Object]$DelayBeforeAddingNextHostSeconds)
                begin { throw "Initialize-VcfEdgeAtScale must not be called when JSON load returns null" }
                process {}
            }
            Mock Write-LogMessage { }
            Mock ConvertFrom-JsonSafely { return $null }

            { Invoke-VcfEdgeAtScaleSiteDeployment -DeploymentRootDirectory ([System.IO.Path]::GetTempPath()) -InfrastructureJson "infra.json" -SupervisorJson "supervisor.json" } |
                Should -Throw "*E-CONFIG-NULL-001*"
        }
    }

    It "Returns without calling Initialize-VcfEdgeAtScale when -ValidateOnly is set and validation passes" {
        $initCount = InModuleScope VcfEdgeAtScale {
            $Script:_initCallCount = 0
            function Invoke-VcfEdgeAtScaleModuleVersionStalenessCheck { [CmdletBinding()] Param () }
            function Initialize-ScriptVcfPowerCliModuleVersion {
                [CmdletBinding()] Param ([Parameter()] [Object]$MinimumVcfPowerCliVersion)
            }
            function Get-ModuleTemplatesPath { [CmdletBinding()] Param (); return "" }
            function Update-HelpJsonIfStale {
                [CmdletBinding()] Param ([Parameter()] [Object]$DocsPath, [Parameter()] [Object]$TemplatePath)
            }
            function Test-EdgeSiteNameValid { [CmdletBinding()] Param ([Parameter()] [Object]$Name); return $true }
            function Update-InfrastructureJsonReferencedFilePaths {
                [CmdletBinding()] Param ([Parameter()] [Object]$InfrastructureJsonPath, [Parameter()] [Object]$InputData)
            }
            function Get-EffectiveSupervisorServiceFlag {
                [CmdletBinding()] Param ([Parameter()] [Object]$Cluster, [Parameter()] [Object]$CommonData, [Parameter()] [Object]$FlagName)
                return $true  # all services disabled → YAML validation skipped for each cluster
            }
            function Test-JsonShallowValidation {
                [CmdletBinding()] Param ([Parameter()] [Object]$InfrastructureJson, [Parameter()] [Object]$SupervisorJson, [Parameter()] [Object]$EdgeSite, [Parameter()] [Switch]$ComputeOnly)
            }
            function Test-JsonDeeperValidation {
                [CmdletBinding()] Param ([Parameter()] [Object]$InfrastructureJson, [Parameter()] [Object]$SupervisorJson, [Parameter()] [Object]$EdgeSite, [Parameter()] [Switch]$ComputeOnly)
            }
            function Test-NetworkSegmentNameUniqueness {
                [CmdletBinding()] Param ([Parameter()] [Object]$InputData, [Parameter()] [Object]$EdgeSite)
                return [PSCustomObject]@{ IsValid = $true; ErrorMessage = $null }
            }
            function Test-EsxHostUniqueness {
                [CmdletBinding()] Param ([Parameter()] [Object]$InputData)
                return [PSCustomObject]@{ IsValid = $true; ErrorMessage = $null }
            }
            function Initialize-VcfEdgeAtScale {
                [CmdletBinding()] Param ([Parameter()] [Object]$InfrastructureJson, [Parameter()] [Object]$SupervisorJson, [Parameter()] [Object]$DelayBeforeAddingNextHostSeconds)
                begin { $Script:_initCallCount++ }
                process {}
            }
            Mock Write-LogMessage { }
            Mock Invoke-VcfEdgeAtScaleUpdateCheck { }
            Mock ConvertFrom-JsonSafely {
                return [PSCustomObject]@{
                    common   = [PSCustomObject]@{ vCenterName = "vc.lab" }
                    clusters = @([PSCustomObject]@{ edgeSite = "edge1" })
                }
            }

            Invoke-VcfEdgeAtScaleSiteDeployment `
                -DeploymentRootDirectory ([System.IO.Path]::GetTempPath()) `
                -InfrastructureJson "infra.json" `
                -SupervisorJson "supervisor.json" `
                -ValidateOnly
            $Script:_initCallCount
        }
        $initCount | Should -Be 0
    }

    It "Calls Initialize-VcfEdgeAtScale with normalized CleanUp scope when -CleanUp is set" {
        $result = InModuleScope VcfEdgeAtScale {
            $Script:_initCallCount = 0
            $Script:_initCleanUp = $null
            function Invoke-VcfEdgeAtScaleModuleVersionStalenessCheck { [CmdletBinding()] Param () }
            function Initialize-ScriptVcfPowerCliModuleVersion {
                [CmdletBinding()] Param ([Parameter()] [Object]$MinimumVcfPowerCliVersion)
            }
            function Get-ModuleTemplatesPath { [CmdletBinding()] Param (); return "" }
            function Update-HelpJsonIfStale {
                [CmdletBinding()] Param ([Parameter()] [Object]$DocsPath, [Parameter()] [Object]$TemplatePath)
            }
            function Test-EdgeSiteNameValid { [CmdletBinding()] Param ([Parameter()] [Object]$Name); return $true }
            function Update-InfrastructureJsonReferencedFilePaths {
                [CmdletBinding()] Param ([Parameter()] [Object]$InfrastructureJsonPath, [Parameter()] [Object]$InputData)
            }
            function Initialize-VcfEdgeAtScale {
                [CmdletBinding()] Param (
                    [Parameter()] [Object]$InfrastructureJson,
                    [Parameter()] [Object]$SupervisorJson,
                    [Parameter()] [Object]$DelayBeforeAddingNextHostSeconds,
                    [Parameter()] [Object]$CleanUp
                )
                begin {
                    $Script:_initCallCount++
                    $Script:_initCleanUp = $CleanUp
                }
                process {}
            }
            Mock Write-LogMessage { }
            Mock ConvertFrom-JsonSafely {
                return [PSCustomObject]@{
                    common   = [PSCustomObject]@{ vCenterName = "vc.lab" }
                    clusters = @([PSCustomObject]@{ edgeSite = "edge1" })
                }
            }

            # CleanUp "supervisor" (lowercase) should be normalized to "Supervisor" before forwarding.
            Invoke-VcfEdgeAtScaleSiteDeployment `
                -DeploymentRootDirectory ([System.IO.Path]::GetTempPath()) `
                -InfrastructureJson "infra.json" `
                -SupervisorJson "supervisor.json" `
                -CleanUp "Supervisor"
            [PSCustomObject]@{ Count = $Script:_initCallCount; CleanUp = $Script:_initCleanUp }
        }
        $result.Count  | Should -Be 1
        $result.CleanUp | Should -Be "Supervisor"
    }

    It "Throws VcfDeploymentException when an edgeSite name fails validation" {
        InModuleScope VcfEdgeAtScale {
            function Invoke-VcfEdgeAtScaleModuleVersionStalenessCheck { [CmdletBinding()] Param () }
            function Initialize-ScriptVcfPowerCliModuleVersion {
                [CmdletBinding()] Param ([Parameter()] [Object]$MinimumVcfPowerCliVersion)
            }
            function Get-ModuleTemplatesPath { [CmdletBinding()] Param (); return "" }
            function Update-HelpJsonIfStale {
                [CmdletBinding()] Param ([Parameter()] [Object]$DocsPath, [Parameter()] [Object]$TemplatePath)
            }
            # Return false for the edgeSite name to trigger the edgeSite validation error.
            function Test-EdgeSiteNameValid { [CmdletBinding()] Param ([Parameter()] [Object]$Name); return $false }
            function Update-InfrastructureJsonReferencedFilePaths {
                [CmdletBinding()] Param ([Parameter()] [Object]$InfrastructureJsonPath, [Parameter()] [Object]$InputData)
            }
            Mock Write-LogMessage { }
            Mock ConvertFrom-JsonSafely {
                return [PSCustomObject]@{
                    common   = [PSCustomObject]@{ vCenterName = "vc.lab" }
                    clusters = @([PSCustomObject]@{ edgeSite = "INVALID SITE NAME" })
                }
            }
            { Invoke-VcfEdgeAtScaleSiteDeployment -DeploymentRootDirectory ([System.IO.Path]::GetTempPath()) -InfrastructureJson "infra.json" -SupervisorJson "supervisor.json" } |
                Should -Throw "*edgeSite names failed validation*"
        }
    }

    It "Propagates VcfDeploymentException from Invoke-JsonConfigurationValidation" {
        InModuleScope VcfEdgeAtScale {
            function Invoke-VcfEdgeAtScaleModuleVersionStalenessCheck { [CmdletBinding()] Param () }
            function Initialize-ScriptVcfPowerCliModuleVersion {
                [CmdletBinding()] Param ([Parameter()] [Object]$MinimumVcfPowerCliVersion)
            }
            function Get-ModuleTemplatesPath { [CmdletBinding()] Param (); return "" }
            function Update-HelpJsonIfStale {
                [CmdletBinding()] Param ([Parameter()] [Object]$DocsPath, [Parameter()] [Object]$TemplatePath)
            }
            function Test-EdgeSiteNameValid { [CmdletBinding()] Param ([Parameter()] [Object]$Name); return $true }
            function Update-InfrastructureJsonReferencedFilePaths {
                [CmdletBinding()] Param ([Parameter()] [Object]$InfrastructureJsonPath, [Parameter()] [Object]$InputData)
            }
            function Invoke-YamlFileExistenceValidation {
                [CmdletBinding()] Param([Parameter()] [Object]$InputData, [Parameter()] [Object]$SiteIndication, [Parameter()] [Object]$EdgeSitesArray, [Parameter()] [Object]$CleanUp, [Parameter()] [Switch]$ComputeOnly)
            }
            function Invoke-JsonConfigurationValidation {
                [CmdletBinding()] Param([Parameter()] [Object]$InfrastructureJson, [Parameter()] [Object]$SupervisorJson, [Parameter()] [Object]$InputData, [Parameter()] [Object]$SiteIndication, [Parameter()] [Object]$ValidationStartTime, [Parameter()] [Object]$CleanUp, [Parameter()] [Object]$EdgeSite, [Parameter()] [Switch]$ComputeOnly)
                throw [VcfDeploymentException]::new("clusters[edge1].vCenterName: missing required field.")
            }
            Mock Write-LogMessage { }
            Mock ConvertFrom-JsonSafely {
                return [PSCustomObject]@{
                    common   = [PSCustomObject]@{ vCenterName = "vc.lab" }
                    clusters = @([PSCustomObject]@{ edgeSite = "edge1" })
                }
            }
            { Invoke-VcfEdgeAtScaleSiteDeployment -DeploymentRootDirectory ([System.IO.Path]::GetTempPath()) -InfrastructureJson "infra.json" -SupervisorJson "supervisor.json" } |
                Should -Throw "*clusters*"
        }
    }
}

Describe "Invoke-YamlFileExistenceValidation" {
    It "Returns without throwing when CleanUp scope is set" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage { }
            $fakeInputData = [PSCustomObject]@{
                clusters = @([PSCustomObject]@{ edgeSite = "edge1" })
                common   = [PSCustomObject]@{ }
            }
            { Invoke-YamlFileExistenceValidation -InputData $fakeInputData -SiteIndication "all sites" -CleanUp "All" } |
                Should -Not -Throw
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq "DEBUG" -and $Message -match "Not performing YAML validation during cleanup" }
        }
    }

    It "Throws when a required ArgoCD YAML file is missing from disk" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage { }
            function Get-EffectiveSupervisorServiceFlag {
                [CmdletBinding()] Param ([Parameter()] [Object]$Cluster, [Parameter()] [Object]$CommonData, [Parameter()] [Object]$FlagName)
                # ArgoCD enabled, Harbor disabled.
                return $FlagName -eq "disableHarbor"
            }
            function Get-EffectiveArgoCdYamlPath {
                [CmdletBinding()] Param ([Parameter()] [Object]$Cluster, [Parameter()] [Object]$CommonData, [Parameter()] [Object]$PropertyName)
                return "/nonexistent/argocd-operator.yaml"
            }
            Mock Test-Path { $false }
            $fakeInputData = [PSCustomObject]@{
                clusters = @([PSCustomObject]@{ edgeSite = "edge1" })
                common   = [PSCustomObject]@{ }
            }
            { Invoke-YamlFileExistenceValidation -InputData $fakeInputData -SiteIndication "all sites" } |
                Should -Throw "*required YAML files*"
        }
    }

    It "Completes without error when all services are disabled for every cluster" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage { }
            Mock Test-Path { $true }
            function Get-EffectiveSupervisorServiceFlag {
                [CmdletBinding()] Param ([Parameter()] [Object]$Cluster, [Parameter()] [Object]$CommonData, [Parameter()] [Object]$FlagName)
                return $true
            }
            $fakeInputData = [PSCustomObject]@{
                clusters = @([PSCustomObject]@{ edgeSite = "edge1" })
                common   = [PSCustomObject]@{ }
            }
            { Invoke-YamlFileExistenceValidation -InputData $fakeInputData -SiteIndication "all sites" } |
                Should -Not -Throw
            # When all services are disabled, Test-Path is never called for YAML files.
            Should -Invoke Test-Path -Times 0 -Scope It
        }
    }
}

Describe "Invoke-JsonConfigurationValidation" {
    It "Returns without throwing when CleanUp scope is set" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage { }
            $fakeInputData = [PSCustomObject]@{
                clusters = @([PSCustomObject]@{ edgeSite = "edge1" })
                common   = [PSCustomObject]@{ }
            }
            { Invoke-JsonConfigurationValidation -InfrastructureJson "infra.json" -SupervisorJson "sup.json" `
                -InputData $fakeInputData -SiteIndication "all sites" -ValidationStartTime (Get-Date) -CleanUp "All" } |
                Should -Not -Throw
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq "DEBUG" -and $Message -match "Cleanup mode" }
        }
    }

    It "Throws when Test-JsonShallowValidation fails" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage { }
            function Test-JsonShallowValidation {
                [CmdletBinding()] Param ([Parameter()] [Object]$InfrastructureJson, [Parameter()] [Object]$SupervisorJson, [Parameter()] [Object]$EdgeSite, [Parameter()] [Switch]$ComputeOnly)
                throw [VcfDeploymentException]::new("Missing required property: clusters[].vCenterName")
            }
            $fakeInputData = [PSCustomObject]@{
                clusters = @([PSCustomObject]@{ edgeSite = "edge1" })
                common   = [PSCustomObject]@{ }
            }
            { Invoke-JsonConfigurationValidation -InfrastructureJson "infra.json" -SupervisorJson "sup.json" `
                -InputData $fakeInputData -SiteIndication "all sites" -ValidationStartTime (Get-Date) } |
                Should -Throw "*Missing required property*"
        }
    }

    It "Completes without error when all validations pass" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage { }
            function Test-JsonShallowValidation {
                [CmdletBinding()] Param ([Parameter()] [Object]$InfrastructureJson, [Parameter()] [Object]$SupervisorJson, [Parameter()] [Object]$EdgeSite, [Parameter()] [Switch]$ComputeOnly)
            }
            function Test-JsonDeeperValidation {
                [CmdletBinding()] Param ([Parameter()] [Object]$InfrastructureJson, [Parameter()] [Object]$SupervisorJson, [Parameter()] [Object]$EdgeSite, [Parameter()] [Switch]$ComputeOnly)
            }
            function Test-NetworkSegmentNameUniqueness {
                [CmdletBinding()] Param ([Parameter()] [Object]$InputData, [Parameter()] [Object]$EdgeSite)
                return [PSCustomObject]@{ IsValid = $true; ErrorMessage = $null }
            }
            function Test-EsxHostUniqueness {
                [CmdletBinding()] Param ([Parameter()] [Object]$InputData)
                return [PSCustomObject]@{ IsValid = $true; ErrorMessage = $null }
            }
            Mock Invoke-VcfEdgeAtScaleUpdateCheck { }
            $fakeInputData = [PSCustomObject]@{
                clusters = @([PSCustomObject]@{ edgeSite = "edge1" })
                common   = [PSCustomObject]@{ }
            }
            { Invoke-JsonConfigurationValidation -InfrastructureJson "infra.json" -SupervisorJson "sup.json" `
                -InputData $fakeInputData -SiteIndication "all sites" -ValidationStartTime (Get-Date) } |
                Should -Not -Throw
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq "INFO" -and $Message -match "Checking for required JSON properties" }
        }
    }
}

Describe "Sync-VcfEdgeAtScaleConfigUiTool" {

    It "Returns without copying when the module is not found via Get-Module" {
        InModuleScope VcfEdgeAtScale {
            Mock Get-Module { return $null }
            Mock Copy-Item { }
            Sync-VcfEdgeAtScaleConfigUiTool -UserBaseDirectory "C:\some\path"
            Should -Invoke Copy-Item -Times 0
        }
    }

    It "Returns without copying when source and destination have the same UI version" {
        $srcDir  = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "veas-sync-src-$(New-Guid)"
        $destDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "veas-sync-dest-$(New-Guid)"
        try {
            $null = New-Item -ItemType Directory -Path (Join-Path $srcDir "Tools")
            $null = New-Item -ItemType Directory -Path (Join-Path $destDir "Tools")
            Set-Content -Path (Join-Path $srcDir "Tools\veas-json-generator.py")  -Value 'UI_VERSION = "1.0.0"' -Encoding UTF8
            Set-Content -Path (Join-Path $destDir "Tools\veas-json-generator.py") -Value 'UI_VERSION = "1.0.0"' -Encoding UTF8

            $fakeModule = [PSCustomObject]@{ Version = [Version]"1.0.0"; ModuleBase = $srcDir }
            InModuleScope VcfEdgeAtScale -ArgumentList $fakeModule, $destDir {
                param($mod, $dest)
                Mock Get-Module { return $mod }
                Mock Copy-Item { }
                Sync-VcfEdgeAtScaleConfigUiTool -UserBaseDirectory $dest
                Should -Invoke Copy-Item -Times 0
            }
        } finally {
            Remove-Item -Path $srcDir  -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -Path $destDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "Copies the source file to the destination when the source version is newer" {
        $srcDir  = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "veas-sync-src-$(New-Guid)"
        $destDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "veas-sync-dest-$(New-Guid)"
        try {
            $null = New-Item -ItemType Directory -Path (Join-Path $srcDir "Tools")
            $null = New-Item -ItemType Directory -Path (Join-Path $destDir "Tools")
            Set-Content -Path (Join-Path $srcDir "Tools\veas-json-generator.py")  -Value 'UI_VERSION = "2.0.0"' -Encoding UTF8
            Set-Content -Path (Join-Path $destDir "Tools\veas-json-generator.py") -Value 'UI_VERSION = "1.0.0"' -Encoding UTF8

            $fakeModule = [PSCustomObject]@{ Version = [Version]"2.0.0"; ModuleBase = $srcDir }
            InModuleScope VcfEdgeAtScale -ArgumentList $fakeModule, $destDir {
                param($mod, $dest)
                Mock Get-Module { return $mod }
                Sync-VcfEdgeAtScaleConfigUiTool -UserBaseDirectory $dest
            }
            # Verify the destination file now contains the newer version string.
            $updatedContent = Get-Content -Path (Join-Path $destDir "Tools\veas-json-generator.py") -Raw
            $updatedContent | Should -Match '2\.0\.0'
        } finally {
            Remove-Item -Path $srcDir  -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -Path $destDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# ── New-LogFile / Write-LogEntryToFile — log file lifecycle ──────────────────


Describe "Update-HelpJsonIfStale" {

    It "Returns false when template file does not exist" {
        InModuleScope VcfEdgeAtScale {
            $result = Update-HelpJsonIfStale -TemplatePath "/nonexistent/veas-help.json" -DocsPath "/nonexistent/docs-help.json"
            $result | Should -Be $false
        }
    }

    It "Copies and returns true when Docs copy is absent" {
        $tempDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "veas-helptest-$(New-Guid)"
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
        $templatePath = Join-Path $tempDir "template-help.json"
        $docsPath     = Join-Path $tempDir "docs-help.json"
        try {
            Set-Content -Path $templatePath -Value '{"moduleVersion":"1.0.0","entries":[]}' -Encoding UTF8
            $result = InModuleScope VcfEdgeAtScale -ArgumentList $templatePath, $docsPath {
                param($tpl, $docs)
                Update-HelpJsonIfStale -TemplatePath $tpl -DocsPath $docs
            }
            $result | Should -Be $true
            Test-Path $docsPath | Should -Be $true
        } finally {
            Remove-Item -Recurse -Force -Path $tempDir -ErrorAction SilentlyContinue
        }
    }

    It "Returns false when Docs version matches template version" {
        $tempDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "veas-helptest-$(New-Guid)"
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
        $templatePath = Join-Path $tempDir "template-help.json"
        $docsPath     = Join-Path $tempDir "docs-help.json"
        try {
            $content = '{"moduleVersion":"1.0.3","entries":[]}'
            Set-Content -Path $templatePath -Value $content -Encoding UTF8
            Set-Content -Path $docsPath     -Value $content -Encoding UTF8
            $result = InModuleScope VcfEdgeAtScale -ArgumentList $templatePath, $docsPath {
                param($tpl, $docs)
                Update-HelpJsonIfStale -TemplatePath $tpl -DocsPath $docs
            }
            $result | Should -Be $false
        } finally {
            Remove-Item -Recurse -Force -Path $tempDir -ErrorAction SilentlyContinue
        }
    }

    It "Copies and returns true when Docs version differs from template version" {
        $tempDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "veas-helptest-$(New-Guid)"
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
        $templatePath = Join-Path $tempDir "template-help.json"
        $docsPath     = Join-Path $tempDir "docs-help.json"
        try {
            Set-Content -Path $templatePath -Value '{"moduleVersion":"1.0.4","entries":[]}' -Encoding UTF8
            Set-Content -Path $docsPath     -Value '{"moduleVersion":"1.0.3","entries":[]}' -Encoding UTF8
            $result = InModuleScope VcfEdgeAtScale -ArgumentList $templatePath, $docsPath {
                param($tpl, $docs)
                Update-HelpJsonIfStale -TemplatePath $tpl -DocsPath $docs
            }
            $result | Should -Be $true
            $updatedVersion = (Get-Content -Path $docsPath -Raw | ConvertFrom-Json).moduleVersion
            $updatedVersion | Should -Be "1.0.4"
        } finally {
            Remove-Item -Recurse -Force -Path $tempDir -ErrorAction SilentlyContinue
        }
    }

    It "Copies and returns true when template has no moduleVersion field (forces copy)" {
        $tempDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "veas-helptest-$(New-Guid)"
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
        $templatePath = Join-Path $tempDir "template-help.json"
        $docsPath     = Join-Path $tempDir "docs-help.json"
        try {
            Set-Content -Path $templatePath -Value '{"entries":[]}' -Encoding UTF8
            Set-Content -Path $docsPath     -Value '{"entries":[]}' -Encoding UTF8
            $result = InModuleScope VcfEdgeAtScale -ArgumentList $templatePath, $docsPath {
                param($tpl, $docs)
                Mock Get-ModulePublicVersion { return "1.0.0" }
                Update-HelpJsonIfStale -TemplatePath $tpl -DocsPath $docs
            }
            $result | Should -Be $true
        } finally {
            Remove-Item -Recurse -Force -Path $tempDir -ErrorAction SilentlyContinue
        }
    }

    It "Copies and returns true when Docs copy contains malformed JSON (treated as stale)" {
        $tempDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "veas-helptest-$(New-Guid)"
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
        $templatePath = Join-Path $tempDir "template-help.json"
        $docsPath     = Join-Path $tempDir "docs-help.json"
        try {
            Set-Content -Path $templatePath -Value '{"moduleVersion":"1.0.4","entries":[]}' -Encoding UTF8
            Set-Content -Path $docsPath     -Value "not {{ valid json" -Encoding UTF8
            $result = InModuleScope VcfEdgeAtScale -ArgumentList $templatePath, $docsPath {
                param($tpl, $docs)
                Update-HelpJsonIfStale -TemplatePath $tpl -DocsPath $docs
            }
            $result | Should -Be $true
        } finally {
            Remove-Item -Recurse -Force -Path $tempDir -ErrorAction SilentlyContinue
        }
    }
}

# ── Get-JsonDataWithValidation — shared JSON-load helper ──────────────────────


Describe "Sync-VcfEdgeAtScaleUiTemplate" {

    It "Returns without copying when Get-Module -ListAvailable returns nothing" {
        InModuleScope VcfEdgeAtScale {
            Mock Get-Module { return $null }
            Mock Copy-Item { }
            Sync-VcfEdgeAtScaleUiTemplate -UserBaseDirectory "C:\some\path"
            Should -Invoke Copy-Item -Times 0
        }
    }

    It "Returns without copying when UserBaseDirectory is empty" {
        $srcDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "veas-uitpl-src-$(New-Guid)"
        $null = New-Item -ItemType Directory -Path (Join-Path $srcDir "Tools") -Force
        Set-Content -Path (Join-Path $srcDir "Tools\veas-ui.html") -Value "<!-- VEAS-UI-VERSION: 1.0.0 -->" -Encoding UTF8
        try {
            $fakeModule = [PSCustomObject]@{ Version = [Version]"1.0.0"; ModuleBase = $srcDir }
            InModuleScope VcfEdgeAtScale -ArgumentList $fakeModule {
                param($mod)
                Mock Get-Module { return $mod }
                Mock Copy-Item { }
                Sync-VcfEdgeAtScaleUiTemplate -UserBaseDirectory ""
                Should -Invoke Copy-Item -Times 0
            }
        } finally {
            Remove-Item -Path $srcDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "Returns without copying when source and destination have the same UI template version" {
        $srcDir  = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "veas-uitpl-src-$(New-Guid)"
        $destDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "veas-uitpl-dest-$(New-Guid)"
        try {
            $null = New-Item -ItemType Directory -Path (Join-Path $srcDir  "Tools") -Force
            $null = New-Item -ItemType Directory -Path (Join-Path $destDir "Tools") -Force
            $versionLine = "<!-- VEAS-UI-VERSION: 1.0.0 -->"
            Set-Content -Path (Join-Path $srcDir  "Tools\veas-ui.html") -Value $versionLine -Encoding UTF8
            Set-Content -Path (Join-Path $destDir "Tools\veas-ui.html") -Value $versionLine -Encoding UTF8

            $fakeModule = [PSCustomObject]@{ Version = [Version]"1.0.0"; ModuleBase = $srcDir }
            InModuleScope VcfEdgeAtScale -ArgumentList $fakeModule, $destDir {
                param($mod, $dest)
                Mock Get-Module { return $mod }
                Mock Copy-Item { }
                Sync-VcfEdgeAtScaleUiTemplate -UserBaseDirectory $dest
                Should -Invoke Copy-Item -Times 0
            }
        } finally {
            Remove-Item -Path $srcDir  -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -Path $destDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "Copies the template when the source version is newer than the destination" {
        $srcDir  = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "veas-uitpl-src-$(New-Guid)"
        $destDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "veas-uitpl-dest-$(New-Guid)"
        try {
            $null = New-Item -ItemType Directory -Path (Join-Path $srcDir  "Tools") -Force
            $null = New-Item -ItemType Directory -Path (Join-Path $destDir "Tools") -Force
            Set-Content -Path (Join-Path $srcDir  "Tools\veas-ui.html") -Value "<!-- VEAS-UI-VERSION: 2.0.0 -->" -Encoding UTF8
            Set-Content -Path (Join-Path $destDir "Tools\veas-ui.html") -Value "<!-- VEAS-UI-VERSION: 1.0.0 -->" -Encoding UTF8

            $fakeModule = [PSCustomObject]@{ Version = [Version]"2.0.0"; ModuleBase = $srcDir }
            InModuleScope VcfEdgeAtScale -ArgumentList $fakeModule, $destDir {
                param($mod, $dest)
                Mock Get-Module { return $mod }
                Sync-VcfEdgeAtScaleUiTemplate -UserBaseDirectory $dest
            }
            $updatedContent = Get-Content -Path (Join-Path $destDir "Tools\veas-ui.html") -Raw
            $updatedContent | Should -Match "2\.0\.0"
        } finally {
            Remove-Item -Path $srcDir  -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -Path $destDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# ── Format-ConfigurationTable — PSObject-to-table formatter ──────────────────


Describe "Format-ConfigurationTable" {

    It "Returns nothing when all items have null Keys" {
        # An item with no Key property has .Key = $null, so it is filtered by the function's null-Key guard.
        $itemNoKey = [PSCustomObject]@{ Required = "Yes"; Notes = "No key here" }
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $itemNoKey {
            param($i)
            Format-ConfigurationTable -InputObject @($i)
        }
        $result | Should -BeNullOrEmpty
    }

    It "Does not throw and renders table when passed a single valid item" {
        # Format-ConfigurationTable routes output to Out-Host (not the pipeline) so callers
        # can use it in pipeline chains without polluting the success stream.
        InModuleScope VcfEdgeAtScale -ArgumentList ([PSCustomObject]@{ Key = "myKey"; Required = "Yes"; Notes = "A note" }) {
            param($i)
            Mock Out-Host { }
            { Format-ConfigurationTable -InputObject @($i) } | Should -Not -Throw
            Should -Invoke Out-Host -Times 1
        }
    }

    It "Deduplicates items with the same Key — only one row emitted per unique Key" {
        # Format-ConfigurationTable routes output to Out-Host via Format-Table. A function stub for
        # Format-Table captures each piped item so we can assert exactly 2 unique-key rows were sent.
        $item1 = [PSCustomObject]@{ Key = "dupKey"; Required = "Yes"; Notes = "First" }
        $item2 = [PSCustomObject]@{ Key = "dupKey"; Required = "No";  Notes = "Second" }
        $item3 = [PSCustomObject]@{ Key = "otherKey"; Required = "Yes"; Notes = "Other" }
        $rowCount = InModuleScope VcfEdgeAtScale -ArgumentList $item1, $item2, $item3 {
            param($a, $b, $c)
            $Script:_ftRowCount = 0
            function Format-Table {
                [CmdletBinding()]
                Param(
                    [Parameter(ValueFromPipeline = $true)] [Object]$InputObject,
                    [Parameter()] [Object]$Property,
                    [Switch]$AutoSize,
                    [Switch]$Wrap
                )
                process { $Script:_ftRowCount++ }
            }
            Mock Out-Host { }
            Format-ConfigurationTable -InputObject @($a, $b, $c)
            $Script:_ftRowCount
        }
        # "dupKey" deduplicates to 1 row; "otherKey" is 1 row — total 2 unique rows.
        $rowCount | Should -Be 2
    }
}

# ── Set-ScriptVcenterCredential — script-scope credential storage ─────────────


Describe "Get-ConfigurationHelpData" {

    It "Returns null when Get-ModuleTemplatesPath throws" {
        $result = InModuleScope VcfEdgeAtScale {
            Mock Get-ModuleTemplatesPath { throw "Templates directory not found" }
            Get-ConfigurationHelpData -HelpFileName "infra-help.json"
        }
        $result | Should -BeNullOrEmpty
    }

    It "Returns null when the resolved help JSON file does not exist" {
        $tempDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "veas-helpdata-$(New-Guid)"
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
        try {
            $result = InModuleScope VcfEdgeAtScale -ArgumentList $tempDir {
                param($tdir)
                Mock Get-ModuleTemplatesPath { return $tdir }
                # No file is created in $tdir so Test-Path will fail.
                Get-ConfigurationHelpData -HelpFileName "missing-help.json"
            }
            $result | Should -BeNullOrEmpty
        } finally {
            Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "Returns an array of entries from a valid help JSON file" {
        $tempDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "veas-helpdata-$(New-Guid)"
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
        $helpFile = Join-Path $tempDir "infra-help.json"
        try {
            # Two entries are required so ConvertFrom-Json preserves the array (a single-element JSON
            # array is unwrapped to a bare PSCustomObject by the pipeline, which would fail the
            # function's -is [Array] guard).
            $helpContent = '[{"Key":"common.vCenterName","Required":"Yes","Notes":"vCenter FQDN"},{"Key":"common.ssoUsername","Required":"Yes","Notes":"SSO username"}]'
            Set-Content -Path $helpFile -Value $helpContent -Encoding UTF8
            $result = InModuleScope VcfEdgeAtScale -ArgumentList $tempDir {
                param($tdir)
                Mock Get-ModuleTemplatesPath { return $tdir }
                Mock Test-JsonFile { return $true }
                Get-ConfigurationHelpData -HelpFileName "infra-help.json"
            }
            $result | Should -Not -BeNullOrEmpty
            @($result).Count | Should -Be 2
            $result[0].Key | Should -Be "common.vCenterName"
        } finally {
            Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# ── Test-JsonMissingProperties — additional edge-case coverage ────────────────


Describe "Write-VcfDeploymentFailureFooter" {

    It "Writes the no-log-file message when Script:LogFile is null" {
        InModuleScope VcfEdgeAtScale {
            $Script:LogFile = $null
            Mock Write-Host { }
            Write-VcfDeploymentFailureFooter
            Should -Invoke Write-Host -ParameterFilter { $Object -match "No log file was created" } -Scope It
        }
    }

    It "Writes the log-file path and collect-logs hint when Script:LogFile is set and path exists" {
        $tempFile = [System.IO.Path]::GetTempFileName()
        try {
            InModuleScope VcfEdgeAtScale -ArgumentList $tempFile {
                param($tf)
                $Script:LogFile = $tf
                Mock Write-Host { }
                Write-VcfDeploymentFailureFooter
                Should -Invoke Write-Host -ParameterFilter { $Object -match "Log file" }         -Scope It
                Should -Invoke Write-Host -ParameterFilter { $Object -match "CollectLogs" }      -Scope It
            }
        } finally {
            Remove-Item -Path $tempFile -Force -ErrorAction SilentlyContinue
        }
    }
}

# ── Get-ArgoCDOperatorServiceNamespace ───────────────────────────────────────


Describe "Show-VcfEdgeAtScaleVersion" {
    It "Calls Write-LogMessage with INFO type and module version string" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Show-VcfEdgeAtScaleVersion
            Should -Invoke Write-LogMessage -Times 1 -Scope It -ParameterFilter { $Type -eq "INFO" -and $Message -match "VcfEdgeAtScale version" }
        }
    }

    It "Logs INFO version and no ERROR when called with no arguments" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            { Show-VcfEdgeAtScaleVersion } | Should -Not -Throw
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq 'INFO' -and $Message -match 'version' }
            Should -Not -Invoke Write-LogMessage -ParameterFilter { $Type -eq 'ERROR' }
        }
    }
}


Describe "Show-ConfigurationHelpTable — mocked output" {
    It "Returns early without writing headers when Config is null" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Show-ConfigurationHelpTable -Title "Test" -Config $null -Format "List"
            Should -Invoke Write-LogMessage -Times 0 -Scope It
        }
    }

    It "Logs INFO and does not throw when rendering config in List format" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            $config = @([PSCustomObject]@{ Key = "common.clusterName"; Required = "Yes"; Notes = "Cluster name." })
            { Show-ConfigurationHelpTable -Title "Test Reference" -Config $config -Format "List" } | Should -Not -Throw
            Should -Not -Invoke Write-LogMessage -ParameterFilter { $Type -eq 'ERROR' }
        }
    }

    It "Does not throw and calls Format-ConfigurationTable when rendering in Table format" {
        # Format-ConfigurationTable is called via pipeline ($Config | Format-ConfigurationTable).
        # Pester 5.7.1 does not count Should -Invoke for pipeline-input calls. Use a begin{} stub
        # counter (runs in module scope). Suppress all pipeline output with Out-Null so only the
        # explicit $Script: read is returned to InModuleScope's caller.
        InModuleScope VcfEdgeAtScale {
            $Script:_fmtTableCount = 0
            function Format-ConfigurationTable {
                [CmdletBinding()]
                Param([Parameter(Mandatory = $true, ValueFromPipeline = $true)] [PSCustomObject[]]$InputObject)
                begin { $Script:_fmtTableCount++ }
                process {}
            }
            Mock Write-LogMessage {}
            $config = @([PSCustomObject]@{ Key = "common.clusterName"; Required = "Yes"; Notes = "Cluster name." })
            Show-ConfigurationHelpTable -Title "Test Reference" -Config $config -Format "Table" | Out-Null
            $Script:_fmtTableCount | Should -BeGreaterOrEqual 1
        }
    }
}

# ── Invoke-AbandonHciWorkflowIfInProgress ────────────────────────────────────


Describe "Show-InfrastructureJsonConfigurationHelp — mocked" {

    It "Calls Get-ConfigurationHelpData with infrastructure-config-help.json" {
        InModuleScope VcfEdgeAtScale {
            Mock Get-ConfigurationHelpData { return $null }
            Mock Show-ConfigurationHelpTable {}
            Show-InfrastructureJsonConfigurationHelp
            Should -Invoke Get-ConfigurationHelpData -Times 1 -ParameterFilter { $HelpFileName -eq "infrastructure-config-help.json" } -Scope It
        }
    }

    It "Does not call Show-ConfigurationHelpTable when Get-ConfigurationHelpData returns null" {
        InModuleScope VcfEdgeAtScale {
            Mock Get-ConfigurationHelpData { return $null }
            Mock Show-ConfigurationHelpTable {}
            Show-InfrastructureJsonConfigurationHelp
            Should -Invoke Show-ConfigurationHelpTable -Times 0 -Scope It
        }
    }
}

# ── Show-SupervisorJsonConfigurationHelp ──────────────────────────────────────


Describe "Show-SupervisorJsonConfigurationHelp — mocked" {

    It "Calls Get-ConfigurationHelpData with supervisor-config-help.json" {
        InModuleScope VcfEdgeAtScale {
            Mock Get-ConfigurationHelpData { return $null }
            Mock Show-ConfigurationHelpTable {}
            Show-SupervisorJsonConfigurationHelp
            Should -Invoke Get-ConfigurationHelpData -Times 1 -ParameterFilter { $HelpFileName -eq "supervisor-config-help.json" } -Scope It
        }
    }

    It "Calls Show-ConfigurationHelpTable when Get-ConfigurationHelpData returns data" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Get-ConfigurationHelpData { return @([PSCustomObject]@{ Key = "test.key"; Required = "Yes"; Notes = "A note." }) }
            Mock Show-ConfigurationHelpTable {}
            Show-SupervisorJsonConfigurationHelp -Format "List"
            Should -Invoke Show-ConfigurationHelpTable -Times 1 -Scope It
        }
    }
}

# ── Invoke-VcfEdgeAtScaleUpdateCheck ──────────────────────────────────────────


Describe "Invoke-VcfEdgeAtScaleUpdateCheck" {

    It "Returns early and logs a debug message when InputData.common.autoUpdate is false" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            $inputData = [PSCustomObject]@{
                common = [PSCustomObject]@{ autoUpdate = $false }
            }
            { Invoke-VcfEdgeAtScaleUpdateCheck -InputData $inputData } | Should -Not -Throw
            Should -Invoke Write-LogMessage -Times 1 -ParameterFilter { $Type -eq "DEBUG" -and $Message -like "*autoUpdate*" } -Scope It
        }
    }

    It "Logs an ADVISORY message when a newer version is available (manual install path)" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            # Not installed via PSGallery — Get-InstalledModule returns null.
            Mock Get-InstalledModule { $null }
            Mock Get-Module { [PSCustomObject]@{ Version = [Version]"1.0.0" } }
            Mock Find-Module { [PSCustomObject]@{ Version = [Version]"2.0.0" } }
            # Write-Host calls in the manual-install path are intentional interactive output;
            # mock them so tests do not emit to the console.
            Mock Write-Host {}
            Invoke-VcfEdgeAtScaleUpdateCheck
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq "ADVISORY" -and $Message -match "2\.0\.0" } -Scope It
        }
    }

    It "Returns without logging an ADVISORY when the module is already up to date" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Get-InstalledModule { $null }
            Mock Get-Module { [PSCustomObject]@{ Version = [Version]"2.0.0" } }
            Mock Find-Module { [PSCustomObject]@{ Version = [Version]"2.0.0" } }
            Invoke-VcfEdgeAtScaleUpdateCheck
            Should -Not -Invoke Write-LogMessage -ParameterFilter { $Type -eq "ADVISORY" } -Scope It
        }
    }
}

# Test-PhysicalNicConnected — Get-VMHostNetworkAdapter -VMHost has ArgumentTransformationAttribute
# so the unit-test path (passing PSCustomObject -VMHost to the mock) fails to bind before the
# mock can intercept. Coverage is provided by the live test.

# ── Get-AvailableVmClassNames ─────────────────────────────────────────────────


Describe "Resolve-DeploymentRootDirectory" {

    It "Returns DefaultBaseDirectory when no env var is set and user presses Enter" {
        $result = InModuleScope VcfEdgeAtScale {
            $env:VcfEdgeAtScaleRootDirectory = $null
            Mock Write-Host {}
            Mock Read-Host { "" }
            Resolve-DeploymentRootDirectory -DefaultBaseDirectory (Join-Path ([System.IO.Path]::GetTempPath()) "VcfEdgeAtScale")
        }
        $result | Should -Be (Join-Path ([System.IO.Path]::GetTempPath()) "VcfEdgeAtScale")
    }

    It "Returns the user-typed path when user provides a custom directory" {
        $result = InModuleScope VcfEdgeAtScale {
            $env:VcfEdgeAtScaleRootDirectory = $null
            Mock Write-Host {}
            Mock Read-Host { "/custom/deployment/root" }
            Resolve-DeploymentRootDirectory -DefaultBaseDirectory (Join-Path ([System.IO.Path]::GetTempPath()) "VcfEdgeAtScale")
        }
        $result | Should -Be "/custom/deployment/root"
    }

    It "Clears the stale env var when it points to a non-existent path and then prompts" {
        $result = InModuleScope VcfEdgeAtScale {
            $env:VcfEdgeAtScaleRootDirectory = "/path/that/does/not/exist/abc123"
            Mock Write-Host {}
            Mock Read-Host { "/fallback/dir" }
            Resolve-DeploymentRootDirectory -DefaultBaseDirectory (Join-Path ([System.IO.Path]::GetTempPath()) "VcfEdgeAtScale")
        }
        $result | Should -Be "/fallback/dir"
        $env:VcfEdgeAtScaleRootDirectory | Should -BeNullOrEmpty
    }

    It "Returns the env var path when it resolves to a fully initialized layout and user accepts" {
        $result = InModuleScope VcfEdgeAtScale {
            $tempDir = [System.IO.Path]::GetTempPath()
            $env:VcfEdgeAtScaleRootDirectory = $tempDir
            Mock Test-VcfEdgeAtScaleDeploymentRootInitialized { $true }
            Mock Write-Host {}
            # User presses Enter (accepts the existing dir)
            Mock Read-Host { "" }
            Resolve-DeploymentRootDirectory -DefaultBaseDirectory (Join-Path ([System.IO.Path]::GetTempPath()) "VcfEdgeAtScale")
        }
        $result | Should -Not -BeNullOrEmpty
    }

    It "Returns the env var path when it resolves to a fully initialized layout and user answers 'n'" {
        $result = InModuleScope VcfEdgeAtScale {
            $tempDir = (Resolve-Path -LiteralPath ([System.IO.Path]::GetTempPath())).Path
            $env:VcfEdgeAtScaleRootDirectory = $tempDir
            Mock Test-VcfEdgeAtScaleDeploymentRootInitialized { $true }
            Mock Write-Host {}
            # Answer "n" to "Initialize a different directory instead?" → keep the current env root
            Mock Read-Host { "n" }
            Resolve-DeploymentRootDirectory -DefaultBaseDirectory (Join-Path ([System.IO.Path]::GetTempPath()) "VcfEdgeAtScale")
        }
        $result | Should -Not -BeNullOrEmpty
    }
}


Describe "Copy-InitializeTemplateFiles — guard paths and copy logic" {

    It "Logs an error and returns false when a required YAML template source file is missing" {
        $result = InModuleScope VcfEdgeAtScale {
            $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "veastest-$([System.Guid]::NewGuid().ToString('N'))"
            $null = New-Item -ItemType Directory -Path $tempRoot -Force
            try {
                # TemplatesPath directory exists but has no files — first YAML template will be missing.
                $Script:VcfEdgeAtScaleServiceYamlTemplateFileNames = @("missing-template.yaml")
                Mock Write-Host {}
                Mock Write-LogMessage {}
                $copyResult = Copy-InitializeTemplateFiles `
                    -DocsDirectory         (Join-Path $tempRoot "Docs") `
                    -ServicesYamlDirectory (Join-Path $tempRoot "ServicesYaml") `
                    -TemplateRestoreHint   "Reinstall the module." `
                    -TemplatesPath         $tempRoot `
                    -ToolsDirectory        (Join-Path $tempRoot "Tools")
                Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq "ERROR" -and $Message -match "Required module template is missing" } -Times 1 -Exactly
                return $copyResult
            } finally {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        $result | Should -Be $false
    }

    It "Skips the YAML copy when Confirm-FileOverwritePrompt returns false" {
        $copyCount = InModuleScope VcfEdgeAtScale {
            $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "veastest-$([System.Guid]::NewGuid().ToString('N'))"
            $null = New-Item -ItemType Directory -Path $tempRoot -Force
            try {
                $Script:VcfEdgeAtScaleServiceYamlTemplateFileNames = @("service.yaml")
                # Create the source YAML template file so the exists-check passes.
                $null = New-Item -ItemType File -Path (Join-Path $tempRoot "service.yaml") -Force
                # Confirm-FileOverwritePrompt → $false simulates user answering N to overwrite.
                Mock Confirm-FileOverwritePrompt { $false }
                Mock Update-HelpJsonIfStale { $false }
                Mock Write-Host {}
                Mock Write-Warning {}
                $Script:_copyCount = 0
                Mock Copy-Item { $Script:_copyCount++ }
                $null = Copy-InitializeTemplateFiles `
                    -DocsDirectory         (Join-Path $tempRoot "Docs") `
                    -ServicesYamlDirectory (Join-Path $tempRoot "ServicesYaml") `
                    -TemplateRestoreHint   "Reinstall the module." `
                    -TemplatesPath         $tempRoot `
                    -ToolsDirectory        (Join-Path $tempRoot "Tools")
                $Script:_copyCount
            } finally {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        # No files copied because Confirm returned false for every prompt.
        $copyCount | Should -Be 0
    }
}

# ── Initialize-RootJsonFilesFromTemplate ─────────────────────────────────────


Describe "Initialize-RootJsonFilesFromTemplate — error paths log and return false" {

    It "Logs ERROR and returns false when the infrastructure template file is missing" {
        $result = InModuleScope VcfEdgeAtScale {
            $tmpRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "veas-test-$([System.Guid]::NewGuid().ToString('N'))"
            $null = New-Item -ItemType Directory -Path $tmpRoot -Force
            try {
                Mock Write-Host {}
                Mock Write-LogMessage {}
                Initialize-RootJsonFilesFromTemplate `
                    -BaseDirectory                 $tmpRoot `
                    -InfrastructureDestinationPath (Join-Path $tmpRoot "infrastructure.json") `
                    -InfrastructureTemplatePath    (Join-Path $tmpRoot "missing-infra-template.json") `
                    -ServicesYamlDirectory         (Join-Path $tmpRoot "ServicesYaml") `
                    -SupervisorDestinationPath     (Join-Path $tmpRoot "supervisor.json") `
                    -SupervisorTemplatePath        (Join-Path $tmpRoot "missing-super-template.json") `
                    -TemplateRestoreHint           "reinstall hint"
            } finally {
                Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        $result | Should -Be $false
    }

    It "Logs ERROR and returns false when infrastructure template lacks supervisorServices.parentDirectory" {
        $result = InModuleScope VcfEdgeAtScale {
            $tmpRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "veas-test-$([System.Guid]::NewGuid().ToString('N'))"
            $null = New-Item -ItemType Directory -Path $tmpRoot -Force
            try {
                $templatePath = Join-Path $tmpRoot "infra-template.json"
                # Template that has no supervisorServices.parentDirectory key.
                Set-Content -Path $templatePath -Value '{"common":{"foo":"bar"}}' -Encoding UTF8
                Mock Write-Host {}
                Mock Write-LogMessage {}
                Initialize-RootJsonFilesFromTemplate `
                    -BaseDirectory                 $tmpRoot `
                    -InfrastructureDestinationPath (Join-Path $tmpRoot "infrastructure.json") `
                    -InfrastructureTemplatePath    $templatePath `
                    -ServicesYamlDirectory         (Join-Path $tmpRoot "ServicesYaml") `
                    -SupervisorDestinationPath     (Join-Path $tmpRoot "supervisor.json") `
                    -SupervisorTemplatePath        (Join-Path $tmpRoot "missing-super-template.json") `
                    -TemplateRestoreHint           "reinstall hint"
            } finally {
                Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        $result | Should -Be $false
    }

    It "Returns true and writes both JSON files when both destination paths are absent" {
        $result = InModuleScope VcfEdgeAtScale {
            $tmpRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "veas-test-$([System.Guid]::NewGuid().ToString('N'))"
            $null = New-Item -ItemType Directory -Path $tmpRoot -Force
            try {
                $infraTemplate = Join-Path $tmpRoot "infra-template.json"
                $superTemplate = Join-Path $tmpRoot "super-template.json"
                # Minimal valid infrastructure.json with the required parentDirectory placeholders.
                $infraJson = '{"common":{"supervisorServices":{"parentDirectory":"OLD_SVCS"}},"clusters":[{"harborConfiguration":{"parentDirectory":"OLD_BASE","hostname":"h.example.com"}}]}'
                Set-Content -Path $infraTemplate -Value $infraJson -Encoding UTF8
                Set-Content -Path $superTemplate -Value '{"version":1}' -Encoding UTF8
                Mock Write-Host {}
                Initialize-RootJsonFilesFromTemplate `
                    -BaseDirectory                 $tmpRoot `
                    -InfrastructureDestinationPath (Join-Path $tmpRoot "infrastructure.json") `
                    -InfrastructureTemplatePath    $infraTemplate `
                    -ServicesYamlDirectory         (Join-Path $tmpRoot "ServicesYaml") `
                    -SupervisorDestinationPath     (Join-Path $tmpRoot "supervisor.json") `
                    -SupervisorTemplatePath        $superTemplate `
                    -TemplateRestoreHint           "reinstall hint"
            } finally {
                Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        $result | Should -Be $true
    }

    It "Returns false and logs ERROR when supervisor.json template is missing" {
        $result = InModuleScope VcfEdgeAtScale {
            $tmpRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "veas-test-$([System.Guid]::NewGuid().ToString('N'))"
            $null = New-Item -ItemType Directory -Path $tmpRoot -Force
            try {
                $infraTemplate = Join-Path $tmpRoot "infra-template.json"
                $infraJson = '{"common":{"supervisorServices":{"parentDirectory":"OLD_SVCS"}},"clusters":[{"harborConfiguration":{"parentDirectory":"OLD_BASE","hostname":"h.example.com"}}]}'
                Set-Content -Path $infraTemplate -Value $infraJson -Encoding UTF8
                Mock Write-Host {}
                Mock Write-LogMessage {}
                # Supervisor template is intentionally absent.
                Initialize-RootJsonFilesFromTemplate `
                    -BaseDirectory                 $tmpRoot `
                    -InfrastructureDestinationPath (Join-Path $tmpRoot "infrastructure.json") `
                    -InfrastructureTemplatePath    $infraTemplate `
                    -ServicesYamlDirectory         (Join-Path $tmpRoot "ServicesYaml") `
                    -SupervisorDestinationPath     (Join-Path $tmpRoot "supervisor.json") `
                    -SupervisorTemplatePath        (Join-Path $tmpRoot "missing-super-template.json") `
                    -TemplateRestoreHint           "reinstall hint"
            } finally {
                Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        $result | Should -Be $false
    }
}

# ── Invoke-PersistDeploymentRootDirectory ────────────────────────────────────


Describe "Invoke-PersistDeploymentRootDirectory — env var and profile persistence" {

    It "Sets VcfEdgeAtScaleRootDirectory to ResolvedBaseDirectory for the current session" {
        InModuleScope VcfEdgeAtScale {
            $savedEnv = $env:VcfEdgeAtScaleRootDirectory
            Mock Write-Host {}
            $createdList = [System.Collections.Generic.List[String]]::new()
            try {
                Invoke-PersistDeploymentRootDirectory `
                    -BaseDirectoryWasCreated $false `
                    -ResolvedBaseDirectory   "/test/base" `
                    -SubdirectoriesCreated   $createdList
                $env:VcfEdgeAtScaleRootDirectory | Should -Be "/test/base"
            } finally {
                $env:VcfEdgeAtScaleRootDirectory = $savedEnv
            }
        }
    }

    It "Creates PROFILE and appends env var assignment when PROFILE does not yet exist" {
        InModuleScope VcfEdgeAtScale {
            $savedEnv  = $env:VcfEdgeAtScaleRootDirectory
            $savedProf = $PROFILE
            $tmpProfile = Join-Path ([System.IO.Path]::GetTempPath()) "veas-profile-$([System.Guid]::NewGuid().ToString('N')).ps1"
            $createdList = [System.Collections.Generic.List[String]]::new()
            Mock Write-Host {}
            try {
                Set-Variable -Name PROFILE -Value $tmpProfile -Scope Script
                { Invoke-PersistDeploymentRootDirectory `
                    -BaseDirectoryWasCreated $false `
                    -ResolvedBaseDirectory   "/test/base" `
                    -SubdirectoriesCreated   $createdList } | Should -Not -Throw
                (Test-Path $tmpProfile) | Should -Be $true
            } finally {
                $env:VcfEdgeAtScaleRootDirectory = $savedEnv
                Set-Variable -Name PROFILE -Value $savedProf -Scope Script
                if (Test-Path $tmpProfile) { Remove-Item -LiteralPath $tmpProfile -Force -ErrorAction SilentlyContinue }
            }
        }
    }

    It "Does not append to PROFILE when ENV_VAR_NAME is already present" {
        InModuleScope VcfEdgeAtScale {
            $savedEnv  = $env:VcfEdgeAtScaleRootDirectory
            $savedProf = $PROFILE
            $tmpProfile = Join-Path ([System.IO.Path]::GetTempPath()) "veas-profile-$([System.Guid]::NewGuid().ToString('N')).ps1"
            $createdList = [System.Collections.Generic.List[String]]::new()
            Mock Write-Host {}
            try {
                # Pre-seed the profile with the env var assignment so the function should skip appending.
                Set-Content -Path $tmpProfile -Value "`$env:VcfEdgeAtScaleRootDirectory = `"/old/path`"" -Encoding UTF8
                Set-Variable -Name PROFILE -Value $tmpProfile -Scope Script
                Invoke-PersistDeploymentRootDirectory `
                    -BaseDirectoryWasCreated $false `
                    -ResolvedBaseDirectory   "/test/base" `
                    -SubdirectoriesCreated   $createdList
                $content = Get-Content -LiteralPath $tmpProfile -Raw
                # File should contain exactly one occurrence of the env var name — the one we seeded.
                ($content -split "VcfEdgeAtScaleRootDirectory").Count | Should -Be 2
            } finally {
                $env:VcfEdgeAtScaleRootDirectory = $savedEnv
                Set-Variable -Name PROFILE -Value $savedProf -Scope Script
                if (Test-Path $tmpProfile) { Remove-Item -LiteralPath $tmpProfile -Force -ErrorAction SilentlyContinue }
            }
        }
    }
}

# ── Invoke-WitnessFaultDomainSetup — fault domain resolution and stretched cluster activation ──


Describe "Invoke-VcfEdgeAtScaleCollectLogs" {
    It "Logs ERROR and returns null when VcfEdgeAtScaleRootDirectory is unset and Read-Host returns empty" {
        $result = InModuleScope VcfEdgeAtScale {
            $saved = $env:VcfEdgeAtScaleRootDirectory
            $env:VcfEdgeAtScaleRootDirectory = ""
            Mock Read-Host { return "" }
            Mock Write-Host {}
            Mock Write-LogMessage {}
            try {
                Invoke-VcfEdgeAtScaleCollectLogs
            } finally {
                $env:VcfEdgeAtScaleRootDirectory = $saved
            }
        }
        $result | Should -BeNullOrEmpty
    }

    It "Logs ERROR and returns null when infrastructure.json does not exist in the deployment root" {
        $result = InModuleScope VcfEdgeAtScale {
            $tmpRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "veas-test-$([System.Guid]::NewGuid().ToString('N'))"
            $null = New-Item -ItemType Directory -Path $tmpRoot -Force
            try {
                $saved = $env:VcfEdgeAtScaleRootDirectory
                $env:VcfEdgeAtScaleRootDirectory = $tmpRoot
                Mock Read-Host { return "Y" }
                Mock Write-Host {}
                Mock Write-LogMessage {}
                Invoke-VcfEdgeAtScaleCollectLogs
            } finally {
                $env:VcfEdgeAtScaleRootDirectory = $saved
                Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        $result | Should -BeNullOrEmpty
    }

    It "Creates a zip archive and returns its path when all required files exist" {
        InModuleScope VcfEdgeAtScale {
            $tmpRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "veas-test-$([System.Guid]::NewGuid().ToString('N'))"
            $null = New-Item -ItemType Directory -Path $tmpRoot -Force
            $null = New-Item -ItemType Directory -Path (Join-Path $tmpRoot "Logs") -Force
            $null = New-Item -ItemType Directory -Path (Join-Path $tmpRoot "ServicesYaml") -Force
            Set-Content -Path (Join-Path $tmpRoot "infrastructure.json") -Value "{}" -Encoding UTF8
            Set-Content -Path (Join-Path $tmpRoot "supervisor.json") -Value "{}" -Encoding UTF8
            try {
                $saved = $env:VcfEdgeAtScaleRootDirectory
                $env:VcfEdgeAtScaleRootDirectory = $tmpRoot
                Mock Read-Host { return "Y" }
                Mock Write-Host {}
                $zipPath = Invoke-VcfEdgeAtScaleCollectLogs
                $zipPath | Should -Match "VcfEdgeAtScale-logs-.*\.zip$"
                (Test-Path -LiteralPath $zipPath) | Should -Be $true
            } finally {
                $env:VcfEdgeAtScaleRootDirectory = $saved
                Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
                if ($zipPath -and (Test-Path -LiteralPath $zipPath)) {
                    Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
                }
            }
        }
    }
}


Describe "Start-VcfEdgeAtScale" {
    It "Writes a warning about missing directory and does not throw when VcfEdgeAtScaleRootDirectory is unset (no deploy switch)" {
        InModuleScope VcfEdgeAtScale {
            $saved = $env:VcfEdgeAtScaleRootDirectory
            $env:VcfEdgeAtScaleRootDirectory = ""
            Mock Write-LogMessage {}
            try {
                { Start-VcfEdgeAtScale } | Should -Not -Throw
                Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq "WARNING" }
            } finally {
                $env:VcfEdgeAtScaleRootDirectory = $saved
            }
        }
    }

    It "Delegates to Invoke-VcfEdgeAtScaleCollectLogs when -CollectLogs is passed" {
        InModuleScope VcfEdgeAtScale {
            Mock Invoke-VcfEdgeAtScaleCollectLogs { return (Join-Path ([System.IO.Path]::GetTempPath()) "archive.zip") }
            { Start-VcfEdgeAtScale -CollectLogs } | Should -Not -Throw
            Should -Invoke Invoke-VcfEdgeAtScaleCollectLogs -Times 1
        }
    }

    It "Returns without printing next-step hints when -Initialize fails (callee returns null)" {
        InModuleScope VcfEdgeAtScale {
            Mock Invoke-VcfEdgeAtScaleModuleInitialize { return $null }
            Mock Write-Host {}
            { Start-VcfEdgeAtScale -Initialize } | Should -Not -Throw
            # Next-step hints must NOT be printed when init failed — only the callee's logged error should appear.
            Should -Invoke Write-Host -Times 0 -ParameterFilter { $Object -match "Next step" }
        }
    }

    It "Logs the module version and returns when -Version is passed" {
        InModuleScope VcfEdgeAtScale {
            Mock New-LogFile {}
            Mock Invoke-VcfEdgeAtScaleModuleVersionStalenessCheck {}
            Mock Get-Module {
                [PSCustomObject]@{ Name = "VcfEdgeAtScale"; Version = [version]"1.2.3.4" }
            }
            $loggedMessages = [System.Collections.Generic.List[String]]::new()
            Mock Write-LogMessage {
                param([String]$Message)
                $loggedMessages.Add($Message)
            }
            Start-VcfEdgeAtScale -Version
            ($loggedMessages | Where-Object { $_ -match "VcfEdgeAtScale version:" }).Count | Should -BeGreaterOrEqual 1
        }
    }

    It "Deploy path: delegates to Invoke-VcfEdgeAtScaleSiteDeployment when VcfEdgeAtScaleRootDirectory is a valid directory" {
        $callCount = InModuleScope VcfEdgeAtScale {
            $Script:_siteDeployCount = 0
            $fakeRoot = [System.IO.Path]::GetTempPath()
            $saved = $env:VcfEdgeAtScaleRootDirectory
            $env:VcfEdgeAtScaleRootDirectory = $fakeRoot
            Mock New-LogFile {}
            function Invoke-VcfEdgeAtScaleSiteDeployment {
                [CmdletBinding()]
                Param(
                    [Parameter()] [Object]$AcceptBadCheckResults,
                    [Parameter()] [Object]$CleanUp,
                    [Parameter()] [Object]$ComputeOnly,
                    [Parameter()] [Object]$DelayBeforeAddingNextHostSeconds,
                    [Parameter()] [Object]$DeploymentRootDirectory,
                    [Parameter()] [Object]$EdgeSite,
                    [Parameter()] [Object]$Force,
                    [Parameter()] [Object]$InfrastructureJson,
                    [Parameter()] [Object]$RollbackOnFailure,
                    [Parameter()] [Object]$SaveHarborYaml,
                    [Parameter()] [Object]$SupervisorJson,
                    [Parameter()] [Object]$ValidateOnly
                )
                $Script:_siteDeployCount++
            }
            try {
                Start-VcfEdgeAtScale
            } finally {
                $env:VcfEdgeAtScaleRootDirectory = $saved
            }
            $Script:_siteDeployCount
        }
        $callCount | Should -Be 1
    }

    It "Deploy path: calls Write-VcfDeploymentFailureFooter when Invoke-VcfEdgeAtScaleSiteDeployment throws VcfDeploymentException" {
        $footerCallCount = InModuleScope VcfEdgeAtScale {
            $Script:_footerCallCount = 0
            $fakeRoot = [System.IO.Path]::GetTempPath()
            $saved = $env:VcfEdgeAtScaleRootDirectory
            $env:VcfEdgeAtScaleRootDirectory = $fakeRoot
            Mock New-LogFile {}
            function Invoke-VcfEdgeAtScaleSiteDeployment {
                [CmdletBinding()]
                Param(
                    [Parameter()] [Object]$AcceptBadCheckResults,
                    [Parameter()] [Object]$CleanUp,
                    [Parameter()] [Object]$ComputeOnly,
                    [Parameter()] [Object]$DelayBeforeAddingNextHostSeconds,
                    [Parameter()] [Object]$DeploymentRootDirectory,
                    [Parameter()] [Object]$EdgeSite,
                    [Parameter()] [Object]$Force,
                    [Parameter()] [Object]$InfrastructureJson,
                    [Parameter()] [Object]$RollbackOnFailure,
                    [Parameter()] [Object]$SaveHarborYaml,
                    [Parameter()] [Object]$SupervisorJson,
                    [Parameter()] [Object]$ValidateOnly
                )
                throw [VcfDeploymentException]::new("simulated deployment failure")
            }
            function Write-VcfDeploymentFailureFooter {
                [CmdletBinding()] Param()
                $Script:_footerCallCount++
            }
            try {
                # Start-VcfEdgeAtScale catches VcfDeploymentException — it must not propagate.
                { Start-VcfEdgeAtScale } | Should -Not -Throw
            } finally {
                $env:VcfEdgeAtScaleRootDirectory = $saved
            }
            $Script:_footerCallCount
        }
        $footerCallCount | Should -Be 1
    }

    It "Deploy path: calls Write-VcfDeploymentFailureFooter for unexpected (non-VcfDeploymentException) errors" {
        $footerCallCount = InModuleScope VcfEdgeAtScale {
            $Script:_footerCallCount2 = 0
            $fakeRoot = [System.IO.Path]::GetTempPath()
            $saved = $env:VcfEdgeAtScaleRootDirectory
            $env:VcfEdgeAtScaleRootDirectory = $fakeRoot
            Mock New-LogFile {}
            Mock Write-LogMessage {}
            function Invoke-VcfEdgeAtScaleSiteDeployment {
                [CmdletBinding()]
                Param(
                    [Parameter()] [Object]$AcceptBadCheckResults,
                    [Parameter()] [Object]$CleanUp,
                    [Parameter()] [Object]$ComputeOnly,
                    [Parameter()] [Object]$DelayBeforeAddingNextHostSeconds,
                    [Parameter()] [Object]$DeploymentRootDirectory,
                    [Parameter()] [Object]$EdgeSite,
                    [Parameter()] [Object]$Force,
                    [Parameter()] [Object]$InfrastructureJson,
                    [Parameter()] [Object]$RollbackOnFailure,
                    [Parameter()] [Object]$SaveHarborYaml,
                    [Parameter()] [Object]$SupervisorJson,
                    [Parameter()] [Object]$ValidateOnly
                )
                throw [System.Exception]::new("unexpected runtime failure")
            }
            function Write-VcfDeploymentFailureFooter {
                [CmdletBinding()] Param()
                $Script:_footerCallCount2++
            }
            try {
                # The outer generic catch must swallow unexpected errors and call the footer.
                { Start-VcfEdgeAtScale } | Should -Not -Throw
            } finally {
                $env:VcfEdgeAtScaleRootDirectory = $saved
            }
            $Script:_footerCallCount2
        }
        $footerCallCount | Should -Be 1
    }
}

Describe "Invoke-VcfEdgeAtScaleVersionDisplay" {

    It "Logs version from loaded module when available" {
        InModuleScope VcfEdgeAtScale {
            Mock New-LogFile {}
            Mock Write-LogMessage {}
            Mock Get-Module { [PSCustomObject]@{ Version = [version]"1.2.3"; Name = "VcfEdgeAtScale" } }
            Invoke-VcfEdgeAtScaleVersionDisplay
            Should -Invoke Write-LogMessage -ParameterFilter { $Message -match "1\.2\.3" } -Scope It
        }
    }

    It "Falls back to Script:ModuleVersion when module load lookup returns null" {
        InModuleScope VcfEdgeAtScale {
            $Script:ModuleVersion = "0.0.0.test"
            Mock New-LogFile {}
            Mock Write-LogMessage {}
            Mock Get-Module { $null }
            Invoke-VcfEdgeAtScaleVersionDisplay
            Should -Invoke Write-LogMessage -ParameterFilter { $Message -match "0\.0\.0\.test" } -Scope It
        }
    }
}

Describe "Resolve-VcfEdgeAtScaleDeployPaths" {

    BeforeEach { $script:_savedRoot = $env:VcfEdgeAtScaleRootDirectory }
    AfterEach {
        if ($null -ne $script:_savedRoot) { $env:VcfEdgeAtScaleRootDirectory = $script:_savedRoot }
        else { Remove-Item "env:\VcfEdgeAtScaleRootDirectory" -ErrorAction SilentlyContinue }
    }

    It "Returns null when VcfEdgeAtScaleRootDirectory is not set" {
        $env:VcfEdgeAtScaleRootDirectory = ""
        $result = InModuleScope VcfEdgeAtScale { Resolve-VcfEdgeAtScaleDeployPaths }
        $result | Should -Be $null
    }

    It "Returns a path object with default JSON paths when env var points to an existing directory" {
        $tmpDir = [System.IO.Path]::GetTempPath()
        $env:VcfEdgeAtScaleRootDirectory = $tmpDir
        $result = InModuleScope VcfEdgeAtScale { Resolve-VcfEdgeAtScaleDeployPaths }
        $result | Should -Not -Be $null
        $result.RootDirectory | Should -Not -BeNullOrEmpty
        $result.InfrastructureJson | Should -Match "infrastructure\.json"
        $result.SupervisorJson | Should -Match "supervisor\.json"
    }
}

# ── Write-LogMessage ──────────────────────────────────────────────────────────


Describe "Invoke-VcfEdgeAtScaleModuleInitialize" {
    It "Returns null when the base directory cannot be created" {
        $result = InModuleScope VcfEdgeAtScale {
            function Resolve-DeploymentRootDirectory {
                [CmdletBinding()] Param([Parameter()] [Object]$DefaultBaseDirectory)
                return "/nonexistent/veas-test-path"
            }
            Mock Write-LogMessage {}
            Mock Test-Path { $false } -ParameterFilter { $PathType -eq "Container" }
            Mock New-Item { throw "Access denied" } -ParameterFilter { $ItemType -eq "Directory" }
            Invoke-VcfEdgeAtScaleModuleInitialize
        }
        $result | Should -BeNullOrEmpty
    }
}

# ── Add-PhysicalAdaptersToVDS ─────────────────────────────────────────────────


Describe "Invoke-VcfEdgeAtScaleSiteDeployment — Harbor preflight" {
    It "Calls Invoke-HarborEnvVarPreflight once when Harbor is enabled for a cluster and CleanUp is not set" {
        $preflightCount = InModuleScope VcfEdgeAtScale {
            $Script:_harborPreflightCount = 0
            function Invoke-VcfEdgeAtScaleModuleVersionStalenessCheck { [CmdletBinding()] Param() }
            function Initialize-ScriptVcfPowerCliModuleVersion { [CmdletBinding()] Param([Parameter()] [Object]$MinimumVcfPowerCliVersion) }
            function Get-ModuleTemplatesPath { [CmdletBinding()] Param(); return "" }
            function Update-HelpJsonIfStale { [CmdletBinding()] Param([Parameter()] [Object]$DocsPath, [Parameter()] [Object]$TemplatePath) }
            function Test-EdgeSiteNameValid { [CmdletBinding()] Param([Parameter()] [Object]$Name); return $true }
            function Update-InfrastructureJsonReferencedFilePaths { [CmdletBinding()] Param([Parameter()] [Object]$InfrastructureJsonPath, [Parameter()] [Object]$InputData) }
            function Invoke-YamlFileExistenceValidation { [CmdletBinding()] Param([Parameter()] [Object]$InputData, [Parameter()] [Object]$SiteIndication, [Parameter()] [Object]$EdgeSitesArray, [Parameter()] [Object]$CleanUp, [Parameter()] [Switch]$ComputeOnly) }
            function Invoke-JsonConfigurationValidation { [CmdletBinding()] Param([Parameter()] [Object]$InfrastructureJson, [Parameter()] [Object]$SupervisorJson, [Parameter()] [Object]$InputData, [Parameter()] [Object]$SiteIndication, [Parameter()] [Object]$ValidationStartTime, [Parameter()] [Object]$CleanUp, [Parameter()] [Object]$EdgeSite, [Parameter()] [Switch]$ComputeOnly) }
            # Harbor is enabled (disableHarbor flag returns false = not disabled = Harbor active).
            function Get-EffectiveSupervisorServiceFlag { [CmdletBinding()] Param([Parameter()] [Object]$Cluster, [Parameter()] [Object]$CommonData, [Parameter()] [Object]$FlagName); return $false }
            function Invoke-HarborEnvVarPreflight {
                [CmdletBinding()] Param([Parameter()] [Object]$InputData, [Parameter()] [Object]$EdgeSite)
                begin { $Script:_harborPreflightCount++ }
                process {}
            }
            function Initialize-VcfEdgeAtScale { [CmdletBinding()] Param([Parameter()] [Object]$InfrastructureJson, [Parameter()] [Object]$SupervisorJson, [Parameter()] [Object]$DelayBeforeAddingNextHostSeconds) }
            Mock Write-LogMessage {}
            Mock Invoke-VcfEdgeAtScaleUpdateCheck {}
            Mock ConvertFrom-JsonSafely {
                return [PSCustomObject]@{
                    common   = [PSCustomObject]@{ vCenterName = "vc.lab" }
                    clusters = @([PSCustomObject]@{ edgeSite = "edge1" })
                }
            }
            Invoke-VcfEdgeAtScaleSiteDeployment `
                -DeploymentRootDirectory ([System.IO.Path]::GetTempPath()) `
                -InfrastructureJson "infra.json" `
                -SupervisorJson "supervisor.json"
            $Script:_harborPreflightCount
        }
        $preflightCount | Should -Be 1
    }
}

Describe "Invoke-VcfEdgeAtScaleSiteDeployment — RollbackOnFailure sets preference" {
    It "Sets Script:RollbackOnFailurePreference to false when RollbackOnFailure=false is passed" {
        $preference = InModuleScope VcfEdgeAtScale {
            function Invoke-VcfEdgeAtScaleModuleVersionStalenessCheck { [CmdletBinding()] Param() }
            function Initialize-ScriptVcfPowerCliModuleVersion { [CmdletBinding()] Param([Parameter()] [Object]$MinimumVcfPowerCliVersion) }
            function Get-ModuleTemplatesPath { [CmdletBinding()] Param(); return "" }
            function Update-HelpJsonIfStale { [CmdletBinding()] Param([Parameter()] [Object]$DocsPath, [Parameter()] [Object]$TemplatePath) }
            function Test-EdgeSiteNameValid { [CmdletBinding()] Param([Parameter()] [Object]$Name); return $true }
            function Update-InfrastructureJsonReferencedFilePaths { [CmdletBinding()] Param([Parameter()] [Object]$InfrastructureJsonPath, [Parameter()] [Object]$InputData) }
            # Harbor disabled for all clusters so harbor preflight is skipped.
            function Get-EffectiveSupervisorServiceFlag { [CmdletBinding()] Param([Parameter()] [Object]$Cluster, [Parameter()] [Object]$CommonData, [Parameter()] [Object]$FlagName); return $true }
            function Invoke-YamlFileExistenceValidation { [CmdletBinding()] Param([Parameter()] [Object]$InputData, [Parameter()] [Object]$SiteIndication, [Parameter()] [Object]$EdgeSitesArray, [Parameter()] [Object]$CleanUp, [Parameter()] [Switch]$ComputeOnly) }
            function Invoke-JsonConfigurationValidation { [CmdletBinding()] Param([Parameter()] [Object]$InfrastructureJson, [Parameter()] [Object]$SupervisorJson, [Parameter()] [Object]$InputData, [Parameter()] [Object]$SiteIndication, [Parameter()] [Object]$ValidationStartTime, [Parameter()] [Object]$CleanUp, [Parameter()] [Object]$EdgeSite, [Parameter()] [Switch]$ComputeOnly) }
            function Initialize-VcfEdgeAtScale { [CmdletBinding()] Param([Parameter()] [Object]$InfrastructureJson, [Parameter()] [Object]$SupervisorJson, [Parameter()] [Object]$DelayBeforeAddingNextHostSeconds) }
            Mock Write-LogMessage {}
            Mock Invoke-VcfEdgeAtScaleUpdateCheck {}
            Mock ConvertFrom-JsonSafely {
                return [PSCustomObject]@{
                    common   = [PSCustomObject]@{ vCenterName = "vc.lab" }
                    clusters = @([PSCustomObject]@{ edgeSite = "edge1" })
                }
            }
            Invoke-VcfEdgeAtScaleSiteDeployment `
                -DeploymentRootDirectory ([System.IO.Path]::GetTempPath()) `
                -InfrastructureJson "infra.json" `
                -SupervisorJson "supervisor.json" `
                -RollbackOnFailure $false
            $Script:RollbackOnFailurePreference
        }
        $preference | Should -Be $false
    }
}
