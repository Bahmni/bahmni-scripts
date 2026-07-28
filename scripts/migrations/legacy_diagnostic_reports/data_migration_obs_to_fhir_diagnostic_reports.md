# Obs to FHIR Diagnostic Report Migration

## Table of Contents
1. Background
2. Before You Begin
3. Running the Migration
4. How the Migration Handles Different Scenarios
5. Important Notes and Limitations

---

## 1. Background

Bahmni stores lab results as observation groups in the `obs` table. Each group consists of a parent observation (representing the test panel or result set) and one or more child observations (individual result values). A special child observation with concept `LAB_REPORT` may also be present, carrying a reference to the uploaded report document.

The FHIR API reads lab results from a different set of tables:

| Table | Purpose |
|---|---|
| `fhir_diagnostic_report` | One row per result group — the report header |
| `fhir_diagnostic_report_results` | One row per child result observation |
| `fhir_diagnostic_report_performers` | Provider resolved from the obs creator |
| `fhir_diagnostic_report_service_request` | Link to the originating lab order |
| `fhir_diagnostic_report_presented_form` | Link to the uploaded document attachment, when present |
| `fhir_diag_report_migration_log` | Batch tracking — identifies which rows this script created, enabling safe rollback |

Without migration, all historical lab results entered through the old Bahmni UI are invisible to any FHIR consumer (including the new React UI). This migration script copies existing lab result obs groups into the FHIR tables so that historical data is accessible without loss.

> **New React UI data does not need migration.** When results are entered through the new React UI, it writes directly to both the `obs` table and the FHIR tables simultaneously. This migration is only for historical data entered through the old Bahmni UI, which wrote only to the `obs` table.

### Which obs records are migrated

Only obs where **`obs_group_id IS NULL` AND `order_id IS NOT NULL`** are migrated. The `order_id IS NOT NULL` filter is the key discriminator: in Bahmni, lab result obs groups are always linked to a lab order via `order_id`. Diagnoses, vitals, and any other obs group types do not carry an `order_id` and are excluded automatically.

**Accession-based results** (obs entered in the old Bahmni UI without linking to a lab order, where `order_id IS NULL`) are not migrated by this script. Only order-linked lab results are in scope.

### Obs Hierarchy Depth

Bahmni stores lab result obs in hierarchical groups. The depth of the hierarchy varies by test configuration. This script handles up to **4 levels deep**:

```
Level 0  root obs (obs_group_id IS NULL, order_id IS NOT NULL)
Level 1    └── intermediate group obs (no value)
Level 2          └── intermediate group obs (no value)
Level 3                ├── LAB_MINNORMAL obs  (excluded)
                       ├── actual result obs  (value_numeric / value_text / etc.)  ← included
                       └── LAB_MAXNORMAL obs  (excluded)
```

The script runs three INSERT passes for `fhir_diagnostic_report_results`: one for each depth level (direct children, grandchildren, great-grandchildren). Only obs that carry an actual value are included at any level. Structural group obs with no value are skipped automatically.

### Excluded Obs Concepts

The following Bahmni-internal concepts are always excluded from `fhir_diagnostic_report_results` at every depth level:

| Concept | Reason |
|---|---|
| `LAB_REPORT` | Document attachment reference — migrated to `fhir_diagnostic_report_presented_form` instead |
| `LAB_MAXNORMAL` | Reference range upper bound metadata — not a clinical result value |
| `LAB_MINNORMAL` | Reference range lower bound metadata — not a clinical result value |

If any of these concepts is not configured in the database, the corresponding session variable resolves to NULL and the exclusion is silently skipped with no impact on the migration.

### Field Mapping Summary

