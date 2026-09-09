\set ON_ERROR_STOP true

-- ===============================
-- TRUNCATE TABLES
-- ===============================
TRUNCATE failed_events;
TRUNCATE mail_message CASCADE;
TRUNCATE mail_followers CASCADE;

-- ===============================
-- MASK ADDRESSES
-- ===============================
UPDATE res_partner
SET street  = concat('address1-', id),
    street2 = concat('address2-', id),
    city    = concat('address3-', id);

-- ===============================
-- MASK USERS (EXCLUDE admin, emrsync)
-- ===============================
UPDATE res_users
SET login = concat('user-', id)
WHERE login NOT IN ('admin', 'emrsync');

-- Set everyone's password as 'password' (hashed)
UPDATE res_users
SET password = '$1$lw8k34ec$xOY5xkPtTgTw/gN6nHiZq.'
WHERE login NOT IN ('admin', 'emrsync');

-- ===============================
-- MASK EVENT RECORDS
-- ===============================
UPDATE event_records
SET object = regexp_replace(object, '"customerId": "(.+?)"', '"customerId": "XXX123456"')
WHERE object::text LIKE '%customerId%';

-- ===============================
-- MASK MAIL ALIAS
-- ===============================
UPDATE mail_alias
SET alias_name = concat('alias-', id);

-- ===============================
-- MASK PARTNER NAMES
-- ===============================
UPDATE res_partner
SET name = concat('User ', id),
display_name = concat('User ', id);

-- ===============================
-- MASK PROVIDER NAME IN SALE ORDER
-- ===============================
UPDATE sale_order
SET provider_name = 'Provider-' || id;

-- ===============================
-- REMOVE PARTNER IMAGES (stored in ir_attachment)
-- ===============================
UPDATE ir_attachment
SET db_datas = NULL
WHERE res_model = 'res.partner' AND res_field LIKE 'image%';

-- ===============================
-- SELECT QUERIES TO VERIFY CHANGES
-- ===============================

-- Verify partner addresses
SELECT id, street, street2, city
FROM res_partner
LIMIT 5;

-- Verify masked users
SELECT id, login, password
FROM res_users
WHERE login NOT IN ('admin', 'emrsync')
LIMIT 5;

-- Verify event records masking
SELECT id, object
FROM event_records
WHERE object::text LIKE '%XXX123456%'
LIMIT 5;

-- Verify mail_alias
SELECT id, alias_name
FROM mail_alias
LIMIT 5;

-- Verify partner names
SELECT id, name
FROM res_partner
LIMIT 5;

-- Verify partner images removed
SELECT id, name, res_field, db_datas IS NULL AS image_removed
FROM ir_attachment
WHERE res_model = 'res.partner' AND res_field LIKE 'image%'
LIMIT 5;

