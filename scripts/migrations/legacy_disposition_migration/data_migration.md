# BAH-5286: Legacy Disposition Observation Migration

## Table of Contents
1. Background
2. Before You Begin
3. Running the Migration
4. Full vs Batch Mode, Chunking, and Resuming an Interrupted Migration
5. Field Mapping — What Gets Written
6. Scoping — The Disposition/Disposition Note Obs Pair
7. Idempotency
8. Rollback — Batch-Scoped, Log-Driven (Deletes, Not Restores)
9. Audit Script

---

## 1. Background

Old Bahmni records a disposition (Admit / Discharge / Transfer / Undo
Discharge) as two sibling **Observations** sharing an `obs_group_id`, part of
the emrapi "Disposition Concept Set":

* A **Disposition** obs — `value_coded` is the answer concept (Admit
  Patient / Discharge Patient / Transfer Patient / Undo Discharge).
* A sibling **Disposition Note** obs — `value_text` is the free-text note
  (optional).

New Bahmni (BAH-5066) instead places a disposition order in the `orders`
table, under the `ADT Order` order type, and BAH-5067's Disposition widget on
the clinical dashboard reads **only** those `orders`/`ServiceRequest` rows —
it does not dual-read Observations. Without migration, dispositions recorded
through the old UI are invisible on the new dashboard.

This is a **standalone, one-time database migration script** — not a
core-module Liquibase changeset — following the same pattern as
`medication_notes_migration/` (BAH-4996) in this repo.

---

## 2. Before You Begin

### Prerequisites

* **MySQL client installed** — required if connecting directly to the
  database. Verify with `mysql --version`.
