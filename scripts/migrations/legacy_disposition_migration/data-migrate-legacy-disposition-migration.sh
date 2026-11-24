#!/usr/bin/env bash
set -euo pipefail

# ─── Constants ────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EMRAPI_SOURCE="org.openmrs.module.emrapi"
DISPOSITION_CODE="Disposition"
DISPOSITION_NOTE_CODE="DispositionNote"
ADT_ORDER_TYPE_NAME="ADT Order"
ADT_DISPOSITION_RULES_PROPERTY="fhir2Extension.adtDispositionRules"
DISPOSITION_CODES="ADMIT DISCHARGE TRANSFER UNDO_DISCHARGE"

# ─── Argument defaults ────────────────────────────────────────────────────────
DB_HOST="127.0.0.1"
DB_PORT="3306"
DB_USER=""
DB_PASS=""
DB_NAME=""
DOCKER_CONTAINER=""
CHUNK_SIZE="2000"

# ─── Usage ────────────────────────────────────────────────────────────────────
usage() {
    echo ""
    echo "Usage: $0 [-h host] [-P port] [-u user] [-p pass] [-d dbname] [-c container] [-s chunk_size]"
    echo ""
    echo "  Fully interactive — prompts for any missing required inputs."
    echo ""
    echo "  Migrates legacy disposition Observations (Disposition Concept Set:"
    echo "  Disposition + Disposition Note) into new orders rows of type"
    echo "  'ADT Order', so BAH-5067's Disposition widget (which reads"
    echo "  ServiceRequests/orders only, no dual read of Observations) shows"
    echo "  historical dispositions alongside newly created ones."
    echo ""
    echo "  -s chunk_size : rows processed per obs_id-range chunk/transaction"
    echo "                  (default: 2000, must be a positive integer)"
    echo ""
    echo "  This script does not own backup logic —"
    echo "  data-backup-legacy-disposition-migration.sh does. It will optionally"
    echo "  offer to run that script for you before migrating."
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
# Prevents two simultaneous runs from colliding on the same obs/orders rows.
# Uses a PID file instead of flock so it works on macOS (bash 3.2) and Linux.
# Scoped to the target database — parallel runs against different DBs are fine.
LOCK_FILE="/tmp/legacy_disposition_migration_${DB_NAME}.lock"

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
LOG_FILE="$SCRIPT_DIR/migration_BAH-5286_$(date +%Y%m%d).log"
CHECKPOINT_FILE="$SCRIPT_DIR/legacy_disposition_checkpoint_${DB_NAME}.txt"
THIS_RUN_HAD_ERRORS=false

# ─── Helper functions ─────────────────────────────────────────────────────────
format_duration() {
    local secs=$1
    printf "%02dh %02dm %02ds" $(( secs / 3600 )) $(( (secs % 3600) / 60 )) $(( secs % 60 ))
}

fmt_num() {
    printf "%'d" "$1"
}

STDERR_TMP=$(mktemp /tmp/legacy_disposition_migration_stderr.XXXXXX)

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
echo "  BAH-5286: Legacy Disposition Observation Migration"
echo "============================================================"
echo ""
echo "  Migrates legacy disposition Observations into 'ADT Order' orders:"
echo "    Disposition obs (value_coded = Admit/Discharge/Transfer/Undo"
echo "    Discharge) + sibling Disposition Note obs (same obs_group_id)"
echo "    -> one new orders row per Disposition obs"
echo ""
echo "  - SCOPE      : non-voided Disposition obs only (emrapi code 'Disposition')"
echo "  - MODE       : Full (all pending) or Batch (specify an obs_id range)"
echo "  - CHUNKED    : processed in obs_id-range chunks of $(fmt_num "$CHUNK_SIZE"), one transaction per chunk"
echo "  - IDEMPOTENT : legacy_disposition_migration_log.source_obs_id is unique;"
echo "                 re-running inserts 0 new rows for already-migrated obs"
echo "  - READ-ONLY  : obs is only ever read, never modified or voided"
echo "  - FULFILLER  : fulfiller_status is set to COMPLETED only if a real"
echo "                 fulfilling encounter (per fhir2Extension.adtDispositionRules,"
echo "                 same rule the live duplicate-order check uses) already"
echo "                 happened after the disposition date in that visit — e.g. an"
echo "                 Admit is COMPLETED only once an ADMISSION encounter followed"
echo "                 it. Otherwise fulfiller_status is left NULL (open), matching"
echo "                 what BAH-5066 leaves on a newly created, not-yet-fulfilled"
echo "                 disposition today."
echo "  - BATCH LOG  : each run tags a batch ID; roll back with data-rollback-legacy-disposition-migration.sh -b <batch_id>"
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

# ─── Required OpenMRS prerequisites ────────────────────────────────────────────
ADT_ORDER_TYPE_ID=$("${MYSQL_PIPE_CMD[@]}" --skip-column-names 2>"$STDERR_TMP" <<EOF
SELECT order_type_id FROM order_type WHERE name = '$ADT_ORDER_TYPE_NAME' AND retired = 0 LIMIT 1;
EOF
)
flush_stderr

if [[ -z "$ADT_ORDER_TYPE_ID" ]]; then
    log_error "OrderType '$ADT_ORDER_TYPE_NAME' not found. This is seeded by bahmni-core liquibase changeset bah-5197-add-adt-order-type-20261007 — upgrade bahmni-core before running this migration."
    exit 1
fi

OUTPATIENT_CARE_SETTING_ID=$("${MYSQL_PIPE_CMD[@]}" --skip-column-names 2>"$STDERR_TMP" <<EOF
SELECT care_setting_id FROM care_setting WHERE care_setting_type = 'OUTPATIENT' AND retired = 0 LIMIT 1;
EOF
)
flush_stderr

if [[ -z "$OUTPATIENT_CARE_SETTING_ID" ]]; then
    log_error "No OUTPATIENT care_setting found. This is a core OpenMRS seed and should always exist."
    exit 1
fi

DISPOSITION_CONCEPT_ID=$("${MYSQL_PIPE_CMD[@]}" --skip-column-names 2>"$STDERR_TMP" <<EOF
SELECT crm.concept_id
FROM concept_reference_map crm
JOIN concept_reference_term crt ON crt.concept_reference_term_id = crm.concept_reference_term_id
JOIN concept_reference_source crs ON crs.concept_source_id = crt.concept_source_id
WHERE crs.name = '$EMRAPI_SOURCE' AND crt.code = '$DISPOSITION_CODE'
LIMIT 1;
EOF
)
flush_stderr

DISPOSITION_NOTE_CONCEPT_ID=$("${MYSQL_PIPE_CMD[@]}" --skip-column-names 2>"$STDERR_TMP" <<EOF
SELECT crm.concept_id
FROM concept_reference_map crm
JOIN concept_reference_term crt ON crt.concept_reference_term_id = crm.concept_reference_term_id
JOIN concept_reference_source crs ON crs.concept_source_id = crt.concept_source_id
WHERE crs.name = '$EMRAPI_SOURCE' AND crt.code = '$DISPOSITION_NOTE_CODE'
LIMIT 1;
EOF
)
flush_stderr
DISPOSITION_NOTE_CONCEPT_ID=${DISPOSITION_NOTE_CONCEPT_ID:-0}

if [[ -z "$DISPOSITION_CONCEPT_ID" ]]; then
    log "No concept mapped to emrapi code '$DISPOSITION_CODE' — nothing to migrate (is the emrapi Disposition concept set installed?)."
    exit 0
fi

log "ADT Order order_type_id=$ADT_ORDER_TYPE_ID, Outpatient care_setting_id=$OUTPATIENT_CARE_SETTING_ID, Disposition concept_id=$DISPOSITION_CONCEPT_ID"

# ─── Fulfillment rules (fhir2Extension.adtDispositionRules) ────────────────────
# A migrated order should read as COMPLETED, not open/active, if the
# disposition it represents was actually carried out — e.g. an Admit is only
# "done" once the patient was really admitted (an ADMISSION encounter exists
# after it in the same visit). This mirrors DispositionOrderLifecycleServiceImpl
# .isFulfilled(), which reads the same global property for the live
# duplicate-order check, so a migrated order's completeness is judged by the
# exact same rule as a brand-new one.
ADT_RULES_JSON=$("${MYSQL_PIPE_CMD[@]}" --skip-column-names 2>"$STDERR_TMP" <<EOF
SELECT property_value FROM global_property WHERE property = '$ADT_DISPOSITION_RULES_PROPERTY' LIMIT 1;
EOF
)
flush_stderr

if [[ -z "$ADT_RULES_JSON" || "$ADT_RULES_JSON" == "NULL" ]]; then
    log_error "Global property '$ADT_DISPOSITION_RULES_PROPERTY' is not configured. Cannot determine fulfiller_status for migrated orders — refusing to guess. Configure this GP (same one BAH-5066/5197 require) before running the migration."
    exit 1
fi

# For each code, resolve: the fulfilling encounter_type_ids (comma-separated,
# or empty if none configured / the type doesn't exist) and whether
# fulfillment is detected by voiding rather than by a plain encounter date.
# Kept as plain shell variables (not an associative array) for bash 3.2
# compatibility (macOS), same constraint already followed by the rest of this
# migration and by medication_notes_migration/.
for CODE in $DISPOSITION_CODES; do
    ENC_TYPE_NAMES_JSON=$("${MYSQL_PIPE_CMD[@]}" --skip-column-names 2>"$STDERR_TMP" <<EOF
SELECT JSON_EXTRACT('$ADT_RULES_JSON', '\$."$CODE".fulfilledByEncounterTypes');
EOF
)
    flush_stderr

    ENC_TYPE_IDS=""
    if [[ -n "$ENC_TYPE_NAMES_JSON" && "$ENC_TYPE_NAMES_JSON" != "NULL" ]]; then
        ENC_TYPE_IDS=$("${MYSQL_PIPE_CMD[@]}" --skip-column-names 2>"$STDERR_TMP" <<EOF
SELECT GROUP_CONCAT(et.encounter_type_id)
FROM encounter_type et
JOIN JSON_TABLE('$ENC_TYPE_NAMES_JSON', '\$[*]' COLUMNS (name VARCHAR(255) PATH '\$')) names
  ON names.name = et.name
WHERE et.retired = 0;
EOF
)
        flush_stderr
    fi

    FULFILLED_BY_VOIDING=$("${MYSQL_PIPE_CMD[@]}" --skip-column-names 2>"$STDERR_TMP" <<EOF
SELECT COALESCE(JSON_EXTRACT('$ADT_RULES_JSON', '\$."$CODE".fulfilledByVoiding'), 'false');
EOF
)
    flush_stderr

    case "$CODE" in
        ADMIT) ADMIT_ENC_TYPE_IDS="$ENC_TYPE_IDS"; ADMIT_BY_VOIDING="$FULFILLED_BY_VOIDING" ;;
        DISCHARGE) DISCHARGE_ENC_TYPE_IDS="$ENC_TYPE_IDS"; DISCHARGE_BY_VOIDING="$FULFILLED_BY_VOIDING" ;;
        TRANSFER) TRANSFER_ENC_TYPE_IDS="$ENC_TYPE_IDS"; TRANSFER_BY_VOIDING="$FULFILLED_BY_VOIDING" ;;
        UNDO_DISCHARGE) UNDO_DISCHARGE_ENC_TYPE_IDS="$ENC_TYPE_IDS"; UNDO_DISCHARGE_BY_VOIDING="$FULFILLED_BY_VOIDING" ;;
    esac
    log "Fulfillment rule for $CODE: encounter_type_ids=[${ENC_TYPE_IDS:-none}] byVoiding=${FULFILLED_BY_VOIDING:-false}"
