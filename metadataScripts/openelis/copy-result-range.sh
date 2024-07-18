#!/bin/sh

# The script imports result range data from a CSV file into a PostgreSQL table (result_limits). It retrieves item_id 
# for each concept_uuid, determines the next available ID, and inserts the data into the table. The script ensures 
# gender is a single uppercase character, uses default values for empty fields, and handles errors gracefully, logging 
# the outcome of each insert operation with the row number and Concept UUID.

DATABASE_NAME="clinlims"
TABLE="result_limits"
CSV_FILE="${CSV_FILE_PATH}"

DATABASE=${POSTGRES_DB:-$DATABASE_NAME}
USER=${POSTGRES_USER:-postgres}
HOST=${POSTGRES_HOST:-$OPENELIS_DB_SERVER}
PORT=${POSTGRES_PORT:-5432}

# Check if the CSV file exists
if [ ! -f "$CSV_FILE" ]; then
    echo "SEVERE:CSV file not found!"
    exit 1
fi

# Function to get the next available ID from result_limits table
get_next_id() {
    local next_id=$(psql -U "$USER" -d "$DATABASE" -h "$HOST" -p "$PORT" -t -c "SELECT COALESCE(MAX(id), 0) + 1 FROM $TABLE;")
    echo $next_id
}

# Function to get the item_id from external_reference table
get_item_id() {
    local concept_uuid=$1
    local item_id=$(psql -U "$USER" -d "$DATABASE" -h "$HOST" -p "$PORT" -t -c "SELECT item_id FROM external_reference WHERE external_id='$concept_uuid' LIMIT 1;")
    echo $item_id
}

# Read the CSV file and insert data into the PostgreSQL table
row_number=1
tail -n +2 "$CSV_FILE" | while IFS=',' read -r concept_uuid gender min_age max_age low_normal high_normal low_valid high_valid
do
    row_number=$((row_number + 1))
    # Check if Concept UUID is empty
    [ -z "$concept_uuid" ] && echo "WARN: Concept UUID not found or empty in row $row_number! Skipping row." && continue
    # Get item_id from external_reference
    item_id=$(get_item_id "$concept_uuid")
    test_result_type_id=4
    if [ -z "$item_id" ]; then
        echo "Item ID for Concept UUID $concept_uuid not found in row $row_number!"
        continue
    fi
    # Get next available ID
    next_id=$(get_next_id)
    # Check for empty fields and use default values if necessary
    [ -z "$gender" ] && gender=NULL || gender=$(echo "$gender" | tr '[:lower:]' '[:upper:]' | cut -c1)
    [ -z "$min_age" ] && min_age=0
    [ -z "$max_age" ] && max_age=DEFAULT
    [ -z "$low_normal" ] && low_normal=DEFAULT
    [ -z "$high_normal" ] && high_normal=DEFAULT
    [ -z "$low_valid" ] && low_valid=DEFAULT
    [ -z "$high_valid" ] && high_valid=DEFAULT
    # Insert data into the PostgreSQL table
    psql -U "$USER" -d "$DATABASE" -h "$HOST" -p "$PORT" -c \
    "INSERT INTO $TABLE (id, test_id, test_result_type_id, gender, min_age, max_age, low_normal, high_normal, low_valid, high_valid) VALUES ($next_id,$item_id, $test_result_type_id, '$gender', $min_age, $max_age, $low_normal, $high_normal, $low_valid, $high_valid);"
    # Check the result of the insert operation
    case $? in
        0)
            echo "INFO: Inserted data for Concept UUID $concept_uuid, row $row_number."
            ;;
        1)
            echo "SEVERE: Fatal error occurred while inserting data for Concept UUID $concept_uuid, row $row_number."
            ;;
        2)
            echo "ERROR: Connection to the database server failed while inserting data for Concept UUID $concept_uuid, row $row_number."
            ;;
        3)
            echo "ERROR: An error occurred in the SQL script for Concept UUID $concept_uuid, row $row_number."
            ;;
    esac
done
