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
#   .\Setup-DevContainers.ps1 -DryRun -Verbose
#   .\Setup-DevContainers.ps1 -NonInteractive
#
# OPTIONS:
#   -Distro           Distro to install: Debian (only supported distro)
#   -Resume           Resume setup after reboot
#   -DryRun           Show what would be done without making changes
#   -NonInteractive   Skip all prompts, use defaults
#   -SkipApps         Skip Windows Terminal/VS Code installation
#   -SkipFonts        Skip MesloLGS NF font installation
#   -Force            Force reinstall of Windows apps even if present
#   -Help             Show help message
#
# LICENSE:            NCSA
#===============================================================================

#Requires -Version 5.1
#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [Parameter(HelpMessage = "Linux distribution to install")]
    [ValidateSet('Debian')]
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

# Satisfy PSScriptAnalyzer - parameters are used in nested function scopes
$null = $Distro, $Resume, $DryRun, $NonInteractive, $SkipApps, $SkipFonts, $Force, $Help

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
$script:EXIT_WSL_FAILED = 4
$script:EXIT_DISTRO_FAILED = 5
$script:EXIT_WINGET_FAILED = 6
$script:EXIT_REBOOT_REQUIRED = 7
$script:EXIT_NO_SLOT_AVAILABLE = 9

