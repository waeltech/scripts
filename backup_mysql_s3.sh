#!/bin/bash
#
# MySQL Backup Script with S3 Upload & Retention Policy
# Runs on Debian, keeps 7 daily and 4 weekly backups
# Requires: Docker, AWS CLI, gzip
# Set AWS_PROFILE environment variable to use a specific AWS CLI profile
# Set cron job for daily backups
# 0 2 * * * /path/to/backup_mysql_s3.sh

# ===== CONFIGURATION =====
MYSQL_USER="root"
MYSQL_PASSWORD="ROOT_PASSWORD"
MYSQL_HOST="localhost"
MYSQL_CONTAINER="mysql"

S3_BUCKET="s3://backup/mysql-backups"  # change to match your S3 bucket
S3_REGION="eu-west-1"
S3_ENDPOINT="https://s3.eu-west-1.wasabisys.com" # change to match your S3 endpoint
BACKUP_DIR="/home/wael/backups/mysql"

# Date formats
DATE=$(date +%F)
WEEK=$(date +%G-%V)   # ISO Year-Week

# Create directories
DAILY_DIR="$BACKUP_DIR/daily"
WEEKLY_DIR="$BACKUP_DIR/weekly"

mkdir -p "$DAILY_DIR" "$WEEKLY_DIR" || {
    echo "[$(date)] ERROR: Failed to create backup directories"
    exit 1
}

# ===== BACKUP ALL DATABASES (inside Docker container) =====
echo "[$(date)] Starting MySQL per-database backup from Docker container '$MYSQL_CONTAINER'..."

# Get list of databases (excluding system DBs)
DBS=$(docker exec "$MYSQL_CONTAINER" \
  mysql -h "$MYSQL_HOST" -u "$MYSQL_USER" -p"$MYSQL_PASSWORD" \
  -e "SHOW DATABASES;" | grep -Ev "(Database|information_schema|performance_schema|mysql|sys)")

if [ -z "$DBS" ]; then
    echo "[$(date)] ERROR: No databases found to back up!"
    exit 1
fi

# Backup each DB individually
for DB in $DBS; do
    BACKUP_FILE="$DAILY_DIR/${DB}_${DATE}.sql.gz"
    docker exec "$MYSQL_CONTAINER" sh -c \
      "mysqldump -h $MYSQL_HOST -u $MYSQL_USER -p\"$MYSQL_PASSWORD\" --single-transaction --quick --lock-tables=false \"$DB\"" \
      | gzip > "$BACKUP_FILE"
    
    if [ $? -eq 0 ]; then
        echo "[$(date)] Backup complete: $BACKUP_FILE"
    else
        echo "[$(date)] ERROR: Backup failed for $DB"
    fi
done

# ===== CREATE WEEKLY BACKUP (Sundays) =====
if [ "$(date +%u)" -eq 7 ]; then
    cp "$DAILY_DIR"/*_"$DATE".sql.gz "$WEEKLY_DIR"/
    echo "[$(date)] Weekly backups saved."
fi

# ===== UPLOAD TO (S3-Compatible) =====
echo "[$(date)] Uploading backups to  S3..."
/usr/local/bin/aws --profile wasabi --endpoint-url="$S3_ENDPOINT" s3 sync "$DAILY_DIR" "$S3_BUCKET/daily" --exact-timestamps
/usr/local/bin/aws --profile wasabi --endpoint-url="$S3_ENDPOINT" s3 sync "$WEEKLY_DIR" "$S3_BUCKET/weekly" --exact-timestamps

# ===== RETENTION POLICY =====
# Keep last 7 daily backups locally
find "$DAILY_DIR" -type f -mtime +6 -delete
# Keep last 7 daily backups remotely
/usr/local/bin/aws --profile wasabi  --endpoint-url="$S3_ENDPOINT" s3 ls "$S3_BUCKET/daily/" | awk '{print $4}' | sort | head -n -7 | while read file; do
    /usr/local/bin/aws --profile wasabi --endpoint-url="$S3_ENDPOINT" s3 rm "$S3_BUCKET/daily/$file"
done

# Keep last 4 weekly backups locally
find "$WEEKLY_DIR" -type f -mtime +27 -delete
# Keep last 4 weekly backups remotely
/usr/local/bin/aws --profile wasabi --endpoint-url="$S3_ENDPOINT" s3 ls "$S3_BUCKET/weekly/" | awk '{print $4}' | sort | head -n -4 | while read file; do
    /usr/local/bin/aws --profile wasabi --endpoint-url="$S3_ENDPOINT" s3 rm "$S3_BUCKET/weekly/$file"
done

echo "[$(date)] Backup and cleanup complete."