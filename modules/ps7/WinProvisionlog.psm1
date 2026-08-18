#Requires -Version 7.0

<#
.SYNOPSIS
    Consolida e publica o log de execução do WinProvision.
.DESCRIPTION
    Módulo de infraestrutura, não um passo de provisionamento. Exporta uma
    única função, chamada pelo orquestrador ao final da execução — sucesso
    ou falha — para arquivar o transcript localmente e notificar via Discord.

    O webhook está definido como padrão do parâmetro DiscordWebhook. Pode
    ser sobrescrito passando -DiscordWebhook explicitamente, ou trocado
    por uma variável de ambiente / arquivo externo no futuro.
#>

<#
.SYNOPSIS
    Arquiva o transcript da execução e publica um resumo no Discord.
.PARAMETER TranscriptPath
    Caminho do arquivo de transcript gerado pelo orquestrador (Start-Transcript).
.PARAMETER Success
    Indica se o provisionamento terminou sem falhas.
.PARAMETER FailedModule
    Nome do módulo que causou a interrupção, se houver.
.PARAMETER StartTime
    Horário de início da execução, para cálculo de duração no resumo.
.PARAMETER DiscordWebhook
    URL do webhook do Discord. Se vazia, o log é apenas arquivado localmente.
.PARAMETER ArchivePath
    Pasta local onde o log arquivado é salvo.
#>
function Complete-ProvisionLog {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$TranscriptPath,

        [Parameter(Mandatory)]
        [bool]$Success,

        [string]$FailedModule,

        [datetime]$StartTime,

        [string]$DiscordWebhook = 'https://discord.com/api/webhooks/1539058959900610560/6072l5AgVdCx_XqiGsDAaNUpLdFqrkhT7Q4HkoD5973N8JS86D-QDHBNlVwJRYWeFqJq',

        [string]$ArchivePath = 'C:\ProgramData\WinProvision\Logs'
    )

    $endTime = Get-Date

    try {
        if (-not (Test-Path -LiteralPath $ArchivePath)) {
            $null = New-Item -Path $ArchivePath -ItemType Directory -Force
        }
    }
    catch {
        Write-Warning "Não foi possível criar o diretório de arquivo '$ArchivePath': $($_.Exception.Message)"
        return $false
    }

    $archivedLog = $null
    if (Test-Path -LiteralPath $TranscriptPath) {
        $stamp = $endTime.ToString('yyyyMMdd-HHmmss')
        $archivedLog = Join-Path $ArchivePath "WinProvision_$stamp.log"
        try {
            Copy-Item -LiteralPath $TranscriptPath -Destination $archivedLog -Force
        }
        catch {
            Write-Warning "Não foi possível arquivar o transcript: $($_.Exception.Message)"
            $archivedLog = $null
        }
    }
    else {
        Write-Warning "Transcript não encontrado em '$TranscriptPath'."
    }

    if (-not $DiscordWebhook) {
        Write-Warning "Nenhum webhook configurado. Log arquivado apenas localmente."
        return $true
    }

    $statusLine   = if ($Success) { "Concluído com sucesso" } else { "Concluído com falha" }
    $statusEmoji  = if ($Success) { "✅" } else { "⚠️" }
    $durationLine = if ($StartTime) { "`n**Duração:** $((New-TimeSpan -Start $StartTime -End $endTime).ToString('hh\:mm\:ss'))" } else { "" }
    $failedLine   = if (-not $Success -and $FailedModule) { "`n**Módulo com falha:** $FailedModule" } else { "" }

    $summary = @"
🖥️ **WinProvision - $env:COMPUTERNAME**
**Status:** $statusEmoji $statusLine$durationLine$failedLine
**Fim:** $($endTime.ToString('yyyy-MM-dd HH:mm:ss'))
"@

    $payloadJson = @{ content = $summary } | ConvertTo-Json -Depth 5

    try {
        if ($archivedLog -and (Get-Item -LiteralPath $archivedLog).Length -le 8MB) {
            $form = @{
                payload_json = $payloadJson
                file         = (Get-Item -LiteralPath $archivedLog)
            }
            $null = Invoke-RestMethod -Uri $DiscordWebhook -Method Post -Form $form
        }
        else {
            $null = Invoke-RestMethod -Uri $DiscordWebhook -Method Post -Body $payloadJson -ContentType 'application/json'
        }
    }
    catch {
        Write-Warning "Falha ao enviar notificação para o Discord: $($_.Exception.Message)"
        return $false
    }

    return $true
}

Export-ModuleMember -Function Complete-ProvisionLog
