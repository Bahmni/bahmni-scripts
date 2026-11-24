# BAH-5286 — Migrate Legacy Disposition Observations to ServiceRequests

Design notes, carried over from analysis done in `bahmni-module-fhir2-addl-extension/BAH-5067_BAH-5286_analysis.md`
and a follow-up session. Captured so work can resume tomorrow without re-deriving it.

## Why

BAH-5067's Disposition widget reads FHIR `ServiceRequest`s only (decision taken on BAH-5067, no dual read of
Observations). Legacy dispositions were recorded as Observations. Without this migration, old dispositions are
invisible in the new widget. Must ship in the same release as BAH-5067 (Bahmni Standard 2.0).

## Decisions made

- **No bahmni-core / fhir2-addl-extension changes required.** Everything the migration needs already exists on
  `main`/`master`:
  - `ADT Order` order type is seeded by bahmni-core liquibase changeset `bah-5197-add-adt-order-type-20261007`
    (merged via PR #360).
  - Default GP `fhir2Extension.adtDispositionRules` already keys on `ADMIT` / `DISCHARGE` / `TRANSFER` /
    `UNDO_DISCHARGE` — the same codes the legacy answer concepts already carry. No code-translation table needed.
  - `fhir2Extension.adtOrderTypeName` defaults to `ADT Order`.
- **Direct SQL into `orders`, not the FHIR API.** A ServiceRequest POST stamps `date_activated` with the request
  time; the card requires the original observation's timestamp. Direct SQL (same approach as the BAH-4996
  medication-notes migration) is the only way to preserve it, and it also bypasses the duplicate-active-order
  guard added in PR #141 (`ServiceRequestValidatorImpl`), which we want for backfilling old data.
- **`fulfiller_status` is computed per row, not left blanket-`NULL`.** Superseded an earlier decision to always
  leave it `NULL`. A doctor placing an Admit order does not mean the disposition is done — it's only complete
  once the patient is actually moved to a bed and admitted (a real `ADMISSION` encounter). The migrate script
  reuses the exact rule `DispositionOrderLifecycleServiceImpl.isFulfilled()` already applies to live orders,
  reading `fhir2Extension.adtDispositionRules`'s `fulfilledByEncounterTypes`/`fulfilledByVoiding` at run time: if
  a qualifying encounter (or voided encounter, for Undo Discharge) exists in the same visit after the
  disposition's date, the migrated order gets `fulfiller_status = COMPLETED`; otherwise it's left `NULL` (open),
  same as a freshly created, not-yet-fulfilled live disposition. Implemented in
  `data-migrate-legacy-disposition-migration.sh`; see `data_migration.md` Section 5 for the full rationale and a
  known narrowing vs. the live check (visit-less encounters in the visit's time window aren't replicated — this
  only ever under-counts fulfillment, never over-counts).
- **Idempotency via a mapping/log table**, not a column on `orders` (no such column exists). Table keyed by
  source obs UUID, following the BAH-4996 `stop_order_notes_migration_log` pattern — also gives batch-scoped
  rollback for free.
- **Branch:** `BAH-5286` off `bahmni-scripts` `master` (not off the in-progress `BAH-4990-fix-master` branch).
- **Location:** `bahmni-scripts/scripts/migrations/legacy_disposition_migration/`, mirroring the BAH-4996
  medication-notes-migration folder layout (migrate / backup / audit / rollback scripts + a `data_migration.md`).

## Legacy data model (confirmed from emrapi-api 2.3.0 `DispositionMapper` bytecode + bahmni-core
`V1_62__AddDispositionConcepts.sql` + liquibase changeset `bahmni-clinical-201502091501`)

A legacy disposition is **two sibling Obs rows sharing `obs_group_id`**, both members of a group obs whose
concept maps to `Disposition Concept Set`:

```
disposition_obs
  concept_id  -> concept mapped (source "org.openmrs.module.emrapi", map type SAME-AS) to code "Disposition"
  value_coded -> the answer concept (Admit Patient / Discharge Patient / Transfer Patient / Undo Discharge),
                 which itself has an emrapi SAME-AS mapping to ADMIT / DISCHARGE / TRANSFER / UNDO_DISCHARGE
                 -- THIS is the code the migration needs, not disposition_obs.concept_id's own mapping
  obs_datetime, person_id (patient), encounter_id, creator, date_created, voided

note_obs  (sibling: same obs_group_id as disposition_obs)
  concept_id  -> concept mapped to code "DispositionNote"
  value_text  -> the note (optional — not every disposition has one)
```

`DispositionMapper.getDisposition(Obs)` (what the legacy UI/API itself calls) confirms this: it is handed the
`disposition_obs` directly (found via `ObservationTypeMatcher` over `encounter.getObsAtTopLevel(false)`), then
walks `getGroupMembers()` to find the note. The group concept (`Disposition Concept Set`) is never read for
field values — only used to identify which top-level obs is "the" disposition obs.

Voided observations (`disposition_obs.voided = 1`) must be skipped, per the card.

## Target shape — `orders` row per legacy disposition

Mirrors the field mapping fhir2-addl-extension's `BahmniServiceRequestTranslatorImpl` + `toOpenmrsType` already
use for live dispositions, written directly instead of through FHIR:

