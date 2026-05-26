FROM mysql:8.0

COPY demo/db-backups/1.0.0-standard/openmrs/resources/configuration_checksums  /configuration_checksums
COPY demo/db-backups/1.0.0-standard/openmrs/resources/*.sql.gz /docker-entrypoint-initdb.d/
