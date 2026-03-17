#
# Author: Francinaldo Nunes
# Description: Evolution of the laboratory automation scripts, consolidating
#              practical experiments and architectural improvements developed
#              over time. AI tools were used as engineering assistance during
#              development to support refinement and robustness improvements.
# Version: 2.0
# License: MIT

set -euo pipefail

# ==================== GLOBAL CONFIGURATION ====================

# Script metadata
SCRIPT_VERSION="2.0"
SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${SCRIPT_DIR}/setup-k8s-$(date +%Y%m%d-%H%M%S).log"

# Cluster configuration
CLUSTER_DOMAIN="${CLUSTER_DOMAIN:-cluster.test}"
CLUSTER_NAME="${CLUSTER_NAME:-k8s-cluster}"
RANCHER_HOSTNAME="rancher.${CLUSTER_DOMAIN}"
RANCHER_PASSWORD="${RANCHER_PASSWORD:-}"
KIND_CONFIG_FILE="${SCRIPT_DIR}/kind-cluster.yaml"
CERT_DIR="${SCRIPT_DIR}/certs"

# Tool versions (configurable via environment variables)
KIND_VERSION="${KIND_VERSION:-v0.29.0}"
KUBERNETES_VERSION="${KUBERNETES_VERSION:-v1.32.0}"
KUBECTL_VERSION="${KUBECTL_VERSION:-v1.32.0}"
RANCHER_CLI_VERSION="${RANCHER_CLI_VERSION:-v2.11.3}"
RANCHER_VERSION="${RANCHER_VERSION:-2.13.x}"
CERT_MANAGER_CHART_VERSION="${CERT_MANAGER_CHART_VERSION:-v1.15.0}"
RANCHER_MONITORING_CHART_VERSION="${RANCHER_MONITORING_CHART_VERSION:-108.0.2+up77.9.1-rancher.11}"
GATEWAY_API_VERSION="${GATEWAY_API_VERSION:-v1.1.0}"
NGF_VERSION="${NGF_VERSION:-1.3.0}"

# System requirements
MIN_MEMORY_GB=4
MIN_DISK_GB=20
MIN_CPU_CORES=2
REQUIRED_PORTS=(80 443 6443 30080 30443)

# Runtime flags
NON_INTERACTIVE="${NON_INTERACTIVE:-false}"
SKIP_PREREQS="${SKIP_PREREQS:-false}"
VERBOSE="${VERBOSE:-false}"
DRY_RUN="${DRY_RUN:-false}"
FORCE_REINSTALL="${FORCE_REINSTALL:-false}"

# Logging configuration
# LOG_LEVEL: 0=DEBUG, 1=INFO, 2=WARNING, 3=ERROR
# Default to INFO (1), or DEBUG (0) if VERBOSE=true
if [[ "$VERBOSE" == "true" ]]; then
    LOG_LEVEL="${LOG_LEVEL:-0}"
else
    LOG_LEVEL="${LOG_LEVEL:-1}"
fi

# Timeout configuration (in seconds)
# These can be overridden via environment variables for slower/faster environments
CLUSTER_START_TIMEOUT="${CLUSTER_START_TIMEOUT:-120}"
CERTIFICATE_TIMEOUT="${CERTIFICATE_TIMEOUT:-300}"
HELM_INSTALL_TIMEOUT="${HELM_INSTALL_TIMEOUT:-600}"
KUBECTL_WAIT_TIMEOUT="${KUBECTL_WAIT_TIMEOUT:-300}"

# IPv6 configuration
# Set to 'false' to keep IPv6 enabled (may cause issues with Kind in some environments)
# Default: true (disable IPv6 for better Kind compatibility)
DISABLE_IPV6="${DISABLE_IPV6:-true}"

# Rollback tracking
# Array to track completed installation steps for rollback on failure
declare -a INSTALLATION_STEPS=()
ROLLBACK_ENABLED="${ROLLBACK_ENABLED:-true}"

# ==================== ANSI COLOR CODES ====================

if [[ -t 1 ]] && [[ "${NO_COLOR:-}" != "1" ]]; then
    COLOR_RESET='\033[0m'
    COLOR_INFO='\033[0;34m'     # Blue
    COLOR_SUCCESS='\033[0;32m'  # Green
    COLOR_WARN='\033[0;33m'     # Yellow
    COLOR_ERROR='\033[0;31m'    # Red
    COLOR_DEBUG='\033[0;35m'    # Magenta
    COLOR_MENU_TITLE='\033[1;32m' # Bold Green
    COLOR_MENU_OPTION='\033[0;36m' # Cyan
    COLOR_PROMPT='\033[0;37m'   # White/Light Gray
else
    COLOR_RESET=''
    COLOR_INFO=''
    COLOR_SUCCESS=''
    COLOR_WARN=''
    COLOR_ERROR=''
    COLOR_DEBUG=''
    COLOR_MENU_TITLE=''
    COLOR_MENU_OPTION=''
    COLOR_PROMPT=''
fi

# ==================== LOGGING FUNCTIONS ====================

# Enhanced logging with timestamps, log levels, and configurable verbosity
# Respects LOG_LEVEL: 0=DEBUG, 1=INFO, 2=WARNING, 3=ERROR
log_message() {
    local level="$1"
    local level_num="$2"
    local color="$3"
    shift 3
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local message="$*"
    
    # Skip if message level is below configured LOG_LEVEL
    if [[ $level_num -lt $LOG_LEVEL ]]; then
        return 0
    fi
    
    # Console output with color
    echo -e "${color}[${timestamp}] ${level}: ${message}${COLOR_RESET}" >&2
    
    # Log file output without color
    echo "[${timestamp}] ${level}: ${message}" >> "$LOG_FILE"
}

echo_debug() { log_message "DEBUG" 0 "$COLOR_DEBUG" "$@"; }
echo_info() { log_message "INFO" 1 "$COLOR_INFO" "$@"; }
echo_success() { log_message "SUCCESS" 1 "$COLOR_SUCCESS" "$@"; }
echo_warn() { log_message "WARNING" 2 "$COLOR_WARN" "$@"; }
echo_error() { log_message "ERROR" 3 "$COLOR_ERROR" "$@"; }

# ==================== ERROR HANDLING ====================

# Global error handler
error_handler() {
    local line_number="$1"
    local error_code="$2"
    local command="$BASH_COMMAND"
    
    echo_error "Script failed at line $line_number with exit code $error_code"
    echo_error "Failed command: $command"
    echo_error "Log file: $LOG_FILE"
    
    # Cleanup on error
    cleanup_on_error
    
    exit "$error_code"
}

# Set error trap
trap 'error_handler ${LINENO} $?' ERR

