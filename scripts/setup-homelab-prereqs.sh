#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  setup-homelab-prereqs.sh \
    --github-owner <owner> \
    --github-repo <repo> \
    --smb-username <username> \
    [--audiobookshelf-api-key <key>] \
    [--github-branch <branch>] \
    [--flux-path <path>] \
    [--media-namespace <namespace>] \
    [--smb-secret-name <secret>] \
    [--homepage-secret-name <secret>] \
    [--smb-password <password>] \
    [--smb-password-stdin] \
    [--github-personal <true|false>] \
    [--skip-k3s]

Required environment variable:
  GITHUB_TOKEN  GitHub token used by 'flux bootstrap github'

Options:
  --skip-k3s    Skip k3s installation (use when k3s is already installed).
EOF
}

GITHUB_OWNER=""
GITHUB_REPO=""
GITHUB_BRANCH="main"
FLUX_PATH="clusters/homelab"
SMB_USERNAME=""
SMB_PASSWORD=""
SMB_PASSWORD_STDIN="false"
MEDIA_NAMESPACE="media"
SMB_SECRET_NAME="media-smb-credentials"
HOMEPAGE_SECRET_NAME="homepage-secrets"
AUDIOBOOKSHELF_API_KEY=""
GITHUB_PERSONAL="true"
SKIP_K3S="false"
FLUX_INSTALL_SCRIPT_URL="https://raw.githubusercontent.com/fluxcd/flux2/v2.6.4/install/flux.sh"
FLUX_INSTALL_SCRIPT_SHA256="bd7765225b731a1df952456eced0abb5dbbf5e11bc70cf6ab5fddd1476088b7e"
HELM_INSTALL_SCRIPT_URL="https://raw.githubusercontent.com/helm/helm/v3.17.3/scripts/get-helm-3"
HELM_INSTALL_SCRIPT_SHA256="4a01413bf2a767ae744b8bbe4485cd83654d9a0a769c92377afc36328d5a007a"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --github-owner) GITHUB_OWNER="${2:-}"; shift 2 ;;
    --github-repo) GITHUB_REPO="${2:-}"; shift 2 ;;
    --github-branch) GITHUB_BRANCH="${2:-}"; shift 2 ;;
    --flux-path) FLUX_PATH="${2:-}"; shift 2 ;;
    --smb-username) SMB_USERNAME="${2:-}"; shift 2 ;;
    --audiobookshelf-api-key) AUDIOBOOKSHELF_API_KEY="${2:-}"; shift 2 ;;
    --smb-password) SMB_PASSWORD="${2:-}"; shift 2 ;;
    --smb-password-stdin) SMB_PASSWORD_STDIN="true"; shift 1 ;;
    --media-namespace) MEDIA_NAMESPACE="${2:-}"; shift 2 ;;
    --smb-secret-name) SMB_SECRET_NAME="${2:-}"; shift 2 ;;
    --homepage-secret-name) HOMEPAGE_SECRET_NAME="${2:-}"; shift 2 ;;
    --github-personal) GITHUB_PERSONAL="${2:-}"; shift 2 ;;
    --skip-k3s) SKIP_K3S="true"; shift 1 ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "${GITHUB_OWNER}" || -z "${GITHUB_REPO}" || -z "${SMB_USERNAME}" ]]; then
  echo "Missing required arguments." >&2
  usage
  exit 1
fi

if [[ -z "${SMB_PASSWORD}" && "${SMB_PASSWORD_STDIN}" == "true" ]]; then
  IFS= read -r -s SMB_PASSWORD
  if [[ -z "${SMB_PASSWORD}" ]]; then
    echo "No SMB password was provided on stdin." >&2
    exit 1
  fi
fi

if [[ -z "${SMB_PASSWORD}" ]]; then
  read -r -s -p "Enter SMB password: " SMB_PASSWORD
  echo
fi

if [[ -z "${GITHUB_TOKEN:-}" ]]; then
  echo "GITHUB_TOKEN must be set for Flux bootstrap." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Step 1: Install OS prerequisites (curl, sha256sum/coreutils, apt-transport)
# ---------------------------------------------------------------------------
_install_pkg() {
  if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update -qq
    sudo apt-get install -y "$@"
  elif command -v dnf >/dev/null 2>&1; then
    sudo dnf install -y "$@"
  elif command -v yum >/dev/null 2>&1; then
    sudo yum install -y "$@"
  else
    echo "Unsupported package manager. Install the following manually: $*" >&2
    exit 1
  fi
}

echo "Checking/installing system prerequisites..."
MISSING_PKGS=()
for pkg_cmd in curl sha256sum; do
  if ! command -v "${pkg_cmd}" >/dev/null 2>&1; then
    case "${pkg_cmd}" in
      sha256sum) MISSING_PKGS+=("coreutils") ;;
      *) MISSING_PKGS+=("${pkg_cmd}") ;;
    esac
  fi
done

