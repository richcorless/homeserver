#!/usr/bin/env bash
# restore-app-config.sh
# Restores a single app's config PVC from its Volsync restic backup.
#
# What this script does:
#   1. Suspends the app's HelmRelease (so it stops writing to the PVC).
#   2. Deletes the existing PVC (if any).
#   3. Creates a Volsync ReplicationDestination that pulls data from the backup.
#   4. Waits for the restore to complete.
#   5. Resumes the HelmRelease so Flux deploys the app against the restored data.
#   6. Cleans up the temporary ReplicationDestination.
#
# Usage:
#   bash ./scripts/restore-app-config.sh \
#     --app-name audiobookshelf \
#     --pvc-name audiobookshelf-config \
#     [--namespace media] \
#     [--storage-class local-path] \
#     [--capacity 10Gi] \
#     [--restore-as-of "2026-06-30T03:00:00Z"]
#
# All flags except --app-name and --pvc-name have sensible defaults.
# --restore-as-of is optional; omit it to restore the most recent snapshot.
set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
APP_NAME=""
PVC_NAME=""
NAMESPACE="media"
STORAGE_CLASS="local-path"
CAPACITY="10Gi"
RESTORE_AS_OF=""
WAIT_TIMEOUT=600   # seconds to wait for restore to complete

usage() {
  cat <<'EOF'
Usage:
  restore-app-config.sh \
    --app-name <name> \
    --pvc-name <pvc> \
    [--namespace <ns>] \
    [--storage-class <class>] \
    [--capacity <size>] \
    [--restore-as-of <RFC3339-timestamp>]

  --app-name        Name of the HelmRelease to suspend/resume (e.g. audiobookshelf).
  --pvc-name        Name of the PVC to restore (e.g. audiobookshelf-config).
  --namespace       Kubernetes namespace (default: media).
  --storage-class   StorageClass for the restored PVC (default: local-path).
  --capacity        PVC size (default: 10Gi).
  --restore-as-of   Restore to the snapshot on or before this RFC3339 timestamp.
                    Omit to restore the latest snapshot.

Example — restore audiobookshelf to the most recent backup:
  bash ./scripts/restore-app-config.sh \
    --app-name audiobookshelf \
    --pvc-name audiobookshelf-config

Example — restore lyrion to a specific point in time:
  bash ./scripts/restore-app-config.sh \
    --app-name lyrion \
    --pvc-name lyrion-config \
    --restore-as-of "2026-06-30T03:00:00Z"
EOF
}

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --app-name)       APP_NAME="${2:-}"; shift 2 ;;
    --pvc-name)       PVC_NAME="${2:-}"; shift 2 ;;
    --namespace)      NAMESPACE="${2:-}"; shift 2 ;;
    --storage-class)  STORAGE_CLASS="${2:-}"; shift 2 ;;
    --capacity)       CAPACITY="${2:-}"; shift 2 ;;
    --restore-as-of)  RESTORE_AS_OF="${2:-}"; shift 2 ;;
    -h|--help)        usage; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "${APP_NAME}" || -z "${PVC_NAME}" ]]; then
  echo "Error: --app-name and --pvc-name are required." >&2
  usage
  exit 1
fi

# ---------------------------------------------------------------------------
# Check prerequisites
# ---------------------------------------------------------------------------
for cmd in kubectl flux; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "Error: '${cmd}' is not installed or not in PATH." >&2
    exit 1
  fi
done

SECRET_NAME="${PVC_NAME}-volsync"
DEST_NAME="${PVC_NAME}-restore"
TRIGGER_VALUE="restore-$(date +%s)"

echo ""
echo "========================================================"
echo "  Volsync Config Restore"
echo "  App:            ${APP_NAME}"
echo "  PVC:            ${PVC_NAME}"
echo "  Namespace:      ${NAMESPACE}"
echo "  Secret:         ${SECRET_NAME}"
echo "  Storage class:  ${STORAGE_CLASS}"
echo "  Capacity:       ${CAPACITY}"
if [[ -n "${RESTORE_AS_OF}" ]]; then
  echo "  Restore as of:  ${RESTORE_AS_OF}"
else
  echo "  Restore as of:  latest snapshot"
fi
echo "========================================================"
echo ""

# Confirm before proceeding
read -r -p "This will DELETE the existing '${PVC_NAME}' PVC. Continue? [y/N] " CONFIRM
if [[ "${CONFIRM,,}" != "y" ]]; then
  echo "Aborted."
  exit 0
fi

# ---------------------------------------------------------------------------
# Step 1: Suspend the HelmRelease so the app stops running
# ---------------------------------------------------------------------------
echo ""
echo "[1/6] Suspending HelmRelease '${APP_NAME}' in namespace '${NAMESPACE}'..."
flux suspend helmrelease "${APP_NAME}" -n "${NAMESPACE}"

echo "      Waiting for pods to terminate..."
# Give pods up to 60 seconds to terminate
DEADLINE=$(( $(date +%s) + 60 ))
while kubectl get pods -n "${NAMESPACE}" -l "app.kubernetes.io/name=${APP_NAME}" \
    --field-selector=status.phase=Running -o name 2>/dev/null | grep -q .; do
  if [[ $(date +%s) -gt ${DEADLINE} ]]; then
    echo "      Warning: pods did not terminate within 60 s. Proceeding anyway."
    break
  fi
  sleep 3
