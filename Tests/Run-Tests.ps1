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
<#
    .SYNOPSIS
    Runs VcfEdgeAtScale Pester tests with human-readable Detailed output.

    .DESCRIPTION
    Wrapper around Invoke-Pester that applies a PesterConfiguration with Detailed verbosity,
    so each test name is printed as it runs. This makes the test run transparent: any
    [ERROR] or [WARNING] lines that appear are immediately preceded by the name of the
    test that intentionally exercised that error path.

    All console output (stdout, Write-Host, warnings, errors) is captured to a transcript
    file via Start-Transcript/Stop-Transcript. The log path is printed at the start and end
    of the run. When a test fails on a remote machine or in a CI pipeline, share the log file
    to get the full captured output.

    By default all mocked unit tests (VcfEdgeAtScale.*.Tests.ps1) run. Each test file covers
    one Private source file (Cluster, Deployment, EntryPoints, Logging, Networking, Supervisor,
    Validation, Yaml) plus an Infrastructure file for module-level types and metadata. Pass
    -Module to run only one area's tests. Pass -Live to also run the live integration tests
    (VcfEdgeAtScale.Live.Tests.ps1) which require a real vCenter.

    Each test file is run as a separate Invoke-Pester call prefixed with a "[N/M] Area (~K tests)"
    header. This eliminates the silent multi-second discovery phase that occurred when all files
    were discovered at once, and makes it obvious which area is currently running.
    Live tests read credentials from environment variables:
        VCF_TEST_VCENTER          — vCenter FQDN or IP (required for live mode)
        VCF_TEST_USER             — username (default: administrator@vsphere.local)
        VCF_TEST_PASSWORD         — password (required for live mode)
        VCF_TEST_CLUSTER          — cluster name for vSAN/cluster tests (optional)
        VCF_TEST_ALLOW_WRITES     — set to any non-empty value to enable stateful write tests (Tier D)
        VCF_TEST_ESX_PASSWORD     — ESX root password for Initialize-VcfEdgeAtScale idempotent re-run test;
                                    infrastructure.json must also have nonInteractivePassword: true
        HARBOR_ADMIN_PASSWORD     — Harbor admin password (required for Install-HarborSupervisorService live test)
        SECRET_KEY                — Harbor secret key (required for Install-HarborSupervisorService live test)

    Run from the VcfEdgeAtScale module root:
        ./Tests/Run-Tests.ps1

    To run from the module root:
        Set-Location .../VcfEdgeAtScale
        ./Tests/Run-Tests.ps1

    To run with live tests:
        $env:VCF_TEST_VCENTER = "vc01.lab"; $env:VCF_TEST_PASSWORD = "..."
        ./Tests/Run-Tests.ps1 -Live

    To run only live tests:
        ./Tests/Run-Tests.ps1 -Live -TestPath ""

    To run tests for a specific module area:
        ./Tests/Run-Tests.ps1 -Module Cluster
        ./Tests/Run-Tests.ps1 -Module Networking

    To run a single Describe block by name:
        ./Tests/Run-Tests.ps1 -Filter "Test-ValidIPv4Address"

    To write the transcript to a specific path:
        ./Tests/Run-Tests.ps1 -LogPath "C:\Logs\test-run.txt"

    .PARAMETER Filter
    Optional Pester FullName filter string. Passed to PesterConfiguration.Filter.FullName.
    Supports wildcards (e.g. "*LogLevel*" or "Get-CleanErrorMessage*").

    .PARAMETER Live
    When set, includes VcfEdgeAtScale.Live.Tests.ps1 in the test run. Requires
    VCF_TEST_VCENTER and VCF_TEST_PASSWORD environment variables.

    .PARAMETER LogPath
    Path to the transcript log file. Defaults to a timestamped file in the system temp directory
    (e.g. %TEMP%\VcfEdgeAtScale-Tests-20260529-143012.txt). The file captures all console output,
    including Pester's per-test pass/fail lines, the failure summary block, and any non-terminating
    errors written to the error stream. Pass an empty string to disable transcription.

    .PARAMETER Module
    Optional. When specified, runs only the test file for that module area (e.g. "Cluster",
    "Networking", "Supervisor"). Corresponds to VcfEdgeAtScale.<Module>.Tests.ps1. Use
    "Infrastructure" for module-level type and metadata tests.

    .PARAMETER TestPath
    Explicit path to a unit test file. When omitted, auto-discovers all
    VcfEdgeAtScale.*.Tests.ps1 files in the Tests directory (excluding Live). Pass an empty
    string ("") with -Live to run only the live test file.

    .EXAMPLE
    ./Tests/Run-Tests.ps1

    .EXAMPLE
    ./Tests/Run-Tests.ps1 -Filter "*ValidIPv4*"

    .EXAMPLE
    $env:VCF_TEST_VCENTER = "vc01.example.com"; $env:VCF_TEST_PASSWORD = "P@ssw0rd"
    ./Tests/Run-Tests.ps1 -Live

    .EXAMPLE
    ./Tests/Run-Tests.ps1 -LogPath "$HOME\Desktop\test-results.txt"

    .NOTES
    PesterConfiguration.Output.Verbosity = "Detailed" prints every test name with a pass/fail
    indicator. The alternative "Normal" prints only failed tests; "Minimal" prints only the
    summary line.

    Start-Transcript captures Write-Host, Write-Output, Write-Warning, Write-Error, and most
    other console output. It does not capture output from external executables (e.g. kubectl)
    because those write directly to the process stdout handle rather than through PowerShell's
    output streams.
