#!/usr/bin/env bash
# =============================================================================
# PayStream Authorization Service - Cluster Setup Script
# =============================================================================
# Automated setup for local Kubernetes development environment.
# Installs all required tools, starts Minikube, and configures
# Istio Ambient Mesh, Argo Rollouts, and External Secrets Operator.
#
# Usage: ./setup.sh
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Color definitions
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ---------------------------------------------------------------------------
# Helper functions
# ---------------------------------------------------------------------------
info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

success() {
    echo -e "${GREEN}[OK]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error_exit() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
    exit 1
}

check_command() {
    command -v "$1" &>/dev/null
}

# ---------------------------------------------------------------------------
# Detect operating system
# ---------------------------------------------------------------------------
detect_os() {
    info "Detecting operating system..."
    OS_TYPE="$(uname -s)"
    case "${OS_TYPE}" in
        Darwin)
            OS="macos"
            success "Detected macOS (Darwin)"
            ;;
        Linux)
            OS="linux"
            success "Detected Linux"
            ;;
        *)
            error_exit "Unsupported operating system: ${OS_TYPE}. Only macOS and Linux are supported."
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Package manager helpers
# ---------------------------------------------------------------------------
brew_install() {
    local formula="$1"
    if ! brew list --formula "$formula" &>/dev/null; then
        info "Installing ${formula} via Homebrew..."
        brew install "$formula"
    else
        success "${formula} is already installed via Homebrew"
    fi
}

apt_install() {
    local package="$1"
    if ! dpkg -l "$package" 2>/dev/null | grep -q "^ii"; then
        info "Installing ${package} via apt..."
        sudo apt-get update -qq
        sudo apt-get install -y "$package"
    else
        success "${package} is already installed via apt"
    fi
}

# ---------------------------------------------------------------------------
# Tool installation functions
# ---------------------------------------------------------------------------
install_docker() {
    if check_command docker; then
        success "docker is already installed ($(docker --version))"
        return
    fi
    info "Installing Docker..."
    case "${OS}" in
        macos)
            brew install --cask docker
            warn "Docker Desktop installed. Please start Docker Desktop manually if it is not running."
            ;;
        linux)
            sudo apt-get update -qq
            sudo apt-get install -y ca-certificates curl gnupg lsb-release
            sudo mkdir -p /etc/apt/keyrings
            curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg 2>/dev/null || true
            echo \
                "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
                $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
            sudo apt-get update -qq
            sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
            sudo usermod -aG docker "${USER}" || true
            ;;
    esac
    success "Docker installed successfully"
}

install_minikube() {
    if check_command minikube; then
        success "minikube is already installed ($(minikube version --short 2>/dev/null || echo 'version unknown'))"
        return
    fi
    info "Installing Minikube..."
    case "${OS}" in
        macos)
            brew_install minikube
            ;;
        linux)
            local arch
            arch="$(dpkg --print-architecture 2>/dev/null || echo amd64)"
            curl -LO "https://storage.googleapis.com/minikube/releases/latest/minikube-linux-${arch}"
            sudo install "minikube-linux-${arch}" /usr/local/bin/minikube
            rm -f "minikube-linux-${arch}"
            ;;
    esac
    success "Minikube installed successfully"
}

install_kubectl() {
    if check_command kubectl; then
        success "kubectl is already installed ($(kubectl version --client --short 2>/dev/null || kubectl version --client 2>/dev/null | head -1))"
        return
    fi
    info "Installing kubectl..."
    case "${OS}" in
        macos)
            brew_install kubectl
            ;;
        linux)
            local arch
            arch="$(dpkg --print-architecture 2>/dev/null || echo amd64)"
            local version
            version="$(curl -L -s https://dl.k8s.io/release/stable.txt)"
            curl -LO "https://dl.k8s.io/release/${version}/bin/linux/${arch}/kubectl"
            sudo install kubectl /usr/local/bin/kubectl
            rm -f kubectl
            ;;
    esac
    success "kubectl installed successfully"
}