* **bahmni-core with the `ADT Order` order type seeded** — liquibase
  changeset `bah-5197-add-adt-order-type-20261007` (merged via PR #360). The
  migrate script checks for this and refuses to run if it's missing, rather
  than silently creating orders of the wrong type.
* **Docker installed and running** — required if the database is inside a
  Docker container. Verify with `docker ps`.
* **Database access** — a MySQL username and password with read and write
  access to the OpenMRS database.
* **Backup is optional but recommended** — rollback here is batch-scoped and
  driven by a migration log table (see Section 8), so a `mysqldump` backup is
  not required to undo a run. `data-backup-legacy-disposition-migration.sh`
  still exists as an extra safety net and can optionally be invoked from the
  migrate script when prompted (see Section 3).

> **Important — Do not run multiple instances simultaneously:** the script
> uses a lock file (`/tmp/legacy_disposition_migration_<dbname>.lock`) to
> prevent two concurrent runs against the same database. Never bypass this
> unless you are certain no other run is active.

---

## 3. Running the Migration

Four standalone scripts live in this directory, matching the convention used
by the other migrations in this repo (e.g. `medication_notes_migration/`):

```
data-backup-legacy-disposition-migration.sh    — takes a targeted mysqldump of orders (+ the log table, if present)
data-migrate-legacy-disposition-migration.sh   — dry-run, choose Full/Batch, confirm, insert the migrated orders
data-rollback-legacy-disposition-migration.sh  — batch-scoped undo, driven by the migration log table
data-audit-legacy-disposition-migration.sh     — read-only before/after coverage report, per disposition type
```

### Recommended: run the backup script first

```bash
./data-backup-legacy-disposition-migration.sh -u <username> -p <password> -d <dbname> -c <container>
```

### Then run the migration

```bash
./data-migrate-legacy-disposition-migration.sh -u <username> -p <password> -d <dbname> -c <container>

# Optionally control chunk size (default 2000, must be a positive integer):
./data-migrate-legacy-disposition-migration.sh -u <username> -p <password> -d <dbname> -c <container> -s 1000
```

The script is fully interactive — any flag not passed is prompted for. If you
skipped the backup step above, the migrate script will offer to run
`data-backup-legacy-disposition-migration.sh` for you (using the same
credentials) before proceeding — see Step 5 below. You can also skip it
entirely and take your own backup through other means.

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

#### Step 2 — Connectivity check and prerequisite checks
The script runs a lightweight `SELECT 1;` before doing anything else, so a
wrong container name or bad credentials fail fast. It then looks up (and
fails fast if missing) the `ADT Order` order type, the `OUTPATIENT` care
setting, and the emrapi-mapped `Disposition` concept — the same prerequisites
BAH-5066's save path relies on.

#### Step 3 — Dry-run counts
```text
Legacy disposition obs pending migration : 42
Voided disposition obs (always skipped)  : 3
```
If the pending count is zero, the script exits immediately with `Nothing to
migrate. All records are already up to date.` — nothing is written.

#### Step 3.5 — Checkpoint detection, then Full vs Batch mode
```text
Checkpoint found — last completed chunk ended at obs_id 239,755.
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
  2. Batch migration — specify an obs_id range
Enter choice [1/2]:
```
Choosing **Batch** shows the full pending `obs_id` range as a hint, then
prompts for a start/end `obs_id`; only rows in that range are touched. This
is useful for migrating a known slice or for splitting a very large migration
into independently-reviewable, separately rollback-able runs. Choosing
**Full** uses the entire pending range, computed from the *actual* pending
rows (not the whole `obs` table). Either way, a fresh batch ID (UUID, or
`batch_YYYYMMDD_HHMMSS` as a fallback) is generated for the run — see
Section 8.

#### Step 4 — Confirmation
```text
Proceed with migration? [yes/no]:
```
Type `yes` to proceed. Anything else cancels with no changes made.

#### Step 5 — Optional backup
```text
Run data-backup-legacy-disposition-migration.sh now before migrating? [yes/no]:
```
If you already ran `data-backup-legacy-disposition-migration.sh` yourself
(recommended), answer `no` here. Otherwise answer `yes` and the migrate
script will invoke it for you, reusing the same credentials — it takes a
`mysqldump` of `orders` (and the migration log table, if it already exists),
written next to the script as `backup_BAH-5286_<timestamp>.sql` and validated
(non-empty, contains the `-- Dump completed` footer). If the backup fails
validation, the migration aborts with no changes made. If you answer `no`,
migration proceeds without a backup — `data-rollback-legacy-disposition-migration.sh`
still works afterward regardless (it's log-driven, not backup-driven — see
Section 8); skipping this step only means you have no extra full-table
safety net beyond the batch-scoped rollback.

#### Step 6 — Migration runs, one chunk at a time
The pending `obs_id` range is split into chunks of `-s` size (default
2,000). Each chunk's INSERT runs inside a single transaction, scoped to that
chunk's `obs_id` range. If a chunk's transaction fails, it rolls back
automatically and the checkpoint file preserves progress up to the last
*successful* chunk — see Section 4. Progress logs per chunk:
```text
INFO   Chunk 1/5 done (obs_id 4-2,003): migrated=12
INFO   Chunk 2/5 done (obs_id 2,004-4,003): migrated=8
...
```

#### Step 7 — Summary
```text
┌──────────────────────────────────────────────────────────────┐
│  MIGRATION SUMMARY                                            │
├──────────────────────────────────────────────────────────────┤
│  Batch ID                              : 550e8400-e29b-...   │
│  Chunks processed                      : 5                   │
│  Orders created                        : 38                  │
│  Backup file                           : backup_BAH-5286_... │
│  Total time elapsed                    : 00h 00m 01s         │
└──────────────────────────────────────────────────────────────┘

To roll back this batch run:
  ./data-rollback-legacy-disposition-migration.sh -u <username> -d <dbname> -b 550e8400-e29b-...
```
The printed rollback command is ready to copy-paste — see Section 8.

### Where Output Goes

| Destination | What goes there | Persists after the run? |
|---|---|---|
| **Terminal (screen)** | Interactive prompts, dry-run counts, confirmation, migration summary. | No |
| **Log file** (`migration_BAH-5286_YYYYMMDD.log`, next to the script) | Every `INFO` line, plus raw MySQL error output for any failed query. Check this file if the script exits unexpectedly with no visible error. | Yes — one file per calendar day |
| **Backup file** (`backup_BAH-5286_<timestamp>.sql`, next to the script) | An optional targeted `mysqldump` of `orders` (and the log table, if present), produced by `data-backup-legacy-disposition-migration.sh` (run standalone, or invoked from the migrate script when you answer `yes` at Step 5). Not required for rollback — see Section 8 — but useful as an extra safety net. Absent if you skipped this step. | Yes — kept until you delete it |
| **Checkpoint file** (`legacy_disposition_checkpoint_<dbname>.txt`, next to the script) | The batch ID, obs_id range, and the `obs_id` at which the last successfully-committed chunk ended. Only present while a run is incomplete — see Section 4. | Only if the run is interrupted before completing |
| **Migration log table** (`legacy_disposition_migration_log`, in the database) | One row per source disposition obs actually migrated by any run, pairing it to the `orders` row it created. Drives the rollback script — see Section 8. | Yes — until rolled back or manually cleared |

---

## 4. Full vs Batch Mode, Chunking, and Resuming an Interrupted Migration

### Full vs Batch mode

Every run is either:
* **Full** — migrates every pending row across the whole table.
* **Batch** — migrates only rows within an `obs_id` range you specify.
  Useful for migrating a known slice, staging a large migration as several
  independently-reviewable runs, or re-running just a subset that failed.

Both modes are chunked and checkpointed identically (below); "batch" here
refers to the user-chosen `obs_id` scope, not the chunk size. Every run —
Full or Batch — is also tagged with its own **batch ID** (a generated UUID,
used for the batch-scoped rollback in Section 8; unrelated to the Full/Batch
mode choice, despite the shared word).

### Why chunked

The migration is scoped by `obs_id` range, using `-s <chunk_size>` (default
`2000`, must be a positive integer — the script rejects `0`, negative, or
non-numeric values before doing anything else). Each chunk runs its INSERT as
its own transaction, scoped to `obs_id BETWEEN <start> AND <end>`. This
bounds how much work (and how long a lock is held) any single transaction
does, which matters at high row counts.

The chunk range is derived from the **actual pending rows** (via the same
guards as the dry-run counts and the real INSERT's `WHERE` clause), not from
`MIN(obs_id)`/`MAX(obs_id)` across the whole `obs` table. A handful of
long-since-migrated rows scattered near `obs_id = 1` do not force the script
to iterate thousands of empty chunks just to reach where the real pending
data starts.

### If the migration is interrupted

If the process is killed, the container restarts, the connection drops, or a
chunk's transaction fails outright, the loop stops **after fully rolling
back the in-flight chunk** — a chunk is never partially applied. The
checkpoint file records the `obs_id` the last *successful* chunk ended at,
written only after that chunk's `COMMIT` succeeds.

Re-running the script detects the checkpoint automatically:
```text
Checkpoint found — last completed chunk ended at obs_id 239,755.
Batch ID in checkpoint : 550e8400-e29b-41d4-a716-446655440000
Range in checkpoint    : 4 - 239,791
Resume from checkpoint? [yes/no]:
```
* **`yes`** — resumes from `checkpoint + 1`, using the *same batch ID and the
  same obs_id range* as the interrupted run, so the migration log stays a
  single coherent batch. Already-completed chunks are not reprocessed.
* **`no`** — discards the checkpoint and prompts for Full/Batch mode again
  from scratch (a new batch ID is generated). In practice this reaches the
  same end state as resuming either way, since already-migrated obs are
  excluded regardless (via `NOT EXISTS` against the migration log table) —
  the difference only matters if you suspect the checkpoint itself is stale
  or wrong.

If the checkpoint file exists but is empty or unreadable (e.g. the process
was killed mid-write), the script logs a warning, deletes it, and starts
fresh rather than silently misreporting a resume point.

On a clean, fully-completed run, the checkpoint file is deleted — its
presence always means "an earlier run did not finish."

---

## 5. Field Mapping — What Gets Written

One `orders` row is inserted per eligible Disposition obs:

| `orders` column | Source |
|---|---|
| `order_type_id` | the `ADT Order` order type (looked up once at script start) |
| `concept_id` | the Disposition obs's `value_coded` (the answer concept) |
| `patient_id` | the Disposition obs's `person_id` |
| `encounter_id` | the Disposition obs's `encounter_id` |
| `care_setting` | `OUTPATIENT` — the same constant BAH-5066 sets for every disposition order, live or migrated |
| `orderer` | the `provider` row for the obs creator's person (`provider.person_id = users.person_id` for `users.user_id = obs.creator`) |
| `urgency` | `ON_SCHEDULED_DATE` |
| `scheduled_date` | the Disposition obs's `obs_datetime` — this is what the FHIR translator reads back as `occurrencePeriod.start` |
| `date_activated` | the Disposition obs's `date_created` — read back as `authoredOn`; **not** the migration run time |
| `comment_to_fulfiller` | the sibling Disposition Note obs's `value_text`, if one exists; `NULL` otherwise |
| `order_number` | a migration-local `ORD-MIG-<n>` sequence, seeded past any existing `ORD-MIG-*` numbers so re-runs and OpenMRS's own `ORD-<seed>` sequence never collide |
| `order_action` | `NEW` |
| `creator`, `date_created` | the migration run's own values (user `1`, run time) — consistent with how these columns record row-insert provenance elsewhere in OpenMRS; the obs's original author/time is preserved separately via `orderer`/`date_activated` above |
| `fulfiller_status` | `COMPLETED` **only if** a real fulfilling encounter already happened after the disposition in that visit (see below); `NULL` (open) otherwise |
| `voided` | `0` |

A ServiceRequest **POST** was considered and rejected for this: it would
stamp `date_activated` with the request time, losing the original
observation's timestamp, which the card requires preserving. Writing
directly to `orders` also bypasses the duplicate-active-order guard added for
live dispositions (`ServiceRequestValidatorImpl`), which is wanted here —
backfilling old data should never be blocked by a check designed for new
orders.

### `fulfiller_status` — why it isn't always NULL

A disposition that was actually carried out should not read as still "open"
just because it was migrated from old data. For example: a doctor places an
Admit order, but the order isn't truly done until the patient is actually
moved to a bed and admitted — represented by a real `ADMISSION` encounter.
Treating every migrated order as blanket-open (or blanket-complete) would be
wrong in both directions, so the migrate script computes this per row, using
the exact same rule the *live* duplicate-order check uses:
`fhir2Extension.adtDispositionRules`'s `fulfilledByEncounterTypes` (and
`fulfilledByVoiding`, for Undo Discharge) — the same global property
`DispositionOrderLifecycleServiceImpl.isFulfilled()` reads.

Concretely, for each migrated Disposition obs, the script checks whether an
encounter of the configured fulfilling type(s) exists in the **same visit**,
dated **after** the disposition's `date_activated` (or, for a
`fulfilledByVoiding` rule like Undo Discharge, whether such an encounter was
voided after that date). If so, `fulfiller_status = 'COMPLETED'`; otherwise
`NULL`, matching what a freshly created, not-yet-fulfilled live disposition
looks like today.

