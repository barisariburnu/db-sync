#!/bin/bash

# =============================================================================
# Abone Adres Bilgileri Senkronizasyonu
# PostgreSQL (abys.abone_adres_bilgileri_vw) -> Oracle (ABONE_ADRES_BILGILERI)
# ogr2ogr ile PG -> OCI aktarımı
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
    LOG_FILE="${log_dir:-./}/sync_abys_abone_adres_bilgileri.log"

    PG_YONCA_HOST="${PG_YONCA_HOST:-localhost}"
    PG_YONCA_PORT="${PG_YONCA_PORT:-5432}"
    PG_YONCA_DATABASE="${PG_YONCA_DATABASE:-}"
    PG_YONCA_USER="${PG_YONCA_USER:-postgres}"
    PG_YONCA_PASSWORD="${PG_YONCA_PASSWORD:-}"

    ORACLE_YONCA_HOST="${ORACLE_YONCA_HOST:-localhost}"
    ORACLE_YONCA_PORT="${ORACLE_YONCA_PORT:-1521}"
    ORACLE_YONCA_DATABASE="${ORACLE_YONCA_DATABASE:-}"
    ORACLE_YONCA_USER="${ORACLE_YONCA_USER:-}"
    ORACLE_YONCA_PASSWORD="${ORACLE_YONCA_PASSWORD:-}"
    ORACLE_YONCA_SCHEMA="${ORACLE_YONCA_SCHEMA:-}"

    ORACLE_TARGET_TABLE="ABONE_ADRES_BILGILERI"

    export TNS_ADMIN="${TNS_ADMIN:-/usr/lib/oracle/instantclient}"
    export NLS_LANG="AMERICAN_AMERICA.UTF8"
    export NLS_DATE_FORMAT="YYYY-MM-DD HH24:MI:SS"
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
    if ! PGPASSWORD="$PG_YONCA_PASSWORD" psql -h "$PG_YONCA_HOST" -p "$PG_YONCA_PORT" \
        -U "$PG_YONCA_USER" -d "$PG_YONCA_DATABASE" -c "SELECT 1;" >/dev/null 2>&1; then
        exit_with_error "PostgreSQL connection failed"
    fi
    if ! echo "SELECT 1 FROM DUAL;" | sqlplus -s "${ORACLE_YONCA_USER}/${ORACLE_YONCA_PASSWORD}@${ORACLE_YONCA_HOST}:${ORACLE_YONCA_PORT}/${ORACLE_YONCA_DATABASE}" >/dev/null 2>&1; then
        exit_with_error "Oracle connection failed"
    fi
    log_success "Database connections successful"
}

# =============================================================================
# SQL QUERY
# =============================================================================

get_sql_query() {
    cat <<'EOF'
SELECT
    id::bigint                          AS ID,
    abone_no                            AS ABONE_NO,
    sozlesme_no                         AS SOZLESME_NO,
    abone_olus_tarihi                   AS ABONE_OLUS_TARIHI,
    sozlesme_tarihi                     AS SOZLESME_TARIHI,
    abone_adi                           AS ABONE_ADI,
    dma_adi                             AS DMA_ADI,
    abone_tip_kod                       AS ABONE_TIP_KOD,
    abone_tip_ad                        AS ABONE_TIP_AD,
    tarife_turu                         AS TARIFE_TURU,
    sayac_durumu                        AS SAYAC_DURUMU,
    sayac_no                            AS SAYAC_NO,
    son_endeks                          AS SON_ENDEKS,
    ada                                 AS ADA,
    pafta                               AS PAFTA,
    parsel                              AS PARSEL,
    bina_maks_kod::bigint               AS BINA_MAKS_KOD,
    daire_maks_kod::bigint              AS DAIRE_MAKS_KOD,
    adres                               AS ADRES,
    ilce                                AS ILCE,
    mahalle                             AS MAHALLE,
    cadde_sokak                         AS CADDE_SOKAK,
    binano                              AS BINANO,
    daire_no                            AS DAIRE_NO,
    sehir                               AS SEHIR,
    kirsal_mi                           AS KIRSAL_MI,
    fesih_tarihi                        AS FESIH_TARIHI,
    abone_iptal_tarihi                  AS ABONE_IPTAL_TARIHI,
    defter_no::bigint                   AS DEFTER_NO,
    sayfa::bigint                       AS SAYFA,
    taksim::bigint                      AS TAKSIM,
    gis_feature_id::bigint              AS GIS_FEATURE_ID,
    gis_feature_entity                  AS GIS_FEATURE_ENTITY,
    sayac_damga_yili                    AS SAYAC_DAMGA_YILI,
    sayac_yasi                          AS SAYAC_YASI,
    sayac_olcum_turu                    AS SAYAC_OLCUM_TURU,
    sicil_no::bigint                    AS SICIL_NO,
    building_door_location::geometry    AS BUILDING_DOOR_LOCATION
FROM abys.abone_adres_bilgileri_vw
EOF
}

