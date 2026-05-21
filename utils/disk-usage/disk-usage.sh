#!/bin/bash
# PKG_NAME: disk-usage
# PKG_VERSION: 2.4.1
# PKG_SECTION: utils
# PKG_PRIORITY: optional
# PKG_ARCHITECTURE: all
# PKG_DEPENDS: bash (>= 4.0), coreutils (>= 8.0), findutils (>= 4.0)
# PKG_RECOMMENDS: ncdu
# PKG_MAINTAINER: Manzolo <manzolo@libero.it>
# PKG_DESCRIPTION: Advanced disk usage analyzer with HTML report export
# PKG_LONG_DESCRIPTION: Analyzes directory sizes with visual progress bars
#  and exports interactive Baobab-style HTML reports.
#  .
#  Features:
#  - Colored terminal output with progress bars
#  - Interactive HTML treemap (squarified, drill-down, breadcrumb)
#  - Sortable/filterable file table in HTML report
#  - Top N largest files listing
#  - Customizable scan depth and hidden file support
# PKG_HOMEPAGE: https://github.com/manzolo/BashCollection

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

MAX_DEPTH=1
BAR_WIDTH=20
SHOW_HIDDEN=false
SHOW_TOP_FILES=false
TOP_FILES_COUNT=10
HTML_OUTPUT=""
HTML_DEPTH=3
REMOTE_HOST=""
REMOTE_PATH=""
SSH_OPTS=""

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

show_top_files() {
    local target_dir="$1" count="$2" total_size="$3"
    echo
    echo -e "${BLUE}➤ Top $count Largest Files${NC}"
    echo "────────────────────────────────────────────"
    local tmp; tmp=$(mktemp)
    if [ "$SHOW_HIDDEN" = true ]; then
        find "$target_dir" -type f -exec du -b {} + 2>/dev/null | sort -rn | head -n "$count" > "$tmp"
    else
        find "$target_dir" -type f -not -path '*/\.*' -exec du -b {} + 2>/dev/null | sort -rn | head -n "$count" > "$tmp"
    fi
    local fc=0
    while read -r size filepath; do
        [ -z "$size" ] || [ -z "$filepath" ] && continue
        local name rel human pct
        name=$(basename "$filepath")
        rel="${filepath#"$target_dir"/}"
        human=$(human_readable "$size")
        pct=$(echo "scale=0; $size * 100 / $total_size" | bc)
        [ "$pct" = "0" ] || [ -z "$pct" ] && pct="<1"
        echo -e "${CYAN}📄 $name${NC}"
        echo -e "   Path: ${YELLOW}$rel${NC}"
        echo -e "   Size: ${GREEN}$human${NC} (${pct}% of total)"
        echo
        ((fc++))
    done < "$tmp"
    [ "$fc" -eq 0 ] && echo -e "${YELLOW}No files found.${NC}"
    rm -f "$tmp"
}

analyze_directory() {
    local target_dir="$1" depth="$2"
    [ ! -d "$target_dir" ] && { echo -e "${RED}Error: '$target_dir' does not exist!${NC}"; exit 1; }
    target_dir=$(realpath "$target_dir")

    echo -e "${BLUE}➤ Folder Analysis: ${CYAN}$target_dir${NC}"
    echo "────────────────────────────────────────────"
    echo -e "${YELLOW}⏳ Calculating sizes...${NC}"

    local total_size
    total_size=$(du -sb "$target_dir" 2>/dev/null | cut -f1)
    [ -z "$total_size" ] || [ "$total_size" = "0" ] && { echo -e "${RED}Error: cannot calculate size${NC}"; exit 1; }
    echo -e "\033[1A\033[K"

    local tmp; tmp=$(mktemp)
    if [ "$SHOW_HIDDEN" = true ]; then
        find "$target_dir" -maxdepth "$depth" -mindepth 1 -type d 2>/dev/null
    else
        find "$target_dir" -maxdepth "$depth" -mindepth 1 -type d -not -path '*/\.*' 2>/dev/null
    fi | while read -r dir; do
        local sz; sz=$(du -sb "$dir" 2>/dev/null | cut -f1)
        [ -n "$sz" ] && echo "$sz|$dir"
    done | sort -t'|' -k1 -rn > "$tmp"

    local count=0
    while IFS='|' read -r size dir; do
        [ -z "$size" ] || [ -z "$dir" ] && continue
        local dn human pct color bar
        dn=$(basename "$dir")
        human=$(human_readable "$size")
        pct=$(echo "scale=0; $size * 100 / $total_size" | bc)
        color=$(get_color "$pct")
        bar=$(generate_bar "$pct" "$BAR_WIDTH")
        echo -e "${CYAN}📁 $dn${NC}"
        echo -e "   Size: ${GREEN}$human${NC} (${pct}% of parent)"
        echo -e "   ${color}[$bar]${NC} ${pct}%"
        echo
        ((count++))
    done < "$tmp"

    echo "────────────────────────────────────────────"
    echo -e "${BLUE}📊 Total: ${GREEN}$(human_readable "$total_size")${NC}"
    echo -e "${BLUE}📂 Folders analyzed: ${GREEN}$count${NC}"
    [ "$SHOW_TOP_FILES" = true ] && show_top_files "$target_dir" "$TOP_FILES_COUNT" "$total_size"
    rm -f "$tmp"
}

