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

    By default only the mocked unit tests (VcfEdgeAtScale.Tests.ps1) run. Pass -Live to also
    run the live integration tests (VcfEdgeAtScale.Live.Tests.ps1) which require a real vCenter.
    Live tests read credentials from environment variables:
        VCF_TEST_VCENTER   — vCenter FQDN or IP (required for live mode)
        VCF_TEST_USER      — username (default: administrator@vsphere.local)
        VCF_TEST_PASSWORD  — password (required for live mode)
        VCF_TEST_CLUSTER   — cluster name for vSAN/cluster tests (optional)
        VCF_TEST_ALLOW_WRITES — set to any non-empty value to enable stateful write tests (Tier D)

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

    To run a single Describe block by name:
        ./Tests/Run-Tests.ps1 -Filter "Test-ValidIPv4Address"

    .PARAMETER Filter
    Optional Pester FullName filter string. Passed to PesterConfiguration.Filter.FullName.
    Supports wildcards (e.g. "*LogLevel*" or "Get-CleanErrorMessage*").

    .PARAMETER Live
    When set, includes VcfEdgeAtScale.Live.Tests.ps1 in the test run. Requires
    VCF_TEST_VCENTER and VCF_TEST_PASSWORD environment variables.

    .PARAMETER TestPath
    Path to the mocked unit test file. Defaults to VcfEdgeAtScale.Tests.ps1 next to this script.
    Pass an empty string ("") with -Live to run only the live test file.

    .EXAMPLE
    ./Tests/Run-Tests.ps1

    .EXAMPLE
    ./Tests/Run-Tests.ps1 -Filter "*ValidIPv4*"

    .EXAMPLE
    $env:VCF_TEST_VCENTER = "vc01.example.com"; $env:VCF_TEST_PASSWORD = "P@ssw0rd"
    ./Tests/Run-Tests.ps1 -Live

    .NOTES
    PesterConfiguration.Output.Verbosity = "Detailed" prints every test name with a pass/fail
    indicator. The alternative "Normal" prints only failed tests; "Minimal" prints only the
    summary line.
#>

Param (
    [Parameter(Mandatory = $false)] [String]$Filter = "",
    [Parameter(Mandatory = $false)] [String]$TestPath = (Join-Path $PSScriptRoot "VcfEdgeAtScale.Tests.ps1"),
    [Parameter(Mandatory = $false)] [Switch]$Live
)

$pathsToRun = [System.Collections.Generic.List[String]]::new()

if (-not [String]::IsNullOrWhiteSpace($TestPath)) {
    $pathsToRun.Add($TestPath)
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
    throw "No test paths to run. Provide -TestPath or -Live."
}

$config = New-PesterConfiguration
$config.Run.Path = $pathsToRun.ToArray()
$config.Output.Verbosity = "Detailed"

if (-not [String]::IsNullOrWhiteSpace($Filter)) {
    $config.Filter.FullName = $Filter
}

Invoke-Pester -Configuration $config
