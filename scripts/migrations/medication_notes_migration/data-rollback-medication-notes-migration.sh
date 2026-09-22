#!/usr/bin/env bash
set -euo pipefail

# ─── Argument defaults ────────────────────────────────────────────────────────
DB_HOST="127.0.0.1"
DB_PORT="3306"
DB_USER=""
DB_PASS=""
DB_NAME=""
BATCH_ID=""
DOCKER_CONTAINER=""

# ─── Usage ────────────────────────────────────────────────────────────────────
usage() {
    echo ""
    echo "Usage (direct) : $0 -u <user> [-p <password>] -d <database> [-b <batch_id>] [-h <host>] [-P <port>]"
    echo "Usage (Docker) : $0 -u <user> [-p <password>] -d <database> [-b <batch_id>] -c <container>"
    echo ""
    echo "  -u  MySQL username        (required)"
    echo "  -p  MySQL password        (optional — prompted securely if not provided)"
    echo "  -d  Database name         (required)"
    echo "  -b  Batch ID to roll back (optional — lists available batches if omitted)"
    echo "  -h  Host                  (default: 127.0.0.1, direct mode only)"
    echo "  -P  Port                  (default: 3306,      direct mode only)"
    echo "  -c  Docker container name"
    echo ""
    echo "  Uses stop_order_notes_migration_log to identify exactly which"
    echo "  order_id/step rows a given migration run touched, then sets"
    echo "  comment_to_fulfiller back to NULL for only those rows. Since the"
    echo "  migration only ever writes comment_to_fulfiller when it was"
    echo "  previously NULL, NULL is always the correct restored value — no"
    echo "  full-table dump/restore is needed."
    echo ""
    exit 1
}

while getopts "h:P:u:p:d:b:c:" opt; do
    case $opt in
        h) DB_HOST="$OPTARG" ;;
        P) DB_PORT="$OPTARG" ;;
        u) DB_USER="$OPTARG" ;;
        p) DB_PASS="$OPTARG" ;;
        d) DB_NAME="$OPTARG" ;;
        b) BATCH_ID="$OPTARG" ;;
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

# ─── Build MySQL commands ─────────────────────────────────────────────────────
export MYSQL_PWD="$DB_PASS"
if [[ -n "$DOCKER_CONTAINER" ]]; then
    MYSQL_CMD=(docker exec -e MYSQL_PWD "$DOCKER_CONTAINER" mysql -u "$DB_USER" "$DB_NAME")
    MYSQL_PIPE_CMD=(docker exec -i -e MYSQL_PWD "$DOCKER_CONTAINER" mysql -u "$DB_USER" "$DB_NAME")
