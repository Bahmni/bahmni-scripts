#!/usr/bin/env bash
set -euo pipefail

EMRAPI_SOURCE="org.openmrs.module.emrapi"
DISPOSITION_CODE="Disposition"

# ─── Usage ────────────────────────────────────────────────────────────────────
usage() {
    echo ""
    echo "Usage (direct) : $0 -u <user> [-p <password>] -d <database> [-h <host>] [-P <port>]"
    echo "Usage (Docker) : $0 -u <user> [-p <password>] -d <database> -c <container>"
    echo ""
    echo "  Prints a before/after audit of legacy disposition Observations vs"
    echo "  migrated ADT Order rows, broken down by disposition type. Run"
    echo "  before migration to see what's eligible, and again after to"
    echo "  verify completeness."
    echo ""
    exit 1
}

# ─── Argument defaults ────────────────────────────────────────────────────────
DB_HOST="127.0.0.1"
DB_PORT="3306"
DB_USER=""
DB_PASS=""
DB_NAME=""
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

export MYSQL_PWD="$DB_PASS"
if [[ -n "$DOCKER_CONTAINER" ]]; then
    MYSQL_CMD=(docker exec -e MYSQL_PWD "$DOCKER_CONTAINER" mysql -u "$DB_USER" "$DB_NAME")
