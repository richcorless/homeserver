#!/usr/bin/env bash
# setup-volsync-secrets.sh
# Creates the Kubernetes secrets that Volsync's restic mover needs to back up
# each app's config PVC to the SMB share //10.1.10.10/Config/backup.
#
# Run this after the initial cluster bootstrap and after adding any new app.
# The SMB credentials used here must have read/write access to the backup share.
#
# Usage:
#   bash ./scripts/setup-volsync-secrets.sh \
#     --smb-username <user> \
#     [--smb-password <pass>] \
#     [--smb-password-stdin] \
#     [--restic-password <pass>] \
#     [--namespace <ns>] \
#     [--backup-share <//host/share/path>]
#
# The same restic password is used for every app's repository. Keep it safe —
# you need it to restore. If you lose it, the backups are unreadable.
set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
SMB_USERNAME=""
SMB_PASSWORD=""
SMB_PASSWORD_STDIN="false"
RESTIC_PASSWORD=""
NAMESPACE="media"
BACKUP_SHARE="//10.1.10.10/Config/backup"

usage() {
  cat <<'EOF'
Usage:
  setup-volsync-secrets.sh \
    --smb-username <user> \
    [--smb-password <pass>] \
    [--smb-password-stdin] \
    [--restic-password <pass>] \
    [--namespace <namespace>] \
    [--backup-share <//host/share/path>]

  --smb-username        SMB username for the backup share.
  --smb-password        SMB password (prompted if omitted).
  --smb-password-stdin  Read SMB password from stdin.
  --restic-password     Restic repository encryption password (generated if omitted).
                        WARNING: store this somewhere safe — you need it to restore.
  --namespace           Kubernetes namespace where PVCs live (default: media).
  --backup-share        SMB UNC path to the backup root (default: //10.1.10.10/Config/backup).
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --smb-username)      SMB_USERNAME="${2:-}"; shift 2 ;;
    --smb-password)      SMB_PASSWORD="${2:-}"; shift 2 ;;
    --smb-password-stdin) SMB_PASSWORD_STDIN="true"; shift 1 ;;
    --restic-password)   RESTIC_PASSWORD="${2:-}"; shift 2 ;;
    --namespace)         NAMESPACE="${2:-}"; shift 2 ;;
    --backup-share)      BACKUP_SHARE="${2:-}"; shift 2 ;;
    -h|--help)           usage; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "${SMB_USERNAME}" ]]; then
  echo "Error: --smb-username is required." >&2
  usage
  exit 1
fi

# ---------------------------------------------------------------------------
# Read SMB password
# ---------------------------------------------------------------------------
if [[ "${SMB_PASSWORD_STDIN}" == "true" ]]; then
  IFS= read -r -s SMB_PASSWORD
  if [[ -z "${SMB_PASSWORD}" ]]; then
    echo "No SMB password was provided on stdin." >&2
    exit 1
  fi
elif [[ -z "${SMB_PASSWORD}" ]]; then
  read -r -s -p "Enter SMB password for backup share: " SMB_PASSWORD
  echo
fi

if [[ -z "${SMB_PASSWORD}" ]]; then
  echo "SMB password is required." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Generate or accept a restic password
# ---------------------------------------------------------------------------
if [[ -z "${RESTIC_PASSWORD}" ]]; then
  if command -v openssl >/dev/null 2>&1; then
    RESTIC_PASSWORD="$(openssl rand -base64 32)"
  else
    RESTIC_PASSWORD="$(tr -dc 'A-Za-z0-9_\-' </dev/urandom | head -c 40)"
  fi
  echo ""
  echo "============================================================"
  echo "  GENERATED RESTIC PASSWORD — SAVE THIS NOW"
  echo "  You need it to restore from backup."
  echo ""
  echo "  ${RESTIC_PASSWORD}"
  echo "============================================================"
  echo ""
fi

