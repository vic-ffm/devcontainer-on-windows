#!/usr/bin/env bash
# SPDX-License-Identifier: NCSA
#===============================================================================
# setup-wsl-devcontainers.sh - WSL2 user and system setup for DevContainers
#
# DESCRIPTION:
#   Configures a fresh WSL2 distribution for VS Code DevContainers:
#   - Creates non-root user with passwordless sudo
#   - Configures /etc/wsl.conf for optimal performance
#   - Sets up Git with proper line ending handling
#   - Installs Docker via install-docker.sh
#   - Installs GitHub CLI and configures Git authentication
#   - Configures SSH agent for devcontainer credential forwarding
#   Non-interactive and idempotent.
#
# REQUIREMENTS:
#   Bash 5.2+
#   Root privileges
#
# USAGE:
#   sudo ./setup-wsl-devcontainers.sh --user USERNAME
#   sudo ./setup-wsl-devcontainers.sh --user USERNAME --verbose
#   sudo ./setup-wsl-devcontainers.sh --user USERNAME --dry-run
#
# OPTIONS:
#   --user USERNAME    Username to create (required)
#   --dry-run          Show what would be done without making changes
#   --verbose, -v      Enable verbose output
#   --skip-docker      Skip Docker installation
#   --skip-github      Skip GitHub CLI installation and authentication
#   --skip-shell       Skip shell customization (Zsh/Oh-My-Zsh/Powerlevel10k/mise)
#   --skip-ssh-agent   Skip SSH agent configuration for devcontainers
#   --help, -h         Show this help message
#
# ENVIRONMENT:
#   TRACE=1            Enable bash debug tracing
#
# LICENSE:             NCSA
#===============================================================================

# shellcheck enable=check-set-e-suppressed
# shellcheck enable=check-extra-masked-returns

#-------------------------------------------------------------------------------
# Bash Version Check
#-------------------------------------------------------------------------------
if ((BASH_VERSINFO[0] < 5 || (BASH_VERSINFO[0] == 5 && BASH_VERSINFO[1] < 2))); then
  printf 'Error: This script requires Bash 5.2+. Current: %s\n' "${BASH_VERSION}" >&2
  exit 1
fi

#-------------------------------------------------------------------------------
# Strict Mode & Safety Settings
#-------------------------------------------------------------------------------
set -o errexit
set -o errtrace
set -o nounset
set -o pipefail
shopt -s extglob
shopt -s globskipdots
shopt -s inherit_errexit
shopt -s assoc_expand_once

# Enable debug tracing if TRACE=1
[[ ${TRACE:-0} == 1 ]] && set -o xtrace

#-------------------------------------------------------------------------------
# Constants
#-------------------------------------------------------------------------------
declare -r SCRIPT_NAME="${0##*/}"
declare -r SCRIPT_VERSION="1.0.0"
declare -r LOG_FILE="/var/log/wsl-devcontainers-setup.log"
declare -r LOCK_FILE="/var/lock/wsl-devcontainers-setup.lock"

# Lock timeout (seconds)
declare -ri LOCK_TIMEOUT=300

# shellcheck disable=SC2034  # EXIT_SUCCESS defined for completeness
declare -ri EXIT_SUCCESS=0
declare -ri EXIT_GENERAL_ERROR=1
declare -ri EXIT_LOCK_FAILED=2
declare -ri EXIT_INVALID_ARGS=3
declare -ri EXIT_ROOT_REQUIRED=4
declare -ri EXIT_NOT_WSL2=5
declare -ri EXIT_DOCKER_FAILED=6
declare -ri EXIT_GITHUB_FAILED=7
# shellcheck disable=SC2034  # EXIT_USER_CANCELLED defined for completeness
declare -ri EXIT_USER_CANCELLED=8
declare -ri EXIT_SHELL_FAILED=9
# shellcheck disable=SC2034  # EXIT_SSH_AGENT_FAILED defined for completeness
declare -ri EXIT_SSH_AGENT_FAILED=10

# Required commands
declare -ra REQUIRED_COMMANDS=(
  useradd chpasswd usermod chmod chown mkdir rm cp mv
  grep sed tee cat id getent visudo sudo
  flock pgrep apt-get
)

declare -ra PREREQUISITES=(
  ca-certificates
  curl
  wget
  git
  gnupg
  openssh-client
  bash-completion
  less
  nano
  vim
  unzip
  build-essential
)

#-------------------------------------------------------------------------------
# Global State Variables
#-------------------------------------------------------------------------------
declare TARGET_USER=""
declare DRY_RUN=false
declare VERBOSE=false
declare SKIP_DOCKER=false
declare SKIP_GITHUB=false
declare SKIP_SHELL=false
declare SKIP_SSH_AGENT=false

# Cleanup state tracking
declare -i CLEANUP_IN_PROGRESS=0
declare -i SIGNAL_RECEIVED=0
declare RECEIVED_SIGNAL=""
declare -a CLEANUP_ACTIONS=()
declare -A CREATED_FILES=()
declare -A MODIFIED_FILES=()

#-------------------------------------------------------------------------------
# Terminal Colours
#-------------------------------------------------------------------------------
declare -A COLORS
if [[ -t 1 && ${TERM:-dumb} != dumb ]]; then
  COLORS=(
    [red]='\033[0;31m'
    [green]='\033[0;32m'
    [yellow]='\033[0;33m'
    [blue]='\033[0;34m'
    [cyan]='\033[0;36m'
    [bold]='\033[1m'
    [reset]='\033[0m'
  )
else
  COLORS=([red]='' [green]='' [yellow]='' [blue]='' [cyan]='' [bold]='' [reset]='')
fi

#-------------------------------------------------------------------------------
# Logging
#-------------------------------------------------------------------------------
_log() {
  local -r level="$1" color="$2" msg="$3"
  local timestamp
  printf -v timestamp '%(%Y-%m-%d %H:%M:%S)T' "${EPOCHSECONDS}"
  printf '%b[%s]%b %s - %s\n' "${COLORS[${color}]}" "${level}" "${COLORS[reset]}" "${timestamp}" "${msg}" | tee -a "${LOG_FILE}"
}

log_info() { _log "INFO " "blue" "$1"; }
log_success() { _log "OK   " "green" "$1"; }
log_warn() { _log "WARN " "yellow" "$1" >&2; }
log_error() { _log "ERROR" "red" "$1" >&2; }
log_debug() {
  if [[ ${VERBOSE} == true ]]; then
    _log "DEBUG" "cyan" "$1"
  fi
}

