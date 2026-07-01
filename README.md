# homeserver

GitOps repository for deploying services to a k3s cluster with Flux and Helm.

## What is deployed

| Service | URL |
|---|---|
| Homepage | `http://homeserver.local/` |
| Audiobookshelf | `http://homeserver.local/audiobookshelf` |
| Lyrion Music Server | `http://homeserver.local:9000` |

Both apps mount media from a remote SMB server at `10.1.10.10`.
App config is backed up nightly to `//10.1.10.10/Config/backup` via Volsync.

## Documentation

| Guide | Description |
|---|---|
| [Deployment Guide](docs/deployment.md) | Full setup: bootstrap, secrets, Flux, accessing services |
| [Backup & Restore Guide](docs/backup-restore.md) | How backups work, restarting apps, restoring config, recovering a lost node |

## Quick links

- **Bootstrap a new cluster** → [docs/deployment.md](docs/deployment.md)
- **Restore after node failure** → [docs/backup-restore.md#recovering-from-a-lost-node](docs/backup-restore.md#recovering-from-a-lost-node)
- **Restart a single app** → [docs/backup-restore.md#restarting-a-single-app](docs/backup-restore.md#restarting-a-single-app)
- **Restore a single app's config** → [docs/backup-restore.md#restoring-a-single-apps-config](docs/backup-restore.md#restoring-a-single-apps-config)
- **Full recovery checklist** → [docs/backup-restore.md#full-cluster-checklist-bookmark-this](docs/backup-restore.md#full-cluster-checklist-bookmark-this)

## Scripts

| Script | Purpose |
|---|---|
| `scripts/setup-homelab-prereqs.sh` | Bootstrap k3s, Helm, Flux, create SMB secret |
| `scripts/setup-volsync-secrets.sh` | Create backup secrets (run after bootstrap) |
| `scripts/setup-homepage-secrets.sh` | Set Audiobookshelf API key for Homepage widget |
| `scripts/restore-app-config.sh` | Restore a single app's config PVC from backup |

## Repository layout

```
clusters/homelab/       Root kustomization Flux reconciles
infrastructure/sources/ HelmRepository definitions
infrastructure/smb-csi/ SMB CSI driver
infrastructure/traefik/ Traefik config (LMS port-9000 entrypoint)
infrastructure/volsync/ Volsync backup operator
apps/media/             Namespace, storage, app manifests, ingress
apps/media/backup/      Volsync ReplicationSource manifests
docs/                   Deployment and backup/restore documentation
scripts/                Bootstrap and helper scripts
```

