@{
    RootModule        = 'VDI-ImageMaint.psm1'
    ModuleVersion     = '2.0.0'
    GUID              = '6f3d1c2e-8a4b-4f7e-9c1d-2b5a7e9f0c31'
    Author            = 'EMS Partner'
    CompanyName       = 'EMS Partner'
    Copyright         = '(c) EMS Partner'
    Description       = 'Golden image maintenance for Windows 11 VDI on Omnissa Horizon Instant Clone: update, optimize (OSOT), seal, generalize. English / Polish.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @('Invoke-VdiImageMaint')
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData       = @{
        PSData = @{
            Tags = @('VDI', 'Horizon', 'Omnissa', 'InstantClone', 'OSOT', 'FSLogix', 'Windows11')
        }
    }
}
