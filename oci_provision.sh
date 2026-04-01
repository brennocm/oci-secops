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

echo -e "${CYAN}---------------------------------------------------------------${NC}"

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
read -p "Seleção: " OPTION

check_storage_req() {
    if [ "$1" -gt "$FREE_STORAGE" ]; then
        echo -e "${RED}[!] ERRO: A seleção exige $1GB, mas você só tem ${FREE_STORAGE}GB disponíveis.${NC}"
        exit 1
    fi
}

launch_vps() {
    local NAME=$1
    local OCPU=$2
    local RAM=$3
    local USERDATA="${4:-$SCRIPT_DIR/harden.sh}"   # default: harden.sh
    local START_TIME=$(date +%s)
    local RETRY_COUNT=0
    local MAX_RETRIES=20  # 20 tentativas × 60s = ~20 minutos

    while true; do
        echo -e "\n${YELLOW}[...] Buscando capacidade: $NAME ($OCPU OCPU / ${RAM}GB RAM)${NC}"

        LAUNCH_RES=$(oci compute instance launch \
            --availability-domain "$AD_NAME" \
            --compartment-id "$TENANCY_ID" \
            --shape "VM.Standard.A1.Flex" \
            --shape-config "{\"ocpus\": $OCPU, \"memoryInGBs\": $RAM}" \
            --display-name "$NAME" \
            --image-id "$IMAGE_ID" \
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
        check_storage_req 50
        read -p "Nome da instância [Pressione Enter para 'ARM-Monster']: " CUSTOM_NAME
        launch_vps "${CUSTOM_NAME:-ARM-Monster}" 4 24 
        ;;
    2) 
        check_storage_req 100
        read -p "Prefixo das instâncias [Pressione Enter para 'ARM-Twin']: " CUSTOM_PREFIX
        PREFIX=${CUSTOM_PREFIX:-ARM-Twin}
        for i in {1..2}; do launch_vps "${PREFIX}-$i" 2 12 & done 
        wait
        ;;
    3) 
        check_storage_req 200
        read -p "Prefixo das instâncias [Pressione Enter para 'ARM-Small']: " CUSTOM_PREFIX
        PREFIX=${CUSTOM_PREFIX:-ARM-Small}
        for i in {1..4}; do launch_vps "${PREFIX}-$i" 1 6 & done 
        wait
        ;;
    4) 
        check_storage_req 50
        read -p "Nome da instância [Pressione Enter para 'ARM-Single']: " CUSTOM_NAME
        launch_vps "${CUSTOM_NAME:-ARM-Single}" 1 6 
        ;;
    5)
        if [ "$CI_READY" = false ]; then
            echo -e "${RED}[!] harden_ci.sh ou setup_ci.sh ausente.${NC}"
            rm -f "$TEMP_MACHINES_FILE"; exit 1
        fi
        check_storage_req 50
        read -p "Nome da instância [Pressione Enter para 'ARM-CI-Security']: " CUSTOM_NAME
        INSTANCE_TYPE="CI"
        launch_vps "${CUSTOM_NAME:-ARM-CI-Security}" 4 24 "$SCRIPT_DIR/harden_ci.sh"
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