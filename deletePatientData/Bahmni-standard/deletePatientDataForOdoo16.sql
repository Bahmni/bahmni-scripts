-- =====================================================
-- Author: Akhil Anto Tharayil
-- Purpose: Clear transactional data safely in Odoo 16
-- Safety:
--   - NEVER uses TRUNCATE ... CASCADE
--   - DOES NOT delete res_users or res_partner
--   - Customers are archived (active=false), not deleted
-- =====================================================

-- IMPORTANT:
-- Run with Odoo service STOPPED

BEGIN;

-- -------------------------
-- SALES
-- -------------------------
DELETE FROM sale_order_line_invoice_rel;
DELETE FROM account_tax_sale_order_line_rel;
DELETE FROM sale_order_line;
DELETE FROM sale_order;

-- -------------------------
-- PURCHASE
-- -------------------------
DELETE FROM account_tax_purchase_order_line_rel;
DELETE FROM purchase_order_line;
DELETE FROM purchase_order WHERE state IN ('draft','sent');


-- -------------------------
-- POS
-- -------------------------
DELETE FROM account_tax_pos_order_line_rel;
DELETE FROM pos_pack_operation_lot;
DELETE FROM pos_order_line;
DELETE FROM pos_order;

-- -------------------------
-- ACCOUNTING
-- -------------------------
DELETE FROM account_partial_reconcile;
DELETE FROM account_full_reconcile;

DELETE FROM account_move_line;
DELETE FROM account_move
WHERE move_type IN (
    'out_invoice',
    'out_refund',
    'in_invoice',
    'in_refund',
    'out_receipt',
    'in_receipt'
);

-- -------------------------
-- ANALYTICS
-- -------------------------
DELETE FROM account_analytic_line;

-- -------------------------
-- MAIL / ACTIVITY
-- -------------------------
DELETE FROM mail_message
WHERE model IN (
    'sale.order',
    'purchase.order',
    'account.move',
    'pos.order'
);

DELETE FROM mail_activity;

-- -------------------------
-- EVENTS
-- -------------------------
DELETE FROM event_records_offset_marker;
DELETE FROM event_records;
DELETE FROM markers;

-- -------------------------
-- ARCHIVE CUSTOMERS (SAFE)
-- -------------------------
-- Archive only customers NOT linked to any user
UPDATE res_partner
SET active = FALSE
WHERE is_company = FALSE
  AND customer_rank > 0
  AND user_id IS NULL;  -- VERY important

-- WHY ARCHIVE, NOT DELETE:
-- res_users has a mandatory FK to res_partner.
-- Deleting partners can indirectly wipe users.
-- Archiving keeps history + prevents user loss.

-- DELETE only partners that are:
-- 1. Not companies
-- 2. Not linked to any user
-- 3. Customers (customer_rank > 0)

-- DELETE FROM res_partner_attributes
-- WHERE partner_id IN (
    -- SELECT id FROM res_partner
    -- WHERE is_company = FALSE
      -- AND customer_rank > 0
      -- AND id NOT IN (SELECT partner_id FROM res_users)
-- );

-- DELETE FROM res_partner
-- WHERE is_company = FALSE
  -- AND customer_rank > 0
  -- AND id NOT IN (SELECT partner_id FROM res_users);
  

-- NOTE:
-- Please ensure the Bahmni Community module (bahmni_customer_return) is installed.
-- If this module is not installed, executing this query will result in an error.
-- Bahmni Customer Returns
DELETE FROM bahmni_customer_return
WHERE customer_id IN (
    SELECT id FROM res_partner
    WHERE active = FALSE
);

-- Account Payments
-- Delete all account payments (careful!)
DELETE FROM account_payment;


COMMIT;

-- =====================================================
-- END
-- =====================================================
