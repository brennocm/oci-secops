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

# A1 capacity is allocated per Availability Domain: a region with 3 ADs gives
# three independent chances of finding a host, so all of them are collected.
mapfile -t AD_LIST < <(oci iam availability-domain list --compartment-id "$TENANCY_ID" --output json 2>/dev/null | jq -r '.data[].name')
if [ ${#AD_LIST[@]} -eq 0 ]; then
    echo -e "${RED}[!] ERRO: nenhum Availability Domain retornado pela API.${NC}"
    exit 1
fi
AD_NAME="${AD_LIST[0]}"   # AD de referência para consultas de AD única
if [ ${#AD_LIST[@]} -eq 1 ]; then
    echo -e "  > Nome do AD:      ${GREEN}$AD_NAME${NC}"
else
    echo -e "  > ADs na região:   ${GREEN}${#AD_LIST[@]} → ${AD_LIST[*]}${NC}"
fi

SUBNET_ID=$(oci network subnet list --compartment-id "$TENANCY_ID" --output json 2>/dev/null | jq -r '.data[0].id')
if [ -z "$SUBNET_ID" ] || [ "$SUBNET_ID" == "null" ]; then exit 1; fi
echo -e "  > Sub-rede:        ${GREEN}$SUBNET_ID${NC}"

IMAGE_ID=$(oci compute image list --compartment-id "$TENANCY_ID" --operating-system "Canonical Ubuntu" --operating-system-version "24.04" --shape "VM.Standard.A1.Flex" --sort-by "TIMECREATED" --output json 2>/dev/null | jq -r '.data[0].id')
if [ -z "$IMAGE_ID" ] || [ "$IMAGE_ID" == "null" ]; then exit 1; fi
echo -e "  > Imagem (24.04):  ${GREEN}$IMAGE_ID${NC}"

# --- A1 QUOTA DISCOVERY (feeds the "Limited Full Power" strategy) ---
# Reads the tenancy's real Ampere A1 allowance instead of assuming the
# documented 4 OCPU / 24GB: Oracle caps it per-tenancy/per-region.
get_limit() {
    # $1 = limit-name, $2 = availability domain, $3 = campo (available|used)
    oci limits resource-availability get \
        --service-name compute \
        --limit-name "$1" \
        --compartment-id "$TENANCY_ID" \
        --availability-domain "$2" \
        --output json 2>/dev/null | jq -r ".data.\"$3\" // empty"
}

# "livre" = melhor colocação em UMA AD (uma instância vive em uma só AD).
# "em uso" = soma de todas as ADs (o teto Always Free é da tenancy inteira).
A1_CORES_FREE=0
A1_RAM_FREE=0
A1_CORES_USED=0
A1_RAM_USED=0
QUOTA_OK=false
for AD in "${AD_LIST[@]}"; do
    C_FREE=$(get_limit "standard-a1-core-count"   "$AD" "available")
    R_FREE=$(get_limit "standard-a1-memory-count" "$AD" "available")
    C_USED=$(get_limit "standard-a1-core-count"   "$AD" "used")
    R_USED=$(get_limit "standard-a1-memory-count" "$AD" "used")
    [[ "$C_USED" =~ ^[0-9]+$ ]] && A1_CORES_USED=$(( A1_CORES_USED + C_USED ))
    [[ "$R_USED" =~ ^[0-9]+$ ]] && A1_RAM_USED=$(( A1_RAM_USED + R_USED ))
    if [[ "$C_FREE" =~ ^[0-9]+$ ]] && [[ "$R_FREE" =~ ^[0-9]+$ ]]; then
        QUOTA_OK=true
        [ "$C_FREE" -gt "$A1_CORES_FREE" ] && A1_CORES_FREE=$C_FREE
        [ "$R_FREE" -gt "$A1_RAM_FREE" ] && A1_RAM_FREE=$R_FREE
    fi
done

if [ "$QUOTA_OK" = true ]; then
    echo -e "  > Cota A1 livre:   ${GREEN}${A1_CORES_FREE} OCPU / ${A1_RAM_FREE}GB RAM${NC}"
else
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

# --- CAPACITY HUNT TUNING (override via ambiente) ---
# A1 capacity opens in unpredictable, short windows: the hunt is a time budget,
# not a fixed number of tries. Probing uses the capacity report API, which has
# no side effect and a far looser rate limit than launch_instance.
HUNT_MINUTES=${HUNT_MINUTES:-180}                    # janela total por instância
POLL_SECONDS=${POLL_SECONDS:-30}                     # intervalo entre sondagens
BLIND_POLL_SECONDS=${BLIND_POLL_SECONDS:-60}         # intervalo sem capacity report
MAX_RATE_RETRIES=${MAX_RATE_RETRIES:-6}              # 429 CONSECUTIVOS tolerados
BOOT_TIMEOUT_SECONDS=${BOOT_TIMEOUT_SECONDS:-900}    # teto para chegar em RUNNING

# --- ALWAYS FREE COMPLIANCE CHECK (Storage) ---
# The 200GB allotment covers BOOT *and* BLOCK volumes, in every AD -- counting
# only boot volumes of AD[0] underestimates usage and can push past the ceiling.
sum_volumes() {
    # $1 = subcomando bv (boot-volume|volume), $2 = AD
    oci bv "$1" list --availability-domain "$2" --compartment-id "$TENANCY_ID" --output json 2>/dev/null \
        | jq '[.data[]? | select(."lifecycle-state" != "TERMINATED") | ."size-in-gbs"] | add // 0'
}

USED_STORAGE=0
for AD in "${AD_LIST[@]}"; do
    for KIND in boot-volume volume; do
        SZ=$(sum_volumes "$KIND" "$AD")
        [[ "$SZ" =~ ^[0-9]+$ ]] && USED_STORAGE=$(( USED_STORAGE + SZ ))
    done
done
FREE_STORAGE=$(( AF_MAX_STORAGE - USED_STORAGE ))

if [ "$FREE_STORAGE" -lt 50 ]; then
     echo -e "${RED}[!] CRÍTICO: Armazenamento Always Free insuficiente (Disponível: ${FREE_STORAGE}GB).${NC}"
     exit 1
fi

# --- INGRESS PRE-FLIGHT ---
# harden.sh libera 22/80/443 no ufw, mas a security list da VCN filtra antes:
# sem ingress na 22 o pós-deploy trava esperando um SSH que nunca conecta.
INGRESS_JSON=$(oci network security-list list --compartment-id "$TENANCY_ID" --output json 2>/dev/null)
port_open() {
    echo "$INGRESS_JSON" | jq -e --argjson p "$1" '
        [ .data[]?."ingress-security-rules"[]?
          | select(.source == "0.0.0.0/0")
          | select(.protocol == "all" or .protocol == "6")
          | select( (."tcp-options" == null)
                    or (."tcp-options"."destination-port-range" == null)
                    or ( (."tcp-options"."destination-port-range".min <= $p)
                         and (."tcp-options"."destination-port-range".max >= $p) ) )
        ] | length > 0' >/dev/null 2>&1
}
MISSING_PORTS=()
for P in 22 80 443; do port_open "$P" || MISSING_PORTS+=("$P"); done
if [ ${#MISSING_PORTS[@]} -gt 0 ]; then
    echo -e "${YELLOW}[!] AVISO: a security list da VCN não tem ingress 0.0.0.0/0 para: ${MISSING_PORTS[*]}${NC}"
    if printf '%s\n' "${MISSING_PORTS[@]}" | grep -qx 22; then
        echo -e "${RED}    Sem a porta 22 o pós-deploy vai travar aguardando SSH.${NC}"
        echo -e "${YELLOW}    Console > Networking > VCN > Security Lists > Add Ingress Rule.${NC}"
    else
        echo -e "${YELLOW}    O hardening abre essas portas no ufw, mas a VCN bloqueia antes.${NC}"
    fi
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

# Cheap, side-effect-free capacity probe (CreateComputeCapacityReport).
# Echoes AVAILABLE / OUT_OF_HOST_CAPACITY / HARDWARE_NOT_SUPPORTED, or nothing
# when the API is not reachable for this user (older CLI, missing IAM policy).
capacity_status() {
    local AD=$1 OCPU=$2 RAM=$3
    oci compute compute-capacity-report create \
        --compartment-id "$TENANCY_ID" \
        --availability-domain "$AD" \
        --shape-availabilities "[{\"instanceShape\":\"$AF_SHAPE\",\"instanceShapeConfig\":{\"ocpus\":$OCPU,\"memoryInGBs\":$RAM}}]" \
        --output json 2>/dev/null \
        | jq -r '.data."shape-availabilities"[0]."availability-status" // empty'
}

# Waits for a freshly launched instance to become usable and records it.
# Every wait here is bounded: a provision that fails or stalls must surface as
# an error, never hang the script.
finalize_instance() {
    local NAME=$1 AD=$2 RES=$3
    local INSTANCE_ID
    INSTANCE_ID=$(echo "$RES" | jq -r '.data.id // empty' 2>/dev/null)
    if [ -z "$INSTANCE_ID" ]; then
        echo -e "${RED}[!] Launch de $NAME retornou sem OCID. Resposta:\n$RES${NC}"
        return 1
    fi

    echo -ne "${CYAN}[*] Aguardando a instância $NAME inicializar... ${NC}"
    local WAIT_DEADLINE=$(( $(date +%s) + BOOT_TIMEOUT_SECONDS ))
    local STATE=""
    while true; do
        STATE=$(oci compute instance get --instance-id "$INSTANCE_ID" --output json 2>/dev/null | jq -r '.data."lifecycle-state" // empty')
        case "$STATE" in
            RUNNING)
                echo -e "${GREEN}EXECUTANDO ($NAME)!${NC}"
                break
                ;;
            TERMINATED|TERMINATING|STOPPED|STOPPING)
                echo -e "\n${RED}[!] $NAME entrou em ${STATE} antes de ficar pronta.${NC}"
                echo -e "${YELLOW}    OCID: $INSTANCE_ID${NC}"
                return 1
                ;;
        esac
        if [ "$(date +%s)" -ge "$WAIT_DEADLINE" ]; then
            echo -e "\n${RED}[!] Timeout: $NAME não chegou em RUNNING em ${BOOT_TIMEOUT_SECONDS}s (estado: ${STATE:-desconhecido}).${NC}"
            echo -e "${YELLOW}    Verifique no console: $INSTANCE_ID${NC}"
            return 1
        fi
        sleep 5
    done

    # A VNIC pode demorar alguns segundos para aparecer depois do RUNNING.
    local PUBLIC_IP=""
    local IP_DEADLINE=$(( $(date +%s) + 120 ))
    while true; do
        PUBLIC_IP=$(oci compute instance list-vnics --instance-id "$INSTANCE_ID" --output json 2>/dev/null | jq -r '.data[0]."public-ip" // empty')
        [ -n "$PUBLIC_IP" ] && break
        [ "$(date +%s)" -ge "$IP_DEADLINE" ] && break
        sleep 5
    done
    if [ -z "$PUBLIC_IP" ]; then
        echo -e "${RED}[!] $NAME está RUNNING mas sem IP público. OCID: $INSTANCE_ID${NC}"
        return 1
    fi

    echo -e "${GREEN}[+] CAPACIDADE GARANTIDA ($NAME em $AD)! IP: $PUBLIC_IP${NC}"
    echo "$(date) | $NAME | IP: $PUBLIC_IP | AD: $AD | ID: $INSTANCE_ID" >> "$LOG_FILE"

    # Adds the created machine to the temp file (thread-safe for parallel launches)
    echo "$NAME|$PUBLIC_IP" >> "$TEMP_MACHINES_FILE"
    return 0
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
    local DEADLINE=$(( START_TIME + HUNT_MINUTES * 60 ))
    local RATE_COUNT=0        # 429 CONSECUTIVOS, zerado a cada resposta normal
    local PROBES=0
    local ATTEMPTS=0
    local REPORT_OK=true      # cai para false se o capacity report não responder
    local LAUNCH_RES ST BACKOFF ELAPSED
    local TARGET_ADS=()

    echo -e "\n${YELLOW}[...] Caçando capacidade: $NAME ($OCPU OCPU / ${RAM}GB RAM${BOOT_DESC})${NC}"
    echo -e "${CYAN}      Janela ${HUNT_MINUTES}min | sondagem ${POLL_SECONDS}s | ${#AD_LIST[@]} AD(s)${NC}"

    while true; do
        if [ "$(date +%s)" -ge "$DEADLINE" ]; then
            ELAPSED=$(( $(date +%s) - START_TIME ))
            echo -e "\n${RED}[!] Janela de ${HUNT_MINUTES}min esgotada para '$NAME' (${ELAPSED}s, ${PROBES} sondagens, ${ATTEMPTS} launches).${NC}"
            echo -e "${YELLOW}    A demanda por A1 nesta região está alta no momento.${NC}"
            echo -e "${YELLOW}    Amplie a janela: HUNT_MINUTES=480 ./oci_provision.sh${NC}"
            echo -e "${YELLOW}    Considere também uma estratégia com menor alocação de recursos.${NC}"
            return 1
        fi

        # 1. Descobre onde há capacidade SEM efeito colateral. Só o resultado
        #    positivo justifica gastar uma chamada de launch_instance (429).
        TARGET_ADS=()
        if [ "$REPORT_OK" = true ]; then
            PROBES=$(( PROBES + 1 ))
            for AD in "${AD_LIST[@]}"; do
                ST=$(capacity_status "$AD" "$OCPU" "$RAM")
                if [ -z "$ST" ]; then
                    echo -e "${YELLOW}[!] Capacity report indisponível — caindo para sondagem direta.${NC}"
                    REPORT_OK=false
                    break
                fi
                [ "$ST" == "AVAILABLE" ] && TARGET_ADS+=("$AD")
            done
        fi
        if [ "$REPORT_OK" = false ]; then
            TARGET_ADS=("${AD_LIST[@]}")
        fi

        # 2. Nada disponível: espera e sonda de novo (log resumido a cada ~10).
        if [ ${#TARGET_ADS[@]} -eq 0 ]; then
            if [ $(( PROBES % 10 )) -eq 1 ]; then
                echo -e "${RED}[-] Sem capacidade para $NAME — sondagem ${PROBES}, $(( ($(date +%s) - START_TIME) / 60 ))/${HUNT_MINUTES}min decorridos.${NC}"
            fi
            sleep $(( POLL_SECONDS + RANDOM % 10 ))
            continue
        fi

        # 3. Há capacidade: dispara o launch de verdade.
        for AD in "${TARGET_ADS[@]}"; do
            ATTEMPTS=$(( ATTEMPTS + 1 ))
            [ "$REPORT_OK" = true ] && echo -e "${GREEN}[>] Capacidade detectada em $AD — lançando $NAME (launch #${ATTEMPTS})...${NC}"

            LAUNCH_RES=$(oci compute instance launch \
                --availability-domain "$AD" \
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
                RATE_COUNT=0
                if [ "$REPORT_OK" = true ]; then
                    echo -e "${RED}[-] A capacidade em $AD sumiu antes do launch. Continuando a caça...${NC}"
                elif [ $(( ATTEMPTS % 10 )) -eq 1 ]; then
                    echo -e "${RED}[-] Sem capacidade para $NAME — tentativa ${ATTEMPTS}, $(( ($(date +%s) - START_TIME) / 60 ))/${HUNT_MINUTES}min decorridos.${NC}"
                fi
                continue
            elif [[ $LAUNCH_RES == *"TooManyRequests"* ]]; then
                # HTTP 429: launch_instance é limitada por usuário e exige
                # backoff exponencial. Só 429 CONSECUTIVOS abortam a caça.
                RATE_COUNT=$(( RATE_COUNT + 1 ))
                if [ "$RATE_COUNT" -ge "$MAX_RATE_RETRIES" ]; then
                    echo -e "\n${RED}[!] ${MAX_RATE_RETRIES} rate limits consecutivos para '$NAME'.${NC}"
                    echo -e "${YELLOW}    A OCI limita chamadas de launch_instance por usuário.${NC}"
                    echo -e "${YELLOW}    Aguarde ~15 minutos sem novas tentativas e execute novamente.${NC}"
                    return 1
                fi
                BACKOFF=$(( 60 * (2 ** (RATE_COUNT - 1)) ))
                [ "$BACKOFF" -gt 600 ] && BACKOFF=600
                echo -e "${YELLOW}[-] Rate limit da API (429) — ${RATE_COUNT}/${MAX_RATE_RETRIES} consecutivos, aguardando ${BACKOFF}s...${NC}"
                sleep "$BACKOFF"
                continue
            elif [[ $LAUNCH_RES == *"LimitExceeded"* ]]; then
                echo -e "${RED}[!] Cota excedida para '$NAME' ($OCPU OCPU / ${RAM}GB RAM).${NC}"
                echo -e "${YELLOW}    Sua cota A1 livre é de ${A1_CORES_FREE:-?} OCPU / ${A1_RAM_FREE:-?}GB RAM.${NC}"
                echo -e "${YELLOW}    Use a opção 6 (Limited Full Power) para caber automaticamente,${NC}"
                echo -e "${YELLOW}    ou peça aumento em: Console > Limits, Quotas and Usage.${NC}"
                return 1
            elif [[ $LAUNCH_RES == *"Error"* || $LAUNCH_RES == *"ServiceError"* || $LAUNCH_RES == *"Usage:"* ]]; then
                echo -e "${RED}[!] Comando OCI falhou para $NAME! Detalhes:\n$LAUNCH_RES${NC}"
                return 1
            fi

            RATE_COUNT=0
            finalize_instance "$NAME" "$AD" "$LAUNCH_RES"
            return $?
        done

        # Nenhum launch desta rodada vingou (corrida perdida ou 429): sempre
        # espera antes da próxima, senão a caça vira uma rajada de chamadas
        # de launch_instance -- exatamente o que dispara o rate limit.
        if [ "$REPORT_OK" = true ]; then
            sleep "$POLL_SECONDS"
        else
            sleep "$BLIND_POLL_SECONDS"
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