#!/usr/bin/env bash
#
# setup.sh — system update/upgrade + opencode installer
#
# Usage (curl | bash):
#   curl -fsSL https://raw.githubusercontent.com/<user>/<repo>/<branch>/setup.sh | bash
#
# Or download and inspect first (recommended):
#   curl -fsSL -o setup.sh https://raw.githubusercontent.com/<user>/<repo>/<branch>/setup.sh
#   less setup.sh
#   bash setup.sh
#
# Environment overrides:
#   SKIP_SYSTEM_UPDATE=1   Skip the apt update/upgrade stage
#   SKIP_OPENCODE=1        Skip the opencode install stage
#   NONINTERACTIVE=1       Never prompt; assume "yes" (also auto-set when piped)
#   OPENCODE_INSTALL_DIR   Override opencode install dir (default ~/.opencode/bin)
#   SKIP_SSH_KEY=1         Skip copying the SSH private key
#   SSH_KEY_NAME           Key filename (default id_ed25519)
#   SSH_KEY_SRC_DIR        Source dir for the key (default /mnt/shared/Terminal)
#
# Designed to be extended: add new install_* functions and register them
# in the run_stages() list near the bottom.

set -euo pipefail

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
SKIP_SYSTEM_UPDATE="${SKIP_SYSTEM_UPDATE:-0}"
SKIP_OPENCODE="${SKIP_OPENCODE:-0}"
NONINTERACTIVE="${NONINTERACTIVE:-0}"
OPENCODE_INSTALL_URL="https://opencode.ai/install"

# SSH key setup
SKIP_SSH_KEY="${SKIP_SSH_KEY:-0}"
SSH_KEY_NAME="${SSH_KEY_NAME:-id_ed25519}"
SSH_KEY_SRC_DIR="${SSH_KEY_SRC_DIR:-/mnt/shared/Terminal}"

# If stdin is not a TTY (e.g. piped from curl), force non-interactive mode.
if [ ! -t 0 ]; then
  NONINTERACTIVE=1
fi

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RESET=$'\033[0m'; C_BLUE=$'\033[1;34m'; C_GREEN=$'\033[1;32m'
  C_YELLOW=$'\033[1;33m'; C_RED=$'\033[1;31m'
else
  C_RESET=''; C_BLUE=''; C_GREEN=''; C_YELLOW=''; C_RED=''
fi

