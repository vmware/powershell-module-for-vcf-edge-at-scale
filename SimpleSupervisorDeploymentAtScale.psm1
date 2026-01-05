# Copyright (c) 2025 Broadcom. All Rights Reserved.
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
# PowerShell Module: SimpleSupervisorDeploymentAtScale
# Module Version: 1.0.0.3
# Last modified: 2025-12-30
#

# Module-level variables
$Script:ModuleVersion = '1.0.0.3'

# Set platform-specific command names for cross-platform compatibility.
$Script:ArgocdCmd = if ($isWindows) { "argocd.exe" } else { "argocd" }
$Script:KubectlCmd = if ($isWindows) { "kubectl.exe" } else { "kubectl" }
$Script:VcfCmd = if ($isWindows) { "vcf.exe" } else { "vcf" }

# Define log level hierarchy (lower number = lower priority, higher number = higher priority)
$Script:LogLevelHierarchy = @{
    "DEBUG" = 0
    "INFO" = 1
    "ADVISORY" = 2
    "WARNING" = 3
    "EXCEPTION" = 4
    "ERROR" = 5
}

# Initialize log level (will be set by Start-SimpleSupervisorDeploymentAtScale)
$Script:ConfiguredLogLevel = "INFO"

# =============================================================================
# Internal Functions (Not Exported)
# =============================================================================

Function Test-LogLevel {

    <#
        .SYNOPSIS
        Determines if a message should be displayed based on the configured log level.

        .DESCRIPTION
        Compares the message type against the configured log level threshold to determine
        if the message should be displayed on screen. All messages are always written to
        the log file regardless of level.

        The log level hierarchy from lowest to highest is:
        DEBUG < INFO < ADVISORY < WARNING < EXCEPTION < ERROR

        .PARAMETER MessageType
        The type/severity of the log message to check.

        .PARAMETER ConfiguredLevel
        The minimum log level configured for screen output.

        .EXAMPLE
        Test-LogLevel -MessageType "DEBUG" -ConfiguredLevel "INFO"
        Returns $false because DEBUG is below INFO threshold.

        .EXAMPLE
        Test-LogLevel -MessageType "ERROR" -ConfiguredLevel "INFO"
        Returns $true because ERROR is at or above INFO threshold.

        .OUTPUTS
        Boolean
        Returns $true if the message should be displayed, $false otherwise.

    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ConfiguredLevel,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$MessageType

    )

    $messageLevel = $Script:LogLevelHierarchy[$MessageType]
    $configuredLevelValue = $Script:LogLevelHierarchy[$ConfiguredLevel]

    return ($messageLevel -ge $configuredLevelValue)
}


Function Write-ErrorAndReturn {

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

        .PARAMETER ErrorMessage
        The error message to log and include in the result.

        .PARAMETER ErrorCode
        Optional error code for categorization. Defaults to "ERR_UNKNOWN".

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
                return Write-ErrorAndReturn -ErrorMessage "Failed to add host to VDS" -ErrorCode "ERR_VDS_ADD_HOST"
            }
        }

        .EXAMPLE
        # Caller checks result and decides how to handle.
        $result = Add-HostToVDS -Hostname $esxHost -VdsName $vdsName
        if (-not $result.Success) {
            Write-LogMessage -Type ERROR -Message "VDS configuration failed: $($result.ErrorMessage)"
            throw "Deployment failed. Check logs for details."  # Main workflow decides to throw
        }

        .OUTPUTS
        PSCustomObject
        Returns an object with Success=$false, ErrorMessage, and ErrorCode properties.

        .NOTES
        Error Handling: This is a utility function used by other functions to return
        standardized error objects. Do NOT use 'exit 1' in helper functions; use this
        function instead to allow the caller to control error handling.

    #>

    Param(
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$ErrorCode = "ERR_UNKNOWN",
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ErrorMessage

    )

    Write-LogMessage -Type ERROR -Message $ErrorMessage

    return @{
        Success = $false
        ErrorMessage = $ErrorMessage
        ErrorCode = $ErrorCode
    }
}
Function Get-CleanErrorMessage {

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
        Write-LogMessage -Type ERROR -Message "Operation failed: $cleanError"

        Extracts a clean error message from an exception and logs it.

        .EXAMPLE
        $cleanMessage = Get-CleanErrorMessage -ErrorMessage $errorResponse
        if ($cleanMessage) {
            Write-Host "Error: $cleanMessage"
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

    Param(
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
Function Get-EnvironmentSetup {

    <#
        .SYNOPSIS
        Collects and logs system environment information for troubleshooting purposes.

        .DESCRIPTION
        The Get-EnvironmentSetup function gathers detailed information about the current
        runtime environment including PowerShell version, PowerCLI modules, and operating
        system details. This information is automatically logged to help with troubleshooting
        and support scenarios. The function handles cross-platform differences for Windows,
        macOS, and Linux systems.

        Information collected includes:
        - PowerShell version
        - VCF.PowerCLI module version (if installed)
        - VMware.PowerCLI module version (if installed)
        - PowerShell-YAML module version (if installed)
        - Operating system name and version (with platform-specific enhancements)

        .EXAMPLE
        Get-EnvironmentSetup
        Collects environment information and logs it to the current log file.

        .NOTES
        This function is typically called automatically when a new log file is created.
        It uses platform-specific commands (sw_vers on macOS, Get-ComputerInfo on Windows)
        to provide enhanced OS information beyond the basic PowerShell automatic variables.
        All output is suppressed from the console and only written to the log file.
    #>

    Write-LogMessage -Type DEBUG -Message "Entered Get-EnvironmentSetup function..."

    # Get PowerShell version information.
    $powerShellRelease = $($PSVersionTable.PSVersion).ToString()

    # Check for installed PowerCLI modules (VCF and VMware versions).
    $vcfPowerCliRelease = (Get-Module -ListAvailable -Name VCF.PowerCLI -ErrorAction SilentlyContinue | Sort-Object Revision | Select-Object -First 1).Version
    $vmwarePowerCliRelease = (Get-Module -ListAvailable -Name VMware.PowerCLI -ErrorAction SilentlyContinue | Sort-Object Revision | Select-Object -First 1).Version

    # If the module is not installed, set the release to "N/A".
    if ($null -eq $vcfPowerCliRelease) {
        $vcfPowerCliRelease = "N/A"
    }
    if ($null -eq $vmwarePowerCliRelease) {
        $vmwarePowerCliRelease = "N/A"
    }

    # Start with basic OS information from PowerShell automatic variables.
    $operatingSystem = $($PSVersionTable.OS)

    # Enhanced macOS information - sw_vers provides more user-friendly OS details than Darwin kernel info.
    if ($IsMacOS) {
        try {
            $macOsName = (sw_vers --productName)
            $macOsRelease = (sw_vers --productVersion)
            $macOsVersion = "$macOsName $macOsRelease"
        } catch [Exception] {
            # If sw_vers fails, we'll fall back to the basic OS info from $PSVersionTable.
        }
    }
    if ($macOsVersion) {
        $operatingSystem = $macOsVersion
    }

    # Enhanced Windows information - Get-ComputerInfo provides more detailed OS information.
    if ($IsWindows) {
        try {
            $windowsProductInformation = (Get-ComputerInfo -ProgressAction SilentlyContinue) | Select-Object OSName,OSVersion
            $windowsVersion = "$($windowsProductInformation.OSName) $($windowsProductInformation.OSVersion)"
        } catch [Exception] {
            # If Get-ComputerInfo fails, we'll fall back to the basic OS info from $PSVersionTable.
        }
    }
    if ($windowsVersion) {
        $operatingSystem = $windowsVersion
    }

    Write-LogMessage -Type DEBUG -Message "Client PowerShell version is $powerShellRelease"

    if ($vcfPowerCliRelease) {
        Write-LogMessage -Type DEBUG -Message "Client VCF.PowerCLI version is $vcfPowerCliRelease."
    }
    if ($vmwarePowerCliRelease) {
        Write-LogMessage -Type DEBUG -Message "Client VMware.PowerCLI version is $vmwarePowerCliRelease."
    }
    if (-not $vcfPowerCliRelease) {
        Write-LogMessage -Type ERROR -Message "VCF.PowerCLI not installed. Please install VCF.PowerCLI module."
        throw "Deployment failed. Check logs for details."
    }

    Write-LogMessage -Type DEBUG  -Message "Client Operating System is $operatingSystem"

}
Function New-LogFile {

    <#
        .SYNOPSIS
        Creates a log file with automatic directory structure and environment logging.

        .DESCRIPTION
        The New-LogFile function establishes the logging infrastructure for the VCF PowerShell
        Toolbox by creating a timestamped log file in a specified directory. The function creates
        one log file using the format mm-dd-yyyy, ensuring logs are organized chronologically.
        If the log directory doesn't exist, it will be created automatically. When a new log file
        is created, the function automatically calls Get-EnvironmentSetup to record system
        information for troubleshooting purposes.

        The function sets the following script-scoped variables:
        - $Script:LogFolder: Path to the log directory
        - $Script:LogFile: Full path to the current log file

        .PARAMETER Prefix
        Specifies the prefix for the log file name. The final log file will be named
        "{Prefix}-{mm-dd-yyyy}.log". Default value is "VCF.PS.Toolbox".

        .PARAMETER Directory
        Specifies the directory name where log files will be stored, relative to the script root.
        The directory will be created if it doesn't exist. Default value is "logs".

        .EXAMPLE
        New-LogFile
        Creates a log file with default settings: "logs/VCF.PS.Toolbox-01-15-2024.log"

        .EXAMPLE
        New-LogFile -Directory "audit" -Prefix "SecurityAudit"
        Creates a log file: "audit/SecurityAudit-01-15-2024.log"

        .NOTES
        This function should be called before any Write-LogMessage calls to ensure the log
        infrastructure is properly initialized. The function will exit the script if it
        cannot create the required log directory.
    #>

    Param (
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$Directory = "logs",
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$Prefix = "SimpleSupervisorDeploymentAtScale"
    )

    # Generate timestamp for daily log file naming (yyyy-MM-dd format)
    $fileTimeStamp = Get-Date -Format "yyyy-MM-dd"

    # Set script-scoped variables for log directory and file paths.
    $Script:LogFolder = Join-Path -Path $PSScriptRoot -ChildPath $Directory
    $Script:LogFile = Join-Path -Path $Script:LogFolder -ChildPath "$Prefix-$fileTimeStamp.log"

    # Create log directory if it doesn't exist.
    if (-not (Test-Path -Path $Script:LogFolder -PathType Container) ) {
        Write-Information "LogFolder not found, creating $Script:LogFolder" -InformationAction Continue
        New-Item -ItemType Directory -Path $Script:LogFolder | Out-Null
        if (-not $?) {
            Write-Information "Failed to create directory $Script:LogFile. Exiting." -InformationAction Continue
            throw "Deployment failed. Check logs for details."
        }
    }

    # Create the log file if it doesn't exist for today.
    # When creating a new log file, automatically capture environment details for troubleshooting.
    if (-not (Test-Path $Script:LogFile)) {
        New-Item -Type File -Path $Script:LogFile | Out-Null
        Get-EnvironmentSetup
    }
}
Function Write-LogMessage {

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

        .EXAMPLE
        Write-LogMessage -Type INFO -Message "Process started successfully"
        Displays an informational message in green on the console and writes the message to the log file.

        .EXAMPLE
        Write-LogMessage -Type ERROR -Message "Failed to connect to server" -PrependNewLine
        Displays an error message in red with a blank line before it, and logs it to the file.

        .EXAMPLE
        Write-LogMessage -Type WARNING -Message "Configuration file not found, using defaults" -SuppressOutputToScreen
        Writes a warning message to the log file only, without displaying it on the console.

        .EXAMPLE
        Write-LogMessage -Type ADVISORY -Message "Consider updating your configuration" -SuppressOutputToFile
        Displays an advisory message on the console only, without writing it to the log file.

        .EXAMPLE
        Write-LogMessage -Type DEBUG -Message "Variable value: $myVar = $($myVar)"
        Displays a debug message in gray on the console (only if log level is DEBUG) and writes it to the log file.

        .NOTES
        This function relies on the Script:LogFile, Script:LogOnly, and Script:configuredLogLevel variables being set.
        The log file path should be established using the New-LogFile function before calling this function.
        The Script:configuredLogLevel should be set during script initialization.
    #>

    Param (
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [Switch]$AppendNewLine,
        [Parameter(Mandatory = $true)] [AllowEmptyString()] [String]$Message,
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [Switch]$PrependNewLine,
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [Switch]$SuppressOutputToFile,
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [Switch]$SuppressOutputToScreen,
        [Parameter(Mandatory = $false)] [ValidateSet("INFO", "ERROR", "WARNING", "EXCEPTION", "ADVISORY", "DEBUG")] [String]$Type = "INFO"
    )

    # Define color mapping for different message types.
    $msgTypeToColor = @{
        "INFO" = "Green";
        "ERROR" = "Red" ;
        "WARNING" = "Yellow" ;
        "ADVISORY" = "Yellow" ;
        "EXCEPTION" = "Cyan";
        "DEBUG" = "Gray"
    }

    # Get the appropriate color for the message type.
    $messageColor = $msgTypeToColor.$Type

    # Create timestamp for log file entries (yyyy-MM-dd_HH:mm:ss format)
    $timeStamp = Get-Date -Format "yyyy-MM-dd_HH:mm:ss"

    # Determine if message should be displayed based on log level threshold.
    $shouldDisplay = Test-LogLevel -MessageType $Type -ConfiguredLevel $Script:ConfiguredLogLevel

    # Add blank line before message if requested and not in log-only mode and meets log level threshold.
    if ($PrependNewLine -and (-not ($Script:LogOnly -eq "enabled")) -and $shouldDisplay) {
        Write-Output ""
    }

    # Display message to console with color coding (unless suppressed, in log-only mode, or below log level threshold).
    if (-not $SuppressOutputToScreen -and $Script:LogOnly -ne "enabled" -and $shouldDisplay) {
        Write-Host -ForegroundColor $messageColor "[$Type] $Message"
    }

    # Add blank line after message if requested and not in log-only mode and meets log level threshold.
    if ($AppendNewLine -and (-not ($Script:LogOnly -eq "enabled")) -and $shouldDisplay) {
        Write-Output ""
    }

    # Write message to log file (unless suppressed).
    if (-not $SuppressOutputToFile) {
        # Only attempt to write to log file if it's been initialized and path is valid.
        if ($Script:LogFile -and -not [string]::IsNullOrWhiteSpace($Script:LogFile)) {
            $logContent = '[' + $timeStamp + '] ' + '(' + $Type + ')' + ' ' + $Message
            try {
                # Ensure the log file directory exists.
                $logDir = Split-Path -Path $Script:LogFile -Parent -ErrorAction SilentlyContinue
                if ($logDir -and -not (Test-Path -Path $logDir -ErrorAction SilentlyContinue)) {
                    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
                }
                Add-Content -Path $Script:LogFile -Value $logContent -ErrorAction Stop
            }
            catch {
                # Handle log file write failures gracefully - only show error if log file was expected.
                # Silently ignore if log file wasn't initialized (e.g., standalone function calls)
                # Don't show error message to avoid cluttering output when function is called standalone.
            }
        }
        # If log file is not initialized, silently skip file logging (function may be called standalone)
    }
}
Function Show-Version {

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

    Param (
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [Switch]$Silence
    )

    Write-LogMessage -Type DEBUG -Message "Entered Show-Version function..."

    if (-not $Silence) {
        Write-LogMessage -Type INFO -Message "Version: $Script:ModuleVersion"
    } else {
        Write-LogMessage -Type DEBUG -Message "Script Version: $Script:ModuleVersion"
    }
}
Function Connect-Vcenter {

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
        Using PSCredential objects ensures that passwords are handled securely and not exposed in plain text.

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
        $securePassword = Read-Host "Enter ESX password" -asSecureString
        $credential = New-Object System.Management.Automation.PSCredential("root", $securePassword)
        Connect-Vcenter -serverName "ESX-host.example.com" -serverCredential $credential -serverType "ESX"

        Connects to an ESX host using a PSCredential object created from secure input.

        .EXAMPLE
        Connect-Vcenter -ServerName $Script:VCenterName -ServerCredential $vCenterCredential -ServerType "vCenter"
        Connect-Vcenter -ServerName $esxHost -ServerCredential $esxCredential -ServerType "ESX"

        Example of connecting to both vCenter and ESX host in sequence using variables.

        .NOTES
        - Requires VMware PowerCLI to be installed and imported before execution
        - The function gracefully handles existing connections and provides detailed information about current sessions
        - Existing connections are detected using $Global:DefaultViServers and the function returns without attempting duplicate connections
        - Connection failures are logged with detailed error information and terminate script execution with exit code 1
        - The function integrates with the VCF PowerShell Toolbox logging infrastructure for consistent reporting
        - Both server types use the same underlying VMware PowerCLI Connect-VIServer cmdlet
        - Username information is displayed for existing connections when available from the connection context
        - Connection attempts use SuppressOutputToScreen for initial connection messages to reduce console verbosity
        - Successful connections are confirmed with informational messages for audit trail purposes
        - Function is designed for use in deployment scenarios where reliable server connectivity is critical


    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [PSCredential]$ServerCredential,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ServerName,

        [Parameter(Mandatory = $true)] [ValidateSet("vCenter", "ESX")] [String]$ServerType
    )

    Write-LogMessage -Type DEBUG -Message "Entered Connect-Vcenter function..."

    # Check if we're already connected to this vCenter to avoid duplicate connections.
    $connectedVcenter = $Global:DefaultViServers | Where-Object {$_.name -eq $ServerName -and $_.IsConnected -eq "true"}

    if (-not $connectedVcenter) {
        # Attempt to establish a new connection to the vCenter.  If it fails, exit the script.
        try {
            Write-LogMessage -Type DEBUG -Message "Attempting to connect to $ServerType Server `"$ServerName`"..."
            Connect-VIServer -Server $ServerName -Credential $ServerCredential -ErrorAction Stop | Out-Null
        } catch [System.TimeoutException] {
            Write-LogMessage -Type ERROR -Message "Cannot connect to $ServerType Server `"$ServerName`" due to network/timeout issues: $_"
            throw "Deployment failed. Check logs for details."
        }
        catch {
            # Extract clean error message.

            $errorMessage = $_.Exception.Message

            # Check for SSL/TLS connection errors.

            if ($errorMessage -match "SSL connection could not be established|SSL|certificate") {
                Write-LogMessage -Type ERROR -Message "Failed to establish SSL connection to $ServerType `"$ServerName`"."
                Write-Host ""
                Write-LogMessage -Type ERROR -Message "Common causes and solutions:"
                Write-LogMessage -Type ERROR -Message "  1. Self-signed or untrusted SSL certificate"
                Write-LogMessage -Type ERROR -Message "     Solution: Configure PowerCLI to ignore invalid certificates:"
                Write-LogMessage -Type ERROR -Message "     Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:`$false"
                Write-Host ""
                Write-LogMessage -Type ERROR -Message "  2. TLS protocol version mismatch"
                Write-LogMessage -Type ERROR -Message "     Solution: Enable TLS 1.2 in PowerShell:"
                Write-LogMessage -Type ERROR -Message "     [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12"
                Write-Host ""
                Write-LogMessage -Type ERROR -Message "  3. Network connectivity or firewall blocking HTTPS (port 443)"
                Write-LogMessage -Type ERROR -Message "     Solution: Verify network connectivity: Test-NetConnection -ComputerName $ServerName -Port 443"
                Write-Host ""
                Write-LogMessage -Type ERROR -Message "Full error details: $errorMessage"
            }
            # Check for authentication errors.

            elseif ($errorMessage -match "incorrect user name or password|authentication|credentials") {
                Write-LogMessage -Type ERROR -Message "Failed to connect to $ServerType `"$ServerName`": Authentication failed."
                Write-LogMessage -Type ERROR -Message "Please verify the username and password are correct."
                Write-Host ""
                Write-LogMessage -Type DEBUG -Message "Full error details: $errorMessage"
                # Throw immediately for authentication failures to prevent further execution.
                throw "Authentication failed"
            }
            # Generic connection error
            else {
                Write-LogMessage -Type ERROR -Message "Failed to connect to $ServerType `"$ServerName`"."
                Write-LogMessage -Type ERROR -Message "Error details: $errorMessage"
            }

            throw "Deployment failed. Check logs for details."
        }
        Write-LogMessage -Type DEBUG -Message "Successfully connected to $ServerType `"$ServerName`"."
    } else {
        # Connection already exists.  Surface the data on what user the connection is using.
        $existingUsername = ($Global:DefaultVIServers | Where-Object {$_.Name -eq $ServerName }).User
        if ($existingUsername) {
            Write-LogMessage -Type WARNING -Message "Already connected to $ServerType `"$ServerName`" as `"$existingUsername`"."
        } else {
            Write-LogMessage -Type WARNING -Message "Already connected to $ServerType `"$ServerName`"."
        }
    }
}

Function Test-VcenterConnection {

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
        If not specified, uses $Script:VCenterName.

        .PARAMETER SkipConnectivityTest
        When specified, only checks if a session exists without making an API call.
        This is faster but doesn't verify the connection is still alive (useful if you
        just want to check session existence, not actual connectivity).

        .OUTPUTS
        System.Management.Automation.PSCustomObject
        Returns an object with the following properties:
        - IsConnected: Boolean indicating if connection exists and is valid
        - ServerName: The server name that was tested
        - SessionAge: TimeSpan indicating how long the session has been active
        - ErrorMessage: Error message if connection is invalid (null if connected)

        .EXAMPLE
        # Check connection before critical operation (uses $Script:VCenterName by default)
        $connectionTest = Test-VcenterConnection
        if (-not $connectionTest.IsConnected) {
            Write-LogMessage -Type ERROR -Message "Not connected to vCenter `"$Script:VCenterName`": $($connectionTest.ErrorMessage)"
            throw "Deployment failed. Check logs for details."
        }

        .EXAMPLE
        # Fast check without API call.

        $sessionExists = Test-VcenterConnection -SkipConnectivityTest
        if ($sessionExists.IsConnected) {
            Write-LogMessage -Type DEBUG -SuppressOutputToFile -Message "Session exists for `"$($sessionExists.ServerName)`" (age: $($sessionExists.SessionAge))"
        } else {
            Write-LogMessage -Type WARNING -Message "No active session found for `"$Script:VCenterName`""
        }

        .EXAMPLE
        # Test specific vCenter
        $result = Test-VcenterConnection -ServerName $Script:VCenterName
        if ($result.IsConnected) {
            Write-LogMessage -Type INFO -Message "Connection to `"$($result.ServerName)`" is valid"
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

    Param(
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$ServerName = $Script:VCenterName,
        [Parameter(Mandatory = $false)] [Switch]$SkipConnectivityTest
    )

    Write-LogMessage -Type DEBUG -SuppressOutputToFile -Message "Entered Test-VcenterConnection function..."

    # Initialize result object.
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

        # Calculate session age
        if ($vcServer.ServiceUri.StartTime) {
            $result.SessionAge = (Get-Date) - $vcServer.ServiceUri.StartTime
        } elseif ($vcServer.ExtensionData.Content.About.ApiVersion) {
            # Session exists but start time not available - estimate as "recent".

            $result.SessionAge = [TimeSpan]::FromMinutes(0)
        }

        Write-LogMessage -Type DEBUG -SuppressOutputToFile -Message "PowerCLI session exists for `"$ServerName`" (age: $($result.SessionAge))"

        # If skip connectivity test, return now (session exists)
        if ($SkipConnectivityTest) {
            $result.IsConnected = $true
            return $result
        }

        # Phase 2: Verify connection is actually alive with lightweight API call.

        # Using Get-Datacenter because it's:
        # - Fast (small response)
        # - Always available (every vCenter has at least one datacenter)
        # - Read-only (no side effects)
        # - Validates authentication and API access
        Write-LogMessage -Type DEBUG -SuppressOutputToFile -Message "Performing connectivity test to `"$ServerName`"..."

        $null = Get-Datacenter -Server $ServerName -ErrorAction Stop | Select-Object -First 1

        # Connection is valid
        $result.IsConnected = $true
        Write-LogMessage -Type DEBUG -SuppressOutputToFile -Message "Connection to `"$ServerName`" is active and valid"
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
Function Disconnect-Vcenter {

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
        This parameter is used for logging context but is not strictly required for disconnection.
        - "vCenter": Indicates disconnection from a vCenter instance
        - "ESX": Indicates disconnection from an ESX host instance

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
        - If any connections remain after disconnection attempt, the function exits with code 1
        - The allServers switch is recommended for cleanup scenarios to ensure all connections are terminated
        - Error handling provides detailed logging with ErrorAction:Stop to ensure disconnection failures are caught
        - The function integrates with VCF PowerShell Toolbox logging infrastructure for consistent reporting
        - Proper disconnection prevents resource leaks and ensures clean session management
        - Function is designed for use in cleanup scenarios, error handling routines, and temporary connection management

    #>

    Param (
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [Switch]$AllServers,
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$ServerName,
        [Parameter(Mandatory = $false)] [ValidateSet("vCenter", "ESX")] [String]$ServerType,
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [Switch]$Silence
    )
    Write-LogMessage -Type DEBUG -Message "Entered Disconnect-Vcenter function..."

    # Disconnect from vCenter.  Stop on error.
    try {
        if ($AllServers) {
            Disconnect-VIServer -Server * -Force -Confirm:$false -ErrorAction:Stop | Out-Null
        } else {
            Disconnect-VIServer -Server $ServerName -Force -Confirm:$false -ErrorAction:Stop | Out-Null
        }
    } catch {
    }
    # Double check that all servers are disconnected.
    if ($null -eq $Global:DefaultVIServer) {
        if ($Silence) {
            Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "Successfully disconnected from all vCenter and ESX hosts"
        } else {
            Write-LogMessage -Type INFO -Message "Successfully disconnected from all vCenter and ESX hosts"
        }
    } else {
        Write-LogMessage -Type ERROR -Message "Failed to disconnect from all servers. The following connections remain active: $($Global:DefaultVIServer.Name -join ', ')"
        throw "Deployment failed. Check logs for details."
    }
}
Function Test-VCenterVersion {

    <#
        .SYNOPSIS
        Validates that vCenter is running a specified minimum version or later.

        .DESCRIPTION
        The Test-VCenterVersion function checks the version of the connected vCenter
        to ensure it meets a specified minimum version requirement. This validation is critical
        for ensuring that the vCenter supports the features and APIs required for
        deployment operations.

        The function retrieves the vCenter version from the connected vCenter instance
        (identified by $Script:VCenterName) using the PowerCLI API version information. It
        accepts a minimum required version as a parameter in the format "major.minor.patch"
        (e.g., "9.0.0") and performs a semantic version comparison to validate that the
        detected version meets or exceeds the requirement.

        The minimum version string is parsed within the function to extract major, minor, and
        patch components for comparison against the detected vCenter version.

        Key features:
        - Retrieves vCenter version from active connection using $Script:VCenterName
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
            Write-Host "Version validation failed: $($result.ErrorMessage)"
            throw "Deployment failed. Check logs for details."
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
        - Uses $Script:VCenterName global variable to identify the connected vCenter
        - The function uses $Global:DefaultViServers to access connection information
        - Version comparison follows semantic versioning rules (major.minor.patch)
        - Returns error result object on failure instead of throwing exceptions
        - Integrates with Write-LogMessage for consistent logging
        - Version strings must be in format "major.minor.patch" (e.g., "9.0.0")

        Error Handling: Validation function. Returns structured error object via Write-ErrorAndReturn
        on any validation failure. Caller should check $result.Success and decide whether to exit
        or continue. Typically, main workflow functions call 'exit 1' on version validation failure.

        .LINK
        Connect-Vcenter
        Disconnect-Vcenter
    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$MinimumVersion
    )

    Write-LogMessage -Type DEBUG -Message "Entered Test-VCenterVersion function..."

    try {
        # Get the connected vCenter instance using the script-scoped vCenter name.

        $vcServer = $Global:DefaultViServers | Where-Object { $_.Name -eq $Script:VCenterName -and $_.IsConnected }

        if (-not $vcServer) {
            return Write-ErrorAndReturn -ErrorMessage "Not connected to vCenter `"$Script:VCenterName`". Please establish a connection first." -ErrorCode "ERR_NOT_CONNECTED"
        }

        # Get the vCenter version from the API version property.

        $vcVersionString = $vcServer.Version

        if (-not $vcVersionString) {
            return Write-ErrorAndReturn -ErrorMessage "Unable to retrieve version information from vCenter `"$Script:VCenterName`"." -ErrorCode "ERR_VERSION_UNAVAILABLE"
        }

        Write-LogMessage -Type DEBUG -Message "Detected vCenter `"$Script:VCenterName`" version: $vcVersionString"

        # Convert version strings to [version] type for proper semantic version comparison
        try {
            $vcVersion = [version]$vcVersionString
            $minVersion = [version]$MinimumVersion
        } catch {
            return Write-ErrorAndReturn -ErrorMessage "Failed to parse version strings. vCenter version: `"$vcVersionString`", Minimum version: `"$MinimumVersion`". Both must be in valid version format (e.g., 9.0.0)." -ErrorCode "ERR_VERSION_PARSE_FAILED"
        }

        # Compare versions using [version] type comparison (automatically handles major.minor.build.revision)
        if ($vcVersion -lt $minVersion) {
            return Write-ErrorAndReturn -ErrorMessage "vCenter `"$Script:VCenterName`" version $vcVersionString does not meet minimum required version: $MinimumVersion. Please upgrade vCenter." -ErrorCode "ERR_VERSION_TOO_OLD"
        }

        # Version validation passed
        Write-LogMessage -Type INFO -Message "vCenter `"$Script:VCenterName`" version $vcVersionString meets minimum required version ($MinimumVersion)."

        return @{
            Success = $true
            ErrorMessage = $null
            ErrorCode = $null
            Version = $vcVersionString
            MinimumVersion = $MinimumVersion
        }

    } catch {
        return Write-ErrorAndReturn -ErrorMessage "Failed to validate vCenter version for `"$Script:VCenterName`": $_" -ErrorCode "ERR_VALIDATION_EXCEPTION"
    }
}

Function New-SubscriptionBasedContentLibrary {

    <#
        .SYNOPSIS
        Creates a new subscription based content library on vCenter and returns its unique identifier.

        .DESCRIPTION
        The New-SubscriptionBasedContentLibrary function creates a new subscription based content library in vCenter
        using the specified datastore for storage. This content library is a container for storing 9.0.1 async patch
        for supervisor.

        This function performs the following operations:
        1. Retrieves the specified datastore object from vCenter
        2. Creates a new subscription based content library with the provided name, description and subscriptionURL
        3. Associates the content library with the specified datastore for storage
        4. Returns the unique identifier of the newly created content library

        The function includes comprehensive error handling for authorization issues, network timeouts,
        and other potential failures during content library creation. All operations are logged using
        the Write-LogMessage system for audit trail and troubleshooting purposes.

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
        - Requires an active PowerCLI connection to vCenter via the $Script:VCenterName variable
        - The specified datastore must exist and be accessible from vCenter
        - The publishURL from the contentlibray has to be passed as SubscriptionUrl
        - The function will terminate script execution (exit 1) if content library creation fails
        - Uses comprehensive error handling for authorization, network timeout, and general failures
        - Integrates with the VCF PowerShell Toolbox logging infrastructure for consistent reporting
        - The returned library ID is obtained by calling Get-ContentLibraryId after successful creation
        - The function uses the VMware PowerCLI New-ContentLibrary cmdlet for library creation

        .LINK
        Get-ContentLibraryId
        New-ContentLibrary
    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$DatastoreName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$LibraryDescription,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$LibraryName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$SubscriptionUrl
    )

    Write-LogMessage -Type DEBUG -Message "Entered New-SubscriptionBasedContentLibrary function..."

    # Verify vCenter connection before proceeding.
    $connectionTest = Test-VcenterConnection
    if (-not $connectionTest.IsConnected) {
        Write-LogMessage -Type ERROR -Message "Not connected to vCenter `"$Script:VCenterName`": $($connectionTest.ErrorMessage)"
        throw "Deployment failed. Check logs for details."
    }

    # Check if the content library already exists and if so, return the id.
    $contentLibraryId = Get-ContentLibraryId -libraryName $LibraryName
    if ($contentLibraryId) {
        Write-LogMessage -Type WARNING -Message "Content library `"$LibraryName`" already exists on vCenter `"$Script:VCenterName`"."
        return $contentLibraryId
    }

    try {
        # Get Datastore object. Using the datastore name.
        $datastoreObject = Get-Datastore -Name $DatastoreName -Server $Script:VCenterName

        # Create subscription based content library. Using the datastore object.
        New-ContentLibrary -Name $LibraryName `
            -Description $LibraryDescription `
            -Type Subscribed `
            -SubscriptionUrl $SubscriptionUrl `
            -Datastore $datastoreObject `
            -AutomaticSyncEnabled:$true `
            -ErrorAction Stop `
            -Server $Script:VCenterName | Out-Null
    }
    catch [System.UnauthorizedAccessException] {
        Write-LogMessage -Type ERROR -Message "Cannot create content library `"$LibraryName`" (`"$LibraryDescription`") on vCenter `"$Script:VCenterName`" due to authorization issues: $_"
        throw "Deployment failed. Check logs for details."
    }
    catch [System.TimeoutException] {
        Write-LogMessage -Type ERROR -Message "Cannot create content library `"$LibraryName`" (`"$LibraryDescription`") on vCenter `"$Script:VCenterName`" due to network/timeout issues: $_"
        throw "Deployment failed. Check logs for details."
    }
    catch {
        Write-LogMessage -Type ERROR -Message "Failed to create content library `"$LibraryName`" (`"$LibraryDescription`") on vCenter `"$Script:VCenterName`": $_"
        throw "Deployment failed. Check logs for details."
    }
    Write-LogMessage -Type INFO -Message "Successfully created content library `"$LibraryName`" on vCenter `"$Script:VCenterName`"."
    $contentLibraryId = Get-ContentLibraryId -libraryName $LibraryName
    return $contentLibraryId
}
Function Add-Cluster {

    <#
        .SYNOPSIS
        Creates a new vSphere cluster with DRS and HA enabled in a specified datacenter.

        .DESCRIPTION
        The Add-Cluster function creates a new vSphere compute cluster within a specified
        datacenter on a vCenter. The function includes comprehensive validation to
        ensure the target datacenter exists and prevents duplicate cluster creation. It
        automatically configures the cluster with Distributed Resource Scheduler (DRS)
        and High Availability (HA) enabled for optimal resource management and availability.

        The function prompts the user to interactively select a vLCM image from the
        vCenter's image catalog using Find-VlcmImage. The selected image's software
        specification is then retrieved using Get-LcmSoftwareSpecification and applied
        to the cluster during creation, ensuring the cluster is configured with the
        desired ESXi image specification.

        Key features:
        - Pre-creation validation of datacenter existence
        - Duplicate cluster detection and prevention
        - Interactive vLCM image selection for cluster software specification
        - Automatic software specification object retrieval and validation
        - Automatic DRS and HA enablement
        - Comprehensive error handling and logging
        - Integration with VCF PowerShell Toolbox logging infrastructure

        The function will throw an exception if the target datacenter is not found, if
        the software specification cannot be retrieved, or if cluster creation fails,
        ensuring that subsequent operations don't proceed with invalid cluster configurations.

        .PARAMETER ClusterName
        The name of the new cluster to create. This name must be unique within the
        specified datacenter and should follow VMware naming conventions. The cluster
        name will be used for identification and management purposes.

        .PARAMETER DataCenterName
        The name of the datacenter where the cluster will be created. This datacenter
        must already exist in the specified vCenter. The function will validate
        the datacenter's existence before attempting cluster creation.

        .EXAMPLE
        Add-Cluster -ClusterName "Production-Cluster-01" -DataCenterName "Datacenter1"

        Creates a new cluster named "Production-Cluster-01" in "Datacenter1" on the specified vCenter.

        .EXAMPLE
        Add-Cluster -clusterName $clusterName -dataCenterName $datacenterName

        Creates a cluster using variables for dynamic cluster deployment scenarios.

        .NOTES
        This function requires an active PowerCLI connection to the specified vCenter.
        The function will throw an exception if critical errors occur, such as datacenter
        not found, software specification retrieval failure, or cluster creation failure.
        DRS is configured in fully automated mode, and HA is enabled with default settings.
        The function uses Find-VlcmImage to prompt the user for vLCM image selection and
        Get-LcmSoftwareSpecification to retrieve the software specification object for
        cluster creation.

    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$DataCenterName
    )
    Write-LogMessage -Type DEBUG -Message "Entered Add-Cluster function..."

    # Verify vCenter connection before proceeding.
    $connectionTest = Test-VcenterConnection
    if (-not $connectionTest.IsConnected) {
        Write-LogMessage -Type ERROR -Message "Not connected to vCenter `"$Script:VCenterName`": $($connectionTest.ErrorMessage)"
        throw "Deployment failed. Check logs for details."
    }

    # Look to see if the the datacenter exists in this vCenter.
    try {
        $dataCenterFound = Get-Datacenter -Name $DataCenterName -Server $Script:VCenterName -ErrorAction:Ignore
    } catch [System.UnauthorizedAccessException] {
        Write-LogMessage -Type ERROR -Message "Cannot perform Get-Datacenter operation for `"$DataCenterName`" on vCenter `"$Script:VCenterName`" due to authorization issues: $_"
        throw "Deployment failed. Check logs for details."
    }
    catch [System.TimeoutException] {
        Write-LogMessage -Type ERROR -Message "Cannot perform Get-Datacenter operation for `"$DataCenterName`" on vCenter `"$Script:VCenterName`" due to network/timeout issues: $_"
        throw "Deployment failed. Check logs for details."
    }
    catch {
        Write-LogMessage -Type ERROR -AppendNewLine -Message "Failed perform Get-Datacenter operation on `"$DataCenterName`" on vCenter on `"$Script:VCenterName`" : $_"
        throw "Deployment failed. Check logs for details."
    }

    # If the datacenter does not exist, exit.
    if (-not $dataCenterFound) {
        Write-LogMessage -Type ERROR -AppendNewLine -Message "The datacenter `"$DataCenterName`" could not be found on vCenter `"$Script:VCenterName`". Exiting."
        throw "Deployment failed. Check logs for details."
    }

    # Look to see if the cluster already exists.
    try {
        $clusterFound = Get-Cluster -Name $ClusterName -location $DataCenterName -ErrorAction:Stop -Server $Script:VCenterName
    } catch {
        Write-LogMessage -Type INFO -Message "The cluster `"$ClusterName`" on datacenter `"$DataCenterName`" on vCenter `"$Script:VCenterName`" is not present. Proceeding with creating a new cluster."
    }
    # If the cluster does not exist, create it.
    if (-not $clusterFound) {
        # Create the cluster.
        try {
            # Ask the user to select a vLCM image.  The function will throw an exception if the user cancels.
            $softwareSpecificationId = Find-VlcmImage
            Write-LogMessage -Type DEBUG -Message "Retrieving software specification object for ID: $softwareSpecificationId"
            try {
                $softwareSpecification = Get-LcmSoftwareSpecification -Id $softwareSpecificationId -ErrorAction Stop
            }
            catch {
                Write-LogMessage -Type ERROR -Message "Failed to retrieve software specification with ID `"$softwareSpecificationId`": $_"
                throw "Deployment failed. Check logs for details."
            }
            if ($null -eq $softwareSpecification) {
                Write-LogMessage -Type ERROR -Message "Software specification with ID `"$softwareSpecificationId`" was not found."
                throw "Deployment failed. Check logs for details."
            }
            Write-LogMessage -Type DEBUG -Message "Successfully retrieved software specification object."
            New-Cluster -Name $ClusterName -Location $DataCenterName -DrsEnabled:$true -HAEnabled:$true -SoftwareSpecification $softwareSpecification -Server $Script:VCenterName -ErrorAction Stop | Out-Null
            $clusterFound = Get-Cluster -Name $ClusterName -location $DataCenterName -ErrorAction:Stop -Server $Script:VCenterName

        } catch [System.UnauthorizedAccessException] {
            Write-LogMessage -Type ERROR -Message "Failed to create cluster `"$ClusterName`" on datacenter `"$DataCenterName`" on vCenter `"$Script:VCenterName`" due to authorization issues: $_"
            throw "Deployment failed. Check logs for details."
        }
        catch [System.TimeoutException] {
            Write-LogMessage -Type ERROR -Message "Failed to create cluster `"$ClusterName`" on datacenter `"$DataCenterName`" on vCenter `"$Script:VCenterName`" due to network/timeout issues: $_"
            throw "Deployment failed. Check logs for details."
        }
        catch {
            Write-LogMessage -Type ERROR -Message "Failed create cluster cluster `"$ClusterName`" on datacenter `"$DataCenterName`" on vCenter `"$Script:VCenterName`" : $_"
            throw "Deployment failed. Check logs for details."
        }
    } else {
        Write-LogMessage -Type WARNING -Message "The cluster `"$ClusterName`" on datacenter `"$DataCenterName`" on vCenter `"$Script:VCenterName`" is already present."
        return
    }

    if ($clusterFound) {
        Write-LogMessage -Type INFO -Message "Successfully created the cluster `"$ClusterName`" on datacenter `"$DataCenterName`" on `"$Script:VCenterName`"."
    } else {
        Write-LogMessage -Type ERROR -Message "Something went wrong creating the cluster `"$ClusterName`" on datacenter `"$DataCenterName`" on vCenter `"$Script:VCenterName`": $_"
        throw "Deployment failed. Check logs for details."
    }
}
Function Update-Cluster {

    <#
        .SYNOPSIS
        Configures vSphere cluster settings for High Availability, DRS, and monitoring optimized for simple deployments.

        .DESCRIPTION
        This function applies comprehensive cluster configuration settings specifically optimized for simple
        vSphere deployments. It configures High Availability (HA) and Distributed Resource Scheduler (DRS) with
        settings that are appropriate for environments where only one ESX host is present in the cluster.

        The function performs the following configuration operations:
        1. Validates cluster existence and retrieves cluster objects for configuration
        2. Enables HA and DRS with fully automated DRS automation level
        3. Configures HA host monitoring to "enabled" for proper cluster health detection
        4. Sets VM monitoring to "vmMonitoringOnly" to monitor VM heartbeats without application monitoring
        5. Disables HA admission control to prevent resource constraints from blocking VM operations
        6. Applies all configuration changes through the vSphere API and validates successful implementation

        Key configuration details:
        - DRS Automation Level: FullyAutomated (allows automatic VM migration and resource balancing)
        - HA Host Monitoring: Enabled (monitors ESX host health and availability)
        - VM Monitoring: vmMonitoringOnly (monitors VM heartbeats but not application-level monitoring)
        - Admission Control: Disabled (prevents resource reservation from blocking VM startup in simple scenarios)

        .PARAMETER ClusterName
        Specifies the name of the vSphere cluster to be configured. The cluster must already exist
        in the vCenter environment specified by the global $Script:VCenterName variable.
        This parameter is mandatory and must reference a valid, existing cluster.

        .EXAMPLE
        Update-Cluster -clusterName "cl02"

        Configures the cluster "cl02" with optimized settings for simple deployment.
        This includes enabling HA with host and VM monitoring, enabling fully automated DRS,
        and disabling admission control to prevent resource constraint issues.

        .EXAMPLE
        Update-Cluster -clusterName "production-cluster"

        Applies simple optimized configuration to "production-cluster" including all HA/DRS
        settings, monitoring configuration, and admission control adjustments.

        .NOTES
        Prerequisites:
        - VMware PowerCLI must be installed and imported into the PowerShell session
        - Active connection to vCenter must be established (uses $Script:VCenterName global variable)
        - User account must have appropriate privileges to modify cluster configuration settings
        - Target cluster must already exist in the vCenter environment

        Behavior:
        - Uses direct vSphere API calls (ReconfigureComputeResource_Task) for advanced configuration options
        - Host monitoring configuration requires API-level access as it's not exposed through Set-Cluster cmdlet
        - All configuration changes are applied atomically through a single API call
        - Function validates successful configuration application before completion

        Error Handling:
        - Comprehensive error handling for authorization, timeout, and general configuration failures
        - Throws exceptions on any critical configuration errors
        - Detailed error logging with specific error context for troubleshooting

        Performance:
        - Single API call for all configuration changes minimizes vCenter load
        - Configuration validation ensures settings are properly applied before function completion
        - Optimized for simple scenarios where traditional multi-host cluster features may not apply

        Integration:
        - Integrates with VCF PowerShell Toolbox logging infrastructure for consistent audit trails
        - Uses global vCenter connection context for seamless integration with deployment workflows
        - Designed for use in automated deployment scenarios where reliable cluster configuration is critical
    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName
    )

    Write-LogMessage -Type DEBUG -Message "Entered Update-Cluster function..."

    # Verify vCenter connection before proceeding.
    $connectionTest = Test-VcenterConnection
    if (-not $connectionTest.IsConnected) {
        Write-LogMessage -Type ERROR -Message "Not connected to vCenter `"$Script:VCenterName`": $($connectionTest.ErrorMessage)"
        throw "Deployment failed. Check logs for details."
    }

    try {
        $cluster = Get-Cluster -Name $ClusterName -Server $Script:VCenterName -ErrorAction Stop
        $clusterView = Get-View $cluster.Id
        if (-not $cluster) {
            Write-LogMessage -Type ERROR -Message "The cluster `"$ClusterName`" on datacenter `"$dataCenter`" in vCenter `"$Script:VCenterName`" was not found."
            throw "Deployment failed. Check logs for details."
        } else {
            # Enabling HA and DRS and admission control on HA.

            Set-Cluster -Cluster $ClusterName -DrsEnabled:$true -HAEnabled:$true -DrsAutomationLevel FullyAutomated -Confirm:$false -Server $Script:VCenterName -ErrorAction Stop | Out-Null

            # This work-around is required because the HostMonitoring option is not exposed by Set-Cluster cmdlet.
            $cluster.ExtensionData.ConfigurationEx.DasConfig.HostMonitoring = 'enabled'

            # Clone current configuration.
            $configSpec = New-Object VMware.Vim.ClusterConfigSpecEx
            $configSpec.dasConfig = $clusterView.ConfigurationEx.DasConfig

            # Enabled the HostMonitoring option.
            $configSpec.dasConfig.HostMonitoring = "enabled"

            # Set vmMonitoring
            # Acceptable values - "vmMonitoringDisabled" "vmMonitoringOnly" "vmAndAppMonitoring".

            $configSpec.dasConfig.VMMonitoring = "vmMonitoringOnly"

            # Disable the AdmissionControlEnabled option.
            $configSpec.dasConfig.AdmissionControlEnabled = $false

            # Apply changes.
            $clusterView.ReconfigureComputeResource_Task($configSpec, $true) | Out-Null
            if ($cluster.ExtensionData.ConfigurationEx.DasConfig.HostMonitoring -eq 'enabled') {
                Write-LogMessage -Type INFO -Message "Successfully enabled HA monitoring settings on cluster `"$ClusterName`" on vCenter `"$Script:VCenterName`"."
            }
            if ($cluster.ExtensionData.ConfigurationEx.DasConfig.VmMonitoring -eq 'vmMonitoringOnly') {
                Write-LogMessage -Type INFO -Message "Successfully configured VM monitoring settings on cluster `"$ClusterName`" on vCenter `"$Script:VCenterName`"."
            }
        }
    } catch [System.UnauthorizedAccessException] {
        Write-LogMessage -Type ERROR -Message "Cannot update settings on cluster `"$ClusterName`" on `"$Script:VCenterName`" due to authorization issues: $_"
        throw "Deployment failed. Check logs for details."
    }
    catch [System.TimeoutException] {
        Write-LogMessage -Type ERROR -Message "Cannot update settings on cluster `"$ClusterName`" on `"$Script:VCenterName`" due to network/timeout issues: $_"
        throw "Deployment failed. Check logs for details."
    }
    catch {
        Write-LogMessage -Type ERROR -AppendNewLine -Message "Failed to update settings on cluster `"$ClusterName`" on `"$Script:VCenterName`" : $_"
        throw "Deployment failed. Check logs for details."
    }
}
Function Add-HostToCluster {

    <#
        .SYNOPSIS
        Adds an ESX host to an existing vSphere cluster and verifies successful integration.

        .DESCRIPTION
        This function adds an ESX host to a specified vSphere cluster within a vCenter environment.
        It performs the following operations:
        1. Retrieves the target cluster object from vCenter
        2. Adds the ESX host to the cluster using the provided credentials
        3. Verifies that the host was successfully added by checking cluster membership
        4. Provides appropriate logging for success or failure scenarios

        The function uses the Force parameter to bypass confirmation prompts during host addition.

        .EXAMPLE
        Add-HostToCluster -ClusterName "cl02" -EsxHostName "esx01.example.com" -EsxCredential $EsxCredential

        This example adds the ESX host "esx01.example.com" to the cluster "cl02"
        in the vCenter "vcenter.example.com" using the provided ESX credentials.

        .PARAMETER ClusterName
        Specifies the name of the vSphere cluster where the ESX host will be added.
        The cluster must already exist in the specified vCenter.

        .PARAMETER EsxHostName
        Specifies the FQDN or IP address of the ESX host to be added to the cluster.

        .PARAMETER EsxCredential
        Specifies the PSCredential object containing the username and password for authenticating
        with the ESX host during the addition process.

        .NOTES
        - Requires VMware PowerCLI to be installed and imported
        - The user must have appropriate privileges in vCenter to add hosts to clusters
        - The ESX host should be accessible from the vCenter
        - Any existing host configuration will be preserved during cluster addition
    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [PSCredential]$EsxCredential,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$EsxHostName
    )

    Write-LogMessage -Type DEBUG -Message "Entered Add-HostToCluster function..."

    # Verify vCenter connection before proceeding.
    $connectionTest = Test-VcenterConnection
    if (-not $connectionTest.IsConnected) {
        Write-LogMessage -Type ERROR -Message "Not connected to vCenter `"$Script:VCenterName`": $($connectionTest.ErrorMessage)"
        throw "Deployment failed. Check logs for details."
    }

    # Retrieve the target cluster object from vCenter.
    try {
        $clusterObject = Get-Cluster -Name $ClusterName -Server $Script:VCenterName -ErrorAction Stop
    } catch [System.UnauthorizedAccessException] {
        Write-LogMessage -Type ERROR -Message "Cannot perform Get-Cluster operation for cluster `"$ClusterName`" on vCenter `"$Script:VCenterName`" due to authorization issues: $_"
        throw "Deployment failed. Check logs for details."
    }
    catch [System.TimeoutException] {
        Write-LogMessage -Type ERROR -Message "Cannot perform Get-Cluster operation for cluster `"$ClusterName`" on vCenter `"$Script:VCenterName`" due to network/timeout issues: $_"
        throw "Deployment failed. Check logs for details."
    }
    catch {
        Write-LogMessage -Type ERROR -AppendNewLine -Message "Failed to perform Get-Cluster operation for cluster `"$ClusterName`" on vCenter `"$Script:VCenterName`" : $_"
        throw "Deployment failed. Check logs for details."
    }

    # Check if the host is already in the cluster.
    try {
        $existingHost = $clusterObject | Get-VMHost -Name $EsxHostName -Server $Script:VCenterName -ErrorAction SilentlyContinue
    } catch {
        # If Get-VMHost fails, continue to add the host.

        $existingHost = $null
    }

    if ($existingHost) {
        Write-LogMessage -TYPE WARNING -Message "ESX Host `"$EsxHostName`" is already in cluster `"$ClusterName`" in vCenter `"$Script:VCenterName`" with state `"$($existingHost.ConnectionState)`"."

        # If not connected, try to connect it.

        if ($existingHost.ConnectionState -ne "Connected") {
            Write-LogMessage -TYPE INFO -Message "Setting ESX host `"$EsxHostName`" to connected state..."
            try {
                Set-VMHost -VMHost $EsxHostName -Server $Script:VCenterName -State Connected -Confirm:$false -ErrorAction Stop
                Write-LogMessage -TYPE INFO -Message "Successfully set ESX host `"$EsxHostName`" to connected state."
            } catch {
                Write-LogMessage -TYPE ERROR -Message "Failed to set ESX host `"$EsxHostName`" to connected state in vCenter `"$Script:VCenterName`" : $_"
                throw "Deployment failed. Check logs for details."
            }
        }
        return
    }

    # Attempt to add the ESX host to the specified cluster.
    Write-LogMessage -TYPE INFO -Message "Attempting to add ESX host `"$EsxHostName`" to cluster `"$ClusterName`" in vCenter `"$Script:VCenterName`"..."
    try {
        Add-VMHost -Name $EsxHostName -Credential $EsxCredential -Location $ClusterName -Force -Server $Script:VCenterName -ErrorAction Stop | Out-Null
        Write-LogMessage -TYPE INFO -Message "ESX host `"$EsxHostName`" added to cluster `"$ClusterName`" in vCenter `"$Script:VCenterName`"."
    }
    catch [System.UnauthorizedAccessException] {
        Write-LogMessage -TYPE ERROR -Message "Cannot add host `"$EsxHostName`" to cluster `"$ClusterName`" in vCenter `"$Script:VCenterName`" due to authorization issues: $_"
        throw "Deployment failed. Check logs for details."
    }
    catch [System.TimeoutException] {
        Write-LogMessage -TYPE ERROR -Message "Cannot add host `"$EsxHostName`" to cluster `"$ClusterName`" in vCenter `"$Script:VCenterName`" due to network/timeout issues: $_"
        throw "Deployment failed. Check logs for details."
    }
    catch {
        # Extract just the meaningful error message, removing PowerShell metadata.

        $errorMessage = $_.Exception.Message

        # Check for common "already managed" scenario and make it friendlier.

        if ($errorMessage -match "already being managed|already managed|already exists") {
            Write-LogMessage -TYPE ERROR -Message "This host `"$EsxHostName`" is already being managed by vCenter `"$Script:VCenterName`"."
        } else {
            # For other errors, show the clean error message without PowerShell metadata.

            Write-LogMessage -TYPE ERROR -Message "Failed to add host `"$EsxHostName`" to cluster `"$ClusterName`" in vCenter `"$Script:VCenterName`": $errorMessage"
        }
        throw "Deployment failed. Check logs for details."
    }

    # Ensure the host is in connected state.
    Write-LogMessage -TYPE INFO -Message "Setting host `"$EsxHostName`" to connected state..."
    try {
        Start-Sleep 2
        Set-VMHost -VMHost $EsxHostName -Server $Script:VCenterName -State Connected -Confirm:$false -ErrorAction Stop | Out-Null
    } catch [System.UnauthorizedAccessException] {
        Write-LogMessage -TYPE ERROR -Message "Cannot set host `"$EsxHostName`" to connected state in vCenter `"$Script:VCenterName`" due to authorization issues: $_"
        throw "Deployment failed. Check logs for details."
    }
    catch [System.TimeoutException] {
        Write-LogMessage -TYPE ERROR -Message "Cannot set host `"$EsxHostName`" to connected state in vCenter `"$Script:VCenterName`" due to network/timeout issues: $_"
        throw "Deployment failed. Check logs for details."
    }
    catch {
        Write-LogMessage -TYPE ERROR -Message "Failed to set host `"$EsxHostName`" to connected state in vCenter `"$Script:VCenterName`" : $_"
        throw "Deployment failed. Check logs for details."
    }

    # Verify that the host was successfully added and is connected.
    try {
        $verifyHost = Get-VMHost -Name $EsxHostName -Server $Script:VCenterName -ErrorAction Stop
    } catch {
        Write-LogMessage -TYPE ERROR -Message "Failed to verify host `"$EsxHostName`" in vCenter `"$Script:VCenterName`" : $_"
        throw "Deployment failed. Check logs for details."
    }

    if ($verifyHost.Parent.Name -eq $ClusterName -and $verifyHost.ConnectionState -eq "Connected") {
        Write-LogMessage -TYPE INFO -Message "Successfully added host `"$EsxHostName`" to cluster `"$ClusterName`" in vCenter `"$Script:VCenterName`"."
    }
    else {
        Write-LogMessage -TYPE ERROR -Message "Failed to add `"$EsxHostName`" to cluster `"$ClusterName`" in vCenter `"$Script:VCenterName`". Current state: Parent=$($verifyHost.Parent.Name), ConnectionState=$($verifyHost.ConnectionState)"
        throw "Deployment failed. Check logs for details."
    }
}
Function Get-ClusterId {

    <#
        .SYNOPSIS
        Retrieves the MoRef identifier for a vSphere cluster.

        .DESCRIPTION
        The Get-ClusterId function queries the vCenter to find a vSphere cluster by name and returns its
        MoRef identifier (e.g., "domain-c2045"). This identifier is required by VCF PowerCLI 9 cmdlets such as
        Invoke-EnableOnComputeClusterClusterSupervisors for enabling vSphere Supervisor on a cluster.

        The function extracts the MoRef value from the cluster's ExtensionData, which is different from the
        cluster's .Id property that returns the full type-prefixed ID (e.g., "ClusterComputeResource-domain-c2045").

        The function will terminate the script with an error if the cluster is not found or if any other error
        occurs during the lookup.

        .PARAMETER ClusterName
        The name of the vSphere cluster for which to retrieve the MoRef identifier. This parameter is mandatory.

        .EXAMPLE
        Get-ClusterId -ClusterName "compute-cluster-01"
        Returns the MoRef identifier (e.g., "domain-c2045") for the cluster named "compute-cluster-01".

        .EXAMPLE
        $clusterId = Get-ClusterId -ClusterName "edge-cluster"
        Stores the cluster MoRef ID in a variable for use with VCF PowerCLI 9 supervisor enablement cmdlets.

        .OUTPUTS
        System.String
        Returns the MoRef identifier for the cluster (e.g., "domain-c2045").

        .NOTES
        - Requires an active connection to vCenter (uses $Script:VCenterName)
        - Uses Get-Cluster cmdlet from VMware PowerCLI
        - Will exit the script with code 1 if the cluster is not found or any error occurs
        - Returns the ExtensionData.MoRef.Value property which is the identifier expected by VCF PowerCLI 9 APIs
        - The returned ID format is "domain-cXXXX" without the "ClusterComputeResource-" prefix
    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName
    )

    Write-LogMessage -Type DEBUG -Message "Entered Get-ClusterId function..."

    # Verify vCenter connection before proceeding.
    $connectionTest = Test-VcenterConnection
    if (-not $connectionTest.IsConnected) {
        Write-LogMessage -Type ERROR -Message "Not connected to vCenter `"$Script:VCenterName`": $($connectionTest.ErrorMessage)"
        throw "Deployment failed. Check logs for details."
    }

    try {
        # Get cluster object from vCenter.

        $clusterObject = Get-Cluster -Name $ClusterName -Server $Script:VCenterName -ErrorAction Stop

        # Extract the MoRef ID (e.g., "domain-c2045") from ExtensionData
        # VCF PowerCLI 9 API expects just the MoRef value, not the full type-prefixed ID.

        $clusterId = $clusterObject.ExtensionData.MoRef.Value

        return $clusterId

    } catch [System.UnauthorizedAccessException] {
        Write-LogMessage -Type ERROR -Message "Cannot get cluster id for `"$ClusterName`" on `"$Script:VCenterName`" due to authorization issues: $_"
        throw "Deployment failed. Check logs for details."
    }
    catch [System.TimeoutException] {
        Write-LogMessage -Type ERROR -Message "Cannot get cluster id for `"$ClusterName`" on `"$Script:VCenterName`" due to network/timeout issues: $_"
        throw "Deployment failed. Check logs for details."
    }
    catch {
        Write-LogMessage -Type ERROR -Message "Failed to get cluster id for `"$ClusterName`" on `"$Script:VCenterName`": $_"
        throw "Deployment failed. Check logs for details."
    }
}

Function Get-PortGroupId {

    <#
        .SYNOPSIS
        Retrieves the unique identifier (ExtensionData.Key) for a vSphere Distributed Switch (VDS) port group.

        .DESCRIPTION
        The function Get-PortGroupId queries the vCenter to find a VDS port group by name and returns its unique identifier.
        This identifier is used for configuring supervisor clusters and other vSphere networking components. The function will
        terminate the script with an error if the port group is not found or if any other error occurs during the lookup.

        .EXAMPLE
        Get-PortGroupId -PortGroupName "management"
        Returns the unique identifier for the "management" port group.

        .EXAMPLE
        $mgmtPortGroupId = Get-PortGroupId -PortGroupName "tkgs-management"
        Stores the port group ID in a variable for later use in supervisor cluster configuration.

        .PARAMETER PortGroupName
        The name of the VDS port group for which to retrieve the unique identifier. This parameter is mandatory.

        .NOTES
        - Requires an active connection to vCenter (uses $Script:VCenterName)
        - Uses Get-VDPortgroup cmdlet from VMware PowerCLI
        - Will exit the script with code 1 if the port group is not found or any error occurs
        - Returns the ExtensionData.Key property which is the unique identifier used by vSphere APIs
    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$PortGroupName
    )
    Write-LogMessage -Type DEBUG -Message "Entered Get-PortGroupId function..."

    # Verify vCenter connection before proceeding.
    $connectionTest = Test-VcenterConnection
    if (-not $connectionTest.IsConnected) {
        Write-LogMessage -Type ERROR -Message "Not connected to vCenter `"$Script:VCenterName`": $($connectionTest.ErrorMessage)"
        throw "Deployment failed. Check logs for details."
    }

    try {
        # Get VDS Port group ID from name.

        $pgObject = Get-VDPortgroup -Name $PortGroupName -Server $Script:VCenterName -ErrorAction Stop
        $pgId = $pgObject.ExtensionData.Key
        return $pgId

    } catch [System.UnauthorizedAccessException] {
        Write-LogMessage -Type ERROR -Message "Cannot get port group id for `"$PortGroupName`" on `"$Script:VCenterName`" due to authorization issues: $_"
        throw "Deployment failed. Check logs for details."
    }
    catch [System.TimeoutException] {
        Write-LogMessage -Type ERROR -Message "Cannot get port group id for `"$PortGroupName`" on `"$Script:VCenterName`" due to network/timeout issues: $_"
        throw "Deployment failed. Check logs for details."
    }
    catch {
        Write-LogMessage -Type ERROR -Message "Failed to get port group id for `"$PortGroupName`" on `"$Script:VCenterName`": $_"
        throw "Deployment failed. Check logs for details."
    }
}
Function Set-NewDatastore {

    <#
        .SYNOPSIS
        Creates a new datastore on an ESX host if it doesn't already exist and applies a specified tag.

        .DESCRIPTION
        The Set-NewDatastore function creates a new datastore on the specified ESX host using the provided disk canonical name.
        It first checks if a datastore with the same name already exists on the vCenter to avoid naming conflicts.
        If the datastore exists on the vCenter but not on the specified ESX host, the function will exit with an error
        to prevent conflicts. If the datastore already exists on the specified ESX host, the function will return safely
        and proceed to tag the datastore. If the datastore doesn't exist, it will create a new datastore and wait for it
        to become available with configurable wait times. After successful creation or verification, the function applies
        the specified tag to the datastore for identification and management purposes.

        .EXAMPLE
        Set-NewDatastore -DatastoreName "MyDatastore" -EsxHost "esx01.example.com" -DiskCanonicalName "naa:600508b1001c1234567890abcdef" -TagName "Production"

        This example creates a new VMFS datastore named "MyDatastore" on the ESX host "esx01.example.com" using the specified
        disk canonical name and applies the "Production" tag to the datastore.

        .EXAMPLE
        Set-NewDatastore -DatastoreName "vSAN-Datastore" -EsxHost "esx02.example.com" -DiskCanonicalName "naa:600508b1001c987654321fedcba" -TagName "vSAN-Storage" -TotalWaitTime 180 -CheckInterval 15

        This example creates a datastore with custom wait parameters (3 minutes total, checking every 15 seconds) and tags it
        appropriately for storage management.

        .PARAMETER CheckInterval
        The interval in seconds between checks when waiting for the datastore to become available. Default is 10 seconds.

        .PARAMETER DatastoreName
        The name of the datastore to be created. This name must be unique within the vCenter.

        .PARAMETER DiskCanonicalName
        (Mandatory) The canonical name of the disk device to be used for creating the datastore. This should be in the format
        "naa:xxxxx" or similar device identifier visible to the ESX host.

        .PARAMETER EsxHost
        The name or FQDN of the ESX host where the datastore will be created.

        .PARAMETER TagName
        The name of the tag to be applied to the datastore after creation or verification. This tag is used for identification
        and management purposes within vCenter.

        .PARAMETER TotalWaitTime
        The maximum time in seconds to wait for the datastore to become available after creation. Default is 120 seconds (2 minutes).

        .NOTES
        - Requires an active connection to vCenter (uses $Script:VCenterName)
        - Uses New-Datastore and New-TagAssignment cmdlets from VMware PowerCLI
        - Will exit the script with code 1 if any errors occur during datastore creation or tagging
        - Displays progress indicator while waiting for datastore to become available
        - The specified tag must already exist in vCenter before calling this function
        - Handles authorization and timeout exceptions with appropriate error messages
    #>

    Param (
        [Parameter(Mandatory = $false)] [ValidateRange(1, [int]::MaxValue)] [Int]$CheckInterval=10,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$DatastoreName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$DiskCanonicalName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$EsxHost,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$TagName,
        [Parameter(Mandatory = $false)] [ValidateRange(1, [int]::MaxValue)] [Int]$TotalWaitTime=120
    )

    Write-LogMessage -Type DEBUG -Message "Entered Set-NewDatastore function..."

    # Verify vCenter connection before proceeding.
    $connectionTest = Test-VcenterConnection
    if (-not $connectionTest.IsConnected) {
        Write-LogMessage -Type ERROR -Message "Not connected to vCenter `"$Script:VCenterName`": $($connectionTest.ErrorMessage)"
        throw "Deployment failed. Check logs for details."
    }

    # Check to see if the datastore name is present on the vCenter in question.
    $datastoreFoundOnVcenter = ((Get-Datastore -Name $DatastoreName -Server $Script:VCenterName -ErrorAction SilentlyContinue).State -eq 'Available')
    $datastoreFoundOnEsx = $false  # Initialize variable to avoid undefined variable issues

    if ($datastoreFoundOnVcenter) {
        try {
            $datastoreFoundOnEsx = Get-VMHost -Name $EsxHost -Datastore $DatastoreName -Server $Script:VCenterName -ErrorAction Stop
        }
        catch [System.UnauthorizedAccessException] {
            Write-LogMessage -Type ERROR -Message "Cannot access datastore `"$DatastoreName`" on ESX host `"$EsxHost`" due to authorization issues: $_"
            throw "Deployment failed. Check logs for details."
        }
        catch [System.TimeoutException] {
            Write-LogMessage -Type ERROR -Message "Cannot access datastore `"$DatastoreName`" on ESX host `"$EsxHost`" due to network/timeout issues: $_"
            throw "Deployment failed. Check logs for details."
        }
        catch {
            # Check if this is specifically a "StorageResource not found" error (datastore exists on vCenter but not on this ESX host)
            if ($_.Exception.Message -match "Could not find StorageResource with name") {
                Write-LogMessage -Type ERROR -Message "The datastore `"$DatastoreName`" name is already being used by another server on vCenter `"$Script:VCenterName`". Exiting."
                throw "Deployment failed. Check logs for details."
            } else {
                # Re-throw other errors as they are not related to datastore name conflicts.

                Write-LogMessage -Type ERROR -Message "Error checking datastore `"$DatastoreName`" on ESX host `"$EsxHost`": $_"
                throw "Deployment failed. Check logs for details."
            }
        }
    }

    # If the datastore was found on the expected ESX server, we can return safely.
    if ($datastoreFoundOnEsx) {
        Write-LogMessage -Type WARNING -Message "The datastore `"$DatastoreName`" was already created on ESX host `"$EsxHost`" attached to vCenter `"$Script:VCenterName`"."
        # Still need to tag the existing datastore, so continue to tagging section.

    } else {
        try {
            # Create datastore on the specified ESX host.

            Write-LogMessage -Type INFO -Message "Attempting to create the new datastore `"$DatastoreName`" on ESX host `"$EsxHost`" attached to vCenter `"$Script:VCenterName`"..."
            # Create the datastore (hardcode for VMFS for now, but should be agnostic to the type of datastore)
            New-Datastore -VMHost $EsxHost -Name $DatastoreName -Path $DiskCanonicalName -Vmfs -Server $Script:VCenterName -ErrorAction Stop | Out-Null
            # Wait for datastore to become available with progress indicator.


            $elapsedTime = 0
            $maxChecks = $TotalWaitTime / $CheckInterval
            $currentCheck = 0
            $datastoreReady = $false

            do {
                $currentCheck++
                $datastoreState = (Get-Datastore -Name $DatastoreName -Server $Script:VCenterName -ErrorAction SilentlyContinue).State

                if ($datastoreState -eq 'Available') {
                    Write-Progress -Activity "Waiting for Datastore to become Available" -Status "Complete" -Completed
                    $datastoreReady = $true
                    break
                } else {
                    $statusMessage = "Check $currentCheck of $maxChecks - State: $datastoreState"
                    $currentStatus = "Elapsed: $elapsedTime seconds"
                    Write-Progress -Activity "Waiting for Datastore to become Available" -Status $statusMessage -CurrentOperation $currentStatus
                    Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "Waiting for datastore `"$DatastoreName`" to settle into a connected state... $elapsedTime seconds elapsed)"
                    Start-Sleep $CheckInterval
                    $elapsedTime += $CheckInterval
                }
            } while ($elapsedTime -lt $TotalWaitTime)

            # Clear progress indicator and check final status.

            Write-Progress -Activity "Waiting for Datastore to become Available" -Status "Complete" -Completed

            if (-not $datastoreReady) {
                Write-LogMessage -Type ERROR -Message "Timeout waiting for datastore `"$DatastoreName`" to become available after $TotalWaitTime seconds."
                throw "Deployment failed. Check logs for details."
            }
            Write-LogMessage -Type INFO -Message "The datastore `"$DatastoreName`" was created successfully on ESX host `"$EsxHost`" attached to vCenter `"$Script:VCenterName`"."
        } catch [System.UnauthorizedAccessException] {
            Write-LogMessage -Type ERROR -Message "Cannot create datastore `"$DatastoreName`" on ESX host `"$EsxHost`" due to authorization issues: $_"
            throw "Deployment failed. Check logs for details."
        }
        catch [System.TimeoutException] {
            Write-LogMessage -Type ERROR -Message "Cannot create datastore `"$DatastoreName`" on ESX host `"$EsxHost`" due to network/timeout issues: $_"
            throw "Deployment failed. Check logs for details."
        }
        catch {
            Write-LogMessage -Type ERROR -Message "Failed to create datastore `"$DatastoreName`" on ESX host `"$EsxHost`": $_"
            throw "Deployment failed. Check logs for details."
        }
    }
    try {
        $datastoreObject = Get-Datastore -Name $DatastoreName -Server $Script:VCenterName -ErrorAction SilentlyContinue
    } catch {
        Write-LogMessage -Type ERROR -Message "Failed to get datastore `"$DatastoreName`" on vCenter `"$Script:VCenterName`": $_"
        throw "Deployment failed. Check logs for details."
    }
    # Tag the datastore.
    try {
        New-TagAssignment -Tag $TagName -Entity $datastoreObject -Server $Script:VCenterName -ErrorAction Stop | Out-Null
        Write-LogMessage -Type INFO -Message "Successfully tagged datastore `"$DatastoreName`" with tag `"$TagName`" on vCenter `"$Script:VCenterName`"."
    } catch {
        Write-LogMessage -Type ERROR -Message "Error tagging datastore `"$DatastoreName`" with tag `"$TagName`" on vCenter `"$Script:VCenterName`": $_"
        throw "Deployment failed. Check logs for details."
    }
}
Function Get-EsxUnformattedDisk {

    <#
        .SYNOPSIS
        Scans an ESX host for unformatted disks (disks not in use by any datastore).

        .DESCRIPTION
        Identifies all SCSI LUNs on an ESX host that are not currently used by any VMFS datastore.
        Returns detailed information about each unformatted disk including capacity, vendor, and model.

        This is a helper function extracted from Get-EsxDatastoreInfo to follow the Single Responsibility Principle.
        It focuses solely on disk scanning logic without UI or validation concerns.

        .PARAMETER VmHost
        The VMHost object representing the ESX host to scan. Must be a valid PowerCLI VMHost object.

        .PARAMETER EsxHostName
        The hostname or IP address of the ESX host (used for logging only).

        .PARAMETER Silence
        Switch to suppress console output. When enabled, logs are written to file only.

        .OUTPUTS
        Array of PSCustomObject with properties: ID, CanonicalName, UUID, CapacityGB, Vendor, Model, MultipathPolicy, RuntimeName.
        Returns empty array if no unformatted disks are found.

        .NOTES
        - Requires an active connection to the ESX host
        - Filters out pseudo disks (disks without a multipath policy)
        - Assigns sequential IDs (1, 2, 3...) for interactive selection
    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$EsxHostName,
        [Parameter(Mandatory = $false)] [Switch]$Silence,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] $VmHost
    )

    Write-LogMessage -Type DEBUG -Message "Entered Get-EsxUnformattedDisk function..."
    Write-LogMessage -Type INFO -SuppressOutputToScreen:$Silence -Message "Scanning for unformatted disks/LUNs on ESX host `"$EsxHostName`"..."

    try {
        # Get all SCSI LUNs of type disk.
        $allDisks = $VmHost | Get-ScsiLun -LunType disk

        # Get all mounted datastores.
        $mountedDatastores = Get-Datastore -VMHost $VmHost

        # Get disk backing for mounted datastores.
        $usedDisks = @()
        foreach ($ds in $mountedDatastores) {
            $dsView = Get-View -Id $ds.ExtensionData.MoRef
            if ($dsView.Info.Vmfs) {
                foreach ($extent in $dsView.Info.Vmfs.Extent) {
                    $usedDisks += $extent.DiskName
                }
            }
        }

        # Find disks that are not used by any datastore.
        $unformattedDisks = $allDisks | Where-Object {
            $diskUuid = $_.CanonicalName
            $usedDisks -notcontains $diskUuid -and
            $null -ne $_.MultipathPolicy  # Exclude pseudo disks.
        }

        $unformattedDiskArray = @()

        if ($unformattedDisks -and $unformattedDisks.Count -gt 0) {
            Write-LogMessage -Type INFO -SuppressOutputToScreen:$Silence -Message "Found $($unformattedDisks.Count) unformatted disk(s) on ESX host `"$EsxHostName`"."

            $diskId = 1
            foreach ($disk in $unformattedDisks) {
                $unformattedInfo = [PSCustomObject]@{
                    ID = $diskId
                    CanonicalName = $disk.CanonicalName
                    UUID = $disk.Uuid
                    CapacityGB = [math]::Round(($disk.CapacityGB), 2)
                    Vendor = $disk.Vendor
                    Model = $disk.Model
                    MultipathPolicy = $disk.MultipathPolicy
                    RuntimeName = $disk.RuntimeName
                }
                $unformattedDiskArray += $unformattedInfo

                Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "Unformatted: $($unformattedInfo.CanonicalName) - UUID: $($unformattedInfo.UUID) - Capacity: $($unformattedInfo.CapacityGB) GB - Vendor: $($unformattedInfo.Vendor)"
                $diskId++
            }
        }
        else {
            Write-LogMessage -Type INFO -SuppressOutputToScreen:$Silence -Message "No unformatted disks found on ESX host `"$EsxHostName`"."
        }

        return $unformattedDiskArray
    }
    catch {
        Write-LogMessage -Type ERROR -Message "Failed to scan for unformatted disks on ESX host `"$EsxHostName`": $_"
        throw "Deployment failed. Check logs for details."
    }
}
Function Get-EsxDatastoreHealth {

    <#
        .SYNOPSIS
        Validates the health and properties of a specific datastore on an ESX host.

        .DESCRIPTION
        Performs comprehensive health checks on a mounted datastore including:
        - Mount status verification
        - VMFS version detection
        - Accessibility checks
        - Capacity and free space analysis
        - State validation

        This is a helper function extracted from Get-EsxDatastoreInfo to follow the Single Responsibility Principle.
        It focuses solely on datastore validation logic.

        .PARAMETER VmHost
        The VMHost object representing the ESX host. Must be a valid PowerCLI VMHost object.

        .PARAMETER EsxHostName
        The hostname or IP address of the ESX host (used for logging only).

        .PARAMETER DatastoreName
        The name of the datastore to validate.

        .PARAMETER FreeSpaceWarningThreshold
        The free space percentage threshold below which a warning is generated. Default is 10.

        .PARAMETER Silence
        Switch to suppress console output. When enabled, logs are written to file only.

        .OUTPUTS
        PSCustomObject with datastore health properties:
        - Name, IsMounted, Type, IsVMFS, FileSystemVersion, UUID, CanonicalName
        - CapacityGB, FreeSpaceGB, FreeSpacePercent, Accessible, State
        - IsHealthy, HealthIssues, ExtentCount, Extents

        .NOTES
        - Health check thresholds: free space warning if < FreeSpaceWarningThreshold (default 10%)
        - Returns IsMounted=$false if datastore not found
        - Includes extent information for VMFS datastores
    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$DatastoreName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$EsxHostName,
        [Parameter(Mandatory = $false)] [ValidateRange(0, 100)] [Int]$FreeSpaceWarningThreshold = 10,
        [Parameter(Mandatory = $false)] [Switch]$Silence,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] $VmHost
    )

    Write-LogMessage -Type DEBUG -Message "Entered Get-EsxDatastoreHealth function..."
    Write-LogMessage -Type DEBUG -SuppressOutputToScreen:$Silence -Message "Validating mounted datastore `"$DatastoreName`" on ESX host `"$EsxHostName`"..."

    try {
        $targetDatastore = Get-Datastore -Name $DatastoreName -VMHost $VmHost -ErrorAction Stop

        # Get datastore details.
        $dsView = Get-View -Id $targetDatastore.ExtensionData.MoRef

        # Check if datastore is VMFS formatted.
        $isVmfs = $targetDatastore.Type -eq "VMFS"
        $vmfsVersion = if ($isVmfs -and $dsView.Info.Vmfs) { $dsView.Info.Vmfs.Version } else { $null }
        $datastoreUuid = if ($isVmfs -and $dsView.Info.Vmfs) { $dsView.Info.Vmfs.Uuid } else { $null }

        # Check datastore health.
        $isHealthy = $true
        $healthIssues = @()

        # Check if accessible using State property (Accessible property is deprecated).
        # State should be "Available" when datastore is accessible and healthy.
        if ($targetDatastore.State -ne "Available") {
            $isHealthy = $false
            $healthIssues += "Datastore state is: $($targetDatastore.State)"
        }

        # Check capacity.
        $freeSpacePercent = [math]::Round(($targetDatastore.FreeSpaceGB / $targetDatastore.CapacityGB * 100), 2)
        if ($freeSpacePercent -lt $FreeSpaceWarningThreshold) {
            $healthIssues += "Low free space: $freeSpacePercent%"
        }

        $datastoreStatus = [PSCustomObject]@{
            Name = $targetDatastore.Name
            IsMounted = $true
            Type = $targetDatastore.Type
            IsVMFS = $isVmfs
            FileSystemVersion = $vmfsVersion
            UUID = $datastoreUuid
            CanonicalName = if ($isVmfs -and $dsView.Info.Vmfs -and $dsView.Info.Vmfs.Extent.Count -gt 0) { $dsView.Info.Vmfs.Extent[0].DiskName } else { $null }
            CapacityGB = [math]::Round($targetDatastore.CapacityGB, 2)
            FreeSpaceGB = [math]::Round($targetDatastore.FreeSpaceGB, 2)
            FreeSpacePercent = $freeSpacePercent
            State = $targetDatastore.State
            IsHealthy = $isHealthy
            HealthIssues = if ($healthIssues.Count -gt 0) { $healthIssues -join "; " } else { "None" }
            ExtentCount = if ($isVmfs -and $dsView.Info.Vmfs) { $dsView.Info.Vmfs.Extent.Count } else { 0 }
            Extents = if ($isVmfs -and $dsView.Info.Vmfs) {
                ($dsView.Info.Vmfs.Extent | ForEach-Object {
                    [PSCustomObject]@{
                        DiskName = $_.DiskName
                        Partition = $_.Partition
                    }
                })
            } else { @() }
        }

        # Log results with VMFS status.
        if ($isVmfs) {
            if ($isHealthy) {
                Write-LogMessage -Type INFO -SuppressOutputToScreen:$Silence -Message "Datastore `"$DatastoreName`" is mounted, VMFS v$vmfsVersion formatted, and healthy on ESX host `"$EsxHostName`"."
                Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "UUID: $datastoreUuid - Capacity: $($datastoreStatus.CapacityGB) GB - Free: $($datastoreStatus.FreeSpaceGB) GB ($($datastoreStatus.FreeSpacePercent)%)"
            }
            else {
                Write-LogMessage -Type WARNING -SuppressOutputToScreen:$Silence -Message "Datastore `"$DatastoreName`" is mounted and VMFS v$vmfsVersion formatted but has issues on ESX host `"$EsxHostName`": $($healthIssues -join ', ')"
            }
        }
        else {
            Write-LogMessage -Type INFO -SuppressOutputToScreen:$Silence -Message "Datastore `"$DatastoreName`" is mounted on ESX host `"$EsxHostName`" but is NOT VMFS formatted (Type: $($targetDatastore.Type))."
            if (-not $isHealthy) {
                Write-LogMessage -Type WARNING -SuppressOutputToScreen:$Silence -Message "Datastore has issues: $($healthIssues -join ', ')"
            }
        }

        return $datastoreStatus
    }
    catch {
        Write-LogMessage -Type WARNING -SuppressOutputToScreen:$Silence -Message "Datastore `"$DatastoreName`" not found or not mounted on ESX host `"$EsxHostName`": $_"
        return [PSCustomObject]@{
            Name = $DatastoreName
            IsMounted = $false
            IsVMFS = $false
            IsHealthy = $false
            HealthIssues = "Datastore not found or not mounted"
        }
    }
}
Function Select-EsxUnformattedDisk {

    <#
        .SYNOPSIS
        Interactive UI for selecting an unformatted disk from a list.

        .DESCRIPTION
        Displays a formatted table of available unformatted disks and prompts the user to select one.
        Validates user input and returns the canonical name of the selected disk.

        This is a helper function extracted from Get-EsxDatastoreInfo to separate UI concerns
        from business logic, improving testability and maintainability.

        .PARAMETER UnformattedDisks
        Array of PSCustomObject representing unformatted disks (from Get-EsxUnformattedDisk).
        Each object must have: ID, CanonicalName, CapacityGB, Vendor, Model, UUID.

        .PARAMETER Silence
        Switch to suppress non-interactive console output. When enabled, logs are written to file only.

        .OUTPUTS
        String. Returns the CanonicalName of the selected disk.
        Throws an exception if the user enters 'c' to cancel.

        .NOTES
        - Requires user interaction (Read-Host) - cannot be fully automated
        - User must select a disk (1-N) or enter 'c' to cancel (which exits the module)
        - Validates input is numeric and within valid range
        - Displays disk details in formatted table for easy selection
        - If user cancels, the function throws an exception to stop deployment
    #>

    Param (
        [Parameter(Mandatory = $false)] [Switch]$Silence,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Array]$UnformattedDisks
    )

    Write-LogMessage -Type DEBUG -Message "Entered Select-EsxUnformattedDisk function..."

    if ($UnformattedDisks.Count -eq 0) {
        Write-LogMessage -Type WARNING -SuppressOutputToScreen:$Silence -Message "No unformatted disks available for selection."
        return $null
    }

    Write-LogMessage -Type INFO -SuppressOutputToScreen:$Silence -Message "Available unformatted disks:"

    # Display table of unformatted disks.
    $selectionTable = $UnformattedDisks | Select-Object ID, CanonicalName, CapacityGB, Vendor, Model
    $selectionTable | Format-Table -AutoSize | Out-String | Write-Host

    # Prompt user for selection.
    $validSelection = $false
    $selectedId = $null

    while (-not $validSelection) {
        Write-Host "Enter the ID of the disk to select (1-$($UnformattedDisks.Count)) or 'c' to cancel: " -NoNewline -ForegroundColor Yellow
        $userInput = Read-Host

        # Check for cancel option.
        if ($userInput -eq 'c' -or $userInput -eq 'C') {
            Write-Host ""
            Write-LogMessage -Type WARNING -SuppressOutputToScreen:$Silence -Message "User cancelled disk selection."
            Write-LogMessage -Type ERROR -SuppressOutputToScreen:$Silence -Message "Disk selection cancelled. Cannot proceed with deployment."
            throw "Deployment failed. Check logs for details."
        }
        elseif ($userInput -match '^\d+$') {
            $selectedId = [int]$userInput

            if ($selectedId -ge 1 -and $selectedId -le $UnformattedDisks.Count) {
                Write-Host ""
                $selectedDisk = $UnformattedDisks | Where-Object { $_.ID -eq $selectedId }
                Write-LogMessage -Type INFO -SuppressOutputToScreen:$Silence -Message "Selected disk: $($selectedDisk.CanonicalName) - UUID: $($selectedDisk.UUID) - Capacity: $($selectedDisk.CapacityGB) GB"
                return $selectedDisk.CanonicalName
            }
            else {
                Write-Host "Invalid selection. Please enter a number between 1 and $($UnformattedDisks.Count), or 'c' to cancel." -ForegroundColor Red
            }
        }
        else {
            Write-Host "Invalid input. Please enter a number between 1 and $($UnformattedDisks.Count), or 'c' to cancel." -ForegroundColor Red
        }
    }
}
Function Get-EsxDatastoreInfo {

    <#
        .SYNOPSIS
        Scans an ESX host for unformatted datastores and validates mounted datastores.

        .DESCRIPTION
        Orchestrator function that provides backward-compatible interface to datastore scanning operations.
        Delegates to specialized helper functions for improved maintainability:
        - Get-EsxUnformattedDisk: Scans for unformatted disks
        - Get-EsxDatastoreHealth: Validates datastore health
        - Select-EsxUnformattedDisk: Interactive disk selection UI

        The function reports UUID, capacity, and health status for discovered datastores.
        This function requires a direct connection to the ESX host.

        Key features:
        - Identifies unformatted storage devices available for use
        - Validates health of mounted datastores including accessibility, state, and free space
        - Provides detailed capacity information for all discovered storage
        - Returns structured data for programmatic processing

        .PARAMETER EsxHostName
        The hostname or IP address of the ESX host to scan. This parameter is mandatory.
        Requires an active direct connection to the ESX host.

        .PARAMETER DatastoreName
        Optional. Name of a specific mounted datastore to validate.
        When specified, the function ONLY checks this specific datastore and skips unformatted disk scans.
        Performs health checks including mount status, VMFS formatting, accessibility, state, and free space validation.

        .PARAMETER SelectUnformattedDatastore
        Switch to enable interactive selection of an unformatted datastore.
        When enabled, displays a table of unformatted disks with ID, UUID, and capacity.
        User can select a disk by entering its ID.
        The selected disk UUID will be included in the return value.
        This parameter is ignored if -DatastoreName is specified.

        .PARAMETER Silence
        Switch to suppress all console output.
        When enabled, all log messages are written to the log file only (using -SuppressOutputToScreen).
        Useful for automation scenarios where console output should be minimized.

        .EXAMPLE
        Get-EsxDatastoreInfo -EsxHostName "esx01.example.com"

        Scans the ESX host for all unformatted disks/LUNs.

        .EXAMPLE
        Get-EsxDatastoreInfo -EsxHostName "esx01.example.com" -DatastoreName "datastore1"

        Validates that datastore "datastore1" is mounted and healthy on the specified host.
        Checks if it is VMFS formatted and reports the VMFS version if applicable.

        .EXAMPLE
        Get-EsxDatastoreInfo -esxHostName "esx01.example.com" -selectUnformattedDatastore

        Scans for unformatted disks and prompts the user to select one by ID.
        Returns the selected disk UUID in the SelectedDatastoreUUID property.

        .EXAMPLE
        Get-EsxDatastoreInfo -esxHostName "esx01.example.com" -datastoreName "datastore1" -silence

        Validates datastore "datastore1" health with all output suppressed to console.
        Logs are written only to the log file (useful for automation).

        .OUTPUTS
        PSCustomObject with properties:
        - EsxHost: The hostname or IP of the scanned ESX host
        - UnformattedDisks: Array of unformatted disks/LUNs with UUID, capacity, and vendor info
        - MountedDatastoreStatus: Health status of specified datastore with the following properties:
          * IsMounted: Boolean indicating if datastore is mounted
          * IsVMFS: Boolean indicating if datastore is VMFS formatted
          * Type: Datastore type (VMFS, NFS, vVOL, etc.)
          * FileSystemVersion: VMFS version number (if VMFS formatted)
          * UUID: Datastore UUID (if VMFS formatted)
          * CanonicalName: Canonical name of the underlying disk device (e.g., "naa:xxxxx") for the first extent
          * Name, CapacityGB, FreeSpaceGB, FreeSpacePercent, Accessible, State, IsHealthy, HealthIssues
        - SelectedDatastoreUUID: UUID of selected unformatted disk (if selectUnformattedDatastore is used)

        .NOTES
        - Requires an active direct connection to the ESX host
        - Requires PowerCLI modules to be installed (VMware.VimAutomation.Core)
        - Health check criteria includes accessibility, state, and free space (warning if < 10%)
        - Uses Write-LogMessage with -SuppressOutputToScreen for consistent logging throughout the script
        - Follows the error handling patterns of the SimpleSupervisorDeploymentAtScale module
        - Refactored into modular helper functions for improved maintainability and testability
    #>

    Param (
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$DatastoreName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$EsxHostName,
        [Parameter(Mandatory = $false)] [Switch]$SelectUnformattedDatastore,
        [Parameter(Mandatory = $false)] [Switch]$Silence
    )

    Write-LogMessage -Type DEBUG -Message "Entered Get-EsxDatastoreInfo function..."

    # Verify vCenter connection before proceeding.
    $connectionTest = Test-VcenterConnection
    if (-not $connectionTest.IsConnected) {
        Write-LogMessage -Type ERROR -Message "Not connected to vCenter `"$Script:VCenterName`": $($connectionTest.ErrorMessage)"
        throw "Deployment failed. Check logs for details."
    }

    try {
        # If datastoreName is specified, only check that specific datastore.
        if ($DatastoreName) {
            Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "Checking for specific datastore `"$DatastoreName`" only."
        }
        else {
            Write-LogMessage -Type INFO -SuppressOutputToScreen:$Silence -Message "Starting datastore scan on ESX host `"$EsxHostName`"..."
        }

        # Get VMHost object from direct ESX connection.
        try {
            $vmHost = Get-VMHost -Name $EsxHostName -Server $EsxHostName -ErrorAction Stop
        }
        catch [System.UnauthorizedAccessException] {
            Write-LogMessage -Type ERROR -Message "Cannot access ESX host `"$EsxHostName`" due to authorization issues: $_"
            throw "Deployment failed. Check logs for details."
        }
        catch [System.TimeoutException] {
            Write-LogMessage -Type ERROR -Message "Cannot access ESX host `"$EsxHostName`" due to network/timeout issues: $_"
            throw "Deployment failed. Check logs for details."
        }
        catch {
            Write-LogMessage -Type ERROR -Message "Failed to get ESX host `"$EsxHostName`": $_"
            throw "Deployment failed. Check logs for details."
        }

        # Initialize result object.
        $result = [PSCustomObject]@{
            EsxHost = $EsxHostName
            UnformattedDisks = @()
            MountedDatastoreStatus = $null
            SelectedDatastoreUUID = $null
        }

        # Check for unformatted disks and LUNs (if not checking specific datastore).
        if (-not $DatastoreName) {
            # Delegate to Get-EsxUnformattedDisk helper function.
            $result.UnformattedDisks = Get-EsxUnformattedDisk -vmHost $vmHost -esxHostName $EsxHostName -silence:$Silence

            # Interactive selection if requested.
            if ($SelectUnformattedDatastore) {
                # Delegate to Select-EsxUnformattedDisk helper function.
                $selectedCanonicalName = Select-EsxUnformattedDisk -unformattedDisks $result.UnformattedDisks -silence:$Silence
                $result.SelectedDatastoreUUID = $selectedCanonicalName
            }

            # Log summary.
            Write-LogMessage -Type INFO -SuppressOutputToScreen:$Silence -Message "Datastore scan completed on ESX host `"$EsxHostName`". Unformatted disks: $($result.UnformattedDisks.Count)"
        }

        # Check specific mounted datastore health if requested.
        if ($DatastoreName) {
            # Delegate to Get-EsxDatastoreHealth helper function.
            $result.MountedDatastoreStatus = Get-EsxDatastoreHealth -vmHost $vmHost -esxHostName $EsxHostName -datastoreName $DatastoreName -silence:$Silence
        }

        # Return the result object.
        return $result
    }
    catch {
        Write-LogMessage -Type ERROR -SuppressOutputToScreen:$Silence -Message "Failed to scan ESX host `"$EsxHostName`": $_"
        Write-LogMessage -Type EXCEPTION -Message $_.Exception.Message
        throw "Deployment failed. Check logs for details."
    }
}
Function Wait-SupervisorReady {

    <#
        .SYNOPSIS
        Waits for a Supervisor to become ready by monitoring its configuration and Kubernetes status.

        .DESCRIPTION
        The Wait-SupervisorReady function monitors a Supervisor's readiness by repeatedly checking its
        ConfigStatus and KubernetesStatus until both reach the desired state (RUNNING and READY) or
        until a timeout occurs. This function provides progress feedback and returns status to the caller.

        The function polls the Supervisor status at regular intervals and displays progress information
        including elapsed time, configuration status, and Kubernetes status. Returns $true on success
        or $false on timeout, allowing the calling function to handle cleanup and error processing.

        .PARAMETER SupervisorId
        The ID of the Supervisor to monitor. This parameter is mandatory.

        .PARAMETER ClusterName
        The name of the cluster where the Supervisor is deployed. Used for logging purposes.

        .PARAMETER CheckInterval
        The interval in seconds between status checks. Default is 10 seconds.

        .PARAMETER TotalWaitTime
        The maximum time in seconds to wait for the Supervisor to become ready. Default is 1800 seconds (30 minutes).

        .EXAMPLE
        $success = Wait-SupervisorReady -SupervisorId $supId -ClusterName "MyCluster"
        if (-not $success) {
            # Handle timeout/failure
        }

        Waits for the specified Supervisor to become ready and checks the result.

        .EXAMPLE
        Wait-SupervisorReady -SupervisorId $supId -ClusterName "MyCluster" -CheckInterval 15 -TotalWaitTime 3600

        Waits up to 1 hour, checking every 15 seconds.

        .OUTPUTS
        PSCustomObject with properties:
        - Success: Boolean indicating if Supervisor became ready ($true) or timed out ($false)
        - ElapsedSeconds: Integer representing the elapsed time in seconds

        .NOTES
        - Requires an active vCenter connection
        - Uses Invoke-GetSupervisorNamespaceManagementSummary to check status
        - Returns object with success status and elapsed time
        - Does not exit script; allows graceful error handling by caller
    #>

    Param (
        [Parameter(Mandatory = $false)] [ValidateRange(1, [int]::MaxValue)] [Int]$CheckInterval = 10,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$SupervisorId,
        [Parameter(Mandatory = $false)] [ValidateRange(1, [int]::MaxValue)] [Int]$TotalWaitTime = 1800
    )

    Write-LogMessage -Type DEBUG -Message "Entered Wait-SupervisorReady function..."

    $elapsedTime = 0
    $currentCheck = 0

    try {
        do {
            $currentCheck++

            try {
                $supervisorStatus = Invoke-GetSupervisorNamespaceManagementSummary -Supervisor $SupervisorId
            }
            catch {
                $errorMsg = $_.Exception.Message

                # Check for common transient network/API errors.

                if ($errorMsg -match "An error occurred while sending the request|The operation has timed out") {
                    Write-LogMessage -Type DEBUG -Message "Transient API error during supervisor status check (attempt $currentCheck): $errorMsg"

                    # Continue waiting if we haven't exceeded total wait time.

                    if ($elapsedTime -lt $TotalWaitTime) {
                        $statusMessage = "Elapsed Time: $elapsedTime seconds - Status: Waiting for API response..."
                        Write-Progress -Activity "Waiting for Supervisor services to become available" -Status $statusMessage
                        Start-Sleep $CheckInterval
                        $elapsedTime += $CheckInterval
                        continue
                    }
                    else {
                        # Timeout reached
                        Write-Progress -Activity "Waiting for Supervisor services to become available" -Status "Timeout" -Completed
                        Write-LogMessage -Type ERROR -Message "Timeout waiting for supervisor services API to respond on cluster `"$ClusterName`" after $TotalWaitTime seconds."
                        Write-LogMessage -Type ERROR -Message "The supervisor may still be initializing. Check vCenter UI for current status."
                        return [PSCustomObject]@{
                            Success = $false
                            ElapsedSeconds = $elapsedTime
                        }
                    }
                }
                else {
                    # Non-transient error, re-throw
                    throw
                }
            }

            if ((($supervisorStatus).ConfigStatus -eq "RUNNING") -and (($supervisorStatus).KubernetesStatus -eq "READY")) {
                Write-Progress -Activity "Waiting for Supervisor services to become available" -Status "Complete" -Completed
                Write-LogMessage -Type INFO -Message "Supervisor services on cluster `"$ClusterName`" were successfully configured in $elapsedTime seconds."
                return [PSCustomObject]@{
                    Success = $true
                    ElapsedSeconds = $elapsedTime
                }
            } else {
                $statusMessage = "Elapsed Time: $elapsedTime seconds - Status: $($supervisorStatus.ConfigStatus)"
                $currentStatus = "Kubernetes Status: $($supervisorStatus.KubernetesStatus)"
                Write-Progress -Activity "Waiting for Supervisor services to become available" -Status $statusMessage -CurrentOperation $currentStatus
                Start-Sleep $CheckInterval
                $elapsedTime += $CheckInterval
            }
        } while ($elapsedTime -lt $TotalWaitTime)

        # If we exit the loop without success, log timeout and clear progress.

        Write-Progress -Activity "Waiting for Supervisor services to become available" -Status "Timeout" -Completed
        Write-LogMessage -Type ERROR -Message "Timeout waiting for supervisor services to become ready on cluster `"$ClusterName`" after $TotalWaitTime seconds ($elapsedTime seconds elapsed)."
        return [PSCustomObject]@{
            Success = $false
            ElapsedSeconds = $elapsedTime
        }
    }
    catch {
        # Log exception with context, then return failure with elapsed time.

        Write-Progress -Activity "Waiting for Supervisor services to become available" -Status "Error" -Completed
        Write-LogMessage -Type ERROR -Message "Error checking supervisor services status on cluster `"$ClusterName`": $_"
        Write-Host ""
        Write-LogMessage -Type ERROR -Message "This may indicate:"
        Write-LogMessage -Type ERROR -Message "  1. Network connectivity issues between the client and vCenter"
        Write-LogMessage -Type ERROR -Message "  2. vCenter API temporarily unavailable"
        Write-LogMessage -Type ERROR -Message "  3. Supervisor is in a failed state"
        Write-Host ""
        Write-LogMessage -Type ERROR -Message "Check the supervisor status in vCenter UI: Menu > Workload Management > Supervisors"
        return [PSCustomObject]@{
            Success = $false
            ElapsedSeconds = $elapsedTime
        }
    }
}

Function Get-ManagementNetworkConfig {

    <#
        .SYNOPSIS
        Extracts and validates management network configuration from supervisor specification.

        .DESCRIPTION
        Parses management network configuration from the TKGS component specification,
        validates IP assignment mode (must be STATIC), and resolves port group IDs.

        .PARAMETER Spec
        Management network specification object from supervisorDetails.tkgsComponentSpec.tkgsMgmtNetworkSpec

        .OUTPUTS
        PSCustomObject with validated management network configuration

        .EXAMPLE
        $mgmtConfig = Get-ManagementNetworkConfig -Spec $supervisorDetails.tkgsComponentSpec.tkgsMgmtNetworkSpec
    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [PSCustomObject]$Spec
    )

    Write-LogMessage -Type DEBUG -Message "Entered Get-ManagementNetworkConfig function..."

    try {
        # Validate IP assignment mode (DHCP not supported for management network).
        $ipAssignmentMode = $Spec.tkgsMgmtIpAssignmentMode
        Write-LogMessage -Type DEBUG -Message "  Validating IP assignment mode: $ipAssignmentMode"
        if ($ipAssignmentMode -ne "STATIC") {
            Write-LogMessage -Type ERROR -Message "Management network only supports STATIC IP assignment mode. Received: $ipAssignmentMode"
            throw "Deployment failed. Check logs for details."
        }

        # Resolve port group ID.
        $networkName = $Spec.tkgsMgmtNetworkName
        Write-LogMessage -Type DEBUG -Message "  Resolving port group ID for management network: $networkName"
        $portgroupID = Get-PortGroupId -portGroupName $networkName

        if ([string]::IsNullOrEmpty($portgroupID)) {
            Write-LogMessage -Type ERROR -Message "Failed to resolve port group ID for management network: $networkName"
            throw "Deployment failed. Check logs for details."
        }

        # Build configuration object.
        $config = [PSCustomObject]@{
            Name = $networkName
            PortGroupID = $portgroupID
            IPAssignmentMode = $ipAssignmentMode
            DHCPEnabled = $false
            StartingIP = $Spec.tkgsMgmtNetworkStartingIp
            IPCount = $Spec.tkgsMgmtNetworkIPCount
            Gateway = $Spec.tkgsMgmtNetworkGatewayCidr
            DNSServers = $Spec.tkgsMgmtNetworkDnsServers
            NTPServers = $Spec.tkgsMgmtNetworkNtpServers
            SearchDomains = $Spec.tkgsMgmtNetworkSearchDomains
        }

        Write-LogMessage -Type INFO -Message "  Management network configuration extracted: $($config.Name) with $($config.IPCount) IPs"
        Write-LogMessage -Type INFO -Message "    Starting IP: $($config.StartingIP), Gateway: $($config.Gateway)."
        return $config
    }
    catch {
        Write-LogMessage -Type ERROR -Message "Failed to extract management network configuration: $_"
        throw "Deployment failed. Check logs for details."
    }
}

Function Get-WorkloadNetworkConfig {

    <#
        .SYNOPSIS
        Extracts and validates workload network configuration from supervisor specification.

        .DESCRIPTION
        Parses workload network configuration from the TKGS component specification,
        validates IP assignment mode (must be STATIC), and resolves port group IDs.

        .PARAMETER Spec
        Workload network specification object from supervisorDetails.tkgsComponentSpec.tkgsPrimaryWorkloadNetwork

        .OUTPUTS
        PSCustomObject with validated workload network configuration

        .EXAMPLE
        $workloadConfig = Get-WorkloadNetworkConfig -Spec $supervisorDetails.tkgsComponentSpec.tkgsPrimaryWorkloadNetwork
    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [PSCustomObject]$Spec
    )

    Write-LogMessage -Type DEBUG -Message "Entered Get-WorkloadNetworkConfig function..."

    try {
        # Validate IP assignment mode (DHCP not supported for workload network).
        $ipAssignmentMode = $Spec.tkgsPrimaryWorkloadIpAssignmentMode
        Write-LogMessage -Type DEBUG -Message "  Validating IP assignment mode: $ipAssignmentMode."
        if ($ipAssignmentMode -ne "STATIC") {
            Write-LogMessage -Type ERROR -Message "Workload network only supports STATIC IP assignment mode. Received: $ipAssignmentMode."
            throw "Deployment failed. Check logs for details."
        }

        # Resolve port group ID.
        $networkName = $Spec.tkgsPrimaryWorkloadNetworkName
        Write-LogMessage -Type DEBUG -Message "  Resolving port group ID for workload network: $networkName."
        $portgroupID = Get-PortGroupId -portGroupName $networkName

        if ([string]::IsNullOrEmpty($portgroupID)) {
            Write-LogMessage -Type ERROR -Message "Failed to resolve port group ID for workload network: $networkName."
            throw "Deployment failed. Check logs for details."
        }

        # Build configuration object.
        $config = [PSCustomObject]@{
            Name = $networkName
            PortGroupID = $portgroupID
            IPAssignmentMode = $ipAssignmentMode
            DHCPEnabled = $false
            StartingIP = $Spec.tkgsPrimaryWorkloadNetworkStartingIp
            IPCount = $Spec.tkgsPrimaryWorkloadNetworkIPCount
            Gateway = $Spec.tkgsPrimaryWorkloadNetworkGatewayCidr
            DNSServers = $Spec.tkgsWorkloadDnsServers
            NTPServers = $Spec.tkgsWorkloadNtpServers
            SearchDomains = $Spec.tkgsPrimaryWorkloadNetworkSearchDomains
            ServiceStartIP = $Spec.tkgsWorkloadServiceStartIp
            ServiceCount = $Spec.tkgsWorkloadServiceCount
        }

        Write-LogMessage -Type INFO -Message "  Workload network configuration extracted: $($config.Name) with $($config.IPCount) node IPs and $($config.ServiceCount) service IPs."
        Write-LogMessage -Type INFO -Message "    Node IP: $($config.StartingIP), Service IP: $($config.ServiceStartIP)."
        return $config
    }
    catch {
        Write-LogMessage -Type ERROR -Message "Failed to extract workload network configuration: $_"
        throw "Deployment failed. Check logs for details."
    }
}

Function Get-FLBNetworkConfig {

    <#
        .SYNOPSIS
        Extracts Foundation Load Balancer network configuration.

        .DESCRIPTION
        Parses FLB network configuration (management or virtual server network) and resolves port group IDs.

        .PARAMETER NetworkSpec
        FLB network specification from foundationLoadBalancerComponents

        .OUTPUTS
        PSCustomObject with FLB network configuration

        .EXAMPLE
        $flbMgmtNet = Get-FLBNetworkConfig -NetworkSpec $supervisorDetails.tkgsComponentSpec.foundationLoadBalancerComponents.flbManagementNetwork
    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [PSCustomObject]$NetworkSpec
    )

    Write-LogMessage -Type DEBUG -Message "Entered Get-FLBNetworkConfig function..."

    try {
        # Resolve port group ID.
        $networkName = $NetworkSpec.flbNetworkName
        Write-LogMessage -Type DEBUG -Message "  Resolving port group ID for FLB network: $networkName"
        $portGroupID = Get-PortGroupId -portGroupName $networkName

        if ([string]::IsNullOrEmpty($portGroupID)) {
            Write-LogMessage -Type ERROR -Message "Failed to resolve port group ID for FLB network: $networkName"
            throw "Deployment failed. Check logs for details."
        }

        # Build configuration object.
        $config = [PSCustomObject]@{
            Name = $networkName
            PortGroupID = $portGroupID
            Type = $NetworkSpec.flbNetworkType
            IPAssignmentMode = $NetworkSpec.flbNetworkIpAssignmentMode
            StartingIP = $NetworkSpec.flbNetworkIpAddressStartingIp
            IPCount = $NetworkSpec.flbNetworkIpAddressCount
            Gateway = $NetworkSpec.flbNetworkGateway
        }

        Write-LogMessage -Type INFO -Message "  FLB network configuration extracted: $($config.Name), Type: $($config.Type)"
        Write-LogMessage -Type INFO -Message "    IP Assignment: $($config.IPAssignmentMode), Count: $($config.IPCount)"
        return $config
    }
    catch {
        Write-LogMessage -Type ERROR -Message "Failed to extract FLB network configuration: $_"
        throw "Deployment failed. Check logs for details."
    }
}

Function Get-LoadBalancerConfig {

    <#
        .SYNOPSIS
        Extracts Foundation Load Balancer configuration from supervisor specification.

        .DESCRIPTION
        Parses complete FLB configuration including both management and virtual server networks.

        .PARAMETER Spec
        Foundation Load Balancer specification from supervisorDetails.tkgsComponentSpec.foundationLoadBalancerComponents

        .OUTPUTS
        PSCustomObject with complete FLB configuration

        .EXAMPLE
        $flbConfig = Get-LoadBalancerConfig -Spec $supervisorDetails.tkgsComponentSpec.foundationLoadBalancerComponents
    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [PSCustomObject]$Spec
    )

    Write-LogMessage -Type DEBUG -Message "Entered Get-LoadBalancerConfig function..."

    try {
        Write-LogMessage -Type DEBUG -Message "Extracting Foundation Load Balancer configuration..."

        # Extract management and virtual server network configurations.
        $mgmtNetwork = Get-FLBNetworkConfig -NetworkSpec $Spec.flbManagementNetwork
        $vsNetwork = Get-FLBNetworkConfig -NetworkSpec $Spec.flbVirtualServerNetwork

        # Build configuration object.
        $config = [PSCustomObject]@{
            Name = $Spec.flbName
            Size = $Spec.flbSize
            Availability = $Spec.flbAvailability
            VipStartIP = $Spec.flbVipStartIP
            VipIPCount = $Spec.flbVipIPCount
            Provider = $Spec.flbProvider
            DNSServers = $Spec.flbDnsServers
            NTPServers = $Spec.flbNtpServers
            SearchDomains = $Spec.flbSearchDomains
            ManagementNetwork = $mgmtNetwork
            VirtualServerNetwork = $vsNetwork
        }

        Write-LogMessage -Type INFO -Message "FLB configuration extracted: $($config.Name), Size: $($config.Size), VIPs: $($config.VipIPCount)"
        return $config
    }
    catch {
        Write-LogMessage -Type ERROR -Message "Failed to extract Foundation Load Balancer configuration: $_"
        throw "Deployment failed. Check logs for details."
    }
}

Function Get-SupervisorConfigurationFromJson {

    <#
        .SYNOPSIS
        Parses supervisor JSON configuration into a structured configuration object.

        .DESCRIPTION
        Extracts and validates all supervisor configuration parameters from the input JSON file,
        returning a PSCustomObject with organized sections for control plane, networks, and FLB.
        This function delegates to specialized parsers for each configuration section.

        .PARAMETER JsonFilePath
        Full path to the JSON configuration file containing supervisor specifications

        .OUTPUTS
        PSCustomObject with structured configuration:
        - ControlPlane: VM count and size
        - ManagementNetwork: Network configuration for control plane
        - WorkloadNetwork: Network configuration for workloads
        - LoadBalancer: FLB configuration including management and virtual server networks

        .EXAMPLE
        $config = Get-SupervisorConfigurationFromJson -JsonFilePath "C:\configs\supervisor.json"
        Write-Host "Control Plane Size: $($config.ControlPlane.Size)"
    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$JsonFilePath
    )

    Write-LogMessage -Type DEBUG -Message "Entered Get-SupervisorConfigurationFromJson function..."

    try {
        Write-LogMessage -Type DEBUG -Message "Parsing supervisor configuration from JSON file..."

        # Parse JSON file.
        $supervisorDetails = ConvertFrom-JsonSafely -JsonFilePath $JsonFilePath

        if ($null -eq $supervisorDetails) {
            Write-LogMessage -Type ERROR -Message "Failed to parse JSON file or file is empty"
            throw "Deployment failed. Check logs for details."
        }

        # Extract control plane configuration.
        Write-LogMessage -Type DEBUG -Message "Extracting control plane configuration..."
        $controlPlane = [PSCustomObject]@{
            VMCount = $supervisorDetails.supervisorSpec.controlPlaneVMCount
            Size = $supervisorDetails.supervisorSpec.controlPlaneSize
        }

        # Extract network configurations using specialized functions.
        Write-LogMessage -Type DEBUG -Message "Extracting network configurations..."
        $mgmtNetwork = Get-ManagementNetworkConfig -Spec $supervisorDetails.tkgsComponentSpec.tkgsMgmtNetworkSpec
        $workloadNetwork = Get-WorkloadNetworkConfig -Spec $supervisorDetails.tkgsComponentSpec.tkgsPrimaryWorkloadNetwork
        $loadBalancer = Get-LoadBalancerConfig -Spec $supervisorDetails.tkgsComponentSpec.foundationLoadBalancerComponents

        # Build structured configuration object.
        $config = [PSCustomObject]@{
            ControlPlane = $controlPlane
            ManagementNetwork = $mgmtNetwork
            WorkloadNetwork = $workloadNetwork
            LoadBalancer = $loadBalancer
        }

        Write-LogMessage -Type INFO -Message "Supervisor configuration parsed successfully"
        Write-LogMessage -Type INFO -Message "Control Plane: $($controlPlane.VMCount) x $($controlPlane.Size)"
        Write-LogMessage -Type INFO -Message "Management Network: $($mgmtNetwork.Name)"
        Write-LogMessage -Type INFO -Message "Workload Network: $($workloadNetwork.Name)"
        Write-LogMessage -Type INFO -Message "Load Balancer: $($loadBalancer.Name)"

        return $config
    }
    catch {
        Write-LogMessage -Type ERROR -Message "Failed to parse supervisor configuration from JSON: $_"
        throw "Deployment failed. Check logs for details."
    }
}

Function Test-SupervisorConfiguration {

    <#
        .SYNOPSIS
        Validates supervisor configuration structure before deployment.

        .DESCRIPTION
        Performs runtime validation of supervisor configuration object structure to ensure all
        required configuration sections are present. This function validates:
        • Management network configuration object exists
        • Workload network configuration object exists
        • Foundation Load Balancer configuration object exists
        • Control plane configuration object exists
        • Workload service count meets recommended minimum (configurable via MinimumServiceCount parameter, default 16)

        This function performs STRUCTURAL validation only. Value-level validation is handled by:
        • Test-JsonNullValues: Validates all properties have non-null values
        • Test-JsonDeeperValidation: Validates property formats, ranges, and business rules

        .PARAMETER Config
        Complete supervisor configuration object from Get-SupervisorConfigurationFromJson.

        .PARAMETER MinimumServiceCount
        The minimum recommended service count for workload network. Default is 16.

        .OUTPUTS
        Boolean: $true if validation passes, $false if validation fails.

        .EXAMPLE
        $config = Get-SupervisorConfigurationFromJson -JsonFilePath $InfrastructureJson
        if (-not (Test-SupervisorConfiguration -Config $config)) {
            Write-LogMessage -Type ERROR -Message "Configuration validation failed"
            throw "Deployment failed. Check logs for details."
        }

        .NOTES
        This function logs detailed information about validation failures to aid troubleshooting.
        All validation errors are logged but the function returns a simple boolean result.

        Validation Responsibilities:
        • Test-JsonNullValues: Null value checks (runs first during JSON validation)
        • Test-JsonDeeperValidation: Format, range, and business rule validation
        • Test-SupervisorConfiguration: Runtime structural validation (this function)
    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSCustomObject]$Config,
        [Parameter(Mandatory = $false)] [ValidateRange(1, [int]::MaxValue)] [Int]$MinimumServiceCount = 16
    )

    Write-LogMessage -Type DEBUG -Message "Entered Test-SupervisorConfiguration function..."

    $validationPassed = $true

    try {
        Write-LogMessage -Type DEBUG -Message "Validating supervisor configuration..."

        # Validate management network configuration.
        # Note: Null value checks for management network properties are handled by Test-JsonNullValues
        if (-not $Config.ManagementNetwork) {
            Write-LogMessage -Type ERROR -Message "Validation failed: Management network configuration is missing"
            $validationPassed = $false
        } else {
            Write-LogMessage -Type DEBUG -Message "  Validating management network..."
            # Runtime validation passed - null value validation already performed by Test-JsonNullValues.

        }

        # Validate workload network configuration.
        # Note: Null value checks for workload network properties are handled by Test-JsonNullValues
        if (-not $Config.WorkloadNetwork) {
            Write-LogMessage -Type ERROR -Message "Validation failed: Workload network configuration is missing"
            $validationPassed = $false
        } else {
            Write-LogMessage -Type DEBUG -Message "  Validating workload network..."
            # Runtime validation passed - null value validation already performed by Test-JsonNullValues.

            # Note: Workload network IP count minimum (2) is validated in Test-JsonDeeperValidation

            if ($Config.WorkloadNetwork.ServiceCount -lt $MinimumServiceCount) {
                Write-LogMessage -Type WARNING -Message "    Workload network service count ($($Config.WorkloadNetwork.ServiceCount)) is low (recommended minimum $MinimumServiceCount)"
            }
        }

        # Validate control plane configuration.
        # Note: Control plane size and VM count are validated in Test-JsonDeeperValidation
        if (-not $Config.ControlPlane) {
            Write-LogMessage -Type ERROR -Message "Validation failed: Control plane configuration is missing"
            $validationPassed = $false
        } else {
            Write-LogMessage -Type DEBUG -Message "  Validating control plane..."
            # Runtime validation passed - JSON validation already checked size and VM count.

        }

        # Validate load balancer configuration.
        # Note: Load balancer availability mode is validated in Test-JsonDeeperValidation
        if (-not $Config.LoadBalancer) {
            Write-LogMessage -Type ERROR -Message "Validation failed: Load balancer configuration is missing"
            $validationPassed = $false
        } else {
            Write-LogMessage -Type DEBUG -Message "  Validating load balancer..."

            if (-not $Config.LoadBalancer.ManagementNetwork) {
                Write-LogMessage -Type ERROR -Message "    Load balancer management network is missing"
                $validationPassed = $false
            }
            # Note: FLB management network IP count minimum (2) is validated in Test-JsonDeeperValidation

            if (-not $Config.LoadBalancer.VirtualServerNetwork) {
                Write-LogMessage -Type ERROR -Message "    Load balancer virtual server network is missing"
                $validationPassed = $false
            }
            # Note: FLB virtual server network IP count minimum (2) is validated in Test-JsonDeeperValidation
        }

        if ($validationPassed) {
            Write-LogMessage -Type INFO -Message "Configuration validation passed"
        } else {
            Write-LogMessage -Type ERROR -Message "Configuration validation failed - review errors above"
        }

        return $validationPassed
    }
    catch {
        Write-LogMessage -Type ERROR -Message "Configuration validation encountered an error: $_"
        return $false
    }
}

Function New-SupervisorControlPlaneSpec {

    <#
        .SYNOPSIS
        Creates VCF PowerCLI 9 control plane specification for supervisor deployment.

        .DESCRIPTION
        Builds the complete control plane specification using VCF PowerCLI 9 Initialize-* cmdlets.
        This function constructs the management network configuration including network backing,
        DNS/NTP services, IP management, and control plane settings required for supervisor enablement.

        Based on VCF PowerCLI 9 SDK patterns for supervisor namespace management.

        .PARAMETER ControlPlaneConfig
        Control plane configuration object containing VMCount and Size properties.

        .PARAMETER ManagementNetworkConfig
        Management network configuration object with network settings, DNS, NTP, and IP configuration.

        .PARAMETER StoragePolicyId
        Storage policy MoRef ID for control plane VMs.

        .OUTPUTS
        VCF PowerCLI 9 control plane specification object ready for supervisor enablement.

        .EXAMPLE
        $controlPlaneSpec = New-SupervisorControlPlaneSpec -ControlPlaneConfig $config.ControlPlane -ManagementNetworkConfig $config.ManagementNetwork -StoragePolicyId $policyId
    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [PSCustomObject]$ControlPlaneConfig,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [PSCustomObject]$ManagementNetworkConfig,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$StoragePolicyId
    )

    Write-LogMessage -Type DEBUG -Message "Entered New-SupervisorControlPlaneSpec function..."

    try {
        Write-LogMessage -Type INFO -Message "Building control plane specification..."

        # Build network backing.
        $networkBacking = Initialize-VcenterNamespaceManagementSupervisorsNetworksManagementNetworkBacking `
            -Backing "NETWORK" `
            -Network $ManagementNetworkConfig.PortGroupID

        # Build DNS configuration.
        $dns = Initialize-VcenterNamespaceManagementNetworksServiceDNS `
            -Servers $ManagementNetworkConfig.DNSServers `
            -SearchDomains $ManagementNetworkConfig.SearchDomains

        # Build NTP configuration.
        $ntp = Initialize-VcenterNamespaceManagementNetworksServiceNTP `
            -Servers $ManagementNetworkConfig.NTPServers

        # Build network services.
        $services = Initialize-VcenterNamespaceManagementNetworksServices `
            -Dns $dns `
            -Ntp $ntp

        # Build IP range for management network.
        $ipRange = Initialize-VcenterNamespaceManagementNetworksIPRange `
            -Address $ManagementNetworkConfig.StartingIP `
            -Count $ManagementNetworkConfig.IPCount

        # Build IP assignment for NODE.
        $ipAssignment = Initialize-VcenterNamespaceManagementNetworksIPAssignment `
            -Assignee "NODE" `
            -Ranges $ipRange

        # Build IP management configuration.
        $ipManagement = Initialize-VcenterNamespaceManagementNetworksIPManagement `
            -DhcpEnabled $ManagementNetworkConfig.DHCPEnabled `
            -GatewayAddress $ManagementNetworkConfig.Gateway `
            -IpAssignments $ipAssignment

        # Build management network configuration.
        $managementNetwork = Initialize-VcenterNamespaceManagementSupervisorsNetworksManagementNetwork `
            -Network $ManagementNetworkConfig.PortGroupID `
            -Backing $networkBacking `
            -Services $services `
            -IpManagement $ipManagement

        # Build control plane configuration.
        $controlPlane = Initialize-VcenterNamespaceManagementSupervisorsControlPlane `
            -Network $managementNetwork `
            -LoginBanner "" `
            -Size $ControlPlaneConfig.Size `
            -StoragePolicy $StoragePolicyId `
            -Count $ControlPlaneConfig.VMCount

        Write-LogMessage -Type INFO -Message "Control plane specification built successfully: Size=$($ControlPlaneConfig.Size), VMs=$($ControlPlaneConfig.VMCount)"
        return $controlPlane
    }
    catch {
        Write-LogMessage -Type ERROR -Message "Failed to build control plane specification: $_"
        throw "Deployment failed. Check logs for details."
    }
}

Function New-SupervisorWorkloadSpec {

    <#
        .SYNOPSIS
        Creates VCF PowerCLI 9 workload specification for supervisor deployment.

        .DESCRIPTION
        Builds the complete workload network specification using VCF PowerCLI 9 Initialize-* cmdlets.
        This function constructs the workload network configuration including DNS/NTP services,
        IP management for both nodes and services, and vSphere network settings.

        Based on VCF PowerCLI 9 SDK patterns for supervisor workload configuration.

        .PARAMETER WorkloadNetworkConfig
        Workload network configuration object with network settings, DNS, NTP, and IP configuration.

        .OUTPUTS
        VCF PowerCLI 9 workload network specification object ready for supervisor enablement.

        .EXAMPLE
        $workloadSpec = New-SupervisorWorkloadSpec -WorkloadNetworkConfig $config.WorkloadNetwork
    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [PSCustomObject]$WorkloadNetworkConfig
    )

    Write-LogMessage -Type DEBUG -Message "Entered New-SupervisorWorkloadSpec function..."

    try {
        Write-LogMessage -Type DEBUG -Message "Building workload network specification..."

        # Build DNS configuration.
        $dns = Initialize-VcenterNamespaceManagementNetworksServiceDNS `
            -Servers $WorkloadNetworkConfig.DNSServers `
            -SearchDomains $WorkloadNetworkConfig.SearchDomains

        # Build NTP configuration.
        $ntp = Initialize-VcenterNamespaceManagementNetworksServiceNTP `
            -Servers $WorkloadNetworkConfig.NTPServers

        # Build network services.
        $services = Initialize-VcenterNamespaceManagementNetworksServices `
            -Dns $dns `
            -Ntp $ntp

        # Build node IP range.
        $nodeIpRange = Initialize-VcenterNamespaceManagementNetworksIPRange `
            -Address $WorkloadNetworkConfig.StartingIP `
            -Count $WorkloadNetworkConfig.IPCount

        # Build service IP range.
        $serviceIpRange = Initialize-VcenterNamespaceManagementNetworksIPRange `
            -Address $WorkloadNetworkConfig.ServiceStartIP `
            -Count $WorkloadNetworkConfig.ServiceCount

        # Build IP assignment for services.
        $serviceIpAssignment = Initialize-VcenterNamespaceManagementNetworksIPAssignment `
            -Assignee "SERVICE" `
            -Ranges $serviceIpRange

        # Build IP assignment for nodes.
        $nodeIpAssignment = Initialize-VcenterNamespaceManagementNetworksIPAssignment `
            -Assignee "NODE" `
            -Ranges $nodeIpRange

        # Build IP management configuration.
        $ipManagement = Initialize-VcenterNamespaceManagementNetworksIPManagement `
            -DhcpEnabled $WorkloadNetworkConfig.DHCPEnabled `
            -GatewayAddress $WorkloadNetworkConfig.Gateway `
            -IpAssignments $serviceIpAssignment, $nodeIpAssignment

        # Build vSphere network configuration.
        $vsphereNetwork = Initialize-VcenterNamespaceManagementSupervisorsNetworksWorkloadVSphereNetwork `
            -Dvpg $WorkloadNetworkConfig.PortGroupID

        # Build workload network configuration.
        $workloadNetwork = Initialize-VcenterNamespaceManagementSupervisorsNetworksWorkloadNetwork `
            -Network $WorkloadNetworkConfig.Name `
            -NetworkType "VSPHERE" `
            -Vsphere $vsphereNetwork `
            -Services $services `
            -IpManagement $ipManagement

        Write-LogMessage -Type INFO -Message "Workload network specification built successfully: $($WorkloadNetworkConfig.Name)"
        return $workloadNetwork
    }
    catch {
        Write-LogMessage -Type ERROR -Message "Failed to build workload network specification: $_"
        throw "Deployment failed. Check logs for details."
    }
}

Function New-SupervisorLoadBalancerSpec {

    <#
        .SYNOPSIS
        Creates VCF PowerCLI 9 Foundation Load Balancer specification for supervisor deployment.

        .DESCRIPTION
        Builds the complete Foundation Load Balancer (FLB) specification using VCF PowerCLI 9 Initialize-* cmdlets.
        This function constructs the FLB configuration including deployment target, management and virtual server
        network interfaces, network services (DNS/NTP), and load balancer address ranges.

        Based on VCF PowerCLI 9 SDK patterns for supervisor edge configuration.

        .PARAMETER LoadBalancerConfig
        Foundation Load Balancer configuration object with FLB settings and network configurations.

        .PARAMETER StoragePolicyId
        Storage policy MoRef ID for FLB deployment.

        .PARAMETER SupervisorZone
        Supervisor zone identifier for FLB deployment target.

        .PARAMETER FlbMgmtNetworkPersona
        Management network persona (default: "Management").

        .PARAMETER FlbWorkloadNetworkPersona
        Workload network personas (default: @("FRONTEND","WORKLOAD")).

        .OUTPUTS
        VCF PowerCLI 9 edge specification object ready for supervisor enablement.

        .EXAMPLE
        $flbSpec = New-SupervisorLoadBalancerSpec -LoadBalancerConfig $config.LoadBalancer -StoragePolicyId $policyId -SupervisorZone "zone-1"
    #>

    Param (
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$FlbMgmtNetworkPersona = "Management",
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [Array]$FlbWorkloadNetworkPersona = @("FRONTEND","WORKLOAD"),
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [PSCustomObject]$LoadBalancerConfig,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$StoragePolicyId,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$SupervisorZone
    )

    Write-LogMessage -Type DEBUG -Message "Entered New-SupervisorLoadBalancerSpec function..."

    try {
        Write-LogMessage -Type DEBUG -Message "Building Foundation Load Balancer specification..."

        # Build deployment target.
        $deploymentTarget = Initialize-VcenterNamespaceManagementNetworksEdgesFoundationDeploymentTarget `
            -StoragePolicy $StoragePolicyId `
            -Zones $SupervisorZone `
            -DeploymentSize $LoadBalancerConfig.Size `
            -Availability $LoadBalancerConfig.Availability

        # Build management network interface.
        $mgmtIpRange = Initialize-VcenterNamespaceManagementNetworksEdgesFoundationFoundationIPRange `
            -Address $LoadBalancerConfig.ManagementNetwork.StartingIP `
            -Count $LoadBalancerConfig.ManagementNetwork.IPCount

        $mgmtIpConfig = Initialize-VcenterNamespaceManagementNetworksEdgesFoundationIPConfig `
            -IpRanges $mgmtIpRange `
            -Gateway $LoadBalancerConfig.ManagementNetwork.Gateway

        $mgmtDvpgNetwork = Initialize-VcenterNamespaceManagementNetworksEdgesFoundationDistributedPortGroupNetwork `
            -Name $LoadBalancerConfig.ManagementNetwork.Name `
            -Network $LoadBalancerConfig.ManagementNetwork.PortGroupID `
            -Ipam $LoadBalancerConfig.ManagementNetwork.IPAssignmentMode `
            -IpConfig $mgmtIpConfig

        $mgmtNetwork = Initialize-VcenterNamespaceManagementNetworksEdgesFoundationNetwork `
            -NetworkType $LoadBalancerConfig.ManagementNetwork.Type `
            -DvpgNetwork $mgmtDvpgNetwork

        $mgmtNetworkInterface = Initialize-VcenterNamespaceManagementNetworksEdgesFoundationNetworkInterface `
            -Personas $FlbMgmtNetworkPersona `
            -Network $mgmtNetwork

        # Build virtual server network interface.
        $vsIpRange = Initialize-VcenterNamespaceManagementNetworksEdgesFoundationFoundationIPRange `
            -Address $LoadBalancerConfig.VirtualServerNetwork.StartingIP `
            -Count $LoadBalancerConfig.VirtualServerNetwork.IPCount

        $vsIpConfig = Initialize-VcenterNamespaceManagementNetworksEdgesFoundationIPConfig `
            -IpRanges $vsIpRange `
            -Gateway $LoadBalancerConfig.VirtualServerNetwork.Gateway

        $vsDvpgNetwork = Initialize-VcenterNamespaceManagementNetworksEdgesFoundationDistributedPortGroupNetwork `
            -Name $LoadBalancerConfig.VirtualServerNetwork.Name `
            -Network $LoadBalancerConfig.VirtualServerNetwork.PortGroupID `
            -Ipam $LoadBalancerConfig.VirtualServerNetwork.IPAssignmentMode `
            -IpConfig $vsIpConfig

        $vsNetwork = Initialize-VcenterNamespaceManagementNetworksEdgesFoundationNetwork `
            -NetworkType $LoadBalancerConfig.VirtualServerNetwork.Type `
            -DvpgNetwork $vsDvpgNetwork

        $vsNetworkInterface = Initialize-VcenterNamespaceManagementNetworksEdgesFoundationNetworkInterface `
            -Personas $FlbWorkloadNetworkPersona `
            -Network $vsNetwork

        # Build network services (DNS/NTP).
        $flbDns = Initialize-VcenterNamespaceManagementNetworksEdgesFoundationDNS `
            -Servers $LoadBalancerConfig.DNSServers `
            -SearchDomains $LoadBalancerConfig.SearchDomains

        $flbNtp = Initialize-VcenterNamespaceManagementNetworksEdgesFoundationNTP `
            -Servers $LoadBalancerConfig.NTPServers

        $networkServices = Initialize-VcenterNamespaceManagementNetworksEdgesFoundationNetworkServices `
            -Dns $flbDns `
            -Ntp $flbNtp

        # Build foundation configuration.
        $foundationConfig = Initialize-VcenterNamespaceManagementNetworksEdgesVsphereFoundationConfig `
            -DeploymentTarget $deploymentTarget `
            -Interfaces $mgmtNetworkInterface, $vsNetworkInterface `
            -NetworkServices $networkServices

        # Build VIP address range.
        $vipRange = Initialize-VcenterNamespaceManagementNetworksIPRange `
            -Address $LoadBalancerConfig.VipStartIP `
            -Count $LoadBalancerConfig.VipIPCount

        # Build edge specification.
        $edge = Initialize-VcenterNamespaceManagementNetworksEdgesEdge `
            -Id $LoadBalancerConfig.Name `
            -LoadBalancerAddressRanges $vipRange `
            -Foundation $foundationConfig `
            -Provider $LoadBalancerConfig.Provider

        Write-LogMessage -Type DEBUG -Message "Foundation Load Balancer specification built successfully: $($LoadBalancerConfig.Name)"
        return $edge
    }
    catch {
        Write-LogMessage -Type ERROR -Message "Failed to build Foundation Load Balancer specification: $_"
        throw "Deployment failed. Check logs for details."
    }
}

Function Invoke-SupervisorCreation {

    <#
        .SYNOPSIS
        Invokes the VCF PowerCLI 9 API to create a supervisor on a compute cluster.

        .DESCRIPTION
        Wraps the Invoke-EnableOnComputeClusterClusterSupervisors cmdlet with proper error handling,
        JSON serialization, temporary file management, and idempotent behavior for existing supervisors.

        This function handles the complete API invocation workflow:
        • Serializes supervisor specification to JSON with proper depth and count conversion
        • Creates and manages temporary JSON files for API communication
        • Invokes the VCF PowerCLI 9 supervisor enablement cmdlet
        • Handles "already exists" scenarios by retrieving existing supervisor ID
        • Ensures proper cleanup of temporary files in all code paths
        • Provides structured result object with success status and supervisor ID

        Based on VCF PowerCLI 9 API patterns for supervisor enablement.

        .PARAMETER ClusterId
        vSphere cluster MoRef ID where supervisor will be enabled (e.g., "domain-c8").

        .PARAMETER ClusterName
        Human-readable cluster name for logging and error messages.

        .PARAMETER SupervisorName
        Name for the supervisor cluster. Used for both creation and existing supervisor lookup.

        .PARAMETER SupervisorSpec
        Complete supervisor specification object from Initialize-VcenterNamespaceManagementSupervisorsEnableOnComputeClusterSpec.
        This object must include control plane, workloads, and zone configuration.

        .PARAMETER VcenterUser
        vCenter username for REST API authentication when retrieving existing supervisor IDs.

        .PARAMETER VcenterInsecurePassword
        vCenter password (plain text) for REST API authentication when retrieving existing supervisor IDs.
        This parameter name explicitly indicates the password is transmitted insecurely as plain text.

        .PARAMETER InsecureTls
        Switch to bypass SSL certificate validation for vCenter REST API connections.

        .OUTPUTS
        PSCustomObject with the following properties:
        • Success (Boolean): Indicates if operation succeeded
        • SupervisorId (String): Supervisor MoRef ID if successful, $null if failed
        • IsExisting (Boolean): $true if supervisor already existed, $false if newly created
        • ErrorMessage (String): Error details if Success is $false, $null if successful

        .EXAMPLE
        $result = Invoke-SupervisorCreation -ClusterId "domain-c8" -ClusterName "Cluster01" -SupervisorName "supervisor-01" -SupervisorSpec $spec -VcenterUser $user -VcenterInsecurePassword $pass
        if ($result.Success) {
            Write-Host "Supervisor ID: $($result.SupervisorId)"
        }

        .EXAMPLE
        $result = Invoke-SupervisorCreation -ClusterId $ClusterId -ClusterName $ClusterName -SupervisorName $SupervisorName -SupervisorSpec $spec -VcenterUser $vcUser -VcenterInsecurePassword $vcPass -InsecureTls
        if ($result.IsExisting) {
            Write-Host "Using existing supervisor: $($result.SupervisorId)"
        }

        .NOTES
        VCF PowerCLI 9 Requirements:
        • Uses Invoke-EnableOnComputeClusterClusterSupervisors cmdlet
        • Requires JSON serialization with depth 10 for complex nested objects
        • Count properties must be converted to integers (PowerShell quirk)
        • Temporary JSON files are created in system temp directory with unique names

        Error Handling:
        • "already has Workloads enabled" error triggers existing supervisor lookup
        • Temporary files are cleaned up in finally block
        • Returns structured object instead of throwing exceptions
        • Follows script-wide pattern of using exit/return instead of throw
    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterId,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $false)] [Switch]$InsecureTls,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$SupervisorName,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSCustomObject]$SupervisorSpec,
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$VcenterInsecurePassword,
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$VcenterUser
    )

    Write-LogMessage -Type DEBUG -Message "Entered Invoke-SupervisorCreation function..."
    # Initialize temporary file path variable for cleanup in finally block.
    $tempJsonPath = $null

    try {
        Write-LogMessage -Type INFO -Message "Invoking supervisor creation on cluster `"$ClusterName`" (ID: $ClusterId)..."

        # Create temporary JSON file with timestamp to avoid collisions.
        $timestamp = Get-Date -Format 'yyyyMMddHHmmss'
        $tempJsonPath = [System.IO.Path]::GetTempPath() + "supervisor_spec_${timestamp}.json"

        Write-LogMessage -Type DEBUG -Message "Serializing supervisor specification to JSON..."

        # Step 1: Serialize supervisor spec to JSON using VCF PowerCLI 9 ToJson() method.
        $SupervisorSpec.ToJson() | Set-Content $tempJsonPath

        # Step 2: Read back and convert to PSCustomObject for manipulation.
        $jsonFilePath = Get-Content $tempJsonPath -Raw
        $obj = $jsonFilePath | ConvertFrom-Json

        # Step 3: Convert count properties to integers (VCF PowerCLI 9 requirement).
        # PowerShell may serialize numeric properties as strings, but VCF API requires integers.
        Convert-CountToInt $obj

        # Step 4: Serialize back to JSON with proper depth for complex nested objects.
        $jsonFilePathPayload = $obj | ConvertTo-Json -Depth 10

        # Invoke the VCF PowerCLI 9 cmdlet to enable supervisor on cluster.
        $supervisorId = Invoke-EnableOnComputeClusterClusterSupervisors `
            -Cluster $ClusterId `
            -vcenterNamespaceManagementSupervisorsEnableOnComputeClusterSpec $jsonFilePathPayload `
            -Confirm:$false `
            -ErrorAction Stop

        Write-LogMessage -Type INFO -Message "Successfully initiated supervisor creation. Supervisor ID: $supervisorId"

        # Return success result with newly created supervisor ID.
        return [PSCustomObject]@{
            Success = $true
            SupervisorId = $supervisorId
            IsExisting = $false
            ErrorMessage = $null
        }
    }
    catch {
        $errorMessage = $_.Exception.Message

        # Handle "already has Workloads enabled" scenario (idempotent operation).
        if ($errorMessage -match "already has Workloads enabled") {
            Write-LogMessage -Type INFO -Message "Cluster `"$ClusterName`" already has supervisor enabled. Retrieving existing supervisor ID..."

            # Build parameters for Get-SupervisorId.
            $getSupervisorParams = @{
                supervisorName = $SupervisorName
                VcenterUser = $VcenterUser
                VcenterInsecurePassword = $VcenterInsecurePassword
                silence = $true
            }

            # Add InsecureTls if specified.
            if ($InsecureTls) {
                $getSupervisorParams.insecureTls = $true
            }

            # Attempt to retrieve existing supervisor ID.
            $existingSupervisorId = Get-SupervisorId @getSupervisorParams

            if ($existingSupervisorId) {
                Write-LogMessage -Type INFO -Message "Found existing supervisor with ID: $existingSupervisorId"

                # Return success result with existing supervisor ID.
                return [PSCustomObject]@{
                    Success = $true
                    SupervisorId = $existingSupervisorId
                    IsExisting = $true
                    ErrorMessage = $null
                }
            }
            else {
                Write-LogMessage -Type ERROR -Message "Failed to retrieve existing supervisor ID for `"$SupervisorName`""

                # Return failure result.
                return [PSCustomObject]@{
                    Success = $false
                    SupervisorId = $null
                    IsExisting = $false
                    ErrorMessage = "Failed to retrieve existing supervisor ID for `"$SupervisorName`""
                }
            }
        }
        else {
            # Unexpected error occurred - provide helpful context based on error type.

            # Extract clean error message from JSON error response.
            $cleanErrorMessage = Get-CleanErrorMessage -ErrorMessage $errorMessage

            # Check for zone association failure.
            switch -Regex ($errorMessage) {
                "Failed to associate zone|zone.*cluster" {
                    Write-LogMessage -Type ERROR -Message "Failed to create supervisor on cluster `"$ClusterName`": Unable to associate Supervisor Zone with cluster."
                    Write-LogMessage -Type ERROR -Message "Error details: $cleanErrorMessage"
                    Write-LogMessage -Type ERROR -Message "This typically indicates:"
                    Write-LogMessage -Type ERROR -Message "  1. The specified zone does not exist or is misconfigured in vCenter."
                    Write-LogMessage -Type ERROR -Message "  2. The cluster is already associated with a different zone."
                    Write-LogMessage -Type ERROR -Message "  3. A previous supervisor enablement failed and left the system in an inconsistent state."
                    Write-LogMessage -Type ERROR -Message "Remediation: Remove stale zone to cluster mapping from vCenter and try again."
                }
                "500.*Internal server error" {
                    Write-LogMessage -Type ERROR -Message "Failed to create supervisor on cluster `"$ClusterName`": vCenter API internal server error."
                    Write-LogMessage -Type ERROR -Message "Error details: $cleanErrorMessage"
                }
                default {
                    # Generic unexpected error - show clean message.
                    Write-LogMessage -Type ERROR -Message "Failed to create supervisor on cluster `"$ClusterName`": $cleanErrorMessage"
                }
            }

            # Return failure result with original error details for programmatic use.
            return [PSCustomObject]@{
                Success = $false
                SupervisorId = $null
                IsExisting = $false
                ErrorMessage = $errorMessage
            }
        }
    }
    finally {
        # Cleanup temporary JSON file in all code paths (success, failure, existing).
        if ($tempJsonPath -and (Test-Path $tempJsonPath)) {
            Write-LogMessage -Type DEBUG -Message "Cleaning up temporary JSON file: $tempJsonPath"
            Remove-Item -Path $tempJsonPath -Force -ErrorAction SilentlyContinue
        }
    }
}
Function Add-Supervisor {

    <#
        .SYNOPSIS
        Creates a new vSphere Supervisor cluster with comprehensive configuration and monitoring, or retrieves an existing supervisor ID.

        .DESCRIPTION
        The Add-Supervisor function deploys a new vSphere Supervisor cluster on a specified vSphere cluster
        using the provided JSON configuration. This function handles the complete supervisor deployment process
        including configuration validation, supervisor creation, status monitoring with progress tracking, and
        intelligent handling of pre-existing supervisors.

        The function performs the following operations:
        1. Loads and validates the supervisor configuration from the provided JSON file
        2. Extracts supervisor specifications including zone, control plane settings, and network configurations
        3. Parses network settings for management, workload, and Foundation Load Balancer (FLB) components
        4. Configures control plane VMs with specified size, count, and storage policy
        5. Sets up network management with DHCP or static IP allocation based on configuration
        6. Deploys Foundation Load Balancer with management and virtual server networks
        7. Attempts to create the supervisor cluster using the vSphere Namespace Management API
        8. If supervisor already exists on the cluster, retrieves the existing supervisor ID instead
        9. Monitors the supervisor deployment progress with a comprehensive progress indicator
        10. Waits for both ConfigStatus (RUNNING) and KubernetesStatus (READY) before completion
        11. Provides detailed logging throughout the deployment process

        The function includes intelligent error handling:
        - If a supervisor already exists on the cluster, it retrieves and returns the existing supervisor ID
        - Uses Get-SupervisorId to query for existing supervisors with optional TLS certificate validation bypass
        - Exits with code 1 if supervisor creation fails for reasons other than pre-existence
        - Provides timeout protection with configurable wait time and check intervals

        Progress tracking includes elapsed time, current status information, and Kubernetes readiness state.
        The monitoring phase uses configurable timeout and check interval parameters to provide flexible
        control over the waiting period.

        .PARAMETER InfrastructureJson
        Specifies the full path to the JSON configuration file containing supervisor deployment details.
        This file must contain all required supervisor specifications including vSphere zone, control plane
        configuration, network settings, and TKGS component specifications. The JSON structure must match
        the expected supervisor configuration schema.

        .PARAMETER StoragePolicyId
        Specifies the unique identifier of the vSphere storage policy to be used for the supervisor cluster.
        This storage policy will be applied to supervisor control plane VMs and determines the storage
        characteristics and placement rules for supervisor components.

        .PARAMETER ClusterId
        Specifies the unique identifier of the vSphere cluster where the supervisor will be deployed.
        This cluster must be properly configured with distributed switches, storage policies, and
        appropriate resource allocations before supervisor deployment.

        .PARAMETER ClusterName
        Specifies the name of the vSphere cluster for logging and identification purposes.
        This parameter is used primarily for enhanced logging messages and progress tracking
        to provide clear context about which cluster is being configured.

        .PARAMETER TotalWaitTime
        Specifies the maximum time in seconds to wait for the supervisor to become ready.
        The function will monitor supervisor status and wait for both ConfigStatus (RUNNING)
        and KubernetesStatus (READY) before completion. Default value is 3600 seconds (1 hour).
        If the supervisor doesn't become ready within this time, the function will exit with error code 1.

        .PARAMETER CheckInterval
        Specifies the interval in seconds between status checks while waiting for the supervisor
        to become ready. The function will check supervisor status every CheckInterval seconds
        during the monitoring phase. Default value is 15 seconds. Shorter intervals provide
        more frequent updates but may increase API load, while longer intervals reduce API calls
        but provide less frequent progress updates.

        .PARAMETER InsecureTls
        Optional switch parameter that bypasses SSL certificate validation for vCenter REST API connections.
        When specified, the function will pass this flag to Get-SupervisorId when checking for existing
        supervisors, which disables SSL certificate validation for all REST API calls to vCenter.

        This parameter is useful in development and lab environments where:
        - Self-signed certificates are in use
        - Certificate chains are not properly configured
        - Certificate names don't match the vCenter FQDN

        Security Warning: This parameter introduces a security risk by disabling certificate validation,
        making the connection vulnerable to man-in-the-middle attacks. Should NOT be used in production
        environments. When this flag is not specified, SSL certificate validation is enforced (secure by default).

        .PARAMETER VCenterPasswordDecrypted
        Optional parameter specifying the plain text vCenter password for authentication when
        retrieving existing supervisor IDs. This parameter is required when the function needs
        to handle cases where a supervisor already exists on the cluster and must return its ID.

        When a supervisor already exists:
        - The function catches the "already has Workloads enabled" error from the API
        - Calls Get-SupervisorId with this password to retrieve the existing supervisor's ID
        - Returns the existing supervisor ID instead of failing

        If not provided and a supervisor already exists, the function will not be able to retrieve
        the existing supervisor ID and will exit with an error. This password is used for REST API
        authentication to vCenter's namespace management endpoints.

        Security Warning: This parameter accepts passwords in plain text (not SecureString), which
        poses a security risk. The password may be visible in logs, memory dumps, or process listings.

        .EXAMPLE
        Add-Supervisor -infrastructureJson "C:\config\supervisor.json" -storagePolicyId "aa6d5a82-1c88-45da-85d3-3d74b91a5bad" -clusterId "domain-c8" -clusterName "cl02"

        Creates a new supervisor on cluster "cl02" using the configuration from supervisor.json
        with the specified storage policy and cluster identifiers. Uses default timeout of 3600 seconds
        and check interval of 15 seconds. SSL certificate validation is enforced (secure default).

        .EXAMPLE
        $supervisorId = Add-Supervisor -infrastructureJson $SupervisorJson -storagePolicyId $policyId -clusterId $ClusterId -clusterName $ClusterName -vCenterPasswordDecrypted $vcPassword

        Creates a supervisor and captures the returned supervisor ID for use in subsequent operations
        such as namespace creation or ArgoCD deployment. Includes vCenter password to handle cases where
        a supervisor already exists on the cluster. If supervisor exists, retrieves and returns its ID.

        .EXAMPLE
        Add-Supervisor -infrastructureJson "C:\config\supervisor.json" -storagePolicyId "aa6d5a82-1c88-45da-85d3-3d74b91a5bad" -clusterId "domain-c8" -clusterName "cl02" -totalWaitTime 7200 -checkInterval 30

        Creates a new supervisor with custom timeout of 7200 seconds (2 hours) and check interval of 30 seconds.
        This is useful for larger deployments that may take longer to become ready or when you want less
        frequent status updates to reduce API load.

        .EXAMPLE
        $supervisorId = Add-Supervisor -infrastructureJson $SupervisorJson -storagePolicyId $policyId -clusterId $ClusterId -clusterName $ClusterName -vCenterPasswordDecrypted $password -insecureTls

        Creates a supervisor in a lab environment with SSL certificate validation bypassed. The -insecureTls
        flag is passed to Get-SupervisorId when checking for existing supervisors. This is useful for
        development environments with self-signed certificates but should NOT be used in production.

        .EXAMPLE
        try {
            $supervisorId = Add-Supervisor -infrastructureJson $config -storagePolicyId $policy -clusterId $cluster -clusterName $name -vCenterPasswordDecrypted $pass
        } catch {
            Write-Host "Failed to create supervisor: $_"
        }

        Demonstrates proper error handling when creating a supervisor. The function returns the supervisor ID
        whether it creates a new one or retrieves an existing one, making it safe to call repeatedly.

        .OUTPUTS
        System.String
        Returns the unique identifier (ID) of the successfully created or retrieved supervisor cluster.
        The ID format is typically "domain-cNNN" where NNN is a numeric identifier (e.g., "domain-c8").
        This ID can be used for subsequent operations such as creating namespaces, deploying services,
        or configuring ArgoCD instances.

        .NOTES
        Prerequisites:
        - Requires vSphere 7.0 U1 or later with vSphere with Tanzu enabled
        - The target cluster must have distributed switches properly configured
        - Storage policies must be created and associated with appropriate datastores
        - Network port groups must exist for management, workload, and FLB networks
        - Sufficient cluster resources (CPU, memory, storage) for supervisor control plane VMs
        - PowerCLI module VMware.VimAutomation.Core must be loaded

        Behavior:
        - Function uses script-scoped variables for vCenter connection details ($Script:VCenterName, $Script:VCenterUser)
        - Progress monitoring uses a do-while loop with configurable timeout (default 3600 seconds/1 hour)
        - Status checks occur at configurable intervals (default 15 seconds) during the monitoring phase
        - Idempotent: If supervisor already exists, retrieves and returns existing supervisor ID
        - Function will exit with code 1 if supervisor creation fails (except for pre-existence)
        - All operations are logged using Write-LogMessage for consistent logging format
        - Temporary JSON files are created in the system temp directory and cleaned up automatically

        Performance Considerations:
        - Timeout and check interval parameters allow customization of monitoring behavior
        - Shorter check intervals provide more frequent updates but may increase API load
        - Longer timeouts are useful for large deployments that may take longer to become ready
        - Initial supervisor creation typically takes 15-30 minutes depending on environment
        - Existing supervisor ID retrieval typically completes in under 10 seconds

        Security Considerations:
        - The -insecureTls parameter bypasses SSL certificate validation (use only in lab environments)
        - The -vCenterPasswordDecrypted parameter accepts plain text passwords (security risk)
        - Passwords may be visible in memory dumps or process listings
        - Consider using secure credential management for production deployments
        - SSL certificate validation is enforced by default (secure by default behavior)

        .LINK
        Get-SupervisorId
        Get-OrCreateSupervisor
        Invoke-EnableOnComputeClusterClusterSupervisors
        Invoke-GetSupervisorNamespaceManagementSummary
        Add-ArgoCDNamespace
    #>

    Param (
        [Parameter(Mandatory = $false)] [ValidateRange(1, [int]::MaxValue)] [Int]$CheckInterval=15,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterId,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$FlbMgmtNetworkPersona="Management",
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [Array]$FlbWorkloadNetworkPersona=@("FRONTEND","WORKLOAD"),
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$InfrastructureJson,
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [Switch]$InsecureTls,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$StoragePolicyId,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$SupervisorName,
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$SupervisorZone="zone-1",
        [Parameter(Mandatory = $false)] [ValidateRange(1, [int]::MaxValue)] [Int]$TotalWaitTime=3600,
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$VCenterPasswordDecrypted
    )

    Write-LogMessage -Type DEBUG -Message "Entered Add-Supervisor function..."

    Write-LogMessage -Type INFO -Message "Beginning Supervisor deployment to cluster `"$ClusterName`"..."

    try {
        # ========================================================================
        # STEP 1: Parse Configuration from JSON.

        # ========================================================================
        Write-Progress -Activity "Supervisor Deployment" -Status "Parsing configuration from JSON..." -PercentComplete 10
        Write-LogMessage -Type INFO -Message "[Step 1/5] Parsing supervisor configuration from JSON..."
        $config = Get-SupervisorConfigurationFromJson -JsonFilePath $InfrastructureJson

        # Validate configuration before proceeding.
        if (-not (Test-SupervisorConfiguration -Config $config)) {
            Write-LogMessage -Type ERROR -Message "Supervisor configuration validation failed"
            throw "Deployment failed. Check logs for details."
        }

        # ========================================================================
        # STEP 2: Build VCF PowerCLI 9 Specifications.

        # ========================================================================
        Write-Progress -Activity "Supervisor Deployment" -Status "Building Supervisor specifications..." -PercentComplete 30
        Write-LogMessage -Type INFO -Message "[Step 2/5] Building Supervisor specifications..."

        # Build control plane specification using parameter splatting.
        $controlPlaneParams = @{
            ControlPlaneConfig = $config.ControlPlane
            ManagementNetworkConfig = $config.ManagementNetwork
            StoragePolicyId = $StoragePolicyId
        }
        $controlPlaneSpec = New-SupervisorControlPlaneSpec @controlPlaneParams

        # Build workload network specification using parameter splatting.
        $workloadNetworkParams = @{
            WorkloadNetworkConfig = $config.WorkloadNetwork
        }
        $workloadNetworkSpec = New-SupervisorWorkloadSpec @workloadNetworkParams

        # Build Foundation Load Balancer specification using parameter splatting.
        $loadBalancerParams = @{
            LoadBalancerConfig = $config.LoadBalancer
            StoragePolicyId = $StoragePolicyId
            SupervisorZone = $SupervisorZone
            FlbMgmtNetworkPersona = $FlbMgmtNetworkPersona
            FlbWorkloadNetworkPersona = $FlbWorkloadNetworkPersona
        }
        $edgeSpec = New-SupervisorLoadBalancerSpec @loadBalancerParams

        # ========================================================================
        # STEP 3: Assemble Complete Supervisor Specification.

        # ========================================================================
        Write-Progress -Activity "Supervisor Deployment" -Status "Assembling complete supervisor specification..." -PercentComplete 50
        Write-LogMessage -Type INFO -Message "[Step 3/5] Assembling complete supervisor specification..."

        # Build Kube API Server options (empty for now).
        $kubeApiServerOptions = Initialize-VcenterNamespaceManagementSupervisorsKubeAPIServerOptions

        # Build workloads specification.
        $workloadsSpec = Initialize-VcenterNamespaceManagementSupervisorsWorkloads `
            -Network $workloadNetworkSpec `
            -Edge $edgeSpec `
            -KubeApiServerOptions $kubeApiServerOptions

        # Build complete supervisor enablement specification.
        $supervisorSpec = Initialize-VcenterNamespaceManagementSupervisorsEnableOnComputeClusterSpec `
            -Name $SupervisorName `
            -Zone $SupervisorZone `
            -ControlPlane $controlPlaneSpec `
            -Workloads $workloadsSpec

        # ========================================================================
        # STEP 4: Invoke Supervisor Creation.

        # ========================================================================
        Write-Progress -Activity "Supervisor Deployment" -Status "Invoking supervisor creation API..." -PercentComplete 70
        Write-LogMessage -Type INFO -Message "[Step 4/5] Invoking supervisor creation API..."

        # Invoke supervisor creation using parameter splatting.
        $creationParams = @{
            ClusterId = $ClusterId
            ClusterName = $ClusterName
            SupervisorName = $SupervisorName
            SupervisorSpec = $supervisorSpec
            VcenterUser = $Script:VCenterUser
            VcenterInsecurePassword = $VCenterPasswordDecrypted
            InsecureTls = $InsecureTls
        }
        $creationResult = Invoke-SupervisorCreation @creationParams

        # Check if creation was successful.
        if (-not $creationResult.Success) {
            # Extract clean error message from the API response.

            $errorMsg = $creationResult.ErrorMessage

            # Extract clean error message from JSON error response.
            $cleanError = Get-CleanErrorMessage -ErrorMessage $errorMsg
            Write-LogMessage -Type ERROR -Message "Supervisor creation failed: $cleanError"
            throw "Deployment failed. Check logs for details."
        }

        $supervisorId = $creationResult.SupervisorId
        Write-LogMessage -Type INFO -Message "[Step 4/5] Supervisor API invocation completed. ID: $supervisorId"

        # If supervisor already existed, skip waiting and return immediately.
        if ($creationResult.IsExisting) {
            Write-LogMessage -Type INFO -Message "[Step 5/5] Supervisor already exists, skipping status monitoring"
            Write-LogMessage -Type INFO -Message "Using existing supervisor ID: $supervisorId"
            return $supervisorId
        }

        # ========================================================================
        # STEP 5: Monitor Supervisor Deployment Status.

        # ========================================================================
        Write-Progress -Activity "Supervisor Deployment" -Status "Monitoring supervisor deployment status..." -PercentComplete 85
        Write-LogMessage -Type INFO -Message "[Step 5/5] Monitoring supervisor deployment status..."

        # Monitor supervisor readiness using parameter splatting.
        $waitParams = @{
            supervisorId = $supervisorId
            clusterName = $ClusterName
            checkInterval = $CheckInterval
            totalWaitTime = $TotalWaitTime
        }
        $waitResult = Wait-SupervisorReady @waitParams

        if (-not $waitResult.Success) {
            Write-LogMessage -Type ERROR -Message "Supervisor did not become ready within $TotalWaitTime seconds"
            throw "Deployment failed. Check logs for details."
        }

        Write-LogMessage -Type INFO -Message "[Step 5/5] Supervisor is ready (elapsed: $($waitResult.ElapsedSeconds) seconds)"
        Write-LogMessage -Type INFO -Message "Supervisor deployment completed successfully. Supervisor ID: $supervisorId"

        Write-Progress -Activity "Supervisor Deployment" -Status "Completed" -PercentComplete 100 -Completed

        return $supervisorId
    }
    catch {
        Write-LogMessage -Type ERROR -Message "Failed to create a Supervisor on cluster `"$ClusterName`" attached to vCenter `"$Script:VCenterName`": $_"
        throw "Deployment failed. Check logs for details."
    }
}

Function Invoke-VDSCreation {

    <#
        .SYNOPSIS
        Creates a Virtual Distributed Switch or retrieves an existing one.

        .DESCRIPTION
        This helper function creates a new Virtual Distributed Switch with the specified
        configuration or retrieves an existing VDS if it already exists. The function
        handles idempotent VDS creation for safe re-execution.

        .PARAMETER VdsName
        The name of the Virtual Distributed Switch to create or retrieve.

        .PARAMETER DatacenterObject
        The datacenter object where the VDS will be created.

        .PARAMETER VdsVersion
        The version of the Virtual Distributed Switch (e.g., "7.0.0", "8.0.0").

        .PARAMETER NumUplinks
        The number of uplink ports to configure on the VDS.

        .OUTPUTS
        VDS object (VMware.VimAutomation.Vds.Types.V1.VmwareVDSwitch)

        .EXAMPLE
        $vds = Invoke-VDSCreation -VdsName "Production-VDS" -DatacenterObject $dc -VdsVersion "7.0.0" -NumUplinks "2"

        .NOTES
        Error Handling: Helper function. Returns VDS object on success. Returns structured error
        object via Write-ErrorAndReturn on failure. Caller should check result type and handle
        errors appropriately (typically by calling 'exit 1' in main workflow functions).
    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$VdsName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [PSObject]$DatacenterObject,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$VdsVersion,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$NumUplinks
    )

    Write-LogMessage -Type DEBUG -Message "Entered Invoke-VDSCreation function..."

    # Verify vCenter connection before proceeding.
    $connectionTest = Test-VcenterConnection
    if (-not $connectionTest.IsConnected) {
        Write-LogMessage -Type ERROR -Message "Not connected to vCenter `"$Script:VCenterName`": $($connectionTest.ErrorMessage)"
        throw "Deployment failed. Check logs for details."
    }

    try {
        # Check if VDS already exists.
        $vdsObject = Get-VDSwitch -Name $VdsName -Server $Script:VCenterName -ErrorAction SilentlyContinue

        if ($null -ne $vdsObject) {
            Write-LogMessage -Type WARNING -Message "VDS `"$VdsName`" is already present on vCenter `"$Script:VCenterName`"."
            return $vdsObject
        }

        # Create new VDS.
        New-VDSwitch -Name $VdsName -Location $DatacenterObject -Version $VdsVersion -NumUplinkPorts $NumUplinks -ErrorAction Stop | Out-Null

        # Retrieve newly created VDS.
        $vdsObject = Get-VDSwitch -Name $VdsName -Server $Script:VCenterName -ErrorAction SilentlyContinue

        if ($null -ne $vdsObject) {
            Write-LogMessage -Type INFO -Message "Successfully created VDS `"$VdsName`" on vCenter `"$Script:VCenterName`"."
            return $vdsObject
        } else {
            Write-LogMessage -Type ERROR -Message "Failed to retrieve VDS `"$VdsName`" after creation."
            throw "Deployment failed. Check logs for details."
        }
    } catch {
        Write-LogMessage -Type ERROR -Message "Failed to create VDS `"$VdsName`": $_"
        throw "Deployment failed. Check logs for details."
    }
}

Function Add-HostToVDS {

    <#
        .SYNOPSIS
        Adds an ESX host to a Virtual Distributed Switch.

        .DESCRIPTION
        This helper function adds an ESX host to the specified VDS. If the host is already
        attached to the VDS, the function logs a warning and continues gracefully.

        .PARAMETER Hostname
        The ESX host object to add to the VDS.

        .PARAMETER VdsName
        The name of the Virtual Distributed Switch.

        .EXAMPLE
        Add-HostToVDS -Hostname $EsxHost -VdsName "Production-VDS"

        .NOTES
        Error Handling: Helper function. Returns structured error object via Write-ErrorAndReturn
        on unexpected failures. Caller should check $result.Success and handle errors accordingly.
        Expected errors (host already attached) are handled gracefully with warnings.
    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [PSObject]$Hostname,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$VdsName
    )

    Write-LogMessage -Type DEBUG -Message "Entered Add-HostToVDS function..."

    try {
        Add-VDSwitchVMHost -VMHost $Hostname -VDSwitch $VdsName -Server $Script:VCenterName -ErrorAction Stop | Out-Null
    } catch {
        $errMsg = $_.Exception.Message

        if ($errMsg -match "is already added to VDSwitch") {
            Write-LogMessage -Type WARNING -Message "The ESX host `"$Hostname`" is already attached to VDS `"$VdsName`" on vCenter `"$Script:VCenterName`"."
        } else {
            return Write-ErrorAndReturn -ErrorMessage "Unexpected error adding ESX host `"$Hostname`" to VDS `"$VdsName`": $_" -ErrorCode "ERR_VDS_UNEXPECTED"
        }
    }
}

Function New-VDSPortGroups {

    <#
        .SYNOPSIS
        Creates distributed port groups on a Virtual Distributed Switch.

        .DESCRIPTION
        This helper function creates multiple distributed port groups with VLAN configuration.
        It checks for existing port groups and handles idempotent creation. The function
        detects duplicate port groups and validates port group existence before creation.

        .PARAMETER VdsName
        The name of the Virtual Distributed Switch where port groups will be created.

        .PARAMETER PortGroups
        An array of objects containing port group configuration (Name, VlanId properties).

        .EXAMPLE
        $portGroups = @(
            @{ Name = "Management"; VlanId = 100 },
            @{ Name = "vMotion"; VlanId = 200 }
        )
        New-VDSPortGroups -VdsName "Production-VDS" -PortGroups $portGroups

        .NOTES
        Error Handling: Helper function. Returns structured error object via Write-ErrorAndReturn
        on unexpected failures. Caller should check $result.Success and handle errors accordingly.
        Expected errors (port group already exists) are handled gracefully with warnings.
    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$VdsName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [System.Object[]]$portGroups
    )

    Write-LogMessage -Type DEBUG -Message "Entered New-VDSPortGroups function..."

    # Verify vCenter connection before proceeding.
    $connectionTest = Test-VcenterConnection
    if (-not $connectionTest.IsConnected) {
        Write-LogMessage -Type ERROR -Message "Not connected to vCenter `"$Script:VCenterName`": $($connectionTest.ErrorMessage)"
        throw "Deployment failed. Check logs for details."
    }

    foreach ($portGroup in $portGroups) {
        try {
            # Check if port group already exists before attempting to create it.
            $existingPortGroup = Get-VDPortgroup -Name $($portGroup.Name) -Server $Script:VCenterName -ErrorAction SilentlyContinue

            if ($existingPortGroup) {
                # Handle case where multiple port groups with same name exist.
                if ($existingPortGroup.GetType() -eq [System.Object[]]) {
                    Write-LogMessage -Type ERROR -Message "Two or more port groups named `"$($portGroup.Name)`" were found in vCenter `"$Script:VCenterName`". Please delete the duplicate port groups or update your configuration."
                    throw "Deployment failed. Check logs for details."
                }

                # Check if it's on the same VDS.
                if ($existingPortGroup.VDSwitch.Name -eq $VdsName) {
                    try {
                        $existingVlanId = $existingPortGroup.ExtensionData.Config.DefaultPortConfig.Vlan.VlanId
                    } catch {
                        $existingVlanId = "Unknown"
                    }
                    Write-LogMessage -Type WARNING -Message "Port group `"$($portGroup.Name)`" already exists on VDS `"$VdsName`" with VLAN ID $existingVlanId. Skipping creation."
                } else {
                    try {
                        $existingVlanId = $existingPortGroup.ExtensionData.Config.DefaultPortConfig.Vlan.VlanId
                    } catch {
                        $existingVlanId = "Unknown"
                    }
                    Write-LogMessage -Type WARNING -Message "Port group `"$($portGroup.Name)`" already exists on VDS `"$($existingPortGroup.VDSwitch.Name)`" with VLAN ID $existingVlanId but not on target VDS `"$VdsName`". Skipping creation to avoid conflicts."
                }
            } else {
                # Port group doesn't exist, create it.
                Write-LogMessage -Type INFO -Message "Creating port group `"$($portGroup.Name)`" on VDS `"$VdsName`" with VLAN ID $($portGroup.VlanId)..."
                New-VDPortgroup -Server $Script:VCenterName -Name $($portGroup.Name) -VDSwitch $VdsName -VlanId $($portGroup.VlanId) -NumPorts 128 -PortBinding Static -ErrorAction Stop | Out-Null
                Write-LogMessage -Type INFO -Message "  Successfully created port group `"$($portGroup.Name)`" on VDS `"$VdsName`"."
            }
        } catch {
            $errMsg = $_.Exception.Message

            if ($errMsg -match "Operation is not valid due to the current state of the object") {
                Write-LogMessage -Type WARNING -Message "The port group `"$($portGroup.Name)`" is already attached to distributed switch `"$VdsName`" on vCenter `"$Script:VCenterName`"."
            } elseif ($errMsg -match "already exists") {
                Write-LogMessage -Type WARNING -Message "The port group `"$($portGroup.Name)`" is already present on vCenter `"$Script:VCenterName`"."
            } else {
                return Write-ErrorAndReturn -ErrorMessage "Unexpected error creating port group $($portGroup.Name): $_" -ErrorCode "ERR_PORTGROUP_UNEXPECTED"
            }
        }
    }
}

Function Add-PhysicalAdaptersToVDS {

    <#
        .SYNOPSIS
        Assigns physical network adapters to Virtual Distributed Switch uplinks.

        .DESCRIPTION
        This helper function assigns physical network adapters (vmnics) to VDS uplinks.
        It checks for existing adapter assignments and handles idempotent configuration.
        The function retrieves currently assigned adapters from the VDS to prevent duplicate assignments.

        .PARAMETER VdsObject
        The Virtual Distributed Switch object to which adapters will be added.

        .PARAMETER VdsName
        The name of the Virtual Distributed Switch (used for logging).

        .PARAMETER Hostname
        The ESX host object containing the physical network adapters.

        .PARAMETER NicList
        An array of objects containing physical network adapter names (Name property).

        .EXAMPLE
        $nicList = @(
            @{ Name = "vmnic0" },
            @{ Name = "vmnic1" }
        )
        Add-PhysicalAdaptersToVDS -VdsObject $vds -VdsName "Production-VDS" -Hostname $EsxHost -NicList $nicList

        .NOTES
        Error Handling: Helper function. Returns structured error object via Write-ErrorAndReturn
        on configuration failures. Caller should check $result.Success and handle errors accordingly.
        Expected errors (adapter already assigned) are handled gracefully with warnings.
    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [PSObject]$VdsObject,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$VdsName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [PSObject]$Hostname,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [System.Object[]]$nicList
    )

    Write-LogMessage -Type DEBUG -Message "Entered Add-PhysicalAdaptersToVDS function..."

    # Verify vCenter connection before proceeding.
    $connectionTest = Test-VcenterConnection
    if (-not $connectionTest.IsConnected) {
        Write-LogMessage -Type ERROR -Message "Not connected to vCenter `"$Script:VCenterName`": $($connectionTest.ErrorMessage)"
        throw "Deployment failed. Check logs for details."
    }

    try {
        # Get currently assigned physical adapters on the VDS for this host.
        $assignedAdapters = @()
        try {
            $vdsHostConfig = $VdsObject.ExtensionData.Config.Host | Where-Object { $_.Host.Value -eq $Hostname.ExtensionData.MoRef.Value }
            if ($vdsHostConfig -and $vdsHostConfig.Config.Backing.PnicSpec) {
                $assignedAdapters = $vdsHostConfig.Config.Backing.PnicSpec | ForEach-Object { $_.PnicDevice }
            }
        } catch {
            Write-LogMessage -Type WARNING -Message "Unable to retrieve assigned adapters for VDS `"$VdsName`". Will attempt to add all adapters."
        }

        # Add each physical adapter to the VDS.
        foreach ($vmnicName in $nicList) {
            $nicName = $vmnicName.Name

            if ($assignedAdapters -contains $nicName) {
                Write-LogMessage -Type WARNING -Message "Network adapter `"$nicName`" is already attached to VDS `"$VdsName`" on ESX host `"$Hostname`" on vCenter `"$Script:VCenterName`"."
            } else {
                # Migrate Virtual Nic to distributed port group.
                $vmhostNetworkAdapter = Get-VMHost -Name $Hostname -Server $Script:VCenterName | Get-VMHostNetworkAdapter -Physical -Name $nicName -Server $Script:VCenterName
                $VdsObject | Add-VDSwitchPhysicalNetworkAdapter -VMHostPhysicalNic $vmhostNetworkAdapter -Server $Script:VCenterName -Confirm:$false
            }
        }
    } catch {
        Write-LogMessage -Type ERROR -Message "Failed to configure network adapters for VDS `"$VdsName`": $_"
        return Write-ErrorAndReturn -ErrorMessage "Network adapter configuration failed" -ErrorCode "ERR_NIC_CONFIG"
    }
}
Function Set-VirtualDistributedSwitch {

       <#
        .SYNOPSIS
        Creates and configures a vSphere Virtual Distributed Switch (VDS) with port groups and physical network adapters.

        .DESCRIPTION
        The Set-VirtualDistributedSwitch function creates and configures a complete vSphere Virtual Distributed Switch
        infrastructure including the switch itself, distributed port groups, and physical network adapter assignments.
        This function provides comprehensive VDS deployment automation for vSphere environments, handling all aspects
        of distributed switching configuration in a single operation.

        The function performs the following key operations:
        • Creates a new Virtual Distributed Switch with specified version and uplink configuration
        • Adds ESX hosts from the target cluster to the VDS for distributed network management
        • Creates multiple distributed port groups with VLAN configuration and static port binding
        • Assigns physical network adapters (vmnic) to the VDS uplinks for network connectivity
        • Provides comprehensive error handling and proactive duplicate resource detection
        • Integrates with vSphere cluster infrastructure for automated network deployment

        This function is designed for use in automated vSphere infrastructure deployments where consistent
        network configuration across multiple hosts is required. It handles existing resource detection
        gracefully, making it safe to run multiple times against the same infrastructure. The function
        proactively validates port group names to prevent conflicts and detects duplicate port groups.

        Key features:
        - Automated VDS creation with version and uplink port specification
        - Cluster-wide host integration with distributed switching
        - Multiple port group creation with VLAN and binding configuration
        - Proactive port group conflict detection and validation
        - Physical adapter assignment with duplicate detection
        - Comprehensive error handling for authorization and timeout scenarios
        - Integration with vSphere datacenter and cluster objects

        .PARAMETER VdsName
        The name of the Virtual Distributed Switch to create. This name must be unique within the
        datacenter and should follow standard vSphere naming conventions. The VDS name is used
        for identification and management operations throughout the vSphere environment.

        .PARAMETER DatacenterName
        The name of the vSphere datacenter where the VDS will be created. The datacenter must
        already exist and be accessible through the current vCenter connection. This parameter
        determines the scope and location of the distributed switch within the vSphere inventory.

        .PARAMETER NumUplinks
        The number of uplink ports to configure on the Virtual Distributed Switch. This determines
        how many physical network adapters can be connected to the switch for external connectivity.
        Common values are 2, 4, or 8 depending on the physical network configuration and redundancy
        requirements. Must be specified as a string value.

        .PARAMETER VdsVersion
        The version of the Virtual Distributed Switch to create. This should match the vSphere
        version capabilities and feature requirements. Common versions include "6.0.0", "6.5.0",
        "6.6.0", "7.0.0", "8.0.0", and "9.0.0". Higher versions provide additional features but
        require compatible ESX host versions.

        .PARAMETER ClusterName
        The name of the vSphere cluster whose hosts will be added to the Virtual Distributed Switch.
        All hosts in the specified cluster will be configured to use the VDS for distributed
        network management. The cluster must exist and contain ESX hosts for the operation to succeed.

        .PARAMETER PortGroups
        An array of objects containing port group configuration information. Each object should contain
        at minimum 'Name' and 'VlanId' properties. The function creates distributed port groups with
        128 static ports and the specified VLAN configuration. Port groups provide network segmentation
        and traffic isolation for virtual machines and infrastructure services.

        .PARAMETER NicList
        An array of objects containing physical network adapter information. Each object should contain
        a 'Name' property specifying the vmnic device name (e.g., "vmnic0", "vmnic1"). These adapters
        will be assigned to the VDS uplinks to provide physical network connectivity for the distributed
        switch infrastructure.

        .EXAMPLE
        $portGroups = @(
            @{ Name = "Management"; VlanId = 100 },
            @{ Name = "vMotion"; VlanId = 200 },
            @{ Name = "Storage"; VlanId = 300 }
        )
        $nicList = @(
            @{ Name = "vmnic0" },
            @{ Name = "vmnic1" }
        )
        Set-VirtualDistributedSwitch -vdsName "Production-VDS" -datacenterName "Datacenter1" -numUplinks "2" -vdsVersion "7.0.0" -clusterName "Cluster1" -portGroups $portGroups -nicList $nicList

        Creates a production VDS with version 7.0.0, 2 uplinks, three port groups with different VLANs,
        and assigns two physical adapters to provide network connectivity. The function will check for
        existing port groups and skip creation if they already exist on the target VDS.

        .EXAMPLE
        Set-VirtualDistributedSwitch -vdsName "Lab-VDS" -datacenterName "Lab-DC" -numUplinks "4" -vdsVersion "8.0.0" -clusterName "Lab-Cluster" -portGroups $pgConfig -nicList $nicConfig

        Creates a lab environment VDS with 4 uplinks using vSphere 8.0 features, utilizing pre-configured
        port group and NIC arrays for flexible deployment scenarios. Existing port groups will be detected
        and skipped to prevent conflicts.

        .EXAMPLE
        $vdsParams = @{
            vdsName = $InputData.common.virtualDistributedSwitch.vdsName
            datacenterName = $InputData.common.datacenterName
            numUplinks = $InputData.common.virtualDistributedSwitch.numUplinks
            vdsVersion = $InputData.common.virtualDistributedSwitch.vdsVersion
            clusterName = $InputData.common.clusterName
            portGroups = $InputData.common.virtualDistributedSwitch.portGroups
            nicList = $InputData.common.virtualDistributedSwitch.nicList
        }
        Set-VirtualDistributedSwitch @vdsParams

        Deploys VDS infrastructure using configuration parameters from input data with parameter splatting,
        enabling dynamic deployment scenarios based on configuration files.

        .OUTPUTS
        None
        This function does not return objects but performs infrastructure configuration with side effects.
        Success is indicated by the absence of exceptions and the creation of VDS infrastructure components.
        All operations are logged for audit trail and troubleshooting purposes.

        .NOTES
        Prerequisites:
        • Active PowerCLI connection to vCenter with administrative privileges
        • Target datacenter and cluster must exist and be accessible
        • ESX hosts in the cluster must be in a connected state
        • Physical network adapters specified in nicList must exist on target hosts
        • Sufficient network uplink capacity for the specified configuration

        Behavior:
        • Detects and skips creation of existing VDS, port groups, and adapter assignments
        • Proactively checks for existing port groups before attempting creation to prevent conflicts
        • Validates port group name uniqueness and detects multiple port groups with same name
        • Creates distributed port groups with 128 static ports and specified VLAN configuration
        • Assigns physical adapters to VDS uplinks in the order specified in nicList
        • Provides warning messages for existing resources rather than errors
        • Terminates script execution (exit 1) if critical operations fail or duplicate port groups found

        Network Configuration:
        • Port groups are created with static port binding for predictable VM network assignment
        • VLAN configuration is applied based on the VlanId property in port group objects
        • Physical adapters are assigned to uplinks to provide external network connectivity
        • VDS version determines available features and compatibility with ESX host versions

        Error Handling:
        • Main workflow function: Uses 'exit 1' to terminate script on critical failures
        • Calls helper functions that return structured error objects via Write-ErrorAndReturn
        • Checks $result.Success from helper functions and exits on failure
        • Comprehensive exception handling for authorization, timeout, and general errors
        • Graceful handling of duplicate resource scenarios with warning messages
        • Proactive detection of multiple port groups with same name (terminates with error)
        • Detailed error logging for troubleshooting network configuration issues
        • Script termination on critical failures to prevent partial configurations
        • Helper functions (Invoke-VDSCreation, Add-HostToVDS, New-VDSPortGroups, Add-PhysicalAdaptersToVDS)
          return error objects; this function decides to exit on their failures

        Performance Considerations:
        • Operations are performed sequentially to ensure proper dependency handling
        • Large numbers of port groups or NICs may increase deployment time
        • Network adapter assignment requires host communication and may be affected by network latency

        .LINK
        New-VDSwitch
        Add-VDSwitchVMHost
        New-VDPortgroup
        Add-VDSwitchPhysicalNetworkAdapter
        Get-VMHostNetworkAdapter
    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$DatacenterName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [System.Object[]]$nicList,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$NumUplinks,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [System.Object[]]$portGroups,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$VdsName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$VdsVersion
    )

    Write-LogMessage -Type DEBUG -Message "Entered Set-VirtualDistributedSwitch function..."

    # Verify vCenter connection before proceeding.
    $connectionTest = Test-VcenterConnection
    if (-not $connectionTest.IsConnected) {
        Write-LogMessage -Type ERROR -Message "Not connected to vCenter `"$Script:VCenterName`": $($connectionTest.ErrorMessage)"
        throw "Deployment failed. Check logs for details."
    }

    try {

        # Get datacenter, cluster, and host objects.
        $datacenterObject = Get-Datacenter -Name $DatacenterName -Server $Script:VCenterName
        $clusterObject = Get-Cluster -Name $ClusterName -Server $Script:VCenterName
        $hostname = Get-VMHost -Location $clusterObject -Server $Script:VCenterName

        # Create or retrieve VDS.
        $vdsObject = Invoke-VDSCreation -VdsName $VdsName -DatacenterObject $datacenterObject -VdsVersion $VdsVersion -NumUplinks $NumUplinks

        # Add ESX host to the VDS.
        $result = Add-HostToVDS -Hostname $hostname -VdsName $VdsName
        if ($result -and -not $result.Success) {
            throw "Deployment failed. Check logs for details."
        }

        # Create distributed port groups.
        $result = New-VDSPortGroups -VdsName $VdsName -PortGroups $portGroups
        if ($result -and -not $result.Success) {
            throw "Deployment failed. Check logs for details."
        }

        # Add physical network adapters to VDS.
        $result = Add-PhysicalAdaptersToVDS -VdsObject $vdsObject -VdsName $VdsName -Hostname $hostname -NicList $nicList
        if ($result -and -not $result.Success) {
            throw "Deployment failed. Check logs for details."
        }
    } catch [System.UnauthorizedAccessException] {
        Write-LogMessage -Type ERROR -Message "Cannot configure distributed switch `"$VdsName`" due to authorization issues: $_"
        throw "Deployment failed. Check logs for details."
    } catch [System.TimeoutException] {
        Write-LogMessage -Type ERROR -Message "Cannot configure distributed switch `"$VdsName`" due to network/timeout issues: $_"
        throw "Deployment failed. Check logs for details."
    } catch {
        Write-LogMessage -Type ERROR -Message "Failed to configure distributed switch `"$VdsName`": $_"
        throw "Deployment failed. Check logs for details."
    }
}
Function Set-VMFSStoragePolicy {

    <#
        .SYNOPSIS
        Creates a tag-based VMFS storage policy and applies it to a specified datastore.

        .DESCRIPTION
        This function creates a VMware Storage Policy-Based Management (SPBM) storage policy
        specifically for VMFS datastores using tag-based rules. It configures volume allocation
        rules combined with vSphere tag requirements and applies the policy to the specified
        datastore. The function checks if the policy already exists before creating a new one
        and includes comprehensive error handling for authorization and network timeout scenarios.

        The storage policy created will have both volume allocation capabilities and tag-based
        placement rules, ensuring that virtual machines using this policy are placed on storage
        that matches both the specified allocation type and the required tags.

        .EXAMPLE
        Set-VMFSStoragePolicy -policyName "VMFS-Storage-Policy" -storageType "VMFS" -ruleValue "Conserve space when possible" -datastoreName "datastore1" -tagName "Production" -tagCatalog "Environment"

        Creates a VMFS storage policy named "VMFS-Storage-Policy" with space conservation rule and Production tag requirement, then applies it to "datastore1".

        .EXAMPLE
        Set-VMFSStoragePolicy -policyName "VMFS-FullInit-Policy" -storageType "VMFS" -ruleValue "Fully Initialized" -datastoreName "production-ds" -tagName "HighPerformance" -tagCatalog "Performance"

        Creates a VMFS storage policy with fully initialized allocation rule and HighPerformance tag requirement, then applies it to "production-ds" datastore.

        .PARAMETER PolicyName
        The name of the storage policy to create. Must be a non-empty string.

        .PARAMETER StorageType
        The type of storage policy to create. Currently only supports "VMFS" storage type.

        .PARAMETER RuleValue
        The volume allocation rule to apply to the storage policy. Valid values are:
        - "Conserve space when possible" - Thin provisioning to save space
        - "Fully Initialized" - Thick provisioning with full initialization
        - "ReserveSpace" - Thick provisioning with space reservation

        .PARAMETER DatastoreName
        The name of the datastore to which the storage policy will be applied. Must be a non-empty string.

        .PARAMETER TagName
        The name of the vSphere tag that must be associated with storage for this policy. The tag must exist in the specified tag catalog.

        .PARAMETER TagCatalog
        The name of the vSphere tag catalog/category that contains the required tag. The catalog must exist and contain the specified tag.

        .NOTES
        - Requires connection to vCenter via PowerCLI
        - Uses VMware Storage Policy-Based Management (SPBM) cmdlets
        - Requires vSphere tags to be configured and assigned to storage resources
        - The specified tag and tag catalog must exist before running this function
        - Function will exit with code 1 on any errors
        - Logs all operations and errors using Write-LogMessage function
        - Storage policy combines both volume allocation rules and tag-based placement rules
    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$DatastoreName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$PolicyName,
        [Parameter(Mandatory = $true)] [ValidateSet("Conserve space when possible", "Fully Initialized", "ReserveSpace")] [String]$RuleValue,
        [Parameter(Mandatory = $true)] [ValidateSet("VMFS")] [String]$StorageType,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$TagCatalog,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$TagName
    )

    Write-LogMessage -Type DEBUG -Message "Entered Set-VMFSStoragePolicy function..."

    # Verify vCenter connection before proceeding.
    $connectionTest = Test-VcenterConnection
    if (-not $connectionTest.IsConnected) {
        Write-LogMessage -Type ERROR -Message "Not connected to vCenter `"$Script:VCenterName`": $($connectionTest.ErrorMessage)"
        throw "Deployment failed. Check logs for details."
    }

    try {
        $policy = Get-SpbmStoragePolicy -Name $PolicyName -Server $Script:VCenterName -ErrorAction SilentlyContinue
        if($policy) {
            Write-LogMessage -Type WARNING -Message "Storage policy `"$PolicyName`" using rule `"$RuleValue`" has already been created on vCenter `"$Script:VCenterName`"."
            return
        }

        $volumeAllocationCapability = Get-SpbmCapability -Name "com.vmware.storage.volumeallocation.VolumeAllocationType" -Server $Script:VCenterName -ErrorAction Stop
        $capabilityRule = New-SpbmRule -Capability $volumeAllocationCapability -Value $RuleValue -Server $Script:VCenterName -ErrorAction Stop

        $tagObject = Get-Tag -Name $TagName -Category $TagCatalog -Server $Script:VCenterName -ErrorAction Stop
        $tagRule = New-SpbmRule -AnyOfTags $tagObject -Server $Script:VCenterName -ErrorAction Stop

        # Create a rule set with the storage capability rule and tag rules.
        $ruleSet = New-SpbmRuleSet -AllOfRules $capabilityRule, $tagRule -ErrorAction Stop

        # Create policy
        New-SpbmStoragePolicy -Name $PolicyName `
        -Description "$StorageType with $RuleValue'" `
        -AnyOfRuleSets $ruleSet -Server $Script:VCenterName | Out-Null

        $policyCreated = Get-SpbmStoragePolicy -Name $PolicyName -Server $Script:VCenterName

        if($policyCreated){
            Write-LogMessage -Type INFO -Message "Successfully created storage policy `"$PolicyName`" using rule `"$RuleValue`"."
        }
    } catch [System.UnauthorizedAccessException] {
        Write-LogMessage -Type ERROR -Message "Cannot create storage policy `"$PolicyName`" due to authorization issues: $_"
        throw "Deployment failed. Check logs for details."
    }
    catch [System.TimeoutException] {
        Write-LogMessage -Type ERROR -Message "Cannot create storage policy `"$PolicyName`" due to network/timeout issues: $_"
        throw "Deployment failed. Check logs for details."
    }
    catch {
        Write-LogMessage -Type ERROR -Message "Failed to create storage policy `"$PolicyName`": $_"
        throw "Deployment failed. Check logs for details."
    }
}
Function Get-SupervisorControlPlaneIp {

    <#
        .SYNOPSIS
        Retrieves the IPv4 address of the Supervisor Control Plane VM in a specified cluster.

        .DESCRIPTION
        This function locates the Supervisor Control Plane VM within the specified vSphere cluster
        and returns its IPv4 address. The function searches for VMs with names containing
        "SupervisorControlPlane" and extracts the primary IPv4 address from the VM's guest information.

        .EXAMPLE
        Get-SupervisorControlPlaneIp -ClusterName "MyCluster"
        Returns the IPv4 address of the Supervisor Control Plane VM in the "MyCluster" cluster.

        .PARAMETER ClusterName
        The name of the vSphere cluster where the Supervisor Control Plane VM is hosted.
        This parameter is optional but recommended for targeted searches.

        .OUTPUTS
        System.String
        Returns the IPv4 address of the Supervisor Control Plane VM as a string.

        .NOTES
        - Requires an active connection to vCenter
        - The function will exit with error code 1 if the VM cannot be found or accessed
        - Only returns IPv4 addresses (filters out IPv6 addresses)
    #>

    Param (
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$ClusterName
    )
    Write-LogMessage -Type DEBUG -Message "Entered Get-SupervisorControlPlaneIp function..."

    # Verify vCenter connection before proceeding.
    $connectionTest = Test-VcenterConnection
    if (-not $connectionTest.IsConnected) {
        Write-LogMessage -Type ERROR -Message "Not connected to vCenter `"$Script:VCenterName`": $($connectionTest.ErrorMessage)"
        throw "Deployment failed. Check logs for details."
    }

    try {
        # Get all Supervisor Control Plane VMs in the given cluster.

        $controlPlaneVM = Get-Cluster -Name $ClusterName -Server $Script:VCenterName |
        Get-VM |
        Where-Object { $_.Name -like "*SupervisorControlPlane*" }  # Adjust pattern if needed

        $vmView = Get-View $controlPlaneVM.Id

        # Get IPv4 address
        $ip = $vmView.Guest.IPAddress | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' }
        return $ip

    } catch [System.UnauthorizedAccessException] {
        Write-LogMessage -Type ERROR -Message "Cannot fetch Supervisor Control Plane VM details on cluster `"$ClusterName`" attached to vCenter `"$Script:VCenterName`" due to authorization issues: $_"
        throw "Deployment failed. Check logs for details."
    }
    catch [System.TimeoutException] {
        Write-LogMessage -Type ERROR -Message "Cannot fetch Supervisor Control Plane VM details on cluster `"$ClusterName`" attached to vCenter `"$Script:VCenterName`" due to network/timeout issues: $_"
        throw "Deployment failed. Check logs for details."
    }
    catch {
        Write-LogMessage -Type ERROR -Message "Supervisor Control Plane VM details on cluster `"$ClusterName`" attached to vCenter `"$Script:VCenterName`" could not be fetched: $_"
        throw "Deployment failed. Check logs for details."
    }
}
Function Set-VCFContextCreate {

    <#
        .SYNOPSIS
        Creates and configures a VCF CLI context for connecting to Supervisor Control Plane VM with SSO authentication, including context existence validation and retry logic.

        .DESCRIPTION
        The Set-VCFContextCreate function establishes a VCF CLI context to communicate with a Kubernetes
        Supervisor Control Plane VM using SSO authentication. This function performs several key operations:
        1. Checks if the VCF context already exists to avoid duplicates
        2. Creates a new VCF context with the specified endpoint and SSO credentials
        3. Implements retry logic with timeout handling for context creation
        4. Validates successful context creation by checking context availability
        5. Switches to the newly created context for subsequent VCF CLI operations

        The function uses the VCF CLI tool to create and manage contexts, which are required for
        interacting with vSphere with Tanzu (formerly known as vSphere with Kubernetes) environments.
        The context stores authentication and connection information for the Supervisor Control Plane.

        Key features:
        - Checks for existing VCF contexts to prevent duplicates
        - Creates VCF CLI context with SSO authentication
        - Supports optional TLS certificate verification bypass
        - Implements retry logic with configurable timeout (default 60 seconds, configurable via TimeoutSeconds parameter)
        - Validates context creation through periodic availability checks
        - Automatically switches to the new context after creation
        - Comprehensive error handling with detailed logging
        - Handles context creation failures with automatic retry and cleanup

        .PARAMETER ContextName
        The name of the VCF context to create. This name will be used to identify and reference
        the context in subsequent VCF CLI operations. The context name should be unique and
        descriptive of the target environment.

        .PARAMETER Endpoint
        The IP address or FQDN of the Supervisor Control Plane VM. This is the endpoint that
        the VCF CLI will use to communicate with the Kubernetes API server running on the
        Supervisor Control Plane. Typically obtained from Get-SupervisorControlPlaneIp function.

        .PARAMETER SsoUsername
        The SSO username for authentication with the Supervisor Control Plane. This should be
        a valid vCenter SSO user account that has appropriate permissions to access the
        Supervisor Control Plane and manage Kubernetes resources.

        .PARAMETER InsecureTls
        Optional switch parameter that bypasses TLS certificate verification when connecting
        to the Supervisor Control Plane. Use this parameter when working with self-signed
        certificates or in development/testing environments where certificate validation
        may cause connection issues.

        .PARAMETER TimeoutSeconds
        The maximum time in seconds to wait for VCF context creation and validation. Default is 60.

        .PARAMETER CheckIntervalSeconds
        The interval in seconds between checks when waiting for VCF context to be available. Default is 5.

        .EXAMPLE
        Set-VCFContextCreate -ContextName "prod-supervisor" -Endpoint "192.168.1.100" -SsoUsername "administrator@vsphere.local"

        Creates a VCF context named "prod-supervisor" connecting to the Supervisor Control Plane
        at IP address 192.168.1.100 using the administrator@vsphere.local SSO account. The function
        will check if the context already exists and skip creation if found, then validate the
        context creation with retry logic before switching to it.

        .EXAMPLE
        Set-VCFContextCreate -ContextName "dev-supervisor" -Endpoint "supervisor.dev.local" -SsoUsername "devuser@vsphere.local" -InsecureTls

        Creates a VCF context named "dev-supervisor" connecting to supervisor.dev.local with
        TLS certificate verification bypassed, useful for development environments. Includes
        context existence checking and retry logic with timeout handling.

        .EXAMPLE
        Set-VCFContextCreate -ContextName $ContextName -Endpoint $supervisorControlPlaneVmIp -SsoUsername $Script:VCenterUser -InsecureTls

        Creates a VCF context using variables, typically called during automated deployment
        scenarios where the context name, endpoint, and username are determined dynamically.
        The function will implement retry logic and timeout handling for reliable context creation.

        .NOTES
        - Requires VCF CLI tool to be installed and available in the system PATH
        - The function will exit the script with error code 1 if context creation or switching fails
        - Uses Write-LogMessage for consistent logging throughout the VCF PowerShell Toolbox
        - The created context will be used for subsequent kubectl and VCF CLI operations
        - Context information is stored by the VCF CLI tool for future use
        - This function is typically called before deploying ArgoCD instances or other Kubernetes resources
        - Implements context existence checking to prevent duplicate context creation
        - Uses retry logic with configurable timeout (default 60 seconds) and check interval (default 5 seconds) for context validation
        - Automatically deletes and recreates contexts if initial creation fails during validation
        - Constructs full context name using global $argocdNamespace variable for validation
        - Creates temporary JSON files for context list operations and cleans them up automatically

        .LINK
        Test-CommandAvailability
        Get-SupervisorControlPlaneIp
        Add-ArgoCDInstance
    #>

    Param (
        [Parameter(Mandatory = $false)] [ValidateRange(1, [int]::MaxValue)] [Int]$CheckIntervalSeconds = 5,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ContextName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Endpoint,
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [Switch]$InsecureTls,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$SsoUsername,
        [Parameter(Mandatory = $false)] [ValidateRange(1, [int]::MaxValue)] [Int]$TimeoutSeconds = 60
    )
    Write-LogMessage -Type DEBUG -Message "Entered Set-VCFContextCreate function..."

    try {
        # Step 1: Create VCF context with SSO authentication.

        $createArgs = @(
            "context", "create", $ContextName,
            "--endpoint", $Endpoint,
            "--username", $SsoUsername
        )

        # Add the insecure tls flag if the parameter is passed.
        if ($InsecureTls) {
            $createArgs += "--insecure-skip-tls-verify"
        }

        # Create a temporary data file to store the JSON object from the vcf context list command.
        $temporaryDataFilePath = [System.IO.Path]::GetTempPath() + "temporaryData.json"

        # List VCF contexts and store the JSON object in the temporary data file.
        & $Script:VcfCmd context list -o json | Out-File -FilePath $temporaryDataFilePath
        $jsonObject = Get-Content -Path $temporaryDataFilePath | ConvertFrom-Json

        # Remove the temporary data file.
        Remove-Item -Path $temporaryDataFilePath

        # Check if the VCF context already exists.
        if ($jsonObject | Where-Object { $_.name -eq $ContextName }) {
            Write-LogMessage -Type WARNING -Message "VCF context `"$ContextName`" already exists."
            return
        }
        Write-LogMessage -Type INFO "Creating VCF context `"$ContextName`" with SSO authentication..."
        & $Script:VcfCmd $createArgs

        # Create a variable to store the VCF context name.
        $vksNS = $ContextName+":"+$argocdNamespace

         # Check if the VCF context was created successfully with timeout.
        $elapsedTime = 0
        $contextFound = $false

        Write-LogMessage -Type INFO -Message "Waiting for VCF context `"$ContextName`" to be available (timeout: $TimeoutSeconds seconds)..."

        while ($elapsedTime -lt $TimeoutSeconds -and -not $contextFound) {
            # Get fresh context list.

            & $Script:VcfCmd context list -o json | Out-File -FilePath $temporaryDataFilePath
            $jsonObject = Get-Content -Path $temporaryDataFilePath | ConvertFrom-Json
            Remove-Item -Path $temporaryDataFilePath

            # Check if the context exists.

            foreach ($ns in $jsonObject) {
                Write-LogMessage -Type INFO -suppressOutputToScreen -Message "Discovered name space is `"$ns`"."
                if ($($ns.name) -eq $vksNS) {
                    Write-LogMessage -Type INFO -Message "VCF context `"$ContextName`" created successfully."
                    $contextFound = $true
                    break
                }
            }

            # If the context is not found, delete the context and create a new one.
            if (-not $contextFound) {
                & $Script:VcfCmd context delete $ContextName -y
                Write-LogMessage -Type INFO -Message "VCF context not found yet, waiting $CheckIntervalSeconds before trying again... (elapsed: $elapsedTime seconds)"
                Start-Sleep -Seconds $CheckIntervalSeconds
                & $Script:VcfCmd $createArgs | Out-Null
                $elapsedTime += $CheckIntervalSeconds
            }
        }

        if (-not $contextFound) {
            Write-LogMessage -Type ERROR -Message "VCF context `"$ContextName`" creation failed - timeout reached after $TimeoutSeconds seconds."
            throw "Deployment failed. Check logs for details."
        }

        # Step 2: Use the context.

        Write-LogMessage -Type INFO "Switching to VCF context `"$ContextName`"..."
        & $Script:VcfCmd context use $ContextName
        if ($LASTEXITCODE -ne 0) {
            return Write-ErrorAndReturn -ErrorMessage "Failed to switch to VCF context" -ErrorCode "ERR_VCF_CONTEXT"
        }

    } catch {
       Write-LogMessage -Type ERROR -Message "Supervisor Control Plane VM details could not be fetched: $_"
            throw "Deployment failed. Check logs for details."
    }
}
Function Test-WebhookServiceReady {

    <#
        .SYNOPSIS
        Checks if the ArgoCD operator webhook service is ready with active endpoints.

        .DESCRIPTION
        The Test-WebhookServiceReady function checks if the webhook service exists and has
        active endpoints (pods backing it). This is used to verify the webhook service
        is ready before attempting to create ArgoCD instances.

        .PARAMETER ServiceNamespace
        The Kubernetes namespace where the webhook service is deployed.

        .PARAMETER ServiceName
        The name of the webhook service. Defaults to "argocd-service-webhook-service".

        .OUTPUTS
        System.Boolean
        Returns $true if the webhook service exists and has active endpoints, $false otherwise.

        .NOTES
        This function uses kubectl to query the service and endpoints. Errors are caught
        and logged at DEBUG level, returning $false to allow retry logic.

    #>

    Param(
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ServiceNamespace,
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$ServiceName = "argocd-service-webhook-service"
    )

    try {
        # Check if the webhook service exists.
        $webhookService = & $Script:KubectlCmd get service $ServiceName -n $ServiceNamespace -o json 2>$null | ConvertFrom-Json

        if (-not $webhookService) {
            return $false
        }

        # Service exists, now check if it has endpoints (pods backing it).
        $webhookEndpoints = & $Script:KubectlCmd get endpoints $ServiceName -n $ServiceNamespace -o json 2>$null | ConvertFrom-Json

        if ($webhookEndpoints.subsets.addresses.Count -gt 0) {
            Write-LogMessage -Type INFO -Message "ArgoCD operator webhook service is ready with $($webhookEndpoints.subsets.addresses.Count) endpoint(s)."
            return $true
        }

        return $false
    }
    catch {
        Write-LogMessage -Type DEBUG -Message "Error checking webhook service: $($_.Exception.Message). Continuing to wait..."
        return $false
    }
}
Function Wait-WebhookServiceReady {

    <#
        .SYNOPSIS
        Waits for the ArgoCD operator webhook service to become ready.

        .DESCRIPTION
        The Wait-WebhookServiceReady function polls the webhook service until it becomes
        ready with active endpoints, or until a timeout is reached. This function provides
        diagnostic information if the timeout is reached.

        .PARAMETER ServiceNamespace
        The Kubernetes namespace where the webhook service is deployed.

        .PARAMETER ServiceName
        The name of the webhook service. Defaults to "argocd-service-webhook-service".

        .PARAMETER CheckInterval
        Interval between webhook service availability checks, in seconds. Defaults to 5 seconds.

        .PARAMETER TimeoutSeconds
        Maximum time to wait for webhook service readiness, in seconds. Defaults to 180 seconds.

        .OUTPUTS
        PSCustomObject
        Returns an object with Success property indicating if the webhook service became ready.

        .NOTES
        This function will return an error result if the timeout is reached, including
        diagnostic information about pods and namespace status.

    #>

    Param(
        [Parameter(Mandatory = $false)] [ValidateRange(1, [int]::MaxValue)] [Int]$CheckInterval = 5,
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$ServiceName = "argocd-service-webhook-service",
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ServiceNamespace,
        [Parameter(Mandatory = $false)] [ValidateRange(1, [int]::MaxValue)] [Int]$TimeoutSeconds = 180
    )

    Write-LogMessage -Type INFO -Message "Waiting for ArgoCD operator webhook service to be ready (timeout: $TimeoutSeconds seconds)..."

    $elapsedTime = 0
    $webhookReady = $false

    do {
        $webhookReady = Test-WebhookServiceReady -ServiceNamespace $ServiceNamespace -ServiceName $ServiceName

        if (-not $webhookReady) {
            Write-LogMessage -Type DEBUG -Message "Webhook service not ready yet. Waiting..."
            Start-Sleep $CheckInterval
            $elapsedTime += $CheckInterval
        }

        # Timeout check.
        if ($elapsedTime -ge $TimeoutSeconds -and -not $webhookReady) {
            Write-LogMessage -Type ERROR -Message "Timeout waiting for ArgoCD operator webhook service after $TimeoutSeconds seconds."
            Write-LogMessage -Type ERROR -Message "The webhook service may not be properly installed in namespace `"$ServiceNamespace`"."

            # Provide diagnostic information.
            Write-LogMessage -Type INFO -Message "Diagnostic: Checking pods in operator namespace `"$ServiceNamespace`"..."
            $operatorPods = & $Script:KubectlCmd get pods -n $ServiceNamespace -o json 2>$null | ConvertFrom-Json
            if ($operatorPods.items.Count -gt 0) {
                Write-LogMessage -Type INFO -Message "Found $($operatorPods.items.Count) pod(s) in namespace `"$ServiceNamespace`":"
                foreach ($pod in $operatorPods.items) {
                    Write-LogMessage -Type INFO -Message "  - Pod: $($pod.metadata.name), Phase: $($pod.status.phase)"
                }
            }
            else {
                Write-LogMessage -Type ERROR -Message "No pods found in namespace `"$ServiceNamespace`". The operator may not have been installed successfully."
            }

            # Check if the namespace itself exists.
            Write-LogMessage -Type INFO -Message "Diagnostic: Verifying namespace `"$ServiceNamespace`" exists..."
            $namespaceCheck = & $Script:KubectlCmd get namespace $ServiceNamespace -o json 2>$null | ConvertFrom-Json
            if (-not $namespaceCheck) {
                Write-LogMessage -Type ERROR -Message "Namespace `"$ServiceNamespace`" does not exist. The ArgoCD operator installation failed."
            }
            else {
                Write-LogMessage -Type INFO -Message "Namespace `"$ServiceNamespace`" exists."
            }

            return Write-ErrorAndReturn -ErrorMessage "ArgoCD operator webhook service not ready after $TimeoutSeconds seconds" -ErrorCode "ERR_WEBHOOK_TIMEOUT"
        }

    } while (-not $webhookReady)

    return @{
        Success = $true
        ErrorMessage = $null
        ErrorCode = $null
    }
}
Function Get-PodReadinessStatus {

    <#
        .SYNOPSIS
        Retrieves the readiness status of pods in a Kubernetes namespace.

        .DESCRIPTION
        The Get-PodReadinessStatus function queries kubectl to get pod status information
        and returns a structured object with total pod count, ready pod count, and readiness
        status. This function is used to monitor pod deployment progress.

        .PARAMETER Namespace
        The Kubernetes namespace to query for pods.

        .OUTPUTS
        PSCustomObject
        Returns an object with the following properties:
        - TotalPods: Total number of pods in the namespace
        - ReadyPods: Number of pods in Running or Succeeded state
        - AllReady: Boolean indicating if all pods are ready
        - ReadyPodNames: Array of names of ready pods

        .NOTES
        Pods are considered ready if their phase is "Running" or "Succeeded".

    #>

    Param(
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Namespace
    )

    # Get pod status directly without file I/O.
    $jsonOutput = & $Script:KubectlCmd get pods -n $Namespace -o json | ConvertFrom-Json

    $totalPods = $jsonOutput.items.Count

    # Count ready pods.
    $readyPods = @($jsonOutput.items | Where-Object {
        $_.status.phase -eq "Running" -or $_.status.phase -eq "Succeeded"
    })

    return @{
        TotalPods = $totalPods
        ReadyPods = $readyPods.Count
        AllReady = ($totalPods -gt 1 -and $readyPods.Count -eq $totalPods)
        ReadyPodObjects = $readyPods
    }
}
Function Wait-ArgoCDPodsReady {

    <#
        .SYNOPSIS
        Waits for all ArgoCD pods to become ready in a namespace.

        .DESCRIPTION
        The Wait-ArgoCDPodsReady function monitors pod status and waits for all ArgoCD pods
        to reach Running or Succeeded state. The function logs pod readiness progress and
        handles timeout scenarios.

        .PARAMETER Namespace
        The Kubernetes namespace where ArgoCD pods are deployed.

        .PARAMETER CheckInterval
        Interval between pod status checks, in seconds. Defaults to 10 seconds.

        .PARAMETER TimeoutSeconds
        Maximum time to wait for all pods to become ready, in seconds. Defaults to 600 seconds.

        .OUTPUTS
        None
        This function throws an exception if the timeout is reached or if pods fail to become ready.

        .NOTES
        The function requires at least 2 pods to be present (more than just the secret-generation pod)
        before considering the deployment complete. Pods are logged only once when they become ready.

    #>

    Param(
        [Parameter(Mandatory = $false)] [ValidateRange(1, [int]::MaxValue)] [Int]$CheckInterval = 10,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Namespace,
        [Parameter(Mandatory = $false)] [ValidateRange(1, [int]::MaxValue)] [Int]$TimeoutSeconds = 600
    )

    $elapsedTime = 0
    $loggedReadyPods = @()
    $allPodsReady = $false

    do {
        $podStatus = Get-PodReadinessStatus -Namespace $Namespace
        $totalPods = $podStatus.TotalPods
        $readyPods = $podStatus.ReadyPods
        $allPodsReady = $podStatus.AllReady

        # Wait for pods to be created (more than just the secret-generation pod).
        if ($totalPods -le 1) {
            $allPodsReady = $false
            Write-LogMessage -Type INFO -Message "Waiting for ArgoCD pods to be created. Found: $totalPods."
            Start-Sleep $CheckInterval
            $elapsedTime += $CheckInterval

            # Timeout check.
            if ($elapsedTime -ge $TimeoutSeconds) {
                Write-LogMessage -Type ERROR -Message "Timeout waiting for ArgoCD pods to be created after $TimeoutSeconds seconds. Only $totalPods pod(s) found."
                throw "Deployment failed. Check logs for details."
            }
            continue
        }

        # Log ready pods only once.
        foreach ($pod in $podStatus.ReadyPodObjects) {
            if ($pod.metadata.name -notin $loggedReadyPods) {
                Write-LogMessage -Type INFO -Message "ArgoCD pod `"$($pod.metadata.name)`" is now $($pod.status.phase)."
                $loggedReadyPods += $pod.metadata.name
            }
        }

        if (-not $allPodsReady) {
            Write-LogMessage -Type INFO -Message "Waiting for ArgoCD pods to be ready. Ready: $readyPods, Total: $totalPods."
            Start-Sleep $CheckInterval
            $elapsedTime += $CheckInterval

            # Timeout check.
            if ($elapsedTime -ge $TimeoutSeconds) {
                Write-LogMessage -Type ERROR -Message "Timeout waiting for ArgoCD pods after $TimeoutSeconds seconds. Ready: $readyPods/$totalPods."
                throw "Deployment failed. Check logs for details."
            }
        }

    } while (-not $allPodsReady)

    Write-LogMessage -Type INFO -Message "All $totalPods ArgoCD pods are ready."
}
Function Add-ArgoCDInstance {

    <#
        .SYNOPSIS
        Deploys an ArgoCD instance to a vSphere Supervisor namespace using kubectl and VCF CLI integration.

        .DESCRIPTION
        The Add-ArgoCDInstance function creates and configures an ArgoCD instance within a specified vSphere Supervisor
        namespace by applying Kubernetes YAML manifests through kubectl commands and VCF CLI context management.
        This function is designed to work as part of the vSphere with Tanzu ecosystem for GitOps-based application
        deployment and lifecycle management.

        The function performs the following key operations:
        • Writes ArgoCD deployment YAML content to the specified file path using UTF-8 encoding
        • Establishes VCF CLI context for the target namespace with configurable TLS verification
        • Applies the ArgoCD deployment manifest using kubectl to create the instance resources
        • Implements a 60-second wait period for ArgoCD instance initialization and readiness
        • Configures kubectl context to use the ArgoCD namespace for subsequent operations
        • Retrieves and displays deployed services for verification and troubleshooting

        This function integrates with the broader vSphere with Tanzu deployment workflow, requiring proper
        authentication context, an existing supervisor namespace, and a pre-installed ArgoCD operator.
        The deployment process includes comprehensive error handling and will terminate script execution
        if critical operations fail.

        Key features:
        - Native integration with vSphere Supervisor clusters and VCF CLI
        - Automated YAML content management and UTF-8 encoding
        - Context-aware kubectl operations with namespace switching
        - Built-in deployment verification and service discovery
        - Comprehensive error handling with detailed logging
        - Configurable TLS verification for both development and production environments

        .PARAMETER ArgoCdNamespace
        The name of the vSphere Supervisor namespace where the ArgoCD instance will be deployed.
        This namespace must already exist and be properly configured with storage policies, VM classes,
        and the ArgoCD operator. The namespace serves as both the deployment target and the kubectl
        context for all operations performed by this function. Must follow Kubernetes naming conventions.

        .PARAMETER ArgoCdDeploymentYamlPath
        The file system path where the ArgoCD deployment YAML configuration will be written and applied.
        This parameter is optional with a default value that can be provided by calling functions.
        The function expects the $yamlContent variable to be available in the calling scope containing
        valid ArgoCD deployment YAML. The file will be created or overwritten with UTF-8 encoding.

        .PARAMETER ContextName
        The name of the VCF CLI context to use for the deployment. This context must be previously
        created using Set-VCFContextCreate and should correspond to the target supervisor cluster
        where the ArgoCD instance will be deployed.

        .PARAMETER ClusterId
        The vCenter cluster MoRef identifier (e.g., "domain-c462") where the supervisor is enabled.
        This is used to dynamically construct the service namespace for webhook validation checks.
        The cluster ID is obtained from Get-ClusterId and is required because the service namespace
        format is "svc-<service>-<cluster-id>", not "svc-<service>-<supervisor-uuid>".

        .PARAMETER Service
        The service identifier (reference name) for the ArgoCD operator supervisor service.
        This is used to dynamically construct the service namespace for webhook validation checks.
        Should match the format "argocd-service.vsphere.vmware.com" or similar naming convention.

        .PARAMETER InsecureTls
        When specified, enables insecure TLS verification for VCF CLI operations by adding the
        --insecure-skip-tls-verify flag. This is useful for development and lab environments
        with self-signed certificates. When not specified, uses secure TLS verification suitable
        for production environments.

        .PARAMETER AuthCheckInterval
        Interval between kubectl authentication retry attempts, in seconds.
        Defaults to 5 seconds. Lower values provide faster retry but increase system load.

        .PARAMETER AuthTimeoutSeconds
        Maximum time to wait for kubectl authentication to succeed, in seconds.
        Defaults to 60 seconds. The function will retry authentication at regular intervals
        until either authentication succeeds or the timeout is reached.

        .PARAMETER PodReadyCheckInterval
        Interval between pod status checks while waiting for ArgoCD pods to become ready, in seconds.
        Defaults to 10 seconds. Lower values provide more frequent updates but increase API load.

        .PARAMETER PodReadyTimeoutSeconds
        Maximum time to wait for all ArgoCD pods to become ready, in seconds.
        Defaults to 600 seconds (10 minutes). The function will monitor pod status and wait
        for all pods to reach Running or Succeeded state before completion.

        .PARAMETER WebhookReadyCheckInterval
        Interval between webhook service availability checks, in seconds.
        Defaults to 5 seconds. Lower values provide faster detection but increase API load.

        .PARAMETER WebhookReadyTimeoutSeconds
        Maximum time to wait for the ArgoCD operator webhook service to become ready, in seconds.
        Defaults to 180 seconds (3 minutes). The function will check for webhook service availability
        before attempting to create ArgoCD instances to avoid webhook validation failures.

        .EXAMPLE
        Add-ArgoCDInstance -ArgoCdNamespace "argocd-system" -ArgoCdDeploymentYamlPath "C:\configs\argocd-deployment.yaml" -ContextName "prod-context"

        Deploys an ArgoCD instance to the "argocd-system" namespace using secure TLS verification.
        The function writes the YAML content and applies it using kubectl, then verifies the deployment.

        .EXAMPLE
        Add-ArgoCDInstance -ArgoCdNamespace "dev-argocd" -ArgoCdDeploymentYamlPath "/tmp/argocd-dev-config.yaml" -ContextName "dev-context" -InsecureTls

        Creates an ArgoCD instance in the "dev-argocd" namespace with insecure TLS verification,
        suitable for development and testing environments with self-signed certificates.

        .EXAMPLE
        $deploymentParams = @{
            argoCdNamespace = $InputData.common.argoCD.nameSpace
            argoCdDeploymentYamlPath = $InputData.common.argoCD.argoCdDeploymentYamlPath
            contextName = $InputData.common.argoCD.contextName
            insecureTls = $true
        }
        Add-ArgoCDInstance @deploymentParams

        Deploys ArgoCD using configuration parameters from input data with parameter splatting,
        enabling dynamic deployment scenarios based on configuration files with insecure TLS for lab environments.

        .OUTPUTS
        None
        This function does not return objects but performs deployment operations with side effects.
        Success is indicated by the absence of exceptions and the successful display of services
        in the target namespace. All operations are logged for audit trail and troubleshooting.

        .NOTES
        Prerequisites:
        • VCF CLI must be installed and accessible in the system PATH
        • kubectl must be installed and configured for Kubernetes operations
        • Target vSphere Supervisor namespace must exist with proper configuration
        • ArgoCD operator must be installed and running in the supervisor cluster
        • $yamlContent variable must be defined in calling scope with valid YAML content

        Behavior:
        • Uses configurable TLS verification for VCF CLI operations based on the insecureTls parameter
        • Implements retry logic for kubectl authentication with configurable timeout and check interval
        • Automatically attempts to re-authenticate using vcf context if authentication fails
        • Implements a fixed 60-second wait time for ArgoCD instance availability
        • Switches kubectl context to the ArgoCD namespace, affecting subsequent kubectl operations
        • Overwrites existing deployment YAML files without warning
        • Terminates script execution (exit 1) if any deployment steps fail or authentication times out

        Security Considerations:
        • Use secure TLS verification (default) for production environments
        • Insecure TLS verification should only be used in development/lab environments with self-signed certificates
        • ArgoCD deployment includes service accounts with potentially elevated permissions
        • Network policies may need configuration for proper ArgoCD access
        • TLS certificate validation is configurable via the insecureTls parameter

        Performance Notes:
        • Fixed 60-second wait time may need adjustment based on cluster performance
        • Large YAML files are loaded entirely into memory during processing
        • kubectl operations are synchronous and may block on slow cluster responses

        .LINK
        Set-VCFContextCreate
        Add-ArgoCDNamespace
        Install-ArgoCDOperator
        Get-SupervisorControlPlaneIp
    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ArgoCdDeploymentYamlPath,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ArgoCdNamespace,
        [Parameter(Mandatory = $false)] [ValidateRange(1, [int]::MaxValue)] [Int]$AuthCheckInterval = 5,
        [Parameter(Mandatory = $false)] [ValidateRange(1, [int]::MaxValue)] [Int]$AuthTimeoutSeconds = 60,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterId,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ContextName,
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [Switch]$InsecureTls,
        [Parameter(Mandatory = $false)] [ValidateRange(1, [int]::MaxValue)] [Int]$PodReadyCheckInterval = 10,
        [Parameter(Mandatory = $false)] [ValidateRange(1, [int]::MaxValue)] [Int]$PodReadyTimeoutSeconds = 600,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Service,
        [Parameter(Mandatory = $false)] [ValidateRange(1, [int]::MaxValue)] [Int]$WebhookReadyCheckInterval = 5,
        [Parameter(Mandatory = $false)] [ValidateRange(1, [int]::MaxValue)] [Int]$WebhookReadyTimeoutSeconds = 180
    )

    Write-LogMessage -Type DEBUG -Message "Entered Add-ArgoCDInstance function..."

    # Construct the service namespace (format: svc-<service-slug>-<cluster-id>).
    # The service slug is derived from the service name by removing the domain suffix.
    # The cluster ID (e.g., domain-c462) is used, NOT the supervisor UUID.
    $serviceSlug = $Service -replace '\.vsphere\.vmware\.com$', ''
    $serviceNamespace = "svc-$serviceSlug-$ClusterId"

    if ($InsecureTls) {
        $insecureTlsFlag = "--insecure-skip-tls-verify"
    } else {
        $insecureTlsFlag = ""
    }

    try {
        # Naive approach to switch to VCF context.
        if ($insecureTlsFlag) {
            & $Script:VcfCmd context use $ContextName --insecure-skip-tls-verify
        } else {
            & $Script:VcfCmd context use $ContextName
        }

        if ($LASTEXITCODE -ne 0) {
            return Write-ErrorAndReturn -ErrorMessage "Failed to switch to VCF context `"$ContextName`"" -ErrorCode "ERR_VCF_CONTEXT"
        }

        # Wait for ArgoCD operator webhook service to be ready before applying YAML.
        $webhookResult = Wait-WebhookServiceReady -ServiceNamespace $serviceNamespace -ServiceName "argocd-service-webhook-service" -CheckInterval $WebhookReadyCheckInterval -TimeoutSeconds $WebhookReadyTimeoutSeconds
        if (-not $webhookResult.Success) {
            return $webhookResult
        }

        & $Script:KubectlCmd apply -f $ArgoCdDeploymentYamlPath
        if ($LASTEXITCODE -ne 0) {
            return Write-ErrorAndReturn -ErrorMessage "Failed to apply ArgoCD deployment YAML file `"$ArgoCdDeploymentYamlPath`"" -ErrorCode "ERR_KUBECTL_APPLY"
        }

        $vksNs = $ContextName+":"+$ArgoCdNamespace

        & $Script:KubectlCmd config use-context $vksNs
        if ($LASTEXITCODE -ne 0) {
            return Write-ErrorAndReturn -ErrorMessage "Failed to locate ArgoCD namespace `"$vksNs`"." -ErrorCode "ERR_KUBECTL_CONTEXT"
        }

        # Wait for kubectl authentication with retry logic.
        Write-LogMessage -Type INFO -Message "Verifying kubectl authentication for namespace `"$ArgoCdNamespace`" (timeout: $AuthTimeoutSeconds seconds)..."

        $elapsedTime = 0
        $authSuccess = $false

        do {
            try {
                # Check if we have permission to get pods in ArgoCD namespace.
                $canGetPods = & $Script:KubectlCmd auth can-i get pods -n $ArgoCdNamespace 2>&1
                $authExitCode = $LASTEXITCODE

                if ($authExitCode -eq 0 -and $canGetPods -eq "yes") {
                    # Authentication successful.
                    $authSuccess = $true
                    Write-LogMessage -Type INFO -Message "kubectl authentication verified for namespace `"$ArgoCdNamespace`" after $elapsedTime seconds"
                    break
                }

                # Authentication failed - try to re-authenticate.
                if ($elapsedTime -eq 0) {
                    Write-LogMessage -Type WARNING -Message "kubectl authentication failed: $canGetPods"
                    Write-LogMessage -Type INFO -Message "Attempting to re-authenticate using: vcf context use $ContextName"
                }

                # Re-authenticate using vcf context.
                if ($insecureTlsFlag) {
                    $null = & $Script:VcfCmd context use $ContextName --insecure-skip-tls-verify 2>&1
                } else {
                    $null = & $Script:VcfCmd context use $ContextName 2>&1
                }

                # Update progress.
                $statusMessage = "Waiting for authentication (exit code: $authExitCode)"
                $currentOperation = "Elapsed: $elapsedTime seconds"
                Write-Progress -Activity "Waiting for kubectl authentication" -Status $statusMessage -CurrentOperation $currentOperation

                # Wait before next check.
                Start-Sleep $AuthCheckInterval
                $elapsedTime += $AuthCheckInterval

            } catch {
                $errorMessage = $_.Exception.Message
                Write-LogMessage -Type ERROR -Message "Error during kubectl authentication check: $errorMessage"
                Write-Progress -Activity "Waiting for kubectl authentication" -Status "Error" -Completed
                throw "Deployment failed. Check logs for details."
            }
        } while ($elapsedTime -lt $AuthTimeoutSeconds)

        # Check if authentication succeeded.
        if (-not $authSuccess) {
            Write-Progress -Activity "Waiting for kubectl authentication" -Status "Timeout" -Completed
            Write-LogMessage -Type ERROR -Message "kubectl authentication failed after $AuthTimeoutSeconds seconds"
            Write-LogMessage -Type ERROR -Message "You may need to manually re-authenticate using: vcf context use $ContextName"
            throw "Deployment failed. Check logs for details."
        }

        Write-Progress -Activity "Waiting for kubectl authentication" -Status "Authenticated" -Completed

        # Wait for all ArgoCD pods to be ready.
        Wait-ArgoCDPodsReady -Namespace $ArgoCdNamespace -CheckInterval $PodReadyCheckInterval -TimeoutSeconds $PodReadyTimeoutSeconds

        Write-LogMessage -Type INFO -Message "ArgoCD namespace `"$vksNs`" is now available with all pods ready."

    } catch {
        Write-LogMessage -Type ERROR -Message "Failed to add ArgoCD instance: $_"
        throw "Deployment failed. Check logs for details."
    }
}

Function Show-ArgoCDInstanceDetails {

    <#
        .SYNOPSIS
        Displays ArgoCD instance connection details including login URL and initial admin password.

        .DESCRIPTION
        The Show-ArgoCDInstanceDetails function retrieves and displays the ArgoCD instance connection information
        for a deployed ArgoCD service. It fetches the load balancer IP address from the argocd-server service
        and retrieves the initial admin password from the Kubernetes secret. The function then displays login
        instructions and provides the command to update the admin password.

        This function is typically called after successfully deploying an ArgoCD instance to provide the user
        with the necessary information to access and configure the ArgoCD web interface.

        .PARAMETER ArgoCdNamespace
        The Kubernetes namespace where the ArgoCD instance is deployed. This parameter is mandatory and cannot
        be null or empty.

        .EXAMPLE
        Show-ArgoCDInstanceDetails -ArgoCdNamespace "vks-ns-12345"
        Displays the ArgoCD login URL and initial admin password for the instance in the specified namespace.

        .OUTPUTS
        None
        This function writes informational messages to the log but does not return any output.
    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ArgoCdNamespace
    )

    # Derive IP address from external load balancer for ArgoCD namespace.
    $svcJson = & $Script:KubectlCmd get svc argocd-server -n $ArgoCdNamespace -o json | ConvertFrom-Json
    $ipAddr = $svcJson.status.loadBalancer.ingress[0].ip
    if ($null -eq $ipAddr) {
        Write-LogMessage -Type ERROR -Message "Failed to retrieve IP address for ArgoCD server service in namespace `"$ArgoCdNamespace`"."
        throw "Deployment failed. Check logs for details."
    }

    # Retrieve initial admin password from Kubernetes secret.
    $encodedPassword = & $Script:KubectlCmd get secret -n $ArgoCdNamespace argocd-initial-admin-secret -o jsonpath='{.data.password}'
    if ($null -eq $encodedPassword) {
        Write-LogMessage -Type ERROR -Message "Failed to retrieve initial admin password for ArgoCD in namespace `"$ArgoCdNamespace`"."
        throw "Deployment failed. Check logs for details."
    }

    # Decode initial admin password from Base64 encoded string.
    $decodedPassword = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($encodedPassword))
    if ($null -eq $decodedPassword) {
        Write-LogMessage -Type ERROR -Message "Failed to decode initial admin password for ArgoCD in namespace `"$ArgoCdNamespace`"."
        throw "Deployment failed. Check logs for details."
    }

    # In order to ensure the user can login to ArgoCD, we need to display the login instructions to the user regardless of the log level threshold.
    Write-Host -ForegroundColor Green "`n[INFO]To login to ArgoCD:"
    Write-Host -ForegroundColor Green "[INFO] Go to https://${ipAddr}/"
    Write-Host -ForegroundColor Green "[INFO] Login as user `"admin`" using temporary password: $decodedPassword"
    Write-Host -ForegroundColor Green "[INFO] To update your password run: `"$Script:ArgocdCmd account update-password --server $ipAddr --account admin --insecure`""

    # Write output to log file, except for the decoded password which is only logged to the screen.
    Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "To login to ArgoCD:"
    Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "Go to https://${ipAddr}/"
    Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "To update your password run: `"$Script:ArgocdCmd account update-password --server $ipAddr --account admin --insecure`""

    # Cleanup credentials.
    Remove-Variable -Name decodedPassword -Force
    Remove-Variable -Name encodedPassword -Force
    [System.GC]::Collect()
    [System.GC]::WaitForPendingFinalizers()
}
Function Get-Base64FromYml {

    <#
        .SYNOPSIS
        Converts a YAML file to Base64 encoded string format for supervisor service deployment.

        .DESCRIPTION
        The Get-Base64FromYml function reads a YAML file and converts its content to a Base64 encoded string.
        This encoding is required when creating supervisor service content through the vSphere APIs, as the
        service specifications must be provided in Base64 format. The function reads the entire file content
        as raw text, converts it to UTF-8 bytes, and then encodes it using Base64 encoding.

        This function is typically used in the context of deploying supervisor services like ArgoCD, where
        the service configuration YAML needs to be embedded in API requests as Base64 encoded content.

        .PARAMETER Path
        The full path to the YAML file that needs to be converted to Base64 format. The file must exist
        and be readable. This parameter is mandatory and cannot be null or empty.

        .EXAMPLE
        Get-Base64FromYml -Path "C:\configs\argocd-service.yml"
        Converts the ArgoCD service YAML file to Base64 encoded string.

        .EXAMPLE
        $base64Content = Get-Base64FromYml -Path $argoCDyaml
        Stores the Base64 encoded content of the YAML file in a variable for later use in API calls.

        .OUTPUTS
        System.String
        Returns a Base64 encoded string representation of the YAML file content.

        .NOTES
        - The function reads the entire file content into memory, so it may not be suitable for very large files
        - The encoding uses UTF-8 character encoding before Base64 conversion
        - This function is commonly used with Set-ArgoCDService to deploy supervisor services
        - The returned Base64 string can be directly used in vSphere supervisor service API calls

        .LINK
        Set-ArgoCDService
    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Path
    )

    Write-LogMessage -Type DEBUG -Message "Entered Get-Base64FromYml function..."

    $raw = Get-Content -Path $Path -Raw
    $base64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($raw))

    return $base64
}
Function Set-ArgoCDService {

    <#
        .SYNOPSIS
        The function creates the ArgoCD service using yml file.

        .DESCRIPTION
        The function creates the ArgoCD service using yml file. It converts Yaml into
        base64 encoding format and creates a carvel spec and using API to create the service.

        .EXAMPLE
        Set-ArgoCDService -Path <.yml file path>

        .PARAMETER -Path
        Location of the yaml file.

    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Path
    )

    Write-LogMessage -Type DEBUG -Message "Entered Set-ArgoCDService function..."

    try {
        $base64Content = Get-Base64FromYml -Path $Path
        $argoServiceName, $argoServiceVersion = Get-ArgoCDServiceDetail -Path $Path
        $vcenterNamespaceManagementSupervisorServicesVersionsCarvelCreateSpec = Initialize-VcenterNamespaceManagementSupervisorServicesVersionsCarvelCreateSpec -Content $base64Content
        $vcenterNamespaceManagementSupervisorServicesCarvelCreateSpec = Initialize-VcenterNamespaceManagementSupervisorServicesCarvelCreateSpec -VersionSpec $vcenterNamespaceManagementSupervisorServicesVersionsCarvelCreateSpec
        $vcenterNamespaceManagementSupervisorServicesCheckContentRequest = Initialize-NamespaceManagementSupervisorServicesCreateSpec -CarvelSpec $vcenterNamespaceManagementSupervisorServicesCarvelCreateSpec
        Invoke-CreateNamespaceManagementSupervisorServices -vcenterNamespaceManagementSupervisorServicesCreateSpec $vcenterNamespaceManagementSupervisorServicesCheckContentRequest -Confirm:$false -ErrorAction:Stop | Out-Null
        Write-LogMessage  "Successfully created ArgoCD service `"$argoServiceName`" version `"$argoServiceVersion`" on vCenter `"$Script:VCenterName`"."
    } catch {
        $errMsg = $_.Exception.Message

        if ($errMsg -match "an instance of Supervisor Service with the same identifier already exists") {
            Write-LogMessage -Type WARNING -Message "ArgoCD service `"$argoServiceName`" version `"$argoServiceVersion`" already exists on vCenter `"$Script:VCenterName`"."
        }
        else {
            Write-LogMessage -TYPE "ERROR" -Message "ArgoCD service `"$argoServiceName`" version `"$argoServiceVersion`" on vCenter `"$Script:VCenterName`" creation failed: $_"
            throw "Deployment failed. Check logs for details."
        }
    }
}
Function Test-YamlPropertyConsistency {

    <#
        .SYNOPSIS
        Validates that specified property values in a YAML file match expected values using customizable validation logic.

        .DESCRIPTION
        The Test-YamlPropertyConsistency function provides a flexible framework for parsing YAML files and validating
        property values against expected criteria. It supports custom validation logic through scriptblocks, making it
        suitable for various validation scenarios including namespace consistency, version validation, configuration
        validation, and other property-based checks.

        The function uses the native PowerShell YAML parser to process multi-document YAML files and:
        - Handles YAML files that contain multiple documents separated by '---'
        - Searches for properties using customizable path specifications
        - Applies custom validation logic through scriptblock parameters
        - Provides detailed logging of validation results and any mismatches found
        - Returns boolean result indicating whether all validations passed
        - Supports complex nested property paths and multiple validation criteria

        This function serves as a general-purpose YAML validation framework that can be adapted for various
        deployment validation scenarios including Kubernetes manifests, configuration files, and service definitions.

        .PARAMETER YamlFilePath
        The full path to the YAML file to validate. This file should contain valid YAML content that needs
        to be validated against specified criteria.

        .PARAMETER PropertyPaths
        An array of property paths to search for in the YAML documents. Each path can be:
        - Simple property name (e.g., "namespace")
        - Nested property path using dot notation (e.g., "metadata.namespace")
        - Multiple paths for comprehensive validation
        Property paths are case-sensitive and follow standard PowerShell object property access patterns.

        .PARAMETER ExpectedValues
        An array of expected values corresponding to the property paths. The validation will check if found
        property values match these expected values. The array should have the same length as PropertyPaths,
        or provide a single value to validate against all properties.

        .PARAMETER ValidationScriptBlock
        Optional custom validation logic as a scriptblock. The scriptblock receives the following parameters:
        - $foundValue: The actual value found in the YAML
        - $expectedValue: The expected value for comparison
        - $propertyPath: The property path being validated
        - $documentIndex: The document number being processed
        The scriptblock should return $true for valid values, $false for invalid values.

        .PARAMETER ValidationName
        A descriptive name for the validation operation, used in logging messages to provide context
        about what type of validation is being performed (e.g., "namespace consistency", "version validation").

        .PARAMETER AllowMissingProperties
        Switch parameter that controls behavior when properties are not found. When specified, missing
        properties are treated as acceptable and logged as warnings rather than errors.

        .EXAMPLE
        Test-YamlPropertyConsistency -YamlFilePath "/path/to/deployment.yml" -PropertyPaths @("metadata.namespace") -ExpectedValues @("argocd") -ValidationName "namespace consistency"

        Validates that all metadata.namespace values in the YAML file match "argocd".

        .EXAMPLE
        $validationScript = {
            param($documentIndex, $expectedValue, $foundValue, $propertyPath)
            return $foundValue -eq $expectedValue -and $foundValue -match '^[a-z0-9-]+$'
        }
        Test-YamlPropertyConsistency -YamlFilePath $yamlPath -PropertyPaths @("metadata.namespace", "spec.namespace") -ExpectedValues @("production") -ValidationScriptBlock $validationScript -ValidationName "namespace format validation"

        Uses custom validation logic to check both value equality and format compliance.

        .EXAMPLE
        Test-YamlPropertyConsistency -YamlFilePath $configFile -PropertyPaths @("spec.version", "metadata.labels.version") -ExpectedValues @("1.0.0", "1.0.0") -ValidationName "version consistency" -AllowMissingProperties

        Validates version consistency across multiple properties, treating missing properties as acceptable.

        .OUTPUTS
        System.Boolean
        Returns $true if all property validations pass, $false if any validations fail or if the file cannot be processed.

        .NOTES
        Prerequisites:
        - Requires the YAML file to be accessible and contain valid YAML content
        - Uses native PowerShell YAML parsing (ConvertFrom-Yaml function must be available)
        - Handles both single and multi-document YAML files

        Behavior:
        - Processes each document in multi-document YAML files independently
        - Supports nested property access using dot notation (e.g., "metadata.namespace")
        - Provides detailed logging for each property found and validation result
        - Custom validation script blocks enable complex validation scenarios
        - Property path matching is case-sensitive

        Error Handling:
        - Returns $false if the YAML file cannot be read or parsed
        - Logs detailed error information for troubleshooting
        - Handles missing properties based on allowMissingProperties parameter
        - Comprehensive exception handling for file access and YAML parsing errors

        Performance:
        - Efficient single-pass processing of YAML documents
        - Minimal memory footprint for large YAML files
        - Optimized property path resolution using hashtable key access

        Integration:
        - Integrates with VCF PowerShell Toolbox logging infrastructure
        - Designed for use in automated deployment and validation scenarios
        - Compatible with existing YAML processing workflows in the codebase
    #>

    Param (
        [Parameter(Mandatory = $false)] [Switch]$AllowMissingProperties,
        [Parameter(Mandatory = $true)] [AllowEmptyString()] [String[]]$ExpectedValues,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String[]]$PropertyPaths,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ValidationName,
        [Parameter(Mandatory = $false)] [ScriptBlock]$ValidationScriptBlock = $null,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$YamlFilePath
    )

    Write-LogMessage -Type DEBUG -Message "Entered Test-YamlPropertyConsistency function..."

    try {
        # Validate that the YAML file exists.

        if (-not (Test-Path -Path $YamlFilePath -PathType Leaf)) {
            $currentDir = Get-Location
            # Detect if path is a Windows absolute path (starts with drive letter like C:\ or C:/)
            $isWindowsAbsolutePath = $YamlFilePath -match '^[A-Za-z]:[\\/]'
            # Detect if path is Unix absolute path (starts with /)
            $isUnixAbsolutePath = $YamlFilePath -match '^/'
            # Detect if path is absolute (either Windows or Unix style)
            $isAbsolutePath = $isWindowsAbsolutePath -or $isUnixAbsolutePath

            Write-LogMessage -Type ERROR -Message "YAML file not found for $ValidationName validation."
            Write-LogMessage -Type ERROR -Message "  Specified path: '$YamlFilePath'"

            if ($isWindowsAbsolutePath) {
                Write-LogMessage -Type ERROR -Message "  Note: The specified path is a Windows absolute path. On non-Windows systems, please update your configuration file (infrastructure.json) to use a relative path or a Unix-style absolute path."
            } elseif (-not $isAbsolutePath) {
                # Only show resolved path for relative paths.

                $resolvedPath = Join-Path $currentDir $YamlFilePath
                Write-LogMessage -Type ERROR -Message "  Resolved path: '$resolvedPath'"
            }

            Write-LogMessage -Type ERROR -Message "  Current working directory: '$currentDir'"
            Write-LogMessage -Type ERROR -Message "  Please verify the file path in your configuration file (infrastructure.json) and ensure the file exists."
            return $false
        }

        # Validate parameter consistency
        if ($ExpectedValues.Count -ne 1 -and $ExpectedValues.Count -ne $PropertyPaths.Count) {
            Write-LogMessage -Type ERROR -Message "Expected values count must be 1 (for all properties) or match property paths count. PropertyPaths: $($PropertyPaths.Count), ExpectedValues: $($ExpectedValues.Count)"
            return $false
        }

        Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "Starting $ValidationName validation for YAML file: '$YamlFilePath'"
        Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "Property paths to validate: $($PropertyPaths -join ', ')"
        Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "Expected values: $($ExpectedValues -join ', ')"

        $yamlContent = Get-Content -Raw -Path $YamlFilePath

        # Split multi-document YAML by --- separator.

        # Use regex to handle different line endings (Unix: \n, Windows: \r\n)
        $documents = $yamlContent -split '(?m)^---\s*$'

        $config = @()
        foreach ($docContent in $documents) {
            $docContent = $docContent.Trim()
            if ($docContent) {
                $doc = ConvertFrom-Yaml -YamlContent $docContent

                if ($doc -is [hashtable]) {
                    # YAML parser returned a hashtable directly.

                    $config += $doc
                } elseif ($doc.Count -gt 0 -and $null -ne $doc[0]) {
                    # YAML parser returned an array with hashtable.

                    $config += $doc[0]
                }
            }
        }

        $validationFailed = $false
        $documentsChecked = 0
        $propertiesFound = 0
        $validationResults = @()

        # Check each document for the specified properties.

        foreach ($doc in $config) {
            if ($null -eq $doc) { continue }
            $documentsChecked++

            for ($i = 0; $i -lt $PropertyPaths.Count; $i++) {
                $propertyPath = $PropertyPaths[$i]
                $expectedValue = if ($ExpectedValues.Count -eq 1) { $ExpectedValues[0] } else { $ExpectedValues[$i] }

                # Navigate to the property using dot notation.

                $foundValue = $null
                $propertyFound = $false
                $currentObject = $doc
                $pathParts = $propertyPath -split '\.'

                foreach ($part in $pathParts) {
                    if ($currentObject -is [hashtable] -and $currentObject.ContainsKey($part)) {
                        $currentObject = $currentObject[$part]
                        $propertyFound = $true
                    } else {
                        $propertyFound = $false
                        break
                    }
                }

                if ($propertyFound) {
                    $foundValue = $currentObject
                    $propertiesFound++

                    Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "Found property '$propertyPath' in document $documentsChecked with value: '$foundValue'"

                    # Apply validation logic
                    $isValid = $false
                    if ($null -ne $ValidationScriptBlock) {
                        # Use custom validation scriptblock.

                        try {
                            $isValid = & $ValidationScriptBlock -foundValue $foundValue -expectedValue $expectedValue -propertyPath $propertyPath -documentIndex $documentsChecked
                        } catch {
                            Write-LogMessage -Type ERROR -Message "Custom validation scriptblock failed for property '$propertyPath' in document $documentsChecked : $_"
                            $isValid = $false
                        }
                    } else {
                        # Use default equality validation.

                        $isValid = ($foundValue -eq $expectedValue)
                    }

                    if (-not $isValid) {
                        Write-LogMessage -Type ERROR -Message "$ValidationName validation failed in file `"$YamlFilePath`" for property `"$propertyPath`". Expected: `"$expectedValue`", Found: `"$foundValue`"."
                        $validationFailed = $true
                    } else {
                        Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "$ValidationName validation on YAML file `"$YamlFilePath`": for property `"$propertyPath`"."
                    }

                    $validationResults += @{
                        DocumentIndex = $documentsChecked
                        PropertyPath = $propertyPath
                        FoundValue = $foundValue
                        ExpectedValue = $expectedValue
                        IsValid = $isValid
                    }
                } else {
                    # Property not found
                    $message = "Property '$propertyPath' not found in document $documentsChecked"
                    if ($AllowMissingProperties) {
                        Write-LogMessage -Type WARNING -Message "$message - treating as acceptable due to allowMissingProperties flag"
                    } else {
                        Write-LogMessage -Type ERROR -Message "$message - this is considered a validation failure"
                        $validationFailed = $true
                    }

                    $validationResults += @{
                        DocumentIndex = $documentsChecked
                        PropertyPath = $propertyPath
                        FoundValue = $null
                        ExpectedValue = $expectedValue
                        IsValid = $AllowMissingProperties
                    }
                }
            }
        }

        Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "$ValidationName validation completed - Documents checked: $documentsChecked, Properties found: $propertiesFound"

        if ($propertiesFound -eq 0 -and -not $AllowMissingProperties) {
            Write-LogMessage -Type ERROR -Message "No properties matching the specified paths were found in the YAML file"
            return $false
        }

        if ($validationFailed) {
            Write-LogMessage -Type ERROR -Message "$ValidationName validation failed - One or more property values did not meet the validation criteria"
            return $false
        } else {
            Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "$ValidationName validation successful - All property values passed validation"
            return $true
        }

    } catch {
        Write-LogMessage -Type ERROR -Message "Failed to perform $ValidationName validation on YAML file '$YamlFilePath': $_"
        return $false
    }
}
Function Get-ArgoCDServiceDetail {

    <#
        .SYNOPSIS
        Extracts ArgoCD service name and version from a multi-document YAML package file.

        .DESCRIPTION
        The Get-ArgoCDServiceDetail function parses a multi-document YAML file (typically a Carvel package file)
        to extract the ArgoCD service reference name and version. The function handles YAML files that contain
        multiple documents separated by '---' and specifically looks for the Package document that contains
        the spec.refName and spec.version properties.

        The function uses a native PowerShell YAML parser to process the file and automatically handles:
        - Multi-document YAML files (documents separated by ---)
        - Package and PackageMetadata document types
        - Extraction of refName and version from the correct Package document
        - Error handling for malformed or missing YAML content

        This function is typically used during ArgoCD service deployment to identify the correct service
        name and version for supervisor service installation.

        .PARAMETER Path
        The full path to the YAML package file to parse. This file should contain Carvel package
        definitions with at least one Package document that includes spec.refName and spec.version properties.

        .EXAMPLE
        Get-ArgoCDServiceDetail -Path "/path/to/argocd-service.yml"

        Parses the specified YAML file and returns the ArgoCD service reference name and version.
        Returns: "argocd-service.vsphere.vmware.com", "1.0.0-24815986"

        .EXAMPLE
        $ServiceName, $serviceVersion = Get-ArgoCDServiceDetail -Path $argoCDyaml

        Extracts service details and assigns them to separate variables for use in service deployment.

        .OUTPUTS
        System.String[]
        Returns an array containing two strings:
        [0] - The service reference name (spec.refName)
        [1] - The service version (spec.version)

        .NOTES
        - Requires the YAML file to contain at least one Package document with spec.refName and spec.version
        - Uses native PowerShell YAML parsing (no external dependencies)
        - Handles both single and multi-document YAML files
        - Will exit with error code 1 if the required Package document is not found
        - The function specifically looks for Package documents, not PackageMetadata documents
    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Path
    )

    Write-LogMessage -Type DEBUG -Message "Entered Get-ArgoCDServiceDetail function..."

    try {
        $yamlContent = Get-Content -Raw -Path $Path

        # Split multi-document YAML by --- separator.

        # Use regex to handle different line endings (Unix: \n, Windows: \r\n)
        $documents = $yamlContent -split '(?m)^---\s*$'

        Write-LogMessage -Type DEBUG -Message "Split YAML into $($documents.Count) document(s)"

        $config = @()
        foreach ($docContent in $documents) {
            $docContent = $docContent.Trim()
            if ($docContent) {
                $doc = ConvertFrom-Yaml -YamlContent $docContent

                if ($doc -is [hashtable]) {
                    # YAML parser returned a hashtable directly.

                    $config += $doc
                    Write-LogMessage -Type DEBUG -Message "Parsed document as hashtable with keys: $($doc.Keys -join ', ')"
                } elseif ($doc.Count -gt 0 -and $null -ne $doc[0]) {
                    # YAML parser returned an array with hashtable.

                    $config += $doc[0]
                    Write-LogMessage -Type DEBUG -Message "Parsed document as array, extracted first element with keys: $($doc[0].Keys -join ', ')"
                }
            }
        }

        Write-LogMessage -Type DEBUG -Message "Total parsed YAML documents: $($config.Count)"
    } catch {
        Write-LogMessage -Type ERROR -Message "Failed to convert YAML file to JSON: $_"
        throw "Deployment failed. Check logs for details."
    }
    # Access properties from the parsed YAML documents.
    # Look for the first document that has a 'spec' with 'refName' and 'version' (Package document)
    $configHash = $null

    foreach ($doc in $config) {
        if ($null -ne $doc -and $doc.ContainsKey("spec")) {
            $spec = $doc["spec"]
            Write-LogMessage -Type DEBUG -Message "Examining document with spec keys: $($spec.Keys -join ', ')"
            # Check if this is a Package document (has refName and version)
            if ($spec.ContainsKey("refName") -and $spec.ContainsKey("version")) {
                $configHash = $doc
                Write-LogMessage -Type DEBUG -Message "Found Package document with refName: $($spec['refName']), version: $($spec['version'])"
                break
            }
        }
    }

    if ($null -ne $configHash -and $configHash.ContainsKey("spec")) {
        $spec = $configHash["spec"]
        $refName = if ($spec.ContainsKey("refName")) { $spec["refName"] } else { $null }
        $version = if ($spec.ContainsKey("version")) { $spec["version"] } else { $null }

        return $refName, $version
    } else {
        Write-LogMessage -Type ERROR -Message "Failed to find Package document with 'spec.refName' and 'spec.version' in YAML file. Available documents: $($config.Count)"
        if ($config.Count -gt 0) {
            foreach ($doc in $config) {
                $kind = if ($doc.ContainsKey("kind")) { $doc["kind"] } else { "Unknown" }
                $hasSpec = if ($doc.ContainsKey("spec")) { "Yes" } else { "No" }
                Write-LogMessage -Type ERROR -Message "  Document kind: $kind, has spec: $hasSpec"
                if ($doc.ContainsKey("spec")) {
                    $spec = $doc["spec"]
                    Write-LogMessage -Type ERROR -Message "    spec keys: $($spec.Keys -join ', ')"
                }
            }
        }
        throw "Deployment failed. Check logs for details."
    }
}
Function Get-ContentLibraryId {

    <#
        .SYNOPSIS
        Retrieves the unique identifier of a vSphere content library by name.

        .DESCRIPTION
        The Get-ContentLibraryId function searches for a content library on the specified vCenter
        by name and returns its unique identifier. This function queries all local content libraries
        available on the vCenter and performs a case-sensitive name match to locate the
        requested library.

        The function is commonly used in deployment scenarios where content library IDs are required
        for operations such as VM template deployment, supervisor cluster configuration, or other
        vSphere operations that reference content libraries by their unique identifiers.

        If the specified content library is not found, the function will exit the script with an
        error code to prevent subsequent operations from proceeding with invalid library references.

        .PARAMETER LibraryName
        The name of the content library for which to retrieve the unique identifier.
        This parameter is mandatory and performs a case-sensitive match against existing
        content library names on the vCenter.

        .EXAMPLE
        Get-ContentLibraryId -LibraryName "VCF-ContentLibrary"

        Retrieves the unique identifier for the content library named "VCF-ContentLibrary".

        .EXAMPLE
        $libraryId = Get-ContentLibraryId -LibraryName "Production-Templates"

        Stores the content library ID in a variable for use in subsequent operations.

        .EXAMPLE
        Get-ContentLibraryId -LibraryName $InputData.common.contentLibrary.libraryName

        Retrieves the content library ID using a name from configuration data.

        .OUTPUTS
        System.String
        Returns the unique identifier (ID) of the specified content library as a string.

        .NOTES
        - Requires an active PowerCLI connection to vCenter via the $Script:VCenterName variable
        - Uses Invoke-ListContentLocalLibrary and Invoke-GetLibraryIdContentLocalLibrary cmdlets
        - Performs case-sensitive name matching against content library names
        - Will terminate script execution (exit 1) if the library is not found or if errors occur
        - Only searches local content libraries, not subscribed libraries
        - The returned ID can be used with other vSphere APIs and PowerCLI cmdlets that require content library references

        .LINK
        New-LocalContentLibrary
        Invoke-ListContentLocalLibrary
        Invoke-GetLibraryIdContentLocalLibrary
    #>

    # Get the content library id from the content library name.
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$LibraryName
    )
    Write-LogMessage -Type DEBUG -Message "Entered Get-ContentLibraryId function..."

    # Verify vCenter connection before proceeding.
    $connectionTest = Test-VcenterConnection
    if (-not $connectionTest.IsConnected) {
        Write-LogMessage -Type ERROR -Message "Not connected to vCenter `"$Script:VCenterName`": $($connectionTest.ErrorMessage)"
        throw "Deployment failed. Check logs for details."
    }

    try {
        $contentList = Invoke-ListContentLocalLibrary -Server $Script:VCenterName
        foreach ($lib in $contentList) {
            $libDetails = Invoke-GetLibraryIdContentLocalLibrary -LibraryId $lib -Server $Script:VCenterName
            if ( $libDetails.Name -eq $LibraryName) {
                return $libDetails.Id
            }
        }
    } catch {
        Write-LogMessage  -TYPE "ERROR" -Message "Failed to create content library `"$LibraryName`" on `"$Script:VCenterName`": $_"
        throw "Deployment failed. Check logs for details."
    }
}
Function New-LocalContentLibrary {

    <#
        .SYNOPSIS
        Creates a new local content library on vCenter and returns its unique identifier.

        .DESCRIPTION
        The New-LocalContentLibrary function creates a new local content library in vCenter
        using the specified datastore for storage. A content library is a container for VM templates,
        ISO files, and other content that can be used for virtual machine deployment and management.

        This function performs the following operations:
        1. Retrieves the specified datastore object from vCenter
        2. Creates a new local content library with the provided name and description
        3. Associates the content library with the specified datastore for storage
        4. Returns the unique identifier of the newly created content library

        The function includes comprehensive error handling for authorization issues, network timeouts,
        and other potential failures during content library creation. All operations are logged using
        the Write-LogMessage system for audit trail and troubleshooting purposes.

        .PARAMETER DatastoreName
        The name of the datastore where the content library will store its content. This datastore
        must already exist and be accessible from the connected vCenter. The datastore will
        be used to store VM templates, ISO files, and other content library items.

        .PARAMETER LibraryName
        The name for the new content library. This name must be unique within the vCenter
        and should follow standard naming conventions. The name will be used to identify and
        manage the content library through the vSphere Client and API operations.

        .PARAMETER LibraryDescription
        A descriptive text that explains the purpose and contents of the content library. This
        description helps administrators understand the library's intended use and is displayed
        in the vSphere Client interface.

        .EXAMPLE
        New-LocalContentLibrary -DatastoreName "datastore1" -LibraryName "VCF-ContentLibrary" -LibraryDescription "Content library for VCF deployment templates"

        Creates a new local content library named "VCF-ContentLibrary" stored on "datastore1" with the specified description.

        .EXAMPLE
        $libraryId = New-LocalContentLibrary -DatastoreName "shared-storage" -LibraryName "Production-Templates" -LibraryDescription "Production VM templates and ISOs"

        Creates a content library and stores the returned library ID in a variable for later use.

        .EXAMPLE
        New-LocalContentLibrary -DatastoreName $DatastoreName -LibraryName $LibraryName -LibraryDescription $LibraryDescription

        Creates a content library using variables for dynamic deployment scenarios.

        .OUTPUTS
        System.String
        Returns the unique identifier (ID) of the newly created content library. This ID can be used
        for subsequent operations such as adding content items or configuring library permissions.

        .NOTES
        - Requires an active PowerCLI connection to vCenter via the $Script:VCenterName variable
        - The specified datastore must exist and be accessible from vCenter
        - The function will terminate script execution (exit 1) if content library creation fails
        - Uses comprehensive error handling for authorization, network timeout, and general failures
        - Integrates with the VCF PowerShell Toolbox logging infrastructure for consistent reporting
        - The returned library ID is obtained by calling Get-ContentLibraryId after successful creation
        - Content libraries created are local libraries (not subscribed libraries)
        - The function uses the VMware PowerCLI New-ContentLibrary cmdlet for library creation

        .LINK
        Get-ContentLibraryId
        New-ContentLibrary
    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$DatastoreName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$LibraryName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$LibraryDescription
    )

    Write-LogMessage -Type DEBUG -Message "Entered New-LocalContentLibrary function..."

    # Verify vCenter connection before proceeding.
    $connectionTest = Test-VcenterConnection
    if (-not $connectionTest.IsConnected) {
        Write-LogMessage -Type ERROR -Message "Not connected to vCenter `"$Script:VCenterName`": $($connectionTest.ErrorMessage)"
        throw "Deployment failed. Check logs for details."
    }

    # Check if the content library already exists and if so, return the id.
    $contentLibraryId = Get-ContentLibraryId -libraryName $LibraryName
    if ($contentLibraryId) {
        Write-LogMessage -Type WARNING -Message "Content library `"$LibraryName`" already exists on vCenter `"$Script:VCenterName`"."
        return $contentLibraryId
    }

    try {
        # Get Datastore object. Using the datastore name.
        $datastoreObject = Get-Datastore -Name $DatastoreName -Server $Script:VCenterName

        # Create local content library. Using the datastore object.
        New-ContentLibrary `
            -Name $LibraryName `
            -Datastore $datastoreObject `
            -Description $LibraryDescription `
            -Server $Script:VCenterName | Out-Null
    }
    catch [System.UnauthorizedAccessException] {
        Write-LogMessage -Type ERROR -Message "Cannot create content library `"$LibraryName`" (`"$LibraryDescription`") on vCenter `"$Script:VCenterName`" due to authorization issues: $_"
        throw "Deployment failed. Check logs for details."
    }
    catch [System.TimeoutException] {
        Write-LogMessage -Type ERROR -Message "Cannot create content library `"$LibraryName`" (`"$LibraryDescription`") on vCenter`"$Script:VCenterName`" due to network/timeout issues: $_"
        throw "Deployment failed. Check logs for details."
    }
    catch {
        Write-LogMessage -Type ERROR -Message "Failed to create content library `"$LibraryName`" (`"$LibraryDescription`") on vCenter`"$Script:VCenterName`": $_"
        throw "Deployment failed. Check logs for details."
    }
    Write-LogMessage -Type INFO -Message "Successfully created content library `"$LibraryName`" on vCenter `"$Script:VCenterName`"."
    $contentLibraryId = Get-ContentLibraryId -libraryName $LibraryName
    return $contentLibraryId
}

Function New-VCenterRestApiSession {

    <#
        .SYNOPSIS
        Creates an authenticated REST API session with vCenter.

        .DESCRIPTION
        Establishes a REST API session with vCenter using Basic authentication.
        This function handles credential encoding, session creation, and returns session
        headers that can be used for subsequent API calls.

        The function performs Basic authentication with Base64 encoding of credentials
        and creates a session token that can be reused for multiple API operations,
        reducing the need for repeated authentication.

        Based on vCenter REST API authentication patterns.

        .PARAMETER VcenterUser
        Username for vCenter authentication. Must have sufficient privileges
        to access the required API endpoints.

        .PARAMETER VcenterInsecurePassword
        Plain text password for the vCenter user account. This parameter accepts
        passwords in plain text format (security risk - see security warning).

        Security Warning: This parameter accepts passwords in plain text, which
        poses a security risk. The password is Base64 encoded but not encrypted.

        .PARAMETER InsecureTls
        Switch to bypass SSL certificate validation for vCenter connections.
        When specified, certificate validation is skipped.

        Security Warning: This introduces a security risk by disabling certificate
        validation, making connections vulnerable to man-in-the-middle attacks.
        Should only be used in development/lab environments.

        .OUTPUTS
        PSCustomObject with the following properties:
        • Success (Boolean): Indicates if session creation succeeded
        • SessionHeaders (Hashtable): Headers for API calls with session ID
        • SessionId (String): The session ID token
        • ErrorMessage (String): Error details if Success is $false

        .EXAMPLE
        $session = New-VCenterRestApiSession -VcenterUser "admin@vsphere.local" -VcenterInsecurePassword "password"
        if ($session.Success) {
            $response = Invoke-RestMethod -Uri "https://vcenter/api/endpoint" -Headers $session.SessionHeaders
        }

        .EXAMPLE
        $sessionParams = @{
            VcenterUser = $Script:VCenterUser
            VcenterInsecurePassword = $password
            InsecureTls = $true
        }
        $session = New-VCenterRestApiSession @sessionParams

        .NOTES
        API Endpoint: POST /rest/com/vmware/cis/session

        Authentication Method: Basic authentication with Base64 encoding

        Security Considerations:
        • Uses plain text password parameter (security vulnerability)
        • Credentials are Base64 encoded but not encrypted
        • SSL certificate validation can be bypassed
        • Session tokens should be protected and cleaned up after use

        Error Handling:
        • Returns structured object instead of throwing exceptions
        • Follows script-wide pattern of using return instead of throw
        • Detailed error logging for troubleshooting
    #>

    Param (
        [Parameter(Mandatory = $false)] [Switch]$InsecureTls,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$VcenterUser,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$VcenterInsecurePassword
    )

    Write-LogMessage -Type DEBUG -Message "Entered New-VCenterRestApiSession function..."

    try {
        Write-LogMessage -Type INFO -Message "  Creating REST API session with vCenter..."

        # Encode credentials for Basic authentication.
        $pair = "$VcenterUser`:$VcenterInsecurePassword"
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($pair)
        $encodedAuth = [Convert]::ToBase64String($bytes)
        $headers = @{ Authorization = "Basic $encodedAuth" }

        # Create session with vCenter REST API.
        $session = Invoke-RestMethod -Method POST `
            -Uri "https://$Script:VCenterName/rest/com/vmware/cis/session" `
            -Headers $headers `
            -SkipCertificateCheck:$InsecureTls `
            -ErrorAction Stop

        $sessionId = $session.value
        $authHeaders = @{ "vmware-api-session-id" = $sessionId }

        Write-LogMessage -Type INFO -Message "  REST API session created successfully"

        # Return success result with session information.
        return [PSCustomObject]@{
            Success = $true
            SessionHeaders = $authHeaders
            SessionId = $sessionId
            ErrorMessage = $null
        }
    }
    catch {
        $errorMessage = $_.Exception.Message
        Write-LogMessage -Type ERROR -Message "Failed to create REST API session: $errorMessage"

        # Return failure result.
        return [PSCustomObject]@{
            Success = $false
            SessionHeaders = $null
            SessionId = $null
            ErrorMessage = $errorMessage
        }
    }
}

Function Find-SupervisorByName {

    <#
        .SYNOPSIS
        Searches for a supervisor cluster by name using vCenter REST API.

        .DESCRIPTION
        Queries the vCenter namespace management API to find a supervisor cluster
        by its name. This function retrieves all supervisor summaries and searches
        for a match by name (case-sensitive).

        If the supervisor is found, returns the supervisor ID. If not found,
        returns $null (this is not considered an error - the supervisor may
        not have been created yet).

        Based on vCenter namespace management API patterns.

        .PARAMETER SupervisorName
        Name of the supervisor cluster to search for. Search is case-sensitive
        and must match exactly as it appears in vCenter.

        .PARAMETER SessionHeaders
        Hashtable containing authenticated session headers from New-VCenterRestApiSession.
        Must include "vmware-api-session-id" header.

        .PARAMETER InsecureTls
        Switch to bypass SSL certificate validation for vCenter API calls.

        .OUTPUTS
        PSCustomObject with the following properties:
        • Success (Boolean): Indicates if API query succeeded
        • SupervisorId (String): Supervisor cluster ID if found, $null if not found
        • Found (Boolean): $true if supervisor exists, $false if not found
        • ErrorMessage (String): Error details if Success is $false

        .EXAMPLE
        $result = Find-SupervisorByName -SupervisorName "prod-supervisor" -SessionHeaders $session.SessionHeaders
        if ($result.Success -and $result.Found) {
            Write-Host "Found supervisor: $($result.SupervisorId)"
        }

        .EXAMPLE
        $findParams = @{
            SupervisorName = $SupervisorName
            SessionHeaders = $session.SessionHeaders
            InsecureTls = $true
        }
        $result = Find-SupervisorByName @findParams

        .NOTES
        API Endpoint: GET /api/vcenter/namespace-management/supervisors/summaries

        Behavior:
        • Queries all supervisor summaries (may be slow with many supervisors)
        • Performs case-sensitive name matching
        • Returns $null for SupervisorId if not found (not an error condition)
        • Success=$true even if supervisor not found (query succeeded)

        Error Handling:
        • Returns structured object instead of throwing exceptions
        • API failures return Success=$false
        • Not found returns Success=$true, Found=$false
    #>

    Param (
        [Parameter(Mandatory = $false)] [Switch]$InsecureTls,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$SupervisorName,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Hashtable]$SessionHeaders
    )

    Write-LogMessage -Type DEBUG -Message "Entered Find-SupervisorByName function..."

    try {
        Write-LogMessage -Type INFO -Message "  Searching for supervisor `"$SupervisorName`"..."

        # Query supervisor summaries from vCenter API.
        $response = Invoke-RestMethod -Method GET `
            -Uri "https://$Script:VCenterName/api/vcenter/namespace-management/supervisors/summaries" `
            -Headers $SessionHeaders `
            -SkipCertificateCheck:$InsecureTls `
            -ErrorAction Stop

        # Find the supervisor by name (case-sensitive match).
        $supervisorInstance = $response.items | Where-Object { $_.info.name -eq $SupervisorName }

        if ($supervisorInstance) {
            $supervisorId = $supervisorInstance.supervisor.ToString()
            Write-LogMessage -Type INFO -Message "  Found supervisor `"$SupervisorName`" with ID: $supervisorId."

            # Return success with found supervisor.
            return [PSCustomObject]@{
                Success = $true
                SupervisorId = $supervisorId
                Found = $true
                ErrorMessage = $null
            }
        }
        else {
            Write-LogMessage -Type INFO -Message "  Supervisor `"$SupervisorName`" not found."

            # Return success but not found (not an error - may not be created yet).
            return [PSCustomObject]@{
                Success = $true
                SupervisorId = $null
                Found = $false
                ErrorMessage = $null
            }
        }
    }
    catch {
        $errorMessage = $_.Exception.Message
        Write-LogMessage -Type ERROR -Message "Failed to query supervisor summaries: $errorMessage"

        # Return failure result.
        return [PSCustomObject]@{
            Success = $false
            SupervisorId = $null
            Found = $false
            ErrorMessage = $errorMessage
        }
    }
}

Function Wait-SupervisorDiscoverable {

    <#
        .SYNOPSIS
        Waits for a supervisor cluster to become discoverable and reach READY status.

        .DESCRIPTION
        Polls the vCenter namespace management API until the supervisor cluster becomes
        available and reaches READY kubernetes_status. This function implements a
        configurable timeout and check interval pattern with progress tracking.

        The function continuously queries the supervisor status until either:
        • Supervisor reaches READY status (success)
        • Timeout is reached (failure)
        • Supervisor disappears during wait (failure)

        Based on polling patterns similar to Wait-SupervisorReady.

        .PARAMETER SupervisorName
        Name of the supervisor cluster to wait for. Used for status queries and logging.

        .PARAMETER SessionHeaders
        Hashtable containing authenticated session headers from New-VCenterRestApiSession.

        .PARAMETER TimeoutSeconds
        Maximum time to wait for supervisor to become ready, in seconds.
        Defaults to 3600 seconds (1 hour).

        .PARAMETER CheckInterval
        Interval between status checks, in seconds. Defaults to 15 seconds.
        Lower values provide more frequent updates but increase API load.

        .PARAMETER InsecureTls
        Switch to bypass SSL certificate validation for vCenter API calls.

        .OUTPUTS
        PSCustomObject with the following properties:
        • Success (Boolean): $true if supervisor reached READY status
        • SupervisorId (String): Supervisor ID if found, $null otherwise
        • ElapsedSeconds (Int): Total time waited
        • LastStatus (String): Last kubernetes_status observed
        • ErrorMessage (String): Error details if Success is $false

        .EXAMPLE
        $waitResult = Wait-SupervisorDiscoverable -SupervisorName "prod-supervisor" -SessionHeaders $session.SessionHeaders -TimeoutSeconds 600
        if ($waitResult.Success) {
            Write-Host "Supervisor ready after $($waitResult.ElapsedSeconds) seconds"
        }

        .EXAMPLE
        $waitParams = @{
            SupervisorName = $name
            SessionHeaders = $headers
            TimeoutSeconds = 1800
            CheckInterval = 30
            InsecureTls = $true
        }
        $result = Wait-SupervisorDiscoverable @waitParams

        .NOTES
        API Endpoint: GET /api/vcenter/namespace-management/supervisors/summaries

        Polling Pattern:
        • Checks status every CheckInterval seconds
        • Uses Write-Progress for visual feedback
        • Terminates on timeout or supervisor ready
        • Fails if supervisor disappears during wait

        Performance Considerations:
        • Network latency affects check responsiveness
        • Lower check intervals increase API call frequency
        • Consider timeout based on environment provisioning time

        Error Handling:
        • Returns structured object instead of throwing exceptions
        • Timeout is considered a failure (Success=$false)
        • Provides last known status for troubleshooting
    #>

    Param (
        [Parameter(Mandatory = $false)] [ValidateRange(1, [int]::MaxValue)] [Int]$TimeoutSeconds = 3600,
        [Parameter(Mandatory = $false)] [ValidateRange(1, [int]::MaxValue)] [Int]$CheckInterval = 15,
        [Parameter(Mandatory = $false)] [Switch]$InsecureTls,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$SupervisorName,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Hashtable]$SessionHeaders
    )

    Write-LogMessage -Type DEBUG -Message "Entered Wait-SupervisorDiscoverable function..."

    Write-LogMessage -Type INFO -Message "  Waiting for supervisor `"$SupervisorName`" to become ready (timeout: $TimeoutSeconds seconds)..."

    $elapsedTime = 0
    $lastStatus = "UNKNOWN"
    $supervisorId = $null

    do {
        try {
            # Query supervisor summaries to get current status.
            $response = Invoke-RestMethod -Method GET `
                -Uri "https://$Script:VCenterName/api/vcenter/namespace-management/supervisors/summaries" `
                -Headers $SessionHeaders `
                -SkipCertificateCheck:$InsecureTls `
                -ErrorAction Stop

            # Find the matching supervisor instance.
            $supervisorInstance = $response.items | Where-Object { $_.info.name -eq $SupervisorName }

            if (-not $supervisorInstance) {
                Write-LogMessage -Type ERROR -Message "  Supervisor `"$SupervisorName`" disappeared during wait"
                Write-Progress -Activity "Waiting for Supervisor `"$SupervisorName`"" -Status "Error: Supervisor disappeared" -Completed

                # Return failure - supervisor disappeared.
                return [PSCustomObject]@{
                    Success = $false
                    SupervisorId = $null
                    ElapsedSeconds = $elapsedTime
                    LastStatus = $lastStatus
                    ErrorMessage = "Supervisor disappeared during wait"
                }
            }

            # Get current status and supervisor ID.
            $lastStatus = $supervisorInstance.info.kubernetes_status
            $supervisorId = $supervisorInstance.supervisor.ToString()

            # Check if supervisor is ready.
            if ($lastStatus -eq "READY") {
                Write-Progress -Activity "Waiting for Supervisor `"$SupervisorName`"" -Status "Ready" -Completed
                Write-LogMessage -Type INFO -Message "  Supervisor `"$SupervisorName`" reached READY status after $elapsedTime seconds"

                # Return success.
                return [PSCustomObject]@{
                    Success = $true
                    SupervisorId = $supervisorId
                    ElapsedSeconds = $elapsedTime
                    LastStatus = $lastStatus
                    ErrorMessage = $null
                }
            }

            # Update progress with current status.
            $statusMessage = "Status: $lastStatus"
            $currentOperation = "Elapsed: $elapsedTime seconds"
            Write-Progress -Activity "Waiting for Supervisor `"$SupervisorName`"" -Status $statusMessage -CurrentOperation $currentOperation

            # Wait before next check.
            Start-Sleep $CheckInterval
            $elapsedTime += $CheckInterval
        }
        catch {
            $errorMessage = $_.Exception.Message
            Write-LogMessage -Type ERROR -Message "  Error during supervisor status check: $errorMessage"
            Write-Progress -Activity "Waiting for Supervisor `"$SupervisorName`"" -Status "Error" -Completed

            # Return failure.
            return [PSCustomObject]@{
                Success = $false
                SupervisorId = $null
                ElapsedSeconds = $elapsedTime
                LastStatus = $lastStatus
                ErrorMessage = $errorMessage
            }
        }
    } while ($elapsedTime -lt $TimeoutSeconds)

    # Timeout reached without supervisor becoming ready.
    Write-Progress -Activity "Waiting for Supervisor `"$SupervisorName`"" -Status "Timeout" -Completed
    Write-LogMessage -Type ERROR -Message "  Supervisor `"$SupervisorName`" did not become ready after $TimeoutSeconds seconds (last status: $lastStatus)"

    # Return failure - timeout.
    return [PSCustomObject]@{
        Success = $false
        SupervisorId = $supervisorId
        ElapsedSeconds = $elapsedTime
        LastStatus = $lastStatus
        ErrorMessage = "Timeout waiting for supervisor to become ready (last status: $lastStatus)"
    }
}
Function Get-SupervisorId {

    <#
        .SYNOPSIS
        Retrieves the unique identifier of a vSphere Supervisor cluster using vCenter REST API authentication.

        .DESCRIPTION
        The Get-SupervisorId function queries the vSphere Supervisor cluster infrastructure using vCenter
        REST APIs to retrieve the unique identifier of a specified supervisor cluster. This function performs
        direct REST API authentication and namespace management queries to locate supervisor clusters by name
        and return their corresponding identifiers.

        The function performs the following key operations:
        • Establishes REST API session with vCenter using Basic authentication
        • Queries the namespace management supervisors API endpoint for cluster summaries
        • Searches through supervisor instances to match the specified supervisor name
        • Waits for the supervisor instance to become available (READY status) with configurable timeout
        • Returns the unique supervisor identifier for use in subsequent Kubernetes operations
        • Provides comprehensive error handling for authentication and API communication failures

        This function is essential for vSphere with Tanzu operations as supervisor IDs are required for
        namespace creation, service installation, and other Kubernetes management tasks within the
        vSphere Supervisor cluster ecosystem. The function uses direct REST API calls rather than
        PowerCLI cmdlets for more granular control over authentication and error handling.

        Key features:
        - Direct vCenter REST API integration with session-based authentication
        - Comprehensive supervisor cluster discovery and identification
        - Configurable wait for supervisor readiness with progress indication
        - Basic authentication with Base64 encoding for vCenter access
        - Certificate validation bypass for development and lab environments
        - Detailed error logging with context-specific troubleshooting information
        - Integration with vSphere namespace management infrastructure
        - Optional silent mode to suppress informational log messages
        - Configurable timeout and check interval parameters for flexible operation

        Security considerations:
        - Uses Basic authentication with plain text password parameter (security risk)
        - Bypasses SSL certificate validation (SkipCertificateCheck)
        - Credentials are encoded but transmitted over potentially insecure connections
        - Session tokens are used for subsequent API calls to minimize credential exposure

        .PARAMETER Silence
        Optional switch parameter that suppresses informational log messages when the supervisor
        becomes ready. When specified, the function will only output error messages and not success
        messages. Useful for silent operations or when integrating with automated workflows where
        verbose output is not desired.

        .PARAMETER SupervisorName
        The name of the vSphere Supervisor cluster for which to retrieve the unique identifier.
        This should match the supervisor cluster name as configured in vCenter and must
        correspond to an existing, properly configured supervisor cluster. The name is case-sensitive
        and must match exactly as it appears in the vCenter inventory.

        .PARAMETER VcenterUser
        The username for vCenter authentication with sufficient privileges to access namespace
        management APIs. This user must have permissions to query supervisor cluster information and
        access the vCenter REST API endpoints. Typically requires administrator-level privileges or
        specific RBAC permissions for namespace management operations.

        .PARAMETER VcenterInsecurePassword
        The plain text password for the specified vCenter user account. This parameter presents a
        security risk as it accepts passwords in plain text format rather than SecureString objects.
        The password is used for Basic authentication with the vCenter REST API and should be
        protected appropriately in production environments.

        .PARAMETER TotalWaitTime
        Optional integer parameter specifying the maximum time to wait for the supervisor to become
        ready, in seconds. Defaults to 3600 seconds (1 hour) if not specified. The function will
        continuously check the supervisor status at the specified CheckInterval until either the
        supervisor becomes ready or this timeout is reached. Setting this to a lower value will
        cause the function to fail faster if the supervisor takes longer than expected to become ready.

        .PARAMETER CheckInterval
        Optional integer parameter specifying the interval between status checks, in seconds.
        Defaults to 15 seconds if not specified. The function will query the supervisor status
        every CheckInterval seconds during the wait period. Lower values provide more frequent
        updates but may increase API load, while higher values reduce API calls but provide
        less frequent status updates.

        .PARAMETER InsecureTls
        Optional switch parameter that bypasses SSL certificate validation for the vCenter connection.
        When specified, the function will not validate the SSL certificate of the vCenter.
        This is intended for use in development and lab environments where valid certificates
        may not be available, but it introduces a security risk and should not be used in
        production environments.

        .EXAMPLE
        Get-SupervisorId -SupervisorName "Production-Supervisor" -VcenterUser "administrator@vsphere.local" -VcenterInsecurePassword "VMware1!"

        Retrieves the unique identifier for the supervisor cluster named "Production-Supervisor" using
        administrator credentials. The function will authenticate with vCenter and return the supervisor ID
        if the cluster exists and is accessible.

        .EXAMPLE
        $supervisorId = Get-SupervisorId -supervisorName $Script:SupervisorName -VcenterUser $Script:VCenterUser -VcenterInsecurePassword $VCenterPasswordDecrypted

        Uses script-scoped variables to retrieve the supervisor ID, demonstrating integration with
        larger deployment workflows where credentials and names are managed centrally.

        .EXAMPLE
        if ($supervisorId = Get-SupervisorId -supervisorName "Test-Supervisor" -VcenterUser $VcenterUser -VcenterInsecurePassword $vcenterPass) {
            Write-Host "Found supervisor with ID: $supervisorId"
        }

        Demonstrates conditional supervisor ID retrieval with immediate usage, useful for validation
        scenarios where supervisor existence needs to be verified before proceeding with operations.

        .EXAMPLE
        $supervisorId = Get-SupervisorId -supervisorName "Test-Supervisor" -VcenterUser $VcenterUser -VcenterInsecurePassword $vcenterPass -silence

        Retrieves the supervisor ID in silent mode, suppressing informational log messages. The function
        will still display progress indicators and error messages, but won't log success messages when
        the supervisor becomes ready. Useful in automated workflows or when reducing log verbosity.

        .EXAMPLE
        $supervisorId = Get-SupervisorId -supervisorName "Production-Supervisor" -VcenterUser "admin@vsphere.local" -VcenterInsecurePassword "VMware1!" -totalWaitTime 7200 -checkInterval 30

        Retrieves the supervisor ID with custom timeout and check interval settings. This example waits
        up to 2 hours (7200 seconds) for the supervisor to become ready, checking status every 30 seconds
        instead of the default 15 seconds. Useful for environments where supervisors take longer to
        provision or when you want to reduce API call frequency.

        .EXAMPLE
        $supervisorId = Get-SupervisorId -supervisorName "Quick-Test" -VcenterUser $VcenterUser -VcenterInsecurePassword $vcenterPass -totalWaitTime 300 -checkInterval 5

        Uses a shorter timeout (5 minutes) and more frequent checks (every 5 seconds) for testing
        scenarios where you want faster feedback on supervisor readiness. This is useful for
        development environments or when you know the supervisor should be ready quickly.

        .OUTPUTS
        System.String
        Returns the unique identifier (ID) of the specified vSphere Supervisor cluster as a string.
        The ID format is typically "domain-c" followed by a numeric identifier (e.g., "domain-c123").
        This ID is used for subsequent vSphere with Tanzu operations including namespace management,
        service installation, and Kubernetes cluster operations.

        .NOTES
        Prerequisites:
        • vCenter must be accessible via HTTPS on the standard port (443)
        • Target supervisor cluster must exist and be properly configured
        • User account must have sufficient privileges for namespace management API access
        • Network connectivity must allow REST API communication with vCenter

        Security Warnings:
        • Function uses plain text password parameter (security vulnerability)
        • SSL certificate validation is bypassed (SkipCertificateCheck)
        • Credentials are transmitted using Basic authentication
        • Consider implementing SecureString parameters for production use
        • Ensure secure network communication (VPN, private networks) when possible

        API Endpoints Used:
        • POST /rest/com/vmware/cis/session - Session authentication
        • GET /api/vcenter/namespace-management/supervisors/summaries - Supervisor discovery

        Behavior:
        • Establishes new vCenter session for each function call
        • Searches all supervisor instances for name match (case-sensitive)
        • Waits for supervisor to reach READY status with progress indication (configurable intervals)
        • Configurable maximum wait time for supervisor readiness (default: 1 hour)
        • Returns supervisor ID immediately once supervisor reaches READY status
        • Terminates script execution (exit 1) if supervisor not found or errors occur
        • Provides detailed error logging for troubleshooting API communication issues
        • Shows simplified status updates during wait period via Write-Progress

        Error Handling:
        • Authentication failures: Invalid credentials or insufficient permissions
        • Network errors: Connection timeouts, SSL issues, or network connectivity problems
        • API errors: vCenter service unavailability or API endpoint changes
        • Not found scenarios: Supervisor name doesn't match any existing clusters
        • Timeout scenarios: Supervisor doesn't reach READY status within configured timeout period
        • General exceptions: Comprehensive error logging with context information

        Performance Considerations:
        • Creates new authentication session for each call (no session reuse)
        • Queries all supervisor summaries (may be slow with many supervisors)
        • Waits up to configurable timeout for supervisor readiness with configurable check intervals
        • Network latency affects overall function execution time
        • Consider caching supervisor IDs for repeated operations
        • Long execution times possible when waiting for supervisor provisioning
        • Check interval affects API call frequency and responsiveness

        .LINK
        Add-Supervisor
        Get-OrCreateSupervisor
        Add-ArgoCDNamespace
        Install-ArgoCDOperator
        Invoke-RestMethod
    #>

    Param (
        [Parameter(Mandatory = $false)] [ValidateRange(1, [int]::MaxValue)] [Int]$CheckInterval=15,
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [Switch]$InsecureTls,
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [Switch]$Silence,
        [Parameter(Mandatory = $false)] [ValidateRange(1, [int]::MaxValue)] [Int]$TotalWaitTime=3600,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$SupervisorName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$VcenterInsecurePassword,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$VcenterUser
    )

    Write-LogMessage -Type DEBUG -Message "Entered Get-SupervisorId function..."

    Write-LogMessage -Type INFO -Message "Retrieving supervisor ID for `"$SupervisorName`" on vCenter `"$Script:VCenterName`"..."

    # Initialize session variable for cleanup in finally block.
    $session = $null

    try {
        # ========================================================================
        # STEP 1: Validate Parameters.

        # ========================================================================
        if ($TotalWaitTime -le 0) {
            Write-LogMessage -Type ERROR -Message "totalWaitTime must be greater than 0, got: $TotalWaitTime"
            return $null
        }
        if ($CheckInterval -le 0) {
            Write-LogMessage -Type ERROR -Message "checkInterval must be greater than 0, got: $CheckInterval"
            return $null
        }
        if ($CheckInterval -ge $TotalWaitTime) {
            Write-LogMessage -Type ERROR -Message "checkInterval ($CheckInterval) must be less than totalWaitTime ($TotalWaitTime)"
            return $null
        }

        # ========================================================================
        # STEP 2: Create REST API Session.

        # ========================================================================
        Write-LogMessage -Type INFO -Message "[Step 1/3] Creating REST API session..."

        $sessionParams = @{
            VcenterUser = $VcenterUser
            VcenterInsecurePassword = $VcenterInsecurePassword
            InsecureTls = $InsecureTls
        }
        $session = New-VCenterRestApiSession @sessionParams

        if (-not $session.Success) {
            Write-LogMessage -Type ERROR -Message "Failed to create REST API session: $($session.ErrorMessage)"
            throw "Deployment failed. Check logs for details."
        }

        # ========================================================================
        # STEP 3: Search for Supervisor and Wait for Ready.

        # ========================================================================
        Write-LogMessage -Type INFO -Message "[Step 2/3] Searching for supervisor cluster..."

        $findParams = @{
            SupervisorName = $SupervisorName
            SessionHeaders = $session.SessionHeaders
            InsecureTls = $InsecureTls
        }
        $findResult = Find-SupervisorByName @findParams

        if (-not $findResult.Success) {
            Write-LogMessage -Type ERROR -Message "Failed to query supervisors: $($findResult.ErrorMessage)"
            throw "Deployment failed. Check logs for details."
        }

        # If supervisor not found, return null (may not be created yet).
        if (-not $findResult.Found) {
            Write-LogMessage -Type INFO -Message "Supervisor instance `"$SupervisorName`" not found on vCenter `"$Script:VCenterName`". Proceeding to create it."
            return $null
        }

        # Supervisor found - now wait for it to become ready.
        Write-LogMessage -Type INFO -Message "[Step 3/3] Waiting for supervisor to become ready..."

        $waitParams = @{
            SupervisorName = $SupervisorName
            SessionHeaders = $session.SessionHeaders
            TimeoutSeconds = $TotalWaitTime
            CheckInterval = $CheckInterval
            InsecureTls = $InsecureTls
        }
        $waitResult = Wait-SupervisorDiscoverable @waitParams

        if (-not $waitResult.Success) {
            Write-LogMessage -Type ERROR -Message "Supervisor did not become ready: $($waitResult.ErrorMessage)"
            throw "Deployment failed. Check logs for details."
        }

        # Supervisor is ready.
        if (-not $Silence) {
            Write-LogMessage -Type INFO -Message "Supervisor instance `"$SupervisorName`" reported status ready, after waiting for $($waitResult.ElapsedSeconds) seconds."
        }

        return $waitResult.SupervisorId

    } catch {
        Write-LogMessage -Type ERROR -Message "Unable to fetch supervisor ID for `"$SupervisorName`" on vCenter `"$Script:VCenterName`": $_"
        throw "Deployment failed. Check logs for details."
    } finally {
        # Cleanup the vCenter REST API session.
        if ($session -and $session.Success -and $session.SessionHeaders) {
            try {
                Invoke-RestMethod -Method DELETE `
                    -Uri "https://$Script:VCenterName/rest/com/vmware/cis/session" `
                    -Headers $session.SessionHeaders `
                    -SkipCertificateCheck:$InsecureTls `
                    -ErrorAction SilentlyContinue | Out-Null
            } catch {
                # Silently ignore cleanup errors.

            }
        }
    }
}
Function Get-StoragePolicyId {

    <#
        .SYNOPSIS
        Retrieves the unique identifier of a vSphere Storage Policy-Based Management (SPBM) storage policy.

        .DESCRIPTION
        The Get-StoragePolicyId function queries the vCenter to retrieve the unique identifier
        of a specified storage policy by name. This function is essential for supervisor cluster
        configuration and other vSphere operations that require storage policy references.

        The function uses the VMware PowerCLI Get-SpbmStoragePolicy cmdlet to locate the storage
        policy and extract its ID property. The returned ID can be used in subsequent operations
        such as supervisor cluster creation, VM deployment, or storage configuration tasks.

        This function includes comprehensive error handling and will terminate script execution
        if the specified storage policy cannot be found or if any errors occur during the lookup
        process. All operations are logged using the Write-LogMessage system for consistent
        error reporting and troubleshooting.

        .PARAMETER StoragePolicyName
        The name of the storage policy for which to retrieve the unique identifier. This parameter
        is mandatory and must match an existing storage policy name in the connected vCenter.
        Common examples include "vSAN Default Storage Policy", "VM Storage Policy - Thick Provision",
        or custom storage policies created for specific deployment requirements.

        .EXAMPLE
        Get-StoragePolicyId -StoragePolicyName "vSAN Default Storage Policy"

        Retrieves the unique identifier for the default vSAN storage policy.

        .EXAMPLE
        $policyId = Get-StoragePolicyId -StoragePolicyName "VM Storage Policy - Thick Provision"

        Stores the storage policy ID in a variable for use in subsequent operations.

        .EXAMPLE
        Get-StoragePolicyId -StoragePolicyName $InputData.common.storagePolicy.storagePolicyName

        Retrieves the storage policy ID using a policy name from configuration data.

        .OUTPUTS
        System.String
        Returns the unique identifier (GUID) of the specified storage policy as a string.

        .NOTES
        - Requires an active PowerCLI connection to vCenter via the $Script:VCenterName variable
        - Uses the Get-SpbmStoragePolicy cmdlet from VMware PowerCLI
        - Will terminate script execution (exit 1) if the storage policy is not found or any errors occur
        - The returned ID is typically used for supervisor cluster configuration and VM deployment operations
        - Storage policy names are case-sensitive and must match exactly as they appear in vCenter
        - This function is commonly used in conjunction with supervisor cluster creation and TKGS configuration
    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$StoragePolicyName
    )

    Write-LogMessage -Type DEBUG -Message "Entered Get-StoragePolicyId function..."

    # Verify vCenter connection before proceeding.
    $connectionTest = Test-VcenterConnection
    if (-not $connectionTest.IsConnected) {
        Write-LogMessage -Type ERROR -Message "Not connected to vCenter `"$Script:VCenterName`": $($connectionTest.ErrorMessage)"
        throw "Deployment failed. Check logs for details."
    }

    # Get storage policy id from the storage policy name.
    try {
        $policy = Get-SpbmStoragePolicy -Name $StoragePolicyName -Server $Script:VCenterName
        $storagePolicyId = $($policy.Id)
        return $storagePolicyId
    } catch {
        Write-LogMessage -Type "ERROR" -Message "Unable to fetch storage policy id `"$StoragePolicyName`" on `"$Script:VCenterName`": $_"
        throw "Deployment failed. Check logs for details."
    }
}
Function Get-OrCreateSupervisor {

    <#
        .SYNOPSIS
        Gets or creates a supervisor cluster and returns its ID.

        .DESCRIPTION
        This function retrieves the storage policy ID from the specified storage policy name, then checks
        if a supervisor with the given name already exists. If the supervisor exists, it returns the
        existing supervisor ID. If it doesn't exist, it creates a new supervisor using the provided
        JSON configuration and returns the new supervisor ID.

        The function uses script-level variables for vCenter connection details ($Script:VCenterName
        and $Script:VCenterUser) and requires the vCenter password to be passed as a parameter.

        The function supports optional TLS certificate validation bypass through the insecureTls parameter,
        which is passed through to both Get-SupervisorId and Add-Supervisor functions. When the insecureTls
        switch is not specified, TLS certificate validation is enforced (secure by default).

        .PARAMETER ClusterId
        The ID of the vSphere cluster where the supervisor should be created or verified to exist.
        Format example: "domain-c123" or similar vCenter managed object reference.

        .PARAMETER ClusterName
        The name of the vSphere cluster. This is used for logging and identification purposes
        when creating a supervisor. The cluster must exist and match the ClusterId.

        .PARAMETER InsecureTls
        Optional switch parameter that bypasses SSL certificate validation for vCenter connections.
        When specified, this flag is passed to both Get-SupervisorId and Add-Supervisor functions,
        allowing operations in development and lab environments where valid certificates may not be
        available. If not specified, TLS certificate validation is enforced (secure by default).
        This parameter should not be used in production environments.

        .PARAMETER StoragePolicyId
        The id of the storage policy. This policy will be used for the supervisor configuration.
        The storage policy must exist and be compatible with the target cluster infrastructure.

        .PARAMETER SupervisorJson
        The JSON configuration file path or content for supervisor creation. This configuration is used
        when creating a new supervisor and must contain all required supervisor specifications including
        vSphere zone, control plane configuration, network settings, and TKGS component specifications.

        .PARAMETER SupervisorName
        The name of the supervisor to check for existence or create if it doesn't exist. This name must
        follow vSphere supervisor naming conventions and should be unique within the vCenter environment.

        .PARAMETER VCenterPasswordDecrypted
        The decrypted password for vCenter authentication. Used to authenticate with vCenter when checking
        for existing supervisors and when creating new supervisors. This should be provided as a plain
        text string (decrypted from SecureString).

        .EXAMPLE
        Get-OrCreateSupervisor -StoragePolicyId "policy-123" -SupervisorName "supervisor-01" -VCenterPasswordDecrypted "VMware1!" -SupervisorJson $SupervisorJson -ClusterId "domain-c123" -ClusterName "Cluster-01"

        Checks if supervisor "supervisor-01" exists, creates it if it doesn't, and returns the supervisor ID.
        TLS certificate validation is enforced (secure mode).

        .EXAMPLE
        Get-OrCreateSupervisor -StoragePolicyId "policy-123" -SupervisorName "supervisor-01" -VCenterPasswordDecrypted "VMware1!" -SupervisorJson $SupervisorJson -ClusterId "domain-c123" -ClusterName "Cluster-01" -InsecureTls

        Checks if supervisor "supervisor-01" exists, creates it if it doesn't, and returns the supervisor ID.
        TLS certificate validation is bypassed for development/lab environments.

        .OUTPUTS
        System.String
        Returns the supervisor ID (either existing or newly created) as a string in the format "domain-cXXX".

        .NOTES
        Prerequisites:
        • Script-level variables $Script:VCenterName and $Script:VCenterUser must be set
        • vCenter must be accessible and credentials must be valid
        • Target cluster must exist and be properly configured
        • Storage policy must exist and be compatible with the cluster

        Security Considerations:
        • The insecureTls parameter should only be used in development/lab environments
        • Password is passed as plain text string (consider SecureString in production)
        • TLS certificate validation is enforced by default when insecureTls is not specified

        .LINK
        Get-SupervisorId
        Add-Supervisor
        Get-StoragePolicyId
    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterId,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterName,
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [Switch]$InsecureTls,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$StoragePolicyId,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$SupervisorJson,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$SupervisorName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$VCenterPasswordDecrypted
    )

    Write-LogMessage -Type DEBUG -Message "Entered Get-OrCreateSupervisor function..."

    # Check if supervisor already exists, if not create it.
    if ($InsecureTls) {
        if (-not (Get-SupervisorId -supervisorName $SupervisorName -VcenterUser $Script:VCenterUser -VcenterInsecurePassword $VCenterPasswordDecrypted -insecureTls)) {
            $supervisorId = Add-Supervisor -infrastructureJson $SupervisorJson -storagePolicyId $StoragePolicyId -clusterId $ClusterId -clusterName $ClusterName -supervisorName $SupervisorName -vCenterPasswordDecrypted $VCenterPasswordDecrypted -insecureTls
        } else {
            $supervisorId = Get-SupervisorId -supervisorName $SupervisorName -VcenterUser $Script:VCenterUser -VcenterInsecurePassword $VCenterPasswordDecrypted -silence -insecureTls
        }
    } else {
        if (-not (Get-SupervisorId -supervisorName $SupervisorName -VcenterUser $Script:VCenterUser -VcenterInsecurePassword $VCenterPasswordDecrypted)) {
            $supervisorId = Add-Supervisor -infrastructureJson $SupervisorJson -storagePolicyId $StoragePolicyId -clusterId $ClusterId -clusterName $ClusterName -supervisorName $SupervisorName -vCenterPasswordDecrypted $VCenterPasswordDecrypted
        } else {
            $supervisorId = Get-SupervisorId -supervisorName $SupervisorName -VcenterUser $Script:VCenterUser -VcenterInsecurePassword $VCenterPasswordDecrypted -silence
        }
    }

    return $supervisorId
}
Function Add-ArgoCDNamespace {

    <#
        .SYNOPSIS
        Creates and configures a vSphere Supervisor namespace specifically optimized for ArgoCD deployment and management.

        .DESCRIPTION
        The Add-ArgoCDNamespace function creates a dedicated vSphere Supervisor namespace designed specifically for
        ArgoCD deployment within a Tanzu Kubernetes Grid Service (TKGS) environment. This function handles the complete
        namespace provisioning lifecycle including resource allocation, storage configuration, and VM service setup.

        The function performs the following comprehensive operations:
        1. Validates that the specified namespace doesn't already exist to prevent conflicts
        2. Creates a new Supervisor namespace on the specified supervisor cluster using vCenter APIs
        3. Configures unlimited storage specifications with the specified storage policy for ArgoCD persistence
        4. Sets up VM service specifications linking VM classes for workload deployment
        5. Applies complete namespace configuration to enable ArgoCD operator and instance deployment
        6. Implements proper initialization delays to ensure stable namespace provisioning

        Key configuration details:
        - Storage Policy: Applied to all persistent volumes created within the namespace
        - VM Classes: Define compute resource specifications (CPU, memory) for ArgoCD pods
        - Storage Limit: Set to unlimited (0) to prevent resource constraints during ArgoCD operations
        - Namespace Isolation: Provides dedicated environment for ArgoCD resources and configurations

        This function integrates with vSphere with Tanzu infrastructure and serves as a foundational step
        for ArgoCD deployment, ensuring proper resource allocation and configuration for GitOps workflows.

        .PARAMETER SupervisorId
        The unique identifier of the vSphere Supervisor cluster where the namespace will be created.
        This ID is typically obtained from the Get-SupervisorId function or supervisor creation process.
        The supervisor cluster must be in a ready state and properly configured for namespace creation.
        Format example: "domain-c123" or similar vCenter managed object reference.

        .PARAMETER ArgoCdNamespace
        The name for the ArgoCD namespace to be created. This name must follow Kubernetes namespace
        naming conventions (lowercase alphanumeric characters and hyphens only, maximum 63 characters).
        The namespace provides resource isolation and serves as the deployment target for ArgoCD
        operator and instance resources. Common examples: "argocd", "argocd-prod", "gitops-system".

        .PARAMETER StoragePolicyId
        The unique identifier of the vSphere storage policy to be applied to the namespace.
        This policy defines storage characteristics including performance tier, availability requirements,
        and placement rules for all persistent volumes created within the ArgoCD namespace.
        The storage policy must exist and be compatible with the target datastore infrastructure.

        .PARAMETER VmClasses
        Array of VM class names that define compute resource specifications (CPU cores, memory allocation,
        storage capacity) for virtual machines and pods running within the ArgoCD namespace.
        VM classes control resource allocation and performance characteristics for ArgoCD workloads.
        VM class names must conform to RFC1123 naming conventions (lowercase alphanumeric with hyphens, max 80 chars).
        The API validates that each VM class exists in vCenter inventory during namespace configuration.
        Common examples: "best-effort-small", "guaranteed-medium", "best-effort-2xlarge".
        Supports both single string and array input formats.

        .EXAMPLE
        Add-ArgoCDNamespace -SupervisorId "domain-c123" -ArgoCdNamespace "argocd" -StoragePolicyId "policy-456" -VmClasses @("best-effort-medium")

        Creates an ArgoCD namespace named "argocd" on supervisor cluster "domain-c123" with a single VM class.
        Uses storage policy "policy-456" for persistent volumes.

        .EXAMPLE
        Add-ArgoCDNamespace -SupervisorId $SupervisorId -ArgoCdNamespace "argocd-production" -StoragePolicyId $StoragePolicyId -VmClasses @("guaranteed-large", "best-effort-2xlarge")

        Creates a production ArgoCD namespace with multiple VM classes to support different workload types.
        The namespace can deploy pods using either guaranteed or best-effort resource allocation.

        .EXAMPLE
        $namespaceParams = @{
            SupervisorId = Get-SupervisorId -SupervisorName $SupervisorName
            ArgoCdNamespace = $InputData.common.argoCD.nameSpace
            StoragePolicyId = Get-StoragePolicyId -StoragePolicyName $InputData.common.storagePolicy.storagePolicyName
            VmClasses = $InputData.common.argoCD.vmClass
        }
        Add-ArgoCDNamespace @namespaceParams

        Creates ArgoCD namespace using parameter splatting with dynamic ID resolution from configuration data.
        This approach enables flexible deployment scenarios with centralized configuration management.

        .OUTPUTS
        None
        This function creates namespace infrastructure and logs status messages but does not return objects.
        Success is indicated by informational log messages and absence of script termination.

        .NOTES
        Prerequisites:
        - Active vCenter connection with Supervisor Services administration privileges
        - Target supervisor cluster must be in ready/running state with proper Tanzu configuration
        - Specified storage policy must exist and be compatible with the target infrastructure
        - VM classes must exist in vCenter inventory and be available for assignment
        - VM class names must conform to RFC1123 naming conventions (validated in JSON validation phase)
        - Sufficient cluster resources (CPU, memory, storage) to accommodate the namespace requirements

        Behavior:
        - Function returns early with warning message if namespace already exists (idempotent operation)
        - Uses unlimited storage allocation (limit = 0) to prevent ArgoCD operational constraints
        - Implements 5-second initialization delays after namespace creation and configuration for stability
        - Passes VM classes as array to API (List<string>) for individual class validation
        - Exits script with code 1 on any critical errors to prevent incomplete deployments
        - Creates namespace with both storage specifications and VM service configurations in single operation
        - Automatically deletes namespace if VM class configuration fails to maintain clean state

        Error Handling:
        - Comprehensive error handling for namespace creation, storage configuration, and VM service setup
        - Extracts clean error messages from API JSON responses for user-friendly output
        - Automatic namespace cleanup on VM class configuration failure prevents orphaned resources
        - Detailed error logging with specific failure context including which VM class is invalid
        - Script termination on critical errors prevents proceeding with invalid namespace configuration
        - Graceful handling of duplicate namespace scenarios with informational logging

        Performance:
        - Efficient single-pass namespace creation with complete configuration application
        - Minimal API calls through batched configuration operations
        - Built-in delays ensure proper resource initialization before function completion
        - Optimized for large-scale deployment scenarios with reliable namespace provisioning

        Integration:
        - Integrates with VCF PowerShell Toolbox logging infrastructure for consistent audit trails
        - Compatible with vSphere with Tanzu namespace management workflows
        - Designed for use in automated ArgoCD deployment pipelines and configuration management
        - Supports both interactive and scripted deployment scenarios with comprehensive logging

        Security:
        - Namespace isolation provides security boundary for ArgoCD resources and configurations
        - Storage policy enforcement ensures data protection and compliance requirements
        - VM class restrictions prevent resource abuse and maintain cluster stability
        - Integration with vSphere RBAC for proper access control and authorization

        .LINK
        Get-SupervisorId
        Get-StoragePolicyId
        Install-ArgoCDOperator
        Add-ArgoCDInstance

    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ArgoCdNamespace,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$StoragePolicyId,

        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$SupervisorId,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [Array]$VmClasses
    )
    Write-LogMessage -Type DEBUG -Message "Entered Add-ArgoCDNamespace function..."

    try {
        if ((Invoke-ListNamespacesInstances).Namespace -contains $ArgoCdNamespace) {
            Write-LogMessage -Type WARNING -Message "The ArgoCD namespace `"$ArgoCdNamespace`" has already been created on vCenter `"$Script:VCenterName`"."
            return
        }

        # Create the namespace on the supervisor.

        Write-LogMessage -Type DEBUG -Message "Creating namespace '$ArgoCdNamespace' on supervisor '$SupervisorId'..."
        try {
            $vcenterNamespacesInstancesCreateSpecV2 = Initialize-VcenterNamespacesInstancesCreateSpecV2 -supervisor $SupervisorId -Namespace $ArgoCdNamespace
            Invoke-CreateNamespacesInstancesV2 -VcenterNamespacesInstancesCreateSpecV2 $vcenterNamespacesInstancesCreateSpecV2 -Confirm:$false -ErrorAction Stop | Out-Null
            Write-LogMessage -Type DEBUG -Message "Namespace creation initiated successfully"
        }
        catch {
            # Extract clean error message from API response.

            $errorMessage = $_.Exception.Message

            # Try to extract error details from JSON error response.

            if ($errorMessage -match '"error_type":"([^"]+)"') {
                $errorType = $matches[1]
                Write-LogMessage -Type ERROR -Message "Failed to create namespace '$ArgoCdNamespace': Error type: $errorType"
            }
            else {
                Write-LogMessage -Type ERROR -Message "Failed to create namespace '$ArgoCdNamespace'"
            }

            # Extract clean error message from JSON error response.
            $cleanMessage = Get-CleanErrorMessage -ErrorMessage $errorMessage
            Write-LogMessage -Type ERROR -Message "Reason: $cleanMessage"

            Write-LogMessage -Type ERROR -Message "Supervisor ID: $SupervisorId"
            Write-LogMessage -Type ERROR -Message "Namespace: $ArgoCdNamespace"

            # Provide helpful context based on error type.

            if ($errorMessage -match 'NOT_ALLOWED_IN_CURRENT_STATE') {
                Write-LogMessage -Type ERROR -Message ""
                Write-LogMessage -Type ERROR -Message "TROUBLESHOOTING: The supervisor cluster is not in a valid state for namespace creation."
                Write-LogMessage -Type ERROR -Message "Possible causes:"
                Write-LogMessage -Type ERROR -Message "  - Workloads are being enabled or disabled on the supervisor"
                Write-LogMessage -Type ERROR -Message "  - Supervisor is in a transitional state"
                Write-LogMessage -Type ERROR -Message "  - Another operation is in progress"
                Write-LogMessage -Type ERROR -Message "Resolution: Wait for the supervisor to reach a stable state and retry."
            }

            throw "Deployment failed. Check logs for details."
        }
        Start-Sleep 5

        # Set the storage limit to unlimited (by not specifying -Limit parameter)
        Write-LogMessage -Type DEBUG -Message "Initializing storage specification with policy ID: $StoragePolicyId"
        $vcenterNamespacesInstancesStorageSpec = Initialize-VcenterNamespacesInstancesStorageSpec -Policy $StoragePolicyId -ErrorAction Stop
        Write-LogMessage -Type DEBUG -Message "Storage specification initialized successfully"

        # Pass VM classes as array (API expects List<string>, not comma-separated string)
        Write-LogMessage -Type INFO -Message "Configuring VM classes: $($VmClasses -join ', ')"
        Write-LogMessage -Type DEBUG -Message "VM classes count: $($VmClasses.Count)"
        Write-LogMessage -Type DEBUG -Message "VM classes array: $($VmClasses | ForEach-Object { "'$_'" } | Join-String -Separator ', ')"

        # Initialize the VM service specification (without content library)
        Write-LogMessage -Type DEBUG -Message "Attempting to initialize VM service specification with VM classes..."
        try {
            $vcenterNamespacesInstancesVMServiceSpec = Initialize-VcenterNamespacesInstancesVMServiceSpec -VmClasses $VmClasses -ErrorAction Stop
            Write-LogMessage -Type DEBUG -Message "VM service specification initialized successfully"
        }
        catch {
            Write-LogMessage -Type ERROR -Message "Failed to initialize VM service specification"
            Write-LogMessage -Type ERROR -Message "Error details: $($_.Exception.Message)"
            Write-LogMessage -Type ERROR -Message "VM classes attempted: $($VmClasses -join ', ')"
            throw "Deployment failed. Check logs for details."
        }

        # Initialize the namespace set specification (with storage and VM service specifications)
        Write-LogMessage -Type DEBUG -Message "Initializing namespace set specification..."
        try {
            $vcenterNamespacesInstancesSetSpec = Initialize-NamespacesInstancesSetSpec -StorageSpecs $vcenterNamespacesInstancesStorageSpec -VmServiceSpec $vcenterNamespacesInstancesVMServiceSpec -ErrorAction Stop
            Write-LogMessage -Type DEBUG -Message "Namespace set specification initialized successfully"
        }
        catch {
            Write-LogMessage -Type ERROR -Message "Failed to initialize namespace set specification"
            Write-LogMessage -Type ERROR -Message "Error details: $($_.Exception.Message)"
            throw "Deployment failed. Check logs for details."
        }

        # Apply the namespace configuration (this is where VM classes are actually assigned)
        Write-LogMessage -Type DEBUG -Message "Applying namespace configuration to '$argocdNameSpace'..."
        Write-LogMessage -Type DEBUG -Message "This step assigns VM classes: $($VmClasses -join ', ')"
        try {
            Invoke-SetNamespaceInstances -Namespace $argocdNameSpace -VcenterNamespacesInstancesSetSpec $vcenterNamespacesInstancesSetSpec -Confirm:$false -ErrorAction Stop | Out-Null
            Write-LogMessage -Type DEBUG -Message "Namespace configuration applied successfully"
        }
        catch {
            # Extract clean error message from API response.
            $errorMessage = $_.Exception.Message

            # Extract clean error message from JSON error response.
            $cleanMessage = Get-CleanErrorMessage -ErrorMessage $errorMessage
            Write-LogMessage -Type ERROR -Message "Failed to apply namespace configuration: $cleanMessage"

            Write-LogMessage -Type ERROR -Message "VM classes attempted: $($VmClasses -join ', ')"
            Write-LogMessage -Type ERROR -Message "Namespace: $argocdNameSpace"

            # Clean up: Delete the namespace since configuration failed.

            Write-LogMessage -Type INFO -Message "Cleaning up: Deleting namespace '$argocdNameSpace' due to configuration failure..."
            try {
                Invoke-DeleteNamespaceInstances -Namespace $argocdNameSpace -Confirm:$false -ErrorAction Stop | Out-Null
                Write-LogMessage -Type INFO -Message "Namespace '$argocdNameSpace' deleted successfully."
            }
            catch {
                Write-LogMessage -Type WARNING -Message "Failed to delete namespace '$argocdNameSpace': $($_.Exception.Message)"
                Write-LogMessage -Type WARNING -Message "You may need to manually delete the namespace."
            }

            throw "Deployment failed. Check logs for details."
        }

        Start-Sleep 5
        Write-LogMessage -Type INFO -Message "The ArgoCD namespace `"$ArgoCdNamespace`" was created successfully."
        Write-LogMessage -Type INFO -Message "VM classes assigned: $($VmClasses -join ', ')"
    } catch {
        Write-LogMessage -Type "ERROR" -Message "The namespace could not be created: $_"
        throw "Deployment failed. Check logs for details."
    }
}
Function Install-ArgoCDOperator {

    <#
        .SYNOPSIS
        Installs and configures the ArgoCD operator as a supervisor service on a vSphere Supervisor cluster.

        .DESCRIPTION
        The Install-ArgoCDOperator function deploys the ArgoCD operator as a supervisor service on a specified
        vSphere Supervisor cluster using the vCenter namespace management APIs. This function handles the complete
        installation lifecycle including service creation, configuration monitoring, and error handling for various
        deployment scenarios.

        The function performs the following key operations:
        • Creates a supervisor service specification for the ArgoCD operator with specified version
        • Deploys the ArgoCD operator service to the target supervisor cluster
        • Monitors the configuration status with real-time progress tracking and timeout handling
        • Handles duplicate service scenarios gracefully with appropriate warnings
        • Provides comprehensive error handling for compatibility, cluster state, and general deployment issues
        • Implements intelligent retry logic with configurable timeout (300 seconds default)

        This function is designed to work within the vSphere with Tanzu ecosystem and serves as a prerequisite
        for ArgoCD instance deployment. The operator manages ArgoCD custom resources and provides the foundation
        for GitOps workflows in Kubernetes environments running on vSphere Supervisor clusters.

        Key features:
        - Automated supervisor service creation using vCenter namespace management APIs
        - Real-time configuration status monitoring with progress indicators
        - Intelligent duplicate service detection and handling
        - Comprehensive error handling for compatibility and cluster state issues
        - Configurable timeout with 30-second polling intervals
        - Integration with vSphere Supervisor cluster infrastructure
        - Support for version-specific ArgoCD operator deployments

        .PARAMETER ClusterId
        The vCenter cluster MoRef identifier (e.g., "domain-c462") where the supervisor is enabled.
        This is used to dynamically construct the service namespace for error messages and diagnostics.
        The cluster ID is obtained from Get-ClusterId.

        .PARAMETER SupervisorId
        The unique identifier of the vSphere Supervisor cluster where the ArgoCD operator will be installed.
        This should be the supervisor cluster ID obtained from supervisor creation or discovery operations.
        The supervisor cluster must be in a running state and have the necessary prerequisites configured
        including storage policies, content libraries, and network configurations. This is used for the
        actual API call to create the supervisor service.

        .PARAMETER Service
        The service identifier (reference name) for the ArgoCD operator supervisor service. This is typically
        extracted from the ArgoCD service YAML package file and identifies the specific service to be deployed.
        The service identifier must match the spec.refName from the ArgoCD service package definition and
        should follow the format "argocd-service.vsphere.vmware.com" or similar naming convention.

        .PARAMETER Version
        The version of the ArgoCD operator service to install. This should match the spec.version from the
        ArgoCD service package definition and determines the specific operator version and capabilities.
        Version format typically follows semantic versioning with build identifiers (e.g., "1.0.0-24815986").
        The version must be compatible with the supervisor cluster version and capabilities.

        .EXAMPLE
        Install-ArgoCDOperator -ClusterId "domain-c462" -SupervisorId "domain-s123" -Service "argocd-service.vsphere.vmware.com" -Version "1.0.0-24815986"

        Installs the ArgoCD operator version 1.0.0-24815986 on supervisor cluster "domain-s123" using the
        standard ArgoCD service identifier. The function will monitor the installation progress and report
        success or failure with detailed status information.

        .EXAMPLE
        $argoServiceName, $argoServiceVersion = Get-ArgoCDServiceDetail -Path $argoCDyaml
        Install-ArgoCDOperator -clusterId $ClusterId -supervisorId $SupervisorId -service $argoServiceName -version $argoServiceVersion

        Installs the ArgoCD operator using service details extracted from a YAML package file, demonstrating
        integration with service discovery functions for dynamic deployment scenarios.

        .EXAMPLE
        Install-ArgoCDOperator -clusterId $ClusterId -supervisorId $SupervisorId -service $ServiceName -version $ServiceVersion
        # Function will handle existing service gracefully and monitor configuration status.


        Shows the function's ability to handle existing services and provide appropriate feedback for
        various deployment states including already configured services.

        .OUTPUTS
        None
        This function does not return objects but performs supervisor service installation with side effects.
        Success is indicated by the absence of exceptions and successful configuration status messages.
        All operations are logged for audit trail and troubleshooting purposes.

        .NOTES
        Prerequisites:
        • Active vCenter connection with administrative privileges for supervisor service management
        • Target supervisor cluster must be in running state with proper configuration
        • ArgoCD service package must be available and properly configured
        • Supervisor cluster must meet minimum version requirements (9.0.0.0-0100-24847555 or higher)
        • Sufficient resources and network connectivity for ArgoCD operator deployment

        Behavior:
        • Monitors configuration status with 30-second polling intervals
        • Implements 300-second (5-minute) timeout for configuration completion
        • Handles existing services with warning messages rather than errors
        • Provides detailed error messages for troubleshooting deployment issues
        • Terminates script execution (exit 1) on critical failures

        Configuration States:
        • CONFIGURING: Service is being configured (monitored with progress updates)
        • CONFIGURED: Service successfully installed and ready for use
        • ERROR: Service configuration failed with detailed error messages

        Error Handling:
        • Compatibility errors: Provides specific supervisor version upgrade guidance
        • Cluster state errors: Indicates supervisor cluster is not running with remediation steps
        • Duplicate service errors: Graceful handling with configuration status verification
        • Timeout errors: Clear indication of configuration timeout with troubleshooting guidance
        • General errors: Comprehensive error logging with exception details

        Performance Considerations:
        • Initial 30-second delay after service creation for proper initialization
        • 30-second polling intervals balance responsiveness with system load
        • 300-second timeout provides sufficient time for most deployment scenarios
        • Configuration monitoring continues until success, failure, or timeout

        Integration:
        • Works with vSphere with Tanzu supervisor clusters
        • Integrates with ArgoCD service package management
        • Supports GitOps workflow preparation and ArgoCD instance deployment
        • Compatible with vCenter namespace management infrastructure

        .LINK
        Set-ArgoCDService
        Get-ArgoCDServiceDetail
        Add-ArgoCDNamespace
        Add-ArgoCDInstance
        Initialize-VcenterNamespaceManagementSupervisorsSupervisorServicesCreateSpec
        Invoke-VcenterNamespaceManagementSupervisorsSupervisorServicesCreate
    #>

    Param (
        [Parameter(Mandatory = $false)] [ValidateRange(1, [int]::MaxValue)] [Int]$CheckInterval = 5,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterId,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Service,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$SupervisorId,
        [Parameter(Mandatory = $false)] [ValidateRange(1, [int]::MaxValue)] [Int]$TotalWaitTime = 300,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Version
    )

    Write-LogMessage -Type DEBUG -Message "Entered Install-ArgoCDOperator function..."

    # Construct the service namespace (format: svc-<service-slug>-<cluster-id>).
    # The service slug is derived from the service name by removing the domain suffix.
    # The cluster ID (e.g., domain-c462) is used, NOT the supervisor UUID.
    $serviceSlug = $Service -replace '\.vsphere\.vmware\.com$', ''
    $serviceNamespace = "svc-$serviceSlug-$ClusterId"

    try {
        $vcenterNamespaceManagementSupervisorsSupervisorServicesCreateSpec = Initialize-VcenterNamespaceManagementSupervisorsSupervisorServicesCreateSpec -SupervisorService $Service -Version $Version
        try {
            Invoke-VcenterNamespaceManagementSupervisorsSupervisorServicesCreate -supervisor $SupervisorId -vcenterNamespaceManagementSupervisorsSupervisorServicesCreateSpec $vcenterNamespaceManagementSupervisorsSupervisorServicesCreateSpec -Confirm:$false -ErrorAction:Stop
            Write-LogMessage -TYPE INFO -Message "The ArgoCD operator was successfully created.  Waiting for configuration tasks to complete."
            Start-Sleep $CheckInterval
        } catch {
            $errMsg = $_.Exception.Message

            switch -Regex ($errMsg) {
                "a Supervisor Service with the identifier (.*) already exists" {
                    Write-LogMessage -TYPE WARNING -Message "A supervisor service was already created. Checking configuration status."
                }
                "Supervisor Service is not in activated state" {
                    # Service exists but is in a non-activated state (likely failed previous installation).
                    Write-LogMessage -TYPE ERROR -Message "ArgoCD operator installation failed: Failed to create Supervisor Service ($Service) version ($Version) on cluster ($SupervisorId). Supervisor Service is not in activated state."
                    Write-Host ""
                    Write-LogMessage -TYPE ERROR -Message "This error indicates the ArgoCD service already exists but is in a broken or deactivated state."
                    Write-LogMessage -TYPE ERROR -Message "SOLUTION: Delete and recreate the ArgoCD operator service:"
                    Write-LogMessage -TYPE ERROR -Message "  1. In vCenter UI, navigate to: Menu > Supervisor Management > Services."
                    Write-LogMessage -TYPE ERROR -Message "  2. Find `"$Service`" in the list."
                    Write-LogMessage -TYPE ERROR -Message "  3. Click the Actions dropdown menu for this service."
                    Write-LogMessage -TYPE ERROR -Message "  4. If available, click `"Deactivate Service`" and wait for completion."
                    Write-LogMessage -TYPE ERROR -Message "  5. Click the Actions dropdown menu again."
                    Write-LogMessage -TYPE ERROR -Message "  6. Click `"Delete`" to remove the service."
                    Write-LogMessage -TYPE ERROR -Message "  7. Wait for the service to be fully deleted."
                    Write-LogMessage -TYPE ERROR -Message "  8. Re-run this script to install a clean ArgoCD operator."
                    Write-Host ""
                    Write-LogMessage -TYPE WARNING -Message "If the service is stuck and cannot be deleted via UI:"
                    Write-LogMessage -TYPE WARNING -Message "  Use kubectl to manually clean up the namespace: kubectl delete namespace $serviceNamespace"
                    Write-LogMessage -TYPE WARNING -Message "  Then manually remove the service via vCenter REST API or contact VMware support."
                    throw "Deployment failed. Check logs for details."
                }
                "Signature verification result for Service Version ([0-9.-]+) not found" {
                    # Service version not available on this supervisor (signature verification failed)
                    $requestedVersion = $matches[1]

                    # Extract clean error message.
                    $cleanErrorMessage = Get-CleanErrorMessage -ErrorMessage $errMsg
                    if ($cleanErrorMessage -eq $errMsg) {
                        # No clean message found, use default message.
                        $cleanErrorMessage = "ArgoCD service version $requestedVersion is not available on this supervisor."
                    }

                    Write-LogMessage -TYPE ERROR -Message "ArgoCD operator installation failed: $cleanErrorMessage"
                    Write-Host ""
                    Write-LogMessage -TYPE ERROR -Message "SOLUTION: Either upgrade your supervisor to a version that includes ArgoCD service $requestedVersion,"
                    Write-LogMessage -TYPE ERROR -Message "         or modify your infrastructure.json to specify a different ArgoCD service version that is available."
                    Write-Host ""
                    Write-LogMessage -TYPE ERROR -Message "To list available ArgoCD service versions, use the vSphere API or vCenter UI:"
                    Write-LogMessage -TYPE ERROR -Message "  Menu > Supervisor Management > Supervisors > ArgoCD Service > Manager Versions"
                    throw "Deployment failed. Check logs for details."
                }
                "Supervisor Service \(argocd-service\.vsphere\.vmware\.com\) version \(([^)]+)\) has not been found" {
                    # Generic "version not found" error.
                    $requestedVersion = $matches[1]
                    Write-LogMessage -TYPE ERROR -Message "ArgoCD operator installation failed: ArgoCD service version $requestedVersion is not available on this supervisor."
                    Write-Host ""
                    Write-LogMessage -TYPE ERROR -Message "SOLUTION: Either upgrade your supervisor to a version that includes ArgoCD service $requestedVersion,"
                    Write-LogMessage -TYPE ERROR -Message "         or modify your infrastructure.json to specify a different ArgoCD service version that is available."
                    Write-Host ""
                    Write-LogMessage -TYPE ERROR -Message "To list available ArgoCD service versions, use the vSphere API or vCenter UI:"
                    Write-LogMessage -TYPE ERROR -Message "  Menu > Supervisor Management > Supervisors > ArgoCD Service > Manager Versions"
                    throw "Deployment failed. Check logs for details."
                }
                "Failed to run compatibility check for Supervisor Service" {
                    # Only catch compatibility check errors that are NOT about version availability.

                    # Extract clean error message from JSON response.
                    $cleanErrorMessage = Get-CleanErrorMessage -ErrorMessage $errMsg

                    Write-LogMessage -TYPE ERROR -Message "ArgoCD operator installation failed: $cleanErrorMessage"
                    Write-Host ""
                    Write-LogMessage -TYPE ERROR -Message "SOLUTION: Upgrade your supervisor to version 9.0.0.0-0100-24847555 or higher and try again."
                    Write-LogMessage -TYPE ERROR -Message "This error indicates the supervisor version is too old to verify the ArgoCD service signature."
                    throw "Deployment failed. Check logs for details."
                }
                default {
                    # Extract clean error message from JSON response.
                    $cleanMessage = Get-CleanErrorMessage -ErrorMessage $errMsg

                    if ($cleanMessage -ne $errMsg) {
                        Write-LogMessage -TYPE ERROR -Message "ArgoCD operator installation failed: $cleanMessage"
                    }
                    else {
                        Write-LogMessage -TYPE ERROR -Message "Unexpected error in Install-ArgoCDOperator: $errMsg"
                    }

                    throw "Deployment failed. Check logs for details."
                }
            }
        }

        $elapsedTime = 0

        do {
            try {
                $serviceOutput = Invoke-VcenterNamespaceManagementSupervisorsSupervisorServicesGet -supervisor $SupervisorId -supervisorService $Service
            } catch {
                # Handle JSON deserialization errors when config_status is empty or invalid.

                if ($_.Exception.Message -match "Error converting value.*config_status") {
                    Write-LogMessage -TYPE DEBUG -Message "Supervisor service status not yet available (empty config_status). Waiting..."
                    $statusMessage = "Elapsed Time: $elapsedTime seconds - Status: Initializing (config status not yet available)"
                    Write-Progress -Activity "Waiting for ArgoCD operator configuration" -Status $statusMessage
                    Start-Sleep $CheckInterval
                    $elapsedTime += $CheckInterval
                    continue
                } else {
                    # Re-throw unexpected errors
                    throw
                }
            }

            switch ($serviceOutput.ConfigStatus) {
                "CONFIGURED" {
                    Write-Progress -Activity "Waiting for ArgoCD operator configuration" -Status "Complete" -Completed
                    Write-LogMessage -TYPE INFO -Message "The ArgoCD operator has been successfully installed on vCenter `"$Script:VCenterName`" in $elapsedTime seconds."
                    return
                }
                "ERROR" {
                    Write-Progress -Activity "Waiting for ArgoCD operator configuration" -Status "Error" -Completed

                    # Extract error messages for analysis.
                    $errorMessages = $serviceOutput.Messages

                    # Check for specific reconciliation failures that indicate leftover resources.
                    switch -Regex ($errorMessages) {
                        "ReconcileFailed|already exists|AlreadyExists" {
                            Write-LogMessage -TYPE ERROR -Message "ArgoCD operator installation failed due to conflicting resources from a previous installation."
                            Write-LogMessage -TYPE ERROR -Message "Error details: $errorMessages"
                            Write-Host ""
                            Write-LogMessage -TYPE ERROR -Message "SOLUTION: Clean up the existing ArgoCD operator and retry:"
                            Write-LogMessage -TYPE ERROR -Message "  1. In vCenter UI, navigate to: Menu > Supervisor Management > Services."
                            Write-LogMessage -TYPE ERROR -Message "  2. Find `"ArgoCD Service`" and the Actions dropdown menu."
                            Write-LogMessage -TYPE ERROR -Message "  3. Click on Delete."
                            Write-LogMessage -TYPE ERROR -Message "  4. Click on Deactivate Service."
                            Write-LogMessage -TYPE ERROR -Message "  5. Click on Confirm."
                            Write-LogMessage -TYPE ERROR -Message "  6. Click on Delete."
                            Write-LogMessage -TYPE ERROR -Message "  7. Wait for the service to be deleted."
                            Write-LogMessage -TYPE ERROR -Message "  8. Re-run this script to install a clean ArgoCD operator."
                            Write-LogMessage -TYPE WARNING -Message "If the service is stuck in ERROR state and cannot be deleted via UI:"
                            Write-LogMessage -TYPE WARNING -Message "  Use kubectl to manually clean up the namespace: kubectl delete namespace $serviceNamespace"
                        }
                        default {
                            Write-LogMessage -TYPE ERROR -Message "The ArgoCD operator service has the following error message: $errorMessages"
                        }
                    }
                    throw "Deployment failed. Check logs for details."
                }
                default {
                    $statusMessage = "Elapsed Time: $elapsedTime seconds - Status: $($serviceOutput.ConfigStatus)"
                    Write-Progress -Activity "Waiting for ArgoCD operator configuration" -Status $statusMessage
                    Start-Sleep $CheckInterval
                    $elapsedTime += $CheckInterval
                }
            }
        } while ($elapsedTime -lt $TotalWaitTime)

        Write-Progress -Activity "Waiting for ArgoCD operator configuration" -Status "Timeout" -Completed
        Write-LogMessage -TYPE ERROR -Message "The service install request has timed out after $TotalWaitTime seconds. Please check the service logs for more information."
        throw "Deployment failed. Check logs for details."
    } catch {
        # Try to extract clean error message from JSON response.

        $errMsg = $_.Exception.Message

        # Extract clean error message from JSON response.
        $cleanMessage = Get-CleanErrorMessage -ErrorMessage $errMsg

        if ($cleanMessage -ne $errMsg) {
            Write-LogMessage -TYPE ERROR -Message "ArgoCD operator installation failed: $cleanMessage"
        }
        elseif ($errMsg -match "vcenter.wcp.appplatform.supervisorservice.cluster.not_running") {
            Write-LogMessage -TYPE ERROR -Message "The supervisor cluster is not running. Please login to vCenter `"$Script:VCenterName`" and verify its state."
        }
        else {
            Write-LogMessage -TYPE ERROR -Message "The ArgoCD operator creation failed: $errMsg"
        }
        throw "Deployment failed. Check logs for details."
    }
}
Function Convert-CountToInt {

    <#
        .SYNOPSIS
        Recursively converts 'count' properties from floating-point numbers to integers in PowerShell objects.

        .DESCRIPTION
        The Convert-CountToInt function traverses PowerShell objects (PSCustomObjects, hashtables, arrays)
        and converts any property named 'count' from floating-point numbers (double, single, decimal) or
        numeric strings to integer values. This is particularly useful when working with JSON data that
        may contain count values as floating-point numbers but should be integers for proper API consumption.

        The function performs recursive traversal of nested objects and collections, ensuring that all
        'count' properties throughout the entire object hierarchy are converted. It handles various data
        types including PSCustomObjects, hashtables, and enumerable collections while preserving the
        original object structure.

        Key features:
        - Recursive processing of nested objects and collections
        - Case-insensitive matching of 'count' property names
        - Support for PSCustomObjects, hashtables, and enumerable collections
        - Conversion from double, single, decimal, and numeric string values
        - Culture-invariant string parsing for consistent results
        - Truncation toward zero for floating-point to integer conversion

        .PARAMETER Item
        The PowerShell object to process. This can be any type of object including:
        - PSCustomObject with properties that may contain 'count' fields
        - Hashtable or IDictionary with 'count' keys
        - Arrays or other enumerable collections containing objects with 'count' properties
        - Individual values (which will be returned unchanged if not a container type)

        The parameter accepts pipeline input, allowing for easy processing of multiple objects.

        .EXAMPLE
        $jsonFilePathObject = @{
            name = "example"
            count = 5.0
            items = @(
                @{ count = "10.0"; value = "item1" },
                @{ count = 3.14; value = "item2" }
            )
        }
        Convert-CountToInt $jsonFilePathObject

        Converts the floating-point 'count' values to integers throughout the nested structure.
        After conversion: count = 5, items[0].count = 10, items[1].count = 3

        .EXAMPLE
        $pscustomObject = [PSCustomObject]@{
            Count = 7.5
            Details = [PSCustomObject]@{
                ItemCount = 12.0
                Count = "15.0"
            }
        }
        Convert-CountToInt $pscustomObject

        Processes a PSCustomObject with nested objects, converting all 'count' properties to integers.
        Case-insensitive matching ensures both 'Count' and 'count' properties are converted.

        .EXAMPLE
        $data | Convert-CountToInt

        Processes pipeline input, useful for converting multiple objects or JSON data imported from files.

        .NOTES
        - The function modifies objects in-place rather than creating copies
        - Uses culture-invariant parsing for consistent string-to-number conversion across different locales
        - Truncates floating-point values toward zero when converting to integers (5.9 becomes 5, -3.7 becomes -3)
        - Only processes properties specifically named 'count' (case-insensitive)
        - Handles circular references gracefully by processing each object only once per call
        - Designed for use with JSON data structures that may contain numeric count fields as floating-point values

        .INPUTS
        System.Object
        Any PowerShell object that may contain 'count' properties requiring integer conversion.

        .OUTPUTS
        None
        The function modifies input objects in-place and does not return values.

        .LINK
        ConvertFrom-Json
        ConvertTo-Json
    #>

    Param (
        [Parameter(ValueFromPipeline = $true)] $Item
    )

    Write-LogMessage -Type DEBUG -Message "Entered Convert-CountToInt function..."

    # Return immediately if the input item is null to avoid processing null values.
    if ($null -eq $Item) { return }

    # Process enumerable collections (arrays, lists, etc.) but exclude strings.
    # Recursively call Convert-CountToInt on each element in the collection.
    if ($Item -is [System.Collections.IEnumerable] -and $Item -isnot [string]) {
        foreach ($elem in $Item) { Convert-CountToInt $elem }
        return
    }

    # Process PSCustomObject properties.
    # Walk through all properties and convert any named 'count' from numeric types to integers.
    if ($Item -is [pscustomobject]) {
        foreach ($prop in $Item.PSObject.Properties) {
            # Case-insensitive check for 'count' property name.

            if ($prop.Name -ieq 'count') {
                $val = $prop.Value
                # Convert floating-point numbers (double, single, decimal) to integers
                if ($val -is [double] -or $val -is [single] -or $val -is [decimal]) {
                    $prop.Value = [int][double]$val       # Truncate toward zero
                }
                # Convert numeric strings to integers using culture-invariant parsing.

                elseif ($val -is [string]) {
                    $parsed = 0.0
                    if ([double]::TryParse(
                        $val,
                        [System.Globalization.NumberStyles]::Float,
                        [System.Globalization.CultureInfo]::InvariantCulture,
                        [ref] $parsed
                    )) {
                        $prop.Value = [int][double]$parsed  # Convert "1.0" -> 1
                    }
                }
            }
            # Recursively process nested property values.

            Convert-CountToInt $prop.Value
        }
        return
    }

    # Process hashtables and other dictionary types (IDictionary interface)
    # This provides support for hashtables created with -AsHashtable parameter in ConvertFrom-Json.
    if ($Item -is [System.Collections.IDictionary]) {
        # Create a copy of keys to avoid modification during enumeration.

        foreach ($key in @($Item.Keys)) {
            # Case-insensitive check for 'count' key in hashtables.

            if ($key -is [string] -and $key.Equals('count',[System.StringComparison]::OrdinalIgnoreCase)) {
                $val = $Item[$key]
                # Convert floating-point numbers to integers.

                if ($val -is [double] -or $val -is [single] -or $val -is [decimal]) {
                    $Item[$key] = [int][double]$val
                }
                # Convert numeric strings to integers using culture-invariant parsing.

                elseif ($val -is [string]) {
                    $parsed = 0.0
                    if ([double]::TryParse($val,
                        [System.Globalization.NumberStyles]::Float,
                        [System.Globalization.CultureInfo]::InvariantCulture,
                        [ref] $parsed)) {
                        $Item[$key] = [int][double]$parsed
                    }
                }
            }
            # Recursively process nested dictionary values.

            Convert-CountToInt $Item[$key]
        }
    }
}
Function Get-InteractiveInput {

    <#
        .SYNOPSIS
        Prompts the user for input with validation to ensure a non-empty value is provided.

        .DESCRIPTION
        The Get-InteractiveInput function provides a way to collect user input
        with built-in validation that prevents empty responses. The function repeatedly
        prompts the user until a valid (non-empty) value is entered, ensuring that
        required information is always collected before proceeding.

        The function supports both standard text input and secure string input for
        sensitive information like passwords. When using secure string mode, the input
        is masked and returned as a SecureString object for enhanced security handling.

        This function is essential for interactive scripts that require user input and
        cannot proceed without valid data, providing a consistent user experience across
        the VCF PowerShell Toolbox.

        .PARAMETER AsSecureString
        When specified, the input will be collected as a secure string with masked
        characters (asterisks) displayed instead of the actual input. This is
        recommended for passwords and other sensitive information. The returned
        value will be a System.Security.SecureString object.

        .PARAMETER PromptMessage
        The message displayed to the user when requesting input. This should be a clear,
        descriptive prompt that explains what information is being requested. The message
        will be displayed repeatedly until valid input is provided.
        When specified, the input will be collected as a secure string with masked
        characters (asterisks) displayed instead of the actual input. This is
        recommended for passwords and other sensitive information. The returned
        value will be a System.Security.SecureString object.

        .EXAMPLE
        $domain = Get-InteractiveInput -PromptMessage "Enter your domain (or press Enter for default)"

    #>

    Param (
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [Switch]$AsSecureString,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$PromptMessage
    )

    Write-LogMessage -Type DEBUG -Message "Entered Get-InteractiveInput function..."

    do {
        if ($AsSecureString) {
            $value = Read-Host $PromptMessage -asSecureString
        } else {
            $value = Read-Host $PromptMessage
        }
    } while ($value.Length -eq 0)

    return $value
}


Function Get-JsonDataWithValidation {

    <#
        .SYNOPSIS
        Loads and validates JSON file existence and parseability with consistent error handling.

        .DESCRIPTION
        Common helper function for JSON validation functions that handles file existence checking
        and JSON parsing with consistent error handling and logging. This function eliminates
        code duplication across Test-JsonMissingProperties and Test-JsonNullValues by centralizing
        the common file validation and parsing logic.

        The function performs two critical validations:
        1. Verifies the JSON file exists at the specified path
        2. Attempts to parse the JSON file using ConvertFrom-JsonSafely

        If either validation fails, the function updates the provided ValidationResult object
        with appropriate error information and returns $null. On success, it returns the parsed
        JSON data and stores it in the ValidationResult.JsonData property.

        .PARAMETER JsonFilePath
        Path to the JSON file to load and validate.

        .PARAMETER JsonObjectName
        Name of the JSON object for error messages and logging (e.g., "InputConfiguration", "SupervisorConfiguration").
        This name is used to provide context in error messages.

        .PARAMETER ValidationResult
        Reference to the validation result object to update on error. The function will set
        IsValid, ErrorCount, and Summary properties on validation failure.

        .OUTPUTS
        PSCustomObject - Parsed JSON data on success, or $null if validation failed.

        .EXAMPLE
        $jsonFilePathData = Get-JsonDataWithValidation -JsonFilePath $JsonFilePath -JsonObjectName $JsonObjectName -ValidationResult ([ref]$validationResult)
        if ($null -eq $jsonFilePathData) {
            return $validationResult
        }

        Loads JSON data and returns early if validation fails.

        .NOTES
        This function is a helper for Test-JsonMissingProperties and Test-JsonNullValues.

        Error Handling:
        • Updates ValidationResult object with error details
        • Logs errors using Write-LogMessage
        • Returns $null on any validation failure
        • Preserves parsed JSON data in ValidationResult.JsonData on success
    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$JsonFilePath,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$JsonObjectName,
        [Parameter(Mandatory = $true)] [ref]$ValidationResult
    )

    Write-LogMessage -Type DEBUG -Message "Validating and loading JSON file: $JsonFilePath"

    # Validate that the JSON file exists.
    if (-Not (Test-Path -Path $JsonFilePath -PathType Leaf)) {
        $ValidationResult.Value.IsValid = $false
        $ValidationResult.Value.ErrorCount = 1
        $ValidationResult.Value.Summary = "$JsonObjectName validation failed: File $JsonFilePath does not exist."
        Write-LogMessage -Type ERROR -Message $ValidationResult.Value.Summary
        return $null
    }

    # Load and parse the JSON file.
    try {
        $jsonFilePathData = ConvertFrom-JsonSafely -JsonFilePath $JsonFilePath
        $ValidationResult.Value.JsonData = $jsonFilePathData
        return $jsonFilePathData
    }
    catch {
        $ValidationResult.Value.IsValid = $false
        $ValidationResult.Value.ErrorCount = 1
        $ValidationResult.Value.Summary = "$JsonObjectName validation failed: Unable to parse JSON file $JsonFilePath. Error: $_"
        Write-LogMessage -Type ERROR -Message $ValidationResult.Value.Summary
        return $null
    }
}

Function Test-JsonFile {

    <#
        .SYNOPSIS
        Validates JSON file existence and content with proper resource management and comprehensive error handling.

        .DESCRIPTION
        The Test-JsonFile function provides robust validation of JSON files by checking both file existence
        and JSON content validity. It uses the .NET System.Text.Json.JsonDocument class for efficient
        parsing and implements proper resource disposal to prevent memory leaks.

        Key features:
        - File existence validation with detailed error reporting
        - Strict JSON parsing using System.Text.Json.JsonDocument
        - Proper resource disposal using try/finally blocks
        - Comprehensive error handling with specific exception types
        - Integration with the script's logging system
        - Performance optimized for large JSON files

        The function will return $true if the file exists and contains valid JSON, $false otherwise.
        All errors are logged using the Write-LogMessage system for consistent error reporting.

        .EXAMPLE
        Test-JsonFile -JsonFilePath "C:\config\settings.json"
        Returns $true if the file exists and contains valid JSON, $false otherwise.

        .EXAMPLE
        if (Test-JsonFile -JsonFilePath $configPath) {
            Write-Host "Configuration file is valid"
            $config = Get-Content $configPath | ConvertFrom-Json
        }

        .PARAMETER JsonFilePath
        The absolute path to the JSON file to be validated. This parameter is mandatory and must
        point to an existing file. The path can be either a local file path or a UNC path.

        .OUTPUTS
        System.Boolean
        Returns $true if the file exists and contains valid JSON content, $false otherwise.

        .NOTES
        - Uses System.Text.Json.JsonDocument for efficient JSON validation
        - Implements proper resource disposal to prevent memory leaks
        - All validation errors are logged using Write-LogMessage
        - Function is optimized for performance with large JSON files
        - Compatible with both Windows PowerShell 5.1 and PowerShell 7+
    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateScript({ if ([string]::IsNullOrWhiteSpace($_)) { throw "JSON file path cannot be null, empty, or contain only whitespace characters." }; if ($_.Length -gt 260) { throw "JSON file path cannot exceed 260 characters. Current length: $($_.Length)" }; if ($_ -match '[<>"|?*]') { throw "JSON file path contains invalid characters: $($matches[0])" }; return $true })] [ValidateNotNullOrEmpty()] [String]$JsonFilePath
    )

    Write-LogMessage -Type DEBUG -Message "Entered Test-JsonFile function..."

    # Validate file existence first.
    if (-not (Test-Path -Path $JsonFilePath -PathType Leaf)) {
        Write-LogMessage -Type ERROR -Message "JSON file not found: '$JsonFilePath'"
        return $false
    }

    # Validate file is actually a file (not a directory)
    $fileInfo = Get-Item -Path $JsonFilePath -ErrorAction SilentlyContinue
    if ($fileInfo -and $fileInfo.PSIsContainer) {
        Write-LogMessage -Type ERROR -Message "Specified path is a directory, not a file: '$JsonFilePath'"
        return $false
    }

    # Check if file is readable.
    try {
        $null = Get-Content -Path $JsonFilePath -TotalCount 1 -ErrorAction Stop
    } catch [System.UnauthorizedAccessException] {
        Write-LogMessage -Type ERROR -Message "Access denied reading JSON file: '$JsonFilePath'. Please check file permissions."
        return $false
    } catch [System.IO.IOException] {
        Write-LogMessage -Type ERROR -Message "I/O error reading JSON file: '$JsonFilePath'. File may be locked or corrupted."
        return $false
    } catch {
        Write-LogMessage -Type ERROR -Message "Unexpected error reading JSON file: '$JsonFilePath': $($_.Exception.Message)"
        return $false
    }

    # Validate JSON content.
    $jsonFilePathDocument = $null
    try {
        Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "Validating JSON content in file: '$JsonFilePath'"

        # Read file content
        $content = Get-Content -Path $JsonFilePath -Raw -ErrorAction Stop

        # Check for empty file.

        if ([string]::IsNullOrWhiteSpace($content)) {
            Write-LogMessage -Type ERROR -Message "JSON file is empty or contains only whitespace: '$JsonFilePath'"
            return $false
        }

        # Load and validate JSON using System.Text.Json for strict parsing.

        Add-Type -AssemblyName System.Text.Json -ErrorAction Stop

        # Parse JSON with strict validation.

        $jsonFilePathDocument = [System.Text.Json.JsonDocument]::Parse($content)

        # If we reach here, JSON is valid.

        Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "JSON file validation successful: '$JsonFilePath'"
        return $true

    } catch [System.Text.Json.JsonException] {
        # Handle JSON parsing errors specifically.

        Write-LogMessage -Type ERROR -Message "Invalid JSON format in file: '$JsonFilePath'"
        Write-LogMessage -Type ERROR -Message "JSON parsing error: $($_.Exception.Message)"
        return $false
    } catch [System.ArgumentException] {
        # Handle argument exceptions (e.g., invalid UTF-8 encoding)
        Write-LogMessage -Type ERROR -Message "Invalid content encoding in JSON file: '$JsonFilePath'"
        Write-LogMessage -Type ERROR -Message "Encoding error: $($_.Exception.Message)"
        return $false
    } catch [System.IO.FileNotFoundException] {
        # Handle case where file was deleted between existence check and read.

        Write-LogMessage -Type ERROR -Message "JSON file was deleted during validation: '$JsonFilePath'"
        return $false
    } catch [System.OutOfMemoryException] {
        # Handle very large files that exceed memory limits.

        Write-LogMessage -Type ERROR -Message "JSON file too large to process: '$JsonFilePath'. File may exceed available memory."
        return $false
    } catch {
        # Handle any other unexpected exceptions.

        Write-LogMessage -Type ERROR -Message "Unexpected error during JSON validation for file: '$JsonFilePath'"
        Write-LogMessage -Type ERROR -Message "Error details: $($_.Exception.Message)"
        return $false
    } finally {
        # Ensure proper resource disposal.

        if ($jsonFilePathDocument) {
            try {
                $jsonFilePathDocument.Dispose()
                Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "JSON document resources properly disposed for: '$JsonFilePath'"
            } catch {
                Write-LogMessage -Type WARNING -SuppressOutputToScreen -Message "Warning: Could not dispose JSON document resources for: '$JsonFilePath': $($_.Exception.Message)"
            }
        }
    }
}
Function ConvertFrom-JsonSafely {

    <#
        .SYNOPSIS
        Safely loads and validates JSON content from a file with comprehensive error handling.

        .DESCRIPTION
        The ConvertFrom-JsonSafely function provides a robust way to load JSON files with
        built-in validation and error handling. The function reads the file content, removes
        empty lines that could cause JSON parsing issues, and converts the content to a
        PowerShell object. If JSON validation fails, the function logs detailed error
        information including the file path and specific parsing error, then exits the
        script to prevent further execution with invalid data.

        This function standardizes JSON loading across the VCF PowerShell Toolbox and
        ensures consistent error reporting for troubleshooting.

        .PARAMETER JsonFilePath
        The full path to the JSON file to load and parse. The file must exist and
        contain valid JSON content.

        .EXAMPLE
        $config = ConvertFrom-JsonSafely -JsonFilePath "C:\configs\settings.json"
        Loads application settings from a JSON file with error handling.

        .NOTES
        This function will terminate script execution (exit) if JSON parsing fails.
        Empty lines are automatically filtered out before JSON parsing to handle
        files that may have formatting issues.
    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$JsonFilePath
    )

    Write-LogMessage -Type DEBUG -Message "Entered ConvertFrom-JsonSafely function..."

    try {
        # Read file content, filter out empty lines, and convert from JSON,.

        # Empty line filtering prevents JSON parsing issues with poorly formatted files,.

        return (Get-Content $JsonFilePath) | Select-String -Pattern "^\s*$" -NotMatch | ConvertFrom-Json -ErrorVariable ErrorMessage

    }
    catch {
        # Handle JSON parsing errors with detailed, user-friendly logging.
        $errorMessage = $_.Exception.Message

        Write-LogMessage -Type ERROR -Message "JSON validation failed for file: $JsonFilePath"
        Write-Host ""

        # Extract the specific JSON error and location.

        if ($errorMessage -match "Bad JSON escape sequence: \\([A-Za-z])\..*'([^']+)'.*line (\d+).*position (\d+)") {
            $badChar = $matches[1]
            $jsonFilePathPath = $matches[2]
            $lineNum = $matches[3]
            $position = $matches[4]

            Write-LogMessage -Type ERROR -Message "Invalid escape sequence: '\$badChar' in JSON property '$jsonFilePathPath'"
            Write-LogMessage -Type ERROR -Message "Location: Line $lineNum, Position $position"
            Write-Host ""
            Write-LogMessage -Type ERROR -Message "Common causes:"
            Write-LogMessage -Type ERROR -Message "  1. Windows file paths must use forward slashes (/) or escaped backslashes (\\\\)"
            Write-LogMessage -Type ERROR -Message "     Example: `"C:/Users/Admin/file.yml`" or `"C:\\\\Users\\\\Admin\\\\file.yml`""
            Write-LogMessage -Type ERROR -Message "  2. Backslash (\) is a special character in JSON and must be escaped"
            Write-Host ""
            Write-LogMessage -Type ERROR -Message "Please correct the JSON syntax in '$JsonFilePath' at line $lineNum and try again."
        }
        elseif ($errorMessage -match "Conversion from JSON failed with error: (.+?)\. Path '([^']+)'.*line (\d+).*position (\d+)") {
            $jsonFilePathError = $matches[1]
            $jsonFilePathPath = $matches[2]
            $lineNum = $matches[3]
            $position = $matches[4]

            Write-LogMessage -Type ERROR -Message "JSON parsing error: $jsonFilePathError"
            Write-LogMessage -Type ERROR -Message "Property: '$jsonFilePathPath'"
            Write-LogMessage -Type ERROR -Message "Location: Line $lineNum, Position $position"
            Write-Host ""
            Write-LogMessage -Type ERROR -Message "Please correct the JSON syntax in '$JsonFilePath' and try again."
        }
        else {
            # Fallback for unexpected error formats.

            Write-LogMessage -Type ERROR -Message "JSON parsing error: $errorMessage"
        }

        # Exit script execution to prevent continuing with invalid data.
        throw "Deployment failed. Check logs for details."
    }
}
Function Test-CommandAvailability {

    <#
        .SYNOPSIS
        Tests if a specified command/utility is available in the system PATH.

        .DESCRIPTION
        This function checks whether a given command or executable is available and accessible
        through the system PATH. It can be used to verify that required tools or utilities
        are installed before attempting to use them in the script. If the command is not found,
        the function will log an error and exit the script.

        .EXAMPLE
        Test-CommandAvailability -Command "vcf" -Description "vcf-cli"

        .PARAMETER Command
        The name of the command or executable to test for availability

        .PARAMETER Description
        A human-readable description of the command for use in error messages


    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Command,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Description

    )

    Write-LogMessage -Type DEBUG -Message "Entered Test-CommandAvailability function..."

    if (Get-Command $Command -ErrorAction SilentlyContinue) {
        Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "Executable $Command found in PATH. Proceeding."
    } else {
        Write-LogMessage -Type ERROR -Message "Executable `"$Command`" not found in PATH.  $Description is required for the script to proceed. Exiting"
        throw "Deployment failed. Check logs for details."
    }
}
Function Test-Filepath {

    <#
        .SYNOPSIS
        Tests if a specified file exists at the given file path.

        .DESCRIPTION
        The function Test-Filepath validates whether a file exists at the specified path.
        If the file exists, it logs a success message. If the file does not exist,
        it logs an error message and exits the script with code 1.

        .EXAMPLE
        Test-Filepath -FilePath "c:\\argocd.yml" -Description "ArgoCD configuration"

        .PARAMETER FilePath
        The absolute path to the file that needs to be validated for existence.

        .PARAMETER Description
        A descriptive name for the file being tested, used in log messages.

    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$FilePath,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Description

    )

    Write-LogMessage -Type DEBUG -Message "Entered Test-Filepath function..."

    if (Test-Path -Path $FilePath -PathType Leaf) {
        Write-LogMessage -Type INFO -Message "Found the `"$Description`" file on disk: `"$FilePath`"."
    } else {
        Write-LogMessage -Type ERROR -Message "Failed to find `"$Description`" file on disk: `"$FilePath`" not found. Exiting."
        throw "Deployment failed. Check logs for details."
    }
}

Function Test-JsonMissingProperties {

    <#
        .SYNOPSIS
        Validates JSON file content for missing required properties with support for nested properties.

        .DESCRIPTION
        The Test-JsonMissingProperties function provides comprehensive validation of JSON files
        to ensure all required properties are present. It supports nested property validation
        using dot notation (e.g., "common.vCenter.name") and provides detailed reporting of
        missing properties with their expected structure.

        This function is particularly useful for validating configuration files, API payloads,
        or any JSON data that must conform to a specific schema. It integrates with the VCF
        PowerShell Toolbox logging infrastructure for consistent error reporting.

        .PARAMETER JsonFilePath
        The full path to the JSON file to validate. The file must exist and contain valid JSON content.

        .PARAMETER RequiredProperties
        An array of property names (using dot notation for nested properties) that must be present
        in the JSON object. Examples: "name", "config.database.host", "settings.security.enabled"

        .PARAMETER JsonObjectName
        A descriptive name for the JSON object being validated, used in error messages and
        logging to help identify the source of validation failures.

        .PARAMETER StopOnFirstError
        When specified, the function will stop validation and return immediately upon
        finding the first missing property, rather than validating all properties.

        .PARAMETER ShowExpectedStructure
        When specified, the function will include the expected JSON structure for missing
        properties in the validation results, helpful for troubleshooting and documentation.

        .OUTPUTS
        System.Management.Automation.PSCustomObject
        Returns an object with the following properties:
        - IsValid: Boolean indicating if all validations passed
        - MissingProperties: Array of missing property paths
        - ExpectedStructure: Suggested JSON structure for missing properties (if ShowExpectedStructure is used)
        - ErrorCount: Total number of missing properties
        - Summary: Human-readable summary of validation results
        - JsonData: The loaded JSON object (if validation passes)

        .EXAMPLE
        $validationResult = Test-JsonMissingProperties -JsonFilePath "config.json" -RequiredProperties @("database.host", "database.port", "api.key") -JsonObjectName "Configuration"

        if (-not $validationResult.IsValid) {
            Write-Host "Validation failed: $($validationResult.Summary)"
            return
        }
        $config = $validationResult.JsonData

        .EXAMPLE
        $requiredProps = @(
            "common.vCenterName",
            "common.VcenterUser",
            "common.esxHost",
            "common.argoCD.argoCdOperatorYamlPath",
            "common.datastore.lunId"
        )
        $result = Test-JsonMissingProperties -JsonFilePath "input.json" -RequiredProperties $requiredProps -JsonObjectName "InputConfiguration" -ShowExpectedStructure

        .NOTES
        This function uses the existing ConvertFrom-JsonSafely function for safe JSON loading
        and integrates with the VCF PowerShell Toolbox logging infrastructure. Nested properties
        are accessed using dot notation, and the function provides detailed error reporting
        for missing properties at any depth in the JSON structure.
    #>

    Param (
        [Parameter(Mandatory = $false)] [Switch]$StopOnFirstError,
        [Parameter(Mandatory = $false)] [Switch]$ShowExpectedStructure,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$JsonFilePath,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String[]]$RequiredProperties,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$JsonObjectName
    )

    Write-LogMessage -Type DEBUG -Message "Entered Test-JsonMissingProperties function..."

    # Initialize validation result object.
    $validationResult = [PSCustomObject]@{
        IsValid = $true
        MissingProperties = @()
        ExpectedStructure = @{}
        ErrorCount = 0
        Summary = ""
        JsonData = $null
    }

    Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "Validating $($RequiredProperties.Count) required properties: $($RequiredProperties -join ', ')"

    # Load and validate the JSON file using helper function.
    $jsonFilePathData = Get-JsonDataWithValidation -JsonFilePath $JsonFilePath -JsonObjectName $JsonObjectName -ValidationResult ([ref]$validationResult)
    if ($null -eq $jsonFilePathData) {
        return $validationResult
    }

    # Helper function to check if a nested property exists using dot notation.
    Function Test-NestedProperty {
        <#
            .SYNOPSIS
            Tests whether a nested property exists in an object using dot notation path.

            .DESCRIPTION
            This function traverses a nested object structure to verify if a property path exists.
            It supports both PowerShell custom objects (PSObject) and hashtables, following
            a dot-separated property path (e.g., "config.database.host") to determine if the
            entire path is valid and accessible.

            The function performs deep traversal of the object hierarchy, checking each level
            of the specified path. It handles different object types:
            - Hashtables: Uses ContainsKey() method to check for property existence
            - PSObjects: Uses PSObject.Properties collection to verify property existence

            This is particularly useful for validating JSON configuration objects or
            complex nested data structures before attempting to access their properties.

            .PARAMETER Object
            The root object to search within. Can be a PowerShell custom object, hashtable,
            or any object that supports property access.

            .PARAMETER PropertyPath
            A string representing the property path using dot notation (e.g., "level1.level2.property").
            Each segment separated by dots represents a nested level in the object hierarchy.

            .EXAMPLE
            Test-NestedProperty -Object $JsonFilePathConfig -PropertyPath "database.connection.host"

            Tests if the $JsonFilePathConfig object contains the nested property path database.connection.host.
            Returns $true if the entire path exists, $false otherwise.

            .EXAMPLE
            $config = @{
                server = @{
                    network = @{
                        port = 8080
                    }
                }
            }
            Test-NestedProperty -Object $config -propertyPath "server.network.port"

            Returns $true because the complete path exists in the hashtable structure.

            .EXAMPLE
            Test-NestedProperty -Object $config -propertyPath "server.network.timeout"

            Returns $false if the 'timeout' property doesn't exist under server.network.

            .OUTPUTS
            System.Boolean
            Returns $true if the complete property path exists, $false if any part of the path is missing.

            .NOTES
            - The function performs case-sensitive property matching
            - Works with mixed object types (hashtables and PSObjects) in the same hierarchy
            - Stops traversal and returns $false as soon as any part of the path is not found
            - Does not throw exceptions for missing properties, always returns a boolean result
        #>

        param($Object, $PropertyPath)

        # Split the property path into individual segments using dot as delimiter.

        $properties = $PropertyPath -split '\.'
        # Start traversal from the root object.

        $currentObject = $Object

        # Iterate through each property segment in the path.

        foreach ($Property in $properties) {
            # Handle hashtable objects - use ContainsKey for property existence check.

            if ($currentObject -is [System.Collections.Hashtable]) {
                if (-not $currentObject.ContainsKey($Property)) {
                    return $false
                }
                # Move to the next level in the hierarchy.

                $currentObject = $currentObject[$Property]
            }
            # Handle PowerShell custom objects - check PSObject.Properties collection.

            elseif ($currentObject.PSObject.Properties[$Property]) {
                # Move to the next level in the hierarchy.

                $currentObject = $currentObject.$Property
            }
            # Property doesn't exist in current object - path is invalid.

            else {
                return $false
            }
        }

        # Successfully traversed the entire path.

        return $true
    }

    # Helper function to generate expected JSON structure for missing properties.

Function Get-ExpectedStructure {

        <#
            .SYNOPSIS
            Generates a nested JSON structure template for a missing property path.

            .DESCRIPTION
            This helper function creates a hierarchical hashtable structure that represents
            the expected JSON format for a missing property specified using dot notation.
            It builds nested objects for each level in the property path and adds a
            placeholder value for the final property.

            The function is used internally by Test-JsonMissingProperties to provide
            users with concrete examples of what structure their JSON should have
            when properties are missing.

            .PARAMETER PropertyPath
            A string representing the property path using dot notation (e.g., "config.database.host").
            Each segment separated by dots becomes a nested level in the resulting structure.

            .EXAMPLE
            Get-ExpectedStructure -PropertyPath "config.database.host"

            Returns:
            @{
                config = @{
                    database = @{
                        host = "<value>"
                    }
                }
            }

            .EXAMPLE
            Get-ExpectedStructure -PropertyPath "name"

            Returns:
            @{
                name = "<value>"
            }

            .OUTPUTS
            System.Collections.Hashtable
            Returns a nested hashtable representing the expected JSON structure with
            placeholder values ("<value>") for the final property in the path.

            .NOTES
            - This is an internal helper function within Test-JsonMissingProperties
            - The placeholder value "<value>" indicates where actual data should be provided
            - The structure can be converted to JSON for display purposes
            - Supports unlimited nesting depth based on the property path provided
        #>

        Param (
            [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$PropertyPath
        )

    Write-LogMessage -Type DEBUG -Message "Entered Get-ExpectedStructure function..."

        # Split the property path into individual property names.

        $properties = $PropertyPath -split '\.'

        # Initialize the root structure as an empty hashtable.

        $structure = @{}

        # Keep a reference to the current level for building nested structure.

        $currentLevel = $structure

        # Build the nested structure by iterating through each property in the path.

        for ($i = 0; $i -lt $properties.Count; $i++) {
            $property = $properties[$i]

            if ($i -eq ($properties.Count - 1)) {
                # Last property in the path - add placeholder value to indicate expected data.

                $currentLevel[$property] = "<value>"
            }
            else {
                # Intermediate property - create nested hashtable and move reference deeper.

                $currentLevel[$property] = @{}
                $currentLevel = $currentLevel[$property]
            }
        }

        # Return the complete nested structure.

        return $structure
    }

    # Validate each required property.
    foreach ($property in $RequiredProperties) {
        $propertyExists = Test-NestedProperty -Object $JsonFilePathData -PropertyPath $property

        if (-not $propertyExists) {
            $validationResult.IsValid = $false
            $validationResult.MissingProperties += $property
            $validationResult.ErrorCount++

            Write-LogMessage -Type ERROR -Message "$JsonObjectName (in JSON file $JsonFilePath) is missing required property: $property"

            # Generate expected structure if requested.

            if ($ShowExpectedStructure) {
                $expectedStructure = Get-ExpectedStructure -PropertyPath $property
                $validationResult.ExpectedStructure[$property] = $expectedStructure
            }

            # Stop on first error if requested.

            if ($StopOnFirstError) {
                break
            }
        }
    }

    # Generate summary message.
    if ($validationResult.IsValid) {
        $validationResult.Summary = "$JsonObjectName validation passed. All $($RequiredProperties.Count) required properties are present."
        Write-LogMessage -Type INFO -Message $validationResult.Summary -SuppressOutputToScreen
    }
    else {
        $validationResult.Summary = "$JsonObjectName validation failed. $($validationResult.ErrorCount) of $($RequiredProperties.Count) required properties are missing: $($validationResult.MissingProperties -join ', ')"
        Write-LogMessage -Type ERROR -Message $validationResult.Summary

        # Log expected structure if available.

        if ($ShowExpectedStructure -and $validationResult.ExpectedStructure.Count -gt 0) {
            Write-LogMessage -Type INFO -Message "Expected JSON structure for missing properties:"
            foreach ($missingProp in $validationResult.MissingProperties) {
                $structureJson = $validationResult.ExpectedStructure[$missingProp] | ConvertTo-Json -Depth 10
                Write-LogMessage -Type INFO -Message "Property '$missingProp' expected structure: $structureJson"
            }
        }
    }

    return $validationResult
}

Function Test-JsonNullValues {

    <#
        .SYNOPSIS
        Validates that specified JSON properties are not null.

        .DESCRIPTION
        The Test-JsonNullValues function checks whether specified properties in a JSON file
        contain null values. This is a complementary validation to Test-JsonMissingProperties,
        which only checks if keys exist. This function ensures that existing keys also have
        non-null values.

        This validation is critical because PowerShell's JSON parsing will include properties
        with null values in the object structure, making them technically "present" but unusable.
        Configuration files must have actual values, not nulls, for deployment to succeed.

        .PARAMETER JsonFilePath
        The full path to the JSON file to validate. The file must exist and contain valid JSON content.

        .PARAMETER RequiredProperties
        An array of property names (using dot notation for nested properties) that must have
        non-null values. Examples: "name", "config.database.host", "settings.security.enabled"

        .PARAMETER JsonObjectName
        A descriptive name for the JSON object being validated, used in error messages and
        logging to help identify the source of validation failures.

        .PARAMETER StopOnFirstError
        When specified, the function will stop validation and return immediately upon
        finding the first null value, rather than validating all properties.

        .OUTPUTS
        System.Management.Automation.PSCustomObject
        Returns an object with the following properties:
        - IsValid: Boolean indicating if all validations passed (no null values found)
        - NullProperties: Array of property paths that contain null values
        - ErrorCount: Total number of properties with null values
        - Summary: Human-readable summary of validation results
        - JsonData: The loaded JSON object (if validation passes)

        .EXAMPLE
        $validationResult = Test-JsonNullValues -JsonFilePath "config.json" -RequiredProperties @("database.host", "database.port", "api.key") -JsonObjectName "Configuration"

        if (-not $validationResult.IsValid) {
            Write-Host "Validation failed: $($validationResult.Summary)"
            return
        }

        .EXAMPLE
        $requiredProps = @(
            "common.vCenterName",
            "common.VcenterUser",
            "common.esxHost"
        )
        $result = Test-JsonNullValues -JsonFilePath "input.json" -RequiredProperties $requiredProps -JsonObjectName "InputConfiguration"

        .NOTES
        - This function is designed to work in conjunction with Test-JsonMissingProperties
        - First check if keys exist (Test-JsonMissingProperties), then check if values are non-null (Test-JsonNullValues)
        - Uses Get-JsonPropertyValue to retrieve nested property values
        - Integrates with VCF PowerShell Toolbox logging infrastructure
        - Null values in arrays or objects are also detected

        Error Handling: Main workflow function. Uses 'exit 1' to terminate script on critical
        validation failures when properties contain null values.
    #>

    Param (
        [Parameter(Mandatory = $false)] [Switch]$StopOnFirstError,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$JsonFilePath,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String[]]$RequiredProperties,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$JsonObjectName
    )

    Write-LogMessage -Type DEBUG -Message "Entered Test-JsonNullValues function..."

    # Initialize validation result object.
    $validationResult = [PSCustomObject]@{
        IsValid = $true
        NullProperties = @()
        ErrorCount = 0
        Summary = ""
        JsonData = $null
    }

    Write-LogMessage -Type DEBUG -Message "Checking $($RequiredProperties.Count) properties for null values: $($RequiredProperties -join ', ')"

    # Load and validate the JSON file using helper function.
    $jsonFilePathData = Get-JsonDataWithValidation -JsonFilePath $JsonFilePath -JsonObjectName $JsonObjectName -ValidationResult ([ref]$validationResult)
    if ($null -eq $jsonFilePathData) {
        return $validationResult
    }

    # Validate each property for null values.
    foreach ($Property in $RequiredProperties) {
        # Use Get-JsonPropertyValue to retrieve the property value.

        $propertyValue = Get-JsonPropertyValue -inputData $jsonFilePathData -propertyPath $Property

        # Check if the value is null.

        if ($null -eq $propertyValue) {
            $validationResult.IsValid = $false
            $validationResult.NullProperties += $Property
            $validationResult.ErrorCount++

            Write-LogMessage -Type ERROR -Message "$JsonObjectName (in JSON file $JsonFilePath) property '$Property' has a null value. Please provide a valid value."

            # Stop on first error if requested.

            if ($StopOnFirstError) {
                break
            }
        }
    }

    # Generate summary message.
    if ($validationResult.IsValid) {
        $validationResult.Summary = "$JsonObjectName null value validation passed. All $($RequiredProperties.Count) required properties have non-null values."
        Write-LogMessage -Type DEBUG -Message $validationResult.Summary
    }
    else {
        $validationResult.Summary = "$JsonObjectName null value validation failed. $($validationResult.ErrorCount) of $($RequiredProperties.Count) required properties have null values: $($validationResult.NullProperties -join ', ')"
        Write-LogMessage -Type ERROR -Message $validationResult.Summary
    }

    return $validationResult
}
Function Test-JsonShallowValidation {

    <#
        .SYNOPSIS
        Validates both input.json and supervisor.json configuration files to ensure all required properties are present and have non-null values.

        .DESCRIPTION
        This function performs comprehensive validation of two critical JSON configuration files used in the one node deployment:
        1. input.json - Contains infrastructure configuration including vCenter, ESX host, storage, and networking details
        2. supervisor.json - Contains supervisor cluster configuration including TKGS components, load balancer, and network specifications

        The function performs the following validation operations:
        - Defines comprehensive arrays of required properties for both JSON files
        - Loads and parses both JSON configuration files
        - Validates each file against its respective required properties using Test-JsonMissingProperties (checks if keys exist)
        - Validates each file's required properties for null values using Test-JsonNullValues (checks if values are non-null)
        - Provides detailed logging for validation results
        - Exits with error code 1 if any validation fails, ensuring deployment doesn't proceed with incomplete or null configuration

        This two-phase validation is critical to prevent deployment failures due to:
        1. Missing properties (keys don't exist in JSON)
        2. Null values (keys exist but have no value)

        Both conditions would cause deployment failures and must be caught early.

        .EXAMPLE
        Test-JsonShallowValidation -InfrastructureJson "C:\config\input.json" -SupervisorJson "C:\config\SupervisorDetails.json"

        This example validates both configuration files located in the C:\config directory before proceeding with deployment.

        .EXAMPLE
        Test-JsonShallowValidation -InfrastructureJson $InfrastructureJson -SupervisorJson $SupervisorJson

        This function is typically called during the initialization phase using variables containing the file paths
        to validate configuration files before proceeding with the one node deployment process.

        .PARAMETER InfrastructureJson
        Specifies the full path to the input.json configuration file. This file must contain all required infrastructure
        configuration properties including vCenter details, ESX host information, storage configuration, content library
        settings, and virtual distributed switch specifications. The file must be valid JSON format and accessible.

        .PARAMETER SupervisorJson
        Specifies the full path to the supervisor.json (SupervisorDetails.json) configuration file. This file must contain
        all required TKGS supervisor cluster configuration properties including supervisor specifications, foundation load
        balancer components, management network settings, and primary workload network configurations. The file must be
        valid JSON format and accessible.

        .NOTES
        - Both JSON files must exist and be readable at the specified paths
        - Performs two-phase validation:
          1. Test-JsonMissingProperties: Checks if all required keys exist in the JSON structure
          2. Test-JsonNullValues: Checks if all required properties have non-null values
        - Function will terminate script execution with exit code 1 if any validation phase fails
        - Validation covers 25 input.json properties and 36+ supervisor.json properties across multiple categories
        - Both JSON files must be valid JSON format and contain all required nested properties with non-null values
        - Validation includes deep property path checking (e.g., "common.argoCD.nameSpace", "tkgsComponentSpec.foundationLoadBalancerComponents.flbName")
        - Missing properties are reported with detailed expected structure information for troubleshooting
        - Null values are reported with clear error messages indicating which properties have null values

        Validation Order:
        1. Check if JSON files exist and are parseable
        2. Validate supervisor.json for missing properties
        3. Validate input.json for missing properties
        4. Validate supervisor.json for null values
        5. Validate input.json for null values
        6. Exit with error if any validation fails, otherwise proceed with deployment
    #>

    # Define required properties for input.json validation.
    # This array contains all mandatory property paths that must exist in the input.json configuration file.
    # Properties are organized by functional areas: ArgoCD, Infrastructure, Storage, Content Library, and Networking.

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$InfrastructureJson,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$SupervisorJson
    )

    Write-LogMessage -Type DEBUG -Message "Entered Test-JsonShallowValidation function..."

    $infrastructureJsonRequiredProperties = @(
        # ArgoCD Configuration Properties (7 properties)
        "common.argoCD.contextName",                # Kubernetes context name for ArgoCD
        "common.argoCD.nameSpace",                  # Namespace where ArgoCD will be deployed
        "common.argoCD.vmClass",                    # VM class for ArgoCD workloads
        "common.argoCD.argoCdOperatorYamlPath",     # Path to ArgoCD configuration YAML
        "common.argoCD.argoCdDeploymentYamlPath",   # Path to the ArgoCD deployment YAML

        # Infrastructure Configuration Properties (6 properties)
        "common.clusterName",                       # Name of the vSphere cluster
        "common.datacenterName",                    # Name of the vSphere datacenter
        "common.esxHost",                           # FQDN/IP of the ESX host
        "common.esxUser",                           # Username for ESX host authentication
        "common.vCenterName",                       # FQDN/IP of the vCenter
        "common.VcenterUser",                       # Username for vCenter authentication

        # Storage Configuration Properties (5 properties)
        "common.datastore.datastoreName",           # Name of the datastore to create
        "common.storagepolicy.storagePolicyTagCatalog", # Name of the storage policy tag catalog
        "common.storagepolicy.storagePolicyName",   # Name of the storage policy
        "common.storagepolicy.storagePolicyRule",   # Storage policy rule definition
        "common.storagepolicy.storagePolicyType",   # Type of storage policy (e.g., VMFS)

        # Virtual Distributed Switch Configuration Properties (5 properties)
        "common.virtualDistributedSwitch.nicList",      # List of physical NICs for the VDS
        "common.virtualDistributedSwitch.numUplinks",   # Number of uplink ports
        "common.virtualDistributedSwitch.portGroups",   # Array of port group configurations
        "common.virtualDistributedSwitch.vdsName",      # Name of the virtual distributed switch
        "common.virtualDistributedSwitch.vdsVersion"    # Version of the VDS
    )

    # Define required properties for supervisor.json validation.
    # This array contains all mandatory property paths for TKGS supervisor cluster configuration.
    # Properties cover supervisor specs, load balancer components, and network configurations.

    $supervisorJsonRequiredProperties = @(
        # Supervisor Specification Properties (5 properties)
        "supervisorSpec.controlPlaneVMCount",       # Number of control plane VMs
        "supervisorSpec.controlPlaneSize",          # Size specification for control plane VMs

        # Foundation Load Balancer Base Configuration (9 properties)
        "tkgsComponentSpec.foundationLoadBalancerComponents.flbName",           # Load balancer name
        "tkgsComponentSpec.foundationLoadBalancerComponents.flbSize",           # Load balancer size (small/medium/large)
        "tkgsComponentSpec.foundationLoadBalancerComponents.flbAvailability",   # Availability configuration
        "tkgsComponentSpec.foundationLoadBalancerComponents.flbVipStartIP",     # Starting IP for VIP range
        "tkgsComponentSpec.foundationLoadBalancerComponents.flbVipIPCount",     # Number of VIP addresses
        "tkgsComponentSpec.foundationLoadBalancerComponents.flbProvider",       # Load balancer provider
        "tkgsComponentSpec.foundationLoadBalancerComponents.flbDnsServers",     # DNS servers for load balancer
        "tkgsComponentSpec.foundationLoadBalancerComponents.flbNtpServers",     # NTP servers for load balancer
        "tkgsComponentSpec.foundationLoadBalancerComponents.flbSearchDomains",  # Search domains for DNS resolution
        # Foundation Load Balancer Management Network Configuration (8 properties)
        "tkgsComponentSpec.foundationLoadBalancerComponents.flbManagementNetwork.flbNetworkIpAssignmentMode",    # IP assignment mode (static/dhcp)
        "tkgsComponentSpec.foundationLoadBalancerComponents.flbManagementNetwork.flbNetworkName",                # Management network name
        "tkgsComponentSpec.foundationLoadBalancerComponents.flbManagementNetwork.flbNetworkType",                # Network type
        "tkgsComponentSpec.foundationLoadBalancerComponents.flbManagementNetwork.flbNetworkIpAddressStartingIp", # Starting IP for management network
        "tkgsComponentSpec.foundationLoadBalancerComponents.flbManagementNetwork.flbNetworkIpAddressCount",      # Number of IPs in management network range
        "tkgsComponentSpec.foundationLoadBalancerComponents.flbManagementNetwork.flbNetworkGateway",             # Gateway for management network

        # Foundation Load Balancer Virtual Server Network Configuration (8 properties)
        "tkgsComponentSpec.foundationLoadBalancerComponents.flbVirtualServerNetwork.flbNetworkIpAssignmentMode",    # IP assignment mode for virtual server network
        "tkgsComponentSpec.foundationLoadBalancerComponents.flbVirtualServerNetwork.flbNetworkName",                # Virtual server network name
        "tkgsComponentSpec.foundationLoadBalancerComponents.flbVirtualServerNetwork.flbNetworkType",                # Virtual server network type
        "tkgsComponentSpec.foundationLoadBalancerComponents.flbVirtualServerNetwork.flbNetworkIpAddressStartingIp", # Starting IP for virtual server network
        "tkgsComponentSpec.foundationLoadBalancerComponents.flbVirtualServerNetwork.flbNetworkIpAddressCount",      # Number of IPs in virtual server network range
        "tkgsComponentSpec.foundationLoadBalancerComponents.flbVirtualServerNetwork.flbNetworkGateway",             # Gateway for virtual server network
        # TKGS Management Network Specification (9 properties)
        "tkgsComponentSpec.tkgsMgmtNetworkSpec.tkgsMgmtIpAssignmentMode",       # IP assignment mode for TKGS management network
        "tkgsComponentSpec.tkgsMgmtNetworkSpec.tkgsMgmtNetworkName",            # Name of the TKGS management network
        "tkgsComponentSpec.tkgsMgmtNetworkSpec.tkgsMgmtNetworkGatewayCidr",     # Gateway CIDR for TKGS management network
        "tkgsComponentSpec.tkgsMgmtNetworkSpec.tkgsMgmtNetworkStartingIp",      # Starting IP address for TKGS management network
        "tkgsComponentSpec.tkgsMgmtNetworkSpec.tkgsMgmtNetworkIPCount",         # Number of IP addresses for TKGS management network
        "tkgsComponentSpec.tkgsMgmtNetworkSpec.tkgsMgmtNetworkDnsServers",      # DNS servers for TKGS management network
        "tkgsComponentSpec.tkgsMgmtNetworkSpec.tkgsMgmtNetworkSearchDomains",   # Search domains for TKGS management network
        "tkgsComponentSpec.tkgsMgmtNetworkSpec.tkgsMgmtNetworkNtpServers",      # NTP servers for TKGS management network

        # TKGS Primary Workload Network Specification (10 properties)
        "tkgsComponentSpec.tkgsPrimaryWorkloadNetwork.tkgsPrimaryWorkloadIpAssignmentMode",        # IP assignment mode for primary workload network
        "tkgsComponentSpec.tkgsPrimaryWorkloadNetwork.tkgsPrimaryWorkloadNetworkSearchDomains",    # Search domains for primary workload network
        "tkgsComponentSpec.tkgsPrimaryWorkloadNetwork.tkgsPrimaryWorkloadNetworkName",             # Name of the primary workload network
        "tkgsComponentSpec.tkgsPrimaryWorkloadNetwork.tkgsPrimaryWorkloadNetworkGatewayCidr",      # Gateway CIDR for primary workload network
        "tkgsComponentSpec.tkgsPrimaryWorkloadNetwork.tkgsPrimaryWorkloadNetworkStartingIp",       # Starting IP address for primary workload network
        "tkgsComponentSpec.tkgsPrimaryWorkloadNetwork.tkgsPrimaryWorkloadNetworkIPCount",          # Number of IP addresses for primary workload network
        "tkgsComponentSpec.tkgsPrimaryWorkloadNetwork.tkgsWorkloadDnsServers",                     # DNS servers for workload network
        "tkgsComponentSpec.tkgsPrimaryWorkloadNetwork.tkgsWorkloadNtpServers",                     # NTP servers for workload network
        "tkgsComponentSpec.tkgsPrimaryWorkloadNetwork.tkgsWorkloadServiceStartIp",                 # Starting IP for workload services
        "tkgsComponentSpec.tkgsPrimaryWorkloadNetwork.tkgsWorkloadServiceCount"                    # Number of service IP addresses for workloads
    )

    # Validate supervisor.json against required properties schema.
    Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "Validating $SupervisorJson configuration file..."
    $supervisorDataValidationResult = Test-JsonMissingProperties -JsonFilePath $SupervisorJson -RequiredProperties $supervisorJsonRequiredProperties -JsonObjectName "SupervisorConfiguration" -ShowExpectedStructure

    # Validate input.json against required properties schema.
    Write-LogMessage -Type INFO -SuppressOutputToScreen  -Message "Validating $InfrastructureJson configuration file..."
    $inputDataValidationResult = Test-JsonMissingProperties -JsonFilePath $InfrastructureJson -RequiredProperties $infrastructureJsonRequiredProperties -JsonObjectName "InputConfiguration" -ShowExpectedStructure

    # Check input.json validation results and handle accordingly.
    if (-Not $inputDataValidationResult.IsValid) {
        Write-LogMessage -Type ERROR -Message "Input JSON validation failed: $($inputDataValidationResult.Summary)"
        Write-LogMessage -Type ERROR -Message "Deployment cannot proceed with incomplete input configuration. Please fix the missing properties and try again."
        throw "Deployment failed. Check logs for details."
    } else {
        Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "Input JSON validation passed: $($inputDataValidationResult.Summary)"
    }

    # Check supervisor.json validation results and handle accordingly.
    if (-Not $supervisorDataValidationResult.IsValid) {
        Write-LogMessage -Type ERROR -Message "Supervisor JSON validation failed: $($supervisorDataValidationResult.Summary)"
        Write-LogMessage -Type ERROR -Message "Deployment cannot proceed with incomplete supervisor configuration. Please fix the missing properties and try again."
        throw "Deployment failed. Check logs for details."
    } else {
        Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "Supervisor JSON validation passed: $($supervisorDataValidationResult.Summary)"
    }

    # Validate supervisor.json for null values.
    Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "Validating $SupervisorJson for null values..."
    $supervisorNullValidationResult = Test-JsonNullValues -JsonFilePath $SupervisorJson -RequiredProperties $supervisorJsonRequiredProperties -JsonObjectName "SupervisorConfiguration"

    # Validate input.json for null values.
    Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "Validating $InfrastructureJson for null values..."
    $inputNullValidationResult = Test-JsonNullValues -JsonFilePath $InfrastructureJson -RequiredProperties $infrastructureJsonRequiredProperties -JsonObjectName "InputConfiguration"

    # Check input.json null value validation results.
    if (-Not $inputNullValidationResult.IsValid) {
        Write-LogMessage -Type ERROR -Message "Input JSON null value validation failed: $($inputNullValidationResult.Summary)"
        Write-LogMessage -Type ERROR -Message "Deployment cannot proceed with null values in input configuration. Please provide valid values for all required properties."
        throw "Deployment failed. Check logs for details."
    } else {
        Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "Input JSON null value validation passed: $($inputNullValidationResult.Summary)"
    }

    # Check supervisor.json null value validation results.
    if (-Not $supervisorNullValidationResult.IsValid) {
        Write-LogMessage -Type ERROR -Message "Supervisor JSON null value validation failed: $($supervisorNullValidationResult.Summary)"
        Write-LogMessage -Type ERROR -Message "Deployment cannot proceed with null values in supervisor configuration. Please provide valid values for all required properties."
        throw "Deployment failed. Check logs for details."
    } else {
        Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "Supervisor JSON null value validation passed: $($supervisorNullValidationResult.Summary)"
    }

    # If all validation results are valid, write a success message.
    if ($inputDataValidationResult.IsValid -and $supervisorDataValidationResult.IsValid -and $inputNullValidationResult.IsValid -and $supervisorNullValidationResult.IsValid) {
        Write-LogMessage -PrependNewLine -Type INFO -Message "JSON configuration file validation completed successfully."
    }
}

Function Test-IpAddressInCidrRange {

    <#
        .SYNOPSIS
        Tests if an IP address falls within a specified CIDR network range.

        .DESCRIPTION
        The Test-IpAddressInCidrRange function validates whether a given IP address
        is contained within a specified CIDR network range. This is useful for validating
        that starting IP addresses, gateway addresses, or other IP configurations fall
        within expected network boundaries.

        The function performs the following validation:
        1. Validates the format of both the IP address and CIDR notation
        2. Parses the CIDR range to extract network address and subnet mask
        3. Converts both IP addresses to binary format for comparison
        4. Applies the subnet mask to determine network membership
        5. Returns true if the IP is within the range, false otherwise

        .PARAMETER IpAddress
        The IP address to test (e.g., "192.168.1.100"). Must be a valid IPv4 address.

        .PARAMETER CidrRange
        The CIDR network range (e.g., "192.168.1.0/24"). Must be in valid CIDR notation
        with format: IP/prefix where prefix is 0-32.

        .EXAMPLE
        Test-IpAddressInCidrRange -IpAddress "192.168.1.100" -CidrRange "192.168.1.0/24"
        Returns $true because 192.168.1.100 is within the 192.168.1.0/24 network.

        .EXAMPLE
        Test-IpAddressInCidrRange -IpAddress "10.0.0.5" -CidrRange "192.168.1.0/24"
        Returns $false because 10.0.0.5 is not within the 192.168.1.0/24 network.

        .EXAMPLE
        Test-IpAddressInCidrRange -IpAddress "172.16.50.1" -CidrRange "172.16.0.0/16"
        Returns $true because 172.16.50.1 is within the 172.16.0.0/16 network.

        .OUTPUTS
        Boolean
        Returns $true if the IP address is within the CIDR range, $false otherwise.

        .NOTES
        This function only supports IPv4 addresses and CIDR notation.
        The function validates input formats before performing range checks.

    #>

    Param(
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$IpAddress,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$CidrRange

    )

    Write-LogMessage -Type DEBUG -Message "Entered Test-IpAddressInCidrRange function..."

    try {
        # Validate IP address format.

        if ($IpAddress -notmatch '^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$') {
            Write-LogMessage -Type ERROR -Message "Invalid IP address format: $IpAddress"
            return $false
        }

        # Validate CIDR range format.

        if ($CidrRange -notmatch '^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\/([0-9]|[1-2][0-9]|3[0-2])$') {
            Write-LogMessage -Type ERROR -Message "Invalid CIDR range format: $CidrRange"
            return $false
        }

        # Split CIDR into network address and prefix length.

        $cidrParts = $CidrRange.Split('/')
        $networkAddress = $cidrParts[0]
        $prefixLength = [int]$cidrParts[1]

        # Convert IP addresses to 32-bit integers.

        Function ConvertTo-IpInt {
            param([String]$IpString)
            $octets = $IpString.Split('.')
            return ([int64]$octets[0] -shl 24) -bor ([int64]$octets[1] -shl 16) -bor ([int64]$octets[2] -shl 8) -bor [int64]$octets[3]
        }

        # Calculate subnet mask from prefix length.

        if ($prefixLength -eq 0) {
            $subnetMask = 0
        } else {
            $subnetMask = [int64][Math]::Pow(2, 32) - [int64][Math]::Pow(2, (32 - $prefixLength))
        }

        # Convert addresses to integers.

        $ipInt = ConvertTo-IpInt -IpString $IpAddress
        $networkInt = ConvertTo-IpInt -IpString $networkAddress

        # Apply subnet mask to both addresses.

        $ipNetwork = $ipInt -band $subnetMask
        $cidrNetwork = $networkInt -band $subnetMask

        # Check if the IP is in the same network.

        $isInRange = ($ipNetwork -eq $cidrNetwork)

        if ($isInRange) {
            Write-LogMessage -Type DEBUG -Message "IP address $IpAddress is within CIDR range $CidrRange"
        } else {
            Write-LogMessage -Type DEBUG -Message "IP address $IpAddress is NOT within CIDR range $CidrRange"
        }

        return $isInRange
    }
    catch {
        Write-LogMessage -Type ERROR -Message "Error checking IP address range: $_"
        return $false
    }
}

Function Get-JsonPropertyValue {

    <#
        .SYNOPSIS
        Extracts a property value from a JSON object using dot-notation path.

        .DESCRIPTION
        The Get-JsonPropertyValue function navigates nested JSON objects, PSCustomObjects, or Hashtables
        using a dot-notation property path (e.g., "parent.child.property") and returns the value as a string.
        This helper function separates the concern of property extraction from validation logic.

        .PARAMETER InputData
        The input data object (JSON, PSCustomObject, Hashtable, or String) to extract the value from.

        .PARAMETER PropertyPath
        Optional. The dot-notation path to the property (e.g., "common.vCenterName"). If not specified
        and InputData is a string, returns the string directly. If not specified and InputData is an
        object, converts the entire object to a string.

        .OUTPUTS
        System.String
        Returns the extracted property value as a string, or $null if extraction fails.

        .EXAMPLE
        $value = Get-JsonPropertyValue -InputData $config -PropertyPath "common.vCenterName"
        Extracts the vCenterName property from the common section of the config object.

        .NOTES
        This is a helper function used by Test-JsonPropertyFormat to separate property extraction
        from validation logic, improving testability and maintainability.

    #>

    Param (
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$PropertyPath,
        [Parameter(Mandatory = $true)] [AllowNull()] [AllowEmptyString()] $InputData

    )

    Write-LogMessage -Type DEBUG -Message "Entered Get-JsonPropertyValue function..."

    try {
        # Handle null input
        if ($null -eq $InputData) {
            Write-LogMessage -Type ERROR -SuppressOutputToScreen -Message "Input data is null"
            return $null
        }

        # If inputData is already a string, return it directly.

        if ($InputData -is [String]) {
            Write-LogMessage -Type DEBUG -Message "Input is already a string with length: $($InputData.Length)"
            return $InputData
        }

        # If propertyPath is specified, extract the property value.

        if ($PropertyPath) {
            Write-LogMessage -Type DEBUG -Message "Extracting property '$PropertyPath' from input object"

            # Split property path by dots to navigate nested properties.

            $pathParts = $PropertyPath.Split('.')
            $currentObject = $InputData

            foreach ($part in $pathParts) {
                if ($null -eq $currentObject) {
                    Write-LogMessage -Type ERROR -SuppressOutputToScreen -Message "Property path '$PropertyPath' contains null value at '$part'"
                    return $null
                }

                # Handle PSCustomObject, Hashtable, and regular object property access.

                if ($currentObject -is [PSCustomObject]) {
                    $currentObject = $currentObject.$part
                } elseif ($currentObject -is [Hashtable]) {
                    $currentObject = $currentObject[$part]
                } else {
                    try {
                        $currentObject = $currentObject.$part
                    } catch {
                        Write-LogMessage -Type ERROR -SuppressOutputToScreen -Message "Cannot access property '$part' in path '$PropertyPath': $($_.Exception.Message)"
                        return $null
                    }
                }
            }

            # Convert the final property value to string.

            $result = if ($null -eq $currentObject) { "" } else { $currentObject.ToString() }
            Write-LogMessage -Type DEBUG -Message "Extracted value: '$result' (length: $($result.Length))"
            return $result
        }
        # If no propertyPath specified, convert entire object to string.

        else {
            $result = $InputData.ToString()
            Write-LogMessage -Type DEBUG -Message "Converted entire object to string (length: $($result.Length))"
            return $result
        }
    }
    catch {
        Write-LogMessage -Type ERROR -SuppressOutputToScreen -Message "Error extracting property value: $($_.Exception.Message)"
        return $null
    }
}

Function Get-ValidationPresetRules {

    <#
        .SYNOPSIS
        Returns validation rules for predefined validation presets.

        .DESCRIPTION
        The Get-ValidationPresetRules function maps validation preset names to their corresponding
        validation rules (allowed characters, regex patterns, etc.). This separates preset definition
        logic from the main validation orchestration, improving maintainability and extensibility.

        .PARAMETER ValidationPreset
        The name of the validation preset to retrieve rules for.

        .OUTPUTS
        System.Collections.Hashtable
        Returns a hashtable containing validation rules with keys:
        - AllowedCharacters: String of allowed characters (if applicable)
        - DisallowedCharacters: String of disallowed characters (if applicable)
        - RegexPattern: Regular expression pattern (if applicable)

        .EXAMPLE
        $rules = Get-ValidationPresetRules -ValidationPreset "IpAddress"
        Returns rules for IP address validation including the regex pattern.

        .NOTES
        This is a helper function used by Test-JsonPropertyFormat to separate preset logic
        from validation execution, making it easier to add or modify presets.

    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateSet("AlphaNumeric", "AlphaNumericDash", "Numeric", "FileName", "UserName", "DomainName", "IpAddress", "IpAddressWithCidr", "IpAddressOrDomainNameWithPort", "Email", "lowerCaseRfc1123PortGroup", "FilePath", "vSphereObject80Characters")] [String]$ValidationPreset
    )

    Write-LogMessage -Type DEBUG -Message "Entered Get-ValidationPresetRules function..."

    $rules = @{
        AllowedCharacters = $null
        DisallowedCharacters = $null
        RegexPattern = $null
    }

    switch ($ValidationPreset) {
        "AlphaNumeric" {
            $rules.AllowedCharacters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        }
        "AlphaNumericDash" {
            $rules.AllowedCharacters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"
        }
        "Numeric" {
            $rules.AllowedCharacters = "0123456789"
        }
        "FileName" {
            $rules.DisallowedCharacters = '<>:"/\|?*'
        }
        "UserName" {
            $rules.AllowedCharacters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_"
        }
        "DomainName" {
            $rules.RegexPattern = '^[a-zA-Z0-9][a-zA-Z0-9\-\.]*[a-zA-Z0-9]$'
        }
        "IpAddressOrDomainNameWithPort" {
            $rules.RegexPattern = '^(?:(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)|(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)*[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?):(?:[1-9][0-9]{0,3}|[1-5][0-9]{4}|6[0-4][0-9]{3}|65[0-4][0-9]{2}|655[0-2][0-9]|6553[0-5])$'
        }
        "IpAddress" {
            $rules.RegexPattern = '^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$'
        }
        "IpAddressWithCidr" {
            $rules.RegexPattern = '^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\/([0-9]|[1-2][0-9]|3[0-2])$'
        }
        "Email" {
            $rules.RegexPattern = '^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$'
        }
        "lowerCaseRfc1123PortGroup" {
            $rules.RegexPattern = '^(?=.{1,80}$)[a-z0-9]([-a-z0-9]*[a-z0-9])?$'
        }
        "FilePath" {
            # Cross-platform file path regex supporting Windows, Linux, and macOS.

            $rules.RegexPattern = '^(?:(?:[a-zA-Z]:)?[\\\/]|\.{0,2}[\\\/]|\\\\[^\\\/\s]+[\\\/][^\\\/\s]+[\\\/])?(?:[^<>:"|?*\x00-\x1f\\\/]+[\\\/])*[^<>:"|?*\x00-\x1f\\\/]*$'
        }
        "vSphereObject80Characters" {
            # vSphere object name validation: alphanumeric, hyphen, underscore, plus sign, spaces, parentheses
            $rules.RegexPattern = '^[a-zA-Z0-9\s_+\-()]{1,80}$'
        }
    }

    Write-LogMessage -Type DEBUG -Message "Retrieved validation rules for preset '$ValidationPreset'"
    return $rules
}

Function Test-StringAgainstAllowlist {

    <#
        .SYNOPSIS
        Validates that a string contains only allowed characters.

        .DESCRIPTION
        The Test-StringAgainstAllowlist function checks each character in the input string
        against an allowlist of permitted characters. This implements a secure allowlist
        validation approach.

        .PARAMETER InputText
        The string to validate.

        .PARAMETER AllowedCharacters
        A string containing all characters that are permitted in the input.

        .OUTPUTS
        System.Boolean
        Returns $true if all characters in InputText are in the allowlist, $false otherwise.

        .EXAMPLE
        $isValid = Test-StringAgainstAllowlist -InputText "Server01" -AllowedCharacters "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        Validates that Server01 contains only alphanumeric characters.

        .NOTES
        This is a helper function used by Test-JsonPropertyFormat to separate allowlist
        validation logic from orchestration.

    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$InputText,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$AllowedCharacters

    )

    Write-LogMessage -Type DEBUG -Message "Entered Test-StringAgainstAllowlist function..."

    Write-LogMessage -Type DEBUG -Message "Validating string against allowed characters allowlist"

    foreach ($char in $InputText.ToCharArray()) {
        if ($AllowedCharacters.IndexOf($char.ToString()) -eq -1) {
            Write-LogMessage -Type ERROR -Message "Character '$char' is not in the allowed character set"
            return $false
        }
    }

    Write-LogMessage -Type DEBUG -Message "Allowlist validation passed"
    return $true
}

Function Test-StringAgainstDenylist {

    <#
        .SYNOPSIS
        Validates that a string does not contain forbidden characters.

        .DESCRIPTION
        The Test-StringAgainstDenylist function checks that the input string does not
        contain any characters from a denylist of forbidden characters.

        .PARAMETER InputText
        The string to validate.

        .PARAMETER DisallowedCharacters
        A string containing characters that are not permitted in the input.

        .OUTPUTS
        System.Boolean
        Returns $true if no forbidden characters are found, $false otherwise.

        .EXAMPLE
        $isValid = Test-StringAgainstDenylist -InputText "MyFile.txt" -DisallowedCharacters '<>:"/\|?*'
        Validates that the filename doesn't contain filesystem-unsafe characters.

        .NOTES
        This is a helper function used by Test-JsonPropertyFormat to separate denylist
        validation logic from orchestration.

    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$InputText,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$DisallowedCharacters

    )

    Write-LogMessage -Type DEBUG -Message "Entered Test-StringAgainstDenylist function..."

    Write-LogMessage -Type DEBUG -Message "Validating string against disallowed characters denylist"

    foreach ($char in $InputText.ToCharArray()) {
        if ($DisallowedCharacters.IndexOf($char.ToString()) -ne -1) {
            Write-LogMessage -Type ERROR -Message "Character '$char' is not allowed (found in disallowed character set)"
            return $false
        }
    }

    Write-LogMessage -Type DEBUG -Message "Denylist validation passed"
    return $true
}

Function Test-AcceptableStrings {

    <#
        .SYNOPSIS
        Validates that a string matches one of the acceptable values.

        .DESCRIPTION
        The Test-AcceptableStrings function checks if the input string exactly matches
        one of the strings in an acceptable values list. This implements enumerated
        value validation for controlled vocabularies.

        .PARAMETER InputText
        The string to validate.

        .PARAMETER AcceptableStrings
        An array of strings that are considered acceptable values.

        .PARAMETER PropertyPath
        Optional. The property path for error messages.

        .OUTPUTS
        System.Boolean
        Returns $true if the input matches one of the acceptable strings, $false otherwise.

        .EXAMPLE
        $isValid = Test-AcceptableStrings -inputText "SMALL" -acceptableStrings @("TINY", "SMALL", "MEDIUM", "LARGE")
        Validates that the control plane size is one of the acceptable values.

        .NOTES
        This is a helper function used by Test-JsonPropertyFormat to separate acceptable
        strings validation logic from orchestration. Uses ordinal comparison for consistency.

    #>

    Param (
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$PropertyPath,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [String]$InputText,

        [Parameter(Mandatory = $true)] [ValidateNotNull()] [String[]]$AcceptableStrings
    )

    Write-LogMessage -Type DEBUG -Message "Entered Test-AcceptableStrings function..."

    Write-LogMessage -Type DEBUG -Message "Validating against list of acceptable strings: $($AcceptableStrings -join ', ')"

    $stringComparison = [System.StringComparison]::Ordinal
    foreach ($acceptableString in $AcceptableStrings) {
        if ([String]::Equals($InputText, $acceptableString, $stringComparison)) {
            Write-LogMessage -Type DEBUG -Message "Matched acceptable string: '$acceptableString'"
            return $true
        }
    }

    # Build error message with optional property path.
    $pathInfo = if ($PropertyPath) { " for JSON property `"$PropertyPath`"" } else { "" }
    Write-LogMessage -Type ERROR -Message "Validation failed for input value `"$InputText`"${pathInfo}. It should be one of: $($AcceptableStrings -join ', ')"
    return $false
}

Function Test-NumericRange {

    <#
        .SYNOPSIS
        Validates that a numeric value falls within a specified range.

        .DESCRIPTION
        The Test-NumericRange function converts a string to a numeric value and validates
        that it falls within specified minimum and maximum bounds. Supports validation
        against minimum only, maximum only, or both.

        .PARAMETER InputText
        The string representation of the numeric value to validate.

        .PARAMETER MinValue
        Optional. The minimum acceptable value.

        .PARAMETER MaxValue
        Optional. The maximum acceptable value.

        .PARAMETER PropertyPath
        Optional. The property path for error messages.

        .OUTPUTS
        System.Boolean
        Returns $true if the value is numeric and within the specified range, $false otherwise.

        .EXAMPLE
        $isValid = Test-NumericRange -InputText "5" -MinValue 1 -MaxValue 10
        Validates that the value is between 1 and 10.

        .NOTES
        This is a helper function used by Test-JsonPropertyFormat to separate numeric
        range validation logic from orchestration.

    #>

    Param (
        [Parameter(Mandatory = $false)] [Double]$MaxValue,
        [Parameter(Mandatory = $false)] [Double]$MinValue,

        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$PropertyPath,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$InputText
    )

    Write-LogMessage -Type DEBUG -Message "Entered Test-NumericRange function..."

    Write-LogMessage -Type DEBUG -Message "Validating numeric range for value: '$InputText'"

    # Attempt to convert input to numeric.
    $numericValue = $null
    $isNumeric = [Double]::TryParse($InputText, [ref]$numericValue)

    if (-not $isNumeric) {
        $pathInfo = if ($PropertyPath) { " for property '$PropertyPath'" } else { "" }
        Write-LogMessage -Type ERROR -Message "Numeric validation failed${pathInfo}: Value '$InputText' is not a valid number"
        return $false
    }

    # Check minimum value.
    if ($PSBoundParameters.ContainsKey('MinValue') -and $numericValue -lt $MinValue) {
        $pathInfo = if ($PropertyPath) { " for property '$PropertyPath'" } else { "" }
        Write-LogMessage -Type ERROR -Message "Numeric validation failed${pathInfo}: Value $numericValue is below minimum $MinValue"
        return $false
    }

    # Check maximum value.
    if ($PSBoundParameters.ContainsKey('MaxValue') -and $numericValue -gt $MaxValue) {
        $pathInfo = if ($PropertyPath) { " for property '$PropertyPath'" } else { "" }
        Write-LogMessage -Type ERROR -Message "Numeric validation failed${pathInfo}: Value $numericValue exceeds maximum $MaxValue"
        return $false
    }

    Write-LogMessage -Type DEBUG -Message "Numeric range validation passed for value: $numericValue"
    return $true
}

Function Test-ValidCidrRange {

    <#
        .SYNOPSIS
        Validates that an IP count corresponds to a valid CIDR block range.

        .DESCRIPTION
        The Test-ValidCidrRange function checks if a given IP address count corresponds to a valid
        CIDR range (/8 to /32). The value must be a power of 2 AND within the valid range.
        This ensures IP address counts correspond to complete, valid CIDR blocks.

        Valid CIDR ranges (IPv4):
        - 1 IP = 2^0 = /32 (single host)
        - 2 IPs = 2^1 = /31 (point-to-point)
        - 4 IPs = 2^2 = /30
        - 8 IPs = 2^3 = /29
        - 16 IPs = 2^4 = /28
        - 32 IPs = 2^5 = /27
        - 64 IPs = 2^6 = /26
        - 128 IPs = 2^7 = /25
        - 256 IPs = 2^8 = /24
        - 512 IPs = 2^9 = /23
        - 1024 IPs = 2^10 = /22
        - ... up to ...
        - 16,777,216 IPs = 2^24 = /8 (maximum)

        Values larger than 16,777,216 (e.g., 2^25 = 33,554,432) are powers of 2 but correspond
        to CIDR prefixes smaller than /8, which are invalid.

        .PARAMETER InputText
        The value to validate as a power of 2.

        .PARAMETER PropertyPath
        Optional. The property path for error messages.

        .OUTPUTS
        System.Boolean
        Returns $true if the value is a power of 2, $false otherwise.

        .EXAMPLE
        $isValid = Test-ValidCidrRange -InputText "512"
        Validates that "512" corresponds to a valid CIDR range (/23).
        Returns: $true

        .EXAMPLE
        $isValid = Test-ValidCidrRange -InputText "511"
        Validates that "511" corresponds to a valid CIDR range.
        Returns: $false (511 is not a power of 2)

        .EXAMPLE
        $isValid = Test-ValidCidrRange -InputText "33554432"
        Validates that "33554432" corresponds to a valid CIDR range.
        Returns: $false (would be /7, outside valid range)

        .NOTES
        The function uses bitwise AND operation to check if a number is a power of 2.
        A power of 2 in binary has exactly one bit set (e.g., 8 = 1000, 16 = 10000).
        The check (n & (n-1)) == 0 returns true only for powers of 2.

    #>

    Param (
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$PropertyPath,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$InputText

    )

    Write-LogMessage -Type DEBUG -Message "Entered Test-ValidCidrRange function..."

    Write-LogMessage -Type DEBUG -Message "Validating CIDR range for IP count: '$InputText'"

    # Attempt to parse as integer.
    $number = $null
    $isInteger = [int]::TryParse($InputText, [ref]$number)

    if (-not $isInteger) {
        $pathInfo = if ($PropertyPath) { " for property '$PropertyPath'" } else { "" }
        Write-LogMessage -Type ERROR -Message "CIDR range validation failed${pathInfo}: Value '$InputText' is not a valid integer"
        return $false
    }

    # Check if number is positive.
    if ($number -le 0) {
        $pathInfo = if ($PropertyPath) { " for property '$PropertyPath'" } else { "" }
        Write-LogMessage -Type ERROR -Message "CIDR range validation failed${pathInfo}: Value $number must be positive"
        return $false
    }

    # Check if number is a power of 2 using bitwise AND.
    # A power of 2 has only one bit set in binary representation.
    # Example: 8 = 1000, 8-1 = 0111, 1000 & 0111 = 0000.
    # Non-power: 7 = 0111, 7-1 = 0110, 0111 & 0110 = 0110 (not zero)
    $isPowerOfTwo = ($number -band ($number - 1)) -eq 0

    if (-not $isPowerOfTwo) {
        $pathInfo = if ($PropertyPath) { " for property '$PropertyPath'" } else { "" }

        # Calculate what CIDR block this would be if it were valid.

        $nearestLower = [Math]::Pow(2, [Math]::Floor([Math]::Log($number, 2)))
        $nearestUpper = [Math]::Pow(2, [Math]::Ceiling([Math]::Log($number, 2)))

        Write-LogMessage -Type ERROR -Message "CIDR range validation failed${pathInfo}: Value $number is not a power of 2 (not a complete CIDR block). Nearest valid values: $nearestLower or $nearestUpper"
        return $false
    }

    # Calculate equivalent CIDR prefix.
    $cidrPrefix = 32 - [Math]::Log($number, 2)

    # Validate that this corresponds to a valid CIDR range (/8 to /32)
    # /32 = 1 IP, /31 = 2 IPs, /30 = 4 IPs, ... /8 = 16,777,216 IPs
    if ($cidrPrefix -lt 8 -or $cidrPrefix -gt 32) {
        $pathInfo = if ($PropertyPath) { " for property '$PropertyPath'" } else { "" }
        Write-LogMessage -Type ERROR -Message "CIDR range validation failed${pathInfo}: Value $number corresponds to /$cidrPrefix which is outside valid CIDR range (/8 to /32). Valid IP counts: 1 to 16,777,216"
        return $false
    }

    Write-LogMessage -Type DEBUG -Message "CIDR range validation passed for value: $number (equivalent to /$cidrPrefix CIDR block)"
    return $true
}
Function Test-JsonPropertyFormat {

    <#
        .SYNOPSIS
        Validates input from JSON properties or text against specified character sets and patterns to ensure only valid characters are present.

        .DESCRIPTION
        The Test-JsonPropertyFormat function provides comprehensive input validation by checking JSON property values
        or direct text input against defined character sets, regular expressions, or predefined validation presets.
        This function helps ensure data integrity and security by preventing invalid characters from being processed
        by the application.

        The function supports multiple validation modes including allowlist character validation,
        denylist character exclusion, regular expression pattern matching, and common preset
        validations for typical use cases like filenames, usernames, and system identifiers.

        This function is essential for validating JSON configuration data and user input before processing
        it in scripts that interact with file systems, network resources, or other components that may be
        sensitive to special characters or injection attacks.

        .PARAMETER InputData
        The input data to validate. This parameter accepts either:
        - A JSON object/PSCustomObject with properties to validate
        - A string value to validate directly
        - A hashtable with key-value pairs to validate
        The function will extract string values from JSON properties or validate the string directly
        according to the validation rules provided.

        .PARAMETER PropertyPath
        Optional. When InputData is a JSON object, specifies the dot-notation path to the property to validate.
        For example: "common.vCenterName" or "supervisorSpec.controlPlaneSize". If not specified and InputData
        is an object, the function will attempt to convert the entire object to a string for validation.

        .PARAMETER AllowedCharacters
        A string containing all characters that are permitted in the input. When specified,
        the function will validate that the input contains only characters present in this set.
        This is a allowlist approach where only explicitly allowed characters pass validation.
        Example: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"

        .PARAMETER DisallowedCharacters
        A string containing characters that are not permitted in the input. When specified,
        the function will fail validation if any of these characters are found in the input.
        This is a denylist approach where specific characters are explicitly forbidden.
        Example: "<>:\"/\\|?*" (common filesystem-unsafe characters)

        .PARAMETER RegexPattern
        A regular expression pattern that the input must match. When specified, the entire
        input string must match this pattern for validation to succeed. This provides
        flexible pattern-based validation for complex requirements.
        Example: "^[a-zA-Z0-9][a-zA-Z0-9\-_.]*[a-zA-Z0-9]$" (valid hostname pattern)

        .PARAMETER ValidationPreset
        A predefined validation preset that applies common validation rules. Available presets:
        - AlphaNumeric: Letters and numbers only
        - AlphaNumericDash: Letters, numbers, hyphens, and underscores
        - Numeric: Numbers only (0-9)
        - FileName: Safe characters for file names (excludes filesystem-unsafe characters)
        - UserName: Common username format (alphanumeric, dots, hyphens, underscores)
        - DomainName: Valid domain name characters
        - IpAddress: Valid IP address format (IPv4)
        - IpAddressWithCidr: Valid IP address format with CIDR mask (IPv4/subnet)
        - Email: Basic email address format validation
        - lowerCaseRfc1123PortGroup: Valid RFC1123 hostname format (lowercase only)
        - FilePath: Cross-platform file path validation (Windows, Linux, macOS compatible)

        .PARAMETER MinLength
        The minimum required length for the input string. If specified, validation will fail
        if the input is shorter than this value. Defaults to 1 if not specified.

        .PARAMETER MaxLength
        The maximum allowed length for the input string. If specified, validation will fail
        if the input is longer than this value. No maximum limit if not specified.

        .PARAMETER CaseSensitive
        When specified, character validation will be case-sensitive. By default, validation
        is case-insensitive for character set matching. This parameter affects AllowedCharacters,
        DisallowedCharacters, and AcceptableStrings validation but not regular expression patterns.

        .PARAMETER AcceptableStrings
        An array of strings that are considered acceptable input values. When specified,
        the input must exactly match one of the strings in this array for validation to succeed.
        This provides a simple allowlist approach for validating against a predefined set of
        acceptable values. The comparison respects the CaseSensitive parameter.
        Example: @("Development", "Testing", "Production")

        .OUTPUTS
        System.Boolean
        Returns $true if the input passes all specified validation criteria, or $false if
        any validation rule fails. The function logs detailed information about validation
        failures for troubleshooting purposes.

        .EXAMPLE
        $isValid = Test-JsonPropertyFormat -InputData "MyFileName123" -ValidationPreset "FileName"
        Validates that the input string contains only characters safe for use in file names.

        .EXAMPLE
        $isValid = Test-JsonPropertyFormat -InputData "12345" -ValidationPreset "Numeric"
        Validates that the input string contains only numeric characters (0-9).

        .EXAMPLE
        $isValid = Test-JsonPropertyFormat -inputData $JsonFilePathConfig -propertyPath "common.vCenterName" -validationPreset "DomainName"
        Validates that the vCenter name from JSON configuration follows domain name format rules.

        .EXAMPLE
        $isValid = Test-JsonPropertyFormat -inputData $InputData -propertyPath "common.esxHost" -validationPreset "IpAddressOrDomainNameWithPort"
        Validates that the ESX host property from JSON contains a valid IP address or domain name with optional port.

        .EXAMPLE
        $isValid = Test-JsonPropertyFormat -inputData "ServerName-01" -allowedCharacters "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_" -minLength 3 -maxLength 15
        Validates server name string with specific character allowlist and length constraints.

        .EXAMPLE
        $isValid = Test-JsonPropertyFormat -inputData $config -propertyPath "datastore.datastoreName" -disallowedCharacters "<>:\"/\\|?*" -maxLength 50
        Validates datastore name from JSON by excluding filesystem-unsafe characters with a maximum length limit.

        .EXAMPLE
        $isValid = Test-JsonPropertyFormat -inputData $supervisorConfig -propertyPath "tkgsComponentSpec.foundationLoadBalancerComponents.flbVipStartIP" -validationPreset "IpAddress"
        Validates that the load balancer VIP start IP from JSON is a properly formatted IPv4 address.

        .EXAMPLE
        $isValid = Test-JsonPropertyFormat -inputData "192.168.1.0/24" -validationPreset "IpAddressWithCidr"
        Validates that the input string is a properly formatted IPv4 address with CIDR notation (e.g., 192.168.1.0/24).

        .EXAMPLE
        $isValid = Test-JsonPropertyFormat -inputData "my-domain-name.local" -regexPattern "^[a-zA-Z0-9][a-zA-Z0-9\-\.]*[a-zA-Z0-9]$" -minLength 4
        Validates input string against a custom regular expression pattern with minimum length requirement.

        .EXAMPLE
        $isValid = Test-JsonPropertyFormat -inputData $config -propertyPath "supervisorSpec.controlPlaneSize" -acceptableStrings @("TINY", "SMALL", "MEDIUM", "LARGE")
        Validates that the control plane size from JSON matches one of the acceptable string values.

        .EXAMPLE
        $isValid = Test-JsonPropertyFormat -inputData "TINY" -acceptableStrings @("tiny", "small", "medium", "large") -caseSensitive
        Validates input against acceptable strings with case-sensitive matching.

        .EXAMPLE
        $isValid = Test-JsonPropertyFormat -inputData "C:\Program Files\VMware\vCenter" -validationPreset "FilePath"
        Validates that the input string is a valid cross-platform file path (supports Windows, Linux, and macOS formats).

        .NOTES
        This function provides comprehensive logging of validation attempts and failures for
        troubleshooting purposes. When validation fails, specific details about which criteria
        failed are logged to help identify the issue. The function handles edge cases such as
        empty input, null values, and conflicting validation parameters gracefully.

        The function supports flexible input types:
        - Direct string validation: Pass a string directly to inputData
        - JSON property validation: Pass a JSON object/PSCustomObject to inputData with a propertyPath
        - Hashtable validation: Pass a hashtable to inputData with a propertyPath using dot notation

        Property path navigation supports nested objects using dot notation (e.g., "common.vCenterName"
        or "supervisorSpec.controlPlaneSize"). The function automatically handles PSCustomObject and
        Hashtable property access patterns.

        For security-sensitive applications, consider using the most restrictive validation
        approach appropriate for your use case. allowlist validation (allowedCharacters or
        acceptableStrings) is generally more secure than denylist validation (disallowedCharacters).

        The acceptableStrings parameter provides a simple and secure way to validate against
        a predefined set of acceptable values, which is particularly useful for configuration
        parameters, environment names, or other controlled vocabularies.
    #>

    Param (
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String[]]$AcceptableStrings,
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$allowedCharacters,
        [Parameter(Mandatory = $false)] [Switch]$CaseSensitive,
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$disallowedCharacters,
        [Parameter(Mandatory = $true)] [AllowNull()] [AllowEmptyString()] $InputData,
        [Parameter(Mandatory = $false)] [ValidateRange(1, 10000)] [Int]$MaxLength,
        [Parameter(Mandatory = $false)] [Double]$MaxValue,
        [Parameter(Mandatory = $false)] [ValidateRange(0, 1000)] [Int]$MinLength,
        [Parameter(Mandatory = $false)] [Double]$MinValue,
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$PropertyPath,
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$regexPattern,
        [Parameter(Mandatory = $false)] [ValidateSet("AlphaNumeric", "AlphaNumericDash", "Numeric", "FileName", "UserName", "DomainName", "IpAddress", "IpAddressWithCidr", "IpAddressOrDomainNameWithPort", "Email", "lowerCaseRfc1123PortGroup", "FilePath", "vSphereObject80Characters")] [String]$ValidationPreset
    )

    Write-LogMessage -Type DEBUG -Message "Entered Test-JsonPropertyFormat function..."

    # Step 1: Extract the property value from input data using helper function.
    $inputText = Get-JsonPropertyValue -inputData $InputData -propertyPath $PropertyPath

    if ($null -eq $inputText) {
        Write-LogMessage -Type ERROR -SuppressOutputToScreen -Message "Input validation failed: Could not extract property value"
        return $false
    }

    Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "Validating input text with length: $($inputText.Length)"

    # Step 2: Apply validation preset rules if specified.
    if ($ValidationPreset) {
        Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "Applying validation preset: $ValidationPreset"
        $presetRules = Get-ValidationPresetRules -validationPreset $ValidationPreset

        # Merge preset rules with explicitly provided parameters (explicit parameters take precedence)
        if (-not $allowedCharacters -and $presetRules.AllowedCharacters) {
            $allowedCharacters = $presetRules.AllowedCharacters
        }
        if (-not $disallowedCharacters -and $presetRules.DisallowedCharacters) {
            $disallowedCharacters = $presetRules.DisallowedCharacters
        }
        if (-not $regexPattern -and $presetRules.RegexPattern) {
            $regexPattern = $presetRules.RegexPattern
        }
    }

    # Step 3: Validate against acceptable strings (enumerated values) if specified.
    if ($AcceptableStrings -and $AcceptableStrings.Count -gt 0) {
        Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "Validating against acceptable strings"
        $isValid = Test-AcceptableStrings -inputText $inputText -acceptableStrings $AcceptableStrings -propertyPath $PropertyPath
        if (-not $isValid) {
            return $false
        }

        # If only acceptable strings validation was requested, return early.

        if (-not $allowedCharacters -and -not $disallowedCharacters -and -not $regexPattern -and -not $MinLength -and -not $MaxLength -and -not $PSBoundParameters.ContainsKey('MinValue') -and -not $PSBoundParameters.ContainsKey('MaxValue')) {
            Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "Input validation for '$inputText' passed successfully (acceptable strings only)"
            return $true
        }
    }

    # Step 4: Validate numeric range if specified.
    if ($PSBoundParameters.ContainsKey('MinValue') -or $PSBoundParameters.ContainsKey('MaxValue')) {
        Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "Validating numeric range"

        # Build parameter hashtable for Test-NumericRange.

        $numericParams = @{
            InputText = $inputText
            PropertyPath = $PropertyPath
        }
        if ($PSBoundParameters.ContainsKey('MinValue')) {
            $numericParams.MinValue = $MinValue
        }
        if ($PSBoundParameters.ContainsKey('MaxValue')) {
            $numericParams.MaxValue = $MaxValue
        }

        $isValid = Test-NumericRange @numericParams
        if (-not $isValid) {
            return $false
        }
    }

    # Step 5: Validate string length constraints.
    if ($MinLength -and $inputText.Length -lt $MinLength) {
        Write-LogMessage -Type ERROR -Message "Input validation failed: Input length $($inputText.Length) is less than minimum required length $MinLength"
        return $false
    }

    if ($MaxLength -and $inputText.Length -gt $MaxLength) {
        Write-LogMessage -Type ERROR -Message "Input validation failed: Input length $($inputText.Length) exceeds maximum allowed length $MaxLength"
        return $false
    }

    # Step 6: Validate against regular expression pattern if specified.
    if ($regexPattern) {
        Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "Validating against regex pattern: $regexPattern"

        # Use case-sensitive matching for all regex validation.

        if (-not ($inputText -cmatch $regexPattern)) {
            $presetInfo = if ($ValidationPreset) { " ($ValidationPreset)" } else { "" }
            Write-LogMessage -Type ERROR -Message "Validation failed for `"$PropertyPath`" with value `"$inputText`". It does not match the required pattern${presetInfo}: $regexPattern"
            return $false
        }
    }

    # Step 7: Validate against allowed characters (allowlist) if specified.
    if ($allowedCharacters) {
        Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "Validating against allowed characters"
        $isValid = Test-StringAgainstAllowlist -inputText $inputText -allowedCharacters $allowedCharacters
        if (-not $isValid) {
            return $false
        }
    }

    # Step 8: Validate against disallowed characters (denylist) if specified.
    if ($disallowedCharacters) {
        Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "Validating against disallowed characters"
        $isValid = Test-StringAgainstDenylist -inputText $inputText -disallowedCharacters $disallowedCharacters
        if (-not $isValid) {
            return $false
        }
    }

    # All validations passed.
    Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "Input validation for '$inputText' passed successfully"
    return $true
}

Function Test-TagCatalogCategory {

    <#
        .SYNOPSIS
        Tests for the existence of a vSphere tag catalog category and creates it if it doesn't exist.

        .DESCRIPTION
        The Test-TagCatalogCategory function checks if a specified tag catalog category exists
        in the connected vCenter. If the tag catalog category is not found, it creates
        a new one with a predefined description for edge-node greenfield deployments.

        This function is designed for greenfield deployments and uses a hardcoded description.
        The function will exit the script with code 1 if any errors occur during the lookup
        or creation process.

        .PARAMETER TagCatalog
        The name of the tag catalog category to test for existence or create.
        This parameter is mandatory and cannot be null or empty.

        .EXAMPLE
        Test-TagCatalogCategory -tagCatalog "EdgeNodePolicy"
        Tests for the existence of the "EdgeNodePolicy" tag catalog category and creates it if it doesn't exist.

        .EXAMPLE
        Test-TagCatalogCategory -tagCatalog $InputData.common.storagePolicy.storagePolicyTagCatalog
        Tests for the tag catalog specified in the input configuration data.

        .NOTES
        - This function requires a valid connection to vCenter via the $Script:VCenterName variable
        - The function uses hardcoded description: "Tag catalog for edge-node greenfield deployment"
        - The function will terminate the script execution (exit 1) if errors occur
        - Designed specifically for greenfield deployments; may need revision for brownfield scenarios
        - Uses Write-LogMessage for error logging

        .OUTPUTS
        None. This function does not return any objects but may create a new tag catalog category.

        .LINK
        Get-TagCategory
        New-TagCategory
    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$TagCatalog
    )

    Write-LogMessage -Type DEBUG -Message "Entered Test-TagCatalogCategory function..."

    # Verify vCenter connection before proceeding.
    $connectionTest = Test-VcenterConnection
    if (-not $connectionTest.IsConnected) {
        Write-LogMessage -Type ERROR -Message "Not connected to vCenter `"$Script:VCenterName`": $($connectionTest.ErrorMessage)"
        throw "Deployment failed. Check logs for details."
    }

    try {
        $tagFoundCategory = Get-TagCategory -Name $TagCatalog -Server $Script:VCenterName -ErrorAction SilentlyContinue
    } catch {
    }

    if (-not $tagFoundCategory) {
        # Hard coded description for the tag category assuming greenfield.  Can revisit for non-greenfield.
        try {
            New-TagCategory -Name $TagCatalog -Description "Tag catalog for edge-node greenfield deployment" -Server $Script:VCenterName -Confirm:$false -ErrorAction Stop | Out-Null
            Write-LogMessage -Type INFO -Message "Succesfully created tag catalog `"$TagCatalog`" on `"$Script:VCenterName`"."
        } catch {
            $errorMessage = $_.Exception.Message

            # Check for SSO authentication failure which is commonly caused by clock sync issues.

            if ($errorMessage -match "vSphere single sign-on failed for connection") {
                Write-LogMessage -Type ERROR -Message "Error creating tag catalog `"$TagCatalog`" on `"$Script:VCenterName`": SSO authentication failure."
                Write-LogMessage -Type ERROR -Message "This is commonly caused by clock synchronization issues between the client and vCenter Server."
                Write-LogMessage -Type ERROR -Message "Troubleshooting steps:"
                Write-LogMessage -Type ERROR -Message "  1. Verify NTP is configured and synchronized on this host (client)."
                Write-LogMessage -Type ERROR -Message "  2. Verify NTP is configured and synchronized on vCenter Server `"$Script:VCenterName`"."
                Write-LogMessage -Type ERROR -Message "  3. Check that time drift is less than 5 minutes between client and vCenter."
                Write-LogMessage -Type ERROR -Message "Full error details: $errorMessage"
            } else {
                Write-LogMessage -Type ERROR -Message "Error creating tag catalog `"$TagCatalog`" on `"$Script:VCenterName`": $errorMessage"
            }
            throw "Deployment failed. Check logs for details."
        }

    } else {
        Write-LogMessage -Type WARNING -Message "Tag catalog `"$TagCatalog`" already exists on vCenter `"$Script:VCenterName`"."
    }
}

Function Test-Tag {

    <#
        .SYNOPSIS
        Tests for the existence of a vSphere tag within a specified tag catalog category and creates it if it doesn't exist.

        .DESCRIPTION
        The Test-Tag function checks if a specified tag exists within a given tag catalog category
        in the connected vCenter. If the tag is not found, it creates a new tag with a
        predefined description for edge-node greenfield deployments.

        This function is designed for greenfield deployments and uses a hardcoded description.
        The function will exit the script with code 1 if any errors occur during the lookup
        or creation process.

        .PARAMETER TagCatalog
        The name of the tag catalog category that should contain the tag.
        This parameter is mandatory and cannot be null or empty.

        .PARAMETER TagName
        The name of the tag to test for existence or create within the specified tag catalog category.
        This parameter is mandatory and cannot be null or empty.

        .EXAMPLE
        Test-Tag -tagCatalog "EdgeNodePolicy" -tagName "SupervisorCluster01"
        Tests for the existence of the "SupervisorCluster01" tag in the "EdgeNodePolicy" catalog category
        and creates it if it doesn't exist.

        .EXAMPLE
        Test-Tag -tagCatalog $storagePolicyTagCatalog -tagName $SupervisorName
        Tests for the tag specified by variables, commonly used with configuration data.

        .NOTES
        - This function requires a valid connection to vCenter via the $Script:VCenterName variable
        - The function uses hardcoded description: "New Tag for supervisor instance {tagName} for edge-node greenfield deployment"
        - The function will terminate the script execution (exit 1) if errors occur during tag catalog lookup or tag creation
        - Designed specifically for greenfield deployments; may need revision for brownfield scenarios
        - Uses Write-LogMessage for error logging
        - The tag catalog category must exist before calling this function (use Test-TagCatalogCategory first)

        .OUTPUTS
        None. This function does not return any output but may create a new tag if it doesn't exist.

        .LINK
        Test-TagCatalogCategory
    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$TagCatalog,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$TagName
    )

    Write-LogMessage -Type DEBUG -Message "Entered Test-Tag function..."

    # Verify vCenter connection before proceeding.
    $connectionTest = Test-VcenterConnection
    if (-not $connectionTest.IsConnected) {
        Write-LogMessage -Type ERROR -Message "Not connected to vCenter `"$Script:VCenterName`": $($connectionTest.ErrorMessage)"
        throw "Deployment failed. Check logs for details."
    }

    # Create tagCategoy object.
    try {
        $tagCatalogObject = Get-TagCategory -Name $TagCatalog -Server $Script:VCenterName -ErrorAction SilentlyContinue}
    catch {
        Write-LogMessage -Type ERROR -Message "Error looking up tag catalog `"$TagCatalog`" on vCenter `"$Script:VCenterName`" $_"
        throw "Deployment failed. Check logs for details."
    }

    # Look to see if tag has already been created.
    try {
        $foundTagName = Get-Tag -Name $TagName -Category $tagCatalogObject -Server $Script:VCenterName -ErrorAction SilentlyContinue
    } catch {
        Write-LogMessage -Type ERROR -Message "Error looking up tag `"$TagName`" in tag catalog `"$TagCatalog`" on vCenter `"$Script:VCenterName`" $_"
        throw "Deployment failed. Check logs for details."
    }

    # If tag has not been created, create it.
    if (-not $foundTagName) {
        try {
            $tagCategoryObject = Get-TagCategory $tagCatalogObject -ErrorAction Stop
            $taskId = New-Tag -Name $TagName -Category $tagCategoryObject -Description "New Tag for supervisor instance $TagName for edge-node greenfield deployment" -Server $Script:VCenterName -Confirm:$false -ErrorAction Stop
            Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "New Tag creation TaskId: $($taskId.Value)"
            Write-LogMessage -Type INFO -Message "Succesfully created tag name `"$TagName`" on `"$TagCatalog`" on vCenter `"$Script:VCenterName`"."
        } catch {
            Write-LogMessage -Type ERROR -Message "Error creating tag name `"$TagName`" on `"$TagCatalog`" on vCenter `"$Script:VCenterName`" $_"
            throw "Deployment failed. Check logs for details."
        }
    } else{
        Write-LogMessage -Type WARNING -Message "Tag name `"$TagName`" already exists on `"$TagCatalog`" on vCenter `"$Script:VCenterName`"."
    }
}

Function Test-JsonDeeperValidation {

    <#
        .SYNOPSIS
        Validates JSON file content against specified validation rules.

        .DESCRIPTION
        The Test-JsonDeeperValidation function provides comprehensive validation of JSON files
        against specified validation rules. It supports nested property validation
        using dot notation (e.g., "common.vCenter.name") and provides detailed reporting of
        validation failures.
    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$InfrastructureJson,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$SupervisorJson
    )

    Write-LogMessage -Type DEBUG -Message "Entered Test-JsonDeeperValidation function..."

    $inputData = ConvertFrom-JsonSafely -JsonFilePath $InfrastructureJson
    $supervisorData = ConvertFrom-JsonSafely -JsonFilePath $SupervisorJson

    $validationFailures = 0

    # Create an arraylist of all four VKS networks.
    $vksNetworks = [System.Collections.ArrayList]::new()
    $vksNetworks.Add("$($supervisorData.tkgsComponentSpec.tkgsMgmtNetworkSpec.tkgsMgmtNetworkName)") | Out-Null
    $vksNetworks.Add("$($supervisorData.tkgsComponentSpec.foundationLoadBalancerComponents.flbManagementNetwork.flbNetworkName)") | Out-Null
    $vksNetworks.Add("$($supervisorData.tkgsComponentSpec.tkgsPrimaryWorkloadNetwork.tkgsPrimaryWorkloadNetworkName)") | Out-Null
    $vksNetworks.Add("$($supervisorData.tkgsComponentSpec.foundationLoadBalancerComponents.flbVirtualServerNetwork.flbNetworkName)") | Out-Null

   # loop through each VKS network and check if it exists in the input data.
    foreach ($vksNetwork in $vksNetworks) {
        $foundNetwork = $false
        foreach ($network in $inputData.common.virtualDistributedSwitch.portGroups) {
            if ($vksNetwork -cmatch $($network.name)) {
                $foundNetwork = $true
                break
            }
        }
        if (-not $foundNetwork) {
            Write-LogMessage -Type ERROR -Message "VKS network `"$vksNetwork`" in $SupervisorJson does not exist in the $InfrastructureJson"
            $validationFailures++
        }
    }

    # Test for VMware object character validation.
    $vmwareObjectCharacterProperties = @(
        "common.clusterName",
        "common.datacenterName",
        "common.datastore.datastoreName",
        "common.storagepolicy.storagePolicyTagCatalog",
        "common.storagepolicy.storagePolicyName"
    )
    foreach ($vmwareObjectCharacterProperty in $vmwareObjectCharacterProperties) {
        $isValid = Test-JsonPropertyFormat -inputData $inputData -propertyPath $vmwareObjectCharacterProperty -validationPreset "vSphereObject80Characters"
        if (-Not $isValid) {
            $validationFailures++
        }
    }

    # Test for existence of required yaml files.
    $filePathProperties = @(
        "common.argoCD.argoCdOperatorYamlPath",
        "common.argoCD.argoCdDeploymentYamlPath"
    )
    foreach ($FilePathProperty in $filePathProperties) {
        $isValid = Test-JsonPropertyFormat -inputData $inputData -propertyPath $FilePathProperty -validationPreset "FilePath"
        if (-Not $isValid) {
                $validationFailures++
        }
    }

    # Objects that must be an unsigned integer with minimum value requirements.
    $numericPropertiesWithRanges = @(
        @{Path = "tkgsComponentSpec.foundationLoadBalancerComponents.flbVipIPCount"; Min = 1},
        @{Path = "tkgsComponentSpec.foundationLoadBalancerComponents.flbManagementNetwork.flbNetworkIpAddressCount"; Min = 2},
        @{Path = "tkgsComponentSpec.foundationLoadBalancerComponents.flbVirtualServerNetwork.flbNetworkIpAddressCount"; Min = 2},
        @{Path = "tkgsComponentSpec.tkgsMgmtNetworkSpec.tkgsMgmtNetworkIPCount"; Min = 5},
        @{Path = "tkgsComponentSpec.tkgsPrimaryWorkloadNetwork.tkgsPrimaryWorkloadNetworkIPCount"; Min = 2}
    )

    foreach ($prop in $numericPropertiesWithRanges) {
        $params = @{
            inputData = $supervisorData
            propertyPath = $prop.Path
            validationPreset = "Numeric"
            minValue = $prop.Min
        }

        $isValid = Test-JsonPropertyFormat @params
        if (-Not $isValid) {
            $validationFailures++
        }
    }

    # Validate tkgsWorkloadServiceCount as a valid CIDR range.
    # This represents the number of service IP addresses to allocate for workloads.
    # Must correspond to a valid CIDR block (/8 to /32):.
    # - 16 = /28, 32 = /27, 64 = /26, 128 = /25, 256 = /24, 512 = /23, 1024 = /22, etc.
    # - Maximum: 16,777,216 = /8
    Write-LogMessage -Type DEBUG -Message "Validating tkgsWorkloadServiceCount as valid CIDR range"
    $serviceCountValue = Get-JsonPropertyValue -inputData $supervisorData -propertyPath "tkgsComponentSpec.tkgsPrimaryWorkloadNetwork.tkgsWorkloadServiceCount"
    if ($null -ne $serviceCountValue) {
        $isValid = Test-ValidCidrRange -inputText $serviceCountValue -propertyPath "tkgsComponentSpec.tkgsPrimaryWorkloadNetwork.tkgsWorkloadServiceCount"
        if (-Not $isValid) {
            $validationFailures++
        }
    } else {
        Write-LogMessage -Type ERROR -Message "Property 'tkgsComponentSpec.tkgsPrimaryWorkloadNetwork.tkgsWorkloadServiceCount' is missing or null"
        $validationFailures++
    }

    # Objects that must be an unsigned integer.
    $integerObjectPropertiesForInputData = @(
        "common.virtualDistributedSwitch.numUplinks"
    )
    foreach ($integerObjectProperty in $integerObjectPropertiesForInputData) {
        $isValid = Test-JsonPropertyFormat -inputData $inputData -propertyPath $integerObjectProperty -validationPreset "Numeric"
        if (-Not $isValid) {
            $validationFailures++
        }
    }

    # Require that all neetworks be lower-cased RFC1123 hostname for WCP compliance.  vcenter.wcp.dns.name.noncompliant error will be thrown if not compliant.
    $vksNetworkNameProperties = @(
        "tkgsComponentSpec.foundationLoadBalancerComponents.flbManagementNetwork.flbNetworkName",                # Management network name
        "tkgsComponentSpec.foundationLoadBalancerComponents.flbVirtualServerNetwork.flbNetworkName",
        "tkgsComponentSpec.tkgsPrimaryWorkloadNetwork.tkgsPrimaryWorkloadNetworkName",
        "tkgsComponentSpec.tkgsMgmtNetworkSpec.tkgsMgmtNetworkName"
    )
    foreach ($vksNetworkNameProperty in $vksNetworkNameProperties) {
        $isValid = Test-JsonPropertyFormat -inputData $supervisorData -propertyPath $vksNetworkNameProperty -validationPreset "lowerCaseRfc1123PortGroup"
        if (-Not $isValid) {
            $validationFailures++
        }
    }

    # Require that all networks and VM classes be lowercase RFC1123 compliant for WCP/Kubernetes compatibility.
    # vcenter.wcp.dns.name.noncompliant error will be thrown by vCenter if not compliant.
    # Pattern validates: lowercase letters, numbers, hyphens (not at start/end), max 80 chars.
    $lowerCaseRfc1123RegexPattern = '^(?=.{1,80}$)[a-z0-9]([-a-z0-9]*[a-z0-9])?$'

    foreach ($network in $inputData.common.virtualDistributedSwitch.portGroups) {
        if ($($network.name) -cnotmatch $lowerCaseRfc1123RegexPattern) {
            Write-LogMessage -Type ERROR -Message "Port group name `"$($network.name)`" in input.json does not conform to RFC1123 (lowercase alphanumeric with hyphens only)."
            $validationFailures++
        }
    }

    # Validate VM class names follow RFC1123 format (format check only, existence validated by API during assignment).
    # VM classes must be lowercase RFC1123 compliant for Kubernetes compatibility.
    $vmClassValue = $inputData.common.argoCD.vmClass
    if ($vmClassValue) {
        # Handle both string and array formats.

        $vmClassList = if ($vmClassValue -is [Array]) { $vmClassValue } else { @($vmClassValue) }

        foreach ($vmClassName in $vmClassList) {
            if ($vmClassName -cnotmatch $lowerCaseRfc1123RegexPattern) {
                Write-LogMessage -Type ERROR -Message "VM class name `"$vmClassName`" in input.json does not conform to RFC1123 (lowercase alphanumeric with hyphens only, max 80 chars)."
                $validationFailures++
            }
        }
    }

    $ipv4regexPattern = '^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$'
    $dnsServers = @(
        [PSCustomObject]@{ Name = "tkgsComponentSpec.foundationLoadBalancerComponents.flbDnsServers" ; Data = $($supervisorData.tkgsComponentSpec.foundationLoadBalancerComponents.flbDnsServers) }
        [PSCustomObject]@{ Name = "tkgsMgmtNetworkSpec.tkgsMgmtNetworkDnsServers"; Data = $($supervisorData.tkgsComponentSpec.tkgsMgmtNetworkSpec.tkgsMgmtNetworkDnsServers) }
        [PSCustomObject]@{ Name = "tkgsPrimaryWorkloadNetwork.tkgsWorkloadDnsServers"; Data = $($supervisorData.tkgsComponentSpec.tkgsPrimaryWorkloadNetwork.tkgsWorkloadDnsServers) }
    )
    foreach ($dnsServer in $dnsServers) {
        $dnsServerCount = ($($dnsServer.Data).Count)
        if ($($dnsServerCount) -eq 0 -or $($dnsServerCount) -gt 3) {
            Write-LogMessage -Type ERROR -Message "DNS server array `"$($dnsServer.Name)`" must have at least 1 server and at most 3 servers.  Current count: $($dnsServerCount)."
            $validationFailures++
            continue
        }
        foreach ($dnsServerEntry in $dnsServer.Data) {
            if ($($dnsServerEntry) -notmatch $ipv4regexPattern) {
                Write-LogMessage -Type ERROR -Message "DNS server `"$($dnsServerEntry)`" `"$($dnsServer.Name)`" is not a valid IPV4 address."
                $validationFailures++
            }
        }
    }

    # Supervisor services or vSphere Pods must have storage policy set to fully Initialized. other settings will introduce disk creation issues.
    # https://knowledge.broadcom.com/external/article/385016/failed-to-add-disk-error-while-deploying.html
    $policyPath = "common.storagepolicy.storagePolicyRule"
    $isValid = Test-JsonPropertyFormat -inputData $inputData -propertyPath $policyPath -acceptableStrings @("Fully initialized")
    if (-Not $isValid) {
        $validationFailures++
    }

    # Today only VMFS is supported.
    $storageType = "common.storagepolicy.storagePolicyType"
    $isValid = Test-JsonPropertyFormat -inputData $inputData -propertyPath $storageType -acceptableStrings @("VMFS")
    if (-Not $isValid) {
        $validationFailures++
    }

    # Foundation Load Balancer size must be one of the following: SMALL, MEDIUM, LARGE, X-LARGE.
    $policyPath = "tkgsComponentSpec.foundationLoadBalancerComponents.flbSize"
    $isValid = Test-JsonPropertyFormat -inputData $supervisorData -propertyPath $policyPath -acceptableStrings @("SMALL", "MEDIUM", "LARGE", "X-LARGE")
    if (-Not $isValid) {
        $validationFailures++
    }

    # Only one FLB provider is supported: VSPHERE_FOUNDATION.
    $flbProvider = "tkgsComponentSpec.foundationLoadBalancerComponents.flbProvider"
    $isValid = Test-JsonPropertyFormat -inputData $supervisorData -propertyPath $flbProvider -acceptableStrings @("VSPHERE_FOUNDATION")
    if (-Not $isValid) {
        $validationFailures++
    }

    # Supervisor control plane size must be one of the following: TINY, SMALL, MEDIUM, LARGE.
    $policyPath = "supervisorSpec.controlPlaneSize"
    $isValid = Test-JsonPropertyFormat -inputData $supervisorData -propertyPath $policyPath -acceptableStrings @("TINY", "SMALL", "MEDIUM", "LARGE")
    if (-Not $isValid) {
        $validationFailures++
    }

    # Only DVPG is supported for foundation load balancer networks.
    $networkTypeProperties = @(
        "tkgsComponentSpec.foundationLoadBalancerComponents.flbManagementNetwork.flbNetworkType",
        "tkgsComponentSpec.foundationLoadBalancerComponents.flbVirtualServerNetwork.flbNetworkType"
    )
    foreach ($networkTypeProperty in $networkTypeProperties) {
        $isValid = Test-JsonPropertyFormat -inputData $supervisorData -propertyPath $networkTypeProperty -acceptableStrings @("DVPG")
        if (-Not $isValid) {
            $validationFailures++
        }
    }

    # flbAvailability must be either SINGLE_NODE or ACTIVE_PASSIVE
    $policyPath = "tkgsComponentSpec.foundationLoadBalancerComponents.flbAvailability"
    $isValid = Test-JsonPropertyFormat -inputData $supervisorData -propertyPath $policyPath -acceptableStrings @("SINGLE_NODE", "ACTIVE_PASSIVE")
    if (-Not $isValid) {
        $validationFailures++
    }

    # Ensure the control plane VM count is either 1 or 3.
    $policyPath = "supervisorSpec.controlPlaneVMCount"
    $isValid = Test-JsonPropertyFormat -inputData $supervisorData -propertyPath $policyPath -acceptableStrings @("1", "3")
    if (-Not $isValid) {
        $validationFailures++
    }

    # Network Gateway property validation.
    $networkGatewayProperties = @(
        "tkgsComponentSpec.foundationLoadBalancerComponents.flbManagementNetwork.flbNetworkGateway",
        "tkgsComponentSpec.foundationLoadBalancerComponents.flbVirtualServerNetwork.flbNetworkGateway",
        "tkgsComponentSpec.tkgsMgmtNetworkSpec.tkgsMgmtNetworkGatewayCidr",
        "tkgsComponentSpec.tkgsPrimaryWorkloadNetwork.tkgsPrimaryWorkloadNetworkGatewayCidr"
    )
    foreach ($networkGatewayProperty in $networkGatewayProperties) {
        $isValid = Test-JsonPropertyFormat -inputData $supervisorData -propertyPath $networkGatewayProperty -validationPreset "IpAddressWithCidr"
        if (-Not $isValid) {
            $validationFailures++
        }
    }

    # Starting IP address property validation.
    $startingIpAddressProperties = @(
        "tkgsComponentSpec.foundationLoadBalancerComponents.flbManagementNetwork.flbNetworkIpAddressStartingIp",
        "tkgsComponentSpec.foundationLoadBalancerComponents.flbVirtualServerNetwork.flbNetworkIpAddressStartingIp",
        "tkgsComponentSpec.tkgsMgmtNetworkSpec.tkgsMgmtNetworkStartingIp",
        "tkgsComponentSpec.tkgsPrimaryWorkloadNetwork.tkgsPrimaryWorkloadNetworkStartingIp",
        "tkgsComponentSpec.foundationLoadBalancerComponents.flbVipStartIP",
        "tkgsComponentSpec.tkgsPrimaryWorkloadNetwork.tkgsWorkloadServiceStartIp"
    )
    foreach ($startingIpAddressProperty in $startingIpAddressProperties) {
        $isValid = Test-JsonPropertyFormat -inputData $supervisorData -propertyPath $startingIpAddressProperty -validationPreset "IpAddress"
        if (-Not $isValid) {
            $validationFailures++
        }
    }

    # Validate that starting IP addresses are within their respective CIDR ranges.
    Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "Validating starting IP addresses are within their respective CIDR ranges..."

    # Define IP-to-Gateway mappings for validation.
    $ipToGatewayMappings = @(
        @{
            IpPath = "tkgsComponentSpec.foundationLoadBalancerComponents.flbManagementNetwork.flbNetworkIpAddressStartingIp"
            GatewayPath = "tkgsComponentSpec.foundationLoadBalancerComponents.flbManagementNetwork.flbNetworkGateway"
            Description = "FLB Management Network Starting IP"
        },
        @{
            IpPath = "tkgsComponentSpec.foundationLoadBalancerComponents.flbVirtualServerNetwork.flbNetworkIpAddressStartingIp"
            GatewayPath = "tkgsComponentSpec.foundationLoadBalancerComponents.flbVirtualServerNetwork.flbNetworkGateway"
            Description = "FLB Virtual Server Network Starting IP"
        },
        @{
            IpPath = "tkgsComponentSpec.tkgsMgmtNetworkSpec.tkgsMgmtNetworkStartingIp"
            GatewayPath = "tkgsComponentSpec.tkgsMgmtNetworkSpec.tkgsMgmtNetworkGatewayCidr"
            Description = "TKGS Management Network Starting IP"
        },
        @{
            IpPath = "tkgsComponentSpec.tkgsPrimaryWorkloadNetwork.tkgsPrimaryWorkloadNetworkStartingIp"
            GatewayPath = "tkgsComponentSpec.tkgsPrimaryWorkloadNetwork.tkgsPrimaryWorkloadNetworkGatewayCidr"
            Description = "TKGS Primary Workload Network Starting IP"
        }
    )

    foreach ($mapping in $ipToGatewayMappings) {
        # Extract IP and Gateway values from JSON.

        $ipValue = $null
        $gatewayValue = $null

        # Navigate the property path to get the IP value.

        $ipParts = $mapping.IpPath.Split('.')
        $ipTemp = $supervisorData
        foreach ($part in $ipParts) {
            if ($null -ne $ipTemp.$part) {
                $ipTemp = $ipTemp.$part
            } else {
                break
            }
        }
        if ($ipTemp -is [string]) {
            $ipValue = $ipTemp
        }

        # Navigate the property path to get the Gateway value.

        $gatewayParts = $mapping.GatewayPath.Split('.')
        $gatewayTemp = $supervisorData
        foreach ($part in $gatewayParts) {
            if ($null -ne $gatewayTemp.$part) {
                $gatewayTemp = $gatewayTemp.$part
            } else {
                break
            }
        }
        if ($gatewayTemp -is [string]) {
            $gatewayValue = $gatewayTemp
        }

        # Validate if both values exist.

        if ($null -ne $ipValue -and $null -ne $gatewayValue) {
            Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "Checking $($mapping.Description): $ipValue against gateway $gatewayValue"

            $isInRange = Test-IpAddressInCidrRange -IpAddress $ipValue -CidrRange $gatewayValue

            if (-not $isInRange) {
                Write-LogMessage -Type ERROR -Message "$($mapping.Description) ($ipValue) is NOT within the gateway CIDR range ($gatewayValue)"
                $validationFailures++
            } else {
                Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "$($mapping.Description) ($ipValue) is within the gateway CIDR range ($gatewayValue)"
            }
        }
    }

    if ($validationFailures -gt 0) {
        Write-LogMessage -Type ERROR -prependNewLine -Message "JSON parameter validation failed with $validationFailures error(s)."
        throw "Deployment failed. Check logs for details."
    } else {
        Write-LogMessage -Type DEBUG -Message "JSON parameter validation passed."
    }
}
Function Find-Datastore {

    <#
        .SYNOPSIS
        Locates a datastore on an ESX host or prompts for selection of an unformatted disk alternative.

        .DESCRIPTION
        The Find-Datastore function searches for a specified datastore on an ESX host and validates its configuration.
        If the datastore is not found, the function offers an interactive selection of available unformatted disks
        as alternatives, allowing the user to choose a disk for datastore creation.

        The function performs the following operations:
        1. Checks if the specified datastore exists and is mounted on the ESX host
        2. If found, validates that the datastore is VMFS formatted and reports its status
        3. If not found, scans for available unformatted disks on the ESX host
        4. Presents an interactive table of unformatted disks for user selection
        5. Returns the canonical name of the selected disk for subsequent datastore creation

        Key features:
        - Validates existing datastore mount status and VMFS formatting
        - Provides fallback mechanism when datastore is not found
        - Interactive disk selection with detailed capacity and vendor information
        - Returns canonical disk name for programmatic use in datastore creation workflows
        - Exits with error if no valid datastore or disk selection is made

        .PARAMETER EsxHostName
        The hostname or IP address of the ESX host to scan. This parameter is mandatory.
        Requires an active direct connection to the ESX host.

        .PARAMETER DatastoreName
        The name of the datastore to locate on the ESX host. This parameter is mandatory.
        If the datastore is not found, the function will prompt for an alternative disk selection.

        .EXAMPLE
        Find-Datastore -EsxHostName "esx01.example.com" -DatastoreName "datastore1"

        Searches for "datastore1" on the specified ESX host.
        If found and VMFS formatted, reports the datastore status.
        If not found, prompts user to select from available unformatted disks.

        .EXAMPLE
        $diskName = Find-Datastore -EsxHostName "esx01.example.com" -DatastoreName "my-datastore"
        if ($diskName) {
            Write-Host "Selected disk for datastore creation: $diskName"
            # Proceed with datastore creation using $diskName.

        }

        Captures the returned canonical disk name for use in subsequent datastore creation operations.

        .EXAMPLE
        # Within a deployment workflow.

        $diskCanonicalName = Find-Datastore -EsxHostName $EsxHost -DatastoreName $requiredDatastore
        if ($diskCanonicalName) {
            Set-NewDatastore -EsxHost $EsxHost -DiskCanonicalName $diskCanonicalName -DatastoreName $requiredDatastore
        }

        Uses the function as part of an automated deployment workflow to locate or select storage.

        .OUTPUTS
        String. Returns the canonical name of either:
        - The selected unformatted disk (e.g., "naa.600508b1001c...") if the datastore doesn't exist
        - The existing datastore's underlying disk canonical name if the datastore is already mounted
        Throws an exception if no valid selection is made, datastore type is unexpected, or canonical name cannot be retrieved.

        .NOTES
        - Requires an active direct connection to the ESX host
        - Requires PowerCLI modules to be installed (VMware.VimAutomation.Core)
        - Uses Get-EsxDatastoreInfo internally for datastore scanning and disk discovery
        - Interactive selection requires user input and cannot be fully automated
        - If datastore exists but is not VMFS formatted, the function throws an exception
        - Uses Write-LogMessage for consistent logging throughout the script
        - Follows the error handling patterns of the SimpleSupervisorDeploymentAtScale module
    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$DatastoreName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$EsxHostName

    )
    Write-LogMessage -Type DEBUG -Message "Entered Find-Datastore function..."

    # Step 1: Check if specific datastore exists.
    $getDatastoreParams = @{
        esxHostName = $EsxHostName
        datastoreName = $DatastoreName
        silence = $true
    }
    $result = Get-EsxDatastoreInfo @getDatastoreParams

    if (-not $result.MountedDatastoreStatus.IsMounted) {
        # Step 2: Datastore NOT found - inform user.

        Write-LogMessage -Type INFO -Message "Datastore `"$DatastoreName`" not found on ESX host `"$EsxHostName`". Proceeding with unformatted disk selection."
        Write-LogMessage -Type INFO -Message "Checking for available unformatted disks..."

        # Step 3: Present alternatives with interactive selection.

        $selectDatastoreParams = @{
            esxHostName = $EsxHostName
            selectUnformattedDatastore = $true
        }
        $result = Get-EsxDatastoreInfo @selectDatastoreParams

        # Step 4: Process user's selection.

        if ($result.SelectedDatastoreUUID) {
            # Get full details of selected disk.

            $selectedDisk = $result.UnformattedDisks | Where-Object { $_.CanonicalName -eq $result.SelectedDatastoreUUID }

            if ($null -ne $selectedDisk) {
                Write-LogMessage -Type INFO -Message "Selected: $($selectedDisk.CanonicalName) - $($selectedDisk.CapacityGB) GB - Vendor: $($selectedDisk.Vendor)"
                # Return the canonical name of the selected disk.
                return $selectedDisk.CanonicalName
            }
            else {
                Write-LogMessage -Type ERROR -Message "Selected disk `"$($result.SelectedDatastoreUUID)`" not found in available disks. Cannot proceed."
                throw "Deployment failed. Check logs for details."
            }
        }
        else {
            # User skipped selection - cannot proceed.

            Write-LogMessage -Type ERROR -Message "No datastore selected. Cannot proceed with deployment."
            throw "Deployment failed. Check logs for details."
        }
    }
    else {
        # Datastore found - verify it's VMFS and healthy.
        if ($result.MountedDatastoreStatus.IsVMFS) {
            Write-LogMessage -Type INFO -Message "Datastore `"$DatastoreName`" is already mounted on ESX host `"$EsxHostName`" and has $($result.MountedDatastoreStatus.FreeSpaceGB) GB free space."
            Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "$DatastoreName UUID is $($result.MountedDatastoreStatus.UUID)"
            # Datastore already exists - return its canonical name from the result object.

            if ($result.MountedDatastoreStatus.CanonicalName) {
                Write-LogMessage -Type INFO -Message "Retrieved canonical name for existing datastore `"$DatastoreName`": $($result.MountedDatastoreStatus.CanonicalName)."
                return $result.MountedDatastoreStatus.CanonicalName
            }
            else {
                Write-LogMessage -Type ERROR -Message "Could not retrieve canonical name for datastore `"$DatastoreName`""
                throw "Deployment failed. Check logs for details."
            }
        }
        else {
            Write-LogMessage -Type ERROR -Message "Datastore `"$DatastoreName`" is mounted, but in unexpected type: (Type: $($result.MountedDatastoreStatus.Type)). Cannot proceed."
            throw "Deployment failed. Check logs for details."
        }
    }
}
Function Find-VlcmImage {

    <#
        .SYNOPSIS
        Locates a vLCM image on the attached vCenter or prompts for interactive selection.

        .DESCRIPTION
        The Find-VlcmImage function retrieves available vLCM images from the attached vCenter using
        Invoke-EsxSettingsRepositorySoftwareList and presents them for user selection. The function
        displays each image's DisplayName and non-null SoftwareSpec components, allowing the user
        to choose an appropriate image for deployment.

        The function performs the following operations:
        1. Retrieves all available vLCM images from the attached vCenter using Invoke-EsxSettingsRepositorySoftwareList
        2. Displays each image's DisplayName and SoftwareSpec details in a formatted table with proper spacing
        3. Prompts the user to select an image by number (selection cannot be skipped)
        4. Returns the selected image's ID for use in subsequent operations (typically passed to Get-LcmSoftwareSpecification)

        Key features:
        - Interactive image selection with detailed SoftwareSpec information
        - Shows BaseImage (always present) and other non-null SoftwareSpec components as separate columns
        - Formatted output with blank line separation between table and prompt for improved readability
        - Validates user input and provides clear error messages
        - Returns image ID string for programmatic use in deployment workflows
        - User must select an image or enter 'c' to cancel (which throws an exception)

        .PARAMETER None
        This function requires no parameters. It uses the currently attached vCenter connection.

        .EXAMPLE
        $imageId = Find-VlcmImage

        Retrieves available vLCM images and prompts for user selection, returning the selected image ID.

        .EXAMPLE
        # Within a deployment workflow.

        $selectedImageId = Find-VlcmImage
        if ($selectedImageId) {
            Write-Host "Selected image ID: $selectedImageId"
            # Proceed with deployment using $selectedImageId.

        }

        Uses the function as part of an automated deployment workflow to select a vLCM image.

        .OUTPUTS
        String. Returns the ID of the selected vLCM image (e.g., "software-spec-1").
        Throws an exception if the user enters 'c' to cancel.

        .NOTES
        - Requires an active vCenter connection (Connect-VIServer)
        - Requires PowerCLI modules to be installed (VMware.VimAutomation.Core)
        - Uses Invoke-EsxSettingsRepositorySoftwareList internally for image discovery
        - Interactive selection requires user input and cannot be fully automated
        - Selection cannot be skipped - user must select an image (1-N) or cancel ('c')
        - If user cancels, the function throws an exception to stop deployment
        - Uses Write-LogMessage for consistent logging throughout the script
        - Follows the error handling patterns of the SimpleSupervisorDeploymentAtScale module
    #>

    Write-LogMessage -Type DEBUG -Message "Entered Find-VlcmImage function..."

    # Step 1: Retrieve available vLCM images from vCenter.
    Write-LogMessage -Type INFO -PrependNewLine -Message "Retrieving list of of vLCM images from vCenter's Image Catalog..."
    try {
        $imageList = Invoke-EsxSettingsRepositorySoftwareList -ErrorAction Stop
    }
    catch {
        Write-LogMessage -Type ERROR -Message "Failed to retrieve vLCM images: $($_.Exception.Message)"
        throw "Deployment failed. Check logs for details."
    }

    if ($null -eq $imageList -or $null -eq $imageList.Records -or $imageList.Records.Count -eq 0) {
        Write-LogMessage -Type ERROR -Message "No vLCM images found in the repository."
        throw "Deployment failed. Check logs for details."
    }

    Write-LogMessage -Type DEBUG -Message "Found $($imageList.Records.Count) vLCM image(s) available."

    # Step 2: Helper function to extract SoftwareSpec components as a hashtable.
    function Get-SoftwareSpecComponents {
        param (
            [Parameter(Mandatory = $true)] [AllowNull()] [PSObject]$SoftwareSpec
        )

        # Define the keys we care about and how they should be handled.
        $fieldMap = @(
            @{ Key = "AlternativeImages"; Label = "AlternativeImages"; IsCollection = $true },
            @{ Key = "AddOn";             Label = "AddOn" },
            @{ Key = "BaseImage";         Label = "BaseImage"; IsVersion = $true },
            @{ Key = "Components";        Label = "Components"; IsCollection = $true },
            @{ Key = "HardwareSupport";   Label = "HardwareSupport" },
            @{ Key = "RemovedComponents"; Label = "RemovedComponents"; IsCollection = $true },
            @{ Key = "Solutions";         Label = "Solutions"; IsCollection = $true }
        )

        # Initialize result with nulls.
        $results = [ordered]@{ }
        foreach ($field in $fieldMap) {
            $results[$field.Key] = $null
        }

        if ($null -eq $SoftwareSpec) {
            return $results
        }

        # Case 1: SoftwareSpec is an Object (PSObject/Dictionary/etc).
        if ($SoftwareSpec -isnot [string]) {
            foreach ($field in $fieldMap) {
                $val = $SoftwareSpec.$($field.Key)

                if ($null -ne $val) {
                    if ($field.IsVersion -and $null -ne $val.Version) {
                        $results[$field.Key] = $val.Version
                    }
                    elseif ($field.IsCollection -and $val.Count -gt 0) {
                        $results[$field.Key] = $val.Keys -join ", "
                    }
                    elseif ($val -ne "") {
                        $results[$field.Key] = $val
                    }
                }
            }
        }
        else {
            # Case 2: SoftwareSpec is a string - parse it to extract components.
            $softwareSpecString = $SoftwareSpec.ToString()

            foreach ($field in $fieldMap) {
                if ($field.IsVersion) {
                    # BaseImage has special format: "BaseImage: Version: <value>".

                    if ($softwareSpecString -match "$($field.Label):\s*Version:\s*([^,]+)") {
                        $extractedValue = $matches[1].Trim()
                        if ($extractedValue -and $extractedValue -ne "") {
                            $results[$field.Key] = $extractedValue
                        }
                    }
                }
                else {
                    # Other fields use format: "Label: <value>".

                    if ($softwareSpecString -match "$($field.Label):\s*([^,]+)") {
                        $extractedValue = $matches[1].Trim()
                        if ($extractedValue -and $extractedValue -ne "") {
                            $results[$field.Key] = $extractedValue
                        }
                    }
                }
            }
        }

        return $results
    }

    # Step 3: First pass - determine which columns are needed across all records.
    $availableColumns = @{
        BaseImage = $false
        AddOn = $false
        Components = $false
        Solutions = $false
        HardwareSupport = $false
        RemovedComponents = $false
        AlternativeImages = $false
    }

    # Create a copy of keys to avoid enumeration modification error.
    $columnKeys = @('BaseImage', 'AddOn', 'Components', 'Solutions', 'HardwareSupport', 'RemovedComponents', 'AlternativeImages')

    foreach ($record in $imageList.Records) {
        $specComponents = Get-SoftwareSpecComponents -SoftwareSpec $record.SoftwareSpec
        foreach ($key in $columnKeys) {
            if ($null -ne $specComponents[$key] -and $specComponents[$key] -ne "") {
                $availableColumns[$key] = $true
            }
        }
    }

    # Step 4: Build column list (BaseImage always included, others only if found).
    $columnList = @('ID', 'DisplayName', 'BaseImage')
    foreach ($key in @('AddOn', 'Components', 'Solutions', 'HardwareSupport', 'RemovedComponents', 'AlternativeImages')) {
        if ($availableColumns[$key]) {
            $columnList += $key
        }
    }

    # Step 5: Prepare image data for display with individual columns.
    $imageSelectionList = @()
    $index = 1

    foreach ($record in $imageList.Records) {
        $specComponents = Get-SoftwareSpecComponents -SoftwareSpec $record.SoftwareSpec

        # Build hashtable with required columns.
        $imageHash = @{
            ID = $index
            DisplayName = $record.DisplayName
            BaseImage = if ($specComponents.BaseImage) { $specComponents.BaseImage } else { "(not available)" }
            ImageId = $record.Id
        }

        # Add other columns only if they're available across any record.
        if ($availableColumns.AddOn) {
            $imageHash['AddOn'] = if ($specComponents.AddOn) { $specComponents.AddOn } else { "" }
        }
        if ($availableColumns.Components) {
            $imageHash['Components'] = if ($specComponents.Components) { $specComponents.Components } else { "" }
        }
        if ($availableColumns.Solutions) {
            $imageHash['Solutions'] = if ($specComponents.Solutions) { $specComponents.Solutions } else { "" }
        }
        if ($availableColumns.HardwareSupport) {
            $imageHash['HardwareSupport'] = if ($specComponents.HardwareSupport) { $specComponents.HardwareSupport } else { "" }
        }
        if ($availableColumns.RemovedComponents) {
            $imageHash['RemovedComponents'] = if ($specComponents.RemovedComponents) { $specComponents.RemovedComponents } else { "" }
        }
        if ($availableColumns.AlternativeImages) {
            $imageHash['AlternativeImages'] = if ($specComponents.AlternativeImages) { $specComponents.AlternativeImages } else { "" }
        }

        $imageSelectionList += [PSCustomObject]$imageHash
        $index++
    }

    # Step 6: Display formatted table of available images.
    Write-LogMessage -Type INFO -Message "Available vLCM images:"
    $selectionTable = $imageSelectionList | Select-Object $columnList
    $tableOutput = $selectionTable | Format-Table -AutoSize | Out-String
    Write-Host $tableOutput.TrimEnd()
    Write-Host ""

    # Step 7: Prompt user for selection.
    $validSelection = $false
    $selectedId = $null

    while (-not $validSelection) {
        Write-Host "Enter the ID of the image to select (1-$($imageSelectionList.Count)) or 'c' to cancel: " -NoNewline -ForegroundColor Yellow
        $userInput = Read-Host

        # Check for cancel option.
        if ($userInput -eq 'c' -or $userInput -eq 'C') {
            Write-Host ""
            Write-LogMessage -Type WARNING -Message "User cancelled vLCM image selection."
            Write-LogMessage -Type ERROR -Message "vLCM image selection cancelled. Cannot proceed with deployment."
            throw "Deployment failed. Check logs for details."
        }
        elseif ($userInput -match '^\d+$') {
            $selectedId = [int]$userInput

            if ($selectedId -ge 1 -and $selectedId -le $imageSelectionList.Count) {
                $selectedImage = $imageSelectionList | Where-Object { $_.ID -eq $selectedId }
                Write-Host ""
                Write-LogMessage -Type DEBUG -Message "Selected image: $($selectedImage.DisplayName) - ID: $($selectedImage.ImageId)"
                # Return the image's ID.
                return $selectedImage.ImageId
            }
            else {
                Write-Host "Invalid selection. Please enter a number between 1 and $($imageSelectionList.Count), or 'c' to cancel." -ForegroundColor Red
            }
        }
        else {
            Write-Host "Invalid input. Please enter a number between 1 and $($imageSelectionList.Count), or 'c' to cancel." -ForegroundColor Red
        }
    }
}

Function Initialize-SimpleSupervisorDeploymentAtScale {

    <#
        .SYNOPSIS
        Initializes a complete VMware vSphere one-node deployment environment.

        .DESCRIPTION
        This function performs a comprehensive initialization of a VMware vSphere one-node deployment environment.
        It reads configuration data from input JSON files and performs the following operations:

        - Extracts configuration variables for vCenter, ESX host, cluster, supervisor, datacenter, datastore, storage policies, virtual distributed switch, content library, and ArgoCD
        - Prompts for and securely stores vCenter and ESX host credentials
        - Establishes connections to vCenter and validates ESX host connectivity
        - Creates and configures a vSphere cluster with HA, DRS, and admission control settings
        - Adds the ESX host to the cluster
        - Creates VMFS datastore and storage policies
        - Sets up virtual distributed switch with port groups and uplinks
        - Creates and configures Kubernetes supervisor cluster
        - Installs ArgoCD operator and creates ArgoCD service
        - Creates local content library for VM templates
        - Sets up ArgoCD namespace with appropriate storage policies and VM classes
        - Creates ArgoCD instance with proper context configuration
        - Manages environment variables for password-less access
        - Properly disconnects from vCenter upon completion

        .NOTES
        This function requires the Script:inputData and Script:supervisorData variables to be populated
        from their respective JSON configuration files before execution.

        The function performs interactive credential prompts and establishes persistent vCenter connections.
        All operations are logged and the function handles cleanup of connections upon completion.

        .EXAMPLE
        Initialize-SimpleSupervisorDeploymentAtScale -InfrastructureJson "infrastructure.json" -SupervisorJson "supervisor.json"

        This will start the complete one-node deployment process using the specified configuration files.

    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$InfrastructureJson,

        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$SupervisorJson
    )

    # Convert the input JSON file to a PowerShell object.
    Write-LogMessage -Type DEBUG -Message "Entered Initialize-SimpleSupervisorDeploymentAtScale function..."

    try {
        $inputData = ConvertFrom-JsonSafely -JsonFilePath $InfrastructureJson

        # vCenter variables.
        $Script:VCenterName = $inputData.common.vCenterName
        $Script:VCenterUser = $inputData.common.VcenterUser
        # ESX host variables.
        $esxHost = $inputData.common.esxHost
        $esxUser = $inputData.common.esxUser
        $datastoreName = $inputData.common.datastore.datastoreName

        # Cluster variable.
        $clusterName = $inputData.common.clusterName
        # Supervisor variables.
        $Script:SupervisorName = $inputData.common.supervisorName
        # Datacenter variables.
        $datacenterName = $inputData.common.datacenterName
        # Datastore variables
        $datastoreName = $inputData.common.datastore.datastoreName
        # Storage policy variables.
        $storagePolicyName = $inputData.common.storagePolicy.storagePolicyName
        $storagePolicyTagCatalog = $inputData.common.storagePolicy.storagePolicyTagCatalog
        $storagePolicyType = $inputData.common.storagePolicy.storagePolicyType
        $storagePolicyRule = $inputData.common.storagePolicy.storagePolicyRule
        # Virtual distributed Switch variables.
        $vdsName = $inputData.common.virtualDistributedSwitch.vdsName
        $vdsVersion = $inputData.common.virtualDistributedSwitch.vdsVersion
        $numUplinks = $inputData.common.virtualDistributedSwitch.numUplinks
        $portGroups = $inputData.common.virtualDistributedSwitch.portGroups
        $nicList = $inputData.common.virtualDistributedSwitch.nicList

        # argoCD variables.
        $argoCDyaml = $inputData.common.argoCD.argoCdOperatorYamlPath
        $contextName = $inputData.common.argoCD.contextName
        $argocdNameSpace = $inputData.common.argoCD.nameSpace
        $argocdVmClass  = $inputData.common.argoCD.vmClass
        $argoCdDeploymentYamlPath = $inputData.common.argoCD.argoCdDeploymentYamlPath

        # Check if the vcf-cli utility is available.
        Test-CommandAvailability -Command $Script:VcfCmd -Description "vcf-cli"

        # Check if the kubectl utility is available.
        Test-CommandAvailability -Command $Script:KubectlCmd -Description "kubectl"

        # Check if the namespace is consistent in the argoCD deployment yaml file.
        Write-LogMessage -Type DEBUG -Message "Checking if the namespace value specified in `"$InfrastructureJson`" is consistent with the namespace value specified in the ArgoCD deployment yaml file."
        $isValid = Test-YamlPropertyConsistency -yamlFilePath $argoCdDeploymentYamlPath -allowMissingProperties @("metadata.namespace") -expectedValues @($argocdNameSpace) -validationName "namespace consistency"
        if (-Not $isValid) {
            Write-LogMessage -Type ERROR -Message "ArgoCD deployment YAML file validation failed. Please check the error messages above for details."
            Write-LogMessage -Type ERROR -Message "Common issues:"
            Write-LogMessage -Type ERROR -Message "  - The file path specified in infrastructure.json may be incorrect"
            Write-LogMessage -Type ERROR -Message "  - The file may not exist at the specified location"
            Write-LogMessage -Type ERROR -Message "  - If using a relative path, ensure you're running from the correct directory"
            throw "Deployment failed: ArgoCD deployment YAML file validation failed. Please check the logs above for specific error details."
        } else {
            Write-LogMessage -Type DEBUG -Message "The namespace specified in $InfrastructureJson is consistent in the ArgoCD deployment yaml file."
        }

        # Get the password for the vCenter and ESX host from the user and store in secure strings.
        $vCenterPass = Get-InteractiveInput -PromptMessage "`nEnter the password for the user `"$Script:VCenterUser`" on vCenter `"$Script:VCenterName`" " -asSecureString
        $esxPassword = Get-InteractiveInput -PromptMessage "`nEnter the password for the user `"$esxUser`" on ESX Host `"$esxHost`" " -asSecureString

        # Add blank line after password prompts for better readability.
        Write-Host ""

        # Create PSCredential objects for the vCenter and ESX host.
        $vCenterCredential = New-Object System.Management.Automation.PSCredential($Script:VCenterUser, $vCenterPass)
        $esxCredential = New-Object System.Management.Automation.PSCredential($esxUser, $esxPassword)

        # Before we connect to vCenter. Disconnect from all servers.
        Disconnect-Vcenter -allServers -silence

        # Connect to the vCenter and persist the connection until the end of the script.
        Connect-Vcenter -serverName $Script:VCenterName -serverCredential $vCenterCredential -serverType "vCenter"

        # Check if the vCenter version is supported.
        $result = Test-VCenterVersion -minimumVersion "9.0.0"
        if (-not $result.Success) {
            # Connection cleanup handled by function-level finally block.

            throw "Deployment failed. Check logs for details."
        }

        # Connect to the ESX host to validate connection and find datastore.
        try {
            Connect-Vcenter -serverName $esxHost -serverCredential $esxCredential -serverType "ESX"
            $diskCanonicalName = Find-Datastore -esxHostName $esxHost -datastoreName $datastoreName
        }
        catch {
            # Check if this is an authentication error (already logged in Connect-Vcenter).
            $errorMessage = $_.Exception.Message
            if ($errorMessage -notmatch "Authentication failed") {
                Write-LogMessage -Type ERROR -Message "Something unexpected happening connecting to ESX host `"$esxHost`" or find datastore `"$datastoreName`" : $_"
            }
            # Set flag for cleanup.
            $esxConnectionFailed = $true
        }
        finally {
            # Always disconnect ESX (if connected), even on errors
            Disconnect-Vcenter -serverName $esxHost -serverType "ESX" -silence
            # Exit after cleanup if connection failed.

            # Function-level finally block will also handle vCenter cleanup.

            if ($esxConnectionFailed) {
                throw "Deployment failed. Check logs for details."
            }
        }

        # Create cluster with HAEnabled, DrsEnabled, AdmissionControlDisabled are by default.

        Add-Cluster -clusterName $clusterName -dataCenterName $datacenterName
        Add-HostToCluster -clusterName $clusterName -esxHostName $esxHost -esxCredential $esxCredential

        # Create the tag catalog category.
        Test-TagCatalogCategory -tagCatalog $storagePolicyTagCatalog

        # Create the tag name.
        Test-Tag -tagCatalog $storagePolicyTagCatalog -tagName $Script:SupervisorName

        # The follow command updates HA properties on the cluster.
        Update-Cluster -clusterName $clusterName

        # Create VMFS Datastore on the ESX host.
        try {
            $esxHost = Get-VMHost -Name $esxHost -Server $Script:VCenterName -ErrorAction SilentlyContinue
        }
        catch {
            Write-LogMessage -Type ERROR -Message "Failed to get the ESX host `"$esxHost`" on vCenter `"$Script:VCenterName`": $_"
            # Connection cleanup handled by function-level finally block.

            throw "Deployment failed. Check logs for details."
        }
        Set-NewDatastore -datastoreName $datastoreName -esxHost $esxHost -diskCanonicalName $diskCanonicalName -tagName $Script:SupervisorName

        # Create a VMFS Storage Policy.
        Set-VMFSStoragePolicy -policyName $storagePolicyName -storageType $storagePolicyType -ruleValue $storagePolicyRule -datastoreName $datastoreName -tagName $Script:SupervisorName -tagCatalog $storagePolicyTagCatalog

        # Creates a distributed switch on the cluster.
        Set-VirtualDistributedSwitch -vdsName $vdsName -datacenterName $datacenterName -numUplinks $numUplinks -vdsVersion $vdsVersion -clusterName $clusterName -portGroups $portGroups -nicList $nicList

        # Convert SecureString to plain text.
        $decodedPasswordInterimStep = [System.Runtime.InteropServices.Marshal]::SecureStringToCoTaskMemUnicode($vCenterPass)
        $vCenterPasswordDecrypted = [System.Runtime.InteropServices.Marshal]::PtrToStringUni($decodedPasswordInterimStep)
          # Clear the value from memory.
        [System.Runtime.InteropServices.Marshal]::ZeroFreeCoTaskMemUnicode($decodedPasswordInterimStep)

        # Get the cluster MoRef ID.
        $clusterId = Get-ClusterId -clusterName $clusterName

        $storagePolicyId = Get-StoragePolicyId -storagePolicyName $storagePolicyName

        # Get or create supervisor using the new function.

        $supervisorId = Get-OrCreateSupervisor -storagePolicyId $storagePolicyId -supervisorName $Script:SupervisorName -vCenterPasswordDecrypted $vCenterPasswordDecrypted -supervisorJson $SupervisorJson -clusterId $clusterId -clusterName $clusterName -insecureTls

        # Set environmental variables for password-less access for creating an ArgoCD instance.
        try {
            $env:VCF_CLI_VSPHERE_PASSWORD = $vCenterPasswordDecrypted
            $env:KUBECTL_VSPHERE_PASSWORD = $vCenterPasswordDecrypted
            # Create an argoCD Operator.
            Set-ArgoCDService -Path $argoCDyaml
            $argoServiceName, $argoServiceVersion = Get-ArgoCDServiceDetail -Path $argoCDyaml
            Install-ArgoCDOperator -clusterId $clusterId -supervisorId $supervisorId -service $argoServiceName -version $argoServiceVersion

            # Create ArgoCD namespace using the supervisor id.
            Add-ArgoCDNamespace -supervisorId $supervisorId -argoCdNamespace $argocdNameSpace -storagePolicyId $storagePolicyId -vmClasses $argocdVmClass

            # Create an argoCD Instance using the cluster name.
            $supervisorControlPlaneVmIp = Get-SupervisorControlPlaneIp -clusterName $clusterName
            Set-VCFContextCreate -contextName $contextName -endpoint $supervisorControlPlaneVmIp -ssoUsername $Script:VCenterUser -insecureTls
            # Create an argoCD Instance using the cluster name.
            Add-ArgoCDInstance -argoCdNamespace $argocdNameSpace -argoCdDeploymentYamlPath $argoCdDeploymentYamlPath -contextName $contextName -clusterId $clusterId -service $argoServiceName -insecureTls

            Show-ArgoCDInstanceDetails -argoCdNamespace $argocdNameSpace
            } finally {
                # Always cleanup environment variables, even on errors.

                Remove-Item env:\VCF_CLI_VSPHERE_PASSWORD -ErrorAction SilentlyContinue
                Remove-Item env:\KUBECTL_VSPHERE_PASSWORD -ErrorAction SilentlyContinue
            }
    } finally {
        # Always cleanup vCenter connections on ANY exit (normal, error, or Ctrl+C)
        # This ensures no leaked connections regardless of how the function exits.

        Disconnect-Vcenter -allServers -silence
    }
}

Function ConvertFrom-Yaml {

    <#
    .SYNOPSIS
        Converts YAML content to PowerShell objects using native PowerShell parsing.

    .DESCRIPTION
        The ConvertFrom-Yaml function parses YAML content and converts it into PowerShell hashtables
        and arrays. This is a native PowerShell implementation that doesn't require external dependencies.
        It returns an array containing hashtables representing the parsed YAML structure.

        Key features:
        - Native PowerShell implementation (no external dependencies)
        - Supports nested objects and arrays
        - Handles multi-document YAML (separated by ---)
        - Returns structured PowerShell objects for easy property access
        - Comprehensive error handling with detailed error messages

    .PARAMETER YamlContent
        The YAML content as a string to be parsed. This can be single or multi-document YAML.

    .EXAMPLE
        $yaml = @"
        name: John Doe
        age: 30
        address:
          street: 123 Main St
          city: New York
        "@
        $result = ConvertFrom-Yaml -YamlContent $yaml
        $result[0].name  # Returns: John Doe

    .OUTPUTS
        System.Array
        Returns an array containing hashtables representing the parsed YAML structure.

    .NOTES
        This function is designed to work with the internal ConvertFrom-YamlInternal function
        which handles the actual parsing logic. The function uses PowerShell's pipeline
        capabilities for efficient processing of YAML content.

    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)] [ValidateNotNullOrEmpty()] [string]$YamlContent

    )

    begin {
        Write-LogMessage -Type DEBUG -Message "Entered ConvertFrom-Yaml function..."

        # Initialize an ArrayList to collect YAML lines from pipeline input.

        # Using ArrayList for better performance when adding multiple items.

        $yamlLines = New-Object System.Collections.ArrayList
    }

    process {
        # Split the YAML content into individual lines for processing.

        # This handles both Windows (\r\n) and Unix (\n) line endings
        # Split on \n and then trim \r from each line to handle cross-platform line endings.

        $lines = $YamlContent -split "`n"

        # Add each line to our collection for later processing.

        # Out-Null suppresses the ArrayList.Add() return value (index)
        foreach ($line in $lines) {
            # TrimEnd removes any trailing \r from Windows line endings.

            $yamlLines.Add($line.TrimEnd("`r")) | Out-Null
        }
    }

    end {
        try {
            # Call the internal YAML parsing function with collected lines.

            # This returns an array containing hashtables representing the YAML structure.

            return ConvertFrom-YamlInternal -YamlLines $yamlLines
        }
        catch {
            # Provide detailed error information for troubleshooting YAML parsing issues.

            Write-Error "Failed to parse YAML: $($_.Exception.Message)"
            return Write-ErrorAndReturn -ErrorMessage "YAML parsing failed: $($_.Exception.Message)" -ErrorCode "ERR_YAML_PARSE"
        }
    }
}

Function ConvertTo-Yaml {

    <#
    .SYNOPSIS
        Converts a PowerShell object to YAML format.

    .DESCRIPTION
        The ConvertTo-Yaml function converts PowerShell objects (hashtables, arrays, PSCustomObjects)
        into YAML format. It supports nested objects, arrays, and various data types including
        strings, numbers, booleans, and null values.

    .PARAMETER InputObject
        The PowerShell object to be converted to YAML format. This can be a hashtable,
        PSCustomObject, array, or any other PowerShell object.

    .PARAMETER IndentSize
        The number of spaces to use for indentation in the YAML output. Default is 2.

    .EXAMPLE
        $object = @{
            name = "John Doe"
            age = 30
            skills = @("PowerShell", "Python")
            address = @{
                street = "123 Main St"
                city = "New York"
            }
        }
        ConvertTo-Yaml -InputObject $object

    .EXAMPLE
        $array = @("item1", "item2", "item3")
        ConvertTo-Yaml -InputObject $array -IndentSize 4

    .OUTPUTS
        System.String
        Returns the YAML representation of the input object.

    .NOTES
        Author: PowerShell YAML Parser
        Version: 1.0.0

    #>

    [CmdletBinding()]
    Param (
        [Parameter()] [ValidateRange(1, [int]::MaxValue)] [int]$IndentSize = 2,

        [Parameter(Mandatory = $true, ValueFromPipeline = $true)] [object]$InputObject
    )

    begin {
        Write-LogMessage -Type DEBUG -Message "Entered ConvertTo-Yaml function..."

        $yamlContent = New-Object System.Collections.ArrayList
    }

    process {
        $lines = ConvertTo-YamlInternal -InputObject $InputObject -IndentSize $IndentSize -CurrentIndent 0
        foreach ($line in $lines) {
            $yamlContent.Add($line) | Out-Null
        }
    }

    end {
        return $yamlContent -join "`n"
    }
}

Function ConvertFrom-YamlInternal {

    <#
    .SYNOPSIS
        Internal function that parses YAML lines into a PowerShell array.

    .DESCRIPTION
        The ConvertFrom-YamlInternal function is an internal helper function that processes
        an array of YAML lines and converts them into a PowerShell array containing a hashtable. It handles
        nested objects, arrays, and various YAML structures using a stack-based approach
        to maintain proper indentation levels.

    .PARAMETER YamlLines
        An array of strings representing the YAML content, where each string is a line
        from the YAML document.

    .EXAMPLE
        $yamlLines = @(
            "name: John Doe",
            "age: 30",
            "address:",
            "  street: 123 Main St",
            "  city: New York"
        )
        $result = ConvertFrom-YamlInternal -YamlLines $yamlLines

    .OUTPUTS
        System.Array
        Returns an array containing a hashtable representing the parsed YAML structure.

    .NOTES
        This is an internal function used by ConvertFrom-Yaml. It should not be called
        directly in most scenarios.

        Author: PowerShell YAML Parser
        Version: 1.0.0

    #>

    Param (
        [ValidateNotNullOrEmpty()] [string[]]$YamlLines
    )

    Write-LogMessage -Type DEBUG -Message "Entered ConvertFrom-YamlInternal function..."

    $result = @{}
    $stack = New-Object System.Collections.ArrayList
    $currentObject = $result
    $lineNumber = 0

    foreach ($line in $YamlLines) {
        $lineNumber++
        $trimmedLine = $line.TrimEnd()

        # Skip empty lines and comments.

        if ([string]::IsNullOrWhiteSpace($trimmedLine) -or $trimmedLine.StartsWith('#')) {
            continue
        }

        # Calculate indentation level
        $currentIndentLevel = ($line.Length - $line.TrimStart().Length) / 2

        # Remove processed items from stack that are at same or higher level.

        while ($stack.Count -gt 0) {
            $lastItem = $stack[$stack.Count - 1]
            if ($lastItem.IndentLevel -ge $currentIndentLevel) {
                $stack.RemoveAt($stack.Count - 1)
            } else {
                break
            }
        }

        # Parse the line
        $parsedItem = New-YamlLine -Line $trimmedLine -LineNumber $lineNumber

        if ($null -ne $parsedItem) {
            # Set the current object based on stack.

            if ($stack.Count -eq 0) {
                $currentObject = $result
            } else {
                $currentObject = $stack[$stack.Count - 1].Object
            }

            # Handle different types of YAML structures.

            if ($parsedItem.Type -eq "KeyValue") {
                Add-ObjectProperty -Object $currentObject -Path $parsedItem.Key -Value $parsedItem.Value
            }
            elseif ($parsedItem.Type -eq "ArrayItem") {
                if (-not $currentObject.ContainsKey($parsedItem.Key)) {
                    $currentObject[$parsedItem.Key] = New-Object System.Collections.ArrayList
                }
                $currentObject[$parsedItem.Key].Add($parsedItem.Value) | Out-Null
            }
            elseif ($parsedItem.Type -eq "ObjectStart") {
                $newObject = @{}
                Add-ObjectProperty -Object $currentObject -Path $parsedItem.Key -Value $newObject
                $stack.Add(@{
                    Object = $newObject
                    IndentLevel = $currentIndentLevel
                }) | Out-Null
            }
            elseif ($parsedItem.Type -eq "ArrayStart") {
                $newArray = New-Object System.Collections.ArrayList
                Add-ObjectProperty -Object $currentObject -Path $parsedItem.Key -Value $newArray
                $stack.Add(@{
                    Object = $newArray
                    IndentLevel = $currentIndentLevel
                    IsArray = $true
                }) | Out-Null
            }
        }
    }

    # Return the hashtable wrapped in an array.
    $array = New-Object System.Object[] 1
    $array[0] = $result
    return $array
}

Function New-YamlLine {

    <#
    .SYNOPSIS
        Parses a single YAML line and returns a structured object representing its content.

    .DESCRIPTION
        The New-YamlLine function analyzes a single YAML line and determines its type
        (key-value pair, array item, object start, or array start). It returns a hashtable
        with type information and parsed values that can be used by the YAML parser.

    .PARAMETER Line
        The YAML line to be parsed. Should be trimmed of leading/trailing whitespace.

    .PARAMETER LineNumber
        The line number in the YAML document for error reporting purposes.

    .EXAMPLE
        $result = New-YamlLine -Line "name: John Doe" -LineNumber 1
        # Returns: @{ Type = "KeyValue"; Key = "name"; Value = "John Doe" }

    .EXAMPLE
        $result = New-YamlLine -Line "- item1" -LineNumber 5
        # Returns: @{ Type = "ArrayItem"; Key = ""; Value = "item1" }

    .EXAMPLE
        $result = New-YamlLine -Line "address:" -LineNumber 10
        # Returns: @{ Type = "ObjectStart"; Key = "address"; Value = $null }

    .OUTPUTS
        System.Collections.Hashtable
        Returns a hashtable with the following possible properties:
        - Type: "KeyValue", "ArrayItem", "ObjectStart", or "ArrayStart"
        - Key: The key name (empty for array items)
        - Value: The parsed value (null for object/array starts)

    .NOTES
        This is an internal function used by ConvertFrom-YamlInternal. It should not be
        called directly in most scenarios.

        Author: PowerShell YAML Parser
        Version: 1.0.0

    #>

    Param (
        [string]$Line,
        [int]$LineNumber

    )

    Write-LogMessage -Type DEBUG -Message "Entered New-YamlLine function..."

    # Handle array items (starting with -)
    if ($Line.StartsWith('- ')) {
        $value = $Line.Substring(2).Trim()
        return @{
            Type = "ArrayItem"
            Key = ""
            Value = ConvertFrom-YamlValue -Value $value
        }
    }

    # Handle key-value pairs.
    if ($Line.Contains(':')) {
        $colonIndex = $Line.IndexOf(':')
        $key = $Line.Substring(0, $colonIndex).Trim()
        $value = $Line.Substring($colonIndex + 1).Trim()

        # Check if this is an object or array start.

        if ([string]::IsNullOrWhiteSpace($value)) {
            # Check next non-empty line to determine if it's an object or array.

            return @{
                Type = "ObjectStart"
                Key = $key
                Value = $null
            }
        }
        elseif ($value -eq '[]') {
            return @{
                Type = "ArrayStart"
                Key = $key
                Value = $null
            }
        }
        else {
            return @{
                Type = "KeyValue"
                Key = $key
                Value = ConvertFrom-YamlValue -Value $value
            }
        }
    }

    return $null
}


Function ConvertFrom-YamlValue {

    <#
    .SYNOPSIS
        Converts a YAML value string to its appropriate PowerShell data type.

    .DESCRIPTION
        The ConvertFrom-YamlValue function takes a YAML value string and converts it to
        the appropriate PowerShell data type. It handles strings, numbers, booleans, null
        values, and removes quotes when appropriate.

    .PARAMETER Value
        The YAML value string to be converted to a PowerShell object.

    .EXAMPLE
        $result = ConvertFrom-YamlValue -Value "John Doe"
        # Returns: "John Doe" (string)

    .EXAMPLE
        $result = ConvertFrom-YamlValue -Value "30"
        # Returns: 30 (integer)

    .EXAMPLE
        $result = ConvertFrom-YamlValue -Value "true"
        # Returns: $true (boolean)

    .EXAMPLE
        $result = ConvertFrom-YamlValue -Value "null"
        # Returns: $null

    .EXAMPLE
        $result = ConvertFrom-YamlValue -Value '"quoted string"'
        # Returns: "quoted string" (unquoted string)

    .OUTPUTS
        System.Object
        Returns the converted value as the appropriate PowerShell data type:
        - String (unquoted)
        - Integer (for numeric strings)
        - Double (for decimal strings)
        - Boolean (for true/false values)
        - Null (for null/empty values)

    .NOTES
        This is an internal function used by New-YamlLine. It should not be called
        directly in most scenarios.

        Author: PowerShell YAML Parser
        Version: 1.0.0

    #>

    Param (
        [string]$Value
    )

    Write-LogMessage -Type DEBUG -Message "Entered ConvertFrom-YamlValue function..."

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    # Remove quotes if present.
    if (($Value.StartsWith('"') -and $Value.EndsWith('"')) -or
        ($Value.StartsWith("'") -and $Value.EndsWith("'"))) {
        return $Value.Substring(1, $Value.Length - 2)
    }

    # Try to parse as number.
    if ($Value -match '^-?\d+$') {
        return [int]$Value
    }
    elseif ($Value -match '^-?\d+\.\d+$') {
        return [double]$Value
    }

    # Try to parse as boolean.
    if ($Value -eq 'true' -or $Value -eq 'True' -or $Value -eq 'TRUE') {
        return $true
    }
    elseif ($Value -eq 'false' -or $Value -eq 'False' -or $Value -eq 'FALSE') {
        return $false
    }

    # Try to parse as null.
    if ($Value -eq 'null' -or $Value -eq 'Null' -or $Value -eq 'NULL' -or $Value -eq '~') {
        return $null
    }

    # Return as string.
    return $Value
}


Function Add-ObjectProperty {

    <#
    .SYNOPSIS
        Adds a property to a hashtable object with the specified key and value.

    .DESCRIPTION
        The Add-ObjectProperty function adds a property to a hashtable object using the
        specified key (path) and value. This is a simple helper function used internally
        by the YAML parser to set properties on objects during parsing.

    .PARAMETER Object
        The hashtable object to which the property will be added.

    .PARAMETER Path
        The key name for the property to be added to the object.

    .PARAMETER Value
        The value to be assigned to the property.

    .EXAMPLE
        $obj = @{}
        Add-ObjectProperty -Object $obj -Path "name" -Value "John Doe"
        # $obj now contains: @{ name = "John Doe" }

    .EXAMPLE
        $obj = @{}
        Add-ObjectProperty -Object $obj -Path "age" -Value 30
        # $obj now contains: @{ age = 30 }

    .EXAMPLE
        $obj = @{}
        Add-ObjectProperty -Object $obj -Path "address" -Value @{ street = "123 Main St" }
        # $obj now contains: @{ address = @{ street = "123 Main St" } }

    .OUTPUTS
        None
        This function modifies the input object in place and does not return a value.

    .NOTES
        This is an internal function used by ConvertFrom-YamlInternal. It should not be
        called directly in most scenarios.

        Author: PowerShell YAML Parser
        Version: 1.0.0

    #>

    Param (
        [hashtable]$Object,
        [string]$Path,

        [object]$Value
    )

    Write-LogMessage -Type DEBUG -Message "Entered Add-ObjectProperty function..."

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return
    }

    $Object[$Path] = $Value
}

Function ConvertTo-YamlInternal {

    <#
    .SYNOPSIS
        Internal helper function that recursively converts PowerShell objects to YAML format with proper indentation.

    .DESCRIPTION
        The ConvertTo-YamlInternal function is an internal helper that performs recursive conversion of PowerShell
        objects (hashtables, PSCustomObjects, arrays, and primitive types) into properly formatted YAML lines
        with appropriate indentation. This function is the core engine behind the ConvertTo-Yaml cmdlet and
        handles the complex logic of traversing nested object structures while maintaining proper YAML formatting.

        The function processes different object types as follows:
        - Hashtables and PSCustomObjects: Converts properties to key-value pairs with nested indentation
        - Arrays and ArrayLists: Converts items to YAML list format with dash prefixes
        - Nested objects: Recursively processes with increased indentation levels
        - Primitive values: Delegates to ConvertTo-YamlValue for proper type conversion

        The function maintains proper YAML indentation by calculating spaces based on the current nesting level
        and the specified indent size, ensuring the output conforms to YAML specification standards.

    .PARAMETER InputObject
        The PowerShell object to be converted to YAML format. This can be any type of object including:
        - Hashtables containing key-value pairs
        - PSCustomObjects with properties
        - Arrays or ArrayLists containing multiple items
        - Primitive types (strings, numbers, booleans)
        - Nested combinations of the above types

    .PARAMETER IndentSize
        The number of spaces to use for each level of indentation in the YAML output.
        This parameter controls the visual formatting and nesting structure of the generated YAML.
        Common values are 2 or 4 spaces per indentation level to match YAML conventions.

    .PARAMETER CurrentIndent
        The current indentation level for the object being processed. This parameter is used
        internally during recursive calls to maintain proper nesting depth. The actual number
        of spaces used for indentation is calculated as (CurrentIndent * IndentSize).
        This parameter starts at 0 for root-level objects and increments for each nesting level.

    .EXAMPLE
        # This function is typically called internally by ConvertTo-Yaml.

        $hashtable = @{
            name = "John Doe"
            age = 30
            skills = @("PowerShell", "Python")
            address = @{
                street = "123 Main St"
                city = "New York"
            }
        }
        $yamlLines = ConvertTo-YamlInternal -InputObject $hashtable -IndentSize 2 -CurrentIndent 0

        This example would produce YAML lines with proper indentation:
        name: John Doe
        age: 30
        skills:
          - PowerShell
          - Python
        address:
          street: 123 Main St
          city: New York

    .EXAMPLE
        # Processing an array at indentation level 1.

        $array = @("item1", "item2", "item3")
        $yamlLines = ConvertTo-YamlInternal -InputObject $array -IndentSize 2 -CurrentIndent 1

        This would produce:
          - item1
          - item2
          - item3

    .OUTPUTS
        System.Collections.ArrayList
        Returns an ArrayList containing strings, where each string represents a line of YAML output
        with appropriate indentation. The caller can join these lines with newline characters to
        create the final YAML document.

    .NOTES
        - This is an internal function used by ConvertTo-Yaml and should not be called directly in most scenarios
        - The function uses recursive calls to handle nested object structures
        - Proper YAML formatting is maintained through careful indentation management
        - The function delegates primitive value conversion to ConvertTo-YamlValue for consistency
        - Output suppression (| Out-Null) is used when adding items to ArrayList to prevent index output
        - The function handles both hashtables and PSCustomObjects uniformly through PSObject.Properties

        Author: PowerShell YAML Parser
        Version: 1.0.0
        Dependencies: ConvertTo-YamlValue function for primitive type conversion

    #>

    Param (
        [int]$CurrentIndent,
        [int]$IndentSize,

        [object]$InputObject
    )

    Write-LogMessage -Type DEBUG -Message "Entered ConvertTo-YamlInternal function..."

    $yamlLines = New-Object System.Collections.ArrayList
    $indent = " " * ($CurrentIndent * $IndentSize)

    if ($InputObject -is [hashtable] -or $InputObject -is [PSCustomObject]) {
        foreach ($property in $InputObject.PSObject.Properties) {
            $key = $property.Name
            $value = $property.Value

            if ($value -is [array] -or $value -is [System.Collections.ArrayList]) {
                $yamlLines.Add("$indent$key`:") | Out-Null
                foreach ($item in $value) {
                    $yamlLines.Add("$indent  - $(ConvertTo-YamlValue -Value $item -IndentSize $IndentSize -CurrentIndent $CurrentIndent + 1)") | Out-Null
                }
            }
            elseif ($value -is [hashtable] -or $value -is [PSCustomObject]) {
                $yamlLines.Add("$indent$key`:") | Out-Null
                $subLines = ConvertTo-YamlInternal -InputObject $value -IndentSize $IndentSize -CurrentIndent $CurrentIndent + 1
                foreach ($line in $subLines) {
                    $yamlLines.Add($line) | Out-Null
                }
            }
            else {
                $yamlLines.Add("$indent$key`: $(ConvertTo-YamlValue -Value $value -IndentSize $IndentSize -CurrentIndent $CurrentIndent)") | Out-Null
            }
        }
    }
    elseif ($InputObject -is [array] -or $InputObject -is [System.Collections.ArrayList]) {
        foreach ($item in $InputObject) {
            $yamlLines.Add("$indent- $(ConvertTo-YamlValue -Value $item -IndentSize $IndentSize -CurrentIndent $CurrentIndent)") | Out-Null
        }
    }
    else {
        $yamlLines.Add("$indent$(ConvertTo-YamlValue -Value $InputObject -IndentSize $IndentSize -CurrentIndent $CurrentIndent)") | Out-Null
    }

    return $yamlLines
}

Function ConvertTo-YamlValue {

    <#
    .SYNOPSIS
        Converts a PowerShell object to its YAML string representation.

    .DESCRIPTION
        The ConvertTo-YamlValue function converts a PowerShell object to its appropriate
        YAML string representation. It handles various data types including strings,
        numbers, booleans, null values, hashtables, arrays, and complex objects.

    .PARAMETER Value
        The PowerShell object to be converted to YAML format.

    .PARAMETER IndentSize
        The number of spaces to use for indentation in nested structures.

    .PARAMETER CurrentIndent
        The current indentation level for proper formatting.

    .EXAMPLE
        $result = ConvertTo-YamlValue -Value "Hello World" -IndentSize 2 -CurrentIndent 0
        # Returns: "Hello World"

    .EXAMPLE
        $result = ConvertTo-YamlValue -Value 42 -IndentSize 2 -CurrentIndent 0
        # Returns: "42"

    .EXAMPLE
        $result = ConvertTo-YamlValue -Value $true -IndentSize 2 -CurrentIndent 0
        # Returns: "true"

    .EXAMPLE
        $result = ConvertTo-YamlValue -Value $null -IndentSize 2 -CurrentIndent 0
        # Returns: "null"

    .EXAMPLE
        $result = ConvertTo-YamlValue -Value @("item1", "item2") -IndentSize 2 -CurrentIndent 0
        # Returns: Multi-line YAML array representation.


    .OUTPUTS
        System.String
        Returns the YAML string representation of the input object.

    .NOTES
        This is an internal function used by ConvertTo-YamlInternal. It should not be
        called directly in most scenarios.

    #>

    Param (
        [int]$CurrentIndent,
        [int]$IndentSize,

        [object]$Value
    )

    Write-LogMessage -Type DEBUG -Message "Entered ConvertTo-YamlValue function..."

    if ($null -eq $Value) {
        return "null"
    }
    elseif ($Value -is [bool]) {
        return $Value.ToString().ToLower()
    }
    elseif ($Value -is [string]) {
        # Escape special characters and add quotes if necessary.

        if ($Value.Contains(':') -or $Value.Contains('"') -or $Value.Contains("'") -or
            $Value.StartsWith(' ') -or $Value.EndsWith(' ') -or
            $Value -match '^[0-9]' -or $Value -match '^(true|false|null)$') {
            return "`"$($Value.Replace('"', '\"'))`""
        }
        return $Value
    }
    elseif ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal]) {
        return $Value.ToString()
    }
    elseif ($Value -is [hashtable] -or $Value -is [PSCustomObject]) {
        $subYaml = ConvertTo-YamlInternal -InputObject $Value -IndentSize $IndentSize -CurrentIndent $CurrentIndent + 1
        return "`n$subYaml"
    }
    elseif ($Value -is [array] -or $Value -is [System.Collections.ArrayList]) {
        $arrayItems = New-Object System.Collections.ArrayList
        foreach ($item in $Value) {
            $itemValue = ConvertTo-YamlValue -Value $item -IndentSize $IndentSize -CurrentIndent $CurrentIndent
            $arrayItems.Add($itemValue) | Out-Null
        }
        return "`n$($arrayItems -join "`n")"
    }
    else {
        return $Value.ToString()
    }
}


Function Test-PortGroupNameUniqueness {

    <#
        .SYNOPSIS
        Validates that all portgroup names are unique within input.json.

        .DESCRIPTION
        This function performs validation to ensure that all portgroup names defined in
        input.json (common.virtualDistributedSwitch.portGroups[].name) are unique within
        that collection. The function checks for duplicates within the portgroup names
        and provides detailed error reporting if any duplicates are found, including
        the VLAN IDs associated with conflicting portgroups.

        .PARAMETER InputData
        The parsed input.json data object containing portgroup configurations.

        .EXAMPLE
        $inputData = ConvertFrom-JsonSafely -JsonFilePath "input.json"
        $result = Test-PortGroupNameUniqueness -InputData $inputData
        if (-not $result.IsValid) {
            Write-Error "Portgroup name validation failed: $($result.ErrorMessage)"
        }

        .OUTPUTS
        PSCustomObject
        Returns an object with the following properties:
        - IsValid: Boolean indicating if all portgroup names are unique
        - ErrorMessage: String containing details about any validation failures
        - DuplicateNames: Array of duplicate portgroup names found
        - AllPortGroupNames: Array of all portgroup names collected for validation

        .NOTES
        This function is case-sensitive for portgroup name comparisons. Portgroup names must be
        exactly identical to be considered duplicates. When duplicates are found, the function
        also reports the VLAN IDs associated with the conflicting portgroups. The function logs
        validation progress and results using the Write-LogMessage function.
    #>

    Param(
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] $inputData
    )

    Write-LogMessage -Type DEBUG -Message "Entered Test-PortGroupNameUniqueness function..."

    Write-LogMessage -Type DEBUG -Message "Starting portgroup name uniqueness validation."

    $duplicateNames = @()
    $validationResult = @{
        IsValid = $true
        ErrorMessage = ""
        DuplicateNames = @()
        AllPortGroupNames = @()
    }

    try {
        # Collect portgroup information from input.json.

        $portGroupDetails = @()
        if ($inputData.common.virtualDistributedSwitch.portGroups) {
            foreach ($portGroup in $inputData.common.virtualDistributedSwitch.portGroups) {
                if ($portGroup.name) {
                    $portGroupDetails += [PSCustomObject]@{
                        Name = $portGroup.name
                        VlanId = $portGroup.vlanId
                    }
                    Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "Found portgroup: '$($portGroup.name)' (VLAN: $($portGroup.vlanId))"
                }
            }
        }

        # Check for duplicates within portgroup names.

        $groupedNames = $portGroupDetails | Group-Object -Property Name
        foreach ($group in $groupedNames) {
            if ($group.Count -gt 1) {
                $duplicateNames += $group.Name
                $vlanIds = $group.Group | ForEach-Object { $_.VlanId }
                $vlanIdList = $vlanIds -join ', '
                Write-LogMessage -Type ERROR -Message "Duplicate portgroup name found: '$($group.Name)' (appears $($group.Count) times) with VLAN IDs: $vlanIdList"
            }
        }

        # Set validation result
        if ($duplicateNames.Count -gt 0) {
            $validationResult.IsValid = $false
            $validationResult.ErrorMessage = "Found $($duplicateNames.Count) duplicate portgroup name(s): $($duplicateNames -join ', ')"
            $validationResult.DuplicateNames = $duplicateNames
            Write-LogMessage -Type ERROR -SuppressOutputToScreen -Message "Portgroup name uniqueness validation failed: $($validationResult.ErrorMessage)"
        } else {
            Write-LogMessage -Type DEBUG -Message "Portgroup name uniqueness validation passed. All $($portGroupDetails.Count) portgroup names are unique."
        }

        $validationResult.AllPortGroupNames = $portGroupDetails | ForEach-Object { $_.Name }

    } catch {
        $validationResult.IsValid = $false
        $validationResult.ErrorMessage = "Error during portgroup name validation: $($_.Exception.Message)"
        Write-LogMessage -Type ERROR -Message $validationResult.ErrorMessage
    }

    return $validationResult
}


# =============================================================================
# Exported Functions
# =============================================================================


Function Start-SimpleSupervisorDeploymentAtScale {

    <#
    .SYNOPSIS
        Automates the end-to-end deployment of a simple vSphere Supervisor at scale in VMware Cloud Foundation 9.x.

    .DESCRIPTION
        Start-SimpleSupervisorDeploymentAtScale is designed to streamline the deployment of a simple vSphere Supervisor in
        VMware Cloud Foundation (VCF) 9.x environments. The function handles all aspects of the deployment including:

        - vCenter and ESX host connection
        - ESX Cluster creation and host add
        - Datastore creation and storage policy configuration.
        - Virtual Distributed Switch (VDS) setup and port group configuration
        - vSphere Supervisor Deployment
        - ArgoCD installation and configuration for GitOps workflows

    .PARAMETER InfrastructureJson
        Path to the infrastructure configuration JSON file.

        Default: "infrastructure.json"

    .PARAMETER SupervisorJson
        Path to the Supervisor Cluster configuration JSON file.

        Default: "supervisor.json"

    .PARAMETER LogLevel
        Sets the minimum log level for console output.

        Default: "INFO"

    .PARAMETER Version
        Displays the module version and exits without performing deployment.

    .EXAMPLE
        Start-SimpleSupervisorDeploymentAtScale

        Executes the deployment using default configuration files.

    .EXAMPLE
        Start-SimpleSupervisorDeploymentAtScale -InfrastructureJson "config/site-a-infrastructure.json" -SupervisorJson "config/site-a-supervisor.json"

        Executes the deployment using custom configuration files.

    .EXAMPLE
        Start-SimpleSupervisorDeploymentAtScale -Version

        Displays the module version and exits.

    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$InfrastructureJson = "infrastructure.json",

        [Parameter(Mandatory = $false)] [ValidateSet("DEBUG", "INFO", "ADVISORY", "WARNING", "EXCEPTION", "ERROR")] [String]$LogLevel = "INFO",
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$SupervisorJson = "supervisor.json",
        [Parameter(Mandatory = $false)] [Switch]$Version
    )

    # Handle version flag
    if ($Version) {
        $versionToDisplay = $null

        # Try to get version from loaded module first.

        $loadedModule = Get-Module -Name "SimpleSupervisorDeploymentAtScale"
        if ($loadedModule -and $loadedModule.Version -and $loadedModule.Version -ne [version]"0.0") {
            $versionToDisplay = $loadedModule.Version.ToString()
        } else {
            # Try to get version from manifest file.

            $modulePath = $null
            if ($PSScriptRoot) {
                $modulePath = $PSScriptRoot
            } else {
                # Try to find module path from loaded module.

                $moduleInfo = Get-Module -Name "SimpleSupervisorDeploymentAtScale" -ListAvailable | Select-Object -First 1
                if ($moduleInfo -and $moduleInfo.ModuleBase) {
                    $modulePath = $moduleInfo.ModuleBase
                }
            }

            if ($modulePath) {
                $manifestPath = Join-Path $modulePath "SimpleSupervisorDeploymentAtScale.psd1"
                if (Test-Path $manifestPath) {
                    try {
                        $manifest = Import-PowerShellDataFile -Path $manifestPath
                        if ($manifest.ModuleVersion) {
                            $versionToDisplay = $manifest.ModuleVersion.ToString()
                        }
                    } catch {
                        # Continue to fallback
                    }
                }
            }

            # Fall back to script variable if we couldn't get version from manifest.

            if (-not $versionToDisplay) {
                $versionToDisplay = $Script:ModuleVersion
            }
        }

        Write-Host "SimpleSupervisorDeploymentAtScale version: $versionToDisplay"
        return
    }

    # Set the progress preference to continue.

    $Global:ProgressPreference = 'Continue'

    # Initialize configured log level from parameter (normalize to uppercase).
    $Script:ConfiguredLogLevel = $LogLevel.ToUpper()

    # Create New log file.
    New-LogFile

    # Log the configured log level.
    Write-LogMessage -Type DEBUG -Message "Log level set to: $Script:ConfiguredLogLevel (screen output filtered, all levels written to file)"

    # Perform shallow validation of input.json and supervisor.json configuration files (presence of properties only).
    Test-JsonShallowValidation -InfrastructureJson $InfrastructureJson -SupervisorJson $SupervisorJson

    # Perform deeper validation of input.json and supervisor.json configuration files (pattern matching of values).
    Test-JsonDeeperValidation -InfrastructureJson $InfrastructureJson -SupervisorJson $SupervisorJson

    # Load JSON data for portgroup name uniqueness validation.

    $inputData = ConvertFrom-JsonSafely -JsonFilePath $InfrastructureJson

    # Validate portgroup name uniqueness within input.json.

    $portGroupNameValidationResult = Test-PortGroupNameUniqueness -inputData $inputData
    if (-not $portGroupNameValidationResult.IsValid) {
        Write-LogMessage -Type ERROR -SuppressOutputToScreen -Message "Portgroup name uniqueness validation failed: $($portGroupNameValidationResult.ErrorMessage)"
        Write-LogMessage -Type ERROR -Message "Deployment cannot proceed with duplicate portgroup names. Please fix the naming conflicts and try again."
        throw "Portgroup name uniqueness validation failed: $($portGroupNameValidationResult.ErrorMessage)"
    } else {
        Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "Portgroup name uniqueness validation passed."
    }

    # Initialize the one node deployment.
    Initialize-SimpleSupervisorDeploymentAtScale -InfrastructureJson $InfrastructureJson -SupervisorJson $SupervisorJson
}

Function Show-SimpleSupervisorDeploymentAtScaleVersion {

    <#
    .SYNOPSIS
        Displays the version information for the SimpleSupervisorDeploymentAtScale module.

    .DESCRIPTION
        Shows the current version of the SimpleSupervisorDeploymentAtScale module.

    .EXAMPLE
        Show-SimpleSupervisorDeploymentAtScaleVersion

        Displays: "SimpleSupervisorDeploymentAtScale version: 1.0.0.2"

    #>

    [CmdletBinding()]
    param()


    Write-Host "SimpleSupervisorDeploymentAtScale version: $Script:ModuleVersion"
}

Function Copy-SimpleSupervisorTemplates {

    <#
    .SYNOPSIS
        Copies supervisor deployment template files to a specified location.

    .DESCRIPTION
        Copy-SimpleSupervisorTemplates copies all four required template files from the module's Templates
        directory to a specified destination. The function copies infrastructure.json, supervisor.json,
        argocd-deployment.yml, and 1.0.1-24896502.yml. If any of these files are missing from the source
        directory, the function will throw an error.

        The template files are included with the module installation and contain example configurations
        that users can modify for their environment.

    .PARAMETER DestinationPath
        The destination directory where the template files will be copied. If not specified, files are
        copied to the current working directory.

        Default: Current working directory ($PWD)

    .PARAMETER WhatIf
        Shows what would happen if the function runs. The function is executed but no changes are made.

    .EXAMPLE
        Copy-SimpleSupervisorTemplates

        Copies all template files (infrastructure.json, supervisor.json, argocd-deployment.yml, and 1.0.1-24896502.yml) to the current working directory.

    .EXAMPLE
        Copy-SimpleSupervisorTemplates -DestinationPath "./config"

        Copies all template files to the ./config subdirectory.

    .EXAMPLE
        Copy-SimpleSupervisorTemplates -WhatIf

        Shows what files would be copied without actually copying them.

    .NOTES
        Template files are located in the module's Templates subdirectory. You can also access them directly
        using the module path:

        $modulePath = (Get-Module -Name SimpleSupervisorDeploymentAtScale -ListAvailable).ModuleBase
        $templatePath = Join-Path $modulePath "Templates"

        The template files contain example values that must be modified for your specific environment.
    #>

    [CmdletBinding(SupportsShouldProcess = $true)]
    Param (
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$DestinationPath = $PWD
    )

    Write-LogMessage -Type DEBUG -Message "Entered Copy-SimpleSupervisorTemplates function..."

    # Validate destination path
    if ([string]::IsNullOrWhiteSpace($DestinationPath)) {
        Write-LogMessage -Type ERROR -Message "Destination path cannot be null, empty, or contain only whitespace characters."
        throw "Deployment failed. Check logs for details."
    }

    # Validate path format (basic validation for invalid characters)
    if ($DestinationPath -match '[<>"|?*]') {
        Write-LogMessage -Type ERROR -Message "Destination path contains invalid characters: $($matches[0])"
        throw "Deployment failed. Check logs for details."
    }

    # Validate that the destination path is valid using Test-Path.

    # Check if parent directory exists (if path has a parent) or if the path itself is valid
    $parentPath = Split-Path -Path $DestinationPath -Parent -ErrorAction SilentlyContinue
    if ($parentPath -and $parentPath -ne $DestinationPath) {
        if (-not (Test-Path -Path $parentPath -ErrorAction SilentlyContinue)) {
            Write-LogMessage -Type ERROR -Message "Destination path parent directory does not exist: $parentPath"
            throw "Deployment failed. Check logs for details."
        }
    }

    # Define the four required template files.

    $requiredTemplateFiles = @("infrastructure.json", "supervisor.json", "argocd-deployment.yml", "1.0.1-24896502.yml")

    # Determine the module's template directory.

    $moduleBase = $null

    # Primary: Use module's ModuleBase if available (most reliable)
    if ($MyInvocation.MyCommand.Module.ModuleBase) {
        $moduleBase = $MyInvocation.MyCommand.Module.ModuleBase
    } elseif ($PSScriptRoot) {
        # Fallback 1: Use PSScriptRoot (when module is loaded)
        $moduleBase = $PSScriptRoot
        # Check if Templates directory exists in current path.

        $templatesCheck = Join-Path $moduleBase "Templates"
        if (-not (Test-Path $templatesCheck)) {
            # If not found, check if we're in root and Templates is in SimpleSupervisorDeploymentAtScale subdirectory.

            # This handles development/testing scenarios.

            $subDirCheck = Join-Path $moduleBase (Join-Path "SimpleSupervisorDeploymentAtScale" "Templates")
            if (Test-Path $subDirCheck) {
                $moduleBase = Join-Path $moduleBase "SimpleSupervisorDeploymentAtScale"
            }
        }
    } else {
        # Fallback 2: Query module system.

        $moduleInfo = Get-Module -Name "SimpleSupervisorDeploymentAtScale" -ListAvailable | Select-Object -First 1
        if ($moduleInfo -and $moduleInfo.ModuleBase) {
            $moduleBase = $moduleInfo.ModuleBase
        }
    }

    if (-not $moduleBase) {
        Write-LogMessage -Type ERROR -Message "Unable to determine module installation path. Please ensure the module is installed correctly."
        throw "Deployment failed. Check logs for details."
    }

    $templatesPath = Join-Path $moduleBase "Templates"

    if (-not (Test-Path $templatesPath)) {
        Write-LogMessage -Type ERROR -Message "Templates directory not found at: $templatesPath"
        throw "Deployment failed. Check logs for details."
    }

    # Validate that all required template files exist before attempting to copy.

    $missingFiles = @()
    foreach ($fileName in $requiredTemplateFiles) {
        $sourceFile = Join-Path $templatesPath $fileName
        if (-not (Test-Path $sourceFile)) {
            $missingFiles += $fileName
        }
    }

    if ($missingFiles.Count -gt 0) {
        Write-LogMessage -Type ERROR -Message "Required template files not found in source directory: $($missingFiles -join ', ')"
        throw "Deployment failed. Check logs for details."
    }

    # Ensure destination directory exists.

    if (-not (Test-Path $DestinationPath)) {
        if ($PSCmdlet.ShouldProcess($DestinationPath, "Create directory")) {
            try {
                New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null
                Write-LogMessage -Type DEBUG -Message "Created destination directory: $DestinationPath"
            } catch {
                Write-LogMessage -Type ERROR -Message "Failed to create destination directory '$DestinationPath': $($_.Exception.Message)"
                throw "Deployment failed. Check logs for details."
            }
        }
    }

    $copiedCount = 0
    $skippedCount = 0

    foreach ($fileName in $requiredTemplateFiles) {
        $sourceFile = Join-Path $templatesPath $fileName
        $destFile = Join-Path $DestinationPath $fileName

        # Check if destination file already exists and prompt for confirmation.

        if (Test-Path $destFile) {
            # Skip prompt if WhatIf is enabled.

            if ($WhatIfPreference) {
                Write-LogMessage -Type INFO -Message "Would overwrite existing file: $destFile"
            } elseif ($PSCmdlet.ShouldProcess($destFile, "Overwrite existing file")) {
                try {
                    $overwrite = Read-Host "File '$destFile' already exists. Overwrite? (Y/N)"
                    if ($overwrite -ne "Y" -and $overwrite -ne "y") {
                        Write-LogMessage -Type INFO -Message "Skipping $fileName - file already exists and user chose not to overwrite."
                        $skippedCount++
                        continue
                    }
                } catch {
                    Write-LogMessage -Type WARNING -Message "User cancelled file overwrite prompt for $fileName."
                    $skippedCount++
                    continue
                }
            } else {
                # ShouldProcess returned false (user declined via Confirm prompt)
                Write-LogMessage -Type INFO -Message "Skipping $fileName - user declined to overwrite existing file."
                $skippedCount++
                continue
            }
        }

        if ($PSCmdlet.ShouldProcess($destFile, "Copy template file")) {
            if ($WhatIfPreference) {
                Write-LogMessage -Type INFO -Message "Would copy $fileName to $DestinationPath"
                $copiedCount++
            } else {
                try {
                    Copy-Item -Path $sourceFile -Destination $destFile -Force
                    Write-LogMessage -Type INFO -Message "Copied $fileName to $DestinationPath"
                    $copiedCount++
                } catch {
                    Write-LogMessage -Type ERROR -Message "Failed to copy $fileName to '$DestinationPath': $($_.Exception.Message)"
                    throw "Deployment failed. Check logs for details."
                }
            }
        } else {
            Write-LogMessage -Type INFO -Message "Would copy $fileName to $DestinationPath"
            $copiedCount++
        }
    }

    # Build and display summary message.

    if ($WhatIfPreference) {
        $summaryMessage = "What if: Performing the operation 'Copy template files' on target '$DestinationPath'. "
        $summaryMessage += "Would copy $copiedCount file(s)"
        if ($skippedCount -gt 0) {
            $summaryMessage += ", would skip $skippedCount file(s) (already exist)"
        }
        Write-LogMessage -Type INFO -Message $summaryMessage
    } elseif ($copiedCount -gt 0) {
        $summaryMessage = "Template files copied successfully to: $DestinationPath ($copiedCount file(s) copied"
        if ($skippedCount -gt 0) {
            $summaryMessage += ", $skippedCount file(s) skipped)"
        } else {
            $summaryMessage += ")"
        }
        Write-LogMessage -Type INFO -Message $summaryMessage
    } elseif ($skippedCount -gt 0) {
        Write-LogMessage -Type INFO -Message "All template files were skipped ($skippedCount file(s) already exist)"
    } else {
        Write-LogMessage -Type INFO -Message "No template files were copied or skipped"
    }
}


Function Format-ConfigurationTable {

    <#
        .SYNOPSIS

        Formats configuration data as a table.

        .DESCRIPTION
        Internal helper function that formats an array of configuration objects as a table.

        .PARAMETER InputObject
        Array of PSCustomObject configuration items to format.

    #>

    [CmdletBinding()]

    Param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)] [PSCustomObject[]]$InputObject
    )

    Begin {
        $allItems = @()
        $seenElements = @{}
    }

    Process {
        # Handle both single objects and arrays.

        if ($null -ne $InputObject) {
            if ($InputObject -is [Array]) {
                foreach ($item in $InputObject) {
                    if ($null -ne $item -and $null -ne $item.'Element Name') {
                        $elementName = $item.'Element Name'
                        if (-not $seenElements.ContainsKey($elementName)) {
                            $seenElements[$elementName] = $true
                            $allItems += $item
                        }
                    }
                }
            } else {
                if ($null -ne $InputObject.'Element Name') {
                    $elementName = $InputObject.'Element Name'
                    if (-not $seenElements.ContainsKey($elementName)) {
                        $seenElements[$elementName] = $true
                        $allItems += $InputObject
                    }
                }
            }
        }
    }

    End {
        if ($allItems.Count -eq 0) {
            return
        }

        # Simply format as table.

        $allItems | Format-Table -Property 'Element Name', 'Default Value May Be Used?', 'Created by Script?', 'Notes' -AutoSize -Wrap
    }
}


Function Show-InfrastructureJsonConfigurationHelp {

    <#

        .SYNOPSIS
        Displays a reference table for configuring infrastructure.json file.

        .DESCRIPTION
        This helper function displays a comprehensive table showing all configuration elements
        for the infrastructure.json file, including whether default values can be used, whether
        the element is created by the script, and important notes for each field.

        .PARAMETER Format
        Specifies the output format. Valid values are:

        - Auto (default): Automatically selects the best format based on terminal width. Uses 'List' for narrow screens (< WidthThreshold characters, default 120) and 'Table' for wide screens (>= WidthThreshold characters).
        - List: Displays each field on its own line. Works best for narrow screens (40-50+ characters). No column wrapping issues.
        - Table: Displays data in a table format with columns. Best for wide screens (WidthThreshold+ characters, default 120+).
        - GridView: Opens an interactive grid view window with sorting and filtering capabilities. Works on any screen size but requires Windows PowerShell (not available in PowerShell Core on macOS/Linux).

        .PARAMETER Filter
        Filters the configuration elements by Element Name using wildcard matching. The filter is automatically wrapped with wildcards (*) on both sides.
        For example, '-Filter tkgsComponentSpec' will match all elements containing 'tkgsComponentSpec' in their name.

        .EXAMPLE
        Show-InfrastructureJsonConfigurationHelp

        Displays the complete infrastructure.json configuration reference table using auto-detected format.

        .EXAMPLE
        Show-InfrastructureJsonConfigurationHelp -Format Auto

        Automatically selects the best format based on terminal width.

        .EXAMPLE
        Show-InfrastructureJsonConfigurationHelp -Format List

        Displays the configuration in list format, ideal for narrow screens.

        .EXAMPLE
        Show-InfrastructureJsonConfigurationHelp -Format Table

        Displays the configuration in table format, ideal for wide screens.

        .EXAMPLE
        Show-InfrastructureJsonConfigurationHelp -Format GridView

        Opens an interactive grid view window with sorting and filtering capabilities (Windows PowerShell only).

        .EXAMPLE
        Show-InfrastructureJsonConfigurationHelp -Filter argoCD

        Displays only configuration elements containing 'argoCD' in their Element Name.

        .OUTPUTS
        None. This function displays formatted output to the console or opens a grid view window.
    #>

    [CmdletBinding()]
    Param(
        [Parameter()] [string]$Filter,
        [Parameter()] [ValidateSet('Table', 'List', 'GridView', 'Auto')] [string]$format = 'Auto',
        [Parameter()] [int]$WidthThreshold = 120
    )

    $infrastructureConfig = @(
        [PSCustomObject]@{
            'Element Name' = 'common.vCenterName'
            'Default Value May Be Used?' = 'No'
            'Created by Script?' = 'No'
            'Notes' = 'Must be vCenter 9.0 or higher. Script execution system must have HTTPS access to it.'
        },
        [PSCustomObject]@{
            'Element Name' = 'common.vCenterUser'
            'Default Value May Be Used?' = 'Yes'
            'Created by Script?' = 'No'
            'Notes' = 'While administrator@vsphere.local can be used, it''s recommended that one use a less privileged user that can create clusters, PV port groups, and supervisors. SSO users may be used as well.'
        },
        [PSCustomObject]@{
            'Element Name' = 'common.EsxHost'
            'Default Value May Be Used?' = 'No'
            'Created by Script?' = 'No'
            'Notes' = 'The script execution system must have HTTPS access to the ESX host'
        },
        [PSCustomObject]@{
            'Element Name' = 'common.EsxUser'
            'Default Value May Be Used?' = 'Yes'
            'Created by Script?' = 'No'
            'Notes' = 'ESX User must have permission to create a datastore'
        },
        [PSCustomObject]@{
            'Element Name' = 'common.datacenterName'
            'Default Value May Be Used?' = 'No'
            'Created by Script?' = 'No'
            'Notes' = 'The Edge Cluster will be created under this virtual datacenter. It assumed the vSphere datacenter already existed before running the script.'
        },
        [PSCustomObject]@{
            'Element Name' = 'common.clusterName'
            'Default Value May Be Used?' = 'Yes'
            'Created by Script?' = 'Yes'
            'Notes' = 'The script will create an Edge ESX cluster using the cluster name.'
        },
        [PSCustomObject]@{
            'Element Name' = 'common.supervisorName'
            'Default Value May Be Used?' = 'Yes'
            'Created by Script?' = 'Yes'
            'Notes' = 'The script will create a vSphere Supervisor using this name.'
        },
        [PSCustomObject]@{
            'Element Name' = 'common.argoCD.argoCdOperatorYamlPath'
            'Default Value May Be Used?' = 'No'
            'Created by Script?' = 'No'
            'Notes' = 'Path to the ArgoCD operator YAML file. This file is part of the ZIP file download from step #2 or can be downloaded from the broadcom support portal. Please modify the path accordingly. For Windows systems, backslashes must be escaped, such as in the provided example. For MacOS and Linux, there is no need to escape the forward slash.'
        },
        [PSCustomObject]@{
            'Element Name' = 'common.argoCD.argoCdDeploymentYamlPath'
            'Default Value May Be Used?' = 'No'
            'Created by Script?' = 'No'
            'Notes' = 'Path to the modified ArgoCD instance YAML config. Refer to Step #3. Please modify the path accordingly. For Windows systems, backslashes must be escaped, such as in the provided example. For MacOS and Linux, there is no need to escape the forward slash. Namespace in this file must match the namespace in common.argoCD.nameSpace in infrastructure.json lest the script produce an error.'
        },
        [PSCustomObject]@{
            'Element Name' = 'common.argoCD.contextName'
            'Default Value May Be Used?' = 'Yes'
            'Created by Script?' = 'Yes'
            'Notes' = 'This is the VCF context name. VCF CLI will configure a new set of VCF contexts to access and configure ArgoCD'
        },
        [PSCustomObject]@{
            'Element Name' = 'common.argoCD.nameSpace'
            'Default Value May Be Used?' = 'Yes'
            'Created by Script?' = 'Yes'
            'Notes' = 'This namespace definition must match the one in the yaml file referenced in common.argoCD.argoCdDeploymentYamlPath.'
        },
        [PSCustomObject]@{
            'Element Name' = 'common.argoCD.vmClass'
            'Default Value May Be Used?' = 'Yes'
            'Created by Script?' = 'No'
            'Notes' = 'This is a list of VM classes already available to the Supervisor that you wish to associate with the ArgoCD namespace.'
        },
        [PSCustomObject]@{
            'Element Name' = 'common.datastore.datastoreName'
            'Default Value May Be Used?' = 'Yes'
            'Created by Script?' = 'Yes'
            'Notes' = 'The script will prompt the user to select an unformatted disk to format as VMFS using this name.'
        },
        [PSCustomObject]@{
            'Element Name' = 'common.storagePolicy.storagePolicyTagCatalog'
            'Default Value May Be Used?' = 'Yes'
            'Created by Script?' = 'Yes'
            'Notes' = 'Any TagCatalog name, Script will search if TagCatalog already exist, if not, create a new one'
        },
        [PSCustomObject]@{
            'Element Name' = 'common.storagePolicy.storagePolicyName'
            'Default Value May Be Used?' = 'Yes'
            'Created by Script?' = 'Yes'
            'Notes' = 'Policy used to map VMFS datastore specified to the Supervisor instance'
        },
        [PSCustomObject]@{
            'Element Name' = 'common.storagePolicy.storagePolicyType'
            'Default Value May Be Used?' = 'Yes'
            'Created by Script?' = 'No'
            'Notes' = 'The only valid value is VMFS. Please do not change otherwise the script will error with a warning to revert the setting to VMFS.'
        },
        [PSCustomObject]@{
            'Element Name' = 'common.storagePolicy.storagePolicyRule'
            'Default Value May Be Used?' = 'Yes'
            'Created by Script?' = 'No'
            'Notes' = 'The only valid value is ''Fully initialized''. Please do not change otherwise the script will error with a warning to revert the setting to ''Fully initialized''.'
        },
        [PSCustomObject]@{
            'Element Name' = 'common.virtualDistributedSwitch.vdsName'
            'Default Value May Be Used?' = 'Yes'
            'Created by Script?' = 'Yes'
            'Notes' = 'The virtual distributed switch created by the script.'
        },
        [PSCustomObject]@{
            'Element Name' = 'common.virtualDistributedSwitch.vdsVersion'
            'Default Value May Be Used?' = 'Yes'
            'Created by Script?' = 'Yes'
            'Notes' = 'This must be a valid virtual distributed switch version. The script will create a new VDS if there isn''t one already. Leave the value as ''9.0.0''.'
        },
        [PSCustomObject]@{
            'Element Name' = 'common.virtualDistributedSwitch.numUplinks'
            'Default Value May Be Used?' = 'Yes'
            'Created by Script?' = 'Yes'
            'Notes' = 'The number of uplinks used by the virtual distributed switch created by the script.'
        },
        [PSCustomObject]@{
            'Element Name' = 'common.virtualDistributedSwitch.nicList'
            'Default Value May Be Used?' = 'Yes'
            'Created by Script?' = 'Yes'
            'Notes' = 'An array of physical NICs on the ESX host that you wish to attach to the virtual distributed switch created by the script. Script will not migrate vmkernel to the newly created VDS.'
        },
        [PSCustomObject]@{
            'Element Name' = 'common.portGroups'
            'Default Value May Be Used?' = 'Yes'
            'Created by Script?' = 'Yes'
            'Notes' = 'The names and VLANs of the port groups that you wish to create. Networks referenced for the flbManagementNetwork, flbVirtualServerNetwork, tkgsMgmtNetwork, and tkgsPrimaryWorkloadNetwork in the supervisor.json must exist in this file. The network names must be lower-cased and conform to RFC1123.'
        }
    )

    # Apply filter if specified.

    if ($Filter) {
        $filterPattern = "*$Filter*"
        $infrastructureConfig = $infrastructureConfig | Where-Object {
            $_.'Element Name' -like $filterPattern
        }

        if ($infrastructureConfig.Count -eq 0) {
            Write-Warning "No configuration elements found matching filter: $Filter"
            return
        }
    }

    # Detect terminal width
    $terminalWidth = if ($Host.UI.RawUI.BufferSize.Width -gt 0) {
        $Host.UI.RawUI.BufferSize.Width
    } else {
        $WidthThreshold  # Default fallback
    }

    # Adjust line width for header (max WidthThreshold, or terminal width if smaller)
    $lineWidth = [Math]::Min($terminalWidth, $WidthThreshold)

    Write-Host "`n" -NoNewline
    Write-Host ("=" * $lineWidth) -ForegroundColor Cyan
    Write-Host "Infrastructure.json Configuration Reference" -ForegroundColor Cyan
    Write-Host ("=" * $lineWidth) -ForegroundColor Cyan
    Write-Host "`n"

    # Determine format if Auto is selected.

    if ($format -eq 'Auto') {
        # Auto-select: List for narrow screens (< WidthThreshold chars), Table for wide screens
        if ($terminalWidth -lt $WidthThreshold) {
            $format = 'List'
        } else {
            $format = 'Table'
        }
    }

    # Display based on selected format.

    switch ($format) {
        'GridView' {
            # Check if Out-GridView cmdlet is available.

            $gridViewAvailable = $null -ne (Get-Command -Name 'Out-GridView' -ErrorAction SilentlyContinue)
            if ($gridViewAvailable) {
                $infrastructureConfig | Out-GridView -Title "Infrastructure.json Configuration Reference"
            } else {
                Write-Warning "Out-GridView is not available on this system (typically only available on Windows PowerShell). Using List format instead."
                $infrastructureConfig | Format-List -Property 'Element Name', 'Default Value May Be Used?', 'Created by Script?', 'Notes'
            }
        }
        'List' {
            $infrastructureConfig | Format-List -Property 'Element Name', 'Default Value May Be Used?', 'Created by Script?', 'Notes'
        }
        'Table' {
            try {
                $infrastructureConfig | Format-ConfigurationTable
            } catch {
                Write-Warning "Failed to format configuration table: $($_.Exception.Message)"
                Write-Host "Displaying configuration as list format:" -ForegroundColor Yellow
                $infrastructureConfig | Format-List -Property 'Element Name', 'Default Value May Be Used?', 'Created by Script?', 'Notes'
            }
        }
    }

    Write-Host "`n"
}

Function Show-SupervisorJsonConfigurationHelp {

    <#
        .SYNOPSIS
        Displays a reference table for configuring supervisor.json file.

        .DESCRIPTION
        This helper function displays a comprehensive table showing all configuration elements
        for the supervisor.json file, including whether default values can be used, whether
        the element is created by the script, and important notes for each field.

        .PARAMETER Format
        Specifies the output format. Valid values are:

        - Auto (default): Automatically selects the best format based on terminal width. Uses 'List' for narrow screens (< WidthThreshold characters, default 120) and 'Table' for wide screens (>= WidthThreshold characters).
        - List: Displays each field on its own line. Works best for narrow screens (40-50+ characters). No column wrapping issues.
        - Table: Displays data in a table format with columns. Best for wide screens (WidthThreshold+ characters, default 120+).
        - GridView: Opens an interactive grid view window with sorting and filtering capabilities. Works on any screen size but requires Windows PowerShell (not available in PowerShell Core on macOS/Linux).

        .PARAMETER Filter
        Filters the configuration elements by Element Name using wildcard matching. The filter is automatically wrapped with wildcards (*) on both sides.
        For example, '-Filter tkgsComponentSpec' will match all elements containing 'tkgsComponentSpec' in their name.

        .EXAMPLE
        Show-SupervisorJsonConfigurationHelp

        Displays the complete supervisor.json configuration reference table using auto-detected format.

        .EXAMPLE
        Show-SupervisorJsonConfigurationHelp -Format Auto

        Automatically selects the best format based on terminal width.

        .EXAMPLE
        Show-SupervisorJsonConfigurationHelp -Format List

        Displays the configuration in list format, ideal for narrow screens.

        .EXAMPLE
        Show-SupervisorJsonConfigurationHelp -Format Table

        Displays the configuration in table format, ideal for wide screens.

        .EXAMPLE
        Show-SupervisorJsonConfigurationHelp -Format GridView

        Opens an interactive grid view window with sorting and filtering capabilities (Windows PowerShell only).

        .EXAMPLE
        Show-SupervisorJsonConfigurationHelp -Filter tkgsComponentSpec

        Displays only configuration elements containing 'tkgsComponentSpec' in their Element Name.

        .OUTPUTS
        None. This function displays formatted output to the console or opens a grid view window.


    #>

    [CmdletBinding()]
    Param(
        [Parameter()] [string]$Filter,
        [Parameter()] [ValidateSet('Table', 'List', 'GridView', 'Auto')] [string]$format = 'Auto',
        [Parameter()] [int]$WidthThreshold = 120
    )

    $supervisorConfig = @(
        [PSCustomObject]@{
            'Element Name' = 'supervisorSpec.controlPlaneVMCount'
            'Default Value May Be Used?' = 'Yes'
            'Created by Script?' = 'No'
            'Notes' = 'The value may be either ''1'' or ''3''.'
        },
        [PSCustomObject]@{
            'Element Name' = 'supervisorSpec.controlPlaneSize'
            'Default Value May Be Used?' = 'Yes'
            'Created by Script?' = 'No'
            'Notes' = 'The value may be ''Tiny'', ''Small'', ''Medium'', or ''Large'''
        },
        [PSCustomObject]@{
            'Element Name' = 'tkgsComponentSpec.foundationLoadBalancerComponents.flbName'
            'Default Value May Be Used?' = 'Yes'
            'Created by Script?' = 'Yes'
            'Notes' = 'Foundation Load Balancer Name'
        },
        [PSCustomObject]@{
            'Element Name' = 'tkgsComponentSpec.foundationLoadBalancerComponents.flbSize'
            'Default Value May Be Used?' = 'Yes'
            'Created by Script?' = 'No'
            'Notes' = 'The value may ''Small'', ''Medium'', or ''Large'', or ''X-LARGE'''
        },
        [PSCustomObject]@{
            'Element Name' = 'tkgsComponentSpec.foundationLoadBalancerComponents.flbAvailability'
            'Default Value May Be Used?' = 'Yes'
            'Created by Script?' = 'No'
            'Notes' = 'The value may be ''SINGLE_NODE'' or ''ACTIVE_PASSIVE'' (for two-node deployments).'
        },
        [PSCustomObject]@{
            'Element Name' = 'tkgsComponentSpec.foundationLoadBalancerComponents.flbVipStartIP'
            'Default Value May Be Used?' = 'No'
            'Created by Script?' = 'Yes'
            'Notes' = 'The starting IP for your Foundation Load Balancer virtual IP range.'
        },
        [PSCustomObject]@{
            'Element Name' = 'tkgsComponentSpec.foundationLoadBalancerComponents.flbVipIPCount'
            'Default Value May Be Used?' = 'No'
            'Created by Script?' = 'Yes'
            'Notes' = 'The number of IPs used by the Foundation Load Balancer starting from the flbVipStartIP'
        },
        [PSCustomObject]@{
            'Element Name' = 'tkgsComponentSpec.foundationLoadBalancerComponents.flbProvider'
            'Default Value May Be Used?' = 'Yes'
            'Created by Script?' = 'Yes'
            'Notes' = 'The only valid value is ''VSPHERE_FOUNDATION''. Please do not change otherwise the script will error with a warning to revert the setting to ''VSPHERE_FOUNDATION''.'
        },
        [PSCustomObject]@{
            'Element Name' = 'tkgsComponentSpec.foundationLoadBalancerComponents.flbDnsServers'
            'Default Value May Be Used?' = 'No'
            'Created by Script?' = 'No'
            'Notes' = 'The DNS server(s) for the Foundation Load Balancer network.'
        },
        [PSCustomObject]@{
            'Element Name' = 'tkgsComponentSpec.foundationLoadBalancerComponents.flbNtpServers'
            'Default Value May Be Used?' = 'No'
            'Created by Script?' = 'No'
            'Notes' = 'The NTP server(s) for the Foundation Load Balancer network.'
        },
        [PSCustomObject]@{
            'Element Name' = 'tkgsComponentSpec.foundationLoadBalancerComponents.flbSearchDomains'
            'Default Value May Be Used?' = 'No'
            'Created by Script?' = 'No'
            'Notes' = 'The domain search domain for the Foundation Load Balancer network.'
        },
        [PSCustomObject]@{
            'Element Name' = 'tkgsComponentSpec.foundationLoadBalancerComponents.flbManagementNetwork.flbNetworkIpAssignmentMode'
            'Default Value May Be Used?' = 'Yes'
            'Created by Script?' = 'No'
            'Notes' = 'The only valid value is ''STATIC''. Please do not change otherwise the script will error with a warning to revert the setting to ''STATIC''.'
        },
        [PSCustomObject]@{
            'Element Name' = 'tkgsComponentSpec.foundationLoadBalancerComponents.flbManagementNetwork.flbNetworkName'
            'Default Value May Be Used?' = 'Yes'
            'Created by Script?' = 'Yes'
            'Notes' = 'This network name may be changed, but it must also be changed in infrastructure.json common.portGroup.name. The network name must be lower-cased and conform to RFC1123.'
        },
        [PSCustomObject]@{
            'Element Name' = 'tkgsComponentSpec.foundationLoadBalancerComponents.flbManagementNetwork.flbNetworkType'
            'Default Value May Be Used?' = 'Yes'
            'Created by Script?' = 'No'
            'Notes' = 'The only valid value is ''DVPG''. Please do not change otherwise the script will error with a warning to revert the setting to ''DVPG''.'
        },
        [PSCustomObject]@{
            'Element Name' = 'tkgsComponentSpec.foundationLoadBalancerComponents.flbManagementNetwork.flbNetworkIpAddressStartingIp'
            'Default Value May Be Used?' = 'No'
            'Created by Script?' = 'Yes'
            'Notes' = 'The starting IP for your Foundation Load Balancer management IP range.'
        },
        [PSCustomObject]@{
            'Element Name' = 'tkgsComponentSpec.foundationLoadBalancerComponents.flbManagementNetwork.flbNetworkIpAddressCount'
            'Default Value May Be Used?' = 'No'
            'Created by Script?' = 'Yes'
            'Notes' = 'The number of IPs used by the Foundation Load Balancer management network, starting from the flbNetworkIpAddressStartingIp'
        },
        [PSCustomObject]@{
            'Element Name' = 'tkgsComponentSpec.foundationLoadBalancerComponents.flbManagementNetwork.flbNetworkGateway'
            'Default Value May Be Used?' = 'No'
            'Created by Script?' = 'Yes'
            'Notes' = 'Default gateway for Foundation Load Balancer management network'
        },
        [PSCustomObject]@{
            'Element Name' = 'tkgsComponentSpec.foundationLoadBalancerComponents.flbVirtualServerNetwork.flbNetworkIpAssignmentMode'
            'Default Value May Be Used?' = 'Yes'
            'Created by Script?' = 'No'
            'Notes' = 'The only valid value is ''STATIC''. Please do not change otherwise the script will error with a warning to revert the setting to ''STATIC''.'
        },
        [PSCustomObject]@{
            'Element Name' = 'tkgsComponentSpec.foundationLoadBalancerComponents.flbVirtualServerNetwork.flbNetworkName'
            'Default Value May Be Used?' = 'Yes'
            'Created by Script?' = 'Yes'
            'Notes' = 'This network name may be changed, but it must also be changed in infrastructure.json common.portGroup.name.'
        },
        [PSCustomObject]@{
            'Element Name' = 'tkgsComponentSpec.foundationLoadBalancerComponents.flbVirtualServerNetwork.flbNetworkType'
            'Default Value May Be Used?' = 'Yes'
            'Created by Script?' = 'Yes'
            'Notes' = 'The only valid value is ''DVPG''. Please do not change otherwise the script will error with a warning to revert the setting to ''DVPG''.'
        },
        [PSCustomObject]@{
            'Element Name' = 'tkgsComponentSpec.foundationLoadBalancerComponents.flbVirtualServerNetwork.flbNetworkIpAddressStartingIp'
            'Default Value May Be Used?' = 'No'
            'Created by Script?' = 'Yes'
            'Notes' = 'The starting IP for your Foundation Load Balancer server network IP range.'
        },
        [PSCustomObject]@{
            'Element Name' = 'tkgsComponentSpec.foundationLoadBalancerComponents.flbVirtualServerNetwork.flbNetworkIpAddressCount'
            'Default Value May Be Used?' = 'Yes'
            'Created by Script?' = 'Yes'
            'Notes' = 'The number of IPs used by the Foundation Load Balancer virtual server network in the virtual IP range, starting from the flbNetworkIpAddressStartingIp.'
        },
        [PSCustomObject]@{
            'Element Name' = 'tkgsComponentSpec.foundationLoadBalancerComponents.flbVirtualServerNetwork.flbNetworkGateway'
            'Default Value May Be Used?' = 'No'
            'Created by Script?' = 'Yes'
            'Notes' = 'Default gateway for Foundation Load Balancer server network.'
        },
        [PSCustomObject]@{
            'Element Name' = 'tkgsComponentSpec.tkgsMgmtNetworkSpec.tkgsMgmtIpAssignmentMode'
            'Default Value May Be Used?' = 'Yes'
            'Created by Script?' = 'No'
            'Notes' = 'The only valid value is ''STATIC''. Please do not change otherwise the script will error with a warning to revert the setting to ''STATIC''.'
        },
        [PSCustomObject]@{
            'Element Name' = 'tkgsComponentSpec.tkgsMgmtNetworkSpec.tkgsMgmtNetworkName'
            'Default Value May Be Used?' = 'Yes'
            'Created by Script?' = 'Yes'
            'Notes' = 'This network name may be changed, but it must also be changed in infrastructure.json common.portGroup.name. The network name must be lower-cased and conform to RFC1123.'
        },
        [PSCustomObject]@{
            'Element Name' = 'tkgsComponentSpec.tkgsMgmtNetworkSpec.tkgsMgmtNetworkGatewayCidr'
            'Default Value May Be Used?' = 'No'
            'Created by Script?' = 'Yes'
            'Notes' = 'Default gateway for VKS server network.'
        },
        [PSCustomObject]@{
            'Element Name' = 'tkgsComponentSpec.tkgsMgmtNetworkSpec.tkgsMgmtNetworkStartingIp'
            'Default Value May Be Used?' = 'No'
            'Created by Script?' = 'Yes'
            'Notes' = 'The starting IP for your VKS management network IP range.'
        },
        [PSCustomObject]@{
            'Element Name' = 'tkgsComponentSpec.tkgsMgmtNetworkSpec.tkgsMgmtNetworkIPCount'
            'Default Value May Be Used?' = 'No'
            'Created by Script?' = 'Yes'
            'Notes' = 'The number of IPs used by the Foundation Load Balancer virtual server network in the virtual IP range, starting from the .tkgsMgmtNetworkIPCount.'
        },
        [PSCustomObject]@{
            'Element Name' = 'tkgsComponentSpec.tkgsMgmtNetworkSpec.tkgsMgmtNetworkDnsServers'
            'Default Value May Be Used?' = 'No'
            'Created by Script?' = 'No'
            'Notes' = 'The DNS server(s) for the VKS management network.'
        },
        [PSCustomObject]@{
            'Element Name' = 'tkgsComponentSpec.tkgsMgmtNetworkSpec.tkgsMgmtNetworkSearchDomains'
            'Default Value May Be Used?' = 'No'
            'Created by Script?' = 'No'
            'Notes' = 'The domain search domain for the VKS management network.'
        },
        [PSCustomObject]@{
            'Element Name' = 'tkgsComponentSpec.tkgsMgmtNetworkSpec.tkgsMgmtNetworkNtpServers'
            'Default Value May Be Used?' = 'No'
            'Created by Script?' = 'No'
            'Notes' = 'The NTP server(s) for the VKS management network.'
        },
        [PSCustomObject]@{
            'Element Name' = 'tkgsComponentSpec.tkgsPrimaryWorkloadNetwork.tkgsPrimaryWorkloadIpAssignmentMode'
            'Default Value May Be Used?' = 'Yes'
            'Created by Script?' = 'Yes'
            'Notes' = 'The only valid value is ''STATIC''. Please do not change otherwise the script will error with a warning to revert the setting to ''STATIC''.'
        },
        [PSCustomObject]@{
            'Element Name' = 'tkgsComponentSpec.tkgsPrimaryWorkloadNetwork.tkgsPrimaryWorkloadNetworkName'
            'Default Value May Be Used?' = 'Yes'
            'Created by Script?' = 'Yes'
            'Notes' = 'This network name may be changed, but it must also be changed in infrastructure.json common.portGroup.name. The network name must be lower-cased and conform to RFC1123.'
        },
        [PSCustomObject]@{
            'Element Name' = 'tkgsComponentSpec.tkgsPrimaryWorkloadNetwork.tkgsPrimaryWorkloadNetworkGatewayCidr'
            'Default Value May Be Used?' = 'No'
            'Created by Script?' = 'Yes'
            'Notes' = 'Default gateway for VKS workload network.'
        },
        [PSCustomObject]@{
            'Element Name' = 'tkgsComponentSpec.tkgsPrimaryWorkloadNetwork.tkgsPrimaryWorkloadNetworkStartingIp'
            'Default Value May Be Used?' = 'No'
            'Created by Script?' = 'Yes'
            'Notes' = 'The starting IP address for the VKS workload network virtual IP range.'
        },
        [PSCustomObject]@{
            'Element Name' = 'tkgsComponentSpec.tkgsPrimaryWorkloadNetwork.tkgsPrimaryWorkloadNetworkIPCount'
            'Default Value May Be Used?' = 'No'
            'Created by Script?' = 'Yes'
            'Notes' = 'The number of IPs for the VKS workload network virtual IP range.'
        },
        [PSCustomObject]@{
            'Element Name' = 'tkgsComponentSpec.tkgsPrimaryWorkloadNetwork.tkgsPrimaryWorkloadNetworkSearchDomains'
            'Default Value May Be Used?' = 'No'
            'Created by Script?' = 'No'
            'Notes' = 'The DNS search domain for the VKS workload network.'
        },
        [PSCustomObject]@{
            'Element Name' = 'tkgsComponentSpec.tkgsPrimaryWorkloadNetwork.tkgsWorkloadDnsServers'
            'Default Value May Be Used?' = 'No'
            'Created by Script?' = 'No'
            'Notes' = 'The DNS server(s) for the VKS workload network.'
        },
        [PSCustomObject]@{
            'Element Name' = 'tkgsComponentSpec.tkgsPrimaryWorkloadNetwork.tkgsWorkloadNtpServers'
            'Default Value May Be Used?' = 'No'
            'Created by Script?' = 'No'
            'Notes' = 'The NTP server(s) for the VKS workload network.'
        },
        [PSCustomObject]@{
            'Element Name' = 'tkgsComponentSpec.tkgsPrimaryWorkloadNetwork.tkgsWorkloadServiceStartIp'
            'Default Value May Be Used?' = 'No'
            'Created by Script?' = 'Yes'
            'Notes' = 'The starting IP address for the VKS workload network virtual IP range.'
        },
        [PSCustomObject]@{
            'Element Name' = 'tkgsComponentSpec.tkgsPrimaryWorkloadNetwork.tkgsWorkloadServiceCount'
            'Default Value May Be Used?' = 'Yes'
            'Created by Script?' = 'Yes'
            'Notes' = 'The maximum IP count, provisioned starting tkgsWorkloadServiceStartIp IP address, for the VKS workload network virtual IP range. This IP account must fully occupy a CIDR address range, for example, 256 or 512, but not 200 or 500.'
        }
    )

    # Apply filter if specified.

    if ($Filter) {
        $filterPattern = "*$Filter*"
        $supervisorConfig = $supervisorConfig | Where-Object {
            $_.'Element Name' -like $filterPattern
        }

        if ($supervisorConfig.Count -eq 0) {
            Write-Warning "No configuration elements found matching filter: $Filter"
            return
        }
    }

    # Detect terminal width
    $terminalWidth = if ($Host.UI.RawUI.BufferSize.Width -gt 0) {
        $Host.UI.RawUI.BufferSize.Width
    } else {
        $WidthThreshold  # Default fallback
    }

    # Adjust line width for header (max WidthThreshold, or terminal width if smaller)
    $lineWidth = [Math]::Min($terminalWidth, $WidthThreshold)

    Write-Host "`n" -NoNewline
    Write-Host ("=" * $lineWidth) -ForegroundColor Cyan
    Write-Host "Supervisor.json Configuration Reference" -ForegroundColor Cyan
    Write-Host ("=" * $lineWidth) -ForegroundColor Cyan
    Write-Host "`n"

    # Determine format if Auto is selected.

    if ($format -eq 'Auto') {
        # Auto-select: List for narrow screens (< WidthThreshold chars), Table for wide screens
        if ($terminalWidth -lt $WidthThreshold) {
            $format = 'List'
        } else {
            $format = 'Table'
        }
    }

    # Display based on selected format.

    switch ($format) {
        'GridView' {
            # Check if Out-GridView cmdlet is available.

            $gridViewAvailable = $null -ne (Get-Command -Name 'Out-GridView' -ErrorAction SilentlyContinue)
            if ($gridViewAvailable) {
                $supervisorConfig | Out-GridView -Title "Supervisor.json Configuration Reference"
            } else {
                Write-Warning "Out-GridView is not available on this system (typically only available on Windows PowerShell). Using List format instead."
                $supervisorConfig | Format-List -Property 'Element Name', 'Default Value May Be Used?', 'Created by Script?', 'Notes'
            }
        }
        'List' {
            $supervisorConfig | Format-List -Property 'Element Name', 'Default Value May Be Used?', 'Created by Script?', 'Notes'
        }
        'Table' {
            try {
                $supervisorConfig | Format-ConfigurationTable
            } catch {
                Write-Warning "Failed to format configuration table: $($_.Exception.Message)"
                Write-Host "Displaying configuration as list format:" -ForegroundColor Yellow
                $supervisorConfig | Format-List -Property 'Element Name', 'Default Value May Be Used?', 'Created by Script?', 'Notes'
            }
        }
    }

    Write-Host "`n"
}

# Export the public functions.
Export-ModuleMember -Function 'Start-SimpleSupervisorDeploymentAtScale', 'Copy-SimpleSupervisorTemplates', 'Show-InfrastructureJsonConfigurationHelp', 'Show-SupervisorJsonConfigurationHelp'