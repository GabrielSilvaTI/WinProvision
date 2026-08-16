#Requires -Version 7.0

<#
.SYNOPSIS
    Orquestrador autônomo para o provisionamento do Windows (Zero-Touch).
.DESCRIPTION
    Baixa, importa e executa sequencialmente os módulos de provisionamento
    hospedados no repositório WinProvision. Projetado para execução 100%
    desatendida: nenhuma barra de progresso, confirmação ou prompt é exibido.

    A lista de módulos é sempre obtida do manifesto remoto (manifest.json)
    publicado no repositório — não há lista embutida de fallback. Isso
    significa que o manifesto é uma dependência obrigatória: se ele não
    puder ser baixado ou estiver malformado, o provisionamento é abortado.

    Para uso manual/teste, é possível ignorar o manifesto remoto passando
    -Modules explicitamente.
.PARAMETER BaseUrl
    URL base (raw.githubusercontent.com) onde os módulos (.psd1/.psm1) estão hospedados.
.PARAMETER ManifestUrl
    URL do manifesto JSON remoto listando os módulos a executar, na ordem
    desejada. Formato esperado: [{"Name":"Install-Winget","Function":"Install-Winget"}, ...]
    Por padrão, é derivado de -BaseUrl.
.PARAMETER Modules
    Lista explícita de módulos (objetos com Name/Function). Se informada,
    ignora o manifesto remoto — uso pensado para testes manuais.
.PARAMETER MaxRetries
    Número máximo de tentativas para cada requisição HTTP.
.PARAMETER TimeoutSec
    Timeout, em segundos, para cada requisição HTTP.
.PARAMETER LogPath
    Caminho do arquivo de log (transcript) da execução.
.NOTES
    Versão: 3.1 (Fully Automated / PowerShell 7+ / Manifesto Obrigatório)
#>

[CmdletBinding()]
param(
    [ValidatePattern('^https://')]
    [string]$BaseUrl = "https://raw.githubusercontent.com/GabrielSilvaTI/WinProvision/refs/heads/main/m%C3%B3dulos/7%2B",

    [ValidatePattern('^https://')]
    [string]$ManifestUrl = "$BaseUrl/manifest.json",

    [pscustomobject[]]$Modules,

    [ValidateRange(1, 10)]
    [int]$MaxRetries = 3,

    [ValidateRange(5, 300)]
    [int]$TimeoutSec = 30,

    [string]$LogPath = (Join-Path ($env:TEMP ?? "C:\Windows\Temp") "WinProvision\provision.log")
)

# --- Configurações de Automação Total (Zero Interatividade) ---
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue' # Desativa barras de download/progresso
$ConfirmPreference     = 'None'             # Suprime confirmações do PowerShell
$InformationPreference = 'Continue'

# Evita "mojibake" em mensagens acentuadas em sessões desatendidas
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$script:BaseUrl     = $BaseUrl
$script:ManifestUrl = $ManifestUrl
$script:MaxRetries  = $MaxRetries
$script:TimeoutSec  = $TimeoutSec
$script:WorkDir     = Join-Path ($env:TEMP ?? "C:\Windows\Temp") "WinProvision\Modules"

# Nome de módulo só pode conter caracteres seguros para nome de arquivo/URL,
# já que é usado para montar caminhos em disco e endpoints HTTP.
$script:ModuleNamePattern = '^[A-Za-z0-9_-]+$'

# --- Funções Auxiliares ---

function Write-Step {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Message,
        [ValidateSet("White", "Gray", "Cyan", "Green", "Red", "Yellow")]
        [string]$Color = "White"
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$timestamp] $Message" -ForegroundColor $Color
}

function Initialize-WorkDirectory {
    [CmdletBinding()]
    param()
    if (Test-Path -LiteralPath $script:WorkDir) {
        Remove-Item -LiteralPath $script:WorkDir -Recurse -Force -Confirm:$false -ErrorAction SilentlyContinue
    }
    $null = New-Item -Path $script:WorkDir -ItemType Directory -Force
    Write-Step -Message "Diretório de trabalho inicializado em: $script:WorkDir" -Color Gray
}

