@{
    # Analisa apenas avisos graves e erros de código
    Severity = @(
        'Error',
        'Warning'
    )

    # Executa todas as regras nativas de segurança e corretude...
    IncludeDefaultRules = $true

    # ...EXCETO as regras estéticas e ruidosas abaixo:
    ExcludeRules = @(
        # Encoding e Formatação
        'PSUseBOM',                          # Já tratado automaticamente no workflow
        'PSAvoidUsingCmdletAliases',         # Permite aliases comuns como % para ForEach-Object ou dir
        'PSUseCorrectCasing',                # Ignora maiúsculas/minúsculas em comandos (ex: write-host vs Write-Host)
        
        # Estilo e Organização Interna
        'PSAvoidLongLines',                  # Não reclama do tamanho das linhas do código
        'PSUseShouldProcessForStateChangingFunctions', # Evita exigir -WhatIf/-Confirm em funções internas
        'PSAvoidUsingWriteHost',             # Permite mensagens coloridas de log no console via Write-Host
        'PSProvideCommentBasedHelp'          # Não exige blocos de documentação <# ... #> em todas as funções
    )

    # Regras customizadas para modularidade
    Rules = @{
        PSAvoidGlobalVars = @{
            Enable = $true                   # Evita poluição de variáveis no escopo global
        }
        PSAvoidUsingPlainTextForPassword = @{
            Enable = $true                   # Evita senhas hardcoded em texto puro
        }
    }
}
