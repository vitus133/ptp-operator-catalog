#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# build-and-deploy-catalog.sh
#
# Builds the PTP operator image, generates an OLM bundle and
# catalog, and deploys the catalog to the cluster.
#
# The operator references external component images (linuxptp-daemon,
# kube-rbac-proxy, cloud-event-proxy) via env vars.  These are NOT
# built by this script — you provide their pull specs and they get
# baked into the CSV during bundle generation.
#
# Image reference flow:
#   1. Operator image      → built from np-ptp-operator/Dockerfile
#   2. Component images    → pull specs accepted via flags,
#                             written into env.yaml, end up in CSV
#   3. Bundle image        → FROM scratch, contains CSV + CRDs
#   4. Catalog image       → points at the bundle image
#
# Usage:
#   cd ptp-work
#   ./ptp-operator-catalog/build-and-deploy-catalog.sh [options]
# ./ptp-operator-catalog/build-and-deploy-catalog.sh --auto-version --build --push --deploy
# ============================================================

# --- Defaults ---
REGISTRY="quay.io/vgrinber"
VERSION="5.0.0"
CHANNEL="alpha"
MIN_KUBE_VERSION="1.33.0"
AUTO_VERSION=true

LPTPD_IMG="quay.io/vgrinber/linuxptp-daemon:main"
KRP_IMG="quay.io/openshift/origin-kube-rbac-proxy:5.0"
CEP_IMG="quay.io/vgrinber/cloud-event-proxy:main"

DO_BUILD=true
DO_PUSH=true
DO_DEPLOY=false
DO_UNDEPLOY=false
DO_ALL=false

# --- Resolve paths relative to this script ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PTP_OP_DIR="$(cd "${SCRIPT_DIR}/../np-ptp-operator" && pwd)"

# --- Helper functions ---

info()  { echo -e "\033[34mINFO\033[0m  $*"; }
ok()    { echo -e "\033[32mOK\033[0m    $*"; }
warn()  { echo -e "\033[33mWARN\033[0m  $*"; }
error() { echo -e "\033[31mERROR\033[0m $*" >&2; }
die()   { error "$@"; exit 1; }

usage() {
    cat <<'EOF'
build-and-deploy-catalog.sh

Build the PTP operator image, generate an OLM bundle and catalog
with correct image references, and deploy the catalog to the cluster.

USAGE
    cd ptp-work
    ./ptp-operator-catalog/build-and-deploy-catalog.sh [options]

COMPONENT IMAGE FLAGS
    These are pull specs for pre-built images that the operator
    references at runtime via env vars.  They are NOT built here —
    only baked into the CSV.

    --lptpd-img <ref>   linuxptp-daemon image        (env: LINUXPTP_DAEMON_IMAGE)
    --krp-img <ref>     kube-rbac-proxy image        (env: KUBE_RBAC_PROXY_IMAGE)
    --cep-img <ref>     cloud-event-proxy image      (env: SIDECAR_EVENT_IMAGE)

    If omitted, defaults to ${REGISTRY}/<component>:latest based on
    the current --registry value.  Override to point at upstream or
    any other registry.

BUILD/DEPLOY FLAGS
    --registry <path>   Registry prefix               (default: quay.io/vgrinber)
    --version <ver>     Operator version               (default: 5.0.0)
    --auto-version       Pull latest bundle from registry and increment version (default)
    --no-auto-version    Use --version as-is, do not auto-increment
    --min-kube-version <ver>
                        CSV spec.minKubeVersion (default: 1.33.0)
    --build             Build operator image only
    --push              Push operator + bundle + catalog images
    --deploy            Deploy catalog to cluster only
    --undeploy          Remove catalog from cluster
    --all               Build + push + deploy           (default)
    -h, --help          Show this help

    On --deploy, every *.yaml under ./extra-manifests/ is applied in
    lexical order (namespace, OperatorGroup, Subscription, etc.).

EXAMPLES
    # Full build with upstream component images
    ./ptp-operator-catalog/build-and-deploy-catalog.sh \
        --lptpd-img quay.io/openshift/origin-ptp:5.0 \
        --krp-img   quay.io/openshift/origin-kube-rbac-proxy:5.0 \
        --cep-img   quay.io/openshift/origin-cloud-event-proxy:5.0

    # Build with a mix — own lptpd, upstream cep
    ./ptp-operator-catalog/build-and-deploy-catalog.sh \
        --lptpd-img myregistry.com/myorg/lptpd:v2.1 \
        --cep-img   quay.io/openshift/origin-cloud-event-proxy:5.0

    # Build only (no cluster access needed)
    ./ptp-operator-catalog/build-and-deploy-catalog.sh --build --push

    # Deploy existing catalog
    ./ptp-operator-catalog/build-and-deploy-catalog.sh --deploy

WHAT GETS BUILT
    Operator image:    <registry>/ptp-operator:<version>       (built from source)
    Bundle image:      <registry>/ptp-operator-bundle:v<ver>  (FROM scratch + CSV)
    Catalog image:     <registry>/ptp-operator-catalog:v<ver> (points at bundle)

COMPONENT IMAGES (not built, pull specs only)
    LINUXPTP_DAEMON_IMAGE   = <lptpd-img>    (creates linuxptp-daemon DaemonSet)
    KUBE_RBAC_PROXY_IMAGE   = <krp-img>      (sidecar for metrics)
    SIDECAR_EVENT_IMAGE     = <cep-img>      (sidecar for events)

PREREQUISITES
    - podman (or docker, override with CONTAINER_TOOL env var)
    - opm, operator-sdk, kustomize, controller-gen
      (downloaded automatically by the Makefile if missing)
    - Cluster access (oc/kubectl) for deploy/undeploy
EOF
    exit 0
}

