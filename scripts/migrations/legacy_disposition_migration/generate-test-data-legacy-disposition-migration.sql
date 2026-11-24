-- =============================================================
-- TEST DATA GENERATOR: Legacy Disposition Observations (BAH-5286)
-- =============================================================
-- Generates N disposition "cases" — each a fresh Visit + a Consultation
-- encounter carrying a Disposition obs (+ optional Disposition Note obs,
-- grouped under a parent "Disposition Concept Set" obs, matching the real
-- legacy obs shape) — split across buckets covering disposition type,
-- note presence, voided-ness, and fulfillment state (whether a real
-- ADMISSION/DISCHARGE/TRANSFER encounter exists afterward in the same
-- visit, per fhir2Extension.adtDispositionRules — see
-- data-migrate-legacy-disposition-migration.sh).
--
-- Every created visit_id is tracked in a scratch table
-- (test_bah5286_bulk_visits) so cleanup can find everything this script
-- created without guessing at comment/tag conventions.
--
-- Usage:
--   SET @NUM_CASES = 100000;
--   source generate-test-data-legacy-disposition-migration.sql
--
-- Cleanup after testing:
--   DELETE FROM obs WHERE encounter_id IN (
--     SELECT encounter_id FROM encounter WHERE visit_id IN (SELECT visit_id FROM test_bah5286_bulk_visits)
--   );
--   DELETE FROM encounter WHERE visit_id IN (SELECT visit_id FROM test_bah5286_bulk_visits);
--   DELETE FROM visit WHERE visit_id IN (SELECT visit_id FROM test_bah5286_bulk_visits);
--   DROP TABLE IF EXISTS test_bah5286_bulk_visits;
--   -- Also undo any migration run against this data:
--   --   ./data-rollback-legacy-disposition-migration.sh -u <user> -d <db> -b <batch_id>
-- =============================================================

SET @NUM_CASES = 100000; -- 1 disposition obs per case -> ~100K eligible rows. Change to control volume (see bucket table below)

-- ─── Dynamically fetch required reference data for this database ──────────
SET @emrapi_source_id   = (SELECT concept_source_id FROM concept_reference_source WHERE name = 'org.openmrs.module.emrapi' LIMIT 1);
SET @same_as_map_type   = (SELECT concept_map_type_id FROM concept_map_type WHERE name = 'SAME-AS' LIMIT 1);

SET @disposition_set_concept_id = (
  SELECT crm.concept_id FROM concept_reference_map crm
  JOIN concept_reference_term crt ON crt.concept_reference_term_id = crm.concept_reference_term_id
  WHERE crt.concept_source_id = @emrapi_source_id AND crt.code = 'Disposition Concept Set' LIMIT 1
);
SET @disposition_concept_id = (
  SELECT crm.concept_id FROM concept_reference_map crm
  JOIN concept_reference_term crt ON crt.concept_reference_term_id = crm.concept_reference_term_id
  WHERE crt.concept_source_id = @emrapi_source_id AND crt.code = 'Disposition' LIMIT 1
);
SET @disposition_note_concept_id = (
  SELECT crm.concept_id FROM concept_reference_map crm
  JOIN concept_reference_term crt ON crt.concept_reference_term_id = crm.concept_reference_term_id
  WHERE crt.concept_source_id = @emrapi_source_id AND crt.code = 'DispositionNote' LIMIT 1
);
SET @admit_concept_id = (
  SELECT crm.concept_id FROM concept_reference_map crm
  JOIN concept_reference_term crt ON crt.concept_reference_term_id = crm.concept_reference_term_id
  WHERE crt.concept_source_id = @emrapi_source_id AND crt.code = 'ADMIT' LIMIT 1
);
SET @discharge_concept_id = (
  SELECT crm.concept_id FROM concept_reference_map crm
  JOIN concept_reference_term crt ON crt.concept_reference_term_id = crm.concept_reference_term_id
  WHERE crt.concept_source_id = @emrapi_source_id AND crt.code = 'DISCHARGE' LIMIT 1
);
SET @transfer_concept_id = (
  SELECT crm.concept_id FROM concept_reference_map crm
  JOIN concept_reference_term crt ON crt.concept_reference_term_id = crm.concept_reference_term_id
  WHERE crt.concept_source_id = @emrapi_source_id AND crt.code = 'TRANSFER' LIMIT 1
);
SET @undo_discharge_concept_id = (
  SELECT crm.concept_id FROM concept_reference_map crm
  JOIN concept_reference_term crt ON crt.concept_reference_term_id = crm.concept_reference_term_id
  WHERE crt.concept_source_id = @emrapi_source_id AND crt.code = 'UNDO_DISCHARGE' LIMIT 1
);

