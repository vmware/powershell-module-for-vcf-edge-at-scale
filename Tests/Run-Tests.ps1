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

    Run from the VcfEdgeAtScale module root:
        ./Tests/Run-Tests.ps1

    To run from the module root:
        Set-Location .../VcfEdgeAtScale
        ./Tests/Run-Tests.ps1

    To run a single Describe block by name:
        ./Tests/Run-Tests.ps1 -Filter "Test-ValidIPv4Address"

    .PARAMETER Filter
    Optional Pester FullName filter string. Passed to PesterConfiguration.Filter.FullName.
    Supports wildcards (e.g. "*LogLevel*" or "Get-CleanErrorMessage*").

    .PARAMETER TestPath
    Path to the test file or directory. Defaults to the Tests folder next to this script.

    .EXAMPLE
    ./Tests/Run-Tests.ps1

    .EXAMPLE
    ./Tests/Run-Tests.ps1 -Filter "*ValidIPv4*"

    .NOTES
    PesterConfiguration.Output.Verbosity = "Detailed" prints every test name with a pass/fail
    indicator. The alternative "Normal" prints only failed tests; "Minimal" prints only the
    summary line.
#>

Param (
    [Parameter(Mandatory = $false)] [String]$Filter = "",
    [Parameter(Mandatory = $false)] [String]$TestPath = (Join-Path $PSScriptRoot "VcfEdgeAtScale.Tests.ps1")
)

$config = New-PesterConfiguration
$config.Run.Path = $TestPath
$config.Output.Verbosity = "Detailed"

if (-not [String]::IsNullOrWhiteSpace($Filter)) {
    $config.Filter.FullName = $Filter
}

Invoke-Pester -Configuration $config
