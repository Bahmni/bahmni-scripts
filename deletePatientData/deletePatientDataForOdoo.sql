Truncate table "sale_order_line",
"sale_order",
"account_analytic_line",
"account_analytic_tag_sale_order_line_rel",
"account_tax_sale_order_line_rel",
"procurement_order",
"sale_order_line_invoice_rel",
"account_analytic_line_tag_rel",
"stock_move",
"stock_location_route_procurement",
"stock_quant",
"stock_quant_move_rel",
"stock_location_route_move",
"stock_move_operation_link",
"stock_pack_operation_lot",
"stock_return_picking_line",
"stock_scrap";

delete from res_partner where not exists (select ru.partner_id from res_users ru where ru.partner_id = res_partner.id) and id != 1;
delete from markers where feed_uri like '%atomfeed/encounter/recent%' OR feed_uri like '%atomfeed/patient/recent%';
delete from event_records where category = 'product';
