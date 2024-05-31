FROM mysql:5.7

COPY demo/db-backups/1.0.0-standard/openmrs/mysql5.7/resources/configuration_checksums  /configuration_checksums
COPY demo/db-backups/1.0.0-standard/openmrs/mysql5.7/resources/*.sql.gz /docker-entrypoint-initdb.d/
