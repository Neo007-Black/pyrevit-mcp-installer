# Window for the pyRevit MCP installer. Start it with Install.bat.
# -NoSplash skips the opening animation and sound.
# -Screenshot and -SplashAt are developer options: draw the window (or the splash after N seconds) to a PNG and exit.
param([switch]$Uninstall, [switch]$NoSplash, [string]$Screenshot, [double]$SplashAt = 0, [switch]$Existing)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
. (Join-Path $PSScriptRoot 'lib\Core.ps1')

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="pyRevit MCP Installer" Width="760" Height="720" MinWidth="680" MinHeight="600"
        WindowStartupLocation="CenterScreen" Background="#F5F6F8" FontFamily="Segoe UI" FontSize="13">
  <Window.Resources>
    <Style TargetType="Button">
      <Setter Property="Padding" Value="18,8"/><Setter Property="Margin" Value="8,0,0,0"/><Setter Property="MinWidth" Value="100"/>
    </Style>
    <Style TargetType="CheckBox">
      <Setter Property="Margin" Value="0,4"/><Setter Property="VerticalContentAlignment" Value="Center"/>
    </Style>
    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="White"/><Setter Property="BorderBrush" Value="#DDE1E7"/>
      <Setter Property="BorderThickness" Value="1"/><Setter Property="CornerRadius" Value="8"/>
      <Setter Property="Padding" Value="16,12"/><Setter Property="Margin" Value="0,0,0,12"/>
    </Style>
    <Style x:Key="Head" TargetType="TextBlock">
      <Setter Property="FontWeight" Value="SemiBold"/><Setter Property="FontSize" Value="15"/><Setter Property="Margin" Value="0,0,0,6"/>
    </Style>
  </Window.Resources>
  <Grid>
  <DockPanel>
    <Border DockPanel.Dock="Top" Background="#1F2A44" Padding="20,16">
      <DockPanel>
        <Border DockPanel.Dock="Right" Background="#2F6FED" CornerRadius="14" Padding="14,5" VerticalAlignment="Center">
          <TextBlock Text="by Tay Zar" Foreground="White" FontWeight="SemiBold" FontSize="14"/>
        </Border>
        <StackPanel>
          <TextBlock Text="pyRevit MCP for Claude" Foreground="White" FontSize="22" FontWeight="SemiBold"/>
          <TextBlock Text="Offline setup for Revit 2019 and newer" Foreground="#C3CCE0"/>
        </StackPanel>
      </DockPanel>
    </Border>
    <Grid Margin="16">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>
      <Border x:Name="VersionCard" Grid.Row="0" Style="{StaticResource Card}">
        <StackPanel>
          <TextBlock Text="1. Choose Revit versions" Style="{StaticResource Head}"/>
          <ScrollViewer MaxHeight="180" VerticalScrollBarVisibility="Auto">
            <StackPanel x:Name="Versions"/>
          </ScrollViewer>
        </StackPanel>
      </Border>
      <Grid x:Name="Options" Grid.Row="1">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="3*"/><ColumnDefinition Width="12"/><ColumnDefinition Width="2*"/>
        </Grid.ColumnDefinitions>
        <Border Grid.Column="0" Style="{StaticResource Card}">
          <StackPanel>
            <TextBlock Text="2. MCP method (Revit 2021+)" Style="{StaticResource Head}"/>
            <CheckBox x:Name="Agent" Content="Agent MCP - built into pyRevit 7.1" IsChecked="True"/>
            <CheckBox x:Name="Routes" Content="Routes - MCP extension on localhost"/>
            <TextBlock Text="Revit 2019-2020 always use Routes." Foreground="#5A6372" TextWrapping="Wrap" Margin="0,6,0,0"/>
          </StackPanel>
        </Border>
        <Border Grid.Column="2" Style="{StaticResource Card}">
          <StackPanel>
            <TextBlock Text="3. Connect to Claude" Style="{StaticResource Head}"/>
            <CheckBox x:Name="Desktop" Content="Claude Desktop"/>
            <CheckBox x:Name="Code" Content="Claude Code"/>
          </StackPanel>
        </Border>
      </Grid>
      <Border x:Name="UninstallCard" Grid.Row="0" Style="{StaticResource Card}" Visibility="Collapsed">
        <StackPanel>
          <TextBlock Text="Uninstall" Style="{StaticResource Head}"/>
          <RadioButton x:Name="FromRecord" GroupName="Source" Content="Remove what this installer added" IsChecked="True" Margin="0,2"/>
          <RadioButton x:Name="FromExisting" GroupName="Source" Content="Remove existing setup found on this PC (installed another way)" Margin="0,2,0,8"/>
          <StackPanel x:Name="RecordPanel">
            <CheckBox x:Name="RemoveMcp" Content="MCP setup: Claude entries, MCP settings, extension and portable Python" IsChecked="True"/>
            <CheckBox x:Name="RemovePyRevit" Content="Also remove pyRevit installed by this installer (clean uninstall)"/>
            <TextBlock Text="Only items this installer added are removed. Your own extensions and projects stay." Foreground="#5A6372" TextWrapping="Wrap" Margin="0,6,0,0"/>
          </StackPanel>
          <StackPanel x:Name="ExistingPanel" Visibility="Collapsed">
            <TextBlock Text="Nothing is ticked. Tick only what you want to remove." Foreground="#B42318" FontWeight="SemiBold" Margin="0,0,0,4"/>
            <ScrollViewer MaxHeight="210" VerticalScrollBarVisibility="Auto">
              <StackPanel x:Name="Found"/>
            </ScrollViewer>
          </StackPanel>
        </StackPanel>
      </Border>
      <TextBox x:Name="Log" Grid.Row="2" IsReadOnly="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto"
               FontFamily="Consolas" FontSize="12" Background="White" BorderBrush="#DDE1E7" Padding="8"/>
      <StackPanel Grid.Row="3" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,12,0,0">
        <Button x:Name="Switch" Content="Uninstall..."/>
        <Button x:Name="Preview" Content="Preview"/>
        <Button x:Name="Install" Content="Install" Background="#2F6FED" Foreground="White" FontWeight="SemiBold"/>
      </StackPanel>
    </Grid>
  </DockPanel>
  <!-- Opening animation. Click anywhere to skip. -->
  <Grid x:Name="Splash" Visibility="Collapsed" Cursor="Hand">
    <Grid.Background>
      <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
        <GradientStop Color="#1F2A44" Offset="0"/><GradientStop Color="#0F1526" Offset="1"/>
      </LinearGradientBrush>
    </Grid.Background>
    <StackPanel VerticalAlignment="Center" HorizontalAlignment="Center">
      <Grid x:Name="Logo" Width="130" Height="130" Opacity="0" RenderTransformOrigin="0.5,0.5">
        <Grid.RenderTransform><ScaleTransform ScaleX="0.2" ScaleY="0.2"/></Grid.RenderTransform>
        <Ellipse x:Name="Ring" Stroke="#6EA0FF" StrokeThickness="3" StrokeDashArray="14,6" RenderTransformOrigin="0.5,0.5">
          <Ellipse.RenderTransform><RotateTransform/></Ellipse.RenderTransform>
        </Ellipse>
        <Ellipse Fill="#2F6FED" Margin="14"/>
        <TextBlock Text="MCP" Foreground="White" FontSize="28" FontWeight="Bold" HorizontalAlignment="Center" VerticalAlignment="Center"/>
      </Grid>
      <TextBlock x:Name="SplashTitle" Text="pyRevit MCP for Claude" Foreground="White" FontSize="30" FontWeight="SemiBold"
                 HorizontalAlignment="Center" Margin="0,24,0,0" Opacity="0">
        <TextBlock.RenderTransform><TranslateTransform Y="24"/></TextBlock.RenderTransform>
      </TextBlock>
      <TextBlock x:Name="SplashName" Text="by Tay Zar" Foreground="#9FBEFF" FontSize="18" HorizontalAlignment="Center" Margin="0,8,0,0" Opacity="0"/>
      <Border Width="260" Height="4" CornerRadius="2" Background="#33FFFFFF" Margin="0,30,0,0">
        <Border x:Name="Bar" Width="0" Height="4" CornerRadius="2" Background="#6EA0FF" HorizontalAlignment="Left"/>
      </Border>
    </StackPanel>
  </Grid>
  </Grid>
