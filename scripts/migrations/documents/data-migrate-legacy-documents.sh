#!/usr/bin/env bash
set -euo pipefail

# ─── Constants ────────────────────────────────────────────────────────────────
CHUNK_SIZE=10000
CHECKPOINT_FILE="migration_checkpoint.txt"

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
    echo "Usage: $0 [-h host] [-P port] [-u user] [-p pass] [-d dbname] [-c container] [-s chunk_size]"
    echo ""
    echo "  Fully interactive — prompts for any missing required inputs."
    echo "  -s  Rows per commit chunk (default: $CHUNK_SIZE)"
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
if [[ -n "$DOCKER_CONTAINER" ]]; then
    MYSQL_CMD="docker exec -e MYSQL_PWD=$DB_PASS $DOCKER_CONTAINER mysql -u $DB_USER $DB_NAME"
    MYSQL_PIPE_CMD="docker exec -i -e MYSQL_PWD=$DB_PASS $DOCKER_CONTAINER mysql -u $DB_USER $DB_NAME"
else
    MYSQL_CMD="mysql -h $DB_HOST -P $DB_PORT -u $DB_USER -p$DB_PASS $DB_NAME"
    MYSQL_PIPE_CMD="mysql -h $DB_HOST -P $DB_PORT -u $DB_USER -p$DB_PASS $DB_NAME"
fi

# ─── Log file ─────────────────────────────────────────────────────────────────
LOG_FILE="migration_$(date +%Y%m%d).log"
THIS_RUN_HAD_ERRORS=false

# ─── Helper functions ─────────────────────────────────────────────────────────
format_duration() {
    local secs=$1
    printf "%02dh %02dm %02ds" $(( secs / 3600 )) $(( (secs % 3600) / 60 )) $(( secs % 60 ))
}

fmt_num() {
    printf "%'d" "$1"
}

STDERR_TMP=$(mktemp /tmp/migration_stderr.XXXXXX)

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
    flush_stderr
    rm -f "$STDERR_TMP"
    if [[ "$THIS_RUN_HAD_ERRORS" == "false" ]]; then
        rm -f migration_*.log
    fi
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

# ─── Session variables SQL (re-resolved per chunk) ────────────────────────────
SESSION_VARS="
SET @document_cid = (SELECT concept_id FROM concept_name WHERE name = 'Document' AND concept_name_type = 'FULLY_SPECIFIED' AND locale_preferred = true AND locale = 'en');
"

# ─── Header ───────────────────────────────────────────────────────────────────
echo ""
echo "============================================================"
echo "  Legacy Document Migration (BAH-4718)"
echo "============================================================"
echo ""
echo "  Migrates Patient Documents obs groups into document_reference"
echo "  and document_reference_content for FHIR compatibility."
echo ""
echo "  - IDEMPOTENT  : obs.uuid copied as document_reference.uuid"
echo "  - INSERT IGNORE: already-migrated rows silently skipped"
echo "  - CHUNKED     : commits every $CHUNK_SIZE rows — no long locks"
echo "  - RESUMABLE   : checkpoint saved after every chunk"
echo ""
if [[ -n "$DOCKER_CONTAINER" ]]; then
    echo "  Mode    : Docker ($DOCKER_CONTAINER)"
else
    echo "  Mode    : Direct ($DB_HOST:$DB_PORT)"
fi
echo "  Database: $DB_NAME"
echo "  Log file: $LOG_FILE"
echo "  Chunk   : $CHUNK_SIZE rows per commit"
echo "============================================================"
echo ""

log "Migration started"

# ─── Checkpoint detection ─────────────────────────────────────────────────────
RESUME_FROM_OBS_ID=""
if [[ -f "$CHECKPOINT_FILE" ]]; then
    RESUME_FROM_OBS_ID=$(grep -oE '[0-9]+$' "$CHECKPOINT_FILE")
    echo "  Checkpoint found — last scanned obs_id: $(fmt_num "$RESUME_FROM_OBS_ID")"
    echo ""
    read -r -p "  Resume from checkpoint? [yes/no]: " RESUME_CHOICE
    echo ""
    if [[ "$RESUME_CHOICE" == "yes" ]]; then
        log "Resuming from checkpoint: obs_id $RESUME_FROM_OBS_ID"
    else
        RESUME_FROM_OBS_ID=""
        rm -f "$CHECKPOINT_FILE"
        log "Restarting from beginning (checkpoint discarded)"
    fi
