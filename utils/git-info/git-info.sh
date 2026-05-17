#!/usr/bin/env bash
# PKG_NAME: git-info
# PKG_VERSION: 2.3.0
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
#  - Boxed dashboard layout with icons and badges
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
    --all)      SHOW_ALL=true;       shift ;;
    --info)     SHOW_INFO=true;      shift ;;
    --status)   SHOW_STATUS=true;    shift ;;
    --branches) SHOW_BRANCHES=true;  shift ;;
    --usage)    SHOW_USAGE=true;     shift ;;
    --commits)  SHOW_COMMITS=true;   shift ;;
    --remotes)  SHOW_REMOTES=true;   shift ;;
    --tags)     SHOW_TAGS=true;      shift ;;
    --summary)  SHOW_SUMMARY=true;   shift ;;
    --detailed) DETAILED=true;       shift ;;
    --debug)    DEBUG=true;          shift ;;
    --no-color) USE_COLOR=false;     shift ;;
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
  # Use $'...' so escape bytes are real ESC, not literal "\033". This is
  # required for strip_ansi/vwidth to compute correct visible widths.
  RESET=$'\033[0m'
  BOLD=$'\033[1m'
  DIM=$'\033[2m'
  FRAME=$'\033[38;5;244m'     # grey for box frames
  TITLE=$'\033[1;38;5;75m'    # bright cyan for section titles
  KEY=$'\033[1;38;5;252m'     # almost-white bold for keys
  YELLOW=$'\033[33m'
  GREEN=$'\033[32m'
  RED=$'\033[31m'
  CYAN=$'\033[36m'
  ORANGE=$'\033[38;5;208m'
  MAGENTA=$'\033[35m'
  BLUE=$'\033[34m'
  BADGE_GREEN=$'\033[1;30;42m'   # black on green
  BADGE_RED=$'\033[1;37;41m'     # white on red
  BADGE_YELLOW=$'\033[1;30;43m'  # black on yellow
  BADGE_BLUE=$'\033[1;37;44m'    # white on blue
else
  RESET=""; BOLD=""; DIM=""; FRAME=""; TITLE=""; KEY=""
  YELLOW=""; GREEN=""; RED=""; CYAN=""; ORANGE=""; MAGENTA=""; BLUE=""
  BADGE_GREEN=""; BADGE_RED=""; BADGE_YELLOW=""; BADGE_BLUE=""
fi

# --- Layout config ---
TERM_COLS=$(tput cols 2>/dev/null || echo 100)
TOTAL_WIDTH=90
[[ $TERM_COLS -lt $((TOTAL_WIDTH + 2)) ]] && TOTAL_WIDTH=$((TERM_COLS - 2))
[[ $TOTAL_WIDTH -lt 60 ]] && TOTAL_WIDTH=60

# --- Section icons ---
ICON_REPO="📦"
ICON_TREE="🌿"
ICON_BRANCH="🌳"
ICON_DISK="💾"
ICON_COMMITS="📊"
ICON_REMOTE="🔗"
ICON_TAGS="🏷 "
ICON_SUMMARY="📋"

# --- Helpers ---
strip_ansi() {
  printf '%s' "$1" | sed -E $'s/\033\\[[0-9;]*[a-zA-Z]//g'
}

# Visible width (assumes single-width chars in content; emoji are only in titles)
vwidth() {
  local s
  s=$(strip_ansi "$1")
  echo "${#s}"
}

repeat_char() {
  local ch="$1" n="$2"
  [[ $n -le 0 ]] && return
  printf "${ch}%.0s" $(seq 1 "$n")
}

