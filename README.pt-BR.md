[English](README.md) | Português (BR)

[![Kubernetes](https://img.shields.io/badge/Kubernetes-v1.32.0-326ce5?logo=kubernetes&logoColor=white)](https://kubernetes.io/)
[![Rancher](https://img.shields.io/badge/Rancher-v2.13.x-0075a1?logo=rancher&logoColor=white)](https://rancher.com/)
[![Gateway API](https://img.shields.io/badge/Gateway_API-v1.1.0-blue?logo=kubernetes&logoColor=white)](https://gateway-api.sigs.k8s.io/)
[![Kind](https://img.shields.io/badge/Kind-v0.29.0-326ce5?logo=kubernetes&logoColor=white)](https://kind.sigs.k8s.io/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Shell](https://img.shields.io/badge/Shell-Bash-4EAA25?logo=gnu-bash&logoColor=white)](https://www.gnu.org/software/bash/)
[![Linux](https://img.shields.io/badge/Platform-Linux-FCC624?logo=linux&logoColor=black)](https://www.kernel.org/)

---

# k8s-lab-platform

Configuração automatizada de um ambiente Kubernetes local para desenvolvimento,
utilizando Kind, NGINX Gateway Fabric, cert-manager e Rancher.

> **Destinado a ambientes de desenvolvimento, testes, treinamentos e POCs.
> Não recomendado para uso em produção.**

## Visão Geral

O `k8s-lab-platform` evoluiu a partir de scripts e experimentos arquiteturais
desenvolvidos ao longo do tempo, sendo gradualmente refinado com foco em
segurança, confiabilidade e adoção do modelo moderno baseado em Gateway API.

> Parte das melhorias desta versão contou com o apoio de ferramentas de IA,
> utilizadas como assistência de engenharia ao longo da evolução do projeto.

## Funcionalidades

- **Toolchain Automatizada**: Instalação e configuração de Docker, Kind, Helm, kubectl e Rancher CLI.
- **Orquestração de Cluster**: Criação de clusters Kubernetes multi-node configuráveis via Kind (control-plane + N workers).
- **Ingress e Networking**: Gateway API (canal standard) com NGINX Gateway Fabric (NGF) via NodePort.
- **Gerenciamento de Certificados**: Integração completa com cert-manager e CA local gerada via OpenSSL para endpoints HTTPS seguros.
- **Interface de Gerenciamento**: Instalação e configuração automatizada do Rancher Server.
- **Logging estruturado**: quatro níveis de log (DEBUG, INFO, WARNING, ERROR), com timestamps, saída colorida e persistência em arquivo.
- **Mecanismos de Segurança**: Sem senhas hardcoded — geradas via `/dev/urandom` e armazenadas com `chmod 600`.
- **Sistema de Rollback**: Rastreia etapas de instalação concluídas e as desfaz automaticamente em caso de falha.
- **Verificações Pré-instalação**: Validação de compatibilidade do sistema (RAM, CPU, Disco, portas, rede, distro Linux).
- **Verificação Pós-instalação**: Health checks automatizados para todos os componentes implantados (`verify_installation`).
- **Modo Dry-run**: Visualize todos os comandos sem executá-los (`DRY_RUN=true`).
- **Modo Não-interativo**: Suporte completo a CI/CD com senhas geradas automaticamente e sem prompts.

## Tecnologias Utilizadas

| Camada | Tecnologia |
|---|---|
| Scripting | Bash (`set -euo pipefail`) |
| Containerização | Docker |
| Distribuição Kubernetes | Kind (Kubernetes in Docker) |
| Gerenciamento de Pacotes | Helm |
| Ingress / Networking | NGINX Gateway Fabric + Gateway API |
| Gerenciamento de Certificados | cert-manager + CA local (OpenSSL) |
| Plataforma de Gerenciamento | Rancher Server |
| Monitoramento (opcional) | Prometheus + Grafana (via Rancher Monitoring) |
| Métricas (opcional) | Kubernetes Metrics Server |

## Arquitetura

O script foi estruturado de forma modular. A função `main()` interpreta os argumentos e orquestra funções independentes, cada uma responsável por um componente específico.

### Fluxo de Instalação

```
Verificações do Sistema → Docker → sysctl → kubectl → Helm → Kind
    → Certificados CA → Cluster Kind → Gateway API/NGF → cert-manager
    → CA Issuer → Rancher Server → /etc/hosts
    → [Opcional] Rancher CLI → [Opcional] Monitoramento → [Opcional] Metrics Server
```

### Estrutura de Diretórios

```text
.
├── setup-kind-cluster.sh       # Script principal de automação (~2.600 linhas)
├── README.md                   # Documentação em Inglês
├── README.pt-BR.md             # Documentação em Português
├── GATEWAY_API_GUIDE.md        # Guia de uso do Gateway API (EN)
├── GATEWAY_API_GUIDE.pt-BR.md  # Guia de uso do Gateway API (PT-BR)
└── .gitignore                  # Regras de exclusão do Git
```

## Pré-requisitos

- **Sistema Operacional**: Linux (Ubuntu 22.04+, Debian, CentOS, RHEL, Fedora, Rocky Linux, AlmaLinux).
- **Permissões**: Privilégios de `sudo` para gerenciamento de pacotes e configuração do sistema.
- **Hardware Mínimo**:
  - CPU: 2 cores
  - RAM: 4 GB
  - Disco: 20 GB disponíveis
- **Rede**: Acesso à internet para Docker Hub, GitHub e repositórios de charts Helm.

## Instalação

```bash
# 1. Clone o repositório
git clone <url-do-repositório>
cd k8s-lab-platform

# 2. Conceda permissões de execução
chmod +x setup-kind-cluster.sh

# 3. Execute o menu interativo
./setup-kind-cluster.sh

# OU execute uma instalação completa não-interativa
./setup-kind-cluster.sh install-all
```

## Configuração

Todas as configurações podem ser sobrescritas via variáveis de ambiente.

### Configurações Principais

| Variável | Descrição | Padrão |
|---|---|---|
| `CLUSTER_NAME` | Nome do cluster Kind | `k8s-cluster` |
| `CLUSTER_DOMAIN` | Domínio base para serviços | `cluster.test` |
| `RANCHER_PASSWORD` | Senha do admin do Rancher (gerada automaticamente se vazia) | `""` |
| `WORKER_NODES` | Número de nós workers | `2` |
| `DISABLE_IPV6` | Desabilitar IPv6 para compatibilidade com Kind | `true` |

### Flags de Execução

| Variável | Descrição | Padrão |
|---|---|---|
| `NON_INTERACTIVE` | Ignorar todos os prompts (modo CI/CD) | `false` |
| `VERBOSE` | Habilitar saída de nível DEBUG | `false` |
| `LOG_LEVEL` | Verbosidade do log: 0=DEBUG, 1=INFO, 2=WARNING, 3=ERROR | `1` |
| `DRY_RUN` | Exibir comandos sem executar | `false` |
| `FORCE_REINSTALL` | Forçar reinstalação de ferramentas já instaladas | `false` |
| `SKIP_PREREQS` | Ignorar verificação de requisitos do sistema | `false` |
| `ROLLBACK_ENABLED` | Rollback automático em caso de falha | `true` |

### Configurações de Timeout

| Variável | Descrição | Padrão |
|---|---|---|
| `CLUSTER_START_TIMEOUT` | Segundos para aguardar inicialização do cluster | `120` |
| `CERTIFICATE_TIMEOUT` | Segundos para aguardar emissão de certificado | `300` |
| `HELM_INSTALL_TIMEOUT` | Segundos para instalações de charts Helm | `600` |
| `KUBECTL_WAIT_TIMEOUT` | Segundos para comandos `kubectl wait` | `300` |

### Versões das Ferramentas (configuráveis)

| Variável | Padrão |
|---|---|
| `KIND_VERSION` | `v0.29.0` |
| `KUBERNETES_VERSION` | `v1.32.0` |
| `KUBECTL_VERSION` | `v1.32.0` |
| `RANCHER_CLI_VERSION` | `v2.11.3` |
| `RANCHER_VERSION` | `2.13.x` |
| `CERT_MANAGER_CHART_VERSION` | `v1.15.0` |
| `GATEWAY_API_VERSION` | `v1.1.0` |
| `NGF_VERSION` | `1.3.0` |

## Uso

### Menu Interativo

Execute sem argumentos para acessar o menu interativo completo (28 opções):

```bash
./setup-kind-cluster.sh
```

### Comandos CLI

```bash
# Instalar apenas infraestrutura (ferramentas + cluster, etapas 1-8)
./setup-kind-cluster.sh install-infra

# Instalar apenas plataforma (Gateway, cert-manager, Rancher, etapas 9-13)
./setup-kind-cluster.sh install-platform

# Instalação completa (etapas 1-13)
./setup-kind-cluster.sh install-all

# Instalação completa com stack de monitoramento
./setup-kind-cluster.sh install-full

# Instalação individual de componentes
./setup-kind-cluster.sh install-docker
./setup-kind-cluster.sh install-kubectl
./setup-kind-cluster.sh install-helm
./setup-kind-cluster.sh install-kind
./setup-kind-cluster.sh install-rancher-cli
./setup-kind-cluster.sh create-cluster
./setup-kind-cluster.sh install-gateway-api
./setup-kind-cluster.sh install-cert-manager
./setup-kind-cluster.sh install-rancher
./setup-kind-cluster.sh install-monitoring
./setup-kind-cluster.sh install-metrics

# Ciclo de vida do cluster
./setup-kind-cluster.sh start-cluster
./setup-kind-cluster.sh stop-cluster
./setup-kind-cluster.sh remove-cluster

# Utilitários
./setup-kind-cluster.sh status       # Exibir status do cluster
./setup-kind-cluster.sh verify       # Health check pós-instalação
./setup-kind-cluster.sh rollback     # Desfazer etapas de instalação concluídas
./setup-kind-cluster.sh cleanup      # Remover arquivos locais gerados e logs
```

### Opções CLI

```
-h, --help              Exibir mensagem de ajuda
-v, --version           Exibir versão
--verbose               Habilitar saída verbose/debug
--non-interactive       Executar sem prompts
--dry-run               Exibir comandos sem executar
--force-reinstall       Forçar reinstalação de ferramentas existentes
--skip-prereqs          Ignorar verificação de requisitos do sistema
--cluster-name NAME     Definir nome do cluster
--cluster-domain DOMAIN Definir domínio do cluster
--worker-nodes N        Definir número de nós workers
--no-rollback           Desabilitar rollback automático em caso de falha
```

### Exemplos de Uso

```bash
# Instalação completa não-interativa com nome de cluster personalizado
./setup-kind-cluster.sh --non-interactive --cluster-name dev-env install-all

# Dry-run para visualizar todos os comandos
./setup-kind-cluster.sh --dry-run install-all

# Instalar com 3 nós workers e monitoramento
WORKER_NODES=3 ./setup-kind-cluster.sh install-full

# Definir senha do Rancher via variável de ambiente
RANCHER_PASSWORD="MinhaSenhaSegura123" ./setup-kind-cluster.sh install-rancher

# Uso em pipeline CI/CD
NON_INTERACTIVE=true ROLLBACK_ENABLED=true ./setup-kind-cluster.sh install-all
```

## Resolução de DNS Local (`/etc/hosts`)

Este script utiliza `/etc/hosts` para resolução de DNS local. A etapa 14 adiciona automaticamente uma entrada para o Rancher:

```
127.0.0.1   rancher.cluster.test
```

> [!IMPORTANT]
> **Cada nova aplicação exposta via Gateway API ou Ingress requer sua própria entrada no `/etc/hosts`.**
> Não há resolução DNS wildcard com esta abordagem — cada hostname deve ser registrado individualmente.

### Adicionando entradas para novas aplicações

Edite o `/etc/hosts` (requer `sudo`) e adicione uma linha por aplicação:

```
# Kind cluster — entradas DNS locais
127.0.0.1   rancher.cluster.test
127.0.0.1   grafana.cluster.test
127.0.0.1   prometheus.cluster.test
127.0.0.1   minha-app.cluster.test
```

Em seguida, acesse a aplicação em `https://grafana.cluster.test` (as portas 80/443 são gerenciadas pelo NGINX Gateway Fabric).

> [!TIP]
> **Melhoria futura:** Substitua o `/etc/hosts` pelo [dnsmasq](https://thekelleys.org.uk/dnsmasq/doc.html) para habilitar resolução wildcard (`*.cluster.test → 127.0.0.1`) e eliminar a necessidade de adicionar entradas manualmente. Esta é a abordagem utilizada por ferramentas como Rancher Desktop e k3d.

## Verificação pós-instalação

O comando `verify` executa `verify_installation()` que verifica:

1. Conectividade da API do Kubernetes (`kubectl cluster-info`)
2. Status dos nós (todos em estado `Ready`)
3. Saúde dos pods em `kube-system`
4. Prontidão do deployment do NGINX Gateway Fabric
5. Existência dos recursos GatewayClass e Gateway
6. Prontidão do deployment do cert-manager
7. Prontidão do deployment do Rancher Server e acessibilidade da UI

```bash
./setup-kind-cluster.sh verify
```

## Decisões Técnicas

| Decisão | Justificativa |
|---|---|
| **Gateway API + NGF** | Adota Gateway API com NGINX Gateway Fabric em vez do NGINX Ingress Controller tradicional, permitindo melhor separação de responsabilidades e maior flexibilidade de roteamento. |
| **NodePort + extraPortMappings** | Kind mapeia as portas do host 80/443 para as portas do container 30080/30443 via `extraPortMappings`, então o NGF usa o tipo de serviço NodePort |
| **`externalTrafficPolicy: Cluster`** | Garante que o encaminhamento de tráfego entre nós funcione corretamente em setups multi-nó do Kind onde as portas estão mapeadas apenas para o nó de controle |
| **Header X-Forwarded-Proto** | Injetado explicitamente no HTTPRoute para evitar loops de redirecionamento do Rancher quando o TLS é terminado no Gateway |
| **Fallback para Localhost no HTTPRoute** | Permite troubleshooting estável via `kubectl port-forward` sem modificar `/etc/hosts` |
| **Versão fixada do Rancher** | Utiliza `2.13.x` (semver range) para garantir estabilidade permitindo atualizações de patch críticas |
| **`set -euo pipefail`** | O script encerra imediatamente em qualquer erro ou variável indefinida, evitando estados inconsistentes |
| **Funções Modulares** | Cada componente é isolado em uma função para permitir execução passo a passo ou em lote |
| **Detecção Multi-método de Portas** | Usa `nc`, `ss`, `netstat` e `lsof` para detectar conflitos de porta em diferentes ambientes Linux |
| **Sem Senhas Hardcoded** | Senhas geradas via `/dev/urandom`, armazenadas com `chmod 600`, ou solicitadas interativamente |
| **Rollback LIFO** | Etapas de instalação rastreadas em array; rollback processa em ordem reversa (Last-In, First-Out) |
| **CA RSA 2048** | Escolhido em vez de RSA 4096 para melhor desempenho em ambientes de desenvolvimento local |
| **IPv6 desabilitado por padrão** | Clusters Kind podem ter problemas de rede com IPv6 em alguns ambientes; configurável via `DISABLE_IPV6` |

## Notas de Segurança

- Senhas nunca são hardcoded. São geradas via `/dev/urandom` ou solicitadas interativamente.
- Arquivos de senha gerados são armazenados com `chmod 600` (leitura/escrita apenas pelo proprietário).
- Chaves privadas CA são armazenadas com `chmod 600`.
- Executar como root aciona um aviso e requer confirmação explícita.
- Configurações inseguras (ex: `--kubelet-insecure-tls` para Metrics Server) são explicitamente documentadas como apenas para desenvolvimento.
- Este script **não é destinado a uso em produção**.

## Contribuição

1. Realize o Fork do projeto.
2. Crie uma branch para sua funcionalidade (`git checkout -b feature/MinhaFuncionalidade`).
3. Comite suas alterações (`git commit -m 'Adiciona MinhaFuncionalidade'`).
4. Realize o Push para a branch (`git push origin feature/MinhaFuncionalidade`).
5. Abra um Pull Request.

---

## Licença

Este projeto está licenciado sob a [Licença MIT](LICENSE).