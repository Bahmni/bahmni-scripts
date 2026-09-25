SET FOREIGN_KEY_CHECKS=0;

-- Step 1: Truncate transaction-heavy tables
TRUNCATE TABLE test_order;
TRUNCATE TABLE drug_order;
TRUNCATE TABLE note;
TRUNCATE TABLE obs_relationship;
TRUNCATE TABLE concept_proposal;
TRUNCATE TABLE concept_proposal_tag_map;
TRUNCATE TABLE obs;
TRUNCATE TABLE orders;
TRUNCATE TABLE relationship;
TRUNCATE TABLE visit_attribute;
TRUNCATE TABLE bed_patient_assignment_map;
TRUNCATE TABLE encounter_provider;
TRUNCATE TABLE episode_encounter;
TRUNCATE TABLE order_group;
TRUNCATE TABLE encounter;
TRUNCATE TABLE visit;
TRUNCATE TABLE patient_identifier;
TRUNCATE TABLE conditions;
TRUNCATE TABLE cohort_member;
TRUNCATE TABLE patient_program;
TRUNCATE TABLE episode_patient_program;
TRUNCATE TABLE patient_program_attribute;
TRUNCATE TABLE patient_state;
TRUNCATE TABLE patient;
TRUNCATE TABLE episode;
TRUNCATE TABLE audit_log;
TRUNCATE TABLE event_records_offset_marker;

-- Step 2: Fast cleanup for person_attribute (preserve person_id=1 only)
CREATE TEMPORARY TABLE tmp_person_attribute AS
SELECT * FROM person_attribute WHERE person_id = 1;

TRUNCATE TABLE person_attribute;

INSERT INTO person_attribute SELECT * FROM tmp_person_attribute;
DROP TEMPORARY TABLE tmp_person_attribute;

-- Step 3: Fast cleanup for person_address (preserve person_id=1 only)
CREATE TEMPORARY TABLE tmp_person_address AS
SELECT * FROM person_address WHERE person_id = 1;

TRUNCATE TABLE person_address;

INSERT INTO person_address SELECT * FROM tmp_person_address;
DROP TEMPORARY TABLE tmp_person_address;

-- Step 4: Fast cleanup for person_name (preserve users, providers, person_id=1)
CREATE TEMPORARY TABLE tmp_person_name AS
SELECT * 
FROM person_name
WHERE person_id = 1
   OR person_id IN (SELECT person_id FROM users)
   OR person_id IN (SELECT person_id FROM provider);

TRUNCATE TABLE person_name;

INSERT INTO person_name SELECT * FROM tmp_person_name;
DROP TEMPORARY TABLE tmp_person_name;

-- Step 5: Fast cleanup for person (preserve users, providers, person_id=1)
CREATE TEMPORARY TABLE tmp_person AS
SELECT * 
FROM person
WHERE person_id = 1
   OR person_id IN (SELECT person_id FROM users)
   OR person_id IN (SELECT person_id FROM provider);

TRUNCATE TABLE person;

INSERT INTO person SELECT * FROM tmp_person;
DROP TEMPORARY TABLE tmp_person;

-- Step 6: Delete event_records + markers (use WHERE filters as requested)
DELETE FROM event_records WHERE category = 'patient' OR category = 'Encounter';
DELETE FROM markers WHERE feed_uri LIKE '%feed/patient/recent%';

-- Step 7: Reset bed status
UPDATE bed SET status = 'AVAILABLE';

-- Step 8: Verify cleanup (optional)
SELECT 
  (SELECT COUNT(*) FROM person_attribute) AS person_attr_count,
  (SELECT COUNT(*) FROM person_address) AS person_address_count,
  (SELECT COUNT(*) FROM person_name) AS person_name_count,
  (SELECT COUNT(*) FROM person) AS person_count,
  (SELECT COUNT(*) FROM event_records) AS event_records_count,
  (SELECT COUNT(*) FROM markers) AS markers_count;

SET FOREIGN_KEY_CHECKS=1;
