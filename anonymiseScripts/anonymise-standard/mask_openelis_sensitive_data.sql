\set ON_ERROR_STOP true

-- 1️⃣ Clear failed events
TRUNCATE failed_events;
-- Verify that the table is empty
SELECT COUNT(*) AS failed_events_count FROM failed_events LIMIT 5;

-- 2️⃣ Mask addresses (organization_address)
UPDATE organization_address AS oa
SET value = CONCAT('address-', oa.organization_id);

-- Verify the changes in organization_address
SELECT *
FROM organization_address
LIMIT 5;

-- 3️⃣ Mask patient identities
UPDATE patient_identity AS pi
SET identity_data = CONCAT('PRIMARYRELATIVE-', pi.patient_id);

-- Verify the changes in patient_identity
SELECT *
FROM patient_identity
LIMIT 5;

-- 4️⃣ Mask system users login (skip atomfeed users)
UPDATE system_user su
SET login_name = CONCAT('user-', lu.id)
FROM login_user lu
WHERE lu.login_name = su.login_name
  AND su.login_name NOT IN ('admin', 'atomfeed');

-- Verify the changes in system_user (excluding atomfeed)
SELECT id, login_name
FROM system_user
WHERE login_name NOT IN ('admin', 'atomfeed') LIMIT 5;

-- 5️⃣ Set everyone's password as adminADMIN!
UPDATE login_user
SET login_name = CONCAT('user-', id),
    password = 'adminADMIN!'
WHERE login_name NOT IN ('admin', 'atomfeed');

-- Verify the changes in login_user
SELECT id, login_name, password
FROM login_user
WHERE login_name NOT IN ('admin', 'atomfeed') LIMIT 5;

-- 6️⃣ Fix system_user login for users missing in login_user
UPDATE system_user su
SET login_name = CONCAT('userwologin-', su.id)
WHERE su.login_name NOT IN (SELECT login_name FROM login_user);

-- Verify the changes in system_user (missing login_user entries)
SELECT id, login_name
FROM system_user
WHERE login_name LIKE 'userwologin-%' LIMIT 5;

-- 7️⃣ Set first_name and last_name = login_name (skip atomfeed)
UPDATE system_user
SET first_name = login_name,
    last_name = login_name
WHERE login_name NOT IN ('atomfeed');

-- Verify the changes in system_user (first_name and last_name)
SELECT id, first_name, last_name
FROM system_user
WHERE first_name = last_name LIMIT 5;
