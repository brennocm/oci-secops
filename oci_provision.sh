#!/bin/bash

# --- SUPPRESS WARNINGS ---
export SUPPRESS_LABEL_WARNING=True

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
LOG_FILE="$SCRIPT_DIR/provisioned_vps.log"
TEMP_MACHINES_FILE=$(mktemp)

# --- LOAD LOCAL SECRETS ---
ENV_FILE="$SCRIPT_DIR/.env"
if [ -f "$ENV_FILE" ]; then
    set -a; source "$ENV_FILE"; set +a
else
    echo "[!] ERRO: '$ENV_FILE' não encontrado. Copie .env.example para .env e preencha os valores antes de continuar."
    exit 1
fi

# --- COLOR DEFINITIONS ---
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
MAGENTA='\033[0;35m'
NC='\033[0m'
BOLD='\033[1m'

# Array to store instances created in this session
PROVISIONED_MACHINES=()
INSTANCE_TYPE=""

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

# --- INITIAL CHECKS (STRICT MODE) ---
echo -ne "${YELLOW}[*] Validando dependências locais... ${NC}"

if [ ! -f "$SCRIPT_DIR/harden.sh" ]; then
    echo -e "\n${RED}[!] ERRO CRÍTICO: 'harden.sh' não encontrado em $SCRIPT_DIR${NC}"
    exit 1
fi

if [ ! -f "$SCRIPT_DIR/pentest_arsenal.sh" ]; then
    echo -e "\n${RED}[!] ERRO CRÍTICO: 'pentest_arsenal.sh' não encontrado em $SCRIPT_DIR${NC}"
    echo -e "${YELLOW}O script exige todos os arquivos para garantir a automação completa.${NC}"
    exit 1
fi

# --- CI SECURITY INSTANCE CHECKS ---
CI_HARDENING="$SCRIPT_DIR/harden_ci.sh"
CI_SETUP="$SCRIPT_DIR/setup_ci.sh"
CI_READY=true
if [ ! -f "$CI_HARDENING" ] || [ ! -f "$CI_SETUP" ]; then
    echo -e "\n${YELLOW}[!] AVISO: 'harden_ci.sh' ou 'setup_ci.sh' não encontrado.${NC}"
    echo -e "${YELLOW}    Opção 5 (CI Security) estará indisponível.${NC}"
    CI_READY=false
fi

SSH_PUB_KEY="$HOME/.ssh/oci_vps_key.pub"
SSH_PRIV_KEY="$HOME/.ssh/oci_vps_key"
if [ ! -f "$SSH_PUB_KEY" ] || [ ! -f "$SSH_PRIV_KEY" ]; then
    echo -e "\n${RED}[!] ERRO CRÍTICO: Par de chaves SSH não encontrado em $HOME/.ssh/${NC}"
    exit 1
fi

echo -e "${GREEN}Tudo OK!${NC}"

# --- DYNAMIC DISCOVERY ---
echo -e "${YELLOW}[*] Verificando ambiente OCI...${NC}"

TENANCY_ID=$(grep "^tenancy=" ~/.oci/config | cut -d'=' -f2)
if [ -z "$TENANCY_ID" ]; then exit 1; fi
echo -e "  > Compartimento Raiz: ${GREEN}$TENANCY_ID${NC}"

AD_NAME=$(oci iam availability-domain list --compartment-id "$TENANCY_ID" --output json 2>/dev/null | jq -r '.data[0].name')
if [ -z "$AD_NAME" ] || [ "$AD_NAME" == "null" ]; then exit 1; fi
echo -e "  > Nome do AD:      ${GREEN}$AD_NAME${NC}"

SUBNET_ID=$(oci network subnet list --compartment-id "$TENANCY_ID" --output json 2>/dev/null | jq -r '.data[0].id')
if [ -z "$SUBNET_ID" ] || [ "$SUBNET_ID" == "null" ]; then exit 1; fi
echo -e "  > Sub-rede:        ${GREEN}$SUBNET_ID${NC}"

IMAGE_ID=$(oci compute image list --compartment-id "$TENANCY_ID" --operating-system "Canonical Ubuntu" --operating-system-version "24.04" --shape "VM.Standard.A1.Flex" --sort-by "TIMECREATED" --output json 2>/dev/null | jq -r '.data[0].id')
if [ -z "$IMAGE_ID" ] || [ "$IMAGE_ID" == "null" ]; then exit 1; fi
echo -e "  > Imagem (24.04):  ${GREEN}$IMAGE_ID${NC}"

# --- A1 QUOTA DISCOVERY (feeds the "Limited Full Power" strategy) ---
# Reads the tenancy's real Ampere A1 allowance instead of assuming the
# documented 4 OCPU / 24GB: Oracle caps it per-tenancy/per-region.
get_limit_available() {
    oci limits resource-availability get \
        --service-name compute \
        --limit-name "$1" \
        --compartment-id "$TENANCY_ID" \
        --availability-domain "$AD_NAME" \
        --output json 2>/dev/null | jq -r '.data.available // empty'
}

get_limit_used() {
    oci limits resource-availability get \
        --service-name compute \
        --limit-name "$1" \
        --compartment-id "$TENANCY_ID" \
        --availability-domain "$AD_NAME" \
        --output json 2>/dev/null | jq -r '.data.used // empty'
}