done

# Normalize to SQL-safe values: a non-matching id list (-1) so the IN(...)
# clause is always valid SQL, and a 0/1 flag instead of the JSON 'true'/'false'
# string JSON_EXTRACT returned.
[[ -z "$ADMIT_ENC_TYPE_IDS" ]] && ADMIT_ENC_TYPE_IDS="-1"
[[ -z "$DISCHARGE_ENC_TYPE_IDS" ]] && DISCHARGE_ENC_TYPE_IDS="-1"
[[ -z "$TRANSFER_ENC_TYPE_IDS" ]] && TRANSFER_ENC_TYPE_IDS="-1"
[[ -z "$UNDO_DISCHARGE_ENC_TYPE_IDS" ]] && UNDO_DISCHARGE_ENC_TYPE_IDS="-1"
[[ "$ADMIT_BY_VOIDING" == *true* ]] && ADMIT_BY_VOIDING_FLAG=1 || ADMIT_BY_VOIDING_FLAG=0
[[ "$DISCHARGE_BY_VOIDING" == *true* ]] && DISCHARGE_BY_VOIDING_FLAG=1 || DISCHARGE_BY_VOIDING_FLAG=0
[[ "$TRANSFER_BY_VOIDING" == *true* ]] && TRANSFER_BY_VOIDING_FLAG=1 || TRANSFER_BY_VOIDING_FLAG=0
[[ "$UNDO_DISCHARGE_BY_VOIDING" == *true* ]] && UNDO_DISCHARGE_BY_VOIDING_FLAG=1 || UNDO_DISCHARGE_BY_VOIDING_FLAG=0

