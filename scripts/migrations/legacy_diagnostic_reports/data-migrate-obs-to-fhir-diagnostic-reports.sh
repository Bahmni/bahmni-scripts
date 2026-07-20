#!/usr/bin/env bash
set -euo pipefail

# ─── Constants ────────────────────────────────────────────────────────────────
CHUNK_SIZE=10000


CHECKPOINT_FILE="diag_report_migration_checkpoint.txt"

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
    echo "  Target obs:"
    echo "    Only obs where obs_group_id IS NULL AND order_id IS NOT NULL are"
    echo "    migrated. This selects lab result groups (linked to a lab order)"
    echo "    and excludes diagnoses, vitals, and any other obs group types."
    echo ""
    echo "  Prerequisites:"
    echo "    The following tables must exist before running this script:"
    echo "      fhir_diagnostic_report            (status, concept_id, subject_id, encounter_id,"
    echo "                                          issued, conclusion, creator, date_created,"
    echo "                                          changed_by, date_changed, voided, voided_by,"
    echo "                                          date_voided, void_reason, uuid)"
    echo "      fhir_diagnostic_report_results    (diagnostic_report_id, obs_id)"
    echo "      fhir_diagnostic_report_performers (diagnostic_report_id, provider_id)"
    echo "      fhir_diagnostic_report_service_request (diagnostic_report_id, order_id)"
    echo "      fhir_diagnostic_report_presented_form  (diagnostic_report_id, document_attachment_id)"
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

# ─── Single-instance lock ────────────────────────────────────────────────────
# Prevents two simultaneous runs from colliding on the same obs_id range.
# Uses a PID file instead of flock so it works on macOS (bash 3.2) and Linux.
# Scoped to the target database — parallel runs against different DBs are fine.
LOCK_FILE="/tmp/diag_report_migration_${DB_NAME}.lock"

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
# Validates container name, credentials, and database in one lightweight query.
# Runs before checkpoint detection so a wrong container never silently continues.
CONN_TEST=$($MYSQL_CMD --skip-column-names -e "SELECT 1;" 2>&1) || true
if [[ "$CONN_TEST" != "1" ]]; then
    echo ""
    echo "  ERROR: Cannot connect to MySQL."
    echo "  $CONN_TEST"
    echo ""
    rm -f "$LOCK_FILE"
    exit 1
fi

# ─── Log file ─────────────────────────────────────────────────────────────────
LOG_FILE="diag_report_migration_$(date +%Y%m%d).log"
THIS_RUN_HAD_ERRORS=false

# ─── Helper functions ─────────────────────────────────────────────────────────
format_duration() {
    local secs=$1
    printf "%02dh %02dm %02ds" $(( secs / 3600 )) $(( (secs % 3600) / 60 )) $(( secs % 60 ))
}

fmt_num() {
    printf "%'d" "$1"
}

STDERR_TMP=$(mktemp /tmp/diag_report_migration_stderr.XXXXXX)

flush_stderr() {
    if [[ -s "$STDERR_TMP" ]]; then
        if [[ "$THIS_RUN_HAD_ERRORS" == "false" ]]; then
            THIS_RUN_HAD_ERRORS=true
            echo "" >> "$LOG_FILE"
            echo "== Run: $(date '+%Y-%m-%d %H:%M:%S') ==" >> "$LOG_FILE"
        fi
        cat "$STDERR_TMP" >> "$LOG_FILE"
    fi
    : > "$STDERR_TMP"
}

on_exit() {
    flush_stderr
    rm -f "$STDERR_TMP"
    rm -f "$LOCK_FILE" 2>/dev/null || true
    if [[ "$THIS_RUN_HAD_ERRORS" == "false" ]]; then
        rm -f diag_report_migration_*.log
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
        echo "== Run: $(date '+%Y-%m-%d %H:%M:%S') ==" >> "$LOG_FILE"
    fi
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    printf "  %s  ERROR  %s\n" "$ts" "$1" | tee -a "$LOG_FILE"
}

