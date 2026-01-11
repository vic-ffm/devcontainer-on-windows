# SPDX-License-Identifier: NCSA
#===============================================================================
# Setup-DevContainers.ps1 - DevContainers environment setup for Windows 11
#
# DESCRIPTION:
#   Automated setup of VS Code DevContainers on Windows 11 via WSL2.
#   Handles WSL2 enablement, distro installation, and tooling setup.
#   Non-interactive mode available for automation.
#
# REQUIREMENTS:
#   Windows 11 22H2+ 
#   PowerShell 5.1+ or PowerShell 7+
#   Administrator privileges
#
# USAGE:
#   .\Setup-DevContainers.ps1
#   .\Setup-DevContainers.ps1 -Distro Ubuntu
#   .\Setup-DevContainers.ps1 -DryRun -Verbose
#   .\Setup-DevContainers.ps1 -NonInteractive -Distro Debian
#
# OPTIONS:
#   -Distro           Distro to install: Debian (default) or Ubuntu
#   -Resume           Resume setup after reboot
#   -DryRun           Show what would be done without making changes
#   -NonInteractive   Skip all prompts, use defaults
#   -SkipApps         Skip Windows Terminal/VS Code installation
#   -SkipFonts        Skip MesloLGS NF font installation
#   -Force            Overwrite existing configuration
#   -Help             Show help message
#
# LICENSE:            NCSA
#===============================================================================

#Requires -Version 5.1
#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [Parameter(HelpMessage = "Linux distribution to install")]
    [ValidateSet('Debian', 'Ubuntu')]
    [string]$Distro = 'Debian',

    [Parameter(HelpMessage = "Resume setup after reboot")]
    [switch]$Resume,

    [Parameter(HelpMessage = "Preview without making changes")]
    [switch]$DryRun,

    [Parameter(HelpMessage = "Skip all prompts, use defaults")]
    [switch]$NonInteractive,

    [Parameter(HelpMessage = "Skip Windows Terminal/VS Code installation")]
    [switch]$SkipApps,

    [Parameter(HelpMessage = "Skip MesloLGS NF font installation")]
    [switch]$SkipFonts,

    [Parameter(HelpMessage = "Overwrite existing configuration")]
    [switch]$Force,

    [Parameter(HelpMessage = "Show help message")]
    [switch]$Help
)

#-------------------------------------------------------------------------------
# Strict Mode
#-------------------------------------------------------------------------------
Set-StrictMode -Version 3.0  # Explicit version for deterministic behavior
$ErrorActionPreference = 'Stop'
$script:OriginalProgressPreference = $ProgressPreference
$ProgressPreference = 'SilentlyContinue' 

#-------------------------------------------------------------------------------
# Constants
#-------------------------------------------------------------------------------
$script:SCRIPT_NAME = $MyInvocation.MyCommand.Name
$script:SCRIPT_VERSION = "1.0.0"
$script:LOG_DIR = "$env:LOCALAPPDATA\DevContainersSetup"
$script:LOG_FILE = "$script:LOG_DIR\setup.log"
$script:STATE_REG_PATH = "HKCU:\Software\DevContainersSetup"
$script:RESUME_TASK_NAME = "DevContainersSetup_Resume"

# Mutex for preventing concurrent execution
$script:SETUP_MUTEX_NAME = "Global\DevContainersSetup_Mutex"
$script:SetupMutex = $null

# Exit codes 
$script:EXIT_SUCCESS = 0
$script:EXIT_GENERAL_ERROR = 1
$script:EXIT_NOT_ADMIN = 2
$script:EXIT_INVALID_ARGS = 3
$script:EXIT_WSL_FAILED = 4
$script:EXIT_DISTRO_FAILED = 5
$script:EXIT_WINGET_FAILED = 6
$script:EXIT_REBOOT_REQUIRED = 7
$script:EXIT_USER_CANCELLED = 8

# Supported distros 
$script:SUPPORTED_DISTROS = @{
    'Debian' = @{
        WslName       = 'Debian'
        DisplayName   = 'Debian 13 Trixie'
        IsDefault     = $true
        SupportUntil  = '2030-06-30'
    }
    'Ubuntu' = @{
        WslName       = 'Ubuntu-24.04'
        DisplayName   = 'Ubuntu 24.04 LTS'
        IsDefault     = $false
        SupportUntil  = '2029-04'
    }
}

# VS Code extensions required for DevContainers
$script:VSCODE_EXTENSIONS = @(
    'ms-vscode-remote.remote-containers'
    'ms-vscode-remote.remote-wsl'
)

# MesloLGS NF font files (bundled with repo for Powerlevel10k)
$script:MESLO_FONT_FILES = @(
    'MesloLGS NF Regular.ttf'
    'MesloLGS NF Bold.ttf'
    'MesloLGS NF Italic.ttf'
    'MesloLGS NF Bold Italic.ttf'
)
$script:MESLO_FONT_NAME = "MesloLGS NF"

#-------------------------------------------------------------------------------
# Logging Functions
#-------------------------------------------------------------------------------
function Initialize-Logging {
    if (-not (Test-Path $script:LOG_DIR)) {
        New-Item -ItemType Directory -Path $script:LOG_DIR -Force | Out-Null
    }
    # Clear or create log file
    "" | Out-File -FilePath $script:LOG_FILE -Encoding UTF8
}