# Single SQL expression reused in every chunk's INSERT, deciding fulfiller_status
# per row from its disposition code and the rules resolved above. A disposition
# is COMPLETED only if a real fulfilling encounter (or, for Undo Discharge, a
# voided Discharge encounter) happened after it in the same visit — otherwise
# NULL (open), same as a freshly created, not-yet-fulfilled live disposition.
# This intentionally scopes to encounters sharing the source encounter's
# visit_id; it does not replicate the live service's extra handling of
# visit-less encounters within the visit's time window (a narrow edge case —
# see data_migration.md Section 5).
fulfiller_status_case_expr() {
    cat <<SQL
CASE
  WHEN p.disposition_code = 'ADMIT' AND EXISTS (
    SELECT 1 FROM encounter fe
    WHERE fe.visit_id = p.visit_id
      AND fe.encounter_type IN ($ADMIT_ENC_TYPE_IDS)
      AND fe.voided = $ADMIT_BY_VOIDING_FLAG
      AND (CASE WHEN $ADMIT_BY_VOIDING_FLAG = 1 THEN fe.date_voided ELSE fe.encounter_datetime END) > p.date_activated
  ) THEN 'COMPLETED'
  WHEN p.disposition_code = 'DISCHARGE' AND EXISTS (
    SELECT 1 FROM encounter fe
    WHERE fe.visit_id = p.visit_id
      AND fe.encounter_type IN ($DISCHARGE_ENC_TYPE_IDS)
      AND fe.voided = $DISCHARGE_BY_VOIDING_FLAG
      AND (CASE WHEN $DISCHARGE_BY_VOIDING_FLAG = 1 THEN fe.date_voided ELSE fe.encounter_datetime END) > p.date_activated
  ) THEN 'COMPLETED'
  WHEN p.disposition_code = 'TRANSFER' AND EXISTS (
    SELECT 1 FROM encounter fe
    WHERE fe.visit_id = p.visit_id
      AND fe.encounter_type IN ($TRANSFER_ENC_TYPE_IDS)
      AND fe.voided = $TRANSFER_BY_VOIDING_FLAG
      AND (CASE WHEN $TRANSFER_BY_VOIDING_FLAG = 1 THEN fe.date_voided ELSE fe.encounter_datetime END) > p.date_activated
  ) THEN 'COMPLETED'
  WHEN p.disposition_code = 'UNDO_DISCHARGE' AND EXISTS (
    SELECT 1 FROM encounter fe
    WHERE fe.visit_id = p.visit_id
      AND fe.encounter_type IN ($UNDO_DISCHARGE_ENC_TYPE_IDS)
      AND fe.voided = $UNDO_DISCHARGE_BY_VOIDING_FLAG
      AND (CASE WHEN $UNDO_DISCHARGE_BY_VOIDING_FLAG = 1 THEN fe.date_voided ELSE fe.encounter_datetime END) > p.date_activated
  ) THEN 'COMPLETED'
  ELSE NULL
END
SQL
}

