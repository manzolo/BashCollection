#!/bin/bash
# PKG_NAME: dmarc-report
# PKG_VERSION: 1.0.0
# PKG_SECTION: utils
# PKG_PRIORITY: optional
# PKG_ARCHITECTURE: all
# PKG_DEPENDS: bash (>= 4.0), libxml2-utils
# PKG_RECOMMENDS: gzip, unzip, tar
# PKG_MAINTAINER: Manzolo <manzolo@libero.it>
# PKG_DESCRIPTION: DMARC XML report analyzer
# PKG_LONG_DESCRIPTION: Parses DMARC aggregate report files and displays
#  a summary table with SPF/DKIM results per source IP.
#  .
#  Supported formats: .xml, .gz, .zip, .tar.gz, .tgz
#  Accepts individual files, archives, or entire directories.
# PKG_HOMEPAGE: https://github.com/manzolo/BashCollection

#===============================================================================
# DMARC REPORT ANALYZER
# Analyzes DMARC XML report files and produces a summary table.
#
# Usage: dmarc-report file1.xml [file2.xml] ...
#        dmarc-report report.xml.gz
#        dmarc-report report.zip
#        dmarc-report /path/to/folder
#        dmarc-report *.xml *.gz *.zip
#
# Supported formats: .xml, .gz, .zip, .tar.gz, .tgz
#===============================================================================

set -euo pipefail

# --- Colors ---
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m'
readonly BOLD='\033[1m'

# --- Temporary directory with auto-cleanup ---
TMPDIR_WORK=""

cleanup() {
    [[ -n "$TMPDIR_WORK" && -d "$TMPDIR_WORK" ]] && rm -rf "$TMPDIR_WORK"
}
trap cleanup EXIT

# --- Utility functions ---

msg_info()  { echo -e "  ${BLUE}[i]${NC} $*"; }
msg_ok()    { echo -e "  ${GREEN}[+]${NC} $*"; }
msg_warn()  { echo -e "  ${YELLOW}[!]${NC} $*"; }
msg_err()   { echo -e "  ${RED}[x]${NC} $*" >&2; }

usage() {
    cat <<EOF

${BOLD}DMARC Report Analyzer${NC}

Usage: $0 <file|folder> [file|folder] ...

Arguments:
  file.xml              DMARC XML report file
  file.xml.gz / file.gz Gzip-compressed file
  file.zip              ZIP archive
  file.tar.gz / file.tgz  tar+gzip archive
  /path/folder          Folder (recursively searches for XML and archives)

Examples:
  $0 report_google.xml
  $0 /path/to/dmarc/
  $0 report.zip *.xml.gz reports_folder/

EOF
    exit 1
}

# Check mandatory dependencies
check_dependencies() {
    local missing=()

    command -v xmllint &>/dev/null || missing+=("xmllint (libxml2-utils)")

    if (( ${#missing[@]} > 0 )); then
        msg_err "Missing dependencies:"
        for dep in "${missing[@]}"; do
            echo "       - $dep"
        done
        echo ""
        echo "  Install with: sudo apt install libxml2-utils"
        exit 1
    fi
}

# Check optional decompression tool (warn but don't block)
check_optional_tool() {
    local tool="$1" pkg="$2"
    if ! command -v "$tool" &>/dev/null; then
        msg_warn "'$tool' not found — some archives will be skipped (install: sudo apt install $pkg)"
        return 1
    fi
    return 0
}

# Known IP database
get_server_name() {
    local ip="$1"
    case "$ip" in
        212.29.129.*)                       echo "Enter.it"   ;;
        185.56.87.*)                        echo "SiteGround" ;;
        198.2.190.*|198.2.18*|205.201.13*)  echo "Mailchimp"  ;;
        209.85.*|172.217.*)                 echo "Google"      ;;
        40.107.*|52.100.*|104.47.*)         echo "Microsoft"   ;;
        *)                                  echo "Unknown"     ;;
    esac
}

# --- Archive extraction ---