# Truncate a plain string to at most N chars, adding ellipsis if cut.
truncate_str() {
  local s="$1" max="$2"
  if [[ ${#s} -gt $max ]]; then
    printf '%s…' "${s:0:$((max - 1))}"
  else
    printf '%s' "$s"
  fi
}

# Box drawing
# box_top "icon" "TITLE"
box_top() {
  local icon="$1"
  local title="$2"
  # Visible cells: "╭─ " (3) + icon(2 wide) + " " (1) + title(len) + " " (1) + dashes + "╮" (1)
  # We treat emoji icon as 2 columns.
  local title_len=${#title}
  local used=$((3 + 2 + 1 + title_len + 1 + 1))
  local dashes=$((TOTAL_WIDTH - used))
  [[ $dashes -lt 1 ]] && dashes=1
  printf "${FRAME}╭─${RESET} %s ${TITLE}%s${RESET} ${FRAME}" "$icon" "$title"
  repeat_char "─" "$dashes"
  printf "╮${RESET}\n"
}

# box_line "<content with optional ANSI>"
box_line() {
  local content="$1"
  local vw padding
  vw=$(vwidth "$content")
  padding=$((TOTAL_WIDTH - 4 - vw))
  [[ $padding -lt 0 ]] && padding=0
  printf "${FRAME}│${RESET} %b" "$content"
  printf "%*s" "$padding" ""
  printf " ${FRAME}│${RESET}\n"
}

box_blank() { box_line ""; }

box_bottom() {
  printf "${FRAME}╰"
  repeat_char "─" $((TOTAL_WIDTH - 2))
  printf "╯${RESET}\n"
}

# Key/Value row inside a box. Key column 14 chars.
box_kv() {
  local key="$1"
  local value="$2"
  box_line "$(printf "${KEY}%-14s${RESET} %b" "$key" "$value")"
}

# Sub-header inside a box (small label, dim)
box_sub() {
  local label="$1"
  box_line "$(printf "${DIM}── %s${RESET}" "$label")"
}

# Badge: status pill
badge() {
  local color="$1"
  local text="$2"
  printf "${color} %s ${RESET}" "$text"
}

# Sparkline char from value relative to max
spark_char() {
  local val=$1 max=$2
  local chars=("▁" "▂" "▃" "▄" "▅" "▆" "▇" "█")
  if [[ $max -le 0 ]]; then echo "${chars[0]}"; return; fi
  local idx=$(( val * 7 / max ))
  [[ $idx -lt 0 ]] && idx=0
  [[ $idx -gt 7 ]] && idx=7
  echo "${chars[$idx]}"
}

# Debug functions
debug_cmd() {
  [[ "$DEBUG" == true ]] && printf "%b[DEBUG]%b %b\$ %s%b\n" "$MAGENTA" "$RESET" "$DIM" "$1" "$RESET" >&2
}
debug_output() {
  if [[ "$DEBUG" == true ]] && [[ -n "$1" ]]; then
    printf "%b[DEBUG]%b %bOutput:%b\n" "$MAGENTA" "$RESET" "$DIM" "$RESET" >&2
    echo "$1" | sed 's/^/        /' >&2
  fi
}

# In debug mode, wrap `git` so every invocation is logged to stderr.
# Uses `command git` internally to avoid recursion.
if [[ "$DEBUG" == true ]]; then
  git() {
    printf "%b[DEBUG]%b %b\$ git %s%b\n" "$MAGENTA" "$RESET" "$DIM" "$*" "$RESET" >&2
    command git "$@"
  }
fi

# --- Dependency check ---
if ! command -v git >/dev/null 2>&1; then
  echo -e "${RED}✗ git is not installed${RESET}"
  exit 1
fi

# --- Validate repository ---
if [[ ! -d "$REPO_PATH" ]]; then
  echo -e "${RED}✗ Directory not found: $REPO_PATH${RESET}"
  exit 1
fi

cd "$REPO_PATH" || exit 1

if ! git rev-parse --git-dir >/dev/null 2>&1; then
  echo ""
  box_top "📦" "REPOSITORY"
  box_line "  $(badge "$BADGE_RED" "NOT A GIT REPO")  $(printf "${DIM}%s${RESET}" "$(pwd)")"
  box_bottom
  echo ""
  exit 1
fi

GIT_DIR=$(git rev-parse --git-dir)
REPO_ROOT=$(git rev-parse --show-toplevel)
REPO_ROOT_SHORT="${REPO_ROOT/#$HOME/~}"
REPO_NAME=$(basename "$REPO_ROOT")

# --- Collect data ---
debug_cmd "git config --get remote.origin.url"
REMOTE_URL=$(git config --get remote.origin.url 2>/dev/null)
debug_output "$REMOTE_URL"

# Short form of remote URL for display
short_remote() {
  local u="$1"
  [[ -z "$u" ]] && { echo ""; return; }
  # git@host:user/repo.git -> host:user/repo
  u="${u%.git}"
  u="${u#https://}"
  u="${u#http://}"
  u="${u#git@}"
  u="${u/:/\/}"
  echo "$u"
}
REMOTE_SHORT=$(short_remote "$REMOTE_URL")

CURRENT_BRANCH=$(git symbolic-ref --short HEAD 2>/dev/null || echo "detached HEAD")
HEAD_COMMIT=$(git rev-parse --short HEAD 2>/dev/null)
HEAD_COMMIT_FULL=$(git rev-parse HEAD 2>/dev/null)
LAST_COMMIT_MSG=$(git log -1 --pretty=format:"%s" 2>/dev/null)
LAST_COMMIT_AUTHOR=$(git log -1 --pretty=format:"%an" 2>/dev/null)
LAST_COMMIT_DATE=$(git log -1 --pretty=format:"%ar" 2>/dev/null)
LAST_COMMIT_DATE_FULL=$(git log -1 --pretty=format:"%ai" 2>/dev/null)

echo ""

# --- Repository Information ---
if [[ "$SHOW_ALL" == true ]] || [[ "$SHOW_INFO" == true ]]; then
  box_top "$ICON_REPO" "REPOSITORY"
  # Available width for value column (after "  Key<14>  " prefix and box padding)
  VAL_MAX=$((TOTAL_WIDTH - 4 - 14 - 1))
  [[ $VAL_MAX -lt 20 ]] && VAL_MAX=20

  box_kv "Path"    "${CYAN}$(truncate_str "$REPO_ROOT_SHORT" "$VAL_MAX")${RESET}"
  box_kv "Name"    "${BOLD}$(truncate_str "$REPO_NAME" "$VAL_MAX")${RESET}"
  box_kv "Branch"  "${GREEN}$(truncate_str "$CURRENT_BRANCH" "$VAL_MAX")${RESET}"
  if [[ -n "$REMOTE_SHORT" ]]; then
    box_kv "Remote"  "${BLUE}$(truncate_str "$REMOTE_SHORT" "$VAL_MAX")${RESET}"
  else
    box_kv "Remote"  "${DIM}(none — local only)${RESET}"
  fi
  if [[ -n "$HEAD_COMMIT" ]]; then
    box_kv "HEAD"    "${YELLOW}${HEAD_COMMIT}${RESET} ${DIM}·${RESET} ${LAST_COMMIT_DATE} ${DIM}·${RESET} ${LAST_COMMIT_AUTHOR}"
    # Reserve 2 chars for surrounding quotes
    MSG_TRUNC=$(truncate_str "$LAST_COMMIT_MSG" $((VAL_MAX - 2)))
    box_kv "Message" "\"${MSG_TRUNC}\""
  else
    box_kv "HEAD"    "${DIM}(no commits yet)${RESET}"
  fi
  box_bottom
  echo ""
fi

# --- Working Tree Status ---
if [[ "$SHOW_ALL" == true ]] || [[ "$SHOW_STATUS" == true ]]; then
  MODIFIED_FILES=$(git diff --name-only 2>/dev/null | wc -l)
  STAGED_FILES=$(git diff --cached --name-only 2>/dev/null | wc -l)
  UNTRACKED_FILES=$(git ls-files --others --exclude-standard 2>/dev/null | wc -l)
  # Ignored entries — counts collapsed dirs (e.g. node_modules/) as 1 entry,
  # matching what `git status --ignored` shows.
  IGNORED_COUNT=$(git status --ignored --porcelain 2>/dev/null | grep -c '^!!')
  STASH_COUNT=$(git stash list 2>/dev/null | wc -l)

  box_top "$ICON_TREE" "WORKING TREE"

  # Status badge line
  if [[ $MODIFIED_FILES -eq 0 ]] && [[ $STAGED_FILES -eq 0 ]] && [[ $UNTRACKED_FILES -eq 0 ]]; then
    STATUS_BADGE=$(badge "$BADGE_GREEN" "CLEAN")
  else
    STATUS_BADGE=$(badge "$BADGE_YELLOW" "DIRTY")
  fi

  # Upstream tracking
  UPSTREAM=""
  AHEAD=0
  BEHIND=0
  if git rev-parse --abbrev-ref --symbolic-full-name @{u} >/dev/null 2>&1; then
    UPSTREAM=$(git rev-parse --abbrev-ref --symbolic-full-name @{u})
    AHEAD=$(git rev-list --count @{u}..HEAD 2>/dev/null || echo 0)
    BEHIND=$(git rev-list --count HEAD..@{u} 2>/dev/null || echo 0)
  fi

  if [[ -n "$UPSTREAM" ]]; then
    if [[ $AHEAD -eq 0 ]] && [[ $BEHIND -eq 0 ]]; then
      SYNC_BADGE=$(badge "$BADGE_GREEN" "IN SYNC")
      SYNC_INFO="${DIM}with${RESET} ${BLUE}${UPSTREAM}${RESET}"
    else
      SYNC_BADGE=$(badge "$BADGE_BLUE" "DIVERGED")
      SYNC_INFO="${GREEN}↑${AHEAD}${RESET} ${YELLOW}↓${BEHIND}${RESET} ${DIM}vs${RESET} ${BLUE}${UPSTREAM}${RESET}"
    fi
  else
    SYNC_BADGE=$(badge "$BADGE_YELLOW" "NO UPSTREAM")
    SYNC_INFO="${DIM}push with -u to track${RESET}"
  fi

  box_line "  ${STATUS_BADGE}  ${SYNC_BADGE}  ${SYNC_INFO}"
  box_blank

  # Counters with coloured numbers
  M_COL=$([[ $MODIFIED_FILES -gt 0 ]] && echo "$ORANGE" || echo "$DIM")
  S_COL=$([[ $STAGED_FILES -gt 0 ]] && echo "$GREEN" || echo "$DIM")
  U_COL=$([[ $UNTRACKED_FILES -gt 0 ]] && echo "$YELLOW" || echo "$DIM")
  I_COL=$([[ $IGNORED_COUNT -gt 0 ]] && echo "$MAGENTA" || echo "$DIM")
  K_COL=$([[ $STASH_COUNT -gt 0 ]] && echo "$CYAN" || echo "$DIM")

  box_line "$(printf "  ${KEY}Modified${RESET} ${M_COL}%3d${RESET}   ${KEY}Staged${RESET} ${S_COL}%3d${RESET}   ${KEY}Untracked${RESET} ${U_COL}%3d${RESET}   ${KEY}Ignored${RESET} ${I_COL}%3d${RESET}   ${KEY}Stash${RESET} ${K_COL}%2d${RESET}" \
    "$MODIFIED_FILES" "$STAGED_FILES" "$UNTRACKED_FILES" "$IGNORED_COUNT" "$STASH_COUNT")"

  if [[ "$DETAILED" == true ]] && [[ $((MODIFIED_FILES + STAGED_FILES + UNTRACKED_FILES)) -gt 0 ]]; then
    box_blank
    box_sub "changed files (first 8)"
    git status --short 2>/dev/null | head -n 8 | while IFS= read -r line; do
      box_line "  ${DIM}${line}${RESET}"
    done
  fi
  if [[ "$DETAILED" == true ]] && [[ $IGNORED_COUNT -gt 0 ]]; then
    box_blank
    box_sub "ignored (first 8)"
    git status --ignored --porcelain 2>/dev/null | grep '^!!' | head -n 8 | while IFS= read -r line; do
      box_line "  ${MAGENTA}${line}${RESET}"
    done
  fi
  box_bottom
  echo ""
fi

# --- Branch Information ---
if [[ "$SHOW_ALL" == true ]] || [[ "$SHOW_BRANCHES" == true ]]; then
  LOCAL_BRANCHES=$(git branch --list 2>/dev/null | wc -l)
  REMOTE_BRANCHES=$(git branch -r 2>/dev/null | grep -v '\->' | wc -l)

  box_top "$ICON_BRANCH" "BRANCHES"
  box_line "$(printf "  ${KEY}Local${RESET}  ${BOLD}%d${RESET}     ${KEY}Remote${RESET}  ${BOLD}%d${RESET}" "$LOCAL_BRANCHES" "$REMOTE_BRANCHES")"
  box_blank
  box_sub "local (most recent)"

  git branch --sort=-committerdate --format='%(HEAD)|%(refname:short)|%(objectname:short)|%(committerdate:relative)|%(contents:subject)' 2>/dev/null \
    | head -n 8 | while IFS='|' read -r head name sha when subject; do
      local_marker="  "
      [[ "$head" == "*" ]] && local_marker="${GREEN}● ${RESET}"
      # Trim subject to fit
      max_subj=$((TOTAL_WIDTH - 50))
      [[ $max_subj -lt 10 ]] && max_subj=10
      if [[ ${#subject} -gt $max_subj ]]; then
        subject="${subject:0:$((max_subj - 1))}…"
      fi
      box_line "$(printf "%b%-30s ${YELLOW}%-8s${RESET} ${DIM}%s${RESET}" "$local_marker" "${name:0:30}" "$sha" "$when")"
      [[ "$DETAILED" == true ]] && box_line "$(printf "    ${DIM}%s${RESET}" "$subject")"
    done

  if [[ $LOCAL_BRANCHES -gt 8 ]]; then
    box_line "  ${DIM}… and $((LOCAL_BRANCHES - 8)) more${RESET}"
  fi

  if [[ "$DETAILED" == true ]]; then
    STALE_BRANCHES=$(git branch -vv 2>/dev/null | grep ': gone]' || true)
    if [[ -n "$STALE_BRANCHES" ]]; then
      box_blank
      box_sub "stale (upstream deleted)"
      while IFS= read -r line; do
        box_line "  ${ORANGE}${line}${RESET}"
      done <<< "$STALE_BRANCHES"
    fi
  fi
  box_bottom
  echo ""
fi

# --- Disk Space Usage ---
if [[ "$SHOW_ALL" == true ]] || [[ "$SHOW_USAGE" == true ]]; then
  box_top "$ICON_DISK" "DISK USAGE"
  if [[ -d "$GIT_DIR" ]]; then
    GIT_SIZE=$(du -sh "$GIT_DIR" 2>/dev/null | cut -f1)
    REPO_SIZE=$(du -sh --exclude=.git "$REPO_ROOT" 2>/dev/null | cut -f1)
    TOTAL_SIZE=$(du -sh "$REPO_ROOT" 2>/dev/null | cut -f1)

    box_line "$(printf "  ${KEY}.git${RESET}  ${BOLD}%-8s${RESET}   ${KEY}work${RESET}  ${BOLD}%-8s${RESET}   ${KEY}total${RESET}  ${BOLD}%s${RESET}" \
      "$GIT_SIZE" "$REPO_SIZE" "$TOTAL_SIZE")"

    OBJECTS_COUNT=$(git count-objects -v 2>/dev/null | grep '^count:' | awk '{print $2}')
    PACK_COUNT=$(git count-objects -v 2>/dev/null | grep '^packs:' | awk '{print $2}')
    SIZE_PACK=$(git count-objects -v 2>/dev/null | grep '^size-pack:' | awk '{print $2}')
    box_line "$(printf "  ${KEY}Objects${RESET} ${BOLD}%d${RESET} loose  ${DIM}·${RESET}  ${KEY}Packs${RESET} ${BOLD}%s${RESET} (${BOLD}%sKB${RESET})" \
      "${OBJECTS_COUNT:-0}" "${PACK_COUNT:-0}" "${SIZE_PACK:-0}")"

    if [[ "$DETAILED" == true ]]; then
      box_blank
      box_sub ".git breakdown (top 5)"
      du -sh "$GIT_DIR"/* 2>/dev/null | sort -hr | head -n 5 | while IFS= read -r line; do
        box_line "  ${DIM}${line}${RESET}"
      done
    fi

    if [[ ${OBJECTS_COUNT:-0} -gt 1000 ]]; then
      box_blank
      box_line "  ${ORANGE}⚠${RESET}  consider running ${BOLD}git gc${RESET} to optimize"
    fi
  else
    box_line "  ${RED}✗ could not access .git directory${RESET}"
  fi
  box_bottom
  echo ""
fi

# --- Commit Statistics ---
if [[ "$SHOW_ALL" == true ]] || [[ "$SHOW_COMMITS" == true ]]; then
  TOTAL_COMMITS=$(git rev-list --count HEAD 2>/dev/null || echo 0)
  FIRST_COMMIT_DATE=$(git log --reverse --pretty=format:"%ai" 2>/dev/null | head -n 1)
  COMMITS_LAST_DAY=$(git rev-list --count --since="1 day ago" HEAD 2>/dev/null || echo 0)
  COMMITS_LAST_WEEK=$(git rev-list --count --since="1 week ago" HEAD 2>/dev/null || echo 0)
  COMMITS_LAST_MONTH=$(git rev-list --count --since="1 month ago" HEAD 2>/dev/null || echo 0)

  # Sparkline scaled to the max of the three
  MAX_ACTIVITY=$COMMITS_LAST_MONTH
  [[ $COMMITS_LAST_WEEK -gt $MAX_ACTIVITY ]] && MAX_ACTIVITY=$COMMITS_LAST_WEEK
  [[ $COMMITS_LAST_DAY  -gt $MAX_ACTIVITY ]] && MAX_ACTIVITY=$COMMITS_LAST_DAY

  S_24=$(spark_char "$COMMITS_LAST_DAY"   "$MAX_ACTIVITY")
  S_7D=$(spark_char "$COMMITS_LAST_WEEK"  "$MAX_ACTIVITY")
  S_30=$(spark_char "$COMMITS_LAST_MONTH" "$MAX_ACTIVITY")

  box_top "$ICON_COMMITS" "COMMITS"
  box_line "$(printf "  ${KEY}Total${RESET}  ${BOLD}%-6s${RESET}   ${KEY}First${RESET}  ${DIM}%s${RESET}" \
    "$TOTAL_COMMITS" "${FIRST_COMMIT_DATE%% *}")"
  box_blank
  box_line "$(printf "  ${KEY}Activity${RESET}   24h ${GREEN}%s${RESET} ${BOLD}%-3d${RESET}    7d ${GREEN}%s${RESET} ${BOLD}%-3d${RESET}    30d ${GREEN}%s${RESET} ${BOLD}%d${RESET}" \
    "$S_24" "$COMMITS_LAST_DAY" "$S_7D" "$COMMITS_LAST_WEEK" "$S_30" "$COMMITS_LAST_MONTH")"

  box_blank
  box_sub "top contributors"
  git shortlog -sn --all --no-merges 2>/dev/null | head -n 5 | while IFS= read -r line; do
    count=$(echo "$line" | awk '{print $1}')
    author=$(echo "$line" | sed -E 's/^[[:space:]]*[0-9]+[[:space:]]+//')
    box_line "$(printf "  ${YELLOW}%4s${RESET}  %s" "$count" "$author")"
  done

  if [[ "$DETAILED" == true ]]; then
    box_blank
    box_sub "recent commits (last 8)"
    git log -8 --pretty=format:"%h|%s|%ar|%an" 2>/dev/null | while IFS='|' read -r sha subj when who; do
      max_subj=$((TOTAL_WIDTH - 40))
      [[ $max_subj -lt 10 ]] && max_subj=10
      [[ ${#subj} -gt $max_subj ]] && subj="${subj:0:$((max_subj - 1))}…"
      box_line "$(printf "  ${YELLOW}%-8s${RESET} %s ${DIM}(%s · %s)${RESET}" "$sha" "$subj" "$when" "$who")"
    done

    TRACKED_FILES=$(git ls-files 2>/dev/null | wc -l)
    box_blank
    box_kv "Tracked files" "${BOLD}${TRACKED_FILES}${RESET}"
  fi
  box_bottom
  echo ""
fi

# --- Remote Information ---
if [[ "$SHOW_ALL" == true ]] || [[ "$SHOW_REMOTES" == true ]]; then
  REMOTES=$(git remote 2>/dev/null)
  box_top "$ICON_REMOTE" "REMOTES"
  if [[ -n "$REMOTES" ]]; then
    REMOTE_COUNT=$(echo "$REMOTES" | wc -l)
    box_kv "Configured" "${BOLD}${REMOTE_COUNT}${RESET}"
    box_blank
    while IFS= read -r remote; do
      FETCH_URL=$(git remote get-url "$remote" 2>/dev/null)
      PUSH_URL=$(git remote get-url --push "$remote" 2>/dev/null)
      # Available width after "  ● <remote>   fetch " (3 + len(remote) + 9)
      URL_MAX=$((TOTAL_WIDTH - 4 - 3 - ${#remote} - 9))
      [[ $URL_MAX -lt 20 ]] && URL_MAX=20
      FETCH_TRUNC=$(truncate_str "$FETCH_URL" "$URL_MAX")
      box_line "  ${GREEN}●${RESET} ${BOLD}${remote}${RESET}   ${DIM}fetch${RESET} ${BLUE}${FETCH_TRUNC}${RESET}"
      if [[ "$FETCH_URL" != "$PUSH_URL" ]]; then
        PUSH_TRUNC=$(truncate_str "$PUSH_URL" "$URL_MAX")
        box_line "                  ${DIM}push ${RESET} ${BLUE}${PUSH_TRUNC}${RESET}"
      fi
      if [[ "$DETAILED" == true ]]; then
        REMOTE_BRANCH_COUNT=$(git branch -r 2>/dev/null | grep -c "^  $remote/" || echo 0)
        box_line "                  ${DIM}branches:${RESET} ${BOLD}${REMOTE_BRANCH_COUNT}${RESET}"
      fi
    done <<< "$REMOTES"
  else
    box_line "  $(badge "$BADGE_YELLOW" "NO REMOTES")  ${DIM}local-only repository${RESET}"
  fi
  box_bottom
  echo ""
fi

# --- Tags ---
if [[ "$SHOW_ALL" == true ]] || [[ "$SHOW_TAGS" == true ]]; then
  TAG_COUNT=$(git tag 2>/dev/null | wc -l)
  box_top "$ICON_TAGS" "TAGS"
  if [[ $TAG_COUNT -eq 0 ]]; then
    box_line "  ${DIM}no tags${RESET}"
  else
    box_kv "Total" "${BOLD}${TAG_COUNT}${RESET}"
    box_blank
    box_sub "most recent"
    git tag --sort=-creatordate 2>/dev/null | head -n 5 | while read -r tag; do
      TAG_DATE=$(git log -1 --format="%ai" "$tag" 2>/dev/null)
      TAG_MSG=$(git tag -l --format='%(contents:subject)' "$tag" 2>/dev/null)
      if [[ -n "$TAG_MSG" ]]; then
        max_msg=$((TOTAL_WIDTH - 35))
        [[ ${#TAG_MSG} -gt $max_msg ]] && TAG_MSG="${TAG_MSG:0:$((max_msg - 1))}…"
        box_line "  ${YELLOW}${tag}${RESET}  ${TAG_MSG}  ${DIM}(${TAG_DATE%% *})${RESET}"
      else
        box_line "  ${YELLOW}${tag}${RESET}  ${DIM}(${TAG_DATE%% *})${RESET}"
      fi
    done
    if [[ $TAG_COUNT -gt 5 ]]; then
      box_line "  ${DIM}… and $((TAG_COUNT - 5)) more${RESET}"
    fi
  fi
  box_bottom
  echo ""
fi

# --- Summary ---
if [[ "$SHOW_ALL" == true ]] || [[ "$SHOW_SUMMARY" == true ]]; then
  CONTRIBUTORS=$(git shortlog -sn --all --no-merges 2>/dev/null | wc -l)

  [[ -z "$MODIFIED_FILES"  ]] && MODIFIED_FILES=$(git diff --name-only 2>/dev/null | wc -l)
  [[ -z "$STAGED_FILES"    ]] && STAGED_FILES=$(git diff --cached --name-only 2>/dev/null | wc -l)
  [[ -z "$UNTRACKED_FILES" ]] && UNTRACKED_FILES=$(git ls-files --others --exclude-standard 2>/dev/null | wc -l)
  [[ -z "$LOCAL_BRANCHES"  ]] && LOCAL_BRANCHES=$(git branch --list 2>/dev/null | wc -l)
  [[ -z "$REMOTE_BRANCHES" ]] && REMOTE_BRANCHES=$(git branch -r 2>/dev/null | grep -v '\->' | wc -l)
  [[ -z "$TOTAL_COMMITS"   ]] && TOTAL_COMMITS=$(git rev-list --count HEAD 2>/dev/null || echo 0)
  [[ -z "$TAG_COUNT"       ]] && TAG_COUNT=$(git tag 2>/dev/null | wc -l)
  [[ -z "$GIT_SIZE"        ]] && GIT_SIZE=$(du -sh "$GIT_DIR" 2>/dev/null | cut -f1)

  if [[ $MODIFIED_FILES -eq 0 ]] && [[ $STAGED_FILES -eq 0 ]] && [[ $UNTRACKED_FILES -eq 0 ]]; then
    SUMMARY_BADGE=$(badge "$BADGE_GREEN" "CLEAN")
  else
    SUMMARY_BADGE=$(badge "$BADGE_YELLOW" "DIRTY")
  fi

  box_top "$ICON_SUMMARY" "SUMMARY"
  box_line "  ${BOLD}${REPO_NAME}${RESET} ${DIM}·${RESET} ${GREEN}${CURRENT_BRANCH}${RESET}  ${SUMMARY_BADGE}"
  box_blank
  box_kv "Commits"      "${BOLD}${TOTAL_COMMITS}${RESET}"
  box_kv "Branches"     "${BOLD}${LOCAL_BRANCHES}${RESET} local ${DIM}·${RESET} ${BOLD}${REMOTE_BRANCHES}${RESET} remote"
  box_kv "Contributors" "${BOLD}${CONTRIBUTORS}${RESET}"
  box_kv "Tags"         "${BOLD}${TAG_COUNT}${RESET}"
  box_kv "Disk"         "${BOLD}${GIT_SIZE}${RESET} ${DIM}(.git)${RESET}"
  box_bottom
  echo ""
fi
