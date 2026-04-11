#!/bin/bash

# VPN Dual Setup Installation Script
# Installs WireGuard and OpenVPN with custom routing configuration
# Run as root or with sudo

set -e  # Exit on error

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${GREEN}[+]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[!]${NC} $1"
}

print_error() {
    echo -e "${RED}[-]${NC} $1"
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   print_error "This script must be run as root or with sudo"
   exit 1
fi

# Configuration variables
WG_INTERFACE="wg0"
WG_CONFIG="/etc/wireguard/wg0.conf"
OVPN_DIR="/etc/openvpn/server"
OVPN_CONFIG="$OVPN_DIR/server.conf"
OVPN_UP_SCRIPT="$OVPN_DIR/ovpn-wg-up.sh"
OVPN_DOWN_SCRIPT="$OVPN_DIR/ovpn-wg-down.sh"
PUBLIC_IP=$(curl -s ifconfig.me || echo "194.87.103.131")

print_status "Starting VPN Dual Setup Installation"
print_status "Detected Public IP: $PUBLIC_IP"

# Update system
print_status "Updating system packages..."
apt-get update -y
apt-get upgrade -y

# Install required packages
print_status "Installing required packages..."
apt-get install -y \
    wireguard \
    wireguard-tools \
    openvpn \
    easy-rsa \
    iptables \
    curl \
    resolvconf \
    ufw \
    net-tools

# Load WireGuard kernel module
print_status "Loading WireGuard kernel module..."
modprobe wireguard || print_warning "WireGuard module not available (common in OpenVZ/LXC)"

# Enable IP forwarding permanently
print_status "Configuring IP forwarding..."
sed -i 's/#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/' /etc/sysctl.conf
sed -i 's/net.ipv4.ip_forward=0/net.ipv4.ip_forward=1/' /etc/sysctl.conf

# Configure reverse path filtering
cat >> /etc/sysctl.conf << 'EOF'

# VPN routing optimization
net.ipv4.conf.all.rp_filter=0
net.ipv4.conf.default.rp_filter=0
net.ipv4.conf.tun0.rp_filter=0
net.ipv4.conf.wg0.rp_filter=0
EOF

# Apply sysctl settings
sysctl -p || print_warning "Could not apply all sysctl settings"

# ==================== WIREGUARD SETUP ====================
print_status "Setting up WireGuard..."

# Create WireGuard directory if it doesn't exist
mkdir -p /etc/wireguard
chmod 700 /etc/wireguard

# Create WireGuard configuration
print_status "Creating WireGuard configuration..."
cat > $WG_CONFIG << 'EOF'
[Interface]
PrivateKey = sBk4yUN4/YEVRQwcn4mMgtzK4X2fPtyv6HGK423pB14=
Address = 10.10.10.2/24
ListenPort = 44450
Table = off

PostUp = ip route add default via 10.10.10.3 dev wg0 table wgforward
PostDown = iptables -D FORWARD -i tun0 -o wg0 -j ACCEPT; iptables -D FORWARD -i wg0 -o tun0 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT; ip rule del fwmark 100 lookup wgforward; iptables -t mangle -D PREROUTING -i tun0 -j MARK --set-mark 100; ip route del default via 10.10.10.3 dev wg0 table wgforward; ip route del 10.10.10.0/24 dev wg0 scope link table wgforward

[Peer]
PublicKey = j9I4oPgfgFxZuohCMIHxTgF7AjQVwCw4a/QpCwZnJhM=
Endpoint = 185.250.151.170:44450
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF

chmod 600 $WG_CONFIG

# ==================== OPENVPN SETUP ====================
print_status "Setting up OpenVPN..."

# Create OpenVPN directory structure
mkdir -p $OVPN_DIR
mkdir -p /etc/openvpn/easy-rsa

# Copy Easy-RSA files
print_status "Setting up Easy-RSA..."
cp -r /usr/share/easy-rsa/* /etc/openvpn/easy-rsa/
cd /etc/openvpn/easy-rsa

# Initialize Easy-RSA PKI
./easyrsa init-pki

# Build CA (using default values)
print_status "Building Certificate Authority..."
echo -e "\n\n\n\n\n\n\n" | ./easyrsa build-ca nopass

# Generate server certificate
print_status "Generating server certificate..."
echo -e "\n\n\n\n\n\n\n" | ./easyrsa gen-req server nopass
echo -e "yes\n" | ./easyrsa sign-req server server

# Generate DH parameters
print_status "Generating Diffie-Hellman parameters (this may take a while)..."
./easyrsa gen-dh

# Generate TLS key
print_status "Generating TLS authentication key..."
openvpn --genkey --secret $OVPN_DIR/tc.key

# Generate CRL
print_status "Generating Certificate Revocation List..."
./easyrsa gen-crl

# Copy certificates to OpenVPN directory
print_status "Copying certificates to OpenVPN directory..."
cp pki/ca.crt $OVPN_DIR/
cp pki/private/ca.key $OVPN_DIR/
cp pki/issued/server.crt $OVPN_DIR/
cp pki/private/server.key $OVPN_DIR/
cp pki/dh.pem $OVPN_DIR/
cp pki/crl.pem $OVPN_DIR/

# Create OpenVPN server configuration
print_status "Creating OpenVPN server configuration..."
cat > $OVPN_CONFIG << EOF
local $PUBLIC_IP
port 1194
proto udp
dev tun
ca ca.crt
cert server.crt
key server.key
dh dh.pem
auth SHA512
tls-crypt tc.key
topology subnet
server 10.8.0.0 255.255.255.0
push "redirect-gateway def1 bypass-dhcp"
ifconfig-pool-persist ipp.txt
push "dhcp-option DNS 8.8.8.8"
push "dhcp-option DNS 9.9.9.9"
push "block-outside-dns"
keepalive 10 120
user nobody
group nogroup
persist-key
persist-tun
verb 3
crl-verify crl.pem
explicit-exit-notify

script-security 2
up $OVPN_UP_SCRIPT
down $OVPN_DOWN_SCRIPT
down-pre
EOF

# Create OpenVPN up script
print_status "Creating OpenVPN up script..."
cat > $OVPN_UP_SCRIPT << 'EOF'
#!/bin/bash
set -e

# OpenVPN creates tun0 before calling this script.
# We force all traffic arriving from tun0 into the wgforward table.

# Routing table for traffic that must leave through WireGuard
ip route replace 10.10.10.0/24 dev wg0 scope link table wgforward
ip route replace default via 10.10.10.3 dev wg0 table wgforward

# Remove stale duplicate rule if it exists
ip rule del fwmark 100 lookup wgforward 2>/dev/null || true

# Mark all packets coming from OpenVPN clients
iptables -t mangle -C PREROUTING -i tun0 -j MARK --set-mark 100 2>/dev/null || \
iptables -t mangle -A PREROUTING -i tun0 -j MARK --set-mark 100

# Route marked packets through WireGuard
ip rule add fwmark 100 lookup wgforward

# Allow forwarding between OpenVPN and WireGuard
iptables -C FORWARD -i tun0 -o wg0 -j ACCEPT 2>/dev/null || \
iptables -A FORWARD -i tun0 -o wg0 -j ACCEPT

iptables -C FORWARD -i wg0 -o tun0 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || \
iptables -A FORWARD -i wg0 -o tun0 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# Kernel routing behavior for policy-routed VPN traffic
sysctl -w net.ipv4.ip_forward=1
sysctl -w net.ipv4.conf.all.rp_filter=0
sysctl -w net.ipv4.conf.default.rp_filter=0
sysctl -w net.ipv4.conf.tun0.rp_filter=0
sysctl -w net.ipv4.conf.wg0.rp_filter=0
EOF

# Create OpenVPN down script
print_status "Creating OpenVPN down script..."
cat > $OVPN_DOWN_SCRIPT << 'EOF'
#!/bin/bash
set +e

# Remove forwarding rules
iptables -D FORWARD -i tun0 -o wg0 -j ACCEPT 2>/dev/null
iptables -D FORWARD -i wg0 -o tun0 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null

# Remove packet marking
iptables -t mangle -D PREROUTING -i tun0 -j MARK --set-mark 100 2>/dev/null

# Remove policy routing rule
ip rule del fwmark 100 lookup wgforward 2>/dev/null

# Optional: keep routes, or remove them.
# I would leave them, but if you want full teardown, uncomment:
# ip route del default via 10.10.10.3 dev wg0 table wgforward 2>/dev/null
# ip route del 10.10.10.0/24 dev wg0 scope link table wgforward 2>/dev/null
EOF

# Make scripts executable
chmod +x $OVPN_UP_SCRIPT
chmod +x $OVPN_DOWN_SCRIPT

# Create ipp.txt file
touch $OVPN_DIR/ipp.txt

# ==================== FIREWALL SETUP ====================
print_status "Configuring firewall rules..."

# Configure UFW
ufw default deny incoming
ufw default allow outgoing

# Allow SSH
ufw allow 22/tcp
print_warning "SSH port 22 is allowed. Change this if using a different port."

# Allow OpenVPN
ufw allow 1194/udp

# Allow WireGuard
ufw allow 44450/udp

# Allow forwarding in UFW
sed -i 's/DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw || true

# Enable UFW (skip if already enabled)
if ! ufw status | grep -q "Status: active"; then
    print_status "Enabling UFW firewall..."
    echo "y" | ufw enable
else
    print_status "UFW is already enabled, reloading rules..."
    ufw reload
fi

# ==================== CLIENT CONFIGURATION ====================
print_status "Creating client configuration template..."
cat > $OVPN_DIR/client-common.txt << EOF
client
dev tun
proto udp
remote $PUBLIC_IP 1194
resolv-retry infinite
nobind
user nobody
group nogroup
persist-key
persist-tun
remote-cert-tls server
auth SHA512
verb 3
EOF

# ==================== SERVICE MANAGEMENT ====================
print_status "Enabling and starting services..."

# Enable WireGuard
systemctl enable wg-quick@wg0
systemctl start wg-quick@wg0 || print_warning "WireGuard failed to start. Check configuration."

# Enable OpenVPN
systemctl enable openvpn-server@server
systemctl start openvpn-server@server || print_warning "OpenVPN failed to start. Check configuration."

# ==================== VERIFICATION ====================
print_status "Verifying installation..."

# Check WireGuard status
if systemctl is-active --quiet wg-quick@wg0; then
    print_status "WireGuard is running"
    wg show
else
    print_warning "WireGuard is not running"
fi

# Check OpenVPN status
if systemctl is-active --quiet openvpn-server@server; then
    print_status "OpenVPN is running"
else
    print_warning "OpenVPN is not running"
fi

# Check network interfaces
print_status "Network interfaces:"
ip addr show | grep -E "^[0-9]+: (wg0|tun0):" || print_warning "VPN interfaces not found"

# ==================== USAGE INSTRUCTIONS ====================
print_status "Installation complete!"
echo ""
echo "=========================================="
echo -e "${GREEN}VPN Dual Setup Installation Complete${NC}"
echo "=========================================="
echo ""
echo "WireGuard Configuration:"
echo "  Interface: wg0"
echo "  Address: 10.10.10.2/24"
echo "  Port: 44450"
echo ""
echo "OpenVPN Configuration:"
echo "  Interface: tun0"
echo "  Network: 10.8.0.0/24"
echo "  Port: 1194/udp"
echo ""
echo "To create a client certificate:"
echo "  cd /etc/openvpn/easy-rsa"
echo "  ./easyrsa gen-req client-name nopass"
echo "  ./easyrsa sign-req client client-name"
echo ""
echo "Check service status:"
echo "  systemctl status wg-quick@wg0"
echo "  systemctl status openvpn-server@server"
echo ""
echo "View logs:"
echo "  journalctl -u wg-quick@wg0 -f"
echo "  journalctl -u openvpn-server@server -f"
echo "=========================================="