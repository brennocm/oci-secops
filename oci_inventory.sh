#!/bin/bash

# --- SUPRIMIR AVISOS ---
export SUPPRESS_LABEL_WARNING=True

# --- DEFINIÇÕES DE CORES ---
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

# --- DESCOBERTA DINÂMICA ---
TENANCY_ID=$(grep "^tenancy=" ~/.oci/config | cut -d'=' -f2)
if [ -z "$TENANCY_ID" ]; then
    echo -e "${RED}[!] Erro: Tenancy ID não encontrado na configuração.${NC}"
    exit 1
fi

echo -e "${YELLOW}[*] Varrendo todos os compartimentos recursivamente...${NC}"
# Obtém todos os sub-compartimentos e adiciona o tenancy raiz
SUB_COMPS=$(oci iam compartment list --compartment-id "$TENANCY_ID" --compartment-id-in-subtree true --access-level ACCESSIBLE --output json 2>/dev/null | jq -r '.data[] | select(."lifecycle-state" == "ACTIVE") | .id')
# Combina e remove IDs duplicados
ALL_COMPARTMENTS=$(echo "$TENANCY_ID $SUB_COMPS" | tr ' ' '\n' | sort -u)

# Contadores
TOTAL_BOOT_GB=0
TOTAL_ARM_OCPU=0
TOTAL_ARM_RAM=0
FOUND_INSTANCES=""
FOUND_IPS=""

for comp_id in $ALL_COMPARTMENTS; do
    COMP_NAME=$(oci iam compartment get --compartment-id "$comp_id" --output json 2>/dev/null | jq -r '.data.name' || echo "Root")
    
    # 1. COMPUTAÇÃO
    INSTANCES_JSON=$(oci compute instance list --compartment-id "$comp_id" --output json 2>/dev/null)
    if [ ! -z "$INSTANCES_JSON" ]; then
        # Lista instâncias normalmente
        while read -r inst; do
            [ -z "$inst" ] && continue
            FOUND_INSTANCES+="${GREEN}✔${NC} [$COMP_NAME] $inst\n"
        done < <(echo "$INSTANCES_JSON" | jq -r '.data | map(select(."lifecycle-state" != "TERMINATED")) | .[] | "[\(."lifecycle-state")] \(."display-name") | \(."shape") | \(."shape-config".ocpus) OCPU | \(."shape-config"."memory-in-gbs")GB RAM"')
        
        # SOMA dos recursos ARM Always Free (usando soma direta via JSON para precisão)
        DOCPU=$(echo "$INSTANCES_JSON" | jq -r '.data | map(select(."shape" == "VM.Standard.A1.Flex" and ."lifecycle-state" != "TERMINATED")) | [.[]."shape-config".ocpus] | add // 0')
        DRAM=$(echo "$INSTANCES_JSON" | jq -r '.data | map(select(."shape" == "VM.Standard.A1.Flex" and ."lifecycle-state" != "TERMINATED")) | [.[]."shape-config"."memory-in-gbs"] | add // 0')
        TOTAL_ARM_OCPU=$(echo "$TOTAL_ARM_OCPU + $DOCPU" | bc)
        TOTAL_ARM_RAM=$(echo "$TOTAL_ARM_RAM + $DRAM" | bc)
    fi

    # 2. ARMAZENAMENTO (Todos os ADs)
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

    # 3. REDE (IPs Públicos)
    # IPs efêmeros via VNICs
    ACTIVE_IDS=$(echo "$INSTANCES_JSON" | jq -r '.data | map(select(."lifecycle-state" != "TERMINATED")) | .[].id' 2>/dev/null)
    for id in $ACTIVE_IDS; do
        IP=$(oci compute instance list-vnics --instance-id "$id" --output json 2>/dev/null | jq -r '.data[0]."public-ip"')
        if [ "$IP" != "null" ] && [ ! -z "$IP" ]; then FOUND_IPS+="    ${GREEN}🌐${NC} $IP [$COMP_NAME]\n"; fi
    done
    # IPs reservados
    RES_IPS=$(oci network public-ip list --scope REGION --compartment-id "$comp_id" --output json 2>/dev/null | jq -r '.data[] | "\(."ip-address") (\(."display-name"))"')
    if [ ! -z "$RES_IPS" ]; then
        while read -r rip; do FOUND_IPS+="    ${GREEN}🌐${NC} $rip [$COMP_NAME] (Reservado)\n"; done <<< "$RES_IPS"
    fi
done

# --- SAÍDA ---
echo -e "\n${CYAN}[ INSTÂNCIAS DE COMPUTAÇÃO ]${NC}"
[ -z "$FOUND_INSTANCES" ] && echo "  Nenhuma ativa." || echo -e "$FOUND_INSTANCES"

echo -e "\n${CYAN}[ REDE ]${NC}"
[ -z "$FOUND_IPS" ] && echo "    Nenhum IP Público." || echo -e "$FOUND_IPS"

echo -e "\n${MAGENTA}---------------------------------------------------------------${NC}"
echo -e "${MAGENTA}     RESUMO DE CONFORMIDADE ALWAYS FREE (RECURSIVO)           ${NC}"
echo -e "${MAGENTA}---------------------------------------------------------------${NC}"

[ "$TOTAL_BOOT_GB" -le 200 ] && C=$GREEN || C=$RED
echo -e "  Armazenamento: ${C}${TOTAL_BOOT_GB}GB${NC} / Limite 200GB"

# Normaliza os totais com printf para evitar artefatos de ponto flutuante (.0999)
CLEAN_OCPU=$(printf "%.1f" "$TOTAL_ARM_OCPU" 2>/dev/null || echo "0.0")
CLEAN_RAM=$(printf "%.1f" "$TOTAL_ARM_RAM" 2>/dev/null || echo "0.0")

[ $(echo "$CLEAN_OCPU <= 4" | bc 2>/dev/null || echo 1) -eq 1 ] && C=$GREEN || C=$RED
echo -e "  ARM OCPUs: ${C}${CLEAN_OCPU}${NC} / Limite 4"

[ $(echo "$CLEAN_RAM <= 24" | bc 2>/dev/null || echo 1) -eq 1 ] && C=$GREEN || C=$RED
echo -e "  ARM RAM: ${C}${CLEAN_RAM}GB${NC} / Limite 24GB"
echo -e "${MAGENTA}---------------------------------------------------------------${NC}"