# --- Ensure toolchain: opm (via make), yq (manual download) ---
# The Makefile's catalog targets invoke bare 'opm' and 'yq' (not $(OPM)/
# $(YQ)), and neither has a download target.  We bootstrap both into
# ${PTP_OP_DIR}/bin and add it to PATH so those bare calls resolve.
ensure_tools() {
    info "Ensuring opm is installed"
    (
        cd "${PTP_OP_DIR}"
        make opm
    )

    TOOLS_BIN="${PTP_OP_DIR}/bin"
    mkdir -p "${TOOLS_BIN}"

    if [[ ! -x "${TOOLS_BIN}/yq" ]]; then
        info "Downloading yq to ${TOOLS_BIN}/yq"
        local yq_os yq_arch
        case "$(uname -s)" in
            Linux)  yq_os="linux" ;;
            Darwin) yq_os="darwin" ;;
            *)      yq_os="linux" ;;
        esac
        case "$(uname -m)" in
            x86_64|amd64) yq_arch="amd64" ;;
            aarch64|arm64) yq_arch="arm64" ;;
            *)             yq_arch="amd64" ;;
        esac
        curl -sSLo "${TOOLS_BIN}/yq" \
            "https://github.com/mikefarah/yq/releases/download/v4.44.3/yq_${yq_os}_${yq_arch}"
        chmod +x "${TOOLS_BIN}/yq"
        ok "yq installed"
    fi

    export PATH="${TOOLS_BIN}:${PATH}"
    ok "Toolchain ready (opm + yq on PATH)"
}

# --- Patch generated CSV after 'make bundle' ---
# 1. Lower spec.minKubeVersion so OLM will install on older clusters
#    (the base template hardcodes 1.35.0, which fails on 1.33.x servers).
# 2. Declare spec.relatedImages explicitly.  OLM only auto-discovers
#    images from container 'image:' fields, so the component images that
#    the operator pulls via env vars would otherwise be absent.
patch_csv() {
    local csv_file="$1"
    yq -i \
        '.spec.minKubeVersion = "'"${MIN_KUBE_VERSION}"'" |
         .spec.relatedImages = [
           {"name": "ptp-operator",       "image": "'"${OPERATOR_IMG}"'"},
           {"name": "linuxptp-daemon",    "image": "'"${LPTPD_IMG}"'"},
           {"name": "kube-rbac-proxy",    "image": "'"${KRP_IMG}"'"},
           {"name": "cloud-event-proxy",  "image": "'"${CEP_IMG}"'"}
         ]' \
        "${csv_file}"
    ok "Patched ${csv_file} (minKubeVersion=${MIN_KUBE_VERSION}, relatedImages added)"
}

