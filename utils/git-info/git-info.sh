#!/usr/bin/env bash
# PKG_NAME: git-info
# PKG_VERSION: 2.1.0
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
#  - Modular sections: view specific info with dedicated options
#  - Repository metadata and configuration
#  - Local and remote branch analysis
#  - Disk space usage of repository and .git directory
#  - Commit statistics and history
#  - Contributor analysis
#  - Working tree status
#  - Remote repository information
#  - Tag information
#  - Summary view
#  - Detailed mode for extended information
#  - Debug mode to see commands and their output
#  - Clean, simple layout
# PKG_HOMEPAGE: https://github.com/manzolo/BashCollection

# git-info.sh - Git repository analysis tool
# Usage: ./git-info.sh [path] [options]

REPO_PATH="."
USE_COLOR=true
DEBUG=false

# Section flags
SHOW_INFO=false
SHOW_STATUS=false
SHOW_BRANCHES=false
SHOW_USAGE=false
SHOW_COMMITS=false
SHOW_REMOTES=false
SHOW_TAGS=false
SHOW_SUMMARY=false
SHOW_ALL=false
DETAILED=false

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --all)
      SHOW_ALL=true
      shift
      ;;
    --info)
      SHOW_INFO=true
      shift
      ;;
    --status)
      SHOW_STATUS=true
      shift
      ;;
    --branches)
      SHOW_BRANCHES=true
      shift
      ;;
    --usage)
      SHOW_USAGE=true
      shift
      ;;
    --commits)
      SHOW_COMMITS=true
      shift
      ;;
    --remotes)
      SHOW_REMOTES=true
      shift
      ;;
    --tags)
      SHOW_TAGS=true
      shift
      ;;
    --summary)
      SHOW_SUMMARY=true
      shift
      ;;
    --detailed)
      DETAILED=true
      shift
      ;;
    --debug)
      DEBUG=true
      shift
      ;;
    --no-color)
      USE_COLOR=false
      shift
      ;;
    -h|--help)
      echo "Usage: $0 [path] [options]"
      echo ""
      echo "Options:"
      echo "  --all         Show all information (default if no options specified)"
      echo "  --info        Show repository information"
      echo "  --status      Show working tree status"
      echo "  --branches    Show branch information"
      echo "  --usage       Show disk space usage"
      echo "  --commits     Show commit statistics"
      echo "  --remotes     Show remote information"
      echo "  --tags        Show tags information"
      echo "  --summary     Show summary"
      echo "  --detailed    Show detailed information for selected sections"
      echo "  --debug       Show commands being executed and their output"
      echo "  --no-color    Disable colored output"
      echo ""
      echo "Examples:"
      echo "  $0 --branches              # Show only branches"
      echo "  $0 --usage --commits       # Show usage and commits"
      echo "  $0 --all --detailed        # Show everything with details"
      echo "  $0 /path/to/repo --status  # Check status of specific repo"
      echo "  $0 --branches --debug      # Show branches with debug output"
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

# If no section is specified, show all
if [[ "$SHOW_INFO" == false ]] && [[ "$SHOW_STATUS" == false ]] && \
   [[ "$SHOW_BRANCHES" == false ]] && [[ "$SHOW_USAGE" == false ]] && \
   [[ "$SHOW_COMMITS" == false ]] && [[ "$SHOW_REMOTES" == false ]] && \
   [[ "$SHOW_TAGS" == false ]] && [[ "$SHOW_SUMMARY" == false ]]; then
  SHOW_ALL=true
fi

# --- Colors ---
if [[ "$USE_COLOR" == true ]]; then
  RESET="\033[0m"
  BOLD="\033[1m"
  HEADER="\033[1;34m"      # bright blue
  YELLOW="\033[33m"        # yellow
  GREEN="\033[32m"         # green
  RED="\033[31m"           # red
  CYAN="\033[36m"          # cyan
  DIM="\033[2m"            # dim text
  ORANGE="\033[38;5;208m"  # orange
  MAGENTA="\033[35m"       # magenta
