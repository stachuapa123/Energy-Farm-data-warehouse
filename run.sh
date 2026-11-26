#!/usr/bin/env bash
# EcoVolt - runs the whole pipeline inside the SQL Server container with sqlcmd.
# Place in the repository root (next to docker-compose.yml, .env, Data/, Schemas/, implementation/).
#
#   ./run.sh                    everything: sources -> without_partitions -> with_partitions -> comparison
#   ./run.sh --reset            same, but first drops EcoVoltDW and EcoVoltDW_Part (fresh start)
#   ./run.sh sources            only the source system (PowerMaster + weather staging)
#   ./run.sh without            only implementation/without_partitions (01 ... 08)
#   ./run.sh with               only implementation/with_partitions   (00 ... 08_0)
#   ./run.sh compare            only implementation/09_compare_partitioned_vs_not.sql
#   ./run.sh --reset without with compare     steps can be combined
#
# Requirements: the container is running (docker compose up -d) and mounts this folder at /sql
# and the Data folder at /dw_data. The password is read from MSSQL_SA_PASSWORD in .env.
set -euo pipefail
cd "$(dirname "$0")"

CONTAINER="${MSSQL_CONTAINER:-ecovolt-mssql}"
SQL_ROOT_IN_CONTAINER="/sql"          # where this folder is mounted in the container
IMPL="implementation"

# ---------- settings from .env ----------
if [ ! -f .env ]; then
  echo "ERROR: .env not found in $(pwd)" >&2
  exit 1
fi
set -a
# shellcheck disable=SC1091
. ./.env
set +a
: "${MSSQL_SA_PASSWORD:?MSSQL_SA_PASSWORD is not set in .env}"

# ---------- arguments ----------
RESET=false
STEPS=()
for arg in "$@"; do
  case "$arg" in
    --reset) RESET=true ;;
    sources|without|with|compare) STEPS+=("$arg") ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $arg (use --help)" >&2; exit 1 ;;
  esac
done
[ "${#STEPS[@]}" -eq 0 ] && STEPS=(sources without with compare)

# ---------- helpers ----------
sqlcmd_in_container() {
  # -C trust certificate, -I QUOTED_IDENTIFIER ON (filtered indexes), -b stop on error, -W trim spaces
  docker exec -i "$CONTAINER" /opt/mssql-tools18/bin/sqlcmd -C -I -b -W \
    -S localhost -U sa -P "$MSSQL_SA_PASSWORD" "$@"
}

run_file() {                      # $1 = path relative to this folder
  local rel="$1" start
  if ! docker exec "$CONTAINER" test -f "$SQL_ROOT_IN_CONTAINER/$rel"; then
    echo "ERROR: $rel is not visible in the container at $SQL_ROOT_IN_CONTAINER/$rel" >&2
    echo "       Is this folder mounted at $SQL_ROOT_IN_CONTAINER (docker-compose.yml: - .:/sql:ro,z)?" >&2
    exit 1
  fi
  echo
  echo "=================== $rel ==================="
  start=$(date +%s)
  sqlcmd_in_container -i "$SQL_ROOT_IN_CONTAINER/$rel"
  echo "------------------- $rel OK ($(( $(date +%s) - start )) s)"
}

find_one() {                      # $1 = file name anywhere in the repository (outside implementation/)
  local matches=()
  mapfile -t matches < <(find . -path "./$IMPL" -prune -o -path ./.git -prune -o -type f -name "$1" -print)
  if [ "${#matches[@]}" -ne 1 ]; then
    echo "ERROR: expected exactly one file named $1, found ${#matches[@]}: ${matches[*]:-none}" >&2
    exit 1
  fi
  echo "${matches[0]#./}"
}

run_prefix() {                    # $1 = folder, $2 = beginning of the script name (must match exactly one file)
  local matches=()
  shopt -s nullglob
  matches=("$1"/"$2"*.sql)
  shopt -u nullglob
  if [ "${#matches[@]}" -ne 1 ]; then
    echo "ERROR: '$2' matches ${#matches[@]} scripts in $1 (expected 1)" >&2
    exit 1
  fi
  run_file "${matches[0]}"
}

db_exists() {
  [ "$(sqlcmd_in_container -h -1 -Q "SET NOCOUNT ON; SELECT CASE WHEN DB_ID(N'$1') IS NULL THEN 0 ELSE 1 END;" | tr -d '[:space:]')" = "1" ]
}

# ---------- container ready? ----------
if ! docker inspect "$CONTAINER" >/dev/null 2>&1; then
  echo "ERROR: container $CONTAINER not found - start it with: docker compose up -d" >&2
  exit 1
fi
echo -n "Waiting for $CONTAINER to be healthy"
for _ in $(seq 1 60); do
  status=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$CONTAINER")
  if [ "$status" = "healthy" ] || [ "$status" = "running" ]; then echo " - $status"; break; fi
  echo -n "."; sleep 2
done
docker exec "$CONTAINER" test -d /dw_data/T1/PowerMaster \
  || { echo "ERROR: /dw_data/T1/PowerMaster is not visible in the container (check DATA_DIR and :z)" >&2; exit 1; }

# ---------- fresh start ----------
if $RESET; then
  echo
  echo "=================== dropping EcoVoltDW and EcoVoltDW_Part ==================="
  sqlcmd_in_container -Q "
    IF DB_ID(N'EcoVoltDW') IS NOT NULL
    BEGIN ALTER DATABASE EcoVoltDW SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE EcoVoltDW; END;
    IF DB_ID(N'EcoVoltDW_Part') IS NOT NULL
    BEGIN ALTER DATABASE EcoVoltDW_Part SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE EcoVoltDW_Part; END;"
fi

# ---------- steps ----------
for step in "${STEPS[@]}"; do
  case "$step" in
    sources)
      run_file "$(find_one PowerMaster_schema.sql)"
      run_file "$(find_one Weather_linux_docker.sql)"
      run_file "$(find_one load_snapshot_docker_linux.sql)"
      ;;
    without)
      if db_exists EcoVoltDW; then
        echo "ERROR: EcoVoltDW already exists - the scripts load into empty tables. Use ./run.sh --reset without" >&2
        exit 1
      fi
      for p in 01 02 03 04_d 04_f 05 06 07 08; do
        run_prefix "$IMPL/without_partitions" "$p"
      done
      ;;
    with)
      if db_exists EcoVoltDW_Part; then
        echo "ERROR: EcoVoltDW_Part already exists - the scripts load into empty tables. Use ./run.sh --reset with" >&2
        exit 1
      fi
      for p in 00 01_0_ 01_01 02 03 04_0_d 04_0_f 05 06 07 08; do
        run_prefix "$IMPL/with_partitions" "$p"
      done
      ;;
    compare)
      run_file "$IMPL/09_compare_partitioned_vs_not.sql"
      ;;
  esac
done

echo
echo "All done."