function Write-Log {
    param(
        [Parameter(Mandatory)]
        [string]$Level,
        [Parameter(Mandatory)]
        [string]$Message,
        [Parameter(Mandatory)]
        [string]$Color
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logLine = "[$Level] $timestamp - $Message"

    # Write to log file
    Add-Content -Path $script:LOG_FILE -Value $logLine -Encoding UTF8

    # Write to console with color
    Write-Host $logLine -ForegroundColor $Color
}

function Write-LogInfo {
    param([string]$Message)
    Write-Log -Level "INFO " -Message $Message -Color "Cyan"
}

function Write-LogSuccess {
    param([string]$Message)
    Write-Log -Level "OK   " -Message $Message -Color "Green"
}

function Write-LogWarn {
    param([string]$Message)
    Write-Log -Level "WARN " -Message $Message -Color "Yellow"
}

function Write-LogError {
    param([string]$Message)
    Write-Log -Level "ERROR" -Message $Message -Color "Red"
}

function Write-LogDebug {
    param([string]$Message)
    if ($VerbosePreference -eq 'Continue' -or $PSBoundParameters['Verbose']) {
        Write-Log -Level "DEBUG" -Message $Message -Color "DarkGray"
    }
}

function Write-LogStep {
    param(
        [Parameter(Mandatory)]
        [string]$Step,
        [Parameter(Mandatory)]
        [string]$Description
    )

    Write-Host ""
    Write-Host "[Step $Step] " -ForegroundColor Blue -NoNewline
    Write-Host $Description -ForegroundColor White
    Write-Host ("-" * 60) -ForegroundColor DarkGray

    Add-Content -Path $script:LOG_FILE -Value "" -Encoding UTF8
    Add-Content -Path $script:LOG_FILE -Value "[Step $Step] $Description" -Encoding UTF8
    Add-Content -Path $script:LOG_FILE -Value ("-" * 60) -Encoding UTF8
}

#-------------------------------------------------------------------------------
# Utility Functions
#-------------------------------------------------------------------------------
function Test-Administrator {
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentUser)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Exit-WithError {
    param(
        [string]$Message,
        [int]$ExitCode = $script:EXIT_GENERAL_ERROR
    )

    Write-LogError $Message
    Write-LogInfo "Log file: $script:LOG_FILE"
    exit $ExitCode
}

function Invoke-WithDryRun {
    param(
        [Parameter(Mandatory)]
        [scriptblock]$ScriptBlock,
        [string]$Description
    )

    if ($DryRun) {
        Write-LogInfo "[DRY-RUN] Would execute: $Description"
        return $null
    }

    Write-LogDebug "Executing: $Description"
    return & $ScriptBlock
}

function Get-Confirmation {
    param(
        [Parameter(Mandatory)]
        [string]$Prompt,
        [bool]$Default = $true
    )

    if ($NonInteractive) {
        Write-LogDebug "Non-interactive mode: using default ($Default)"
        return $Default
    }

    if ($DryRun) {
        Write-LogInfo "[DRY-RUN] Would prompt: $Prompt"
        return $true
    }

    $defaultText = if ($Default) { "[Y/n]" } else { "[y/N]" }
    $response = Read-Host "$Prompt $defaultText"

    if ([string]::IsNullOrWhiteSpace($response)) {
        return $Default
    }

    return $response -match '^[Yy]'
}

#-------------------------------------------------------------------------------
# Script Locking (prevent concurrent execution)
#-------------------------------------------------------------------------------
function Enter-ScriptLock {
    <#
    .SYNOPSIS
    Acquires an exclusive lock to prevent concurrent script execution.
    .OUTPUTS
    Returns $true if lock acquired, $false if another instance is running.
    #>
    try {
        $createdNew = $false
        $script:SetupMutex = New-Object System.Threading.Mutex($true, $script:SETUP_MUTEX_NAME, [ref]$createdNew)

        if (-not $createdNew) {
            # Mutex exists, try to acquire it with timeout
            $acquired = $script:SetupMutex.WaitOne(0)  # Non-blocking
            if (-not $acquired) {
                Write-LogError "Another instance of DevContainers Setup is already running"
                return $false
            }
        }

        Write-LogDebug "Acquired exclusive script lock"
        return $true
    }
    catch [System.Threading.AbandonedMutexException] {
        # Previous instance crashed without releasing - we now own it
        Write-LogDebug "Acquired abandoned script lock (previous instance crashed)"
        return $true
    }
    catch {
        Write-LogWarn "Could not acquire script lock: $_"
        # Allow script to run anyway - lock is a safety feature, not critical
        return $true
    }
}

function Exit-ScriptLock {
    <#
    .SYNOPSIS
    Releases the exclusive lock when script completes.
    #>
    if ($script:SetupMutex) {
        try {
            $script:SetupMutex.ReleaseMutex()
            $script:SetupMutex.Dispose()
            Write-LogDebug "Released script lock"
        }
        catch {
            # Ignore errors during cleanup
        }
        $script:SetupMutex = $null
    }
}

#-------------------------------------------------------------------------------
# Virtualization Check
#-------------------------------------------------------------------------------
function Test-VirtualizationEnabled {
    <#
    .SYNOPSIS
    Checks if hardware virtualization is enabled and available.
    .DESCRIPTION
    Uses multiple detection methods because:
    - When hypervisor is already running (WSL2, Hyper-V), VirtualizationFirmwareEnabled
      returns false even though virtualization IS working
    - HypervisorPresent = true means virtualization is already active
    .OUTPUTS
    Returns hashtable with Enabled (bool) and Message (string).
    #>
    try {
        # Method 1: Check if hypervisor is already present (most reliable when WSL2/Hyper-V active)
        $computerSystem = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue
        if ($computerSystem.HypervisorPresent -eq $true) {
            return @{ Enabled = $true; Message = "Hypervisor already active" }
        }

        # Method 2: Check firmware setting (only reliable when hypervisor is NOT running)
        $cpu = Get-CimInstance -ClassName Win32_Processor -ErrorAction SilentlyContinue
        if ($cpu.VirtualizationFirmwareEnabled -eq $true) {
            return @{ Enabled = $true; Message = "Virtualization enabled in firmware" }
        }

        # Method 3: Check via Get-ComputerInfo (Windows 10+)
        try {
            $compInfo = Get-ComputerInfo -Property HyperV* -ErrorAction SilentlyContinue
            if ($compInfo.HyperVisorPresent -eq $true) {
                return @{ Enabled = $true; Message = "Hypervisor present (Get-ComputerInfo)" }
            }
            if ($compInfo.HyperVRequirementVirtualizationFirmwareEnabled -eq $true) {
                return @{ Enabled = $true; Message = "Virtualization enabled (Get-ComputerInfo)" }
            }
        }
        catch {
            # Get-ComputerInfo may not be available on all systems
        }

        # If we reach here without confirming enabled, check if it's explicitly disabled
        if ($cpu.VirtualizationFirmwareEnabled -eq $false -and $computerSystem.HypervisorPresent -eq $false) {
            return @{
                Enabled = $false
                Message = "Hardware virtualization is disabled in BIOS/UEFI. Enable VT-x/AMD-V."
            }
        }

        # Can't determine - assume enabled and let WSL fail with its own error if not
        return @{ Enabled = $true; Message = "Virtualization status unclear (assuming enabled)" }
    }
    catch {
        # Can't verify - assume enabled and let WSL fail with its own error if not
        return @{ Enabled = $true; Message = "Could not verify virtualization (assuming enabled)" }
    }
}

#-------------------------------------------------------------------------------
# WSL Command Helpers (robust UTF-16 handling and timeout support)
#-------------------------------------------------------------------------------
function Invoke-WslCommand {
    <#
    .SYNOPSIS
    Executes a WSL command with proper UTF-16 encoding handling.
    .OUTPUTS
    Returns hashtable with ExitCode, Output, and Success properties.
    #>
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments,
        [string]$Distro
    )

    $origEncoding = [Console]::OutputEncoding
    try {
        [Console]::OutputEncoding = [System.Text.Encoding]::Unicode

        $wslArgs = @()
        if ($Distro) {
            $wslArgs += @("-d", $Distro)
        }
        $wslArgs += $Arguments

        $output = & wsl.exe @wslArgs 2>&1
        $exitCode = $LASTEXITCODE

        return @{
            ExitCode = $exitCode
            Output   = ($output | Out-String) -replace '\x00', '' -replace '\r', ''
            Success  = ($exitCode -eq 0)
        }
    }
    finally {
        [Console]::OutputEncoding = $origEncoding
    }
}

function Invoke-WslWithTimeout {
    <#
    .SYNOPSIS
    Executes a WSL command with timeout protection for long-running commands.
    .OUTPUTS
    Returns hashtable with ExitCode, Output, Error, and Success properties.
    #>
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments,
        [string]$Distro,
        [int]$TimeoutSeconds = 120
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "wsl.exe"

    $fullArgs = @()
    if ($Distro) {
        $fullArgs += @("-d", $Distro)
    }
    $fullArgs += $Arguments
    $psi.Arguments = $fullArgs -join ' '

    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::Unicode
    $psi.StandardErrorEncoding = [System.Text.Encoding]::Unicode

    $process = [System.Diagnostics.Process]::Start($psi)

    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        $process.Kill()
        throw "WSL command timed out after $TimeoutSeconds seconds: wsl $($fullArgs -join ' ')"
    }

    $stdout = $process.StandardOutput.ReadToEnd() -replace '\x00', '' -replace '\r', ''
    $stderr = $process.StandardError.ReadToEnd() -replace '\x00', '' -replace '\r', ''

    return @{
        ExitCode = $process.ExitCode
        Output   = $stdout
        Error    = $stderr
        Success  = ($process.ExitCode -eq 0)
    }
}

#-------------------------------------------------------------------------------
# State Management (for reboot resume)
#-------------------------------------------------------------------------------
function Save-SetupState {
    param(
        [int]$Phase,
        [string]$SelectedDistro
    )

    if ($DryRun) {
        Write-LogInfo "[DRY-RUN] Would save state: Phase=$Phase, Distro=$SelectedDistro"
        return
    }

    if (-not (Test-Path $script:STATE_REG_PATH)) {
        New-Item -Path $script:STATE_REG_PATH -Force | Out-Null
    }

    Set-ItemProperty -Path $script:STATE_REG_PATH -Name "Phase" -Value $Phase
    Set-ItemProperty -Path $script:STATE_REG_PATH -Name "Distro" -Value $SelectedDistro
    Set-ItemProperty -Path $script:STATE_REG_PATH -Name "Timestamp" -Value (Get-Date -Format "o")
    Set-ItemProperty -Path $script:STATE_REG_PATH -Name "ScriptPath" -Value $PSCommandPath

    Write-LogDebug "Saved state: Phase=$Phase, Distro=$SelectedDistro"
}

function Get-SetupState {
    if (-not (Test-Path $script:STATE_REG_PATH)) {
        return $null
    }

    try {
        $state = @{
            Phase      = (Get-ItemProperty -Path $script:STATE_REG_PATH -Name "Phase" -ErrorAction SilentlyContinue).Phase
            Distro     = (Get-ItemProperty -Path $script:STATE_REG_PATH -Name "Distro" -ErrorAction SilentlyContinue).Distro
            Timestamp  = (Get-ItemProperty -Path $script:STATE_REG_PATH -Name "Timestamp" -ErrorAction SilentlyContinue).Timestamp
            ScriptPath = (Get-ItemProperty -Path $script:STATE_REG_PATH -Name "ScriptPath" -ErrorAction SilentlyContinue).ScriptPath
        }

        if ($state.Phase -and $state.Distro) {
            return $state
        }
    }
    catch {
        Write-LogDebug "No valid saved state found"
    }

    return $null
}

function Clear-SetupState {
    # Clean up scheduled task if it exists
    $null = schtasks.exe /delete /tn $script:RESUME_TASK_NAME /f 2>&1
    Write-LogDebug "Cleaned up resume task (if existed)"

    # Clean up registry state
    if (Test-Path $script:STATE_REG_PATH) {
        Remove-Item -Path $script:STATE_REG_PATH -Recurse -Force -ErrorAction SilentlyContinue
        Write-LogDebug "Cleared saved registry state"
    }

    # Note: Mutex lock is released in Exit-ScriptLock called from finally block
}