if [[ ${#MISSING_PKGS[@]} -gt 0 ]]; then
  echo "Installing missing tools: ${MISSING_PKGS[*]}"
  _install_pkg "${MISSING_PKGS[@]}"
fi

# ---------------------------------------------------------------------------
# Step 2: Install k3s
# ---------------------------------------------------------------------------
if [[ "${SKIP_K3S}" == "true" ]]; then
  echo "Skipping k3s installation (--skip-k3s)."
elif command -v k3s >/dev/null 2>&1; then
  echo "k3s is already installed ($(k3s --version | head -n1)), skipping."
else
  echo "Installing k3s..."
  # Traefik is enabled by default in k3s and serves as the ingress controller.
  # This repo's Ingress resources (apps/media/ingress.yaml) target ingressClassName: traefik,
  # so Traefik must remain enabled. Do not pass --disable=traefik.
  curl -sfL https://get.k3s.io | sh -
fi

# k3s writes its kubeconfig to /etc/rancher/k3s/k3s.yaml (owned by root, mode 600).
# Export it inline so kubectl/helm/flux can reach the cluster if KUBECONFIG is not already set.
# Note: Non-root users may need to copy the file to ~/.kube/config with appropriate ownership.
if [[ -z "${KUBECONFIG:-}" ]]; then
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
fi

# ---------------------------------------------------------------------------
# Step 3: Install Helm (if not already present) and verify kubectl
# ---------------------------------------------------------------------------
if command -v helm >/dev/null 2>&1; then
  echo "Helm is already installed ($(helm version --short 2>/dev/null)), skipping."
else
  echo "Installing Helm..."
  HELM_INSTALL_SCRIPT="$(mktemp)"
  curl -fsSL -o "${HELM_INSTALL_SCRIPT}" "${HELM_INSTALL_SCRIPT_URL}"
  if ! echo "${HELM_INSTALL_SCRIPT_SHA256}  ${HELM_INSTALL_SCRIPT}" | sha256sum --check --status; then
    echo "Helm installer checksum verification failed." >&2
    rm -f "${HELM_INSTALL_SCRIPT}"
    exit 1
  fi
  if [[ -w /usr/local/bin ]]; then
    bash "${HELM_INSTALL_SCRIPT}"
  elif command -v sudo >/dev/null 2>&1; then
    sudo bash "${HELM_INSTALL_SCRIPT}"
  else
    mkdir -p "${HOME}/.local/bin"
    USE_SUDO=false HELM_INSTALL_DIR="${HOME}/.local/bin" bash "${HELM_INSTALL_SCRIPT}"
    export PATH="${HOME}/.local/bin:${PATH}"
  fi
  rm -f "${HELM_INSTALL_SCRIPT}"
fi

if ! command -v kubectl >/dev/null 2>&1; then
  echo "Missing required command: kubectl" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Step 4: Install Flux CLI
# ---------------------------------------------------------------------------
if ! command -v flux >/dev/null 2>&1; then
  echo "Installing Flux CLI..."
  FLUX_INSTALL_SCRIPT="$(mktemp)"
  curl -fsSL -o "${FLUX_INSTALL_SCRIPT}" "${FLUX_INSTALL_SCRIPT_URL}"
  if ! echo "${FLUX_INSTALL_SCRIPT_SHA256}  ${FLUX_INSTALL_SCRIPT}" | sha256sum --check --status; then
    echo "Flux installer checksum verification failed." >&2
    rm -f "${FLUX_INSTALL_SCRIPT}"
    exit 1
  fi
  if [[ -w /usr/local/bin ]]; then
    bash "${FLUX_INSTALL_SCRIPT}"
  elif command -v sudo >/dev/null 2>&1; then
    sudo bash "${FLUX_INSTALL_SCRIPT}"
  else
    mkdir -p "${HOME}/.local/bin"
    BINDIR="${HOME}/.local/bin" bash "${FLUX_INSTALL_SCRIPT}"
    export PATH="${HOME}/.local/bin:${PATH}"
  fi
  rm -f "${FLUX_INSTALL_SCRIPT}"
fi

# ---------------------------------------------------------------------------
# Step 5: Bootstrap Flux
# ---------------------------------------------------------------------------
echo "Bootstrapping Flux..."
# Install core Flux components:
# - source-controller: manages Git, Helm, and Bucket sources
# - kustomize-controller: applies Kustomizations from sources
# - helm-controller: required for HelmRelease resources used in this repo
FLUX_BOOTSTRAP_ARGS=(
  --owner="${GITHUB_OWNER}"
  --repository="${GITHUB_REPO}"
  --branch="${GITHUB_BRANCH}"
  --path="${FLUX_PATH}"
  --token-auth
  --components="source-controller,kustomize-controller,helm-controller"
)

if [[ "${GITHUB_PERSONAL}" == "true" ]]; then
  FLUX_BOOTSTRAP_ARGS+=(--personal)
fi

flux bootstrap github "${FLUX_BOOTSTRAP_ARGS[@]}"

# ---------------------------------------------------------------------------
# Step 6: Create SMB credentials and Homepage secrets
# ---------------------------------------------------------------------------
echo "Creating namespace and application secrets..."
kubectl create namespace "${MEDIA_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
kubectl -n "${MEDIA_NAMESPACE}" create secret generic "${SMB_SECRET_NAME}" \
  --from-literal=username="${SMB_USERNAME}" \
  --from-literal=password="${SMB_PASSWORD}" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n "${MEDIA_NAMESPACE}" create secret generic "${HOMEPAGE_SECRET_NAME}" \
  --from-literal=HOMEPAGE_VAR_AUDIOBOOKSHELF_API_KEY="${AUDIOBOOKSHELF_API_KEY}" \
  --dry-run=client -o yaml | kubectl apply -f -

if [[ -z "${AUDIOBOOKSHELF_API_KEY}" ]]; then
  echo "Homepage secret created without an Audiobookshelf API key."
  echo "Update ${HOMEPAGE_SECRET_NAME}.HOMEPAGE_VAR_AUDIOBOOKSHELF_API_KEY after logging into Audiobookshelf as an admin."
fi

echo "Done."