A1_CORES_FREE=$(get_limit_available "standard-a1-core-count")
A1_RAM_FREE=$(get_limit_available "standard-a1-memory-count")
A1_CORES_USED=$(get_limit_used "standard-a1-core-count")
A1_RAM_USED=$(get_limit_used "standard-a1-memory-count")
[[ "$A1_CORES_USED" =~ ^[0-9]+$ ]] || A1_CORES_USED=0
[[ "$A1_RAM_USED" =~ ^[0-9]+$ ]] || A1_RAM_USED=0

if [[ "$A1_CORES_FREE" =~ ^[0-9]+$ ]] && [[ "$A1_RAM_FREE" =~ ^[0-9]+$ ]]; then
    QUOTA_OK=true
    echo -e "  > Cota A1 livre:   ${GREEN}${A1_CORES_FREE} OCPU / ${A1_RAM_FREE}GB RAM${NC}"
else
    QUOTA_OK=false
    echo -e "  > Cota A1 livre:   ${YELLOW}indeterminada (opção 6 indisponível)${NC}"
fi

echo -e "${CYAN}---------------------------------------------------------------${NC}"

# ==============================================================================
# ALWAYS FREE HARD CEILINGS
# The tenancy quota CANNOT be trusted as a safety net: on a Free Tier account
# exceeding the allotment is rejected (LimitExceeded), but on an upgraded
# Pay-As-You-Go account the very same launch succeeds and is BILLED. The OCI
# API does not expose which kind of account this is, so these ceilings are
# enforced locally, on every launch, regardless of what the quota allows.
# ==============================================================================
AF_SHAPE="VM.Standard.A1.Flex"   # only free-eligible shape in this region
AF_MAX_OCPU=4                    # Always Free: 4 OCPU total, all instances
AF_MAX_RAM=24                    # Always Free: 24GB RAM total, all instances
AF_MAX_STORAGE=200               # Always Free: 200GB block storage total
AF_VPU=10                        # Balanced performance; higher tiers are paid

# --- ALWAYS FREE COMPLIANCE CHECK (Storage) ---
USED_STORAGE=$(oci bv boot-volume list --availability-domain "$AD_NAME" --compartment-id "$TENANCY_ID" --output json 2>/dev/null | jq '[.data[] | select(."lifecycle-state" != "TERMINATED") | ."size-in-gbs"] | add')
[ -z "$USED_STORAGE" ] || [ "$USED_STORAGE" == "null" ] && USED_STORAGE=0
FREE_STORAGE=$((200 - USED_STORAGE))

if [ "$FREE_STORAGE" -lt 50 ]; then
     echo -e "${RED}[!] CRÍTICO: Armazenamento Always Free insuficiente (Disponível: ${FREE_STORAGE}GB).${NC}"
     exit 1
fi

echo -e "${YELLOW}Selecione a Estratégia de Implantação:${NC}"
echo "1) Full Power              (4 OCPU / 24GB RAM)"
echo "2) Balanced Pair           (2x 2 OCPU / 12GB RAM) - Parallel Launch"
echo "3) Small Cluster           (4x 1 OCPU / 6GB RAM)  - Parallel Launch"
echo "4) Single Instance         (1 OCPU / 6GB RAM)"
echo "5) CI Security             (4 OCPU / 24GB RAM) - SonarQube + OWASP ZAP + Dep-Check"
echo -e "6) ${BOLD}Limited Full Power${NC}     (máximo que a SUA cota permite) - Auto-detectado"
read -p "Seleção: " OPTION

