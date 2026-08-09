#Requires -Version 5.1
<#
.SYNOPSIS
    WinProvision Orchestrator - Interface Amigável e Minimalista no Estilo Windows 11.
#>
[CmdletBinding()]
param(
    [string]$LogFile = "C:\ProgramData\WinProvision\Logs\WinProvision_Orchestrator.log"
)

# ============================
# 0. AUTO-ELEVAÇÃO DE PRIVILÉGIOS
# ============================
$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $IsAdmin) {
    $ScriptPath = if ($PSCommandPath) { $PSCommandPath } elseif ($MyInvocation.MyCommand.Path) { $MyInvocation.MyCommand.Path } else { $null }
    if ($ScriptPath) {
        $ArgList = "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`""
        if ($PSBoundParameters.ContainsKey('LogFile')) { $ArgList += " -LogFile `"$LogFile`"" }
        Start-Process powershell.exe -ArgumentList $ArgList -Verb RunAs
        exit 0
    }
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

# ============================
# 1. APIs WIN32 (Shell + Keep-Alive)
# ============================
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public class WinShell {
    [DllImport("user32.dll")] public static extern IntPtr FindWindow(string cls, string win);
    [DllImport("user32.dll")] public static extern IntPtr FindWindowEx(IntPtr parent, IntPtr childAfter, string className, string windowName);
    [DllImport("user32.dll")] public static extern int ShowWindow(IntPtr hWnd, int cmd);
    [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();

    public static void HideShell() {
        IntPtr tray  = FindWindow("Shell_TrayWnd", null);
        IntPtr start = FindWindow("DV2ControlHost", null);
        if (tray  != IntPtr.Zero) ShowWindow(tray,  0);
        if (start != IntPtr.Zero) ShowWindow(start, 0);

        IntPtr secTray = IntPtr.Zero;
        while ((secTray = FindWindowEx(IntPtr.Zero, secTray, "Shell_SecondaryTrayWnd", null)) != IntPtr.Zero) {
            ShowWindow(secTray, 0);
        }
    }

    public static void ShowShell() {
        IntPtr tray  = FindWindow("Shell_TrayWnd", null);
        IntPtr start = FindWindow("DV2ControlHost", null);
        if (tray  != IntPtr.Zero) ShowWindow(tray,  5);
        if (start != IntPtr.Zero) ShowWindow(start, 5);

        IntPtr secTray = IntPtr.Zero;
        while ((secTray = FindWindowEx(IntPtr.Zero, secTray, "Shell_SecondaryTrayWnd", null)) != IntPtr.Zero) {
            ShowWindow(secTray, 5);
        }
    }

    public static void HideConsole() {
        IntPtr con = GetConsoleWindow();
        if (con != IntPtr.Zero) ShowWindow(con, 0);
    }
}

public class WinPower {
    [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    public static extern uint SetThreadExecutionState(uint esFlags);

    public const uint ES_SYSTEM_REQUIRED  = 0x00000001;
    public const uint ES_DISPLAY_REQUIRED = 0x00000002;
    public const uint ES_CONTINUOUS       = 0x80000000;

    public static void PreventSleep() {
        SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED | ES_DISPLAY_REQUIRED);
    }

    public static void AllowSleep() {
        SetThreadExecutionState(ES_CONTINUOUS);
    }
}
"@

# Impede suspensão e desligamento de tela durante o processo
[WinPower]::PreventSleep()

# ============================
# 2. CONFIGURAÇÃO DAS TAREFAS
# ============================
$MaxRetries    = 3
$RetryDelaySec = 5

$Tasks = @(
    @{Name='Wallpaper'; DisplayName='Personalização do Sistema'; Url='https://raw.githubusercontent.com/GabrielSilvaTI/WinProvision/refs/heads/main/scripts/modules/Wallpaper.ps1'},
    @{Name='Bootstrap'; DisplayName='Softwares Essenciais';      Url='https://raw.githubusercontent.com/GabrielSilvaTI/WinProvision/refs/heads/main/scripts/modules/Bootstrap.ps1'},
    @{Name='Office';    DisplayName='Pacote Microsoft Office';   Url='https://raw.githubusercontent.com/GabrielSilvaTI/WinProvision/refs/heads/main/scripts/modules/office.ps1'},
    @{Name='MAS';       DisplayName='Ativação e Recursos';       Url='https://raw.githubusercontent.com/GabrielSilvaTI/WinProvision/refs/heads/main/scripts/modules/Ohook.ps1'}
)

# Estado compartilhado thread-safe
$Sync = [hashtable]::Synchronized(@{
    Status   = @{}
    Finished = $false
    HasError = $false
})
foreach ($t in $Tasks) { $Sync.Status[$t.Name] = 'Aguardando' }

# ============================
# 3. INTERFACE GRÁFICA (FLUENT DESIGN WIN 11)
# ============================
[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="WinProvision Orchestrator" Height="640" Width="780"
        WindowStartupLocation="CenterScreen" WindowState="Maximized"
        WindowStyle="None" ResizeMode="NoResize"
        Topmost="True" Background="#1C1C1C" FontFamily="Segoe UI Variable Display, Segoe UI">
    <Window.Resources>
        <Style TargetType="{x:Type ScrollBar}">
            <Setter Property="Stylus.IsFlicksEnabled" Value="false"/>
            <Setter Property="Foreground" Value="#404040"/>
            <Setter Property="Background" Value="#1C1C1C"/>
            <Setter Property="Width" Value="6"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="{x:Type ScrollBar}">
                        <Grid x:Name="Bg" Background="#1C1C1C">
                            <Track x:Name="PART_Track" IsDirectionReversed="true">
                                <Track.Thumb>
                                    <Thumb x:Name="Thumb" Background="#404040"/>
                                </Track.Thumb>
                            </Track>
                        </Grid>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="TaskCard" TargetType="Border">
            <Setter Property="Background" Value="#262626"/>
            <Setter Property="BorderBrush" Value="#2D2D2D"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="CornerRadius" Value="8"/>
            <Setter Property="Padding" Value="16,14"/>
            <Setter Property="Margin" Value="0,0,0,8"/>
        </Style>

        <Style x:Key="FlatButton" TargetType="Button">
            <Setter Property="Background" Value="#2D2D2D"/>
            <Setter Property="Foreground" Value="#CCCCCC"/>
            <Setter Property="BorderBrush" Value="#383838"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="10,4"/>
            <Setter Property="FontSize" Value="11.5"/>
            <Setter Property="Cursor" Value="Hand"/>
        </Style>

        <!-- Botão Fechar: mesma cor do fundo (sem bloco visivel), so o texto se destaca -->
        <!-- Template proprio evita que o WPF aplique chrome/cinza padrao em qualquer estado -->
        <Style x:Key="CloseButtonStyle" TargetType="Button">
            <Setter Property="Background" Value="#1C1C1C"/>
            <Setter Property="Foreground" Value="#CCCCCC"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="Bd" Background="{TemplateBinding Background}" CornerRadius="2">
                            <ContentPresenter x:Name="Cp" HorizontalAlignment="Center" VerticalAlignment="Center" TextElement.Foreground="{TemplateBinding Foreground}"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Cp" Property="TextElement.Foreground" Value="#FFFFFF"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Barra de progresso fina com template explicito: sem isso, o preenchimento -->
        <!-- (Indicator) nao aparece corretamente fora de uma janela com tema padrao -->
        <Style x:Key="ThinProgressBar" TargetType="ProgressBar">
            <Setter Property="Foreground" Value="#3898EC"/>
            <Setter Property="Background" Value="#2A2A2A"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ProgressBar">
                        <Grid x:Name="TemplateRoot">
                            <Border Background="{TemplateBinding Background}" CornerRadius="2"/>
                            <Grid x:Name="PART_Track" ClipToBounds="True">
                                <Rectangle x:Name="PART_Indicator" Fill="{TemplateBinding Foreground}"
                                           HorizontalAlignment="Left" RadiusX="2" RadiusY="2"/>
                            </Grid>
                        </Grid>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
    </Window.Resources>

    <Grid>
        <Grid.RowDefinitions>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <ScrollViewer Grid.Row="0" VerticalScrollBarVisibility="Auto">
            <Border MaxWidth="620" Padding="20,45,20,20" HorizontalAlignment="Center">
                <Grid>
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                    </Grid.RowDefinitions>

                    <!-- CABEÇALHO FIEL À IMAGEM DE REFERÊNCIA -->
                    <StackPanel Grid.Row="0" Margin="0,0,0,14">
                        <TextBlock FontSize="26" Margin="0,0,0,8">
                            <Run Text="WinProvision" Foreground="#FFFFFF" FontWeight="Bold"/>
                            <Run Text=" Orchestrator" Foreground="#3898EC" FontWeight="Normal"/>
                        </TextBlock>
                        <TextBlock Text="Configurando seu computador" FontSize="22" FontWeight="Bold" Foreground="#FFFFFF"/>
                        <TextBlock Name="SubtitleText" Text="Estamos preparando o ambiente de trabalho. Isso pode levar alguns minutos." FontSize="13" Foreground="#9E9E9E" Margin="0,3,0,0"/>
                    </StackPanel>

                    <!-- BARRA DE CARREGAMENTO ULTRA FINA (STYLE MATCH) -->
                    <ProgressBar Name="ProgressBarMain" Grid.Row="1" Style="{StaticResource ThinProgressBar}"
                                 Height="3" Minimum="0" Maximum="100" Margin="0,0,0,22" HorizontalAlignment="Stretch"/>

                    <!-- LISTA DE TAREFAS -->
                    <ItemsControl Name="TaskList" Grid.Row="2" Background="Transparent">
                        <ItemsControl.ItemTemplate>
                            <DataTemplate>
                                <Border Style="{StaticResource TaskCard}">
                                    <Grid>
                                        <Grid.ColumnDefinitions>
                                            <ColumnDefinition Width="Auto"/>
                                            <ColumnDefinition Width="*"/>
                                            <ColumnDefinition Width="Auto"/>
                                        </Grid.ColumnDefinitions>

                                        <!-- Ícone do Status (Segoe MDL2 Assets) -->
                                        <TextBlock Grid.Column="0" Text="{Binding StatusIcon}" FontFamily="Segoe MDL2 Assets"
                                                   Foreground="{Binding StatusColor}" FontSize="15" VerticalAlignment="Center" Margin="0,0,14,0"/>

                                        <TextBlock Grid.Column="1" Text="{Binding DisplayName}" Foreground="#FFFFFF"
                                                   FontSize="13.5" FontWeight="Normal" VerticalAlignment="Center"/>

                                        <TextBlock Grid.Column="2" Text="{Binding StatusText}" Foreground="{Binding StatusColor}"
                                                   FontSize="12.5" FontWeight="Normal" VerticalAlignment="Center"/>
                                    </Grid>
                                </Border>
                            </DataTemplate>
                        </ItemsControl.ItemTemplate>
                    </ItemsControl>

                    <!-- SEÇÃO "DETALHES" (Exibida APENAS em caso de ERRO) -->
                    <Border Name="DetailsContainer" Grid.Row="3" Style="{StaticResource TaskCard}" Margin="0,12,0,0" Padding="0" Visibility="Collapsed">
                        <Grid>
                            <Grid.RowDefinitions>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="*"/>
                            </Grid.RowDefinitions>

                            <Grid Grid.Row="0" Margin="14,10,14,6">
                                <TextBlock Text="Detalhes da ocorrência" Foreground="#FF99A4" FontWeight="SemiBold" FontSize="12"/>
                                <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
                                    <Button Name="BtnCopyLog" Content="Copiar" Style="{StaticResource FlatButton}" Margin="0,0,6,0"/>
                                    <Button Name="BtnOpenLog" Content="Abrir Pasta" Style="{StaticResource FlatButton}"/>
                                </StackPanel>
                            </Grid>

                            <ScrollViewer Name="LogScroll" Grid.Row="1" Height="150" VerticalScrollBarVisibility="Auto" Margin="0,0,0,8">
                                <TextBox Name="LogBox" Background="Transparent" Foreground="#CCCCCC" BorderThickness="0"
                                         FontFamily="Consolas" FontSize="11.5" TextWrapping="Wrap" IsReadOnly="True"
                                         Margin="14,4,14,6"/>
                            </ScrollViewer>
                        </Grid>
                    </Border>
                </Grid>
            </Border>
        </ScrollViewer>

        <!-- RODAPÉ E BOTÃO FECHAR -->
        <Border Grid.Row="1" Background="#1C1C1C" BorderBrush="#262626" BorderThickness="0,1,0,0" Padding="24,14">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBlock Name="FooterStatusText" Grid.Column="0" Text="Por favor, mantenha o computador ligado..." Foreground="#707070" FontSize="12.5" VerticalAlignment="Center"/>

                <Button Name="CloseButton" Grid.Column="1" Content="Fechar" Width="85" Height="30"
                        Style="{StaticResource CloseButtonStyle}" FontSize="12" FontWeight="Normal" IsEnabled="True"/>
            </Grid>
        </Border>
    </Grid>
</Window>
"@

$reader           = New-Object System.Xml.XmlNodeReader $xaml
$window           = [Windows.Markup.XamlReader]::Load($reader)
$TaskList         = $window.FindName('TaskList')
$LogBox           = $window.FindName('LogBox')
$LogScroll        = $window.FindName('LogScroll')
$ProgressBar      = $window.FindName('ProgressBarMain')
$CloseButton      = $window.FindName('CloseButton')
$BtnCopyLog       = $window.FindName('BtnCopyLog')
$BtnOpenLog       = $window.FindName('BtnOpenLog')
$FooterStatus     = $window.FindName('FooterStatusText')
$SubtitleText     = $window.FindName('SubtitleText')
$DetailsContainer = $window.FindName('DetailsContainer')

# ============================
# MAPEAMENTO DE ESTADOS E ÍCONES
# ============================
function Get-StatusColor([string]$status) {
    switch ($status) {
        'OK'         { '#6CCB5F' } # Verde Fluent
        'FALHA'      { '#FF99A4' } # Vermelho Suave
        'Executando' { '#3898EC' } # Azul Accent
        default      { '#808080' } # Cinza Neutro
    }
}

function Get-StatusIcon([string]$status) {
    switch ($status) {
        'OK'         { [char]0xE73E } # Checkmark
        'FALHA'      { [char]0xEA39 } # Erro X
        'Executando' { [char]0xE72C } # Sync / Processando
        default      { [char]0xE916 } # Relogio / Aguardando
    }
}

function Get-StatusText([string]$status) {
    switch ($status) {
        'OK'         { 'Concluído' }
        'FALHA'      { 'Não foi possível concluir' }
        'Executando' { 'Configurando...' }
        default      { 'Na fila' }
    }
}

# ============================
# VIEWMODEL BINDING
# ============================
$TaskItems = New-Object System.Collections.ObjectModel.ObservableCollection[Object]
foreach ($t in $Tasks) {
    $TaskItems.Add([PSCustomObject]@{
        Name        = $t.Name
        DisplayName = $t.DisplayName
        Status      = 'Aguardando'
        StatusText  = (Get-StatusText 'Aguardando')
        StatusIcon  = (Get-StatusIcon 'Aguardando')
        StatusColor = (Get-StatusColor 'Aguardando')
    })
}
$TaskList.ItemsSource = $TaskItems

# ============================
# WORKER RUNSPACE
# ============================
$runspace = [runspacefactory]::CreateRunspace()
$runspace.ApartmentState = 'MTA'
$runspace.Open()
$runspace.SessionStateProxy.SetVariable('Sync', $Sync)
$runspace.SessionStateProxy.SetVariable('Tasks', $Tasks)
$runspace.SessionStateProxy.SetVariable('LogFile', $LogFile)
$runspace.SessionStateProxy.SetVariable('MaxRetries', $MaxRetries)
$runspace.SessionStateProxy.SetVariable('RetryDelaySec', $RetryDelaySec)

$ps = [powershell]::Create()
$ps.Runspace = $runspace

[void]$ps.AddScript({
    function Write-Log {
        param([string]$Message, [ValidateSet('INFO','WARN','ERROR')][string]$Level = 'INFO')
        $entry = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')][$Level] $Message"
        try { $entry | Out-File -FilePath $LogFile -Append -Encoding UTF8 }
        catch { Write-Error "Falha ao gravar log: $($_.Exception.Message)" -ErrorAction Continue }
    }

    function Set-TaskState {
        [CmdletBinding(SupportsShouldProcess)]
        param([string]$Name, [string]$Status)
        if (-not $PSCmdlet.ShouldProcess($Name, "Definir status para $Status")) { return }
        [System.Threading.Monitor]::Enter($Sync)
        try {
            $Sync.Status[$Name] = $Status
            if ($Status -eq 'FALHA') { $Sync.HasError = $true }
        }
        finally { [System.Threading.Monitor]::Exit($Sync) }
    }

    function Invoke-Module {
        param([string]$Name, [string]$Url)
        $attempt = 0
        while ($attempt -lt $MaxRetries) {
            $attempt++
            Write-Log -Message "Iniciando modulo '$Name'..."
            Set-TaskState -Name $Name -Status 'Executando'
            try {
                $tempScript = Join-Path -Path $env:TEMP -ChildPath ("WinProvision_" + $Name + ".ps1")
                $content = Invoke-RestMethod -Uri $Url -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
                $content | Out-File -FilePath $tempScript -Encoding UTF8 -Force

                # O modulo filho recebe o MESMO LogFile do orquestrador e reporta seu
                # proprio percentual de progresso via linhas "[PROGRESS] NN% - ...",
                # que a UI le em tempo real para calcular a barra de progresso geral.
                $proc = Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -NonInteractive -File `"$tempScript`" -LogPath `"$LogFile`"" -WindowStyle Hidden -Wait -PassThru

                Remove-Item $tempScript -Force -ErrorAction SilentlyContinue

                if ($proc.ExitCode -eq 0) {
                    Write-Log -Message "Modulo '$Name' concluido com sucesso."
                    Set-TaskState -Name $Name -Status 'OK'
                    return $true
                } else {
                    Write-Log -Level 'ERROR' -Message "Modulo '$Name' retornou erro (ExitCode: $($proc.ExitCode))"
                }
            } catch {
                Write-Log -Level 'ERROR' -Message "Erro ao executar '$Name': $($_.Exception.Message)"
            }

            if ($attempt -lt $MaxRetries) {
                Start-Sleep -Seconds $RetryDelaySec
            }
        }
        Set-TaskState -Name $Name -Status 'FALHA'
        return $false
    }

    $logDir = Split-Path $LogFile -Parent
    if (-not (Test-Path $logDir)) { New-Item $logDir -ItemType Directory -Force | Out-Null }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13

    foreach ($task in $Tasks) {
        [void](Invoke-Module -Name $task.Name -Url $task.Url)
    }

    [System.Threading.Monitor]::Enter($Sync)
    try { $Sync.Finished = $true } finally { [System.Threading.Monitor]::Exit($Sync) }
})