</Window>
'@

$window = [Windows.Markup.XamlReader]::Load((New-Object Xml.XmlNodeReader $xaml))
$iconFile = Join-Path $PSScriptRoot 'assets\app.ico'
if (Test-Path -LiteralPath $iconFile) {
    # Read into memory so the file is not locked (the EXE deletes its temporary folder afterwards).
    $iconStream = New-Object IO.MemoryStream (, [IO.File]::ReadAllBytes($iconFile))
    $window.Icon = [Windows.Media.Imaging.BitmapFrame]::Create($iconStream)
}
$ui = @{}
foreach ($n in 'Versions', 'Desktop', 'Code', 'Log', 'Switch', 'Preview', 'Install', 'VersionCard', 'Options', 'Agent', 'Routes', 'UninstallCard', 'RemoveMcp', 'RemovePyRevit', 'FromRecord', 'FromExisting', 'RecordPanel', 'ExistingPanel', 'Found', 'Splash', 'Logo', 'Ring', 'SplashTitle', 'SplashName', 'Bar') { $ui[$n] = $window.FindName($n) }

$script:Pump = {
    $frame = New-Object Windows.Threading.DispatcherFrame
    $null = [Windows.Threading.Dispatcher]::CurrentDispatcher.BeginInvoke(
        [Windows.Threading.DispatcherPriority]::Background, [Action]{ $frame.Continue = $false }.GetNewClosure())
    [Windows.Threading.Dispatcher]::PushFrame($frame)
}
$script:Logger = { param($m) $ui.Log.AppendText("$m`r`n"); $ui.Log.ScrollToEnd(); & $script:Pump }

