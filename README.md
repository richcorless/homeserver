# homeserver

GitOps repository for deploying services to a k3s cluster with Flux and Helm.

## What is deployed

- ingress-nginx (single cluster ingress/reverse proxy)
- Audiobookshelf
- Lyrion Music Server

Both apps mount media from a remote SMB server at `10.1.10.10`.

## Repository layout

- `/clusters/homelab` - root kustomization Flux should reconcile
- `/infrastructure/sources` - HelmRepository definitions
- `/apps/ingress-nginx` - ingress controller HelmRelease
- `/apps/media` - namespace, storage, app HelmReleases, and shared Ingress

## How secrets are handled

No username/password is stored in this repository.

The SMB PVs reference a Kubernetes secret named `media-smb-credentials` in the `media` namespace:

- `username`
- `password`

This secret is created by the setup script (or manually, see below) before Flux reconciliation begins.

## Prerequisites

The following must be in place before running the setup script. They cannot be automated:

1. **A Linux server** with `sudo` access where k3s will run (or already running).
2. **SMB shares** reachable from the server:
   - `//10.1.10.10/Audiobooks`
   - `//10.1.10.10/Music`
   - `//10.1.10.10/Music Lossless`
3. **A GitHub personal access token** (`GITHUB_TOKEN`) with repo admin permissions, used by Flux bootstrap.
4. **SMB credentials** (username and password) for the shares above.

## Setup (recommended: one-shot script)

`scripts/setup-homelab-prereqs.sh` handles the full cluster bootstrap in one command. It:

1. Installs OS prerequisites (`curl`, `sha256sum`/`coreutils`) if missing.
2. Installs k3s unless `--skip-k3s` is passed or k3s is already present.
3. Configures `KUBECONFIG` by exporting `/etc/rancher/k3s/k3s.yaml` if not already set.
4. Installs Helm if missing (checksum-verified).
5. Verifies `kubectl` is available.
6. Installs the Flux CLI if missing (checksum-verified).
7. Bootstraps Flux with `source-controller`, `kustomize-controller`, and `helm-controller` components to this repository at `clusters/homelab` on branch `main`.
8. Creates the `media` namespace and the `media-smb-credentials` secret.

> The SMB CSI driver (v1.20.1) is deployed by Flux from `infrastructure/smb-csi/`.

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

## Manual setup (alternative)

If you prefer to set up each component individually instead of using the script:

### Install Helm

```bash
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```

### Install and bootstrap Flux CLI

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

### Create SMB credentials secret

```bash
kubectl create namespace media
kubectl -n media create secret generic media-smb-credentials \
  --from-literal=username='<your-smb-username>' \
  --from-literal=password='<your-smb-password>'
```

## Deploy

Once Flux is connected to this repository and the secret exists, Flux will reconcile:

- ingress-nginx controller
- namespace + PV/PVCs
- Audiobookshelf HelmRelease
- Lyrion HelmRelease
- media path-based Ingress

You can force reconciliation with:

```bash
flux reconcile kustomization flux-system --with-source
```

## Access services through nginx ingress

With ingress-nginx running, use:

- `http://<server>/audiobookshelf`
- `http://<server>/lms`

These paths are configured in `apps/media/ingress.yaml` and rewritten to each app root path.

## Future HTTPS and SSO

The single ingress model is set up so HTTPS and SSO can be added centrally later:

- add `spec.tls` to `apps/media/ingress.yaml` and issue certificates (for example with cert-manager)
- add nginx auth annotations in `apps/media/ingress.yaml` to integrate an SSO gateway (e.g. oauth2-proxy or authentik)

## Notes

- If your SMB share names or server change, update:
  - `apps/media/storage/audiobooks-pv.yaml`
  - `apps/media/storage/music-pv.yaml`
  - `apps/media/storage/music-lossless-pv.yaml`
- If your cluster does not use the `local-path` StorageClass, update the config PVC manifests.
