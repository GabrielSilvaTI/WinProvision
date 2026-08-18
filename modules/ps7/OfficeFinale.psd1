@{
    RootModule        = 'OfficeFinale.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = '8e4f4b1a-2b5c-4d9a-9f3e-8a2c7d6e5f4a'  # Gere um novo com New-Guid se preferir
    Author            = 'SeuNome'
    CompanyName       = 'SuaEmpresa'
    Copyright         = '(c) 2025 SeuNome. Todos os direitos reservados.'
    Description       = 'Módulo para executar o script de ativação da Massgrave com o parâmetro /Ohook (Office).'
    PowerShellVersion = '7.0'
    FunctionsToExport = @('Invoke-OfficeFinale')
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}