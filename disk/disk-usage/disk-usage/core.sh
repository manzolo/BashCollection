# disk-usage module: help, size formatting, bars, colors
# Sourced by disk-usage.sh — do not execute directly.
show_help() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS] [DIRECTORY]
       $(basename "$0") [OPTIONS] --html [user@]host:/remote/path

Analyze folder sizes locally or on a remote host via SSH.
Without --html: colored terminal output (local only).
With --html: interactive Baobab-style HTML report (local or remote).

OPTIONS:
    -d, --depth DEPTH         Terminal analysis depth (default: 1)
    -w, --width WIDTH         Progress bar width (default: 20)
    -a, --all                 Include hidden files/folders
    -f, --files [N]           Show top N largest files (default: 10)
    -s, --sort TYPE           Sort by: size, name (default: size)
        --html [FILE]         Generate HTML report (default: temp file, auto-open)
        --html-depth DEPTH    Scan depth for HTML report (default: 3)
        --ssh-opts OPTS       Extra SSH options (e.g. '-p 2222 -i ~/.ssh/id_rsa')
    -h, --help                Show this help message

EXAMPLES:
    $(basename "$0")                              # Terminal: current directory
    $(basename "$0") /var/log                     # Terminal: /var/log
    $(basename "$0") -d 2 -f /home/user           # Terminal: 2 levels + top files
    $(basename "$0") --html /var/log              # HTML report for /var/log
    $(basename "$0") --html report.html -a .      # HTML report with hidden files
    $(basename "$0") --html user@server:/var/log  # HTML report from remote host
    $(basename "$0") --html root@nas:/data        # HTML report from NAS

EOF
}

human_readable() {
    local bytes=$1
    awk -v b="$bytes" 'BEGIN{
        u[0]="B";u[1]="K";u[2]="M";u[3]="G";u[4]="T";u[5]="P"
        s=b;i=0
        while(s>=1024&&i<5){s=s/1024;i++}
        printf "%.1f%s",s,u[i]
    }'
}

generate_bar() {
    local pct=$1 width=$2
    local filled empty bar=""
    filled=$(echo "scale=0; $pct * $width / 100" | bc)
    empty=$((width - filled))
    for ((i=0; i<filled; i++)); do bar+="▓"; done
    for ((i=0; i<empty; i++)); do bar+="░"; done
    echo "$bar"
}

get_color() {
    local pct=$1
    if   (( $(echo "$pct >= 90" | bc -l) )); then echo -e "$RED"
    elif (( $(echo "$pct >= 70" | bc -l) )); then echo -e "$YELLOW"
    elif (( $(echo "$pct >= 50" | bc -l) )); then echo -e "$CYAN"
    else echo -e "$GREEN"
    fi
}