# ─── Migration log table ──────────────────────────────────────────────────────
# One row per source Disposition obs actually migrated. uk_source_obs is the
# idempotency guard — since this migration INSERTs new orders rows rather
# than UPDATEing existing ones (unlike BAH-4996), there is no NULL-column
# guard available on `orders` itself, so this table is the only way to know
# an obs was already migrated. It also gives the rollback script exactly
# which orders a given batch created.
log "Creating legacy_disposition_migration_log table if not exists..."
"${MYSQL_PIPE_CMD[@]}" 2>"$STDERR_TMP" <<'INITSQL'
CREATE TABLE IF NOT EXISTS legacy_disposition_migration_log (
    id                  INT AUTO_INCREMENT PRIMARY KEY,
    batch_id            VARCHAR(36) NOT NULL,
    source_obs_id       INT         NOT NULL,
    source_obs_uuid     VARCHAR(38) NOT NULL,
    migrated_order_id   INT         NOT NULL,
    migrated_order_uuid VARCHAR(38) NOT NULL,
    migrated_at         DATETIME    NOT NULL,
    UNIQUE KEY uk_source_obs (source_obs_id),
    UNIQUE KEY uk_batch_order (batch_id, migrated_order_id),
    INDEX idx_batch_id (batch_id)
);
INITSQL
flush_stderr

# ─── Shared pending-row predicate (reused for dry-run, range detection, chunks) ─
# $1 = obs_id range condition (e.g. "d.obs_id BETWEEN 1 AND 100", or "1=1" for no range filter)
pending_predicate() {
    local range="$1"
    cat <<SQL
(
  SELECT COUNT(*)
  FROM obs d
  WHERE d.concept_id = $DISPOSITION_CONCEPT_ID
    AND d.voided = 0
    AND d.value_coded IS NOT NULL
    AND NOT EXISTS (SELECT 1 FROM legacy_disposition_migration_log log WHERE log.source_obs_id = d.obs_id)
    AND $range
)
SQL
}

# ─── Dry-run count (whole table, no range filter) ─────────────────────────────
echo "  Counting records pending migration..."
echo ""

PENDING_COUNT=$("${MYSQL_PIPE_CMD[@]}" --skip-column-names 2>"$STDERR_TMP" <<EOF
SELECT $(pending_predicate "1=1");
EOF
)
flush_stderr

