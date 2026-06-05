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
    Static lint pass that enforces Windows-safe Pester stub patterns in VcfEdgeAtScale.Tests.ps1.

    .DESCRIPTION
    Parses the Pester test file with the PowerShell AST and checks for two families of anti-pattern
    that cause silent or confusing failures when the test suite is run on Windows with VCF PowerCLI 9
    installed:

      CHECK A — Common parameter redeclaration in stubs
        [CmdletBinding()] automatically injects -ErrorAction, -Verbose, -Debug, -WarningAction,
        -Confirm, -WhatIf, and related common parameters. Explicitly declaring any of them inside a
        Param block produces "A parameter with the name 'X' was defined multiple times" — a
        terminating error that silently bypasses the code under test and lands in an outer catch.

      CHECK B — Missing begin/process blocks in stubs for known pipeline-receiving or
        ArgumentTransformationAttribute cmdlets
        VMware PowerCLI binary cmdlets such as Set-Cluster, Set-VMHost, and the
        Initialize-VcenterNamespaceManagement* family carry ArgumentTransformationAttribute on their
        parameters. On Windows, Pester's Mock wraps the binary cmdlet so the type conversion runs
        before the Mock scriptblock. For pipeline-receiving cmdlets, a stub without begin/process
        blocks causes Pester's call-counter to silently under-count. Both classes of cmdlet require
        explicit begin {}; process {} blocks in their stub bodies.

    Exits with code 0 when no violations are found and code 1 when any violation is detected.
    Intended to be run before or alongside the Pester suite:

        pwsh -File Tests/Invoke-StubLint.ps1
        pwsh -File Tests/Invoke-StubLint.ps1 -TestFilePath path/to/Tests.ps1

    .PARAMETER TestFilePath
    Path to the Pester test file to lint. Defaults to VcfEdgeAtScale.Tests.ps1 adjacent to this
    script.

    .EXAMPLE
    ./Tests/Invoke-StubLint.ps1

    .EXAMPLE
    ./Tests/Invoke-StubLint.ps1 -TestFilePath "$PSScriptRoot/VcfEdgeAtScale.Tests.ps1"

    .NOTES
    Both checks use the PowerShell AST (System.Management.Automation.Language.Parser) for precise
    structural analysis rather than regex, so they are immune to multi-line formatting variations.

    The list of cmdlets subject to CHECK B is maintained in $Script:PIPELINE_OR_TRANSFORM_CMDLETS
    below. Add to it whenever a new VMware binary cmdlet is stubbed and causes Windows-specific
    test failures.
#>

