#!/usr/bin/env bash
# SPDX-License-Identifier: NCSA
#===============================================================================
# install-docker-wsl2.sh - Docker Engine installer/remover for WSL2
#
# DESCRIPTION:
#   Script to install or remove Docker Engine on WSL2 systems.
#   Supports Debian and Debian-based distributions.
#   Non-interactive and idempotent.
#
# REQUIREMENTS:
#   Bash 5.2+
#   Debian 13 Trixie in WSL2
#
# USAGE:
#   curl -fsSL https://example.com/install-docker-wsl2.sh | sudo bash
#   sudo ./install-docker-wsl2.sh
#   sudo ./install-docker-wsl2.sh --user myuser --verbose
#   sudo ./install-docker-wsl2.sh --remove
#   sudo ./install-docker-wsl2.sh --remove --purge --force
#
# INSTALLATION OPTIONS:
#   --user USERNAME    Add specified user to docker group (default: $SUDO_USER)
#   --skip-iptables    Skip iptables-legacy configuration
#   --version VERSION  Install specific Docker version
#
# REMOVAL OPTIONS:
#   --remove           Remove Docker Engine and repository configuration
#   --purge            Also remove Docker data (images, containers, volumes)
#   --force, -f        Skip confirmation prompts
#   --keep-user-group  Keep user in docker group during removal
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
# Strict Mode & Safety Settings (Bash 5.2+)
#-------------------------------------------------------------------------------
set -o errexit             # Exit on any command failure
set -o errtrace            # ERR trap inherited by functions/subshells
set -o nounset             # Exit on undefined variable
set -o pipefail            # Catch errors in pipelines
shopt -s extglob           # Extended pattern matching
shopt -s globskipdots      # Never match . or .. in globs (Bash 5.2+)
shopt -s inherit_errexit   # Command substitutions inherit errexit (Bash 4.4+)
shopt -s assoc_expand_once # Prevent double array subscript evaluation (Bash 5.0+)

# Enable debug tracing if TRACE=1
[[ ${TRACE:-0} == 1 ]] && set -o xtrace

# Command-level tracing (set via --trace-commands)
declare TRACE_COMMANDS=false

#-------------------------------------------------------------------------------
# Constants
#-------------------------------------------------------------------------------
declare -r SCRIPT_NAME="${0##*/}"
declare -r SCRIPT_VERSION="2.1.0"
declare -r LOG_FILE="/var/log/docker-wsl2-install.log"
declare -r LOCK_FILE="/var/lock/docker-wsl2-install.lock"

# Docker repository configuration
declare -r DOCKER_GPG_URL="https://download.docker.com/linux"
declare -r DOCKER_REPO_URL="https://download.docker.com/linux"

# Docker GPG key fingerprint for verification
declare -r DOCKER_GPG_FINGERPRINT="9DC858229FC7DD38854AE2D88D81803C0EBFCD88"

# Docker GPG key SHA256 checksum (defense-in-depth verification)
# NOTE: This is secondary to fingerprint verification. Update when Docker rotates keys:
#   curl -fsSL https://download.docker.com/linux/debian/gpg | sha256sum
# Then verify the fingerprint matches DOCKER_GPG_FINGERPRINT before updating.
declare -r DOCKER_GPG_SHA256="1500c1f56fa9e26b9b8f42452a553675796ade0807cdce11975eb98170b3a570"

# Allowed domains for downloads (security allowlist)
declare -ra ALLOWED_DOWNLOAD_DOMAINS=(download.docker.com)

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
declare -ri EXIT_UNSUPPORTED_DISTRO=6
declare -ri EXIT_NETWORK_ERROR=7
declare -ri EXIT_DISK_SPACE=8
declare -ri EXIT_INSTALL_FAILED=9
# shellcheck disable=SC2034  # EXIT_USER_CANCELLED defined for completeness/documentation
declare -ri EXIT_USER_CANCELLED=10

# Required commands for script execution
declare -ra REQUIRED_COMMANDS=(
  curl apt-get dpkg-query getent id stat mkdir rm mv cp chmod
  gpg awk grep sed tee sleep flock pgrep uname sha256sum cut mktemp
)

# Packages to install
declare -ra DOCKER_PACKAGES=(
  docker-ce
  docker-ce-cli
  containerd.io
  docker-buildx-plugin
  docker-compose-plugin
)

declare -ra PREREQUISITES=(
  ca-certificates
  curl
  gnupg
  lsb-release
)

declare -ra CONFLICTING_PACKAGES=(
  docker.io
  docker-doc
  docker-compose
  docker-compose-v2
  podman-docker
  containerd
  runc
)

# Fallback codenames for forward compatibility
declare -rA FALLBACK_CODENAMES=(
  [debian]="trixie bookworm bullseye"
)

# Files/directories managed by this installer (for removal)
declare -r DOCKER_GPG_KEY="/etc/apt/keyrings/docker.asc"
declare -r DOCKER_SOURCES_FILE="/etc/apt/sources.list.d/docker.sources"
declare -r DOCKER_DATA_DIR="/var/lib/docker"
declare -r CONTAINERD_DATA_DIR="/var/lib/containerd"

#-------------------------------------------------------------------------------
# Global State Variables
#-------------------------------------------------------------------------------
declare DOCKER_USER="${SUDO_USER:-}"
declare SKIP_IPTABLES=false
declare DRY_RUN=false
declare VERBOSE=false
declare DOCKER_VERSION=""
declare SYSLOG=false

# Removal mode state
declare REMOVE_MODE=false
declare PURGE_DATA=false
declare FORCE_REMOVE=false
declare REMOVE_USER_FROM_GROUP=true

declare DISTRO_ID=""
declare DISTRO_CODENAME=""
declare DISTRO_BASE=""
declare ARCH=""
declare EFFECTIVE_CODENAME=""

# Cleanup state tracking (for rollback)
declare -i CLEANUP_IN_PROGRESS=0
declare -i SIGNAL_RECEIVED=0
declare RECEIVED_SIGNAL=""
declare -a CLEANUP_ACTIONS=()
declare -A CREATED_FILES=()
declare -A MODIFIED_FILES=()

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

# Prompt for confirmation (respects --force and --dry-run)
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

