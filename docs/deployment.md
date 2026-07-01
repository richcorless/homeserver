# Deployment Guide

This guide covers everything needed to deploy the homelab cluster from scratch.

---

## What is deployed

| Service | URL |
|---|---|
| Homepage | `http://homeserver.local/` |
| Audiobookshelf | `http://homeserver.local/audiobookshelf` |
| Lyrion Music Server | `http://homeserver.local:9000` |

Both Audiobookshelf and Lyrion mount media from an SMB server at `10.1.10.10`.

---

## Repository layout

```
clusters/homelab/       Root kustomization Flux reconciles
infrastructure/sources/ HelmRepository definitions
infrastructure/smb-csi/ SMB CSI driver HelmRelease
infrastructure/traefik/ Traefik HelmChartConfig (adds LMS port-9000 entrypoint)
infrastructure/volsync/ Volsync backup operator HelmRelease
apps/media/             Namespace, storage, app manifests, ingress
apps/media/backup/      Volsync ReplicationSource manifests (nightly backups)
scripts/                Helper scripts for bootstrap, secrets, and restore
docs/                   This documentation
```

---

## How secrets are handled

No passwords are stored in this repository.

| Secret name | Namespace | Keys | Purpose |
|---|---|---|---|
| `media-smb-credentials` | `media` | `username`, `password` | Mounts SMB media shares |
| `homepage-secrets` | `media` | `HOMEPAGE_VAR_AUDIOBOOKSHELF_API_KEY` | Homepage widget API token |
| `audiobookshelf-config-volsync-secret` | `media` | `RESTIC_REPOSITORY`, `RESTIC_PASSWORD`, `RCLONE_CONFIG` | Volsync backup of Audiobookshelf config |
| `lyrion-config-volsync-secret` | `media` | `RESTIC_REPOSITORY`, `RESTIC_PASSWORD`, `RCLONE_CONFIG` | Volsync backup of Lyrion config |

All secrets are created by helper scripts during bootstrap. See the sections below.

---

## Prerequisites

The following must be in place before running the setup script:

1. **A Linux server** with `sudo` access where k3s will run (or already running).
2. **SMB shares** reachable from the server:
   - `//10.1.10.10/Audiobooks`
   - `//10.1.10.10/Music`
   - `//10.1.10.10/Music Lossless`
   - `//10.1.10.10/Config/backup` (writable — used for nightly config backups)
3. **A GitHub personal access token** (`GITHUB_TOKEN`) with repo admin permissions, used by Flux bootstrap.
4. **SMB credentials** (username and password) for the shares above.
5. **Audiobookshelf API key** — created in Audiobookshelf after the first admin login, so this is configured in a second step after deployment.

---

## Step 1: Bootstrap the cluster

`scripts/setup-homelab-prereqs.sh` handles the cluster bootstrap in one command. It:

1. Installs OS prerequisites (`curl`, `sha256sum`) if missing.
2. Installs k3s unless `--skip-k3s` is passed or k3s is already present.
3. Configures `KUBECONFIG`.
4. Installs Helm and the Flux CLI (checksum-verified).
5. Bootstraps Flux to this repository at `clusters/homelab` on branch `main`.
6. Creates the `media` namespace and the `media-smb-credentials` secret.

```bash
export GITHUB_TOKEN='<your-github-token>'
echo '<your-smb-password>' | \
bash ./scripts/setup-homelab-prereqs.sh \
  --github-owner richcorless \
  --github-repo homeserver \
  --github-branch main \
  --flux-path clusters/homelab \
  --smb-username '<your-smb-username>' \
  --smb-password-stdin \
  --media-namespace media \
  --smb-secret-name media-smb-credentials \
  --github-personal true
```

Pass `--skip-k3s` if k3s is already installed.

---

## Step 2: Create Volsync backup secrets

Once Flux has reconciled (Volsync operator installed, `media` namespace ready), create the backup secrets:

```bash
echo '<your-smb-password>' | \
bash ./scripts/setup-volsync-secrets.sh \
  --smb-username '<your-smb-username>' \
  --smb-password-stdin \
  --namespace media
```

