# Legacy Diagnosis Migration

## Table of Contents
1. Background
2. Before You Begin
3. Running the Migration
4. How the Migration Handles Different Scenarios
5. What Is Not Available in the New UI

---

## 1. Background

The old Bahmni UI stores patient diagnoses in the `obs` (observations) table.

The new Bahmni React UI reads diagnoses from a different table — `encounter_diagnosis` — which is what the FHIR API uses. 

Without migration, all historical diagnoses entered through the old UI are completely invisible in the new UI. 

This migration script copies legacy diagnoses from the old table into the new table so that historical data is visible to clinicians using the new UI.

---

## 2. Before You Begin

### Prerequisites
Before running the migration, ensure the following are in place:

* **MySQL client installed** — required if connecting directly to the database. Verify by running `mysql --version` in your terminal.
* **Docker installed and running** — required if the database is inside a Docker container. Verify by running `docker ps` in your terminal.
* **Database access** — you must have a MySQL username and password with read and write access to the OpenMRS database.
* **Backup taken** — always take a backup before running the migration.

### Take a Backup
Run the backup script before anything else:

```bash
./data-backup-legacy-diagnoses.sh -u <username> -p <password> -d <dbname> -c <container> 
```

The backup protects you if anything goes wrong. The migration script itself is safe to re-run — it will never create duplicates — but having a backup allows a clean rollback if needed.

---

## 3. Running the Migration

> **Important — Do not run multiple instances simultaneously:** Never run this migration script in two or more terminal sessions or environments at the same time against the same database. Concurrent executions can cause  incorrect row counts, and data inconsistencies that cannot be automatically resolved. Always ensure only one instance of the migration is running at a time.

### Starting the Script
Run the script from the migrations directory:

```bash
./data-migrate-legacy-diagnoses.sh -u <username> -p <password> -d <dbname> -c <container> 
```

The script is fully interactive — it will prompt for all required inputs one by one.

### What You See When Running

#### Step 1 — Credentials
The script prompts for all inputs in sequence:

```text
Docker container name (leave blank for direct connection):
Enter MySQL username   :
Enter database name    :
Enter password for ... :
```

* Leave the Docker container name blank if you are connecting directly to the database. Enter the container name if the database is running inside Docker.
* The password is typed securely — no characters are shown on screen.

#### Step 2 — Available Data Range
```text
Available obs_id range : 248 - 887
```
This shows the range of diagnosis records available in the old table. It gives an idea of the volume of historical data.

#### Step 3 — Choose Migration Mode
```text
Select migration type:
1. Full migration  — migrate all pending records
2. Batch migration — specify an obs_id range
```

* Choose **Full migration** for smaller datasets or during a maintenance window.
* Choose **Batch migration** for very large datasets where running everything at once might slow down the database. You specify a start and end range, run the migration, then run it again with the next range until all records are done.

#### Step 4 — Dry-run Count
```text
Counting all records pending migration...

Records pending migration : 42
```
Before inserting anything, the script counts exactly how many records are ready to be migrated. 

This count excludes records that have already been migrated, deleted diagnoses handled differently, and old superseded versions of edited diagnoses. 

If the count is `0`, the script exits with: `Nothing to migrate. All records are already up to date.`

#### Step 5 — Confirmation
```text
Proceed with migrating 42 records? [yes/no]:
```
Type `yes` to proceed or `no` to cancel. Nothing is written to the database until you confirm.

#### Step 6 — Migration Runs
```text
Running migration...
```
The migration inserts records into `encounter_diagnosis`. If the script is interrupted (server restart, network issue), simply re-run — already-migrated records are automatically skipped. No manual cleanup is needed.

#### Step 7 — Summary
Shows how many records were inserted in this run in the new table:
1. Rows inserted this run
2. Chunks processed
3. `encounter_diagnosis` before
4. `encounter_diagnosis` after
5. Total time elapsed

### Batch Migration Example
If you have 30,000 records and want to migrate in batches of 10,000:
* **Run 1** → start: 1, end: 10000 → 9,800 records migrated
* **Run 2** → start: 10001, end: 20000 → 10,000 records migrated
* **Run 3** → start: 20001, end: 30000 → 9,500 records migrated (remaining)

Already-migrated records from previous runs are always skipped automatically.

---

## 4. How the Migration Handles Different Scenarios

### Active Diagnosis
A diagnosis the clinician entered normally and has not been deleted, edited, or marked inactive.
* **What happens:** Migrated into the new table and visible in the new UI exactly as entered.

### Deleted Diagnosis
A diagnosis the clinician explicitly deleted from the patient record in the old UI. When a diagnosis is deleted, all its child obs (coded diagnosis, certainty, order etc.) are voided in the database.
* **What happens:** Not migrated. The migration only processes obs groups that have an active (non-voided) coded or non-coded diagnosis child. Since all children are voided for deleted diagnoses, they are automatically excluded. Deleted diagnoses will not appear in the new UI.

### Inactive Diagnosis (Ruled Out Diagnosis)
A diagnosis the clinician marked as inactive using the `Bahmni Diagnosis Status = Ruled Out Diagnosis` option in the old UI. In the old UI this appeared with a strikethrough.
* **What happens:** Not migrated at all. The new UI has no equivalent way to display a strikethrough diagnosis — the `encounter_diagnosis` table has no column for clinical status beyond the voided flag. Excluding these records is the safest approach to avoid them appearing as active diagnoses in the new UI.

