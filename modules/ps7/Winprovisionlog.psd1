@{
    RootModule        = 'WinProvisionLog.psm1'
    ModuleVersion     = '2.0.0'
    GUID              = 'a1b2c3d4-e5f6-7890-abcd-ef1234567890'
    Author            = 'WinProvision Team'
    CompanyName       = 'Your Organization'
    Copyright         = '(c) 2026 Your Organization. All rights reserved.'
    Description       = 'Arquivamento e notificação final do log do WinProvision, com envio opcional ao Discord.'
    PowerShellVersion = '7.0'
    FunctionsToExport = @(
        'Complete-ProvisionLog'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData       = @{
        PSData = @{
            Tags       = @('Logging', 'WinProvision', 'Discord')
            LicenseUri = 'https://opensource.org/licenses/MIT'
            ProjectUri = 'https://github.com/GabrielSilvaTI/WinProvision'
        }
    }
}
