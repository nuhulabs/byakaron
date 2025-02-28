#!/bin/bash
set -e

echo "Waiting for MySQL to be ready..."
while ! mysql -h db-mysql -u root -e "SELECT 1" >/dev/null 2>&1; do
  echo "MySQL is unavailable - sleeping"
  sleep 2
done
echo "MySQL is up and running!"

# Check if data already exists in MySQL
DATA_EXISTS=$(mysql -h db-mysql -u root -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'bngc'" | grep -v "COUNT" | tr -d ' ')

if [ "$DATA_EXISTS" -gt "0" ]; then
  echo "Data already exists in MySQL database. Skipping dump loading."
else
  echo "Loading MySQL dump..."
  mysql -h db-mysql -u root bngc < /app/dump.sql
  echo "MySQL dump loaded successfully!"
fi

echo "Waiting for PostgreSQL to be ready..."
while ! pg_isready -h db -U bngc >/dev/null 2>&1; do
  echo "PostgreSQL is unavailable - sleeping"
  sleep 2
done
echo "PostgreSQL is up and running!"

# Check if data already exists in PostgreSQL
PG_DATA_EXISTS=$(PGPASSWORD=bngc psql -h db -U bngc -d bngc -t -c "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'wiki'" | tr -d ' ')

if [ "$PG_DATA_EXISTS" -gt "0" ]; then
  echo "Data already exists in PostgreSQL database. Skipping migration."
else
  echo "Creating pgloader migration script..."
  cat > /app/migration.load << EOF
LOAD DATABASE
    FROM mysql://root@db-mysql/bngc
    INTO postgresql://bngc:bngc@db/bngc;
EOF

  echo "Starting migration with pgloader..."
  pgloader /app/migration.load
  echo "Migration completed successfully!"
fi 