function Resolve-ModuleList {
    <#
        Decide a lista de módulos a executar:
        parâmetro -Modules explícito (testes) > manifesto remoto (obrigatório).
        Não há lista embutida de fallback — se o manifesto falhar, aborta.
    #>
    [CmdletBinding()]
    param()

    if ($script:ExplicitModules) {
        Write-Step -Message "Usando lista de módulos informada explicitamente (-Modules)." -Color Gray
        return $script:ExplicitModules
    }

    try {
        Write-Step -Message "Buscando manifesto remoto: $script:ManifestUrl" -Color Gray
        $raw = Invoke-RestMethod -Uri $script:ManifestUrl `
            -TimeoutSec $script:TimeoutSec `
            -MaximumRetryCount $script:MaxRetries `
            -RetryIntervalSec 2 `
            -ErrorAction Stop

        $list = @(foreach ($item in $raw) {
            $name = [string]$item.Name
            $func = if ($item.PSObject.Properties['Function']) { [string]$item.Function } else { $name }
            [pscustomobject]@{ Name = $name; Function = $func }
        })

        if ($list.Count -eq 0) {
            throw "o manifesto remoto retornou uma lista vazia."
        }

        foreach ($m in $list) {
            if ($m.Name -notmatch $script:ModuleNamePattern -or $m.Function -notmatch $script:ModuleNamePattern) {
                throw "entrada inválida no manifesto: Name='$($m.Name)' Function='$($m.Function)'."
            }
        }

        $duplicates = $list | Group-Object -Property Name | Where-Object { $_.Count -gt 1 }
        if ($duplicates) {
            $dupNames = ($duplicates | ForEach-Object { $_.Name }) -join ', '
            throw "o manifesto contém módulo(s) duplicado(s): $dupNames."
        }

        Write-Step -Message "Manifesto remoto carregado com $($list.Count) módulo(s)." -Color Gray
        return $list
    }
    catch {
        # Sem fallback: o manifesto é obrigatório, então propaga o erro para
        # abortar o provisionamento com uma mensagem clara.
        throw "Não foi possível carregar o manifesto remoto ($script:ManifestUrl): $($_.Exception.Message)"
    }
}

