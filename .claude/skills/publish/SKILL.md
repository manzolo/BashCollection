---
name: publish
description: Use this skill when the user asks to "pubblica", "publish", "rilascia", "bump e pubblica", or "commit e pubblica" a BashCollection package. Handles the full release workflow: git commit of pending changes + publish to remote repository.
allowed-tools: Bash, Read, Glob, Grep
---

# Publish BashCollection Package

Full release workflow for `$ARGUMENTS`: commit pending changes, then publish.

## Current state

- Git status: !`git status --short`
- Git log recent: !`git log --oneline -5`

## Steps

**ARGUMENTS** contains the package name (e.g. `disk-cloner`, `share-manager`).

### 1. Commit pending changes

If `git status` shows modified files, create a commit:

- Stage only the relevant files for this package (find them via `git diff --name-only`)
- If no files are staged/modified, skip the commit step
- Use a conventional commit message based on what changed (feat/fix/refactor/docs)
- Read the PKG_VERSION from the main script header to include it in the commit message
- Format: `type(package-name): short description, bump X.Y.Z`
- Always add co-author: `Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>`

### 2. Publish

Run:

```bash
./menage_scripts.sh publish $ARGUMENTS
```

Wait for it to complete and report the outcome (success or error).

### 3. Report

Summarize what was done: which files were committed, the version published, and whether the remote deploy succeeded.
