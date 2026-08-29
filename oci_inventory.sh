#!/bin/bash

# --- SUPPRESS WARNINGS ---
export SUPPRESS_LABEL_WARNING=True

# --- COLOR DEFINITIONS ---
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
MAGENTA='\033[0;35m'
NC='\033[0m'
BOLD='\033[1m'

# -----------------
# Splash Screen
# -----------------
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
echo -e "  ${BOLD}Automated provisioning and hardening of OCI Always Free instances${NC}"
echo -e "  ----------------------------------------"
echo ""

# --- DYNAMIC DISCOVERY ---
TENANCY_ID=$(grep "^tenancy=" ~/.oci/config | cut -d'=' -f2)
if [ -z "$TENANCY_ID" ]; then
    echo -e "${RED}[!] Erro: Tenancy ID não encontrado na configuração.${NC}"
    exit 1
fi

# ==============================================================================
# ALWAYS FREE CEILINGS vs TENANCY QUOTA
# Mirrors oci_provision.sh: the documented Always Free allotment is NOT the
# effective limit. Oracle caps Ampere A1 per tenancy and per region, so the
# quota is read live instead of assumed.
# ==============================================================================
AF_MAX_OCPU=4
AF_MAX_RAM=24
AF_MAX_STORAGE=200

AD_NAME=$(oci iam availability-domain list --compartment-id "$TENANCY_ID" --output json 2>/dev/null | jq -r '.data[0].name')

get_limit_field() {
    # $1 = limit name, $2 = field (available|used)
    oci limits resource-availability get \
        --service-name compute \
        --limit-name "$1" \
        --compartment-id "$TENANCY_ID" \
        --availability-domain "$AD_NAME" \
        --output json 2>/dev/null | jq -r ".data.$2 // empty"
}

if [ -n "$AD_NAME" ] && [ "$AD_NAME" != "null" ]; then
    Q_OCPU_AVAIL=$(get_limit_field "standard-a1-core-count" "available")
    Q_RAM_AVAIL=$(get_limit_field "standard-a1-memory-count" "available")
    Q_OCPU_USED=$(get_limit_field "standard-a1-core-count" "used")
    Q_RAM_USED=$(get_limit_field "standard-a1-memory-count" "used")
fi

if [[ "$Q_OCPU_AVAIL" =~ ^[0-9]+$ ]] && [[ "$Q_RAM_AVAIL" =~ ^[0-9]+$ ]]; then
    QUOTA_OK=true
    [[ "$Q_OCPU_USED" =~ ^[0-9]+$ ]] || Q_OCPU_USED=0
    [[ "$Q_RAM_USED" =~ ^[0-9]+$ ]] || Q_RAM_USED=0
    Q_OCPU_LIMIT=$(( Q_OCPU_USED + Q_OCPU_AVAIL ))
    Q_RAM_LIMIT=$(( Q_RAM_USED + Q_RAM_AVAIL ))
else
    QUOTA_OK=false
fi

echo -e "${YELLOW}[*] Varrendo todos os compartimentos recursivamente...${NC}"
# Retrieves all sub-compartments and adds the root tenancy
SUB_COMPS=$(oci iam compartment list --compartment-id "$TENANCY_ID" --compartment-id-in-subtree true --access-level ACCESSIBLE --output json 2>/dev/null | jq -r '.data[] | select(."lifecycle-state" == "ACTIVE") | .id')
# Combine and deduplicate IDs
ALL_COMPARTMENTS=$(echo "$TENANCY_ID $SUB_COMPS" | tr ' ' '\n' | sort -u)

# Counters
TOTAL_BOOT_GB=0
TOTAL_ARM_OCPU=0
TOTAL_ARM_RAM=0
FOUND_INSTANCES=""
FOUND_IPS=""