# ─── Checkpoint detection ─────────────────────────────────────────────────────
# Must happen before SESSION_VARS so we can restore BATCH_ID on resume.
RESUME_FROM_OBS_ID=""
BATCH_ID=""

if [[ -f "$CHECKPOINT_FILE" ]]; then
    RESUME_FROM_OBS_ID=$(grep 'Last Scanned obs_id' "$CHECKPOINT_FILE" | grep -oE '[0-9]+$' || true)
    BATCH_ID=$(grep 'Batch ID' "$CHECKPOINT_FILE" | sed 's/Batch ID - //' || true)
    echo "  Checkpoint found — last scanned obs_id: $(fmt_num "$RESUME_FROM_OBS_ID")"
    echo "  Batch ID in checkpoint               : $BATCH_ID"
    echo ""
    read -r -p "  Resume from checkpoint? [yes/no]: " RESUME_CHOICE
    echo ""
    if [[ "$RESUME_CHOICE" == "yes" ]]; then
        log "Resuming from checkpoint: obs_id $RESUME_FROM_OBS_ID, batch $BATCH_ID"
    else
        RESUME_FROM_OBS_ID=""
        BATCH_ID=""
        rm -f "$CHECKPOINT_FILE"
        log "Restarting from beginning (checkpoint discarded)"
    fi
fi

# Generate a fresh batch ID when starting a new run (not resuming).
if [[ -z "$BATCH_ID" ]]; then
    BATCH_ID=$($MYSQL_CMD --skip-column-names -e "SELECT UUID();" 2>/dev/null | tr -d '[:space:]')
    if [[ -z "$BATCH_ID" ]]; then
        BATCH_ID="batch_$(date +%Y%m%d_%H%M%S)"
    fi
fi

# ─── Session variables SQL (re-resolved per chunk — separate connections) ─────
# LAB_REPORT concept: identifies the document attachment child obs.
# batch_id: written to the migration log so rollback can target this run only.
SESSION_VARS="
SET @lab_report_cid = (
    SELECT concept_id FROM concept_name
    WHERE name = 'LAB_REPORT'
      AND concept_name_type = 'FULLY_SPECIFIED'
      AND locale_preferred = true
      AND locale = 'en'
    LIMIT 1
);
SET @lab_maxnormal_cid = (
    SELECT concept_id FROM concept_name
    WHERE name = 'LAB_MAXNORMAL'
      AND concept_name_type = 'FULLY_SPECIFIED'
      AND locale_preferred = true
      AND locale = 'en'
    LIMIT 1
);
SET @lab_minnormal_cid = (
    SELECT concept_id FROM concept_name
    WHERE name = 'LAB_MINNORMAL'
      AND concept_name_type = 'FULLY_SPECIFIED'
      AND locale_preferred = true
      AND locale = 'en'
    LIMIT 1
);
SET @lab_notes_cid = (
    SELECT concept_id FROM concept_name
    WHERE name = 'LAB_NOTES'
      AND concept_name_type = 'FULLY_SPECIFIED'
      AND locale_preferred = true
      AND locale = 'en'
    LIMIT 1
);
SET @batch_id = '$BATCH_ID';
"

