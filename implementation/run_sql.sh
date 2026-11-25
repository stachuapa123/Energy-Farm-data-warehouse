#!/usr/bin/env bash
# Runs the SQL scripts with sqlcmd - inside the SQL Server container (default) or with a local
# sqlcmd when SQL Server is installed natively on Linux (MSSQL_IN_DOCKER=false in .env).
#
# Usage:
#   ./run_sql.sh without_partitions                 initial load (T1): 01 02 03 04_dim 04_fact 05 06
#   ./run_sql.sh with_partitions                    initial load (T1): 00 01_0 01_01 02 03 04_0_dim 04_0_fact 05 06
#   ./run_sql.sh without_partitions 07 08           incremental load (T2), validation + 10 queries
#   ./run_sql.sh with_partitions 07 08
#   ./run_sql.sh . 09                               partitioned vs non-partitioned comparison
# Each argument after the folder is the beginning of a script name; it must match exactly one file.
set -euo pipefail
cd "$(dirname "$0")"

set -a
# shellcheck disable=SC1091
. ./.env
set +a

folder="${1:?usage: ./run_sql.sh <without_partitions|with_partitions|.> [script-prefix ...]}"
shift

if [ $# -eq 0 ]; then
  case "$folder" in
    without_partitions) set -- 01 02 03 04_d 04_f 05 06 ;;
    with_partitions)    set -- 00 01_0_ 01_01 02 03 04_0_d 04_0_f 05 06 ;;
    *) echo "Give the script prefixes, e.g. ./run_sql.sh . 09" >&2; exit 1 ;;
  esac
fi

run_sqlcmd() {
  # -C trust the server certificate, -I QUOTED_IDENTIFIER ON (filtered indexes),
  # -b stop on the first error, -W trim trailing spaces in the output
  if [ "${MSSQL_IN_DOCKER:-true}" = "true" ]; then
    docker compose exec -T mssql /opt/mssql-tools18/bin/sqlcmd -C -I -b -W \
      -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -i "/sql/$1"
  else
    sqlcmd -C -I -b -W -S "localhost,${MSSQL_PORT:-1433}" -U sa -P "$MSSQL_SA_PASSWORD" -i "$1"
  fi
}

for prefix in "$@"; do
  shopt -s nullglob
  matches=("$folder"/"$prefix"*.sql)
  shopt -u nullglob
  if [ "${#matches[@]}" -ne 1 ]; then
    echo "Prefix '$prefix' matches ${#matches[@]} scripts in '$folder' (expected exactly 1)." >&2
    exit 1
  fi
  script="${matches[0]#./}"
  echo
  echo "=================== $script ==================="
  start=$(date +%s)
  run_sqlcmd "$script"
  echo "------------------- $script finished in $(( $(date +%s) - start )) s"
done
