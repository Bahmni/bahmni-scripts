#!/usr/bin/env bash

set -euo pipefail

# --- Parse arguments ---------------------------------------------------------
DB_HOST="127.0.0.1"
DB_PORT="3306"
DB_USER=""
DB_PASS=""
DB_NAME="openmrs"
BACKUP_FILE=""
DOCKER_CONTAINER=""

usage() {
    echo ""
    echo "Usage (direct) : $0 -u <user> [-p <password>] -d <database> -b <backup_file> [-h <host>] [-P <port>]"
    echo "Usage (Docker) : $0 -u <user> [-p <password>] -d <database> -b <backup_file> -c <container>"
    echo ""
    echo "  -u  MySQL username        (required)"
    echo "  -p  MySQL password        (optional — prompted securely if not provided)"
    echo "  -d  Database name         (required)"
    echo "  -b  Backup file path      (required)"
    echo "  -h  Host                  (default: 127.0.0.1, direct mode only)"
    echo "  -P  Port                  (default: 3306,     direct mode only)"
    echo "  -c  Docker container name"
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
        b) BACKUP_FILE="$OPTARG" ;;
        c) DOCKER_CONTAINER="$OPTARG" ;;
        *) usage ;;
    esac
done

if [[ -z "$DB_USER" || -z "$DB_NAME" || -z "$BACKUP_FILE" ]]; then
    usage
fi

# Prompt for password securely if not provided via -p
if [[ -z "$DB_PASS" ]]; then
    read -r -s -p "  Enter password for $DB_USER: " DB_PASS
    echo ""
    echo ""
fi

if [[ -n "$DOCKER_CONTAINER" ]]; then
    MYSQL_CMD="docker exec -e MYSQL_PWD=$DB_PASS $DOCKER_CONTAINER mysql -u $DB_USER $DB_NAME"
else
    MYSQL_CMD="mysql -h $DB_HOST -P $DB_PORT -u $DB_USER -p$DB_PASS $DB_NAME"
fi

# --- Verify backup file ------------------------------------------------------
echo "  Verifying backup file: $BACKUP_FILE"
echo ""

if [[ ! -f "$BACKUP_FILE" ]]; then
    echo "  ERROR: Backup file not found: $BACKUP_FILE"
    echo "  Aborting. Do not proceed without a verified backup."
    echo ""
    exit 1
fi

BACKUP_SIZE=$(wc -c < "$BACKUP_FILE")
if [[ "$BACKUP_SIZE" -eq 0 ]]; then
    echo "  ERROR: Backup file is empty: $BACKUP_FILE"
    echo "  Aborting. Do not proceed without a verified backup."
    echo ""
    exit 1
fi

echo "  Backup file verified. Size: $(du -sh "$BACKUP_FILE" | cut -f1)"
echo ""

# --- Dry run — count rows to be deleted --------------------------------------
echo "  Counting encounter_diagnosis rows that will be deleted..."
echo ""

DELETE_COUNT=$($MYSQL_CMD --skip-column-names -e "
SELECT COUNT(*)
FROM encounter_diagnosis ed
WHERE ed.uuid IN (
    SELECT obs.uuid
    FROM obs
    WHERE obs.concept_id = (
        SELECT concept_id FROM concept_name
        WHERE name = 'Visit Diagnoses'
          AND concept_name_type = 'FULLY_SPECIFIED'
          AND locale_preferred = true
          AND locale = 'en'
    )
    AND obs.obs_group_id IS NULL
);
")

echo "  Rows to be deleted : $DELETE_COUNT"
echo ""

if [[ "$DELETE_COUNT" -eq 0 ]]; then
    echo "  Nothing to roll back. No migrated rows found in encounter_diagnosis."
    echo ""
    exit 0
fi

# --- Confirmation ------------------------------------------------------------
read -r -p "  Delete $DELETE_COUNT rows from encounter_diagnosis? [yes/no]: " CONFIRM
echo ""

if [[ "$CONFIRM" != "yes" ]]; then
    echo "  Rollback cancelled."
    echo ""
    exit 0
fi

# --- Run rollback ------------------------------------------------------------
echo "  Running rollback..."
echo ""

$MYSQL_CMD -e "
DELETE ed
FROM encounter_diagnosis ed
WHERE ed.uuid IN (
    SELECT obs.uuid
    FROM (
        SELECT uuid FROM obs
        WHERE concept_id = (
            SELECT concept_id FROM concept_name
            WHERE name = 'Visit Diagnoses'
              AND concept_name_type = 'FULLY_SPECIFIED'
              AND locale_preferred = true
              AND locale              = 'en'
        )
        AND obs_group_id IS NULL
    ) AS obs
);
"

# --- Verify ------------------------------------------------------------------
REMAINING_COUNT=$($MYSQL_CMD --skip-column-names -e "
SELECT COUNT(*)
FROM encounter_diagnosis ed
WHERE ed.uuid IN (
    SELECT obs.uuid
    FROM obs
    WHERE obs.concept_id = (
        SELECT concept_id FROM concept_name
        WHERE name = 'Visit Diagnoses'
          AND concept_name_type = 'FULLY_SPECIFIED'
          AND locale_preferred = true
          AND locale = 'en'
    )
    AND obs.obs_group_id IS NULL
);
")

if [[ "$REMAINING_COUNT" -ne 0 ]]; then
    echo "  WARNING: $REMAINING_COUNT migrated rows still remain in encounter_diagnosis."
    echo "  Manual investigation required."
    echo ""
else
    echo "  Rollback complete. All $DELETE_COUNT migrated rows removed."
    echo ""
fi

# --- Restore reminder --------------------------------------------------------
echo "  IMPORTANT: The encounter_diagnosis table has been partially"
echo "  rolled back but may still contain inconsistent data."
echo "  Restore from backup to guarantee a clean state:"
echo ""
echo "    mysql -h $DB_HOST -P $DB_PORT -u $DB_USER -p <password> $DB_NAME < $BACKUP_FILE"
echo ""
echo "  After restoring, verify row counts match pre-migration state"
echo "  before reopening the system to users."
echo ""
