#!/usr/bin/env bash

set -euo pipefail

# --- Parse arguments ---------------------------------------------------------
DB_HOST="127.0.0.1"
DB_PORT="3306"
DB_USER=""
DB_PASS=""
DB_NAME="openmrs"
DOCKER_CONTAINER=""

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

# Prompt for password securely if not provided via -p
if [[ -z "$DB_PASS" ]]; then
    read -r -s -p "  Enter password for $DB_USER: " DB_PASS
    echo ""
    echo ""
fi

BACKUP_FILE="$(dirname "${BASH_SOURCE[0]}")/backup_BAH-4718_$(date +%Y%m%d_%H%M%S).sql"

# --- Build mysqldump command --------------------------------------------------
if [[ -n "$DOCKER_CONTAINER" ]]; then
    MYSQLDUMP_CMD="docker exec -e MYSQL_PWD=$DB_PASS $DOCKER_CONTAINER mysqldump -u $DB_USER"
else
    MYSQLDUMP_CMD="mysqldump -h $DB_HOST -P $DB_PORT -u $DB_USER -p$DB_PASS"
fi

# --- Header ------------------------------------------------------------------
echo ""
echo "============================================================"
echo "  BAH-4718: Pre-Migration Backup"
echo "============================================================"
echo ""
echo "  Tables : obs, document_reference, document_reference_content"
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

# --- Confirm -----------------------------------------------------------------
read -r -p "  Proceed with backup? [yes/no]: " CONFIRM
echo ""

if [[ "$CONFIRM" != "yes" ]]; then
    echo "  Backup cancelled."
    echo ""
    exit 0
fi

# --- Run backup --------------------------------------------------------------
echo "  Taking backup..."
echo ""

$MYSQLDUMP_CMD --single-transaction --quick "$DB_NAME" obs document_reference document_reference_content > "$BACKUP_FILE" 2>/dev/null

BACKUP_SIZE=$(wc -c < "$BACKUP_FILE")
if [[ "$BACKUP_SIZE" -eq 0 ]]; then
    echo "  ERROR: Backup file is empty. Check your connection and credentials."
    echo ""
    exit 1
fi

echo "  Backup complete."
echo "  File : $BACKUP_FILE"
echo "  Size : $(du -sh "$BACKUP_FILE" | cut -f1)"
echo ""

# --- Restore instructions ----------------------------------------------------
echo "  To restore if needed:"
echo ""
if [[ -n "$DOCKER_CONTAINER" ]]; then
echo "    cat $BACKUP_FILE | docker exec -i -e MYSQL_PWD=<password> $DOCKER_CONTAINER mysql -u $DB_USER $DB_NAME"
else
echo "    mysql -h $DB_HOST -P $DB_PORT -u $DB_USER -p<password> $DB_NAME < $BACKUP_FILE"
fi
echo ""
echo "  You can now run the migration:"
echo "    ./data-migrate-legacy-documents.sh (same connection args)"
echo ""
