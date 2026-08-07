#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

# Read specific values from .env without executing it as shell. `source` would
# treat values containing $(...), backticks, or globs as code — risky for
# user-supplied fields like SMTP_PWD. Docker Compose reads .env on its own.
read_env() {
  [ -f "$ENV_FILE" ] || return 0
  awk -F= -v key="$1" '
    /^[[:space:]]*#/ { next }
    $1 == key { sub(/^[^=]+=/, ""); val = $0 }
    END { print val }
  ' "$ENV_FILE"
}

PROXY_MODE="$(read_env PROXY_MODE)"
S3_ENDPOINT="$(read_env S3_ENDPOINT)"
DATABASE_URL="$(read_env DATABASE_URL)"
DOMAIN="$(read_env DOMAIN)"
NEXT_PUBLIC_BASE_URL="$(read_env NEXT_PUBLIC_BASE_URL)"
POSTGRES_VERSION="$(read_env POSTGRES_VERSION)"
POSTGRES_VOLUME="$(read_env POSTGRES_VOLUME)"

# Compose file selection: base, plus the external-proxy override when the
# user is bringing their own reverse proxy (PROXY_MODE=external).
_compose_files=("$SCRIPT_DIR/docker-compose.yml")
if [ "${PROXY_MODE:-bundled}" = "external" ]; then
  _compose_files+=("$SCRIPT_DIR/docker-compose.external-proxy.yml")
fi
COMPOSE_FILE="$(IFS=:; echo "${_compose_files[*]}")"
export COMPOSE_FILE
unset _compose_files

# Enable bundled services unless the user has pointed Rallly at external
# providers in .env. Setting S3_ENDPOINT to a non-Garage endpoint disables
# the bundled Garage container; setting DATABASE_URL disables the bundled
# Postgres container; PROXY_MODE=external disables the bundled Traefik.
_profiles=()
if [ -z "${S3_ENDPOINT:-}" ] || [ "${S3_ENDPOINT}" = "http://garage:3900" ]; then
  _profiles+=("bundled-storage")
fi
if [ -z "${DATABASE_URL:-}" ]; then
  _profiles+=("bundled-db")
fi
if [ "${PROXY_MODE:-bundled}" != "external" ]; then
  _profiles+=("bundled-proxy")
fi
COMPOSE_PROFILES="$(IFS=,; echo "${_profiles[*]-}")"
export COMPOSE_PROFILES
unset _profiles

# ── Helpers ─────────────────────────────────────────────────────

info()  { echo "  → $*"; }
error() { echo "  ✗ $*" >&2; }
ok()    { echo "  ✓ $*"; }

prompt() {
  local var_name="$1" prompt_text="$2" default="${3:-}"
  local input
  if [ -n "$default" ]; then
    printf "  %s [%s]: " "$prompt_text" "$default"
  else
    printf "  %s: " "$prompt_text"
  fi
  read -r input
  eval "$var_name=\"${input:-$default}\""
}

prompt_secret() {
  local var_name="$1" prompt_text="$2"
  local input="" char
  printf "  %s: " "$prompt_text"
  while IFS= read -rsn1 char; do
    if [[ -z "$char" ]]; then
      break
    elif [[ "$char" == $'\x7f' || "$char" == $'\b' ]]; then
      if [[ -n "$input" ]]; then
        input="${input%?}"
        printf '\b \b'
      fi
    else
      input+="$char"
      printf '*'
    fi
  done
  echo ""
  eval "$var_name=\"$input\""
}

generate_secret() {
  openssl rand -hex "$1" 2>/dev/null
}

check_docker() {
  if ! command -v docker &>/dev/null; then
    error "Docker is not installed."
    exit 1
  fi
  if ! docker compose version &>/dev/null; then
    error "Docker Compose v2 is not available."
    exit 1
  fi
}

