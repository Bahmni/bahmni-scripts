download_and_delete_openmrs_patient_data(){
docker exec -i bahmni-standard-openmrsdb-1 mysql -u openmrs-user -ppassword<<EOF
use openmrs;
set foreign_key_checks=0;

truncate table test_order;
truncate table drug_order;
truncate table note; 
truncate table obs_relationship; 
truncate table concept_proposal; 
truncate table concept_proposal_tag_map;
truncate table obs;
truncate table orders;
truncate table drug_order; 
truncate table test_order; 
truncate table relationship;
truncate table visit_attribute;
truncate table bed_patient_assignment_map;
truncate table encounter_provider;
truncate table episode_encounter;
truncate table order_group;
truncate table encounter; 
truncate table appointmentscheduling_appointment;
truncate table appointmentscheduling_appointment_status_history;
truncate table visit_attribute;
truncate table visit; 
truncate table patient_identifier;
truncate table appointmentscheduling_appointment_request;
truncate table conditions;
truncate table cohort_member;
truncate table patient_program;
truncate table episode_patient_program;
truncate table patient_program_attribute;
truncate table patient_state;
truncate table patient; 
truncate table episode;
truncate table audit_log;
delete from person_address where person_id <> 1;
delete from person_attribute where person_id <> 1;
delete from person_name where not exists
(select u.person_id from users u where person_name.person_id = u.person_id or person_name.person_id = 1)
and not exists (select p.person_id from provider p where person_name.person_id = p.person_id or person_name.person_id = 1);
delete from person where not exists
(select u.person_id from users u where person.person_id = u.person_id or person.person_id = 1)
and not exists (select p.person_id from provider p where person.person_id = p.person_id or person.person_id = 1);
delete from person_address where person_id <> 1;
delete from person_attribute where person_id <> 1;
delete from event_records where category = 'patient' OR category = 'Encounter';
delete from markers where feed_uri like '%feed/patient/recent%' ; 

truncate table event_records_offset_marker;

update bed set status="AVAILABLE";

set foreign_key_checks=1;
EOF

}

download_and_delete_openelis_patient_data(){
docker exec -i bahmni-standard-openelisdb-1 psql -U postgres<<EOF
\c clinlims;
SET search_path TO clinlims;
truncate result_signature,
referral_result,
referral,
result_inventory,
result,
worksheet_analyte,
note,
report_external_export,
report_external_import,
analysis_qaevent,
analysis_storages,
analysis_users,
analysis,
sample_qaevent,
sample_requester,
sample_human,
sample_newborn,
sample_animal,
sample_environmental,
sample_item,
sample_organization,
sample_projects,
sample,
observation_history,
patient,
patient_identity,
patient_occupation,
person_address,
patient_patient_type,
patient_relations,
organization_contact;

delete from person where not exists (select p.person_id from provider p where p.person_id = person.id);
delete from markers where feed_uri like '%atomfeed/encounter/recent%' OR feed_uri like '%atomfeed/patient/recent%';
delete from event_records where category = 'patient';
truncate table event_records_offset_marker;

EOF
}

download_and_delete_openerp_patient_data(){
docker exec -i bahmni-standard-odoodb-1 psql -U odoo<<EOF
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

EOF
}

 download_and_delete_openmrs_patient_data
 download_and_delete_openelis_patient_data
download_and_delete_openerp_patient_data