#>

Param (
    [Parameter(Mandatory = $false)] [String]$Filter = "",
    [Parameter(Mandatory = $false)] [String]$LogPath = (Join-Path ([System.IO.Path]::GetTempPath()) "VcfEdgeAtScale-Tests-$(Get-Date -Format 'yyyyMMdd-HHmmss').txt"),
    [Parameter(Mandatory = $false)] [ValidateSet("Cluster", "Deployment", "EntryPoints", "Infrastructure", "Logging", "Networking", "Supervisor", "Validation", "Yaml")] [String]$Module = "",
    [Parameter(Mandatory = $false)] [String]$TestPath = "",
    [Parameter(Mandatory = $false)] [Switch]$Live
)

# ---------------------------------------------------------------------------
# Transcript logging.
# Start-Transcript captures Write-Host, Write-Output, Write-Warning, Write-Error,
# and Pester's own console output to a plain-text file. Use this file to review
# the full test run output (including individual pass/fail lines) after the fact,
# share it when reporting failures, or pipe it through grep to isolate errors.
# ---------------------------------------------------------------------------
$transcriptActive = $false
if (-not [String]::IsNullOrWhiteSpace($LogPath)) {
    $logDir = Split-Path -Path $LogPath -Parent
    if (-not [String]::IsNullOrWhiteSpace($logDir) -and -not (Test-Path -LiteralPath $logDir)) {
        New-Item -Path $logDir -ItemType Directory -Force | Out-Null
    }
    try {
        Start-Transcript -Path $LogPath -Force -ErrorAction Stop
        $transcriptActive = $true
        Write-Host "  Log: $LogPath" -ForegroundColor DarkGray
        Write-Host ""
    } catch {
        Write-Host "  Warning: could not start transcript at '$LogPath': $($_.Exception.Message)" -ForegroundColor DarkYellow
    }
}

# ---------------------------------------------------------------------------
# Pester 5 availability guard.
# Windows PowerShell ships with Pester 3.4 (signed by the OS). Pester 5 must
# be installed from PSGallery. -SkipPublisherCheck bypasses the Authenticode
# mismatch between the inbox Pester and the PSGallery-signed Pester 5 package.
# ---------------------------------------------------------------------------
$pester5 = Get-Module -ListAvailable -Name Pester |
    Where-Object { $_.Version.Major -ge 5 } |
    Sort-Object Version -Descending |
    Select-Object -First 1

if ($null -eq $pester5) {
    Write-Host "Pester 5 is not installed. Installing from PSGallery (CurrentUser scope)…" -ForegroundColor Yellow
    try {
        Install-Module -Name Pester -MinimumVersion "5.0.0" -Force -SkipPublisherCheck -Scope CurrentUser -ErrorAction Stop
        Write-Host "Pester 5 installed." -ForegroundColor Green
    }
    catch {
        throw "Could not install Pester 5 automatically: $($_.Exception.Message)`nRun manually: Install-Module Pester -MinimumVersion '5.0.0' -Force -SkipPublisherCheck -Scope CurrentUser"
    }
}

