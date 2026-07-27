#!/usr/bin/env bash
set -euo pipefail

# ─── Constants ────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHUNK_SIZE=10000
CHECKPOINT_FILE="$SCRIPT_DIR/migration_checkpoint.txt"

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

# ─── Log file ─────────────────────────────────────────────────────────────────
# One file per day — all runs (success and failure) append to the same file.
LOG_FILE="$SCRIPT_DIR/migration_$(date +%Y%m%d).log"
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
    flush_stderr                    # promote any captured errors to log file
    rm -f "$STDERR_TMP"             # clean up temp file
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

# ─── Session variables SQL (re-resolved per chunk — separate connections) ─────
SESSION_VARS="
SET @visit_diagnoses_cid    = COALESCE((SELECT concept_id FROM concept_name WHERE name = 'Visit Diagnoses'        AND concept_name_type = 'FULLY_SPECIFIED' AND locale_preferred = true AND locale = 'en'), (SELECT concept_id FROM concept_name WHERE name = 'Visit Diagnoses'        AND concept_name_type = 'FULLY_SPECIFIED' AND locale_preferred = true AND locale = 'es'));
SET @coded_diag_cid         = COALESCE((SELECT concept_id FROM concept_name WHERE name = 'Coded Diagnosis'        AND concept_name_type = 'FULLY_SPECIFIED' AND locale_preferred = true AND locale = 'en'), (SELECT concept_id FROM concept_name WHERE name = 'Coded Diagnosis'        AND concept_name_type = 'FULLY_SPECIFIED' AND locale_preferred = true AND locale = 'es'));
SET @noncoded_diag_cid      = COALESCE((SELECT concept_id FROM concept_name WHERE name = 'Non-coded Diagnosis'    AND concept_name_type = 'FULLY_SPECIFIED' AND locale_preferred = true AND locale = 'en'), (SELECT concept_id FROM concept_name WHERE name = 'Non-coded Diagnosis'    AND concept_name_type = 'FULLY_SPECIFIED' AND locale_preferred = true AND locale = 'es'));
SET @certainty_cid          = COALESCE((SELECT concept_id FROM concept_name WHERE name = 'Diagnosis Certainty'    AND concept_name_type = 'FULLY_SPECIFIED' AND locale_preferred = true AND locale = 'en'), (SELECT concept_id FROM concept_name WHERE name = 'Diagnosis Certainty'    AND concept_name_type = 'FULLY_SPECIFIED' AND locale_preferred = true AND locale = 'es'));
SET @order_cid              = COALESCE((SELECT concept_id FROM concept_name WHERE name = 'Diagnosis order'        AND concept_name_type = 'FULLY_SPECIFIED' AND locale_preferred = true AND locale = 'en'), (SELECT concept_id FROM concept_name WHERE name = 'Diagnosis order'        AND concept_name_type = 'FULLY_SPECIFIED' AND locale_preferred = true AND locale = 'es'));
SET @confirmed_cid          = COALESCE((SELECT concept_id FROM concept_name WHERE name = 'Confirmed'              AND concept_name_type = 'FULLY_SPECIFIED' AND locale_preferred = true AND locale = 'en'), (SELECT concept_id FROM concept_name WHERE name = 'Confirmed'              AND concept_name_type = 'FULLY_SPECIFIED' AND locale_preferred = true AND locale = 'es'));
SET @primary_cid            = COALESCE((SELECT concept_id FROM concept_name WHERE name = 'Primary'                AND concept_name_type = 'FULLY_SPECIFIED' AND locale_preferred = true AND locale = 'en'), (SELECT concept_id FROM concept_name WHERE name = 'Primary'                AND concept_name_type = 'FULLY_SPECIFIED' AND locale_preferred = true AND locale = 'es'));
SET @secondary_cid          = COALESCE((SELECT concept_id FROM concept_name WHERE name = 'Secondary'              AND concept_name_type = 'FULLY_SPECIFIED' AND locale_preferred = true AND locale = 'en'), (SELECT concept_id FROM concept_name WHERE name = 'Secondary'              AND concept_name_type = 'FULLY_SPECIFIED' AND locale_preferred = true AND locale = 'es'));
SET @bahmni_diag_status_cid = COALESCE((SELECT concept_id FROM concept_name WHERE name = 'Bahmni Diagnosis Status' AND concept_name_type = 'FULLY_SPECIFIED' AND locale_preferred = true AND locale = 'en'), (SELECT concept_id FROM concept_name WHERE name = 'Bahmni Diagnosis Status' AND concept_name_type = 'FULLY_SPECIFIED' AND locale_preferred = true AND locale = 'es'));
SET @status_ruled_out_cid   = COALESCE((SELECT concept_id FROM concept_name WHERE name = 'Ruled Out Diagnosis'   AND concept_name_type = 'FULLY_SPECIFIED' AND locale_preferred = true AND locale = 'en'), (SELECT concept_id FROM concept_name WHERE name = 'Ruled Out Diagnosis'   AND concept_name_type = 'FULLY_SPECIFIED' AND locale_preferred = true AND locale = 'es'));
SET @revised_cid            = COALESCE((SELECT concept_id FROM concept_name WHERE name = 'Bahmni Diagnosis Revised' AND concept_name_type = 'FULLY_SPECIFIED' AND locale_preferred = true AND locale = 'en'), (SELECT concept_id FROM concept_name WHERE name = 'Bahmni Diagnosis Revised' AND concept_name_type = 'FULLY_SPECIFIED' AND locale_preferred = true AND locale = 'es'));
"