# ─── HTML Report ──────────────────────────────────────────────────────────────

_html_escape() {
    local s="$1"
    s="${s//&/&amp;}"; s="${s//</&lt;}"; s="${s//>/&gt;}"
    echo "$s"
}

_html_head() {
    # unquoted heredoc: bash vars are expanded (only the 6 params below, no $ in CSS)
    local title="$1" scan_path="$2" scan_date="$3" total_human="$4" dir_count="$5" file_count="$6"
    title=$(_html_escape "$title")
    scan_path=$(_html_escape "$scan_path")
    cat << HTMLEOF
<!DOCTYPE html>
<html lang="it">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Disk Usage: ${title}</title>
<style>
*,*::before,*::after{box-sizing:border-box;margin:0;padding:0}
body{background:#0f0f1a;color:#e0e0e0;font-family:'Segoe UI',system-ui,sans-serif;min-height:100vh}
.header{background:linear-gradient(135deg,#1a1a3e,#0f0f1a);padding:18px 24px;border-bottom:1px solid #252545}
.header h1{font-size:1.35rem;font-weight:600;color:#fff}
.header .path{font-size:.82rem;color:#777;margin-top:4px;font-family:monospace;word-break:break-all}
.stats{display:flex;gap:10px;padding:14px 24px;background:#13131f;flex-wrap:wrap;border-bottom:1px solid #1e1e35}
.stat{background:#1e1e35;border-radius:8px;padding:10px 16px;flex:1;min-width:130px;border:1px solid #2a2a4e}
.stat .val{font-size:1.25rem;font-weight:700;color:#7eb8f7}
.stat .lbl{font-size:.7rem;color:#777;margin-top:3px;text-transform:uppercase;letter-spacing:.6px}
.section{padding:14px 24px}
.section-title{font-size:.95rem;font-weight:600;color:#aaa;margin-bottom:8px;display:flex;align-items:center;gap:8px}
/* Tabs */
.tabs{display:flex;gap:0;border-bottom:2px solid #252545;margin-bottom:10px}
.tab-btn{padding:7px 18px;background:none;border:none;border-bottom:2px solid transparent;margin-bottom:-2px;color:#666;cursor:pointer;font-size:.85rem;font-weight:600;transition:color .15s}
.tab-btn:hover{color:#bbb}
.tab-btn.active{color:#7eb8f7;border-bottom-color:#7eb8f7}
.tab-pane{display:none}.tab-pane.active{display:block}
/* Breadcrumb */
.breadcrumb{display:flex;align-items:center;gap:4px;flex-wrap:wrap;margin-bottom:8px;font-size:.82rem;min-height:28px}
.bc-item{color:#7eb8f7;cursor:pointer;padding:3px 10px;border-radius:4px;border:1px solid #2a3a5e;background:#1a2a4e;white-space:nowrap}
.bc-item:hover,.bc-item.bc-cur{background:#253a6e}
.bc-sep{color:#444}
/* Treemap */
#treemap{position:relative;height:400px;border-radius:8px;overflow:hidden;background:#0a0a14;border:1px solid #2a2a4e;cursor:default}
.tm-cell{position:absolute;overflow:hidden;transition:filter .12s}
.tm-cell:hover{filter:brightness(1.35);z-index:20}
.tm-cell.is-dir{cursor:pointer}
.tm-lbl{position:absolute;bottom:0;left:0;right:0;padding:2px 4px;font-size:10px;color:rgba(255,255,255,.82);background:rgba(0,0,0,.38);overflow:hidden;text-overflow:ellipsis;white-space:nowrap;pointer-events:none;line-height:1.4}
.tm-sz{font-size:9px;color:rgba(255,255,255,.55)}
/* Tree view */
#tree-view{border-radius:8px;overflow:auto;max-height:420px;background:#0a0a14;border:1px solid #2a2a4e;padding:6px 0}
.tv-row{font-size:.83rem}
.tv-item{display:flex;align-items:center;gap:5px;padding:3px 8px;cursor:pointer;border-radius:4px;margin:1px 4px;user-select:none}
.tv-item:hover{background:#18182e}
.tv-tog{width:16px;text-align:center;color:#555;font-size:.7rem;flex-shrink:0;transition:transform .1s}
.tv-ic{flex-shrink:0;font-size:.95rem}
.tv-nm{flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;min-width:0;font-weight:500}
.tv-bar-wrap{width:140px;height:7px;background:#1a1a2e;border-radius:3px;overflow:hidden;flex-shrink:0}
.tv-bar{height:100%;border-radius:3px}
.tv-sz{width:68px;text-align:right;font-family:monospace;color:#7eb8f7;font-size:.77rem;flex-shrink:0}
.tv-pct{width:38px;text-align:right;color:#555;font-size:.72rem;flex-shrink:0}
.tv-children{border-left:1px solid #1e1e35;margin-left:20px}
/* Tooltip */
#tooltip{position:fixed;background:#1c1c38;border:1px solid #3a3a6e;border-radius:7px;padding:8px 12px;font-size:.78rem;pointer-events:none;z-index:999;max-width:320px;display:none;box-shadow:0 4px 16px rgba(0,0,0,.5)}
#tooltip .tt-name{font-weight:600;color:#fff;margin-bottom:3px}
#tooltip .tt-path{color:#777;font-family:monospace;font-size:.72rem;word-break:break-all;margin-bottom:3px}
#tooltip .tt-size{color:#7eb8f7;font-weight:700}
/* Table */
.tbl-ctrl{display:flex;gap:8px;align-items:center;margin-bottom:10px;flex-wrap:wrap}
.srch{flex:1;min-width:200px;background:#1e1e35;border:1px solid #3a3a5e;border-radius:6px;padding:7px 12px;color:#e0e0e0;font-size:.85rem;outline:none}
.srch:focus{border-color:#5a7abf}
.sel{background:#1e1e35;border:1px solid #3a3a5e;border-radius:6px;padding:7px 10px;color:#e0e0e0;font-size:.85rem;cursor:pointer;outline:none}
.rcnt{font-size:.78rem;color:#555}
.tbl-wrap{overflow-x:auto;border-radius:8px;border:1px solid #2a2a4e;max-height:480px;overflow-y:auto}
table{width:100%;border-collapse:collapse;font-size:.83rem}
thead{background:#16163a;position:sticky;top:0;z-index:5}
th{padding:9px 11px;text-align:left;font-weight:600;color:#999;cursor:pointer;user-select:none;white-space:nowrap;border-bottom:1px solid #2a2a4e}
th:hover{color:#ddd;background:#1e1e45}
th .arr{margin-left:4px;opacity:.35;font-size:.8rem}
th.srt .arr{opacity:1;color:#7eb8f7}
td{padding:7px 11px;border-bottom:1px solid #18182e;vertical-align:middle}
tr:hover td{background:#16162e}
.ic{font-size:1rem}
.nm{font-weight:500;white-space:nowrap;max-width:220px;overflow:hidden;text-overflow:ellipsis}
.pt{font-family:monospace;font-size:.75rem;color:#777;max-width:280px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.sz{text-align:right;font-family:monospace;color:#7eb8f7;white-space:nowrap}
.badge{display:inline-block;padding:2px 7px;border-radius:10px;font-size:.72rem;font-weight:600}
.badge.dir{background:#1e3050;color:#7eb8f7}
.badge.file{background:#1e3025;color:#7abf7a}
footer{text-align:center;padding:18px;color:#333;font-size:.72rem;border-top:1px solid #18182e;margin-top:4px}
</style>
</head>
<body>
<div class="header">
  <h1>📊 Disk Usage Report — ${title}</h1>
  <div class="path">${scan_path}</div>
</div>
<div class="stats">
  <div class="stat"><div class="val">${total_human}</div><div class="lbl">Total Size</div></div>
  <div class="stat"><div class="val">${dir_count}</div><div class="lbl">Directories</div></div>
  <div class="stat"><div class="val">${file_count}</div><div class="lbl">Files</div></div>
  <div class="stat"><div class="val" id="stat-lg">—</div><div class="lbl">Largest File</div></div>
  <div class="stat"><div class="val">${scan_date}</div><div class="lbl">Scan Date</div></div>
</div>
<div class="section">
  <div class="section-title">🗂️ Explorer</div>
  <div class="tabs">
    <button class="tab-btn active" data-tab="tm">🗺️ Map</button>
    <button class="tab-btn" data-tab="tree">🌳 Tree</button>
  </div>
  <div id="tab-tm" class="tab-pane active">
    <div class="breadcrumb" id="bc"></div>
    <div id="treemap"></div>
    <div style="font-size:.72rem;color:#333;margin-top:5px;text-align:right">click directory to drill down · click background to go up</div>
  </div>
  <div id="tab-tree" class="tab-pane">
    <div id="tree-view"></div>
  </div>
</div>
<div class="section">
  <div class="section-title">📋 Files &amp; Directories</div>
  <div class="tbl-ctrl">
    <input type="text" class="srch" id="srch" placeholder="🔍  Filter by name or path…">
    <select class="sel" id="tf">
      <option value="all">All types</option>
      <option value="dir">📁 Directories</option>
      <option value="file">📄 Files</option>
    </select>
    <span class="rcnt" id="rcnt"></span>
  </div>
  <div class="tbl-wrap">
    <table id="ftbl">
      <thead><tr>
        <th style="width:36px"></th>
        <th data-c="name">Name <span class="arr">↕</span></th>
        <th data-c="path">Path <span class="arr">↕</span></th>
        <th data-c="size" class="srt">Size <span class="arr">↓</span></th>
        <th data-c="type">Type <span class="arr">↕</span></th>
      </tr></thead>
      <tbody id="tb"></tbody>
    </table>
  </div>
</div>
<div id="tooltip"><div class="tt-name" id="ttn"></div><div class="tt-path" id="ttp"></div><div class="tt-size" id="tts"></div></div>
<footer>Generated by disk-usage · ${scan_date}</footer>
<script>
/* DATA injected by disk-usage.sh */
const DATA =
HTMLEOF
}

_html_tail() {
    # quoted heredoc: no bash expansion — safe for all JS $ signs
    cat << 'HTMLEOF'
;
/* ── Utilities ─────────────────────────────────────────────────────────── */
function fmt(b){
    if(!b)return'0 B';
    const u=['B','KB','MB','GB','TB','PB'],i=Math.min(Math.floor(Math.log2(b)/10),5);
    return(b/Math.pow(1024,i)).toFixed(i?1:0)+' '+u[i];
}
function esc(s){return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');}
function icon(n,t,e){
    if(t==='dir')return'📁';
    const m={jpg:'🖼️',jpeg:'🖼️',png:'🖼️',gif:'🖼️',svg:'🖼️',webp:'🖼️',bmp:'🖼️',
        mp4:'🎬',mkv:'🎬',avi:'🎬',mov:'🎬',wmv:'🎬',webm:'🎬',
        mp3:'🎵',flac:'🎵',wav:'🎵',ogg:'🎵',aac:'🎵',m4a:'🎵',
        pdf:'📕',doc:'📝',docx:'📝',odt:'📝',
        xls:'📊',xlsx:'📊',ods:'📊',csv:'📊',
        ppt:'📑',pptx:'📑',odp:'📑',
        zip:'📦',tar:'📦',gz:'📦',bz2:'📦',xz:'📦','7z':'📦',rar:'📦',tgz:'📦',
        sh:'⚙️',bash:'⚙️',zsh:'⚙️',py:'🐍',
        js:'💛',ts:'💛',jsx:'💛',tsx:'💛',
        html:'🌐',htm:'🌐',css:'🌐',
        json:'📋',yaml:'📋',yml:'📋',toml:'📋',xml:'📋',
        sql:'🗄️',db:'🗄️',sqlite:'🗄️',
        iso:'💿',img:'💿',qcow2:'💿',vdi:'💿',vmdk:'💿',
        log:'📜',txt:'📄',md:'📄',rst:'📄',deb:'📥',rpm:'📥'};
    return m[(e||'').toLowerCase()]||'📄';
}

/* ── Tree Builder (fixed: root children properly populated) ─────────────── */
function buildTree(flat){
    const by={};
    for(const n of flat) by[n.path]={...n,children:[]};
    for(const n of flat){
        if(n.path==='')continue; // skip root entry itself
        const par=n.parent;
        if(par===''||par===null||par===undefined){
            // top-level: attach to root
            if(by[''])by[''].children.push(by[n.path]);
        } else if(by[par]){
            by[par].children.push(by[n.path]);
        }
    }
    return by['']||{name:'root',size:0,type:'dir',path:'',children:[]};
}

/* ── Squarified Treemap ─────────────────────────────────────────────────── */
function squarify(nodes,x,y,w,h){
    const total=nodes.reduce((s,n)=>s+n.size,0);
    if(!nodes.length||!total||w<=0||h<=0)return[];
    const area=w*h;
    const sc=nodes.map(n=>({...n,_a:n.size/total*area}));
    return _sq(sc,x,y,w,h);
}
function _worst(row,ra,sh){
    if(!row.length||!ra||!sh)return Infinity;
    const mx=Math.max(...row.map(i=>i._a)),mn=Math.min(...row.map(i=>i._a)),s2=sh*sh;
    return Math.max(s2*mx/(ra*ra),ra*ra/(s2*mn));
}
function _sq(items,x,y,w,h){
    if(!items.length)return[];
    if(items.length===1)return[{...items[0],x,y,w,h}];
    const sh=Math.min(w,h);
    let row=[],ra=0,pw=Infinity,cut=0;
    for(let i=0;i<items.length;i++){
        const nr=[...row,items[i]],na=ra+items[i]._a,wst=_worst(nr,na,sh);
        if(wst>pw&&row.length>0)break;
        row=nr;ra=na;pw=wst;cut=i+1;
    }
    const placed=_place(row,ra,x,y,w,h),rest=items.slice(cut);
    if(!rest.length)return placed;
    const[nx,ny,nw,nh]=_next(ra,x,y,w,h);
    if(nw<=0||nh<=0)return placed;
    return[...placed,..._sq(rest,nx,ny,nw,nh)];
}
function _place(row,ra,x,y,w,h){
    const wide=w>=h,T=ra/(wide?h:w);
    let off=0;
    return row.map(it=>{
        const sp=it._a/T,cell=wide?{x,y:y+off,w:T,h:sp}:{x:x+off,y,w:sp,h:T};
        off+=sp;return{...it,...cell};
    });
}
function _next(ra,x,y,w,h){
    const wide=w>=h,T=ra/(wide?h:w);
    return wide?[x+T,y,w-T,h]:[x,y+T,w,h-T];
}

/* ── Colors ─────────────────────────────────────────────────────────────── */
const HUES=[210,155,42,275,18,335,115,255,185,78];
const _hmap={};let _hi=0;
function hue(path){const t=(path||'').split('/')[0]||'_root';if(!_hmap[t])_hmap[t]=HUES[_hi++%HUES.length];return _hmap[t];}
function clr(n,d){const h=hue(n.path||n.name),s=n.type==='dir'?58:40,l=Math.max(18,n.type==='dir'?40-d*5:48-d*5);return`hsl(${h},${s}%,${l}%)`;}
/* green(120) → yellow(60) → red(0) based on % of parent */
function barClr(pct){return`hsl(${Math.round(120-Math.min(pct,100)*1.2)},70%,42%)`;}

/* ── Treemap Renderer ───────────────────────────────────────────────────── */
let _root=null,_tmStack=[],_cur=null,_dep=0,_bcCurrent=null;

function tmRender(node,depth){
    _cur=node;_dep=depth;_bcCurrent=node;
    const c=document.getElementById('treemap');
    const W=c.offsetWidth,H=c.offsetHeight;
    c.innerHTML='';
    const kids=[...(node.children||[])].filter(k=>k.size>0).sort((a,b)=>b.size-a.size);
    if(!kids.length){
        c.innerHTML='<div style="display:flex;align-items:center;justify-content:center;height:100%;color:#444;font-size:.88rem">Empty directory</div>';
        bcRender();return;
    }
    const cells=squarify(kids,0,0,W,H);
    for(const cell of cells){
        if(cell.w<2||cell.h<2)continue;
        const div=document.createElement('div');
        div.className='tm-cell'+(cell.type==='dir'?' is-dir':'');
        div.style.cssText=`left:${cell.x.toFixed(1)}px;top:${cell.y.toFixed(1)}px;width:${Math.max(0,cell.w-1).toFixed(1)}px;height:${Math.max(0,cell.h-1).toFixed(1)}px;background:${clr(cell,depth)};border:1px solid rgba(0,0,0,.4);border-radius:2px`;
        if(cell.w>44&&cell.h>16){
            const lb=document.createElement('div');
            lb.className='tm-lbl';
            lb.innerHTML=(cell.type==='dir'?'📁 ':'')+esc(cell.name)+(cell.h>30?`<br><span class="tm-sz">${fmt(cell.size)}</span>`:'');
            div.appendChild(lb);
        }
        div.addEventListener('mouseenter',e=>ttShow(e,cell));
        div.addEventListener('mousemove',e=>ttMove(e));
        div.addEventListener('mouseleave',ttHide);
        div.addEventListener('click',e=>{
            e.stopPropagation();
            if(cell.type==='dir'&&(cell.children||[]).length>0){_tmStack.push({node,depth});tmRender(cell,depth+1);}
        });
        c.appendChild(div);
    }
    c.addEventListener('click',()=>{
        if(_tmStack.length){const s=_tmStack.pop();tmRender(s.node,s.depth);}
    },{once:true});
    bcRender();
}

/* Breadcrumb: derived from _tmStack (ancestors) + _bcCurrent (displayed node).
   _tmStack[0] is always the root ancestor, so we never prepend _root separately. */
function bcRender(){
    const bc=document.getElementById('bc');
    bc.innerHTML='';
    // Ancestors: stack items, using root's real name for index 0
    const chain=_tmStack.length>0
        ?_tmStack.map((s,i)=>({node:s.node,name:i===0?(_root.name||'root'):s.node.name}))
        :[{node:_root,name:_root.name||'root'}];
    // Current displayed node: append if different from last ancestor
    const last=chain[chain.length-1];
    if(_bcCurrent&&_bcCurrent!==last.node){
        chain.push({node:_bcCurrent,name:_bcCurrent.name,cur:true});
    } else {
        chain[chain.length-1]={...last,cur:true};
    }
    chain.forEach((item,i)=>{
        if(i>0){const sp=document.createElement('span');sp.className='bc-sep';sp.textContent=' › ';bc.appendChild(sp);}
        const el=document.createElement('span');
        el.className='bc-item'+(item.cur?' bc-cur':'');
        el.textContent=item.name;
        if(!item.cur){
            const cn=item.node,cd=i;
            el.addEventListener('click',()=>{_tmStack=_tmStack.slice(0,cd);tmRender(cn,cd);});
        }
        bc.appendChild(el);
    });
}

/* ── Tree View ──────────────────────────────────────────────────────────── */
function tvInit(root){
    const container=document.getElementById('tree-view');
    container.innerHTML='';
    const kids=[...(root.children||[])].sort((a,b)=>b.size-a.size);
    const maxS=kids.length?kids[0].size:0;
    for(const child of kids) container.appendChild(tvRow(child,0,maxS,root.size));
}

function tvRow(node,depth,maxSib,parentSz){
    const outer=document.createElement('div');
    outer.className='tv-row';
    const hasKids=node.type==='dir'&&(node.children||[]).length>0;
    const barW=maxSib>0?Math.round(node.size/maxSib*140):0;
    const pct=parentSz>0?Math.round(node.size/parentSz*100):0;

    const item=document.createElement('div');
    item.className='tv-item';
    item.style.paddingLeft=(8+depth*20)+'px';
    item.innerHTML=
        `<span class="tv-tog">${hasKids?'►':''}</span>`+
        `<span class="tv-ic">${icon(node.name,node.type,node.ext)}</span>`+
        `<span class="tv-nm" title="${esc(node.path||node.name)}">${esc(node.name)}</span>`+
        `<span class="tv-bar-wrap"><span class="tv-bar" style="width:${barW}px;background:${barClr(pct)}"></span></span>`+
        `<span class="tv-sz">${fmt(node.size)}</span>`+
        `<span class="tv-pct">${pct?pct+'%':''}</span>`;
    outer.appendChild(item);

    if(hasKids){
        const kids=document.createElement('div');
        kids.className='tv-children';
        kids.style.display='none';
        outer.appendChild(kids);
        let rendered=false;

        item.addEventListener('click',e=>{
            e.stopPropagation();
            const open=kids.style.display!=='none';
            if(!open&&!rendered){
                rendered=true;
                const sorted=[...node.children].sort((a,b)=>b.size-a.size);
                const ms=sorted.length?sorted[0].size:0;
                for(const c of sorted) kids.appendChild(tvRow(c,depth+1,ms,node.size));
            }
            kids.style.display=open?'none':'block';
            item.querySelector('.tv-tog').textContent=open?'►':'▼';
        });
    }
    return outer;
}

/* ── Tab Switcher ───────────────────────────────────────────────────────── */
function initTabs(){
    document.querySelectorAll('.tab-btn').forEach(btn=>{
        btn.addEventListener('click',()=>{
            document.querySelectorAll('.tab-btn').forEach(b=>b.classList.remove('active'));
            document.querySelectorAll('.tab-pane').forEach(p=>p.classList.remove('active'));
            btn.classList.add('active');
            document.getElementById('tab-'+btn.dataset.tab).classList.add('active');
            // Re-render treemap when switching to map tab (size may have changed)
            if(btn.dataset.tab==='tm'&&_cur) setTimeout(()=>tmRender(_cur,_dep),10);
        });
    });
}

/* ── Tooltip ────────────────────────────────────────────────────────────── */
function ttShow(e,n){
    document.getElementById('ttn').textContent=(n.type==='dir'?'📁 ':'📄 ')+n.name;
    document.getElementById('ttp').textContent=n.path||'/';
    document.getElementById('tts').textContent=fmt(n.size);
    document.getElementById('tooltip').style.display='block';
    ttMove(e);
}
function ttMove(e){
    const t=document.getElementById('tooltip');
    t.style.left=Math.min(e.clientX+14,window.innerWidth-330)+'px';
    t.style.top=Math.min(e.clientY+14,window.innerHeight-90)+'px';
}
function ttHide(){document.getElementById('tooltip').style.display='none';}

/* ── Table ──────────────────────────────────────────────────────────────── */
let _tdata=[],_sc='size',_sa=false,_ft='',_ftp='all';

function tblInit(flat){
    _tdata=flat.filter(n=>n.path!=='');
    const files=flat.filter(n=>n.type==='file');
    if(files.length){
        const lg=files.reduce((a,b)=>a.size>b.size?a:b);
        document.getElementById('stat-lg').textContent=fmt(lg.size);
    }
    tblRender();
    document.getElementById('srch').addEventListener('input',e=>{_ft=e.target.value;tblRender();});
    document.getElementById('tf').addEventListener('change',e=>{_ftp=e.target.value;tblRender();});
    document.querySelectorAll('th[data-c]').forEach(th=>{
        th.addEventListener('click',()=>{
            const col=th.dataset.c;
            if(_sc===col)_sa=!_sa;else{_sc=col;_sa=(col==='name'||col==='path');}
            document.querySelectorAll('th').forEach(h=>{h.classList.remove('srt');if(h.querySelector('.arr'))h.querySelector('.arr').textContent='↕';});
            th.classList.add('srt');if(th.querySelector('.arr'))th.querySelector('.arr').textContent=_sa?'↑':'↓';
            tblRender();
        });
    });
}

function tblRender(){
    const q=_ft.toLowerCase();
    const filtered=_tdata.filter(n=>{
        if(_ftp!=='all'&&n.type!==_ftp)return false;
        if(q)return n.name.toLowerCase().includes(q)||(n.path||'').toLowerCase().includes(q);
        return true;
    });
    const sorted=filtered.slice().sort((a,b)=>{
        let va,vb;
        if(_sc==='size'){va=a.size;vb=b.size;}
        else if(_sc==='name'){va=a.name.toLowerCase();vb=b.name.toLowerCase();}
        else if(_sc==='path'){va=(a.path||'').toLowerCase();vb=(b.path||'').toLowerCase();}
        else if(_sc==='type'){va=a.type;vb=b.type;}
        else{va=a.size;vb=b.size;}
        if(va<vb)return _sa?-1:1;if(va>vb)return _sa?1:-1;return 0;
    });
    const tb=document.getElementById('tb');
    tb.innerHTML='';
    for(const n of sorted){
        const tr=document.createElement('tr');
        tr.innerHTML=`<td class="ic">${icon(n.name,n.type,n.ext)}</td><td class="nm" title="${esc(n.name)}">${esc(n.name)}</td><td class="pt" title="${esc(n.path)}">${esc(n.path)}</td><td class="sz">${fmt(n.size)}</td><td><span class="badge ${n.type}">${n.type==='dir'?'📁 dir':'📄 file'}</span></td>`;
        tb.appendChild(tr);
    }
    document.getElementById('rcnt').textContent=sorted.length.toLocaleString()+' items';
}

/* ── Init ───────────────────────────────────────────────────────────────── */
document.addEventListener('DOMContentLoaded',()=>{
    _root=buildTree(DATA);
    initTabs();
    tmRender(_root,0);  // bcRender() called inside tmRender
    tvInit(_root);
    tblInit(DATA);
    let _rt;
    const obs=new ResizeObserver(()=>{clearTimeout(_rt);_rt=setTimeout(()=>{if(_cur)tmRender(_cur,_dep);},120);});
    obs.observe(document.getElementById('treemap'));
});
</script>
</body>
</html>
HTMLEOF
}

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

# ─── Argument Parsing ────────────────────────────────────────────────────────

TARGET_DIR="."

while [[ $# -gt 0 ]]; do
    case $1 in
        -d|--depth)       MAX_DEPTH="$2"; shift 2 ;;
        -w|--width)       BAR_WIDTH="$2"; shift 2 ;;
        -a|--all)         SHOW_HIDDEN=true; shift ;;
        -f|--files)
            SHOW_TOP_FILES=true
            if [[ $2 =~ ^[0-9]+$ ]]; then TOP_FILES_COUNT="$2"; shift 2; else shift; fi ;;
        -s|--sort)        shift 2 ;;  # kept for compatibility, unused
        --html)
            if [[ -n $2 && $2 != -* && ! -d "$2" ]]; then
                # Check if the value looks like [user@]host:/path (SSH target)
                if [[ "$2" =~ ^[A-Za-z0-9._@-]+:.+ ]]; then
                    # Parse SSH target: split on first ':'
                    REMOTE_HOST="${2%%:*}"
                    REMOTE_PATH="${2#*:}"
                    HTML_OUTPUT="$(mktemp /tmp/disk-usage-XXXXXX.html)"
                    shift 2
                else
                    HTML_OUTPUT="$2"; shift 2
                fi
            else
                HTML_OUTPUT="$(mktemp /tmp/disk-usage-XXXXXX.html)"; shift
            fi ;;
        --html-depth)     HTML_DEPTH="$2"; shift 2 ;;
        --ssh-opts)       SSH_OPTS="$2"; shift 2 ;;
        -h|--help)        show_help; exit 0 ;;
        *)
            # Detect [user@]host:/path as positional argument (without --html)
            if [[ "$1" =~ ^[A-Za-z0-9._@-]+:.+ ]]; then
                REMOTE_HOST="${1%%:*}"
                REMOTE_PATH="${1#*:}"
                [ -z "$HTML_OUTPUT" ] && HTML_OUTPUT="$(mktemp /tmp/disk-usage-XXXXXX.html)"
            elif [ -d "$1" ]; then
                TARGET_DIR="$1"
            else
                echo -e "${RED}Error: '$1' is not a valid directory, SSH path, or option${NC}"
                show_help; exit 1
            fi
            shift ;;
    esac
done

if [ -n "$HTML_OUTPUT" ]; then
    generate_html_report "$HTML_OUTPUT" "$TARGET_DIR"
else
    analyze_directory "$TARGET_DIR" "$MAX_DEPTH"
fi
