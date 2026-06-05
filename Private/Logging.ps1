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
#region Private — logging, vCenter connectivity, content library, witness prep
function Initialize-ScriptVcfPowerCliModuleVersion {

    <#
        .SYNOPSIS
        Validates installed VCF.PowerCLI against a minimum version and caches the resolved version on the script scope.

        .DESCRIPTION
        Resolves the newest installed VCF.PowerCLI module from Get-Module -ListAvailable (or from a pre-resolved module
        object when provided), compares it to MinimumVcfPowerCliVersion, assigns Script:VcfPowerCliModuleVersion on
        success, and throws on failure. Used by Get-EnvironmentSetup and at the start of each deployment run so the
        requirement is enforced even when the daily log file already exists.

        .PARAMETER MinimumVcfPowerCliVersion
        Minimum acceptable VCF.PowerCLI version (default 9.0.0).

        .PARAMETER PreResolvedModule
        Optional. A module object already retrieved by the caller (e.g. from a combined Get-Module -ListAvailable scan).
        When provided the function skips the filesystem scan and validates against this object directly.

        .EXAMPLE
        Initialize-ScriptVcfPowerCliModuleVersion -MinimumVcfPowerCliVersion "9.0.0"

        .EXAMPLE
        $mod = Get-Module -ListAvailable -Name "VCF.PowerCLI" | Sort-Object { [Version]$_.Version } -Descending | Select-Object -First 1
        Initialize-ScriptVcfPowerCliModuleVersion -PreResolvedModule $mod

        .OUTPUTS
        None. Sets Script:VcfPowerCliModuleVersion on success.

        .NOTES
        Throws with an explicit message so CI consoles and catch blocks show the root cause without opening the log file.
        Write-LogMessage still records ERROR for log correlation when Script:LogFile is initialized.
        Side effect: sets $Script:VcfPowerCliModuleVersion on success.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $false)] [Version]$MinimumVcfPowerCliVersion = "9.0.0",
        [Parameter(Mandatory = $false)] [AllowNull()] [System.Management.Automation.PSModuleInfo]$PreResolvedModule = $null
    )

    $vcfModuleLatest = if ($null -ne $PreResolvedModule) {
        $PreResolvedModule
    } else {
        Get-Module -ListAvailable -Name "VCF.PowerCLI" -ErrorAction SilentlyContinue | Sort-Object { [Version]$_.Version } -Descending | Select-Object -First 1
    }

    if ($null -eq $vcfModuleLatest) {
        $errorDetail = "VCF.PowerCLI is not installed. Install VCF.PowerCLI $($MinimumVcfPowerCliVersion) or later."
        Write-LogMessage -Type ERROR -Message $errorDetail
        throw [VcfDeploymentException]::new("$errorDetail See log file for full deployment context if logging is enabled.")
    }

    $vcfPowerCliRelease = $vcfModuleLatest.Version
    if ([Version]$vcfPowerCliRelease -lt $MinimumVcfPowerCliVersion) {
        $errorDetail = "VCF.PowerCLI version $vcfPowerCliRelease is below the minimum required $MinimumVcfPowerCliVersion. Upgrade VCF PowerCLI and retry."
        Write-LogMessage -Type ERROR -Message $errorDetail
        throw [VcfDeploymentException]::new("$errorDetail See log file for full deployment context if logging is enabled.")
    }

    $Script:VcfPowerCliModuleVersion = [Version]$vcfPowerCliRelease
}
function Get-VcfSdkInitializeCommand {

    <#
        .SYNOPSIS
        Returns the first available Initialize-* cmdlet from an ordered list of candidate names.

        .DESCRIPTION
        VCF PowerCLI 9.0 and 9.1 may expose the same vSphere Automation models under either NamespaceManagement-prefixed
        or VcenterNamespaceManagement-prefixed Initialize cmdlets. Callers use the returned CommandInfo with the call operator
        to build request bodies in a release-agnostic way.

        .PARAMETER NameCandidates
        Ordered list of cmdlet names to try (first match wins).

        .EXAMPLE
        $cmd = Get-VcfSdkInitializeCommand -NameCandidates @("Initialize-NamespaceManagementSoftwareClustersUpgradeSpec", "Initialize-VcenterNamespaceManagementSoftwareClustersUpgradeSpec")

        .OUTPUTS
        System.Management.Automation.CommandInfo, or $null if no candidate exists in the current session.
    #>

    [CmdletBinding()]
    [OutputType([Object])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String[]]$NameCandidates
    )

    foreach ($candidateName in $NameCandidates) {
        if ([String]::IsNullOrWhiteSpace($candidateName)) {
            continue
        }

        $commandInfo = Get-Command -Name $candidateName -ErrorAction SilentlyContinue
        if ($null -ne $commandInfo) {
            return $commandInfo
        }
    }

    return $null
}
function Test-VcfPowerCliVersionAtLeast {

    <#
        .SYNOPSIS
        Returns whether the cached VCF.PowerCLI version is greater than or equal to a minimum version.

        .DESCRIPTION
        Uses Script:VcfPowerCliModuleVersion set by Initialize-ScriptVcfPowerCliModuleVersion. Returns $false if the cache is unset
        (callers should run initialization before relying on this for branching).

        .PARAMETER MinimumVersion
        Minimum version to compare (inclusive).

        .EXAMPLE
        if (Test-VcfPowerCliVersionAtLeast -MinimumVersion "9.1.0") { ... }

        .OUTPUTS
        Boolean
    #>

    [CmdletBinding()]
    [OutputType([Bool])]
    Param (
        [Parameter(Mandatory = $true)] [Version]$MinimumVersion
    )

    if ($null -eq $Script:VcfPowerCliModuleVersion) {
        return $false
    }

    return ($Script:VcfPowerCliModuleVersion -ge $MinimumVersion)
}
function ConvertFrom-SecureStringViaBstr {

    <#
        .SYNOPSIS
        Converts a SecureString to a plain-text string using BSTR marshalling, then zeros the BSTR immediately.

        .DESCRIPTION
        Allocates a BSTR via Marshal.SecureStringToBSTR, reads the plain text, and guarantees
        Marshal.ZeroFreeBSTR in a finally block so the plain-text window on the heap is as short as
        possible. Intended only for immediate use (e.g. building a Basic auth header) — never store
        the return value in a variable that outlives a single statement.

        .PARAMETER SecureString
        The SecureString to convert.

        .OUTPUTS
        String — the plain-text value of the SecureString.

        .EXAMPLE
        $plain = ConvertFrom-SecureStringViaBstr -SecureString $credential.Password
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [SecureString]$SecureString
    )

    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    try {
        return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    } finally {
        if ($bstr -ne [IntPtr]::Zero) {
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    }
}
function Get-VcenterRestApiPlainPassword {

    <#
        .SYNOPSIS
        Resolves the password string for vCenter REST Basic authentication from optional SecureString, PSCredential, or string inputs.

        .DESCRIPTION
        Priority order: VcenterPassword (SecureString) > VcenterCredential (PSCredential) > VcenterInsecurePassword (String).
        The returned value is intended for immediate Basic auth encoding only and is not written to the log.
        Uses ConvertFrom-SecureStringViaBstr so the plain text exists only on the stack for the duration of this call.

        .PARAMETER VcenterCredential
        Optional PSCredential; password is extracted via BSTR and zeroed immediately after use.

        .PARAMETER VcenterInsecurePassword
        Optional password as a plain string (legacy fallback — avoid in new call sites).

        .PARAMETER VcenterPassword
        Optional password as SecureString.

        .OUTPUTS
        String, or $null if no source yields a non-empty password.

        .NOTES
        Uses ConvertFrom-SecureStringViaBstr (SecureStringToBSTR / PtrToStringBSTR / ZeroFreeBSTR) for the
        SecureString and PSCredential paths.

        .EXAMPLE
        $vcenterRestApiPlainPassword = Get-VcenterRestApiPlainPassword
        if ($null -eq $vcenterRestApiPlainPassword) {
            Write-LogMessage -Type ERROR -Message "Get-VcenterRestApiPlainPassword: result not found."
        }
    #>

    [CmdletBinding()]
    [OutputType([String])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingUsernameAndPasswordParams', '')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('UsePSCredentialType', '')]
    Param (
        [Parameter(Mandatory = $false)] [PSCredential]$VcenterCredential,
        [Parameter(Mandatory = $false)] [AllowEmptyString()] [String]$VcenterInsecurePassword,
        [Parameter(Mandatory = $false)] [SecureString]$VcenterPassword
    )

    if ($null -ne $VcenterPassword) {
        return ConvertFrom-SecureStringViaBstr -SecureString $VcenterPassword
    }

    if ($null -ne $VcenterCredential) {
        return ConvertFrom-SecureStringViaBstr -SecureString $VcenterCredential.Password
    }

    if (-not [String]::IsNullOrWhiteSpace($VcenterInsecurePassword)) {
        return $VcenterInsecurePassword
    }

    return $null
}
function ConvertTo-SecureStringForCredential {

    <#
        .SYNOPSIS
        Builds a SecureString from a plain-text string for PSCredential construction.

        .DESCRIPTION
        Wraps ConvertTo-SecureString -AsPlainText -Force so callers do not need to suppress
        PSAvoidUsingConvertToSecureStringWithPlainText at every call site. The suppression
        is intentional — this is the designated conversion point for environment-variable
        credentials.

        .PARAMETER PlainText
        The plain-text string to convert. Empty string is permitted (PSCredential allows blank passwords).

        .OUTPUTS
        SecureString

        .EXAMPLE
        # Use an environment variable so the plain text never appears in script source.
        $securePassword = ConvertTo-SecureStringForCredential -PlainText $env:VCENTER_PASSWORD
        $vcenterCredential = New-Object System.Management.Automation.PSCredential("administrator@vsphere.local", $securePassword)
    #>

    [CmdletBinding()]
    [OutputType([SecureString])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '')]
    Param (
        [Parameter(Mandatory = $true)] [AllowEmptyString()] [String]$PlainText
    )

    return ConvertTo-SecureString -String $PlainText -AsPlainText -Force
}
function Set-ScriptVcenterCredential {

    <#
        .SYNOPSIS
        Stores the vCenter PSCredential in script scope for use by REST API callers.

        .DESCRIPTION
        Stores the PSCredential object in $Script:VcenterCredential. REST API callers (Get-SupervisorId, etc.)
        extract the plain password on demand via Get-VcenterRestApiPlainPassword, which uses BSTR extraction
        and zeroes the memory immediately after use. This avoids holding a plain-text password in script scope.

        .PARAMETER Credential
        vCenter PSCredential to store.
    
        .EXAMPLE
        $securePwd = ConvertTo-SecureStringForCredential -PlainText $env:VCENTER_PASSWORD
        Set-ScriptVcenterCredential -Credential (
            New-Object System.Management.Automation.PSCredential("administrator@vsphere.local", $securePwd)
        )
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSCredential]$Credential
    )

    $Script:VcenterCredential = $Credential
}
function Test-LogLevel {

    <#
        .SYNOPSIS
        Determines if a message should be displayed based on the configured log level.

        .DESCRIPTION
        Compares the message type against the configured log level threshold to determine
        if the message should be displayed on screen. All messages are always written to
        the log file regardless of level.

        The log level hierarchy from lowest to highest is:
        DEBUG < INFO < ADVISORY < WARNING < EXCEPTION < ERROR

        .PARAMETER ConfiguredLevel
        The minimum log level configured for screen output.

        .PARAMETER MessageType
        The type/severity of the log message to check.

        .EXAMPLE
        Test-LogLevel -ConfiguredLevel "INFO" -MessageType "DEBUG"
        Returns $false because DEBUG is below INFO threshold.

        .EXAMPLE
        Test-LogLevel -ConfiguredLevel "INFO" -MessageType "ERROR"
        Returns $true because ERROR is at or above INFO threshold.

        .OUTPUTS
        Boolean
        Returns $true if the message should be displayed, $false otherwise.
    #>

    [CmdletBinding()]
    [OutputType([Bool])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateSet("DEBUG", "INFO", "ADVISORY", "WARNING", "EXCEPTION", "ERROR")] [String]$ConfiguredLevel,
        [Parameter(Mandatory = $true)] [ValidateSet("DEBUG", "INFO", "ADVISORY", "WARNING", "EXCEPTION", "ERROR")] [String]$MessageType
    )

    $messageLevel = $Script:LogLevelHierarchy[$MessageType]
    $configuredLevelValue = $Script:LogLevelHierarchy[$ConfiguredLevel]

    return ($messageLevel -ge $configuredLevelValue)
}
function Write-ErrorAndReturn {

    <#
        .SYNOPSIS
        Writes an error message and returns a standardized error result.

        .DESCRIPTION
        This function provides a standardized way to handle errors by logging the error
        message and returning a consistent error result object. This replaces the need
        for throw statements and provides better error handling consistency.

        USAGE GUIDELINES:
        - Use in Helper/Validation/Utility functions (not main workflow functions)
        - Allows caller to decide how to handle the error (propagate, retry, or exit)
        - Always check the returned Success property in the caller

        Error Handling Pattern:
        1. Helper function calls Write-ErrorAndReturn to return structured error
        2. Caller checks $result.Success
        3. Caller decides: propagate error, retry operation, or exit script

        .PARAMETER ErrorCode
        Optional error code for categorization. Defaults to "ERR_UNKNOWN".

        .PARAMETER ErrorMessage
        The error message to log and include in the result.

        Error Code Categories:
        - ERR_NOT_CONNECTED, ERR_TIMEOUT: Connection issues
        - ERR_VERSION_*: Version validation failures
        - ERR_VDS_*, ERR_PORTGROUP_*, ERR_NIC_CONFIG: Network configuration errors
        - ERR_VCF_CONTEXT: VCF context switching failures
        - ERR_KUBECTL_*: Kubernetes command failures
        - ERR_ARGOCD_*: ArgoCD deployment errors
        - ERR_YAML_PARSE: YAML parsing failures
        - ERR_VALIDATION: General validation failures

        .EXAMPLE
        # Helper function returns error object.
        Function Add-HostToVDS {
            try {
                # ... configuration ...
            } catch {
                return Write-ErrorAndReturn -ErrorCode "ERR_VDS_ADD_HOST" -ErrorMessage "Failed to add host to VDS"
            }
        }

        .EXAMPLE
        # Caller checks result and decides how to handle.
        $result = Add-HostToVDS -Hostname $esxHost -VdsName $vdsName
        if (-not $result.Success) {
            $err = "VDS configuration failed: $($result.ErrorMessage)."
            Write-LogMessage -Type ERROR -Message $err
            throw [VcfDeploymentException]::new($err)
        }

        .OUTPUTS
        PSCustomObject
        Returns an object with Success=$false, ErrorMessage, and ErrorCode properties.

        .NOTES
        Error Handling: This is a utility function used by other functions to return
        standardized error objects. Do NOT use 'exit 1' in helper functions; use this
        function instead to allow the caller to control error handling.
    #>

    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    Param (
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$ErrorCode = "ERR_UNKNOWN",
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ErrorMessage
    )

    Write-LogMessage -Type ERROR -Message $ErrorMessage

    return [PSCustomObject]@{
        Success = $false
        ErrorMessage = $ErrorMessage
        ErrorCode = $ErrorCode
    }
}
function Get-CleanErrorMessage {

    <#
        .SYNOPSIS
        Extracts clean error messages from JSON error responses.

        .DESCRIPTION
        The Get-CleanErrorMessage function attempts to extract localized or default error
        messages from JSON-formatted error responses. This function standardizes error message
        extraction throughout the module, eliminating code duplication and ensuring consistent
        error message handling.

        The function checks for error messages in the following priority order:
        1. "localized" field - User-friendly localized error message
        2. "default_message" field - Default error message
        3. Original error message - Falls back to the input if no clean message is found

        This function is used throughout the module to extract clean, user-friendly error
        messages from API responses that may contain JSON-formatted error details.

        .PARAMETER ErrorMessage
        The raw error message that may contain JSON-formatted error details. This can be
        a plain string or a JSON string containing error information.

        .EXAMPLE
        $cleanError = Get-CleanErrorMessage -ErrorMessage $_.Exception.Message
        Write-LogMessage -Type ERROR -Message "Operation failed: $cleanError."

        Extracts a clean error message from an exception and logs it.

        .EXAMPLE
        $cleanMessage = Get-CleanErrorMessage -ErrorMessage $errorResponse
        if ($cleanMessage) {
            Write-LogMessage -Type ERROR -Message "Error: $cleanMessage"
        }

        Extracts a clean error message from an API response for display to the user.

        .OUTPUTS
        System.String
        Returns the cleanest available error message. If no clean message is found in the
        JSON response, returns the original error message unchanged.

        .NOTES
        This function uses regex pattern matching to extract error messages from JSON strings.
        The patterns match common JSON error response formats used by vCenter and VCF APIs.

        Error Message Priority:
        - "localized" field is preferred as it provides user-friendly messages
        - "default_message" field is used if "localized" is not available
        - Original message is returned if neither field is found
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ErrorMessage
    )

    switch -Regex ($ErrorMessage) {
        '"localized":"([^"]+)"' {
            return $matches[1]
        }
        '"default_message":"([^"]+)"' {
            return $matches[1]
        }
        default {
            return $ErrorMessage
        }
    }
}
function Get-CleanServiceErrorMessage {

    <#
        .SYNOPSIS
        Extracts clean, readable error messages from verbose service error responses.

        .DESCRIPTION
        The Get-CleanServiceErrorMessage function extracts essential error information from
        verbose service error messages that contain duplicate information, technical details,
        and verbose formatting. This function identifies the core error reason and message
        while removing redundant information.

        The function extracts:
        1. The error Reason (e.g., "ReconcileFailed")
        2. The actual error Message (e.g., kapp deployment errors)
        3. Removes duplicate messages, Args, Params, Localized fields, and other technical details

        .PARAMETER ErrorMessage
        The raw error message string that may contain verbose service error details with
        duplicate information and technical metadata.

        .EXAMPLE
        $cleanError = Get-CleanServiceErrorMessage -ErrorMessage $serviceOutput.Messages
        Write-LogMessage -Type ERROR -Message "Error details: $cleanError."

        Extracts a clean error message from service output for user-friendly logging.

        .OUTPUTS
        System.String
        Returns a clean, readable error message with essential information only.
        If the message format is not recognized, returns the original message.
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ErrorMessage
    )

    # Extract Reason if present (e.g., "Reason: ReconcileFailed").
    $reason = $null
    if ($ErrorMessage -match 'Reason:\s*([^.,]+)') {
        $reason = $matches[1].Trim()
    }

    # Extract the actual error message. First matching pattern wins (order matters).
    $actualMessage = $null
    switch -Regex ($ErrorMessage) {
        'namespaces\s+"([^"]+)"\s+not found' {
            $actualMessage = "Namespace `"$($Matches[1])`" does not exist"
            break
        }
        'API server says:\s*([^\.]+)' {
            $actualMessage = $Matches[1].Trim() -replace '\s*\(reason:\s*[^)]+\)', '' -replace '\s+', ' '
            break
        }
        'kapp: Error: ([^\.]+(?:\([^)]+\))?[^\.]*?)(?:\.|$)' {
            $actualMessage = $Matches[1].Trim() -replace '\s+', ' '
            break
        }
        'Message:\s*([^,]+(?:\([^)]+\))?[^,]*?)(?:\.|,|$)' {
            $actualMessage = $Matches[1].Trim() -replace '\s+', ' '
            break
        }
        'DefaultMessage:\s*([^,]+)' {
            $actualMessage = $Matches[1].Trim() -replace '\s+', ' '
            break
        }
    }

    # Remove duplicate phrases (2+ chars) if the same text appears multiple times.
    # Word boundaries prevent mid-word collapsing (e.g. "processing" is not reduced because
    # the repeat would not align to a word boundary on both ends).
    if ($actualMessage) {
        $actualMessage = $actualMessage -replace '\b(.{2,}?)\1+\b', '$1'
    }

    $cleanParts = [System.Collections.Generic.List[String]]::new()
    if ($reason) {
        $null = $cleanParts.Add("Reason: $reason")
    }
    if ($actualMessage) {
        $null = $cleanParts.Add($actualMessage)
    }

    if ($cleanParts.Count -gt 0) {
        return $cleanParts -join '. '
    }

    # Fallback: extract essential parts by removing verbose VCF error fields (Args, Params, etc.)
    $cleaned = $ErrorMessage
    $cleaned = $cleaned -replace 'Args:\s*[^,]+', ''
    $cleaned = $cleaned -replace 'Params:\s*[^,]+', ''
    $cleaned = $cleaned -replace 'Localized:\s*[^,]+', ''
    $cleaned = $cleaned -replace 'Severity:\s*[^,]+', ''
    $cleaned = $cleaned -replace 'Id:\s*[^,]+', ''
    $cleaned = $cleaned -replace 'DefaultMessage:\s*[^,]+', ''
    # Remove duplicate phrases (2+ chars). Word boundaries prevent mid-word collapsing.
    $cleaned = $cleaned -replace '\b(.{2,}?)\1+\b', '$1'
    # Clean up extra whitespace and punctuation.
    $cleaned = $cleaned -replace '\s+', ' '
    $cleaned = $cleaned -replace '\.\.+', '.'
    $cleaned = $cleaned.Trim()

    if ($cleaned.Length -gt 0) {
        return $cleaned
    }

    # Final fallback: return original message.
    return $ErrorMessage
}
function Get-PythonExecutable {

    <#
        .SYNOPSIS
        Returns the name of the first Python executable found on PATH.

        .DESCRIPTION
        Tries platform-preferred Python executable names in order and returns the first one
        that responds successfully to --version. On Windows the preferred names are "python",
        "py" (Windows Launcher), and "python3" as a fallback. On non-Windows "python3" is
        tried first, then "python" (which may be Python 2 on some systems).

        Returns an empty string when no Python executable is found.

        .OUTPUTS
        [PSCustomObject] Object with Executable ([String]) and Version ([String]) properties,
        or $null when no Python executable is found on PATH.

        .EXAMPLE
        $py = Get-PythonExecutable
        if ($py) {
            Write-Host "Using $($py.Executable) ($($py.Version))"
            & $py.Executable script.py
        }
    #>

    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    Param ()

    $candidates = if ($IsWindows) { @("python", "py", "python3") } else { @("python3", "python") }
    foreach ($candidate in $candidates) {
        try {
            $rawOutput = & $candidate --version 2>&1
            if ($LASTEXITCODE -eq 0 -and $rawOutput) {
                $versionLine = ($rawOutput | Where-Object { $_ -is [String] } | Select-Object -First 1).Trim()
                if (-not [String]::IsNullOrWhiteSpace($versionLine)) {
                    return [PSCustomObject]@{ Executable = $candidate; Version = $versionLine }
                }
            }
        } catch {
            continue
        }
    }
    return $null
}
function Get-VcfEdgeAtScaleInstallSource {

    <#
        .SYNOPSIS
        Resolves the install source of the VcfEdgeAtScale module as a human-readable string.

        .DESCRIPTION
        Queries PowerShellGet (Get-InstalledModule) as the authoritative source for gallery
        installs. If no PowerShellGet record exists for the given version, falls back to
        Get-Module to locate the module path and reports it as a local path install. Returns
        "N/A (manifest unreadable)" immediately when ModuleVersion is "unknown", surfacing
        .psd1 read failures without silently producing a misleading fallback.

        .PARAMETER ModuleVersion
        The module version string to look up (e.g. "1.0.3.1009"). Used to match the exact
        installed version rather than the latest.

        .OUTPUTS
        System.String
        A descriptive install source string such as "PSGallery (v1.0.3.1009)" or
        "Local path (C:\Users\admin\VCFEdgeAtScale\1.0.3.1009)". Returns "N/A" if the
        module cannot be located, or "N/A (manifest unreadable)" when ModuleVersion is
        "unknown" (indicating the .psd1 could not be read at import time).

        .EXAMPLE
        Get-VcfEdgeAtScaleInstallSource -ModuleVersion "1.0.3.1009"
        Returns "PSGallery (v1.0.3.1009)" when installed from the gallery.

        .EXAMPLE
        Get-VcfEdgeAtScaleInstallSource -ModuleVersion "unknown"
        Returns "N/A (manifest unreadable)" without attempting a PSGet lookup.
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ModuleVersion
    )

    # "unknown" means Import-PowerShellDataFile failed at import time; a PSGet lookup would
    # produce a non-terminating error (invalid version format) that is silently swallowed.
    # Surface the real problem rather than silently degrading to "Local path".
    if ($ModuleVersion -eq "unknown") {
        return "N/A (manifest unreadable)"
    }

    try {
        # -ErrorAction SilentlyContinue suppresses non-terminating errors (e.g. version not found).
        # The surrounding try/catch handles terminating errors (e.g. PSGallery unreachable, corrupted
        # PowerShellGet state). Both guards are intentional — Get-InstalledModule can produce either.
        # -AllowPrerelease ensures prerelease-tagged installs are returned when the version matches.
        $installedMod = Get-InstalledModule -Name "VcfEdgeAtScale" -RequiredVersion $ModuleVersion -AllowPrerelease -ErrorAction SilentlyContinue
        if ($null -ne $installedMod -and -not [String]::IsNullOrWhiteSpace($installedMod.Repository)) {
            return "$($installedMod.Repository) (v$($installedMod.Version))"
        }

        # No PowerShellGet record — could be a git-clone install, a corrupted PSGet database,
        # or a private-gallery install without a PSGet record. Label as "Local path" rather than
        # "Manual install" to avoid misleading a support engineer into thinking PSGallery was not used.
        # | Select-Object -First 1 on the loaded-module check ensures ?? null-coalescing always
        # receives a single object or $null, never an empty array (which ?? would not fall through).
        $thisModule = (Get-Module -Name "VcfEdgeAtScale" -ErrorAction SilentlyContinue | Select-Object -First 1) ??
                      (Get-Module -ListAvailable -Name "VcfEdgeAtScale" -ErrorAction SilentlyContinue | Select-Object -First 1)
        if ($null -ne $thisModule) {
            return "Local path ($($thisModule.ModuleBase))"
        }
    } catch {
        Write-LogMessage -Type DEBUG -Message "Could not determine module install location: $($_.Exception.Message)"
    }

    return "N/A"
}
function Get-MacOsVersionInfo {

    <#
    .SYNOPSIS
        Returns a friendly macOS version string using sw_vers, or $null on non-macOS or failure.
    .DESCRIPTION
        Calls sw_vers to retrieve product name and version. Returns a string such as
        "macOS 14.5" when successful, or $null when not on macOS or when sw_vers fails.
    .OUTPUTS
        String, or $null when not on macOS or when sw_vers fails.
    .EXAMPLE
        $macVersion = Get-MacOsVersionInfo
    .NOTES
        Returns $null on any error; the caller falls back to $PSVersionTable.OS.
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param ()

    if (-not $IsMacOS) { return $null }
    try {
        $macOsName = (sw_vers --productName)
        $macOsRelease = (sw_vers --productVersion)
        return "$macOsName $macOsRelease"
    } catch [Exception] {
        Write-LogMessage -Type DEBUG -Message "sw_vers failed; using fallback OS info. $($_.Exception.Message)"
        return $null
    }
}
function Get-WindowsVersionInfo {

    <#
    .SYNOPSIS
        Returns a friendly Windows version string using Get-ComputerInfo, or $null on non-Windows or timeout.
    .DESCRIPTION
        Spawns Get-ComputerInfo in a background job with an 8-second timeout so it never blocks
        the deployment startup path. Returns "<OSName> <OSVersion>" on success, $null otherwise.
    .OUTPUTS
        String, or $null when not on Windows, on timeout, or on any error.
    .EXAMPLE
        $winVersion = Get-WindowsVersionInfo
    .NOTES
        Returns $null on non-Windows, timeout, or any error; caller falls back to $PSVersionTable.OS.
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param ()

    if (-not $IsWindows) { return $null }
    $computerInfoJob = $null
    try {
        $computerInfoJob = Start-Job -ScriptBlock { Get-ComputerInfo -ProgressAction SilentlyContinue | Select-Object OSName, OSVersion }
        $null = Wait-Job -Job $computerInfoJob -Timeout 8
        if ($computerInfoJob.State -eq 'Completed') {
            $info = Receive-Job -Job $computerInfoJob -ErrorAction SilentlyContinue
            if ($info) { return "$($info.OSName) $($info.OSVersion)" }
        } else {
            Write-LogMessage -Type DEBUG -Message "Get-ComputerInfo timed out after 8s; using fallback OS info."
        }
    } catch [Exception] {
        Write-LogMessage -Type DEBUG -Message "Get-ComputerInfo failed; using fallback OS info. $($_.Exception.Message)"
    } finally {
        if ($null -ne $computerInfoJob) { Remove-Job -Job $computerInfoJob -Force -ErrorAction SilentlyContinue }
    }
    return $null
}
function Get-EnvironmentSetup {

    <#
        .SYNOPSIS
        Collects and logs system environment information for troubleshooting purposes.

        .DESCRIPTION
        The Get-EnvironmentSetup function gathers detailed information about the current
        runtime environment including PowerShell version, PowerCLI modules, CLI tools,
        and operating system details. This information is automatically logged to help with
        troubleshooting and support scenarios. The function handles cross-platform differences
        for Windows, macOS, and Linux systems.

        Information collected includes:
        - PowerShell version
        - VCF.PowerCLI module version (must be 9.0.0 or later by default; throws if missing or too old)
        - VMware.PowerCLI module version (if installed)
        - VcfEdgeAtScale module install location (PSGallery vs manual install)
        - kubectl version (if on PATH)
        - VCF CLI (vcf / vcf.exe) version (if on PATH)
        - Python version (python3 / python / py, all tried; errors silently suppressed)
        - Operating system name and version (with platform-specific enhancements)

        .PARAMETER MinimumVcfPowerCliVersion
        Minimum acceptable VCF.PowerCLI version. Default is 9.0.0.

        .EXAMPLE
        Get-EnvironmentSetup
        Collects environment information and logs it to the current log file.

        .EXAMPLE
        Get-EnvironmentSetup -MinimumVcfPowerCliVersion "9.2.0"
        Validates that the newest installed VCF.PowerCLI is at least 9.2.0 before logging environment details.

        .NOTES
        This function is typically called automatically when a new log file is created.
        It uses platform-specific commands (sw_vers on macOS, Get-ComputerInfo on Windows)
        to provide enhanced OS information beyond the basic PowerShell automatic variables.
        All output is suppressed from the console and only written to the log file.
        CLI tool version detection (kubectl, vcf, python) is best-effort and never throws.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $false)] [Version]$MinimumVcfPowerCliVersion = "9.0.0"
    )

    Write-LogMessage -Type DEBUG -Message "Entered Get-EnvironmentSetup function..."

    $powerShellRelease = $($PSVersionTable.PSVersion).ToString()

    # Single filesystem scan for both PowerCLI module names to avoid two sequential directory traversals.
    $powerCliModulesInstalled = Get-Module -ListAvailable -Name @("VCF.PowerCLI", "VMware.PowerCLI") -ErrorAction SilentlyContinue

    # Resolve the highest VCF.PowerCLI from the pre-fetched results and pass it to the shared validator.
    # This keeps validation logic and error messages in one place while avoiding a second filesystem scan.
    $vcfModuleLatestForEnv = $powerCliModulesInstalled | Where-Object Name -eq "VCF.PowerCLI" | Sort-Object { [Version]$_.Version } -Descending | Select-Object -First 1
    Initialize-ScriptVcfPowerCliModuleVersion -MinimumVcfPowerCliVersion $MinimumVcfPowerCliVersion -PreResolvedModule $vcfModuleLatestForEnv
    $vcfPowerCliRelease = $Script:VcfPowerCliModuleVersion.ToString()

    $vmwarePowerCliVersion = ($powerCliModulesInstalled | Where-Object Name -eq "VMware.PowerCLI" | Sort-Object { [Version]$_.Version } -Descending | Select-Object -First 1).Version
    $vmwarePowerCliRelease = if ($null -eq $vmwarePowerCliVersion) { "N/A" } else { $vmwarePowerCliVersion.ToString() }

    $moduleInstallLocation = Get-VcfEdgeAtScaleInstallSource -ModuleVersion $Script:ModuleVersion

    # kubectl version — best-effort; suppressed on any error.
    # --short was deprecated in kubectl 1.25 and removed in 1.28; use plain --client instead.
    $kubectlVersion = "N/A"
    try {
        $kubectlRaw = & $Script:KubectlCmd version --client 2>&1
        if ($LASTEXITCODE -eq 0 -and $kubectlRaw) {
            # Prefer the "Client Version" line when present; fall back to the first string line.
            $clientLine = $kubectlRaw | Where-Object { $_ -is [String] -and $_ -match "Client Version" } | Select-Object -First 1
            $kubectlVersion = if ($clientLine) { $clientLine.Trim() } else { ($kubectlRaw | Where-Object { $_ -is [String] } | Select-Object -First 1).Trim() }
        }
    } catch {
        Write-LogMessage -Type DEBUG -Message "kubectl version check failed: $($_.Exception.Message)"
    }

    # VCF CLI version — best-effort; suppressed on any error.
    # Get-VcfEdgeAtScaleVcfCmd resolves and caches $Script:VcfCmd lazily on first call; deferred from module-load to avoid PATH scan at startup.
    $vcfCliVersion = "N/A"
    try {
        $vcfRaw = & (Get-VcfEdgeAtScaleVcfCmd) version 2>&1
        if ($LASTEXITCODE -eq 0 -and $vcfRaw) {
            $vcfCliVersion = ($vcfRaw | Where-Object { $_ -is [String] } | Select-Object -First 1).Trim()
        }
    } catch {
        Write-LogMessage -Type DEBUG -Message "vcf version check failed: $($_.Exception.Message)"
    }

    # Python version — Get-PythonExecutable detects the executable and captures the version
    # string in a single --version invocation; no second call needed.
    $pythonVersion = "N/A"
    $pyResult = Get-PythonExecutable
    if ($pyResult) {
        $pythonVersion = $pyResult.Version
    }

    $operatingSystem = $($PSVersionTable.OS)
    $macOsVersion = Get-MacOsVersionInfo
    if ($macOsVersion) { $operatingSystem = $macOsVersion }
    $windowsVersion = Get-WindowsVersionInfo
    if ($windowsVersion) { $operatingSystem = $windowsVersion }

    Write-LogMessage -Type DEBUG -Message "Client PowerShell version is $powerShellRelease."
    Write-LogMessage -Type DEBUG -Message "Client VCF.PowerCLI version is $vcfPowerCliRelease."
    Write-LogMessage -Type DEBUG -Message "Client VMware.PowerCLI version is $vmwarePowerCliRelease."
    Write-LogMessage -Type DEBUG -Message "Client VcfEdgeAtScale install source: $moduleInstallLocation."
    Write-LogMessage -Type DEBUG -Message "Client kubectl version: $kubectlVersion."
    Write-LogMessage -Type DEBUG -Message "Client VCF CLI version: $vcfCliVersion."
    Write-LogMessage -Type DEBUG -Message "Client Python version: $pythonVersion."
    Write-LogMessage -Type DEBUG -Message "Client Operating System is $operatingSystem."

}
function New-LogFile {

    <#
        .SYNOPSIS
        Creates a log file with automatic directory structure and environment logging.

        .DESCRIPTION
        The New-LogFile function establishes the logging infrastructure for the VcfEdgeAtScale module by creating
        a daily log file under an optional deployment root, or the user's local application data directory when no root is specified. The function creates
        one log file using the format yyyy-MM-dd, ensuring logs are organized chronologically.
        If the log directory doesn't exist, it will be created automatically. When a new log file
        is created, the function automatically calls Get-EnvironmentSetup to record system
        information for troubleshooting purposes.

        The function sets the following script-scoped variables:
        - $Script:LogFolder: Path to the log directory
        - $Script:LogFile: Full path to the current log file

        .PARAMETER BaseDirectory
        Optional root directory under which the log folder is created (joined with Directory). When omitted, the platform-appropriate user local application data directory is used (e.g. ~/.local/share/VcfEdgeAtScale on macOS/Linux, %LOCALAPPDATA%\VcfEdgeAtScale on Windows).

        .PARAMETER Prefix
        Specifies the prefix for the log file name. The final log file will be named
        "{Prefix}-{yyyy-MM-dd}.log". Default value is "VcfEdgeAtScale".

        .PARAMETER Directory
        Specifies the directory name segment where log files are stored, relative to BaseDirectory when set, otherwise relative to the user local application data directory.
        The directory will be created if it doesn't exist. Default value is "logs".

        .EXAMPLE
        New-LogFile
        Creates a log file under the user's local application data directory: "~/.local/share/VcfEdgeAtScale/logs/VcfEdgeAtScale-2024-01-15.log"

        .EXAMPLE
        New-LogFile -Directory "audit" -Prefix "SecurityAudit"
        Creates a log file: "audit/SecurityAudit-2024-01-15.log"

        .EXAMPLE
        New-LogFile -BaseDirectory "$HOME/VcfEdgeAtScale" -Directory "Logs"
        Creates a log file under the deployment root when $env:VcfEdgeAtScaleRootDirectory is used by Start-VcfEdgeAtScale.

        .NOTES
        This function should be called before any Write-LogMessage calls to ensure the log
        infrastructure is properly initialized. The function throws a terminating error if it
        cannot create the required log directory or log file.
        Side effects: sets $Script:LogFolder, $Script:LogFile, and $Script:NewLogFileCreatedThisSession.
    #>

    [CmdletBinding(SupportsShouldProcess)]
    Param (
        [Parameter(Mandatory = $false)] [AllowEmptyString()] [String]$BaseDirectory,
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$Directory = "logs",
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$Prefix = "VcfEdgeAtScale"
    )

    # Generate timestamp for daily log file naming (yyyy-MM-dd format).
    $fileTimeStamp = Get-Date -Format "yyyy-MM-dd"

    # Default to the user's local application data directory so logs are never written into
    # the module installation folder (which may be read-only and is not a user data location).
    $localAppData = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::LocalApplicationData)
    $logParentPath = Join-Path -Path $localAppData -ChildPath "VcfEdgeAtScale"
    if (-not [String]::IsNullOrWhiteSpace($BaseDirectory)) {
        $logParentPath = $BaseDirectory
    }
    $Script:LogFolder = Join-Path -Path $logParentPath -ChildPath $Directory
    $Script:LogFile = Join-Path -Path $Script:LogFolder -ChildPath "$Prefix-$fileTimeStamp.log"

    if (-not (Test-Path -Path $Script:LogFolder -PathType Container) ) {
        if ($PSCmdlet.ShouldProcess($Script:LogFolder, "Create directory")) {
            Write-Information "LogFolder not found, creating $Script:LogFolder" -InformationAction Continue
            try {
                New-Item -ItemType Directory -Path $Script:LogFolder -ErrorAction Stop | Out-Null
            } catch {
                Write-Information "Failed to create log directory `"$Script:LogFolder`": $($_.Exception.Message)" -InformationAction Continue
                throw [VcfDeploymentException]::new("Failed to create log directory `"$Script:LogFolder`": $($_.Exception.Message)")
            }
        }
    }

    # When creating a new log file, automatically capture environment details for troubleshooting.
    # $Script:NewLogFileCreatedThisSession is reset unconditionally so re-calling New-LogFile on the same day
    # does not re-trigger the daily update check. Under -WhatIf, ShouldProcess returns $false and the flag
    # intentionally stays $false, suppressing the update check in dry-run mode.
    $Script:NewLogFileCreatedThisSession = $false
    if (-not (Test-Path $Script:LogFile)) {
        if ($PSCmdlet.ShouldProcess($Script:LogFile, "Create log file")) {
            try {
                New-Item -Type File -Path $Script:LogFile -ErrorAction Stop | Out-Null
            } catch {
                Write-Information "Failed to create log file `"$Script:LogFile`": $($_.Exception.Message)" -InformationAction Continue
                throw [VcfDeploymentException]::new("Failed to create log file `"$Script:LogFile`": $($_.Exception.Message)")
            }
            Get-EnvironmentSetup

            # Signal that a new log file was created today so the caller can trigger the daily update check.
            $Script:NewLogFileCreatedThisSession = $true
        }
    }
}
function Write-LogEntryToFile {

    <#
        .SYNOPSIS
        Appends a single pre-formatted log line to $Script:LogFile.

        .DESCRIPTION
        Private helper called only by Write-LogMessage to eliminate the three identical
        log-file-write blocks. Silently no-ops when $Script:LogFile is unset or blank.
        Swallows I/O errors via a self-referencing Write-LogMessage call with suppression flags
        so they are recorded without causing recursion or user-visible noise.

        .PARAMETER LogContent
        The fully formatted log line to append (timestamp + type + message already joined).
    
        .EXAMPLE
        Write-LogEntryToFile -LogContent "value"
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [AllowEmptyString()] [String]$LogContent
    )

    if (-not $Script:LogFile -or [String]::IsNullOrWhiteSpace($Script:LogFile)) {
        return
    }
    try {
        $logDir = Split-Path -Path $Script:LogFile -Parent -ErrorAction SilentlyContinue
        if ($logDir -and -not (Test-Path -Path $logDir -ErrorAction SilentlyContinue)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }
        Add-Content -Path $Script:LogFile -Value $LogContent -ErrorAction Stop
    } catch {
        Write-LogMessage -Type DEBUG -Message "Log file write skipped or failed (standalone call). $($_.Exception.Message)" -SuppressOutputToScreen -SuppressOutputToFile
    }
}
function Complete-PendingLogMessage {

    <#
    .SYNOPSIS
        Completes a pending NoNewline log line by appending a suffix and flushing to file and console.
    .DESCRIPTION
        When a prior Write-LogMessage -NoNewline call stored a pending message, this function appends
        Message to form the final line, writes it to the log file, and outputs the suffix to the
        console so the line completes. When no pending message exists, it logs a programming-error
        warning and writes Message as a standalone line.
    .PARAMETER ForceToScreen
        Passed through from the outer Write-LogMessage call.
    .PARAMETER Message
        The suffix to append to the pending message, or the standalone message if no pending.
    .PARAMETER MessageColor
        Pre-computed console color for the current message type.
    .PARAMETER MsgTypeToColor
        Hashtable mapping type strings to console color names.
    .PARAMETER ShouldDisplay
        Whether the current message type meets the configured log-level threshold.
    .PARAMETER SuppressOutputToFile
        When set, skips writing to the log file.
    .PARAMETER SuppressOutputToScreen
        When set, skips console output.
    .PARAMETER TimeStamp
        Pre-formatted timestamp string for use in fallback standalone output.
    .PARAMETER Type
        The message type (INFO, ERROR, etc.) used in the fallback standalone log entry.
    .EXAMPLE
        Complete-PendingLogMessage -ForceToScreen:$false -Message " Done" -MessageColor "Green" -MsgTypeToColor $colors -ShouldDisplay $true -SuppressOutputToFile:$false -SuppressOutputToScreen:$false -TimeStamp $ts -Type INFO
    .NOTES
        Write-Host is the primary output mechanism in this function; all Write-Host calls are
        intentional interactive console output. Use Write-LogMessage for diagnostic logging.
        Called exclusively from Write-LogMessage.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $false)] [Switch]$ForceToScreen,
        [Parameter(Mandatory = $true)] [AllowEmptyString()] [String]$Message,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$MessageColor,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Hashtable]$MsgTypeToColor,
        [Parameter(Mandatory = $true)] [Bool]$ShouldDisplay,
        [Parameter(Mandatory = $false)] [Switch]$SuppressOutputToFile,
        [Parameter(Mandatory = $false)] [Switch]$SuppressOutputToScreen,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$TimeStamp,
        [Parameter(Mandatory = $true)] [ValidateSet("INFO", "ERROR", "WARNING", "EXCEPTION", "ADVISORY", "DEBUG")] [String]$Type
    )

    if ($null -ne $Script:LogMessagePending) {
        $fullMessage = $Script:LogMessagePending + $Message
        $pendingType = $Script:LogMessagePendingType
        $pendingTimestamp = $Script:LogMessagePendingTimestamp
        $pendingColor = $MsgTypeToColor.$pendingType
        $Script:LogMessagePending = $null
        $Script:LogMessagePendingType = $null
        $Script:LogMessagePendingTimestamp = $null
        if (-not $SuppressOutputToScreen -and $Script:LogOnly -ne "enabled" -and ((Test-LogLevel -ConfiguredLevel $Script:ConfiguredLogLevel -MessageType $pendingType) -or $ForceToScreen)) {
            # Write only the suffix; the NoNewline call already wrote the prefix without a newline.
            Write-Host -ForegroundColor $pendingColor $Message
            [Console]::Out.Flush()
        }
        if (-not $SuppressOutputToFile) {
            Write-LogEntryToFile -LogContent "[$pendingTimestamp] ($pendingType) $fullMessage"
        }
    } else {
        # No pending message; -CompletePending called without a prior -NoNewline. Log a programming-error
        # warning, then write $Message as a standalone line so output is not silently lost.
        $truncatedMessage = if ($Message.Length -gt 80) { "$($Message.Substring(0, 80))..." } else { $Message }
        $warningText = "[Write-LogMessage] -CompletePending called with no pending NoNewline message. Suffix written as standalone line: '$truncatedMessage'"
        Write-LogEntryToFile -LogContent "[$TimeStamp] (WARNING) $warningText"
        if (-not $SuppressOutputToScreen -and $Script:LogOnly -ne "enabled" -and ($ShouldDisplay -or $ForceToScreen)) {
            Write-Host -ForegroundColor $MessageColor "[$Type] $Message"
            [Console]::Out.Flush()
        }
        if (-not $SuppressOutputToFile) {
            Write-LogEntryToFile -LogContent "[$TimeStamp] ($Type) $Message"
        }
    }
}
function Write-LogMessage {

    <#
        .SYNOPSIS
        Writes a severity-based color-coded message to the console and/or log file.

        .DESCRIPTION
        The Write-LogMessage function provides centralized logging functionality with support for
        different message types (INFO, ERROR, WARNING, EXCEPTION, ADVISORY, DEBUG). Messages are displayed
        on the console with color coding based on severity and written to a log file with timestamps.
        This function supports flexible output control allowing messages to be suppressed from either
        the console or log file as needed.

        Screen output is filtered based on the configured log level threshold (set via the -logLevel
        script parameter). Only messages at or above the configured level are displayed on screen.
        All messages are always written to the log file regardless of their severity level.

        Log level hierarchy (lowest to highest):
        DEBUG < INFO < ADVISORY < WARNING < EXCEPTION < ERROR

        .PARAMETER Message
        The message content to be logged and/or displayed. Can be an empty string if needed.

        .PARAMETER Type
        The severity level of the message. Valid values are:
        - DEBUG (Gray): Debug information for troubleshooting and development
        - INFO (Green): General information messages
        - ADVISORY (Yellow): Advisory information for user guidance
        - WARNING (Yellow): Warning conditions that may need attention
        - EXCEPTION (Cyan): Exception details and stack traces
        - ERROR (Red): Error conditions that require attention
        Default value is "INFO".

        .PARAMETER ForceToScreen
        When specified, forces the message to be displayed on the console regardless of the configured log level threshold.
        Use this for messages that must always be visible to the operator (e.g. credential display after deployment).
        SuppressOutputToScreen and LogOnly mode still take precedence over this flag.

        .PARAMETER SuppressOutputToScreen
        When specified, prevents the message from being displayed on the console regardless of log level.

        .PARAMETER SuppressOutputToFile
        When specified, prevents the message from being written to the log file.

        .PARAMETER PrependNewLine
        When specified, adds a blank line before displaying the message on the console.
        This parameter has no effect when SuppressOutputToScreen is used or when the message
        is filtered by log level threshold.

        .PARAMETER AppendNewLine
        When specified, adds a blank line after displaying the message on the console.
        This parameter has no effect when SuppressOutputToScreen is used or when the message
        is filtered by log level threshold.

        .PARAMETER NoNewline
        When specified, the message is displayed on the console without a trailing newline, and
        is not written to the log file yet. Use -CompletePending later to append a result (e.g. " Success")
        to the same line and then write one combined line to the log file. Reduces output for
        attempt/success pairs.

        .PARAMETER CompletePending
        When specified, Message is the suffix to append to the previous -NoNewline message. The
        combined line is written to the log file; on console the suffix is output so the line
        completes (e.g. "Attempting... Success"). If no pending message exists, the message is
        written as a normal full line.

        .EXAMPLE
        Write-LogMessage -Type INFO -Message "Process started successfully."
        Displays an informational message in green on the console and writes the message to the log file.

        .EXAMPLE
        Write-LogMessage -Type ERROR -Message "Failed to connect to server." -PrependNewLine
        Displays an error message in red with a blank line before it, and logs it to the file.

        .EXAMPLE
        Write-LogMessage -Type WARNING -Message "Configuration file not found, using defaults." -SuppressOutputToScreen
        Writes a warning message to the log file only, without displaying it on the console.

        .EXAMPLE
        Write-LogMessage -Type ADVISORY -Message "Consider updating your configuration." -SuppressOutputToFile
        Displays an advisory message on the console only, without writing it to the log file.

        .EXAMPLE
        Write-LogMessage -Type DEBUG -Message "Variable value: $myVar = $($myVar)"
        Displays a debug message in gray on the console (only if log level is DEBUG) and writes it to the log file.

        .EXAMPLE
        Write-LogMessage -Type INFO -NoNewline -Message "Attempting to add host..."
        # ... do work ...
        Write-LogMessage -Type INFO -CompletePending -Message " Success"
        Results in one console line and one log line: "Attempting to add host... Success".

        .NOTES
        This function relies on the Script:LogFile, Script:LogOnly, and Script:ConfiguredLogLevel variables being set.
        The log file path should be established using the New-LogFile function before calling this function.
        The Script:ConfiguredLogLevel should be set during script initialization.
        Side effects: -NoNewline sets $Script:LogMessagePending, $Script:LogMessagePendingType, and
        $Script:LogMessagePendingTimestamp; -CompletePending clears them.
        Write-Host is the primary output mechanism in this function; all Write-Host calls are
        intentional interactive console output. Use Write-LogMessage for diagnostic logging.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $false)] [Switch]$AppendNewLine,
        [Parameter(Mandatory = $false)] [Switch]$CompletePending,
        [Parameter(Mandatory = $false)] [Switch]$ForceToScreen,
        [Parameter(Mandatory = $true)] [AllowEmptyString()] [String]$Message,
        [Parameter(Mandatory = $false)] [Switch]$NoNewline,
        [Parameter(Mandatory = $false)] [Switch]$PrependNewLine,
        [Parameter(Mandatory = $false)] [Switch]$SuppressOutputToFile,
        [Parameter(Mandatory = $false)] [Switch]$SuppressOutputToScreen,
        [Parameter(Mandatory = $false)] [ValidateSet("INFO", "ERROR", "WARNING", "EXCEPTION", "ADVISORY", "DEBUG")] [String]$Type = "INFO"
    )

    $msgTypeToColor = @{
        "INFO" = "Green";
        "ERROR" = "Red" ;
        "WARNING" = "Yellow" ;
        "ADVISORY" = "Yellow" ;
        "EXCEPTION" = "Cyan";
        "DEBUG" = "Gray"
    }

    $messageColor = $msgTypeToColor.$Type
    $timeStamp = Get-Date -Format "yyyy-MM-dd_HH:mm:ss"
    $shouldDisplay = Test-LogLevel -ConfiguredLevel $Script:ConfiguredLogLevel -MessageType $Type

    # CompletePending: append Message to the stored NoNewline line and write one combined line to file and console.
    if ($CompletePending) {
        $completePendingParams = @{
            ForceToScreen          = $ForceToScreen
            Message                = $Message
            MessageColor           = $messageColor
            MsgTypeToColor         = $msgTypeToColor
            ShouldDisplay          = $shouldDisplay
            SuppressOutputToFile   = $SuppressOutputToFile
            SuppressOutputToScreen = $SuppressOutputToScreen
            TimeStamp              = $timeStamp
            Type                   = $Type
        }
        Complete-PendingLogMessage @completePendingParams
        return
    }

    # NoNewline: display without newline and store for later CompletePending; do not write to file yet.
    if ($NoNewline) {
        if ($PrependNewLine -and (-not ($Script:LogOnly -eq "enabled")) -and ($shouldDisplay -or $ForceToScreen)) {
            Write-Host ""
        }
        $Script:LogMessagePending = $Message
        $Script:LogMessagePendingType = $Type
        $Script:LogMessagePendingTimestamp = $timeStamp
        try {
            if (-not $SuppressOutputToScreen -and $Script:LogOnly -ne "enabled" -and ($shouldDisplay -or $ForceToScreen)) {
                Write-Host -ForegroundColor $messageColor "[$Type] $Message" -NoNewline
                [Console]::Out.Flush()
            }
            if ($AppendNewLine -and (-not ($Script:LogOnly -eq "enabled")) -and ($shouldDisplay -or $ForceToScreen)) {
                Write-Host ""
            }
        } catch {
            # If console output fails after pending state was set, clear it to prevent a permanently orphaned pending line.
            $Script:LogMessagePending = $null
            $Script:LogMessagePendingType = $null
            $Script:LogMessagePendingTimestamp = $null
        }
        return
    }

    # Add blank line before message if requested and not in log-only mode and meets log level threshold.
    if ($PrependNewLine -and (-not ($Script:LogOnly -eq "enabled")) -and ($shouldDisplay -or $ForceToScreen)) {
        Write-Host ""
    }

    # Display message to console with color coding (unless suppressed, in log-only mode, or below log level threshold).
    # When a NoNewline pending message is active, INFO/DEBUG/ADVISORY are suppressed from the console so the
    # pending line stays clean (e.g. "Creating cluster... Done"). WARNING, ERROR, and EXCEPTION always show
    # on screen immediately — suppressing them would hide actionable failure details from the operator.
    # A bare newline is written before a high-priority message that interrupts a pending line so the dangling
    # prefix is visually complete; $Script:LogMessagePending is preserved so CompletePending still writes the
    # correctly combined line to the log file.
    # This is the designated console output for the logger; do not use Write-Host elsewhere (use Write-LogMessage).
    if (-not $SuppressOutputToScreen -and $Script:LogOnly -ne "enabled" -and ($shouldDisplay -or $ForceToScreen)) {
        if ($null -ne $Script:LogMessagePending -and $Type -notin @('WARNING', 'ERROR', 'EXCEPTION')) {
            # Pending line is active; suppress lower-priority message from screen. It still goes to the log file.
        } else {
            if ($null -ne $Script:LogMessagePending) {
                # A high-priority message interrupts the pending line. Write a bare newline to move the
                # cursor off the dangling prefix before showing the WARNING/ERROR.
                Write-Host ""
            }
            Write-Host -ForegroundColor $messageColor "[$Type] $Message"
            # Flush console output to prevent buffering issues when Write-Progress is active.
            [Console]::Out.Flush()
        }
    }

    # Add blank line after message if requested and not in log-only mode and meets log level threshold.
    if ($AppendNewLine -and (-not ($Script:LogOnly -eq "enabled")) -and ($shouldDisplay -or $ForceToScreen)) {
        Write-Host ""
    }

    if (-not $SuppressOutputToFile) {
        Write-LogEntryToFile -LogContent "[$timeStamp] ($Type) $Message"
    }
}
function Show-Version {

    <#
        .SYNOPSIS
        The function Show-Version shows the version of the script.

        .DESCRIPTION
        The function provides version information.

        .EXAMPLE
        Show-Version

        .EXAMPLE
        Show-Version -Silence

        .PARAMETER Silence
        Specifies the option to not display the output to screen.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $false)] [Switch]$Silence
    )

    Write-LogMessage -Type DEBUG -Message "Entered Show-Version function..."

    if (-not $Silence) {
        Write-LogMessage -Type INFO -Message "Version: $Script:ModuleVersion"
    } else {
        Write-LogMessage -Type DEBUG -Message "Script Version: $Script:ModuleVersion"
    }
}
function Get-RetryCredential {

    <#
        .SYNOPSIS
        Prompts the operator to retry a failed vCenter/ESX connection with a new password.

        .DESCRIPTION
        Asks the operator if they want to re-enter their password (Y/N loop). If Y, prompts for
        the new password and returns a new PSCredential. If N, throws VcfDeploymentException.

        .PARAMETER IsEsx
        When $true, appends "(or press Enter for no password)" to the password prompt and passes
        -AllowEmpty to Get-InteractiveInput.

        .PARAMETER ServerName
        FQDN or IP of the target server, used in the prompt message.

        .PARAMETER ServerType
        "vCenter" or "ESX" — used in the prompt message.

        .PARAMETER Username
        Username to embed in the new PSCredential.

        .EXAMPLE
        $cred = Get-RetryCredential -Username $username -ServerName "vc.lab" -ServerType "vCenter" -IsEsx $false

        .NOTES
        Called by Invoke-VcenterConnectionWithRetry on authentication failure.
    #>

    [CmdletBinding()]
    [OutputType([PSCredential])]
    Param (
        [Parameter(Mandatory = $true)] [Bool]$IsEsx,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ServerName,
        [Parameter(Mandatory = $true)] [ValidateSet("vCenter", "ESX")] [String]$ServerType,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Username
    )

    Write-LogMessage -Type INFO -Message ""
    $retryResponse = $null
    while ($retryResponse -ne "Y" -and $retryResponse -ne "N") {
        $retryResponse = Read-Host "Would you like to re-enter your password? (Y/N)"
        $retryResponse = $retryResponse.Trim().ToUpper()
    }
    if ($retryResponse -eq "N") {
        $err = "User chose not to retry. Exiting."
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }
    Write-LogMessage -Type INFO -Message ""
    $promptMessage = "Enter the password for the user `"$Username`" on $ServerType `"$ServerName`""
    if ($IsEsx) { $promptMessage = "$promptMessage (or press Enter for no password)" }
    $promptMessage = $promptMessage.Trim().TrimEnd(": ")
    $newPassword = Get-InteractiveInput -PromptMessage $promptMessage -AsSecureString -AllowEmpty:$IsEsx
    Write-LogMessage -Type INFO -Message ""
    Write-LogMessage -Type INFO -Message "Retrying connection with new credentials..."
    return New-Object System.Management.Automation.PSCredential($Username, $newPassword)
}
function Invoke-VcenterConnectionWithRetry {

    <#
        .SYNOPSIS
        Attempts to connect to a vCenter or ESX host, retrying once with new credentials when
        authentication fails and the caller allows interactive re-prompting.

        .DESCRIPTION
        Runs the credential retry loop extracted from Connect-Vcenter. Tries the supplied
        credential, then:
        - SSL errors: throws immediately (non-retryable).
        - Auth failures with -SkipRetryPrompt: throws immediately.
        - Auth failures without -SkipRetryPrompt: prompts the user (Y/N). Y re-prompts for
          password and retries; N throws.
        - Generic errors: throws immediately.

        On success, sets $connectionSuccessful to $true and returns. Never returns without
        throwing when all attempts fail.

        .PARAMETER CurrentCredential
        Initial PSCredential to try. May be replaced by a re-prompted credential on retry.

        .PARAMETER ServerName
        FQDN or IP of the target server.

        .PARAMETER ServerType
        "vCenter" or "ESX" — used in log messages and prompt text only.

        .PARAMETER SkipRetryPrompt
        When set, throws immediately on authentication failure without prompting.

        .OUTPUTS
        None. Throws on all failure paths.

        .EXAMPLE
        Invoke-VcenterConnectionWithRetry -CurrentCredential $cred -ServerName "vc.lab" -ServerType "vCenter"
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSCredential]$CurrentCredential,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ServerName,
        [Parameter(Mandatory = $true)] [ValidateSet("vCenter", "ESX")] [String]$ServerType,
        [Parameter(Mandatory = $false)] [Switch]$SkipRetryPrompt
    )

    $connectionSuccessful = $false
    $isEsx = ($ServerType -eq "ESX")

    while (-not $connectionSuccessful) {
        try {
            Write-LogMessage -Type DEBUG -Message "Connecting to $ServerType `"$ServerName`" as user `"$($CurrentCredential.UserName)`"."
            $connectParams = @{
                Server     = $ServerName
                Credential = $CurrentCredential
                ErrorAction = 'Stop'
            }
            $null = Connect-VIServer @connectParams
            $connectionSuccessful = $true
            Write-LogMessage -Type DEBUG -Message "Successfully connected to $ServerType `"$ServerName`"."
        } catch [System.TimeoutException] {
            $err = "Cannot connect to $ServerType Server `"$ServerName`" due to network/timeout issues: $_."
            Write-LogMessage -Type ERROR -Message $err
            throw [VcfDeploymentException]::new($err)
        } catch {
            $errorMessage = $_.Exception.Message

            switch -Regex ($errorMessage) {
                "SSL connection could not be established|SSL|certificate" {
                    $sslHelp = @"
Failed to establish SSL connection to $ServerType `"$ServerName`". Common causes and solutions:
  1. Self-signed or untrusted SSL certificate.
     Solution: Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:`$false
  2. TLS protocol version mismatch.
     Solution: [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  3. Network connectivity or firewall blocking HTTPS (port 443).
     Solution: Test-NetConnection -ComputerName $ServerName -Port 443
Full error details: $errorMessage.
"@
                    Write-LogMessage -Type ERROR -Message $sslHelp.Trim()
                    throw [VcfDeploymentException]::new("SSL connection to $ServerType `"$ServerName`" failed: $errorMessage.")
                }
                "incorrect user name or password|authentication|credentials" {
                    # When the caller owns retry logic, suppress the ERROR so it is not shown twice.
                    if ($SkipRetryPrompt) {
                        Write-LogMessage -Type DEBUG -Message "Failed to connect to $ServerType `"$ServerName`": Authentication failed (caller will handle retry)."
                        Write-LogMessage -Type DEBUG -Message "Full error details: $errorMessage."
                        throw [VcfDeploymentException]::new("Authentication failed")
                    }
                    Write-LogMessage -Type ERROR -Message "Failed to connect to $ServerType `"$ServerName`": Authentication failed."
                    Write-LogMessage -Type DEBUG -Message "Full error details: $errorMessage."

                    $CurrentCredential = Get-RetryCredential `
                        -IsEsx      $isEsx `
                        -ServerName $ServerName `
                        -ServerType $ServerType `
                        -Username   $CurrentCredential.UserName
                }
                default {
                    Write-LogMessage -Type DEBUG -Message "Connection error details: $errorMessage."
                    switch -Regex ($errorMessage) {
                        "Network is unreachable|unreachable\s*\(.*:443\)" {
                            Write-LogMessage -Type ERROR -Message "Cannot connect to $ServerType `"$ServerName`": the host is not reachable on the network. Check that the host is powered on, the IP address or host name is correct, and that port 443 is open."
                            break
                        }
                        "did not properly respond|connection.*failed|timed out|host has failed to respond" {
                            Write-LogMessage -Type ERROR -Message "Cannot connect to $ServerType `"$ServerName`": connection timed out or host did not respond. Check network and firewall (port 443)."
                            break
                        }
                        default {
                            $err = "Failed to connect to $ServerType `"$ServerName`": $errorMessage"
                            Write-LogMessage -Type ERROR -Message $err
                        }
                    }
                    throw [VcfDeploymentException]::new($err)
                }
            }
        }
    }
}
function Connect-Vcenter {

    <#
        .SYNOPSIS
        Establishes a secure connection to vCenter or ESX host instances with unified connection management.

        .DESCRIPTION
        The Connect-Vcenter function creates a secure connection to either vCenter or ESX host
        using PSCredential objects for authentication. It provides unified connection management for both
        server types with intelligent duplicate connection detection and comprehensive error handling.

        The function includes advanced connection state management that checks for existing connections
        and provides detailed information about current sessions, including the connected username.
        It uses SecureString parameters to ensure password security and automatically handles
        connection state validation.

        Key features:
        - Unified connection management for both vCenter and ESX hosts
        - Secure credential handling using PSCredential objects
        - Intelligent duplicate connection detection with existing session details
        - Comprehensive error handling and structured logging
        - Graceful handling of existing connections with detailed user information
        - Connection state validation to prevent duplicate connections

        .PARAMETER ServerName
        The fully qualified domain name (FQDN) or IP address of the server to connect to.
        This can be either a vCenter or an ESX host, depending on the ServerType parameter.
        This parameter is mandatory and must be a valid, reachable server instance.

        .PARAMETER ServerCredential
        A PSCredential object containing the username and password for authentication to the target server.
        This should contain a valid user account with appropriate permissions for the operations being performed.
        For vCenter: Supports both local vCenter accounts and SSO domain accounts (e.g., administrator@vsphere.local).
        For ESX: Typically uses root account or other local ESX user accounts.
        The password is supplied through the credential object's SecureString.

        .PARAMETER ServerType
        Specifies the type of server being connected to. Valid values are "vCenter" or "ESX".
        This parameter determines the connection context and affects logging messages and error handling.
        - "vCenter": Connects to a vCenter instance for centralized management
        - "ESX": Connects directly to an ESX host for host-specific operations

        .EXAMPLE
        $credential = Get-Credential -Message "Enter vCenter credentials"
        Connect-Vcenter -ServerName "vcenter.example.com" -ServerCredential $credential -ServerType "vCenter"

        Connects to a vCenter using credentials obtained from Get-Credential cmdlet.

        .EXAMPLE
        $securePassword = Read-Host "Enter ESX password (or press Enter for no password)" -asSecureString
        $credential = New-Object System.Management.Automation.PSCredential("root", $securePassword)
        Connect-Vcenter -serverName "ESX-host.example.com" -serverCredential $credential -serverType "ESX"

        Connects to an ESX host using a PSCredential object created from secure input.

        .EXAMPLE
        Connect-Vcenter -ServerName $Script:vCenterName -ServerCredential $vCenterCredential -ServerType "vCenter"
        Connect-Vcenter -ServerName $esxHost -ServerCredential $esxCredential -ServerType "ESX"

        Example of connecting to both vCenter and ESX host in sequence using variables.

        .NOTES
        - Requires VMware PowerCLI to be installed and imported before execution
        - The function gracefully handles existing connections and provides detailed information about current sessions
        - Existing connections are detected using $Global:DefaultViServers and the function returns without attempting duplicate connections
        - Connection failures are logged with detailed error information and throw a terminating error
        - The function integrates with the VCF PowerShell Toolbox logging infrastructure for consistent reporting
        - Both server types use the same underlying VMware PowerCLI Connect-VIServer cmdlet
        - Username information is displayed for existing connections when available from the connection context
        - Connection attempts use SuppressOutputToScreen for initial connection messages to reduce console verbosity
        - Successful connections are confirmed with informational messages for audit trail purposes
        - Function is designed for use in deployment scenarios where reliable server connectivity is critical
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [PSCredential]$ServerCredential,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ServerName,
        [Parameter(Mandatory = $true)] [ValidateSet("vCenter", "ESX")] [String]$ServerType,
        [Parameter(Mandatory = $false)] [Switch]$SkipRetryPrompt
    )

    Write-LogMessage -Type DEBUG -Message "Entered Connect-Vcenter function..."

    # Check if we're already connected to this vCenter to avoid duplicate connections.
    $connectedVcenter = $Global:DefaultViServers | Where-Object { $_.Name -eq $ServerName -and $_.IsConnected }

    if (-not $connectedVcenter) {
        Invoke-VcenterConnectionWithRetry `
            -CurrentCredential $ServerCredential `
            -ServerName        $ServerName `
            -ServerType        $ServerType `
            -SkipRetryPrompt:  $SkipRetryPrompt.IsPresent
    } else {
        # Connection already exists. Surface the data on what user the connection is using.
        $existingUsername = ($Global:DefaultVIServers | Where-Object {$_.Name -eq $ServerName }).User
        if ($existingUsername) {
            Write-LogMessage -Type WARNING -Message "Already connected to $ServerType `"$ServerName`" as `"$existingUsername`"."
        } else {
            Write-LogMessage -Type WARNING -Message "Already connected to $ServerType `"$ServerName`"."
        }
    }
}
function Test-VcenterConnection {

    <#
        .SYNOPSIS
        Tests if an active and valid vCenter connection exists with minimal overhead.

        .DESCRIPTION
        This function efficiently validates that:
        1. A PowerCLI session exists to the specified vCenter
        2. The session is marked as connected (IsConnected = $true)
        3. The connection is actually alive (can execute a lightweight API call)

        The function uses a two-phase check:
        - Phase 1: Fast check of $Global:DefaultViServers (cached session state)
        - Phase 2: Lightweight API call (Get-Datacenter -Name '*') to verify connectivity

        This provides minimal overhead while ensuring the connection is truly functional
        before attempting more complex operations that would fail with cryptic errors.

        .PARAMETER ServerName
        The hostname or IP address of the vCenter to test connectivity to.
        If not specified, uses $Script:vCenterName.

        .PARAMETER SkipConnectivityTest
        When specified, only checks if a session exists without making an API call.
        This is faster but doesn't verify the connection is still alive (useful if you
        just want to check session existence, not actual connectivity).

        .OUTPUTS
        System.Management.Automation.PSCustomObject
        Returns an object with the following properties:
        - IsConnected: Boolean indicating if connection exists and is valid
        - ServerName: The server name that was tested
        - SessionAge: Reserved; always $null (session start time is not exposed by VCF PowerCLI 9)
        - ErrorMessage: Error message if connection is invalid (null if connected)

        .EXAMPLE
        # Check connection before critical operation (uses $Script:vCenterName by default).
        Assert-VcenterConnected

        .EXAMPLE
        # Fast check without API call.

        $sessionExists = Test-VcenterConnection -SkipConnectivityTest
        if ($sessionExists.IsConnected) {
            Write-LogMessage -Type DEBUG -SuppressOutputToFile -Message "Session exists for `"$($sessionExists.ServerName)`" (age: $($sessionExists.SessionAge))"
        } else {
            Write-LogMessage -Type WARNING -Message "No active session found for `"$Script:vCenterName`"."
        }

        .EXAMPLE
        # Test specific vCenter.
        $result = Test-VcenterConnection -ServerName $Script:vCenterName
        if ($result.IsConnected) {
            Write-LogMessage -Type INFO -Message "Connection to `"$($result.ServerName)`" is valid."
        }

        .NOTES
        Performance Characteristics:
        - Session check only: <1ms (just checks $Global:DefaultViServers)
        - With connectivity test: ~50-100ms (one lightweight API call)
        - Much faster than retrying failed operations

        Error Handling: This is a validation function. Returns structured result object
        with success/failure information. Does not terminate script execution.

        Use Cases:
        - Before long-running operations to fail fast
        - In loops where connection might time out
        - After network-related errors to determine if reconnection needed
        - In finally blocks to check if cleanup is needed
    #>

    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    Param (
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$ServerName = $Script:vCenterName,
        [Parameter(Mandatory = $false)] [Switch]$SkipConnectivityTest
    )

    Write-LogMessage -Type DEBUG -SuppressOutputToFile -Message "Entered Test-VcenterConnection function..."

    $result = [PSCustomObject]@{
        IsConnected = $false
        ServerName = $ServerName
        SessionAge = $null
        ErrorMessage = $null
    }

    # Phase 1: Check if session exists in PowerCLI session cache.
    try {
        $vcServer = $Global:DefaultViServers | Where-Object {
            $_.Name -eq $ServerName -and $_.IsConnected
        }

        if (-not $vcServer) {
            $result.ErrorMessage = "No active PowerCLI session found for vCenter `"$ServerName`""
            Write-LogMessage -Type DEBUG -SuppressOutputToFile -Message $result.ErrorMessage
            return $result
        }

        Write-LogMessage -Type DEBUG -SuppressOutputToFile -Message "PowerCLI session exists for `"$ServerName`"."

        # If skip connectivity test, return now (session exists).
        if ($SkipConnectivityTest) {
            $result.IsConnected = $true
            return $result
        }

        # Phase 2: Verify connection is actually alive with lightweight API call.

        # Using Get-Datacenter because it's a lightweight operation.
        # - Fast (small response)
        # - Always available (every vCenter has at least one datacenter)
        # - Read-only (no side effects)
        # - Validates authentication and API access
        Write-LogMessage -Type DEBUG -SuppressOutputToFile -Message "Performing connectivity test to `"$ServerName`"..."

        $null = Get-Datacenter -Server $ServerName -ErrorAction Stop | Select-Object -First 1

        $result.IsConnected = $true
        Write-LogMessage -Type DEBUG -SuppressOutputToFile -Message "Connection to `"$ServerName`" is active and valid."
        return $result

    } catch [VMware.VimAutomation.ViCore.Types.V1.ErrorHandling.InvalidLogin] {
        $result.ErrorMessage = "Authentication failed for vCenter `"$ServerName`". Session may have expired."
        Write-LogMessage -Type WARNING -Message $result.ErrorMessage
        return $result
    } catch [VMware.VimAutomation.Sdk.Types.V1.ErrorHandling.VimException.ViServerConnectionException] {
        $result.ErrorMessage = "Connection to vCenter `"$ServerName`" was lost. Network issue or vCenter restart."
        Write-LogMessage -Type WARNING -Message $result.ErrorMessage
        return $result
    } catch {
        $result.ErrorMessage = "Unable to verify connection to vCenter `"$ServerName`": $_"
        Write-LogMessage -Type WARNING -Message $result.ErrorMessage
        return $result
    }
}
function Assert-VcenterConnected {

    <#
        .SYNOPSIS
        Throws VcfDeploymentException if the active vCenter connection is absent or broken.

        .DESCRIPTION
        Calls Test-VcenterConnection and throws VcfDeploymentException if IsConnected is false.
        Use at the top of any function that requires an active vCenter session before beginning
        operations. Logs the error before throwing so the failure is captured in the log file.

        .EXAMPLE
        Assert-VcenterConnected
        # Throws if not connected to $Script:vCenterName; execution continues only when connected.

        .NOTES
        Throws [VcfDeploymentException]; never returns a value.
        Always checks $Script:vCenterName (the module-level vCenter connection). Call at the top
        of any function that requires an active vCenter session before beginning operations.
    #>

    [CmdletBinding()]
    Param ()

    $connectionTest = Test-VcenterConnection
    if (-not $connectionTest.IsConnected) {
        $errorMsg = "Not connected to vCenter `"$Script:vCenterName`": $($connectionTest.ErrorMessage)"
        Write-LogMessage -Type ERROR -Message $errorMsg
        throw [VcfDeploymentException]::new($errorMsg)
    }
}
function Invoke-VcenterReconnectIfNeeded {

    <#
        .SYNOPSIS
        Ensures an active vCenter connection; if the session was lost, reconnects using stored or prompted credentials.

        .DESCRIPTION
        Calls Test-VcenterConnection. If not connected, attempts to reconnect to vCenter using, in order:
        (1) Script:VcenterInsecurePassword and Script:VCenterUser (from initial Connect-Vcenter),
        (2) VCENTER_COMMON_PASSWORD environment variable and Script:VCenterUser,
        (3) interactive prompt for vCenter password.
        Intended for use in long-running deployment flows (e.g. after supervisor wait timeout) where the
        PowerCLI session may have expired. Requires Script:vCenterName and Script:VCenterUser to be set
        (e.g. from Start-VcfEdgeAtScale). On successful reconnect, updates
        Script:VcenterInsecurePassword so REST API callers (Get-SupervisorId, etc.) continue to work.

        .OUTPUTS
        None. Returns after connection is established. Throws if reconnect fails.
    
        .EXAMPLE
        Invoke-VcenterReconnectIfNeeded
    #>

    [CmdletBinding()]
    Param ()

    if ([String]::IsNullOrWhiteSpace($Script:vCenterName) -or [String]::IsNullOrWhiteSpace($Script:VCenterUser)) {
        throw [VcfDeploymentException]::new("Invoke-VcenterReconnectIfNeeded requires Script:vCenterName and Script:VCenterUser to be set (e.g. from Start-VcfEdgeAtScale).")
    }
    $connectionTest = Test-VcenterConnection -ServerName $Script:vCenterName
    if ($connectionTest.IsConnected) {
        return
    }
    Write-LogMessage -Type INFO -Message "vCenter session lost or expired: $($connectionTest.ErrorMessage). Attempting to reconnect to `"$Script:vCenterName`"..."

    $vCenterCredential = $null
    # Prefer credential from initial Connect-Vcenter (Script:VcenterCredential).
    if ($null -ne $Script:VcenterCredential) {
        $vCenterCredential = $Script:VcenterCredential
    }
    # Else try environment variable.
    if (-not $vCenterCredential -and -not [String]::IsNullOrWhiteSpace($env:VCENTER_COMMON_PASSWORD) -and -not [String]::IsNullOrWhiteSpace($Script:VCenterUser)) {
        try {
            $vCenterPassFromEnv = ConvertTo-SecureStringForCredential -PlainText $env:VCENTER_COMMON_PASSWORD
            $vCenterCredential = New-Object System.Management.Automation.PSCredential($Script:VCenterUser, $vCenterPassFromEnv)
        } catch {
            $vCenterCredential = $null
        }
    }
    if ($vCenterCredential) {
        try {
            Disconnect-Vcenter -AllServers -Silence
            Connect-Vcenter -ServerName $Script:vCenterName -ServerCredential $vCenterCredential -ServerType "vCenter"
            Set-ScriptVcenterCredential -Credential $vCenterCredential
            Write-LogMessage -Type INFO -Message "Reconnected to vCenter `"$Script:vCenterName`" using stored credentials."
            return
        } catch {
            Write-LogMessage -Type WARNING -Message "Reconnect with stored credentials failed: $($_.Exception.Message). Will prompt for password."
            $vCenterCredential = $null
        }
    }
    Write-LogMessage -Type INFO -Message "Prompting for vCenter password to reconnect to `"$Script:vCenterName`"."
    $vCenterPass = Get-InteractiveInput -PromptMessage "Enter the password for the user `"$Script:VCenterUser`" on vCenter `"$Script:vCenterName`" (reconnect): " -AsSecureString
    $vCenterCredential = New-Object System.Management.Automation.PSCredential($Script:VCenterUser, $vCenterPass)
    Disconnect-Vcenter -AllServers -Silence
    Connect-Vcenter -ServerName $Script:vCenterName -ServerCredential $vCenterCredential -ServerType "vCenter"
    Set-ScriptVcenterCredential -Credential $vCenterCredential
    Write-LogMessage -Type INFO -Message "Reconnected to vCenter `"$Script:vCenterName`" using prompted credentials."
}
function Disconnect-Vcenter {

    <#
        .SYNOPSIS
        Safely disconnects from vCenter or ESX host instances with support for individual or bulk disconnection.

        .DESCRIPTION
        The Disconnect-Vcenter function provides a safe and reliable way to disconnect from
        vCenter and/or ESX host instances. It includes comprehensive error handling
        to ensure that disconnection failures are properly logged and handled. The function
        supports both individual server disconnection and bulk disconnection from all active
        connections, making it flexible for various cleanup scenarios.

        The function uses forced disconnection with confirmation suppression to ensure
        reliable cleanup in automated scenarios, making it ideal for script cleanup
        operations and error handling routines. After disconnection, it verifies that
        all connections have been properly terminated by checking $Global:DefaultVIServer.

        Key features:
        - Individual or bulk disconnection management for vCenter and ESX hosts
        - Safe disconnection with comprehensive error handling
        - Post-disconnection verification to ensure clean state
        - Forced disconnection to handle active operations gracefully
        - Confirmation suppression for automated execution
        - Integration with VCF PowerShell Toolbox logging infrastructure

        The function is typically called at the end of scripts, in error handling
        scenarios, or when switching between different server connections to ensure
        proper cleanup of VMware PowerCLI connections.

        .PARAMETER AllServers
        Optional switch parameter that disconnects from all active vCenter and ESX host connections.
        When specified, the function uses wildcard disconnection (Disconnect-VIServer -Server *)
        to terminate all active PowerCLI sessions. This is useful for cleanup scenarios where
        all connections should be terminated regardless of which servers are connected.
        Cannot be used together with ServerName parameter.

        .PARAMETER ServerName
        Optional. The fully qualified domain name (FQDN) or IP address of a specific server to disconnect from.
        This can be either a vCenter or an ESX host, depending on the ServerType parameter.
        This should match the server name used in the original connection.
        Required when AllServers is not specified.

        .PARAMETER ServerType
        Optional. Specifies the type of server being disconnected from. Valid values are "vCenter" or "ESX".
        Used for logging and to match callers that pass the same type as used with Connect-Vcenter.

        .PARAMETER Silence
        Optional switch parameter that suppresses console output for disconnection success messages.
        When specified, successful disconnections are logged with SuppressOutputToScreen flag,
        preventing console output while maintaining log file entries. Error messages are still
        displayed regardless of this parameter. This is useful for automated scenarios where
        verbose console output should be minimized while preserving audit trail functionality.

        .EXAMPLE
        Disconnect-Vcenter -allServers

        Disconnects from all active vCenter and ESX host connections with verification.
        This is the recommended approach for script cleanup and error handling.

        .EXAMPLE
        Disconnect-Vcenter -allServers -silence

        Quietly disconnects from all active connections with suppressed console output.
        Useful for automated cleanup scenarios.

        .EXAMPLE
        Disconnect-Vcenter -serverName "vcenter.example.com" -serverType "vCenter"

        Disconnects from a specific vCenter with error handling and logging.

        .EXAMPLE
        Disconnect-Vcenter -serverName $esxHost -serverType "ESX" -silence

        Disconnects from a specific ESX host with suppressed console output for success messages.

        .NOTES
        - Requires VMware PowerCLI to be installed and imported before execution
        - The function uses Force parameter to ensure disconnection even with active operations or tasks
        - Confirmation prompts are suppressed (Confirm:$false) for automated execution in scripts
        - Post-disconnection verification checks $Global:DefaultVIServer to ensure clean state
        - If any connections remain after disconnection attempt, the function throws a terminating error
        - The allServers switch is recommended for cleanup scenarios to ensure all connections are terminated
        - Error handling provides detailed logging with ErrorAction:Stop to ensure disconnection failures are caught
        - The function integrates with VCF PowerShell Toolbox logging infrastructure for consistent reporting
        - Proper disconnection prevents resource leaks and ensures clean session management
        - Function is designed for use in cleanup scenarios, error handling routines, and temporary connection management
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $false)] [Switch]$AllServers,
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$ServerName,
        [Parameter(Mandatory = $false)] [ValidateSet("vCenter", "ESX")] [String]$ServerType,
        [Parameter(Mandatory = $false)] [Switch]$Silence
    )
    Write-LogMessage -Type DEBUG -Message "Entered Disconnect-Vcenter function..."

    # Disconnect from vCenter. Try bulk disconnect first, then individual if needed.
    if ($AllServers) {
        try {
            Disconnect-VIServer -Server * -Force -Confirm:$false -ErrorAction Stop | Out-Null
        } catch {
            # Bulk disconnect failed - try individual disconnects if there are any connections.
            # Only attempt if the error isn't "no servers found" (which is expected when there are no connections).
            if ($_.Exception.Message -notmatch "Could not find any of the servers") {
                Write-LogMessage -Type DEBUG -Message "Bulk disconnect failed, attempting individual disconnects: $($_.Exception.Message)"
                # Use $Global:DefaultVIServer instead of Get-VIServer to avoid interfering with session state.
                if ($Global:DefaultVIServer) {
                    $serversToDisconnect = @($Global:DefaultVIServer)
                    foreach ($server in $serversToDisconnect) {
                        Disconnect-VIServer -Server $server.Name -Force -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
                    }
                }
            }
        }
    } else {
        try {
            if ($ServerType) {
                Write-LogMessage -Type DEBUG -Message "Disconnecting from $ServerType `"$ServerName`"..."
            }
            Disconnect-VIServer -Server $ServerName -Force -Confirm:$false -ErrorAction Stop | Out-Null
        } catch {
            Write-LogMessage -Type DEBUG -Message "Error during server disconnection (non-critical): $($_.Exception.Message)"
        }
    }

    # Verify all servers are disconnected (only if AllServers was specified).
    # Use $Global:DefaultVIServer instead of Get-VIServer to avoid interfering with session state.
    if ($AllServers) {
        if ($null -eq $Global:DefaultVIServer) {
            if ($Silence) {
                Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "Successfully disconnected from all vCenter and ESX hosts."
            } else {
                Write-LogMessage -Type INFO -Message "Successfully disconnected from all vCenter and ESX hosts."
            }
        } else {
            $activeConnections = @($Global:DefaultVIServer) | Where-Object { $_.IsConnected -eq $true }
            if ($activeConnections.Count -eq 0) {
                if ($Silence) {
                    Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "Successfully disconnected from all vCenter and ESX hosts."
                } else {
                    Write-LogMessage -Type INFO -Message "Successfully disconnected from all vCenter and ESX hosts."
                }
            } else {
                $serverNames = $activeConnections | Select-Object -ExpandProperty Name
                $err = "Failed to disconnect from all servers. The following connections remain active: $($serverNames -join ', ')"
                Write-LogMessage -Type ERROR -Message $err
                throw [VcfDeploymentException]::new($err)
            }
        }
    }
}
function Test-VCenterVersion {

    <#
        .SYNOPSIS
        Validates that vCenter is running a specified minimum version or later.

        .DESCRIPTION
        The Test-VCenterVersion function checks the version of the connected vCenter
        to ensure it meets a specified minimum version requirement. This validation is critical
        for ensuring that the vCenter supports the features and APIs required for
        deployment operations.

        The function retrieves the vCenter version from the connected vCenter instance
        (identified by $Script:vCenterName) using the PowerCLI API version information. It
        accepts a minimum required version as a parameter in the format "major.minor.patch"
        (e.g., "9.0.0") and performs a semantic version comparison to validate that the
        detected version meets or exceeds the requirement.

        The minimum version string is parsed within the function to extract major, minor, and
        patch components for comparison against the detected vCenter version.

        Key features:
        - Retrieves vCenter version from active connection using $Script:vCenterName
        - Accepts flexible minimum version parameter (major.minor.patch format)
        - Performs semantic version comparison (major.minor.patch)
        - Provides detailed error messages for version mismatches
        - Logs version information for audit trail
        - Returns standardized result object for error handling

        .PARAMETER MinimumVersion
        The minimum required version in "major.minor.patch" format (e.g., "9.0.0", "8.0.3").
        This parameter is mandatory and determines the version threshold for validation.
        The version string must contain at least three dot-separated numeric components.

        .EXAMPLE
        $result = Test-VCenterVersion -MinimumVersion "9.0.0"
        if (-not $result.Success) {
            $err = "Version validation failed: $($result.ErrorMessage)"
            Write-LogMessage -Type ERROR -Message $err
            throw [VcfDeploymentException]::new($err)
        }

        Validates the vCenter version against a minimum requirement of 9.0.0.

        .EXAMPLE
        Test-VCenterVersion -MinimumVersion "8.0.3"

        Validates the vCenter version with a minimum requirement of 8.0.3.

        .OUTPUTS
        PSCustomObject
        Returns an object with the following properties:
        - Success: Boolean indicating whether validation passed
        - ErrorMessage: String containing error details if validation failed (null on success)
        - ErrorCode: String containing error code if validation failed (null on success)
        - Version: String containing the detected vCenter version
        - MinimumVersion: String containing the minimum required version

        .NOTES
        - Requires an active connection to vCenter (via Connect-Vcenter)
        - Uses $Script:vCenterName global variable to identify the connected vCenter
        - The function uses $Global:DefaultViServers to access connection information
        - Version comparison follows semantic versioning rules (major.minor.patch)
        - Returns error result object on failure instead of throwing exceptions
        - Integrates with Write-LogMessage for consistent logging
        - Version strings must be in format "major.minor.patch" (e.g., "9.0.0")

        Error Handling: Validation function. Returns structured error object via Write-ErrorAndReturn
        on any validation failure. Caller should check $result.Success and decide whether to exit
        or continue. Typically, main workflow functions throw a terminating error on version validation failure.

        .LINK
        Connect-Vcenter
        Disconnect-Vcenter
    #>

    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$MinimumVersion
    )

    Write-LogMessage -Type DEBUG -Message "Entered Test-VCenterVersion function..."

    try {

        $vcServer = $Global:DefaultViServers | Where-Object { $_.Name -eq $Script:vCenterName -and $_.IsConnected }

        if (-not $vcServer) {
            return Write-ErrorAndReturn -ErrorMessage "Not connected to vCenter `"$Script:vCenterName`". Please establish a connection first." -ErrorCode "ERR_NOT_CONNECTED"
        }


        $vcVersionString = $vcServer.Version

        if (-not $vcVersionString) {
            return Write-ErrorAndReturn -ErrorMessage "Unable to retrieve version information from vCenter `"$Script:vCenterName`"." -ErrorCode "ERR_VERSION_UNAVAILABLE"
        }

        Write-LogMessage -Type DEBUG -Message "Detected vCenter `"$Script:vCenterName`" version: $vcVersionString"

        # Convert version strings to [version] type for proper semantic version comparison.
        try {
            $vcVersion = [Version]$vcVersionString
            $minVersion = [Version]$MinimumVersion
        } catch {
            return Write-ErrorAndReturn -ErrorMessage "Failed to parse version strings. vCenter version: `"$vcVersionString`", Minimum version: `"$MinimumVersion`". Both must be in valid version format (e.g., 9.0.0)." -ErrorCode "ERR_VERSION_PARSE_FAILED"
        }

        # Compare versions using [version] type comparison (automatically handles major.minor.build.revision)
        if ($vcVersion -lt $minVersion) {
            return Write-ErrorAndReturn -ErrorMessage "vCenter `"$Script:vCenterName`" version $vcVersionString does not meet minimum required version: $MinimumVersion. Please upgrade vCenter." -ErrorCode "ERR_VERSION_TOO_OLD"
        }

        # Version validation passed.
        Write-LogMessage -Type DEBUG -Message "vCenter `"$Script:vCenterName`" version $vcVersionString meets minimum required version ($MinimumVersion)."

        return [PSCustomObject]@{
            Success        = $true
            ErrorMessage   = $null
            ErrorCode      = $null
            Version        = $vcVersionString
            MinimumVersion = $MinimumVersion
        }

    } catch {
        return Write-ErrorAndReturn -ErrorMessage "Failed to validate vCenter version for `"$Script:vCenterName`": $_" -ErrorCode "ERR_VALIDATION_EXCEPTION"
    }
}
function Test-ESXVersion {

    <#
        .SYNOPSIS
        Validates that an ESX host is running a specified minimum version or later.

        .DESCRIPTION
        The Test-ESXVersion function checks the version of a connected ESX host to ensure it meets
        a specified minimum version requirement. Call it after Connect-Vcenter to the ESX host.
        Uses the same semantic version comparison as Test-VCenterVersion.

        .PARAMETER MinimumVersion
        The minimum required version in "major.minor.patch" format (e.g., "9.0.0").

        .PARAMETER ServerName
        The ESX host name or address (must match the current connection in DefaultViServers).

        .OUTPUTS
        PSCustomObject with Success, ErrorMessage, ErrorCode, Version, MinimumVersion.
    
        .EXAMPLE
        $eSXVersionResult = Test-ESXVersion -MinimumVersion "value" -ServerName $vcenterConnection
        if (-not $eSXVersionResult.IsValid) { Write-LogMessage -Type ERROR -Message $eSXVersionResult.Summary }
    #>

    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$MinimumVersion,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ServerName
    )

    Write-LogMessage -Type DEBUG -Message "Entered Test-ESXVersion function..."

    try {
        $esxServer = $Global:DefaultViServers | Where-Object { $_.Name -eq $ServerName -and $_.IsConnected }

        if (-not $esxServer) {
            return Write-ErrorAndReturn -ErrorMessage "Not connected to ESX host `"$ServerName`". Please establish a connection first." -ErrorCode "ERR_NOT_CONNECTED"
        }

        $esxVersionString = $esxServer.Version

        if (-not $esxVersionString) {
            return Write-ErrorAndReturn -ErrorMessage "Unable to retrieve version information from ESX host `"$ServerName`"." -ErrorCode "ERR_VERSION_UNAVAILABLE"
        }

        Write-LogMessage -Type DEBUG -Message "Detected ESX host `"$ServerName`" version: $esxVersionString"

        try {
            $esxVersion = [Version]$esxVersionString
            $minVersion = [Version]$MinimumVersion
        } catch {
            return Write-ErrorAndReturn -ErrorMessage "Failed to parse version strings. ESX version: `"$esxVersionString`", Minimum version: `"$MinimumVersion`". Both must be in valid version format (e.g., 9.0.0)." -ErrorCode "ERR_VERSION_PARSE_FAILED"
        }

        if ($esxVersion -lt $minVersion) {
            return Write-ErrorAndReturn -ErrorMessage "ESX host `"$ServerName`" version $esxVersionString does not meet minimum required version: $MinimumVersion. Please upgrade the host." -ErrorCode "ERR_VERSION_TOO_OLD"
        }

        Write-LogMessage -Type DEBUG -Message "ESX host `"$ServerName`" version $esxVersionString meets minimum required version ($MinimumVersion)."

        return [PSCustomObject]@{
            Success        = $true
            ErrorMessage   = $null
            ErrorCode      = $null
            Version        = $esxVersionString
            MinimumVersion = $MinimumVersion
        }

    } catch {
        return Write-ErrorAndReturn -ErrorMessage "Failed to validate ESX version for `"$ServerName`": $_" -ErrorCode "ERR_VALIDATION_EXCEPTION"
    }
}
function Invoke-DatastoreResolutionWithDiagnostics {

    <#
        .SYNOPSIS
        Retrieves a named datastore from vCenter, emitting diagnostic information when the datastore is not found.

        .DESCRIPTION
        Calls Get-Datastore for the specified name. When found, returns the datastore object. When not found,
        logs available datastores as diagnostic guidance and throws a VcfDeploymentException.

        .PARAMETER DatastoreName
        Name of the datastore to retrieve from the connected vCenter.

        .EXAMPLE
        $datastoreObject = Invoke-DatastoreResolutionWithDiagnostics -DatastoreName "shared-storage"
    #>

    [CmdletBinding()]
    [OutputType([Object])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$DatastoreName
    )

    Write-LogMessage -Type DEBUG -Message "Retrieving datastore `"$DatastoreName`" from vCenter `"$Script:vCenterName`"..."
    $datastoreObject = Get-Datastore -Name $DatastoreName -Server $Script:vCenterName -ErrorAction SilentlyContinue

    if ($datastoreObject) {
        Write-LogMessage -Type DEBUG -Message "Found datastore `"$DatastoreName`" (ID: $($datastoreObject.Id)) on vCenter `"$Script:vCenterName`"."
        return $datastoreObject
    }

    Write-LogMessage -Type ERROR -Message "Datastore `"$DatastoreName`" not found on vCenter `"$Script:vCenterName`"."
    Write-LogMessage -Type ERROR -Message "The datastore specified in the configuration does not exist or is not accessible."

    try {
        $availableDatastores = Get-Datastore -Server $Script:vCenterName -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name | Sort-Object
        if ($availableDatastores) {
            Write-LogMessage -Type ERROR -Message "Available datastores on vCenter `"$Script:vCenterName`":"
            foreach ($ds in $availableDatastores) {
                Write-LogMessage -Type ERROR -Message "  - $ds"
            }
        } else {
            Write-LogMessage -Type ERROR -Message "No datastores found on vCenter `"$Script:vCenterName`"."
        }
    } catch [VcfDeploymentException] {
        throw
    } catch {
        Write-LogMessage -Type DEBUG -Message "Could not retrieve list of available datastores: $($_.Exception.Message)"
    }

    $err = "SOLUTION: Update the datastore name in your configuration file to match an existing datastore on vCenter `"$Script:vCenterName`"."
    Write-LogMessage -Type ERROR -Message $err
    throw [VcfDeploymentException]::new($err)
}
function Get-SubscriptionSslThumbprint {

    <#
        .SYNOPSIS
        Retrieves the SSL certificate thumbprint from a subscription URL endpoint.

        .DESCRIPTION
        Opens a TCP/SSL connection to the host of the subscription URL, performs an SSL handshake,
        extracts the server certificate, and returns the thumbprint formatted with colon separators
        (e.g. "AA:BB:CC:..."). The TCP and SSL resources are always closed in a finally block.
        Throws VcfDeploymentException if the connection fails or the certificate cannot be retrieved.

        .PARAMETER SubscriptionUrl
        The full URL of the content library subscription endpoint. The host and port are parsed from this URL.

        .OUTPUTS
        System.String
        Returns the colon-separated SHA1 thumbprint of the server's SSL certificate.

        .EXAMPLE
        $thumbprint = Get-SubscriptionSslThumbprint -SubscriptionUrl "https://vcenter.example.com/cls/vcsp/lib/abc/lib.json"
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$SubscriptionUrl
    )

    Write-LogMessage -Type DEBUG -Message "Retrieving SSL certificate thumbprint from subscription URL: $SubscriptionUrl"
    $subscriptionUri = [System.Uri]$SubscriptionUrl
    $hostname = $subscriptionUri.Host
    $port = if ($subscriptionUri.Port -ne -1) { $subscriptionUri.Port } else { if ($subscriptionUri.Scheme -eq "https") { 443 } else { 80 } }

    $tcpClient = $null
    $sslStream = $null
    $sslThumbprint = $null

    try {
        Write-LogMessage -Type DEBUG -Message "Opening TCP connection to $hostname on port $port..."
        $tcpClient = New-Object System.Net.Sockets.TcpClient($hostname, $port)

        # Accept all certs for retrieval; params required by RemoteCertificateValidationCallback.
        $sslStream = New-Object System.Net.Security.SslStream(
            $tcpClient.GetStream(),
            $false,
            { param($certSender, $certificate, $chain, $sslPolicyErrors) $null = $certSender, $certificate, $chain, $sslPolicyErrors; return $true }
        )

        Write-LogMessage -Type DEBUG -Message "Performing SSL handshake with $hostname..."
        $sslStream.AuthenticateAsClient($hostname)

        $certificate = $sslStream.RemoteCertificate
        if (-not $certificate) {
            Write-LogMessage -Type ERROR -Message "Could not retrieve SSL certificate from $hostname. RemoteCertificate is null."
            $err = "This may indicate a network connectivity issue or the server is not responding."
            Write-LogMessage -Type ERROR -Message $err
            throw [VcfDeploymentException]::new($err)
        }

        $rawHash = $certificate.GetCertHashString()
        $sslThumbprint = ($rawHash.ToUpper() -replace '(..)(?=.+)', '$1:')
        Write-LogMessage -Type DEBUG -Message "Retrieved SSL thumbprint for $hostname - $sslThumbprint"
    } catch {
        Write-LogMessage -Type ERROR -Message "Failed to retrieve SSL certificate thumbprint from $hostname - $($_.Exception.Message)"
        if ($_.Exception.InnerException) {
            Write-LogMessage -Type ERROR -Message "Inner exception: $($_.Exception.InnerException.Message)"
        }
        $err = "Cannot create content library without SSL thumbprint."
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    } finally {
        if ($null -ne $sslStream) {
            try { $sslStream.Close() } catch {
                Write-LogMessage -Type DEBUG -Message "Suppressed during SSL stream cleanup: $($_.Exception.Message)"
            }
        }
        if ($null -ne $tcpClient) {
            try { $tcpClient.Close() } catch {
                Write-LogMessage -Type DEBUG -Message "Suppressed during TCP client cleanup: $($_.Exception.Message)"
            }
        }
    }

    if (-not $sslThumbprint) {
        $err = "Could not retrieve SSL certificate from $hostname. Cannot create content library without SSL thumbprint."
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }

    return $sslThumbprint
}
function Invoke-SubscriptionContentLibraryCreate {

    <#
        .SYNOPSIS
        Creates a subscription-based content library and verifies creation by returning its ID.

        .DESCRIPTION
        Calls New-ContentLibrary with the provided datastore, SSL thumbprint, and subscription URL.
        After creation, calls Get-ContentLibraryId to verify the library exists and returns its ID.
        Throws VcfDeploymentException if the post-creation lookup returns no ID.

        .PARAMETER DatastoreObject
        The resolved datastore object (from Invoke-DatastoreResolutionWithDiagnostics) to associate
        with the new content library.

        .PARAMETER LibraryDescription
        Description string for the new content library.

        .PARAMETER LibraryName
        Name of the new content library.

        .PARAMETER SslThumbprint
        Colon-separated SSL thumbprint for the subscription URL (from Get-SubscriptionSslThumbprint).

        .PARAMETER SubscriptionUrl
        The subscription endpoint URL for the content library.

        .OUTPUTS
        System.String
        Returns the unique ID of the newly created content library.

        .EXAMPLE
        $libraryId = Invoke-SubscriptionContentLibraryCreate -DatastoreObject $ds -LibraryDescription "Patch library" -LibraryName "VCF-Lib" -SslThumbprint "AA:BB:CC" -SubscriptionUrl "https://vcenter.example.com/lib.json"
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] $DatastoreObject,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$LibraryDescription,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$LibraryName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$SslThumbprint,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$SubscriptionUrl
    )

    Write-LogMessage -Type DEBUG -Message "Creating content library `"$LibraryName`" with SSL thumbprint: $SslThumbprint"
    New-ContentLibrary -Name $LibraryName `
        -Description $LibraryDescription `
        -SubscriptionUrl $SubscriptionUrl `
        -Datastore $DatastoreObject `
        -AutomaticSync `
        -SslThumbprint $SslThumbprint `
        -ErrorAction Stop `
        -Server $Script:vCenterName | Out-Null

    Write-LogMessage -Type DEBUG -Message "Successfully created content library `"$LibraryName`" on vCenter `"$Script:vCenterName`"."

    $contentLibraryId = Get-ContentLibraryId -LibraryName $LibraryName
    if (-not $contentLibraryId) {
        $err = "Content library `"$LibraryName`" was created but could not be retrieved from vCenter `"$Script:vCenterName`"."
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }

    return $contentLibraryId
}
function New-SubscriptionBasedContentLibrary {

    <#
        .SYNOPSIS
        Creates a new subscription based content library on vCenter and returns its unique identifier.

        .DESCRIPTION
        The New-SubscriptionBasedContentLibrary function creates a new subscription based content library in vCenter
        using the specified datastore for storage. This content library is a container for storing 9.0.1 async patch
        for supervisor.

        This function performs the following operations:
        1. Checks if a content library with the same name already exists
        2. Retrieves and validates the specified datastore object from vCenter
        3. Retrieves the SSL thumbprint from the subscription URL endpoint
        4. Creates a new subscription based content library with the provided name, description and subscriptionURL
        5. Associates the content library with the specified datastore for storage
        6. Verifies the library was created successfully and returns its unique identifier

        The function includes comprehensive error handling for authorization issues, network timeouts,
        datastore validation, and other potential failures during content library creation. All operations
        are logged using the Write-LogMessage system for audit trail and troubleshooting purposes.

        .PARAMETER DatastoreName
        The name of the datastore where the content library will store its content. This datastore
        must already exist and be accessible from the connected vCenter. The datastore will
        be used to store 9.0.1 async patch for supervisor.

        .PARAMETER LibraryDescription
        A descriptive text that explains the purpose and contents of the content library. This
        description helps administrators understand the library's intended use and is displayed
        in the vSphere Client interface.

        .PARAMETER LibraryName
        The name for the new content library. This name must be unique within the vCenter
        and should follow standard naming conventions. The name will be used to identify and
        manage the content library through the vSphere Client and API operations.

        .PARAMETER SubscriptionUrl
        Specifies the URL of the endpoint where the metadata for the remotely published library is served.
        The URL format is validated by Test-JsonPropertyFormat during JSON validation. This function is
        typically called only after Test-ContentLibraryBySubscriptionUri confirms no library with this
        SubscriptionUrl exists.

        .EXAMPLE
        New-SubscriptionBasedContentLibrary -DatastoreName "datastore1" -LibraryName "VCF-ContentLibrary" -LibraryDescription "9.0.1 async patch storage for supervisor" -SubscriptionUrl "Publisher Content Library publishurl"

        Creates a new subscription based content library named "VCF-ContentLibrary" stored on "datastore1" with the specified description.

        .EXAMPLE
        $libraryId = New-SubscriptionBasedContentLibrary -DatastoreName "shared-storage" -LibraryName "Production-Templates" -LibraryDescription "9.0.1 async patch storage for supervisor" -SubscriptionUrl "Publisher Content Library publishurl"

        Creates a content library and stores the returned library ID in a variable for later use.

        .EXAMPLE
        New-SubscriptionBasedContentLibrary -DatastoreName $DatastoreName -LibraryName $LibraryName -LibraryDescription $LibraryDescription -SubscriptionUrl $SubscriptionUrl

        Creates a content library using variables for dynamic deployment scenarios.

        .OUTPUTS
        System.String
        Returns the unique identifier (ID) of the newly created content library. This ID can be used
        for subsequent operations such as adding content items or configuring library permissions.

        .NOTES
        - Requires an active PowerCLI connection to vCenter via the $Script:vCenterName variable
        - The specified datastore must exist and be accessible from vCenter
        - The publishURL from the content library has to be passed as SubscriptionUrl
        - SubscriptionUrl format is validated by Test-JsonPropertyFormat during JSON validation
        - This function is typically called only after Test-ContentLibraryBySubscriptionUri confirms
          no library with the SubscriptionUrl exists, so SubscriptionUrl checking is not performed here
        - The function checks for existing libraries by name before creating
        - If a library with the same name exists, returns the existing library ID
        - The function validates datastore existence before attempting library creation
        - The function verifies library creation was successful before returning the library ID
        - Uses comprehensive error handling for authorization, network timeout, datastore validation, and general failures
        - Integrates with the VCF PowerShell Toolbox logging infrastructure for consistent reporting
        - The returned library ID is obtained by calling Get-ContentLibraryId after successful creation
        - The function uses the VMware PowerCLI New-ContentLibrary cmdlet for library creation

        .LINK
        Get-ContentLibraryId
        Get-SubscriptionSslThumbprint
        Invoke-DatastoreResolutionWithDiagnostics
        Invoke-SubscriptionContentLibraryCreate
        New-ContentLibrary
        Test-ContentLibraryBySubscriptionUri
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$DatastoreName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$LibraryDescription,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$LibraryName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$SubscriptionUrl
    )

    Write-LogMessage -Type DEBUG -Message "Entered New-SubscriptionBasedContentLibrary function..."

    $connectionTest = Test-VcenterConnection
    if (-not $connectionTest.IsConnected) {
        $err = "Not connected to vCenter `"$Script:vCenterName`": $($connectionTest.ErrorMessage)"
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }

    $contentLibraryId = Get-ContentLibraryId -LibraryName $LibraryName
    if ($contentLibraryId) {
        Write-LogMessage -Type INFO -Message "Content library `"$LibraryName`" already exists on vCenter `"$Script:vCenterName`". Skipping content library creation."
        return $contentLibraryId
    }

    try {
        $datastoreObject = Invoke-DatastoreResolutionWithDiagnostics -DatastoreName $DatastoreName
        $sslThumbprint = Get-SubscriptionSslThumbprint -SubscriptionUrl $SubscriptionUrl
        return Invoke-SubscriptionContentLibraryCreate -DatastoreObject $datastoreObject -LibraryDescription $LibraryDescription -LibraryName $LibraryName -SslThumbprint $sslThumbprint -SubscriptionUrl $SubscriptionUrl
    }
    catch [System.UnauthorizedAccessException] {
        $err = "Cannot create content library `"$LibraryName`" (`"$LibraryDescription`") on vCenter `"$Script:vCenterName`" due to authorization issues: $($_.Exception.Message)"
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }
    catch [System.TimeoutException] {
        $err = "Cannot create content library `"$LibraryName`" (`"$LibraryDescription`") on vCenter `"$Script:vCenterName`" due to network/timeout issues: $($_.Exception.Message)"
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    } catch {
        $errorMessage = $_.Exception.Message
        $innerException = $_.Exception.InnerException
        $innerDetail = ""
        if ($null -ne $innerException) {
            $innerDetail = "`nInner exception: $($innerException.Message)"
            if ($null -ne $innerException.InnerException) {
                $innerDetail = "$innerDetail`nNested inner exception: $($innerException.InnerException.Message)"
            }
        }
        $detailedError = "Failed to create content library `"$LibraryName`" (`"$LibraryDescription`") on vCenter `"$Script:vCenterName`": $errorMessage$innerDetail"
        Write-LogMessage -Type ERROR -Message $detailedError
        if ($errorMessage -match "subscribe|subscription") {
            Write-LogMessage -Type ERROR -Message "The subscription URL `"$SubscriptionUrl`" may be invalid, unreachable, or the publisher library may not be available."
            Write-LogMessage -Type ERROR -Message "Common causes:"
            Write-LogMessage -Type ERROR -Message "  1. The subscription URL is incorrect or the publisher library has been removed"
            Write-LogMessage -Type ERROR -Message "  2. Network connectivity issues preventing access to the publisher library"
            Write-LogMessage -Type ERROR -Message "  3. The publisher library requires authentication that hasn't been configured"
            Write-LogMessage -Type ERROR -Message "  4. SSL certificate validation failures (check PowerCLI InvalidCertificateAction setting)"
            Write-LogMessage -Type ERROR -Message "SOLUTION: Verify the subscription URL is correct and the publisher library is accessible from this vCenter."
        }
        throw [VcfDeploymentException]::new("Failed to query lifecycle content libraries on `"$Script:vCenterName`". Check logs for details.")
    }
}
function Get-SupervisorLifecycleContentLibraries {

    <#
        .SYNOPSIS
        Retrieves lifecycle content libraries associated with the supervisor for enablement and upgrades.

        .DESCRIPTION
        The Get-SupervisorLifecycleContentLibraries function queries the vCenter namespace management
        lifecycle content libraries using PowerCLI cmdlets to check if there are any content libraries
        configured for supervisor enablement and upgrades. This function is used to determine if a
        content library needs to be associated with the supervisor.

        The function checks the status of each library. If any library has status "READY", it indicates
        that a content library is already properly configured and no further action is needed.

        .OUTPUTS
        PSCustomObject with the following properties:
        • Success (Boolean): Indicates if query succeeded
        • HasReadyLibrary (Boolean): $true if at least one library has status "READY", $false otherwise
        • Libraries (Array): Array of library objects with id and status
        • ErrorMessage (String): Error details if Success is $false

        .EXAMPLE
        $result = Get-SupervisorLifecycleContentLibraries
        if ($result.Success -and $result.HasReadyLibrary) {
            Write-LogMessage -Type INFO -Message "Content library is already configured and ready."
        }

        .NOTES
        PowerCLI Cmdlet: Invoke-VcenterNamespaceManagementLifecycleContentLibrariesList

        Behavior:
        • Queries lifecycle content libraries for supervisor enablement/upgrades using PowerCLI
        • Checks if any library has status "READY"
        • Returns empty array if no libraries are configured
        • Success=$true even if no libraries found (query succeeded)
        • Uses existing PowerCLI connection to vCenter (no session headers needed)

        Error Handling:
        • Returns structured object instead of throwing exceptions
        • Cmdlet failures return Success=$false
    #>
    [OutputType([PSCustomObject])]

    [CmdletBinding()]
    Param ()

    Write-LogMessage -Type DEBUG -Message "Entered Get-SupervisorLifecycleContentLibraries function..."

    try {
        Write-LogMessage -Type DEBUG -Message "Querying lifecycle content libraries using PowerCLI cmdlets..."

        # Query lifecycle content libraries using PowerCLI cmdlet.
        $librariesList = Invoke-VcenterNamespaceManagementLifecycleContentLibrariesList -ErrorAction Stop

        $hasReadyLibrary = $false
        $libraries = [System.Collections.Generic.List[Object]]::new()

        if ($librariesList) {
            foreach ($libraryEntry in $librariesList) {
                $libraryInfo = @{
                    Id = $libraryEntry.Library.Id
                    Status = $libraryEntry.Status
                }
                $null = $libraries.Add($libraryInfo)

                if ($libraryEntry.Status -eq "READY") {
                    $hasReadyLibrary = $true
                    Write-LogMessage -Type DEBUG -Message "Found content library with READY status: $($libraryEntry.Library.Id)"
                }
            }
        }

        if ($hasReadyLibrary) {
            Write-LogMessage -Type INFO -Message "Lifecycle content library is already configured and ready for supervisor enablement/upgrades."
        }
        else {
            if ($libraries.Count -eq 0) {
                Write-LogMessage -Type DEBUG -Message "No lifecycle content libraries found. A content library needs to be associated."
            }
            else {
                Write-LogMessage -Type DEBUG -Message "Found $($libraries.Count) lifecycle content library(ies), but none have READY status."
            }
        }

        return [PSCustomObject]@{
            Success = $true
            HasReadyLibrary = $hasReadyLibrary
            Libraries = $libraries
            ErrorMessage = $null
        }
    } catch {
        $errorMessage = $_.Exception.Message
        Write-LogMessage -Type ERROR -Message "Failed to query lifecycle content libraries: $errorMessage"

        return [PSCustomObject]@{
            Success = $false
            HasReadyLibrary = $false
            Libraries = @()
            ErrorMessage = $errorMessage
        }
    }
}
function Set-SupervisorLifecycleContentLibrary {

    <#
        .SYNOPSIS
        Associates a content library with the supervisor for enablement and upgrades.

        .DESCRIPTION
        The Set-SupervisorLifecycleContentLibrary function associates a content library with the
        supervisor cluster using PowerCLI cmdlets. This enables the supervisor to use the content
        library for supervisor enablement and upgrades.

        This function should only be called after Get-SupervisorLifecycleContentLibraries confirms
        that no library with status "READY" exists.

        .PARAMETER ContentLibraryId
        The unique identifier of the content library to associate with the supervisor.
        This should be a subscribed content library containing supervisor images.

        .OUTPUTS
        PSCustomObject with the following properties:
        • Success (Boolean): Indicates if association succeeded
        • ErrorMessage (String): Error details if Success is $false

        .EXAMPLE
        $result = Set-SupervisorLifecycleContentLibrary -ContentLibraryId $libraryId
        if ($result.Success) {
            Write-LogMessage -Type INFO -Message "Content library associated successfully."
        }

        .NOTES
        PowerCLI Cmdlets:
        • Initialize-VcenterNamespaceManagementLifecycleContentLibrariesSetSpec
        • Invoke-VcenterNamespaceManagementLifecycleContentLibrariesSet

        Behavior:
        • Associates a content library with the supervisor for lifecycle operations
        • The content library should be a subscribed library with supervisor images
        • The library status will be checked asynchronously after association
        • Uses existing PowerCLI connection to vCenter (no session headers needed)
        • These operations work even with no supervisors deployed in a cluster

        Error Handling:
        • Returns structured object instead of throwing exceptions
        • Cmdlet failures return Success=$false
    #>

    [CmdletBinding()]
    [OutputType([Bool])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ContentLibraryId
    )

    Write-LogMessage -Type DEBUG -Message "Entered Set-SupervisorLifecycleContentLibrary function..."

    try {
        Write-LogMessage -Type DEBUG -Message "Associating content library `"$ContentLibraryId`" with supervisor for lifecycle operations..."

        $setSpec = Initialize-VcenterNamespaceManagementLifecycleContentLibrariesSetSpec -Library $ContentLibraryId -ErrorAction Stop

        # Associate content library with supervisor using PowerCLI cmdlet.
        Invoke-VcenterNamespaceManagementLifecycleContentLibrariesSet -VcenterNamespaceManagementLifecycleContentLibrariesSetSpec $setSpec -Confirm:$false -ErrorAction Stop | Out-Null

        Write-LogMessage -Type DEBUG -Message "Successfully associated content library `"$ContentLibraryId`" with supervisor for lifecycle operations."

        return [PSCustomObject]@{
            Success = $true
            ErrorMessage = $null
        }
    } catch {
        $errorMessage = $_.Exception.Message
        Write-LogMessage -Type ERROR -Message "Failed to associate content library `"$ContentLibraryId`" with supervisor: $errorMessage"

        return [PSCustomObject]@{
            Success = $false
            ErrorMessage = $errorMessage
        }
    }
}
function Initialize-SupervisorLifecycleContentLibrary {

    <#
        .SYNOPSIS
        Initializes and ensures a content library is associated with the supervisor for enablement and upgrades.

        .DESCRIPTION
        The Initialize-SupervisorLifecycleContentLibrary function checks if a lifecycle content library
        with READY status already exists. If not, it associates the provided content library with
        the supervisor for enablement and upgrades. This function uses PowerCLI cmdlets and the existing
        PowerCLI connection to vCenter for all operations.

        .PARAMETER ContentLibraryId
        The unique identifier of the content library to associate with the supervisor if needed.
        This should be a subscribed content library containing supervisor images.

        .OUTPUTS
        PSCustomObject with the following properties:
        • Success (Boolean): Indicates if operation succeeded
        • ActionTaken (String): "none" if READY library exists, "associated" if library was associated, "error" if error occurred
        • ErrorMessage (String): Error details if Success is $false

        .EXAMPLE
        $result = Initialize-SupervisorLifecycleContentLibrary -ContentLibraryId $libraryId
        if ($result.Success) {
            Write-LogMessage -Type INFO -Message "Lifecycle content library check completed: $($result.ActionTaken)"
        }

        .NOTES
        This function encapsulates the entire lifecycle content library check and association workflow.
        It uses PowerCLI cmdlets to check for existing READY libraries and associates if needed.
        All errors are handled gracefully and logged as warnings without blocking deployment.
        These operations work even with no supervisors deployed in a cluster.
        The function uses the existing PowerCLI connection to vCenter (no authentication parameters needed).

        PowerCLI Cmdlets Used:
        • Invoke-VcenterNamespaceManagementLifecycleContentLibrariesList (via Get-SupervisorLifecycleContentLibraries)
        • Initialize-VcenterNamespaceManagementLifecycleContentLibrariesSetSpec (via Set-SupervisorLifecycleContentLibrary)
        • Invoke-VcenterNamespaceManagementLifecycleContentLibrariesSet (via Set-SupervisorLifecycleContentLibrary)
    #>

    [CmdletBinding()]
    [OutputType([Bool])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ContentLibraryId
    )

    Write-LogMessage -Type DEBUG -Message "Entered Initialize-SupervisorLifecycleContentLibrary function..."

    try {
        Write-LogMessage -Type DEBUG -Message "Checking lifecycle content libraries for supervisor enablement/upgrades..."

        # Check if a lifecycle content library with READY status already exists using PowerCLI cmdlets.
        $lifecycleCheck = Get-SupervisorLifecycleContentLibraries
        if (-not $lifecycleCheck.Success) {
            Write-LogMessage -Type WARNING -Message "Failed to check lifecycle content libraries: $($lifecycleCheck.ErrorMessage). Skipping content library association."
            return [PSCustomObject]@{
                Success = $false
                ActionTaken = "error"
                ErrorMessage = "Failed to check lifecycle content libraries: $($lifecycleCheck.ErrorMessage)"
            }
        }

        if ($lifecycleCheck.HasReadyLibrary) {
            Write-LogMessage -Type DEBUG -Message "Lifecycle content library is already configured and ready. No association needed."
            return [PSCustomObject]@{
                Success = $true
                ActionTaken = "none"
                ErrorMessage = $null
            }
        }

        # No READY library exists, associate the provided content library using PowerCLI cmdlets.
        Write-LogMessage -Type DEBUG -Message "No READY lifecycle content library found. Associating content library `"$ContentLibraryId`" with supervisor for enablement/upgrades..."
        $associateResult = Set-SupervisorLifecycleContentLibrary -ContentLibraryId $ContentLibraryId
        if (-not $associateResult.Success) {
            Write-LogMessage -Type WARNING -Message "Failed to associate content library with supervisor lifecycle: $($associateResult.ErrorMessage). Supervisor enablement/upgrades may not work correctly."
            return [PSCustomObject]@{
                Success = $false
                ActionTaken = "error"
                ErrorMessage = $associateResult.ErrorMessage
            }
        }

        return [PSCustomObject]@{
            Success = $true
            ActionTaken = "associated"
            ErrorMessage = $null
        }
    } catch {
        $errorMessage = $_.Exception.Message
        Write-LogMessage -Type WARNING -Message "Error during lifecycle content library check/association: $errorMessage. Skipping content library association."
        return [PSCustomObject]@{
            Success = $false
            ActionTaken = "error"
            ErrorMessage = $errorMessage
        }
    }
}
function Test-ContentLibraryBySubscriptionUri {

    <#
        .SYNOPSIS
        Checks for the existence of a content library with a matching SubscriptionUri.

        .DESCRIPTION
        The Test-ContentLibraryBySubscriptionUri function searches for content libraries on the specified vCenter
        and checks if any content library has a SubscriptionUri that matches the provided URL. This function
        is useful for verifying if a subscribed content library already exists before attempting to create
        a new one or to locate a specific content library by its subscription endpoint.

        The function queries all content libraries available on the vCenter and performs a case-sensitive
        match against the SubscriptionUri property. If a matching content library is found, the function
        returns the Name of that library. If no match is found, the function returns $false.

        .PARAMETER SubscriptionUri
        The subscription URL to search for. This should match the SubscriptionUri property of the content library.
        This parameter is required and must be provided when calling the function.

        .EXAMPLE
        Test-ContentLibraryBySubscriptionUri -SubscriptionUri "https://wp-content.vmware.com/v2/latest/lib.json"

        Checks for a content library with the specified subscription URI.

        .EXAMPLE
        $libraryName = Test-ContentLibraryBySubscriptionUri -SubscriptionUri "https://example.com/lib.json"
        if ($libraryName) {
            Write-LogMessage -Type INFO -Message "Found library: $libraryName"
        } else {
            Write-LogMessage -Type INFO -Message "No matching library found"
        }

        Checks for a content library and handles the result appropriately.

        .OUTPUTS
        System.String or System.Boolean
        Returns the Name of the content library if a match is found, or $false if no matching content library exists.

        .NOTES
        - Requires an active PowerCLI connection to vCenter via the $Script:vCenterName variable
        - Uses Get-ContentLibrary cmdlet to retrieve all content libraries
        - Performs case-sensitive matching against SubscriptionUri property
        - Only subscribed content libraries have a SubscriptionUri property
        - The function will return $false if no matching library is found or if errors occur
        - Integrates with the VCF PowerShell Toolbox logging infrastructure for consistent reporting

        .LINK
        Get-ContentLibrary
        New-SubscriptionBasedContentLibrary
    #>

    [CmdletBinding()]
    [OutputType([Bool])]
    Param (
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$SubscriptionUri
    )

    Write-LogMessage -Type DEBUG -Message "Entered Test-ContentLibraryBySubscriptionUri function..."

    $connectionTest = Test-VcenterConnection
    if (-not $connectionTest.IsConnected) {
        $err = "Not connected to vCenter `"$Script:vCenterName`": $($connectionTest.ErrorMessage)"
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }

    try {
        $contentLibraries = Get-ContentLibrary -Server $Script:vCenterName -ErrorAction Stop

        # Search for a content library with matching SubscriptionUri.
        foreach ($library in $contentLibraries) {
            if ($library.SubscriptionUri -eq $SubscriptionUri) {
                Write-LogMessage -Type DEBUG -Message "Found content library `"$($library.Name)`" with matching SubscriptionUri `"$SubscriptionUri`" on vCenter `"$Script:vCenterName`"."
                return $library.Name
            }
        }

        Write-LogMessage -Type DEBUG -Message "No content library found with SubscriptionUri `"$SubscriptionUri`" on vCenter `"$Script:vCenterName`"."
        return $false
    } catch [VcfDeploymentException] {
        throw  # already logged and typed — propagate without re-wrapping
    } catch {
        # Re-throw API errors so callers can distinguish a transient failure from a missing library.
        # Returning $false on error would cause callers to create a duplicate content library.
        $err = "Failed to check for content library with SubscriptionUri `"$SubscriptionUri`" on vCenter `"$Script:vCenterName`": $($_.Exception.Message)"
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }
}
function Initialize-SupervisorContentLibrary {

    <#
        .SYNOPSIS
        Initializes a content library for supervisor enablement/upgrades.

        .DESCRIPTION
        The Initialize-SupervisorContentLibrary function creates or retrieves a subscription-based
        content library for supervisor enablement and upgrades, then associates it with the supervisor
        for lifecycle operations.

        The function performs the following operations:
        1. Checks if a content library with the specified subscription URL already exists
        2. Creates a new content library if one doesn't exist, or retrieves the existing one
        3. Associates the content library with the supervisor for lifecycle operations

        .PARAMETER DatastoreName
        The name of the datastore where the content library will be stored. This parameter is required
        when creating a new content library.

        .PARAMETER LibraryName
        The name for the content library. This parameter is required when creating a new content library.
        The name must be unique within the vCenter.

        .PARAMETER SubscriptionUrl
        The subscription URL for the content library. This parameter is required and is used to identify
        existing content libraries and to create new subscribed content libraries.

        .EXAMPLE
        Initialize-SupervisorContentLibrary -DatastoreName "datastore1" -LibraryName "Supervisor-ContentLibrary" -SubscriptionUrl "https://wp-content.vmware.com/supervisor/v1/latest/lib.json"

        Initializes a content library for supervisor enablement/upgrades.

        .OUTPUTS
        None. This function does not return a value.

        .NOTES
        - Requires an active PowerCLI connection to vCenter via the $Script:vCenterName variable
        - Always creates and associates content library for supervisor enablement/upgrades (no version restrictions)
        - Uses PowerCLI cmdlets for all operations (no REST API calls needed):
          • Get-ContentLibrary (via Test-ContentLibraryBySubscriptionUri and Get-ContentLibraryId)
          • New-ContentLibrary (via New-SubscriptionBasedContentLibrary)
          • Invoke-VcenterNamespaceManagementLifecycleContentLibrariesList (via Initialize-SupervisorLifecycleContentLibrary)
          • Invoke-VcenterNamespaceManagementLifecycleContentLibrariesSet (via Initialize-SupervisorLifecycleContentLibrary)
        - All operations use the existing PowerCLI connection (no authentication parameters needed)
        - Integrates with the VCF PowerShell Toolbox logging infrastructure for consistent reporting

        .LINK
        Test-ContentLibraryBySubscriptionUri
        New-SubscriptionBasedContentLibrary
        Initialize-SupervisorLifecycleContentLibrary
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$DatastoreName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$LibraryName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$SubscriptionUrl
    )

    Write-LogMessage -Type DEBUG -Message "Entered Initialize-SupervisorContentLibrary function..."

    # Test if the content library already exists for supervisor enablement/upgrades.
    $contentLibraryName = Test-ContentLibraryBySubscriptionUri -SubscriptionUri $SubscriptionUrl
    if (-not $contentLibraryName) {
        Write-LogMessage -Type DEBUG -Message "No content library found with SubscriptionUri `"$SubscriptionUrl`" on vCenter `"$Script:vCenterName`"."
        # If not, create a new one.
        $contentLibraryId = New-SubscriptionBasedContentLibrary -DatastoreName $DatastoreName -LibraryDescription "Async patch library for supervisor" -LibraryName $LibraryName -SubscriptionUrl $SubscriptionUrl
    } else {
        Write-LogMessage -Type DEBUG -Message "Content library `"$contentLibraryName`" found with SubscriptionUri `"$SubscriptionUrl`" on vCenter `"$Script:vCenterName`"."
        $contentLibraryId = Get-ContentLibraryId -LibraryName $contentLibraryName
    }

    # Initialize lifecycle content library association for supervisor enablement/upgrades.
    if ($contentLibraryId) {
        Initialize-SupervisorLifecycleContentLibrary -ContentLibraryId $contentLibraryId | Out-Null
    } else {
        Write-LogMessage -Type WARNING -Message "Content library ID not available. Skipping lifecycle content library association."
    }
}
function Set-VclsRetreatModeForCluster {

    <#
        .SYNOPSIS
        Puts vSphere Cluster Services (vCLS) in retreat mode for a cluster using the cluster reconfigure API.

        .DESCRIPTION
        vCLS is deprecated in vCenter 9.0; retreat mode is recommended to avoid redundant resource use.
        This function uses the vSphere API ReconfigureComputeResource_Task with ClusterConfigSpecEx
        and systemVMsConfig.deploymentMode = ABSENT so vCLS VMs are not deployed for the cluster.
        On vSphere 9.0, retreat mode does not impact DRS or HA. Does not depend on vCenter advanced
        settings or PowerCLI Get/Set/New-AdvancedSetting (avoids parameter name issues in VCF PowerCLI 9).

        .PARAMETER ClusterName
        Name of the cluster to put in vCLS retreat mode.

        .PARAMETER Server
        vCenter server name. Default is $Script:vCenterName.

        .PARAMETER TaskPollIntervalSeconds
        Seconds between polls when waiting for the reconfigure task to complete. Default is 3.

        .PARAMETER RetreatMode
        When $false, the function returns immediately without making any changes. Default is $true.

        .PARAMETER TaskWaitTimeoutSeconds
        Maximum seconds to wait for the reconfigure task. Default is 120.

        .NOTES
        Non-fatal: on failure (e.g. unsupported vCenter version or API not available), logs a WARNING and returns.
        Primary path: cluster.ExtensionData.ReconfigureComputeResource_Task with ClusterSystemVmsConfigSpec.DeploymentMode = ABSENT.
    
        .EXAMPLE
        Set-VclsRetreatModeForCluster -ClusterName "edge-cluster-1"
    #>
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $false)] [Bool]$RetreatMode = $true,
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$Server = $Script:vCenterName,
        [Parameter(Mandatory = $false)] [ValidateRange(1, 60)] [Int]$TaskPollIntervalSeconds = 3,
        [Parameter(Mandatory = $false)] [ValidateRange(10, 600)] [Int]$TaskWaitTimeoutSeconds = 120
    )

    if (-not $RetreatMode) {
        Write-LogMessage -Type DEBUG -Message "Set-VclsRetreatModeForCluster: RetreatMode is false; skipping vCLS retreat mode for cluster `"$ClusterName`"."
        return
    }

    try {
        $clusterObject = Get-Cluster -Name $ClusterName -Server $Server -ErrorAction Stop
        if (-not $clusterObject -or -not $clusterObject.ExtensionData) {
            Write-LogMessage -Type WARNING -Message "Set-VclsRetreatModeForCluster: could not get cluster `"$ClusterName`" or ExtensionData. Skipping vCLS retreat mode."
            return
        }

        # Primary path: cluster reconfigure API with systemVMsConfig.deploymentMode = ABSENT (retreat mode). Avoids advanced settings and PowerCLI parameter issues.
        try {
            $clusterSystemVmsSpec = New-Object VMware.Vim.ClusterSystemVmsConfigSpec
            $clusterSystemVmsSpec.DeploymentMode = "ABSENT"
            $clusterSpec = New-Object VMware.Vim.ClusterConfigSpecEx
            $clusterSpec.SystemVMsConfig = $clusterSystemVmsSpec
            $taskRef = $clusterObject.ExtensionData.ReconfigureComputeResource_Task($clusterSpec, $true)
            if ($taskRef) {
                # Wait by polling; VCF PowerCLI Wait-Task may not accept pipeline input from this task type.
                $taskDeadline = (Get-Date).AddSeconds($TaskWaitTimeoutSeconds)
                $taskState = $null
                do {
                    $taskView = Get-View -Id $taskRef -Server $Server -Property Info -ErrorAction SilentlyContinue
                    if (-not $taskView -or -not $taskView.Info) {
                        Start-Sleep -Seconds $TaskPollIntervalSeconds
                        continue
                    }
                    $taskState = $taskView.Info.State
                    if ($taskState -eq "success") {
                        break
                    }
                    if ($taskState -eq "error") {
                        $errMsg = if ($taskView.Info.Error -and $taskView.Info.Error.LocalizedMessage) { $taskView.Info.Error.LocalizedMessage } else { "Task failed." }
                        throw [VcfDeploymentException]::new($errMsg)
                    }
                    Start-Sleep -Seconds $TaskPollIntervalSeconds
                } while ((Get-Date) -lt $taskDeadline)
                if ($taskState -ne "success") {
                    throw [VcfDeploymentException]::new("Task did not complete within $TaskWaitTimeoutSeconds seconds (state: $taskState).")
                }
            }
            Write-LogMessage -Type INFO -Message "Set vCLS to retreat mode for cluster `"$ClusterName`""
            return
        } catch {
            Write-LogMessage -Type DEBUG -Message "Set-VclsRetreatModeForCluster: cluster reconfigure API failed, falling back to OptionManager: $($_.Exception.Message)"
        }

        # Fallback: vCenter OptionManager advanced setting (for older vCenter where cluster API may not support systemVMsConfig).
        $domainId = $clusterObject.Id -replace "^[^-]+-", ""
        if ([String]::IsNullOrWhiteSpace($domainId)) {
            Write-LogMessage -Type WARNING -Message "Set-VclsRetreatModeForCluster: could not derive domain ID for fallback. Skipping vCLS retreat mode."
            return
        }
        $settingName = "config.vcls.clusters.$domainId.enabled"
        try {
            $si = Get-View -Server $Server -Id "ServiceInstance-ServiceInstance" -ErrorAction Stop
            # Content: use property (same as RetrieveServiceContent per API). Some PowerCLI builds expose Content, others use RetrieveServiceContent().
            $content = if ($si.PSObject.Properties['Content']) { $si.Content } else { $si.RetrieveServiceContent() }
            $optionManagerRef = $content.OptionManager
            if ($optionManagerRef) {
                # $content.OptionManager is a MoRef; resolve it to a live view before calling methods.
                $optionManagerView = Get-View -Id $optionManagerRef -Server $Server -ErrorAction Stop
                $optionValue = New-Object VMware.Vim.OptionValue
                $optionValue.key = $settingName
                $optionValue.value = "False"
                $optionManagerView.UpdateOptions(@($optionValue))
                Write-LogMessage -Type INFO -Message "Set vCLS to retreat mode for cluster `"$ClusterName`" (vCenter advanced setting $settingName = False) via OptionManager API."
                return
            }
        } catch {
            Write-LogMessage -Type DEBUG -Message "Set-VclsRetreatModeForCluster: OptionManager API failed: $($_.Exception.Message)"
        }

        Write-LogMessage -Type WARNING -Message "Set-VclsRetreatModeForCluster: could not set vCLS retreat mode for cluster `"$ClusterName`" (cluster API and OptionManager failed). Cluster creation succeeded; you can set retreat mode manually in vCenter (Configure > vSphere Cluster Services > Edit vCLS Mode)."
    } catch {
        Write-LogMessage -Type WARNING -Message "Set-VclsRetreatModeForCluster: could not set vCLS retreat mode for cluster `"$ClusterName`": $($_.Exception.Message). Cluster creation succeeded; you can set retreat mode manually in vCenter (Configure > vSphere Cluster Services > Edit vCLS Mode)."
    }
}

