#! /bin/bash

# Map Variables
INPUT_VPN_CONFIG=$1
INPUT_VPN_PASS=$2

# Get VPN Config File
echo $INPUT_VPN_CONFIG | base64 -d - >pritunl-config.ovpn && tar --create --file=pritunl-config.tar pritunl-config.ovpn

# Install VPN Client
sudo tee /etc/apt/sources.list.d/pritunl.list <<EOF
deb https://repo.pritunl.com/stable/apt jammy main
EOF
gpg --keyserver hkp://keyserver.ubuntu.com --recv-keys 7568D9BB55FF9E5287D586017AE645C0CF8E292A
gpg --armor --export 7568D9BB55FF9E5287D586017AE645C0CF8E292A | sudo tee /etc/apt/trusted.gpg.d/pritunl.asc
sudo apt-get update && sudo apt-get install -y pritunl-client

# Add VPN Config to Pritunl Client
pritunl-client add pritunl-config.tar

# Connect to VPN Server
VPN_ID=$(pritunl-client list | sed -n '4p' | awk -F '|' '{ print $2 }' | xargs) && echo "VPN_ID: $VPN_ID"
pritunl-client start $VPN_ID -p $INPUT_VPN_PASS
sleep 10
RETRY=0

while [ $RETRY -lt 5 ]; do
	sleep 10
	((RETRY += 1))
	echo "Retry Connection: $RETRY"
	STATUS=$(pritunl-client list | sed -n '4p' | awk -F '|' '{ print $6 }' | xargs)
	if [ "$STATUS" != "Connecting" ]; then
		STATUS="true"
		break
	fi
done

if [ "$STATUS" = "true" ]; then
	echo "Connection success"
else
	echo "Unable to connect"
	exit 1
fi