# Set or update a KEY=value line in .env, preserving everything else.
upsert_env() {
  local key="$1" value="$2"
  [ -f "$ENV_FILE" ] || return 0
  if grep -q "^${key}=" "$ENV_FILE"; then
    local tmp
    tmp="$(mktemp)"
    awk -v key="$key" -v val="$value" -F= '
      $1 == key && !/^[[:space:]]*#/ { print key "=" val; next }
      { print }
    ' "$ENV_FILE" > "$tmp"
    mv "$tmp" "$ENV_FILE"
    chmod 600 "$ENV_FILE"
  else
    printf '%s=%s\n' "$key" "$value" >> "$ENV_FILE"
  fi
}

# Default major version for the bundled Postgres on fresh installs, and the
# target major for './rallly.sh upgrade-db'. Existing data volumes are never
# moved to this automatically — they stay pinned to the major that
# initialised them until explicitly upgraded.
PG_DEFAULT_MAJOR=18

# Majors below this are at or approaching end of life — warn on start/update.
PG_EOL_MIN_MAJOR=15

# The compose-managed volume name for the bundled db: <project>_<key>.
# The key is the compose volume the db service mounts — db-data unless an
# upgrade has switched the install to a newer volume via POSTGRES_VOLUME.
db_volume_name() {
  local key="${1:-${POSTGRES_VOLUME:-db-data}}"
  local project="${COMPOSE_PROJECT_NAME:-$(read_env COMPOSE_PROJECT_NAME)}"
  if [ -z "$project" ]; then
    # Replicate Docker Compose's default project name: directory basename,
    # lowercased, invalid characters stripped.
    project="$(basename "$SCRIPT_DIR" | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9_-]//g' -e 's/^[_-]*//')"
  fi
  echo "${project}_${key}"
}

# Read the PostgreSQL major version out of an existing data volume.
# Pre-18 layout has PG_VERSION at the volume root; 18+ images keep it
# at <major>/docker/PG_VERSION.
detect_volume_pg_version() {
  local volume="$1"
  docker run --rm -v "${volume}:/pgdata:ro" alpine:3 sh -c \
    'cat /pgdata/PG_VERSION 2>/dev/null || cat /pgdata/*/docker/PG_VERSION 2>/dev/null' \
    | sort -n | tail -n1 | tr -d '[:space:]'
}

# Pin the bundled Postgres major version. Existing data volumes keep the
# version they were initialized with (read from PG_VERSION — a manually
# upgraded install stays on its own major); fresh installs get 18. The pin
# is persisted as POSTGRES_VERSION in .env so it is stable across runs and
# never floats.
ensure_postgres_pin() {
  if [ -n "${DATABASE_URL:-}" ]; then
    # External database — the bundled db service never starts, but compose
    # still interpolates its config. Export parse-only values; don't touch
    # the user's .env.
    POSTGRES_VERSION="${POSTGRES_VERSION:-$PG_DEFAULT_MAJOR}"
  elif [ -z "${POSTGRES_VERSION:-}" ]; then
    local volume contents
    volume="$(db_volume_name)"
    # Distinguish "volume doesn't exist" from "can't reach the daemon" —
    # otherwise a stopped daemon would look like a fresh install and pin
    # the new default major over an existing volume's data.
    if ! docker volume ls -q &>/dev/null; then
      error "Cannot query Docker volumes — is the Docker daemon running?"
      exit 1
    fi
    if docker volume inspect "$volume" &>/dev/null; then
      # `|| true`: under `set -eo pipefail` a volume without a readable
      # PG_VERSION would abort the script before the fallbacks below run.
      POSTGRES_VERSION="$(detect_volume_pg_version "$volume" || true)"
      if [ -n "$POSTGRES_VERSION" ]; then
        info "Existing database volume detected — pinning PostgreSQL $POSTGRES_VERSION."
      elif contents="$(docker run --rm -v "${volume}:/pgdata:ro" alpine:3 ls -A /pgdata 2>/dev/null)" && [ -z "$contents" ]; then
        # Volume exists but Postgres never initialised it — safe to treat
        # as a fresh install.
        POSTGRES_VERSION="$PG_DEFAULT_MAJOR"
        info "Empty database volume — provisioning PostgreSQL $POSTGRES_VERSION."
      else
        error "Found an existing database volume ($volume) but could not read its PostgreSQL version."
        error "Set POSTGRES_VERSION in $ENV_FILE manually (e.g. POSTGRES_VERSION=14) and try again."
        exit 1
      fi
    else
      POSTGRES_VERSION="$PG_DEFAULT_MAJOR"
      info "No existing database volume — provisioning PostgreSQL $POSTGRES_VERSION."
    fi
    upsert_env POSTGRES_VERSION "$POSTGRES_VERSION"
  fi

  case "$POSTGRES_VERSION" in
    ''|*[!0-9]*)
      error "Invalid POSTGRES_VERSION '$POSTGRES_VERSION' in $ENV_FILE — expected a major version number (e.g. 14)."
      exit 1
      ;;
  esac

  if [ "$POSTGRES_VERSION" -ge 18 ]; then
    POSTGRES_DATA_MOUNT=/var/lib/postgresql
  else
    POSTGRES_DATA_MOUNT=/var/lib/postgresql/data
  fi
  if [ -z "${DATABASE_URL:-}" ]; then
    upsert_env POSTGRES_DATA_MOUNT "$POSTGRES_DATA_MOUNT"
  fi
  export POSTGRES_VERSION POSTGRES_DATA_MOUNT
}