# Cleanup function for error scenarios
cleanup_on_error() {
    echo_warn "Performing cleanup due to error..."
    
    if [[ "$ROLLBACK_ENABLED" == "true" ]] && [[ ${#INSTALLATION_STEPS[@]} -gt 0 ]]; then
        echo_warn "Rollback is enabled. Attempting to undo completed steps..."
        rollback_installation
    else
        echo_info "Rollback disabled or no steps to rollback"
    fi
}

# Graceful exit handler
graceful_exit() {
    echo_info "Script interrupted. Performing cleanup..."
    cleanup_on_error
    exit 130
}

# Set interrupt trap
trap graceful_exit SIGINT SIGTERM

# ==================== UTILITY FUNCTIONS ====================

# Check if running as root
check_root() {
    if [[ "$EUID" -eq 0 ]]; then
        echo_warn "Running as root. This is not recommended for security reasons."
        if [[ "$NON_INTERACTIVE" != "true" ]]; then
            read -p "Continue anyway? (y/N): " -r
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                echo_info "Exiting for security reasons."
                exit 1
            fi
        fi
    fi
}

# Detect Linux distribution
detect_distro() {
    echo_info "Detecting Linux distribution..."
    
    if [[ ! -f /etc/os-release ]]; then
        echo_error "Cannot detect Linux distribution. /etc/os-release not found."
        exit 1
    fi
    
    # Source OS release information
    source /etc/os-release
    
    DISTRO_ID="${ID,,}"
    DISTRO_ID_LIKE="${ID_LIKE,,}"
    UBUNTU_CODENAME="${UBUNTU_CODENAME:-}"
    VERSION_CODENAME="${VERSION_CODENAME:-}"
    
    # Determine base distribution
    if [[ "$DISTRO_ID" == "linuxmint" ]]; then
        BASE_CODENAME="${UBUNTU_CODENAME:-$VERSION_CODENAME}"
        BASE_DISTRO="ubuntu"
    elif [[ "$DISTRO_ID_LIKE" =~ ubuntu|debian ]]; then
        BASE_DISTRO="ubuntu"
        BASE_CODENAME="$VERSION_CODENAME"
    elif [[ "$DISTRO_ID_LIKE" =~ rhel|fedora|centos ]] || [[ "$DISTRO_ID" =~ ^(fedora|centos|rocky|almalinux)$ ]]; then
        BASE_DISTRO="rhel"
    else
        echo_error "Unsupported Linux distribution: $DISTRO_ID"
        echo_error "Supported distributions: Ubuntu, Debian, CentOS, RHEL, Fedora, Rocky Linux, AlmaLinux"
        exit 1
    fi
    
    echo_info "Detected distribution: $DISTRO_ID (base: $BASE_DISTRO)"
    [[ -n "$BASE_CODENAME" ]] && echo_info "Codename: $BASE_CODENAME"
}

# Check system requirements
check_system_requirements() {
    if [[ "$SKIP_PREREQS" == "true" ]]; then
        echo_warn "Skipping system requirements check (SKIP_PREREQS=true)"
        return 0
    fi
    
    echo_info "Checking system requirements..."
    local failed=false
    
    # Check memory
    local memory_gb=$(free -g | awk '/^Mem:/{print $2}')
    if [[ $memory_gb -lt $MIN_MEMORY_GB ]]; then
        echo_error "Insufficient memory: ${memory_gb}GB available, ${MIN_MEMORY_GB}GB required"
        failed=true
    else
        echo_success "Memory check passed: ${memory_gb}GB available"
    fi
    
    # Check disk space
    local disk_gb=$(df -BG "$SCRIPT_DIR" | awk 'NR==2 {print $4}' | sed 's/G//')
    if [[ $disk_gb -lt $MIN_DISK_GB ]]; then
        echo_error "Insufficient disk space: ${disk_gb}GB available, ${MIN_DISK_GB}GB required"
        failed=true
    else
        echo_success "Disk space check passed: ${disk_gb}GB available"
    fi
    
    # Check CPU cores
    local cpu_cores=$(nproc)
    if [[ $cpu_cores -lt $MIN_CPU_CORES ]]; then
        echo_error "Insufficient CPU cores: ${cpu_cores} available, ${MIN_CPU_CORES} required"
        failed=true
    else
        echo_success "CPU check passed: ${cpu_cores} cores available"
    fi
    
    # Check required commands
    local required_commands=(curl wget tar gzip openssl)
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            echo_error "Required command not found: $cmd"
            failed=true
        fi
    done
    
    if [[ "$failed" == "true" ]]; then
        echo_error "System requirements check failed. Use SKIP_PREREQS=true to bypass."
        exit 1
    fi
    
    echo_success "All system requirements met"
}

# Check network connectivity
check_network() {
    echo_info "Checking network connectivity..."
    
    local test_urls=(
        "https://download.docker.com"
        "https://dl.k8s.io"
        "https://github.com"
        "https://charts.jetstack.io"
    )
    
    for url in "${test_urls[@]}"; do
        if ! curl -s --connect-timeout 10 "$url" >/dev/null; then
            echo_error "Cannot reach $url. Check your internet connection."
            exit 1
        fi
    done
    
    echo_success "Network connectivity check passed"
}

# Check port availability
# Helper to check if a single port is in use
is_port_in_use() {
    local port=$1
    
    # Method 1: Try to connect with netcat (most reliable for "is it reachable?")
    if command -v nc >/dev/null 2>&1; then
        if nc -z -w 1 127.0.0.1 "$port" >/dev/null 2>&1; then
            return 0 # Port is in use
        fi
    fi
    
    # Method 2: ss (socket statistics)
    if command -v ss >/dev/null 2>&1; then
        if ss -tuln | grep -E ":$port " >/dev/null 2>&1; then
            return 0 # Port is in use
        fi
    fi
    
    # Method 3: netstat
    if command -v netstat >/dev/null 2>&1; then
        if netstat -tuln | grep -E ":$port " >/dev/null 2>&1; then
            return 0 # Port is in use
        fi
    fi
    
    # Method 4: lsof (least reliable without sudo for docker-proxy)
    if command -v lsof >/dev/null 2>&1; then
        if lsof -Pi :$port -sTCP:LISTEN -t >/dev/null 2>&1; then
            return 0 # Port is in use
        fi
    fi
    
    return 1 # Port is free
}

check_ports() {
    echo_info "Checking port availability..."
    
    local ports_in_use=()
    for port in "${REQUIRED_PORTS[@]}"; do
        if is_port_in_use "$port"; then
            ports_in_use+=("$port")
        fi
    done
    
    if [[ ${#ports_in_use[@]} -gt 0 ]]; then
        echo_warn "Ports in use: ${ports_in_use[*]}"
        
        # Check if there's an existing Kind cluster
        if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
            echo_warn "Detected existing Kind cluster: ${CLUSTER_NAME}"
            
            if [[ "$NON_INTERACTIVE" == "true" ]]; then
                # In non-interactive mode, if FORCE_REINSTALL is true, we can proceed to remove
                if [[ "$FORCE_REINSTALL" == "true" ]]; then
                     echo_info "FORCE_REINSTALL is set. Removing existing cluster..."
                     remove_kind_cluster
                     return 0
                else
                    echo_error "Cannot proceed: ports in use by existing cluster (non-interactive mode)."
                    echo_info "Use FORCE_REINSTALL=true to automatically remove the existing cluster."
                    exit 1
                fi
            fi
            
            echo
            echo "Options:"
            echo "  1) Stop and remove existing cluster (recommended)"
            echo "  2) Continue anyway (may fail)"
            echo "  3) Abort installation"
            echo
            read -p "Choose an option [1-3]: " cluster_option
            
            case $cluster_option in
                1)
                    echo_info "Stopping and removing existing cluster..."
                    remove_kind_cluster
                    echo_success "Existing cluster removed. Checking ports again..."
                    # Recursive check to ensure ports are now free
                    sleep 3
                    check_ports
                    ;;
                2)
                    echo_warn "Continuing with ports in use (installation may fail)..."
                    ;;
                3|*)
                    echo_info "Installation aborted by user"
                    exit 0
                    ;;
            esac
        else
            echo_error "Ports in use by another application (not a Kind cluster '${CLUSTER_NAME}')"
            echo_info "Please free the following ports: ${ports_in_use[*]}"
            exit 1
        fi
    else
        echo_success "All required ports are available"
    fi
}

# Generate a secure random password
# Args:
#   $1: password length (default: 16)
generate_secure_password() {
    local length="${1:-16}"
    
    # Use /dev/urandom for cryptographically secure random data
    # Filter to alphanumeric + special chars, take first N characters
    tr -dc 'A-Za-z0-9!@#$%^&*()_+=' < /dev/urandom | head -c "$length"
}

# Check if a command/tool is available
# Args:
#   $1: command name
#   $2: (optional) installation hint
check_dependency() {
    local cmd="$1"
    local hint="${2:-}"
    
    if ! command -v "$cmd" &>/dev/null; then
        echo_error "Required dependency not found: $cmd"
        if [[ -n "$hint" ]]; then
            echo_info "Installation hint: $hint"
        fi
        return 1
    fi
    
    echo_debug "Dependency check passed: $cmd"
    return 0
}

# Verify download integrity using checksum
# Args:
#   $1: file path
#   $2: expected checksum (sha256)
verify_download_integrity() {
    local file="$1"
    local expected_checksum="$2"
    
    if [[ -z "$expected_checksum" ]]; then
        echo_warn "No checksum provided for $file, skipping integrity verification"
        return 0
    fi
    
    echo_info "Verifying integrity of $(basename "$file")..."
    
    local actual_checksum
    actual_checksum=$(sha256sum "$file" | awk '{print $1}')
    
    if [[ "$actual_checksum" != "$expected_checksum" ]]; then
        echo_error "Checksum mismatch for $file"
        echo_error "Expected: $expected_checksum"
        echo_error "Got:      $actual_checksum"
        return 1
    fi
    
    echo_success "Integrity verification passed for $(basename "$file")"
    return 0
}

# Register a completed installation step for potential rollback
# Args:
#   $1: step name (e.g., "docker", "kind-cluster", "gateway-api")
register_installation_step() {
    local step="$1"
    
    if [[ "$ROLLBACK_ENABLED" == "true" ]]; then
        INSTALLATION_STEPS+=("$step")
        echo_debug "Registered installation step: $step"
    fi
}

# Rollback installation by undoing completed steps in reverse order
# This function is called automatically on error if ROLLBACK_ENABLED=true
rollback_installation() {
    echo_warn "Starting rollback of ${#INSTALLATION_STEPS[@]} completed step(s)..."
    
    # Process steps in reverse order (LIFO)
    for ((i=${#INSTALLATION_STEPS[@]}-1; i>=0; i--)); do
        local step="${INSTALLATION_STEPS[$i]}"
        echo_info "Rolling back step: $step"
        
        case "$step" in
            "kind-cluster")
                echo_info "Removing Kind cluster..."
                kind delete cluster --name "$CLUSTER_NAME" 2>/dev/null || true
                ;;
            
            "gateway-api")
                echo_info "Uninstalling Gateway API & NGF..."
                helm uninstall nginx-gateway-fabric -n nginx-gateway 2>/dev/null || true
                kubectl delete namespace nginx-gateway 2>/dev/null || true
                kubectl delete -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml" 2>/dev/null || true
                ;;
            
            "cert-manager")
                echo_info "Uninstalling cert-manager..."
                helm uninstall cert-manager -n cert-manager 2>/dev/null || true
                kubectl delete namespace cert-manager 2>/dev/null || true
                ;;
            
            "rancher")
                echo_info "Uninstalling Rancher..."
                helm uninstall rancher -n cattle-system 2>/dev/null || true
                kubectl delete namespace cattle-system 2>/dev/null || true
                ;;
            
            "monitoring")
                echo_info "Uninstalling monitoring stack..."
                helm uninstall rancher-monitoring -n cattle-monitoring-system 2>/dev/null || true
                helm uninstall rancher-monitoring-crd -n cattle-monitoring-system 2>/dev/null || true
                kubectl delete namespace cattle-monitoring-system 2>/dev/null || true
                ;;
            
            "metrics-server")
                echo_info "Uninstalling Metrics Server..."
                helm uninstall metrics-server -n kube-system 2>/dev/null || true
                ;;
            
            "ca-certificates")
                echo_info "Removing CA certificates..."
                rm -rf "$CERT_DIR" 2>/dev/null || true
                ;;
            
            "sysctl-config")
                echo_info "Removing sysctl configuration..."
                sudo rm -f /etc/sysctl.d/99-k8s.conf 2>/dev/null || true
                ;;
            
            *)
                echo_warn "Unknown rollback step: $step (skipping)"
                ;;
        esac
    done
    
    # Clear the steps array
    INSTALLATION_STEPS=()
    
    echo_success "Rollback completed"
}

# Prompt for user confirmation
prompt_confirmation() {
    local message="$1"
    local default="${2:-N}"
    
    if [[ "$NON_INTERACTIVE" == "true" ]]; then
        echo_info "Non-interactive mode: assuming '$default' for: $message"
        [[ "$default" =~ ^[Yy]$ ]]
        return $?
    fi
    
    local prompt
    if [[ "$default" =~ ^[Yy]$ ]]; then
        prompt="$message (Y/n): "
    else
        prompt="$message (y/N): "
    fi
    
    while true; do
        read -p "$prompt" -r reply
        reply="${reply:-$default}"
        
        case "$reply" in
            [Yy]|[Yy][Ee][Ss]) return 0 ;;
            [Nn]|[Nn][Oo]) return 1 ;;
            *) echo_warn "Please answer yes or no." ;;
        esac
    done
}

# Execute command with dry-run support and optional exit-on-error
# Args:
#   --exit-on-error: Exit script if command fails (default: return error code)
#   remaining args: command to execute
execute_command() {
    local exit_on_error=false
    
    # Parse optional flag
    if [[ "${1:-}" == "--exit-on-error" ]]; then
        exit_on_error=true
        shift
    fi
    
    local cmd="$*"
    
    echo_debug "Executing: $cmd"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        echo_info "[DRY RUN] Would execute: $cmd"
        return 0
    fi
    
    # Execute command and capture result
    if bash -c "$cmd"; then
        return 0
    else
        local exit_code=$?
        echo_error "Command failed (exit code: $exit_code): $cmd"
        
        if [[ "$exit_on_error" == "true" ]]; then
            exit "$exit_code"
        fi
        
        return "$exit_code"
    fi
}

# ==================== INSTALLATION FUNCTIONS ====================

# Enhanced Docker installation with better error handling
install_docker() {
    echo_info "Starting Docker installation..."
    
    if command -v docker &>/dev/null && [[ "$FORCE_REINSTALL" != "true" ]]; then
        echo_success "Docker is already installed ($(docker --version))"
        return 0
    fi
    
    case "$BASE_DISTRO" in
        ubuntu)
            install_docker_ubuntu
            ;;
        rhel)
            install_docker_rhel
            ;;
        *)
            echo_error "Unsupported distribution for Docker installation: $BASE_DISTRO"
            exit 1
            ;;
    esac
    
    # Configure Docker service
    sudo systemctl enable --now docker || {
        echo_error "Failed to enable and start Docker service."
        exit 1
    }
    
    # Add user to docker group
    configure_docker_permissions
    
    # Verify installation
    if ! docker --version &>/dev/null; then
        echo_error "Docker installation verification failed"
        exit 1
    fi
    
    echo_success "Docker installed successfully"
}