# --- Auto-increment version from registry ---
# Queries the bundle image tags in the registry, finds the latest vX.Y.Z
# (OLM uses symbolic semver versions), and increments the patch version
# (5.0.0 → 5.0.1, 5.0.1 → 5.0.2, etc.).
# IMPORTANT: this function prints ONLY the computed version to stdout.
# All logging must go to stderr, because the caller captures stdout via
# $(...) — anything else on stdout corrupts the returned version.
get_next_version() {
    local registry="$1"
    local bundle_repo="${registry}/ptp-operator-bundle"
    local default_version="$2"

    if ! command -v skopeo >/dev/null 2>&1; then
        warn "skopeo not found, using default version: ${default_version}" >&2
        echo "${default_version}"
        return
    fi

    echo "INFO  Querying registry for latest bundle version: ${bundle_repo}" >&2
    local tags_json
    tags_json=$(skopeo list-tags "docker://${bundle_repo}" 2>/dev/null) || {
        echo "WARN  Could not list tags (repo may not exist yet), using default version: ${default_version}" >&2
        echo "${default_version}"
        return
    }

    # Extract version tags matching vX.Y or vX.Y.Z, normalizing vX.Y to
    # vX.Y.0 so both forms sort correctly together, then take the highest.
    local latest
    latest=$(echo "${tags_json}" | jq -r '.Tags[]' 2>/dev/null \
        | grep -E '^v[0-9]+\.[0-9]+(\.[0-9]+)?$' \
        | sed -E 's/^v([0-9]+\.[0-9]+)$/v\1.0/' \
        | sort -t. -k1,1n -k2,2n -k3,3n \
        | tail -1)

    if [[ -z "$latest" ]]; then
        echo "WARN  No version tags found, using default version: ${default_version}" >&2
        echo "${default_version}"
        return
    fi

    # Increment patch version: v5.2.0 → 5.2.1
    local current="${latest#v}"
    local major minor patch
    IFS='.' read -r major minor patch <<< "$current"
    patch="${patch:-0}"
    local next="${major}.${minor}.$(( patch + 1 ))"
    echo "OK    Latest bundle: ${latest} → next version: ${next}" >&2
    echo "${next}"
}

# --- Parse arguments ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)      usage ;;
        --registry)     REGISTRY="$2";     shift 2 ;;
        --version)      VERSION="$2";      shift 2 ;;
        --auto-version) AUTO_VERSION=true;  shift ;;
        --no-auto-version) AUTO_VERSION=false; shift ;;
        --min-kube-version) MIN_KUBE_VERSION="$2"; shift 2 ;;
        --lptpd-img)    LPTPD_IMG="$2";    shift 2 ;;
        --krp-img)      KRP_IMG="$2";      shift 2 ;;
        --cep-img)      CEP_IMG="$2";      shift 2 ;;
        --build)        DO_BUILD=true;     shift ;;
        --push)         DO_PUSH=true;      shift ;;
        --deploy)       DO_DEPLOY=true;    shift ;;
        --undeploy)     DO_UNDEPLOY=true;  shift ;;
        --all)          DO_ALL=true;       shift ;;
        *) die "Unknown option: $1  (try --help)" ;;
    esac
done

# --- Apply defaults for component image specs ---
LPTPD_IMG="${LPTPD_IMG:-${REGISTRY}/lptpd:latest}"
KRP_IMG="${KRP_IMG:-${REGISTRY}/krp:latest}"
CEP_IMG="${CEP_IMG:-${REGISTRY}/cep:latest}"

# --- Auto-increment version (default on; disable with --no-auto-version) ---
if $AUTO_VERSION; then
    VERSION="$(get_next_version "${REGISTRY}" "${VERSION}")"
fi

# Default to --all when no action flags specified
if ! $DO_BUILD && ! $DO_PUSH && ! $DO_DEPLOY && ! $DO_UNDEPLOY && ! $DO_ALL; then
    DO_ALL=true
fi

if $DO_ALL; then
    DO_BUILD=true
    DO_PUSH=true
    DO_DEPLOY=true
fi

# --- Derived image references ---
OPERATOR_IMG="${REGISTRY}/ptp-operator:${VERSION}"
BUNDLE_IMG="${REGISTRY}/ptp-operator-bundle:v${VERSION}"
CATALOG_IMG="${REGISTRY}/ptp-operator-catalog:v${VERSION}"

# --- Pre-flight checks ---
command -v podman >/dev/null 2>&1 || command -v docker >/dev/null 2>&1 \
    || die "podman or docker required but not found"
command -v make   >/dev/null 2>&1 || die "make required but not found"

cd "${SCRIPT_DIR}/.." || die "Cannot cd to ptp-work root"

