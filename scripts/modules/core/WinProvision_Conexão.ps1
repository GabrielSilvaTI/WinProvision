#Requires -Version 5.1
<#
.SYNOPSIS
    Verifica se a internet está disponível, tentando novamente em caso de falha.

.DESCRIPTION
    Script 100% autônomo, pensado como "gate" de conectividade para outras
    automações (RMM, Intune, GPO Startup Script, etc.). Faz até -MaxAttempts
    tentativas de ping, aguardando -IntervalSeconds entre elas. Retorna
    exit code consistente para permitir checagem de sucesso/falha pela
    ferramenta/script chamador.

.NOTES
    Compatível com Windows PowerShell 5.1.

    CAVEAT: o teste usa ICMP (ping) via Test-Connection. Em redes onde ICMP de
    saída é bloqueado por firewall (comum em ambientes corporativos/cloud) mas
    HTTP/DNS funcionam normalmente, este script pode reportar "sem internet"
    incorretamente (falso negativo). Se o ambiente bloquear ICMP, considere
    trocar para um teste baseado em TCP (ex.: porta 443).

    Códigos de saída:
        0 = Internet disponível
        1 = Sem conexão após todas as tentativas

.PARAMETER Target
    Host a ser testado. Padrão: 8.8.8.8

.PARAMETER MaxAttempts
    Número máximo de tentativas. Padrão: 10

.PARAMETER IntervalSeconds
    Intervalo em segundos entre tentativas. Padrão: 3
#>

[CmdletBinding()]
param(
    [string]$Target = "8.8.8.8",
    [int]$MaxAttempts = 10,
    [int]$IntervalSeconds = 3
)

for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
    Write-Host "Verificando conexão ($attempt/$MaxAttempts)..." -ForegroundColor Yellow

    if (Test-Connection -ComputerName $Target -Count 1 -Quiet) {
        Write-Host "Internet disponível!" -ForegroundColor Green
        exit 0
    }

    if ($attempt -lt $MaxAttempts) {
        Start-Sleep -Seconds $IntervalSeconds
    }
}

Write-Error "Sem conexão após $MaxAttempts tentativas."
exit 1
