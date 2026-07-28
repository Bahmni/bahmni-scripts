#!/usr/bin/env bash
set -euo pipefail

# ─── Usage ────────────────────────────────────────────────────────────────────
usage() {
    echo ""
    echo "Usage (direct) : $0 -u <user> [-p <password>] -d <database> [-h <host>] [-P <port>]"
    echo "Usage (Docker) : $0 -u <user> [-p <password>] -d <database> -c <container>"
    echo ""
    echo "  Prints a before/after audit of legacy lab obs vs FHIR DiagnosticReport rows."
    echo "  Run before migration to capture a baseline, and again after to verify completeness."
    echo "  Covers AC-1 (audit) and supports AC-15 (no data loss verification)."
    echo ""
    exit 1
}

# ─── Argument defaults ────────────────────────────────────────────────────────
DB_HOST="localhost"
DB_PORT="3306"
DB_USER=""
DB_PASS=""
DB_NAME="openmrs"
DOCKER_CONTAINER=""

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

if [[ -n "$DOCKER_CONTAINER" ]]; then
    MYSQL_CMD="docker exec -e MYSQL_PWD=$DB_PASS $DOCKER_CONTAINER mysql -u $DB_USER $DB_NAME"
else
    MYSQL_CMD="mysql -h $DB_HOST -P $DB_PORT -u $DB_USER -p$DB_PASS $DB_NAME"
fi

# ─── Early connectivity check ─────────────────────────────────────────────────
CONN_TEST=$($MYSQL_CMD --skip-column-names -e "SELECT 1;" 2>&1) || true
if [[ "$CONN_TEST" != "1" ]]; then
    echo ""
    echo "  ERROR: Cannot connect to MySQL."
    echo "  $CONN_TEST"
    echo ""
    exit 1
fi

fmt_num() { printf "%'d" "$1"; }

echo ""
echo "============================================================"
echo "  Obs → FHIR DiagnosticReport Migration Audit"
echo "============================================================"
if [[ -n "$DOCKER_CONTAINER" ]]; then
    echo "  Mode    : Docker ($DOCKER_CONTAINER)"
else
    echo "  Mode    : Direct ($DB_HOST:$DB_PORT)"
fi
echo "  Database: $DB_NAME"
echo "  Time    : $(date '+%Y-%m-%d %H:%M:%S')"
echo "============================================================"
echo ""

