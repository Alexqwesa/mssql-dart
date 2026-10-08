#!/usr/bin/env bash
# Builds the Linux native TLS helper, runs offline Dart tests, starts the live
# SQL Server stack (or the edition matrix), and runs test/live.
#
# Usage:
#   bash tool/full_tests.sh           # docker-compose.live.yml (14334/14335)
#   bash tool/full_tests.sh --matrix  # docker-compose.matrix.yml (all editions)
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
password="${MSSQL_SA_PASSWORD:-Strong_test_password_123!}"
mode=live
matrix_image_revision=3

usage() {
  cat <<'EOF'
Usage: bash tool/full_tests.sh [--live|--matrix]

  --live     Start docker-compose.live.yml (default; ports 14334/14335)
  --matrix   Start docker-compose.matrix.yml and run live tests per edition

Environment:
  MSSQL_SA_PASSWORD   SA password (default: Strong_test_password_123!)
  DOCKER_HOST         Docker engine socket. If unset or pointed at a missing
                      Rancher Desktop socket, falls back to /var/run/docker.sock.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --live) mode=live; shift ;;
    --matrix) mode=matrix; shift ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

prefer_system_docker() {
  # Prefer a working system dockerd when DOCKER_HOST points at a missing
  # Rancher Desktop socket (common after PATH installs ~/.rd/bin/docker).
  if [[ ! -S /var/run/docker.sock ]]; then
    return
  fi
  if ! docker -H unix:///var/run/docker.sock info >/dev/null 2>&1; then
    return
  fi
  if ! docker info >/dev/null 2>&1; then
    export DOCKER_HOST=unix:///var/run/docker.sock
    echo "Using system Docker at $DOCKER_HOST"
  fi
}

wait_sql_server() {
  local container=$1
  local attempt sqlcmd
  for attempt in $(seq 1 90); do
    if docker exec "$container" test -x /opt/mssql-tools18/bin/sqlcmd >/dev/null 2>&1; then
      sqlcmd=/opt/mssql-tools18/bin/sqlcmd
    else
      sqlcmd=/opt/mssql-tools/bin/sqlcmd
    fi
    if docker exec "$container" "$sqlcmd" -S localhost -U sa -P "$password" -C -Q 'SELECT/**/1;' >/dev/null 2>&1; then
      echo "$container ready"
      return 0
    fi
    sleep 2
  done
  docker compose -f "$compose" logs || true
  echo "SQL Server container did not become ready: $container" >&2
  return 1
}

run_dart_tests() {
  local label=$1
  shift
  local output exit_code
  set +e
  output="$(dart test "$@" --reporter=expanded 2>&1)"
  exit_code=$?
  set -e
  if [[ $exit_code -ne 0 ]] || grep -Eq '~[1-9][0-9]*' <<<"$output"; then
    printf '%s\n' "$output"
  else
    printf '%s\n' "$output" | awk 'NF { line=$0 } END { if (line != "") print line }'
  fi
  if [[ $exit_code -ne 0 ]]; then
    echo "$label failed." >&2
    return "$exit_code"
  fi
  if grep -Eq '~[1-9][0-9]*' <<<"$output"; then
    echo "$label unexpectedly skipped tests." >&2
    return 1
  fi
}

prefer_system_docker
need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Required command not found: $1" >&2
    exit 1
  }
}
need docker
need dart

cd "$root"

echo "Building native TLS library and running C++ tests..."
bash "$root/tool/build_native.sh"

echo "Running offline Dart tests..."
mapfile -t offline_tests < <(find "$root/test" -maxdepth 1 -type f -name '*.dart' | sort)
run_dart_tests 'Offline Dart tests' "${offline_tests[@]}"

if [[ ! -f "$root/.env" ]]; then
  cp "$root/.env.example" "$root/.env"
fi

if [[ "$mode" == live ]]; then
  compose="$root/docker-compose.live.yml"
  echo "Starting live SQL Server containers..."
  docker compose --env-file "$root/.env" -f "$compose" up -d --build
  wait_sql_server mssql-dart-live
  wait_sql_server mssql-dart-live-force-tls

  export MSSQL_LIVE_TESTS=1
  export MSSQL_HOST=127.0.0.1
  export MSSQL_PORT=14334
  export MSSQL_FORCE_TLS_PORT=14335
  export MSSQL_ENCRYPT=0
  export MSSQL_USER=sa
  export MSSQL_PASSWORD="$password"
  export MSSQL_TRUST_SERVER_CERTIFICATE=1

  echo "Running live tests against docker-compose.live.yml..."
  run_dart_tests 'Live Dart tests' test/live --concurrency=1

  echo
  echo "Live SQL Server containers were kept for reuse."
  echo "Stop them manually when finished:"
  echo "  DOCKER_HOST=${DOCKER_HOST:-unix:///var/run/docker.sock} docker compose --env-file .env -f docker-compose.live.yml down"
  exit 0
fi

compose="$root/docker-compose.matrix.yml"
matrix_images=(
  'sqlserver-2017|mssql-dart-live:2017'
  'sqlserver-2019|mssql-dart-live:2019'
  'sqlserver-2022|mssql-dart-live:2022'
  'sqlserver-2025|mssql-dart-live:2025'
)

missing_services=()
for entry in "${matrix_images[@]}"; do
  service="${entry%%|*}"
  image="${entry##*|}"
  if ! docker image inspect "$image" >/dev/null 2>&1; then
    missing_services+=("$service")
    continue
  fi
  revision="$(docker image inspect "$image" --format '{{index .Config.Labels "org.mssql.dart.live.revision"}}' 2>/dev/null || true)"
  if [[ "$revision" != "$matrix_image_revision" ]]; then
    missing_services+=("$service")
  fi
done

if ((${#missing_services[@]} > 0)); then
  echo "Building missing SQL Server matrix images: ${missing_services[*]}"
  docker compose -f "$compose" build "${missing_services[@]}"
  stale=()
  for service in "${missing_services[@]}"; do
    stale+=("$service" "${service}-force-tls")
  done
  docker compose -f "$compose" rm -sf "${stale[@]}"
fi

echo "Starting SQL Server matrix containers..."
docker compose -f "$compose" up -d --no-build

editions=(
  'SQL Server 2017|14170|14171|mssql-dart-live-2017'
  'SQL Server 2019|14190|14191|mssql-dart-live-2019'
  'SQL Server 2022|14220|14221|mssql-dart-live-2022'
  'SQL Server 2025|14250|14251|mssql-dart-live-2025'
)

for edition in "${editions[@]}"; do
  IFS='|' read -r name normal_port force_port container <<<"$edition"
  echo "Waiting for $name..."
  wait_sql_server "$container"
  echo "Running live tests against $name..."
  export MSSQL_LIVE_TESTS=1
  export MSSQL_HOST=127.0.0.1
  export MSSQL_PORT="$normal_port"
  export MSSQL_FORCE_TLS_PORT="$force_port"
  export MSSQL_ENCRYPT=0
  export MSSQL_USER=sa
  export MSSQL_PASSWORD="$password"
  export MSSQL_TRUST_SERVER_CERTIFICATE=1
  run_dart_tests "Live Dart tests ($name)" test/live --concurrency=1
done

echo
echo "SQL Server matrix containers were kept for reuse."
echo "Stop them manually when finished:"
echo "  DOCKER_HOST=${DOCKER_HOST:-unix:///var/run/docker.sock} docker compose -f docker-compose.matrix.yml down"
