#!/usr/bin/env bash
# PKG_NAME: git-info
# PKG_VERSION: 1.0.1
# PKG_SECTION: utils
# PKG_PRIORITY: optional
# PKG_ARCHITECTURE: all
# PKG_DEPENDS: bash (>= 4.0), git
# PKG_MAINTAINER: Manzolo <manzolo@libero.it>
# PKG_DESCRIPTION: Git repository analysis and reporting tool
# PKG_LONG_DESCRIPTION: Comprehensive tool for analyzing git repositories
#  and generating detailed reports including branch information, commit
#  statistics, disk space usage, and contributor analysis.
#  .
#  Features:
#  - Repository metadata and configuration
#  - Local and remote branch analysis
#  - Disk space usage of .git directory
#  - Commit statistics and history
#  - Contributor analysis
#  - Working tree status
#  - Detailed and summary modes
# PKG_HOMEPAGE: https://github.com/manzolo/BashCollection

# git-info.sh - Git repository analysis tool
# Usage: ./git-info.sh [path] [--full] [--no-color]

REPO_PATH="."
FULL_MODE=false
USE_COLOR=true

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --full)
      FULL_MODE=true
      shift
      ;;
    --no-color)
      USE_COLOR=false
      shift
      ;;
    -h|--help)
      echo "Usage: $0 [path] [--full] [--no-color]"
      echo "  path: Path to git repository (default: current directory)"
      echo "  --full: Include detailed analysis"
      echo "  --no-color: Disable colored output"
      exit 0
      ;;
    -*)
      echo "Unknown option $1"
      echo "Use -h or --help for usage information"
      exit 1
      ;;
    *)
      REPO_PATH="$1"
      shift
      ;;
  esac
done

# --- Colors ---
if [[ "$USE_COLOR" == true ]]; then
  RESET="\033[0m"
  BOLD="\033[1m"
  HEADER_BG="\033[48;5;27m\033[97m"   # white text, blue bg
  WARN_BG="\033[48;5;202m\033[97m"    # white text, orange bg
  ERROR_BG="\033[48;5;196m\033[97m"   # white text, red bg
  SUCCESS_BG="\033[48;5;34m\033[97m"  # white text, green bg
  SUBHEAD="\033[1;33m"                # bright yellow
  INFO="\033[0;36m"                   # cyan
  DIM="\033[2m"                       # dim text
else
  RESET=""
  BOLD=""
  HEADER_BG=""
  WARN_BG=""
  ERROR_BG=""
  SUCCESS_BG=""
  SUBHEAD=""
  INFO=""
  DIM=""
fi

print_header() {
  printf "\n${HEADER_BG} %-60s ${RESET}\n" "$1"
}

print_warn() {
  printf "${WARN_BG} [!] %s ${RESET}\n" "$1"
}

print_error() {
  printf "${ERROR_BG} [X] %s ${RESET}\n" "$1"
}

print_success() {
  printf "${SUCCESS_BG} [✓] %s ${RESET}\n" "$1"
}

print_info() {
  printf "${INFO}ℹ %s${RESET}\n" "$1"
}

# --- Dependency check ---
if ! command -v git >/dev/null 2>&1; then
  print_error "git is not installed"
  exit 1
fi

# --- Validate repository ---
if [[ ! -d "$REPO_PATH" ]]; then
  print_error "Directory not found: $REPO_PATH"
  exit 1
fi

cd "$REPO_PATH" || exit 1

if ! git rev-parse --git-dir >/dev/null 2>&1; then
  print_error "Not a git repository: $REPO_PATH"
  exit 1
fi

GIT_DIR=$(git rev-parse --git-dir)
REPO_ROOT=$(git rev-parse --show-toplevel)

# --- Start output ---
echo
print_header "Git Repository Analysis"
echo "Date: $(date '+%Y-%m-%d %H:%M:%S')"
echo "Path: $REPO_ROOT"
echo "Mode: $([ $FULL_MODE == true ] && echo "Full Analysis" || echo "Standard")"
echo

