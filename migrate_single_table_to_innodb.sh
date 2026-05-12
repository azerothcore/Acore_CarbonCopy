#!/usr/bin/env bash
set -euo pipefail

# Migrate exactly one table from MyISAM to InnoDB.
# Defaults target CarbonCopy table in ac_eluna.
#
# Examples:
#   ./migrate_single_table_to_innodb.sh -u
#   ./migrate_single_table_to_innodb.sh -u root -p 'secret'
#   ./migrate_single_table_to_innodb.sh -u root -d ac_eluna -t carboncopy_player_logs
#   ./migrate_single_table_to_innodb.sh -u root --dry-run

HOST="127.0.0.1"
PORT="3306"
USER=""
PASSWORD=""
SOCKET=""
DB_NAME="ac_eluna"
TABLE_NAME="carboncopy"
BACKUP_DIR="./db_backups"
SKIP_BACKUP=0
DRY_RUN=0

usage() {
  cat <<'EOF'
Usage:
  migrate_single_table_to_innodb.sh -u USER [options]

Required:
  -u, --user USER                Database user

Options:
  -h, --host HOST                Database host (default: 127.0.0.1)
  -P, --port PORT                Database port (default: 3306)
  -p, --password PASSWORD        Database password (if omitted, prompts securely)
  -S, --socket PATH              MySQL socket path (optional)
  -d, --database NAME            Database/schema name (default: ac_eluna)
  -t, --table NAME               Table name (default: carboncopy)
  -b, --backup-dir PATH          Backup output folder (default: ./db_backups)
      --skip-backup              Skip mysqldump backup step
      --dry-run                  Print ALTER statement only
      --help                     Show this help
EOF
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "ERROR: Required command not found: $1" >&2
    exit 1
  fi
}

mysql_base_args() {
  local args=()
  args+=("-h" "$HOST" "-P" "$PORT" "-u" "$USER" "--batch" "--raw" "--silent")
  if [[ -n "$SOCKET" ]]; then
    args+=("-S" "$SOCKET")
  fi
  printf '%s\n' "${args[@]}"
}

mysql_exec() {
  local sql="$1"
  MYSQL_PWD="$PASSWORD" mysql $(mysql_base_args | tr '\n' ' ') -e "$sql"
}

mysqldump_base_args() {
  local args=()
  args+=("-h" "$HOST" "-P" "$PORT" "-u" "$USER")
  if [[ -n "$SOCKET" ]]; then
    args+=("-S" "$SOCKET")
  fi
  printf '%s\n' "${args[@]}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -u|--user)
      USER="${2:-}"
      shift 2
      ;;
    -h|--host)
      HOST="${2:-}"
      shift 2
      ;;
    -P|--port)
      PORT="${2:-}"
      shift 2
      ;;
    -p|--password)
      PASSWORD="${2:-}"
      shift 2
      ;;
    -S|--socket)
      SOCKET="${2:-}"
      shift 2
      ;;
    -d|--database)
      DB_NAME="${2:-}"
      shift 2
      ;;
    -t|--table)
      TABLE_NAME="${2:-}"
      shift 2
      ;;
    -b|--backup-dir)
      BACKUP_DIR="${2:-}"
      shift 2
      ;;
    --skip-backup)
      SKIP_BACKUP=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$USER" ]]; then
  echo "ERROR: --user is required." >&2
  usage
  exit 1
fi

if [[ -z "$PASSWORD" ]]; then
  read -r -s -p "DB password for $USER: " PASSWORD
  echo
fi

require_cmd mysql
if [[ $SKIP_BACKUP -eq 0 ]]; then
  require_cmd mysqldump
fi

echo "Checking DB connectivity..."
mysql_exec "SELECT 1;" >/dev/null

TABLE_EXISTS_SQL="
SELECT COUNT(*)
FROM information_schema.TABLES
WHERE TABLE_SCHEMA='${DB_NAME//\'/\'\'}'
  AND TABLE_NAME='${TABLE_NAME//\'/\'\'}';
"
EXISTS_COUNT="$(mysql_exec "$TABLE_EXISTS_SQL" | tail -n 1)"

if [[ "$EXISTS_COUNT" != "1" ]]; then
  echo "ERROR: Table not found: ${DB_NAME}.${TABLE_NAME}" >&2
  exit 1
fi

ENGINE_SQL="
SELECT ENGINE
FROM information_schema.TABLES
WHERE TABLE_SCHEMA='${DB_NAME//\'/\'\'}'
  AND TABLE_NAME='${TABLE_NAME//\'/\'\'}'
LIMIT 1;
"
CURRENT_ENGINE="$(mysql_exec "$ENGINE_SQL" | tail -n 1)"

ALTER_SQL="ALTER TABLE \`${DB_NAME}\`.\`${TABLE_NAME}\` ENGINE=InnoDB ROW_FORMAT=DEFAULT;"

echo "Target table: ${DB_NAME}.${TABLE_NAME}"
echo "Current engine: ${CURRENT_ENGINE}"

if [[ "$CURRENT_ENGINE" == "InnoDB" ]]; then
  echo "Already InnoDB. Nothing to do."
  exit 0
fi

if [[ "$CURRENT_ENGINE" != "MyISAM" ]]; then
  echo "WARNING: Current engine is ${CURRENT_ENGINE} (not MyISAM)."
  echo "Will still execute requested conversion to InnoDB."
fi

if [[ $DRY_RUN -eq 1 ]]; then
  echo "Dry run statement:"
  echo "$ALTER_SQL"
  exit 0
fi

if [[ $SKIP_BACKUP -eq 0 ]]; then
  mkdir -p "$BACKUP_DIR"
  TS="$(date +%Y%m%d_%H%M%S)"
  BACKUP_FILE="$BACKUP_DIR/${DB_NAME}_${TABLE_NAME}_pre_innodb_${TS}.sql"
  DUMP_STDERR_FILE="$(mktemp)"
  echo "Creating backup: $BACKUP_FILE"

  DUMP_EXIT=0
  MYSQL_PWD="$PASSWORD" mysqldump $(mysqldump_base_args | tr '\n' ' ') \
    --databases "$DB_NAME" --tables "$TABLE_NAME" \
    --routines --events --triggers --hex-blob --single-transaction \
    > "$BACKUP_FILE" 2>"$DUMP_STDERR_FILE" || DUMP_EXIT=$?

  # Always print any stderr so the user sees it.
  if [[ -s "$DUMP_STDERR_FILE" ]]; then
    cat "$DUMP_STDERR_FILE" >&2
  fi

  # Treat as failure if mysqldump exited non-zero OR stderr contains "Error:".
  # mysqldump can exit 0 on privilege warnings while still printing errors.
  BACKUP_OK=1
  if [[ $DUMP_EXIT -ne 0 ]] || grep -qi 'error:' "$DUMP_STDERR_FILE"; then
    BACKUP_OK=0
  fi
  rm -f "$DUMP_STDERR_FILE"

  if [[ $BACKUP_OK -eq 0 ]]; then
    echo "ERROR: Backup failed. Aborting — engine not changed." >&2
    rm -f "$BACKUP_FILE"
    exit 1
  fi
fi

echo "Running conversion..."
mysql_exec "$ALTER_SQL" >/dev/null

NEW_ENGINE="$(mysql_exec "$ENGINE_SQL" | tail -n 1)"
echo "New engine: ${NEW_ENGINE}"

if [[ "$NEW_ENGINE" != "InnoDB" ]]; then
  echo "ERROR: Conversion did not complete as expected." >&2
  exit 2
fi

echo "Done: ${DB_NAME}.${TABLE_NAME} is now InnoDB."
