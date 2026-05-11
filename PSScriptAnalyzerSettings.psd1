@{
    # Analyzer profile for this module. Rule names match PSScriptAnalyzer defaults (PS* prefix).
    #
    # PSAvoidUsingConvertToSecureStringWithPlainText / PSAvoidUsingPlainTextForPassword /
    # PSAvoidUsingUsernameAndPasswordParams / UsePSCredentialType:
    #   Suppressed globally because PSScriptAnalyzer settings files do not support per-function
    #   scope. The intentional usages are ConvertTo-SecureStringForCredential and
    #   Get-VcenterRestApiPlainPassword, which must handle plain-text credentials by design.
    #   All other functions use SecureString or PSCredential objects.
    #
    # PSAvoidUsingWriteHost:
    #   Suppressed because Write-LogMessage uses Write-Host for console color output and
    #   interactive prompts require it (Read-Host prompt coloring).
    #
    # PSUseBOMForUnicodeEncodedFile / PSUseSingularNouns:
    #   PSUseBOMForUnicodeEncodedFile is not applicable for cross-platform UTF-8 files.
    #   PSUseSingularNouns conflicts with established function names (e.g. Get-Datacenters).
    #
    # PSUseShouldProcessForStateChangingFunctions:
    #   All Set-*, New-*, Remove-*, Update-* functions in Private/ are internal helpers called
    #   only by orchestration functions that already implement SupportsShouldProcess. Requiring
    #   SupportsShouldProcess on every private helper adds noise without benefit because these
    #   functions are never called directly by end users and -WhatIf is handled at the entry point.
    #   NOTE: this suppression is global — any newly exported Set-*/New-*/Remove-*/Update-* cmdlets
    #   added to FunctionsToExport must manually declare [CmdletBinding(SupportsShouldProcess)].
    #
    # PSAvoidGlobalVars:
    #   Suppressed because Connect-Vcenter, Test-VcenterConnection, and Disconnect-Vcenter must
    #   read $Global:DefaultViServers and $Global:DefaultVIServer — PowerCLI's own session-state
    #   globals. There are no user-defined global variables in this module.
    #
    # PSReviewUnusedParameter:
    #   Some validation functions (e.g. Test-JsonLbVirtualServerIpCount) declare $ClustersToValidate
    #   and $InputData for uniform call-site compatibility with the validation dispatch loop in
    #   Test-JsonDeeperValidation, even when the function body only needs $SiteSpecsToValidate.
    #   This is intentional and documented in those functions' comment-based help.
    ExcludeRules = @(
        'PSAvoidGlobalVars',
        'PSAvoidUsingConvertToSecureStringWithPlainText',
        'PSAvoidUsingPlainTextForPassword',
        'PSAvoidUsingUsernameAndPasswordParams',
        'PSAvoidUsingWriteHost',
        'PSReviewUnusedParameter',
        'PSUseBOMForUnicodeEncodedFile',
        'PSUseShouldProcessForStateChangingFunctions',
        'PSUseSingularNouns',
        'UsePSCredentialType'
    )
}
