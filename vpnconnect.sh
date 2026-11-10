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

# Install prerequisites (gnupg for key handling, lsb-release for codename detection)
timeout 300 sudo apt-get "${APT_OPTS[@]}" update && timeout 300 sudo apt-get "${APT_OPTS[@]}" install -y gnupg lsb-release curl jq

# Detect Ubuntu codename
CODENAME=$(lsb_release -cs)

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
timeout 300 sudo apt-get "${APT_OPTS[@]}" update && timeout 300 sudo apt-get "${APT_OPTS[@]}" install -y pritunl-client

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

for RETRY in $(seq 1 30); do
  sleep 2
  ADDR=$(client_addr || true)
  RUN_STATE=$(pritunl-client list -j | jq -r --arg id "$VPN_ID" '.[] | select(.id == $id) | .run_state' || true)
  echo "Attempt $RETRY: run_state=$RUN_STATE connected=$([[ -n "$ADDR" ]] && echo yes || echo no)"
  if [[ -n "$ADDR" ]]; then
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
