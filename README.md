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

You create this secret on your local cluster before Flux reconciliation.

## Local server prerequisites

1. k3s cluster is running.
2. Flux is installed and pointed at this repo, path `clusters/homelab`.
3. SMB shares exist on `10.1.10.10`:
   - `//10.1.10.10/Audiobooks`
   - `//10.1.10.10/Music`
   - `//10.1.10.10/Music_Flac`
4. SMB CSI driver is installed (`smb.csi.k8s.io`).
5. NGINX Ingress Controller is installed by Flux from `apps/ingress-nginx`.

## Install SMB CSI driver on k3s

Install the upstream SMB CSI Helm chart:

```bash
helm repo add csi-driver-smb https://raw.githubusercontent.com/kubernetes-csi/csi-driver-smb/master/charts
helm repo update
helm upgrade --install csi-driver-smb csi-driver-smb/csi-driver-smb \
  --namespace kube-system
```

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
  - `apps/media/storage/music-flac-pv.yaml`
- If your cluster does not use the `local-path` StorageClass, update the config PVC manifests.
