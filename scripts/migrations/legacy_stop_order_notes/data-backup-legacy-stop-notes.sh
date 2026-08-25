#!/usr/bin/env bash
set -euo pipefail

# ─── Argument defaults ────────────────────────────────────────────────────────
DB_HOST="127.0.0.1"
DB_PORT="3306"
DB_USER=""
DB_PASS=""
DB_NAME=""
DOCKER_CONTAINER=""

# ─── Usage ────────────────────────────────────────────────────────────────────
usage() {
    echo ""
    echo "Usage (direct) : $0 -u <user> [-p <password>] -d <database> [-h <host>] [-P <port>]"
    echo "Usage (Docker) : $0 -u <user> [-p <password>] -d <database> -c <container>"
    echo ""
    echo "  -u  MySQL username (required)"
    echo "  -p  MySQL password (optional — prompted securely if not provided)"
    echo "  -d  Database name  (required)"
    echo "  -h  Host           (default: 127.0.0.1, direct mode only)"
    echo "  -P  Port           (default: 3306,      direct mode only)"
    echo "  -c  Docker container name"
    echo ""
    exit 1
}

while getopts "h:P:u:p:d:c:" opt; do
    case $opt in
        h) DB_HOST="$OPTARG" ;;
        P) DB_PORT="$OPTARG" ;;
        u) DB_USER="$OPTARG" ;;
        p) DB_PASS="$OPTARG" ;;
        d) DB_NAME="$OPTARG" ;;
        c) DOCKER_CONTAINER="$OPTARG" ;;
        *) usage ;;
    esac
done

if [[ -z "$DB_USER" || -z "$DB_NAME" ]]; then
    usage
fi

if [[ -z "$DB_PASS" ]]; then
    read -r -s -p "  Enter password for $DB_USER: " DB_PASS
    echo ""
    echo ""
fi

BACKUP_FILE="$(dirname "${BASH_SOURCE[0]}")/backup_BAH-4996_$(date +%Y%m%d_%H%M%S).sql"

# ─── Build mysqldump command ──────────────────────────────────────────────────
if [[ -n "$DOCKER_CONTAINER" ]]; then
    MYSQLDUMP_CMD="docker exec -e MYSQL_PWD=$DB_PASS $DOCKER_CONTAINER mysqldump -u $DB_USER"
else
    MYSQLDUMP_CMD="mysqldump -h $DB_HOST -P $DB_PORT -u $DB_USER -p$DB_PASS"
fi

# ─── Header ───────────────────────────────────────────────────────────────────
echo ""
echo "============================================================"
echo "  Pre-Migration Backup: Legacy Medication Order Notes"
echo "============================================================"
echo ""
echo "  Tables : orders"
echo "           drug_order"
echo "  Output : $BACKUP_FILE"
echo ""
if [[ -n "$DOCKER_CONTAINER" ]]; then
    echo "  Mode    : Docker ($DOCKER_CONTAINER)"
else
    echo "  Mode    : Direct ($DB_HOST:$DB_PORT)"
fi
echo "  Database: $DB_NAME"
echo ""
echo "  NOTE: This is a targeted table-level backup."
echo "  It is NOT a substitute for a full infrastructure-level"
echo "  backup (RDS snapshot, full mysqldump, etc.)."
echo "============================================================"
echo ""

read -r -p "  Proceed with backup? [yes/no]: " CONFIRM
echo ""

if [[ "$CONFIRM" != "yes" ]]; then
    echo "  Backup cancelled."
    echo ""
    exit 0
fi

echo "  Taking backup..."
echo ""

# Capture stderr separately — mixing it into the dump file (2>&1) can
# embed non-fatal mysqldump warnings as invalid SQL, breaking restore.
DUMP_STDERR=$(mktemp)
set +e
$MYSQLDUMP_CMD \
    --single-transaction \
    --quick \
    "$DB_NAME" \
    orders \
    drug_order \
    > "$BACKUP_FILE" 2>"$DUMP_STDERR"
DUMP_EXIT=$?
set -e

if [[ -s "$DUMP_STDERR" ]]; then
    echo "  mysqldump warnings/errors:"
    cat "$DUMP_STDERR"
    echo ""
fi
rm -f "$DUMP_STDERR"

if [[ $DUMP_EXIT -ne 0 ]]; then
    echo "  ERROR: mysqldump failed (exit code $DUMP_EXIT)."
    rm -f "$BACKUP_FILE"
    exit 1
fi

if [[ ! -s "$BACKUP_FILE" ]]; then
    echo "  ERROR: Backup file is empty. Check your connection and credentials."
    rm -f "$BACKUP_FILE"
    exit 1
fi

if ! grep -q "^-- Dump completed" "$BACKUP_FILE"; then
    echo "  ERROR: Backup file is missing the mysqldump completion footer. The dump may be incomplete."
    rm -f "$BACKUP_FILE"
    exit 1
fi

echo "  Backup complete."
echo ""
echo "  File : $BACKUP_FILE"
echo "  Size : $(du -sh "$BACKUP_FILE" | cut -f1)"
echo ""
echo "  Pass this path to the rollback script with -b if needed."
echo ""