| FHIR Column | Source | Notes |
|---|---|---|
| `fhir_diagnostic_report.status` | `COALESCE(obs.status, 'FINAL')` | Uses the obs status field; pre-2.x records with no status column default to FINAL |
| `fhir_diagnostic_report.concept_id` | `obs.concept_id` | Concept of the root obs group (the test panel) |
| `fhir_diagnostic_report.subject_id` | `obs.person_id` | Patient |
| `fhir_diagnostic_report.encounter_id` | `obs.encounter_id` | Encounter linked to the result |
| `fhir_diagnostic_report.issued` | `obs.obs_datetime` | Date/time the result was recorded |
| `fhir_diagnostic_report.conclusion` | `obs.comments` | Free-text result summary |
| `fhir_diagnostic_report.uuid` | `obs.uuid` | Preserved for idempotency |
| Audit fields (creator, date_created, etc.) | Corresponding `obs` fields | Copied directly |
| `fhir_diagnostic_report_results.obs_id` | `obs.obs_id` of result obs at depth 1, 2, or 3 that carry an actual value | LAB_REPORT, LAB_MAXNORMAL, LAB_MINNORMAL, and all valueless structural obs are excluded |
| `fhir_diagnostic_report_performers.provider_id` | `obs.creator → users.person_id → provider.provider_id` | The user who recorded the result, resolved to their provider record |
| `fhir_diagnostic_report_service_request.order_id` | `obs.order_id` | All migrated obs have order_id by definition |
| `fhir_diagnostic_report_presented_form.document_attachment_id` | LAB_REPORT child obs → `document_attachment.content_url` | Via `document_attachment.content_url = lab_obs.value_complex` |

---

## 2. Before You Begin

### Prerequisites

Before running the migration, ensure the following are in place:

* **Schema migrations applied** — the following tables and columns must exist before running this script. Apply the corresponding Liquibase changesets first:
  * `fhir_diagnostic_report` with the `conclusion` column
  * `fhir_diagnostic_report_results`
  * `fhir_diagnostic_report_performers`
  * `fhir_diagnostic_report_service_request`
  * `fhir_diagnostic_report_presented_form`
* **MySQL client installed** — required if connecting directly to the database. Verify by running `mysql --version` in your terminal.
* **Docker installed and running** — required if the database is inside a Docker container. Verify by running `docker ps` in your terminal.
* **Database access** — you must have a MySQL username and password with read and write access to the OpenMRS database.
* **Backup taken** — always take a backup before running the migration.

### Run the Migration Before the React UI Goes Live

Run this migration **before** clinicians begin entering new lab results through the React UI. The React UI writes directly to the FHIR tables, and it currently looks up existing DiagnosticReports by patient and concept rather than by ServiceRequest. If it finds an already-migrated DiagnosticReport for the same patient and concept, it may update that report in place rather than creating a separate one for the new order — overwriting the migrated result. See the Known Limitation in Section 5 for details.

### Take a Backup

Run the backup script before anything else:

```bash
./data-backup-obs-to-fhir-diagnostic-reports.sh -u <username> -p <password> -d <dbname> -c <container>
```

The backup protects you if anything goes wrong. The migration script itself is safe to re-run — it will never create duplicates — but having a backup allows a clean rollback if needed.

---

## 3. Running the Migration

> **Important — Do not run multiple instances simultaneously:** Never run this migration script in two or more terminal sessions or environments at the same time against the same database. Concurrent executions can cause incorrect row counts and data inconsistencies that cannot be automatically resolved. Always ensure only one instance of the migration is running at a time.

### Starting the Script

Run the script from the migrations directory:

```bash
./data-migrate-obs-to-fhir-diagnostic-reports.sh -u <username> -p <password> -d <dbname> -c <container>
```

The script is fully interactive — it will prompt for all required inputs one by one.

### What You See When Running

#### Step 1 — Credentials

The script prompts for all inputs in sequence:

```text
Docker container name (leave blank for direct connection):
Enter MySQL username  :
Enter database name   :
Enter password for ...:
```

* Leave the Docker container name blank if you are connecting directly to the database. Enter the container name if the database is running inside Docker.
* The password is typed securely — no characters are shown on screen.

