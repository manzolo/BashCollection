# System Cleaner

Advanced system cleaning and maintenance tool for Ubuntu/Debian systems.

## Available Scripts

### manzolo-cleaner (mcleaner)

Dialog-based interactive tool for cleaning and maintaining Debian/Ubuntu systems with TUI interface.

**Features:**
- Clean APT package cache
- Remove unused packages (autoremove)
- Safe removal of old kernel versions
- Clear system logs
- Remove temporary files
- Clean user caches
- Docker cleanup integration
- Free disk space analysis
- Progress tracking
- Before/after disk space reporting
- Interactive TUI with dialog

**Usage:**
```bash
sudo manzolo-cleaner
# Or using the mapped alias:
sudo mcleaner
```

**Main Menu Options:**
1. **Quick Clean**: Runs common cleaning tasks (apt clean, autoremove, temp files)
2. **Advanced Clean**: Additional cleaning options (old kernels, logs, caches)
3. **Docker Clean**: Docker-specific cleanup (containers, images, volumes)
4. **Custom Clean**: Select individual cleaning tasks
5. **Show Statistics**: Display current disk usage
6. **Configuration**: Customize cleaner settings

**Cleaning Tasks:**
- APT package cache (`apt clean`)
- Orphaned packages (`apt autoremove`)
- Old kernel versions (keeps current + one previous)
- System logs in /var/log
- Temporary files (/tmp, /var/tmp)
- User cache directories (~/.cache)
- Thumbnail caches
- Browser caches
- Old snap revisions

**Requirements:**
- Root privileges
- dialog package
- bc (for calculations)
- sudo

**Configuration:**
Settings are saved in `~/.manzolo-cleaner.conf`

**Logs:**
Activity logs are written to `/tmp/manzolo-cleaner.log`

**Safety Features:**
- Confirmation prompts before destructive operations
- Preserves current and previous kernel version
- Disk space calculation before/after operations
- Detailed logging

**Installation:**
Install required dependencies:
```bash
sudo apt install dialog bc
```

**Tips:**
- Run periodically to free up disk space
- Check statistics before cleaning to see potential space savings
- Use custom clean mode to select only specific tasks
- Review logs if any issues occur