| `orders` column | Source |
|---|---|
| `order_type_id` | `order_type` row named `ADT Order` (GP `fhir2Extension.adtOrderTypeName`, default `ADT Order`) |
| `concept_id` | `disposition_obs.value_coded` (the answer concept — Admit/Discharge/Transfer/Undo Discharge) |
| `patient_id` | `disposition_obs.person_id` |
| `encounter_id` | `disposition_obs.encounter_id` |
| `orderer` | provider for `disposition_obs.creator` — resolved via `provider.person_id = users.person_id` for `users.user_id = obs.creator`, same join pattern used elsewhere in bahmni-core's direct-SQL provider lookups (e.g. `V1_95_WardsListSql.sql`) |
| `care_setting` | `OUTPATIENT` — confirmed this is what `BahmniServiceRequestTranslatorImpl.toOpenmrsType()` sets for every live disposition order (`order.setCareSetting(orderService.getCareSettingByName(CareSetting.CareSettingType.OUTPATIENT.toString()))`), so migrated orders match |
| `urgency` | `ON_SCHEDULED_DATE` |
| `scheduled_date` | `disposition_obs.obs_datetime` (-> read back as `occurrencePeriod.start` / FHIR `occurrenceDateTime`) |
| `date_activated` | `disposition_obs.date_created` (-> read back as `authoredOn`) — **not** migration run time |
| `comment_to_fulfiller` | `note_obs.value_text` if present, else `NULL` |
| `creator`, `date_created` | migration-run values (decided: consistent with how these columns record row-insert provenance elsewhere in OpenMRS, same choice BAH-4996 made; the obs's real author/time is preserved separately via `orderer`/`date_activated`) |
| `fulfiller_status` | computed per row — see the updated decision above. `COMPLETED` only if a real fulfilling encounter already happened in that visit after the disposition date (per `fhir2Extension.adtDispositionRules`), else `NULL` |
| `order_number` | confirmed: OpenMRS's default `TimestampOrderNumberGenerator`/`OrderServiceImpl` default produces `ORD-<seed>`. The migration mints its own non-colliding `ORD-MIG-<n>` sequence, seeded past any existing `ORD-MIG-*` value, so it never collides with core's own sequence or a prior run |
| `uuid` | `UUID()` |
| `order_action` | `NEW` |
| `voided` | `0` |

All items are now resolved; see `data_migration.md` Section 5 for the full write-up.

## Idempotency / mapping table (new, BAH-5286-specific)

```sql
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
```

`uk_source_obs` is the idempotency guard (one migrated order per source obs, ever — re-running the full
migration is a no-op for already-migrated rows regardless of batch). Rollback deletes by `batch_id`, same
pattern as BAH-4996's `stop_order_notes_migration_log`.

## Script set to build (mirrors `medication_notes_migration/`)

- `data-backup-legacy-disposition-migration.sh` — dumps `orders` (+ whatever note/obs tables are touched, though
  obs is read-only) before a run.
- `data-migrate-legacy-disposition-migration.sh` — interactive, chunked (by `obs_id` range like BAH-4996 chunks
  by `order_id`), single-instance lock, checkpoint/resume, writes to the log table above.
- `data-audit-legacy-disposition-migration.sh` — counts: legacy disposition obs total / already migrated /
  pending / voided-skipped, per disposition type.
- `data-rollback-legacy-disposition-migration.sh` — given a `batch_id`, deletes the `orders` rows it created
  (via the log table) and the log rows themselves. Source Observations are never touched by migrate or rollback.
- `data_migration.md` — usage doc, same shape as the BAH-4996 one.

## Testing checklist (from the card, unchanged)

- Script runs cleanly on a fresh and an existing DB.
- Re-running is a no-op (no duplicates) — covered by `uk_source_obs`.
- Each disposition type (Admit, Discharge, Transfer, Undo Discharge) migrates with the correct concept.
- Disposition note is carried over; dispositions without a note migrate with no note.
- `authoredOn`/`date_activated` equals the original observation time, `requester`/`orderer` equals the original
  author.
- Voided observations are not migrated; source observations are untouched.
- Migrated dispositions appear correctly in the BAH-5067 widget alongside newly created ones.
- Admission status and duplicate-order checks in the disposition form behave correctly with migrated data (this
  is the riskiest item — now exercised directly by the per-row `fulfiller_status` computation above, instead of
  being deferred).

## Status: scripts written

All four scripts (`data-migrate-`, `data-backup-`, `data-rollback-`, `data-audit-legacy-disposition-migration.sh`)
plus `data_migration.md` are written, following `medication_notes_migration/`'s structure (lock file, checkpoint
file, per-day log, chunked transactions, batch-ID-driven rollback, interactive confirm flow). All pass `bash -n`.

## Next session — start here

1. Dry-run against a local DB with seeded legacy disposition obs (Admit/Discharge/Transfer/Undo Discharge, with
   and without notes, including a voided one, and at least one case where a fulfilling encounter exists and one
   where it doesn't) before touching anything real.
2. Verify the `fulfiller_status` computation against real data — in particular the JSON_TABLE-based encounter-type
   name lookup in the migrate script, which hasn't been run against a live MySQL/MariaDB instance yet.
3. Confirm MySQL/MariaDB version compatibility for `JSON_TABLE` (added in MySQL 8.0.19 / MariaDB 10.6) — if older
   versions need support, this needs a fallback (e.g. multiple `JSON_EXTRACT` calls indexed by position instead
   of `JSON_TABLE`, similar to how BAH-4996's doc calls out its own `JSON_EXTRACT` version requirement).
4. Run `data-audit-legacy-disposition-migration.sh` before and after a test migration to confirm the coverage and
   fulfiller_status breakdown match expectations.
