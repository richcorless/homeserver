# homeserver

GitOps repository for deploying services to a k3s cluster with Flux and Helm.

## What is deployed

- Audiobookshelf
- Lyrion Music Server

Both apps mount media from a remote SMB server at `10.1.10.10`.

## Repository layout

- `/clusters/homelab` - root kustomization Flux should reconcile
- `/infrastructure/sources` - HelmRepository definitions
- `/apps/media` - namespace, storage, and app HelmReleases

## How secrets are handled

No username/password is stored in this repository.

The SMB PV references a Kubernetes secret named `media-smb-credentials` in the `media` namespace:

- `username`
- `password`

You create this secret on your local cluster before Flux reconciliation.

## Local server prerequisites

1. k3s cluster is running.
2. Flux is installed and pointed at this repo, path `clusters/homelab`.
3. SMB CSI driver is installed (`smb.csi.k8s.io`).
4. The SMB share exists on `10.1.10.10` (configured in `apps/media/storage/media-library-pv.yaml` as `//10.1.10.10/media`).
5. Create namespace and credentials secret:

```bash
kubectl create namespace media
kubectl -n media create secret generic media-smb-credentials \
  --from-literal=username='<your-smb-username>' \
  --from-literal=password='<your-smb-password>'
```

## Deploy

Once Flux is connected to this repository and the secret exists, Flux will reconcile:

- namespace + PV/PVCs
- Audiobookshelf HelmRelease
- Lyrion HelmRelease

You can force reconciliation with:

```bash
flux reconcile kustomization flux-system --with-source
```

## Notes

- If your SMB share path is not `//10.1.10.10/media`, update `apps/media/storage/media-library-pv.yaml`.
- If your cluster does not use the `local-path` StorageClass, update the config PVC manifests.