else
  RESET=""
  BOLD=""
  HEADER=""
  YELLOW=""
  GREEN=""
  RED=""
  CYAN=""
  DIM=""
  ORANGE=""
  MAGENTA=""
fi

# Simple layout functions
print_section() {
  local title="$1"
  echo ""
  echo -e "${HEADER}═══ $title ═══${RESET}"
  echo ""
}

print_kv() {
  local key="$1"
  local value="$2"
  printf "  ${BOLD}%-20s${RESET} %b\n" "$key:" "$value"
}

print_item() {
  local icon="$1"
  local text="$2"
  echo "  $icon $text"
}

print_warn() {
  echo -e "  ${ORANGE}⚠${RESET}  $1"
}

print_error() {
  echo -e "  ${RED}✗${RESET}  $1"
}

print_success() {
  echo -e "  ${GREEN}✓${RESET}  $1"
}

print_info() {
  echo -e "  ${CYAN}ℹ${RESET}  $1"
}

# Debug functions
debug_cmd() {
  local cmd="$1"
  if [[ "$DEBUG" == true ]]; then
    echo -e "${MAGENTA}[DEBUG]${RESET} ${DIM}Running:${RESET} $cmd" >&2
  fi
}

debug_output() {
  local output="$1"
  if [[ "$DEBUG" == true ]] && [[ -n "$output" ]]; then
    echo -e "${MAGENTA}[DEBUG]${RESET} ${DIM}Output:${RESET}" >&2
    echo "$output" | sed 's/^/        /' >&2
  fi
}

