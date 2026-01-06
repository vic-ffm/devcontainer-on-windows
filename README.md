# DevContainers Setup for Windows 11

Fully automated setup of VS Code DevContainers on Windows 11 via WSL2 with Docker Engine.

## Features

- **One-click setup** - Double-click `Setup-DevContainers.bat` and everything is configured
- **WSL2 auto-configuration** - Enables features, handles reboot, resumes automatically
- **Docker Engine** - Native Docker in WSL2 (no Docker Desktop, no licensing issues)
- **GitHub CLI & Git Authentication** - Auto-configures SSH keys and Git identity via GitHub OAuth
- **Optimal performance** - Configured for best DevContainers experience
- **Non-interactive mode** - Fully automated for CI/scripting

## Quick Start

### Option 1: Double-Click Setup (Recommended)

1. **Double-click `Setup-DevContainers.bat`**
2. Click "Yes" on the Administrator prompt
3. Wait for setup to complete (may require restart)
4. Done!

That's it. The batch file handles everything automatically.

### Option 2: PowerShell (Manual)

If you prefer running PowerShell directly:

1. Open PowerShell **as Administrator**
2. Navigate to this directory
3. Run:

```powershell
Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process
.\Setup-DevContainers.ps1
```

The script will:
1. Enable WSL2 features (restart if needed)
2. Install Debian 13 Trixie (or Ubuntu 24.04 LTS)
3. Create user with passwordless sudo
4. Install Docker Engine
5. Install GitHub CLI and configure Git authentication (SSH keys, identity)
6. Install Windows Terminal
7. Install VS Code with DevContainers extensions

### Option 2: Manual Setup

If you prefer manual control, run the scripts separately:

```powershell
# 1. Enable WSL2 (if not already)
wsl --install --no-distribution

# 2. Install distro
wsl --install -d Debian

# 3. Run Linux setup (in WSL as root)
sudo ./setup-wsl-devcontainers.sh --user yourusername

# 4. Install Windows apps manually
winget install Microsoft.WindowsTerminal
winget install Microsoft.VisualStudioCode
code --install-extension ms-vscode-remote.remote-containers
code --install-extension ms-vscode-remote.remote-wsl
```

## Scripts

| Script | Platform | Purpose |
|--------|----------|---------|
| `Setup-DevContainers.bat` | Windows | **Double-click to run** - auto-elevates, runs everything |
| `Setup-DevContainers.ps1` | Windows | Main orchestrator - handles everything |
| `setup-wsl-devcontainers.sh` | Linux/WSL | User creation, sudo, Git, Docker, GitHub CLI setup |
| `install-docker.sh` | Linux/WSL | Docker Engine installation |
| `install-github-cli.sh` | Linux/WSL | GitHub CLI installation and Git authentication |

## Supported Distributions

| Distribution | Version | Kernel | Support Until | Default |
|--------------|---------|--------|---------------|---------|
| Debian | 13 Trixie | Linux 6.12 LTS | 2030-06 | Yes |
| Ubuntu | 24.04 LTS | Linux 6.8 | 2029-04 | No |

## Usage

### Setup-DevContainers.ps1 (Windows)

```powershell
# Default setup (Debian 13)
.\Setup-DevContainers.ps1

# Use Ubuntu instead
.\Setup-DevContainers.ps1 -Distro Ubuntu

# Preview without changes
.\Setup-DevContainers.ps1 -DryRun -Verbose

# Fully automated (no prompts)
.\Setup-DevContainers.ps1 -NonInteractive

# Skip Windows apps
.\Setup-DevContainers.ps1 -SkipApps
```

### setup-wsl-devcontainers.sh (Linux)

```bash
# Standard setup
sudo ./setup-wsl-devcontainers.sh --user john

# Preview mode
sudo ./setup-wsl-devcontainers.sh --user john --dry-run

# Skip Docker
sudo ./setup-wsl-devcontainers.sh --user john --skip-docker

# Skip GitHub CLI setup
sudo ./setup-wsl-devcontainers.sh --user john --skip-github
```

### install-docker.sh (Linux)

```bash
# Install Docker
sudo ./install-docker.sh --user john

# Remove Docker
sudo ./install-docker.sh --remove

# Remove Docker and all data
sudo ./install-docker.sh --remove --purge --force
```

