#!/bin/sh
bash .env

OMRS_DB_ContainerName=bahmni-lite-openmrsdb-1
OPENELIS_DB_ContainerName=bahmni-standard-odoodb-1
ODOO_DB_ContainerName=bahmni-standard-odoodb-1
CRATER_DB_ContainerName=bahmni-lite-craterdb-1

OPENMRS_SQL_FILE="deletePatientDataForOpenMRS.sql"
OPENELIS_SQL_FILE="deletePatientDataForOpenElis.sql"
ODOO_SQL_FILE="deletePatientDataForOdoo.sql"
CRATER_SQL_FILE="deletePatientDataForCrater.sql"
# When running on Docker runOnDocker=1, else another value
runOnDocker=1
download_and_delete_openmrs_patient_data(){
if [ "$runOnDocker" -eq 1 ]; then
    docker exec -i $OMRS_DB_ContainerName mysql -u$OPENMRS_DB_USERNAME -p$OPENMRS_DB_PASSWORD openmrs < $OPENMRS_SQL_FILE
else
    mysql -u$OPENMRS_DB_USERNAME -p$OPENMRS_DB_PASSWORD < $OPENMRS_SQL_FILE
fi

}

download_and_delete_openelis_patient_data(){
if [ "$runOnDocker" -eq 1 ]
then
    docker exec -i $OPENELIS_DB_ContainerName psql -U postgres < $OPENELIS_SQL_FILE
else 
    psql -U postgres clinlims < $OPENELIS_SQL_FILE
fi

}

download_and_delete_odoo_patient_data(){
if [ "$runOnDocker" -eq 1 ]
then
    docker exec -i $ODOO_DB_ContainerName psql -U $ODOO_DB_USER  < $ODOO_SQL_FILE
else
    psql -U $ODOO_DB_USER odoo< $ODOO_SQL_FILE
fi
}

download_and_delete_crater_patient_data(){
    docker exec -i $CRATER_DB_ContainerName mysql -u$CRATER_DB_USERNAME -p$CRATER_DB_PASSWORD crater < $CRATER_SQL_FILE
}
# When running bahmni-lite uncomment download_and_delete_crater_patient_data and Comment download_and_delete_openelis_patient_data and download_and_delete_odoo_patient_data
download_and_delete_openmrs_patient_data
download_and_delete_openelis_patient_data
download_and_delete_odoo_patient_data
download_and_delete_crater_patient_data