This is resolved once per script run (not hardcoded), so a site that
reconfigures `fhir2Extension.adtDispositionRules` away from the shipped
defaults is still honoured correctly. If the global property is not
configured at all, the migrate script refuses to run rather than guessing a
fulfillment outcome.

**Known narrowing vs. the live check:** the live
`DispositionOrderLifecycleServiceImpl.collectVisitEncounters()` also includes
a patient's visit-less encounters that fall within the visit's time window
(clients that omit `Encounter.partOf`). This migration only looks at
encounters with a matching `visit_id` — it does not replicate that
time-window fallback. In practice this only under-counts fulfillment (a
migrated order stays open when the live check would have called it
complete), never over-counts, so the narrowing is safe but not perfectly
equivalent. Flag this if it causes unexpected results during testing.

---

## 6. Scoping — The Disposition/Disposition Note Obs Pair

A legacy disposition is **two sibling Observations sharing `obs_group_id`**:
a **Disposition** obs (coded answer: Admit Patient / Discharge Patient /
Transfer Patient / Undo Discharge) and an optional sibling **Disposition
Note** obs (free text), both members of a group obs whose concept maps to the
emrapi "Disposition Concept Set". This mirrors exactly what
`DispositionMapper.getDisposition(Obs)` — the method the old clinic's own
read path calls — does: it is handed the Disposition obs directly, then
walks its group members to find the note. The group concept itself carries
no field values and is never read by this migration.

