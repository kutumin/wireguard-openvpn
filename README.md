# wireguard-openvpn

The script performs the following:

System Updates: Updates package lists and upgrades existing packages

Dependency Installation: Installs WireGuard, OpenVPN, Easy-RSA, and necessary tools

WireGuard Setup: Creates the wg0.conf with your exact configuration

OpenVPN Setup: Sets up PKI infrastructure, generates certificates, and creates server configuration

Routing Scripts: Creates the up/down scripts with policy routing

Firewall Configuration: Sets up UFW rules for both VPN services

Service Management: Enables and starts both services

Verification: Checks if services are running properly

After installation, you'll need to:

Create client certificates for OpenVPN users

Test both VPN connections

Monitor logs for any issues


```
chmod +x install-vpn-dual.sh
sudo ./install-vpn-dual.sh

```