install_docker_ubuntu() {
    echo_info "Installing Docker on Ubuntu/Debian-based system..."
    
    # Update package index
    sudo apt-get update || {
        echo_error "Failed to update package index."
        exit 1
    }
    
    # Install dependencies
    sudo apt-get install -y ca-certificates curl gnupg lsb-release || {
        echo_error "Failed to install Docker dependencies."
        exit 1
    }
    
    # Add Docker GPG key
    sudo mkdir -p /etc/apt/keyrings || {
        echo_error "Failed to create keyrings directory."
        exit 1
    }
    
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg || {
        echo_error "Failed to add Docker GPG key."
        exit 1
    }
    
    # Add Docker repository
    local repo_line="deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $BASE_CODENAME stable"
    echo "$repo_line" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null || {
        echo_error "Failed to add Docker repository."
        exit 1
    }
    
    # Update package index again
    sudo apt-get update || {
        echo_error "Failed to update package index after adding Docker repository."
        exit 1
    }
    
    # Install Docker
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin || {
        echo_error "Failed to install Docker."
        exit 1
    }
}

install_docker_rhel() {
    echo_info "Installing Docker on RHEL-based system..."
    
    # Detect package manager
    local pkg_manager
    if command -v dnf &>/dev/null; then
        pkg_manager="dnf"
    elif command -v yum &>/dev/null; then
        pkg_manager="yum"
    else
        echo_error "No package manager (dnf or yum) found"
        exit 1
    fi
    
    # Install dependencies
    sudo $pkg_manager install -y yum-utils || {
        echo_error "Failed to install yum-utils."
        exit 1
    }
    
    # Add Docker repository
    sudo yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo || {
        echo_error "Failed to add Docker repository."
        exit 1
    }
    
    # Install Docker
    sudo $pkg_manager install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin || {
        echo_error "Failed to install Docker."
        exit 1
    }
}

configure_docker_permissions() {
    echo_info "Configuring Docker permissions..."
    
    if groups "$USER" | grep -qw docker; then
        echo_success "User $USER already belongs to docker group"
        return 0
    fi
    
    sudo usermod -aG docker "$USER" || {
        echo_error "Failed to add user to docker group."
        exit 1
    }
    
    echo_warn "User $USER added to docker group"
    echo_warn "You may need to log out and log back in for changes to take effect"
    
    if [[ "$NON_INTERACTIVE" != "true" ]]; then
        if prompt_confirmation "Continue without restarting session?"; then
            echo_info "Continuing with current session"
        else
            echo_info "Please restart your session and run the script again"
            exit 0
        fi
    fi
}

# Enhanced kubectl installation
install_kubectl() {
    echo_info "Installing kubectl..."
    
    if command -v kubectl &>/dev/null && [[ "$FORCE_REINSTALL" != "true" ]]; then
        echo_success "kubectl is already installed ($(kubectl version --client --short 2>/dev/null || echo 'version unknown'))"
        return 0
    fi
    
    local kubectl_url="https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
    local temp_file="/tmp/kubectl-${KUBECTL_VERSION}"
    
    # Download kubectl
    curl -fsSL -o "$temp_file" "$kubectl_url" || {
        echo_error "Failed to download kubectl."
        exit 1
    }
    
    # Verify checksum if available
    if curl -fsSL "${kubectl_url}.sha256" -o "${temp_file}.sha256" 2>/dev/null; then
        echo_info "Verifying kubectl checksum..."
        local expected actual
        expected=$(cat "${temp_file}.sha256")
        actual=$(sha256sum "$temp_file" | awk '{print $1}')

        if [[ "$expected" != "$actual" ]]; then
            echo_error "kubectl checksum verification failed"
            echo_error "Expected: $expected"
            echo_error "Got:      $actual"
            rm -f "$temp_file" "${temp_file}.sha256"
            exit 1
        fi
        echo_success "kubectl checksum verified"
    fi
    
    # Install kubectl
    sudo install -o root -g root -m 0755 "$temp_file" /usr/local/bin/kubectl || {
        echo_error "Failed to install kubectl."
        rm -f "$temp_file" "${temp_file}.sha256"
        exit 1
    }
    
    rm -f "$temp_file" "${temp_file}.sha256" || echo_warn "Failed to clean up temporary files."
    
    echo_success "kubectl installed successfully"
}

# Enhanced Helm installation
install_helm() {
    echo_info "Installing Helm..."
    
    if command -v helm &>/dev/null && [[ "$FORCE_REINSTALL" != "true" ]]; then
        echo_success "Helm is already installed ($(helm version --short 2>/dev/null || echo 'version unknown'))"
        return 0
    fi
    
    # Use official Helm installation script
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash || {
        echo_error "Failed to install Helm."
        exit 1
    }
    
    echo_success "Helm installed successfully"
}

# Enhanced Kind installation
install_kind() {
    echo_info "Installing Kind..."
    
    if command -v kind &>/dev/null && [[ "$FORCE_REINSTALL" != "true" ]]; then
        echo_success "Kind is already installed ($(kind version 2>/dev/null || echo 'version unknown'))"
        return 0
    fi
    
    local kind_url="https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-amd64"
    local kind_checksum_url="${kind_url}.sha256sum"
    local temp_file="/tmp/kind-${KIND_VERSION}"
    local temp_checksum="/tmp/kind-${KIND_VERSION}.sha256sum"
    
    # Download Kind binary
    curl -fsSL -o "$temp_file" "$kind_url" || {
        echo_error "Failed to download Kind."
        exit 1
    }
    
    # Verify SHA256 checksum (Kind publishes .sha256sum alongside each release)
    echo_info "Verifying Kind checksum..."
    if curl -fsSL -o "$temp_checksum" "$kind_checksum_url" 2>/dev/null; then
        # The checksum file format is: "<hash>  kind-linux-amd64"
        local expected_checksum
        expected_checksum=$(awk '{print $1}' "$temp_checksum")
        local actual_checksum
        actual_checksum=$(sha256sum "$temp_file" | awk '{print $1}')
        
        if [[ "$actual_checksum" != "$expected_checksum" ]]; then
            echo_error "Kind checksum verification failed"
            echo_error "Expected: $expected_checksum"
            echo_error "Got:      $actual_checksum"
            rm -f "$temp_file" "$temp_checksum"
            exit 1
        fi
        echo_success "Kind checksum verified"
        rm -f "$temp_checksum"
    else
        echo_warn "Could not download Kind checksum file. Skipping integrity verification."
    fi
    
    chmod +x "$temp_file" || {
        echo_error "Failed to make Kind executable."
        rm -f "$temp_file"
        exit 1
    }
    
    sudo mv "$temp_file" /usr/local/bin/kind || {
        echo_error "Failed to install Kind."
        rm -f "$temp_file"
        exit 1
    }
    
    echo_success "Kind installed successfully"
}

# Enhanced Rancher CLI installation
install_rancher_cli() {
    echo_info "Installing Rancher CLI..."
    
    if command -v rancher &>/dev/null && [[ "$FORCE_REINSTALL" != "true" ]]; then
        echo_success "Rancher CLI is already installed"
        return 0
    fi
    
    local arch="amd64"
    local url="https://github.com/rancher/cli/releases/download/${RANCHER_CLI_VERSION}/rancher-linux-${arch}-${RANCHER_CLI_VERSION}.tar.gz"
    local temp_dir="/tmp/rancher-cli-${RANCHER_CLI_VERSION}"
    
    # Note: Rancher CLI does not publish a standalone checksum file per release.
    # Integrity is partially ensured by using HTTPS and the official GitHub releases URL.
    # If a checksum becomes available in future releases, add verification here using
    # verify_download_integrity() with the expected SHA256 hash.
    
    # Create temporary directory
    sudo mkdir -p "$temp_dir" || {
        echo_error "Failed to create temporary directory."
        exit 1
    }
    
    # Download and extract
    curl -fsSL "$url" | sudo tar -xzC "$temp_dir" --strip-components=1 || {
        echo_error "Failed to download and extract Rancher CLI."
        sudo rm -rf "$temp_dir"
        exit 1
    }
    
    # Install
    sudo mv "$temp_dir/rancher" /usr/local/bin/ || {
        echo_error "Failed to install Rancher CLI."
        sudo rm -rf "$temp_dir"
        exit 1
    }
    
    sudo rm -rf "$temp_dir" || echo_warn "Failed to clean up temporary directory."
    
    echo_success "Rancher CLI installed successfully"
}

# System configuration functions
configure_sysctl() {
    echo_info "Configuring system parameters (sysctl)..."
    
    local sysctl_file="/etc/sysctl.d/99-k8s.conf"
    local sysctl_content=""
    
    # IPv6 configuration (optional, controlled by DISABLE_IPV6)
    # Why disable IPv6: Kind clusters may have networking issues with IPv6 enabled in some environments
    # This is a known compatibility issue, not a security requirement
    if [[ "$DISABLE_IPV6" == "true" ]]; then
        echo_info "Disabling IPv6 (DISABLE_IPV6=true for Kind compatibility)"
        sysctl_content+="net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
"
    else
        echo_info "Keeping IPv6 enabled (DISABLE_IPV6=false)"
    fi
    
    # File system watches (required for Kubernetes)
    sysctl_content+="fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 1024"
    
    echo "$sysctl_content" | sudo tee "$sysctl_file" > /dev/null || {
        echo_error "Failed to create sysctl configuration file."
        exit 1
    }
    
    sudo sysctl --system || {
        echo_error "Failed to apply sysctl configuration."
        exit 1
    }
    
    echo_success "Sysctl parameters configured"
    register_installation_step "sysctl-config"
}

configure_docker_systemd() {
    echo_info "Configuring Docker systemd service..."
    
    local override_dir="/etc/systemd/system/docker.service.d"
    local override_file="$override_dir/override.conf"
    local override_content="[Service]
LimitNOFILE=1048576"
    
    sudo mkdir -p "$override_dir" || {
        echo_error "Failed to create Docker systemd override directory."
        exit 1
    }
    
    echo "$override_content" | sudo tee "$override_file" > /dev/null || {
        echo_error "Failed to create Docker systemd override file."
        exit 1
    }
    
    sudo systemctl daemon-reload || {
        echo_error "Failed to reload systemd daemon."
        exit 1
    }
    
    sudo systemctl restart docker || {
        echo_error "Failed to restart Docker service."
        exit 1
    }
    
    echo_success "Docker systemd configuration applied"
}

