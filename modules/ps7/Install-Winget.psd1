@{
    # Arquivo de Módulo Principal
    RootModule           = 'Install-Winget.psm1'

    # Versão do Módulo
    ModuleVersion        = '1.2.0'

    # Identificador único do Módulo (GUID)
    GUID                 = '3f8e5c12-98ab-41c6-a213-7d829e2f1110'

    # Autor do Módulo
    Author               = 'Gabriel Silva'

    # Empresa / Organização
    CompanyName          = 'WinProvision'

    # Descrição do Módulo
    Description          = 'Módulo autônomo para verificação e instalação do winget-cli e suas dependências diretamente do GitHub.'

    # Requisito de Versão do PowerShell (ForEach-Object -Parallel, operadores ternário e null-coalescing)
    PowerShellVersion    = '7.0'

    # Edições de PowerShell compatíveis (módulo depende de recursos exclusivos do PowerShell Core)
    CompatiblePSEditions = @('Core')

    # Arquivos incluídos no módulo
    FileList             = @('Install-Winget.psm1', 'Install-Winget.psd1')

    # Funções a serem exportadas (Autoloading otimizado)
    FunctionsToExport    = @('Install-Winget')

    # Cmdlets, Variáveis e Aliases expostos
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()

    # Dados e Metadados do Módulo
    PrivateData          = @{
        PSData = @{
            ProjectUri = 'https://github.com/GabrielSilvaTI/WinProvision'
        }
    }
}
