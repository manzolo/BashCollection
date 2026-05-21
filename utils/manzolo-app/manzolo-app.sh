#!/bin/bash
# PKG_NAME: manzolo-app
# PKG_VERSION: 1.0.0
# PKG_SECTION: utils
# PKG_PRIORITY: optional
# PKG_ARCHITECTURE: all
# PKG_DEPENDS: bash (>= 4.0), coreutils (>= 8.0), findutils (>= 4.0)
# PKG_MAINTAINER: Manzolo <manzolo@libero.it>
# PKG_DESCRIPTION: Catalog of BashCollection scripts with install status
# PKG_LONG_DESCRIPTION: Lists every script in the BashCollection repository,
#  grouped by category, showing whether each one is installed as a system
#  command and a short description pulled from the script PKG_* headers.
#  .
#  Features:
#  - Install status per script (installed / outdated / not installed)
#  - Short description and version from PKG_* headers
#  - Filter by installed/missing state or free-text search
#  - Locates the repository automatically (env var, symlink, common paths)
# PKG_HOMEPAGE: https://github.com/manzolo/BashCollection

set -u

VERSION="1.0.0"
INSTALL_DIR="/usr/local/bin"

# ---- colors -------------------------------------------------------------
setup_colors() {
    if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
        C_GREEN=$'\033[0;32m'; C_YELLOW=$'\033[1;33m'; C_RED=$'\033[0;31m'
        C_CYAN=$'\033[0;36m';  C_DIM=$'\033[2m';       C_BOLD=$'\033[1m'
        C_NC=$'\033[0m'
    else
        C_GREEN=''; C_YELLOW=''; C_RED=''; C_CYAN=''; C_DIM=''; C_BOLD=''; C_NC=''
    fi
}

# ---- help ---------------------------------------------------------------
show_help() {
    cat <<EOF
manzolo-app — BashCollection script catalog

Usage: manzolo-app [OPTIONS] [SEARCH]

Lists every script in the BashCollection repository, grouped by category,
with its install status and a short description from the PKG_* headers.

Options:
  -i, --installed     show only installed scripts
  -m, --missing       show only scripts that are not installed
      --no-color      disable colored output
  -V, --version       print version and exit
  -h, --help          show this help and exit

Arguments:
  SEARCH              show only scripts whose command name or description
                      contains SEARCH (case-insensitive)

Status legend:
  ${C_GREEN}✓${C_NC} installed        ${C_YELLOW}↑${C_NC} installed (older than repo)        ${C_DIM}○${C_NC} not installed

Repository lookup order:
  1. \$MANZOLO_REPO environment variable
  2. location of this script (when run from the repo)
  3. current working directory
  4. the installed 'manage_scripts' command
  5. common paths (~/Workspaces/BashCollection, ~/BashCollection)
EOF
}

# ---- repository discovery ----------------------------------------------
is_repo_root() {
    [ -f "$1/menage_scripts.sh" ] && [ -f "$1/.manzolomap" ]
}

find_repo_upwards() {
    local dir="$1"
    while [ -n "$dir" ] && [ "$dir" != "/" ]; do
        if is_repo_root "$dir"; then
            printf '%s' "$dir"
            return 0
        fi
        dir="$(dirname "$dir")"
    done
    return 1
}

detect_repo() {
    local self d cmd p

    if [ -n "${MANZOLO_REPO:-}" ] && is_repo_root "$MANZOLO_REPO"; then
        printf '%s' "$MANZOLO_REPO"; return 0
    fi

    self="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null)"
    if [ -n "$self" ] && d="$(find_repo_upwards "$(dirname "$self")")"; then
        printf '%s' "$d"; return 0
    fi

    if d="$(find_repo_upwards "$PWD")"; then
        printf '%s' "$d"; return 0
    fi

    for cmd in manage_scripts menage_scripts; do
        p="$(command -v "$cmd" 2>/dev/null)" || continue
        p="$(readlink -f "$p" 2>/dev/null)"
        [ -n "$p" ] || continue
        d="$(dirname "$p")"
        if is_repo_root "$d"; then
            printf '%s' "$d"; return 0
        fi
    done

    for d in "$HOME/Workspaces/BashCollection" "$HOME/BashCollection" \
             "$HOME/git/BashCollection" "$HOME/projects/BashCollection"; do
        if is_repo_root "$d"; then
            printf '%s' "$d"; return 0
        fi
    done

    return 1
}