# The in-container path docker-compose.yml mounts CA_CERT_FILE at.
CA_CERT_MOUNT=/etc/ssl/certs/rallly-custom-ca.pem

# Point Node at the mounted CA bundle when CA_CERT_FILE is set. Compose can't
# express "set this only when another variable is set" in a single value, so
# NODE_EXTRA_CA_CERTS is written to .env here instead of being derived in
# docker-compose.yml — that would clobber a value the user set themselves
# (e.g. an install predating CA_CERT_FILE that bakes its own cert into a
# custom RALLLY_IMAGE) with an empty string.
ensure_ca_cert_env() {
  local ca_cert_file node_extra
  ca_cert_file="$(read_env CA_CERT_FILE)"
  node_extra="$(read_env NODE_EXTRA_CA_CERTS)"

  if [ -z "${ca_cert_file:-}" ]; then
    # Only clear the value we manage — anything else is the user's own.
    if [ "${node_extra:-}" = "$CA_CERT_MOUNT" ]; then
      upsert_env NODE_EXTRA_CA_CERTS ""
    fi
    return 0
  fi

  if [ ! -f "$ca_cert_file" ]; then
    error "CA_CERT_FILE points at '$ca_cert_file', which is not a file."
    error "Set it to the path of a PEM certificate on this host, or remove it from $ENV_FILE."
    exit 1
  fi

  if [ -n "${node_extra:-}" ] && [ "$node_extra" != "$CA_CERT_MOUNT" ]; then
    error "Both CA_CERT_FILE and NODE_EXTRA_CA_CERTS are set in $ENV_FILE, and NODE_EXTRA_CA_CERTS points somewhere else ('$node_extra')."
    error "Remove one of them — CA_CERT_FILE mounts a host certificate; NODE_EXTRA_CA_CERTS expects a path that already exists inside the container."
    exit 1
  fi

  upsert_env NODE_EXTRA_CA_CERTS "$CA_CERT_MOUNT"
}

# Warn (never block, never auto-upgrade) when the pinned bundled Postgres
# major is at or approaching end of life. Skipped on external databases —
# they are not ours to upgrade.
warn_postgres_eol() {
  if [ -n "${DATABASE_URL:-}" ]; then
    return 0
  fi
  case "${POSTGRES_VERSION:-}" in ''|*[!0-9]*) return 0 ;; esac
  if [ "$POSTGRES_VERSION" -ge "$PG_EOL_MIN_MAJOR" ]; then
    return 0
  fi
  echo ""
  if [ "$POSTGRES_VERSION" -eq 14 ]; then
    echo "  ⚠ PostgreSQL 14 reaches end of life on November 12, 2026 — run './rallly.sh upgrade-db' to upgrade to PostgreSQL $PG_DEFAULT_MAJOR."
  else
    echo "  ⚠ PostgreSQL $POSTGRES_VERSION has reached end of life — run './rallly.sh upgrade-db' to upgrade to PostgreSQL $PG_DEFAULT_MAJOR."
  fi
}