for comp_id in $ALL_COMPARTMENTS; do
    COMP_NAME=$(oci iam compartment get --compartment-id "$comp_id" --output json 2>/dev/null | jq -r '.data.name' || echo "Root")
    
    # 1. COMPUTE
    INSTANCES_JSON=$(oci compute instance list --compartment-id "$comp_id" --output json 2>/dev/null)
    if [ ! -z "$INSTANCES_JSON" ]; then
        # List instances normally
        while read -r inst; do
            [ -z "$inst" ] && continue
            FOUND_INSTANCES+="${GREEN}✔${NC} [$COMP_NAME] $inst\n"
        done < <(echo "$INSTANCES_JSON" | jq -r '.data | map(select(."lifecycle-state" != "TERMINATED")) | .[] | "[\(."lifecycle-state")] \(."display-name") | \(."shape") | \(."shape-config".ocpus) OCPU | \(."shape-config"."memory-in-gbs")GB RAM"')
        
        # SUM of ARM Always Free resources (using direct JSON sum for accuracy)
        DOCPU=$(echo "$INSTANCES_JSON" | jq -r '.data | map(select(."shape" == "VM.Standard.A1.Flex" and ."lifecycle-state" != "TERMINATED")) | [.[]."shape-config".ocpus] | add // 0')
        DRAM=$(echo "$INSTANCES_JSON" | jq -r '.data | map(select(."shape" == "VM.Standard.A1.Flex" and ."lifecycle-state" != "TERMINATED")) | [.[]."shape-config"."memory-in-gbs"] | add // 0')
        TOTAL_ARM_OCPU=$(echo "$TOTAL_ARM_OCPU + $DOCPU" | bc)
        TOTAL_ARM_RAM=$(echo "$TOTAL_ARM_RAM + $DRAM" | bc)
    fi

    # 2. STORAGE (All ADs)
    ADS=$(oci iam availability-domain list --compartment-id "$comp_id" 2>/dev/null | jq -r '.data[].name')
    for ad in $ADS; do
        VOLS_JSON=$(oci bv boot-volume list --availability-domain "$ad" --compartment-id "$comp_id" --output json 2>/dev/null)
        if [ ! -z "$VOLS_JSON" ]; then
            while read -r vol_size; do
                [ -z "$vol_size" ] && continue
                TOTAL_BOOT_GB=$((TOTAL_BOOT_GB + vol_size))
            done < <(echo "$VOLS_JSON" | jq -r '.data | map(select(."lifecycle-state" != "TERMINATED")) | .[]."size-in-gbs"')
        fi
    done

    # 3. NETWORK (Public IPs)
    # Ephemeral IPs via VNICs
    ACTIVE_IDS=$(echo "$INSTANCES_JSON" | jq -r '.data | map(select(."lifecycle-state" != "TERMINATED")) | .[].id' 2>/dev/null)
    for id in $ACTIVE_IDS; do
        IP=$(oci compute instance list-vnics --instance-id "$id" --output json 2>/dev/null | jq -r '.data[0]."public-ip"')
        if [ "$IP" != "null" ] && [ ! -z "$IP" ]; then FOUND_IPS+="    ${GREEN}🌐${NC} $IP [$COMP_NAME]\n"; fi
    done
    # Reserved IPs
    RES_IPS=$(oci network public-ip list --scope REGION --compartment-id "$comp_id" --output json 2>/dev/null | jq -r '.data[] | "\(."ip-address") (\(."display-name"))"')
    if [ ! -z "$RES_IPS" ]; then
        while read -r rip; do FOUND_IPS+="    ${GREEN}🌐${NC} $rip [$COMP_NAME] (Reservado)\n"; done <<< "$RES_IPS"
    fi
done

# --- OUTPUT ---
echo -e "\n${CYAN}[ INSTÂNCIAS DE COMPUTAÇÃO ]${NC}"
[ -z "$FOUND_INSTANCES" ] && echo "  Nenhuma ativa." || echo -e "$FOUND_INSTANCES"

echo -e "\n${CYAN}[ REDE ]${NC}"
[ -z "$FOUND_IPS" ] && echo "    Nenhum IP Público." || echo -e "$FOUND_IPS"

echo -e "\n${MAGENTA}---------------------------------------------------------------${NC}"
echo -e "${MAGENTA}     RESUMO DE CONFORMIDADE ALWAYS FREE (RECURSIVO)           ${NC}"
echo -e "${MAGENTA}---------------------------------------------------------------${NC}"

# Normalize totals with printf to avoid floating-point artifacts (.0999)
CLEAN_OCPU=$(printf "%.1f" "$TOTAL_ARM_OCPU" 2>/dev/null || echo "0.0")
CLEAN_RAM=$(printf "%.1f" "$TOTAL_ARM_RAM" 2>/dev/null || echo "0.0")

