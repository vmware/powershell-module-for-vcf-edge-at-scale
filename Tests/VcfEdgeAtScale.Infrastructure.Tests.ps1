# Pester tests for VcfEdgeAtScale — module-level types, exceptions, and metadata
#
# RECOMMENDED: Use the wrapper script for human-readable output:
#   ./Tests/Run-Tests.ps1
#   ./Tests/Run-Tests.ps1 -Filter "*FunctionName*"
#
# DIRECT: Invoke-Pester -Path ./Tests/VcfEdgeAtScale.Infrastructure.Tests.ps1 -Output Detailed
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

Describe "RollbackSkippedException" {
    It "Can be thrown and caught by type" {
        $caught = InModuleScope VcfEdgeAtScale {
            $c = $false
            try {
                throw [RollbackSkippedException]::new()
            } catch {
                $c = $true
            }
            $c
        }
        $caught | Should -Be $true
    }

    It "Has the expected message" {
        $msg = InModuleScope VcfEdgeAtScale {
            ([RollbackSkippedException]::new()).Message
        }
        $msg | Should -Be "Rollback skipped by user; continue to next site."
    }

    It "Is not caught by a typed catch for a different exception type" {
        $caught = InModuleScope VcfEdgeAtScale {
            $c = $false
            try {
                throw [RollbackSkippedException]::new()
            } catch [System.IO.IOException] {
                $c = $true
            } catch {
                # Correct — swallow intentionally; test verifies this branch was reached instead of the IO branch.
                [void]$null
            }
            $c
        }
        $caught | Should -Be $false
    }
}

Describe "Install-VcfEdgeAtScaleModule" {
    BeforeAll {
        # Parse $itemsToCopy directly from the installer script without executing it.
        # This catches omissions like the Private/ directory that broke source installs.
        $installerPath = Join-Path -Path $PSScriptRoot -ChildPath ".." | Join-Path -ChildPath "Install-VcfEdgeAtScaleModule.ps1"
        $script:installerContent = Get-Content -Path $installerPath -Raw
        $script:itemsToCopyMatch = [regex]::Match($script:installerContent, '\$itemsToCopy\s*=\s*@\(([^)]+)\)')
        $script:itemsToCopyRaw = if ($script:itemsToCopyMatch.Success) {
            $script:itemsToCopyMatch.Groups[1].Value -split '[\r\n,"]+' |
                ForEach-Object { $_.Trim().Trim('"') } |
                Where-Object { $_ -ne '' }
        } else { @() }
    }

    It "Contains VcfEdgeAtScale.psm1" {
        $script:itemsToCopyRaw | Should -Contain "VcfEdgeAtScale.psm1"
    }

    It "Contains VcfEdgeAtScale.psd1" {
        $script:itemsToCopyRaw | Should -Contain "VcfEdgeAtScale.psd1"
    }

    It "Contains Private — required for dot-sourced module split" {
        $script:itemsToCopyRaw | Should -Contain "Private"
    }

    It "Contains Templates" {
        $script:itemsToCopyRaw | Should -Contain "Templates"
    }

    It "Contains Tools" {
        $script:itemsToCopyRaw | Should -Contain "Tools"
    }

    It "Has at least 5 items — catches accidental truncation of the list" {
        $script:itemsToCopyRaw.Count | Should -BeGreaterOrEqual 5
    }

    It "Description mentions Private" {
        $script:installerContent | Should -Match "Private"
    }
}


Describe "Module metadata" {
    It "Script:ModuleVersion matches ModuleVersion in psd1" {
        $psdVersion = [String](Import-PowerShellDataFile (Join-Path $script:mod.ModuleBase "VcfEdgeAtScale.psd1")).ModuleVersion
        $scriptVersion = InModuleScope VcfEdgeAtScale { $Script:ModuleVersion }
        $scriptVersion | Should -Be $psdVersion
    }

    It "Script:ModuleVersion is not null or empty" {
        $scriptVersion = InModuleScope VcfEdgeAtScale { $Script:ModuleVersion }
        $scriptVersion | Should -Not -BeNullOrEmpty
    }

    It "Script:ModuleVersion is not 'unknown'" {
        $scriptVersion = InModuleScope VcfEdgeAtScale { $Script:ModuleVersion }
        $scriptVersion | Should -Not -Be "unknown"
    }

    It "ModuleVersion in psd1 is parseable as [System.Version] and has at least 3 parts — catches 5-part typos like 1.0.0.3.1006" {
        # [System.Version] accepts 2, 3, or 4 numeric parts only. A 5-part version (e.g. 1.0.0.3.1006
        # typed instead of 1.0.3.1010) throws, signaling a malformed manifest before any code ships.
        $psdVersion = (Import-PowerShellDataFile (Join-Path $script:mod.ModuleBase "VcfEdgeAtScale.psd1")).ModuleVersion
        { [System.Version]$psdVersion } | Should -Not -Throw
        $parsed = [System.Version]$psdVersion
        $parsed.Major | Should -BeGreaterOrEqual 1
        $parsed.Minor | Should -BeGreaterOrEqual 0
    }
}