# Validate URL format and domain allowlist
validate_url() {
  local -r url="$1"
  local -r pattern='^https://[a-zA-Z0-9][-a-zA-Z0-9]*(\.[a-zA-Z0-9][-a-zA-Z0-9]*)+(/[-a-zA-Z0-9_.~%/]*)?$'

  # Validate URL format
  if [[ ! ${url} =~ ${pattern} ]]; then
    die "Invalid URL format: ${url}" "${EXIT_GENERAL_ERROR:-1}"
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
    die "URL domain not in allowlist: ${domain}" "${EXIT_GENERAL_ERROR:-1}"
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

# Content fetch (returns content to stdout)
secure_fetch() {
  local -r url="$1"
  local -ri max_size="${2:-10485760}" # 10MB default

  # Validate URL before fetching
  validate_url "${url}"

  curl -fsSL \
    --proto '=https' \
    --tlsv1.2 \
    --connect-timeout 10 \
    --max-time 60 \
    --retry 3 \
    --retry-connrefused \
    --max-filesize "${max_size}" \
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

# Check if user is in group
user_in_group() {
  local -r user="$1" group="$2"
  id -nG "${user}" 2>/dev/null | tr ' ' '\n' | grep -qx "${group}"
}

# Verify GPG key fingerprint matches Docker's official key
verify_gpg_fingerprint() {
  local -r keyfile="$1"
  local actual_fp

  # Extract fingerprint using gpg
  actual_fp=$(gpg --show-keys --with-fingerprint --with-colons "${keyfile}" 2>/dev/null \
    | awk -F: '/^fpr:/{gsub(/ /,"",$10); print $10; exit}')
  local -r actual_fp

  if [[ -z ${actual_fp} ]]; then
    die "Failed to extract fingerprint from GPG key" "${EXIT_GENERAL_ERROR}"
  fi

  if [[ ${actual_fp^^} != "${DOCKER_GPG_FINGERPRINT^^}" ]]; then
    log_error "GPG key fingerprint mismatch!"
    log_error "Expected: ${DOCKER_GPG_FINGERPRINT}"
    log_error "Got:      ${actual_fp}"
    die "Security verification failed - GPG key may be compromised" "${EXIT_GENERAL_ERROR}"
  fi

  log_success "GPG key fingerprint verified"
}

# Verify GPG key SHA256 checksum
verify_gpg_checksum() {
  local -r keyfile="$1"
  local actual_sha256

  actual_sha256=$(sha256sum "${keyfile}" | cut -d' ' -f1)
  local -r actual_sha256

  if [[ -z ${actual_sha256} ]]; then
    log_warn "Could not compute SHA256 checksum of GPG key"
    return 0
  fi

  if [[ ${actual_sha256} != "${DOCKER_GPG_SHA256}" ]]; then
    log_warn "GPG key SHA256 mismatch (key may have been legitimately updated)"
    log_warn "Expected: ${DOCKER_GPG_SHA256}"
    log_warn "Got:      ${actual_sha256}"
    # Don't fail - fingerprint verification is authoritative
    return 0
  fi

  log_debug "GPG key SHA256 checksum verified"
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

# Atomic file write
atomic_write() {
  local -r target="$1"
  local -r content="$2"
  local temp

  # Create temp file securely with mktemp (atomic creation with O_EXCL)
  temp=$(mktemp "${target}.tmp.XXXXXX") || die "Failed to create temp file for ${target}" "${EXIT_GENERAL_ERROR}"

  # Clean up temp file on function exit
  trap 'rm -f "${temp}" 2>/dev/null; trap - RETURN' RETURN

  # Write to temp file first
  printf '%s\n' "${content}" >"${temp}"

  # Atomic rename
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
    log_debug "  DISTRO_ID=${DISTRO_ID:-unset}"
    log_debug "  DISTRO_BASE=${DISTRO_BASE:-unset}"
    log_debug "  ARCH=${ARCH:-unset}"
    log_debug "  DOCKER_USER=${DOCKER_USER:-unset}"
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
  # These are not widel available. Attempt to trap but ignore failure
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
# Step Markers (Idempotency Support)
#-------------------------------------------------------------------------------
declare -r STEP_MARKER_DIR="/var/lib/docker-wsl2-install"

# Check if a step was previously completed
step_completed() {
  local -r step_name="$1"
  [[ -f "${STEP_MARKER_DIR}/.step_${step_name}" ]]
}

# Mark a step as completed
mark_step_complete() {
  local -r step_name="$1"
  if [[ ${DRY_RUN} != true ]]; then
    mkdir -p "${STEP_MARKER_DIR}"
    printf '%s\n' "$(printf '%(%FT%T)T' "${EPOCHSECONDS}")" >"${STEP_MARKER_DIR}/.step_${step_name}"
  fi
  log_debug "Step '${step_name}' marked complete"
}

# Clear all step markers (for fresh install)
clear_step_markers() {
  if [[ -d ${STEP_MARKER_DIR} ]]; then
    rm -f "${STEP_MARKER_DIR}"/.step_* 2>/dev/null || true
    log_debug "Step markers cleared"
  fi
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

detect_distribution() {
  log_info "Detecting Linux distribution..."

  [[ -f /etc/os-release ]] || die "Cannot detect distribution: /etc/os-release not found" "${EXIT_UNSUPPORTED_DISTRO}"

  # shellcheck source=/dev/null
  source /etc/os-release

  DISTRO_ID="${ID:-}"
  DISTRO_CODENAME="${VERSION_CODENAME:-}"

  log_debug "Detected: ID=${DISTRO_ID}, Codename=${DISTRO_CODENAME}"

  # Validate distribution family
  case "${DISTRO_ID@L}" in
    debian)
      DISTRO_BASE="debian"
      ;;
    *)
      # Check derivatives via ID_LIKE
      local -r id_like="${ID_LIKE:-}"
      if [[ ${id_like} == *debian* ]]; then
        DISTRO_BASE="debian"
        log_warn "Detected ${DISTRO_ID@Q} (Debian-derivative)"
      else
        die "Unsupported distribution: ${DISTRO_ID}. Requires Debian-based system." "${EXIT_UNSUPPORTED_DISTRO}"
      fi
      ;;
  esac

  [[ -n ${DISTRO_CODENAME} ]] || die "Cannot detect codename (VERSION_CODENAME not set)" "${EXIT_UNSUPPORTED_DISTRO}"

  log_success "Detected: ${DISTRO_ID} ${DISTRO_CODENAME} (${DISTRO_BASE}-based)"
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
    s390x) ARCH="s390x" ;;
    ppc64le) ARCH="ppc64le" ;;
    *) die "Unsupported architecture: ${machine}" "${EXIT_UNSUPPORTED_DISTRO}" ;;
  esac

  log_success "Architecture: ${ARCH}"
}

validate_user() {
  log_info "Validating target user..."

  [[ -z ${DOCKER_USER} ]] && DOCKER_USER="${SUDO_USER:-${USER:-}}"

  if [[ -z ${DOCKER_USER} || ${DOCKER_USER} == root ]]; then
    log_warn "No non-root user specified. Docker group config skipped."
    log_warn "Run later: sudo usermod -aG docker YOUR_USERNAME"
    DOCKER_USER=""
    return 0
  fi

  id "${DOCKER_USER}" &>/dev/null || die "User '${DOCKER_USER}' does not exist" "${EXIT_INVALID_ARGS}"

  log_success "Target user: ${DOCKER_USER}"
}

