# Changelog - Ubuntu Repository Extraction

## [Unreleased] - 2025-11-08

### Changed - Ubuntu Repository Manager Extracted to Standalone Repository

#### 🎯 Major Changes

**Extracted ubuntu-repo to standalone git repository**
- Created standalone repository at `/home/manzolo/Workspaces/ubuntu-repo-standalone`
- Removed `utils/ubuntu-repo/` from BashCollection git tracking
- Repository files still exist locally but are gitignored

**Simplified staging directory**
- Changed from `utils/ubuntu-repo/packages/` to `packages/` (in root)
- Cleaner, flatter directory structure
- `packages/` directory is gitignored

**Updated publish workflow**
- `menage_scripts.sh`: Updated `publish_to_repository()` to use new `packages/` directory
- Automatic deployment to remote repository via `deploy-to-repo.sh`
- Removed local Docker repository fallback (still available locally, just not in workflow)

**Updated configuration**
- `deploy-to-repo.sh`: Changed `LOCAL_PACKAGES_DIR` from `utils/ubuntu-repo/packages` to `packages`
- `.deploy-config.example`: Updated default staging directory path
- `.gitignore`: Added `packages/` and `utils/ubuntu-repo/`

#### 📝 Modified Files

- `menage_scripts.sh` - Updated publish workflow
- `deploy-to-repo.sh` - Updated staging directory
- `.deploy-config.example` - Updated default configuration
- `.gitignore` - Added packages/ and utils/ubuntu-repo/

#### 📁 New Files

- `docs/UBUNTU_REPO_STANDALONE.md` - Guide for standalone repository
- `docs/REMOVED_UBUNTU_REPO.md` - Migration guide and FAQ
- `packages/` - New staging directory (gitignored)

#### 🗑️ Removed from Git

- `utils/ubuntu-repo/.dockerignore`
- `utils/ubuntu-repo/.env.example`
- `utils/ubuntu-repo/.gitignore`
- `utils/ubuntu-repo/Dockerfile`
- `utils/ubuntu-repo/docker-compose.yml`
- `utils/ubuntu-repo/docker-entrypoint.sh`
- `utils/ubuntu-repo/repo.sh`
- `utils/ubuntu-repo/repo-manager.sh`
- `utils/ubuntu-repo/ubuntu-repo-manager.sh`
- `utils/ubuntu-repo/README.md`
- `utils/ubuntu-repo/PUBLISHING_GUIDE.md`
- `utils/ubuntu-repo/QUICKSTART.md`
- `utils/ubuntu-repo/README_DOCKER.md`
- `utils/ubuntu-repo/create-example-package.sh`

**Note**: Files removed from git tracking but still exist locally

#### ✨ Benefits

1. **Cleaner Repository**: BashCollection focuses on scripts, not repository management
2. **Better Separation**: Ubuntu repo can be developed independently
3. **Reusability**: Standalone repo can be used by other projects
4. **Simplified Workflow**: Single command to build and deploy packages
5. **Reduced Duplication**: Single source of truth for Ubuntu Repository Manager

#### 🔄 Migration

**No action required for existing users**. The workflow remains the same:

```bash
# Before and After - same command
sudo ./menage_scripts.sh publish manzolo-chroot
```

**What changed under the hood**:
- Packages now stage in `packages/` instead of `utils/ubuntu-repo/packages/`
- Automatic deployment to remote repository
- Local Docker repository fallback removed from publish workflow (but still available manually)

**If you use custom .deploy-config**:
- No changes needed
- Default `LOCAL_PACKAGES_DIR` is now `packages` but you can override it

#### 📚 Documentation

See detailed documentation:
- `docs/UBUNTU_REPO_STANDALONE.md` - Complete guide for standalone repository
- `docs/REMOVED_UBUNTU_REPO.md` - Migration guide, FAQ, and troubleshooting

#### 🧪 Testing

Test the new workflow:

```bash
# 1. Build and deploy package
sudo ./menage_scripts.sh publish manzolo-chroot

# 2. Verify staging
ls packages/
# Should show: manzolo-chroot_*.deb

# 3. Verify remote deployment
ssh root@home-server.lan "cd /root/ubuntu-repo && ./repo.sh list | grep manzolo-chroot"

# 4. Install on client
sudo apt update && sudo apt install manzolo-chroot
```

#### 🚀 Next Steps

**To use the standalone repository**:

```bash
cd /home/manzolo/Workspaces/ubuntu-repo-standalone
git remote add origin <your-repo-url>
git push -u origin main
```

**To clean up local ubuntu-repo directory** (optional):

```bash
# Only if you don't need local Docker repository
rm -rf utils/ubuntu-repo/
```

---

## Summary

✅ Extracted Ubuntu Repository Manager to standalone repository
✅ Simplified staging directory from `utils/ubuntu-repo/packages/` to `packages/`
✅ Updated publish workflow for automatic remote deployment
✅ Maintained backward compatibility
✅ Created comprehensive documentation

The BashCollection repository is now cleaner and more focused on its core mission: managing and publishing bash scripts!