# ─── Header ───────────────────────────────────────────────────────────────────
echo ""
echo "============================================================"
echo "  Obs to FHIR Diagnostic Report Migration"
echo "============================================================"
echo ""
echo "  Migrates lab result obs groups (obs_group_id IS NULL AND"
echo "  order_id IS NOT NULL) into fhir_diagnostic_report and its"
echo "  child tables. Diagnoses, vitals, and any other obs group"
echo "  types are excluded by the order_id IS NOT NULL filter."
echo ""
echo "  Populated tables:"
echo "    fhir_diagnostic_report              — one row per result group"
echo "    fhir_diagnostic_report_results      — one row per child obs"
echo "    fhir_diagnostic_report_performers   — from obs.creator -> provider"
echo "    fhir_diagnostic_report_service_request — order_id linkage"
echo "    fhir_diagnostic_report_presented_form  — from LAB_REPORT child obs"
echo "    fhir_diag_report_migration_log      — batch tracking for safe rollback"
echo ""
echo "  - IDEMPOTENT : obs.uuid -> fhir_diagnostic_report.uuid (unique)"
echo "  - INSERT IGNORE: already-migrated rows silently skipped"
echo "  - CHUNKED    : commits every $CHUNK_SIZE rows — no long locks"
echo "  - RESUMABLE  : checkpoint saved after every chunk"
echo "  - BATCH TAG  : batch ID written to log; rollback targets only this run"
echo ""
if [[ -n "$DOCKER_CONTAINER" ]]; then
    echo "  Mode    : Docker ($DOCKER_CONTAINER)"
else
    echo "  Mode    : Direct ($DB_HOST:$DB_PORT)"
fi
echo "  Database: $DB_NAME"
echo "  Log file: $LOG_FILE"
echo "  Chunk   : $CHUNK_SIZE rows per commit"
echo "  Batch ID: $BATCH_ID"
echo "============================================================"
echo ""

log "Migration started — batch ID: $BATCH_ID"

# ─── Create migration tracking table ─────────────────────────────────────────
# One row per migrated diagnostic report per batch. Used by the rollback
# script to delete only the rows created in this run, leaving any rows
# written by the React UI untouched.
log "Creating fhir_diag_report_migration_log table if not exists..."
$MYSQL_PIPE_CMD 2>"$STDERR_TMP" <<'INITSQL'
CREATE TABLE IF NOT EXISTS fhir_diag_report_migration_log (
    id                  INT AUTO_INCREMENT PRIMARY KEY,
    batch_id            VARCHAR(36)  NOT NULL,
    diagnostic_report_id INT         NOT NULL,
    obs_id              INT          NOT NULL,
    migrated_at         DATETIME     NOT NULL,
    UNIQUE KEY uk_batch_dr (batch_id, diagnostic_report_id),
    INDEX idx_batch_id (batch_id)
);
INITSQL
flush_stderr

# ─── Full vs batch mode ───────────────────────────────────────────────────────
echo "  Select migration type:"
echo "    1. Full migration  — migrate all pending lab result obs"
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
    SELECT MIN(o.obs_id), MAX(o.obs_id)
    FROM obs o
    WHERE o.obs_group_id IS NULL
      AND o.order_id     IS NOT NULL;
    " 2>"$STDERR_TMP")
    flush_stderr

    AVAIL_MIN=$(echo "$OBS_RANGE" | awk '{print $1}')
    AVAIL_MAX=$(echo "$OBS_RANGE" | awk '{print $2}')
    echo "  Available obs_id range : $(fmt_num "$AVAIL_MIN") -> $(fmt_num "$AVAIL_MAX")"
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
    log "Batch mode: obs_id $MIN_OBS_ID -> $MAX_OBS_ID"

