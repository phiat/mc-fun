#!/usr/bin/env bash
# Provision a Postgres container for mc-fun
# Usage: setup-pg.sh [project-name]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(dirname "$SCRIPT_DIR")"
PROJECT="${1:-mc-fun}"
CONTAINER_NAME="${PROJECT}-pg"
IMAGE="images:ubuntu/noble"
PG_VERSION="18"
DB_NAME="mc_fun"
DB_USER="mc_fun"
DB_PASS="mc_fun"

echo "==> Setting up Postgres container: ${CONTAINER_NAME}"

# ─── Check existing container ───────────────────────────────

if incus info "${CONTAINER_NAME}" &>/dev/null; then
  echo "    Container ${CONTAINER_NAME} already exists."
  state=$(incus info "${CONTAINER_NAME}" | grep "Status:" | awk '{print $2}')
  if [ "$state" != "RUNNING" ]; then
    echo "    Starting existing container..."
    incus start "${CONTAINER_NAME}"
  fi

  for i in $(seq 1 15); do
    if incus exec "${CONTAINER_NAME}" -- pg_isready -U "${DB_USER}" 2>/dev/null; then
      echo "==> Postgres is ready"
      PG_IP=$(incus list "${CONTAINER_NAME}" --format csv -c 4 | cut -d' ' -f1)
      echo "    postgres://${DB_USER}:${DB_PASS}@${PG_IP}:5432/${DB_NAME}"
      exit 0
    fi
    sleep 1
  done
  echo "WARN: Container running but Postgres not ready"
  exit 1
fi

# ─── Parse resource limits from spec ────────────────────────

MEMORY_LIMIT="1024"
CPU_LIMIT="2"

SPEC_FILE="${INFRA_DIR}/specs/postgres.yaml"
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

# ─── Install Postgres + TimescaleDB ────────────────────────

echo "==> Installing Postgres ${PG_VERSION} + TimescaleDB..."
incus exec "${CONTAINER_NAME}" -- bash -c "
  export DEBIAN_FRONTEND=noninteractive

  apt-get update -qq
  apt-get install -y -qq curl gnupg lsb-release >/dev/null 2>&1

  # PostgreSQL official repo
  curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor -o /usr/share/keyrings/pgdg.gpg
  echo 'deb [signed-by=/usr/share/keyrings/pgdg.gpg] http://apt.postgresql.org/pub/repos/apt noble-pgdg main' \
    > /etc/apt/sources.list.d/pgdg.list

  # TimescaleDB repo
  curl -fsSL https://packagecloud.io/timescale/timescaledb/gpgkey | gpg --dearmor -o /usr/share/keyrings/timescaledb.gpg
  echo 'deb [signed-by=/usr/share/keyrings/timescaledb.gpg] https://packagecloud.io/timescale/timescaledb/ubuntu/ noble main' \
    > /etc/apt/sources.list.d/timescaledb.list

  apt-get update -qq
  apt-get install -y -qq postgresql-${PG_VERSION} timescaledb-2-postgresql-${PG_VERSION} >/dev/null 2>&1

  # Configure
  timescaledb-tune --quiet --yes

  PG_CONF='/etc/postgresql/${PG_VERSION}/main/postgresql.conf'
  PG_HBA='/etc/postgresql/${PG_VERSION}/main/pg_hba.conf'

  sed -i \"s/#listen_addresses.*/listen_addresses = '*'/\" \"\$PG_CONF\"
  echo 'host all all 0.0.0.0/0 md5' >> \"\$PG_HBA\"

  systemctl restart postgresql
  systemctl enable postgresql

  # Create project database and user
  sudo -u postgres psql -c \"CREATE USER ${DB_USER} WITH PASSWORD '${DB_PASS}' CREATEDB;\"
  sudo -u postgres psql -c \"CREATE DATABASE ${DB_NAME} OWNER ${DB_USER};\"
  sudo -u postgres psql -d ${DB_NAME} -c \"CREATE EXTENSION IF NOT EXISTS timescaledb;\"
"

# ─── Wait for readiness ────────────────────────────────────

echo "==> Waiting for Postgres to be ready..."
for i in $(seq 1 15); do
  if incus exec "${CONTAINER_NAME}" -- pg_isready -U "${DB_USER}" 2>/dev/null; then
    break
  fi
  sleep 1
done

# ─── Output ─────────────────────────────────────────────────

PG_IP=$(incus list "${CONTAINER_NAME}" --format csv -c 4 | cut -d' ' -f1)

echo ""
echo "==> Postgres container ready!"
echo "    Container: ${CONTAINER_NAME}"
echo "    IP:        ${PG_IP}"
echo "    Port:      5432"
echo "    Database:  ${DB_NAME}"
echo "    User:      ${DB_USER}"
echo "    Password:  ${DB_PASS}"
echo ""
echo "    Connection string:"
echo "    postgres://${DB_USER}:${DB_PASS}@${PG_IP}:5432/${DB_NAME}"
