# Docker Management Scripts

Tools for managing Docker containers, images, volumes, and Docker Compose projects.

## Available Scripts

### docker-manager

Comprehensive Docker management tool with text-based user interface (TUI) for easy container and resource management.

**Features:**
- Container management (list, start, stop, restart, remove, logs, stats)
- Image management (list, pull, remove, build, prune)
- Volume management (list, create, remove, prune, inspect)
- Network management (list, create, remove, inspect)
- Docker Compose integration
- System-wide cleanup operations
- Resource usage statistics
- Container backup and restore
- Interactive TUI with whiptail
- Automatic Docker service detection and startup

**Usage:**
```bash
sudo docker-manager
```

**Main Menu Sections:**

1. **Container Management**
   - List all containers (running/stopped)
   - Start/stop/restart containers
   - Remove containers
   - View logs
   - View statistics
   - Execute commands in containers

2. **Image Management**
   - List images
   - Pull images from registry
   - Remove images
   - Build images from Dockerfile
   - Prune unused images

3. **Volume Management**
   - List volumes
   - Create new volumes
   - Remove volumes
   - Prune unused volumes
   - Inspect volume details

4. **Network Management**
   - List networks
   - Create networks
   - Remove networks
   - Inspect network details

5. **Docker Compose**
   - Manage Compose projects
   - Up/down/restart services
   - View logs
   - Pull updated images

6. **System Operations**
   - System-wide prune (cleanup)
   - Disk usage statistics
   - Docker info

**Requirements:**
- Root privileges
- whiptail (TUI interface)
- docker.io or docker-ce
- docker-compose (optional, for Compose features)

**Installation of Dependencies:**
```bash
sudo apt install whiptail docker.io docker-compose
```

**Auto-start Docker:**
If Docker service is not running, the script will prompt to start it automatically.

---

### update-docker-compose

Automatically discovers and updates Docker Compose projects in subdirectories.

**Features:**
- Automatic discovery of docker-compose files in subdirectories
- Support for multiple compose file names:
  - docker-compose.yml
  - docker-compose.yaml
  - compose.yml
  - compose.yaml
- Interactive or automatic mode
- Pull updated images
- Restart containers when new images are downloaded
- Automatic cleanup of old/unused images
- Colored output for better readability
- Permission error handling

**Usage:**
```bash
# Automatic mode (default): Update all projects without prompts
sudo update-docker-compose

# Interactive mode: Prompt for each project
sudo update-docker-compose --interactive
sudo update-docker-compose -i

# Show help
update-docker-compose --help
```

**Workflow:**
1. Scans current directory and subdirectories for docker-compose files
2. For each project found:
   - Displays project location
   - Pulls latest images (`docker-compose pull`)
   - Checks if new images were downloaded
   - Restarts containers if updates were found (or asks in interactive mode)
3. Cleans up old/unused images

**Example Output:**
```
Found Docker Compose project in: ./myapp
Pulling images for ./myapp...
New images downloaded!
Restarting containers...
Done!

Found Docker Compose project in: ./webapp
Pulling images for ./webapp...
No new images found. Skipping restart.
```

**Requirements:**
- Docker
- docker-compose or docker-compose-plugin

**Interactive Mode:**
Use `-i` flag to confirm each update:
```bash
sudo update-docker-compose -i
```

**Best Practices:**
- Run from a parent directory containing multiple Docker Compose projects
- Use automatic mode for scheduled updates (cron jobs)
- Use interactive mode for manual selective updates
- Ensure compose files are in subdirectories, not the current directory

**Scheduled Updates (Cron Example):**
```bash
# Update all Docker Compose projects daily at 2 AM
0 2 * * * /usr/local/bin/update-docker-compose >> /var/log/docker-compose-updates.log 2>&1
```

## Tips and Best Practices

**docker-manager:**
- Use container stats to monitor resource usage
- Regularly prune unused images and volumes to free disk space
- Check logs when troubleshooting container issues
- Use the backup feature before major changes

**update-docker-compose:**
- Test updates in interactive mode first
- Keep compose files organized in separate project directories
- Review logs after automatic updates
- Schedule updates during low-traffic periods
