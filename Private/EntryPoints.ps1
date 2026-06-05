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
#region Exported — entry points, templates, configuration help
function Confirm-FileOverwritePrompt {

    <#
        .SYNOPSIS
        Prompts the user to confirm overwriting an existing file.

        .DESCRIPTION
        When the file at FilePath already exists, reads a y/N response from the user and returns
        $true for yes or $false for no (keep existing). When the file does not exist, returns $true
        without prompting. Throws when Read-Host is unavailable so callers receive a clear error.

        .PARAMETER FilePath
        Full path to the file that would be overwritten.

        .OUTPUTS
        [Boolean] $true to write the file; $false to keep the existing copy or when the session
        is non-interactive (error is logged before returning $false in that case).
    
        .EXAMPLE
        Confirm-FileOverwritePrompt -FilePath "infrastructure.json"
    #>

    [CmdletBinding()]
    [OutputType([Boolean])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$FilePath
    )

    if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
        return $true
    }
    try {
        $answer = Read-Host "File `"$FilePath`" already exists. Overwrite? (y/N)"
    } catch {
        Write-LogMessage -Type ERROR -Message "Initialize requires an interactive session for overwrite prompts. $($_.Exception.Message)"
        return $false
    }
    return $answer -match '^[yY]$'
}
function Test-VcfEdgeAtScaleDeploymentRootInitialized {

    <#
        .SYNOPSIS
        Returns whether a directory matches a completed Initialize layout (folders, JSON, shipped YAML).

        .NOTES
        Private helper; not exported. Used by Invoke-VcfEdgeAtScaleModuleInitialize only.

        .DESCRIPTION
        True when all DEPLOY_LAYOUT_SUBDIRECTORIES (Docs, Logs, ServicesYaml, Tools) exist, root infrastructure.json
        and supervisor.json exist, and all VcfEdgeAtScaleServiceYamlTemplateFileNames files exist under ServicesYaml.

        .PARAMETER DeploymentRoot
        Resolved full path to the deployment base directory.

        .OUTPUTS
        [Boolean]
    
        .EXAMPLE
        Test-VcfEdgeAtScaleDeploymentRootInitialized -DeploymentRoot "value"
    #>

    [CmdletBinding()]
    [OutputType([Boolean])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$DeploymentRoot
    )

    foreach ($dirName in $Script:DEPLOY_LAYOUT_SUBDIRECTORIES) {
        $childPath = Join-Path -Path $DeploymentRoot -ChildPath $dirName
        if (-not (Test-Path -LiteralPath $childPath -PathType Container)) {
            return $false
        }
    }
    $infrastructurePath = Join-Path -Path $DeploymentRoot -ChildPath $Script:INFRA_JSON_FILENAME
    $supervisorPath = Join-Path -Path $DeploymentRoot -ChildPath $Script:SUPERVISOR_JSON_FILENAME
    if (-not (Test-Path -LiteralPath $infrastructurePath -PathType Leaf)) {
        return $false
    }
    if (-not (Test-Path -LiteralPath $supervisorPath -PathType Leaf)) {
        return $false
    }
    $servicesYamlDir = Join-Path -Path $DeploymentRoot -ChildPath $Script:SERVICES_YAML_DIR_NAME
    foreach ($yamlBaseName in $Script:VcfEdgeAtScaleServiceYamlTemplateFileNames) {
        $yamlPath = Join-Path -Path $servicesYamlDir -ChildPath $yamlBaseName
        if (-not (Test-Path -LiteralPath $yamlPath -PathType Leaf)) {
            return $false
        }
    }
    return $true
}
function Resolve-DeploymentRootDirectory {

    <#
        .SYNOPSIS
        Resolves the deployment base directory by checking the environment variable then prompting the user.

        .DESCRIPTION
        When $env:VcfEdgeAtScaleRootDirectory is set:
          - If the path does not exist: clears the stale value and falls through to the prompt.
          - If the path exists but is not a folder: logs a note and falls through to the prompt.
          - If the path is a fully initialized layout: asks the operator whether to reuse it or
            initialize a different directory.
          - If the path exists but is not fully initialized: notes the incomplete state and prompts.
        When the operator provides no input at the base directory prompt, DefaultBaseDirectory is used.
        Returns $null and logs an error when the directory cannot be determined (empty input after
        prompting, or Read-Host unavailable in a non-interactive session).

        .PARAMETER DefaultBaseDirectory
        The default base directory path to offer as the default prompt value (typically
        Join-Path $HOME $Script:DEFAULT_DEPLOY_DIR_NAME). Must be a non-empty string.

        .OUTPUTS
        [String] The operator-chosen (or defaulted) base directory path. Never null or empty.

        .EXAMPLE
        $baseDirectory = Resolve-DeploymentRootDirectory -DefaultBaseDirectory (Join-Path $HOME "VcfEdgeAtScale")

        .NOTES
        Write-Host is the primary output mechanism in this function; all Write-Host calls are
        intentional interactive console output. Use Write-LogMessage for diagnostic logging.
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$DefaultBaseDirectory
    )

    $baseDirectory = $null
    $envRootRaw = $env:VcfEdgeAtScaleRootDirectory

    if (-not [String]::IsNullOrWhiteSpace($envRootRaw)) {
        $trimmedEnvRoot = $envRootRaw.Trim()
        if (-not (Test-Path -LiteralPath $trimmedEnvRoot)) {
            Write-Host ""
            Write-Host "  Note: `$env:VcfEdgeAtScaleRootDirectory pointed at a path that does not exist:" -ForegroundColor Yellow
            Write-Host "    $trimmedEnvRoot" -ForegroundColor White
            $env:VcfEdgeAtScaleRootDirectory = $null
            if ($IsWindows) {
                try {
                    [System.Environment]::SetEnvironmentVariable($Script:ENV_VAR_NAME, $null, [System.EnvironmentVariableTarget]::User)
                    Write-Host "  Stale value cleared from session and user environment. Choose a folder below." -ForegroundColor Green
                } catch {
                    Write-Host "  Stale value cleared from session. User-level clear failed: $($_.Exception.Message)" -ForegroundColor Yellow
                }
            } else {
                Write-Host "  Stale value cleared from session. Choose a folder below." -ForegroundColor Green
            }
        } elseif (-not (Test-Path -LiteralPath $trimmedEnvRoot -PathType Container)) {
            Write-Host ""
            Write-Host "  Note: `$env:VcfEdgeAtScaleRootDirectory points at a path that exists but is not a folder:" -ForegroundColor Yellow
            Write-Host "    $trimmedEnvRoot" -ForegroundColor White
            Write-Host "  Choose a deployment root folder below (default: $DefaultBaseDirectory)." -ForegroundColor Gray
        } else {
            $envRootResolved = $null
            try {
                $envRootResolved = (Resolve-Path -LiteralPath $trimmedEnvRoot -ErrorAction Stop).Path
            } catch {
                $envRootResolved = $null
            }
            if ($envRootResolved -and (Test-VcfEdgeAtScaleDeploymentRootInitialized -DeploymentRoot $envRootResolved)) {
                Write-Host ""
                Write-Host "  Detected: `$env:VcfEdgeAtScaleRootDirectory` is set in this session." -ForegroundColor Green
                Write-Host "    Value: $envRootRaw" -ForegroundColor White
                Write-Host "  That path resolves to a full Initialize layout (Docs, Logs, ServicesYaml, root JSON, shipped YAML under ServicesYaml):" -ForegroundColor Green
                Write-Host "    $envRootResolved" -ForegroundColor White
                try {
                    $useDifferentDirectoryResponse = Read-Host "Initialize a different directory instead? (y/N)"
                } catch {
                    Write-LogMessage -Type ERROR -Message "Initialize requires an interactive session for directory prompts. $($_.Exception.Message)"
                    return $null
                }
                switch -Regex ($useDifferentDirectoryResponse.Trim()) {
                    "^(?i)(y|yes)$" {
                        Write-Host "  Choose a new base path below (default remains Join-Path `$HOME '$($Script:DEFAULT_DEPLOY_DIR_NAME)')." -ForegroundColor Gray
                    }
                    default {
                        $baseDirectory = $envRootResolved
                    }
                }
            } elseif ($envRootResolved) {
                Write-Host ""
                Write-Host "  Note: VcfEdgeAtScaleRootDirectory is set, but this folder is not a complete initialized layout:" -ForegroundColor Yellow
                Write-Host "  $envRootResolved" -ForegroundColor Yellow
                Write-Host "  You will be prompted for the base directory below (default: $DefaultBaseDirectory)." -ForegroundColor Gray
            }
        }
    }

    if ($null -eq $baseDirectory) {
        $baseDirectory = Read-DeploymentBaseDirectoryFromUser -DefaultBaseDirectory $DefaultBaseDirectory
        if ($null -eq $baseDirectory) {
            return $null
        }
    }

    if ([String]::IsNullOrWhiteSpace($baseDirectory)) {
        Write-LogMessage -Type ERROR -Message "Base directory cannot be empty after input."
        return $null
    }

    return $baseDirectory
}
function Read-DeploymentBaseDirectoryFromUser {

    <#
        .SYNOPSIS
        Interactively prompts the operator for the deployment base directory path.

        .DESCRIPTION
        Displays the default path and prompts with Read-Host. Returns the default when the operator
        presses Enter, or the trimmed user input otherwise. Returns $null when the session is
        non-interactive and Read-Host is unavailable (error is logged before returning).

        .PARAMETER DefaultBaseDirectory
        The default base directory path shown to the operator.

        .OUTPUTS
        [String] The operator-chosen directory path, or $null when Read-Host is unavailable
        (error already logged).

        .EXAMPLE
        $baseDirectory = Read-DeploymentBaseDirectoryFromUser -DefaultBaseDirectory (Join-Path $HOME "VcfEdgeAtScale")

        .NOTES
        Write-Host is the primary output mechanism in this function; all Write-Host calls are
        intentional interactive console output. Use Write-LogMessage for diagnostic logging.
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$DefaultBaseDirectory
    )

    Write-Host ""
    Write-Host -NoNewline "  Default base directory:" -ForegroundColor White
    Write-Host "  $DefaultBaseDirectory`n" -ForegroundColor Cyan
    try {
        $userBaseResponse = Read-Host "Press Enter to use the default, or type a full directory path"
    } catch {
        Write-LogMessage -Type ERROR -Message "Initialize requires an interactive session for directory prompts. $($_.Exception.Message)"
        return $null
    }
    if ([String]::IsNullOrWhiteSpace($userBaseResponse)) {
        return $DefaultBaseDirectory
    }
    return $userBaseResponse.Trim()
}
function New-DeploySubdirectories {

    <#
        .SYNOPSIS
        Creates the standard subdirectory layout under the deployment base directory.

        .DESCRIPTION
        Iterates Script:DEPLOY_LAYOUT_SUBDIRECTORIES and creates each subdirectory under
        ResolvedBaseDirectory when it does not already exist. Returns a list of the subdirectory
        names that were created, or $null if any creation fails (error is logged before returning).

        .PARAMETER ResolvedBaseDirectory
        The fully resolved base deployment directory path.

        .EXAMPLE
        $created = New-DeploySubdirectories -ResolvedBaseDirectory $resolvedBaseDirectory
        if ($null -eq $created) { return $null }

        .NOTES
        Called by Invoke-VcfEdgeAtScaleModuleInitialize. Returns an empty list when all
        subdirectories already exist.
    #>

    [CmdletBinding()]
    [OutputType([System.Collections.Generic.List[String]])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ResolvedBaseDirectory
    )

    $subdirectoriesCreated = [System.Collections.Generic.List[String]]::new()
    foreach ($subdirectoryName in $Script:DEPLOY_LAYOUT_SUBDIRECTORIES) {
        $childPath = Join-Path -Path $ResolvedBaseDirectory -ChildPath $subdirectoryName
        if (-not (Test-Path -LiteralPath $childPath -PathType Container)) {
            try {
                $null = New-Item -ItemType Directory -Path $childPath -Force -ErrorAction Stop
                $null = $subdirectoriesCreated.Add($subdirectoryName)
            } catch {
                Write-LogMessage -Type ERROR -Message "Failed to create directory `"$childPath`": $($_.Exception.Message)"
                return $null
            }
        }
    }
    return $subdirectoriesCreated
}
function Copy-TemplateDocumentationFiles {

    <#
    .SYNOPSIS
        Copies EXAMPLE.rtf and README.rtf from the module templates to the Docs directory.
    .DESCRIPTION
        For each RTF documentation file, checks whether the source exists in the templates folder,
        prompts the user before overwriting (via Confirm-FileOverwritePrompt), then copies it.
        Skips gracefully with a warning when the source is absent.
    .PARAMETER DocsDirectory
        Full path to the Docs subdirectory where documentation files will be placed.
    .PARAMETER TemplateRestoreHint
        User-facing hint appended to warning messages when a template file is missing.
    .PARAMETER TemplatesPath
        Full path to the module Templates folder.
    .EXAMPLE
        Copy-TemplateDocumentationFiles -DocsDirectory $docsDir -TemplateRestoreHint $hint -TemplatesPath $tmplPath
    .NOTES
        Write-Host is the primary output mechanism in this function; all Write-Host calls are
        intentional interactive console output. Use Write-LogMessage for diagnostic logging.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$DocsDirectory,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$TemplateRestoreHint,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$TemplatesPath
    )

    $rtfDocumentationPairs = @(
        @{ DestinationFileName = "EXAMPLE.rtf"; SourcePath = (Join-Path -Path $TemplatesPath -ChildPath "EXAMPLE.rtf") },
        @{ DestinationFileName = "README.rtf";  SourcePath = (Join-Path -Path $TemplatesPath -ChildPath "README.rtf") }
    )

    Write-Host ""
    Write-Host "  Documentation (Docs)" -ForegroundColor Magenta

    foreach ($documentationPair in $rtfDocumentationPairs) {
        if (-not (Test-Path -LiteralPath $documentationPair.SourcePath -PathType Leaf)) {
            Write-LogMessage -Type WARNING -Message "Optional documentation file '$($documentationPair.DestinationFileName)' is not in the module Templates folder (source not found at $($documentationPair.SourcePath)). Skipping this copy; Initialize continues. $TemplateRestoreHint"
            continue
        }
        $destinationDocumentationPath = Join-Path -Path $DocsDirectory -ChildPath $documentationPair.DestinationFileName
        if (-not (Confirm-FileOverwritePrompt -FilePath $destinationDocumentationPath)) {
            Write-Host "    Skipped (keep existing): $($documentationPair.DestinationFileName)" -ForegroundColor Yellow
            continue
        }
        try {
            Copy-Item -LiteralPath $documentationPair.SourcePath -Destination $destinationDocumentationPath -Force -ErrorAction Stop
        } catch {
            Write-LogMessage -Type WARNING -Message "Skipping documentation copy '$($documentationPair.DestinationFileName)' after error: $($_.Exception.Message) $TemplateRestoreHint"
            continue
        }
        Write-Host "    Copied: $($documentationPair.DestinationFileName)" -ForegroundColor Green
    }
}
function Copy-InitializeTemplateFiles {

    <#
        .SYNOPSIS
        Copies Supervisor service YAML templates, documentation files, and tool files to the initialized layout directories.

        .DESCRIPTION
        Called from Invoke-VcfEdgeAtScaleModuleInitialize after the directory structure has been created. Handles
        five file categories: Supervisor service YAML templates (required — throws if missing), RTF documentation
        files (optional — skips with warning if missing), help JSON files (auto-refreshed silently when stale),
        the Python config UI tool (optional — skips with warning), and the HTML UI template (optional — silent
        overwrite). Overwrite prompts are handled by Confirm-FileOverwritePrompt.

        .PARAMETER DocsDirectory
        Absolute path to the Docs subdirectory under the deployment root.

        .PARAMETER ServicesYamlDirectory
        Absolute path to the ServicesYaml subdirectory under the deployment root.

        .PARAMETER TemplateRestoreHint
        Guidance string appended to error messages when a required template is missing.

        .PARAMETER TemplatesPath
        Absolute path to the module Templates directory.

        .PARAMETER ToolsDirectory
        Absolute path to the Tools subdirectory under the deployment root.

        .EXAMPLE
        Copy-InitializeTemplateFiles -DocsDirectory $docsDir -ServicesYamlDirectory $yamlDir `
            -TemplateRestoreHint $hint -TemplatesPath $tplPath -ToolsDirectory $toolsDir

        .NOTES
        Called exclusively from Invoke-VcfEdgeAtScaleModuleInitialize.
        Returns $true when all required YAML templates were copied successfully; $false when any
        required template is missing or a copy fails (error is logged before returning).
        Write-Host is the primary output mechanism in this function; all Write-Host calls are
        intentional interactive console output. Use Write-LogMessage for diagnostic logging.
    #>

    [CmdletBinding()]
    [OutputType([Bool])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$DocsDirectory,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ServicesYamlDirectory,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$TemplateRestoreHint,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$TemplatesPath,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ToolsDirectory
    )

    Write-Host ""
    Write-Host "  Supervisor service YAML (ServicesYaml)" -ForegroundColor Magenta
    foreach ($templateFileName in $Script:VcfEdgeAtScaleServiceYamlTemplateFileNames) {
        $fromPath = Join-Path -Path $TemplatesPath -ChildPath $templateFileName
        if (-not (Test-Path -LiteralPath $fromPath -PathType Leaf)) {
            Write-LogMessage -Type ERROR -Message "Required module template is missing: $fromPath. $TemplateRestoreHint"
            return $false
        }
        $toPath = Join-Path -Path $ServicesYamlDirectory -ChildPath $templateFileName
        if (-not (Confirm-FileOverwritePrompt -FilePath $toPath)) {
            Write-Host "    Skipped (keep existing): $templateFileName" -ForegroundColor Yellow
            continue
        }
        try {
            Copy-Item -LiteralPath $fromPath -Destination $toPath -Force -ErrorAction Stop
        } catch {
            Write-LogMessage -Type ERROR -Message "Failed to copy `"$templateFileName`" to `"$toPath`": $($_.Exception.Message)"
            return $false
        }
        Write-Host "    Copied: $templateFileName" -ForegroundColor Green
    }

    Copy-TemplateDocumentationFiles -DocsDirectory $DocsDirectory -TemplateRestoreHint $TemplateRestoreHint -TemplatesPath $TemplatesPath

    # Help JSON files are not user-edited; auto-refresh silently when the module version changes.
    $helpJsonFileNames = @($Script:INFRA_HELP_FILENAME, $Script:SUPERVISOR_HELP_FILENAME)
    foreach ($helpFileName in $helpJsonFileNames) {
        $helpTemplatePath = Join-Path -Path $TemplatesPath -ChildPath $helpFileName
        $helpDocsPath = Join-Path -Path $DocsDirectory -ChildPath $helpFileName
        $helpWasUpdated = Update-HelpJsonIfStale -DocsPath $helpDocsPath -TemplatePath $helpTemplatePath
        if (Test-Path -LiteralPath $helpDocsPath -PathType Leaf) {
            if ($helpWasUpdated) {
                Write-Host "    Updated: $helpFileName" -ForegroundColor Green
            } else {
                Write-Host "    Current: $helpFileName" -ForegroundColor Gray
            }
        }
    }

    $moduleToolsPath = Join-Path -Path (Split-Path -Path $TemplatesPath -Parent) -ChildPath $Script:TOOLS_DIR_NAME

    Write-Host ""
    Write-Host "  Tools" -ForegroundColor Magenta
    $configUiFileName = "veas-json-generator.py"
    $configUiSourcePath = Join-Path -Path $moduleToolsPath -ChildPath $configUiFileName
    if (-not (Test-Path -LiteralPath $configUiSourcePath -PathType Leaf)) {
        Write-LogMessage -Type WARNING -Message "Optional tool '$configUiFileName' is not in the module Tools folder (source not found at $configUiSourcePath). Skipping this copy; Initialize continues. $TemplateRestoreHint"
    } else {
        $configUiDestinationPath = Join-Path -Path $ToolsDirectory -ChildPath $configUiFileName
        if (Confirm-FileOverwritePrompt -FilePath $configUiDestinationPath) {
            $pyExeHint = (Get-PythonExecutable)?.Executable ?? "python3"
            try {
                Copy-Item -LiteralPath $configUiSourcePath -Destination $configUiDestinationPath -Force -ErrorAction Stop
                Write-Host "    Copied: $configUiFileName  (run: $pyExeHint `"$configUiDestinationPath`")" -ForegroundColor Green
            } catch {
                Write-LogMessage -Type WARNING -Message "Skipping tool copy '$configUiFileName' after error: $($_.Exception.Message) $TemplateRestoreHint"
            }
        } else {
            Write-Host "    Skipped (keep existing): $configUiFileName" -ForegroundColor Yellow
        }
    }

    # The HTML UI template is a versioned asset; always silently overwrite.
    $uiTemplateFileName = "veas-ui.html"
    $uiTemplateSourcePath = Join-Path -Path $moduleToolsPath -ChildPath $uiTemplateFileName
    if (-not (Test-Path -LiteralPath $uiTemplateSourcePath -PathType Leaf)) {
        Write-LogMessage -Type WARNING -Message "Optional UI template '$uiTemplateFileName' is not in the module Tools folder (source not found at $uiTemplateSourcePath). Skipping this copy; Initialize continues. $TemplateRestoreHint"
    } else {
        $uiTemplateDestinationPath = Join-Path -Path $ToolsDirectory -ChildPath $uiTemplateFileName
        try {
            Copy-Item -LiteralPath $uiTemplateSourcePath -Destination $uiTemplateDestinationPath -Force -ErrorAction Stop
            Write-Host "    Copied: $uiTemplateFileName" -ForegroundColor Green
        } catch {
            Write-LogMessage -Type WARNING -Message "Skipping UI template copy '$uiTemplateFileName' after error: $($_.Exception.Message) $TemplateRestoreHint"
        }
    }
    return $true
}
function Write-InfrastructureJsonFromTemplate {

    <#
    .SYNOPSIS
        Writes infrastructure.json from the module template, substituting directory tokens.
    .DESCRIPTION
        Reads the template, patches common.supervisorServices.parentDirectory to ServicesYamlDirectory
        and harborConfiguration.parentDirectory to BaseDirectory via regex, validates the resulting
        JSON parses cleanly, then writes the file. Returns $false on any failure (error is logged).
    .PARAMETER BaseDirectory
        Resolved absolute path of the deployment base directory.
    .PARAMETER InfrastructureDestinationPath
        Destination path for the infrastructure JSON file.
    .PARAMETER InfrastructureTemplatePath
        Full path to the bundled infrastructure.json template.
    .PARAMETER ServicesYamlDirectory
        Full path to the ServicesYaml subdirectory.
    .PARAMETER TemplateRestoreHint
        User-facing hint for error messages when the template is missing.
    .EXAMPLE
        Write-InfrastructureJsonFromTemplate -BaseDirectory $base -InfrastructureDestinationPath $dest -InfrastructureTemplatePath $tmpl -ServicesYamlDirectory $svcDir -TemplateRestoreHint $hint
    .NOTES
        Returns $true on success, $false on any error (error is already logged before returning).
    #>

    [CmdletBinding()]
    [OutputType([Bool])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$BaseDirectory,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$InfrastructureDestinationPath,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$InfrastructureTemplatePath,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ServicesYamlDirectory,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$TemplateRestoreHint
    )

    if (-not (Test-Path -LiteralPath $InfrastructureTemplatePath -PathType Leaf)) {
        Write-LogMessage -Type ERROR -Message "Cannot create infrastructure.json from module template: file not found at $InfrastructureTemplatePath. $TemplateRestoreHint"
        return $false
    }

    $infrastructureTemplateText = Get-Content -LiteralPath $InfrastructureTemplatePath -Raw -ErrorAction Stop

    # Set common.supervisorServices.parentDirectory to ServicesYaml and
    # clusters[].harborConfiguration.parentDirectory to the base directory.
    # Avoid ConvertTo-Json so template formatting (e.g. nicList) stays as shipped.
    $escapedServicesDir = $ServicesYamlDirectory.Replace('\', '\\').Replace('"', '\"')
    $supervisorParentPattern = '(?s)("common"\s*:\s*\{.*?"supervisorServices"\s*:\s*\{.*?"parentDirectory"\s*:\s*")([^"]*)(")'
    $supervisorParentMatch = [Regex]::Match($infrastructureTemplateText, $supervisorParentPattern)
    if (-not $supervisorParentMatch.Success) {
        Write-LogMessage -Type ERROR -Message "Module template infrastructure.json must include common.supervisorServices.parentDirectory for Initialize. $TemplateRestoreHint"
        return $false
    }

    $infrastructureJsonText = $infrastructureTemplateText.Substring(0, $supervisorParentMatch.Index) + $supervisorParentMatch.Groups[1].Value + $escapedServicesDir + $supervisorParentMatch.Groups[3].Value + $infrastructureTemplateText.Substring($supervisorParentMatch.Index + $supervisorParentMatch.Length)
    $escapedBaseDir = $BaseDirectory.Replace('\', '\\').Replace('"', '\"')
    $harborParentPattern = '(?s)("harborConfiguration"\s*:\s*\{[^}]*?"parentDirectory"\s*:\s*")([^"]*)(")'
    if ([Regex]::IsMatch($infrastructureJsonText, $harborParentPattern)) {
        $infrastructureJsonText = [Regex]::Replace($infrastructureJsonText, $harborParentPattern, "`${1}$escapedBaseDir`${3}")
    } else {
        Write-LogMessage -Type WARNING -Message "Module template infrastructure.json does not contain harborConfiguration.parentDirectory; skipping Harbor parentDirectory initialization."
    }

    try {
        $null = $infrastructureJsonText | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Write-LogMessage -Type ERROR -Message "After setting parentDirectory fields, infrastructure JSON did not parse: $($_.Exception.Message)"
        return $false
    }

    try {
        Set-Content -LiteralPath $InfrastructureDestinationPath -Value $infrastructureJsonText -Encoding utf8 -ErrorAction Stop
    } catch {
        Write-LogMessage -Type ERROR -Message "Failed to write infrastructure JSON to `"$InfrastructureDestinationPath`": $($_.Exception.Message)"
        return $false
    }

    Write-LogMessage -Type INFO -Message "Wrote infrastructure.json (common.supervisorServices.parentDirectory -> ServicesYaml; harborConfiguration.parentDirectory -> base directory)."
    return $true
}
function Initialize-RootJsonFilesFromTemplate {

    <#
        .SYNOPSIS
        Seeds or replaces infrastructure.json and supervisor.json from bundled module templates.

        .DESCRIPTION
        Prompts the user if either JSON file already exists, then copies or writes the file from the
        module template. For infrastructure.json the parentDirectory fields for supervisorServices and
        harborConfiguration are patched via regex to match the current deployment layout before writing.
        Validation-parses the final JSON before writing to catch any substitution errors early.
        Returns $true on success and $false on any error (error is logged via Write-LogMessage -Type ERROR
        before returning $false; the caller should check the return value and return early on $false).

        .OUTPUTS
        [Bool] $true on success, $false on any error.

        .PARAMETER BaseDirectory
        Resolved absolute path of the deployment base directory. Used to set
        harborConfiguration.parentDirectory in the infrastructure template.

        .PARAMETER InfrastructureDestinationPath
        Full path where infrastructure.json should be written.

        .PARAMETER InfrastructureTemplatePath
        Full path to the bundled infrastructure.json template in the module Templates folder.

        .PARAMETER ServicesYamlDirectory
        Full path to the ServicesYaml subdirectory. Used to set
        common.supervisorServices.parentDirectory in the infrastructure template.

        .PARAMETER SupervisorDestinationPath
        Full path where supervisor.json should be written.

        .PARAMETER SupervisorTemplatePath
        Full path to the bundled supervisor.json template in the module Templates folder.

        .PARAMETER TemplateRestoreHint
        User-facing hint appended to error messages when a template file is missing.

        .EXAMPLE
        Initialize-RootJsonFilesFromTemplate `
            -BaseDirectory               $resolvedBase `
            -InfrastructureDestinationPath (Join-Path $resolvedBase "infrastructure.json") `
            -InfrastructureTemplatePath  (Join-Path $templatesPath "infrastructure.json") `
            -ServicesYamlDirectory       (Join-Path $resolvedBase "ServicesYaml") `
            -SupervisorDestinationPath   (Join-Path $resolvedBase "supervisor.json") `
            -SupervisorTemplatePath      (Join-Path $templatesPath "supervisor.json") `
            -TemplateRestoreHint         $hint

        .NOTES
        Write-Host is the primary output mechanism in this function; all Write-Host calls are
        intentional interactive console output. Use Write-LogMessage for diagnostic logging.
        Private to the module. Called from Invoke-VcfEdgeAtScaleModuleInitialize.
    #>

    [CmdletBinding()]
    [OutputType([Bool])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$BaseDirectory,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$InfrastructureDestinationPath,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$InfrastructureTemplatePath,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ServicesYamlDirectory,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$SupervisorDestinationPath,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$SupervisorTemplatePath,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$TemplateRestoreHint
    )

    Write-Host ""
    Write-Host "  Root JSON files" -ForegroundColor Magenta
    $shouldWriteInfrastructureFromTemplate = $false
    if (-not (Test-Path -LiteralPath $InfrastructureDestinationPath -PathType Leaf)) {
        $shouldWriteInfrastructureFromTemplate = $true
    } else {
        Write-Host "    infrastructure.json already exists at $InfrastructureDestinationPath." -ForegroundColor White
        try {
            $refreshInfrastructureAnswer = Read-Host "Replace infrastructure.json from the module template (supervisorServices.parentDirectory -> ServicesYaml; harborConfiguration.parentDirectory -> base directory)? (y/N)"
        } catch {
            Write-LogMessage -Type ERROR -Message "Initialize requires an interactive session for refresh prompts. $($_.Exception.Message)"
            return $false
        }
        switch ($refreshInfrastructureAnswer) {
            "y" { $shouldWriteInfrastructureFromTemplate = $true }
            "Y" { $shouldWriteInfrastructureFromTemplate = $true }
            default {
                Write-Host "    Kept existing infrastructure.json." -ForegroundColor Yellow
            }
        }
    }
    if ($shouldWriteInfrastructureFromTemplate) {
        $writeInfraParams = @{
            BaseDirectory                  = $BaseDirectory
            InfrastructureDestinationPath  = $InfrastructureDestinationPath
            InfrastructureTemplatePath     = $InfrastructureTemplatePath
            ServicesYamlDirectory          = $ServicesYamlDirectory
            TemplateRestoreHint            = $TemplateRestoreHint
        }
        if (-not (Write-InfrastructureJsonFromTemplate @writeInfraParams)) {
            return $false
        }
    }

    $shouldWriteSupervisorFromTemplate = $false
    if (-not (Test-Path -LiteralPath $SupervisorDestinationPath -PathType Leaf)) {
        $shouldWriteSupervisorFromTemplate = $true
    } else {
        Write-Host "    supervisor.json already exists at $SupervisorDestinationPath." -ForegroundColor White
        try {
            $refreshSupervisorAnswer = Read-Host "Replace supervisor.json from the module template? (y/N)"
        } catch {
            Write-LogMessage -Type ERROR -Message "Initialize requires an interactive session for refresh prompts. $($_.Exception.Message)"
            return $false
        }
        switch ($refreshSupervisorAnswer) {
            "y" { $shouldWriteSupervisorFromTemplate = $true }
            "Y" { $shouldWriteSupervisorFromTemplate = $true }
            default {
                Write-Host "    Kept existing supervisor.json." -ForegroundColor Yellow
            }
        }
    }
    if ($shouldWriteSupervisorFromTemplate) {
        if (-not (Test-Path -LiteralPath $SupervisorTemplatePath -PathType Leaf)) {
            Write-LogMessage -Type ERROR -Message "Cannot copy supervisor.json from module template: file not found at $SupervisorTemplatePath. $TemplateRestoreHint"
            return $false
        }
        try {
            Copy-Item -LiteralPath $SupervisorTemplatePath -Destination $SupervisorDestinationPath -Force -ErrorAction Stop
        } catch {
            Write-LogMessage -Type ERROR -Message "Failed to copy supervisor.json to `"$SupervisorDestinationPath`": $($_.Exception.Message) $TemplateRestoreHint"
            return $false
        }
        Write-Host "    Copied supervisor.json to deployment root." -ForegroundColor Green
    }

    return $true
}
function Invoke-PersistDeploymentRootDirectory {

    <#
        .SYNOPSIS
        Persists VcfEdgeAtScaleRootDirectory for future sessions and writes the Initialize summary.

        .DESCRIPTION
        Sets VcfEdgeAtScaleRootDirectory in the current session. On Windows, also writes it to the
        user environment registry so Explorer-launched processes inherit it. On all platforms,
        appends the assignment to $PROFILE so SSH and other non-Explorer sessions also pick it up.
        After all persistence operations, writes the Initialize summary to the console.

        .PARAMETER BaseDirectoryWasCreated
        True when the base directory was created by Initialize (was not pre-existing). Used in the
        summary line that distinguishes "created" from "already existed."

        .PARAMETER ResolvedBaseDirectory
        Fully resolved absolute path of the deployment root directory. Written to the env var,
        registry, and profile.

        .PARAMETER SubdirectoriesCreated
        List of subdirectory names created during this Initialize run. Used in the summary.

        .PARAMETER TemplatesOnly
        When set, adjusts the summary line for the root JSON section to note that JSON was
        not modified.

        .EXAMPLE
        Invoke-PersistDeploymentRootDirectory `
            -BaseDirectoryWasCreated $true `
            -ResolvedBaseDirectory   $resolvedBase `
            -SubdirectoriesCreated   $subdirectoriesCreated `
            -TemplatesOnly:          $TemplatesOnly.IsPresent

        .NOTES
        Write-Host is the primary output mechanism in this function; all Write-Host calls are
        intentional interactive console output. Use Write-LogMessage for diagnostic logging.
        Private to the module. Called from Invoke-VcfEdgeAtScaleModuleInitialize.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [Bool]$BaseDirectoryWasCreated,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ResolvedBaseDirectory,
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [System.Collections.Generic.List[String]]$SubdirectoriesCreated,
        [Parameter(Mandatory = $false)] [Switch]$TemplatesOnly
    )

    $env:VcfEdgeAtScaleRootDirectory = $ResolvedBaseDirectory
    $persistedEnvSucceeded = $false

    if ($IsWindows) {
        # On Windows, persist to the user environment registry so new sessions inherit it automatically.
        try {
            [System.Environment]::SetEnvironmentVariable($Script:ENV_VAR_NAME, $ResolvedBaseDirectory, [System.EnvironmentVariableTarget]::User)
            # Read back to confirm the write landed; some Windows configurations silently no-op.
            $verifyValue = [System.Environment]::GetEnvironmentVariable($Script:ENV_VAR_NAME, [System.EnvironmentVariableTarget]::User)
            $persistedEnvSucceeded = ($verifyValue -eq $ResolvedBaseDirectory)
            if (-not $persistedEnvSucceeded) {
                Write-LogMessage -Type WARNING -Message "VcfEdgeAtScaleRootDirectory registry write appeared to succeed but read-back returned '$verifyValue' instead of '$ResolvedBaseDirectory'."
            }
        } catch {
            Write-LogMessage -Type WARNING -Message "Could not persist VcfEdgeAtScaleRootDirectory to the user environment: $($_.Exception.Message)"
        }
    }
    # On macOS/Linux, [System.EnvironmentVariableTarget]::User is not supported by .NET
    # and will throw PlatformNotSupportedException. The $PROFILE append below covers both platforms.

    Write-Host ""
    Write-Host "=== Initialize summary ===" -ForegroundColor Cyan
    Write-Host "  Deployment root: $ResolvedBaseDirectory" -ForegroundColor White
    if ($BaseDirectoryWasCreated) {
        Write-Host "  Base directory: created (it did not exist before)." -ForegroundColor Green
    } else {
        Write-Host "  Base directory: already existed; files kept unless you chose overwrite." -ForegroundColor Gray
    }
    if ($SubdirectoriesCreated.Count -gt 0) {
        Write-Host "  Subdirectories created: $($SubdirectoriesCreated -join ', ')." -ForegroundColor Green
    } else {
        Write-Host "  Subdirectories Docs, Logs, ServicesYaml, Tools: already present." -ForegroundColor Gray
    }
    Write-Host "  See sections above for YAML, Docs, Tools, and JSON actions." -ForegroundColor Gray
    Write-Host "  Optional Docs/Tools sources may show WARNING if your module install is missing files." -ForegroundColor Gray
    if (-not $TemplatesOnly) {
        Write-Host "  Root JSON: created or refreshed per your answers above." -ForegroundColor Gray
    } else {
        Write-Host "  Root JSON was not modified (templates-only mode)." -ForegroundColor Gray
    }
    if ($IsWindows) {
        if ($persistedEnvSucceeded) {
            Write-Host "  VcfEdgeAtScaleRootDirectory -> $ResolvedBaseDirectory (session + user environment persisted)." -ForegroundColor Green
        } else {
            Write-Host "  VcfEdgeAtScaleRootDirectory -> $ResolvedBaseDirectory (current session only; user-level persist failed — see warning above)." -ForegroundColor Yellow
            Write-Host '  To set manually: [System.Environment]::SetEnvironmentVariable("VcfEdgeAtScaleRootDirectory", "<path>", [System.EnvironmentVariableTarget]::User)' -ForegroundColor Cyan
        }
    } else {
        Write-Host "  VcfEdgeAtScaleRootDirectory -> $ResolvedBaseDirectory (set for this session)." -ForegroundColor Green
    }
    Write-Host ""

    $profileLine = "`$env:VcfEdgeAtScaleRootDirectory = `"$ResolvedBaseDirectory`""
    $appendedToProfile = $false
    try {
        $profileDir = Split-Path $PROFILE -Parent
        if (-not (Test-Path $profileDir)) {
            New-Item -ItemType Directory -Path $profileDir -Force | Out-Null
        }
        if (-not (Test-Path $PROFILE)) {
            New-Item -ItemType File -Path $PROFILE -Force | Out-Null
        }
        $existingContent = Get-Content -LiteralPath $PROFILE -Raw -ErrorAction SilentlyContinue
        if ($existingContent -notmatch [Regex]::Escape($Script:ENV_VAR_NAME)) {
            Add-Content -LiteralPath $PROFILE -Value "`n$profileLine" -Encoding UTF8
            $appendedToProfile = $true
        }
    } catch {
        Write-LogMessage -Type WARNING -Message "Could not append to `$PROFILE ($PROFILE): $($_.Exception.Message)"
    }

    if ($appendedToProfile) {
        Write-Host "  Line appended to: $PROFILE" -ForegroundColor Green
        Write-Host "  New terminal sessions will inherit this variable automatically." -ForegroundColor Gray
    } else {
        Write-Host "  Note: `$PROFILE already contains VcfEdgeAtScaleRootDirectory — no change made." -ForegroundColor Gray
        Write-Host "  Profile: $PROFILE" -ForegroundColor Gray
    }
}
function Invoke-VcfEdgeAtScaleModuleInitialize {

    <#
        .SYNOPSIS
            Interactively creates the on-disk layout for VcfEdgeAtScale configuration, logs, YAML, and documentation.

        .DESCRIPTION
            Prompts for a base directory (default joins the user home directory with VCFEdgeAtScale), creates Docs,
            Logs, and ServicesYaml when missing, and copies bundled Supervisor service YAML templates and documentation files from the
            Templates directory (including EXAMPLE.rtf and README.rtf) with overwrite prompts (default N). Missing
            documentation sources under Templates are skipped with a warning (initialize does not fail for those; the
            summary block at the end lists what succeeded). Missing
            Supervisor service YAML or infrastructure/supervisor JSON templates still fails with guidance to reinstall the
            module or copy files from the GitHub repository. Works for a new or existing configuration directory. When -TemplatesOnly is set, only YAML and Docs files are refreshed; root
            infrastructure.json and supervisor.json are not created or replaced. Otherwise seeds those JSON files when absent,
            and when they already exist offers optional replacement from module templates (infrastructure.json paths under
            ServicesYaml are updated when written from the template).             Persists VcfEdgeAtScaleRootDirectory via two mechanisms on all platforms: on Windows, also writes to
            [System.Environment]::SetEnvironmentVariable (User scope) so Explorer-launched processes inherit it from the registry.
            On all platforms, the variable assignment line is appended to $PROFILE so sessions not spawned by Explorer
            (SSH, some terminal emulators) also pick it up automatically.
            When VcfEdgeAtScaleRootDirectory points at an existing initialized layout, asks whether to initialize a different directory instead of re-prompting for the base path.

        .PARAMETER TemplatesOnly
            When set, copies only ServicesYaml and Docs templates; does not create or replace infrastructure.json or supervisor.json at the base directory.

        .NOTES
            Private to the module. Invoked from Start-VcfEdgeAtScale -Initialize only. Requires an interactive host for Read-Host.
            User-visible status uses Write-Host (not Write-Output) because Start-VcfEdgeAtScale assigns this function's output to $null, which would otherwise hide success-stream output.
            Write-Host is the primary output mechanism in this function; all Write-Host calls are
            intentional interactive console output. Use Write-LogMessage for diagnostic logging.
    
        .EXAMPLE
        Invoke-VcfEdgeAtScaleModuleInitialize
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $false)] [Switch]$TemplatesOnly
    )

    $templatesPath = Get-ModuleTemplatesPath
    $templateRestoreHint = "Reinstall the VcfEdgeAtScale module (for example Install-Module VcfEdgeAtScale -Force) or copy missing files from https://github.com/vmware/powershell-module-for-vcf-edge-at-scale (see the VcfEdgeAtScale/Templates folder in that repository)."
    $defaultBaseDirectory = Join-Path -Path $HOME -ChildPath $Script:DEFAULT_DEPLOY_DIR_NAME

    Write-Host ""
    Write-Host "VcfEdgeAtScale initialize" -ForegroundColor Cyan
    if ($TemplatesOnly) {
        Write-Host "  Mode: templates only — refresh ServicesYaml and Docs; root JSON is not modified." -ForegroundColor Gray
    } else {
        Write-Host "  Mode: full — configuration base, Logs, ServicesYaml, Docs, optional JSON seed/replace." -ForegroundColor Gray
    }

    $baseDirectory = Resolve-DeploymentRootDirectory -DefaultBaseDirectory $defaultBaseDirectory
    if ([String]::IsNullOrWhiteSpace($baseDirectory)) {
        return $null
    }

    $baseDirectoryExistedBefore = Test-Path -LiteralPath $baseDirectory -PathType Container
    $baseDirectoryWasCreated = $false
    if (-not $baseDirectoryExistedBefore) {
        try {
            $null = New-Item -ItemType Directory -Path $baseDirectory -Force -ErrorAction Stop
            $baseDirectoryWasCreated = $true
        } catch {
            Write-LogMessage -Type ERROR -Message "Failed to create base directory `"$baseDirectory`": $($_.Exception.Message)"
            return $null
        }
    }

    if (-not (Test-Path -LiteralPath $baseDirectory)) {
        Write-LogMessage -Type ERROR -Message "Could not resolve the base directory path after create — directory not found: `"$baseDirectory`"."
        return $null
    }
    $resolvedBaseDirectory = (Resolve-Path -LiteralPath $baseDirectory).Path

    $subdirectoriesCreated = New-DeploySubdirectories -ResolvedBaseDirectory $resolvedBaseDirectory
    if ($null -eq $subdirectoriesCreated) {
        return $null
    }

    $servicesYamlDirectory = Join-Path -Path $resolvedBaseDirectory -ChildPath $Script:SERVICES_YAML_DIR_NAME
    $docsDirectory = Join-Path -Path $resolvedBaseDirectory -ChildPath $Script:DOCS_DIR_NAME
    $toolsDirectory = Join-Path -Path $resolvedBaseDirectory -ChildPath $Script:TOOLS_DIR_NAME

    $templatesCopied = Copy-InitializeTemplateFiles `
        -DocsDirectory         $docsDirectory `
        -ServicesYamlDirectory $servicesYamlDirectory `
        -TemplateRestoreHint   $templateRestoreHint `
        -TemplatesPath         $templatesPath `
        -ToolsDirectory        $toolsDirectory
    if (-not $templatesCopied) {
        return $null
    }

    if (-not $TemplatesOnly) {
        $jsonResult = Initialize-RootJsonFilesFromTemplate `
            -BaseDirectory                 $resolvedBaseDirectory `
            -InfrastructureDestinationPath (Join-Path -Path $resolvedBaseDirectory -ChildPath $Script:INFRA_JSON_FILENAME) `
            -InfrastructureTemplatePath    (Join-Path -Path $templatesPath -ChildPath $Script:INFRA_JSON_FILENAME) `
            -ServicesYamlDirectory         $servicesYamlDirectory `
            -SupervisorDestinationPath     (Join-Path -Path $resolvedBaseDirectory -ChildPath $Script:SUPERVISOR_JSON_FILENAME) `
            -SupervisorTemplatePath        (Join-Path -Path $templatesPath -ChildPath $Script:SUPERVISOR_JSON_FILENAME) `
            -TemplateRestoreHint           $templateRestoreHint
        if (-not $jsonResult) {
            return $null
        }
    } else {
        Write-Host ""
        Write-Host "  Templates-only mode: skipped root infrastructure.json and supervisor.json." -ForegroundColor Gray
    }

    Invoke-PersistDeploymentRootDirectory `
        -BaseDirectoryWasCreated $baseDirectoryWasCreated `
        -ResolvedBaseDirectory   $resolvedBaseDirectory `
        -SubdirectoriesCreated   $subdirectoriesCreated `
        -TemplatesOnly:          $TemplatesOnly.IsPresent

    return $resolvedBaseDirectory
}
function Invoke-VcfEdgeAtScaleCollectLogs {

    <#
        .SYNOPSIS
        Interactively builds a support archive of deployment JSON, Logs, and ServicesYaml.

        .DESCRIPTION
        Prompts whether to use infrastructure.json and supervisor.json under the deployment root (from
        VcfEdgeAtScaleRootDirectory or a typed path), or custom paths. Copies those files plus the contents of
        Logs and ServicesYaml under the deployment root into a zip under the user home directory.

        .OUTPUTS
        [String] Full path to the created zip file.

        .NOTES
        Private to the module. Invoked from Start-VcfEdgeAtScale -CollectLogs only.
        Returns $null on any error (error is logged via Write-LogMessage -Type ERROR before returning).
        Write-Host is the primary output mechanism in this function; all Write-Host calls are
        intentional interactive console output. Use Write-LogMessage for diagnostic logging.
    
        .EXAMPLE
        Invoke-VcfEdgeAtScaleCollectLogs
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param ()

    $deploymentRootRaw = $env:VcfEdgeAtScaleRootDirectory
    if ([String]::IsNullOrWhiteSpace($deploymentRootRaw)) {
        Write-Host "VcfEdgeAtScaleRootDirectory is not set."
        try {
            $deploymentRootRaw = Read-Host "Enter deployment root (folder that contains Logs and ServicesYaml)"
        } catch {
            Write-LogMessage -Type ERROR -Message "CollectLogs requires an interactive session or set VcfEdgeAtScaleRootDirectory. $($_.Exception.Message)"
            return $null
        }
    }
    if ([String]::IsNullOrWhiteSpace($deploymentRootRaw)) {
        Write-LogMessage -Type ERROR -Message "A deployment root directory is required for CollectLogs."
        return $null
    }
    if (-not (Test-Path -LiteralPath $deploymentRootRaw.Trim())) {
        Write-LogMessage -Type ERROR -Message "Could not resolve deployment root — path does not exist: `"$deploymentRootRaw`"."
        return $null
    }
    $deploymentRoot = (Resolve-Path -LiteralPath $deploymentRootRaw.Trim()).Path

    $defaultInfrastructurePath = Join-Path -Path $deploymentRoot -ChildPath $Script:INFRA_JSON_FILENAME
    $defaultSupervisorPath = Join-Path -Path $deploymentRoot -ChildPath $Script:SUPERVISOR_JSON_FILENAME

    Write-Host ""
    Write-Host "Default JSON files under deployment root:"
    Write-Host "  $defaultInfrastructurePath"
    Write-Host "  $defaultSupervisorPath"
    try {
        $useDefaultsResponse = Read-Host "Use these two files in the zip? (Y/n)"
    } catch {
        Write-LogMessage -Type ERROR -Message "CollectLogs requires an interactive session. $($_.Exception.Message)"
        return $null
    }

    $infrastructureSourcePath = $null
    $supervisorSourcePath = $null
    switch -Regex ($useDefaultsResponse.Trim()) {
        "^(?i)(n|no)$" {
            try {
                $infrastructureSourcePath = Read-Host "Full path to infrastructure.json to include"
                $supervisorSourcePath = Read-Host "Full path to supervisor.json to include"
            } catch {
                Write-LogMessage -Type ERROR -Message "CollectLogs requires an interactive session for custom paths. $($_.Exception.Message)"
                return $null
            }
        }
        default {
            $infrastructureSourcePath = $defaultInfrastructurePath
            $supervisorSourcePath = $defaultSupervisorPath
        }
    }

    if ([String]::IsNullOrWhiteSpace($infrastructureSourcePath) -or [String]::IsNullOrWhiteSpace($supervisorSourcePath)) {
        Write-LogMessage -Type ERROR -Message "Both infrastructure.json and supervisor.json paths are required."
        return $null
    }

    # Resolve-Path emits a non-terminating error (not a throw) when the file does not exist, so
    # try/catch cannot guard it. Test-Path first to avoid polluting the error stream.
    $infrastructureSourcePath = $infrastructureSourcePath.Trim()
    $supervisorSourcePath = $supervisorSourcePath.Trim()
    if (-not (Test-Path -LiteralPath $infrastructureSourcePath -PathType Leaf)) {
        Write-LogMessage -Type ERROR -Message "infrastructure file not found: $infrastructureSourcePath"
        return $null
    }
    if (-not (Test-Path -LiteralPath $supervisorSourcePath -PathType Leaf)) {
        Write-LogMessage -Type ERROR -Message "supervisor file not found: $supervisorSourcePath"
        return $null
    }
    $infrastructureSourcePath = (Resolve-Path -LiteralPath $infrastructureSourcePath).Path
    $supervisorSourcePath = (Resolve-Path -LiteralPath $supervisorSourcePath).Path

    $logsSourcePath = Join-Path -Path $deploymentRoot -ChildPath $Script:LOGS_DIR_NAME
    $servicesYamlSourcePath = Join-Path -Path $deploymentRoot -ChildPath $Script:SERVICES_YAML_DIR_NAME

    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $zipFileName = "VcfEdgeAtScale-logs-$stamp.zip"
    $zipDestinationPath = Join-Path -Path $HOME -ChildPath $zipFileName
    $stagingParent = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "VcfEdgeAtScale-collect-$stamp"
    $stagingRoot = Join-Path -Path $stagingParent -ChildPath "archive"

    try {
        $null = New-Item -ItemType Directory -Path $stagingRoot -Force -ErrorAction Stop
        $stagingLogs = Join-Path -Path $stagingRoot -ChildPath $Script:LOGS_DIR_NAME
        $stagingServicesYaml = Join-Path -Path $stagingRoot -ChildPath $Script:SERVICES_YAML_DIR_NAME
        $null = New-Item -ItemType Directory -Path $stagingLogs -Force -ErrorAction Stop
        $null = New-Item -ItemType Directory -Path $stagingServicesYaml -Force -ErrorAction Stop

        Copy-Item -LiteralPath $infrastructureSourcePath -Destination (Join-Path -Path $stagingRoot -ChildPath $Script:INFRA_JSON_FILENAME) -Force -ErrorAction Stop
        Copy-Item -LiteralPath $supervisorSourcePath -Destination (Join-Path -Path $stagingRoot -ChildPath $Script:SUPERVISOR_JSON_FILENAME) -Force -ErrorAction Stop

        if (Test-Path -LiteralPath $logsSourcePath -PathType Container) {
            $logChildren = @(Get-ChildItem -LiteralPath $logsSourcePath -Force -ErrorAction SilentlyContinue)
            foreach ($logItem in $logChildren) {
                $logDest = Join-Path -Path $stagingLogs -ChildPath $logItem.Name
                Copy-Item -LiteralPath $logItem.FullName -Destination $logDest -Recurse -Force -ErrorAction Stop
            }
        } else {
            Write-LogMessage -Type WARNING -Message "Logs folder not found or not a directory: $logsSourcePath. The archive includes an empty Logs folder."
        }

        if (Test-Path -LiteralPath $servicesYamlSourcePath -PathType Container) {
            $yamlChildren = @(Get-ChildItem -LiteralPath $servicesYamlSourcePath -Force -ErrorAction SilentlyContinue)
            foreach ($yamlItem in $yamlChildren) {
                $yamlDest = Join-Path -Path $stagingServicesYaml -ChildPath $yamlItem.Name
                Copy-Item -LiteralPath $yamlItem.FullName -Destination $yamlDest -Recurse -Force -ErrorAction Stop
            }
        } else {
            Write-LogMessage -Type WARNING -Message "ServicesYaml folder not found or not a directory: $servicesYamlSourcePath. The archive includes an empty ServicesYaml folder."
        }

        if (Test-Path -LiteralPath $zipDestinationPath -PathType Leaf) {
            Remove-Item -LiteralPath $zipDestinationPath -Force -ErrorAction Stop
        }

        $compressItems = @(
            (Join-Path -Path $stagingRoot -ChildPath $Script:INFRA_JSON_FILENAME),
            (Join-Path -Path $stagingRoot -ChildPath $Script:SUPERVISOR_JSON_FILENAME),
            $stagingLogs,
            $stagingServicesYaml
        )
        Compress-Archive -Path $compressItems -DestinationPath $zipDestinationPath -Force -ErrorAction Stop

        Write-Host ""
        Write-Host "CollectLogs finished. Archive saved to:"
        Write-Host "  $zipDestinationPath"
    } finally {
        if (Test-Path -LiteralPath $stagingParent) {
            Remove-Item -LiteralPath $stagingParent -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    return $zipDestinationPath
}
function Invoke-VcfEdgeAtScaleModuleVersionStalenessCheck {

    <#
        .SYNOPSIS
        Warns when the module on disk differs from the version loaded in the current session.

        .DESCRIPTION
        Reads the ModuleVersion from the .psd1 on disk and compares it to $Script:ModuleVersion,
        which was captured when the module was imported. A mismatch means the module files have
        been updated since this PowerShell session started; the user must open a new window for
        the changes to take effect.

        Failures (missing manifest, unreadable file) are silently swallowed at DEBUG level so they
        never interrupt a deployment run.

        .NOTES
        Called at the start of every Start-VcfEdgeAtScale run, after New-LogFile opens the log.
    
        .EXAMPLE
        Invoke-VcfEdgeAtScaleModuleVersionStalenessCheck
    #>

    [CmdletBinding()]
    Param ()

    [CmdletBinding()]
    $manifestPath = Join-Path -Path $Script:ModuleRoot -ChildPath "VcfEdgeAtScale.psd1"
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        return
    }
    try {
        $diskVersion = (Import-PowerShellDataFile -Path $manifestPath).ModuleVersion
    } catch {
        Write-LogMessage -Type DEBUG -Message "Module staleness check skipped — could not read manifest: $($_.Exception.Message)"
        return
    }
    if ($diskVersion -ne $Script:ModuleVersion) {
        Write-LogMessage -Type WARNING -Message (
            "Module on disk is version $diskVersion but this session loaded version $Script:ModuleVersion. " +
            "Open a new PowerShell window to run the updated module."
        )
    }
}
function Write-VcfDeploymentFailureFooter {

    <#
        .SYNOPSIS
        Writes a colored failure footer to the console after a deployment error.

        .DESCRIPTION
        Emits a colored console footer with the log file path (if one was created) and a
        reminder to run Start-VcfEdgeAtScale -CollectLogs to bundle support artifacts.
        When no log file was created, reports that check as well.

        .EXAMPLE
        Write-VcfDeploymentFailureFooter

        .NOTES
        Write-Host is the primary output mechanism in this function; all Write-Host calls are
        intentional interactive console output. Use Write-LogMessage for diagnostic logging.
    #>

    [CmdletBinding()]
    Param ()

    Write-Host ""
    if (-not [String]::IsNullOrWhiteSpace($Script:LogFile) -and (Test-Path -LiteralPath $Script:LogFile -PathType Leaf)) {
        Write-Host "Deployment failed. Log file: $Script:LogFile" -ForegroundColor Red
        Write-Host "To collect logs and configuration for support, run:" -ForegroundColor Yellow
        Write-Host "  Start-VcfEdgeAtScale -CollectLogs" -ForegroundColor Yellow
    } else {
        Write-Host "Deployment failed. No log file was created (check prerequisites)." -ForegroundColor Red
    }
    Write-Host ""
}
function Invoke-YamlFileExistenceValidation {

    <#
    .SYNOPSIS
        Validates that all required ArgoCD and Harbor YAML files exist on disk.

    .DESCRIPTION
        Checks that every ArgoCD operator YAML, ArgoCD deployment YAML, Harbor service YAML, and
        Harbor data-values template YAML referenced by the infrastructure configuration is present
        and accessible. Skips the check when in cleanup mode or when -ComputeOnly is set (neither
        ArgoCD nor Harbor is deployed in those cases). Throws VcfDeploymentException when any file
        is missing.

    .PARAMETER CleanUp
        When provided, YAML validation is skipped (cleanup does not use deployment YAMLs).

    .PARAMETER ComputeOnly
        When set, YAML validation is skipped (no supervisor services deployed in compute-only mode).

    .PARAMETER EdgeSitesArray
        Pre-resolved array of edge site identifiers to restrict which clusters are checked.
        Pass an empty array to check all clusters.

    .PARAMETER InputData
        The parsed infrastructure JSON object.

    .PARAMETER SiteIndication
        Human-readable string describing the scope (e.g. "all sites" or "edgeSite(s) "site1"").

    .EXAMPLE
        Invoke-YamlFileExistenceValidation -InputData $inputData -SiteIndication "all sites" -EdgeSitesArray @()

        Validates YAML files for all clusters.

    .NOTES
        Internal helper for Invoke-VcfEdgeAtScaleSiteDeployment. Throws VcfDeploymentException
        when required files are missing.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $false)] [ValidateSet("All", "ArgoCD", "Compute", "Harbor", "Supervisor")] [String]$CleanUp,
        [Parameter(Mandatory = $false)] [Switch]$ComputeOnly,
        [Parameter(Mandatory = $false)] [AllowEmptyCollection()] [String[]]$EdgeSitesArray = @(),
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object]$InputData,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$SiteIndication
    )

    if ($CleanUp -in @("All", "ArgoCD", "Compute", "Harbor", "Supervisor")) {
        Write-LogMessage -Type DEBUG -Message "Not performing YAML validation during cleanup."
        return
    }
    if ($ComputeOnly) {
        Write-LogMessage -Type DEBUG -Message "ComputeOnly: skipping YAML file existence validation (Argo CD and Harbor are not deployed)."
        return
    }

    Write-LogMessage -Type DEBUG -Message "Validating YAML file existence for $SiteIndication..."
    $yamlValidationStartTime = Get-Date

    $clustersToCheck = if ($EdgeSitesArray.Count -gt 0) {
        $InputData.clusters | Where-Object { $_.edgeSite -in $EdgeSitesArray }
    } else {
        $InputData.clusters
    }

    $missingYamlFiles = [System.Collections.Generic.List[Object]]::new()

    foreach ($cluster in $clustersToCheck) {
        $currentEdgeSite = $cluster.edgeSite
        if (Get-EffectiveSupervisorServiceFlag -Cluster $cluster -CommonData $InputData.common -FlagName "disableArgoCD") {
            Write-LogMessage -Type DEBUG -Message "ArgoCD is disabled for edgeSite `"$currentEdgeSite`"; skipping ArgoCD YAML path validation."
            continue
        }
        $argoCdOperatorYamlPath = Get-EffectiveArgoCdYamlPath -Cluster $cluster -CommonData $InputData.common -PropertyName "argoCdOperatorYamlPath"
        $argoCdDeploymentYamlPath = Get-EffectiveArgoCdYamlPath -Cluster $cluster -CommonData $InputData.common -PropertyName "argoCdDeploymentYamlPath"
        if ($argoCdOperatorYamlPath) {
            if (-not (Test-Path -LiteralPath $argoCdOperatorYamlPath)) {
                $missingYamlFiles.Add([PSCustomObject]@{ EdgeSite = $currentEdgeSite; FileType = "ArgoCD Operator YAML"; FilePath = $argoCdOperatorYamlPath })
            }
        } else {
            $missingYamlFiles.Add([PSCustomObject]@{ EdgeSite = $currentEdgeSite; FileType = "ArgoCD Operator YAML"; FilePath = "Not specified in configuration" })
        }
        if ($argoCdDeploymentYamlPath) {
            if (-not (Test-Path -LiteralPath $argoCdDeploymentYamlPath)) {
                $missingYamlFiles.Add([PSCustomObject]@{ EdgeSite = $currentEdgeSite; FileType = "ArgoCD Deployment YAML"; FilePath = $argoCdDeploymentYamlPath })
            }
        } else {
            $missingYamlFiles.Add([PSCustomObject]@{ EdgeSite = $currentEdgeSite; FileType = "ArgoCD Deployment YAML"; FilePath = "Not specified in configuration" })
        }
    }

    foreach ($cluster in $clustersToCheck) {
        if (Get-EffectiveSupervisorServiceFlag -Cluster $cluster -CommonData $InputData.common -FlagName "disableHarbor") {
            continue
        }
        $currentEdgeSite = $cluster.edgeSite
        $harborServiceYamlPath = Get-EffectiveSupervisorServicesYamlPath -Cluster $cluster -CommonData $InputData.common -LogicalYamlPathPropertyName "harborServiceYamlPath"
        if ($harborServiceYamlPath) {
            if (-not (Test-Path -LiteralPath $harborServiceYamlPath)) {
                $missingYamlFiles.Add([PSCustomObject]@{ EdgeSite = $currentEdgeSite; FileType = "Harbor Service YAML"; FilePath = $harborServiceYamlPath })
            }
        } else {
            $missingYamlFiles.Add([PSCustomObject]@{ EdgeSite = $currentEdgeSite; FileType = "Harbor Service YAML"; FilePath = "Not specified (supervisorServices.parentDirectory / harborServiceYamlFileName)" })
        }
        $harborDataValuesTemplatePath = Get-EffectiveSupervisorServicesYamlPath -Cluster $cluster -CommonData $InputData.common -LogicalYamlPathPropertyName "harborDataTemplateYamlPath"
        if ($harborDataValuesTemplatePath) {
            if (-not (Test-Path -LiteralPath $harborDataValuesTemplatePath)) {
                $missingYamlFiles.Add([PSCustomObject]@{ EdgeSite = $currentEdgeSite; FileType = "Harbor Data Values YAML template"; FilePath = $harborDataValuesTemplatePath })
            }
        } else {
            $missingYamlFiles.Add([PSCustomObject]@{ EdgeSite = $currentEdgeSite; FileType = "Harbor Data Values YAML template"; FilePath = "Not specified (supervisorServices.parentDirectory / harborDataTemplateYamlFileName)" })
        }
    }

    if ($missingYamlFiles.Count -gt 0) {
        $errorLines = [System.Collections.Generic.List[String]]::new()
        foreach ($missingFile in $missingYamlFiles) {
            $errorLines.Add("  - EdgeSite `"$($missingFile.EdgeSite)`": $($missingFile.FileType) - $($missingFile.FilePath)")
        }
        $errorMessage = "Required YAML files are missing or not accessible:`n$($errorLines -join "`n")"
        Write-LogMessage -Type ERROR -Message $errorMessage
        $err = "Deployment cannot proceed without required YAML files. Please ensure all YAML files exist at the specified paths and try again."
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }

    $yamlValidationElapsed = (Get-Date) - $yamlValidationStartTime
    Write-LogMessage -Type DEBUG -Message "YAML file validation completed for $SiteIndication in $($yamlValidationElapsed.TotalSeconds.ToString('F2')) seconds."
}
function Test-TopologyUniquenessOrThrow {

    <#
        .SYNOPSIS
        Validates network segment name uniqueness and ESX host uniqueness across all clusters.

        .DESCRIPTION
        Calls Test-NetworkSegmentNameUniqueness and Test-EsxHostUniqueness on the parsed
        infrastructure JSON. Throws VcfDeploymentException on the first uniqueness failure
        encountered, with a user-facing error message pointing to the conflict.

        .PARAMETER EdgeSite
        Optional edge-site filter passed to Test-NetworkSegmentNameUniqueness.

        .PARAMETER InputData
        Parsed infrastructure JSON object.

        .PARAMETER SiteIndication
        Human-readable scope string used in log messages.

        .PARAMETER ValidationStartTime
        Timestamp from the start of overall validation, used for elapsed-time reporting.

        .EXAMPLE
        Test-TopologyUniquenessOrThrow -InputData $inputData -SiteIndication "all sites" `
            -ValidationStartTime $validationStartTime

        .NOTES
        Called by Invoke-JsonConfigurationValidation. Throws on failure; returns nothing on success.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$EdgeSite,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object]$InputData,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$SiteIndication,
        [Parameter(Mandatory = $true)] [DateTime]$ValidationStartTime
    )

    $networkValidationStartTime = Get-Date
    Write-LogMessage -Type DEBUG -Message "Validating network segment names for $SiteIndication..."
    $networkSegmentValidationParams = @{ InputData = $InputData }
    if ($EdgeSite) { $networkSegmentValidationParams.EdgeSite = $EdgeSite }
    $networkSegmentNameValidationResult = Test-NetworkSegmentNameUniqueness @networkSegmentValidationParams
    if (-not $networkSegmentNameValidationResult.IsValid) {
        $err = "Network segment name uniqueness validation failed: $($networkSegmentNameValidationResult.ErrorMessage)"
        Write-LogMessage -Type ERROR -SuppressOutputToScreen -Message $err
        Write-LogMessage -Type ERROR -Message "Deployment cannot proceed with duplicate network segment names. Please fix the naming conflicts and try again."
        throw [VcfDeploymentException]::new($err)
    } else {
        Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "Network segment name uniqueness validation passed."
    }
    $networkValidationElapsed = (Get-Date) - $networkValidationStartTime
    $totalElapsed = (Get-Date) - $ValidationStartTime
    Write-LogMessage -Type DEBUG -Message "Network segment name validation completed for $SiteIndication in $($networkValidationElapsed.TotalSeconds.ToString('F2')) seconds (Total elapsed: $($totalElapsed.TotalSeconds.ToString('F2'))s)."

    Write-LogMessage -Type DEBUG -Message "Validating ESX host uniqueness across all clusters..."
    $esxHostValidationResult = Test-EsxHostUniqueness -InputData $InputData
    if (-not $esxHostValidationResult.IsValid) {
        $err = "ESX host uniqueness validation failed: $($esxHostValidationResult.ErrorMessage)"
        Write-LogMessage -Type ERROR -SuppressOutputToScreen -Message $err
        Write-LogMessage -Type ERROR -Message "Deployment cannot proceed with duplicate ESX hosts. Each host must belong to exactly one edge site."
        throw [VcfDeploymentException]::new($err)
    } else {
        Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "ESX host uniqueness validation passed."
    }
}
function Invoke-JsonConfigurationValidation {

    <#
    .SYNOPSIS
        Runs shallow, deeper, network-segment, and ESX-host uniqueness validation on the JSON
        configuration files.

    .DESCRIPTION
        Performs the full pre-deployment configuration validation sequence. Skipped during cleanup.
        Runs Test-JsonShallowValidation, the daily update check, Test-JsonDeeperValidation,
        Test-NetworkSegmentNameUniqueness, and Test-EsxHostUniqueness. Throws on the first
        validation failure encountered.

    .PARAMETER CleanUp
        When provided, all JSON validation is skipped (cleanup does not require a fully valid
        configuration).

    .PARAMETER ComputeOnly
        When set, supervisor-specific properties are excluded from shallow and deeper validation.

    .PARAMETER EdgeSite
        Optional comma-delimited edge site filter passed to shallow and deeper validators.

    .PARAMETER InputData
        The parsed infrastructure JSON object (used for network-segment and ESX-host checks).

    .PARAMETER InfrastructureJson
        Resolved path to infrastructure.json.

    .PARAMETER SiteIndication
        Human-readable scope string for log messages.

    .PARAMETER SupervisorJson
        Resolved path to supervisor.json.

    .PARAMETER ValidationStartTime
        Timestamp from the start of overall validation, used for elapsed-time reporting.

    .EXAMPLE
        Invoke-JsonConfigurationValidation -InfrastructureJson $infraPath -SupervisorJson $supPath `
            -InputData $inputData -SiteIndication "all sites" -ValidationStartTime (Get-Date)

        Validates both JSON files with no edge-site filter.

    .NOTES
        Internal helper for Invoke-VcfEdgeAtScaleSiteDeployment. Reads $Script:NewLogFileCreatedThisSession
        to gate the daily update check.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $false)] [ValidateSet("All", "ArgoCD", "Compute", "Harbor", "Supervisor")] [String]$CleanUp,
        [Parameter(Mandatory = $false)] [Switch]$ComputeOnly,
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$EdgeSite,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$InfrastructureJson,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object]$InputData,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$SiteIndication,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$SupervisorJson,
        [Parameter(Mandatory = $true)] [DateTime]$ValidationStartTime
    )

    if ($CleanUp -in @("All", "ArgoCD", "Compute", "Harbor", "Supervisor")) {
        Write-LogMessage -Type DEBUG -Message "Cleanup mode: skipping full JSON validation; configuration will be parsed in Initialize-VcfEdgeAtScale."
        return
    }

    Write-LogMessage -Type DEBUG -Message "Validating JSON configuration files for $SiteIndication..."

    $shallowValidationStartTime = Get-Date
    Write-LogMessage -Type INFO -Message "Checking for required JSON properties for $SiteIndication..."
    $shallowValidationParams = @{
        InfrastructureJson = $InfrastructureJson
        SupervisorJson     = $SupervisorJson
    }
    if ($ComputeOnly) { $shallowValidationParams.ComputeOnly = $true }
    if ($EdgeSite) { $shallowValidationParams.EdgeSite = $EdgeSite }
    try {
        Test-JsonShallowValidation @shallowValidationParams
        $shallowValidationElapsed = (Get-Date) - $shallowValidationStartTime
        $totalElapsed = (Get-Date) - $ValidationStartTime
        Write-LogMessage -Type DEBUG -Message "Required properties validation completed for $SiteIndication in $($shallowValidationElapsed.TotalSeconds.ToString('F2')) seconds (Total elapsed: $($totalElapsed.TotalSeconds.ToString('F2'))s)."
    } catch {
        $shallowValidationElapsed = (Get-Date) - $shallowValidationStartTime
        Write-LogMessage -Type ERROR -Message "Required properties validation failed for $SiteIndication after $($shallowValidationElapsed.TotalSeconds.ToString('F2')) seconds."
        throw
    }

    if ($Script:NewLogFileCreatedThisSession) {
        try {
            Invoke-VcfEdgeAtScaleUpdateCheck -Quiet -InputData $InputData
        } catch {
            Write-LogMessage -Type DEBUG -Message "Daily update check failed silently: $($_.Exception.Message)"
        }
    }

    $deeperValidationStartTime = Get-Date
    Write-LogMessage -Type INFO -Message "Validating property formats and values for $SiteIndication..."
    $deeperValidationParams = @{
        InfrastructureJson = $InfrastructureJson
        SupervisorJson     = $SupervisorJson
    }
    if ($ComputeOnly) { $deeperValidationParams.ComputeOnly = $true }
    if ($EdgeSite) { $deeperValidationParams.EdgeSite = $EdgeSite }
    try {
        Test-JsonDeeperValidation @deeperValidationParams
        $deeperValidationElapsed = (Get-Date) - $deeperValidationStartTime
        $totalElapsed = (Get-Date) - $ValidationStartTime
        Write-LogMessage -Type DEBUG -Message "Property format validation completed for $SiteIndication in $($deeperValidationElapsed.TotalSeconds.ToString('F2')) seconds (Total elapsed: $($totalElapsed.TotalSeconds.ToString('F2'))s)."
    } catch {
        $deeperValidationElapsed = (Get-Date) - $deeperValidationStartTime
        Write-LogMessage -Type ERROR -Message "Property format validation failed for $SiteIndication after $($deeperValidationElapsed.TotalSeconds.ToString('F2')) seconds."
        throw
    }

    $topologyParams = @{ InputData = $InputData; SiteIndication = $SiteIndication; ValidationStartTime = $ValidationStartTime }
    if ($EdgeSite) { $topologyParams.EdgeSite = $EdgeSite }
    Test-TopologyUniquenessOrThrow @topologyParams

    $validationEndTime = Get-Date
    $totalValidationTime = $validationEndTime - $ValidationStartTime
    Write-LogMessage -Type DEBUG -Message "JSON configuration validation completed successfully for $SiteIndication in $($totalValidationTime.TotalSeconds.ToString('F2')) seconds."
}
function Invoke-VcfEdgeAtScaleSiteDeployment {

    <#
    .SYNOPSIS
        Validates configuration files and orchestrates the full per-site edge deployment workflow.

    .DESCRIPTION
        Extracted from Start-VcfEdgeAtScale to separate the deployment orchestration logic from the
        outer parameter-dispatch shell. This function:

        - Sets rollback preference and module-scope flags from caller parameters.
        - Warns when the on-disk module has been updated since the session imported it.
        - Enforces the VCF PowerCLI minimum version.
        - Auto-refreshes Docs help JSON files when the module has been upgraded.
        - Validates infrastructure JSON and supervisor JSON (shallow, deep, network segment
          uniqueness, ESX host uniqueness, YAML file existence).
        - Exits after validation when -ValidateOnly is set.
        - Normalizes the -CleanUp scope string.
        - Runs the Harbor environment-variable preflight when Harbor is enabled.
        - Delegates to Initialize-VcfEdgeAtScale for the actual vCenter connection and per-site
          deployment or cleanup loop.

    .PARAMETER AcceptBadCheckResults
        Forwarded to Initialize-VcfEdgeAtScale. When set, proceeds without prompting on red
        vSAN or vLCM alarm states.

    .PARAMETER CleanUp
        Optional cleanup scope. When provided, Initialize-VcfEdgeAtScale runs cleanup instead of
        deploying. Must be one of: All, ArgoCD, Compute, Harbor, Supervisor.

    .PARAMETER ComputeOnly
        Forwarded to Initialize-VcfEdgeAtScale. When set, skips the supervisor and post-supervisor
        steps.

    .PARAMETER DelayBeforeAddingNextHostSeconds
        Forwarded to Initialize-VcfEdgeAtScale. Seconds to wait before adding the 2nd+ host to
        each cluster during deployment.

    .PARAMETER DeploymentRootDirectory
        Resolved path to the deployment root directory, used for Docs help JSON auto-refresh.

    .PARAMETER EdgeSite
        Optional comma-delimited list of edge site identifiers. When provided, only the matching
        clusters are validated and deployed.

    .PARAMETER Force
        Forwarded to Initialize-VcfEdgeAtScale. Bypasses cleanup confirmation when
        common.labenvironment is true.

    .PARAMETER InfrastructureJson
        Resolved path to infrastructure.json.

    .PARAMETER RollbackOnFailure
        Controls rollback behavior on failure. $true = always rollback without prompting.
        $false = never rollback (leave site in current state). $null = prompt with Y/N/Always.

    .PARAMETER SaveHarborYaml
        Forwarded to Initialize-VcfEdgeAtScale. When set, saves the rendered Harbor data values
        YAML file after installation.

    .PARAMETER SupervisorJson
        Resolved path to supervisor.json.

    .PARAMETER ValidateOnly
        When set, exits after configuration validation without deploying or running cleanup.

    .EXAMPLE
        Invoke-VcfEdgeAtScaleSiteDeployment -DeploymentRootDirectory $rootDir -InfrastructureJson $infraPath -SupervisorJson $supPath

        Validates both JSON files and runs the full deployment workflow.

    .EXAMPLE
        Invoke-VcfEdgeAtScaleSiteDeployment -DeploymentRootDirectory $rootDir -InfrastructureJson $infraPath -SupervisorJson $supPath -ValidateOnly

        Validates both JSON files then exits without deploying.

    .NOTES
        Internal helper for Start-VcfEdgeAtScale. Not intended for direct consumer use.
        Raises VcfDeploymentException on known configuration or deployment failures.

        Write-Host is the primary output mechanism in this function; all Write-Host calls are
        intentional interactive console output. Use Write-LogMessage for diagnostic logging.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $false)] [Switch]$AcceptBadCheckResults,
        [Parameter(Mandatory = $false)] [ValidateSet("All", "ArgoCD", "Compute", "Harbor", "Supervisor")] [String]$CleanUp,
        [Parameter(Mandatory = $false)] [Switch]$ComputeOnly,
        [Parameter(Mandatory = $false)] [ValidateRange(0, 300)] [Int]$DelayBeforeAddingNextHostSeconds = 0,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$DeploymentRootDirectory,
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$EdgeSite,
        [Parameter(Mandatory = $false)] [Switch]$Force,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$InfrastructureJson,
        [Parameter(Mandatory = $false)] [Nullable[Bool]]$RollbackOnFailure,
        [Parameter(Mandatory = $false)] [Switch]$SaveHarborYaml,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$SupervisorJson,
        [Parameter(Mandatory = $false)] [Switch]$ValidateOnly
    )

    # $null = prompt (Y/N/Always); $true = always rollback; $false = never rollback.
    $Script:RollbackOnFailurePreference = $RollbackOnFailure
    $Script:RollbackAlwaysFromPrompt = $false
    $Script:CleanUpOnly = $false

    # Warn if the module on disk has been updated since this session imported it.
    Invoke-VcfEdgeAtScaleModuleVersionStalenessCheck

    # Enforce VCF.PowerCLI minimum even when today's log file already existed (New-LogFile only runs Get-EnvironmentSetup on first creation).
    Initialize-ScriptVcfPowerCliModuleVersion -MinimumVcfPowerCliVersion "9.0.0"

    # Silently refresh help JSON files in Docs if the module has been upgraded since they were last copied.
    try {
        $helpTemplatesPath = Get-ModuleTemplatesPath
        $helpDocsDirectory = Join-Path -Path $DeploymentRootDirectory -ChildPath $Script:DOCS_DIR_NAME
        foreach ($helpFileName in @($Script:INFRA_HELP_FILENAME, $Script:SUPERVISOR_HELP_FILENAME)) {
            $null = Update-HelpJsonIfStale `
                -DocsPath (Join-Path -Path $helpDocsDirectory -ChildPath $helpFileName) `
                -TemplatePath (Join-Path -Path $helpTemplatesPath -ChildPath $helpFileName)
        }
    } catch {
        Write-LogMessage -Type DEBUG -Message "Help JSON auto-refresh skipped: $($_.Exception.Message)"
    }

    Write-LogMessage -Type DEBUG -Message "Log level set to: $Script:ConfiguredLogLevel (screen output filtered, all levels written to file)"

    # Perform validation with progress indication.
    Write-Host ""
    $validationStartTime = Get-Date
    $inputData = ConvertFrom-JsonSafely -JsonFilePath $InfrastructureJson
    if ($null -eq $inputData) {
        $err = "[E-CONFIG-NULL-001] Infrastructure JSON produced no data after load."
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }
    Update-InfrastructureJsonReferencedFilePaths -InfrastructureJsonPath $InfrastructureJson -InputData $inputData
    if ($EdgeSite) {
        $edgeSitesArrayForValidation = Get-EdgeSitesFromParameter -EdgeSite $EdgeSite -InputData $inputData
    } else {
        $edgeSitesArrayForValidation = @()
    }
    $siteIndication = if ($edgeSitesArrayForValidation.Count -gt 0) { "edgeSite(s) `"$($edgeSitesArrayForValidation -join '", "')`"" } else { "all sites" }

    $edgeSiteErrors = [System.Collections.Generic.List[String]]::new()
    foreach ($cluster in $inputData.clusters) {
        $siteName = [String]($cluster.edgeSite)
        if ([String]::IsNullOrWhiteSpace($siteName)) {
            $edgeSiteErrors.Add("clusters[].edgeSite: a required edgeSite name is missing or empty.")
        } elseif (-not (Test-EdgeSiteNameValid -Name $siteName)) {
            $edgeSiteErrors.Add("clusters[`"$siteName`"].edgeSite: must be 1-80 chars, lowercase letters, digits, and hyphens only; must not start or end with a hyphen.")
        }
    }
    if ($edgeSiteErrors.Count -gt 0) {
        foreach ($err in $edgeSiteErrors) {
            Write-LogMessage -Type ERROR -Message $err
        }
        throw [VcfDeploymentException]::new("One or more edgeSite names failed validation. See log for details.")
    }

    $yamlValidationParams = @{
        InputData       = $inputData
        SiteIndication  = $siteIndication
        EdgeSitesArray  = $edgeSitesArrayForValidation
    }
    if ($CleanUp) { $yamlValidationParams.CleanUp = $CleanUp }
    if ($ComputeOnly) { $yamlValidationParams.ComputeOnly = $true }
    Invoke-YamlFileExistenceValidation @yamlValidationParams

    $jsonValidationParams = @{
        InfrastructureJson  = $InfrastructureJson
        SupervisorJson      = $SupervisorJson
        InputData           = $inputData
        SiteIndication      = $siteIndication
        ValidationStartTime = $validationStartTime
    }
    if ($CleanUp) { $jsonValidationParams.CleanUp = $CleanUp }
    if ($ComputeOnly) { $jsonValidationParams.ComputeOnly = $true }
    if ($EdgeSite) { $jsonValidationParams.EdgeSite = $EdgeSite }
    Invoke-JsonConfigurationValidation @jsonValidationParams

    # When -ValidateOnly, exit after validation without deploying or cleaning up.
    if ($ValidateOnly) {
        Write-LogMessage -Type INFO -Message "ValidateOnly: validation passed. Exiting without deployment."
        return
    }

    # If -CleanUp was specified but value is null or empty, show usage and return.
    if ($PSBoundParameters.ContainsKey("CleanUp") -and [String]::IsNullOrWhiteSpace($CleanUp)) {
        Write-LogMessage -Type WARNING -Message "-CleanUp requires one of: Supervisor, Compute, All, ArgoCD, Harbor."
        Write-Host ""
        Write-Host "Usage: -CleanUp must be one of: Supervisor, Compute, All, ArgoCD, Harbor"
        Write-Host "  Supervisor - Remove only the supervisor (compute remains)."
        Write-Host "  Compute   - Remove only compute (VDS, vSAN/VMFS, cluster); fails if supervisor is deployed."
        Write-Host "  All       - Remove supervisor first, then compute."
        Write-Host "  ArgoCD    - Remove only the ArgoCD supervisor namespace for each cluster."
        Write-Host "  Harbor    - Remove only the Harbor Supervisor Service from the supervisor for each cluster."
        return
    }

    # Normalize -CleanUp to All, ArgoCD, Compute, Harbor, or Supervisor (accept lowercase).
    if (-not [String]::IsNullOrWhiteSpace($CleanUp)) {
        $cu = $CleanUp.Trim().ToLower()
        switch ($cu) {
            "all" { $CleanUp = "All" }
            "argocd" { $CleanUp = "ArgoCD" }
            "compute" { $CleanUp = "Compute" }
            "harbor" { $CleanUp = "Harbor" }
            "supervisor" { $CleanUp = "Supervisor" }
            default {
                Write-LogMessage -Type WARNING -Message "-CleanUp must be one of: Supervisor, Compute, All, ArgoCD, Harbor (got: $CleanUp)."
                Write-Host "Usage: -CleanUp must be one of: Supervisor, Compute, All, ArgoCD, Harbor"
                return
            }
        }
    }

    # Before deployment begins, resolve any Harbor $env: secrets that are not yet set.
    # This prompts the user now (masked input, once per variable) rather than mid-deployment.
    # Skipped for cleanup-only, validate-only, -ComputeOnly, or when Harbor is disabled for every cluster in scope.
    # When -ComputeOnly is set, Harbor is not deployed: operators may keep a full harborConfiguration
    # (including $env: placeholders for a later supervisor run) without defining those variables yet.
    if ($null -ne $inputData -and [String]::IsNullOrWhiteSpace($CleanUp) -and -not $ComputeOnly) {
        $clustersForHarborPreflight = if ($EdgeSite -and $null -ne $edgeSitesArrayForValidation -and $edgeSitesArrayForValidation.Count -gt 0) {
            @($inputData.clusters | Where-Object { $_.edgeSite -in $edgeSitesArrayForValidation })
        } else {
            @($inputData.clusters)
        }
        $anyHarborEnabledForPreflight = $false
        foreach ($clusterHp in $clustersForHarborPreflight) {
            if (-not (Get-EffectiveSupervisorServiceFlag -Cluster $clusterHp -CommonData $inputData.common -FlagName "disableHarbor")) {
                $anyHarborEnabledForPreflight = $true
                break
            }
        }
        if ($anyHarborEnabledForPreflight) {
            $harborPreflightParams = @{ InputData = $inputData }
            if ($EdgeSite) { $harborPreflightParams.EdgeSite = $EdgeSite }
            Invoke-HarborEnvVarPreflight @harborPreflightParams
        } else {
            Write-LogMessage -Type DEBUG -Message "Skipping Harbor environment-variable preflight (Harbor disabled for all clusters in scope)."
        }
    }

    # Initialize the edge deployment workflow. Forward explicit parameters (do not rely on
    # PowerShell dynamic scoping for AcceptBadCheckResults / DelayBeforeAddingNextHostSeconds).
    $initParams = @{
        InfrastructureJson               = $InfrastructureJson
        SupervisorJson                   = $SupervisorJson
        DelayBeforeAddingNextHostSeconds = $DelayBeforeAddingNextHostSeconds
    }
    if ($AcceptBadCheckResults) {
        $initParams.AcceptBadCheckResults = $true
    }
    if ($EdgeSite) {
        $initParams.EdgeSite = $EdgeSite
    }
    if (-not [String]::IsNullOrWhiteSpace($CleanUp)) {
        $initParams.CleanUp = $CleanUp
    }
    if ($ComputeOnly) {
        $initParams.ComputeOnly = $true
    }
    if ($Force) {
        $initParams.Force = $true
    }
    if ($SaveHarborYaml) {
        $initParams.SaveHarborYaml = $true
    }
    Initialize-VcfEdgeAtScale @initParams
}
function Invoke-VcfEdgeAtScaleVersionDisplay {

    <#
        .SYNOPSIS
        Resolves and logs the current VcfEdgeAtScale module version.

        .DESCRIPTION
        Looks up the version in the following order:
        (1) Loaded module metadata via Get-Module.
        (2) The module manifest file (.psd1) located relative to $PSScriptRoot.
        (3) The script-scope $Script:ModuleVersion fallback.
        Initializes the log file under $VcfEdgeRootDirectory when provided and the directory exists.

        .PARAMETER VcfEdgeRootDirectory
        Optional base directory under which to initialize the log file before logging the version.

        .EXAMPLE
        Invoke-VcfEdgeAtScaleVersionDisplay -VcfEdgeRootDirectory $env:VcfEdgeAtScaleRootDirectory

        .NOTES
        Does not throw. Logs the resolved version string via Write-LogMessage.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $false)] [String]$VcfEdgeRootDirectory = ""
    )

    if (-not [String]::IsNullOrWhiteSpace($VcfEdgeRootDirectory) -and (Test-Path -LiteralPath $VcfEdgeRootDirectory.Trim() -PathType Container)) {
        New-LogFile -BaseDirectory $VcfEdgeRootDirectory.Trim() -Directory $Script:LOGS_DIR_NAME
    } else {
        New-LogFile
    }

    $versionToDisplay = $null
    $loadedModule = Get-Module -Name "VcfEdgeAtScale" | Select-Object -First 1
    if ($loadedModule -and $loadedModule.Version -and $loadedModule.Version -ne [version]"0.0") {
        $versionToDisplay = $loadedModule.Version.ToString()
    } else {
        $modulePath = $null
        if ($PSScriptRoot) {
            $modulePath = $PSScriptRoot
        } else {
            $moduleInfo = Get-Module -Name "VcfEdgeAtScale" -ListAvailable | Select-Object -First 1
            if ($moduleInfo -and $moduleInfo.ModuleBase) {
                $modulePath = $moduleInfo.ModuleBase
            }
        }
        if ($modulePath) {
            $manifestPath = Join-Path -Path $modulePath -ChildPath "VcfEdgeAtScale.psd1"
            if (Test-Path $manifestPath) {
                try {
                    $manifest = Import-PowerShellDataFile -Path $manifestPath
                    if ($manifest.ModuleVersion) {
                        $versionToDisplay = $manifest.ModuleVersion.ToString()
                    }
                } catch {
                    Write-LogMessage -Type DEBUG -Message "Manifest import failed; using fallback. $($_.Exception.Message)"
                }
            }
        }
        if (-not $versionToDisplay) {
            $versionToDisplay = $Script:ModuleVersion
        }
    }
    Write-LogMessage -Type INFO -Message "VcfEdgeAtScale version: $versionToDisplay"
}
function Resolve-VcfEdgeAtScaleDeployPaths {

    <#
        .SYNOPSIS
        Resolves the deployment root directory and default JSON configuration paths from the environment.

        .DESCRIPTION
        Reads $env:VcfEdgeAtScaleRootDirectory, resolves the path, and defaults $InfrastructureJson and
        $SupervisorJson to files under that directory when the caller did not provide explicit paths.
        Returns a PSCustomObject with RootDirectory, InfrastructureJson, and SupervisorJson properties.
        Returns $null and logs a warning when VcfEdgeAtScaleRootDirectory is not set or not resolvable,
        or returns $null with an error when a required JSON path resolves to an empty string.

        .PARAMETER InfrastructureJson
        Optional explicit path to infrastructure.json. When empty, defaults to
        Join-Path($RootDirectory, "infrastructure.json").

        .PARAMETER SupervisorJson
        Optional explicit path to supervisor.json. When empty, defaults to
        Join-Path($RootDirectory, "supervisor.json").

        .EXAMPLE
        $paths = Resolve-VcfEdgeAtScaleDeployPaths -InfrastructureJson $InfrastructureJson -SupervisorJson $SupervisorJson

        .NOTES
        Returns $null on failure (caller must check and return early). Does not throw.
    #>

    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    Param (
        [Parameter(Mandatory = $false)] [String]$InfrastructureJson = "",
        [Parameter(Mandatory = $false)] [String]$SupervisorJson = ""
    )

    $vcfEdgeRootRaw = $env:VcfEdgeAtScaleRootDirectory
    if ([String]::IsNullOrWhiteSpace($vcfEdgeRootRaw)) {
        $examplePath = Join-Path -Path $HOME -ChildPath $Script:DEFAULT_DEPLOY_DIR_NAME
        Write-LogMessage -Type WARNING -Message (
            "VcfEdgeAtScaleRootDirectory is not set. Run Start-VcfEdgeAtScale -Initialize, or set it for this session. " +
            "The following is an example only (your default Initialize path is Join-Path `$HOME '$($Script:DEFAULT_DEPLOY_DIR_NAME)'; use the directory you chose at Initialize if different): " +
            "`$env:VcfEdgeAtScaleRootDirectory = `"$examplePath`""
        )
        return $null
    }

    if (-not (Test-Path -LiteralPath $vcfEdgeRootRaw.Trim())) {
        Write-LogMessage -Type ERROR -Message "VcfEdgeAtScaleRootDirectory is set but the path does not exist. Ensure the directory exists. Value: `"$vcfEdgeRootRaw`"."
        return $null
    }
    $rootDirectory = (Resolve-Path -LiteralPath $vcfEdgeRootRaw.Trim()).Path

    if ([String]::IsNullOrWhiteSpace($InfrastructureJson)) {
        $InfrastructureJson = Join-Path -Path $rootDirectory -ChildPath $Script:INFRA_JSON_FILENAME
    }
    if ([String]::IsNullOrWhiteSpace($SupervisorJson)) {
        $SupervisorJson = Join-Path -Path $rootDirectory -ChildPath $Script:SUPERVISOR_JSON_FILENAME
    }
    if ([String]::IsNullOrWhiteSpace($InfrastructureJson)) {
        Write-LogMessage -Type ERROR -Message "InfrastructureJson resolved to an empty path. Provide -InfrastructureJson or fix VcfEdgeAtScaleRootDirectory."
        return $null
    }
    if ([String]::IsNullOrWhiteSpace($SupervisorJson)) {
        Write-LogMessage -Type ERROR -Message "SupervisorJson resolved to an empty path. Provide -SupervisorJson or fix VcfEdgeAtScaleRootDirectory."
        return $null
    }
    return [PSCustomObject]@{
        RootDirectory      = $rootDirectory
        InfrastructureJson = $InfrastructureJson
        SupervisorJson     = $SupervisorJson
    }
}
function Start-VcfEdgeAtScale {

    <#
    .SYNOPSIS
        Automates end-to-end vSphere Supervisor edge deployment at scale in VMware Cloud Foundation 9.x.

    .DESCRIPTION
        Start-VcfEdgeAtScale orchestrates vSphere Supervisor cluster preparation and deployment in
        VMware Cloud Foundation (VCF) 9.x environments. The function handles the deployment workflow including:

        - vCenter and ESX host connection
        - ESX Cluster creation and host add
        - Datastore creation and storage policy configuration.
        - Virtual Distributed Switch (VDS) setup and port group configuration
        - vSphere Supervisor Deployment
        - ArgoCD installation and configuration for GitOps workflows

        For normal runs (not -Version or -Initialize), the environment variable VcfEdgeAtScaleRootDirectory must
        point at your configuration base directory. Defaults for -InfrastructureJson and -SupervisorJson join that
        directory with infrastructure.json and supervisor.json when you omit those parameters. Logs are written
        under Join-Path(VcfEdgeAtScaleRootDirectory, "Logs"). Use Start-VcfEdgeAtScale -Initialize to create or
        refresh the recommended layout from module Templates (new or existing base directory; use
        -Initialize -InitializeTemplatesOnly to refresh only ServicesYaml and Docs without changing root JSON).
        Use Start-VcfEdgeAtScale -CollectLogs to zip infrastructure.json, supervisor.json, Logs, and ServicesYaml for support (interactive prompts).

    .PARAMETER InfrastructureJson
        Path to the infrastructure configuration JSON file.

        When omitted, the path is Join-Path($env:VcfEdgeAtScaleRootDirectory, "infrastructure.json").

        Supervisor service YAML files and Harbor TLS PEM files are referenced by
        supervisorServices.parentDirectory plus file name properties (and harborConfiguration.parentDirectory
        plus tlsCrt, tlsKey, caCrt file names). Combined paths are normalized with
        Resolve-InfrastructureReferencedFilePath (current directory and the infrastructure JSON directory).

    .PARAMETER SupervisorJson
        Path to the Supervisor Cluster configuration JSON file.

        When omitted, the path is Join-Path($env:VcfEdgeAtScaleRootDirectory, "supervisor.json").

    .PARAMETER LogLevel
        Sets the minimum log level for console output.

        Default: "INFO"

    .PARAMETER ValidateOnly
        When specified, runs full JSON and YAML validation (shallow, deeper, network segment uniqueness) then exits without connecting to vCenter or deploying. Use to validate configuration files before deployment.

    .PARAMETER CheckForUpdates
        Checks PSGallery for a newer version of VcfEdgeAtScale and optionally installs it. Exits without deploying.
        The check is skipped when the module was not installed from PSGallery. Respects common.autoUpdate false when
        an InfrastructureJson is provided.

    .PARAMETER Version
        Displays the module version and exits without performing deployment.

    .PARAMETER EdgeSite
        Optional comma-delimited list of edge site identifiers (e.g. "site1,site2"). If provided, only clusters
        with matching edgeSite values are deployed, in the order specified. If omitted, all clusters in the
        infrastructure JSON are deployed sequentially. Only comma is allowed as separator; invalid delimiters
        (e.g. semicolon) or unknown site names cause the workflow to fail.

    .PARAMETER AcceptBadCheckResults
        When specified, automatically proceed when vSAN cluster health is red or when vLCM cluster compliance remediation fails (no Y/N prompts).

    .PARAMETER CleanUp
        Optional. When specified, the script authenticates to vCenter, performs cleanup per scope, then exits without deploying. Must be one of: Supervisor, Compute, All, ArgoCD, Harbor. Supervisor = disable supervisor only (compute remains). Compute = remove only compute (VDS, vSAN/VMFS, cluster); fails if supervisor is deployed. All = disable supervisor first, then remove compute. ArgoCD = remove only the ArgoCD supervisor namespace for each cluster. Harbor = remove only the Harbor Supervisor Service from the supervisor for each cluster. Confirmation requires typing exactly "delete <scope> for <edgeSite>" unless -Force is used with common.labenvironment true in infrastructure JSON.

    .PARAMETER CollectLogs
        Interactive support bundle. Prompts whether to use infrastructure.json and supervisor.json under the deployment root (from VcfEdgeAtScaleRootDirectory, or a prompted path if unset), or custom full paths. Includes those files plus the Logs and ServicesYaml folders under that deployment root in Join-Path($HOME, "VcfEdgeAtScale-logs-<timestamp>.zip"). Does not deploy. Do not combine with -Initialize, -InitializeTemplatesOnly, or -Version.

    .PARAMETER ComputeOnly
        When specified, the script runs all pre-supervisor steps (clusters, hosts, storage, VDS, vLCM compliance/remediation) then exits without enabling the supervisor or deploying Argo CD or Harbor. Use to prepare compute and storage only. Does not conflict with -CleanUp (deployment scope vs cleanup scope). Harbor $env: preflight is not run: clusters may still define harborConfiguration (for example for a later full deploy) without setting HARBOR_ADMIN_PASSWORD and other variables referenced there.

    .PARAMETER DelayBeforeAddingNextHostSeconds
        Seconds to wait before adding the 2nd, 3rd, etc. host to a cluster. Default is 0 (Add-HostToCluster now waits for the host add task to complete, so a fixed delay is usually unnecessary). Set greater than 0 only if you need extra settling time.

    .PARAMETER Force
        When common.labenvironment is true in infrastructure JSON and -Force is set, bypasses the cleanup confirmation prompt (user does not need to type "delete <scope> for <edgeSite>"). Has no effect when labEnvironment is false; a warning is displayed if -Force is used in that case.

    .PARAMETER Initialize
        Interactive setup: prompts for a base directory (default ~/VCFEdgeAtScale), creates Docs, Logs, and ServicesYaml
        when missing, copies module YAML and documentation into ServicesYaml and Docs (overwrite prompts; default N).
        Seeds or optionally replaces infrastructure.json and supervisor.json from Templates (see -InitializeTemplatesOnly).
        When VcfEdgeAtScaleRootDirectory resolves to a fully initialized layout (Docs, Logs, ServicesYaml, root JSON, all
        shipped YAML files under ServicesYaml), asks whether to initialize a different directory; answering N reuses that path without re-typing it.
        Section output uses console colors. Sets VcfEdgeAtScaleRootDirectory for the current session. On
        Windows, persists it via [System.Environment]::SetEnvironmentVariable (User scope) and also appends
        to $PROFILE so sessions not spawned by Explorer (SSH, some terminal emulators) inherit it reliably.
        On macOS/Linux, appends the export line to $PROFILE. Prints a fallback manual command if the
        Windows registry persist step fails. Other switches are ignored except -LogLevel and -InitializeTemplatesOnly.

    .PARAMETER InitializeTemplatesOnly
        Use only with -Initialize. Refreshes Supervisor service YAML and Docs files from Templates without creating or
        replacing infrastructure.json or supervisor.json in the base directory. Use on an existing configuration root
        to update shipped YAML or help copies without touching JSON.

    .PARAMETER RollbackOnFailure
        Boolean. When $true: always rollback on failure (no prompt; for autonomous runs). When $false: never rollback; leave site in current state and continue to next site if any. When omitted: prompt with Yes/No/Always. Use $true or $false to bypass the prompt for unattended execution.

        For normal retries after a failure, prefer rolling back (Y, Always, or -RollbackOnFailure $true)
        so the environment returns to a known state before you fix configuration and re-run. Use
        -RollbackOnFailure $false or answer N only when you intentionally leave the site partially
        deployed for hands-on debugging in vCenter or kubectl. After you finish debugging, run the
        matching scoped cleanup (for example Start-VcfEdgeAtScale -CleanUp Harbor -EdgeSite
        <site>) or choose rollback at the next prompt so the next deployment does not stack on a
        broken half-state.

    .PARAMETER SaveHarborYaml
        When specified, the completed Harbor data values YAML file is moved into a "HarborYaml" subdirectory under the module directory instead of being deleted. The directory is created automatically if it does not exist; if it cannot be created, deployment exits with an error before Harbor installation begins. The saved file matches the final rendered values used for installation; the deployment log includes a redacted copy. When omitted, the temporary file is deleted after successful installation.

    .EXAMPLE
        Start-VcfEdgeAtScale -Initialize

        Runs interactive setup to create the configuration directory layout, copy templates, and print VcfEdgeAtScaleRootDirectory profile instructions.

    .EXAMPLE
        Start-VcfEdgeAtScale -Initialize -InitializeTemplatesOnly

        Refreshes YAML and Docs from the module into an existing (or new) base directory without changing root JSON files.

    .EXAMPLE
        Start-VcfEdgeAtScale -CollectLogs

        Prompts for JSON sources and zips deployment files, Logs, and ServicesYaml to the user home directory.

    .EXAMPLE
        Start-VcfEdgeAtScale

        Executes the deployment using infrastructure.json and supervisor.json under $env:VcfEdgeAtScaleRootDirectory when those parameters are omitted.

    .EXAMPLE
        Start-VcfEdgeAtScale -InfrastructureJson "config/site-a-infrastructure.json" -SupervisorJson "config/site-a-supervisor.json"

        Executes the deployment using custom configuration files for all clusters.

    .EXAMPLE
        Start-VcfEdgeAtScale -EdgeSite "site1"

        Executes the deployment for only the cluster with edgeSite "site1".

    .EXAMPLE
        Start-VcfEdgeAtScale -EdgeSite "site1,site2"

        Executes the deployment for the clusters with edgeSite "site1" and "site2", in that order.

    .EXAMPLE
        Start-VcfEdgeAtScale -Version

        Displays the module version and exits.

    .EXAMPLE
        Start-VcfEdgeAtScale -CleanUp All

        Authenticates to vCenter, disables supervisor then removes compute (VDS, vSAN/VMFS, cluster) for each site, then exits. User must type "delete all for <edgeSite>" to confirm (or use -Force with labEnvironment true).

    .EXAMPLE
        Start-VcfEdgeAtScale -CleanUp Supervisor -EdgeSite site1

        Removes only the supervisor for site1; compute remains. User must type "delete supervisor for site1" to confirm.

    .EXAMPLE
        Start-VcfEdgeAtScale -ComputeOnly

        Runs clusters, hosts, storage, VDS, and vLCM remediation for each cluster, then exits without enabling supervisor.

    .EXAMPLE
        Start-VcfEdgeAtScale -RollbackOnFailure $true

        Autonomous run: always rollback on failure without prompting.

    .EXAMPLE
        Start-VcfEdgeAtScale -ValidateOnly -InfrastructureJson "infrastructure.json" -SupervisorJson "supervisor.json"

        Validates both JSON files and YAML paths then exits without deploying.

    .EXAMPLE
        Start-VcfEdgeAtScale -SaveHarborYaml

        Deploys all clusters; after Harbor installation the completed data values YAML is moved to the "HarborYaml" subdirectory instead of being deleted.

    .EXAMPLE
        Start-VcfEdgeAtScale -CheckForUpdates

        Checks PSGallery for a newer version of VcfEdgeAtScale and prompts to install if one is found.

        .NOTES
        Write-Host is the primary output mechanism in this function; all Write-Host calls are
        intentional interactive console output. Use Write-LogMessage for diagnostic logging.
    #>

    [CmdletBinding(DefaultParameterSetName = "Deploy")]
    Param (
        # --- Deploy (default) ---
        [Parameter(ParameterSetName = "Deploy")] [Switch]$AcceptBadCheckResults,
        [Parameter(ParameterSetName = "CheckForUpdates", Mandatory = $true)] [Switch]$CheckForUpdates,
        [Parameter(ParameterSetName = "CleanUp", Mandatory = $true)] [ValidateSet("All", "ArgoCD", "Compute", "Harbor", "Supervisor")] [String]$CleanUp,
        [Parameter(ParameterSetName = "CollectLogs", Mandatory = $true)] [Switch]$CollectLogs,
        [Parameter(ParameterSetName = "Deploy")] [Switch]$ComputeOnly,
        [Parameter(ParameterSetName = "Deploy")] [ValidateRange(0, 300)] [Int]$DelayBeforeAddingNextHostSeconds = 0,
        [Parameter(ParameterSetName = "Deploy")] [Parameter(ParameterSetName = "CleanUp")] [ValidateNotNullOrEmpty()] [String]$EdgeSite,
        [Parameter(ParameterSetName = "CleanUp")] [Switch]$Force,
        [Parameter(ParameterSetName = "Deploy")] [Parameter(ParameterSetName = "CleanUp")] [Parameter(ParameterSetName = "CheckForUpdates")] [String]$InfrastructureJson,
        [Parameter(ParameterSetName = "Initialize", Mandatory = $true)] [Switch]$Initialize,
        [Parameter(ParameterSetName = "Initialize")] [Switch]$InitializeTemplatesOnly,
        [Parameter()] [ValidateSet("DEBUG", "INFO", "ADVISORY", "WARNING", "EXCEPTION", "ERROR")] [String]$LogLevel = "INFO",
        [Parameter(ParameterSetName = "Deploy")] [Nullable[bool]]$RollbackOnFailure,
        [Parameter(ParameterSetName = "Deploy")] [Switch]$SaveHarborYaml,
        [Parameter(ParameterSetName = "Deploy")] [Parameter(ParameterSetName = "CleanUp")] [String]$SupervisorJson,
        [Parameter(ParameterSetName = "Deploy")] [Switch]$ValidateOnly,
        [Parameter(ParameterSetName = "Version", Mandatory = $true)] [Switch]$Version
    )

    # Initialize configured log level from parameter (normalize to uppercase). Set before -Version so Write-LogMessage honors the threshold.
    $Script:ConfiguredLogLevel = $LogLevel.ToUpper()

    if ($Initialize) {
        $initBaseDirectory = Invoke-VcfEdgeAtScaleModuleInitialize -TemplatesOnly:$InitializeTemplatesOnly
        # $null return means an error was already logged by the callee; exit without showing next-step hints.
        if ([String]::IsNullOrWhiteSpace($initBaseDirectory) -or -not (Test-Path -LiteralPath $initBaseDirectory -PathType Container)) {
            return
        }

        New-LogFile -BaseDirectory $initBaseDirectory -Directory $Script:LOGS_DIR_NAME

        # Print next-step hints for customizing JSON; direct editing first, browser UI second.
        $pyExe = (Get-PythonExecutable)?.Executable ?? "python3"
        Write-Host ""
        Write-Host "  Next step: customize infrastructure.json and supervisor.json." -ForegroundColor Cyan
        Write-Host "  Option 1 — Direct JSON editing:" -ForegroundColor White
        Write-Host "    Open infrastructure.json and supervisor.json in any text editor." -ForegroundColor Gray
        Write-Host "    Run 'Start-VcfEdgeAtScale -ValidateOnly' to validate before deploying." -ForegroundColor Gray
        $toolScript = Join-Path -Path (Join-Path -Path $initBaseDirectory -ChildPath $Script:TOOLS_DIR_NAME) -ChildPath "veas-json-generator.py"
        Write-Host "  Option 2 — Browser-based UI:" -ForegroundColor White
        if (Test-Path -LiteralPath $toolScript) {
            Write-Host "    $pyExe `"$toolScript`"" -ForegroundColor Gray
        } else {
            Write-Host "    $pyExe `"<base-dir>\Tools\veas-json-generator.py`"" -ForegroundColor Gray
        }

        return
    }

    if ($CollectLogs) {
        $null = Invoke-VcfEdgeAtScaleCollectLogs
        return
    }

    if ($Version) {
        Invoke-VcfEdgeAtScaleVersionDisplay -VcfEdgeRootDirectory $env:VcfEdgeAtScaleRootDirectory
        return
    }

    if ($CheckForUpdates) {
        $checkLogBase = $env:VcfEdgeAtScaleRootDirectory
        if (-not [String]::IsNullOrWhiteSpace($checkLogBase) -and (Test-Path -LiteralPath $checkLogBase.Trim() -PathType Container)) {
            New-LogFile -BaseDirectory $checkLogBase.Trim() -Directory $Script:LOGS_DIR_NAME
        } else {
            New-LogFile
        }
        # Parse infrastructure JSON if provided so common.autoUpdate is respected during a manual check.
        $checkInputData = $null
        if (-not [String]::IsNullOrWhiteSpace($InfrastructureJson) -and (Test-Path -LiteralPath $InfrastructureJson)) {
            try {
                $checkInputData = ConvertFrom-JsonSafely -JsonFilePath $InfrastructureJson
            } catch {
                Write-LogMessage -Type DEBUG -Message "Could not parse InfrastructureJson for update check; proceeding without autoUpdate override. $($_.Exception.Message)"
            }
        }
        Invoke-VcfEdgeAtScaleUpdateCheck -InputData $checkInputData
        return
    }

    $deployPaths = Resolve-VcfEdgeAtScaleDeployPaths -InfrastructureJson $InfrastructureJson -SupervisorJson $SupervisorJson
    if (-not $deployPaths) {
        return
    }
    $vcfEdgeRootDirectory = $deployPaths.RootDirectory
    $InfrastructureJson   = $deployPaths.InfrastructureJson
    $SupervisorJson       = $deployPaths.SupervisorJson

    New-LogFile -BaseDirectory $vcfEdgeRootDirectory -Directory $Script:LOGS_DIR_NAME

    $savedProgressPreference = $Global:ProgressPreference
    try {
        $Global:ProgressPreference = "Continue"

        $deployParams = @{
            DeploymentRootDirectory          = $vcfEdgeRootDirectory
            InfrastructureJson               = $InfrastructureJson
            SupervisorJson                   = $SupervisorJson
            DelayBeforeAddingNextHostSeconds = $DelayBeforeAddingNextHostSeconds
        }
        if ($AcceptBadCheckResults) {
            $deployParams.AcceptBadCheckResults = $true
        }
        if ($EdgeSite) {
            $deployParams.EdgeSite = $EdgeSite
        }
        if ($PSBoundParameters.ContainsKey("CleanUp")) {
            $deployParams.CleanUp = $CleanUp
        }
        if ($ComputeOnly) {
            $deployParams.ComputeOnly = $true
        }
        if ($Force) {
            $deployParams.Force = $true
        }
        if ($PSBoundParameters.ContainsKey("RollbackOnFailure")) {
            $deployParams.RollbackOnFailure = $RollbackOnFailure
        }
        if ($SaveHarborYaml) {
            $deployParams.SaveHarborYaml = $true
        }
        if ($ValidateOnly) {
            $deployParams.ValidateOnly = $true
        }

        Invoke-VcfEdgeAtScaleSiteDeployment @deployParams
    } catch [VcfDeploymentException] {
        # Known deployment failure — already surfaced to the user via Write-LogMessage -Type ERROR.
        # Show the friendly footer; no further output needed since the error was already logged.
        Write-VcfDeploymentFailureFooter
    } catch {
        # Unexpected exception — not previously logged. Log the full exception to the file for
        # debugging and show a clean message on screen; do not rethrow to avoid ugly stack traces.
        Write-LogMessage -Type ERROR -SuppressOutputToScreen -Message "Unexpected error: $($_.Exception.ToString())"
        Write-LogMessage -Type ERROR -Message "An unexpected error occurred: $($_.Exception.Message). Check the log file for full details."
        Write-VcfDeploymentFailureFooter
    } finally {
        $Global:ProgressPreference = $savedProgressPreference
    }
}
function Show-VcfEdgeAtScaleVersion {

    <#
    .SYNOPSIS
        Displays the version information for the VcfEdgeAtScale module.

    .DESCRIPTION
        Shows the current version of the VcfEdgeAtScale module.

    .EXAMPLE
        Show-VcfEdgeAtScaleVersion

        Displays the current module version, e.g. "VcfEdgeAtScale version: 1.0.3.1000".
    #>

    [CmdletBinding()]
    Param ()

    Write-LogMessage -Type INFO -Message "VcfEdgeAtScale version: $Script:ModuleVersion"
}
function Get-ModuleTemplatesPath {

    <#
        .SYNOPSIS
        Resolves the full path to the module's Templates directory.

        .DESCRIPTION
        Returns the path to the VcfEdgeAtScale Templates directory containing bundled JSON, YAML, RTF
        (EXAMPLE.rtf, README.rtf), and *-config-help.json files used by deployment and Start-VcfEdgeAtScale -Initialize. Uses
        Module.ModuleBase when available, then PSScriptRoot (with VcfEdgeAtScale subdirectory
        fallback for development), then Get-Module -ListAvailable. Throws if the Templates directory
        does not exist.

        .OUTPUTS
        String. Full path to the Templates directory.

        .EXAMPLE
        $templatesPath = Get-ModuleTemplatesPath
        $jsonPath = Join-Path $templatesPath "infrastructure.json"

        .NOTES
        Used by Invoke-VcfEdgeAtScaleModuleInitialize. Requires Write-LogMessage for error logging.
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param ()

    [CmdletBinding()]
    $moduleBase = $null
    if ($MyInvocation.MyCommand.Module.ModuleBase) {
        $moduleBase = $MyInvocation.MyCommand.Module.ModuleBase
    } elseif ($PSScriptRoot) {
        $moduleBase = $PSScriptRoot
        $templatesCheck = Join-Path -Path $moduleBase -ChildPath "Templates"
        if (-not (Test-Path $templatesCheck)) {
            $subDirCheck = Join-Path -Path $moduleBase -ChildPath (Join-Path -Path "VcfEdgeAtScale" -ChildPath "Templates")
            if (Test-Path $subDirCheck) {
                $moduleBase = Join-Path -Path $moduleBase -ChildPath "VcfEdgeAtScale"
            }
        }
    } else {
        $moduleInfo = Get-Module -Name "VcfEdgeAtScale" -ListAvailable | Select-Object -First 1
        if ($moduleInfo -and $moduleInfo.ModuleBase) {
            $moduleBase = $moduleInfo.ModuleBase
        }
    }

    if (-not $moduleBase) {
        $err = "Unable to determine module installation path. Please ensure the module is installed correctly."
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }

    $templatesPath = Join-Path -Path $moduleBase -ChildPath "Templates"
    if (-not (Test-Path $templatesPath)) {
        $err = "Templates directory not found at: $templatesPath."
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }

    return $templatesPath
}
function Format-ConfigurationTable {

    <#
        .SYNOPSIS

        Formats configuration data as a table.

        .DESCRIPTION
        Internal helper function that formats an array of configuration objects as a table.

        .PARAMETER InputObject
        Array of PSCustomObject configuration items to format.
    
        .EXAMPLE
        Format-ConfigurationTable -InputObject $resourceObject
    #>

    [CmdletBinding()]

    Param (
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)] [PSCustomObject[]]$InputObject
    )

    Begin {
        $allItems = [System.Collections.Generic.List[PSCustomObject]]::new()
        $seenKeys = @{}
    }

    Process {
        # Handle both single objects and arrays.

        if ($null -ne $InputObject) {
            if ($InputObject -is [Array]) {
                foreach ($item in $InputObject) {
                    if ($null -ne $item -and $null -ne $item.Key) {
                        $key = $item.Key
                        if (-not $seenKeys.ContainsKey($key)) {
                            $seenKeys[$key] = $true
                            $allItems.Add($item)
                        }
                    }
                }
            } else {
                if ($null -ne $InputObject.Key) {
                    $key = $InputObject.Key
                    if (-not $seenKeys.ContainsKey($key)) {
                        $seenKeys[$key] = $true
                        $allItems.Add($InputObject)
                    }
                }
            }
        }
    }

    End {
        if ($allItems.Count -eq 0) {
            return
        }

        # Write-Host: blank line and table output use Write-Host so the interactive table renders correctly; Write-Output can introduce rendering regression.
        $allItems | Format-Table -Property 'Key', 'Required', 'Notes' -AutoSize -Wrap | Out-Host
    }
}
function Get-ModulePublicVersion {

    <#
        .SYNOPSIS
        Returns the 3-part public release version from the module version string.

        .DESCRIPTION
        The module uses a 4-part version scheme: Major.Minor.Patch.Build (e.g. 1.0.3.1000).
        The 3-part public release is Major.Minor.Patch (e.g. 1.0.3), which is what the
        help JSON files store in their moduleVersion field and what the PowerShell Gallery
        displays as the package version. Build numbers (the 4th part) are internal pre-release
        identifiers; stripping them allows upgrading from 1.0.3.1000 to 1.0.3.1001 without
        triggering a help-file re-copy, and maps cleanly to the Gallery's 3-part SemVer expectation.

        .OUTPUTS
        String. The 3-part public version (e.g. "1.0.3"), or the full version string if it
        has fewer than 4 parts.

        .NOTES
        Reads $Script:ModuleVersion. Does not throw; returns the raw value on any parse error.
    
        .EXAMPLE
        $modulePublicVersion = Get-ModulePublicVersion
        if ($null -eq $modulePublicVersion) {
            Write-LogMessage -Type ERROR -Message "Get-ModulePublicVersion: result not found."
        }
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param ()

    $parts = $Script:ModuleVersion -split '\.'
    if ($parts.Count -ge 4) {
        # Strip the 4th (build) segment; return Major.Minor.Patch.
        return ($parts[0..2] -join '.')
    }
    return $Script:ModuleVersion
}
function Update-HelpJsonIfStale {

    <#
        .SYNOPSIS
        Silently copies a help JSON file from the module Templates directory to the user's Docs directory when the version differs or the file is missing.

        .DESCRIPTION
        Reads the moduleVersion field from both the Templates (source-of-truth) and Docs (user) copies of a help JSON file.
        Help JSON files store the 3-part public release version (e.g. "1.0.3"), not the full 4-part module version.
        This means build-number upgrades (e.g. 1.0.3.1000 to 1.0.3.1001) do not trigger a re-copy; only a new
        public release (e.g. 1.0.4) does. If the Docs copy is absent or has a different moduleVersion than the
        Templates copy, the Templates copy is silently written over the Docs copy. Does not throw on failure; logs a Warning instead.

        .PARAMETER DocsPath
        Full path to the destination file in the user's Docs directory.

        .PARAMETER TemplatePath
        Full path to the source file in the module Templates directory.

        .OUTPUTS
        [Boolean] $true when the file was copied (updated or first-time); $false when the Docs copy was already current or on failure.

        .NOTES
        Help JSON files are not user-edited, so silent replacement is safe. Called from Invoke-VcfEdgeAtScaleModuleInitialize and Start-VcfEdgeAtScale.
    
        .EXAMPLE
        Update-HelpJsonIfStale -DocsPath "config.json" -TemplatePath "config.json"
    #>
    [CmdletBinding()]
    [OutputType([Boolean])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$DocsPath,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$TemplatePath
    )

    if (-not (Test-Path -LiteralPath $TemplatePath -PathType Leaf)) {
        Write-LogMessage -Type WARNING -Message "Help JSON template not found at '$TemplatePath'. Skipping auto-refresh for '$DocsPath'."
        return $false
    }

    # Read the template version as the authoritative source.
    $templateVersion = $null
    try {
        $templateJson = ConvertFrom-JsonSafely -JsonFilePath $TemplatePath
        $templateVersion = if ($templateJson -is [Array]) { $null } else { $templateJson.moduleVersion }
    } catch {
        Write-LogMessage -Type WARNING -Message "Could not read template help JSON at '$TemplatePath': $($_.Exception.Message). Skipping auto-refresh."
        return $false
    }

    # If the template has no moduleVersion field it cannot be compared reliably; always copy so
    # the Docs directory is refreshed rather than silently left with a potentially stale version.
    # Use the module's own public version as the display label in that case.
    $versionLabel = if ([String]::IsNullOrWhiteSpace($templateVersion)) {
        Write-LogMessage -Type DEBUG -Message "Help JSON template at '$TemplatePath' has no moduleVersion field; forcing copy to Docs."
        Get-ModulePublicVersion
    } else {
        $templateVersion
    }

    # Determine whether the Docs copy is current.
    $needsCopy = $true
    if (-not [String]::IsNullOrWhiteSpace($templateVersion) -and (Test-Path -LiteralPath $DocsPath -PathType Leaf)) {
        try {
            $docsJson = ConvertFrom-JsonSafely -JsonFilePath $DocsPath
            $docsVersion = if ($docsJson -is [Array]) { $null } else { $docsJson.moduleVersion }
            if ($docsVersion -eq $templateVersion) {
                $needsCopy = $false
            }
        } catch {
            # Unreadable Docs copy; replace it.
            $needsCopy = $true
        }
    }

    if (-not $needsCopy) {
        Write-LogMessage -Type DEBUG -Message "Help JSON '$([System.IO.Path]::GetFileName($DocsPath))' is current (v$versionLabel). No update needed."
        return $false
    }

    try {
        Copy-Item -LiteralPath $TemplatePath -Destination $DocsPath -Force -ErrorAction Stop
        Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "Help JSON '$([System.IO.Path]::GetFileName($DocsPath))' updated to module v$versionLabel."
        return $true
    } catch {
        Write-LogMessage -Type WARNING -Message "Could not update help JSON at '$DocsPath': $($_.Exception.Message)."
        return $false
    }
}
function Build-HelpConfigEntries {

    <#
    .SYNOPSIS
        Validates a help JSON entries array and returns an array of PSCustomObject config rows.
    .DESCRIPTION
        Validates that EntriesArray is a non-empty array, that each entry has Key, Required, and
        Notes, then constructs and returns the trimmed config array. Applies Filter as a wildcard on
        Key when provided. Returns $null on any validation failure (warning is logged before return).
    .PARAMETER EntriesArray
        The raw entries array from the help JSON (either the top-level array or jsonData.entries).
    .PARAMETER Filter
        Optional Key wildcard filter. Wrapped in * on both sides (e.g. "argoCD" -> *argoCD*).
    .PARAMETER HelpJsonPath
        Path to the help JSON file, used in warning messages.
    .EXAMPLE
        $config = Build-HelpConfigEntries -EntriesArray $jsonData.entries -Filter "harbor" -HelpJsonPath "infrastructure-config-help.json"
    .NOTES
        Returns $null on any failure; the caller should treat $null as a graceful no-result.
    #>

    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    Param (
        [Parameter(Mandatory = $true)] [AllowNull()] [AllowEmptyCollection()] $EntriesArray,
        [Parameter(Mandatory = $false)] [AllowNull()] [String]$Filter,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$HelpJsonPath
    )

    if ($null -eq $EntriesArray -or $EntriesArray -isnot [Array]) {
        Write-LogMessage -Type WARNING -Message "Configuration help file at '$HelpJsonPath' must contain an array of configuration elements (or an object with an 'entries' array)."
        return $null
    }
    if ($EntriesArray.Count -eq 0) {
        Write-LogMessage -Type WARNING -Message "Configuration help file at '$HelpJsonPath' contains no configuration elements."
        return $null
    }

    $requiredFields = @('Key', 'Required', 'Notes')
    $config = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($entry in $EntriesArray) {
        $missingFields = @($requiredFields | Where-Object { -not $entry.PSObject.Properties[$_] -or [String]::IsNullOrWhiteSpace($entry.$_) })
        if ($missingFields.Count -gt 0) {
            Write-LogMessage -Type WARNING -Message "Configuration help file at '$HelpJsonPath' contains entries missing required fields: $($missingFields -join ', '). Each entry must have: Key, Required, Notes."
            return $null
        }
        $config.Add([PSCustomObject]@{ Key = $entry.Key; Required = $entry.Required; Notes = $entry.Notes })
    }

    if ($Filter) {
        $config = @($config | Where-Object { $_.Key -like "*$Filter*" })
        if ($config.Count -eq 0) {
            Write-LogMessage -Type WARNING -Message "No configuration elements found matching filter: $Filter"
            return $null
        }
    }

    return $config
}
function Get-ConfigurationHelpData {

    <#
        .SYNOPSIS
        Loads and validates a configuration help JSON file from the deployment Docs directory or module Templates directory.

        .DESCRIPTION
        When $env:VcfEdgeAtScaleRootDirectory is set and Join-Path(Docs, HelpFileName) exists under that root, that file is loaded first so operators can refresh help JSON beside their deployment files. Otherwise the module Templates path is used. The function validates array structure and required fields (Key, Required, Notes), optionally filters by Key wildcard, and returns an array of PSCustomObject. Returns $null on any failure (path, file missing, invalid JSON, validation). Used by Show-InfrastructureJsonConfigurationHelp and Show-SupervisorJsonConfigurationHelp.

        .PARAMETER HelpFileName
        Name of the help JSON file (e.g. "infrastructure-config-help.json", "supervisor-config-help.json").

        .PARAMETER Filter
        Optional wildcard filter applied to Key. Filter is wrapped with * on both sides (e.g. "argoCD" matches *argoCD*).

        .OUTPUTS
        PSCustomObject[]. Array of configuration help entries, or $null on failure.

        .NOTES
        Uses Get-ModuleTemplatesPath; on failure writes Warning and returns $null. Does not throw.
    
        .EXAMPLE
        $configurationHelpData = Get-ConfigurationHelpData -HelpFileName "config.json"
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    Param (
        [Parameter(Mandatory = $false)] [AllowNull()] [String]$Filter,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$HelpFileName
    )

    try {
        $templatesPath = Get-ModuleTemplatesPath
    } catch {
        Write-LogMessage -Type WARNING -Message "Unable to locate module Templates directory. Please ensure the module is installed correctly."
        return $null
    }

    $templateHelpJsonPath = Join-Path -Path $templatesPath -ChildPath $HelpFileName
    $helpJsonPath = $null
    $vcfEdgeRootForHelp = $env:VcfEdgeAtScaleRootDirectory
    if (-not [String]::IsNullOrWhiteSpace($vcfEdgeRootForHelp)) {
        $docsHelpCandidatePath = Join-Path -Path $vcfEdgeRootForHelp.Trim() -ChildPath (Join-Path -Path $Script:DOCS_DIR_NAME -ChildPath $HelpFileName)
        if (Test-Path -LiteralPath $docsHelpCandidatePath -PathType Leaf) {
            $resolvedDocsPath = (Resolve-Path -LiteralPath $docsHelpCandidatePath).Path

            # Check whether the Docs copy is current; if version differs, fall through to Templates.
            # Compare against the 3-part public version (strips the 4th build segment) so that
            # build upgrades (e.g. 1.0.3.1000 → 1.0.3.1001) do not invalidate the Docs copy.
            $docsVersionMatches = $false
            try {
                $docsRaw = ConvertFrom-JsonSafely -JsonFilePath $resolvedDocsPath
                $docsVersion = if ($docsRaw -is [Array]) { $null } else { $docsRaw.moduleVersion }
                $docsVersionMatches = ($docsVersion -eq (Get-ModulePublicVersion))
            } catch {
                $docsVersionMatches = $false
            }

            if ($docsVersionMatches) {
                $helpJsonPath = $resolvedDocsPath
            } else {
                Write-LogMessage -Type INFO -Message "Help file '$HelpFileName' in Docs is from a different module version; using bundled Templates copy."
            }
        }
    }

    if ([String]::IsNullOrWhiteSpace($helpJsonPath)) {
        $helpJsonPath = $templateHelpJsonPath
    }
    if (-not (Test-Path $helpJsonPath)) {
        Write-LogMessage -Type WARNING -Message "Configuration help file not found at: $helpJsonPath. Please verify the module installation."
        return $null
    }

    if (-not (Test-JsonFile -JsonFilePath $helpJsonPath)) {
        Write-LogMessage -Type WARNING -Message "Configuration help file at '$helpJsonPath' contains invalid JSON or cannot be read. Please verify the file exists and contains valid JSON."
        return $null
    }

    try {
        $jsonData = ConvertFrom-JsonSafely -JsonFilePath $helpJsonPath
    } catch {
        Write-LogMessage -Type WARNING -Message "Failed to parse configuration help file at '$helpJsonPath': $($_.Exception.Message). Please verify the file contains valid JSON."
        return $null
    }

    if ($null -eq $jsonData) {
        Write-LogMessage -Type WARNING -Message "Configuration help file at '$helpJsonPath' parsed but returned null. File may be empty or malformed."
        return $null
    }

    # Support both legacy bare-array format and wrapped { moduleVersion, entries } format.
    $entriesArray = if ($jsonData -is [Array]) { $jsonData } else { $jsonData.entries }
    return Build-HelpConfigEntries -EntriesArray $entriesArray -Filter $Filter -HelpJsonPath $helpJsonPath
}
function Show-ConfigurationHelpTable {

    <#
        .SYNOPSIS
        Displays a configuration help array with a title and format (List, Table, or GridView).

        .DESCRIPTION
        Writes a header (title with separator), resolves Auto format from terminal width vs WidthThreshold, then outputs
        the config array as List, Table (via Format-ConfigurationTable), or GridView. Used by Show-InfrastructureJsonConfigurationHelp
        and Show-SupervisorJsonConfigurationHelp after Get-ConfigurationHelpData.

        .PARAMETER Title
        Title string for the header (e.g. "Infrastructure.json Configuration Reference").

        .PARAMETER Config
        Array of PSCustomObject with Key, Required, Notes.

        .PARAMETER Format
        Output format: Auto (resolve from width), List, Table, or GridView.

        .PARAMETER WidthThreshold
        When Format is Auto, use List if terminal width &lt; this value, else Table. Default 120.

        .NOTES
        Does not throw. On Table format failure, falls back to List.
        Write-Host is the primary output mechanism in this function; all Write-Host calls are
        intentional interactive console output. Use Write-LogMessage for diagnostic logging.
    
        .EXAMPLE
        Show-ConfigurationHelpTable -Config "value" -Format "value" -Title "value"
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [AllowNull()] [AllowEmptyCollection()] [Object[]]$Config,
        [Parameter(Mandatory = $true)] [ValidateSet('Auto', 'GridView', 'List', 'Table')] [String]$Format,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Title,
        [Parameter(Mandatory = $false)] [ValidateRange(40, [Int]::MaxValue)] [Int]$WidthThreshold = 120
    )

    if (-not $Config -or $Config.Count -eq 0) {
        return
    }

    $terminalWidth = if ($Host.UI.RawUI.BufferSize.Width -gt 0) { $Host.UI.RawUI.BufferSize.Width } else { $WidthThreshold }
    $lineWidth = [Math]::Min($terminalWidth, $WidthThreshold)

    $resolvedFormat = $Format
    if ($Format -eq 'Auto') {
        $resolvedFormat = if ($terminalWidth -lt $WidthThreshold) { 'List' } else { 'Table' }
    }

    Write-Host ""
    Write-LogMessage -Type INFO -Message ("=" * $lineWidth)
    Write-LogMessage -Type INFO -Message $Title
    Write-LogMessage -Type INFO -Message ("=" * $lineWidth)
    Write-Host ""

    switch ($resolvedFormat) {
        'GridView' {
            $gridViewAvailable = $null -ne (Get-Command -Name 'Out-GridView' -ErrorAction SilentlyContinue)
            if ($gridViewAvailable) {
                $Config | Out-GridView -Title $Title
            } else {
                Write-LogMessage -Type WARNING -Message "Out-GridView is not available on this system (typically only available on Windows PowerShell). Using List format instead."
                # Write-Host: blank line and table output use Write-Host so the interactive table renders correctly; Write-Output can introduce rendering regression.
                $Config | Format-List -Property 'Key', 'Required', 'Notes' | Out-Host
            }
        }
        'List' {
            # Write-Host: blank line and table output use Write-Host so the interactive table renders correctly; Write-Output can introduce rendering regression.
            $Config | Format-List -Property 'Key', 'Required', 'Notes' | Out-Host
        }
        'Table' {
            try {
                $Config | Format-ConfigurationTable
            } catch {
                Write-LogMessage -Type WARNING -Message "Failed to format configuration table: $($_.Exception.Message)"
                Write-LogMessage -Type INFO -Message "Displaying configuration as list format:"
                # Write-Host: blank line and table output use Write-Host so the interactive table renders correctly; Write-Output can introduce rendering regression.
                $Config | Format-List -Property 'Key', 'Required', 'Notes' | Out-Host
            }
        }
    }

    Write-Host ""
}
function Show-InfrastructureJsonConfigurationHelp {

    <#
        .SYNOPSIS
        Displays a reference table for configuring infrastructure.json file.

        .DESCRIPTION
        This helper function displays a reference table of configuration keys for the infrastructure.json file,
        with Required (Yes/No/Conditional) and Notes for each key.

        .PARAMETER Format
        Specifies the output format. Valid values are:

        - Auto (default): Automatically selects the best format based on terminal width. Uses 'List' for narrow screens (< WidthThreshold characters, default 120) and 'Table' for wide screens (>= WidthThreshold characters).
        - List: Displays each field on its own line. Works best for narrow screens (40-50+ characters). No column wrapping issues.
        - Table: Displays data in a table format with columns. Best for wide screens (WidthThreshold+ characters, default 120+).
        - GridView: Opens an interactive grid view window with sorting and filtering capabilities. Works on any screen size but requires Windows PowerShell (not available in PowerShell Core on macOS/Linux).

        .PARAMETER Filter
        Filters the configuration elements by Key using wildcard matching. The filter is automatically wrapped with wildcards (*) on both sides.
        For example, '-Filter argoCD' will match all keys containing 'argoCD'.

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

        Displays only configuration elements containing 'argoCD' in their Key.

        .OUTPUTS
        None. This function displays formatted output to the console or opens a grid view window.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $false)] [AllowEmptyString()] [String]$Filter,
        [Parameter(Mandatory = $false)] [ValidateSet('Auto', 'GridView', 'List', 'Table')] [String]$Format = 'Auto',
        [Parameter(Mandatory = $false)] [ValidateRange(40, [Int]::MaxValue)] [Int]$WidthThreshold = 120
    )

    $config = Get-ConfigurationHelpData -HelpFileName $Script:INFRA_HELP_FILENAME -Filter $Filter
    if ($null -ne $config) {
        Show-ConfigurationHelpTable -Config $config -Format $Format -Title "Infrastructure.json Configuration Reference" -WidthThreshold $WidthThreshold
    }
}
function Show-SupervisorJsonConfigurationHelp {

    <#
        .SYNOPSIS
        Displays a reference table for configuring supervisor.json file.

        .DESCRIPTION
        This helper function displays a reference table of configuration keys for the supervisor.json file,
        with Required (Yes/No/Conditional) and Notes for each key.

        .PARAMETER Format
        Specifies the output format. Valid values are:

        - Auto (default): Automatically selects the best format based on terminal width. Uses 'List' for narrow screens (< WidthThreshold characters, default 120) and 'Table' for wide screens (>= WidthThreshold characters).
        - List: Displays each field on its own line. Works best for narrow screens (40-50+ characters). No column wrapping issues.
        - Table: Displays data in a table format with columns. Best for wide screens (WidthThreshold+ characters, default 120+).
        - GridView: Opens an interactive grid view window with sorting and filtering capabilities. Works on any screen size but requires Windows PowerShell (not available in PowerShell Core on macOS/Linux).

        .PARAMETER Filter
        Filters the configuration elements by Key using wildcard matching. The filter is automatically wrapped with wildcards (*) on both sides.
        For example, '-Filter mgmt' will match all keys containing 'mgmt'.

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
        Show-SupervisorJsonConfigurationHelp -Filter mgmt

        Displays only configuration elements containing 'mgmt' in their Key.

        .OUTPUTS
        None. This function displays formatted output to the console or opens a grid view window.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $false)] [AllowEmptyString()] [String]$Filter,
        [Parameter(Mandatory = $false)] [ValidateSet('Auto', 'GridView', 'List', 'Table')] [String]$Format = 'Auto',
        [Parameter(Mandatory = $false)] [ValidateRange(40, [Int]::MaxValue)] [Int]$WidthThreshold = 120
    )

    $config = Get-ConfigurationHelpData -HelpFileName $Script:SUPERVISOR_HELP_FILENAME -Filter $Filter
    if ($null -ne $config) {
        Show-ConfigurationHelpTable -Config $config -Format $Format -Title "Supervisor.json Configuration Reference" -WidthThreshold $WidthThreshold
    }
}