# Revit versions found on this PC
$boxes = @()
$found = @(Get-RevitVersions)
foreach ($v in $found) {
    $box = New-Object Windows.Controls.CheckBox
    $note = switch ($v.Kind) {
        'Modern'      { 'pyRevit 7.1' }
        'Legacy'      { 'pyRevit 6.5.5, Routes only' }
        'Unsupported' { 'not supported' }
    }
    $box.Content = "Revit $($v.Year)    -    $note"
    $box.Tag = $v.Year
    $box.IsEnabled = $v.Kind -ne 'Unsupported'
    $null = $ui.Versions.Children.Add($box)
    $boxes += $box
}

$hasDesktop = @(Get-DesktopConfigPaths).Count -gt 0
$hasCode = [bool](Get-ClaudeCode)
foreach ($pair in @(@($ui.Desktop, $hasDesktop), @($ui.Code, $hasCode))) {
    $pair[0].IsChecked = $pair[1]; $pair[0].IsEnabled = $pair[1]
    if (-not $pair[1]) { $pair[0].Content = "$($pair[0].Content)  (not found on this PC)" }
}

function Set-Mode([bool]$Removing) {
    $script:Removing = $Removing
    $show = [Windows.Visibility]::Visible; $hide = [Windows.Visibility]::Collapsed
    $ui.VersionCard.Visibility = if ($Removing) { $hide } else { $show }
    $ui.Options.Visibility = if ($Removing) { $hide } else { $show }
    $ui.UninstallCard.Visibility = if ($Removing) { $show } else { $hide }
    $ui.Install.Content = if ($Removing) { 'Uninstall' } else { 'Install' }
    $ui.Switch.Content = if ($Removing) { 'Back to install' } else { 'Uninstall...' }
    $ui.Log.Clear()
    if ($Removing) { Write-Log 'Choose what to remove, then click Preview.' }
    elseif ($found.Count) { Write-Log 'Select your Revit versions, then click Preview to see every change before installing.' }
    else { Write-Log 'No Revit installation was found on this PC.' }
}

# Lists what is on this PC. Every box starts unticked.
function Update-Found {
    $ui.Found.Children.Clear()
    Write-Log 'Looking for existing setup...'
    $items = @(Get-ExistingSetup)
    foreach ($item in $items) {
        $text = New-Object Windows.Controls.TextBlock
        $text.Text = $item.Label; $text.TextWrapping = 'Wrap'
        $box = New-Object Windows.Controls.CheckBox
        $box.Content = $text; $box.Tag = $item
        $null = $ui.Found.Children.Add($box)
    }
    if ($items.Count) { Write-Log "Found $($items.Count) item(s). Tick what to remove, then click Preview." }
    else { Write-Log 'No existing pyRevit MCP setup was found.' }
}

function Set-Source([bool]$Existing) {
    $show = [Windows.Visibility]::Visible; $hide = [Windows.Visibility]::Collapsed
    $ui.RecordPanel.Visibility = if ($Existing) { $hide } else { $show }
    $ui.ExistingPanel.Visibility = if ($Existing) { $show } else { $hide }
    $ui.Log.Clear()
    if ($Existing) { Invoke-Busy { Update-Found } } else { Write-Log 'Choose what to remove, then click Preview.' }
}

