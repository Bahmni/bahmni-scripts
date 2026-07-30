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

## 1.5 Document Identifier (masterIdentifier)

Each migrated document receives a **masterIdentifier** to identify it in the new FHIR system.

**Format:** `{PatientID}-{DocumentType}-{ObsID}`

**Examples:**
- `10-Prescription-304018` — Patient 10's Prescription (obs_id 304018)
- `20-Radiology Report-512345` — Patient 20's Radiology Report (obs_id 512345)
- `15-Patient File-89012` — Patient 15's Patient File (obs_id 89012)

**How it's Generated:**
- **Patient ID:** The patient number associated with the document (e.g., patient 10, patient 20)
- **Document Type:** The category of the document (e.g., Prescription, Radiology Report, Patient File)
- **Shortened Obs ID:** A unique number from the database that ensures no two documents share the same identifier

**Why This Format:**
-  **Guaranteed Unique** — obs_id is the database primary key, ensuring no duplicates
-  **User-Meaningful** — Patient ID and document type visible for clinical context
-  **Robust** — Works reliably across migration chunks and resumable migrations
-  **FHIR Compliant** — Serves as FHIR masterIdentifier business identifier

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
./data-migrate-legacy-documents.sh -u <username> -p <password> -d <dbname> [-c <container>]
```

### Interactive Prompts

The script prompts for missing parameters:
* **Docker container** (if `-c` not provided) — leave blank for direct connection
* **Migration mode** (if full mode vs. batch mode not specified via environment) — choose based on dataset size
* **Confirmation** — confirms document count and asks before starting

### What to Expect
* **Dry-run count** — Shows how many documents will be migrated
* **Interactive prompts** — May ask for container name and migration mode if not pre-configured
* **Confirmation prompt** — Confirms record count before starting
* **Progress updates** — Shows chunks processed
* **Completion message** — Total migrated

### If Interrupted
A checkpoint file saves progress. Re-run the script and choose "yes" to resume — no duplicates will be created.

---

## 4. How the Migration Handles Different Scenarios

### Standard Document
Parent obs with file path and category (Prescription, Patient File, Radiology, etc.)
* **Result:** Migrated with category preserved — same category displays in new UI
* **masterIdentifier:** Auto-generated as `{PatientID}-{DocCategory}-{ObsID}`
  - Example: `10-Prescription-304018`, `20-Radiology Report-512345`
  - Guarantees global uniqueness via obs_id primary key
  - Includes patient context for clinical relevance

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
* **Note:** masterIdentifier format remains consistent across re-runs

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
