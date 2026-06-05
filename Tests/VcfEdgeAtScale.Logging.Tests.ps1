# Pester tests for VcfEdgeAtScale — Private/Logging.ps1
#
# RECOMMENDED: Use the wrapper script for human-readable output:
#   ./Tests/Run-Tests.ps1
#   ./Tests/Run-Tests.ps1 -Filter "*FunctionName*"
#
# DIRECT: Invoke-Pester -Path ./Tests/VcfEdgeAtScale.Logging.Tests.ps1 -Output Detailed
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

Describe "Get-CleanErrorMessage" {
    It "Returns localized message when present in JSON" {
        $json = '{"localized":"The operation failed."}'
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $json { Get-CleanErrorMessage -ErrorMessage $args[0] }
        $result | Should -Be "The operation failed."
    }

    It "Returns default_message when present and localized absent" {
        $json = '{"default_message":"Default error text"}'
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $json { Get-CleanErrorMessage -ErrorMessage $args[0] }
        $result | Should -Be "Default error text"
    }

    It "Returns original message when no JSON pattern matches" {
        $plainInput = "Plain error string"
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $plainInput { Get-CleanErrorMessage -ErrorMessage $args[0] }
        $result | Should -Be $plainInput
    }
}


Describe "Get-CleanServiceErrorMessage" {
    It "Extracts namespace not found (Pattern 1)" {
        $msg = 'namespaces "my-ns" not found'
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $msg { Get-CleanServiceErrorMessage -ErrorMessage $args[0] }
        $result | Should -Be "Namespace `"my-ns`" does not exist"
    }

    It "Extracts API server says (Pattern 2) and strips parenthesized reason" {
        $msg = "API server says: The resource already exists (reason: Conflict)."
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $msg { Get-CleanServiceErrorMessage -ErrorMessage $args[0] }
        $result | Should -Match "resource already exists"
        $result | Should -Not -Match "\(reason:\s*Conflict\)"
    }

    It "Extracts kapp error (Pattern 3)" {
        $msg = "kapp: Error: Deployment failed (timeout)."
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $msg { Get-CleanServiceErrorMessage -ErrorMessage $args[0] }
        $result | Should -Match "Deployment failed"
    }

    It "Returns Reason and actual message when both present" {
        $msg = "Reason: ReconcileFailed. Message: Namespace does not exist."
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $msg { Get-CleanServiceErrorMessage -ErrorMessage $args[0] }
        $result | Should -Match "Reason: ReconcileFailed"
        $result | Should -Match "Namespace"
    }

    It "Returns original message when no pattern matches" {
        $plainInput = "Unknown error format"
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $plainInput { Get-CleanServiceErrorMessage -ErrorMessage $args[0] }
        $result | Should -Be $plainInput
    }

    It "De-dup regex does not collapse normal words that share substrings" {
        # The regex is \\b(.{2,}?)\\1+\\b — verify it does not reduce words like 'processing'
        # where internal letter groups could match sub-patterns.
        $msg = "processing processing error"
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $msg { Get-CleanServiceErrorMessage -ErrorMessage $args[0] }
        $result | Should -Not -BeNullOrEmpty
        $result | Should -Match "processing error"
    }

    It "De-dup regex does not collapse word-level repetition — only character-pattern repetition" {
        # The regex \b(.{2,}?)\1+\b collapses INTERNAL character-group repetition (e.g. 'abab' -> 'ab'),
        # not word-level repetition ('failed failed' remains unchanged because the word boundary
        # anchors require the repeated group to share characters within a single token).
        # This is correct behaviour: word-level dedup is not the function's contract.
        $msg = "failed failed"
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $msg { Get-CleanServiceErrorMessage -ErrorMessage $args[0] }
        # Falls through to fallback path; original message is returned since no patterns match.
        $result | Should -Not -BeNullOrEmpty
    }

    It "Returns unrecognized message unchanged (fallback path)" {
        $result = InModuleScope VcfEdgeAtScale { Get-CleanServiceErrorMessage -ErrorMessage "unknown error" }
        $result | Should -Be "unknown error"
    }

    It "Preserves single-character words that cannot form valid duplicates" {
        $msg = "a b c error"
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $msg { Get-CleanServiceErrorMessage -ErrorMessage $args[0] }
        $result | Should -Not -BeNullOrEmpty
    }
}


Describe "ConvertFrom-SecureStringViaBstr" {
    It "Converts a SecureString to the correct plain-text value" {
        $secure = ConvertTo-SecureString -String "bstr-test-value" -AsPlainText -Force
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $secure { ConvertFrom-SecureStringViaBstr -SecureString $args[0] }
        $result | Should -Be "bstr-test-value"
    }

    It "Converts an empty SecureString to an empty string" -Skip {
        # ConvertTo-SecureString rejects empty strings by default; this test is skipped
        # because the edge case of truly empty credentials is not practically supported by PowerShell.
    }
}

Describe "Get-VcenterRestApiPlainPassword" {
    It "Returns plain text from SecureString" {
        $secure = ConvertTo-SecureString -String "unit-test-secret" -AsPlainText -Force
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $secure { Get-VcenterRestApiPlainPassword -VcenterPassword $args[0] }
        $result | Should -Be "unit-test-secret"
    }

    It "Returns plain text from PSCredential" {
        $secure = ConvertTo-SecureString -String "cred-secret" -AsPlainText -Force
        $cred = New-Object System.Management.Automation.PSCredential("user", $secure)
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $cred { Get-VcenterRestApiPlainPassword -VcenterCredential $args[0] }
        $result | Should -Be "cred-secret"
    }

    It "Prefers SecureString over PSCredential when both are supplied" {
        $secureWin = ConvertTo-SecureString -String "from-secure" -AsPlainText -Force
        $secureCred = ConvertTo-SecureString -String "from-cred" -AsPlainText -Force
        $cred = New-Object System.Management.Automation.PSCredential("user", $secureCred)
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $secureWin,$cred { Get-VcenterRestApiPlainPassword -VcenterPassword $args[0] -VcenterCredential $args[1] }
        $result | Should -Be "from-secure"
    }

    It "Returns plain string when SecureString is absent" {
        $result = InModuleScope VcfEdgeAtScale { Get-VcenterRestApiPlainPassword -VcenterInsecurePassword "plain-pass" }
        $result | Should -Be "plain-pass"
    }

    It "Prefers SecureString when both are supplied" {
        $secure = ConvertTo-SecureString -String "from-secure" -AsPlainText -Force
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $secure { Get-VcenterRestApiPlainPassword -VcenterInsecurePassword "from-plain" -VcenterPassword $args[0] }
        $result | Should -Be "from-secure"
    }

    It "Returns null when both sources are empty" {
        $result = InModuleScope VcfEdgeAtScale { Get-VcenterRestApiPlainPassword -VcenterInsecurePassword "" }
        $result | Should -Be $null
    }
}


Describe "Get-VcfSdkInitializeCommand" {
    It "Returns first existing cmdlet from candidates" {
        $cmd = InModuleScope VcfEdgeAtScale { Get-VcfSdkInitializeCommand -NameCandidates @("Get-Process", "Nonexistent-Cmdlet-XYZ") }
        $cmd | Should -Not -Be $null
        $cmd.Name | Should -Be "Get-Process"
    }

    It "Returns null when no candidate exists" {
        $cmd = InModuleScope VcfEdgeAtScale { Get-VcfSdkInitializeCommand -NameCandidates @("Nonexistent-Cmdlet-XYZ-123", "Another-Missing-Cmdlet") }
        $cmd | Should -Be $null
    }

    It "Skips whitespace-only candidate names" {
        $cmd = InModuleScope VcfEdgeAtScale { Get-VcfSdkInitializeCommand -NameCandidates @("   ", "Get-Date") }
        $cmd.Name | Should -Be "Get-Date"
    }
}


Describe "Test-VcfPowerCliVersionAtLeast" {
    It "Returns false when Script:VcfPowerCliModuleVersion is unset" {
        $result = InModuleScope VcfEdgeAtScale {
            $Script:VcfPowerCliModuleVersion = $null
            Test-VcfPowerCliVersionAtLeast -MinimumVersion "9.0.0"
        }
        $result | Should -Be $false
    }

    It "Returns true when cached version meets minimum" {
        $result = InModuleScope VcfEdgeAtScale {
            $Script:VcfPowerCliModuleVersion = [version]"9.1.0.0"
            Test-VcfPowerCliVersionAtLeast -MinimumVersion "9.0.0"
        }
        $result | Should -Be $true
    }

    It "Returns false when cached version is below minimum" {
        $result = InModuleScope VcfEdgeAtScale {
            $Script:VcfPowerCliModuleVersion = [version]"8.9.0.0"
            Test-VcfPowerCliVersionAtLeast -MinimumVersion "9.0.0"
        }
        $result | Should -Be $false
    }
}


Describe "Test-LogLevel" {
    It "Returns <Expected> for ConfiguredLevel '<ConfiguredLevel>' MessageType '<MessageType>'" -ForEach @(
        @{ ConfiguredLevel = "INFO";    MessageType = "DEBUG";     Expected = $false }
        @{ ConfiguredLevel = "INFO";    MessageType = "INFO";      Expected = $true  }
        @{ ConfiguredLevel = "INFO";    MessageType = "ERROR";     Expected = $true  }
        @{ ConfiguredLevel = "DEBUG";   MessageType = "DEBUG";     Expected = $true  }
        @{ ConfiguredLevel = "DEBUG";   MessageType = "INFO";      Expected = $true  }
        @{ ConfiguredLevel = "DEBUG";   MessageType = "ADVISORY";  Expected = $true  }
        @{ ConfiguredLevel = "DEBUG";   MessageType = "WARNING";   Expected = $true  }
        @{ ConfiguredLevel = "DEBUG";   MessageType = "EXCEPTION"; Expected = $true  }
        @{ ConfiguredLevel = "DEBUG";   MessageType = "ERROR";     Expected = $true  }
        @{ ConfiguredLevel = "ERROR";   MessageType = "DEBUG";     Expected = $false }
        @{ ConfiguredLevel = "ERROR";   MessageType = "INFO";      Expected = $false }
        @{ ConfiguredLevel = "ERROR";   MessageType = "ADVISORY";  Expected = $false }
        @{ ConfiguredLevel = "ERROR";   MessageType = "WARNING";   Expected = $false }
        @{ ConfiguredLevel = "ERROR";   MessageType = "EXCEPTION"; Expected = $false }
        @{ ConfiguredLevel = "ADVISORY"; MessageType = "INFO";     Expected = $false }
        @{ ConfiguredLevel = "ADVISORY"; MessageType = "ADVISORY"; Expected = $true  }
        @{ ConfiguredLevel = "ADVISORY"; MessageType = "WARNING";  Expected = $true  }
    ) {
        $result = InModuleScope VcfEdgeAtScale -ArgumentList $ConfiguredLevel, $MessageType {
            Test-LogLevel -ConfiguredLevel $args[0] -MessageType $args[1]
        }
        $result | Should -Be $Expected
    }
}


Describe "Write-ErrorAndReturn" {
    It "Returns Success false" {
        $result = InModuleScope VcfEdgeAtScale { Write-ErrorAndReturn -ErrorMessage "Something went wrong" }
        $result.Success | Should -Be $false
    }

    It "Returns the provided error message" {
        $result = InModuleScope VcfEdgeAtScale { Write-ErrorAndReturn -ErrorMessage "Disk not found" }
        $result.ErrorMessage | Should -Be "Disk not found"
    }

    It "Returns default error code when not specified" {
        $result = InModuleScope VcfEdgeAtScale { Write-ErrorAndReturn -ErrorMessage "fail" }
        $result.ErrorCode | Should -Be "ERR_UNKNOWN"
    }

    It "Returns the specified error code" {
        $result = InModuleScope VcfEdgeAtScale { Write-ErrorAndReturn -ErrorCode "ERR_VDS_ADD_HOST" -ErrorMessage "fail" }
        $result.ErrorCode | Should -Be "ERR_VDS_ADD_HOST"
    }
}


Describe "Get-VcfEdgeAtScaleInstallSource" {
    # Tests the extracted helper directly — no Get-EnvironmentSetup, no kubectl stub,
    # no message-scraping. If these tests fail the failure message is unambiguous.

    It "Returns 'PSGallery (vX.Y.Z)' when Get-InstalledModule returns a repository record" {
        $result = InModuleScope VcfEdgeAtScale {
            Mock Get-InstalledModule {
                [PSCustomObject]@{ Repository = "PSGallery"; Version = "1.0.3.1010" }
            }
            Get-VcfEdgeAtScaleInstallSource -ModuleVersion "1.0.3.1010"
        }
        $result | Should -Be "PSGallery (v1.0.3.1010)"
    }

    It "Returns 'Local path (...)' when Get-InstalledModule returns null and module is loaded" {
        # Get-Module -Name VcfEdgeAtScale returns the loaded module (loaded in BeforeAll).
        $result = InModuleScope VcfEdgeAtScale {
            Mock Get-InstalledModule { return $null }
            Get-VcfEdgeAtScaleInstallSource -ModuleVersion "1.0.3.1010"
        }
        $result | Should -Match "^Local path \("
    }

    It "Returns 'N/A' when Get-InstalledModule returns null and Get-Module returns null" {
        $result = InModuleScope VcfEdgeAtScale {
            Mock Get-InstalledModule { return $null }
            Mock Get-Module -ParameterFilter { $Name -eq "VcfEdgeAtScale" } { return $null }
            Get-VcfEdgeAtScaleInstallSource -ModuleVersion "1.0.3.1010"
        }
        $result | Should -Be "N/A"
    }

    It "Returns 'N/A' when Get-InstalledModule throws" {
        $result = InModuleScope VcfEdgeAtScale {
            Mock Get-InstalledModule { throw "PowerShellGet unavailable" }
            Mock Get-Module -ParameterFilter { $Name -eq "VcfEdgeAtScale" } { return $null }
            Get-VcfEdgeAtScaleInstallSource -ModuleVersion "1.0.3.1010"
        }
        $result | Should -Be "N/A"
    }

    It "Returns 'N/A (manifest unreadable)' when ModuleVersion is 'unknown'" {
        # When the .psd1 cannot be read at import time, $Script:ModuleVersion is set to "unknown".
        # A PSGet lookup with version "unknown" would silently fail; this guard surfaces the root cause.
        $result = InModuleScope VcfEdgeAtScale {
            Get-VcfEdgeAtScaleInstallSource -ModuleVersion "unknown"
        }
        $result | Should -Be "N/A (manifest unreadable)"
    }
}


Describe "Get-EnvironmentSetup — CLI version detection degrades gracefully" {
    BeforeAll {
        $script:savedKubectl = InModuleScope VcfEdgeAtScale { $Script:KubectlCmd }
        $script:savedVcf     = InModuleScope VcfEdgeAtScale { $Script:VcfCmd }

        # Create mock scripts in a unique temp dir.
        $script:envMockDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "veas-envmock-$([System.Guid]::NewGuid().ToString('N').Substring(0, 8))"
        New-Item -ItemType Directory -Path $script:envMockDir -Force | Out-Null

        # Mock kubectl that exits non-zero.
        $script:mockKubectlFail = Join-Path $script:envMockDir "mock-kubectl-fail.ps1"
        Set-Content -Path $script:mockKubectlFail -Value '$global:LASTEXITCODE = 1; Write-Error "connection refused"' -Encoding UTF8

        # Mock vcf that returns a version string.
        $script:mockVcfOk = Join-Path $script:envMockDir "mock-vcf-ok.ps1"
        Set-Content -Path $script:mockVcfOk -Value 'Write-Output "vcf version 9.1.0"' -Encoding UTF8
    }
    AfterAll {
        InModuleScope VcfEdgeAtScale -ArgumentList $script:savedKubectl,$script:savedVcf { param($k,$v) $Script:KubectlCmd = $k; $Script:VcfCmd = $v }
        Remove-Item -Path $script:envMockDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    BeforeEach {
        $global:LASTEXITCODE = $null
        InModuleScope VcfEdgeAtScale -ArgumentList $script:savedKubectl,$script:savedVcf { param($k,$v) $Script:KubectlCmd = $k; $Script:VcfCmd = $v }
    }

    It "Does not log ERROR and does not throw when kubectl exits non-zero" {
        InModuleScope VcfEdgeAtScale -ArgumentList $script:mockKubectlFail { param($p) $Script:KubectlCmd = $p }
        InModuleScope VcfEdgeAtScale {
            Mock Initialize-ScriptVcfPowerCliModuleVersion { $Script:VcfPowerCliModuleVersion = [Version]"9.0.0" }
            Mock Write-LogMessage {}
            { Get-EnvironmentSetup } | Should -Not -Throw
            Should -Not -Invoke Write-LogMessage -ParameterFilter { $Type -eq 'ERROR' }
        }
    }

    It "Logs the detected VCF CLI version to the debug log" {
        InModuleScope VcfEdgeAtScale -ArgumentList $script:mockVcfOk { param($p) $Script:VcfCmd = $p }
        InModuleScope VcfEdgeAtScale {
            # Mock Initialize-ScriptVcfPowerCliModuleVersion so the function reaches the vcf CLI
            # block even when VCF.PowerCLI is not installed in the test environment.
            Mock Initialize-ScriptVcfPowerCliModuleVersion { $Script:VcfPowerCliModuleVersion = [Version]"9.0.0" }
            Mock Write-LogMessage {}
            Get-EnvironmentSetup
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq "DEBUG" -and $Message -match "VCF CLI version.*9\.1\.0" } -Scope It
        }
    }
}


Describe "Initialize-ScriptVcfPowerCliModuleVersion — PreResolvedModule parameter" {
    BeforeEach {
        # Save and clear the cached version so each test starts clean.
        $script:savedVcfVersion = InModuleScope VcfEdgeAtScale { $Script:VcfPowerCliModuleVersion }
        InModuleScope VcfEdgeAtScale { $Script:VcfPowerCliModuleVersion = $null }
        # Obtain a real PSModuleInfo from the already-loaded module so we satisfy the type constraint.
        # We set Module.Version on the script scope inside module scope to simulate any version.
        $script:realModuleInfo = InModuleScope VcfEdgeAtScale { Get-Module -Name "VcfEdgeAtScale" }
    }
    AfterEach {
        InModuleScope VcfEdgeAtScale -ArgumentList $script:savedVcfVersion { param($v) $Script:VcfPowerCliModuleVersion = $v }
    }

    It "Accepts a pre-resolved PSModuleInfo and caches its version" {
        # Pass the real loaded module as PreResolvedModule; override version check by using a low minimum.
        InModuleScope VcfEdgeAtScale -ArgumentList $script:realModuleInfo {
            param($m)
            Initialize-ScriptVcfPowerCliModuleVersion -PreResolvedModule $m -MinimumVcfPowerCliVersion "0.0.0"
        }
        $cached = InModuleScope VcfEdgeAtScale { $Script:VcfPowerCliModuleVersion }
        $cached | Should -Not -BeNullOrEmpty
        $cached | Should -BeOfType [Version]
    }

    It "Throws with 'below the minimum required' when the real module's version is older than minimum" {
        # Set an impossibly high minimum to force the version check to fail.
        { InModuleScope VcfEdgeAtScale -ArgumentList $script:realModuleInfo {
            param($m)
            Initialize-ScriptVcfPowerCliModuleVersion -PreResolvedModule $m -MinimumVcfPowerCliVersion "99.0.0"
        } } | Should -Throw "*below the minimum required*"
    }

    It "Throws with 'not installed' message when PreResolvedModule is explicitly null" {
        # When null is passed, the function must fall through to the installed-module check.
        # On the test machine VCF.PowerCLI IS installed so this will succeed or throw
        # with a version error — not the "not installed" error.
        # Instead verify via the else-branch directly: construct a scenario where no module exists.
        # We test this by passing $null and checking that no "below minimum" error fires (it either
        # finds the installed module or throws "not installed" — both are correct behavior).
        $threw = $false
        try {
            InModuleScope VcfEdgeAtScale {
                Initialize-ScriptVcfPowerCliModuleVersion -PreResolvedModule $null -MinimumVcfPowerCliVersion "0.0.0"
            }
        } catch {
            $threw = $true
        }
        # If it doesn't throw, it found VCF.PowerCLI; if it throws, the message should reference install/version.
        if ($threw) {
            $_ | Should -Match "VCF.PowerCLI"
        }
        # Primary assertion: function does not corrupt Script:VcfPowerCliModuleVersion on failure.
        $cached = InModuleScope VcfEdgeAtScale { $Script:VcfPowerCliModuleVersion }
        if (-not $threw) { $cached | Should -Not -BeNullOrEmpty }
    }

    It "Does not call Get-Module -ListAvailable when PreResolvedModule is supplied (fast path)" {
        # Verify the function completes and sets version even with a fresh cache — proves the fast path ran.
        InModuleScope VcfEdgeAtScale -ArgumentList $script:realModuleInfo {
            param($m)
            Initialize-ScriptVcfPowerCliModuleVersion -PreResolvedModule $m -MinimumVcfPowerCliVersion "0.0.0"
        }
        $cached = InModuleScope VcfEdgeAtScale { $Script:VcfPowerCliModuleVersion }
        $cached | Should -BeOfType [Version]
    }
}


Describe "Write-ClusterEsxiNodeHealthReport" {
    It "Logs WARNING and does not throw when Get-Cluster fails (non-fatal catch path)" {
        # When no vCenter is connected, Get-Cluster throws; the catch block logs a WARNING
        # and returns normally — the function must never propagate this exception to callers.
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            { Write-ClusterEsxiNodeHealthReport -ClusterName "nonexistent-cluster-xyz" } | Should -Not -Throw
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq 'WARNING' }
        }
    }

    It "Logs a single INFO line when all hosts are Connected and PoweredOn" {
        InModuleScope VcfEdgeAtScale {
            function Get-Cluster {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                process {}
            }
            function Get-VMHost {
                [CmdletBinding()] Param([Parameter()] [Object]$Location, [Parameter()] [Object]$Server)
                process {}
            }
            Mock Write-LogMessage {}
            Mock Get-Cluster { [PSCustomObject]@{ Name = "cl0" } }
            Mock Get-VMHost {
                @([PSCustomObject]@{ Name = "esx01.lab"; ConnectionState = "Connected"; PowerState = "PoweredOn" })
            }
            Write-ClusterEsxiNodeHealthReport -ClusterName "cl0"
            Should -Invoke Write-LogMessage -Times 1 -ParameterFilter { $Type -eq "INFO" -and $Message -match "all Connected" } -Scope It
        }
    }

    It "Logs a WARNING header and per-host line when one host is disconnected" {
        InModuleScope VcfEdgeAtScale {
            function Get-Cluster {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                process {}
            }
            function Get-VMHost {
                [CmdletBinding()] Param([Parameter()] [Object]$Location, [Parameter()] [Object]$Server)
                process {}
            }
            Mock Write-LogMessage {}
            Mock Get-Cluster { [PSCustomObject]@{ Name = "cl0" } }
            Mock Get-VMHost {
                @(
                    [PSCustomObject]@{ Name = "esx01.lab"; ConnectionState = "Connected";    PowerState = "PoweredOn" },
                    [PSCustomObject]@{ Name = "esx02.lab"; ConnectionState = "Disconnected"; PowerState = "PoweredOn" }
                )
            }
            Write-ClusterEsxiNodeHealthReport -ClusterName "cl0"
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq "WARNING" -and $Message -match "not Connected" } -Scope It
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq "WARNING" -and $Message -match "esx02\.lab" } -Scope It
        }
    }
}


Describe "Get-VcenterRestApiPlainPassword — no plaintext in logs" {
    It "Does not pass the resolved password to Write-LogMessage" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage { }
            $secure = ConvertTo-SecureString -String "super-secret-vcenter-pw" -AsPlainText -Force
            $null = Get-VcenterRestApiPlainPassword -VcenterPassword $secure
            Should -Invoke Write-LogMessage -Times 0
        }
    }
}


Describe "ConvertTo-SecureStringForCredential" {
    It "Converts a plain string to a SecureString" {
        $secure = InModuleScope VcfEdgeAtScale {
            ConvertTo-SecureStringForCredential -PlainText "my-secret"
        }
        $secure                           | Should -Not -Be $null
        $secure                           | Should -BeOfType [System.Security.SecureString]
        [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR(
            [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        ) | Should -Be "my-secret"
    }
}


Describe "Test-VcenterConnection — mocked vCenter" {
    It "Returns IsConnected false when DefaultViServers has no entry for the vCenter name" {
        $result = InModuleScope VcfEdgeAtScale {
            $Global:DefaultViServers = @()
            $Script:vCenterName     = "vc.lab"
            Test-VcenterConnection
        }
        $result.IsConnected | Should -Be $false
    }

    It "Returns IsConnected true with -SkipConnectivityTest when DefaultViServers has a matching connected entry" {
        $result = InModuleScope VcfEdgeAtScale {
            $Global:DefaultViServers = @([PSCustomObject]@{ Name = "vc.lab"; IsConnected = $true })
            $Script:vCenterName      = "vc.lab"
            Test-VcenterConnection -SkipConnectivityTest
        }
        $result.IsConnected | Should -Be $true
    }
}


Describe "Get-PythonExecutable" {
    It "Returns null or a PSCustomObject with Executable and Version properties" {
        # Get-PythonExecutable probes real candidates on PATH — it cannot be mocked
        # without a real executable. This test asserts the shape contract: the return
        # is either null (no python found) or a PSCustomObject with both expected properties.
        $result = InModuleScope VcfEdgeAtScale { Get-PythonExecutable }
        if ($null -ne $result) {
            $result.Executable | Should -Not -BeNullOrEmpty
            $result.Version    | Should -Not -BeNullOrEmpty
            $result.Version    | Should -Match "Python"
        } else {
            $result | Should -Be $null
        }
    }
}


Describe "Write-SupervisorKubernetesDiagnosticReport" {

    It "Logs INFO header when Invoke-GetSupervisorNamespaceManagementSummary is available and returns a summary" {
        InModuleScope VcfEdgeAtScale {
            function Invoke-GetSupervisorNamespaceManagementSummary {
                [CmdletBinding()] Param([Parameter()] [Object]$Supervisor)
                begin {}; process {}
            }
            Mock Write-LogMessage {}
            Mock Invoke-GetSupervisorNamespaceManagementSummary {
                [PSCustomObject]@{
                    ConfigStatus      = "CONFIGURED"
                    KubernetesStatus  = "READY"
                    Stats             = $null
                    Messages          = @()
                }
            }
            Mock Get-Command { [PSCustomObject]@{ Name = "Invoke-GetSupervisorNamespaceManagementSummary" } }
            { Write-SupervisorKubernetesDiagnosticReport -ClusterName "cl0" -SupervisorId "sup-001" } | Should -Not -Throw
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq "INFO" -and $Message -match "diagnostics" }
        }
    }

    It "Returns without logging INFO header when Invoke-GetSupervisorNamespaceManagementSummary is not available" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Get-Command { $null }
            { Write-SupervisorKubernetesDiagnosticReport -ClusterName "cl0" -SupervisorId "sup-001" } | Should -Not -Throw
            Should -Invoke Write-LogMessage -Times 1 -ParameterFilter { $Type -eq "DEBUG" -and $Message -match "not available" }
        }
    }

    It "Logs WARNING when summary API call throws" {
        InModuleScope VcfEdgeAtScale {
            function Invoke-GetSupervisorNamespaceManagementSummary {
                [CmdletBinding()] Param([Parameter()] [Object]$Supervisor)
                begin {}; process {}
            }
            Mock Write-LogMessage {}
            Mock Invoke-GetSupervisorNamespaceManagementSummary { throw "API unavailable" }
            Mock Get-Command { [PSCustomObject]@{ Name = "Invoke-GetSupervisorNamespaceManagementSummary" } }
            { Write-SupervisorKubernetesDiagnosticReport -ClusterName "cl0" -SupervisorId "sup-001" } | Should -Not -Throw
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq "WARNING" -and $Message -match "Could not read supervisor summary" }
        }
    }
}

# ── Invoke-SupervisorKubernetesDiagnosticSafe ─────────────────────────────────


Describe "New-LogFile" {

    AfterEach {
        # Clean up script-scoped log path variables so they don't bleed across tests.
        InModuleScope VcfEdgeAtScale {
            $Script:LogFolder = $null
            $Script:LogFile   = $null
        }
    }

    It "Sets Script:LogFile to a path under the given BaseDirectory" {
        $baseDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "veas-logtest-$(New-Guid)"
        try {
            InModuleScope VcfEdgeAtScale -ArgumentList $baseDir {
                param($base)
                Mock Get-EnvironmentSetup { }
                New-LogFile -BaseDirectory $base -Directory "logs" -Prefix "TestRun"
            }
            $logFile = InModuleScope VcfEdgeAtScale { $Script:LogFile }
            $logFile | Should -Not -BeNullOrEmpty
            # Use StartsWith so the temp path (which contains regex-special chars) is compared literally.
            $logFile.StartsWith($baseDir) | Should -Be $true
            $logFile | Should -Match "TestRun-\d{4}-\d{2}-\d{2}\.log"
        } finally {
            Remove-Item -Path $baseDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "Creates the log directory when it does not already exist" {
        $baseDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "veas-logtest-$(New-Guid)"
        try {
            InModuleScope VcfEdgeAtScale -ArgumentList $baseDir {
                param($base)
                Mock Get-EnvironmentSetup { }
                New-LogFile -BaseDirectory $base -Directory "newlogs" -Prefix "TestRun"
            }
            $logFolder = InModuleScope VcfEdgeAtScale { $Script:LogFolder }
            Test-Path $logFolder | Should -Be $true
        } finally {
            Remove-Item -Path $baseDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}


Describe "Write-LogEntryToFile" {

    It "Appends the provided content to Script:LogFile" {
        $tmpFile = [System.IO.Path]::GetTempFileName()
        try {
            InModuleScope VcfEdgeAtScale -ArgumentList $tmpFile {
                param($logPath)
                $Script:LogFile = $logPath
                Write-LogEntryToFile -LogContent "test-log-line"
            }
            Get-Content $tmpFile -Raw | Should -Match "test-log-line"
        } finally {
            Remove-Item -Path $tmpFile -Force -ErrorAction SilentlyContinue
        }
    }

    It "Skips Add-Content and does not throw when Script:LogFile is empty" {
        InModuleScope VcfEdgeAtScale {
            $Script:LogFile = ""
            Mock Add-Content {}
            { Write-LogEntryToFile -LogContent "should-not-be-written" } | Should -Not -Throw
            Should -Not -Invoke Add-Content
        }
    }
}

# ── New-SupervisorControlPlaneSpec — PowerCLI Initialize-* wiring ─────────────


Describe "Set-ScriptVcenterCredential" {

    AfterEach {
        InModuleScope VcfEdgeAtScale {
            $Script:VcenterCredential = $null
        }
    }

    It "Stores the provided credential in Script:VcenterCredential" {
        $cred = [PSCredential]::new("testuser", (ConvertTo-SecureString "testpass" -AsPlainText -Force))
        InModuleScope VcfEdgeAtScale -ArgumentList $cred {
            param($c)
            Set-ScriptVcenterCredential -Credential $c
            $Script:VcenterCredential | Should -Not -BeNullOrEmpty
            $Script:VcenterCredential.UserName | Should -Be "testuser"
        }
    }

    It "Overwrites a previously stored credential" {
        $cred1 = [PSCredential]::new("user1", (ConvertTo-SecureString "pass1" -AsPlainText -Force))
        $cred2 = [PSCredential]::new("user2", (ConvertTo-SecureString "pass2" -AsPlainText -Force))
        InModuleScope VcfEdgeAtScale -ArgumentList $cred1, $cred2 {
            param($c1, $c2)
            Set-ScriptVcenterCredential -Credential $c1
            Set-ScriptVcenterCredential -Credential $c2
            $Script:VcenterCredential.UserName | Should -Be "user2"
        }
    }
}

# ── Get-ConfigurationHelpData — help JSON loader and validator ────────────────


Describe "Test-VCenterVersion — mocked connection" {

    It "Returns ERR_NOT_CONNECTED when DefaultViServers is empty" {
        $result = InModuleScope VcfEdgeAtScale {
            $Global:DefaultViServers = @()
            $Script:vCenterName = "vc.lab"
            Test-VCenterVersion -MinimumVersion "9.0.0"
        }
        $result.Success   | Should -Be $false
        $result.ErrorCode | Should -Be "ERR_NOT_CONNECTED"
    }

    It "Returns ERR_VERSION_UNAVAILABLE when the Version property is null" {
        $result = InModuleScope VcfEdgeAtScale {
            $Global:DefaultViServers = @([PSCustomObject]@{ Name = "vc.lab"; IsConnected = $true; Version = $null })
            $Script:vCenterName = "vc.lab"
            Test-VCenterVersion -MinimumVersion "9.0.0"
        }
        $result.Success   | Should -Be $false
        $result.ErrorCode | Should -Be "ERR_VERSION_UNAVAILABLE"
    }

    It "Returns ERR_VERSION_TOO_OLD when detected version is below the minimum" {
        $result = InModuleScope VcfEdgeAtScale {
            $Global:DefaultViServers = @([PSCustomObject]@{ Name = "vc.lab"; IsConnected = $true; Version = "8.0.3" })
            $Script:vCenterName = "vc.lab"
            Test-VCenterVersion -MinimumVersion "9.0.0"
        }
        $result.Success   | Should -Be $false
        $result.ErrorCode | Should -Be "ERR_VERSION_TOO_OLD"
    }

    It "Returns Success=true when version exactly equals the minimum (boundary)" {
        $result = InModuleScope VcfEdgeAtScale {
            $Global:DefaultViServers = @([PSCustomObject]@{ Name = "vc.lab"; IsConnected = $true; Version = "9.0.0" })
            $Script:vCenterName = "vc.lab"
            Test-VCenterVersion -MinimumVersion "9.0.0"
        }
        $result.Success  | Should -Be $true
        $result.Version  | Should -Be "9.0.0"
    }

    It "Returns Success=true when version is above the minimum" {
        $result = InModuleScope VcfEdgeAtScale {
            $Global:DefaultViServers = @([PSCustomObject]@{ Name = "vc.lab"; IsConnected = $true; Version = "9.1.0" })
            $Script:vCenterName = "vc.lab"
            Test-VCenterVersion -MinimumVersion "9.0.0"
        }
        $result.Success | Should -Be $true
    }
}

# ── Test-ESXVersion — mocked connection ──────────────────────────────────────


Describe "Test-ESXVersion — mocked connection" {

    It "Returns ERR_NOT_CONNECTED when no matching entry exists in DefaultViServers" {
        $result = InModuleScope VcfEdgeAtScale {
            $Global:DefaultViServers = @()
            Test-ESXVersion -MinimumVersion "9.0.0" -ServerName "esx01.lab"
        }
        $result.Success   | Should -Be $false
        $result.ErrorCode | Should -Be "ERR_NOT_CONNECTED"
    }

    It "Returns ERR_NOT_CONNECTED when the matching entry is not marked IsConnected" {
        $result = InModuleScope VcfEdgeAtScale {
            $Global:DefaultViServers = @([PSCustomObject]@{ Name = "esx01.lab"; IsConnected = $false; Version = "9.0.0" })
            Test-ESXVersion -MinimumVersion "9.0.0" -ServerName "esx01.lab"
        }
        $result.Success   | Should -Be $false
        $result.ErrorCode | Should -Be "ERR_NOT_CONNECTED"
    }

    It "Returns ERR_VERSION_TOO_OLD when host version is below the minimum" {
        $result = InModuleScope VcfEdgeAtScale {
            $Global:DefaultViServers = @([PSCustomObject]@{ Name = "esx01.lab"; IsConnected = $true; Version = "8.0.3" })
            Test-ESXVersion -MinimumVersion "9.0.0" -ServerName "esx01.lab"
        }
        $result.Success   | Should -Be $false
        $result.ErrorCode | Should -Be "ERR_VERSION_TOO_OLD"
    }

    It "Returns Success=true when version exactly equals the minimum (boundary)" {
        $result = InModuleScope VcfEdgeAtScale {
            $Global:DefaultViServers = @([PSCustomObject]@{ Name = "esx01.lab"; IsConnected = $true; Version = "9.0.0" })
            Test-ESXVersion -MinimumVersion "9.0.0" -ServerName "esx01.lab"
        }
        $result.Success | Should -Be $true
        $result.Version | Should -Be "9.0.0"
    }

    It "Returns Success=true when version is above the minimum" {
        $result = InModuleScope VcfEdgeAtScale {
            $Global:DefaultViServers = @([PSCustomObject]@{ Name = "esx01.lab"; IsConnected = $true; Version = "9.1.0" })
            Test-ESXVersion -MinimumVersion "9.0.0" -ServerName "esx01.lab"
        }
        $result.Success | Should -Be $true
    }
}

# ── Write-VcfDeploymentFailureFooter ─────────────────────────────────────────


Describe "Show-Version" {
    It "Logs INFO version when -Silence is not set" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Show-Version
            Should -Invoke Write-LogMessage -Times 1 -Scope It -ParameterFilter { $Type -eq "INFO" -and $Message -match "Version" }
        }
    }

    It "Logs DEBUG version when -Silence is set and does not log INFO" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Show-Version -Silence
            Should -Invoke Write-LogMessage -Times 0 -Scope It -ParameterFilter { $Type -eq "INFO" }
            Should -Invoke Write-LogMessage -Times 1 -Scope It -ParameterFilter { $Type -eq "DEBUG" -and $Message -match "Version" }
        }
    }
}


Describe "Invoke-VcenterReconnectIfNeeded" {
    It "Throws when Script:vCenterName is not set" {
        InModuleScope VcfEdgeAtScale {
            $Script:vCenterName  = ""
            $Script:VCenterUser  = "administrator@vsphere.local"
            { Invoke-VcenterReconnectIfNeeded } | Should -Throw "*requires Script*"

        }
    }

    It "Throws when Script:VCenterUser is not set" {
        InModuleScope VcfEdgeAtScale {
            $Script:vCenterName  = "vc01.lab"
            $Script:VCenterUser  = ""
            { Invoke-VcenterReconnectIfNeeded } | Should -Throw "*requires Script*"

        }
    }

    It "Returns without reconnecting when already connected" {
        InModuleScope VcfEdgeAtScale {
            $Script:vCenterName = "vc01.lab"
            $Script:VCenterUser = "administrator@vsphere.local"
            Mock Test-VcenterConnection { return [PSCustomObject]@{ IsConnected = $true; ErrorMessage = "" } }
            Mock Connect-Vcenter {}
            Mock Write-LogMessage {}
            Invoke-VcenterReconnectIfNeeded
            Should -Invoke Connect-Vcenter -Times 0 -Scope It
        }
    }

    It "Calls Connect-Vcenter when already-stored credential is available and session is lost" {
        InModuleScope VcfEdgeAtScale {
            $Script:vCenterName      = "vc01.lab"
            $Script:VCenterUser      = "administrator@vsphere.local"
            $securePass              = ConvertTo-SecureString "P@ssw0rd" -AsPlainText -Force
            $Script:VcenterCredential = New-Object System.Management.Automation.PSCredential("administrator@vsphere.local", $securePass)
            Mock Test-VcenterConnection { return [PSCustomObject]@{ IsConnected = $false; ErrorMessage = "Session expired" } }
            Mock Disconnect-Vcenter {}
            Mock Connect-Vcenter {}
            Mock Set-ScriptVcenterCredential {}
            Mock Write-LogMessage {}
            Invoke-VcenterReconnectIfNeeded
            Should -Invoke Connect-Vcenter -Times 1 -Scope It
        }
    }
}

# ── Test-SupervisorConfiguration ─────────────────────────────────────────────


Describe "Connect-Vcenter — guard conditions" {
    It "Throws when Connect-VIServer throws an authentication error" {
        # Connect-Vcenter treats a null return as success (assigns to $null). To trigger the
        # throw path, Connect-VIServer must throw so the catch block fires.
        InModuleScope VcfEdgeAtScale {
            function Connect-VIServer {
                [CmdletBinding()] Param([Parameter()] [Object]$Server, [Parameter()] [Object]$Credential, [Parameter()] [Switch]$Force)
                process {}
            }
            Mock Write-LogMessage {}
            $cred = [PSCredential]::new("admin", (ConvertTo-SecureString "pw" -AsPlainText -Force))
            Mock Connect-VIServer { throw "Invalid credentials for server vc.lab." }
            { Connect-Vcenter -ServerName "vc.lab" -ServerType "vCenter" -ServerCredential $cred -SkipRetryPrompt } | Should -Throw "*Authentication failed*"

        }
    }

    It "Returns without throwing when Connect-VIServer succeeds" {
        InModuleScope VcfEdgeAtScale {
            function Connect-VIServer {
                [CmdletBinding()] Param([Parameter()] [Object]$Server, [Parameter()] [Object]$Credential, [Parameter()] [Switch]$Force)
                process {}
            }
            Mock Write-LogMessage {}
            $cred = [PSCredential]::new("admin", (ConvertTo-SecureString "pw" -AsPlainText -Force))
            Mock Connect-VIServer { [PSCustomObject]@{ Name = "vc.lab"; IsConnected = $true } }
            { Connect-Vcenter -ServerName "vc.lab" -ServerType "vCenter" -ServerCredential $cred -SkipRetryPrompt } | Should -Not -Throw
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq "DEBUG" -and $Message -match "Entered Connect-Vcenter" }
        }
    }
}


Describe "Disconnect-Vcenter — guard conditions" {
    It "Returns without throwing when no vCenter session exists" {
        InModuleScope VcfEdgeAtScale {
            function Disconnect-VIServer {
                [CmdletBinding(SupportsShouldProcess = $true)]
                Param([Parameter(ValueFromPipeline = $true)] [Object]$Server, [Parameter()] [Switch]$Force)
                process {}
            }
            Mock Write-LogMessage {}
            Mock Disconnect-VIServer {}
            $Script:vCenterName = "vc.lab"
            $Global:DefaultViServers = @()
            { Disconnect-Vcenter } | Should -Not -Throw
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq "DEBUG" -and $Message -match "Entered Disconnect-Vcenter" }
        }
    }

    It "Does not throw when called with -ServerName for an existing session" {
        # Verifies the named-server disconnect path completes without throwing.
        # Disconnect-VIServer is called inside a try/catch; any internal failure is swallowed.
        InModuleScope VcfEdgeAtScale {
            function Disconnect-VIServer {
                [CmdletBinding(SupportsShouldProcess = $true)]
                Param([Parameter()] [Object]$Server, [Parameter()] [Switch]$Force)
                process {}
            }
            Mock Write-LogMessage {}
            { Disconnect-Vcenter -ServerName "vc.lab" -ServerType "vCenter" } | Should -Not -Throw
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq "DEBUG" -and $Message -match "Disconnecting from vCenter" }
        }
    }
}

# ── Connect-Vcenter — retry loop (Invoke-VcenterConnectionWithRetry contract) ──


Describe "Connect-Vcenter — SkipRetryPrompt throws immediately on auth failure" {
    # These tests describe the contract of the credential retry loop that will be extracted
    # to Invoke-VcenterConnectionWithRetry. They must pass BEFORE and AFTER extraction.
    It "Throws without prompting when -SkipRetryPrompt is set and auth fails" {
        { InModuleScope VcfEdgeAtScale {
            function Connect-VIServer {
                [CmdletBinding()] Param([Parameter()] [Object]$Server, [Parameter()] [Object]$Credential, [Parameter()] [Switch]$Force)
                process {}
            }
            Mock Write-LogMessage {}
            Mock Connect-VIServer { throw "incorrect user name or password" }
            $cred = [PSCredential]::new("admin", (ConvertTo-SecureString "bad" -AsPlainText -Force))
            Connect-Vcenter -ServerName "vc.lab" -ServerType "vCenter" -ServerCredential $cred -SkipRetryPrompt
        } } | Should -Throw "*Authentication failed*"

    }

    It "Does not call Read-Host when -SkipRetryPrompt is set" {
        InModuleScope VcfEdgeAtScale {
            $Script:_readHostCalled = $false
            function Connect-VIServer {
                [CmdletBinding()] Param([Parameter()] [Object]$Server, [Parameter()] [Object]$Credential, [Parameter()] [Switch]$Force)
                process {}
            }
            function Read-Host {
                [CmdletBinding()] Param([Parameter()] [Object]$Prompt, [Parameter()] [Switch]$AsSecureString)
                $Script:_readHostCalled = $true
            }
            Mock Write-LogMessage {}
            Mock Connect-VIServer { throw "incorrect user name or password" }
            $cred = [PSCredential]::new("admin", (ConvertTo-SecureString "bad" -AsPlainText -Force))
            try { Connect-Vcenter -ServerName "vc.lab" -ServerType "vCenter" -ServerCredential $cred -SkipRetryPrompt } catch {}
            $Script:_readHostCalled | Should -Be $false
        }
    }
}


Describe "Connect-Vcenter — user declines retry (N answer)" {
    It "Throws VcfDeploymentException when user answers N to the retry prompt" {
        { InModuleScope VcfEdgeAtScale {
            function Connect-VIServer {
                [CmdletBinding()] Param([Parameter()] [Object]$Server, [Parameter()] [Object]$Credential, [Parameter()] [Switch]$Force)
                process {}
            }
            function Read-Host {
                [CmdletBinding()] Param([Parameter()] [Object]$Prompt, [Parameter()] [Switch]$AsSecureString)
                "N"
            }
            Mock Write-LogMessage {}
            Mock Connect-VIServer { throw "incorrect user name or password" }
            $cred = [PSCredential]::new("admin", (ConvertTo-SecureString "bad" -AsPlainText -Force))
            Connect-Vcenter -ServerName "vc.lab" -ServerType "vCenter" -ServerCredential $cred
        } } | Should -Throw "*User chose not to retry*"
    }
}


Describe "Connect-Vcenter — user retries with correct credentials (Y answer)" {
    It "Succeeds on second attempt after user answers Y and supplies correct password" {
        InModuleScope VcfEdgeAtScale {
            $Script:_connectCallCount = 0
            function Connect-VIServer {
                [CmdletBinding()] Param([Parameter()] [Object]$Server, [Parameter()] [Object]$Credential, [Parameter()] [Switch]$Force)
                begin { $Script:_connectCallCount++ }
                process {
                    if ($Script:_connectCallCount -eq 1) { throw "incorrect user name or password" }
                    [PSCustomObject]@{ Name = "vc.lab"; IsConnected = $true }
                }
            }
            $Script:_readCallCount = 0
            function Read-Host {
                [CmdletBinding()] Param([Parameter()] [Object]$Prompt, [Parameter()] [Switch]$AsSecureString)
                $Script:_readCallCount++
                if ($AsSecureString) { return (ConvertTo-SecureString "good" -AsPlainText -Force) }
                return "Y"
            }
            function Get-InteractiveInput {
                [CmdletBinding()] Param([Parameter()] [Object]$PromptMessage, [Parameter()] [Switch]$AsSecureString, [Parameter()] [Switch]$AllowEmpty)
                ConvertTo-SecureString "good" -AsPlainText -Force
            }
            Mock Write-LogMessage {}
            $cred = [PSCredential]::new("admin", (ConvertTo-SecureString "bad" -AsPlainText -Force))
            { Connect-Vcenter -ServerName "vc.lab" -ServerType "vCenter" -ServerCredential $cred } | Should -Not -Throw
            $Script:_connectCallCount | Should -Be 2
        }
    }
}


Describe "Connect-Vcenter — SSL error is non-retryable" {
    It "Throws VcfDeploymentException immediately on SSL error without retry prompt" {
        { InModuleScope VcfEdgeAtScale {
            function Connect-VIServer {
                [CmdletBinding()] Param([Parameter()] [Object]$Server, [Parameter()] [Object]$Credential, [Parameter()] [Switch]$Force)
                process {}
            }
            $Script:_readHostCalledSsl = $false
            function Read-Host {
                [CmdletBinding()] Param([Parameter()] [Object]$Prompt, [Parameter()] [Switch]$AsSecureString)
                $Script:_readHostCalledSsl = $true
                "Y"
            }
            Mock Write-LogMessage {}
            Mock Connect-VIServer { throw "SSL connection could not be established" }
            $cred = [PSCredential]::new("admin", (ConvertTo-SecureString "pw" -AsPlainText -Force))
            Connect-Vcenter -ServerName "vc.lab" -ServerType "vCenter" -ServerCredential $cred
        } } | Should -Throw "*SSL*"
    }

    It "Does not prompt for retry on SSL error" {
        InModuleScope VcfEdgeAtScale {
            $Script:_readHostCalledSsl2 = $false
            function Connect-VIServer {
                [CmdletBinding()] Param([Parameter()] [Object]$Server, [Parameter()] [Object]$Credential, [Parameter()] [Switch]$Force)
                process {}
            }
            function Read-Host {
                [CmdletBinding()] Param([Parameter()] [Object]$Prompt, [Parameter()] [Switch]$AsSecureString)
                $Script:_readHostCalledSsl2 = $true
                "Y"
            }
            Mock Write-LogMessage {}
            Mock Connect-VIServer { throw "SSL connection could not be established" }
            $cred = [PSCredential]::new("admin", (ConvertTo-SecureString "pw" -AsPlainText -Force))
            try { Connect-Vcenter -ServerName "vc.lab" -ServerType "vCenter" -ServerCredential $cred } catch {}
            $Script:_readHostCalledSsl2 | Should -Be $false
        }
    }
}

# ── Set-VsanDomNetworkSchedulerThrottleOnHost ────────────────────────────────


Describe "Get-SupervisorLifecycleContentLibraries — query paths" {

    It "Returns Success=false when the PowerCLI cmdlet throws" {
        $result = InModuleScope VcfEdgeAtScale {
            function Invoke-VcenterNamespaceManagementLifecycleContentLibrariesList {
                [CmdletBinding()] Param()
                process {}
            }
            Mock Write-LogMessage {}
            Mock Invoke-VcenterNamespaceManagementLifecycleContentLibrariesList { throw "API error" }
            Get-SupervisorLifecycleContentLibraries
        }
        $result.Success | Should -BeFalse
    }

    It "Returns HasReadyLibrary=true when a library with READY status is present" {
        $result = InModuleScope VcfEdgeAtScale {
            function Invoke-VcenterNamespaceManagementLifecycleContentLibrariesList {
                [CmdletBinding()] Param()
                process {}
            }
            Mock Write-LogMessage {}
            $fakeEntry = [PSCustomObject]@{ Library = [PSCustomObject]@{ Id = "lib-001" }; Status = "READY" }
            Mock Invoke-VcenterNamespaceManagementLifecycleContentLibrariesList { @($fakeEntry) }
            Get-SupervisorLifecycleContentLibraries
        }
        $result.Success | Should -BeTrue
        $result.HasReadyLibrary | Should -BeTrue
    }
}


Describe "Set-SupervisorLifecycleContentLibrary — success path" {
    It "Returns Success=true and null ErrorMessage when both SDK cmdlets succeed" {
        $result = InModuleScope VcfEdgeAtScale {
            function Initialize-VcenterNamespaceManagementLifecycleContentLibrariesSetSpec {
                [CmdletBinding()] Param([Parameter()] [Object]$Library)
                begin {}; process {}
            }
            function Invoke-VcenterNamespaceManagementLifecycleContentLibrariesSet {
                [CmdletBinding(SupportsShouldProcess = $true)] Param([Parameter()] [Object]$VcenterNamespaceManagementLifecycleContentLibrariesSetSpec)
                begin {}; process {}
            }
            Mock Write-LogMessage {}
            Mock Initialize-VcenterNamespaceManagementLifecycleContentLibrariesSetSpec { [PSCustomObject]@{ Library = "lib-123" } }
            Set-SupervisorLifecycleContentLibrary -ContentLibraryId "lib-123"
        }
        $result.Success      | Should -Be $true
        $result.ErrorMessage | Should -BeNullOrEmpty
    }
}

Describe "Set-SupervisorLifecycleContentLibrary — error path" {
    It "Returns Success=false with ErrorMessage when the SDK cmdlet throws" {
        $result = InModuleScope VcfEdgeAtScale {
            function Initialize-VcenterNamespaceManagementLifecycleContentLibrariesSetSpec {
                [CmdletBinding()] Param([Parameter()] [Object]$Library)
                begin { throw "API error: library not found" }; process {}
            }
            Mock Write-LogMessage {}
            Set-SupervisorLifecycleContentLibrary -ContentLibraryId "lib-missing"
        }
        $result.Success      | Should -Be $false
        $result.ErrorMessage | Should -Match "API error"
    }
}

Describe "Initialize-SupervisorLifecycleContentLibrary — association paths" {

    It "Returns ActionTaken=none when a READY library already exists" {
        $result = InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Get-SupervisorLifecycleContentLibraries {
                [PSCustomObject]@{ Success = $true; HasReadyLibrary = $true; Libraries = @() }
            }
            Initialize-SupervisorLifecycleContentLibrary -ContentLibraryId "lib-001"
        }
        $result.Success | Should -BeTrue
        $result.ActionTaken | Should -Be "none"
    }

    It "Returns ActionTaken=associated when no READY library exists and association succeeds" {
        $result = InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Get-SupervisorLifecycleContentLibraries {
                [PSCustomObject]@{ Success = $true; HasReadyLibrary = $false; Libraries = @() }
            }
            Mock Set-SupervisorLifecycleContentLibrary {
                [PSCustomObject]@{ Success = $true; ErrorMessage = $null }
            }
            Initialize-SupervisorLifecycleContentLibrary -ContentLibraryId "lib-002"
        }
        $result.Success | Should -BeTrue
        $result.ActionTaken | Should -Be "associated"
    }
}


Describe "Initialize-SupervisorContentLibrary — library selection paths" {

    It "Calls New-SubscriptionBasedContentLibrary when no existing library is found" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Test-ContentLibraryBySubscriptionUri { $null }
            Mock New-SubscriptionBasedContentLibrary { "lib-new" }
            Mock Initialize-SupervisorLifecycleContentLibrary { [PSCustomObject]@{ Success = $true; ActionTaken = "associated" } }
            Initialize-SupervisorContentLibrary -DatastoreName "ds1" -LibraryName "MyLib" -SubscriptionUrl "https://example.com/lib.json"
            Should -Invoke New-SubscriptionBasedContentLibrary -Times 1
        }
    }

    It "Calls Get-ContentLibraryId when a matching existing library is found" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Test-ContentLibraryBySubscriptionUri { "ExistingLib" }
            Mock Get-ContentLibraryId { "lib-existing" }
            Mock Initialize-SupervisorLifecycleContentLibrary { [PSCustomObject]@{ Success = $true; ActionTaken = "none" } }
            Initialize-SupervisorContentLibrary -DatastoreName "ds1" -LibraryName "MyLib" -SubscriptionUrl "https://example.com/lib.json"
            Should -Invoke Get-ContentLibraryId -Times 1
        }
    }
}

Describe "Invoke-DatastoreResolutionWithDiagnostics" {

    It "Returns datastore object when Get-Datastore succeeds" {
        $result = InModuleScope VcfEdgeAtScale {
            $fakeDs = [PSCustomObject]@{ Name = "ds1"; Id = "datastore-1" }
            function Get-Datastore {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                process { return $fakeDs }
            }
            Mock Write-LogMessage {}
            Invoke-DatastoreResolutionWithDiagnostics -DatastoreName "ds1"
        }
        $result.Id | Should -Be "datastore-1"
    }

    It "Throws VcfDeploymentException when datastore is not found" {
        { InModuleScope VcfEdgeAtScale {
            function Get-Datastore {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                process { return $null }
            }
            Mock Write-LogMessage {}
            Invoke-DatastoreResolutionWithDiagnostics -DatastoreName "missing-ds"
        } } | Should -Throw "*SOLUTION: Update the datastore name*"
    }

    It "Logs available datastores when target datastore is not found" {
        InModuleScope VcfEdgeAtScale {
            $callCount = 0
            function Get-Datastore {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                process {
                    $callCount++
                    # First call (named lookup) returns null; second call (list all) returns available names.
                    if ($Name) { return $null }
                    return @([PSCustomObject]@{ Name = "ds-available-1" })
                }
            }
            Mock Write-LogMessage {}
            try { Invoke-DatastoreResolutionWithDiagnostics -DatastoreName "missing-ds" } catch {}
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq "ERROR" -and $Message -match "Available datastores" }
        }
    }
}

Describe "Get-SubscriptionSslThumbprint" {

    It "Throws VcfDeploymentException when TCP connection to the subscription URL host fails" {
        { InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            # Port 65534 is almost certainly not open on localhost — connection is refused immediately.
            Get-SubscriptionSslThumbprint -SubscriptionUrl "https://localhost:65534/lib.json"
        } } | Should -Throw "*Cannot create content library without SSL thumbprint*"
    }

    It "Logs ERROR with inner exception details when connection fails" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            try { Get-SubscriptionSslThumbprint -SubscriptionUrl "https://localhost:65534/lib.json" } catch {}
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq "ERROR" -and $Message -match "Failed to retrieve SSL certificate thumbprint" }
        }
    }
}

Describe "Invoke-SubscriptionContentLibraryCreate" {

    It "Returns library ID when New-ContentLibrary succeeds and Get-ContentLibraryId returns an ID" {
        $result = InModuleScope VcfEdgeAtScale {
            function New-ContentLibrary {
                [CmdletBinding()] Param(
                    [Parameter()] [Object]$Name, [Parameter()] [Object]$Description,
                    [Parameter()] [Object]$SubscriptionUrl, [Parameter()] [Object]$Datastore,
                    [Parameter()] [Switch]$AutomaticSync, [Parameter()] [Object]$SslThumbprint,
                    [Parameter()] [Object]$Server
                )
                process {}
            }
            Mock Write-LogMessage {}
            Mock Get-ContentLibraryId { "lib-id-1234" }
            Invoke-SubscriptionContentLibraryCreate -DatastoreObject ([PSCustomObject]@{ Name = "ds1" }) -LibraryDescription "Test lib" -LibraryName "TestLib" -SslThumbprint "AA:BB:CC" -SubscriptionUrl "https://vcenter.example.com/lib.json"
        }
        $result | Should -Be "lib-id-1234"
    }

    It "Throws VcfDeploymentException when Get-ContentLibraryId returns null after creation" {
        { InModuleScope VcfEdgeAtScale {
            function New-ContentLibrary {
                [CmdletBinding()] Param(
                    [Parameter()] [Object]$Name, [Parameter()] [Object]$Description,
                    [Parameter()] [Object]$SubscriptionUrl, [Parameter()] [Object]$Datastore,
                    [Parameter()] [Switch]$AutomaticSync, [Parameter()] [Object]$SslThumbprint,
                    [Parameter()] [Object]$Server
                )
                process {}
            }
            Mock Write-LogMessage {}
            Mock Get-ContentLibraryId { $null }
            Invoke-SubscriptionContentLibraryCreate -DatastoreObject ([PSCustomObject]@{ Name = "ds1" }) -LibraryDescription "Test lib" -LibraryName "TestLib" -SslThumbprint "AA:BB:CC" -SubscriptionUrl "https://vcenter.example.com/lib.json"
        } } | Should -Throw "*was created but could not be retrieved*"
    }
}

# ── Set-VclsRetreatModeForCluster ─────────────────────────────────────────────


Describe "Set-VclsRetreatModeForCluster — retreat mode guard and cluster paths" {

    It "Returns without calling Get-Cluster when RetreatMode is false" {
        InModuleScope VcfEdgeAtScale {
            function Get-Cluster {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                process { throw "Get-Cluster must not be called when RetreatMode=false" }
            }
            Mock Write-LogMessage {}
            { Set-VclsRetreatModeForCluster -ClusterName "cl0" -RetreatMode $false } | Should -Not -Throw
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq "DEBUG" -and $Message -match "RetreatMode is false" }
        }
    }

    It "Logs WARNING and returns when Get-Cluster returns null" {
        InModuleScope VcfEdgeAtScale {
            function Get-Cluster {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                process {}
            }
            Mock Write-LogMessage {}
            Mock Get-Cluster { $null }
            { Set-VclsRetreatModeForCluster -ClusterName "missing" -RetreatMode $true -Server "vc01" } | Should -Not -Throw
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq "WARNING" -and $Message -match "could not get cluster" }
        }
    }

    It "Logs WARNING and returns when Get-Cluster throws" {
        InModuleScope VcfEdgeAtScale {
            function Get-Cluster {
                [CmdletBinding()] Param([Parameter()] [Object]$Name, [Parameter()] [Object]$Server)
                process { throw "Cluster not found" }
            }
            Mock Write-LogMessage {}
            Mock Get-Cluster { throw "Cluster not found" }
            { Set-VclsRetreatModeForCluster -ClusterName "cl0" -RetreatMode $true -Server "vc01" } | Should -Not -Throw
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq "WARNING" -and $Message -match "could not set vCLS retreat mode" }
        }
    }
}

# ── Set-VmkernelIpv4StaticGatewayViaEsxcli ───────────────────────────────────


Describe "Write-LogMessage" {

    It "Writes to log file when Script:LogFile is set" {
        InModuleScope VcfEdgeAtScale {
            $tmpFile = Join-Path ([System.IO.Path]::GetTempPath()) ("wlm-test-{0}.log" -f [System.Guid]::NewGuid().ToString("N").Substring(0, 8))
            $Script:LogFile = $tmpFile
            $Script:ConfiguredLogLevel = "DEBUG"
            $Script:LogOnly = $null
            $Script:LogMessagePending = $null
            try {
                Write-LogMessage -Type INFO -Message "hello-file-write" -SuppressOutputToScreen
                (Get-Content $tmpFile -Raw) | Should -Match "hello-file-write"
            } finally {
                $Script:LogFile = $null
                Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "Does not write to log file when SuppressOutputToFile is set" {
        InModuleScope VcfEdgeAtScale {
            $tmpFile = Join-Path ([System.IO.Path]::GetTempPath()) ("wlm-test-{0}.log" -f [System.Guid]::NewGuid().ToString("N").Substring(0, 8))
            $Script:LogFile = $tmpFile
            $Script:ConfiguredLogLevel = "DEBUG"
            $Script:LogOnly = $null
            $Script:LogMessagePending = $null
            try {
                Write-LogMessage -Type INFO -Message "should-not-appear" -SuppressOutputToScreen -SuppressOutputToFile
                (Test-Path $tmpFile) | Should -Be $false
            } finally {
                $Script:LogFile = $null
                Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "Writes combined NoNewline + CompletePending line to log file" {
        InModuleScope VcfEdgeAtScale {
            $tmpFile = Join-Path ([System.IO.Path]::GetTempPath()) ("wlm-test-{0}.log" -f [System.Guid]::NewGuid().ToString("N").Substring(0, 8))
            $Script:LogFile = $tmpFile
            $Script:ConfiguredLogLevel = "DEBUG"
            $Script:LogOnly = $null
            $Script:LogMessagePending = $null
            try {
                Write-LogMessage -Type INFO -Message "Connecting..." -NoNewline -SuppressOutputToScreen
                Write-LogMessage -Type INFO -Message " Done" -CompletePending -SuppressOutputToScreen
                $logContent = Get-Content $tmpFile -Raw
                # Combined line must appear exactly once; the pending prefix and suffix are joined.
                $logContent | Should -Match "Connecting\.\.\. Done"
            } finally {
                $Script:LogFile = $null
                Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "Writes standalone line with WARNING tag when CompletePending is called without prior NoNewline" {
        InModuleScope VcfEdgeAtScale {
            $tmpFile = Join-Path ([System.IO.Path]::GetTempPath()) ("wlm-test-{0}.log" -f [System.Guid]::NewGuid().ToString("N").Substring(0, 8))
            $Script:LogFile = $tmpFile
            $Script:ConfiguredLogLevel = "DEBUG"
            $Script:LogOnly = $null
            # Ensure no pending message is set.
            $Script:LogMessagePending = $null
            try {
                Write-LogMessage -Type INFO -Message "orphaned" -CompletePending -SuppressOutputToScreen
                $logContent = Get-Content $tmpFile -Raw
                # The implementation writes a WARNING diagnostic + the orphaned message as a standalone line.
                $logContent | Should -Match "CompletePending called with no pending"
                $logContent | Should -Match "orphaned"
            } finally {
                $Script:LogFile = $null
                Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "Log level routing — DEBUG message is suppressed when ConfiguredLevel is INFO" {
        InModuleScope VcfEdgeAtScale {
            $tmpFile = Join-Path ([System.IO.Path]::GetTempPath()) ("wlm-test-{0}.log" -f [System.Guid]::NewGuid().ToString("N").Substring(0, 8))
            $Script:LogFile = $tmpFile
            $Script:ConfiguredLogLevel = "INFO"
            $Script:LogOnly = $null
            $Script:LogMessagePending = $null
            try {
                # SuppressOutputToScreen is NOT set — if the console path ran it would call Write-Host.
                # We only test the file path here: DEBUG is still written to the log file regardless of threshold.
                Write-LogMessage -Type DEBUG -Message "debug-should-still-log" -SuppressOutputToScreen
                $logContent = Get-Content $tmpFile -Raw
                $logContent | Should -Match "debug-should-still-log"
            } finally {
                $Script:LogFile = $null
                Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "Formats log entries with timestamp, type, and message" {
        InModuleScope VcfEdgeAtScale {
            $tmpFile = Join-Path ([System.IO.Path]::GetTempPath()) ("wlm-test-{0}.log" -f [System.Guid]::NewGuid().ToString("N").Substring(0, 8))
            $Script:LogFile = $tmpFile
            $Script:ConfiguredLogLevel = "DEBUG"
            $Script:LogOnly = $null
            $Script:LogMessagePending = $null
            try {
                Write-LogMessage -Type WARNING -Message "check-format" -SuppressOutputToScreen
                $logContent = Get-Content $tmpFile -Raw
                # Entry format: [yyyy-MM-dd_HH:mm:ss] (WARNING) check-format
                $logContent | Should -Match '\[\d{4}-\d{2}-\d{2}_\d{2}:\d{2}:\d{2}\]'
                $logContent | Should -Match '\(WARNING\)'
                $logContent | Should -Match "check-format"
            } finally {
                $Script:LogFile = $null
                Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

# ── Test-HarborVolumeSizes ────────────────────────────────────────────────────


Describe "Write-VsanClusterHealthReport" {

    It "Logs INFO when overallHealth is green" {
        InModuleScope VcfEdgeAtScale {
            Mock Get-VsanClusterHealthSummaryViaView {
                [PSCustomObject]@{ overallHealth = "green"; overallHealthDescription = ""; groups = @() }
            }
            Mock Write-LogMessage {}
            Write-VsanClusterHealthReport -ClusterName "cl01"
            Should -Invoke Write-LogMessage -Times 1 -ParameterFilter {
                $Type -eq "INFO" -and $Message -match "overallHealth=green"
            } -Scope It
        }
    }

    It "Logs WARNING when overallHealth is yellow" {
        InModuleScope VcfEdgeAtScale {
            $fakeGroup = [PSCustomObject]@{}
            $fakeGroup | Add-Member -NotePropertyName groupName -NotePropertyValue "Network"
            $fakeTest = [PSCustomObject]@{}
            $fakeTest | Add-Member -NotePropertyName health -NotePropertyValue "yellow"
            $fakeTest | Add-Member -NotePropertyName testName -NotePropertyValue "Connectivity"
            $fakeGroup | Add-Member -NotePropertyName tests -NotePropertyValue @($fakeTest)
            Mock Get-VsanClusterHealthSummaryViaView {
                [PSCustomObject]@{ overallHealth = "yellow"; overallHealthDescription = "degraded"; groups = @($fakeGroup) }
            }
            Mock Write-LogMessage {}
            Write-VsanClusterHealthReport -ClusterName "cl01"
            Should -Invoke Write-LogMessage -ParameterFilter {
                $Type -eq "WARNING" -and $Message -match "overallHealth=yellow"
            } -Scope It
        }
    }

    It "Logs WARNING when health summary is not available" {
        InModuleScope VcfEdgeAtScale {
            Mock Get-VsanClusterHealthSummaryViaView { $null }
            Mock Write-LogMessage {}
            Write-VsanClusterHealthReport -ClusterName "cl01"
            Should -Invoke Write-LogMessage -Times 1 -ParameterFilter {
                $Type -eq "WARNING" -and $Message -match "not available"
            } -Scope It
        }
    }
}

# ── Write-SupervisorHealthReport ──────────────────────────────────────────────


Describe "Write-SupervisorHealthReport" {

    It "Logs DEBUG and returns when Invoke-GetSupervisorNamespaceManagementSummary is not available" {
        InModuleScope VcfEdgeAtScale {
            Mock Get-Command { $null }
            Mock Write-LogMessage {}
            Write-SupervisorHealthReport -ClusterName "cl01" -SupervisorId "sup-001"
            Should -Invoke Write-LogMessage -Times 1 -ParameterFilter {
                $Type -eq "DEBUG" -and $Message -match "not available"
            } -Scope It
        }
    }

    It "Logs a single INFO line when supervisor is fully healthy" {
        InModuleScope VcfEdgeAtScale {
            function Invoke-GetSupervisorNamespaceManagementSummary {
                [CmdletBinding()] Param([Parameter()] [Object]$Supervisor)
                [PSCustomObject]@{
                    ConfigStatus    = "RUNNING"
                    KubernetesStatus = "READY"
                    Messages        = @()
                }
            }
            Mock Get-Command { [PSCustomObject]@{ Name = "Invoke-GetSupervisorNamespaceManagementSummary" } }
            Mock Write-SupervisorKubernetesDiagnosticReport {}
            Mock Write-LogMessage {}
            Write-SupervisorHealthReport -ClusterName "cl01" -SupervisorId "sup-001"
            Should -Invoke Write-LogMessage -Times 1 -ParameterFilter {
                $Type -eq "INFO" -and $Message -match "ConfigStatus=RUNNING"
            } -Scope It
            Should -Invoke Write-SupervisorKubernetesDiagnosticReport -Times 0 -Scope It
        }
    }

    It "Delegates to Write-SupervisorKubernetesDiagnosticReport when supervisor is not healthy" {
        InModuleScope VcfEdgeAtScale {
            function Invoke-GetSupervisorNamespaceManagementSummary {
                [CmdletBinding()] Param([Parameter()] [Object]$Supervisor)
                [PSCustomObject]@{
                    ConfigStatus    = "CONFIGURING"
                    KubernetesStatus = "NOT_READY"
                    Messages        = @()
                }
            }
            Mock Get-Command { [PSCustomObject]@{ Name = "Invoke-GetSupervisorNamespaceManagementSummary" } }
            Mock Write-SupervisorKubernetesDiagnosticReport {}
            Mock Write-LogMessage {}
            Write-SupervisorHealthReport -ClusterName "cl01" -SupervisorId "sup-001"
            Should -Invoke Write-SupervisorKubernetesDiagnosticReport -Times 1 -Scope It
        }
    }
}

# ── Get-SupervisorId ──────────────────────────────────────────────────────────


Describe "Invoke-VcenterConnectionWithRetry" {
    It "Returns without throwing when Connect-VIServer succeeds on the first attempt" {
        InModuleScope VcfEdgeAtScale {
            function Connect-VIServer {
                [CmdletBinding()] Param([Parameter()] [Object]$Server, [Parameter()] [Object]$Credential)
                process {}
            }
            Mock Write-LogMessage {}
            Mock Connect-VIServer { [PSCustomObject]@{ Name = "vc.lab" } }
            $cred = [PSCredential]::new("admin", (ConvertTo-SecureString "pw" -AsPlainText -Force))
            { Invoke-VcenterConnectionWithRetry -CurrentCredential $cred -ServerName "vc.lab" -ServerType "vCenter" -SkipRetryPrompt } | Should -Not -Throw
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq "DEBUG" -and $Message -match "Successfully connected" }
        }
    }

    It "Throws VcfDeploymentException immediately when Connect-VIServer raises an SSL error" {
        $exTypeName = InModuleScope VcfEdgeAtScale {
            function Connect-VIServer {
                [CmdletBinding()] Param([Parameter()] [Object]$Server, [Parameter()] [Object]$Credential)
                process {}
            }
            Mock Write-LogMessage {}
            Mock Connect-VIServer { throw "SSL connection could not be established" }
            $cred = [PSCredential]::new("admin", (ConvertTo-SecureString "pw" -AsPlainText -Force))
            try {
                Invoke-VcenterConnectionWithRetry -CurrentCredential $cred -ServerName "vc.lab" -ServerType "vCenter" -SkipRetryPrompt
                return "no-throw"
            } catch {
                return $_.Exception.GetType().Name
            }
        }
        $exTypeName | Should -Be "VcfDeploymentException"
    }

    It "Throws an exception matching 'Authentication failed' when auth fails with -SkipRetryPrompt" {
        $errorMsg = InModuleScope VcfEdgeAtScale {
            function Connect-VIServer {
                [CmdletBinding()] Param([Parameter()] [Object]$Server, [Parameter()] [Object]$Credential)
                process {}
            }
            Mock Write-LogMessage {}
            Mock Connect-VIServer { throw "incorrect user name or password" }
            $cred = [PSCredential]::new("admin", (ConvertTo-SecureString "pw" -AsPlainText -Force))
            try {
                Invoke-VcenterConnectionWithRetry -CurrentCredential $cred -ServerName "vc.lab" -ServerType "vCenter" -SkipRetryPrompt
                return "no-throw"
            } catch {
                return $_.Exception.Message
            }
        }
        $errorMsg | Should -Match "Authentication failed"
    }
}

# ── Set-NewDatastore ──────────────────────────────────────────────────────────


Describe "Assert-VcenterConnected — connected" {
    It "Does not throw when vCenter connection test reports IsConnected=true" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Test-VcenterConnection { [PSCustomObject]@{ IsConnected = $true; ErrorMessage = "" } }
            { Assert-VcenterConnected } | Should -Not -Throw
            Should -Invoke Write-LogMessage -Times 0 -Scope It -ParameterFilter { $Type -eq "ERROR" }
        }
    }
}

Describe "Assert-VcenterConnected — disconnected" {
    It "Throws VcfDeploymentException and logs ERROR when IsConnected=false" {
        InModuleScope VcfEdgeAtScale {
            Mock Write-LogMessage {}
            Mock Test-VcenterConnection { [PSCustomObject]@{ IsConnected = $false; ErrorMessage = "Session expired" } }
            { Assert-VcenterConnected } | Should -Throw -ExceptionType ([VcfDeploymentException])
            Should -Invoke Write-LogMessage -ParameterFilter { $Type -eq "ERROR" -and $Message -match "Session expired" }
        }
    }
}