fi

# ─── Full vs batch mode ───────────────────────────────────────────────────────
echo "  Select migration type:"
echo "    1. Full migration  — migrate all pending records"
echo "    2. Batch migration — specify an obs_id range"
echo ""
read -r -p "  Enter choice [1/2]: " MIGRATION_TYPE
echo ""

MIN_OBS_ID=""
MAX_OBS_ID=""
RANGE_CONDITION=""

if [[ "$MIGRATION_TYPE" == "2" ]]; then
    log "Batch mode — fetching available obs_id range..."

    OBS_RANGE=$($MYSQL_CMD --skip-column-names -e "
    SELECT MIN(obs_id), MAX(obs_id)
    FROM obs
    WHERE obs_group_id IS NULL
      AND voided = 0;
    " 2>"$STDERR_TMP")
    flush_stderr

    AVAIL_MIN=$(echo "$OBS_RANGE" | awk '{print $1}')
    AVAIL_MAX=$(echo "$OBS_RANGE" | awk '{print $2}')
    echo "  Available obs_id range : $(fmt_num "$AVAIL_MIN") → $(fmt_num "$AVAIL_MAX")"
    echo ""

    read -r -p "  Enter start obs_id : " MIN_OBS_ID
    read -r -p "  Enter end obs_id   : " MAX_OBS_ID
    echo ""

    if ! [[ "$MIN_OBS_ID" =~ ^[0-9]+$ && "$MAX_OBS_ID" =~ ^[0-9]+$ ]]; then
        echo "  ERROR: obs_id values must be numeric."
        echo ""
        exit 1
    fi

    if [[ "$MIN_OBS_ID" -gt "$MAX_OBS_ID" ]]; then
        echo "  ERROR: start obs_id must be <= end obs_id."
        echo ""
        exit 1
    fi

    RANGE_CONDITION="AND parent.obs_id BETWEEN $MIN_OBS_ID AND $MAX_OBS_ID"
    log "Batch mode: obs_id $MIN_OBS_ID → $MAX_OBS_ID"

elif [[ "$MIGRATION_TYPE" == "1" ]]; then
    log "Full migration mode — fetching pending obs_id range..."

    OBS_RANGE=$($MYSQL_CMD --skip-column-names -e "
    SELECT MIN(parent.obs_id), MAX(parent.obs_id)
    FROM obs parent
    WHERE parent.obs_group_id IS NULL
      AND parent.voided = 0
      AND EXISTS (
          SELECT 1 FROM obs child
          WHERE child.obs_group_id = parent.obs_id
            AND child.concept_id = 42
            AND child.value_text IS NOT NULL
            AND child.voided = 0
      )
      AND NOT EXISTS (
          SELECT 1 FROM document_reference dr
          WHERE dr.uuid = parent.uuid
      );
    " 2>"$STDERR_TMP")
    flush_stderr

    MIN_OBS_ID=$(echo "$OBS_RANGE" | awk '{print $1}')
    MAX_OBS_ID=$(echo "$OBS_RANGE" | awk '{print $2}')

    if [[ -z "$MIN_OBS_ID" || "$MIN_OBS_ID" == "NULL" || -z "$MAX_OBS_ID" || "$MAX_OBS_ID" == "NULL" ]]; then
        log "Nothing to migrate. All records are already up to date."
        exit 0
    fi

    RANGE_CONDITION=""
    log "Full mode: pending obs_id range $MIN_OBS_ID → $MAX_OBS_ID"

else
    echo "  ERROR: Invalid choice. Enter 1 or 2."
    echo ""
    exit 1
fi

# ─── Dry-run count ────────────────────────────────────────────────────────────
echo "  Counting records pending migration..."
echo ""

DRY_RUN_COUNT=$($MYSQL_CMD --skip-column-names -e "
SELECT COUNT(*)
FROM obs parent
WHERE parent.obs_group_id IS NULL
  AND parent.voided = 0
  $RANGE_CONDITION
  AND EXISTS (
      SELECT 1 FROM obs child
      WHERE child.obs_group_id = parent.obs_id
        AND child.concept_id = 42
        AND child.value_text IS NOT NULL
        AND child.voided = 0
  )
  AND NOT EXISTS (
      SELECT 1 FROM document_reference dr
      WHERE dr.uuid = parent.uuid
  );
" 2>"$STDERR_TMP")
flush_stderr

# Determine actual start point (resume or fresh)
if [[ -n "$RESUME_FROM_OBS_ID" ]]; then
    START_OBS_ID=$(( RESUME_FROM_OBS_ID + 1 ))
else
    START_OBS_ID=$MIN_OBS_ID
fi

TOTAL_CHUNKS=$(( (MAX_OBS_ID - START_OBS_ID + CHUNK_SIZE) / CHUNK_SIZE ))

echo "  Records pending migration : $(fmt_num "$DRY_RUN_COUNT")"
echo "  obs_id range              : $(fmt_num "$MIN_OBS_ID") → $(fmt_num "$MAX_OBS_ID")"
echo "  Starting from obs_id      : $(fmt_num "$START_OBS_ID")"
echo "  Estimated chunks          : $(fmt_num "$TOTAL_CHUNKS")  ($CHUNK_SIZE rows per chunk)"
echo ""

if [[ "$DRY_RUN_COUNT" -eq 0 ]]; then
    log "Nothing to migrate. All records are already up to date."
    exit 0
fi

# ─── Confirm ──────────────────────────────────────────────────────────────────
read -r -p "  Proceed with migrating $(fmt_num "$DRY_RUN_COUNT") records? [yes/no]: " CONFIRM
echo ""

if [[ "$CONFIRM" != "yes" ]]; then
    log "Migration cancelled by user."
    exit 0
fi

# ─── Pre-migration row count ──────────────────────────────────────────────────
COUNT_BEFORE=$($MYSQL_CMD --skip-column-names -e "
SELECT COUNT(*) FROM document_reference;
" 2>"$STDERR_TMP")
flush_stderr

log "document_reference rows before migration: $(fmt_num "$COUNT_BEFORE")"

# ─── Chunked migration loop ───────────────────────────────────────────────────
echo ""
echo "  Starting chunked migration..."
echo ""
printf "  %-12s | %-27s | %10s | %13s | %s\n" \
    "Chunk" "obs_id range" "Inserted" "Elapsed" "ETA"
printf "  %s\n" "─────────────────────────────────────────────────────────────────────────"

START_TIME=$(date +%s)
TOTAL_INSERTED=0
CHUNK_NUM=0
CURRENT_OBS_ID=$START_OBS_ID
LAST_MIGRATED_OBS_ID=${RESUME_FROM_OBS_ID:-0}

while [[ "$CURRENT_OBS_ID" -le "$MAX_OBS_ID" ]]; do
    CHUNK_END=$(( CURRENT_OBS_ID + CHUNK_SIZE - 1 ))
    if [[ "$CHUNK_END" -gt "$MAX_OBS_ID" ]]; then
        CHUNK_END=$MAX_OBS_ID
    fi

    CHUNK_NUM=$(( CHUNK_NUM + 1 ))

    log "Starting chunk $CHUNK_NUM: obs_id $(fmt_num "$CURRENT_OBS_ID") → $(fmt_num "$CHUNK_END")"

    # Disable set -e so we can capture MySQL exit code manually
    set +e
    CHUNK_OUTPUT=$($MYSQL_PIPE_CMD --skip-column-names 2>"$STDERR_TMP" <<EOF
$SESSION_VARS
START TRANSACTION;
INSERT IGNORE INTO document_reference (
    uuid, status, doc_status, type_concept_id,
    subject_id, encounter_id, author_id,
    date_started, description, location_id,
    creator, date_created, voided, voided_by, date_voided, void_reason
)
SELECT
    parent.uuid,
    'CURRENT',
    CASE WHEN parent.voided = 1 THEN 'ENTEREDINERROR' ELSE 'FINAL' END,
    COALESCE(parent.concept_id, @document_cid),
    patient.patient_id,
    parent.encounter_id,
    COALESCE(ep.provider_id, NULL),
    parent.obs_datetime,
    SUBSTRING(COALESCE((
        SELECT child.comments
        FROM obs child
        WHERE child.obs_group_id = parent.obs_id
          AND child.comments IS NOT NULL
          AND child.voided = 0
        ORDER BY child.obs_id ASC
        LIMIT 1
    ), ''), 1, 255),
    enc.location_id,
    parent.creator,
    parent.date_created,
    parent.voided,
    parent.voided_by,
    parent.date_voided,
    parent.void_reason
FROM obs parent
    INNER JOIN patient ON patient.patient_id = parent.person_id
    INNER JOIN encounter enc ON parent.encounter_id = enc.encounter_id
    LEFT JOIN encounter_provider ep ON enc.encounter_id = ep.encounter_id AND ep.voided = 0
    INNER JOIN obs child ON child.obs_group_id = parent.obs_id
WHERE parent.obs_group_id IS NULL
  AND parent.voided = 0
  AND child.concept_id = 42
  AND child.value_text IS NOT NULL
  AND child.voided = 0
  AND parent.obs_id BETWEEN $CURRENT_OBS_ID AND $CHUNK_END
  AND enc.voided = 0
  AND NOT EXISTS (
    SELECT 1 FROM document_reference dr
    WHERE dr.uuid = parent.uuid
  )
GROUP BY parent.obs_id;
SET @dr_rows = ROW_COUNT();

INSERT IGNORE INTO document_reference_content (
    document_reference_id, uuid, content_url, content_type,
    creator, date_created, voided, voided_by, date_voided, void_reason
)
SELECT
    dr.document_reference_id,
    child.uuid,
    SUBSTRING(child.value_text, 1, 512),
    CASE LOWER(SUBSTRING_INDEX(SUBSTRING_INDEX(child.value_text, '?', 1), '.', -1))
      WHEN 'pdf' THEN 'application/pdf'
      WHEN 'jpg' THEN 'image/jpeg'
      WHEN 'jpeg' THEN 'image/jpeg'
      WHEN 'png' THEN 'image/png'
      WHEN 'gif' THEN 'image/gif'
      WHEN 'bmp' THEN 'image/bmp'
      WHEN 'webp' THEN 'image/webp'
      WHEN 'avif' THEN 'image/avif'
      WHEN 'tiff' THEN 'image/tiff'
      WHEN 'tif' THEN 'image/tiff'
      WHEN 'dcm' THEN 'application/dicom'
      WHEN 'mov' THEN 'video/quicktime'
      WHEN 'mp4' THEN 'video/mp4'
      WHEN 'doc' THEN 'application/msword'
      WHEN 'docx' THEN 'application/vnd.openxmlformats-officedocument.wordprocessingml.document'
      WHEN 'txt' THEN 'text/plain'
      ELSE 'application/octet-stream'
    END,
    child.creator,
    child.date_created,
    COALESCE(child.voided, 0),
    child.voided_by,
    child.date_voided,
    child.void_reason
FROM obs parent
    INNER JOIN obs child ON child.obs_group_id = parent.obs_id
    INNER JOIN document_reference dr ON dr.uuid = parent.uuid
WHERE parent.obs_group_id IS NULL
  AND parent.voided = 0
  AND child.concept_id = 42
  AND child.value_text IS NOT NULL
  AND child.voided = 0
  AND parent.obs_id BETWEEN $CURRENT_OBS_ID AND $CHUNK_END
  AND NOT EXISTS (
    SELECT 1 FROM document_reference_content drc
    WHERE drc.document_reference_id = dr.document_reference_id
      AND drc.uuid = child.uuid
  );
SET @drc_rows = ROW_COUNT();

COMMIT;
SELECT @dr_rows;
SELECT MAX(o.obs_id)
FROM obs o
INNER JOIN document_reference dr ON dr.uuid = o.uuid
WHERE o.obs_id BETWEEN $CURRENT_OBS_ID AND $CHUNK_END;
EOF
    )
    MYSQL_EXIT=$?
    set -e
    flush_stderr

    log "Chunk $CHUNK_NUM SQL completed successfully."

    if [[ $MYSQL_EXIT -ne 0 ]]; then
        echo ""
        log_error "Chunk $CHUNK_NUM failed — obs_id $CURRENT_OBS_ID → $CHUNK_END"
        log_error "Transaction rolled back. Checkpoint at obs_id $(( CURRENT_OBS_ID - 1 )) is safe. Re-run and choose 'resume'."
        log_error "See $LOG_FILE for MySQL error details."
        exit 1
    fi

    CHUNK_INSERTED=$(echo "$CHUNK_OUTPUT" | grep -E '^[0-9]+$' | head -1)
    if ! [[ "$CHUNK_INSERTED" =~ ^[0-9]+$ ]]; then
        CHUNK_INSERTED=0
    fi

    LAST_OBS_RAW=$(echo "$CHUNK_OUTPUT" | grep -v '^[[:space:]]*$' | tail -1)
    if [[ "$LAST_OBS_RAW" =~ ^[0-9]+$ ]]; then
        LAST_MIGRATED_OBS_ID=$LAST_OBS_RAW
    fi

    TOTAL_INSERTED=$(( TOTAL_INSERTED + CHUNK_INSERTED ))
    log "Committing chunk $CHUNK_NUM. Updating checkpoint to obs_id $(fmt_num "$CHUNK_END")"
    echo "Last Scanned obs_id - $CHUNK_END" > "$CHECKPOINT_FILE"
    log "Checkpoint saved. Last committed obs_id: $(fmt_num "$CHUNK_END")"

    # Progress and ETA
    ELAPSED=$(( $(date +%s) - START_TIME ))
    CHUNKS_REMAINING=$(( (MAX_OBS_ID - CHUNK_END + CHUNK_SIZE - 1) / CHUNK_SIZE ))

    if [[ $CHUNK_NUM -gt 0 && $ELAPSED -gt 0 ]]; then
        SECS_PER_CHUNK=$(( ELAPSED / CHUNK_NUM ))
        ETA_STR=$(format_duration $(( SECS_PER_CHUNK * CHUNKS_REMAINING )))
    else
        ETA_STR="calculating..."
    fi

    PROGRESS_LINE=$(printf "  %5d/%-5d | %12s → %-12s | %10s | %13s | %s" \
        "$CHUNK_NUM" \
        "$TOTAL_CHUNKS" \
        "$(fmt_num "$CURRENT_OBS_ID")" \
        "$(fmt_num "$CHUNK_END")" \
        "+$(fmt_num "$CHUNK_INSERTED")" \
        "$(format_duration "$ELAPSED")" \
        "$ETA_STR")

    echo "$PROGRESS_LINE"

    CURRENT_OBS_ID=$(( CHUNK_END + 1 ))
done

# ─── Post-migration count ─────────────────────────────────────────────────────
COUNT_AFTER=$($MYSQL_CMD --skip-column-names -e "
SELECT COUNT(*) FROM document_reference;
" 2>"$STDERR_TMP")
flush_stderr

TOTAL_ELAPSED=$(( $(date +%s) - START_TIME ))

# ─── Summary ──────────────────────────────────────────────────────────────────
printf "  %s\n" "─────────────────────────────────────────────────────────────────────────"
echo ""
log "Migration complete."
echo ""
echo "  ┌──────────────────────────────────────────────────────────────┐"
echo "  │  MIGRATION SUMMARY                                           │"
echo "  ├──────────────────────────────────────────────────────────────┤"
printf "  │  Rows inserted this run      : %-30s│\n" "$(fmt_num "$TOTAL_INSERTED")"
printf "  │  Chunks processed            : %-30s│\n" "$(fmt_num "$CHUNK_NUM")"
printf "  │  document_reference before   : %-30s│\n" "$(fmt_num "$COUNT_BEFORE")"
printf "  │  document_reference after    : %-30s│\n" "$(fmt_num "$COUNT_AFTER")"
printf "  │  Total time elapsed          : %-30s│\n" "$(format_duration "$TOTAL_ELAPSED")"
echo "  └──────────────────────────────────────────────────────────────┘"
echo ""

# Checkpoint removed on clean completion — no resume needed
rm -f "$CHECKPOINT_FILE"
log "Checkpoint removed. Migration finished successfully."

echo ""
