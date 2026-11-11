#!/bin/bash
set -eo pipefail

# Apt options: timeout after 30s per request, retry up to 3 times.
# Prevents jobs from hanging for hours when a mirror is unresponsive.
APT_OPTS=(-o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30 -o Acquire::Retries=3)

# Map Variables
INPUT_VPN_CONFIG=$1
INPUT_VPN_PASS=$2

# Get VPN Config File
echo $INPUT_VPN_CONFIG | base64 -d - >pritunl-config.ovpn && tar --create --file=pritunl-config.tar pritunl-config.ovpn

# Detect Ubuntu codename
. /etc/os-release
CODENAME=$VERSION_CODENAME

# Third-party Ubuntu mirrors on their own domains, used when Canonical's are
# unreachable (2026-11-11: archive/security.ubuntu.com DNS outage). apt still
# checks the Ubuntu archive signature, so a mirror cannot alter packages.
FALLBACK_MIRRORS=(https://mirrors.edge.kernel.org/ubuntu https://mirror.us.leaseweb.net/ubuntu https://mirrors.mit.edu/ubuntu)

apt_install() {
  if curl -fsS -m 10 -o /dev/null "http://archive.ubuntu.com/ubuntu/dists/$CODENAME/InRelease"; then
    timeout 300 sudo apt-get "${APT_OPTS[@]}" update && timeout 300 sudo apt-get "${APT_OPTS[@]}" install -y "$@" && return 0
  fi
  local dir opts
  dir=$(mktemp -d)
  [[ -f /etc/apt/sources.list.d/pritunl.list ]] && cp /etc/apt/sources.list.d/pritunl.list "$dir/"
  for MIRROR in "${FALLBACK_MIRRORS[@]}"; do
    curl -fsS -m 10 -o /dev/null "$MIRROR/dists/$CODENAME/InRelease" || continue
    echo "Ubuntu mirrors unreachable, installing from $MIRROR"
    printf 'Types: deb\nURIs: %s\nSuites: %s %s-updates %s-security\nComponents: main universe\nSigned-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg\n' \
      "$MIRROR" "$CODENAME" "$CODENAME" "$CODENAME" > "$dir/ubuntu-fallback.sources"
    opts=("${APT_OPTS[@]}" -o Dir::Etc::SourceList=/dev/null -o Dir::Etc::SourceParts="$dir")
    timeout 300 sudo apt-get "${opts[@]}" update && timeout 300 sudo apt-get "${opts[@]}" install -y "$@" && return 0
  done
  return 1
}

# Prerequisites ship with the GitHub runner images; install only what is missing.
MISSING=()
command -v gpg &>/dev/null || MISSING+=(gnupg)
command -v curl &>/dev/null || MISSING+=(curl)
command -v jq &>/dev/null || MISSING+=(jq)
if (( ${#MISSING[@]} )); then
  apt_install "${MISSING[@]}" || true
fi

# Set up modern keyring directory
sudo mkdir -p /etc/apt/keyrings

# Pritunl repo key is vendored (pritunl_repo_pub.asc, fingerprint
# 7568D9BB55FF9E5287D586017AE645C0CF8E292A) so the install does not depend on
# keyserver.ubuntu.com, which times out from the runners and left an empty keyring.
KEY_SRC="$(dirname "$(readlink -f "$0")")/pritunl_repo_pub.asc"
gpg --dearmor < "$KEY_SRC" | sudo tee /etc/apt/keyrings/pritunl.gpg > /dev/null
sudo chmod 644 /etc/apt/keyrings/pritunl.gpg
if ! gpg --show-keys --with-colons /etc/apt/keyrings/pritunl.gpg | grep -q '^fpr:.*7568D9BB55FF9E5287D586017AE645C0CF8E292A'; then
  echo "Error: Pritunl repo key fingerprint mismatch"
  exit 1
fi

# Add Pritunl repository with signed-by for modern apt
sudo tee /etc/apt/sources.list.d/pritunl.list <<EOF
deb [signed-by=/etc/apt/keyrings/pritunl.gpg] https://repo.pritunl.com/stable/apt $CODENAME main
EOF

# Install VPN Client
apt_install pritunl-client || true

# Verify pritunl-client was installed
if ! command -v pritunl-client &>/dev/null; then
  echo "Error: pritunl-client installation failed"
  exit 1
fi

# Add VPN Config to Pritunl Client
pritunl-client add pritunl-config.tar

# Connect to VPN Server
# Read state from JSON: the table's 6th column is "Autostart" (always "Disabled"),
# so the old check reported success even when the tunnel never came up.
VPN_ID=$(pritunl-client list -j | jq -r '.[0].id') && echo "VPN_ID: $VPN_ID"
pritunl-client start "$VPN_ID" -p "$INPUT_VPN_PASS"

client_addr() {
  pritunl-client list -j | jq -r --arg id "$VPN_ID" '.[] | select(.id == $id) | .client_address // empty'
}

# openvpn >= 2.7 (Ubuntu 26.04) applies the pushed DNS to tun* with domain "~.",
# hijacking all runner lookups right after connect ("Resolving timed out").
# The VPN only pushes a public resolver, so keep the runner's DNS as on 2.6.
restore_runner_dns() {
  command -v resolvectl &>/dev/null || return 0
  for IFACE in $(ip -o link show | awk -F': ' '$2 ~ /^tun/ {print $2}'); do
    sudo resolvectl revert "$IFACE" || true
  done
  sudo resolvectl flush-caches || true
}

for RETRY in $(seq 1 30); do
  sleep 2
  ADDR=$(client_addr || true)
  RUN_STATE=$(pritunl-client list -j | jq -r --arg id "$VPN_ID" '.[] | select(.id == $id) | .run_state' || true)
  echo "Attempt $RETRY: run_state=$RUN_STATE connected=$([[ -n "$ADDR" ]] && echo yes || echo no)"
  if [[ -n "$ADDR" ]]; then
    restore_runner_dns
    echo "Connection success"
    exit 0
  fi
done

echo "::error::VPN did not connect (no client address after 60s)"
# Diagnostics expose server/client addresses and routes: only on "Re-run with debug logging".
if [[ "${RUNNER_DEBUG:-}" == "1" ]]; then
  echo "::group::pritunl-client diagnostics"
  pritunl-client list || true
  pritunl-client logs "$VPN_ID" || true
  sudo journalctl -u pritunl-client --no-pager -n 200 || true
  openvpn --version | head -1 || true
  ip -br addr || true
  resolvectl status || true
  echo "::endgroup::"
else
  echo "Re-run the job with debug logging enabled to print pritunl/openvpn diagnostics."
fi
exit 1
