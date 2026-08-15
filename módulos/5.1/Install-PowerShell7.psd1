@{
    # Identificação do Módulo
    ModuleVersion = '1.0.0'
    GUID          = 'a2c89e47-5d2b-4f90-8e12-369b0a1f72d4'
    Author        = 'Gabriel'
    CompanyName   = 'Automação'
    Copyright     = '(c) 2026. Todos os direitos reservados.'
    Description   = 'Módulo para verificação e instalação automática do PowerShell 7+ via GitHub Releases.'

    # Requisitos do Ambiente
    # Mantido em 5.1 propositalmente: este módulo é o ponto de entrada do provisionamento
    # e pode ser executado antes de o PowerShell 7+ existir na máquina.
    PowerShellVersion    = '5.1'

    # Edições de PowerShell compatíveis
    CompatiblePSEditions = @('Desktop', 'Core')

    # Script/Módulo Principal
    RootModule = 'Install-PowerShell7.psm1'

    # Arquivos incluídos no módulo
    FileList = @('Install-PowerShell7.psm1', 'Install-PowerShell7.psd1')

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
