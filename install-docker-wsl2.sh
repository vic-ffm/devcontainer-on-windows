#!/usr/bin/env bash
#===============================================================================
# install-docker-wsl2.sh - Docker Engine installer for WSL2
#
# DESCRIPTION:
#   Script to install Docker Engine on WSL2 systems.
#   Supports any Ubuntu/Debian version with automatic codename detection.
#   Non-interactive and idempotent.
#
# REQUIREMENTS:
#   Bash 5.2+ (ships with Ubuntu 24.04+, Debian 12+)
#
# USAGE:
#   curl -fsSL https://example.com/install-docker-wsl2.sh | sudo bash
#   sudo ./install-docker-wsl2.sh
#   sudo ./install-docker-wsl2.sh --user myuser --verbose
#
# OPTIONS:
#   --user USERNAME    Add specified user to docker group (default: $SUDO_USER)
#   --skip-iptables    Skip iptables-legacy configuration
#   --dry-run          Show what would be done without making changes
#   --verbose          Enable verbose output
#   --version VERSION  Install specific Docker version
#   --syslog           Also log to syslog (for enterprise environments)
#   --help             Show this help message
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
  printf 'Error: This script requires Bash 5.2+. Current: %s\n' "$BASH_VERSION" >&2
  exit 1
fi

set -o errexit        # Exit on any command failure
set -o errtrace       # ERR trap inherited by functions/subshells
set -o nounset        # Exit on undefined variable
set -o pipefail       # Catch errors in pipelines
shopt -s extglob      # Extended pattern matching
shopt -s globskipdots # Never match . or .. in globs 

# Enable debug tracing if TRACE=1
[[ ${TRACE:-0} == 1 ]] && set -o xtrace

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

# Network retry configuration
declare -ri MAX_RETRIES=5
declare -ri RETRY_DELAY_BASE=2

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
  [ubuntu]="noble jammy focal"
  [debian]="bookworm bullseye"
)

#-------------------------------------------------------------------------------
# Global State Variables
#-------------------------------------------------------------------------------
declare DOCKER_USER="${SUDO_USER:-}"
declare SKIP_IPTABLES=false
declare DRY_RUN=false
declare VERBOSE=false
declare DOCKER_VERSION=""
declare SYSLOG=false
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
  printf -v timestamp '%(%Y-%m-%d %H:%M:%S)T' "$EPOCHSECONDS"
  printf '%b[%s]%b %s - %s\n' "${COLORS[$color]}" "$level" "${COLORS[reset]}" "$timestamp" "$msg" | tee -a "$LOG_FILE"
  _syslog "$level" "$msg"
}

log_info() { _log "INFO " "blue" "$1"; }
log_success() { _log "OK   " "green" "$1"; }
log_warn() { _log "WARN " "yellow" "$1" >&2; }
log_error() { _log "ERROR" "red" "$1" >&2; }
log_debug() { [[ $VERBOSE == true ]] && _log "DEBUG" "cyan" "$1" || true; }

# Send to syslog if enabled
_syslog() {
  local -r level="$1" msg="$2"
  if [[ $SYSLOG == true ]] && has_command logger; then
    logger -t "$SCRIPT_NAME" -p "user.${level,,}" "$msg" 2>/dev/null || true
  fi
}

log_step() {
  local -r step="$1" desc="$2"
  printf '\n%b%b[Step %s]%b %s\n' "${COLORS[bold]}" "${COLORS[blue]}" "$step" "${COLORS[reset]}" "$desc" | tee -a "$LOG_FILE"
  printf '%s\n' "$(printf '─%.0s' {1..60})" | tee -a "$LOG_FILE"
}

#-------------------------------------------------------------------------------
# Utility Functions
#-------------------------------------------------------------------------------
die() {
  log_error "$1"
  exit "${2:-1}"
}