# --- Run header ---
echo ""
echo "============================================"
echo " PTP Operator Catalog Builder"
echo "============================================"
echo "  Registry  : ${REGISTRY}"
echo "  Version   : ${VERSION}"
echo "  Channel   : ${CHANNEL}"
echo "  MinKube   : ${MIN_KUBE_VERSION}"
echo ""
echo "  Operator image  : ${OPERATOR_IMG}"
echo "  Bundle image    : ${BUNDLE_IMG}"
echo "  Catalog image   : ${CATALOG_IMG}"
echo ""
echo "  LINUXPTP_DAEMON_IMAGE : ${LPTPD_IMG}"
echo "  KUBE_RBAC_PROXY_IMAGE : ${KRP_IMG}"
echo "  SIDECAR_EVENT_IMAGE   : ${CEP_IMG}"
echo "============================================"
echo ""

# ============================================================
# Phase 1: Build operator image
# ============================================================
if $DO_BUILD; then
    info "Building operator image: ${OPERATOR_IMG}"
    (
        cd "${PTP_OP_DIR}"
        CONTAINER_TOOL=podman IMG="${OPERATOR_IMG}" ARCH=x86_64 make docker-build
    )
    ok "Operator image built"
fi

# ============================================================
# Phase 2: Push operator image
# ============================================================
if $DO_PUSH; then
    info "Pushing operator image: ${OPERATOR_IMG}"
    (
        cd "${PTP_OP_DIR}"
        CONTAINER_TOOL=podman IMG="${OPERATOR_IMG}" ARCH=x86_64 make docker-push
    )
    ok "Operator image pushed"
fi