# ==================== KUBERNETES CLUSTER FUNCTIONS ====================

# Check cluster connectivity
check_cluster_connection() {
    echo_info "Checking Kubernetes cluster connectivity..."
    
    if ! kubectl cluster-info &>/dev/null; then
        echo_error "Cannot connect to Kubernetes cluster"
        echo_info "Available clusters: $(kind get clusters 2>/dev/null || echo 'none')"
        exit 1
    fi
    
    echo_success "Kubernetes cluster connection established"
}

# Generate CA certificates with enhanced security
generate_ca_certificates() {
    echo_info "Generating CA certificates for $CLUSTER_DOMAIN..."
    
    mkdir -p "$CERT_DIR" || {
        echo_error "Failed to create certificates directory."
        exit 1
    }
    
    # Create OpenSSL configuration (simplified for better performance)
    cat > "$CERT_DIR/openssl.cnf" << EOF
[ req ]
default_bits       = 2048
distinguished_name = req_distinguished_name
x509_extensions    = v3_ca
prompt             = no

[ req_distinguished_name ]
CN = $CLUSTER_DOMAIN

[ v3_ca ]
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer
basicConstraints = critical,CA:TRUE
keyUsage = critical, keyCertSign, cRLSign
extendedKeyUsage = serverAuth, clientAuth
subjectAltName = @alt_names

[ alt_names ]
DNS.1 = $CLUSTER_DOMAIN
DNS.2 = *.$CLUSTER_DOMAIN
DNS.3 = localhost
IP.1 = 127.0.0.1
EOF
    
    # Generate CA certificate and key (using RSA 2048 for better performance)
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
        -keyout "$CERT_DIR/tls.key" \
        -out "$CERT_DIR/tls.crt" \
        -config "$CERT_DIR/openssl.cnf" \
        -extensions v3_ca || {
        echo_error "Failed to generate CA TLS certificate."
        exit 1
    }
    
    # Set secure permissions
    chmod 600 "$CERT_DIR/tls.key"
    chmod 644 "$CERT_DIR/tls.crt"
    
    echo_success "CA certificates generated at $CERT_DIR"
    register_installation_step "ca-certificates"
}

# Create Kind cluster with enhanced configuration
create_kind_cluster() {
    echo_info "Creating Kind cluster configuration..."
    
    # Ensure certificates exist
    if [[ ! -f "$CERT_DIR/tls.crt" ]]; then
        generate_ca_certificates
    fi
    
    # Check if cluster already exists
    if kind get clusters 2>/dev/null | grep -q "^$CLUSTER_NAME$"; then
        echo_warn "Kind cluster '$CLUSTER_NAME' already exists"
        
        if [[ "$FORCE_REINSTALL" == "true" ]]; then
            echo_info "Force reinstall enabled, removing existing cluster"
            remove_kind_cluster
        elif prompt_confirmation "Reinstall existing cluster?"; then
            remove_kind_cluster
        else
            echo_info "Using existing cluster"
            return 0
        fi
    fi
    
    # Generate Kind configuration
    cat > "$KIND_CONFIG_FILE" << EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
networking:
  ipFamily: ipv4
  disableDefaultCNI: false
nodes:
  - role: control-plane
    image: kindest/node:$KUBERNETES_VERSION
    extraPortMappings:
      - containerPort: 30080
        hostPort: 80
        protocol: TCP
      - containerPort: 30443
        hostPort: 443
        protocol: TCP
    extraMounts:
      - hostPath: $CERT_DIR/tls.crt
        containerPath: /etc/kind/ca/tls.crt
    kubeadmConfigPatches:
      - |
        kind: InitConfiguration
        nodeRegistration:
          kubeletExtraArgs:
            allowed-unsafe-sysctls: "net.ipv6.conf.all.disable_ipv6,net.ipv6.conf.default.disable_ipv6"
        ---
        kind: ClusterConfiguration
        apiServer:
          extraArgs:
            "tls-min-version": "VersionTLS12"
            "audit-log-maxage": "30"
            "audit-log-maxbackup": "3"
            "audit-log-maxsize": "100"
        ---
        kind: KubeletConfiguration
        containerLogMaxSize: "100Mi"
        maxPods: 110
EOF
    
    # Add worker nodes if requested
    local worker_count="${WORKER_NODES:-2}"
    for ((i=1; i<=worker_count; i++)); do
        cat >> "$KIND_CONFIG_FILE" << EOF
  - role: worker
    image: kindest/node:$KUBERNETES_VERSION
    extraMounts:
      - hostPath: $CERT_DIR/tls.crt
        containerPath: /etc/kind/ca/tls.crt
    kubeadmConfigPatches:
      - |
        kind: InitConfiguration
        nodeRegistration:
          kubeletExtraArgs:
            allowed-unsafe-sysctls: "net.ipv6.conf.all.disable_ipv6,net.ipv6.conf.default.disable_ipv6"
EOF
    done
    
    echo_info "Creating Kind cluster '$CLUSTER_NAME'..."
    kind create cluster --name "$CLUSTER_NAME" --config "$KIND_CONFIG_FILE" --wait 300s || {
        echo_error "Failed to create Kind cluster."
        exit 1
    }
    
    # Update CA certificates in nodes
    echo_info "Updating CA certificates in Kind nodes..."
    for node in $(kind get nodes --name "$CLUSTER_NAME"); do
        docker exec "$node" sh -c 'cp /etc/kind/ca/tls.crt /usr/local/share/ca-certificates/rancher-ca.crt && update-ca-certificates' || {
            echo_error "Failed to update CA certificates in node $node."
            exit 1
        }
    done
    
    # Disable automatic restart for containers
    echo_info "Configuring container restart policies..."
    for container in $(docker ps -a --filter "name=$CLUSTER_NAME" --format "{{.Names}}"); do
        docker update --restart=no "$container" || {
            echo_error "Failed to configure restart policy for container $container."
            exit 1
        }
    done
    
    echo_success "Kind cluster created successfully"
    register_installation_step "kind-cluster"
}

# Start Kind cluster
start_kind_cluster() {
    echo_info "Starting Kind cluster '$CLUSTER_NAME'..."
    
    if ! kind get clusters 2>/dev/null | grep -q "^$CLUSTER_NAME$"; then
        echo_error "Kind cluster '$CLUSTER_NAME' does not exist"
        exit 1
    fi
    
    local containers
    containers=$(docker ps -a --filter "label=io.x-k8s.kind.cluster=$CLUSTER_NAME" --format "{{.Names}}")
    
    if [[ -z "$containers" ]]; then
        echo_error "No containers found for Kind cluster '$CLUSTER_NAME'"
        exit 1
    fi
    
    echo_info "Starting containers: $containers"
    docker start $containers || {
        echo_error "Failed to start cluster containers."
        exit 1
    }
    
    # Wait for cluster to be ready
    echo_info "Waiting for cluster to be ready..."
    local timeout=$CLUSTER_START_TIMEOUT
    local elapsed=0
    
    while ! kubectl cluster-info &>/dev/null; do
        if [[ $elapsed -ge $timeout ]]; then
            echo_error "Timeout waiting for cluster to be ready"
            exit 1
        fi
        
        sleep 5
        elapsed=$((elapsed + 5))
        echo_debug "Waiting for cluster... ($elapsed/${timeout}s)"
    done
    
    echo_success "Kind cluster started successfully"
}

# Stop Kind cluster
stop_kind_cluster() {
    echo_info "Stopping Kind cluster '$CLUSTER_NAME'..."
    
    local containers
    containers=$(docker ps --filter "label=io.x-k8s.kind.cluster=$CLUSTER_NAME" --format "{{.Names}}")
    
    if [[ -z "$containers" ]]; then
        echo_warn "No running containers found for Kind cluster '$CLUSTER_NAME'"
        return 0
    fi
    
    echo_info "Stopping containers: $containers"
    docker stop $containers || {
        echo_error "Failed to stop cluster containers."
        exit 1
    }
    
    echo_success "Kind cluster stopped successfully"
}

# Remove Kind cluster
remove_kind_cluster() {
    echo_info "Removing Kind cluster '$CLUSTER_NAME'..."
    
    if ! kind get clusters 2>/dev/null | grep -q "^$CLUSTER_NAME$"; then
        echo_warn "Kind cluster '$CLUSTER_NAME' does not exist"
        return 0
    fi
    
    if [[ "$NON_INTERACTIVE" != "true" ]] && ! prompt_confirmation "Remove Kind cluster '$CLUSTER_NAME'?"; then
        echo_info "Cluster removal cancelled"
        return 0
    fi
    
    kind delete cluster --name "$CLUSTER_NAME" || {
        echo_error "Failed to delete cluster."
        exit 1
    }
    echo_success "Kind cluster removed successfully"
}

# ==================== KUBERNETES COMPONENTS ====================

# Install NGINX Ingress Controller
# Install Gateway API CRDs and NGINX Gateway Fabric
install_gateway_api() {
    echo_info "Installing Gateway API CRDs and NGINX Gateway Fabric..."
    
    # Check if already installed
    if kubectl get gatewayclass nginx &>/dev/null; then
        echo_success "Gateway API/NGF already installed"
        return 0
    fi

    # 1. Install Gateway API CRDs (Standard Channel)
    echo_info "Installing Gateway API CRDs (${GATEWAY_API_VERSION})..."
    kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml" || {
        echo_error "Failed to install Gateway API CRDs"
        exit 1
    }
    echo_success "Gateway API CRDs installed"

    # 2. Install NGINX Gateway Fabric via Helm
    echo_info "Installing NGINX Gateway Fabric (${NGF_VERSION})..."
    
    # Create namespace
    kubectl create namespace nginx-gateway --dry-run=client -o yaml | kubectl apply -f -

    # Install Chart
    # We use ServiceType=NodePort to expose ports 80/443 on the Kind node.
    # Kind port mappings (extraPortMappings) forward host 80/443 to container 80/443.
    # We need the Gateway Service to listen on these node ports.
    
    helm upgrade --install nginx-gateway-fabric oci://ghcr.io/nginxinc/charts/nginx-gateway-fabric \
        --version "${NGF_VERSION}" \
        --namespace nginx-gateway \
        --create-namespace \
        --set service.type=NodePort \
        --set service.ports[0].port=80 \
        --set service.ports[0].nodePort=30080 \
        --set service.ports[0].targetPort=80 \
        --set service.ports[0].name=http \
        --set service.ports[1].port=443 \
        --set service.ports[1].nodePort=30443 \
        --set service.ports[1].targetPort=443 \
        --set service.ports[1].name=https \
        --set service.externalTrafficPolicy=Cluster \
        --wait \
        --timeout "${HELM_INSTALL_TIMEOUT}s" || {
        echo_error "Failed to install NGINX Gateway Fabric"
        exit 1
    }

    # 3. Create Gateway Resource
    echo_info "Creating NGINX Gateway resource..."
    cat <<EOF | kubectl apply -f -
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: default-gateway
  namespace: nginx-gateway
