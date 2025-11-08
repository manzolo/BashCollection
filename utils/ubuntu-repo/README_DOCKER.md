# Ubuntu Repository Manager - Docker Edition

Create and manage your own Ubuntu/Debian package repository using Docker. Perfect for both public and internal use!

## 🚀 Quick Start (5 Minutes)

### 1. Configure Your Repository

```bash
cd utils/ubuntu-repo

# Create configuration from example
cp .env.example .env

# Edit configuration
nano .env
```

**Minimum required configuration:**
```bash
SERVER_NAME=your-server-ip-or-domain  # e.g., 192.168.1.100 or repo.example.com
HTTP_PORT=8080                         # Port to expose (or 80 for standard)
REPO_NAME=myrepo                       # Your repository name
GPG_KEY_EMAIL=repo@yourdomain.com      # Email for GPG key
```

### 2. Start the Repository

```bash
./repo.sh start
```

That's it! Your repository is now running! 🎉

### 3. Add Your First Package

```bash
# Add a package
./repo.sh add /path/to/your-package.deb

# Or place packages in ./packages/ and import all at once
cp *.deb packages/
./repo.sh import
```

### 4. Configure Clients

```bash
./repo.sh client-config
```

Follow the instructions shown to add your repository to Ubuntu/Debian clients.

## 📦 What Gets Created

```
utils/ubuntu-repo/
├── Dockerfile               # Container definition
├── docker-compose.yml       # Service orchestration
├── .env                     # Your configuration (create from .env.example)
├── repo.sh                  # Management script (your main interface)
├── packages/                # Drop .deb files here
├── logs/                    # Nginx access/error logs
└── Docker volumes (persistent):
    ├── repo-data/          # Repository database
    ├── repo-public/        # Published packages (served via nginx)
    └── gpg-keys/           # GPG signing keys
```

## 🎯 Common Commands

### Container Management

```bash
./repo.sh start              # Start repository
./repo.sh stop               # Stop repository
./repo.sh restart            # Restart repository
./repo.sh status             # Show status
./repo.sh logs               # Show logs
./repo.sh logs -f            # Follow logs
./repo.sh shell              # Open shell in container
```

### Package Management

```bash
./repo.sh add package.deb    # Add single package
./repo.sh remove pkg-name    # Remove package
./repo.sh list               # List all packages
./repo.sh search "query"     # Search packages
./repo.sh import             # Import all from ./packages/
./repo.sh info               # Show repository info
```

### Client Configuration

```bash
./repo.sh client-config      # Show client setup instructions
```

## 📋 Complete Usage Example

```bash
# 1. Setup
cd utils/ubuntu-repo
cp .env.example .env
# Edit .env with your settings

# 2. Start repository
./repo.sh start

# 3. Create a test package (or use your own)
../create-example-package.sh

# 4. Add package to repository
./repo.sh add mypackage_1.0.deb

# 5. Verify it's there
./repo.sh list

# 6. Configure a client (on any Ubuntu machine)
wget -qO - http://your-server:8080/KEY.gpg | sudo gpg --dearmor -o /etc/apt/trusted.gpg.d/myrepo.gpg
echo "deb [signed-by=/etc/apt/trusted.gpg.d/myrepo.gpg] http://your-server:8080 focal main" | sudo tee /etc/apt/sources.list.d/myrepo.list
sudo apt update

# 7. Install your package
sudo apt install mypackage
```

## ⚙️ Configuration Options

Edit `.env` to customize:

### Repository Settings
```bash
REPO_NAME=myrepo                    # Repository identifier
REPO_DISTRIBUTION=focal             # Ubuntu version (focal, jammy, noble)
REPO_COMPONENT=main                 # Component (main, universe, etc.)
REPO_ARCHITECTURE=amd64             # Architecture
```

### Network Settings
```bash
SERVER_NAME=repo.example.com        # Domain or IP
HTTP_PORT=8080                      # HTTP port to expose
```

### GPG Settings
```bash
GPG_KEY_NAME=My Repo Key
GPG_KEY_EMAIL=repo@example.com      # Important: identifies the key
```

## 🌐 Deployment Scenarios

### Internal Network Only

```bash
# .env configuration
SERVER_NAME=192.168.1.100
HTTP_PORT=80
```

Access: `http://192.168.1.100`

### Public Internet (HTTP)

```bash
# .env configuration
SERVER_NAME=repo.example.com
HTTP_PORT=80
```

**Firewall**: Open port 80
**DNS**: Point domain to your server
Access: `http://repo.example.com`

### Public Internet (HTTPS with Reverse Proxy)

Use nginx or Traefik as reverse proxy:

```yaml
# Example with Traefik
labels:
  - "traefik.enable=true"
  - "traefik.http.routers.repo.rule=Host(`repo.example.com`)"
  - "traefik.http.routers.repo.entrypoints=websecure"
  - "traefik.http.routers.repo.tls.certresolver=letsencrypt"
```

### Multiple Distributions

