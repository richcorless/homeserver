#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  setup-homepage-secrets.sh \
    [--audiobookshelf-api-key <key>] \
    [--audiobookshelf-api-key-stdin] \
    [--media-namespace <namespace>] \
    [--homepage-secret-name <secret>] \
    [--homepage-deployment-name <deployment>]

If --audiobookshelf-api-key is omitted, the script prompts for it.
EOF
}

MEDIA_NAMESPACE="media"
HOMEPAGE_SECRET_NAME="homepage-secrets"
HOMEPAGE_DEPLOYMENT_NAME="homepage"
AUDIOBOOKSHELF_API_KEY=""
AUDIOBOOKSHELF_API_KEY_STDIN="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --audiobookshelf-api-key) AUDIOBOOKSHELF_API_KEY="${2:-}"; shift 2 ;;
    --audiobookshelf-api-key-stdin) AUDIOBOOKSHELF_API_KEY_STDIN="true"; shift 1 ;;
    --media-namespace) MEDIA_NAMESPACE="${2:-}"; shift 2 ;;
    --homepage-secret-name) HOMEPAGE_SECRET_NAME="${2:-}"; shift 2 ;;
    --homepage-deployment-name) HOMEPAGE_DEPLOYMENT_NAME="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ "${AUDIOBOOKSHELF_API_KEY_STDIN}" == "true" ]]; then
  IFS= read -r -s AUDIOBOOKSHELF_API_KEY
  if [[ -z "${AUDIOBOOKSHELF_API_KEY}" ]]; then
    echo "No Audiobookshelf API key was provided on stdin." >&2
    exit 1
  fi
elif [[ -z "${AUDIOBOOKSHELF_API_KEY}" ]]; then
  read -r -s -p "Enter Audiobookshelf API key: " AUDIOBOOKSHELF_API_KEY
  echo
fi

if [[ -z "${AUDIOBOOKSHELF_API_KEY}" ]]; then
  echo "Audiobookshelf API key is required." >&2
  exit 1
fi

if ! command -v kubectl >/dev/null 2>&1; then
  echo "Missing required command: kubectl" >&2
  exit 1
fi

kubectl -n "${MEDIA_NAMESPACE}" create secret generic "${HOMEPAGE_SECRET_NAME}" \
  --from-literal=HOMEPAGE_VAR_AUDIOBOOKSHELF_API_KEY="${AUDIOBOOKSHELF_API_KEY}" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n "${MEDIA_NAMESPACE}" rollout restart "deployment/${HOMEPAGE_DEPLOYMENT_NAME}"
kubectl -n "${MEDIA_NAMESPACE}" rollout status "deployment/${HOMEPAGE_DEPLOYMENT_NAME}"

echo "Homepage secret updated and deployment restarted."