# ============================================================
# Phase 3: Patch env.yaml and generate OLM bundle + catalog
#          (runs when building or pushing — both need fresh bundle)
# ============================================================
if $DO_BUILD || $DO_PUSH; then

    # Ensure opm + yq are available (yq is needed to patch the CSV below)
    ensure_tools

    # Patch env.yaml with the provided component image pull specs.
    # 'make update-env.yaml' modifies config/manager/env.yaml in-place,
    # creating a .bak backup.  'make bundle' runs this target, generates
    # the CSV, then 'restore-env-yaml' reverts env.yaml so the git
    # tree stays clean.
    info "Patching env.yaml with component image references"
    (
        cd "${PTP_OP_DIR}"
        LINUXPTP_DAEMON_IMAGE="${LPTPD_IMG}" \
        KUBE_RBAC_PROXY_IMAGE="${KRP_IMG}" \
        SIDECAR_EVENT_IMAGE="${CEP_IMG}" \
        make update-env-yaml
    )
    ok "env.yaml patched"

    # Generate the OLM bundle.
    # The 'bundle' target runs: update-env-yaml → kustomize →
    # operator-sdk generate bundle → validate → copy to manifests/stable →
    # restore-env-yaml.  The generated CSV contains:
    #   - The operator image in spec.install.deployments[].containers[].image
    #   - Component image pull specs as env var values
    info "Generating OLM bundle (VERSION=${VERSION}, CHANNEL=${CHANNEL})"
    (
        cd "${PTP_OP_DIR}"
        CONTAINER_TOOL=podman \
        IMG="${OPERATOR_IMG}" \
        ARCH=x86_64 \
        VERSION="${VERSION}" \
        CHANNELS="${CHANNEL}" \
        DEFAULT_CHANNEL="${CHANNEL}" \
        make bundle
    )
    ok "OLM bundle generated"

    # Patch the generated CSV: lower minKubeVersion for older clusters and
    # declare relatedImages (component images are env-var-only, so OLM won't
    # discover them otherwise).
    info "Patching CSV (minKubeVersion=${MIN_KUBE_VERSION}, adding relatedImages)"
    for csv in "${PTP_OP_DIR}"/bundle/manifests/*.clusterserviceversion.yaml; do
        patch_csv "${csv}"
    done
    for csv in "${PTP_OP_DIR}"/manifests/stable/*.clusterserviceversion.yaml; do
        patch_csv "${csv}"
    done

    # Build the bundle image (FROM scratch, contains CSV + CRDs + metadata)
    info "Building bundle image: ${BUNDLE_IMG}"
    (
        cd "${PTP_OP_DIR}"
        CONTAINER_TOOL=podman \
        BUNDLE_IMG="${BUNDLE_IMG}" \
        ARCH=x86_64 \
        make bundle-build
    )
    ok "Bundle image built"

    # Push bundle image (required before catalog-build, which runs opm render)
    info "Pushing bundle image: ${BUNDLE_IMG}"
    (
        cd "${PTP_OP_DIR}"
        CONTAINER_TOOL=podman \
        BUNDLE_IMG="${BUNDLE_IMG}" \
        ARCH=x86_64 \
        make bundle-push
    )
    ok "Bundle image pushed"

    # Generate catalog metadata files
    info "Generating catalog metadata"
    (
        cd "${PTP_OP_DIR}"
        BUNDLE_IMGS="${BUNDLE_IMG}" \
        CATALOG_IMG="${CATALOG_IMG}" \
        CATALOG_DEFAULT_CHANNEL="${CHANNEL}" \
        make catalog/index.yaml catalog/operator.yaml catalog/channel.yaml catalog.Dockerfile
    )
    ok "Catalog metadata generated"

    # Build and push catalog image
    info "Building catalog image: ${CATALOG_IMG}"
    (
        cd "${PTP_OP_DIR}"
        CONTAINER_TOOL=podman \
        BUNDLE_IMGS="${BUNDLE_IMG}" \
        CATALOG_IMG="${CATALOG_IMG}" \
        CATALOG_DEFAULT_CHANNEL="${CHANNEL}" \
        ARCH=x86_64 \
        make catalog-build
    )
    ok "Catalog image built"

    info "Pushing catalog image: ${CATALOG_IMG}"
    (
        cd "${PTP_OP_DIR}"
        CONTAINER_TOOL=podman \
        CATALOG_IMG="${CATALOG_IMG}" \
        ARCH=x86_64 \
        make catalog-push
    )
    ok "Catalog image pushed"

fi

# ============================================================
# Phase 4: Deploy / undeploy catalog to cluster
# ============================================================
if $DO_DEPLOY; then
    # Clean existing OLM resources so OLM re-resolves from the new catalog.
    # Without this, OLM caches the old bundle by image reference and won't
    # pick up changes when the tag stays the same.
    info "Cleaning existing OLM resources"
    oc delete clusteroperator ptp-operator -n openshift-ptp --ignore-not-found 2>/dev/null || true
    oc delete csv -l operators.coreos.com/ptp-operator.openshift-ptp -n openshift-ptp --ignore-not-found 2>/dev/null || true
    oc delete subscription ptp-operator -n openshift-ptp --ignore-not-found 2>/dev/null || true
    oc delete catalogsource ptp-operator-catalog -n openshift-marketplace --ignore-not-found 2>/dev/null || true
    oc delete clustercatalog ptp-operator-catalog -n openshift-marketplace --ignore-not-found 2>/dev/null || true
    ok "Existing OLM resources cleaned"

    info "Deploying catalog to cluster: ${CATALOG_IMG}"
    (
        cd "${PTP_OP_DIR}"
        CATALOG_IMG="${CATALOG_IMG}" \
        make catalog-deploy
    )
    ok "Catalog deployed"

    # Apply everything under extra-manifests/ (namespace, OperatorGroup,
    # Subscription, or any custom manifests the user drops in there).
    # Files are applied in lexical order.
    EXTRA_MANIFESTS="${SCRIPT_DIR}/extra-manifests"
    if [[ -d "${EXTRA_MANIFESTS}" && -n "$(ls -A "${EXTRA_MANIFESTS}" 2>/dev/null)" ]]; then
        info "Applying manifests from ${EXTRA_MANIFESTS}"
        for manifest in "${EXTRA_MANIFESTS}"/*.yaml; do
            [[ -e "${manifest}" ]] || continue
            info "  Applying $(basename "${manifest}")"
            ok "$(oc apply -f "${manifest}")"
        done
        ok "Extra manifests applied"
    else
        warn "No extra-manifests directory or it is empty — skipping"
    fi
fi

if $DO_UNDEPLOY; then
    info "Removing catalog from cluster"
    (
        cd "${PTP_OP_DIR}"
        make catalog-undeploy
    )
    ok "Catalog removed"
fi

# ============================================================
# Summary
# ============================================================
echo ""
echo "============================================"
echo " Done"
echo "============================================"
if $DO_DEPLOY; then
    echo "  Catalog deployed: ${CATALOG_IMG}"
    echo ""
    echo "  Verify:"
    echo "    oc get catalogsource ptp-operator-catalog -n openshift-marketplace"
    echo "    oc get clustercatalog ptp-operator-catalog"
    echo "    oc get packagemanifest ptp-operator"
    echo "    oc get subscription ptp-operator -n openshift-ptp"
    echo "    oc get csv -n openshift-ptp"
    echo "    oc get pods -n openshift-ptp"
fi
echo "============================================"
