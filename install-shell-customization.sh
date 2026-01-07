#!/usr/bin/env bash
# SPDX-License-Identifier: NCSA
#===============================================================================
# install-shell-customization.sh - Shell customization installer/remover for WSL2
#
# DESCRIPTION:
#   Script to install or remove Zsh/Oh-My-Zsh/Powerlevel10k/mise on WSL2 systems.
#
# REQUIREMENTS:
#   Bash 5.2+
#   Ubuntu 24.04+ or Debian 12+ in WSL2
#
# USAGE:
#   sudo ./install-shell-customization.sh
#   sudo ./install-shell-customization.sh --user myuser --verbose
#   sudo ./install-shell-customization.sh --remove
#   sudo ./install-shell-customization.sh --remove --purge --force
#
# INSTALLATION OPTIONS:
#   --user USERNAME    Configure shell for specified user (default: $SUDO_USER)
#
# REMOVAL OPTIONS:
#   --remove           Remove shell customization (Oh-My-Zsh, configs)
#   --purge            Also remove mise and its data
#   --force, -f        Skip confirmation prompts
#
# GENERAL OPTIONS:
#   --dry-run          Show what would be done without making changes
#   --verbose, -v      Enable verbose output
#   --syslog           Also log to syslog (for enterprise environments)
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

# Command-level tracing (set via --trace-commands)
declare TRACE_COMMANDS=false

#-------------------------------------------------------------------------------
# Constants
#-------------------------------------------------------------------------------
declare -r SCRIPT_NAME="${0##*/}"
declare -r SCRIPT_VERSION="1.0.0"
declare -r LOG_FILE="/var/log/shell-customization-install.log"
declare -r LOCK_FILE="/var/lock/shell-customization-install.lock"

# Git repository URLs
declare -r OHMYZSH_REPO="https://github.com/ohmyzsh/ohmyzsh.git"
declare -r P10K_REPO="https://github.com/romkatv/powerlevel10k.git"
declare -r ZSH_AUTOSUGGESTIONS_REPO="https://github.com/zsh-users/zsh-autosuggestions.git"
declare -r ZSH_SYNTAX_HIGHLIGHTING_REPO="https://github.com/zsh-users/zsh-syntax-highlighting.git"
declare -r MISE_INSTALL_URL="https://mise.run"

# Network retry configuration
declare -ri MAX_RETRIES=5
declare -ri RETRY_DELAY_BASE=2

# Lock timeout (seconds) - prevents deadlocks from stuck processes
declare -ri LOCK_TIMEOUT=300

# Structured exit codes for better error handling
# shellcheck disable=SC2034  # EXIT_SUCCESS defined for completeness/documentation
declare -ri EXIT_SUCCESS=0
declare -ri EXIT_GENERAL_ERROR=1
declare -ri EXIT_LOCK_FAILED=2
declare -ri EXIT_INVALID_ARGS=3
declare -ri EXIT_ROOT_REQUIRED=4
declare -ri EXIT_NOT_WSL2=5
declare -ri EXIT_NETWORK_ERROR=6
declare -ri EXIT_INSTALL_FAILED=7
# shellcheck disable=SC2034  # EXIT_USER_CANCELLED defined for completeness/documentation
declare -ri EXIT_USER_CANCELLED=8

# Required commands for script execution
declare -ra REQUIRED_COMMANDS=(
  curl apt-get dpkg-query getent id stat mkdir rm mv cp chmod chown
  git grep sed tee sleep flock pgrep uname chsh
)

# APT packages to install (reference list)
# shellcheck disable=SC2034  # SHELL_PACKAGES defined for documentation
declare -ra SHELL_PACKAGES=(
  zsh
  fzf
  git
)

# Oh-My-Zsh plugins (built-in)
declare -ra OMZ_BUILTIN_PLUGINS=(
  git
  docker
  docker-compose
  z
  sudo
  history
  colored-man-pages
  copypath
  copyfile
  fzf
)

# External plugins to clone
declare -rA OMZ_EXTERNAL_PLUGINS=(
  ["zsh-autosuggestions"]="${ZSH_AUTOSUGGESTIONS_REPO}"
  ["zsh-syntax-highlighting"]="${ZSH_SYNTAX_HIGHLIGHTING_REPO}"
)

#-------------------------------------------------------------------------------
# Global State Variables
#-------------------------------------------------------------------------------
declare TARGET_USER="${SUDO_USER:-}"
declare DRY_RUN=false
declare VERBOSE=false
declare SYSLOG=false

# Removal mode state
declare REMOVE_MODE=false
declare PURGE_DATA=false
declare FORCE_REMOVE=false

# Cleanup state tracking (for rollback)
declare -i CLEANUP_IN_PROGRESS=0
declare -i SIGNAL_RECEIVED=0
declare RECEIVED_SIGNAL=""
declare -a CLEANUP_ACTIONS=()
declare -A CREATED_FILES=()
declare -A CREATED_DIRS=()
declare -A MODIFIED_FILES=()

# User paths (set after validation)
declare USER_HOME=""
declare OMZ_DIR=""
declare OMZ_CUSTOM=""
declare P10K_DIR=""
declare ZSHRC_FILE=""
declare P10K_CONFIG=""
declare MISE_BIN=""
declare MISE_DATA=""

