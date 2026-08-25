# BAH-4996: Legacy Medication Order Note Migration

## Table of Contents
1. Background
2. Before You Begin
3. Running the Migration
4. Full vs Batch Mode, Chunking, and Resuming an Interrupted Migration
5. The Two Migration Steps
6. Scoping — Why Drug Orders Only
7. Idempotency
8. Rollback — Batch-Scoped, Log-Driven (Not a Full-Table Restore)
9. Audit Script

---

## 1. Background

Old Bahmni and new Bahmni store the medication order note in different columns
of the shared `orders` table:

* **Old Bahmni** stores the note in `orders.order_reason_non_coded`.
* **New Bahmni** stores the note in `orders.comment_to_fulfiller`, which is
  what the FHIR API maps to `MedicationRequest.note[order-note].text`.

Without migration, legacy medication order notes entered through the old UI
are invisible to the new UI's read path (and to the FHIR API).

This is a **standalone, one-time database migration script** — not a
core-module Liquibase changeset — following the same pattern as the existing
`data-migrate-legacy-diagnoses.sh` script in this repo.

---

## 2. Before You Begin

### Prerequisites

* **MySQL client installed** — required if connecting directly to the
  database. Verify with `mysql --version`.
* **Docker installed and running** — required if the database is inside a
  Docker container. Verify with `docker ps`.
* **Database access** — a MySQL username and password with read and write
  access to the OpenMRS database.
* **Backup is optional but recommended** — rollback here is batch-scoped and
  driven by a migration log table (see Section 8), so a `mysqldump` backup is
  no longer required to undo a run. `data-backup-legacy-stop-notes.sh` still
  exists as an extra safety net and can optionally be invoked from the
  migrate script when prompted (see Section 3).

> **Important — Do not run multiple instances simultaneously:** the script
> uses a lock file (`/tmp/stop_order_notes_migration_<dbname>.lock`) to
> prevent two concurrent runs against the same database. Never bypass this
> unless you are certain no other run is active.

---

## 3. Running the Migration

Four standalone scripts live in this directory, matching the convention used
by the other migrations in this repo (e.g. `legacy_diagnostic_reports/`):

```
data-backup-legacy-stop-notes.sh    — takes a targeted mysqldump of orders + drug_order (optional safety net)
data-migrate-legacy-stop-notes.sh   — dry-run, choose Full/Batch, confirm, run the 2 UPDATEs
data-rollback-legacy-stop-notes.sh  — batch-scoped undo, driven by the migration log table
data-audit-legacy-stop-notes.sh     — read-only before/after coverage report
```

### Recommended: run the backup script first

```bash
./data-backup-legacy-stop-notes.sh -u <username> -p <password> -d <dbname> -c <container>
```

### Then run the migration

```bash
./data-migrate-legacy-stop-notes.sh -u <username> -p <password> -d <dbname> -c <container>

# Optionally control chunk size (default 5000, must be a positive integer):
./data-migrate-legacy-stop-notes.sh -u <username> -p <password> -d <dbname> -c <container> -s 2000
```

The script is fully interactive — any flag not passed is prompted for. If you
skipped the backup step above, the migrate script will offer to run
`data-backup-legacy-stop-notes.sh` for you (using the same credentials) before
proceeding — see Step 5 below. You can also skip it entirely and take your own
backup through other means.

### What You See When Running

#### Step 1 — Credentials
```text
Docker container name (leave blank for direct connection):
Enter MySQL username  :
Enter database name   :
Enter password for ...:
```
The password is typed securely (no characters shown) and is passed to MySQL
via the `MYSQL_PWD` environment variable — never on the command line.

#### Step 2 — Connectivity check
The script runs a lightweight `SELECT 1;` before doing anything else, so a
wrong container name or bad credentials fail fast.

#### Step 3 — Dry-run counts
```text
DC orders pending step 1         : 42
NEW/REVISE orders pending step 2 : 17
```
Two counts are shown: DC (discontinue) orders pending step 1, and NEW or
REVISE orders pending step 2. If both are zero, the script exits immediately with
`Nothing to migrate. All records are already up to date.` — nothing is
written.

#### Step 3.5 — Checkpoint detection, then Full vs Batch mode
```text
Checkpoint found — last completed chunk ended at order_id 239,755.
Batch ID in checkpoint : 550e8400-e29b-41d4-a716-446655440000
Range in checkpoint    : 4 - 239,791
Resume from checkpoint? [yes/no]:
```
If a previous run was interrupted, a checkpoint prompt appears here — see
Section 4. If you resume, the mode/range from that run is reused automatically
and the prompt below is skipped.

