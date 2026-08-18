@{
    # Script de módulo ou ficheiro de dados associado a este manifesto.
    RootModule = 'Wallpaper.psm1'

    # Versão deste módulo
    ModuleVersion = '1.0.0'

    # Identifica exclusivamente este módulo
    GUID = 'a84d9f12-e321-412f-b258-94df18301132'

    # Autor do módulo
    Author = 'Gabriel Silva'

    # Empresa ou fornecedor deste módulo
    CompanyName = 'WinProvision'

    # Declaração de Direitos de Autor para este módulo
    Copyright = '(c) 2026 WinProvision. Todos os direitos reservados.'

    # Descrição da funcionalidade fornecida por este módulo
    Description = 'Módulo para provisionamento e configuração de papéis de parede OEM e slideshow de área de trabalho no Windows.'

    # Versão mínima do Power Shell exigida por este módulo
    PowerShellVersion = '7.0'

    # Arquiteturas de processador suportadas (None, X86, Amd64, Arm)
    ProcessorArchitecture = 'None'

    # Módulos que devem ser importados no ambiente global antes de importar este módulo
    RequiredModules = @()

    # Montagens (.dll) que devem ser carregadas antes de importar este módulo
    RequiredAssemblies = @()

    # Scripts (.ps1) executados no ambiente do chamador antes de importar este módulo
    ScriptsToProcess = @()

    # Arquivos de tipo (.ps1xml) a serem carregados ao importar este módulo
    TypesToProcess = @()

    # Arquivos de formato (.ps1xml) a serem carregados ao importar este módulo
    FormatsToProcess = @()

    # Módulos a importar como módulos aninhados do módulo especificado em RootModule
    NestedModules = @()

    # Funções a exportar deste módulo (para melhor desempenho, use curingas ou especifique diretamente)
    FunctionsToExport = @(
        'Set-Wallpaper'
    )

    # Cmdlets a exportar deste módulo
    CmdletsToExport = @()

    # Variáveis a exportar deste módulo
    VariablesToExport = @()

    # Aliases a exportar deste módulo
    AliasesToExport = @()

    # Lista de todos os módulos incluídos neste módulo
    ModuleList = @()

    # Lista de todos os arquivos incluídos neste módulo
    FileList = @()

    # Dados privados a passar para o módulo especificado em RootModule
    PrivateData = @{
        PSData = @{
            # Tags aplicadas a este módulo para busca em repositórios (PowerShell Gallery)
            Tags = @('OEM', 'Wallpaper', 'Slideshow', 'Provisioning', 'Windows')

            # URL da licença deste módulo
            # LicenseUri = ''

            # URL do projeto para este módulo
            # ProjectUri = ''
        }
    }
}