# Validates a whole deployment strategy against the Always Free allotment
# BEFORE anything is launched. Accounts for resources already in use so a
# second run cannot push the tenancy over the ceiling.
check_free_tier_budget() {
    local REQ_OCPU=$1 REQ_RAM=$2 REQ_STORAGE=$3 REQ_COUNT=$4
    local TOT_OCPU=$(( A1_CORES_USED + REQ_OCPU ))
    local TOT_RAM=$(( A1_RAM_USED + REQ_RAM ))
    local BLOCKED=false

    echo -e "${CYAN}---------------------------------------------------------------${NC}"
    echo -e "${BOLD}[*] Verificação Always Free (${REQ_COUNT} instância(s)):${NC}"
    printf "    %-22s %-14s %-14s %s\n" "RECURSO" "JÁ EM USO" "ESTA EXECUÇÃO" "TETO FREE"
    printf "    %-22s %-14s %-14s %s\n" "OCPU (A1)" "$A1_CORES_USED" "+$REQ_OCPU" "$AF_MAX_OCPU"
    printf "    %-22s %-14s %-14s %s\n" "RAM GB (A1)" "$A1_RAM_USED" "+$REQ_RAM" "$AF_MAX_RAM"
    printf "    %-22s %-14s %-14s %s\n" "Disco GB" "$USED_STORAGE" "+$REQ_STORAGE" "$AF_MAX_STORAGE"

    # 1. Always Free ceiling (protects PAY-AS-YOU-GO accounts from billing)
    if [ "$TOT_OCPU" -gt "$AF_MAX_OCPU" ]; then
        echo -e "${RED}[!] BLOQUEADO: ${TOT_OCPU} OCPU excede o teto Always Free de ${AF_MAX_OCPU}.${NC}"
        BLOCKED=true
    fi
    if [ "$TOT_RAM" -gt "$AF_MAX_RAM" ]; then
        echo -e "${RED}[!] BLOQUEADO: ${TOT_RAM}GB de RAM excede o teto Always Free de ${AF_MAX_RAM}GB.${NC}"
        BLOCKED=true
    fi
    if [ $(( USED_STORAGE + REQ_STORAGE )) -gt "$AF_MAX_STORAGE" ]; then
        echo -e "${RED}[!] BLOQUEADO: $(( USED_STORAGE + REQ_STORAGE ))GB de disco excede o teto Always Free de ${AF_MAX_STORAGE}GB.${NC}"
        BLOCKED=true
    fi

    if [ "$BLOCKED" = true ]; then
        echo -e "${RED}[!] Esta estratégia sairia do Always Free e poderia gerar cobrança.${NC}"
        echo -e "${YELLOW}    Use a opção 6 (Limited Full Power) para dimensionar automaticamente.${NC}"
        rm -f "$TEMP_MACHINES_FILE"; exit 1
    fi

    # 2. Tenancy quota (would fail with LimitExceeded / partial deploy)
    if [ "$QUOTA_OK" = true ]; then
        if [ "$REQ_OCPU" -gt "$A1_CORES_FREE" ] || [ "$REQ_RAM" -gt "$A1_RAM_FREE" ]; then
            echo -e "${RED}[!] BLOQUEADO: sua cota A1 é de ${A1_CORES_FREE} OCPU / ${A1_RAM_FREE}GB —${NC}"
            echo -e "${RED}    insuficiente para ${REQ_OCPU} OCPU / ${REQ_RAM}GB.${NC}"
            if [ "$REQ_COUNT" -gt 1 ]; then
                echo -e "${YELLOW}    Lançamento paralelo abortado para evitar deploy parcial.${NC}"
            fi
            echo -e "${YELLOW}    Use a opção 6 (Limited Full Power) para caber na sua cota.${NC}"
            rm -f "$TEMP_MACHINES_FILE"; exit 1
        fi
    fi

    echo -e "${GREEN}[+] Dentro do Always Free. Nenhuma cobrança será gerada.${NC}"
    echo -e "${CYAN}---------------------------------------------------------------${NC}"
    read -p "➔ Confirmar provisionamento? [S/n]: " CONFIRM_FT
    if [[ "$CONFIRM_FT" =~ ^[nN]$ ]]; then
        echo -e "${YELLOW}[*] Cancelado pelo usuário.${NC}"
        rm -f "$TEMP_MACHINES_FILE"; exit 0
    fi
}