Only **non-voided** Disposition obs with a non-null `value_coded` are
eligible — matching `DispositionMapper.getDisposition(Obs)`, which returns
`null` for a voided obs. Voided observations are never migrated and are never
written to.

---

## 7. Idempotency

Unlike BAH-4996 (which UPDATEs existing rows, guarded by a NULL-column
check), this migration **INSERTs** new `orders` rows — there is no existing
column to guard on. Idempotency instead comes from the migration log table:
every chunk's SELECT excludes any Disposition obs whose `obs_id` already has
a row in `legacy_disposition_migration_log` (`NOT EXISTS` / unique key on
`source_obs_id`).

Re-running the script after a successful migration will show a dry-run count
of `0` and exit immediately with no changes.

---

## 8. Rollback — Batch-Scoped, Log-Driven (Deletes, Not Restores)

```bash
# List available batches and pick one interactively:
./data-rollback-legacy-disposition-migration.sh -u <username> -p <password> -d <dbname> -c <container>

# Or roll back a specific batch directly:
./data-rollback-legacy-disposition-migration.sh -u <username> -p <password> -d <dbname> -c <container> -b <batch_id>
```

### Why this is possible

Because the migration only ever **creates** new `orders` rows and never
modifies existing ones or touches `obs`, undoing a batch is simply deleting
the `orders` rows it created. `legacy_disposition_migration_log` records
exactly which `order_id`s each `batch_id` created, written in the same
transaction as the INSERT that created them — so the log and the data are
always consistent, even if a chunk fails and rolls back.

