#!/usr/bin/env bash
# Provision a Paper Minecraft server container for mc-fun
# Usage: setup-minecraft.sh [project-name]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(dirname "$SCRIPT_DIR")"
PROJECT="${1:-mc-fun}"
CONTAINER_NAME="${PROJECT}-mc"
IMAGE="images:ubuntu/noble"
MC_DIR="/opt/minecraft"
MC_VERSION="1.21.4"
RCON_PASSWORD="${RCON_PASSWORD:-mc-fun-rcon}"

echo "==> Setting up Minecraft container: ${CONTAINER_NAME}"

# ─── Check existing container ───────────────────────────────

if incus info "${CONTAINER_NAME}" &>/dev/null; then
  echo "    Container ${CONTAINER_NAME} already exists."
  state=$(incus info "${CONTAINER_NAME}" | grep "Status:" | awk '{print $2}')
  if [ "$state" != "RUNNING" ]; then
    echo "    Starting existing container..."
    incus start "${CONTAINER_NAME}"
  fi

  echo "==> Waiting for Minecraft server to be ready..."
  for i in $(seq 1 60); do
    if incus exec "${CONTAINER_NAME}" -- bash -c "echo | nc -w2 localhost 25575" &>/dev/null; then
      echo "==> Minecraft server is ready (RCON responding)"
      MC_IP=$(incus list "${CONTAINER_NAME}" --format csv -c 4 | cut -d' ' -f1)
      echo "    IP: ${MC_IP}  Game: 25565  RCON: 25575"
      exit 0
    fi
    sleep 2
  done
  echo "WARN: Container running but Minecraft not ready after 120s"
  exit 1
fi

# ─── Parse resource limits from spec ────────────────────────

MEMORY_LIMIT="4096"
CPU_LIMIT="4"

SPEC_FILE="${INFRA_DIR}/specs/minecraft.yaml"
if [ -f "$SPEC_FILE" ]; then
  SPEC_MEMORY=$(grep -E '^\s+memory:' "$SPEC_FILE" | awk '{print $2}' | tr -d '[:space:]')
  if [ -n "$SPEC_MEMORY" ]; then
    MEMORY_LIMIT="$SPEC_MEMORY"
  fi

  SPEC_CPU=$(grep -E '^\s+cpu:' "$SPEC_FILE" | awk '{print $2}' | tr -d '[:space:]')
  if [ -n "$SPEC_CPU" ]; then
    CPU_LIMIT="$SPEC_CPU"
  fi
fi

# ─── Launch container with inline limits ─────────────────────

echo "==> Launching container from ${IMAGE}..."
echo "    Memory: ${MEMORY_LIMIT}MB, CPU: ${CPU_LIMIT} cores"
incus launch "${IMAGE}" "${CONTAINER_NAME}" \
  -c limits.memory="${MEMORY_LIMIT}MB" \
  -c limits.cpu="${CPU_LIMIT}"

echo "==> Waiting for container networking..."
for i in $(seq 1 30); do
  if incus exec "${CONTAINER_NAME}" -- ip -4 addr show eth0 2>/dev/null | grep -q "inet "; then
    break
  fi
  sleep 1
done

# ─── Install Java 21 (Adoptium Temurin) ────────────────────

echo "==> Installing Java 21 (Temurin)..."
incus exec "${CONTAINER_NAME}" -- bash -c "
  export DEBIAN_FRONTEND=noninteractive

  apt-get update -qq
  apt-get install -y -qq curl gnupg netcat-openbsd >/dev/null 2>&1

  # Adoptium repo
  curl -fsSL https://packages.adoptium.net/artifactory/api/gpg/key/public | gpg --dearmor -o /usr/share/keyrings/adoptium.gpg
  echo 'deb [signed-by=/usr/share/keyrings/adoptium.gpg] https://packages.adoptium.net/artifactory/deb noble main' \
    > /etc/apt/sources.list.d/adoptium.list

  apt-get update -qq
  apt-get install -y -qq temurin-21-jdk >/dev/null 2>&1

  java -version
"

# ─── Download Paper MC ─────────────────────────────────────