launch_vps() {
    local NAME=$1
    local OCPU=$2
    local RAM=$3
    local USERDATA="${4:-$SCRIPT_DIR/harden.sh}"   # default: harden.sh
    local BOOT_GB="${5:-}"                         # optional: boot volume size in GB
    # Boot volume size and performance tier are NOT standalone CLI options:
    # both live inside --source-details, alongside the image id.
    local BOOT_DESC=""
    local SRC_DETAILS="{\"sourceType\":\"image\",\"imageId\":\"$IMAGE_ID\",\"bootVolumeVpusPerGB\":$AF_VPU"
    if [ -n "$BOOT_GB" ]; then
        SRC_DETAILS="${SRC_DETAILS},\"bootVolumeSizeInGBs\":$BOOT_GB"
        BOOT_DESC=" / ${BOOT_GB}GB disco"
    fi
    SRC_DETAILS="${SRC_DETAILS}}"
    # Last line of defence: a single instance can never exceed the whole
    # Always Free allotment, whatever the caller passed in.
    if [ "$OCPU" -gt "$AF_MAX_OCPU" ] || [ "$RAM" -gt "$AF_MAX_RAM" ]; then
        echo -e "${RED}[!] ABORTADO ($NAME): ${OCPU} OCPU / ${RAM}GB excede o Always Free.${NC}"
        return 1
    fi
    if [ -n "$BOOT_GB" ] && [ "$BOOT_GB" -gt "$AF_MAX_STORAGE" ]; then
        echo -e "${RED}[!] ABORTADO ($NAME): disco de ${BOOT_GB}GB excede o Always Free.${NC}"
        return 1
    fi

    local START_TIME=$(date +%s)
    local RETRY_COUNT=0
    local MAX_RETRIES=20  # 20 tentativas × 60s = ~20 minutos
    local RATE_COUNT=0
    local MAX_RATE_RETRIES=6  # backoff exponencial: 60s..600s (~35 min)

    while true; do
        echo -e "\n${YELLOW}[...] Buscando capacidade: $NAME ($OCPU OCPU / ${RAM}GB RAM${BOOT_DESC})${NC}"

        LAUNCH_RES=$(oci compute instance launch \
            --availability-domain "$AD_NAME" \
            --compartment-id "$TENANCY_ID" \
            --shape "$AF_SHAPE" \
            --shape-config "{\"ocpus\": $OCPU, \"memoryInGBs\": $RAM}" \
            --source-details "$SRC_DETAILS" \
            --display-name "$NAME" \
            --subnet-id "$SUBNET_ID" \
            --assign-public-ip true \
            --user-data-file "$USERDATA" \
            --ssh-authorized-keys-file "$SSH_PUB_KEY" 2>&1)

        if [[ $LAUNCH_RES == *"Out of capacity"* || $LAUNCH_RES == *"Out of host capacity"* ]]; then
            RETRY_COUNT=$(( RETRY_COUNT + 1 ))
            ELAPSED=$(( $(date +%s) - START_TIME ))
            if [ "$RETRY_COUNT" -ge "$MAX_RETRIES" ]; then
                echo -e "\n${RED}[!] Limite de tentativas atingido para '$NAME' após ${ELAPSED}s.${NC}"
                echo -e "${YELLOW}    A região ${AD_NAME%%-AD-*} está com alta demanda no momento.${NC}"
                echo -e "${YELLOW}    Sugestão: tente novamente em horários de menor tráfego,${NC}"
                echo -e "${YELLOW}    como madrugada ou início da manhã (horário UTC).${NC}"
                echo -e "${YELLOW}    Considere também tentar uma estratégia com menor alocação de recursos.${NC}"
                break
            fi
            echo -e "${RED}[-] Sem capacidade para $NAME. Tentativa $RETRY_COUNT/$MAX_RETRIES — nova tentativa em 60s...${NC}"
            sleep 60
        elif [[ $LAUNCH_RES == *"TooManyRequests"* ]]; then
            # HTTP 429: the launch_instance API is rate limited per user and
            # needs exponential backoff, not the flat retry used for capacity.
            RATE_COUNT=$(( RATE_COUNT + 1 ))
            if [ "$RATE_COUNT" -ge "$MAX_RATE_RETRIES" ]; then
                echo -e "\n${RED}[!] Rate limit persistente da API para '$NAME'.${NC}"
                echo -e "${YELLOW}    A OCI limita chamadas de launch_instance por usuário.${NC}"
                echo -e "${YELLOW}    Aguarde ~15 minutos sem novas tentativas e execute novamente.${NC}"
                break
            fi
            BACKOFF=$(( 60 * (2 ** (RATE_COUNT - 1)) ))
            [ "$BACKOFF" -gt 600 ] && BACKOFF=600
            echo -e "${YELLOW}[-] Rate limit da API (429). Tentativa $RATE_COUNT/$MAX_RATE_RETRIES — aguardando ${BACKOFF}s...${NC}"
            sleep "$BACKOFF"
        elif [[ $LAUNCH_RES == *"LimitExceeded"* ]]; then
            echo -e "${RED}[!] Cota excedida para '$NAME' ($OCPU OCPU / ${RAM}GB RAM).${NC}"
            echo -e "${YELLOW}    Sua cota A1 livre é de ${A1_CORES_FREE:-?} OCPU / ${A1_RAM_FREE:-?}GB RAM.${NC}"
            echo -e "${YELLOW}    Use a opção 6 (Limited Full Power) para caber automaticamente,${NC}"
            echo -e "${YELLOW}    ou peça aumento em: Console > Limits, Quotas and Usage.${NC}"
            break
        elif [[ $LAUNCH_RES == *"Error"* || $LAUNCH_RES == *"ServiceError"* || $LAUNCH_RES == *"Usage:"* ]]; then
            echo -e "${RED}[!] Comando OCI falhou para $NAME! Detalhes:\n$LAUNCH_RES${NC}"
            break
        else
            INSTANCE_ID=$(echo "$LAUNCH_RES" | jq -r '.data.id' 2>/dev/null)
            echo -ne "${CYAN}[*] Aguardando a instância $NAME inicializar... ${NC}"
            
            while true; do
                STATE=$(oci compute instance get --instance-id "$INSTANCE_ID" --output json 2>/dev/null | jq -r '.data."lifecycle-state"')
                if [ "$STATE" == "RUNNING" ]; then echo -e "${GREEN}EXECUTANDO ($NAME)!${NC}"; break; fi
                sleep 5
            done

            PUBLIC_IP=$(oci compute instance list-vnics --instance-id "$INSTANCE_ID" --output json 2>/dev/null | jq -r '.data[0]."public-ip"')
            
            echo -e "${GREEN}[+] CAPACIDADE GARANTIDA ($NAME)! IP: $PUBLIC_IP${NC}"
            echo "$(date) | $NAME | IP: $PUBLIC_IP | ID: $INSTANCE_ID" >> "$LOG_FILE"
            
            # Adds the created machine to the temp file (thread-safe for parallel launches)
            echo "$NAME|$PUBLIC_IP" >> "$TEMP_MACHINES_FILE"
            break
        fi
    done
}

