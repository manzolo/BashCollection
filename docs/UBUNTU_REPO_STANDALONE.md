# Ubuntu Repository Manager - Standalone Setup

This document describes the extraction of the Ubuntu Repository Manager into a standalone git repository and the integration with BashCollection's publish workflow.

## What Was Done

### 1. Created Standalone Git Repository

**Location**: `/home/manzolo/Workspaces/ubuntu-repo-standalone`

**Contents**:
- `repo.sh` - Main repository management script
- `ubuntu-repo-manager.sh` - Ubuntu repository setup wizard
- `docker-compose.yml` - Docker Compose configuration
- `Dockerfile` - Docker image definition
- `docker-entrypoint.sh` - Container entry point
- `README.md` - Documentation
- `PUBLISHING_GUIDE.md` - Publishing guide
- `QUICKSTART.md` - Quick start guide
- `.env.example` - Environment configuration example

**Git Status**:
```bash
cd /home/manzolo/Workspaces/ubuntu-repo-standalone
git log --oneline
# eb3ecaf Initial commit: Ubuntu Repository Manager standalone
```

### 2. Updated BashCollection Publish Workflow

Modified `menage_scripts.sh` function `publish_to_repository()` to:

**Primary Method - Remote Deployment**:
1. Check if `deploy-to-repo.sh` exists
2. Copy packages to local staging area (`utils/ubuntu-repo/packages/`)
3. Extract package names from .deb files
4. Deploy each package to remote repository using `deploy-to-repo.sh`
5. Show deployment status for each package

**Fallback - Local Docker Repository**:
1. If `deploy-to-repo.sh` not found, use local Docker repo
2. Copy packages to `utils/ubuntu-repo/packages/`
3. Import packages using `./repo.sh import` (if container is running)
4. Display warning that this is LOCAL only

**Final Fallback - Manual**:
- Show helpful message with options if no deployment method available

## Usage

### Publishing a Package (Remote Deployment)

```bash
# Publish a single package to remote repository
sudo ./menage_scripts.sh publish manzolo-chroot

# The workflow:
# 1. Builds the .deb package
# 2. Copies to utils/ubuntu-repo/packages/ (staging)
# 3. Deploys to remote server using deploy-to-repo.sh
# 4. Remote server imports and publishes the package
```

### Publishing Flow Details

When you run `sudo ./menage_scripts.sh publish <package>`:

1. **Build Phase** (handled by `publish_specific_script`):
   - Finds the script
   - Parses metadata
   - Asks for version (if not in metadata)
   - Creates .deb package with both alias and original name executables
   - Saves to temporary build directory

2. **Publish Phase** (handled by `publish_to_repository`):
   - Copies .deb to `utils/ubuntu-repo/packages/` (local staging)
   - Extracts package name from .deb filename
   - Calls `./deploy-to-repo.sh <package>` which:
     - Copies .deb to remote server packages directory
     - Runs `./repo.sh import` on remote server
     - Remote repo imports and publishes the package
     - Remote repo signs and updates indexes

3. **Verification**:
   - Shows deployment status
   - On client machines: `sudo apt update && sudo apt install <package>`

## Integration with deploy-to-repo.sh

The publish workflow now seamlessly integrates with `deploy-to-repo.sh`:

```bash
# Single command to build and deploy
sudo ./menage_scripts.sh publish manzolo-chroot

# Equivalent to:
sudo ./menage_scripts.sh publish manzolo-chroot  # Build package
./deploy-to-repo.sh manzolo-chroot               # Deploy to remote
```

## Configuration

Ensure you have `.deploy-config` configured (or use defaults):

```bash
# Example .deploy-config
REMOTE_SERVER="root@home-server.lan"
REMOTE_REPO_PATH="/root/ubuntu-repo"
REMOTE_PACKAGES_DIR="$REMOTE_REPO_PATH/packages"
LOCAL_PACKAGES_DIR="utils/ubuntu-repo/packages"
```

## Directory Structure

```
BashCollection/
├── menage_scripts.sh          # Updated with remote deployment
├── deploy-to-repo.sh          # Handles remote deployment
├── .deploy-config             # Deployment configuration (optional)
└── packages/                  # Local staging area for .deb packages

ubuntu-repo-standalone/        # Standalone git repository (separate)
├── repo.sh                    # Repository management
├── docker-compose.yml         # Docker setup
├── Dockerfile                 # Docker image
└── README.md                  # Documentation

Note: utils/ubuntu-repo/ has been removed from BashCollection repository
      and is now maintained as a standalone repository.
```

## Benefits

1. **Unified Workflow**: Single command to build and deploy packages
2. **Standalone Repo**: Ubuntu repo can be deployed independently
3. **Flexible Deployment**: Supports both remote and local deployment
4. **Staging Area**: Local packages directory for review before deployment
5. **Clear Feedback**: Shows deployment status for each package
6. **Backward Compatible**: Fallback to local Docker repo if deploy-to-repo.sh not found

## Next Steps

### To use the standalone repository on your server:

```bash
# On your development machine
cd /home/manzolo/Workspaces/ubuntu-repo-standalone

# Push to your git server (GitHub, GitLab, etc.)
git remote add origin <your-repo-url>
git push -u origin main

# On your Ubuntu server
git clone <your-repo-url>
cd ubuntu-repo-standalone
./repo.sh start
```

### To publish packages from BashCollection:

```bash
# Build and deploy in one command
sudo ./menage_scripts.sh publish <package-name>

# Or use the interactive menu
sudo ./menage_scripts.sh publish
```

## Testing

Test the complete workflow:

```bash
# 1. Build and deploy a package
sudo ./menage_scripts.sh publish manzolo-chroot

# 2. Verify on client machine
sudo apt update
apt-cache policy manzolo-chroot

# 3. Install
sudo apt install manzolo-chroot

# 4. Test
mchroot --help
manzolo-chroot --help
```

## Troubleshooting

### Package not deploying to remote

Check that:
1. `deploy-to-repo.sh` exists in BashCollection root
2. `.deploy-config` is configured correctly
3. SSH access to remote server works: `ssh root@home-server.lan`
4. Remote repository is running: `ssh root@home-server.lan "cd /root/ubuntu-repo && ./repo.sh status"`

### Package builds but doesn't deploy

Check the output of `publish_to_repository()`:
- Look for "Deploying to remote Ubuntu repository..." message
- Check for errors in deploy-to-repo.sh output
- Verify packages are copied to `utils/ubuntu-repo/packages/`

### Want to use local Docker repo only

Remove or rename `deploy-to-repo.sh`:
```bash
mv deploy-to-repo.sh deploy-to-repo.sh.disabled
```

The publish workflow will fall back to local Docker repository.

## Summary

The Ubuntu Repository Manager has been successfully:
- ✅ Extracted to a standalone git repository at `/home/manzolo/Workspaces/ubuntu-repo-standalone`
- ✅ Integrated with BashCollection's publish workflow
- ✅ Configured to deploy packages to remote repository via `deploy-to-repo.sh`
- ✅ Maintains backward compatibility with local Docker deployment

You can now:
- Build packages with `sudo ./menage_scripts.sh publish <package>`
- Automatically deploy to your remote Ubuntu repository
- Manage the Ubuntu repo independently as a standalone project
