# Quick Start Guide - Ubuntu Repository (Docker)

## 🚀 Get Started in 3 Steps

### Step 1: Configure

```bash
cd utils/ubuntu_repo
cp .env.example .env
nano .env
```

**Edit these minimal settings:**
```bash
SERVER_NAME=192.168.1.100       # Your server IP or domain
HTTP_PORT=8080                   # Port (or 80 for standard)
GPG_KEY_EMAIL=repo@example.com   # Your email
```

### Step 2: Start

```bash
./repo.sh start
```

**First run takes ~2 minutes** (downloads image, generates GPG key)

### Step 3: Add Package

```bash
# Option A: Add single package
./repo.sh add /path/to/package.deb

# Option B: Bulk import
cp *.deb packages/
./repo.sh import
```

## ✅ Verify It Works

```bash
./repo.sh status           # Check container is running
./repo.sh list             # See your packages
```

## 🖥️ Configure Clients

### On any Ubuntu machine:

```bash
# Get your server's client config
./repo.sh client-config

# Or manually (replace YOUR_SERVER:PORT):
wget -qO - http://YOUR_SERVER:PORT/KEY.gpg | sudo gpg --dearmor -o /etc/apt/trusted.gpg.d/myrepo.gpg
echo "deb [signed-by=/etc/apt/trusted.gpg.d/myrepo.gpg] http://YOUR_SERVER:PORT focal main" | sudo tee /etc/apt/sources.list.d/myrepo.list
sudo apt update
sudo apt install your-package-name
```

**Note**: The modern method above uses `gpg --dearmor` instead of the deprecated `apt-key`.

## 📖 Full Documentation

- **README_DOCKER.md** - Complete guide with all features
- **README.md** - Non-Docker (standalone) version

## 🆘 Common Commands

```bash
./repo.sh start              # Start repository
./repo.sh stop               # Stop repository
./repo.sh add package.deb    # Add package
./repo.sh list               # List packages
./repo.sh logs               # View logs
./repo.sh client-config      # Show client setup
./repo.sh help               # All commands
```

## 🎯 What You Get

- **Web Access**: http://YOUR_SERVER:PORT
- **GPG Key**: http://YOUR_SERVER:PORT/KEY.gpg
- **Package Directory**: `./packages/` (drop .deb files here)
- **Logs**: `./logs/` directory

## 💡 Tips

- First time takes longer (building Docker image)
- Subsequent starts are instant
- Data persists in Docker volumes
- Use `./repo.sh backup` for backups

**Ready to go! 🎉**