# Retry with exponential backoff and HTTP status awareness
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
      log_error "Command failed after $max_attempts attempts: ${cmd[*]@Q}"
      log_error "Last output: $output"
      return 1
    fi

    # Check for rate limiting or server errors
    if [[ $output =~ (429|503|"Too Many Requests"|"Service Unavailable") ]]; then
      log_warn "Server rate-limited or unavailable (attempt $attempt/$max_attempts)"
      ((delay *= 3)) 
    else
      log_warn "Attempt $attempt/$max_attempts failed (exit code: $exit_code). Retrying in ${delay}s..."
      ((delay *= 2)) 
    fi

    # Cap maximum delay 
    ((delay > 60)) && delay=60

    sleep "$delay"
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
  [[ $version_info =~ [Mm]icrosoft.*[Ww][Ss][Ll]2|[Ww][Ss][Ll]2.*[Mm]icrosoft ]] && return 0
  [[ $version_info =~ [Mm]icrosoft && -d /run/WSL ]] && return 0
  return 1
}

# Execute or simulate based on dry-run mode
execute() {
  if [[ $DRY_RUN == true ]]; then
    log_info "[DRY-RUN] Would execute: ${*@Q}"
    return 0
  fi
  log_debug "Executing: ${*@Q}"
  "$@"
}

# Check if package is installed
is_installed() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "^install ok installed$"
}

# Check if user is in group
user_in_group() {
  local -r user="$1" group="$2"
  id -nG "$user" 2>/dev/null | tr ' ' '\n' | grep -qx "$group"
}

# Verify GPG key fingerprint matches Docker's official key
verify_gpg_fingerprint() {
  local -r keyfile="$1"
  local actual_fp

  # Extract fingerprint using gpg
  actual_fp=$(gpg --show-keys --with-fingerprint --with-colons "$keyfile" 2>/dev/null |
    awk -F: '/^fpr:/{gsub(/ /,"",$10); print $10; exit}')

  if [[ -z $actual_fp ]]; then
    die "Failed to extract fingerprint from GPG key" 1
  fi

  if [[ ${actual_fp^^} != "${DOCKER_GPG_FINGERPRINT^^}" ]]; then
    log_error "GPG key fingerprint mismatch!"
    log_error "Expected: $DOCKER_GPG_FINGERPRINT"
    log_error "Got:      $actual_fp"
    die "Security verification failed - GPG key may be compromised" 1
  fi

  log_success "GPG key fingerprint verified"
}