### How rollback works

1. `data-rollback-legacy-disposition-migration.sh` checks that
   `legacy_disposition_migration_log` exists (i.e. the migration has run at
   least once).
2. If `-b <batch_id>` is not given, it lists every batch on record (orders
   created, started/finished timestamps) and prompts for one.
3. The batch ID format is validated (UUID or `batch_YYYYMMDD_HHMMSS`) before
   any query runs, and its existence in the log is confirmed.
4. It checks whether any of the batch's orders have since been referenced as
   a `previous_order` by a later order (e.g. a discontinuation) and warns if
   so — this is advisory, not a hard block.
5. It requires typing `YES` (not `yes`) to confirm — this is a destructive,
   irreversible-once-confirmed action, hence the stronger confirmation than
   the migration script's `yes` prompt.
6. In a single transaction: `DELETE` every `orders` row logged under that
   `batch_id`, then `DELETE` those log rows.

This means:

* **Only the orders this specific batch created are affected** — orders
  created by other batches, or placed through the application after
  migration, are untouched (they're identified by `batch_id`).
* **No backup file is required.** `data-backup-legacy-disposition-migration.sh`
  still exists and can be run beforehand as an extra safety net, but the
  rollback script itself never reads it.
* Source Observations are never touched by the migration and are never
  touched by rollback.

Only run the rollback script once you've confirmed (via the batch listing or
`data-audit-legacy-disposition-migration.sh`) that the batch ID you're
targeting is the one you actually want undone.

---

## 9. Audit Script

```bash
./data-audit-legacy-disposition-migration.sh -u <username> -p <password> -d <dbname> -c <container>
```

A read-only report — it runs no `INSERT`/`UPDATE`/`DELETE` and does not
require the migration log table to exist. Useful before migrating (to see
what's eligible) and after (to confirm completeness), or any time you want a
coverage snapshot without changing anything.

It reports, broken down by disposition type (Admit, Discharge, Transfer, Undo
Discharge) and combined:

* **Eligible** — non-voided Disposition obs of that type.
* **Migrated** — of those, how many already have a row in the migration log.
* **Pending** — the difference.
* **Coverage** — migrated ÷ eligible, as a percentage (overall).

It also reports the migration log summary — distinct batches run, total
orders created, and how many of those landed with `fulfiller_status =
COMPLETED` vs. still open (`NULL`) — if `legacy_disposition_migration_log`
exists, or notes that the migration hasn't run yet if it doesn't. It finishes
with a plain-language verdict: `COMPLETE`, `INCOMPLETE` (with a pending
count), or "no eligible rows found."