#-------------------------------------------------------------------------------
# Network Connectivity Check
#-------------------------------------------------------------------------------
check_network() {
  log_info "Checking network connectivity..."

  local -ra test_endpoints=(
    "https://download.docker.com"
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

check_disk_space() {
  log_info "Checking available disk space..."
  local -ri required_mb=500
  local -i available_mb
  available_mb=$(df -BM /var 2>/dev/null | awk 'NR==2 {print int($4)}') || available_mb=0

  if ((available_mb < required_mb)); then
    die "Insufficient disk space: ${available_mb}MB available, ${required_mb}MB required" "${EXIT_DISK_SPACE}"
  fi
  log_success "Disk space OK: ${available_mb}MB available"
}

check_dns() {
  log_info "Checking DNS resolution..."
  local -r test_host="download.docker.com"
  if ! getent hosts "${test_host}" &>/dev/null; then
    die "DNS resolution failed for ${test_host}. Check your DNS settings." "${EXIT_NETWORK_ERROR}"
  fi
  log_success "DNS resolution OK"
}

check_file_descriptors() {
  log_info "Checking file descriptor limits..."
  local -ri required_fds=256
  local -i max_fds
  max_fds=$(ulimit -n 2>/dev/null) || max_fds=0

  if ((max_fds > 0 && max_fds < required_fds)); then
    log_warn "Low file descriptor limit: ${max_fds} (recommended: ${required_fds}+)"
  else
    log_debug "File descriptor limit: ${max_fds}"
  fi
}

#-------------------------------------------------------------------------------
# Repository Functions
#-------------------------------------------------------------------------------

# Parses HTML directory listing from https://download.docker.com/linux/{distro}/dists/
# Returns codenames on stdout, one per line
fetch_available_codenames() {
  local -r dists_url="${DOCKER_REPO_URL}/${DISTRO_BASE}/dists/"
  local html_content
  local -a codenames

  # Fetch directory listing with TLS hardening (no need for validate_url - internal function)
  html_content=$(curl -fsSL \
    --proto '=https' \
    --tlsv1.2 \
    --connect-timeout 10 \
    --max-time 30 \
    --max-filesize 1048576 \
    "${dists_url}" 2>/dev/null) || return 1

  # shellcheck disable=SC2312  # Pipeline return values intentionally not checked
  mapfile -t codenames < <(
    printf '%s' "${html_content}" \
      | grep -oP 'href="\K[a-z]+(?=/")' \
      | grep -v -E '^(\.|\.\.)$' \
      | sort -u
  )

  if ((${#codenames[@]} == 0)); then
    return 1
  fi

  # Output codenames
  printf '%s\n' "${codenames[@]}"
}

# Check if a codename exists in Docker repo
codename_exists_in_repo() {
  local -r codename="$1"
  local -r test_url="${DOCKER_REPO_URL}/${DISTRO_BASE}/dists/${codename}/Release"

  curl -fsSL \
    --proto '=https' \
    --tlsv1.2 \
    --head \
    --connect-timeout 5 \
    --max-time 10 \
    "${test_url}" &>/dev/null
}

# Verify Docker repo has packages for codename, find fallback if needed
resolve_codename() {
  # shellcheck disable=SC2310  # Intentional: capture result in variable
  if codename_exists_in_repo "${DISTRO_CODENAME}"; then
    log_debug "Docker repo has packages for ${DISTRO_CODENAME}"
    EFFECTIVE_CODENAME="${DISTRO_CODENAME}"
    return 0
  fi

  log_warn "Docker repo missing packages for '${DISTRO_CODENAME}'"
  log_info "Finding compatible fallback..."

  local -a available_codenames
  # shellcheck disable=SC2310,SC2312  # Intentional: allow dynamic fetch to fail gracefully
  if mapfile -t available_codenames < <(fetch_available_codenames 2>/dev/null) && ((${#available_codenames[@]} > 0)); then
    log_debug "Found ${#available_codenames[@]} available codenames dynamically"
    for codename in "${available_codenames[@]}"; do
      # shellcheck disable=SC2310  # Intentional: capture result in variable
      if codename_exists_in_repo "${codename}"; then
        log_warn "Using dynamically resolved fallback: ${codename}"
        EFFECTIVE_CODENAME="${codename}"
        return 0
      fi
    done
  fi

  # Fall back to hardcoded codenames
  log_debug "Falling back to hardcoded codenames"
  local -a fallbacks
  read -ra fallbacks <<<"${FALLBACK_CODENAMES[${DISTRO_BASE}]}"

  for fallback in "${fallbacks[@]}"; do
    # shellcheck disable=SC2310  # Intentional: capture result in variable
    if codename_exists_in_repo "${fallback}"; then
      log_warn "Using fallback: ${fallback}"
      EFFECTIVE_CODENAME="${fallback}"
      return 0
    fi
  done

  log_warn "No fallback found, trying ${DISTRO_CODENAME} anyway"
  EFFECTIVE_CODENAME="${DISTRO_CODENAME}"
}

#-------------------------------------------------------------------------------
# Removal Functions
#-------------------------------------------------------------------------------

# Check what Docker components are currently installed
# Returns: 0 if Docker components found, 1 if nothing installed
check_docker_installation() {
  log_info "Checking current Docker installation..."

  local -i found=0

  # Check packages
  for pkg in "${DOCKER_PACKAGES[@]}"; do
    local pkg_installed=false
    # shellcheck disable=SC2310  # Intentional: capture result in variable
    is_installed "${pkg}" && pkg_installed=true
    if [[ ${pkg_installed} == true ]]; then
      log_info "  Package installed: ${pkg}"
      ((found++))
    fi
  done

  # Check GPG key
  if [[ -f ${DOCKER_GPG_KEY} ]]; then
    log_info "  GPG key present: ${DOCKER_GPG_KEY}"
    ((found++))
  fi

  # Check sources file
  if [[ -f ${DOCKER_SOURCES_FILE} ]]; then
    log_info "  Repository configured: ${DOCKER_SOURCES_FILE}"
    ((found++))
  fi

  # Check data directories
  if [[ -d ${DOCKER_DATA_DIR} ]]; then
    local size
    size=$(du -sh "${DOCKER_DATA_DIR}" 2>/dev/null | cut -f1) || size="unknown"
    log_info "  Docker data: ${DOCKER_DATA_DIR} (${size})"
    ((found++))
  fi

  if [[ -d ${CONTAINERD_DATA_DIR} ]]; then
    local size
    size=$(du -sh "${CONTAINERD_DATA_DIR}" 2>/dev/null | cut -f1) || size="unknown"
    log_info "  Containerd data: ${CONTAINERD_DATA_DIR} (${size})"
    ((found++))
  fi

  # Check user in docker group
  if [[ -n ${DOCKER_USER} ]]; then
    local in_group=false
    # shellcheck disable=SC2310  # Intentional: capture result in variable
    user_in_group "${DOCKER_USER}" docker && in_group=true
    if [[ ${in_group} == true ]]; then
      log_info "  User '${DOCKER_USER}' in docker group"
      ((found++))
    fi
  fi

  if ((found == 0)); then
    log_warn "No Docker installation detected"
    return 1
  fi

  log_success "Found ${found} Docker component(s)"
  return 0
}

# Stop Docker services gracefully
stop_docker_services() {
  log_step "1/5" "Stopping Docker services"

  # Check if systemd is running
  if ! pidof systemd &>/dev/null; then
    log_info "systemd not running - skipping service stop"
    return 0
  fi

  # Stop docker service
  if systemctl is-active --quiet docker.service 2>/dev/null; then
    log_info "Stopping docker.service..."
    # shellcheck disable=SC2310  # Intentional: allow failures for service operations
    execute systemctl stop docker.service 2>/dev/null || true
    # shellcheck disable=SC2310  # Intentional: allow failures for service operations
    execute systemctl disable docker.service 2>/dev/null || true
    log_success "docker.service stopped"
  else
    log_info "docker.service not running"
  fi

  # Stop docker.socket if exists
  if systemctl is-active --quiet docker.socket 2>/dev/null; then
    log_info "Stopping docker.socket..."
    # shellcheck disable=SC2310  # Intentional: allow failures for service operations
    execute systemctl stop docker.socket 2>/dev/null || true
    # shellcheck disable=SC2310  # Intentional: allow failures for service operations
    execute systemctl disable docker.socket 2>/dev/null || true
  fi

  # Stop containerd
  if systemctl is-active --quiet containerd.service 2>/dev/null; then
    log_info "Stopping containerd.service..."
    # shellcheck disable=SC2310  # Intentional: allow failures for service operations
    execute systemctl stop containerd.service 2>/dev/null || true
    # shellcheck disable=SC2310  # Intentional: allow failures for service operations
    execute systemctl disable containerd.service 2>/dev/null || true
    log_success "containerd.service stopped"
  else
    log_info "containerd.service not running"
  fi

  # Kill any lingering docker processes
  if pgrep -x dockerd &>/dev/null; then
    log_warn "dockerd still running, sending SIGTERM..."
    # shellcheck disable=SC2310  # Intentional: allow failures for process kill
    execute pkill -TERM dockerd 2>/dev/null || true
    sleep 2
    if pgrep -x dockerd &>/dev/null; then
      log_warn "dockerd still running, sending SIGKILL..."
      # shellcheck disable=SC2310  # Intentional: allow failures for process kill
      execute pkill -KILL dockerd 2>/dev/null || true
    fi
  fi

  log_success "Docker services stopped"
}

# Remove Docker packages
remove_docker_packages() {
  log_step "2/5" "Removing Docker packages"

  local -a to_remove=()

  # Check which packages are installed
  for pkg in "${DOCKER_PACKAGES[@]}"; do
    local pkg_installed=false
    # shellcheck disable=SC2310  # Intentional: capture result in variable
    is_installed "${pkg}" && pkg_installed=true
    if [[ ${pkg_installed} == true ]]; then
      to_remove+=("${pkg}")
    fi
  done

  if ((${#to_remove[@]} == 0)); then
    log_info "No Docker packages installed"
    return 0
  fi

  log_info "Removing packages: ${to_remove[*]}"

  export DEBIAN_FRONTEND=noninteractive
  export DEBIAN_PRIORITY=critical

  if [[ ${DRY_RUN} == true ]]; then
    log_info "[DRY-RUN] Would remove: ${to_remove[*]}"
  else
    # Use --purge to remove config files as well
    apt-get remove -y --purge "${to_remove[@]}" || {
      log_warn "Some packages may not have been fully removed"
    }

    # Clean up dependencies
    apt-get autoremove -y || true
  fi

  log_success "Docker packages removed"
}

# Remove Docker repository and GPG key
remove_docker_repository() {
  log_step "3/5" "Removing Docker repository configuration"

  # Remove GPG key
  if [[ -f ${DOCKER_GPG_KEY} ]]; then
    log_info "Removing GPG key: ${DOCKER_GPG_KEY}"
    execute rm -f "${DOCKER_GPG_KEY}"
    log_success "GPG key removed"
  else
    log_info "GPG key not present"
  fi

  # Remove sources file
  if [[ -f ${DOCKER_SOURCES_FILE} ]]; then
    log_info "Removing repository: ${DOCKER_SOURCES_FILE}"
    execute rm -f "${DOCKER_SOURCES_FILE}"
    log_success "Repository configuration removed"
  else
    log_info "Repository configuration not present"
  fi

  # Also check for legacy sources.list entry (pre-DEB822)
  local -r legacy_list="/etc/apt/sources.list.d/docker.list"
  if [[ -f ${legacy_list} ]]; then
    log_info "Removing legacy repository: ${legacy_list}"
    execute rm -f "${legacy_list}"
  fi

  # Update package cache
  log_info "Updating package index..."
  # shellcheck disable=SC2310  # Intentional: allow apt-get update to fail
  execute apt-get update -qq 2>/dev/null || true

  log_success "Docker repository removed"
}

# Remove user from docker group
remove_user_from_docker_group() {
  log_step "4/5" "Removing user from docker group"

  if [[ -z ${DOCKER_USER} ]]; then
    log_info "No user specified - skipping"
    return 0
  fi

  if [[ ${REMOVE_USER_FROM_GROUP} != true ]]; then
    log_info "User group removal disabled (--keep-user-group)"
    return 0
  fi

  # Check if docker group exists
  if ! getent group docker &>/dev/null; then
    log_info "Docker group doesn't exist"
    return 0
  fi

  local in_group=false
  # shellcheck disable=SC2310  # Intentional: capture result in variable
  user_in_group "${DOCKER_USER}" docker && in_group=true

  if [[ ${in_group} != true ]]; then
    log_info "User '${DOCKER_USER}' not in docker group"
    return 0
  fi

  log_info "Removing '${DOCKER_USER}' from docker group..."

  if [[ ${DRY_RUN} == true ]]; then
    log_info "[DRY-RUN] Would remove user from docker group"
  else
    # Try gpasswd first, fallback to deluser
    if gpasswd -d "${DOCKER_USER}" docker 2>/dev/null; then
      log_success "User '${DOCKER_USER}' removed from docker group"
    else
      local has_deluser=false
      # shellcheck disable=SC2310  # Intentional: capture result in variable
      has_command deluser && has_deluser=true
      if [[ ${has_deluser} == true ]]; then
        # shellcheck disable=SC2310  # Intentional: allow deluser to fail
        execute deluser "${DOCKER_USER}" docker 2>/dev/null || true
        log_success "User '${DOCKER_USER}' removed from docker group"
      else
        log_warn "Could not remove user from docker group"
      fi
    fi
  fi
}

# Purge Docker data directories (with --purge)
purge_docker_data() {
  log_step "5/5" "Purging Docker data"

  if [[ ${PURGE_DATA} != true ]]; then
    log_info "Data preservation mode (use --purge to remove data)"
    if [[ -d ${DOCKER_DATA_DIR} ]]; then
      local size
      size=$(du -sh "${DOCKER_DATA_DIR}" 2>/dev/null | cut -f1) || size="unknown"
      log_warn "Preserving: ${DOCKER_DATA_DIR} (${size})"
    fi
    if [[ -d ${CONTAINERD_DATA_DIR} ]]; then
      local size
      size=$(du -sh "${CONTAINERD_DATA_DIR}" 2>/dev/null | cut -f1) || size="unknown"
      log_warn "Preserving: ${CONTAINERD_DATA_DIR} (${size})"
    fi
    return 0
  fi

  # Double-confirm for data destruction
  if [[ ${DRY_RUN} != true ]]; then
    log_warn "WARNING: This will permanently delete all Docker data!"
    log_warn "  - All containers"
    log_warn "  - All images"
    log_warn "  - All volumes"
    log_warn "  - All networks"
    log_warn "  - All build cache"
    printf '\n'

    local confirmed=false
    # shellcheck disable=SC2310  # Intentional: capture result in variable
    confirm_action "Type 'yes' to confirm data deletion" && confirmed=true
    if [[ ${confirmed} != true ]]; then
      log_info "Data purge cancelled by user"
      return 0
    fi
  fi

  # Remove Docker data directory
  if [[ -d ${DOCKER_DATA_DIR} ]]; then
    log_info "Removing: ${DOCKER_DATA_DIR}"
    execute rm -rf "${DOCKER_DATA_DIR}"
    log_success "Docker data directory removed"
  fi

  # Remove containerd data directory
  if [[ -d ${CONTAINERD_DATA_DIR} ]]; then
    log_info "Removing: ${CONTAINERD_DATA_DIR}"
    execute rm -rf "${CONTAINERD_DATA_DIR}"
    log_success "Containerd data directory removed"
  fi

  # Remove docker group if empty
  if getent group docker &>/dev/null; then
    local member_list
    member_list=$(getent group docker | cut -d: -f4)
    local -r member_list
    if [[ -z ${member_list} ]]; then
      log_info "Removing empty docker group..."
      # shellcheck disable=SC2310  # Intentional: allow groupdel to fail
      execute groupdel docker 2>/dev/null || true
    else
      log_info "Preserving docker group (has members)"
    fi
  fi

  log_success "Docker data purged"
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

  # Check packages removed
  for pkg in "${DOCKER_PACKAGES[@]}"; do
    local pkg_installed=false
    # shellcheck disable=SC2310  # Intentional: capture result in variable
    is_installed "${pkg}" && pkg_installed=true
    if [[ ${pkg_installed} == true ]]; then
      log_error "Package still installed: ${pkg}"
      ((issues++))
    fi
  done

  if ((issues == 0)); then
    log_success "All Docker packages removed"
  fi

  # Check docker command gone
  local has_docker=false
  # shellcheck disable=SC2310  # Intentional: capture result in variable
  has_command docker && has_docker=true
  if [[ ${has_docker} == true ]]; then
    log_warn "docker command still available (may be from another source)"
  else
    log_success "docker command removed"
  fi

  # Check repository removed
  if [[ -f ${DOCKER_GPG_KEY} ]]; then
    log_error "GPG key still present: ${DOCKER_GPG_KEY}"
    ((issues++))
  else
    log_success "GPG key removed"
  fi

  if [[ -f ${DOCKER_SOURCES_FILE} ]]; then
    log_error "Repository still configured: ${DOCKER_SOURCES_FILE}"
    ((issues++))
  else
    log_success "Repository configuration removed"
  fi

  # Check data directories (if purge was requested)
  if [[ ${PURGE_DATA} == true ]]; then
    if [[ -d ${DOCKER_DATA_DIR} ]]; then
      log_error "Docker data still present: ${DOCKER_DATA_DIR}"
      ((issues++))
    else
      log_success "Docker data directory removed"
    fi

    if [[ -d ${CONTAINERD_DATA_DIR} ]]; then
      log_error "Containerd data still present: ${CONTAINERD_DATA_DIR}"
      ((issues++))
    else
      log_success "Containerd data directory removed"
    fi
  else
    # Inform about preserved data
    if [[ -d ${DOCKER_DATA_DIR} ]]; then
      log_info "Docker data preserved: ${DOCKER_DATA_DIR}"
    fi
  fi

  # Check user removed from group
  if [[ -n ${DOCKER_USER} && ${REMOVE_USER_FROM_GROUP} == true ]]; then
    local in_group=false
    # shellcheck disable=SC2310  # Intentional: capture result in variable
    user_in_group "${DOCKER_USER}" docker && in_group=true
    if [[ ${in_group} == true ]]; then
      log_warn "User '${DOCKER_USER}' still in docker group"
    else
      log_success "User '${DOCKER_USER}' removed from docker group"
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
  log_info "Packages removed:   ${DOCKER_PACKAGES[*]}"
  log_info "Repository removed: ${DOCKER_SOURCES_FILE}"
  log_info "GPG key removed:    ${DOCKER_GPG_KEY}"

  if [[ ${PURGE_DATA} == true ]]; then
    log_info "Data purged:        ${DOCKER_DATA_DIR}, ${CONTAINERD_DATA_DIR}"
  else
    log_info "Data preserved:     ${DOCKER_DATA_DIR}"
    log_warn "To remove data: sudo rm -rf ${DOCKER_DATA_DIR} ${CONTAINERD_DATA_DIR}"
  fi

  log_info "Log file:           ${LOG_FILE}"
  log_info ""

  # Items NOT removed (by design)
  log_info "Preserved (by design):"
  log_info "  - Prerequisites (curl, gnupg, etc.) - used by other applications"
  log_info "  - /etc/wsl.conf systemd setting - may be used by other services"
  log_info "  - iptables settings - may affect other applications"
  log_info ""
}

# Main removal orchestrator
main_remove() {
  mkdir -p "${LOG_FILE%/*}"
  : >"${LOG_FILE}"
  chmod 644 "${LOG_FILE}"

  log_info "==============================================================="
  log_info "  Docker Engine WSL2 Remover v${SCRIPT_VERSION}"
  log_info "  Bash ${BASH_VERSION} | Started: $(printf '%(%F %T)T' "${EPOCHSECONDS}")"
  log_info "==============================================================="

  [[ ${DRY_RUN} == true ]] && log_warn "DRY-RUN MODE: No changes will be made"
  [[ ${PURGE_DATA} == true ]] && log_warn "PURGE MODE: Docker data will be deleted"
  [[ ${FORCE_REMOVE} == true ]] && log_warn "FORCE MODE: Confirmations bypassed"

  setup_signal_handlers

  # Freeze configuration to prevent modification
  readonly DOCKER_USER REMOVE_MODE PURGE_DATA FORCE_REMOVE REMOVE_USER_FROM_GROUP
  readonly DRY_RUN VERBOSE SYSLOG

  acquire_lock

  # Validation
  check_root
  validate_required_commands

  # Check what's installed
  local has_installation=false
  # shellcheck disable=SC2310  # Intentional: capture result in variable
  check_docker_installation && has_installation=true

  if [[ ${has_installation} != true ]]; then
    log_info "No Docker installation found. Nothing to remove."
    return 0
  fi

  # Confirmation prompt
  if [[ ${DRY_RUN} != true ]]; then
    printf '\n'
    log_warn "This will remove Docker Engine and related components."
    if [[ ${PURGE_DATA} == true ]]; then
      log_warn "ALL DOCKER DATA WILL BE PERMANENTLY DELETED!"
    else
      log_info "Docker data in ${DOCKER_DATA_DIR} will be preserved."
    fi
    printf '\n'

    local confirmed=false
    # shellcheck disable=SC2310  # Intentional: capture result in variable
    confirm_action "Proceed with Docker removal?" && confirmed=true
    if [[ ${confirmed} != true ]]; then
      log_info "Removal cancelled by user."
      exit 0
    fi
  fi

  # Execute removal steps
  stop_docker_services
  remove_docker_packages
  remove_docker_repository
  remove_user_from_docker_group
  purge_docker_data

  # Verify
  # shellcheck disable=SC2310  # Intentional: allow verification to fail gracefully
  verify_removal || true
  print_removal_summary

  log_success "Removal completed successfully!"
}

#-------------------------------------------------------------------------------
# Installation Functions
#-------------------------------------------------------------------------------
remove_conflicting_packages() {
  log_step "1/7" "Removing conflicting packages"

  local -a to_remove=()

  for pkg in "${CONFLICTING_PACKAGES[@]}"; do
    # shellcheck disable=SC2310  # Intentional: capture result for filtering
    is_installed "${pkg}" && to_remove+=("${pkg}")
  done

  if ((${#to_remove[@]} == 0)); then
    log_success "No conflicting packages found"
    return 0
  fi

  log_info "Removing: ${to_remove[*]}"
  # shellcheck disable=SC2310  # Intentional: allow failures during cleanup
  execute apt-get remove -y --purge "${to_remove[@]}" || true
  # shellcheck disable=SC2310  # Intentional: allow failures during cleanup
  execute apt-get autoremove -y || true

  log_success "Conflicting packages removed"
}

install_prerequisites() {
  log_step "2/7" "Installing prerequisites"

  log_info "Updating package index..."
  execute apt-get update -qq

  log_info "Installing: ${PREREQUISITES[*]}"
  execute apt_install "${PREREQUISITES[@]}"

  log_success "Prerequisites installed"
}

setup_docker_repository() {
  log_step "3/7" "Setting up Docker repository"

  local -r keyring_dir="/etc/apt/keyrings"
  local -r keyring_file="${keyring_dir}/docker.asc"
  local -r sources_file="/etc/apt/sources.list.d/docker.sources"

  [[ -d ${keyring_dir} ]] || execute install -m 0755 -d "${keyring_dir}"

  log_info "Downloading Docker GPG key..."
  local -r gpg_url="${DOCKER_GPG_URL}/${DISTRO_BASE}/gpg"

  if [[ ${DRY_RUN} == true ]]; then
    log_info "[DRY-RUN] Would download: ${gpg_url}"
  else
    retry_with_backoff "${MAX_RETRIES}" "${RETRY_DELAY_BASE}" \
      secure_download "${gpg_url}" "${keyring_file}" 1048576 # 1MB max for GPG key
    chmod a+r "${keyring_file}"
    verify_gpg_fingerprint "${keyring_file}"
    verify_gpg_checksum "${keyring_file}"
    register_created_file "${keyring_file}"
  fi
  # Resolve codename
  [[ ${DRY_RUN} != true ]] && resolve_codename

  # Create sources file (DEB822 format)
  log_info "Configuring repository for ${EFFECTIVE_CODENAME:-${DISTRO_CODENAME}}..."

  local repo_content
  printf -v repo_content 'Types: deb
URIs: %s/%s
Suites: %s
Components: stable
Signed-By: %s
Architectures: %s' \
    "${DOCKER_REPO_URL}" "${DISTRO_BASE}" \
    "${EFFECTIVE_CODENAME:-${DISTRO_CODENAME}}" \
    "${keyring_file}" "${ARCH}"

  if [[ ${DRY_RUN} == true ]]; then
    log_info "[DRY-RUN] Would write to ${sources_file}"
  else
    # Backup existing file if present
    [[ -f ${sources_file} ]] && backup_file "${sources_file}"
    # Use atomic write (write to temp, then rename)
    atomic_write "${sources_file}" "${repo_content}"
  fi

  log_info "Updating package index..."
  execute apt-get update -qq

  log_success "Docker repository configured"
}

install_docker_engine() {
  log_step "4/7" "Installing Docker Engine"

  # Check existing installation
  local has_docker=false
  # shellcheck disable=SC2310  # Intentional: capture result in variable
  has_command docker && has_docker=true
  if [[ ${has_docker} == true ]]; then
    local current_version
    current_version="$(docker --version 2>/dev/null || echo 'unknown')"
    log_info "Docker already installed: ${current_version}"

    if docker info &>/dev/null; then
      log_success "Docker is functional - checking for updates..."
    else
      log_warn "Docker installed but not functional - reinstalling..."
    fi
  fi

  if [[ -n ${DOCKER_VERSION} ]]; then
    log_info "Installing Docker version: ${DOCKER_VERSION}"
    local -a versioned_pkgs=()
    local pkg
    for pkg in "${DOCKER_PACKAGES[@]}"; do
      versioned_pkgs+=("${pkg}=${DOCKER_VERSION}")
    done
    execute apt_install "${versioned_pkgs[@]}"
  else
    log_info "Installing: ${DOCKER_PACKAGES[*]}"
    execute apt_install "${DOCKER_PACKAGES[@]}"
  fi

  if [[ ${DRY_RUN} != true ]]; then
    # shellcheck disable=SC2310  # Intentional: die terminates on failure
    has_command docker || die "Docker installation failed" "${EXIT_INSTALL_FAILED}"
    local docker_ver
    docker_ver="$(docker --version)" || docker_ver="unknown"
    log_success "Docker installed: ${docker_ver}"
  else
    log_success "[DRY-RUN] Docker packages would be installed"
  fi
}

configure_iptables() {
  log_step "5/7" "Configuring iptables"

  if [[ ${SKIP_IPTABLES} == true ]]; then
    log_info "Skipping iptables configuration (--skip-iptables)"
    return 0
  fi

  local has_update_alternatives=false
  # shellcheck disable=SC2310  # Intentional: capture result in variable
  has_command update-alternatives && has_update_alternatives=true
  if [[ ${has_update_alternatives} != true ]]; then
    log_warn "update-alternatives not available"
    return 0
  fi

  # Check current setting
  local current
  current="$(update-alternatives --query iptables 2>/dev/null | awk '/^Value:/{print $2}')" || true

  if [[ ${current} == *iptables-legacy* ]]; then
    log_success "iptables already set to legacy mode"
    return 0
  fi

  # Check if legacy alternative exists
  if ! update-alternatives --list iptables 2>/dev/null | grep -q iptables-legacy; then
    log_warn "iptables-legacy not available"
    return 0
  fi

  log_info "Setting iptables to legacy mode..."
  # shellcheck disable=SC2310  # Intentional: allow failures for optional setting
  execute update-alternatives --set iptables /usr/sbin/iptables-legacy 2>/dev/null || true
  # shellcheck disable=SC2310  # Intentional: allow failures for optional setting
  execute update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy 2>/dev/null || true

  log_success "iptables configured"
}

configure_user_group() {
  log_step "6/7" "Configuring user permissions"

  if [[ -z ${DOCKER_USER} ]]; then
    log_warn "No user specified - skipping"
    return 0
  fi

  # Ensure docker group exists
  getent group docker &>/dev/null || execute groupadd docker

  # Check if already in group
  local already_in_group=false
  # shellcheck disable=SC2310  # Intentional: capture result in variable
  user_in_group "${DOCKER_USER}" docker && already_in_group=true
  if [[ ${already_in_group} == true ]]; then
    log_success "User '${DOCKER_USER}' already in docker group"
    return 0
  fi

  log_info "Adding '${DOCKER_USER}' to docker group..."
  execute usermod -aG docker "${DOCKER_USER}"

  log_success "User added to docker group"
  log_info "Run 'newgrp docker' or log out/in to apply"
}

configure_systemd() {
  log_step "7/7" "Configuring systemd"

  local -r wsl_conf="/etc/wsl.conf"

  # Check if systemd already enabled
  if [[ -f ${wsl_conf} ]] && grep -qE '^\s*systemd\s*=\s*true' "${wsl_conf}" 2>/dev/null; then
    log_success "systemd already enabled"
  else
    log_info "Enabling systemd in WSL..."

    if [[ ${DRY_RUN} == true ]]; then
      log_info "[DRY-RUN] Would update ${wsl_conf}"
    else
      # Backup existing wsl.conf if present
      [[ -f ${wsl_conf} ]] && backup_file "${wsl_conf}"

      if [[ -f ${wsl_conf} ]]; then
        if grep -qE '^\s*\[boot\]' "${wsl_conf}"; then
          if ! grep -qE '^\s*systemd\s*=' "${wsl_conf}"; then
            sed -i '/^\s*\[boot\]/a systemd=true' "${wsl_conf}"
          else
            sed -i 's/^\s*systemd\s*=.*/systemd=true/' "${wsl_conf}"
          fi
        else
          printf '\n[boot]\nsystemd=true\n' >>"${wsl_conf}"
        fi
      else
        printf '[boot]\nsystemd=true\n' >"${wsl_conf}"
        register_created_file "${wsl_conf}"
      fi
      log_success "systemd enabled"
      log_warn "WSL restart required: wsl --shutdown"
    fi
  fi

  # Start Docker if systemd running
  if [[ ${DRY_RUN} != true ]] && pidof systemd &>/dev/null; then
    log_info "Starting Docker service..."
    # shellcheck disable=SC2310  # Intentional: allow failures for service start
    execute systemctl enable --now docker.service 2>/dev/null || true
    # shellcheck disable=SC2310  # Intentional: allow failures for service start
    execute systemctl enable containerd.service 2>/dev/null || true
    log_success "Docker service started"
  else
    log_info "systemd not running - Docker starts after WSL restart"
  fi
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

  local -i passed=1

  # Docker CLI
  local has_docker_cli=false
  # shellcheck disable=SC2310  # Intentional: capture result in variable
  has_command docker && has_docker_cli=true
  if [[ ${has_docker_cli} == true ]]; then
    local cli_ver
    cli_ver="$(docker --version)" || cli_ver="unknown"
    log_success "Docker CLI: ${cli_ver}"
  else
    log_error "Docker CLI not found"
    passed=0
  fi

  # Docker Compose
  if docker compose version &>/dev/null; then
    local compose_ver
    compose_ver="$(docker compose version --short)" || compose_ver="unknown"
    log_success "Compose: ${compose_ver}"
  else
    log_warn "Docker Compose not available"
  fi

  # Docker daemon
  if docker info &>/dev/null; then
    log_success "Docker daemon running"

    log_info "Running hello-world test..."
    if docker run --rm hello-world &>/dev/null; then
      log_success "hello-world test passed"
    else
      log_warn "hello-world failed (may need WSL restart)"
    fi
  else
    log_warn "Docker daemon not running (restart WSL)"
  fi

  # systemd status
  if pidof systemd &>/dev/null; then
    local status
    status="$(systemctl is-active docker 2>/dev/null || echo 'unknown')"
    log_info "Docker service: ${status}"
  fi

  # Docker socket permissions
  if [[ -S /var/run/docker.sock ]]; then
    local sock_perms
    sock_perms=$(stat -c '%a' /var/run/docker.sock 2>/dev/null || echo 'unknown')
    if [[ ${sock_perms} == "660" ]]; then
      log_success "Docker socket permissions: ${sock_perms}"
    else
      log_warn "Docker socket permissions: ${sock_perms} (expected 660)"
    fi
  fi

  # containerd status
  if pidof systemd &>/dev/null; then
    if systemctl is-active --quiet containerd 2>/dev/null; then
      log_success "containerd service: active"
    else
      log_warn "containerd service: not active"
    fi
  fi

  # cgroup version detection
  if [[ -f /sys/fs/cgroup/cgroup.controllers ]]; then
    log_info "cgroup: v2 (unified hierarchy)"
  elif [[ -d /sys/fs/cgroup/cpu ]]; then
    log_info "cgroup: v1 (legacy hierarchy)"
  fi

  return $((1 - passed))
}

# Post-installation health check
health_check() {
  log_info "Running post-installation health check..."

  local -i score=0
  local -ri max_score=5

  # Check Docker CLI responds
  if docker --version &>/dev/null; then
    log_debug "Health: Docker CLI responds"
    ((score++))
  else
    log_debug "Health: Docker CLI not responding"
  fi

  # Check Docker daemon socket exists
  if [[ -S /var/run/docker.sock ]]; then
    log_debug "Health: Docker socket exists"
    ((score++))
  else
    log_debug "Health: Docker socket missing"
  fi

  # Check Docker info works (daemon running)
  if docker info &>/dev/null; then
    log_debug "Health: Docker daemon responding"
    ((score++))
  else
    log_debug "Health: Docker daemon not responding"
  fi

  # Check Can pull an image
  if docker pull hello-world &>/dev/null; then
    log_debug "Health: Image pull successful"
    ((score++))
  else
    log_debug "Health: Image pull failed"
  fi

  # Check Can run a container
  if docker run --rm hello-world &>/dev/null; then
    log_debug "Health: Container run successful"
    ((score++))
  else
    log_debug "Health: Container run failed"
  fi

  log_info "Health check score: ${score}/${max_score}"

  if ((score < 3)); then
    log_warn "Installation may be incomplete - restart WSL and re-run"
    return 1
  fi

  log_success "Health check passed"
  return 0
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
  log_info "Distribution: ${DISTRO_ID} ${DISTRO_CODENAME} (${ARCH})"
  log_info "Repo codename: ${EFFECTIVE_CODENAME:-${DISTRO_CODENAME}}"
  log_info "Docker user:  ${DOCKER_USER:-'(none)'}"
  log_info "Log file:     ${LOG_FILE}"
  log_info ""

  if ! pidof systemd &>/dev/null; then
    log_warn "ACTION REQUIRED: Restart WSL"
    log_warn "  1. Close all WSL terminals"
    log_warn "  2. PowerShell: wsl --shutdown"
    log_warn "  3. Open new WSL terminal"
    log_info ""
  fi

  [[ -n ${DOCKER_USER} ]] && log_info "Apply group: newgrp docker"
  log_info "Test: docker run hello-world"
}

#-------------------------------------------------------------------------------
# Help
#-------------------------------------------------------------------------------
show_help() {
  cat <<EOF
${COLORS[bold]}${SCRIPT_NAME}${COLORS[reset]} v${SCRIPT_VERSION} - Docker Engine installer for WSL2

${COLORS[bold]}USAGE:${COLORS[reset]}
    sudo ${SCRIPT_NAME} [OPTIONS]

${COLORS[bold]}INSTALLATION OPTIONS:${COLORS[reset]}
    --user USERNAME    Add user to docker group (default: \$SUDO_USER)
    --skip-iptables    Skip iptables-legacy configuration
    --version VERSION  Install specific Docker version

${COLORS[bold]}REMOVAL OPTIONS:${COLORS[reset]}
    --remove           Remove Docker Engine and repository configuration
    --purge            Also remove Docker data (images, containers, volumes)
                       WARNING: This permanently deletes all Docker data!
    --force, -f        Skip confirmation prompts (use with caution)
    --keep-user-group  Keep user in docker group during removal

${COLORS[bold]}GENERAL OPTIONS:${COLORS[reset]}
    --dry-run          Preview without making changes
    --verbose, -v      Enable verbose output
    --trace-commands   Enable command-level tracing (DEBUG trap)
    --syslog           Also log to syslog (for enterprise environments)
    --help, -h         Show this help

${COLORS[bold]}SUPPORTED:${COLORS[reset]}
    Debian-based distributions (Ubuntu, Debian) - auto-detects codename

${COLORS[bold]}EXAMPLES:${COLORS[reset]}
    # Install Docker
    sudo ${SCRIPT_NAME}
    sudo ${SCRIPT_NAME} --user myuser --verbose
    sudo ${SCRIPT_NAME} --dry-run

    # Remove Docker (preserve data)
    sudo ${SCRIPT_NAME} --remove
    sudo ${SCRIPT_NAME} --remove --user myuser

    # Remove Docker completely (delete all data)
    sudo ${SCRIPT_NAME} --remove --purge --force

${COLORS[bold]}REMOVAL NOTES:${COLORS[reset]}
    The --remove option will:
      - Stop Docker services
      - Remove Docker packages (docker-ce, docker-ce-cli, etc.)
      - Remove Docker repository and GPG key
      - Remove specified user from docker group

    The --remove option will NOT remove:
      - Prerequisites (curl, gnupg, etc.) - used by other apps
      - /etc/wsl.conf systemd setting - may be used by other services
      - iptables settings - may affect other applications
      - Docker data (unless --purge is specified)

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
        DOCKER_USER="${2}"
        shift 2
        ;;
      --user=*)
        DOCKER_USER="${1#*=}"
        validate_username "${DOCKER_USER}"
        shift
        ;;
      --skip-iptables)
        SKIP_IPTABLES=true
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
      --version)
        [[ -n ${2:-} ]] || die "--version requires VERSION (e.g., 5:24.0.7-1~debian.12~bookworm)" "${EXIT_INVALID_ARGS}"
        DOCKER_VERSION="${2}"
        shift 2
        ;;
      --version=*)
        DOCKER_VERSION="${1#*=}"
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
      --keep-user-group)
        REMOVE_USER_FROM_GROUP=false
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
  if [[ ${REMOVE_MODE} == true ]]; then
    # --remove is mutually exclusive with install-only options
    [[ -n ${DOCKER_VERSION} ]] && die "--remove and --version are mutually exclusive" "${EXIT_INVALID_ARGS}"
    [[ ${SKIP_IPTABLES} == true ]] && die "--remove and --skip-iptables are mutually exclusive" "${EXIT_INVALID_ARGS}"
  fi

  # --purge requires --remove
  [[ ${PURGE_DATA} == true && ${REMOVE_MODE} != true ]] && die "--purge requires --remove" "${EXIT_INVALID_ARGS}"

  # --keep-user-group requires --remove
  [[ ${REMOVE_USER_FROM_GROUP} == false && ${REMOVE_MODE} != true ]] && die "--keep-user-group requires --remove" "${EXIT_INVALID_ARGS}"

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
  log_info "  Docker Engine WSL2 Installer v${SCRIPT_VERSION}"
  log_info "  Bash ${BASH_VERSION} | Started: $(printf '%(%F %T)T' "${EPOCHSECONDS}")"
  log_info "==============================================================="

  [[ ${DRY_RUN} == true ]] && log_warn "DRY-RUN MODE: No changes will be made"
  [[ ${TRACE_COMMANDS} == true ]] && log_warn "TRACE MODE: Command tracing enabled"

  setup_signal_handlers
  setup_debug_tracing

  # Freeze configuration to prevent modification
  readonly DOCKER_USER SKIP_IPTABLES DRY_RUN VERBOSE DOCKER_VERSION SYSLOG TRACE_COMMANDS

  acquire_lock

  # Validation
  check_root
  validate_required_commands
  check_wsl2
  detect_distribution
  detect_architecture
  validate_user
  check_disk_space
  check_file_descriptors
  check_dns
  check_network

  # Installation
  remove_conflicting_packages
  install_prerequisites
  setup_docker_repository
  install_docker_engine
  configure_iptables
  configure_user_group
  configure_systemd

  # Verify
  # shellcheck disable=SC2310  # Intentional: allow verification to fail gracefully
  verify_installation || true

  # Run health check if daemon is running
  if pidof systemd &>/dev/null && docker info &>/dev/null; then
    # shellcheck disable=SC2310  # Intentional: allow health check to fail gracefully
    health_check || true
  fi

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
