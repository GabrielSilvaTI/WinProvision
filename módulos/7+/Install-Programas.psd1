@{
    # Arquivo de Módulo Principal
    RootModule           = 'Install-Programas.psm1'

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

    # Requisito de Versão do PowerShell (operadores ternário e null-coalescing, -in, etc.)
    PowerShellVersion    = '7.0'

    # Edições de PowerShell compatíveis (módulo depende de recursos exclusivos do PowerShell Core)
    CompatiblePSEditions = @('Core')

    # Arquivos incluídos no módulo
    FileList             = @('Install-Programas.psm1', 'Install-Programas.psd1')

    # Funções a serem exportadas do módulo (Autoloading otimizado)
    FunctionsToExport    = @('Install-Programas')

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
