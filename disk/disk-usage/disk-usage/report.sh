# disk-usage module: data collection and HTML report generation
# Sourced by disk-usage.sh — do not execute directly.
_collect_local_data() {
    local target_dir="$1" depth="$2"
    local root_size; root_size=$(du -sb "$target_dir" 2>/dev/null | cut -f1)
    printf '%s\tdir\t\n' "$root_size"
    while IFS= read -r dir; do
        local rel sz
        rel="${dir#"$target_dir"/}"
        sz=$(du -sb "$dir" 2>/dev/null | cut -f1)
        printf '%s\tdir\t%s\n' "$sz" "$rel"
    done < <(find "$target_dir" -maxdepth "$depth" -mindepth 1 -type d 2>/dev/null | sort)
    while IFS= read -r file; do
        local rel sz
        rel="${file#"$target_dir"/}"
        sz=$(stat -c%s "$file" 2>/dev/null || echo 0)
        printf '%s\tfile\t%s\n' "$sz" "$rel"
    done < <(find "$target_dir" -maxdepth "$depth" -mindepth 1 -type f 2>/dev/null | sort)
}

_collect_remote_data() {
    local host="$1" rpath="$2" depth="$3"
    # Build script: printf safely quotes the path, then append the logic via quoted heredoc
    {
        printf 'TARGET=%q\n' "$rpath"
        printf 'DEPTH=%q\n' "$depth"
        cat << 'REMOTE_SCRIPT'
root_size=$(du -sb "$TARGET" 2>/dev/null | cut -f1)
printf '%s\tdir\t\n' "$root_size"
find "$TARGET" -maxdepth "$DEPTH" -mindepth 1 -type d 2>/dev/null | sort | while IFS= read -r dir; do
    sz=$(du -sb "$dir" 2>/dev/null | cut -f1)
    rel="${dir#"$TARGET"/}"
    printf '%s\tdir\t%s\n' "$sz" "$rel"
done
find "$TARGET" -maxdepth "$DEPTH" -mindepth 1 -type f 2>/dev/null | sort | while IFS= read -r file; do
    sz=$(stat -c%s "$file" 2>/dev/null || echo 0)
    rel="${file#"$TARGET"/}"
    printf '%s\tfile\t%s\n' "$sz" "$rel"
done
REMOTE_SCRIPT
    } | ssh $SSH_OPTS "$host" bash
}

generate_html_report() {
    local output_file="$1"
    local root_name display_path tmp

    tmp=$(mktemp)

    if [ -n "$REMOTE_HOST" ]; then
        display_path="${REMOTE_HOST}:${REMOTE_PATH}"
        root_name=$(basename "$REMOTE_PATH")
        echo -e "${YELLOW}⏳ Scanning remote ${CYAN}${display_path}${YELLOW} (depth=${HTML_DEPTH})...${NC}"
        _collect_remote_data "$REMOTE_HOST" "$REMOTE_PATH" "$HTML_DEPTH" > "$tmp"
        if [ $? -ne 0 ] || [ ! -s "$tmp" ]; then
            rm -f "$tmp"
            echo -e "${RED}Error: SSH scan failed — check host, path and credentials${NC}"
            exit 1
        fi
    else
        local target_dir="$2"
        [ ! -d "$target_dir" ] && { echo -e "${RED}Error: '$target_dir' not found${NC}"; exit 1; }
        target_dir=$(realpath "$target_dir")
        display_path="$target_dir"
        root_name=$(basename "$target_dir")
        echo -e "${YELLOW}⏳ Scanning for HTML report (depth=${HTML_DEPTH})...${NC}"
        _collect_local_data "$target_dir" "$HTML_DEPTH" > "$tmp"
    fi

    local file_count dir_count root_size
    file_count=$(awk -F'\t' '$2=="file"' "$tmp" | wc -l)
    dir_count=$(awk -F'\t' '$2=="dir"' "$tmp" | wc -l)
    dir_count=$((dir_count - 1))
    root_size=$(awk -F'\t' 'NR==1{print $1}' "$tmp")

    local json
    json=$(awk -v rootname="$root_name" -F'\t' '
    function js(s,    r,i,c){
        r=""
        for(i=1;i<=length(s);i++){
            c=substr(s,i,1)
            if(c=="\\")r=r"\\\\"
            else if(c=="\"")r=r"\\\""
            else if(c=="\n")r=r"\\n"
            else if(c=="\r")r=r"\\r"
            else if(c=="\t")r=r"\\t"
            else r=r c
        }
        return "\""r"\""
    }
    function bn(p,    n,a){n=split(p,a,"/");return(n>0)?a[n]:"."}
    function dn(p,    nm,i){nm=bn(p);i=length(p)-length(nm);if(i<=0)return"";return substr(p,1,i-1)}
    function ex(nm,  n,a){n=split(nm,a,".");if(n<=1)return"";return tolower(a[n])}
    BEGIN{printf "["}
    {
        sz=$1;tp=$2
        rest=$0;sub(/^[^\t]+\t[^\t]+\t/,"",rest);path=rest
        nm=(path=="")?rootname:bn(path);par=dn(path);e=(tp=="file")?ex(nm):""
        if(NR>1)printf","
        printf "{\"path\":%s,\"name\":%s,\"size\":%s,\"type\":%s,\"parent\":%s,\"ext\":%s}",
            js(path),js(nm),sz,js(tp),js(par),js(e)
    }
    END{printf"]"}
    ' "$tmp")

    local human scan_date
    human=$(human_readable "$root_size")
    scan_date=$(date '+%Y-%m-%d %H:%M:%S')

    {
        _html_head "$root_name" "$display_path" "$scan_date" "$human" "$dir_count" "$file_count"
        printf '%s\n' "$json"
        _html_tail
    } > "$output_file"

    rm -f "$tmp"
    echo -e "\033[1A\033[K"
    echo -e "${GREEN}✓ HTML report: ${CYAN}$output_file${NC}"
    xdg-open "$output_file" 2>/dev/null || open "$output_file" 2>/dev/null || echo -e "  Open: ${YELLOW}$output_file${NC}"
}