spec:
  gatewayClassName: nginx
  listeners:
  - name: http
    port: 80
    protocol: HTTP
    allowedRoutes:
      namespaces:
        from: All
  - name: https
    port: 443
    protocol: HTTPS
    tls:
      mode: Terminate
      certificateRefs:
      - name: tls-rancher-gateway
        namespace: nginx-gateway 
    allowedRoutes:
      namespaces:
        from: All
EOF

    register_installation_step "gateway-api"
    echo_success "NGINX Gateway Fabric installed and Gateway created"
}

# Install cert-manager
install_cert_manager() {
    check_cluster_connection
    echo_info "Installing cert-manager..."
    
    # Check dependencies
    echo_info "Checking cert-manager dependencies..."
    
    # cert-manager has minimal dependencies - mainly cluster connectivity and Helm
    # Check if Helm is available
    if ! command -v helm &> /dev/null; then
        echo_error "DEPENDENCY ERROR: Helm is required for cert-manager installation."
        echo_info "Please install Helm first or run full installation."
        exit 1
    fi
    
    echo_success "cert-manager dependencies check completed."
    
    # Add Helm repository
    helm repo add jetstack https://charts.jetstack.io || {
        echo_error "Failed to add cert-manager Helm repository."
        exit 1
    }
    
    helm repo update || {
        echo_error "Failed to update Helm repositories."
        exit 1
    }
    
    # Install cert-manager
    helm upgrade --install cert-manager jetstack/cert-manager \
        --namespace cert-manager --create-namespace \
        --set crds.enabled=true \
        --version "$CERT_MANAGER_CHART_VERSION" \
        --set resources.requests.cpu=10m \
        --set resources.requests.memory=32Mi \
        --wait --timeout 10m || {
        echo_error "Failed to install cert-manager."
        exit 1
    }
    
    echo_success "cert-manager installed successfully"
    register_installation_step "cert-manager"
}

# Create local CA issuer
create_local_ca_issuer() {
    echo_info "Creating local CA issuer for cert-manager..."
    
    local ns="cert-manager"
    local ca_cert="$CERT_DIR/tls.crt"
    local ca_key="$CERT_DIR/tls.key"
    
    # Create CA secret
    kubectl create secret tls local-ca-key-pair \
        --cert="$ca_cert" --key="$ca_key" \
        -n "$ns" --dry-run=client -o yaml | kubectl apply -f - || {
        echo_error "Failed to create CA secret for cert-manager."
        exit 1
    }
    
    # Create ClusterIssuer
    # Note: heredoc with || { } is invalid Bash syntax — the error handler must come after EOF.
    kubectl apply -f - << 'HEREDOC_EOF'
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: local-ca-issuer
spec:
  ca:
    secretName: local-ca-key-pair
HEREDOC_EOF
    # shellcheck disable=SC2181 - $? captures the heredoc kubectl apply exit code
    if [[ $? -ne 0 ]]; then
        echo_error "Failed to create ClusterIssuer for cert-manager."
        exit 1
    fi
    
    echo_success "Local CA issuer created successfully"
}

