#!/bin/bash

# --- SUPRIMIR AVISOS ---
export SUPPRESS_LABEL_WARNING=True

# --- DEFINIÇÃO DO CAMINHO DO SCRIPT E LOG ---
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
LOG_FILE="$SCRIPT_DIR/provisioned_vps.log"

# --- DEFINIÇÃO DE CORES ---
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
echo -ne "${YELLOW}[*] Verificando ambiente OCI em busca de recursos ativos... ${NC}"

TENANCY_ID=$(grep "^tenancy=" ~/.oci/config | cut -d'=' -f2)
if [ -z "$TENANCY_ID" ]; then
    echo -e "${RED}\n[!] Erro: Não foi possível encontrar o tenancy em ~/.oci/config${NC}"
    exit 1
fi
echo -e "${GREEN}OK!${NC}"

# Listar instâncias ARM ativas (Running, Starting ou Stopped)
echo -ne "${YELLOW}[*] Buscando instâncias ARM ativas... ${NC}"
INSTANCES_JSON=$(oci compute instance list --compartment-id "$TENANCY_ID" --output json 2>/dev/null | jq -r '.data | map(select(."shape" == "VM.Standard.A1.Flex" and (."lifecycle-state" == "RUNNING" or ."lifecycle-state" == "STARTING" or ."lifecycle-state" == "STOPPED" or ."lifecycle-state" == "PROVISIONING"))) | .[] | "\(.id)|\(."display-name")|\(."lifecycle-state")"')

# Se não encontrar instâncias
if [ -z "$INSTANCES_JSON" ]; then
    echo -e "${GREEN}Nenhuma encontrada.${NC}"
    echo -e "\n${CYAN}===============================================================${NC}"
    echo -e "${GREEN}[+] O seu ambiente ARM Always Free já está totalmente limpo.${NC}"
    
    if [ -f "$LOG_FILE" ]; then
        echo -e "${CYAN}---------------------------------------------------------------${NC}"
        read -p "Deseja apagar o arquivo de log local antigo ($LOG_FILE)? (s/N): " DEL_LOG
        if [[ "$DEL_LOG" == "s" || "$DEL_LOG" == "S" ]]; then
            rm -f "$LOG_FILE"
            echo -e "${GREEN}[+] Log local removido com sucesso.${NC}"
        fi
    fi
    exit 0
fi
echo -e "${GREEN}Encontradas!${NC}"

# Criar um array para facilitar o processamento
IFS=$'\n' read -rd '' -a INSTANCE_ARRAY <<< "$INSTANCES_JSON"
NUM_INSTANCES=${#INSTANCE_ARRAY[@]}

# --- MINI-AUDITORIA ANTES DO NUKE ---
echo -e "\n${MAGENTA}===============================================================${NC}"
echo -e "${MAGENTA}                 RECURSOS ATUALMENTE ATIVOS                   ${NC}"
echo -e "${MAGENTA}===============================================================${NC}"
echo -e "Você tem ${CYAN}${NUM_INSTANCES}${NC} instância(s) ARM consumindo recursos neste momento:\n"

echo -e "ID | NOME | ESTADO"
echo -e "${CYAN}---------------------------------------------------------------${NC}"
i=1
for line in "${INSTANCE_ARRAY[@]}"; do
    NAME=$(echo "$line" | cut -d'|' -f2)
    STATE=$(echo "$line" | cut -d'|' -f3)
    echo -e "$i) ${CYAN}$NAME${NC} [${YELLOW}$STATE${NC}]"
    i=$((i+1))
done
echo -e "${CYAN}---------------------------------------------------------------${NC}"

echo -e "\n${MAGENTA}O QUE VOCÊ DESEJA FAZER?${NC}"
echo "1) Apagar UMA instância específica"
echo "2) APAGAR TUDO (Destruir todas as instâncias ARM + Apagar Logs)"
echo "3) Sair sem fazer nada"
read -p "Opção: " OPTION

terminate_instance() {
    local OCID=$1
    local NAME=$2
    echo -e "\n${RED}[!] Enviando ordem de destruição para: $NAME...${NC}"

    # Executa o comando de encerramento
    oci compute instance terminate --instance-id "$OCID" --preserve-boot-volume false --force

    if [ $? -eq 0 ]; then
        echo -ne "${YELLOW}[*] Status no painel: TERMINANDO. Aguardando finalização... ${NC}"

        # Loop de verificação em tempo real
        while true; do
            STATE=$(oci compute instance get --instance-id "$OCID" --output json 2>/dev/null | jq -r '.data."lifecycle-state"')
            
            if [ "$STATE" == "TERMINATED" ]; then
                echo -e "${GREEN} ENCERRADO!${NC}"
                echo -e "${GREEN}[+] Sucesso: $NAME e seu volume de boot de 50GB foram completamente apagados.${NC}"
                break
            elif [ "$STATE" == "null" ] || [ -z "$STATE" ]; then
                # Se a API retornar null, o recurso foi removido por completo
                echo -e "${GREEN} REMOVIDO!${NC}"
                echo -e "${GREEN}[+] Sucesso: $NAME desapareceu do ambiente.${NC}"
                break
            fi

            # Imprime um ponto a cada 5 segundos para indicar progresso
            echo -ne "${YELLOW}.${NC}"
            sleep 5
        done
    else
        echo -e "${RED}[-] Erro ao tentar enviar o comando de remoção para $NAME.${NC}"
    fi
}

case $OPTION in
    1)
        read -p "Digite o número da instância da lista acima: " NUM
        INDEX=$((NUM-1))
        if [ $INDEX -ge 0 ] && [ $INDEX -lt ${#INSTANCE_ARRAY[@]} ]; then
            SELECTED_LINE="${INSTANCE_ARRAY[$INDEX]}"
            OCID=$(echo "$SELECTED_LINE" | cut -d'|' -f1)
            NAME=$(echo "$SELECTED_LINE" | cut -d'|' -f2)
            terminate_instance "$OCID" "$NAME"
            echo -e "\n${YELLOW}[!] O log local não foi apagado para preservar o histórico das demais instâncias.${NC}"
        else
            echo -e "${RED}Opção inválida.${NC}"
        fi
        ;;
    2)
        echo -e "\n${RED}[!!!] AVISO: Isso apagará as ${NUM_INSTANCES} instâncias listadas, seus discos de boot e o log local.${NC}"
        read -p "Tem certeza absoluta? (s/N): " CONFIRM
        if [[ "$CONFIRM" == "s" || "$CONFIRM" == "S" ]]; then
            for line in "${INSTANCE_ARRAY[@]}"; do
                OCID=$(echo "$line" | cut -d'|' -f1)
                NAME=$(echo "$line" | cut -d'|' -f2)
                terminate_instance "$OCID" "$NAME"
            done
            
            # Apaga o log local após a destruição completa
            if [ -f "$LOG_FILE" ]; then
                rm -f "$LOG_FILE"
                echo -e "\n${GREEN}[+] Log local ($LOG_FILE) removido com sucesso.${NC}"
            fi
            echo -e "${GREEN}[+] Ambiente OCI limpo com sucesso!${NC}"
        else
            echo -e "${YELLOW}Operação cancelada pelo usuário.${NC}"
        fi
        ;;
    *)
        echo -e "${YELLOW}Encerrando sem realizar alterações...${NC}"
        ;;
esac