function Get-PlanFromUi {
    if ($script:Removing) {
        if ($ui.FromExisting.IsChecked) {
            return Get-ExistingRemovalPlan @($ui.Found.Children | Where-Object { $_.IsChecked } | ForEach-Object { $_.Tag })
        }
        return Get-UninstallPlan ([bool]$ui.RemoveMcp.IsChecked) ([bool]$ui.RemovePyRevit.IsChecked)
    }
    $years = [int[]]@($boxes | Where-Object { $_.IsChecked } | ForEach-Object { $_.Tag })
    Get-InstallPlan $years ([bool]$ui.Desktop.IsChecked) ([bool]$ui.Code.IsChecked) ([bool]$ui.Agent.IsChecked) ([bool]$ui.Routes.IsChecked)
}
function Show-Plan($Plan) {
    $ui.Log.Clear()
    if ($Plan.Steps.Count) {
        Write-Log 'Planned changes:'
        $i = 0; foreach ($s in $Plan.Steps) { $i++; Write-Log "  $i. $($s.Text)" }
    }
    foreach ($w in $Plan.Warnings) { Write-Log "NOTE: $w" }
    foreach ($p in $Plan.Problems) { Write-Log "CANNOT CONTINUE YET: $p" }
}

function Invoke-Busy([scriptblock]$Work) {
    $controls = @($ui.Install, $ui.Preview, $ui.Switch, $ui.VersionCard, $ui.Options, $ui.UninstallCard)
    foreach ($c in $controls) { $c.IsEnabled = $false }
    $script:Busy = $true
    try { & $Work }
    catch { Write-Log "ERROR: $($_.Exception.Message)" }
    finally { $script:Busy = $false; foreach ($c in $controls) { $c.IsEnabled = $true } }
}

# Removing pyRevit always removes the MCP setup too.
$ui.RemovePyRevit.Add_Checked({ $ui.RemoveMcp.IsChecked = $true; $ui.RemoveMcp.IsEnabled = $false })
$ui.RemovePyRevit.Add_Unchecked({ $ui.RemoveMcp.IsEnabled = $true })
$ui.Switch.Add_Click({ $ui.FromRecord.IsChecked = $true; Set-Mode (-not $script:Removing) })
$ui.FromRecord.Add_Click({ Set-Source $false })
$ui.FromExisting.Add_Click({ Set-Source $true })
$ui.Preview.Add_Click({ Invoke-Busy { Show-Plan (Get-PlanFromUi) } })

$ui.Install.Add_Click({
    Invoke-Busy {
        $verb = if ($script:Removing) { 'Uninstall' } else { 'Install' }
        $plan = Get-PlanFromUi
        Show-Plan $plan
        if ($plan.Problems.Count -or -not $plan.Steps.Count) { return }
        $icon = if ($script:Removing) { 'Warning' } else { 'Question' }
        $question = "Apply the $($plan.Steps.Count) steps listed in the window?"
        $existing = $script:Removing -and $ui.FromExisting.IsChecked
        if ($existing) {
            $names = @($ui.Found.Children | Where-Object { $_.IsChecked } | ForEach-Object { "- $($_.Tag.Label)" }) -join "`n"
            $question = "These were NOT installed by this installer. Remove them?`n`n$names"
        }
        if (@($plan.Confirm).Count) {
            # Changes to a pyRevit the user already had are repeated here, so they cannot be missed.
            $question += "`n`nThis changes your existing pyRevit:`n" + (@($plan.Confirm | ForEach-Object { "- $_" }) -join "`n")
            $icon = 'Warning'
        }
        # The safe answer is selected by default.
        $answer = [Windows.MessageBox]::Show($window, $question, $verb, 'YesNo', $icon, 'No')
        if ($answer -ne 'Yes') { Write-Log 'Cancelled. Nothing was changed.'; return }
        Write-Log ''
        Invoke-InstallPlan $plan
        Write-Log ''
        if ($existing) { Write-Log 'Refreshing the list...'; Update-Found }
        if ($script:Removing) { Write-Log 'DONE. Fully quit and reopen Claude.' }
        else { Write-Log 'DONE. Next: start Revit, open a project, then fully quit and reopen Claude.' }
    }
})

# ---------- opening animation and sound ----------
function New-Move([double]$From, [double]$To, [double]$Seconds, [double]$Delay = 0, $Ease) {
    $a = New-Object Windows.Media.Animation.DoubleAnimation $From, $To, ([Windows.Duration][TimeSpan]::FromSeconds($Seconds))
    $a.BeginTime = [TimeSpan]::FromSeconds($Delay)
    if ($Ease) { $a.EasingFunction = $Ease }
    $a
}

