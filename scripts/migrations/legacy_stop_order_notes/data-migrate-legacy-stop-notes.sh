#!/usr/bin/env bash
set -euo pipefail

# ─── Constants ────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Argument defaults ────────────────────────────────────────────────────────
DB_HOST="127.0.0.1"
DB_PORT="3306"
DB_USER=""
DB_PASS=""
DB_NAME=""
DOCKER_CONTAINER=""
CHUNK_SIZE="5000"

# ─── Usage ────────────────────────────────────────────────────────────────────
usage() {
    echo ""
    echo "Usage: $0 [-h host] [-P port] [-u user] [-p pass] [-d dbname] [-c container] [-s chunk_size]"
    echo ""
    echo "  Fully interactive — prompts for any missing required inputs."
    echo ""
    echo "  Migrates legacy medication order notes (order_reason_non_coded and"
    echo "  dosing_instructions additionalInstructions) into orders.comment_to_fulfiller,"
    echo "  scoped strictly to Drug Orders (INNER JOIN drug_order)."
    echo ""
    echo "  -s chunk_size : rows processed per order_id-range chunk/transaction"
    echo "                  (default: 5000, must be a positive integer)"
    echo ""
    echo "  This script does not own backup logic — data-backup-legacy-stop-notes.sh"
    echo "  does. It will optionally offer to run that script for you before migrating."
    echo ""
    exit 1
}

while getopts "h:P:u:p:d:c:s:" opt; do
    case $opt in
        h) DB_HOST="$OPTARG" ;;
        P) DB_PORT="$OPTARG" ;;
        u) DB_USER="$OPTARG" ;;
        p) DB_PASS="$OPTARG" ;;
        d) DB_NAME="$OPTARG" ;;
        c) DOCKER_CONTAINER="$OPTARG" ;;
        s) CHUNK_SIZE="$OPTARG" ;;
        *) usage ;;
    esac
done

if ! [[ "$CHUNK_SIZE" =~ ^[0-9]+$ ]] || [[ "$CHUNK_SIZE" -le 0 ]]; then
    echo ""
    echo "  ERROR: -s chunk_size must be a positive integer (got: '$CHUNK_SIZE')."
    echo ""
    exit 1
fi

# ─── Interactive prompts ──────────────────────────────────────────────────────
if [[ -z "$DOCKER_CONTAINER" ]]; then
    read -r -p "  Docker container name (leave blank for direct connection): " DOCKER_CONTAINER
    echo ""
fi

if [[ -z "$DB_USER" ]]; then
    read -r -p "  Enter MySQL username  : " DB_USER
    echo ""
fi

if [[ -z "$DB_USER" ]]; then
    echo "  ERROR: MySQL username is required."
    echo ""
    exit 1
fi

if [[ -z "$DB_NAME" ]]; then
    read -r -p "  Enter database name   : " DB_NAME
    echo ""
fi

if [[ -z "$DB_NAME" ]]; then
    echo "  ERROR: Database name is required."
    echo ""
    exit 1
fi

if [[ -z "$DB_PASS" ]]; then
    read -r -s -p "  Enter password for $DB_USER: " DB_PASS
    echo ""
    echo ""
fi

# ─── Build MySQL commands ─────────────────────────────────────────────────────
# Use bash arrays to prevent word-splitting on passwords with special characters.
# Pass the password via MYSQL_PWD env var so it does not appear in process args.
export MYSQL_PWD="$DB_PASS"
if [[ -n "$DOCKER_CONTAINER" ]]; then
    # -e MYSQL_PWD (no =value) forwards the already-exported env var into the container
    MYSQL_CMD=(docker exec -e MYSQL_PWD "$DOCKER_CONTAINER" mysql -u "$DB_USER" "$DB_NAME")
    MYSQL_PIPE_CMD=(docker exec -i -e MYSQL_PWD "$DOCKER_CONTAINER" mysql -u "$DB_USER" "$DB_NAME")
