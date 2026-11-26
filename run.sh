#!/usr/bin/env bash
# EcoVolt - optional helper that runs the SQL scripts with sqlcmd inside the SQL Server container,
# in the same order as README.md (instead of running them one by one in an SQL client).
# Run it from the project directory after: docker compose up -d
#
#   ./run.sh                    everything: without_partitions -> with_partitions -> comparison
#   ./run.sh --reset            same, but first drops EcoVoltDW and EcoVoltDW_Part (fresh start)
#   ./run.sh without            only dw_creation_scripts/without_partitions (01 ... 06)
#   ./run.sh with               only dw_creation_scripts/with_partitions   (00 ... 06_0)
#   ./run.sh compare            only dw_creation_scripts/compare_partitioned_vs_not.sql
#   ./run.sh crosscheck         only queries/sql_crosscheck.sql (on EcoVoltDW)
#   ./run.sh sources            the source system for the ETL stage (PowerMaster + weather staging)
#   ./run.sh --reset without with compare     steps can be combined
set -euo pipefail
cd "$(dirname "$0")"

CONTAINER="${MSSQL_CONTAINER:-mssql-db}"
# Must match MSSQL_SA_PASSWORD in docker-compose.yml.
MSSQL_SA_PASSWORD="${MSSQL_SA_PASSWORD:-EcoVolt_Strong_Pass_2025}"
SQL_ROOT_IN_CONTAINER="/sql"
SCRIPTS="dw_creation_scripts"

# ---------- arguments ----------
RESET=false
STEPS=()
for arg in "$@"; do
  case "$arg" in
    --reset) RESET=true ;;
    sources|without|with|compare|crosscheck) STEPS+=("$arg") ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $arg (use --help)" >&2; exit 1 ;;
  esac
done
[ "${#STEPS[@]}" -eq 0 ] && STEPS=(without with compare)

# ---------- helpers ----------
sqlcmd_in_container() {
  docker exec -i "$CONTAINER" /opt/mssql-tools18/bin/sqlcmd -C -I -b -W \
    -S localhost -U sa -P "$MSSQL_SA_PASSWORD" "$@"
}

run_file() {                      # $1 = path relative to this folder
  local rel="$1" start
  if ! docker exec "$CONTAINER" test -f "$SQL_ROOT_IN_CONTAINER/$rel"; then
    echo "ERROR: $rel is not visible in the container at $SQL_ROOT_IN_CONTAINER/$rel" >&2
    echo "       Is this folder mounted at $SQL_ROOT_IN_CONTAINER (docker-compose.yml: - .:/sql:ro)?" >&2
    exit 1
  fi
  echo
  echo "=================== $rel ==================="
  start=$(date +%s)
  sqlcmd_in_container -i "$SQL_ROOT_IN_CONTAINER/$rel"
  echo "------------------- $rel OK ($(( $(date +%s) - start )) s)"
}

find_one() {                      # $1 = file name in Schemas/ or Data/
  local matches=()
  mapfile -t matches < <(find ./Schemas ./Data -type f -name "$1" -print)
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
echo -n "Waiting for SQL Server in $CONTAINER"
for _ in $(seq 1 60); do
  if sqlcmd_in_container -Q "SELECT 1" >/dev/null 2>&1; then echo " - ready"; break; fi
  echo -n "."; sleep 2
done
if [[ " ${STEPS[*]} " == *" without "* || " ${STEPS[*]} " == *" with "* ]]; then
  docker exec "$CONTAINER" test -f /dw_data/bulk/EnergyProduction_2024.csv \
    || { echo "ERROR: /dw_data/bulk is empty in the container - run: python Generator/export_bulk.py" >&2; exit 1; }
fi

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
      echo
      echo "=================== copying Data/ to $CONTAINER:/var/opt/mssql/import ==================="
      [ -d Data ] || { echo "ERROR: Data/ not found in $(pwd)" >&2; exit 1; }
      docker exec -u root "$CONTAINER" mkdir -p /var/opt/mssql/import
      docker cp Data/. "$CONTAINER":/var/opt/mssql/import/
      docker exec -u root "$CONTAINER" chmod -R a+rX /var/opt/mssql/import
      run_file "$(find_one PowerMaster_schema.sql)"
      run_file "$(find_one Weather_linux_docker.sql)"
      run_file "$(find_one load_snapshot_docker_linux.sql)"
      ;;
    without)
      if db_exists EcoVoltDW; then
        echo "ERROR: EcoVoltDW already exists - the scripts load into empty tables. Use ./run.sh --reset without" >&2
        exit 1
      fi
      for p in 01 02 03 04_d 04_f 05 06; do
        run_prefix "$SCRIPTS/without_partitions" "$p"
      done
      ;;
    with)
      if db_exists EcoVoltDW_Part; then
        echo "ERROR: EcoVoltDW_Part already exists - the scripts load into empty tables. Use ./run.sh --reset with" >&2
        exit 1
      fi
      for p in 00 01_0_ 01_01 02 03 04_0_d 04_0_f 05 06; do
        run_prefix "$SCRIPTS/with_partitions" "$p"
      done
      ;;
    compare)
      run_file "$SCRIPTS/compare_partitioned_vs_not.sql"
      ;;
    crosscheck)
      run_file "queries/sql_crosscheck.sql"
      ;;
  esac
done

echo
echo "All done."