# ─── Query all counts ─────────────────────────────────────────────────────────
# Run each query separately so parsing is unambiguous
ELIGIBLE=$($MYSQL_CMD --skip-column-names -e "
  SELECT COUNT(*) FROM obs
  WHERE obs_group_id IS NULL AND order_id IS NOT NULL AND voided = 0;" 2>/dev/null | tr -d '[:space:]')

MIGRATED=$($MYSQL_CMD --skip-column-names -e "
  SELECT COUNT(*) FROM obs o
  JOIN fhir_diagnostic_report dr ON dr.uuid = o.uuid
  WHERE o.obs_group_id IS NULL AND o.order_id IS NOT NULL AND o.voided = 0;" 2>/dev/null | tr -d '[:space:]')

PENDING=$($MYSQL_CMD --skip-column-names -e "
  SELECT COUNT(*) FROM obs o
  WHERE o.obs_group_id IS NULL AND o.order_id IS NOT NULL AND o.voided = 0
    AND NOT EXISTS (
        SELECT 1 FROM fhir_diagnostic_report dr WHERE dr.uuid = o.uuid);" 2>/dev/null | tr -d '[:space:]')

WITH_RESULTS=$($MYSQL_CMD --skip-column-names -e "
  SELECT COUNT(DISTINCT diagnostic_report_id)
  FROM fhir_diagnostic_report_results;" 2>/dev/null | tr -d '[:space:]')

WITH_SR=$($MYSQL_CMD --skip-column-names -e "
  SELECT COUNT(DISTINCT diagnostic_report_id)
  FROM fhir_diagnostic_report_service_request;" 2>/dev/null | tr -d '[:space:]')

WITH_ATTACH=$($MYSQL_CMD --skip-column-names -e "
  SELECT COUNT(DISTINCT diagnostic_report_id)
  FROM fhir_diagnostic_report_presented_form;" 2>/dev/null | tr -d '[:space:]')

BATCH_CNT=$($MYSQL_CMD --skip-column-names -e "
  SELECT COUNT(DISTINCT batch_id) FROM fhir_diag_report_migration_log;" 2>/dev/null | tr -d '[:space:]')

LOG_ROWS=$($MYSQL_CMD --skip-column-names -e "
  SELECT COUNT(*) FROM fhir_diag_report_migration_log;" 2>/dev/null | tr -d '[:space:]')

STATUS_RAW=$($MYSQL_CMD --skip-column-names -e "
  SELECT COALESCE(status,'(null)'), COUNT(*)
  FROM fhir_diagnostic_report
  WHERE uuid IN (SELECT uuid FROM obs WHERE obs_group_id IS NULL AND order_id IS NOT NULL)
  GROUP BY status;" 2>/dev/null)

ELIGIBLE=${ELIGIBLE:-0}
MIGRATED=${MIGRATED:-0}
PENDING=${PENDING:-0}
WITH_RESULTS=${WITH_RESULTS:-0}
WITH_SR=${WITH_SR:-0}
WITH_ATTACH=${WITH_ATTACH:-0}
BATCH_CNT=${BATCH_CNT:-0}
LOG_ROWS=${LOG_ROWS:-0}

if [[ "$ELIGIBLE" -gt 0 ]]; then
    PCT=$(( MIGRATED * 100 / ELIGIBLE ))
else
    PCT=0
fi

# ─── Print summary ────────────────────────────────────────────────────────────
echo "  +-----------------------------------------------------------------+"
echo "  |  OBS SIDE                                                       |"
echo "  +-----------------------------------------------------------------+"
printf "  |  Eligible obs (obs_group_id IS NULL, order_id IS NOT NULL)     |\n"
printf "  |    Total eligible                : %-20s|\n" "$(fmt_num $ELIGIBLE)"
printf "  |    Already migrated              : %-20s|\n" "$(fmt_num $MIGRATED)"
printf "  |    Still pending                 : %-20s|\n" "$(fmt_num $PENDING)"
printf "  |    Coverage                      : %-20s|\n" "${PCT}%"
echo "  +-----------------------------------------------------------------+"
echo "  |  FHIR SIDE                                                      |"
echo "  +-----------------------------------------------------------------+"
printf "  |  fhir_diagnostic_report (migrated)   : %-20s|\n" "$(fmt_num $MIGRATED)"
printf "  |  fhir_diagnostic_report_results      : %-20s|\n" "$(fmt_num $WITH_RESULTS)"
printf "  |  fhir_diagnostic_report_service_req  : %-20s|\n" "$(fmt_num $WITH_SR)"
printf "  |  fhir_diagnostic_report_presented    : %-20s|\n" "$(fmt_num $WITH_ATTACH)"
echo "  +-----------------------------------------------------------------+"
echo "  |  BATCH LOG                                                      |"
echo "  +-----------------------------------------------------------------+"
printf "  |  Migration batches run           : %-20s|\n" "$(fmt_num $BATCH_CNT)"
printf "  |  Total log entries               : %-20s|\n" "$(fmt_num $LOG_ROWS)"
echo "  +-----------------------------------------------------------------+"

# Status breakdown
echo ""
echo "  fhir_diagnostic_report status breakdown (migrated obs only):"
echo "$STATUS_RAW" | while IFS=$'\t' read -r status cnt; do
    [[ -z "$status" ]] && continue
    printf "    %-20s : %s\n" "$status" "$cnt"
done

# ─── Data loss check ──────────────────────────────────────────────────────────
echo ""
if [[ "$PENDING" -eq 0 && "$ELIGIBLE" -gt 0 ]]; then
    echo "  ✓  COMPLETE — All $ELIGIBLE eligible obs have been migrated."
elif [[ "$PENDING" -gt 0 ]]; then
    echo "  ⚠  INCOMPLETE — $PENDING obs still pending migration."
    echo "     Run the migration script to process remaining rows."
else
    echo "  ℹ  No eligible obs found in this database."
fi
echo ""