else
    MYSQL_CMD=(mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" "$DB_NAME")
    MYSQL_PIPE_CMD=(mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" "$DB_NAME")
fi

# ─── Single-instance lock ─────────────────────────────────────────────────────
# Prevents two simultaneous runs from colliding on the same orders/drug_order rows.
# Uses a PID file instead of flock so it works on macOS (bash 3.2) and Linux.
# Scoped to the target database — parallel runs against different DBs are fine.
LOCK_FILE="/tmp/stop_order_notes_migration_${DB_NAME}.lock"

if [[ -f "$LOCK_FILE" ]]; then
    OLD_PID=$(cat "$LOCK_FILE" 2>/dev/null || true)
    if [[ -n "$OLD_PID" ]] && kill -0 "$OLD_PID" 2>/dev/null; then
        echo ""
        echo "  ERROR: Another migration is already running for database '$DB_NAME' (PID $OLD_PID)."
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

# ─── Early connectivity check — fail fast before any work starts ─────────────
CONN_TEST=$("${MYSQL_CMD[@]}" --skip-column-names -e "SELECT 1;" 2>&1) || true
if [[ "$CONN_TEST" != "1" ]]; then
    echo ""
    echo "  ERROR: Cannot connect to MySQL."
    echo "  $CONN_TEST"
    echo ""
    rm -f "$LOCK_FILE"
    exit 1
fi

# ─── Log file / checkpoint file ────────────────────────────────────────────────
# One log file per day — all runs (success and failure) append to the same file.
LOG_FILE="$SCRIPT_DIR/migration_BAH-4996_$(date +%Y%m%d).log"
CHECKPOINT_FILE="$SCRIPT_DIR/stop_notes_checkpoint_${DB_NAME}.txt"
THIS_RUN_HAD_ERRORS=false

# ─── Helper functions ─────────────────────────────────────────────────────────
format_duration() {
    local secs=$1
    printf "%02dh %02dm %02ds" $(( secs / 3600 )) $(( (secs % 3600) / 60 )) $(( secs % 60 ))
}

fmt_num() {
    printf "%'d" "$1"
}

STDERR_TMP=$(mktemp /tmp/stop_order_notes_migration_stderr.XXXXXX)

flush_stderr() {
    if [[ -s "$STDERR_TMP" ]]; then
        if [[ "$THIS_RUN_HAD_ERRORS" == "false" ]]; then
            THIS_RUN_HAD_ERRORS=true
            echo "" >> "$LOG_FILE"
            echo "══ Run: $(date '+%Y-%m-%d %H:%M:%S') ══" >> "$LOG_FILE"
        fi
        cat "$STDERR_TMP" >> "$LOG_FILE"
    fi
    : > "$STDERR_TMP"
}

# EXIT trap — flush any pending stderr, then clean up
on_exit() {
    flush_stderr                    # promote any captured errors to log file
    rm -f "$STDERR_TMP"              # clean up temp file
    rm -f "$LOCK_FILE" 2>/dev/null || true
}
trap on_exit EXIT

log() {
    printf "  %s  INFO   %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$1"
}

log_error() {
    if [[ "$THIS_RUN_HAD_ERRORS" == "false" ]]; then
        THIS_RUN_HAD_ERRORS=true
        echo "" >> "$LOG_FILE"
        echo "══ Run: $(date '+%Y-%m-%d %H:%M:%S') ══" >> "$LOG_FILE"
    fi
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    printf "  %s  ERROR  %s\n" "$ts" "$1" | tee -a "$LOG_FILE"
}

# ─── Header ───────────────────────────────────────────────────────────────────
echo ""
echo "============================================================"
echo "  BAH-4996: Legacy Medication Order Note Migration"
echo "============================================================"
echo ""
echo "  Migrates legacy Drug Order notes into orders.comment_to_fulfiller:"
echo "    1. DISCONTINUE orders — order_reason_non_coded -> comment_to_fulfiller"
echo "    2. NEW/REVISE orders   — dosing_instructions.additionalInstructions"
echo "                             (JSON) -> comment_to_fulfiller"
echo ""
echo "  - SCOPE      : Drug Orders only (INNER JOIN drug_order ON order_id)"
echo "  - MODE       : Full (all pending) or Batch (specify an order_id range)"
echo "  - CHUNKED    : processed in order_id-range chunks of $(fmt_num "$CHUNK_SIZE"), one transaction per chunk"
echo "  - IDEMPOTENT : comment_to_fulfiller IS NULL guards; re-running updates 0 rows"
echo "  - READ-ONLY  : dosing_instructions and order_reason_non_coded are only ever read, never modified"
echo "  - BATCH LOG  : each run tags a batch ID; roll back with data-rollback-legacy-stop-notes.sh -b <batch_id>"
echo ""
if [[ -n "$DOCKER_CONTAINER" ]]; then
    echo "  Mode    : Docker ($DOCKER_CONTAINER)"
else
    echo "  Mode    : Direct ($DB_HOST:$DB_PORT)"
fi
echo "  Database: $DB_NAME"
echo "  Log file: $LOG_FILE"
echo "============================================================"
echo ""

log "Migration started"

# ─── Migration log table ──────────────────────────────────────────────────────
# One row per (batch_id, order_id, step) actually updated. Since both UPDATEs
# are guarded by comment_to_fulfiller IS NULL, the "old" value is always NULL —
# so rollback only needs to know WHICH rows a batch touched, not what to
# restore them to. This enables the rollback script to undo a single batch
# surgically instead of a full-table mysqldump restore.
log "Creating stop_order_notes_migration_log table if not exists..."
"${MYSQL_PIPE_CMD[@]}" 2>"$STDERR_TMP" <<'INITSQL'
CREATE TABLE IF NOT EXISTS stop_order_notes_migration_log (
    id          INT AUTO_INCREMENT PRIMARY KEY,
    batch_id    VARCHAR(36) NOT NULL,
    order_id    INT         NOT NULL,
    step        TINYINT     NOT NULL,
    migrated_at DATETIME    NOT NULL,
    UNIQUE KEY uk_batch_order_step (batch_id, order_id, step),
    INDEX idx_batch_id (batch_id)
);
INITSQL
flush_stderr

# ─── Shared pending-row predicates (reused for dry-run, range detection, chunks) ─
# $1 = order_id range condition (e.g. "o.order_id BETWEEN 1 AND 100", or "1=1" for no range filter)
dc_pending_predicate() {
    local range="$1"
    cat <<SQL
(
  SELECT COUNT(*)
  FROM orders o
  INNER JOIN drug_order do ON do.order_id = o.order_id
  WHERE o.order_action = 'DISCONTINUE'
    AND o.order_reason_non_coded IS NOT NULL
    AND o.order_reason_non_coded != ''
    AND o.comment_to_fulfiller IS NULL
    AND $range
)
SQL
}

new_revise_pending_predicate() {
    local range="$1"
    cat <<SQL
(
  SELECT COUNT(*)
  FROM orders o
  INNER JOIN drug_order do ON do.order_id = o.order_id
  WHERE o.order_action IN ('NEW', 'REVISE')
    AND do.dosing_instructions LIKE '%"additionalInstructions"%'
    AND JSON_EXTRACT(do.dosing_instructions, '\$.additionalInstructions') IS NOT NULL
    AND o.comment_to_fulfiller IS NULL
    AND $range
)
SQL
}

# ─── Dry-run counts (whole table, no range filter) ────────────────────────────
echo "  Counting records pending migration..."
echo ""

DC_PENDING_COUNT=$("${MYSQL_PIPE_CMD[@]}" --skip-column-names 2>"$STDERR_TMP" <<EOF
SELECT $(dc_pending_predicate "1=1");
EOF
)
flush_stderr

NEW_PENDING_COUNT=$("${MYSQL_PIPE_CMD[@]}" --skip-column-names 2>"$STDERR_TMP" <<EOF
SELECT $(new_revise_pending_predicate "1=1");
EOF
)
flush_stderr

echo "  Step 1 - DISCONTINUE orders pending (order_reason_non_coded -> comment_to_fulfiller) : $(fmt_num "$DC_PENDING_COUNT")"
echo "  Step 2 - NEW/REVISE orders pending (dosing_instructions JSON -> comment_to_fulfiller): $(fmt_num "$NEW_PENDING_COUNT")"
echo ""

if [[ "$DC_PENDING_COUNT" -eq 0 && "$NEW_PENDING_COUNT" -eq 0 ]]; then
    log "Nothing to migrate. All records are already up to date."
    exit 0
fi

# ─── Full pending order_id range (used for Full mode + shown as a hint in Batch mode) ─
FULL_RANGE_ROW=$("${MYSQL_PIPE_CMD[@]}" --skip-column-names 2>"$STDERR_TMP" <<EOF
SELECT MIN(order_id), MAX(order_id) FROM (
  SELECT o.order_id
  FROM orders o
  INNER JOIN drug_order do ON do.order_id = o.order_id
  WHERE o.order_action = 'DISCONTINUE'
    AND o.order_reason_non_coded IS NOT NULL
    AND o.order_reason_non_coded != ''
    AND o.comment_to_fulfiller IS NULL
  UNION
  SELECT o.order_id
  FROM orders o
  INNER JOIN drug_order do ON do.order_id = o.order_id
  WHERE o.order_action IN ('NEW', 'REVISE')
    AND do.dosing_instructions LIKE '%"additionalInstructions"%'
    AND JSON_EXTRACT(do.dosing_instructions, '\$.additionalInstructions') IS NOT NULL
    AND o.comment_to_fulfiller IS NULL
) pending;
EOF
)
flush_stderr
FULL_MIN_ORDER_ID=$(echo "$FULL_RANGE_ROW" | awk '{print $1}')
FULL_MAX_ORDER_ID=$(echo "$FULL_RANGE_ROW" | awk '{print $2}')

if [[ -z "$FULL_MIN_ORDER_ID" || "$FULL_MIN_ORDER_ID" == "NULL" ]]; then
    log "Nothing to migrate. All records are already up to date."
    exit 0
fi

# ─── Checkpoint detection ──────────────────────────────────────────────────────
# A checkpoint (if resumed) carries its own batch_id and order_id range so a
# resumed run keeps logging to the same batch and the same bounds as before.
BATCH_ID=""
MIN_ORDER_ID=""
MAX_ORDER_ID=""
START_ORDER_ID=""
RESUMED=false

if [[ -f "$CHECKPOINT_FILE" ]]; then
    CP_LAST=$(grep 'Last completed chunk end order_id' "$CHECKPOINT_FILE" | grep -oE '[0-9]+$' || true)
    CP_BATCH=$(grep 'Batch ID' "$CHECKPOINT_FILE" | sed 's/Batch ID - //' || true)
    CP_MIN=$(grep 'Range Min' "$CHECKPOINT_FILE" | grep -oE '[0-9]+$' || true)
    CP_MAX=$(grep 'Range Max' "$CHECKPOINT_FILE" | grep -oE '[0-9]+$' || true)

    if [[ -n "$CP_LAST" && -n "$CP_BATCH" && -n "$CP_MIN" && -n "$CP_MAX" ]]; then
        echo "  Checkpoint found — last completed chunk ended at order_id $(fmt_num "$CP_LAST")."
        echo "  Batch ID in checkpoint : $CP_BATCH"
        echo "  Range in checkpoint    : $(fmt_num "$CP_MIN") - $(fmt_num "$CP_MAX")"
        read -r -p "  Resume from checkpoint? [yes/no]: " RESUME_CONFIRM
        echo ""
        if [[ "$RESUME_CONFIRM" == "yes" ]]; then
            BATCH_ID="$CP_BATCH"
            MIN_ORDER_ID="$CP_MIN"
            MAX_ORDER_ID="$CP_MAX"
            START_ORDER_ID=$(( CP_LAST + 1 ))
            RESUMED=true
            if [[ "$START_ORDER_ID" -gt "$MAX_ORDER_ID" ]]; then
                log "Checkpoint is already past its range. Nothing left to resume."
                rm -f "$CHECKPOINT_FILE"
                exit 0
            fi
            log "Resuming batch $BATCH_ID from order_id $(fmt_num "$START_ORDER_ID")"
        else
            echo "  Starting a fresh run (checkpoint discarded)."
            echo ""
            rm -f "$CHECKPOINT_FILE"
        fi
    else
        echo "  WARNING: Checkpoint file exists but is incomplete/unreadable. Starting fresh."
        echo ""
        rm -f "$CHECKPOINT_FILE"
    fi
fi

# ─── Full vs Batch mode selection (skipped when resuming) ─────────────────────
if [[ "$RESUMED" == "false" ]]; then
    echo "  Select migration type:"
    echo "    1. Full migration  — migrate all pending rows"
    echo "    2. Batch migration — specify an order_id range"
    echo ""
    read -r -p "  Enter choice [1/2]: " MIGRATION_TYPE
    echo ""

    if [[ "$MIGRATION_TYPE" == "2" ]]; then
        echo "  Available pending order_id range : $(fmt_num "$FULL_MIN_ORDER_ID") - $(fmt_num "$FULL_MAX_ORDER_ID")"
        echo ""
        read -r -p "  Enter start order_id : " MIN_ORDER_ID
        read -r -p "  Enter end order_id   : " MAX_ORDER_ID
        echo ""

        if ! [[ "$MIN_ORDER_ID" =~ ^[0-9]+$ && "$MAX_ORDER_ID" =~ ^[0-9]+$ ]]; then
            echo "  ERROR: order_id values must be numeric and valid."
            echo ""
            exit 1
        fi

        if [[ "$MIN_ORDER_ID" -gt "$MAX_ORDER_ID" ]]; then
            echo "  ERROR: start order_id must be <= end order_id."
            echo ""
            exit 1
        fi

        log "Batch mode: order_id $(fmt_num "$MIN_ORDER_ID") -> $(fmt_num "$MAX_ORDER_ID")"
    elif [[ "$MIGRATION_TYPE" == "1" ]]; then
        MIN_ORDER_ID="$FULL_MIN_ORDER_ID"
        MAX_ORDER_ID="$FULL_MAX_ORDER_ID"
        log "Full mode: pending order_id range $(fmt_num "$MIN_ORDER_ID") -> $(fmt_num "$MAX_ORDER_ID")"
    else
        echo "  ERROR: Invalid choice. Enter 1 or 2."
        echo ""
        exit 1
    fi

    START_ORDER_ID="$MIN_ORDER_ID"

    # Fresh batch ID for this run (not resuming).
    BATCH_ID=$("${MYSQL_PIPE_CMD[@]}" --skip-column-names 2>/dev/null <<<"SELECT UUID();" | tr -d '[:space:]')
    if [[ -z "$BATCH_ID" ]]; then
        BATCH_ID="batch_$(date +%Y%m%d_%H%M%S)"
    fi
fi

# ─── Scoped dry-run count for the chosen range ────────────────────────────────
RANGE_DRY_RUN_COUNT=$("${MYSQL_PIPE_CMD[@]}" --skip-column-names 2>"$STDERR_TMP" <<EOF
SELECT $(dc_pending_predicate "o.order_id BETWEEN $MIN_ORDER_ID AND $MAX_ORDER_ID")
     + $(new_revise_pending_predicate "o.order_id BETWEEN $MIN_ORDER_ID AND $MAX_ORDER_ID");
EOF
)
flush_stderr

if [[ "$RANGE_DRY_RUN_COUNT" -eq 0 && "$RESUMED" == "false" ]]; then
    log "Nothing to migrate in order_id range $MIN_ORDER_ID - $MAX_ORDER_ID."
    exit 0
fi

TOTAL_CHUNKS=$(( (MAX_ORDER_ID - START_ORDER_ID) / CHUNK_SIZE + 1 ))

echo "  Order_id range          : $(fmt_num "$START_ORDER_ID") - $(fmt_num "$MAX_ORDER_ID")"
echo "  Rows pending in range    : $(fmt_num "$RANGE_DRY_RUN_COUNT")"
echo "  Chunk size              : $(fmt_num "$CHUNK_SIZE")"
echo "  Estimated chunks        : $(fmt_num "$TOTAL_CHUNKS")"
echo "  Batch ID                : $BATCH_ID"
echo ""

# ─── Confirm ──────────────────────────────────────────────────────────────────
read -r -p "  Proceed with migration? [yes/no]: " CONFIRM
echo ""

if [[ "$CONFIRM" != "yes" ]]; then
    log "Migration cancelled by user."
    exit 0
fi

# ─── Optional backup ──────────────────────────────────────────────────────────
# This script does not take its own backup — data-backup-legacy-stop-notes.sh
# owns that logic (single source of truth, matches the other migrations'
# convention of a standalone backup script). It can optionally be invoked here
# for convenience, using the same connection details already gathered above.
BACKUP_SCRIPT="$SCRIPT_DIR/data-backup-legacy-stop-notes.sh"
BACKUP_FILE=""

if [[ -x "$BACKUP_SCRIPT" ]]; then
    read -r -p "  Run data-backup-legacy-stop-notes.sh now before migrating? [yes/no]: " RUN_BACKUP
    echo ""
    if [[ "$RUN_BACKUP" == "yes" ]]; then
        BACKUP_ARGS=(-u "$DB_USER" -p "$DB_PASS" -d "$DB_NAME")
        if [[ -n "$DOCKER_CONTAINER" ]]; then
            BACKUP_ARGS+=(-c "$DOCKER_CONTAINER")
        else
            BACKUP_ARGS+=(-h "$DB_HOST" -P "$DB_PORT")
        fi

        BACKUP_OUTPUT=$(printf 'yes\n' | "$BACKUP_SCRIPT" "${BACKUP_ARGS[@]}")
        echo "$BACKUP_OUTPUT"

        BACKUP_FILE=$(echo "$BACKUP_OUTPUT" | grep "  File : " | sed 's/.*File : //')
        if [[ -z "$BACKUP_FILE" || ! -s "$BACKUP_FILE" ]]; then
            log_error "Backup did not complete successfully. Aborting migration — no changes made."
            exit 1
        fi
        log "Backup complete: $BACKUP_FILE"
        echo ""
    else
        echo "  Skipping backup — proceeding without one. Run data-backup-legacy-stop-notes.sh"
        echo "  separately first if you want rollback safety."
        echo ""
    fi
fi

# ─── Chunked migration loop ────────────────────────────────────────────────────
echo "  Running migration..."
echo ""

START_TIME=$(date +%s)
CURRENT_ORDER_ID="$START_ORDER_ID"
TOTAL_STEP1=0
TOTAL_STEP2=0
CHUNK_NUM=0

while [[ "$CURRENT_ORDER_ID" -le "$MAX_ORDER_ID" ]]; do
    CHUNK_NUM=$((CHUNK_NUM + 1))
    CHUNK_END=$(( CURRENT_ORDER_ID + CHUNK_SIZE - 1 ))
    if [[ "$CHUNK_END" -gt "$MAX_ORDER_ID" ]]; then
        CHUNK_END="$MAX_ORDER_ID"
    fi

    RANGE_COND="o.order_id BETWEEN $CURRENT_ORDER_ID AND $CHUNK_END"

    set +e
    CHUNK_OUTPUT=$("${MYSQL_PIPE_CMD[@]}" --skip-column-names 2>"$STDERR_TMP" <<EOF
START TRANSACTION;

-- Log which order_ids step 1 is about to touch, before the UPDATE clears the
-- comment_to_fulfiller IS NULL guard. Since the guard means the "old" value
-- is always NULL, this log is sufficient for the rollback script to undo
-- exactly this batch rows without a full-table restore.
INSERT IGNORE INTO stop_order_notes_migration_log (batch_id, order_id, step, migrated_at)
SELECT '$BATCH_ID', o.order_id, 1, NOW()
FROM orders o
INNER JOIN drug_order do ON do.order_id = o.order_id
WHERE o.order_action = 'DISCONTINUE'
  AND o.order_reason_non_coded IS NOT NULL
  AND o.order_reason_non_coded != ''
  AND o.comment_to_fulfiller IS NULL
  AND $RANGE_COND;

-- 1. DC orders: move note -> comment_to_fulfiller
-- order_reason_non_coded is only ever read here, never modified — no
-- concept-name derivation is performed (order_reason_non_coded is left
-- exactly as-is regardless of whether order_reason is coded).
UPDATE orders o
INNER JOIN drug_order do ON do.order_id = o.order_id
SET o.comment_to_fulfiller = o.order_reason_non_coded
WHERE o.order_action = 'DISCONTINUE'
  AND o.order_reason_non_coded IS NOT NULL
  AND o.order_reason_non_coded != ''
  AND o.comment_to_fulfiller IS NULL
  AND $RANGE_COND;
SET @step1_rows = ROW_COUNT();

-- Log which order_ids step 2 is about to touch (same reasoning as step 1).
INSERT IGNORE INTO stop_order_notes_migration_log (batch_id, order_id, step, migrated_at)
SELECT '$BATCH_ID', o.order_id, 2, NOW()
FROM orders o
INNER JOIN drug_order do ON do.order_id = o.order_id
WHERE o.order_action IN ('NEW', 'REVISE')
  AND do.dosing_instructions LIKE '%"additionalInstructions"%'
  AND JSON_EXTRACT(do.dosing_instructions, '\$.additionalInstructions') IS NOT NULL
  AND o.comment_to_fulfiller IS NULL
  AND $RANGE_COND;

-- 2. NEW/REVISE orders: extract additionalInstructions from JSON -> comment_to_fulfiller
--    (dosing_instructions untouched). REVISE is included because editing a drug
--    order in old Bahmni creates a new orders row with order_action='REVISE',
--    carrying its note in dosing_instructions the same way a NEW order does.
UPDATE orders o
INNER JOIN drug_order do ON do.order_id = o.order_id
SET o.comment_to_fulfiller = JSON_UNQUOTE(JSON_EXTRACT(do.dosing_instructions, '\$.additionalInstructions'))
WHERE o.order_action IN ('NEW', 'REVISE')
  AND do.dosing_instructions LIKE '%"additionalInstructions"%'
  AND JSON_EXTRACT(do.dosing_instructions, '\$.additionalInstructions') IS NOT NULL
  AND o.comment_to_fulfiller IS NULL
  AND $RANGE_COND;
SET @step2_rows = ROW_COUNT();

COMMIT;

SELECT @step1_rows, @step2_rows;
EOF
)
    MYSQL_EXIT=$?
    set -e
    flush_stderr

    if [[ $MYSQL_EXIT -ne 0 ]]; then
        log_error "Chunk $CHUNK_NUM failed (order_id $CURRENT_ORDER_ID-$CHUNK_END). Transaction rolled back."
        log_error "Checkpoint preserved at order_id $(( CURRENT_ORDER_ID - 1 )) — re-run this script to resume from here."
        log_error "See $LOG_FILE for MySQL error details."
        exit 1
    fi

    CHUNK_STEP1=$(echo "$CHUNK_OUTPUT" | tail -1 | awk '{print $1}')
    CHUNK_STEP2=$(echo "$CHUNK_OUTPUT" | tail -1 | awk '{print $2}')
    [[ "$CHUNK_STEP1" =~ ^[0-9]+$ ]] || CHUNK_STEP1=0
    [[ "$CHUNK_STEP2" =~ ^[0-9]+$ ]] || CHUNK_STEP2=0

    TOTAL_STEP1=$(( TOTAL_STEP1 + CHUNK_STEP1 ))
    TOTAL_STEP2=$(( TOTAL_STEP2 + CHUNK_STEP2 ))

    # Checkpoint only updated after a successful commit
    {
        echo "Last completed chunk end order_id - $CHUNK_END"
        echo "Batch ID - $BATCH_ID"
        echo "Range Min - $MIN_ORDER_ID"
        echo "Range Max - $MAX_ORDER_ID"
    } > "$CHECKPOINT_FILE"
    log "Chunk $CHUNK_NUM/$(fmt_num "$TOTAL_CHUNKS") done (order_id $(fmt_num "$CURRENT_ORDER_ID")-$(fmt_num "$CHUNK_END")): step1=$CHUNK_STEP1 step2=$CHUNK_STEP2"

    CURRENT_ORDER_ID=$(( CHUNK_END + 1 ))
done

# Clean finish — remove the checkpoint so a future run starts fresh
rm -f "$CHECKPOINT_FILE"

TOTAL_ELAPSED=$(( $(date +%s) - START_TIME ))

# ─── Summary ──────────────────────────────────────────────────────────────────
echo ""
log "Migration complete."
echo ""
echo "  ┌──────────────────────────────────────────────────────────────┐"
echo "  │  MIGRATION SUMMARY                                           │"
echo "  ├──────────────────────────────────────────────────────────────┤"
printf "  │  Batch ID                             : %-22s│\n" "$BATCH_ID"
printf "  │  Chunks processed                    : %-23s│\n" "$(fmt_num "$CHUNK_NUM")"
printf "  │  Step 1 rows updated (DC note)          : %-21s│\n" "$(fmt_num "$TOTAL_STEP1")"
printf "  │  Step 2 rows updated (NEW/REVISE note)  : %-21s│\n" "$(fmt_num "$TOTAL_STEP2")"
printf "  │  Backup file                          : %-22s│\n" "$( [[ -n "$BACKUP_FILE" ]] && basename "$BACKUP_FILE" || echo "none (skipped)" )"
printf "  │  Total time elapsed                   : %-22s│\n" "$(format_duration "$TOTAL_ELAPSED")"
echo "  └──────────────────────────────────────────────────────────────┘"
echo ""
if [[ -n "$BACKUP_FILE" ]]; then
    echo "  Backup path: $BACKUP_FILE"
    echo ""
fi
echo "  To roll back this batch run:"
echo "    ./data-rollback-legacy-stop-notes.sh -u $DB_USER -d $DB_NAME -b $BATCH_ID"
echo ""