# ── Commands ────────────────────────────────────────────────────

cmd_setup() {
  if [ -f "$ENV_FILE" ]; then
    info "Existing .env found."
    read -rp "  Overwrite with new configuration? [y/N]: " overwrite
    if [[ ! "${overwrite:-N}" =~ ^[Yy]$ ]]; then
      ok "Keeping existing configuration."
      return 0
    fi
  fi

  if ! command -v openssl &>/dev/null; then
    error "openssl is required to generate secrets. Please install it and try again."
    exit 1
  fi

  echo ""
  echo "  ── Configuration ──"
  echo ""

  echo "  ── Reverse Proxy ──"
  echo ""
  echo "  1) bundled  — Traefik on this host handles HTTPS (ports 80/443 required)"
  echo "  2) external — You already have a reverse proxy; publish web on a host port"
  echo "  3) local    — No proxy, plain http on localhost (for trying Rallly out)"
  echo ""
  prompt PROXY_CHOICE "Choose [1/2/3]" "1"

  # Local mode is external mode with the base URL forced to plain http on
  # loopback — there is no proxy in front to terminate TLS.
  BASE_URL=""
  case "$PROXY_CHOICE" in
    3)
      PROXY_MODE=external
      # Re-prompt until the port is usable. An out-of-range value is only
      # rejected later by `docker compose up`, long after setup has reported
      # success — catch it while the user is still here to fix it.
      while true; do
        prompt LOCAL_PORT "Port to serve on" "3000"
        case "$LOCAL_PORT" in
          ''|*[!0-9]*) error "Port must be a number between 1 and 65535." ;;
          *) if [ "$LOCAL_PORT" -ge 1 ] && [ "$LOCAL_PORT" -le 65535 ]; then
               break
             fi
             error "Port must be a number between 1 and 65535." ;;
        esac
      done
      WEB_PORT="127.0.0.1:$LOCAL_PORT"
      DOMAIN="localhost:$LOCAL_PORT"
      BASE_URL="http://$DOMAIN"
      ;;
    2)
      PROXY_MODE=external
      prompt DOMAIN "Domain name (e.g. rallly.example.com)"
      prompt WEB_PORT "Host port binding for web" "127.0.0.1:3000"
      ;;
    *)
      PROXY_MODE=bundled
      prompt DOMAIN "Domain name (e.g. rallly.example.com)"
      ;;
  esac

  echo ""
  prompt INITIAL_ADMIN_EMAIL "Admin email (used to log in to the control panel)"
  prompt SUPPORT_EMAIL "Support email shown to users" "$INITIAL_ADMIN_EMAIL"
  if [ "$PROXY_MODE" = "bundled" ]; then
    prompt ACME_EMAIL "Email for SSL certificates" "$INITIAL_ADMIN_EMAIL"
  fi

  echo ""
  echo "  ── Email (SMTP) ──"
  echo ""
  prompt SMTP_HOST "SMTP host"
  prompt SMTP_PORT "SMTP port" "587"
  prompt SMTP_USER "SMTP username"
  prompt_secret SMTP_PWD "SMTP password"

  # Implicit TLS on 465; STARTTLS/plain on everything else (587, 25, 2525, ...)
  if [ "$SMTP_PORT" = "465" ]; then
    SMTP_SECURE=true
  else
    SMTP_SECURE=false
  fi

  echo ""
  info "Generating secrets..."

  local secret_password postgres_password s3_access_key s3_secret_key garage_rpc_secret
  secret_password="$(generate_secret 32)"
  postgres_password="$(generate_secret 24)"
  s3_access_key="$(generate_secret 16)"
  s3_secret_key="$(generate_secret 32)"
  garage_rpc_secret="$(generate_secret 32)"

  {
    cat <<ENVEOF
# Rallly Self-Hosted Configuration
# Generated by rallly.sh setup on $(date -u +"%Y-%m-%dT%H:%M:%SZ")

# ── Domain ──
DOMAIN=$DOMAIN

# ── Reverse Proxy ──
PROXY_MODE=$PROXY_MODE
ENVEOF

    if [ "$PROXY_MODE" = "bundled" ]; then
      cat <<ENVEOF
ACME_EMAIL=$ACME_EMAIL
ENVEOF
    else
      cat <<ENVEOF
WEB_PORT=$WEB_PORT
ENVEOF
    fi

    # Only written for local mode; otherwise compose derives it from DOMAIN.
    if [ -n "$BASE_URL" ]; then
      cat <<ENVEOF
NEXT_PUBLIC_BASE_URL=$BASE_URL
ENVEOF
    fi

    cat <<ENVEOF

# ── App Settings ──
SECRET_PASSWORD=$secret_password
SUPPORT_EMAIL=$SUPPORT_EMAIL
INITIAL_ADMIN_EMAIL=$INITIAL_ADMIN_EMAIL

# ── SMTP ──
SMTP_HOST=$SMTP_HOST
SMTP_PORT=$SMTP_PORT
SMTP_SECURE=$SMTP_SECURE
SMTP_USER=$SMTP_USER
SMTP_PWD=$SMTP_PWD

# ── Auto-configured ──
POSTGRES_PASSWORD=$postgres_password
S3_ACCESS_KEY_ID=$s3_access_key
S3_SECRET_ACCESS_KEY=$s3_secret_key
GARAGE_RPC_SECRET=$garage_rpc_secret
ENVEOF
  } > "$ENV_FILE"

  chmod 600 "$ENV_FILE"
  ok "Configuration saved to $ENV_FILE"
}