# --- Repository Information ---
print_header "Repository Information"

# Get remote URL
REMOTE_URL=$(git config --get remote.origin.url 2>/dev/null)
if [[ -n "$REMOTE_URL" ]]; then
  echo "  Remote URL: $REMOTE_URL"
else
  echo "  Remote URL: ${DIM}none (local repository)${RESET}"
fi

# Get current branch
CURRENT_BRANCH=$(git symbolic-ref --short HEAD 2>/dev/null || echo "detached HEAD")
echo "  Current branch: $CURRENT_BRANCH"

# Get HEAD commit
HEAD_COMMIT=$(git rev-parse --short HEAD 2>/dev/null)
HEAD_COMMIT_FULL=$(git rev-parse HEAD 2>/dev/null)
echo "  HEAD commit: $HEAD_COMMIT"

# Get last commit info
LAST_COMMIT_MSG=$(git log -1 --pretty=format:"%s" 2>/dev/null)
LAST_COMMIT_AUTHOR=$(git log -1 --pretty=format:"%an" 2>/dev/null)
LAST_COMMIT_DATE=$(git log -1 --pretty=format:"%ar" 2>/dev/null)
echo "  Last commit: \"$LAST_COMMIT_MSG\""
echo "  Last author: $LAST_COMMIT_AUTHOR ($LAST_COMMIT_DATE)"

# --- Working Tree Status ---
print_header "Working Tree Status"

# Check for uncommitted changes
MODIFIED_FILES=$(git diff --name-only 2>/dev/null | wc -l)
STAGED_FILES=$(git diff --cached --name-only 2>/dev/null | wc -l)
UNTRACKED_FILES=$(git ls-files --others --exclude-standard 2>/dev/null | wc -l)

if [[ $MODIFIED_FILES -eq 0 ]] && [[ $STAGED_FILES -eq 0 ]] && [[ $UNTRACKED_FILES -eq 0 ]]; then
  print_success "Working tree is clean"
else
  if [[ $MODIFIED_FILES -gt 0 ]]; then
    print_warn "$MODIFIED_FILES modified file(s)"
  fi
  if [[ $STAGED_FILES -gt 0 ]]; then
    print_info "$STAGED_FILES staged file(s)"
  fi
  if [[ $UNTRACKED_FILES -gt 0 ]]; then
    echo "  $UNTRACKED_FILES untracked file(s)"
  fi
fi

# Check if we're ahead/behind remote
if git rev-parse --abbrev-ref --symbolic-full-name @{u} >/dev/null 2>&1; then
  UPSTREAM=$(git rev-parse --abbrev-ref --symbolic-full-name @{u})
  AHEAD=$(git rev-list --count @{u}..HEAD 2>/dev/null || echo 0)
  BEHIND=$(git rev-list --count HEAD..@{u} 2>/dev/null || echo 0)

  echo "  Tracking: $UPSTREAM"
  if [[ $AHEAD -gt 0 ]]; then
    print_info "Ahead by $AHEAD commit(s)"
  fi
  if [[ $BEHIND -gt 0 ]]; then
    print_warn "Behind by $BEHIND commit(s)"
  fi
  if [[ $AHEAD -eq 0 ]] && [[ $BEHIND -eq 0 ]]; then
    print_success "Up to date with upstream"
  fi
else
  print_warn "Current branch has no upstream tracking"
fi

# --- Branch Information ---
print_header "Branch Information"

LOCAL_BRANCHES=$(git branch --list 2>/dev/null | wc -l)
REMOTE_BRANCHES=$(git branch -r 2>/dev/null | grep -v '\->' | wc -l)
echo "  Local branches: $LOCAL_BRANCHES"
echo "  Remote branches: $REMOTE_BRANCHES"