# Supported distros
$script:SUPPORTED_DISTROS = @{
    'Debian' = @{
        DisplayName = 'Debian 13 Trixie'
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

function Write-SetupLog {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Interactive CLI requires colored console output')]
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
    Write-SetupLog -Level "INFO " -Message $Message -Color "Cyan"
}

function Write-LogSuccess {
    param([string]$Message)
    Write-SetupLog -Level "OK   " -Message $Message -Color "Green"
}

function Write-LogWarn {
    param([string]$Message)
    Write-SetupLog -Level "WARN " -Message $Message -Color "Yellow"
}

function Write-LogError {
    param([string]$Message)
    Write-SetupLog -Level "ERROR" -Message $Message -Color "Red"
}

function Write-LogDebug {
    param([string]$Message)
    if ($VerbosePreference -eq 'Continue' -or $PSBoundParameters['Verbose']) {
        Write-SetupLog -Level "DEBUG" -Message $Message -Color "DarkGray"
    }
}

function Write-LogStep {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Interactive CLI requires colored console output')]
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

function Get-PosixEscapedPath {
    <#
    .SYNOPSIS
    Escapes a path for use in POSIX single-quoted strings.
    .DESCRIPTION
    Replaces single quotes with the POSIX-safe sequence: '\''
    This closes the quote, adds an escaped quote, reopens the quote.
    Required when Windows usernames contain apostrophes (e.g., O'Connor).
    #>
    param([Parameter(Mandatory)][string]$Path)
    return $Path -replace "'", "'\\''"
}

#-------------------------------------------------------------------------------
# Script Locking
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
            # Intentionally suppressed: cleanup errors during mutex release are non-critical
            $null = $_
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
            # Intentionally suppressed: Get-ComputerInfo may not be available on all systems
            $null = $_
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
# WSL Command Helpers
#-------------------------------------------------------------------------------
function Test-WslFileTransferIntegrity {
    <#
    .SYNOPSIS
    Verifies a file was transferred to WSL without truncation by comparing sizes.
    .DESCRIPTION
    Accounts for CR characters (0x0D) that are stripped during transfer via tr -d '\r'.
    This ensures the integrity check works correctly for both LF and CRLF source files.
    .PARAMETER SourcePath
    The Windows source file path.
    .PARAMETER WslPath
    The destination path inside WSL.
    .PARAMETER Distro
    The WSL distribution name.
    .OUTPUTS
    Returns $true if sizes match. Throws on mismatch or error.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$SourcePath,
        [Parameter(Mandatory)]
        [string]$WslPath,
        [Parameter(Mandatory)]
        [string]$Distro
    )

    $fileName = Split-Path -Leaf $SourcePath

    # Read source file as bytes to accurately count CR characters
    $sourceBytes = [System.IO.File]::ReadAllBytes($SourcePath)

    # Count CR bytes (0x0D) that tr -d '\r' will strip during transfer
    $crCount = 0
    foreach ($byte in $sourceBytes) {
        if ($byte -eq 0x0D) { $crCount++ }
    }

    # Expected size is original minus stripped CRs
    $expectedSize = $sourceBytes.Length - $crCount

    $sizeOutput = wsl -d $Distro -u root --cd /tmp -- stat -c '%s' $WslPath 2>&1
    $transferredSize = ($sizeOutput | Out-String).Trim() -replace '\x00', '' -replace '\r', ''

    if ($LASTEXITCODE -ne 0 -or -not $transferredSize) {
        throw "Could not verify file transfer: stat failed for $WslPath (exit code: $LASTEXITCODE)"
    }

    if ([long]$transferredSize -ne $expectedSize) {
        throw "File integrity check failed: $fileName size mismatch (expected: $expectedSize bytes, got: $transferredSize bytes)"
    }

    if ($crCount -gt 0) {
        Write-LogDebug "Verified transfer: $fileName ($expectedSize bytes, stripped $crCount CR chars)"
    } else {
        Write-LogDebug "Verified transfer: $fileName ($expectedSize bytes)"
    }

    return $true
}

#-------------------------------------------------------------------------------
# Debian Rootfs Download
#-------------------------------------------------------------------------------
function Get-DebianRootfs {
    <#
    .SYNOPSIS
    Downloads and extracts the Debian rootfs tarball from Microsoft's .appx package.
    .OUTPUTS
    Returns the path to the extracted rootfs.tar file.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'Rootfs is singular - abbreviation for root filesystem')]
    param(
        [Parameter(Mandatory)]
        [string]$OutputPath
    )

    $appxUrl = "https://aka.ms/wsl-debian-gnulinux"
    $randomSuffix = Get-Random -Maximum 999999

    # Use LOCALAPPDATA for temp files - guaranteed to be on local system drive
    $tempBase = Join-Path $env:LOCALAPPDATA "DevContainersSetup\temp"
    if (-not (Test-Path $tempBase)) {
        New-Item -ItemType Directory -Path $tempBase -Force | Out-Null
    }

    $appxPath = Join-Path $tempBase "debian-appx-$randomSuffix.zip"
    $extractPath = Join-Path $tempBase "debian-extract-$randomSuffix"

    try {
        Write-LogInfo "Downloading Debian rootfs from Microsoft..."
        Write-LogDebug "URL: $appxUrl"

        $downloadStart = Get-Date
        Invoke-WebRequest -Uri $appxUrl -OutFile $appxPath -UseBasicParsing -ErrorAction Stop
        $downloadTime = (Get-Date) - $downloadStart
        $appxSize = (Get-Item $appxPath).Length
        Write-LogDebug "Downloaded $([Math]::Round($appxSize / 1MB, 1)) MB in $([Math]::Round($downloadTime.TotalSeconds, 1))s"

        # Verify Authenticode signature (supply-chain protection)
        Write-LogInfo "Verifying package signature..."
        $signature = Get-AuthenticodeSignature -FilePath $appxPath
        if ($signature.Status -ne 'Valid') {
            throw "Downloaded package has invalid Authenticode signature: $($signature.StatusMessage)"
        }
        if ($signature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') {
            throw "Downloaded package not signed by Microsoft (Subject: $($signature.SignerCertificate.Subject))"
        }
        Write-LogDebug "Package signature valid: $($signature.SignerCertificate.Subject)"

        Write-LogInfo "Extracting rootfs from package..."
        Expand-Archive -Path $appxPath -DestinationPath $extractPath -Force -ErrorAction Stop

        # Find the rootfs tarball (install.tar.gz in Debian's .appx)
        $rootfsGz = Get-ChildItem -Path $extractPath -Filter "install.tar.gz" -Recurse -ErrorAction SilentlyContinue |
            Select-Object -First 1

        if (-not $rootfsGz) {
            $rootfsGz = Get-ChildItem -Path $extractPath -Filter "*.tar.gz" -Recurse -ErrorAction SilentlyContinue |
                Select-Object -First 1
        }

        if (-not $rootfsGz) {
            throw "No rootfs tarball found in .appx package. Contents: $(Get-ChildItem $extractPath -Recurse -Name | Out-String)"
        }

        Write-LogDebug "Found rootfs: $($rootfsGz.Name) ($([Math]::Round($rootfsGz.Length / 1MB, 1)) MB)"

        # Decompress .tar.gz to .tar using .NET GzipStream
        Write-LogInfo "Decompressing rootfs..."
        $gzipInput = [System.IO.File]::OpenRead($rootfsGz.FullName)
        $gzipStream = New-Object System.IO.Compression.GzipStream($gzipInput, [System.IO.Compression.CompressionMode]::Decompress)
        $tarOutput = [System.IO.File]::Create($OutputPath)

        try {
            $gzipStream.CopyTo($tarOutput)
        }
        finally {
            $tarOutput.Close()
            $gzipStream.Close()
            $gzipInput.Close()
        }

        if (-not (Test-Path $OutputPath)) {
            throw "Failed to create rootfs tarball at: $OutputPath"
        }

        $tarSize = (Get-Item $OutputPath).Length
        Write-LogDebug "Decompressed rootfs: $([Math]::Round($tarSize / 1MB, 1)) MB"

        if ($tarSize -lt 100MB) {
            throw "Rootfs tarball suspiciously small ($([Math]::Round($tarSize / 1MB, 1)) MB)"
        }

        Write-LogSuccess "Debian rootfs ready ($([Math]::Round($tarSize / 1MB, 0)) MB)"
        return $OutputPath
    }
    finally {
        Remove-Item $appxPath -Force -ErrorAction SilentlyContinue
        Remove-Item $extractPath -Recurse -Force -ErrorAction SilentlyContinue
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
        $regProps = Get-ItemProperty -Path $script:STATE_REG_PATH -ErrorAction SilentlyContinue
        if (-not $regProps) { return $null }

        # Safe property access compatible with Strict Mode 3.0
        $phase = if ($regProps.PSObject.Properties['Phase']) { $regProps.Phase } else { $null }
        $distro = if ($regProps.PSObject.Properties['Distro']) { $regProps.Distro } else { $null }

        if ($phase -and $distro) {
            return @{
                Phase      = $phase
                Distro     = $distro
                Timestamp  = if ($regProps.PSObject.Properties['Timestamp']) { $regProps.Timestamp } else { $null }
                ScriptPath = if ($regProps.PSObject.Properties['ScriptPath']) { $regProps.ScriptPath } else { $null }
            }
        }
    }
    catch {
        Write-LogDebug "Error reading state: $_"
    }

    return $null
}

function Clear-SetupState {
    # Clean up scheduled task if it exists (ignore errors if task doesn't exist)
    try {
        $null = schtasks.exe /delete /tn $script:RESUME_TASK_NAME /f 2>&1
        Write-LogDebug "Cleaned up resume task (if existed)"
    }
    catch {
        # Task didn't exist - that's fine
        Write-LogDebug "No resume task to clean up"
    }

    # Clean up registry state
    if (Test-Path $script:STATE_REG_PATH) {
        Remove-Item -Path $script:STATE_REG_PATH -Recurse -Force -ErrorAction SilentlyContinue
        Write-LogDebug "Cleared saved registry state"
    }

    # Note: Mutex lock is released in Exit-ScriptLock called from finally block
}

function Request-Reboot {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Interactive CLI requires colored console output')]
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
# Configuration Functions
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

    # Helper function to extract section content (for scoped matching)
    # Matches from [section] until next [section] or end of file
    $getSectionContent = {
        param([string]$Content, [string]$SectionName)
        $pattern = "\[$SectionName\][\s\S]*?(?=\n\[|\z)"
        $match = [regex]::Match($Content, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($match.Success) { return $match.Value } else { return "" }
    }

    # Extract section contents for scoped matching
    $wsl2Section = & $getSectionContent $configContent "wsl2"
    $experimentalSection = & $getSectionContent $configContent "experimental"

    # Ensure [wsl2] section exists with recommended settings
    if ($configContent -notmatch "\[wsl2\]") {
        $configContent = "[wsl2]`nmemory=$memoryConfig`nlocalhostForwarding=true`n`n" + $configContent
        $configChanged = $true
        Write-LogDebug "Added [wsl2] section with memory=$memoryConfig"
    }
    elseif ($wsl2Section -notmatch "(?m)^memory\s*=") {
        # Add memory setting under existing [wsl2] section (only if not in that section)
        $configContent = $configContent -replace "(\[wsl2\])", "`$1`nmemory=$memoryConfig"
        $configChanged = $true
        Write-LogDebug "Added memory=$memoryConfig to existing [wsl2] section"
    }

    # Re-extract experimental section after potential changes
    $experimentalSection = & $getSectionContent $configContent "experimental"

    # DISABLE sparse VHD due to current WSL2 bugs
    if ($configContent -notmatch "\[experimental\]") {
        $configContent += "`n[experimental]`nsparseVhd=false`nautoMemoryReclaim=gradual`n"
        $configChanged = $true
        Write-LogDebug "Added [experimental] section with sparseVhd=false"
    }
    elseif ($experimentalSection -match "(?m)^sparseVhd\s*=\s*true") {
        $configContent = $configContent -replace "sparseVhd\s*=\s*true", "sparseVhd=false"
        $configChanged = $true
        Write-LogDebug "Changed sparseVhd from true to false"
    }
    elseif ($experimentalSection -notmatch "(?m)^sparseVhd\s*=") {
        $configContent = $configContent -replace "(\[experimental\])", "`$1`nsparseVhd=false"
        $configChanged = $true
        Write-LogDebug "Added sparseVhd=false to existing [experimental] section"
    }

    # Re-extract experimental section after potential changes
    $experimentalSection = & $getSectionContent $configContent "experimental"

    # Ensure autoMemoryReclaim is configured (separate from sparseVhd logic)
    if ($configContent -match "\[experimental\]" -and $experimentalSection -notmatch "(?m)^autoMemoryReclaim\s*=") {
        $configContent = $configContent -replace "(\[experimental\])", "`$1`nautoMemoryReclaim=gradual"
        $configChanged = $true
        Write-LogDebug "Added autoMemoryReclaim=gradual to existing [experimental] section"
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
    Disable-SparseOnExistingDistro
}

function Disable-SparseOnExistingDistro {
    Write-LogInfo "Checking sparse VHD status on existing distributions..."

    # Get list of existing distros
    $rawOutput = wsl --list --quiet 2>&1
    $distroList = ($rawOutput | Out-String) -replace '\x00', '' -replace '\r', ''

    # Handle WSL command failure (e.g., WSL not ready)
    if ($LASTEXITCODE -ne 0) {
        Write-LogWarn "Could not enumerate WSL distributions (exit code: $LASTEXITCODE)"
        Write-LogDebug "WSL output: $distroList"
        return
    }

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

function Initialize-Wsl2DefaultVersion {
    <#
    .SYNOPSIS
    Initializes WSL2 as the default version with automatic kernel update on failure.
    .DESCRIPTION
    Attempts to set WSL2 as default. If it fails (often due to missing kernel),
    automatically runs wsl --update and retries. Provides clear remediation steps
    if all attempts fail.
    .OUTPUTS
    Returns $true if WSL2 is configured successfully, $false on failure.
    #>

    if ($DryRun) {
        Write-LogInfo "[DRY-RUN] Would set WSL2 as default version"
        return $true
    }

    Write-LogDebug "Setting WSL2 as default version..."
    $null = wsl --set-default-version 2 2>&1

    if ($LASTEXITCODE -eq 0) {
        Write-LogDebug "WSL2 set as default successfully"
        return $true
    }

    $firstExitCode = $LASTEXITCODE
    Write-LogWarn "Failed to set WSL2 as default (exit code: $firstExitCode)"
    Write-LogInfo "Attempting to update WSL kernel..."

    # Try wsl --update to install/update kernel component
    $updateOutput = wsl --update 2>&1 | Out-String
    Write-LogDebug "WSL update output: $($updateOutput.Trim())"

    Start-Sleep -Seconds 2

    # Retry setting WSL2 as default
    Write-LogInfo "Retrying WSL2 default configuration..."
    $null = wsl --set-default-version 2 2>&1

    if ($LASTEXITCODE -eq 0) {
        Write-LogSuccess "WSL2 configured after kernel update"
        return $true
    }

    # Final failure - provide remediation steps
    Write-LogError "Failed to configure WSL2 as default after kernel update"
    Write-LogError "Exit code: $LASTEXITCODE"
    Write-LogError ""
    Write-LogError "Manual remediation steps:"
    Write-LogError "  1. Run: wsl --update"
    Write-LogError "  2. Run: wsl --set-default-version 2"
    Write-LogError "  3. If still failing, download kernel: https://aka.ms/wsl2kernel"
    Write-LogError "  4. Re-run this script after completing above steps"

    return $false
}

function Enable-WSL2Feature {
    Write-LogStep "1/7" "Enabling WSL2 features"

    $status = Test-WSL2Enabled
    $needsReboot = $false

    if ($status.AllEnabled) {
        Write-LogSuccess "WSL2 features already enabled"

        # Ensure WSL2 is set as default version
        if (-not (Initialize-Wsl2DefaultVersion)) {
            Exit-WithError "Could not configure WSL2 as default version" $script:EXIT_WSL_FAILED
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
    if (-not (Initialize-Wsl2DefaultVersion)) {
        # If reboot is needed anyway, this failure is expected - kernel installs after reboot
        if (-not $needsReboot) {
            Exit-WithError "Could not configure WSL2 as default version" $script:EXIT_WSL_FAILED
        }
        Write-LogWarn "WSL2 default version will be configured after reboot"
    }

    if ($needsReboot -and -not $DryRun) {
        Write-LogSuccess "WSL2 features enabled (restart required)"
        return $true
    }

    Write-LogSuccess "WSL2 features configured"
    return $false
}

function Get-NextAvailableDistroName {
    <#
    .SYNOPSIS
    Finds the next available distro name in Debian-01 to Debian-99 range.
    .OUTPUTS
    Returns the next available name (e.g., "Debian-03"), or $null if all taken.
    #>

    Write-LogDebug "Scanning for available distro slot..."

    try {
        # Get list of existing distros (quiet mode, just names)
        $rawOutput = wsl --list --quiet 2>&1
        $distroList = ($rawOutput | Out-String) -replace '\x00', '' -replace '\r', ''

        # Handle WSL command failure (e.g., WSL not ready)
        if ($LASTEXITCODE -ne 0) {
            Write-LogDebug "wsl --list failed (exit code: $LASTEXITCODE), assuming no distros exist"
            return "Debian-01"
        }

        $existingDistros = @($distroList -split "`n" |
            Where-Object { $_ -match '\S' } |
            ForEach-Object { $_.Trim() })

        Write-LogDebug "Existing distros: $($existingDistros -join ', ')"

        # Find first available slot (01 through 99)
        for ($i = 1; $i -le 99; $i++) {
            $candidateName = "Debian-{0:D2}" -f $i

            # Case-insensitive check
            $isUsed = $existingDistros | Where-Object {
                $_.Equals($candidateName, [StringComparison]::OrdinalIgnoreCase)
            }

            if (-not $isUsed) {
                Write-LogDebug "Found available slot: $candidateName"
                return $candidateName
            }
        }

        Write-LogWarn "All Debian-01 through Debian-99 slots are in use"
        return $null
    }
    catch {
        Write-LogDebug "Error scanning distro slots: $_"
        # On error, return first slot (will fail later if actually in use)
        return "Debian-01"
    }
}

function Install-WslDistroViaImport {
    <#
    .SYNOPSIS
    Creates a new Debian WSL distribution by downloading rootfs directly from Microsoft.
    .DESCRIPTION
    Downloads the Debian .appx package from Microsoft, extracts the rootfs tarball,
    and imports it as a new WSL distribution with the specified name.
    .OUTPUTS
    Returns the name of the created distribution.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$TargetDistroName
    )

    $distroInfo = $script:SUPPORTED_DISTROS['Debian']
    $displayName = $distroInfo.DisplayName

    Write-LogInfo "Creating $displayName as '$TargetDistroName'..."

    if ($DryRun) {
        Write-LogInfo "[DRY-RUN] Would download Debian rootfs and import as $TargetDistroName"
        return $TargetDistroName
    }

    # Use LOCALAPPDATA for temp files - guaranteed to be on local system drive
    $tempBase = Join-Path $env:LOCALAPPDATA "DevContainersSetup\temp"
    if (-not (Test-Path $tempBase)) {
        New-Item -ItemType Directory -Path $tempBase -Force | Out-Null
    }

    $randomSuffix = Get-Random -Maximum 999999
    $tempTarPath = Join-Path $tempBase "debian-rootfs-$randomSuffix.tar"
    $installPath = Join-Path $env:LOCALAPPDATA "WSL\$TargetDistroName"

    if (Test-Path $installPath) {
        $existingFiles = Get-ChildItem $installPath -ErrorAction SilentlyContinue
        if ($existingFiles) {
            Write-LogError "Install path already contains data: $installPath"
            Write-LogError "This may be from a failed previous run."
            Write-LogError "Please remove it manually: Remove-Item -Recurse '$installPath'"
            Exit-WithError "Install path not empty: $installPath" $script:EXIT_DISTRO_FAILED
        }
    }

    $cleanupTarball = $false
    $cleanupInstallPath = $false
    $cleanupDistro = $false

    try {
        Write-LogInfo "Step 1/3: Downloading Debian rootfs..."
        $tempTarPath = Get-DebianRootfs -OutputPath $tempTarPath
        $cleanupTarball = $true

        Write-LogInfo "Step 2/3: Importing as $TargetDistroName..."

        if (-not (Test-Path $installPath)) {
            New-Item -ItemType Directory -Path $installPath -Force | Out-Null
            $cleanupInstallPath = $true
        }

        $importOutput = wsl --import $TargetDistroName "`"$installPath`"" "`"$tempTarPath`"" 2>&1
        $importExitCode = $LASTEXITCODE
        $importStr = ($importOutput | Out-String) -replace '\x00', ''

        if ($importExitCode -ne 0) {
            throw "Import failed (exit code: $importExitCode): $importStr"
        }

        $cleanupDistro = $true
        $cleanupInstallPath = $false
        Write-LogSuccess "$TargetDistroName imported"

        Write-LogInfo "Step 3/3: Cleaning up..."
        Remove-Item $tempTarPath -Force -ErrorAction SilentlyContinue
        $cleanupTarball = $false

        Write-LogInfo "Verifying $TargetDistroName..."
        $verifyResult = wsl -d $TargetDistroName -u root --cd /tmp -- echo "health_check" 2>&1
        $verifyStr = ($verifyResult | Out-String) -replace '\x00', ''

        if ($LASTEXITCODE -ne 0) {
            throw "Distro health check failed: $verifyStr"
        }

        Write-LogSuccess "$displayName created as '$TargetDistroName'"
        $cleanupDistro = $false

        return $TargetDistroName
    }
    catch {
        Write-LogError "Failed to create distro: $_"

        if ($cleanupDistro) {
            Write-LogInfo "Rolling back: removing $TargetDistroName..."
            $null = wsl --unregister $TargetDistroName 2>&1
        }

        if ($cleanupInstallPath -and (Test-Path $installPath)) {
            Write-LogInfo "Rolling back: removing install directory..."
            Remove-Item -Path $installPath -Recurse -Force -ErrorAction SilentlyContinue
        }

        if ($cleanupTarball -and (Test-Path $tempTarPath)) {
            Write-LogInfo "Rolling back: removing tarball..."
            Remove-Item $tempTarPath -Force -ErrorAction SilentlyContinue
        }

        Exit-WithError "Failed to create $TargetDistroName`: $_" $script:EXIT_DISTRO_FAILED
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
            $initResult = wsl -d $WslDistroName -u root --cd /tmp -- echo "WSL_READY" 2>&1
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

        $null = wsl -d $WslDistroName -u root --cd / -- mkdir -p /tmp 2>$null
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to create /tmp directory in WSL"
        }

        # Copy scripts to WSL via Windows filesystem
        Write-LogInfo "Copying setup scripts to WSL..."

        # Use LOCALAPPDATA for temp files - guaranteed to be on local system drive
        # and accessible via WSL's /mnt/c/... path mapping
        $tempDir = Join-Path $env:LOCALAPPDATA "DevContainersSetup\temp\wsl-scripts-$(Get-Random)"

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
            $wslTempDir = "/mnt/" + $tempDir.Substring(0, 1).ToLower() + $tempDir.Substring(2).Replace('\', '/')
            # Escape single quotes for POSIX shell (handles usernames like O'Connor)
            $escapedWslTempDir = Get-PosixEscapedPath -Path $wslTempDir
            Write-LogDebug "WSL temp path: $wslTempDir"

            # Copy files to /tmp in WSL and fix line endings
            Write-LogDebug "Copying and converting line endings..."
            wsl -d $WslDistroName -u root --cd /tmp -- sh -c "cat '$escapedWslTempDir/setup-wsl-devcontainers.sh' | tr -d '\r' > /tmp/setup-wsl-devcontainers.sh"
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to copy setup-wsl-devcontainers.sh to WSL"
            }

            wsl -d $WslDistroName -u root --cd /tmp -- sh -c "cat '$escapedWslTempDir/install-docker.sh' | tr -d '\r' > /tmp/install-docker.sh"
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to copy install-docker.sh to WSL"
            }

            if ($tempGithubPath) {
                wsl -d $WslDistroName -u root --cd /tmp -- sh -c "cat '$escapedWslTempDir/install-github-cli.sh' | tr -d '\r' > /tmp/install-github-cli.sh"
                if ($LASTEXITCODE -ne 0) {
                    throw "Failed to copy install-github-cli.sh to WSL"
                }
            }

            if ($tempShellPath) {
                wsl -d $WslDistroName -u root --cd /tmp -- sh -c "cat '$escapedWslTempDir/install-shell-customization.sh' | tr -d '\r' > /tmp/install-shell-customization.sh"
                if ($LASTEXITCODE -ne 0) {
                    Write-LogWarn "Failed to copy install-shell-customization.sh to WSL"
                }
            }

            if ($tempP10kPath) {
                wsl -d $WslDistroName -u root --cd /tmp -- sh -c "cat '$escapedWslTempDir/p10k.zsh' | tr -d '\r' > /tmp/p10k.zsh"
                if ($LASTEXITCODE -ne 0) {
                    Write-LogWarn "Failed to copy p10k.zsh to WSL"
                }
            }

            if ($tempZshPluginsPath) {
                wsl -d $WslDistroName -u root --cd /tmp -- sh -c "cat '$escapedWslTempDir/zsh_plugins.txt' | tr -d '\r' > /tmp/zsh_plugins.txt"
                if ($LASTEXITCODE -ne 0) {
                    Write-LogWarn "Failed to copy zsh_plugins.txt to WSL"
                }
            }

            # Verify files exist
            $verifyResult = wsl -d $WslDistroName -u root --cd /tmp -- ls -la /tmp/*.sh 2>&1
            $verifyStr = ($verifyResult | Out-String) -replace '\x00', '' -replace '\r', ''
            Write-LogDebug "Scripts in /tmp: $verifyStr"

            if ($verifyStr -notmatch "setup-wsl-devcontainers.sh" -or $verifyStr -notmatch "install-docker.sh") {
                throw "Script files not found in WSL after transfer"
            }

            # Verify all transferred scripts (catches truncation during Windows->WSL copy)
            Write-LogDebug "Verifying script transfer integrity..."
            Test-WslFileTransferIntegrity -SourcePath $setupScript -WslPath "/tmp/setup-wsl-devcontainers.sh" -Distro $WslDistroName
            Test-WslFileTransferIntegrity -SourcePath $dockerScript -WslPath "/tmp/install-docker.sh" -Distro $WslDistroName
            if ($tempGithubPath) {
                Test-WslFileTransferIntegrity -SourcePath $githubScript -WslPath "/tmp/install-github-cli.sh" -Distro $WslDistroName
            }
            if ($tempShellPath) {
                Test-WslFileTransferIntegrity -SourcePath $shellScript -WslPath "/tmp/install-shell-customization.sh" -Distro $WslDistroName
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
                $null = wsl -d $WslDistroName -u root --cd /tmp -- test -f $scriptPath
                if ($LASTEXITCODE -ne 0) {
                    throw "Script file not found in WSL: $scriptPath"
                }
                $null = wsl -d $WslDistroName -u root --cd /tmp -- chmod +x $scriptPath
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

        # Build argument list (--cd /tmp avoids CWD translation issues with UNC paths)
        $argList = @("-d", $WslDistroName, "-u", "root", "--cd", "/tmp", "--", "/tmp/setup-wsl-devcontainers.sh", "--user", $unixUser)
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

        # Note: We do NOT delete the distro on configuration failure.
        # This allows the user to inspect what went wrong.
        Write-LogWarn "The distro '$WslDistroName' remains registered for inspection."
        Write-LogWarn "To clean up manually, run: wsl --unregister $WslDistroName"
        Write-LogWarn "To retry, run this script again (it will create a new distro)."

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
        if ($terminal -and -not $Force) {
            Write-LogSuccess "Windows Terminal already installed (v$($terminal.Version))"
            return
        }
        if ($terminal -and $Force) {
            Write-LogInfo "Force reinstalling Windows Terminal (current: v$($terminal.Version))..."
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
        $shell = $null  # Initialize before try block for finally cleanup

        try {
            # Check if font is already installed (same size = likely same file)
            if (Test-Path $destPath) {
                $sourceSize = (Get-Item $fontPath).Length
                $destSize = (Get-Item $destPath).Length
                if ($sourceSize -eq $destSize) {
                    Write-LogDebug "Font already installed: $fontFileName"
                    $installedCount++
                    continue
                }
            }

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
            # Release COM object if it was created
            if ($null -ne $shell) {
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
    Initialize-WindowsTerminalFont
    Initialize-VSCodeTerminalFont
}

function Initialize-WindowsTerminalFont {
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

    $backupPath = "$wtSettingsPath.backup"

    try {
        # Backup existing settings
        Copy-Item $wtSettingsPath $backupPath -Force
        Write-LogDebug "Backed up Windows Terminal settings to $backupPath"

        $settingsContent = Get-Content $wtSettingsPath -Raw -Encoding UTF8
        $fontName = $script:MESLO_FONT_NAME

        # Try PowerShell 7.3+ JSON with comments support first
        if ($PSVersionTable.PSVersion.Major -ge 7 -and $PSVersionTable.PSVersion.Minor -ge 3) {
            try {
                $settings = $settingsContent | ConvertFrom-Json -AllowComments

                # Ensure profiles.defaults exists using safe property access
                if (-not $settings.PSObject.Properties['profiles']) {
                    $settings | Add-Member -NotePropertyName profiles -NotePropertyValue ([PSCustomObject]@{}) -Force
                }
                if (-not $settings.profiles.PSObject.Properties['defaults']) {
                    $settings.profiles | Add-Member -NotePropertyName defaults -NotePropertyValue ([PSCustomObject]@{}) -Force
                }

                # Set font configuration (v1.10+ style with font object)
                $fontConfig = [PSCustomObject]@{ face = $fontName }

                if ($settings.profiles.defaults.PSObject.Properties['font']) {
                    $settings.profiles.defaults.font | Add-Member -NotePropertyName face -NotePropertyValue $fontName -Force
                }
                else {
                    $settings.profiles.defaults | Add-Member -NotePropertyName font -NotePropertyValue $fontConfig -Force
                }

                $settingsJson = $settings | ConvertTo-Json -Depth 10
                Set-Content -Path $wtSettingsPath -Value $settingsJson -Encoding UTF8
                Write-LogSuccess "Windows Terminal configured to use $fontName"
                return
            }
            catch {
                Write-LogDebug "PowerShell 7.3+ JSON parsing failed, falling back to text-based: $_"
            }
        }

        # Text-based approach for JSONC compatibility (PowerShell 5.1 and 7.0-7.2)
        # Windows Terminal settings.json commonly contains comments which break ConvertFrom-Json
        # Pattern matches "face" : "value" within a "font" block (handles whitespace variations)
        $fontFacePattern = '("font"\s*:\s*\{[^}]*"face"\s*:\s*")([^"]*)'

        if ($settingsContent -match $fontFacePattern) {
            # Update existing font face value
            $settingsContent = $settingsContent -replace $fontFacePattern, "`${1}$fontName"
            Set-Content -Path $wtSettingsPath -Value $settingsContent -Encoding UTF8
            Write-LogSuccess "Windows Terminal font updated to $fontName"
        }
        else {
            # No existing font configuration found
            # Inserting nested JSON structures via regex is fragile and could corrupt the file
            Write-LogWarn "Windows Terminal font configuration not found in settings"
            Write-LogInfo "To configure manually:"
            Write-LogInfo "  1. Open Windows Terminal Settings (Ctrl+,)"
            Write-LogInfo "  2. Go to: Profiles > Defaults > Appearance"
            Write-LogInfo "  3. Set Font face to: $fontName"
        }
    }
    catch {
        Write-LogWarn "Failed to configure Windows Terminal font: $_"
        if (Test-Path $backupPath) {
            Copy-Item $backupPath $wtSettingsPath -Force
            Write-LogDebug "Restored Windows Terminal settings from backup"
        }
    }
}

function Initialize-VSCodeTerminalFont {
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
                # Find position after opening brace, allowing comments to precede it
                $firstBraceIndex = $settingsContent.IndexOf('{')
                if ($firstBraceIndex -ge 0) {
                    $insertPos = $firstBraceIndex + 1
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
            if (-not $Force) {
                Write-LogSuccess "VS Code already installed (v$version)"
                return $path
            }
            Write-LogInfo "Force reinstalling VS Code (current: v$version)..."
            break
        }
    }

    try {
        $codePath = (Get-Command code -ErrorAction SilentlyContinue).Source
        if ($codePath -and -not $Force) {
            Write-LogSuccess "VS Code already installed: $codePath"
            return $codePath
        }
        if ($codePath -and $Force) {
            Write-LogInfo "Force reinstalling VS Code (found: $codePath)..."
        }
    }
    catch {
        # Intentionally suppressed: checking if 'code' command exists
        $null = $_
    }

    if (-not (Test-WingetAvailable)) {
        Exit-WithError "winget not available and VS Code not found. Install VS Code manually." $script:EXIT_WINGET_FAILED
    }

    Write-LogInfo "Installing VS Code via winget..."

    if ($DryRun) {
        Write-LogInfo "[DRY-RUN] Would execute: winget install --id Microsoft.VisualStudioCode"
        return $null
    }

    try {
        $null = winget install --id Microsoft.VisualStudioCode `
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

function Install-VSCodeExtension {
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
            $null = & $codePath --install-extension $ext --force 2>&1

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
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Interactive CLI requires colored console output')]
    param()

    $help = @"

$($script:SCRIPT_NAME) v$($script:SCRIPT_VERSION) - DevContainers setup for Windows 11

USAGE:
    .\$($script:SCRIPT_NAME) [OPTIONS]

OPTIONS:
    -Distro <name>     Distribution to install: Debian (only supported distro)
    -Resume            Resume setup after reboot
    -DryRun            Preview without making changes
    -NonInteractive    Skip all prompts, use defaults
    -SkipApps          Skip Windows Terminal/VS Code installation
    -SkipFonts         Skip MesloLGS NF font installation
    -Force             Force reinstall of Windows apps even if present
    -Verbose           Enable verbose output
    -Help              Show this help message

SUPPORTED DISTRIBUTIONS:
    Debian    Debian 13 Trixie - support until 2030

EXAMPLES:
    # Standard setup with Debian
    .\$($script:SCRIPT_NAME)

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
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Interactive CLI requires colored console output')]
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
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Interactive CLI requires colored console output')]
    param()

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
    $needsReboot = Enable-WSL2Feature

    if ($needsReboot) {
        Request-Reboot -NextPhase 2 -SelectedDistro $Distro
        return  # Won't reach here normally
    }

    # Configure .wslconfig
    Initialize-WslConfig

    # Always create a new distro with unique sequential name
    $wslDistroName = Get-NextAvailableDistroName
    if (-not $wslDistroName) {
        Write-LogError "All distro slots (Debian-01 through Debian-99) are in use."
        Write-LogError ""
        Write-LogError "To free up slots, unregister distros you no longer need:"
        Write-LogError "  wsl --unregister Debian-XX"
        Write-LogError ""
        Write-LogError "To see all distros:"
        Write-LogError "  wsl --list --verbose"
        Exit-WithError "No available distro slots (Debian-01 to Debian-99 all in use)" $script:EXIT_NO_SLOT_AVAILABLE
    }

    Write-LogInfo "Target distro name: $wslDistroName"

    # Create the distro via export/import workflow
    $wslDistroName = Install-WslDistroViaImport -TargetDistroName $wslDistroName

    # Always configure the newly created distro (no skip logic)
    Initialize-WslDistro -WslDistroName $wslDistroName

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
        Install-VSCodeExtension
    }
    else {
        Write-LogInfo "Skipping Windows applications installation (-SkipApps)"
    }

    # Verify VS Code integration in WSL
    if (-not $SkipApps) {
        Write-LogInfo "Verifying VS Code integration in WSL..."
        $codeTest = wsl -d $wslDistroName --cd ~ -- bash -c 'source ~/.bashrc && which code 2>/dev/null || echo "NOT_FOUND"' 2>&1 | Out-String
        $codeTest = $codeTest -replace '\x00', '' -replace '\r?\n', ''
        if ($codeTest -match "NOT_FOUND" -or [string]::IsNullOrWhiteSpace($codeTest)) {
            Write-LogWarn "VS Code 'code' command not found in WSL PATH"
            Write-LogWarn "You may need to restart your terminal or run: source ~/.bashrc"
        }
        else {
            Write-LogSuccess "VS Code integration verified: $codeTest"
        }
    }

    # Restart WSL to ensure clean systemd initialization on next boot
    # This is critical for systemd user services (like ssh-agent) to work properly
    Write-LogInfo "Finalizing WSL configuration..."
    if (-not $DryRun) {
        wsl --shutdown 2>$null
        Start-Sleep -Seconds 2
        Write-LogSuccess "WSL restarted - systemd will initialize fresh on next launch"
    }
    else {
        Write-LogInfo "[DRY-RUN] Would restart WSL for clean systemd initialization"
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
