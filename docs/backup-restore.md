# Backup and Restore Guide

This guide covers everything you need to know about how app config data is backed up and how
to recover it after a failure. **Read this before you need it** — ideally when things are working,
so you know where to look when they are not.

---

## Overview

### What is backed up

Each app stores its configuration (database, settings, metadata) in a Kubernetes PVC using the
`local-path` storage class. These PVCs live on the node's local disk.

| App | PVC | Backed up |
|---|---|---|
| Audiobookshelf | `audiobookshelf-config` | ✅ nightly |
| Lyrion Music Server | `lyrion-config` | ✅ nightly |

Media files (audiobooks, music) are **not** backed up — they live on the NAS at `10.1.10.10` and
are considered the source of truth.

### Where backups go

Backups are written to the SMB share `//10.1.10.10/Config/backup` using
[Volsync](https://volsync.readthedocs.io/) with a restic backend over rclone.

Each app gets its own subdirectory:

```
//10.1.10.10/Config/backup/
  audiobookshelf-config/   ← restic repository for Audiobookshelf
  lyrion-config/           ← restic repository for Lyrion
```

### Schedule and retention

Backups run nightly at **03:00** local time. Retention policy:

| Period | Snapshots kept |
|---|---|
| Daily | 7 (last week) |
| Weekly | 4 (last month) |
| Prune interval | every 7 days |

Maximum data loss in the worst case: **~24 hours** (since the last successful 3am backup).

### How Volsync works (brief)

Volsync runs as a Kubernetes operator (`volsync-system` namespace). Each `ReplicationSource`
manifest tells it which PVC to back up, when, and where. At backup time, Volsync spins up a
short-lived restic mover pod that reads the PVC and pushes deduplicated, encrypted chunks to the
restic repository on the NAS. The restic password is stored in a Kubernetes secret and is required
for restore.

---

## Initial setup

After bootstrapping the cluster (see [deployment.md](deployment.md)), run:

```bash
echo '<smb-password>' | \
bash ./scripts/setup-volsync-secrets.sh \
  --smb-username '<smb-username>' \
  --smb-password-stdin \
  --namespace media
```

This creates the Kubernetes secrets that Volsync needs to authenticate with the backup share.
The script generates a restic encryption password and prints it once — **save it in a password
manager immediately**. You need it to restore from backup.

### Verify backups are running

The first backup runs at 03:00 the night after setup. To check status at any time:

```bash
kubectl get replicationsource -n media
```

A healthy output looks like:

```
NAME                      LAST SYNC              DURATION   NEXT SYNC
audiobookshelf-config     2026-07-01T03:00:42Z   28s        2026-07-02T03:00:00Z
lyrion-config             2026-07-01T03:01:05Z   19s        2026-07-02T03:00:00Z
```

For more detail on the last run:

```bash
kubectl describe replicationsource audiobookshelf-config -n media
```

---

## Adding backup for a new app

> **When you add a new app, you must manually create its backup configuration.**
> Volsync does not auto-discover new PVCs.

### 1. Add a ReplicationSource manifest

Create `apps/media/backup/<app>-config-backup.yaml` based on this template:

```yaml
apiVersion: volsync.backube/v1alpha1
kind: ReplicationSource
metadata:
  name: <app>-config            # must be unique in the namespace
spec:
  sourcePVC: <app>-config       # PVC name to back up
  trigger:
    schedule: "0 3 * * *"
  restic:
    pruneIntervalDays: 7
    repository: <app>-config-volsync-secret
    retain:
      daily: 7
      weekly: 4
    copyMethod: Direct
```

Add it to `apps/media/backup/kustomization.yaml`:

```yaml
resources:
  - audiobookshelf-config-backup.yaml
  - lyrion-config-backup.yaml
  - <app>-config-backup.yaml    # add this line
```

### 2. Edit `scripts/setup-volsync-secrets.sh`

Find the `APP_REPOS` map near the bottom of the script and add an entry:

```bash
APP_REPOS["<app>-config-volsync-secret"]="<app>-config"
```

### 3. Create the secret on the cluster

Re-run the setup script with the same credentials:

```bash
echo '<smb-password>' | \
bash ./scripts/setup-volsync-secrets.sh \
  --smb-username '<smb-username>' \
  --smb-password-stdin \
  --restic-password '<your-existing-restic-password>' \
  --namespace media
```

### 4. Commit and push

Commit the new `ReplicationSource` and updated `kustomization.yaml`. Flux will apply them
on the next reconcile.

---

## Restarting a single app

Sometimes an app needs a manual restart (e.g. after a config change or to pick up a secret update).

### Restart via Flux (recommended)

Suspend and resume the HelmRelease — Flux reconciles and Helm rolls out the pod:

```bash
flux suspend helmrelease audiobookshelf -n media
flux resume helmrelease audiobookshelf -n media
```

### Restart via kubectl rollout

```bash
kubectl rollout restart deployment/audiobookshelf-main -n media
kubectl rollout status  deployment/audiobookshelf-main -n media
```

### Check pod status

```bash
kubectl get pods -n media
kubectl describe pod -n media -l app.kubernetes.io/name=audiobookshelf
kubectl logs -n media -l app.kubernetes.io/name=audiobookshelf
```

---

## Restoring a single app's config

Use the restore script. It handles everything: suspending the app, deleting the broken PVC,
pulling the backup, and bringing the app back up.

### Restore to the latest snapshot

```bash
bash ./scripts/restore-app-config.sh \
  --app-name audiobookshelf \
  --pvc-name audiobookshelf-config
```

### Restore Lyrion to the latest snapshot

```bash
bash ./scripts/restore-app-config.sh \
  --app-name lyrion \
  --pvc-name lyrion-config
```

### Restore to a specific point in time

```bash
bash ./scripts/restore-app-config.sh \
  --app-name audiobookshelf \
  --pvc-name audiobookshelf-config \
  --restore-as-of "2026-06-30T03:00:00Z"
```

The script will confirm before deleting anything and prints step-by-step progress.

If the restore fails, check the mover pod logs:

```bash
kubectl get pods -n media -l volsync.backube/replicationdestination=audiobookshelf-config-restore
kubectl logs -n media  -l volsync.backube/replicationdestination=audiobookshelf-config-restore
```

---

## Recovering from a lost node

> This covers the scenario where the node running your apps is gone (hardware failure, OS corruption,
> etc.) and you need to rebuild everything from scratch.

The cluster state (all app manifests) lives in this Git repository — Flux recreates everything
from Git. App config data is in the Volsync backups on the NAS. Together these give you a full
recovery path.

### Step 1: Rebuild the node

Provision a new Linux server (same OS/specs as before) or reinstall the OS on the existing hardware.

### Step 2: Bootstrap the cluster

Run the bootstrap script exactly as you did originally:

```bash
export GITHUB_TOKEN='<your-github-token>'
echo '<smb-password>' | \
bash ./scripts/setup-homelab-prereqs.sh \
  --github-owner richcorless \
  --github-repo homeserver \
  --github-branch main \
  --flux-path clusters/homelab \
  --smb-username '<smb-username>' \
  --smb-password-stdin \
  --media-namespace media \
  --smb-secret-name media-smb-credentials \
  --github-personal true
```

This installs k3s, Helm, Flux, and connects Flux to this repository. Flux will deploy everything
from Git: Traefik, SMB CSI, Volsync, all app HelmReleases, and empty config PVCs.

**Wait for Flux to reconcile fully before continuing:**

```bash
flux get kustomizations
flux get helmreleases -A
```

All kustomizations and HelmReleases should show `Ready = True`.

### Step 3: Recreate the backup secrets

```bash
echo '<smb-password>' | \
bash ./scripts/setup-volsync-secrets.sh \
  --smb-username '<smb-username>' \
  --smb-password-stdin \
  --restic-password '<your-saved-restic-password>' \
  --namespace media
```

> You must use the **same restic password** that was used when the backups were created.
> This is why you saved it in step 2 of the initial setup.

### Step 4: Restore each app's config

Run the restore script for each app:

```bash
bash ./scripts/restore-app-config.sh \
  --app-name audiobookshelf \
  --pvc-name audiobookshelf-config

bash ./scripts/restore-app-config.sh \
  --app-name lyrion \
  --pvc-name lyrion-config
```

Each restore takes a minute or two depending on data size and NAS speed. The script brings the app
back up automatically when restore is complete.

### Step 5: Recreate the Homepage API key secret

The Audiobookshelf API key is not backed up (it's a Kubernetes secret, not app data).
After Audiobookshelf is running with its restored database, your existing admin account and API key
are back. Re-populate the Homepage secret:

```bash
bash ./scripts/setup-homepage-secrets.sh \
  --media-namespace media \
  --homepage-secret-name homepage-secrets
```

### Step 6: Verify everything

```bash
kubectl get pods -n media        # all pods should be Running
kubectl get pvc  -n media        # all PVCs should be Bound
flux get helmreleases -n media   # all HelmReleases Ready
```

Browse to `http://homeserver.local/` — Homepage should show all services healthy.

---

## Full cluster checklist (bookmark this)

Use this as your recovery checklist:

- [ ] New node provisioned and reachable
- [ ] Bootstrap script run (`setup-homelab-prereqs.sh`)
- [ ] Flux reconciled — all kustomizations and HelmReleases `Ready`
- [ ] Volsync secrets created (`setup-volsync-secrets.sh` with saved restic password)
- [ ] Audiobookshelf config restored (`restore-app-config.sh`)
- [ ] Lyrion config restored (`restore-app-config.sh`)
- [ ] Homepage API key secret recreated (`setup-homepage-secrets.sh`)
- [ ] All pods Running, PVCs Bound, services reachable

---

## Troubleshooting

### Check backup status

```bash
kubectl get replicationsource -n media
kubectl describe replicationsource audiobookshelf-config -n media
```

### Watch a backup run in real time

Backups run at 03:00. To trigger one immediately (for testing):

```bash
# Temporarily patch the schedule to run in 1 minute, observe, then revert
kubectl patch replicationsource audiobookshelf-config -n media \
  --type=merge -p '{"spec":{"trigger":{"schedule":"* * * * *"}}}'
# ... wait and watch ...
kubectl patch replicationsource audiobookshelf-config -n media \
  --type=merge -p '{"spec":{"trigger":{"schedule":"0 3 * * *"}}}'
```

### Check mover pod logs

```bash
# For ReplicationSource (backup)
kubectl get pods -n media -l volsync.backube/replicationsource=audiobookshelf-config
kubectl logs  -n media -l volsync.backube/replicationsource=audiobookshelf-config

# For ReplicationDestination (restore)
kubectl get pods -n media -l volsync.backube/replicationdestination=audiobookshelf-config-restore
kubectl logs  -n media -l volsync.backube/replicationdestination=audiobookshelf-config-restore
```

### Volsync operator logs

```bash
kubectl logs -n volsync-system -l app.kubernetes.io/name=volsync
```

### Restic secret missing or wrong credentials

If a backup fails with authentication errors, recreate the secret:

```bash
kubectl delete secret audiobookshelf-config-volsync-secret -n media
echo '<smb-password>' | \
bash ./scripts/setup-volsync-secrets.sh \
  --smb-username '<smb-username>' \
  --smb-password-stdin \
  --restic-password '<your-restic-password>' \
  --namespace media
```
