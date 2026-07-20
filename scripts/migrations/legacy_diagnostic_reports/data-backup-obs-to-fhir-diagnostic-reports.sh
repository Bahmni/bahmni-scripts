#!/usr/bin/env bash
set -euo pipefail

# ─── Argument defaults ────────────────────────────────────────────────────────
DB_HOST="127.0.0.1"
DB_PORT="3306"
DB_USER=""
DB_PASS=""
DB_NAME="openmrs"
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

BACKUP_FILE="$(dirname "${BASH_SOURCE[0]}")/backup_diagnostic_report_migration_$(date +%Y%m%d_%H%M%S).sql"

# ─── Build mysqldump command ──────────────────────────────────────────────────
if [[ -n "$DOCKER_CONTAINER" ]]; then
    MYSQLDUMP_CMD="docker exec -e MYSQL_PWD=$DB_PASS $DOCKER_CONTAINER mysqldump -u $DB_USER"
else
    MYSQLDUMP_CMD="mysqldump -h $DB_HOST -P $DB_PORT -u $DB_USER -p$DB_PASS"
fi

# ─── Header ───────────────────────────────────────────────────────────────────
echo ""
echo "============================================================"
echo "  Pre-Migration Backup: Obs → FHIR Diagnostic Reports"
echo "============================================================"
echo ""
echo "  Tables : obs"
echo "           fhir_diagnostic_report"
echo "           fhir_diagnostic_report_results"
echo "           fhir_diagnostic_report_performers"
echo "           fhir_diagnostic_report_service_request"
echo "           fhir_diagnostic_report_presented_form"
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

$MYSQLDUMP_CMD \
    --single-transaction \
    --quick \
    "$DB_NAME" \
    obs \
    fhir_diagnostic_report \
    fhir_diagnostic_report_results \
    fhir_diagnostic_report_performers \
    fhir_diagnostic_report_service_request \
    fhir_diagnostic_report_presented_form \
    > "$BACKUP_FILE" 2>&1

echo "  Backup complete."
echo ""
echo "  File : $BACKUP_FILE"
echo "  Size : $(du -sh "$BACKUP_FILE" | cut -f1)"
echo ""
echo "  Pass this path to the rollback script with -b if needed."
echo ""