#!/bin/bash

# Log dizinini oluştur
mkdir -p /app/logs

echo "Starting db-sync Scheduler Service..."
echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] Container started (Scheduler Mode)"

# Cron başlat
exec cron -f
