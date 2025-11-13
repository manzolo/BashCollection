# SSH Manager v2.4

Enhanced SSH connection manager with profiles, automation, and advanced port forwarding.

## Features

- **Connection Management**: Save and manage multiple SSH server profiles
- **Multiple Connection Types**: SSH, SFTP, SSHFS+MC (Midnight Commander)
- **Port Forwarding**: Local (-L), Remote (-R), and Dynamic (-D) SSH tunnels
- **Auto-Reconnect**: Persistent tunnels with autossh support
- **SSH Key Management**: Copy SSH keys to servers
- **YAML Configuration**: Human-readable configuration format
- **Modular Architecture**: Easy to extend and maintain
- **Connection Logging**: Track all SSH activities

## Installation

```bash
# Via BashCollection installer
sudo ./menage_scripts.sh install

# Direct execution
sudo ./utils/ssh-manager/ssh-manager.sh
```

## Quick Start

1. Run `ssh-manager`
2. Press `6` to add a server
3. Press `1` to connect via SSH

## Configuration

Configuration is stored in `~/.config/manzolo-ssh-manager/config.yaml`

### Example Configuration

```yaml
servers:
  - name: "Production Server"
    host: "prod.example.com"
    user: "deploy"
    port: 22
    description: "Main production server"
    ssh_options: "-o StrictHostKeyChecking=no"
    portforwards:
      - name: "MySQL Access"
        type: "L"
        local_port: 3306
        remote_host: "localhost"
        remote_port: 3306
        description: "Access production database"
        autoreconnect: true

      - name: "Web Admin"
        type: "L"
        local_port: 8080
        remote_host: "admin.internal"
        remote_port: 80
        description: "Internal admin panel"

      - name: "SOCKS Proxy"
        type: "D"
        local_port: 1080
        description: "Dynamic SOCKS proxy for network access"

  - name: "Development Server"
    host: "192.168.1.100"
    user: "dev"
    port: 2222
    portforwards:
      - name: "Expose Local App"
        type: "R"
        remote_port: 8000
        remote_host: "localhost"
        local_port: 3000
        description: "Share local dev server with team"

  - name: "Jump Host"
    host: "bastion.company.com"
    user: "admin"
    port: 22
    description: "Bastion server for internal network"
```

## Port Forwarding

### Types of Port Forwards

#### 1. Local Forward (-L)
Forward local port to remote destination through SSH server.

**Use cases:**
- Access internal databases
- Reach web interfaces behind firewalls
- Secure unencrypted protocols

**Example:** Access remote MySQL database locally
- Configuration: `L 3306:localhost:3306`
- Result: `localhost:3306` → `server:3306`

#### 2. Remote Forward (-R)
Expose local service to remote network.

**Use cases:**
- Share local development server
- Access home computer from anywhere
- Demo applications without deployment

**Example:** Expose local web app on port 3000
- Configuration: `R 8000:localhost:3000`
- Result: Remote users access `server:8000` → your `localhost:3000`

#### 3. Dynamic Forward (-D)
Create SOCKS proxy to tunnel all traffic.

**Use cases:**
- Secure public WiFi connections
- Browse as if in different location
- Access entire remote network

**Example:** SOCKS proxy on port 1080
- Configuration: `D 1080`
- Result: Configure browser to use `localhost:1080` SOCKS5 proxy

### Managing Port Forwards

#### Add Port Forward Profile
1. Menu → `5` (Port Forwarding)
2. Select `4` (Add port forward profile)
3. Choose server
4. Select tunnel type (L/R/D)
5. Enter port details
6. Enable auto-reconnect (optional)

#### Start Tunnel
1. Menu → `5` → `1` (Start tunnel)
2. Select profile
3. Tunnel starts in background

#### Stop Tunnel
1. Menu → `5` → `2` (Stop tunnel)
2. Select active tunnel or stop all

#### View Active Tunnels
- Menu → `5` → `3` (Show active tunnels)
- Shows: PID, type, ports, status

## Module Structure

```
utils/ssh-manager/
├── ssh-manager.sh          # Main entry point (87 lines)
└── ssh-manager/
    ├── core.sh             # Core functions, logging, colors (86 lines)
    ├── config.sh           # Configuration management (112 lines)
    ├── connections.sh      # SSH/SFTP/SSHFS handlers (249 lines)
    ├── servers.sh          # Server CRUD operations (234 lines)
    ├── portforward.sh      # Port forwarding/tunnels (687 lines)
    ├── ui.sh               # User interface/menus (37 lines)
    └── utils.sh            # Prerequisites, dependencies (137 lines)
```

