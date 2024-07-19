# Metadata Script
Application specific utilities and scripts for Bahmni

## 📦 [copy-result-range.sh](./openelis/copy-result-range.sh)

The script imports result range data from a CSV file into a PostgreSQL table (result_limits). It retrieves item_id for each concept_uuid, determines the next available ID, and inserts the  data into the table. The script ensures gender is a single uppercase character, uses default values for empty fields, and handles errors gracefully, logging the outcome of each insert operation with the row number and Concept UUID.

To use this script:

1. Download the [copy-result-range.sh](./openelis/copy-result-range.sh), define result ranges in CSV format, and then copy them to the appropriate directories within your `bahmni-docker` folder.
    
    _**NOTE**: Ensure that the CSV file (result-ranges.csv) is correctly formatted as shown below:_
    ```
    Concept UUID,Gender,Min Age,Max Age,Normal Low,Normal High,Valid Low,Valid High
    ```
2. Update the `openelisdb` service configuration in your Docker Compose file to mount the script and CSV file into the container.
3. Access the `openelisdb-1` container and ensure that the script has executable permissions.
    ```
    cd resources && chmod +x copy-result-range.sh
    ```
    **_NOTE:_** Replace `./image-scanner.sh` with the actual path to your script file if it's located in a different directory.
4. Access the `openelisdb-1` container and run the script with the appropriate environment variables.
    ```
    CSV_FILE_PATH="result-ranges.csv" \
    POSTGRES_DB="clinlims" \
    POSTGRES_USER="clinlims" \
    ./copy-result-range.sh
    ```

## 📦 [set_saleable_attribute.sh](./openmrs/set_saleable_attribute.sh)

This script allows to set the `saleable` attribute to true for the concepts matched by UUIDS read from a CSV file. This is specifically useful when concepts in bulk needs to be updated with the attribute so that it gets synced with Odoo as products. An example could be `Procedure` concepts. 

The script leverages the concept attribute APIs `/openmrs/ws/rest/v1/concept/$uuid/attribute` and `/openmrs/ws/rest/v1/conceptattributetype?q=saleable&limit=1`

Usage of this script:
1. Prepare a CSV which contains the UUIDs of the concepts which needs to be updated in the first column.

2. Run the script by passing the required parameters

    ```./set_saleable_attribute.sh path/to/uuids.csv domain username password```

3. Example:

    ```./set_saleable_attribute.sh procedures.csv localhost superman Admin123```