cmd_start() {
  check_docker
  if [ ! -f "$ENV_FILE" ]; then
    error "No .env file found. Run './rallly.sh setup' first."
    exit 1
  fi
  ensure_postgres_pin
  ensure_ca_cert_env
  docker compose up -d
  echo ""
  echo "Rallly is starting at ${NEXT_PUBLIC_BASE_URL:-https://${DOMAIN:-localhost}}"
  echo "Run './rallly.sh logs' to watch startup progress."
  warn_postgres_eol
}

cmd_stop() {
  check_docker
  docker compose down
  echo "Rallly has been stopped."
}

cmd_restart() {
  check_docker
  ensure_postgres_pin
  ensure_ca_cert_env
  # `docker compose restart` restarts containers as-is — it does not re-read
  # .env or apply config changes. `up -d` recreates only what changed, so a
  # restart picks up edits to .env the way users expect it to.
  docker compose up -d
  echo "Rallly has been restarted."
}

cmd_update() {
  check_docker
  # Update repo files if this is a git clone
  if [ -d "$SCRIPT_DIR/.git" ]; then
    echo "Updating configuration files..."
    git -C "$SCRIPT_DIR" pull --ff-only || {
      error "Could not update repo files. You may need to run: git -C $SCRIPT_DIR pull manually."
    }
    echo ""
  fi
  ensure_postgres_pin
  ensure_ca_cert_env
  echo "Pulling latest images..."
  docker compose pull
  echo ""
  echo "Recreating containers..."
  docker compose up -d --remove-orphans
  echo ""
  echo "Update complete."
  docker compose ps
  warn_postgres_eol
}

cmd_logs() {
  check_docker
  local service="${1:-}"
  if [ -n "$service" ]; then
    docker compose logs -f --tail=100 "$service"
  else
    docker compose logs -f --tail=100
  fi
}

cmd_status() {
  check_docker
  docker compose ps
}

cmd_backup() {
  check_docker
  local backup_dir="$SCRIPT_DIR/backups"
  local timestamp
  timestamp="$(date +%Y%m%d_%H%M%S)"
  local backup_file="$backup_dir/rallly_${timestamp}.sql.gz"

  mkdir -p "$backup_dir"
  chmod 700 "$backup_dir"

  ensure_postgres_pin

  # Dumps contain the full database — keep them private like .env.
  echo "Backing up database..."
  if [ -z "${DATABASE_URL:-}" ]; then
    docker compose exec -T db \
      pg_dump -U postgres rallly | (umask 077; gzip > "$backup_file")
  else
    # External Postgres — run pg_dump in a throwaway container. pg_dump
    # can dump any server up to its own major version; for newer servers
    # run pg_dump manually with a matching client.
    docker run --rm -i "postgres:${POSTGRES_VERSION}-alpine" \
      pg_dump "$DATABASE_URL" | (umask 077; gzip > "$backup_file")
  fi

  echo "Backup saved to: $backup_file"
}