log_step() {
  local -r step="$1" desc="$2"
  printf '\n%b%b[Step %s]%b %s\n' "${COLORS[bold]}" "${COLORS[blue]}" "${step}" "${COLORS[reset]}" "${desc}" | tee -a "${LOG_FILE}"
  printf '%s\n' "$(printf -- '-%.0s' {1..60})" | tee -a "${LOG_FILE}"
}

#-------------------------------------------------------------------------------
# Utility Functions
#-------------------------------------------------------------------------------
die() {
  log_error "$1"
  exit "${2:-1}"
}

has_command() {
  command -v "$1" &>/dev/null
}

# Execute or simulate based on dry-run mode
execute() {
  if [[ ${DRY_RUN} == true ]]; then
    log_info "[DRY-RUN] Would execute: ${*@Q}"
    return 0
  fi
  log_debug "Executing: ${*@Q}"
  "$@"
}

# Check if running in WSL2
is_wsl2() {
  local version_info
  [[ -f /proc/version ]] || return 1
  version_info=$(<"/proc/version")
  local -r version_info
  [[ ${version_info} =~ [Mm]icrosoft.*[Ww][Ss][Ll]2|[Ww][Ss][Ll]2.*[Mm]icrosoft ]] && return 0
  [[ ${version_info} =~ [Mm]icrosoft && -d /run/WSL ]] && return 0
  return 1
}