# Custom naming and parallelism logic
echo -e "${CYAN}---------------------------------------------------------------${NC}"
case $OPTION in
    1) 
        check_free_tier_budget 4 24 50 1
        read -p "Nome da instância [Pressione Enter para 'ARM-Monster']: " CUSTOM_NAME
        launch_vps "${CUSTOM_NAME:-ARM-Monster}" 4 24 
        ;;
    2) 
        check_free_tier_budget 4 24 100 2
        read -p "Prefixo das instâncias [Pressione Enter para 'ARM-Twin']: " CUSTOM_PREFIX
        PREFIX=${CUSTOM_PREFIX:-ARM-Twin}
        for i in {1..2}; do launch_vps "${PREFIX}-$i" 2 12 & done 
        wait
        ;;
    3) 
        check_free_tier_budget 4 24 200 4
        read -p "Prefixo das instâncias [Pressione Enter para 'ARM-Small']: " CUSTOM_PREFIX
        PREFIX=${CUSTOM_PREFIX:-ARM-Small}
        for i in {1..4}; do launch_vps "${PREFIX}-$i" 1 6 & done 
        wait
        ;;
    4) 
        check_free_tier_budget 1 6 50 1
        read -p "Nome da instância [Pressione Enter para 'ARM-Single']: " CUSTOM_NAME
        launch_vps "${CUSTOM_NAME:-ARM-Single}" 1 6 
        ;;
    5)
        if [ "$CI_READY" = false ]; then
            echo -e "${RED}[!] harden_ci.sh ou setup_ci.sh ausente.${NC}"
            rm -f "$TEMP_MACHINES_FILE"; exit 1
        fi
        check_free_tier_budget 4 24 50 1
        read -p "Nome da instância [Pressione Enter para 'ARM-CI-Security']: " CUSTOM_NAME
        INSTANCE_TYPE="CI"
        launch_vps "${CUSTOM_NAME:-ARM-CI-Security}" 4 24 "$SCRIPT_DIR/harden_ci.sh"
        ;;
    6)
        if [ "$QUOTA_OK" = false ]; then
            echo -e "${RED}[!] Não foi possível consultar sua cota A1 via API.${NC}"
            echo -e "${YELLOW}    Verifique as permissões IAM ou escolha uma opção fixa (1-5).${NC}"
            rm -f "$TEMP_MACHINES_FILE"; exit 1
        fi

        if [ "$A1_CORES_FREE" -lt 1 ] || [ "$A1_RAM_FREE" -lt 1 ]; then
            echo -e "${RED}[!] Sem cota A1 livre (${A1_CORES_FREE} OCPU / ${A1_RAM_FREE}GB).${NC}"
            echo -e "${YELLOW}    Termine instâncias existentes ou peça aumento de limite.${NC}"
            rm -f "$TEMP_MACHINES_FILE"; exit 1
        fi

        # Takes the SMALLER of: what the tenancy quota allows, and what is
        # left of the Always Free allotment. The quota alone is not a safety
        # net -- on a Pay-As-You-Go account it can legally exceed Always Free.
        AF_OCPU_LEFT=$(( AF_MAX_OCPU - A1_CORES_USED ))
        AF_RAM_LEFT=$(( AF_MAX_RAM - A1_RAM_USED ))

        MAX_OCPU=$A1_CORES_FREE
        [ "$MAX_OCPU" -gt "$AF_OCPU_LEFT" ] && MAX_OCPU=$AF_OCPU_LEFT
        MAX_RAM=$A1_RAM_FREE
        [ "$MAX_RAM" -gt "$AF_RAM_LEFT" ] && MAX_RAM=$AF_RAM_LEFT

        # A1.Flex hardware ratio: at most 64GB per OCPU
        RAM_CEILING=$(( MAX_OCPU * 64 ))
        [ "$MAX_RAM" -gt "$RAM_CEILING" ] && MAX_RAM=$RAM_CEILING

        if [ "$MAX_OCPU" -lt 1 ] || [ "$MAX_RAM" -lt 1 ]; then
            echo -e "${RED}[!] Sem margem no Always Free (${MAX_OCPU} OCPU / ${MAX_RAM}GB restantes).${NC}"
            rm -f "$TEMP_MACHINES_FILE"; exit 1
        fi

        MAX_BOOT=$FREE_STORAGE
        [ "$MAX_BOOT" -gt "$AF_MAX_STORAGE" ] && MAX_BOOT=$AF_MAX_STORAGE

        echo -e "${GREEN}[*] Máximo dentro do seu Always Free: ${BOLD}${MAX_OCPU} OCPU / ${MAX_RAM}GB RAM / até ${MAX_BOOT}GB de disco${NC}"
        echo -e "${YELLOW}    (usar todo o disco impede uma segunda instância nesta tenancy)${NC}"
        read -p "Tamanho do boot volume em GB [Enter para ${MAX_BOOT}]: " CUSTOM_BOOT
        BOOT_GB=${CUSTOM_BOOT:-$MAX_BOOT}
        if ! [[ "$BOOT_GB" =~ ^[0-9]+$ ]] || [ "$BOOT_GB" -lt 50 ] || [ "$BOOT_GB" -gt "$MAX_BOOT" ]; then
            echo -e "${RED}[!] Valor inválido. Informe um número entre 50 e ${MAX_BOOT}.${NC}"
            rm -f "$TEMP_MACHINES_FILE"; exit 1
        fi

        check_free_tier_budget "$MAX_OCPU" "$MAX_RAM" "$BOOT_GB" 1
        read -p "Nome da instância [Pressione Enter para 'ARM-Limited-Monster']: " CUSTOM_NAME
        launch_vps "${CUSTOM_NAME:-ARM-Limited-Monster}" "$MAX_OCPU" "$MAX_RAM" "$SCRIPT_DIR/harden.sh" "$BOOT_GB"
        ;;
    *) 
        echo -e "${RED}Seleção inválida.${NC}"
        rm -f "$TEMP_MACHINES_FILE"
        exit 1 
        ;;