> **Important:** The script generates a restic encryption password and prints it once. Save it in a password manager immediately. You need it to restore from backup.

To use your own restic password:

```bash
echo '<your-smb-password>' | \
bash ./scripts/setup-volsync-secrets.sh \
  --smb-username '<your-smb-username>' \
  --smb-password-stdin \
  --restic-password '<your-chosen-restic-password>' \
  --namespace media
```

---

## Step 3: Configure the Homepage API key

After Flux has reconciled Homepage and you have created an Audiobookshelf admin account, run:

```bash
bash ./scripts/setup-homepage-secrets.sh \
  --media-namespace media \
  --homepage-secret-name homepage-secrets
```

The script prompts for the Audiobookshelf API key. For non-interactive use:

```bash
echo '<your-api-key>' | \
bash ./scripts/setup-homepage-secrets.sh \
  --media-namespace media \
  --audiobookshelf-api-key-stdin
```

---

## Force a Flux reconciliation

```bash
flux reconcile kustomization flux-system --with-source
```

---

## Manual setup (alternative to scripts)

### Install Helm

```bash
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```

### Install and bootstrap Flux CLI

> The version and checksum below were current at the time of writing. Check [github.com/fluxcd/flux2/releases](https://github.com/fluxcd/flux2/releases) for the latest stable version and update the checksum accordingly.

```bash
curl -fsSL -o /tmp/install-flux.sh https://raw.githubusercontent.com/fluxcd/flux2/v2.6.4/install/flux.sh
echo 'bd7765225b731a1df952456eced0abb5dbbf5e11bc70cf6ab5fddd1476088b7e  /tmp/install-flux.sh' | sha256sum --check
sudo bash /tmp/install-flux.sh

export GITHUB_TOKEN='<your-github-token>'
flux bootstrap github \
  --owner=richcorless \
  --repository=homeserver \
  --branch=main \
  --path=clusters/homelab \
  --personal \
  --token-auth
```

### Create required secrets manually

```bash
kubectl create namespace media
kubectl -n media create secret generic media-smb-credentials \
  --from-literal=username='<your-smb-username>' \
  --from-literal=password='<your-smb-password>'
```

Then run `scripts/setup-volsync-secrets.sh` and `scripts/setup-homepage-secrets.sh` as above.

---

## Accessing services

k3s ships Traefik as the built-in ingress controller.

### Homepage

```
http://homeserver.local/
```

Provides quick links and health status for all apps. Validates `Host` header against `HOMEPAGE_ALLOWED_HOSTS` — add any extra hostnames or IPs in `apps/media/homepage/deployment.yaml`.

### Audiobookshelf

```
http://homeserver.local/audiobookshelf
```

The `strip-audiobookshelf` Traefik Middleware removes the prefix before forwarding to the backend. `BASE_URL=/audiobookshelf` tells Audiobookshelf to generate correct redirect URLs.

### Lyrion Music Server (LMS)

```
http://homeserver.local:9000
```

LMS does not support subfolder paths. Traefik is configured with a dedicated entrypoint on port 9000 so all LMS internal redirects resolve correctly.

---

## Future HTTPS and SSO

The ingress model is set up so HTTPS and SSO can be added centrally:

- Add `spec.tls` to Ingress resources in `apps/media/ingress.yaml` and issue certificates (e.g. with cert-manager).
- Add a Traefik `Middleware` with ForwardAuth in `apps/media/ingress.yaml` for SSO (e.g. oauth2-proxy or authentik).

---

## Notes

- If your SMB share names or server change, update the PV manifests in `apps/media/storage/`.
- If your cluster does not use the `local-path` StorageClass, update the config PVC manifests.
- If your server hostname is not `homeserver.local`, update `apps/media/homepage/config/services.yaml` and `apps/media/homepage/deployment.yaml`.
- Homepage config files live in `apps/media/homepage/config/` and use a kustomize `configMapGenerator`. Any change to a config file automatically triggers a rolling update — no manual restart needed.
- If LAN player discovery over UDP must be exposed, prefer a Traefik UDP entrypoint rather than enabling app `hostNetwork`.