function Request-Reboot {
    param(
        [int]$NextPhase,
        [string]$SelectedDistro
    )

    Save-SetupState -Phase $NextPhase -SelectedDistro $SelectedDistro

    if ($DryRun) {
        Write-LogInfo "[DRY-RUN] Would request reboot and schedule resume task"
        return
    }

    $scriptPath = $PSCommandPath
    $resumeCmd = "powershell.exe -ExecutionPolicy Bypass -NoProfile -WindowStyle Normal -File `"$scriptPath`" -Resume"

    # Method 1: Task Scheduler (works for all users, most reliable)
    Write-LogDebug "Creating scheduled task for resume..."

    # Delete existing task if present
    $null = schtasks.exe /delete /tn $script:RESUME_TASK_NAME /f 2>&1

    # Create task to run at next logon with highest privileges
    # Using /rl HIGHEST ensures admin elevation
    $taskResult = schtasks.exe /create /tn $script:RESUME_TASK_NAME /tr $resumeCmd /sc ONLOGON /rl HIGHEST /f 2>&1
    $taskExitCode = $LASTEXITCODE

    if ($taskExitCode -eq 0) {
        Write-LogDebug "Created scheduled task: $script:RESUME_TASK_NAME"
    }
    else {
        Write-LogWarn "Task Scheduler method failed (exit code: $taskExitCode)"
        Write-LogDebug "Task Scheduler output: $taskResult"

        # Method 2: RunOnce fallback (only works for admin accounts)
        Write-LogInfo "Attempting RunOnce registry fallback..."
        try {
            # Use exclamation prefix to defer deletion until after execution
            Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce" `
                -Name "!DevContainersSetup" -Value $resumeCmd -ErrorAction Stop
            Write-LogDebug "Created RunOnce registry entry"
            Write-LogWarn "Note: RunOnce only works if logged in as Administrator account"
        }
        catch {
            Write-LogError "Could not create resume mechanism: $_"
            Write-LogWarn "Please run this script again with -Resume flag after reboot"
        }
    }

    Write-Host ""
    Write-LogWarn "==============================================================="
    Write-LogWarn "  SYSTEM RESTART REQUIRED"
    Write-LogWarn "==============================================================="
    Write-Host ""
    Write-LogInfo "WSL2 features have been enabled and require a restart."
    Write-LogInfo "Setup will resume automatically after restart."
    Write-Host ""

    if (-not $NonInteractive) {
        $restart = Get-Confirmation -Prompt "Restart now?" -Default $true
        if ($restart) {
            Write-LogInfo "Restarting computer in 5 seconds..."
            Start-Sleep -Seconds 5
            Restart-Computer -Force
        }
    }

    Write-Host ""
    Write-LogInfo "Please restart your computer manually, then setup will continue."
    Write-LogInfo "Or run: shutdown /r /t 0"

    exit $script:EXIT_REBOOT_REQUIRED
}