esac

# Reads from temp file into the main session array
while read -r line; do
    PROVISIONED_MACHINES+=("$line")
done < "$TEMP_MACHINES_FILE"
rm -f "$TEMP_MACHINES_FILE"

# ==============================================================================
# POST-PROVISIONING MENU (ORCHESTRATION)
# ==============================================================================
if [ ${#PROVISIONED_MACHINES[@]} -gt 0 ]; then
    get_ssh_port() {
        local IP=$1
        # Tests port 22 first, then 2222 (the hardening script may change it)
        if ssh -p 22 -q -o BatchMode=yes -o ConnectTimeout=3 -o StrictHostKeyChecking=no -i "$SSH_PRIV_KEY" ubuntu@"$IP" "echo ok" 2>/dev/null | grep -q 'ok'; then
            echo "22"
        elif ssh -p 2222 -q -o BatchMode=yes -o ConnectTimeout=3 -o StrictHostKeyChecking=no -i "$SSH_PRIV_KEY" ubuntu@"$IP" "echo ok" 2>/dev/null | grep -q 'ok'; then
            echo "2222"
        else
            echo "0"
        fi
    }

    install_on_machine() {
        local TARGET_NAME=$1
        local TARGET_IP=$2
        
        echo -e "\n${CYAN}===============================================================${NC}"
        echo -e "${CYAN}>>> Conectando a: $TARGET_NAME ($TARGET_IP)${NC}"

        # 1. WAIT FOR SSH TO BECOME AVAILABLE
        echo -ne "${YELLOW}[*] Aguardando serviço SSH iniciar... ${NC}"
        SSH_PORT="0"
        while [ "$SSH_PORT" == "0" ]; do
            sleep 5
            SSH_PORT=$(get_ssh_port "$TARGET_IP")
        done
        echo -e "${GREEN}Conectado na porta $SSH_PORT!${NC}"

        # 2. STREAM HARDENING LOG (CLOUD-INIT) IN REAL TIME (RESILIENT)
        echo -e "${YELLOW}[*] Acompanhando o log do Hardening (Cloud-Init) ao vivo...${NC}"
        echo -e "${CYAN}---------------------------------------------------------------${NC}"
        
        while true; do
            SSH_PORT=$(get_ssh_port "$TARGET_IP")
            if [ "$SSH_PORT" != "0" ]; then
                ssh -p "$SSH_PORT" -q -t -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -o StrictHostKeyChecking=no -i "$SSH_PRIV_KEY" ubuntu@"$TARGET_IP" "sudo tail -f /var/log/cloud-init-output.log" 2>/dev/null &
                TAIL_PID=$!
                
                while sleep 10; do
                    if ssh -p 22 -q -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no -i "$SSH_PRIV_KEY" ubuntu@"$TARGET_IP" "sudo test -f /root/hardening_complete" 2>/dev/null || \
                       ssh -p 2222 -q -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no -i "$SSH_PRIV_KEY" ubuntu@"$TARGET_IP" "sudo test -f /root/hardening_complete" 2>/dev/null; then
                        kill $TAIL_PID 2>/dev/null
                        break 2
                    fi
                    
                    if ! kill -0 $TAIL_PID 2>/dev/null; then
                        echo -e "${YELLOW}[!] Conexão interrompida. Reconectando para retomar o log...${NC}"
                        break
                    fi
                done
                kill $TAIL_PID 2>/dev/null
            else
                sleep 5
            fi
        done
        echo -e "${CYAN}---------------------------------------------------------------${NC}"
        echo -e "${GREEN}[+] Hardening concluído! O gerenciador de pacotes (APT) está livre.${NC}"

        # 3. UPLOAD PENTEST SCRIPT VIA SCP (RESILIENT)
        echo -ne "${YELLOW}[*] Fazendo upload do script pentest_arsenal.sh... ${NC}"
        SSH_PORT=$(get_ssh_port "$TARGET_IP")
        
        while ! scp -P "$SSH_PORT" -q -o StrictHostKeyChecking=no -i "$SSH_PRIV_KEY" "$SCRIPT_DIR/pentest_arsenal.sh" ubuntu@"$TARGET_IP":/home/ubuntu/pentest_arsenal.sh; do
            sleep 5
            SSH_PORT=$(get_ssh_port "$TARGET_IP")
        done
        echo -e "${GREEN}OK!${NC}"

        # 4. RUN BUG BOUNTY INSTALLATION
        echo -e "${YELLOW}[*] Executando instalação do Bug Bounty (saída em tempo real)...${NC}"
        echo -e "${CYAN}---------------------------------------------------------------${NC}"
        
        PROFILE_ARG="--full"
        case "$OPT_PROFILE" in
            2) PROFILE_ARG="--web" ;;
            3) PROFILE_ARG="--infra" ;;
        esac

        GUI_ARG=""
        if [[ "$OPT_GUI" =~ ^[sS]$ ]]; then
            GUI_ARG="--vnc"
        fi

        if ssh -p "$SSH_PORT" -t -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -o StrictHostKeyChecking=no -i "$SSH_PRIV_KEY" ubuntu@"$TARGET_IP" "sudo sed -i 's/\r$//' /home/ubuntu/pentest_arsenal.sh && sudo chmod +x /home/ubuntu/pentest_arsenal.sh && sudo env VNC_PASSWORD='$VNC_PASSWORD' /home/ubuntu/pentest_arsenal.sh $PROFILE_ARG $GUI_ARG"; then
            echo -e "${CYAN}---------------------------------------------------------------${NC}"
            echo -e "${GREEN}[+] Instalação 100% concluída em $TARGET_NAME!${NC}"
        else
            echo -e "${CYAN}---------------------------------------------------------------${NC}"
            echo -e "${RED}[!] ERRO CRÍTICO durante a orquestração do Bug Bounty em $TARGET_NAME!${NC}"
        fi
        ssh -p "$SSH_PORT" -o StrictHostKeyChecking=no -i "$SSH_PRIV_KEY" ubuntu@"$TARGET_IP" "rm -f /home/ubuntu/pentest_arsenal.sh" 2>/dev/null
    }

    install_ci_on_machine() {
        local TARGET_NAME=$1
        local TARGET_IP=$2
        
        echo -e "\n${CYAN}===============================================================${NC}"
        echo -e "${CYAN}>>> Configurando CI Security em: $TARGET_NAME ($TARGET_IP)${NC}"

        # 1. WAIT FOR SSH TO BECOME AVAILABLE
        echo -ne "${YELLOW}[*] Aguardando serviço SSH iniciar... ${NC}"
        SSH_PORT="0"
        while [ "$SSH_PORT" == "0" ]; do
            sleep 5
            SSH_PORT=$(get_ssh_port "$TARGET_IP")
        done
        echo -e "${GREEN}Conectado na porta $SSH_PORT!${NC}"

        # 2. STREAM CI HARDENING LOG (CLOUD-INIT) IN REAL TIME
        echo -e "${YELLOW}[*] Monitorando Hardening da CI (Cloud-Init) ao vivo...${NC}"
        echo -e "${CYAN}---------------------------------------------------------------${NC}"
        
        while true; do
            SSH_PORT=$(get_ssh_port "$TARGET_IP")
            if [ "$SSH_PORT" != "0" ]; then
                ssh -p "$SSH_PORT" -q -t -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -o StrictHostKeyChecking=no -i "$SSH_PRIV_KEY" ubuntu@"$TARGET_IP" "sudo tail -f /var/log/cloud-init-output.log" 2>/dev/null &
                TAIL_PID=$!
                
                while sleep 10; do
                    if ssh -p "$SSH_PORT" -q -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no -i "$SSH_PRIV_KEY" ubuntu@"$TARGET_IP" "sudo test -f /root/hardening_complete" 2>/dev/null; then
                        kill $TAIL_PID 2>/dev/null
                        break 2
                    fi
                    if ! kill -0 $TAIL_PID 2>/dev/null; then break; fi
                done
                kill $TAIL_PID 2>/dev/null
            else
                sleep 5
            fi
        done
        echo -e "${CYAN}---------------------------------------------------------------${NC}"
        echo -e "${GREEN}[+] Hardening concluído! Instalando ferramentas CI...${NC}"

        # 3. UPLOAD CI_SETUP.SH
        echo -ne "${YELLOW}[*] Fazendo upload do script setup_ci.sh... ${NC}"
        while ! scp -P "$SSH_PORT" -q -o StrictHostKeyChecking=no -i "$SSH_PRIV_KEY" "$SCRIPT_DIR/setup_ci.sh" ubuntu@"$TARGET_IP":/home/ubuntu/setup_ci.sh; do
            sleep 5
        done
        echo -e "${GREEN}OK!${NC}"

        # 4. RUN CI INSTALLATION
        echo -e "${YELLOW}[*] Executando configuração de ferramentas CI (ZAP, Sonar, Dep-Check)...${NC}"
        echo -e "${CYAN}---------------------------------------------------------------${NC}"
        
        if ssh -p "$SSH_PORT" -t -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -o StrictHostKeyChecking=no -i "$SSH_PRIV_KEY" ubuntu@"$TARGET_IP" "sudo sed -i 's/\r$//' /home/ubuntu/setup_ci.sh && sudo chmod +x /home/ubuntu/setup_ci.sh && sudo env NVD_API_KEY='$NVD_API_KEY' SONAR_DB_PASSWORD='$SONAR_DB_PASSWORD' /home/ubuntu/setup_ci.sh"; then
            echo -e "${CYAN}---------------------------------------------------------------${NC}"
            echo -e "${GREEN}[+] CI Security 100% concluído em $TARGET_NAME!${NC}"
        else
            echo -e "${CYAN}---------------------------------------------------------------${NC}"
            echo -e "${RED}[!] ERRO CRÍTICO durante a orquestração da CI em $TARGET_NAME!${NC}"
        fi
        ssh -p "$SSH_PORT" -o StrictHostKeyChecking=no -i "$SSH_PRIV_KEY" ubuntu@"$TARGET_IP" "rm -f /home/ubuntu/setup_ci.sh" 2>/dev/null
    }

    if [ "$INSTANCE_TYPE" = "CI" ]; then
        # CI post-deploy flow (skips the generic bug bounty menu)
        IFS='|' read -r m_name m_ip <<< "${PROVISIONED_MACHINES[0]}"
        echo -e "\n${MAGENTA}===============================================================${NC}"
        echo -e "${MAGENTA}   PÓS-DEPLOY: CONFIGURAÇÃO DE CI SECURITY                    ${NC}"
        echo -e "${MAGENTA}===============================================================${NC}"
        read -p "➔ Deseja instalar ferramentas CI Security em $m_name ($m_ip)? [S/n]: " OPT_CI
        if [[ ! "$OPT_CI" =~ ^[nN]$ ]]; then
            install_ci_on_machine "$m_name" "$m_ip"
        fi
    else
        # Standard post-deploy flow for Bug Bounty
        echo -e "\n${MAGENTA}===============================================================${NC}"
        echo -e "${MAGENTA}   PÓS-DEPLOY: MONITORAMENTO & FERRAMENTAS (BUG BOUNTY)       ${NC}"
        echo -e "${MAGENTA}===============================================================${NC}"
        echo -e "${YELLOW}Em quais máquinas você deseja executar a orquestração pós-deploy?${NC}"
        echo "0) Nenhuma (Pular instalação e sair)"
        
        for i in "${!PROVISIONED_MACHINES[@]}"; do
            IFS='|' read -r m_name m_ip <<< "${PROVISIONED_MACHINES[$i]}"
            echo "$((i+1))) $m_name ($m_ip)"
        done
        
        if [ ${#PROVISIONED_MACHINES[@]} -gt 1 ]; then
            echo "T) Em TODAS as máquinas listadas acima (execução paralela)"
        fi
        
        read -p "Opção: " OPT_TOOLS

        if [[ "$OPT_TOOLS" != "0" ]]; then
            echo -e "${YELLOW}---------------------------------------------------------------${NC}"
            echo -e "${CYAN}Escolha o Perfil de Ferramentas:${NC}"
            echo "1) Full Pentest (Arsenal Completo + Docker)"
            echo "2) Web Pentest (Recon & Varredura Web)"
            echo "3) Infra Pentest (AD & Exploração de Redes)"
            read -p "Opção de Perfil [1-3, Padrão 1]: " OPT_PROFILE
            [ -z "$OPT_PROFILE" ] && OPT_PROFILE="1"
            echo -e "${YELLOW}---------------------------------------------------------------${NC}"
            read -p "➔ Deseja instalar a Interface Gráfica (XFCE + VNC)? [s/N]: " OPT_GUI

        fi
    fi
    

    if [ "$INSTANCE_TYPE" != "CI" ]; then
        if [[ "$OPT_TOOLS" == "0" ]]; then
            echo -e "${YELLOW}[*] Orquestração ignorada pelo usuário.${NC}"
        elif [[ "$OPT_TOOLS" == "t" || "$OPT_TOOLS" == "T" ]]; then
            for item in "${PROVISIONED_MACHINES[@]}"; do
                IFS='|' read -r m_name m_ip <<< "$item"
                install_on_machine "$m_name" "$m_ip"
            done
        else
            INDEX=$((OPT_TOOLS-1))
            if [ $INDEX -ge 0 ] && [ $INDEX -lt ${#PROVISIONED_MACHINES[@]} ]; then
                IFS='|' read -r m_name m_ip <<< "${PROVISIONED_MACHINES[$INDEX]}"
                install_on_machine "$m_name" "$m_ip"
            else
                echo -e "${RED}[!] Opção inválida. Instalação ignorada.${NC}"
            fi
        fi
    fi
fi

# Machine access summary
if [ ${#PROVISIONED_MACHINES[@]} -gt 0 ]; then
    echo -e "\n${MAGENTA}======= ACESSO ÀS MÁQUINAS =======${NC}"
    for item in "${PROVISIONED_MACHINES[@]}"; do
        IFS='|' read -r m_name m_ip <<< "$item"
        echo -ne "${GREEN}$m_name${NC} -> "

        FPORT="22"
        if ssh -p 2222 -q -o BatchMode=yes -o ConnectTimeout=2 -o StrictHostKeyChecking=no -i "$SSH_PRIV_KEY" ubuntu@"$m_ip" "echo ok" 2>/dev/null | grep -q 'ok'; then
            FPORT="2222"
        fi
        echo -e "${YELLOW}ssh -p $FPORT -i ~/.ssh/oci_vps_key ubuntu@$m_ip${NC}"

        if [ "$INSTANCE_TYPE" = "CI" ]; then
            echo -e "  ${CYAN}Túnel SonarQube:  ssh -N -L 9000:localhost:9000 -p $FPORT -i ~/.ssh/oci_vps_key ubuntu@$m_ip${NC}"
            echo -e "  ${CYAN}Depois acesse:    http://localhost:9000${NC}"
        fi
    done
    echo -e "${MAGENTA}==================================${NC}\n"
else
    echo -e "\n${RED}[!] Nenhuma instância foi provisionada com sucesso.${NC}"
fi