#### Step 2 — Checkpoint Detection

If a previous run was interrupted, the script detects a saved checkpoint and offers to resume:

```text
Checkpoint found — last scanned obs_id: 45,000
Batch ID in checkpoint               : a4b2c3d4-e29b-41d4-a716-446655440000

Resume from checkpoint? [yes/no]:
```

* Choose `yes` to continue from where the last run stopped. The same batch ID is reused so all chunks belong to a single batch in the migration log.
* Choose `no` to discard the checkpoint and restart with a new batch ID. All records are re-evaluated; already-migrated rows are silently skipped by `INSERT IGNORE`.

#### Step 3 — Choose Migration Mode

```text
Select migration type:
  1. Full migration  — migrate all pending lab result obs
  2. Batch migration — specify an obs_id range
```

* Choose **Full migration** for smaller datasets or during a maintenance window.
* Choose **Batch migration** for very large datasets where running everything at once might slow down the database. Specify a start and end obs_id, run the migration, then continue with the next range until all records are done.

#### Step 4 — Dry-run Count

```text
Counting lab result obs pending migration...

Lab result obs pending migration : 1,240
obs_id range                     : 101 -> 98,750
Starting from obs_id             : 101
Estimated chunks                 : 10  (10000 rows per chunk)
Batch ID                         : a4b2c3d4-e29b-41d4-a716-446655440000
```

Before inserting anything, the script counts exactly how many lab result obs groups (`order_id IS NOT NULL`) are ready to be migrated. Records already present in `fhir_diagnostic_report` (matched by UUID) are excluded from the count. If the count is `0`, the script exits with: `Nothing to migrate. All lab result records are already up to date.`

#### Step 5 — Confirmation

```text
Proceed with migrating 1,240 lab result obs? [yes/no]:
```

Type `yes` to proceed or `no` to cancel. Nothing is written to the database until you confirm.

#### Step 6 — Migration Runs

```text
  Chunk        | obs_id range                | Inserted    | Elapsed       | ETA
  ─────────────────────────────────────────────────────────────────────────────
      1/10     |          101 →       10,100 |        +312 |  00h 00m 04s  | 00h 00m 36s
      2/10     |       10,101 →       20,100 |        +280 |  00h 00m 08s  | 00h 00m 32s
  ...
```

Each chunk runs eight statements inside a single transaction: the five table INSERTs (with three passes for `fhir_diagnostic_report_results` covering depth levels 1, 2, and 3) plus a batch log INSERT into `fhir_diag_report_migration_log`. If the script is interrupted (server restart, network issue, etc.), simply re-run — it will detect the checkpoint and resume from the last committed chunk using the same batch ID. No manual cleanup is needed.

#### Step 7 — Summary

```text
  +-----------------------------------------------------------------+
  |  MIGRATION SUMMARY                                              |
  +-----------------------------------------------------------------+
  |  Batch ID                              : a4b2c3d4-e29b-41d4... |
  |  Diagnostic reports inserted this run  : 1,240                 |
  |  Chunks processed                      : 10                    |
  |  fhir_diagnostic_report before         : 0                     |
  |  fhir_diagnostic_report after          : 1,240                 |
  |  Total time elapsed                    : 00h 00m 42s           |
  +-----------------------------------------------------------------+

  To roll back this batch run:
    ./data-rollback-obs-to-fhir-diagnostic-reports.sh \
        -u <username> -d <dbname> -b a4b2c3d4-e29b-41d4-...
```

The summary prints the batch ID and the exact rollback command for this run. Record the batch ID — you will need it if a rollback is required later.

### Batch Migration Example

If you have 30,000 lab result obs and want to migrate in batches:

* **Run 1** → start: 1, end: 10,000 → inserts reports for all lab result obs in that range
* **Run 2** → start: 10,001, end: 20,000 → continues with the next range
* **Run 3** → start: 20,001, end: 30,000 → completes the remaining records

