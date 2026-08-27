#!/usr/bin/env bash
set -euo pipefail

# ─── Usage ────────────────────────────────────────────────────────────────────
usage() {
    echo ""
    echo "Usage (direct) : $0 -u <user> [-p <password>] -d <database> [-h <host>] [-P <port>]"
    echo "Usage (Docker) : $0 -u <user> [-p <password>] -d <database> -c <container>"
    echo ""
    echo "  Prints a before/after audit of legacy medication order notes vs"
    echo "  orders.comment_to_fulfiller. Run before migration to see what's"
    echo "  eligible, and again after to verify completeness."
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
echo "  BAH-4996: Legacy Medication Order Note Migration Audit"
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

# ─── Step 1: DISCONTINUE orders ────────────────────────────────────────────────
ELIGIBLE_1=$("${MYSQL_CMD[@]}" --skip-column-names -e "
  SELECT COUNT(*) FROM orders o
  INNER JOIN drug_order do ON do.order_id = o.order_id
  WHERE o.order_action = 'DISCONTINUE'
    AND o.order_reason_non_coded IS NOT NULL
    AND o.order_reason_non_coded != '';" 2>/dev/null | tr -d '[:space:]')

MIGRATED_1=$("${MYSQL_CMD[@]}" --skip-column-names -e "
  SELECT COUNT(*) FROM orders o
  INNER JOIN drug_order do ON do.order_id = o.order_id
  WHERE o.order_action = 'DISCONTINUE'
    AND o.order_reason_non_coded IS NOT NULL
    AND o.order_reason_non_coded != ''
    AND o.comment_to_fulfiller IS NOT NULL;" 2>/dev/null | tr -d '[:space:]')

# ─── Step 2: NEW/REVISE orders ─────────────────────────────────────────────────
ELIGIBLE_2=$("${MYSQL_CMD[@]}" --skip-column-names -e "
  SELECT COUNT(*) FROM orders o
  INNER JOIN drug_order do ON do.order_id = o.order_id
  WHERE o.order_action IN ('NEW', 'REVISE')
    AND do.dosing_instructions LIKE '%\"additionalInstructions\"%'
    AND JSON_EXTRACT(do.dosing_instructions, '\$.additionalInstructions') IS NOT NULL;" 2>/dev/null | tr -d '[:space:]')

MIGRATED_2=$("${MYSQL_CMD[@]}" --skip-column-names -e "
  SELECT COUNT(*) FROM orders o
  INNER JOIN drug_order do ON do.order_id = o.order_id
  WHERE o.order_action IN ('NEW', 'REVISE')
    AND do.dosing_instructions LIKE '%\"additionalInstructions\"%'
    AND JSON_EXTRACT(do.dosing_instructions, '\$.additionalInstructions') IS NOT NULL
    AND o.comment_to_fulfiller IS NOT NULL;" 2>/dev/null | tr -d '[:space:]')

# ─── Migration log (if the migration has run at least once) ──────────────────
LOG_TABLE_EXISTS=$("${MYSQL_CMD[@]}" --skip-column-names -e "
  SELECT COUNT(*) FROM information_schema.tables
  WHERE table_schema = DATABASE() AND table_name = 'stop_order_notes_migration_log';" 2>/dev/null | tr -d '[:space:]')

BATCH_CNT=0
LOG_ROWS=0
if [[ "$LOG_TABLE_EXISTS" -eq 1 ]]; then
    BATCH_CNT=$("${MYSQL_CMD[@]}" --skip-column-names -e "
      SELECT COUNT(DISTINCT batch_id) FROM stop_order_notes_migration_log;" 2>/dev/null | tr -d '[:space:]')
    LOG_ROWS=$("${MYSQL_CMD[@]}" --skip-column-names -e "
      SELECT COUNT(*) FROM stop_order_notes_migration_log;" 2>/dev/null | tr -d '[:space:]')
fi

ELIGIBLE_1=${ELIGIBLE_1:-0}; MIGRATED_1=${MIGRATED_1:-0}
ELIGIBLE_2=${ELIGIBLE_2:-0}; MIGRATED_2=${MIGRATED_2:-0}
PENDING_1=$(( ELIGIBLE_1 - MIGRATED_1 ))
PENDING_2=$(( ELIGIBLE_2 - MIGRATED_2 ))
TOTAL_ELIGIBLE=$(( ELIGIBLE_1 + ELIGIBLE_2 ))
TOTAL_MIGRATED=$(( MIGRATED_1 + MIGRATED_2 ))
TOTAL_PENDING=$(( PENDING_1 + PENDING_2 ))

if [[ "$TOTAL_ELIGIBLE" -gt 0 ]]; then
    PCT=$(( TOTAL_MIGRATED * 100 / TOTAL_ELIGIBLE ))
else
    PCT=0
fi

# ─── Print summary ────────────────────────────────────────────────────────────
echo "  +-----------------------------------------------------------------+"
echo "  |  STEP 1 — DISCONTINUE orders (order_reason_non_coded)          |"
echo "  +-----------------------------------------------------------------+"
printf "  |    Total eligible                : %-20s|\n" "$(fmt_num "$ELIGIBLE_1")"
printf "  |    Already migrated              : %-20s|\n" "$(fmt_num "$MIGRATED_1")"
printf "  |    Still pending                 : %-20s|\n" "$(fmt_num "$PENDING_1")"
echo "  +-----------------------------------------------------------------+"
echo "  |  STEP 2 — NEW/REVISE orders (dosing_instructions JSON)         |"
echo "  +-----------------------------------------------------------------+"
printf "  |    Total eligible                : %-20s|\n" "$(fmt_num "$ELIGIBLE_2")"
printf "  |    Already migrated              : %-20s|\n" "$(fmt_num "$MIGRATED_2")"
printf "  |    Still pending                 : %-20s|\n" "$(fmt_num "$PENDING_2")"
echo "  +-----------------------------------------------------------------+"
echo "  |  OVERALL                                                        |"
echo "  +-----------------------------------------------------------------+"
printf "  |    Total eligible                : %-20s|\n" "$(fmt_num "$TOTAL_ELIGIBLE")"
printf "  |    Already migrated              : %-20s|\n" "$(fmt_num "$TOTAL_MIGRATED")"
printf "  |    Still pending                 : %-20s|\n" "$(fmt_num "$TOTAL_PENDING")"
printf "  |    Coverage                      : %-20s|\n" "${PCT}%"
echo "  +-----------------------------------------------------------------+"
echo "  |  BATCH LOG (stop_order_notes_migration_log)                    |"
echo "  +-----------------------------------------------------------------+"
if [[ "$LOG_TABLE_EXISTS" -eq 1 ]]; then
    printf "  |    Migration batches run         : %-20s|\n" "$(fmt_num "$BATCH_CNT")"
    printf "  |    Total log entries             : %-20s|\n" "$(fmt_num "$LOG_ROWS")"
else
    printf "  |    %-62s|\n" "Table not found — migration has not run yet."
fi
echo "  +-----------------------------------------------------------------+"

# ─── Data loss / completeness check ───────────────────────────────────────────
echo ""
if [[ "$TOTAL_PENDING" -eq 0 && "$TOTAL_ELIGIBLE" -gt 0 ]]; then
    echo "  COMPLETE — All $(fmt_num "$TOTAL_ELIGIBLE") eligible drug order notes have been migrated."
elif [[ "$TOTAL_PENDING" -gt 0 ]]; then
    echo "  INCOMPLETE — $(fmt_num "$TOTAL_PENDING") drug order note(s) still pending migration."
    echo "  Run data-migrate-legacy-stop-notes.sh to process remaining rows."
else
    echo "  No eligible drug order notes found in this database."
fi
echo ""