# =============================================================================
# ORACLE OPERATIONS
# =============================================================================

get_record_count() {
    echo "SELECT COUNT(*) FROM ${ORACLE_TARGET_TABLE};" | \
        sqlplus -s "${ORACLE_YONCA_USER}/${ORACLE_YONCA_PASSWORD}@${ORACLE_YONCA_HOST}:${ORACLE_YONCA_PORT}/${ORACLE_YONCA_DATABASE}" 2>/dev/null | \
        grep -E '^[[:space:]]*[0-9]+' | head -1 | tr -d ' ' | xargs
}

check_and_prepare_table() {
    log "Checking Oracle table status..."
    local result
    result=$(echo "
SET SERVEROUTPUT ON
DECLARE
    table_exists NUMBER;
BEGIN
    SELECT COUNT(*) INTO table_exists FROM all_tables
    WHERE owner='${ORACLE_YONCA_SCHEMA}' AND table_name='${ORACLE_TARGET_TABLE}';
    IF table_exists > 0 THEN
        DBMS_OUTPUT.PUT_LINE('EXISTS');
    ELSE
        DBMS_OUTPUT.PUT_LINE('NOT_EXISTS');
    END IF;
END;
/" | sqlplus -s "${ORACLE_YONCA_USER}/${ORACLE_YONCA_PASSWORD}@${ORACLE_YONCA_HOST}:${ORACLE_YONCA_PORT}/${ORACLE_YONCA_DATABASE}" 2>&1 | grep -E "EXISTS|NOT_EXISTS" | tail -1)

    if [[ "$result" == *"EXISTS"* ]] && [[ "$result" != *"NOT_EXISTS"* ]]; then
        log "Table exists, truncating..."
        truncate_oracle_table
        return 0
    else
        log "Table does not exist, will be created by ogr2ogr..."
        return 1
    fi
}

truncate_oracle_table() {
    log "Truncating Oracle table: $ORACLE_TARGET_TABLE"
    local truncate_output
    truncate_output=$(echo "
DECLARE
    v_seq VARCHAR2(100);
BEGIN
    EXECUTE IMMEDIATE 'ALTER TABLE ${ORACLE_YONCA_SCHEMA}.${ORACLE_TARGET_TABLE} NOLOGGING';
    EXECUTE IMMEDIATE 'TRUNCATE TABLE ${ORACLE_YONCA_SCHEMA}.${ORACLE_TARGET_TABLE}';
    BEGIN
        SELECT sequence_name INTO v_seq FROM user_sequences
        WHERE sequence_name LIKE '%${ORACLE_TARGET_TABLE}%' AND ROWNUM = 1;
        EXECUTE IMMEDIATE 'DROP SEQUENCE ' || v_seq;
        EXECUTE IMMEDIATE 'CREATE SEQUENCE ' || v_seq || ' START WITH 1 INCREMENT BY 1';
    EXCEPTION WHEN NO_DATA_FOUND THEN NULL;
    END;
    COMMIT;
END;
/" | sqlplus -s "${ORACLE_YONCA_USER}/${ORACLE_YONCA_PASSWORD}@${ORACLE_YONCA_HOST}:${ORACLE_YONCA_PORT}/${ORACLE_YONCA_DATABASE}" 2>&1)
    echo "$truncate_output" >> "$LOG_FILE"
    log_success "Oracle table truncated"
}

set_table_logging() {
    local mode="$1"
    echo "
BEGIN
    EXECUTE IMMEDIATE 'ALTER TABLE ${ORACLE_YONCA_SCHEMA}.${ORACLE_TARGET_TABLE} $mode';
    COMMIT;
EXCEPTION WHEN OTHERS THEN NULL;
END;
/" | sqlplus -s "${ORACLE_YONCA_USER}/${ORACLE_YONCA_PASSWORD}@${ORACLE_YONCA_HOST}:${ORACLE_YONCA_PORT}/${ORACLE_YONCA_DATABASE}" 2>&1 | tee -a "$LOG_FILE"
}

update_statistics() {
    log "Updating Oracle table statistics..."
    echo "BEGIN DBMS_STATS.GATHER_TABLE_STATS('${ORACLE_YONCA_SCHEMA}', '${ORACLE_TARGET_TABLE}'); END;
/" | sqlplus -s "${ORACLE_YONCA_USER}/${ORACLE_YONCA_PASSWORD}@${ORACLE_YONCA_HOST}:${ORACLE_YONCA_PORT}/${ORACLE_YONCA_DATABASE}" >> "$LOG_FILE" 2>&1
    log_success "Statistics updated"
}

# =============================================================================
# SYNC
# =============================================================================

sync_data() {
    log "Starting data synchronization..."

    local table_exists=false
    if check_and_prepare_table; then
        table_exists=true
    fi

    local sql_query
    sql_query=$(get_sql_query)

    log "Executing ogr2ogr data transfer..."

    if [ "$table_exists" = true ]; then
        log "Using APPEND mode (table exists)..."
        ogr2ogr -f "OCI" \
            "OCI:${ORACLE_YONCA_USER}/${ORACLE_YONCA_PASSWORD}@${ORACLE_YONCA_HOST}:${ORACLE_YONCA_PORT}/${ORACLE_YONCA_DATABASE}:${ORACLE_TARGET_TABLE}" \
            "PG:host=${PG_YONCA_HOST} port=${PG_YONCA_PORT} dbname=${PG_YONCA_DATABASE} user=${PG_YONCA_USER} password=${PG_YONCA_PASSWORD}" \
            -sql "$sql_query" \
            -nln "$ORACLE_TARGET_TABLE" \
            -lco GEOMETRY_NAME=building_door_location \
            -append \
            -lco LAUNDER=NO \
            -lco PRECISION=YES \
            -skipfailures \
            -a_srs "EPSG:2320" \
            -gt 65536 \
            -progress \
            --config PG_USE_COPY YES \
            --config OCI_VARCHAR2_SIZE 4000 \
            --config OCI_UPPERCASE_COLUMN_NAMES YES \
            2>&1 | tee -a "$LOG_FILE"
    else
        log "Using CREATE mode (table will be created)..."
        ogr2ogr -f "OCI" \
            "OCI:${ORACLE_YONCA_USER}/${ORACLE_YONCA_PASSWORD}@${ORACLE_YONCA_HOST}:${ORACLE_YONCA_PORT}/${ORACLE_YONCA_DATABASE}:${ORACLE_TARGET_TABLE}" \
            "PG:host=${PG_YONCA_HOST} port=${PG_YONCA_PORT} dbname=${PG_YONCA_DATABASE} user=${PG_YONCA_USER} password=${PG_YONCA_PASSWORD}" \
            -sql "$sql_query" \
            -nln "$ORACLE_TARGET_TABLE" \
            -lco GEOMETRY_NAME=building_door_location \
            -lco LAUNDER=NO \
            -lco PRECISION=YES \
            -a_srs "EPSG:2320" \
            -gt 65536 \
            -progress \
            --config PG_USE_COPY YES \
            --config OCI_VARCHAR2_SIZE 4000 \
            --config OCI_UPPERCASE_COLUMN_NAMES YES \
            2>&1 | tee -a "$LOG_FILE"
    fi

    local exit_code=${PIPESTATUS[0]}
    if [ $exit_code -ne 0 ]; then
        log_error "ogr2ogr failed with exit code: $exit_code"
        exit 1
    fi

    log "Verifying data transfer..."
    local target_count
    target_count=$(get_record_count)
    if [ -n "$target_count" ] && [ "$target_count" -gt 0 ]; then
        log_success "Data transfer completed. Records: $target_count"
    else
        log_error "No data transferred to Oracle"
        exit 1
    fi

    set_table_logging "LOGGING"
}

# =============================================================================
# MAIN
# =============================================================================

cleanup_log_file() {
    local max_size=$((100 * 1024 * 1024))
    local keep_size=$((50 * 1024 * 1024))
    if [ -f "$LOG_FILE" ]; then
        local current_size=$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)
        if [ "$current_size" -gt "$max_size" ]; then
            tail -c "$keep_size" "$LOG_FILE" > "${LOG_FILE}.tmp"
            mv "${LOG_FILE}.tmp" "$LOG_FILE"
        fi
    fi
}

main() {
    load_config
    log "=== Abone Adres Bilgileri Sync Started ==="
    check_dependencies
    test_connections
    sync_data
    update_statistics
    local duration=$(($(date +%s) - START_TIME))
    log_success "Sync completed in ${duration} seconds"
    cleanup_log_file
}

case "${1:-}" in
    "--help"|"-h") echo "Usage: $0 [--help|--test]"; exit 0 ;;
    "--test") load_config; check_dependencies; test_connections; log_success "OK"; exit 0 ;;
    *) main ;;
esac