# Validate username format 
validate_username() {
  local -r user="$1"
  if [[ ! $user =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
    die "Invalid username format: '$user'. Must be POSIX-compliant (lowercase, start with letter/underscore, max 32 chars)" 1
  fi
}

#-------------------------------------------------------------------------------
# Lock Management
#-------------------------------------------------------------------------------
acquire_lock() {
  log_debug "Acquiring lock: $LOCK_FILE"

  mkdir -p "${LOCK_FILE%/*}"

  # Open lock file
  exec {LOCK_FD}>"$LOCK_FILE"

  if ! flock -n "$LOCK_FD"; then
    die "Another instance of $SCRIPT_NAME is already running" 2
  fi

  # Write PID for debugging
  printf '%d\n' $$ >&"$LOCK_FD"
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
  CLEANUP_ACTIONS+=("$action")
  log_debug "Registered cleanup action: $action"
}

register_created_file() {
  local -r file="$1"
  CREATED_FILES["$file"]=1
  log_debug "Registered created file: $file"
}

register_modified_file() {
  local -r file="$1" backup="$2"
  MODIFIED_FILES["$file"]="$backup"
  log_debug "Registered modified file: $file (backup: $backup)"
}

backup_file() {
  local -r file="$1"
  if [[ -f $file ]]; then
    local backup="${file}.bak.${SRANDOM}"
    cp -a "$file" "$backup" 2>/dev/null || true
    register_modified_file "$file" "$backup"
    echo "$backup"
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
# Handles trappable signals with cleanup and exit codes
#-------------------------------------------------------------------------------
signal_handler() {
  local -r sig_name="${1:-UNKNOWN}"
  local sig_num=1 sig_desc="Unknown signal" sig_type="fatal"

  # Prevent re-entrant signal handling
  if ((SIGNAL_RECEIVED)); then
    return
  fi
  SIGNAL_RECEIVED=1
  RECEIVED_SIGNAL="$sig_name"

  # Parse signal info
  if [[ -v SIGNAL_INFO[$sig_name] ]]; then
    IFS=':' read -r sig_num sig_desc sig_type <<<"${SIGNAL_INFO[$sig_name]}"
  fi

  local -ri exit_code=$((128 + sig_num))

  # Log based on signal type
  case "$sig_type" in
    graceful)
      log_warn "Received SIG$sig_name ($sig_desc) - initiating graceful shutdown..."
      ;;
    fatal)
      log_error "FATAL: Received SIG$sig_name ($sig_desc) - attempting emergency cleanup..."
      log_error "This indicates a serious error. Please report if reproducible."
      ;;
  esac

  # Perform cleanup (will be handled by EXIT trap)
  exit "$exit_code"
}

#-------------------------------------------------------------------------------
# Error Handler
#-------------------------------------------------------------------------------
error_handler() {
  local -ri exit_code=$?
  local -r failed_cmd="$BASH_COMMAND"
  local -r line="${BASH_LINENO[0]}"
  local -r func="${FUNCNAME[1]:-main}"
  local -r src="${BASH_SOURCE[1]:-$SCRIPT_NAME}"

  # Don't trigger for intentional failures
  ((exit_code == 0)) && return 0

  log_error "Command failed with exit code $exit_code"
  log_error "  Location: $func() at $src:$line"
  log_error "  Command:  $failed_cmd"

  # Print stack trace in verbose mode
  if [[ $VERBOSE == true ]]; then
    log_debug "Stack trace:"
    local -i i
    for ((i = 1; i < ${#FUNCNAME[@]}; i++)); do
      log_debug "  [$i] ${FUNCNAME[i]}() at ${BASH_SOURCE[i]:-unknown}:${BASH_LINENO[i - 1]}"
    done
  fi
}

#-------------------------------------------------------------------------------
# Cleanup Handler (runs on EXIT - catches all termination scenarios)
# Performs cleanup in LIFO order, handles rollback of partial changes
#-------------------------------------------------------------------------------
cleanup() {
  local -ri original_exit_code=$?
  local -i exit_code=$original_exit_code

  # Prevent recursive cleanup
  if ((CLEANUP_IN_PROGRESS)); then
    return
  fi
  CLEANUP_IN_PROGRESS=1

  # Disable all signal traps during cleanup to prevent interruption
  trap '' INT TERM HUP QUIT

  log_debug "Cleanup triggered (exit_code=$exit_code, signal=${RECEIVED_SIGNAL:-none})"

  # If we received a fatal signal, adjust messaging
  if [[ -n $RECEIVED_SIGNAL ]]; then
    log_info "Cleaning up after SIG$RECEIVED_SIGNAL..."
  fi

  # Execute registered cleanup actions in reverse order (LIFO)
  local -i i
  for ((i = ${#CLEANUP_ACTIONS[@]} - 1; i >= 0; i--)); do
    local action="${CLEANUP_ACTIONS[i]}"
    log_debug "Executing cleanup action: $action"
    if declare -F "$action" &>/dev/null; then
      "$action" 2>/dev/null || true
    else
      log_warn "Unknown cleanup action skipped: $action"
    fi
  done

  # Rollback: Remove files we created (if exit was not successful)
  if ((exit_code != 0)); then
    log_info "Rolling back changes..."

    for file in "${!CREATED_FILES[@]}"; do
      if [[ -f $file ]]; then
        log_debug "Removing created file: $file"
        rm -f "$file" 2>/dev/null || true
      fi
    done

    # Restore modified files from backups
    for file in "${!MODIFIED_FILES[@]}"; do
      local backup="${MODIFIED_FILES[$file]}"
      if [[ -f $backup ]]; then
        log_debug "Restoring $file from $backup"
        mv -f "$backup" "$file" 2>/dev/null || true
      fi
    done

    # Clean up apt state if we were mid operation
    if has_command apt-get; then
      log_debug "Cleaning apt state..."
      apt-get clean 2>/dev/null || true
      rm -f /var/lib/apt/lists/lock 2>/dev/null || true
      rm -f /var/lib/dpkg/lock* 2>/dev/null || true
    fi
  else
    # Success: remove backup files
    for file in "${!MODIFIED_FILES[@]}"; do
      local backup="${MODIFIED_FILES[$file]}"
      rm -f "$backup" 2>/dev/null || true
    done
  fi

  # Final status
  if ((exit_code != 0)); then
    log_error "Script failed with exit code: $exit_code"
    [[ -n $RECEIVED_SIGNAL ]] && log_error "Terminated by: SIG$RECEIVED_SIGNAL"
    log_info "Log file: $LOG_FILE"
  fi

  exit "$exit_code"
}

#-------------------------------------------------------------------------------
# Setup All Signal Handlers
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
  trap 'signal_handler ILL' ILL   # 4  - Illegal instruction
  trap 'signal_handler TRAP' TRAP # 5  - Trace/breakpoint trap
  trap 'signal_handler ABRT' ABRT # 6  - Abort
  trap 'signal_handler BUS' BUS   # 7  - Bus error
  trap 'signal_handler FPE' FPE   # 8  - Floating point exception
  trap 'signal_handler SEGV' SEGV # 11 - Segmentation fault
  trap 'signal_handler SYS' SYS   # 31 - Bad system call
  trap 'signal_handler STKFLT' STKFLT 2>/dev/null || true # 16 - Stack fault
  # SIGEMT is only available on Alpha/SPARC/MIPS
  # Attempt to trap it but ignore failure
  trap 'signal_handler EMT' EMT 2>/dev/null || true
  trap 'signal_handler IOT' IOT 2>/dev/null || true

  log_debug "Signal handlers installed"
}

#-------------------------------------------------------------------------------
# Validation Functions
#-------------------------------------------------------------------------------
check_root() {
  ((EUID == 0)) || die "This script must be run as root. Use: sudo $SCRIPT_NAME" 1
}

check_wsl2() {
  log_info "Checking WSL2 environment..."
  is_wsl2 || die "This script requires WSL2. Detected non-WSL2 system." 1
  log_success "WSL2 environment confirmed"
}

detect_distribution() {
  log_info "Detecting Linux distribution..."

  [[ -f /etc/os-release ]] || die "Cannot detect distribution: /etc/os-release not found" 1

  # Source os-release (shellcheck knows this is intentional)
  # shellcheck source=/dev/null
  source /etc/os-release

  DISTRO_ID="${ID:-}"
  DISTRO_CODENAME="${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}"

  log_debug "Detected: ID=$DISTRO_ID, Codename=$DISTRO_CODENAME"

  # Validate distribution family
  case "${DISTRO_ID@L}" in
    ubuntu)
      DISTRO_BASE="ubuntu"
      ;;
    debian)
      DISTRO_BASE="debian"
      ;;
    *)
      # Check derivatives via ID_LIKE
      local id_like="${ID_LIKE:-}"
      if [[ $id_like == *ubuntu* ]]; then
        DISTRO_BASE="ubuntu"
        log_warn "Detected ${DISTRO_ID@Q} (Ubuntu-derivative)"
      elif [[ $id_like == *debian* ]]; then
        DISTRO_BASE="debian"
        log_warn "Detected ${DISTRO_ID@Q} (Debian-derivative)"
      else
        die "Unsupported distribution: $DISTRO_ID. Requires Ubuntu/Debian-based system." 1
      fi
      ;;
  esac

  [[ -n $DISTRO_CODENAME ]] || die "Cannot detect codename (VERSION_CODENAME not set)" 1

  log_success "Detected: $DISTRO_ID $DISTRO_CODENAME (${DISTRO_BASE}-based)"
}

detect_architecture() {
  log_info "Detecting system architecture..."

  local -r machine="$(uname -m)"

  case "$machine" in
    x86_64) ARCH="amd64" ;;
    aarch64 | arm64) ARCH="arm64" ;;
    armv7l | armhf) ARCH="armhf" ;;
    s390x) ARCH="s390x" ;;
    ppc64le) ARCH="ppc64le" ;;
    *) die "Unsupported architecture: $machine" 1 ;;
  esac

  log_success "Architecture: $ARCH"
}

