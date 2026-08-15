#Requires -Version 7.0

<#
.SYNOPSIS
    Orchestrator autônomo para o provisionamento do Windows (Zero-Touch).
.DESCRIPTION
    Suprime qualquer prompt de confirmação, barras de progresso ou interações do usuário.
.NOTES
    Versão: 2.1 (Fully Automated)
#>

[CmdletBinding()]
param()

# --- Configurações de Automação Total (Zero Interatividade) ---
$ErrorActionPreference    = 'Stop'
$ProgressPreference       = 'SilentlyContinue' # Desativa barras de download/progresso que travam consoles sem UI
$ConfirmPreference        = 'None'             # Suprime qualquer confirmação do PowerShell
$InformationPreference    = 'Continue'

# --- Configurações Locais ---
$script:BaseUrl = "https://raw.githubusercontent.com/GabrielSilvaTI/WinProvision/refs/heads/main/m%C3%B3dulos/7%2B"
$script:WorkDir = Join-Path ($env:TEMP ?? "C:\Windows\Temp") "WinProvision\Modules"

$script:Modules = @(
    [pscustomobject]@{ Name = "Install-Winget";    Function = "Install-Winget" }
    [pscustomobject]@{ Name = "Install-Programas"; Function = "Install-Programas" }
    [pscustomobject]@{ Name = "Install-Office";    Function = "Install-Office" }
)

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
    if (Test-Path -Path $script:WorkDir) {
        Remove-Item -Path $script:WorkDir -Recurse -Force -ErrorAction SilentlyContinue -Confirm:$false
    }
    $null = New-Item -Path $script:WorkDir -ItemType Directory -Force
    Write-Step -Message "Diretório de trabalho inicializado em: $script:WorkDir" -Color Gray
}

function Download-ModuleFiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ModuleName
    )
    $moduleDir = Join-Path $script:WorkDir $ModuleName
    $null = New-Item -Path $moduleDir -ItemType Directory -Force

    $extensions = @("psd1", "psm1")
    foreach ($ext in $extensions) {
        $url  = "$($script:BaseUrl)/$ModuleName.$ext"
        $dest = Join-Path $moduleDir "$ModuleName.$ext"
        
        Write-Step -Message "Baixando: $ModuleName.$ext ..." -Color Gray
        
        try {
            Invoke-RestMethod -Uri $url -OutFile $dest -UserAgent "Mozilla/5.0 (Windows NT 10.0; Win64; x64)" -ErrorAction Stop
        }
        catch {
            Write-Step -Message "Falha ao baixar $ModuleName.$ext : $_" -Color Red
            throw
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

    if (-not (Test-Path -Path $psd1)) {
        throw "Arquivo de manifesto '$psd1' não foi encontrado."
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

        $isSuccess = $false
        if ($null -eq $result) {
            $isSuccess = $true
        }
        elseif ($result -is [bool]) {
            $isSuccess = $result
        }
        elseif ($result -is [hashtable] -and $result.ContainsKey('Success')) {
            $isSuccess = [bool]$result['Success']
        }
        elseif ($result -is [PSCustomObject] -and $result.PSObject.Properties['Success']) {
            $isSuccess = [bool]$result.Success
        }

        if ($isSuccess) {
            Write-Step -Message "[OK] $ModuleName finalizado com sucesso." -Color Green
            return $true
        }

        Write-Step -Message "[ERRO] $ModuleName retornou status de falha." -Color Red
        return $false
    }
    catch {
        Write-Step -Message "[EXCEÇÃO] Erro ao executar $ModuleName : $_" -Color Red
        return $false
    }
}

function Remove-WorkDirectory {
    if (Test-Path -Path $script:WorkDir) {
        try {
            Remove-Item -Path $script:WorkDir -Recurse -Force -Confirm:$false -ErrorAction Stop
            Write-Step -Message "Limpeza: Arquivos temporários removidos." -Color Gray
        }
        catch {
            Write-Step -Message "Aviso: Não foi possível limpar a pasta temporária: $_" -Color Yellow
        }
    }
}

# --- Execução Principal ---

function Start-Provision {
    Write-Step -Message "============================================" -Color White
    Write-Step -Message "   ORQUESTRADOR DE PROVISIONAMENTO (ZERO-TOUCH)" -Color White
    Write-Step -Message "============================================" -Color White

    $overallSuccess = $true
    $failedModule   = $null

    try {
        Initialize-WorkDirectory

        $total = $script:Modules.Count
        for ($i = 0; $i -lt $total; $i++) {
            $mod          = $script:Modules[$i]
            $moduleName   = $mod.Name
            $functionName = $mod.Function
            $stepNumber   = $i + 1

            try {
                Download-ModuleFiles -ModuleName $moduleName
                Import-ModuleFromTemp -ModuleName $moduleName
                Test-FunctionExists -FunctionName $functionName

                $success = Invoke-ModuleFunction -ModuleName $moduleName -FunctionName $functionName -StepNumber $stepNumber -TotalSteps $total

                if (-not $success) {
                    $overallSuccess = $false
                    $failedModule   = $moduleName
                    break
                }
            }
            catch {
                Write-Step -Message "[FALHA CRÍTICA] Módulo $moduleName : $_" -Color Red
                $overallSuccess = $false
                $failedModule   = $moduleName
                break
            }
        }
    }
    finally {
        Write-Step -Message "============================================" -Color White
        Remove-WorkDirectory
    }

    if ($overallSuccess) {
        Write-Step -Message "Provisionamento concluído com sucesso." -Color Green
        Write-Step -Message "============================================" -Color White
        [Environment]::Exit(0)
    }
    else {
        Write-Step -Message "Orquestrador interrompido devido a falhas." -Color Red
        Write-Step -Message "Módulo com falha: $failedModule" -Color Red
        Write-Step -Message "============================================" -Color White
        [Environment]::Exit(1)
    }
}

# Inicia a execução imediatamente e encerra o processo do shell ao concluir
Start-Provision