#endregion
function Write-ClusterEsxiNodeHealthReport {

    <#
        .SYNOPSIS
        Logs ESX host connection and power state for a vSphere cluster after deployment checks.

        .DESCRIPTION
        Emits a single summary line when all hosts are healthy (ConnectionState=Connected and
        PowerState=PoweredOn). When one or more hosts are unhealthy, logs a header and lists only
        the unhealthy hosts at WARNING severity so operators can triage without scrolling past
        noise for healthy hosts.

        .PARAMETER ClusterName
        The vCenter cluster display name.
    
        .EXAMPLE
        Write-ClusterEsxiNodeHealthReport -ClusterName "edge-cluster-1"
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName
    )

    try {
        $clusterObject = Get-Cluster -Name $ClusterName -Server $Script:vCenterName -ErrorAction Stop
        $vmHosts = @(Get-VMHost -Location $clusterObject -Server $Script:vCenterName -ErrorAction Stop | Sort-Object -Property Name)
        $unhealthyHosts = @($vmHosts | Where-Object { $_.ConnectionState -ne "Connected" -or $_.PowerState -ne "PoweredOn" })
        if ($unhealthyHosts.Count -eq 0) {
            Write-LogMessage -Type INFO -Message "ESX node health for cluster `"$ClusterName`" ($($vmHosts.Count) host(s)): all Connected/PoweredOn."
            return
        }
        Write-LogMessage -Type WARNING -Message "ESX node health for cluster `"$ClusterName`" ($($vmHosts.Count) host(s)): $($unhealthyHosts.Count) not Connected/PoweredOn."
        foreach ($vmHost in $unhealthyHosts) {
            Write-LogMessage -Type WARNING -Message "  $($vmHost.Name): ConnectionState=$($vmHost.ConnectionState), PowerState=$($vmHost.PowerState)."
        }
    } catch {
        Write-LogMessage -Type WARNING -Message "Could not list ESX host health for cluster `"$ClusterName`": $($_.Exception.Message)"
    }
}
function Write-SupervisorHealthReport {

    <#
        .SYNOPSIS
        Logs a concise supervisor health summary after deployment, surfacing only non-healthy findings.

        .DESCRIPTION
        Queries the supervisor summary via Invoke-GetSupervisorNamespaceManagementSummary (and
        conditions via Invoke-GetSupervisorNamespaceManagementConditions when available) and logs a
        single INFO line when the supervisor is healthy (ConfigStatus=RUNNING, KubernetesStatus=READY,
        no ERROR/WARNING summary messages, all conditions Status=True). When any check is not
        healthy, delegates to Write-SupervisorKubernetesDiagnosticReport for the full diagnostic
        output. Non-fatal if the API is unavailable.

        .PARAMETER ClusterName
        The vCenter cluster display name (for log context).

        .PARAMETER SupervisorId
        Supervisor resource identifier.
    
        .EXAMPLE
        Write-SupervisorHealthReport -ClusterName "edge-cluster-1" -SupervisorId "domain-c123"
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$SupervisorId
    )

    $cmdSummary = Get-Command Invoke-GetSupervisorNamespaceManagementSummary -ErrorAction SilentlyContinue
    if (-not $cmdSummary) {
        Write-LogMessage -Type DEBUG -Message "Write-SupervisorHealthReport: Invoke-GetSupervisorNamespaceManagementSummary is not available; skipping post-deployment supervisor health report."
        return
    }

    try {
        $summary = Invoke-GetSupervisorNamespaceManagementSummary -Supervisor $SupervisorId -ErrorAction Stop
    } catch {
        Write-LogMessage -Type WARNING -Message "Could not read supervisor health for cluster `"$ClusterName`" (supervisor `"$SupervisorId`"): $($_.Exception.Message)"
        return
    }

    $configStatus = $summary.ConfigStatus
    $kubernetesStatus = $summary.KubernetesStatus
    $summaryMessages = @($summary.Messages)
    $nonInfoMessages = @($summaryMessages | Where-Object {
        $severityText = if ($null -ne $_.Severity) { $_.Severity.ToString() } else { "" }
        $severityText -match "^(ERROR|CRITICAL|WARNING|WARN)$"
    })

    $nonTrueConditions = @()
    $cmdConditions = Get-Command Invoke-GetSupervisorNamespaceManagementConditions -ErrorAction SilentlyContinue
    if ($cmdConditions) {
        try {
            $conditions = @(Invoke-GetSupervisorNamespaceManagementConditions -Supervisor $SupervisorId -ErrorAction Stop)
            $nonTrueConditions = @($conditions | Where-Object { $_.Status -ne "True" -and -not [String]::IsNullOrWhiteSpace($_.Status) })
        } catch {
            Write-LogMessage -Type DEBUG -Message "Supervisor conditions API failed for cluster `"$ClusterName`" (supervisor `"$SupervisorId`"): $($_.Exception.Message)"
        }
    }

    $isHealthy = ($configStatus -eq "RUNNING") -and ($kubernetesStatus -eq "READY") -and ($nonInfoMessages.Count -eq 0) -and ($nonTrueConditions.Count -eq 0)
    if ($isHealthy) {
        Write-LogMessage -Type INFO -Message "Supervisor health for cluster `"$ClusterName`" (supervisor `"$SupervisorId`"): ConfigStatus=RUNNING, KubernetesStatus=READY, no outstanding messages or conditions."
        return
    }

    # Delegate to the full diagnostic report so operators can see summary messages and condition details.
    Write-SupervisorKubernetesDiagnosticReport -ClusterName $ClusterName -Context "post-deployment health (ConfigStatus=$configStatus, KubernetesStatus=$kubernetesStatus)" -SupervisorId $SupervisorId
}
function Write-VsanClusterHealthReport {

    <#
        .SYNOPSIS
        Logs a concise vSAN cluster health summary after deployment, surfacing only non-green findings.

        .DESCRIPTION
        Calls Get-VsanClusterHealthSummaryViaView with FetchFromCache=$true so the latest cached
        result (refreshed by Invoke-VsanClusterHealthRetestAfterDeployment) is reported. Logs a
        single INFO line when overallHealth is green; otherwise logs a header plus the non-green
        group/test entries at WARNING severity. Non-fatal when the vSAN Health API is unavailable.

        .PARAMETER ClusterName
        The vSAN cluster name.
    
        .EXAMPLE
        Write-VsanClusterHealthReport -ClusterName "edge-cluster-1"
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName
    )

    $healthSummary = Get-VsanClusterHealthSummaryViaView -ClusterName $ClusterName -FetchFromCache
    if (-not $healthSummary) {
        Write-LogMessage -Type WARNING -Message "vSAN health for cluster `"$ClusterName`": summary not available from vCenter. Check vSAN Health in the UI."
        return
    }

    $overallHealth = $healthSummary.overallHealth
    if ($overallHealth -eq "green") {
        Write-LogMessage -Type INFO -Message "vSAN health for cluster `"$ClusterName`": overallHealth=green."
        return
    }

    $overallDescription = $healthSummary.overallHealthDescription
    $descriptionSuffix = if (-not [String]::IsNullOrWhiteSpace($overallDescription)) { " ($overallDescription)" } else { "" }
    $headerLine = "vSAN health for cluster `"$ClusterName`": overallHealth=$overallHealth$descriptionSuffix."
    Write-LogMessage -Type WARNING -Message $headerLine

    # List only non-green tests so Connected/healthy checks are not shown.
    $healthGroups = $healthSummary.groups
    if (-not $healthGroups) {
        return
    }
    foreach ($healthGroup in @($healthGroups)) {
        $groupName = $healthGroup.PSObject.Properties["groupName"].Value
        $groupTests = $healthGroup.PSObject.Properties["tests"].Value
        if (-not $groupTests) {
            continue
        }
        foreach ($test in @($groupTests)) {
            $testHealth = $test.PSObject.Properties["health"].Value
            if (-not $testHealth -or $testHealth -eq "green") {
                continue
            }
            $testName = $test.PSObject.Properties["testName"].Value
            Write-LogMessage -Type WARNING -Message "  [$testHealth] $groupName / $testName"
        }
    }
}
function Write-SupervisorApiSummaryMessages {

    <#
    .SYNOPSIS
        Logs supervisor summary messages returned by the vCenter namespace-management API.
    .DESCRIPTION
        Iterates the messages array from a supervisor summary response, formats severity and
        detail text (including AdditionalProperties fallback), maps severity to a log level, and
        emits each message via Write-LogMessage. Emits actionable guidance for known patterns
        such as IP pool utilization warnings.
    .PARAMETER Messages
        Array of supervisor summary message objects from Invoke-GetSupervisorNamespaceManagementSummary.
    .EXAMPLE
        Write-SupervisorApiSummaryMessages -Messages @($summary.Messages)
    .NOTES
        Called by Write-SupervisorKubernetesDiagnosticReport.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [Object[]]$Messages
    )

    $summaryMessages = @($Messages)
    if ($summaryMessages.Count -gt 0) {
        Write-LogMessage -Type INFO -Message "Supervisor summary messages ($($summaryMessages.Count)):"
        foreach ($msg in $summaryMessages) {
            $severityText = if (-not [String]::IsNullOrWhiteSpace($msg.Severity)) { $msg.Severity.ToString() } else { "" }
            $detailsText = ""
            if ($null -ne $msg.Details) {
                $detailsText = $msg.Details.Localized
                if ([String]::IsNullOrWhiteSpace($detailsText)) { $detailsText = $msg.Details.DefaultMessage }
            }
            if ([String]::IsNullOrWhiteSpace($detailsText) -and $null -ne $msg.AdditionalProperties) {
                $apDict = [System.Collections.Generic.IDictionary[string, object]]$msg.AdditionalProperties
                foreach ($apKey in @("message", "detail", "text", "description")) {
                    $apVal = $null
                    if ($apDict.TryGetValue($apKey, [Ref]$apVal) -and -not [String]::IsNullOrWhiteSpace($apVal)) {
                        if ([String]::IsNullOrWhiteSpace($detailsText)) { $detailsText = $apVal.ToString() }
                        elseif ($apKey -ne "message") { $detailsText = "$detailsText Details: '$($apVal.ToString())'." }
                    }
                }
                if ([String]::IsNullOrWhiteSpace($severityText)) {
                    $apSev = $null
                    if ($apDict.TryGetValue("severity", [Ref]$apSev) -and -not [String]::IsNullOrWhiteSpace($apSev)) { $severityText = $apSev.ToString() }
                }
            }
            if ([String]::IsNullOrWhiteSpace($detailsText)) { $detailsText = "(no details)" }
            $messageId = $msg.Id
            $detailsId = if ($null -ne $msg.Details) { $msg.Details.Id } else { $null }
            $kbLink = $msg.KbArticleLink
            $logType = switch -Regex ($severityText) {
                "^(ERROR|CRITICAL)$" { "ERROR"; break }
                "^(WARNING|WARN)$"   { "WARNING"; break }
                default              { "INFO" }
            }
            $line = "  [$severityText] $detailsText"
            $idText = if (-not [String]::IsNullOrWhiteSpace($messageId)) { $messageId } else { $detailsId }
            if (-not [String]::IsNullOrWhiteSpace($idText)) { $line = "$line (id: $idText)" }
            if (-not [String]::IsNullOrWhiteSpace($kbLink)) { $line = "$line KB: $kbLink" }
            Write-LogMessage -Type $logType -Message $line
            switch -Regex ($detailsText) {
                "IPPool.*utilization|utilization.*IPPool|low on free IP" {
                    Write-LogMessage -Type WARNING -Message "  ^ IP pool utilization is high. If a supervisor service (Harbor or Argo CD) subsequently fails with 'exhausted all IP addresses in requested IPPools', increase `"siteSpec[N].primaryWorkloadNetwork.primaryWorkloadNetworkIPCount`" in supervisor.json and redeploy."
                    break
                }
            }
        }
    } else {
        Write-LogMessage -Type INFO -Message "No summary messages from the API (check Workload Management in the UI if status is not READY)."
    }
}
function Write-SupervisorKubernetesDiagnosticReport {

    <#
        .SYNOPSIS
        Logs supervisor Kubernetes status messages and conditions from the vCenter namespace-management APIs.

        .DESCRIPTION
        Surfaces the same class of information shown under Kubernetes Status in the vCenter UI (summary
        messages such as workload network IP pool utilization, plus supervisor conditions when the API is available).

        .PARAMETER ClusterName
        Cluster name for log context.

        .PARAMETER Context
        Short phrase describing why diagnostics are being shown (for example timeout or Harbor failure).

        .PARAMETER SupervisorId
        Supervisor resource identifier passed to Invoke-GetSupervisorNamespaceManagementSummary.
    
        .EXAMPLE
        Write-SupervisorKubernetesDiagnosticReport -ClusterName "edge-cluster-1" -SupervisorId "domain-c123"
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $false)] [String]$Context,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$SupervisorId
    )

    $cmdSummary = Get-Command Invoke-GetSupervisorNamespaceManagementSummary -ErrorAction SilentlyContinue
    if (-not $cmdSummary) {
        Write-LogMessage -Type DEBUG -Message "Write-SupervisorKubernetesDiagnosticReport: Invoke-GetSupervisorNamespaceManagementSummary is not available."
        return
    }

    $headerSuffix = "cluster `"$ClusterName`", supervisor `"$SupervisorId`""
    $header = if ([String]::IsNullOrWhiteSpace($Context)) {
        "Supervisor Kubernetes diagnostics ($headerSuffix)"
    } else {
        "Supervisor Kubernetes diagnostics — $Context ($headerSuffix)"
    }
    Write-LogMessage -Type INFO -Message "======== $header ========"
    Write-LogMessage -Type INFO -Message "Kubernetes Status in the UI indicates whether the Supervisor is operable; messages below mirror the supervisor summary API."

    try {
        $summary = Invoke-GetSupervisorNamespaceManagementSummary -Supervisor $SupervisorId -ErrorAction Stop
    } catch {
        Write-LogMessage -Type WARNING -Message "Could not read supervisor summary from vCenter: $($_.Exception.Message)"
        Write-LogMessage -Type INFO -Message "======== End supervisor Kubernetes diagnostics ========"
        return
    }

    Write-LogMessage -Type INFO -Message "ConfigStatus: $($summary.ConfigStatus); KubernetesStatus: $($summary.KubernetesStatus)."

    if ($null -ne $summary.Stats) {
        $st = $summary.Stats
        # Render utilization as percentages at INFO (easy to parse); keep absolute values at DEBUG.
        $cpuPercent = if ($st.CpuCapacity -gt 0) { [Math]::Round(($st.CpuUsed / $st.CpuCapacity) * 100, 1) } else { 0 }
        $memoryPercent = if ($st.MemoryCapacity -gt 0) { [Math]::Round(($st.MemoryUsed / $st.MemoryCapacity) * 100, 1) } else { 0 }
        $storagePercent = if ($st.StorageCapacity -gt 0) { [Math]::Round(($st.StorageUsed / $st.StorageCapacity) * 100, 1) } else { 0 }
        Write-LogMessage -Type INFO -Message "Summary utilization: CPU=$cpuPercent% Memory=$memoryPercent% Storage=$storagePercent%."
        Write-LogMessage -Type DEBUG -Message "Summary stats (absolute): CpuUsed=$($st.CpuUsed) CpuCapacity=$($st.CpuCapacity) MemoryUsed=$($st.MemoryUsed) MemoryCapacity=$($st.MemoryCapacity) StorageUsed=$($st.StorageUsed) StorageCapacity=$($st.StorageCapacity)."
    }

    Write-SupervisorApiSummaryMessages -Messages @($summary.Messages)

    $cmdConditions = Get-Command Invoke-GetSupervisorNamespaceManagementConditions -ErrorAction SilentlyContinue
    if ($cmdConditions) {
        try {
            $conditions = @(Invoke-GetSupervisorNamespaceManagementConditions -Supervisor $SupervisorId -ErrorAction Stop)
            if ($conditions.Count -gt 0) {
                Write-LogMessage -Type INFO -Message "Supervisor conditions ($($conditions.Count)):"
                foreach ($condition in $conditions) {
                    $descriptionText = $condition.Description
                    if ($descriptionText -and $descriptionText.Length -gt 400) {
                        $descriptionText = "$($descriptionText.Substring(0, 400))..."
                    }
                    $conditionMessages = $condition.Messages
                    $joinedMessages = if ($conditionMessages -and $conditionMessages.Count -gt 0) {
                        ($conditionMessages | ForEach-Object { $_.ToString() }) -join "; "
                    } else {
                        ""
                    }
                    Write-LogMessage -Type INFO -Message "  Type=$($condition.Type) Status=$($condition.Status) Severity=$($condition.Severity) Reason=$($condition.Reason) Description=$descriptionText Messages=$joinedMessages"
                    if ($condition.Status -ne "True" -and -not [String]::IsNullOrWhiteSpace($condition.Status)) {
                        Write-LogMessage -Type WARNING -Message "  ^ Condition Status is not True; see Reason/Description/Messages above."
                    }
                }
            }
        } catch {
            Write-LogMessage -Type DEBUG -Message "Supervisor conditions API failed: $($_.Exception.Message)"
        }
    }

    Write-LogMessage -Type INFO -Message "======== End supervisor Kubernetes diagnostics ========"
}