Otherwise (no checkpoint, or you decline to resume), you're asked to choose:
```text
Select migration type:
  1. Full migration  — migrate all pending rows
  2. Batch migration — specify an order_id range
Enter choice [1/2]:
```
Choosing **Batch** shows the full pending `order_id` range as a hint, then
prompts for a start/end `order_id`; only rows in that range are touched. This
is useful for migrating a known slice (e.g. one facility's order_id range) or
for splitting a very large migration into independently-reviewable, separately
rollback-able runs. Choosing **Full** uses the entire pending range, computed
from the *actual* pending rows (not the whole table), so a small amount of
old, already-migrated data scattered across a wide `order_id` span does not
inflate the chunk count. Either way, a fresh batch ID (UUID, or
`batch_YYYYMMDD_HHMMSS` as a fallback) is generated for the run — see
Section 8.

#### Step 4 — Confirmation
```text
Proceed with migration? [yes/no]:
```
Type `yes` to proceed. Anything else cancels with no changes made.

#### Step 5 — Optional backup
```text
Run data-backup-legacy-stop-notes.sh now before migrating? [yes/no]:
```
If you already ran `data-backup-legacy-stop-notes.sh` yourself (recommended),
answer `no` here. Otherwise answer `yes` and the migrate script will invoke it
for you, reusing the same credentials — it takes a `mysqldump` of `orders` and
`drug_order` (both tables are dumped because the migration *reads*
`drug_order` and *writes* `orders`, though the SQL never writes to
`drug_order`), written next to the script as `backup_BAH-4996_<timestamp>.sql`
and validated (non-empty, contains the `-- Dump completed` footer). If the
backup fails validation, the migration aborts with no changes made. If you
answer `no`, migration proceeds without a backup — you won't be able to use
`data-rollback-legacy-stop-notes.sh` afterward unless you took one some other way.

#### Step 6 — Migration runs, one chunk at a time
The pending `order_id` range is split into chunks of `-s` size (default
5,000). Both UPDATE statements (see Section 5) run inside a single
transaction **per chunk**, scoped to that chunk's `order_id` range. If a
chunk's transaction fails, it rolls back automatically and the checkpoint
file preserves progress up to the last *successful* chunk — see Section 4.
Progress logs per chunk:
```text
INFO   Chunk 1/48 done (order_id 4-5,003): step1=0 step2=12
INFO   Chunk 2/48 done (order_id 5,004-10,003): step1=3 step2=0
...
```

#### Step 7 — Summary
```text
┌──────────────────────────────────────────────────────────────┐
│  MIGRATION SUMMARY                                           │
├──────────────────────────────────────────────────────────────┤
│  Batch ID                              : 550e8400-e29b-...   │
│  Chunks processed                      : 48                  │
│  Step 1 rows updated (DC note)         : 42                  │
│  Step 2 rows updated (NEW/REVISE note) : 17                  │
│  Backup file                           : backup_BAH-4996_... │
│  Total time elapsed                    : 00h 00m 01s         │
└──────────────────────────────────────────────────────────────┘

To roll back this batch run:
  ./data-rollback-legacy-stop-notes.sh -u <username> -d <dbname> -b 550e8400-e29b-...
```
Row counts are totals summed across all chunks. The printed rollback command
is ready to copy-paste — see Section 8.

### Where Output Goes

| Destination | What goes there | Persists after the run? |
|---|---|---|
| **Terminal (screen)** | Interactive prompts, dry-run counts, confirmation, migration summary. | No |
| **Log file** (`migration_BAH-4996_YYYYMMDD.log`, next to the script) | Every `INFO` line, plus raw MySQL error output for any failed query. Check this file if the script exits unexpectedly with no visible error. | Yes — one file per calendar day |
| **Backup file** (`backup_BAH-4996_<timestamp>.sql`, next to the script) | An optional targeted `mysqldump` of `orders` and `drug_order`, produced by `data-backup-legacy-stop-notes.sh` (run standalone, or invoked from the migrate script when you answer `yes` at Step 5). Not required for rollback — see Section 8 — but useful as an extra safety net. Absent if you skipped this step. | Yes — kept until you delete it |
| **Checkpoint file** (`stop_notes_checkpoint_<dbname>.txt`, next to the script) | The batch ID, order_id range, and the `order_id` at which the last successfully-committed chunk ended. Only present while a run is incomplete — see Section 4. | Only if the run is interrupted before completing |
| **Migration log table** (`stop_order_notes_migration_log`, in the database) | One row per `(batch_id, order_id, step)` actually updated by any run. Drives the rollback script — see Section 8. | Yes — until rolled back or manually cleared |

---

## 4. Full vs Batch Mode, Chunking, and Resuming an Interrupted Migration

### Full vs Batch mode

Every run is either:
* **Full** — migrates every pending row across the whole table.
* **Batch** — migrates only rows within an `order_id` range you specify.
  Useful for migrating a known slice, staging a large migration as several
  independently-reviewable runs, or re-running just a subset that failed.

Both modes are chunked and checkpointed identically (below); "batch" here
refers to the user-chosen `order_id` scope, not the chunk size. Every run —
Full or Batch — is also tagged with its own **batch ID** (a generated UUID,
used for the batch-scoped rollback in Section 8; unrelated to the Full/Batch
mode choice, despite the shared word).

### Why chunked

The migration is scoped by `order_id` range, using `-s <chunk_size>` (default
`5000`, must be a positive integer — the script rejects `0`, negative, or
non-numeric values before doing anything else). Each chunk runs the same
two `UPDATE` statements as its own transaction, scoped to
`order_id BETWEEN <start> AND <end>`. This bounds how much work (and how long
a lock is held) any single transaction does, which matters at high row
counts — this has been load-tested at 100K+ rows with real chunk timings in
the single-digit-seconds range per chunk.

The chunk range is derived from the **actual pending rows** (via the same
guards as the dry-run counts and the real `UPDATE` `WHERE` clauses), not from
`MIN(order_id)`/`MAX(order_id)` across the whole table. A handful of
long-since-migrated rows scattered near `order_id = 1` do not force the
script to iterate thousands of empty chunks just to reach where the real
pending data starts.

### If the migration is interrupted

If the process is killed, the container restarts, the connection drops, or a
chunk's transaction fails outright, the loop stops **after fully rolling
back the in-flight chunk** — a chunk is never partially applied. The
checkpoint file records the `order_id` the last *successful* chunk ended at,
written only after that chunk's `COMMIT` succeeds.

Re-running the script detects the checkpoint automatically:
```text
Checkpoint found — last completed chunk ended at order_id 239,755.
Batch ID in checkpoint : 550e8400-e29b-41d4-a716-446655440000
Range in checkpoint    : 4 - 239,791
Resume from checkpoint? [yes/no]:
```
* **`yes`** — resumes from `checkpoint + 1`, using the *same batch ID and the
  same order_id range* as the interrupted run, so the migration log stays a
  single coherent batch. Already-completed chunks are not reprocessed.
* **`no`** — discards the checkpoint and prompts for Full/Batch mode again
  from scratch (a new batch ID is generated). In practice this reaches the
  same end state as resuming either way, since already-migrated rows are
  excluded regardless (the migration's `comment_to_fulfiller IS NULL`-style
  guards make this safe) — the difference only matters if you suspect the
  checkpoint itself is stale or wrong.

If the checkpoint file exists but is empty or unreadable (e.g. the process
was killed mid-write), the script logs a warning, deletes it, and starts
fresh rather than silently misreporting a resume point.

On a clean, fully-completed run, the checkpoint file is deleted — its
presence always means "an earlier run did not finish."

### What resuming does *not* protect against

Resuming is safe specifically because this migration's idempotency comes
from column-state guards (`comment_to_fulfiller IS NULL`, etc.), not from
the checkpoint bookkeeping itself. The checkpoint only optimizes *where to
start scanning* — even a full rescan from `order_id` 1 with no checkpoint at
all would still produce the correct end state, just slower. This differs
from insert-based migrations (e.g. `data-migrate-legacy-diagnoses.sh`) where
checkpoint/range mismatches can risk silently skipping pending rows; that
failure mode does not apply here.

---

## 5. The Two Migration Steps

Both steps are scoped to Drug Orders only via `INNER JOIN drug_order do
ON do.order_id = o.order_id` (see Section 6).

### Step 1 — DC orders: move the note into `comment_to_fulfiller`
For a discontinued (`order_action = 'DISCONTINUE'`) drug order that has a
non-empty `order_reason_non_coded` and no existing `comment_to_fulfiller`,
the note is copied into `comment_to_fulfiller`.

**`order_reason_non_coded` is only ever read here — it is never modified.**
There is no concept-name lookup/derivation step. Real old-Bahmni
stop-medication data can have **both** a coded `order_reason` (the dropdown
stop reason) and a free-text `order_reason_non_coded` note set at the same
time — they are independent fields, not mutually exclusive — but this
migration does not touch `order_reason` or attempt to normalize
`order_reason_non_coded` to a concept display name; it is left exactly as
found, regardless of whether `order_reason` is coded.

### Step 2 — NEW/REVISE orders: extract `additionalInstructions` from JSON
For a drug order with `order_action` of `NEW` **or `REVISE`** whose
`drug_order.dosing_instructions` JSON contains an `additionalInstructions`
key, that value is extracted via `JSON_UNQUOTE(JSON_EXTRACT(...))` and written
into `comment_to_fulfiller`. **`dosing_instructions` itself is never
modified** — it is read-only input to this migration.

`REVISE` is included because **editing** a drug order in old Bahmni does not
update the existing row — it creates a new `orders` row with
`order_action = 'REVISE'` (linked back via `previous_order_id`), carrying its
note in `dosing_instructions` the same way a `NEW` order does. Without
covering `REVISE`, edited orders' notes would be silently skipped.

---

## 6. Scoping — Why Drug Orders Only

The `orders` table is shared across all order types (Drug, Lab/Test,
Radiology, etc.). Running the raw UPDATEs against `orders` alone — without
the `INNER JOIN drug_order` — would also touch Test/Lab and other non-drug
orders that happen to have similar column values, corrupting their data.
Every UPDATE in this migration is therefore joined against `drug_order` on
`order_id`, restricting all writes strictly to medication (drug) orders.

---

## 7. Idempotency

* **Both steps** guard on `comment_to_fulfiller IS NULL` — once a row has
  been migrated, re-running the UPDATE matches zero rows for it (not an
  INSERT/unique-constraint pattern, since these are UPDATEs, not INSERTs).

Re-running the script after a successful migration will show dry-run counts
of `0` and exit immediately with no changes.

---

## 8. Rollback — Batch-Scoped, Log-Driven (Not a Full-Table Restore)

```bash
# List available batches and pick one interactively:
./data-rollback-legacy-stop-notes.sh -u <username> -p <password> -d <dbname> -c <container>

# Or roll back a specific batch directly:
./data-rollback-legacy-stop-notes.sh -u <username> -p <password> -d <dbname> -c <container> -b <batch_id>
```

### Why this is possible despite both steps being blind UPDATEs

Both migration steps `UPDATE ... SET comment_to_fulfiller = ...`, and both are
guarded by `comment_to_fulfiller IS NULL`. That guard means the value being
overwritten is **always `NULL`** — so rollback doesn't need to know or store
the "old" value at all; it only needs to know **which rows a given run
touched**, so it can set `comment_to_fulfiller` back to `NULL` for exactly
those rows and no others.

That's what the `stop_order_notes_migration_log` table is for. Before each
`UPDATE` in a chunk's transaction, an `INSERT IGNORE` logs
`(batch_id, order_id, step, migrated_at)` for every row about to be touched,
in the same transaction — so the log and the update are always consistent,
even if a chunk fails and rolls back.

### How rollback works

1. `data-rollback-legacy-stop-notes.sh` checks that
   `stop_order_notes_migration_log` exists (i.e. the migration has run at
   least once).
2. If `-b <batch_id>` is not given, it lists every batch on record (rows
   touched, started/finished timestamps) and prompts for one.
3. The batch ID format is validated (UUID or `batch_YYYYMMDD_HHMMSS`) before
   any query runs, and its existence in the log is confirmed.
4. It shows a step-by-step breakdown of how many rows will be affected and
   requires typing `YES` (not `yes`) to confirm — this is a destructive,
   irreversible-once-confirmed action, hence the stronger confirmation than
   the migration script's `yes` prompt.
5. In a single transaction: `UPDATE orders ... SET comment_to_fulfiller = NULL`
   for every `order_id` logged under that `batch_id`, then `DELETE` those log
   rows.

This means:

* **Only the rows this specific batch touched are affected** — rows touched
  by other batches, or edited through the application after migration, are
  untouched (they're identified by `batch_id`, not by column value).
* **No backup file is required.** `data-backup-legacy-stop-notes.sh` still
  exists and can be run beforehand as an extra safety net (e.g. against a
  scenario outside this migration's control, like manual `UPDATE`s run by
  someone else), but the rollback script itself never reads it.
* `order_reason_non_coded` and `dosing_instructions` are never touched by
  rollback, matching the fact that the migration never modifies them either.

Only run the rollback script once you've confirmed (via the batch listing or
`data-audit-legacy-stop-notes.sh`) that the batch ID you're targeting is the
one you actually want undone.

---

## 9. Audit Script

```bash
./data-audit-legacy-stop-notes.sh -u <username> -p <password> -d <dbname> -c <container>
```

A read-only report — it runs no `INSERT`/`UPDATE`/`DELETE` and does not
require the migration log table to exist. Useful before migrating (to see
what's eligible) and after (to confirm completeness), or any time you want a
coverage snapshot without changing anything.

It reports, separately for Step 1 (DISCONTINUE notes) and Step 2 (NEW/REVISE
JSON notes), and combined:

* **Total eligible** — rows matching the step's source-data condition,
  regardless of migration state.
* **Already migrated** — of those, how many have `comment_to_fulfiller`
  populated.
* **Still pending** — the difference.
* **Coverage** — migrated ÷ eligible, as a percentage.

It also reports the migration log summary (distinct batches run, total log
rows) if `stop_order_notes_migration_log` exists, or notes that the migration
hasn't run yet if it doesn't. It finishes with a plain-language verdict:
`COMPLETE`, `INCOMPLETE` (with a pending count), or "no eligible rows found."
