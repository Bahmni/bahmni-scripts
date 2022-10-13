ARG BASE_IMAGE=mysql:5.7
FROM ${BASE_IMAGE}
COPY v0.92/openmrs_backup.sql.gz /docker-entrypoint-initdb.d