# Wait for the bundled db to accept TCP connections. The compose healthcheck
# uses the unix socket, which the image's init-phase temporary server also
# answers — TCP only comes up once the real server is running.
wait_for_db() {
  local tries=45
  while [ "$tries" -gt 0 ]; do
    if docker compose exec -T db pg_isready -q -h 127.0.0.1 -U postgres 2>/dev/null; then
      return 0
    fi
    tries=$((tries - 1))
    sleep 2
  done
  return 1
}

# Per-table row counts ("table:count" lines) used to verify the restore —
# count(*) over every table in the public schema, so the check covers the
# whole application schema, not just a known table. Appends a sentinel on
# query failure so a broken connection can't masquerade as a match.
db_table_counts() {
  docker compose exec -T db psql -tA -v ON_ERROR_STOP=1 -U postgres -d rallly 2>/dev/null <<'SQL' || echo "query-failed"
SELECT format('SELECT %L || count(*) FROM %I.%I', tablename || ':', schemaname, tablename)
FROM pg_tables WHERE schemaname = 'public' ORDER BY tablename
\gexec
SQL
}

# Abort the upgrade before anything is switched over. The original volume
# and .env are only modified after the restore is verified, so every failure
# path lands here with the old install fully intact.
fail_upgrade() {
  error "$1"
  docker compose down &>/dev/null || true
  echo ""
  error "The upgrade did not complete — nothing was switched over."
  info "Your PostgreSQL $old_major data (volume: $old_volume) and .env are untouched."
  if [ -n "${dump_file:-}" ] && [ -f "$dump_file" ]; then
    info "The dump from this attempt was kept at: $dump_file"
  fi
  info "Run './rallly.sh start' to start Rallly on PostgreSQL $old_major as before."
  exit 1
}

