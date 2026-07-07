#!/usr/bin/env bash
set -euo pipefail

# ─── Argument defaults ────────────────────────────────────────────────────────
DB_HOST="127.0.0.1"
DB_PORT="3306"
DB_USER=""
DB_PASS=""
DB_NAME=""
DOCKER_CONTAINER=""
BACKUP_FILE=""

# ─── Usage ────────────────────────────────────────────────────────────────────
usage() {
    echo ""
    echo "Usage: $0 -b <backup_file> [-h host] [-P port] [-u user] [-p pass] [-d dbname] [-c container]"
    echo ""
    echo "  -b  Path to a verified backup file (required — this operation is irreversible)"
    echo "  Fully interactive — prompts for any other missing required inputs."
    echo ""
    exit 1
}

while getopts "h:P:u:p:d:c:b:" opt; do
    case $opt in
        h) DB_HOST="$OPTARG" ;;
        P) DB_PORT="$OPTARG" ;;
        u) DB_USER="$OPTARG" ;;
        p) DB_PASS="$OPTARG" ;;
        d) DB_NAME="$OPTARG" ;;
        c) DOCKER_CONTAINER="$OPTARG" ;;
        b) BACKUP_FILE="$OPTARG" ;;
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

if [[ -z "$DB_NAME" ]]; then
    read -r -p "  Enter database name   : " DB_NAME
    echo ""
fi

if [[ -z "$DB_PASS" ]]; then
    read -r -s -p "  Enter password for $DB_USER: " DB_PASS
    echo ""
    echo ""
fi

# ─── Require and verify backup file ──────────────────────────────────────────
if [[ -z "$BACKUP_FILE" ]]; then
    echo "  ERROR: A backup file path is required (-b <backup_file>)."
    echo "  Run data-backup-legacy-diagnoses.sh first and pass the path here."
    echo ""
    exit 1
fi

if [[ ! -f "$BACKUP_FILE" ]]; then
    echo "  ERROR: Backup file not found: $BACKUP_FILE"
    echo "  Aborting. Do not proceed without a verified backup."
    echo ""
    exit 1
fi

if [[ $(wc -c < "$BACKUP_FILE") -eq 0 ]]; then
    echo "  ERROR: Backup file is empty: $BACKUP_FILE"
    echo "  Aborting. Do not proceed without a verified backup."
    echo ""
    exit 1
fi

if ! grep -q "^-- Dump completed" "$BACKUP_FILE"; then
    echo "  ERROR: Backup file does not contain a valid mysqldump footer."
    echo "  The dump may be incomplete. Aborting."
    echo ""
    exit 1
fi

echo "  Backup verified: $BACKUP_FILE ($(du -sh "$BACKUP_FILE" | cut -f1))"
echo ""

# ─── Build MySQL commands ─────────────────────────────────────────────────────
if [[ -n "$DOCKER_CONTAINER" ]]; then
    MYSQL_CMD="docker exec -i -e MYSQL_PWD=$DB_PASS $DOCKER_CONTAINER mysql -u $DB_USER $DB_NAME"
else
    MYSQL_CMD="mysql -h $DB_HOST -P $DB_PORT -u $DB_USER -p$DB_PASS $DB_NAME"
fi

# ─── Header & Warning ─────────────────────────────────────────────────────────
echo "============================================================"
echo "  DANGER: Hard Delete Migrated Legacy Diagnoses"
echo "============================================================"
echo "  This script will PERMANENTLY DELETE records from the"
echo "  legacy 'obs' table if their UUID is successfully found"
echo "  in the 'encounter_diagnosis' table."
echo ""
echo "  Both parent 'Visit Diagnoses' and their child records"
echo "  will be hard-deleted to reclaim disk space."
echo "============================================================"
echo ""

# ─── Dry Run: Count targets ───────────────────────────────────────────────────
echo "  Calculating records to be deleted..."

TARGET_COUNTS=$($MYSQL_CMD --skip-column-names <<EOF
SET @visit_diagnoses_cid = (SELECT concept_id FROM concept_name WHERE name = 'Visit Diagnoses' AND concept_name_type = 'FULLY_SPECIFIED' AND locale_preferred = true AND locale = 'en');

SELECT 
    (SELECT COUNT(*) 
     FROM obs o 
     INNER JOIN encounter_diagnosis ed ON ed.uuid = o.uuid 
     WHERE o.concept_id = @visit_diagnoses_cid AND o.obs_group_id IS NULL) AS parent_count,
    (SELECT COUNT(*) 
     FROM obs child
     WHERE child.obs_group_id IN (
         SELECT o.obs_id
         FROM obs o
         INNER JOIN encounter_diagnosis ed ON ed.uuid = o.uuid
         WHERE o.concept_id = @visit_diagnoses_cid AND o.obs_group_id IS NULL
     )) AS child_count;
EOF
)

PARENT_COUNT=$(echo "$TARGET_COUNTS" | awk '{print $1}')
CHILD_COUNT=$(echo "$TARGET_COUNTS" | awk '{print $2}')
TOTAL_COUNT=$(( PARENT_COUNT + CHILD_COUNT ))

echo "  Target Parent Records (Visit Diagnoses) : $PARENT_COUNT"
echo "  Target Child Records (Coded, order, etc): $CHILD_COUNT"
echo "  -------------------------------------------------"
echo "  Total Rows to be PERMANENTLY DELETED    : $TOTAL_COUNT"
echo ""

if [[ "$TOTAL_COUNT" -eq 0 ]]; then
    echo "  No migrated records found in the obs table. Nothing to do!"
    exit 0
fi

