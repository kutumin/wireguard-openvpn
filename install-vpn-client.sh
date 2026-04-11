#!/bin/bash

# VPN Client Installation Script
# Installs WireGuard with client configuration
# Run as root or with sudo

set -e  # Exit on error

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
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

print_info() {
    echo -e "${BLUE}[i]${NC} $1"
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   print_error "This script must be run as root or with sudo"
   exit 1
fi

# Configuration variables
WG_INTERFACE="wg0"
WG_CONFIG="/etc/wireguard/wg0.conf"
SERVER_ENDPOINT="194.87.103.131:44450"
CLIENT_ADDRESS="10.10.10.3/24"

# Detect network interface
DEFAULT_INTERFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
if [ -z "$DEFAULT_INTERFACE" ]; then
    print_warning "Could not detect default interface, using eth0"
    DEFAULT_INTERFACE="eth0"
fi
print_info "Detected network interface: $DEFAULT_INTERFACE"

print_status "Starting VPN Client Installation"
print_info "This machine will be configured as: $CLIENT_ADDRESS"

# Update system
print_status "Updating system packages..."
apt-get update -y
apt-get upgrade -y

# Install required packages
print_status "Installing required packages..."
apt-get install -y \
    wireguard \
    wireguard-tools \
    iptables \
    curl \
    resolvconf \
    ufw \
    net-tools \
    nmap \
    tcpdump \
    dnsutils

print_status "Installing nping (from nmap package)..."
if ! command -v nping &> /dev/null; then
    apt-get install -y nmap
fi

# Load WireGuard kernel module
print_status "Loading WireGuard kernel module..."
modprobe wireguard || print_warning "WireGuard module not available (common in OpenVZ/LXC)"

# Enable IP forwarding
print_status "Configuring IP forwarding..."
sed -i 's/#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/' /etc/sysctl.conf
sed -i 's/net.ipv4.ip_forward=0/net.ipv4.ip_forward=1/' /etc/sysctl.conf

# Configure reverse path filtering for VPN routing
cat >> /etc/sysctl.conf << 'EOF'

# VPN routing optimization
net.ipv4.conf.all.rp_filter=0
net.ipv4.conf.default.rp_filter=0
net.ipv4.conf.wg0.rp_filter=0
net.ipv4.conf.all.forwarding=1
EOF

# Apply sysctl settings
sysctl -p || print_warning "Could not apply all sysctl settings"

# ==================== WIREGUARD SETUP ====================
print_status "Setting up WireGuard client..."

# Create WireGuard directory
mkdir -p /etc/wireguard
chmod 700 /etc/wireguard

# Generate WireGuard keys
print_status "Generating WireGuard keys..."
cd /etc/wireguard
umask 077
wg genkey | tee privatekey | wg pubkey > publickey
PRIVATE_KEY=$(cat privatekey)
PUBLIC_KEY=$(cat publickey)

print_info "Generated Public Key: $PUBLIC_KEY"
print_warning "IMPORTANT: Send this public key to the VPN server admin if needed:"
echo "  $PUBLIC_KEY"

# Create WireGuard configuration
print_status "Creating WireGuard client configuration..."
cat > $WG_CONFIG << EOF
[Interface]
PrivateKey = qG79dWhaN6LstkJqn5Bzy0u9TziC8frRs3d2MnPoY0g=
Address = $CLIENT_ADDRESS
ListenPort = 44451

# Keep connection alive and set up NAT masquerading
PostUp = nping --udp --dest-port 44450 --rate 5 -c 25 --data-length 4 $SERVER_ENDPOINT; iptables -t nat -A POSTROUTING -o $DEFAULT_INTERFACE -j MASQUERADE
PostDown = iptables -t nat -D POSTROUTING -o $DEFAULT_INTERFACE -j MASQUERADE 2>/dev/null || true

[Peer]
PublicKey = HKe7xu4TDTHJiQV15SoEtnGMNhidczPQP5XPgtMedyA=
Endpoint = $SERVER_ENDPOINT
AllowedIPs = 10.10.10.2/32, 10.8.0.0/24
PersistentKeepalive = 25
EOF

chmod 600 $WG_CONFIG

# Also create a template with actual generated keys for reference
cat > /etc/wireguard/client-keys.txt << EOF
# WireGuard Client Keys - Generated $(date)
Private Key: $PRIVATE_KEY
Public Key: $PUBLIC_KEY
Configuration File: $WG_CONFIG
EOF
chmod 600 /etc/wireguard/client-keys.txt

print_info "Keys saved to /etc/wireguard/client-keys.txt"

# ==================== FIREWALL SETUP ====================
print_status "Configuring firewall rules..."

# Configure UFW
ufw default deny incoming
ufw default allow outgoing

# Allow SSH
SSH_PORT=$(grep "^Port" /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' || echo "22")
ufw allow $SSH_PORT/tcp
print_info "SSH port $SSH_PORT is allowed"

# Allow WireGuard port
ufw allow 44451/udp

# Allow forwarding
sed -i 's/DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw || true

# Add NAT rules to iptables directly (as backup)
print_status "Setting up NAT masquerading rules..."

# Function to setup iptables rules
setup_iptables_rules() {
    # Add NAT masquerade rule if not exists
    if ! iptables -t nat -C POSTROUTING -o $DEFAULT_INTERFACE -j MASQUERADE 2>/dev/null; then
        iptables -t nat -A POSTROUTING -o $DEFAULT_INTERFACE -j MASQUERADE
        print_status "Added iptables NAT rule for $DEFAULT_INTERFACE"
    fi
    
    # Allow forwarding between WireGuard and main interface
    iptables -C FORWARD -i wg0 -o $DEFAULT_INTERFACE -j ACCEPT 2>/dev/null || \
        iptables -A FORWARD -i wg0 -o $DEFAULT_INTERFACE -j ACCEPT
    
    iptables -C FORWARD -i $DEFAULT_INTERFACE -o wg0 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || \
        iptables -A FORWARD -i $DEFAULT_INTERFACE -o wg0 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
}

# Make iptables rules persistent
print_status "Making iptables rules persistent..."
apt-get install -y iptables-persistent || {
    print_warning "Could not install iptables-persistent, rules may not survive reboot"
}

# Save current rules
if command -v netfilter-persistent &> /dev/null; then
    netfilter-persistent save
fi

# Enable UFW
if ! ufw status | grep -q "Status: active"; then
    print_status "Enabling UFW firewall..."
    echo "y" | ufw enable
else
    print_status "UFW is already enabled, reloading rules..."
    ufw reload
fi

# ==================== CONNECTION HELPER SCRIPTS ====================
print_status "Creating helper scripts..."

# Create a connection test script
cat > /usr/local/bin/vpn-test.sh << 'EOF'
#!/bin/bash
# VPN Connection Test Script

echo "=== VPN Connection Test ==="
echo ""

# Check WireGuard interface
if ip link show wg0 &>/dev/null; then
    echo "✓ WireGuard interface (wg0) is UP"
    wg show
else
    echo "✗ WireGuard interface (wg0) is DOWN"
fi

echo ""
echo "=== Connectivity Tests ==="

# Test connection to server
echo -n "Testing connection to server (10.10.10.2): "
if ping -c 1 -W 2 10.10.10.2 &>/dev/null; then
    echo "✓ Reachable"
else
    echo "✗ Unreachable"
fi

# Test OpenVPN network reachability
echo -n "Testing OpenVPN network (10.8.0.1): "
if ping -c 1 -W 2 10.8.0.1 &>/dev/null; then
    echo "✓ Reachable"
else
    echo "✗ Unreachable"
fi

echo ""
echo "=== Routing Table ==="
ip route show | grep -E "10.10.10|10.8.0"

echo ""
echo "=== Firewall NAT Rules ==="
iptables -t nat -L POSTROUTING -v | grep MASQUERADE || echo "No NAT rules found"

echo ""
echo "=== WireGuard Logs ==="
journalctl -u wg-quick@wg0 --since "5 minutes ago" | tail -5
EOF

chmod +x /usr/local/bin/vpn-test.sh

# Create a connection restart script
cat > /usr/local/bin/vpn-restart.sh << 'EOF'
#!/bin/bash
# VPN Connection Restart Script

echo "Restarting WireGuard connection..."
systemctl restart wg-quick@wg0
sleep 2
echo "Connection restarted. Running test..."
/usr/local/bin/vpn-test.sh
EOF

chmod +x /usr/local/bin/vpn-restart.sh

# Create a status monitoring script
cat > /usr/local/bin/vpn-status.sh << 'EOF'
#!/bin/bash
# VPN Status Monitor

watch -n 2 'echo "=== WireGuard Status ==="; wg show; echo ""; echo "=== Latest Handshake ==="; wg show wg0 | grep -E "latest handshake|transfer" || echo "No connection established"'
EOF

chmod +x /usr/local/bin/vpn-status.sh

# ==================== SERVICE MANAGEMENT ====================
print_status "Enabling and starting WireGuard service..."

# Enable WireGuard at boot
systemctl enable wg-quick@wg0

# Start WireGuard
print_status "Starting WireGuard interface..."
if systemctl start wg-quick@wg0; then
    print_status "WireGuard started successfully"
else
    print_warning "WireGuard failed to start. Checking configuration..."
    journalctl -u wg-quick@wg0 --since "1 minute ago" | tail -10
fi

# Wait for connection to establish
sleep 3

# Setup iptables rules (after WireGuard is up)
setup_iptables_rules

# Save iptables rules again
if command -v netfilter-persistent &> /dev/null; then
    netfilter-persistent save
fi

# ==================== VERIFICATION ====================
print_status "Verifying installation..."

# Check WireGuard status
if systemctl is-active --quiet wg-quick@wg0; then
    print_status "WireGuard service is running"
else
    print_warning "WireGuard service is not running"
fi

# Check interface
if ip link show wg0 &>/dev/null; then
    print_status "WireGuard interface wg0 is UP"
    WG_INFO=$(wg show)
    echo "$WG_INFO"
else
    print_warning "WireGuard interface not found"
fi

# Test connection with nping
print_status "Testing connection to VPN server..."
if command -v nping &>/dev/null; then
    nping --udp --dest-port 44450 -c 3 --data-length 4 194.87.103.131 2>/dev/null || \
    print_warning "Connection test failed - check firewall and network"
fi

# ==================== USAGE INSTRUCTIONS ====================
print_status "Installation complete!"
echo ""
echo "=========================================="
echo -e "${GREEN}VPN Client Installation Complete${NC}"
echo "=========================================="
echo ""
echo "WireGuard Configuration:"
echo "  Interface: wg0"
echo "  Address: $CLIENT_ADDRESS"
echo "  Port: 44451"
echo "  Server: $SERVER_ENDPOINT"
echo ""
echo "Routing Configuration:"
echo "  VPN Server: 10.10.10.2"
echo "  OpenVPN Clients: 10.8.0.0/24"
echo ""
echo "Helper Scripts Available:"
echo "  vpn-test.sh     - Test VPN connectivity"
echo "  vpn-restart.sh  - Restart VPN connection"
echo "  vpn-status.sh   - Monitor VPN status"
echo ""
echo "Important Commands:"
echo "  systemctl status wg-quick@wg0    - Check service status"
echo "  journalctl -u wg-quick@wg0 -f    - View logs"
echo "  wg show                           - Show WireGuard status"
echo "  /usr/local/bin/vpn-test.sh        - Run connectivity tests"
echo ""
echo "Firewall Status:"
echo "  ufw status                        - Check firewall rules"
echo ""
print_warning "IMPORTANT: Ensure the VPN server has this client's public key configured!"
echo "  Your Public Key: $PUBLIC_KEY"
echo ""
echo "Configuration files:"
echo "  WireGuard Config: $WG_CONFIG"
echo "  Key Backup: /etc/wireguard/client-keys.txt"
echo "=========================================="

# Offer to run connection test
echo ""
read -p "Would you like to run a connection test now? (y/n): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    /usr/local/bin/vpn-test.sh
fi

print_status "Client setup completed successfully!"