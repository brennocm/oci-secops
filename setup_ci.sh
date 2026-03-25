#!/bin/bash
export LANG=C.UTF-8
# setup_ci.sh - CI tools installer, runs post-boot
# (Option 5 in oci_provision.sh — executed after cloud-init)

set -e

echo "[*] Verificando se o Docker está ativo..."
if ! systemctl is-active --quiet docker; then
    timeout 60 bash -c 'until systemctl is-active --quiet docker; do sleep 3; done'
fi

# --- 1b. QEMU (AMD64 emulation on ARM for x86 images such as owasp/dependency-check) ---
echo "[*] Instalando qemu-user-static para emulação AMD64..."
apt-get install -y qemu-user-static >/dev/null 2>&1
docker run --rm --privileged multiarch/qemu-user-static --reset -p yes >/dev/null 2>&1
echo "[+] Emulação AMD64 habilitada."

# --- 2. CREATE DIRECTORY STRUCTURE ---
echo "[*] Criando estrutura /opt/ci-security..."
mkdir -p /opt/ci-security/sonarqube
mkdir -p /opt/ci-security/dependency-check/data   # persistent NVD cache (~2 GB)
mkdir -p /opt/ci-security/zap/reports
chown -R ubuntu:ubuntu /opt/ci-security

# --- 2a. NVD API KEY (protected configuration) ---
echo "NVD_API_KEY=${NVD_API_KEY}" > /etc/dep-check.env
chmod 640 /etc/dep-check.env
chown root:ubuntu /etc/dep-check.env

# --- 2b. PRE-POPULATE THE NVD CACHE ---
echo "[*] Baixando cache NVD pré-construído (~111 MB)..."
NVD_RELEASE="https://github.com/666-member/dont-hurt-her/releases/download/v0.0.1/dep-check-data.tar.gz"
if wget -q -O /tmp/dep-check-data.tar.gz "$NVD_RELEASE"; then
    tar -xzf /tmp/dep-check-data.tar.gz -C /opt/ci-security/dependency-check/data/
    rm /tmp/dep-check-data.tar.gz
    chown -R ubuntu:ubuntu /opt/ci-security/dependency-check/data
    echo "[+] Cache NVD pré-populado."
else
    echo "[!] Falha ao baixar o cache NVD — a primeira execução do dep-check irá construí-lo automaticamente."
fi

# --- 3. DOCKER COMPOSE FOR SONARQUBE + POSTGRES ---
echo "[*] Criando arquivo Docker Compose para SonarQube..."
_SONAR_PASS="${SONAR_DB_PASSWORD}"
cat > /opt/ci-security/sonarqube/docker-compose.yml << EOF
services:
  sonarqube:
    image: sonarqube:community
    container_name: sonarqube
    restart: unless-stopped
    depends_on:
      - sonar_db
    environment:
      SONAR_JDBC_URL: jdbc:postgresql://sonar_db:5432/sonar
      SONAR_JDBC_USERNAME: sonar
      SONAR_JDBC_PASSWORD: ${_SONAR_PASS}
    ports:
      - "127.0.0.1:9000:9000"       # loopback only — SSH tunnel required
    volumes:
      - sonarqube_data:/opt/sonarqube/data
      - sonarqube_extensions:/opt/sonarqube/extensions
      - sonarqube_logs:/opt/sonarqube/logs
    deploy:
      resources:
        limits:
          memory: 12G

  sonar_db:
    image: postgres:16
    container_name: sonar_db
    restart: unless-stopped
    environment:
      POSTGRES_USER: sonar
      POSTGRES_PASSWORD: ${_SONAR_PASS}
      POSTGRES_DB: sonar
    volumes:
      - sonar_db_data:/var/lib/postgresql/data
    deploy:
      resources:
        limits:
          memory: 2G
    # No ports section — internal Docker network only

volumes:
  sonarqube_data:
  sonarqube_extensions:
  sonarqube_logs:
  sonar_db_data:
EOF

# --- 4. START SONARQUBE ---
echo "[*] Iniciando stack do SonarQube..."
(cd /opt/ci-security/sonarqube && docker compose up -d)

# --- 5. DEPENDENCY-CHECK WRAPPER ---
echo "[*] Instalando wrapper dep-check..."
cat > /usr/local/bin/dep-check << 'WRAPPER'
#!/bin/bash
set -e
[ -f /etc/dep-check.env ] && . /etc/dep-check.env
if [ -z "$NVD_API_KEY" ]; then
  echo "[!] NVD_API_KEY não definida. Adicione-a em /etc/dep-check.env"
  exit 1
fi
REPORT_DIR="${REPORT_DIR:-./security-reports/dependency-check}"
mkdir -p "$REPORT_DIR" /opt/ci-security/dependency-check/data

docker run --rm \
  --platform linux/amd64 \
  -e user="$USER" \
  -u "$(id -u):$(id -g)" \
  --volume "$(pwd)":/src:z \
  --volume /opt/ci-security/dependency-check/data:/usr/share/dependency-check/data:z \
  --volume "$(realpath "$REPORT_DIR")":/report:z \
  owasp/dependency-check:latest \
  --scan /src \
  --format "HTML" --format "JSON" \
  --project "$(basename "$(pwd)")" \
  --out /report \
  --exclude ".git/**" --exclude ".venv/**" \
  --exclude "node_modules/**" --exclude "__pycache__/**" \
  --nvdApiKey "$NVD_API_KEY" --failOnCVSS 7

