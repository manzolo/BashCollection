#!/bin/bash

# Advanced colors and formatting
GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
UNDERLINE='\033[4m'
NC='\033[0m' # No Color

# Function for headers
print_header() {
    echo -e "\n${CYAN}${BOLD}${UNDERLINE}$1${NC}"
    echo -e "${CYAN}============================================${NC}"
}

# Function for sub-sections
print_section() {
    echo -e "\n${BLUE}${BOLD}➤ $1${NC}"
    echo -e "${BLUE}────────────────────────────────────────────${NC}"
}

# Function for success messages
print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

# Function for warning messages
print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

# Function for error messages
print_error() {
    echo -e "${RED}✗ $1${NC}"
}

# Function for progress bars
progress_bar() {
    local percentage=$1
    local bar_length=20
    local filled_length=$((percentage * bar_length / 100))
    local bar=""
    
    for ((i=0; i<filled_length; i++)); do
        bar+="▓"
    done
    for ((i=filled_length; i<bar_length; i++)); do
        bar+="░"
    done
    
    echo -e "[${bar}] ${percentage}%"
}

clear

# Introductory banner
echo -e "${MAGENTA}${BOLD}"
echo "╔══════════════════════════════════════════════════╗"
echo "║             🚀 SYSTEM DASHBOARD PRO 🚀           ║"
echo "║          Real-Time Resource Monitoring           ║"
echo "╚══════════════════════════════════════════════════╝"

print_header "📊 GENERAL SYSTEM OVERVIEW"
echo -e "📅 ${BOLD}Date and time:${NC} $(date +'%m/%d/%Y %H:%M:%S')"
echo -e "🖥️  ${BOLD}Hostname:${NC} $(hostname)"
echo -e "🐧 ${BOLD}Distribution:${NC} $(lsb_release -d | cut -f2)"
echo -e "⏰ ${BOLD}Uptime:${NC} $(uptime -p | sed 's/up //')"

print_header "📈 RESOURCE USAGE"

print_section "CPU Usage"
cpu_usage=$(grep 'cpu ' /proc/stat | awk '{usage=($2+$4)*100/($2+$4+$5)} END {print int(usage)}')
echo -e "Current usage: ${BOLD}${cpu_usage}%${NC}"
progress_bar $cpu_usage

print_section "Memory Usage"
mem_info=$(free -h | grep 'Mem:')
mem_total=$(echo $mem_info | awk '{print $2}')
mem_used=$(echo $mem_info | awk '{print $3}')
mem_percent=$(echo $mem_info | awk '{print int($3/$2*100)}')
echo -e "Usage: ${BOLD}${mem_used} / ${mem_total}${NC}"
progress_bar $mem_percent

print_section "Disk Space"
df -h --total | grep -E '^/|total' | while read line; do
    fs=$(echo $line | awk '{print $1}')
    size=$(echo $line | awk '{print $2}')
    used=$(echo $line | awk '{print $3}')
    perc=$(echo $line | awk '{print $5}' | tr -d '%')
    mount=$(echo $line | awk '{print $6}')
    echo -e "📁 ${BOLD}${mount}${NC} (${fs}): ${used} / ${size}"
    progress_bar $perc
done

print_header "🔥 ACTIVE PROCESSES"

print_section "Top 5 Processes by CPU"
ps aux --sort=-%cpu | head -n 6 | awk 'NR==1 {printf "%-20s %-10s %-10s %-10s\n", "USER", "PID", "CPU%", "COMMAND"} NR>1 {printf "%-20s %-10s %-10s %-10s\n", $1, $2, $3, $11}'

print_section "Top 5 Processes by Memory"
ps aux --sort=-%mem | head -n 6 | awk 'NR==1 {printf "%-20s %-10s %-10s %-10s\n", "USER", "PID", "MEM%", "COMMAND"} NR>1 {printf "%-20s %-10s %-10s %-10s\n", $1, $2, $4, $11}'

# Advanced Docker section
if command -v docker &> /dev/null; then
    print_header "🐳 DOCKER CONTAINERS"
    
    if [ $(docker ps -q | wc -l) -gt 0 ]; then
        print_section "Top 5 Containers by CPU"
        docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}" | head -n 6
        
        print_section "Top 5 Containers by Memory"
        docker stats --no-stream --format "table {{.Name}}\t{{.MemPerc}}\t{{.MemUsage}}" | head -n 6
        
        print_section "Container Status"
        echo -e "🟢 Running: $(docker ps -q | wc -l) container(s)"
        echo -e "🔴 Stopped: $(docker ps -aq -f status=exited | wc -l) container(s)"
    else
        print_warning "Docker is installed but no containers are running."
    fi
else
    print_warning "Docker is not installed. Skipping container section."
fi

print_header "📋 ADDITIONAL SYSTEM INFO"
echo -e "🌡️  ${BOLD}CPU Temperature:${NC} $(($(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null || echo 0) / 1000))°C"
echo -e "🔌 ${BOLD}Load average:${NC} $(cat /proc/loadavg | awk '{print $1", "$2", "$3}')"
echo -e "💾 ${BOLD}Swap memory:${NC} $(free -h | grep 'Swap:' | awk '{print $3 " / " $2}')"

# Footer
echo -e "\n${GREEN}${BOLD}"
echo "✅ COMPLETE REPORT ✅"
echo "Generated on: $(date +'%m/%d/%Y %H:%M')"
