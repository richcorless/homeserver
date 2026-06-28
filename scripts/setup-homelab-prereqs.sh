#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  setup-homelab-prereqs.sh \
    --github-owner <owner> \
    --github-repo <repo> \
    --smb-username <username> \
    [--github-branch <branch>] \
    [--flux-path <path>] \
    [--media-namespace <namespace>] \
    [--smb-secret-name <secret>] \
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
GITHUB_PERSONAL="true"
SKIP_K3S="false"
SMB_CSI_CHART_VERSION="1.20.1"
# Keep repo URL branch aligned with SMB_CSI_CHART_VERSION major/minor.
SMB_CSI_HELM_REPO_URL="https://raw.githubusercontent.com/kubernetes-csi/csi-driver-smb/release-1.20/charts"
FLUX_INSTALL_SCRIPT_URL="https://raw.githubusercontent.com/fluxcd/flux2/v2.6.4/install/flux.sh"
FLUX_INSTALL_SCRIPT_SHA256="bd7765225b731a1df952456eced0abb5dbbf5e11bc70cf6ab5fddd1476088b7e"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --github-owner) GITHUB_OWNER="${2:-}"; shift 2 ;;
    --github-repo) GITHUB_REPO="${2:-}"; shift 2 ;;
    --github-branch) GITHUB_BRANCH="${2:-}"; shift 2 ;;
    --flux-path) FLUX_PATH="${2:-}"; shift 2 ;;
    --smb-username) SMB_USERNAME="${2:-}"; shift 2 ;;
    --smb-password) SMB_PASSWORD="${2:-}"; shift 2 ;;
    --smb-password-stdin) SMB_PASSWORD_STDIN="true"; shift 1 ;;
    --media-namespace) MEDIA_NAMESPACE="${2:-}"; shift 2 ;;
    --smb-secret-name) SMB_SECRET_NAME="${2:-}"; shift 2 ;;
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

SMB_CSI_MAJOR_MINOR="$(echo "${SMB_CSI_CHART_VERSION}" | cut -d. -f1-2)"
if [[ "${SMB_CSI_HELM_REPO_URL}" != *"release-${SMB_CSI_MAJOR_MINOR}/charts" ]]; then
  echo "SMB_CSI_HELM_REPO_URL must match SMB_CSI_CHART_VERSION major.minor (release-${SMB_CSI_MAJOR_MINOR})." >&2
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
    MISSING_PKGS+=("${pkg_cmd}")
  fi
done

if [[ ${#MISSING_PKGS[@]} -gt 0 ]]; then
  echo "Installing missing tools: ${MISSING_PKGS[*]}"
  # Both curl and sha256sum ship in well-known packages across distros.
  # coreutils provides sha256sum; curl is its own package.
  PKG_LIST=()
  for pkg in "${MISSING_PKGS[@]}"; do
    case "${pkg}" in
      sha256sum) PKG_LIST+=("coreutils") ;;
      *) PKG_LIST+=("${pkg}") ;;
    esac
  done
  _install_pkg "${PKG_LIST[@]}"
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
  curl -sfL https://get.k3s.io | sh -
  # k3s writes its kubeconfig to /etc/rancher/k3s/k3s.yaml.
  # Export it so subsequent kubectl/helm calls work without a separate kubeconfig.
  export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
fi

# If k3s is the kubectl provider, export KUBECONFIG so helm/flux can reach it.
if [[ -z "${KUBECONFIG:-}" && -f /etc/rancher/k3s/k3s.yaml ]]; then
  export KUBECONFIG="/etc/rancher/k3s/k3s.yaml"
fi

# ---------------------------------------------------------------------------
# Step 3: Verify remaining prerequisites
# ---------------------------------------------------------------------------
for cmd in curl kubectl helm sha256sum; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "Missing required command: ${cmd}" >&2
    exit 1
  fi
done

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
FLUX_BOOTSTRAP_ARGS=(
  --owner="${GITHUB_OWNER}"
  --repository="${GITHUB_REPO}"
  --branch="${GITHUB_BRANCH}"
  --path="${FLUX_PATH}"
  --token-auth
)

if [[ "${GITHUB_PERSONAL}" == "true" ]]; then
  FLUX_BOOTSTRAP_ARGS+=(--personal)
fi

flux bootstrap github "${FLUX_BOOTSTRAP_ARGS[@]}"

# ---------------------------------------------------------------------------
# Step 6: Install SMB CSI driver
# ---------------------------------------------------------------------------
echo "Installing SMB CSI driver..."
helm repo add csi-driver-smb "${SMB_CSI_HELM_REPO_URL}"
helm repo update
helm upgrade --install csi-driver-smb csi-driver-smb/csi-driver-smb \
  --namespace kube-system \
  --version "${SMB_CSI_CHART_VERSION}"

# ---------------------------------------------------------------------------
# Step 7: Create SMB credentials secret
# ---------------------------------------------------------------------------
echo "Creating namespace and SMB credentials secret..."
kubectl create namespace "${MEDIA_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
kubectl -n "${MEDIA_NAMESPACE}" apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${SMB_SECRET_NAME}
type: Opaque
stringData:
  username: ${SMB_USERNAME}
  password: ${SMB_PASSWORD}
EOF

echo "Done."