Import-Module -Name Pester -MinimumVersion "5.0.0" -Force

$pathsToRun = [System.Collections.Generic.List[String]]::new()

if (-not [String]::IsNullOrWhiteSpace($TestPath)) {
    $pathsToRun.Add($TestPath)
} elseif (-not [String]::IsNullOrWhiteSpace($Module)) {
    $modulePath = Join-Path -Path $PSScriptRoot -ChildPath "VcfEdgeAtScale.$Module.Tests.ps1"
    if (-not (Test-Path -LiteralPath $modulePath)) {
        throw "Module test file not found: $modulePath"
    }
    $pathsToRun.Add($modulePath)
} else {
    $discovered = Get-ChildItem -Path $PSScriptRoot -Filter "VcfEdgeAtScale.*.Tests.ps1" |
        Where-Object { $_.Name -ne "VcfEdgeAtScale.Live.Tests.ps1" -and $_.Name -ne "VcfEdgeAtScale.Tests.ps1" } |
        Sort-Object Name |
        Select-Object -ExpandProperty FullName
    foreach ($p in $discovered) { $pathsToRun.Add($p) }
}

if ($Live) {
    $liveTestPath = Join-Path -Path $PSScriptRoot -ChildPath "VcfEdgeAtScale.Live.Tests.ps1"
    if (-not (Test-Path -Path $liveTestPath)) {
        throw "Live test file not found: $liveTestPath"
    }
    $pathsToRun.Add($liveTestPath)
    Write-Host "Live test mode enabled. VCF_TEST_VCENTER=$($env:VCF_TEST_VCENTER)"
}

if ($pathsToRun.Count -eq 0) {
    throw "No test paths to run. Provide -TestPath, -Module, or -Live."
}

# Build per-file test count estimates in one pass so the loop below can print
# "[1/10] Cluster (~300 tests)" without a second Select-String scan per file.
$perFileEstimates = @{}
foreach ($p in $pathsToRun) {
    $perFileEstimates[$p] = (
        Select-String -LiteralPath $p -Pattern '^\s+It\s+[''"]' -AllMatches | Measure-Object
    ).Count
}
$totalEstimate = ($perFileEstimates.Values | Measure-Object -Sum).Sum

$fileLabel = if ($pathsToRun.Count -eq 1) { "1 file" } else { "$($pathsToRun.Count) files" }
Write-Host ""
Write-Host "  Discovered ~$totalEstimate tests across $fileLabel." -ForegroundColor Cyan
Write-Host ""

# ---------------------------------------------------------------------------
# Stub lint pass: static analysis for Windows-breaking Pester stub patterns.
# Runs before Pester so that structural violations are caught immediately
# without waiting for the full test run to surface them.
# ---------------------------------------------------------------------------
$lintScript = Join-Path -Path $PSScriptRoot -ChildPath "Invoke-StubLint.ps1"
if (Test-Path -LiteralPath $lintScript -PathType Leaf) {
    $lintFailed  = $false
    $lintTargets = @($pathsToRun | Where-Object { $_ -notmatch 'Live' })
    $lintIndex   = 0
    foreach ($lintTarget in $lintTargets) {
        $lintIndex++
        $lintLeaf = Split-Path -Leaf $lintTarget
        Write-Host "  Linting [$lintIndex/$($lintTargets.Count)]: $lintLeaf" -ForegroundColor DarkGray
        & $lintScript -TestFilePath $lintTarget
        if ($LASTEXITCODE -ne 0) { $lintFailed = $true; break }
    }
    if ($lintFailed) {
        Write-Host ""
        Write-Host "  Stub lint failed. Fix violations before running tests." -ForegroundColor Red
        Write-Host ""
        if ($transcriptActive) { Stop-Transcript | Out-Null }
        exit 1
    }
    Write-Host ""
    Write-Host "  Stub lint passed." -ForegroundColor Green
    Write-Host ""
}

# ---------------------------------------------------------------------------
# Pester run: one file at a time so the "[N/M] Area" header prints before
# each file's tests begin — eliminating the silent discovery phase that made
# the run appear hung between stub lint and the first test name.
# Results are aggregated across all files for the failure/skip summary below.
# ---------------------------------------------------------------------------
$allFailed        = [System.Collections.Generic.List[Object]]::new()
$allSkipped       = [System.Collections.Generic.List[Object]]::new()
$totalRunCount    = 0
$totalFailedCount = 0
$totalSkipCount   = 0
$fileIndex        = 0
$fileCount        = $pathsToRun.Count