Already-migrated records from previous runs are always skipped automatically via `INSERT IGNORE` on the UUID unique constraint. Each batch run gets its own batch ID in `fhir_diag_report_migration_log`.

### Rolling Back

The rollback is surgical — it deletes only rows created by a specific migration batch and does not touch rows that the React UI may have written after the migration.

**If you know the batch ID** (printed in the summary at the end of each run):

```bash
./data-rollback-obs-to-fhir-diagnostic-reports.sh \
    -u <username> -p <password> -d <dbname> -b <batch_id> [-c <container>]
```

**If you do not know the batch ID**, omit `-b` and the script will list all available batches interactively:

```bash
./data-rollback-obs-to-fhir-diagnostic-reports.sh \
    -u <username> -p <password> -d <dbname> [-c <container>]
```

```text
  Available migration batches:

  Batch ID                               | Reports | Started at          | Finished at
  ----------------------------------------------------------------------------------------
  a4b2c3d4-e29b-41d4-a716-446655440000  |   1,240 | 2025-07-06 10:00:00 | 2025-07-06 10:00:42

  Enter batch ID to roll back:
```

The rollback script:
1. Validates the batch ID exists in `fhir_diag_report_migration_log`.
2. Shows the count of rows that will be deleted.
3. Requires explicit `YES` confirmation before deleting anything.
4. Deletes rows from all five FHIR tables for that batch only (child tables first to respect FK order).
5. Removes the batch entries from `fhir_diag_report_migration_log`.
6. Does **not** modify the `obs` table.

---

## 4. How the Migration Handles Different Scenarios

### Standard Lab Result Group (2-level)

A top-level obs where `obs_group_id IS NULL` and `order_id IS NOT NULL`, where result obs are direct children of the root.

* **What happens:** The root obs becomes one row in `fhir_diagnostic_report`. Its status is taken from `obs.status` (defaulting to FINAL if NULL). Each direct child obs that carries an actual value (value_numeric, value_text, value_coded, value_datetime, or value_complex is not null) becomes a row in `fhir_diagnostic_report_results`. Valueless structural children and LAB_MAXNORMAL/LAB_MINNORMAL/LAB_REPORT obs are excluded. A service request row links the report to the lab order. The obs creator is resolved to a provider and inserted into `fhir_diagnostic_report_performers`.

### Nested Lab Result Group (3-level)

A top-level obs where result values are stored as grandchildren via one intermediate sub-group obs.

```
root obs  →  sub-group (no value)  →  result obs (value)
```

* **What happens:** The root obs is migrated to `fhir_diagnostic_report` as normal. The intermediate sub-group child (no value) is excluded from `fhir_diagnostic_report_results`. Its children that carry actual values are included instead.

### Deeply Nested Lab Result Group (4-level)

A top-level obs where result values are stored as great-grandchildren via two intermediate sub-group obs — the structure used by some Bahmni single-result panel configurations.

```
root obs  →  sub-group (no value)  →  sub-group (no value)  →  result obs (value)
```

Alongside the actual result, Bahmni stores reference range metadata at the same depth level:

```
root  →  sub-group  →  sub-group  →  LAB_MINNORMAL (value 0)   excluded
                                  →  actual result (value X)    included
                                  →  LAB_MAXNORMAL (value 0)   excluded
```

* **What happens:** The two intermediate sub-group obs are excluded from results. The script's Level 3 pass finds the great-grandchildren. LAB_MINNORMAL and LAB_MAXNORMAL obs are filtered out by concept. Only the actual result obs is inserted into `fhir_diagnostic_report_results`. The reference range for the result is derived at query time from the ConceptNumeric definition, not from these obs.

### Obs Not Linked to a Lab Order (Diagnoses, Vitals, Accession-Based Results)

An obs group where `order_id IS NULL`.

* **What happens:** Skipped entirely. The `order_id IS NOT NULL` filter excludes diagnoses, vitals, and any lab result entered through the old Bahmni accession workflow without linking to a formal order. These obs are never evaluated, never counted in the dry-run, and never inserted.

