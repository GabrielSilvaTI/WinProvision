#Requires -Version 5.1
<#
.SYNOPSIS
    WinProvision Orchestrator - Execucao automatica com devolutiva visual WPF.
#>
[CmdletBinding()]
param()

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

# ============================
# API Win32 - Controle da barra de tarefas
# ============================
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class WinShell {
    [DllImport("user32.dll")]   public static extern IntPtr FindWindow(string cls, string win);
    [DllImport("user32.dll")]   public static extern int    ShowWindow(IntPtr hWnd, int cmd);
    [DllImport("user32.dll")]   public static extern bool   SetForegroundWindow(IntPtr hWnd);
    [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();

    // Oculta a barra de tarefas e o botao Iniciar
    public static void HideShell() {
        IntPtr tray  = FindWindow("Shell_TrayWnd",  null);
        IntPtr start = FindWindow("DV2ControlHost", null);
        if (tray  != IntPtr.Zero) ShowWindow(tray,  0);
        if (start != IntPtr.Zero) ShowWindow(start, 0);
    }
    // Restaura a barra de tarefas e o botao Iniciar
    public static void ShowShell() {
        IntPtr tray  = FindWindow("Shell_TrayWnd",  null);
        IntPtr start = FindWindow("DV2ControlHost", null);
        if (tray  != IntPtr.Zero) ShowWindow(tray,  5);
        if (start != IntPtr.Zero) ShowWindow(start, 5);
    }
    // Oculta a janela do console PowerShell que executa este script
    public static void HideConsole() {
        IntPtr con = GetConsoleWindow();
        if (con != IntPtr.Zero) ShowWindow(con, 0);
    }
}
"@

# ============================
# Configuracoes
# ============================
$LogFile        = Join-Path -Path $env:SystemRoot -ChildPath 'Temp\WinProvision_Log.txt'
$MaxRetries     = 3
$RetryDelaySec  = 5

$Tasks = @(
    @{Name='Wallpaper'; Url='https://raw.githubusercontent.com/GabrielSilvaTI/WinProvision/refs/heads/main/scripts/modules/Wallpaper.ps1'},
    @{Name='Bootstrap'; Url='https://raw.githubusercontent.com/GabrielSilvaTI/WinProvision/refs/heads/main/scripts/modules/Bootstrap.ps1'},
    @{Name='Office';    Url='https://raw.githubusercontent.com/GabrielSilvaTI/WinProvision/refs/heads/main/scripts/modules/office.ps1'},
    @{Name='MAS';       Url='https://raw.githubusercontent.com/GabrielSilvaTI/WinProvision/refs/heads/main/scripts/modules/Ohook.ps1'}
)

# ============================
# Estado compartilhado thread-safe
# (a UI so LE este objeto via timer; o runspace de trabalho so ESCREVE nele)
# ============================
$Sync = [hashtable]::Synchronized(@{
    Log       = New-Object System.Collections.Generic.Queue[string]
    Status    = @{}
    Attempt   = @{}
    Progress  = 0
    Finished  = $false
})
foreach ($t in $Tasks) { $Sync.Status[$t.Name] = 'Aguardando'; $Sync.Attempt[$t.Name] = '-' }

# ============================
# XAML - Visual moderno (cards + badges)
# ============================
[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="WinProvision Orchestrator" Height="600" Width="820"
        WindowStartupLocation="CenterScreen" WindowState="Maximized"
        WindowStyle="None" ResizeMode="NoResize"
        Topmost="True" Background="#101418" FontFamily="Segoe UI">
    <Window.Resources>
        <Style x:Key="CardStyle" TargetType="Border">
            <Setter Property="Background" Value="#181D24"/>
            <Setter Property="CornerRadius" Value="10"/>
            <Setter Property="Padding" Value="16,12"/>
            <Setter Property="Margin" Value="0,0,0,8"/>
        </Style>
        <Style x:Key="BadgeStyle" TargetType="Border">
            <Setter Property="CornerRadius" Value="12"/>
            <Setter Property="Padding" Value="10,3"/>
        </Style>
    </Window.Resources>
    <Grid>
        <Grid.RowDefinitions>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <ScrollViewer Grid.Row="0" VerticalScrollBarVisibility="Auto">
            <Border MaxWidth="900" Padding="0,40,0,30" HorizontalAlignment="Center">
                <Grid>
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                    </Grid.RowDefinitions>

                    <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,2">
                        <TextBlock Text="WinProvision" FontSize="30" FontWeight="Bold" Foreground="White"/>
                        <TextBlock Text=" Orchestrator" FontSize="30" FontWeight="Light" Foreground="#5AA9E6"/>
                    </StackPanel>
                    <TextBlock Name="SubtitleText" Grid.Row="1" Text="Provisionamento automatico em andamento..." FontSize="13"
                                Foreground="#8A93A0" Margin="0,0,0,18"/>

                    <Border Grid.Row="2" Style="{StaticResource CardStyle}" Padding="0" Margin="0,0,0,16">
                        <ProgressBar Name="ProgressBarMain" Height="8" Minimum="0" Maximum="100"
                                      Foreground="#5AA9E6" Background="#222831" BorderThickness="0"/>
                    </Border>

                    <ItemsControl Name="TaskList" Grid.Row="3" Background="Transparent">
                        <ItemsControl.ItemTemplate>
                            <DataTemplate>
                                <Border Style="{StaticResource CardStyle}">
                                    <Grid>
                                        <Grid.ColumnDefinitions>
                                            <ColumnDefinition Width="*"/>
                                            <ColumnDefinition Width="Auto"/>
                                            <ColumnDefinition Width="Auto"/>
                                        </Grid.ColumnDefinitions>
                                        <TextBlock Grid.Column="0" Text="{Binding Task}" Foreground="White"
                                                    FontSize="14" VerticalAlignment="Center"/>
                                        <TextBlock Grid.Column="1" Text="{Binding AttemptText}" Foreground="#8A93A0"
                                                    FontSize="12" VerticalAlignment="Center" Margin="0,0,12,0"/>
                                        <Border Grid.Column="2" Style="{StaticResource BadgeStyle}" Background="{Binding StatusColor}">
                                            <TextBlock Text="{Binding Status}" Foreground="White" FontSize="12" FontWeight="SemiBold"/>
                                        </Border>
                                    </Grid>
                                </Border>
                            </DataTemplate>
                        </ItemsControl.ItemTemplate>
                    </ItemsControl>

                    <Border Grid.Row="4" Style="{StaticResource CardStyle}" Margin="0,12,0,0" Padding="0">
                        <Grid>
                            <Grid.RowDefinitions>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="*"/>
                            </Grid.RowDefinitions>
                            <TextBlock Grid.Row="0" Text="LOG" Foreground="#5AA9E6" FontWeight="Bold" FontSize="11"
                                        Margin="14,8,0,4"/>
                            <ScrollViewer Name="LogScroll" Grid.Row="1" Height="220" VerticalScrollBarVisibility="Auto" Margin="0,0,0,8">
                                <TextBox Name="LogBox" Background="Transparent" Foreground="#7CD992" BorderThickness="0"
                                          FontFamily="Consolas" FontSize="11.5" TextWrapping="Wrap" IsReadOnly="True"
                                          Margin="14,0,14,0"/>
                            </ScrollViewer>
                        </Grid>
                    </Border>
                </Grid>
            </Border>
        </ScrollViewer>

        <Border Grid.Row="1" Background="#181D24" BorderBrush="#262C35" BorderThickness="0,1,0,0" Padding="30,14">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBlock Name="FooterStatusText" Grid.Column="0" Text="Executando modulos de provisionamento, aguarde..."
                            Foreground="#8A93A0" FontSize="12.5" VerticalAlignment="Center"/>
                <Button Name="CloseButton" Grid.Column="1" Content="Fechar" Width="120" Height="34"
                         Background="#2A313C" Foreground="White" BorderThickness="0" FontSize="13"/>
            </Grid>
        </Border>
    </Grid>
</Window>
"@

$reader          = New-Object System.Xml.XmlNodeReader $xaml
$window          = [Windows.Markup.XamlReader]::Load($reader)
$TaskList        = $window.FindName('TaskList')
$LogBox          = $window.FindName('LogBox')
$LogScroll       = $window.FindName('LogScroll')
$ProgressBar     = $window.FindName('ProgressBarMain')
$CloseButton     = $window.FindName('CloseButton')
$FooterStatus    = $window.FindName('FooterStatusText')
$SubtitleText    = $window.FindName('SubtitleText')

# ============================
# Cores por status
# ============================
function Get-StatusColor([string]$status) {
    switch ($status) {
        'OK'               { '#2E7D32' }
        'FALHA'            { '#C62828' }
        'Executando'       { '#1565C0' }
        'Aguardando retry' { '#F9A825' }
        default            { '#37414F' }
    }
}

# ============================
# ViewModel ligado a UI (so o thread da UI mexe aqui)
# ============================
$TaskItems = New-Object System.Collections.ObjectModel.ObservableCollection[Object]
foreach ($t in $Tasks) {
    $TaskItems.Add([PSCustomObject]@{
        Task        = $t.Name
        Status      = 'Aguardando'
        AttemptText = ''
        StatusColor = (Get-StatusColor 'Aguardando')
    })
}
$TaskList.ItemsSource = $TaskItems

# ============================
# Runspace de trabalho - so ESCREVE no $Sync, nunca toca a UI
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
        $entry = "[$(Get-Date -Format 'dd/MM/yyyy HH:mm:ss')][$Level] $Message"
        try { $entry | Out-File -FilePath $LogFile -Append -Encoding UTF8 } catch {}
        [System.Threading.Monitor]::Enter($Sync)
        try { $Sync.Log.Enqueue($entry) } finally { [System.Threading.Monitor]::Exit($Sync) }
    }
    function Set-TaskState {
        param([string]$Name, [string]$Status, [string]$Attempt)
        [System.Threading.Monitor]::Enter($Sync)
        try { $Sync.Status[$Name] = $Status; $Sync.Attempt[$Name] = $Attempt }
        finally { [System.Threading.Monitor]::Exit($Sync) }
    }
    function Invoke-Module {
        param([string]$Name, [string]$Url)
        $attempt = 0
        while ($attempt -lt $MaxRetries) {
            $attempt++
            Write-Log -Message "Iniciando modulo '$Name' (Tentativa $attempt)..."
            Set-TaskState -Name $Name -Status 'Executando' -Attempt $attempt
            try {
                $tempScript = [System.IO.Path]::GetTempFileName() + ".ps1"
                $content = Invoke-RestMethod -Uri $Url -UseBasicParsing -ErrorAction Stop
                $content | Out-File -FilePath $tempScript -Encoding UTF8
                $proc = Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -NonInteractive -File `"$tempScript`"" -WindowStyle Hidden -Wait -PassThru
                Remove-Item $tempScript -Force -ErrorAction SilentlyContinue
                if ($proc.ExitCode -eq 0) {
                    Write-Log -Message "Modulo '$Name' concluido com sucesso."
                    Set-TaskState -Name $Name -Status 'OK' -Attempt $attempt
                    return $true
                } else {
                    Write-Log -Level 'ERROR' -Message "Modulo '$Name' falhou com ExitCode: $($proc.ExitCode)"
                }
            } catch {
                Write-Log -Level 'ERROR' -Message "Erro ao processar '$Name': $($_.Exception.Message)"
            }
            if ($attempt -lt $MaxRetries) {
                Set-TaskState -Name $Name -Status 'Aguardando retry' -Attempt $attempt
                Start-Sleep -Seconds $RetryDelaySec
            }
        }
        Set-TaskState -Name $Name -Status 'FALHA' -Attempt $attempt
        return $false
    }

    $logDir = Split-Path $LogFile -Parent
    if (-not (Test-Path $logDir)) { New-Item $logDir -ItemType Directory -Force | Out-Null }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    $results = @()
    $total = $Tasks.Count
    $i = 0
    foreach ($task in $Tasks) {
        $status = Invoke-Module -Name $task.Name -Url $task.Url
        $results += [PSCustomObject]@{ Task = $task.Name; Success = $status }
        $i++
        [System.Threading.Monitor]::Enter($Sync)
        try { $Sync.Progress = [int](($i / $total) * 100) } finally { [System.Threading.Monitor]::Exit($Sync) }
    }

    Write-Log -Message "=== Resumo do Provisionamento ==="
    foreach ($r in $results) {
        $txt = if ($r.Success) { 'OK' } else { 'FALHA' }
        Write-Log -Message "$($r.Task): $txt" -Level $(if ($r.Success) { 'INFO' } else { 'ERROR' })
    }

    [System.Threading.Monitor]::Enter($Sync)
    try { $Sync.Finished = $true } finally { [System.Threading.Monitor]::Exit($Sync) }
})

