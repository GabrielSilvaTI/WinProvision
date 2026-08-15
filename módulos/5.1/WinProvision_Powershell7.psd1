@{
    # Identificação do Módulo
    ModuleVersion = '1.0.0'
    GUID          = 'a2c89e47-5d2b-4f90-8e12-369b0a1f72d4'
    Author        = 'Gabriel'
    CompanyName   = 'Automação'
    Copyright     = '(c) 2026. Todos os direitos reservados.'
    Description   = 'Módulo para verificação e instalação automática do PowerShell 7+ via GitHub Releases.'

    # Requisitos do Ambiente
    PowerShellVersion = '5.1'

    # Script/Módulo Principal
    RootModule = 'Install-PowerShell7.psm1'

    # Funções a serem exportadas para o usuário final
    FunctionsToExport = @('Install-PowerShell7')

    # Desativa exportação de Aliases, Cmdlets e Variáveis desnecessários
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    # Informações Privadas
    PrivateData = @{
        PSData = @{
            Tags = @('PowerShell7', 'Install', 'Automation', 'GitHub')
        }
    }
}
