#!/usr/bin/env bash
# domain_info.sh - Enhanced version
# Usage: ./domain_info.sh domain.tld [--http] [--full]
# Provides DNS, WHOIS, TLS, optional HTTP info with enhanced features.

DOMAIN="$1"
WITH_HTTP=false
FULL_MODE=false

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --http)
      WITH_HTTP=true
      shift
      ;;
    --full)
      FULL_MODE=true
      shift
      ;;
    -*)
      echo "Unknown option $1"
      exit 1
      ;;
    *)
      if [[ -z "$DOMAIN" ]]; then
        DOMAIN="$1"
      fi
      shift
      ;;
  esac
done

if [[ -z "$DOMAIN" ]]; then
  echo "Usage: $0 domain.tld [--http] [--full]"
  echo "  --http: Include HTTP/HTTPS headers"
  echo "  --full: Include additional checks (CAA, SRV, subdomain scan)"
  exit 1
fi

# --- Enhanced Colors ---
RESET="\033[0m"
BOLD="\033[1m"
HEADER_BG="\033[48;5;27m\033[97m"   # white text, blue bg
WARN_BG="\033[48;5;202m\033[97m"    # white text, orange bg
ERROR_BG="\033[48;5;196m\033[97m"   # white text, red bg
SUCCESS_BG="\033[48;5;34m\033[97m"  # white text, green bg
SUBHEAD="\033[1;33m"                # bright yellow
INFO="\033[0;36m"                   # cyan
DIM="\033[2m"                       # dim text

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

# --- Enhanced Dependency management ---
REQUIRED_CMDS=(dig host whois curl openssl nc)
OPTIONAL_CMDS=(nmap drill timeout)
MISSING_CMDS=()
MISSING_OPTIONAL=()

for cmd in "${REQUIRED_CMDS[@]}"; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    MISSING_CMDS+=("$cmd")
  fi
done

for cmd in "${OPTIONAL_CMDS[@]}"; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    MISSING_OPTIONAL+=("$cmd")
  fi
done

