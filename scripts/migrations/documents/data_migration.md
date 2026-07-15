# Legacy Document Migration

## Table of Contents
1. Background
2. Before You Begin
3. Running the Migration
4. How the Migration Handles Different Scenarios
5. What Is Not Available in the New UI

---

## 1. Background

The old Bahmni UI stores patient documents in the `obs` table as parent-child groups.

The new Bahmni React UI reads documents from FHIR-compatible `document_reference` and `document_reference_content` tables.

Without migration, all historical documents entered through the old UI are invisible in the new UI.

This migration script copies legacy documents from the old table structure into the new tables so historical data is visible in the new UI.

---

## 2. Before You Begin

### Prerequisites
* **Database access** — MySQL username and password with read/write access to OpenMRS database
* **Backup taken** — always take a backup before running the migration

### Take a Backup
```bash
./data-backup-legacy-documents.sh -u <username> -p <password> -d <dbname> -c <container>
```

---

## 3. Running the Migration

### Starting the Script
```bash
./data-migrate-legacy-documents.sh -u <username> -p <password> -d <dbname> -c <container>
```

The script will:
1. Count pending documents
2. Ask for confirmation
3. Migrate in chunks to avoid locks
4. Report results

### What to Expect
* **Dry-run count** — Shows how many documents will be migrated
* **Confirmation prompt** — Confirm before starting
* **Progress updates** — Shows chunks processed
* **Completion message** — Total migrated

### If Interrupted
A checkpoint file saves progress. Re-run the script and choose "yes" to resume — no duplicates will be created.

---

## 4. How the Migration Handles Different Scenarios

### Standard Document
Parent obs with file path and category (Prescription, Patient File, Radiology, etc.)
* **Result:** Migrated with category preserved — same category displays in new UI

### Document with Comments
Child obs has comments/notes attached
* **Result:** Comments stored as description — displays in new UI if configured

### Document without File Path
Child obs is missing the actual file reference
* **Result:** SKIPPED — document without file path cannot be used

### Voided Documents
Obs marked as voided (deleted)
* **Result:** SKIPPED — voided documents are excluded from migration

### Re-running Migration
Migration already completed
* **Result:** No duplicates created — safe to re-run anytime

---

## Optional Cleanup: Removing Old Records

After migration is complete and validated, you can optionally remove the original `obs` records to reclaim space:

```bash
./delete-migrated-legacy-documents.sh -u <username> -p <password> -d <dbname> -c <container>
```

**Important:** This step is optional and irreversible. Only run after sign-off that the migration is complete and validated.

---

## Rollback if Needed

If you need to rollback after migration:

```bash
./data-rollback-legacy-documents.sh -u <username> -p <password> -d <dbname> -b <backup_file> -c <container>
```

This removes the migrated document_reference rows. The original `obs` table remains unchanged.

---

## Support

For issues:
1. Check error messages
2. Ensure backup exists
3. Verify database access
4. Re-run the script — it is safe to re-run