# Install Rancher Server
install_rancher_server() {
    check_cluster_connection
    echo_info "Installing Rancher Server..."
    
    # Check dependencies
    echo_info "Checking Rancher dependencies..."
    
    # Check if cert-manager is installed
    if ! kubectl get deployment cert-manager -n cert-manager &>/dev/null; then
        echo_error "DEPENDENCY ERROR: cert-manager is required for Rancher installation."
        echo_info "Please install cert-manager first: ./k8s-dev-ranch-enhanced.sh install-cert-manager"
        exit 1
    fi
    
    # Check if ClusterIssuer exists
    if ! kubectl get clusterissuer local-ca-issuer &>/dev/null; then
        echo_error "DEPENDENCY ERROR: ClusterIssuer 'local-ca-issuer' is required for Rancher installation."
        echo_info "ClusterIssuer is created automatically during full installation."
        echo_info "For individual installation, ensure CA certificates are generated first."
        exit 1
    fi
    
    # Check if CA certificates exist
    if [[ ! -f "$CERT_DIR/tls.crt" ]] || [[ ! -f "$CERT_DIR/tls.key" ]]; then
        echo_error "DEPENDENCY ERROR: CA certificates are required for Rancher installation."
        echo_info "CA certificates should be in: $CERT_DIR/"
        echo_info "Run full installation or generate certificates manually."
        exit 1
    fi
    
    echo_success "All Rancher dependencies are satisfied."
    
    # Create namespace
    kubectl create namespace cattle-system --dry-run=client -o yaml | kubectl apply -f - || {
        echo_error "Failed to create cattle-system namespace."
        exit 1
    }
    
    # Create CA secret
    if ! kubectl -n cattle-system get secret tls-ca &>/dev/null; then
        echo_info "Creating CA secret..."
        kubectl create secret generic tls-ca -n cattle-system --from-file=cacerts.pem="$CERT_DIR/tls.crt" || {
            echo_error "Failed to create CA secret."
            exit 1
        }
    fi
    
    # Create TLS certificate via cert-manager
    if ! kubectl -n nginx-gateway get secret tls-rancher-gateway &>/dev/null; then
        echo_info "Creating TLS certificate via cert-manager..."
        kubectl apply -f - << EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: rancher-tls
  namespace: nginx-gateway
spec:
  secretName: tls-rancher-gateway
  duration: 8760h # 1 year
  renewBefore: 720h # 30 days
  commonName: $RANCHER_HOSTNAME
  dnsNames:
    - $RANCHER_HOSTNAME
  issuerRef:
    name: local-ca-issuer
    kind: ClusterIssuer
EOF
        
        # Wait for certificate
        echo_info "Waiting for TLS certificate..."
        local timeout=$CERTIFICATE_TIMEOUT
        local elapsed=0
        
        while ! kubectl -n nginx-gateway get secret tls-rancher-gateway &>/dev/null; do
            if [[ $elapsed -ge $timeout ]]; then
                echo_error "Timeout waiting for TLS certificate"
                exit 1
            fi
            
            sleep 5
            elapsed=$((elapsed + 5))
            [[ "$VERBOSE" == "true" ]] && echo_info "Waiting for certificate... ($elapsed/${timeout}s)"
        done
        
        echo_success "TLS certificate ready"
    fi
    
    # Get or generate Rancher password
    # Security: Never use hardcoded passwords, always require explicit configuration or generate secure random password
    local password_file="${SCRIPT_DIR}/.rancher_password"
    
    if [[ -z "$RANCHER_PASSWORD" ]]; then
        if [[ "$NON_INTERACTIVE" == "true" ]]; then
            # Generate secure random password for non-interactive mode
            RANCHER_PASSWORD=$(generate_secure_password 20)
            
            # Save to secure file with restricted permissions
            echo "$RANCHER_PASSWORD" > "$password_file"
            chmod 600 "$password_file"
            
            echo_warn "Generated secure random password for Rancher"
            echo_warn "Password saved to: $password_file (permissions: 600)"
            echo_info "IMPORTANT: Save this password securely. It will be needed to access Rancher."
        else
            # Interactive mode: prompt user for password
            while [[ ${#RANCHER_PASSWORD} -lt 12 ]]; do
                [[ -n "$RANCHER_PASSWORD" ]] && echo_error "Password must be at least 12 characters"
                read -s -p "Enter Rancher admin password (min 12 chars): " RANCHER_PASSWORD
                echo
            done
            
            # Optionally save to file
            if prompt_confirmation "Save password to ${password_file}?"; then
                echo "$RANCHER_PASSWORD" > "$password_file"
                chmod 600 "$password_file"
                echo_info "Password saved to: $password_file"
            fi
        fi
    else
        echo_info "Using RANCHER_PASSWORD from environment variable"
    fi
    
    # Add Helm repository
    helm repo add rancher-latest https://releases.rancher.com/server-charts/latest || {
        echo_error "Failed to add Rancher Helm repository."
        exit 1
    }
    
    helm repo update || {
        echo_error "Failed to update Helm repositories."
        exit 1
    }
    
    # Install Rancher
    helm upgrade --install rancher rancher-latest/rancher \
        --namespace cattle-system \
        --version "${RANCHER_VERSION}" \
        --set hostname="$RANCHER_HOSTNAME" \
        --set bootstrapPassword="$RANCHER_PASSWORD" \
        --set ingress.enabled=false \
        --set tls=external \
        --set privateCA=true \
        --set replicas=1 \
        --set resources.requests.cpu=500m \
        --set resources.requests.memory=512Mi \
        --wait --timeout ${HELM_INSTALL_TIMEOUT}s || {
        echo_error "Failed to install Rancher Server."
        exit 1
    }
    
    echo_success "Rancher Server installed successfully"

    # Create HTTPRoute for Rancher
    echo_info "Creating HTTPRoute for Rancher..."
    cat <<EOF | kubectl apply -f -
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: rancher
  namespace: cattle-system
spec:
  parentRefs:
  - name: default-gateway
    namespace: nginx-gateway
  hostnames:
  - "${RANCHER_HOSTNAME}"
  - "localhost"
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /
    filters:
    - type: RequestHeaderModifier
      requestHeaderModifier:
        set:
        - name: X-Forwarded-Proto
          value: https
    backendRefs:
    - name: rancher
      port: 80
EOF

    register_installation_step "rancher"
    echo_info "Rancher URL: https://$RANCHER_HOSTNAME"
    echo_info "Username: admin"
    echo_info "Password: $RANCHER_PASSWORD"
}

# Configure /etc/hosts
configure_hosts() {
    echo_info "Configuring /etc/hosts..."
    
    if grep -q "$RANCHER_HOSTNAME" /etc/hosts; then
        echo_success "/etc/hosts already configured for $RANCHER_HOSTNAME"
        return 0
    fi
    
    echo "127.0.0.1 $RANCHER_HOSTNAME" | sudo tee -a /etc/hosts || {
        echo_error "Failed to configure /etc/hosts."
        exit 1
    }
    
    echo_success "/etc/hosts configured for $RANCHER_HOSTNAME"
}

# ==================== OPTIONAL COMPONENTS ====================

# Install monitoring stack
install_monitoring() {
    check_cluster_connection
    echo_info "Installing monitoring stack (Prometheus + Grafana)..."
    
    # Check dependencies
    echo_info "Checking monitoring stack dependencies..."
    
    # Check if Helm is available
    if ! command -v helm &> /dev/null; then
        echo_error "DEPENDENCY ERROR: Helm is required for monitoring stack installation."
        echo_info "Please install Helm first or run full installation."
        exit 1
    fi
    
    # Check if NGINX Gateway Fabric is installed (recommended for Grafana access)
    if ! kubectl get deployment nginx-gateway-fabric -n nginx-gateway &>/dev/null; then
        echo_warn "NGINX Gateway Fabric is not installed."
        echo_info "While not required, Gateway API is recommended for external access to Grafana."
        echo_info "Install Gateway API: ./setup-kind-cluster.sh install-gateway-api"
    fi
    
    echo_success "Monitoring stack dependencies check completed."
    
    # Add Helm repository
    helm repo add rancher-charts https://charts.rancher.io || {
        echo_error "Failed to add Rancher charts Helm repository."
        exit 1
    }
    
    helm repo update || {
        echo_error "Failed to update Helm repositories."
        exit 1
    }
    
    # Install CRDs
    helm upgrade --install rancher-monitoring-crd rancher-charts/rancher-monitoring-crd \
        --namespace cattle-monitoring-system --create-namespace \
        --version "$RANCHER_MONITORING_CHART_VERSION" \
        --wait --timeout 5m || {
        echo_error "Failed to install monitoring CRDs."
        exit 1
    }
    
    # Discover Rancher System Project ID for proper integration
    echo_info "Discovering Rancher System project ID..."
    local system_project_id
    system_project_id=$(kubectl get projects.management.cattle.io -A -o jsonpath='{.items[?(@.spec.displayName=="System")].metadata.name}' 2>/dev/null || echo "")
    
    if [ -z "$system_project_id" ]; then
        echo_warn "Could not discover Rancher System project ID. Monitoring will be installed without full Rancher UI integration."
    else
        echo_info "Discovered System project ID: $system_project_id"
    fi

    # Install monitoring stack
    helm upgrade --install rancher-monitoring rancher-charts/rancher-monitoring \
        --namespace cattle-monitoring-system \
        --version "$RANCHER_MONITORING_CHART_VERSION" \
        --set global.cattle.clusterId=local \
        --set global.cattle.clusterName=local \
        $( [ -n "$system_project_id" ] && echo "--set global.cattle.systemProjectId=$system_project_id" ) \
        --set global.cattle.url="https://$RANCHER_HOSTNAME" \
        --set prometheus.prometheusSpec.retention=10d \
        --set prometheus.prometheusSpec.resources.requests.memory=750Mi \
        --set prometheus.prometheusSpec.resources.requests.cpu=750m \
        --set prometheus.prometheusSpec.maximumStartupDurationSeconds=300 \
        --set grafana.resources.requests.memory=200Mi \
        --set grafana.resources.requests.cpu=100m \
        --wait --timeout 10m || {
        echo_error "Failed to install monitoring stack."
        exit 1
    }
    
    echo_success "Monitoring stack installed successfully"

    # Create HTTPRoute for direct Grafana access (optional but recommended)
    if kubectl get gatewayclass nginx &>/dev/null; then
        echo_info "Creating HTTPRoute for Grafana..."
        cat <<EOF | kubectl apply -f -
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: grafana
  namespace: cattle-monitoring-system
spec:
  parentRefs:
  - name: default-gateway
    namespace: nginx-gateway
  hostnames:
  - "grafana.${CLUSTER_DOMAIN}"
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /
    backendRefs:
    - name: rancher-monitoring-grafana
      port: 80
EOF
        echo_info "Grafana URL: https://grafana.${CLUSTER_DOMAIN}"
    fi

    register_installation_step "monitoring"
}

# Install metrics server
install_metrics_server() {
    check_cluster_connection
    echo_info "Installing Metrics Server..."
    
    # Check dependencies
    echo_info "Checking Metrics Server dependencies..."
    
    # Check if Helm is available
    if ! command -v helm &> /dev/null; then
        echo_error "DEPENDENCY ERROR: Helm is required for Metrics Server installation."
        echo_info "Please install Helm first or run full installation."
        exit 1
    fi
    
    echo_success "Metrics Server dependencies check completed."
    
    # Add Helm repository
    helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ || {
        echo_error "Failed to add Metrics Server Helm repository."
        exit 1
    }
    
    helm repo update || {
        echo_error "Failed to update Helm repositories."
        exit 1
    }
    
    # Install Metrics Server
    helm upgrade --install metrics-server metrics-server/metrics-server \
        -n kube-system \
        --set args[0]=--kubelet-insecure-tls \
        --set args[1]=--kubelet-preferred-address-types=InternalIP \
        --wait --timeout 5m || {
        echo_error "Failed to install Metrics Server."
        exit 1
    }
    
    echo_success "Metrics Server installed successfully"
    register_installation_step "metrics-server"
}

# ==================== VERIFICATION FUNCTIONS ====================

# Verify installation and cluster health
# This function validates that the Kubernetes cluster and all critical components are working correctly
verify_installation() {
    echo_info "Starting installation verification..."
    local failed=false
    
    # 1. Check cluster connectivity
    echo_info "Checking cluster connectivity..."
    if ! kubectl cluster-info &>/dev/null; then
        echo_error "Cannot connect to Kubernetes cluster"
        failed=true
    else
        echo_success "Cluster connectivity: OK"
    fi
    
    # 2. Check node status
    echo_info "Checking node status..."
    local not_ready_nodes
    not_ready_nodes=$(kubectl get nodes --no-headers 2>/dev/null | grep -v " Ready" | wc -l)
    
    if [[ $not_ready_nodes -gt 0 ]]; then
        echo_error "$not_ready_nodes node(s) not in Ready state"
        kubectl get nodes
        failed=true
    else
        local node_count
        node_count=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
        echo_success "All $node_count nodes are Ready"
    fi
    
    # 3. Check critical pods in kube-system
    echo_info "Checking kube-system pods..."
    local not_running_pods
    not_running_pods=$(kubectl get pods -n kube-system --no-headers 2>/dev/null | grep -v "Running\|Completed" | wc -l)
    
    if [[ $not_running_pods -gt 0 ]]; then
        echo_warn "$not_running_pods pod(s) in kube-system not running"
        kubectl get pods -n kube-system | grep -v "Running\|Completed"
    else
        echo_success "All kube-system pods are running"
    fi
    
    # 4. Check NGINX Gateway Fabric
    if kubectl get namespace nginx-gateway &>/dev/null; then
        echo_info "Checking NGINX Gateway Fabric..."
        if kubectl get deployment nginx-gateway-fabric -n nginx-gateway &>/dev/null; then
            local ready_replicas
            ready_replicas=$(kubectl get deployment nginx-gateway-fabric -n nginx-gateway -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
            
            if [[ "$ready_replicas" -ge 1 ]]; then
                echo_success "NGINX Gateway Fabric: OK ($ready_replicas replicas ready)"
            else
                echo_error "NGINX Gateway Fabric not ready"
                failed=true
            fi
        else
            echo_warn "NGINX Gateway Fabric not found"
        fi
        
        # Check Gateway Class
        if kubectl get gatewayclass nginx &>/dev/null; then
             echo_success "GatewayClass 'nginx': Found"
        else
             echo_error "GatewayClass 'nginx': Not found"
             failed=true
        fi
        
        # Check Gateway
        if kubectl get gateway default-gateway -n nginx-gateway &>/dev/null; then
             echo_success "Gateway 'default-gateway': Found"
        else
             echo_error "Gateway 'default-gateway': Not found"
             failed=true
        fi
    fi
    
    # 5. Check cert-manager
    if kubectl get namespace cert-manager &>/dev/null; then
        echo_info "Checking cert-manager..."
        if kubectl get deployment cert-manager -n cert-manager &>/dev/null; then
            local ready_replicas
            ready_replicas=$(kubectl get deployment cert-manager -n cert-manager -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
            
            if [[ "$ready_replicas" -ge 1 ]]; then
                echo_success "cert-manager: OK ($ready_replicas replicas ready)"
            else
                echo_error "cert-manager not ready"
                failed=true
            fi
        else
            echo_warn "cert-manager not found"
        fi
    fi
    
    # 6. Check Rancher
    if kubectl get namespace cattle-system &>/dev/null; then
        echo_info "Checking Rancher Server..."
        if kubectl get deployment rancher -n cattle-system &>/dev/null; then
            local ready_replicas
            ready_replicas=$(kubectl get deployment rancher -n cattle-system -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
            
            if [[ "$ready_replicas" -ge 1 ]]; then
                echo_success "Rancher Server: OK ($ready_replicas replicas ready)"
                
                # Try to access Rancher UI
                echo_info "Testing Rancher UI accessibility..."
                if curl -k -s -o /dev/null -w "%{http_code}" "https://$RANCHER_HOSTNAME" --connect-timeout 10 | grep -q "200\|301\|302"; then
                    echo_success "Rancher UI is accessible at https://$RANCHER_HOSTNAME"
                else
                    echo_warn "Rancher UI may not be accessible yet (this can take a few minutes)"
                fi
            else
                echo_error "Rancher Server not ready"
                failed=true
            fi
        else
            echo_warn "Rancher Server not found"
        fi
    fi
    
    # 7. Summary
    echo
    if [[ "$failed" == "true" ]]; then
        echo_error "Installation verification FAILED"
        echo_error "Some components are not working correctly"
        return 1
    else
        echo_success "Installation verification PASSED"
        echo_success "All critical components are working correctly"
        return 0
    fi
}

# ==================== CLEANUP FUNCTIONS ====================

cleanup_local_files() {
    echo_info "Cleaning up local files..."
    
    local files_to_remove=(
        "$KIND_CONFIG_FILE"
        "$CERT_DIR"
    )
    
    for item in "${files_to_remove[@]}"; do
        if [[ -e "$item" ]]; then
            rm -rf "$item" || {
                echo_error "Failed to remove: $item"
                exit 1
            }
            echo_info "Removed: $item"
        fi
    done
    
    # Clean up development logs
    echo_info "Cleaning up development logs..."
    local log_files=($(ls setup-k8s-*.log 2>/dev/null))
    if [ ${#log_files[@]} -gt 0 ]; then
        for log_file in "${log_files[@]}"; do
            # Skip the current log file to avoid removing it while it's being written to
            if [[ "$log_file" != "$(basename "$LOG_FILE")" ]]; then
                rm -f "$log_file"
                if [ $? -eq 0 ]; then
                    echo_info "Removed log: $log_file"
                else
                    echo_error "Failed to remove log: $log_file"
                fi
            else
                echo_info "Skipping current log file: $log_file"
            fi
        done
    else
        echo_info "No development logs found to clean"
    fi
    
    echo_success "Local files and logs cleaned up"
}

# ==================== MENU SYSTEM ====================


# Check system compatibility (for menu option)
check_system_compatibility() {
    echo
    echo_info "=== System Compatibility Check ==="
    echo
    
    local checks_passed=0
    local checks_failed=0
    local warnings=0
    
    # Check 1: Root access
    echo_info "Checking root access..."
    if [[ $EUID -eq 0 ]]; then
        echo_success "Running as root"
        ((checks_passed++))
    else
        echo_warn "Not running as root (will be required for installation)"
        ((warnings++))
    fi
    
    # Check 2: Distribution detection
    echo_info "Detecting Linux distribution..."
    detect_distro
    echo_success "Distribution: $DISTRO_ID (base: $BASE_DISTRO)"
    ((checks_passed++))
    
    # Check 3: System requirements
    echo_info "Checking system requirements..."
    
    # Memory
    local total_memory=$(free -g | awk '/^Mem:/{print $2}')
    if [[ $total_memory -ge $MIN_MEMORY_GB ]]; then
        echo_success "Memory: ${total_memory}GB (minimum: ${MIN_MEMORY_GB}GB)"
        ((checks_passed++))
    else
        echo_error "Memory: ${total_memory}GB (minimum: ${MIN_MEMORY_GB}GB required)"
        ((checks_failed++))
    fi
    
    # Disk space
    local available_disk=$(df -BG "$SCRIPT_DIR" | awk 'NR==2 {print $4}' | sed 's/G//')
    if [[ $available_disk -ge $MIN_DISK_GB ]]; then
        echo_success "Disk space: ${available_disk}GB (minimum: ${MIN_DISK_GB}GB)"
        ((checks_passed++))
    else
        echo_error "Disk space: ${available_disk}GB (minimum: ${MIN_DISK_GB}GB required)"
        ((checks_failed++))
    fi
    
    # CPU cores
    local cpu_cores=$(nproc)
    if [[ $cpu_cores -ge $MIN_CPU_CORES ]]; then
        echo_success "CPU cores: ${cpu_cores} (minimum: ${MIN_CPU_CORES})"
        ((checks_passed++))
    else
        echo_error "CPU cores: ${cpu_cores} (minimum: ${MIN_CPU_CORES} required)"
        ((checks_failed++))
    fi
    
    # Check 4: Network connectivity
    echo_info "Checking network connectivity..."
    if ping -c 1 -W 2 8.8.8.8 &>/dev/null; then
        echo_success "Network connectivity: OK"
        ((checks_passed++))
    else
        echo_error "Network connectivity: FAILED"
        ((checks_failed++))
    fi
    
    # Check 5: Port availability (non-fatal)
    echo_info "Checking port availability..."
    local ports_in_use=()
    for port in "${REQUIRED_PORTS[@]}"; do
        if lsof -Pi :$port -sTCP:LISTEN -t >/dev/null 2>&1; then
            ports_in_use+=("$port")
        fi
    done
    
    if [[ ${#ports_in_use[@]} -eq 0 ]]; then
        echo_success "All required ports available (${REQUIRED_PORTS[*]})"
        ((checks_passed++))
    else
        echo_warn "Ports in use: ${ports_in_use[*]} (may need to stop existing cluster)"
        ((warnings++))
    fi
    
    # Summary
    echo
    echo_info "=== Compatibility Check Summary ==="
    echo_success "Passed: $checks_passed"
    if [[ $warnings -gt 0 ]]; then
        echo_warn "Warnings: $warnings"
    fi
    if [[ $checks_failed -gt 0 ]]; then
        echo_error "Failed: $checks_failed"
    fi
    echo
    
    if [[ $checks_failed -eq 0 ]]; then
        if [[ $warnings -eq 0 ]]; then
            echo_success "System is fully compatible!"
        else
            echo_warn "System is compatible with warnings (see above)"
        fi
    else
        echo_error "System does not meet minimum requirements"
    fi
    echo
    
    # Don't exit, just return to menu
    read -p "Press Enter to continue..."
}

show_menu() {
    echo
    echo -e "${COLOR_MENU_TITLE}=== Kubernetes Kind + Rancher Setup Script (setup-kind-cluster.sh) v${SCRIPT_VERSION} ===${COLOR_RESET}"
    echo
    echo -e "${COLOR_MENU_TITLE}Installation Steps:${COLOR_RESET}"
    echo -e "${COLOR_MENU_OPTION} 1) Install Docker${COLOR_RESET}"
    echo -e "${COLOR_MENU_OPTION} 2) Configure Docker (systemd)${COLOR_RESET}"
    echo -e "${COLOR_MENU_OPTION} 3) Configure system (sysctl)${COLOR_RESET}"
    echo -e "${COLOR_MENU_OPTION} 4) Install kubectl${COLOR_RESET}"
    echo -e "${COLOR_MENU_OPTION} 5) Install Helm${COLOR_RESET}"
    echo -e "${COLOR_MENU_OPTION} 6) Install Kind${COLOR_RESET}"
    echo -e "${COLOR_MENU_OPTION} 7) Generate CA certificates${COLOR_RESET}"
    echo -e "${COLOR_MENU_OPTION} 8) Create Kind cluster${COLOR_RESET}"
    echo -e "${COLOR_MENU_OPTION} 9) Install Gateway API & NGF${COLOR_RESET}"
    echo -e "${COLOR_MENU_OPTION}10) Install cert-manager${COLOR_RESET}"
    echo -e "${COLOR_MENU_OPTION}11) Create local CA issuer${COLOR_RESET}"
    echo -e "${COLOR_MENU_OPTION}12) Install Rancher Server${COLOR_RESET}"
    echo -e "${COLOR_MENU_OPTION}13) Configure /etc/hosts${COLOR_RESET}"
    echo
    echo -e "${COLOR_MENU_TITLE}Batch Operations:${COLOR_RESET}"
    echo -e "${COLOR_MENU_OPTION}14) Install infrastructure  (steps 1-8:  tools + cluster)${COLOR_RESET}"
    echo -e "${COLOR_MENU_OPTION}15) Install platform        (steps 9-13: Gateway, cert-manager, Rancher)${COLOR_RESET}"
    echo -e "${COLOR_MENU_OPTION}16) Install ALL             (steps 1-13: complete environment)${COLOR_RESET}"
    echo -e "${COLOR_MENU_OPTION}17) Install complete        (steps 1-13 + monitoring)${COLOR_RESET}"
    echo
    echo -e "${COLOR_MENU_TITLE}Optional Components:${COLOR_RESET}"
    echo -e "${COLOR_MENU_OPTION}18) Install Rancher CLI${COLOR_RESET}"
    echo -e "${COLOR_MENU_OPTION}19) Install monitoring (Prometheus + Grafana)${COLOR_RESET}"
    echo -e "${COLOR_MENU_OPTION}20) Install Metrics Server${COLOR_RESET}"
    echo
    echo -e "${COLOR_MENU_TITLE}Cluster Management:${COLOR_RESET}"
    echo -e "${COLOR_MENU_OPTION}21) Start Kind cluster${COLOR_RESET}"
    echo -e "${COLOR_MENU_OPTION}22) Stop Kind cluster${COLOR_RESET}"
    echo -e "${COLOR_MENU_OPTION}23) Show cluster status${COLOR_RESET}"
    echo
    echo -e "${COLOR_WARN}Cleanup Operations:${COLOR_RESET}"
    echo -e "${COLOR_MENU_OPTION}24) Remove Kind cluster${COLOR_RESET}"
    echo -e "${COLOR_MENU_OPTION}25) Clean up local files${COLOR_RESET}"
    echo
    echo -e "${COLOR_MENU_TITLE}Verification:${COLOR_RESET}"
    echo -e "${COLOR_MENU_OPTION}26) Verify installation${COLOR_RESET}"
    echo -e "${COLOR_MENU_OPTION}27) Check system compatibility${COLOR_RESET}"
    echo
    echo -e "${COLOR_MENU_TITLE}Configuration:${COLOR_RESET}"
    echo -e "${COLOR_MENU_OPTION}28) Change cluster name (current: ${CLUSTER_NAME}) [pre-install only]${COLOR_RESET}"
    echo
    echo -e "${COLOR_MENU_OPTION} 0) Exit${COLOR_RESET}"
    echo
    printf "%bChoose an option: %b" "$COLOR_PROMPT" "$COLOR_RESET"
}

show_cluster_status() {
    echo_info "Cluster Status Information:"
    echo
    
    # Kind clusters
    echo -e "${COLOR_INFO}Kind Clusters:${COLOR_RESET}"
    if kind get clusters 2>/dev/null | grep -q .; then
        kind get clusters 2>/dev/null | sed 's/^/  - /'
    else
        echo "  No Kind clusters found"
    fi
    echo
    
    # Docker containers
    echo -e "${COLOR_INFO}Kind Containers:${COLOR_RESET}"
    local containers
    containers=$(docker ps -a --filter "label=io.x-k8s.kind.cluster" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null)
    if [[ -n "$containers" ]]; then
        echo "$containers"
    else
        echo "  No Kind containers found"
    fi
    echo
    
    # Kubernetes context
    echo -e "${COLOR_INFO}Kubernetes Context:${COLOR_RESET}"
    if kubectl config current-context 2>/dev/null; then
        echo
        echo -e "${COLOR_INFO}Cluster Info:${COLOR_RESET}"
        kubectl cluster-info 2>/dev/null || echo "  Cannot connect to cluster"
    else
        echo "  No active Kubernetes context"
    fi
}

# ==================== COMMAND LINE INTERFACE ====================

show_help() {
    cat << EOF
Kubernetes Kind + Rancher Setup Script v${SCRIPT_VERSION}

USAGE:
    $SCRIPT_NAME [OPTIONS] [COMMAND]

COMMANDS:
    install-infra       Install infrastructure (steps 1-9: tools + cluster)
    install-platform    Install platform (steps 10-14: Gateway, cert-manager, Rancher)
    install-all         Install complete environment (steps 1-14)
    install-full        Install complete environment with monitoring
    install-docker      Install Docker
    install-kubectl     Install kubectl
    install-helm        Install Helm
    install-kind        Install Kind
    install-rancher-cli Install Rancher CLI
    create-cluster      Create Kind cluster
    install-gateway-api Install Gateway API & NGF
    install-cert-manager Install cert-manager
    install-rancher     Install Rancher Server
    install-monitoring  Install monitoring stack
    install-metrics     Install Metrics Server
    start-cluster       Start Kind cluster
    stop-cluster        Stop Kind cluster
    remove-cluster      Remove Kind cluster
    cleanup             Clean up local files
    status              Show cluster status
    verify              Verify installation and cluster health
    rollback            Rollback partial installation (undo completed steps)
    menu                Show interactive menu (default)

OPTIONS:
    -h, --help          Show this help message
    -v, --version       Show version information
    --verbose           Enable verbose output
    --non-interactive   Run in non-interactive mode
    --dry-run           Show commands without executing
    --force-reinstall   Force reinstallation of existing tools
    --skip-prereqs      Skip system requirements check
    --cluster-name NAME Set cluster name (default: k8s-cluster)
    --cluster-domain DOMAIN Set cluster domain (default: cluster.test)
    --worker-nodes N    Set number of worker nodes (default: 2)
    --no-rollback       Disable automatic rollback on failure

ENVIRONMENT VARIABLES:
    CLUSTER_NAME        Cluster name
    CLUSTER_DOMAIN      Cluster domain
    RANCHER_PASSWORD    Rancher admin password (auto-generated if not set)
    WORKER_NODES        Number of worker nodes
    NON_INTERACTIVE     Non-interactive mode (true/false)
    VERBOSE             Verbose output (true/false)
    LOG_LEVEL           Log level: 0=DEBUG, 1=INFO, 2=WARNING, 3=ERROR (default: 1, or 0 if VERBOSE=true)
    DRY_RUN             Dry run mode (true/false)
    FORCE_REINSTALL     Force reinstall (true/false)
    SKIP_PREREQS        Skip prerequisites (true/false)
    DISABLE_IPV6        Disable IPv6 for Kind compatibility (true/false, default: true)
    ROLLBACK_ENABLED    Enable automatic rollback on failure (true/false, default: true)
    CLUSTER_START_TIMEOUT    Timeout for cluster startup in seconds (default: 120)
    CERTIFICATE_TIMEOUT      Timeout for certificate generation in seconds (default: 300)
    HELM_INSTALL_TIMEOUT     Timeout for Helm installations in seconds (default: 600)

EXAMPLES:
    # Interactive menu
    $SCRIPT_NAME
    
    # Install only infrastructure (tools + cluster)
    $SCRIPT_NAME install-infra
    
    # Install only platform (requires cluster already running)
    $SCRIPT_NAME install-platform
    
    # Install complete environment
    $SCRIPT_NAME install-all
    
    # Install with custom cluster name
    $SCRIPT_NAME --cluster-name my-cluster install-all
    
    # Non-interactive installation
    $SCRIPT_NAME --non-interactive install-full
    
    # Dry run to see what would be executed
    $SCRIPT_NAME --dry-run install-infra

EOF
}

show_version() {
    echo "Kubernetes Kind + Rancher Setup Script v${SCRIPT_VERSION}"
}

# Parse command line arguments
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_help
                exit 0
                ;;
            -v|--version)
                show_version
                exit 0
                ;;
            --verbose)
                VERBOSE="true"
                shift
                ;;
            --non-interactive)
                NON_INTERACTIVE="true"
                shift
                ;;
            --dry-run)
                DRY_RUN="true"
                shift
                ;;
            --force-reinstall)
                FORCE_REINSTALL="true"
                shift
                ;;
            --skip-prereqs)
                SKIP_PREREQS="true"
                shift
                ;;
            --cluster-name)
                CLUSTER_NAME="$2"
                RANCHER_HOSTNAME="rancher.${CLUSTER_DOMAIN}"
                echo_debug "Cluster name set to: $CLUSTER_NAME (hostname: $RANCHER_HOSTNAME)"
                shift 2
                ;;
            --cluster-domain)
                CLUSTER_DOMAIN="$2"
                RANCHER_HOSTNAME="rancher.${CLUSTER_DOMAIN}"
                echo_debug "Cluster domain set to: $CLUSTER_DOMAIN (hostname: $RANCHER_HOSTNAME)"
                shift 2
                ;;
            --worker-nodes)
                WORKER_NODES="$2"
                shift 2
                ;;
            install-infra)
                COMMAND="install_infra"
                shift
                ;;
            install-platform)
                COMMAND="install_platform"
                shift
                ;;
            install-all)
                COMMAND="install_all"
                shift
                ;;
            install-full)
                COMMAND="install_full"
                shift
                ;;
            install-docker)
                COMMAND="install_docker"
                shift
                ;;
            install-kubectl)
                COMMAND="install_kubectl"
                shift
                ;;
            install-helm)
                COMMAND="install_helm"
                shift
                ;;
            install-kind)
                COMMAND="install_kind"
                shift
                ;;
            install-rancher-cli)
                COMMAND="install_rancher_cli"
                shift
                ;;
            create-cluster)
                COMMAND="create_kind_cluster"
                shift
                ;;
            install-gateway-api)
                COMMAND="install_gateway_api"
                shift
                ;;
            install-cert-manager)
                COMMAND="install_cert_manager"
                shift
                ;;
            install-rancher)
                COMMAND="install_rancher_server"
                shift
                ;;
            install-monitoring)
                COMMAND="install_monitoring"
                shift
                ;;
            install-metrics)
                COMMAND="install_metrics_server"
                shift
                ;;
            start-cluster)
                COMMAND="start_kind_cluster"
                shift
                ;;
            stop-cluster)
                COMMAND="stop_kind_cluster"
                shift
                ;;
            remove-cluster)
                COMMAND="remove_kind_cluster"
                shift
                ;;
            cleanup)
                COMMAND="cleanup_local_files"
                shift
                ;;
            status)
                COMMAND="show_cluster_status"
                shift
                ;;
            verify)
                COMMAND="verify_installation"
                shift
                ;;
            rollback)
                COMMAND="rollback_installation"
                shift
                ;;
            --no-rollback)
                ROLLBACK_ENABLED="false"
                shift
                ;;
            menu)
                COMMAND="interactive_menu"
                shift
                ;;
            *)
                echo_error "Unknown option: $1"
                echo_info "Use --help for usage information"
                exit 1
                ;;
        esac
    done
}

