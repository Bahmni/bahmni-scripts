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
    echo "  Uses legacy_disposition_migration_log to identify exactly which"
    echo "  orders a given migration run created, then deletes those orders"
    echo "  rows and their log entries. Since the migration only ever INSERTs"
    echo "  new orders rows (never updates existing ones) and never touches"
    echo "  obs, deleting the logged order_ids fully and safely undoes a batch."
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
LOCK_FILE="/tmp/legacy_disposition_migration_${DB_NAME}.lock"

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
  AND table_name = 'legacy_disposition_migration_log';
" 2>&1)

if [[ "$LOG_TABLE_EXISTS" -eq 0 ]]; then
    echo "  ERROR: legacy_disposition_migration_log table does not exist."
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
        COUNT(*)          AS orders_created,
        MIN(migrated_at)  AS started_at,
        MAX(migrated_at)  AS finished_at
    FROM legacy_disposition_migration_log
    GROUP BY batch_id
    ORDER BY MIN(migrated_at) DESC;
    " 2>&1)

    if [[ -z "$BATCH_LIST" ]]; then
        echo "  No migration batches found in legacy_disposition_migration_log."
        echo "  Nothing to roll back."
        echo ""
        exit 0
    fi

    printf "  %-38s | %8s | %-20s | %-20s\n" "Batch ID" "Orders" "Started at" "Finished at"
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
FROM legacy_disposition_migration_log
WHERE batch_id = '$BATCH_ID';
" 2>&1)

if [[ "$AFFECTED_COUNT" -eq 0 ]]; then
    echo "  ERROR: Batch ID '$BATCH_ID' not found in legacy_disposition_migration_log."
    echo "  Run without -b to list available batch IDs."
    echo ""
    exit 1
fi

# ─── Warn if any of this batch's orders were touched after migration ─────────
# A clean rollback assumes nothing downstream has since referenced the
# migrated orders (e.g. a disposition note edited via the app, or another
# order superseding/discontinuing a migrated one). This is a best-effort
# warning, not a hard block — a migrated order being voided after the fact is
# expected and still safe to delete.
MODIFIED_SINCE=$("${MYSQL_CMD[@]}" --skip-column-names -e "
SELECT COUNT(*)
FROM orders o
JOIN legacy_disposition_migration_log log ON log.migrated_order_id = o.order_id
WHERE log.batch_id = '$BATCH_ID'
  AND o.previous_order_id IS NOT NULL;
" 2>&1)

# ─── Warning ──────────────────────────────────────────────────────────────────
echo "============================================================"
echo "  Rollback: batch $BATCH_ID"
echo "============================================================"
echo ""
echo "  This will permanently DELETE the $AFFECTED_COUNT order(s) this batch"
echo "  created, and their entries in legacy_disposition_migration_log."
echo ""
if [[ "${MODIFIED_SINCE:-0}" -gt 0 ]]; then
    echo "  WARNING: $MODIFIED_SINCE of these order(s) have a later order"
    echo "  referencing them as a previous_order (e.g. a discontinuation)."
    echo "  Deleting them may leave that later order's previous_order_id"
    echo "  dangling. Review before proceeding if this batch is not recent."
    echo ""
fi
echo "  Source Observations were never touched by the migration and are"
echo "  NOT touched by this rollback."
echo ""
echo "  Orders created by other batches, or placed by the application after"
echo "  migration, are identified by batch_id and will NOT be affected."
echo "============================================================"
echo ""

read -r -p "  Type 'YES' to confirm rollback of $AFFECTED_COUNT order(s): " CONFIRM
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

DELETE o FROM orders o
JOIN legacy_disposition_migration_log log ON log.migrated_order_id = o.order_id
WHERE log.batch_id = '$BATCH_ID';
SELECT ROW_COUNT();

DELETE FROM legacy_disposition_migration_log
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

DELETED_ORDERS=$(echo "$ROLLBACK_OUTPUT" | grep -E '^[0-9]+$' | sed -n '1p')
DELETED_LOG=$(echo "$ROLLBACK_OUTPUT" | grep -E '^[0-9]+$' | sed -n '2p')
DELETED_ORDERS=${DELETED_ORDERS:-0}
DELETED_LOG=${DELETED_LOG:-0}

echo "  Rollback complete."
echo ""
echo "  ┌──────────────────────────────────────────────────────────────┐"
echo "  │  ROLLBACK SUMMARY                                            │"
echo "  ├──────────────────────────────────────────────────────────────┤"
printf "  │  Batch ID                             : %-22s│\n" "$BATCH_ID"
printf "  │  orders rows deleted                  : %-22s│\n" "$DELETED_ORDERS"
printf "  │  Log entries removed                  : %-22s│\n" "$DELETED_LOG"
echo "  └──────────────────────────────────────────────────────────────┘"
echo ""
echo "  Source Observations were not modified."
echo ""