cmd_upgrade_db() {
  check_docker
  if [ ! -f "$ENV_FILE" ]; then
    error "No .env file found. Run './rallly.sh setup' first."
    exit 1
  fi
  if [ -n "${DATABASE_URL:-}" ]; then
    error "DATABASE_URL is set — you are using an external database, which this script does not manage."
    error "Upgrade it with your database provider's tools instead."
    exit 1
  fi

  ensure_postgres_pin
  local old_major="$POSTGRES_VERSION"
  local old_mount="$POSTGRES_DATA_MOUNT"
  local old_volume_key="${POSTGRES_VOLUME:-db-data}"
  local target_major="$PG_DEFAULT_MAJOR"
  if [ "$old_major" -ge "$target_major" ]; then
    ok "The bundled PostgreSQL is already on major $old_major — nothing to upgrade."
    return 0
  fi

  local old_volume new_volume_key new_volume
  old_volume="$(db_volume_name)"
  new_volume_key="db-data-pg${target_major}"
  new_volume="$(db_volume_name "$new_volume_key")"
  if [ "$old_volume" = "$new_volume" ]; then
    error "POSTGRES_VOLUME in $ENV_FILE already points at $new_volume but POSTGRES_VERSION is $old_major."
    error "This looks like a half-finished manual change — fix .env before upgrading."
    exit 1
  fi
  if ! docker volume inspect "$old_volume" &>/dev/null; then
    error "No database volume found ($old_volume) — there is nothing to upgrade."
    error "If this is a fresh install, remove POSTGRES_VERSION and POSTGRES_DATA_MOUNT from $ENV_FILE and run './rallly.sh start' to provision PostgreSQL $target_major directly."
    exit 1
  fi

  # The target volume can already exist: from an upgrade attempt that failed
  # (partial restore), or from a completed upgrade the user rolled back from.
  # The pin in .env still points at the old major, so it is not in use — but
  # in the rollback case it may hold rows written after the earlier upgrade.
  # Deleting it is part of what the user confirms below.
  local leftover_volume=""
  if docker volume inspect "$new_volume" &>/dev/null; then
    leftover_volume="$new_volume"
  fi

  echo ""
  echo "  This will upgrade the bundled PostgreSQL from $old_major to $target_major:"
  echo ""
  echo "    1. Stop Rallly (it stays offline until the upgrade finishes)"
  echo "    2. Dump the database into ./backups/ (kept as a rollback artifact)"
  echo "    3. Restore it into a fresh PostgreSQL $target_major volume ($new_volume)"
  echo "    4. Point .env at the new volume and restart Rallly"
  echo ""
  echo "  The current PostgreSQL $old_major volume ($old_volume) is left untouched"
  echo "  so you can roll back."
  if [ -n "$leftover_volume" ]; then
    echo ""
    echo "  ⚠ The volume $leftover_volume already exists — likely from an earlier"
    echo "    upgrade attempt or a rollback. It will be DELETED and recreated from"
    echo "    the current database. If it might still hold data you need (e.g. rows"
    echo "    written after a previous upgrade), answer no and inspect it first."
  fi
  echo ""
  local confirm
  read -rp "  Proceed? [y/N]: " confirm
  if [[ ! "${confirm:-N}" =~ ^[Yy]$ ]]; then
    info "Upgrade cancelled."
    return 0
  fi

  local postgres_password
  postgres_password="$(read_env POSTGRES_PASSWORD)"

  echo ""
  info "Stopping Rallly..."
  docker compose down

  info "Starting PostgreSQL $old_major..."
  if ! docker compose up -d db || ! wait_for_db; then
    fail_upgrade "The current database did not come up. Check './rallly.sh logs db'."
  fi

  local counts_before
  counts_before="$(db_table_counts)"
  case "$counts_before" in *query-failed*)
    fail_upgrade "Could not read row counts from the current database."
  ;; esac

  local backup_dir="$SCRIPT_DIR/backups"
  mkdir -p "$backup_dir"
  chmod 700 "$backup_dir"
  local dump_file
  dump_file="$backup_dir/rallly_pg${old_major}_to_pg${target_major}_$(date +%Y%m%d_%H%M%S).sql.gz"

  # Dump with a client matching the target major — pg_dump can read any
  # older server, and its output is guaranteed to restore into the target.
  # Runs in the db container's network namespace to reach it over TCP.
  info "Dumping the database with a PostgreSQL $target_major client..."
  local db_cid
  db_cid="$(docker compose ps -q db)"
  # Dumps contain the full database — keep them private like .env.
  if ! docker run --rm --network "container:${db_cid}" -e PGPASSWORD="$postgres_password" \
      "postgres:${target_major}-alpine" \
      pg_dump -h 127.0.0.1 -U postgres rallly | (umask 077; gzip > "$dump_file"); then
    fail_upgrade "pg_dump failed."
  fi
  if [ ! -s "$dump_file" ]; then
    fail_upgrade "The dump at $dump_file is empty."
  fi
  ok "Database dumped to $dump_file"

  info "Stopping PostgreSQL $old_major..."
  docker compose down

  # Deletion was disclosed in the confirmation prompt above.
  if [ -n "$leftover_volume" ] && docker volume inspect "$leftover_volume" &>/dev/null; then
    info "Removing volume $leftover_volume left over from a previous upgrade..."
    docker volume rm "$leftover_volume" >/dev/null || fail_upgrade "Could not remove the leftover volume $leftover_volume."
  fi

  info "Starting a fresh PostgreSQL $target_major..."
  export POSTGRES_VERSION="$target_major"
  export POSTGRES_DATA_MOUNT=/var/lib/postgresql
  export POSTGRES_VOLUME="$new_volume_key"
  if ! docker compose up -d db || ! wait_for_db; then
    fail_upgrade "PostgreSQL $target_major did not come up. Check './rallly.sh logs db'."
  fi

  info "Restoring the dump into PostgreSQL $target_major..."
  if ! gunzip -c "$dump_file" | docker compose exec -T db psql -q -v ON_ERROR_STOP=1 -U postgres -d rallly >/dev/null; then
    fail_upgrade "Restoring the dump into PostgreSQL $target_major failed."
  fi

  local counts_after
  counts_after="$(db_table_counts)"
  case "$counts_after" in *query-failed*)
    fail_upgrade "Could not read row counts from the restored database."
  ;; esac
  if [ "$counts_before" != "$counts_after" ]; then
    error "Row counts differ after the restore:"
    diff <(printf '%s\n' "$counts_before") <(printf '%s\n' "$counts_after") >&2 || true
    fail_upgrade "Sanity check failed after the restore."
  fi
  local table_total
  table_total="$(printf '%s' "$counts_before" | grep -c . || true)"
  ok "Restore verified ($table_total tables, row counts match)."

  # Switch all three pins in one atomic write — a partial switch (e.g. the
  # new major pointed at the old volume) would leave an install that cannot
  # start. The temp file lives next to .env so the rename stays atomic.
  local tmp_env
  tmp_env="$(mktemp "$ENV_FILE.XXXXXX")" || fail_upgrade "Could not create a temporary file to update .env."
  if ! { awk -F= -v ver="$target_major" -v mount="$POSTGRES_DATA_MOUNT" -v vol="$new_volume_key" '
    /^[[:space:]]*#/ { print; next }
    $1 == "POSTGRES_VERSION"    { print "POSTGRES_VERSION=" ver; seen_ver = 1; next }
    $1 == "POSTGRES_DATA_MOUNT" { print "POSTGRES_DATA_MOUNT=" mount; seen_mount = 1; next }
    $1 == "POSTGRES_VOLUME"     { print "POSTGRES_VOLUME=" vol; seen_vol = 1; next }
    { print }
    END {
      if (!seen_ver)   print "POSTGRES_VERSION=" ver
      if (!seen_mount) print "POSTGRES_DATA_MOUNT=" mount
      if (!seen_vol)   print "POSTGRES_VOLUME=" vol
    }
  ' "$ENV_FILE" > "$tmp_env" && chmod 600 "$tmp_env" && mv "$tmp_env" "$ENV_FILE"; }; then
    rm -f "$tmp_env"
    fail_upgrade "Could not update $ENV_FILE."
  fi

  info "Restarting Rallly..."
  docker compose up -d

  echo ""
  ok "PostgreSQL upgraded from $old_major to $target_major."
  echo ""
  echo "  Dump (rollback artifact):     $dump_file"
  echo "  Old PostgreSQL $old_major volume:    $old_volume (untouched)"
  echo ""
  echo "  To roll back, set these in .env and run './rallly.sh stop && ./rallly.sh start':"
  echo "    POSTGRES_VERSION=$old_major"
  echo "    POSTGRES_DATA_MOUNT=$old_mount"
  echo "    POSTGRES_VOLUME=$old_volume_key"
  echo ""
  echo "  ⚠ Rolling back restores the database as it was at the moment of this"
  echo "    upgrade — anything created afterward will be lost. Take a fresh"
  echo "    './rallly.sh backup' before rolling back."
  echo ""
  echo "  Once you're confident everything works, reclaim disk space with:"
  echo "    docker volume rm $old_volume"
}

cmd_help() {
  cat <<EOF
Rallly Management CLI

Usage: ./rallly.sh <command> [options]

Commands:
  setup          Interactive configuration and secret generation
  start          Start all services
  stop           Stop all services
  restart        Restart all services
  update         Pull latest images and restart
  logs [service] Stream logs (optionally for a specific service)
  status         Show service status
  backup         Back up the database to ./backups/
  upgrade-db     Upgrade the bundled PostgreSQL to $PG_DEFAULT_MAJOR (dump + restore into a fresh volume)
  help           Show this help message

Services: traefik, web, db, garage
EOF
}

case "${1:-help}" in
  setup)      cmd_setup ;;
  start)      cmd_start ;;
  stop)       cmd_stop ;;
  restart)    cmd_restart ;;
  update)     cmd_update ;;
  logs)       cmd_logs "${2:-}" ;;
  status)     cmd_status ;;
  backup)     cmd_backup ;;
  upgrade-db) cmd_upgrade_db ;;
  help|*)     cmd_help ;;
esac