# ─── Strict Confirmation ──────────────────────────────────────────────────────
read -r -p "  Type 'YES' to permanently delete these $TOTAL_COUNT rows: " CONFIRM
echo ""

if [[ "$CONFIRM" != "YES" ]]; then
    echo "  Deletion aborted by user. No data was modified."
    exit 0
fi

# ─── Execution ────────────────────────────────────────────────────────────────
echo "  Executing hard deletion..."

# Disable exit on error temporarily to capture MySQL failure gracefully
set +e

$MYSQL_CMD <<EOF
START TRANSACTION;

-- Setup concept IDs for the parent and every child concept written by the migration
SET @visit_diagnoses_cid    = (SELECT concept_id FROM concept_name WHERE name = 'Visit Diagnoses'          AND concept_name_type = 'FULLY_SPECIFIED' AND locale_preferred = true AND locale = 'en');
SET @coded_diag_cid         = (SELECT concept_id FROM concept_name WHERE name = 'Coded Diagnosis'          AND concept_name_type = 'FULLY_SPECIFIED' AND locale_preferred = true AND locale = 'en');
SET @noncoded_diag_cid      = (SELECT concept_id FROM concept_name WHERE name = 'Non-coded Diagnosis'      AND concept_name_type = 'FULLY_SPECIFIED' AND locale_preferred = true AND locale = 'en');
SET @certainty_cid          = (SELECT concept_id FROM concept_name WHERE name = 'Diagnosis Certainty'      AND concept_name_type = 'FULLY_SPECIFIED' AND locale_preferred = true AND locale = 'en');
SET @order_cid              = (SELECT concept_id FROM concept_name WHERE name = 'Diagnosis order'          AND concept_name_type = 'FULLY_SPECIFIED' AND locale_preferred = true AND locale = 'en');
SET @bahmni_diag_status_cid = (SELECT concept_id FROM concept_name WHERE name = 'Bahmni Diagnosis Status'  AND concept_name_type = 'FULLY_SPECIFIED' AND locale_preferred = true AND locale = 'en');
SET @revised_cid            = (SELECT concept_id FROM concept_name WHERE name = 'Bahmni Diagnosis Revised' AND concept_name_type = 'FULLY_SPECIFIED' AND locale_preferred = true AND locale = 'en');

-- 1. Remove obs_relationship rows that reference migrated child obs.
--    Must run before deleting child obs to avoid FK constraint violations.
DELETE FROM obs_relationship
WHERE obs_id IN (
    SELECT child_obs_id FROM (
        SELECT child.obs_id AS child_obs_id
        FROM obs child
        WHERE child.obs_group_id IN (
            SELECT o.obs_id FROM obs o
            INNER JOIN encounter_diagnosis ed ON ed.uuid = o.uuid
            WHERE o.concept_id = @visit_diagnoses_cid AND o.obs_group_id IS NULL
        )
        AND child.concept_id IN (
            @coded_diag_cid, @noncoded_diag_cid, @certainty_cid,
            @order_cid, @bahmni_diag_status_cid, @revised_cid
        )
    ) AS t
)
OR related_obs_id IN (
    SELECT child_obs_id FROM (
        SELECT child.obs_id AS child_obs_id
        FROM obs child
        WHERE child.obs_group_id IN (
            SELECT o.obs_id FROM obs o
            INNER JOIN encounter_diagnosis ed ON ed.uuid = o.uuid
            WHERE o.concept_id = @visit_diagnoses_cid AND o.obs_group_id IS NULL
        )
        AND child.concept_id IN (
            @coded_diag_cid, @noncoded_diag_cid, @certainty_cid,
            @order_cid, @bahmni_diag_status_cid, @revised_cid
        )
    ) AS t2
);

-- 2. Remove obs_relationship rows that reference migrated parent obs.
DELETE FROM obs_relationship
WHERE obs_id IN (
    SELECT o.obs_id FROM obs o
    INNER JOIN encounter_diagnosis ed ON ed.uuid = o.uuid
    WHERE o.concept_id = @visit_diagnoses_cid AND o.obs_group_id IS NULL
)
OR related_obs_id IN (
    SELECT o.obs_id FROM obs o
    INNER JOIN encounter_diagnosis ed ON ed.uuid = o.uuid
    WHERE o.concept_id = @visit_diagnoses_cid AND o.obs_group_id IS NULL
);

-- 3. Hard delete child obs scoped to concept IDs written by the migration only.
--    Does not touch any unrelated obs children under the same parent.
DELETE child FROM obs child
WHERE child.obs_group_id IN (
    SELECT parent_obs_id FROM (
        SELECT o.obs_id AS parent_obs_id
        FROM obs o
        INNER JOIN encounter_diagnosis ed ON ed.uuid = o.uuid
        WHERE o.concept_id = @visit_diagnoses_cid
          AND o.obs_group_id IS NULL
    ) AS migrated_parents
)
AND child.concept_id IN (
    @coded_diag_cid, @noncoded_diag_cid, @certainty_cid,
    @order_cid, @bahmni_diag_status_cid, @revised_cid
);

-- 4. Hard delete the migrated parent obs
DELETE o FROM obs o
INNER JOIN encounter_diagnosis ed ON ed.uuid = o.uuid
WHERE o.concept_id = @visit_diagnoses_cid
  AND o.obs_group_id IS NULL;

COMMIT;
EOF

MYSQL_EXIT=$?
set -e

if [[ $MYSQL_EXIT -ne 0 ]]; then
    echo "  ERROR: MySQL transaction failed. Rollback executed."
    echo "  No data was deleted."
    exit 1
fi

echo "  SUCCESS: $TOTAL_COUNT legacy records were successfully deleted."
echo ""