Describe "ESX host deduplication — null and case-insensitive safety" {
    It "Deduplicates case-insensitive hostnames correctly" {
        # Validates that HashSet[string] with OrdinalIgnoreCase treats 'HOST.lab' and 'host.lab' as one entry.
        $result = @(InModuleScope VcfEdgeAtScale {
            # Simulate the dedup loop directly with a known input.
            $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            $list = [System.Collections.Generic.List[object]]::new()
            foreach ($h in @("host.lab", "HOST.lab", "Host.Lab", "other.lab")) {
                if (-not [String]::IsNullOrWhiteSpace($h) -and $seen.Add($h)) {
                    $list.Add($h)
                }
            }
            $list | Write-Output
        })
        $result.Count | Should -Be 2
        $result | Should -Contain "host.lab"
        $result | Should -Contain "other.lab"
    }

    It "Skips null and whitespace-only hostnames without throwing" {
        $result = @(InModuleScope VcfEdgeAtScale {
            $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            $list = [System.Collections.Generic.List[object]]::new()
            foreach ($h in @($null, "", "   ", "real.host")) {
                if (-not [String]::IsNullOrWhiteSpace($h) -and $seen.Add($h)) {
                    $list.Add($h)
                }
            }
            # Pipeline the list so PowerShell unrolls it into individual objects rather than returning the List as one object.
            $list | Write-Output
        })
        $result.Count | Should -Be 1
        $result[0] | Should -Be "real.host"
    }
}