if [[ ${#MISSING_CMDS[@]} -gt 0 ]]; then
  print_error "Missing required dependencies: ${MISSING_CMDS[*]}"
  if [[ -f /etc/debian_version ]]; then
    read -p "Install with apt? (y/n) " ans
    if [[ "$ans" == "y" ]]; then
      sudo apt update && sudo apt install -y dnsutils whois curl openssl netcat-openbsd
    else
      echo "Some checks will be skipped."
      exit 1
    fi
  fi
fi

if [[ ${#MISSING_OPTIONAL[@]} -gt 0 && $FULL_MODE == true ]]; then
  print_warn "Optional tools missing (for --full mode): ${MISSING_OPTIONAL[*]}"
fi

# --- Validation ---
if ! [[ "$DOMAIN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
  print_error "Invalid domain format: $DOMAIN"
  exit 1
fi

# --- Start output ---
echo
print_header "Domain Analysis: $DOMAIN"
echo "Date (UTC): $(date -u +"%Y-%m-%d %H:%M:%SZ")"
echo "Mode: $([ $FULL_MODE == true ] && echo "Full Analysis" || echo "Standard")"
echo

# --- Enhanced DNS records ---
print_header "DNS Records"
if command -v dig >/dev/null; then
  # Function to query and format DNS records
  query_dns() {
    local record_type=$1
    local result
    result=$(dig +short "$record_type" "$DOMAIN" 2>/dev/null)
    
    if [[ -n "$result" ]]; then
      if [[ "$record_type" == "MX" ]]; then
        echo "$result" | sort -n | sed 's/^/  /'
      else
        echo "$result" | sed 's/^/  /'
      fi
      return 0
    else
      echo "  none"
      return 1
    fi
  }

  # Standard records
  echo -e "${SUBHEAD}A Records:${RESET}"
  if query_dns A; then
    print_success "IPv4 addresses found"
  fi

  echo -e "${SUBHEAD}AAAA Records:${RESET}"
  if query_dns AAAA; then
    print_success "IPv6 addresses found"
  fi

  echo -e "${SUBHEAD}CNAME:${RESET}"
  query_dns CNAME

  echo -e "${SUBHEAD}MX Records:${RESET}"
  if query_dns MX; then
    print_success "Mail servers configured"
  fi

  echo -e "${SUBHEAD}NS Records:${RESET}"
  query_dns NS

  echo -e "${SUBHEAD}TXT Records:${RESET}"
  TXT_RESULT=$(dig +short TXT "$DOMAIN" 2>/dev/null)
  if [[ -n "$TXT_RESULT" ]]; then
    echo "$TXT_RESULT" | while IFS= read -r line; do
      echo "  $line"
      # Analyze TXT record types
      if [[ "$line" =~ v=spf1 ]]; then
        print_info "  → SPF record found (email authentication)"
      elif [[ "$line" =~ v=DMARC1 ]]; then
        print_info "  → DMARC record found (email policy)"
      elif [[ "$line" =~ google-site-verification ]]; then
        print_info "  → Google site verification"
      elif [[ "$line" =~ domain-verification ]]; then
        print_info "  → Domain verification record"
      fi
    done
  else
    echo "  none"
  fi

  echo -e "${SUBHEAD}SOA Record:${RESET}"
  query_dns SOA

  # Full mode additional records
  if [[ $FULL_MODE == true ]]; then
    echo -e "${SUBHEAD}CAA Records:${RESET}"
    query_dns CAA
    
    echo -e "${SUBHEAD}SRV Records (common):${RESET}"
    for srv in "_http._tcp" "_https._tcp" "_sip._tcp" "_xmpp-server._tcp"; do
      SRV_RESULT=$(dig +short SRV "${srv}.${DOMAIN}" 2>/dev/null)
      if [[ -n "$SRV_RESULT" ]]; then
        echo "  ${srv}: $SRV_RESULT"
      fi
    done
  fi
else
  print_error "dig not available - DNS checks skipped"
fi

# --- Enhanced Reverse lookup ---
print_header "Reverse DNS Lookup"
if command -v host >/dev/null && command -v dig >/dev/null; then
  declare -a all_ips
  mapfile -t ipv4_ips < <(dig +short A "$DOMAIN" 2>/dev/null)
  mapfile -t ipv6_ips < <(dig +short AAAA "$DOMAIN" 2>/dev/null)
  all_ips=("${ipv4_ips[@]}" "${ipv6_ips[@]}")
  
  if [[ ${#all_ips[@]} -eq 0 ]]; then
    echo "  ${DIM}No IP addresses found${RESET}"
  else
    for ip in "${all_ips[@]}"; do
      [[ -z "$ip" ]] && continue
      reverse=$(host "$ip" 2>/dev/null | awk -F 'pointer ' '{print $2}' | sed 's/\.$//')
      if [[ -n "$reverse" ]]; then
        echo "  $ip → $reverse"
        # Check if reverse matches original domain
        if [[ "$reverse" == "$DOMAIN" ]] || [[ "$reverse" == *".$DOMAIN" ]]; then
          print_success "  → Reverse DNS matches domain"
        else
          print_info "  → Reverse DNS points to different domain"
        fi
      else
        echo "  $ip → ${DIM}no reverse DNS${RESET}"
      fi
    done
  fi
else
  print_warn "host or dig not available"
fi

# --- Enhanced WHOIS ---
print_header "WHOIS Information"
if command -v whois >/dev/null; then
  WHOIS_RAW=$(timeout 10 whois "$DOMAIN" 2>/dev/null || true)
  if [[ -n "$WHOIS_RAW" ]]; then
    echo "$WHOIS_RAW" | awk '
      BEGIN{IGNORECASE=1}
      /Registrar:/ && !seen1++ {print "  " $0}
      /Creation Date:|Created On:|registered:/ && !seen2++ {print "  " $0}
      /Expiry Date:|Expires On:|expires:/ && !seen3++ {
        print "  " $0
        # Extract date and check if expiring soon
        if (match($0, /[0-9]{4}-[0-9]{2}-[0-9]{2}/)) {
          expiry_date = substr($0, RSTART, RLENGTH)
          cmd = "date -d \"" expiry_date "\" +%s 2>/dev/null || date -j -f \"%Y-%m-%d\" \"" expiry_date "\" +%s 2>/dev/null"
          cmd | getline expiry_timestamp
          close(cmd)
          
          cmd = "date +%s"
          cmd | getline current_timestamp  
          close(cmd)
          
          days_left = int((expiry_timestamp - current_timestamp) / 86400)
          if (days_left < 30 && days_left > 0) {
            print "  ⚠️  Domain expires in " days_left " days!"
          }
        }
      }
      /Name Server:|nserver:/ {print "  " $0}
      /Status:|status:/ && !seen4++ {print "  " $0}
    '
    
    # Check domain status
    if echo "$WHOIS_RAW" | grep -qi "clientTransferProhibited\|serverTransferProhibited"; then
      print_info "Domain transfer protection enabled"
    fi
  else
    echo "  ${DIM}WHOIS data not available${RESET}"
  fi
else
  print_warn "whois not available"
fi

# --- Enhanced TLS Certificate ---
print_header "TLS Certificate Analysis"
if command -v openssl >/dev/null; then
  CERT_INFO=$(timeout 10 bash -c "echo | openssl s_client -servername '$DOMAIN' -connect '$DOMAIN:443' -verify_return_error 2>/dev/null | openssl x509 -noout -text 2>/dev/null")
  
  if [[ -n "$CERT_INFO" ]]; then
    # Extract key information
    SUBJECT=$(echo "$CERT_INFO" | grep "Subject:" | head -1)
    ISSUER=$(echo "$CERT_INFO" | grep "Issuer:" | head -1)
    NOT_BEFORE=$(echo "$CERT_INFO" | grep "Not Before:" | head -1)
    NOT_AFTER=$(echo "$CERT_INFO" | grep "Not After :" | head -1)
    
    echo "  $SUBJECT" | sed 's/Subject: /Subject: /'
    echo "  $ISSUER" | sed 's/Issuer: /Issuer:  /'
    echo "  $NOT_BEFORE"
    echo "  $NOT_AFTER"
    
    # Check certificate validity
    if openssl s_client -servername "$DOMAIN" -connect "$DOMAIN:443" -verify_return_error </dev/null >/dev/null 2>&1; then
      print_success "Certificate is valid and trusted"
    else
      print_warn "Certificate validation issues detected"
    fi
    
    # Check for SAN (Subject Alternative Names)
    SAN=$(echo "$CERT_INFO" | grep -A1 "Subject Alternative Name:" | tail -1 | sed 's/^[[:space:]]*//')
    if [[ -n "$SAN" ]]; then
      echo "  SAN: $SAN"
    fi
    
    # Check expiration
    EXPIRY_DATE=$(echo "$NOT_AFTER" | grep -o '[A-Z][a-z][a-z] [0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9] [0-9][0-9][0-9][0-9]')
    if [[ -n "$EXPIRY_DATE" ]]; then
      EXPIRY_EPOCH=$(date -d "$EXPIRY_DATE" +%s 2>/dev/null || date -j -f "%b %d %H:%M:%S %Y" "$EXPIRY_DATE" +%s 2>/dev/null)
      CURRENT_EPOCH=$(date +%s)
      DAYS_LEFT=$(( (EXPIRY_EPOCH - CURRENT_EPOCH) / 86400 ))
      
      if [[ $DAYS_LEFT -lt 30 ]]; then
        print_warn "Certificate expires in $DAYS_LEFT days!"
      elif [[ $DAYS_LEFT -lt 90 ]]; then
        print_info "Certificate expires in $DAYS_LEFT days"
      else
        print_success "Certificate valid for $DAYS_LEFT days"
      fi
    fi
  else
    print_error "Could not retrieve or parse certificate"
  fi
else
  print_warn "openssl not available"
fi

# --- Enhanced Port Check ---
print_header "Network Connectivity"
if command -v nc >/dev/null; then
  COMMON_PORTS=(80 443 21 22 25 53 110 143 993 995 587 465)
  OPEN_PORTS=()
  
  echo "  Common ports:"
  for port in "${COMMON_PORTS[@]}"; do
    if timeout 3 nc -z -w 3 "$DOMAIN" "$port" 2>/dev/null; then
      OPEN_PORTS+=("$port")
      case $port in
        80) echo "  Port $port: open (HTTP)" ;;
        443) echo "  Port $port: open (HTTPS)" ;;
        22) echo "  Port $port: open (SSH)" ;;
        25) echo "  Port $port: open (SMTP)" ;;
        53) echo "  Port $port: open (DNS)" ;;
        *) echo "  Port $port: open" ;;
      esac
    fi
  done
  
  if [[ ${#OPEN_PORTS[@]} -eq 0 ]]; then
    echo "  ${DIM}No common ports open${RESET}"
  else
    print_success "${#OPEN_PORTS[@]} ports open"
  fi
  
  # Security check
  if [[ " ${OPEN_PORTS[*]} " == *" 22 "* ]]; then
    print_warn "SSH port (22) is open - ensure it's properly secured"
  fi
else
  print_warn "nc not available"
fi

# --- Subdomain Discovery (Full mode) ---
if [[ $FULL_MODE == true ]]; then
  print_header "Common Subdomain Check"
  COMMON_SUBDOMAINS=(www mail ftp admin webmail mx smtp pop imap dns ns1 ns2 blog shop api app mobile dev test staging)
  FOUND_SUBDOMAINS=()
  
  for sub in "${COMMON_SUBDOMAINS[@]}"; do
    if dig +short A "${sub}.${DOMAIN}" | grep -q .; then
      FOUND_SUBDOMAINS+=("${sub}.${DOMAIN}")
      IP=$(dig +short A "${sub}.${DOMAIN}" | head -1)
      echo "  ${sub}.${DOMAIN} → $IP"
    fi
  done
  
  if [[ ${#FOUND_SUBDOMAINS[@]} -eq 0 ]]; then
    echo "  ${DIM}No common subdomains found${RESET}"
  else
    print_success "Found ${#FOUND_SUBDOMAINS[@]} subdomains"
  fi
fi

# --- Enhanced HTTP/HTTPS ---
if [[ $WITH_HTTP == true ]]; then
  print_header "Web Server Analysis"
  if command -v curl >/dev/null; then
    
    # HTTPS Check
    echo "  ${SUBHEAD}HTTPS Response:${RESET}"
    HTTPS_RESPONSE=$(curl -IsL --max-time 10 "https://$DOMAIN" 2>/dev/null)
    if [[ -n "$HTTPS_RESPONSE" ]]; then
      echo "$HTTPS_RESPONSE" | head -n 15 | sed 's/^/    /'
      
      # Security headers check
      if echo "$HTTPS_RESPONSE" | grep -qi "strict-transport-security"; then
        print_success "HSTS header present"
      else
        print_warn "HSTS header missing"
      fi
      
      if echo "$HTTPS_RESPONSE" | grep -qi "x-frame-options"; then
        print_success "X-Frame-Options header present"
      fi
      
      if echo "$HTTPS_RESPONSE" | grep -qi "x-content-type-options"; then
        print_success "X-Content-Type-Options header present"
      fi
    else
      print_error "HTTPS not responding"
    fi
    
    echo
    echo "  ${SUBHEAD}HTTP Response:${RESET}"
    HTTP_RESPONSE=$(curl -IsL --max-time 10 "http://$DOMAIN" 2>/dev/null)
    if [[ -n "$HTTP_RESPONSE" ]]; then
      echo "$HTTP_RESPONSE" | head -n 10 | sed 's/^/    /'
      
      # Check for HTTP to HTTPS redirect
      if echo "$HTTP_RESPONSE" | grep -q "301\|302" && echo "$HTTP_RESPONSE" | grep -qi "https://"; then
        print_success "HTTP redirects to HTTPS"
      else
        print_warn "HTTP doesn't redirect to HTTPS"
      fi
    else
      print_error "HTTP not responding"
    fi
  else
    print_warn "curl not available"
  fi
fi

# --- Summary ---
print_header "Summary"
echo "  Domain: $DOMAIN"
if command -v dig >/dev/null; then
  A_COUNT=$(dig +short A "$DOMAIN" 2>/dev/null | wc -l)
  AAAA_COUNT=$(dig +short AAAA "$DOMAIN" 2>/dev/null | wc -l)
  echo "  IPv4 addresses: $A_COUNT"
  echo "  IPv6 addresses: $AAAA_COUNT"
fi

if [[ $WITH_HTTP == true ]]; then
  echo "  Web analysis: completed"
fi

if [[ $FULL_MODE == true ]]; then
  echo "  Full analysis: completed"
fi

echo
print_success "Analysis completed at $(date -u +"%H:%M:%S UTC")"