Run multiple containers for different Ubuntu versions:

**Focal (20.04):**
```bash
# .env
CONTAINER_NAME=ubuntu-repo-focal
REPO_DISTRIBUTION=focal
HTTP_PORT=8080
```

**Jammy (22.04):**
```bash
# .env
CONTAINER_NAME=ubuntu-repo-jammy
REPO_DISTRIBUTION=jammy
HTTP_PORT=8081
```

Start both: `./repo.sh start` (in each configured directory)

## 🔧 Advanced Usage

### Access Container Shell

```bash
./repo.sh shell

# Inside container, you can use:
aptly repo show myrepo
aptly repo search myrepo 'name'
gpg --list-keys
```

### Manual Package Management

```bash
# From host
./repo.sh shell

# Inside container
/scripts/repo-manager.sh add /packages/file.deb
/scripts/repo-manager.sh list
/scripts/repo-manager.sh publish
```

### Backup Repository

```bash
./repo.sh backup
# Creates: ubuntu-repo-backup-YYYYMMDD_HHMMSS.tar.gz
```

### View Logs

```bash
# Container logs
./repo.sh logs -f

# Nginx logs (from host)
tail -f logs/ubuntu-repo-access.log
tail -f logs/ubuntu-repo-error.log
```

### Rebuild Image

```bash
# After modifying Dockerfile or scripts
./repo.sh build
./repo.sh restart
```

## 🐛 Troubleshooting

### Container won't start

```bash
# Check logs
./repo.sh logs

# Check configuration
cat .env

# Rebuild
./repo.sh build
./repo.sh start
```

### Packages not appearing

```bash
# Check if package was added
./repo.sh list

# Manually trigger publish
./repo.sh shell
/scripts/repo-manager.sh publish
```

### GPG key errors on clients

```bash
# Re-download key (modern method)
wget -qO - http://your-server:8080/KEY.gpg | sudo gpg --dearmor -o /etc/apt/trusted.gpg.d/myrepo.gpg

# Or export manually from container
./repo.sh shell
gpg --armor --export repo@example.com > /var/www/manzolo-ubuntu-repo/public/KEY.gpg
```

**Note**: The old `apt-key` method is deprecated. Always use the `signed-by` method for repository configuration.

### Port already in use

```bash
# Change HTTP_PORT in .env
nano .env
# Change HTTP_PORT=8080 to another port

# Restart
./repo.sh restart
```

### Reset everything

```bash
# WARNING: Deletes all data!
./repo.sh cleanup
```

## 📊 Monitoring

### Check Health

```bash
# Container status
./repo.sh status

# Health check
docker inspect ubuntu-repo | grep -A 10 Health

# Test HTTP access
curl http://localhost:8080/
```

### View Statistics

```bash
./repo.sh info
```

## 🔒 Security Best Practices

1. **Use HTTPS in production** - Via reverse proxy (nginx, Traefik)
2. **Keep GPG keys secure** - Backed up in volume `gpg-keys`
3. **Regular backups** - Use `./repo.sh backup`
4. **Update regularly** - Rebuild image for security updates
5. **Firewall rules** - Limit access if internal only
6. **Strong GPG email** - Use a valid, unique email

## 🔄 Updating

### Update Docker Image

```bash
./repo.sh stop
./repo.sh build
./repo.sh start
```

Data is persisted in Docker volumes, so updates are safe.

### Update Configuration

```bash
# Edit .env
nano .env

# Restart to apply
./repo.sh restart
```

## 📁 Volume Management

### List Volumes

```bash
docker volume ls | grep ubuntu-repo
```

### Backup Volumes

```bash
./repo.sh backup
```

### Inspect Volume

```bash
docker volume inspect ubuntu-repo_repo-data
docker volume inspect ubuntu-repo_gpg-keys
```

## 🌟 Features

- ✅ Complete isolation via Docker
- ✅ Automatic GPG key generation
- ✅ Nginx web server included
- ✅ Persistent data volumes
- ✅ Easy backup/restore
- ✅ Health checks
- ✅ Log management
- ✅ Simple CLI interface
- ✅ Multi-distribution support
- ✅ Public and private deployment

## 📚 Additional Resources

- [Aptly Documentation](https://www.aptly.info/doc/overview/)
- [Creating .deb Packages](https://wiki.debian.org/BuildingTutorial)
- [Docker Compose Reference](https://docs.docker.com/compose/)

## 🆘 Getting Help

```bash
./repo.sh help              # Show all commands
./repo.sh client-config     # Show client setup
./repo.sh logs              # Check logs
./repo.sh info              # Repository info
```

## 💡 Tips

- Drop multiple .deb files in `./packages/` and use `./repo.sh import`
- Use `./repo.sh logs -f` to watch real-time logs
- Access repository web interface at `http://your-server:port`
- GPG key is auto-exported to `/KEY.gpg` on the web server
- Logs are in `./logs/` directory for easy access

---

**Enjoy your self-hosted Ubuntu repository!** 🎉