# ---- PKG header parsing -------------------------------------------------
pkg_field() {
    local file="$1" field="$2" line
    line="$(grep -m1 -iE "^#[[:space:]]*PKG_${field}:" "$file" 2>/dev/null)" || return 0
    line="${line#*:}"
    line="${line#"${line%%[![:space:]]*}"}"   # trim leading whitespace
    line="${line%"${line##*[![:space:]]}"}"   # trim trailing whitespace
    printf '%s' "$line"
}

# ---- installed version detection ---------------------------------------
installed_version() {
    local bin="$1" real target ver
    if [ -L "$bin" ]; then
        real="$(readlink -f "$bin" 2>/dev/null)"
    elif [ -f "$bin" ]; then
        target="$(grep -m1 -oE '/[^ "]*\.sh' "$bin" 2>/dev/null)" || true
        real="$target"
    fi
    if [ -n "${real:-}" ] && [ -f "$real" ]; then
        ver="$(pkg_field "$real" VERSION)"
        [ -n "$ver" ] && { printf '%s' "$ver"; return; }
    fi
    ver="$(grep -m1 -oE 'wrapper - v[0-9][0-9.]*' "$bin" 2>/dev/null)" || true
    printf '%s' "${ver#wrapper - v}"
}

# ---- argument parsing ---------------------------------------------------
FILTER_STATE="all"   # all | installed | missing
SEARCH=""

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)      setup_colors; show_help; exit 0 ;;
        -V|--version)   echo "manzolo-app $VERSION"; exit 0 ;;
        -i|--installed) FILTER_STATE="installed" ;;
        -m|--missing)   FILTER_STATE="missing" ;;
        --no-color)     NO_COLOR=1 ;;
        --)             shift; [ $# -gt 0 ] && SEARCH="$1"; break ;;
        -*)             echo "Unknown option: $1" >&2
                        echo "Try 'manzolo-app --help'." >&2; exit 2 ;;
        *)              SEARCH="$1" ;;
    esac
    shift
done

setup_colors

# ---- locate repository --------------------------------------------------
REPO="$(detect_repo)" || {
    echo "${C_RED}✖ BashCollection repository not found.${C_NC}" >&2
    echo "  Set \$MANZOLO_REPO, or run this from inside the repo." >&2
    exit 1
}

IGNORE_FILE="$REPO/.manzoloignore"
MAP_FILE="$REPO/.manzolomap"

# ---- load .manzoloignore patterns --------------------------------------
IGNORE_PATTERNS=()
if [ -f "$IGNORE_FILE" ]; then
    while IFS= read -r line; do
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [ -n "$line" ] || continue
        case "$line" in \#*) continue ;; esac
        IGNORE_PATTERNS+=("$line")
    done < "$IGNORE_FILE"
fi

is_excluded() {
    local rel="$1" pat
    for pat in "${IGNORE_PATTERNS[@]}"; do
        # shellcheck disable=SC2053
        [[ "$rel" == $pat ]] && return 0
    done
    return 1
}