validate_user() {
  log_info "Validating target user..."

  [[ -z $DOCKER_USER ]] && DOCKER_USER="${SUDO_USER:-${USER:-}}"

  if [[ -z $DOCKER_USER || $DOCKER_USER == root ]]; then
    log_warn "No non-root user specified. Docker group config skipped."
    log_warn "Run later: sudo usermod -aG docker YOUR_USERNAME"
    DOCKER_USER=""
    return 0
  fi

  id "$DOCKER_USER" &>/dev/null || die "User '$DOCKER_USER' does not exist" 1

  log_success "Target user: $DOCKER_USER"
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
    if curl -fsSL --connect-timeout 5 --max-time 10 -o /dev/null "$endpoint" 2>/dev/null; then
      log_success "Network connectivity confirmed"
      return 0
    fi
  done

  die "No network connectivity. Please check your internet connection." 1
}

#-------------------------------------------------------------------------------
# Repository Functions
#-------------------------------------------------------------------------------
# Verify Docker repo has packages for codename, find fallback if needed
resolve_codename() {
  local test_url="${DOCKER_REPO_URL}/${DISTRO_BASE}/dists/${DISTRO_CODENAME}/Release"

  if curl -fsSL --head --connect-timeout 5 "$test_url" &>/dev/null; then
    log_debug "Docker repo has packages for $DISTRO_CODENAME"
    EFFECTIVE_CODENAME="$DISTRO_CODENAME"
    return 0
  fi

  log_warn "Docker repo missing packages for '$DISTRO_CODENAME'"
  log_info "Finding compatible fallback..."

  local -a fallbacks
  read -ra fallbacks <<<"${FALLBACK_CODENAMES[$DISTRO_BASE]}"

  for fallback in "${fallbacks[@]}"; do
    test_url="${DOCKER_REPO_URL}/${DISTRO_BASE}/dists/${fallback}/Release"
    if curl -fsSL --head --connect-timeout 5 "$test_url" &>/dev/null; then
      log_warn "Using fallback: $fallback"
      EFFECTIVE_CODENAME="$fallback"
      return 0
    fi
  done

  log_warn "No fallback found, trying $DISTRO_CODENAME anyway"
  EFFECTIVE_CODENAME="$DISTRO_CODENAME"
}

