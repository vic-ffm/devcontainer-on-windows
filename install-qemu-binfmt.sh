#!/usr/bin/env bash
# SPDX-License-Identifier: NCSA
#===============================================================================
# install-qemu-binfmt.sh - QEMU user-mode emulation installer for WSL2 Docker
#
# DESCRIPTION:
#   Script to install or remove QEMU user-mode emulation via binfmt_misc
#   for Docker multi-architecture support on WSL2 systems.
#   Enables running any Linux binary from any ISA (ARM64, ARM, RISC-V, etc.)
#   directly in WSL2 and inside Docker containers/devcontainers.
#   Non-interactive and idempotent.
#
# REQUIREMENTS:
#   Bash 5.2+
#   Ubuntu 24.04+ or Debian 12+ in WSL2
#   Docker Engine installed and running (for steps 2-4)
#
# USAGE:
#   sudo ./install-qemu-binfmt.sh
#   sudo ./install-qemu-binfmt.sh --user myuser --verbose
#   sudo ./install-qemu-binfmt.sh --remove
#   sudo ./install-qemu-binfmt.sh --remove --force
#
# INSTALLATION OPTIONS:
#   --user USERNAME    User for Docker buildx configuration (default: $SUDO_USER)
#   --skip-buildx      Skip Docker buildx multi-arch builder setup
#
# REMOVAL OPTIONS:
#   --remove           Remove binfmt registration and systemd service
#   --force, -f        Skip confirmation prompts
#
# GENERAL OPTIONS:
#   --dry-run          Show what would be done without making changes
#   --verbose, -v      Enable verbose output
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

#-------------------------------------------------------------------------------
# Constants
#-------------------------------------------------------------------------------
declare -r SCRIPT_NAME="${0##*/}"
declare -r SCRIPT_VERSION="1.0.0"
declare -r LOG_FILE="/var/log/qemu-binfmt-install.log"
declare -r LOCK_FILE="/var/lock/qemu-binfmt-install.lock"

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
declare -ri EXIT_DOCKER_NOT_INSTALLED=6
# shellcheck disable=SC2034  # Exit codes defined for completeness/documentation
declare -ri EXIT_NETWORK_ERROR=7
# shellcheck disable=SC2034  # Exit codes defined for completeness/documentation
declare -ri EXIT_INSTALL_FAILED=8
# shellcheck disable=SC2034  # Exit codes defined for completeness/documentation
declare -ri EXIT_USER_CANCELLED=9

# Required commands for script execution
declare -ra REQUIRED_COMMANDS=(
  docker systemctl id stat mkdir rm mv cp chmod grep tee sleep flock pgrep
)

# tonistiigi/binfmt - Docker's recommended QEMU binfmt image
# Ships static QEMU binaries with proper F flag registration
declare -r BINFMT_IMAGE="tonistiigi/binfmt"

# systemd service file for boot-time binfmt registration
declare -r BINFMT_SERVICE_FILE="/etc/systemd/system/docker-binfmt.service"

# Step marker directory for idempotency tracking
declare -r STEP_MARKER_DIR="/var/lib/qemu-binfmt-install"

#-------------------------------------------------------------------------------
# Global State Variables
#-------------------------------------------------------------------------------
declare QEMU_USER="${SUDO_USER:-}"
declare SKIP_BUILDX=false
declare DRY_RUN=false
declare VERBOSE=false

# Removal mode state
declare REMOVE_MODE=false
declare FORCE_REMOVE=false

# Cleanup state tracking (for rollback)
declare -i CLEANUP_IN_PROGRESS=0
declare -i SIGNAL_RECEIVED=0
# shellcheck disable=SC2034  # RECEIVED_SIGNAL used for diagnostics
declare RECEIVED_SIGNAL=""
declare -a CLEANUP_ACTIONS=()
# shellcheck disable=SC2034  # CREATED_FILES used in cleanup registry
declare -A CREATED_FILES=()
# shellcheck disable=SC2034  # MODIFIED_FILES used in cleanup registry
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

