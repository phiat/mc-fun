#!/usr/bin/env bash
# Deploy kube-prometheus-stack to k3s on your MC server host
# Run from dev machine: bash infra/k8s/deploy-monitoring.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REMOTE="${MC_REMOTE_HOST:?Set MC_REMOTE_HOST to your server hostname}"
NAMESPACE="monitoring"

echo "==> Deploying monitoring stack to k3s on ${REMOTE}"

# ─── Get Minecraft container IP ────────────────────────────

MC_IP=$(ssh "${REMOTE}" "incus list minecraft --format csv -c 4 2>/dev/null | cut -d' ' -f1")
if [ -z "$MC_IP" ]; then
  echo "ERROR: Could not get Minecraft container IP from ${REMOTE}"
  exit 1
fi
echo "    Minecraft container IP: ${MC_IP}"

# ─── Prepare values file with real IP ─────────────────────

TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

sed "s/MC_CONTAINER_IP/${MC_IP}/g" "${SCRIPT_DIR}/monitoring-values.yaml" > "${TMPDIR}/values.yaml"
echo "    Values file prepared with MC IP substituted"

# ─── Copy files to remote ─────────────────────────────────

echo "==> Copying Helm values to ${REMOTE}..."
scp "${TMPDIR}/values.yaml" "${REMOTE}:/tmp/monitoring-values.yaml"

# ─── Copy Grafana dashboard ───────────────────────────────

if [ -f "${SCRIPT_DIR}/minecraft-dashboard.json" ]; then
  scp "${SCRIPT_DIR}/minecraft-dashboard.json" "${REMOTE}:/tmp/minecraft-dashboard.json"
fi

# ─── Install on remote via SSH ─────────────────────────────

echo "==> Installing kube-prometheus-stack via Helm..."
ssh -t "${REMOTE}" "
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

  # Add Helm repo
  sudo helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
  sudo helm repo update

  # Create namespace
  sudo k3s kubectl create namespace ${NAMESPACE} 2>/dev/null || true

  # Create Grafana dashboard ConfigMap if dashboard exists
  if [ -f /tmp/minecraft-dashboard.json ]; then
    sudo k3s kubectl create configmap grafana-minecraft-dashboard \
      --from-file=minecraft.json=/tmp/minecraft-dashboard.json \
      -n ${NAMESPACE} --dry-run=client -o yaml | sudo k3s kubectl apply -f -
  fi

  # Install or upgrade
  sudo helm upgrade --install monitoring \
    prometheus-community/kube-prometheus-stack \
    -f /tmp/monitoring-values.yaml \
    -n ${NAMESPACE} \
    --wait --timeout 5m

  echo ''
  echo '==> Monitoring stack deployed!'
  sudo k3s kubectl get pods -n ${NAMESPACE}
"

# ─── Output ────────────────────────────────────────────────

echo ""
echo "==> Deployment complete!"
echo ""
echo "    Grafana:     http://${REMOTE}:30080"
echo "    Login:       admin / mc-fun-grafana"
echo ""
echo "    Prometheus:  (cluster-internal, port-forward if needed)"
echo "    ssh ${REMOTE} -- sudo k3s kubectl port-forward -n ${NAMESPACE} svc/monitoring-kube-prometheus-prometheus 9090:9090"
echo ""
echo "    Scrape targets:"
echo "    - UnifiedMetrics:  ${MC_IP}:9225/metrics"
echo "    - JMX Exporter:    ${MC_IP}:9226/metrics"
