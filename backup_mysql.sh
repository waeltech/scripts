#!/bin/bash

# Configuration
CONTAINER_NAME="mysql" # Name of the MySQL container
BACKUP_DIR="/home/debian/backup" # Base directory for backups
DAILY_BACKUP_DIR="/home/debian/backup/daily_backup"     # Directory for daily backups
WEEKLY_BACKUP_DIR="/home/debian/backup/weekly_backup"   # Directory for weekly backups
RETENTION_DAYS=7    # Number of days to retain daily backups
RETENTION_WEEKS=8   # Number of weeks to retain weekly backups
MYSQL_USER="root"   # MySQL user with backup privileges
MYSQL_PASSWORD="SERVER_PASSWORD"  # MySQL password

# Create backup directories if they don't exist
mkdir -p "$BACKUP_DIR"
mkdir -p "$DAILY_BACKUP_DIR"
mkdir -p "$WEEKLY_BACKUP_DIR"

# Get a list of databases excluding the default system databases
DATABASES=$(docker exec "$CONTAINER_NAME" sh -c \
    "mysql -u$MYSQL_USER -p$MYSQL_PASSWORD -e 'SHOW DATABASES;' | tail -n +2 | grep -Ev '^(information_schema|mysql|performance_schema|sys)$'")

if [ -z "$DATABASES" ]; then
    echo "No databases found or connection failed!" >&2
    exit 1
fi

# Function to perform backups
perform_backup() {
    BACKUP_DIR=$1
    BACKUP_TYPE=$2
    for DB in $DATABASES; do
        BACKUP_FILE="$BACKUP_DIR/${DB}_backup_$(date +'%Y-%m-%d').sql"
        docker exec "$CONTAINER_NAME" sh -c \
            "mysqldump -u$MYSQL_USER -p$MYSQL_PASSWORD $DB" > "$BACKUP_FILE"

        if [ $? -eq 0 ]; then
            echo "$BACKUP_TYPE backup successfully created for database '$DB' at $BACKUP_FILE"
        else
            echo "$BACKUP_TYPE backup failed for database '$DB'!" >&2
        fi
    done
}

# Perform daily backups
perform_backup "$DAILY_BACKUP_DIR" "Daily"

# If today is Friday, perform weekly backups
if [ "$(date +%u)" -eq 5 ]; then
    perform_backup "$WEEKLY_BACKUP_DIR" "Weekly"
fi

# Remove backups older than retention period
find "$DAILY_BACKUP_DIR" -type f -name "*.sql" -mtime +$RETENTION_DAYS -exec rm {} \;
find "$WEEKLY_BACKUP_DIR" -type f -name "*.sql" -mtime +$((RETENTION_WEEKS * 7)) -exec rm {} \;

# Copy backup files to our backup server change user and server ip accordingly
rsync -avz /home/debian/backup/ ubuntu@127.0.0.1:backup