#endregion
function Get-VcfEdgeAtScaleConfigUiVersion {

    <#
        .SYNOPSIS
        Returns the UI_VERSION string embedded in a veas-json-generator.py file.

        .DESCRIPTION
        Reads the first line matching the pattern UI_VERSION = "..." in the specified file and returns
        the quoted version value. Returns $null when the file is unreadable or contains no matching line.

        .PARAMETER FilePath
        Full path to the veas-json-generator.py file to inspect.

        .OUTPUTS
        [String] Version string (e.g. "1.0.3.1004"), or $null if not found.

        .EXAMPLE
        Get-VcfEdgeAtScaleConfigUiVersion -FilePath "C:\Users\Admin\VCFEdgeAtScale\Tools\veas-json-generator.py"

        Returns the UI_VERSION value from the specified file.

        .NOTES
        Private helper. Used by Sync-VcfEdgeAtScaleConfigUiTool to compare source and destination
        Python tool versions before deciding whether to copy.
    #>
    [OutputType([String])]

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$FilePath
    )

    try {
        $lineMatch = Select-String -LiteralPath $FilePath -Pattern 'UI_VERSION\s*=\s*"([^"]+)"' -ErrorAction Stop
        if ($null -ne $lineMatch) {
            return $lineMatch.Matches[0].Groups[1].Value
        }
    } catch {
        Write-LogMessage -Type DEBUG -Message "Get-VcfEdgeAtScaleConfigUiVersion: could not read '${FilePath}': $($_.Exception.Message)"
    }
    return $null
}
function Sync-VcfEdgeAtScaleConfigUiTool {

    <#
        .SYNOPSIS
        Copies the config UI tool from the newly installed module to the deployment root Tools directory when the versions differ.

        .DESCRIPTION
        After a module upgrade, locates the newest installed VcfEdgeAtScale module via Get-Module -ListAvailable,
        reads the UI_VERSION from its veas-json-generator.py, and compares it to the UI_VERSION in the user's
        deployment root Tools directory. If they differ the new file is copied automatically with no user prompt.

        The sync is silently skipped when:
        - UserBaseDirectory is not set or does not exist.
        - The tool is absent from the deployment root (the user has not run -Initialize yet).
        - The source file is missing from the newly installed module.

        .PARAMETER UserBaseDirectory
        Path to the operator's deployment base directory (typically $env:VcfEdgeAtScaleRootDirectory).
        Pass an empty string or omit to skip the sync.

        .EXAMPLE
        Sync-VcfEdgeAtScaleConfigUiTool -UserBaseDirectory $env:VcfEdgeAtScaleRootDirectory

        Checks whether the deployed config UI tool matches the installed module version and copies it if not.

        .NOTES
        Private helper. Invoked from Invoke-VcfEdgeAtScaleUpdateCheck after a successful Update-Module call.
        Write-Host is the primary output mechanism in this function; all Write-Host calls are
        intentional interactive console output. Use Write-LogMessage for diagnostic logging.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $false)] [AllowEmptyString()] [String]$UserBaseDirectory
    )

    $configUiFileName = "veas-json-generator.py"

    $latestInstalledModule = Get-Module -ListAvailable -Name "VcfEdgeAtScale" |
        Sort-Object -Property Version -Descending |
        Select-Object -First 1
    if ($null -eq $latestInstalledModule) {
        Write-LogMessage -Type DEBUG -Message "Config UI sync skipped: VcfEdgeAtScale module not found via Get-Module -ListAvailable."
        return
    }

    $moduleToolsPath = Join-Path -Path $latestInstalledModule.ModuleBase -ChildPath "Tools"
    $sourcePath = Join-Path -Path $moduleToolsPath -ChildPath $configUiFileName
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
        Write-LogMessage -Type DEBUG -Message "Config UI sync skipped: source not found at $sourcePath."
        return
    }

    if ([String]::IsNullOrWhiteSpace($UserBaseDirectory) -or -not (Test-Path -LiteralPath $UserBaseDirectory -PathType Container)) {
        Write-LogMessage -Type DEBUG -Message "Config UI sync skipped: deployment root is not set or does not exist."
        return
    }

    $deploymentToolsPath = Join-Path -Path $UserBaseDirectory -ChildPath "Tools"
    $destPath = Join-Path -Path $deploymentToolsPath -ChildPath $configUiFileName
    if (-not (Test-Path -LiteralPath $destPath -PathType Leaf)) {
        Write-LogMessage -Type DEBUG -Message "Config UI tool not present in deployment root; skipping auto-sync. Run Start-VcfEdgeAtScale -Initialize to install it."
        return
    }

    $sourceVersion = Get-VcfEdgeAtScaleConfigUiVersion -FilePath $sourcePath
    $destVersion = Get-VcfEdgeAtScaleConfigUiVersion -FilePath $destPath
    if ($sourceVersion -eq $destVersion) {
        Write-LogMessage -Type DEBUG -Message "Config UI tool is current (version $sourceVersion); no sync needed."
        return
    }

    Write-LogMessage -Type INFO -Message "Updating config UI tool: version $destVersion → $sourceVersion."
    try {
        Copy-Item -LiteralPath $sourcePath -Destination $destPath -Force -ErrorAction Stop
        Write-LogMessage -Type INFO -Message "Config UI tool updated to $sourceVersion at $destPath."
        Write-Host "  Config UI tool updated: $configUiFileName ($destVersion → $sourceVersion)" -ForegroundColor Green
    } catch {
        Write-LogMessage -Type WARNING -Message "Config UI tool sync failed: $($_.Exception.Message)"
        Write-Host "  Config UI tool could not be auto-updated. To copy manually, run:" -ForegroundColor Yellow
        Write-Host "    Copy-Item -LiteralPath '$sourcePath' -Destination '$destPath' -Force" -ForegroundColor Cyan
    }
}
function Get-VcfEdgeAtScaleUiTemplateVersion {

    <#
        .SYNOPSIS
        Returns the VEAS-UI-VERSION string embedded in a veas-ui.html file.

        .DESCRIPTION
        Reads the first line matching the pattern <!-- VEAS-UI-VERSION: ... --> in the specified
        file and returns the version value. Returns $null when the file is unreadable or contains
        no matching line.

        .PARAMETER FilePath
        Full path to the veas-ui.html file to inspect.

        .OUTPUTS
        [String] Version string (e.g. "1.0.3.1004"), or $null if not found.

        .EXAMPLE
        Get-VcfEdgeAtScaleUiTemplateVersion -FilePath "C:\VCFEdgeAtScale\Tools\veas-ui.html"

        Returns the VEAS-UI-VERSION value from the specified file.

        .NOTES
        Private helper. Used by Sync-VcfEdgeAtScaleUiTemplate to compare source and destination
        HTML template versions before deciding whether to copy.
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$FilePath
    )

    try {
        $lineMatch = Select-String -LiteralPath $FilePath -Pattern 'VEAS-UI-VERSION:\s*([\d.]+)' -ErrorAction Stop
        if ($null -ne $lineMatch) {
            return $lineMatch.Matches[0].Groups[1].Value
        }
    } catch {
        Write-LogMessage -Type DEBUG -Message "Get-VcfEdgeAtScaleUiTemplateVersion: could not read '${FilePath}': $($_.Exception.Message)"
    }
    return $null
}
function Sync-VcfEdgeAtScaleUiTemplate {

    <#
        .SYNOPSIS
        Copies the UI HTML template from the newly installed module to the deployment root Tools directory when the versions differ.

        .DESCRIPTION
        After a module upgrade, locates the newest installed VcfEdgeAtScale module via Get-Module -ListAvailable,
        reads the VEAS-UI-VERSION from its veas-ui.html, and compares it to the version in the user's
        deployment root Tools directory. If they differ the new file is copied automatically with no user prompt.

        The sync is silently skipped when:
        - UserBaseDirectory is not set or does not exist.
        - The template is absent from the deployment root (the user has not run -Initialize yet).
        - The source file is missing from the newly installed module.

        Unlike veas-json-generator.py, the HTML template is always silently overwritten because it
        is a versioned UI asset that is not edited by the operator.

        .PARAMETER UserBaseDirectory
        Path to the operator's deployment base directory (typically $env:VcfEdgeAtScaleRootDirectory).
        Pass an empty string or omit to skip the sync.

        .EXAMPLE
        Sync-VcfEdgeAtScaleUiTemplate -UserBaseDirectory $env:VcfEdgeAtScaleRootDirectory

        Checks whether the deployed UI template matches the installed module version and copies it if not.

        .NOTES
        Private helper. Invoked from Invoke-VcfEdgeAtScaleUpdateCheck after a successful Update-Module call.
        Write-Host is the primary output mechanism in this function; all Write-Host calls are
        intentional interactive console output. Use Write-LogMessage for diagnostic logging.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $false)] [AllowEmptyString()] [String]$UserBaseDirectory
    )

    $uiTemplateFileName = "veas-ui.html"

    $latestInstalledModule = Get-Module -ListAvailable -Name "VcfEdgeAtScale" |
        Sort-Object -Property Version -Descending |
        Select-Object -First 1
    if ($null -eq $latestInstalledModule) {
        Write-LogMessage -Type DEBUG -Message "UI template sync skipped: VcfEdgeAtScale module not found via Get-Module -ListAvailable."
        return
    }

    $moduleToolsPath = Join-Path -Path $latestInstalledModule.ModuleBase -ChildPath "Tools"
    $sourcePath = Join-Path -Path $moduleToolsPath -ChildPath $uiTemplateFileName
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
        Write-LogMessage -Type DEBUG -Message "UI template sync skipped: source not found at $sourcePath."
        return
    }

    if ([String]::IsNullOrWhiteSpace($UserBaseDirectory) -or -not (Test-Path -LiteralPath $UserBaseDirectory -PathType Container)) {
        Write-LogMessage -Type DEBUG -Message "UI template sync skipped: deployment root is not set or does not exist."
        return
    }

    $deploymentToolsPath = Join-Path -Path $UserBaseDirectory -ChildPath "Tools"
    $destPath = Join-Path -Path $deploymentToolsPath -ChildPath $uiTemplateFileName
    if (-not (Test-Path -LiteralPath $destPath -PathType Leaf)) {
        Write-LogMessage -Type DEBUG -Message "UI template not present in deployment root; skipping auto-sync. Run Start-VcfEdgeAtScale -Initialize to install it."
        return
    }

    $sourceVersion = Get-VcfEdgeAtScaleUiTemplateVersion -FilePath $sourcePath
    $destVersion = Get-VcfEdgeAtScaleUiTemplateVersion -FilePath $destPath
    if ($sourceVersion -eq $destVersion) {
        Write-LogMessage -Type DEBUG -Message "UI template is current (version $sourceVersion); no sync needed."
        return
    }

    Write-LogMessage -Type INFO -Message "Updating UI template: version $destVersion → $sourceVersion."
    try {
        Copy-Item -LiteralPath $sourcePath -Destination $destPath -Force -ErrorAction Stop
        Write-LogMessage -Type INFO -Message "UI template updated to $sourceVersion at $destPath."
        Write-Host "  UI template updated: $uiTemplateFileName ($destVersion → $sourceVersion)" -ForegroundColor Green
    } catch {
        Write-LogMessage -Type WARNING -Message "UI template sync failed: $($_.Exception.Message)"
        Write-Host "  UI template could not be auto-updated. To copy manually, run:" -ForegroundColor Yellow
        Write-Host "    Copy-Item -LiteralPath '$sourcePath' -Destination '$destPath' -Force" -ForegroundColor Cyan
    }
}
function Invoke-PsGalleryModuleUpdate {

    <#
        .SYNOPSIS
        Prompts the operator to install a PSGallery module update and performs the install when confirmed.

        .DESCRIPTION
        Displays an install prompt for the specified module/version. If the operator confirms (default Y),
        runs Update-Module, then syncs the config UI tool and UI template. Displays manual steps on decline
        or if the install fails.

        .PARAMETER LatestVersion
        The latest available version string from Find-Module.

        .PARAMETER ModuleName
        The module name as registered in PSGallery (e.g. "VcfEdgeAtScale").

        .EXAMPLE
        Invoke-PsGalleryModuleUpdate -ModuleName "VcfEdgeAtScale" -LatestVersion "2.1.0"

        .NOTES
        Write-Host is the primary output mechanism in this function; all Write-Host calls are
        intentional interactive console output. Use Write-LogMessage for diagnostic logging.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$LatestVersion,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ModuleName
    )

    Write-Host ""
    $installChoice = Read-Host "Install update now? [Y/n]"
    if ([String]::IsNullOrWhiteSpace($installChoice)) {
        $installChoice = "Y"
    }
    if ($installChoice -notmatch '^[Yy]') {
        Write-Host ""
        Write-Host "To update manually, run:" -ForegroundColor Yellow
        Write-Host "  Update-Module -Name $ModuleName" -ForegroundColor Cyan
        Write-Host ""
        return
    }
    Write-LogMessage -Type INFO -Message "Installing $ModuleName $LatestVersion from PSGallery..."
    try {
        Update-Module -Name $ModuleName -ErrorAction Stop
        Write-LogMessage -Type INFO -Message "$ModuleName $LatestVersion installed successfully."
        Sync-VcfEdgeAtScaleConfigUiTool -UserBaseDirectory $env:VcfEdgeAtScaleRootDirectory
        Sync-VcfEdgeAtScaleUiTemplate   -UserBaseDirectory $env:VcfEdgeAtScaleRootDirectory
        Write-Host ""
        Write-Host "Update complete. Open a new PowerShell window to use the new version." -ForegroundColor Green
        Write-Host ""
    } catch {
        Write-LogMessage -Type ERROR -Message "Update failed: $($_.Exception.Message)"
        Write-Host ""
        Write-Host "To update manually, run:" -ForegroundColor Yellow
        Write-Host "  Update-Module -Name $ModuleName" -ForegroundColor Cyan
        Write-Host ""
    }
}
function Invoke-VcfEdgeAtScaleUpdateCheck {

    <#
        .SYNOPSIS
        Checks PSGallery for a newer version of the VcfEdgeAtScale module and optionally installs it.

        .DESCRIPTION
        Queries the PowerShell Gallery for the latest published version of VcfEdgeAtScale and compares it
        to the currently running version. The check runs regardless of how the module was installed.

        When a newer version is found:
        - If the module was installed via PSGallery (Get-InstalledModule shows Repository = PSGallery), the
          user is offered the option to run Update-Module automatically (default Y).
        - If the module was installed manually (cloned/copied), the new version is announced and the manual
          update steps are shown; no automatic install is attempted.

        The check is skipped silently when:
        - PSGallery cannot be reached (network error, proxy, air-gap). All PSGallery errors are non-fatal.
        - The infrastructure JSON is loaded and common.autoUpdate is explicitly set to false.

        Auto-checks triggered by New-LogFile (once-per-day) are quiet when no update is found; only a new
        version produces visible output. Manual invocation (called from Start-VcfEdgeAtScale -CheckForUpdates)
        always reports the outcome, including "already up to date."

        .PARAMETER Quiet
        When set, suppress output when the module is already up to date. Used for the daily auto-check.

        .PARAMETER InputData
        Optional parsed infrastructure JSON object. When supplied, common.autoUpdate is read to respect
        an operator override that disables auto-checks.

        .EXAMPLE
        Invoke-VcfEdgeAtScaleUpdateCheck

        Checks for an available update and prompts to install if one is found (PSGallery installs) or
        shows manual update steps (manually installed copies).

        .EXAMPLE
        Invoke-VcfEdgeAtScaleUpdateCheck -Quiet -InputData $inputData

        Daily auto-check; silent when already at the latest version, respects common.autoUpdate override.

        .NOTES
        Requires network access to the PowerShell Gallery. All PSGallery errors are non-fatal and logged
        at DEBUG; the check is silently skipped rather than surfacing an error to the operator.
        Write-Host is the primary output mechanism in this function; all Write-Host calls are
        intentional interactive console output. Use Write-LogMessage for diagnostic logging.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $false)] [Object]$InputData,
        [Parameter(Mandatory = $false)] [Switch]$Quiet
    )

    # Respect common.autoUpdate = false override when infrastructure JSON is loaded.
    if ($null -ne $InputData -and $null -ne $InputData.common -and $null -ne $InputData.common.PSObject.Properties["autoUpdate"]) {
        $autoUpdateValue = $InputData.common.autoUpdate
        if ($autoUpdateValue -is [bool] -and -not $autoUpdateValue) {
            Write-LogMessage -Type DEBUG -Message "Update check skipped: common.autoUpdate is false in infrastructure JSON."
            return
        } elseif ($autoUpdateValue -isnot [bool]) {
            Write-LogMessage -Type DEBUG -Message "Update check: common.autoUpdate value is not a boolean ($($autoUpdateValue.GetType().Name)); treating as enabled."
        }
    }

    # Determine the current running version and whether this was a PSGallery install.
    # Get-InstalledModule only knows about modules registered by Install-Module/Update-Module;
    # manually installed copies will return $null.
    $installedModule = Get-InstalledModule -Name "VcfEdgeAtScale" -ErrorAction SilentlyContinue
    $isGalleryInstall = $null -ne $installedModule -and $installedModule.Repository -eq "PSGallery"

    # Use the running module's version as the baseline for the comparison regardless of
    # install source; Get-Module is always available even for manual installs.
    $runningModule = Get-Module -Name "VcfEdgeAtScale" -ErrorAction SilentlyContinue
    if ($null -eq $runningModule) {
        Write-LogMessage -Type DEBUG -Message "Update check skipped: VcfEdgeAtScale is not currently loaded."
        return
    }
    $currentVersion = [Version]$runningModule.Version

    # Query PSGallery. Any failure (network, proxy, air-gap) is non-fatal and silently skipped.
    try {
        $galleryModule = Find-Module -Name "VcfEdgeAtScale" -Repository "PSGallery" -ErrorAction Stop
    } catch {
        Write-LogMessage -Type DEBUG -Message "Update check skipped: could not reach PSGallery. $($_.Exception.Message)"
        return
    }

    $latestVersion = [Version]$galleryModule.Version

    if ($latestVersion -le $currentVersion) {
        if (-not $Quiet) {
            Write-LogMessage -Type INFO -Message "VcfEdgeAtScale is up to date (version $currentVersion)."
        }
        return
    }

    Write-LogMessage -Type ADVISORY -Message "A new version of VcfEdgeAtScale is available: $latestVersion (you have $currentVersion)." -PrependNewLine

    if (-not $isGalleryInstall) {
        # Module was installed manually — cannot use Update-Module; show manual steps.
        Write-Host ""
        Write-Host "This module was not installed from PSGallery. To update, pull the latest source and re-run the installer:" -ForegroundColor Yellow
        Write-Host "  git pull" -ForegroundColor Cyan
        Write-Host "  .\VcfEdgeAtScale\Install-VcfEdgeAtScaleModule.ps1" -ForegroundColor Cyan
        Write-Host ""
        return
    }

    # PSGallery install — prompt to update automatically. Default is Y.
    Invoke-PsGalleryModuleUpdate -ModuleName "VcfEdgeAtScale" -LatestVersion $latestVersion
}

#endregion