else
    MYSQL_CMD=(mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" "$DB_NAME")
    MYSQL_PIPE_CMD=(mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" "$DB_NAME")
fi

# ─── Single-instance lock ─────────────────────────────────────────────────────
LOCK_FILE="/tmp/stop_order_notes_migration_${DB_NAME}.lock"

if [[ -f "$LOCK_FILE" ]]; then
    OLD_PID=$(cat "$LOCK_FILE" 2>/dev/null || true)
    if [[ -n "$OLD_PID" ]] && kill -0 "$OLD_PID" 2>/dev/null; then
        echo ""
        echo "  ERROR: A migration or rollback is already running for database '$DB_NAME' (PID $OLD_PID)."
        echo "  Lock file : $LOCK_FILE"
        echo "  If you are certain no other run is active, remove the lock file and retry:"
        echo "    rm -f $LOCK_FILE"
        echo ""
        exit 1
    else
        echo "  WARNING: Removing stale lock file (PID ${OLD_PID:-unknown} is no longer active)."
        rm -f "$LOCK_FILE"
    fi
fi

echo $$ > "$LOCK_FILE"

on_exit() {
    rm -f "$LOCK_FILE" 2>/dev/null || true
}
trap on_exit EXIT

# ─── Early connectivity check ────────────────────────────────────────────────
CONN_TEST=$("${MYSQL_CMD[@]}" --skip-column-names -e "SELECT 1;" 2>&1) || true
if [[ "$CONN_TEST" != "1" ]]; then
    echo ""
    echo "  ERROR: Cannot connect to MySQL."
    echo "  $CONN_TEST"
    echo ""
    exit 1
fi

echo ""

# ─── Check that the migration log table exists ────────────────────────────────
LOG_TABLE_EXISTS=$("${MYSQL_CMD[@]}" --skip-column-names -e "
SELECT COUNT(*) FROM information_schema.tables
WHERE table_schema = DATABASE()
  AND table_name = 'stop_order_notes_migration_log';
" 2>&1)

if [[ "$LOG_TABLE_EXISTS" -eq 0 ]]; then
    echo "  ERROR: stop_order_notes_migration_log table does not exist."
    echo "  The migration script must have run at least once to create this table."
    echo ""
    exit 1
fi

# ─── If no batch_id supplied, list available batches and prompt ───────────────
if [[ -z "$BATCH_ID" ]]; then
    echo "  Available migration batches:"
    echo ""

    BATCH_LIST=$("${MYSQL_CMD[@]}" --skip-column-names -e "
    SELECT
        batch_id,
        COUNT(*)          AS rows_touched,
        MIN(migrated_at)  AS started_at,
        MAX(migrated_at)  AS finished_at
    FROM stop_order_notes_migration_log
    GROUP BY batch_id
    ORDER BY MIN(migrated_at) DESC;
    " 2>&1)

    if [[ -z "$BATCH_LIST" ]]; then
        echo "  No migration batches found in stop_order_notes_migration_log."
        echo "  Nothing to roll back."
        echo ""
        exit 0
    fi

    printf "  %-38s | %8s | %-20s | %-20s\n" "Batch ID" "Rows" "Started at" "Finished at"
    printf "  %s\n" "----------------------------------------------------------------------------------------"
    echo "$BATCH_LIST" | while IFS=$'\t' read -r bid cnt started finished; do
        printf "  %-38s | %8s | %-20s | %-20s\n" "$bid" "$cnt" "$started" "$finished"
    done
    echo ""

    read -r -p "  Enter batch ID to roll back: " BATCH_ID
    echo ""

    if [[ -z "$BATCH_ID" ]]; then
        echo "  No batch ID entered. Rollback aborted."
        echo ""
        exit 0
    fi
fi

# ─── Validate batch ID format (before any DB call — prevents SQL injection) ───
# Accepted formats:
#   UUID            — generated by SELECT UUID() in the migration script
#   batch_DATE_TIME — fallback when UUID() is unavailable
if ! [[ "$BATCH_ID" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ || \
        "$BATCH_ID" =~ ^batch_[0-9]{8}_[0-9]{6}$ ]]; then
    echo "  ERROR: Batch ID '$BATCH_ID' has an invalid format (${#BATCH_ID} chars)."
    echo "  Expected: UUID (36 chars)  e.g. 550e8400-e29b-41d4-a716-446655440000"
    echo "            or    batch_YYYYMMDD_HHMMSS   e.g. batch_20260825_103045"
    echo "  Tip: copy-paste directly from the batch list above to avoid typos."
    echo ""
    exit 1
fi

# ─── Validate the batch ID exists in the log ─────────────────────────────────
AFFECTED_COUNT=$("${MYSQL_CMD[@]}" --skip-column-names -e "
SELECT COUNT(*)
FROM stop_order_notes_migration_log
WHERE batch_id = '$BATCH_ID';
" 2>&1)

if [[ "$AFFECTED_COUNT" -eq 0 ]]; then
    echo "  ERROR: Batch ID '$BATCH_ID' not found in stop_order_notes_migration_log."
    echo "  Run without -b to list available batch IDs."
    echo ""
    exit 1
fi

STEP_BREAKDOWN=$("${MYSQL_CMD[@]}" --skip-column-names -e "
SELECT step, COUNT(*) FROM stop_order_notes_migration_log
WHERE batch_id = '$BATCH_ID' GROUP BY step;
" 2>&1)

# ─── Warning ──────────────────────────────────────────────────────────────────
echo "============================================================"
echo "  Rollback: batch $BATCH_ID"
echo "============================================================"
echo ""
echo "  This will set comment_to_fulfiller back to NULL for the"
echo "  $AFFECTED_COUNT order row(s) this batch touched:"
echo "$STEP_BREAKDOWN" | while IFS=$'\t' read -r step cnt; do
    [[ -z "$step" ]] && continue
    if [[ "$step" == "1" ]]; then
        printf "    step 1 (DISCONTINUE notes)  : %s\n" "$cnt"
    else
        printf "    step 2 (NEW/REVISE notes)   : %s\n" "$cnt"
    fi
done
echo ""
echo "  order_reason_non_coded and dosing_instructions were never modified"
echo "  by the migration and are not touched by this rollback."
echo ""
echo "  Rows touched by other batches, or by the application after"
echo "  migration, are identified by batch_id and will NOT be affected."
echo "============================================================"
echo ""

read -r -p "  Type 'YES' to confirm rollback of $AFFECTED_COUNT row(s): " CONFIRM
echo ""

if [[ "$CONFIRM" != "YES" ]]; then
    echo "  Rollback aborted by user. No data was modified."
    echo ""
    exit 0
fi

# ─── Execute rollback ─────────────────────────────────────────────────────────
echo "  Executing rollback for batch $BATCH_ID ..."
echo ""

set +e
ROLLBACK_OUTPUT=$("${MYSQL_PIPE_CMD[@]}" --skip-column-names 2>&1 <<ROLLBACKSQL
START TRANSACTION;

UPDATE orders o
JOIN stop_order_notes_migration_log log ON log.order_id = o.order_id
SET o.comment_to_fulfiller = NULL
WHERE log.batch_id = '$BATCH_ID';
SELECT ROW_COUNT();

DELETE FROM stop_order_notes_migration_log
WHERE batch_id = '$BATCH_ID';
SELECT ROW_COUNT();

COMMIT;
ROLLBACKSQL
)
ROLLBACK_EXIT=$?
set -e

if [[ $ROLLBACK_EXIT -ne 0 ]]; then
    echo "  ERROR: Rollback failed."
    echo "$ROLLBACK_OUTPUT"
    echo "  The transaction was rolled back — no data was modified."
    echo ""
    exit 1
fi

RESTORED_ROWS=$(echo "$ROLLBACK_OUTPUT" | grep -E '^[0-9]+$' | sed -n '1p')
DELETED_LOG=$(echo "$ROLLBACK_OUTPUT" | grep -E '^[0-9]+$' | sed -n '2p')
RESTORED_ROWS=${RESTORED_ROWS:-0}
DELETED_LOG=${DELETED_LOG:-0}

echo "  Rollback complete."
echo ""
echo "  ┌──────────────────────────────────────────────────────────────┐"
echo "  │  ROLLBACK SUMMARY                                            │"
echo "  ├──────────────────────────────────────────────────────────────┤"
printf "  │  Batch ID                             : %-22s│\n" "$BATCH_ID"
printf "  │  orders.comment_to_fulfiller reset    : %-22s│\n" "$RESTORED_ROWS"
printf "  │  Log entries removed                  : %-22s│\n" "$DELETED_LOG"
echo "  └──────────────────────────────────────────────────────────────┘"
echo ""
echo "  order_reason_non_coded and dosing_instructions were not modified."
echo ""