### Obs Group With a LAB_REPORT Child

A lab result group that includes a child observation with concept `LAB_REPORT`, indicating a document was uploaded as the report (e.g., a scanned PDF).

* **What happens:** The parent obs is migrated normally. The LAB_REPORT child is used to resolve the corresponding `document_attachment` record, which is inserted into `fhir_diagnostic_report_presented_form`. The LAB_REPORT obs itself is excluded from `fhir_diagnostic_report_results` since it is a document reference, not a result value.
* **If `LAB_REPORT` concept is not configured:** The `@lab_report_cid` session variable resolves to NULL. The LAB_REPORT exclusion and presented form steps are silently skipped. All other tables are still populated correctly.

### Obs Creator Has No Provider Record

A lab result where the user who entered it (`obs.creator`) has no corresponding row in the `provider` table.

* **What happens:** The performer step produces no row for this report. All other tables are still populated. The FHIR DiagnosticReport is visible but has no performer listed.

### Voided Obs Group

A parent obs that has been voided (e.g., the result was entered in error).

* **What happens:** The obs group is migrated into `fhir_diagnostic_report` with its voided status, voided_by, date_voided, and void_reason fields preserved from the obs record. Voided reports remain in the FHIR table but are not returned by the FHIR API to consumers.

### Already-Migrated Record (Re-run)

A lab result obs whose UUID is already present in `fhir_diagnostic_report`.

* **What happens:** `INSERT IGNORE` silently skips the row for all steps. No duplicate is created, no error is raised, and the existing FHIR record is not modified. The script can be safely re-run at any time.

### React UI Records During Rollback

A `fhir_diagnostic_report` row that was created by the new React UI after the migration ran (not by this script).

* **What happens:** The rollback script only deletes rows whose `diagnostic_report_id` appears in `fhir_diag_report_migration_log` for the target batch. React UI rows are not in the log and are never deleted.

---

## 5. Important Notes and Limitations

### Obs Table Is Not Modified

This migration is read-only with respect to the `obs` table. No obs records are updated, voided, or deleted. The obs data remains the source of truth in OpenMRS.

### Only Order-Linked Lab Result Obs Are Migrated

The filter `obs_group_id IS NULL AND order_id IS NOT NULL` selects exclusively lab result obs groups that are linked to a lab order. Diagnoses, vitals, and lab results entered via the old Bahmni accession workflow (where `order_id IS NULL`) are automatically excluded regardless of obs_id range or migration mode. Accession-based historical results require a separate migration strategy (e.g., manually linking those obs to their corresponding orders before re-running this script).

### Obs Hierarchy Up to 4 Levels Deep

The migration handles Bahmni obs structures up to 4 levels deep (root → L1 → L2 → L3 result). If your data contains obs hierarchies deeper than 4 levels, the result obs at those deeper levels will not be migrated. Verify the depth of your obs hierarchy before running by inspecting the `obs_group_id` chain for a sample of lab results.

### Reference Range Metadata Obs Are Excluded

Bahmni stores reference range bounds as sibling obs alongside the actual result (`LAB_MAXNORMAL`, `LAB_MINNORMAL`). These are excluded from `fhir_diagnostic_report_results` because they are metadata, not clinical result values. The FHIR reference range for numeric results is derived from the `ConceptNumeric` definition at query time.

### Migration Is Idempotent

The migration can be re-run as many times as needed. Already-migrated obs groups are identified by UUID (`INSERT IGNORE` on the unique uuid constraint) and skipped. New lab result obs added after the last run will be picked up on the next run.

### Batch Tag Enables Safe Rollback

Every run generates a unique batch ID. All `fhir_diagnostic_report` rows created in that run are recorded in `fhir_diag_report_migration_log` against that batch ID. This means:
- The rollback script deletes only the rows for the selected batch.
- Rows written by the React UI after migration are never affected.
- The batch ID is printed in the migration summary and in the rollback command at the end of every run. Record it.

