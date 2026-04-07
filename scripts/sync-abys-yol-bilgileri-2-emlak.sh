#!/bin/bash

# =============================================================================
# Yol Bilgileri Senkronizasyonu
# PostgreSQL (abys.yol_bilgileri_vw) -> PostgreSQL (emlak.yol_bilgileri)
# ogr2ogr ile PG -> PG aktarımı
# =============================================================================

set -euo pipefail

LOG_FILE=""
START_TIME=$(date +%s)

# =============================================================================
# CONFIGURATION
# =============================================================================

load_config() {
    for env_file in "/app/.env" ".env" "../.env"; do
        if [ -f "$env_file" ]; then
            set -a
            eval "$(sed 's/\r$//' "$env_file")"
            set +a
            break
        fi
    done
    
    local log_dir
    for dir in "/app/logs" "./logs"; do
        if mkdir -p "$dir" 2>/dev/null; then
            log_dir="$dir"
            break
        fi
    done
    LOG_FILE="${log_dir:-./}/sync-abys-yol-bilgileri-2-emlak.log"
    
    # Source Database configuration (PostgreSQL)
    PG_YONCA_HOST="${PG_YONCA_HOST:-localhost}"
    PG_YONCA_PORT="${PG_YONCA_PORT:-5432}"
    PG_YONCA_DATABASE="${PG_YONCA_DATABASE:-}"
    PG_YONCA_USER="${PG_YONCA_USER:-postgres}"
    PG_YONCA_PASSWORD="${PG_YONCA_PASSWORD:-}"

    # Target Database configuration (PostgreSQL)
    PG_EMLAK_HOST="${PG_EMLAK_HOST:-localhost}"
    PG_EMLAK_PORT="${PG_EMLAK_PORT:-5432}"
    PG_EMLAK_DATABASE="${PG_EMLAK_DATABASE:-}"
    PG_EMLAK_USER="${PG_EMLAK_USER:-postgres}"
    PG_EMLAK_PASSWORD="${PG_EMLAK_PASSWORD:-}"
    PG_EMLAK_TABLE="${PG_EMLAK_TABLE:-yol_bilgileri}"

    # Sync mode: truncate or recreate
    SYNC_MODE="${SYNC_MODE:-truncate}"
    
    # PostgreSQL environment
    export GDAL_CACHEMAX=2048
}

# =============================================================================
# LOGGING
# =============================================================================

