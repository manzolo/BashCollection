# Package Metadata - Quick Start

## TL;DR

Add these comments to the top of your script (after the shebang):

```bash
#!/bin/bash
# PKG_NAME: my-tool
# PKG_VERSION: 1.0.0
# PKG_DEPENDS: bash (>= 4.0), curl
# PKG_DESCRIPTION: One-line description here
# PKG_LONG_DESCRIPTION: Longer description
#  that can span multiple lines
```

Then publish:
```bash
./menage_scripts.sh publish
```

## Example: disk-usage

The `disk-usage.sh` script now has metadata:

```bash
#!/bin/bash
# PKG_NAME: disk-usage
# PKG_VERSION: 2.1.0
# PKG_SECTION: utils
# PKG_PRIORITY: optional
# PKG_ARCHITECTURE: all
# PKG_DEPENDS: bash (>= 4.0), coreutils (>= 8.0)
# PKG_RECOMMENDS: ncdu
# PKG_MAINTAINER: Manzolo <manzolo@libero.it>
# PKG_DESCRIPTION: Advanced disk usage analyzer with visual progress bars
# PKG_LONG_DESCRIPTION: Analyzes directory sizes and displays them with beautiful
#  colored progress bars and detailed statistics.
#  .
#  Features:
#  - Customizable depth levels for recursive analysis
#  - Support for hidden files and directories
#  - Top N largest files listing
#  - Beautiful colored output with progress bars
#  - Real-time size calculations
#  - Multiple sorting options
# PKG_HOMEPAGE: https://github.com/manzolo/BashCollection

# ... rest of the script ...
```

## How to Test

### 1. Build the Package

```bash
./menage_scripts.sh publish
```

Select option 2 (Select specific scripts), then choose disk-usage.

**Notice**: It will NOT ask for a version because `PKG_VERSION` is specified!

### 2. Check the Package

```bash
cd /tmp
dpkg -I /home/manzolo/Workspaces/BashCollection/.package_build/disk-usage_2.1.0_all.deb
```

You should see:

```
Package: disk-usage
Version: 2.1.0
Section: utils
Priority: optional
Architecture: all
Depends: bash (>= 4.0), coreutils (>= 8.0)
Recommends: ncdu
Maintainer: Manzolo <manzolo@libero.it>
Description: Advanced disk usage analyzer with visual progress bars
 Analyzes directory sizes and displays them with beautiful
 colored progress bars and detailed statistics.
 .
 Features:
 - Customizable depth levels for recursive analysis
 - Support for hidden files and directories
 - Top N largest files listing
 - Beautiful colored output with progress bars
 - Real-time size calculations
 - Multiple sorting options
Homepage: https://github.com/manzolo/BashCollection
```

### 3. Install and Test Locally

```bash
sudo dpkg -i disk-usage_2.1.0_all.deb
disk-usage --help
```

### 4. Publish to Repository

If the repository is running:

```bash
cd utils/ubuntu-repo
./repo.sh list
```

You should see `disk-usage 2.1.0` in the list.

## Field Reference

| Field | Example | Required |
|-------|---------|----------|
| PKG_NAME | `my-tool` | No (uses filename) |
| PKG_VERSION | `1.0.0` | No (will prompt) |
| PKG_SECTION | `utils`, `admin`, `net` | No (default: `utils`) |
| PKG_PRIORITY | `optional`, `important` | No (default: `optional`) |
| PKG_ARCHITECTURE | `all`, `amd64` | No (default: `all`) |
| PKG_DEPENDS | `bash (>= 4.0), curl` | No (default: `bash`) |
| PKG_RECOMMENDS | `whiptail, dialog` | No |
| PKG_SUGGESTS | `docker.io` | No |
| PKG_MAINTAINER | `Name <email>` | No (default: BashCollection) |
| PKG_DESCRIPTION | Short one-liner | No (auto-generated) |
| PKG_LONG_DESCRIPTION | Multi-line text | No (generic) |
| PKG_HOMEPAGE | URL | No (BashCollection repo) |

## Common Patterns

### Minimal Metadata
```bash
#!/bin/bash
# PKG_VERSION: 1.0.0
# PKG_DESCRIPTION: My awesome tool
```

### With Dependencies
```bash
#!/bin/bash
# PKG_VERSION: 2.0.0
# PKG_DEPENDS: bash (>= 4.0), curl, jq
# PKG_RECOMMENDS: whiptail | dialog
# PKG_DESCRIPTION: JSON processor with UI
```

### Full Metadata
```bash
#!/bin/bash
# PKG_NAME: advanced-tool
# PKG_VERSION: 3.1.0
# PKG_SECTION: admin
# PKG_PRIORITY: optional
# PKG_DEPENDS: bash (>= 5.0), python3, sqlite3
# PKG_RECOMMENDS: postgresql-client
# PKG_SUGGESTS: redis-tools
# PKG_MAINTAINER: Your Name <you@example.com>
# PKG_DESCRIPTION: Advanced system administration tool
# PKG_LONG_DESCRIPTION: This tool provides comprehensive system
#  administration features including:
#  - Database management
#  - Cache optimization
#  - Monitoring and alerting
#  - Automated backups
# PKG_HOMEPAGE: https://github.com/yourname/yourtool
```

## Multi-line Descriptions

The dot (`.`) creates a paragraph break in Debian descriptions:

```bash
# PKG_LONG_DESCRIPTION: First paragraph with description.
#  .
#  Second paragraph here.
#  .
#  Key features:
#  - Feature one
#  - Feature two
```

## Benefits

1. **No Interactive Prompts**: Version is pre-defined
2. **Consistent Metadata**: Same info every build
3. **Better APT Info**: Users see detailed descriptions
4. **Dependency Management**: Auto-install required packages
5. **Professional Packages**: Like official Ubuntu packages

## Migration Path

Old scripts without metadata still work with defaults. Add metadata gradually:

1. Start with `PKG_VERSION` (avoid prompts)
2. Add `PKG_DESCRIPTION` (improve apt show output)
3. Add `PKG_DEPENDS` (ensure dependencies)
4. Add remaining fields as needed

## See Also

- Full guide: `PACKAGE_METADATA_GUIDE.md`
- Ubuntu repository setup: `utils/ubuntu-repo/README.md`
- Publishing guide: `utils/ubuntu-repo/PUBLISHING_GUIDE.md`
