#!/bin/sh
# When running on Docker runOnDocker=1, else another value
runOnDocker=0
download_and_delete_openmrs_patient_data(){
if [ "$runOnDocker" -eq 1 ]; then
    docker exec -i bahmni-standard-openmrsdb-1 mysql -u openmrs-user -ppassword openmrs < deletePatientDataForOpenMRS.sql

else
    mysql -u openmrs-user -ppassword < deletePatientDataForOpenMRS.sql
fi

}

download_and_delete_openelis_patient_data(){
if [ "$runOnDocker" -eq 1 ]
then
    docker exec -i bahmni-standard-openelisdb-1 psql -U postgres < deletePatientDataForOpenElis.sql
    
else 
   psql -U postgres clinlims < deletePatientDataForOpenElis.sql
fi

}

download_and_delete_odoo_patient_data(){
if [ "$runOnDocker" -eq 1 ]
then
    docker exec -i bahmni-standard-odoodb-1 psql -U odoo  < deletePatientDataForOdoo.sql
else
    psql -U odoo odoo< deletePatientDataForOdoo.sql
fi

}

download_and_delete_crater_patient_data(){
docker exec -i bahmni-lite-craterdb-1 mysql -u crater -p < deletePatientForCrater.sql
}

download_and_delete_openmrs_patient_data
download_and_delete_openelis_patient_data
download_and_delete_odoo_patient_data
# download_and_delete_crater_patient_data
