#!/bin/bash
# PKG_NAME: email-domain-check
# PKG_VERSION: 1.0.0
# PKG_SECTION: utils
# PKG_PRIORITY: optional
# PKG_ARCHITECTURE: all
# PKG_DEPENDS: bash (>= 4.0), bind9-dnsutils
# PKG_MAINTAINER: Manzolo <manzolo@libero.it>
# PKG_DESCRIPTION: Email DNS records checker (SPF, DKIM, DMARC, MX)
# PKG_LONG_DESCRIPTION: Verifies email-related DNS records for a given domain:
#  MX servers, SPF policy, DMARC policy, and DKIM keys.
#  Provides a summary with colored status indicators.
# PKG_HOMEPAGE: https://github.com/manzolo/BashCollection

#===============================================================================
# EMAIL DOMAIN CHECK
# Verifies SPF, DKIM, DMARC and other email DNS records for a domain.
#
# Usage: email-domain-check <domain.tld>
#===============================================================================

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

if [ -z "$1" ]; then
    echo ""
    echo "Usage: $0 <domain>"
    echo "Example: $0 example.com"
    exit 1
fi

DOMAIN="$1"

if ! command -v dig &> /dev/null; then
    echo "Error: 'dig' not installed. Install with: sudo apt install dnsutils"
    exit 1
fi

echo ""
echo -e "${BOLD}${CYAN}============================================${NC}"
echo -e "${BOLD}${CYAN}  EMAIL CHECK: $DOMAIN${NC}"
echo -e "${BOLD}${CYAN}============================================${NC}"
echo -e "  Date: $(date '+%Y-%m-%d %H:%M:%S')"

#--- MX RECORDS ---
echo ""
echo -e "${BLUE}--- MX Records (Mail servers) ---${NC}"
MX=$(dig +short MX "$DOMAIN" | sort -n)
if [ -n "$MX" ]; then
    echo -e "${GREEN}[OK]${NC} MX records found:"
    echo "$MX" | while read -r line; do echo "    -> $line"; done
else
    echo -e "${RED}[X]${NC} No MX records found"
fi

#--- SPF RECORD ---
echo ""
echo -e "${BLUE}--- SPF Record ---${NC}"
SPF=$(dig +short TXT "$DOMAIN" | grep "v=spf1" | tr -d '"')
if [ -n "$SPF" ]; then
    echo -e "${GREEN}[OK]${NC} SPF record found:"
    echo -e "    ${CYAN}$SPF${NC}"

    INCLUDES=$(echo "$SPF" | grep -o "include:" | wc -l)
    echo ""
    echo "    Analysis:"
    echo "    -> Includes found: $INCLUDES"

    if echo "$SPF" | grep -q "\-all"; then
        echo -e "    -> Policy: ${GREEN}-all (hard fail)${NC}"
    elif echo "$SPF" | grep -q "~all"; then
        echo -e "    -> Policy: ${YELLOW}~all (soft fail)${NC}"
    fi

    if [ "$INCLUDES" -gt 6 ]; then
        echo -e "    ${YELLOW}[!] Warning: many includes, risk of >10 DNS lookups${NC}"
    fi
else
    echo -e "${RED}[X]${NC} No SPF record found"
fi

#--- DMARC RECORD ---
echo ""
echo -e "${BLUE}--- DMARC Record ---${NC}"
DMARC=$(dig +short TXT "_dmarc.$DOMAIN" | grep "v=DMARC1" | tr -d '"')
if [ -n "$DMARC" ]; then
    echo -e "${GREEN}[OK]${NC} DMARC record found:"
    echo -e "    ${CYAN}$DMARC${NC}"

    POLICY=$(echo "$DMARC" | grep -oE "p=(none|quarantine|reject)" | cut -d= -f2)
    echo ""
    if [ "$POLICY" = "reject" ]; then
        echo -e "    -> Policy: ${GREEN}reject (maximum protection)${NC}"
    elif [ "$POLICY" = "quarantine" ]; then
        echo -e "    -> Policy: ${GREEN}quarantine (good protection)${NC}"
    elif [ "$POLICY" = "none" ]; then
        echo -e "    -> Policy: ${YELLOW}none (monitoring only)${NC}"
    fi

    if echo "$DMARC" | grep -q "rua="; then
        RUA=$(echo "$DMARC" | grep -oE "rua=mailto:[^;]+" | sed 's/rua=mailto://')
        echo "    -> Reports to: $RUA"
    fi
else
    echo -e "${RED}[X]${NC} No DMARC record found"
    echo -e "    ${YELLOW}Suggested: v=DMARC1; p=none; rua=mailto:dmarc@$DOMAIN${NC}"
fi

#--- DKIM RECORD ---
echo ""
echo -e "${BLUE}--- DKIM Record ---${NC}"
SELECTORS="default selector1 selector2 google dkim s1 s2 k1 mail"
DKIM_FOUND=0

for sel in $SELECTORS; do
    DKIM=$(dig +short TXT "${sel}._domainkey.$DOMAIN" 2>/dev/null | grep "v=DKIM1")
    if [ -n "$DKIM" ]; then
        DKIM_FOUND=1
        echo -e "${GREEN}[OK]${NC} DKIM found with selector: ${BOLD}$sel${NC}"
        break
    fi
done

if [ $DKIM_FOUND -eq 0 ]; then
    echo -e "${YELLOW}[!]${NC} DKIM not found with common selectors"
    echo "    Selectors tried: $SELECTORS"
    echo "    Ask your provider which selector is in use"
fi

#--- SUMMARY ---
echo ""
echo -e "${BLUE}============================================${NC}"
echo -e "${BOLD}SUMMARY${NC}"
echo -e "${BLUE}============================================${NC}"

[ -n "$SPF" ]         && echo -e "  SPF:   ${GREEN}[OK]${NC}"        || echo -e "  SPF:   ${RED}[X]${NC}"
[ $DKIM_FOUND -eq 1 ] && echo -e "  DKIM:  ${GREEN}[OK]${NC}"        || echo -e "  DKIM:  ${YELLOW}[?]${NC}"
[ -n "$DMARC" ]       && echo -e "  DMARC: ${GREEN}[OK]${NC} ($POLICY)" || echo -e "  DMARC: ${RED}[X]${NC}"
[ -n "$MX" ]          && echo -e "  MX:    ${GREEN}[OK]${NC}"        || echo -e "  MX:    ${RED}[X]${NC}"

echo ""
echo -e "${CYAN}Analysis complete.${NC}"
echo ""