run_git() {
  local cmd="$@"
  debug_cmd "git $cmd"
  local output=$(git $cmd 2>&1)
  local exit_code=$?
  debug_output "$output"
  if [[ $exit_code -eq 0 ]]; then
    echo "$output"
  fi
  return $exit_code
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

# --- Collect all data first ---
debug_cmd "git config --get remote.origin.url"
REMOTE_URL=$(git config --get remote.origin.url 2>/dev/null)
debug_output "$REMOTE_URL"

debug_cmd "git symbolic-ref --short HEAD"
CURRENT_BRANCH=$(git symbolic-ref --short HEAD 2>/dev/null || echo "detached HEAD")
debug_output "$CURRENT_BRANCH"

debug_cmd "git rev-parse --short HEAD"
HEAD_COMMIT=$(git rev-parse --short HEAD 2>/dev/null)
debug_output "$HEAD_COMMIT"

debug_cmd "git rev-parse HEAD"
HEAD_COMMIT_FULL=$(git rev-parse HEAD 2>/dev/null)
debug_output "$HEAD_COMMIT_FULL"

debug_cmd "git log -1 --pretty=format:'%s'"
LAST_COMMIT_MSG=$(git log -1 --pretty=format:"%s" 2>/dev/null)
debug_output "$LAST_COMMIT_MSG"

debug_cmd "git log -1 --pretty=format:'%an'"
LAST_COMMIT_AUTHOR=$(git log -1 --pretty=format:"%an" 2>/dev/null)
debug_output "$LAST_COMMIT_AUTHOR"

debug_cmd "git log -1 --pretty=format:'%ar'"
LAST_COMMIT_DATE=$(git log -1 --pretty=format:"%ar" 2>/dev/null)
debug_output "$LAST_COMMIT_DATE"

debug_cmd "git log -1 --pretty=format:'%ai'"
LAST_COMMIT_DATE_FULL=$(git log -1 --pretty=format:"%ai" 2>/dev/null)
debug_output "$LAST_COMMIT_DATE_FULL"

# --- Repository Information ---
if [[ "$SHOW_ALL" == true ]] || [[ "$SHOW_INFO" == true ]]; then
  print_section "Repository Information"

  print_kv "Repository path" "$REPO_ROOT"
  if [[ -n "$REMOTE_URL" ]]; then
    print_kv "Remote URL" "$REMOTE_URL"
  else
    print_kv "Remote URL" "${DIM}(none - local repository)${RESET}"
  fi

  print_kv "Current branch" "${GREEN}$CURRENT_BRANCH${RESET}"
  print_kv "HEAD commit" "$HEAD_COMMIT"
  print_kv "Last commit" "\"${YELLOW}$LAST_COMMIT_MSG${RESET}\""
  print_kv "Commit author" "$LAST_COMMIT_AUTHOR ${DIM}($LAST_COMMIT_DATE)${RESET}"
  print_kv "Commit date" "$LAST_COMMIT_DATE_FULL"
fi

# --- Working Tree Status ---
if [[ "$SHOW_ALL" == true ]] || [[ "$SHOW_STATUS" == true ]]; then
  print_section "Working Tree Status"

  # Check for uncommitted changes
  debug_cmd "git diff --name-only | wc -l"
  MODIFIED_FILES=$(git diff --name-only 2>/dev/null | wc -l)
  debug_output "$MODIFIED_FILES"

  debug_cmd "git diff --cached --name-only | wc -l"
  STAGED_FILES=$(git diff --cached --name-only 2>/dev/null | wc -l)
  debug_output "$STAGED_FILES"

  debug_cmd "git ls-files --others --exclude-standard | wc -l"
  UNTRACKED_FILES=$(git ls-files --others --exclude-standard 2>/dev/null | wc -l)
  debug_output "$UNTRACKED_FILES"

  print_kv "Modified files" "$MODIFIED_FILES"
  print_kv "Staged files" "$STAGED_FILES"
  print_kv "Untracked files" "$UNTRACKED_FILES"

  echo ""
  if [[ $MODIFIED_FILES -eq 0 ]] && [[ $STAGED_FILES -eq 0 ]] && [[ $UNTRACKED_FILES -eq 0 ]]; then
    print_success "Working tree is clean"
  else
    if [[ $MODIFIED_FILES -gt 0 ]]; then
      print_warn "$MODIFIED_FILES file(s) modified but not staged"
    fi
    if [[ $STAGED_FILES -gt 0 ]]; then
      print_info "$STAGED_FILES file(s) staged for commit"
    fi
  fi

  # Check if we're ahead/behind remote
  debug_cmd "git rev-parse --abbrev-ref --symbolic-full-name @{u}"
  if git rev-parse --abbrev-ref --symbolic-full-name @{u} >/dev/null 2>&1; then
    UPSTREAM=$(git rev-parse --abbrev-ref --symbolic-full-name @{u})
    debug_output "$UPSTREAM"

    debug_cmd "git rev-list --count @{u}..HEAD"
    AHEAD=$(git rev-list --count @{u}..HEAD 2>/dev/null || echo 0)
    debug_output "$AHEAD"

    debug_cmd "git rev-list --count HEAD..@{u}"
    BEHIND=$(git rev-list --count HEAD..@{u} 2>/dev/null || echo 0)
    debug_output "$BEHIND"

    echo ""
    print_kv "Upstream branch" "$UPSTREAM"

    if [[ $AHEAD -gt 0 ]]; then
      print_item "⬆" "${GREEN}Ahead by $AHEAD commit(s)${RESET}"
    fi
    if [[ $BEHIND -gt 0 ]]; then
      print_item "⬇" "${YELLOW}Behind by $BEHIND commit(s)${RESET}"
    fi
    if [[ $AHEAD -eq 0 ]] && [[ $BEHIND -eq 0 ]]; then
      print_success "Up to date with upstream"
    fi
  else
    echo ""
    print_warn "No upstream tracking configured"
  fi
fi

# --- Branch Information ---
if [[ "$SHOW_ALL" == true ]] || [[ "$SHOW_BRANCHES" == true ]]; then
  print_section "Branch Information"

  debug_cmd "git branch --list | wc -l"
  LOCAL_BRANCHES=$(git branch --list 2>/dev/null | wc -l)
  debug_output "$LOCAL_BRANCHES"

  debug_cmd "git branch -r | grep -v '\->' | wc -l"
  REMOTE_BRANCHES=$(git branch -r 2>/dev/null | grep -v '\->' | wc -l)
  debug_output "$REMOTE_BRANCHES"

  print_kv "Local branches" "$LOCAL_BRANCHES"
  print_kv "Remote branches" "$REMOTE_BRANCHES"

  echo ""
  echo -e "  ${BOLD}Local Branches (recent):${RESET}"
  git branch -v --sort=-committerdate 2>/dev/null | head -n 10 | sed 's/^/    /'
  if [[ $LOCAL_BRANCHES -gt 10 ]]; then
    echo -e "    ${DIM}... and $((LOCAL_BRANCHES - 10)) more${RESET}"
  fi

  if [[ "$DETAILED" == true ]]; then
    echo ""
    echo -e "  ${BOLD}Remote Branches (recent):${RESET}"
    git branch -r -v --sort=-committerdate 2>/dev/null | grep -v '\->' | head -n 10 | sed 's/^/    /'
    if [[ $REMOTE_BRANCHES -gt 10 ]]; then
      echo -e "    ${DIM}... and $((REMOTE_BRANCHES - 10)) more${RESET}"
    fi

    # Stale branches check
    echo ""
    echo -e "  ${BOLD}Stale branches:${RESET}"
    STALE_BRANCHES=$(git branch -vv 2>/dev/null | grep ': gone]' || true)
    if [[ -n "$STALE_BRANCHES" ]]; then
      print_warn "Found stale branches (remote deleted):"
      echo "$STALE_BRANCHES" | sed 's/^/    /'
    else
      print_success "No stale branches found"
    fi
  fi
fi

# --- Disk Space Usage ---
if [[ "$SHOW_ALL" == true ]] || [[ "$SHOW_USAGE" == true ]]; then
  print_section "Disk Space Usage"

  if [[ -d "$GIT_DIR" ]]; then
    debug_cmd "du -sh $GIT_DIR"
    GIT_SIZE=$(du -sh "$GIT_DIR" 2>/dev/null | cut -f1)
    debug_output "$GIT_SIZE"

    # Get working directory size (excluding .git)
    debug_cmd "du -sh --exclude=.git $REPO_ROOT"
    REPO_SIZE=$(du -sh --exclude=.git "$REPO_ROOT" 2>/dev/null | cut -f1)
    debug_output "$REPO_SIZE"

    debug_cmd "du -sh $REPO_ROOT"
    TOTAL_SIZE=$(du -sh "$REPO_ROOT" 2>/dev/null | cut -f1)
    debug_output "$TOTAL_SIZE"

    print_kv "Working directory" "$REPO_SIZE"
    print_kv ".git directory" "$GIT_SIZE"
    print_kv "Total size" "$TOTAL_SIZE"

    # Objects count
    OBJECTS_COUNT=$(git count-objects -v 2>/dev/null | grep '^count:' | awk '{print $2}')
    PACK_COUNT=$(git count-objects -v 2>/dev/null | grep '^packs:' | awk '{print $2}')
    SIZE_PACK=$(git count-objects -v 2>/dev/null | grep '^size-pack:' | awk '{print $2}')

    echo ""
    print_kv "Loose objects" "$OBJECTS_COUNT"
    print_kv "Pack files" "$PACK_COUNT (${SIZE_PACK}KB)"

    if [[ "$DETAILED" == true ]]; then
      echo ""
      echo -e "  ${BOLD}.git directory breakdown:${RESET}"
      du -sh "$GIT_DIR"/* 2>/dev/null | sort -hr | head -n 5 | sed 's/^/    /'
    fi

    # Check if garbage collection might help
    if [[ $OBJECTS_COUNT -gt 1000 ]]; then
      echo ""
      print_info "Consider running 'git gc' to optimize repository"
    fi
  else
    print_error "Could not access .git directory"
  fi
fi

# --- Commit Statistics ---
if [[ "$SHOW_ALL" == true ]] || [[ "$SHOW_COMMITS" == true ]]; then
  print_section "Commit Statistics"

  debug_cmd "git rev-list --count HEAD"
  TOTAL_COMMITS=$(git rev-list --count HEAD 2>/dev/null || echo 0)
  debug_output "$TOTAL_COMMITS"

  print_kv "Total commits" "$TOTAL_COMMITS"

  # First and last commit dates
  debug_cmd "git log --reverse --pretty=format:'%ai' | head -n 1"
  FIRST_COMMIT_DATE=$(git log --reverse --pretty=format:"%ai" 2>/dev/null | head -n 1)
  debug_output "$FIRST_COMMIT_DATE"
  print_kv "First commit" "$FIRST_COMMIT_DATE"
  print_kv "Latest commit" "$LAST_COMMIT_DATE_FULL"

  # Commits by time period
  COMMITS_LAST_DAY=$(git rev-list --count --since="1 day ago" HEAD 2>/dev/null || echo 0)
  COMMITS_LAST_WEEK=$(git rev-list --count --since="1 week ago" HEAD 2>/dev/null || echo 0)
  COMMITS_LAST_MONTH=$(git rev-list --count --since="1 month ago" HEAD 2>/dev/null || echo 0)

  echo ""
  echo -e "  ${BOLD}Recent activity:${RESET}"
  print_kv "  Last 24 hours" "$COMMITS_LAST_DAY commits"
  print_kv "  Last 7 days" "$COMMITS_LAST_WEEK commits"
  print_kv "  Last 30 days" "$COMMITS_LAST_MONTH commits"

  # Top contributors
  echo ""
  echo -e "  ${BOLD}Top contributors:${RESET}"
  git shortlog -sn --all --no-merges 2>/dev/null | head -n 5 | sed 's/^/    /'

  if [[ "$DETAILED" == true ]]; then
    # Recent commits
    echo ""
    echo -e "  ${BOLD}Recent commits (last 10):${RESET}"
    git log -10 --pretty=format:"    %C(auto)%h%Creset - %s %C(dim)(%ar by %an)%Creset" 2>/dev/null
    echo ""

    # Commit activity by day of week
    echo ""
    echo -e "  ${BOLD}Commit activity by day:${RESET}"
    git log --pretty=format:"%ad" --date=format:"%A" 2>/dev/null | sort | uniq -c | sort -rn | sed 's/^/    /'

    # File statistics
    TRACKED_FILES=$(git ls-files 2>/dev/null | wc -l)
    echo ""
    echo -e "  ${BOLD}File statistics:${RESET}"
    print_kv "  Tracked files" "$TRACKED_FILES"

    # Largest files
    echo ""
    echo -e "    ${DIM}Largest tracked files:${RESET}"
    git ls-files 2>/dev/null | xargs -I {} du -h {} 2>/dev/null | sort -hr | head -n 5 | sed 's/^/      /'
  fi
fi

# --- Remote Information ---
if [[ "$SHOW_ALL" == true ]] || [[ "$SHOW_REMOTES" == true ]]; then
  print_section "Remote Information"

  debug_cmd "git remote"
  REMOTES=$(git remote 2>/dev/null)
  debug_output "$REMOTES"
  if [[ -n "$REMOTES" ]]; then
    REMOTE_COUNT=$(echo "$REMOTES" | wc -l)
    print_kv "Configured remotes" "$REMOTE_COUNT"

    echo ""
    while IFS= read -r remote; do
      echo -e "  ${BOLD}Remote: $remote${RESET}"
      FETCH_URL=$(git remote get-url "$remote" 2>/dev/null)
      PUSH_URL=$(git remote get-url --push "$remote" 2>/dev/null)

      print_kv "  Fetch URL" "$FETCH_URL"
      if [[ "$FETCH_URL" != "$PUSH_URL" ]]; then
        print_kv "  Push URL" "$PUSH_URL"
      fi

      if [[ "$DETAILED" == true ]]; then
        REMOTE_BRANCH_COUNT=$(git branch -r 2>/dev/null | grep -c "^  $remote/" || echo 0)
        print_kv "  Branches" "$REMOTE_BRANCH_COUNT"
        echo ""
        echo -e "    ${DIM}Branch list:${RESET}"
        git branch -r 2>/dev/null | grep "^  $remote/" | sed 's/^/      /'
      fi
      echo ""
    done <<< "$REMOTES"
  else
    print_warn "No remotes configured"
  fi
fi

# --- Tags ---
if [[ "$SHOW_ALL" == true ]] || [[ "$SHOW_TAGS" == true ]]; then
  print_section "Tags"

  TAG_COUNT=$(git tag 2>/dev/null | wc -l)
  print_kv "Total tags" "$TAG_COUNT"

  if [[ $TAG_COUNT -gt 0 ]]; then
    echo ""
    echo -e "  ${BOLD}Recent tags:${RESET}"
    git tag --sort=-creatordate 2>/dev/null | head -n 5 | while read -r tag; do
      TAG_DATE=$(git log -1 --format="%ai" "$tag" 2>/dev/null)
      TAG_MSG=$(git tag -l --format='%(contents:subject)' "$tag" 2>/dev/null)
      if [[ -n "$TAG_MSG" ]]; then
        echo -e "    ${YELLOW}$tag${RESET} - $TAG_MSG ${DIM}(${TAG_DATE%% *})${RESET}"
      else
        echo -e "    ${YELLOW}$tag${RESET} ${DIM}(${TAG_DATE%% *})${RESET}"
      fi
    done
    if [[ $TAG_COUNT -gt 5 ]]; then
      echo -e "    ${DIM}... and $((TAG_COUNT - 5)) more${RESET}"
    fi
  fi
fi

# --- Summary ---
if [[ "$SHOW_ALL" == true ]] || [[ "$SHOW_SUMMARY" == true ]]; then
  print_section "Summary"

  CONTRIBUTORS=$(git shortlog -sn --all --no-merges 2>/dev/null | wc -l)

  # Recalculate these if not already done
  if [[ -z "$MODIFIED_FILES" ]]; then
    MODIFIED_FILES=$(git diff --name-only 2>/dev/null | wc -l)
    STAGED_FILES=$(git diff --cached --name-only 2>/dev/null | wc -l)
    UNTRACKED_FILES=$(git ls-files --others --exclude-standard 2>/dev/null | wc -l)
  fi

  if [[ -z "$LOCAL_BRANCHES" ]]; then
    LOCAL_BRANCHES=$(git branch --list 2>/dev/null | wc -l)
    REMOTE_BRANCHES=$(git branch -r 2>/dev/null | grep -v '\->' | wc -l)
  fi

  if [[ -z "$TOTAL_COMMITS" ]]; then
    TOTAL_COMMITS=$(git rev-list --count HEAD 2>/dev/null || echo 0)
  fi

  if [[ -z "$TAG_COUNT" ]]; then
    TAG_COUNT=$(git tag 2>/dev/null | wc -l)
  fi

  if [[ -z "$GIT_SIZE" ]]; then
    GIT_SIZE=$(du -sh "$GIT_DIR" 2>/dev/null | cut -f1)
  fi

  STATUS_TEXT=$([ $MODIFIED_FILES -eq 0 ] && [ $STAGED_FILES -eq 0 ] && [ $UNTRACKED_FILES -eq 0 ] && echo "${GREEN}clean${RESET}" || echo "${YELLOW}modified${RESET}")

  print_kv "Repository" "$REPO_ROOT"
  print_kv "Current branch" "${GREEN}$CURRENT_BRANCH${RESET}"
  print_kv "Total commits" "$TOTAL_COMMITS"
  print_kv "Branches" "$LOCAL_BRANCHES local, $REMOTE_BRANCHES remote"
  print_kv "Contributors" "$CONTRIBUTORS"
  print_kv "Tags" "$TAG_COUNT"
  print_kv "Disk usage" "$GIT_SIZE"
  print_kv "Status" "$STATUS_TEXT"
fi

echo ""