### Status Reflects Obs Status, Not Always FINAL

`fhir_diagnostic_report.status` is set to `COALESCE(obs.status, 'FINAL')`. Lab results already in PRELIMINARY or another status in the obs table will carry that status into the FHIR table. Only obs records that pre-date the `obs.status` column (NULL) are defaulted to FINAL.

### Performer Comes From the Obs Creator

`fhir_diagnostic_report_performers` is populated by resolving `obs.creator → users → provider`. If the creator user has no provider record (for example, the OpenMRS `daemon` system user used in test/seed data), no performer row is inserted for that report — this is correct behaviour. In production, lab results are entered by lab technicians who have provider records. Provider lookup uses `provider.person_id = users.person_id WHERE provider.retired = 0`.

### Schema Migrations Must Run First

The following schema objects must be created by Liquibase changesets before running this migration:
- `fhir_diagnostic_report.conclusion` column
- `fhir_diagnostic_report_service_request` table
- `fhir_diagnostic_report_presented_form` table

The `fhir_diag_report_migration_log` table is created automatically by the migration script itself (`CREATE TABLE IF NOT EXISTS`).

### Document Attachment Lookup

The `fhir_diagnostic_report_presented_form` step links to `document_attachment` via:

```sql
JOIN document_attachment da ON da.content_url = lab_obs.value_complex
```

The LAB_REPORT child obs stores the attachment URL in `obs.value_complex`; `document_attachment.content_url` holds the matching URL. There is no `obs_id` foreign key on the `document_attachment` table. If `value_complex` is NULL or does not match any `content_url`, the step inserts 0 rows for that report with no error — the migration continues normally.

### No Child Obs Created as FHIR Observations

This migration only populates the diagnostic report and its reference tables. Child obs referenced by `fhir_diagnostic_report_results` must also be reachable as FHIR Observation resources for the FHIR API to return them in a report bundle. Ensure the FHIR Observation layer is functional before exposing migrated reports to consumers.

### Known Limitation — React UI May Overwrite Migrated Reports

The new React UI currently looks up existing DiagnosticReports by **patient and concept** when a clinician enters a new lab result. If a migrated DiagnosticReport already exists for the same patient and concept, the React UI may update that report in place rather than creating a separate DiagnosticReport for the new order. This causes the migrated result to be replaced with the newly entered value and the service request link to be updated to the new order.

**Affected scenario:** A patient has two separate lab orders for the same test concept (e.g., two orders for "Absolute Eosinophil Count Test"). The migration creates one DiagnosticReport per order. When a clinician enters a result for the second order through the React UI, the system finds the first migrated DiagnosticReport and overwrites it instead of creating a new one.

**Consequence:** After the React UI entry, `fhir_diagnostic_report_service_request` for the migrated report will show the new order_id, and `fhir_diagnostic_report_results` will point to the new result obs — the original migrated result is lost from the FHIR layer (the underlying obs data in the `obs` table is unaffected).

**Recommended mitigation:** Run this migration **before** clinicians begin entering results through the React UI for the migrated patients. This is a known issue in the FHIR module's DiagnosticReport creation logic; a fix requires the React UI to match DiagnosticReports by ServiceRequest UUID rather than by patient+concept.

### Migration Does Not Cover Post-Migration Changes

Once this migration has been run:

* **New lab result obs** added after the run will be picked up by re-running the migration.
* **Obs updated after migration** (e.g., `obs.comments` edited) will not be reflected in the already-migrated `fhir_diagnostic_report` row. The FHIR record is a snapshot taken at migration time.
* **Obs voided after migration** will not have their FHIR record automatically voided. The migrated row remains with `voided = 0`.

**The recommended approach** is to run the migration once, validate the output, and switch consumers to the FHIR API. For ongoing synchronisation, a real-time FHIR translator (rather than a one-time migration script) is required.