SET @consultation_encounter_type_id = (SELECT encounter_type_id FROM encounter_type WHERE name = 'Consultation' LIMIT 1);
SET @admission_encounter_type_id    = (SELECT encounter_type_id FROM encounter_type WHERE name = 'ADMISSION' LIMIT 1);
SET @discharge_encounter_type_id    = (SELECT encounter_type_id FROM encounter_type WHERE name = 'DISCHARGE' LIMIT 1);
SET @transfer_encounter_type_id     = (SELECT encounter_type_id FROM encounter_type WHERE name = 'TRANSFER' LIMIT 1);

SET @visit_type_id = (SELECT visit_type_id FROM visit_type WHERE retired = 0 LIMIT 1);
SET @location_id   = (SELECT location_id FROM location LIMIT 1);
SET @creator       = (SELECT user_id FROM users WHERE retired = 0 LIMIT 1);

SELECT patient_id, person_id INTO @patient_id, @person_id FROM patient JOIN person ON person.person_id = patient.patient_id WHERE person.voided = 0 LIMIT 1;

-- ─── Fail fast with a clear message if prerequisite reference data is missing ─
SELECT
  CASE
    WHEN @disposition_concept_id IS NULL THEN 'ERROR: No concept mapped to emrapi code ''Disposition''. Is the emrapi Disposition concept set installed?'
    WHEN @disposition_set_concept_id IS NULL THEN 'ERROR: No concept mapped to emrapi code ''Disposition Concept Set''.'
    WHEN @admit_concept_id IS NULL OR @discharge_concept_id IS NULL OR @transfer_concept_id IS NULL OR @undo_discharge_concept_id IS NULL
      THEN 'ERROR: One or more of ADMIT/DISCHARGE/TRANSFER/UNDO_DISCHARGE emrapi-mapped concepts not found.'
    WHEN @consultation_encounter_type_id IS NULL THEN 'ERROR: No ''Consultation'' encounter type found.'
    WHEN @admission_encounter_type_id IS NULL OR @discharge_encounter_type_id IS NULL OR @transfer_encounter_type_id IS NULL
      THEN 'ERROR: One or more of ADMISSION/DISCHARGE/TRANSFER encounter types not found (seeded by emrapi/bedmanagement).'
    WHEN @visit_type_id IS NULL THEN 'ERROR: No visit_type found.'
    WHEN @location_id IS NULL THEN 'ERROR: No location found.'
    WHEN @creator IS NULL THEN 'ERROR: No unretired user found.'
    WHEN @patient_id IS NULL THEN 'ERROR: No non-voided patient found.'
    ELSE 'OK: all prerequisites resolved.'
  END AS prerequisite_check;

-- ─── Scratch tracking table (for cleanup — see header) ─────────────────────
CREATE TABLE IF NOT EXISTS test_bah5286_bulk_visits (
    visit_id INT PRIMARY KEY
);

DROP PROCEDURE IF EXISTS sp_create_disposition_case;
DROP PROCEDURE IF EXISTS generate_test_dispositions;

DELIMITER $$

