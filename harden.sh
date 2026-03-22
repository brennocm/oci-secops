#!/bin/bash
export LANG=C.UTF-8
# =================================================================
# SCRIPT DE ULTRA-HARDENING PARA INSTÂNCIAS OCI ARM (UBUNTU)
# Desenvolvido para Segurança, Furtividade e Defesa Automatizada
# =================================================================

# --- DEFINIÇÕES DE CORES ---
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

export DEBIAN_FRONTEND=noninteractive

echo -e "${CYAN}[*] Iniciando Procedimento de Ultra-Hardening...${NC}"

# 1. ATUALIZAÇÃO E CORREÇÃO DO SISTEMA
echo -e "${YELLOW}[1/8] Atualizando o sistema e aplicando correções de vulnerabilidades...${NC}"
# Adicionando resiliência ao apt-get update em caso de falha transitória nos repositórios OCI
apt-get update -y || (sleep 10 && apt-get update -y)
apt-get dist-upgrade -y
apt-get autoremove -y && apt-get autoclean
echo -e "${GREEN}[+] Sistema atualizado.${NC}"

# 2. INSTALAÇÃO DE FERRAMENTAS DE SEGURANÇA
echo -e "${YELLOW}[2/8] Instalando pacotes de segurança críticos...${NC}"
# Perfis do AppArmor adicionados
apt-get install -y ufw fail2ban unattended-upgrades lynis needrestart libpam-tmpdir apparmor-profiles apparmor-utils
echo -e "${GREEN}[+] Pacotes de segurança instalados.${NC}"

# 3. ATUALIZAÇÕES DE SEGURANÇA AUTOMÁTICAS (Configure e Esqueça)
echo -e "${YELLOW}[3/8] Configurando Atualizações de Segurança Automatizadas...${NC}"
cat << 'APT' > /etc/apt/apt.conf.d/50unattended-upgrades
Unattended-Upgrade::Allowed-Origins { "${distro_id}:${distro_codename}-security"; };
Unattended-Upgrade::Package-Blacklist { };
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:00";
APT
echo -e "${GREEN}[+] Patches automáticos habilitados (Reinicialização definida para 04:00).${NC}"

# 4. HARDENING DO KERNEL E REDE (SYSCTL)
echo -e "${YELLOW}[4/8] Endurecendo o Kernel Linux (Anti-Spoof/Anti-DoS/IPv6/Rede)...${NC}"
cat << 'SYS' > /etc/sysctl.d/99-hardened.conf
# Ignorar redirecionamentos ICMP (previne MITM)
net.ipv4.conf.all.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0

# Proteção contra IP Spoofing
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# Proteção contra TCP SYN Flood (Anti-DoS)
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 2048
net.ipv4.tcp_synack_retries = 2

# Desabilitar roteamento por IP de origem
net.ipv4.conf.all.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0

# Restringir acesso a ponteiros do kernel (Mitigação de Exploits)
kernel.kptr_restrict = 2
kernel.perf_event_paranoid = 3

# Desabilitar IPv6 completamente para evitar bypasses
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1

# Ajuste agressivo de rede para ferramentas de Pentest
fs.file-max = 2097152
net.ipv4.ip_local_port_range = 1024 65535

# Ajuste de swap (definido proativamente — inofensivo sem swap)
vm.swappiness = 10
SYS
sysctl -p /etc/sysctl.d/99-hardened.conf
echo -e "${GREEN}[+] Parâmetros de Kernel e Rede endurecidos.${NC}"

# 4.5. PROTEÇÕES DE MEMÓRIA E PONTOS DE MONTAGEM
echo -e "${YELLOW}[4.5/8] Protegendo Pontos de Montagem e Memória (Swap)...${NC}"
# hidepid do /proc
grep -q "hidepid" /etc/fstab || echo "proc /proc proc defaults,hidepid=2 0 0" >> /etc/fstab
mount -o remount,hidepid=2 /proc || true

