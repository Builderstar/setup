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
#   SKIP_WIREGUARD=1       Skip the WireGuard setup stage
#   WG_SRC_DIR             Source dir for wg keys + conf (default /mnt/shared/Terminal)
#   WG_DIR                 WireGuard config dir (default /etc/wireguard)
#   WG_IFACE               WireGuard interface name (default wg0)
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

# WireGuard setup
SKIP_WIREGUARD="${SKIP_WIREGUARD:-0}"
WG_SRC_DIR="${WG_SRC_DIR:-/mnt/shared/Terminal}"   # source for wg keys + conf
WG_DIR="${WG_DIR:-/etc/wireguard}"
WG_IFACE="${WG_IFACE:-wg0}"

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
# Stage: WireGuard tunnel setup
#
# Copies wg-privatekey, wg-publickey, and wg0.conf from the shared folder into
# /etc/wireguard, sets permissions, and brings up the tunnel. The copied
# wg0.conf is the single source of truth for relay/peer details, so no
# infrastructure values are baked into this script.
# ---------------------------------------------------------------------------
setup_wireguard() {
  if [ "$SKIP_WIREGUARD" -eq 1 ]; then
    warn "Skipping WireGuard setup (SKIP_WIREGUARD=1)."
    return 0
  fi

  local src_dir="${WG_SRC_DIR%/}"
  local src_priv="${src_dir}/wg-privatekey"
  local src_pub="${src_dir}/wg-publickey"
  local src_conf="${src_dir}/wg0.conf"
  local conf_dest="${WG_DIR}/${WG_IFACE}.conf"

  # The config file is mandatory; keys are expected alongside it.
  if [ ! -f "$src_conf" ]; then
    warn "No wg0.conf found at ${src_conf}; skipping WireGuard setup."
    return 0
  fi

  # WireGuard install + service control needs root.
  resolve_sudo

  if ! have wg; then
    if have apt-get; then
      log "Installing wireguard..."
      as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y wireguard
    else
      warn "'wg' not found and apt-get unavailable; cannot install WireGuard. Skipping."
      return 0
    fi
  fi

  log "Installing WireGuard config and keys into ${WG_DIR} ..."
  as_root install -d -m 700 "$WG_DIR"

  # Back up an existing conf before overwriting.
  if as_root test -f "$conf_dest"; then
    as_root cp -a "$conf_dest" "${conf_dest}.bak.$(date +%s)"
    log "Backed up existing ${conf_dest}"
  fi

  # Copy the config (source of truth for the tunnel).
  as_root cp -f "$src_conf" "$conf_dest"
  as_root chmod 600 "$conf_dest"

  # Copy keys if present (config may embed the key inline, so these are optional).
  if [ -f "$src_priv" ]; then
    as_root cp -f "$src_priv" "${WG_DIR}/privatekey"
    as_root chmod 600 "${WG_DIR}/privatekey"
    ok "Private key installed (chmod 600)."
  else
    warn "No wg-privatekey at ${src_priv}; relying on key embedded in wg0.conf."
  fi
  if [ -f "$src_pub" ]; then
    as_root cp -f "$src_pub" "${WG_DIR}/publickey"
    as_root chmod 644 "${WG_DIR}/publickey"
    ok "Public key installed (chmod 644)."
  fi

  # Ensure the kernel module loads on boot.
  as_root bash -c 'echo wireguard > /etc/modules-load.d/wireguard.conf'

  # Enable on boot and (re)start the tunnel.
  log "Enabling and starting wg-quick@${WG_IFACE} ..."
  as_root systemctl enable "wg-quick@${WG_IFACE}" >/dev/null 2>&1 || true
  if as_root systemctl restart "wg-quick@${WG_IFACE}"; then
    sleep 2
    ok "WireGuard interface ${WG_IFACE} is up."
    as_root wg show "$WG_IFACE" 2>/dev/null || true
  else
    warn "Failed to start wg-quick@${WG_IFACE}; check ${conf_dest} and 'systemctl status wg-quick@${WG_IFACE}'."
  fi
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
  setup_wireguard
}

main() {
  log "Starting setup..."

  # sudo is only needed for the apt system-update stage; opencode installs
  # per-user without root. Skip the sudo check entirely when system update
  # is disabled.
  if [ "$SKIP_SYSTEM_UPDATE" -ne 1 ]; then
    resolve_sudo
  fi

  if ! confirm "This will update packages, install opencode, set up the SSH key, and configure WireGuard. Proceed?"; then
    die "Aborted by user."
  fi

  run_stages

  ok "All done."
}

main "$@"