install_istioctl() {
    if check_command istioctl; then
        success "istioctl is already installed ($(istioctl version --remote=false 2>/dev/null || echo 'version unknown'))"
        return
    fi
    info "Installing istioctl..."
    case "${OS}" in
        macos)
            brew_install istioctl
            ;;
        linux)
            curl -L https://istio.io/downloadIstio | sh - 2>/dev/null
            local istio_dir
            istio_dir="$(ls -d istio-* 2>/dev/null | sort -V | tail -1)"
            if [[ -n "${istio_dir}" ]]; then
                sudo install "${istio_dir}/bin/istioctl" /usr/local/bin/istioctl
                rm -rf "${istio_dir}"
            else
                error_exit "Failed to download Istio. Please install istioctl manually."
            fi
            ;;
    esac
    success "istioctl installed successfully"
}

install_argo_rollouts_plugin() {
    if check_command kubectl-argo-rollouts; then
        success "kubectl-argo-rollouts is already installed"
        return
    fi
    info "Installing kubectl-argo-rollouts plugin..."
    case "${OS}" in
        macos)
            brew install argoproj/tap/kubectl-argo-rollouts
            ;;
        linux)
            local arch
            arch="$(uname -m)"
            if [[ "${arch}" == "x86_64" ]]; then arch="amd64"; fi
            if [[ "${arch}" == "aarch64" ]]; then arch="arm64"; fi
            curl -LO "https://github.com/argoproj/argo-rollouts/releases/latest/download/kubectl-argo-rollouts-linux-${arch}"
            chmod +x "kubectl-argo-rollouts-linux-${arch}"
            sudo mv "kubectl-argo-rollouts-linux-${arch}" /usr/local/bin/kubectl-argo-rollouts
            ;;
    esac
    success "kubectl-argo-rollouts plugin installed successfully"
}

install_terraform() {
    if check_command terraform; then
        success "terraform is already installed ($(terraform version -json 2>/dev/null | jq -r '.terraform_version' 2>/dev/null || terraform version | head -1))"
        return
    fi
    info "Installing Terraform..."
    case "${OS}" in
        macos)
            brew_install terraform
            ;;
        linux)
            sudo apt-get update -qq && sudo apt-get install -y gnupg software-properties-common
            curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg 2>/dev/null || true
            echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
                | sudo tee /etc/apt/sources.list.d/hashicorp.list >/dev/null
            sudo apt-get update -qq
            sudo apt-get install -y terraform
            ;;
    esac
    success "Terraform installed successfully"
}

install_terragrunt() {
    if check_command terragrunt; then
        success "terragrunt is already installed ($(terragrunt --version 2>/dev/null | head -1))"
        return
    fi
    info "Installing Terragrunt..."
    case "${OS}" in
        macos)
            brew_install terragrunt
            ;;
        linux)
            local arch
            arch="$(uname -m)"
            if [[ "${arch}" == "x86_64" ]]; then arch="amd64"; fi
            if [[ "${arch}" == "aarch64" ]]; then arch="arm64"; fi
            local tg_version
            tg_version="$(curl -s https://api.github.com/repos/gruntwork-io/terragrunt/releases/latest | jq -r '.tag_name')"
            curl -LO "https://github.com/gruntwork-io/terragrunt/releases/download/${tg_version}/terragrunt_linux_${arch}"
            chmod +x "terragrunt_linux_${arch}"
            sudo mv "terragrunt_linux_${arch}" /usr/local/bin/terragrunt
            ;;
    esac
    success "Terragrunt installed successfully"
}

install_gh() {
    if check_command gh; then
        success "gh (GitHub CLI) is already installed ($(gh --version | head -1))"
        return
    fi
    info "Installing GitHub CLI (gh)..."
    case "${OS}" in
        macos)
            brew_install gh
            ;;
        linux)
            sudo mkdir -p -m 755 /etc/apt/keyrings
            curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null
            sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
                | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
            sudo apt-get update -qq
            sudo apt-get install -y gh
            ;;
    esac
    success "GitHub CLI installed successfully"
}

