English | [Português (BR)](README.pt-BR.md)

[![Kubernetes](https://img.shields.io/badge/Kubernetes-v1.32.0-326ce5?logo=kubernetes&logoColor=white)](https://kubernetes.io/)
[![Rancher](https://img.shields.io/badge/Rancher-v2.13.x-0075a1?logo=rancher&logoColor=white)](https://rancher.com/)
[![Gateway API](https://img.shields.io/badge/Gateway_API-v1.1.0-blue?logo=kubernetes&logoColor=white)](https://gateway-api.sigs.k8s.io/)
[![Kind](https://img.shields.io/badge/Kind-v0.29.0-326ce5?logo=kubernetes&logoColor=white)](https://kind.sigs.k8s.io/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Shell](https://img.shields.io/badge/Shell-Bash-4EAA25?logo=gnu-bash&logoColor=white)](https://www.gnu.org/software/bash/)
[![Linux](https://img.shields.io/badge/Platform-Linux-FCC624?logo=linux&logoColor=black)](https://www.kernel.org/)

---

# k8s-lab-platform

Automated setup for a local Kubernetes development environment using Kind,
NGINX Gateway Fabric, cert-manager, and Rancher.

> **Intended for development, testing, training, and POC environments.
> Not recommended for production use.**

## Overview

`k8s-lab-platform` evolved from a set of laboratory scripts and architectural
experiments developed over time, gradually refined with a focus on security,
reliability, and adoption of the modern Gateway API model.

> Some improvements in this version were developed with the support of AI tools,
> used as engineering assistance during the project’s evolution.

## Features

- **Automated Toolchain**: Installation and configuration of Docker, Kind, Helm, kubectl, and Rancher CLI.
- **Cluster Orchestration**: Creation of configurable multi-node Kubernetes clusters via Kind (control-plane + N workers).
- **Ingress & Networking**: Gateway API (standard channel) with NGINX Gateway Fabric (NGF) via NodePort.
- **Certificate Management**: Full cert-manager integration with a locally generated CA for secure HTTPS endpoints.
- **Management UI**: Automated installation and configuration of Rancher Server.
- **Structured logging**: four log levels (DEBUG, INFO, WARNING, ERROR) with timestamps, color output, and file persistence.
- **Security mechanisms**: no hardcoded passwords — generated via `/dev/urandom` and stored with `chmod 600`.
- **Rollback system**: tracks completed installation steps and automatically reverts them on failure.
- **Pre-flight checks**: system compatibility validation (RAM, CPU, disk, ports, network, Linux distribution).
- **Post-installation verification**: automated health checks for deployed components (`verify_installation`).
- **Dry-run mode**: preview commands without execution (`DRY_RUN=true`).
- **Non-interactive mode**: full CI/CD support with auto-generated passwords and no prompts.

## Tech Stack

| Layer | Technology |
|---|---|
| Scripting | Bash (`set -euo pipefail`) |
| Containerization | Docker |
| Kubernetes Distribution | Kind (Kubernetes in Docker) |
| Package Management | Helm |
| Ingress / Networking | NGINX Gateway Fabric + Gateway API |
| Certificate Management | cert-manager + local CA (OpenSSL) |
| Management Platform | Rancher Server |
| Monitoring (optional) | Prometheus + Grafana (via Rancher Monitoring) |
| Metrics (optional) | Kubernetes Metrics Server |

## Architecture

The script was structured in a modular way. The `main()` function parses
arguments and orchestrates independent functions, each responsible for
a specific component.

### Installation Flow

```
System Checks → Docker → sysctl → kubectl → Helm → Kind → Rancher CLI
    → CA Certs → Kind Cluster → Gateway API/NGF → cert-manager
    → CA Issuer → Rancher Server → /etc/hosts
    → [Optional] Monitoring → [Optional] Metrics Server
```

### Directory Structure

```text
.
├── setup-kind-cluster.sh       # Main automation script (~2,600 lines)
├── README.md                   # English documentation
├── README.pt-BR.md             # Portuguese documentation
├── GATEWAY_API_GUIDE.md        # Gateway API usage guide (EN)
├── GATEWAY_API_GUIDE.pt-BR.md  # Gateway API usage guide (PT-BR)
└── .gitignore                  # Git exclusion rules
```

## Prerequisites

- **Host OS**: Linux (Ubuntu 22.04+, Debian, CentOS, RHEL, Fedora, Rocky Linux, AlmaLinux).
- **Permissions**: `sudo` privileges for package management and system configuration.
- **Minimum Hardware**:
  - CPU: 2 cores
  - RAM: 4 GB
  - Disk: 20 GB available
- **Network**: Internet access to reach Docker Hub, GitHub, and Helm chart repositories.

## Installation

```bash
# 1. Clone the repository
git clone <repository-url>
cd k8s-lab-platform

# 2. Grant execution permissions
chmod +x setup-kind-cluster.sh

# 3. Run the interactive menu
./setup-kind-cluster.sh

# OR run a full non-interactive installation
./setup-kind-cluster.sh install-all
```

## Configuration

All settings can be overridden via environment variables.

### Core Settings

| Variable | Description | Default |
|---|---|---|
| `CLUSTER_NAME` | Kind cluster name | `k8s-cluster` |
| `CLUSTER_DOMAIN` | Base domain for services | `cluster.test` |
| `RANCHER_PASSWORD` | Rancher admin password (auto-generated if empty) | `""` |
| `WORKER_NODES` | Number of worker nodes | `2` |
| `DISABLE_IPV6` | Disable IPv6 for Kind compatibility | `true` |

### Runtime Flags

| Variable | Description | Default |
|---|---|---|
| `NON_INTERACTIVE` | Skip all prompts (CI/CD mode) | `false` |
| `VERBOSE` | Enable DEBUG-level output | `false` |
| `LOG_LEVEL` | Log verbosity: 0=DEBUG, 1=INFO, 2=WARNING, 3=ERROR | `1` |
| `DRY_RUN` | Print commands without executing | `false` |
| `FORCE_REINSTALL` | Reinstall already-installed tools | `false` |
| `SKIP_PREREQS` | Skip system requirements check | `false` |
| `ROLLBACK_ENABLED` | Auto-rollback on failure | `true` |

### Timeout Settings

| Variable | Description | Default |
|---|---|---|
| `CLUSTER_START_TIMEOUT` | Seconds to wait for cluster startup | `120` |
| `CERTIFICATE_TIMEOUT` | Seconds to wait for certificate issuance | `300` |
| `HELM_INSTALL_TIMEOUT` | Seconds for Helm chart installations | `600` |
| `KUBECTL_WAIT_TIMEOUT` | Seconds for `kubectl wait` commands | `300` |

### Tool Versions (configurable)

| Variable | Default |
|---|---|
| `KIND_VERSION` | `v0.29.0` |
| `KUBERNETES_VERSION` | `v1.32.0` |
| `KUBECTL_VERSION` | `v1.32.0` |
| `RANCHER_CLI_VERSION` | `v2.11.3` |
| `RANCHER_VERSION` | `2.13.x` |
| `CERT_MANAGER_CHART_VERSION` | `v1.15.0` |
| `GATEWAY_API_VERSION` | `v1.1.0` |
| `NGF_VERSION` | `1.3.0` |

## Usage

### Interactive Menu

Run without arguments to access the full interactive menu (28 options):

```bash
./setup-kind-cluster.sh
```

### CLI Commands

```bash
# Install only infrastructure (tools + cluster, steps 1-9)
./setup-kind-cluster.sh install-infra

# Install only platform (Gateway, cert-manager, Rancher, steps 10-14)
./setup-kind-cluster.sh install-platform

# Full installation (steps 1-14)
./setup-kind-cluster.sh install-all

# Full installation with monitoring stack
./setup-kind-cluster.sh install-full

# Individual component installation
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

# Cluster lifecycle
./setup-kind-cluster.sh start-cluster
./setup-kind-cluster.sh stop-cluster
./setup-kind-cluster.sh remove-cluster

# Utilities
./setup-kind-cluster.sh status       # Show cluster status
./setup-kind-cluster.sh verify       # Post-install health check
./setup-kind-cluster.sh rollback     # Undo completed installation steps
./setup-kind-cluster.sh cleanup      # Remove local generated files and logs
```

### CLI Options

```
-h, --help              Show help message
-v, --version           Show version
--verbose               Enable verbose/debug output
--non-interactive       Run without prompts
--dry-run               Show commands without executing
--force-reinstall       Force reinstall of existing tools
--skip-prereqs          Skip system requirements check
--cluster-name NAME     Set cluster name
--cluster-domain DOMAIN Set cluster domain
--worker-nodes N        Set number of worker nodes
--no-rollback           Disable automatic rollback on failure
```

### Usage Examples

```bash
# Non-interactive full install with custom cluster name
./setup-kind-cluster.sh --non-interactive --cluster-name dev-env install-all

# Dry-run to preview all commands
./setup-kind-cluster.sh --dry-run install-all

# Install with 3 worker nodes and monitoring
WORKER_NODES=3 ./setup-kind-cluster.sh install-full

# Set Rancher password via environment variable
RANCHER_PASSWORD="MySecurePass123" ./setup-kind-cluster.sh install-rancher

# CI/CD pipeline usage
NON_INTERACTIVE=true ROLLBACK_ENABLED=true ./setup-kind-cluster.sh install-all
```

## Local DNS Resolution (`/etc/hosts`)

This script uses `/etc/hosts` for local DNS resolution. Step 14 automatically adds an entry for Rancher:

```
127.0.0.1   rancher.cluster.test
```

> [!IMPORTANT]
> **Each new application exposed via Gateway API or Ingress requires its own entry.**
> **Wildcard DNS is not supported with this approach.**

### Adding entries for new applications

Edit `/etc/hosts` (requires `sudo`) and add one line per application:

```
# Kind cluster — local DNS entries
127.0.0.1   rancher.cluster.test
127.0.0.1   grafana.cluster.test
127.0.0.1   prometheus.cluster.test
127.0.0.1   my-app.cluster.test
```

Then access the application at `https://grafana.cluster.test` (ports 80/443 are handled by NGINX Gateway Fabric).

> [!TIP]
> **Future improvement:** Replace `/etc/hosts` with [dnsmasq](https://thekelleys.org.uk/dnsmasq/doc.html) to enable wildcard resolution (`*.cluster.test → 127.0.0.1`) and eliminate the need to add entries manually. This is the approach used by tools like Rancher Desktop and k3d.

## Post-Installation Verification

The `verify` command runs `verify_installation()` which checks:

1. Kubernetes API connectivity (`kubectl cluster-info`)
2. Node status (all nodes in `Ready` state)
3. `kube-system` pod health
4. NGINX Gateway Fabric deployment readiness
5. GatewayClass and Gateway resource existence
6. cert-manager deployment readiness
7. Rancher Server deployment readiness and UI accessibility

```bash
./setup-kind-cluster.sh verify
```

## Technical Decisions

| Decision | Rationale |
|---|---|
| **Gateway API + NGF** | Uses Gateway API instead of the traditional NGINX Ingress Controller for clearer responsibility separation and flexible routing |
| **NodePort + extraPortMappings** | Kind maps host ports 80/443 to container ports 30080/30443 |
| **`externalTrafficPolicy: Cluster`** | Ensures cross-node traffic forwarding in multi-node setups |
| **X-Forwarded-Proto header** | Prevents Rancher redirect loops when TLS terminates at the Gateway |
| **Localhost fallback in HTTPRoute** | Allows stable troubleshooting via `kubectl port-forward` without modifying `/etc/hosts` |
| **Pinned Rancher version** | Uses `2.13.x` (semver range) to ensure stability while allowing critical patch updates |
| **`set -euo pipefail`** | Script exits immediately on any error or undefined variable, preventing inconsistent states |
| **Modular functions** | Enables step-by-step or batch execution |
| **Multi-method port detection** | Uses `nc`, `ss`, `netstat`, and `lsof` to detect port conflicts across different Linux environments |
| **No hardcoded passwords** | Generated securely via /dev/urandom |
| **LIFO rollback** | Installation steps reverted in reverse order |
| **RSA 2048 CA** | Better performance for local development |
| **IPv6 disabled by default** | Avoids networking issues in some Kind environments |

## Security Notes

- Passwords are never hardcoded.
- Sensitive files stored with chmod 600.
- Running as root requires confirmation.
- Development-only insecure options are explicitly documented.
- Not intended for production use.

## Contributing

1. Fork the project.
2. Create a branch.
3. Commit changes.
4. Push and open a Pull Request.

---

## License

This project is licensed under the [MIT License](LICENSE).
