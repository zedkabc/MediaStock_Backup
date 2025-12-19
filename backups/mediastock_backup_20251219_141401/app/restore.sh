#!/bin/bash

################################################################################
# Script de restauration pour MediaStock (Docker Compose + MySQL)
################################################################################

set -euo pipefail

# ---- CONFIG ----
DEFAULT_BACKUP_DIR="/opt/mediastock_backups"
DEFAULT_TARGET_DIR="$(pwd)"
BACKUP_DIR=""
TARGET_DIR=""
BACKUP_FILE_ARG=""
LOG_FILE=""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---- Colors ----
G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; B='\033[0;34m'; N='\033[0m'

log()    { echo -e "${G}[$(date +'%F %T')]${N} $1" | tee -a "$LOG_FILE"; }
warn()   { echo -e "${Y}[$(date +'%F %T')] WARN:${N} $1" | tee -a "$LOG_FILE"; }
error()  { echo -e "${R}[$(date +'%F %T')] ERROR:${N} $1" | tee -a "$LOG_FILE"; }

################################################################################
# Argument parser
################################################################################
while [[ $# -gt 0 ]]; do
    case "$1" in
        --backup-dir) BACKUP_DIR="$2"; shift 2 ;;
        --target-dir) TARGET_DIR="$2"; shift 2 ;;
        --backup-file) BACKUP_FILE_ARG="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: $0 [--backup-dir DIR] [--target-dir DIR] [--backup-file FILE]"
            exit 0 ;;
        *) echo "Unknown option $1"; exit 1 ;;
    esac
done

BACKUP_DIR="${BACKUP_DIR:-$DEFAULT_BACKUP_DIR}"
TARGET_DIR="${TARGET_DIR:-$DEFAULT_TARGET_DIR}"

mkdir -p "$BACKUP_DIR"
LOG_FILE="${BACKUP_DIR}/restore_$(date +%Y%m%d_%H%M%S).log"

################################################################################
# Select backup file
################################################################################
select_backup() {
    if [[ -n "$BACKUP_FILE_ARG" ]]; then
        echo "$BACKUP_FILE_ARG"
        return
    fi

    echo -e "${B}Backups disponibles:${N}"
    BACKUPS=($(ls -t "${BACKUP_DIR}"/mediastock_backup_*.tar.gz 2>/dev/null))

    if [[ ${#BACKUPS[@]} -eq 0 ]]; then
        error "Aucun backup trouvé"
        exit 1
    fi

    for i in "${!BACKUPS[@]}"; do
        echo "[$((i+1))] $(basename "${BACKUPS[$i]}")"
    done

    read -p "Choisir un backup: " CHOICE
    echo "${BACKUPS[$((CHOICE-1))]}"
}

################################################################################
# Checksum verification
################################################################################
verify_checksum() {
    local file="$1"

    if [[ ! -f "${file}.sha256" ]]; then
        warn "Pas de fichier checksum — ignoré."
        return 0
    fi

    if sha256sum -c "${file}.sha256"; then
        log "Checksum OK"
    else
        error "Checksum invalide"
        exit 1
    fi
}

################################################################################
# Extract backup
################################################################################
extract_backup() {
    local file="$1"
    local tmp="${BACKUP_DIR}/restore_tmp_$(date +%s)"

    mkdir -p "$tmp"
    tar xzf "$file" -C "$tmp"

    RESTORE_PATH=$(find "$tmp" -maxdepth 1 -type d -name "mediastock_backup_*" | head -n1)
    echo "$RESTORE_PATH"
}

################################################################################
# Stop docker
################################################################################
stop_docker() {
    log "Arrêt des services Docker..."
    cd "$TARGET_DIR"

    if docker compose ps -q >/dev/null 2>&1; then
        docker compose down || warn "Impossible d'arrêter proprement"
    fi
}

################################################################################
# Restore MySQL dump
################################################################################
restore_mysql_dump() {
    local path="$1"

    if [[ ! -f "${path}/db/mysql_all.sql.gz" ]]; then
        warn "Aucun dump MySQL trouvé"
        return
    fi

    log "Restauration dump MySQL..."

    docker compose up -d mysql
    sleep 10

    DB_USER=$(docker exec mysql printenv MYSQL_USER)
    DB_PASS=$(docker exec mysql printenv MYSQL_PASSWORD)

    gunzip -c "${path}/db/mysql_all.sql.gz" \
        | docker exec -i mysql mysql -u"$DB_USER" -p"$DB_PASS"

    log "Dump MySQL restauré"
}

################################################################################
# Restore MySQL volume
################################################################################
restore_mysql_volume() {
    local path="$1"

    if [[ ! -f "${path}/volumes/mysql-data.tar.gz" ]]; then
        warn "Pas de volume MySQL"
        return
    fi

    log "Restauration du volume MySQL..."

    docker volume rm mediastock_mysql-data 2>/dev/null || true
    docker volume create mediastock_mysql-data >/dev/null

    docker run --rm \
        -v mediastock_mysql-data:/data \
        -v "${path}/volumes:/backup" \
        alpine \
        sh -c "rm -rf /data/* && tar xzf /backup/mysql-data.tar.gz -C /data"

    log "Volume MySQL restauré"
}

################################################################################
# Restore source code
################################################################################
restore_code() {
    local path="$1"
    log "Restauration du code source..."

    rm -rf "${TARGET_DIR:?}/app"
    cp -r "${path}/app" "${TARGET_DIR}/"

    log "Code restauré"
}

################################################################################
# Restore config
################################################################################
restore_config() {
    local path="$1"

    if [[ ! -d "${path}/config" ]]; then
        warn "Pas de config trouvée"
        return
    fi

    log "Restauration configuration..."
    cp -f "${path}/config/"* "${TARGET_DIR}/"

    log "Fichiers config restaurés"
}

################################################################################
# Restart services
################################################################################
restart_services() {
    log "Redémarrage Docker..."
    cd "$TARGET_DIR"
    docker compose up -d
    sleep 10
    docker compose ps
}

################################################################################
# Main process
################################################################################
main() {
    log "===== DÉBUT RESTORE MediaStock ====="

    BACKUP_FILE=$(select_backup)
    verify_checksum "$BACKUP_FILE"

    RESTORE_DIR=$(extract_backup "$BACKUP_FILE")

    stop_docker
    restore_config "$RESTORE_DIR"
    restore_code "$RESTORE_DIR"
    restore_mysql_volume "$RESTORE_DIR"
    restore_mysql_dump "$RESTORE_DIR"
    restart_services

    log "===== RESTAURATION TERMINÉE 🎉 ====="
}

main