-- ─── Building block: one disposition "case" ────────────────────────────────
-- answer_concept_id    : the Admit/Discharge/Transfer/Undo Discharge concept
-- note_mode            : 'WITH_NOTE' | 'NO_NOTE'
-- voided_mode          : 'VOIDED' | 'NOT_VOIDED'
-- fulfillment_mode     : 'FULFILLED_AFTER'  — fulfilling encounter dated after the obs (should read COMPLETED)
--                        'FULFILLED_BEFORE' — fulfilling encounter dated BEFORE the obs (should NOT count — order matters)
--                        'NOT_FULFILLED'    — no fulfilling encounter at all (should stay open/NULL)
--                        'NONE'             — bucket doesn't apply fulfillment (e.g. voided case)
-- fulfilling_encounter_type_id : which encounter type fulfills this disposition (NULL for 'NONE')
-- fulfilled_by_voiding : TRUE only for Undo Discharge — fulfillment is a DISCHARGE encounter being
--                        voided afterward, not a new encounter being created
CREATE PROCEDURE sp_create_disposition_case(
    IN tag VARCHAR(64),
    IN answer_concept_id INT,
    IN note_mode VARCHAR(20),
    IN voided_mode VARCHAR(20),
    IN fulfillment_mode VARCHAR(20),
    IN fulfilling_encounter_type_id INT,
    IN fulfilled_by_voiding BOOLEAN
)
BEGIN
    DECLARE v_visit_id INT;
    DECLARE v_consult_encounter_id INT;
    DECLARE v_group_obs_id BIGINT;
    DECLARE v_disposition_obs_id BIGINT;
    DECLARE v_base_datetime DATETIME DEFAULT DATE_SUB(NOW(), INTERVAL 30 DAY);
    DECLARE v_is_voided TINYINT DEFAULT IF(voided_mode = 'VOIDED', 1, 0);

    -- 1. Visit
    INSERT INTO visit (patient_id, visit_type_id, date_started, location_id, creator, date_created, uuid, voided)
    VALUES (@patient_id, @visit_type_id, v_base_datetime, @location_id, @creator, NOW(), UUID(), 0);
    SET v_visit_id = LAST_INSERT_ID();
    INSERT INTO test_bah5286_bulk_visits (visit_id) VALUES (v_visit_id);

    -- 2. Consultation encounter carrying the disposition obs
    INSERT INTO encounter (encounter_type, patient_id, visit_id, encounter_datetime, location_id, creator, date_created, uuid, voided)
    VALUES (@consultation_encounter_type_id, @patient_id, v_visit_id, v_base_datetime, @location_id, @creator, NOW(), UUID(), 0);
    SET v_consult_encounter_id = LAST_INSERT_ID();

    -- 3. Parent "Disposition Concept Set" group obs (never read by the migration — present for shape-fidelity only)
    INSERT INTO obs (person_id, concept_id, encounter_id, obs_datetime, location_id, creator, date_created, uuid, voided, comment)
    VALUES (@person_id, @disposition_set_concept_id, v_consult_encounter_id, v_base_datetime, @location_id, @creator, NOW(), UUID(), v_is_voided, CONCAT('TEST-BAH5286-BULK-', tag));
    SET v_group_obs_id = LAST_INSERT_ID();

    -- 4. Disposition obs (the one the migration reads: concept_id = Disposition, value_coded = answer concept)
    INSERT INTO obs (person_id, concept_id, encounter_id, obs_group_id, obs_datetime, value_coded, location_id, creator, date_created, uuid, voided, comment)
    VALUES (@person_id, @disposition_concept_id, v_consult_encounter_id, v_group_obs_id, v_base_datetime, answer_concept_id, @location_id, @creator, NOW(), UUID(), v_is_voided, CONCAT('TEST-BAH5286-BULK-', tag));
    SET v_disposition_obs_id = LAST_INSERT_ID();

    -- 5. Sibling Disposition Note obs (optional)
    IF note_mode = 'WITH_NOTE' THEN
        INSERT INTO obs (person_id, concept_id, encounter_id, obs_group_id, obs_datetime, value_text, location_id, creator, date_created, uuid, voided, comment)
        VALUES (@person_id, @disposition_note_concept_id, v_consult_encounter_id, v_group_obs_id, v_base_datetime, CONCAT('Bulk test note ', tag), @location_id, @creator, NOW(), UUID(), v_is_voided, CONCAT('TEST-BAH5286-BULK-', tag));
    END IF;

    -- 6. Fulfilling encounter, if this case calls for one
    IF fulfillment_mode = 'FULFILLED_AFTER' THEN
        IF fulfilled_by_voiding THEN
            -- Undo Discharge: fulfillment is an existing DISCHARGE encounter being voided
            -- afterward, not a new encounter appearing. Create it BEFORE the disposition
            -- (as a real prior discharge would be), then void it AFTER.
            INSERT INTO encounter (encounter_type, patient_id, visit_id, encounter_datetime, location_id, creator, date_created, uuid, voided, date_voided, voided_by, void_reason)
            VALUES (fulfilling_encounter_type_id, @patient_id, v_visit_id, DATE_SUB(v_base_datetime, INTERVAL 1 DAY), @location_id, @creator, NOW(), UUID(),
                    1, DATE_ADD(v_base_datetime, INTERVAL 1 HOUR), @creator, CONCAT('TEST-BAH5286-BULK-', tag));
        ELSE
            INSERT INTO encounter (encounter_type, patient_id, visit_id, encounter_datetime, location_id, creator, date_created, uuid, voided)
            VALUES (fulfilling_encounter_type_id, @patient_id, v_visit_id, DATE_ADD(v_base_datetime, INTERVAL 1 HOUR), @location_id, @creator, NOW(), UUID(), 0);
        END IF;
    ELSEIF fulfillment_mode = 'FULFILLED_BEFORE' THEN
        -- Fulfilling encounter exists but BEFORE the disposition — must NOT count as fulfilled
        INSERT INTO encounter (encounter_type, patient_id, visit_id, encounter_datetime, location_id, creator, date_created, uuid, voided)
        VALUES (fulfilling_encounter_type_id, @patient_id, v_visit_id, DATE_SUB(v_base_datetime, INTERVAL 1 HOUR), @location_id, @creator, NOW(), UUID(), 0);
    END IF;
    -- 'NOT_FULFILLED' and 'NONE' create no fulfilling encounter at all.
