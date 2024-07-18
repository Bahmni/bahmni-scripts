#!/bin/bash

# Check if the CSV file and credentials are provided as arguments
if [ "$#" -ne 4 ]; then
    echo "Usage: $0 path/to/uuids.csv domain username password"
    exit 1
fi

CSV_FILE="$1"
DOMAIN="$2"
USERNAME="$3"
PASSWORD="$4"

BASE_URL="https://$DOMAIN/openmrs/ws/rest/v1"

# Encode the username and password in base64
AUTH=$(echo -n "$USERNAME:$PASSWORD" | base64)

# Function to fetch the attributeType UUID
fetch_attribute_type_uuid() {
    local url="$BASE_URL/conceptattributetype?q=saleable&limit=1"
    local response
    local uuid

    response=$(curl -s -X GET "$url" \
      -H "Authorization: Basic $AUTH" \
      -H "Accept: application/json")

    # Parse JSON response to extract UUID
    uuid=$(echo "$response" | awk -F '[,:}]' '{for(i=1;i<=NF;i++){if($i~/uuid/){print $(i+1)}}}' | tr -d '"')

    echo "$uuid"
}

# Function to check if the attribute exists
check_attribute() {
    local uuid="$1"
    local url="$BASE_URL/concept/$uuid/attribute"
    local response

    response=$(curl -s -X GET "$url" \
      -H "Authorization: Basic $AUTH" \
      -H "Accept: application/json")

    # Check if the attribute already exists
    if echo "$response" | grep -q "$ATTRIBUTETYPE_UUID"; then
        return 0 # Attribute exists
    else
        return 1 # Attribute does not exist
    fi
}

# Function to make the POST request
make_post_request() {
    local uuid="$1"
    local url="$BASE_URL/concept/$uuid/attribute"
    local payload

    payload=$(cat <<EOF
{
  "attributeType": "$ATTRIBUTETYPE_UUID",
  "value": "true"
}
EOF
)

    curl -X POST "$url" \
      -H "Authorization: Basic $AUTH" \
      -H "Content-Type: application/json" \
      -d "$payload"

    echo "POST request sent for UUID: $uuid"
}

# Fetch the attributeType UUID
ATTRIBUTETYPE_UUID=$(fetch_attribute_type_uuid)
echo "Fetched attributeType UUID: $ATTRIBUTETYPE_UUID"

# Read the CSV file line by line, skipping the header row
tail -n +2 "$CSV_FILE" | while IFS=, read -r uuid _; do
    echo "Processing UUID: $uuid"

    if check_attribute "$uuid"; then
        echo "Attribute with UUID $ATTRIBUTETYPE_UUID already exists for concept $uuid. Skipping POST request."
    else
        echo "Attribute with UUID $ATTRIBUTETYPE_UUID not found for concept $uuid. Making POST request."
        make_post_request "$uuid"
    fi
done

echo "All requests have been processed."
