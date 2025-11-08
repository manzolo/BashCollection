# Package Metadata Guide

## Overview

You can customize Debian package metadata by adding special comments at the top of your scripts. The build system will automatically parse these and use them when creating `.deb` packages.

## Metadata Format

Add these special comments after the shebang line:

```bash
#!/bin/bash
# PKG_NAME: custom-package-name
# PKG_VERSION: 1.0.0
# PKG_SECTION: utils
# PKG_PRIORITY: optional
# PKG_ARCHITECTURE: all
# PKG_DEPENDS: bash (>= 4.0), curl, jq
# PKG_RECOMMENDS: whiptail, dialog
# PKG_SUGGESTS: docker.io
# PKG_MAINTAINER: Your Name <you@example.com>
# PKG_DESCRIPTION: Short one-line description
# PKG_LONG_DESCRIPTION: This is a longer, more detailed description
#  that can span multiple lines. Just indent continuation lines
#  with a space after the # symbol.
# PKG_HOMEPAGE: https://github.com/yourusername/yourrepo
```

## Available Metadata Fields

| Field | Required | Default | Description |
|-------|----------|---------|-------------|
| `PKG_NAME` | No | Script filename | Package name (will be converted to lowercase with hyphens) |
| `PKG_VERSION` | No | Prompted | Version number (e.g., 1.0.0, 2.1.3-beta) |
| `PKG_SECTION` | No | `utils` | Package section (utils, admin, net, etc.) |
| `PKG_PRIORITY` | No | `optional` | Priority (required, important, standard, optional, extra) |
| `PKG_ARCHITECTURE` | No | `all` | Architecture (all, amd64, arm64, etc.) |
| `PKG_DEPENDS` | No | `bash (>= 4.0)` | Runtime dependencies |
| `PKG_RECOMMENDS` | No | Empty | Recommended packages |
| `PKG_SUGGESTS` | No | Empty | Suggested packages |
| `PKG_MAINTAINER` | No | `BashCollection <manzolo@libero.it>` | Package maintainer |
| `PKG_DESCRIPTION` | No | Auto-generated | Short description (one line) |
| `PKG_LONG_DESCRIPTION` | No | Generic | Extended description (can be multi-line) |
| `PKG_HOMEPAGE` | No | BashCollection repo | Project homepage |

## Example: disk-usage Script

```bash
#!/bin/bash
# PKG_NAME: disk-usage
# PKG_VERSION: 2.1.0
# PKG_SECTION: utils
# PKG_PRIORITY: optional
# PKG_DEPENDS: bash (>= 4.0), coreutils (>= 8.0)
# PKG_RECOMMENDS: ncdu
# PKG_MAINTAINER: Manzolo <manzolo@libero.it>
# PKG_DESCRIPTION: Advanced disk usage analyzer with visual progress bars
# PKG_LONG_DESCRIPTION: Analyzes directory sizes and displays them with beautiful
#  colored progress bars. Features include:
#  - Customizable depth levels for recursive analysis
#  - Support for hidden files and directories
#  - Top N largest files listing
#  - Multiple output formats (table, tree, JSON)
#  - Real-time progress indication
# PKG_HOMEPAGE: https://github.com/manzolo/BashCollection

# Disk Usage Analyzer - Visualize folder sizes with progress bars
# ... rest of the script ...
```

## How It Works

1. **Parse Metadata**: When building a package, the system reads the script and extracts all `PKG_*` comments
2. **Apply Defaults**: Missing fields use sensible defaults
3. **Generate Package**: Creates the `.deb` with your custom metadata
4. **Publish**: Uploads to your Ubuntu repository

## Building Packages

### Single Package (Interactive)
```bash
./menage_scripts.sh publish
# Select option 2 (Select specific scripts)
# Choose your script (e.g., disk-usage)
```

### Single Package (Direct)
```bash
cd utils/disk-usage
../../menage_scripts.sh publish
```

### All Packages
```bash
./menage_scripts.sh publish
# Select option 1 (Publish all scripts)
```

## Version Prompting

If `PKG_VERSION` is **not** specified in the script:
- The system will prompt you for a version interactively
- Validates version format (e.g., 1.0.0, 2.1, 3.0.0-beta)

If `PKG_VERSION` **is** specified:
- Uses that version automatically (no prompt)
- You can override by editing the script before building

## Multi-line Descriptions

For `PKG_LONG_DESCRIPTION`, you can span multiple lines:

```bash
# PKG_LONG_DESCRIPTION: This is the first line of the description.
#  This is the second line, indented with one space.
#  This is the third line.
#  - Bullet point one
#  - Bullet point two
```

**Important**: Each continuation line must start with `# ` (hash + space) followed by a space.

## Advanced Dependencies

### Simple
```bash
# PKG_DEPENDS: bash, curl
```

### With Version Constraints
```bash
# PKG_DEPENDS: bash (>= 4.0), curl (>= 7.0), jq
```

### Multiple Packages
```bash
# PKG_DEPENDS: bash (>= 4.0), coreutils, util-linux
# PKG_RECOMMENDS: whiptail | dialog
# PKG_SUGGESTS: docker.io, docker-compose
```

## Tips

1. **Keep descriptions concise**: Short description should be < 80 characters
2. **Document dependencies**: List all required commands/packages
3. **Use semantic versioning**: Follow x.y.z format
4. **Test locally first**: Install with `sudo dpkg -i package.deb` before publishing
5. **Update version**: Increment version when making changes

## Integration with Repository

After building packages with metadata, they're automatically:
1. Built with your custom metadata
2. Copied to `utils/ubuntu-repo/packages/`
3. Imported into the repository (if container is running)
4. Available for `apt install`

## Viewing Package Info

Once installed on a client:

```bash
# View all metadata
apt show disk-usage

# View description only
apt-cache show disk-usage | grep Description -A 10

# List dependencies
apt-cache depends disk-usage
```

## Example Output

When someone runs `apt show disk-usage` on their system:

```
Package: disk-usage
Version: 2.1.0
Priority: optional
Section: utils
Maintainer: Manzolo <manzolo@libero.it>
Installed-Size: 42 kB
Depends: bash (>= 4.0), coreutils (>= 8.0)
Recommends: ncdu
Homepage: https://github.com/manzolo/BashCollection
Download-Size: 12.3 kB
APT-Sources: http://your-repo.com focal/main amd64 Packages
Description: Advanced disk usage analyzer with visual progress bars
 Analyzes directory sizes and displays them with beautiful
 colored progress bars. Features include:
 - Customizable depth levels for recursive analysis
 - Support for hidden files and directories
 - Top N largest files listing
 - Multiple output formats (table, tree, JSON)
 - Real-time progress indication
```

## Migrating Existing Scripts

For scripts without metadata:
1. Works immediately with defaults
2. Gradually add metadata as needed
3. No breaking changes

## Reference

- [Debian Policy Manual](https://www.debian.org/doc/debian-policy/)
- [Control File Format](https://www.debian.org/doc/debian-policy/ch-controlfields.html)
- [Package Naming](https://www.debian.org/doc/debian-policy/ch-binary.html#s-package-name)