## Common Scenarios

### Database Developer

Access production database through bastion:

```yaml
portforwards:
  - name: "Prod PostgreSQL"
    type: "L"
    local_port: 5432
    remote_host: "db.internal.company.com"
    remote_port: 5432
    autoreconnect: true
```

Connect tools to `localhost:5432`

### Remote Worker

Access multiple office services:

```yaml
portforwards:
  - name: "Remote Desktop"
    type: "L"
    local_port: 3389
    remote_host: "desktop.office"
    remote_port: 3389

  - name: "File Server"
    type: "L"
    local_port: 445
    remote_host: "fileserver.office"
    remote_port: 445

  - name: "Jenkins"
    type: "L"
    local_port: 8080
    remote_host: "jenkins.office"
    remote_port: 8080
```

### IoT Developer

Expose local MQTT broker to cloud:

```yaml
portforwards:
  - name: "MQTT Broker"
    type: "R"
    remote_port: 1883
    remote_host: "localhost"
    local_port: 1883

  - name: "Grafana Dashboard"
    type: "R"
    remote_port: 3000
    remote_host: "localhost"
    local_port: 3000
```

### Security Testing

SOCKS proxy for network pivoting:

```yaml
portforwards:
  - name: "Pivot Proxy"
    type: "D"
    local_port: 9050
    description: "SOCKS5 proxy through compromised host"
```

Use with proxychains: `proxychains4 -f /etc/proxychains4.conf nmap 10.0.0.0/24`

## Auto-Reconnect

When enabled, tunnels use `autossh` to maintain persistent connections:

- Automatically reconnects if connection drops
- Monitors connection health with ServerAliveInterval
- Survives network interruptions

**Install autossh:**
```bash
# Ubuntu/Debian
sudo apt install autossh

# RHEL/CentOS
sudo yum install autossh

# Arch
sudo pacman -S autossh
```

## Logs

All activities logged to: `~/.config/manzolo-ssh-manager/ssh-manager.log`

Log rotation: Automatic at 1MB

## Dependencies

**Required:**
- bash >= 4.0
- openssh-client
- dialog
- yq (YAML processor)

**Optional:**
- autossh (for auto-reconnect tunnels)
- sshpass (password authentication)
- sshfs (for SSHFS+MC feature)
- mc (Midnight Commander for file browsing)

## Tips & Tricks

### Find Free Port Automatically
When adding Local forward, enter `auto` for local port - the system will find an available port.

### Multiple Tunnels
Start multiple port forwards for a server simultaneously - each runs as separate background process.

### Persistent Tunnels
Enable auto-reconnect for critical tunnels that must stay up 24/7.

### SOCKS Proxy Browser Setup

**Firefox:**
1. Settings → Network Settings → Manual proxy
2. SOCKS Host: `localhost`, Port: `1080`
3. SOCKS v5: Yes

**Chrome:**
```bash
google-chrome --proxy-server="socks5://localhost:1080"
```

### SSH Config Integration
Custom SSH options per server allow using your existing `~/.ssh/config`:

```yaml
ssh_options: "-F ~/.ssh/custom_config"
```

## Troubleshooting

**Port already in use:**
- Check active tunnels: Menu → 5 → 3
- Use `auto` for local port assignment
- Check: `ss -tln | grep :PORT`

**Tunnel won't start:**
- Test SSH connection first: Menu → 1
- Check firewall rules
- Verify remote service is running
- Check logs: `~/.config/manzolo-ssh-manager/ssh-manager.log`

**Auto-reconnect not working:**
- Install autossh: `sudo apt install autossh`
- Check if enabled in port forward profile

## Version History

- **v2.4** - Added comprehensive port forwarding (Local, Remote, Dynamic), auto-reconnect, tunnel management
- **v2.3** - Modular architecture refactoring
- **v2.2** - Named server identification
- **v2.0** - Initial YAML-based configuration

## License

Part of BashCollection - https://github.com/manzolo/BashCollection

## Author

Manzolo <manzolo@libero.it>