log()   { printf '%s==>%s %s\n' "$C_BLUE"  "$C_RESET" "$*"; }
ok()    { printf '%s ok%s  %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn()  { printf '%swarn%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
err()   { printf '%serr%s  %s\n' "$C_RED"   "$C_RESET" "$*" >&2; }
die()   { err "$*"; exit 1; }

# ---------------------------------------------------------------------------
# Utilities
# ---------------------------------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }

# Resolve a privilege-escalation command. Empty if already root.
SUDO=""
resolve_sudo() {
  if [ "$(id -u)" -eq 0 ]; then
    SUDO=""
  elif have sudo; then
    SUDO="sudo"
  else
    die "This script needs root privileges and 'sudo' is not installed. Re-run as root."
  fi
}

# Run a command with elevated privileges.
as_root() {
  if [ -n "$SUDO" ]; then
    "$SUDO" "$@"
  else
    "$@"
  fi
}

confirm() {
  # confirm "Question?" -> returns 0 for yes, 1 for no
  local prompt="${1:-Continue?}"
  if [ "$NONINTERACTIVE" -eq 1 ]; then
    return 0
  fi
  local reply
  printf '%s [Y/n] ' "$prompt"
  read -r reply || reply=""
  case "$reply" in
    ""|[Yy]|[Yy][Ee][Ss]) return 0 ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# Stage: system update / upgrade (Debian/apt)
# ---------------------------------------------------------------------------
update_system() {
  if [ "$SKIP_SYSTEM_UPDATE" -eq 1 ]; then
    warn "Skipping system update (SKIP_SYSTEM_UPDATE=1)."
    return 0
  fi

  if ! have apt-get; then
    warn "apt-get not found; this stage targets Debian/Ubuntu. Skipping system update."
    return 0
  fi

  log "Updating package lists..."
  as_root env DEBIAN_FRONTEND=noninteractive apt-get update

  log "Upgrading installed packages..."
  as_root env DEBIAN_FRONTEND=noninteractive apt-get -y upgrade

  log "Removing unused packages..."
  as_root env DEBIAN_FRONTEND=noninteractive apt-get -y autoremove

  ok "System packages updated and upgraded."
}

# ---------------------------------------------------------------------------
# Stage: ensure base dependencies the opencode installer needs
# ---------------------------------------------------------------------------
ensure_dependencies() {
  if ! have apt-get; then
    return 0
  fi
  local missing=()
  have curl || missing+=("curl")
  have unzip || missing+=("unzip")
  if [ "${#missing[@]}" -gt 0 ]; then
    log "Installing prerequisites: ${missing[*]}"
    as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
  fi
}

# ---------------------------------------------------------------------------
# Stage: install latest stable opencode
# ---------------------------------------------------------------------------
install_opencode() {
  if [ "$SKIP_OPENCODE" -eq 1 ]; then
    warn "Skipping opencode install (SKIP_OPENCODE=1)."
    return 0
  fi

  if have opencode; then
    local current
    current="$(opencode --version 2>/dev/null || echo 'unknown')"
    log "opencode already installed (version: ${current}); re-running installer to update."
  fi

  have curl || die "curl is required to install opencode but was not found."

  log "Installing latest stable opencode from ${OPENCODE_INSTALL_URL} ..."

  # opencode installs per-user (default ~/.opencode/bin); no root needed.
  # Set OPENCODE_INSTALL_DIR to override the destination.
  if [ -n "${OPENCODE_INSTALL_DIR:-}" ]; then
    if env OPENCODE_INSTALL_DIR="$OPENCODE_INSTALL_DIR" \
         bash -c "curl -fsSL '$OPENCODE_INSTALL_URL' | bash"; then
      ok "opencode installer finished."
    else
      die "opencode installation failed."
    fi
  else
    if curl -fsSL "$OPENCODE_INSTALL_URL" | bash; then
      ok "opencode installer finished."
    else
      die "opencode installation failed."
    fi
  fi

  if have opencode; then
    ok "opencode is available: $(opencode --version 2>/dev/null || echo 'installed')"
  else
    warn "opencode installed but is not on the current PATH."
    warn "Open a new shell, or add its bin dir to PATH (default: \$HOME/.opencode/bin)."
  fi
}

# ---------------------------------------------------------------------------
# Stage: install SSH private key from the shared folder
# ---------------------------------------------------------------------------
setup_ssh_key() {
  if [ "$SKIP_SSH_KEY" -eq 1 ]; then
    warn "Skipping SSH key setup (SKIP_SSH_KEY=1)."
    return 0
  fi

  local src="${SSH_KEY_SRC_DIR%/}/${SSH_KEY_NAME}"
  local ssh_dir="${HOME}/.ssh"
  local dest="${ssh_dir}/${SSH_KEY_NAME}"

  if [ ! -f "$src" ]; then
    warn "SSH key not found at ${src}; skipping key setup."
    return 0
  fi

  log "Installing SSH private key from ${src} ..."

  # Ensure ~/.ssh exists with correct (private) permissions.
  mkdir -p "$ssh_dir"
  chmod 700 "$ssh_dir"

  if [ -f "$dest" ]; then
    if ! confirm "Key already exists at ${dest}. Overwrite?"; then
      warn "Keeping existing key; skipping copy."
      chmod 600 "$dest" 2>/dev/null || true
      return 0
    fi
  fi

  # Copy (not move) so the source on the shared mount stays intact.
  cp -f "$src" "$dest"
  chmod 600 "$dest"

  # If a matching public key is present alongside it, install that too.
  if [ -f "${src}.pub" ]; then
    cp -f "${src}.pub" "${dest}.pub"
    chmod 644 "${dest}.pub"
    ok "Public key installed at ${dest}.pub"
  fi

  ok "SSH private key installed at ${dest} (chmod 600)."
}

# ---------------------------------------------------------------------------
# Orchestration
# ---------------------------------------------------------------------------
run_stages() {
  # Add new stages here as the project grows.
  update_system
  ensure_dependencies
  install_opencode
  setup_ssh_key
}

main() {
  log "Starting setup..."

  # sudo is only needed for the apt system-update stage; opencode installs
  # per-user without root. Skip the sudo check entirely when system update
  # is disabled.
  if [ "$SKIP_SYSTEM_UPDATE" -ne 1 ]; then
    resolve_sudo
  fi

  if ! confirm "This will update system packages (sudo) and install opencode (per-user). Proceed?"; then
    die "Aborted by user."
  fi

  run_stages

  ok "All done."
}

main "$@"
