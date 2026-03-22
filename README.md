<p align="center">
  <img src="assets/logo.png" alt="OCI SecOps Logo" width="260"/>
  <br/>
  <h1 align="center" style="font-size: 3em;">OCI SecOps</h1>
</p>

Conjunto de scripts para provisionar, auditar e gerenciar instâncias na **Oracle Cloud Infrastructure (OCI)**, maximizando os recursos do *Always Free Tier* (Arquitetura ARM Ampere A1). O projeto automatiza o ciclo de vida completo de ambientes voltados para **Segurança Ofensiva (Bug Bounty / Pentest)** e **Segurança Defensiva (CI/CD AppSec)**.

## Arquiteturas de Implantação Suportadas

O orquestrador pode provisionar o limite *Always Free* em diferentes topologias:

| Opção | Topologia | Recursos | Uso Ideal |
|-------|-----------|----------|-----------|
| 1 | Instância Única Potente | 4 OCPU / 24GB RAM | Automações pesadas, força bruta |
| 2 | Par Balanceado | 2× (2 OCPU / 12GB RAM) | Divisão de escopos de scan |
| 3 | Cluster Pequeno | 4× (1 OCPU / 6GB RAM) | Arquitetura mestre/nó, evasão de bloqueios IP |
| 4 | Instância Simples | 1 OCPU / 6GB RAM | Testes rápidos e isolados |
| 5 | CI Security | 4 OCPU / 24GB RAM | Pipeline SAST/DAST/SCA completo |

---

## Componentes do Projeto

### Orquestração & Ciclo de Vida

- **`oci_provision.sh`** — Orquestrador principal. Mapeia Tenant, Compartments, VCNs e Imagens; verifica limites de armazenamento Always Free antes do deploy; injeta os scripts de pós-configuração corretos conforme o perfil escolhido; aguarda o boot e executa a instalação remotamente via SSH.

- **`oci_inventory.sh`** — Audita o consumo do teto *Always Free* (OCPUs, RAM, Discos) em todos os compartimentos recursivamente, informando o que está ativo, parado ou consumindo limite indevidamente.

- **`oci_teardown.sh`** — Encerra instâncias e destrói volumes de boot associados, evitando faturamentos e discos em estado fantasma após o fim de testes.

- **`oci_dashboard.sh`** — Painel de monitoramento em tempo real. Exibe estado, IP público e recursos de todas as instâncias, com atualização automática a cada 15 segundos.

### Hardening (Cloud-Init)

- **`harden.sh`** — Injetado via `cloud-init` nas instâncias de pentest. Aplica tuning de kernel (`sysctl`: TCP SYN Flood, IP Spoofing), desativa autenticação por senha no SSH, restringe portas via UFW, configura Fail2Ban e cria swap dinâmico de 4GB.

- **`harden_ci.sh`** — Variação do hardening para instâncias CI. Inclui instalação do Docker Engine e ajustes adicionais de `sysctl` exigidos pelo Elasticsearch interno do SonarQube (`vm.max_map_count`).

### Toolchains Pós-Deploy

- **`pentest_arsenal.sh`** — Instala o ecossistema ofensivo completo na instância endurecida: Golang nativo ARM64, arsenal de reconhecimento web (Subfinder, Httpx, Nuclei, Ffuf, etc.), ferramentas de infra pentest (Impacket, NetExec, Certipy, Sliver C2, Metasploit, Ligolo-ng) e interface gráfica XFCE + VNC (opcional via `--vnc`).

  Perfis disponíveis: `--web`, `--infra`, `--full` (padrão), `--vnc`.

- **`setup_ci.sh`** — Exclusivo para o perfil CI Security. Implanta a tríade AppSec em containers Docker:
  - **SonarQube Community** + PostgreSQL (acesso via SSH tunnel na porta 9000)
  - **OWASP ZAP** (wrappers `zap-baseline` e `zap-api` para scans DAST)
  - **OWASP Dependency-Check** (wrapper `dep-check` para análise SCA com cache NVD pré-populado)

---

## Pré-requisitos

- Linux nativo ou WSL2
- [OCI CLI](https://docs.oracle.com/en-us/iaas/Content/API/SDKDocs/cliinstall.htm) instalada e configurada (`~/.oci/config`)
- Par de chaves SSH salvo em `~/.ssh/oci_vps_key` e `~/.ssh/oci_vps_key.pub`
- `jq` instalado localmente

## Configuração

### `.env` — credenciais de provisionamento

Obrigatório antes do primeiro uso. Contém as credenciais injetadas nas instâncias durante o deploy:

```bash
cp .env.example .env
# edite .env com os valores desejados
```

| Variável | Descrição |
|----------|-----------|
| `NVD_API_KEY` | Chave da API do NVD para o OWASP Dependency-Check. Obtenha gratuitamente em [nvd.nist.gov/developers/request-an-api-key](https://nvd.nist.gov/developers/request-an-api-key) |
| `VNC_PASSWORD` | Senha do servidor VNC (perfil `--vnc`) |
| `SONAR_DB_PASSWORD` | Senha do banco PostgreSQL interno do SonarQube |

### `.env.ci` — token do SonarQube (pós-deploy)

Após o deploy da instância CI e o primeiro login no SonarQube (`http://localhost:9000` via SSH tunnel), gere um token de usuário e exporte-o antes de rodar o scanner:

```bash
# na instância CI, ou localmente via tunnel
export SONAR_TOKEN=sqp_...
sonar-scan
```

Opcionalmente, salve em `.env.ci` para reutilizar entre sessões — o arquivo já está no `.gitignore`:

```bash
echo "SONAR_TOKEN=sqp_..." > .env.ci
source .env.ci && sonar-scan
```

## Uso

```bash
cd scripts/
chmod +x *.sh
./oci_provision.sh
```

O orquestrador guia interativamente pelo provisionamento. Ao final, exibe o comando SSH de acesso a cada instância criada.

### Utilitários independentes

```bash
# Inventário de recursos Always Free
./oci_inventory.sh

# Painel de monitoramento ao vivo
./oci_dashboard.sh

# Encerrar instâncias
./oci_teardown.sh
```
