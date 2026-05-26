FROM mysql:5.6

# Copy configuration_checksums & DB Backup
COPY demo/db-backups/1.0.0-lite/mysql5.6/resources/configuration_checksums  /configuration_checksums
COPY demo/db-backups/1.0.0-lite/mysql5.6/resources/*.sql.gz /docker-entrypoint-initdb.d/