# ---------------------------------------------------------------------------
# Install rclone if missing (needed to obscure the SMB password)
# ---------------------------------------------------------------------------
if ! command -v rclone >/dev/null 2>&1; then
  echo "rclone not found. Installing..."
  if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update -qq && sudo apt-get install -y rclone
  elif command -v dnf >/dev/null 2>&1; then
    sudo dnf install -y rclone
  elif command -v yum >/dev/null 2>&1; then
    sudo yum install -y rclone
  else
    # Fallback: rclone one-line installer
    curl -fsSL https://rclone.org/install.sh | sudo bash
  fi
fi

# ---------------------------------------------------------------------------
# Obscure the SMB password for rclone (rclone does not accept plain-text passwords
# in its config file for security reasons — it uses its own lightweight obfuscation)
# ---------------------------------------------------------------------------
OBSCURED_SMB_PASSWORD="$(rclone obscure "${SMB_PASSWORD}")"

# ---------------------------------------------------------------------------
# Parse the SMB UNC path into host, share, and sub-path.
# Expected format: //host/share  or  //host/share/sub/path
# ---------------------------------------------------------------------------
# Strip leading slashes and split
SMB_PATH="${BACKUP_SHARE#//}"
SMB_HOST="${SMB_PATH%%/*}"
SMB_REMAINDER="${SMB_PATH#*/}"
SMB_SHARE="${SMB_REMAINDER%%/*}"
SMB_SUBPATH="${SMB_REMAINDER#*/}"
# If there's no subpath (share == remainder), subpath is empty
if [[ "${SMB_SHARE}" == "${SMB_REMAINDER}" ]]; then
  SMB_SUBPATH=""
fi

# Build rclone config content (a single [smb-backup] remote pointing at the host)
RCLONE_CONFIG="$(cat <<EOF
[smb-backup]
type = smb
host = ${SMB_HOST}
user = ${SMB_USERNAME}
pass = ${OBSCURED_SMB_PASSWORD}
EOF
)"

# ---------------------------------------------------------------------------
# Create one Kubernetes secret per app config PVC.
# Each secret contains:
#   RESTIC_REPOSITORY  - the rclone path for this app's restic repo
#   RESTIC_PASSWORD    - the restic encryption password (same for all apps)
#   RCLONE_CONFIG      - the rclone config file content
# ---------------------------------------------------------------------------

# Map of: secret-name -> subfolder-within-backup-share
# Format: "secret_name:subpath"
declare -A APP_REPOS
APP_REPOS["audiobookshelf-config-volsync-secret"]="audiobookshelf-config"
APP_REPOS["lyrion-config-volsync-secret"]="lyrion-config"

# Build the rclone remote path prefix (share + optional subpath)
if [[ -n "${SMB_SUBPATH}" && "${SMB_SUBPATH}" != "${SMB_SHARE}" ]]; then
  REPO_PREFIX="${SMB_SHARE}/${SMB_SUBPATH}"
else
  REPO_PREFIX="${SMB_SHARE}"
fi

for SECRET_NAME in "${!APP_REPOS[@]}"; do
  APP_SUBPATH="${APP_REPOS[${SECRET_NAME}]}"
  RESTIC_REPO="rclone:smb-backup:${REPO_PREFIX}/${APP_SUBPATH}"

  echo "Creating secret '${SECRET_NAME}' in namespace '${NAMESPACE}'..."
  echo "  RESTIC_REPOSITORY = ${RESTIC_REPO}"

  kubectl -n "${NAMESPACE}" create secret generic "${SECRET_NAME}" \
    --from-literal=RESTIC_REPOSITORY="${RESTIC_REPO}" \
    --from-literal=RESTIC_PASSWORD="${RESTIC_PASSWORD}" \
    --from-literal=RCLONE_CONFIG="${RCLONE_CONFIG}" \
    --dry-run=client -o yaml | kubectl apply -f -
done

echo ""
echo "Done. Volsync backup secrets created in namespace '${NAMESPACE}'."
echo ""
echo "Volsync will start backing up at 03:00 each night."
echo "Check backup status with:"
echo "  kubectl get replicationsource -n ${NAMESPACE}"
echo ""
echo "REMINDER: Store the restic password somewhere safe (e.g. a password manager)."
echo "Without it you cannot restore from backup."