echo "==> Downloading Paper ${MC_VERSION}..."
incus exec "${CONTAINER_NAME}" -- bash -c "
  mkdir -p ${MC_DIR}

  # Get latest build number from Paper API
  BUILDS_JSON=\$(curl -fsSL 'https://api.papermc.io/v2/projects/paper/versions/${MC_VERSION}/builds')
  BUILD=\$(echo \"\$BUILDS_JSON\" | python3 -c \"
import sys, json
data = json.load(sys.stdin)
builds = data.get('builds', [])
if not builds:
    sys.exit(1)
latest = builds[-1]
print(latest['build'])
\")
  DOWNLOAD=\$(echo \"\$BUILDS_JSON\" | python3 -c \"
import sys, json
data = json.load(sys.stdin)
builds = data.get('builds', [])
latest = builds[-1]
print(latest['downloads']['application']['name'])
\")

  echo \"    Build: \$BUILD  File: \$DOWNLOAD\"
  curl -fsSL -o ${MC_DIR}/paper.jar \
    \"https://api.papermc.io/v2/projects/paper/versions/${MC_VERSION}/builds/\${BUILD}/downloads/\${DOWNLOAD}\"

  ls -lh ${MC_DIR}/paper.jar
"

# ─── Configure server ──────────────────────────────────────

echo "==> Configuring server..."
incus exec "${CONTAINER_NAME}" -- bash -c "
  cd ${MC_DIR}

  # Accept EULA
  echo 'eula=true' > eula.txt

  # server.properties
  cat > server.properties <<'PROPS'
server-port=25565
enable-rcon=true
rcon.port=25575
rcon.password=${RCON_PASSWORD}
enforce-whitelist=true
white-list=true
motd=mc-fun server
max-players=10
difficulty=normal
view-distance=12
simulation-distance=8
spawn-protection=0
enable-command-block=true
snooper-enabled=false
online-mode=true
PROPS

  # ops.json
  cat > ops.json <<'OPS'
[
  {
    \"uuid\": \"00000000-0000-0000-0000-000000000000\",
    \"name\": \"DonaldMahanahan\",
    \"level\": 4,
    \"bypassesPlayerLimit\": true
  }
]
OPS

  # whitelist.json
  cat > whitelist.json <<'WL'
[
  {\"uuid\": \"00000000-0000-0000-0000-000000000000\", \"name\": \"DonaldMahanahan\"},
  {\"uuid\": \"00000000-0000-0000-0000-000000000001\", \"name\": \"kurgenjlopp\"},
  {\"uuid\": \"00000000-0000-0000-0000-000000000002\", \"name\": \"McFunBot\"}
]
WL

  # Create minecraft system user
  useradd -r -m -d ${MC_DIR} -s /bin/bash minecraft 2>/dev/null || true
  chown -R minecraft:minecraft ${MC_DIR}
"

# ─── Create systemd service ───────────────────────────────

echo "==> Creating systemd service..."
incus exec "${CONTAINER_NAME}" -- bash -c "
  cat > /etc/systemd/system/minecraft.service <<'SVC'
[Unit]
Description=Minecraft Paper Server
After=network.target

[Service]
User=minecraft
WorkingDirectory=${MC_DIR}
ExecStart=/usr/bin/java -Xms2G -Xmx3G -jar ${MC_DIR}/paper.jar --nogui
ExecStop=/bin/bash -c 'echo \"stop\" | /usr/bin/nc -w5 localhost 25575 || true'
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SVC

  systemctl daemon-reload
  systemctl enable minecraft
  systemctl start minecraft
"

# ─── Wait for readiness ────────────────────────────────────

echo "==> Waiting for Minecraft server to start (this takes 30-90s)..."
for i in $(seq 1 90); do
  if incus exec "${CONTAINER_NAME}" -- bash -c "echo | nc -w2 localhost 25575" &>/dev/null; then
    echo "==> RCON port responding after ${i}s"
    break
  fi
  if [ $((i % 10)) -eq 0 ]; then
    echo "    Still waiting... (${i}s)"
  fi
  sleep 2
done

# Also check game port
for i in $(seq 1 30); do
  if incus exec "${CONTAINER_NAME}" -- bash -c "echo | nc -w2 localhost 25565" &>/dev/null; then
    echo "==> Game port responding"
    break
  fi
  sleep 2
done

# ─── Output ─────────────────────────────────────────────────

MC_IP=$(incus list "${CONTAINER_NAME}" --format csv -c 4 | cut -d' ' -f1)

echo ""
echo "==> Minecraft container ready!"
echo "    Container:     ${CONTAINER_NAME}"
echo "    IP:            ${MC_IP}"
echo "    Game port:     25565"
echo "    RCON port:     25575"
echo "    RCON password: ${RCON_PASSWORD}"
echo "    Server dir:    ${MC_DIR}"
echo ""
echo "    Connect from Minecraft client: ${MC_IP}:25565"
