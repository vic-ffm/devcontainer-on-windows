#!/usr/bin/env bash
#===============================================================================
# install-github-cli.sh - GitHub CLI installer with Git/SSH configuration
#
# DESCRIPTION:
#   Script to install GitHub CLI and configure Git authentication.
#   Supports browser-based OAuth, SSH key generation, and Git identity setup.
#   Non-interactive (where possible) and idempotent.
#
# REQUIREMENTS:
#   Bash 5.2+
#   Ubuntu 24.04+ or Debian 12+ in WSL2
#
# USAGE:
#   sudo ./install-github-cli.sh --user USERNAME
#   sudo ./install-github-cli.sh --user USERNAME --verbose
#   sudo ./install-github-cli.sh --user USERNAME --skip-ssh
#   sudo ./install-github-cli.sh --remove
#   sudo ./install-github-cli.sh --remove --purge --force
#
# INSTALLATION OPTIONS:
#   --user USERNAME    Target user for authentication (required)
#   --skip-ssh         Skip SSH key generation and upload
#   --skip-git-config  Skip Git identity configuration
#   --ssh-key-comment  Custom comment for SSH key
#
# REMOVAL OPTIONS:
#   --remove           Remove GitHub CLI and repository configuration
#   --purge            Also remove SSH keys created by this script
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
# LICENSE:
#   BSD 3-Clause "New" or "Revised" License
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
declare -r LOG_FILE="/var/log/github-cli-install.log"
declare -r LOCK_FILE="/var/lock/github-cli-install.lock"

# GitHub CLI repository configuration
declare -r GH_GPG_URL="https://cli.github.com/packages/githubcli-archive-keyring.gpg"
declare -r GH_REPO_URL="https://cli.github.com/packages"

# GitHub CLI GPG key fingerprint for verification
# Renewed September 2024, expires September 2026
# Source: https://github.blog/changelog/2024-09-11-github-cli-renews-gpg-signing-key-for-linux-packages/
declare -r GH_GPG_FINGERPRINT="2C6106201985B60E6C7AC87323F3D4EA75716059"

# Allowed domains for downloads (security allowlist)
declare -ra ALLOWED_DOWNLOAD_DOMAINS=(cli.github.com github.com api.github.com)

# Network retry configuration
declare -ri MAX_RETRIES=5
declare -ri RETRY_DELAY_BASE=2

# Lock timeout (seconds) - prevents deadlocks from stuck processes
declare -ri LOCK_TIMEOUT=300

# shellcheck disable=SC2034  # EXIT_SUCCESS defined for completeness/documentation
declare -ri EXIT_SUCCESS=0
declare -ri EXIT_GENERAL_ERROR=1
declare -ri EXIT_LOCK_FAILED=2
declare -ri EXIT_INVALID_ARGS=3
declare -ri EXIT_ROOT_REQUIRED=4
declare -ri EXIT_NOT_WSL2=5
declare -ri EXIT_UNSUPPORTED_DISTRO=6
declare -ri EXIT_NETWORK_ERROR=7
declare -ri EXIT_INSTALL_FAILED=8
declare -ri EXIT_AUTH_FAILED=9
declare -ri EXIT_SSH_FAILED=10
# shellcheck disable=SC2034  # EXIT_USER_CANCELLED defined for completeness/documentation
declare -ri EXIT_USER_CANCELLED=11

declare -ra REQUIRED_COMMANDS=(
  curl apt-get dpkg-query getent id stat mkdir rm mv cp chmod
  gpg awk grep sed tee sleep flock pgrep uname sha256sum cut mktemp
  ssh-keygen
)

# Files/directories managed by this installer
declare -r GH_GPG_KEY="/etc/apt/keyrings/githubcli-archive-keyring.gpg"
declare -r GH_SOURCES_FILE="/etc/apt/sources.list.d/github-cli.sources"
declare -r SSH_CONFIG_MARKER="# GitHub SSH config (managed by install-github-cli.sh)"

#-------------------------------------------------------------------------------
# Global State Variables
#-------------------------------------------------------------------------------
declare TARGET_USER="${SUDO_USER:-}"
declare DRY_RUN=false
declare VERBOSE=false
declare SYSLOG=false
declare SKIP_SSH=false
declare SKIP_GIT_CONFIG=false
declare SSH_KEY_COMMENT=""

# Removal mode state
declare REMOVE_MODE=false
declare PURGE_DATA=false
declare FORCE_REMOVE=false

declare ARCH=""

# Cleanup state tracking (for rollback)
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

# Prompt for confirmation
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

# Retry with exponential backoff
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

has_command() {
  command -v "$1" &>/dev/null
}

# Validate URL format and domain allowlist
validate_url() {
  local -r url="$1"
  local -r pattern='^https://[a-zA-Z0-9][-a-zA-Z0-9]*(\.[a-zA-Z0-9][-a-zA-Z0-9]*)+(/[-a-zA-Z0-9_.~%/]*)?$'

  # Validate URL format
  if [[ ! ${url} =~ ${pattern} ]]; then
    die "Invalid URL format: ${url}" "${EXIT_GENERAL_ERROR}"
  fi

  # Extract domain from URL
  local domain
  domain="${url#https://}"
  domain="${domain%%/*}"

  # Validate against allowed domains
  local allowed=false
  local d
  for d in "${ALLOWED_DOWNLOAD_DOMAINS[@]}"; do
    if [[ ${domain} == "${d}" ]]; then
      allowed=true
      break
    fi
  done

  if [[ ${allowed} != true ]]; then
    die "URL domain not in allowlist: ${domain}" "${EXIT_GENERAL_ERROR}"
  fi
}

