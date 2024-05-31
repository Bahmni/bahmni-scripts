FROM postgres:16
COPY demo/db-backups/1.0.0-standard/odoo/resources/filestore  /filestore
COPY demo/db-backups/1.0.0-standard/odoo/resources/*.sql.gz /docker-entrypoint-initdb.d/