# Restrições do /tmp (mantendo exec para compatibilidade com ferramentas de Pentest)
if ! grep -q "/tmp tmpfs" /etc/fstab; then
    echo "tmpfs /tmp tmpfs defaults,nosuid,nodev 0 0" >> /etc/fstab
    echo "tmpfs /var/tmp tmpfs defaults,nosuid,nodev 0 0" >> /etc/fstab
    mount /tmp || true
    mount /var/tmp || true
fi
mount -o remount,nosuid,nodev /dev/shm || true

# Geração dinâmica de Swap (4GB) para proteção contra OOM durante Fuzzing/Katana
if [ ! -f /swapfile ] && [ "$(df -BG / | awk 'NR==2 {print $4}' | sed 's/G//')" -gt 10 ]; then
    fallocate -l 4G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo "/swapfile none swap sw 0 0" >> /etc/fstab
fi
echo -e "${GREEN}[+] Limites de memória e pontos de montagem protegidos.${NC}"

# 5. HARDENING DO SERVIÇO SSH (A Defesa Principal)
echo -e "${YELLOW}[5/8] Protegendo o Protocolo SSH (Desabilitando Senhas/Root/Corrigindo Socket)...${NC}"
cat << 'SSH' > /etc/ssh/sshd_config.d/hardened.conf
Port 22
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
MaxAuthTries 3
ClientAliveInterval 300
ClientAliveCountMax 2
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding local
Compression no
DebianBanner no
# Restringir a HostKeys seguras
HostKey /etc/ssh/ssh_host_ed25519_key
HostKey /etc/ssh/ssh_host_rsa_key
# Banner de Segurança
Banner /etc/issue.net
SSH
# CORREÇÃO DE BUG: Usar reload em vez de restart para não encerrar sessões ativas do cloud-init
systemctl reload ssh || true
echo -e "${GREEN}[+] SSH endurecido (Autenticação por Senha Desabilitada).${NC}"

# 6. FIREWALL (UFW) E LIMPEZA OCI
echo -e "${YELLOW}[6/8] Configurando Firewall e removendo regras padrão OCI...${NC}"
# Limpar regras iptables padrão do OCI que frequentemente conflitam com UFW
iptables -F INPUT
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
echo "y" | ufw enable
echo -e "${GREEN}[+] Firewall ativo. Portas 22, 80, 443 abertas.${NC}"

# 7. FAIL2BAN (Prevenção Agressiva de Intrusão)
echo -e "${YELLOW}[7/8] Configurando Fail2Ban (Banimento automático de ataques de força bruta)...${NC}"
cat << 'F2B' > /etc/fail2ban/jail.local
[sshd]
enabled = true
port = 22
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
bantime = 24h
findtime = 10m
F2B
systemctl restart fail2ban
echo -e "${GREEN}[+] Fail2Ban ativo (3 falhas = BANIMENTO por 24h).${NC}"

# 8. BANNER LEGAL (Dissuasão) E APPARMOR
echo -e "${YELLOW}[8/8] Configurando Banner de Segurança e AppArmor...${NC}"
echo "------------------------------------------------------------" > /etc/issue.net
echo "  AUTHORIZED ACCESS ONLY - THIS SYSTEM IS MONITORED" >> /etc/issue.net
echo "      All illegal activity will be reported." >> /etc/issue.net
echo "------------------------------------------------------------" >> /etc/issue.net
aa-enforce /etc/apparmor.d/* >/dev/null 2>&1 || true
echo -e "${GREEN}[+] Banner de Segurança e regras do AppArmor definidos.${NC}"

echo -e "${CYAN}===============================================${NC}"
echo -e "${CYAN}   HARDENING CONCLUÍDO - SISTEMA PROTEGIDO     ${NC}"
echo -e "${CYAN}===============================================${NC}"
touch /root/hardening_complete