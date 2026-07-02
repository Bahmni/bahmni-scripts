FROM mysql:8.0

# Copy configuration_checksums & DB Backup
COPY demo/db-backups/3.0.0-lite/mysql8.0/resources/configuration_checksums  /configuration_checksums
COPY demo/db-backups/3.0.0-lite/mysql8.0/resources/*.sql.gz /docker-entrypoint-initdb.d/
