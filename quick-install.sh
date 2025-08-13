#!/bin/bash

# VPNymous Infrastructure Quick Installer
# Usage: curl -sL https://github.com/netadminplus/vpnymous-infrastructure/raw/main/quick-install.sh | sudo bash -s subdomain cf_token

set -e

if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root"
   exit 1
fi

if [[ $# -ne 2 ]]; then
    echo "Usage: curl -sL https://github.com/netadminplus/vpnymous-infrastructure/raw/main/quick-install.sh | sudo bash -s <subdomain> <cloudflare_token>"
    echo "Example: curl -sL https://github.com/netadminplus/vpnymous-infrastructure/raw/main/quick-install.sh | sudo bash -s main your_cf_token"
    exit 1
fi

SUBDOMAIN=$1
CF_TOKEN=$2

echo "Installing VPNymous infrastructure..."
echo "Subdomain: ${SUBDOMAIN}.vpnymous.net"

# Install git if not present
apt update -qq
apt install -y git

# Clone repository
cd /tmp
rm -rf vpnymous-infrastructure
git clone https://github.com/netadminplus/vpnymous-infrastructure.git
cd vpnymous-infrastructure/vpnymous-scripts

# Make executable and run
chmod +x install.sh
./install.sh "$SUBDOMAIN" "$CF_TOKEN"

echo "Installation completed!"
echo "Clean up temporary files..."
cd /
rm -rf /tmp/vpnymous-infrastructure

echo "VPNymous infrastructure is ready!"
echo "Access panel at: https://${SUBDOMAIN}.vpnymous.net:8000"