VOIDED_SKIPPED=$("${MYSQL_PIPE_CMD[@]}" --skip-column-names 2>"$STDERR_TMP" <<EOF
SELECT COUNT(*) FROM obs d WHERE d.concept_id = $DISPOSITION_CONCEPT_ID AND d.voided = 1;
EOF
)
flush_stderr

echo "  Legacy disposition obs pending migration : $(fmt_num "$PENDING_COUNT")"
echo "  Voided disposition obs (always skipped)  : $(fmt_num "$VOIDED_SKIPPED")"
echo ""

if [[ "$PENDING_COUNT" -eq 0 ]]; then
    log "Nothing to migrate. All records are already up to date."
    exit 0
fi

# ─── Full pending obs_id range (used for Full mode + shown as a hint in Batch mode) ─
FULL_RANGE_ROW=$("${MYSQL_PIPE_CMD[@]}" --skip-column-names 2>"$STDERR_TMP" <<EOF
SELECT MIN(d.obs_id), MAX(d.obs_id)
FROM obs d
WHERE d.concept_id = $DISPOSITION_CONCEPT_ID
  AND d.voided = 0
  AND d.value_coded IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM legacy_disposition_migration_log log WHERE log.source_obs_id = d.obs_id);
EOF
)
flush_stderr
FULL_MIN_OBS_ID=$(echo "$FULL_RANGE_ROW" | awk '{print $1}')
FULL_MAX_OBS_ID=$(echo "$FULL_RANGE_ROW" | awk '{print $2}')

if [[ -z "$FULL_MIN_OBS_ID" || "$FULL_MIN_OBS_ID" == "NULL" ]]; then
    log "Nothing to migrate. All records are already up to date."
    exit 0
fi

# ─── Checkpoint detection ──────────────────────────────────────────────────────
# A checkpoint (if resumed) carries its own batch_id and obs_id range so a
# resumed run keeps logging to the same batch and the same bounds as before.
BATCH_ID=""
MIN_OBS_ID=""
MAX_OBS_ID=""
START_OBS_ID=""
RESUMED=false

if [[ -f "$CHECKPOINT_FILE" ]]; then
    CP_LAST=$(grep 'Last completed chunk end obs_id' "$CHECKPOINT_FILE" | grep -oE '[0-9]+$' || true)
    CP_BATCH=$(grep 'Batch ID' "$CHECKPOINT_FILE" | sed 's/Batch ID - //' || true)
    CP_MIN=$(grep 'Range Min' "$CHECKPOINT_FILE" | grep -oE '[0-9]+$' || true)
    CP_MAX=$(grep 'Range Max' "$CHECKPOINT_FILE" | grep -oE '[0-9]+$' || true)

    if [[ -n "$CP_LAST" && -n "$CP_BATCH" && -n "$CP_MIN" && -n "$CP_MAX" ]]; then
        echo "  Checkpoint found — last completed chunk ended at obs_id $(fmt_num "$CP_LAST")."
        echo "  Batch ID in checkpoint : $CP_BATCH"
        echo "  Range in checkpoint    : $(fmt_num "$CP_MIN") - $(fmt_num "$CP_MAX")"
        read -r -p "  Resume from checkpoint? [yes/no]: " RESUME_CONFIRM
        echo ""
        if [[ "$RESUME_CONFIRM" == "yes" ]]; then
            BATCH_ID="$CP_BATCH"
            MIN_OBS_ID="$CP_MIN"
            MAX_OBS_ID="$CP_MAX"
            START_OBS_ID=$(( CP_LAST + 1 ))
            RESUMED=true
            if [[ "$START_OBS_ID" -gt "$MAX_OBS_ID" ]]; then
                log "Checkpoint is already past its range. Nothing left to resume."
                rm -f "$CHECKPOINT_FILE"
                exit 0
            fi
            log "Resuming batch $BATCH_ID from obs_id $(fmt_num "$START_OBS_ID")"
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
    echo "    2. Batch migration — specify an obs_id range"
    echo ""
    read -r -p "  Enter choice [1/2]: " MIGRATION_TYPE
    echo ""

    if [[ "$MIGRATION_TYPE" == "2" ]]; then
        echo "  Available pending obs_id range : $(fmt_num "$FULL_MIN_OBS_ID") - $(fmt_num "$FULL_MAX_OBS_ID")"
        echo ""
        read -r -p "  Enter start obs_id : " MIN_OBS_ID
        read -r -p "  Enter end obs_id   : " MAX_OBS_ID
        echo ""

        if ! [[ "$MIN_OBS_ID" =~ ^[0-9]+$ && "$MAX_OBS_ID" =~ ^[0-9]+$ ]]; then
            echo "  ERROR: obs_id values must be numeric and valid."
            echo ""
            exit 1
        fi

        if [[ "$MIN_OBS_ID" -gt "$MAX_OBS_ID" ]]; then
            echo "  ERROR: start obs_id must be <= end obs_id."
            echo ""
            exit 1
        fi

        log "Batch mode: obs_id $(fmt_num "$MIN_OBS_ID") -> $(fmt_num "$MAX_OBS_ID")"
    elif [[ "$MIGRATION_TYPE" == "1" ]]; then
        MIN_OBS_ID="$FULL_MIN_OBS_ID"
        MAX_OBS_ID="$FULL_MAX_OBS_ID"
        log "Full mode: pending obs_id range $(fmt_num "$MIN_OBS_ID") -> $(fmt_num "$MAX_OBS_ID")"
    else
        echo "  ERROR: Invalid choice. Enter 1 or 2."
        echo ""
        exit 1
    fi

    START_OBS_ID="$MIN_OBS_ID"

    # Fresh batch ID for this run (not resuming).
    BATCH_ID=$("${MYSQL_PIPE_CMD[@]}" --skip-column-names 2>/dev/null <<<"SELECT UUID();" | tr -d '[:space:]')
    if [[ -z "$BATCH_ID" ]]; then
        BATCH_ID="batch_$(date +%Y%m%d_%H%M%S)"
    fi
