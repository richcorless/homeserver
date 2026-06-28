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
- `/apps` - namespace, storage, app HelmReleases, and shared Ingress

## How secrets are handled

No username/password is stored in this repository.

The SMB PVs reference a Kubernetes secret named `media-smb-credentials` in the `media` namespace:

- `username`
- `password`

You create this secret on your local cluster before Flux reconciliation.

## Local server prerequisites

1. k3s cluster is running.
2. Flux is installed and pointed at this repo, path `clusters/homelab`.
3. SMB shares exist on `10.1.10.10`:
   - `//10.1.10.10/Audiobooks`
   - `//10.1.10.10/Music`
   - `//10.1.10.10/Music Lossless`
4. SMB CSI driver is installed (`smb.csi.k8s.io`).
5. NGINX Ingress Controller is installed by Flux from `apps/ingress-nginx`.

## Install and bootstrap Flux

Install Flux CLI:

```bash
curl -fsSL -o /tmp/install-flux.sh https://raw.githubusercontent.com/fluxcd/flux2/v2.6.4/install/flux.sh
echo 'bd7765225b731a1df952456eced0abb5dbbf5e11bc70cf6ab5fddd1476088b7e  /tmp/install-flux.sh' | sha256sum --check
sudo bash /tmp/install-flux.sh
```

Bootstrap Flux against this repository (requires `GITHUB_TOKEN` with repo admin permissions):

```bash
export GITHUB_TOKEN='<your-github-token>'
flux bootstrap github \
  --owner=richcorless \
  --repository=homeserver \
  --branch=main \
  --path=clusters/homelab \
  --personal \
  --token-auth
```

After bootstrap, Flux will reconcile this repo path automatically.

## Install SMB CSI driver on k3s

Install the upstream SMB CSI Helm chart:

```bash
helm repo add csi-driver-smb https://raw.githubusercontent.com/kubernetes-csi/csi-driver-smb/release-1.20/charts
helm repo update
helm upgrade --install csi-driver-smb csi-driver-smb/csi-driver-smb \
  --namespace kube-system \
  --version 1.20.1
```

If you change SMB CSI chart major/minor versions, update both the chart version and repo URL together.

Confirm the driver is registered:

```bash
kubectl get csidriver smb.csi.k8s.io
```

## Create SMB credentials secret in the cluster

Create namespace and credentials secret:

```bash
kubectl create namespace media
kubectl -n media create secret generic media-smb-credentials \
  --from-literal=username='<your-smb-username>' \
  --from-literal=password='<your-smb-password>'
```

## One-shot setup script

You can run the included script to install/bootstrap Flux, install SMB CSI, and create/update the SMB secret:

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

These paths are configured in `apps/ingress.yaml` and rewritten to each app root path.

## Future HTTPS and SSO

The single ingress model is set up so HTTPS and SSO can be added centrally later:

- add `spec.tls` to `apps/ingress.yaml` and issue certificates (for example with cert-manager)
- add nginx auth annotations in `apps/ingress.yaml` to integrate an SSO gateway (e.g. oauth2-proxy or authentik)

## Notes

- If your SMB share names or server change, update:
  - `apps/storage/audiobooks-pv.yaml`
  - `apps/storage/music-pv.yaml`
  - `apps/storage/music-lossless-pv.yaml`
- If your cluster does not use the `local-path` StorageClass, update the config PVC manifests.
