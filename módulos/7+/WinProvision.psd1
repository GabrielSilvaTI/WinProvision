@{
    # Arquivo de Módulo Principal
    RootModule           = 'WinProvision.psm1'

    # Versão do Módulo
    ModuleVersion        = '1.0.0'

    # Identificador único (GUID)
    GUID                 = 'b2a1a8c4-543e-4b47-920f-02d1a3c71289'

    # Autor do Módulo
    Author               = 'Gabriel Silva'

    # Empresa ou Organização
    CompanyName          = 'WinProvision'

    # Descrição do Módulo
    Description          = 'Módulo para provisionamento e atualização idempotente de aplicações via winget.'

    # Requisito de Versão do PowerShell
    PowerShellVersion    = '7.0'

    # Funções a serem exportadas do módulo (Autoloading otimizado)
    FunctionsToExport    = @('Invoke-WinProvision')

    # Cmdlets, Variáveis e Aliases expostos
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()

    # Dados e Metadados do Projeto
    PrivateData          = @{
        PSData = @{
            ProjectUri = 'https://github.com/GabrielSilvaTI/WinProvision'
        }
    }
}