install_basic_tools() {
    local tools=("jq" "curl" "git")
    for tool in "${tools[@]}"; do
        if check_command "$tool"; then
            success "${tool} is already installed"
        else
            info "Installing ${tool}..."
            case "${OS}" in
                macos)
                    brew_install "$tool"
                    ;;
                linux)
                    apt_install "$tool"
                    ;;
            esac
            success "${tool} installed successfully"
        fi
    done
}

install_kubeconform() {
    if check_command kubeconform; then
        success "kubeconform is already installed ($(kubeconform -v 2>/dev/null || echo 'version unknown'))"
        return
    fi
    info "Installing kubeconform..."
    case "${OS}" in
        macos)
            brew_install kubeconform
            ;;
        linux)
            local arch
            arch="$(uname -m)"
            if [[ "${arch}" == "x86_64" ]]; then arch="amd64"; fi
            if [[ "${arch}" == "aarch64" ]]; then arch="arm64"; fi
            local kc_version
            kc_version="$(curl -s https://api.github.com/repos/yannh/kubeconform/releases/latest | jq -r '.tag_name')"
            curl -LO "https://github.com/yannh/kubeconform/releases/download/${kc_version}/kubeconform-linux-${arch}.tar.gz"
            tar xzf "kubeconform-linux-${arch}.tar.gz" kubeconform
            sudo install kubeconform /usr/local/bin/kubeconform
            rm -f kubeconform "kubeconform-linux-${arch}.tar.gz"
            ;;
    esac
    success "kubeconform installed successfully"
}

# ---------------------------------------------------------------------------
# Cluster setup functions
# ---------------------------------------------------------------------------
start_minikube() {
    info "Checking Minikube cluster status..."

    if minikube status --format='{{.Host}}' 2>/dev/null | grep -q "Running"; then
        success "Minikube cluster is already running"
        return
    fi

    info "Starting Minikube cluster (4 CPUs, 8GB RAM, docker driver)..."
    minikube start --cpus=4 --memory=8192 --driver=docker

    # Wait for the cluster to be ready
    info "Waiting for cluster to be ready..."
    kubectl wait --for=condition=Ready nodes --all --timeout=120s

    success "Minikube cluster started successfully"
}

install_istio_ambient() {
    info "Checking Istio installation..."

    # Verify ambient mode specifically by checking for ztunnel DaemonSet
    if kubectl get daemonset ztunnel -n istio-system &>/dev/null; then
        success "Istio Ambient Mesh is already installed (ztunnel DaemonSet found)"
        return
    fi

    if kubectl get namespace istio-system &>/dev/null; then
        local istio_pods
        istio_pods="$(kubectl get pods -n istio-system --no-headers 2>/dev/null | wc -l | tr -d ' ')"
        if [[ "${istio_pods}" -gt 0 ]]; then
            warn "Istio is installed but NOT in ambient mode. Reinstalling with ambient profile..."
            istioctl uninstall --purge -y 2>/dev/null
        fi
    fi

    info "Installing Istio with Ambient Mesh profile..."
    istioctl install --set profile=ambient -y

    info "Waiting for Istio pods to be ready..."
    if ! kubectl wait --for=condition=Ready pods --all -n istio-system --timeout=300s; then
        error_exit "Istio pods failed to become ready within 300 seconds"
    fi

    success "Istio Ambient Mesh installed successfully"
}

install_argo_rollouts() {
    info "Checking Argo Rollouts installation..."

    if kubectl get namespace argo-rollouts &>/dev/null; then
        local argo_pods
        argo_pods="$(kubectl get pods -n argo-rollouts --no-headers 2>/dev/null | wc -l | tr -d ' ')"
        if [[ "${argo_pods}" -gt 0 ]]; then
            success "Argo Rollouts is already installed (${argo_pods} pods in argo-rollouts)"
            return
        fi
    fi

    info "Creating argo-rollouts namespace..."
    kubectl create namespace argo-rollouts 2>/dev/null || true

    info "Installing Argo Rollouts..."
    kubectl apply -n argo-rollouts -f https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml

    info "Waiting for Argo Rollouts pods to be ready..."
    if ! kubectl wait --for=condition=Ready pods --all -n argo-rollouts --timeout=180s; then
        error_exit "Argo Rollouts pods failed to become ready within 180 seconds"
    fi

    success "Argo Rollouts installed successfully"
}