# ---- load .manzolomap mappings -----------------------------------------
declare -A NAME_MAP=()
if [ -f "$MAP_FILE" ]; then
    while IFS= read -r line; do
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [ -n "$line" ] || continue
        case "$line" in \#*) continue ;; esac
        if [[ "$line" == *#* ]]; then
            NAME_MAP["${line%%#*}"]="${line#*#}"
        fi
    done < "$MAP_FILE"
fi

# ---- scan scripts -------------------------------------------------------
ROWS=()
TOTAL=0 N_INSTALLED=0 N_MISSING=0 N_SHOWN=0
MAX_NAME=10

search_lc=""
[ -n "$SEARCH" ] && search_lc="${SEARCH,,}"

while IFS= read -r file; do
    rel="${file#"$REPO"/}"
    [[ "$rel" == */* ]] || continue          # skip repo-root files
    [ -x "$file" ] || continue               # match installer: executable only
    is_excluded "$rel" && continue

    category="${rel%%/*}"
    base="$(basename "$file" .sh)"
    name="${NAME_MAP[$rel]:-$base}"

    repo_ver="$(pkg_field "$file" VERSION)"
    desc="$(pkg_field "$file" DESCRIPTION)"
    [ -n "$desc" ] || desc="—"

    # install status
    inst_bin=""
    for cand in "$name" "$base"; do
        if [ -e "$INSTALL_DIR/$cand" ] || [ -L "$INSTALL_DIR/$cand" ]; then
            inst_bin="$INSTALL_DIR/$cand"
            break
        fi
    done

    state="missing"
    inst_ver=""
    if [ -n "$inst_bin" ]; then
        inst_ver="$(installed_version "$inst_bin")"
        if [ -n "$inst_ver" ] && [ -n "$repo_ver" ] && [ "$inst_ver" != "$repo_ver" ]; then
            state="outdated"
        else
            state="installed"
        fi
    fi

    TOTAL=$((TOTAL + 1))
    if [ "$state" = "missing" ]; then
        N_MISSING=$((N_MISSING + 1))
    else
        N_INSTALLED=$((N_INSTALLED + 1))
    fi

    # apply filters
    case "$FILTER_STATE" in
        installed) [ "$state" = "missing" ] && continue ;;
        missing)   [ "$state" != "missing" ] && continue ;;
    esac
    if [ -n "$search_lc" ]; then
        hay="${name,,} ${desc,,}"
        [[ "$hay" == *"$search_lc"* ]] || continue
    fi

    [ "${#name}" -gt "$MAX_NAME" ] && MAX_NAME="${#name}"
    N_SHOWN=$((N_SHOWN + 1))
    # Placeholders for possibly-empty fields: IFS=tab read collapses adjacent
    # tabs, so no inner field may be empty. desc (last) is always non-empty.
    ROWS+=("${category}"$'\t'"${name}"$'\t'"${state}"$'\t'"${repo_ver:-?}"$'\t'"${base}"$'\t'"${inst_ver:--}"$'\t'"${desc}")
done < <(find "$REPO" -type d -name .git -prune -o -type f -name '*.sh' -print)

# ---- render -------------------------------------------------------------
echo
echo "${C_BOLD}BashCollection${C_NC} ${C_DIM}— script catalog${C_NC}"
echo "${C_DIM}repo: $REPO${C_NC}"
echo

if [ "$N_SHOWN" -eq 0 ]; then
    echo "${C_YELLOW}No scripts match the current filter.${C_NC}"
    echo
    exit 0
fi

name_w=$((MAX_NAME + 2))
cur_cat=""

while IFS=$'\t' read -r category name state repo_ver base inst_ver desc; do
    if [ "$category" != "$cur_cat" ]; then
        cur_cat="$category"
        echo "${C_BOLD}${C_CYAN}▸ ${category}${C_NC}"
    fi

    case "$state" in
        installed) icon="${C_GREEN}✓${C_NC}"; name_col="${C_GREEN}" ;;
        outdated)  icon="${C_YELLOW}↑${C_NC}"; name_col="${C_YELLOW}" ;;
        *)         icon="${C_DIM}○${C_NC}";   name_col="${C_DIM}" ;;
    esac

    note=""
    [ "$name" != "$base" ] && note=" ${C_DIM}(alias: ${base})${C_NC}"
    [ "$state" = "outdated" ] && note="${note} ${C_YELLOW}[installed ${inst_ver}]${C_NC}"

    ver_disp="${repo_ver:-?}"
    printf '  %b  %b%-*s%b  %b%-9s%b %s%b\n' \
        "$icon" \
        "$name_col" "$name_w" "$name" "$C_NC" \
        "$C_DIM" "v${ver_disp}" "$C_NC" \
        "$desc" "$note"
done < <(printf '%s\n' "${ROWS[@]}" | LC_ALL=C sort -t$'\t' -k1,1 -k2,2)

echo
summary="${C_BOLD}${TOTAL} scripts${C_NC} · ${C_GREEN}${N_INSTALLED} installed${C_NC} · ${C_DIM}${N_MISSING} not installed${C_NC}"
if [ "$FILTER_STATE" != "all" ] || [ -n "$SEARCH" ]; then
    summary="${summary} · ${C_CYAN}${N_SHOWN} shown${C_NC}"
fi
echo "$summary"
echo
