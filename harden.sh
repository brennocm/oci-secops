#!/bin/bash
export LANG=C.UTF-8
# =================================================================
# ULTRA-HARDENING SCRIPT FOR OCI ARM INSTANCES (UBUNTU)
# Designed for Security, Stealth, and Automated Defense
# =================================================================

# --- COLOR DEFINITIONS ---
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

export DEBIAN_FRONTEND=noninteractive

echo -e "${CYAN}[*] Iniciando Procedimento de Ultra-Hardening...${NC}"

# 1. SYSTEM UPDATE AND PATCH
echo -e "${YELLOW}[1/8] Atualizando o sistema e aplicando correções de vulnerabilidades...${NC}"
# Adding resilience to apt-get update in case of transient OCI repository failures
apt-get update -y || (sleep 10 && apt-get update -y)
apt-get dist-upgrade -y
apt-get autoremove -y && apt-get autoclean
echo -e "${GREEN}[+] Sistema atualizado.${NC}"

# 2. SECURITY TOOLS INSTALLATION
echo -e "${YELLOW}[2/8] Instalando pacotes de segurança críticos...${NC}"
# AppArmor profiles added
apt-get install -y ufw fail2ban unattended-upgrades lynis needrestart libpam-tmpdir apparmor-profiles apparmor-utils
echo -e "${GREEN}[+] Pacotes de segurança instalados.${NC}"

# 3. AUTOMATIC SECURITY UPDATES (Set and Forget)
echo -e "${YELLOW}[3/8] Configurando Atualizações de Segurança Automatizadas...${NC}"
cat << 'APT' > /etc/apt/apt.conf.d/50unattended-upgrades
Unattended-Upgrade::Allowed-Origins { "${distro_id}:${distro_codename}-security"; };
Unattended-Upgrade::Package-Blacklist { };
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:00";
APT
echo -e "${GREEN}[+] Patches automáticos habilitados (Reinicialização definida para 04:00).${NC}"

# 4. KERNEL AND NETWORK HARDENING (SYSCTL)
echo -e "${YELLOW}[4/8] Endurecendo o Kernel Linux (Anti-Spoof/Anti-DoS/IPv6/Rede)...${NC}"
cat << 'SYS' > /etc/sysctl.d/99-hardened.conf
# Ignore ICMP redirects (prevents MITM)
net.ipv4.conf.all.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0

# Protection against IP Spoofing
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# Protection against TCP SYN Flood (Anti-DoS)
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 2048
net.ipv4.tcp_synack_retries = 2

# Disable source IP routing
net.ipv4.conf.all.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0

# Restrict access to kernel pointers (Exploit Mitigation)
kernel.kptr_restrict = 2
kernel.perf_event_paranoid = 3

# Disable IPv6 entirely to prevent bypasses
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1

# Aggressive network tuning for Pentest tools
fs.file-max = 2097152
net.ipv4.ip_local_port_range = 1024 65535

# Swap tuning (set proactively — harmless without a swap device)
vm.swappiness = 10
SYS
sysctl -p /etc/sysctl.d/99-hardened.conf
echo -e "${GREEN}[+] Parâmetros de Kernel e Rede endurecidos.${NC}"

# 4.5. MEMORY AND MOUNT POINT PROTECTIONS
echo -e "${YELLOW}[4.5/8] Protegendo Pontos de Montagem e Memória (Swap)...${NC}"
# hidepid for /proc
grep -q "hidepid" /etc/fstab || echo "proc /proc proc defaults,hidepid=2 0 0" >> /etc/fstab
mount -o remount,hidepid=2 /proc || true

# /tmp restrictions (keeping exec for compatibility with Pentest tools)
if ! grep -q "/tmp tmpfs" /etc/fstab; then
    echo "tmpfs /tmp tmpfs defaults,nosuid,nodev 0 0" >> /etc/fstab
    echo "tmpfs /var/tmp tmpfs defaults,nosuid,nodev 0 0" >> /etc/fstab
    mount /tmp || true
    mount /var/tmp || true
fi
mount -o remount,nosuid,nodev /dev/shm || true

# Dynamic Swap generation (4GB) to protect against OOM during Fuzzing/Katana
if [ ! -f /swapfile ] && [ "$(df -BG / | awk 'NR==2 {print $4}' | sed 's/G//')" -gt 10 ]; then
    fallocate -l 4G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo "/swapfile none swap sw 0 0" >> /etc/fstab
fi
echo -e "${GREEN}[+] Limites de memória e pontos de montagem protegidos.${NC}"

# 5. SSH SERVICE HARDENING (The Primary Defense)
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
# Restrict to secure HostKeys
HostKey /etc/ssh/ssh_host_ed25519_key
HostKey /etc/ssh/ssh_host_rsa_key
# Security Banner
Banner /etc/issue.net
SSH
# BUG FIX: Use reload instead of restart to avoid terminating active cloud-init sessions
systemctl reload ssh || true
echo -e "${GREEN}[+] SSH endurecido (Autenticação por Senha Desabilitada).${NC}"

# 6. FIREWALL (UFW) AND OCI CLEANUP
echo -e "${YELLOW}[6/8] Configurando Firewall e removendo regras padrão OCI...${NC}"
# Clear default OCI iptables rules that frequently conflict with UFW
iptables -F INPUT
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
echo "y" | ufw enable
echo -e "${GREEN}[+] Firewall ativo. Portas 22, 80, 443 abertas.${NC}"

# 7. FAIL2BAN (Aggressive Intrusion Prevention)
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

# 8. LEGAL BANNER (Deterrence) AND APPARMOR
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