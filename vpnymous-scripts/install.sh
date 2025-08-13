#!/bin/bash

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   print_error "This script must be run as root"
   exit 1
fi

# Check if required parameters are provided
if [ "$#" -ne 2 ]; then
    print_error "Usage: $0 <subdomain> <cloudflare_api_token>"
    print_error "Example: $0 main cf_token_here"
    exit 1
fi

SUBDOMAIN=$1
CF_API_TOKEN=$2
DOMAIN="vpnymous.net"
FULL_DOMAIN="${SUBDOMAIN}.${DOMAIN}"

print_status "Starting VPNymous server installation..."
print_status "Subdomain: ${FULL_DOMAIN}"

# Validate inputs
if [[ ! $SUBDOMAIN =~ ^[a-zA-Z0-9-]+$ ]]; then
    print_error "Invalid subdomain format"
    exit 1
fi

if [[ ${#CF_API_TOKEN} -lt 10 ]]; then
    print_error "Invalid Cloudflare API token"
    exit 1
fi

print_status "Step 1: Input validation completed"

# Function to create Cloudflare DNS record
create_dns_record() {
    print_status "Step 2: Creating DNS record for ${FULL_DOMAIN}"
    
    # Get server's public IP
    SERVER_IP=$(curl -s ifconfig.me)
    if [[ -z "$SERVER_IP" ]]; then
        print_error "Failed to get server IP"
        exit 1
    fi
    
    print_status "Server IP: ${SERVER_IP}"
    
    # Get zone ID for vpnymous.net
    ZONE_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=${DOMAIN}" \
        -H "Authorization: Bearer ${CF_API_TOKEN}" \
        -H "Content-Type: application/json" | \
        grep -Po '"id":"\K[^"]*' | head -1)
    
    if [[ -z "$ZONE_ID" ]]; then
        print_error "Failed to get Cloudflare zone ID for ${DOMAIN}"
        exit 1
    fi
    
    print_status "Zone ID: ${ZONE_ID}"
    
    # Check if record already exists
    EXISTING_RECORD=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records?name=${FULL_DOMAIN}&type=A" \
        -H "Authorization: Bearer ${CF_API_TOKEN}" \
        -H "Content-Type: application/json")
    
    EXISTING_IP=$(echo "$EXISTING_RECORD" | grep -Po '"content":"\K[^"]*' | head -1)
    
    if [[ -n "$EXISTING_IP" ]]; then
        if [[ "$EXISTING_IP" == "$SERVER_IP" ]]; then
            print_status "DNS record already exists with correct IP: ${EXISTING_IP}"
            return 0
        else
            print_warning "DNS record exists with different IP: ${EXISTING_IP}, updating to ${SERVER_IP}"
            RECORD_ID=$(echo "$EXISTING_RECORD" | grep -Po '"id":"\K[^"]*' | head -1)
            
            # Update existing record
            CF_RESPONSE=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records/${RECORD_ID}" \
                -H "Authorization: Bearer ${CF_API_TOKEN}" \
                -H "Content-Type: application/json" \
                --data "{\"type\":\"A\",\"name\":\"${SUBDOMAIN}\",\"content\":\"${SERVER_IP}\",\"ttl\":300}")
        fi
    else
        # Create new A record
        CF_RESPONSE=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records" \
            -H "Authorization: Bearer ${CF_API_TOKEN}" \
            -H "Content-Type: application/json" \
            --data "{\"type\":\"A\",\"name\":\"${SUBDOMAIN}\",\"content\":\"${SERVER_IP}\",\"ttl\":300}")
    fi
    
    # Check if successful
    if echo "$CF_RESPONSE" | grep -q '"success":true'; then
        print_status "DNS record configured successfully"
    else
        print_error "Failed to configure DNS record"
        echo "$CF_RESPONSE"
        exit 1
    fi
}

# Install required packages
print_status "Installing required packages..."
apt update -qq
apt install -y curl jq

# Create DNS record
create_dns_record

# Function to setup SSL certificates
setup_ssl_certificates() {
    print_status "Step 3: Setting up SSL certificates"
    
    # Check if certificate already exists
    if [[ -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" && -f "/etc/letsencrypt/live/${DOMAIN}/privkey.pem" ]]; then
        print_status "SSL certificate already exists for ${DOMAIN}"
        
        # Check if certificate is valid and not expiring soon (30 days)
        if openssl x509 -checkend 2592000 -noout -in "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" >/dev/null 2>&1; then
            print_status "Existing certificate is valid, skipping certificate generation"
            setup_auto_renewal
            return 0
        else
            print_warning "Certificate expires soon, will renew"
        fi
    fi
    
    # Install certbot and cloudflare plugin
    apt install -y certbot python3-certbot-dns-cloudflare openssl
    
    # Create cloudflare credentials file
    mkdir -p /root/.secrets
    cat > /root/.secrets/cloudflare.ini << EOF
dns_cloudflare_api_token = ${CF_API_TOKEN}
EOF
    chmod 600 /root/.secrets/cloudflare.ini
    
    # Get wildcard certificate for *.vpnymous.net
    print_status "Requesting SSL certificate for *.${DOMAIN}"
    
    certbot certonly \
        --dns-cloudflare \
        --dns-cloudflare-credentials /root/.secrets/cloudflare.ini \
        --dns-cloudflare-propagation-seconds 60 \
        --agree-tos \
        --email ramtin@skiff.com \
        --non-interactive \
        -d "*.${DOMAIN}" \
        -d "${DOMAIN}"
    
    if [[ $? -eq 0 ]]; then
        print_status "SSL certificate obtained successfully"
    else
        print_error "Failed to obtain SSL certificate"
        exit 1
    fi
    
    setup_auto_renewal
}

# Function to setup auto-renewal
setup_auto_renewal() {
    print_status "Setting up SSL auto-renewal"
    
    # Check if cron job already exists
    if crontab -l 2>/dev/null | grep -q "certbot renew"; then
        print_status "Auto-renewal already configured"
        return 0
    fi
    
    # Add renewal cron job (runs twice daily)
    (crontab -l 2>/dev/null; echo "0 0,12 * * * /usr/bin/certbot renew --quiet --post-hook 'docker restart \$(docker ps -q --filter name=marznode) 2>/dev/null || true'") | crontab -
    
    print_status "SSL auto-renewal configured"
}

# Wait for DNS propagation
print_status "Waiting 60 seconds for DNS propagation..."
sleep 60

# Setup SSL certificates
setup_ssl_certificates

# Function to install Marzneshin
install_marzneshin() {
    print_status "Step 4: Installing Marzneshin"
    
    # Check if already installed
    if [[ -f "/etc/opt/marzneshin/docker-compose.yml" ]]; then
        print_status "Marzneshin already installed, skipping installation"
        return 0
    fi
    
    # Download and run Marzneshin installation script
    print_status "Downloading Marzneshin installation script"
    
    # Install dependencies
    apt install -y wget docker.io docker-compose
    
    # Start docker service
    systemctl enable docker
    systemctl start docker
    
    # Use local installation script
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    MARZNESHIN_SCRIPT="${SCRIPT_DIR}/../script.sh"
    
    if [[ ! -f "$MARZNESHIN_SCRIPT" ]]; then
        print_error "Marzneshin script not found at ${MARZNESHIN_SCRIPT}"
        exit 1
    fi
    
    # Run installation with MariaDB
    print_status "Running Marzneshin installation with MariaDB"
    bash "$MARZNESHIN_SCRIPT" install --database mariadb
    
    if [[ $? -eq 0 ]]; then
        print_status "Marzneshin installed successfully"
    else
        print_error "Failed to install Marzneshin"
        exit 1
    fi
    
    # Clean up
    rm -f /tmp/marzneshin_install.sh
}

# Install Marzneshin
install_marzneshin

# Function to configure certificates and docker-compose
configure_certificates() {
    print_status "Step 5: Configuring certificates and docker-compose"
    
    # Create marznode directory
    mkdir -p /var/lib/marznode
    
    # Copy SSL certificates to marznode directory
    if [[ -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" && -f "/etc/letsencrypt/live/${DOMAIN}/privkey.pem" ]]; then
        cp "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" /var/lib/marznode/
        cp "/etc/letsencrypt/live/${DOMAIN}/privkey.pem" /var/lib/marznode/
        print_status "SSL certificates copied to /var/lib/marznode/"
    else
        print_error "SSL certificates not found"
        exit 1
    fi
    
    # Update docker-compose.yml SSL paths
    if [[ -f "/etc/opt/marzneshin/docker-compose.yml" ]]; then
        print_status "Updating docker-compose.yml SSL certificate paths"
        
        sed -i 's|SSL_KEY_FILE: "./server.key"|SSL_KEY_FILE: "./privkey.pem"|g' /etc/opt/marzneshin/docker-compose.yml
        sed -i 's|SSL_CERT_FILE: "./server.cert"|SSL_CERT_FILE: "./fullchain.pem"|g' /etc/opt/marzneshin/docker-compose.yml
        
        print_status "Docker-compose.yml updated"
    else
        print_error "Docker-compose.yml not found"
        exit 1
    fi
}

# Configure certificates
configure_certificates

# Function to create xray configuration
create_xray_config() {
    print_status "Step 6: Creating xray configuration"
    
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    TEMPLATE_FILE="${SCRIPT_DIR}/configs/xray_config_template.json"
    
    if [[ ! -f "$TEMPLATE_FILE" ]]; then
        print_error "Xray config template not found at ${TEMPLATE_FILE}"
        exit 1
    fi
    
    # Create xray config from template
    print_status "Creating xray_config.json for ${FULL_DOMAIN}"
    
    sed "s/PLACEHOLDER_DOMAIN/${FULL_DOMAIN}/g" "$TEMPLATE_FILE" > /var/lib/marznode/xray_config.json
    
    if [[ -f "/var/lib/marznode/xray_config.json" ]]; then
        print_status "Xray configuration created successfully"
    else
        print_error "Failed to create xray configuration"
        exit 1
    fi
}

# Function to restart services
restart_services() {
    print_status "Step 7: Starting services"
    
    cd /etc/opt/marzneshin
    
    # Try docker compose (new) or docker-compose (old)
    if command -v docker &> /dev/null; then
        if docker compose version &> /dev/null; then
            docker compose up -d
        elif command -v docker-compose &> /dev/null; then
            docker-compose up -d
        else
            print_error "Neither 'docker compose' nor 'docker-compose' found"
            exit 1
        fi
    else
        print_error "Docker not found"
        exit 1
    fi
    
    print_status "Services started successfully"
    print_status "Installation completed!"
    print_status "Access panel at: https://${FULL_DOMAIN}:8000"
}

# Create xray configuration
create_xray_config

# Restart services
restart_services