fi

# ─── Scoped dry-run count for the chosen range ────────────────────────────────
RANGE_DRY_RUN_COUNT=$("${MYSQL_PIPE_CMD[@]}" --skip-column-names 2>"$STDERR_TMP" <<EOF
SELECT $(pending_predicate "d.obs_id BETWEEN $MIN_OBS_ID AND $MAX_OBS_ID");
EOF
)
flush_stderr

if [[ "$RANGE_DRY_RUN_COUNT" -eq 0 && "$RESUMED" == "false" ]]; then
    log "Nothing to migrate in obs_id range $MIN_OBS_ID - $MAX_OBS_ID."
    exit 0
fi

TOTAL_CHUNKS=$(( (MAX_OBS_ID - START_OBS_ID) / CHUNK_SIZE + 1 ))

echo "  Obs_id range             : $(fmt_num "$START_OBS_ID") - $(fmt_num "$MAX_OBS_ID")"
echo "  Rows pending in range     : $(fmt_num "$RANGE_DRY_RUN_COUNT")"
echo "  Chunk size                : $(fmt_num "$CHUNK_SIZE")"
echo "  Estimated chunks          : $(fmt_num "$TOTAL_CHUNKS")"
echo "  Batch ID                  : $BATCH_ID"
echo ""

# ─── Confirm ──────────────────────────────────────────────────────────────────
read -r -p "  Proceed with migration? [yes/no]: " CONFIRM
echo ""

if [[ "$CONFIRM" != "yes" ]]; then
    log "Migration cancelled by user."
    exit 0
fi

# ─── Optional backup ──────────────────────────────────────────────────────────
# This script does not take its own backup — data-backup-legacy-disposition-migration.sh
# owns that logic (single source of truth, matches the other migrations' convention
# of a standalone backup script). It can optionally be invoked here for convenience,
# using the same connection details already gathered above.
BACKUP_SCRIPT="$SCRIPT_DIR/data-backup-legacy-disposition-migration.sh"
BACKUP_FILE=""

if [[ ! -e "$BACKUP_SCRIPT" ]]; then
    log_error "Backup script not found at $BACKUP_SCRIPT — cannot offer a pre-migration backup."
    read -r -p "  Continue WITHOUT a backup? [yes/no]: " CONTINUE_NO_BACKUP
    echo ""
    if [[ "$CONTINUE_NO_BACKUP" != "yes" ]]; then
        log "Migration cancelled by user (no backup available)."
        exit 0
    fi
elif [[ ! -x "$BACKUP_SCRIPT" ]]; then
    log_error "Backup script found but is not executable: $BACKUP_SCRIPT (run: chmod +x \"$BACKUP_SCRIPT\")."
    read -r -p "  Continue WITHOUT a backup? [yes/no]: " CONTINUE_NO_BACKUP
    echo ""
    if [[ "$CONTINUE_NO_BACKUP" != "yes" ]]; then
        log "Migration cancelled by user (no backup available)."
        exit 0
    fi
else
    read -r -p "  Run data-backup-legacy-disposition-migration.sh now before migrating? [yes/no]: " RUN_BACKUP
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
        echo "  Skipping backup — proceeding without one. Run data-backup-legacy-disposition-migration.sh"
        echo "  separately first if you want an extra safety net (rollback itself does not need it —"
        echo "  it is driven by the migration log table, see Section 8 of data_migration.md)."
        echo ""
    fi
