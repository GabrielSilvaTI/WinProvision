#Requires -Version 5.1
<#
.SYNOPSIS
    WinProvision Orchestrator - Provisionamento automatizado do Windows.
.DESCRIPTION
    Executa sequencialmente os modulos Bootstrap, Office e MAS com suporte a
    repeticao automatica, verificacao de conectividade e log detalhado.
.NOTES
    Requer execucao como Administrador.
    Compativel com PowerShell 5.1 e PSScriptAnalyzer (PSGallery rules).
#>

[CmdletBinding()]
param()

#region Configuracoes
$script:LogFile         = Join-Path -Path $env:SystemRoot -ChildPath 'Temp\WinProvision_Log.txt'
$script:MaxRetries      = 3
$script:RetryDelaySec   = 5
$script:NetworkDelaySec = 10
#endregion

#region Funcoes auxiliares

function Write-Log {
    <#
    .SYNOPSIS
        Grava uma entrada de log com timestamp e nivel no arquivo de log.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )

    $timestamp = Get-Date -Format 'dd/MM/yyyy HH:mm:ss'
    $entry     = "[$timestamp][$Level] $Message"

    try {
        $entry | Out-File -FilePath $script:LogFile -Append -Encoding UTF8
    }
    catch {
        Write-Warning "Nao foi possivel gravar no log: $($_.Exception.Message)"
    }
}

function Test-InternetConnection {
    <#
    .SYNOPSIS
        Verifica conectividade com a internet via ping.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [string]$TargetHost = '8.8.8.8'
    )

    $result = Test-Connection -ComputerName $TargetHost -Count 1 -Quiet -ErrorAction SilentlyContinue
    return [bool]$result
}

function Invoke-RemoteScript {
    <#
    .SYNOPSIS
        Baixa e executa um script remoto com suporte a retry e log.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$Url
    )

    $attempt = 0
    $success = $false

    while ($attempt -lt $script:MaxRetries -and -not $success) {
        $attempt++
        Write-Log -Message "Executando '$Name' (Tentativa $attempt de $($script:MaxRetries))..."

        if (-not (Test-InternetConnection)) {
            Write-Log -Level 'WARN' -Message "Sem conexao para '$Name'. Aguardando $($script:NetworkDelaySec)s..."
            Write-Warning "[$Name] Sem conexao. Aguardando $($script:NetworkDelaySec) segundos..."
            Start-Sleep -Seconds $script:NetworkDelaySec
            continue
        }

        try {
            # Baixa o conteudo do script remoto
            $scriptContent = Invoke-RestMethod -Uri $Url -UseBasicParsing -ErrorAction Stop

            if ([string]::IsNullOrWhiteSpace($scriptContent)) {
                Write-Log -Level 'ERROR' -Message "Conteudo vazio retornado para '$Name'."
                Write-Warning "[$Name] O script remoto veio vazio."
                break
            }

            # Executa em escopo local; erros internos sao capturados sem propagar excecao pai
            $scriptBlock = [scriptblock]::Create($scriptContent)
            & $scriptBlock

            $success = $true
            Write-Log -Message "'$Name' concluido com sucesso."
            Write-Host "[$Name] Concluido com sucesso." -ForegroundColor Green
        }
        catch {
            # Extrai a mensagem mais profunda da cadeia de excecoes
            $inner = $_.Exception
            while ($null -ne $inner.InnerException) { $inner = $inner.InnerException }
            $errorMessage = $inner.Message

            Write-Log -Level 'ERROR' -Message "ERRO em '$Name' (Tentativa $attempt): $errorMessage"
            Write-Warning "[$Name] Erro na tentativa ${attempt}: $errorMessage"

            if ($attempt -lt $script:MaxRetries) {
                Write-Host "[$Name] Tentando novamente em $($script:RetryDelaySec)s..." -ForegroundColor Yellow
                Start-Sleep -Seconds $script:RetryDelaySec
            }
        }
    }

    if (-not $success) {
        Write-Log -Level 'ERROR' -Message "FALHA CRITICA: '$Name' nao executado apos $($script:MaxRetries) tentativas."
        Write-Host "[$Name] Falhou apos $($script:MaxRetries) tentativas. Verifique o log." -ForegroundColor Red
    }

    return $success
}

#endregion

#region Inicializacao

# Garante que o diretorio de log existe
$logDir = Split-Path -Path $script:LogFile -Parent
if (-not (Test-Path -Path $logDir -PathType Container)) {
    $null = New-Item -ItemType Directory -Path $logDir -Force -ErrorAction SilentlyContinue
}

# Forca TLS 1.2 (necessario no PS 5.1 para requisicoes HTTPS)
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

Write-Host 'Iniciando WinProvision Orchestrator...' -ForegroundColor Cyan
Write-Log -Message 'Orquestrador iniciado. Ordem: Bootstrap, Office, MAS.'

#endregion

#region Definicao das tarefas

$tasks = @(
    [PSCustomObject]@{
        Name = 'Bootstrap'
        Url  = 'https://raw.githubusercontent.com/GabrielSilvaTI/WinProvision/refs/heads/main/scripts/modules/Bootstrap.ps1'
    },
    [PSCustomObject]@{
        Name = 'Office'
        Url  = 'https://raw.githubusercontent.com/GabrielSilvaTI/WinProvision/refs/heads/main/scripts/modules/office.ps1'
    },
    [PSCustomObject]@{
        Name = 'MAS'
        Url  = 'https://raw.githubusercontent.com/GabrielSilvaTI/WinProvision/refs/heads/main/scripts/modules/Ohook.ps1'
    }
)

#endregion

#region Execucao das tarefas

$results = New-Object -TypeName 'System.Collections.Generic.List[PSCustomObject]'

foreach ($task in $tasks) {
    $succeeded = Invoke-RemoteScript -Name $task.Name -Url $task.Url
    $results.Add(
        [PSCustomObject]@{
            Task    = $task.Name
            Success = $succeeded
        }
    )
}

#endregion

#region Resumo final

Write-Host ''
Write-Host '=== Resumo do Provisionamento ===' -ForegroundColor Cyan

foreach ($result in $results) {
    if ($result.Success) {
        Write-Host ("  [OK    ] {0}" -f $result.Task) -ForegroundColor Green
    }
    else {
        Write-Host ("  [FALHA] {0}" -f $result.Task) -ForegroundColor Red
    }
}

Write-Host ''
Write-Host "Log completo em: $($script:LogFile)" -ForegroundColor Cyan
Write-Log -Message 'Orquestrador finalizado.'

#endregion

exit 0