echo "[+] Relatório: $REPORT_DIR/dependency-check-report.html"
WRAPPER
chmod +x /usr/local/bin/dep-check

# --- 6. ZAP WRAPPERS ---
echo "[*] Instalando wrappers do ZAP..."
cat > /usr/local/bin/zap-baseline << 'WRAPPER'
#!/bin/bash
set -e
APP_URL="${1:-http://localhost:8000}"
REPORT_DIR="${REPORT_DIR:-./security-reports/zap}"
mkdir -p "$REPORT_DIR"

docker run --rm \
  --network="host" \
  -v "$(realpath "$REPORT_DIR")":/zap/wrk/:rw \
  ghcr.io/zaproxy/zaproxy:stable \
  zap-baseline.py \
  -t "$APP_URL" \
  -r zap-baseline-report.html \
  -J zap-baseline-report.json \
  -I

echo "[+] Relatório: $REPORT_DIR/zap-baseline-report.html"
WRAPPER
chmod +x /usr/local/bin/zap-baseline

cat > /usr/local/bin/zap-api << 'WRAPPER'
#!/bin/bash
set -e
API_FILE="${1:-openapi.json}"
APP_URL="${2:-http://localhost:8000}"
REPORT_DIR="${REPORT_DIR:-./security-reports/zap}"
mkdir -p "$REPORT_DIR"

docker run --rm \
  --network="host" \
  -v "$(pwd)":/zap/wrk/:rw \
  ghcr.io/zaproxy/zaproxy:stable \
  zap-api-scan.py \
  -t "/zap/wrk/$API_FILE" \
  -f openapi \
  -r zap-api-report.html \
  -J zap-api-report.json

echo "[+] Relatório: $REPORT_DIR/zap-api-report.html"
WRAPPER
chmod +x /usr/local/bin/zap-api

# --- 7. SONAR-SCAN WRAPPER ---
echo "[*] Instalando wrapper sonar-scan..."
cat > /usr/local/bin/sonar-scan << 'WRAPPER'
#!/bin/bash
set -e
SONAR_TOKEN="${SONAR_TOKEN:-}"
SONAR_URL="${SONAR_URL:-http://localhost:9000}"

if [ -z "$SONAR_TOKEN" ]; then
  echo "[!] SONAR_TOKEN não definido. Exporte-o primeiro: export SONAR_TOKEN=sqp_..."
  exit 1
fi

docker run --rm \
  --network="host" \
  -e SONAR_HOST_URL="$SONAR_URL" \
  -e SONAR_TOKEN="$SONAR_TOKEN" \
  -v "$(pwd)":/usr/src \
  sonarsource/sonar-scanner-cli:latest

echo "[+] Análise concluída. Dashboard: $SONAR_URL"
WRAPPER
chmod +x /usr/local/bin/sonar-scan

# --- 8. PRE-PULL DOCKER IMAGES (parallel) ---
echo "[*] Baixando imagens das ferramentas em paralelo..."
docker pull sonarqube:community &
docker pull postgres:16 &
docker pull owasp/dependency-check:latest &
docker pull ghcr.io/zaproxy/zaproxy:stable &
docker pull sonarsource/sonar-scanner-cli:latest &
docker pull node:current-alpine &
wait
echo "[+] Todas as imagens baixadas."

# --- 9. FINAL ACCESS INSTRUCTIONS ---
echo "[*] Salvando instruções em CI-ACCESS.txt..."
cat > /home/ubuntu/CI-ACCESS.txt << EOF
=== Instância CI Security — Instruções de Acesso ===

Todos os serviços CI estão vinculados a 127.0.0.1. Apenas SSH (porta 22) é público.

Tunnel SonarQube:
  ssh -N -L 9000:localhost:9000 -i ~/.ssh/oci_vps_key ubuntu@$(curl -s ifconfig.me)
  Depois abra: http://localhost:9000  (admin/admin no primeiro login — altere imediatamente)

Executar Dependency-Check em um projeto:
  scp -r ./meuprojeto ubuntu@$(curl -s ifconfig.me):/home/ubuntu/
  ssh -i ~/.ssh/oci_vps_key ubuntu@$(curl -s ifconfig.me)
  cd /home/ubuntu/meuprojeto && dep-check

Executar scan baseline do ZAP:
  zap-baseline http://localhost:<PORTA_APP>

Executar scanner SonarQube:
  export SONAR_TOKEN=sqp_...
  sonar-scan

Caminhos:
  Dados SonarQube:   /opt/ci-security/sonarqube/ (volumes Docker)
  Cache NVD:         /opt/ci-security/dependency-check/data/  (~2 GB, construído na primeira execução)
  Relatórios ZAP:    ./security-reports/zap/
EOF

echo -e "\n--------------------------------------------------------"
cat /home/ubuntu/CI-ACCESS.txt
echo "--------------------------------------------------------"
echo " CONFIGURAÇÃO DAS FERRAMENTAS CI CONCLUÍDA! "
echo "--------------------------------------------------------"