[CmdletBinding()]
Param (
    [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$TestFilePath = (
        Join-Path -Path $PSScriptRoot -ChildPath "VcfEdgeAtScale.Tests.ps1"
    )
)

#region Constants

# Common parameters injected automatically by [CmdletBinding()] or [CmdletBinding(SupportsShouldProcess=$true)].
# Declaring any of these explicitly in a Param block alongside [CmdletBinding()] is a fatal duplicate.
$Script:COMMON_PARAMS = [System.Collections.Generic.HashSet[string]]::new(
    [string[]]@(
        'ErrorAction', 'ErrorVariable', 'WarningAction', 'WarningVariable',
        'Verbose', 'Debug', 'Confirm', 'WhatIf',
        'OutVariable', 'OutBuffer', 'PipelineVariable', 'InformationAction', 'InformationVariable'
    ),
    [System.StringComparer]::OrdinalIgnoreCase
)

# VMware binary cmdlets that require explicit begin {}; process {} blocks in their stubs.
# Two categories:
#   • Pipeline-receiving: stub lacks begin/process → Pester's Should -Invoke counter under-counts.
#   • ArgumentTransformationAttribute: on Windows, the binary's type-conversion runs before the Mock
#     scriptblock; an empty process {} ensures the stub body executes in the correct pipeline slot.
# Add entries here whenever a new Windows-specific stub failure is traced to either category.
$Script:PIPELINE_OR_TRANSFORM_CMDLETS = [System.Collections.Generic.HashSet[string]]::new(
    [string[]]@(
        # Pipeline-receiving PowerCLI cmdlets
        'Set-Cluster',
        'Set-VMHost',
        'Format-ConfigurationTable',
        # ArgumentTransformationAttribute — Initialize-VcenterNamespaceManagement* family.
        # These are matched by prefix below, not by exact name, so only the prefix root is listed.
        # Exact names for which failures have been observed and fixed:
        'Initialize-VcenterNamespaceManagementSupervisorsKubeAPIServerOptions',
        'Initialize-VcenterNamespaceManagementSupervisorsWorkloads',
        'Initialize-VcenterNamespaceManagementSupervisorsEnableOnComputeClusterSpec',
        'Initialize-VcenterNamespaceManagementSupervisorsControlPlane',
        'Initialize-VcenterNamespaceManagementSupervisorsLoadBalancer',
        'Initialize-VcenterNamespaceManagementSupervisorsEdge',
        'Initialize-VcenterNamespaceManagementSupervisorsNetwork'
    ),
    [System.StringComparer]::OrdinalIgnoreCase
)

# Prefix match: any stub whose name starts with this string is subject to CHECK B.
$Script:VCENTER_NS_MGMT_PREFIX = 'Initialize-VcenterNamespaceManagement'

#endregion

#region Helpers

function Get-FunctionDefinitionsFromFile {

    <#
        .SYNOPSIS
        Parses a PowerShell file and returns a result object with a ParseFailed flag and a
        Functions array. Using a PSCustomObject prevents PowerShell's pipeline-unrolling from
        collapsing an empty-functions result into $null, which would be indistinguishable from
        a genuine parse failure at the call site.

        .NOTES
        Returns [PSCustomObject]@{ ParseFailed = $true;  Functions = @() } on parse failure.
        Returns [PSCustomObject]@{ ParseFailed = $false; Functions = @(...) } on success.
        Functions may be an empty array when the file has no function definitions by design.
    #>

    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$FilePath
    )

    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($FilePath, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) {
        Write-LogViolation -Message "AST parse errors in '$FilePath':" -Severity ERROR
        foreach ($err in $parseErrors) {
            Write-Host "  Line $($err.Extent.StartLineNumber): $($err.Message)" -ForegroundColor Red
        }
        return [PSCustomObject]@{ ParseFailed = $true; Functions = @() }
    }
    return [PSCustomObject]@{
        ParseFailed = $false
        Functions   = @($ast.FindAll(
            { $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] },
            $true
        ))
    }
}

function Write-LogViolation {

    <#
        .SYNOPSIS
        Writes a formatted violation line to the console. Severity controls the colour.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [String]$Message,
        [Parameter(Mandatory = $false)] [ValidateSet('ERROR', 'WARN', 'INFO')] [String]$Severity = 'ERROR'
    )

    $color = switch ($Severity) {
        'ERROR' { 'Red' }
        'WARN'  { 'Yellow' }
        'INFO'  { 'Cyan' }
    }
    Write-Host "  [$Severity] $Message" -ForegroundColor $color
}