# ==================== BATCH OPERATIONS ====================

install_infra() {
    echo_info "Installing infrastructure (steps 1-8: tools + Kind cluster)..."
    
    install_docker
    configure_docker_systemd
    configure_sysctl
    install_kubectl
    install_helm
    install_kind
    generate_ca_certificates
    create_kind_cluster
    
    echo_success "Infrastructure installed successfully!"
    echo_info "Kind cluster '${CLUSTER_NAME}' is ready."
    echo_info "Next step: run 'install-platform' to deploy Gateway API, cert-manager and Rancher."
    echo_warn "If user was added to docker group, restart terminal session before continuing."
}

install_platform() {
    echo_info "Installing platform (steps 9-13: Gateway API, cert-manager, Rancher)..."
    
    install_gateway_api
    install_cert_manager
    create_local_ca_issuer
    install_rancher_server
    configure_hosts
    
    echo_success "Platform installed successfully!"
    echo_info "Rancher URL: https://$RANCHER_HOSTNAME"
    echo_info "Gateway API & NGF installed and listening on ports 80/443"
}

install_all() {
    echo_info "Installing complete Kubernetes environment (steps 1-13)..."
    
    install_infra
    install_platform
    
    echo_success "Complete environment installed successfully!"
    echo_info "Rancher URL: https://$RANCHER_HOSTNAME"
}

