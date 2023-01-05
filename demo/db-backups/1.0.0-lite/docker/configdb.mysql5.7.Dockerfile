FROM mysql:5.7

RUN yum update -y && \
    yum install -y \
    unzip \
    gzip

# Copy configuration_checksums & DB Backup
COPY demo/db-backups/1.0.0-lite/mysql5.7/*  .

RUN unzip configuration_checksums.zip && \
    gunzip -c omrs*.gz > /docker-entrypoint-initdb.d/omrs_db_backup.sql && \
    rm configuration_checksums.zip && \
    rm omrs*.gz