# Create temp directory on first need
ensure_tmpdir() {
    if [[ -z "$TMPDIR_WORK" ]]; then
        TMPDIR_WORK=$(mktemp -d "${TMPDIR:-/tmp}/dmarc_analysis.XXXXXX")
    fi
}

# Extract a compressed file and return paths of found XMLs
extract_file() {
    local archive="$1"
    ensure_tmpdir

    local extract_dir
    extract_dir=$(mktemp -d "$TMPDIR_WORK/extract.XXXXXX")

    case "${archive,,}" in
        *.xml.gz|*.gz)
            if check_optional_tool gunzip gzip; then
                gunzip -c "$archive" > "$extract_dir/$(basename "${archive%.gz}")" 2>/dev/null
            fi
            ;;
        *.zip)
            if check_optional_tool unzip unzip; then
                unzip -q -o "$archive" -d "$extract_dir" 2>/dev/null
            fi
            ;;
        *.tar.gz|*.tgz)
            if check_optional_tool tar tar; then
                tar -xzf "$archive" -C "$extract_dir" 2>/dev/null
            fi
            ;;
        *)
            msg_warn "Unsupported format: $archive"
            return
            ;;
    esac

    # Find all extracted XMLs
    find "$extract_dir" -type f -iname '*.xml' 2>/dev/null
}

# --- Collect XML files to process ---

collect_xml_files() {
    local xml_files=()

    for arg in "$@"; do
        if [[ -d "$arg" ]]; then
            msg_info "Scanning folder: ${BOLD}$arg${NC}"
            while IFS= read -r -d '' f; do
                case "${f,,}" in
                    *.xml)
                        xml_files+=("$f")
                        ;;
                    *.gz|*.zip|*.tar.gz|*.tgz)
                        while IFS= read -r extracted; do
                            [[ -n "$extracted" ]] && xml_files+=("$extracted")
                        done < <(extract_file "$f")
                        ;;
                esac
            done < <(find "$arg" -type f \( -iname '*.xml' -o -iname '*.gz' -o -iname '*.zip' -o -iname '*.tar.gz' -o -iname '*.tgz' \) -print0 2>/dev/null)

        elif [[ -f "$arg" ]]; then
            case "${arg,,}" in
                *.xml)
                    xml_files+=("$arg")
                    ;;
                *.gz|*.zip|*.tar.gz|*.tgz)
                    while IFS= read -r extracted; do
                        [[ -n "$extracted" ]] && xml_files+=("$extracted")
                    done < <(extract_file "$arg")
                    ;;
                *)
                    msg_warn "Unrecognized file type: $arg"
                    ;;
            esac
        else
            msg_warn "Not found: $arg"
        fi
    done

    printf '%s\n' "${xml_files[@]}"
}

# --- XML parsing ---

# Global date range tracking (Unix timestamps)
GLOBAL_DATE_MIN=""
GLOBAL_DATE_MAX=""

