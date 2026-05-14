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
Function Test-VcfEdgeAtScaleDeploymentRootInitialized {

    <#
        .SYNOPSIS
        Returns whether a directory matches a completed Initialize layout (folders, JSON, shipped YAML).

        .NOTES
        Private helper; not exported. Used by Invoke-VcfEdgeAtScaleModuleInitialize only.

        .DESCRIPTION
        True when Docs, Logs, ServicesYaml exist, root infrastructure.json and supervisor.json exist, and all
        VcfEdgeAtScaleServiceYamlTemplateFileNames files exist under ServicesYaml.

        .PARAMETER DeploymentRoot
        Resolved full path to the deployment base directory.

        .OUTPUTS
        [Boolean]
    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$DeploymentRoot
    )

    foreach ($dirName in @("Docs", "Logs", "ServicesYaml")) {
        $childPath = Join-Path -Path $DeploymentRoot -ChildPath $dirName
        if (-not (Test-Path -LiteralPath $childPath -PathType Container)) {
            return $false
        }
    }
    $infrastructurePath = Join-Path -Path $DeploymentRoot -ChildPath "infrastructure.json"
    $supervisorPath = Join-Path -Path $DeploymentRoot -ChildPath "supervisor.json"
    if (-not (Test-Path -LiteralPath $infrastructurePath -PathType Leaf)) {
        return $false
    }
    if (-not (Test-Path -LiteralPath $supervisorPath -PathType Leaf)) {
        return $false
    }
    $servicesYamlDir = Join-Path -Path $DeploymentRoot -ChildPath "ServicesYaml"
    foreach ($yamlBaseName in $Script:VcfEdgeAtScaleServiceYamlTemplateFileNames) {
        $yamlPath = Join-Path -Path $servicesYamlDir -ChildPath $yamlBaseName
        if (-not (Test-Path -LiteralPath $yamlPath -PathType Leaf)) {
            return $false
        }
    }
    return $true
}
Function Invoke-VcfEdgeAtScaleModuleInitialize {

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
            ServicesYaml are updated when written from the template). Persists VcfEdgeatScaleRootDirectory via
            On Windows: [System.Environment]::SetEnvironmentVariable (User scope) persists it to the registry. On macOS/Linux: the line is automatically appended to $PROFILE so new sessions inherit it.
            When VcfEdgeatScaleRootDirectory points at an existing initialized layout, asks whether to initialize a different directory instead of re-prompting for the base path.

        .PARAMETER TemplatesOnly
            When set, copies only ServicesYaml and Docs templates; does not create or replace infrastructure.json or supervisor.json at the base directory.

        .NOTES
            Private to the module. Invoked from Start-VcfEdgeAtScale -Initialize only. Requires an interactive host for Read-Host.
            User-visible status uses Write-Host (not Write-Output) because Start-VcfEdgeAtScale assigns this function's output to $null, which would otherwise hide success-stream output.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $false)] [Switch]$TemplatesOnly
    )

    $templatesPath = Get-ModuleTemplatesPath
    $templateRestoreHint = "Reinstall the VcfEdgeAtScale module (for example Install-Module VcfEdgeAtScale -Force) or copy missing files from https://github.com/vmware/powershell-module-for-vcf-edge-at-scale (see the VcfEdgeAtScale/Templates folder in that repository)."
    $defaultBaseDirectory = Join-Path -Path $HOME -ChildPath "VCFEdgeAtScale"

    Write-Host ""
    Write-Host "VcfEdgeAtScale initialize" -ForegroundColor Cyan
    if ($TemplatesOnly) {
        Write-Host "  Mode: templates only — refresh ServicesYaml and Docs; root JSON is not modified." -ForegroundColor Gray
    } else {
        Write-Host "  Mode: full — configuration base, Logs, ServicesYaml, Docs, optional JSON seed/replace." -ForegroundColor Gray
    }

    $baseDirectory = $null
    $envRootResolved = $null
    $envRootRaw = $env:VcfEdgeatScaleRootDirectory
    if (-not [String]::IsNullOrWhiteSpace($envRootRaw)) {
        $trimmedEnvRoot = $envRootRaw.Trim()
        if (-not (Test-Path -LiteralPath $trimmedEnvRoot)) {
            Write-Host ""
            Write-Host "  Note: `$env:VcfEdgeatScaleRootDirectory pointed at a path that does not exist:" -ForegroundColor Yellow
            Write-Host "    $trimmedEnvRoot" -ForegroundColor White
            $env:VcfEdgeatScaleRootDirectory = $null
            if ($IsWindows) {
                try {
                    [System.Environment]::SetEnvironmentVariable("VcfEdgeatScaleRootDirectory", $null, [System.EnvironmentVariableTarget]::User)
                    Write-Host "  Stale value cleared from session and user environment. Choose a folder below." -ForegroundColor Green
                } catch {
                    Write-Host "  Stale value cleared from session. User-level clear failed: $($_.Exception.Message)" -ForegroundColor Yellow
                }
            } else {
                Write-Host "  Stale value cleared from session. Choose a folder below." -ForegroundColor Green
            }
        } elseif (-not (Test-Path -LiteralPath $trimmedEnvRoot -PathType Container)) {
            Write-Host ""
            Write-Host "  Note: `$env:VcfEdgeatScaleRootDirectory points at a path that exists but is not a folder:" -ForegroundColor Yellow
            Write-Host "    $trimmedEnvRoot" -ForegroundColor White
            Write-Host "  Choose a deployment root folder below (default: $defaultBaseDirectory)." -ForegroundColor Gray
        } else {
            try {
                $envRootResolved = (Resolve-Path -LiteralPath $trimmedEnvRoot -ErrorAction Stop).Path
            } catch {
                $envRootResolved = $null
            }
            if ($envRootResolved -and (Test-VcfEdgeAtScaleDeploymentRootInitialized -DeploymentRoot $envRootResolved)) {
                Write-Host ""
                Write-Host "  Detected: `$env:VcfEdgeatScaleRootDirectory` is set in this session." -ForegroundColor Green
                Write-Host "    Value: $envRootRaw" -ForegroundColor White
                Write-Host "  That path resolves to a full Initialize layout (Docs, Logs, ServicesYaml, root JSON, shipped YAML under ServicesYaml):" -ForegroundColor Green
                Write-Host "    $envRootResolved" -ForegroundColor White
                try {
                    $useDifferentDirectoryResponse = Read-Host "Initialize a different directory instead? (y/N)"
                } catch {
                    throw "Initialize requires an interactive session for directory prompts. $($_.Exception.Message)"
                }
                switch -Regex ($useDifferentDirectoryResponse.Trim()) {
                    "^(?i)(y|yes)$" {
                        Write-Host "  Choose a new base path below (default remains Join-Path `$HOME 'VCFEdgeAtScale')." -ForegroundColor Gray
                    }
                    default {
                        $baseDirectory = $envRootResolved
                    }
                }
            } elseif ($envRootResolved) {
                Write-Host ""
                Write-Host "  Note: VcfEdgeatScaleRootDirectory is set, but this folder is not a complete initialized layout:" -ForegroundColor Yellow
                Write-Host "  $envRootResolved" -ForegroundColor Yellow
                Write-Host "  You will be prompted for the base directory below (default: $defaultBaseDirectory)." -ForegroundColor Gray
            }
        }
    }

    if ($null -eq $baseDirectory) {
        Write-Host ""
        Write-Host -NoNewline "  Default base directory:" -ForegroundColor White
        Write-Host "  $defaultBaseDirectory`n" -ForegroundColor Cyan
        try {
            $userBaseResponse = Read-Host "Press Enter to use the default, or type a full directory path"
        } catch {
            throw "Initialize requires an interactive session for directory prompts. $($_.Exception.Message)"
        }

        switch ([String]::IsNullOrWhiteSpace($userBaseResponse)) {
            $true { $baseDirectory = $defaultBaseDirectory }
            default { $baseDirectory = $userBaseResponse.Trim() }
        }
    }

    if ([String]::IsNullOrWhiteSpace($baseDirectory)) {
        throw "Base directory cannot be empty after input."
    }

    $baseDirectoryExistedBefore = Test-Path -LiteralPath $baseDirectory -PathType Container
    $baseDirectoryWasCreated = $false
    if (-not $baseDirectoryExistedBefore) {
        try {
            $null = New-Item -ItemType Directory -Path $baseDirectory -Force -ErrorAction Stop
            $baseDirectoryWasCreated = $true
        } catch {
            throw "Failed to create base directory `"$baseDirectory`": $($_.Exception.Message)"
        }
    }

    try {
        $resolvedBaseDirectory = (Resolve-Path -LiteralPath $baseDirectory).Path
    } catch {
        throw "Could not resolve the base directory path after create. Path: $baseDirectory. $($_.Exception.Message)"
    }
    $subdirectories = @("Docs", "Logs", "ServicesYaml", "Tools")
    $subdirectoriesCreated = [System.Collections.Generic.List[String]]::new()
    foreach ($subdirectoryName in $subdirectories) {
        $childPath = Join-Path -Path $resolvedBaseDirectory -ChildPath $subdirectoryName
        if (-not (Test-Path -LiteralPath $childPath -PathType Container)) {
            try {
                $null = New-Item -ItemType Directory -Path $childPath -Force -ErrorAction Stop
                $null = $subdirectoriesCreated.Add($subdirectoryName)
            } catch {
                throw "Failed to create directory `"$childPath`": $($_.Exception.Message)"
            }
        }
    }

    $servicesYamlDirectory = Join-Path -Path $resolvedBaseDirectory -ChildPath "ServicesYaml"
    $docsDirectory = Join-Path -Path $resolvedBaseDirectory -ChildPath "Docs"

    Write-Host ""
    Write-Host "  Supervisor service YAML (ServicesYaml)" -ForegroundColor Magenta
    foreach ($templateFileName in $Script:VcfEdgeAtScaleServiceYamlTemplateFileNames) {
        $fromPath = Join-Path -Path $templatesPath -ChildPath $templateFileName
        if (-not (Test-Path -LiteralPath $fromPath -PathType Leaf)) {
            throw "Required module template is missing: $fromPath. $templateRestoreHint"
        }
        $toPath = Join-Path -Path $servicesYamlDirectory -ChildPath $templateFileName
        $shouldCopyServiceYaml = $true
        if (Test-Path -LiteralPath $toPath -PathType Leaf) {
            try {
                $overwriteAnswer = Read-Host "File `"$toPath`" already exists. Overwrite? (y/N)"
            } catch {
                throw "Initialize requires an interactive session for overwrite prompts. $($_.Exception.Message)"
            }
            switch ($overwriteAnswer) {
                "y" { }
                "Y" { }
                default {
                    $shouldCopyServiceYaml = $false
                }
            }
        }
        if (-not $shouldCopyServiceYaml) {
            Write-Host "    Skipped (keep existing): $templateFileName" -ForegroundColor Yellow
            continue
        }
        try {
            Copy-Item -LiteralPath $fromPath -Destination $toPath -Force -ErrorAction Stop
        } catch {
            throw "Failed to copy `"$templateFileName`" to `"$toPath`": $($_.Exception.Message)"
        }
        Write-Host "    Copied: $templateFileName" -ForegroundColor Green
    }

    $rtfDocumentationPairs = @(
        @{ DestinationFileName = "EXAMPLE.rtf"; SourcePath = (Join-Path -Path $templatesPath -ChildPath "EXAMPLE.rtf") },
        @{ DestinationFileName = "README.rtf"; SourcePath = (Join-Path -Path $templatesPath -ChildPath "README.rtf") }
    )

    Write-Host ""
    Write-Host "  Documentation (Docs)" -ForegroundColor Magenta

    # RTF files may be customized by the user; prompt before overwriting.
    foreach ($documentationPair in $rtfDocumentationPairs) {
        if (-not (Test-Path -LiteralPath $documentationPair.SourcePath -PathType Leaf)) {
            Write-Warning "Optional documentation file '$($documentationPair.DestinationFileName)' is not in the module Templates folder (source not found at $($documentationPair.SourcePath)). Skipping this copy; Initialize continues. $templateRestoreHint"
            continue
        }
        $destinationDocumentationPath = Join-Path -Path $docsDirectory -ChildPath $documentationPair.DestinationFileName
        $shouldCopyDocumentation = $true
        if (Test-Path -LiteralPath $destinationDocumentationPath -PathType Leaf) {
            try {
                $overwriteDocumentationAnswer = Read-Host "File `"$destinationDocumentationPath`" already exists. Overwrite? (y/N)"
            } catch {
                throw "Initialize requires an interactive session for overwrite prompts. $($_.Exception.Message)"
            }
            switch ($overwriteDocumentationAnswer) {
                "y" { }
                "Y" { }
                default {
                    $shouldCopyDocumentation = $false
                }
            }
        }
        if (-not $shouldCopyDocumentation) {
            Write-Host "    Skipped (keep existing): $($documentationPair.DestinationFileName)" -ForegroundColor Yellow
            continue
        }
        try {
            Copy-Item -LiteralPath $documentationPair.SourcePath -Destination $destinationDocumentationPath -Force -ErrorAction Stop
        } catch {
            Write-Warning "Skipping documentation copy '$($documentationPair.DestinationFileName)' after error: $($_.Exception.Message) $templateRestoreHint"
            continue
        }
        Write-Host "    Copied: $($documentationPair.DestinationFileName)" -ForegroundColor Green
    }

    # Help JSON files are not user-edited; auto-refresh silently when the module version changes.
    $helpJsonFileNames = @("infrastructure-config-help.json", "supervisor-config-help.json")
    foreach ($helpFileName in $helpJsonFileNames) {
        $helpTemplatePath = Join-Path -Path $templatesPath -ChildPath $helpFileName
        $helpDocsPath = Join-Path -Path $docsDirectory -ChildPath $helpFileName
        $helpWasUpdated = Update-HelpJsonIfStale -DocsPath $helpDocsPath -TemplatePath $helpTemplatePath
        if (Test-Path -LiteralPath $helpDocsPath -PathType Leaf) {
            if ($helpWasUpdated) {
                Write-Host "    Updated: $helpFileName" -ForegroundColor Green
            } else {
                Write-Host "    Current: $helpFileName" -ForegroundColor Gray
            }
        }
    }

    $toolsDirectory = Join-Path -Path $resolvedBaseDirectory -ChildPath "Tools"
    $moduleToolsPath = Join-Path -Path (Split-Path -Path $templatesPath -Parent) -ChildPath "Tools"

    Write-Host ""
    Write-Host "  Tools" -ForegroundColor Magenta
    $configUiFileName = "veas-json-generator.py"
    $configUiSourcePath = Join-Path -Path $moduleToolsPath -ChildPath $configUiFileName
    if (-not (Test-Path -LiteralPath $configUiSourcePath -PathType Leaf)) {
        Write-Warning "Optional tool '$configUiFileName' is not in the module Tools folder (source not found at $configUiSourcePath). Skipping this copy; Initialize continues. $templateRestoreHint"
    } else {
        $configUiDestinationPath = Join-Path -Path $toolsDirectory -ChildPath $configUiFileName
        $shouldCopyConfigUi = $true
        if (Test-Path -LiteralPath $configUiDestinationPath -PathType Leaf) {
            try {
                $overwriteConfigUiAnswer = Read-Host "File `"$configUiDestinationPath`" already exists. Overwrite? (y/N)"
            } catch {
                throw "Initialize requires an interactive session for overwrite prompts. $($_.Exception.Message)"
            }
            switch ($overwriteConfigUiAnswer) {
                "y" { }
                "Y" { }
                default {
                    $shouldCopyConfigUi = $false
                }
            }
        }
        if ($shouldCopyConfigUi) {
            $pyExeHint = (Get-PythonExecutable)?.Executable ?? "python3"
            try {
                Copy-Item -LiteralPath $configUiSourcePath -Destination $configUiDestinationPath -Force -ErrorAction Stop
                Write-Host "    Copied: $configUiFileName  (run: $pyExeHint `"$configUiDestinationPath`")" -ForegroundColor Green
            } catch {
                Write-Warning "Skipping tool copy '$configUiFileName' after error: $($_.Exception.Message) $templateRestoreHint"
            }
        } else {
            Write-Host "    Skipped (keep existing): $configUiFileName" -ForegroundColor Yellow
        }
    }

    # Copy the UI HTML template (veas-ui.html) alongside the Python tool.
    # This file is a versioned UI asset and is always silently overwritten — it is not
    # edited by the operator, so no overwrite prompt is needed.
    $uiTemplateFileName = "veas-ui.html"
    $uiTemplateSourcePath = Join-Path -Path $moduleToolsPath -ChildPath $uiTemplateFileName
    if (-not (Test-Path -LiteralPath $uiTemplateSourcePath -PathType Leaf)) {
        Write-Warning "Optional UI template '$uiTemplateFileName' is not in the module Tools folder (source not found at $uiTemplateSourcePath). Skipping this copy; Initialize continues. $templateRestoreHint"
    } else {
        $uiTemplateDestinationPath = Join-Path -Path $toolsDirectory -ChildPath $uiTemplateFileName
        try {
            Copy-Item -LiteralPath $uiTemplateSourcePath -Destination $uiTemplateDestinationPath -Force -ErrorAction Stop
            Write-Host "    Copied: $uiTemplateFileName" -ForegroundColor Green
        } catch {
            Write-Warning "Skipping UI template copy '$uiTemplateFileName' after error: $($_.Exception.Message) $templateRestoreHint"
        }
    }

    $infrastructureDestinationPath = Join-Path -Path $resolvedBaseDirectory -ChildPath "infrastructure.json"
    $supervisorDestinationPath = Join-Path -Path $resolvedBaseDirectory -ChildPath "supervisor.json"
    $infrastructureTemplatePath = Join-Path -Path $templatesPath -ChildPath "infrastructure.json"
    $supervisorTemplatePath = Join-Path -Path $templatesPath -ChildPath "supervisor.json"

    if (-not $TemplatesOnly) {
        Write-Host ""
        Write-Host "  Root JSON files" -ForegroundColor Magenta
        $shouldWriteInfrastructureFromTemplate = $false
        if (-not (Test-Path -LiteralPath $infrastructureDestinationPath -PathType Leaf)) {
            $shouldWriteInfrastructureFromTemplate = $true
        } else {
            Write-Host "    infrastructure.json already exists at $infrastructureDestinationPath." -ForegroundColor White
            try {
                $refreshInfrastructureAnswer = Read-Host "Replace infrastructure.json from the module template (supervisorServices.parentDirectory -> ServicesYaml; harborConfiguration.parentDirectory -> base directory)? (y/N)"
            } catch {
                throw "Initialize requires an interactive session for refresh prompts. $($_.Exception.Message)"
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
            if (-not (Test-Path -LiteralPath $infrastructureTemplatePath -PathType Leaf)) {
                throw "Cannot create infrastructure.json from module template: file not found at $infrastructureTemplatePath. $templateRestoreHint"
            }
            $infrastructureTemplateText = Get-Content -LiteralPath $infrastructureTemplatePath -Raw -ErrorAction Stop
            # Set common.supervisorServices.parentDirectory to ServicesYaml and
            # clusters[].harborConfiguration.parentDirectory to the base directory.
            # Avoid ConvertTo-Json so template formatting (for example nicList) stays as shipped.
            $escapedParentDirectoryForJson = $servicesYamlDirectory.Replace('\', '\\').Replace('"', '\"')
            $supervisorParentPattern = '(?s)("common"\s*:\s*\{.*?"supervisorServices"\s*:\s*\{.*?"parentDirectory"\s*:\s*")([^"]*)(")'
            $supervisorParentMatch = [regex]::Match($infrastructureTemplateText, $supervisorParentPattern)
            if (-not $supervisorParentMatch.Success) {
                throw "Module template infrastructure.json must include common.supervisorServices.parentDirectory for Initialize. $templateRestoreHint"
            }
            $infrastructureJsonText = $infrastructureTemplateText.Substring(0, $supervisorParentMatch.Index) + $supervisorParentMatch.Groups[1].Value + $escapedParentDirectoryForJson + $supervisorParentMatch.Groups[3].Value + $infrastructureTemplateText.Substring($supervisorParentMatch.Index + $supervisorParentMatch.Length)

            # Replace harborConfiguration.parentDirectory with the base directory.
            # Use a regex rather than a literal string so the replacement works regardless of what value
            # the template ships with (avoids a silent no-op if the template placeholder ever changes).
            $escapedBaseDirectoryForJson = $resolvedBaseDirectory.Replace('\', '\\').Replace('"', '\"')
            $harborParentPattern = '(?s)("harborConfiguration"\s*:\s*\{[^}]*?"parentDirectory"\s*:\s*")([^"]*)(")'
            if ([regex]::IsMatch($infrastructureJsonText, $harborParentPattern)) {
                $infrastructureJsonText = [regex]::Replace($infrastructureJsonText, $harborParentPattern, "`${1}$escapedBaseDirectoryForJson`${3}")
            } else {
                Write-LogMessage -Type WARNING -Message "Module template infrastructure.json does not contain harborConfiguration.parentDirectory; skipping Harbor parentDirectory initialization."
            }

            try {
                $null = $infrastructureJsonText | ConvertFrom-Json -ErrorAction Stop
            } catch {
                throw "After setting parentDirectory fields, infrastructure JSON did not parse: $($_.Exception.Message)"
            }
            try {
                Set-Content -LiteralPath $infrastructureDestinationPath -Value $infrastructureJsonText -Encoding utf8 -ErrorAction Stop
            } catch {
                throw "Failed to write infrastructure JSON to `"$infrastructureDestinationPath`": $($_.Exception.Message)"
            }
            Write-Host "    Wrote infrastructure.json (common.supervisorServices.parentDirectory -> ServicesYaml; harborConfiguration.parentDirectory -> base directory)." -ForegroundColor Green
        }

        $shouldWriteSupervisorFromTemplate = $false
        if (-not (Test-Path -LiteralPath $supervisorDestinationPath -PathType Leaf)) {
            $shouldWriteSupervisorFromTemplate = $true
        } else {
            Write-Host "    supervisor.json already exists at $supervisorDestinationPath." -ForegroundColor White
            try {
                $refreshSupervisorAnswer = Read-Host "Replace supervisor.json from the module template? (y/N)"
            } catch {
                throw "Initialize requires an interactive session for refresh prompts. $($_.Exception.Message)"
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
            if (-not (Test-Path -LiteralPath $supervisorTemplatePath -PathType Leaf)) {
                throw "Cannot copy supervisor.json from module template: file not found at $supervisorTemplatePath. $templateRestoreHint"
            }
            try {
                Copy-Item -LiteralPath $supervisorTemplatePath -Destination $supervisorDestinationPath -Force -ErrorAction Stop
            } catch {
                throw "Failed to copy supervisor.json to `"$supervisorDestinationPath`": $($_.Exception.Message) $templateRestoreHint"
            }
            Write-Host "    Copied supervisor.json to deployment root." -ForegroundColor Green
        }
    } else {
        Write-Host ""
        Write-Host "  Templates-only mode: skipped root infrastructure.json and supervisor.json." -ForegroundColor Gray
    }

    # Set for the current session.
    $env:VcfEdgeatScaleRootDirectory = $resolvedBaseDirectory
    $persistedEnvSucceeded = $false

    if ($IsWindows) {
        # On Windows, persist to the user environment registry so new sessions inherit it automatically.
        try {
            [System.Environment]::SetEnvironmentVariable("VcfEdgeatScaleRootDirectory", $resolvedBaseDirectory, [System.EnvironmentVariableTarget]::User)
            $persistedEnvSucceeded = $true
        } catch {
            Write-Warning "Could not persist VcfEdgeatScaleRootDirectory to the user environment: $($_.Exception.Message)"
        }
    }
    # On macOS/Linux, [System.EnvironmentVariableTarget]::User is not supported by .NET
    # and will throw PlatformNotSupportedException. The user is prompted below to add
    # the variable to their $PROFILE instead.

    Write-Host ""
    Write-Host "=== Initialize summary ===" -ForegroundColor Cyan
    Write-Host "  Deployment root: $resolvedBaseDirectory" -ForegroundColor White
    if ($baseDirectoryWasCreated) {
        Write-Host "  Base directory: created (it did not exist before)." -ForegroundColor Green
    } else {
        Write-Host "  Base directory: already existed; files kept unless you chose overwrite." -ForegroundColor Gray
    }
    if ($subdirectoriesCreated.Count -gt 0) {
        Write-Host "  Subdirectories created: $($subdirectoriesCreated -join ', ')." -ForegroundColor Green
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
            Write-Host "  VcfEdgeatScaleRootDirectory -> $resolvedBaseDirectory (session + user environment persisted)." -ForegroundColor Green
        } else {
            Write-Host "  VcfEdgeatScaleRootDirectory -> $resolvedBaseDirectory (current session only; user-level persist failed — see warning above)." -ForegroundColor Yellow
            Write-Host '  To set manually: [System.Environment]::SetEnvironmentVariable("VcfEdgeatScaleRootDirectory", "<path>", [System.EnvironmentVariableTarget]::User)' -ForegroundColor Cyan
        }
    } else {
        Write-Host "  VcfEdgeatScaleRootDirectory -> $resolvedBaseDirectory (set for this session)." -ForegroundColor Green
        Write-Host ""

        # Append to $PROFILE automatically so new sessions inherit the variable,
        # creating the profile file if it does not yet exist.
        $profileLine = "`$env:VcfEdgeatScaleRootDirectory = `"$resolvedBaseDirectory`""
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
            if ($existingContent -notmatch [Regex]::Escape("VcfEdgeatScaleRootDirectory")) {
                Add-Content -LiteralPath $PROFILE -Value "`n$profileLine" -Encoding UTF8
                $appendedToProfile = $true
            }
        } catch {
            Write-Warning "Could not append to `$PROFILE ($PROFILE): $($_.Exception.Message)"
        }

        if ($appendedToProfile) {
            Write-Host "  Line appended to: $PROFILE" -ForegroundColor Green
            Write-Host "  New terminal sessions will inherit this variable automatically." -ForegroundColor Gray
        } else {
            Write-Host "  Note: `$PROFILE already contains VcfEdgeatScaleRootDirectory — no change made." -ForegroundColor Gray
            Write-Host "  Profile: $PROFILE" -ForegroundColor Gray
        }
    }

    return $resolvedBaseDirectory
}
Function Invoke-VcfEdgeAtScaleCollectLogs {

    <#
        .SYNOPSIS
        Interactively builds a support archive of deployment JSON, Logs, and ServicesYaml.

        .DESCRIPTION
        Prompts whether to use infrastructure.json and supervisor.json under the deployment root (from
        VcfEdgeatScaleRootDirectory or a typed path), or custom paths. Copies those files plus the contents of
        Logs and ServicesYaml under the deployment root into a zip under the user home directory.

        .OUTPUTS
        [String] Full path to the created zip file.

        .NOTES
        Private to the module. Invoked from Start-VcfEdgeAtScale -CollectLogs only. Uses Write-Host so output is visible when the caller assigns the result to $null.
    #>

    [CmdletBinding()]
    Param ()

    $deploymentRootRaw = $env:VcfEdgeatScaleRootDirectory
    if ([String]::IsNullOrWhiteSpace($deploymentRootRaw)) {
        Write-Host "VcfEdgeatScaleRootDirectory is not set."
        try {
            $deploymentRootRaw = Read-Host "Enter deployment root (folder that contains Logs and ServicesYaml)"
        } catch {
            throw "CollectLogs requires an interactive session or set VcfEdgeatScaleRootDirectory. $($_.Exception.Message)"
        }
    }
    if ([String]::IsNullOrWhiteSpace($deploymentRootRaw)) {
        throw "A deployment root directory is required for CollectLogs."
    }
    try {
        $deploymentRoot = (Resolve-Path -LiteralPath $deploymentRootRaw.Trim()).Path
    } catch {
        throw "Could not resolve deployment root: $deploymentRootRaw. $($_.Exception.Message)"
    }

    $defaultInfrastructurePath = Join-Path -Path $deploymentRoot -ChildPath "infrastructure.json"
    $defaultSupervisorPath = Join-Path -Path $deploymentRoot -ChildPath "supervisor.json"

    Write-Host ""
    Write-Host "Default JSON files under deployment root:"
    Write-Host "  $defaultInfrastructurePath"
    Write-Host "  $defaultSupervisorPath"
    try {
        $useDefaultsResponse = Read-Host "Use these two files in the zip? (Y/n)"
    } catch {
        throw "CollectLogs requires Read-Host. $($_.Exception.Message)"
    }

    $infrastructureSourcePath = $null
    $supervisorSourcePath = $null
    switch -Regex ($useDefaultsResponse.Trim()) {
        "^(?i)(n|no)$" {
            try {
                $infrastructureSourcePath = Read-Host "Full path to infrastructure.json to include"
                $supervisorSourcePath = Read-Host "Full path to supervisor.json to include"
            } catch {
                throw "CollectLogs requires Read-Host for custom paths. $($_.Exception.Message)"
            }
        }
        default {
            $infrastructureSourcePath = $defaultInfrastructurePath
            $supervisorSourcePath = $defaultSupervisorPath
        }
    }

    if ([String]::IsNullOrWhiteSpace($infrastructureSourcePath) -or [String]::IsNullOrWhiteSpace($supervisorSourcePath)) {
        throw "Both infrastructure.json and supervisor.json paths are required."
    }
    try {
        $infrastructureSourcePath = (Resolve-Path -LiteralPath $infrastructureSourcePath.Trim()).Path
        $supervisorSourcePath = (Resolve-Path -LiteralPath $supervisorSourcePath.Trim()).Path
    } catch {
        throw "Could not resolve JSON path: $($_.Exception.Message)"
    }
    if (-not (Test-Path -LiteralPath $infrastructureSourcePath -PathType Leaf)) {
        throw "infrastructure file not found: $infrastructureSourcePath"
    }
    if (-not (Test-Path -LiteralPath $supervisorSourcePath -PathType Leaf)) {
        throw "supervisor file not found: $supervisorSourcePath"
    }

    $logsSourcePath = Join-Path -Path $deploymentRoot -ChildPath "Logs"
    $servicesYamlSourcePath = Join-Path -Path $deploymentRoot -ChildPath "ServicesYaml"

    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $zipFileName = "VcfEdgeatScale-logs-$stamp.zip"
    $zipDestinationPath = Join-Path -Path $HOME -ChildPath $zipFileName
    $stagingParent = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "VcfEdgeAtScale-collect-$stamp"
    $stagingRoot = Join-Path -Path $stagingParent -ChildPath "archive"

    try {
        $null = New-Item -ItemType Directory -Path $stagingRoot -Force -ErrorAction Stop
        $stagingLogs = Join-Path -Path $stagingRoot -ChildPath "Logs"
        $stagingServicesYaml = Join-Path -Path $stagingRoot -ChildPath "ServicesYaml"
        $null = New-Item -ItemType Directory -Path $stagingLogs -Force -ErrorAction Stop
        $null = New-Item -ItemType Directory -Path $stagingServicesYaml -Force -ErrorAction Stop

        Copy-Item -LiteralPath $infrastructureSourcePath -Destination (Join-Path -Path $stagingRoot -ChildPath "infrastructure.json") -Force -ErrorAction Stop
        Copy-Item -LiteralPath $supervisorSourcePath -Destination (Join-Path -Path $stagingRoot -ChildPath "supervisor.json") -Force -ErrorAction Stop

        if (Test-Path -LiteralPath $logsSourcePath -PathType Container) {
            $logChildren = @(Get-ChildItem -LiteralPath $logsSourcePath -Force -ErrorAction SilentlyContinue)
            foreach ($logItem in $logChildren) {
                $logDest = Join-Path -Path $stagingLogs -ChildPath $logItem.Name
                Copy-Item -LiteralPath $logItem.FullName -Destination $logDest -Recurse -Force -ErrorAction Stop
            }
        } else {
            Write-Warning "Logs folder not found or not a directory: $logsSourcePath. The archive includes an empty Logs folder."
        }

        if (Test-Path -LiteralPath $servicesYamlSourcePath -PathType Container) {
            $yamlChildren = @(Get-ChildItem -LiteralPath $servicesYamlSourcePath -Force -ErrorAction SilentlyContinue)
            foreach ($yamlItem in $yamlChildren) {
                $yamlDest = Join-Path -Path $stagingServicesYaml -ChildPath $yamlItem.Name
                Copy-Item -LiteralPath $yamlItem.FullName -Destination $yamlDest -Recurse -Force -ErrorAction Stop
            }
        } else {
            Write-Warning "ServicesYaml folder not found or not a directory: $servicesYamlSourcePath. The archive includes an empty ServicesYaml folder."
        }

        if (Test-Path -LiteralPath $zipDestinationPath -PathType Leaf) {
            Remove-Item -LiteralPath $zipDestinationPath -Force -ErrorAction Stop
        }

        $compressItems = @(
            (Join-Path -Path $stagingRoot -ChildPath "infrastructure.json"),
            (Join-Path -Path $stagingRoot -ChildPath "supervisor.json"),
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
Function Start-VcfEdgeAtScale {

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

        For normal runs (not -Version or -Initialize), the environment variable VcfEdgeatScaleRootDirectory must
        point at your configuration base directory. Defaults for -InfrastructureJson and -SupervisorJson join that
        directory with infrastructure.json and supervisor.json when you omit those parameters. Logs are written
        under Join-Path(VcfEdgeatScaleRootDirectory, "Logs"). Use Start-VcfEdgeAtScale -Initialize to create or
        refresh the recommended layout from module Templates (new or existing base directory; use
        -Initialize -InitializeTemplatesOnly to refresh only ServicesYaml and Docs without changing root JSON).
        Use Start-VcfEdgeAtScale -CollectLogs to zip infrastructure.json, supervisor.json, Logs, and ServicesYaml for support (interactive prompts).

    .PARAMETER InfrastructureJson
        Path to the infrastructure configuration JSON file.

        When omitted, the path is Join-Path($env:VcfEdgeatScaleRootDirectory, "infrastructure.json").

        Supervisor service YAML files and Harbor TLS PEM files are referenced by
        supervisorServices.parentDirectory plus file name properties (and harborConfiguration.parentDirectory
        plus tlsCrt, tlsKey, caCrt file names). Combined paths are normalized with
        Resolve-InfrastructureReferencedFilePath (current directory and the infrastructure JSON directory).

    .PARAMETER SupervisorJson
        Path to the Supervisor Cluster configuration JSON file.

        When omitted, the path is Join-Path($env:VcfEdgeatScaleRootDirectory, "supervisor.json").

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
        Interactive support bundle. Prompts whether to use infrastructure.json and supervisor.json under the deployment root (from VcfEdgeatScaleRootDirectory, or a prompted path if unset), or custom full paths. Includes those files plus the Logs and ServicesYaml folders under that deployment root in Join-Path($HOME, "VcfEdgeatScale-logs-<timestamp>.zip"). Does not deploy. Do not combine with -Initialize, -InitializeTemplatesOnly, or -Version.

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
        When VcfEdgeatScaleRootDirectory resolves to a fully initialized layout (Docs, Logs, ServicesYaml, root JSON, all
        shipped YAML files under ServicesYaml), asks whether to initialize a different directory; answering N reuses that path without re-typing it.
        Section output uses console colors. Sets VcfEdgeatScaleRootDirectory for the current session. On
        Windows, persists it via [System.Environment]::SetEnvironmentVariable (User scope). On macOS/Linux,
        automatically appends the export line to $PROFILE so new sessions inherit it. Prints a fallback
        manual command if the Windows persist step fails. Other switches are ignored except -LogLevel and
        -InitializeTemplatesOnly.

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

        Runs interactive setup to create the configuration directory layout, copy templates, and print VcfEdgeatScaleRootDirectory profile instructions.

    .EXAMPLE
        Start-VcfEdgeAtScale -Initialize -InitializeTemplatesOnly

        Refreshes YAML and Docs from the module into an existing (or new) base directory without changing root JSON files.

    .EXAMPLE
        Start-VcfEdgeAtScale -CollectLogs

        Prompts for JSON sources and zips deployment files, Logs, and ServicesYaml to the user home directory.

    .EXAMPLE
        Start-VcfEdgeAtScale

        Executes the deployment using infrastructure.json and supervisor.json under $env:VcfEdgeatScaleRootDirectory when those parameters are omitted.

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

    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $false)] [Switch]$AcceptBadCheckResults,
        [Parameter(Mandatory = $false)] [Switch]$CheckForUpdates,
        [Parameter(Mandatory = $false)] [ValidateSet("All", "ArgoCD", "Compute", "Harbor", "Supervisor")] [String]$CleanUp,
        [Parameter(Mandatory = $false)] [Switch]$CollectLogs,
        [Parameter(Mandatory = $false)] [Switch]$ComputeOnly,
        [Parameter(Mandatory = $false)] [ValidateRange(0, 300)] [Int]$DelayBeforeAddingNextHostSeconds = 0,
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$EdgeSite,
        [Parameter(Mandatory = $false)] [Switch]$Force,
        [Parameter(Mandatory = $false)] [Switch]$Initialize,
        [Parameter(Mandatory = $false)] [Switch]$InitializeTemplatesOnly,
        [Parameter(Mandatory = $false)] [String]$InfrastructureJson,
        [Parameter(Mandatory = $false)] [ValidateSet("DEBUG", "INFO", "ADVISORY", "WARNING", "EXCEPTION", "ERROR")] [String]$LogLevel = "INFO",
        [Parameter(Mandatory = $false)] [Nullable[bool]]$RollbackOnFailure,
        [Parameter(Mandatory = $false)] [Switch]$SaveHarborYaml,
        [Parameter(Mandatory = $false)] [String]$SupervisorJson,
        [Parameter(Mandatory = $false)] [Switch]$ValidateOnly,
        [Parameter(Mandatory = $false)] [Switch]$Version
    )

    # Initialize configured log level from parameter (normalize to uppercase). Set before -Version so Write-LogMessage honors the threshold.
    $Script:ConfiguredLogLevel = $LogLevel.ToUpper()

    if ($Initialize -and $CollectLogs) {
        throw "Do not combine -Initialize with -CollectLogs."
    }
    if ($CollectLogs -and $InitializeTemplatesOnly) {
        throw "Do not combine -CollectLogs with -InitializeTemplatesOnly."
    }
    if ($CollectLogs -and $Version) {
        throw "Do not combine -CollectLogs with -Version."
    }

    if ($InitializeTemplatesOnly -and -not $Initialize) {
        throw "InitializeTemplatesOnly must be used with -Initialize. Example: Start-VcfEdgeAtScale -Initialize -InitializeTemplatesOnly"
    }

    if ($Initialize) {
        $deploymentParameterNames = @(
            "AcceptBadCheckResults",
            "CheckForUpdates",
            "CleanUp",
            "CollectLogs",
            "ComputeOnly",
            "DelayBeforeAddingNextHostSeconds",
            "EdgeSite",
            "Force",
            "InfrastructureJson",
            "RollbackOnFailure",
            "SaveHarborYaml",
            "SupervisorJson",
            "ValidateOnly",
            "Version"
        )
        $ignoredParameterNames = @()
        foreach ($boundParameterName in $PSBoundParameters.Keys) {
            if ($deploymentParameterNames -contains $boundParameterName) {
                $ignoredParameterNames += $boundParameterName
            }
        }
        if ($ignoredParameterNames.Count -gt 0) {
            Write-Output "Note: -Initialize runs alone; ignoring these parameters for this run: $($ignoredParameterNames -join ', ')."
        }
        $initBaseDirectory = Invoke-VcfEdgeAtScaleModuleInitialize -TemplatesOnly:$InitializeTemplatesOnly
        if (-not [String]::IsNullOrWhiteSpace($initBaseDirectory) -and (Test-Path -LiteralPath $initBaseDirectory -PathType Container)) {
            New-LogFile -BaseDirectory $initBaseDirectory -Directory "Logs"
        }

        # Print next-step hints for customizing JSON; direct editing first, browser UI second.
        $pyExe = (Get-PythonExecutable)?.Executable ?? "python3"
        Write-Host ""
        Write-Host "  Next step: customize infrastructure.json and supervisor.json." -ForegroundColor Cyan
        Write-Host "  Option 1 — Direct JSON editing:" -ForegroundColor White
        Write-Host "    Open infrastructure.json and supervisor.json in any text editor." -ForegroundColor Gray
        Write-Host "    Run 'Start-VcfEdgeAtScale -ValidateOnly' to validate before deploying." -ForegroundColor Gray
        $toolScript = Join-Path $initBaseDirectory "Tools" "veas-json-generator.py"
        Write-Host "  Option 2 — Browser-based UI:" -ForegroundColor White
        if (-not [String]::IsNullOrWhiteSpace($initBaseDirectory) -and (Test-Path -LiteralPath $toolScript)) {
            Write-Host "    $pyExe `"$toolScript`"" -ForegroundColor Gray
        } else {
            Write-Host "    $pyExe `"<base-dir>\Tools\veas-json-generator.py`"" -ForegroundColor Gray
        }

        return
    }

    if ($CollectLogs) {
        $deploymentParameterNamesForCollectLogs = @(
            "AcceptBadCheckResults",
            "CheckForUpdates",
            "CleanUp",
            "ComputeOnly",
            "DelayBeforeAddingNextHostSeconds",
            "EdgeSite",
            "Force",
            "InfrastructureJson",
            "Initialize",
            "InitializeTemplatesOnly",
            "LogLevel",
            "RollbackOnFailure",
            "SaveHarborYaml",
            "SupervisorJson",
            "ValidateOnly",
            "Version"
        )
        $ignoredParameterNamesForCollectLogs = @()
        foreach ($boundParameterName in $PSBoundParameters.Keys) {
            if ($deploymentParameterNamesForCollectLogs -contains $boundParameterName) {
                $ignoredParameterNamesForCollectLogs += $boundParameterName
            }
        }
        if ($ignoredParameterNamesForCollectLogs.Count -gt 0) {
            Write-Output "Note: -CollectLogs runs alone; ignoring these parameters for this run: $($ignoredParameterNamesForCollectLogs -join ', ')."
        }
        $null = Invoke-VcfEdgeAtScaleCollectLogs
        return
    }

    if ($Version) {
        $versionLogBase = $env:VcfEdgeatScaleRootDirectory
        if (-not [String]::IsNullOrWhiteSpace($versionLogBase) -and (Test-Path -LiteralPath $versionLogBase.Trim() -PathType Container)) {
            New-LogFile -BaseDirectory $versionLogBase.Trim() -Directory "Logs"
        } else {
            New-LogFile
        }
        $versionToDisplay = $null

        # Try to get version from loaded module first.

        $loadedModule = Get-Module -Name "VcfEdgeAtScale"
        if ($loadedModule -and $loadedModule.Version -and $loadedModule.Version -ne [version]"0.0") {
            $versionToDisplay = $loadedModule.Version.ToString()
        } else {
            # Try to get version from manifest file.

            $modulePath = $null
            if ($PSScriptRoot) {
                $modulePath = $PSScriptRoot
            } else {
                # Try to find module path from loaded module.

                $moduleInfo = Get-Module -Name "VcfEdgeAtScale" -ListAvailable | Select-Object -First 1
                if ($moduleInfo -and $moduleInfo.ModuleBase) {
                    $modulePath = $moduleInfo.ModuleBase
                }
            }

            if ($modulePath) {
                $manifestPath = Join-Path $modulePath "VcfEdgeAtScale.psd1"
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

            # Fall back to script variable if we couldn't get version from manifest.
            if (-not $versionToDisplay) {
                $versionToDisplay = $Script:ModuleVersion
            }
        }

        Write-LogMessage -Type INFO -Message "VcfEdgeAtScale version: $versionToDisplay"
        return
    }

    if ($CheckForUpdates) {
        $checkLogBase = $env:VcfEdgeatScaleRootDirectory
        if (-not [String]::IsNullOrWhiteSpace($checkLogBase) -and (Test-Path -LiteralPath $checkLogBase.Trim() -PathType Container)) {
            New-LogFile -BaseDirectory $checkLogBase.Trim() -Directory "Logs"
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

    $vcfEdgeRootRaw = $env:VcfEdgeatScaleRootDirectory
    if ([String]::IsNullOrWhiteSpace($vcfEdgeRootRaw)) {
        $exampleVcfEdgeRootDirectory = Join-Path -Path $HOME -ChildPath "VCFEdgeAtScale"
        Write-Warning (
            "VcfEdgeatScaleRootDirectory is not set. Run Start-VcfEdgeAtScale -Initialize, or set it for this session. " +
            "The following is an example only (your default Initialize path is Join-Path `$HOME 'VCFEdgeAtScale'; use the directory you chose at Initialize if different): " +
            "`$env:VcfEdgeatScaleRootDirectory = `"$exampleVcfEdgeRootDirectory`""
        )
        return
    }

    try {
        $vcfEdgeRootDirectory = (Resolve-Path -LiteralPath $vcfEdgeRootRaw.Trim()).Path
    } catch {
        throw "VcfEdgeatScaleRootDirectory is set but the path could not be resolved. Ensure the directory exists. Value: $vcfEdgeRootRaw. $($_.Exception.Message)"
    }

    if (-not $PSBoundParameters.ContainsKey("InfrastructureJson") -or [String]::IsNullOrWhiteSpace($InfrastructureJson)) {
        $InfrastructureJson = Join-Path -Path $vcfEdgeRootDirectory -ChildPath "infrastructure.json"
    }
    if (-not $PSBoundParameters.ContainsKey("SupervisorJson") -or [String]::IsNullOrWhiteSpace($SupervisorJson)) {
        $SupervisorJson = Join-Path -Path $vcfEdgeRootDirectory -ChildPath "supervisor.json"
    }
    if ([String]::IsNullOrWhiteSpace($InfrastructureJson)) {
        throw "InfrastructureJson resolved to an empty path. Provide -InfrastructureJson or fix VcfEdgeatScaleRootDirectory."
    }
    if ([String]::IsNullOrWhiteSpace($SupervisorJson)) {
        throw "SupervisorJson resolved to an empty path. Provide -SupervisorJson or fix VcfEdgeatScaleRootDirectory."
    }

    New-LogFile -BaseDirectory $vcfEdgeRootDirectory -Directory "Logs"

    $savedProgressPreference = $Global:ProgressPreference
    try {
        $Global:ProgressPreference = "Continue"

        # Rollback on failure: only set from parameter when explicitly passed; omitted = prompt (Y/N/Always). $true = always rollback (no prompt), $false = never rollback.
        if ($PSBoundParameters.ContainsKey("RollbackOnFailure")) {
            $Script:RollbackOnFailurePreference = $RollbackOnFailure
        } else {
            $Script:RollbackOnFailurePreference = $null
        }
        $Script:RollbackAlwaysFromPrompt = $false
        $Script:CleanUpOnly = $false

        # Enforce VCF.PowerCLI minimum even when today's log file already existed (New-LogFile only runs Get-EnvironmentSetup on first creation).
        Initialize-ScriptVcfPowerCliModuleVersion -MinimumVcfPowerCliVersion "9.0.0"

        # Silently refresh help JSON files in Docs if the module has been upgraded since they were last copied.
        try {
            $helpTemplatesPath = Get-ModuleTemplatesPath
            $helpDocsDirectory = Join-Path -Path $vcfEdgeRootDirectory -ChildPath "Docs"
            foreach ($helpFileName in @("infrastructure-config-help.json", "supervisor-config-help.json")) {
                $null = Update-HelpJsonIfStale `
                    -DocsPath (Join-Path -Path $helpDocsDirectory -ChildPath $helpFileName) `
                    -TemplatePath (Join-Path -Path $helpTemplatesPath -ChildPath $helpFileName)
            }
        } catch {
            Write-LogMessage -Type DEBUG -Message "Help JSON auto-refresh skipped: $($_.Exception.Message)"
        }

        # Log the configured log level.
        Write-LogMessage -Type DEBUG -Message "Log level set to: $Script:ConfiguredLogLevel (screen output filtered, all levels written to file)"

        # Perform validation with progress indication.
        Write-Output ""
        $validationStartTime = Get-Date
        $inputData = ConvertFrom-JsonSafely -JsonFilePath $InfrastructureJson
        if ($null -eq $inputData) {
            throw "[E-CONFIG-NULL-001] Infrastructure JSON produced no data after load. Check logs for details."
        }
        Update-InfrastructureJsonReferencedFilePaths -InfrastructureJsonPath $InfrastructureJson -InputData $inputData
        if ($EdgeSite) {
            $edgeSitesArrayForValidation = Get-EdgeSitesFromParameter -EdgeSite $EdgeSite -InputData $inputData
        } else {
            $edgeSitesArrayForValidation = @()
        }
        $siteIndication = if ($edgeSitesArrayForValidation.Count -gt 0) { "edgeSite(s) `"$($edgeSitesArrayForValidation -join '", "')`"" } else { "all sites" }

        # Validate YAML file existence for required ArgoCD and Harbor files (cheap operation, do this first). Skip when -CleanUp is set (cleanup does not use deployment YAMLs). Skip when -ComputeOnly (no supervisor or services).
        if ($CleanUp -notin @("Supervisor", "Compute", "All", "ArgoCD", "Harbor") -and -not $ComputeOnly) {
            Write-LogMessage -Type DEBUG -Message "Validating YAML file existence for $siteIndication..."
            $yamlValidationStartTime = Get-Date
            $clustersToCheck = if ($edgeSitesArrayForValidation.Count -gt 0) {
                $inputData.clusters | Where-Object { $_.edgeSite -in $edgeSitesArrayForValidation }
            } else {
                $inputData.clusters
            }

            $missingYamlFiles = @()
            foreach ($cluster in $clustersToCheck) {
                $currentEdgeSite = $cluster.edgeSite

                # Skip ArgoCD YAML validation for clusters where ArgoCD is disabled.
                if (Get-EffectiveSupervisorServiceFlag -Cluster $cluster -CommonData $inputData.common -FlagName "disableArgoCD") {
                    Write-LogMessage -Type DEBUG -Message "ArgoCD is disabled for edgeSite `"$currentEdgeSite`"; skipping ArgoCD YAML path validation."
                    continue
                }

                $argoCdOperatorYamlPath = Get-EffectiveArgoCdYamlPath -Cluster $cluster -CommonData $inputData.common -PropertyName "argoCdOperatorYamlPath"
                $argoCdDeploymentYamlPath = Get-EffectiveArgoCdYamlPath -Cluster $cluster -CommonData $inputData.common -PropertyName "argoCdDeploymentYamlPath"

                if ($argoCdOperatorYamlPath) {
                    if (-not (Test-Path -LiteralPath $argoCdOperatorYamlPath)) {
                        $missingYamlFiles += [PSCustomObject]@{
                            EdgeSite = $currentEdgeSite
                            FileType = "ArgoCD Operator YAML"
                            FilePath = $argoCdOperatorYamlPath
                        }
                    }
                } else {
                    $missingYamlFiles += [PSCustomObject]@{
                        EdgeSite = $currentEdgeSite
                        FileType = "ArgoCD Operator YAML"
                        FilePath = "Not specified in configuration"
                    }
                }

                if ($argoCdDeploymentYamlPath) {
                    if (-not (Test-Path -LiteralPath $argoCdDeploymentYamlPath)) {
                        $missingYamlFiles += [PSCustomObject]@{
                            EdgeSite = $currentEdgeSite
                            FileType = "ArgoCD Deployment YAML"
                            FilePath = $argoCdDeploymentYamlPath
                        }
                    }
                } else {
                    $missingYamlFiles += [PSCustomObject]@{
                        EdgeSite = $currentEdgeSite
                        FileType = "ArgoCD Deployment YAML"
                        FilePath = "Not specified in configuration"
                    }
                }
            }

            # Harbor YAML validation: paths are Join-Path(supervisorServices.parentDirectory, *YamlFileName) with cluster/common fallback.
            foreach ($cluster in $clustersToCheck) {
                if (Get-EffectiveSupervisorServiceFlag -Cluster $cluster -CommonData $inputData.common -FlagName "disableHarbor") {
                    continue
                }
                $currentEdgeSite = $cluster.edgeSite
                $harborServiceYamlPathForValidation = Get-EffectiveSupervisorServicesYamlPath -Cluster $cluster -CommonData $inputData.common -LogicalYamlPathPropertyName "harborServiceYamlPath"
                if ($harborServiceYamlPathForValidation) {
                    if (-not (Test-Path -LiteralPath $harborServiceYamlPathForValidation)) {
                        $missingYamlFiles += [PSCustomObject]@{
                            EdgeSite = $currentEdgeSite
                            FileType = "Harbor Service YAML"
                            FilePath = $harborServiceYamlPathForValidation
                        }
                    }
                } else {
                    $missingYamlFiles += [PSCustomObject]@{
                        EdgeSite = $currentEdgeSite
                        FileType = "Harbor Service YAML"
                        FilePath = "Not specified (supervisorServices.parentDirectory / harborServiceYamlFileName)"
                    }
                }
                $harborDataValuesTemplatePath = Get-EffectiveSupervisorServicesYamlPath -Cluster $cluster -CommonData $inputData.common -LogicalYamlPathPropertyName "harborDataTemplateYamlPath"
                if ($harborDataValuesTemplatePath) {
                    if (-not (Test-Path -LiteralPath $harborDataValuesTemplatePath)) {
                        $missingYamlFiles += [PSCustomObject]@{
                            EdgeSite = $currentEdgeSite
                            FileType = "Harbor Data Values YAML template"
                            FilePath = $harborDataValuesTemplatePath
                        }
                    }
                } else {
                    $missingYamlFiles += [PSCustomObject]@{
                        EdgeSite = $currentEdgeSite
                        FileType = "Harbor Data Values YAML template"
                        FilePath = "Not specified (supervisorServices.parentDirectory / harborDataTemplateYamlFileName)"
                    }
                }
            }

            if ($missingYamlFiles.Count -gt 0) {
                $errorMessage = "Required YAML files are missing or not accessible:`n"
                foreach ($missingFile in $missingYamlFiles) {
                    $errorMessage += "  - EdgeSite `"$($missingFile.EdgeSite)`": $($missingFile.FileType) - $($missingFile.FilePath)`n"
                }
                Write-LogMessage -Type ERROR -Message $errorMessage
                Write-LogMessage -Type ERROR -Message "Deployment cannot proceed without required YAML files. Please ensure all YAML files exist at the specified paths and try again."
                throw "[E-YAML-MISSING-001] Required YAML files are missing or not accessible. Check logs for details."
            }

            $yamlValidationElapsed = (Get-Date) - $yamlValidationStartTime
            Write-LogMessage -Type DEBUG -Message "YAML file validation completed for $siteIndication in $($yamlValidationElapsed.TotalSeconds.ToString('F2')) seconds."
        } elseif ($ComputeOnly) {
            Write-LogMessage -Type DEBUG -Message "ComputeOnly: skipping YAML file existence validation (Argo CD and Harbor are not deployed)."
        } else {
            Write-LogMessage -Type DEBUG -Message "Not performing YAML validation during cleanup."
        }

        # During cleanup, skip full JSON validation (shallow, deeper, network segment). Initialize-VcfEdgeAtScale will parse the JSON and resolve edge sites; invalid JSON will fail there.
        if ($CleanUp -in @("Supervisor", "Compute", "All", "ArgoCD", "Harbor")) {
            Write-LogMessage -Type DEBUG -Message "Cleanup mode: skipping full JSON validation; configuration will be parsed in Initialize-VcfEdgeAtScale."
        } else {
            Write-LogMessage -Type DEBUG -Message "Validating JSON configuration files for $siteIndication..."

            # Perform shallow validation of input.json and supervisor.json configuration files (presence of properties only).
            $shallowValidationStartTime = Get-Date
            Write-LogMessage -Type INFO -Message "Checking for required JSON properties for $siteIndication..."
            $shallowValidationParams = @{
                InfrastructureJson = $InfrastructureJson
                SupervisorJson = $SupervisorJson
            }
            if ($ComputeOnly) {
                $shallowValidationParams.ComputeOnly = $true
            }
            if ($EdgeSite) {
                $shallowValidationParams.EdgeSite = $EdgeSite
            }
            try {
                Test-JsonShallowValidation @shallowValidationParams
                $shallowValidationElapsed = (Get-Date) - $shallowValidationStartTime
                $totalElapsed = (Get-Date) - $validationStartTime
                Write-LogMessage -Type DEBUG -Message "Required properties validation completed for $siteIndication in $($shallowValidationElapsed.TotalSeconds.ToString('F2')) seconds (Total elapsed: $($totalElapsed.TotalSeconds.ToString('F2'))s)."
            } catch {
                $shallowValidationElapsed = (Get-Date) - $shallowValidationStartTime
                Write-LogMessage -Type ERROR -Message "Required properties validation failed for $siteIndication after $($shallowValidationElapsed.TotalSeconds.ToString('F2')) seconds."
                throw
            }

            # Daily auto update check: runs at most once per day (keyed to new log file creation).
            # Placed after shallow validation so config errors surface before any update prompt.
            if ($Script:NewLogFileCreatedThisSession) {
                try {
                    Invoke-VcfEdgeAtScaleUpdateCheck -Quiet -InputData $inputData
                } catch {
                    Write-LogMessage -Type DEBUG -Message "Daily update check failed silently: $($_.Exception.Message)"
                }
            }

        # Perform deeper validation of input.json and supervisor.json configuration files (pattern matching of values).
        $deeperValidationStartTime = Get-Date
        Write-LogMessage -Type INFO -Message "Validating property formats and values for $siteIndication..."
        $deeperValidationParams = @{
            InfrastructureJson = $InfrastructureJson
            SupervisorJson = $SupervisorJson
        }
        if ($ComputeOnly) {
            $deeperValidationParams.ComputeOnly = $true
        }
        if ($EdgeSite) {
            $deeperValidationParams.EdgeSite = $EdgeSite
        }
        try {
            Test-JsonDeeperValidation @deeperValidationParams
            $deeperValidationElapsed = (Get-Date) - $deeperValidationStartTime
            $totalElapsed = (Get-Date) - $validationStartTime
            Write-LogMessage -Type DEBUG -Message "Property format validation completed for $siteIndication in $($deeperValidationElapsed.TotalSeconds.ToString('F2')) seconds (Total elapsed: $($totalElapsed.TotalSeconds.ToString('F2'))s)."
        } catch {
            $deeperValidationElapsed = (Get-Date) - $deeperValidationStartTime
            Write-LogMessage -Type ERROR -Message "Property format validation failed for $siteIndication after $($deeperValidationElapsed.TotalSeconds.ToString('F2')) seconds."
            throw
        }

        # Network segment name uniqueness validation (reuse parsed infrastructure object; paths already updated).
        $networkValidationStartTime = Get-Date
        Write-LogMessage -Type DEBUG -Message "Validating network segment names for $siteIndication..."

        # Validate network segment name uniqueness within infrastructure.json.
        $networkSegmentValidationParams = @{
            InputData = $inputData
        }
        if ($EdgeSite) {
            $networkSegmentValidationParams.EdgeSite = $EdgeSite
        }
        $networkSegmentNameValidationResult = Test-NetworkSegmentNameUniqueness @networkSegmentValidationParams
        if (-not $networkSegmentNameValidationResult.IsValid) {
            Write-LogMessage -Type ERROR -SuppressOutputToScreen -Message "Network segment name uniqueness validation failed: $($networkSegmentNameValidationResult.ErrorMessage)"
            Write-LogMessage -Type ERROR -Message "Deployment cannot proceed with duplicate network segment names. Please fix the naming conflicts and try again."
            throw "[E-NETSEG-001] Network segment name uniqueness validation failed: $($networkSegmentNameValidationResult.ErrorMessage)"
        } else {
            Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "Network segment name uniqueness validation passed."
        }
        $networkValidationElapsed = (Get-Date) - $networkValidationStartTime
        $totalElapsed = (Get-Date) - $validationStartTime
        Write-LogMessage -Type DEBUG -Message "Network segment name validation completed for $siteIndication in $($networkValidationElapsed.TotalSeconds.ToString('F2')) seconds (Total elapsed: $($totalElapsed.TotalSeconds.ToString('F2'))s)."

        # ESX host uniqueness validation: each ESX host must appear in exactly one edge site.
        Write-LogMessage -Type DEBUG -Message "Validating ESX host uniqueness across all clusters..."
        $esxHostValidationResult = Test-EsxHostUniqueness -InputData $inputData
        if (-not $esxHostValidationResult.IsValid) {
            Write-LogMessage -Type ERROR -SuppressOutputToScreen -Message "ESX host uniqueness validation failed: $($esxHostValidationResult.ErrorMessage)"
            Write-LogMessage -Type ERROR -Message "Deployment cannot proceed with duplicate ESX hosts. Each host must belong to exactly one edge site."
            throw "[E-ESXHOST-001] ESX host uniqueness validation failed: $($esxHostValidationResult.ErrorMessage)"
        } else {
            Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "ESX host uniqueness validation passed."
        }

        # Complete validation (only reached if all validations passed).
        $validationEndTime = Get-Date
        $totalValidationTime = $validationEndTime - $validationStartTime
        Write-LogMessage -Type DEBUG -Message "JSON configuration validation completed successfully for $siteIndication in $($totalValidationTime.TotalSeconds.ToString('F2')) seconds."
    }

    # When -ValidateOnly, exit after validation without deploying or cleaning up.
    if ($ValidateOnly) {
        Write-LogMessage -Type INFO -Message "ValidateOnly: validation passed. Exiting without deployment."
        return
    }

    # If -CleanUp was specified but value is null or empty, show usage and return.
    if ($PSBoundParameters.ContainsKey("CleanUp") -and [String]::IsNullOrWhiteSpace($CleanUp)) {
        Write-LogMessage -Type WARNING -Message "-CleanUp requires one of: Supervisor, Compute, All, ArgoCD, Harbor."
        Write-Output ""
        Write-Output "Usage: -CleanUp must be one of: Supervisor, Compute, All, ArgoCD, Harbor"
        Write-Output "  Supervisor - Remove only the supervisor (compute remains)."
        Write-Output "  Compute   - Remove only compute (VDS, vSAN/VMFS, cluster); fails if supervisor is deployed."
        Write-Output "  All       - Remove supervisor first, then compute."
        Write-Output "  ArgoCD    - Remove only the ArgoCD supervisor namespace for each cluster."
        Write-Output "  Harbor    - Remove only the Harbor Supervisor Service from the supervisor for each cluster."
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
                Write-Output "Usage: -CleanUp must be one of: Supervisor, Compute, All, ArgoCD, Harbor"
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
    } catch {
        # Surface a friendly log-collection hint whenever deployment exits with an error.
        # The original exception is rethrown so the caller (or PowerShell itself) still sees it.
        Write-Host ""
        if (-not [String]::IsNullOrWhiteSpace($Script:LogFile) -and (Test-Path -LiteralPath $Script:LogFile -PathType Leaf)) {
            Write-Host "Deployment failed. Log file: $Script:LogFile" -ForegroundColor Red
            Write-Host "To collect logs and configuration for support, run:" -ForegroundColor Yellow
            Write-Host "  Start-VcfEdgeAtScale -CollectLogs" -ForegroundColor Yellow
        } else {
            Write-Host "Deployment failed. No log file was created (check prerequisites)." -ForegroundColor Red
        }
        Write-Host ""
        throw
    } finally {
        $Global:ProgressPreference = $savedProgressPreference
    }
}
Function Show-VcfEdgeAtScaleVersion {

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
    param()

    Write-LogMessage -Type INFO -Message "VcfEdgeAtScale version: $Script:ModuleVersion"
}
Function Get-ModuleTemplatesPath {

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

    Param ()

    $moduleBase = $null
    if ($MyInvocation.MyCommand.Module.ModuleBase) {
        $moduleBase = $MyInvocation.MyCommand.Module.ModuleBase
    } elseif ($PSScriptRoot) {
        $moduleBase = $PSScriptRoot
        $templatesCheck = Join-Path $moduleBase "Templates"
        if (-not (Test-Path $templatesCheck)) {
            $subDirCheck = Join-Path $moduleBase (Join-Path "VcfEdgeAtScale" "Templates")
            if (Test-Path $subDirCheck) {
                $moduleBase = Join-Path $moduleBase "VcfEdgeAtScale"
            }
        }
    } else {
        $moduleInfo = Get-Module -Name "VcfEdgeAtScale" -ListAvailable | Select-Object -First 1
        if ($moduleInfo -and $moduleInfo.ModuleBase) {
            $moduleBase = $moduleInfo.ModuleBase
        }
    }

    if (-not $moduleBase) {
        Write-LogMessage -Type ERROR -Message "Unable to determine module installation path. Please ensure the module is installed correctly."
        throw "Unable to determine module installation path. Please ensure the module is installed correctly."
    }

    $templatesPath = Join-Path $moduleBase "Templates"
    if (-not (Test-Path $templatesPath)) {
        Write-LogMessage -Type ERROR -Message "Templates directory not found at: $templatesPath."
        throw "Templates directory not found at: $templatesPath."
    }

    return $templatesPath
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

    Param (
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)] [PSCustomObject[]]$InputObject
    )

    Begin {
        $allItems = @()
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
                            $allItems += $item
                        }
                    }
                }
            } else {
                if ($null -ne $InputObject.Key) {
                    $key = $InputObject.Key
                    if (-not $seenKeys.ContainsKey($key)) {
                        $seenKeys[$key] = $true
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

        $allItems | Format-Table -Property 'Key', 'Required', 'Notes' -AutoSize -Wrap
    }
}
Function Get-ModulePublicVersion {

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
    #>

    $parts = $Script:ModuleVersion -split '\.'
    if ($parts.Count -ge 4) {
        # Strip the 4th (build) segment; return Major.Minor.Patch.
        return ($parts[0..2] -join '.')
    }
    return $Script:ModuleVersion
}
Function Update-HelpJsonIfStale {
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
    #>
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$DocsPath,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$TemplatePath
    )

    if (-not (Test-Path -LiteralPath $TemplatePath -PathType Leaf)) {
        Write-Warning "Help JSON template not found at '$TemplatePath'. Skipping auto-refresh for '$DocsPath'."
        return $false
    }

    # Read the template version as the authoritative source.
    $templateVersion = $null
    try {
        $templateJson = Get-Content -Path $TemplatePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $templateVersion = if ($templateJson -is [Array]) { $null } else { $templateJson.moduleVersion }
    } catch {
        Write-Warning "Could not read template help JSON at '$TemplatePath': $($_.Exception.Message). Skipping auto-refresh."
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
            $docsJson = Get-Content -Path $DocsPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
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
        Write-Warning "Could not update help JSON at '$DocsPath': $($_.Exception.Message)."
        return $false
    }
}
Function Get-ConfigurationHelpData {
    <#
        .SYNOPSIS
        Loads and validates a configuration help JSON file from the deployment Docs directory or module Templates directory.

        .DESCRIPTION
        When $env:VcfEdgeatScaleRootDirectory is set and Join-Path(Docs, HelpFileName) exists under that root, that file is loaded first so operators can refresh help JSON beside their deployment files. Otherwise the module Templates path is used. The function validates array structure and required fields (Key, Required, Notes), optionally filters by Key wildcard, and returns an array of PSCustomObject. Returns $null on any failure (path, file missing, invalid JSON, validation). Used by Show-InfrastructureJsonConfigurationHelp and Show-SupervisorJsonConfigurationHelp.

        .PARAMETER HelpFileName
        Name of the help JSON file (e.g. "infrastructure-config-help.json", "supervisor-config-help.json").

        .PARAMETER Filter
        Optional wildcard filter applied to Key. Filter is wrapped with * on both sides (e.g. "argoCD" matches *argoCD*).

        .OUTPUTS
        PSCustomObject[]. Array of configuration help entries, or $null on failure.

        .NOTES
        Uses Get-ModuleTemplatesPath; on failure writes Warning and returns $null. Does not throw.
    #>
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$HelpFileName,
        [Parameter(Mandatory = $false)] [AllowNull()] [String]$Filter
    )

    try {
        $templatesPath = Get-ModuleTemplatesPath
    } catch {
        Write-Warning "Unable to locate module Templates directory. Please ensure the module is installed correctly."
        return $null
    }

    $templateHelpJsonPath = Join-Path $templatesPath $HelpFileName
    $helpJsonPath = $null
    $vcfEdgeRootForHelp = $env:VcfEdgeatScaleRootDirectory
    if (-not [String]::IsNullOrWhiteSpace($vcfEdgeRootForHelp)) {
        $docsHelpCandidatePath = Join-Path -Path $vcfEdgeRootForHelp.Trim() -ChildPath (Join-Path -Path "Docs" -ChildPath $HelpFileName)
        if (Test-Path -LiteralPath $docsHelpCandidatePath -PathType Leaf) {
            try {
                $resolvedDocsPath = (Resolve-Path -LiteralPath $docsHelpCandidatePath).Path
            } catch {
                $resolvedDocsPath = $docsHelpCandidatePath
            }

            # Check whether the Docs copy is current; if version differs, fall through to Templates.
            # Compare against the 3-part public version (strips the 4th build segment) so that
            # build upgrades (e.g. 1.0.3.1000 → 1.0.3.1001) do not invalidate the Docs copy.
            $docsVersionMatches = $false
            try {
                $docsRaw = Get-Content -Path $resolvedDocsPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
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
        Write-Warning "Configuration help file not found at: $helpJsonPath. Please verify the module installation."
        return $null
    }

    if (-not (Test-JsonFile -JsonFilePath $helpJsonPath)) {
        Write-Warning "Configuration help file at '$helpJsonPath' contains invalid JSON or cannot be read. Please verify the file exists and contains valid JSON."
        return $null
    }

    try {
        $jsonContent = Get-Content -Path $helpJsonPath -Raw -ErrorAction Stop
        $jsonData = $jsonContent | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Write-Warning "Failed to parse configuration help file at '$helpJsonPath': $($_.Exception.Message). Please verify the file contains valid JSON."
        return $null
    }

    if ($null -eq $jsonData) {
        Write-Warning "Configuration help file at '$helpJsonPath' parsed but returned null. File may be empty or malformed."
        return $null
    }

    # Support both legacy bare-array format and wrapped { moduleVersion, entries } format.
    $entriesArray = if ($jsonData -is [Array]) { $jsonData } else { $jsonData.entries }

    if ($null -eq $entriesArray -or $entriesArray -isnot [Array]) {
        Write-Warning "Configuration help file at '$helpJsonPath' must contain an array of configuration elements (or an object with an 'entries' array)."
        return $null
    }

    if ($entriesArray.Count -eq 0) {
        Write-Warning "Configuration help file at '$helpJsonPath' contains no configuration elements."
        return $null
    }

    $requiredFields = @('Key', 'Required', 'Notes')
    $config = @()
    foreach ($entry in $entriesArray) {
        $missingFields = @()
        foreach ($field in $requiredFields) {
            if (-not $entry.PSObject.Properties[$field] -or [string]::IsNullOrWhiteSpace($entry.$field)) {
                $missingFields += $field
            }
        }
        if ($missingFields.Count -gt 0) {
            Write-Warning "Configuration help file at '$helpJsonPath' contains entries missing required fields: $($missingFields -join ', '). Each entry must have: Key, Required, Notes."
            return $null
        }
        $config += [PSCustomObject]@{
            'Key' = $entry.Key
            'Required' = $entry.Required
            'Notes' = $entry.Notes
        }
    }

    if ($Filter) {
        $filterPattern = "*$Filter*"
        $config = @($config | Where-Object { $_.Key -like $filterPattern })
        if ($config.Count -eq 0) {
            Write-Warning "No configuration elements found matching filter: $Filter"
            return $null
        }
    }

    return $config
}
Function Show-ConfigurationHelpTable {

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
    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Title,
        [Parameter(Mandatory = $true)] [AllowNull()] [Array]$Config,
        [Parameter(Mandatory = $true)] [ValidateSet('Auto', 'GridView', 'List', 'Table')] [String]$Format,
        [Parameter(Mandatory = $false)] [ValidateRange(40, [int]::MaxValue)] [Int]$WidthThreshold = 120
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

    Write-Output "`n"
    Write-LogMessage -Type INFO -Message ("=" * $lineWidth)
    Write-LogMessage -Type INFO -Message $Title
    Write-LogMessage -Type INFO -Message ("=" * $lineWidth)
    Write-Output "`n"

    switch ($resolvedFormat) {
        'GridView' {
            $gridViewAvailable = $null -ne (Get-Command -Name 'Out-GridView' -ErrorAction SilentlyContinue)
            if ($gridViewAvailable) {
                $Config | Out-GridView -Title $Title
            } else {
                Write-Warning "Out-GridView is not available on this system (typically only available on Windows PowerShell). Using List format instead."
                $Config | Format-List -Property 'Key', 'Required', 'Notes'
            }
        }
        'List' {
            $Config | Format-List -Property 'Key', 'Required', 'Notes'
        }
        'Table' {
            try {
                $Config | Format-ConfigurationTable
            } catch {
                Write-Warning "Failed to format configuration table: $($_.Exception.Message)"
                Write-LogMessage -Type INFO -Message "Displaying configuration as list format:"
                $Config | Format-List -Property 'Key', 'Required', 'Notes'
            }
        }
    }

    Write-Output "`n"
}
Function Show-InfrastructureJsonConfigurationHelp {

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
        [Parameter(Mandatory = $false)] [ValidateRange(40, [int]::MaxValue)] [Int]$WidthThreshold = 120
    )

    $config = Get-ConfigurationHelpData -HelpFileName "infrastructure-config-help.json" -Filter $Filter
    if ($null -ne $config) {
        Show-ConfigurationHelpTable -Config $config -Format $Format -Title "Infrastructure.json Configuration Reference" -WidthThreshold $WidthThreshold
    }
}
Function Show-SupervisorJsonConfigurationHelp {

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
        [Parameter(Mandatory = $false)] [ValidateRange(40, [int]::MaxValue)] [Int]$WidthThreshold = 120
    )

    $config = Get-ConfigurationHelpData -HelpFileName "supervisor-config-help.json" -Filter $Filter
    if ($null -ne $config) {
        Show-ConfigurationHelpTable -Config $config -Format $Format -Title "Supervisor.json Configuration Reference" -WidthThreshold $WidthThreshold
    }
}

#endregion
