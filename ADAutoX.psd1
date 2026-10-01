@{
    RootModule           = 'ADAutoX.psm1'
    ModuleVersion        = '2.0.0'
    GUID                 = '9c4a5e38-7f21-4d1b-8390-e5a6f7b8c9d0'
    Author               = 'Identity & Directory Engineering Team'
    CompanyName          = 'Enterprise Lab & Identity Operations'
    Copyright            = '(c) 2026. All rights reserved.'
    Description          = 'Enterprise-grade Active Directory identity provisioning, transactional lifecycle management, DPAPI credential security, and audit analytics framework.'
    PowerShellVersion    = '5.1'
    FunctionsToExport    = @(
        'ConvertTo-ADLdapFilter',
        'ConvertTo-ADDistinguishedNameValue',
        'Get-ADSanitizedSamAccountName',
        'Get-ADSanitizedUserPrincipalName',
        'New-ADAutoXCorrelationId',
        'Get-ADAutoXCorrelationId',
        'Write-ADAutoXConsole',
        'Write-ADAutoXLogRecord',
        'New-ADAutoXRandomPassword',
        'Test-ADAutoXPasswordComplexity',
        'Protect-ADAutoXFileAcl',
        'Export-ADAutoXCredentials',
        'Test-ADAutoXDomainReachability',
        'Initialize-ADAutoXContext',
        'Clear-ADAutoXContext',
        'Initialize-ADAutoXLedger',
        'Get-ADAutoXLedger',
        'Add-ADAutoXLedgerEntry',
        'Invoke-ADAutoXLedgerRollback',
        'Invoke-ADAutoXPreflight',
        'Get-ADAutoXAuditReport',
        'Get-ADAutoXSecurityScan'
    )
    CmdletsToExport      = @()
    VariablesToExport    = '*'
    AliasesToExport      = @()
}
