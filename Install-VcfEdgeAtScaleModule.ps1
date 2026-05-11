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

#Requires -Version 7.4

<#
.SYNOPSIS
    Manually installs the VcfEdgeAtScale PowerShell module cross-platform.

.DESCRIPTION
    Copies VcfEdgeAtScale.psd1, VcfEdgeAtScale.psm1, PSScriptAnalyzerSettings.psd1,
    Private, Templates, and Tools into the first path in $env:PSModulePath for the
    current platform (Windows, Linux, or macOS). Validates the installed manifest
    before completing. Python __pycache__ directories are excluded from the copy.

    If the module is currently loaded in the session it is removed before the
    files are overwritten and reloaded afterward, so the in-memory version
    matches what was just installed.

    After installation the script optionally appends 'Import-Module VcfEdgeAtScale'
    to $PROFILE so the module loads automatically in every new PowerShell session.
    Use -AddToProfile to skip the interactive prompt and always add the line, or
    -SkipProfileUpdate to skip the prompt and never add it.

    Prerequisites:
      - PowerShell 7.4 or newer (enforced by #Requires).
      - VCF.PowerCLI 9.0 or newer must already be installed; it is declared as
        a required module in the VcfEdgeAtScale manifest and Import-Module will
        fail without it.

.PARAMETER SourcePath
    Path to the directory containing the module source files. Defaults to the
    directory containing this script ($PSScriptRoot), which is correct when
    running directly from a cloned repository.

.PARAMETER AddToProfile
    When specified, appends 'Import-Module VcfEdgeAtScale' to $PROFILE without
    prompting. Skipped silently if the line is already present. Cannot be combined
    with -SkipProfileUpdate.

.PARAMETER SkipProfileUpdate
    When specified, skips the $PROFILE update prompt entirely and does not modify
    $PROFILE. Use for unattended installs where profile changes are unwanted.
    Cannot be combined with -AddToProfile.

.EXAMPLE
    .\Install-VcfEdgeAtScaleModule.ps1

    Installs from the script's own directory. Prompts whether to add the module
    to $PROFILE for auto-load on every new session.

.EXAMPLE
    .\Install-VcfEdgeAtScaleModule.ps1 -SourcePath "~/Downloads/VcfEdgeAtScale"

    Installs from a custom source directory and prompts for $PROFILE update.

.EXAMPLE
    .\Install-VcfEdgeAtScaleModule.ps1 -AddToProfile

    Installs and adds 'Import-Module VcfEdgeAtScale' to $PROFILE without prompting.

.EXAMPLE
    .\Install-VcfEdgeAtScaleModule.ps1 -SkipProfileUpdate

    Installs without modifying $PROFILE (suitable for CI or scripted installs).

.NOTES
    After installation run 'Import-Module VcfEdgeAtScale' to confirm success,
    then 'Start-VcfEdgeAtScale -Initialize' to set up your working directory.
#>
[CmdletBinding()]
Param (
    [Parameter(Mandatory = $false)] [Switch]$AddToProfile,
    [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$SourcePath = $PSScriptRoot,
    [Parameter(Mandatory = $false)] [Switch]$SkipProfileUpdate
)

if ($AddToProfile -and $SkipProfileUpdate) {
    throw "Do not combine -AddToProfile with -SkipProfileUpdate."
}

$itemsToCopy = @("VcfEdgeAtScale.psd1", "VcfEdgeAtScale.psm1", "PSScriptAnalyzerSettings.psd1", "Private", "Templates", "Tools")

Write-Host ""
Write-Host "VcfEdgeAtScale Module Installer" -ForegroundColor Cyan
Write-Host "================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "PREREQUISITE: VCF.PowerCLI 9.0 or newer must be installed before importing this module." -ForegroundColor Yellow
Write-Host ""

try {
    if (-not (Test-Path -Path $SourcePath -PathType Container)) {
        throw "Source path not found or is not a directory: $SourcePath"
    }

    $pathSeparator = [System.IO.Path]::PathSeparator
    $basePath = ($env:PSModulePath -split $pathSeparator)[0]
    $installPath = Join-Path -Path $basePath -ChildPath "VcfEdgeAtScale"

    Write-Host "Source      : $SourcePath"
    Write-Host "Destination : $installPath"
    Write-Host ""

    # Unload the module if it is currently in the session so the files can be
    # overwritten and the reloaded copy is consistent with what was just installed.
    $loadedModule = Get-Module -Name "VcfEdgeAtScale" -ErrorAction SilentlyContinue
    if ($null -ne $loadedModule) {
        Write-Host "Unloading currently loaded module (version $($loadedModule.Version))..." -ForegroundColor Gray
        Remove-Module -Name "VcfEdgeAtScale" -Force -ErrorAction Stop
    }

    if (-not (Test-Path -Path $installPath)) {
        Write-Host "Creating module directory..." -ForegroundColor Gray
        New-Item -Path $installPath -ItemType Directory -Force | Out-Null
    }

    foreach ($item in $itemsToCopy) {
        $itemSource = Join-Path -Path $SourcePath -ChildPath $item

        if (-not (Test-Path -Path $itemSource)) {
            Write-Host "  [SKIP] $item — not found at source." -ForegroundColor Yellow
            continue
        }

        Write-Host "  Copying $item..." -ForegroundColor Gray
        # Exclude Python bytecode cache directories that may exist in a development checkout.
        Copy-Item -Path $itemSource -Destination $installPath -Recurse -Force -Exclude "__pycache__"
        # Copy-Item -Exclude does not recurse into subdirectories; remove any copied __pycache__ explicitly.
        Get-ChildItem -Path (Join-Path -Path $installPath -ChildPath $item) -Filter "__pycache__" -Recurse -Directory -ErrorAction SilentlyContinue |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }

    # Unblock all copied files on Windows so execution policy does not block the module
    # after installation when the source was downloaded from the internet (ZIP or clone).
    # Unblock-File is a no-op on macOS/Linux where Zone.Identifier streams do not exist.
    Write-Host "Unblocking installed module files (Windows execution policy)..." -ForegroundColor Gray
    Get-ChildItem -Path $installPath -Recurse -File -ErrorAction SilentlyContinue |
        ForEach-Object { Unblock-File -Path $_.FullName -ErrorAction SilentlyContinue }

    Write-Host ""
    Write-Host "Validating module manifest..." -ForegroundColor Gray
    $manifestPath = Join-Path -Path $installPath -ChildPath "VcfEdgeAtScale.psd1"
    $null = Test-ModuleManifest -Path $manifestPath -ErrorAction Stop

    # Reload the module into the current session so the caller can use it immediately
    # without opening a new shell. Import errors are non-fatal — the files are on disk
    # and the user can reload manually if a dependency like VCF.PowerCLI is absent.
    Write-Host "Importing module into current session..." -ForegroundColor Gray
    try {
        Import-Module -Name "VcfEdgeAtScale" -Force -ErrorAction Stop
        $reloadedVersion = (Get-Module -Name "VcfEdgeAtScale").Version
        Write-Host "  Module loaded (version $reloadedVersion)." -ForegroundColor Gray
    } catch {
        Write-Host "  Import skipped: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host "  Run 'Import-Module VcfEdgeAtScale' manually once all prerequisites are met." -ForegroundColor Yellow
    }

    # Optionally add 'Import-Module VcfEdgeAtScale' to $PROFILE so the module
    # loads automatically in every new PowerShell session. Prompt unless the
    # caller passed -AddToProfile or -SkipProfileUpdate.
    $profileLine = "Import-Module VcfEdgeAtScale"
    $shouldUpdateProfile = $false

    if (-not $SkipProfileUpdate) {
        $profileAlreadyContainsLine = (Test-Path -LiteralPath $PROFILE) -and
            ((Get-Content -LiteralPath $PROFILE -ErrorAction SilentlyContinue) -contains $profileLine)

        if ($profileAlreadyContainsLine) {
            Write-Host "Profile ($PROFILE) already contains '$profileLine'; no change needed." -ForegroundColor Gray
        } elseif ($AddToProfile) {
            $shouldUpdateProfile = $true
        } else {
            Write-Host ""
            Write-Host "Auto-load on every session" -ForegroundColor Cyan
            Write-Host "  Add the following line to your PowerShell profile ($PROFILE):" -ForegroundColor Cyan
            Write-Host "    $profileLine" -ForegroundColor White
            Write-Host ""
            $response = Read-Host "Add this line to your profile now? (Y/N, Enter=no)"
            $shouldUpdateProfile = ($response -match '^Y(es)?$')
        }

        if ($shouldUpdateProfile) {
            if (-not (Test-Path -LiteralPath $PROFILE)) {
                Write-Host "Creating profile file: $PROFILE" -ForegroundColor Gray
                New-Item -Path $PROFILE -ItemType File -Force | Out-Null
            }
            Add-Content -LiteralPath $PROFILE -Value "" -Encoding UTF8
            Add-Content -LiteralPath $PROFILE -Value "# Added by VcfEdgeAtScale installer on $(Get-Date -Format 'yyyy-MM-dd')" -Encoding UTF8
            Add-Content -LiteralPath $PROFILE -Value $profileLine -Encoding UTF8
            Write-Host "Added '$profileLine' to $PROFILE." -ForegroundColor Green
            Write-Host "  The module will load automatically in every new PowerShell session." -ForegroundColor Green
        }
    }

    Write-Host ""
    Write-Host "Installation complete." -ForegroundColor Green
    Write-Host "  Start-VcfEdgeAtScale -Initialize" -ForegroundColor Green
    Write-Host ""
}
catch {
    Write-Host ""
    Write-Host "Installation failed: $($_.Exception.Message)" -ForegroundColor Red
    throw
}
