#
# PSScriptAnalyzerSettings.psd1
# Coloque este arquivo em: .github/PSScriptAnalyzerSettings.psd1
#
# Documentação completa das regras:
#   https://github.com/PowerShell/PSScriptAnalyzer/tree/master/docs/Rules
#
# Uso via workflow:
#   Invoke-ScriptAnalyzer -Path . -Recurse -Settings .\.github\PSScriptAnalyzerSettings.psd1
#
@{
    # ── Severidades avaliadas ────────────────────────────────────────────────
    # Error   → bloqueia merge (bug real ou risco de segurança)
    # Warning → bloqueia merge (má prática detectável)
    # Information → apenas informativo, não bloqueia
    Severity = @('Error', 'Warning', 'Information')

    # ── Regras EXCLUÍDAS ─────────────────────────────────────────────────────
    # Justificativas documentadas por regra para facilitar revisão futura.
    ExcludeRules = @(

        # Scripts de provisionamento usam Write-Host intencionalmente para
        # exibir progresso colorido em contextos headless/UserOnce onde
        # apenas o console importa (sem pipeline de objetos).
        'PSAvoidUsingWriteHost',

        # Múltiplas funções por arquivo é o padrão adotado nos módulos
        # de provisionamento (um arquivo = um módulo coeso).
        'PSReviewUnusedParameter',

        # Linhas longas são inevitáveis em ArgumentLists de winget/choco
        # e em blocos de configuração ($CFG). Limite de 120 chars no editor.
        'PSAvoidLongLines',

        # Alinhamento de atribuições (@{} com padding) é deliberado
        # para legibilidade no $CFG e tabelas de configuração.
        'PSAlignAssignmentStatement'
    )

    # ── Regras INCLUÍDAS explicitamente (além das built-in) ──────────────────
    # Todas as built-in já são ativas por padrão; esta seção adiciona
    # regras de segurança que queremos garantir mesmo se o default mudar.
    IncludeDefaultRules = $true

    # ── Configurações por regra ───────────────────────────────────────────────
    Rules = @{

        # Detecta credenciais em texto plano (ex: -Password "abc")
        PSAvoidUsingConvertToSecureStringWithPlainText = @{
            Enable = $true
        }

        # Proíbe uso de Invoke-Expression (vetor de injeção)
        PSAvoidUsingInvokeExpression = @{
            Enable = $true
        }

        # Garante uso de verbos aprovados em funções exportadas
        PSUseApprovedVerbs = @{
            Enable = $true
        }

        # Exige que cmdlets que alteram estado suportem -WhatIf/-Confirm
        # Desabilitado: scripts de provisionamento não são cmdlets interativos
        PSUseShouldProcessForStateChangingFunctions = @{
            Enable = $false
        }

        # Consistência de aspas: prefere aspas simples quando não há expansão
        PSAvoidUsingDoubleQuotesForConstantString = @{
            Enable = $false   # scripts têm muitas strings com $vars; desabilitado p/ ruído
        }

        # Comprimento máximo de linha (em chars) — aplicado apenas como info
        PSAvoidLongLines = @{
            Enable            = $false   # excluído acima; config aqui para documentação
            MaximumLineLength = 160
        }
    }
}