foreach ($currentTestPath in $pathsToRun) {
    $fileIndex++
    $areaName     = [System.IO.Path]::GetFileNameWithoutExtension($currentTestPath) -replace '^VcfEdgeAtScale\.', '' -replace '\.Tests$', ''
    $fileEstimate = $perFileEstimates[$currentTestPath]

    Write-Host ""
    Write-Host "  [$fileIndex/$fileCount]  $areaName  (~$fileEstimate tests)" -ForegroundColor Cyan
    Write-Host ""

    $fileConfig = New-PesterConfiguration
    $fileConfig.Run.Path     = [String[]]@($currentTestPath)
    $fileConfig.Run.PassThru = $true
    $fileConfig.Output.Verbosity = "Detailed"
    if (-not [String]::IsNullOrWhiteSpace($Filter)) {
        $fileConfig.Filter.FullName = $Filter
    }

    $fileResult = Invoke-Pester -Configuration $fileConfig

    if ($null -ne $fileResult) {
        $totalRunCount    += $fileResult.TotalCount
        $totalFailedCount += $fileResult.FailedCount
        $totalSkipCount   += $fileResult.SkippedCount
        foreach ($f in $fileResult.Failed)  { $allFailed.Add($f) }
        foreach ($s in $fileResult.Skipped) { $allSkipped.Add($s) }
    }
}

if ($totalFailedCount -gt 0) {
    $sep = "=" * 64
    Write-Host ""
    Write-Host $sep -ForegroundColor Red
    Write-Host "  FAILURES  ($totalFailedCount of $totalRunCount tests)" -ForegroundColor Red
    Write-Host $sep -ForegroundColor Red
    $i = 1
    foreach ($failure in $allFailed) {
        Write-Host ""
        Write-Host "  [$i]  $($failure.ExpandedPath)" -ForegroundColor Red
        $errMsg = if ($failure.ErrorRecord.Count -gt 0) { $failure.ErrorRecord[0].Exception.Message } else { "(no message)" }
        foreach ($line in ($errMsg -split "`n")) {
            $trimmed = $line.TrimEnd()
            if ($trimmed) { Write-Host "       $trimmed" -ForegroundColor Yellow }
        }
        if ($failure.ErrorRecord.Count -gt 0 -and $failure.ErrorRecord[0].ScriptStackTrace) {
            $firstStackLine = ($failure.ErrorRecord[0].ScriptStackTrace -split "`n" | Select-Object -First 1).Trim()
            Write-Host "       at $firstStackLine" -ForegroundColor DarkGray
        }
        $i++
    }
    Write-Host ""
    Write-Host $sep -ForegroundColor Red
    Write-Host ""
}

if ($totalSkipCount -gt 0) {
    $sep = "=" * 64
    Write-Host ""
    Write-Host $sep -ForegroundColor DarkYellow
    Write-Host "  SKIPPED  ($totalSkipCount of $totalRunCount tests)" -ForegroundColor DarkYellow
    Write-Host $sep -ForegroundColor DarkYellow
    $i = 1
    foreach ($skipped in $allSkipped) {
        Write-Host ""
        Write-Host "  [$i]  $($skipped.ExpandedPath)" -ForegroundColor DarkYellow
        # Pester stores the -Because reason in the first error record's message when
        # Set-ItResult -Skipped -Because "..." is used.
        $reason = if ($skipped.ErrorRecord.Count -gt 0) {
            $skipped.ErrorRecord[0].Exception.Message
        } else {
            "(no reason given)"
        }
        Write-Host "       because: $reason" -ForegroundColor Gray
        $i++
    }
    Write-Host ""
    Write-Host $sep -ForegroundColor DarkYellow
    Write-Host ""
}

if ($transcriptActive) {
    Write-Host ""
    if ($totalFailedCount -gt 0) {
        Write-Host "  Full transcript (all output including per-test lines): $LogPath" -ForegroundColor Red
    } else {
        Write-Host "  Full transcript: $LogPath" -ForegroundColor DarkGray
    }
    Write-Host ""
    Stop-Transcript | Out-Null
}