### install-github-cli.sh (Linux)

```bash
# Install GitHub CLI and configure authentication
sudo ./install-github-cli.sh --user john

# Skip SSH key generation
sudo ./install-github-cli.sh --user john --skip-ssh

# Skip Git identity configuration
sudo ./install-github-cli.sh --user john --skip-git-config

# Custom SSH key comment
sudo ./install-github-cli.sh --user john --ssh-key-comment "my-dev-machine"

# Preview mode
sudo ./install-github-cli.sh --user john --dry-run

# Remove GitHub CLI
sudo ./install-github-cli.sh --remove

# Remove GitHub CLI and SSH keys
sudo ./install-github-cli.sh --remove --purge --force
```

## Requirements

### Windows
- Windows 11 22H2+ (or Windows 10 2004+)
- PowerShell 5.1+ or PowerShell 7+
- Administrator privileges
- Internet connection

### Linux (WSL)
- Bash 5.2+
- Root privileges
- Ubuntu/Debian-based distribution

## Best Practices

### File System Performance

**Always store projects in the Linux filesystem, not `/mnt/c`**

```bash
# Good (fast)
~/projects/myapp

# Bad (slow - uses 9P protocol over network)
/mnt/c/Users/.../myapp
```

The setup creates `~/projects` for this purpose.

### WSL Configuration

The setup configures `/etc/wsl.conf` for optimal performance:

```ini
[boot]
systemd=true

[user]
default=yourusername

[interop]
appendWindowsPath=false  # Cleaner PATH, faster startup
```

### Git Line Endings

Configured automatically:
```bash
git config --global core.autocrlf input
git config --global core.eol lf
```

### Docker (Not Docker Desktop)

This setup uses **Docker Engine** (native in WSL2), not Docker Desktop:

- Free for all users (no licensing restrictions)
- Better performance (native Linux kernel)
- No separate Windows service required

## After Setup

1. **Open Windows Terminal** and select your distro from the dropdown
2. **Test Docker**: `docker run hello-world`
3. **Test GitHub SSH**: `ssh -T git@github.com`
4. **Clone a project**: `cd ~/projects && git clone git@github.com:user/repo.git`
5. **Open in VS Code**: `code .`
6. **Use DevContainers**: Command Palette → "Dev Containers: Reopen in Container"

### GitHub Authentication

During setup, you'll be prompted to authenticate with GitHub via browser OAuth:

1. A URL and code will be displayed in the terminal
2. Open the URL in your browser and enter the code
3. Authorize the GitHub CLI application
4. Your SSH key is automatically generated and uploaded to GitHub
5. Git identity (name/email) is configured from your GitHub profile

To verify authentication:

```bash
# Check GitHub CLI status
gh auth status

# Test SSH connection
ssh -T git@github.com

# Verify Git config
git config --global user.name
git config --global user.email
```

## Troubleshooting

### WSL not starting after reboot

```powershell
# Check WSL status
wsl --status

# Update WSL
wsl --update

# Set default version
wsl --set-default-version 2
```

### Docker not running

```bash
# Check systemd
systemctl status docker

# Start Docker
sudo systemctl start docker

# If systemd not running, restart WSL
# From PowerShell:
wsl --shutdown
```

### Permission denied on Docker

```bash
# Add user to docker group
sudo usermod -aG docker $USER

# Apply group (or restart WSL)
newgrp docker
```

### VS Code can't connect to WSL

1. Ensure WSL extension is installed
2. Try: `code --remote wsl+Debian .`
3. Check VS Code Server: `~/.vscode-server/`

## Log Files

| Log | Location |
|-----|----------|
| PowerShell setup | `%LOCALAPPDATA%\DevContainersSetup\setup.log` |
| WSL setup | `/var/log/wsl-devcontainers-setup.log` |
| Docker install | `/var/log/docker-wsl2-install.log` |
| GitHub CLI install | `/var/log/github-cli-install.log` |

## License

BSD 3-Clause "New" or "Revised" License

## Credits

- Docker installation script based on official Docker documentation
- WSL2 best practices from Microsoft and Docker documentation
