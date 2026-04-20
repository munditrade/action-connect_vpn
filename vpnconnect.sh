#!/bin/bash
set -e

# Map Variables
INPUT_VPN_CONFIG=$1
INPUT_VPN_PASS=$2

# Get VPN Config File
echo $INPUT_VPN_CONFIG | base64 -d - >pritunl-config.ovpn && tar --create --file=pritunl-config.tar pritunl-config.ovpn

# Install prerequisites (gnupg for key handling, lsb-release for codename detection)
sudo apt-get update && sudo apt-get install -y gnupg lsb-release curl

# Detect Ubuntu codename
CODENAME=$(lsb_release -cs)

# Set up modern keyring directory
sudo mkdir -p /etc/apt/keyrings

# Import GPG key via HTTPS (avoids HKP port 11371 which is blocked on some runners)
curl -fsSL "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x7568D9BB55FF9E5287D586017AE645C0CF8E292A" \
  | gpg --dearmor \
  | sudo tee /etc/apt/keyrings/pritunl.gpg > /dev/null
sudo chmod 644 /etc/apt/keyrings/pritunl.gpg

# Add Pritunl repository with signed-by for modern apt
sudo tee /etc/apt/sources.list.d/pritunl.list <<EOF
deb [signed-by=/etc/apt/keyrings/pritunl.gpg] https://repo.pritunl.com/stable/apt $CODENAME main
EOF

# Install VPN Client
sudo apt-get update && sudo apt-get install -y pritunl-client

# Verify pritunl-client was installed
if ! command -v pritunl-client &>/dev/null; then
  echo "Error: pritunl-client installation failed"
  exit 1
fi

# Add VPN Config to Pritunl Client
pritunl-client add pritunl-config.tar

# Connect to VPN Server
VPN_ID=$(pritunl-client list | sed -n '4p' | awk -F '|' '{ print $2 }' | xargs) && echo "VPN_ID: $VPN_ID"
pritunl-client start $VPN_ID -p $INPUT_VPN_PASS
sleep 10
RETRY=0

while [ $RETRY -lt 10 ]; do
  sleep 5
  ((RETRY += 1))
  echo "Retry Connection: $RETRY"
  STATUS=$(pritunl-client list | sed -n '4p' | awk -F '|' '{ print $6 }' | xargs)
  echo "Status: $STATUS"
  if [ "$STATUS" = "Connected" ]; then
    break
  fi
done

if [ "$STATUS" = "Connected" ]; then
  echo "Connection success"
else
  echo "Unable to connect, last status: $STATUS"
  exit 1
fi