### Edited Diagnosis
When a clinician edits a diagnosis from a past encounter in the old UI, the old Bahmni system:
1. Keeps the original diagnosis record and marks it as superseded.
2. Creates a new diagnosis record in the current encounter with the updated information.

This means at any point in time, only one version of the diagnosis is the "current" version — the most recent edit.
* **What happens:** Only the latest version is migrated. All older superseded versions are skipped. The clinician sees the most up-to-date diagnosis in the new UI, not a history of every edit.

> **Important — edit after migration:** If the migration runs first and then the clinician edits a diagnosis in the old UI, the new version created by the edit will be picked up the next time the migration runs. However, the original migrated record will remain unchanged in the new table (it carries the data from before the edit). To correct this, the original migrated record should be removed from `encounter_diagnosis` and the migration re-run.

---

## 5. What Is Not Available in the New UI

### Primary / Secondary Diagnosis Order
* **Old UI:** Each diagnosis was clearly labelled as Primary or Secondary.
* **New UI:** The conditions display widget does not have a column for diagnosis order. 

Although the migration correctly stores `Primary = 1` and `Secondary = 2` in the database, this information is never shown to the clinician. Additionally, any diagnosis saved or edited through the new UI will have its order reset to Primary regardless of its original value.

### Strikethrough for Ruled Out / Inactive Diagnoses
* **Old UI:** Diagnoses marked as `Ruled Out Diagnosis` (status) were shown with a strikethrough line through the diagnosis name, giving the clinician a visual indication that it was ruled out.
* **New UI:** There is no strikethrough rendering. `Ruled Out Diagnosis` status records are excluded from migration entirely.

The clinician will not see any visual indication of the ruled out status — the diagnosis simply does not appear.

### Important — Migration Is a One-Time Operation
This migration must be run once, before clinicians begin using the new UI. 

Once the migration has been run and clinicians have switched to the new UI:
* **Any diagnosis edited in the old UI after migration** will not be automatically reflected in the new table. The already-migrated row carries the data from before the edit. The new version created by the edit will be picked up if the migration is re-run — but the original stale row will remain unchanged in `encounter_diagnosis` unless manually removed first.
* **Any diagnosis deleted in the old UI after migration** will not be removed from `encounter_diagnosis`. The migrated row remains in the new table and continues to appear in the new UI even though the clinician deleted it in the old UI.
* **Any new diagnosis added in the old UI after migration** will be picked up by re-running the migration.

**The migration script takes no responsibility for data consistency if the old UI continues to be used after migration.** The recommended approach is to complete the migration, validate the data, and then switch all clinicians to the new UI. Continued parallel use of both UIs will lead to data inconsistencies that cannot be automatically resolved.

---

## 6. Optional Cleanup: Removing Migrated Records from the obs Table

> **This step is outside the scope of the JIRA migration specification.**
> The migration requirement states that records must persist in the `obs` table as the audit trail. The cleanup script described below is an **optional, irreversible** step and must only be run with explicit clinical and compliance sign-off.

After migration, the legacy diagnosis records remain in the `obs` table. This is by design — the `obs` table serves as the audit trail and the migration does not touch it.

If, after a sufficient retention period and with explicit clinical and compliance approval, you wish to reclaim disk space by removing the migrated records from `obs`, run:

```bash
./delete-migrated-legacy-diagnoses.sh -b <backup_file> -u <username> -p <password> -d <dbname> -c <container>
```

### Prerequisites Before Running the Delete Script

* **Backup verified** — the `-b <backup_file>` flag is mandatory. Pass the path to a backup created by `data-backup-legacy-diagnoses.sh`. The script verifies the backup contains a valid mysqldump footer before proceeding.
* **Migration complete and validated** — the delete script removes obs records that have a matching UUID in `encounter_diagnosis`. Ensure the migration has been fully run and validated first.
* **Clinical and compliance sign-off obtained** — this operation permanently removes patient clinical data from the `obs` table. Obtain explicit written sign-off from the appropriate clinical and compliance stakeholders before proceeding.
* **Sufficient retention period observed** — do not run this immediately after migration. Allow adequate time for validation, rollback if needed, and compliance review.
* **No rollback possible after deletion** — the rollback script (`data-rollback-legacy-diagnoses.sh`) restores `encounter_diagnosis` records but cannot restore hard-deleted `obs` rows. After running the delete script, the `obs` audit trail for migrated diagnoses is permanently gone.

### What the Delete Script Does

1. Clears any `obs_relationship` rows referencing the migrated obs (to avoid FK constraint violations).
2. Hard-deletes child obs under each migrated parent, scoped only to the concept IDs written by the migration (`Coded Diagnosis`, `Non-coded Diagnosis`, `Diagnosis Certainty`, `Diagnosis order`, `Bahmni Diagnosis Status`, `Bahmni Diagnosis Revised`).
3. Hard-deletes the migrated parent (`Visit Diagnoses`) obs rows whose UUID exists in `encounter_diagnosis`.

All three steps run inside a single transaction — if any step fails, the entire delete is rolled back and no data is removed.