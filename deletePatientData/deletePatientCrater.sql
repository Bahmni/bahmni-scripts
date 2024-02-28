use crater
set foreign_key_checks=0;
TRUNCATE table addresses;
TRUNCATE table expenses;
TRUNCATE table expense_categories;
TRUNCATE table taxes;
TRUNCATE table tax_types;
TRUNCATE table invoice_items;
TRUNCATE table invoices;
TRUNCATE table recurring_invoices;
TRUNCATE table estimate_items;
TRUNCATE table estimates;
TRUNCATE table items;
TRUNCATE table notes;
TRUNCATE table email_logs;
TRUNCATE table exchange_rate_logs;
TRUNCATE table exchange_rate_providers;
TRUNCATE table payments;
TRUNCATE table payment_methods;

delete from customers where id >0; 
set foreign_key_checks=1;