install_external_secrets_operator() {
    info "Checking External Secrets Operator installation..."

    if kubectl get namespace external-secrets &>/dev/null; then
        local eso_pods
        eso_pods="$(kubectl get pods -n external-secrets --no-headers 2>/dev/null | wc -l | tr -d ' ')"
        if [[ "${eso_pods}" -gt 0 ]]; then
            success "External Secrets Operator is already installed (${eso_pods} pods in external-secrets)"
            return
        fi
    fi

    info "Creating external-secrets namespace..."
    kubectl create namespace external-secrets 2>/dev/null || true

    info "Installing External Secrets Operator (v0.10.7)..."
    local ESO_VERSION="v0.10.7"
    if ! kubectl apply -f "https://raw.githubusercontent.com/external-secrets/external-secrets/${ESO_VERSION}/deploy/crds/bundle.yaml"; then
        warn "Failed to apply ESO CRDs. Continuing — ESO is optional for local development."
        return
    fi
    if ! kubectl apply -f "https://raw.githubusercontent.com/external-secrets/external-secrets/${ESO_VERSION}/deploy/manifests/external-secrets.yaml"; then
        warn "Failed to apply ESO manifests. Continuing — ESO is optional for local development."
        return
    fi

    info "Waiting for External Secrets Operator pods to be ready..."
    if ! kubectl wait --for=condition=Ready pods --all -n external-secrets --timeout=180s; then
        warn "External Secrets Operator pods did not become ready within 180 seconds"
    fi

    success "External Secrets Operator installed successfully"
}

# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------
verify_components() {
    info "Verifying all components..."
    echo ""

    local all_healthy=true

    # Check Minikube
    if minikube status --format='{{.Host}}' 2>/dev/null | grep -q "Running"; then
        success "Minikube: Running"
    else
        warn "Minikube: Not running"
        all_healthy=false
    fi

    # Check istio-system pods
    info "Pods in istio-system:"
    if kubectl get pods -n istio-system --no-headers 2>/dev/null | grep -q "."; then
        kubectl get pods -n istio-system 2>/dev/null
        success "Istio: Installed"
    else
        warn "Istio: No pods found in istio-system"
        all_healthy=false
    fi
    echo ""

    # Check argo-rollouts pods
    info "Pods in argo-rollouts:"
    if kubectl get pods -n argo-rollouts --no-headers 2>/dev/null | grep -q "."; then
        kubectl get pods -n argo-rollouts 2>/dev/null
        success "Argo Rollouts: Installed"
    else
        warn "Argo Rollouts: No pods found in argo-rollouts"
        all_healthy=false
    fi
    echo ""

    # Check external-secrets pods
    info "Pods in external-secrets:"
    if kubectl get pods -n external-secrets --no-headers 2>/dev/null | grep -q "."; then
        kubectl get pods -n external-secrets 2>/dev/null
        success "External Secrets Operator: Installed"
    else
        warn "External Secrets Operator: No pods found in external-secrets"
        all_healthy=false
    fi
    echo ""

    if [[ "${all_healthy}" == true ]]; then
        success "All components are healthy!"
    else
        warn "Some components may need attention. Review the output above."
    fi
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
show_summary() {
    echo ""
    echo -e "${GREEN}=============================================================================${NC}"
    echo -e "${GREEN}  PayStream Authorization Service - Cluster Setup Complete${NC}"
    echo -e "${GREEN}=============================================================================${NC}"
    echo ""
    echo -e "${BLUE}Installed tools:${NC}"
    echo -e "  docker          : $(docker --version 2>/dev/null || echo 'not found')"
    echo -e "  minikube        : $(minikube version --short 2>/dev/null || echo 'not found')"
    echo -e "  kubectl         : $(kubectl version --client --short 2>/dev/null || kubectl version --client 2>/dev/null | head -1 || echo 'not found')"
    echo -e "  istioctl        : $(istioctl version --remote=false 2>/dev/null || echo 'not found')"
    echo -e "  argo-rollouts   : $(kubectl-argo-rollouts version --short 2>/dev/null || echo 'not found')"
    echo -e "  terraform       : $(terraform version -json 2>/dev/null | jq -r '.terraform_version' 2>/dev/null || terraform version 2>/dev/null | head -1 || echo 'not found')"
    echo -e "  terragrunt      : $(terragrunt --version 2>/dev/null | head -1 || echo 'not found')"
    echo -e "  gh              : $(gh --version 2>/dev/null | head -1 || echo 'not found')"
    echo -e "  jq              : $(jq --version 2>/dev/null || echo 'not found')"
    echo -e "  curl            : $(curl --version 2>/dev/null | head -1 || echo 'not found')"
    echo -e "  git             : $(git --version 2>/dev/null || echo 'not found')"
    echo -e "  kubeconform     : $(kubeconform -v 2>/dev/null || echo 'not found')"
    echo ""
    echo -e "${BLUE}Cluster status:${NC}"
    echo -e "  Minikube        : $(minikube status --format='{{.Host}}' 2>/dev/null || echo 'not running')"
    echo -e "  Kubernetes      : $(kubectl cluster-info 2>/dev/null | head -1 || echo 'not available')"
    echo ""
    echo -e "${BLUE}Namespaces:${NC}"
    kubectl get namespaces 2>/dev/null || echo "  Unable to retrieve namespaces"
    echo ""
    echo -e "${GREEN}=============================================================================${NC}"
    echo -e "${GREEN}  Setup complete! You can now deploy the PayStream services.${NC}"
    echo -e "${GREEN}=============================================================================${NC}"
    echo ""
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    echo ""
    echo -e "${BLUE}=============================================================================${NC}"
    echo -e "${BLUE}  PayStream Authorization Service - Automated Cluster Setup${NC}"
    echo -e "${BLUE}=============================================================================${NC}"
    echo ""

    # Step 1: Detect OS
    detect_os
    echo ""

    # Step 2: Pre-flight checks
    if [[ "${OS}" == "macos" ]] && ! check_command brew; then
        error_exit "Homebrew is required on macOS but not installed. Install it from https://brew.sh"
    fi

    # Step 3: Install required tools
    info "--- Installing required tools ---"
    echo ""
    install_basic_tools
    echo ""
    install_docker
    echo ""

    # Verify Docker daemon is running before proceeding
    if ! docker info &>/dev/null; then
        error_exit "Docker daemon is not running. Start Docker Desktop first, then re-run this script."
    fi
    success "Docker daemon is running"
    echo ""
    install_minikube
    echo ""
    install_kubectl
    echo ""
    install_istioctl
    echo ""
    install_argo_rollouts_plugin
    echo ""
    install_terraform
    echo ""
    install_terragrunt
    echo ""
    install_gh
    echo ""
    install_kubeconform
    echo ""

    # Step 3: Start Minikube
    info "--- Setting up Kubernetes cluster ---"
    echo ""
    start_minikube
    echo ""

    # Step 4: Install Istio Ambient Mesh
    info "--- Installing cluster components ---"
    echo ""
    install_istio_ambient
    echo ""

    # Step 5: Install Argo Rollouts
    install_argo_rollouts
    echo ""

    # Step 6: Install External Secrets Operator
    install_external_secrets_operator
    echo ""

    # Step 7: Verify components
    info "--- Verifying installation ---"
    echo ""
    verify_components

    # Step 8: Show summary
    show_summary
}

main "$@"
