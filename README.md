# PTP Operator Catalog Builder

Build the PTP operator image, generate an OLM bundle and catalog with
correct image references, and deploy the catalog to an OpenShift cluster.

## Quick Start

```bash
cd ptp-work

# Build operator, generate bundle + catalog, push everything, deploy
./ptp-operator-catalog/build-and-deploy-catalog.sh \
    --lptpd-img quay.io/openshift/origin-ptp:5.0 \
    --krp-img   quay.io/openshift/origin-kube-rbac-proxy:5.0 \
    --cep-img   quay.io/openshift/origin-cloud-event-proxy:5.0
```

## What Gets Built vs. Referenced

| Image | Built by this script? | How it ends up in the catalog |
|-------|----------------------|-------------------------------|
| `ptp-operator` | Yes — compiled from source | CSV `spec.install.deployments[].containers[].image` |
| `lptpd` (linuxptp-daemon) | No — pull spec only | CSV env var `LINUXPTP_DAEMON_IMAGE` |
| `krp` (kube-rbac-proxy) | No — pull spec only | CSV env var `KUBE_RBAC_PROXY_IMAGE` |
| `cep` (cloud-event-proxy) | No — pull spec only | CSV env var `SIDECAR_EVENT_IMAGE` |
| `ptp-operator-bundle` | Yes — FROM scratch + CSV + CRDs | Catalog `olm.package` entry |
| `ptp-operator-catalog` | Yes — file-based catalog | ClusterCatalog / CatalogSource `spec.image` |

The operator reads the three component env vars at runtime to decide which
images to use when creating DaemonSets.

## Image Reference Flow

```
--lptpd-img / --krp-img / --cep-img
        │
        ▼
  make update-env-yaml     ──→  patches config/manager/env.yaml
        │
        ▼
  make bundle              ──→  operator-sdk reads env.yaml
        │                          ↓
        │                     generates CSV with env var values
        │                          ↓
        │                     restores env.yaml (git tree stays clean)
        ▼
  make bundle-build        ──→  FROM scratch image containing the CSV
        │
        ▼
  make catalog-build       ──→  opm render + channel.yaml → catalog image
        │
        ▼
  make catalog-deploy      ──→  creates ClusterCatalog + CatalogSource
```

## Script Options

```
Usage:
  ./ptp-operator-catalog/build-and-deploy-catalog.sh [options]

Component image flags (pull specs, not built):
  --lptpd-img <ref>     linuxptp-daemon image       (env: LINUXPTP_DAEMON_IMAGE)
  --krp-img <ref>       kube-rbac-proxy image       (env: KUBE_RBAC_PROXY_IMAGE)
  --cep-img <ref>       cloud-event-proxy image     (env: SIDECAR_EVENT_IMAGE)

Build/deploy flags:
  --registry <path>     Registry prefix             (default: quay.io/vgrinber)
  --version <ver>       Operator version            (default: 5.0)
  --channel <name>      OLM bundle channel          (default: alpha)
  --build               Build operator image only
  --push                Push operator + bundle + catalog images
  --deploy              Deploy catalog to cluster only
  --undeploy            Remove catalog from cluster
  --all                 Build + push + deploy        (default)
  -h, --help            Show help
```

## Examples

### Full build with upstream component images

```bash
./ptp-operator-catalog/build-and-deploy-catalog.sh \
    --lptpd-img quay.io/openshift/origin-ptp:5.0 \
    --krp-img   quay.io/openshift/origin-kube-rbac-proxy:5.0 \
    --cep-img   quay.io/openshift/origin-cloud-event-proxy:5.0
```

### Mix: your own lptpd, upstream cep

```bash
./ptp-operator-catalog/build-and-deploy-catalog.sh \
    --lptpd-img quay.io/vgrinber/lptpd:v2.1 \
    --krp-img   quay.io/openshift/origin-kube-rbac-proxy:5.0 \
    --cep-img   quay.io/openshift/origin-cloud-event-proxy:5.0
```

### Build + push only (no cluster access needed)

```bash
./ptp-operator-catalog/build-and-deploy-catalog.sh --build --push
```

### Deploy an already-pushed catalog

```bash
./ptp-operator-catalog/build-and-deploy-catalog.sh --deploy
```

### Custom registry and version

```bash
./ptp-operator-catalog/build-and-deploy-catalog.sh \
    --registry myregistry.com/myorg \
    --version 5.1 \
    --lptpd-img myregistry.com/myorg/lptpd:v2.1 \
    --krp-img   myregistry.com/myorg/krp:v1.0 \
    --cep-img   quay.io/openshift/origin-cloud-event-proxy:5.0
```

## Prerequisites

- **podman** (or docker — override with `CONTAINER_TOOL` env var)
- **opm**, **operator-sdk**, **kustomize**, **controller-gen**
  (downloaded automatically by the Makefile if missing)
- **Cluster access** (`oc`/`kubectl`) for deploy/undeploy
- The component images (`--lptpd-img`, `--krp-img`, `--cep-img`) must
  already exist in their registries — this script does not build them

## Verify After Deploy

```bash
oc get catalogsource ptp-operator-catalog -n openshift-marketplace
oc get clustercatalog ptp-operator-catalog
oc get packagemanifest ptp-operator
```

## Default Image References

When component image flags are omitted, these defaults are used
(based on the `--registry` value):

| Env Var | Default |
|---------|---------|
| `LINUXPTP_DAEMON_IMAGE` | `<registry>/lptpd:latest` |
| `KUBE_RBAC_PROXY_IMAGE` | `<registry>/krp:latest` |
| `SIDECAR_EVENT_IMAGE` | `<registry>/cep:latest` |

## Source Layout

```
ptp-work/
├── ptp-operator-catalog/
│   ├── build-and-deploy-catalog.sh    ← this script
│   ├── extra-manifests/               ← applied on --deploy (lexical order)
│   │   ├── ns.yaml                    ← openshift-ptp Namespace
│   │   ├── og.yaml                    ← OperatorGroup
│   │   └── subscription.yaml          ← Subscription → installs operator
│   └── DEADME.md                      ← this file
└── np-ptp-operator/
    ├── Dockerfile                     ← operator image build
    ├── Makefile                       ← bundle, catalog, deploy targets
    ├── hack/
    │   ├── env.sh                     ← official image digest resolution
    │   └── catalog-deploy.sh          ← creates CatalogSource + ClusterCatalog
    ├── config/manager/env.yaml        ← component image env vars (template)
    └── ptp-tools/                     ← (not used by this script)
```