# File download with TLS
secure_download() {
  local -r url="$1"
  local -r output="$2"
  local -ri max_size="${3:-10485760}" # 10MB default

  # Validate URL before downloading
  validate_url "${url}"

  curl -fsSL \
    --proto '=https' \
    --tlsv1.2 \
    --connect-timeout 10 \
    --max-time 60 \
    --retry 3 \
    --retry-connrefused \
    --max-filesize "${max_size}" \
    -o "${output}" \
    "${url}"
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

# APT install with non-interactive settings
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

# Verify GPG key fingerprint
verify_gpg_fingerprint() {
  local -r keyfile="$1"
  local actual_fp

  actual_fp=$(gpg --show-keys --with-fingerprint --with-colons "${keyfile}" 2>/dev/null \
    | awk -F: '/^fpr:/{gsub(/ /,"",$10); print $10; exit}')
  local -r actual_fp

  if [[ -z ${actual_fp} ]]; then
    die "Failed to extract fingerprint from GPG key" "${EXIT_GENERAL_ERROR}"
  fi

  if [[ ${actual_fp^^} != "${GH_GPG_FINGERPRINT^^}" ]]; then
    log_error "GPG key fingerprint mismatch!"
    log_error "Expected: ${GH_GPG_FINGERPRINT}"
    log_error "Got:      ${actual_fp}"
    die "Security verification failed - GPG key may be compromised" "${EXIT_GENERAL_ERROR}"
  fi

  log_success "GPG key fingerprint verified"
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
# Locks
#-------------------------------------------------------------------------------
acquire_lock() {
  log_debug "Acquiring lock: ${LOCK_FILE}"

  mkdir -p "${LOCK_FILE%/*}"

  # Open lock file
  exec {LOCK_FD}>"${LOCK_FILE}"

  if ! flock -w "${LOCK_TIMEOUT}" "${LOCK_FD}"; then
    die "Could not acquire lock within ${LOCK_TIMEOUT}s. Another instance may be stuck." "${EXIT_LOCK_FAILED}"
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

atomic_write() {
  local -r target="$1"
  local -r content="$2"
  local temp

  temp=$(mktemp "${target}.tmp.XXXXXX") || die "Failed to create temp file for ${target}" "${EXIT_GENERAL_ERROR}"

  # Clean up temp file on function exit
  trap 'rm -f "${temp}" 2>/dev/null; trap - RETURN' RETURN

  # Write to temp file first
  printf '%s\n' "${content}" >"${temp}"

  mv -f "${temp}" "${target}"

  # Clear trap and register for rollback tracking
  trap - RETURN
  register_created_file "${target}"
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

  # Print stack trace in verbose mode
  if [[ ${VERBOSE} == true ]]; then
    log_debug "Stack trace:"
    local -i i
    for ((i = 1; i < ${#FUNCNAME[@]}; i++)); do
      log_debug "  [${i}] ${FUNCNAME[i]}() at ${BASH_SOURCE[i]:-unknown}:${BASH_LINENO[i - 1]}"
    done

    # Show key variable state for debugging
    log_debug "Variable state:"
    log_debug "  DRY_RUN=${DRY_RUN:-unset}"
    log_debug "  ARCH=${ARCH:-unset}"
    log_debug "  TARGET_USER=${TARGET_USER:-unset}"
  fi
}

#-------------------------------------------------------------------------------
# Cleanup Handler (runs on EXIT - catches all termination scenarios)
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
    local action="${CLEANUP_ACTIONS[i]}"
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

    # Clean up apt state if we were mid operation
    local has_apt=false
    # shellcheck disable=SC2310  # Intentional: capture result in variable
    has_command apt-get && has_apt=true
    if [[ ${has_apt} == true ]]; then
      log_debug "Cleaning apt state..."
      apt-get clean 2>/dev/null || true
      rm -f /var/lib/apt/lists/lock 2>/dev/null || true
      rm -f /var/lib/dpkg/lock* 2>/dev/null || true
    fi
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
  trap 'signal_handler HUP' HUP
  trap 'signal_handler INT' INT
  trap 'signal_handler QUIT' QUIT
  trap 'signal_handler TERM' TERM

  # Program error signals (fatal - attempt cleanup)
  trap 'signal_handler ILL' ILL
  trap 'signal_handler TRAP' TRAP
  trap 'signal_handler ABRT' ABRT
  trap 'signal_handler BUS' BUS
  trap 'signal_handler FPE' FPE
  trap 'signal_handler SEGV' SEGV
  trap 'signal_handler SYS' SYS
  trap 'signal_handler STKFLT' STKFLT 2>/dev/null || true
  # These are not widely available. Attempt to trap but ignore failure
  trap 'signal_handler EMT' EMT 2>/dev/null || true
  trap 'signal_handler IOT' IOT 2>/dev/null || true

  log_debug "Signal handlers installed"
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

detect_architecture() {
  log_info "Detecting system architecture..."

  local machine
  machine="$(uname -m)" || die "Failed to detect architecture" "${EXIT_GENERAL_ERROR}"
  local -r machine

  case "${machine}" in
    x86_64) ARCH="amd64" ;;
    aarch64 | arm64) ARCH="arm64" ;;
    armv7l | armhf) ARCH="armhf" ;;
    *) die "Unsupported architecture: ${machine}" "${EXIT_UNSUPPORTED_DISTRO}" ;;
  esac

  log_success "Architecture: ${ARCH}"
}

validate_user() {
  log_info "Validating target user..."

  [[ -z ${TARGET_USER} ]] && TARGET_USER="${SUDO_USER:-${USER:-}}"

  if [[ -z ${TARGET_USER} || ${TARGET_USER} == root ]]; then
    die "A non-root user must be specified with --user USERNAME" "${EXIT_INVALID_ARGS}"
  fi

  id "${TARGET_USER}" &>/dev/null || die "User '${TARGET_USER}' does not exist" "${EXIT_INVALID_ARGS}"

  log_success "Target user: ${TARGET_USER}"
}

#-------------------------------------------------------------------------------
# Network Connectivity Check
#-------------------------------------------------------------------------------
check_network() {
  log_info "Checking network connectivity..."

  local -ra test_endpoints=(
    "https://cli.github.com"
    "https://github.com"
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

  die "No network connectivity. Please check your internet connection." "${EXIT_NETWORK_ERROR}"
}

#-------------------------------------------------------------------------------
# GitHub CLI Installation Functions
#-------------------------------------------------------------------------------
setup_gh_repository() {
  log_step "1/6" "Setting up GitHub CLI repository"

  local -r keyring_dir="/etc/apt/keyrings"
  local -r keyring_file="${keyring_dir}/githubcli-archive-keyring.gpg"
  local -r sources_file="/etc/apt/sources.list.d/github-cli.sources"

  # Create keyring directory if needed
  [[ -d ${keyring_dir} ]] || execute install -m 0755 -d "${keyring_dir}"

  # Check for existing valid setup
  if [[ -f ${keyring_file} && -f ${sources_file} ]]; then
    # shellcheck disable=SC2310  # Intentional: check function result in conditional
    if verify_gpg_fingerprint "${keyring_file}" 2>/dev/null; then
      log_success "GitHub CLI repository already configured"
      return 0
    fi
    log_warn "Existing GPG key invalid, refreshing..."
  fi

  log_info "Downloading GitHub CLI GPG key..."

  if [[ ${DRY_RUN} == true ]]; then
    log_info "[DRY-RUN] Would download: ${GH_GPG_URL}"
    return 0
  fi

  retry_with_backoff "${MAX_RETRIES}" "${RETRY_DELAY_BASE}" \
    secure_download "${GH_GPG_URL}" "${keyring_file}" 1048576

  chmod a+r "${keyring_file}"
  verify_gpg_fingerprint "${keyring_file}"
  register_created_file "${keyring_file}"

  # Create DEB822 format sources file
  log_info "Configuring repository..."

  local repo_content
  printf -v repo_content 'Types: deb
URIs: %s
Suites: stable
Components: main
Signed-By: %s
Architectures: %s' \
    "${GH_REPO_URL}" "${keyring_file}" "${ARCH}"

  [[ -f ${sources_file} ]] && backup_file "${sources_file}"
  atomic_write "${sources_file}" "${repo_content}"

  log_info "Updating package index..."
  execute apt-get update -qq

  log_success "GitHub CLI repository configured"
}

install_github_cli() {
  log_step "2/6" "Installing GitHub CLI"

  # Check existing installation
  local has_gh=false
  # shellcheck disable=SC2310  # Intentional: capture result in variable
  has_command gh && has_gh=true

  if [[ ${has_gh} == true ]]; then
    local current_version
    current_version="$(gh --version 2>/dev/null | head -1)" || current_version="unknown"
    log_info "GitHub CLI already installed: ${current_version}"

    if sudo -u "${TARGET_USER}" gh auth status &>/dev/null; then
      log_success "GitHub CLI is authenticated and functional"
    else
      log_info "GitHub CLI installed but not authenticated"
    fi
    return 0
  fi

  log_info "Installing: gh"

  if [[ ${DRY_RUN} == true ]]; then
    log_info "[DRY-RUN] Would install: gh"
    return 0
  fi

  execute apt_install gh

  # shellcheck disable=SC2310  # Intentional: die terminates on failure
  has_command gh || die "GitHub CLI installation failed" "${EXIT_INSTALL_FAILED}"

  local gh_ver
  gh_ver="$(gh --version | head -1)" || gh_ver="unknown"
  log_success "GitHub CLI installed: ${gh_ver}"
}

authenticate_github() {
  log_step "3/6" "Authenticating with GitHub"

  # Check if already authenticated
  if sudo -u "${TARGET_USER}" gh auth status &>/dev/null; then
    log_success "Already authenticated with GitHub"
    return 0
  fi

  if [[ ${DRY_RUN} == true ]]; then
    log_info "[DRY-RUN] Would run: gh auth login --hostname github.com --git-protocol https --web"
    return 0
  fi

  # Check if we have a TTY for interactive auth
  if [[ ! -t 0 ]]; then
    log_warn "No interactive terminal detected"
    log_warn "GitHub authentication requires browser interaction"
    log_warn "Options:"
    log_warn "  1. Run this script in an interactive terminal"
    log_warn "  2. Pre-authenticate: sudo -u ${TARGET_USER} gh auth login"
    log_warn "  3. Use token: echo TOKEN | sudo -u ${TARGET_USER} gh auth login --with-token"
    die "Interactive authentication required" "${EXIT_AUTH_FAILED}"
  fi

  log_info "Starting browser-based OAuth authentication..."
  log_warn "INTERACTIVE: A browser window will open for GitHub authentication"
  log_info ""
  log_info "Authentication settings:"
  log_info "  - Host: github.com"
  log_info "  - Protocol: HTTPS"
  log_info "  - Git authentication: Enabled"
  log_info ""

  # Run gh auth login as the target user
  # This is interactive and requires user browser action
  # Note: admin:public_key scope is required for gh ssh-key add
  if ! sudo -u "${TARGET_USER}" gh auth login \
    --hostname github.com \
    --git-protocol https \
    --web \
    --scopes admin:public_key; then
    die "GitHub authentication failed" "${EXIT_AUTH_FAILED}"
  fi

  # Verify authentication
  if ! sudo -u "${TARGET_USER}" gh auth status &>/dev/null; then
    die "Authentication verification failed" "${EXIT_AUTH_FAILED}"
  fi

  # Setup Git to use gh for authentication
  sudo -u "${TARGET_USER}" gh auth setup-git

  log_success "GitHub authentication complete"
}

configure_git_identity() {
  log_step "4/6" "Configuring Git identity"

  if [[ ${SKIP_GIT_CONFIG} == true ]]; then
    log_info "Skipping Git configuration (--skip-git-config)"
    return 0
  fi

  # Check if already configured
  local existing_name existing_email
  existing_name=$(sudo -u "${TARGET_USER}" git config --global user.name 2>/dev/null) || true
  existing_email=$(sudo -u "${TARGET_USER}" git config --global user.email 2>/dev/null) || true

  if [[ -n ${existing_name} && -n ${existing_email} ]]; then
    log_info "Git already configured:"
    log_info "  user.name:  ${existing_name}"
    log_info "  user.email: ${existing_email}"
    log_success "Git identity already configured"
    return 0
  fi

  if [[ ${DRY_RUN} == true ]]; then
    log_info "[DRY-RUN] Would configure Git identity from GitHub API"
    return 0
  fi

  log_info "Fetching identity from GitHub API..."

  # Get user info from GitHub
  local gh_name gh_login gh_email gh_id

  gh_name=$(sudo -u "${TARGET_USER}" gh api user --jq '.name // empty' 2>/dev/null) || true
  gh_login=$(sudo -u "${TARGET_USER}" gh api user --jq '.login' 2>/dev/null) || true
  gh_email=$(sudo -u "${TARGET_USER}" gh api user --jq '.email // empty' 2>/dev/null) || true
  gh_id=$(sudo -u "${TARGET_USER}" gh api user --jq '.id' 2>/dev/null) || true

  # Use login as fallback for name
  [[ -z ${gh_name} ]] && gh_name="${gh_login}"

  # If email is private/null, construct noreply email
  if [[ -z ${gh_email} || ${gh_email} == "null" ]]; then
    gh_email="${gh_id}+${gh_login}@users.noreply.github.com"
    log_info "Using GitHub noreply email (public email not set)"
  fi

  if [[ -z ${gh_name} || -z ${gh_email} ]]; then
    die "Could not retrieve GitHub user information" "${EXIT_AUTH_FAILED}"
  fi

  log_info "Setting Git identity:"
  log_info "  user.name:  ${gh_name}"
  log_info "  user.email: ${gh_email}"

  sudo -u "${TARGET_USER}" git config --global user.name "${gh_name}"
  sudo -u "${TARGET_USER}" git config --global user.email "${gh_email}"

  log_success "Git identity configured from GitHub profile"
}

generate_ssh_key() {
  log_step "5/6" "Generating SSH key"

  if [[ ${SKIP_SSH} == true ]]; then
    log_info "Skipping SSH key generation (--skip-ssh)"
    return 0
  fi

  local -r user_home="/home/${TARGET_USER}"
  local -r ssh_dir="${user_home}/.ssh"
  local -r key_file="${ssh_dir}/id_ed25519_github"

  # Check if key already exists
  if [[ -f ${key_file} ]]; then
    log_info "SSH key already exists: ${key_file}"

    # Check if key is already on GitHub
    # shellcheck disable=SC2310  # Intentional: check function result in conditional
    if check_ssh_key_on_github "${key_file}.pub"; then
      log_success "SSH key already registered with GitHub"
      return 0
    fi
    log_info "Key exists locally but not on GitHub - will upload"
  else
    if [[ ${DRY_RUN} == true ]]; then
      log_info "[DRY-RUN] Would generate: ${key_file}"
    else
      # Create .ssh directory
      sudo -u "${TARGET_USER}" mkdir -p "${ssh_dir}"
      sudo -u "${TARGET_USER}" chmod 700 "${ssh_dir}"

      # Generate comment for the key
      local key_comment
      if [[ -n ${SSH_KEY_COMMENT} ]]; then
        key_comment="${SSH_KEY_COMMENT}"
      else
        local hostname_short
        hostname_short=$(hostname -s 2>/dev/null) || hostname_short="wsl2"
        printf -v key_comment 'WSL2-DevContainers-%s-%(%Y%m%d)T' "${hostname_short}" "${EPOCHSECONDS}"
      fi

      log_info "Generating Ed25519 key: ${key_file}"
      log_info "Comment: ${key_comment}"

      # Generate Ed25519 key with no passphrase
      sudo -u "${TARGET_USER}" ssh-keygen \
        -t ed25519 \
        -f "${key_file}" \
        -N "" \
        -C "${key_comment}"

      # Set permissions
      sudo -u "${TARGET_USER}" chmod 600 "${key_file}"
      sudo -u "${TARGET_USER}" chmod 644 "${key_file}.pub"

      register_created_file "${key_file}"
      register_created_file "${key_file}.pub"

      log_success "SSH key generated"
    fi
  fi

  # Upload to GitHub
  upload_ssh_key_to_github "${key_file}.pub"
}

check_ssh_key_on_github() {
  local -r pub_key_file="$1"

  [[ -f ${pub_key_file} ]] || return 1

  local pub_key_content
  pub_key_content=$(sudo -u "${TARGET_USER}" cat "${pub_key_file}")

  # Get list of SSH keys from GitHub
  local gh_keys
  gh_keys=$(sudo -u "${TARGET_USER}" gh ssh-key list 2>/dev/null) || return 1

  # Extract the key portion
  local key_data
  key_data=$(echo "${pub_key_content}" | awk '{print $2}')

  # Check if key is in the list
  echo "${gh_keys}" | grep -qF "${key_data}"
}

upload_ssh_key_to_github() {
  local -r pub_key_file="$1"

  if [[ ${DRY_RUN} == true ]]; then
    log_info "[DRY-RUN] Would upload: ${pub_key_file}"
    return 0
  fi

  [[ -f ${pub_key_file} ]] || die "Public key not found: ${pub_key_file}" "${EXIT_SSH_FAILED}"

  local key_title
  local hostname_short
  hostname_short=$(hostname -s 2>/dev/null) || hostname_short="wsl2"
  printf -v key_title 'WSL2-DevContainers-%s-%(%Y%m%d)T' "${hostname_short}" "${EPOCHSECONDS}"

  log_info "Uploading SSH key to GitHub..."
  log_info "Title: ${key_title}"

  local upload_output
  if ! upload_output=$(sudo -u "${TARGET_USER}" gh ssh-key add "${pub_key_file}" \
    --title "${key_title}" \
    --type authentication 2>&1); then
    # Upload command failed - check if key already exists
    # shellcheck disable=SC2310  # Intentional: check function result in conditional
    if check_ssh_key_on_github "${pub_key_file}"; then
      log_info "SSH key already exists on GitHub"
    else
      log_error "SSH key upload failed: ${upload_output}"
      die "Failed to upload SSH key to GitHub. Ensure you authorized the 'admin:public_key' scope during login." "${EXIT_SSH_FAILED}"
    fi
  fi

  # Verify the key is actually on GitHub
  # shellcheck disable=SC2310  # Intentional: check function result in conditional
  if ! check_ssh_key_on_github "${pub_key_file}"; then
    die "SSH key upload verification failed - key not found on GitHub" "${EXIT_SSH_FAILED}"
  fi

  log_success "SSH key registered with GitHub"
}

configure_ssh_for_github() {
  log_step "6/6" "Configuring SSH for GitHub"

  if [[ ${SKIP_SSH} == true ]]; then
    log_info "Skipping SSH configuration (--skip-ssh)"
    return 0
  fi

  local -r user_home="/home/${TARGET_USER}"
  local -r ssh_config="${user_home}/.ssh/config"
  local -r key_file="${user_home}/.ssh/id_ed25519_github"

  # Check if already configured
  if [[ -f ${ssh_config} ]] && grep -q "${SSH_CONFIG_MARKER}" "${ssh_config}" 2>/dev/null; then
    log_success "SSH config already includes GitHub configuration"
    return 0
  fi

  if [[ ${DRY_RUN} == true ]]; then
    log_info "[DRY-RUN] Would configure: ${ssh_config}"
    return 0
  fi

  log_info "Adding GitHub SSH configuration..."

  # Backup existing config
  [[ -f ${ssh_config} ]] && backup_file "${ssh_config}"

  # Create/append GitHub config
  local gh_ssh_config
  printf -v gh_ssh_config '%s
Host github.com
    HostName github.com
    User git
    IdentityFile %s
    IdentitiesOnly yes
    AddKeysToAgent yes
' "${SSH_CONFIG_MARKER}" "${key_file}"

  if [[ -f ${ssh_config} ]]; then
    # Append to existing config
    printf '\n%s\n' "${gh_ssh_config}" | sudo -u "${TARGET_USER}" tee -a "${ssh_config}" >/dev/null
  else
    # Create new config
    sudo -u "${TARGET_USER}" mkdir -p "${user_home}/.ssh"
    printf '%s\n' "${gh_ssh_config}" | sudo -u "${TARGET_USER}" tee "${ssh_config}" >/dev/null
    sudo -u "${TARGET_USER}" chmod 600 "${ssh_config}"
    register_created_file "${ssh_config}"
  fi

  # Verify SSH connection - this MUST succeed for the setup to be complete
  log_info "Testing SSH connection to GitHub..."
  local ssh_test
  ssh_test=$(sudo -u "${TARGET_USER}" ssh -T git@github.com 2>&1) || true

  if echo "${ssh_test}" | grep -q "successfully authenticated"; then
    log_success "SSH connection to GitHub verified"
  else
    log_error "SSH test failed: ${ssh_test}"
    die "SSH connection to GitHub failed. The SSH key may not be properly uploaded to your GitHub account." "${EXIT_SSH_FAILED}"
  fi

  log_success "SSH configured for GitHub"
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
  local -i total=5

  # 1. gh command available
  local has_gh_cmd=false
  # shellcheck disable=SC2310  # Intentional: capture result in variable
  has_command gh && has_gh_cmd=true
  if [[ ${has_gh_cmd} == true ]]; then
    local gh_ver
    gh_ver="$(gh --version | head -1)" || gh_ver="unknown"
    log_success "GitHub CLI: ${gh_ver}"
    ((passed++))
  else
    log_error "GitHub CLI not found"
  fi

  # 2. gh authenticated
  if sudo -u "${TARGET_USER}" gh auth status &>/dev/null; then
    log_success "GitHub authentication: valid"
    ((passed++))
  else
    log_warn "GitHub authentication: not authenticated"
  fi

  # 3. Git identity configured
  local git_name git_email
  git_name=$(sudo -u "${TARGET_USER}" git config --global user.name 2>/dev/null) || true
  git_email=$(sudo -u "${TARGET_USER}" git config --global user.email 2>/dev/null) || true

  if [[ -n ${git_name} && -n ${git_email} ]]; then
    log_success "Git identity: ${git_name} <${git_email}>"
    ((passed++))
  else
    log_warn "Git identity: not configured"
  fi

  # 4. SSH key exists
  local -r key_file="/home/${TARGET_USER}/.ssh/id_ed25519_github"
  if [[ -f ${key_file} ]]; then
    log_success "SSH key: ${key_file}"
    ((passed++))
  else
    if [[ ${SKIP_SSH} == true ]]; then
      log_info "SSH key: skipped"
      ((passed++))
    else
      log_warn "SSH key: not found"
    fi
  fi

  # 5. SSH connection works
  if [[ ${SKIP_SSH} != true ]]; then
    local ssh_test
    ssh_test=$(sudo -u "${TARGET_USER}" ssh -T git@github.com 2>&1) || true
    if echo "${ssh_test}" | grep -q "successfully authenticated"; then
      log_success "SSH authentication: working"
      ((passed++))
    else
      log_warn "SSH authentication: not verified"
    fi
  else
    log_info "SSH authentication: skipped"
    ((passed++))
  fi

  log_info "Verification: ${passed}/${total} checks passed"
  return $((passed < 3 ? 1 : 0))
}

#-------------------------------------------------------------------------------
# Removal Functions
#-------------------------------------------------------------------------------
check_gh_installation() {
  log_info "Checking GitHub CLI installation..."

  local -i found=0

  # Check package
  local pkg_installed=false
  # shellcheck disable=SC2310  # Intentional: capture result in variable
  is_installed gh && pkg_installed=true
  if [[ ${pkg_installed} == true ]]; then
    log_info "  Package installed: gh"
    ((found++))
  fi

  # Check GPG key
  if [[ -f ${GH_GPG_KEY} ]]; then
    log_info "  GPG key present: ${GH_GPG_KEY}"
    ((found++))
  fi

  # Check sources file
  if [[ -f ${GH_SOURCES_FILE} ]]; then
    log_info "  Repository configured: ${GH_SOURCES_FILE}"
    ((found++))
  fi

  # Check SSH key
  if [[ -n ${TARGET_USER} ]]; then
    local -r key_file="/home/${TARGET_USER}/.ssh/id_ed25519_github"
    if [[ -f ${key_file} ]]; then
      log_info "  SSH key: ${key_file}"
      ((found++))
    fi
  fi

  if ((found == 0)); then
    log_warn "No GitHub CLI installation detected"
    return 1
  fi

  log_success "Found ${found} GitHub CLI component(s)"
  return 0
}

remove_github_cli() {
  log_step "1/3" "Removing GitHub CLI package"

  local pkg_installed=false
  # shellcheck disable=SC2310  # Intentional: capture result in variable
  is_installed gh && pkg_installed=true

  if [[ ${pkg_installed} == true ]]; then
    log_info "Removing gh package..."
    export DEBIAN_FRONTEND=noninteractive
    # shellcheck disable=SC2310  # Intentional: allow failures during removal
    execute apt-get remove -y --purge gh || true
    # shellcheck disable=SC2310  # Intentional: allow failures during removal
    execute apt-get autoremove -y || true
    log_success "GitHub CLI package removed"
  else
    log_info "gh package not installed"
  fi
}

remove_gh_repository() {
  log_step "2/3" "Removing GitHub CLI repository"

  if [[ -f ${GH_GPG_KEY} ]]; then
    log_info "Removing GPG key: ${GH_GPG_KEY}"
    execute rm -f "${GH_GPG_KEY}"
    log_success "GPG key removed"
  else
    log_info "GPG key not present"
  fi

  if [[ -f ${GH_SOURCES_FILE} ]]; then
    log_info "Removing repository: ${GH_SOURCES_FILE}"
    execute rm -f "${GH_SOURCES_FILE}"
    log_success "Repository configuration removed"
  else
    log_info "Repository configuration not present"
  fi

  # Also check for legacy format
  local -r legacy_list="/etc/apt/sources.list.d/github-cli.list"
  if [[ -f ${legacy_list} ]]; then
    log_info "Removing legacy repository: ${legacy_list}"
    execute rm -f "${legacy_list}"
  fi

  # Update package cache
  log_info "Updating package index..."
  # shellcheck disable=SC2310  # Intentional: allow apt-get update to fail
  execute apt-get update -qq 2>/dev/null || true

  log_success "GitHub CLI repository removed"
}

remove_ssh_config() {
  log_step "3/3" "Cleaning up SSH configuration"

  if [[ -z ${TARGET_USER} ]]; then
    log_info "No user specified - skipping SSH cleanup"
    return 0
  fi

  local -r user_home="/home/${TARGET_USER}"
  local -r ssh_config="${user_home}/.ssh/config"
  local -r key_file="${user_home}/.ssh/id_ed25519_github"

  # Remove SSH key files (only with --purge)
  if [[ ${PURGE_DATA} == true ]]; then
    if [[ -f ${key_file} ]]; then
      log_info "Removing SSH key: ${key_file}"
      execute rm -f "${key_file}" "${key_file}.pub"
      log_success "SSH keys removed"
    fi
  else
    if [[ -f ${key_file} ]]; then
      log_warn "Preserving SSH key: ${key_file}"
      log_info "  (use --purge to remove)"
    fi
  fi

  # Remove GitHub section from SSH config
  if [[ -f ${ssh_config} ]] && grep -q "${SSH_CONFIG_MARKER}" "${ssh_config}" 2>/dev/null; then
    log_info "Removing GitHub configuration from: ${ssh_config}"

    if [[ ${DRY_RUN} == true ]]; then
      log_info "[DRY-RUN] Would edit: ${ssh_config}"
    else
      # Create temp file, filter out the GitHub section
      local temp_config
      temp_config=$(mktemp)
      awk -v marker="${SSH_CONFIG_MARKER}" '
        BEGIN { skip=0 }
        $0 ~ marker { skip=1; next }
        /^Host / && skip { skip=0 }
        !skip { print }
      ' "${ssh_config}" >"${temp_config}"
      mv -f "${temp_config}" "${ssh_config}"
      chown "${TARGET_USER}:${TARGET_USER}" "${ssh_config}"
      chmod 600 "${ssh_config}"
      log_success "GitHub SSH configuration removed"
    fi
  else
    log_info "No GitHub SSH configuration found"
  fi
}

verify_removal() {
  printf '\n%b===============================================================%b\n' "${COLORS[bold]}" "${COLORS[reset]}" | tee -a "${LOG_FILE}"
  printf '%b                    REMOVAL VERIFICATION%b\n' "${COLORS[bold]}" "${COLORS[reset]}" | tee -a "${LOG_FILE}"
  printf '%b===============================================================%b\n' "${COLORS[bold]}" "${COLORS[reset]}" | tee -a "${LOG_FILE}"

  if [[ ${DRY_RUN} == true ]]; then
    log_info "[DRY-RUN] Verification skipped"
    return 0
  fi

  local -i issues=0

  # Check package removed
  local pkg_installed=false
  # shellcheck disable=SC2310  # Intentional: capture result in variable
  is_installed gh && pkg_installed=true
  if [[ ${pkg_installed} == true ]]; then
    log_error "Package still installed: gh"
    ((issues++))
  else
    log_success "gh package removed"
  fi

  # Check gh command gone
  local has_gh_cmd=false
  # shellcheck disable=SC2310  # Intentional: capture result in variable
  has_command gh && has_gh_cmd=true
  if [[ ${has_gh_cmd} == true ]]; then
    log_warn "gh command still available (may be from another source)"
  else
    log_success "gh command removed"
  fi

  # Check repository removed
  if [[ -f ${GH_GPG_KEY} ]]; then
    log_error "GPG key still present: ${GH_GPG_KEY}"
    ((issues++))
  else
    log_success "GPG key removed"
  fi

  if [[ -f ${GH_SOURCES_FILE} ]]; then
    log_error "Repository still configured: ${GH_SOURCES_FILE}"
    ((issues++))
  else
    log_success "Repository configuration removed"
  fi

  # Check SSH keys (if purge was requested)
  if [[ ${PURGE_DATA} == true && -n ${TARGET_USER} ]]; then
    local -r key_file="/home/${TARGET_USER}/.ssh/id_ed25519_github"
    if [[ -f ${key_file} ]]; then
      log_error "SSH key still present: ${key_file}"
      ((issues++))
    else
      log_success "SSH key removed"
    fi
  fi

  if ((issues > 0)); then
    log_warn "Removal completed with ${issues} issue(s)"
    return 1
  fi

  return 0
}

print_removal_summary() {
  printf '\n%b===============================================================%b\n' "${COLORS[bold]}" "${COLORS[reset]}" | tee -a "${LOG_FILE}"
  printf '%b                    REMOVAL COMPLETE%b\n' "${COLORS[bold]}" "${COLORS[reset]}" | tee -a "${LOG_FILE}"
  printf '%b===============================================================%b\n' "${COLORS[bold]}" "${COLORS[reset]}" | tee -a "${LOG_FILE}"

  [[ ${DRY_RUN} == true ]] && log_info "Mode: DRY-RUN (no changes made)"

  log_info ""
  log_info "Package removed:    gh"
  log_info "Repository removed: ${GH_SOURCES_FILE}"
  log_info "GPG key removed:    ${GH_GPG_KEY}"

  if [[ ${PURGE_DATA} == true && -n ${TARGET_USER} ]]; then
    log_info "SSH keys removed:   /home/${TARGET_USER}/.ssh/id_ed25519_github*"
  else
    log_info "SSH keys preserved: /home/${TARGET_USER}/.ssh/id_ed25519_github*"
    log_warn "To remove SSH keys: sudo rm /home/${TARGET_USER}/.ssh/id_ed25519_github*"
  fi

  log_info "Log file:           ${LOG_FILE}"
  log_info ""
}

main_remove() {
  mkdir -p "${LOG_FILE%/*}"
  : >"${LOG_FILE}"
  chmod 644 "${LOG_FILE}"

  log_info "==============================================================="
  log_info "  GitHub CLI Remover v${SCRIPT_VERSION}"
  log_info "  Bash ${BASH_VERSION} | Started: $(printf '%(%F %T)T' "${EPOCHSECONDS}")"
  log_info "==============================================================="

  [[ ${DRY_RUN} == true ]] && log_warn "DRY-RUN MODE: No changes will be made"
  [[ ${PURGE_DATA} == true ]] && log_warn "PURGE MODE: SSH keys will be deleted"
  [[ ${FORCE_REMOVE} == true ]] && log_warn "FORCE MODE: Confirmations bypassed"

  setup_signal_handlers

  # Freeze configuration to prevent modification
  readonly TARGET_USER REMOVE_MODE PURGE_DATA FORCE_REMOVE
  readonly DRY_RUN VERBOSE SYSLOG

  acquire_lock

  # Validation
  check_root
  validate_required_commands

  local has_installation=false
  # shellcheck disable=SC2310  # Intentional: capture result in variable
  check_gh_installation && has_installation=true

  if [[ ${has_installation} != true ]]; then
    log_info "No GitHub CLI installation found. Nothing to remove."
    return 0
  fi

  # Confirmation prompt
  if [[ ${DRY_RUN} != true ]]; then
    printf '\n'
    log_warn "This will remove GitHub CLI and related components."
    if [[ ${PURGE_DATA} == true ]]; then
      log_warn "SSH keys will be PERMANENTLY DELETED!"
    else
      log_info "SSH keys in /home/${TARGET_USER}/.ssh will be preserved."
    fi
    printf '\n'

    local confirmed=false
    # shellcheck disable=SC2310  # Intentional: capture result in variable
    confirm_action "Proceed with GitHub CLI removal?" && confirmed=true
    if [[ ${confirmed} != true ]]; then
      log_info "Removal cancelled by user."
      exit 0
    fi
  fi

  # Execute removal steps
  remove_github_cli
  remove_gh_repository
  remove_ssh_config

  # Verify
  # shellcheck disable=SC2310  # Intentional: allow verification to fail gracefully
  verify_removal || true
  print_removal_summary

  log_success "Removal completed successfully!"
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
  # shellcheck disable=SC2312  # Intentional: fallback to 'installed' if version check fails
  log_info "GitHub CLI:    $(gh --version 2>/dev/null | head -1 || echo 'installed')"
  log_info "Target user:   ${TARGET_USER}"
  log_info "SSH key:       /home/${TARGET_USER}/.ssh/id_ed25519_github"
  log_info "Log file:      ${LOG_FILE}"
  log_info ""

  log_warn "NEXT STEPS:"
  log_warn "  1. Test: gh auth status"
  log_warn "  2. Test: ssh -T git@github.com"
  log_warn "  3. Clone: git clone git@github.com:username/repo.git"
  log_info ""
}

#-------------------------------------------------------------------------------
# Help
#-------------------------------------------------------------------------------
show_help() {
  cat <<EOF
${COLORS[bold]}${SCRIPT_NAME}${COLORS[reset]} v${SCRIPT_VERSION} - GitHub CLI installer with Git/SSH configuration

${COLORS[bold]}USAGE:${COLORS[reset]}
    sudo ${SCRIPT_NAME} --user USERNAME [OPTIONS]
    sudo ${SCRIPT_NAME} --remove [OPTIONS]

${COLORS[bold]}INSTALLATION OPTIONS:${COLORS[reset]}
    --user USERNAME        Target user for authentication (required)
    --skip-ssh             Skip SSH key generation and upload
    --skip-git-config      Skip Git identity configuration
    --ssh-key-comment STR  Custom comment for SSH key

${COLORS[bold]}REMOVAL OPTIONS:${COLORS[reset]}
    --remove               Remove GitHub CLI and repository configuration
    --purge                Also remove SSH keys created by this script
    --force, -f            Skip confirmation prompts

${COLORS[bold]}GENERAL OPTIONS:${COLORS[reset]}
    --dry-run              Preview without making changes
    --verbose, -v          Enable verbose output
    --syslog               Also log to syslog (for enterprise environments)
    --help, -h             Show this help

${COLORS[bold]}WHAT THIS SCRIPT DOES:${COLORS[reset]}
    1. Installs GitHub CLI from official APT repository (with GPG verification)
    2. Authenticates via browser-based OAuth
    3. Configures Git identity from GitHub profile
    4. Generates Ed25519 SSH key (no passphrase)
    5. Uploads SSH key to GitHub account
    6. Configures SSH for GitHub.com

${COLORS[bold]}EXAMPLES:${COLORS[reset]}
    # Full setup
    sudo ${SCRIPT_NAME} --user john

    # Skip SSH key generation
    sudo ${SCRIPT_NAME} --user john --skip-ssh

    # Preview what would happen
    sudo ${SCRIPT_NAME} --user john --dry-run

    # Remove (keep SSH keys)
    sudo ${SCRIPT_NAME} --remove

    # Remove completely
    sudo ${SCRIPT_NAME} --remove --purge --force

${COLORS[bold]}REQUIREMENTS:${COLORS[reset]}
    - Bash 5.2+
    - Root privileges
    - Interactive terminal (for OAuth browser flow)
    - Web browser accessible from WSL2

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
        validate_username "${2}"
        TARGET_USER="${2}"
        shift 2
        ;;
      --user=*)
        TARGET_USER="${1#*=}"
        validate_username "${TARGET_USER}"
        shift
        ;;
      --skip-ssh)
        SKIP_SSH=true
        shift
        ;;
      --skip-git-config)
        SKIP_GIT_CONFIG=true
        shift
        ;;
      --ssh-key-comment)
        [[ -n ${2:-} ]] || die "--ssh-key-comment requires VALUE" "${EXIT_INVALID_ARGS}"
        SSH_KEY_COMMENT="${2}"
        shift 2
        ;;
      --ssh-key-comment=*)
        SSH_KEY_COMMENT="${1#*=}"
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
  if [[ ${REMOVE_MODE} != true && -z ${TARGET_USER} ]]; then
    die "--user USERNAME is required for installation" "${EXIT_INVALID_ARGS}"
  fi

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
  log_info "  GitHub CLI Installer v${SCRIPT_VERSION}"
  log_info "  Bash ${BASH_VERSION} | Started: $(printf '%(%F %T)T' "${EPOCHSECONDS}")"
  log_info "==============================================================="

  [[ ${DRY_RUN} == true ]] && log_warn "DRY-RUN MODE: No changes will be made"

  setup_signal_handlers

  # Freeze configuration to prevent modification
  readonly TARGET_USER SKIP_SSH SKIP_GIT_CONFIG SSH_KEY_COMMENT
  readonly DRY_RUN VERBOSE SYSLOG

  acquire_lock

  # Validation
  check_root
  validate_required_commands
  check_wsl2
  detect_architecture
  validate_user
  check_network

  # Installation
  setup_gh_repository
  install_github_cli
  authenticate_github
  configure_git_identity
  generate_ssh_key
  configure_ssh_for_github

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
