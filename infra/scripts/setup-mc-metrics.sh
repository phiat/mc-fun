#!/usr/bin/env bash
# Install UnifiedMetrics plugin + JMX Prometheus exporter on the MC container
# Run from your dev machine: ssh miniwini-1 -- bash < infra/scripts/setup-mc-metrics.sh
# Or:  ssh miniwini-1 "bash -s" < infra/scripts/setup-mc-metrics.sh
set -euo pipefail

CONTAINER="minecraft"
MC_DIR="/opt/minecraft/server"
JMX_PORT=9226
UNIFIED_METRICS_PORT=9225
JMX_EXPORTER_VERSION="1.0.1"

echo "==> Setting up metrics on ${CONTAINER}"

# ─── Install UnifiedMetrics plugin ──────────────────────────

echo "==> Installing UnifiedMetrics..."
incus exec "${CONTAINER}" -- bash -c "
  cd ${MC_DIR}/plugins

  # Get latest UnifiedMetrics release for Paper
  RELEASE_URL=\$(curl -fsSL https://api.github.com/repos/Cubxity/UnifiedMetrics/releases/latest \
    | python3 -c \"
import sys, json
data = json.load(sys.stdin)
for asset in data.get('assets', []):
    if 'paper' in asset['name'].lower() or 'bukkit' in asset['name'].lower():
        print(asset['browser_download_url'])
        break
\")

  if [ -z \"\$RELEASE_URL\" ]; then
    echo 'WARN: Could not find UnifiedMetrics release, trying direct download...'
    RELEASE_URL='https://github.com/Cubxity/UnifiedMetrics/releases/latest/download/unifiedmetrics-paper.jar'
  fi

  echo \"    Downloading: \$RELEASE_URL\"
  curl -fsSL -o unifiedmetrics.jar \"\$RELEASE_URL\"
  chown minecraft:minecraft unifiedmetrics.jar
  ls -lh unifiedmetrics.jar
"

# ─── Configure UnifiedMetrics for Prometheus ────────────────

echo "==> Configuring UnifiedMetrics..."
incus exec "${CONTAINER}" -- bash -c "
  mkdir -p ${MC_DIR}/plugins/UnifiedMetrics
  cat > ${MC_DIR}/plugins/UnifiedMetrics/config.yml <<'CONF'
# UnifiedMetrics config
metrics:
  enabled: true
  collectors:
    server: true
    world: true
    tick: true
    events: true

drivers:
  prometheus:
    enabled: true
    host: 0.0.0.0
    port: ${UNIFIED_METRICS_PORT}
CONF
  chown -R minecraft:minecraft ${MC_DIR}/plugins/UnifiedMetrics
"

# ─── Install JMX Prometheus exporter ───────────────────────

echo "==> Installing JMX Prometheus exporter ${JMX_EXPORTER_VERSION}..."
incus exec "${CONTAINER}" -- bash -c "
  curl -fsSL -o ${MC_DIR}/jmx_prometheus_javaagent.jar \
    'https://repo1.maven.org/maven2/io/prometheus/jmx/jmx_prometheus_javaagent/${JMX_EXPORTER_VERSION}/jmx_prometheus_javaagent-${JMX_EXPORTER_VERSION}.jar'
  chown minecraft:minecraft ${MC_DIR}/jmx_prometheus_javaagent.jar
  ls -lh ${MC_DIR}/jmx_prometheus_javaagent.jar
"

# ─── Push JMX exporter config ──────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JMX_CONFIG="${SCRIPT_DIR}/../configs/jmx-exporter.yaml"

if [ -f "$JMX_CONFIG" ]; then
  echo "==> Pushing JMX exporter config..."
  incus file push "$JMX_CONFIG" "${CONTAINER}${MC_DIR}/jmx-exporter.yaml"
  incus exec "${CONTAINER}" -- chown minecraft:minecraft "${MC_DIR}/jmx-exporter.yaml"
else
  echo "==> Creating inline JMX exporter config..."
  incus exec "${CONTAINER}" -- bash -c "
    cat > ${MC_DIR}/jmx-exporter.yaml <<'JMX'
lowercaseOutputName: true
lowercaseOutputLabelNames: true
rules:
  - pattern: '.*'
JMX
    chown minecraft:minecraft ${MC_DIR}/jmx-exporter.yaml
  "
fi

# ─── Update systemd service to include JMX agent ──────────

echo "==> Updating minecraft.service with JMX agent..."
incus exec "${CONTAINER}" -- bash -c "
  cat > /etc/systemd/system/minecraft.service <<'SVC'
[Unit]
Description=PaperMC Minecraft Server
After=network.target

[Service]
User=minecraft
WorkingDirectory=${MC_DIR}
ExecStart=/usr/bin/java \\
  -Xms4G -Xmx4G \\
  -javaagent:${MC_DIR}/jmx_prometheus_javaagent.jar=${JMX_PORT}:${MC_DIR}/jmx-exporter.yaml \\
  -jar paper.jar --nogui
ExecStop=/bin/kill -SIGINT \$MAINPID
Restart=on-failure
RestartSec=10
StandardInput=null

[Install]
WantedBy=multi-user.target
SVC

  systemctl daemon-reload
"

# ─── Restart to pick up changes ───────────────────────────

echo "==> Restarting Minecraft server..."
echo "    WARNING: This will kick all players momentarily."
incus exec "${CONTAINER}" -- systemctl restart minecraft

# ─── Wait for metrics endpoints ────────────────────────────

echo "==> Waiting for server + metrics to come up..."
for i in $(seq 1 90); do
  if incus exec "${CONTAINER}" -- bash -c "curl -sf http://localhost:${JMX_PORT}/metrics >/dev/null 2>&1"; then
    echo "==> JMX exporter responding on :${JMX_PORT} after ${i}s"
    break
  fi
  if [ $((i % 10)) -eq 0 ]; then
    echo "    Still waiting... (${i}s)"
  fi
  sleep 2
done

# UnifiedMetrics may take longer (needs full server start)
for i in $(seq 1 60); do
  if incus exec "${CONTAINER}" -- bash -c "curl -sf http://localhost:${UNIFIED_METRICS_PORT}/metrics >/dev/null 2>&1"; then
    echo "==> UnifiedMetrics responding on :${UNIFIED_METRICS_PORT}"
    break
  fi
  sleep 2
done

# ─── Verify ───────────────────────────────────────────────

MC_IP=$(incus list "${CONTAINER}" --format csv -c 4 | cut -d' ' -f1)

echo ""
echo "==> Metrics setup complete!"
echo "    Container:           ${CONTAINER} (${MC_IP})"
echo "    UnifiedMetrics:      http://${MC_IP}:${UNIFIED_METRICS_PORT}/metrics"
echo "    JMX Exporter:        http://${MC_IP}:${JMX_PORT}/metrics"
echo ""
echo "    Use these as Prometheus scrape targets."