done
echo "      Pods stopped."

# ---------------------------------------------------------------------------
# Step 2: Delete the existing PVC (if it exists)
# ---------------------------------------------------------------------------
echo ""
echo "[2/6] Deleting PVC '${PVC_NAME}'..."
if kubectl get pvc "${PVC_NAME}" -n "${NAMESPACE}" >/dev/null 2>&1; then
  kubectl delete pvc "${PVC_NAME}" -n "${NAMESPACE}"
  echo "      PVC deleted."
else
  echo "      PVC not found — nothing to delete (fresh restore)."
fi

# Also remove any leftover ReplicationDestination from a previous failed restore
if kubectl get replicationdestination "${DEST_NAME}" -n "${NAMESPACE}" >/dev/null 2>&1; then
  echo "      Removing stale ReplicationDestination from previous attempt..."
  kubectl delete replicationdestination "${DEST_NAME}" -n "${NAMESPACE}"
fi

# ---------------------------------------------------------------------------
# Step 3: Create the ReplicationDestination
# ---------------------------------------------------------------------------
echo ""
echo "[3/6] Creating ReplicationDestination '${DEST_NAME}'..."

RESTORE_AS_OF_YAML=""
if [[ -n "${RESTORE_AS_OF}" ]]; then
  RESTORE_AS_OF_YAML="    restoreAsOf: \"${RESTORE_AS_OF}\""
fi

kubectl apply -f - <<EOF
apiVersion: volsync.backube/v1alpha1
kind: ReplicationDestination
metadata:
  name: ${DEST_NAME}
  namespace: ${NAMESPACE}
spec:
  trigger:
    manual: ${TRIGGER_VALUE}
  restic:
    repository: ${SECRET_NAME}
    destinationPVC: ${PVC_NAME}
    copyMethod: Direct
    accessModes:
      - ReadWriteOnce
    capacity: ${CAPACITY}
    storageClassName: ${STORAGE_CLASS}
${RESTORE_AS_OF_YAML}
EOF

echo "      ReplicationDestination created."

# ---------------------------------------------------------------------------
# Step 4: Wait for restore to complete
# ---------------------------------------------------------------------------
echo ""
echo "[4/6] Waiting for restore to complete (timeout: ${WAIT_TIMEOUT}s)..."
echo "      (You can watch progress in another terminal with:"
echo "       kubectl get replicationdestination ${DEST_NAME} -n ${NAMESPACE} -w)"
echo ""

DEADLINE=$(( $(date +%s) + WAIT_TIMEOUT ))
while true; do
  STATUS="$(kubectl get replicationdestination "${DEST_NAME}" -n "${NAMESPACE}" \
    -o jsonpath='{.status.latestMoverStatus.result}' 2>/dev/null || true)"

  if [[ "${STATUS}" == "Successful" ]]; then
    echo "      Restore completed successfully."
    break
  elif [[ "${STATUS}" == "Failed" ]]; then
    echo ""
    echo "ERROR: Restore failed. Check the mover pod logs:"
    echo "  kubectl get pods -n ${NAMESPACE} -l volsync.backube/replicationdestination=${DEST_NAME}"
    echo "  kubectl logs -n ${NAMESPACE} -l volsync.backube/replicationdestination=${DEST_NAME}"
    # Resume the HelmRelease even on failure so the cluster isn't left suspended
    echo ""
    echo "Resuming HelmRelease to leave cluster in a consistent state..."
    flux resume helmrelease "${APP_NAME}" -n "${NAMESPACE}" || true
    exit 1
  fi

  if [[ $(date +%s) -gt ${DEADLINE} ]]; then
    echo ""
    echo "ERROR: Restore timed out after ${WAIT_TIMEOUT}s."
    echo "Check ReplicationDestination status:"
    echo "  kubectl describe replicationdestination ${DEST_NAME} -n ${NAMESPACE}"
    flux resume helmrelease "${APP_NAME}" -n "${NAMESPACE}" || true
    exit 1
  fi

  printf "."
  sleep 5
done

# ---------------------------------------------------------------------------
# Step 5: Resume the HelmRelease
# ---------------------------------------------------------------------------
echo ""
echo "[5/6] Resuming HelmRelease '${APP_NAME}'..."
flux resume helmrelease "${APP_NAME}" -n "${NAMESPACE}"
echo "      Flux will now reconcile and redeploy ${APP_NAME} against the restored data."
echo "      Watch rollout: kubectl rollout status -n ${NAMESPACE} deployment/${APP_NAME}-main"

# ---------------------------------------------------------------------------
# Step 6: Clean up the ReplicationDestination
# ---------------------------------------------------------------------------
echo ""
echo "[6/6] Cleaning up ReplicationDestination '${DEST_NAME}'..."
kubectl delete replicationdestination "${DEST_NAME}" -n "${NAMESPACE}"
echo "      Done."

echo ""
echo "========================================================"
echo "  Restore complete."
echo "  ${APP_NAME} should be running with its restored config."
echo ""
echo "  Verify at:"
echo "    kubectl get pods -n ${NAMESPACE}"
echo "========================================================"
