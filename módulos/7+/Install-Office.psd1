@{
    # Arquivo do módulo de script associado a este manifesto
    RootModule           = 'Install-Office.psm1'

    # Versão deste módulo
    ModuleVersion        = '1.0.0'

    # ID Usado para identificar este módulo exclusivamente (GUID)
    GUID                 = 'd7a4e219-81bc-4e20-91a5-8c9e51b1f9e2'

    # Autor deste módulo
    Author               = 'WinProvision Team'

    # Empresa ou fornecedor deste módulo
    CompanyName          = 'WinProvision'

    # Declaração de Direitos Autorais deste módulo
    Copyright            = '(c) 2026. Todos os direitos reservados.'

    # Descrição da funcionalidade fornecida por este módulo
    Description          = 'Módulo para instalação autônoma, silenciosa e idempotente do Microsoft Office via Office Tool Plus (OTP).'

    # Versão mínima do mecanismo do PowerShell exigida por este módulo
    PowerShellVersion    = '7.0'

    # Edições de PowerShell compatíveis (módulo depende de recursos exclusivos do PowerShell Core)
    CompatiblePSEditions = @('Core')

    # Arquivos incluídos no módulo
    FileList             = @('Install-Office.psm1', 'Install-Office.psd1')

    # Funções a serem exportadas por este módulo (ajuda no auto-loading rápido do PowerShell)
    FunctionsToExport    = @('Install-Office')

    # Cmdlets a serem exportados por este módulo
    CmdletsToExport      = @()

    # Variáveis a serem exportadas por este módulo
    VariablesToExport    = @()

    # Aliases a serem exportados por este módulo
    AliasesToExport      = @()

    # Informações privadas passadas para o módulo especificado em RootModule
    PrivateData          = @{
        PSData = @{
            Tags       = @('Office', 'OTP', 'Deployment', 'Provisioning', 'Automation')
            ProjectUri = 'https://github.com/YerongAI/Office-Tool'
        }
    }
}
