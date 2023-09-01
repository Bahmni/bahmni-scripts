#!/bin/bash
HOST_NAME=localhost
LOCATION_COOKIE="%7B%22name%22%3A%22Bahmni%20Clinic%22%2C%22uuid%22%3A%22833d0c66-e29a-4d31-ac13-ca9050d1bfa9%22%7D"
PATIENT_CSV_PATH=./patients.csv
ENCOUNTER_CSV_PATH=./encounters.csv
echo "Getting Session ID"
SESSION_ID=$(curl -s -D - -L https://${HOST_NAME}/openmrs/ws/rest/v1/session -H 'Authorization: Basic c3VwZXJtYW46QWRtaW4xMjM=' --insecure | grep -i 'Set-Cookie' | grep -i 'JSESSIONID' | awk -F'[=;]' '/JSESSIONID/{print $2}')
echo "Session ID: $SESSION_ID"

echo "Importing Patients"
curl -F file=@${PATIENT_CSV_PATH} https://${HOST_NAME}/openmrs/ws/rest/v1/bahmnicore/admin/upload/patient --insecure --header "Cookie: JSESSIONID=${SESSION_ID}" --header 'Content-Type: multipart/form-data'

echo "Sleeping for 5 minutes"
sleep 300

echo "Importing Encounters"
curl -F file=@${ENCOUNTER_CSV_PATH} https://${HOST_NAME}/openmrs/ws/rest/v1/bahmnicore/admin/upload/encounter --insecure --header "Cookie: JSESSIONID=${SESSION_ID};bahmni.user.location=${LOCATION_COOKIE}" --header 'Content-Type: multipart/form-data'