elif [[ "$MIGRATION_TYPE" == "1" ]]; then
    log "Full migration mode — fetching pending obs_id range..."

    OBS_RANGE=$($MYSQL_CMD --skip-column-names -e "
    SELECT MIN(parent.obs_id), MAX(parent.obs_id)
    FROM obs parent
    WHERE parent.obs_group_id IS NULL
      AND parent.order_id     IS NOT NULL
      AND NOT EXISTS (
          SELECT 1 FROM fhir_diagnostic_report dr WHERE dr.uuid = parent.uuid
      );
    " 2>"$STDERR_TMP")
    flush_stderr

    MIN_OBS_ID=$(echo "$OBS_RANGE" | awk '{print $1}')
    MAX_OBS_ID=$(echo "$OBS_RANGE" | awk '{print $2}')

    if [[ -z "$MIN_OBS_ID" || "$MIN_OBS_ID" == "NULL" || -z "$MAX_OBS_ID" || "$MAX_OBS_ID" == "NULL" ]]; then
        log "Nothing to migrate. All lab result records are already up to date."
        exit 0
    fi

    RANGE_CONDITION=""
    log "Full mode: pending obs_id range $MIN_OBS_ID -> $MAX_OBS_ID"

else
    echo "  ERROR: Invalid choice. Enter 1 or 2."
    echo ""
    exit 1
fi

# ─── Dry-run count ────────────────────────────────────────────────────────────
echo "  Counting lab result obs pending migration..."
echo ""

DRY_RUN_COUNT=$($MYSQL_CMD --skip-column-names -e "
SELECT COUNT(*)
FROM obs parent
WHERE parent.obs_group_id IS NULL
  AND parent.order_id     IS NOT NULL
  AND NOT EXISTS (
      SELECT 1 FROM fhir_diagnostic_report dr WHERE dr.uuid = parent.uuid
  )
$RANGE_CONDITION;
" 2>"$STDERR_TMP")
flush_stderr

# ─── Determine actual start point ─────────────────────────────────────────────
if [[ -n "$RESUME_FROM_OBS_ID" ]]; then
    START_OBS_ID=$(( RESUME_FROM_OBS_ID + 1 ))
else
    START_OBS_ID=$MIN_OBS_ID
fi

TOTAL_CHUNKS=$(( (MAX_OBS_ID - START_OBS_ID + CHUNK_SIZE) / CHUNK_SIZE ))

echo "  Lab result obs pending migration : $(fmt_num "$DRY_RUN_COUNT")"
echo "  obs_id range                     : $(fmt_num "$MIN_OBS_ID") -> $(fmt_num "$MAX_OBS_ID")"
echo "  Starting from obs_id             : $(fmt_num "$START_OBS_ID")"
echo "  Estimated chunks                 : $(fmt_num "$TOTAL_CHUNKS")  ($CHUNK_SIZE rows per chunk)"
echo "  Batch ID                         : $BATCH_ID"
echo ""

if [[ "$DRY_RUN_COUNT" -eq 0 ]]; then
    log "Nothing to migrate. All lab result records are already up to date."
    exit 0
fi

read -r -p "  Proceed with migrating $(fmt_num "$DRY_RUN_COUNT") lab result obs? [yes/no]: " CONFIRM
echo ""

if [[ "$CONFIRM" != "yes" ]]; then
    log "Migration cancelled by user."
    exit 0
fi

# ─── Pre-migration row count ──────────────────────────────────────────────────
COUNT_BEFORE=$($MYSQL_CMD --skip-column-names -e "
SELECT COUNT(*) FROM fhir_diagnostic_report;
" 2>"$STDERR_TMP")
flush_stderr

log "fhir_diagnostic_report rows before migration: $(fmt_num "$COUNT_BEFORE")"

# ─── Chunked migration loop ───────────────────────────────────────────────────
echo ""
echo "  Starting chunked migration..."
echo ""
printf "  %-12s | %-27s | %10s | %13s | %s\n" \
    "Chunk" "obs_id range" "Inserted" "Elapsed" "ETA"
printf "  %s\n" "-------------------------------------------------------------------------"

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
    log "Starting chunk $CHUNK_NUM: obs_id $(fmt_num "$CURRENT_OBS_ID") -> $(fmt_num "$CHUNK_END")"

    set +e
    CHUNK_OUTPUT=$($MYSQL_PIPE_CMD --skip-column-names 2>"$STDERR_TMP" <<EOF
$SESSION_VARS
START TRANSACTION;

-- ── Step 1: fhir_diagnostic_report ──────────────────────────────────────────
-- One row per top-level lab result obs (obs_group_id IS NULL,
-- order_id IS NOT NULL). Status is taken from obs.status; NULL obs
-- (pre-2.x records without a status column) default to FINAL.
-- conclusion maps from obs.comments (result summary).
INSERT IGNORE INTO fhir_diagnostic_report (
    status,
    concept_id,
    subject_id,
    encounter_id,
    issued,
    conclusion,
    creator,
    date_created,
    voided,
    voided_by,
    date_voided,
    void_reason,
    uuid
)
SELECT
    COALESCE(parent.status, 'FINAL'),
    parent.concept_id,
    parent.person_id,
    parent.encounter_id,
    parent.obs_datetime,
    parent.comments,
    parent.creator,
    parent.date_created,
    parent.voided,
    parent.voided_by,
    parent.date_voided,
    parent.void_reason,
    parent.uuid
FROM obs parent
WHERE parent.obs_group_id IS NULL
  AND parent.order_id     IS NOT NULL
  AND parent.obs_id BETWEEN $CURRENT_OBS_ID AND $CHUNK_END;

SET @dr_rows = ROW_COUNT();

-- ── Step 2: fhir_diagnostic_report_results ───────────────────────────────────
-- One row per result obs. Handles both flat (2-level) and nested (3-level)
-- Bahmni lab structures:
--   Flat:   root → result obs   (direct children with values)
--   Nested: root → sub-group → result obs   (grandchildren with values)
-- Structural/group obs that carry no value are excluded from results at every
-- level; only obs with an actual value (numeric, text, coded, datetime, or
-- complex) are inserted.  LAB_REPORT obs are excluded at every level.

-- Level 1: direct children of the root obs that carry an actual value.
INSERT IGNORE INTO fhir_diagnostic_report_results (
    diagnostic_report_id,
    obs_id
)
SELECT
    dr.diagnostic_report_id,
    child.obs_id
FROM obs child
JOIN obs parent
    ON  parent.obs_id       = child.obs_group_id
    AND parent.obs_group_id IS NULL
    AND parent.order_id     IS NOT NULL
    AND parent.obs_id BETWEEN $CURRENT_OBS_ID AND $CHUNK_END
JOIN fhir_diagnostic_report dr
    ON  dr.uuid = parent.uuid
WHERE (@lab_report_cid    IS NULL OR child.concept_id != @lab_report_cid)
  AND (@lab_maxnormal_cid IS NULL OR child.concept_id != @lab_maxnormal_cid)
  AND (@lab_minnormal_cid IS NULL OR child.concept_id != @lab_minnormal_cid)
  AND (@lab_notes_cid     IS NULL OR child.concept_id != @lab_notes_cid)
  AND child.voided = 0
  AND (   child.value_numeric  IS NOT NULL
       OR child.value_text     IS NOT NULL
       OR child.value_coded    IS NOT NULL
       OR child.value_datetime IS NOT NULL
       OR child.value_complex  IS NOT NULL);

-- Level 2: grandchildren (root → L1 → L2 with value).
INSERT IGNORE INTO fhir_diagnostic_report_results (
    diagnostic_report_id,
    obs_id
)
SELECT
    dr.diagnostic_report_id,
    grandchild.obs_id
FROM obs grandchild
JOIN obs child
    ON  child.obs_id  = grandchild.obs_group_id
JOIN obs parent
    ON  parent.obs_id       = child.obs_group_id
    AND parent.obs_group_id IS NULL
    AND parent.order_id     IS NOT NULL
    AND parent.obs_id BETWEEN $CURRENT_OBS_ID AND $CHUNK_END
JOIN fhir_diagnostic_report dr
    ON  dr.uuid = parent.uuid
WHERE (@lab_report_cid    IS NULL OR grandchild.concept_id != @lab_report_cid)
  AND (@lab_maxnormal_cid IS NULL OR grandchild.concept_id != @lab_maxnormal_cid)
  AND (@lab_minnormal_cid IS NULL OR grandchild.concept_id != @lab_minnormal_cid)
  AND (@lab_notes_cid     IS NULL OR grandchild.concept_id != @lab_notes_cid)
  AND grandchild.voided = 0
  AND (   grandchild.value_numeric  IS NOT NULL
       OR grandchild.value_text     IS NOT NULL
       OR grandchild.value_coded    IS NOT NULL
       OR grandchild.value_datetime IS NOT NULL
       OR grandchild.value_complex  IS NOT NULL);

-- Level 3: great-grandchildren (root → L1 → L2 → L3 with value).
-- Handles 4-level Bahmni panel structures where two intermediate group obs
-- sit between the root and the actual result obs.
INSERT IGNORE INTO fhir_diagnostic_report_results (
    diagnostic_report_id,
    obs_id
)
SELECT
    dr.diagnostic_report_id,
    ggc.obs_id
FROM obs ggc
JOIN obs grandchild
    ON  grandchild.obs_id = ggc.obs_group_id
JOIN obs child
    ON  child.obs_id      = grandchild.obs_group_id
JOIN obs parent
    ON  parent.obs_id       = child.obs_group_id
    AND parent.obs_group_id IS NULL
    AND parent.order_id     IS NOT NULL
    AND parent.obs_id BETWEEN $CURRENT_OBS_ID AND $CHUNK_END
JOIN fhir_diagnostic_report dr
    ON  dr.uuid = parent.uuid
WHERE (@lab_report_cid    IS NULL OR ggc.concept_id != @lab_report_cid)
  AND (@lab_maxnormal_cid IS NULL OR ggc.concept_id != @lab_maxnormal_cid)
  AND (@lab_minnormal_cid IS NULL OR ggc.concept_id != @lab_minnormal_cid)
  AND (@lab_notes_cid     IS NULL OR ggc.concept_id != @lab_notes_cid)
  AND ggc.voided = 0
  AND (   ggc.value_numeric  IS NOT NULL
       OR ggc.value_text     IS NOT NULL
       OR ggc.value_coded    IS NOT NULL
       OR ggc.value_datetime IS NOT NULL
       OR ggc.value_complex  IS NOT NULL);

-- ── Step 3: fhir_diagnostic_report_performers ────────────────────────────────
-- The performer is the user who recorded the result (obs.creator),
-- resolved to their corresponding provider record.
INSERT IGNORE INTO fhir_diagnostic_report_performers (
    diagnostic_report_id,
    provider_id
)
SELECT
    dr.diagnostic_report_id,
    prov.provider_id
FROM obs parent
JOIN fhir_diagnostic_report dr
    ON  dr.uuid = parent.uuid
JOIN users u
    ON  u.user_id = parent.creator
JOIN provider prov
    ON  prov.person_id = u.person_id
    AND prov.retired   = 0
WHERE parent.obs_group_id IS NULL
  AND parent.order_id     IS NOT NULL
  AND parent.obs_id BETWEEN $CURRENT_OBS_ID AND $CHUNK_END;

-- ── Step 4: fhir_diagnostic_report_service_request ───────────────────────────
-- Links the report back to the originating lab order (ServiceRequest).
-- Every obs in this migration has order_id IS NOT NULL by definition.
INSERT IGNORE INTO fhir_diagnostic_report_service_request (
    diagnostic_report_id,
    order_id
)
SELECT
    dr.diagnostic_report_id,
    parent.order_id
FROM obs parent
JOIN fhir_diagnostic_report dr
    ON  dr.uuid = parent.uuid
WHERE parent.obs_group_id IS NULL
  AND parent.order_id     IS NOT NULL
  AND parent.obs_id BETWEEN $CURRENT_OBS_ID AND $CHUNK_END;

-- ── Step 5: fhir_diagnostic_report_presented_form ────────────────────────────
-- Links the report to its uploaded document attachment.
-- Two passes cover both storage patterns observed in Bahmni:
--   Depth 1: LAB_REPORT obs is a direct child of the root obs.
--   Depth 2: LAB_REPORT obs is a grandchild (root → intermediate → LAB_REPORT).
-- The file URL is matched via COALESCE(value_complex, value_text) because
-- older Bahmni versions stored the URL in value_complex and newer versions
-- (bahmnicore 2.1+) store it in value_text.

-- Depth 1: LAB_REPORT is a direct child of the root obs
INSERT IGNORE INTO fhir_diagnostic_report_presented_form (
    diagnostic_report_id,
    document_attachment_id
)
SELECT
    dr.diagnostic_report_id,
    da.document_attachment_id
FROM obs parent
JOIN fhir_diagnostic_report dr
    ON  dr.uuid = parent.uuid
JOIN obs lab_obs
    ON  lab_obs.obs_group_id = parent.obs_id
    AND lab_obs.concept_id   = @lab_report_cid
    AND lab_obs.voided       = 0
JOIN document_attachment da
    ON  da.content_url = COALESCE(lab_obs.value_complex, lab_obs.value_text)
WHERE parent.obs_group_id IS NULL
  AND parent.order_id     IS NOT NULL
  AND @lab_report_cid     IS NOT NULL
  AND parent.obs_id BETWEEN $CURRENT_OBS_ID AND $CHUNK_END;

-- Depth 2: LAB_REPORT is a grandchild (root → L1 → LAB_REPORT)
INSERT IGNORE INTO fhir_diagnostic_report_presented_form (
    diagnostic_report_id,
    document_attachment_id
)
SELECT
    dr.diagnostic_report_id,
    da.document_attachment_id
FROM obs parent
JOIN fhir_diagnostic_report dr
    ON  dr.uuid = parent.uuid
JOIN obs child
    ON  child.obs_group_id = parent.obs_id
    AND child.voided       = 0
JOIN obs lab_obs
    ON  lab_obs.obs_group_id = child.obs_id
    AND lab_obs.concept_id   = @lab_report_cid
    AND lab_obs.voided       = 0
JOIN document_attachment da
    ON  da.content_url = COALESCE(lab_obs.value_complex, lab_obs.value_text)
WHERE parent.obs_group_id IS NULL
  AND parent.order_id     IS NOT NULL
  AND @lab_report_cid     IS NOT NULL
  AND parent.obs_id BETWEEN $CURRENT_OBS_ID AND $CHUNK_END;

-- Depth 3: LAB_REPORT is a great-grandchild (root → L1 → L2 → LAB_REPORT)
-- This is the 4-level structure used in Bahmni for single-result panel tests
-- where result, LAB_MINNORMAL, LAB_MAXNORMAL, and LAB_REPORT all sit at L3.
INSERT IGNORE INTO fhir_diagnostic_report_presented_form (
    diagnostic_report_id,
    document_attachment_id
)
SELECT
    dr.diagnostic_report_id,
    da.document_attachment_id
FROM obs parent
JOIN fhir_diagnostic_report dr
    ON  dr.uuid = parent.uuid
JOIN obs child
    ON  child.obs_group_id = parent.obs_id
    AND child.voided       = 0
JOIN obs grandchild
    ON  grandchild.obs_group_id = child.obs_id
    AND grandchild.voided       = 0
JOIN obs lab_obs
    ON  lab_obs.obs_group_id = grandchild.obs_id
    AND lab_obs.concept_id   = @lab_report_cid
    AND lab_obs.voided       = 0
JOIN document_attachment da
    ON  da.content_url = COALESCE(lab_obs.value_complex, lab_obs.value_text)
WHERE parent.obs_group_id IS NULL
  AND parent.order_id     IS NOT NULL
  AND @lab_report_cid     IS NOT NULL
  AND parent.obs_id BETWEEN $CURRENT_OBS_ID AND $CHUNK_END;

-- ── Step 6: migration batch log ──────────────────────────────────────────────
-- Records every diagnostic_report_id created in this batch so the rollback
-- script can delete only migration rows and leave React UI rows untouched.
INSERT IGNORE INTO fhir_diag_report_migration_log
    (batch_id, diagnostic_report_id, obs_id, migrated_at)
SELECT @batch_id, dr.diagnostic_report_id, o.obs_id, NOW()
FROM obs o
JOIN fhir_diagnostic_report dr ON dr.uuid = o.uuid
WHERE o.obs_id BETWEEN $CURRENT_OBS_ID AND $CHUNK_END
  AND o.obs_group_id IS NULL
  AND o.order_id     IS NOT NULL;

COMMIT;

SELECT @dr_rows;

SELECT MAX(o.obs_id)
FROM obs o
JOIN fhir_diagnostic_report dr ON dr.uuid = o.uuid
WHERE o.obs_id BETWEEN $CURRENT_OBS_ID AND $CHUNK_END;
EOF
    )
    MYSQL_EXIT=$?
    set -e
    flush_stderr

    log "Chunk $CHUNK_NUM SQL completed."

    if [[ $MYSQL_EXIT -ne 0 ]]; then
        echo ""
        log_error "Chunk $CHUNK_NUM failed — obs_id $CURRENT_OBS_ID -> $CHUNK_END"
        log_error "Transaction rolled back. Checkpoint at obs_id $(( CURRENT_OBS_ID - 1 )) is safe. Re-run and choose resume."
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
    log "Chunk $CHUNK_NUM done. Saving checkpoint at obs_id $(fmt_num "$CHUNK_END")"
    printf "Last Scanned obs_id - %s\nBatch ID - %s\n" "$CHUNK_END" "$BATCH_ID" > "$CHECKPOINT_FILE"
    log "Checkpoint saved."

    ELAPSED=$(( $(date +%s) - START_TIME ))
    CHUNKS_REMAINING=$(( (MAX_OBS_ID - CHUNK_END + CHUNK_SIZE - 1) / CHUNK_SIZE ))

    if [[ $CHUNK_NUM -gt 0 && $ELAPSED -gt 0 ]]; then
        SECS_PER_CHUNK=$(( ELAPSED / CHUNK_NUM ))
        ETA_STR=$(format_duration $(( SECS_PER_CHUNK * CHUNKS_REMAINING )))
    else
        ETA_STR="calculating..."
    fi

    PROGRESS_LINE=$(printf "  %5d/%-5d | %12s -> %-12s | %10s | %13s | %s" \
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

# ─── Post-migration row count ─────────────────────────────────────────────────
COUNT_AFTER=$($MYSQL_CMD --skip-column-names -e "
SELECT COUNT(*) FROM fhir_diagnostic_report;
" 2>"$STDERR_TMP")
flush_stderr

TOTAL_ELAPSED=$(( $(date +%s) - START_TIME ))

# ─── Summary ──────────────────────────────────────────────────────────────────
printf "  %s\n" "-------------------------------------------------------------------------"
echo ""
log "Migration complete."
echo ""
echo "  +-----------------------------------------------------------------+"
echo "  |  MIGRATION SUMMARY                                              |"
echo "  +-----------------------------------------------------------------+"
printf "  |  Batch ID                              : %-20s|\n" "$BATCH_ID"
printf "  |  Diagnostic reports inserted this run  : %-20s|\n" "$(fmt_num "$TOTAL_INSERTED")"
printf "  |  Chunks processed                      : %-20s|\n" "$(fmt_num "$CHUNK_NUM")"
printf "  |  fhir_diagnostic_report before         : %-20s|\n" "$(fmt_num "$COUNT_BEFORE")"
printf "  |  fhir_diagnostic_report after          : %-20s|\n" "$(fmt_num "$COUNT_AFTER")"
printf "  |  Total time elapsed                    : %-20s|\n" "$(format_duration "$TOTAL_ELAPSED")"
echo "  +-----------------------------------------------------------------+"
echo ""
echo "  To roll back this batch run:"
echo "    ./data-rollback-obs-to-fhir-diagnostic-reports.sh \\"
echo "        -u $DB_USER -d $DB_NAME -b $BATCH_ID"
echo ""

rm -f "$CHECKPOINT_FILE"
log "Checkpoint removed. Migration finished successfully."
echo ""