fi

# ─── order_number seed ─────────────────────────────────────────────────────────
# Monotonic counter seeded past anything already in `orders`, so generated
# order_numbers never collide with OpenMRS's own ORD-<seed> sequence or with
# a previous run of this script. Prefixed distinctly (ORD-MIG-) so migrated
# orders are trivially identifiable as such if ever needed.
ORDER_NUMBER_SEED=$("${MYSQL_PIPE_CMD[@]}" --skip-column-names 2>"$STDERR_TMP" <<EOF
SELECT COALESCE(MAX(CAST(SUBSTRING_INDEX(order_number, '-', -1) AS UNSIGNED)), 0) + 1
FROM orders WHERE order_number LIKE 'ORD-MIG-%';
EOF
)
flush_stderr
ORDER_NUMBER_SEED=${ORDER_NUMBER_SEED:-1}

# ─── Chunked migration loop ────────────────────────────────────────────────────
echo "  Running migration..."
echo ""

START_TIME=$(date +%s)
CURRENT_OBS_ID="$START_OBS_ID"
TOTAL_MIGRATED=0
CHUNK_NUM=0

while [[ "$CURRENT_OBS_ID" -le "$MAX_OBS_ID" ]]; do
    CHUNK_NUM=$((CHUNK_NUM + 1))
    CHUNK_END=$(( CURRENT_OBS_ID + CHUNK_SIZE - 1 ))
    if [[ "$CHUNK_END" -gt "$MAX_OBS_ID" ]]; then
        CHUNK_END="$MAX_OBS_ID"
    fi

    set +e
    CHUNK_OUTPUT=$("${MYSQL_PIPE_CMD[@]}" --skip-column-names 2>"$STDERR_TMP" <<EOF
START TRANSACTION;

SET @order_number_seed = $ORDER_NUMBER_SEED;
SET @now = NOW();

-- Rows of this chunk still pending, with the answer concept + sibling note
-- resolved. value_coded on the Disposition obs IS the answer concept (Admit
-- Patient / Discharge Patient / Transfer Patient / Undo Discharge) — this is
-- what resolves to ADMIT/DISCHARGE/TRANSFER/UNDO_DISCHARGE via the emrapi
-- mapping already read by DispositionOrderTypeResolverImpl at order-save time.
DROP TEMPORARY TABLE IF EXISTS tmp_pending;
CREATE TEMPORARY TABLE tmp_pending AS
SELECT
    d.obs_id       AS source_obs_id,
    d.uuid         AS source_obs_uuid,
    d.person_id    AS patient_id,
    d.encounter_id AS encounter_id,
    e.visit_id     AS visit_id,
    d.value_coded  AS concept_id,
    d.obs_datetime AS scheduled_date,
    d.date_created AS date_activated,
    d.creator      AS creator_user_id,
    n.value_text   AS note_text,
    crt.code       AS disposition_code,
    (@order_number_seed := @order_number_seed + 1) AS order_seq
FROM obs d
JOIN encounter e ON e.encounter_id = d.encounter_id
LEFT JOIN obs n
    ON n.obs_group_id = d.obs_group_id
   AND n.concept_id = $DISPOSITION_NOTE_CONCEPT_ID
   AND n.voided = 0
LEFT JOIN concept_reference_map crm
    ON crm.concept_id = d.value_coded
LEFT JOIN concept_reference_term crt
    ON crt.concept_reference_term_id = crm.concept_reference_term_id
   AND crt.concept_source_id = (SELECT concept_source_id FROM concept_reference_source WHERE name = '$EMRAPI_SOURCE' LIMIT 1)
WHERE d.concept_id = $DISPOSITION_CONCEPT_ID
  AND d.voided = 0
  AND d.value_coded IS NOT NULL
  AND d.obs_id BETWEEN $CURRENT_OBS_ID AND $CHUNK_END
  AND NOT EXISTS (SELECT 1 FROM legacy_disposition_migration_log log WHERE log.source_obs_id = d.obs_id);

INSERT INTO orders (
    uuid, order_type_id, concept_id, patient_id, encounter_id, care_setting,
    orderer, urgency, scheduled_date, date_activated, comment_to_fulfiller,
    order_number, order_action, creator, date_created, fulfiller_status, voided
)
SELECT
    UUID(),
    $ADT_ORDER_TYPE_ID,
    p.concept_id,
    p.patient_id,
    p.encounter_id,
    $OUTPATIENT_CARE_SETTING_ID,
    -- orderer: the provider record for the obs creator's person, same join
    -- used elsewhere in bahmni-core's direct-SQL provider lookups
    (SELECT pr.provider_id FROM provider pr
       JOIN users u ON u.user_id = p.creator_user_id
      WHERE pr.person_id = u.person_id AND pr.retired = 0
      ORDER BY pr.provider_id LIMIT 1),
    'ON_SCHEDULED_DATE',
    p.scheduled_date,
    p.date_activated,
    p.note_text,
    CONCAT('ORD-MIG-', p.order_seq),
    'NEW',
    1,
    @now,
    $(fulfiller_status_case_expr),
    0
FROM tmp_pending p;
SET @rows_inserted = ROW_COUNT();

-- Pair each newly inserted order back to its source obs via the unique
-- order_number minted for it in this same transaction.
INSERT INTO legacy_disposition_migration_log
    (batch_id, source_obs_id, source_obs_uuid, migrated_order_id, migrated_order_uuid, migrated_at)
SELECT '$BATCH_ID', p.source_obs_id, p.source_obs_uuid, o.order_id, o.uuid, @now
FROM tmp_pending p
JOIN orders o ON o.order_number = CONCAT('ORD-MIG-', p.order_seq);

DROP TEMPORARY TABLE IF EXISTS tmp_pending;

COMMIT;

SELECT @rows_inserted;
EOF
)
    MYSQL_EXIT=$?
    set -e
    flush_stderr

    if [[ $MYSQL_EXIT -ne 0 ]]; then
        log_error "Chunk $CHUNK_NUM failed (obs_id $CURRENT_OBS_ID-$CHUNK_END). Transaction rolled back."
        log_error "Checkpoint preserved at obs_id $(( CURRENT_OBS_ID - 1 )) — re-run this script to resume from here."
        log_error "See $LOG_FILE for MySQL error details."
        exit 1
    fi

    CHUNK_MIGRATED=$(echo "$CHUNK_OUTPUT" | tail -1 | awk '{print $1}')
    [[ "$CHUNK_MIGRATED" =~ ^[0-9]+$ ]] || CHUNK_MIGRATED=0
    TOTAL_MIGRATED=$(( TOTAL_MIGRATED + CHUNK_MIGRATED ))

    # Checkpoint only updated after a successful commit
    {
        echo "Last completed chunk end obs_id - $CHUNK_END"
        echo "Batch ID - $BATCH_ID"
        echo "Range Min - $MIN_OBS_ID"
        echo "Range Max - $MAX_OBS_ID"
    } > "$CHECKPOINT_FILE"
    log "Chunk $CHUNK_NUM/$(fmt_num "$TOTAL_CHUNKS") done (obs_id $(fmt_num "$CURRENT_OBS_ID")-$(fmt_num "$CHUNK_END")): migrated=$CHUNK_MIGRATED"

    CURRENT_OBS_ID=$(( CHUNK_END + 1 ))