parse_xml_file() {
    local xmlfile="$1"

    local org_name
    org_name=$(xmllint --xpath "string(//org_name)" "$xmlfile" 2>/dev/null) || true

    if [[ -z "$org_name" ]]; then
        msg_warn "Invalid or empty file: $xmlfile"
        return
    fi

    # Extract date range (Unix timestamps)
    local begin_ts end_ts date_begin date_end period_str=""
    begin_ts=$(xmllint --xpath "string(//date_range/begin)" "$xmlfile" 2>/dev/null) || true
    end_ts=$(xmllint   --xpath "string(//date_range/end)"   "$xmlfile" 2>/dev/null) || true

    if [[ "$begin_ts" =~ ^[0-9]+$ ]]; then
        date_begin=$(date -d "@$begin_ts" '+%Y-%m-%d' 2>/dev/null) || date_begin=""
        [[ -z "$GLOBAL_DATE_MIN" || "$begin_ts" -lt "$GLOBAL_DATE_MIN" ]] && GLOBAL_DATE_MIN="$begin_ts"
    fi
    if [[ "$end_ts" =~ ^[0-9]+$ ]]; then
        date_end=$(date -d "@$end_ts" '+%Y-%m-%d' 2>/dev/null) || date_end=""
        [[ -z "$GLOBAL_DATE_MAX" || "$end_ts" -gt "$GLOBAL_DATE_MAX" ]] && GLOBAL_DATE_MAX="$end_ts"
    fi

    if [[ -n "${date_begin:-}" && -n "${date_end:-}" ]]; then
        period_str=" | Period: $date_begin → $date_end"
    fi

    echo -e "  ${BLUE}--- Report from: ${BOLD}$org_name${NC}${BLUE}$period_str ($(basename "$xmlfile"))${NC}"

    local record_count
    record_count=$(xmllint --xpath "count(//record)" "$xmlfile" 2>/dev/null) || true
    record_count=${record_count%.*}

    for ((i = 1; i <= record_count; i++)); do
        local source_ip count dkim_result spf_result
        source_ip=$(xmllint  --xpath "string(//record[$i]/row/source_ip)"            "$xmlfile" 2>/dev/null) || true
        count=$(xmllint      --xpath "string(//record[$i]/row/count)"                "$xmlfile" 2>/dev/null) || true
        dkim_result=$(xmllint --xpath "string(//record[$i]/row/policy_evaluated/dkim)" "$xmlfile" 2>/dev/null) || true
        spf_result=$(xmllint  --xpath "string(//record[$i]/row/policy_evaluated/spf)"  "$xmlfile" 2>/dev/null) || true

        [[ -z "$source_ip" ]] && continue

        local key="$source_ip"
        local existing="${ip_data[$key]:-}"

        if [[ -z "$existing" ]]; then
            ip_data[$key]="$count|$spf_result|$dkim_result"
        else
            local old_count
            old_count=${existing%%|*}
            local new_count=$(( old_count + count ))
            ip_data[$key]="$new_count|${existing#*|}"
        fi
    done
}

# --- Output ---

print_header() {
    local file_count="$1"
    echo ""
    echo -e "${BOLD}${CYAN}+================================================================================+${NC}"
    echo -e "${BOLD}${CYAN}|                          DMARC REPORT ANALYSIS                                |${NC}"
    echo -e "${BOLD}${CYAN}+================================================================================+${NC}"
    echo ""
    echo -e "  ${BOLD}Analysis date:${NC}   $(date '+%Y-%m-%d %H:%M:%S')"
    echo -e "  ${BOLD}Files parsed:${NC}    $file_count"

    if [[ -n "$GLOBAL_DATE_MIN" && -n "$GLOBAL_DATE_MAX" ]]; then
        local d_min d_max
        d_min=$(date -d "@$GLOBAL_DATE_MIN" '+%Y-%m-%d' 2>/dev/null) || d_min="$GLOBAL_DATE_MIN"
        d_max=$(date -d "@$GLOBAL_DATE_MAX" '+%Y-%m-%d' 2>/dev/null) || d_max="$GLOBAL_DATE_MAX"
        echo -e "  ${BOLD}Report period:${NC}   $d_min → $d_max"
    fi

    echo ""
}

