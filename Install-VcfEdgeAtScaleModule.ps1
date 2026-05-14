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

    Once installed to $env:PSModulePath, PowerShell auto-imports the module the first time
    any of its commands is used in a session. No $PROFILE changes are needed.

    IMPORTANT: Do not add 'Import-Module VcfEdgeAtScale' to $PROFILE. The module contains
    ~35,000 lines across six private files and takes ~2 seconds to load on macOS. Loading it
    at every shell startup will make every new terminal noticeably slow. Use PowerShell's
    built-in auto-import instead — the module loads once on first use per session.

    If $PROFILE contains 'Import-Module VcfEdgeAtScale' or a lazy-load stub from an earlier
    install, the installer detects and offers to clean them up automatically.

    Use -SkipProfileUpdate to suppress all profile checks for unattended installs.

    Prerequisites:
      - PowerShell 7.4 or newer (enforced by #Requires).
      - VCF.PowerCLI 9.0 or newer must already be installed.

.PARAMETER SourcePath
    Path to the directory containing the module source files. Defaults to the
    directory containing this script ($PSScriptRoot), which is correct when
    running directly from a cloned repository.

.PARAMETER SkipProfileUpdate
    When specified, skips all $PROFILE inspection and cleanup. Use for unattended
    installs where profile changes are unwanted.

.EXAMPLE
    .\Install-VcfEdgeAtScaleModule.ps1

    Installs from the script's own directory. Checks $PROFILE for any VcfEdgeAtScale
    entries that would slow shell startup and offers to remove them.

.EXAMPLE
    .\Install-VcfEdgeAtScaleModule.ps1 -SourcePath "~/Downloads/VcfEdgeAtScale"

    Installs from a custom source directory.

.EXAMPLE
    .\Install-VcfEdgeAtScaleModule.ps1 -SkipProfileUpdate

    Installs without inspecting or modifying $PROFILE (suitable for CI or scripted installs).

.NOTES
    After installation, open a new shell and run 'Start-VcfEdgeAtScale -Initialize' to set up
    your working directory. PowerShell auto-imports the module on first use — no profile line needed.
#>
[CmdletBinding()]
Param (
    [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$SourcePath = $PSScriptRoot,
    [Parameter(Mandatory = $false)] [Switch]$SkipProfileUpdate
)

function Invoke-ProfileCleanup {

    <#
    .SYNOPSIS
        Shows the user what will be removed from $PROFILE and prompts for confirmation.
    .NOTES
        Always previews what will be deleted before writing. If the cleaned content is
        identical to the original (no match), the function skips without prompting.
    #>

    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ProfilePath,
        [Parameter(Mandatory = $true)] [AllowEmptyString()] [String]$OriginalContent,
        [Parameter(Mandatory = $true)] [AllowEmptyString()] [String]$CleanedContent
    )

    if ($OriginalContent -eq $CleanedContent) {
        Write-Host "  (Nothing matched for removal — skipping to prevent unintended edits.)" -ForegroundColor Gray
        return
    }

    # Show exactly which non-blank lines will disappear so the user can verify before confirming.
    $originalLines = $OriginalContent -split "`n"
    $cleanedLines  = $CleanedContent  -split "`n"
    $removedLines  = $originalLines | Where-Object { $cleanedLines -notcontains $_ -and -not [String]::IsNullOrWhiteSpace($_) }
    if ($removedLines) {
        Write-Host "  Lines that will be removed:" -ForegroundColor DarkGray
        $removedLines | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
        Write-Host ""
    }

    $response = Read-Host "Remove it now? (Y/N, Enter=no)"
    if ($response -match '^Y(es)?$') {
        Set-Content -LiteralPath $ProfilePath -Encoding UTF8 -NoNewline -Value $CleanedContent
        Write-Host "  Removed. Shell startup is now fast." -ForegroundColor Green
    }
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
        Import-Module -Name $manifestPath -Force -ErrorAction Stop
        $reloadedVersion = (Get-Module -Name "VcfEdgeAtScale").Version
        Write-Host "  Module loaded (version $reloadedVersion)." -ForegroundColor Gray
    } catch {
        Write-Host "  Import skipped: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host "  Run 'Import-Module VcfEdgeAtScale' manually once all prerequisites are met." -ForegroundColor Yellow
    }

    # Check $PROFILE for any VcfEdgeAtScale entries that would slow shell startup and clean them up.
    # The installer never writes to $PROFILE — PowerShell auto-imports the module on first command
    # use without any profile line. Detect two known patterns that cause ~2s startup latency:
    #   1. "Import-Module VcfEdgeAtScale" (eager load added by older versions of this installer)
    #   2. A lazy-load stub block (added by a transitional version of this installer)
    $eagerProfileLine = "Import-Module VcfEdgeAtScale"
    $lazyStubSentinel = "# VcfEdgeAtScale lazy loader"

    if (-not $SkipProfileUpdate) {
        $profileContent = if (Test-Path -LiteralPath $PROFILE) {
            Get-Content -LiteralPath $PROFILE -Raw -ErrorAction SilentlyContinue
        } else {
            ""
        }

        $hasLazyStub = $profileContent -match [regex]::Escape($lazyStubSentinel)
        $hasEagerLine = $profileContent -match "(?m)^\s*$([regex]::Escape($eagerProfileLine))\s*$"

        if ($hasLazyStub) {
            Write-Host ""
            Write-Host "Profile cleanup available" -ForegroundColor Yellow
            Write-Host "  $PROFILE contains a VcfEdgeAtScale lazy-load stub from an earlier install." -ForegroundColor Yellow
            Write-Host "  It is no longer needed — PowerShell auto-imports the module on first use." -ForegroundColor Yellow
            Write-Host ""
            # Locate the stub block using [regex]::Match so we can remove it by index/length
            # rather than a global -replace. This prevents the pattern from accidentally
            # consuming a closing '}' that belongs to other code in the profile.
            $stubPattern = "(?ms)^$([regex]::Escape($lazyStubSentinel)).*?^}"
            $stubMatch = [regex]::Match($profileContent, $stubPattern)
            if ($stubMatch.Success) {
                $cleanedContent = $profileContent.Remove($stubMatch.Index, $stubMatch.Length)
            } else {
                $cleanedContent = $profileContent
            }
            Invoke-ProfileCleanup -ProfilePath $PROFILE -OriginalContent $profileContent -CleanedContent $cleanedContent
        } elseif ($hasEagerLine) {
            Write-Host ""
            Write-Host "Profile warning" -ForegroundColor Yellow
            Write-Host "  $PROFILE contains 'Import-Module VcfEdgeAtScale'." -ForegroundColor Yellow
            Write-Host "  This adds ~2 seconds to every new shell. PowerShell auto-imports the module" -ForegroundColor Yellow
            Write-Host "  on first use without any profile entry — the line is not needed." -ForegroundColor Yellow
            Write-Host ""
            # Remove the Import-Module line and any installer comment immediately preceding it.
            $cleanedContent = ($profileContent -replace "(?m)^\s*# VcfEdgeAtScale[^\n]*\r?\n?", "") `
                -replace "(?m)^\s*$([regex]::Escape($eagerProfileLine))\r?\n?", ""
            Invoke-ProfileCleanup -ProfilePath $PROFILE -OriginalContent $profileContent -CleanedContent $cleanedContent
        } else {
            Write-Host ""
            Write-Host "  No profile changes needed — Start-VcfEdgeAtScale auto-loads on first use." -ForegroundColor Green
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
