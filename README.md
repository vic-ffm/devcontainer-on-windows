# DevContainers Setup for Windows 11

![Licence](https://img.shields.io/badge/licence-NCSA-yellow)
![Platform](https://img.shields.io/badge/platform-Windows%2011-0078D6)
![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE)
![Bash](https://img.shields.io/badge/Bash-5.2%2B-4EAA25)

Sets up VS Code DevContainers on Windows 11 using WSL2 and Docker Engine. The scripts handle WSL2, your Linux distro, Docker, and GitHub CLI.

## Table of Contents

- [Features](#features)
- [Requirements](#requirements)
- [Quick Start](#quick-start)
- [Scripts](#scripts)
- [Supported Distributions](#supported-distributions)
- [Options](#options)
- [Verifying the Installation](#verifying-the-installation)
- [Performance Tips](#performance-tips)
- [Logs](#logs)
- [Security](#security)
- [Licence](#licence)
- [Acknowledgements](#acknowledgements)

## Features

- Handles Administrator elevation automatically
- Sets up WSL2 and manages any required reboots
- Installs the open source Docker Engine directly (not Docker Desktop, so no licence concerns)
- GitHub CLI gets installed with browser login
- SSH keys are generated and uploaded to your GitHub account
- Git identity is pulled from your GitHub profile
- Windows Terminal and VS Code are installed via winget
- Safe to run multiple times without breaking your existing setup

## Requirements

### Windows

| Component | Version |
|-----------|---------|
| Windows | 11 22H2 |
| PowerShell | 5.1 or 7.0 |

You'll need Administrator privileges and an internet connection.

### WSL/Linux

| Component | Version |
|-----------|---------|
| Bash | 5.2 |
| Distribution | Ubuntu or Debian (default) |

The Linux scripts need root access (via sudo).

## Quick Start

### Automated

1. Run `Double-Click-Me.bat`
2. Approve the Administrator prompt
3. Follow the prompts (restart if asked)

The batch file does the rest.

### Manual

If you prefer to run things step by step:

```powershell
# Open PowerShell as Administrator, then:
Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process
.\Setup-DevContainers.ps1
```

Or run each piece yourself:

```powershell
# Enable WSL2
wsl --install --no-distribution

# Install a distro
wsl --install -d Debian

# Inside WSL, run the Linux setup
sudo ./setup-wsl-devcontainers.sh --user yourusername

# Back in Windows, install the apps
winget install Microsoft.WindowsTerminal
winget install Microsoft.VisualStudioCode
code --install-extension ms-vscode-remote.remote-containers
code --install-extension ms-vscode-remote.remote-wsl
```

## Scripts

| Script | Platform | What it does |
|--------|----------|--------------|
| `Double-Click-Me.bat` | Windows | Entry point; handles UAC elevation |
| `Setup-DevContainers.ps1` | Windows | Main script that sets up WSL2, your distro, and Windows apps |
| `setup-wsl-devcontainers.sh` | Linux/WSL | Creates your user, configures sudo, sets up Git |
| `install-docker.sh` | Linux/WSL | Installs or removes Docker Engine |
| `install-github-cli.sh` | Linux/WSL | Installs GitHub CLI and sets up Git auth |

## Supported Distributions

| Distribution | Version | Support Until | Default |
|--------------|---------|---------------|---------|
| Debian | 13 Trixie | June 2030 | Yes |
| Ubuntu | 24.04 LTS | April 2029 | No |

## Options

### PowerShell (Setup-DevContainers.ps1)

| Parameter | What it does |
|-----------|--------------|
| `-Distro <Debian\|Ubuntu>` | Which distro to install (default: Debian) |
| `-Resume` | Pick up where you left off after a restart |
| `-DryRun` | Show what would happen without doing it |
| `-NonInteractive` | No prompts; use defaults |
| `-SkipApps` | Don't install Windows Terminal or VS Code |
| `-Force` | Overwrite existing config |
| `-Verbose` | More detailed output |

Examples:

```powershell
# Default setup
.\Setup-DevContainers.ps1

# Use Ubuntu instead
.\Setup-DevContainers.ps1 -Distro Ubuntu

# See what it would do
.\Setup-DevContainers.ps1 -DryRun -Verbose

# Unattended install
.\Setup-DevContainers.ps1 -NonInteractive
```

### Bash (setup-wsl-devcontainers.sh)

| Parameter | What it does |
|-----------|--------------|
| `--user USERNAME` | The username to create (required) |
| `--dry-run` | Preview mode |
| `--verbose`, `-v` | More output |
| `--skip-docker` | Don't install Docker |
| `--skip-github` | Don't install GitHub CLI |

Examples:

```bash
# Standard setup
sudo ./setup-wsl-devcontainers.sh --user john

# Preview
sudo ./setup-wsl-devcontainers.sh --user john --dry-run

# Skip optional bits
sudo ./setup-wsl-devcontainers.sh --user john --skip-docker --skip-github
```

### Docker (install-docker.sh)

| Parameter | What it does |
|-----------|--------------|
| `--user USERNAME` | Add this user to the docker group |
| `--remove` | Uninstall Docker Engine |
| `--purge` | Also delete images, containers, and volumes |
| `--force`, `-f` | Skip confirmation |

### GitHub CLI (install-github-cli.sh)

| Parameter | What it does |
|-----------|--------------|
| `--user USERNAME` | Who to set up auth for (required) |
| `--skip-ssh` | Don't generate SSH keys |
| `--skip-git-config` | Don't set Git name/email |
| `--remove` | Uninstall GitHub CLI |
| `--purge` | Also delete SSH keys |

## Verifying the Installation

Run these to check everything works:

```bash
# Docker
docker run hello-world

# GitHub CLI
gh auth status

# SSH to GitHub
ssh -T git@github.com

# Git config
git config --global user.name
git config --global user.email
```

## Performance Tips

### Keep your code in the Linux filesystem

Accessing files on `/mnt/c` is slow because it goes through the 9P protocol. Keep your projects in the Linux filesystem instead:

```bash
# Fast
~/projects/myapp

# Slow
/mnt/c/Users/.../myapp
```

The setup creates `~/projects` for this reason.

### WSL settings

The installer sets up `/etc/wsl.conf` with these settings:

```ini
[boot]
systemd=true

[user]
default=yourusername

[interop]
appendWindowsPath=false
```

### Git line endings

These are set automatically so you don't get CRLF issues:

```bash
git config --global core.autocrlf input
git config --global core.eol lf
```

## Logs

If something goes wrong, check these:

| Component | Log file |
|-----------|----------|
| PowerShell setup | `%LOCALAPPDATA%\DevContainersSetup\setup.log` |
| WSL setup | `/var/log/wsl-devcontainers-setup.log` |
| Docker | `/var/log/docker-wsl2-install.log` |
| GitHub CLI | `/var/log/github-cli-install.log` |

For WSL issues, try `wsl --status` and `wsl --update` from PowerShell. If Docker isn't responding, `wsl --shutdown` and reopen your terminal usually fixes it.

## Security

- All downloads happen over HTTPS (TLS 1.2+)
- GPG keys are checked against known fingerprints before being trusted
- Docker and GitHub CLI repos use signed packages
- SSH keys use Ed25519 without a passphrase 
- Passwordless sudo is enabled for the created user 

## Licence

Copyright (c) State Government of Victoria 2026. All rights reserved.
Licensed under the University of Illinois/NCSA Open Source Licence (UIUC). See [LICENSE](LICENSE).
p10k.zsh has been copied from [powerlevel10k](https://github.com/romkatv/powerlevel10k/blob/master/config/p10k-rainbow.zsh) and is licensed under the MIT Licence. 