echo
echo -e "${SUBHEAD}Local Branches:${RESET}"
git branch -v --sort=-committerdate 2>/dev/null | head -n 10 | sed 's/^/  /'
if [[ $LOCAL_BRANCHES -gt 10 ]]; then
  echo "  ${DIM}... and $((LOCAL_BRANCHES - 10)) more${RESET}"
fi

if [[ $FULL_MODE == true ]]; then
  echo
  echo -e "${SUBHEAD}Remote Branches:${RESET}"
  git branch -r -v --sort=-committerdate 2>/dev/null | grep -v '\->' | head -n 10 | sed 's/^/  /'
  if [[ $REMOTE_BRANCHES -gt 10 ]]; then
    echo "  ${DIM}... and $((REMOTE_BRANCHES - 10)) more${RESET}"
  fi

  # Stale branches check
  echo
  echo -e "${SUBHEAD}Checking for stale branches...${RESET}"
  STALE_BRANCHES=$(git branch -vv 2>/dev/null | grep ': gone]' || true)
  if [[ -n "$STALE_BRANCHES" ]]; then
    print_warn "Found stale branches (remote deleted):"
    echo "$STALE_BRANCHES" | sed 's/^/  /'
  else
    print_success "No stale branches found"
  fi
fi

# --- Disk Space Usage ---
print_header "Disk Space Usage"