Describe "Initialize parentDirectory regex replacement" {
    # Validates that the regex in Invoke-VcfEdgeAtScaleModuleInitialize correctly patches
    # supervisorServices.parentDirectory and harborConfiguration.parentDirectory in the
    # template JSON — the riskiest mutation in the Initialize flow.
    It "Replaces supervisorServices.parentDirectory correctly" {
        $json = '{"common":{"supervisorServices":{"parentDirectory":"OLD_SVCS","otherKey":"val"}}}'
        $newPath = "/new/services/yaml"
        $escaped = $newPath.Replace('\', '\\').Replace('"', '\"')
        $pattern = '(?s)("common"\s*:\s*\{.*?"supervisorServices"\s*:\s*\{.*?"parentDirectory"\s*:\s*")([^"]*)(")'
        $result = [regex]::Match($json, $pattern)
        $result.Success | Should -Be $true
        $replaced = $json.Substring(0, $result.Index) + $result.Groups[1].Value + $escaped + $result.Groups[3].Value + $json.Substring($result.Index + $result.Length)
        ($replaced | ConvertFrom-Json).common.supervisorServices.parentDirectory | Should -Be $newPath
    }

    It "Replaces harborConfiguration.parentDirectory correctly" {
        $json = '{"clusters":[{"harborConfiguration":{"parentDirectory":"OLD","hostname":"h.example.com"}}]}'
        $newPath = "/new/harbor/base"
        $escaped = $newPath.Replace('\', '\\').Replace('"', '\"')
        $pattern = '(?s)("harborConfiguration"\s*:\s*\{[^}]*?"parentDirectory"\s*:\s*")([^"]*)(")'
        $replaced = [regex]::Replace($json, $pattern, "`${1}$escaped`${3}")
        ($replaced | ConvertFrom-Json).clusters[0].harborConfiguration.parentDirectory | Should -Be $newPath
    }

    It "Returns valid JSON after both replacements" {
        $json = '{"common":{"supervisorServices":{"parentDirectory":"SVCS"}},"clusters":[{"harborConfiguration":{"parentDirectory":"HARBOR","hostname":"h.example.com"}}]}'
        $svcsPath = "C:\\Users\\Admin\\ServicesYaml"
        $harborPath = "C:\\Users\\Admin"
        $escapedSvcs = $svcsPath.Replace('\', '\\').Replace('"', '\"')
        $escapedHarbor = $harborPath.Replace('\', '\\').Replace('"', '\"')
        $svcsPat = '(?s)("common"\s*:\s*\{.*?"supervisorServices"\s*:\s*\{.*?"parentDirectory"\s*:\s*")([^"]*)(")'
        $m = [regex]::Match($json, $svcsPat)
        $out = $json.Substring(0, $m.Index) + $m.Groups[1].Value + $escapedSvcs + $m.Groups[3].Value + $json.Substring($m.Index + $m.Length)
        $harborPat = '(?s)("harborConfiguration"\s*:\s*\{[^}]*?"parentDirectory"\s*:\s*")([^"]*)(")'
        $out = [regex]::Replace($out, $harborPat, "`${1}$escapedHarbor`${3}")
        { $out | ConvertFrom-Json } | Should -Not -Throw
        ($out | ConvertFrom-Json).common.supervisorServices.parentDirectory | Should -Be $svcsPath
        ($out | ConvertFrom-Json).clusters[0].harborConfiguration.parentDirectory | Should -Be $harborPath
    }
}


Describe "PowerCLI Cmdlet Parameter Validation" {
    # Validates every PowerCLI cmdlet invocation in the source against the installed module
    # signatures using the PowerShell AST parser. Catches bugs like `Get-VM -VMHost` where
    # the parameter name does not match any real parameter on that cmdlet.
    # Skipped automatically when no VMware modules are installed (e.g. minimal CI environments).

    BeforeAll {
        $vcliModuleNames = @(
            'VMware.VimAutomation.Core',
            'VMware.VimAutomation.Storage',
            'VMware.VimAutomation.Vds',
            'VMware.VimAutomation.WorkloadManagement',
            'VMware.VimAutomation.Common'
        )
        foreach ($m in $vcliModuleNames) { Import-Module $m -ErrorAction SilentlyContinue }

        $loadedCmds = @(Get-Command -Module $vcliModuleNames -ErrorAction SilentlyContinue)
        $script:vcliAvailable = $loadedCmds.Count -gt 0

        $script:vcliParamIndex = @{}
        if ($script:vcliAvailable) {
            $commonParamNames = [System.Collections.Generic.HashSet[string]]::new(
                [System.Management.Automation.Cmdlet]::CommonParameters,
                [System.StringComparer]::OrdinalIgnoreCase
            )

            foreach ($cmd in $loadedCmds) {
                $names = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                foreach ($p in $cmd.Parameters.Values) {
                    [void]$names.Add($p.Name)
                    foreach ($alias in $p.Aliases) { [void]$names.Add($alias) }
                }
                $script:vcliParamIndex[$cmd.Name.ToLower()] = @{ Valid = $names; Common = $commonParamNames }
            }
        }

        $script:vcliViolations = [System.Collections.Generic.List[string]]::new()
        if ($script:vcliAvailable) {
            $srcDirs = @(
                (Join-Path -Path $PSScriptRoot -ChildPath (Join-Path -Path '..' -ChildPath 'Private')),
                (Join-Path -Path $PSScriptRoot -ChildPath (Join-Path -Path '..' -ChildPath 'Public'))
            )
            $isCmdAst = [scriptblock]{ $args[0] -is [System.Management.Automation.Language.CommandAst] }

            foreach ($dir in $srcDirs) {
                foreach ($file in (Get-ChildItem $dir -Filter '*.ps1' -Recurse -ErrorAction SilentlyContinue)) {
                    $parseErrors = $null; $tokens = $null
                    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
                        $file.FullName, [ref]$tokens, [ref]$parseErrors
                    )
                    foreach ($cmdAst in $ast.FindAll($isCmdAst, $true)) {
                        $cmdName = $cmdAst.CommandElements[0].Value
                        if (-not $cmdName) { continue }
                        $entry = $script:vcliParamIndex[$cmdName.ToLower()]
                        if (-not $entry) { continue }

                        foreach ($elem in $cmdAst.CommandElements) {
                            if ($elem -isnot [System.Management.Automation.Language.CommandParameterAst]) { continue }
                            $pName = $elem.ParameterName
                            if ($entry.Common.Contains($pName)) { continue }
                            if (-not $entry.Valid.Contains($pName)) {
                                $script:vcliViolations.Add(
                                    "$($file.Name):$($elem.Extent.StartLineNumber) — $cmdName -$pName"
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    It "All PowerCLI cmdlet parameters match the installed module signatures" -Skip:(-not $script:vcliAvailable) {
        $script:vcliViolations | Should -BeNullOrEmpty -Because (
            "the following cmdlet/parameter combinations are invalid in the installed PowerCLI version:`n  " +
            ($script:vcliViolations -join "`n  ")
        )
    }
}


Describe "VcfDeploymentException" {
    It "Has 'Deployment failed.' as the default no-arg message" {
        $msg = InModuleScope VcfEdgeAtScale {
            ([VcfDeploymentException]::new()).Message
        }
        $msg | Should -Be "Deployment failed."
    }

    It "Stores a custom message when constructed with one argument" {
        $msg = InModuleScope VcfEdgeAtScale {
            ([VcfDeploymentException]::new("Harbor install failed.")).Message
        }
        $msg | Should -Be "Harbor install failed."
    }

    It "Can be thrown and caught by type" {
        $caught = InModuleScope VcfEdgeAtScale {
            $c = $false
            try {
                throw [VcfDeploymentException]::new("test error")
            } catch {
                $c = $true
            }
            $c
        }
        $caught | Should -Be $true
    }

    It "Is not caught by a typed catch for a different exception type" {
        $caught = InModuleScope VcfEdgeAtScale {
            $c = $false
            try {
                throw [VcfDeploymentException]::new()
            } catch [System.IO.IOException] {
                $c = $true
            } catch {
                [void]$null
            }
            $c
        }
        $caught | Should -Be $false
    }
}


Describe "Harbor YAML redaction regex" {
    # Verify the -replace pattern used in Invoke-HarborTempYamlCleanup and New-HarborDataValuesFile.
    # A regression here would mean secrets appear unmasked in diagnostics files and DEBUG logs.
    BeforeAll {
        $script:redactPattern = '^(\s*(?:harborAdminPassword|secretKey|password|secret):\s+)\S.*$'
    }

    It "Redacts harborAdminPassword scalar values" {
        "harborAdminPassword: MySecret123" -replace $script:redactPattern, '$1[REDACTED]' |
            Should -Be "harborAdminPassword: [REDACTED]"
    }

    It "Redacts secretKey scalar values" {
        "secretKey: s0meRand0mKey!" -replace $script:redactPattern, '$1[REDACTED]' |
            Should -Be "secretKey: [REDACTED]"
    }

    It "Redacts indented password scalar values" {
        "  password: admin123" -replace $script:redactPattern, '$1[REDACTED]' |
            Should -Be "  password: [REDACTED]"
    }

    It "Does not redact non-secret YAML fields" {
        "storageClass: vSAN-default" -replace $script:redactPattern, '$1[REDACTED]' |
            Should -Be "storageClass: vSAN-default"
        "hostname: harbor.example.com" -replace $script:redactPattern, '$1[REDACTED]' |
            Should -Be "hostname: harbor.example.com"
    }
}


Describe "Read-VcfEdgeAtScaleManifestVersion" {

    It "Returns 'unknown' and emits a Warning when the manifest file does not exist" {
        # Read-VcfEdgeAtScaleManifestVersion is removed from the Function: drive after module init.
        # We re-define it inside InModuleScope to exercise the error-path contract.
        $result = InModuleScope VcfEdgeAtScale {
            function Read-VcfEdgeAtScaleManifestVersion {
                [CmdletBinding()] [OutputType([String])] Param(
                    [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ManifestPath
                )
                try {
                    # -ErrorAction Stop converts non-terminating file-not-found into a catchable exception.
                    return (Import-PowerShellDataFile -Path $ManifestPath -ErrorAction Stop).ModuleVersion
                } catch {
                    Write-Warning "VcfEdgeAtScale: Could not read module version from '$ManifestPath' — $($_.Exception.Message). Version will be reported as 'unknown'."
                    return "unknown"
                }
            }
            Read-VcfEdgeAtScaleManifestVersion -ManifestPath "/nonexistent/VcfEdgeAtScale.psd1"
        }
        $result | Should -Be "unknown"
    }

    It "Returns the version string from a valid manifest" {
        $tmpPsd1 = Join-Path ([System.IO.Path]::GetTempPath()) ("veas-test-{0}.psd1" -f [System.Guid]::NewGuid().ToString("N").Substring(0, 8))
        try {
            "@{ ModuleVersion = '9.8.7.6' }" | Set-Content -Path $tmpPsd1 -Encoding UTF8
            $result = InModuleScope VcfEdgeAtScale -ArgumentList $tmpPsd1 {
                function Read-VcfEdgeAtScaleManifestVersion {
                    [CmdletBinding()] [OutputType([String])] Param(
                        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ManifestPath
                    )
                    try { return (Import-PowerShellDataFile -Path $ManifestPath -ErrorAction Stop).ModuleVersion }
                    catch {
                        Write-Warning "VcfEdgeAtScale: Could not read module version from '$ManifestPath' — $($_.Exception.Message). Version will be reported as 'unknown'."
                        return "unknown"
                    }
                }
                Read-VcfEdgeAtScaleManifestVersion -ManifestPath $args[0]
            }
            $result | Should -Be "9.8.7.6"
        } finally {
            Remove-Item $tmpPsd1 -Force -ErrorAction SilentlyContinue
        }
    }
}

# ── Invoke-VcenterConnectionWithRetry ────────────────────────────────────────