install_full() {
    echo_info "Installing complete environment with monitoring..."
    
    install_all
    install_monitoring
    install_metrics_server
    
    echo_success "Full environment with monitoring installed successfully!"
}

# Interactive menu loop
interactive_menu() {
    while true; do
        show_menu
        read -r option
        
        case $option in
            1) install_docker ;;
            2) configure_docker_systemd ;;
            3) configure_sysctl ;;
            4) install_kubectl ;;
            5) install_helm ;;
            6) install_kind ;;
            7) generate_ca_certificates ;;
            8) create_kind_cluster ;;
            9) install_gateway_api ;;
            10) install_cert_manager ;;
            11) create_local_ca_issuer ;;
            12) install_rancher_server ;;
            13) configure_hosts ;;
            14) install_infra ;;
            15) install_platform ;;
            16) install_all ;;
            17) install_full ;;
            18) install_rancher_cli ;;
            19) install_monitoring ;;
            20) install_metrics_server ;;
            21) start_kind_cluster ;;
            22) stop_kind_cluster ;;
            23) show_cluster_status ;;
            24) remove_kind_cluster ;;
            25) cleanup_local_files ;;
            26) verify_installation ;;
            27)
                echo
                echo_info "=== System Compatibility Check ==="
                echo
                check_root
                detect_distro
                check_system_requirements
                check_network
                
                # Check ports without exiting on error
                echo_info "Checking port availability..."
                local ports_in_use=()
                for port in "${REQUIRED_PORTS[@]}"; do
                    if is_port_in_use "$port"; then
                        ports_in_use+=("$port")
                    fi
                done
                
                if [[ ${#ports_in_use[@]} -eq 0 ]]; then
                    echo_success "All required ports available (${REQUIRED_PORTS[*]})"
                else
                    if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
                         echo_warn "Ports in use: ${ports_in_use[*]} (used by existing Kind cluster '${CLUSTER_NAME}')"
                         echo_info "  Tip: Use option 24 (Remove Kind cluster) to free these ports"
                    else
                         echo_warn "Ports in use: ${ports_in_use[*]} (occupied by another application)"
                         echo_info "  Action required: Stop the service using these ports before installation"
                    fi
                fi
                
                echo
                echo_success "System compatibility check completed"
                echo
                ;;
            28)
                echo
                echo_warn "This changes the cluster name for this session only."
                echo_warn "It does NOT rename an existing Kind cluster."
                echo_info "Use this option BEFORE running installation steps."
                echo
                echo_info "Current cluster name: $CLUSTER_NAME"
                printf "%bEnter new cluster name (leave empty to keep current): %b" "$COLOR_PROMPT" "$COLOR_RESET"
                read -r new_name
                if [[ -n "$new_name" ]]; then
                    CLUSTER_NAME="$new_name"
                    RANCHER_HOSTNAME="rancher.${CLUSTER_DOMAIN}"
                    KIND_CONFIG_FILE="${SCRIPT_DIR}/${CLUSTER_NAME}-kind-config.yaml"
                    echo_info "Cluster name set to: $CLUSTER_NAME"
                    echo_info "Rancher hostname: $RANCHER_HOSTNAME"
                else
                    echo_info "Cluster name unchanged: $CLUSTER_NAME"
                fi
                echo
                ;;
            0)
                echo_success "Exiting script"
                exit 0
                ;;
            *)
                echo_warn "Invalid option. Please try again."
                ;;
        esac
        
        echo
        if [[ "$NON_INTERACTIVE" != "true" ]]; then
            read -p "Press Enter to continue..." -r
        fi
    done
}

# ==================== MAIN EXECUTION ====================

main() {
    # Initialize logging
    echo_info "Starting Kubernetes Kind + Rancher Setup Script v${SCRIPT_VERSION}"
    echo_info "Log file: $LOG_FILE"
    
    # Parse command line arguments
    parse_arguments "$@"
    
    # Execute command or show interactive menu
    if [[ -n "${COMMAND:-}" ]]; then
        # Perform checks only when executing a command
        check_root
        detect_distro
        
        # Check system requirements unless skipped
        if [[ "$SKIP_PREREQS" != "true" ]]; then
            check_system_requirements
            check_network
            
            # Skip port checks for cluster removal operations
            if [[ "${COMMAND:-}" != "remove_kind_cluster" ]]; then
                check_ports
            fi
        fi
        
        echo_info "Executing command: $COMMAND"
        "$COMMAND"
    else
        # Show menu without prerequisite checks
        interactive_menu
    fi
}

# Execute main function with all arguments
main "$@"