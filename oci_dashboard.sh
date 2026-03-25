#!/bin/bash

# --- SUPPRESS WARNINGS ---
export SUPPRESS_LABEL_WARNING=True

export LC_ALL=C.UTF-8

# --- COLOR DEFINITIONS ---
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
MAGENTA='\033[0;35m'
NC='\033[0m'
BOLD='\033[1m'

if ! command -v jq &> /dev/null || ! command -v oci &> /dev/null; then
    echo -e "${RED}[!] jq ou OCI CLI não encontrados. Instale-os antes de usar.${NC}"
    exit 1
fi

TENANCY_ID=$(grep "^tenancy=" ~/.oci/config | cut -d'=' -f2)
if [ -z "$TENANCY_ID" ]; then
    echo -e "${RED}[!] Não foi possível extrair o Tenancy ID de ~/.oci/config${NC}"
    exit 1
fi

refresh_dashboard() {
    clear
    echo -e "${CYAN}${BOLD}"
    cat << "EOF"

  ______    ______   ______         ______   ________   ______    ______   _______    ______
 /      \  /      \ |      \       /      \ |        \ /      \  /      \ |       \  /      \
|  $$$$$$\|  $$$$$$\ \$$$$$$      |  $$$$$$\| $$$$$$$$|  $$$$$$\|  $$$$$$\| $$$$$$$\|  $$$$$$\
| $$  | $$| $$   \$$  | $$        | $$___\$$| $$__    | $$   \$$| $$  | $$| $$__/ $$| $$___\$$
| $$  | $$| $$        | $$         \$$    \ | $$  \   | $$      | $$  | $$| $$    $$ \$$    \
| $$  | $$| $$   __   | $$         _\$$$$$$\| $$$$$   | $$   __ | $$  | $$| $$$$$$$  _\$$$$$$\
| $$__/ $$| $$__/  \ _| $$_       |  \__| $$| $$_____ | $$__/  \| $$__/ $$| $$      |  \__| $$
 \$$    $$ \$$    $$|   $$ \       \$$    $$| $$     \ \$$    $$ \$$    $$| $$       \$$    $$
  \$$$$$$   \$$$$$$  \$$$$$$        \$$$$$$  \$$$$$$$$  \$$$$$$   \$$$$$$  \$$        \$$$$$$

by: brennocm (https://github.com/brennocm/oci-secops)

EOF
    echo -e "${NC}"
    echo -e "Last updated: $(date '+%Y-%m-%d %H:%M:%S')"
    echo -e "Press [CTRL+C] to exit.\n"

    echo -e "${YELLOW}[*] Querying Oracle Cloud APIs...${NC}\n"

    INSTANCES_JSON=$(oci compute instance list --compartment-id "$TENANCY_ID" --output json 2>/dev/null)

    if [ -z "$INSTANCES_JSON" ] || [ "$INSTANCES_JSON" == "null" ]; then
        echo -e "${RED}[!] No instances found or API error.${NC}"
        return
    fi

    printf "%-15s | %-12s | %-15s | %-20s | %-12s | %s\n" "INSTANCE" "STATUS" "PUBLIC IP" "RESOURCES" "CREATED" "AVAIL. DOMAIN"
    echo -e "------------------------------------------------------------------------------------------------------------"
    
    echo "$INSTANCES_JSON" | jq -c '.data[]' | while read -r instance; do
        STATE=$(echo "$instance" | jq -r '."lifecycle-state"')
        
        # Skip terminated instances to keep the dashboard clean
        if [ "$STATE" == "TERMINATED" ]; then continue; fi
        
        NAME=$(echo "$instance" | jq -r '."display-name"')
        ID=$(echo "$instance" | jq -r '."id"')
        OCPUS=$(echo "$instance" | jq -r '."shape-config".ocpus // 0')
        MEM=$(echo "$instance" | jq -r '."shape-config"."memory-in-gbs" // 0')
        CREATED=$(echo "$instance" | jq -r '."time-created"' | awk -F'T' '{print $1}')
        AD=$(echo "$instance" | jq -r '."availability-domain"' | awk -F: '{print $NF}')
        
        if [ "$STATE" == "RUNNING" ]; then
            STATE_COLOR="${GREEN}"
            # Uses timeout to prevent the listing from hanging if the OCI API is unresponsive
            IP_STR=$(oci compute instance list-vnics --instance-id "$ID" --output json 2>/dev/null | jq -r '.data[0]."public-ip" // "N/A"')
        elif [ "$STATE" == "PROVISIONING" ] || [ "$STATE" == "STARTING" ]; then
            STATE_COLOR="${YELLOW}"
            IP_STR="Pending..."
        else
            STATE_COLOR="${RED}"
            IP_STR="--"
        fi
        
        printf "%-15s | ${STATE_COLOR}%-12s${NC} | %-15s | %-20s | %-12s | %s\n" "$NAME" "$STATE" "$IP_STR" "${OCPUS} OCPU / ${MEM}GB" "$CREATED" "$AD"
    done
    echo -e "\n${CYAN}======================================================================${NC}"
}

while true; do
    refresh_dashboard
    sleep 15
done
