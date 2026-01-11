@echo off
REM SPDX-License-Identifier: NCSA
REM ============================================================================
REM Double-Click-Me.bat
REM
REM Double-click this file to set up VS Code DevContainers with WSL2 and Docker.
REM Automatically requests Administrator privileges
REM
REM License: NCSA
REM ============================================================================

REM Store the script directory (handles paths with spaces)
set "SCRIPT_DIR=%~dp0"
set "PS_SCRIPT=%SCRIPT_DIR%Setup-DevContainers.ps1"

REM Title and colors
title DevContainers Setup for Windows 11
color 1F

REM ============================================================================
REM Check if running as Administrator
REM ============================================================================
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo.
    echo ============================================================
    echo   DevContainers Setup - Requesting Administrator Access
    echo ============================================================
    echo.
    echo This setup requires Administrator privileges to:
    echo   - Enable WSL2 Windows features
    echo   - Install Linux distribution
    echo   - Install Windows applications
    echo.
    echo Please click "Yes" on the UAC prompt...
    echo.

    REM Self-elevate using PowerShell
    powershell -Command "Start-Process -FilePath '%~f0' -Verb RunAs -Wait"

    REM Exit the non-elevated instance
    exit /b
)

REM ============================================================================
REM We are now running as Administrator
REM ============================================================================
cls
echo.
echo ============================================================
echo   DevContainers Setup for Windows 11
echo ============================================================
echo.
echo   Running as Administrator: YES
echo   Script Directory: %SCRIPT_DIR%
echo.
echo ============================================================
echo.

REM ============================================================================
REM Verify all required files exist
REM ============================================================================
set "FILES_OK=1"

if not exist "%PS_SCRIPT%" (
    echo [ERROR] Missing: Setup-DevContainers.ps1
    set "FILES_OK=0"
)

if not exist "%SCRIPT_DIR%setup-wsl-devcontainers.sh" (
    echo [ERROR] Missing: setup-wsl-devcontainers.sh
    set "FILES_OK=0"
)

if not exist "%SCRIPT_DIR%install-docker.sh" (
    echo [ERROR] Missing: install-docker.sh
    set "FILES_OK=0"
)

if "%FILES_OK%"=="0" (
    color 4F
    echo.
    echo ============================================================
    echo   MISSING REQUIRED FILES
    echo ============================================================
    echo.
    echo Please ensure all these files are in the same directory:
    echo.
    echo   %SCRIPT_DIR%
    echo.
    echo Required files:
    echo   - Double-Click-Me.bat       [this file]
    echo   - Setup-DevContainers.ps1   [PowerShell script]
    echo   - setup-wsl-devcontainers.sh   [Linux setup]
    echo   - install-docker.sh   [Docker installer]
    echo.
    echo Optional files:
    echo   - install-github-cli.sh   [GitHub CLI setup]
    echo   - install-shell-customization.sh   [Zsh/Oh-My-Zsh/mise setup]
    echo   - p10k.zsh   [Powerlevel10k theme config]
    echo.
    goto :error_exit
)

echo All required files found.
echo.

REM Check for optional GitHub CLI script
if not exist "%SCRIPT_DIR%install-github-cli.sh" (
    echo [WARN] Optional: install-github-cli.sh not found
    echo        GitHub CLI setup will be skipped
    echo.
)

REM Check for optional shell customization files
if not exist "%SCRIPT_DIR%install-shell-customization.sh" (
    echo [WARN] Optional: install-shell-customization.sh not found
    echo        Shell customization ^(Zsh/Oh-My-Zsh/mise^) will be skipped
    echo.
) else (
    if not exist "%SCRIPT_DIR%p10k.zsh" (
        echo [WARN] Optional: p10k.zsh not found
        echo        Default Powerlevel10k config will be generated
        echo.
    )
)

echo Starting setup...
echo.
echo ============================================================
echo.

REM ============================================================================
REM Change to script directory (pushd handles UNC paths by mapping a temp drive)
REM ============================================================================
pushd "%SCRIPT_DIR%"

REM ============================================================================
REM Run the PowerShell script
REM ============================================================================
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS_SCRIPT%"

REM Capture the exit code
set "PS_EXIT_CODE=%errorlevel%"

echo.
echo ============================================================

REM ============================================================================
REM Handle exit codes
REM ============================================================================
if %PS_EXIT_CODE% equ 0 (
    color 2F
    echo.
    echo   SETUP COMPLETED SUCCESSFULLY
    echo.
    echo ============================================================
    echo.
    echo   Next steps:
    echo     1. Open Windows Terminal
    echo     2. Select your Linux distro from the dropdown
    echo     3. Run: docker run hello-world
    echo     4. Open VS Code and use DevContainers
    echo.
) else if %PS_EXIT_CODE% equ 7 (
    color 6F
    echo.
    echo   RESTART REQUIRED
    echo.
    echo ============================================================
    echo.
    echo   WSL2 features have been enabled.
    echo   Please restart your computer to continue setup.
    echo.
    echo   Setup will resume automatically after restart.
    echo.
) else (
    color 4F
    echo.
    echo   SETUP ENCOUNTERED AN ERROR
    echo.
    echo ============================================================
    echo.
    echo   Exit code: %PS_EXIT_CODE%
    echo.
    echo   Please check the log file for details:
    echo   %LOCALAPPDATA%\DevContainersSetup\setup.log
    echo.
    echo   Common issues:
    echo     - Internet connection required
    echo     - Virtualization must be enabled in BIOS
    echo     - Antivirus may block installation
    echo.
)

goto :end

:error_exit
set "PS_EXIT_CODE=1"
echo.
echo Setup cannot continue. Please fix the errors above.
echo.

:end
popd 2>nul
echo.
echo Press any key to close this window...
pause >nul
exit /b %PS_EXIT_CODE%