print_table() {
    local total_ok=0 total_fail=0 total_emails=0

    echo "+------------------+----------------+--------+----------+----------+------------------+"
    echo "| IP               | Server         | Emails | SPF      | DKIM     | Status           |"
    echo "+------------------+----------------+--------+----------+----------+------------------+"

    for ip in $(echo "${!ip_data[@]}" | tr ' ' '\n' | sort); do
        local data="${ip_data[$ip]}"
        local count="${data%%|*}"
        local rest="${data#*|}"
        local spf="${rest%%|*}"
        local dkim="${rest#*|}"
        local server
        server=$(get_server_name "$ip")

        total_emails=$(( total_emails + count ))

        local spf_ok=0 dkim_ok=0
        [[ "$spf"  == "pass" ]] && spf_ok=1
        [[ "$dkim" == "pass" ]] && dkim_ok=1

        local spf_txt="Fail"  dkim_txt="Fail"
        (( spf_ok  )) && spf_txt="Pass"
        (( dkim_ok )) && dkim_txt="Pass"

        local spf_col="${RED}" dkim_col="${RED}" stato_col="${YELLOW}"
        (( spf_ok  )) && spf_col="${GREEN}"
        (( dkim_ok )) && dkim_col="${GREEN}"

        local stato_icon="[!]" stato_txt=""
        if (( spf_ok && dkim_ok )); then
            stato_col="${GREEN}"
            stato_icon="[OK]"
            stato_txt="OK"
            total_ok=$(( total_ok + count ))
        else
            total_fail=$(( total_fail + count ))
            case "$server" in
                "Enter.it")   stato_txt="Problem"    ;;
                "SiteGround") stato_txt="SiteGround" ;;
                "Mailchimp")  stato_txt="Mailchimp"  ;;
                *)            stato_txt="Unknown"    ;;
            esac
        fi

        printf "| %-16s | %-14s | %6s | ${spf_col}%-8s${NC} | ${dkim_col}%-8s${NC} | ${stato_col}%-16s${NC} |\n" \
            "$ip" "$server" "$count" "$spf_txt" "$dkim_txt" "$stato_icon $stato_txt"
    done

    echo "+------------------+----------------+--------+----------+----------+------------------+"

    echo ""
    echo -e "${BOLD}--- STATISTICS ---${NC}"
    echo ""
    echo -e "  Total emails:      ${BOLD}$total_emails${NC}"
    echo -e "  Emails OK:         ${GREEN}$total_ok${NC}"
    echo -e "  Emails with errors: ${RED}$total_fail${NC}"

    if (( total_emails > 0 )); then
        local perc_ok=$(( total_ok * 100 / total_emails ))
        echo -e "  OK percentage:     ${BOLD}$perc_ok%${NC}"
    fi
    echo ""

    if (( total_fail > 0 )); then
        print_problems
    fi
}

print_problems() {
    echo -e "${BOLD}--- ISSUES DETECTED ---${NC}"
    echo ""

    for ip in $(echo "${!ip_data[@]}" | tr ' ' '\n' | sort); do
        local data="${ip_data[$ip]}"
        local rest="${data#*|}"
        local spf="${rest%%|*}"
        local dkim="${rest#*|}"
        local server
        server=$(get_server_name "$ip")

        [[ "$spf" == "pass" && "$dkim" == "pass" ]] && continue

        echo -e "  ${YELLOW}[!]${NC} IP ${BOLD}$ip${NC} ($server)"
        [[ "$spf"  != "pass" ]] && echo "      - SPF failed"
        [[ "$dkim" != "pass" ]] && echo "      - DKIM failed"

        case "$server" in
            "SiteGround")
                echo -e "      ${CYAN}-> Configure SMTP relay or add SiteGround to SPF${NC}" ;;
            "Mailchimp")
                echo -e "      ${CYAN}-> Check Mailchimp domain configuration${NC}" ;;
            *)
                echo -e "      ${CYAN}-> Verify whether this server is authorized${NC}" ;;
        esac
        echo ""
    done
}

print_footer() {
    echo "+================================================================================+"
    echo -e "  ${CYAN}Analysis complete${NC}"
    echo "+================================================================================+"
    echo ""
}

# --- Main ---

main() {
    [[ $# -eq 0 ]] && usage

    check_dependencies

    local xml_list
    xml_list=$(collect_xml_files "$@")

    local file_count
    file_count=$(echo "$xml_list" | grep -c '.' 2>/dev/null || echo 0)

    if (( file_count == 0 )); then
        msg_err "No XML files found."
        exit 1
    fi

    declare -gA ip_data

    ensure_tmpdir
    local parse_log="$TMPDIR_WORK/parse_output.txt"

    while IFS= read -r xmlfile; do
        [[ -n "$xmlfile" ]] && parse_xml_file "$xmlfile" >> "$parse_log"
    done <<< "$xml_list"

    print_header "$file_count"

    [[ -s "$parse_log" ]] && cat "$parse_log"

    if (( ${#ip_data[@]} == 0 )); then
        msg_warn "No DMARC records found in the analyzed files."
    else
        print_table
    fi

    print_footer
}

main "$@"