# ============================
# TIMER DA UI, PROGRESSO REAL & DETALHES
# ============================
$script:LastLogPosition     = 0   # cursor de leitura para o LogBox (dump completo ao exibir detalhes)
$script:LastProgressPosition = 0  # cursor de leitura dedicado ao parsing continuo de progresso
$script:CurrentChildPercent  = 0  # ultimo percentual reportado pelo modulo filho em execucao

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(250)

$timer.Add_Tick({
    [System.Threading.Monitor]::Enter($Sync)
    try {
        $hasError = $Sync.HasError
        $finished = $Sync.Finished

        foreach ($item in $TaskItems) {
            $st = $Sync.Status[$item.Name]
            if ($item.Status -ne $st) {
                # Nova tarefa iniciando execucao: zera o percentual do modulo filho anterior
                if ($st -eq 'Executando') { $script:CurrentChildPercent = 0 }
                $item.Status      = $st
                $item.StatusText  = (Get-StatusText $st)
                $item.StatusIcon  = (Get-StatusIcon $st)
                $item.StatusColor = (Get-StatusColor $st)
            }
        }

        $completedCount = ($TaskItems | Where-Object { $_.Status -in @('OK','FALHA') }).Count
    } finally {
        [System.Threading.Monitor]::Exit($Sync)
    }
    $TaskList.Items.Refresh()

    # ---- PROGRESSO REAL: le as linhas [PROGRESS] mais recentes reportadas pelo modulo filho ----
    if (Test-Path $LogFile) {
        try {
            $pStream = [System.IO.File]::Open($LogFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            if ($pStream.Length -gt $script:LastProgressPosition) {
                $pStream.Position = $script:LastProgressPosition
                $pReader = New-Object System.IO.StreamReader($pStream, [System.Text.Encoding]::UTF8)
                $progressChunk = $pReader.ReadToEnd()
                $script:LastProgressPosition = $pStream.Position

                $progressMatches = [regex]::Matches($progressChunk, '\[PROGRESS\]\s*(\d{1,3})%')
                if ($progressMatches.Count -gt 0) {
                    $script:CurrentChildPercent = [int]$progressMatches[$progressMatches.Count - 1].Groups[1].Value
                }
            }
            $pStream.Close()
        } catch { Write-Error "Falha ao ler progresso: $($_.Exception.Message)" -ErrorAction Continue }
    }

    # Progresso geral = tarefas ja concluidas (peso igual entre modulos) + fracao do modulo atual
    $weight  = 100 / $Tasks.Count
    $overall = [math]::Min(100, [int](($completedCount * $weight) + (($script:CurrentChildPercent / 100) * $weight)))
    $ProgressBar.Value = $overall

    # EXIBE A SEÇÃO "DETALHES" APENAS EM CASO DE ERRO
    if ($hasError -and $DetailsContainer.Visibility -eq 'Collapsed') {
        $DetailsContainer.Visibility = [System.Windows.Visibility]::Visible
    }

    if ($DetailsContainer.Visibility -eq 'Visible' -and (Test-Path $LogFile)) {
        try {
            $stream = [System.IO.File]::Open($LogFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            if ($stream.Length -gt $script:LastLogPosition) {
                $stream.Position = $script:LastLogPosition
                $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8)
                $newContent = $reader.ReadToEnd()
                $script:LastLogPosition = $stream.Position
                if (-not [string]::IsNullOrWhiteSpace($newContent)) {
                    $LogBox.AppendText($newContent)
                    $LogScroll.ScrollToEnd()
                }
            }
            $stream.Close()
        } catch { Write-Error "Falha ao ler log de detalhes: $($_.Exception.Message)" -ErrorAction Continue }
    }

    # FINALIZAÇÃO
    if ($finished -and -not $script:FinishedHandled) {
        $script:FinishedHandled = $true
        $ProgressBar.Value = 100

        if (-not $hasError) {
            $SubtitleText.Text = 'Tudo pronto! Seu computador foi configurado com sucesso.'
            $FooterStatus.Text = 'Configuração concluída.'
            $FooterStatus.Foreground = '#6CCB5F'

            $script:AutoCloseSeconds = 10
            $script:CountdownTimer = New-Object System.Windows.Threading.DispatcherTimer
            $script:CountdownTimer.Interval = [TimeSpan]::FromSeconds(1)
            $script:CountdownTimer.Add_Tick({
                $script:AutoCloseSeconds--
                if ($script:AutoCloseSeconds -le 0) {
                    $script:CountdownTimer.Stop()
                    $window.Close()
                } else {
                    $FooterStatus.Text = "Concluído. Fechando automaticamente em $($script:AutoCloseSeconds)s..."
                }
            })
            $script:CountdownTimer.Start()
        } else {
            $SubtitleText.Text = 'A configuração foi concluída com observações.'
            $FooterStatus.Text = 'Verifique os detalhes acima para mais informações.'
            $FooterStatus.Foreground = '#FF99A4'
        }
    }
})

# ============================
# EVENTOS
# ============================
$CloseButton.Add_Click({ $window.Close() })

$BtnCopyLog.Add_Click({
    if (-not [string]::IsNullOrEmpty($LogBox.Text)) {
        [System.Windows.Clipboard]::SetText($LogBox.Text)
        $FooterStatus.Text = "Detalhes copiados para a área de transferência."
    }
})

$BtnOpenLog.Add_Click({
    $logDir = Split-Path $LogFile -Parent
    if (Test-Path $logDir) {
        Start-Process explorer.exe -ArgumentList "`"$logDir`""
    }
})

$window.Add_Loaded({
    [WinShell]::HideConsole()
    [WinShell]::HideShell()
    $window.Activate()
    $ps.BeginInvoke() | Out-Null
    $timer.Start()
})

$window.Add_Closed({
    [WinShell]::ShowShell()
    [WinPower]::AllowSleep()
    $timer.Stop()
    if ($script:CountdownTimer) { $script:CountdownTimer.Stop() }
    try { $ps.Stop(); $ps.Dispose(); $runspace.Close() }
    catch { Write-Error "Falha ao finalizar runspace: $($_.Exception.Message)" -ErrorAction Continue }
})

# ============================
# EXECUÇÃO DA INTERFACE
# ============================
try {
    [void]$window.ShowDialog()
} finally {
    [WinShell]::ShowShell()
    [WinPower]::AllowSleep()
}
