<p align="center">
  <img src="assets/logo.png" alt="OCI SecOps Logo" width="260"/>
  <br/>
  <h1 align="center" style="font-size: 3em;">OCI SecOps</h1>
</p>

Conjunto de scripts para provisionar, auditar e gerenciar instâncias na **Oracle Cloud Infrastructure (OCI)**, maximizando os recursos do *Always Free Tier* (Arquitetura ARM Ampere A1). O projeto automatiza o ciclo de vida completo de ambientes voltados para **Segurança Ofensiva (Bug Bounty / Pentest)** e **Segurança Defensiva (CI/CD AppSec)**.

## Arquiteturas de Implantação Suportadas

O orquestrador pode provisionar o limite *Always Free* em diferentes topologias:

| Opção | Topologia | Recursos | Uso Ideal |
|--------|----------|-----------|-----------|
| 1 | Full Power | 4 OCPU / 24GB RAM | Automações pesadas, força bruta |
| 2 | Balanced Pair | 2× (2 OCPU / 12GB RAM) | Divisão de escopos de scan |
| 3 | Small Cluster | 4× (1 OCPU / 6GB RAM) | Arquitetura mestre/nó, evasão de bloqueios IP |
| 4 | Single Instance | 1 OCPU / 6GB RAM | Testes rápidos e isolados |
| 5 | CI Security | 4 OCPU / 24GB RAM | Pipeline SAST/DAST/SCA completo |
| 6 | **Limited Full Power** | Detectado automaticamente | Cotas reduzidas por região |

> **Sobre a opção 6.** A Oracle documenta 4 OCPU / 24GB como o teto Always Free do Ampere A1, mas o limite efetivo é definido **por tenancy e por região** — contas em regiões com alta demanda costumam receber metade disso, sem aviso. A opção 6 consulta sua cota real via API no momento da execução e dimensiona uma instância única com o máximo que ela permite, incluindo o boot volume. Se seu limite for elevado depois, ela acompanha sozinha.

---

## Conformidade Always Free

O provisionador aplica os tetos do Always Free localmente, em **todas** as estratégias — não apenas na opção 6.

Isso é necessário porque a cota da tenancy não é uma rede de segurança confiável. Numa conta **Free Tier**, exceder o allotment é rejeitado pela API (`LimitExceeded`) — falha segura. Numa conta **Pay As You Go**, o mesmo lançamento é aceito e **faturado**. A OCI não expõe via API qual é o caso da conta, então o script não delega essa decisão.

| Camada | Momento | Proteção |
|--------|---------|----------|
| `check_free_tier_budget()` | Antes de qualquer launch | Soma o que já está em uso ao que será criado e bloqueia se exceder 4 OCPU / 24GB / 200GB, ou se a cota da tenancy for insuficiente. Exibe o balanço e exige confirmação explícita. |
| Guarda por instância | Dentro de `launch_vps()` | Nenhuma instância isolada ultrapassa o teto, seja qual for o chamador. |
| Parâmetros fixos | No comando de launch | Shape `VM.Standard.A1.Flex` e boot volume em VPU 10 (*Balanced*) explícitos, sem depender de defaults da CLI. |

As estratégias que lançam em paralelo (opções 2 e 3) agora são bloqueadas **antes da primeira instância subir** quando a cota não comporta o total — evitando o deploy parcial que deixava metade do cluster de pé.

---

## Componentes do Projeto

### Orquestração & Ciclo de Vida

- **`oci_provision.sh`** — Orquestrador principal. Mapeia Tenant, Compartments, VCNs e Imagens; detecta a cota Ampere A1 real da tenancy via API; aplica os guard-rails de Always Free antes do deploy; injeta os scripts de pós-configuração corretos conforme o perfil escolhido; aguarda o boot e executa a instalação remotamente via SSH.

- **`oci_inventory.sh`** — Audita o consumo do teto *Always Free* (OCPUs, RAM, Discos) em todos os compartimentos recursivamente. Confronta o uso real com **duas** referências — a cota efetiva da tenancy e o teto Always Free — e informa a margem exata disponível para o próximo provisionamento. Alerta quando a cota excede o Always Free (contas *Pay As You Go*, onde o excedente é faturado) e quando a varredura diverge da contabilidade da API, sinal de compartimentos sem permissão de leitura.

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

---

## Solução de Problemas

### `LimitExceeded` no provisionamento

```
"code": "LimitExceeded",
"message": "The following service limits were exceeded: standard-a1-core-count, ..."
```

Sua cota A1 é menor que a estratégia escolhida. **Não é erro de autenticação** — a chamada foi autenticada e autorizada normalmente; a API recusou por cota. Consulte seu limite real:

```bash
oci limits resource-availability get \
  --service-name compute \
  --limit-name standard-a1-core-count \
  --compartment-id <tenancy-ocid> \
  --availability-domain <seu-AD>
```

Troque `standard-a1-core-count` por `standard-a1-memory-count` para a RAM. A **opção 6** se ajusta a esses valores automaticamente.

Para tentar elevar o limite: Console → *Governance & Administration* → *Limits, Quotas and Usage* → `standard-a1-core-count` → *Request a service limit increase*. O pedido é gratuito, mas em regiões sob pressão de capacidade pode ser negado justamente pelo motivo que causou o corte.

### `TooManyRequests` (HTTP 429)

```
"code": "TooManyRequests",
"message": "Too many requests for the user"
```

Rate limit da API. A OCI limita chamadas de `launch_instance` por usuário, e tentativas seguidas — inclusive as que falharam por outros motivos — contam para o limite. O `launch_vps()` trata esse caso com **backoff exponencial** (60s → 120s → 240s → 480s → 600s, até 6 tentativas), separado do retry de capacidade, que usa intervalo fixo.

Se o limite persistir depois disso, aguarde ~15 minutos **sem novas tentativas** antes de executar de novo — cada tentativa durante o bloqueio renova a contagem.

### `Out of host capacity`

Não há hardware A1 livre na região no momento — situação diferente de cota. O `launch_vps()` já faz retry automático (20 tentativas × 60s). Horários de menor demanda, como a madrugada UTC, aumentam a chance de sucesso.

### Shape indisponível na região

Regiões mais recentes podem não oferecer todo o catálogo Always Free. Vale conferir o que existe de fato antes de assumir a tabela oficial:

```bash
oci compute shape list --compartment-id <tenancy-ocid> --all \
  | jq -r '[.data[].shape] | unique | .[]'
```

É comum uma cota aparecer preenchida (por exemplo `vm-standard-e2-1-micro-count = 2`) sem que o shape correspondente exista na região — cota no papel, sem hardware para executá-la.