# Validate username
validate_username() {
  local -r user="$1"
  if [[ ! ${user} =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
    die "Invalid username format: '${user}'. Must be POSIX-compliant (lowercase, start with letter/underscore, max 32 chars)" "${EXIT_INVALID_ARGS}"
  fi
}

validate_required_commands() {
  log_info "Validating required commands..."

  local -a missing=()
  local cmd

  for cmd in "${REQUIRED_COMMANDS[@]}"; do
    # shellcheck disable=SC2310  # Intentional: capture result in conditional
    if ! has_command "${cmd}"; then
      missing+=("${cmd}")
    fi
  done

  if ((${#missing[@]} > 0)); then
    log_error "Missing required command(s): ${missing[*]}"
    die "Install missing commands and try again" "${EXIT_GENERAL_ERROR}"
  fi

  log_success "All required commands available"
}

#-------------------------------------------------------------------------------
# Lock
#-------------------------------------------------------------------------------
acquire_lock() {
  log_debug "Acquiring lock: ${LOCK_FILE}"

  mkdir -p "${LOCK_FILE%/*}"

  # Open lock file
  exec {LOCK_FD}>"${LOCK_FILE}"

  if ! flock -w "${LOCK_TIMEOUT}" "${LOCK_FD}"; then
    die "Could not acquire lock within ${LOCK_TIMEOUT}s. Another instance may be running." "${EXIT_LOCK_FAILED}"
  fi

  # Write PID for debugging
  printf '%d\n' $$ >&"${LOCK_FD}"
  log_debug "Lock acquired (PID: $$)"

  # Register lock release as cleanup action
  register_cleanup "release_lock"
}

release_lock() {
  if [[ -v LOCK_FD ]]; then
    exec {LOCK_FD}>&- 2>/dev/null || true
    log_debug "Lock released"
  fi
}

#-------------------------------------------------------------------------------
# Cleanup Action Registry
#-------------------------------------------------------------------------------
register_cleanup() {
  local -r action="$1"
  CLEANUP_ACTIONS+=("${action}")
  log_debug "Registered cleanup action: ${action}"
}

register_created_file() {
  local -r file="$1"
  CREATED_FILES["${file}"]=1
  log_debug "Registered created file: ${file}"
}

register_modified_file() {
  local -r file="$1" backup="$2"
  MODIFIED_FILES["${file}"]="${backup}"
  log_debug "Registered modified file: ${file} (backup: ${backup})"
}

backup_file() {
  local -r file="$1"
  if [[ -f ${file} ]]; then
    local -r backup="${file}.bak.${SRANDOM}"
    cp -a "${file}" "${backup}" 2>/dev/null || true
    register_modified_file "${file}" "${backup}"
    echo "${backup}"
  fi
}

#-------------------------------------------------------------------------------
# Signal Definitions
#-------------------------------------------------------------------------------
declare -rA SIGNAL_INFO=(
  [HUP]="1:Hangup:graceful"
  [INT]="2:Interrupt:graceful"
  [QUIT]="3:Quit:graceful"
  [TERM]="15:Terminated:graceful"
  [ILL]="4:Illegal instruction:fatal"
  [ABRT]="6:Aborted:fatal"
  [SEGV]="11:Segmentation fault:fatal"
)

#-------------------------------------------------------------------------------
# Signal Handler
#-------------------------------------------------------------------------------
signal_handler() {
  local -r sig_name="${1:-UNKNOWN}"
  local sig_num=1 sig_desc="Unknown signal" sig_type="fatal"

  # Prevent re-entrant signal handling
  if ((SIGNAL_RECEIVED)); then
    return
  fi
  SIGNAL_RECEIVED=1
  RECEIVED_SIGNAL="${sig_name}"

  # Parse signal info
  if [[ -v SIGNAL_INFO[${sig_name}] ]]; then
    IFS=':' read -r sig_num sig_desc sig_type <<<"${SIGNAL_INFO[${sig_name}]}"
  fi

  local -ri exit_code=$((128 + sig_num))

  case "${sig_type}" in
    graceful)
      log_warn "Received SIG${sig_name} (${sig_desc}) - initiating graceful shutdown..."
      ;;
    fatal)
      log_error "FATAL: Received SIG${sig_name} (${sig_desc}) - attempting emergency cleanup..."
      ;;
    *)
      log_warn "Unknown signal type: ${sig_type}"
      ;;
  esac

  exit "${exit_code}"
}

#-------------------------------------------------------------------------------
# Error Handling
#-------------------------------------------------------------------------------
error_handler() {
  local -ri exit_code=$?
  local -r failed_cmd="${BASH_COMMAND}"
  local -r line="${BASH_LINENO[0]}"
  local -r func="${FUNCNAME[1]:-main}"
  local -r src="${BASH_SOURCE[1]:-${SCRIPT_NAME}}"

  ((exit_code == 0)) && return 0

  log_error "Command failed with exit code ${exit_code}"
  log_error "  Location: ${func}() at ${src}:${line}"
  log_error "  Command:  ${failed_cmd}"

  if [[ ${VERBOSE} == true ]]; then
    log_debug "Stack trace:"
    local -i i
    for ((i = 1; i < ${#FUNCNAME[@]}; i++)); do
      log_debug "  [${i}] ${FUNCNAME[i]}() at ${BASH_SOURCE[i]:-unknown}:${BASH_LINENO[i - 1]}"
    done
  fi
}

#-------------------------------------------------------------------------------
# Cleanup Handling
#-------------------------------------------------------------------------------
cleanup_processes() {
  local -a child_pids
  mapfile -t child_pids < <(pgrep -P $$ 2>/dev/null || true)

  if ((${#child_pids[@]} > 0)); then
    log_debug "Terminating ${#child_pids[@]} child process(es)"
    for pid in "${child_pids[@]}"; do
      kill -TERM "${pid}" 2>/dev/null || true
    done
    sleep 0.5
    for pid in "${child_pids[@]}"; do
      kill -KILL "${pid}" 2>/dev/null || true
    done
  fi
}

cleanup() {
  local -ri original_exit_code=${?}
  local -i exit_code=${original_exit_code}

  # Prevent recursive cleanup
  if ((CLEANUP_IN_PROGRESS)); then
    return
  fi
  CLEANUP_IN_PROGRESS=1

  # Disable all signal traps during cleanup
  trap '' INT TERM HUP QUIT

  log_debug "Cleanup triggered (exit_code=${exit_code}, signal=${RECEIVED_SIGNAL:-none})"

  cleanup_processes

  if [[ -n ${RECEIVED_SIGNAL} ]]; then
    log_info "Cleaning up after SIG${RECEIVED_SIGNAL}..."
  fi

  # Execute registered cleanup actions in reverse order (LIFO)
  local -i i
  for ((i = ${#CLEANUP_ACTIONS[@]} - 1; i >= 0; i--)); do
    local action="${CLEANUP_ACTIONS[i]}"
    log_debug "Executing cleanup action: ${action}"
    if declare -F "${action}" &>/dev/null; then
      "${action}" 2>/dev/null || true
    fi
  done

  # Rollback on failure
  if ((exit_code != 0)); then
    log_info "Rolling back changes..."

    for file in "${!CREATED_FILES[@]}"; do
      if [[ -f ${file} ]]; then
        log_debug "Removing created file: ${file}"
        rm -f "${file}" 2>/dev/null || true
      fi
    done

    for file in "${!MODIFIED_FILES[@]}"; do
      local backup="${MODIFIED_FILES[${file}]}"
      if [[ -f ${backup} ]]; then
        log_debug "Restoring ${file} from ${backup}"
        mv -f "${backup}" "${file}" 2>/dev/null || true
      fi
    done
  else
    # Success: remove backup files
    for file in "${!MODIFIED_FILES[@]}"; do
      local backup="${MODIFIED_FILES[${file}]}"
      rm -f "${backup}" 2>/dev/null || true
    done
  fi

  if ((exit_code != 0)); then
    log_error "Script failed with exit code: ${exit_code}"
    [[ -n ${RECEIVED_SIGNAL} ]] && log_error "Terminated by: SIG${RECEIVED_SIGNAL}"
    log_info "Log file: ${LOG_FILE}"
  fi

  exit "${exit_code}"
}

#-------------------------------------------------------------------------------
# Setup Signal Handlers
#-------------------------------------------------------------------------------
setup_signal_handlers() {
  trap cleanup EXIT
  trap error_handler ERR
  trap 'signal_handler HUP' HUP
  trap 'signal_handler INT' INT
  trap 'signal_handler QUIT' QUIT
  trap 'signal_handler TERM' TERM
  trap 'signal_handler ILL' ILL
  trap 'signal_handler ABRT' ABRT
  trap 'signal_handler SEGV' SEGV

  log_debug "Signal handlers installed"
}

#-------------------------------------------------------------------------------
# Validation
#-------------------------------------------------------------------------------
check_root() {
  ((EUID == 0)) || die "This script must be run as root. Use: sudo ${SCRIPT_NAME}" "${EXIT_ROOT_REQUIRED}"
}

check_wsl2() {
  log_info "Checking WSL2 environment..."
  # shellcheck disable=SC2310  # Intentional: die terminates on failure
  is_wsl2 || die "This script requires WSL2. Detected non-WSL2 system." "${EXIT_NOT_WSL2}"
  log_success "WSL2 environment confirmed"
}

#-------------------------------------------------------------------------------
# Prerequisites
#-------------------------------------------------------------------------------
install_prerequisites() {
  log_info "Installing prerequisites..."

  if [[ ${DRY_RUN} == true ]]; then
    log_info "[DRY-RUN] Would install: ${PREREQUISITES[*]}"
    return 0
  fi

  export DEBIAN_FRONTEND=noninteractive

  log_debug "Updating package index..."
  apt-get update -qq

  log_debug "Installing: ${PREREQUISITES[*]}"
  apt-get install -y -qq "${PREREQUISITES[@]}"

  log_success "Prerequisites installed"
}

#-------------------------------------------------------------------------------
# User Setup
#-------------------------------------------------------------------------------
create_user() {
  local -r username="$1"

  log_step "1/10" "Creating user '${username}'"

  # Check if user already exists
  if id "${username}" &>/dev/null; then
    log_info "User '${username}' already exists"
    return 0
  fi

  # Generate secure random password (32 chars)
  # User will never need this due to passwordless sudo
  local password
  password=$(head -c 32 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 32)
  local -r password

  if [[ ${DRY_RUN} == true ]]; then
    log_info "[DRY-RUN] Would create user: ${username}"
    return 0
  fi

  # Create user with home directory and bash shell
  execute useradd -m -s /bin/bash "${username}"

  # Set password
  printf '%s:%s' "${username}" "${password}" | execute chpasswd

  log_success "User '${username}' created"
}

configure_passwordless_sudo() {
  local -r username="$1"

  log_step "2/10" "Configuring passwordless sudo"

  local -r sudoers_file="/etc/sudoers.d/${username}"
  local -r sudoers_content="${username} ALL=(ALL) NOPASSWD:ALL"

  # Check if already configured
  if [[ -f ${sudoers_file} ]] && grep -qF "${sudoers_content}" "${sudoers_file}" 2>/dev/null; then
    log_success "Passwordless sudo already configured"
    return 0
  fi

  if [[ ${DRY_RUN} == true ]]; then
    log_info "[DRY-RUN] Would configure passwordless sudo for: ${username}"
    return 0
  fi

  # Write sudoers file with correct permissions
  printf '%s\n' "${sudoers_content}" >"${sudoers_file}"
  chmod 0440 "${sudoers_file}"
  register_created_file "${sudoers_file}"

  # Validate sudoers syntax
  if ! visudo -cf "${sudoers_file}" &>/dev/null; then
    rm -f "${sudoers_file}"
    die "Invalid sudoers configuration" "${EXIT_GENERAL_ERROR}"
  fi

  log_success "Passwordless sudo configured"
}

configure_wsl() {
  local -r username="$1"

  log_step "3/10" "Configuring WSL environment"

  local -r wsl_conf="/etc/wsl.conf"

  # Check if already configured correctly
  if [[ -f ${wsl_conf} ]]; then
    if grep -q "^systemd=true" "${wsl_conf}" 2>/dev/null \
      && grep -q "^default=${username}" "${wsl_conf}" 2>/dev/null; then
      log_success "WSL already configured correctly"
      return 0
    fi
  fi

  if [[ ${DRY_RUN} == true ]]; then
    log_info "[DRY-RUN] Would configure ${wsl_conf}"
    return 0
  fi

  # Backup existing config
  [[ -f ${wsl_conf} ]] && backup_file "${wsl_conf}"

  # Write wsl.conf
  cat >"${wsl_conf}" <<EOF
# WSL Configuration for DevContainers
# Generated by ${SCRIPT_NAME} v${SCRIPT_VERSION}

[boot]
systemd=true

[user]
default=${username}

[interop]
appendWindowsPath=false
EOF

  [[ ! -v MODIFIED_FILES["${wsl_conf}"] ]] && register_created_file "${wsl_conf}"

  log_success "WSL configured (systemd enabled, default user: ${username})"
  log_warn "WSL restart required: wsl --shutdown"
}

configure_git() {
  local -r username="$1"
  local -r user_home="/home/${username}"

  log_step "4/10" "Configuring Git"

  if [[ ${DRY_RUN} == true ]]; then
    log_info "[DRY-RUN] Would configure Git for ${username}"
    return 0
  fi

  # shellcheck disable=SC2310  # Intentional: capture result in conditional
  if ! has_command git; then
    log_warn "Git not found, installing..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq git
  fi

  # Configure Git as the target user
  sudo -u "${username}" git config --global core.autocrlf input
  sudo -u "${username}" git config --global core.eol lf
  sudo -u "${username}" git config --global init.defaultBranch main

  log_success "Git configured (line endings: LF, default branch: main)"

  # Create projects directory
  local -r projects_dir="${user_home}/projects"
  if [[ ! -d ${projects_dir} ]]; then
    sudo -u "${username}" mkdir -p "${projects_dir}"
    log_info "Created ${projects_dir} for storing projects"
    log_info "Best practice: Store code in Linux filesystem, not /mnt/c"
  else
    log_debug "Projects directory already exists: ${projects_dir}"
  fi
}

install_docker() {
  local -r username="$1"

  log_step "5/10" "Installing Docker"

  if [[ ${SKIP_DOCKER} == true ]]; then
    log_info "Skipping Docker installation (--skip-docker)"
    return 0
  fi

  # Check for local installer first
  # shellcheck disable=SC2312  # Intentional: failure here will cause file checks to fail gracefully
  local -r script_dir="$(dirname "$(readlink -f "$0")")"
  local installer=""

  if [[ -f "${script_dir}/install-docker.sh" ]]; then
    installer="${script_dir}/install-docker.sh"
    log_debug "Using bundled Docker installer: ${installer}"
  elif [[ -f "/tmp/install-docker.sh" ]]; then
    installer="/tmp/install-docker.sh"
    log_debug "Using /tmp Docker installer"
  else
    die "install-docker.sh not found. Place it in the same directory as this script." "${EXIT_DOCKER_FAILED}"
  fi

  if [[ ${DRY_RUN} == true ]]; then
    log_info "[DRY-RUN] Would execute: ${installer} --user ${username}"
    return 0
  fi

  # Execute Docker installer
  local -a docker_args=(--user "${username}")
  [[ ${VERBOSE} == true ]] && docker_args+=(--verbose)

  bash "${installer}" "${docker_args[@]}"
  local -ri rc=$?

  if ((rc != 0)); then
    die "Docker installation failed (exit code: ${rc})" "${EXIT_DOCKER_FAILED}"
  fi

  log_success "Docker installed successfully"
}

install_github_cli() {
  local -r username="$1"

  log_step "6/10" "Installing GitHub CLI and configuring authentication"

  if [[ ${SKIP_GITHUB} == true ]]; then
    log_info "Skipping GitHub CLI installation (--skip-github)"
    return 0
  fi

  # Check for local installer
  # shellcheck disable=SC2312  # Intentional: failure here will cause file checks to fail gracefully
  local -r script_dir="$(dirname "$(readlink -f "$0")")"
  local installer=""

  if [[ -f "${script_dir}/install-github-cli.sh" ]]; then
    installer="${script_dir}/install-github-cli.sh"
    log_debug "Using bundled GitHub CLI installer: ${installer}"
  elif [[ -f "/tmp/install-github-cli.sh" ]]; then
    installer="/tmp/install-github-cli.sh"
    log_debug "Using /tmp GitHub CLI installer"
  else
    log_warn "install-github-cli.sh not found - skipping GitHub CLI setup"
    log_warn "To install GitHub CLI later, run: sudo ./install-github-cli.sh --user ${username}"
    return 0
  fi

  if [[ ${DRY_RUN} == true ]]; then
    log_info "[DRY-RUN] Would execute: ${installer} --user ${username}"
    return 0
  fi

  # Execute GitHub CLI installer
  local -a gh_args=(--user "${username}")
  [[ ${VERBOSE} == true ]] && gh_args+=(--verbose)

  bash "${installer}" "${gh_args[@]}"
  local -ri rc=$?

  if ((rc != 0)); then
    die "GitHub CLI installation failed (exit code: ${rc})" "${EXIT_GITHUB_FAILED}"
  fi

  log_success "GitHub CLI installed and configured"
}

configure_ssh_agent() {
  local -r username="$1"
  local -r user_home="/home/${username}"
  # shellcheck disable=SC2312  # Intentional: command substitution in readonly variable
  local -r user_id="$(id -u "${username}")"
  local -r systemd_user_dir="${user_home}/.config/systemd/user"
  local -r service_file="${systemd_user_dir}/ssh-agent.service"

  log_step "7/10" "Configuring SSH agent for devcontainers"

  if [[ ${SKIP_SSH_AGENT} == true ]]; then
    log_info "Skipping SSH agent configuration (--skip-ssh-agent)"
    return 0
  fi

  # Skip if GitHub CLI was skipped (no SSH key to load)
  if [[ ${SKIP_GITHUB} == true ]]; then
    log_info "Skipping SSH agent (GitHub CLI was skipped)"
    return 0
  fi

  if [[ ${DRY_RUN} == true ]]; then
    log_info "[DRY-RUN] Would configure SSH agent systemd service"
    return 0
  fi

  # Check if systemd is available
  if ! pidof systemd &>/dev/null; then
    log_warn "systemd not running - SSH agent will be configured but not started"
    log_warn "It will start after: wsl --shutdown && wsl"
  fi

  # Create systemd user directory
  log_info "Creating systemd user directory..."
  sudo -u "${username}" mkdir -p "${systemd_user_dir}"

  # Create ssh-agent.service
  log_info "Installing SSH agent systemd service..."

  cat >"${service_file}" <<'SERVICE_EOF'
[Unit]
Description=SSH Authentication Agent
Documentation=man:ssh-agent(1)

[Service]
Type=simple
Environment=SSH_AUTH_SOCK=%t/ssh-agent.socket
ExecStart=/usr/bin/ssh-agent -D -a %t/ssh-agent.socket
ExecStartPost=-/usr/bin/ssh-add %h/.ssh/id_ed25519_github
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
SERVICE_EOF

  chown "${username}:${username}" "${service_file}"
  chmod 644 "${service_file}"
  register_created_file "${service_file}"

  # Enable lingering for user (required for WSL2 to start user services at boot)
  log_info "Enabling user session persistence..."
  loginctl enable-linger "${username}"

  # Reload systemd user daemon and enable service
  log_info "Enabling SSH agent service..."

  # Need to set XDG_RUNTIME_DIR for systemctl --user to work when running as root
  local -r runtime_dir="/run/user/${user_id}"

  sudo -u "${username}" XDG_RUNTIME_DIR="${runtime_dir}" \
    systemctl --user daemon-reload 2>/dev/null || true

  sudo -u "${username}" XDG_RUNTIME_DIR="${runtime_dir}" \
    systemctl --user enable ssh-agent.service 2>/dev/null || true

  # Start service if systemd is running
  if pidof systemd &>/dev/null; then
    log_info "Starting SSH agent service..."
    sudo -u "${username}" XDG_RUNTIME_DIR="${runtime_dir}" \
      systemctl --user start ssh-agent.service 2>/dev/null || true

    # Wait briefly for socket to be created
    sleep 1

    # Verify socket exists
    local -r socket_path="${runtime_dir}/ssh-agent.socket"
    if [[ -S "${socket_path}" ]]; then
      log_success "SSH agent socket created: ${socket_path}"

      # Export SSH_AUTH_SOCK to systemd user environment for non-interactive access
      # This makes the variable available to VS Code Remote and other non-shell processes
      sudo -u "${username}" XDG_RUNTIME_DIR="${runtime_dir}" \
        systemctl --user set-environment SSH_AUTH_SOCK="${socket_path}" 2>/dev/null || true
      log_debug "Exported SSH_AUTH_SOCK to systemd user environment"
    else
      log_warn "SSH agent socket not found (may appear after WSL restart)"
    fi
  fi

  log_success "SSH agent configured for devcontainers"
}

install_shell_customization() {
  local -r username="$1"

  log_step "8/10" "Installing shell customization (Zsh/Oh-My-Zsh/Powerlevel10k/mise)"

  if [[ ${SKIP_SHELL} == true ]]; then
    log_info "Skipping shell customization (--skip-shell)"
    return 0
  fi

  # Check for local installer
  # shellcheck disable=SC2312  # Intentional: failure here will cause file checks to fail gracefully
  local -r script_dir="$(dirname "$(readlink -f "$0")")"
  local installer=""

  if [[ -f "${script_dir}/install-shell-customization.sh" ]]; then
    installer="${script_dir}/install-shell-customization.sh"
    log_debug "Using bundled shell customization installer: ${installer}"
  elif [[ -f "/tmp/install-shell-customization.sh" ]]; then
    installer="/tmp/install-shell-customization.sh"
    log_debug "Using /tmp shell customization installer"
  else
    log_warn "install-shell-customization.sh not found - skipping shell customization"
    log_warn "To install shell customization later, run: sudo ./install-shell-customization.sh --user ${username}"
    return 0
  fi

  if [[ ${DRY_RUN} == true ]]; then
    log_info "[DRY-RUN] Would execute: ${installer} --user ${username}"
    return 0
  fi

  # Execute shell customization installer
  local -a shell_args=(--user "${username}")
  [[ ${VERBOSE} == true ]] && shell_args+=(--verbose)

  bash "${installer}" "${shell_args[@]}"
  local -ri rc=$?

  if ((rc != 0)); then
    die "Shell customization installation failed (exit code: ${rc})" "${EXIT_SHELL_FAILED}"
  fi

  log_success "Shell customization installed successfully"
}

# Helper: Remove old Windows integration configuration from shell RC files
# This handles migration from the previous approach that added System32 to PATH
migrate_old_windows_integration() {
  local -r bashrc="$1"
  local -r zshrc="$2"
  local -r old_marker="# Windows Integration (VS Code + System32)"

  for shell_rc in "${bashrc}" "${zshrc}"; do
    if [[ -f "${shell_rc}" ]] && grep -q "${old_marker}" "${shell_rc}" 2>/dev/null; then
      log_info "Migrating old Windows integration in $(basename "${shell_rc}")..."
      # Remove the marker line and the PATH export line that follows it
      sed -i "/${old_marker}/,+1d" "${shell_rc}"
      log_debug "Removed old Windows integration from $(basename "${shell_rc}")"
    fi
  done
}

# Helper: Create the shared Windows integration file with VS Code PATH and selective aliases
create_windows_integration_file() {
  local -r integration_file="$1"
  local -r vscode_bin_path="$2"

  log_info "Creating Windows integration file..."

  # Start with header
  cat >"${integration_file}" <<'HEADER_EOF'
# WSL Windows Integration
# Provides selective access to Windows executables without PATH pollution
# Generated by setup-wsl-devcontainers.sh - DO NOT EDIT MANUALLY

HEADER_EOF

  # Add VS Code PATH if found (code command needs PATH entry for full functionality)
  if [[ -n "${vscode_bin_path}" ]]; then
    cat >>"${integration_file}" <<EOF
# VS Code (requires PATH entry for full functionality)
export PATH="\$PATH:${vscode_bin_path}"

EOF
    log_debug "Added VS Code to integration file: ${vscode_bin_path}"
  fi

  # Add SSH_AUTH_SOCK for devcontainer access
  cat >>"${integration_file}" <<'SSH_AGENT_EOF'
# SSH Agent for DevContainers
# Socket path is predictable for mounting into containers
_ssh_agent_socket="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/ssh-agent.socket"
if [[ -S "${_ssh_agent_socket}" ]]; then
    export SSH_AUTH_SOCK="${_ssh_agent_socket}"
    # Ensure systemd user environment has SSH_AUTH_SOCK for non-interactive access
    # (handles cases where user logs in before service fully starts)
    if command -v systemctl &>/dev/null; then
        systemctl --user set-environment SSH_AUTH_SOCK="${_ssh_agent_socket}" 2>/dev/null || true
    fi
fi
unset _ssh_agent_socket

SSH_AGENT_EOF

  # Add selective Windows executable functions and aliases
  cat >>"${integration_file}" <<'ALIASES_EOF'
# Selective Windows commands (NOT entire System32 in PATH)
# Functions use wslpath to translate Linux paths to Windows UNC paths

# Explorer - uses function for path translation (explorer.exe doesn't understand Linux paths)
if [[ -x "/mnt/c/Windows/explorer.exe" ]]; then
  explorer() {
    local target="${1:-.}"
    /mnt/c/Windows/explorer.exe "$(wslpath -w "$target" 2>/dev/null || echo "$target")"
  }
  alias explorer.exe='explorer'
fi

# Notepad - uses function for path translation
if [[ -x "/mnt/c/Windows/System32/notepad.exe" ]]; then
  notepad() {
    local file="$1"
    if [[ -n "$file" ]]; then
      /mnt/c/Windows/System32/notepad.exe "$(wslpath -w "$file" 2>/dev/null || echo "$file")"
    else
      /mnt/c/Windows/System32/notepad.exe
    fi
  }
  alias notepad.exe='notepad'
fi

# Clipboard utility (no path translation needed - receives piped input)
[[ -x "/mnt/c/Windows/System32/clip.exe" ]] && alias clip.exe='/mnt/c/Windows/System32/clip.exe'

# PowerShell (no path translation - used for running commands)
[[ -x "/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe" ]] && alias powershell.exe='/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe'
ALIASES_EOF

  log_debug "Windows integration file created at: ${integration_file}"
}

# Helper: Add source statement to shell RC file if not already present
add_integration_source() {
  local -r shell_rc="$1"
  local -r integration_file="$2"
  local -r marker="# WSL Windows Integration"

  [[ -f "${shell_rc}" ]] || return 0

  if grep -q "${marker}" "${shell_rc}" 2>/dev/null; then
    log_debug "Windows integration already sourced in $(basename "${shell_rc}")"
    return 0
  fi

  log_info "Adding Windows integration source to $(basename "${shell_rc}")..."
  cat >>"${shell_rc}" <<EOF

${marker}
[[ -f ~/.wsl-windows-integration ]] && source ~/.wsl-windows-integration
EOF
}

configure_windows_integration() {
  local -r username="$1"
  local -r user_home="/home/${username}"
  local -r bashrc="${user_home}/.bashrc"
  local -r zshrc="${user_home}/.zshrc"
  local -r integration_file="${user_home}/.wsl-windows-integration"

  log_step "9/10" "Configuring Windows integration"

  if [[ ${DRY_RUN} == true ]]; then
    log_info "[DRY-RUN] Would configure Windows integration"
    return 0
  fi

  # Find Windows VS Code installation path via WSL interop
  local vscode_win_path=""
  local -a possible_paths=(
    "/mnt/c/Users/${username}/AppData/Local/Programs/Microsoft VS Code/bin"
    "/mnt/c/Program Files/Microsoft VS Code/bin"
    "/mnt/c/Program Files (x86)/Microsoft VS Code/bin"
  )

  for path in "${possible_paths[@]}"; do
    if [[ -d "${path}" ]]; then
      vscode_win_path="${path}"
      log_debug "Found VS Code at: ${path}"
      break
    fi
  done

  # If not found, try to find via Windows username
  if [[ -z "${vscode_win_path}" ]]; then
    local win_user
    win_user=$(cmd.exe /c "echo %USERNAME%" 2>/dev/null | tr -d '\r\n') || true
    if [[ -n "${win_user}" ]]; then
      local win_path="/mnt/c/Users/${win_user}/AppData/Local/Programs/Microsoft VS Code/bin"
      if [[ -d "${win_path}" ]]; then
        vscode_win_path="${win_path}"
        log_debug "Found VS Code via Windows username at: ${win_path}"
      fi
    fi
  fi

  if [[ -z "${vscode_win_path}" ]]; then
    log_warn "VS Code installation not found on Windows"
    log_warn "Install VS Code on Windows, then 'code .' will work from WSL"
  fi

  # Migrate from old approach (System32 in PATH) to new approach (selective aliases)
  migrate_old_windows_integration "${bashrc}" "${zshrc}"

  # Create shared Windows integration file with VS Code PATH and selective aliases
  create_windows_integration_file "${integration_file}" "${vscode_win_path}"

  # Set proper ownership
  chown "${username}:${username}" "${integration_file}"
  chmod 644 "${integration_file}"

  # Add source statement to both shell configs
  add_integration_source "${bashrc}" "${integration_file}"
  add_integration_source "${zshrc}" "${integration_file}"

  # Pre-create VS Code Server directories for faster first connection
  log_info "Preparing VS Code Server directories..."
  sudo -u "${username}" mkdir -p "${user_home}/.vscode-server/bin"
  sudo -u "${username}" mkdir -p "${user_home}/.vscode-server/extensions"

  log_success "Windows integration configured"
}

verify_setup() {
  local -r username="$1"

  log_step "10/10" "Verifying setup"

  if [[ ${DRY_RUN} == true ]]; then
    log_info "[DRY-RUN] Verification skipped"
    return 0
  fi

  local -i issues=0

  # Check user exists
  if id "${username}" &>/dev/null; then
    log_success "User '${username}' exists"
  else
    log_error "User '${username}' not found"
    ((issues++))
  fi

  # Check sudo works (passwordless)
  if sudo -u "${username}" sudo -n true 2>/dev/null; then
    log_success "Passwordless sudo works"
  else
    log_error "Passwordless sudo not working"
    ((issues++))
  fi

  # Check wsl.conf
  if [[ -f /etc/wsl.conf ]] && grep -q "^systemd=true" /etc/wsl.conf 2>/dev/null; then
    log_success "systemd enabled in wsl.conf"
  else
    log_warn "systemd not configured in wsl.conf"
  fi

  # Check Git config
  if sudo -u "${username}" git config --global core.autocrlf &>/dev/null; then
    log_success "Git configured"
  else
    log_warn "Git not configured"
  fi

  # Check projects directory
  if [[ -d "/home/${username}/projects" ]]; then
    log_success "Projects directory exists"
  else
    log_warn "Projects directory not found"
  fi

  # Check Docker
  if [[ ${SKIP_DOCKER} != true ]]; then
    # Check user in docker group
    if id -nG "${username}" 2>/dev/null | grep -qw docker; then
      log_success "User in docker group"
    else
      log_warn "User not in docker group"
    fi

    # Check Docker daemon
    if docker info &>/dev/null; then
      log_success "Docker daemon running"

      # Quick hello-world test
      if docker run --rm hello-world &>/dev/null; then
        log_success "Docker hello-world test passed"
      else
        log_warn "Docker hello-world test failed (may need WSL restart)"
      fi
    else
      log_warn "Docker daemon not running (restart WSL: wsl --shutdown)"
    fi
  fi

  # Check GitHub CLI
  if [[ ${SKIP_GITHUB} != true ]]; then
    # shellcheck disable=SC2310  # Intentional: capture result in variable
    if has_command gh; then
      log_success "GitHub CLI installed"

      # Check authentication
      if sudo -u "${username}" gh auth status &>/dev/null; then
        log_success "GitHub CLI authenticated"
      else
        log_warn "GitHub CLI not authenticated"
      fi
    else
      log_warn "GitHub CLI not installed"
    fi

    # Check SSH key
    if [[ -f "/home/${username}/.ssh/id_ed25519_github" ]]; then
      log_success "GitHub SSH key exists"
    else
      log_warn "GitHub SSH key not found"
    fi
  fi

  # Check SSH agent
  if [[ ${SKIP_SSH_AGENT} != true && ${SKIP_GITHUB} != true ]]; then
    # shellcheck disable=SC2312  # Intentional: command substitution in variable
    local -r user_runtime_dir="/run/user/$(id -u "${username}")"
    local -r socket_path="${user_runtime_dir}/ssh-agent.socket"

    # Check service enabled
    if sudo -u "${username}" XDG_RUNTIME_DIR="${user_runtime_dir}" \
        systemctl --user is-enabled ssh-agent.service &>/dev/null; then
      log_success "SSH agent service enabled"
    else
      log_warn "SSH agent service not enabled"
    fi

    # Check socket (if systemd running)
    if pidof systemd &>/dev/null; then
      if [[ -S "${socket_path}" ]]; then
        log_success "SSH agent socket: ${socket_path}"

        # Check key loaded
        if sudo -u "${username}" SSH_AUTH_SOCK="${socket_path}" ssh-add -l &>/dev/null; then
          log_success "SSH key loaded in agent"
        else
          log_info "SSH key will load on first use (AddKeysToAgent=yes)"
        fi
      else
        log_warn "SSH agent socket not found (restart WSL)"
      fi
    fi
  fi

  # Check shell customization
  if [[ ${SKIP_SHELL} != true ]]; then
    # shellcheck disable=SC2310  # Intentional: capture result in variable
    if has_command zsh; then
      log_success "Zsh installed"
    else
      log_warn "Zsh not installed"
    fi

    if [[ -d "/home/${username}/.oh-my-zsh" ]]; then
      log_success "Oh-My-Zsh installed"
    else
      log_warn "Oh-My-Zsh not installed"
    fi

    if [[ -d "/home/${username}/.oh-my-zsh/custom/themes/powerlevel10k" ]]; then
      log_success "Powerlevel10k installed"
    else
      log_warn "Powerlevel10k not installed"
    fi

    if [[ -f "/home/${username}/.local/bin/mise" ]]; then
      log_success "mise installed"
    else
      log_warn "mise not installed"
    fi

    local current_shell
    current_shell=$(getent passwd "${username}" | cut -d: -f7)
    if [[ ${current_shell} == *zsh ]]; then
      log_success "Default shell: ${current_shell}"
    else
      log_warn "Default shell is not Zsh: ${current_shell}"
    fi
  fi

  return $((issues > 0 ? 1 : 0))
}

#-------------------------------------------------------------------------------
# Summary
#-------------------------------------------------------------------------------
print_summary() {
  printf '\n%b===============================================================%b\n' "${COLORS[bold]}" "${COLORS[reset]}" | tee -a "${LOG_FILE}"
  printf '%b                    SETUP COMPLETE%b\n' "${COLORS[bold]}" "${COLORS[reset]}" | tee -a "${LOG_FILE}"
  printf '%b===============================================================%b\n' "${COLORS[bold]}" "${COLORS[reset]}" | tee -a "${LOG_FILE}"

  [[ ${DRY_RUN} == true ]] && log_info "Mode: DRY-RUN (no changes made)"

  log_info ""
  log_info "User created:      ${TARGET_USER}"
  log_info "Home directory:    /home/${TARGET_USER}"
  log_info "Projects folder:   /home/${TARGET_USER}/projects"
  log_info "Passwordless sudo: Enabled"
  [[ ${SKIP_SHELL} != true ]] && log_info "Default shell:     Zsh (with Oh-My-Zsh + Powerlevel10k)"
  log_info "Log file:          ${LOG_FILE}"
  log_info ""

  log_warn "NEXT STEPS:"
  log_warn "  1. Restart WSL: wsl --shutdown"
  log_warn "  2. Open new terminal (user will be '${TARGET_USER}')"
  log_warn "  3. Test Docker: docker run hello-world"
  log_warn "  4. Test GitHub: gh auth status"
  log_warn "  5. Test SSH: ssh -T git@github.com"
  log_warn "  6. Clone projects to ~/projects (NOT /mnt/c)"
  [[ ${SKIP_SHELL} != true ]] && log_warn "  7. Install dev tools via mise: mise use -g python@latest"
  log_info ""

  log_info "Best practice: Store code in Linux filesystem for performance"
  log_info "  Good: ~/projects/myapp"
  log_info "  Slow: /mnt/c/Users/.../myapp"
}

#-------------------------------------------------------------------------------
# Help
#-------------------------------------------------------------------------------
show_help() {
  cat <<EOF
${COLORS[bold]}${SCRIPT_NAME}${COLORS[reset]} v${SCRIPT_VERSION} - WSL2 user and system setup for DevContainers

${COLORS[bold]}USAGE:${COLORS[reset]}
    sudo ${SCRIPT_NAME} --user USERNAME [OPTIONS]

${COLORS[bold]}REQUIRED:${COLORS[reset]}
    --user USERNAME    Username to create (POSIX-compliant)

${COLORS[bold]}OPTIONS:${COLORS[reset]}
    --dry-run          Preview without making changes
    --verbose, -v      Enable verbose output
    --skip-docker      Skip Docker installation
    --skip-github      Skip GitHub CLI installation and authentication
    --skip-shell       Skip shell customization (Zsh/Oh-My-Zsh/Powerlevel10k/mise)
    --skip-ssh-agent   Skip SSH agent configuration for devcontainers
    --help, -h         Show this help message

${COLORS[bold]}WHAT THIS SCRIPT DOES:${COLORS[reset]}
    1. Creates a non-root user with passwordless sudo
    2. Configures /etc/wsl.conf (systemd, default user)
    3. Sets up Git with proper line ending handling
    4. Creates ~/projects directory for code
    5. Installs Docker via install-docker.sh
    6. Installs GitHub CLI and configures Git authentication
    7. Configures SSH agent for devcontainer credential forwarding
    8. Installs shell customization (Zsh/Oh-My-Zsh/Powerlevel10k/mise)

${COLORS[bold]}EXAMPLES:${COLORS[reset]}
    # Standard setup
    sudo ${SCRIPT_NAME} --user john

    # Preview what would happen
    sudo ${SCRIPT_NAME} --user john --dry-run

    # Verbose output
    sudo ${SCRIPT_NAME} --user john --verbose

    # Skip Docker (configure manually later)
    sudo ${SCRIPT_NAME} --user john --skip-docker

${COLORS[bold]}REQUIREMENTS:${COLORS[reset]}
    - Bash 5.2+
    - Root privileges (sudo)
    - WSL2 environment
    - install-docker.sh in same directory (unless --skip-docker)

${COLORS[bold]}ENVIRONMENT:${COLORS[reset]}
    TRACE=1    Enable debug tracing

${COLORS[bold]}LOG:${COLORS[reset]}
    ${LOG_FILE}

EOF
}

#-------------------------------------------------------------------------------
# Argument Parsing
#-------------------------------------------------------------------------------
parse_arguments() {
  while (($#)); do
    case "${1}" in
      --user)
        [[ -n ${2:-} ]] || die "--user requires USERNAME" "${EXIT_INVALID_ARGS}"
        TARGET_USER="${2}"
        shift 2
        ;;
      --user=*)
        TARGET_USER="${1#*=}"
        shift
        ;;
      --dry-run)
        DRY_RUN=true
        shift
        ;;
      --verbose | -v)
        VERBOSE=true
        shift
        ;;
      --skip-docker)
        SKIP_DOCKER=true
        shift
        ;;
      --skip-github)
        SKIP_GITHUB=true
        shift
        ;;
      --skip-shell)
        SKIP_SHELL=true
        shift
        ;;
      --skip-ssh-agent)
        SKIP_SSH_AGENT=true
        shift
        ;;
      --help | -h)
        show_help
        exit 0
        ;;
      -*)
        die "Unknown option: ${1} (use --help)" "${EXIT_INVALID_ARGS}"
        ;;
      *)
        die "Unexpected argument: ${1} (use --help)" "${EXIT_INVALID_ARGS}"
        ;;
    esac
  done

  # Validate required arguments
  [[ -z ${TARGET_USER} ]] && die "--user USERNAME is required" "${EXIT_INVALID_ARGS}"

  # Validate username format
  validate_username "${TARGET_USER}"
}

#-------------------------------------------------------------------------------
# Main
#-------------------------------------------------------------------------------
main() {
  mkdir -p "${LOG_FILE%/*}"
  : >"${LOG_FILE}"
  chmod 644 "${LOG_FILE}"

  log_info "==============================================================="
  log_info "  WSL2 DevContainers Setup v${SCRIPT_VERSION}"
  log_info "  Bash ${BASH_VERSION} | Started: $(printf '%(%F %T)T' "${EPOCHSECONDS}")"
  log_info "==============================================================="

  [[ ${DRY_RUN} == true ]] && log_warn "DRY-RUN MODE: No changes will be made"

  setup_signal_handlers

  # Freeze configuration
  readonly TARGET_USER DRY_RUN VERBOSE SKIP_DOCKER SKIP_GITHUB SKIP_SHELL SKIP_SSH_AGENT

  acquire_lock

  # Validation
  check_root
  install_prerequisites
  validate_required_commands
  check_wsl2

  log_info "Target user: ${TARGET_USER}"

  # Setup
  create_user "${TARGET_USER}"
  configure_passwordless_sudo "${TARGET_USER}"
  configure_wsl "${TARGET_USER}"
  configure_git "${TARGET_USER}"
  install_docker "${TARGET_USER}"
  install_github_cli "${TARGET_USER}"
  configure_ssh_agent "${TARGET_USER}"
  install_shell_customization "${TARGET_USER}"
  configure_windows_integration "${TARGET_USER}"

  # Verify
  # shellcheck disable=SC2310  # Intentional: allow verification to fail gracefully
  verify_setup "${TARGET_USER}" || true

  print_summary

  log_success "Setup completed successfully!"
}

parse_arguments "$@"
main
