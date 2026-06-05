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
#region Private — deployment phase helpers, validation, vLCM helpers
function Get-ArgoCDNamespaceFromCluster {

    <#
        .SYNOPSIS
        Derives the ArgoCD supervisor namespace name for a given cluster object and cluster spec.

        .DESCRIPTION
        Combines the nameSpacePrefix (from cluster.supervisorServices.nameSpacePrefix, defaulting to "argocd")
        with the cluster MoRef ID (ExtensionData.MoRef.Value with "domain" stripped) to produce the
        namespace string used by ArgoCD cleanup and deployment. Extracted from three identical inline
        blocks in Invoke-VcfEdgeAtScaleCleanup and the main deployment workflow.

        .PARAMETER ClusterObject
        vSphere cluster object (output of Get-Cluster) with ExtensionData.MoRef.Value populated.

        .PARAMETER ClusterSpec
        The cluster element from infrastructure JSON (may have supervisorServices.nameSpacePrefix).

        .OUTPUTS
        [string] The derived ArgoCD namespace name.

        .EXAMPLE
        $ns = Get-ArgoCDNamespaceFromCluster -ClusterObject $clusterObj -ClusterSpec $cluster
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [System.Object]$ClusterObject,
        [Parameter(Mandatory = $false)] [AllowNull()] [PSObject]$ClusterSpec
    )

    $moRefFull = $ClusterObject.ExtensionData.MoRef.Value
    $moRefId = $moRefFull.Replace("domain-", "")
    $prefix = "argocd"
    if ($ClusterSpec -and $ClusterSpec.supervisorServices -and -not [String]::IsNullOrWhiteSpace($ClusterSpec.supervisorServices.nameSpacePrefix)) {
        $prefix = $ClusterSpec.supervisorServices.nameSpacePrefix.Trim()
    }
    return "$prefix-$moRefId"
}
function Get-VsanWitnessNameForCluster {

    <#
        .SYNOPSIS
        Resolves the vSAN witness host name for a cluster from cluster root or common.

        .DESCRIPTION
        Returns the first non-empty value from cluster.vSanWitnessVmName or InputData.common.vSanWitnessVmName. Used by Initialize-VcfEdgeAtScale for vSAN clusters only; callers must check whether the cluster storage type requires a witness before acting on the return value (e.g. non-vSAN clusters should ignore a non-null result).
        .PARAMETER Cluster
        Cluster object from infrastructure JSON (may have vSanWitnessVmName at the cluster root).
        .PARAMETER InputData
        Full parsed infrastructure JSON (for common.vSanWitnessVmName).
        .OUTPUTS
        [string] or $null if no witness name is configured.
    
        .EXAMPLE
        $vsanWitnessNameForCluster = Get-VsanWitnessNameForCluster -Cluster $clusterObject -InputData $parsedConfig
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $true)] [AllowNull()] [PSObject]$Cluster,
        [Parameter(Mandatory = $true)] [AllowNull()] [PSObject]$InputData
    )

    if (-not $Cluster) { return $null }
    if (-not [String]::IsNullOrWhiteSpace($Cluster.vSanWitnessVmName)) {
        return $Cluster.vSanWitnessVmName
    }
    if ($InputData -and $InputData.common -and -not [String]::IsNullOrWhiteSpace($InputData.common.vSanWitnessVmName)) {
        return $InputData.common.vSanWitnessVmName
    }
    return $null
}
function Get-EffectiveHaPolicyForCluster {

    <#
        .SYNOPSIS
        Resolves HA admission policy for vSAN-OSA / vSAN-ESA clusters from cluster root or common.

        .DESCRIPTION
        Returns clusters[].haPolicy when set to a valid value; otherwise common.haPolicy when set; otherwise reservationBased.
        Invalid values are rejected by Test-JsonHaPolicy during deeper JSON validation.
        Used only for two-or-more-node vSAN clusters when calling Update-Cluster / Invoke-ReconfigureClusterHA.

        .PARAMETER Cluster
        Cluster object from infrastructure JSON (optional clusters[].haPolicy).

        .PARAMETER InputData
        Parsed infrastructure JSON (optional common.haPolicy).

        .OUTPUTS
        String: slotBased, reservationBased, or disabled.
    
        .EXAMPLE
        $effectiveHaPolicyForCluster = Get-EffectiveHaPolicyForCluster -Cluster $clusterObject -InputData $parsedConfig
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $true)] [AllowNull()] [PSObject]$Cluster,
        [Parameter(Mandatory = $true)] [AllowNull()] [PSObject]$InputData
    )

    $allowed = @("slotBased", "reservationBased", "disabled")
    if ($Cluster -and $Cluster.PSObject.Properties["haPolicy"] -and $null -ne $Cluster.haPolicy -and -not [String]::IsNullOrWhiteSpace([String]$Cluster.haPolicy)) {
        $haPolicyValue = ([String]$Cluster.haPolicy).Trim()
        if ($haPolicyValue -in $allowed) {
            return $haPolicyValue
        }
    }
    if ($InputData -and $InputData.common -and $InputData.common.PSObject.Properties["haPolicy"] -and $null -ne $InputData.common.haPolicy -and -not [String]::IsNullOrWhiteSpace([String]$InputData.common.haPolicy)) {
        $haPolicyValue = ([String]$InputData.common.haPolicy).Trim()
        if ($haPolicyValue -in $allowed) {
            return $haPolicyValue
        }
    }
    return "reservationBased"
}
function Test-EdgeSiteNameValid {

    <#
        .SYNOPSIS
        Returns $true when a string is a valid edgeSite name.

        .DESCRIPTION
        A valid edgeSite name is 1–80 characters, lowercase letters, digits, and hyphens only,
        and must not start or end with a hyphen. Matches the JavaScript _isValidRfc1123 function in
        veas-ui.html and the Python RFC1123_RE constant in veas-json-generator.py.

        .PARAMETER Name
        The candidate edgeSite name to test.

        .OUTPUTS
        Boolean - $true when valid; $false when the name is missing, too long, or contains invalid characters.

        .EXAMPLE
        Test-EdgeSiteNameValid -Name "site1"
        # Returns: $true.

        .EXAMPLE
        Test-EdgeSiteNameValid -Name "-bad"
        # Returns: $false.
    #>

    [CmdletBinding()]
    [OutputType([Bool])]
    Param (
        [Parameter(Mandatory = $true)] [AllowEmptyString()] [String]$Name
    )

    if ([String]::IsNullOrWhiteSpace($Name)) {
        return $false
    }
    return $Name -cmatch '^[a-z0-9]([a-z0-9-]{0,78}[a-z0-9])?$'
}
function Get-EffectiveClusterName {

    <#
        .SYNOPSIS
        Resolves the vSphere cluster name for an edge site.

        .DESCRIPTION
        Returns clusters[].overrideClusterName when it is present and non-empty, after validating that the
        value conforms to vSphere object name constraints (1-80 characters; alphanumeric, spaces, _, +, -, (), .).
        Falls back to the generated name when the key is absent or empty.

        .PARAMETER Cluster
        Cluster object from infrastructure JSON (may have overrideClusterName).

        .PARAMETER ClusterNamePrefix
        Common cluster name prefix used when generating the default name.

        .PARAMETER EdgeSite
        Edge site identifier used when generating the default name.

        .OUTPUTS
        String: the effective vSphere cluster name for this edge site.

        .EXAMPLE
        $clusterName = Get-EffectiveClusterName -Cluster $cluster -ClusterNamePrefix "cl0" -EdgeSite "site1"
        # Returns "cl0-site1" when overrideClusterName is absent, or the override value when set.
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSObject]$Cluster,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ClusterNamePrefix,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$EdgeSite
    )

    if ($Cluster.PSObject.Properties["overrideClusterName"] -and -not [String]::IsNullOrWhiteSpace($Cluster.overrideClusterName)) {
        $overrideName = ([String]$Cluster.overrideClusterName).Trim()
        if ($overrideName -notmatch '^[a-zA-Z0-9 _+\-().]{1,80}$') {
            $err = "clusters[$EdgeSite].overrideClusterName `"$overrideName`": must be 1-80 characters, alphanumeric with spaces, _, +, -, (), ."
            Write-LogMessage -Type ERROR -Message $err
            throw [VcfDeploymentException]::new($err)
        }
        Write-LogMessage -Type DEBUG -Message "Using overrideClusterName `"$overrideName`" for edgeSite `"$EdgeSite`" (overrides prefix+site formula)."
        return $overrideName
    }
    return Get-ClusterNameFromPrefix -ClusterNamePrefix $ClusterNamePrefix -EdgeSite $EdgeSite
}
function Get-EffectiveSupervisorServicesYamlPath {

    <#
        .SYNOPSIS
        Resolves the full path to a supervisor service YAML file from parentDirectory and file name keys.

        .DESCRIPTION
        When **parentDirectory** (cluster then common) and the matching **\*YamlFileName** are both
        set, builds Join-Path(parent, fileName) and passes it through
        Resolve-InfrastructureReferencedFilePath. Otherwise falls back to legacy
        **supervisorServices.argoCdOperatorYamlPath**, **argoCdDeploymentYamlPath**,
        **harborDataTemplateYamlPath**, and **harborServiceYamlPath** (cluster over common), i.e.
        fully qualified or resolvable paths as before.

        .PARAMETER Cluster
        Cluster object from infrastructure JSON (optional cluster-level supervisorServices overrides).

        .PARAMETER CommonData
        The common section of infrastructure JSON (supervisorServices defaults).

        .PARAMETER LogicalYamlPathPropertyName
        Logical key matching deployment usage: argoCdDeploymentYamlPath, argoCdOperatorYamlPath,
        harborDataTemplateYamlPath, or harborServiceYamlPath (maps to *YamlFileName properties).

        .OUTPUTS
        [string] Resolved full path when the new or legacy configuration resolves; otherwise $null.

        .EXAMPLE
        $resolvedYamlPath = Get-EffectiveSupervisorServicesYamlPath -Cluster $cluster -CommonData $inputData.common -LogicalYamlPathPropertyName "argoCdDeploymentYamlPath"
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $true)] [AllowNull()] [PSObject]$Cluster,
        [Parameter(Mandatory = $true)] [AllowNull()] [PSObject]$CommonData,
        [Parameter(Mandatory = $true)] [ValidateSet("argoCdDeploymentYamlPath", "argoCdOperatorYamlPath", "harborDataTemplateYamlPath", "harborServiceYamlPath")] [String]$LogicalYamlPathPropertyName
    )

    $fileNamePropertyName = switch ($LogicalYamlPathPropertyName) {
        "argoCdDeploymentYamlPath"   { "argoCdDeploymentYamlFileName" }
        "argoCdOperatorYamlPath"     { "argoCdOperatorYamlFileName" }
        "harborDataTemplateYamlPath" { "harborDataTemplateYamlFileName" }
        "harborServiceYamlPath"      { "harborServiceYamlFileName" }
    }

    $commonSvc = if ($CommonData -and $CommonData.supervisorServices) { $CommonData.supervisorServices } else { $null }
    $clusterSvc = if ($Cluster -and $Cluster.supervisorServices) { $Cluster.supervisorServices } else { $null }

    $parentRaw = $null
    if ($clusterSvc -and $clusterSvc.PSObject.Properties["parentDirectory"] -and -not [String]::IsNullOrWhiteSpace([String]$clusterSvc.parentDirectory)) {
        $parentRaw = [String]$clusterSvc.parentDirectory
    } elseif ($commonSvc -and $commonSvc.PSObject.Properties["parentDirectory"] -and -not [String]::IsNullOrWhiteSpace([String]$commonSvc.parentDirectory)) {
        $parentRaw = [String]$commonSvc.parentDirectory
    }

    $fileRaw = $null
    if ($clusterSvc -and $clusterSvc.PSObject.Properties[$fileNamePropertyName] -and -not [String]::IsNullOrWhiteSpace([String]$clusterSvc.$fileNamePropertyName)) {
        $fileRaw = [String]$clusterSvc.$fileNamePropertyName
    } elseif ($commonSvc -and $commonSvc.PSObject.Properties[$fileNamePropertyName] -and -not [String]::IsNullOrWhiteSpace([String]$commonSvc.$fileNamePropertyName)) {
        $fileRaw = [String]$commonSvc.$fileNamePropertyName
    }

    if (-not [String]::IsNullOrWhiteSpace($parentRaw) -and -not [String]::IsNullOrWhiteSpace($fileRaw)) {
        $combined = $null
        try {
            $combined = [System.IO.Path]::GetFullPath((Join-Path -Path $parentRaw.Trim() -ChildPath $fileRaw.Trim()))
        } catch {
            Write-LogMessage -Type DEBUG -Message "Get-EffectiveSupervisorServicesYamlPath: could not combine parent and file name for $LogicalYamlPathPropertyName : $($_.Exception.Message)"
            $combined = $null
        }
        if (-not [String]::IsNullOrWhiteSpace($combined)) {
            if (-not (Test-PathIsWithinHomeDirectory -ResolvedPath $combined)) {
                Write-LogMessage -Type WARNING -Message "Get-EffectiveSupervisorServicesYamlPath: resolved path for $LogicalYamlPathPropertyName (`"$combined`") is outside the user home directory and has been rejected. Verify parentDirectory in supervisorServices."
                return $null
            }
            return Resolve-InfrastructureReferencedFilePath -FilePath $combined -InfrastructureJsonDirectory $Script:InfrastructureJsonParentForPathResolution
        }
    }

    $legacyPath = $null
    if ($clusterSvc -and $clusterSvc.PSObject.Properties[$LogicalYamlPathPropertyName] -and -not [String]::IsNullOrWhiteSpace([String]$clusterSvc.$LogicalYamlPathPropertyName)) {
        $legacyPath = [String]$clusterSvc.$LogicalYamlPathPropertyName
    } elseif ($commonSvc -and $commonSvc.PSObject.Properties[$LogicalYamlPathPropertyName] -and -not [String]::IsNullOrWhiteSpace([String]$commonSvc.$LogicalYamlPathPropertyName)) {
        $legacyPath = [String]$commonSvc.$LogicalYamlPathPropertyName
    }
    if (-not [String]::IsNullOrWhiteSpace($legacyPath)) {
        return Resolve-InfrastructureReferencedFilePath -FilePath $legacyPath.Trim() -InfrastructureJsonDirectory $Script:InfrastructureJsonParentForPathResolution
    }

    return $null
}
function Get-EffectiveArgoCdYamlPath {

    <#
        .SYNOPSIS
        Resolves the effective Argo CD operator or deployment YAML file path for a cluster.

        .DESCRIPTION
        Delegates to Get-EffectiveSupervisorServicesYamlPath (parentDirectory + file names, or legacy
        argoCdOperatorYamlPath / argoCdDeploymentYamlPath).

        .PARAMETER Cluster
        Cluster object from infrastructure JSON (may have supervisorServices overrides).

        .PARAMETER CommonData
        The common section of infrastructure JSON (for supervisorServices fallback).

        .PARAMETER PropertyName
        argoCdOperatorYamlPath or argoCdDeploymentYamlPath (logical names).

        .OUTPUTS
        [string] or $null if neither the new (parent + file name) nor legacy path is configured.

        .EXAMPLE
        $path = Get-EffectiveArgoCdYamlPath -Cluster $cluster -CommonData $inputData.common -PropertyName "argoCdOperatorYamlPath"
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $true)] [AllowNull()] [PSObject]$Cluster,
        [Parameter(Mandatory = $true)] [AllowNull()] [PSObject]$CommonData,
        [Parameter(Mandatory = $true)] [ValidateSet("argoCdOperatorYamlPath", "argoCdDeploymentYamlPath")] [String]$PropertyName
    )

    return Get-EffectiveSupervisorServicesYamlPath -Cluster $Cluster -CommonData $CommonData -LogicalYamlPathPropertyName $PropertyName
}
function Test-PathIsWithinHomeDirectory {

    <#
        .SYNOPSIS
        Returns $true when a fully-resolved filesystem path is located within the current user's home directory.

        .DESCRIPTION
        Mirrors the _safe_resolve_path() home-directory confinement used by the Python JSON generator server.
        Prevents a crafted parentDirectory value in infrastructure JSON (e.g. "../../etc") from reading or
        writing files outside the user's home tree.

        .PARAMETER ResolvedPath
        Fully normalized absolute path to test (output of [System.IO.Path]::GetFullPath or similar).

        .OUTPUTS
        [Bool] $true when the path is within $HOME, $false otherwise.

        .EXAMPLE
        Test-PathIsWithinHomeDirectory -ResolvedPath "C:\Users\Admin\VCFEdgeAtScale\harbor.crt"
    #>

    [CmdletBinding()]
    [OutputType([Bool])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ResolvedPath
    )

    $homeFull = [System.IO.Path]::GetFullPath($HOME)
    $separator = [System.IO.Path]::DirectorySeparatorChar
    $homeWithSep = $homeFull.TrimEnd($separator) + $separator
    $resolvedFull = [System.IO.Path]::GetFullPath($ResolvedPath)
    return $resolvedFull.StartsWith($homeWithSep, [System.StringComparison]::OrdinalIgnoreCase) -or
           $resolvedFull -eq $homeFull
}
function Resolve-InfrastructureReferencedFilePath {

    <#
        .SYNOPSIS
        Resolves a filesystem path referenced from infrastructure JSON.

        .DESCRIPTION
        When the path is already absolute or relative and the file exists as given, returns the full
        normalized path. When the path is relative and not found yet, tries the current PowerShell
        location (working directory), then the directory containing infrastructure.json (when
        provided). If no file is found, returns the trimmed original string so callers can surface
        it in validation errors. Works on Windows, macOS, and Linux.

        .PARAMETER FilePath
        Path from JSON (absolute or relative).

        .PARAMETER InfrastructureJsonDirectory
        Optional directory of the infrastructure JSON file (parent folder). Used as a fallback
        base for relative paths (for example YAML and certificate files stored next to the JSON).

        .OUTPUTS
        [String] Full path to an existing file, or the original path string when not resolved.

        .EXAMPLE
        Resolve-InfrastructureReferencedFilePath -FilePath "tls.crt.pem" -InfrastructureJsonDirectory "/path/to/config"
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $true)] [AllowEmptyString()] [ValidateNotNull()] [String]$FilePath,
        [Parameter(Mandatory = $false)] [AllowNull()] [String]$InfrastructureJsonDirectory
    )

    if ([String]::IsNullOrWhiteSpace($FilePath)) {
        return $FilePath
    }

    $trimmed = $FilePath.Trim()
    if (Test-Path -LiteralPath $trimmed -PathType Leaf) {
        return (Get-Item -LiteralPath $trimmed).FullName
    }

    if ([System.IO.Path]::IsPathRooted($trimmed)) {
        try {
            $normalizedRooted = [System.IO.Path]::GetFullPath($trimmed)
            if (Test-Path -LiteralPath $normalizedRooted -PathType Leaf) {
                return (Get-Item -LiteralPath $normalizedRooted).FullName
            }
        } catch {
            Write-LogMessage -Type DEBUG -Message "Resolve-InfrastructureReferencedFilePath: could not normalize rooted path `"$trimmed`": $($_.Exception.Message)"
        }
        return $trimmed
    }

    $cwd = (Get-Location).ProviderPath
    $candidates = [System.Collections.Generic.List[string]]::new()
    try {
        [Void]$candidates.Add([System.IO.Path]::GetFullPath((Join-Path -Path $cwd -ChildPath $trimmed)))
    } catch {
        Write-LogMessage -Type DEBUG -Message "Resolve-InfrastructureReferencedFilePath: could not combine CWD with `"$trimmed`": $($_.Exception.Message)"
    }
    if (-not [String]::IsNullOrWhiteSpace($InfrastructureJsonDirectory)) {
        try {
            [Void]$candidates.Add([System.IO.Path]::GetFullPath((Join-Path -Path $InfrastructureJsonDirectory -ChildPath $trimmed)))
        } catch {
            Write-LogMessage -Type DEBUG -Message "Resolve-InfrastructureReferencedFilePath: could not combine infrastructure JSON directory with `"$trimmed`": $($_.Exception.Message)"
        }
    }

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return (Get-Item -LiteralPath $candidate).FullName
        }
    }

    return $trimmed
}
function Update-InfrastructureJsonReferencedFilePaths {

    <#
        .SYNOPSIS
        Sets script scope for path resolution and expands Harbor TLS file names into full paths.

        .DESCRIPTION
        Resolves the parent folder of the infrastructure JSON file and assigns
        $Script:InfrastructureJsonParentForPathResolution so Get-EffectiveSupervisorServicesYamlPath
        can resolve combined supervisorServices paths. For each cluster.harborConfiguration, when
        parentDirectory is set, rewrites tlsCrt, tlsKey, and caCrt from file names under that
        directory to full paths; when parentDirectory is omitted, resolves each value as a full path
        (legacy) with Resolve-InfrastructureReferencedFilePath. Argo CD and Harbor supervisor YAML
        paths are resolved at read time from parentDirectory + *YamlFileName or legacy *YamlPath keys.

        .PARAMETER InfrastructureJsonPath
        Path to the infrastructure JSON file (used to locate the parent directory for relative paths).

        .PARAMETER InputData
        Parsed infrastructure JSON object (modified in place for Harbor TLS paths only).

        .OUTPUTS
        None.
    
        .EXAMPLE
        Update-InfrastructureJsonReferencedFilePaths -InfrastructureJsonPath "infrastructure.json" -InputData $parsedConfig
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$InfrastructureJsonPath,
        [Parameter(Mandatory = $true)] [AllowNull()] [PSObject]$InputData
    )

    $Script:InfrastructureJsonParentForPathResolution = $null

    if (-not $InputData) {
        return
    }

    $infrastructureJsonDirectory = $null
    try {
        if (Test-Path -LiteralPath $InfrastructureJsonPath -PathType Leaf) {
            $infrastructureJsonDirectory = Split-Path -Parent (Resolve-Path -LiteralPath $InfrastructureJsonPath).Path
        }
    } catch {
        Write-LogMessage -Type DEBUG -Message "Update-InfrastructureJsonReferencedFilePaths: could not resolve directory for `"$InfrastructureJsonPath`": $($_.Exception.Message)"
    }

    $Script:InfrastructureJsonParentForPathResolution = $infrastructureJsonDirectory

    if (-not $InputData.clusters) {
        return
    }

    foreach ($cluster in @($InputData.clusters)) {
        if (-not $cluster -or -not $cluster.harborConfiguration) {
            continue
        }
        $hc = $cluster.harborConfiguration
        $hasHarborParent = $hc.PSObject.Properties["parentDirectory"] -and -not [String]::IsNullOrWhiteSpace([String]$hc.parentDirectory)
        foreach ($propertyName in @("caCrt", "tlsCrt", "tlsKey")) {
            if ($null -eq $hc.PSObject.Properties[$propertyName]) {
                continue
            }
            $namePart = [String]$hc.$propertyName
            if ([String]::IsNullOrWhiteSpace($namePart)) {
                continue
            }
            if ($hasHarborParent) {
                $parentRaw = [String]$hc.parentDirectory.Trim()
                $combined = $null
                try {
                    $combined = [System.IO.Path]::GetFullPath((Join-Path -Path $parentRaw -ChildPath $namePart.Trim()))
                } catch {
                    Write-LogMessage -Type DEBUG -Message "Update-InfrastructureJsonReferencedFilePaths: could not combine harborConfiguration.parentDirectory with $propertyName for edgeSite `"$($cluster.edgeSite)`": $($_.Exception.Message)"
                    continue
                }
                if (-not (Test-PathIsWithinHomeDirectory -ResolvedPath $combined)) {
                    Write-LogMessage -Type WARNING -Message "Update-InfrastructureJsonReferencedFilePaths: resolved path for harborConfiguration.$propertyName (edgeSite `"$($cluster.edgeSite)`", `"$combined`") is outside the user home directory and has been rejected. Verify parentDirectory in harborConfiguration."
                    continue
                }
                $resolved = Resolve-InfrastructureReferencedFilePath -FilePath $combined -InfrastructureJsonDirectory $infrastructureJsonDirectory
                if ($resolved -ne $namePart) {
                    Write-LogMessage -Type DEBUG -Message "Resolved clusters[].harborConfiguration.$propertyName (edgeSite `"$($cluster.edgeSite)`") from `"$namePart`" under parentDirectory to `"$resolved`"."
                }
                $hc.$propertyName = $resolved
            } else {
                $resolved = Resolve-InfrastructureReferencedFilePath -FilePath $namePart.Trim() -InfrastructureJsonDirectory $infrastructureJsonDirectory
                if ($resolved -ne $namePart) {
                    Write-LogMessage -Type DEBUG -Message "Resolved clusters[].harborConfiguration.$propertyName (edgeSite `"$($cluster.edgeSite)`", legacy path) from `"$namePart`" to `"$resolved`"."
                }
                $hc.$propertyName = $resolved
            }
        }
    }
}
function Get-EffectiveSupervisorServiceFlag {

    <#
        .SYNOPSIS
        Resolves a boolean supervisor service disable flag with cluster-level override over common-level.

        .DESCRIPTION
        Returns the cluster-level flag value (clusters[].supervisorServices.[FlagName]) when defined,
        otherwise falls back to the common-level value (common.supervisorServices.[FlagName]).
        Returns $false when the flag is absent at both levels, making all services enabled by default.
        Cluster-level always takes priority when both are defined.

        Supported flags:
        - disableArgoCD: When true, skips ArgoCD deployment after supervisor creation.
        - disableHarbor: When true, will skip Harbor deployment (wiring pending).

        .PARAMETER Cluster
        Cluster object from infrastructure JSON (may have supervisorServices.[FlagName]).

        .PARAMETER CommonData
        The common section of infrastructure JSON (for supervisorServices fallback).

        .PARAMETER FlagName
        The boolean flag property name to resolve. Valid values are derived from
        $Script:SupervisorServiceRegistry — currently: disableArgoCD, disableHarbor.
        Add new entries to the registry in VcfEdgeAtScale.psm1 to extend the valid set.

        .OUTPUTS
        [bool] $true if the service should be skipped; $false if enabled (default when unset).

        .EXAMPLE
        $disableArgoCD = Get-EffectiveSupervisorServiceFlag -Cluster $cluster -CommonData $inputData.common -FlagName "disableArgoCD"

        Returns $true if disableArgoCD is set to true at the cluster or common level; $false otherwise.

        .NOTES
        Place "disableArgoCD": true in common.supervisorServices to disable for all clusters, or in
        clusters[].supervisorServices to override for a specific cluster only.
    #>

    [CmdletBinding()]
    [OutputType([Bool])]
    Param (
        [Parameter(Mandatory = $true)] [AllowNull()] [PSObject]$Cluster,
        [Parameter(Mandatory = $true)] [AllowNull()] [PSObject]$CommonData,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$FlagName
    )

    # Validate against registry inside the body so $Script:SupervisorServiceRegistry is guaranteed initialized.
    $validFlags = @($Script:SupervisorServiceRegistry.Values | Select-Object -ExpandProperty DisableFlag)
    if ($FlagName -notin $validFlags) {
        Write-LogMessage -Type WARNING -Message "Get-EffectiveSupervisorServiceFlag: unknown FlagName `"$FlagName`". Valid flags: $($validFlags -join ', '). Returning `$false (service enabled)."
        return $false
    }

    if ($Cluster -and $Cluster.supervisorServices -and $null -ne $Cluster.supervisorServices.$FlagName) {
        return [Bool]$Cluster.supervisorServices.$FlagName
    }
    if ($CommonData -and $CommonData.supervisorServices -and $null -ne $CommonData.supervisorServices.$FlagName) {
        return [Bool]$CommonData.supervisorServices.$FlagName
    }
    return $false
}
function Get-EffectiveVmkernelMtu {

    <#
        .SYNOPSIS
        Resolves the effective MTU for VDS and for vMotion/vSAN VMkernel adapters from common.vSanvMotionVmKernelMtuValue.

        .DESCRIPTION
        common.vSanvMotionVmKernelMtuValue in infrastructure JSON is the source for vMotion and vSAN VMkernel and VDS MTU (default 9000). Mgmt (vmk0) and vSAN Witness (vmk3) interfaces are always 1500 and are not set from this function. Precedence (first defined and in range wins):

        1. common.vSanvMotionVmKernelMtuValue – validated at JSON load (1500-9190). Use for VDS and vMotion/vSAN VMkernels only.
        2. common.vmkernelMtu – legacy key; used only when common.vSanvMotionVmKernelMtuValue is not set.
        3. DefaultMtu parameter – when no override is present or parseable in range.

        .PARAMETER DefaultMtu
        MTU used when no valid override is present. Must be between MinMtu and MaxMtu.

        .PARAMETER InputData
        Full parsed infrastructure JSON (common.vSanvMotionVmKernelMtuValue, common.vmkernelMtu).

        .PARAMETER MaxMtu
        Maximum allowed MTU; values above this are ignored. Must align with JSON validation and VDS/VMkernel limits.

        .PARAMETER MinMtu
        Minimum allowed MTU; values below this are ignored. Must align with JSON validation.

        .OUTPUTS
        [int] MTU in the range MinMtu to MaxMtu (for VDS and vMotion/vSAN VMkernels only).

        .NOTES
        Mgmt and vSAN Witness VMkernels are always 1500. This function returns the value for vMotion/vSAN and VDS only.
    
        .EXAMPLE
        $effectiveVmkernelMtu = Get-EffectiveVmkernelMtu -InputData $parsedConfig
    #>

    [CmdletBinding()]
    [OutputType([Int])]
    Param (
        [Parameter(Mandatory = $false)] [ValidateRange(1500, 9190)] [Int]$DefaultMtu = 9000,
        [Parameter(Mandatory = $true)] [AllowNull()] [PSObject]$InputData,
        [Parameter(Mandatory = $false)] [ValidateRange(1500, 9190)] [Int]$MaxMtu = 9190,
        [Parameter(Mandatory = $false)] [ValidateRange(1500, 9190)] [Int]$MinMtu = 1500
    )

    $parsed = 0

    if ($InputData -and $InputData.common -and $null -ne $InputData.common.PSObject.Properties["vSanvMotionVmKernelMtuValue"]) {
        if ([Int]::TryParse([String]$InputData.common.vSanvMotionVmKernelMtuValue, [Ref]$parsed) -and $parsed -ge $MinMtu -and $parsed -le $MaxMtu) {
            return $parsed
        }
    }
    if ($InputData -and $InputData.common -and $null -ne $InputData.common.vmkernelMtu) {
        if ([Int]::TryParse([String]$InputData.common.vmkernelMtu, [Ref]$parsed) -and $parsed -ge $MinMtu -and $parsed -le $MaxMtu) {
            return $parsed
        }
    }
    return $DefaultMtu
}
function Build-HarborDataValuesParams {

    <#
        .SYNOPSIS
        Builds the New-HarborDataValuesFile splatting parameter hashtable for a Harbor deployment.

        .DESCRIPTION
        Resolves TLS credential parameters from the harborConfiguration object. In lab mode without
        explicit TLS paths, generates a self-signed certificate pair via New-LabHarborSelfSignedTlsMaterialFiles
        and attaches the generated CA path to HarborConfig.caCrt. In both paths, optional volume-size
        and secret override properties are appended when non-blank.

        .PARAMETER EdgeSite
        The edge site name; used in log messages and as a label for self-signed TLS generation.

        .PARAMETER EffectiveHarborHostname
        The resolved Harbor hostname; used as the CN for self-signed TLS when lab mode is active.

        .PARAMETER HarborConfig
        The harborConfiguration PSCustomObject from the cluster JSON. May be mutated: when lab mode
        generates a self-signed CA, caCrt is added/updated on this object so downstream callers see it.

        .PARAMETER HarborDataValuesTemplatePath
        Path to the Harbor data-values YAML template file.

        .PARAMETER LabEnvironment
        When $true and no explicit TLS paths are present, self-signed TLS material is generated.

        .PARAMETER StoragePolicyName
        The VM storage policy name for the Harbor StorageClass.

        .OUTPUTS
        [PSCustomObject] with three properties:
          DataValuesParams    — hashtable ready to splat into New-HarborDataValuesFile.
          LabSelfSignedPaths  — PSCustomObject returned by New-LabHarborSelfSignedTlsMaterialFiles,
                                or $null when lab self-signed TLS was not generated.
          UsedLabGeneratedTls — [Bool] $true when lab self-signed TLS was generated.

        .EXAMPLE
        $result = Build-HarborDataValuesParams -EdgeSite $currentEdgeSite `
            -EffectiveHarborHostname $hostname -HarborConfig $harborConfig `
            -HarborDataValuesTemplatePath $templatePath -LabEnvironment $labEnvironment `
            -StoragePolicyName $storagePolicyName
        $harborTempYamlPath = New-HarborDataValuesFile @($result.DataValuesParams)

        .NOTES
        HarborConfig is passed by reference (PSCustomObject); the caCrt property is added or updated
        in place when lab-generated TLS is used, so the caller's object reflects the generated value.
    #>

    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$EdgeSite,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$EffectiveHarborHostname,
        [Parameter(Mandatory = $true)] [ValidateNotNull()]        [PSCustomObject]$HarborConfig,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$HarborDataValuesTemplatePath,
        [Parameter(Mandatory = $true)]                            [Bool]$LabEnvironment,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$StoragePolicyName
    )

    $labSelfSignedPaths  = $null
    $usedLabGeneratedTls = $false
    $hasTlsCrtPath = ($null -ne $HarborConfig.PSObject.Properties["tlsCrt"]) -and -not [String]::IsNullOrWhiteSpace([String]$HarborConfig.tlsCrt)
    $hasTlsKeyPath = ($null -ne $HarborConfig.PSObject.Properties["tlsKey"]) -and -not [String]::IsNullOrWhiteSpace([String]$HarborConfig.tlsKey)

    if ($LabEnvironment -and -not $hasTlsCrtPath -and -not $hasTlsKeyPath) {
        $labSelfSignedPaths = New-LabHarborSelfSignedTlsMaterialFiles -DnsName $EffectiveHarborHostname -EdgeSite $EdgeSite
        $dataValuesParams = @{
            CaCrtPath              = $labSelfSignedPaths.CaCrtPath
            EdgeSite               = $EdgeSite
            HarborTemplateFilePath = $HarborDataValuesTemplatePath
            Hostname               = $EffectiveHarborHostname
            StoragePolicyName      = $StoragePolicyName
            TlsCrtPath             = $labSelfSignedPaths.TlsCrtPath
            TlsKeyPath             = $labSelfSignedPaths.TlsKeyPath
        }
        if ($HarborConfig.PSObject.Properties["caCrt"]) {
            $HarborConfig.caCrt = $labSelfSignedPaths.CaCrtPath
        } else {
            $HarborConfig | Add-Member -NotePropertyName caCrt -NotePropertyValue $labSelfSignedPaths.CaCrtPath -Force
        }
        $usedLabGeneratedTls = $true
        Write-LogMessage -Type INFO -Message "Lab mode: using generated self-signed TLS for Harbor on edge site `"$EdgeSite`" (hostname `"$EffectiveHarborHostname`")."
    } else {
        $dataValuesParams = @{
            EdgeSite               = $EdgeSite
            HarborTemplateFilePath = $HarborDataValuesTemplatePath
            Hostname               = $EffectiveHarborHostname
            StoragePolicyName      = $StoragePolicyName
        }
        if (-not [String]::IsNullOrWhiteSpace($HarborConfig.tlsCrt))  { $dataValuesParams["TlsCrtPath"] = $HarborConfig.tlsCrt }
        if (-not [String]::IsNullOrWhiteSpace($HarborConfig.tlsKey))  { $dataValuesParams["TlsKeyPath"] = $HarborConfig.tlsKey }
        if (-not [String]::IsNullOrWhiteSpace($HarborConfig.caCrt))   { $dataValuesParams["CaCrtPath"]  = $HarborConfig.caCrt }
    }

    if (-not [String]::IsNullOrWhiteSpace($HarborConfig.registryVolumeSize))  { $dataValuesParams["RegistryVolumeSize"]  = $HarborConfig.registryVolumeSize }
    if (-not [String]::IsNullOrWhiteSpace($HarborConfig.jobserviceVolumeSize)) { $dataValuesParams["JobserviceVolumeSize"] = $HarborConfig.jobserviceVolumeSize }
    if (-not [String]::IsNullOrWhiteSpace($HarborConfig.databaseVolumeSize))  { $dataValuesParams["DatabaseVolumeSize"]  = $HarborConfig.databaseVolumeSize }
    if (-not [String]::IsNullOrWhiteSpace($HarborConfig.redisVolumeSize))     { $dataValuesParams["RedisVolumeSize"]     = $HarborConfig.redisVolumeSize }
    if (-not [String]::IsNullOrWhiteSpace($HarborConfig.trivyVolumeSize))     { $dataValuesParams["TrivyVolumeSize"]     = $HarborConfig.trivyVolumeSize }
    if (-not [String]::IsNullOrWhiteSpace($HarborConfig.harborAdminPassword)) { $dataValuesParams["HarborAdminPassword"] = $HarborConfig.harborAdminPassword }
    if (-not [String]::IsNullOrWhiteSpace($HarborConfig.secretKey))           { $dataValuesParams["SecretKey"]           = $HarborConfig.secretKey }
    if (-not [String]::IsNullOrWhiteSpace($HarborConfig.databasePassword))    { $dataValuesParams["DatabasePassword"]    = $HarborConfig.databasePassword }
    if (-not [String]::IsNullOrWhiteSpace($HarborConfig.coreSecret))          { $dataValuesParams["CoreSecret"]          = $HarborConfig.coreSecret }
    if (-not [String]::IsNullOrWhiteSpace($HarborConfig.jobserviceSecret))    { $dataValuesParams["JobserviceSecret"]    = $HarborConfig.jobserviceSecret }
    if (-not [String]::IsNullOrWhiteSpace($HarborConfig.registrySecret))      { $dataValuesParams["RegistrySecret"]      = $HarborConfig.registrySecret }

    return [PSCustomObject]@{
        DataValuesParams    = $dataValuesParams
        LabSelfSignedPaths  = $labSelfSignedPaths
        UsedLabGeneratedTls = $usedLabGeneratedTls
    }
}
function Invoke-HarborLabTlsCleanup {

    <#
        .SYNOPSIS
        Handles post-deploy lab-generated TLS file preservation and temp file cleanup.

        .DESCRIPTION
        When a lab deployment generates self-signed TLS material (LabSelfSignedPaths is non-null),
        this function optionally persists the key/cert pair to HarborKeyCerts/<EdgeSite>/ under the
        deployment root directory (when PreserveAutoGeneratedKeyCert is $true and install succeeded),
        then unconditionally deletes the three temp TLS files (TlsCrtPath, TlsKeyPath, CaCrtPath).
        This function is safe to call with LabSelfSignedPaths = $null; it returns immediately.

        .PARAMETER CurrentEdgeSite
        The edge site name; used as the subdirectory name and file stem for preserved key/cert files.

        .PARAMETER HarborInstallSucceeded
        When $true and PreserveAutoGeneratedKeyCert is $true, the key/cert pair is written to disk.

        .PARAMETER LabSelfSignedPaths
        PSCustomObject with TlsCrtPath, TlsKeyPath, and CaCrtPath properties. Pass $null to skip.

        .PARAMETER PreserveAutoGeneratedKeyCert
        When $true and HarborInstallSucceeded is $true, persists the key/cert before cleanup.

        .EXAMPLE
        Invoke-HarborLabTlsCleanup -CurrentEdgeSite $currentEdgeSite `
            -HarborInstallSucceeded $harborInstallSucceeded `
            -LabSelfSignedPaths $labSelfSignedPaths `
            -PreserveAutoGeneratedKeyCert $preserveAutoGeneratedKeyCert

        .NOTES
        The key file is created with owner-only permissions (chmod 0600) on non-Windows platforms
        before any content is written, eliminating the TOCTOU window where the file could be
        world-readable. Errors during preservation are logged as WARNING and do not throw.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)]  [ValidateNotNullOrEmpty()] [String]$CurrentEdgeSite,
        [Parameter(Mandatory = $true)]                             [Bool]$HarborInstallSucceeded,
        [Parameter(Mandatory = $false)] [AllowNull()]              [PSCustomObject]$LabSelfSignedPaths,
        [Parameter(Mandatory = $true)]                             [Bool]$PreserveAutoGeneratedKeyCert
    )

    if (-not $LabSelfSignedPaths) { return }

    if ($PreserveAutoGeneratedKeyCert -and $HarborInstallSucceeded) {
        $harborKeyCertSaveDir = $null
        $rootDir = $env:VcfEdgeAtScaleRootDirectory
        if (-not [String]::IsNullOrWhiteSpace($rootDir) -and (Test-Path -LiteralPath $rootDir)) {
            $harborKeyCertSaveDir = Join-Path -Path $rootDir -ChildPath (Join-Path -Path "HarborKeyCerts" -ChildPath $CurrentEdgeSite)
        }
        if ($harborKeyCertSaveDir) {
            try {
                if (-not (Test-Path -LiteralPath $harborKeyCertSaveDir)) {
                    New-Item -ItemType Directory -Path $harborKeyCertSaveDir -Force -ErrorAction Stop | Out-Null
                    Write-LogMessage -Type DEBUG -Message "Created HarborKeyCerts directory: `"$harborKeyCertSaveDir`"."
                }
                $destKeyPath = Join-Path -Path $harborKeyCertSaveDir -ChildPath "$CurrentEdgeSite.key"
                $destCrtPath = Join-Path -Path $harborKeyCertSaveDir -ChildPath "$CurrentEdgeSite.crt"
                $utf8NoBom   = [System.Text.UTF8Encoding]::new($false)
                if (-not $IsWindows) {
                    # Create the key file and lock it to owner-only BEFORE writing content to eliminate
                    # the TOCTOU window where the key would briefly be world-readable.
                    $keyStream = [System.IO.File]::Open($destKeyPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
                    $keyStream.Close()
                    & chmod 0600 $destKeyPath 2>&1 | Out-Null
                    if ($LASTEXITCODE -ne 0) {
                        Write-LogMessage -Type WARNING -Message "Could not set owner-only permissions on Harbor key file `"$destKeyPath`" (chmod exit code $LASTEXITCODE). File may have world-readable permissions — restrict it manually."
                    }
                }
                [System.IO.File]::WriteAllText($destKeyPath, [System.IO.File]::ReadAllText($LabSelfSignedPaths.TlsKeyPath, $utf8NoBom), $utf8NoBom)
                [System.IO.File]::WriteAllText($destCrtPath, [System.IO.File]::ReadAllText($LabSelfSignedPaths.TlsCrtPath, $utf8NoBom), $utf8NoBom)
                if (-not $IsWindows) {
                    & chmod 0644 $destCrtPath 2>&1 | Out-Null
                    if ($LASTEXITCODE -ne 0) {
                        Write-LogMessage -Type WARNING -Message "Could not set permissions on Harbor certificate file `"$destCrtPath`" (chmod exit code $LASTEXITCODE)."
                    }
                }
                Write-LogMessage -Type INFO -Message "Lab mode: preserved auto-generated Harbor key/cert for edge site `"$CurrentEdgeSite`": `"$destKeyPath`", `"$destCrtPath`"."
            } catch {
                Write-LogMessage -Type WARNING -Message "Could not save Harbor key/cert pair for edge site `"$CurrentEdgeSite`": $($_.Exception.Message)."
            }
        } else {
            Write-LogMessage -Type WARNING -Message "preserveAutoGeneratedKeyCertPair is true but `$env:VcfEdgeAtScaleRootDirectory is not set or does not exist. Key/cert pair for edge site `"$CurrentEdgeSite`" will not be saved."
        }
    }

    foreach ($labTlsPath in @($LabSelfSignedPaths.TlsCrtPath, $LabSelfSignedPaths.TlsKeyPath, $LabSelfSignedPaths.CaCrtPath)) {
        if (-not [String]::IsNullOrWhiteSpace($labTlsPath) -and (Test-Path -LiteralPath $labTlsPath)) {
            Remove-Item -LiteralPath $labTlsPath -Force -ErrorAction SilentlyContinue
            Write-LogMessage -Type DEBUG -Message "Removed lab-generated Harbor TLS temp file: `"$labTlsPath`"."
        }
    }
}
function Invoke-HarborTempYamlCleanup {

    <#
        .SYNOPSIS
        Cleans up the temporary Harbor data-values YAML file after a deployment attempt.

        .DESCRIPTION
        On success with a save directory configured, the YAML file is moved to HarborYamlSaveDir
        with an informational log message. On success without a save directory, the file is removed
        silently. On failure, a redacted copy is written for diagnostics before the original
        secrets file is unconditionally removed.

        .PARAMETER HarborInstallSucceeded
        $true when installation completed without exception.

        .PARAMETER HarborTempYamlPath
        Path to the temporary YAML file. Pass $null or empty string when no file was created.

        .PARAMETER HarborYamlSaveDir
        Directory where the YAML should be preserved on success. Pass $null or empty to discard.

        .EXAMPLE
        Invoke-HarborTempYamlCleanup -HarborInstallSucceeded $harborInstallSucceeded `
            -HarborTempYamlPath $harborTempYamlPath -HarborYamlSaveDir $harborYamlSaveDir

        .NOTES
        The redacted copy replaces harborAdminPassword, secretKey, password, secret, tls.key, and
        ca.key values with [REDACTED]. The original file (containing secrets) is always removed.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)]  [Bool]$HarborInstallSucceeded,
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [String]$HarborTempYamlPath,
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [String]$HarborYamlSaveDir
    )

    if ([String]::IsNullOrWhiteSpace($HarborTempYamlPath) -or -not (Test-Path -Path $HarborTempYamlPath)) { return }

    if ($HarborInstallSucceeded) {
        if (-not [String]::IsNullOrWhiteSpace($HarborYamlSaveDir)) {
            $harborYamlDestPath = Join-Path -Path $HarborYamlSaveDir -ChildPath (Split-Path -Path $HarborTempYamlPath -Leaf)
            Move-Item -Path $HarborTempYamlPath -Destination $harborYamlDestPath -Force -ErrorAction SilentlyContinue
            Write-LogMessage -Type INFO -Message "Harbor data values file saved (contains unredacted secrets): `"$harborYamlDestPath`". A redacted copy is in the deployment log."
        } else {
            Remove-Item -Path $HarborTempYamlPath -Force -ErrorAction SilentlyContinue
            Write-LogMessage -Type DEBUG -Message "Cleaned up temporary Harbor data values file: `"$HarborTempYamlPath`"."
        }
    } else {
        # On failure, write a redacted copy for diagnostics and remove the original secrets file.
        # To verify the storage class exists: kubectl get storageclass (in supervisor context).
        try {
            $harborRedactedPath = [System.IO.Path]::ChangeExtension($HarborTempYamlPath, ".redacted.yml")
            $harborRawYaml      = Get-Content -Path $HarborTempYamlPath -Raw -Encoding UTF8 -ErrorAction Stop
            $harborRedactedYaml = $harborRawYaml -replace '(?m)^(\s*(?:harborAdminPassword|secretKey|password|secret|tls\.key|ca\.key):\s+)\S.*$', '$1[REDACTED]'
            Set-Content -Path $harborRedactedPath -Value $harborRedactedYaml -Encoding UTF8 -ErrorAction SilentlyContinue
            Write-LogMessage -Type WARNING -Message "Harbor deployment failed. A redacted copy of the data values file is preserved for diagnostics: `"$harborRedactedPath`"."
        } catch {
            Write-LogMessage -Type WARNING -Message "Harbor deployment failed. Could not write redacted diagnostics file: $($_.Exception.Message)."
        } finally {
            Remove-Item -Path $HarborTempYamlPath -Force -ErrorAction SilentlyContinue
            Write-LogMessage -Type DEBUG -Message "Removed secrets Harbor data values file: `"$HarborTempYamlPath`"."
        }
    }
}
function Resolve-HarborYamlSaveDirectory {

    <#
        .SYNOPSIS
        Resolves and creates the HarborYaml save directory when SaveHarborYaml is enabled.

        .DESCRIPTION
        Returns $null when SaveHarborYaml is $false. Otherwise resolves the directory as
        <ModuleBase>/HarborYaml/, creates it if absent, and returns the full path. Throws
        VcfDeploymentException when directory creation fails.

        .PARAMETER SaveHarborYaml
        When $false the function returns $null immediately without creating any directory.

        .OUTPUTS
        [String] The resolved save directory path, or $null when SaveHarborYaml is $false.

        .EXAMPLE
        $harborYamlSaveDir = Resolve-HarborYamlSaveDirectory -SaveHarborYaml $saveHarborYaml

        .NOTES
        Uses ModuleBase (not $PSScriptRoot) so HarborYaml/ is always created at the module install
        root rather than inside Private/ where this helper is dot-sourced from.
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $true)] [Bool]$SaveHarborYaml
    )

    if (-not $SaveHarborYaml) { return $null }

    $moduleBase = if ($MyInvocation.MyCommand.Module.ModuleBase) {
        $MyInvocation.MyCommand.Module.ModuleBase
    } else {
        Split-Path -Path $PSScriptRoot -Parent
    }
    $saveDir = Join-Path -Path $moduleBase -ChildPath "HarborYaml"
    if (-not (Test-Path -Path $saveDir)) {
        try {
            New-Item -ItemType Directory -Path $saveDir -Force -ErrorAction Stop | Out-Null
            Write-LogMessage -Type DEBUG -Message "Created HarborYaml save directory: `"$saveDir`"."
        } catch [VcfDeploymentException] {
            throw
        } catch {
            $errorMsg = "Cannot create HarborYaml directory `"$saveDir`": $($_.Exception.Message)"
            Write-LogMessage -Type ERROR -Message $errorMsg
            throw [VcfDeploymentException]::new($errorMsg)
        }
    }
    return $saveDir
}
function Invoke-HarborDeploymentPhase {

    <#
        .SYNOPSIS
        Deploys the Harbor Supervisor Service for a single edge site.

        .DESCRIPTION
        Extracted from Initialize-VcfEdgeAtScale to reduce function size.
        Handles the full Harbor deployment sequence: resolving YAML paths, attaching a synthetic
        harborConfiguration for lab mode, resolving the effective hostname, building the data values
        file (with optional lab self-signed TLS), registering the service definition, installing the
        Supervisor Service, showing instance details, and registering the container image registry.
        Temp file cleanup (including redacted diagnostics on failure) and lab TLS key/cert preservation
        are handled in try/finally blocks so secrets are never left on disk after a failure.

        .PARAMETER Context
        Hashtable containing all per-site deployment state required for the Harbor phase:
          Cluster, ClusterId, ClusterName, ContextName, CurrentEdgeSite, InputData,
          InsecureTls, LabEnvironment, PreserveAutoGeneratedKeyCert, SaveHarborYaml,
          StoragePolicyName, SupervisorId.

        .OUTPUTS
        [String] The Harbor service name extracted from the service YAML, or $null when installation fails.

        .NOTES
        Sets $Script:HarborPhaseStarted = $true before any installation step so the rollback logic in
        Initialize-VcfEdgeAtScale can choose Harbor-only rollback on failure.
        Throws on any deployment failure; the caller is responsible for rollback.
        The $cluster object may be mutated (harborConfiguration attached for lab mode; hostname set).
    
        .EXAMPLE
        Invoke-HarborDeploymentPhase -Context "vcf-context"
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Hashtable]$Context
    )

    Assert-ContextKeys -CallerName "Invoke-HarborDeploymentPhase" -Context $Context `
        -RequiredKeys @("Cluster", "ClusterId", "ClusterName", "ContextName", "CurrentEdgeSite",
            "InputData", "StoragePolicyName", "SupervisorId")

    $Script:HarborPhaseStarted = $true
    $cluster                      = $Context.Cluster
    $clusterId                    = $Context.ClusterId
    $clusterName                  = $Context.ClusterName
    $contextName                  = $Context.ContextName
    $currentEdgeSite              = $Context.CurrentEdgeSite
    $inputData                    = $Context.InputData
    $insecureTls                  = $true
    $labEnvironment               = if ($Context.ContainsKey("LabEnvironment"))               { [Bool]$Context.LabEnvironment }               else { $false }
    $preserveAutoGeneratedKeyCert = if ($Context.ContainsKey("PreserveAutoGeneratedKeyCert")) { [Bool]$Context.PreserveAutoGeneratedKeyCert } else { $false }
    $saveHarborYaml               = if ($Context.ContainsKey("SaveHarborYaml"))               { [Bool]$Context.SaveHarborYaml }               else { $false }
    $storagePolicyName            = $Context.StoragePolicyName
    $supervisorId                 = $Context.SupervisorId

    $harborServiceYamlPath        = Get-EffectiveSupervisorServicesYamlPath -Cluster $cluster -CommonData $inputData.common -LogicalYamlPathPropertyName "harborServiceYamlPath"
    $harborDataValuesTemplatePath = Get-EffectiveSupervisorServicesYamlPath -Cluster $cluster -CommonData $inputData.common -LogicalYamlPathPropertyName "harborDataTemplateYamlPath"

    if ($labEnvironment -and -not $cluster.harborConfiguration) {
        $syntheticHarborConfiguration = [PSCustomObject]@{}
        $cluster | Add-Member -NotePropertyName harborConfiguration -NotePropertyValue $syntheticHarborConfiguration -Force
        Write-LogMessage -Type INFO -Message "Lab mode: clusters[].harborConfiguration was omitted for edge site `"$currentEdgeSite`"; attached an empty object for Harbor deploy (hostname from the Harbor data values template; self-signed TLS when tlsCrt and tlsKey are omitted)."
    }
    $harborConfig          = $cluster.harborConfiguration
    $harborTempYamlPath     = $null
    $harborYamlSaveDir      = Resolve-HarborYamlSaveDirectory -SaveHarborYaml $saveHarborYaml
    $labSelfSignedPaths     = $null
    $harborServiceName      = $null
    $harborInstallSucceeded = $false

    try {
        $effectiveHarborHostname = Get-EffectiveHarborHostnameForInfrastructureCluster -Cluster $cluster -CommonData $inputData.common -LabEnvironmentEnabled:$labEnvironment
        if ([String]::IsNullOrWhiteSpace($effectiveHarborHostname)) {
            $errorMsg = "Could not resolve Harbor hostname for edge site `"$currentEdgeSite`". Set clusters[].harborConfiguration.hostname or use lab mode with a Harbor data values template that defines hostname."
            Write-LogMessage -Type ERROR -Message $errorMsg
            throw [VcfDeploymentException]::new($errorMsg)
        }
        if (-not (Test-JsonPropertyFormat -InputData $effectiveHarborHostname -ValidationPreset "IpAddressOrFqdn" -ValidationLabel "harborConfiguration.hostname (deploy)")) {
            $errorMsg = "Resolved Harbor hostname `"$effectiveHarborHostname`" for edge site `"$currentEdgeSite`" is not a valid DNS-compatible FQDN or IP address (deploy-time check)."
            Write-LogMessage -Type ERROR -Message $errorMsg
            throw [VcfDeploymentException]::new($errorMsg)
        }
        if ($harborConfig.PSObject.Properties["hostname"]) {
            $harborConfig.hostname = $effectiveHarborHostname
        } else {
            $harborConfig | Add-Member -NotePropertyName hostname -NotePropertyValue $effectiveHarborHostname -Force
        }

        $dataValuesResult   = Build-HarborDataValuesParams -EdgeSite $currentEdgeSite -EffectiveHarborHostname $effectiveHarborHostname -HarborConfig $harborConfig -HarborDataValuesTemplatePath $harborDataValuesTemplatePath -LabEnvironment $labEnvironment -StoragePolicyName $storagePolicyName
        $labSelfSignedPaths = $dataValuesResult.LabSelfSignedPaths
        $dvp                = $dataValuesResult.DataValuesParams
        $harborTempYamlPath = New-HarborDataValuesFile @dvp
        # Read back from file; CRLF normalization is applied again in Install-HarborSupervisorService
        # before encoding, because Set-Content on Windows may re-introduce CRLF endings.
        $harborYamlContent  = Get-Content -Path $harborTempYamlPath -Raw -Encoding UTF8

        # Register the service definition (idempotent: no-op if already registered on this vCenter).
        Set-HarborService -Path $harborServiceYamlPath
        # Get-ArgoCDServiceDetail is a generic Carvel Package YAML parser; it works for any supervisor service.
        $harborServiceName, $harborServiceVersion = Get-ArgoCDServiceDetail -Path $harborServiceYamlPath
        Write-LogMessage -Type DEBUG -Message "Harbor service: name=`"$harborServiceName`", version=`"$harborServiceVersion`"."

        Install-HarborSupervisorService -ClusterId $clusterId -ClusterName $clusterName -SupervisorId $supervisorId -Service $harborServiceName -Version $harborServiceVersion -YamlServiceConfig $harborYamlContent
        $harborInstallSucceeded = $true
        Write-LogMessage -Type INFO -Message "Harbor Supervisor Service installed successfully for edge site `"$currentEdgeSite`" (hostname: `"$($harborConfig.hostname)`")."
        Show-HarborInstanceDetails -ClusterName $clusterName -ContextName $contextName -HarborConfig $harborConfig -InsecureTls:$insecureTls -LabGeneratedSelfSignedTls:($dataValuesResult.UsedLabGeneratedTls) -SupervisorId $supervisorId -YamlFilePath $harborTempYamlPath
        Add-HarborContainerImageRegistry -ClusterName $clusterName -ContextName $contextName -HarborConfig $harborConfig -InsecureTls:$insecureTls -SupervisorId $supervisorId -YamlFilePath $harborTempYamlPath
    } catch {
        throw
    } finally {
        Invoke-HarborLabTlsCleanup -CurrentEdgeSite $currentEdgeSite -HarborInstallSucceeded $harborInstallSucceeded -LabSelfSignedPaths $labSelfSignedPaths -PreserveAutoGeneratedKeyCert $preserveAutoGeneratedKeyCert
        Invoke-HarborTempYamlCleanup -HarborInstallSucceeded $harborInstallSucceeded -HarborTempYamlPath $harborTempYamlPath -HarborYamlSaveDir $harborYamlSaveDir
        # Harbor credential env vars (HARBOR_ADMIN_PASSWORD, SECRET_KEY) live in process scope and
        # expire with the session — they are not cleared here so they persist for multi-site runs,
        # same-session reruns, and subsequent interactive deployments without re-prompting.
    }

    return $harborServiceName
}
function Invoke-ArgoCDDeploymentPhase {

    <#
        .SYNOPSIS
        Deploys the Argo CD Supervisor Service for a single edge site.

        .DESCRIPTION
        Extracted from Initialize-VcfEdgeAtScale to reduce function size.
        Sets and clears VCF_CLI_VSPHERE_PASSWORD and KUBECTL_VSPHERE_PASSWORD environment variables in a
        try/finally block, installs the ArgoCD service definition, creates the workload namespace, installs
        the operator, creates a VCF context, and deploys the ArgoCD instance.

        .PARAMETER Context
        Hashtable containing all per-site deployment state required for the ArgoCD phase:
          ArgoCdDeploymentYamlPath, ArgoCDyaml, ArgocdNameSpace, ArgocdVmClass,
          ClusterId, ClusterName, ContextName, StoragePolicyId, SupervisorId.

        .OUTPUTS
        [Array] The resolved ArgocdVmClass list (may be populated by Get-AvailableVmClassNames when not pre-set).

        .NOTES
        Sets $Script:ArgoCDPhaseStarted = $true before any installation step so the rollback logic in
        Initialize-VcfEdgeAtScale can choose ArgoCD-only rollback on failure.
        Throws on any deployment failure; the caller is responsible for rollback.
    
        .EXAMPLE
        Invoke-ArgoCDDeploymentPhase -Context "vcf-context"
    #>

    [CmdletBinding()]
    [OutputType([Object[]])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Hashtable]$Context
    )

    Assert-ContextKeys -CallerName "Invoke-ArgoCDDeploymentPhase" -Context $Context `
        -RequiredKeys @("ArgoCdDeploymentYamlPath", "ArgoCDyaml", "ArgocdNameSpace", "ClusterId",
            "ClusterName", "ContextName", "StoragePolicyId", "SupervisorId", "VcenterCredential")

    $Script:ArgoCDPhaseStarted = $true
    $argoCdDeploymentYamlPath = $Context.ArgoCdDeploymentYamlPath
    $argoCDyaml               = $Context.ArgoCDyaml
    $argocdNameSpace          = $Context.ArgocdNameSpace
    $argocdVmClass            = $Context.ArgocdVmClass
    $clusterId                = $Context.ClusterId
    $clusterName              = $Context.ClusterName
    $contextName              = $Context.ContextName
    $storagePolicyId             = $Context.StoragePolicyId
    $supervisorId                = $Context.SupervisorId
    $vcenterCredential           = $Context.VcenterCredential
    $insecureTlsArgoCD = $true

    # Clear existing environment variables first to prevent conflicts with previous runs.
    Remove-Item env:\VCF_CLI_VSPHERE_PASSWORD -ErrorAction SilentlyContinue
    Remove-Item env:\KUBECTL_VSPHERE_PASSWORD -ErrorAction SilentlyContinue

    try {
        $env:VCF_CLI_VSPHERE_PASSWORD = Get-VcenterRestApiPlainPassword -VcenterCredential $vcenterCredential
        $env:KUBECTL_VSPHERE_PASSWORD = $env:VCF_CLI_VSPHERE_PASSWORD
        Write-LogMessage -Type DEBUG -Message "Set environment variables for VCF CLI and kubectl password-less access."
        # Create ArgoCD Operator. Create the ArgoCD workload namespace before installing the operator
        # so reconciliation can find it (avoids "Required namespace does not exist" when the operator
        # expects the namespace to exist).
        Set-ArgoCDService -Path $argoCDyaml
        $argoServiceName, $argoServiceVersion = Get-ArgoCDServiceDetail -Path $argoCDyaml
        if ($null -eq $argocdVmClass -or $argocdVmClass.Count -eq 0) {
            $argocdVmClass = Get-AvailableVmClassNames
        }
        Write-LogMessage -Type DEBUG -Message "Calling Add-ArgoCDNamespace with namespace: `"$argocdNameSpace`""
        Add-ArgoCDNamespace -SupervisorId $supervisorId -ArgoCdNamespace $argocdNameSpace -StoragePolicyId $storagePolicyId -VmClasses $argocdVmClass
        Install-ArgoCDOperator -ClusterId $clusterId -ClusterName $clusterName -SupervisorId $supervisorId -Service $argoServiceName -Version $argoServiceVersion

        $supervisorControlPlaneVmIp = Get-SupervisorControlPlaneIp -ClusterName $clusterName
        $ctxResult = Set-VCFContextCreate -ContextName $contextName -Endpoint $supervisorControlPlaneVmIp -Namespace $argocdNameSpace -SsoUsername $Script:VCenterUser -InsecureTls:$insecureTlsArgoCD
        # Note: $Script:VCenterUser is still read from script scope — it is the SSO username, not a secret.
        # VcenterCredential is passed through the context object; the plain password is extracted only at env-var assignment.
        if ($ctxResult -and -not $ctxResult.Success) {
            $errorMsg = "Deployment failed. VCF context switch failed. Check logs for details."
            Write-LogMessage -Type ERROR -Message $errorMsg
            throw [VcfDeploymentException]::new($errorMsg)
        }
        Write-LogMessage -Type DEBUG -Message "Calling Add-ArgoCDInstance with namespace: `"$argocdNameSpace`", YAML path: `"$argoCdDeploymentYamlPath`"."
        Add-ArgoCDInstance -ArgoCdNamespace $argocdNameSpace -ArgoCdDeploymentYamlPath $argoCdDeploymentYamlPath -ContextName $contextName -ClusterId $clusterId -Service $argoServiceName -InsecureTls:$insecureTlsArgoCD

        Show-ArgoCDInstanceDetails -ArgoCdNamespace $argocdNameSpace -ContextName $contextName -InsecureTls:$insecureTlsArgoCD
    } finally {
        # Always cleanup environment variables, even on errors.
        Remove-Item env:\VCF_CLI_VSPHERE_PASSWORD -ErrorAction SilentlyContinue
        Remove-Item env:\KUBECTL_VSPHERE_PASSWORD -ErrorAction SilentlyContinue
        # $vcenterCredential is a local reference only; $Script:VcenterCredential is cleared
        # at the end of the full deployment run in Initialize-VcfEdgeAtScale's finally block.
    }

    return $argocdVmClass
}
function Test-EsxHostUniqueness {

    <#
        .SYNOPSIS
        Validates that no ESX host (FQDN or IP) appears in more than one edge site in infrastructure.json.

        .DESCRIPTION
        Iterates all clusters[].esxHosts entries and checks for duplicate values across clusters.
        Each physical ESX host must belong to exactly one edge site; sharing a host between sites
        indicates a misconfiguration that would cause vCenter and vSAN operations to fail.

        .PARAMETER InputData
        The parsed infrastructure.json data object containing cluster configurations.

        .EXAMPLE
        $inputData = ConvertFrom-JsonSafely -JsonFilePath "infrastructure.json"
        $result = Test-EsxHostUniqueness -InputData $inputData
        if (-not $result.IsValid) {
            Write-LogMessage -Type ERROR -Message "ESX host uniqueness validation failed: $($result.ErrorMessage)"
        }

        .OUTPUTS
        PSCustomObject with properties:
        - IsValid      : Boolean — $true when all ESX hosts are unique across sites.
        - ErrorMessage : String — details about any duplicate hosts found.
        - DuplicateHosts : Array of duplicate ESX host names.

        .NOTES
        Private helper. Called from Initialize-VcfEdgeAtScale before deployment begins.
        Comparison is case-insensitive to catch duplicates that differ only in case.
    #>

    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [Object]$InputData
    )

    $validationResult = [PSCustomObject]@{
        IsValid        = $true
        ErrorMessage   = $null
        DuplicateHosts = @()
    }

    Write-LogMessage -Type DEBUG -Message "Entered Test-EsxHostUniqueness function..."

    try {
        $hostSiteMap = @{}
        $duplicateHosts = [System.Collections.Generic.List[String]]::new()

        foreach ($cluster in @($InputData.clusters)) {
            if (-not $cluster -or -not $cluster.esxHosts) {
                continue
            }
            $site = $cluster.edgeSite
            foreach ($esxHostName in @($cluster.esxHosts)) {
                if ([String]::IsNullOrWhiteSpace([String]$esxHostName)) {
                    continue
                }
                $hostKey = ([String]$esxHostName).ToLowerInvariant()
                if ($hostSiteMap.ContainsKey($hostKey)) {
                    $firstSite = $hostSiteMap[$hostKey]
                    if (-not $duplicateHosts.Contains($hostKey)) {
                        $duplicateHosts.Add($hostKey)
                    }
                    Write-LogMessage -Type ERROR -Message "Duplicate ESX host found: '$esxHostName' appears in both edgeSite '$firstSite' and '$site'. Each ESX host must be unique across all edge sites."
                } else {
                    $hostSiteMap[$hostKey] = $site
                }
            }
        }

        if ($duplicateHosts.Count -gt 0) {
            $validationResult.IsValid = $false
            $validationResult.DuplicateHosts = $duplicateHosts.ToArray()
            $validationResult.ErrorMessage = "Found $($duplicateHosts.Count) duplicate ESX host(s): $($duplicateHosts -join ', '). Each ESX host must appear in exactly one edge site."
            Write-LogMessage -Type ERROR -SuppressOutputToScreen -Message "ESX host uniqueness validation failed: $($validationResult.ErrorMessage)"
        } else {
            Write-LogMessage -Type DEBUG -Message "ESX host uniqueness validation passed."
        }
    } catch {
        $validationResult.IsValid = $false
        $validationResult.ErrorMessage = "Error during ESX host uniqueness validation: $($_.Exception.Message)"
        Write-LogMessage -Type ERROR -Message $validationResult.ErrorMessage
    }

    return $validationResult
}
function Get-NetworkSegmentDetailsFromInputData {

    <#
        .SYNOPSIS
        Collects network segment details (Name, VlanId, EdgeSite) from infrastructure.json input data.

        .DESCRIPTION
        Iterates over InputData.clusters (optionally filtered by EdgeSitesArray), reads networking.networkSegments,
        and returns an array of PSCustomObject with Name, VlanId, EdgeSite. Used by Test-NetworkSegmentNameUniqueness.
        Logs each segment at INFO with SuppressOutputToScreen.

        .PARAMETER InputData
        Parsed infrastructure JSON object (must have clusters array).

        .PARAMETER EdgeSitesArray
        Optional array of edge site names. When non-empty, only clusters whose edgeSite is in this array are included.

        .OUTPUTS
        PSCustomObject[]. Array of objects with Name, VlanId, EdgeSite.
    
        .EXAMPLE
        $networkSegmentDetailsFromInputData = Get-NetworkSegmentDetailsFromInputData -InputData $parsedConfig
    #>

    [CmdletBinding()]
    [OutputType([Object[]])]
    Param (
        [Parameter(Mandatory = $false)] [Object[]]$EdgeSitesArray = @(),
        [Parameter(Mandatory = $true)] [Object]$InputData
    )

    $networkSegmentDetails = [System.Collections.Generic.List[PSCustomObject]]::new()
    if (-not $InputData.clusters) {
        return $networkSegmentDetails.ToArray()
    }

    $clustersToValidate = if ($EdgeSitesArray -and $EdgeSitesArray.Count -gt 0) {
        $InputData.clusters | Where-Object { $_.edgeSite -in $EdgeSitesArray }
    } else {
        $InputData.clusters
    }

    foreach ($cluster in $clustersToValidate) {
        $currentEdgeSite = $cluster.edgeSite
        if ($cluster.networking -and $cluster.networking.networkSegments) {
            foreach ($networkSegment in $cluster.networking.networkSegments) {
                if ($networkSegment.name) {
                    $networkSegmentDetails.Add([PSCustomObject]@{
                        Name    = $networkSegment.name
                        VlanId  = $networkSegment.vlanId
                        EdgeSite = $currentEdgeSite
                    })
                    Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "Found network segment: '$($networkSegment.name)' (VLAN: $($networkSegment.vlanId), EdgeSite: $currentEdgeSite)"
                }
            }
        }
    }

    return $networkSegmentDetails.ToArray()
}
function Get-DuplicateNetworkSegmentGroups {

    <#
        .SYNOPSIS
        Returns Group-Object groups for network segment names that appear more than once.

        .DESCRIPTION
        Given an array of network segment details (Name, VlanId, EdgeSite), groups by Name
        and returns only groups where Count -gt 1. Used by Test-NetworkSegmentNameUniqueness
        to detect duplicate segment names and report them.

        .PARAMETER NetworkSegmentDetails
        Array of PSCustomObject with at least Name (and optionally VlanId, EdgeSite).

        .OUTPUTS
        Microsoft.PowerShell.Commands.GroupInfo[]
        Zero or more groups, each representing a duplicate name.
    
        .EXAMPLE
        $duplicateNetworkSegmentGroups = Get-DuplicateNetworkSegmentGroups -NetworkSegmentDetails "10.0.0.0/24"
    #>

    [CmdletBinding()]
    [OutputType([System.Object[]])]
    Param (
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [AllowNull()] [Object[]]$NetworkSegmentDetails
    )
    if (-not $NetworkSegmentDetails -or $NetworkSegmentDetails.Count -eq 0) {
        return @()
    }
    $groupedNames = $NetworkSegmentDetails | Group-Object -Property Name
    return $groupedNames | Where-Object { $_.Count -gt 1 }
}
function Test-NetworkSegmentNameUniqueness {

    <#
        .SYNOPSIS
        Validates that all network segment names are unique within infrastructure.json.

        .DESCRIPTION
        This function performs validation to ensure that all network segment names defined in
        infrastructure.json (clusters[].networking.networkSegments[].name) are unique across
        all clusters. The function checks for duplicates within the network segment names
        and provides detailed error reporting if any duplicates are found, including
        the VLAN IDs associated with conflicting network segments.

        .PARAMETER InputData
        The parsed infrastructure.json data object containing network segment configurations.

        .EXAMPLE
        $inputData = ConvertFrom-JsonSafely -JsonFilePath "infrastructure.json"
        $result = Test-NetworkSegmentNameUniqueness -InputData $inputData
        if (-not $result.IsValid) {
            Write-LogMessage -Type ERROR -Message "Network segment name validation failed: $($result.ErrorMessage)"
        }

        .OUTPUTS
        PSCustomObject
        Returns an object with the following properties:
        - IsValid: Boolean indicating if all network segment names are unique
        - ErrorMessage: String containing details about any validation failures
        - DuplicateNames: Array of duplicate network segment names found
        - AllNetworkSegmentNames: Array of all network segment names collected for validation

        .NOTES
        This function is case-sensitive for network segment name comparisons. Network segment names must be
        exactly identical to be considered duplicates. When duplicates are found, the function
        also reports the VLAN IDs associated with the conflicting network segments. The function logs
        validation progress and results using the Write-LogMessage function.
    #>

    [CmdletBinding()]
    [OutputType([Hashtable])]
    Param (
        [Parameter(Mandatory = $false)] [String]$EdgeSite,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [Object]$InputData
    )

    Write-LogMessage -Type DEBUG -Message "Entered Test-NetworkSegmentNameUniqueness function..."

    $edgeSitesArray = @()
    if ($EdgeSite) {
        $edgeSitesArray = Get-EdgeSitesFromParameter -EdgeSite $EdgeSite -InputData $InputData
        Write-LogMessage -Type DEBUG -Message "Validating network segment name uniqueness for edgeSite(s) `"$($edgeSitesArray -join '", "')`" only..."
    } else {
        Write-LogMessage -Type DEBUG -Message "Starting network segment name uniqueness validation across all clusters."
    }

    $duplicateNames = [System.Collections.Generic.List[String]]::new()
    $validationResult = @{
        IsValid = $true
        ErrorMessage = ""
        DuplicateNames = @()
        AllNetworkSegmentNames = @()
    }

    try {
        $networkSegmentDetails = Get-NetworkSegmentDetailsFromInputData -InputData $InputData -EdgeSitesArray $edgeSitesArray

        $duplicateGroups = Get-DuplicateNetworkSegmentGroups -NetworkSegmentDetails $networkSegmentDetails
        foreach ($group in $duplicateGroups) {
            $duplicateNames.Add($group.Name)
            $edgeSites = $group.Group | Select-Object -ExpandProperty EdgeSite
            $vlanIds = $group.Group | Select-Object -ExpandProperty VlanId
            $edgeSiteList = $edgeSites -join ', '
            $vlanIdList = $vlanIds -join ', '
            Write-LogMessage -Type ERROR -Message "Duplicate network segment name found: '$($group.Name)' (appears $($group.Count) times) in edgeSites: $edgeSiteList with VLAN IDs: $vlanIdList."
        }

        if ($duplicateNames.Count -gt 0) {
            $validationResult.IsValid = $false
            $validationResult.ErrorMessage = "Found $($duplicateNames.Count) duplicate network segment name(s): $($duplicateNames -join ', ')"
            $validationResult.DuplicateNames = $duplicateNames
            Write-LogMessage -Type ERROR -SuppressOutputToScreen -Message "Network segment name uniqueness validation failed: $($validationResult.ErrorMessage)"
        } else {
            Write-LogMessage -Type DEBUG -Message "Network segment name uniqueness validation passed. All $($networkSegmentDetails.Count) network segment names are unique."
        }

        $validationResult.AllNetworkSegmentNames = $networkSegmentDetails | Select-Object -ExpandProperty Name

    } catch {
        $validationResult.IsValid = $false
        $validationResult.ErrorMessage = "Error during network segment name validation: $($_.Exception.Message)"
        Write-LogMessage -Type ERROR -Message $validationResult.ErrorMessage
    }

    return $validationResult
}
function Invoke-HarborEnvVarPreflight {

    <#
        .SYNOPSIS
        Resolves all $env: Harbor secret references before deployment begins.

        .DESCRIPTION
        Scans every cluster in InputData where Harbor is not disabled and calls
        Resolve-HarborSecretValue for each secret field that carries a "$env:" reference.
        Any environment variable that is not currently set triggers an interactive masked
        prompt, storing the entered value in the process environment so it is available
        for the rest of the run. This ensures the user is prompted once at start-up rather
        than mid-deployment when a partially-completed deployment would require rollback.

        Fields with format constraints (e.g. secretKey must be exactly 16 characters) have
        those constraints enforced at prompt time via RequiredLength. If an environment
        variable is already set but the value does not satisfy the constraint, the user is
        prompted to supply a corrected value rather than failing later during deployment.

        Only fields explicitly set to a "$env:<VARNAME>" value in harborConfiguration are
        evaluated. Plain-text values and omitted fields are skipped entirely.

        .PARAMETER EdgeSite
        When specified, only the cluster matching this edgeSite value is checked.

        .PARAMETER InputData
        Parsed infrastructure JSON data object (output of ConvertFrom-JsonSafely).

        .EXAMPLE
        Invoke-HarborEnvVarPreflight -InputData $inputData

        Resolves all Harbor $env: secrets across every enabled cluster, prompting for any that are unset.

        .EXAMPLE
        Invoke-HarborEnvVarPreflight -InputData $inputData -EdgeSite "OSA"

        Resolves Harbor $env: secrets for the OSA cluster only.

        .NOTES
        Start-VcfEdgeAtScale does not call this function when -ComputeOnly is set, so a cluster may keep
        harborConfiguration entries with $env: references for a later supervisor or Harbor deployment without
        defining those environment variables during compute-only preparation.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$EdgeSite,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSCustomObject]$InputData
    )

    $secretFields = @("coreSecret", "databasePassword", "harborAdminPassword", "jobserviceSecret", "registrySecret", "secretKey")

    # Length constraints enforced at prompt time; user is re-prompted rather than failing later.
    $secretLengthConstraints = @{ "secretKey" = 16 }

    foreach ($cluster in $InputData.clusters) {
        if (-not [String]::IsNullOrWhiteSpace($EdgeSite) -and $cluster.edgeSite -ne $EdgeSite) {
            continue
        }
        if (Get-EffectiveSupervisorServiceFlag -Cluster $cluster -CommonData $InputData.common -FlagName "disableHarbor") {
            continue
        }
        $harborConfig = $cluster.harborConfiguration
        if (-not $harborConfig) {
            continue
        }
        foreach ($fieldName in $secretFields) {
            $fieldValue = $harborConfig.$fieldName
            if ([String]::IsNullOrWhiteSpace($fieldValue) -or $fieldValue -notmatch '^\$env:') {
                continue
            }
            $resolveParams = @{
                FieldName = $fieldName
                Value     = $fieldValue
            }
            if ($secretLengthConstraints.ContainsKey($fieldName)) {
                $resolveParams.RequiredLength = $secretLengthConstraints[$fieldName]
            }
            $null = Resolve-HarborSecretValue @resolveParams
        }
    }
}
function Read-HarborSecretInteractively {

    <#
    .SYNOPSIS
        Prompts the operator for a Harbor secret value and re-prompts until the length constraint is met.
    .DESCRIPTION
        Displays a secure-input prompt for the given Harbor field. If RequiredLength is positive and the
        entered value does not match, the user is offered a Y/N retry. Choosing N throws a
        VcfDeploymentException. Returns the validated plaintext value.
    .PARAMETER EnvVarName
        The environment-variable name to display in the prompt.
    .PARAMETER FieldName
        The harborConfiguration JSON field name, used in prompts and error messages.
    .PARAMETER RequiredLength
        Expected character count. Pass 0 to skip length validation.
    .EXAMPLE
        $secret = Read-HarborSecretInteractively -EnvVarName "HARBOR_ADMIN_PASSWORD" -FieldName "adminPassword" -RequiredLength 0
    .NOTES
        Throws VcfDeploymentException when the user declines to re-enter a wrong-length value.
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$EnvVarName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$FieldName,
        [Parameter(Mandatory = $true)] [ValidateRange(0, [Int]::MaxValue)] [Int]$RequiredLength
    )

    $envValue = $null
    while ($null -eq $envValue) {
        $secureInput = Read-Host -Prompt "Enter value for harborConfiguration.$FieldName (env:$EnvVarName)" -AsSecureString
        if ($secureInput.Length -eq 0) {
            continue
        }

        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureInput)
        try {
            $candidate = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        } finally {
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }

        if ($RequiredLength -gt 0 -and $candidate.Length -ne $RequiredLength) {
            Write-LogMessage -Type ERROR -Message "harborConfiguration.$FieldName must be exactly $RequiredLength character(s) but the entered value is $($candidate.Length) character(s)."
            $retryResponse = $null
            while ($retryResponse -ne "Y" -and $retryResponse -ne "N") {
                $retryResponse = Read-Host "Would you like to re-enter harborConfiguration.$FieldName? (Y/N)"
                $retryResponse = $retryResponse.Trim().ToUpper()
            }
            if ($retryResponse -eq "N") {
                $err = "User chose not to re-enter harborConfiguration.$FieldName. Aborting deployment."
                Write-LogMessage -Type ERROR -Message $err
                throw [VcfDeploymentException]::new($err)
            }
            continue
        }

        $envValue = $candidate
    }
    return $envValue
}
function Resolve-HarborSecretValue {

    <#
        .SYNOPSIS
        Resolves a Harbor configuration secret value, expanding $env: references.

        .DESCRIPTION
        If Value starts with "$env:", extracts the environment variable name and returns its current
        value from the process environment. If the environment variable is not set or is empty, the
        user is prompted to enter the value interactively (masked input). The entered value is then
        stored in the process-scoped environment variable so that subsequent calls within the same
        run resolve consistently without prompting again. Otherwise returns Value as-is, treating
        it as a plain-text secret.

        When RequiredLength is specified and the resolved value does not match that length, the
        function does not return the invalid value. Instead it logs an error and asks:
        "Would you like to re-enter harborConfiguration.<FieldName>? (Y/N)"
        - Y: re-prompts interactively for a corrected value (loop repeats on each wrong-length entry).
        - N: logs an error and throws, aborting deployment.

        This applies in two situations:
        - Pre-set environment variable with wrong length: the Y/N prompt is shown immediately, and
          on Y the cached variable is cleared before interactive prompting begins.
        - Interactive input that is the wrong length: the Y/N prompt is shown after each bad entry.

        Only values explicitly specified as "$env:<VARNAME>" in harborConfiguration trigger prompting.
        Plain-text values in the JSON are returned as-is without any interactive prompt; their
        constraints are validated separately (e.g. Test-JsonHarborConfiguration).

        .PARAMETER FieldName
        The harborConfiguration field name; used in prompt and log messages.

        .PARAMETER RequiredLength
        When greater than zero, the resolved value must be exactly this many characters. A value of
        the wrong length triggers an error followed by a Y/N prompt; Y re-prompts interactively,
        N throws and aborts deployment. Default: 0 (no length constraint).

        .PARAMETER Value
        The secret value from harborConfiguration in infrastructure.json. May be a plain-text string
        or a "$env:<VARNAME>" reference to an environment variable.

        .OUTPUTS
        [String] The resolved secret value, guaranteed to satisfy RequiredLength when specified.

        .EXAMPLE
        $password = Resolve-HarborSecretValue -FieldName "harborAdminPassword" -Value '$env:HARBOR_ADMIN_PW'

        If HARBOR_ADMIN_PW is set, returns its value. If unset, prompts the user to enter it,
        stores the entered value in HARBOR_ADMIN_PW, and returns it.

        .EXAMPLE
        $key = Resolve-HarborSecretValue -FieldName "secretKey" -Value '$env:SECRET_KEY' -RequiredLength 16

        If SECRET_KEY is set and is 16 characters, returns it. If it is set but is the wrong length,
        logs an error and asks "Would you like to re-enter...? (Y/N)". Y clears the cached value
        and prompts interactively; N throws and aborts deployment. If the variable is not set,
        prompts immediately. Wrong-length interactive input also triggers the Y/N prompt.

        .EXAMPLE
        $password = Resolve-HarborSecretValue -FieldName "harborAdminPassword" -Value "MyP@ssw0rd"

        Returns the plain-text value as-is without prompting.
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$FieldName,
        [Parameter(Mandatory = $false)] [ValidateRange(1, 1024)] [Int]$RequiredLength = 0,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Value
    )

    # A value that looks like a broken env var reference must fail explicitly rather than silently
    # being used as a literal password (which would be passed to Harbor undetected).
    if ($Value -match '^\$env:') {
        if (-not ($Value -match '^\$env:([A-Za-z_][A-Za-z0-9_]*)$')) {
            $err = "Resolve-HarborSecretValue: harborConfiguration.$FieldName value `"$Value`" starts with `$env:` but the variable name is not valid. Use `$env:VARNAME format where VARNAME starts with a letter or underscore and contains only letters, digits, and underscores."
            Write-LogMessage -Type ERROR -Message $err
            throw [VcfDeploymentException]::new($err)
        }
    } else {
        return $Value
    }

    $envVarName = $Matches[1]
    $envValue = [System.Environment]::GetEnvironmentVariable($envVarName)

    if (-not [String]::IsNullOrEmpty($envValue)) {
        if ($RequiredLength -eq 0 -or $envValue.Length -eq $RequiredLength) {
            Write-LogMessage -Type DEBUG -Message "Resolve-HarborSecretValue: Resolved harborConfiguration.$FieldName from environment variable `"$envVarName`"."
            return $envValue
        }

        # Pre-set value has wrong length: ask the user if they want to re-enter.
        Write-LogMessage -Type ERROR -Message "Environment variable `"$envVarName`" (harborConfiguration.$FieldName) has $($envValue.Length) character(s) but must be exactly $RequiredLength."
        $retryResponse = $null
        while ($retryResponse -ne "Y" -and $retryResponse -ne "N") {
            $retryResponse = Read-Host "Would you like to re-enter harborConfiguration.$FieldName? (Y/N)"
            $retryResponse = $retryResponse.Trim().ToUpper()
        }
        if ($retryResponse -eq "N") {
            $err = "User chose not to re-enter harborConfiguration.$FieldName. Aborting deployment."
            Write-LogMessage -Type ERROR -Message $err
            throw [VcfDeploymentException]::new($err)
        }

        # User chose Y: clear the invalid cached value and fall through to interactive prompting.
        [System.Environment]::SetEnvironmentVariable($envVarName, $null)
        Write-LogMessage -Type WARNING -Message "Prompting for corrected value for harborConfiguration.$FieldName (env:$envVarName)."
    } else {
        Write-LogMessage -Type WARNING -Message "Environment variable `"$envVarName`" (harborConfiguration.$FieldName) is not set. Prompting for interactive input."
    }

    # Prompt the user until a non-empty value satisfying RequiredLength is entered.
    $envValue = Read-HarborSecretInteractively -EnvVarName $envVarName -FieldName $FieldName -RequiredLength $RequiredLength

    # Persist in the process environment so subsequent calls resolve without re-prompting.
    # Security note: storing a plaintext secret in a process environment variable is a known
    # trade-off. The value is scoped to the current process, cleared when the process exits,
    # and is accessible to other code running in the same PowerShell session. It is not written
    # to disk. The caller (New-HarborDataValuesFile) expands it immediately and the YAML it
    # produces is cleaned up in a finally block.
    [System.Environment]::SetEnvironmentVariable($envVarName, $envValue)
    Write-LogMessage -Type DEBUG -Message "Stored interactive input in environment variable `"$envVarName`" for harborConfiguration.$FieldName."
    return $envValue
}
function Set-HarborYamlSecretValues {

    <#
    .SYNOPSIS
        Substitutes optional Harbor secret values into YAML content via regex replacement.
    .DESCRIPTION
        Resolves each secret parameter through Resolve-HarborSecretValue (which handles $env: references
        and interactive prompts), then performs the appropriate regex substitution in YamlContentRef.
        Top-level secrets (harborAdminPassword, secretKey) and nested-section secrets (database.password,
        core.secret, jobservice.secret, registry.secret) are handled. Empty/null values are skipped.
        Throws VcfDeploymentException when secretKey resolves to the wrong length.
    .PARAMETER CoreSecret
        Optional value for the YAML core.secret field.
    .PARAMETER DatabasePassword
        Optional value for the YAML database.password field.
    .PARAMETER HarborAdminPassword
        Optional value for the YAML harborAdminPassword field.
    .PARAMETER JobserviceSecret
        Optional value for the YAML jobservice.secret field.
    .PARAMETER RegistrySecret
        Optional value for the YAML registry.secret field.
    .PARAMETER SecretKey
        Optional value for the YAML secretKey field (must resolve to exactly 16 characters).
    .PARAMETER YamlContentRef
        Reference to the YAML content string; updated in place.
    .EXAMPLE
        Set-HarborYamlSecretValues -HarborAdminPassword $pw -SecretKey $sk -YamlContentRef ([Ref]$yaml)
    .NOTES
        Throws VcfDeploymentException when secretKey length constraint is not met.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [String]$CoreSecret,
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [String]$DatabasePassword,
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [String]$HarborAdminPassword,
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [String]$JobserviceSecret,
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [String]$RegistrySecret,
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [String]$SecretKey,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Ref]$YamlContentRef
    )

    if (-not [String]::IsNullOrWhiteSpace($HarborAdminPassword)) {
        $resolvedSecret = Resolve-HarborSecretValue -FieldName "harborAdminPassword" -Value $HarborAdminPassword
        $quotedSecret = ConvertTo-YamlSingleQuotedScalar -Value $resolvedSecret
        $YamlContentRef.Value = $YamlContentRef.Value -replace '(?m)^(?:#\s*)?harborAdminPassword:.*$', ('harborAdminPassword: ' + $quotedSecret.Replace('$', '$$'))
    }
    if (-not [String]::IsNullOrWhiteSpace($SecretKey)) {
        # RequiredLength enforces Y/N-gated re-prompting for $env: references (normally already
        # resolved correctly by Invoke-HarborEnvVarPreflight). For plain-text values that somehow
        # bypassed Test-JsonHarborConfiguration pre-flight validation, the throw below acts as
        # a safety net.
        $resolvedSecret = Resolve-HarborSecretValue -FieldName "secretKey" -Value $SecretKey -RequiredLength 16
        if ($resolvedSecret.Length -ne 16) {
            $err = "Harbor secretKey must be exactly 16 characters but the resolved value is $($resolvedSecret.Length) character(s). Update the `"SECRET_KEY`" environment variable (or harborConfiguration.secretKey) to a 16-character string."
            Write-LogMessage -Type ERROR -Message $err
            throw [VcfDeploymentException]::new($err)
        }
        $quotedSecret = ConvertTo-YamlSingleQuotedScalar -Value $resolvedSecret
        $YamlContentRef.Value = $YamlContentRef.Value -replace '(?m)^(?:#\s*)?secretKey:.*$', ('secretKey: ' + $quotedSecret.Replace('$', '$$'))
    }
    # Replace optional nested secret values; each section is anchored by its top-level YAML key.
    # Uses '${1}' (not '$1') to prevent .NET regex greedy-digit group number ambiguity.
    if (-not [String]::IsNullOrWhiteSpace($DatabasePassword)) {
        $resolvedSecret = Resolve-HarborSecretValue -FieldName "databasePassword" -Value $DatabasePassword
        $quotedSecret = ConvertTo-YamlSingleQuotedScalar -Value $resolvedSecret
        $YamlContentRef.Value = $YamlContentRef.Value -replace '(?m)(^database:\r?\n(?:  [^\n]*\r?\n)*?  password:\s*).*$', ('${1}' + $quotedSecret.Replace('$', '$$'))
    }
    if (-not [String]::IsNullOrWhiteSpace($CoreSecret)) {
        $resolvedSecret = Resolve-HarborSecretValue -FieldName "coreSecret" -Value $CoreSecret
        $quotedSecret = ConvertTo-YamlSingleQuotedScalar -Value $resolvedSecret
        $YamlContentRef.Value = $YamlContentRef.Value -replace '(?m)(^core:\r?\n(?:  [^\n]*\r?\n)*?  secret:\s*).*$', ('${1}' + $quotedSecret.Replace('$', '$$'))
    }
    if (-not [String]::IsNullOrWhiteSpace($JobserviceSecret)) {
        $resolvedSecret = Resolve-HarborSecretValue -FieldName "jobserviceSecret" -Value $JobserviceSecret
        $quotedSecret = ConvertTo-YamlSingleQuotedScalar -Value $resolvedSecret
        $YamlContentRef.Value = $YamlContentRef.Value -replace '(?m)(^jobservice:\r?\n(?:  [^\n]*\r?\n)*?  secret:\s*).*$', ('${1}' + $quotedSecret.Replace('$', '$$'))
    }
    if (-not [String]::IsNullOrWhiteSpace($RegistrySecret)) {
        $resolvedSecret = Resolve-HarborSecretValue -FieldName "registrySecret" -Value $RegistrySecret
        $quotedSecret = ConvertTo-YamlSingleQuotedScalar -Value $resolvedSecret
        $YamlContentRef.Value = $YamlContentRef.Value -replace '(?m)(^registry:\r?\n(?:  [^\n]*\r?\n)*?  secret:\s*).*$', ('${1}' + $quotedSecret.Replace('$', '$$'))
    }
}
function Update-HarborYamlContent {

    <#
        .SYNOPSIS
        Applies all cluster-specific substitutions to a Harbor data values YAML content string.

        .DESCRIPTION
        Performs regex-based replacements on the raw Harbor data values YAML string to set
        hostname, enableNginxLoadBalancer, enableContourHttpProxy, storageClass, optional PVC
        sizes, optional secrets, and optional TLS certificate content. Logs warnings if any
        mandatory substitutions are not found after replacement. Returns the modified YAML string.

        .PARAMETER CaCrtPath
        Optional. Full path to a PEM-encoded CA certificate file.

        .PARAMETER CoreSecret
        Optional. Replacement value for core.secret. "$env:" prefix resolves from environment.

        .PARAMETER DatabasePassword
        Optional. Replacement value for database.password. "$env:" prefix resolves from environment.

        .PARAMETER DatabaseVolumeSize
        Optional. Replacement size for the database PVC (e.g. "10Gi").

        .PARAMETER HarborAdminPassword
        Optional. Replacement value for harborAdminPassword. "$env:" prefix resolves from environment.

        .PARAMETER Hostname
        Required. The DNS-compatible FQDN set as the top-level hostname in the YAML.

        .PARAMETER JobserviceSecret
        Optional. Replacement value for jobservice.secret. "$env:" prefix resolves from environment.

        .PARAMETER JobserviceVolumeSize
        Optional. Replacement size for the jobservice jobLog PVC (e.g. "1Gi").

        .PARAMETER RedisVolumeSize
        Optional. Replacement size for the redis PVC (e.g. "1Gi").

        .PARAMETER RegistrySecret
        Optional. Replacement value for registry.secret. "$env:" prefix resolves from environment.

        .PARAMETER RegistryVolumeSize
        Optional. Replacement size for the registry PVC (e.g. "10Gi").

        .PARAMETER SecretKey
        Optional. Replacement value for secretKey. "$env:" prefix resolves from environment.

        .PARAMETER StorageClassName
        Required. The lowercased storage class name (e.g. "supervisor-osa"). The Supervisor creates
        StorageClasses from policy names by lowercasing them; New-HarborDataValuesFile derives this
        from StoragePolicyName before calling this function.

        .PARAMETER TlsCrtPath
        Optional. Full path to a PEM-encoded TLS certificate file.

        .PARAMETER TlsKeyPath
        Optional. Full path to a PEM-encoded TLS private key file.

        .PARAMETER TrivyVolumeSize
        Optional. Replacement size for the trivy PVC (e.g. "5Gi").

        .PARAMETER YamlContent
        Required. The raw Harbor data values YAML string read from the template file.

        .OUTPUTS
        System.String. The fully substituted YAML content string.

        .EXAMPLE
        $updated = Update-HarborYamlContent -YamlContent $raw -Hostname "harbor.example.com" -StorageClassName "supervisor-osa"
    #>

    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '')]
    Param (
        [Parameter(Mandatory = $false)] [String]$CaCrtPath,
        [Parameter(Mandatory = $false)] [String]$CoreSecret,
        [Parameter(Mandatory = $false)] [String]$DatabasePassword,
        [Parameter(Mandatory = $false)] [String]$DatabaseVolumeSize,
        [Parameter(Mandatory = $false)] [String]$HarborAdminPassword,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Hostname,
        [Parameter(Mandatory = $false)] [String]$JobserviceSecret,
        [Parameter(Mandatory = $false)] [String]$JobserviceVolumeSize,
        [Parameter(Mandatory = $false)] [String]$RedisVolumeSize,
        [Parameter(Mandatory = $false)] [String]$RegistrySecret,
        [Parameter(Mandatory = $false)] [String]$RegistryVolumeSize,
        [Parameter(Mandatory = $false)] [String]$SecretKey,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$StorageClassName,
        [Parameter(Mandatory = $false)] [String]$TlsCrtPath,
        [Parameter(Mandatory = $false)] [String]$TlsKeyPath,
        [Parameter(Mandatory = $false)] [String]$TrivyVolumeSize,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$YamlContent
    )

    # Normalize Windows CRLF to LF before all regex substitutions. Without this, .*$ in
    # multiline mode consumes the trailing \r from each replaced line, producing mixed line
    # endings that go-yaml v3 (used by the Supervisor API) rejects with a parse error.
    $YamlContent = $YamlContent -replace '\r\n', "`n"

    # Set hostname; remove any leading # comment marker on the key line.
    $YamlContent = $YamlContent -replace '(?m)^(?:#\s*)?hostname:.*$', "hostname: $Hostname"

    # Set enableNginxLoadBalancer to true; remove any leading # comment marker on the key line.
    $YamlContent = $YamlContent -replace '(?m)^(?:#\s*)?(enableNginxLoadBalancer:)\s*.*$', 'enableNginxLoadBalancer: true'

    # Set enableContourHttpProxy to false; remove any leading # comment marker on the key line.
    $YamlContent = $YamlContent -replace '(?m)^(?:#\s*)?(enableContourHttpProxy:)\s*.*$', 'enableContourHttpProxy: false'

    # Replace all storageClass values; preserve indentation by capturing the key prefix.
    $YamlContent = $YamlContent -replace '(?m)^(\s+storageClass:\s*).*$', ('$1"' + $StorageClassName + '"')

    # Replace optional PVC sizes when specified; each section is targeted by its YAML path.
    # NOTE: replacement uses '${1}' not '$1' to prevent .NET regex greedy-digit parsing:
    # '$1' + '10Gi' concatenates to '$110Gi' which the engine parses as group 110 (empty),
    # collapsing the entire captured multi-line block. '${1}' explicitly delimits the group.
    if (-not [String]::IsNullOrWhiteSpace($RegistryVolumeSize)) {
        $YamlContent = $YamlContent -replace '(?m)(^    registry:\r?\n(?:      [^\n]*\r?\n)*?      size:\s*)\S+', ('${1}' + $RegistryVolumeSize)
    }
    if (-not [String]::IsNullOrWhiteSpace($JobserviceVolumeSize)) {
        # Jobservice size is nested under jobLog (persistence.persistentVolumeClaim.jobservice.jobLog.size).
        $YamlContent = $YamlContent -replace '(?m)(^    jobservice:\r?\n      jobLog:\r?\n(?:        [^\n]*\r?\n)*?        size:\s*)\S+', ('${1}' + $JobserviceVolumeSize)
    }
    if (-not [String]::IsNullOrWhiteSpace($DatabaseVolumeSize)) {
        $YamlContent = $YamlContent -replace '(?m)(^    database:\r?\n(?:      [^\n]*\r?\n)*?      size:\s*)\S+', ('${1}' + $DatabaseVolumeSize)
    }
    if (-not [String]::IsNullOrWhiteSpace($RedisVolumeSize)) {
        $YamlContent = $YamlContent -replace '(?m)(^    redis:\r?\n(?:      [^\n]*\r?\n)*?      size:\s*)\S+', ('${1}' + $RedisVolumeSize)
    }
    if (-not [String]::IsNullOrWhiteSpace($TrivyVolumeSize)) {
        $YamlContent = $YamlContent -replace '(?m)(^    trivy:\r?\n(?:      [^\n]*\r?\n)*?      size:\s*)\S+', ('${1}' + $TrivyVolumeSize)
    }
    # Replace optional secret values; $env: references are resolved from the environment.
    Set-HarborYamlSecretValues `
        -CoreSecret $CoreSecret `
        -DatabasePassword $DatabasePassword `
        -HarborAdminPassword $HarborAdminPassword `
        -JobserviceSecret $JobserviceSecret `
        -RegistrySecret $RegistrySecret `
        -SecretKey $SecretKey `
        -YamlContentRef ([Ref]$YamlContent)
    # Inject TLS certificate PEM content when TlsCrtPath and TlsKeyPath are provided.
    if (-not [String]::IsNullOrWhiteSpace($TlsCrtPath)) {
        $tlsInsertBlock = ConvertTo-YamlLiteralBlock -FilePath $TlsCrtPath -KeyName "tls.crt" -KeyIndentSpaces 2
        $tlsInsertBlock += ConvertTo-YamlLiteralBlock -FilePath $TlsKeyPath -KeyName "tls.key" -KeyIndentSpaces 2
        if (-not [String]::IsNullOrWhiteSpace($CaCrtPath)) {
            $tlsInsertBlock += ConvertTo-YamlLiteralBlock -FilePath $CaCrtPath -KeyName "ca.crt" -KeyIndentSpaces 2
        }
        # Insert the TLS block immediately after the tlsSecretLabels line in the tlsCertificate section.
        $YamlContent = $YamlContent -replace '(?m)(  tlsSecretLabels:[^\n]*\r?\n)', ('$1' + $tlsInsertBlock.Replace('$', '$$'))
    }
    # Warn if mandatory substitutions are not reflected in the output.
    if ($YamlContent -notmatch ('(?m)^hostname:\s*' + [Regex]::Escape($Hostname))) {
        Write-LogMessage -Type WARNING -Message "Update-HarborYamlContent: hostname `"$Hostname`" not found after replacement. Verify the template format."
    }
    if ($YamlContent -notmatch '(?m)^enableNginxLoadBalancer:\s*true') {
        Write-LogMessage -Type WARNING -Message "Update-HarborYamlContent: enableNginxLoadBalancer: true not found after replacement. Verify the template format."
    }
    if ($YamlContent -notmatch '(?m)^enableContourHttpProxy:\s*false') {
        Write-LogMessage -Type WARNING -Message "Update-HarborYamlContent: enableContourHttpProxy: false not found after replacement. Verify the template format."
    }
    if ($YamlContent -notmatch ('(?m)^\s+storageClass:\s*"?' + [Regex]::Escape($StorageClassName) + '"?')) {
        Write-LogMessage -Type WARNING -Message "Update-HarborYamlContent: Storage class `"$StorageClassName`" not found after replacement. Verify the template format."
    }
    return $YamlContent
}
function Write-HarborYamlDebugLog {

    <#
        .SYNOPSIS
        Logs a Harbor data values YAML string to DEBUG with numbered lines and secret redaction.

        .DESCRIPTION
        Splits the YAML on newlines, emits each line as a DEBUG log entry prefixed with its
        padded line number. Private key PEM literal blocks (tls.key, ca.key) are redacted to
        [REDACTED]. Scalar password/secret fields (harborAdminPassword, secretKey, password,
        secret) are also redacted. A BEGIN/END banner frames the output.

        .PARAMETER YamlContent
        The full YAML string to log.

        .EXAMPLE
        Write-HarborYamlDebugLog -YamlContent $yamlContent
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [String]$YamlContent
    )

    Write-LogMessage -Type DEBUG -Message "--- BEGIN HARBOR DATA VALUES (numbered) ---"
    $inSecretBlock = $false
    $secretBlockMinIndent = 0
    $lineNum = 0
    $YamlContent -split "`n" | ForEach-Object {
        $lineNum++
        $logLine = $_
        if ($inSecretBlock -and $logLine -match "^(\s+)\S" -and $matches[1].Length -ge $secretBlockMinIndent) {
            $logLine = $logLine -replace '\S.*$', '[REDACTED]'
        } elseif ($logLine -match '^(\s*)(?:tls\.key|ca\.key):\s*\|') {
            $inSecretBlock = $true
            $secretBlockMinIndent = $matches[1].Length + 1
        } else {
            $inSecretBlock = $false
            $logLine = $logLine -replace '^(\s*(?:harborAdminPassword|secretKey|password|secret):\s+)\S.*$', '$1[REDACTED]'
        }
        Write-LogMessage -Type DEBUG -Message "YAML line $($lineNum.ToString().PadLeft(4)): $logLine"
    }
    Write-LogMessage -Type DEBUG -Message "--- END HARBOR DATA VALUES ---"
}
function Set-TempFileOwnerOnlyPermissions {

    <#
        .SYNOPSIS
        Restricts a file to owner-only read/write using chmod (Unix) or ACL (Windows).

        .DESCRIPTION
        On non-Windows systems calls chmod 600. On Windows, disables inherited permissions
        and grants only the current user FullControl. Failures are logged as WARNING; the
        function is non-fatal so callers can proceed even if permissions cannot be set.

        .PARAMETER FilePath
        Full path to the file to restrict.

        .EXAMPLE
        Set-TempFileOwnerOnlyPermissions -FilePath $tempYamlFile
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$FilePath
    )

    if (-not $IsWindows) {
        & chmod 600 $FilePath
        if ($LASTEXITCODE -ne 0) {
            Write-LogMessage -Type WARNING -Message "Set-TempFileOwnerOnlyPermissions: chmod 600 failed (exit $LASTEXITCODE) on `"$FilePath`". File may be readable by other OS users."
        }
    } else {
        try {
            $acl = Get-Acl -Path $FilePath
            $acl.SetAccessRuleProtection($true, $false)
            $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
            $rule = [System.Security.AccessControl.FileSystemAccessRule]::new(
                $currentUser,
                [System.Security.AccessControl.FileSystemRights]::FullControl,
                [System.Security.AccessControl.InheritanceFlags]::None,
                [System.Security.AccessControl.PropagationFlags]::None,
                [System.Security.AccessControl.AccessControlType]::Allow
            )
            $acl.AddAccessRule($rule)
            Set-Acl -Path $FilePath -AclObject $acl
        } catch {
            Write-LogMessage -Type WARNING -Message "Set-TempFileOwnerOnlyPermissions: Could not restrict ACL on `"$FilePath`": $($_.Exception.Message). File may be readable by other OS users."
        }
    }
}
function New-HarborDataValuesFile {

    <#
        .SYNOPSIS
        Creates a temporary Harbor data values YAML file configured for a specific cluster.

        .DESCRIPTION
        Reads the provided Harbor data values YAML template, applies the following cluster-specific
        changes, and writes the result to a new temporary file:

        - Sets hostname to the provided value. Uncomments the key if preceded by a # marker.
        - Sets enableNginxLoadBalancer to true, unconditionally. Uncomments the key if preceded by #.
        - Sets enableContourHttpProxy to false, unconditionally. Uncomments the key if preceded by #.
        - Replaces every storageClass value in the persistence section with the storage policy name
          (StoragePolicyName), which matches the Kubernetes StorageClass automatically created by the
          Supervisor for this policy (e.g., "supervisor-OSA"). This is the same name as the tag applied
          to the datastore during vSAN/VMFS setup (supervisorNamePrefix + edgeSite).
        - Optionally replaces individual PVC sizes for registry, jobservice, database, redis, and
          trivy when the corresponding volume size parameter is provided.
        - Optionally replaces secret values (harborAdminPassword, secretKey, database.password,
          core.secret, jobservice.secret, registry.secret). Any value prefixed with "$env:" is
          resolved from the named environment variable at runtime instead of using the literal string,
          so secrets are never persisted in infrastructure.json.
        - When TlsCrtPath and TlsKeyPath are provided, their PEM file contents are injected as YAML
          literal block scalars (tls.crt and tls.key) under the tlsCertificate key. CaCrtPath may
          optionally be included as ca.crt in the same block.

        The temporary file is created in the system temp directory. The caller is responsible for
        cleaning it up after use.

        .PARAMETER CaCrtPath
        Optional. Full path to a PEM-encoded CA certificate file. When provided, its contents are
        injected as ca.crt under tlsCertificate in the YAML. Only valid when TlsCrtPath and
        TlsKeyPath are also provided.

        .PARAMETER CoreSecret
        Optional. Replacement value for core.secret in the YAML. If prefixed with "$env:", the
        value is read from the named environment variable at runtime.

        .PARAMETER DatabasePassword
        Optional. Replacement value for database.password in the YAML. If prefixed with "$env:",
        the value is read from the named environment variable at runtime.

        .PARAMETER DatabaseVolumeSize
        Optional. New size for the database PVC (persistence.persistentVolumeClaim.database.size).
        Must be a positive integer followed by "Gi" (e.g. "10Gi"). Omit to retain the template value.

        .PARAMETER EdgeSite
        The edge site identifier for this cluster (e.g., "ESA", "site1"). Used in the temporary
        file name for traceability.

        .PARAMETER HarborAdminPassword
        Optional. Replacement value for harborAdminPassword in the YAML. If prefixed with "$env:",
        the value is read from the named environment variable at runtime.

        .PARAMETER HarborTemplateFilePath
        Full path to the Harbor data values YAML template file. Typically the value of
        common.supervisorServices.harborDataTemplateYamlFileName (with parentDirectory) from infrastructure.json.

        .PARAMETER Hostname
        The DNS-compatible FQDN (or IP) that Harbor will be accessed at (e.g. "harbor.example.com").
        Sets the top-level hostname key; uncomments the key if it is preceded by a # marker.

        .PARAMETER JobserviceSecret
        Optional. Replacement value for jobservice.secret in the YAML. If prefixed with "$env:",
        the value is read from the named environment variable at runtime.

        .PARAMETER JobserviceVolumeSize
        Optional. New size for the jobservice PVC
        (persistence.persistentVolumeClaim.jobservice.jobLog.size).
        Must be a positive integer followed by "Gi" (e.g. "1Gi"). Omit to retain the template value.

        .PARAMETER RedisVolumeSize
        Optional. New size for the redis PVC (persistence.persistentVolumeClaim.redis.size).
        Must be a positive integer followed by "Gi" (e.g. "1Gi"). Omit to retain the template value.

        .PARAMETER RegistrySecret
        Optional. Replacement value for registry.secret in the YAML. If prefixed with "$env:",
        the value is read from the named environment variable at runtime.

        .PARAMETER RegistryVolumeSize
        Optional. New size for the registry PVC (persistence.persistentVolumeClaim.registry.size).
        Must be a positive integer followed by "Gi" (e.g. "10Gi"). Omit to retain the template value.

        .PARAMETER SecretKey
        Optional. Replacement value for secretKey in the YAML (used for encryption; must be 16 chars).
        If prefixed with "$env:", the value is read from the named environment variable at runtime.

        .PARAMETER StoragePolicyName
        The storage policy name for this cluster (e.g., "supervisor-OSA"). The Supervisor creates a
        Kubernetes StorageClass from this name by lowercasing it and replacing spaces with dashes
        (e.g., "supervisor-osa"). Equals supervisorNamePrefix concatenated with the edge site.

        .PARAMETER TlsCrtPath
        Optional. Full path to a PEM-encoded TLS certificate file. When provided (together with
        TlsKeyPath), its contents are injected as tls.crt under tlsCertificate in the YAML.
        Must be specified together with TlsKeyPath.

        .PARAMETER TlsKeyPath
        Optional. Full path to a PEM-encoded TLS private key file. When provided (together with
        TlsCrtPath), its contents are injected as tls.key under tlsCertificate in the YAML.
        Must be specified together with TlsCrtPath.

        .PARAMETER TrivyVolumeSize
        Optional. New size for the trivy PVC (persistence.persistentVolumeClaim.trivy.size).
        Must be a positive integer followed by "Gi" (e.g. "5Gi"). Omit to retain the template value.

        .OUTPUTS
        System.String. The full path to the temporary Harbor data values YAML file.

        .EXAMPLE
        $harborValuesPath = New-HarborDataValuesFile -EdgeSite "site1" -HarborTemplateFilePath "harbor-data-values-v2.14.2.yml" -Hostname "harbor.site1.example.com" -StoragePolicyName "supervisor-OSA"

        Creates a temporary Harbor data values file with hostname "harbor.site1.example.com",
        storageClass "supervisor-OSA", enableNginxLoadBalancer true, enableContourHttpProxy false,
        and all PVC sizes and secrets unchanged from the template.

        .EXAMPLE
        $harborValuesPath = New-HarborDataValuesFile -EdgeSite "site2" -HarborTemplateFilePath "harbor-data-values-v2.14.2.yml" -Hostname "harbor.site2.example.com" -StoragePolicyName "supervisor-site2" -RegistryVolumeSize "50Gi" -HarborAdminPassword '$env:HARBOR_ADMIN_PW' -TlsCrtPath "C:\certs\harbor.crt" -TlsKeyPath "C:\certs\harbor.key" -CaCrtPath "C:\certs\ca.crt"

        Creates a Harbor data values file with a custom hostname, overridden registry PVC size, an
        admin password resolved from the HARBOR_ADMIN_PW environment variable, and a custom TLS
        certificate with CA injected from the specified PEM files.

        .NOTES
        - The temporary file must be cleaned up by the caller after use (Remove-Item).
        - StoragePolicyName is lowercased (and spaces replaced with dashes) to derive the Kubernetes
          StorageClass name (e.g., policy "supervisor-OSA" -> StorageClass "supervisor-osa").
          Per Broadcom docs: the Supervisor converts policy names to lower case when creating StorageClasses.
        - Both enableNginxLoadBalancer and enableContourHttpProxy are set unconditionally, regardless
          of the template values, and any # comment prefix on those keys is removed.
        - All storageClass occurrences in the persistence.persistentVolumeClaim section are replaced.
        - Jobservice PVC size is nested at persistence.persistentVolumeClaim.jobservice.jobLog.size.
        - Secret values prefixed with "$env:" are resolved from environment variables at runtime,
          preventing plain-text secrets from being stored in infrastructure.json.
        - TlsCrtPath and TlsKeyPath must always be specified together. CaCrtPath is optional and
          only valid when both TLS file parameters are present. File existence is validated during
          the JSON deep check phase before deployment begins.
    #>

    [CmdletBinding()]
    [OutputType([String])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '')]
    Param (
        [Parameter(Mandatory = $false)] [String]$CaCrtPath,
        [Parameter(Mandatory = $false)] [String]$CoreSecret,
        [Parameter(Mandatory = $false)] [String]$DatabasePassword,
        [Parameter(Mandatory = $false)] [String]$DatabaseVolumeSize,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$EdgeSite,
        [Parameter(Mandatory = $false)] [String]$HarborAdminPassword,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$HarborTemplateFilePath,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Hostname,
        [Parameter(Mandatory = $false)] [String]$JobserviceSecret,
        [Parameter(Mandatory = $false)] [String]$JobserviceVolumeSize,
        [Parameter(Mandatory = $false)] [String]$RedisVolumeSize,
        [Parameter(Mandatory = $false)] [String]$RegistrySecret,
        [Parameter(Mandatory = $false)] [String]$RegistryVolumeSize,
        [Parameter(Mandatory = $false)] [String]$SecretKey,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$StoragePolicyName,
        [Parameter(Mandatory = $false)] [String]$TlsCrtPath,
        [Parameter(Mandatory = $false)] [String]$TlsKeyPath,
        [Parameter(Mandatory = $false)] [String]$TrivyVolumeSize
    )

    Write-LogMessage -Type DEBUG -Message "Entered New-HarborDataValuesFile function..."

    if (-not (Test-Path -Path $HarborTemplateFilePath)) {
        $err = "Harbor data values template file not found: `"$HarborTemplateFilePath`"."
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }

    # Kubernetes StorageClasses use a lowercase, dash-separated form of the storage policy name.
    # The Supervisor derives this automatically; we replicate the same transform here.
    $storageClassName = ($StoragePolicyName.ToLower() -replace ' ', '-')
    Write-LogMessage -Type DEBUG -Message "New-HarborDataValuesFile: hostname: `"$Hostname`", storageClass: `"$storageClassName`""

    $tempYamlFile = $null
    try {
        $tempPath = [System.IO.Path]::GetTempPath()
        # Use a GUID suffix rather than a timestamp so the filename is unpredictable to local processes.
        $tempYamlFile = Join-Path -Path $tempPath -ChildPath "harbor-data-values-$EdgeSite-$([Guid]::NewGuid().ToString('N')).yml"
        Write-LogMessage -Type DEBUG -Message "New-HarborDataValuesFile: Temporary file path: `"$tempYamlFile`""

        # Read the template and apply all cluster-specific YAML substitutions via helper.
        $rawYaml = Get-Content -LiteralPath $HarborTemplateFilePath -Raw -Encoding UTF8
        $updateParams = @{
            CaCrtPath           = $CaCrtPath
            CoreSecret          = $CoreSecret
            DatabasePassword    = $DatabasePassword
            DatabaseVolumeSize  = $DatabaseVolumeSize
            HarborAdminPassword = $HarborAdminPassword
            Hostname            = $Hostname
            JobserviceSecret    = $JobserviceSecret
            JobserviceVolumeSize = $JobserviceVolumeSize
            RedisVolumeSize     = $RedisVolumeSize
            RegistrySecret      = $RegistrySecret
            RegistryVolumeSize  = $RegistryVolumeSize
            SecretKey           = $SecretKey
            StorageClassName    = $storageClassName
            TlsCrtPath          = $TlsCrtPath
            TlsKeyPath          = $TlsKeyPath
            TrivyVolumeSize     = $TrivyVolumeSize
            YamlContent         = $rawYaml
        }
        $yamlContent = Update-HarborYamlContent @updateParams

        # Pre-validate YAML structure before writing; catches problems before the server does.
        # ConvertFrom-Yaml won't catch every go-yaml edge case, but will catch gross structural
        # errors (missing colons, bad indentation, etc.). Log line-numbered content so any
        # server-reported line number (e.g. "line 222") maps directly to a visible log entry.
        try {
            $null = ConvertFrom-Yaml -YamlContent $yamlContent
        } catch {
            Write-LogMessage -Type WARNING -Message "New-HarborDataValuesFile: YAML pre-validation failed: $($_.Exception.Message). Logging numbered content for diagnostics."
            Write-HarborYamlDebugLog -YamlContent $yamlContent
            $err = "Deployment failed. Generated Harbor YAML is structurally invalid. Check DEBUG logs for the full numbered content."
            Write-LogMessage -Type ERROR -Message $err
            throw [VcfDeploymentException]::new($err)
        }

        # Write secrets file with owner-only permissions to prevent other OS users from reading secrets.
        $yamlBytes = [System.Text.Encoding]::UTF8.GetBytes($yamlContent)
        $fileStream = [System.IO.File]::Open($tempYamlFile, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        try {
            $fileStream.Write($yamlBytes, 0, $yamlBytes.Length)
        } finally {
            $fileStream.Dispose()
        }
        # Restrict file to owner-only to prevent other OS users from reading secrets.
        Set-TempFileOwnerOnlyPermissions -FilePath $tempYamlFile

        if (-not (Test-Path -Path $tempYamlFile)) {
            $err = "New-HarborDataValuesFile: Temporary file was not created: `"$tempYamlFile`"."
            Write-LogMessage -Type ERROR -Message $err
            throw [VcfDeploymentException]::new($err)
        }

        Write-HarborYamlDebugLog -YamlContent $yamlContent

        Write-LogMessage -Type INFO -Message "Created temporary Harbor data values file for edge site `"$EdgeSite`" (hostname: `"$Hostname`", storageClass: `"$storageClassName`")"
        return $tempYamlFile
    } catch {
        $err = "New-HarborDataValuesFile: Failed to create Harbor data values file from template `"$HarborTemplateFilePath`": $($_.Exception.Message)"
        Write-LogMessage -Type ERROR -Message $err
        if ($tempYamlFile -and (Test-Path -Path $tempYamlFile)) {
            Remove-Item -Path $tempYamlFile -Force -ErrorAction SilentlyContinue
        }
        throw [VcfDeploymentException]::new($err)
    }
}
function Convert-CountToInt {

    <#
        .SYNOPSIS
        Recursively converts properties named "count" from float/string to integer in a PowerShell object.

        .DESCRIPTION
        Traverses PSCustomObjects, hashtables, and arrays in-place. Necessary because PowerShell
        deserializes JSON numbers as doubles, and the VCF PowerCLI 9 supervisor API rejects
        non-integer count fields. Case-insensitive match on "count". Truncates toward zero (5.9 → 5).

        .PARAMETER Item
        Any PowerShell object — PSCustomObject, hashtable, array, or scalar.
        Accepts pipeline input.

        .EXAMPLE
        $spec = $json | ConvertFrom-Json
        Convert-CountToInt $spec   # modifies $spec in place

        .NOTES
        Modifies objects in-place; does not return a value.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(ValueFromPipeline = $true)] $Item
    )

    process {
        if ($null -eq $Item) { return }

        # Strings are IEnumerable; treat them as scalars, not collections.
        if ($Item -is [System.Collections.IEnumerable] -and $Item -isnot [string]) {
            foreach ($elem in $Item) { Convert-CountToInt $elem }
            return
        }

        if ($Item -is [pscustomobject]) {
            foreach ($prop in $Item.PSObject.Properties) {
                if ($prop.Name -ieq 'count') {
                    $val = $prop.Value
                    if ($val -is [double] -or $val -is [single] -or $val -is [decimal]) {
                        $prop.Value = [Int][Double]$val
                    } elseif ($val -is [string]) {
                        $parsed = 0.0
                        if ([Double]::TryParse(
                            $val,
                            [System.Globalization.NumberStyles]::Float,
                            [System.Globalization.CultureInfo]::InvariantCulture,
                            [Ref] $parsed
                        )) {
                            $prop.Value = [Int][Double]$parsed
                        }
                    }
                }
                Convert-CountToInt $prop.Value
            }
            return
        }

        # Covers both [hashtable] and [ordered]@{} (OrderedDictionary) — both implement IDictionary.
        # Also covers hashtables produced by ConvertFrom-Json -AsHashtable.
        if ($Item -is [System.Collections.IDictionary]) {
            # @($Item.Keys) copies the key list so foreach can't observe mid-iteration mutations.
            foreach ($key in @($Item.Keys)) {
                if ($key -is [string] -and $key.Equals('count', [System.StringComparison]::OrdinalIgnoreCase)) {
                    $val = $Item[$key]
                    if ($val -is [double] -or $val -is [single] -or $val -is [decimal]) {
                        $Item[$key] = [Int][Double]$val
                    } elseif ($val -is [string]) {
                        $parsed = 0.0
                        if ([Double]::TryParse($val,
                            [System.Globalization.NumberStyles]::Float,
                            [System.Globalization.CultureInfo]::InvariantCulture,
                            [Ref] $parsed)) {
                            $Item[$key] = [Int][Double]$parsed
                        }
                    }
                }
                Convert-CountToInt $Item[$key]
            }
        }
    }
}
function Get-InteractiveInput {

    <#
        .SYNOPSIS
        Prompts the user for input with validation to ensure a non-empty value is provided.

        .DESCRIPTION
        The Get-InteractiveInput function provides a way to collect user input
        with optional validation that prevents empty responses. By default the function
        repeatedly prompts until a non-empty value is entered. When AllowEmpty is specified
        (e.g. for ESX root with no password), a single prompt is used and empty input is accepted.

        The function supports both standard text input and secure string input for
        sensitive information like passwords. When using secure string mode, the input
        is masked and returned as a SecureString object for enhanced security handling.

        This function is essential for interactive scripts that require user input and
        cannot proceed without valid data, providing a consistent user experience across
        the VCF PowerShell Toolbox.

        .PARAMETER AllowEmpty
        When specified, empty input is accepted and returned (e.g. for null/empty ESX root password).
        The prompt is shown once; pressing Enter without typing returns an empty string or empty SecureString.

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

        .EXAMPLE
        $esxPass = Get-InteractiveInput -PromptMessage "Enter ESX root password (or press Enter for no password): " -AsSecureString -AllowEmpty
        Collects ESX password interactively; empty input is accepted for null root password.

    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $false)] [Switch]$AllowEmpty,
        [Parameter(Mandatory = $false)] [Switch]$AsSecureString,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$PromptMessage
    )

    Write-LogMessage -Type DEBUG -Message "Entered Get-InteractiveInput function..."

    do {
        if ($AsSecureString) {
            $value = Read-Host $PromptMessage -asSecureString
        } else {
            $value = Read-Host $PromptMessage
        }
    } while ((-not $AllowEmpty) -and ($value.Length -eq 0))

    return $value
}
function Get-JsonDataWithValidation {

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
        $jsonFilePathData = Get-JsonDataWithValidation -JsonFilePath $JsonFilePath -JsonObjectName $JsonObjectName -ValidationResult ([Ref]$validationResult)
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

    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$JsonFilePath,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$JsonObjectName,
        [Parameter(Mandatory = $true)] [Ref]$ValidationResult
    )

    Write-LogMessage -Type DEBUG -Message "Validating and loading JSON file: $JsonFilePath"

    if (-not (Test-Path -Path $JsonFilePath -PathType Leaf)) {
        $ValidationResult.Value.IsValid = $false
        $ValidationResult.Value.ErrorCount = 1
        $ValidationResult.Value.Summary = "$JsonObjectName validation failed: File $JsonFilePath does not exist."
        Write-LogMessage -Type ERROR -Message $ValidationResult.Value.Summary
        return $null
    }

    try {
        $jsonFilePathData = ConvertFrom-JsonSafely -JsonFilePath $JsonFilePath
        $ValidationResult.Value.JsonData = $jsonFilePathData
        return $jsonFilePathData
    } catch {
        $ValidationResult.Value.IsValid = $false
        $ValidationResult.Value.ErrorCount = 1
        $ValidationResult.Value.Summary = "$JsonObjectName validation failed: Unable to parse JSON file $JsonFilePath. Error: $_"
        Write-LogMessage -Type ERROR -Message $ValidationResult.Value.Summary
        return $null
    }
}
function Test-JsonContent {

    <#
    .SYNOPSIS
        Validates that a file is non-empty and contains well-formed JSON using System.Text.Json.
    .DESCRIPTION
        Reads the file, checks for emptiness, then parses with JsonDocument for strict validation.
        Disposes the document in a finally block to prevent memory leaks. Returns $false on any
        failure; all errors are logged before returning.
    .PARAMETER JsonFilePath
        Full path to the JSON file to parse.
    .EXAMPLE
        if (-not (Test-JsonContent -JsonFilePath "infrastructure.json")) { return $false }
    .NOTES
        Returns $true when the content is valid JSON, $false otherwise (error already logged).
        Requires PowerShell 7.4 or later.
    #>

    [CmdletBinding()]
    [OutputType([Bool])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$JsonFilePath
    )

    $jsonDocument = $null
    try {
        Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "Validating JSON content in file: `"$JsonFilePath`""
        $content = Get-Content -Path $JsonFilePath -Raw -ErrorAction Stop
        if ([String]::IsNullOrWhiteSpace($content)) {
            Write-LogMessage -Type ERROR -Message "JSON file is empty or contains only whitespace: `"$JsonFilePath`""
            return $false
        }
        Add-Type -AssemblyName System.Text.Json -ErrorAction Stop
        $jsonDocument = [System.Text.Json.JsonDocument]::Parse($content)
        Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "JSON file validation successful: `"$JsonFilePath`""
        return $true
    } catch [System.Text.Json.JsonException] {
        Write-LogMessage -Type ERROR -Message "Invalid JSON format in file: `"$JsonFilePath`""
        Write-LogMessage -Type ERROR -Message "JSON parsing error: $($_.Exception.Message)"
        return $false
    } catch [System.ArgumentException] {
        Write-LogMessage -Type ERROR -Message "Invalid content encoding in JSON file: `"$JsonFilePath`""
        Write-LogMessage -Type ERROR -Message "Encoding error: $($_.Exception.Message)"
        return $false
    } catch [System.IO.FileNotFoundException] {
        Write-LogMessage -Type ERROR -Message "JSON file was deleted during validation: `"$JsonFilePath`""
        return $false
    } catch [System.OutOfMemoryException] {
        Write-LogMessage -Type ERROR -Message "JSON file too large to process: `"$JsonFilePath`". File may exceed available memory."
        return $false
    } catch {
        Write-LogMessage -Type ERROR -Message "Unexpected error during JSON validation for file: `"$JsonFilePath`""
        Write-LogMessage -Type ERROR -Message "Error details: $($_.Exception.Message)"
        return $false
    } finally {
        if ($jsonDocument) {
            try {
                $jsonDocument.Dispose()
                Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "JSON document resources properly disposed for: `"$JsonFilePath`""
            } catch {
                Write-LogMessage -Type WARNING -SuppressOutputToScreen -Message "Warning: Could not dispose JSON document resources for: `"$JsonFilePath`": $($_.Exception.Message)"
            }
        }
    }
}
function Test-JsonFile {

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
        Test-JsonFile -JsonFilePath "./config/settings.json"
        Returns $true if the file exists and contains valid JSON, $false otherwise.

        .EXAMPLE
        if (Test-JsonFile -JsonFilePath $configPath) {
            Write-LogMessage -Type INFO -Message "Configuration file is valid"
            $config = ConvertFrom-JsonSafely -JsonFilePath $configPath
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
        - Requires PowerShell 7.4 or later (same as the module manifest).
    #>

    [CmdletBinding()]
    [OutputType([Bool])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$JsonFilePath
    )

    Write-LogMessage -Type DEBUG -Message "Entered Test-JsonFile function..."

    if ([String]::IsNullOrWhiteSpace($JsonFilePath)) {
        Write-LogMessage -Type ERROR -Message "JSON file path cannot be null, empty, or contain only whitespace characters."
        return $false
    }
    if ($JsonFilePath.Length -gt 260) {
        Write-LogMessage -Type ERROR -Message "JSON file path cannot exceed 260 characters. Current length: $($JsonFilePath.Length)"
        return $false
    }
    if ($JsonFilePath -match '[<>"|?*]') {
        Write-LogMessage -Type ERROR -Message "JSON file path contains invalid characters: $($Matches[0])"
        return $false
    }

    if (-not (Test-Path -Path $JsonFilePath -PathType Leaf)) {
        Write-LogMessage -Type ERROR -Message "JSON file not found: `"$JsonFilePath`""
        return $false
    }

    $fileInfo = Get-Item -Path $JsonFilePath -ErrorAction SilentlyContinue
    if ($fileInfo -and $fileInfo.PSIsContainer) {
        Write-LogMessage -Type ERROR -Message "Specified path is a directory, not a file: `"$JsonFilePath`""
        return $false
    }

    try {
        $null = Get-Content -Path $JsonFilePath -TotalCount 1 -ErrorAction Stop
    } catch [System.UnauthorizedAccessException] {
        Write-LogMessage -Type ERROR -Message "Access denied reading JSON file: `"$JsonFilePath`". Please check file permissions."
        return $false
    } catch [System.IO.IOException] {
        Write-LogMessage -Type ERROR -Message "I/O error reading JSON file: `"$JsonFilePath`". File may be locked or corrupted."
        return $false
    } catch {
        Write-LogMessage -Type ERROR -Message "Unexpected error reading JSON file: `"$JsonFilePath`": $($_.Exception.Message)"
        return $false
    }

    return Test-JsonContent -JsonFilePath $JsonFilePath
}
function ConvertFrom-JsonSafely {

    <#
        .SYNOPSIS
        Safely loads and validates JSON content from a file with comprehensive error handling.

        .DESCRIPTION
        The ConvertFrom-JsonSafely function provides a robust way to load JSON files with
        built-in validation and error handling. The function reads the file content, removes
        empty lines that could cause JSON parsing issues, and converts the content to a
        PowerShell object. If JSON validation fails, the function logs detailed error
        information including the file path and specific parsing error, then throws so the caller can handle the error and prevent further execution with invalid data.

        This function standardizes JSON loading across the VCF PowerShell Toolbox and
        ensures consistent error reporting for troubleshooting.

        .PARAMETER JsonFilePath
        The full path to the JSON file to load and parse. The file must exist and
        contain valid JSON content.

        .EXAMPLE
        $config = ConvertFrom-JsonSafely -JsonFilePath "./configs/settings.json"
        Loads application settings from a JSON file with error handling.

        .NOTES
        This function throws if JSON parsing fails so the caller can handle the error.
        Empty lines are automatically filtered out before JSON parsing to handle
        files that may have formatting issues.
    #>

    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$JsonFilePath
    )

    Write-LogMessage -Type DEBUG -Message "Entered ConvertFrom-JsonSafely function..."

    try {
        # Read the file as a single string and strip blank lines before JSON parsing.
        # Using -Raw avoids building a per-line array; the regex removes blank lines that ConvertFrom-Json cannot handle.
        $rawContent = Get-Content -Path $JsonFilePath -Raw -Encoding UTF8 -ErrorAction Stop
        $cleanedContent = $rawContent -replace '(?m)^\s*$\n', ''
        return $cleanedContent | ConvertFrom-Json -ErrorVariable ErrorMessage

    } catch {
        # Handle JSON parsing errors with detailed, user-friendly logging.
        $errorMessage = $_.Exception.Message

        Write-LogMessage -Type ERROR -Message "JSON validation failed for file: $JsonFilePath."

        switch -Regex ($errorMessage) {
            "Bad JSON escape sequence: \\([A-Za-z])\..*'([^']+)'.*line (\d+).*position (\d+)" {
                $badChar = $Matches[1]
                $jsonFilePathPath = $Matches[2]
                $lineNum = $Matches[3]
                $position = $Matches[4]
                Write-LogMessage -Type ERROR -Message "Invalid escape sequence: `"\$badChar`" in JSON property `"$jsonFilePathPath`""
                Write-LogMessage -Type ERROR -Message "Location: Line $lineNum, Position $position"
                Write-LogMessage -Type ERROR -Message "Common causes:"
                Write-LogMessage -Type ERROR -Message "  1. Windows file paths must use forward slashes (/) or escaped backslashes (\\\\)"
                Write-LogMessage -Type ERROR -Message "     Example: `"C:/Users/Admin/file.yml`" or `"C:\\\\Users\\\\Admin\\\\file.yml`""
                Write-LogMessage -Type ERROR -Message "  2. Backslash (\) is a special character in JSON and must be escaped"
                Write-LogMessage -Type ERROR -Message "Please correct the JSON syntax in `"$JsonFilePath`" at line $lineNum and try again."
                break
            }
            "Conversion from JSON failed with error: (.+?)\. Path '([^']+)'.*line (\d+).*position (\d+)" {
                $jsonFilePathError = $Matches[1]
                $jsonFilePathPath = $Matches[2]
                $lineNum = $Matches[3]
                $position = $Matches[4]
                Write-LogMessage -Type ERROR -Message "JSON parsing error: $jsonFilePathError."
                Write-LogMessage -Type ERROR -Message "Property: `"$jsonFilePathPath`""
                Write-LogMessage -Type ERROR -Message "Location: Line $lineNum, Position $position"
                Write-LogMessage -Type ERROR -Message "Please correct the JSON syntax in `"$JsonFilePath`" and try again."
                break
            }
            default {
                # Do not append a period — exception messages may already end with one.
                Write-LogMessage -Type ERROR -Message "JSON parsing error: $errorMessage"
            }
        }

        $err = "JSON validation failed for `"$JsonFilePath`": $errorMessage"
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }
}
function Test-CommandAvailability {

    <#
        .SYNOPSIS
        Tests if a specified command/utility is available in the system PATH.

        .DESCRIPTION
        This function checks whether a given command or executable is available and accessible
        through the system PATH. It can be used to verify that required tools or utilities
        are installed before attempting to use them in the script. If the command is not found,
        the function logs an error and throws a terminating error.

        .EXAMPLE
        Test-CommandAvailability -Command $Script:VcfCmd -Description "vcf-cli"

        .PARAMETER Command
        The name of the command or executable to test for availability

        .PARAMETER Description
        A human-readable description of the command for use in error messages
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Command,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Description
    )

    Write-LogMessage -Type DEBUG -Message "Entered Test-CommandAvailability function..."

    if (Get-Command $Command -ErrorAction SilentlyContinue) {
        Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "Executable $Command found in PATH. Proceeding."
    } else {
        $err = "Executable `"$Command`" not found in PATH.  $Description is required for the script to proceed. Exiting"
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }
}
function Test-Filepath {

    <#
        .SYNOPSIS
        Tests if a specified file exists at the given file path.

        .DESCRIPTION
        The function Test-Filepath validates whether a file exists at the specified path.
        If the file exists, it logs a success message. If the file does not exist,
        it logs an error message and throws a terminating error.

        .EXAMPLE
        Test-Filepath -FilePath "./argocd.yml" -Description "ArgoCD configuration"

        .PARAMETER FilePath
        The absolute path to the file that needs to be validated for existence.

        .PARAMETER Description
        A descriptive name for the file being tested, used in log messages.

    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Description,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$FilePath
    )

    Write-LogMessage -Type DEBUG -Message "Entered Test-Filepath function..."

    if (Test-Path -Path $FilePath -PathType Leaf) {
        Write-LogMessage -Type INFO -Message "Found the `"$Description`" file on disk: `"$FilePath`"."
    } else {
        $err = "Failed to find `"$Description`" file on disk: `"$FilePath`" not found. Exiting."
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }
}
function Test-NestedProperty {

    <#
        .SYNOPSIS
        Tests whether a nested property exists in an object using dot notation path.

        .DESCRIPTION
        Traverses a nested object structure to verify if a property path exists.
        Supports both PowerShell custom objects (PSObject) and hashtables, following
        a dot-separated property path. Array notation (e.g., "clusters[].field") is
        supported — the remaining path must be present in at least one array element.

        .PARAMETER Object
        The root object to search within.

        .PARAMETER PropertyPath
        A string representing the property path using dot notation (e.g., "level1.level2.property").

        .OUTPUTS
        Boolean — $true if the complete path exists, $false if any segment is missing.

        .EXAMPLE
        $found = Test-NestedProperty -Object $config -PropertyPath "database.connection.host"

        Returns $true if the full path database.connection.host exists in $config, $false otherwise.

        .NOTES
        Works with mixed object hierarchies (hashtables and PSObjects at any depth).
        Stops at the first missing segment and returns $false immediately.
    #>

    [CmdletBinding()]
    [OutputType([Bool])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object]$Object,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$PropertyPath
    )

    $properties = $PropertyPath -split '\.'
    $currentObject = $Object

    for ($propertyIndex = 0; $propertyIndex -lt $properties.Count; $propertyIndex++) {
        $property = $properties[$propertyIndex]
        $isArrayNotation = $property -match '^(.+)\[\]$'

        if ($isArrayNotation) {
            $arrayPropertyName = $matches[1]
            $arrayExists = $false
            if ($currentObject -is [System.Collections.Hashtable]) {
                $arrayExists = $currentObject.ContainsKey($arrayPropertyName)
                if ($arrayExists) { $arrayObject = $currentObject[$arrayPropertyName] }
            }
            elseif ($currentObject.PSObject.Properties[$arrayPropertyName]) {
                $arrayExists = $true
                $arrayObject = $currentObject.$arrayPropertyName
            }

            if (-not $arrayExists) { return $false }
            if ($arrayObject -isnot [System.Collections.IList]) { return $false }
            if ($propertyIndex -eq ($properties.Count - 1)) { return ($arrayObject.Count -gt 0) }

            $remainingPath = $properties[($propertyIndex + 1)..($properties.Count - 1)] -join '.'
            $foundInAnyElement = $false
            foreach ($element in $arrayObject) {
                if (Test-NestedProperty -Object $element -PropertyPath $remainingPath) {
                    $foundInAnyElement = $true
                    break
                }
            }
            return $foundInAnyElement
        }
        else {
            if ($currentObject -is [System.Collections.Hashtable]) {
                if (-not $currentObject.ContainsKey($property)) { return $false }
                $currentObject = $currentObject[$property]
            }
            elseif ($currentObject.PSObject.Properties[$property]) {
                $currentObject = $currentObject.$property
            }
            else {
                return $false
            }
        }
    }

    return $true
}
function Get-ExpectedStructure {

    <#
        .SYNOPSIS
        Generates a nested hashtable template for a missing JSON property path.

        .DESCRIPTION
        Creates a hierarchical hashtable representing the expected JSON structure for
        a missing property specified using dot notation. Each path segment becomes a
        nested level in the resulting structure, with "<value>" as the leaf placeholder.
        Array notation (e.g., "clusters[]") produces a single-element array.

        .PARAMETER PropertyPath
        A string representing the property path using dot notation.

        .OUTPUTS
        System.Collections.Hashtable — Nested hashtable showing the expected JSON structure.

        .EXAMPLE
        $template = Get-ExpectedStructure -PropertyPath "config.database.host"

        Returns @{ config = @{ database = @{ host = "<value>" } } }.

        .NOTES
        The placeholder value "<value>" marks where actual data should be provided.
    #>

    [CmdletBinding()]
    [OutputType([Hashtable])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$PropertyPath
    )

    Write-LogMessage -Type DEBUG -Message "Entered Get-ExpectedStructure function..."

    $properties = $PropertyPath -split '\.'
    $structure = @{}
    $currentLevel = $structure

    for ($propertyIndex = 0; $propertyIndex -lt $properties.Count; $propertyIndex++) {
        $property = $properties[$propertyIndex]
        $isArrayNotation = $property -match '^(.+)\[\]$'

        if ($isArrayNotation) {
            $arrayPropertyName = $matches[1]
            $arrayElement = @{}
            $currentLevel[$arrayPropertyName] = @($arrayElement)
            $currentLevel = $arrayElement
            if ($propertyIndex -eq ($properties.Count - 1)) { return $structure }
        }
        else {
            if ($propertyIndex -eq ($properties.Count - 1)) {
                $currentLevel[$property] = "<value>"
            }
            else {
                $currentLevel[$property] = @{}
                $currentLevel = $currentLevel[$property]
            }
        }
    }

    return $structure
}
function Test-JsonMissingProperties {

    <#
        .SYNOPSIS
        Validates JSON file content for missing required properties with support for nested properties.

        .DESCRIPTION
        Provides comprehensive validation of JSON files to ensure all required properties are
        present. Supports nested property validation using dot notation (e.g., "common.vCenter.name")
        and array notation (e.g., "clusters[].edgeSite"). Provides detailed reporting of missing
        properties and their expected structure on request.

        .PARAMETER JsonFilePath
        The full path to the JSON file to validate.

        .PARAMETER RequiredProperties
        An array of property names (using dot notation for nested properties) that must be present.

        .PARAMETER JsonObjectName
        A descriptive name for the JSON object, used in error messages.

        .PARAMETER StopOnFirstError
        When specified, stops validation and returns immediately after the first missing property.

        .PARAMETER ShowExpectedStructure
        When specified, includes the expected JSON structure for each missing property in the result.

        .OUTPUTS
        PSCustomObject with: IsValid, MissingProperties, ExpectedStructure, ErrorCount, Summary, JsonData.

        .EXAMPLE
        $result = Test-JsonMissingProperties -JsonFilePath "config.json" -RequiredProperties @("database.host", "api.key") -JsonObjectName "Configuration"
        if (-not $result.IsValid) { Write-LogMessage -Type ERROR -Message $result.Summary }

        .NOTES
        Uses Test-NestedProperty for property traversal and Get-ExpectedStructure for structure
        template generation. JSON is loaded via ConvertFrom-JsonSafely through Get-JsonDataWithValidation.
    #>

    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$JsonFilePath,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$JsonObjectName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String[]]$RequiredProperties,
        [Parameter(Mandatory = $false)] [Switch]$ShowExpectedStructure,
        [Parameter(Mandatory = $false)] [Switch]$StopOnFirstError
    )

    Write-LogMessage -Type DEBUG -Message "Entered Test-JsonMissingProperties function..."

    $validationResult = [PSCustomObject]@{
        IsValid = $true
        MissingProperties = [System.Collections.Generic.List[String]]::new()
        ExpectedStructure = @{}
        ErrorCount = 0
        Summary = ""
        JsonData = $null
    }

    Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "Validating $($RequiredProperties.Count) required properties: $($RequiredProperties -join ', ')"

    $jsonFilePathData = Get-JsonDataWithValidation -JsonFilePath $JsonFilePath -JsonObjectName $JsonObjectName -ValidationResult ([Ref]$validationResult)
    if ($null -eq $jsonFilePathData) {
        return $validationResult
    }

    foreach ($property in $RequiredProperties) {
        if (-not (Test-NestedProperty -Object $jsonFilePathData -PropertyPath $property)) {
            $validationResult.IsValid = $false
            $validationResult.MissingProperties.Add($property)
            $validationResult.ErrorCount++
            Write-LogMessage -Type ERROR -Message "$JsonObjectName (in JSON file $JsonFilePath) is missing required property: $property"
            if ($ShowExpectedStructure) {
                $validationResult.ExpectedStructure[$property] = Get-ExpectedStructure -PropertyPath $property
            }
            if ($StopOnFirstError) { break }
        }
    }

    if ($validationResult.IsValid) {
        $validationResult.Summary = "$JsonObjectName validation passed. All $($RequiredProperties.Count) required properties are present."
        Write-LogMessage -Type INFO -Message $validationResult.Summary -SuppressOutputToScreen
    }
    else {
        $validationResult.Summary = "$JsonObjectName validation failed. $($validationResult.ErrorCount) of $($RequiredProperties.Count) required properties are missing: $($validationResult.MissingProperties -join ', ')"
        Write-LogMessage -Type ERROR -Message $validationResult.Summary
        if ($ShowExpectedStructure -and $validationResult.ExpectedStructure.Count -gt 0) {
            Write-LogMessage -Type INFO -Message "Expected JSON structure for missing properties:"
            foreach ($missingProp in $validationResult.MissingProperties) {
                $structureJson = $validationResult.ExpectedStructure[$missingProp] | ConvertTo-Json -Depth 10
                Write-LogMessage -Type INFO -Message "Property `"$missingProp`" expected structure: $structureJson"
            }
        }
    }

    return $validationResult
}
function Test-JsonNullValues {

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
            Write-LogMessage -Type ERROR -Message "Validation failed: $($validationResult.Summary)"
            return
        }

        .EXAMPLE
        $requiredProps = @(
            "common.vCenterName",
            "common.VcenterUser",
            "common.esxHost"
        )
        $result = Test-JsonNullValues -JsonFilePath "infrastructure.json" -RequiredProperties $requiredProps -JsonObjectName "InputConfiguration"

        .NOTES
        - This function is designed to work in conjunction with Test-JsonMissingProperties
        - First check if keys exist (Test-JsonMissingProperties), then check if values are non-null (Test-JsonNullValues)
        - Uses Get-JsonPropertyValue to retrieve nested property values
        - Integrates with VCF PowerShell Toolbox logging infrastructure
        - Null values in arrays or objects are also detected

        Error Handling: Main workflow function. Throws a terminating error on critical
        validation failures when properties contain null values.
    #>

    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$JsonFilePath,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$JsonObjectName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String[]]$RequiredProperties,
        [Parameter(Mandatory = $false)] [Switch]$StopOnFirstError
    )

    Write-LogMessage -Type DEBUG -Message "Entered Test-JsonNullValues function..."

    $validationResult = [PSCustomObject]@{
        IsValid = $true
        NullProperties = [System.Collections.Generic.List[String]]::new()
        ErrorCount = 0
        Summary = ""
        JsonData = $null
    }

    Write-LogMessage -Type DEBUG -Message "Checking $($RequiredProperties.Count) properties for null values: $($RequiredProperties -join ', ')"

    $jsonFilePathData = Get-JsonDataWithValidation -JsonFilePath $JsonFilePath -JsonObjectName $JsonObjectName -ValidationResult ([Ref]$validationResult)
    if ($null -eq $jsonFilePathData) {
        return $validationResult
    }

    foreach ($Property in $RequiredProperties) {
        $hasArrayNotation = $Property -match '\[\]'

        if ($hasArrayNotation) {
            $arrayPathParts = $Property -split '\.'
            $arrayPropertyIndex = -1
            $arrayPropertyName = $null

            for ($partIndex = 0; $partIndex -lt $arrayPathParts.Count; $partIndex++) {
                if ($arrayPathParts[$partIndex] -match '^(.+)\[\]$') {
                    $arrayPropertyIndex = $partIndex
                    $arrayPropertyName = $matches[1]
                    break
                }
            }

            if ($arrayPropertyIndex -ge 0) {
                $currentObject = $jsonFilePathData
                for ($navIndex = 0; $navIndex -lt $arrayPropertyIndex; $navIndex++) {
                    $part = $arrayPathParts[$navIndex]
                    if ($currentObject -is [PSCustomObject]) {
                        $currentObject = $currentObject.$part
                    } elseif ($currentObject -is [Hashtable]) {
                        $currentObject = $currentObject[$part]
                    } else {
                        $currentObject = $currentObject.$part
                    }
                }

                if ($currentObject -is [PSCustomObject]) {
                    $arrayObject = $currentObject.$arrayPropertyName
                } elseif ($currentObject -is [Hashtable]) {
                    $arrayObject = $currentObject[$arrayPropertyName]
                } else {
                    $arrayObject = $currentObject.$arrayPropertyName
                }

                if ($null -eq $arrayObject -or $arrayObject -isnot [System.Collections.IList]) {
                    $validationResult.IsValid = $false
                    $validationResult.NullProperties.Add($Property)
                    $validationResult.ErrorCount++
                    Write-LogMessage -Type ERROR -Message "$JsonObjectName (in JSON file $JsonFilePath) property `"$Property`" array `"$arrayPropertyName`" is null or not an array. Please provide a valid value."
                    if ($StopOnFirstError) {
                        break
                    }
                    continue
                }

                $remainingPathParts = $arrayPathParts[($arrayPropertyIndex + 1)..($arrayPathParts.Count - 1)]

                $elementIndex = 0
                foreach ($element in $arrayObject) {
                    $nullFound = Test-ArrayPropertyNullValue -Object $element -PathParts $remainingPathParts -PropertyPath $Property

                    if ($nullFound) {
                        $validationResult.IsValid = $false
                        if (-not $validationResult.NullProperties.Contains($Property)) {
                            $validationResult.NullProperties.Add($Property)
                        }
                        $validationResult.ErrorCount++
                        Write-LogMessage -Type ERROR -Message "$JsonObjectName (in JSON file $JsonFilePath) property `"$Property`" has a null value at array index $elementIndex. Please provide a valid value."
                        if ($StopOnFirstError) {
                            break
                        }
                    }
                    $elementIndex++
                }

                if ($StopOnFirstError -and -not $validationResult.IsValid) {
                    break
                }
            }
        }
        else {
            $propertyValue = Get-JsonPropertyValue -InputData $jsonFilePathData -PropertyPath $Property

            if ($null -eq $propertyValue -or ($propertyValue -is [String] -and $propertyValue -eq "")) {
                $validationResult.IsValid = $false
                $validationResult.NullProperties.Add($Property)
                $validationResult.ErrorCount++

                Write-LogMessage -Type ERROR -Message "$JsonObjectName (in JSON file $JsonFilePath) property `"$Property`" has a null value. Please provide a valid value."

                if ($StopOnFirstError) {
                    break
                }
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
function Resolve-PropertyOnObject {

    <#
        .SYNOPSIS
        Resolves a single named property from a PSCustomObject, Hashtable, or generic object.

        .DESCRIPTION
        Returns a hashtable with Exists ($true/$false) and Value. Handles the three concrete
        object types used in JSON deserialization: PSCustomObject, Hashtable, and generic .NET
        objects. Returns Exists=$false when the property does not exist or access throws.

        .PARAMETER Object
        The object to read the property from.

        .PARAMETER PropertyName
        The property name to resolve.

        .OUTPUTS
        Hashtable — @{ Exists=[Bool]; Value=[Object] }
    
        .EXAMPLE
        $propertyOnObject = Resolve-PropertyOnObject -Object $resourceObject -PropertyName "resource-name"
    #>

    [CmdletBinding()]
    [OutputType([Hashtable])]
    Param (
        [Parameter(Mandatory = $true)] [AllowNull()] [Object]$Object,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$PropertyName
    )

    if ($Object -is [PSCustomObject]) {
        $prop = $Object.PSObject.Properties[$PropertyName]
        if ($null -eq $prop) { return @{ Exists = $false; Value = $null } }
        return @{ Exists = $true; Value = $Object.$PropertyName }
    }
    if ($Object -is [Hashtable]) {
        if (-not $Object.ContainsKey($PropertyName)) { return @{ Exists = $false; Value = $null } }
        return @{ Exists = $true; Value = $Object[$PropertyName] }
    }
    try {
        $member = $Object | Get-Member -Name $PropertyName -ErrorAction SilentlyContinue
        if ($null -eq $member) { return @{ Exists = $false; Value = $null } }
        return @{ Exists = $true; Value = $Object.$PropertyName }
    } catch {
        Write-LogMessage -Type DEBUG -Message "Property access failed for '$PropertyName': $($_.Exception.Message)"
        return @{ Exists = $false; Value = $null }
    }
}
function Test-ArrayPropertyNullValue {

    <#
        .SYNOPSIS
        Iteratively checks for null values in nested array properties.

        .DESCRIPTION
        Helper function that iteratively navigates through object properties and arrays
        to check for null values. Handles nested array notation like clusters[].networking.networkSegments[].name.
        Uses Resolve-PropertyOnObject for consistent property access across PSCustomObject,
        Hashtable, and generic object types.

        .PARAMETER Object
        The object to check for null values.

        .PARAMETER PathParts
        Array of path parts remaining to navigate.

        .PARAMETER PropertyPath
        The full property path for error reporting.

        .OUTPUTS
        Boolean - Returns $true if a null value is found, $false otherwise.
    
        .EXAMPLE
        Test-ArrayPropertyNullValue -Object $resourceObject -PathParts "config.json" -PropertyPath "config.json"
    #>

    [CmdletBinding()]
    [OutputType([Bool])]
    Param (
        [Parameter(Mandatory = $true)] [AllowNull()] [Object]$Object,
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [Object[]]$PathParts,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$PropertyPath
    )

    $currentObject = $Object
    $currentPathParts = $PathParts

    while ($true) {
        if ($currentPathParts.Count -eq 0) {
            if ($null -eq $currentObject) { return $true }
            if ($currentObject -is [String]) { return [String]::IsNullOrEmpty($currentObject) }
            if ($currentObject -is [System.Collections.IList]) { return ($currentObject.Count -eq 0) }
            return $false
        }
        if ($null -eq $currentObject) { return $true }

        $currentPart = $currentPathParts[0]
        # Direct if/else avoids PowerShell if-expression unboxing: a single-element array returned
        # through an if-expression is unboxed to a plain string, and string[0] returns a Char, not
        # the element. Direct assignment always preserves the array type.
        if ($currentPathParts.Count -eq 1) {
            $remainingParts = @()
        } else {
            $remainingParts = $currentPathParts[1..($currentPathParts.Count - 1)]
        }
        $isArrayNotation = $currentPart -match '^(.+)\[\]$'

        if ($isArrayNotation) {
            $resolved = Resolve-PropertyOnObject -Object $currentObject -PropertyName $matches[1]
            if (-not $resolved.Exists) { return $true }
            $arrayObject = $resolved.Value
            if ($null -eq $arrayObject -or $arrayObject -isnot [System.Collections.IList]) { return $true }
            if ($arrayObject.Count -eq 0) { return $true }
            # Recursively check each element — any null propagates upward.
            foreach ($element in $arrayObject) {
                if (Test-ArrayPropertyNullValue -Object $element -PathParts $remainingParts -PropertyPath $PropertyPath) {
                    return $true
                }
            }
            return $false
        }
        else {
            $resolved = Resolve-PropertyOnObject -Object $currentObject -PropertyName $currentPart
            if (-not $resolved.Exists) { return $true }
            $currentObject = $resolved.Value
            $currentPathParts = $remainingParts
        }
    }
}
function Get-EdgeSitesFromParameter {

    <#
        .SYNOPSIS
        Parses the comma-delimited -EdgeSite parameter and returns validated edge site names.

        .DESCRIPTION
        Splits the -EdgeSite string by comma, trims each value, and validates that every name
        exists in the infrastructure JSON clusters array. Fails if an invalid delimiter (e.g. semicolon)
        is used or if any specified site is not defined in the infrastructure.

        .PARAMETER EdgeSite
        Comma-delimited list of edge site names (e.g. "site1,site2"). Only comma is allowed as separator.

        .PARAMETER InfrastructureJson
        Path to the infrastructure JSON file. Used to load clusters when InputData is not provided.

        .PARAMETER InputData
        Parsed infrastructure JSON object. When provided, avoids re-reading the file.

        .OUTPUTS
        String array of edge site names in the order specified. Empty array when EdgeSite is null or whitespace.

        .NOTES
        Caller must pass either InputData or InfrastructureJson when EdgeSite is specified.
    
        .EXAMPLE
        $edgeSitesFromParameter = Get-EdgeSitesFromParameter
        if ($null -eq $edgeSitesFromParameter) {
            Write-LogMessage -Type ERROR -Message "Get-EdgeSitesFromParameter: result not found."
        }
    #>

    [CmdletBinding()]
    [OutputType([System.Object[]])]
    Param (
        [Parameter(Mandatory = $false)] [String]$EdgeSite,
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$InfrastructureJson,
        [Parameter(Mandatory = $false)] [Object]$InputData
    )

    if ([String]::IsNullOrWhiteSpace($EdgeSite)) {
        return @()
    }

    # Reject invalid delimiters. Only comma is allowed.
    $invalidDelimiters = @(';', '|')
    foreach ($delim in $invalidDelimiters) {
        if ($EdgeSite.IndexOf($delim) -ge 0) {
            $err = "Invalid delimiter in -EdgeSite. Use only comma to separate edge site names (e.g. -EdgeSite site1,site2)."
            Write-LogMessage -Type ERROR -Message $err
            throw [VcfDeploymentException]::new($err)
        }
    }

    $requestedSites = @($EdgeSite -split ',' | ForEach-Object { $_.Trim() } | Where-Object { -not [String]::IsNullOrWhiteSpace($_) })
    if ($requestedSites.Count -eq 0) {
        $err = "No valid edge site names in -EdgeSite after splitting by comma."
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }

    if (-not $InputData -and -not $InfrastructureJson) {
        $err = "Get-EdgeSitesFromParameter requires InputData or InfrastructureJson when EdgeSite is specified."
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }

    if (-not $InputData) {
        $InputData = ConvertFrom-JsonSafely -JsonFilePath $InfrastructureJson
    }

    $validSites = @($InputData.clusters | Select-Object -ExpandProperty edgeSite | Where-Object { -not [String]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    $invalidSites = @($requestedSites | Where-Object { $_ -notin $validSites })
    if ($invalidSites.Count -gt 0) {
        $validList = if ($validSites.Count -gt 0) { $validSites -join ", " } else { "(none defined)" }
        $err = "EdgeSite value(s) not defined in infrastructure JSON: $($invalidSites -join ', '). Valid edgeSite values in clusters[].edgeSite are: $validList"
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }

    return $requestedSites
}
function Get-EffectiveNicListForCluster {

    <#
        .SYNOPSIS
        Returns the effective nicList for a cluster (cluster override or common).

        .DESCRIPTION
        Cluster nicList takes precedence over common.nicList. If the cluster has nicList
        defined and it has 2 or 4 elements, that is returned; otherwise common.nicList
        is returned. Used for VDS uplink configuration and rollback.

        .PARAMETER Cluster
        Cluster object from infrastructure JSON (clusters[] element).

        .PARAMETER CommonNicList
        common.nicList from infrastructure JSON.

        .OUTPUTS
        Array of NIC config objects (2 or 4 elements). Caller must validate count separately when required.
    
        .EXAMPLE
        $effectiveNicListForCluster = Get-EffectiveNicListForCluster -Cluster $clusterObject
    #>

    [CmdletBinding()]
    [OutputType([Object[]])]
    Param (
        [Parameter(Mandatory = $true)] [Object]$Cluster,
        [Parameter(Mandatory = $false)] [Object]$CommonNicList
    )

    $clusterNicList = $null
    if ($Cluster -and $Cluster.PSObject.Properties["nicList"] -and $null -ne $Cluster.nicList -and $Cluster.nicList -is [Array]) {
        $clusterNicList = @($Cluster.nicList)
    }
    if ($clusterNicList -and ($clusterNicList.Count -eq 2 -or $clusterNicList.Count -eq 4)) {
        return $clusterNicList
    }
    return $CommonNicList
}
function Test-InfrastructureNicListEffective {

    <#
        .SYNOPSIS
        Validates that every cluster has an effective nicList (cluster or common) with 2 or 4 NICs.

        .DESCRIPTION
        At least one definition of nicList is mandatory per cluster: either common.nicList
        or clusters[].nicList. Cluster nicList overrides common. Effective list must have
        exactly 2 or 4 NICs (one VDS or two VDS). Throws if any cluster has no effective
        nicList or invalid count.

        .PARAMETER InputData
        Parsed infrastructure JSON object.

        .PARAMETER Clusters
        Array of cluster objects to validate (e.g. all clusters or filtered by EdgeSite).
    
        .EXAMPLE
        $infrastructureNicListEffectiveResult = Test-InfrastructureNicListEffective -Clusters $clustersArray -InputData $parsedConfig
        if (-not $infrastructureNicListEffectiveResult.IsValid) { Write-LogMessage -Type ERROR -Message $infrastructureNicListEffectiveResult.Summary }
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [Object[]]$Clusters,
        [Parameter(Mandatory = $true)] [Object]$InputData
    )

    $commonNicList = $null
    if ($InputData.common -and $InputData.common.PSObject.Properties["nicList"] -and $null -ne $InputData.common.nicList -and $InputData.common.nicList -is [Array]) {
        $commonNicList = @($InputData.common.nicList)
    }

    foreach ($cluster in $Clusters) {
        $effective = Get-EffectiveNicListForCluster -Cluster $cluster -CommonNicList $commonNicList
        $edgeSite = if ($cluster.edgeSite) { $cluster.edgeSite } else { "(unknown)" }
        if (-not $effective -or $effective -isnot [Array] -or $effective.Count -eq 0) {
            $err = "Cluster edgeSite `"$edgeSite`": nicList must be defined at common or at cluster level. Define common.nicList or clusters[].nicList with 2 or 4 NICs."
            Write-LogMessage -Type ERROR -Message $err
            throw [VcfDeploymentException]::new($err)
        }
        if ($effective.Count -ne 2 -and $effective.Count -ne 4) {
            $err = "Cluster edgeSite `"$edgeSite`": effective nicList must contain exactly 2 or 4 NICs. Found $($effective.Count)."
            Write-LogMessage -Type ERROR -Message $err
            throw [VcfDeploymentException]::new($err)
        }
    }
}
function Test-EdgeSiteSetConsistency {

    <#
    .SYNOPSIS
        Validates that two sets of edgeSite values contain no duplicates and are mutually consistent.
    .DESCRIPTION
        Checks for duplicate edgeSite values within each set, then verifies every value in
        InfrastructureEdgeSites is present in SupervisorEdgeSites and vice versa. Returns a
        result object; does NOT log errors itself — callers are responsible for logging.
    .PARAMETER InfrastructureEdgeSites
        Array of edgeSite strings collected from the infrastructure JSON.
    .PARAMETER SupervisorEdgeSites
        Array of edgeSite strings collected from the supervisor JSON.
    .EXAMPLE
        $result = Test-EdgeSiteSetConsistency -InfrastructureEdgeSites @("site1") -SupervisorEdgeSites @("site1")
    .NOTES
        Returns a hashtable with IsValid ([Bool]) and ErrorMessage ([String]).
    #>

    [CmdletBinding()]
    [OutputType([Hashtable])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [String[]]$InfrastructureEdgeSites,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [String[]]$SupervisorEdgeSites
    )

    $result = @{ IsValid = $true; ErrorMessage = "" }

    $infraDuplicates = $InfrastructureEdgeSites | Group-Object | Where-Object { $_.Count -gt 1 }
    if ($infraDuplicates) {
        $result.IsValid = $false
        $result.ErrorMessage = "Duplicate edgeSite values found in infrastructure JSON: $($infraDuplicates.Name -join ', ')"
        return $result
    }

    $supervisorDuplicates = $SupervisorEdgeSites | Group-Object | Where-Object { $_.Count -gt 1 }
    if ($supervisorDuplicates) {
        $result.IsValid = $false
        $result.ErrorMessage = "Duplicate edgeSite values found in supervisor JSON: $($supervisorDuplicates.Name -join ', ')"
        return $result
    }

    $missingInSupervisor = $InfrastructureEdgeSites | Where-Object { $_ -notin $SupervisorEdgeSites }
    if ($missingInSupervisor) {
        $result.IsValid = $false
        $result.ErrorMessage = "EdgeSite values in infrastructure JSON without matching supervisor entries: $($missingInSupervisor -join ', ')"
        return $result
    }

    $missingInInfrastructure = $SupervisorEdgeSites | Where-Object { $_ -notin $InfrastructureEdgeSites }
    if ($missingInInfrastructure) {
        $result.IsValid = $false
        $result.ErrorMessage = "EdgeSite values in supervisor JSON without matching infrastructure entries: $($missingInInfrastructure -join ', ')"
        return $result
    }

    return $result
}
function Test-EdgeSiteMatching {

    <#
        .SYNOPSIS
        Validates that all edgeSite values in infrastructure JSON have matching entries in supervisor JSON.

        .DESCRIPTION
        This function validates that every edgeSite value in the infrastructure JSON clusters array
        has a corresponding entry in the supervisor JSON siteSpec array, and vice versa.
        This ensures proper linking between infrastructure and supervisor configurations.

        .PARAMETER InfrastructureJson
        Full path to the infrastructure JSON configuration file.

        .PARAMETER SupervisorJson
        Full path to the supervisor JSON configuration file.

        .OUTPUTS
        PSCustomObject with the following properties:
        - IsValid: Boolean indicating if all edgeSite values match
        - ErrorMessage: String containing details about any validation failures

        .EXAMPLE
        $result = Test-EdgeSiteMatching -InfrastructureJson "infrastructure.json" -SupervisorJson "supervisor.json"
        if (-not $result.IsValid) {
            Write-LogMessage -Type ERROR -Message $result.ErrorMessage
        }
    #>

    [CmdletBinding()]
    [OutputType([Bool])]
    Param (
        [Parameter(Mandatory = $false)] [String]$EdgeSite,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$InfrastructureJson,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$SupervisorJson
    )

    Write-LogMessage -Type DEBUG -Message "Entered Test-EdgeSiteMatching function..."

    $validationResult = @{
        IsValid = $true
        ErrorMessage = ""
    }

    try {
        $infrastructureData = ConvertFrom-JsonSafely -JsonFilePath $InfrastructureJson
        $supervisorData = ConvertFrom-JsonSafely -JsonFilePath $SupervisorJson

        # Collect edgeSite values from infrastructure JSON.
        $infrastructureEdgeSites = [System.Collections.Generic.List[String]]::new()
        if ($infrastructureData.clusters) {
            foreach ($cluster in $infrastructureData.clusters) {
                if ($cluster.edgeSite) {
                    # If EdgeSite is specified, only include matching clusters.
                    if (-not $EdgeSite -or $cluster.edgeSite -eq $EdgeSite) {
                        $infrastructureEdgeSites.Add($cluster.edgeSite)
                    }
                }
            }
        }

        # Collect edgeSite values from supervisor JSON.
        $supervisorEdgeSites = [System.Collections.Generic.List[String]]::new()
        if ($supervisorData.siteSpec) {
            foreach ($siteSpec in $supervisorData.siteSpec) {
                if ($siteSpec.edgeSite) {
                    # If EdgeSite is specified, only include matching site specs.
                    if (-not $EdgeSite -or $siteSpec.edgeSite -eq $EdgeSite) {
                        $supervisorEdgeSites.Add($siteSpec.edgeSite)
                    }
                }
            }
        }

        $consistencyResult = Test-EdgeSiteSetConsistency -InfrastructureEdgeSites $infrastructureEdgeSites -SupervisorEdgeSites $supervisorEdgeSites
        if (-not $consistencyResult.IsValid) {
            Write-LogMessage -Type ERROR -Message $consistencyResult.ErrorMessage
            $validationResult.IsValid = $false
            $validationResult.ErrorMessage = $consistencyResult.ErrorMessage
            return $validationResult
        }

        Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "EdgeSite matching validation passed. All edgeSite values match between infrastructure and supervisor JSONs."
    } catch {
        $validationResult.IsValid = $false
        $validationResult.ErrorMessage = "Error during edgeSite matching validation: $($_.Exception.Message)"
        Write-LogMessage -Type ERROR -Message $validationResult.ErrorMessage
    }

    return $validationResult
}
function Assert-ValidationResult {

    <#
        .SYNOPSIS
        Throws a VcfDeploymentException when a validation result is invalid; logs the pass or fail outcome.

        .DESCRIPTION
        Centralises the check-and-throw pattern used by Test-JsonShallowValidation for each of its four
        validation phases (missing-property and null-value checks for both JSON files). Logs a success
        line when the result is valid so the caller does not need to repeat that line.

        .PARAMETER Context
        Short label identifying the check (e.g. "Input JSON", "Supervisor JSON null values"). Used in
        log messages.

        .PARAMETER OnFailure
        Human-readable detail appended to the error log and used verbatim as the VcfDeploymentException
        message when the result is invalid.

        .PARAMETER Result
        Validation result object with IsValid ([Bool]) and Summary ([String]) properties. Produced by
        Test-JsonMissingProperties or Test-JsonNullValues.

        .EXAMPLE
        $result = Test-JsonMissingProperties -JsonFilePath $SupervisorJson -RequiredProperties $props -JsonObjectName "SupervisorConfiguration" -ShowExpectedStructure
        Assert-ValidationResult -Context "Supervisor JSON" -OnFailure "Deployment cannot proceed with incomplete supervisor configuration. Please fix the missing properties and try again." -Result $result

        .NOTES
        Helper for Test-JsonShallowValidation. Not intended as a general-purpose utility.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$Context,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$OnFailure,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSCustomObject]$Result
    )

    if (-not $Result.IsValid) {
        Write-LogMessage -Type ERROR -Message "$Context validation failed: $($Result.Summary)"
        Write-LogMessage -Type ERROR -Message $OnFailure
        throw [VcfDeploymentException]::new($OnFailure)
    }
    Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "$Context validation passed: $($Result.Summary)"
}
function Test-ContextNameRequired {

    <#
        .SYNOPSIS
        Returns $true when any cluster in scope has ArgoCD or Harbor enabled.

        .DESCRIPTION
        Iterates the provided cluster list and checks the effective value of disableArgoCD and
        disableHarbor for each cluster using Get-EffectiveSupervisorServiceFlag. Returns $true on the
        first cluster where either service is active; $false when all services are disabled for all
        clusters.

        .PARAMETER ClustersInScope
        The list of cluster objects filtered to the edge sites being validated. An empty array returns
        $false immediately.

        .PARAMETER CommonData
        The common property of the infrastructure JSON (inputData.common). Passed to
        Get-EffectiveSupervisorServiceFlag for default-value resolution. May be $null when
        the JSON has no common section.

        .EXAMPLE
        $requireContextName = Test-ContextNameRequired -ClustersInScope $clustersInScope -CommonData $inputData.common

        .NOTES
        Helper for Test-JsonShallowValidation.
    #>

    [CmdletBinding()]
    [OutputType([Bool])]
    Param (
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [ValidateNotNull()] [Object[]]$ClustersInScope,
        [Parameter(Mandatory = $false)] [Object]$CommonData
    )

    foreach ($clusterRow in $ClustersInScope) {
        $argoEnabled   = -not (Get-EffectiveSupervisorServiceFlag -Cluster $clusterRow -CommonData $CommonData -FlagName "disableArgoCD")
        $harborEnabled = -not (Get-EffectiveSupervisorServiceFlag -Cluster $clusterRow -CommonData $CommonData -FlagName "disableHarbor")
        if ($argoEnabled -or $harborEnabled) {
            return $true
        }
    }
    return $false
}
function Get-InfrastructureRequiredProperties {

    <#
        .SYNOPSIS
        Returns the list of required property paths for infrastructure.json shallow validation.

        .DESCRIPTION
        Builds the canonical set of required infrastructure.json property paths. When RequireContextName
        is $false, common.contextName is excluded — ArgoCD and Harbor are both disabled for all clusters
        in scope and the VCF CLI context is not used.

        .PARAMETER RequireContextName
        When $true, common.contextName is included in the returned array. Pass $false when all supervisor
        services are disabled for all clusters in scope.

        .EXAMPLE
        $infraProps = Get-InfrastructureRequiredProperties -RequireContextName $requireContextName

        .NOTES
        Helper for Test-JsonShallowValidation. The returned array is consumed by Test-JsonMissingProperties
        and Test-JsonNullValues.
    #>

    [CmdletBinding()]
    [OutputType([String[]])]
    Param (
        [Parameter(Mandatory = $true)] [Bool]$RequireContextName
    )

    $properties = @(
        "common.datacenterName",
        "common.vCenterName",
        "common.vCenterUser",
        "common.contextName",
        "clusters",
        "clusters[].edgeSite",
        "clusters[].esxHosts",
        "clusters[].networking",
        "clusters[].networking.networkSegments",
        "clusters[].networking.networkSegments[].name",
        "clusters[].networking.networkSegments[].vlanId",
        "clusters[].networking.networkSegments[].gateway",
        "clusters[].storagePolicy",
        "clusters[].storagePolicy.storageType"
    )
    if (-not $RequireContextName) {
        $properties = @($properties | Where-Object { $_ -ne "common.contextName" })
    }
    return $properties
}
function Get-SupervisorRequiredProperties {

    <#
        .SYNOPSIS
        Returns the list of required property paths for supervisor.json shallow validation.

        .DESCRIPTION
        Returns the canonical set of required supervisor.json property paths covering supervisor specs,
        load balancer components, and network configurations.

        .EXAMPLE
        $supervisorProps = Get-SupervisorRequiredProperties

        .NOTES
        Helper for Test-JsonShallowValidation. The returned array is consumed by Test-JsonMissingProperties
        and Test-JsonNullValues.
    #>

    [CmdletBinding()]
    [OutputType([String[]], [Object[]])]
    Param ()

    return @(
        "commonSupervisorSpec.controlPlaneVMCount",
        "commonSupervisorSpec.controlPlaneSize",
        "commonSupervisorSpec.flbAvailability",
        "commonSupervisorSpec.flbSize",
        "commonSupervisorSpec.flbNetworkType",
        "commonSupervisorSpec.networkSearchDomains",
        "commonSupervisorSpec.networkNtpServers",
        "commonSupervisorSpec.dnsServers",
        "siteSpec",
        "siteSpec[].edgeSite",
        "siteSpec[].foundationLoadBalancerComponents.flbName",
        "siteSpec[].foundationLoadBalancerComponents.flbVipStartIP",
        "siteSpec[].foundationLoadBalancerComponents.flbVipIPCount",
        "siteSpec[].foundationLoadBalancerComponents.flbManagementNetwork.flbNetworkName",
        "siteSpec[].foundationLoadBalancerComponents.flbManagementNetwork.flbNetworkIpAddressStartingIp",
        "siteSpec[].foundationLoadBalancerComponents.flbManagementNetwork.flbNetworkIpAddressCount",
        "siteSpec[].foundationLoadBalancerComponents.flbVirtualServerNetwork.flbNetworkName",
        "siteSpec[].foundationLoadBalancerComponents.flbVirtualServerNetwork.flbNetworkIpAddressStartingIp",
        "siteSpec[].foundationLoadBalancerComponents.flbVirtualServerNetwork.flbNetworkIpAddressCount",
        "siteSpec[].mgmtNetworkSpec.mgmtNetworkName",
        "siteSpec[].mgmtNetworkSpec.mgmtNetworkStartingIp",
        "siteSpec[].mgmtNetworkSpec.mgmtNetworkIPCount",
        "siteSpec[].primaryWorkloadNetwork.primaryWorkloadNetworkName",
        "siteSpec[].primaryWorkloadNetwork.primaryWorkloadNetworkStartingIp",
        "siteSpec[].primaryWorkloadNetwork.primaryWorkloadNetworkIPCount",
        "siteSpec[].primaryWorkloadNetwork.workloadServiceStartIp",
        "siteSpec[].primaryWorkloadNetwork.workloadServiceCount"
    )
}
function Test-EsxHostsArrayFormat {

    <#
        .SYNOPSIS
        Validates that every cluster in InputData uses 'esxHosts' (plural array) rather than the
        deprecated 'esxHost' (singular) property.

        .DESCRIPTION
        Iterates all clusters and verifies that: the deprecated singular 'esxHost' property is absent,
        'esxHosts' exists, is an Array, and is non-empty. Throws a VcfDeploymentException on the first
        violation found.

        .PARAMETER InputData
        The parsed infrastructure.json object containing a 'clusters' array.

        .EXAMPLE
        Test-EsxHostsArrayFormat -InputData $inputData

        .NOTES
        Helper for Test-JsonShallowValidation. Called after missing-property validation passes.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object]$InputData
    )

    if (-not $InputData.clusters) {
        return
    }
    foreach ($cluster in $InputData.clusters) {
        if ($cluster.PSObject.Properties.Name -contains "esxHost") {
            $err = "Cluster with edgeSite '$($cluster.edgeSite)' uses deprecated 'esxHost' (singular). Use 'esxHosts' (plural) array instead."
            Write-LogMessage -Type ERROR -Message $err
            throw [VcfDeploymentException]::new($err)
        }
        if (-not $cluster.esxHosts) {
            $err = "Cluster with edgeSite '$($cluster.edgeSite)' is missing 'esxHosts' array."
            Write-LogMessage -Type ERROR -Message $err
            throw [VcfDeploymentException]::new($err)
        }
        if ($cluster.esxHosts -isnot [Array]) {
            $err = "Cluster with edgeSite '$($cluster.edgeSite)' has 'esxHosts' that is not an array."
            Write-LogMessage -Type ERROR -Message $err
            throw [VcfDeploymentException]::new($err)
        }
        if ($cluster.esxHosts.Count -eq 0) {
            $err = "Cluster with edgeSite '$($cluster.edgeSite)' has empty 'esxHosts' array."
            Write-LogMessage -Type ERROR -Message $err
            throw [VcfDeploymentException]::new($err)
        }
    }
}
function Test-InfrastructureBooleanFlags {

    <#
        .SYNOPSIS
        Validates that optional boolean flags in infrastructure.json common section have boolean values.

        .DESCRIPTION
        Checks four optional boolean flags — esxUniquePasswordPerHost, nonInteractivePassword, autoUpdate,
        and preserveAutoGeneratedKeyCertPair — and throws a VcfDeploymentException when any is present
        but is not a [Bool] value.

        .PARAMETER InfrastructureJson
        Full path to the infrastructure.json file. Used in error messages only.

        .PARAMETER InputData
        The parsed infrastructure.json object. Only the common property is read.

        .EXAMPLE
        Test-InfrastructureBooleanFlags -InfrastructureJson $InfrastructureJson -InputData $inputData

        .NOTES
        Helper for Test-JsonShallowValidation. Called after null-value validation passes.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$InfrastructureJson,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object]$InputData
    )

    $flagDefinitions = @(
        @{ Name = "esxUniquePasswordPerHost";         ExceptionLabel = "common.esxUniquePasswordPerHost" },
        @{ Name = "nonInteractivePassword";           ExceptionLabel = "common.nonInteractivePassword" },
        @{ Name = "autoUpdate";                       ExceptionLabel = "common.autoUpdate" },
        @{ Name = "preserveAutoGeneratedKeyCertPair"; ExceptionLabel = "common.preserveAutoGeneratedKeyCertPair" }
    )
    if (-not $InputData.common) {
        return
    }
    foreach ($flagDef in $flagDefinitions) {
        if ($null -ne $InputData.common.PSObject.Properties[$flagDef.Name]) {
            $value = $InputData.common.($flagDef.Name)
            if ($value -isnot [Bool]) {
                $err = "$($flagDef.ExceptionLabel) must be true or false (boolean). Current value type: $($value.GetType().Name). Fix the value in $InfrastructureJson and re-run."
                Write-LogMessage -Type ERROR -Message $err
                throw [VcfDeploymentException]::new($err)
            }
        }
    }
}
function Test-JsonInfrastructureSupplementalValidation {

    <#
        .SYNOPSIS
        Validates nicList, esxHosts format, boolean flags, and supervisor service YAML paths.

        .DESCRIPTION
        Runs the four supplemental infrastructure JSON validation checks that follow the core
        property-presence and null-value checks in Test-JsonShallowValidation:
        1. nicList — at least one definition (common or per-cluster); 2 or 4 NICs per cluster.
        2. esxHosts array format.
        3. Boolean flag values.
        4. Supervisor service YAML and Harbor TLS shallow path check (skipped with -ComputeOnly).
        Throws VcfDeploymentException when any check fails.

        .PARAMETER ClustersInScope
        Scope-filtered cluster array used by nicList and YAML path checks.

        .PARAMETER ComputeOnly
        When set, skips the supervisor service YAML path check.

        .PARAMETER InputData
        Parsed infrastructure JSON object.

        .PARAMETER InfrastructureJson
        Full path to infrastructure.json (passed to Test-InfrastructureBooleanFlags and path-update helper).

        .EXAMPLE
        Test-JsonInfrastructureSupplementalValidation -InputData $inputData -InfrastructureJson $InfrastructureJson `
            -ClustersInScope $clustersInScope

        .NOTES
        Called by Test-JsonShallowValidation after all core property-presence and null-value checks pass.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object[]]$ClustersInScope,
        [Parameter(Mandatory = $false)] [Switch]$ComputeOnly,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$InfrastructureJson,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object]$InputData
    )

    Test-InfrastructureNicListEffective -InputData $InputData -Clusters $ClustersInScope
    Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "Infrastructure nicList validation passed (cluster override or common; 2 or 4 NICs per cluster)."

    Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "Validating esxHosts format in infrastructure JSON..."
    Test-EsxHostsArrayFormat -InputData $InputData
    Test-InfrastructureBooleanFlags -InfrastructureJson $InfrastructureJson -InputData $InputData

    if (-not $ComputeOnly) {
        Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "Validating supervisor service YAML and Harbor TLS paths (shallow check)..."
        Update-InfrastructureJsonReferencedFilePaths -InfrastructureJsonPath $InfrastructureJson -InputData $InputData
        $shallowPathFailures = Test-JsonShallowSupervisorServicesPathConfiguration -ClustersToValidate $ClustersInScope -InputData $InputData
        if ($shallowPathFailures -gt 0) {
            $err = "JSON configuration validation found $shallowPathFailures file path error(s). Verify all referenced paths exist and re-run."
            Write-LogMessage -Type ERROR -Message $err
            throw [VcfDeploymentException]::new($err)
        }
        Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "Supervisor service YAML and Harbor TLS shallow path validation passed."
    }
}
function Test-JsonShallowValidation {

    <#
        .SYNOPSIS
        Validates infrastructure.json and supervisor.json configuration files to ensure all required properties are present and non-null.

        .DESCRIPTION
        Performs two-phase shallow validation of the two JSON configuration files used by this module:
        1. infrastructure.json — vCenter, ESX host, storage, and networking details.
        2. supervisor.json — supervisor components, load balancer, and network specifications.

        Validation phases:
        - Test-JsonMissingProperties: checks that all required keys exist in the JSON structure.
        - Test-JsonNullValues: checks that all required keys have non-null values.

        Both phases must pass for deployment to proceed. Any failure throws a terminating error.

        .EXAMPLE
        Test-JsonShallowValidation -InfrastructureJson "./config/infrastructure.json" -SupervisorJson "./config/supervisor.json"

        Validates both configuration files before deployment.

        .EXAMPLE
        Test-JsonShallowValidation -InfrastructureJson $InfrastructureJson -SupervisorJson $SupervisorJson

        Called during the initialization phase to validate configuration files before proceeding with deployment.

        .PARAMETER ComputeOnly
        When set, skips supervisor.json checks and infrastructure/supervisor edgeSite pairing, and does not require common.contextName.

        .PARAMETER EdgeSite
        When set, scopes cluster-derived checks (for example supervisor service requirements and nicList) to the listed edge sites.

        .PARAMETER InfrastructureJson
        Full path to infrastructure.json. Must contain all required infrastructure configuration properties including
        vCenter details, ESX host information, storage configuration, and networking. Must be valid JSON.

        .PARAMETER SupervisorJson
        Full path to supervisor.json. Must contain all required supervisor cluster configuration properties including
        supervisor specifications, foundation load balancer components, and network configurations. Ignored when
        -ComputeOnly is set. Must be valid JSON.

        .NOTES
        - When every cluster in scope has both supervisorServices.disableArgoCD and supervisorServices.disableHarbor
          set to true, common.contextName is omitted from the required infrastructure property list (the VCF CLI
          context is not used when all supervisor services are disabled).
        - supervisor.json is not read when -ComputeOnly is set.
        - Performs two-phase validation: missing-key check then null-value check.
        - Throws a terminating error if any validation phase fails.
        - Validation includes deep property path checking using dot notation (e.g. "siteSpec[].mgmtNetworkSpec.mgmtNetworkName").
        - Missing properties are reported with expected structure detail for troubleshooting.
        - Null values are reported with clear error messages indicating which properties need values.

        Validation order:
        1. Parse and scope infrastructure.json; resolve edge-site filter.
        2. Validate supervisor.json for missing properties (skipped with -ComputeOnly).
        3. Validate infrastructure.json for missing properties.
        4. Validate supervisor.json for null values (skipped with -ComputeOnly).
        5. Validate infrastructure.json for null values.
        6. Validate edgeSite matching between the two files (skipped with -ComputeOnly).
        7. Validate nicList, esxHosts format, boolean flags, and service YAML paths.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $false)] [Switch]$ComputeOnly,
        [Parameter(Mandatory = $false)] [String]$EdgeSite,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$InfrastructureJson,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$SupervisorJson
    )

    Write-LogMessage -Type DEBUG -Message "Entered Test-JsonShallowValidation function..."

    $shallowValidationFunctionStartTime = Get-Date

    # Parse infrastructure.json once; all subsequent blocks reuse $inputData.
    $inputData = ConvertFrom-JsonSafely -JsonFilePath $InfrastructureJson

    # If EdgeSite is specified, resolve to list (validates delimiter and site names; throws if invalid).
    $edgeSitesArray = @()
    if ($EdgeSite) {
        $edgeSitesArray = Get-EdgeSitesFromParameter -EdgeSite $EdgeSite -InputData $inputData
        $siteList = $edgeSitesArray -join '", "'
        Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "Validating only edgeSite(s) `"$siteList`" configuration..."
    }

    # Resolve scope-filtered cluster collection used throughout validation.
    $clustersInScope = if ($inputData.clusters) { Get-ClustersInScope -EdgeSitesArray $edgeSitesArray -InputData $inputData } else { @() }

    # contextName is required whenever any supervisor service (ArgoCD or Harbor) is active for any
    # cluster in scope. Both services use the VCF CLI context to interact with the supervisor.
    $requireContextName = if ($ComputeOnly) { $false } else { Test-ContextNameRequired -ClustersInScope $clustersInScope -CommonData $inputData.common }

    $infrastructureJsonRequiredProperties = Get-InfrastructureRequiredProperties -RequireContextName $requireContextName
    $supervisorJsonRequiredProperties     = Get-SupervisorRequiredProperties

    if ($ComputeOnly) {
        Write-LogMessage -Type INFO -Message "ComputeOnly: skipping supervisor.json shallow validation."
        $supervisorDataValidationResult = [PSCustomObject]@{ IsValid = $true; Summary = "skipped (ComputeOnly)" }
        $supervisorNullValidationResult = [PSCustomObject]@{ IsValid = $true; Summary = "skipped (ComputeOnly)" }
    } else {
        Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "Validating $SupervisorJson configuration file..."
        $supervisorDataValidationResult = Test-JsonMissingProperties -JsonFilePath $SupervisorJson -RequiredProperties $supervisorJsonRequiredProperties -JsonObjectName "SupervisorConfiguration" -ShowExpectedStructure
        Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "Validating $SupervisorJson for null values..."
        $supervisorNullValidationResult = Test-JsonNullValues -JsonFilePath $SupervisorJson -RequiredProperties $supervisorJsonRequiredProperties -JsonObjectName "SupervisorConfiguration"
    }

    Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "Validating $InfrastructureJson configuration file..."
    $inputDataValidationResult = Test-JsonMissingProperties -JsonFilePath $InfrastructureJson -RequiredProperties $infrastructureJsonRequiredProperties -JsonObjectName "InputConfiguration" -ShowExpectedStructure

    Assert-ValidationResult -Context "Input JSON"      -OnFailure "Deployment cannot proceed with incomplete input configuration. Please fix the missing properties and try again."       -Result $inputDataValidationResult
    Assert-ValidationResult -Context "Supervisor JSON" -OnFailure "Deployment cannot proceed with incomplete supervisor configuration. Please fix the missing properties and try again." -Result $supervisorDataValidationResult

    Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "Validating $InfrastructureJson for null values..."
    $inputNullValidationResult = Test-JsonNullValues -JsonFilePath $InfrastructureJson -RequiredProperties $infrastructureJsonRequiredProperties -JsonObjectName "InputConfiguration"

    Assert-ValidationResult -Context "Input JSON null values"      -OnFailure "Deployment cannot proceed with null values in input configuration. Please provide valid values for all required properties."      -Result $inputNullValidationResult
    Assert-ValidationResult -Context "Supervisor JSON null values" -OnFailure "Deployment cannot proceed with null values in supervisor configuration. Please provide valid values for all required properties." -Result $supervisorNullValidationResult

    if ($ComputeOnly) {
        $edgeSiteValidationResult = [PSCustomObject]@{ IsValid = $true; ErrorMessage = $null }
    } else {
        # Validate edgeSite matching between infrastructure and supervisor JSONs.
        Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "Validating edgeSite matching between infrastructure and supervisor JSONs..."
        $edgeSiteValidationResult = Test-EdgeSiteMatching -InfrastructureJson $InfrastructureJson -SupervisorJson $SupervisorJson
        if (-not $edgeSiteValidationResult.IsValid) {
            $err = "EdgeSite matching validation failed: $($edgeSiteValidationResult.ErrorMessage)"
            Write-LogMessage -Type ERROR -Message $err
            throw [VcfDeploymentException]::new($err)
        }
    }

    Test-JsonInfrastructureSupplementalValidation `
        -ClustersInScope     $clustersInScope `
        -ComputeOnly:        $ComputeOnly.IsPresent `
        -InputData           $inputData `
        -InfrastructureJson  $InfrastructureJson

    # If all validation results are valid, write a success message.
    if ($inputDataValidationResult.IsValid -and $supervisorDataValidationResult.IsValid -and $inputNullValidationResult.IsValid -and $supervisorNullValidationResult.IsValid -and $edgeSiteValidationResult.IsValid) {
        $siteIndication = if (-not $EdgeSite) { "all sites" } elseif ($null -ne $edgeSitesArray -and $edgeSitesArray.Count -gt 0) { "edgeSite(s) `"$($edgeSitesArray -join '", "')`"" } else { "edgeSite `"$EdgeSite`"" }
        Write-LogMessage -Type DEBUG -Message "JSON configuration file validation completed successfully for $siteIndication."
    }

    $shallowValidationFunctionElapsed = (Get-Date) - $shallowValidationFunctionStartTime
    $siteIndication = if (-not $EdgeSite) { "all sites" } elseif ($null -ne $edgeSitesArray -and $edgeSitesArray.Count -gt 0) { "edgeSite(s) `"$($edgeSitesArray -join '", "')`"" } else { "edgeSite `"$EdgeSite`"" }
    Write-LogMessage -Type DEBUG -Message "Test-JsonShallowValidation completed all validation calls for $siteIndication in $($shallowValidationFunctionElapsed.TotalSeconds.ToString('F3')) seconds."
}
function Resolve-JsonArrayPropertyValue {

    <#
        .SYNOPSIS
        Resolves an array-notation segment during JSON dot-path navigation.

        .DESCRIPTION
        Called by Get-JsonPropertyValue when a path segment uses array notation (e.g. "clusters[]").
        Accesses the named array on the current object, then either returns the array itself when this
        is the terminal segment or searches the array elements for the first element that satisfies
        the remaining path. Returns $null and logs an error on any failure.
        Returns $null on any error (error is logged before returning).

        .PARAMETER ArrayPropertyName
        The property name without brackets (e.g. "clusters" from "clusters[]").

        .PARAMETER CurrentObject
        The object whose property named ArrayPropertyName is the array.

        .PARAMETER IsLastPathPart
        When $true, the array is the terminal segment and is returned as-is.

        .PARAMETER PropertyPath
        Full original dot-notation path; used only in error log messages.

        .PARAMETER RemainingPath
        The dot-notation path segments after this array segment, joined with ".". May be empty.

        .OUTPUTS
        System.Object
        Returns the resolved value or $null on failure.

        .EXAMPLE
        $value = Resolve-JsonArrayPropertyValue -ArrayPropertyName "clusters" -CurrentObject $config -IsLastPathPart $false -PropertyPath "clusters[].vCenterName" -RemainingPath "vCenterName"
    #>

    [CmdletBinding()]
    [OutputType([Object])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$ArrayPropertyName,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object]$CurrentObject,
        [Parameter(Mandatory = $true)] [Bool]$IsLastPathPart,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$PropertyPath,
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [String]$RemainingPath
    )

    # Direct assignments preserve empty-array values; if-expression assignment coerces @() to $null.
    if ($CurrentObject -is [PSCustomObject]) {
        $arrayObject = $CurrentObject.$ArrayPropertyName
    } elseif ($CurrentObject -is [Hashtable]) {
        $arrayObject = $CurrentObject[$ArrayPropertyName]
    } else {
        try {
            $arrayObject = $CurrentObject.$ArrayPropertyName
        } catch {
            Write-LogMessage -Type ERROR -SuppressOutputToScreen -Message "Cannot access array property '$ArrayPropertyName' in path '$PropertyPath': $($_.Exception.Message)"
            return $null
        }
    }

    if ($null -eq $arrayObject) {
        Write-LogMessage -Type ERROR -SuppressOutputToScreen -Message "Array property '$ArrayPropertyName' is null in path '$PropertyPath'"
        return $null
    }

    if ($arrayObject -isnot [System.Collections.IList]) {
        Write-LogMessage -Type ERROR -SuppressOutputToScreen -Message "Property '$ArrayPropertyName' is not an array in path '$PropertyPath'"
        return $null
    }

    if ($IsLastPathPart) {
        if ($arrayObject.Count -eq 0) { return "" }
        return $arrayObject.ToString()
    }

    foreach ($element in $arrayObject) {
        $elementValue = if (-not [String]::IsNullOrWhiteSpace($RemainingPath)) {
            Get-JsonPropertyValue -InputData $element -PropertyPath $RemainingPath
        } else {
            $element
        }
        if ($null -ne $elementValue) { return $elementValue }
    }

    Write-LogMessage -Type ERROR -SuppressOutputToScreen -Message "No element in array '$ArrayPropertyName' has the remaining path '$RemainingPath'"
    return $null
}
function Get-JsonPropertyValue {

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

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $true)] [AllowNull()] [AllowEmptyString()] [Object]$InputData,
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [String]$PropertyPath
    )

    try {
        if ($null -eq $InputData) {
            Write-LogMessage -Type ERROR -SuppressOutputToScreen -Message "Input data is null"
            return $null
        }

        if ($InputData -is [String]) { return $InputData }

        if ($PropertyPath -and $PropertyPath.Trim() -ne "") {
            $pathParts = $PropertyPath.Split('.')
            $currentObject = $InputData

            for ($pathPartIndex = 0; $pathPartIndex -lt $pathParts.Count; $pathPartIndex++) {
                $part = $pathParts[$pathPartIndex]
                $isArrayNotation = $part -match '^(.+)\[\]$'

                if ($null -eq $currentObject) {
                    Write-LogMessage -Type ERROR -SuppressOutputToScreen -Message "Property path '$PropertyPath' contains null value at '$part'"
                    return $null
                }

                if ($isArrayNotation) {
                    $arrayPropertyName = $matches[1]
                    $isLastPart = ($pathPartIndex -eq ($pathParts.Count - 1))
                    $remainingPath = if ($pathPartIndex + 1 -ge $pathParts.Count) { "" } else { $pathParts[($pathPartIndex + 1)..($pathParts.Count - 1)] -join "." }
                    return Resolve-JsonArrayPropertyValue -ArrayPropertyName $arrayPropertyName -CurrentObject $currentObject -IsLastPathPart $isLastPart -PropertyPath $PropertyPath -RemainingPath $remainingPath
                }

                $currentObject = if ($currentObject -is [PSCustomObject]) {
                    $currentObject.$part
                } elseif ($currentObject -is [Hashtable]) {
                    $currentObject[$part]
                } else {
                    try { $currentObject.$part } catch {
                        Write-LogMessage -Type ERROR -SuppressOutputToScreen -Message "Cannot access property '$part' in path '$PropertyPath': $($_.Exception.Message)"
                        return $null
                    }
                }
            }

            if ($null -eq $currentObject) { return "" }
            return $currentObject.ToString()
        }

        return $InputData.ToString()
    } catch {
        Write-LogMessage -Type ERROR -SuppressOutputToScreen -Message "Error extracting property value: $($_.Exception.Message)"
        return $null
    }
}
function Get-ValidationPresetRules {

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

    [CmdletBinding()]
    [OutputType([Hashtable])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateSet("AlphaNumeric", "AlphaNumericDash", "Numeric", "FileName", "UserName", "DomainName", "IpAddress", "IpAddressOrFqdn", "IpAddressWithCidr", "IpAddressOrDomainNameWithPort", "Email", "lowerCaseRfc1123PortGroup", "FilePath", "vSphereObject80Characters", "Url")] [String]$ValidationPreset
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
        "IpAddressOrFqdn" {
            # IPv4 dotted quad OR FQDN (e.g. for ESX host or vCenter name).
            $rules.RegexPattern = '^(?:(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)|[a-zA-Z0-9]([a-zA-Z0-9\-_\.]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-_\.]*[a-zA-Z0-9])?)*)$'
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
        "Url" {
            # URL validation: https://www.example.com/path/to/resource
            # Supports: http/https, multiple subdomains, modern TLDs (2-63 chars), paths, query strings, fragments
            $rules.RegexPattern = '^https?:\/\/([a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}([\/\w\-\.~!*''();:@&=+$,?#\[\]]*)?$'
        }
    }

    Write-LogMessage -Type DEBUG -Message "Retrieved validation rules for preset '$ValidationPreset'"
    return $rules
}
function Test-StringAgainstAllowlist {

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

    [CmdletBinding()]
    [OutputType([Bool])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$AllowedCharacters,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$InputText
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
function Test-StringAgainstDenylist {

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

    [CmdletBinding()]
    [OutputType([Bool])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$DisallowedCharacters,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$InputText
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
function Test-AcceptableStrings {

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

    [CmdletBinding()]
    [OutputType([Bool])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [String[]]$AcceptableStrings,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [String]$InputText,
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [String]$PropertyPath
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

    $pathInfo = if ($PropertyPath) { " for JSON property `"$PropertyPath`"" } else { "" }
    Write-LogMessage -Type ERROR -Message "Validation failed for input value `"$InputText`"${pathInfo}. It should be one of: $($AcceptableStrings -join ', ')"
    return $false
}
function Test-NumericRange {

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

    [CmdletBinding()]
    [OutputType([Bool])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$InputText,
        [Parameter(Mandatory = $false)] [Double]$MaxValue,
        [Parameter(Mandatory = $false)] [Double]$MinValue,
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [String]$PropertyPath
    )

    Write-LogMessage -Type DEBUG -Message "Entered Test-NumericRange function..."

    Write-LogMessage -Type DEBUG -Message "Validating numeric range for value: '$InputText'"

    # Attempt to convert input to numeric.
    $numericValue = $null
    $isNumeric = [Double]::TryParse($InputText, [Ref]$numericValue)

    if (-not $isNumeric) {
        $pathInfo = if ($PropertyPath) { " for property `"$PropertyPath`"" } else { "" }
        Write-LogMessage -Type ERROR -Message "Numeric validation failed${pathInfo}: Value `"$InputText`" is not a valid number"
        return $false
    }

    if ($PSBoundParameters.ContainsKey('MinValue') -and $numericValue -lt $MinValue) {
        $pathInfo = if ($PropertyPath) { " for property `"$PropertyPath`"" } else { "" }
        Write-LogMessage -Type ERROR -Message "Numeric validation failed${pathInfo}: Value $numericValue is below minimum $MinValue."
        return $false
    }

    if ($PSBoundParameters.ContainsKey('MaxValue') -and $numericValue -gt $MaxValue) {
        $pathInfo = if ($PropertyPath) { " for property `"$PropertyPath`"" } else { "" }
        Write-LogMessage -Type ERROR -Message "Numeric validation failed${pathInfo}: Value $numericValue exceeds maximum $MaxValue."
        return $false
    }

    Write-LogMessage -Type DEBUG -Message "Numeric range validation passed for value: $numericValue"
    return $true
}
function Resolve-JsonPropertyInputText {

    <#
    .SYNOPSIS
        Extracts and normalizes the input text value for JSON property format validation.
    .DESCRIPTION
        When a PropertyPath is provided, delegates to Get-JsonPropertyValue. Otherwise returns the
        InputData coerced to a string, or $null when InputData is $null.
    .PARAMETER InputData
        The raw input: a string, PSCustomObject, or hashtable.
    .PARAMETER PropertyPath
        Dot-notation property path. When empty or absent, InputData itself is used as the value.
    .EXAMPLE
        $text = Resolve-JsonPropertyInputText -InputData $jsonObj -PropertyPath "common.vCenterName"
    .NOTES
        Returns $null when the value cannot be resolved. Callers must check for $null.
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $true)] [AllowNull()] [AllowEmptyString()] [Object]$InputData,
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [String]$PropertyPath
    )

    if ($PropertyPath -and $PropertyPath.Trim() -ne "") {
        return Get-JsonPropertyValue -InputData $InputData -PropertyPath $PropertyPath
    }
    if ($InputData -is [String]) { return $InputData }
    if ($null -eq $InputData) { return $null }
    return $InputData.ToString()
}
function Test-InputTextFormatRules {

    <#
    .SYNOPSIS
        Applies length, regex, allowed-character, and disallowed-character checks to a resolved string.
    .DESCRIPTION
        Validates an already-resolved string value against optional MinLength, MaxLength, RegexPattern,
        AllowedCharacters, and DisallowedCharacters constraints. Returns $false and logs an error on
        the first failing check; returns $true when all checks pass. Used by Test-JsonPropertyFormat
        after property extraction and numeric-range checks.
    .PARAMETER AllowedCharacters
        Allowlist character class pattern (passed to Test-StringAgainstAllowlist).
    .PARAMETER DisallowedCharacters
        Denylist character class pattern (passed to Test-StringAgainstDenylist).
    .PARAMETER InputText
        The string value to check.
    .PARAMETER MaxLength
        Maximum allowed string length, or 0 to skip.
    .PARAMETER MinLength
        Minimum required string length, or 0 to skip.
    .PARAMETER PropertyPath
        Used in error messages to identify the field.
    .PARAMETER RegexPattern
        Regex pattern the value must match.
    .PARAMETER ValidationLabel
        Fallback field display name when PropertyPath is absent.
    .PARAMETER ValidationPreset
        Preset name; included in regex-mismatch error messages.
    .EXAMPLE
        Test-InputTextFormatRules -InputText "my-value" -RegexPattern "^[a-z0-9-]+$" -PropertyPath "common.name"
    #>

    [CmdletBinding()]
    [OutputType([Bool])]
    Param (
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [String]$AllowedCharacters,
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [String]$DisallowedCharacters,
        [Parameter(Mandatory = $true)] [AllowEmptyString()] [String]$InputText,
        [Parameter(Mandatory = $false)] [ValidateRange(0, 10000)] [Int]$MaxLength,
        [Parameter(Mandatory = $false)] [ValidateRange(0, 1000)] [Int]$MinLength,
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [String]$PropertyPath,
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [String]$RegexPattern,
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [String]$ValidationLabel,
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [String]$ValidationPreset
    )

    if ($MinLength -and $InputText.Length -lt $MinLength) {
        Write-LogMessage -Type ERROR -Message "Input validation failed: Input length $($InputText.Length) is less than minimum required length $MinLength."
        return $false
    }
    if ($MaxLength -and $InputText.Length -gt $MaxLength) {
        Write-LogMessage -Type ERROR -Message "Input validation failed: Input length $($InputText.Length) exceeds maximum allowed length $MaxLength."
        return $false
    }
    if ($RegexPattern) {
        if (-not ($InputText -cmatch $RegexPattern)) {
            $presetSuffix = if ($ValidationPreset) { " ($ValidationPreset)" } else { "" }
            $fieldDisplay = if ($PropertyPath -and $PropertyPath.Trim() -ne "") { $PropertyPath } elseif ($ValidationLabel -and $ValidationLabel.Trim() -ne "") { $ValidationLabel } else { "input value" }
            Write-LogMessage -Type ERROR -Message "Validation failed for `"$fieldDisplay`" with value `"$InputText`". It does not match the required pattern${presetSuffix}: $RegexPattern"
            return $false
        }
    }
    if ($AllowedCharacters) {
        if (-not (Test-StringAgainstAllowlist -InputText $InputText -AllowedCharacters $AllowedCharacters)) { return $false }
    }
    if ($DisallowedCharacters) {
        if (-not (Test-StringAgainstDenylist -InputText $InputText -DisallowedCharacters $DisallowedCharacters)) { return $false }
    }
    return $true
}
function Test-JsonPropertyFormat {

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
        - IpAddressOrFqdn: Valid IPv4 address or FQDN (e.g. ESX host or vCenter name)
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

        .PARAMETER ValidationLabel
        Optional. Human-readable label for the field used in error messages when PropertyPath is not
        specified (e.g. when validating a direct string). When validation fails, this label is shown
        instead of "input value". Example: "ESX host", "common.vCenterName".

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
        $isValid = Test-JsonPropertyFormat -InputData $JsonFilePathConfig -PropertyPath "common.vCenterName" -ValidationPreset "DomainName"
        Validates that the vCenter name from JSON configuration follows domain name format rules.

        .EXAMPLE
        $isValid = Test-JsonPropertyFormat -InputData $InputData -PropertyPath "common.esxHost" -ValidationPreset "IpAddressOrDomainNameWithPort"
        Validates that the ESX host property from JSON contains a valid IP address or domain name with optional port.

        .EXAMPLE
        $isValid = Test-JsonPropertyFormat -InputData "ServerName-01" -AllowedCharacters "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_" -MinLength 3 -MaxLength 15
        Validates server name string with specific character allowlist and length constraints.

        .EXAMPLE
        $isValid = Test-JsonPropertyFormat -InputData $config -PropertyPath "datastore.datastoreName" -DisallowedCharacters "<>:\"/\\|?*" -MaxLength 50
        Validates datastore name from JSON by excluding filesystem-unsafe characters with a maximum length limit.

        .EXAMPLE
        $isValid = Test-JsonPropertyFormat -InputData $supervisorConfig -PropertyPath "supervisorComponentSpec.foundationLoadBalancerComponents.flbVipStartIP" -ValidationPreset "IpAddress"
        Validates that the load balancer VIP start IP from JSON is a properly formatted IPv4 address.

        .EXAMPLE
        $isValid = Test-JsonPropertyFormat -InputData "192.168.1.0/24" -ValidationPreset "IpAddressWithCidr"
        Validates that the input string is a properly formatted IPv4 address with CIDR notation (e.g., 192.168.1.0/24).

        .EXAMPLE
        $isValid = Test-JsonPropertyFormat -InputData $esxHost -ValidationPreset "IpAddressOrFqdn" -ValidationLabel "ESX host"
        Validates that an ESX host string is either a valid IPv4 address or FQDN; error messages show "ESX host" as the field name.

        .EXAMPLE
        $isValid = Test-JsonPropertyFormat -InputData "my-domain-name.local" -RegexPattern "^[a-zA-Z0-9][a-zA-Z0-9\-\.]*[a-zA-Z0-9]$" -MinLength 4
        Validates input string against a custom regular expression pattern with minimum length requirement.

        .EXAMPLE
        $isValid = Test-JsonPropertyFormat -InputData $config -PropertyPath "supervisorSpec.controlPlaneSize" -AcceptableStrings @("TINY", "SMALL", "MEDIUM", "LARGE")
        Validates that the control plane size from JSON matches one of the acceptable string values.

        .EXAMPLE
        $isValid = Test-JsonPropertyFormat -InputData "TINY" -AcceptableStrings @("tiny", "small", "medium", "large") -CaseSensitive
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

    [CmdletBinding()]
    [OutputType([Bool])]
    Param (
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String[]]$AcceptableStrings,
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$AllowedCharacters,
        [Parameter(Mandatory = $false)] [Switch]$CaseSensitive,
        [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$DisallowedCharacters,
        [Parameter(Mandatory = $true)] [AllowNull()] [AllowEmptyString()] [Object]$InputData,
        [Parameter(Mandatory = $false)] [ValidateRange(1, 10000)] [Int]$MaxLength,
        [Parameter(Mandatory = $false)] [Double]$MaxValue,
        [Parameter(Mandatory = $false)] [ValidateRange(0, 1000)] [Int]$MinLength,
        [Parameter(Mandatory = $false)] [Double]$MinValue,
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [String]$PropertyPath,
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [String]$RegexPattern,
        [Parameter(Mandatory = $false)] [AllowNull()] [AllowEmptyString()] [String]$ValidationLabel,
        [Parameter(Mandatory = $false)] [ValidateSet("AlphaNumeric", "AlphaNumericDash", "Numeric", "FileName", "UserName", "DomainName", "IpAddress", "IpAddressOrFqdn", "IpAddressWithCidr", "IpAddressOrDomainNameWithPort", "Email", "lowerCaseRfc1123PortGroup", "FilePath", "vSphereObject80Characters", "Url")] [String]$ValidationPreset
    )

    $inputText = Resolve-JsonPropertyInputText -InputData $InputData -PropertyPath $PropertyPath
    if ($null -eq $inputText) {
        Write-LogMessage -Type ERROR -SuppressOutputToScreen -Message "Input validation failed: Could not extract property value."
        return $false
    }

    $pathInfo = if ($PropertyPath) { " for property `"$PropertyPath`"" } else { "" }
    $presetInfo = if ($ValidationPreset) { " using preset `"$ValidationPreset`"" } else { "" }
    Write-LogMessage -Type DEBUG -SuppressOutputToScreen -Message "Validating input value: `"$inputText`"${pathInfo}${presetInfo}."

    if ($ValidationPreset) {
        $presetRules = Get-ValidationPresetRules -ValidationPreset $ValidationPreset

        # Merge preset rules with explicitly provided parameters (explicit parameters take precedence)
        if (-not $AllowedCharacters -and $presetRules.AllowedCharacters) {
            $AllowedCharacters = $presetRules.AllowedCharacters
        }
        if (-not $DisallowedCharacters -and $presetRules.DisallowedCharacters) {
            $DisallowedCharacters = $presetRules.DisallowedCharacters
        }
        if (-not $RegexPattern -and $presetRules.RegexPattern) {
            $RegexPattern = $presetRules.RegexPattern
        }
    }

    if ($AcceptableStrings -and $AcceptableStrings.Count -gt 0) {
        $isValid = Test-AcceptableStrings -InputText $inputText -AcceptableStrings $AcceptableStrings -PropertyPath $PropertyPath
        if (-not $isValid) {
            return $false
        }

        # If only acceptable strings validation was requested, return early.

        if (-not $AllowedCharacters -and -not $DisallowedCharacters -and -not $RegexPattern -and -not $MinLength -and -not $MaxLength -and -not $PSBoundParameters.ContainsKey('MinValue') -and -not $PSBoundParameters.ContainsKey('MaxValue')) {
            return $true
        }
    }

    if ($PSBoundParameters.ContainsKey('MinValue') -or $PSBoundParameters.ContainsKey('MaxValue')) {

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

    if (-not (Test-InputTextFormatRules `
            -AllowedCharacters $AllowedCharacters `
            -DisallowedCharacters $DisallowedCharacters `
            -InputText $inputText `
            -MaxLength $MaxLength `
            -MinLength $MinLength `
            -PropertyPath $PropertyPath `
            -RegexPattern $RegexPattern `
            -ValidationLabel $ValidationLabel `
            -ValidationPreset $ValidationPreset)) {
        return $false
    }

    return $true
}
function Test-TagCatalogCategory {

    <#
        .SYNOPSIS
        Tests for the existence of a vSphere tag catalog category and creates it if it doesn't exist.

        .DESCRIPTION
        The Test-TagCatalogCategory function checks if a specified tag catalog category exists
        in the connected vCenter. If the tag catalog category is not found, it creates
        a new one with a predefined description for edge-node greenfield deployments.

        This function is designed for greenfield deployments and uses a hardcoded description.
        The function throws a terminating error if any errors occur during the lookup
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
        - This function requires a valid connection to vCenter via the $Script:vCenterName variable
        - The function uses hardcoded description: "Tag catalog for edge-node greenfield deployment"
        - The function throws a terminating error if errors occur
        - Designed specifically for greenfield deployments; may need revision for brownfield scenarios
        - Uses Write-LogMessage for error logging

        .OUTPUTS
        None. This function does not return any objects but may create a new tag catalog category.

        .LINK
        Get-TagCategory
        New-TagCategory
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$TagCatalog
    )

    Write-LogMessage -Type DEBUG -Message "Entered Test-TagCatalogCategory function..."

    Assert-VcenterConnected

    try {
        $tagFoundCategory = Get-TagCategory -Name $TagCatalog -Server $Script:vCenterName -ErrorAction SilentlyContinue
    } catch {
        Write-LogMessage -Type DEBUG -Message "Error retrieving tag category `"$TagCatalog`" (non-critical): $($_.Exception.Message)"
    }

    if (-not $tagFoundCategory) {
        # Hard coded description for the tag category assuming greenfield. Can revisit for non-greenfield.
        try {
            New-TagCategory -Name $TagCatalog -Description "Tag catalog for edge-node greenfield deployment" -Server $Script:vCenterName -Confirm:$false -ErrorAction Stop | Out-Null
            Write-LogMessage -Type INFO -Message "Successfully created tag catalog `"$TagCatalog`" on `"$Script:vCenterName`"."
        } catch {
            $errorMessage = $_.Exception.Message

            # Check for SSO authentication failure which is commonly caused by clock sync issues.

            if ($errorMessage -match "vSphere single sign-on failed for connection") {
                Write-LogMessage -Type ERROR -Message "Error creating tag catalog `"$TagCatalog`" on `"$Script:vCenterName`": SSO authentication failure."
                Write-LogMessage -Type ERROR -Message "This is commonly caused by clock synchronization issues between the client and vCenter Server."
                Write-LogMessage -Type ERROR -Message "Troubleshooting steps:"
                Write-LogMessage -Type ERROR -Message "  1. Verify NTP is configured and synchronized on this host (client)."
                Write-LogMessage -Type ERROR -Message "  2. Verify NTP is configured and synchronized on vCenter Server `"$Script:vCenterName`"."
                Write-LogMessage -Type ERROR -Message "  3. Check that time drift is less than 5 minutes between client and vCenter."
                Write-LogMessage -Type ERROR -Message "Full error details: $errorMessage"
            } else {
                $err = "Error creating tag catalog `"$TagCatalog`" on `"$Script:vCenterName`": $errorMessage"
                Write-LogMessage -Type ERROR -Message $err
            }
            throw [VcfDeploymentException]::new($err)
        }

    } else {
        Write-LogMessage -Type INFO -Message "Tag catalog `"$TagCatalog`" already exists on vCenter `"$Script:vCenterName`". Skipping tag catalog creation."
    }
}
function Test-Tag {

    <#
        .SYNOPSIS
        Tests for the existence of a vSphere tag within a specified tag catalog category and creates it if it doesn't exist.

        .DESCRIPTION
        The Test-Tag function checks if a specified tag exists within a given tag catalog category
        in the connected vCenter. If the tag is not found, it creates a new tag with a
        predefined description for edge-node greenfield deployments.

        This function is designed for greenfield deployments and uses a hardcoded description.
        The function throws a terminating error if any errors occur during the lookup
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
        - This function requires a valid connection to vCenter via the $Script:vCenterName variable
        - The function uses hardcoded description: "New Tag for supervisor instance {tagName} for edge-node greenfield deployment"
        - The function throws a terminating error if errors occur during tag catalog lookup or tag creation
        - Designed specifically for greenfield deployments; may need revision for brownfield scenarios
        - Uses Write-LogMessage for error logging
        - The tag catalog category must exist before calling this function (use Test-TagCatalogCategory first)

        .OUTPUTS
        None. This function does not return any output but may create a new tag if it doesn't exist.

        .LINK
        Test-TagCatalogCategory
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$TagCatalog,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$TagName
    )

    Write-LogMessage -Type DEBUG -Message "Entered Test-Tag function..."

    Assert-VcenterConnected

    try {
        $tagCatalogObject = Get-TagCategory -Name $TagCatalog -Server $Script:vCenterName -ErrorAction SilentlyContinue}
    catch {
        $err = "Error looking up tag catalog `"$TagCatalog`" on vCenter `"$Script:vCenterName`" $($_.Exception.Message)"
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }

    # Look to see if tag has already been created.
    try {
        $foundTagName = Get-Tag -Name $TagName -Category $tagCatalogObject -Server $Script:vCenterName -ErrorAction SilentlyContinue
    } catch [VcfDeploymentException] {
        throw  # already logged and typed — propagate without re-wrapping
    } catch {
        $err = "Error looking up tag `"$TagName`" in tag catalog `"$TagCatalog`" on vCenter `"$Script:vCenterName`" $($_.Exception.Message)"
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }

    # If tag has not been created, create it.
    if (-not $foundTagName) {
        try {
            $tagCategoryObject = Get-TagCategory $tagCatalogObject -ErrorAction Stop
            $taskId = New-Tag -Name $TagName -Category $tagCategoryObject -Description "New Tag for supervisor instance $TagName for edge-node greenfield deployment" -Server $Script:vCenterName -Confirm:$false -ErrorAction Stop
            Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "New Tag creation TaskId: $($taskId.Value)"
            Write-LogMessage -Type INFO -Message "Successfully created tag name `"$TagName`" on `"$TagCatalog`"."
        } catch [VcfDeploymentException] {
            throw  # already logged and typed — propagate without re-wrapping
        } catch {
            $err = "Error creating tag name `"$TagName`" on `"$TagCatalog`": $($_.Exception.Message)"
            Write-LogMessage -Type ERROR -Message $err
            throw [VcfDeploymentException]::new($err)
        }
    } else {
        Write-LogMessage -Type INFO -Message "Tag name `"$TagName`" already exists on `"$TagCatalog`". Skipping tag creation."
    }
}
#Test-JsonDeeperValidation Helper Functions
function Test-VcenterAndEsxReachability {

    <#
        .SYNOPSIS
        Verifies TCP port reachability for vCenter and a list of ESX hosts; throws if any target is unreachable.

        .DESCRIPTION
        Used by Initialize-VcfEdgeAtScale to fail fast before credential prompts when vCenter or ESX hosts are unreachable on the given port (default 443).
        .PARAMETER VcenterName
        vCenter hostname or IP to test.
        .PARAMETER EsxHosts
        Array of ESX hostnames or IPs to test (may be empty).
        .PARAMETER Port
        TCP port to test. Default 443.
        .NOTES
        Logs DEBUG per target; throws with a clear message listing unreachable targets.
    
        .EXAMPLE
        $vcenterAndEsxReachabilityResult = Test-VcenterAndEsxReachability -VcenterName $vcenterConnection
        if (-not $vcenterAndEsxReachabilityResult.IsValid) { Write-LogMessage -Type ERROR -Message $vcenterAndEsxReachabilityResult.Summary }
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $false)] [String[]]$EsxHosts = @(),
        [Parameter(Mandatory = $false)] [ValidateRange(1, 65535)] [Int]$Port = 443,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$VcenterName
    )
    $failedTargets = [System.Collections.Generic.List[String]]::new()
    $vcenterReachable = Test-TcpPortReachable -IpAddress $VcenterName -Port $Port
    if (-not $vcenterReachable) {
        $failedTargets.Add("vCenter `"$VcenterName`"")
    }
    Write-LogMessage -Type DEBUG -Message "Reachability (TCP $Port): vCenter `"$VcenterName`": $(if ($vcenterReachable) { 'OK' } else { 'unreachable' })."
    foreach ($esx in $EsxHosts) {
        if ([String]::IsNullOrWhiteSpace($esx)) { continue }
        $esxReachable = Test-TcpPortReachable -IpAddress $esx -Port $Port
        if (-not $esxReachable) {
            $failedTargets.Add("ESX `"$esx`"")
        }
        Write-LogMessage -Type DEBUG -Message "Reachability (TCP $Port): ESX `"$esx`": $(if ($esxReachable) { 'OK' } else { 'unreachable' })."
    }
    if ($failedTargets.Count -gt 0) {
        $err = "Reachability failed: $($failedTargets -join '; '). Ensure targets are powered on and port $Port is open, then retry."
        Write-LogMessage -Type ERROR -Message $err
        throw [VcfDeploymentException]::new($err)
    }
    $reachSummary = if ($EsxHosts.Count -eq 0) { "vCenter OK" } else { "all targets OK (vCenter and $($EsxHosts.Count) ESX host(s))" }
    Write-LogMessage -Type INFO -Message "Reachability: $reachSummary."
}
function Test-VmKernelInterfacesSection {

    <#
    .SYNOPSIS
        Validates the networkingVmKernelInterfaces array for a single cluster.
    .DESCRIPTION
        Checks minimum entry count, per-entry service name, VLAN ID, netmask, and IP list validity,
        then verifies that the required vMotion and vSAN services are present. Logs errors for each
        violation. Returns the number of validation failures found.
    .PARAMETER AllowedServices
        Array of allowed service name strings: vMotion, vSAN, vSAN Witness.
    .PARAMETER CurrentEdgeSite
        Cluster edge site name used in log messages.
    .PARAMETER VmKernelIfs
        The networkingVmKernelInterfaces array from the cluster's networking configuration.
    .EXAMPLE
        $failures = Test-VmKernelInterfacesSection -AllowedServices @("vMotion","vSAN","vSAN Witness") -CurrentEdgeSite "site1" -VmKernelIfs $cluster.networking.networkingVmKernelInterfaces
    .NOTES
        Called by Test-JsonNetworkingVmKernelAndTemporaryIp.
    #>

    [CmdletBinding()]
    [OutputType([Int])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object[]]$AllowedServices,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$CurrentEdgeSite,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object[]]$VmKernelIfs
    )

    $failures = 0
    if ($VmKernelIfs.Count -lt 2) {
        Write-LogMessage -Type ERROR -Message "Cluster `"$CurrentEdgeSite`" networking.networkingVmKernelInterfaces must contain at least two entries (vMotion, vSAN). Found $($VmKernelIfs.Count)."
        $failures++
    }
    $serviceNamesSeen = [System.Collections.Generic.List[String]]::new()
    foreach ($vmk in $VmKernelIfs) {
        $service = $vmk.service
        if ([String]::IsNullOrWhiteSpace($service)) {
            Write-LogMessage -Type ERROR -Message "Cluster `"$CurrentEdgeSite`" networking.networkingVmKernelInterfaces has an entry with missing or empty service."
            $failures++
        } else {
            $canonical = $AllowedServices | Where-Object { $_ -eq $service.Trim() } | Select-Object -First 1
            if (-not $canonical) {
                Write-LogMessage -Type ERROR -Message "Cluster `"$CurrentEdgeSite`" networking.networkingVmKernelInterfaces has invalid service `"$service`". Allowed: vMotion, vSAN, vSAN Witness."
                $failures++
            } else { $serviceNamesSeen.Add($canonical) }
        }
        if ($null -ne $vmk.vlanId) {
            $vlanId = $vmk.vlanId -as [int]
            if ($null -eq $vlanId -or $vlanId -lt 0 -or $vlanId -gt 4095) { Write-LogMessage -Type ERROR -Message "Cluster `"$CurrentEdgeSite`" networking.networkingVmKernelInterfaces entry (service `"$($vmk.service)`") has invalid vlanId. Must be 0-4095 inclusive."; $failures++ }
        }
        if ($vmk.PSObject.Properties["netmask"] -and -not [String]::IsNullOrWhiteSpace($vmk.netmask)) {
            if (-not (Test-ValidNetmask -Netmask $vmk.netmask)) { Write-LogMessage -Type ERROR -Message "Cluster `"$CurrentEdgeSite`" networking.networkingVmKernelInterfaces entry (service `"$($vmk.service)`") has invalid netmask `"$($vmk.netmask)`"."; $failures++ }
        }
        $ipList = $vmk.ipList
        if (-not $ipList -or $ipList -isnot [Array]) {
            Write-LogMessage -Type ERROR -Message "Cluster `"$CurrentEdgeSite`" networking.networkingVmKernelInterfaces entry (service `"$($vmk.service)`") must have ipList as an array."
            $failures++
        } elseif ($ipList.Count -ne 2) {
            Write-LogMessage -Type ERROR -Message "Cluster `"$CurrentEdgeSite`" networking.networkingVmKernelInterfaces entry (service `"$($vmk.service)`") ipList must contain exactly two entries (found $($ipList.Count))."
            $failures++
        } else {
            $ip0 = if ($ipList[0] -is [String]) { $ipList[0].Trim() } else { [String]$ipList[0] }
            $ip1 = if ($ipList[1] -is [String]) { $ipList[1].Trim() } else { [String]$ipList[1] }
            if (-not (Test-ValidIPv4Address -IpAddress $ip0)) { Write-LogMessage -Type ERROR -Message "Cluster `"$CurrentEdgeSite`" networking.networkingVmKernelInterfaces entry (service `"$($vmk.service)`") ipList[0] `"$ip0`" is not a valid IPv4 address."; $failures++ }
            if (-not (Test-ValidIPv4Address -IpAddress $ip1)) { Write-LogMessage -Type ERROR -Message "Cluster `"$CurrentEdgeSite`" networking.networkingVmKernelInterfaces entry (service `"$($vmk.service)`") ipList[1] `"$ip1`" is not a valid IPv4 address."; $failures++ }
            if ($ip0 -eq $ip1) { Write-LogMessage -Type ERROR -Message "Cluster `"$CurrentEdgeSite`" networking.networkingVmKernelInterfaces entry (service `"$($vmk.service)`") ipList entries must be unique."; $failures++ }
        }
    }
    foreach ($req in @("vMotion", "vSAN")) {
        if ($serviceNamesSeen -notcontains $req) { Write-LogMessage -Type ERROR -Message "Cluster `"$CurrentEdgeSite`" networking.networkingVmKernelInterfaces must contain vMotion and vSAN. Missing: $req."; $failures++ }
    }
    # When vSAN Witness is present, gateway is required on that entry only.
    foreach ($vmk in $VmKernelIfs) {
        $svc = if ($vmk.service) { [String]$vmk.service.Trim() } else { "" }
        if ($svc -eq "vSAN Witness" -and ($null -eq $vmk.PSObject.Properties["gateway"] -or [String]::IsNullOrWhiteSpace($vmk.gateway))) {
            Write-LogMessage -Type ERROR -Message "Cluster `"$CurrentEdgeSite`" networking.networkingVmKernelInterfaces entry for service `"vSAN Witness`" must have gateway (VMkernel interfaces are not configured with a gateway; gateway is for validation/documentation)."
            $failures++
        }
    }
    return $failures
}
function Test-JsonNetworkingVmKernelAndTemporaryIp {

    <#
        .SYNOPSIS
        Validates networking.networkingVmKernelInterfaces and VLAN IDs for each cluster in a deep-validation pass.
        .DESCRIPTION
        Checks that each cluster's networkSegments have valid vlanId values (0-4095), that vSAN-ESA and vSAN-OSA
        clusters declare at least vMotion and vSAN VMkernel interfaces, that interface service names are from the
        allowed set (vMotion, vSAN, vSAN Witness), and that temporary management IP fields are properly formed when present.
        .PARAMETER ClustersToValidate
        Array of cluster objects from the parsed infrastructure JSON.
        .OUTPUTS
        [Int] Number of validation failures found. 0 = all checks passed.
    
        .EXAMPLE
        $networkingVmKernelAndTemporaryIpResult = Test-JsonNetworkingVmKernelAndTemporaryIp -ClustersToValidate "domain-c123"
        if (-not $networkingVmKernelAndTemporaryIpResult.IsValid) { Write-LogMessage -Type ERROR -Message $networkingVmKernelAndTemporaryIpResult.Summary }
    #>

    [CmdletBinding()]
    [OutputType([Bool])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSCustomObject[]]$ClustersToValidate
    )
    $validationFailures = 0
    $allowedServices = @("vMotion", "vSAN", "vSAN Witness")
    foreach ($cluster in $ClustersToValidate) {
        $currentEdgeSite = $cluster.edgeSite
        $networking = $cluster.networking
        if (-not $networking) { continue }

        if ($networking.networkSegments) {
            foreach ($segment in $networking.networkSegments) {
                $vlanIdStr = $segment.vlanId
                if ($null -ne $vlanIdStr) {
                    $vlanId = $vlanIdStr -as [int]
                    if ($null -eq $vlanId -or $vlanId -lt 0 -or $vlanId -gt 4095) {
                        Write-LogMessage -Type ERROR -Message "Cluster `"$currentEdgeSite`" networking.networkSegments has invalid vlanId `"$vlanIdStr`". Must be 0-4095 inclusive."
                        $validationFailures++
                    }
                }
            }
        }

        # networkingVmKernelInterfaces is mandatory only for vSAN-ESA and vSAN-OSA (not VMFS).
        $storageType = $cluster.storagePolicy.storageType
        $requireVmKernelInterfaces = ($storageType -eq "vSAN-ESA" -or $storageType -eq "vSAN-OSA")
        $vmKernelIfs = $networking.networkingVmKernelInterfaces
        if (-not $requireVmKernelInterfaces) {
            if ($vmKernelIfs -and $vmKernelIfs.Count -gt 0) {
                Write-LogMessage -Type DEBUG -Message "Cluster `"$currentEdgeSite`" has networkingVmKernelInterfaces but storage type is `"$storageType`"; validating format only."
            }
        } elseif (-not $vmKernelIfs -or $vmKernelIfs.Count -eq 0) {
            Write-LogMessage -Type ERROR -Message "Cluster `"$currentEdgeSite`" storage type is `"$storageType`"; networking.networkingVmKernelInterfaces is required (at least vMotion and vSAN; vSAN Witness optional)."
            $validationFailures++
        }
        if (-not $vmKernelIfs -or $vmKernelIfs.Count -eq 0) { continue }
        $validationFailures += Test-VmKernelInterfacesSection `
            -AllowedServices $allowedServices `
            -CurrentEdgeSite $currentEdgeSite `
            -VmKernelIfs $vmKernelIfs
    }
    return $validationFailures
}
function Test-JsonPrefixFormats {

    <#
        .SYNOPSIS
        Validates prefix format properties in infrastructure JSON.

        .DESCRIPTION
        Validates that all prefix properties (clusterNamePrefix, datastoreNamePrefix, vdsNamePrefix, supervisorNamePrefix) conform to vSphere object naming requirements (80 characters max).

        .PARAMETER InputData
        The parsed infrastructure JSON data object.

        .OUTPUTS
        [Int] The number of validation failures found.
    
        .EXAMPLE
        $prefixFormatsResult = Test-JsonPrefixFormats -InputData $parsedConfig
        if (-not $prefixFormatsResult.IsValid) { Write-LogMessage -Type ERROR -Message $prefixFormatsResult.Summary }
    #>

    [CmdletBinding()]
    [OutputType([Bool])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSCustomObject]$InputData
    )

    $validationFailures = 0

    Write-LogMessage -Type DEBUG -Message "Validating prefix formats in infrastructure JSON (only when defined)..."
    $prefixProperties = @(
        "common.clusterNamePrefix",
        "common.datastoreNamePrefix",
        "common.vdsNamePrefix",
        "common.supervisorNamePrefix"
    )
    foreach ($prefixProperty in $prefixProperties) {
        $value = Get-JsonPropertyValue -InputData $InputData -PropertyPath $prefixProperty
        if ($null -ne $value -and -not [String]::IsNullOrWhiteSpace($value)) {
            $isValid = Test-JsonPropertyFormat -InputData $InputData -PropertyPath $prefixProperty -ValidationPreset "vSphereObject80Characters"
            if (-not $isValid) {
                $validationFailures++
            }
        }
    }

    return $validationFailures
}
function Test-JsonNetworkSegmentGateways {

    <#
        .SYNOPSIS
        Validates network segment gateways and network name matching per cluster.

        .DESCRIPTION
        Validates that network segment gateways are in correct IP address with CIDR format, and that supervisor network names exist in infrastructure network segments (case-sensitive matching).

        .PARAMETER ClustersToValidate
        Array of cluster objects to validate.

        .PARAMETER SupervisorData
        The parsed supervisor JSON data object.

        .OUTPUTS
        [Int] The number of validation failures found.
    
        .EXAMPLE
        $networkSegmentGatewaysResult = Test-JsonNetworkSegmentGateways -ClustersToValidate "domain-c123" -SupervisorData $parsedConfig
        if (-not $networkSegmentGatewaysResult.IsValid) { Write-LogMessage -Type ERROR -Message $networkSegmentGatewaysResult.Summary }
    #>

    [CmdletBinding()]
    [OutputType([Bool])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [Object[]]$ClustersToValidate,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSCustomObject]$SupervisorData
    )

    $validationFailures = 0

    foreach ($cluster in $ClustersToValidate) {
        $currentEdgeSite = $cluster.edgeSite
        if (-not $currentEdgeSite) {
            Write-LogMessage -Type ERROR -Message "Cluster is missing edgeSite identifier."
            $validationFailures++
            continue
        }

        # Find matching supervisor site spec.
        $matchingSiteSpec = $SupervisorData.siteSpec | Where-Object { $_.edgeSite -eq $currentEdgeSite } | Select-Object -First 1
        if (-not $matchingSiteSpec) {
            Write-LogMessage -Type ERROR -Message "No matching supervisor site spec found for edgeSite '$currentEdgeSite'."
            $validationFailures++
            continue
        }

        # Validate network segment gateways.
        if ($cluster.networking -and $cluster.networking.networkSegments) {
            foreach ($networkSegment in $cluster.networking.networkSegments) {
                if ($networkSegment.gateway) {
                    $isValid = Test-JsonPropertyFormat -InputData $networkSegment -PropertyPath "gateway" -ValidationPreset "IpAddressWithCidr"
                    if (-not $isValid) {
                        Write-LogMessage -Type ERROR -Message "Invalid gateway format for network segment '$($networkSegment.name)' in cluster '$currentEdgeSite': $($networkSegment.gateway)"
                        $validationFailures++
                    }
                } else {
                    Write-LogMessage -Type ERROR -Message "Network segment '$($networkSegment.name)' in cluster '$currentEdgeSite' is missing gateway."
                    $validationFailures++
                }
            }
        }

        # Validate that supervisor network names exist in infrastructure network segments (case-sensitive).
        $vksNetworks = [System.Collections.Generic.List[String]]::new()
        if ($matchingSiteSpec.mgmtNetworkSpec -and $matchingSiteSpec.mgmtNetworkSpec.mgmtNetworkName) {
            $vksNetworks.Add($matchingSiteSpec.mgmtNetworkSpec.mgmtNetworkName)
        }
        if ($matchingSiteSpec.foundationLoadBalancerComponents -and $matchingSiteSpec.foundationLoadBalancerComponents.flbManagementNetwork -and $matchingSiteSpec.foundationLoadBalancerComponents.flbManagementNetwork.flbNetworkName) {
            $vksNetworks.Add($matchingSiteSpec.foundationLoadBalancerComponents.flbManagementNetwork.flbNetworkName)
        }
        if ($matchingSiteSpec.primaryWorkloadNetwork -and $matchingSiteSpec.primaryWorkloadNetwork.primaryWorkloadNetworkName) {
            $vksNetworks.Add($matchingSiteSpec.primaryWorkloadNetwork.primaryWorkloadNetworkName)
        }
        if ($matchingSiteSpec.foundationLoadBalancerComponents -and $matchingSiteSpec.foundationLoadBalancerComponents.flbVirtualServerNetwork -and $matchingSiteSpec.foundationLoadBalancerComponents.flbVirtualServerNetwork.flbNetworkName) {
            $vksNetworks.Add($matchingSiteSpec.foundationLoadBalancerComponents.flbVirtualServerNetwork.flbNetworkName)
        }

        # Check if each VKS network exists in infrastructure network segments (case-sensitive matching).
        if ($cluster.networking -and $cluster.networking.networkSegments) {
            foreach ($vksNetwork in $vksNetworks) {
                $foundNetwork = $false
                foreach ($networkSegment in $cluster.networking.networkSegments) {
                    if ($vksNetwork -ceq $networkSegment.name) {
                        $foundNetwork = $true
                        break
                    }
                }
                if (-not $foundNetwork) {
                    Write-LogMessage -Type ERROR -Message "VKS network `"$vksNetwork`" in supervisor JSON (edgeSite: $currentEdgeSite) does not exist in infrastructure JSON network segments (case-sensitive matching)."
                    $validationFailures++
                }
            }
        }
    }

    return $validationFailures
}
function Test-JsonStoragePolicyFormats {

    <#
        .SYNOPSIS
        Validates storage policy format properties per cluster.

        .DESCRIPTION
        Validates that storage policy tag catalog and name properties conform to vSphere object naming requirements (80 characters max).

        .PARAMETER ClustersToValidate
        Array of cluster objects to validate.

        .OUTPUTS
        [Int] The number of validation failures found.
    
        .EXAMPLE
        $storagePolicyFormatsResult = Test-JsonStoragePolicyFormats -ClustersToValidate "domain-c123"
        if (-not $storagePolicyFormatsResult.IsValid) { Write-LogMessage -Type ERROR -Message $storagePolicyFormatsResult.Summary }
    #>

    [CmdletBinding()]
    [OutputType([Bool])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [Object[]]$ClustersToValidate
    )

    $validationFailures = 0

    foreach ($cluster in $ClustersToValidate) {
        $currentEdgeSite = $cluster.edgeSite
        if ($cluster.storagePolicy) {
            $storagePolicyTagCatalog = $cluster.storagePolicy.storagePolicyTagCatalog
            if ($storagePolicyTagCatalog) {
                $isValid = Test-JsonPropertyFormat -InputData $storagePolicyTagCatalog -ValidationPreset "vSphereObject80Characters"
                if (-not $isValid) {
                    Write-LogMessage -Type ERROR -Message "Invalid storagePolicyTagCatalog format in cluster '$currentEdgeSite'."
                    $validationFailures++
                }
            }
            $storagePolicyName = $cluster.storagePolicy.storagePolicyName
            if ($storagePolicyName) {
                $isValid = Test-JsonPropertyFormat -InputData $storagePolicyName -ValidationPreset "vSphereObject80Characters"
                if (-not $isValid) {
                    Write-LogMessage -Type ERROR -Message "Invalid storagePolicyName format in cluster '$currentEdgeSite'."
                    $validationFailures++
                }
            }
        }
    }

    return $validationFailures
}
function Test-JsonNumericPropertiesWithRanges {

    <#
        .SYNOPSIS
        Validates numeric properties with minimum value requirements per site.

        .DESCRIPTION
        Validates that numeric properties (IP counts, VIP counts) meet their minimum value requirements.

        .PARAMETER SiteSpecsToValidate
        Array of site specification objects to validate.

        .OUTPUTS
        [Int] The number of validation failures found.
    
        .EXAMPLE
        $numericPropertiesWithRangesResult = Test-JsonNumericPropertiesWithRanges -SiteSpecsToValidate "vsan-edge1"
        if (-not $numericPropertiesWithRangesResult.IsValid) { Write-LogMessage -Type ERROR -Message $numericPropertiesWithRangesResult.Summary }
    #>

    [CmdletBinding()]
    [OutputType([Bool])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [Object[]]$SiteSpecsToValidate
    )

    $validationFailures = 0

    foreach ($siteSpec in $SiteSpecsToValidate) {
        $currentEdgeSite = $siteSpec.edgeSite
        $numericPropertiesWithRanges = @(
            @{Path = "foundationLoadBalancerComponents.flbVipIPCount"; Min = 1; SiteSpec = $siteSpec},
            @{Path = "foundationLoadBalancerComponents.flbManagementNetwork.flbNetworkIpAddressCount"; Min = 2; SiteSpec = $siteSpec},
            @{Path = "mgmtNetworkSpec.mgmtNetworkIPCount"; Min = 5; SiteSpec = $siteSpec},
            @{Path = "primaryWorkloadNetwork.primaryWorkloadNetworkIPCount"; Min = 2; SiteSpec = $siteSpec}
        )

        foreach ($prop in $numericPropertiesWithRanges) {
            $propertyValue = Get-JsonPropertyValue -InputData $prop.SiteSpec -PropertyPath $prop.Path
            if ($null -ne $propertyValue) {
                $params = @{
                    InputData = $propertyValue
                    ValidationPreset = "Numeric"
                    MinValue = $prop.Min
                }
                $isValid = Test-JsonPropertyFormat @params
                if (-not $isValid) {
                    Write-LogMessage -Type ERROR -Message "Invalid numeric value for property `"$($prop.Path)`" in edgeSite `"$currentEdgeSite`"."
                    $validationFailures++
                }
            }
        }
    }

    return $validationFailures
}
function Test-JsonLbVirtualServerIpCount {

    <#
        .SYNOPSIS
        Warns when the LB virtual server network IP count is below the recommended minimum.

        .DESCRIPTION
        For each site, reads foundationLoadBalancerComponents.flbVirtualServerNetwork.flbNetworkIpAddressCount
        and emits a WARNING when the value is below 20. The check never fails validation; it is advisory only.
        The exact number of IPs required depends on which services are deployed, but fewer than 20 may not
        be sufficient to deploy all services.

        .PARAMETER ClustersToValidate
        Unused; retained for call-site compatibility.

        .PARAMETER InputData
        Unused; retained for call-site compatibility.

        .PARAMETER SiteSpecsToValidate
        Array of site specification objects from the supervisor JSON.

        .OUTPUTS
        [Int] Always returns 0 (warnings do not count as failures).
    
        .EXAMPLE
        $lbVirtualServerIpCountResult = Test-JsonLbVirtualServerIpCount -ClustersToValidate "domain-c123" -InputData $parsedConfig -SiteSpecsToValidate "vsan-edge1"
        if (-not $lbVirtualServerIpCountResult.IsValid) { Write-LogMessage -Type ERROR -Message $lbVirtualServerIpCountResult.Summary }
    #>

    [CmdletBinding()]
    [OutputType([Int])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [Object[]]$ClustersToValidate,
        [Parameter(Mandatory = $true)] [AllowNull()] [PSObject]$InputData,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [Object[]]$SiteSpecsToValidate
    )

    $floatingIpWarningThreshold = 20
    $propertyPath = "foundationLoadBalancerComponents.flbVirtualServerNetwork.flbNetworkIpAddressCount"

    foreach ($siteSpec in $SiteSpecsToValidate) {
        $currentEdgeSite = $siteSpec.edgeSite
        $propertyValue = Get-JsonPropertyValue -InputData $siteSpec -PropertyPath $propertyPath
        if ($null -ne $propertyValue) {
            $ipCount = [Int]$propertyValue
            if ($ipCount -lt $floatingIpWarningThreshold) {
                Write-LogMessage -Type WARNING -Message "LB virtual server network IP count for edgeSite `"$currentEdgeSite`" is $ipCount. Fewer than $floatingIpWarningThreshold floating IPs may not be enough to deploy all services. Consider increasing $propertyPath."
            }
        }
    }

    return 0
}
function Test-JsonRfc1123NetworkNames {

    <#
        .SYNOPSIS
        Validates that network names conform to RFC1123 format per site.

        .DESCRIPTION
        Validates that supervisor network names (FLB management, FLB virtual server, supervisor management, primary workload) conform to lowercase RFC1123 hostname format for WCP compliance.

        .PARAMETER SiteSpecsToValidate
        Array of site specification objects to validate.

        .OUTPUTS
        [Int] The number of validation failures found.
    
        .EXAMPLE
        $rfc1123NetworkNamesResult = Test-JsonRfc1123NetworkNames -SiteSpecsToValidate "vsan-edge1"
        if (-not $rfc1123NetworkNamesResult.IsValid) { Write-LogMessage -Type ERROR -Message $rfc1123NetworkNamesResult.Summary }
    #>

    [CmdletBinding()]
    [OutputType([Bool])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [Object[]]$SiteSpecsToValidate
    )

    $validationFailures = 0

    foreach ($siteSpec in $SiteSpecsToValidate) {
        $currentEdgeSite = $siteSpec.edgeSite
        $vksNetworkNameProperties = @(
            @{Path = "foundationLoadBalancerComponents.flbManagementNetwork.flbNetworkName"; SiteSpec = $siteSpec},
            @{Path = "foundationLoadBalancerComponents.flbVirtualServerNetwork.flbNetworkName"; SiteSpec = $siteSpec},
            @{Path = "primaryWorkloadNetwork.primaryWorkloadNetworkName"; SiteSpec = $siteSpec},
            @{Path = "mgmtNetworkSpec.mgmtNetworkName"; SiteSpec = $siteSpec}
        )
        foreach ($vksNetworkNameProperty in $vksNetworkNameProperties) {
            $networkName = Get-JsonPropertyValue -InputData $vksNetworkNameProperty.SiteSpec -PropertyPath $vksNetworkNameProperty.Path
            if ($null -ne $networkName) {
                $isValid = Test-JsonPropertyFormat -InputData $networkName -ValidationPreset "lowerCaseRfc1123PortGroup"
                if (-not $isValid) {
                    Write-LogMessage -Type ERROR -Message "Network name `"$networkName`" in edgeSite `"$currentEdgeSite`" does not conform to RFC1123 format."
                    $validationFailures++
                }
            }
        }
    }

    return $validationFailures
}
function Test-JsonRfc1123NetworkSegments {

    <#
        .SYNOPSIS
        Validates that network segment names conform to RFC1123 format.

        .DESCRIPTION
        Validates that all network segment names in clusters conform to lowercase RFC1123 format (lowercase alphanumeric with hyphens, max 80 chars) for WCP/Kubernetes compatibility.

        .PARAMETER ClustersToValidate
        Array of cluster objects to validate.

        .OUTPUTS
        [Int] The number of validation failures found.
    
        .EXAMPLE
        $rfc1123NetworkSegmentsResult = Test-JsonRfc1123NetworkSegments -ClustersToValidate "domain-c123"
        if (-not $rfc1123NetworkSegmentsResult.IsValid) { Write-LogMessage -Type ERROR -Message $rfc1123NetworkSegmentsResult.Summary }
    #>

    [CmdletBinding()]
    [OutputType([Bool])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [Object[]]$ClustersToValidate
    )

    $validationFailures = 0

    # Pattern validates: lowercase letters, numbers, hyphens (not at start/end), max 80 chars.
    $lowerCaseRfc1123RegexPattern = '^(?=.{1,80}$)[a-z0-9]([-a-z0-9]*[a-z0-9])?$'

    foreach ($cluster in $ClustersToValidate) {
        $currentEdgeSite = $cluster.edgeSite
        if ($cluster.networking -and $cluster.networking.networkSegments) {
            foreach ($networkSegment in $cluster.networking.networkSegments) {
                if ($networkSegment.name -cnotmatch $lowerCaseRfc1123RegexPattern) {
                    Write-LogMessage -Type ERROR -Message "Network segment name `"$($networkSegment.name)`" in cluster '$currentEdgeSite' does not conform to RFC1123 (lowercase alphanumeric with hyphens only)."
                    $validationFailures++
                }
            }
        }
    }

    return $validationFailures
}
function Test-JsonRfc1123VmClassNames {

    <#
        .SYNOPSIS
        Validates that VM class names conform to RFC1123 format per cluster.

        .DESCRIPTION
        Validates that VM class names conform to lowercase RFC1123 format for Kubernetes compatibility.

        .PARAMETER ClustersToValidate
        Array of cluster objects to validate.

        .OUTPUTS
        [Int] The number of validation failures found.
    
        .EXAMPLE
        $rfc1123VmClassNamesResult = Test-JsonRfc1123VmClassNames -ClustersToValidate "domain-c123"
        if (-not $rfc1123VmClassNamesResult.IsValid) { Write-LogMessage -Type ERROR -Message $rfc1123VmClassNamesResult.Summary }
    #>

    [CmdletBinding()]
    [OutputType([Bool])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [Object[]]$ClustersToValidate
    )

    $validationFailures = 0

    # Pattern validates: lowercase letters, numbers, hyphens (not at start/end), max 80 chars.
    $lowerCaseRfc1123RegexPattern = '^(?=.{1,80}$)[a-z0-9]([-a-z0-9]*[a-z0-9])?$'

    foreach ($cluster in $ClustersToValidate) {
        $currentEdgeSite = $cluster.edgeSite
        if ($cluster.supervisorServices -and $cluster.supervisorServices.vmClass) {
            $vmClassValue = $cluster.supervisorServices.vmClass
            $vmClassList = if ($vmClassValue -is [Array]) { $vmClassValue } else { @($vmClassValue) }

            foreach ($vmClassName in $vmClassList) {
                if ($vmClassName -cnotmatch $lowerCaseRfc1123RegexPattern) {
                    Write-LogMessage -Type ERROR -Message "VM class name `"$vmClassName`" in cluster '$currentEdgeSite' does not conform to RFC1123 (lowercase alphanumeric with hyphens only, max 80 chars)."
                    $validationFailures++
                }
            }
        }
    }

    return $validationFailures
}
function Test-JsonDnsServers {

    <#
        .SYNOPSIS
        Validates DNS server configuration from commonSupervisorSpec.

        .DESCRIPTION
        Validates that DNS servers array has 1-3 servers and each server is a valid IPv4 address.

        .PARAMETER SupervisorData
        The parsed supervisor JSON data object.

        .OUTPUTS
        [Int] The number of validation failures found.
    
        .EXAMPLE
        $dnsServersResult = Test-JsonDnsServers -SupervisorData $parsedConfig
        if (-not $dnsServersResult.IsValid) { Write-LogMessage -Type ERROR -Message $dnsServersResult.Summary }
    #>

    [CmdletBinding()]
    [OutputType([Bool])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSCustomObject]$SupervisorData
    )

    $validationFailures = 0

    $ipv4regexPattern = '^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$'
    if ($SupervisorData.commonSupervisorSpec -and $SupervisorData.commonSupervisorSpec.dnsServers) {
        $dnsServers = $SupervisorData.commonSupervisorSpec.dnsServers
        $dnsServerCount = $dnsServers.Count
        if ($dnsServerCount -eq 0 -or $dnsServerCount -gt 3) {
            Write-LogMessage -Type ERROR -Message "DNS server array 'commonSupervisorSpec.dnsServers' must have at least 1 server and at most 3 servers. Current count: $dnsServerCount."
            $validationFailures++
        } else {
            foreach ($dnsServerEntry in $dnsServers) {
                if ($dnsServerEntry -notmatch $ipv4regexPattern) {
                    Write-LogMessage -Type ERROR -Message "DNS server `"$dnsServerEntry`" in commonSupervisorSpec.dnsServers is not a valid IPv4 address."
                    $validationFailures++
                }
            }
        }
    }

    return $validationFailures
}
function Test-JsonFlbConfiguration {

    <#
        .SYNOPSIS
        Validates Foundation Load Balancer configuration from commonSupervisorSpec.

        .DESCRIPTION
        Validates FLB size, network type, and availability mode values.

        .PARAMETER SupervisorData
        The parsed supervisor JSON data object.

        .OUTPUTS
        [Int] The number of validation failures found.
    
        .EXAMPLE
        $flbConfigurationResult = Test-JsonFlbConfiguration -SupervisorData $parsedConfig
        if (-not $flbConfigurationResult.IsValid) { Write-LogMessage -Type ERROR -Message $flbConfigurationResult.Summary }
    #>

    [CmdletBinding()]
    [OutputType([Bool])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSCustomObject]$SupervisorData
    )

    $validationFailures = 0

    # Foundation Load Balancer size must be one of the following: SMALL, MEDIUM, LARGE, X-LARGE.
    if ($SupervisorData.commonSupervisorSpec -and $SupervisorData.commonSupervisorSpec.flbSize) {
        $isValid = Test-JsonPropertyFormat -InputData $SupervisorData.commonSupervisorSpec.flbSize -AcceptableStrings @("SMALL", "MEDIUM", "LARGE", "X-LARGE")
        if (-not $isValid) {
            Write-LogMessage -Type ERROR -Message "Invalid flbSize in commonSupervisorSpec. Must be one of: SMALL, MEDIUM, LARGE, X-LARGE."
            $validationFailures++
        }
    }

    # Only DVPG is supported for foundation load balancer networks.
    if ($SupervisorData.commonSupervisorSpec -and $SupervisorData.commonSupervisorSpec.flbNetworkType) {
        $isValid = Test-JsonPropertyFormat -InputData $SupervisorData.commonSupervisorSpec.flbNetworkType -AcceptableStrings @("DVPG")
        if (-not $isValid) {
            Write-LogMessage -Type ERROR -Message "Invalid flbNetworkType in commonSupervisorSpec. Must be 'DVPG'."
            $validationFailures++
        }
    }

    # flbAvailability must be either SINGLE_NODE or ACTIVE_PASSIVE.
    if ($SupervisorData.commonSupervisorSpec -and $SupervisorData.commonSupervisorSpec.flbAvailability) {
        $isValid = Test-JsonPropertyFormat -InputData $SupervisorData.commonSupervisorSpec.flbAvailability -AcceptableStrings @("SINGLE_NODE", "ACTIVE_PASSIVE")
        if (-not $isValid) {
            Write-LogMessage -Type ERROR -Message "Invalid flbAvailability in commonSupervisorSpec. Must be 'SINGLE_NODE' or 'ACTIVE_PASSIVE'."
            $validationFailures++
        }
    }

    return $validationFailures
}
function Test-JsonControlPlaneConfiguration {

    <#
        .SYNOPSIS
        Validates control plane configuration from commonSupervisorSpec.

        .DESCRIPTION
        Validates control plane size and VM count values.

        .PARAMETER SupervisorData
        The parsed supervisor JSON data object.

        .OUTPUTS
        [Int] The number of validation failures found.
    
        .EXAMPLE
        $controlPlaneConfigurationResult = Test-JsonControlPlaneConfiguration -SupervisorData $parsedConfig
        if (-not $controlPlaneConfigurationResult.IsValid) { Write-LogMessage -Type ERROR -Message $controlPlaneConfigurationResult.Summary }
    #>

    [CmdletBinding()]
    [OutputType([Bool])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSCustomObject]$SupervisorData
    )

    $validationFailures = 0

    # Supervisor control plane size must be one of the following: TINY, SMALL, MEDIUM, LARGE.
    if ($SupervisorData.commonSupervisorSpec -and $SupervisorData.commonSupervisorSpec.controlPlaneSize) {
        $isValid = Test-JsonPropertyFormat -InputData $SupervisorData.commonSupervisorSpec.controlPlaneSize -AcceptableStrings @("TINY", "SMALL", "MEDIUM", "LARGE")
        if (-not $isValid) {
            Write-LogMessage -Type ERROR -Message "Invalid controlPlaneSize in commonSupervisorSpec. Must be one of: TINY, SMALL, MEDIUM, LARGE."
            $validationFailures++
        }
    }

    # Ensure the control plane VM count is either 1 or 3.
    if ($SupervisorData.commonSupervisorSpec -and $SupervisorData.commonSupervisorSpec.controlPlaneVMCount) {
        $controlPlaneVMCount = $SupervisorData.commonSupervisorSpec.controlPlaneVMCount
        if ($controlPlaneVMCount -ne 1 -and $controlPlaneVMCount -ne 3) {
            Write-LogMessage -Type ERROR -Message "Invalid controlPlaneVMCount in commonSupervisorSpec. Must be 1 or 3. Current value: $controlPlaneVMCount."
            $validationFailures++
        }
    }

    return $validationFailures
}
function Test-JsonStartingIpAddresses {

    <#
        .SYNOPSIS
        Validates starting IP address properties per site.

        .DESCRIPTION
        Validates that starting IP addresses for FLB networks, supervisor networks, VIP, and workload service IPs are in valid IP address format.

        .PARAMETER SiteSpecsToValidate
        Array of site specification objects to validate.

        .OUTPUTS
        [Int] The number of validation failures found.
    
        .EXAMPLE
        $startingIpAddressesResult = Test-JsonStartingIpAddresses -SiteSpecsToValidate "vsan-edge1"
        if (-not $startingIpAddressesResult.IsValid) { Write-LogMessage -Type ERROR -Message $startingIpAddressesResult.Summary }
    #>

    [CmdletBinding()]
    [OutputType([Bool])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [Object[]]$SiteSpecsToValidate
    )

    $validationFailures = 0

    foreach ($siteSpec in $SiteSpecsToValidate) {
        $currentEdgeSite = $siteSpec.edgeSite
        $startingIpAddressProperties = @(
            @{Path = "foundationLoadBalancerComponents.flbManagementNetwork.flbNetworkIpAddressStartingIp"; SiteSpec = $siteSpec},
            @{Path = "foundationLoadBalancerComponents.flbVirtualServerNetwork.flbNetworkIpAddressStartingIp"; SiteSpec = $siteSpec},
            @{Path = "mgmtNetworkSpec.mgmtNetworkStartingIp"; SiteSpec = $siteSpec},
            @{Path = "primaryWorkloadNetwork.primaryWorkloadNetworkStartingIp"; SiteSpec = $siteSpec},
            @{Path = "foundationLoadBalancerComponents.flbVipStartIP"; SiteSpec = $siteSpec},
            @{Path = "primaryWorkloadNetwork.workloadServiceStartIp"; SiteSpec = $siteSpec}
        )
        foreach ($startingIpAddressProperty in $startingIpAddressProperties) {
            $ipAddress = Get-JsonPropertyValue -InputData $startingIpAddressProperty.SiteSpec -PropertyPath $startingIpAddressProperty.Path
            if ($null -ne $ipAddress) {
                $isValid = Test-JsonPropertyFormat -InputData $ipAddress -ValidationPreset "IpAddress"
                if (-not $isValid) {
                    Write-LogMessage -Type ERROR -Message "Invalid IP address format for property `"$($startingIpAddressProperty.Path)`" in edgeSite `"$currentEdgeSite`"."
                    $validationFailures++
                }
            }
        }
    }

    return $validationFailures
}
function Test-IpMappingCidrValidation {

    <#
        .SYNOPSIS
        Validates a set of IP-to-network-name mappings against a gateway CIDR map for one edge site.

        .DESCRIPTION
        Iterates IpMappings and for each entry: resolves the IP and network name from SiteSpec via
        Get-JsonPropertyValue; looks up the gateway CIDR from NetworkGatewayMap by name; calls
        Test-IpAddressInCidrRange; and when valid, calls Test-GatewayIpInRange to verify the gateway
        is not consumed by the starting-IP range. Returns the total failure count.

        .PARAMETER EdgeSite
        Edge site name used in log messages.

        .PARAMETER IpMappings
        Array of mapping hashtables. Each must have: IpPath, CountPath, NetworkNamePath, Description, SiteSpec.

        .PARAMETER NetworkGatewayMap
        Hashtable mapping network names (String) to gateway CIDR strings (e.g. "10.10.0.1/24").

        .EXAMPLE
        $failures += Test-IpMappingCidrValidation -EdgeSite "site1" -IpMappings $mappings -NetworkGatewayMap $gwMap

        .NOTES
        Called by Test-JsonIpAddressesInCidrRanges for each cluster in scope.
    #>

    [CmdletBinding()]
    [OutputType([Int])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$EdgeSite,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object[]]$IpMappings,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Hashtable]$NetworkGatewayMap
    )

    $failures = 0
    foreach ($mapping in $IpMappings) {
        $ipValue     = Get-JsonPropertyValue -InputData $mapping.SiteSpec -PropertyPath $mapping.IpPath
        $networkName = Get-JsonPropertyValue -InputData $mapping.SiteSpec -PropertyPath $mapping.NetworkNamePath
        if ($null -eq $ipValue -or $null -eq $networkName) { continue }
        if (-not $NetworkGatewayMap.ContainsKey($networkName)) {
            Write-LogMessage -Type ERROR -Message "Network '$networkName' referenced in supervisor JSON (edgeSite: $EdgeSite) not found in infrastructure JSON network segments."
            $failures++
            continue
        }
        $gatewayValue = $NetworkGatewayMap[$networkName]
        Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "Checking $($mapping.Description) in edgeSite '$EdgeSite': $ipValue against gateway $gatewayValue"
        $isInRange = Test-IpAddressInCidrRange -IpAddress $ipValue -CidrRange $gatewayValue
        if (-not $isInRange) {
            Write-LogMessage -Type ERROR -Message "$($mapping.Description) ($ipValue) in edgeSite '$EdgeSite' is NOT within the gateway CIDR range ($gatewayValue)"
            $failures++
            continue
        }
        Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "$($mapping.Description) ($ipValue) in edgeSite '$EdgeSite' is within the gateway CIDR range ($gatewayValue)"
        $countRaw = Get-JsonPropertyValue -InputData $mapping.SiteSpec -PropertyPath $mapping.CountPath
        $ipCount  = 0
        if ($null -ne $countRaw) { try { $ipCount = [Int]$countRaw } catch { $ipCount = 0 } }
        $gatewayIp = $gatewayValue.Split('/')[0]
        if ($ipCount -gt 0 -and (Test-GatewayIpInRange -GatewayCidr $gatewayValue -StartIp $ipValue -Count $ipCount)) {
            Write-LogMessage -Type ERROR -Message "$($mapping.Description) ($ipValue, count $ipCount) in edgeSite '$EdgeSite' includes the gateway address $gatewayIp. Set the start IP to an address after the gateway."
            $failures++
        }
    }
    return $failures
}
function Test-JsonIpAddressesInCidrRanges {

    <#
        .SYNOPSIS
        Validates that starting IP addresses are within their respective CIDR ranges.

        .DESCRIPTION
        Validates that starting IP addresses for networks match their gateway CIDR ranges by matching network names between supervisor JSON and infrastructure JSON.

        .PARAMETER ClustersToValidate
        Array of cluster objects to validate.

        .PARAMETER SupervisorData
        The parsed supervisor JSON data object.

        .OUTPUTS
        [Int] The number of validation failures found.
    
        .EXAMPLE
        $ipAddressesInCidrRangesResult = Test-JsonIpAddressesInCidrRanges -ClustersToValidate "domain-c123" -SupervisorData $parsedConfig
        if (-not $ipAddressesInCidrRangesResult.IsValid) { Write-LogMessage -Type ERROR -Message $ipAddressesInCidrRangesResult.Summary }
    #>

    [CmdletBinding()]
    [OutputType([Bool])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [Object[]]$ClustersToValidate,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSCustomObject]$SupervisorData
    )

    $validationFailures = 0

    Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "Validating starting IP addresses are within their respective CIDR ranges..."

    foreach ($cluster in $ClustersToValidate) {
        $currentEdgeSite = $cluster.edgeSite
        $matchingSiteSpec = $SupervisorData.siteSpec | Where-Object { $_.edgeSite -eq $currentEdgeSite } | Select-Object -First 1
        if (-not $matchingSiteSpec -or -not $cluster.networking -or -not $cluster.networking.networkSegments) {
            continue
        }

        $networkGatewayMap = @{}
        foreach ($networkSegment in $cluster.networking.networkSegments) {
            if ($networkSegment.name -and $networkSegment.gateway) {
                $networkGatewayMap[$networkSegment.name] = $networkSegment.gateway
            }
        }

        # Define IP-to-Network-Name mappings for validation.
        $ipToNetworkMappings = @(
            @{
                IpPath = "foundationLoadBalancerComponents.flbManagementNetwork.flbNetworkIpAddressStartingIp"
                CountPath = "foundationLoadBalancerComponents.flbManagementNetwork.flbNetworkIpAddressCount"
                NetworkNamePath = "foundationLoadBalancerComponents.flbManagementNetwork.flbNetworkName"
                Description = "FLB Management Network Starting IP"
                SiteSpec = $matchingSiteSpec
            },
            @{
                IpPath = "foundationLoadBalancerComponents.flbVirtualServerNetwork.flbNetworkIpAddressStartingIp"
                CountPath = "foundationLoadBalancerComponents.flbVirtualServerNetwork.flbNetworkIpAddressCount"
                NetworkNamePath = "foundationLoadBalancerComponents.flbVirtualServerNetwork.flbNetworkName"
                Description = "FLB Virtual Server Network Starting IP"
                SiteSpec = $matchingSiteSpec
            },
            @{
                IpPath = "mgmtNetworkSpec.mgmtNetworkStartingIp"
                CountPath = "mgmtNetworkSpec.mgmtNetworkIPCount"
                NetworkNamePath = "mgmtNetworkSpec.mgmtNetworkName"
                Description = "Supervisor Management Network Starting IP"
                SiteSpec = $matchingSiteSpec
            },
            @{
                IpPath = "primaryWorkloadNetwork.primaryWorkloadNetworkStartingIp"
                CountPath = "primaryWorkloadNetwork.primaryWorkloadNetworkIPCount"
                NetworkNamePath = "primaryWorkloadNetwork.primaryWorkloadNetworkName"
                Description = "Primary Workload Network Starting IP"
                SiteSpec = $matchingSiteSpec
            }
        )

        $validationFailures += Test-IpMappingCidrValidation `
            -EdgeSite          $currentEdgeSite `
            -IpMappings        $ipToNetworkMappings `
            -NetworkGatewayMap $networkGatewayMap
    }

    return $validationFailures
}
function Test-JsonShallowSupervisorServicesPathConfiguration {

    <#
        .SYNOPSIS
        Verifies that Argo CD, Harbor Carvel YAML, and Harbor TLS paths resolve to existing files after path expansion.

        .DESCRIPTION
        Intended for shallow validation after Update-InfrastructureJsonReferencedFilePaths. Uses
        Get-EffectiveSupervisorServicesYamlPath for Argo and Harbor supervisor YAMLs (parentDirectory
        + *YamlFileName or legacy *YamlPath). For Harbor TLS entries present on clusters where Harbor
        is enabled, checks Test-Path on clusters[].harborConfiguration paths already expanded by Update.

        .PARAMETER ClustersToValidate
        Cluster objects from the same InputData instance passed to Update-InfrastructureJsonReferencedFilePaths.

        .PARAMETER InputData
        Parsed infrastructure JSON (Harbor TLS paths must already be expanded by Update-InfrastructureJsonReferencedFilePaths).

        .OUTPUTS
        [Int] The number of validation failures found.
    
        .EXAMPLE
        $shallowSupervisorServicesPathConfigurationResult = Test-JsonShallowSupervisorServicesPathConfiguration -ClustersToValidate "domain-c123" -InputData $parsedConfig
        if (-not $shallowSupervisorServicesPathConfigurationResult.IsValid) { Write-LogMessage -Type ERROR -Message $shallowSupervisorServicesPathConfigurationResult.Summary }
    #>

    [CmdletBinding()]
    [OutputType([Bool])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [Object[]]$ClustersToValidate,
        [Parameter(Mandatory = $true)] [AllowNull()] [PSObject]$InputData
    )

    $validationFailures = 0

    foreach ($cluster in $ClustersToValidate) {
        $currentEdgeSite = $cluster.edgeSite

        if (-not (Get-EffectiveSupervisorServiceFlag -Cluster $cluster -CommonData $InputData.common -FlagName "disableArgoCD")) {
            foreach ($logicalName in @("argoCdOperatorYamlPath", "argoCdDeploymentYamlPath")) {
                $resolvedPath = Get-EffectiveSupervisorServicesYamlPath -Cluster $cluster -CommonData $InputData.common -LogicalYamlPathPropertyName $logicalName
                if ([String]::IsNullOrWhiteSpace($resolvedPath)) {
                    Write-LogMessage -Type ERROR -Message "Could not resolve $logicalName for edgeSite `"$currentEdgeSite`". Configure supervisorServices.parentDirectory with the matching *YamlFileName at cluster or common level, or set the legacy supervisorServices.$logicalName property."
                    $validationFailures++
                    continue
                }
                if (-not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
                    Write-LogMessage -Type ERROR -Message "File not found for $logicalName at `"$resolvedPath`" (edgeSite `"$currentEdgeSite`")."
                    $validationFailures++
                }
            }
        }

        if (-not (Get-EffectiveSupervisorServiceFlag -Cluster $cluster -CommonData $InputData.common -FlagName "disableHarbor")) {
            foreach ($logicalName in @("harborDataTemplateYamlPath", "harborServiceYamlPath")) {
                $resolvedPath = Get-EffectiveSupervisorServicesYamlPath -Cluster $cluster -CommonData $InputData.common -LogicalYamlPathPropertyName $logicalName
                if ([String]::IsNullOrWhiteSpace($resolvedPath)) {
                    Write-LogMessage -Type ERROR -Message "Could not resolve $logicalName for edgeSite `"$currentEdgeSite`". Configure supervisorServices.parentDirectory with the matching *YamlFileName at cluster or common level, or set the legacy supervisorServices.$logicalName property."
                    $validationFailures++
                    continue
                }
                if (-not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
                    Write-LogMessage -Type ERROR -Message "File not found for $logicalName at `"$resolvedPath`" (edgeSite `"$currentEdgeSite`")."
                    $validationFailures++
                }
            }

            $hc = $cluster.harborConfiguration
            if ($hc) {
                foreach ($tlsProperty in @("tlsCrt", "tlsKey", "caCrt")) {
                    if ($null -eq $hc.PSObject.Properties[$tlsProperty]) {
                        continue
                    }
                    $tlsPath = [String]$hc.$tlsProperty
                    if ([String]::IsNullOrWhiteSpace($tlsPath)) {
                        continue
                    }
                    if (-not (Test-Path -LiteralPath $tlsPath -PathType Leaf)) {
                        Write-LogMessage -Type ERROR -Message "clusters[].harborConfiguration.$tlsProperty file not found: `"$tlsPath`" for edgeSite `"$currentEdgeSite`". Use parentDirectory plus file name, or a resolvable full path."
                        $validationFailures++
                    }
                }
            }
        }
    }

    return $validationFailures
}
function Test-JsonYamlFilePaths {

    <#
        .SYNOPSIS
        Validates supervisor service YAML paths resolved from parentDirectory + file names or legacy *YamlPath keys.

        .DESCRIPTION
        For each Argo-enabled cluster, resolves argoCdOperatorYamlPath and argoCdDeploymentYamlPath via
        Get-EffectiveSupervisorServicesYamlPath (cluster-over-common): either supervisorServices.parentDirectory
        with the matching *YamlFileName, or legacy supervisorServices.argoCdOperatorYamlPath /
        argoCdDeploymentYamlPath. The same applies to Harbor Carvel YAMLs when Harbor is enabled.
        Resolved paths must match the FilePath validation preset.

        .PARAMETER ClustersToValidate
        Array of cluster objects to validate.

        .PARAMETER InputData
        Full parsed infrastructure JSON (for common.supervisorServices fallback).

        .OUTPUTS
        [Int] The number of validation failures found.
    
        .EXAMPLE
        $yamlFilePathsResult = Test-JsonYamlFilePaths -ClustersToValidate "domain-c123" -InputData $parsedConfig
        if (-not $yamlFilePathsResult.IsValid) { Write-LogMessage -Type ERROR -Message $yamlFilePathsResult.Summary }
    #>

    [CmdletBinding()]
    [OutputType([Bool])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [Object[]]$ClustersToValidate,
        [Parameter(Mandatory = $true)] [AllowNull()] [PSObject]$InputData
    )

    $validationFailures = 0

    foreach ($logicalName in @("argoCdOperatorYamlPath", "argoCdDeploymentYamlPath")) {
        foreach ($cluster in $ClustersToValidate) {
            if (Get-EffectiveSupervisorServiceFlag -Cluster $cluster -CommonData $InputData.common -FlagName "disableArgoCD") {
                continue
            }
            $resolvedPath = Get-EffectiveSupervisorServicesYamlPath -Cluster $cluster -CommonData $InputData.common -LogicalYamlPathPropertyName $logicalName
            if ([String]::IsNullOrWhiteSpace($resolvedPath)) {
                Write-LogMessage -Type ERROR -Message "Could not resolve $logicalName for edgeSite `"$($cluster.edgeSite)`". Configure supervisorServices.parentDirectory with the matching *YamlFileName at cluster or common level, or set the legacy supervisorServices.$logicalName property."
                $validationFailures++
                continue
            }
            if (-not (Test-JsonPropertyFormat -InputData $resolvedPath -ValidationPreset "FilePath")) {
                Write-LogMessage -Type ERROR -Message "Invalid resolved path for $logicalName in cluster '$($cluster.edgeSite)': `"$resolvedPath`"."
                $validationFailures++
            }
        }
    }

    $harborClusters = @($ClustersToValidate | Where-Object { -not (Get-EffectiveSupervisorServiceFlag -Cluster $_ -CommonData $InputData.common -FlagName "disableHarbor") })
    foreach ($logicalName in @("harborDataTemplateYamlPath", "harborServiceYamlPath")) {
        foreach ($cluster in $harborClusters) {
            $resolvedPath = Get-EffectiveSupervisorServicesYamlPath -Cluster $cluster -CommonData $InputData.common -LogicalYamlPathPropertyName $logicalName
            if ([String]::IsNullOrWhiteSpace($resolvedPath)) {
                Write-LogMessage -Type ERROR -Message "Could not resolve $logicalName for edgeSite `"$($cluster.edgeSite)`". Configure supervisorServices.parentDirectory with the matching *YamlFileName at cluster or common level, or set the legacy supervisorServices.$logicalName property."
                $validationFailures++
                continue
            }
            if (-not (Test-JsonPropertyFormat -InputData $resolvedPath -ValidationPreset "FilePath")) {
                Write-LogMessage -Type ERROR -Message "Invalid resolved path for $logicalName in cluster '$($cluster.edgeSite)': `"$resolvedPath`"."
                $validationFailures++
            }
        }
    }

    return $validationFailures
}
function Test-JsonWorkloadServiceCount {

    <#
        .SYNOPSIS
        Validates workloadServiceCount as a valid CIDR range per site.

        .DESCRIPTION
        Validates that workloadServiceCount represents a valid CIDR block (/8 to /32). This represents the number of service IP addresses to allocate for workloads.

        .PARAMETER SiteSpecsToValidate
        Array of site specification objects to validate.

        .OUTPUTS
        [Int] The number of validation failures found.
    
        .EXAMPLE
        $workloadServiceCountResult = Test-JsonWorkloadServiceCount -SiteSpecsToValidate "vsan-edge1"
        if (-not $workloadServiceCountResult.IsValid) { Write-LogMessage -Type ERROR -Message $workloadServiceCountResult.Summary }
    #>

    [CmdletBinding()]
    [OutputType([Bool])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [Object[]]$SiteSpecsToValidate
    )

    $validationFailures = 0

    Write-LogMessage -Type DEBUG -Message "Validating workloadServiceCount as valid CIDR range."
    foreach ($siteSpec in $SiteSpecsToValidate) {
        $currentEdgeSite = $siteSpec.edgeSite
        $serviceCountValue = Get-JsonPropertyValue -InputData $siteSpec -PropertyPath "primaryWorkloadNetwork.workloadServiceCount"
        if ($null -ne $serviceCountValue) {
            $isValid = Test-ValidCidrRange -InputText $serviceCountValue -PropertyPath "siteSpec[$currentEdgeSite].primaryWorkloadNetwork.workloadServiceCount"
            if (-not $isValid) {
                Write-LogMessage -Type ERROR -Message "Invalid workloadServiceCount value in edgeSite `"$currentEdgeSite`"."
                $validationFailures++
            }
        } else {
            Write-LogMessage -Type ERROR -Message "Property `"primaryWorkloadNetwork.workloadServiceCount`" is missing or null in edgeSite `"$currentEdgeSite`"."
            $validationFailures++
        }
    }

    return $validationFailures
}
function Test-JsonStoragePolicyTypes {

    <#
        .SYNOPSIS
        Validates storage policy type per cluster.

        .DESCRIPTION
        Validates that storage policy type is one of: VMFS, vSAN-OSA, vSAN-ESA.

        .PARAMETER ClustersToValidate
        Array of cluster objects to validate.

        .OUTPUTS
        [Int] The number of validation failures found.
    
        .EXAMPLE
        $storagePolicyTypesResult = Test-JsonStoragePolicyTypes -ClustersToValidate "domain-c123"
        if (-not $storagePolicyTypesResult.IsValid) { Write-LogMessage -Type ERROR -Message $storagePolicyTypesResult.Summary }
    #>

    [CmdletBinding()]
    [OutputType([Bool])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [Object[]]$ClustersToValidate
    )

    $validationFailures = 0

    foreach ($cluster in $ClustersToValidate) {
        $currentEdgeSite = $cluster.edgeSite
        if ($cluster.storagePolicy -and $cluster.storagePolicy.storageType) {
            $isValid = Test-JsonPropertyFormat -InputData $cluster.storagePolicy.storageType -AcceptableStrings @("VMFS", "vSAN-OSA", "vSAN-ESA")
            if (-not $isValid) {
                Write-LogMessage -Type ERROR -Message "Invalid storageType in cluster '$currentEdgeSite'. Must be one of: VMFS, vSAN-OSA, vSAN-ESA."
                $validationFailures++
            }
        }
    }

    return $validationFailures
}
function Test-JsonEsxHostCountByStoragePolicyType {

    <#
        .SYNOPSIS
        Validates ESX host count per cluster based on storage policy type.

        .DESCRIPTION
        Validates that ESX host count matches storage policy type requirements:
        - VMFS requires exactly 1 ESX host
        - vSAN-OSA requires exactly 2 ESX hosts
        - vSAN-ESA requires exactly 2 ESX hosts

        .PARAMETER ClustersToValidate
        Array of cluster objects to validate.

        .OUTPUTS
        [Int] The number of validation failures found.
    
        .EXAMPLE
        $esxHostCountByStoragePolicyTypeResult = Test-JsonEsxHostCountByStoragePolicyType -ClustersToValidate "domain-c123"
        if (-not $esxHostCountByStoragePolicyTypeResult.IsValid) { Write-LogMessage -Type ERROR -Message $esxHostCountByStoragePolicyTypeResult.Summary }
    #>

    [CmdletBinding()]
    [OutputType([Bool])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [Object[]]$ClustersToValidate
    )

    $validationFailures = 0

    foreach ($cluster in $ClustersToValidate) {
        $currentEdgeSite = $cluster.edgeSite
        $esxHostCount = 0
        if ($cluster.esxHosts -and $cluster.esxHosts.Count) {
            $esxHostCount = $cluster.esxHosts.Count
        }

        if ($cluster.storagePolicy -and $cluster.storagePolicy.storageType) {
            $storageType = $cluster.storagePolicy.storageType
            switch ($storageType) {
                "VMFS" {
                    if ($esxHostCount -ne 1) {
                        Write-LogMessage -Type ERROR -Message "Cluster '$currentEdgeSite' with storageType 'VMFS' must have exactly 1 ESX host. Found $esxHostCount host(s)."
                        $validationFailures++
                    }
                }
                "vSAN-OSA" {
                    if ($esxHostCount -ne 2) {
                        Write-LogMessage -Type ERROR -Message "Cluster '$currentEdgeSite' with storageType 'vSAN-OSA' must have exactly 2 ESX hosts. Found $esxHostCount host(s)."
                        $validationFailures++
                    }
                }
                "vSAN-ESA" {
                    if ($esxHostCount -ne 2) {
                        Write-LogMessage -Type ERROR -Message "Cluster '$currentEdgeSite' with storageType 'vSAN-ESA' must have exactly 2 ESX hosts. Found $esxHostCount host(s)."
                        $validationFailures++
                    }
                }
            }
        }
    }

    return $validationFailures
}
function Test-JsonEsxHostFormats {

    <#
        .SYNOPSIS
        Validates ESX host format per cluster.

        .DESCRIPTION
        Validates that each ESX host is either a valid IPv4 address (dotted quad) or a valid FQDN.
        FQDN validation allows alphanumeric characters, hyphens, dots, and underscores.

        .PARAMETER ClustersToValidate
        Array of cluster objects to validate.

        .OUTPUTS
        [Int] The number of validation failures found.
    
        .EXAMPLE
        $esxHostFormatsResult = Test-JsonEsxHostFormats -ClustersToValidate "domain-c123"
        if (-not $esxHostFormatsResult.IsValid) { Write-LogMessage -Type ERROR -Message $esxHostFormatsResult.Summary }
    #>

    [CmdletBinding()]
    [OutputType([Bool])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [Object[]]$ClustersToValidate
    )

    $validationFailures = 0

    foreach ($cluster in $ClustersToValidate) {
        $currentEdgeSite = $cluster.edgeSite
        if ($cluster.esxHosts -and $cluster.esxHosts.Count -gt 0) {
            foreach ($esxHost in $cluster.esxHosts) {
                $isValid = Test-JsonPropertyFormat -InputData $esxHost -ValidationPreset "IpAddressOrFqdn" -ValidationLabel "ESX host"
                if (-not $isValid) {
                    Write-LogMessage -Type ERROR -Message "ESX host '$esxHost' in cluster '$currentEdgeSite' is not a valid IPv4 address (dotted quad) or FQDN."
                    $validationFailures++
                }
            }
        }
    }

    return $validationFailures
}
function Test-JsonvSanWitnessVmName {

    <#
        .SYNOPSIS
        Validates vSAN witness FQDN when storage type is VSAN-OSA or VSAN-ESA.

        .DESCRIPTION
        Validates that vSanWitnessVmName is defined and is either a valid IPv4 address (dotted quad) or a valid FQDN
        when any cluster has storage type VSAN-OSA or VSAN-ESA. The validation checks both cluster-level (edgeSite)
        and common-level definitions, with cluster-level taking priority when both are defined.

        .PARAMETER ClustersToValidate
        Array of cluster objects to validate.

        .PARAMETER InputData
        The parsed infrastructure JSON data object.

        .OUTPUTS
        [Int] The number of validation failures found.
    
        .EXAMPLE
        $vSanWitnessVmNameResult = Test-JsonvSanWitnessVmName -ClustersToValidate "domain-c123" -InputData $parsedConfig
        if (-not $vSanWitnessVmNameResult.IsValid) { Write-LogMessage -Type ERROR -Message $vSanWitnessVmNameResult.Summary }
    #>

    [CmdletBinding()]
    [OutputType([Bool])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [Object[]]$ClustersToValidate,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSCustomObject]$InputData
    )

    $validationFailures = 0

    foreach ($cluster in $ClustersToValidate) {
        $currentEdgeSite = $cluster.edgeSite
        $storagePolicyType = $null

        if ($cluster.storagePolicy -and $cluster.storagePolicy.storageType) {
            $storagePolicyType = $cluster.storagePolicy.storageType
            if ($storagePolicyType -ne "vSAN-OSA" -and $storagePolicyType -ne "vSAN-ESA") {
                continue
            }
        } else {
            continue
        }

        # Determine which vSanWitnessVmName to use: cluster root, then common.
        $vSanWitnessVmName = $null
        $vSanWitnessVmNameSource = $null

        if (-not [String]::IsNullOrWhiteSpace($cluster.vSanWitnessVmName)) {
            $vSanWitnessVmName = $cluster.vSanWitnessVmName
            $vSanWitnessVmNameSource = "cluster-level (clusters[].vSanWitnessVmName)"
        } elseif (-not [String]::IsNullOrWhiteSpace($InputData.common.vSanWitnessVmName)) {
            $vSanWitnessVmName = $InputData.common.vSanWitnessVmName
            $vSanWitnessVmNameSource = "common-level (common.vSanWitnessVmName)"
        }

        # Validate that vSanWitnessVmName is defined.
        if ([String]::IsNullOrWhiteSpace($vSanWitnessVmName)) {
            Write-LogMessage -Type ERROR -Message "vSanWitnessVmName is required for cluster '$currentEdgeSite' with storage type '$storagePolicyType', but it is missing at cluster-level (clusters[].vSanWitnessVmName) and common-level (common.vSanWitnessVmName)."
            $validationFailures++
            continue
        }

        # Check if it's a valid FQDN first (more common for witness hosts).
        # This pattern allows: hostname.domain.com, host-name.domain.local, etc.
        # Use direct regex match to avoid error logging from Test-JsonPropertyFormat.
        $fqdnPattern = '^[a-zA-Z0-9]([a-zA-Z0-9\-_\.]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-_\.]*[a-zA-Z0-9])?)*$'
        $isValidFqdn = $vSanWitnessVmName -cmatch $fqdnPattern
        if ($isValidFqdn) {
            continue
        }

        # Check if it's a valid IP address (dotted quad) using direct regex match to avoid error logging.
        $ipAddressPattern = '^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$'
        $isValidIp = $vSanWitnessVmName -cmatch $ipAddressPattern
        if (-not $isValidIp) {
            Write-LogMessage -Type ERROR -Message "vSanWitnessVmName value '$vSanWitnessVmName' for cluster '$currentEdgeSite' (from $vSanWitnessVmNameSource) is not a valid IPv4 address (dotted quad) or FQDN. Required when storage type is '$storagePolicyType'."
            $validationFailures++
        }
    }

    return $validationFailures
}
function Test-JsonHaPolicy {

    <#
        .SYNOPSIS
        Validates common.haPolicy and clusters[].haPolicy when the key is present.

        .DESCRIPTION
        When haPolicy is defined, the value must be exactly slotBased, reservationBased, or disabled (non-empty string).

        .PARAMETER ClustersToValidate
        Cluster objects from infrastructure JSON.

        .PARAMETER InputData
        Parsed infrastructure JSON (common.haPolicy).

        .OUTPUTS
        Int. Number of validation failures (0 if all valid).
    
        .EXAMPLE
        $haPolicyResult = Test-JsonHaPolicy -ClustersToValidate "domain-c123" -InputData $parsedConfig
        if (-not $haPolicyResult.IsValid) { Write-LogMessage -Type ERROR -Message $haPolicyResult.Summary }
    #>

    [CmdletBinding()]
    [OutputType([Bool])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [Object[]]$ClustersToValidate,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSCustomObject]$InputData
    )

    $validationFailures = 0
    $allowedDisplay = "disabled, reservationBased, slotBased"

    if ($InputData.common -and $null -ne $InputData.common.PSObject.Properties["haPolicy"]) {
        $rawCommon = $InputData.common.haPolicy
        if ($rawCommon -isnot [String]) {
            Write-LogMessage -Type ERROR -Message "common.haPolicy must be a string (one of: $allowedDisplay) when the key is defined. Current type: $($rawCommon.GetType().Name)."
            $validationFailures++
        } else {
            $trimmedCommon = $rawCommon.Trim()
            if ([String]::IsNullOrWhiteSpace($trimmedCommon)) {
                Write-LogMessage -Type ERROR -Message "common.haPolicy cannot be empty or whitespace when the key is defined."
                $validationFailures++
            } elseif ($trimmedCommon -notin @("disabled", "reservationBased", "slotBased")) {
                Write-LogMessage -Type ERROR -Message "common.haPolicy must be one of: $allowedDisplay. Current value: '$trimmedCommon'."
                $validationFailures++
            }
        }
    }

    foreach ($cluster in $ClustersToValidate) {
        if (-not $cluster -or $null -eq $cluster.PSObject.Properties["haPolicy"]) {
            continue
        }
        $currentEdgeSite = $cluster.edgeSite
        $rawCluster = $cluster.haPolicy
        if ($rawCluster -isnot [String]) {
            Write-LogMessage -Type ERROR -Message "clusters[].haPolicy must be a string (one of: $allowedDisplay) when defined for edgeSite '$currentEdgeSite'. Current type: $($rawCluster.GetType().Name)."
            $validationFailures++
            continue
        }
        $trimmedCluster = $rawCluster.Trim()
        if ([String]::IsNullOrWhiteSpace($trimmedCluster)) {
            Write-LogMessage -Type ERROR -Message "clusters[].haPolicy cannot be empty or whitespace when defined for edgeSite '$currentEdgeSite'."
            $validationFailures++
        } elseif ($trimmedCluster -notin @("disabled", "reservationBased", "slotBased")) {
            Write-LogMessage -Type ERROR -Message "clusters[].haPolicy for edgeSite '$currentEdgeSite' must be one of: $allowedDisplay. Current value: '$trimmedCluster'."
            $validationFailures++
        }
    }

    return $validationFailures
}
function Get-CommonLabEnvironmentEnabled {

    <#
        .SYNOPSIS
        Returns whether infrastructure JSON enables lab mode (common.labenvironment true).

        .PARAMETER InputData
        Parsed infrastructure JSON root object.
    
        .EXAMPLE
        Get-CommonLabEnvironmentEnabled -InputData $parsedConfig
    #>

    [CmdletBinding()]
    [OutputType([Bool])]
    Param (
        [Parameter(Mandatory = $true)] [AllowNull()] [PSObject]$InputData
    )
    if (-not $InputData -or -not $InputData.common) {
        return $false
    }
    $labProp = $InputData.common.PSObject.Properties | Where-Object { $_.Name -ieq "labenvironment" } | Select-Object -First 1
    if ($null -eq $labProp) {
        return $false
    }
    return ($labProp.Value -eq $true)
}
function Get-HarborHostnameFromDataValuesTemplateFile {

    <#
        .SYNOPSIS
        Reads the top-level hostname value from a Harbor data values YAML template.

        .PARAMETER HarborTemplateFilePath
        Full path to the Harbor data values template (e.g. harbor-data-values-v2.14.2.yml).
    
        .EXAMPLE
        Get-HarborHostnameFromDataValuesTemplateFile -HarborTemplateFilePath "infrastructure.json"
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$HarborTemplateFilePath
    )
    if (-not (Test-Path -LiteralPath $HarborTemplateFilePath -PathType Leaf)) {
        return $null
    }
    $raw = Get-Content -LiteralPath $HarborTemplateFilePath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
    if ([String]::IsNullOrWhiteSpace($raw)) {
        return $null
    }
    # Anchor to start of line so we read the real top-level Harbor data-values hostname, not a nested key.
    # Allow an optional YAML comment marker before hostname (some templates comment the sample line).
    if ($raw -match '(?m)^(?:#\s*)?hostname:\s*(.+)\s*$') {
        $candidate = $Matches[1].Trim().Trim('"').Trim("'")
        if ([String]::IsNullOrWhiteSpace($candidate)) {
            return $null
        }
        # Return raw template text here; callers validate with Test-JsonPropertyFormat -ValidationPreset IpAddressOrFqdn (DNS host or IPv4).
        return $candidate
    }
    return $null
}
function Get-EffectiveHarborHostnameForInfrastructureCluster {

    <#
        .SYNOPSIS
        Resolves the Harbor hostname for YAML and validation (JSON hostname or lab template fallback).

        .DESCRIPTION
        When clusters[].harborConfiguration.hostname is set, returns the trimmed value. When lab mode is
        enabled and both tlsCrt and tlsKey are omitted (including when the entire harborConfiguration
        stanza is omitted), reads hostname from the Harbor data values template file resolved via
        supervisorServices. Returns null if the hostname cannot be resolved.
    
        .EXAMPLE
        Get-EffectiveHarborHostnameForInfrastructureCluster -Cluster $clusterObject -CommonData $parsedConfig
    #>

    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $true)] [AllowNull()] [PSObject]$Cluster,
        [Parameter(Mandatory = $true)] [AllowNull()] [PSObject]$CommonData,
        [Parameter(Mandatory = $false)] [Switch]$LabEnvironmentEnabled
    )
    $hc = $Cluster.harborConfiguration
    if ($hc) {
        $rawHostname = if ($hc.PSObject.Properties["hostname"]) { [String]$hc.hostname } else { "" }
        if (-not [String]::IsNullOrWhiteSpace($rawHostname)) {
            return $rawHostname.Trim()
        }
        $hasTlsCrt = ($null -ne $hc.PSObject.Properties["tlsCrt"]) -and -not [String]::IsNullOrWhiteSpace([String]$hc.tlsCrt)
        $hasTlsKey = ($null -ne $hc.PSObject.Properties["tlsKey"]) -and -not [String]::IsNullOrWhiteSpace([String]$hc.tlsKey)
    } else {
        if (-not $LabEnvironmentEnabled) {
            return $null
        }
        $hasTlsCrt = $false
        $hasTlsKey = $false
    }
    # Lab-only fallback when JSON does not carry a hostname and no customer TLS PEM paths are set: read hostname from the Harbor Carvel data-values YAML (same file deploy uses).
    if ($LabEnvironmentEnabled -and -not $hasTlsCrt -and -not $hasTlsKey) {
        $templatePath = Get-EffectiveSupervisorServicesYamlPath -Cluster $Cluster -CommonData $CommonData -LogicalYamlPathPropertyName "harborDataTemplateYamlPath"
        if ([String]::IsNullOrWhiteSpace($templatePath) -or -not (Test-Path -LiteralPath $templatePath -PathType Leaf)) {
            return $null
        }
        $fromTemplate = Get-HarborHostnameFromDataValuesTemplateFile -HarborTemplateFilePath $templatePath
        if ([String]::IsNullOrWhiteSpace($fromTemplate)) {
            return $null
        }
        return $fromTemplate.Trim()
    }
    return $null
}
function New-LabHarborSelfSignedTlsMaterialFiles {

    <#
        .SYNOPSIS
        Creates temporary PEM files for a Harbor TLS certificate (self-signed, RSA).

        .DESCRIPTION
        Uses .NET CertificateRequest so key material generation works on Windows, macOS, and Linux
        without OpenSSL. Writes tls.crt, tls.key, and ca.crt (same certificate as CA for self-signed)
        under the system temp directory. The caller must delete the files when finished.

        .PARAMETER DnsName
        Subject CN and SAN (DNS or IP).

        .PARAMETER EdgeSite
        Used only for unique temporary file names.

        .PARAMETER RsaKeySize
        RSA key size in bits. Default 2048.
    
        .EXAMPLE
        New-LabHarborSelfSignedTlsMaterialFiles -DnsName "resource-name" -EdgeSite "vsan-edge1"
    #>

    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$DnsName,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$EdgeSite,
        [Parameter(Mandatory = $false)] [ValidateRange(2048, 8192)] [Int]$RsaKeySize = 2048
    )

    $rsa = [System.Security.Cryptography.RSA]::Create($RsaKeySize)
    try {
        $distinguishedName = "CN=$DnsName"
        $dnObj = [System.Security.Cryptography.X509Certificates.X500DistinguishedName]::new($distinguishedName)
        $req = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new(
            $dnObj,
            $rsa,
            [System.Security.Cryptography.HashAlgorithmName]::SHA256,
            [System.Security.Cryptography.RSASignaturePadding]::Pkcs1
        )
        $sanBuilder = [System.Security.Cryptography.X509Certificates.SubjectAlternativeNameBuilder]::new()
        $parsedIp = $null
        if ([System.Net.IPAddress]::TryParse($DnsName, [Ref]$parsedIp)) {
            $null = $sanBuilder.AddIpAddress($parsedIp)
        } else {
            $null = $sanBuilder.AddDnsName($DnsName)
        }
        $null = $req.CertificateExtensions.Add($sanBuilder.Build())
        $notBefore = [DateTimeOffset]::UtcNow.AddMinutes(-5)
        $notAfter = $notBefore.AddYears(1)
        $cert = $req.CreateSelfSigned($notBefore, $notAfter)
        try {
            $certPem = $cert.ExportCertificatePem()
            # Export the key from the same RSA instance passed to CertificateRequest (.NET 10+ may not expose GetRSAPrivateKey on the cert).
            $keyPem = $rsa.ExportPkcs8PrivateKeyPem()
        } finally {
            $cert.Dispose()
        }
    } finally {
        $rsa.Dispose()
    }

    $tempBase = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "harbor-lab-tls-$($EdgeSite -replace '[^\w\-]', '_')-$([Guid]::NewGuid().ToString('N'))"
    $crtPath = "$tempBase.crt.pem"
    $keyPath = "$tempBase.key.pem"
    $caPath = "$tempBase.ca.pem"
    [System.IO.File]::WriteAllText($crtPath, $certPem, [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText($keyPath, $keyPem, [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText($caPath, $certPem, [System.Text.UTF8Encoding]::new($false))
    Write-LogMessage -Type INFO -Message "Lab mode: wrote self-signed Harbor TLS material for `"$DnsName`" (edge site `"$EdgeSite`") to temporary PEM files under the system temp directory."
    return [ordered]@{
        CaCrtPath  = $caPath
        TlsCrtPath = $crtPath
        TlsKeyPath = $keyPath
    }
}
function Test-HarborVolumeSizes {

    <#
        .SYNOPSIS
        Validates optional volume size fields in a cluster's harborConfiguration.

        .DESCRIPTION
        Checks each of the five optional volume size fields (registryVolumeSize, jobserviceVolumeSize,
        databaseVolumeSize, redisVolumeSize, trivyVolumeSize). When a field is present and non-empty,
        it must be a positive integer followed by "Gi" (e.g. "10Gi", "100Gi").

        .PARAMETER Cluster
        The cluster object containing the harborConfiguration stanza.

        .PARAMETER CurrentEdgeSite
        The edgeSite name used in error messages.

        .OUTPUTS
        Int
        Returns the count of validation failures found.

        .EXAMPLE
        $failures = Test-HarborVolumeSizes -Cluster $cluster -CurrentEdgeSite "site1"
    #>

    [CmdletBinding()]
    [OutputType([Int])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] $Cluster,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$CurrentEdgeSite
    )

    $volumeSizePattern = '^[1-9]\d*Gi$'
    $volumeSizeKeys = @("registryVolumeSize", "jobserviceVolumeSize", "databaseVolumeSize", "redisVolumeSize", "trivyVolumeSize")
    $failures = 0

    foreach ($key in $volumeSizeKeys) {
        $value = $Cluster.harborConfiguration.$key
        if ($null -ne $value -and -not [String]::IsNullOrWhiteSpace([String]$value)) {
            if ([String]$value -notmatch $volumeSizePattern) {
                Write-LogMessage -Type ERROR -Message "clusters[].harborConfiguration.$key value `"$value`" in edgeSite `"$CurrentEdgeSite`" is not valid. Must be a positive integer followed by `"Gi`" (e.g. `"10Gi`", `"50Gi`")."
                $failures++
            }
        }
    }

    return $failures
}
function Test-HarborSecretFields {

    <#
        .SYNOPSIS
        Validates secretKey and other secret/password fields in a cluster's harborConfiguration.

        .DESCRIPTION
        Validates secretKey: plain-text literals must be exactly 16 characters (AES-128); values
        beginning with $env: must match the valid env-var reference format. Validates all other
        secret fields (harborAdminPassword, databasePassword, coreSecret, jobserviceSecret,
        registrySecret): any value beginning with $env: must be a well-formed reference.

        .PARAMETER Cluster
        The cluster object containing the harborConfiguration stanza.

        .PARAMETER CurrentEdgeSite
        The edgeSite name used in error messages.

        .OUTPUTS
        Int
        Returns the count of validation failures found.

        .EXAMPLE
        $failures = Test-HarborSecretFields -Cluster $cluster -CurrentEdgeSite "site1"
    #>

    [CmdletBinding()]
    [OutputType([Int])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] $Cluster,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$CurrentEdgeSite
    )

    $envVarPattern = '^\$env:[A-Za-z_][A-Za-z0-9_]*$'
    $failures = 0

    $secretKeyValue = $Cluster.harborConfiguration.secretKey
    if (-not [String]::IsNullOrWhiteSpace($secretKeyValue)) {
        if ($secretKeyValue -match '^\$env:') {
            if ($secretKeyValue -notmatch $envVarPattern) {
                Write-LogMessage -Type ERROR -Message "clusters[].harborConfiguration.secretKey for edgeSite `"$CurrentEdgeSite`" has a malformed environment variable reference `"$secretKeyValue`". Use the format `$env:VARNAME where VARNAME starts with a letter or underscore and contains only letters, digits, and underscores."
                $failures++
            }
        } elseif ($secretKeyValue.Length -ne 16) {
            Write-LogMessage -Type ERROR -Message "clusters[].harborConfiguration.secretKey for edgeSite `"$CurrentEdgeSite`" must be exactly 16 characters but is $($secretKeyValue.Length) character(s). Harbor uses it as an AES-128 encryption key."
            $failures++
        }
    }

    foreach ($secretField in @("harborAdminPassword", "databasePassword", "coreSecret", "jobserviceSecret", "registrySecret")) {
        $fieldValue = $Cluster.harborConfiguration.$secretField
        if (-not [String]::IsNullOrWhiteSpace($fieldValue) -and $fieldValue -match '^\$env:' -and $fieldValue -notmatch $envVarPattern) {
            Write-LogMessage -Type ERROR -Message "clusters[].harborConfiguration.$secretField for edgeSite `"$CurrentEdgeSite`" has a malformed environment variable reference `"$fieldValue`". Use the format `$env:VARNAME where VARNAME starts with a letter or underscore and contains only letters, digits, and underscores."
            $failures++
        }
    }

    return $failures
}
function Test-HarborTlsFiles {

    <#
        .SYNOPSIS
        Validates TLS certificate file existence and PEM type for a cluster's harborConfiguration.

        .DESCRIPTION
        For each TLS field (tlsCrt, tlsKey, caCrt) that has a value, verifies the referenced file
        exists and begins with the expected PEM header. tlsCrt and caCrt must begin with
        "-----BEGIN CERTIFICATE-----". tlsKey must begin with "-----BEGIN" but not
        "-----BEGIN CERTIFICATE-----". Skipped entirely in lab mode when both tlsCrt and tlsKey
        are omitted (TLS is generated at deploy time).

        .PARAMETER Cluster
        The cluster object containing the harborConfiguration stanza.

        .PARAMETER CurrentEdgeSite
        The edgeSite name used in error messages.

        .PARAMETER HasCaCrt
        Whether the cluster's harborConfiguration has a non-empty caCrt value.

        .PARAMETER HasTlsCrt
        Whether the cluster's harborConfiguration has a non-empty tlsCrt value.

        .PARAMETER HasTlsKey
        Whether the cluster's harborConfiguration has a non-empty tlsKey value.

        .PARAMETER LabEnvironment
        Whether common.labenvironment is enabled. Used to skip file checks when both TLS paths
        are omitted (lab generates TLS at deploy time).

        .OUTPUTS
        Int
        Returns the count of validation failures found.

        .EXAMPLE
        $failures = Test-HarborTlsFiles -Cluster $cluster -CurrentEdgeSite "site1" -HasCaCrt $false -HasTlsCrt $true -HasTlsKey $true -LabEnvironment:$false
    #>

    [CmdletBinding()]
    [OutputType([Int])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] $Cluster,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$CurrentEdgeSite,
        [Parameter(Mandatory = $true)] [Bool]$HasCaCrt,
        [Parameter(Mandatory = $true)] [Bool]$HasTlsCrt,
        [Parameter(Mandatory = $true)] [Bool]$HasTlsKey,
        [Parameter(Mandatory = $true)] [Bool]$LabEnvironment
    )

    $failures = 0
    $skipTlsFileChecks = ($LabEnvironment -and -not $HasTlsCrt -and -not $HasTlsKey)

    foreach ($tlsEntry in @(
        [PSCustomObject]@{ Field = "tlsCrt"; HasValue = $HasTlsCrt; ExpectCertificate = $true  },
        [PSCustomObject]@{ Field = "tlsKey"; HasValue = $HasTlsKey; ExpectCertificate = $false },
        [PSCustomObject]@{ Field = "caCrt";  HasValue = $HasCaCrt;  ExpectCertificate = $true  }
    )) {
        if ($skipTlsFileChecks) { continue }
        if (-not $tlsEntry.HasValue) { continue }
        $filePath = $Cluster.harborConfiguration.($tlsEntry.Field)
        if (-not (Test-Path -LiteralPath $filePath)) {
            Write-LogMessage -Type ERROR -Message "clusters[].harborConfiguration.$($tlsEntry.Field) file not found: `"$filePath`" for edgeSite `"$CurrentEdgeSite`". Use parentDirectory plus file name, or a resolvable full path."
            $failures++
            continue
        }
        $pemFirstLine = (Get-Content -LiteralPath $filePath -TotalCount 1 -ErrorAction SilentlyContinue) -replace '\r', ''
        if ($tlsEntry.ExpectCertificate) {
            if ($pemFirstLine -ne "-----BEGIN CERTIFICATE-----") {
                Write-LogMessage -Type ERROR -Message "clusters[].harborConfiguration.$($tlsEntry.Field) must contain a PEM certificate (-----BEGIN CERTIFICATE-----) but the file at `"$filePath`" begins with `"$pemFirstLine`" for edgeSite `"$CurrentEdgeSite`". Check that tlsCrt and tlsKey paths are not swapped."
                $failures++
            }
        } else {
            if ($pemFirstLine -notlike "-----BEGIN*" -or $pemFirstLine -like "-----BEGIN CERTIFICATE-----") {
                Write-LogMessage -Type ERROR -Message "clusters[].harborConfiguration.$($tlsEntry.Field) must contain a PEM private key (e.g. -----BEGIN PRIVATE KEY-----) but the file at `"$filePath`" begins with `"$pemFirstLine`" for edgeSite `"$CurrentEdgeSite`". Check that tlsCrt and tlsKey paths are not swapped."
                $failures++
            }
        }
    }

    return $failures
}
function Write-HarborDuplicateHostnameWarnings {

    <#
        .SYNOPSIS
        Emits a WARNING for each Harbor hostname shared by more than one cluster.

        .DESCRIPTION
        Collects the resolved Harbor hostname for each cluster where Harbor is not disabled, then
        groups by hostname and logs a WARNING for any hostname appearing more than once. This check
        does not increment validation failures; it is advisory (each Harbor instance needs a unique
        DNS name so load-balancer IPs can be differentiated per site).

        .PARAMETER ClustersToValidate
        Array of cluster objects to inspect.

        .PARAMETER InputData
        The parsed infrastructure JSON data object (for common-level flag fallback).

        .PARAMETER LabEnvironment
        Whether common.labenvironment is enabled, passed through to hostname resolution.

        .EXAMPLE
        Write-HarborDuplicateHostnameWarnings -ClustersToValidate $clusters -InputData $inputData -LabEnvironment:$false
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [Object[]]$ClustersToValidate,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSCustomObject]$InputData,
        [Parameter(Mandatory = $true)] [Bool]$LabEnvironment
    )

    $harborHostnames = [System.Collections.Generic.List[String]]::new()
    foreach ($cluster in $ClustersToValidate) {
        if (-not (Get-EffectiveSupervisorServiceFlag -Cluster $cluster -CommonData $InputData.common -FlagName "disableHarbor")) {
            $resolvedHost = Get-EffectiveHarborHostnameForInfrastructureCluster -Cluster $cluster -CommonData $InputData.common -LabEnvironmentEnabled:$LabEnvironment
            if (-not [String]::IsNullOrWhiteSpace($resolvedHost)) {
                $harborHostnames.Add($resolvedHost)
            }
        }
    }

    $duplicateHostnames = $harborHostnames | Group-Object | Where-Object { $_.Count -gt 1 }
    foreach ($dup in $duplicateHostnames) {
        $affectedSites = ($ClustersToValidate | Where-Object {
            -not (Get-EffectiveSupervisorServiceFlag -Cluster $_ -CommonData $InputData.common -FlagName "disableHarbor") -and
            (Get-EffectiveHarborHostnameForInfrastructureCluster -Cluster $_ -CommonData $InputData.common -LabEnvironmentEnabled:$LabEnvironment) -eq $dup.Name
        } | Select-Object -ExpandProperty edgeSite) -join ", "
        Write-LogMessage -Type WARNING -Message "Multiple clusters share harborConfiguration.hostname `"$($dup.Name)`" (edgeSite(s): $affectedSites). Each Harbor instance needs a unique DNS name; both clusters will register to the same hostname, causing DNS conflicts."
    }
}
function Test-JsonHarborConfiguration {

    <#
        .SYNOPSIS
        Validates cluster-level harborConfiguration stanza when Harbor is not disabled.

        .DESCRIPTION
        For each cluster where Harbor is not disabled (disableHarbor is not true at cluster or common
        level), performs both shallow presence checks and deep format validation:

        Shallow checks:
        - harborConfiguration stanza must exist at the cluster level unless common.labenvironment is
          true (lab: the stanza may be omitted; hostname is read from the Harbor data values template and
          TLS is generated at deploy time).
        - harborConfiguration.hostname must be present and non-empty unless common.labenvironment is
          true and both tlsCrt and tlsKey are omitted (hostname is then read from the Harbor data values
          template).

        Deep checks delegated to helpers:
        - Volume sizes (Test-HarborVolumeSizes): each optional size field must be a positive integer + "Gi".
        - Secret fields (Test-HarborSecretFields): secretKey must be 16 chars or a valid $env: ref;
          other secret fields must also use valid $env: refs if they begin with $env:.
        - TLS files (Test-HarborTlsFiles): referenced PEM files must exist and contain the expected type.

        Cross-cluster hostname duplicate advisory (Write-HarborDuplicateHostnameWarnings): does not
        fail validation.

        .PARAMETER ClustersToValidate
        Array of cluster objects to validate.

        .PARAMETER InputData
        The parsed infrastructure JSON data object (for common-level flag fallback).

        .OUTPUTS
        [Int] The number of validation failures found.
    
        .EXAMPLE
        $harborConfigurationResult = Test-JsonHarborConfiguration -ClustersToValidate "domain-c123" -InputData $parsedConfig
        if (-not $harborConfigurationResult.IsValid) { Write-LogMessage -Type ERROR -Message $harborConfigurationResult.Summary }
    #>

    [CmdletBinding()]
    [OutputType([Bool])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [Object[]]$ClustersToValidate,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [PSCustomObject]$InputData
    )

    $validationFailures = 0
    $labEnvironment = Get-CommonLabEnvironmentEnabled -InputData $InputData

    foreach ($cluster in $ClustersToValidate) {
        $currentEdgeSite = $cluster.edgeSite

        if (Get-EffectiveSupervisorServiceFlag -Cluster $cluster -CommonData $InputData.common -FlagName "disableHarbor") {
            Write-LogMessage -Type DEBUG -Message "Harbor is disabled for edgeSite `"$currentEdgeSite`"; skipping harborConfiguration validation."
            continue
        }

        if (-not $cluster.harborConfiguration) {
            if ($labEnvironment) {
                Write-LogMessage -Type DEBUG -Message "Harbor: clusters[].harborConfiguration omitted for edgeSite `"$currentEdgeSite`"; lab mode will synthesize an empty stanza at deploy (hostname from Harbor data values template, self-signed TLS)."
                $effectiveHostnameOnly = Get-EffectiveHarborHostnameForInfrastructureCluster -Cluster $cluster -CommonData $InputData.common -LabEnvironmentEnabled:$labEnvironment
                if ([String]::IsNullOrWhiteSpace($effectiveHostnameOnly)) {
                    Write-LogMessage -Type ERROR -Message "clusters[].harborConfiguration is omitted for edgeSite `"$currentEdgeSite`" while Harbor is enabled in lab mode; the Harbor hostname could not be read from the data values template (hostname: key). Add harborConfiguration with hostname, or fix supervisorServices harbor template path and template content, or set supervisorServices.disableHarbor to true."
                    $validationFailures++
                } else {
                    # Test-JsonPropertyFormat IpAddressOrFqdn allowlists safe DNS labels / IPv4 (see function help for preset rules).
                    $hostOk = Test-JsonPropertyFormat -InputData $effectiveHostnameOnly -ValidationPreset "IpAddressOrFqdn" -ValidationLabel "harborConfiguration.hostname (resolved from template)"
                    if (-not $hostOk) {
                        Write-LogMessage -Type ERROR -Message "Resolved Harbor hostname from template `"$effectiveHostnameOnly`" for edgeSite `"$currentEdgeSite`" is not a valid DNS-compatible FQDN or IP address."
                        $validationFailures++
                    }
                }
                continue
            }
            Write-LogMessage -Type ERROR -Message "clusters[].harborConfiguration is required for edgeSite `"$currentEdgeSite`" because Harbor is not disabled. Add a harborConfiguration stanza, enable common.labenvironment to omit it in lab, or set supervisorServices.disableHarbor to true to skip Harbor."
            $validationFailures++
            continue
        }

        $hasTlsCrt = ($null -ne $cluster.harborConfiguration.PSObject.Properties["tlsCrt"]) -and -not [String]::IsNullOrWhiteSpace($cluster.harborConfiguration.tlsCrt)
        $hasTlsKey = ($null -ne $cluster.harborConfiguration.PSObject.Properties["tlsKey"]) -and -not [String]::IsNullOrWhiteSpace($cluster.harborConfiguration.tlsKey)
        $hasCaCrt  = ($null -ne $cluster.harborConfiguration.PSObject.Properties["caCrt"])  -and -not [String]::IsNullOrWhiteSpace($cluster.harborConfiguration.caCrt)

        if ($hasTlsCrt -xor $hasTlsKey) {
            Write-LogMessage -Type ERROR -Message "clusters[].harborConfiguration.tlsCrt and tlsKey must both be defined together for edgeSite `"$currentEdgeSite`". Define both PEM paths, omit both (when common.labenvironment is true, both omitted triggers a generated self-signed certificate), or do not set exactly one of them."
            $validationFailures++
        }

        $effectiveHostname = Get-EffectiveHarborHostnameForInfrastructureCluster -Cluster $cluster -CommonData $InputData.common -LabEnvironmentEnabled:$labEnvironment
        if ([String]::IsNullOrWhiteSpace($effectiveHostname)) {
            if ($labEnvironment -and -not $hasTlsCrt -and -not $hasTlsKey) {
                Write-LogMessage -Type ERROR -Message "clusters[].harborConfiguration.hostname is missing for edgeSite `"$currentEdgeSite`" and could not be read from the Harbor data values template (hostname: key). Set hostname in JSON or fix the template file referenced by supervisorServices (harborDataTemplateYamlFileName / harborDataTemplateYamlPath)."
                $validationFailures++
            } elseif ($hasTlsCrt -and $hasTlsKey) {
                Write-LogMessage -Type ERROR -Message "clusters[].harborConfiguration.hostname is required for edgeSite `"$currentEdgeSite`" when tlsCrt and tlsKey are supplied."
                $validationFailures++
            } else {
                Write-LogMessage -Type ERROR -Message "clusters[].harborConfiguration.hostname is required for edgeSite `"$currentEdgeSite`" and must not be empty (or enable common.labenvironment and omit tlsCrt/tlsKey to use the template hostname)."
                $validationFailures++
            }
        } else {
            $isValid = Test-JsonPropertyFormat -InputData $effectiveHostname -ValidationPreset "IpAddressOrFqdn" -ValidationLabel "harborConfiguration.hostname (resolved)"
            if (-not $isValid) {
                Write-LogMessage -Type ERROR -Message "Resolved Harbor hostname `"$effectiveHostname`" for edgeSite `"$currentEdgeSite`" is not a valid DNS-compatible FQDN or IP address."
                $validationFailures++
            }
        }

        $validationFailures += Test-HarborVolumeSizes  -Cluster $cluster -CurrentEdgeSite $currentEdgeSite
        $validationFailures += Test-HarborSecretFields -Cluster $cluster -CurrentEdgeSite $currentEdgeSite

        if ($hasCaCrt -and -not ($hasTlsCrt -and $hasTlsKey)) {
            Write-LogMessage -Type ERROR -Message "clusters[].harborConfiguration.caCrt can only be defined when both tlsCrt and tlsKey are also defined for edgeSite `"$currentEdgeSite`"."
            $validationFailures++
        }

        $validationFailures += Test-HarborTlsFiles -Cluster $cluster -CurrentEdgeSite $currentEdgeSite -HasCaCrt $hasCaCrt -HasTlsCrt $hasTlsCrt -HasTlsKey $hasTlsKey -LabEnvironment $labEnvironment
    }

    Write-HarborDuplicateHostnameWarnings -ClustersToValidate $ClustersToValidate -InputData $InputData -LabEnvironment $labEnvironment

    return $validationFailures
}
function Get-ClustersInScope {

    <#
        .SYNOPSIS
        Returns the subset of clusters from InputData that fall within the given edge-site scope.

        .DESCRIPTION
        When EdgeSitesArray is non-empty, filters InputData.clusters to only those whose edgeSite
        property is in the array. When EdgeSitesArray is empty (all-sites run), returns all clusters.
        Used by Test-JsonDeeperValidation to replace the repeated inline filter pattern.

        .PARAMETER EdgeSitesArray
        Array of edgeSite names to include. Pass an empty array to include all clusters.

        .PARAMETER InputData
        The parsed infrastructure JSON object.

        .OUTPUTS
        Object[]. Array of cluster objects in scope; may be empty.
    
        .EXAMPLE
        $clustersInScope = Get-ClustersInScope -EdgeSitesArray "vsan-edge1" -InputData $parsedConfig
    #>

    [CmdletBinding()]
    [OutputType([Object[]])]
    Param (
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [Object[]]$EdgeSitesArray,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object]$InputData
    )

    if ($EdgeSitesArray.Count -gt 0) {
        return @($InputData.clusters | Where-Object { $_.edgeSite -in $EdgeSitesArray })
    }
    return @($InputData.clusters)
}
function Get-SiteSpecsInScope {

    <#
        .SYNOPSIS
        Returns the subset of supervisor siteSpec entries that fall within the given edge-site scope.

        .DESCRIPTION
        When EdgeSitesArray is non-empty, filters SupervisorData.siteSpec to only those whose edgeSite
        property is in the array. When EdgeSitesArray is empty (all-sites run), returns all site specs.
        Used by Test-JsonDeeperValidation to replace the repeated inline filter pattern.

        .PARAMETER EdgeSitesArray
        Array of edgeSite names to include. Pass an empty array to include all site specs.

        .PARAMETER SupervisorData
        The parsed supervisor JSON object.

        .OUTPUTS
        Object[]. Array of siteSpec objects in scope; may be empty.
    
        .EXAMPLE
        $siteSpecsInScope = Get-SiteSpecsInScope -EdgeSitesArray "vsan-edge1" -SupervisorData $parsedConfig
    #>

    [CmdletBinding()]
    [OutputType([Object[]])]
    Param (
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [Object[]]$EdgeSitesArray,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object]$SupervisorData
    )

    if ($EdgeSitesArray.Count -gt 0) {
        return @($SupervisorData.siteSpec | Where-Object { $_.edgeSite -in $EdgeSitesArray })
    }
    return @($SupervisorData.siteSpec)
}
function Resolve-ValidationScopeFlags {

    <#
        .SYNOPSIS
        Returns whether Argo CD and Harbor are enabled for any cluster in the given scope.

        .DESCRIPTION
        Iterates the clusters in scope and checks the effective supervisor service flags. Returns
        a PSCustomObject with two bool properties: AnyArgoEnabled and AnyHarborEnabled. Short-circuits
        once both flags are true to avoid iterating the full cluster list.

        .PARAMETER ClustersInScope
        Array of cluster objects in scope from Get-ClustersInScope. May be empty.

        .PARAMETER CommonData
        The common property object from infrastructure JSON (inputData.common). Used by
        Get-EffectiveSupervisorServiceFlag to resolve inherited flag values.

        .PARAMETER ComputeOnly
        When set, both flags are returned as false without iterating.

        .EXAMPLE
        $flags = Resolve-ValidationScopeFlags -ClustersInScope $clusters -CommonData $inputData.common
        if ($flags.AnyArgoEnabled) { Write-LogMessage -Type INFO -Message "Argo CD enabled for scope." }

        .NOTES
        Returns [PSCustomObject]@{ AnyArgoEnabled = [bool]; AnyHarborEnabled = [bool] }.
    #>

    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    Param (
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [Object[]]$ClustersInScope,
        [Parameter(Mandatory = $true)] [AllowNull()] [Object]$CommonData,
        [Parameter(Mandatory = $false)] [Switch]$ComputeOnly
    )

    $anyArgoEnabled = $false
    $anyHarborEnabled = $false
    if (-not $ComputeOnly) {
        foreach ($clusterFlagRow in $ClustersInScope) {
            if (-not (Get-EffectiveSupervisorServiceFlag -Cluster $clusterFlagRow -CommonData $CommonData -FlagName "disableArgoCD")) {
                $anyArgoEnabled = $true
            }
            if (-not (Get-EffectiveSupervisorServiceFlag -Cluster $clusterFlagRow -CommonData $CommonData -FlagName "disableHarbor")) {
                $anyHarborEnabled = $true
            }
            if ($anyArgoEnabled -and $anyHarborEnabled) { break }
        }
    }
    return [PSCustomObject]@{ AnyArgoEnabled = $anyArgoEnabled; AnyHarborEnabled = $anyHarborEnabled }
}
function Test-JsonVsphereObjectPropertyFormats {

    <#
        .SYNOPSIS
        Validates datacenter and optional content library datastore name formats in infrastructure JSON.

        .DESCRIPTION
        Checks common.datacenterName and, when defined, common.supervisorContentLibraryDatastore
        against the vSphereObject80Characters validation preset. Returns the total number of
        validation failures.

        .PARAMETER InputData
        Parsed infrastructure JSON object.

        .EXAMPLE
        $failures += Test-JsonVsphereObjectPropertyFormats -InputData $inputData

        .NOTES
        Called by Test-JsonCommonProperties.
    #>

    [CmdletBinding()]
    [OutputType([Int])]
    Param (
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object]$InputData
    )

    Write-LogMessage -Type DEBUG -Message "Validating datacenter/contentlibrary datastore formats in infrastructure JSON..."
    $vSphereObjectProperties = @("common.datacenterName")
    if ($InputData.common -and $null -ne $InputData.common.PSObject.Properties["supervisorContentLibraryDatastore"]) {
        $vSphereObjectProperties += "common.supervisorContentLibraryDatastore"
    }
    $failures = 0
    foreach ($vSphereObjectProperty in $vSphereObjectProperties) {
        $isValid = Test-JsonPropertyFormat -InputData $InputData -PropertyPath $vSphereObjectProperty -ValidationPreset "vSphereObject80Characters"
        if (-not $isValid) { $failures++ }
    }
    return $failures
}
function Test-JsonCommonProperties {

    <#
        .SYNOPSIS
        Validates common.* properties in infrastructure JSON and returns a failure count.

        .DESCRIPTION
        Validates the shared common-section properties of infrastructure JSON: vCenterName format,
        vCenterUser format, contextName RFC1123 compliance, content library URL, vSphere object
        names, boolean flags (labenvironment, preserveAutoGeneratedKeyCertPair), numeric range for
        vSanvMotionVmKernelMtuValue, vLcmImageName format, and prefix formats. Returns the
        total number of validation failures found.

        .PARAMETER AnyArgoEnabledForScope
        Whether any cluster in scope has Argo CD enabled. Used to gate contextName validation.

        .PARAMETER AnyHarborEnabledForScope
        Whether any cluster in scope has Harbor enabled. Used to gate contextName validation.

        .PARAMETER InputData
        Parsed infrastructure JSON object.

        .EXAMPLE
        $failures = Test-JsonCommonProperties -InputData $inputData -AnyArgoEnabledForScope -AnyHarborEnabledForScope:$false

        .NOTES
        Called by Test-JsonDeeperValidation. Does not read from disk.
    #>

    [CmdletBinding()]
    [OutputType([Int])]
    Param (
        [Parameter(Mandatory = $false)] [Switch]$AnyArgoEnabledForScope,
        [Parameter(Mandatory = $false)] [Switch]$AnyHarborEnabledForScope,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object]$InputData
    )

    $failures = 0
    $failures += Test-JsonPrefixFormats -InputData $InputData

    if ($InputData.common -and -not [String]::IsNullOrWhiteSpace($InputData.common.vCenterName)) {
        $vCenterName = $InputData.common.vCenterName
        $isValid = Test-JsonPropertyFormat -InputData $vCenterName -ValidationPreset "IpAddressOrFqdn" -ValidationLabel "common.vCenterName"
        if (-not $isValid) {
            Write-LogMessage -Type ERROR -Message "common.vCenterName value '$vCenterName' is not a valid IPv4 address (dotted quad) or FQDN."
            $failures++
        }
    }

    if ($InputData.common -and -not [String]::IsNullOrWhiteSpace($InputData.common.vCenterUser)) {
        $vCenterUserPattern = '^[a-zA-Z0-9._@\-]{1,256}$'
        $isValid = Test-JsonPropertyFormat -InputData $InputData -PropertyPath "common.vCenterUser" -RegexPattern $vCenterUserPattern
        if (-not $isValid) {
            Write-LogMessage -Type ERROR -Message "common.vCenterUser must contain only letters, digits, and the characters . _ @ - (max 256 characters)."
            $failures++
        }
    }

    if (($AnyArgoEnabledForScope -or $AnyHarborEnabledForScope) -and $InputData.common -and -not [String]::IsNullOrWhiteSpace($InputData.common.contextName)) {
        $isValid = Test-JsonPropertyFormat -InputData $InputData -PropertyPath "common.contextName" -ValidationPreset "lowerCaseRfc1123PortGroup"
        if (-not $isValid) {
            Write-LogMessage -Type ERROR -Message "common.contextName must be lowercase RFC1123 compliant (e.g. lowercase alphanumeric and hyphens, 1-80 characters)."
            $failures++
        }
    }

    if ($InputData.common -and $null -ne $InputData.common.PSObject.Properties["supervisorContentLibrarySubscriptionUrl"]) {
        Write-LogMessage -Type DEBUG -Message "Validating Supervisor content library subscription URL..."
        $isValid = Test-JsonPropertyFormat -InputData $InputData -PropertyPath "common.supervisorContentLibrarySubscriptionUrl" -ValidationPreset "Url"
        if (-not $isValid) { $failures++ }
    }

    $failures += Test-JsonVsphereObjectPropertyFormats -InputData $InputData

    if ($InputData.common -and $null -ne $InputData.common.PSObject.Properties["labenvironment"]) {
        $labEnvVal = $InputData.common.labenvironment
        if (-not ($labEnvVal -is [bool])) {
            Write-LogMessage -Type ERROR -Message "Invalid common.labenvironment. When defined, value must be true or false (boolean). Current type: $($labEnvVal.GetType().Name)."
            $failures++
        }
    }

    if ($InputData.common -and $null -ne $InputData.common.PSObject.Properties["preserveAutoGeneratedKeyCertPair"]) {
        $preserveKeyCertVal = $InputData.common.preserveAutoGeneratedKeyCertPair
        if (-not ($preserveKeyCertVal -is [bool])) {
            Write-LogMessage -Type ERROR -Message "Invalid common.preserveAutoGeneratedKeyCertPair. When defined, value must be true or false (boolean). Current type: $($preserveKeyCertVal.GetType().Name)."
            $failures++
        }
    }

    if ($InputData.common -and $null -ne $InputData.common.PSObject.Properties["vSanvMotionVmKernelMtuValue"]) {
        Write-LogMessage -Type DEBUG -Message "Validating common.vSanvMotionVmKernelMtuValue (1500-9190, numbers only)..."
        $isValid = Test-JsonPropertyFormat -InputData $InputData -PropertyPath "common.vSanvMotionVmKernelMtuValue" -ValidationPreset "Numeric" -MinValue 1500 -MaxValue 9190
        if (-not $isValid) {
            Write-LogMessage -Type ERROR -Message "Invalid common.vSanvMotionVmKernelMtuValue. When defined, value must be a number between 1500 and 9190 (numbers only)."
            $failures++
        }
    }

    if ($InputData.common -and $null -ne $InputData.common.PSObject.Properties["vLcmImageName"] -and -not [String]::IsNullOrWhiteSpace($InputData.common.vLcmImageName)) {
        Write-LogMessage -Type DEBUG -Message "Validating common.vLcmImageName format..."
        $isValid = Test-JsonPropertyFormat -InputData $InputData -PropertyPath "common.vLcmImageName" -ValidationPreset "vSphereObject80Characters"
        if (-not $isValid) {
            Write-LogMessage -Type ERROR -Message "Invalid common.vLcmImageName format. Value must conform to vSphere object naming (e.g. up to 80 characters, alphanumeric, spaces, hyphens, underscores, parentheses)."
            $failures++
        }
    }

    return $failures
}
function Test-JsonSupervisorAndSiteProperties {

    <#
        .SYNOPSIS
        Validates supervisor-level and per-site spec properties, returning a failure count.

        .DESCRIPTION
        Validates DNS servers, Foundation Load Balancer configuration, control plane configuration,
        and per-site-spec properties (numeric ranges, workload service CIDR, RFC1123 network names,
        starting IP addresses). All supervisor checks are skipped when ComputeOnly is set.

        .PARAMETER ComputeOnly
        When set, all supervisor-level checks are skipped.

        .PARAMETER SiteSpecsInScope
        Array of siteSpec objects in scope from Get-SiteSpecsInScope. May be empty.

        .PARAMETER SupervisorData
        Parsed supervisor JSON object. May be null when ComputeOnly is set.

        .EXAMPLE
        $failures = Test-JsonSupervisorAndSiteProperties -SupervisorData $supervisorData -SiteSpecsInScope $siteSpecsInScope

        .NOTES
        Called by Test-JsonDeeperValidation. Does not read from disk.
    #>

    [CmdletBinding()]
    [OutputType([Int])]
    Param (
        [Parameter(Mandatory = $false)] [Switch]$ComputeOnly,
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [Object[]]$SiteSpecsInScope,
        [Parameter(Mandatory = $true)] [AllowNull()] [Object]$SupervisorData
    )

    $failures = 0

    if (-not $ComputeOnly) {
        $failures += Test-JsonDnsServers -SupervisorData $SupervisorData
        $failures += Test-JsonFlbConfiguration -SupervisorData $SupervisorData
        $failures += Test-JsonControlPlaneConfiguration -SupervisorData $SupervisorData
    }

    if ($SiteSpecsInScope.Count -gt 0) {
        $failures += Test-JsonNumericPropertiesWithRanges -SiteSpecsToValidate $SiteSpecsInScope
        # workloadServiceCount validated as valid CIDR range (/8 to /32).
        $failures += Test-JsonWorkloadServiceCount -SiteSpecsToValidate $SiteSpecsInScope
        # Network names must be lowercase RFC1123 for WCP compliance (vcenter.wcp.dns.name.noncompliant).
        $failures += Test-JsonRfc1123NetworkNames -SiteSpecsToValidate $SiteSpecsInScope
        $failures += Test-JsonStartingIpAddresses -SiteSpecsToValidate $SiteSpecsInScope
    }

    return $failures
}
function Test-JsonClusterProperties {

    <#
        .SYNOPSIS
        Validates per-cluster properties in infrastructure JSON and returns a failure count.

        .DESCRIPTION
        Validates all per-cluster and cross-cluster/site properties: network segment gateways,
        storage policy formats, per-cluster vLcmImageName, YAML file paths, LB virtual server
        IP counts, RFC1123 network segments, VMkernel networking, VM class names, storage
        policy types, vSAN witness name, HA policy, ESX host count, ESX host formats, Harbor
        configuration, and IP address CIDR range membership.

        .PARAMETER AnyArgoEnabledForScope
        Whether any cluster in scope has Argo CD enabled.

        .PARAMETER AnyHarborEnabledForScope
        Whether any cluster in scope has Harbor enabled.

        .PARAMETER ClustersInScope
        Array of cluster objects in scope. May be empty.

        .PARAMETER ComputeOnly
        When set, checks that require supervisor.json data are skipped.

        .PARAMETER InputData
        Parsed infrastructure JSON object.

        .PARAMETER SiteSpecsInScope
        Array of siteSpec objects in scope. May be empty.

        .PARAMETER SupervisorData
        Parsed supervisor JSON object. May be null when ComputeOnly is set.

        .EXAMPLE
        $failures = Test-JsonClusterProperties -InputData $inputData -SupervisorData $supervisorData `
            -ClustersInScope $clusters -SiteSpecsInScope $siteSpecs `
            -AnyArgoEnabledForScope -AnyHarborEnabledForScope:$false

        .NOTES
        Called by Test-JsonDeeperValidation. Does not read from disk.
    #>

    [CmdletBinding()]
    [OutputType([Int])]
    Param (
        [Parameter(Mandatory = $false)] [Switch]$AnyArgoEnabledForScope,
        [Parameter(Mandatory = $false)] [Switch]$AnyHarborEnabledForScope,
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [Object[]]$ClustersInScope,
        [Parameter(Mandatory = $false)] [Switch]$ComputeOnly,
        [Parameter(Mandatory = $true)] [ValidateNotNull()] [Object]$InputData,
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [Object[]]$SiteSpecsInScope,
        [Parameter(Mandatory = $true)] [AllowNull()] [Object]$SupervisorData
    )

    $failures = 0

    if (-not $ComputeOnly -and $ClustersInScope.Count -gt 0 -and $SiteSpecsInScope.Count -gt 0) {
        $failures += Test-JsonNetworkSegmentGateways -ClustersToValidate $ClustersInScope -SupervisorData $SupervisorData
    }

    if ($ClustersInScope.Count -gt 0) {
        $failures += Test-JsonStoragePolicyFormats -ClustersToValidate $ClustersInScope
    }

    foreach ($currentCluster in $ClustersInScope) {
        $currentEdgeSite = $currentCluster.edgeSite
        if ($null -eq $currentCluster.PSObject.Properties["vLcmImageName"] -or [String]::IsNullOrWhiteSpace($currentCluster.vLcmImageName)) {
            continue
        }
        Write-LogMessage -Type DEBUG -Message "Validating vLcmImageName format for cluster edgeSite `"$currentEdgeSite`"..."
        $isValid = Test-JsonPropertyFormat -InputData $currentCluster.vLcmImageName -ValidationPreset "vSphereObject80Characters"
        if (-not $isValid) {
            Write-LogMessage -Type ERROR -Message "Invalid vLcmImageName format in cluster `"$currentEdgeSite`". Value must conform to vSphere object naming (e.g. up to 80 characters, alphanumeric, spaces, hyphens, underscores, parentheses)."
            $failures++
        }
    }

    if (-not $ComputeOnly -and $ClustersInScope.Count -gt 0 -and ($AnyArgoEnabledForScope -or $AnyHarborEnabledForScope)) {
        $failures += Test-JsonYamlFilePaths -InputData $InputData -ClustersToValidate $ClustersInScope
    }

    if (-not $ComputeOnly -and $ClustersInScope.Count -gt 0 -and $SiteSpecsInScope.Count -gt 0) {
        $failures += Test-JsonLbVirtualServerIpCount -ClustersToValidate $ClustersInScope -InputData $InputData -SiteSpecsToValidate $SiteSpecsInScope
        $failures += Test-JsonIpAddressesInCidrRanges -ClustersToValidate $ClustersInScope -SupervisorData $SupervisorData
    }

    if ($ClustersInScope.Count -gt 0) {
        $failures += Test-JsonRfc1123NetworkSegments -ClustersToValidate $ClustersInScope
        $failures += Test-JsonNetworkingVmKernelAndTemporaryIp -ClustersToValidate $ClustersInScope
        $failures += Test-JsonStoragePolicyTypes -ClustersToValidate $ClustersInScope
        $failures += Test-JsonvSanWitnessVmName -ClustersToValidate $ClustersInScope -InputData $InputData
        $failures += Test-JsonHaPolicy -ClustersToValidate $ClustersInScope -InputData $InputData
        $failures += Test-JsonEsxHostCountByStoragePolicyType -ClustersToValidate $ClustersInScope
        $failures += Test-JsonEsxHostFormats -ClustersToValidate $ClustersInScope
    }

    if ($AnyArgoEnabledForScope -and $ClustersInScope.Count -gt 0) {
        $failures += Test-JsonRfc1123VmClassNames -ClustersToValidate $ClustersInScope
    }

    if (-not $ComputeOnly -and $ClustersInScope.Count -gt 0) {
        $failures += Test-JsonHarborConfiguration -ClustersToValidate $ClustersInScope -InputData $InputData
    }

    return $failures
}
function Test-JsonDeeperValidation {

    <#
        .SYNOPSIS
        Validates JSON file content against specified validation rules.

        .DESCRIPTION
        The Test-JsonDeeperValidation function provides comprehensive validation of JSON files
        against specified validation rules. It supports nested property validation
        using dot notation (e.g., "common.vCenter.name") and provides detailed reporting of
        validation failures.

        .PARAMETER ComputeOnly
        When set, does not load supervisor.json and skips deeper rules that require supervisor, Argo CD, Harbor, or supervisor site data.

        .PARAMETER EdgeSite
        Optional comma-separated edge sites; validation is limited to those clusters where applicable.

        .PARAMETER InfrastructureJson
        Path to infrastructure JSON.

        .PARAMETER SupervisorJson
        Path to supervisor JSON (ignored when -ComputeOnly is set).
    
        .EXAMPLE
        $deeperValidationResult = Test-JsonDeeperValidation -InfrastructureJson "value" -SupervisorJson "value"
        if (-not $deeperValidationResult.IsValid) { Write-LogMessage -Type ERROR -Message $deeperValidationResult.Summary }
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $false)] [Switch]$ComputeOnly,
        [Parameter(Mandatory = $false)] [String]$EdgeSite,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$InfrastructureJson,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$SupervisorJson
    )

    Write-LogMessage -Type DEBUG -Message "Entered Test-JsonDeeperValidation function..."

    $deeperValidationFunctionStartTime = Get-Date

    $inputData = ConvertFrom-JsonSafely -JsonFilePath $InfrastructureJson
    Update-InfrastructureJsonReferencedFilePaths -InfrastructureJsonPath $InfrastructureJson -InputData $inputData
    if ($ComputeOnly) {
        Write-LogMessage -Type INFO -Message "ComputeOnly: skipping supervisor.json load and deeper checks that require supervisor, Argo CD, or Harbor."
        $supervisorData = $null
    } else {
        $supervisorData = ConvertFrom-JsonSafely -JsonFilePath $SupervisorJson
    }

    $edgeSitesArray = @()
    if ($EdgeSite) {
        $edgeSitesArray = Get-EdgeSitesFromParameter -EdgeSite $EdgeSite -InputData $inputData
        $siteList = $edgeSitesArray -join '", "'
        Write-LogMessage -Type INFO -SuppressOutputToScreen -Message "Validating edgeSite(s) `"$siteList`" configuration..."
    }

    $clustersInScope = @(if ($inputData.clusters) { Get-ClustersInScope -EdgeSitesArray $edgeSitesArray -InputData $inputData })
    $siteSpecsInScope = @(if (-not $ComputeOnly -and $supervisorData -and $supervisorData.siteSpec) { Get-SiteSpecsInScope -EdgeSitesArray $edgeSitesArray -SupervisorData $supervisorData })
    $serviceFlags = Resolve-ValidationScopeFlags -ClustersInScope $clustersInScope -CommonData $inputData.common -ComputeOnly:$ComputeOnly.IsPresent

    $validationFailures = 0
    $validationFailures += Test-JsonCommonProperties -InputData $inputData -AnyArgoEnabledForScope:$serviceFlags.AnyArgoEnabled -AnyHarborEnabledForScope:$serviceFlags.AnyHarborEnabled
    $validationFailures += Test-JsonSupervisorAndSiteProperties -ComputeOnly:$ComputeOnly.IsPresent -SupervisorData $supervisorData -SiteSpecsInScope $siteSpecsInScope
    $validationFailures += Test-JsonClusterProperties -ClustersInScope $clustersInScope -ComputeOnly:$ComputeOnly.IsPresent -InputData $inputData -SiteSpecsInScope $siteSpecsInScope -SupervisorData $supervisorData -AnyArgoEnabledForScope:$serviceFlags.AnyArgoEnabled -AnyHarborEnabledForScope:$serviceFlags.AnyHarborEnabled

    if ($validationFailures -gt 0) {
        $err = "JSON parameter validation failed with $validationFailures error(s)."
        Write-LogMessage -Type ERROR -prependNewLine -Message $err
        throw [VcfDeploymentException]::new($err)
    } else {
        Write-LogMessage -Type DEBUG -Message "JSON parameter validation passed."
    }

    $deeperValidationFunctionElapsed = (Get-Date) - $deeperValidationFunctionStartTime
    $siteIndication = if ($edgeSitesArray.Count -gt 0) { "edgeSite(s) `"$($edgeSitesArray -join '", "')`"" } else { "all sites" }
    Write-LogMessage -Type DEBUG -Message "Test-JsonDeeperValidation completed all validation calls for $siteIndication in $($deeperValidationFunctionElapsed.TotalSeconds.ToString('F3')) seconds."
}