log()         { local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [${2:-INFO}] $1"; echo "$msg" | tee -a "$LOG_FILE"; }
log_error()   { log "$1" "ERROR" >&2; }
log_warn()    { log "$1" "WARN"; }
log_success() { log "$1" "SUCCESS"; }
exit_with_error() { log_error "$1"; exit 1; }

# =============================================================================
# VALIDATION
# =============================================================================

check_dependencies() {
    log "Checking dependencies..."
    local missing=()
    for cmd in ogr2ogr sqlplus psql; do
        command -v "$cmd" >/dev/null || missing+=("$cmd")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        exit_with_error "Missing dependencies: ${missing[*]}"
    fi
    log_success "All dependencies found"
}

test_connections() {
    log "Testing database connections..."    
    # Test Source PostgreSQL
    if ! PGPASSWORD="$PG_YONCA_PASSWORD" psql -h "$PG_YONCA_HOST" -p "$PG_YONCA_PORT" \
        -U "$PG_YONCA_USER" -d "$PG_YONCA_DATABASE" -c "SELECT 1;" >/dev/null 2>&1; then
        exit_with_error "Source PostgreSQL connection failed"
    fi    
    # Test Target PostgreSQL
    if ! PGPASSWORD="$PG_EMLAK_PASSWORD" psql -h "$PG_EMLAK_HOST" -p "$PG_EMLAK_PORT" \
        -U "$PG_EMLAK_USER" -d "$PG_EMLAK_DATABASE" -c "SELECT 1;" >/dev/null 2>&1; then
        exit_with_error "Target PostgreSQL connection failed"
    fi    
    log_success "Database connections successful"
}

# =============================================================================
# SQL QUERY
# =============================================================================

get_sql_query() {
    cat <<'EOF'
SELECT
    id::bigint                          AS id,
    segment_id::bigint                  AS segment_id,
    uavt::bigint                        AS uavt,
    sokak                               AS sokak,
    tip                                 AS tip,
    mahalle                             AS mahalle,
    ilce                                AS ilce,
    location::geometry                  AS location
FROM abys.yol_bilgileri_vw
EOF
}

# =============================================================================
# MAIN OPERATIONS
# =============================================================================

check_and_prepare_table() {
    log "Checking PostgreSQL target table status..."
    
    local table_exists
    table_exists=$(PGPASSWORD="$PG_EMLAK_PASSWORD" psql -h "$PG_EMLAK_HOST" \
        -p "$PG_EMLAK_PORT" -U "$PG_EMLAK_USER" -d "$PG_EMLAK_DATABASE" \
        -t -c "SELECT EXISTS (SELECT FROM information_schema.tables WHERE table_name = '$PG_EMLAK_TABLE');" 2>/dev/null | \
        tr -d ' ')
    
    if [ "$table_exists" = "t" ]; then
        log "Table exists, truncating..."
        truncate_postgresql_table
        return 0
    else
        log "Table does not exist, will be created by OGR2OGR..."
        return 1
    fi
}

truncate_postgresql_table() {
    log "Truncating PostgreSQL table: $PG_EMLAK_TABLE"
    
    PGPASSWORD="$PG_EMLAK_PASSWORD" psql -h "$PG_EMLAK_HOST" \
        -p "$PG_EMLAK_PORT" -U "$PG_EMLAK_USER" -d "$PG_EMLAK_DATABASE" \
        -c "TRUNCATE TABLE $PG_EMLAK_TABLE RESTART IDENTITY CASCADE;" 2>&1 | tee -a "$LOG_FILE"
    
    local exit_code=${PIPESTATUS[0]}
    
    if [ $exit_code -ne 0 ]; then
        log_error "Failed to truncate PostgreSQL table"
        exit 1
    fi
    
    log_success "PostgreSQL table truncated successfully"
}

sync_data() {
    log "Starting data synchronization..."
    
    # Tablo varsa truncate, yoksa OGR2OGR oluşturacak
    local table_exists=false
    if check_and_prepare_table; then
        table_exists=true
    fi
    
    local sql_query
    sql_query=$(get_sql_query)

    log "Executing OGR2OGR data transfer..."
    
    if [ "$table_exists" = true ]; then
        # Tablo var - APPEND modu
        log "Using APPEND mode (table exists)..."
        ogr2ogr -f "PostgreSQL" \
            "PG:host=${PG_EMLAK_HOST} port=${PG_EMLAK_PORT} dbname=${PG_EMLAK_DATABASE} user=${PG_EMLAK_USER} password=${PG_EMLAK_PASSWORD}" \
            "PG:host=${PG_YONCA_HOST} port=${PG_YONCA_PORT} dbname=${PG_YONCA_DATABASE} user=${PG_YONCA_USER} password=${PG_YONCA_PASSWORD}" \
            -sql "$sql_query" \
            -nln "$PG_EMLAK_TABLE" \
            -append \
            -lco LAUNDER=NO \
            -lco GEOMETRY_NAME=location \
            -lco PRECISION=YES \
            -lco FID=ogr_fid \
            -skipfailures \
            -a_srs "EPSG:2320" \
            -gt 65536 \
            -progress \
            --config PG_USE_COPY YES \
            2>&1 | tee -a "$LOG_FILE"
    else
        # Tablo yok - CREATE modu
        log "Using CREATE mode (table will be created)..."
        ogr2ogr -f "PostgreSQL" \
            "PG:host=${PG_EMLAK_HOST} port=${PG_EMLAK_PORT} dbname=${PG_EMLAK_DATABASE} user=${PG_EMLAK_USER} password=${PG_EMLAK_PASSWORD}" \
            "PG:host=${PG_YONCA_HOST} port=${PG_YONCA_PORT} dbname=${PG_YONCA_DATABASE} user=${PG_YONCA_USER} password=${PG_YONCA_PASSWORD}" \
            -sql "$sql_query" \
            -nln "$PG_EMLAK_TABLE" \
            -nlt MULTILINESTRING \
            -lco LAUNDER=NO \
            -lco GEOMETRY_NAME=location \
            -lco DIM=2 \
            -lco FID=ogr_fid \
            -a_srs "EPSG:2320" \
            -lco PRECISION=YES \
            -gt 65536 \
            -progress \
            --config PG_USE_COPY YES \
            2>&1 | tee -a "$LOG_FILE"
        
        # İlk oluşturmada spatial index ekle
        create_spatial_index
    fi
    
    local exit_code=${PIPESTATUS[0]}
    
    if [ $exit_code -ne 0 ]; then
        log_error "OGR2OGR failed with exit code: $exit_code"
        exit 1
    fi
    
    # Veri kontrolü yap
    log "Verifying data transfer..."
    local target_count
    target_count=$(PGPASSWORD="$PG_EMLAK_PASSWORD" psql -h "$PG_EMLAK_HOST" \
        -p "$PG_EMLAK_PORT" -U "$PG_EMLAK_USER" -d "$PG_EMLAK_DATABASE" \
        -t -c "SELECT COUNT(*) FROM $PG_EMLAK_TABLE;" 2>/dev/null | \
        grep -E '[0-9]+' | head -1 | tr -d ' ' | xargs)
    
    if [ -n "$target_count" ] && [ "$target_count" -gt 0 ]; then
        log_success "Data transfer completed. Transferred records: $target_count"
    else
        log_error "No data transferred to target PostgreSQL"
        exit 1
    fi
}

create_spatial_index() {
    log "Creating spatial index..."
    
    PGPASSWORD="$PG_EMLAK_PASSWORD" psql -h "$PG_EMLAK_HOST" \
        -p "$PG_EMLAK_PORT" -U "$PG_EMLAK_USER" -d "$PG_EMLAK_DATABASE" \
        -c "CREATE INDEX IF NOT EXISTS ${PG_EMLAK_TABLE}_geometry_idx ON ${PG_EMLAK_TABLE} USING GIST (location);" \
        2>&1 | tee -a "$LOG_FILE"
    
    log_success "Spatial index created"
}

update_statistics() {
    log "Updating PostgreSQL table statistics..."
    
    PGPASSWORD="$PG_EMLAK_PASSWORD" psql -h "$PG_EMLAK_HOST" \
        -p "$PG_EMLAK_PORT" -U "$PG_EMLAK_USER" -d "$PG_EMLAK_DATABASE" \
        -c "VACUUM ANALYZE ${PG_EMLAK_TABLE};" 2>&1 | tee -a "$LOG_FILE"
    
    local exit_code=${PIPESTATUS[0]}
    
    if [ $exit_code -eq 0 ]; then
        log_success "Statistics updated successfully"
    else
        log_warn "Failed to update statistics"
    fi
}

# =============================================================================
# MAIN FUNCTION
# =============================================================================

main() {
    load_config
    log "=== TKGM PostgreSQL Sync Started ==="
    check_dependencies
    test_connections
    sync_data
    update_statistics
    local duration=$(($(date +%s) - START_TIME))
    log_success "Sync completed in ${duration} seconds"
    log "Log file: $LOG_FILE"
    cleanup_log_file
}

cleanup_log_file() {
    local max_size=$((100 * 1024 * 1024)) # 100MB
    local keep_size=$((50 * 1024 * 1024)) # 50MB
    
    if [ -f "$LOG_FILE" ]; then
        local current_size=$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)
        
        if [ "$current_size" -gt "$max_size" ]; then
            log "Log file size ($((current_size/1024/1024))MB) exceeds limit ($((max_size/1024/1024))MB). Truncating..."
            
            # Son N byte'ı al (tail -c) - Binary güvenli ve hızlı
            tail -c "$keep_size" "$LOG_FILE" > "${LOG_FILE}.tmp"
            mv "${LOG_FILE}.tmp" "$LOG_FILE"
            
            # Temizlik bilgisini loga ekle
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] Log file truncated. Kept last $((keep_size/1024/1024))MB." >> "$LOG_FILE"
        fi
    fi
}

# =============================================================================
# SCRIPT ENTRY POINT
# =============================================================================

case "${1:-}" in
    "--help"|"-h")
        echo "Usage: $0 [--help|--test|--dry-run]"
        echo "  --help      Show this help"
        echo "  --test      Test connections only"
        echo "  --dry-run   Show SQL query only"
        exit 0
        ;;
    "--test")
        load_config
        check_dependencies
        test_connections
        log_success "Connection tests passed"
        exit 0
        ;;
    "--dry-run")
        echo "SQL Query:"
        get_sql_query
        exit 0
        ;;
    *)
        main
        ;;
esac