else
    MYSQL_CMD=(mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" "$DB_NAME")
fi

# ─── Early connectivity check ─────────────────────────────────────────────────
CONN_TEST=$("${MYSQL_CMD[@]}" --skip-column-names -e "SELECT 1;" 2>&1) || true
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
echo "  BAH-5286: Legacy Disposition Migration Audit"
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

DISPOSITION_CONCEPT_ID=$("${MYSQL_CMD[@]}" --skip-column-names -e "
  SELECT crm.concept_id
  FROM concept_reference_map crm
  JOIN concept_reference_term crt ON crt.concept_reference_term_id = crm.concept_reference_term_id
  JOIN concept_reference_source crs ON crs.concept_source_id = crt.concept_source_id
  WHERE crs.name = '$EMRAPI_SOURCE' AND crt.code = '$DISPOSITION_CODE'
  LIMIT 1;" 2>/dev/null | tr -d '[:space:]')

if [[ -z "$DISPOSITION_CONCEPT_ID" ]]; then
    echo "  No concept mapped to emrapi code '$DISPOSITION_CODE' — nothing to audit."
    echo "  (Is the emrapi Disposition concept set installed on this database?)"
    echo ""
    exit 0
fi

LOG_TABLE_EXISTS=$("${MYSQL_CMD[@]}" --skip-column-names -e "
  SELECT COUNT(*) FROM information_schema.tables
  WHERE table_schema = DATABASE() AND table_name = 'legacy_disposition_migration_log';" 2>/dev/null | tr -d '[:space:]')

# ─── Overall counts ─────────────────────────────────────────────────────────
TOTAL_ELIGIBLE=$("${MYSQL_CMD[@]}" --skip-column-names -e "
  SELECT COUNT(*) FROM obs d
  WHERE d.concept_id = $DISPOSITION_CONCEPT_ID AND d.voided = 0 AND d.value_coded IS NOT NULL;" 2>/dev/null | tr -d '[:space:]')

VOIDED_SKIPPED=$("${MYSQL_CMD[@]}" --skip-column-names -e "
  SELECT COUNT(*) FROM obs d WHERE d.concept_id = $DISPOSITION_CONCEPT_ID AND d.voided = 1;" 2>/dev/null | tr -d '[:space:]')

TOTAL_ELIGIBLE=${TOTAL_ELIGIBLE:-0}
VOIDED_SKIPPED=${VOIDED_SKIPPED:-0}

BATCH_CNT=0
TOTAL_MIGRATED=0
if [[ "$LOG_TABLE_EXISTS" -eq 1 ]]; then
    BATCH_CNT=$("${MYSQL_CMD[@]}" --skip-column-names -e "
      SELECT COUNT(DISTINCT batch_id) FROM legacy_disposition_migration_log;" 2>/dev/null | tr -d '[:space:]')
    TOTAL_MIGRATED=$("${MYSQL_CMD[@]}" --skip-column-names -e "
      SELECT COUNT(*) FROM legacy_disposition_migration_log;" 2>/dev/null | tr -d '[:space:]')
fi
BATCH_CNT=${BATCH_CNT:-0}
TOTAL_MIGRATED=${TOTAL_MIGRATED:-0}
TOTAL_PENDING=$(( TOTAL_ELIGIBLE - TOTAL_MIGRATED ))

if [[ "$TOTAL_ELIGIBLE" -gt 0 ]]; then
    PCT=$(( TOTAL_MIGRATED * 100 / TOTAL_ELIGIBLE ))
else
    PCT=0
fi

# ─── Per disposition-type breakdown ─────────────────────────────────────────
# $1 = emrapi reference-term code of the answer concept
type_counts() {
    local code="$1"
    local eligible migrated
    eligible=$("${MYSQL_CMD[@]}" --skip-column-names -e "
      SELECT COUNT(*)
      FROM obs d
      JOIN concept_reference_map crm ON crm.concept_id = d.value_coded
      JOIN concept_reference_term crt ON crt.concept_reference_term_id = crm.concept_reference_term_id
      JOIN concept_reference_source crs ON crs.concept_source_id = crt.concept_source_id
      WHERE d.concept_id = $DISPOSITION_CONCEPT_ID
        AND d.voided = 0
        AND crs.name = '$EMRAPI_SOURCE'
        AND crt.code = '$code';" 2>/dev/null | tr -d '[:space:]')
    eligible=${eligible:-0}
    if [[ "$LOG_TABLE_EXISTS" -eq 1 ]]; then
        migrated=$("${MYSQL_CMD[@]}" --skip-column-names -e "
          SELECT COUNT(*)
          FROM obs d
          JOIN concept_reference_map crm ON crm.concept_id = d.value_coded
          JOIN concept_reference_term crt ON crt.concept_reference_term_id = crm.concept_reference_term_id
          JOIN concept_reference_source crs ON crs.concept_source_id = crt.concept_source_id
          JOIN legacy_disposition_migration_log log ON log.source_obs_id = d.obs_id
          WHERE d.concept_id = $DISPOSITION_CONCEPT_ID
            AND d.voided = 0
            AND crs.name = '$EMRAPI_SOURCE'
            AND crt.code = '$code';" 2>/dev/null | tr -d '[:space:]')
    else
        migrated=0
    fi
    migrated=${migrated:-0}
    printf "%s\t%s" "$eligible" "$migrated"
}

echo "  +-----------------------------------------------------------------+"
echo "  |  BY DISPOSITION TYPE                                            |"
echo "  +-----------------------------------------------------------------+"
printf "  |  %-16s | %10s | %10s | %10s |\n" "Type" "Eligible" "Migrated" "Pending"
echo "  +-----------------------------------------------------------------+"
for pair in "Admit:ADMIT" "Discharge:DISCHARGE" "Transfer:TRANSFER" "Undo Discharge:UNDO_DISCHARGE"; do
    LABEL="${pair%%:*}"
    CODE="${pair##*:}"
    COUNTS=$(type_counts "$CODE")
    ELIG=$(echo "$COUNTS" | cut -f1)
    MIG=$(echo "$COUNTS" | cut -f2)
    PEND=$(( ELIG - MIG ))
    printf "  |  %-16s | %10s | %10s | %10s |\n" "$LABEL" "$(fmt_num "$ELIG")" "$(fmt_num "$MIG")" "$(fmt_num "$PEND")"
done
echo "  +-----------------------------------------------------------------+"
echo ""

# ─── Overall summary ─────────────────────────────────────────────────────────
echo "  +-----------------------------------------------------------------+"
echo "  |  OVERALL                                                        |"
echo "  +-----------------------------------------------------------------+"
printf "  |    Total eligible (non-voided)   : %-20s|\n" "$(fmt_num "$TOTAL_ELIGIBLE")"
printf "  |    Voided (always skipped)       : %-20s|\n" "$(fmt_num "$VOIDED_SKIPPED")"
printf "  |    Already migrated              : %-20s|\n" "$(fmt_num "$TOTAL_MIGRATED")"
printf "  |    Still pending                 : %-20s|\n" "$(fmt_num "$TOTAL_PENDING")"
printf "  |    Coverage                      : %-20s|\n" "${PCT}%"
echo "  +-----------------------------------------------------------------+"
echo "  |  BATCH LOG (legacy_disposition_migration_log)                  |"
echo "  +-----------------------------------------------------------------+"
if [[ "$LOG_TABLE_EXISTS" -eq 1 ]]; then
    printf "  |    Migration batches run         : %-20s|\n" "$(fmt_num "$BATCH_CNT")"
    printf "  |    Total orders created          : %-20s|\n" "$(fmt_num "$TOTAL_MIGRATED")"
    COMPLETED_COUNT=$("${MYSQL_CMD[@]}" --skip-column-names -e "
      SELECT COUNT(*) FROM orders o
      JOIN legacy_disposition_migration_log log ON log.migrated_order_id = o.order_id
      WHERE o.fulfiller_status = 'COMPLETED';" 2>/dev/null | tr -d '[:space:]')
    COMPLETED_COUNT=${COMPLETED_COUNT:-0}
    OPEN_COUNT=$(( TOTAL_MIGRATED - COMPLETED_COUNT ))
    printf "  |      ...with fulfiller_status COMPLETED : %-13s|\n" "$(fmt_num "$COMPLETED_COUNT")"
    printf "  |      ...still open (fulfiller_status NULL) : %-9s|\n" "$(fmt_num "$OPEN_COUNT")"
else
    printf "  |    %-62s|\n" "Table not found — migration has not run yet."
fi
echo "  +-----------------------------------------------------------------+"

# ─── Data loss / completeness check ───────────────────────────────────────────
echo ""
if [[ "$TOTAL_PENDING" -eq 0 && "$TOTAL_ELIGIBLE" -gt 0 ]]; then
    echo "  COMPLETE — All $(fmt_num "$TOTAL_ELIGIBLE") eligible legacy dispositions have been migrated."
elif [[ "$TOTAL_PENDING" -gt 0 ]]; then
    echo "  INCOMPLETE — $(fmt_num "$TOTAL_PENDING") legacy disposition(s) still pending migration."
    echo "  Run data-migrate-legacy-disposition-migration.sh to process remaining rows."
else
    echo "  No eligible legacy disposition observations found in this database."
fi
echo ""