#-------------------------------------------------------------------------------
# Terminal Colors
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
# Logging Functions
#-------------------------------------------------------------------------------
_log() {
  local -r level="$1" color="$2" msg="$3"
  local timestamp
  printf -v timestamp '%(%Y-%m-%d %H:%M:%S)T' "${EPOCHSECONDS}"
  printf '%b[%s]%b %s - %s\n' "${COLORS[${color}]}" "${level}" "${COLORS[reset]}" "${timestamp}" "${msg}" | tee -a "${LOG_FILE}"
  _syslog "${level}" "${msg}"
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

# Send to syslog if enabled
_syslog() {
  local -r level="$1" msg="$2"
  local has_logger=false
  # shellcheck disable=SC2310  # Intentional: capture result in variable
  has_command logger && has_logger=true
  if [[ ${SYSLOG} == true && ${has_logger} == true ]]; then
    logger -t "${SCRIPT_NAME}" -p "user.${level,,}" "${msg}" 2>/dev/null || true
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

# Returns: 0 if confirmed, 1 if declined
confirm_action() {
  local -r prompt="${1}"

  # Force mode bypasses confirmation
  [[ ${FORCE_REMOVE} == true ]] && return 0

  # Dry-run mode assumes yes for preview
  if [[ ${DRY_RUN} == true ]]; then
    log_info "[DRY-RUN] Would prompt: ${prompt}"
    return 0
  fi

  # Non-interactive mode: use safe default (decline)
  if [[ ! -t 0 ]]; then
    log_warn "Non-interactive mode - use --force to proceed"
    return 1
  fi

  # Interactive prompt
  printf '%b%s [y/N]: %b' "${COLORS[yellow]}" "${prompt}" "${COLORS[reset]}"
  local response
  read -r response

  [[ ${response,,} =~ ^(y|yes)$ ]]
}

# Retry
retry_with_backoff() {
  local -ri max_attempts="$1"
  local -i delay="$2"
  shift 2
  local -a cmd=("$@")
  local -i attempt=1
  local output
  local -i exit_code

  while ((attempt <= max_attempts)); do
    if output=$("${cmd[@]}" 2>&1); then
      return 0
    fi
    exit_code=$?

    if ((attempt == max_attempts)); then
      log_error "Command failed after ${max_attempts} attempts: ${cmd[*]@Q}"
      log_error "Last output: ${output}"
      return 1
    fi

    # Check for rate limiting or server errors
    if [[ ${output} =~ (429|503|"Too Many Requests"|"Service Unavailable") ]]; then
      log_warn "Server rate-limited or unavailable (attempt ${attempt}/${max_attempts})"
      ((delay *= 3))
    else
      log_warn "Attempt ${attempt}/${max_attempts} failed (exit code: ${exit_code}). Retrying in ${delay}s..."
      ((delay *= 2))
    fi

    # Cap maximum delay
    ((delay > 60)) && delay=60

    sleep "${delay}"
    ((attempt++))
  done
}

# Check if command exists
has_command() {
  command -v "$1" &>/dev/null
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

# Execute or simulate based on dry-run mode
execute() {
  if [[ ${DRY_RUN} == true ]]; then
    log_info "[DRY-RUN] Would execute: ${*@Q}"
    return 0
  fi
  log_debug "Executing: ${*@Q}"
  "$@"
}

# APT install
apt_install() {
  export DEBIAN_FRONTEND=noninteractive
  export DEBIAN_PRIORITY=critical
  export NEEDRESTART_MODE=a # Auto-restart services without prompting

  apt-get install -y -qq \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" \
    -o Acquire::Retries=3 \
    "$@"
}

# Check if package is installed
is_installed() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "^install ok installed$"
}

# Validate username format
validate_username() {
  local -r user="$1"
  if [[ ! ${user} =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
    die "Invalid username format: '${user}'. Must be POSIX-compliant (lowercase, start with letter/underscore, max 32 chars)" "${EXIT_INVALID_ARGS:-1}"
  fi
}

# Validate required commands are available (fail-fast)
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
    die "Install missing commands and try again" "${EXIT_GENERAL_ERROR:-1}"
  fi

  log_success "All required commands available"
}

#-------------------------------------------------------------------------------
# Lock Management
#-------------------------------------------------------------------------------
acquire_lock() {
  log_debug "Acquiring lock: ${LOCK_FILE}"

  mkdir -p "${LOCK_FILE%/*}"

  # Open lock file
  exec {LOCK_FD}>"${LOCK_FILE}"

  if ! flock -w "${LOCK_TIMEOUT}" "${LOCK_FD}"; then
    die "Could not acquire lock within ${LOCK_TIMEOUT}s. Another instance may be stuck." "${EXIT_LOCK_FAILED:-2}"
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

register_created_dir() {
  local -r dir="$1"
  CREATED_DIRS["${dir}"]=1
  log_debug "Registered created directory: ${dir}"
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
# Signal Definitions & Exit Codes
#-------------------------------------------------------------------------------
declare -rA SIGNAL_INFO=(
  # Graceful termination signals
  [HUP]="1:Hangup:graceful"
  [INT]="2:Interrupt:graceful"
  [QUIT]="3:Quit:graceful"
  [TERM]="15:Terminated:graceful"

  # Program error signals
  [ILL]="4:Illegal instruction:fatal"
  [TRAP]="5:Trace/breakpoint trap:fatal"
  [ABRT]="6:Aborted:fatal"
  [BUS]="7:Bus error:fatal"
  [FPE]="8:Floating point exception:fatal"
  [SEGV]="11:Segmentation fault:fatal"
  [STKFLT]="16:Stack fault:fatal"
  [SYS]="31:Bad system call:fatal"
  [IOT]="6:IOT trap:fatal"
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

  # Log based on signal type
  case "${sig_type}" in
    graceful)
      log_warn "Received SIG${sig_name} (${sig_desc}) - initiating graceful shutdown..."
      ;;
    fatal)
      log_error "FATAL: Received SIG${sig_name} (${sig_desc}) - attempting emergency cleanup..."
      log_error "This indicates a serious error. Please report if reproducible."
      ;;
    *)
      log_warn "Unknown signal type: ${sig_type}"
      ;;
  esac

  # Perform cleanup (will be handled by EXIT trap)
  exit "${exit_code}"
}

#-------------------------------------------------------------------------------
# Error Handler
#-------------------------------------------------------------------------------
error_handler() {
  local -ri exit_code=$?
  local -r failed_cmd="${BASH_COMMAND}"
  local -r line="${BASH_LINENO[0]}"
  local -r func="${FUNCNAME[1]:-main}"
  local -r src="${BASH_SOURCE[1]:-${SCRIPT_NAME}}"

  # Don't trigger for intentional failures
  ((exit_code == 0)) && return 0

  log_error "Command failed with exit code ${exit_code}"
  log_error "  Location: ${func}() at ${src}:${line}"
  log_error "  Command:  ${failed_cmd}"

  # Print stack trace and state in verbose mode
  if [[ ${VERBOSE} == true ]]; then
    log_debug "Stack trace:"
    local -i i
    for ((i = 1; i < ${#FUNCNAME[@]}; i++)); do
      log_debug "  [${i}] ${FUNCNAME[i]}() at ${BASH_SOURCE[i]:-unknown}:${BASH_LINENO[i - 1]}"
    done

    # Show key variable state for debugging
    log_debug "Variable state:"
    log_debug "  DRY_RUN=${DRY_RUN:-unset}"
    log_debug "  TARGET_USER=${TARGET_USER:-unset}"
    log_debug "  USER_HOME=${USER_HOME:-unset}"
  fi
}

#-------------------------------------------------------------------------------
# Cleanup Handler (runs on EXIT - catches all termination scenarios)
# Performs cleanup in LIFO order, handles rollback of partial changes
#-------------------------------------------------------------------------------
# Kill any child processes in our process group
cleanup_processes() {
  # Get list of child processes
  local -a child_pids
  mapfile -t child_pids < <(pgrep -P $$ 2>/dev/null || true)

  if ((${#child_pids[@]} > 0)); then
    log_debug "Terminating ${#child_pids[@]} child process(es)"
    for pid in "${child_pids[@]}"; do
      kill -TERM "${pid}" 2>/dev/null || true
    done
    # Brief wait for graceful termination
    sleep 0.5
    # Force kill any remaining
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

  # Disable all signal traps during cleanup to prevent interruption
  trap '' INT TERM HUP QUIT

  log_debug "Cleanup triggered (exit_code=${exit_code}, signal=${RECEIVED_SIGNAL:-none})"

  # Terminate any child processes first
  cleanup_processes

  # If we received a fatal signal, adjust messaging
  if [[ -n ${RECEIVED_SIGNAL} ]]; then
    log_info "Cleaning up after SIG${RECEIVED_SIGNAL}..."
  fi

  # Execute registered cleanup actions in reverse order (LIFO)
  local -i i
  for ((i = ${#CLEANUP_ACTIONS[@]} - 1; i >= 0; i--)); do
    local -r action="${CLEANUP_ACTIONS[i]}"
    log_debug "Executing cleanup action: ${action}"
    if declare -F "${action}" &>/dev/null; then
      "${action}" 2>/dev/null || true
    else
      log_warn "Unknown cleanup action skipped: ${action}"
    fi
  done

  # Rollback: Remove files we created (if exit was not successful)
  if ((exit_code != 0)); then
    log_info "Rolling back changes..."

    # Remove created directories
    for dir in "${!CREATED_DIRS[@]}"; do
      if [[ -d ${dir} ]]; then
        log_debug "Removing created directory: ${dir}"
        rm -rf "${dir}" 2>/dev/null || true
      fi
    done

    # Remove created files
    for file in "${!CREATED_FILES[@]}"; do
      if [[ -f ${file} ]]; then
        log_debug "Removing created file: ${file}"
        rm -f "${file}" 2>/dev/null || true
      fi
    done

    # Restore modified files from backups
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

  # Final status
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
  # EXIT trap - always runs, handles all cleanup
  trap cleanup EXIT

  # ERR trap - provides error context
  trap error_handler ERR

  # Graceful termination signals
  trap 'signal_handler HUP' HUP   # 1  - Hangup
  trap 'signal_handler INT' INT   # 2  - Interrupt (Ctrl+C)
  trap 'signal_handler QUIT' QUIT # 3  - Quit (Ctrl+\)
  trap 'signal_handler TERM' TERM # 15 - Termination request

  # Program error signals (fatal - attempt cleanup)
  trap 'signal_handler ILL' ILL                           # 4  - Illegal instruction
  trap 'signal_handler TRAP' TRAP                         # 5  - Trace/breakpoint trap
  trap 'signal_handler ABRT' ABRT                         # 6  - Abort
  trap 'signal_handler BUS' BUS                           # 7  - Bus error
  trap 'signal_handler FPE' FPE                           # 8  - Floating point exception
  trap 'signal_handler SEGV' SEGV                         # 11 - Segmentation fault
  trap 'signal_handler SYS' SYS                           # 31 - Bad system call
  trap 'signal_handler STKFLT' STKFLT 2>/dev/null || true # 16 - Stack fault
  # These are not widely available. Attempt to trap but ignore failure
  trap 'signal_handler EMT' EMT 2>/dev/null || true
  trap 'signal_handler IOT' IOT 2>/dev/null || true

  log_debug "Signal handlers installed"
}

#-------------------------------------------------------------------------------
# Debug Tracing (--trace-commands)
#-------------------------------------------------------------------------------
setup_debug_tracing() {
  if [[ ${TRACE_COMMANDS} == true ]]; then
    trap '_trace_command "${BASH_COMMAND}" "${LINENO}" "${FUNCNAME[0]:-main}"' DEBUG
    log_debug "Command tracing enabled"
  fi
}

_trace_command() {
  local -r cmd="$1" line="$2" func="$3"
  # Skip internal tracing functions to avoid recursion
  [[ ${cmd} == _trace_command* || ${cmd} == log_* ]] && return
  log_debug "[${func}:${line}] ${cmd}"
}

#-------------------------------------------------------------------------------
# Validation Functions
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

validate_user() {
  log_info "Validating target user..."

  [[ -z ${TARGET_USER} ]] && TARGET_USER="${SUDO_USER:-${USER:-}}"

  if [[ -z ${TARGET_USER} || ${TARGET_USER} == root ]]; then
    die "No non-root user specified. Use --user USERNAME" "${EXIT_INVALID_ARGS}"
  fi

  id "${TARGET_USER}" &>/dev/null || die "User '${TARGET_USER}' does not exist" "${EXIT_INVALID_ARGS}"

  # Set user paths
  USER_HOME=$(getent passwd "${TARGET_USER}" | cut -d: -f6)
  OMZ_DIR="${USER_HOME}/.oh-my-zsh"
  OMZ_CUSTOM="${OMZ_DIR}/custom"
  P10K_DIR="${OMZ_CUSTOM}/themes/powerlevel10k"
  ZSHRC_FILE="${USER_HOME}/.zshrc"
  P10K_CONFIG="${USER_HOME}/.p10k.zsh"
  MISE_BIN="${USER_HOME}/.local/bin/mise"
  MISE_DATA="${USER_HOME}/.local/share/mise"

  log_success "Target user: ${TARGET_USER} (home: ${USER_HOME})"
}

#-------------------------------------------------------------------------------
# Network Connectivity Check
#-------------------------------------------------------------------------------
check_network() {
  log_info "Checking network connectivity..."

  local -ra test_endpoints=(
    "https://github.com"
    "https://1.1.1.1" # Cloudflare DNS fallback
  )

  local endpoint
  for endpoint in "${test_endpoints[@]}"; do
    if curl -fsSL \
      --proto '=https' \
      --tlsv1.2 \
      --connect-timeout 5 \
      --max-time 10 \
      -o /dev/null \
      "${endpoint}" 2>/dev/null; then
      log_success "Network connectivity confirmed"
      return 0
    fi
  done

  die "No network connectivity. Please check your internet connection." "${EXIT_NETWORK_ERROR:-1}"
}

#-------------------------------------------------------------------------------
# Installation Functions
#-------------------------------------------------------------------------------
install_zsh() {
  log_step "1/7" "Installing Zsh"

  # Check if already installed
  # shellcheck disable=SC2310  # Intentional: idempotency check in conditional
  if has_command zsh && is_installed zsh; then
    local zsh_ver
    zsh_ver="$(zsh --version 2>/dev/null)" || zsh_ver="unknown"
    log_success "Zsh already installed: ${zsh_ver}"
    return 0
  fi

  log_info "Installing zsh package..."
  execute apt_install zsh

  # Verify installation
  if [[ ${DRY_RUN} != true ]]; then
    # shellcheck disable=SC2310  # Intentional: die terminates on failure
    has_command zsh || die "Zsh installation failed" "${EXIT_INSTALL_FAILED}"
    local zsh_ver
    zsh_ver="$(zsh --version 2>/dev/null)" || zsh_ver="unknown"
    log_success "Zsh installed: ${zsh_ver}"
  else
    log_success "[DRY-RUN] Zsh would be installed"
  fi
}

install_fzf() {
  log_step "2/7" "Installing fzf"

  # Check if already installed
  # shellcheck disable=SC2310  # Intentional: idempotency check in conditional
  if has_command fzf && is_installed fzf; then
    local fzf_ver
    fzf_ver="$(fzf --version 2>/dev/null | head -1)" || fzf_ver="unknown"
    log_success "fzf already installed: ${fzf_ver}"
    return 0
  fi

  log_info "Installing fzf package..."
  execute apt_install fzf

  # Verify installation
  if [[ ${DRY_RUN} != true ]]; then
    # shellcheck disable=SC2310  # Intentional: die terminates on failure
    has_command fzf || die "fzf installation failed" "${EXIT_INSTALL_FAILED}"
    local fzf_ver
    fzf_ver="$(fzf --version 2>/dev/null | head -1)" || fzf_ver="unknown"
    log_success "fzf installed: ${fzf_ver}"
  else
    log_success "[DRY-RUN] fzf would be installed"
  fi
}

install_ohmyzsh() {
  log_step "3/7" "Installing Oh-My-Zsh"

  # Check if already installed
  if [[ -d ${OMZ_DIR} ]]; then
    log_success "Oh-My-Zsh already installed at ${OMZ_DIR}"
    return 0
  fi

  log_info "Cloning Oh-My-Zsh..."

  if [[ ${DRY_RUN} == true ]]; then
    log_info "[DRY-RUN] Would clone Oh-My-Zsh to ${OMZ_DIR}"
    return 0
  fi

  # Clone Oh-My-Zsh
  retry_with_backoff "${MAX_RETRIES}" "${RETRY_DELAY_BASE}" \
    sudo -u "${TARGET_USER}" git clone --depth=1 "${OHMYZSH_REPO}" "${OMZ_DIR}"

  register_created_dir "${OMZ_DIR}"

  # Create custom directories
  sudo -u "${TARGET_USER}" mkdir -p "${OMZ_CUSTOM}/plugins"
  sudo -u "${TARGET_USER}" mkdir -p "${OMZ_CUSTOM}/themes"

  log_success "Oh-My-Zsh installed"
}

install_powerlevel10k() {
  log_step "4/7" "Installing Powerlevel10k theme"

  # Check if already installed
  if [[ -d ${P10K_DIR} ]]; then
    log_success "Powerlevel10k already installed at ${P10K_DIR}"
    return 0
  fi

  log_info "Cloning Powerlevel10k..."

  if [[ ${DRY_RUN} == true ]]; then
    log_info "[DRY-RUN] Would clone Powerlevel10k to ${P10K_DIR}"
    return 0
  fi

  # Ensure parent directory exists
  sudo -u "${TARGET_USER}" mkdir -p "${OMZ_CUSTOM}/themes"

  # Clone Powerlevel10k
  retry_with_backoff "${MAX_RETRIES}" "${RETRY_DELAY_BASE}" \
    sudo -u "${TARGET_USER}" git clone --depth=1 "${P10K_REPO}" "${P10K_DIR}"

  register_created_dir "${P10K_DIR}"
  log_success "Powerlevel10k installed"
}

install_external_plugins() {
  log_step "5/7" "Installing external Oh-My-Zsh plugins"

  local plugin_name plugin_repo plugin_dir

  for plugin_name in "${!OMZ_EXTERNAL_PLUGINS[@]}"; do
    plugin_repo="${OMZ_EXTERNAL_PLUGINS[${plugin_name}]}"
    plugin_dir="${OMZ_CUSTOM}/plugins/${plugin_name}"

    # Check if already installed
    if [[ -d ${plugin_dir} ]]; then
      log_success "${plugin_name} already installed"
      continue
    fi

    log_info "Cloning ${plugin_name}..."

    if [[ ${DRY_RUN} == true ]]; then
      log_info "[DRY-RUN] Would clone ${plugin_name} to ${plugin_dir}"
      continue
    fi

    # Ensure parent directory exists
    sudo -u "${TARGET_USER}" mkdir -p "${OMZ_CUSTOM}/plugins"

    # Clone plugin
    retry_with_backoff "${MAX_RETRIES}" "${RETRY_DELAY_BASE}" \
      sudo -u "${TARGET_USER}" git clone --depth=1 "${plugin_repo}" "${plugin_dir}"

    register_created_dir "${plugin_dir}"
    log_success "${plugin_name} installed"
  done
}

install_mise() {
  log_step "6/7" "Installing mise (version manager)"

  # Check if already installed
  if [[ -f ${MISE_BIN} ]]; then
    local mise_ver
    mise_ver=$(sudo -u "${TARGET_USER}" "${MISE_BIN}" --version 2>/dev/null) || mise_ver="unknown"
    log_success "mise already installed: ${mise_ver}"
    return 0
  fi

  log_info "Installing mise..."

  if [[ ${DRY_RUN} == true ]]; then
    log_info "[DRY-RUN] Would install mise to ${MISE_BIN}"
    return 0
  fi

  # Create directories
  sudo -u "${TARGET_USER}" mkdir -p "${USER_HOME}/.local/bin"
  sudo -u "${TARGET_USER}" mkdir -p "${USER_HOME}/.local/share/mise"

  # Download mise installer script
  local mise_script
  if ! mise_script=$(curl -fsSL "${MISE_INSTALL_URL}" 2>/dev/null); then
    log_warn "Failed to download mise installer"
    log_warn "Users can install later: curl https://mise.run | sh"
    return 0
  fi

  if [[ -z ${mise_script} ]]; then
    log_warn "mise installer script is empty"
    log_warn "Users can install later: curl https://mise.run | sh"
    return 0
  fi

  # Install mise (the installer respects MISE_INSTALL_PATH)
  MISE_INSTALL_PATH="${MISE_BIN}" sudo -u "${TARGET_USER}" bash -c "${mise_script}"

  # Verify installation
  if [[ ! -f ${MISE_BIN} ]]; then
    log_warn "mise installation may have failed - binary not found at ${MISE_BIN}"
    log_warn "Users can install later: curl https://mise.run | sh"
    return 0
  fi

  register_created_file "${MISE_BIN}"
  local mise_ver
  mise_ver="$(sudo -u "${TARGET_USER}" "${MISE_BIN}" --version 2>/dev/null)" || mise_ver="unknown"
  log_success "mise installed: ${mise_ver}"
  log_info "Note: mise does NOT install any default tools - projects define tools via mise.toml"
}

configure_shell() {
  log_step "7/7" "Configuring shell environment"

  # === Set Zsh as default shell ===
  log_info "Setting Zsh as default shell for ${TARGET_USER}..."

  local current_shell
  current_shell=$(getent passwd "${TARGET_USER}" | cut -d: -f7)

  if [[ ${current_shell} == *zsh ]]; then
    log_success "Zsh already set as default shell"
  else
    if [[ ${DRY_RUN} == true ]]; then
      log_info "[DRY-RUN] Would change shell from ${current_shell} to zsh"
    else
      local zsh_path
      zsh_path="$(command -v zsh 2>/dev/null)" || zsh_path=""
      if [[ -z ${zsh_path} || ! -x ${zsh_path} ]]; then
        die "Cannot find zsh executable" "${EXIT_INSTALL_FAILED}"
      fi
      execute chsh -s "${zsh_path}" "${TARGET_USER}"
      log_success "Default shell changed to zsh"
    fi
  fi

  # === Create .zshrc ===
  log_info "Creating .zshrc..."

  if [[ ${DRY_RUN} == true ]]; then
    log_info "[DRY-RUN] Would create ${ZSHRC_FILE}"
  else
    # Backup existing .zshrc if present
    [[ -f ${ZSHRC_FILE} ]] && backup_file "${ZSHRC_FILE}"

    # Build plugins list
    local plugins_list=""
    for plugin in "${OMZ_BUILTIN_PLUGINS[@]}"; do
      plugins_list+="  ${plugin}\n"
    done
    for plugin in "${!OMZ_EXTERNAL_PLUGINS[@]}"; do
      plugins_list+="  ${plugin}\n"
    done

    # Write .zshrc
    cat >"${ZSHRC_FILE}" <<'ZSHRC_EOF'
# Enable Powerlevel10k instant prompt (should stay at top of .zshrc)
if [[ -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
  source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"
fi

#=============================================================================
# Oh-My-Zsh Configuration
#=============================================================================
export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME="powerlevel10k/powerlevel10k"

# Uncomment to change auto-update behavior
# zstyle ':omz:update' mode disabled  # disable automatic updates
# zstyle ':omz:update' mode auto      # update automatically without asking
# zstyle ':omz:update' mode reminder  # just remind me to update when it's time

# Uncomment if pasting URLs and other text is messed up
# DISABLE_MAGIC_FUNCTIONS="true"

# Uncomment to disable auto-setting terminal title
# DISABLE_AUTO_TITLE="true"

# Uncomment to enable command auto-correction
# ENABLE_CORRECTION="true"

# Display red dots whilst waiting for completion
COMPLETION_WAITING_DOTS="true"

# Disable marking untracked files under VCS as dirty (for large repos)
DISABLE_UNTRACKED_FILES_DIRTY="true"

#=============================================================================
# Plugins
# Standard plugins: $ZSH/plugins/
# Custom plugins: $ZSH_CUSTOM/plugins/
# NOTE: zsh-syntax-highlighting MUST be last
#=============================================================================
plugins=(
  # Built-in plugins
  git
  docker
  docker-compose
  z
  sudo
  history
  colored-man-pages
  copypath
  copyfile
  fzf
  # External plugins (in ~/.oh-my-zsh/custom/plugins/)
  zsh-autosuggestions
  zsh-syntax-highlighting
)

source $ZSH/oh-my-zsh.sh

#=============================================================================
# zsh-autosuggestions configuration
# Ref: https://github.com/zsh-users/zsh-autosuggestions
#=============================================================================
ZSH_AUTOSUGGEST_STRATEGY=(history completion)
ZSH_AUTOSUGGEST_BUFFER_MAX_SIZE=20
ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE="fg=#666666"
ZSH_AUTOSUGGEST_USE_ASYNC=1

#=============================================================================
# zsh-syntax-highlighting configuration
# Ref: https://github.com/zsh-users/zsh-syntax-highlighting
#=============================================================================
ZSH_HIGHLIGHT_HIGHLIGHTERS=(main brackets)
ZSH_HIGHLIGHT_MAXLENGTH=512

#=============================================================================
# fzf configuration
# Key bindings: Ctrl+R (history), Ctrl+T (files), Alt+C (cd)
#=============================================================================
export FZF_DEFAULT_OPTS="--height 40% --layout=reverse --border --info=inline"
if command -v fd &>/dev/null; then
  export FZF_DEFAULT_COMMAND="fd --type f --hidden --follow --exclude .git"
  export FZF_CTRL_T_COMMAND="$FZF_DEFAULT_COMMAND"
  export FZF_ALT_C_COMMAND="fd --type d --hidden --follow --exclude .git"
fi

#=============================================================================
# z (directory jumping) configuration
#=============================================================================
export ZSHZ_DATA="${HOME}/.z"

#=============================================================================
# mise activation (version manager)
#=============================================================================
if [[ -f "$HOME/.local/bin/mise" ]]; then
  eval "$($HOME/.local/bin/mise activate zsh)"
fi

#=============================================================================
# User configuration
#=============================================================================
export EDITOR='vim'
export VISUAL='vim'

# Preferred editor for local and remote sessions
if [[ -n $SSH_CONNECTION ]]; then
  export EDITOR='vim'
else
  # Use VS Code if available
  if command -v code &>/dev/null; then
    export EDITOR='code --wait'
    export VISUAL='code --wait'
  fi
fi

# History configuration
HISTSIZE=500000
SAVEHIST=500000
setopt HIST_IGNORE_ALL_DUPS
setopt HIST_SAVE_NO_DUPS
setopt SHARE_HISTORY
setopt AUTO_CD
setopt AUTO_PUSHD

#=============================================================================
# Load Powerlevel10k configuration
#=============================================================================
[[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh
ZSHRC_EOF

    chown "${TARGET_USER}:${TARGET_USER}" "${ZSHRC_FILE}"
    chmod 644 "${ZSHRC_FILE}"
    register_created_file "${ZSHRC_FILE}"
    log_success ".zshrc created"
  fi

  # === Copy p10k.zsh configuration ===
  log_info "Installing Powerlevel10k configuration..."

  if [[ ${DRY_RUN} == true ]]; then
    log_info "[DRY-RUN] Would copy p10k.zsh to ${P10K_CONFIG}"
  else
    # Copy bundled p10k.zsh from script directory
    # shellcheck disable=SC2312  # Intentional: file check below handles failure gracefully
    local -r script_dir="$(dirname "$(readlink -f "$0")")"
    local -r bundled_p10k="${script_dir}/p10k.zsh"

    if [[ -f ${bundled_p10k} ]]; then
      cp "${bundled_p10k}" "${P10K_CONFIG}"
      chown "${TARGET_USER}:${TARGET_USER}" "${P10K_CONFIG}"
      chmod 644 "${P10K_CONFIG}"
      register_created_file "${P10K_CONFIG}"
      log_success "Powerlevel10k configuration installed"
    else
      log_warn "Bundled p10k.zsh not found at ${bundled_p10k}"
      log_warn "User will need to run 'p10k configure' on first login"
    fi
  fi

  log_success "Shell environment configured"
}

#-------------------------------------------------------------------------------
# Removal Functions
#-------------------------------------------------------------------------------

# Check what shell customization components are installed
check_shell_installation() {
  log_info "Checking current shell customization installation..."

  local -i found=0

  # Check Oh-My-Zsh
  if [[ -d ${OMZ_DIR} ]]; then
    log_info "  Oh-My-Zsh: ${OMZ_DIR}"
    ((found++))
  fi

  # Check Powerlevel10k
  if [[ -d ${P10K_DIR} ]]; then
    log_info "  Powerlevel10k: ${P10K_DIR}"
    ((found++))
  fi

  # Check .zshrc
  if [[ -f ${ZSHRC_FILE} ]]; then
    log_info "  .zshrc: ${ZSHRC_FILE}"
    ((found++))
  fi

  # Check p10k config
  if [[ -f ${P10K_CONFIG} ]]; then
    log_info "  p10k config: ${P10K_CONFIG}"
    ((found++))
  fi

  # Check mise
  if [[ -f ${MISE_BIN} ]]; then
    log_info "  mise: ${MISE_BIN}"
    ((found++))
  fi

  # Check external plugins
  for plugin_name in "${!OMZ_EXTERNAL_PLUGINS[@]}"; do
    local plugin_dir="${OMZ_CUSTOM}/plugins/${plugin_name}"
    if [[ -d ${plugin_dir} ]]; then
      log_info "  Plugin ${plugin_name}: ${plugin_dir}"
      ((found++))
    fi
  done

  # Check default shell
  local current_shell
  current_shell=$(getent passwd "${TARGET_USER}" | cut -d: -f7)
  if [[ ${current_shell} == *zsh ]]; then
    log_info "  Default shell: ${current_shell}"
    ((found++))
  fi

  if ((found == 0)); then
    log_warn "No shell customization installation detected"
    return 1
  fi

  log_success "Found ${found} shell customization component(s)"
  return 0
}

# Remove shell customization
remove_shell_customization() {
  log_step "1/4" "Restoring default shell"

  local current_shell
  current_shell=$(getent passwd "${TARGET_USER}" | cut -d: -f7)

  if [[ ${current_shell} == *zsh ]]; then
    log_info "Changing default shell back to bash..."
    if [[ ${DRY_RUN} == true ]]; then
      log_info "[DRY-RUN] Would change shell to /bin/bash"
    else
      execute chsh -s /bin/bash "${TARGET_USER}"
      log_success "Default shell changed to bash"
    fi
  else
    log_info "Default shell is already ${current_shell}"
  fi

  log_step "2/4" "Removing Oh-My-Zsh and plugins"

  if [[ -d ${OMZ_DIR} ]]; then
    log_info "Removing Oh-My-Zsh directory..."
    if [[ ${DRY_RUN} == true ]]; then
      log_info "[DRY-RUN] Would remove ${OMZ_DIR}"
    else
      execute rm -rf "${OMZ_DIR}"
      log_success "Oh-My-Zsh removed"
    fi
  else
    log_info "Oh-My-Zsh not installed"
  fi

  log_step "3/4" "Removing configuration files"

  # Remove .zshrc
  if [[ -f ${ZSHRC_FILE} ]]; then
    log_info "Removing .zshrc..."
    if [[ ${DRY_RUN} == true ]]; then
      log_info "[DRY-RUN] Would remove ${ZSHRC_FILE}"
    else
      execute rm -f "${ZSHRC_FILE}"
      log_success ".zshrc removed"
    fi
  fi

  # Remove p10k config
  if [[ -f ${P10K_CONFIG} ]]; then
    log_info "Removing p10k configuration..."
    if [[ ${DRY_RUN} == true ]]; then
      log_info "[DRY-RUN] Would remove ${P10K_CONFIG}"
    else
      execute rm -f "${P10K_CONFIG}"
      log_success "p10k configuration removed"
    fi
  fi

  # Remove z database
  local -r z_data="${USER_HOME}/.z"
  if [[ -f ${z_data} ]]; then
    log_info "Removing z directory database..."
    if [[ ${DRY_RUN} == true ]]; then
      log_info "[DRY-RUN] Would remove ${z_data}"
    else
      execute rm -f "${z_data}"
    fi
  fi

  log_step "4/4" "Handling mise"

  if [[ ${PURGE_DATA} == true ]]; then
    if [[ -f ${MISE_BIN} ]]; then
      log_info "Removing mise binary..."
      if [[ ${DRY_RUN} == true ]]; then
        log_info "[DRY-RUN] Would remove ${MISE_BIN}"
      else
        execute rm -f "${MISE_BIN}"
        log_success "mise binary removed"
      fi
    fi

    if [[ -d ${MISE_DATA} ]]; then
      log_info "Removing mise data..."
      if [[ ${DRY_RUN} == true ]]; then
        log_info "[DRY-RUN] Would remove ${MISE_DATA}"
      else
        execute rm -rf "${MISE_DATA}"
        log_success "mise data removed"
      fi
    fi
  else
    if [[ -f ${MISE_BIN} || -d ${MISE_DATA} ]]; then
      log_info "Preserving mise (use --purge to remove)"
    fi
  fi

  log_success "Shell customization removed"
}

# Verify removal was successful
verify_removal() {
  printf '\n%b===============================================================%b\n' "${COLORS[bold]}" "${COLORS[reset]}" | tee -a "${LOG_FILE}"
  printf '%b                    REMOVAL VERIFICATION%b\n' "${COLORS[bold]}" "${COLORS[reset]}" | tee -a "${LOG_FILE}"
  printf '%b===============================================================%b\n' "${COLORS[bold]}" "${COLORS[reset]}" | tee -a "${LOG_FILE}"

  if [[ ${DRY_RUN} == true ]]; then
    log_info "[DRY-RUN] Verification skipped"
    return 0
  fi

  local -i issues=0

  # Check Oh-My-Zsh removed
  if [[ -d ${OMZ_DIR} ]]; then
    log_error "Oh-My-Zsh still present: ${OMZ_DIR}"
    ((issues++))
  else
    log_success "Oh-My-Zsh removed"
  fi

  # Check .zshrc removed
  if [[ -f ${ZSHRC_FILE} ]]; then
    log_error ".zshrc still present: ${ZSHRC_FILE}"
    ((issues++))
  else
    log_success ".zshrc removed"
  fi

  # Check p10k config removed
  if [[ -f ${P10K_CONFIG} ]]; then
    log_error "p10k config still present: ${P10K_CONFIG}"
    ((issues++))
  else
    log_success "p10k config removed"
  fi

  # Check default shell
  local current_shell
  current_shell=$(getent passwd "${TARGET_USER}" | cut -d: -f7)
  if [[ ${current_shell} == *zsh ]]; then
    log_warn "Default shell still zsh: ${current_shell}"
  else
    log_success "Default shell: ${current_shell}"
  fi

  # Check mise (if purge was requested)
  if [[ ${PURGE_DATA} == true ]]; then
    if [[ -f ${MISE_BIN} ]]; then
      log_error "mise still present: ${MISE_BIN}"
      ((issues++))
    else
      log_success "mise removed"
    fi
  else
    if [[ -f ${MISE_BIN} ]]; then
      log_info "mise preserved: ${MISE_BIN}"
    fi
  fi

  if ((issues > 0)); then
    log_warn "Removal completed with ${issues} issue(s)"
    return 1
  fi

  return 0
}

# Print removal summary
print_removal_summary() {
  printf '\n%b===============================================================%b\n' "${COLORS[bold]}" "${COLORS[reset]}" | tee -a "${LOG_FILE}"
  printf '%b                    REMOVAL COMPLETE%b\n' "${COLORS[bold]}" "${COLORS[reset]}" | tee -a "${LOG_FILE}"
  printf '%b===============================================================%b\n' "${COLORS[bold]}" "${COLORS[reset]}" | tee -a "${LOG_FILE}"

  [[ ${DRY_RUN} == true ]] && log_info "Mode: DRY-RUN (no changes made)"

  log_info ""
  log_info "Removed:"
  log_info "  - Oh-My-Zsh directory"
  log_info "  - Powerlevel10k theme"
  log_info "  - External plugins (zsh-autosuggestions, zsh-syntax-highlighting)"
  log_info "  - Shell configuration files (.zshrc, .p10k.zsh)"
  log_info "  - Default shell restored to bash"

  if [[ ${PURGE_DATA} == true ]]; then
    log_info "  - mise binary and data"
  else
    log_info ""
    log_info "Preserved (use --purge to remove):"
    log_info "  - mise binary and data"
  fi

  log_info ""
  log_info "NOT removed (by design):"
  log_info "  - Zsh package (may be used by other users)"
  log_info "  - fzf package (may be used by other applications)"
  log_info "  - Git (system dependency)"
  log_info ""
  log_info "Log file: ${LOG_FILE}"
  log_info ""
}

# Main removal orchestrator
main_remove() {
  mkdir -p "${LOG_FILE%/*}"
  : >"${LOG_FILE}"
  chmod 644 "${LOG_FILE}"

  log_info "==============================================================="
  log_info "  Shell Customization Remover v${SCRIPT_VERSION}"
  log_info "  Bash ${BASH_VERSION} | Started: $(printf '%(%F %T)T' "${EPOCHSECONDS}")"
  log_info "==============================================================="

  [[ ${DRY_RUN} == true ]] && log_warn "DRY-RUN MODE: No changes will be made"
  [[ ${PURGE_DATA} == true ]] && log_warn "PURGE MODE: mise data will be deleted"
  [[ ${FORCE_REMOVE} == true ]] && log_warn "FORCE MODE: Confirmations bypassed"

  setup_signal_handlers

  # Freeze configuration to prevent modification
  readonly TARGET_USER REMOVE_MODE PURGE_DATA FORCE_REMOVE
  readonly DRY_RUN VERBOSE SYSLOG

  acquire_lock

  # Validation
  check_root
  validate_required_commands
  validate_user

  # Check what's installed
  local has_installation=false
  # shellcheck disable=SC2310  # Intentional: capture result in variable
  check_shell_installation && has_installation=true

  if [[ ${has_installation} != true ]]; then
    log_info "No shell customization installation found. Nothing to remove."
    return 0
  fi

  # Confirmation prompt
  if [[ ${DRY_RUN} != true ]]; then
    printf '\n'
    log_warn "This will remove shell customization components."
    if [[ ${PURGE_DATA} == true ]]; then
      log_warn "mise and its data will also be deleted!"
    else
      log_info "mise will be preserved."
    fi
    printf '\n'

    local confirmed=false
    # shellcheck disable=SC2310  # Intentional: capture result in variable
    confirm_action "Proceed with removal?" && confirmed=true
    if [[ ${confirmed} != true ]]; then
      log_info "Removal cancelled by user."
      exit 0
    fi
  fi

  # Execute removal
  remove_shell_customization

  # Verify
  # shellcheck disable=SC2310  # Intentional: allow verification to fail gracefully
  verify_removal || true
  print_removal_summary

  log_success "Removal completed successfully!"
}

#-------------------------------------------------------------------------------
# Verification
#-------------------------------------------------------------------------------
verify_installation() {
  printf '\n%b===============================================================%b\n' "${COLORS[bold]}" "${COLORS[reset]}" | tee -a "${LOG_FILE}"
  printf '%b                    VERIFICATION%b\n' "${COLORS[bold]}" "${COLORS[reset]}" | tee -a "${LOG_FILE}"
  printf '%b===============================================================%b\n' "${COLORS[bold]}" "${COLORS[reset]}" | tee -a "${LOG_FILE}"

  if [[ ${DRY_RUN} == true ]]; then
    log_info "[DRY-RUN] Verification skipped"
    return 0
  fi

  local -i passed=0
  local -i total=8

  # 1. Zsh installed
  # shellcheck disable=SC2310  # Intentional: verification check in conditional
  if has_command zsh; then
    local zsh_ver
    zsh_ver="$(zsh --version 2>/dev/null)" || zsh_ver="unknown"
    log_success "Zsh: ${zsh_ver}"
    ((passed++))
  else
    log_error "Zsh: not installed"
  fi

  # 2. fzf installed
  # shellcheck disable=SC2310  # Intentional: verification check in conditional
  if has_command fzf; then
    local fzf_ver
    fzf_ver="$(fzf --version 2>/dev/null | head -1)" || fzf_ver="unknown"
    log_success "fzf: ${fzf_ver}"
    ((passed++))
  else
    log_error "fzf: not installed"
  fi

  # 3. Oh-My-Zsh installed
  if [[ -d ${OMZ_DIR} ]]; then
    log_success "Oh-My-Zsh: installed"
    ((passed++))
  else
    log_error "Oh-My-Zsh: not found"
  fi

  # 4. Powerlevel10k installed
  if [[ -d ${P10K_DIR} ]]; then
    log_success "Powerlevel10k: installed"
    ((passed++))
  else
    log_error "Powerlevel10k: not found"
  fi

  # 5. zsh-autosuggestions installed
  if [[ -d "${OMZ_CUSTOM}/plugins/zsh-autosuggestions" ]]; then
    log_success "zsh-autosuggestions: installed"
    ((passed++))
  else
    log_error "zsh-autosuggestions: not found"
  fi

  # 6. zsh-syntax-highlighting installed
  if [[ -d "${OMZ_CUSTOM}/plugins/zsh-syntax-highlighting" ]]; then
    log_success "zsh-syntax-highlighting: installed"
    ((passed++))
  else
    log_error "zsh-syntax-highlighting: not found"
  fi

  # 7. mise installed
  if [[ -f ${MISE_BIN} ]]; then
    local mise_ver
    mise_ver=$(sudo -u "${TARGET_USER}" "${MISE_BIN}" --version 2>/dev/null) || mise_ver="unknown"
    log_success "mise: ${mise_ver}"
    ((passed++))
  else
    log_warn "mise: not found (optional)"
    # Don't fail verification for mise - it's optional
    ((passed++))
  fi

  # 8. Default shell is zsh
  local current_shell
  current_shell=$(getent passwd "${TARGET_USER}" | cut -d: -f7)
  if [[ ${current_shell} == *zsh ]]; then
    log_success "Default shell: ${current_shell}"
    ((passed++))
  else
    log_error "Default shell: ${current_shell} (expected zsh)"
  fi

  log_info "Verification: ${passed}/${total} checks passed"
  return $((passed < total ? 1 : 0))
}

#-------------------------------------------------------------------------------
# Summary
#-------------------------------------------------------------------------------
print_summary() {
  printf '\n%b===============================================================%b\n' "${COLORS[bold]}" "${COLORS[reset]}" | tee -a "${LOG_FILE}"
  printf '%b                    INSTALLATION COMPLETE%b\n' "${COLORS[bold]}" "${COLORS[reset]}" | tee -a "${LOG_FILE}"
  printf '%b===============================================================%b\n' "${COLORS[bold]}" "${COLORS[reset]}" | tee -a "${LOG_FILE}"

  [[ ${DRY_RUN} == true ]] && log_info "Mode: DRY-RUN (no changes made)"

  log_info ""
  log_info "User:          ${TARGET_USER}"
  log_info "Shell:         zsh with Oh-My-Zsh + Powerlevel10k"
  log_info "Theme:         powerlevel10k (ASCII mode)"
  log_info "Plugins:       ${#OMZ_BUILTIN_PLUGINS[@]} built-in + ${#OMZ_EXTERNAL_PLUGINS[@]} external"
  log_info "Log file:      ${LOG_FILE}"
  log_info ""
  log_info "Installed plugins:"
  log_info "  Built-in: ${OMZ_BUILTIN_PLUGINS[*]}"
  log_info "  External: ${!OMZ_EXTERNAL_PLUGINS[*]}"
  log_info ""
  log_info "Key bindings:"
  log_info "  Ctrl+R  - fzf history search"
  log_info "  Ctrl+T  - fzf file search"
  log_info "  Alt+C   - fzf directory jump"
  log_info "  ESC ESC - prefix command with sudo"
  log_info ""
  log_info "To apply changes, start a new terminal or run: exec zsh"
}

#-------------------------------------------------------------------------------
# Help
#-------------------------------------------------------------------------------
show_help() {
  cat <<EOF
${COLORS[bold]}${SCRIPT_NAME}${COLORS[reset]} v${SCRIPT_VERSION} - Shell customization installer for WSL2

${COLORS[bold]}USAGE:${COLORS[reset]}
    sudo ${SCRIPT_NAME} [OPTIONS]

${COLORS[bold]}INSTALLATION OPTIONS:${COLORS[reset]}
    --user USERNAME    Configure shell for specified user (default: \$SUDO_USER)

${COLORS[bold]}REMOVAL OPTIONS:${COLORS[reset]}
    --remove           Remove shell customization (Oh-My-Zsh, configs)
    --purge            Also remove mise and its data
    --force, -f        Skip confirmation prompts

${COLORS[bold]}GENERAL OPTIONS:${COLORS[reset]}
    --dry-run          Preview without making changes
    --verbose, -v      Enable verbose output
    --trace-commands   Enable command-level tracing (DEBUG trap)
    --syslog           Also log to syslog (for enterprise environments)
    --help, -h         Show this help

${COLORS[bold]}WHAT GETS INSTALLED:${COLORS[reset]}
    - Zsh (from apt)
    - fzf (from apt)
    - Oh-My-Zsh (from GitHub)
    - Powerlevel10k theme (ASCII mode)
    - External plugins: zsh-autosuggestions, zsh-syntax-highlighting
    - mise version manager (no default tools)
    - Configured .zshrc with optimal settings

${COLORS[bold]}PLUGINS ENABLED:${COLORS[reset]}
    Built-in: git, docker, docker-compose, z, sudo, history,
              colored-man-pages, copypath, copyfile, fzf
    External: zsh-autosuggestions, zsh-syntax-highlighting

${COLORS[bold]}EXAMPLES:${COLORS[reset]}
    # Install shell customization
    sudo ${SCRIPT_NAME}
    sudo ${SCRIPT_NAME} --user myuser --verbose

    # Preview installation
    sudo ${SCRIPT_NAME} --dry-run

    # Remove shell customization (preserve mise)
    sudo ${SCRIPT_NAME} --remove

    # Remove everything including mise
    sudo ${SCRIPT_NAME} --remove --purge --force

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
        validate_username "${2}"
        TARGET_USER="${2}"
        shift 2
        ;;
      --user=*)
        TARGET_USER="${1#*=}"
        validate_username "${TARGET_USER}"
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
      --trace-commands)
        TRACE_COMMANDS=true
        shift
        ;;
      --syslog)
        SYSLOG=true
        shift
        ;;
      --remove)
        REMOVE_MODE=true
        shift
        ;;
      --purge)
        PURGE_DATA=true
        shift
        ;;
      --force | -f)
        FORCE_REMOVE=true
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

  # Validate argument combinations
  # --purge requires --remove
  [[ ${PURGE_DATA} == true && ${REMOVE_MODE} != true ]] && die "--purge requires --remove" "${EXIT_INVALID_ARGS}"

  # --force without --remove is a no-op (warn but continue)
  if [[ ${FORCE_REMOVE} == true && ${REMOVE_MODE} != true ]]; then
    log_warn "--force has no effect without --remove"
  fi
}

#-------------------------------------------------------------------------------
# Main
#-------------------------------------------------------------------------------
main() {
  mkdir -p "${LOG_FILE%/*}"
  : >"${LOG_FILE}"
  chmod 644 "${LOG_FILE}"

  log_info "==============================================================="
  log_info "  Shell Customization Installer v${SCRIPT_VERSION}"
  log_info "  Bash ${BASH_VERSION} | Started: $(printf '%(%F %T)T' "${EPOCHSECONDS}")"
  log_info "==============================================================="

  [[ ${DRY_RUN} == true ]] && log_warn "DRY-RUN MODE: No changes will be made"
  [[ ${TRACE_COMMANDS} == true ]] && log_warn "TRACE MODE: Command tracing enabled"

  setup_signal_handlers
  setup_debug_tracing

  # Freeze configuration to prevent modification
  readonly TARGET_USER DRY_RUN VERBOSE SYSLOG TRACE_COMMANDS

  acquire_lock

  # Validation
  check_root
  validate_required_commands
  check_wsl2
  validate_user
  check_network

  # Installation
  install_zsh
  install_fzf
  install_ohmyzsh
  install_powerlevel10k
  install_external_plugins
  install_mise
  configure_shell

  # Verify
  # shellcheck disable=SC2310  # Intentional: allow verification to fail gracefully
  verify_installation || true

  print_summary

  log_success "Installation completed successfully!"
}

parse_arguments "$@"

# Route to appropriate main function based on mode
if [[ ${REMOVE_MODE} == true ]]; then
  main_remove
else
  main
fi