# ─── Header ───────────────────────────────────────────────────────────────────
echo ""
echo "============================================================"
echo "  Legacy Diagnosis Migration"
echo "============================================================"
echo ""
echo "  Migrates Visit Diagnoses obs groups into encounter_diagnosis"
echo "  for FHIR compatibility."
echo ""
echo "  - IDEMPOTENT  : obs.uuid copied as encounter_diagnosis.uuid"
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

# ─── Pre-flight: verify all required concept names resolve ────────────────────
# If any concept name is absent from this deployment's dictionary, the SESSION_VARS
# SET statements silently assign NULL. A NULL @*_cid makes conditions like
# "!= @status_ruled_out_cid" always false in MySQL, causing wrong rows to be
# included or excluded without any error.
log "Verifying required concept names in deployment dictionary..."

MISSING_CONCEPTS=$("${MYSQL_CMD[@]}" --skip-column-names -e "
SELECT required_name
FROM (
    SELECT 'Visit Diagnoses'          AS required_name UNION ALL
    SELECT 'Coded Diagnosis'                           UNION ALL
    SELECT 'Non-coded Diagnosis'                       UNION ALL
    SELECT 'Diagnosis Certainty'                       UNION ALL
    SELECT 'Diagnosis order'                           UNION ALL
    SELECT 'Confirmed'                                 UNION ALL
    SELECT 'Primary'                                   UNION ALL
    SELECT 'Secondary'                                 UNION ALL
    SELECT 'Bahmni Diagnosis Status'                   UNION ALL
    SELECT 'Ruled Out Diagnosis'                       UNION ALL
    SELECT 'Bahmni Diagnosis Revised'
) AS required
WHERE NOT EXISTS (
    SELECT 1 FROM concept_name cn
    WHERE cn.name                = required.required_name
      AND cn.concept_name_type   = 'FULLY_SPECIFIED'
      AND cn.locale_preferred    = true
      AND cn.locale              IN ('en', 'es')
);
" 2>"$STDERR_TMP")
flush_stderr

if [[ -n "$MISSING_CONCEPTS" ]]; then
    echo ""
    echo "  ERROR: The following required concept names were not found in this deployment's dictionary:"
    while IFS= read -r concept; do
        echo "    - $concept"
    done <<< "$MISSING_CONCEPTS"
    echo ""
    echo "  Migration cannot proceed. Verify your OpenMRS concept dictionary."
    echo ""
    exit 1
fi

log "All required concept names verified."
echo ""

# ─── Pre-flight: verify UNIQUE index on encounter_diagnosis.uuid ─────────────
# INSERT IGNORE skips already-migrated rows by relying on this constraint.
# Without it, re-runs silently insert duplicates with no error.
log "Verifying UNIQUE index on encounter_diagnosis.uuid..."

HAS_UUID_UNIQUE=$("${MYSQL_CMD[@]}" --skip-column-names -e "
SELECT COUNT(*)
FROM information_schema.statistics
WHERE table_schema = DATABASE()
  AND table_name   = 'encounter_diagnosis'
  AND column_name  = 'uuid'
  AND non_unique   = 0;
" 2>"$STDERR_TMP")
flush_stderr

if [[ "$HAS_UUID_UNIQUE" -eq 0 ]]; then
    echo ""
    echo "  ERROR: No UNIQUE index found on encounter_diagnosis.uuid."
    echo "  INSERT IGNORE idempotency relies on this constraint to skip already-migrated rows."
    echo "  Without it, re-running the migration will create duplicate records."
    echo "  Verify your OpenMRS schema before proceeding."
    echo ""
    exit 1
fi

log "UNIQUE index on encounter_diagnosis.uuid verified."
echo ""

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

    OBS_RANGE=$("${MYSQL_PIPE_CMD[@]}" --skip-column-names 2>"$STDERR_TMP" <<EOF
$SESSION_VARS
SELECT MIN(obs_id), MAX(obs_id)
FROM obs
WHERE concept_id    = @visit_diagnoses_cid
  AND obs_group_id IS NULL
  AND voided        = 0;
EOF
)
    flush_stderr

    AVAIL_MIN=$(echo "$OBS_RANGE" | awk '{print $1}')
    AVAIL_MAX=$(echo "$OBS_RANGE" | awk '{print $2}')

    if [[ -z "$AVAIL_MIN" || "$AVAIL_MIN" == "NULL" || -z "$AVAIL_MAX" || "$AVAIL_MAX" == "NULL" ]]; then
        log "No Visit Diagnoses obs found in this database. Nothing to migrate."
        exit 0
    fi

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

    OBS_RANGE=$("${MYSQL_PIPE_CMD[@]}" --skip-column-names 2>"$STDERR_TMP" <<EOF
$SESSION_VARS
SELECT MIN(parent.obs_id), MAX(parent.obs_id)
FROM obs parent
WHERE parent.concept_id   = @visit_diagnoses_cid
  AND parent.obs_group_id IS NULL
  AND parent.voided        = 0
  AND (
      EXISTS (
          SELECT 1 FROM obs coded
          WHERE coded.obs_group_id = parent.obs_id
            AND coded.concept_id   = @coded_diag_cid
            AND coded.voided       = 0
      ) OR EXISTS (
          SELECT 1 FROM obs noncoded
          WHERE noncoded.obs_group_id = parent.obs_id
            AND noncoded.concept_id   = @noncoded_diag_cid
            AND noncoded.voided       = 0
      )
  )
  AND NOT EXISTS (
      SELECT 1 FROM encounter_diagnosis ed WHERE ed.uuid = parent.uuid
  )
  AND NOT EXISTS (
      SELECT 1 FROM obs status_obs
      WHERE status_obs.obs_group_id = parent.obs_id
        AND status_obs.concept_id   = @bahmni_diag_status_cid
        AND status_obs.value_coded  = @status_ruled_out_cid
        AND status_obs.voided       = 0
  )
  AND NOT EXISTS (
      SELECT 1 FROM obs revised_obs
      INNER JOIN concept_name cn_rev
          ON  cn_rev.concept_id       = revised_obs.value_coded
          AND cn_rev.locale           IN ('en', 'es')
          AND cn_rev.locale_preferred = true
          AND cn_rev.name             = 'True'
      WHERE revised_obs.obs_group_id = parent.obs_id
        AND revised_obs.concept_id   = @revised_cid
        AND revised_obs.voided       = 0
  );
EOF
)
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

# ─── Shared "pending record" predicate ────────────────────────────────────────
# Reused for the dry-run count and for density-based chunk boundaries below —
# keeps both queries counting/scanning the exact same set of rows.
PENDING_PREDICATE="
  parent.concept_id   = @visit_diagnoses_cid
  AND parent.obs_group_id IS NULL
  AND parent.voided        = 0
  $RANGE_CONDITION
  AND (
      EXISTS (
          SELECT 1 FROM obs coded
          WHERE coded.obs_group_id = parent.obs_id
            AND coded.concept_id   = @coded_diag_cid
            AND coded.voided       = 0
      ) OR EXISTS (
          SELECT 1 FROM obs noncoded
          WHERE noncoded.obs_group_id = parent.obs_id
            AND noncoded.concept_id   = @noncoded_diag_cid
            AND noncoded.voided       = 0
      )
  )
  AND NOT EXISTS (
      SELECT 1 FROM encounter_diagnosis ed WHERE ed.uuid = parent.uuid
  )
  AND NOT EXISTS (
      SELECT 1 FROM obs status_obs
      WHERE status_obs.obs_group_id = parent.obs_id
        AND status_obs.concept_id   = @bahmni_diag_status_cid
        AND status_obs.value_coded  = @status_ruled_out_cid
        AND status_obs.voided       = 0
  )
  AND NOT EXISTS (
      SELECT 1 FROM obs revised_obs
      INNER JOIN concept_name cn_rev
          ON  cn_rev.concept_id       = revised_obs.value_coded
          AND cn_rev.locale           IN ('en', 'es')
          AND cn_rev.locale_preferred = true
          AND cn_rev.name             = 'True'
      WHERE revised_obs.obs_group_id = parent.obs_id
        AND revised_obs.concept_id   = @revised_cid
        AND revised_obs.voided       = 0
  )
"

# ─── Dry-run count ────────────────────────────────────────────────────────────
echo "  Counting records pending migration..."
echo ""

DRY_RUN_COUNT=$("${MYSQL_PIPE_CMD[@]}" --skip-column-names 2>"$STDERR_TMP" <<EOF
$SESSION_VARS
SELECT COUNT(*)
FROM obs parent
WHERE $PENDING_PREDICATE;
EOF
)
flush_stderr

# Determine actual start point (resume or fresh)
if [[ -n "$RESUME_FROM_OBS_ID" ]]; then
    START_OBS_ID=$(( RESUME_FROM_OBS_ID + 1 ))
else
    START_OBS_ID=$MIN_OBS_ID
fi

# Estimated chunk count is based on actual pending rows, not raw obs_id span —
# the obs_id range can be sparse (unrelated deletes/cleanup elsewhere in the
# obs table), so ID-range-based estimates can wildly overstate the real work.
TOTAL_CHUNKS=$(( (DRY_RUN_COUNT + CHUNK_SIZE - 1) / CHUNK_SIZE ))
if [[ "$TOTAL_CHUNKS" -eq 0 ]]; then
    TOTAL_CHUNKS=1
fi

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
COUNT_BEFORE=$("${MYSQL_CMD[@]}" --skip-column-names -e "
SELECT COUNT(*) FROM encounter_diagnosis;
" 2>"$STDERR_TMP")
flush_stderr

log "encounter_diagnosis rows before migration: $(fmt_num "$COUNT_BEFORE")"

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

while [[ "$CURRENT_OBS_ID" -le "$MAX_OBS_ID" ]]; do
    # Pick the boundary by actual pending-row density, not raw obs_id arithmetic —
    # obs_id gaps (unrelated deletes/cleanup elsewhere in the obs table) would
    # otherwise make a fixed CHUNK_SIZE window cover far fewer than CHUNK_SIZE
    # real rows, paying full connection/transaction overhead for little work.
    set +e
    CHUNK_END=$("${MYSQL_PIPE_CMD[@]}" --skip-column-names 2>"$STDERR_TMP" <<EOF
$SESSION_VARS
SELECT MAX(t.obs_id) FROM (
    SELECT parent.obs_id
    FROM obs parent
    WHERE $PENDING_PREDICATE
      AND parent.obs_id >= $CURRENT_OBS_ID
      AND parent.obs_id <= $MAX_OBS_ID
    ORDER BY parent.obs_id
    LIMIT $CHUNK_SIZE
) t;
EOF
    )
    BOUNDARY_EXIT=$?
    set -e
    flush_stderr

    if [[ $BOUNDARY_EXIT -ne 0 ]]; then
        log_error "Failed to compute next chunk boundary at obs_id $CURRENT_OBS_ID."
        log_error "See $LOG_FILE for MySQL error details."
        exit 1
    fi

    if [[ -z "$CHUNK_END" || "$CHUNK_END" == "NULL" ]]; then
        log "No more pending records at or after obs_id $(fmt_num "$CURRENT_OBS_ID"). Ending migration early."
        break
    fi

    CHUNK_NUM=$(( CHUNK_NUM + 1 ))

    log "Starting chunk $CHUNK_NUM: obs_id $(fmt_num "$CURRENT_OBS_ID") → $(fmt_num "$CHUNK_END")"

    # Disable set -e so we can capture MySQL exit code manually
    set +e
    CHUNK_OUTPUT=$("${MYSQL_PIPE_CMD[@]}" --skip-column-names 2>"$STDERR_TMP" <<EOF
$SESSION_VARS
START TRANSACTION;
INSERT IGNORE INTO encounter_diagnosis (
    diagnosis_coded, diagnosis_non_coded, encounter_id, patient_id,
    dx_rank, certainty, voided, voided_by, date_voided, void_reason,
    creator, date_created, uuid
)
SELECT
    coded.value_coded,
    noncoded.value_text,
    parent.encounter_id,
    parent.person_id,
    CASE
        WHEN order_obs.value_coded = @primary_cid THEN 1
        WHEN order_obs.value_coded = @secondary_cid THEN 2
        ELSE NULL
    END,
    CASE WHEN certainty_obs.value_coded = @confirmed_cid THEN 'CONFIRMED' ELSE 'PROVISIONAL' END,
    parent.voided,
    NULL,
    NULL,
    NULL,
    parent.creator,
    parent.date_created,
    parent.uuid
FROM obs parent
LEFT JOIN obs coded
    ON  coded.obs_group_id  = parent.obs_id
    AND coded.concept_id    = @coded_diag_cid
    AND coded.voided        = 0
LEFT JOIN obs noncoded
    ON  noncoded.obs_group_id = parent.obs_id
    AND noncoded.concept_id   = @noncoded_diag_cid
    AND noncoded.voided       = 0
LEFT JOIN obs certainty_obs
    ON  certainty_obs.obs_group_id = parent.obs_id
    AND certainty_obs.concept_id   = @certainty_cid
    AND certainty_obs.voided       = 0
LEFT JOIN obs order_obs
    ON  order_obs.obs_group_id = parent.obs_id
    AND order_obs.concept_id   = @order_cid
    AND order_obs.voided       = 0
LEFT JOIN obs status_obs
    ON  status_obs.obs_group_id = parent.obs_id
    AND status_obs.concept_id   = @bahmni_diag_status_cid
    AND status_obs.voided       = 0
LEFT JOIN obs revised_obs
    ON  revised_obs.obs_group_id = parent.obs_id
    AND revised_obs.concept_id   = @revised_cid
    AND revised_obs.voided       = 0
LEFT JOIN concept_name cn_revised
    ON  cn_revised.concept_id       = revised_obs.value_coded
    AND cn_revised.locale           IN ('en', 'es')
    AND cn_revised.locale_preferred = true
WHERE parent.concept_id   = @visit_diagnoses_cid
  AND parent.obs_group_id IS NULL
  AND parent.voided        = 0
  AND (coded.value_coded IS NOT NULL OR noncoded.value_text IS NOT NULL)
  AND (status_obs.obs_id IS NULL OR status_obs.value_coded != @status_ruled_out_cid)
  AND (cn_revised.name IS NULL OR cn_revised.name != 'True')
  AND parent.obs_id BETWEEN $CURRENT_OBS_ID AND $CHUNK_END;
SET @rows = ROW_COUNT();
COMMIT;
SELECT @rows;
EOF
    )
    MYSQL_EXIT=$?
    set -e
    flush_stderr


    if [[ $MYSQL_EXIT -ne 0 ]]; then
        echo ""
        log_error "Chunk $CHUNK_NUM failed — obs_id $CURRENT_OBS_ID → $CHUNK_END"
        log_error "Transaction rolled back. Re-run and choose 'resume' to continue from the last checkpoint."
        log_error "See $LOG_FILE for MySQL error details."
        exit 1
    fi

    log "Chunk $CHUNK_NUM completed successfully."

    # Extract inserted row count from SELECT @rows output
    CHUNK_INSERTED=$(echo "$CHUNK_OUTPUT" | grep -E '^[0-9]+$' | head -1)
    if ! [[ "$CHUNK_INSERTED" =~ ^[0-9]+$ ]]; then
        CHUNK_INSERTED=0
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
COUNT_AFTER=$("${MYSQL_CMD[@]}" --skip-column-names -e "
SELECT COUNT(*) FROM encounter_diagnosis;
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
printf "  │  encounter_diagnosis before  : %-30s│\n" "$(fmt_num "$COUNT_BEFORE")"
printf "  │  encounter_diagnosis after   : %-30s│\n" "$(fmt_num "$COUNT_AFTER")"
printf "  │  Total time elapsed          : %-30s│\n" "$(format_duration "$TOTAL_ELAPSED")"
echo "  └──────────────────────────────────────────────────────────────┘"
echo ""

# Checkpoint removed on clean completion — no resume needed
rm -f "$CHECKPOINT_FILE"
log "Checkpoint removed. Migration finished successfully."

echo ""