function Close-Splash {
    if ($script:SplashTimer) { $script:SplashTimer.Stop() }
    $fade = New-Move 1 0 0.45
    $fade.Add_Completed({ $ui.Splash.Visibility = 'Collapsed' })
    $ui.Splash.BeginAnimation([Windows.UIElement]::OpacityProperty, $fade)
}

function Start-Splash([bool]$WithSound) {
    $ui.Splash.Visibility = 'Visible'
    $opacity = [Windows.UIElement]::OpacityProperty
    $out = New-Object Windows.Media.Animation.CubicEase
    $bounce = New-Object Windows.Media.Animation.BackEase; $bounce.Amplitude = 0.6

    $ui.Logo.BeginAnimation($opacity, (New-Move 0 1 0.35))
    foreach ($p in [Windows.Media.ScaleTransform]::ScaleXProperty, [Windows.Media.ScaleTransform]::ScaleYProperty) {
        $ui.Logo.RenderTransform.BeginAnimation($p, (New-Move 0.2 1 0.8 0 $bounce))
    }
    $ui.Ring.RenderTransform.BeginAnimation([Windows.Media.RotateTransform]::AngleProperty, (New-Move 0 240 2.8 0 $out))
    $ui.SplashTitle.BeginAnimation($opacity, (New-Move 0 1 0.5 0.45))
    $ui.SplashTitle.RenderTransform.BeginAnimation([Windows.Media.TranslateTransform]::YProperty, (New-Move 24 0 0.6 0.45 $out))
    $ui.SplashName.BeginAnimation($opacity, (New-Move 0 1 0.5 0.9))
    $ui.Bar.BeginAnimation([Windows.FrameworkElement]::WidthProperty, (New-Move 0 260 2.4 0.2))

    # A missing or unplayable sound must never stop the installer.
    $wav = Join-Path $PSScriptRoot 'assets\startup.wav'
    if ($WithSound -and (Test-Path -LiteralPath $wav)) {
        try { $script:Sound = New-Object System.Media.SoundPlayer $wav; $script:Sound.Play() } catch { }
    }
    $script:SplashTimer = New-Object Windows.Threading.DispatcherTimer
    $script:SplashTimer.Interval = [TimeSpan]::FromSeconds(2.9)
    $script:SplashTimer.Add_Tick({ Close-Splash })
    $script:SplashTimer.Start()
}

$ui.Splash.Add_MouseLeftButtonUp({ if ($script:Sound) { $script:Sound.Stop() }; Close-Splash })
if (-not $NoSplash -and -not $Screenshot) { $window.Add_ContentRendered({ Start-Splash $true }) }

Set-Mode ([bool]$Uninstall)
$window.Add_Closing({ param($sender, $e) if ($script:Busy) { $e.Cancel = $true } })

if ($Screenshot) {
    foreach ($b in $boxes) { if (@(2019, 2024) -contains $b.Tag) { $b.IsChecked = $true } }
    $window.WindowStartupLocation = 'Manual'; $window.Left = -4000; $window.Top = 0; $window.ShowInTaskbar = $false
    $window.Show(); & $script:Pump
    if ($Existing) { $ui.FromExisting.IsChecked = $true; Set-Source $true } else { Show-Plan (Get-PlanFromUi) }
    # Pictures for the documentation: no user folder names, and no "close Revit first" lines.
    $ui.Log.Text = (($ui.Log.Text -split "`r`n" | Where-Object { $_ -notlike 'CANNOT CONTINUE*' }) -join "`r`n").Replace($env:USERPROFILE, 'C:\Users\YourName')
    foreach ($item in @($ui.Found.Children)) { $item.Content.Text = $item.Content.Text.Replace($env:USERPROFILE, 'C:\Users\YourName') }
    $ui.Log.ScrollToHome(); & $script:Pump; $window.UpdateLayout()
    if ($SplashAt -gt 0) {
        Start-Splash $false
        $clock = [Diagnostics.Stopwatch]::StartNew()
        while ($clock.Elapsed.TotalSeconds -lt $SplashAt) { & $script:Pump; Start-Sleep -Milliseconds 15 }
    }
    $content = $window.Content
    $bmp = New-Object Windows.Media.Imaging.RenderTargetBitmap ([int]$content.ActualWidth), ([int]$content.ActualHeight), 96, 96, ([Windows.Media.PixelFormats]::Pbgra32)
    $bmp.Render($content)
    $enc = New-Object Windows.Media.Imaging.PngBitmapEncoder
    $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bmp))
    $stream = [IO.File]::Create($Screenshot); $enc.Save($stream); $stream.Close()
    $window.Close()
    return
}

$null = $window.ShowDialog()
