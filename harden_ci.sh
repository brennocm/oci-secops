#!/bin/bash
export LANG=C.UTF-8
# harden_ci.sh - Cloud-init user-data for the CI Security Instance
# (Option 5 in oci_provision.sh)

set -e

# --- 1. SYSTEM UPDATE ---
echo "[*] Atualizando pacotes do sistema..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get dist-upgrade -y
apt-get autoremove -y

# --- 2. PACKAGE INSTALLATION ---
echo "[*] Instalando pacotes de segurança e suporte..."
apt-get install -y \
  ufw fail2ban unattended-upgrades lynis needrestart libpam-tmpdir apparmor-profiles apparmor-utils \
  ca-certificates gnupg lsb-release curl jq

# --- 3. AUTOMATIC UPDATES ---
echo "[*] Configurando unattended-upgrades..."
cat > /etc/apt/apt.conf.d/50unattended-upgrades <<EOF
Unattended-Upgrade::Allowed-Origins {
    "\${distro_id}:\${distro_codename}";
    "\${distro_id}:\${distro_codename}-security";
    "\${distro_id}ESMApps:\${distro_codename}-apps-security";
    "\${distro_id}ESM:\${distro_codename}-infra-security";
};
Unattended-Upgrade::Package-Blacklist { };
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::InstallOnShutdown "false";
Unattended-Upgrade::Mail "root";
Unattended-Upgrade::MailOnlyOnFailure "true";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:00";
EOF

# --- 4. SYSCTL HARDENING ---
echo "[*] Aplicando hardening do sysctl..."
cat > /etc/sysctl.d/99-hardened.conf <<EOF
# Anti-spoof/anti-DoS network settings
net.ipv4.conf.all.rp_filter=1
net.ipv4.conf.default.rp_filter=1
net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.default.accept_redirects=0
net.ipv4.conf.all.secure_redirects=0
net.ipv4.conf.default.secure_redirects=0
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
net.ipv4.tcp_syncookies=1
net.ipv4.tcp_rfc1337=1

# Memory and process hardening
kernel.kptr_restrict=2
kernel.perf_event_paranoid=3
fs.file-max=65535
net.ipv4.ip_local_port_range=1024 65535

# Required by SonarQube's embedded Elasticsearch
vm.max_map_count=524288
EOF
sysctl -p /etc/sysctl.d/99-hardened.conf

# --- 4.5 MOUNT POINT PROTECTIONS ---
echo "[*] Endurecendo pontos de montagem..."
# hidepid=2 for /proc
mount -o remount,hidepid=2 /proc 2>/dev/null || true
echo "proc /proc proc defaults,nosuid,nodev,noexec,hidepid=2 0 0" >> /etc/fstab

# /tmp noexec/nosuid/nodev (if not handled by libpam-tmpdir)
# Note: We do not use swap on the CI instance to avoid Elasticsearch thrashing

# --- 5. DOCKER INSTALLATION ---
echo "[*] Instalando Docker Engine..."
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
  https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
  > /etc/apt/sources.list.d/docker.list

apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

usermod -aG docker ubuntu
systemctl enable docker
systemctl start docker

# --- 6. SSH HARDENING ---
echo "[*] Endurecendo SSH..."
cat > /etc/ssh/sshd_config.d/hardened.conf << 'EOF'
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
MaxAuthTries 3
ClientAliveInterval 300
ClientAliveCountMax 2
AllowTcpForwarding local
X11Forwarding no
EOF
systemctl reload ssh || true

# --- 7. UFW FIREWALL (PORT 22 ONLY) ---
echo "[*] Configurando UFW (SOMENTE PORTA 22)..."
iptables -F INPUT
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp
echo "y" | ufw enable

# --- 8. FAIL2BAN CONFIGURATION ---
echo "[*] Configurando Fail2ban..."
cat > /etc/fail2ban/jail.local <<EOF
[sshd]
enabled = true
port = 22
maxretry = 3
bantime = 86400
findtime = 3600
EOF
systemctl restart fail2ban

# --- 9. APPARMOR + COMPLETION ---
systemctl enable apparmor
systemctl start apparmor

echo "--------------------------------------------------------"
echo " HARDENING CI CONCLUÍDO COM SUCESSO "
echo "--------------------------------------------------------"
touch /root/hardening_complete
 