done

# Clean finish — remove the checkpoint so a future run starts fresh
rm -f "$CHECKPOINT_FILE"

TOTAL_ELAPSED=$(( $(date +%s) - START_TIME ))

# ─── Summary ──────────────────────────────────────────────────────────────────
echo ""
log "Migration complete."
echo ""
echo "  ┌──────────────────────────────────────────────────────────────┐"
echo "  │  MIGRATION SUMMARY                                            │"
echo "  ├──────────────────────────────────────────────────────────────┤"
printf "  │  Batch ID                             : %-22s│\n" "$BATCH_ID"
printf "  │  Chunks processed                     : %-22s│\n" "$(fmt_num "$CHUNK_NUM")"
printf "  │  Orders created                       : %-22s│\n" "$(fmt_num "$TOTAL_MIGRATED")"
printf "  │  Backup file                          : %-22s│\n" "$( [[ -n "$BACKUP_FILE" ]] && basename "$BACKUP_FILE" || echo "none (skipped)" )"
printf "  │  Total time elapsed                   : %-22s│\n" "$(format_duration "$TOTAL_ELAPSED")"
echo "  └──────────────────────────────────────────────────────────────┘"
echo ""
if [[ -n "$BACKUP_FILE" ]]; then
    echo "  Backup path: $BACKUP_FILE"
    echo ""
fi
echo "  To roll back this batch run:"
if [[ -n "$DOCKER_CONTAINER" ]]; then
    echo "    ./data-rollback-legacy-disposition-migration.sh -u $DB_USER -d $DB_NAME -b $BATCH_ID -c $DOCKER_CONTAINER"
else
    echo "    ./data-rollback-legacy-disposition-migration.sh -u $DB_USER -d $DB_NAME -b $BATCH_ID -h $DB_HOST -P $DB_PORT"
fi
echo ""