if [[ -d "$GIT_DIR" ]]; then
  GIT_SIZE=$(du -sh "$GIT_DIR" 2>/dev/null | cut -f1)
  echo "  .git directory size: $GIT_SIZE"

  if [[ $FULL_MODE == true ]]; then
    echo
    echo -e "${SUBHEAD}Breakdown:${RESET}"
    du -sh "$GIT_DIR"/* 2>/dev/null | sort -hr | head -n 5 | sed 's/^/  /'
  fi

  # Objects count
  OBJECTS_COUNT=$(git count-objects -v 2>/dev/null | grep '^count:' | awk '{print $2}')
  PACK_COUNT=$(git count-objects -v 2>/dev/null | grep '^packs:' | awk '{print $2}')
  SIZE_PACK=$(git count-objects -v 2>/dev/null | grep '^size-pack:' | awk '{print $2}')

  echo
  echo "  Loose objects: $OBJECTS_COUNT"
  echo "  Packed objects: $PACK_COUNT pack(s), ${SIZE_PACK}KB"

  # Check if garbage collection might help
  if [[ $OBJECTS_COUNT -gt 1000 ]]; then
    print_info "Consider running 'git gc' to optimize repository"
  fi
else
  print_warn "Could not access .git directory"
fi

# --- Commit Statistics ---
print_header "Commit Statistics"

TOTAL_COMMITS=$(git rev-list --count HEAD 2>/dev/null || echo 0)
echo "  Total commits: $TOTAL_COMMITS"

# First and last commit dates
FIRST_COMMIT_DATE=$(git log --reverse --pretty=format:"%ai" 2>/dev/null | head -n 1)
LAST_COMMIT_DATE_FULL=$(git log -1 --pretty=format:"%ai" 2>/dev/null)
echo "  First commit: $FIRST_COMMIT_DATE"
echo "  Latest commit: $LAST_COMMIT_DATE_FULL"

# Commits by time period
COMMITS_LAST_DAY=$(git rev-list --count --since="1 day ago" HEAD 2>/dev/null || echo 0)
COMMITS_LAST_WEEK=$(git rev-list --count --since="1 week ago" HEAD 2>/dev/null || echo 0)
COMMITS_LAST_MONTH=$(git rev-list --count --since="1 month ago" HEAD 2>/dev/null || echo 0)
echo
echo "  Commits in last day: $COMMITS_LAST_DAY"
echo "  Commits in last week: $COMMITS_LAST_WEEK"
echo "  Commits in last month: $COMMITS_LAST_MONTH"

# Top contributors
echo
echo -e "${SUBHEAD}Top Contributors:${RESET}"
git shortlog -sn --all --no-merges 2>/dev/null | head -n 5 | sed 's/^/  /'

if [[ $FULL_MODE == true ]]; then
  # Recent commits
  echo
  echo -e "${SUBHEAD}Recent Commits (last 10):${RESET}"
  git log -10 --pretty=format:"  %C(auto)%h%Creset - %s %C(dim)(%ar by %an)%Creset" 2>/dev/null

  # Commit activity by day of week
  echo
  echo
  echo -e "${SUBHEAD}Commit Activity by Day of Week:${RESET}"
  git log --pretty=format:"%ad" --date=format:"%A" 2>/dev/null | sort | uniq -c | sort -rn | sed 's/^/  /'

  # File statistics
  echo
  echo -e "${SUBHEAD}File Statistics:${RESET}"
  TRACKED_FILES=$(git ls-files 2>/dev/null | wc -l)
  echo "  Tracked files: $TRACKED_FILES"

  # Largest files
  echo "  Largest tracked files:"
  git ls-files 2>/dev/null | xargs -I {} du -h {} 2>/dev/null | sort -hr | head -n 5 | sed 's/^/    /'
fi

# --- Remote Information ---
print_header "Remote Information"

REMOTES=$(git remote 2>/dev/null)
if [[ -n "$REMOTES" ]]; then
  REMOTE_COUNT=$(echo "$REMOTES" | wc -l)
  echo "  Configured remotes: $REMOTE_COUNT"
  echo
  while IFS= read -r remote; do
    echo -e "${SUBHEAD}Remote: $remote${RESET}"
    FETCH_URL=$(git remote get-url "$remote" 2>/dev/null)
    PUSH_URL=$(git remote get-url --push "$remote" 2>/dev/null)
    echo "  Fetch URL: $FETCH_URL"
    if [[ "$FETCH_URL" != "$PUSH_URL" ]]; then
      echo "  Push URL:  $PUSH_URL"
    fi

    if [[ $FULL_MODE == true ]]; then
      echo "  Branches:"
      git branch -r 2>/dev/null | grep "^  $remote/" | sed 's/^/    /'
    fi
    echo
  done <<< "$REMOTES"
else
  print_warn "No remotes configured"
fi

# --- Tags ---
print_header "Tags"

TAG_COUNT=$(git tag 2>/dev/null | wc -l)
echo "  Total tags: $TAG_COUNT"

if [[ $TAG_COUNT -gt 0 ]]; then
  echo
  echo -e "${SUBHEAD}Recent Tags:${RESET}"
  git tag --sort=-creatordate 2>/dev/null | head -n 5 | while read -r tag; do
    TAG_DATE=$(git log -1 --format="%ai" "$tag" 2>/dev/null)
    TAG_MSG=$(git tag -l --format='%(contents:subject)' "$tag" 2>/dev/null)
    if [[ -n "$TAG_MSG" ]]; then
      echo "  $tag - $TAG_MSG (${TAG_DATE%% *})"
    else
      echo "  $tag (${TAG_DATE%% *})"
    fi
  done
  if [[ $TAG_COUNT -gt 5 ]]; then
    echo "  ${DIM}... and $((TAG_COUNT - 5)) more${RESET}"
  fi
fi

# --- Summary ---
print_header "Summary"
echo "  Repository: $REPO_ROOT"
echo "  Current branch: $CURRENT_BRANCH"
echo "  Total commits: $TOTAL_COMMITS"
echo "  Total branches: $LOCAL_BRANCHES local, $REMOTE_BRANCHES remote"
echo "  Contributors: $(git shortlog -sn --all --no-merges 2>/dev/null | wc -l)"
echo "  Disk usage: $GIT_SIZE"
echo "  Status: $([ $MODIFIED_FILES -eq 0 ] && [ $STAGED_FILES -eq 0 ] && [ $UNTRACKED_FILES -eq 0 ] && echo "clean" || echo "modified")"

echo
print_success "Analysis completed at $(date '+%H:%M:%S')"
echo