# Validate username format
validate_username() {
  local -r user="$1"
  if [[ ! ${user} =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
    die "Invalid username format: '${user}'. Must be POSIX-compliant (lowercase, start with letter/underscore, max 32 chars)" "${EXIT_INVALID_ARGS}"
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
    die "Install missing commands and try again" "${EXIT_GENERAL_ERROR}"
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
  # shellcheck disable=SC2034  # CREATED_FILES used by cleanup functions
  CREATED_FILES["${file}"]=1
  log_debug "Registered created file: ${file}"
}

register_modified_file() {
  local -r file="$1" backup="$2"
  # shellcheck disable=SC2034  # MODIFIED_FILES used by cleanup functions
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
  [SYS]="31:Bad system call:fatal"
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
  # shellcheck disable=SC2034  # RECEIVED_SIGNAL used for diagnostics
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
      log_warn "Received SIG${sig_name} - shutting down..."
      ;;
  esac

  cleanup
  exit "${exit_code}"
}

#-------------------------------------------------------------------------------
# ERR Handler
#-------------------------------------------------------------------------------
error_handler() {
  local -ri line="${1:-0}"
  local -ri exit_code="${2:-1}"
  local -r cmd="${3:-unknown}"

  # Skip if already handling cleanup
  ((CLEANUP_IN_PROGRESS)) && return

  log_error "Command failed at line ${line} (exit code: ${exit_code})"
  log_error "Failed command: ${cmd}"

  cleanup
}

#-------------------------------------------------------------------------------
# Cleanup Function
#-------------------------------------------------------------------------------
cleanup() {
  # Prevent re-entrant cleanup
  ((CLEANUP_IN_PROGRESS)) && return
  CLEANUP_IN_PROGRESS=1

  log_debug "Running cleanup..."

  # Execute registered cleanup actions in reverse order
  local -i i
  for ((i = ${#CLEANUP_ACTIONS[@]} - 1; i >= 0; i--)); do
    local action="${CLEANUP_ACTIONS[i]}"
    log_debug "Running cleanup action: ${action}"
    # shellcheck disable=SC2310  # Intentional: allow cleanup actions to fail
    ${action} 2>/dev/null || true
  done
}

#-------------------------------------------------------------------------------
# Signal Handler Setup
#-------------------------------------------------------------------------------
setup_signal_handlers() {
  # Set up traps for all defined signals
  local sig
  for sig in "${!SIGNAL_INFO[@]}"; do
    # shellcheck disable=SC2064  # Intentional: expand sig now
    trap "signal_handler ${sig}" "SIG${sig}" 2>/dev/null || true
  done

  # ERR trap for automatic error handling
  trap 'error_handler ${LINENO} $? "${BASH_COMMAND}"' ERR

  # EXIT trap as final safety net
  trap 'cleanup' EXIT
}

#-------------------------------------------------------------------------------
# Step Markers (Idempotency)
#-------------------------------------------------------------------------------
step_completed() {
  local -r step_name="$1"
  [[ -f "${STEP_MARKER_DIR}/${step_name}.done" ]]
}

mark_step_complete() {
  local -r step_name="$1"
  mkdir -p "${STEP_MARKER_DIR}"
  touch "${STEP_MARKER_DIR}/${step_name}.done"
  log_debug "Marked step complete: ${step_name}"
}

clear_step_markers() {
  if [[ -d "${STEP_MARKER_DIR}" ]]; then
    rm -rf "${STEP_MARKER_DIR}"
    log_debug "Cleared step markers"
  fi
}

#-------------------------------------------------------------------------------
# Validation Functions
#-------------------------------------------------------------------------------
check_root() {
  if ((EUID != 0)); then
    die "This script must be run as root (use sudo)" "${EXIT_ROOT_REQUIRED}"
  fi
  log_success "Running as root"
}

check_wsl2() {
  log_info "Checking WSL2 environment..."

  # shellcheck disable=SC2310  # Intentional: capture result in conditional
  if ! is_wsl2; then
    die "This script is designed for WSL2 only" "${EXIT_NOT_WSL2}"
  fi

  log_success "Running in WSL2"
}

check_docker_installed() {
  log_info "Checking Docker installation..."

  # shellcheck disable=SC2310  # Intentional: capture result in conditional
  if ! has_command docker; then
    die "Docker is not installed. Install Docker first using install-docker.sh" "${EXIT_DOCKER_NOT_INSTALLED}"
  fi

  local docker_ver
  docker_ver=$(docker --version 2>/dev/null) || docker_ver="unknown"
  log_success "Docker installed: ${docker_ver}"
}

check_docker_running() {
  log_info "Checking if Docker daemon is running..."

  if docker info &>/dev/null; then
    log_success "Docker daemon is running"
    return 0
  else
    log_warn "Docker daemon is not running"
    return 1
  fi
}

validate_user() {
  if [[ -n ${QEMU_USER} ]]; then
    validate_username "${QEMU_USER}"

    if ! id "${QEMU_USER}" &>/dev/null; then
      die "User '${QEMU_USER}' does not exist" "${EXIT_INVALID_ARGS}"
    fi

    log_success "User '${QEMU_USER}' exists"
  fi
}

#-------------------------------------------------------------------------------
# Installation Functions
#-------------------------------------------------------------------------------

# Step 1/4: Create systemd service (No Docker required)
create_systemd_service() {
  log_step "1/4" "Creating systemd service for boot-time binfmt registration"

  # shellcheck disable=SC2310  # Intentional: step_completed in if condition
  if step_completed "systemd_service"; then
    log_info "systemd service already configured (skipping)"
    return 0
  fi

  # Create systemd service that runs after Docker starts
  # This is needed because:
  # 1. WSL2 masks systemd-binfmt.service with ConditionVirtualization=!wsl
  # 2. wsl --shutdown resets all binfmt_misc registrations
  # 3. This service re-registers on every boot automatically
  local -r service_content='[Unit]
Description=Register QEMU binfmt interpreters for Docker multi-arch
Documentation=https://github.com/tonistiigi/binfmt
After=docker.service
Requires=docker.service
ConditionPathExists=/var/run/docker.sock

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/docker run --rm --privileged tonistiigi/binfmt --install all
ExecStop=/usr/bin/docker run --rm --privileged tonistiigi/binfmt --uninstall all
TimeoutStartSec=120

[Install]
WantedBy=multi-user.target'

  if [[ ${DRY_RUN} == true ]]; then
    log_info "[DRY-RUN] Would create: ${BINFMT_SERVICE_FILE}"
    log_info "[DRY-RUN] Would enable docker-binfmt.service"
    return 0
  fi

  # Backup if exists
  [[ -f "${BINFMT_SERVICE_FILE}" ]] && backup_file "${BINFMT_SERVICE_FILE}"

  # Write service file atomically
  atomic_write "${BINFMT_SERVICE_FILE}" "${service_content}"
  chmod 644 "${BINFMT_SERVICE_FILE}"

  # Reload systemd (works even if Docker not running)
  execute systemctl daemon-reload
  execute systemctl enable docker-binfmt.service

  mark_step_complete "systemd_service"
  log_success "systemd service created and enabled (will activate on boot)"
}

# Step 2/4: Pre-pull binfmt image (Requires Docker)
pull_binfmt_image() {
  log_step "2/4" "Pre-pulling binfmt image for faster boot"

  # Check if Docker daemon is running
  if ! docker info &>/dev/null; then
    log_warn "Docker daemon not running - image will be pulled on first boot"
    return 0
  fi

  # shellcheck disable=SC2310  # Intentional: step_completed in if condition
  if step_completed "image_pull"; then
    log_info "binfmt image already cached (skipping)"
    return 0
  fi

  if [[ ${DRY_RUN} == true ]]; then
    log_info "[DRY-RUN] Would pull: ${BINFMT_IMAGE}"
    return 0
  fi

  # Pull with retry for network reliability
  log_info "Pulling ${BINFMT_IMAGE}..."
  # shellcheck disable=SC2310  # Intentional: retry_with_backoff in if condition
  if ! retry_with_backoff "${MAX_RETRIES}" "${RETRY_DELAY_BASE}" \
    docker pull "${BINFMT_IMAGE}"; then
    log_warn "Failed to pre-pull image (non-fatal, will pull on boot)"
    return 0
  fi

  mark_step_complete "image_pull"
  log_success "binfmt image cached locally"
}

# Step 3/4: Register binfmt interpreters (Requires Docker)
register_binfmt_interpreters() {
  log_step "3/4" "Registering binfmt_misc interpreters"

  # Check if Docker daemon is running
  if ! docker info &>/dev/null; then
    log_warn "Docker daemon not running - binfmt will register on boot via systemd service"
    return 0
  fi

  # Note: We don't use step_completed here because binfmt registrations
  # are kernel-level and lost on wsl --shutdown. The systemd service
  # handles re-registration on boot. This step is for immediate activation.

  if [[ ${DRY_RUN} == true ]]; then
    log_info "[DRY-RUN] Would register binfmt interpreters"
    return 0
  fi

  # Register all architectures with F flag
  # The F flag (fix-binary) opens the interpreter immediately and keeps it
  # in kernel memory, enabling execution inside container namespaces AND
  # direct binary execution on the host filesystem
  log_info "Registering QEMU interpreters with F flag..."
  # shellcheck disable=SC2310  # Intentional: execute in if condition
  if ! execute docker run --rm --privileged "${BINFMT_IMAGE}" --install all; then
    log_warn "Failed to register binfmt interpreters (will retry on boot)"
    return 0
  fi

  log_success "binfmt_misc interpreters registered"
}

# Step 4/4: Configure Docker buildx (Requires Docker)
configure_docker_buildx() {
  log_step "4/4" "Configuring Docker buildx for multi-architecture builds"

  if [[ ${SKIP_BUILDX} == true ]]; then
    log_info "Skipping buildx configuration (--skip-buildx)"
    return 0
  fi

  # Check if Docker daemon is running
  if ! docker info &>/dev/null; then
    log_warn "Docker daemon not running - configure buildx after WSL restart"
    return 0
  fi

  if [[ -z ${QEMU_USER} ]]; then
    log_warn "No user specified - skipping buildx configuration"
    return 0
  fi

  local -r builder_name="multiarch"

  # Check if builder already exists
  if sudo -u "${QEMU_USER}" docker buildx inspect "${builder_name}" &>/dev/null; then
    log_info "Builder '${builder_name}' already exists"
    execute sudo -u "${QEMU_USER}" docker buildx use "${builder_name}"
    log_success "Using existing '${builder_name}' builder"
    return 0
  fi

  if [[ ${DRY_RUN} == true ]]; then
    log_info "[DRY-RUN] Would create buildx builder: ${builder_name}"
    return 0
  fi

  # Create new builder with docker-container driver
  log_info "Creating buildx builder '${builder_name}'..."
  # shellcheck disable=SC2310  # Intentional: execute in if condition
  if ! execute sudo -u "${QEMU_USER}" docker buildx create \
    --name "${builder_name}" \
    --driver docker-container \
    --bootstrap; then
    log_warn "Failed to create buildx builder (non-fatal)"
    return 0
  fi

  execute sudo -u "${QEMU_USER}" docker buildx use "${builder_name}"
  log_success "Docker buildx configured with '${builder_name}' builder"
}

#-------------------------------------------------------------------------------
# Removal Functions
#-------------------------------------------------------------------------------

# Step 1/4: Stop binfmt service
stop_binfmt_service() {
  log_step "1/4" "Stopping binfmt service"

  if [[ ${DRY_RUN} == true ]]; then
    log_info "[DRY-RUN] Would stop docker-binfmt.service"
    return 0
  fi

  if systemctl is-active --quiet docker-binfmt.service 2>/dev/null; then
    execute systemctl stop docker-binfmt.service
    log_success "Service stopped"
  else
    log_info "Service not running"
  fi

  if systemctl is-enabled --quiet docker-binfmt.service 2>/dev/null; then
    execute systemctl disable docker-binfmt.service
    log_success "Service disabled"
  else
    log_info "Service not enabled"
  fi
}

# Step 2/4: Unregister binfmt interpreters
unregister_binfmt() {
  log_step "2/4" "Unregistering binfmt interpreters"

  if [[ ${DRY_RUN} == true ]]; then
    log_info "[DRY-RUN] Would unregister binfmt interpreters"
    return 0
  fi

  if docker info &>/dev/null; then
    # shellcheck disable=SC2310  # Intentional: allow uninstall to fail gracefully
    execute docker run --rm --privileged "${BINFMT_IMAGE}" --uninstall all 2>/dev/null || true
    log_success "Interpreters unregistered"
  else
    log_warn "Docker not running - cannot unregister (will clear on WSL restart anyway)"
  fi
}

# Step 3/4: Remove systemd service
remove_systemd_service() {
  log_step "3/4" "Removing systemd service"

  if [[ ${DRY_RUN} == true ]]; then
    log_info "[DRY-RUN] Would remove: ${BINFMT_SERVICE_FILE}"
    return 0
  fi

  if [[ -f "${BINFMT_SERVICE_FILE}" ]]; then
    execute rm -f "${BINFMT_SERVICE_FILE}"
    execute systemctl daemon-reload
    log_success "Service file removed"
  else
    log_info "Service file not present"
  fi
}

# Step 4/4: Remove buildx builder
remove_buildx_builder() {
  log_step "4/4" "Removing buildx builder"

  if [[ ${DRY_RUN} == true ]]; then
    log_info "[DRY-RUN] Would remove buildx builder 'multiarch'"
    return 0
  fi

  if [[ -n ${QEMU_USER} ]] && docker info &>/dev/null; then
    # shellcheck disable=SC2310  # Intentional: allow removal to fail gracefully
    sudo -u "${QEMU_USER}" docker buildx rm multiarch 2>/dev/null || true
    log_success "Builder removed (if existed)"
  else
    log_info "Skipping buildx removal (no user or Docker not running)"
  fi
}

#-------------------------------------------------------------------------------
# Verification Functions
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

  # 1. Check binfmt_misc is enabled
  if [[ -f /proc/sys/fs/binfmt_misc/status ]] \
    && [[ "$(</proc/sys/fs/binfmt_misc/status)" == "enabled" ]]; then
    log_success "[1/${total}] binfmt_misc is enabled"
    ((passed++))
  else
    log_error "[1/${total}] binfmt_misc is NOT enabled"
  fi

  # 2. Check qemu-aarch64 registered with F flag
  if [[ -f /proc/sys/fs/binfmt_misc/qemu-aarch64 ]]; then
    if grep -q "flags:.*F" /proc/sys/fs/binfmt_misc/qemu-aarch64 2>/dev/null; then
      log_success "[2/${total}] qemu-aarch64 registered with F flag"
      ((passed++))
    else
      log_warn "[2/${total}] qemu-aarch64 missing F flag"
    fi
  else
    log_warn "[2/${total}] qemu-aarch64 NOT registered (will register on boot)"
  fi

  # 3. Check systemd service enabled
  if systemctl is-enabled --quiet docker-binfmt.service 2>/dev/null; then
    log_success "[3/${total}] docker-binfmt.service enabled"
    ((passed++))
  else
    log_error "[3/${total}] docker-binfmt.service NOT enabled"
  fi

  # 4. Check Docker buildx supports linux/arm64
  if [[ -n ${QEMU_USER} ]] && docker info &>/dev/null; then
    if sudo -u "${QEMU_USER}" docker buildx ls 2>/dev/null | grep -q "linux/arm64"; then
      log_success "[4/${total}] Docker buildx supports linux/arm64"
      ((passed++))
    else
      log_warn "[4/${total}] Docker buildx may not support linux/arm64"
    fi
  else
    log_info "[4/${total}] Skipping buildx check (no user or Docker not running)"
    ((passed++)) # Don't penalize if we can't check
  fi

  # 5. Test cross-architecture container (only if Docker running and binfmt registered)
  if docker info &>/dev/null && [[ -f /proc/sys/fs/binfmt_misc/qemu-aarch64 ]]; then
    log_info "Running cross-architecture container test..."
    local test_output
    if test_output=$(docker run --rm --platform linux/arm64 alpine:latest uname -m 2>&1); then
      if [[ ${test_output} == "aarch64" ]]; then
        log_success "[5/${total}] Cross-architecture container test passed (arm64 -> aarch64)"
        ((passed++))
      else
        log_warn "[5/${total}] Unexpected output: ${test_output}"
      fi
    else
      log_warn "[5/${total}] Cross-architecture container test failed (will work after boot)"
    fi
  else
    log_info "[5/${total}] Skipping container test (Docker not running or binfmt not registered yet)"
    ((passed++)) # Don't penalize if we can't test
  fi

  log_info ""
  log_info "Verification: ${passed}/${total} checks passed"

  return $((passed < 3 ? 1 : 0))
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

  # Check service removed
  if [[ -f "${BINFMT_SERVICE_FILE}" ]]; then
    log_error "Service file still exists: ${BINFMT_SERVICE_FILE}"
    ((issues++))
  else
    log_success "Service file removed"
  fi

  # Check service not enabled
  if systemctl is-enabled --quiet docker-binfmt.service 2>/dev/null; then
    log_error "Service still enabled"
    ((issues++))
  else
    log_success "Service disabled/removed"
  fi

  # Check binfmt not registered
  if [[ -f /proc/sys/fs/binfmt_misc/qemu-aarch64 ]]; then
    log_warn "binfmt still registered (will clear on WSL restart)"
  else
    log_success "binfmt unregistered"
  fi

  if ((issues == 0)); then
    log_success "Removal verification passed"
  else
    log_warn "Removal had ${issues} issue(s)"
  fi

  return $((issues > 0 ? 1 : 0))
}

#-------------------------------------------------------------------------------
# Summary Functions
#-------------------------------------------------------------------------------
print_summary() {
  printf '\n%b===============================================================%b\n' "${COLORS[bold]}" "${COLORS[reset]}" | tee -a "${LOG_FILE}"
  printf '%b                    INSTALLATION COMPLETE%b\n' "${COLORS[bold]}" "${COLORS[reset]}" | tee -a "${LOG_FILE}"
  printf '%b===============================================================%b\n' "${COLORS[bold]}" "${COLORS[reset]}" | tee -a "${LOG_FILE}"

  [[ ${DRY_RUN} == true ]] && log_info "Mode: DRY-RUN (no changes made)"

  log_info ""
  log_info "QEMU user-mode emulation has been configured."
  log_info ""
  log_info "What this enables:"
  log_info "  - Run any Linux binary from any ISA directly in WSL2"
  log_info "  - Docker multi-arch containers (docker run --platform linux/arm64 ...)"
  log_info "  - Docker multi-arch builds (docker buildx build --platform ...)"
  log_info "  - All above features work inside devcontainers too"
  log_info ""
  log_info "Log file: ${LOG_FILE}"
  log_info ""

  if ! docker info &>/dev/null; then
    log_warn "ACTION REQUIRED: Restart WSL"
    log_warn "  1. Close all WSL terminals"
    log_warn "  2. PowerShell: wsl --shutdown"
    log_warn "  3. Open new WSL terminal"
    log_warn "  4. Test: docker run --rm --platform linux/arm64 alpine uname -m"
    log_info ""
  else
    log_info "Test commands:"
    log_info "  docker run --rm --platform linux/arm64 alpine uname -m"
    log_info "  docker buildx build --platform linux/arm64,linux/amd64 ."
  fi
}

print_removal_summary() {
  printf '\n%b===============================================================%b\n' "${COLORS[bold]}" "${COLORS[reset]}" | tee -a "${LOG_FILE}"
  printf '%b                    REMOVAL COMPLETE%b\n' "${COLORS[bold]}" "${COLORS[reset]}" | tee -a "${LOG_FILE}"
  printf '%b===============================================================%b\n' "${COLORS[bold]}" "${COLORS[reset]}" | tee -a "${LOG_FILE}"

  [[ ${DRY_RUN} == true ]] && log_info "Mode: DRY-RUN (no changes made)"

  log_info ""
  log_info "QEMU binfmt configuration has been removed."
  log_info ""
  log_info "Note: binfmt registrations are kernel-level and persist until"
  log_info "      WSL is restarted. Run 'wsl --shutdown' to fully clear."
  log_info ""
  log_info "Log file: ${LOG_FILE}"
}

#-------------------------------------------------------------------------------
# Help Function
#-------------------------------------------------------------------------------
show_help() {
  cat <<EOF
${COLORS[bold]}${SCRIPT_NAME}${COLORS[reset]} v${SCRIPT_VERSION} - QEMU binfmt installer for WSL2 Docker

${COLORS[bold]}USAGE:${COLORS[reset]}
    sudo ${SCRIPT_NAME} [OPTIONS]

${COLORS[bold]}DESCRIPTION:${COLORS[reset]}
    Installs QEMU user-mode emulation via binfmt_misc for Docker multi-arch
    support. Enables running any Linux binary from any ISA (ARM64, ARM,
    RISC-V, etc.) directly in WSL2 and inside Docker containers/devcontainers.

${COLORS[bold]}INSTALLATION OPTIONS:${COLORS[reset]}
    --user USERNAME    User for Docker buildx configuration (default: \$SUDO_USER)
    --skip-buildx      Skip Docker buildx multi-arch builder setup

${COLORS[bold]}REMOVAL OPTIONS:${COLORS[reset]}
    --remove           Remove binfmt registration and systemd service
    --force, -f        Skip confirmation prompts

${COLORS[bold]}GENERAL OPTIONS:${COLORS[reset]}
    --dry-run          Preview without making changes
    --verbose, -v      Enable verbose output
    --help, -h         Show this help

${COLORS[bold]}EXAMPLES:${COLORS[reset]}
    # Install QEMU binfmt
    sudo ${SCRIPT_NAME}
    sudo ${SCRIPT_NAME} --user myuser --verbose

    # Remove QEMU binfmt
    sudo ${SCRIPT_NAME} --remove
    sudo ${SCRIPT_NAME} --remove --force

${COLORS[bold]}WHAT THIS ENABLES:${COLORS[reset]}
    - Run any Linux binary from any ISA directly in WSL2
    - Docker: docker run --rm --platform linux/arm64 alpine uname -m
    - Buildx: docker buildx build --platform linux/arm64,linux/amd64 .
    - All features work inside devcontainers too

${COLORS[bold]}REQUIREMENTS:${COLORS[reset]}
    - Bash 5.2+
    - Ubuntu 24.04+ or Debian 12+ in WSL2
    - Docker Engine installed (install-docker.sh)

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
        QEMU_USER="${2}"
        shift 2
        ;;
      --user=*)
        QEMU_USER="${1#*=}"
        validate_username "${QEMU_USER}"
        shift
        ;;
      --skip-buildx)
        SKIP_BUILDX=true
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
      --remove)
        REMOVE_MODE=true
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
  if [[ ${REMOVE_MODE} == true ]]; then
    # --remove is mutually exclusive with install-only options
    [[ ${SKIP_BUILDX} == true ]] && die "--remove and --skip-buildx are mutually exclusive" "${EXIT_INVALID_ARGS}"
  fi

  # --force without --remove is a no-op (warn but continue)
  if [[ ${FORCE_REMOVE} == true && ${REMOVE_MODE} != true ]]; then
    log_warn "--force has no effect without --remove"
  fi
}

#-------------------------------------------------------------------------------
# Main Functions
#-------------------------------------------------------------------------------
main() {
  mkdir -p "${LOG_FILE%/*}"
  : >"${LOG_FILE}"
  chmod 644 "${LOG_FILE}"

  log_info "==============================================================="
  log_info "  QEMU binfmt WSL2 Installer v${SCRIPT_VERSION}"
  log_info "  Bash ${BASH_VERSION} | Started: $(printf '%(%F %T)T' "${EPOCHSECONDS}")"
  log_info "==============================================================="

  [[ ${DRY_RUN} == true ]] && log_warn "DRY-RUN MODE: No changes will be made"

  setup_signal_handlers

  # Freeze configuration to prevent modification
  readonly QEMU_USER SKIP_BUILDX DRY_RUN VERBOSE

  acquire_lock

  # Validation
  check_root
  validate_required_commands
  check_wsl2
  check_docker_installed
  validate_user

  # Installation (4 steps)
  create_systemd_service       # Step 1/4 - Always succeeds (no Docker needed)
  pull_binfmt_image            # Step 2/4 - Needs Docker
  register_binfmt_interpreters # Step 3/4 - Needs Docker
  configure_docker_buildx      # Step 4/4 - Needs Docker

  # Verify
  # shellcheck disable=SC2310  # Intentional: allow verification to fail gracefully
  verify_installation || true

  print_summary

  log_success "Installation completed successfully!"
}

main_remove() {
  mkdir -p "${LOG_FILE%/*}"
  : >"${LOG_FILE}"
  chmod 644 "${LOG_FILE}"

  log_info "==============================================================="
  log_info "  QEMU binfmt WSL2 Remover v${SCRIPT_VERSION}"
  log_info "  Bash ${BASH_VERSION} | Started: $(printf '%(%F %T)T' "${EPOCHSECONDS}")"
  log_info "==============================================================="

  [[ ${DRY_RUN} == true ]] && log_warn "DRY-RUN MODE: No changes will be made"

  setup_signal_handlers

  # Freeze configuration
  readonly QEMU_USER DRY_RUN VERBOSE FORCE_REMOVE

  acquire_lock

  # Validation
  check_root
  check_wsl2

  # Confirm removal
  if [[ ${DRY_RUN} != true ]]; then
    local confirmed=false
    # shellcheck disable=SC2310  # Intentional: capture result in variable
    confirm_action "Remove QEMU binfmt configuration?" && confirmed=true
    if [[ ${confirmed} != true ]]; then
      log_info "Removal cancelled by user"
      exit 0
    fi
  fi

  # Removal (4 steps)
  stop_binfmt_service    # Step 1/4
  unregister_binfmt      # Step 2/4
  remove_systemd_service # Step 3/4
  remove_buildx_builder  # Step 4/4

  # Clean up step markers
  clear_step_markers

  # Verify
  # shellcheck disable=SC2310  # Intentional: allow verification to fail gracefully
  verify_removal || true

  print_removal_summary

  log_success "Removal completed successfully!"
}

#-------------------------------------------------------------------------------
# Entry Point
#-------------------------------------------------------------------------------
parse_arguments "$@"

# Route to appropriate main function based on mode
if [[ ${REMOVE_MODE} == true ]]; then
  main_remove
else
  main
fi