#-------------------------------------------------------------------------------
# Installation Functions
#-------------------------------------------------------------------------------
remove_conflicting_packages() {
  log_step "1/7" "Removing conflicting packages"

  local -a to_remove=()

  for pkg in "${CONFLICTING_PACKAGES[@]}"; do
    is_installed "$pkg" && to_remove+=("$pkg")
  done

  if ((${#to_remove[@]} == 0)); then
    log_success "No conflicting packages found"
    return 0
  fi

  log_info "Removing: ${to_remove[*]}"
  execute apt-get remove -y --purge "${to_remove[@]}" || true
  execute apt-get autoremove -y || true

  log_success "Conflicting packages removed"
}

install_prerequisites() {
  log_step "2/7" "Installing prerequisites"

  log_info "Updating package index..."
  execute apt-get update -qq

  export DEBIAN_FRONTEND=noninteractive

  log_info "Installing: ${PREREQUISITES[*]}"
  execute apt-get install -y -qq "${PREREQUISITES[@]}"

  log_success "Prerequisites installed"
}

setup_docker_repository() {
  log_step "3/7" "Setting up Docker repository"

  local -r keyring_dir="/etc/apt/keyrings"
  local -r keyring_file="$keyring_dir/docker.asc"
  local -r sources_file="/etc/apt/sources.list.d/docker.sources"

  [[ -d $keyring_dir ]] || execute install -m 0755 -d "$keyring_dir"

  log_info "Downloading Docker GPG key..."
  local -r gpg_url="${DOCKER_GPG_URL}/${DISTRO_BASE}/gpg"

  if [[ $DRY_RUN == true ]]; then
    log_info "[DRY-RUN] Would download: $gpg_url"
  else
    retry_with_backoff "$MAX_RETRIES" "$RETRY_DELAY_BASE" \
      curl -fsSL "$gpg_url" -o "$keyring_file"
    chmod a+r "$keyring_file"
    verify_gpg_fingerprint "$keyring_file"
    register_created_file "$keyring_file"
  fi
  # Resolve codename 
  [[ $DRY_RUN != true ]] && resolve_codename

  # Create sources file (DEB822 format)
  log_info "Configuring repository for ${EFFECTIVE_CODENAME:-$DISTRO_CODENAME}..."

  local repo_content
  printf -v repo_content 'Types: deb
URIs: %s/%s
Suites: %s
Components: stable
Signed-By: %s
Architectures: %s' \
    "$DOCKER_REPO_URL" "$DISTRO_BASE" \
    "${EFFECTIVE_CODENAME:-$DISTRO_CODENAME}" \
    "$keyring_file" "$ARCH"

  if [[ $DRY_RUN == true ]]; then
    log_info "[DRY-RUN] Would write to $sources_file"
  else
    [[ -f $sources_file ]] && backup_file "$sources_file"
    printf '%s\n' "$repo_content" >"$sources_file"
    register_created_file "$sources_file"
  fi

  log_info "Updating package index..."
  execute apt-get update -qq

  log_success "Docker repository configured"
}

install_docker_engine() {
  log_step "4/7" "Installing Docker Engine"

  # Check existing installation
  if has_command docker; then
    local current_version
    current_version="$(docker --version 2>/dev/null || echo 'unknown')"
    log_info "Docker already installed: $current_version"

    if docker info &>/dev/null; then
      log_success "Docker is functional - checking for updates..."
    else
      log_warn "Docker installed but not functional - reinstalling..."
    fi
  fi

  export DEBIAN_FRONTEND=noninteractive

  if [[ -n $DOCKER_VERSION ]]; then
    log_info "Installing Docker version: $DOCKER_VERSION"
    local -a versioned_pkgs=()
    local pkg
    for pkg in "${DOCKER_PACKAGES[@]}"; do
      versioned_pkgs+=("${pkg}=${DOCKER_VERSION}")
    done
    execute apt-get install -y -qq "${versioned_pkgs[@]}"
  else
    log_info "Installing: ${DOCKER_PACKAGES[*]}"
    execute apt-get install -y -qq "${DOCKER_PACKAGES[@]}"
  fi

  if [[ $DRY_RUN != true ]]; then
    has_command docker || die "Docker installation failed" 1
    log_success "Docker installed: $(docker --version)"
  else
    log_success "[DRY-RUN] Docker packages would be installed"
  fi
}

configure_iptables() {
  log_step "5/7" "Configuring iptables"

  if [[ $SKIP_IPTABLES == true ]]; then
    log_info "Skipping iptables configuration (--skip-iptables)"
    return 0
  fi

  has_command update-alternatives || {
    log_warn "update-alternatives not available"
    return 0
  }

  # Check current setting
  local current
  current="$(update-alternatives --query iptables 2>/dev/null | awk '/^Value:/{print $2}')" || true

  if [[ $current == *iptables-legacy* ]]; then
    log_success "iptables already set to legacy mode"
    return 0
  fi

  # Check if legacy alternative exists
  if ! update-alternatives --list iptables 2>/dev/null | grep -q iptables-legacy; then
    log_warn "iptables-legacy not available"
    return 0
  fi

  log_info "Setting iptables to legacy mode..."
  execute update-alternatives --set iptables /usr/sbin/iptables-legacy 2>/dev/null || true
  execute update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy 2>/dev/null || true

  log_success "iptables configured"
}

configure_user_group() {
  log_step "6/7" "Configuring user permissions"

  if [[ -z $DOCKER_USER ]]; then
    log_warn "No user specified - skipping"
    return 0
  fi

  # Ensure docker group exists
  getent group docker &>/dev/null || execute groupadd docker

  # Check if already in group
  if user_in_group "$DOCKER_USER" docker; then
    log_success "User '$DOCKER_USER' already in docker group"
    return 0
  fi

  log_info "Adding '$DOCKER_USER' to docker group..."
  execute usermod -aG docker "$DOCKER_USER"

  log_success "User added to docker group"
  log_info "Run 'newgrp docker' or log out/in to apply"
}

configure_systemd() {
  log_step "7/7" "Configuring systemd"

  local -r wsl_conf="/etc/wsl.conf"

  # Check if systemd already enabled
  if [[ -f $wsl_conf ]] && grep -qE '^\s*systemd\s*=\s*true' "$wsl_conf" 2>/dev/null; then
    log_success "systemd already enabled"
  else
    log_info "Enabling systemd in WSL..."

    if [[ $DRY_RUN == true ]]; then
      log_info "[DRY-RUN] Would update $wsl_conf"
    else
      # Backup existing wsl.conf if present
      [[ -f $wsl_conf ]] && backup_file "$wsl_conf"

      if [[ -f $wsl_conf ]]; then
        if grep -qE '^\s*\[boot\]' "$wsl_conf"; then
          if ! grep -qE '^\s*systemd\s*=' "$wsl_conf"; then
            sed -i '/^\s*\[boot\]/a systemd=true' "$wsl_conf"
          else
            sed -i 's/^\s*systemd\s*=.*/systemd=true/' "$wsl_conf"
          fi
        else
          printf '\n[boot]\nsystemd=true\n' >>"$wsl_conf"
        fi
      else
        printf '[boot]\nsystemd=true\n' >"$wsl_conf"
        register_created_file "$wsl_conf"
      fi
      log_success "systemd enabled"
      log_warn "WSL restart required: wsl --shutdown"
    fi
  fi

  # Start Docker if systemd running
  if [[ $DRY_RUN != true ]] && pidof systemd &>/dev/null; then
    log_info "Starting Docker service..."
    execute systemctl enable --now docker.service 2>/dev/null || true
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
  printf '\n%b═══════════════════════════════════════════════════════════════%b\n' "${COLORS[bold]}" "${COLORS[reset]}" | tee -a "$LOG_FILE"
  printf '%b                    VERIFICATION%b\n' "${COLORS[bold]}" "${COLORS[reset]}" | tee -a "$LOG_FILE"
  printf '%b═══════════════════════════════════════════════════════════════%b\n' "${COLORS[bold]}" "${COLORS[reset]}" | tee -a "$LOG_FILE"

  if [[ $DRY_RUN == true ]]; then
    log_info "[DRY-RUN] Verification skipped"
    return 0
  fi

  local -i passed=1

  # Docker CLI
  if has_command docker; then
    log_success "Docker CLI: $(docker --version)"
  else
    log_error "Docker CLI not found"
    passed=0
  fi

  # Docker Compose
  if docker compose version &>/dev/null; then
    log_success "Compose: $(docker compose version --short)"
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
    log_info "Docker service: $status"
  fi

  # Docker socket permissions
  if [[ -S /var/run/docker.sock ]]; then
    local sock_perms
    sock_perms=$(stat -c '%a' /var/run/docker.sock 2>/dev/null || echo 'unknown')
    if [[ $sock_perms == "660" ]]; then
      log_success "Docker socket permissions: $sock_perms"
    else
      log_warn "Docker socket permissions: $sock_perms (expected 660)"
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

#-------------------------------------------------------------------------------
# Summary
#-------------------------------------------------------------------------------
print_summary() {
  printf '\n%b═══════════════════════════════════════════════════════════════%b\n' "${COLORS[bold]}" "${COLORS[reset]}" | tee -a "$LOG_FILE"
  printf '%b                    INSTALLATION COMPLETE%b\n' "${COLORS[bold]}" "${COLORS[reset]}" | tee -a "$LOG_FILE"
  printf '%b═══════════════════════════════════════════════════════════════%b\n' "${COLORS[bold]}" "${COLORS[reset]}" | tee -a "$LOG_FILE"

  [[ $DRY_RUN == true ]] && log_info "Mode: DRY-RUN (no changes made)"

  log_info ""
  log_info "Distribution: $DISTRO_ID $DISTRO_CODENAME ($ARCH)"
  log_info "Repo codename: ${EFFECTIVE_CODENAME:-$DISTRO_CODENAME}"
  log_info "Docker user:  ${DOCKER_USER:-'(none)'}"
  log_info "Log file:     $LOG_FILE"
  log_info ""

  if ! pidof systemd &>/dev/null; then
    log_warn "ACTION REQUIRED: Restart WSL"
    log_warn "  1. Close all WSL terminals"
    log_warn "  2. PowerShell: wsl --shutdown"
    log_warn "  3. Open new WSL terminal"
    log_info ""
  fi

  [[ -n $DOCKER_USER ]] && log_info "Apply group: newgrp docker"
  log_info "Test: docker run hello-world"
}

#-------------------------------------------------------------------------------
# Help
#-------------------------------------------------------------------------------
show_help() {
  cat <<EOF
${COLORS[bold]}$SCRIPT_NAME${COLORS[reset]} v$SCRIPT_VERSION - Docker Engine installer for WSL2

${COLORS[bold]}USAGE:${COLORS[reset]}
    sudo $SCRIPT_NAME [OPTIONS]

${COLORS[bold]}OPTIONS:${COLORS[reset]}
    --user USERNAME    Add user to docker group (default: \$SUDO_USER)
    --skip-iptables    Skip iptables-legacy configuration
    --dry-run          Preview without making changes
    --verbose          Enable verbose output
    --version VERSION  Install specific Docker version
    --syslog           Also log to syslog (for enterprise environments)
    --help             Show this help

${COLORS[bold]}SUPPORTED:${COLORS[reset]}
    Ubuntu/Debian (any version) - auto-detects, falls back if needed

${COLORS[bold]}EXAMPLES:${COLORS[reset]}
    sudo $SCRIPT_NAME
    sudo $SCRIPT_NAME --user myuser --verbose
    sudo $SCRIPT_NAME --dry-run

${COLORS[bold]}ENVIRONMENT:${COLORS[reset]}
    TRACE=1    Enable debug tracing

${COLORS[bold]}LOG:${COLORS[reset]}
    $LOG_FILE

EOF
}

#-------------------------------------------------------------------------------
# Argument Parsing
#-------------------------------------------------------------------------------
parse_arguments() {
  while (($#)); do
    case "$1" in
      --user)
        [[ -n ${2:-} ]] || die "--user requires USERNAME" 1
        validate_username "$2"
        DOCKER_USER="$2"
        shift 2
        ;;
      --user=*)
        DOCKER_USER="${1#*=}"
        validate_username "$DOCKER_USER"
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
      --version)
        [[ -n ${2:-} ]] || die "--version requires VERSION (e.g., 5:24.0.7-1~ubuntu.22.04~jammy)" 1
        DOCKER_VERSION="$2"
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
      --help | -h)
        show_help
        exit 0
        ;;
      -*)
        die "Unknown option: $1 (use --help)" 1
        ;;
      *)
        die "Unexpected argument: $1 (use --help)" 1
        ;;
    esac
  done
}

#-------------------------------------------------------------------------------
# Main
#-------------------------------------------------------------------------------
main() {
  # Initialize logging
  mkdir -p "${LOG_FILE%/*}"
  : >"$LOG_FILE"
  chmod 644 "$LOG_FILE"

  log_info "═══════════════════════════════════════════════════════════════"
  log_info "  Docker Engine WSL2 Installer v$SCRIPT_VERSION"
  log_info "  Bash $BASH_VERSION | Started: $(printf '%(%F %T)T' "$EPOCHSECONDS")"
  log_info "═══════════════════════════════════════════════════════════════"

  [[ $DRY_RUN == true ]] && log_warn "DRY-RUN MODE: No changes will be made"

  setup_signal_handlers

  # Freeze configuration to prevent modification
  readonly DOCKER_USER SKIP_IPTABLES DRY_RUN VERBOSE DOCKER_VERSION SYSLOG

  acquire_lock

  # Validation
  check_root
  check_wsl2
  detect_distribution
  detect_architecture
  validate_user
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
  verify_installation || true
  print_summary

  log_success "Installation completed successfully!"
}

parse_arguments "$@"
main