if [ "$QUOTA_OK" = true ]; then
    printf "  %-16s %-12s %-12s %s\n" "RECURSO" "EM USO" "SUA COTA" "TETO FREE"

    # The binding limit is whichever is smaller: tenancy quota or Always Free
    [ $(echo "$CLEAN_OCPU >= $Q_OCPU_LIMIT" | bc 2>/dev/null || echo 0) -eq 1 ] && C=$RED || C=$GREEN
    printf "  %-16s ${C}%-12s${NC} %-12s %s\n" "ARM OCPUs" "$CLEAN_OCPU" "$Q_OCPU_LIMIT" "$AF_MAX_OCPU"

    [ $(echo "$CLEAN_RAM >= $Q_RAM_LIMIT" | bc 2>/dev/null || echo 0) -eq 1 ] && C=$RED || C=$GREEN
    printf "  %-16s ${C}%-12s${NC} %-12s %s\n" "ARM RAM" "${CLEAN_RAM}GB" "${Q_RAM_LIMIT}GB" "${AF_MAX_RAM}GB"

    [ "$TOTAL_BOOT_GB" -ge "$AF_MAX_STORAGE" ] && C=$RED || C=$GREEN
    printf "  %-16s ${C}%-12s${NC} %-12s %s\n" "Armazenamento" "${TOTAL_BOOT_GB}GB" "-" "${AF_MAX_STORAGE}GB"

    # Headroom = smaller of (quota left) and (Always Free left)
    AF_OCPU_LEFT=$(( AF_MAX_OCPU - Q_OCPU_USED ))
    AF_RAM_LEFT=$(( AF_MAX_RAM - Q_RAM_USED ))
    H_OCPU=$Q_OCPU_AVAIL; [ "$H_OCPU" -gt "$AF_OCPU_LEFT" ] && H_OCPU=$AF_OCPU_LEFT
    H_RAM=$Q_RAM_AVAIL;   [ "$H_RAM" -gt "$AF_RAM_LEFT" ] && H_RAM=$AF_RAM_LEFT
    H_DISK=$(( AF_MAX_STORAGE - TOTAL_BOOT_GB ))
    [ "$H_OCPU" -lt 0 ] && H_OCPU=0; [ "$H_RAM" -lt 0 ] && H_RAM=0; [ "$H_DISK" -lt 0 ] && H_DISK=0

    echo ""
    if [ "$H_OCPU" -lt 1 ] || [ "$H_RAM" -lt 1 ]; then
        echo -e "  ${YELLOW}Margem para novo provisionamento: esgotada.${NC}"
        echo -e "  ${YELLOW}Libere recursos com ./oci_teardown.sh antes de provisionar.${NC}"
    else
        echo -e "  ${GREEN}Margem para novo provisionamento: ${BOLD}${H_OCPU} OCPU / ${H_RAM}GB RAM / ${H_DISK}GB disco${NC}"
        echo -e "  ${CYAN}Use a opção 6 (Limited Full Power) do oci_provision.sh.${NC}"
    fi

    # PAYG accounts can legally exceed Always Free -- and get billed for it
    if [ "$Q_OCPU_LIMIT" -gt "$AF_MAX_OCPU" ] || [ "$Q_RAM_LIMIT" -gt "$AF_MAX_RAM" ]; then
        echo ""
        echo -e "  ${RED}[!] ATENÇÃO: sua cota (${Q_OCPU_LIMIT} OCPU / ${Q_RAM_LIMIT}GB) excede o teto${NC}"
        echo -e "  ${RED}    Always Free. Recursos acima de ${AF_MAX_OCPU} OCPU / ${AF_MAX_RAM}GB SERÃO FATURADOS.${NC}"
    fi

    # Cross-check: recursive scan vs authoritative quota API
    if [ $(echo "$CLEAN_OCPU != $Q_OCPU_USED" | bc 2>/dev/null || echo 0) -eq 1 ]; then
        echo ""
        echo -e "  ${YELLOW}[!] Divergência: varredura encontrou ${CLEAN_OCPU} OCPU, a API contabiliza ${Q_OCPU_USED}.${NC}"
        echo -e "  ${YELLOW}    Pode haver instâncias em compartimentos sem permissão de leitura.${NC}"
    fi
else
    echo -e "  ${YELLOW}[!] Cota da tenancy indisponível — exibindo apenas o teto Always Free.${NC}"
    [ $(echo "$CLEAN_OCPU <= $AF_MAX_OCPU" | bc 2>/dev/null || echo 1) -eq 1 ] && C=$GREEN || C=$RED
    echo -e "  ARM OCPUs: ${C}${CLEAN_OCPU}${NC} / Teto ${AF_MAX_OCPU}"
    [ $(echo "$CLEAN_RAM <= $AF_MAX_RAM" | bc 2>/dev/null || echo 1) -eq 1 ] && C=$GREEN || C=$RED
    echo -e "  ARM RAM: ${C}${CLEAN_RAM}GB${NC} / Teto ${AF_MAX_RAM}GB"
    [ "$TOTAL_BOOT_GB" -le "$AF_MAX_STORAGE" ] && C=$GREEN || C=$RED
    echo -e "  Armazenamento: ${C}${TOTAL_BOOT_GB}GB${NC} / Teto ${AF_MAX_STORAGE}GB"
fi
echo -e "${MAGENTA}---------------------------------------------------------------${NC}"