function Save-ModuleFiles {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Za-z0-9_-]+$')]
        [string]$ModuleName
    )
    $moduleDir = Join-Path $script:WorkDir $ModuleName
    $null = New-Item -Path $moduleDir -ItemType Directory -Force

    foreach ($ext in @("psd1", "psm1")) {
        $url  = "$($script:BaseUrl)/$ModuleName.$ext"
        $dest = Join-Path $moduleDir "$ModuleName.$ext"

        Write-Step -Message "Baixando: $ModuleName.$ext ..." -Color Gray

        try {
            Invoke-RestMethod -Uri $url -OutFile $dest `
                -UserAgent "Mozilla/5.0 (Windows NT 10.0; Win64; x64)" `
                -TimeoutSec $script:TimeoutSec `
                -MaximumRetryCount $script:MaxRetries `
                -RetryIntervalSec 2 `
                -ErrorAction Stop
        }
        catch {
            throw "Falha ao baixar $ModuleName.$ext : $($_.Exception.Message)"
        }
    }
    return $moduleDir
}

function Import-ModuleFromTemp {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ModuleName
    )
    $moduleDir = Join-Path $script:WorkDir $ModuleName
    $psd1 = Join-Path $moduleDir "$ModuleName.psd1"

    if (-not (Test-Path -LiteralPath $psd1)) {
        throw "Arquivo de manifesto '$psd1' não foi encontrado."
    }

    try {
        $null = Test-ModuleManifest -Path $psd1 -ErrorAction Stop
    }
    catch {
        throw "Manifesto de módulo inválido para '$ModuleName': $($_.Exception.Message)"
    }

    Write-Step -Message "Importando módulo: $ModuleName ..." -Color Gray
    Import-Module -Name $psd1 -Force -DisableNameChecking -ErrorAction Stop
}

function Test-FunctionExists {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$FunctionName
    )
    $cmd = Get-Command -Name $FunctionName -ErrorAction SilentlyContinue
    if ($null -eq $cmd) {
        throw "Função '$FunctionName' não encontrada após a importação do módulo."
    }
}

function Invoke-ModuleFunction {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$ModuleName,
        [Parameter(Mandatory)]
        [string]$FunctionName,
        [int]$StepNumber,
        [int]$TotalSteps
    )
    Write-Step -Message "[$StepNumber/$TotalSteps] Executando $ModuleName ($FunctionName)..." -Color Cyan

    try {
        $result = & $FunctionName

        # Contrato de retorno esperado dos módulos: $null (sucesso implícito),
        # [bool], ou objeto/hashtable com propriedade 'Success'. Qualquer outro
        # tipo de retorno é tratado como falha — o módulo deve declarar
        # explicitamente seu status.
        $isSuccess = $false
        switch ($true) {
            { $null -eq $result } { $isSuccess = $true; break }
            { $result -is [bool] } { $isSuccess = $result; break }
            { $result -is [hashtable] -and $result.ContainsKey('Success') } { $isSuccess = [bool]$result['Success']; break }
            { $result -is [pscustomobject] -and $result.PSObject.Properties['Success'] } { $isSuccess = [bool]$result.Success; break }
        }

        if ($isSuccess) {
            Write-Step -Message "[OK] $ModuleName finalizado com sucesso." -Color Green
            return $true
        }

        Write-Step -Message "[ERRO] $ModuleName retornou status de falha." -Color Red
        return $false
    }
    catch {
        Write-Step -Message "[EXCEÇÃO] Erro ao executar $ModuleName : $($_.Exception.Message)" -Color Red
        return $false
    }
}

function Remove-WorkDirectory {
    [CmdletBinding()]
    param()
    if (Test-Path -LiteralPath $script:WorkDir) {
        try {
            Remove-Item -LiteralPath $script:WorkDir -Recurse -Force -Confirm:$false -ErrorAction Stop
            Write-Step -Message "Limpeza: Arquivos temporários removidos." -Color Gray
        }
        catch {
            Write-Step -Message "Aviso: Não foi possível limpar a pasta temporária: $($_.Exception.Message)" -Color Yellow
        }
    }
}

# --- Execução Principal ---

function Start-Provision {
    [CmdletBinding()]
    param()

    $transcriptStarted = $false
    try {
        $logDir = Split-Path -Path $LogPath -Parent
        if ($logDir -and -not (Test-Path -LiteralPath $logDir)) {
            $null = New-Item -Path $logDir -ItemType Directory -Force
        }
        Start-Transcript -Path $LogPath -Append -ErrorAction Stop | Out-Null
        $transcriptStarted = $true
    }
    catch {
        Write-Step -Message "Aviso: não foi possível iniciar o log em '$LogPath': $($_.Exception.Message)" -Color Yellow
    }

    Write-Step -Message "============================================" -Color White
    Write-Step -Message "   ORQUESTRADOR DE PROVISIONAMENTO (ZERO-TOUCH)" -Color White
    Write-Step -Message "============================================" -Color White

    $overallSuccess = $true
    $failedModule   = $null
    $exitCode       = 0

    try {
        Initialize-WorkDirectory
        $moduleList = Resolve-ModuleList
        $total = $moduleList.Count

        for ($i = 0; $i -lt $total; $i++) {
            $mod          = $moduleList[$i]
            $moduleName   = $mod.Name
            $functionName = $mod.Function
            $stepNumber   = $i + 1

            try {
                Save-ModuleFiles -ModuleName $moduleName | Out-Null
                Import-ModuleFromTemp -ModuleName $moduleName
                Test-FunctionExists -FunctionName $functionName

                $success = Invoke-ModuleFunction -ModuleName $moduleName -FunctionName $functionName `
                    -StepNumber $stepNumber -TotalSteps $total

                if (-not $success) {
                    $overallSuccess = $false
                    $failedModule   = $moduleName
                    break
                }
            }
            catch {
                Write-Step -Message "[FALHA CRÍTICA] Módulo $moduleName : $($_.Exception.Message)" -Color Red
                $overallSuccess = $false
                $failedModule   = $moduleName
                break
            }
        }
    }
    catch {
        Write-Step -Message "[FALHA CRÍTICA] Erro na inicialização do orquestrador: $($_.Exception.Message)" -Color Red
        $overallSuccess = $false
        $failedModule   = "<inicialização>"
    }
    finally {
        Write-Step -Message "============================================" -Color White
        Remove-WorkDirectory
    }

    if ($overallSuccess) {
        Write-Step -Message "Provisionamento concluído com sucesso." -Color Green
        Write-Step -Message "============================================" -Color White
        $exitCode = 0
    }
    else {
        Write-Step -Message "Orquestrador interrompido devido a falhas." -Color Red
        Write-Step -Message "Módulo com falha: $failedModule" -Color Red
        Write-Step -Message "============================================" -Color White
        $exitCode = 1
    }

    if ($transcriptStarted) {
        try { Stop-Transcript | Out-Null } catch { }
    }

    exit $exitCode
}

# Inicia a execução imediatamente.
$script:ExplicitModules = $Modules
Start-Provision
