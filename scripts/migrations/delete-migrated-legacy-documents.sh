#!/usr/bin/env bash
set -euo pipefail

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
    echo "Usage: $0 [-h host] [-P port] [-u user] [-p pass] [-d dbname] [-c container]"
    echo ""
    echo "  Fully interactive — prompts for any missing required inputs."
    echo ""
    exit 1
}

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

# ─── Build MySQL commands ─────────────────────────────────────────────────────
if [[ -n "$DOCKER_CONTAINER" ]]; then
    MYSQL_CMD="docker exec -i -e MYSQL_PWD=$DB_PASS $DOCKER_CONTAINER mysql -u $DB_USER $DB_NAME"
else
    MYSQL_CMD="mysql -h $DB_HOST -P $DB_PORT -u $DB_USER -p$DB_PASS $DB_NAME"
fi

# ─── Header & Warning ─────────────────────────────────────────────────────────
echo "============================================================"
echo "  DANGER: Hard Delete Migrated Legacy Documents"
echo "============================================================"
echo "  This script will PERMANENTLY DELETE records from the"
echo "  legacy 'obs' table if their UUID is successfully found"
echo "  in the 'document_reference' table."
echo ""
echo "  Both parent document obs and their child file records"
echo "  will be hard-deleted to reclaim disk space."
echo "============================================================"
echo ""

# ─── Dry Run: Count targets ───────────────────────────────────────────────────
echo "  Calculating records to be deleted..."

TARGET_COUNTS=$($MYSQL_CMD --skip-column-names <<EOF
SELECT
    (SELECT COUNT(*)
     FROM obs o
     INNER JOIN document_reference dr ON dr.uuid = o.uuid
     WHERE o.obs_group_id IS NULL) AS parent_count,
    (SELECT COUNT(*)
     FROM obs child
     WHERE child.obs_group_id IN (
         SELECT o.obs_id
         FROM obs o
         INNER JOIN document_reference dr ON dr.uuid = o.uuid
         WHERE o.obs_group_id IS NULL
     )) AS child_count;
EOF
)

PARENT_COUNT=$(echo "$TARGET_COUNTS" | awk '{print $1}')
CHILD_COUNT=$(echo "$TARGET_COUNTS" | awk '{print $2}')
TOTAL_COUNT=$(( PARENT_COUNT + CHILD_COUNT ))

echo "  Target Parent Records (Document obs)    : $PARENT_COUNT"
echo "  Target Child Records (File paths)       : $CHILD_COUNT"
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

-- 1. Hard delete all CHILD observations (document files) belonging to migrated parents
DELETE FROM obs
WHERE obs_group_id IN (
    SELECT parent_obs_id FROM (
        SELECT o.obs_id AS parent_obs_id
        FROM obs o
        INNER JOIN document_reference dr ON dr.uuid = o.uuid
        WHERE o.obs_group_id IS NULL
    ) AS migrated_parents
);

-- 2. Hard delete all PARENT observations (document records)
DELETE FROM obs
WHERE obs_group_id IS NULL
  AND uuid IN (
      SELECT uuid FROM document_reference
  );

COMMIT;
EOF

DELETION_EXIT=$?
set -e

if [[ $DELETION_EXIT -ne 0 ]]; then
    echo "  ERROR: Deletion failed. Transaction rolled back."
    echo "  Check logs above for MySQL error details."
    exit 1
fi

# --- Verify ------------------------------------------------------------------
REMAINING_PARENT=$($MYSQL_CMD --skip-column-names -e "
SELECT COUNT(*)
FROM obs o
INNER JOIN document_reference dr ON dr.uuid = o.uuid
WHERE o.obs_group_id IS NULL;
")

REMAINING_CHILD=$($MYSQL_CMD --skip-column-names -e "
SELECT COUNT(*)
FROM obs child
WHERE child.obs_group_id IN (
    SELECT o.obs_id
    FROM obs o
    INNER JOIN document_reference dr ON dr.uuid = o.uuid
    WHERE o.obs_group_id IS NULL
);
")

REMAINING_TOTAL=$(( REMAINING_PARENT + REMAINING_CHILD ))

if [[ "$REMAINING_TOTAL" -ne 0 ]]; then
    echo "  WARNING: $REMAINING_TOTAL rows still remain in obs table."
    echo "  Parents: $REMAINING_PARENT | Children: $REMAINING_CHILD"
    echo "  Manual investigation required."
    echo ""
else
    echo "  Hard deletion complete. All $TOTAL_COUNT legacy obs rows removed."
    echo "  Disk space has been reclaimed."
    echo ""
fi

# --- Summary ─────────────────────────────────────────────────────────────────
echo "  ┌─────────────────────────────────────────────────┐"
echo "  │  DELETION SUMMARY                               │"
echo "  ├─────────────────────────────────────────────────┤"
printf "  │  Parent rows deleted        : %-25s│\n" "$PARENT_COUNT"
printf "  │  Child rows deleted         : %-25s│\n" "$CHILD_COUNT"
printf "  │  Total rows deleted         : %-25s│\n" "$TOTAL_COUNT"
printf "  │  Remaining in obs           : %-25s│\n" "$REMAINING_TOTAL"
echo "  └─────────────────────────────────────────────────┘"
echo ""
