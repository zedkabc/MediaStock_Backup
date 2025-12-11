#!/bin/bash

################################################################################
# Backup pour MediaStock (Docker Compose + MySQL)
################################################################################

set -euo pipefail

# ---- CONFIGURATION ----
BACKUP_ROOT="/opt/mediastock_backups"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
BACKUP_NAME="mediastock_backup_${TIMESTAMP}"
BACKUP_PATH="${BACKUP_ROOT}/${BACKUP_NAME}"
LOG_FILE="${BACKUP_ROOT}/backup_${TIMESTAMP}.log"
RETENTION_DAYS=7

# Crée si nécessaire
mkdir -p "${BACKUP_ROOT}"
mkdir -p "${BACKUP_PATH}"

# Couleurs pour logs
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'

log()    { echo -e "${GREEN}[$(date +'%F %T')]${NC} $1" | tee -a "${LOG_FILE}"; }
warn()   { echo -e "${YELLOW}[$(date +'%F %T')] WARN:${NC} $1" | tee -a "${LOG_FILE}"; }
error()  { echo -e "${RED}[$(date +'%F %T')] ERROR:${NC} $1" | tee -a "${LOG_FILE}"; }

cleanup_on_error() {
    error "Erreur détectée — nettoyage du dossier temporaire"
    rm -rf "${BACKUP_PATH}"
    exit 1
}
trap cleanup_on_error ERR

################################################################################
check_prerequisites() {
    log "Vérification de Docker..."
    if ! docker info >/dev/null 2>&1; then
        error "Docker ne tourne pas"; exit 1
    fi
    log "Prérequis OK"
}

################################################################################
backup_mysql() {
    log "🔹 Backup de MySQL"

    mkdir -p "${BACKUP_PATH}/db"

    DB_USER=$(docker exec mysql printenv MYSQL_USER || echo "")
    DB_PASS=$(docker exec mysql printenv MYSQL_PASSWORD || echo "")

    if docker exec mysql mysqldump -u"${DB_USER}" -p"${DB_PASS}" --all-databases \
         | gzip > "${BACKUP_PATH}/db/mysql_all.sql.gz"
    then
        log "✔ Dump MySQL créé"
    else
        warn "⚠ Echec du dump MySQL"
    fi
}

################################################################################
backup_volumes() {
    log "🔹 Backup des volumes MySQL"
    mkdir -p "${BACKUP_PATH}/volumes"
    docker run --rm -v mediastock_mysql-data:/data \
        -v "${BACKUP_PATH}/volumes:/backup" \
        alpine \
        tar czf /backup/mysql-data.tar.gz -C /data .
    log "✔ Volume MySQL sauvegardé"
}

################################################################################
backup_app_code() {
    log "🔹 Backup du code source"
    cp -r . "${BACKUP_PATH}/app"
    log "✔ Code source copié"
}

################################################################################
backup_docker_config() {
    log "🔹 Backup des fichiers de configuration"
    mkdir -p "${BACKUP_PATH}/config"
    cp .env docker-compose.yml docker-compose.production.yml "${BACKUP_PATH}/config/" \
      || warn "Certains fichiers config manquent"
}

################################################################################
create_archive() {
    log "📦 Création de l'archive finale"
    cd "${BACKUP_ROOT}"
    tar czf "${BACKUP_NAME}.tar.gz" "${BACKUP_NAME}"

    rm -rf "${BACKUP_NAME}"

    SHA=$(sha256sum "${BACKUP_NAME}.tar.gz" | cut -d' ' -f1)
    echo "${SHA}  ${BACKUP_NAME}.tar.gz" > "${BACKUP_NAME}.sha256"
    log "✔ Archive + checksum OK"
}

################################################################################
cleanup_old_backups() {
    log "🧹 Suppression des backups > ${RETENTION_DAYS} jours"
    find "${BACKUP_ROOT}" -name "mediastock_backup_*.tar.gz" -mtime +${RETENTION_DAYS} -delete
    find "${BACKUP_ROOT}" -name "*.sha256" -mtime +${RETENTION_DAYS} -delete
    find "${BACKUP_ROOT}" -name "backup_*.log" -mtime +${RETENTION_DAYS} -delete
    log "✔ Anciennes sauvegardes effacées"
}

################################################################################
main() {
    log "===== Début backup MediaStock ====="
    check_prerequisites
    backup_mysql
    backup_volumes
    backup_app_code
    backup_docker_config
    create_archive
    cleanup_old_backups
    log "===== Backup terminé 🎉 ====="
    log "Archive : ${BACKUP_ROOT}/${BACKUP_NAME}.tar.gz"
}

main