#-------------------------------------------------------------------------------
# WSL Configuration Functions
#-------------------------------------------------------------------------------
function Initialize-WslConfig {
    Write-LogInfo "Configuring WSL settings (.wslconfig)..."

    $wslConfigPath = Join-Path $env:USERPROFILE ".wslconfig"
    $configChanged = $false

    # Calculate 80% of system RAM for WSL2 memory limit
    $totalRamBytes = (Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory
    $wslMemoryGB = [Math]::Floor(($totalRamBytes * 0.8) / 1GB)
    # Ensure minimum of 4GB 
    $wslMemoryGB = [Math]::Max($wslMemoryGB, 4)
    $memoryConfig = "${wslMemoryGB}GB"
    Write-LogDebug "System RAM: $([Math]::Round($totalRamBytes / 1GB, 1))GB, WSL2 limit: $memoryConfig (80%)"

    # Read existing config
    $configContent = ""
    if (Test-Path $wslConfigPath) {
        $configContent = Get-Content $wslConfigPath -Raw -ErrorAction SilentlyContinue
        if (-not $configContent) { $configContent = "" }
    }

    if ($DryRun) {
        Write-LogInfo "[DRY-RUN] Would configure .wslconfig with memory=$memoryConfig and autoMemoryReclaim=gradual"
        return
    }

    # Ensure [wsl2] section exists with recommended settings
    if ($configContent -notmatch "\[wsl2\]") {
        $configContent = "[wsl2]`nmemory=$memoryConfig`nlocalhostForwarding=true`n`n" + $configContent
        $configChanged = $true
        Write-LogDebug "Added [wsl2] section with memory=$memoryConfig"
    }
    elseif ($configContent -notmatch "memory\s*=") {
        # Add memory setting under existing [wsl2] section
        $configContent = $configContent -replace "(\[wsl2\])", "`$1`nmemory=$memoryConfig"
        $configChanged = $true
        Write-LogDebug "Added memory=$memoryConfig to existing [wsl2] section"
    }

    # DISABLE sparse VHD due to current WSL2 bugs
    if ($configContent -notmatch "\[experimental\]") {
        $configContent += "`n[experimental]`nsparseVhd=false`nautoMemoryReclaim=gradual`n"
        $configChanged = $true
        Write-LogDebug "Added [experimental] section with sparseVhd=false"
    }
    elseif ($configContent -match "sparseVhd\s*=\s*true") {
        $configContent = $configContent -replace "sparseVhd\s*=\s*true", "sparseVhd=false"
        $configChanged = $true
        Write-LogDebug "Changed sparseVhd from true to false"
    }
    elseif ($configContent -notmatch "sparseVhd\s*=") {
        $configContent = $configContent -replace "(\[experimental\])", "`$1`nsparseVhd=false"
        $configChanged = $true
        Write-LogDebug "Added sparseVhd=false to existing [experimental] section"
    }

    if ($configChanged) {
        Write-LogInfo "Updating .wslconfig with recommended settings..."

        # Backup existing config
        if (Test-Path $wslConfigPath) {
            $backupPath = "$wslConfigPath.backup"
            Copy-Item $wslConfigPath $backupPath -Force
            Write-LogDebug "Backed up existing .wslconfig to $backupPath"
        }

        Set-Content -Path $wslConfigPath -Value $configContent.Trim() -Encoding UTF8
        Write-LogSuccess "WSL configuration updated (memory=$memoryConfig, autoMemoryReclaim=gradual)"

        # Restart WSL to apply
        Write-LogInfo "Restarting WSL to apply configuration..."
        wsl --shutdown 2>$null
        Start-Sleep -Seconds 3
        Write-LogSuccess "WSL restarted with new configuration"
    }
    else {
        Write-LogSuccess "WSL configuration already optimized"
    }

    # Disable sparse VHD on existing distros to ensure consistency
    Disable-SparseOnExistingDistros
}

function Disable-SparseOnExistingDistros {
    Write-LogInfo "Checking sparse VHD status on existing distributions..."

    # Get list of existing distros
    $rawOutput = wsl --list --quiet 2>&1
    $distroList = ($rawOutput | Out-String) -replace '\x00', '' -replace '\r', ''
    $distros = @($distroList -split "`n" | Where-Object { $_ -match '\S' } | ForEach-Object { $_.Trim() })

    if ($distros.Count -eq 0) {
        Write-LogInfo "No existing distributions to configure"
        return
    }

    Write-LogInfo "Found $($distros.Count) distribution(s) to configure: $($distros -join ', ')"

    if ($DryRun) {
        Write-LogInfo "[DRY-RUN] Would disable sparse VHD for all distributions"
        return
    }

    # Shut down WSL first
    Write-LogInfo "Shutting down WSL to configure VHD settings..."
    wsl --shutdown 2>$null
    Start-Sleep -Seconds 3

    $anyChanged = $false

    foreach ($distro in $distros) {
        if (-not $distro) { continue }

        Write-LogInfo "Disabling sparse VHD for: $distro"

        # Disable sparse 
        $result = wsl --manage $distro --set-sparse false 2>&1
        $resultStr = ($result | Out-String) -replace '\x00', '' -replace '\r', ''

        if ($LASTEXITCODE -eq 0) {
            Write-LogSuccess "Disabled sparse VHD for: $distro"
            $anyChanged = $true
        }
        else {
            Write-LogDebug "Could not change sparse for ${distro}: $($resultStr.Trim())"
        }
    }

    if ($anyChanged) {
        Write-LogSuccess "VHD configuration complete"
    }

    # WSL restart 
    Write-LogInfo "Restarting WSL to apply all configuration changes..."
    wsl --shutdown 2>$null
    Start-Sleep -Seconds 3
    Write-LogSuccess "WSL ready for new installations"
}

#-------------------------------------------------------------------------------
# WSL2 Functions
#-------------------------------------------------------------------------------
function Test-WSL2Enabled {
    Write-LogDebug "Checking WSL2 feature status..."

    try {
        $wslFeature = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux -ErrorAction Stop
        $vmFeature = Get-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -ErrorAction Stop

        $wslEnabled = $wslFeature.State -eq 'Enabled'
        $vmEnabled = $vmFeature.State -eq 'Enabled'

        Write-LogDebug "WSL feature: $($wslFeature.State), VM Platform: $($vmFeature.State)"

        return @{
            WSLEnabled = $wslEnabled
            VMEnabled  = $vmEnabled
            AllEnabled = ($wslEnabled -and $vmEnabled)
        }
    }
    catch {
        Write-LogDebug "Error checking features: $_"
        return @{
            WSLEnabled = $false
            VMEnabled  = $false
            AllEnabled = $false
        }
    }
}

function Enable-WSL2Features {
    Write-LogStep "1/7" "Enabling WSL2 features"

    $status = Test-WSL2Enabled
    $needsReboot = $false

    if ($status.AllEnabled) {
        Write-LogSuccess "WSL2 features already enabled"

        # Ensure WSL2 is set as default version
        Invoke-WithDryRun -Description "Set WSL2 as default" -ScriptBlock {
            $null = wsl --set-default-version 2 2>$null
        }

        return $false  # No reboot needed
    }

    if (-not $status.WSLEnabled) {
        Write-LogInfo "Enabling Windows Subsystem for Linux..."
        Invoke-WithDryRun -Description "Enable WSL feature" -ScriptBlock {
            $null = Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux -NoRestart -WarningAction SilentlyContinue
        }
        $needsReboot = $true
    }

    if (-not $status.VMEnabled) {
        Write-LogInfo "Enabling Virtual Machine Platform..."
        Invoke-WithDryRun -Description "Enable VM Platform feature" -ScriptBlock {
            $null = Enable-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -NoRestart -WarningAction SilentlyContinue
        }
        $needsReboot = $true
    }

    # Set WSL2 as default
    Invoke-WithDryRun -Description "Set WSL2 as default" -ScriptBlock {
        $null = wsl --set-default-version 2 2>$null
    }

    if ($needsReboot -and -not $DryRun) {
        Write-LogSuccess "WSL2 features enabled (restart required)"
        return $true
    }

    Write-LogSuccess "WSL2 features configured"
    return $false
}

function Get-ExistingDistros {
    Write-LogStep "2/7" "Checking existing WSL distributions"

    try {
        # WSL outputs UTF-16LE which PowerShell may not handle well
        # Use Out-String to convert then clean up
        $rawOutput = wsl --list --verbose 2>&1
        $output = ($rawOutput | Out-String) -replace '\x00', '' -replace '\r', ''

        if ($LASTEXITCODE -ne 0 -or $output -match "no installed distributions") {
            Write-LogInfo "No WSL distributions found"
            return @()
        }

        # Parse the output (skip header line), trim whitespace
        $lines = @($output -split "`n" |
            Select-Object -Skip 1 |
            Where-Object { $_ -match '\S' } |
            ForEach-Object { $_.Trim() })

        if ($lines.Count -eq 0) {
            Write-LogInfo "No WSL distributions found"
            return @()
        }

        Write-LogInfo "Existing distributions:"
        Write-Host ""
        foreach ($line in $lines) {
            Write-Host "  $line" -ForegroundColor Gray
        }
        Write-Host ""

        return $lines
    }
    catch {
        Write-LogDebug "Error listing distros: $_"
        return @()
    }
}

function Install-WslDistro {
    param(
        [Parameter(Mandatory)]
        [string]$DistroKey
    )

    $distroInfo = $script:SUPPORTED_DISTROS[$DistroKey]
    $wslName = $distroInfo.WslName
    $displayName = $distroInfo.DisplayName

    Write-LogInfo "Installing $displayName..."
    Write-LogInfo "  WSL Name: $wslName"
    Write-LogInfo "  Support until: $($distroInfo.SupportUntil)"

    if ($DryRun) {
        Write-LogInfo "[DRY-RUN] Would execute: wsl --install -d $wslName --no-launch"
        return $wslName
    }

    try {
        # Check for and clean up broken existing installation
        $existingCheck = wsl --list --quiet 2>&1 | Out-String
        $existingCheck = $existingCheck -replace '\x00', ''
        if ($existingCheck -match "(?m)^$wslName\s*$") {
            # Distro exists - test if it's usable
            Write-LogDebug "Found existing $wslName, checking health..."
            $testResult = wsl -d $wslName -u root -- echo "health_check" 2>&1
            if ($LASTEXITCODE -ne 0) {
                Write-LogWarn "Found broken $wslName installation, removing before reinstall..."
                $null = wsl --unregister $wslName 2>$null
                Start-Sleep -Seconds 3
            } else {
                # Distro exists and is healthy - return it
                Write-LogInfo "Distro $wslName already exists and is healthy"
                return $wslName
            }
        }

        # Install without launching 
        Write-LogInfo "Attempting installation via wsl --install..."
        $output = wsl --install -d $wslName --no-launch 2>&1
        $exitCode = $LASTEXITCODE
        # Handle WSL's UTF-16LE output encoding
        $outputStr = ($output | Out-String) -replace '\x00', '' -replace '\r', ''

        # Log the result for debugging
        Write-LogInfo "Install result: exit code = $exitCode"
        if ($outputStr.Trim()) {
            Write-LogInfo "Output: $($outputStr.Trim().Substring(0, [Math]::Min(200, $outputStr.Trim().Length)))..."
        }

        # Check errors 
        $isSparseError = $outputStr -match "Sparse" -or $outputStr -match "VHD" -or $outputStr -match "corruption"
        $isFailure = $exitCode -ne 0

        if ($isSparseError -or $isFailure) {
            Write-LogWarn "Standard installation failed (sparse=$isSparseError, exitCode=$exitCode), trying alternative method..."

            # Shut down WSL 
            wsl --shutdown 2>$null
            Start-Sleep -Seconds 3

            # Try winget installation from Microsoft Store
            Write-LogInfo "Attempting installation via winget (Microsoft Store)..."
            $wingetId = switch ($wslName) {
                "Debian" { "Debian.Debian" }
                "Ubuntu-24.04" { "Canonical.Ubuntu.2404" }
                "Ubuntu" { "Canonical.Ubuntu.2404" }
                default { $null }
            }

            if ($wingetId) {
                $wingetOutput = winget install --id $wingetId --source msstore --accept-source-agreements --accept-package-agreements --disable-interactivity 2>&1
                $wingetExitCode = $LASTEXITCODE
                $wingetStr = ($wingetOutput | Out-String)
                Write-LogInfo "Winget result: exit code = $wingetExitCode"

                if ($wingetExitCode -eq 0 -or $wingetStr -match "successfully installed" -or $wingetStr -match "already installed") {
                    Write-LogSuccess "Installed via Microsoft Store"
                    Start-Sleep -Seconds 5
                }
                else {
                    # Last resort: try wsl --install without --no-launch
                    Write-LogWarn "Winget failed, trying wsl --install without --no-launch..."
                    wsl --shutdown 2>$null
                    Start-Sleep -Seconds 3
                    $output = wsl --install -d $wslName 2>&1
                    $outputStr = ($output | Out-String) -replace '\x00', '' -replace '\r', ''
                    $exitCode = $LASTEXITCODE

                    if ($exitCode -ne 0) {
                        throw "All installation methods failed. Last error: $outputStr"
                    }
                }
            }
            else {
                throw "No alternative installation method available for: $wslName"
            }
        }
        elseif ($exitCode -ne 0) {
            throw "wsl --install failed: $outputStr"
        }

        # Wait for installation to complete
        Write-LogInfo "Waiting for distribution to be ready..."
        Start-Sleep -Seconds 5

        # Verify distro is registered in WSL
        $maxRetries = 6
        $distroRegistered = $false

        for ($retry = 0; $retry -lt $maxRetries; $retry++) {
            $listOutput = wsl --list --quiet 2>&1 | Out-String
            $listOutput = $listOutput -replace '\x00', ''
            if ($listOutput -match "(?m)^$wslName\s*$") {
                $distroRegistered = $true
                Write-LogDebug "Distro verified in wsl --list after $($retry + 1) attempt(s)"
                break
            }
            if ($retry -lt ($maxRetries - 1)) {
                Write-LogDebug "Distro not yet visible, waiting... (attempt $($retry + 1)/$maxRetries)"
                Start-Sleep -Seconds 5
            }
        }

        if (-not $distroRegistered) {
            throw "Distribution $wslName not found in wsl --list after installation"
        }

        Write-LogSuccess "$displayName installed successfully"
        return $wslName
    }
    catch {
        Exit-WithError "Failed to install $displayName`: $_" $script:EXIT_DISTRO_FAILED
    }
}

function Initialize-WslDistro {
    param(
        [Parameter(Mandatory)]
        [string]$WslDistroName
    )

    Write-LogStep "3/7" "Configuring Linux environment"

    # Derive Unix username from Windows username
    $winUser = $env:USERNAME
    $unixUser = $winUser.ToLower() -replace '[^a-z0-9_-]', '' -replace '^[0-9-]', '_'

    if ($unixUser.Length -gt 32) {
        $unixUser = $unixUser.Substring(0, 32)
    }

    if ($unixUser.Length -eq 0) {
        $unixUser = "user"
    }

    Write-LogInfo "Unix username: $unixUser (derived from: $winUser)"

    # Find setup scripts
    $scriptDir = Split-Path -Parent $PSCommandPath
    $setupScript = Join-Path $scriptDir "setup-wsl-devcontainers.sh"
    $dockerScript = Join-Path $scriptDir "install-docker.sh"
    $githubScript = Join-Path $scriptDir "install-github-cli.sh"
    $shellScript = Join-Path $scriptDir "install-shell-customization.sh"
    $p10kConfig = Join-Path $scriptDir "p10k.zsh"
    $zshPluginsConfig = Join-Path $scriptDir "zsh_plugins.txt"

    if (-not (Test-Path $setupScript)) {
        Exit-WithError "setup-wsl-devcontainers.sh not found at: $setupScript" $script:EXIT_GENERAL_ERROR
    }

    if (-not (Test-Path $dockerScript)) {
        Exit-WithError "install-docker.sh not found at: $dockerScript" $script:EXIT_GENERAL_ERROR
    }

    $hasGithubScript = Test-Path $githubScript
    if (-not $hasGithubScript) {
        Write-LogWarn "install-github-cli.sh not found - GitHub CLI setup will be skipped"
    }

    $hasShellScript = Test-Path $shellScript
    if (-not $hasShellScript) {
        Write-LogWarn "install-shell-customization.sh not found - Shell customization will be skipped"
    }

    $hasP10kConfig = Test-Path $p10kConfig
    if ($hasShellScript -and -not $hasP10kConfig) {
        Write-LogWarn "p10k.zsh not found - Default Powerlevel10k config will be generated"
    }

    $hasZshPluginsConfig = Test-Path $zshPluginsConfig
    if ($hasShellScript -and -not $hasZshPluginsConfig) {
        Write-LogWarn "zsh_plugins.txt not found - Shell customization may fail"
    }

    if ($DryRun) {
        Write-LogInfo "[DRY-RUN] Would copy and execute setup scripts in WSL"
        Write-LogInfo "[DRY-RUN] setup-wsl-devcontainers.sh --user $unixUser"
        return
    }

    try {
        Write-LogInfo "Initializing WSL distribution..."
        $maxProbeRetries = 5
        $probeDelay = 2
        $wslReady = $false

        for ($i = 0; $i -lt $maxProbeRetries; $i++) {
            $initResult = wsl -d $WslDistroName -u root -- echo "WSL_READY" 2>&1
            $initStr = ($initResult | Out-String) -replace '\x00', '' -replace '\r', ''

            if ($LASTEXITCODE -eq 0 -and $initStr -match "WSL_READY") {
                $wslReady = $true
                Write-LogDebug "WSL ready after $($i + 1) probe(s)"
                break
            }

            if ($i -lt ($maxProbeRetries - 1)) {
                Write-LogWarn "WSL probe attempt $($i + 1)/$maxProbeRetries failed: $initStr"
                Start-Sleep -Seconds $probeDelay
                $probeDelay = [Math]::Min($probeDelay * 2, 15)
            }
        }

        if (-not $wslReady) {
            throw "WSL distribution $WslDistroName failed to respond after $maxProbeRetries attempts"
        }

        $null = wsl -d $WslDistroName -u root -- mkdir -p /tmp 2>$null
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to create /tmp directory in WSL"
        }

        # Copy scripts to WSL via Windows filesystem
        Write-LogInfo "Copying setup scripts to WSL..."

        $tempDir = Join-Path $env:TEMP "wsl-devcontainers-$(Get-Random)"

        # Validate local drive (required for WSL path conversion)
        # UNC paths like \\server\share won't work with WSL /mnt/ mapping
        if ($tempDir -notmatch '^[A-Za-z]:\\') {
            $tempDir = Join-Path $env:SystemDrive "Temp\wsl-devcontainers-$(Get-Random)"
            Write-LogWarn "TEMP is not on local drive, using: $tempDir"
        }

        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

        try {
            # Read files as raw bytes to avoid PowerShell string manipulation issues
            $setupBytes = [System.IO.File]::ReadAllBytes($setupScript)
            $dockerBytes = [System.IO.File]::ReadAllBytes($dockerScript)
            $githubBytes = $null
            if ($hasGithubScript) {
                $githubBytes = [System.IO.File]::ReadAllBytes($githubScript)
            }

            $shellBytes = $null
            if ($hasShellScript) {
                $shellBytes = [System.IO.File]::ReadAllBytes($shellScript)
            }

            $p10kBytes = $null
            if ($hasP10kConfig) {
                $p10kBytes = [System.IO.File]::ReadAllBytes($p10kConfig)
            }

            $zshPluginsBytes = $null
            if ($hasZshPluginsConfig) {
                $zshPluginsBytes = [System.IO.File]::ReadAllBytes($zshPluginsConfig)
            }

            Write-LogDebug "Setup script: $($setupBytes.Length) bytes"
            Write-LogDebug "Docker script: $($dockerBytes.Length) bytes"
            if ($githubBytes) {
                Write-LogDebug "GitHub CLI script: $($githubBytes.Length) bytes"
            }
            if ($shellBytes) {
                Write-LogDebug "Shell customization script: $($shellBytes.Length) bytes"
            }
            if ($p10kBytes) {
                Write-LogDebug "P10k config: $($p10kBytes.Length) bytes"
            }
            if ($zshPluginsBytes) {
                Write-LogDebug "Zsh plugins config: $($zshPluginsBytes.Length) bytes"
            }

            # Write files to temp directory
            $tempSetupPath = Join-Path $tempDir "setup-wsl-devcontainers.sh"
            $tempDockerPath = Join-Path $tempDir "install-docker.sh"
            $tempGithubPath = $null

            [System.IO.File]::WriteAllBytes($tempSetupPath, $setupBytes)
            [System.IO.File]::WriteAllBytes($tempDockerPath, $dockerBytes)
            if ($githubBytes) {
                $tempGithubPath = Join-Path $tempDir "install-github-cli.sh"
                [System.IO.File]::WriteAllBytes($tempGithubPath, $githubBytes)
            }

            $tempShellPath = $null
            if ($shellBytes) {
                $tempShellPath = Join-Path $tempDir "install-shell-customization.sh"
                [System.IO.File]::WriteAllBytes($tempShellPath, $shellBytes)
            }

            $tempP10kPath = $null
            if ($p10kBytes) {
                $tempP10kPath = Join-Path $tempDir "p10k.zsh"
                [System.IO.File]::WriteAllBytes($tempP10kPath, $p10kBytes)
            }

            $tempZshPluginsPath = $null
            if ($zshPluginsBytes) {
                $tempZshPluginsPath = Join-Path $tempDir "zsh_plugins.txt"
                [System.IO.File]::WriteAllBytes($tempZshPluginsPath, $zshPluginsBytes)
            }

            # Convert Windows path to WSL path 
            $wslTempDir = "/mnt/" + $tempDir.Substring(0,1).ToLower() + $tempDir.Substring(2).Replace('\', '/')
            Write-LogDebug "WSL temp path: $wslTempDir"

            # Copy files to /tmp in WSL and fix line endings
            Write-LogDebug "Copying and converting line endings..."
            wsl -d $WslDistroName -u root -- sh -c "cat '$wslTempDir/setup-wsl-devcontainers.sh' | tr -d '\r' > /tmp/setup-wsl-devcontainers.sh"
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to copy setup-wsl-devcontainers.sh to WSL"
            }

            wsl -d $WslDistroName -u root -- sh -c "cat '$wslTempDir/install-docker.sh' | tr -d '\r' > /tmp/install-docker.sh"
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to copy install-docker.sh to WSL"
            }

            if ($tempGithubPath) {
                wsl -d $WslDistroName -u root -- sh -c "cat '$wslTempDir/install-github-cli.sh' | tr -d '\r' > /tmp/install-github-cli.sh"
                if ($LASTEXITCODE -ne 0) {
                    throw "Failed to copy install-github-cli.sh to WSL"
                }
            }

            if ($tempShellPath) {
                wsl -d $WslDistroName -u root -- sh -c "cat '$wslTempDir/install-shell-customization.sh' | tr -d '\r' > /tmp/install-shell-customization.sh"
                if ($LASTEXITCODE -ne 0) {
                    Write-LogWarn "Failed to copy install-shell-customization.sh to WSL"
                }
            }

            if ($tempP10kPath) {
                wsl -d $WslDistroName -u root -- sh -c "cat '$wslTempDir/p10k.zsh' | tr -d '\r' > /tmp/p10k.zsh"
                if ($LASTEXITCODE -ne 0) {
                    Write-LogWarn "Failed to copy p10k.zsh to WSL"
                }
            }

            if ($tempZshPluginsPath) {
                wsl -d $WslDistroName -u root -- sh -c "cat '$wslTempDir/zsh_plugins.txt' | tr -d '\r' > /tmp/zsh_plugins.txt"
                if ($LASTEXITCODE -ne 0) {
                    Write-LogWarn "Failed to copy zsh_plugins.txt to WSL"
                }
            }

            # Verify files exist
            $verifyResult = wsl -d $WslDistroName -u root -- ls -la /tmp/*.sh 2>&1
            $verifyStr = ($verifyResult | Out-String) -replace '\x00', '' -replace '\r', ''
            Write-LogDebug "Scripts in /tmp: $verifyStr"

            if ($verifyStr -notmatch "setup-wsl-devcontainers.sh" -or $verifyStr -notmatch "install-docker.sh") {
                throw "Script files not found in WSL after transfer"
            }

            # Verify the critical function name exists in the docker script (catches truncation issues)
            $validateCheck = wsl -d $WslDistroName -u root -- grep -c 'validate_user' /tmp/install-docker.sh 2>$null
            $validateCount = ($validateCheck | Out-String).Trim() -replace '\x00', ''
            Write-LogDebug "validate_user occurrences: $validateCount"
            if ([int]$validateCount -lt 3) {
                throw "File integrity check failed: install-docker.sh appears to be corrupted (validate_user count: $validateCount)"
            }

            # Make scripts executable - verify each file and chmod individually
            Write-LogDebug "Setting execute permissions..."
            $chmodScripts = @("/tmp/setup-wsl-devcontainers.sh", "/tmp/install-docker.sh")
            if ($tempGithubPath) {
                $chmodScripts += "/tmp/install-github-cli.sh"
            }
            if ($tempShellPath) {
                $chmodScripts += "/tmp/install-shell-customization.sh"
            }

            foreach ($scriptPath in $chmodScripts) {
                $null = wsl -d $WslDistroName -u root -- test -f $scriptPath
                if ($LASTEXITCODE -ne 0) {
                    throw "Script file not found in WSL: $scriptPath"
                }
                $null = wsl -d $WslDistroName -u root -- chmod +x $scriptPath
                if ($LASTEXITCODE -ne 0) {
                    throw "Failed to set execute permission on: $scriptPath"
                }
                Write-LogDebug "Made executable: $scriptPath"
            }
        }
        finally {
            # Clean up temp directory
            Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }

        # Run setup script as root
        Write-LogInfo "Running Linux setup script..."
        Write-LogInfo "This may take several minutes..."

        # Build argument list
        $argList = @("-d", $WslDistroName, "-u", "root", "--", "/tmp/setup-wsl-devcontainers.sh", "--user", $unixUser)
        if ($VerbosePreference -eq 'Continue') {
            $argList += "--verbose"
        }

        # Execute with output streaming
        $process = Start-Process -FilePath "wsl.exe" `
            -ArgumentList $argList `
            -NoNewWindow -Wait -PassThru

        if ($process.ExitCode -ne 0) {
            throw "Linux setup failed with exit code: $($process.ExitCode)"
        }

        # Set the distro as default
        Write-LogInfo "Setting $WslDistroName as default WSL distribution..."
        $null = wsl --set-default $WslDistroName 2>$null

        Write-LogSuccess "Linux environment configured"
    }
    catch {
        Write-LogError "Linux environment configuration failed: $_"

        # Attempt to clean up the broken distro to allow fresh retry
        Write-LogWarn "Cleaning up failed installation..."
        $null = wsl --unregister $WslDistroName 2>$null

        # Clear registry state
        Clear-SetupState

        Exit-WithError "Linux setup failed: $_" $script:EXIT_DISTRO_FAILED
    }
}

#-------------------------------------------------------------------------------
# Windows Application Functions
#-------------------------------------------------------------------------------
function Test-WingetAvailable {
    try {
        $null = Get-Command winget -ErrorAction Stop
        return $true
    }
    catch {
        return $false
    }
}

function Install-WindowsTerminal {
    Write-LogStep "4/7" "Checking Windows Terminal"

    try {
        $terminal = Get-AppxPackage -Name "Microsoft.WindowsTerminal" -ErrorAction SilentlyContinue
        if ($terminal) {
            Write-LogSuccess "Windows Terminal already installed (v$($terminal.Version))"
            return
        }
    }
    catch {
        Write-LogDebug "Error checking for Windows Terminal: $_"
    }

    if (-not (Test-WingetAvailable)) {
        Write-LogWarn "winget not available - cannot install Windows Terminal"
        Write-LogWarn "Install manually from Microsoft Store"
        return
    }

    Write-LogInfo "Installing Windows Terminal via winget..."

    if ($DryRun) {
        Write-LogInfo "[DRY-RUN] Would execute: winget install --id Microsoft.WindowsTerminal"
        return
    }

    try {
        $output = winget install --id Microsoft.WindowsTerminal `
            --accept-source-agreements --accept-package-agreements `
            --silent --disable-interactivity 2>&1

        if ($LASTEXITCODE -eq 0) {
            Write-LogSuccess "Windows Terminal installed"
        }
        else {
            Write-LogWarn "Windows Terminal installation returned code $LASTEXITCODE"
            Write-LogDebug "Output: $output"
        }
    }
    catch {
        Write-LogWarn "Windows Terminal installation failed: $_"
        Write-LogWarn "Install manually from Microsoft Store"
    }
}

function Install-MesloLGSNFFont {
    Write-LogStep "5/7" "Installing MesloLGS NF Font"

    if (-not $PSScriptRoot) {
        Write-LogWarn "Could not determine script directory"
        Write-LogWarn "Font installation skipped - run script from file to install fonts"
        return
    }
    $scriptDir = $PSScriptRoot

    # Check if any font files exist
    $fontsFound = @()
    foreach ($fontFile in $script:MESLO_FONT_FILES) {
        $fontPath = Join-Path $scriptDir $fontFile
        if (Test-Path $fontPath) {
            $fontsFound += $fontPath
        }
        else {
            Write-LogDebug "Font file not found: $fontPath"
        }
    }

    if ($fontsFound.Count -eq 0) {
        Write-LogWarn "No MesloLGS NF font files found in script directory"
        Write-LogWarn "Expected location: $scriptDir"
        return
    }

    if ($DryRun) {
        Write-LogInfo "[DRY-RUN] Would install $($fontsFound.Count) MesloLGS NF font(s) system-wide"
        return
    }

    Write-LogInfo "Installing $($fontsFound.Count) font file(s) system-wide..."

    # System-wide font installation (requires admin, which we have via #Requires)
    # Since Windows 10 1809, Shell.Application.CopyHere installs to per-user location
    # For system-wide, we copy to C:\Windows\Fonts and register in HKLM
    $systemFontsPath = Join-Path $env:windir "Fonts"
    $regPath = "HKLM:\Software\Microsoft\Windows NT\CurrentVersion\Fonts"
    $installedCount = 0

    foreach ($fontPath in $fontsFound) {
        $fontFileName = [System.IO.Path]::GetFileName($fontPath)
        $destPath = Join-Path $systemFontsPath $fontFileName

        try {
            # Copy font file to system fonts folder
            Copy-Item -Path $fontPath -Destination $destPath -Force -ErrorAction Stop
            Write-LogDebug "Copied font to: $destPath"

            # Get font name for registry using Shell COM
            $shell = New-Object -ComObject Shell.Application
            $folder = $shell.Namespace([System.IO.Path]::GetDirectoryName($fontPath))
            $file = $folder.ParseName($fontFileName)
            $fontTitle = $folder.GetDetailsOf($file, 21)  # Property 21 = Title/Font Name

            if (-not $fontTitle -or $fontTitle -eq "") {
                # Fallback to filename without extension
                $fontTitle = [System.IO.Path]::GetFileNameWithoutExtension($fontPath)
            }

            # Register in system registry (font name + " (TrueType)" -> filename)
            $regName = "$fontTitle (TrueType)"
            Set-ItemProperty -Path $regPath -Name $regName -Value $fontFileName -ErrorAction Stop
            Write-LogDebug "Registered font: $regName -> $fontFileName"

            $installedCount++
        }
        catch {
            Write-LogWarn "Failed to install font $fontFileName : $_"
        }
        finally {
            # Release COM object
            if ($shell) {
                [System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell) | Out-Null
            }
        }
    }

    if ($installedCount -gt 0) {
        Write-LogSuccess "MesloLGS NF fonts installed system-wide ($installedCount files)"
        Write-LogInfo "Note: You may need to restart applications for fonts to appear"
    }
    else {
        Write-LogWarn "No fonts were installed successfully"
    }

    # Configure terminals to use the font
    Set-WindowsTerminalFont
    Set-VSCodeTerminalFont
}

function Set-WindowsTerminalFont {
    Write-LogInfo "Configuring Windows Terminal font..."

    # Windows Terminal has multiple possible locations depending on installation method
    $wtPossiblePaths = @(
        # Store version (stable) - installed by winget
        (Join-Path $env:LOCALAPPDATA "Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json")
        # Store version (preview)
        (Join-Path $env:LOCALAPPDATA "Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState\settings.json")
        # Unpackaged (Scoop, Chocolatey, etc.)
        (Join-Path $env:LOCALAPPDATA "Microsoft\Windows Terminal\settings.json")
    )

    $wtSettingsPath = $wtPossiblePaths | Where-Object { Test-Path $_ } | Select-Object -First 1

    if (-not $wtSettingsPath) {
        Write-LogWarn "Windows Terminal settings not found"
        Write-LogWarn "Open Windows Terminal once, then re-run with -Force to configure font"
        return
    }

    if ($DryRun) {
        Write-LogInfo "[DRY-RUN] Would update Windows Terminal font to $($script:MESLO_FONT_NAME)"
        return
    }

    try {
        # Backup existing settings
        $backupPath = "$wtSettingsPath.backup"
        Copy-Item $wtSettingsPath $backupPath -Force
        Write-LogDebug "Backed up Windows Terminal settings to $backupPath"

        # Read and parse settings
        $settingsContent = Get-Content $wtSettingsPath -Raw -Encoding UTF8
        $settings = $settingsContent | ConvertFrom-Json

        # Ensure profiles.defaults exists
        if (-not $settings.profiles) {
            $settings | Add-Member -NotePropertyName profiles -NotePropertyValue ([PSCustomObject]@{}) -Force
        }
        if (-not $settings.profiles.defaults) {
            $settings.profiles | Add-Member -NotePropertyName defaults -NotePropertyValue ([PSCustomObject]@{}) -Force
        }

        # Set font configuration (v1.10+ style with font object)
        $fontConfig = [PSCustomObject]@{
            face = $script:MESLO_FONT_NAME
        }

        if ($settings.profiles.defaults.font) {
            $settings.profiles.defaults.font | Add-Member -NotePropertyName face -NotePropertyValue $script:MESLO_FONT_NAME -Force
        }
        else {
            $settings.profiles.defaults | Add-Member -NotePropertyName font -NotePropertyValue $fontConfig -Force
        }

        # Write back with proper formatting
        $settingsJson = $settings | ConvertTo-Json -Depth 10
        Set-Content -Path $wtSettingsPath -Value $settingsJson -Encoding UTF8

        Write-LogSuccess "Windows Terminal configured to use $($script:MESLO_FONT_NAME)"
    }
    catch {
        Write-LogWarn "Failed to configure Windows Terminal font: $_"
        # Restore backup if it exists
        if (Test-Path $backupPath) {
            Copy-Item $backupPath $wtSettingsPath -Force
            Write-LogDebug "Restored Windows Terminal settings from backup"
        }
    }
}

function Set-VSCodeTerminalFont {
    Write-LogInfo "Configuring VS Code terminal font..."

    $vscodeSettingsDir = Join-Path $env:APPDATA "Code\User"
    $vscodeSettingsPath = Join-Path $vscodeSettingsDir "settings.json"

    if ($DryRun) {
        Write-LogInfo "[DRY-RUN] Would update VS Code terminal font to $($script:MESLO_FONT_NAME)"
        return
    }

    try {
        # Create directory if needed
        if (-not (Test-Path $vscodeSettingsDir)) {
            New-Item -ItemType Directory -Path $vscodeSettingsDir -Force | Out-Null
        }

        $fontSettingName = 'terminal.integrated.fontFamily'
        $fontSettingValue = $script:MESLO_FONT_NAME

        if (-not (Test-Path $vscodeSettingsPath)) {
            # No existing settings - create minimal file
            $newSettings = @{ $fontSettingName = $fontSettingValue }
            $newSettings | ConvertTo-Json -Depth 10 | Set-Content -Path $vscodeSettingsPath -Encoding UTF8
            Write-LogSuccess "VS Code settings created with $($script:MESLO_FONT_NAME) font"
            return
        }

        # Backup existing settings
        $backupPath = "$vscodeSettingsPath.backup.$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        Copy-Item $vscodeSettingsPath $backupPath -Force
        Write-LogDebug "Backed up VS Code settings to $backupPath"

        $settingsContent = Get-Content $vscodeSettingsPath -Raw -Encoding UTF8

        if ([string]::IsNullOrWhiteSpace($settingsContent)) {
            # Empty file - create new
            $newSettings = @{ $fontSettingName = $fontSettingValue }
            $newSettings | ConvertTo-Json -Depth 10 | Set-Content -Path $vscodeSettingsPath -Encoding UTF8
            Write-LogSuccess "VS Code settings created with $($script:MESLO_FONT_NAME) font"
            return
        }

        # Try standard JSON parsing first
        try {
            $settings = @{}
            $parsed = $settingsContent | ConvertFrom-Json -ErrorAction Stop

            # Convert PSCustomObject to hashtable
            $parsed.PSObject.Properties | ForEach-Object {
                $settings[$_.Name] = $_.Value
            }

            # Update font setting
            $settings[$fontSettingName] = $fontSettingValue

            # Write back (depth 10 is safe for VS Code settings)
            $settingsJson = $settings | ConvertTo-Json -Depth 10
            Set-Content -Path $vscodeSettingsPath -Value $settingsJson -Encoding UTF8

            Write-LogSuccess "VS Code terminal configured to use $($script:MESLO_FONT_NAME)"
        }
        catch {
            # File contains JSONC (comments) or is malformed
            # Use safe targeted insertion that doesn't corrupt existing content
            # NEVER use naive regex to strip comments - it corrupts URLs like https://
            Write-LogDebug "VS Code settings contains comments or is non-standard JSON, using safe insertion"

            $settingPattern = [regex]::Escape("`"$fontSettingName`"")

            if ($settingsContent -match $settingPattern) {
                # Setting exists - update it with precise regex
                $replacePattern = "(`"$([regex]::Escape($fontSettingName))`"\s*:\s*)(`"[^`"]*`"|'[^']*')"
                $settingsContent = $settingsContent -replace $replacePattern, "`$1`"$fontSettingValue`""
            }
            else {
                # Setting doesn't exist - insert after first {
                # Find position after opening brace, preserving any comments
                if ($settingsContent -match '^\s*\{') {
                    $insertPos = $settingsContent.IndexOf('{') + 1
                    $indent = "    "
                    $newSetting = "`n$indent`"$fontSettingName`": `"$fontSettingValue`","
                    $settingsContent = $settingsContent.Insert($insertPos, $newSetting)
                }
                else {
                    Write-LogWarn "Could not parse VS Code settings structure"
                    return
                }
            }

            Set-Content -Path $vscodeSettingsPath -Value $settingsContent -Encoding UTF8
            Write-LogSuccess "VS Code terminal configured to use $($script:MESLO_FONT_NAME) (preserved comments)"
        }
    }
    catch {
        Write-LogWarn "Failed to configure VS Code font: $_"
        Write-LogWarn "You can manually add: `"terminal.integrated.fontFamily`": `"$($script:MESLO_FONT_NAME)`""
    }
}

function Install-VSCode {
    Write-LogStep "6/7" "Checking VS Code"

    # Check common installation paths
    $vscodePaths = @(
        "$env:LOCALAPPDATA\Programs\Microsoft VS Code\Code.exe"
        "$env:ProgramFiles\Microsoft VS Code\Code.exe"
        "${env:ProgramFiles(x86)}\Microsoft VS Code\Code.exe"
    )

    foreach ($path in $vscodePaths) {
        if (Test-Path $path) {
            $version = (Get-Item $path).VersionInfo.ProductVersion
            Write-LogSuccess "VS Code already installed (v$version)"
            return $path
        }
    }

    try {
        $codePath = (Get-Command code -ErrorAction SilentlyContinue).Source
        if ($codePath) {
            Write-LogSuccess "VS Code already installed: $codePath"
            return $codePath
        }
    }
    catch { }

    if (-not (Test-WingetAvailable)) {
        Exit-WithError "winget not available and VS Code not found. Install VS Code manually." $script:EXIT_WINGET_FAILED
    }

    Write-LogInfo "Installing VS Code via winget..."

    if ($DryRun) {
        Write-LogInfo "[DRY-RUN] Would execute: winget install --id Microsoft.VisualStudioCode"
        return $null
    }

    try {
        $output = winget install --id Microsoft.VisualStudioCode `
            --accept-source-agreements --accept-package-agreements `
            --silent --disable-interactivity 2>&1

        if ($LASTEXITCODE -eq 0) {
            Write-LogSuccess "VS Code installed"

            # Refresh PATH
            $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
                        [System.Environment]::GetEnvironmentVariable("Path", "User")

            return "$env:LOCALAPPDATA\Programs\Microsoft VS Code\Code.exe"
        }
        else {
            throw "winget returned code $LASTEXITCODE"
        }
    }
    catch {
        Exit-WithError "VS Code installation failed: $_" $script:EXIT_WINGET_FAILED
    }
}

function Install-VSCodeExtensions {
    Write-LogStep "7/7" "Installing VS Code extensions"

    # Refresh PATH to ensure code is available
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
                [System.Environment]::GetEnvironmentVariable("Path", "User")

    $codePath = $null
    try {
        $codePath = (Get-Command code -ErrorAction Stop).Source
    }
    catch {
        # Try common paths
        $paths = @(
            "$env:LOCALAPPDATA\Programs\Microsoft VS Code\bin\code.cmd"
            "$env:ProgramFiles\Microsoft VS Code\bin\code.cmd"
        )
        foreach ($path in $paths) {
            if (Test-Path $path) {
                $codePath = $path
                break
            }
        }
    }

    if (-not $codePath) {
        Write-LogWarn "VS Code 'code' command not found in PATH"
        Write-LogWarn "Extensions must be installed manually"
        Write-LogInfo "Required extensions:"
        foreach ($ext in $script:VSCODE_EXTENSIONS) {
            Write-LogInfo "  - $ext"
        }
        return
    }

    Write-LogInfo "Installing DevContainers extensions..."

    foreach ($ext in $script:VSCODE_EXTENSIONS) {
        Write-LogInfo "  Installing: $ext"

        if ($DryRun) {
            Write-LogInfo "  [DRY-RUN] Would execute: code --install-extension $ext"
            continue
        }

        try {
            $output = & $codePath --install-extension $ext --force 2>&1

            if ($LASTEXITCODE -eq 0) {
                Write-LogSuccess "    Installed: $ext"
            }
            else {
                Write-LogWarn "    Failed to install $ext (code $LASTEXITCODE)"
            }
        }
        catch {
            Write-LogWarn "    Error installing $ext`: $_"
        }
    }

    Write-LogSuccess "VS Code extensions configured"
}

#-------------------------------------------------------------------------------
# Help
#-------------------------------------------------------------------------------
function Show-Help {
    $help = @"

$($script:SCRIPT_NAME) v$($script:SCRIPT_VERSION) - DevContainers setup for Windows 11

USAGE:
    .\$($script:SCRIPT_NAME) [OPTIONS]

OPTIONS:
    -Distro <name>     Distribution to install: Debian (default) or Ubuntu
    -Resume            Resume setup after reboot
    -DryRun            Preview without making changes
    -NonInteractive    Skip all prompts, use defaults
    -SkipApps          Skip Windows Terminal/VS Code installation
    -SkipFonts         Skip MesloLGS NF font installation
    -Force             Overwrite existing configuration
    -Verbose           Enable verbose output
    -Help              Show this help message

SUPPORTED DISTRIBUTIONS:
    Debian    Debian 13 Trixie (default) - support until 2030
    Ubuntu    Ubuntu 24.04 LTS - support until 2029

EXAMPLES:
    # Standard setup with Debian (default)
    .\$($script:SCRIPT_NAME)

    # Setup with Ubuntu
    .\$($script:SCRIPT_NAME) -Distro Ubuntu

    # Preview what would happen
    .\$($script:SCRIPT_NAME) -DryRun -Verbose

    # Fully automated (no prompts)
    .\$($script:SCRIPT_NAME) -NonInteractive

    # Skip Windows apps (Terminal/VS Code)
    .\$($script:SCRIPT_NAME) -SkipApps

WHAT THIS SCRIPT DOES:
    1. Enables WSL2 Windows features (may require reboot)
    2. Installs selected Linux distribution
    3. Creates user with passwordless sudo
    4. Configures WSL for optimal DevContainers performance
    5. Installs Docker Engine (native, not Docker Desktop)
    6. Installs GitHub CLI and configures Git authentication (SSH keys)
    7. Installs Windows Terminal (via winget)
    8. Installs MesloLGS NF font for Powerlevel10k theme
    9. Installs VS Code with DevContainers extensions

REQUIREMENTS:
    - Windows 11 22H2+ (or Windows 10 2004+)
    - Administrator privileges
    - Internet connection
    - setup-wsl-devcontainers.sh in same directory
    - install-docker.sh in same directory
    - install-github-cli.sh in same directory (optional, for GitHub auth)

LOG FILE:
    $($script:LOG_FILE)

"@

    Write-Host $help
}

#-------------------------------------------------------------------------------
# Main Execution
#-------------------------------------------------------------------------------
function Show-Summary {
    param([string]$WslDistroName)

    Write-Host ""
    Write-Host "===============================================================" -ForegroundColor Green
    Write-Host "                    SETUP COMPLETE" -ForegroundColor Green
    Write-Host "===============================================================" -ForegroundColor Green
    Write-Host ""

    if ($DryRun) {
        Write-LogInfo "Mode: DRY-RUN (no changes made)"
        Write-Host ""
    }

    Write-LogInfo "Distribution:        $($script:SUPPORTED_DISTROS[$Distro].DisplayName)"
    Write-LogInfo "WSL Name:            $WslDistroName"
    Write-LogInfo "VS Code Extensions:  $($script:VSCODE_EXTENSIONS -join ', ')"
    Write-LogInfo "Log file:            $script:LOG_FILE"
    Write-Host ""

    Write-Host "NEXT STEPS:" -ForegroundColor Yellow
    Write-Host "  1. Open Windows Terminal" -ForegroundColor White
    Write-Host "  2. Select '$WslDistroName' from dropdown (or type: wsl)" -ForegroundColor White
    Write-Host "  3. Test Docker: docker run hello-world" -ForegroundColor White
    Write-Host "  4. Open VS Code: code ." -ForegroundColor White
    Write-Host "  5. Use 'Dev Containers: Reopen in Container' command" -ForegroundColor White
    Write-Host ""

    Write-Host "BEST PRACTICES:" -ForegroundColor Cyan
    Write-Host "  - Store projects in ~/projects (Linux filesystem)" -ForegroundColor White
    Write-Host "  - Avoid /mnt/c for active development (slow)" -ForegroundColor White
    Write-Host "  - Use .devcontainer/ configs in your repos" -ForegroundColor White
    Write-Host ""
}

function Main {
    if ($Help) {
        Show-Help
        exit $script:EXIT_SUCCESS
    }

    # Initialize logging
    Initialize-Logging

    # Acquire exclusive mutex lock (prevents concurrent execution)
    if (-not (Enter-ScriptLock)) {
        Exit-WithError "Another instance of this script is already running" $script:EXIT_GENERAL_ERROR
    }

    Write-Host ""
    Write-LogInfo "==============================================================="
    Write-LogInfo "  DevContainers Setup for Windows 11 v$script:SCRIPT_VERSION"
    Write-LogInfo "  PowerShell $($PSVersionTable.PSVersion) | Started: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    Write-LogInfo "==============================================================="

    if ($DryRun) {
        Write-LogWarn "DRY-RUN MODE: No changes will be made"
    }

    # Check for administrator privileges (also enforced by #Requires -RunAsAdministrator)
    if (-not (Test-Administrator)) {
        Write-Host ""
        Write-LogError "This script requires Administrator privileges."
        Write-LogError "Right-click PowerShell and select 'Run as Administrator'"
        Write-Host ""
        exit $script:EXIT_NOT_ADMIN
    }

    Write-LogSuccess "Running as Administrator"

    # Check BIOS virtualization early
    $virtCheck = Test-VirtualizationEnabled
    if (-not $virtCheck.Enabled) {
        Exit-WithError $virtCheck.Message $script:EXIT_GENERAL_ERROR
    }
    Write-LogDebug "Virtualization check: $($virtCheck.Message)"

    # Check for resume state
    if ($Resume) {
        $state = Get-SetupState
        if ($state) {
            Write-LogInfo "Resuming setup from Phase $($state.Phase)..."
            $Distro = $state.Distro

            # Skip to appropriate phase
            if ($state.Phase -ge 2) {
                Write-LogInfo "WSL2 features already enabled"
            }
        }
        else {
            Write-LogWarn "No saved state found, starting fresh"
            Clear-SetupState
        }
    }

    $distroInfo = $script:SUPPORTED_DISTROS[$Distro]
    Write-LogInfo "Selected distribution: $($distroInfo.DisplayName)"

    # Enable WSL2
    $needsReboot = Enable-WSL2Features

    if ($needsReboot) {
        Request-Reboot -NextPhase 2 -SelectedDistro $Distro
        return  # Won't reach here normally
    }

    # Configure .wslconfig 
    Initialize-WslConfig

    # Check existing distros and install if needed
    $existingDistros = Get-ExistingDistros
    $wslDistroName = $distroInfo.WslName

    # Check if selected distro already exists
    $distroExists = $existingDistros | Where-Object {
        $line = $_.Trim()
        $line = $line -replace '^\*\s*', ''
        $line -match "^$wslDistroName\s+"
    }

    Write-LogDebug "Distro detection: looking for '$wslDistroName', found: $($distroExists -ne $null)"

    $skipConfiguration = $false

    if ($distroExists -and -not $Force) {
        Write-LogInfo "$($distroInfo.DisplayName) is already installed"

        if (-not $NonInteractive) {
            $reconfigure = Get-Confirmation -Prompt "Reconfigure existing installation?" -Default $true
            if (-not $reconfigure) {
                Write-LogInfo "Skipping configuration - using existing installation"
                $skipConfiguration = $true
            }
        }
    }
    else {
        # Distro doesn't exist - install it
        $wslDistroName = Install-WslDistro -DistroKey $Distro
    }

    # Configure Linux environment
    if (-not $skipConfiguration) {
        Initialize-WslDistro -WslDistroName $wslDistroName
    }

    # Windows applications
    if (-not $SkipApps) {
        Install-WindowsTerminal

        # Install MesloLGS NF font for Powerlevel10k
        if (-not $SkipFonts) {
            Install-MesloLGSNFFont
        }
        else {
            Write-LogInfo "Skipping font installation (-SkipFonts)"
        }

        $null = Install-VSCode
        Install-VSCodeExtensions
    }
    else {
        Write-LogInfo "Skipping Windows applications installation (-SkipApps)"
    }

    # Verify VS Code integration in WSL
    if (-not $skipConfiguration) {
        Write-LogInfo "Verifying VS Code integration in WSL..."
        $codeTest = wsl -d $wslDistroName -- bash -c 'source ~/.bashrc && which code 2>/dev/null || echo "NOT_FOUND"' 2>&1 | Out-String
        $codeTest = $codeTest -replace '\x00', '' -replace '\r?\n', ''
        if ($codeTest -match "NOT_FOUND" -or [string]::IsNullOrWhiteSpace($codeTest)) {
            Write-LogWarn "VS Code 'code' command not found in WSL PATH"
            Write-LogWarn "You may need to restart your terminal or run: source ~/.bashrc"
        }
        else {
            Write-LogSuccess "VS Code integration verified: $codeTest"
        }
    }

    # Clear saved state on success
    Clear-SetupState

    # Show summary
    Show-Summary -WslDistroName $wslDistroName

    Write-LogSuccess "Setup completed successfully!"
}

# Run main function with cleanup
try {
    Main
}
catch {
    Write-LogError "Unexpected error: $_"
    Write-LogError $_.ScriptStackTrace
    exit $script:EXIT_GENERAL_ERROR
}
finally {
    # Release mutex lock
    Exit-ScriptLock

    # Restore progress preference
    if ($script:OriginalProgressPreference) {
        $ProgressPreference = $script:OriginalProgressPreference
    }
}