function Test-NeedsBeginProcess {

    <#
        .SYNOPSIS
        Returns $true when a function stub's name matches the list of cmdlets that require
        explicit begin/process blocks.
    #>

    [CmdletBinding()]
    [OutputType([Bool])]
    Param (
        [Parameter(Mandatory = $true)] [String]$FunctionName
    )

    if ($Script:PIPELINE_OR_TRANSFORM_CMDLETS.Contains($FunctionName)) { return $true }
    if ($FunctionName.StartsWith($Script:VCENTER_NS_MGMT_PREFIX, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    return $false
}

function Test-HasAnyNamedBlock {

    <#
        .SYNOPSIS
        Returns $true when a FunctionDefinitionAst body contains any named block
        (begin, process, or end).

        Check B only targets stubs with NO named block at all — those whose return value is
        implicitly in the default "end" block. Stubs that already use begin {}, process {},
        or end {} (including counting stubs like begin { $Script:n++ } and negative-assertion
        stubs like begin { throw }) are intentional about their block structure and are exempt:
        they do not have the WindowsArgumentTransformationAttribute risk because the stub
        function replaces the binary cmdlet entirely in module scope.
    #>

    [CmdletBinding()]
    [OutputType([Bool])]
    Param (
        [Parameter(Mandatory = $true)] [System.Management.Automation.Language.FunctionDefinitionAst]$FunctionAst
    )

    $namedBlocks = $FunctionAst.Body.FindAll(
        { $args[0] -is [System.Management.Automation.Language.NamedBlockAst] },
        $false
    )
    return ($null -ne $namedBlocks -and @($namedBlocks).Count -gt 0)
}

#endregion

#region Main

if (-not (Test-Path -LiteralPath $TestFilePath -PathType Leaf)) {
    Write-Host "[ERROR] Test file not found: $TestFilePath" -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "  Stub Lint: $TestFilePath" -ForegroundColor Cyan
Write-Host ""

$parseResult = Get-FunctionDefinitionsFromFile -FilePath $TestFilePath
if ($parseResult.ParseFailed) {
    Write-Host "  Parse error — see details above. Exiting." -ForegroundColor Red
    exit 1
}
$functions = $parseResult.Functions
if ($functions.Count -eq 0) {
    Write-Host "  No function stubs defined — nothing to check." -ForegroundColor DarkGray
    Write-Host ""
    exit 0
}

Write-Host "  Inspecting $($functions.Count) function definitions..." -ForegroundColor DarkGray
Write-Host ""

$violations = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($fn in $functions) {
    if ($null -eq $fn.Body.ParamBlock) { continue }

    # CHECK A: Explicit common parameter declaration.
    foreach ($param in $fn.Body.ParamBlock.Parameters) {
        $paramName = $param.Name.VariablePath.UserPath
        if ($Script:COMMON_PARAMS.Contains($paramName)) {
            $violations.Add([PSCustomObject]@{
                Check    = 'A'
                Function = $fn.Name
                Detail   = "declares common parameter `$$paramName — remove it; [CmdletBinding()] injects it automatically"
                Line     = $param.Extent.StartLineNumber
            })
        }
    }

    # CHECK B: Pipeline/transform stubs with no named block at all.
    # A stub that returns its value in the implicit end block is at risk on Windows: when Pester
    # wraps the binary cmdlet and pipeline input flows through, the ArgumentTransformationAttribute
    # conversion fires before the Mock scriptblock runs. Stubs that already declare any named
    # block (begin, process, or end) are intentional and exempt.
    if ((Test-NeedsBeginProcess -FunctionName $fn.Name) -and -not (Test-HasAnyNamedBlock -FunctionAst $fn)) {
        $violations.Add([PSCustomObject]@{
            Check    = 'B'
            Function = $fn.Name
            Detail   = "stub has no named block (begin/process/end) — add begin {}; process { <return expr> } to guard against ArgumentTransformationAttribute type conversion on Windows"
            Line     = $fn.Extent.StartLineNumber
        })
    }
}

if ($violations.Count -eq 0) {
    Write-Host "  All $($functions.Count) stubs passed." -ForegroundColor Green
    Write-Host ""
    exit 0
}

$sepLine = "=" * 64
Write-Host $sepLine -ForegroundColor Red
Write-Host "  STUB LINT VIOLATIONS ($($violations.Count))" -ForegroundColor Red
Write-Host $sepLine -ForegroundColor Red
Write-Host ""

$checkACount = ($violations | Where-Object { $_.Check -eq 'A' }).Count
$checkBCount = ($violations | Where-Object { $_.Check -eq 'B' }).Count

if ($checkACount -gt 0) {
    Write-Host "  CHECK A — Common parameter redeclaration ($checkACount violation(s))" -ForegroundColor Red
    Write-Host "  Declaring common parameters alongside [CmdletBinding()] produces a fatal duplicate-parameter" -ForegroundColor DarkGray
    Write-Host "  error on Windows that silently bypasses the code under test." -ForegroundColor DarkGray
    Write-Host ""
    foreach ($v in ($violations | Where-Object { $_.Check -eq 'A' })) {
        Write-Host "  Line $($v.Line): function $($v.Function)" -ForegroundColor Red
        Write-Host "    $($v.Detail)" -ForegroundColor Yellow
        Write-Host ""
    }
}

if ($checkBCount -gt 0) {
    Write-Host "  CHECK B — No named block in stub ($checkBCount violation(s))" -ForegroundColor Red
    Write-Host "  These stubs return a value from the implicit end block. On Windows, Pester's Mock" -ForegroundColor DarkGray
    Write-Host "  wraps the binary cmdlet so ArgumentTransformationAttribute type conversion runs" -ForegroundColor DarkGray
    Write-Host "  before the scriptblock. Add begin {}; process { <return expr> } to guard against" -ForegroundColor DarkGray
    Write-Host "  this. Stubs that already use any named block (begin/process/end) are exempt." -ForegroundColor DarkGray
    Write-Host ""
    foreach ($v in ($violations | Where-Object { $_.Check -eq 'B' })) {
        Write-Host "  Line $($v.Line): function $($v.Function)" -ForegroundColor Red
        Write-Host "    $($v.Detail)" -ForegroundColor Yellow
        Write-Host ""
    }
}

Write-Host $sepLine -ForegroundColor Red
Write-Host ""
exit 1

#endregion