END$$

-- ─── Driver: compose cases from the building block ─────────────────────────
CREATE PROCEDURE generate_test_dispositions(IN num_cases INT)
BEGIN
    DECLARE i INT DEFAULT 1;
    DECLARE bucket INT;

    WHILE i <= num_cases DO
        SET bucket = i MOD 20;

        -- Bucket allocation (out of 20) — type x note x voided x fulfillment:
        --  0-3  (20%): ADMIT,          note,    not voided, fulfilled (after)      -> COMPLETED
        --  4-5  (10%): ADMIT,          no note, not voided, fulfilled (after)      -> COMPLETED
        --  6-7  (10%): ADMIT,          no note, not voided, not fulfilled          -> open (NULL)
        --  8    (5%):  ADMIT,          no note, VOIDED                             -> skipped entirely by migration
        --  9-10 (10%): DISCHARGE,      note,    not voided, fulfilled (after)      -> COMPLETED
        --  11   (5%):  DISCHARGE,      no note, not voided, not fulfilled          -> open (NULL)
        --  12-13(10%): TRANSFER,       note,    not voided, fulfilled (after)      -> COMPLETED
        --  14   (5%):  TRANSFER,       no note, not voided, not fulfilled          -> open (NULL)
        --  15-16(10%): UNDO_DISCHARGE, note,    not voided, fulfilled (DISCHARGE encounter voided after) -> COMPLETED
        --  17   (5%):  UNDO_DISCHARGE, no note, not voided, not fulfilled          -> open (NULL)
        --  18   (5%):  ADMIT,          note,    not voided, fulfilled (BEFORE obs) -> open (NULL) — order matters, proves date comparison is correct
        --  19   (5%):  DISCHARGE,      no note, not voided, fulfilled (BEFORE obs) -> open (NULL) — same, for DISCHARGE

        IF bucket BETWEEN 0 AND 3 THEN
            CALL sp_create_disposition_case(i, @admit_concept_id, 'WITH_NOTE', 'NOT_VOIDED', 'FULFILLED_AFTER', @admission_encounter_type_id, FALSE);

        ELSEIF bucket BETWEEN 4 AND 5 THEN
            CALL sp_create_disposition_case(i, @admit_concept_id, 'NO_NOTE', 'NOT_VOIDED', 'FULFILLED_AFTER', @admission_encounter_type_id, FALSE);

        ELSEIF bucket BETWEEN 6 AND 7 THEN
            CALL sp_create_disposition_case(i, @admit_concept_id, 'NO_NOTE', 'NOT_VOIDED', 'NOT_FULFILLED', NULL, FALSE);

        ELSEIF bucket = 8 THEN
            CALL sp_create_disposition_case(i, @admit_concept_id, 'NO_NOTE', 'VOIDED', 'NONE', NULL, FALSE);

        ELSEIF bucket BETWEEN 9 AND 10 THEN
            CALL sp_create_disposition_case(i, @discharge_concept_id, 'WITH_NOTE', 'NOT_VOIDED', 'FULFILLED_AFTER', @discharge_encounter_type_id, FALSE);

        ELSEIF bucket = 11 THEN
            CALL sp_create_disposition_case(i, @discharge_concept_id, 'NO_NOTE', 'NOT_VOIDED', 'NOT_FULFILLED', NULL, FALSE);

        ELSEIF bucket BETWEEN 12 AND 13 THEN
            CALL sp_create_disposition_case(i, @transfer_concept_id, 'WITH_NOTE', 'NOT_VOIDED', 'FULFILLED_AFTER', @transfer_encounter_type_id, FALSE);

        ELSEIF bucket = 14 THEN
            CALL sp_create_disposition_case(i, @transfer_concept_id, 'NO_NOTE', 'NOT_VOIDED', 'NOT_FULFILLED', NULL, FALSE);

        ELSEIF bucket BETWEEN 15 AND 16 THEN
            CALL sp_create_disposition_case(i, @undo_discharge_concept_id, 'WITH_NOTE', 'NOT_VOIDED', 'FULFILLED_AFTER', @discharge_encounter_type_id, TRUE);

        ELSEIF bucket = 17 THEN
            CALL sp_create_disposition_case(i, @undo_discharge_concept_id, 'NO_NOTE', 'NOT_VOIDED', 'NOT_FULFILLED', NULL, TRUE);

        ELSEIF bucket = 18 THEN
            CALL sp_create_disposition_case(i, @admit_concept_id, 'WITH_NOTE', 'NOT_VOIDED', 'FULFILLED_BEFORE', @admission_encounter_type_id, FALSE);

        ELSE
            CALL sp_create_disposition_case(i, @discharge_concept_id, 'NO_NOTE', 'NOT_VOIDED', 'FULFILLED_BEFORE', @discharge_encounter_type_id, FALSE);
        END IF;

        SET i = i + 1;
    END WHILE;

    SELECT CONCAT('Generated ', num_cases, ' disposition cases.') AS result;
    SELECT COUNT(*) AS total_test_visits FROM test_bah5286_bulk_visits;
    SELECT COUNT(*) AS total_test_disposition_obs
    FROM obs o
    JOIN encounter e ON e.encounter_id = o.encounter_id
    JOIN test_bah5286_bulk_visits v ON v.visit_id = e.visit_id
    WHERE o.concept_id = @disposition_concept_id;
END$$

DELIMITER ;

CALL generate_test_dispositions(@NUM_CASES);

DROP PROCEDURE IF EXISTS sp_create_disposition_case;
DROP PROCEDURE IF EXISTS generate_test_dispositions;
