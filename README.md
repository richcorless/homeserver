# homeserver

GitOps repository for deploying services to a k3s cluster with Flux and Helm.

## What is deployed

- Traefik (k3s built-in ingress controller)
- Homepage
- Audiobookshelf
- Lyrion Music Server

Both apps mount media from a remote SMB server at `10.1.10.10`.

## Repository layout

- `/clusters/homelab` - root kustomization Flux should reconcile
- `/infrastructure/sources` - HelmRepository definitions
- `/infrastructure/traefik` - Traefik `HelmChartConfig` pinning Traefik and adding the LMS-specific port-9000 entrypoint
- `/apps/media` - namespace, storage, app manifests, HelmReleases, Traefik Middleware, Ingress, and IngressRoute resources

## How secrets are handled

No username/password is stored in this repository.

The SMB PVs reference a Kubernetes secret named `media-smb-credentials` in the `media` namespace:

- `username`
- `password`

Homepage references a Kubernetes secret named `homepage-secrets` in the `media` namespace:

- `HOMEPAGE_VAR_AUDIOBOOKSHELF_API_KEY`

This key should contain an Audiobookshelf admin API token. You can find it in the Audiobookshelf web UI under **Settings → Users → your account** after the initial admin account is created.

The SMB secret is created during bootstrap. The Homepage secret is populated separately after Audiobookshelf is deployed, because the API token does not exist until after the first admin login.

## Prerequisites

The following must be in place before running the setup script. They cannot be automated:

1. **A Linux server** with `sudo` access where k3s will run (or already running).
2. **SMB shares** reachable from the server:
   - `//10.1.10.10/Audiobooks`
   - `//10.1.10.10/Music`
   - `//10.1.10.10/Music Lossless`
3. **A GitHub personal access token** (`GITHUB_TOKEN`) with repo admin permissions, used by Flux bootstrap.
4. **SMB credentials** (username and password) for the shares above.
5. **Audiobookshelf API key** for Homepage's Audiobookshelf widget. This is created in Audiobookshelf after the first admin login, so it is configured in a second step after deployment.

## Setup (recommended: bootstrap, then configure Homepage secret)

`scripts/setup-homelab-prereqs.sh` handles the cluster bootstrap in one command. It:

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

After Flux has reconciled Homepage and you have created an Audiobookshelf admin account, run:

```bash
bash ./scripts/setup-homepage-secrets.sh \
  --media-namespace media \
  --homepage-secret-name homepage-secrets
```

The script prompts for the Audiobookshelf API key, updates `homepage-secrets`, and restarts the Homepage deployment so the widget picks up the new value. `--homepage-secret-name` is optional and defaults to `homepage-secrets`. For non-interactive use, pass `--audiobookshelf-api-key` or pipe the key with `--audiobookshelf-api-key-stdin`, for example:

```bash
echo '<your-audiobookshelf-api-key>' | \
  bash ./scripts/setup-homepage-secrets.sh \
    --media-namespace media \
    --audiobookshelf-api-key-stdin
```

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

### Create required secrets

```bash
kubectl create namespace media
kubectl -n media create secret generic media-smb-credentials \
  --from-literal=username='<your-smb-username>' \
  --from-literal=password='<your-smb-password>'
```

After Audiobookshelf is deployed and you have an admin API key:

```bash
bash ./scripts/setup-homepage-secrets.sh \
  --media-namespace media \
  --homepage-secret-name homepage-secrets
```

## Deploy

Once Flux is connected to this repository and the SMB secret exists, Flux will reconcile:

- namespace + PV/PVCs
- Audiobookshelf HelmRelease
- Lyrion HelmRelease
- Homepage Deployment + Service + ConfigMap + Ingress
- Traefik Middleware and path-based Ingress resources

After Audiobookshelf is usable, run `scripts/setup-homepage-secrets.sh` to populate `homepage-secrets` and restart Homepage.

You can force reconciliation with:

```bash
flux reconcile kustomization flux-system --with-source
```

## Access services through Traefik

k3s ships with Traefik as its built-in ingress controller. No extra deployment is needed.

### Homepage

```
http://homeserver.local/
```

Homepage is served from the root URL and provides quick links plus health visibility for Audiobookshelf and LMS. Homepage validates the `Host` header against the exact entries in `HOMEPAGE_ALLOWED_HOSTS`, so any additional hostname or IP you want to use must be added explicitly in `apps/media/homepage/deployment.yaml`.

### Audiobookshelf

```
http://homeserver.local/audiobookshelf
```

Configured in `apps/media/ingress.yaml`. The `strip-audiobookshelf` Middleware removes the prefix before forwarding to the backend, and the `add-audiobookshelf-prefix` Middleware sends `X-Forwarded-Prefix: /audiobookshelf` so that Audiobookshelf generates correct redirect URLs. The `BASE_URL=/audiobookshelf` environment variable tells Audiobookshelf to use the subfolder path for all internal links and redirects.

### Lyrion Music Server (LMS)

```
http://homeserver.local:9000
```

LMS does not support being served from a subfolder — it generates root-relative redirect URLs (e.g. `/settings/server/wizard.html`) that a subpath proxy cannot transparently rewrite. Instead, Traefik is configured with a dedicated entrypoint on port 9000 (via `infrastructure/traefik/helmchartconfig.yaml`) and an `IngressRoute` (in `apps/media/lyrion/ingressroute.yaml`) that routes all traffic on that port directly to the `lyrion-main` service at `/`. This means all internal LMS redirects resolve correctly.

LMS should remain behind Kubernetes services and Traefik entrypoints (no `hostNetwork`) so edge port ownership stays centralized in Traefik.

Homepage now serves `/` on port 80, while LMS remains available directly on port 9000.

## Future HTTPS and SSO

The single ingress model is set up so HTTPS and SSO can be added centrally later:

- add `spec.tls` to the Ingress resources in `apps/media/ingress.yaml` and issue certificates (for example with cert-manager)
- add a Traefik `Middleware` with ForwardAuth in `apps/media/ingress.yaml` to integrate an SSO gateway (e.g. oauth2-proxy or authentik)

## Notes

- If your SMB share names or server change, update:
  - `apps/media/storage/audiobooks-pv.yaml`
  - `apps/media/storage/music-pv.yaml`
  - `apps/media/storage/music-lossless-pv.yaml`
- If your cluster does not use the `local-path` StorageClass, update the config PVC manifests.
- If your server hostname is not `homeserver.local`, update:
  - `apps/media/homepage/config/services.yaml` (`Lyrion Music Server.href`)
  - `apps/media/homepage/deployment.yaml` (`HOMEPAGE_ALLOWED_HOSTS`)
- Homepage config files live in `apps/media/homepage/config/` and are managed by a kustomize `configMapGenerator`. Whenever any config file changes, kustomize generates a new ConfigMap name (content hash suffix) which forces a rolling update of the Homepage pod automatically — no manual restart needed.
- `LOG_LEVEL=debug` is set in the Deployment to surface full error context in the pod logs (e.g. `kubectl -n media logs deploy/homepage`). Remove or change it to `info` once the blank `error:` log is resolved.
- Keep the `$(MY_POD_IP):3000` entry in `apps/media/homepage/deployment.yaml` so Kubernetes health checks can reach Homepage on the pod IP.
- Homepage matches `HOMEPAGE_ALLOWED_HOSTS` exactly; CIDR ranges are not supported. Add each allowed hostname or IP explicitly in `apps/media/homepage/deployment.yaml`, and keep Traefik `forwardedHeaders.trustedIPs` aligned with the networks that may send forwarded headers.
- If LAN player discovery over UDP (for example SlimProto/UPnP-related traffic) must be exposed, prefer adding a Traefik-managed UDP entrypoint/router rather than enabling app `hostNetwork`.