# ============================
# Timer de UI - LE o $Sync e atualiza a tela (unico ponto que toca a UI)
# ============================
$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(200)

$timer.Add_Tick({
    [System.Threading.Monitor]::Enter($Sync)
    try {
        while ($Sync.Log.Count -gt 0) {
            $LogBox.AppendText($Sync.Log.Dequeue() + "`r`n")
        }
        foreach ($item in $TaskItems) {
            $st  = $Sync.Status[$item.Task]
            $att = $Sync.Attempt[$item.Task]
            if ($item.Status -ne $st) {
                $item.Status      = $st
                $item.StatusColor = (Get-StatusColor $st)
            }
            $item.AttemptText = if ($att -ne '-') { "tentativa $att" } else { '' }
        }
        $ProgressBar.Value = $Sync.Progress
        $finished = $Sync.Finished
    } finally {
        [System.Threading.Monitor]::Exit($Sync)
    }
    $TaskList.Items.Refresh()
    $LogScroll.ScrollToEnd()

    if ($finished -and -not $script:FinishedHandled) {
        $script:FinishedHandled = $true
        $allOk = ($TaskItems | Where-Object { $_.Status -ne 'OK' }).Count -eq 0
        if ($allOk) {
            $SubtitleText.Text = 'Provisionamento concluido com sucesso.'
            $FooterStatus.Foreground = '#7CD992'
        } else {
            $SubtitleText.Text = 'Provisionamento concluido com falhas. Verifique o log.'
            $FooterStatus.Foreground = '#E0846F'
        }
        $script:AutoCloseSeconds = 15
        $FooterStatus.Text = "Concluido. Fechando automaticamente em $($script:AutoCloseSeconds)s..."
        $script:CountdownTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:CountdownTimer.Interval = [TimeSpan]::FromSeconds(1)
        $script:CountdownTimer.Add_Tick({
            $script:AutoCloseSeconds--
            if ($script:AutoCloseSeconds -le 0) {
                $script:CountdownTimer.Stop()
                $window.Close()
            } else {
                $FooterStatus.Text = "Concluido. Fechando automaticamente em $($script:AutoCloseSeconds)s..."
            }
        })
        $script:CountdownTimer.Start()
    }
})

# ============================
# Inicio automatico ao carregar a janela
# ============================
$CloseButton.Add_Click({ $window.Close() })

$window.Add_Loaded({
    [WinShell]::HideConsole()
    [WinShell]::HideShell()
    $window.Activate()
    $ps.BeginInvoke() | Out-Null
    $timer.Start()
})
$window.Add_Closed({
    [WinShell]::ShowShell()
    $timer.Stop()
    if ($script:CountdownTimer) { $script:CountdownTimer.Stop() }
    try { $ps.Stop(); $ps.Dispose(); $runspace.Close() } catch {}
})

[void]$window.ShowDialog()
