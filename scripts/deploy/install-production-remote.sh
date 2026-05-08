#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

REPO_RAW_BASE_URL="${REPO_RAW_BASE_URL:-https://gitee.com/hyt_2/chain-space/raw/master}"
TMP_ROOT="${TMP_ROOT:-/tmp/chain-space-production-installer}"
SERVER_NAME="${SERVER_NAME:-api.example.com}"
PROJECT_ROOT="${PROJECT_ROOT:-/var/www/chain-space}"
APP_NAME="${APP_NAME:-chain-space}"
APP_USER="${APP_USER:-www-data}"
APP_GROUP="${APP_GROUP:-www-data}"
PHP_VERSION="${PHP_VERSION:-8.2}"
NODE_MAJOR="${NODE_MAJOR:-20}"
PNPM_VERSION="${PNPM_VERSION:-10.33.0}"
INSTALL_MYSQL="${INSTALL_MYSQL:-true}"
INSTALL_RABBITMQ="${INSTALL_RABBITMQ:-true}"
INSTALL_ELASTICSEARCH="${INSTALL_ELASTICSEARCH:-true}"
INSTALL_ES_IK="${INSTALL_ES_IK:-true}"
ENABLE_RABBITMQ_MANAGEMENT="${ENABLE_RABBITMQ_MANAGEMENT:-true}"
ENABLE_SWAP="${ENABLE_SWAP:-true}"
SWAP_SIZE_MB="${SWAP_SIZE_MB:-2048}"
QUEUE_MODE="${QUEUE_MODE:-rabbitmq-workers}"
DEFAULT_QUEUE_NAME="${DEFAULT_QUEUE_NAME:-chain-space.default}"
VIDEO_QUEUE_NAME="${VIDEO_QUEUE_NAME:-video-processing}"
MYSQL_APP_DATABASE="${MYSQL_APP_DATABASE:-chain_space}"
MYSQL_APP_USER="${MYSQL_APP_USER:-chain_space}"
MYSQL_APP_PASSWORD="${MYSQL_APP_PASSWORD:-}"
MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD:-}"
RABBITMQ_APP_VHOST="${RABBITMQ_APP_VHOST:-/chain-space}"
RABBITMQ_APP_USER="${RABBITMQ_APP_USER:-chain-space}"
RABBITMQ_APP_PASSWORD="${RABBITMQ_APP_PASSWORD:-}"
NGINX_PROJECT_NAME="${NGINX_PROJECT_NAME:-chain-space}"
NGINX_ACCESS_LOG="${NGINX_ACCESS_LOG:-/var/log/nginx/chain-space.access.log}"
NGINX_ERROR_LOG="${NGINX_ERROR_LOG:-/var/log/nginx/chain-space.error.log}"
ACME_EMAIL="${ACME_EMAIL:-ops@example.com}"
ACME_WEBROOT="${ACME_WEBROOT:-${PROJECT_ROOT}/acme}"
ACME_INSTALL_DIR="${ACME_INSTALL_DIR:-/root/.acme.sh}"
SSL_CERT_DIR="${SSL_CERT_DIR:-/etc/ssl/chain-space}"
SSL_FULLCHAIN_PATH="${SSL_FULLCHAIN_PATH:-${SSL_CERT_DIR}/fullchain.cer}"
SSL_KEY_PATH="${SSL_KEY_PATH:-${SSL_CERT_DIR}/${SERVER_NAME}.key}"
ENABLE_HTTPS="${ENABLE_HTTPS:-true}"
FORCE_REISSUE_CERT="${FORCE_REISSUE_CERT:-false}"
SUPERVISOR_APP_ENV="${SUPERVISOR_APP_ENV:-production}"
FORCE_COPY_ENV_TEMPLATE="${FORCE_COPY_ENV_TEMPLATE:-false}"

REMOTE_SCRIPT_DIR=""
REMOTE_REPO_ROOT=""
FETCH_BIN=""

usage() {
  cat <<'EOF'
远程生产环境安装器

用法:
  wget -qO- <raw-script-url> | sudo bash
  curl -fsSL <raw-script-url> | sudo bash
  wget -qO- <raw-script-url> | sudo bash -s -- --server-name api.example.com

可选参数:
  --server-name <domain>
  --project-root <path>
  --mysql-password <password>
  --mysql-root-password <password>
  --rabbitmq-password <password>
  --app-user <user>
  --app-group <group>
  --php-version <version>
  --node-major <major>
  --acme-email <email>
  --raw-base-url <url>
  --disable-mysql
  --disable-rabbitmq
  --disable-elasticsearch
  --disable-swap
  --disable-https
  --force-copy-env-template
  --help
EOF
}

log() {
  printf '[production-remote-installer] %s\n' "$*"
}

die() {
  log "ERROR: $*"
  exit 1
}

random_string() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 48 | tr -d '\n' | tr '/+' 'ab' | cut -c1-24
    return
  fi

  python3 - <<'PY'
import secrets
print(secrets.token_urlsafe(18)[:24])
PY
}

require_root() {
  [[ "$(id -u)" -eq 0 ]] || die "请使用 sudo/root 执行该脚本"
}

choose_fetch_bin() {
  if command -v curl >/dev/null 2>&1; then
    FETCH_BIN="curl"
    return
  fi

  if command -v wget >/dev/null 2>&1; then
    FETCH_BIN="wget"
    return
  fi

  die "缺少 curl 或 wget，无法继续拉取部署脚本"
}

fetch_to_file() {
  local relative_path="$1"
  local target_file="$2"
  local source_url="${REPO_RAW_BASE_URL%/}/${relative_path}"

  mkdir -p "$(dirname "${target_file}")"
  log "下载 ${relative_path}"

  if [[ "${FETCH_BIN}" == "curl" ]]; then
    curl -fsSL "${source_url}" -o "${target_file}"
  else
    wget -qO "${target_file}" "${source_url}"
  fi
}

prepare_remote_workspace() {
  REMOTE_SCRIPT_DIR="${TMP_ROOT}/scripts/deploy"
  REMOTE_REPO_ROOT="${TMP_ROOT}"

  rm -rf "${TMP_ROOT}"
  mkdir -p "${REMOTE_SCRIPT_DIR}"

  fetch_to_file "scripts/deploy/lib/chain-space-deploy-common.sh" "${REMOTE_SCRIPT_DIR}/lib/chain-space-deploy-common.sh"
  fetch_to_file "scripts/deploy/install-chain-space-server.sh" "${REMOTE_SCRIPT_DIR}/install-chain-space-server.sh"
  fetch_to_file "scripts/deploy/render-chain-space-supervisor.sh" "${REMOTE_SCRIPT_DIR}/render-chain-space-supervisor.sh"
  fetch_to_file "scripts/deploy/render-chain-space-production-nginx.sh" "${REMOTE_SCRIPT_DIR}/render-chain-space-production-nginx.sh"
  fetch_to_file "scripts/deploy/render-chain-space-production-supervisor.sh" "${REMOTE_SCRIPT_DIR}/render-chain-space-production-supervisor.sh"
  fetch_to_file "scripts/deploy/issue-chain-space-production-cert.sh" "${REMOTE_SCRIPT_DIR}/issue-chain-space-production-cert.sh"
  fetch_to_file "scripts/deploy/check-chain-space-production.sh" "${REMOTE_SCRIPT_DIR}/check-chain-space-production.sh"
  fetch_to_file "scripts/deploy/setup-chain-space-production.sh" "${REMOTE_SCRIPT_DIR}/setup-chain-space-production.sh"
  fetch_to_file "scripts/deploy/config/deploy-release.production.env.example" "${REMOTE_SCRIPT_DIR}/config/deploy-release.production.env.example"
  fetch_to_file "scripts/deploy/templates/chain-space-production-http.conf.example" "${REMOTE_SCRIPT_DIR}/templates/chain-space-production-http.conf.example"
  fetch_to_file "scripts/deploy/templates/chain-space-production-https.conf.example" "${REMOTE_SCRIPT_DIR}/templates/chain-space-production-https.conf.example"

  fetch_to_file "backend/.env.production.example" "${REMOTE_REPO_ROOT}/backend/.env.production.example"
  fetch_to_file "backend/deploy/supervisor/default-worker.conf.example" "${REMOTE_REPO_ROOT}/backend/deploy/supervisor/default-worker.conf.example"
  fetch_to_file "backend/deploy/supervisor/video-processing.conf.example" "${REMOTE_REPO_ROOT}/backend/deploy/supervisor/video-processing.conf.example"
  fetch_to_file "backend/deploy/supervisor/horizon.conf.example" "${REMOTE_REPO_ROOT}/backend/deploy/supervisor/horizon.conf.example"
  fetch_to_file "backend/deploy/supervisor/scheduler.conf.example" "${REMOTE_REPO_ROOT}/backend/deploy/supervisor/scheduler.conf.example"

  chmod +x \
    "${REMOTE_SCRIPT_DIR}/install-chain-space-server.sh" \
    "${REMOTE_SCRIPT_DIR}/render-chain-space-supervisor.sh" \
    "${REMOTE_SCRIPT_DIR}/render-chain-space-production-nginx.sh" \
    "${REMOTE_SCRIPT_DIR}/render-chain-space-production-supervisor.sh" \
    "${REMOTE_SCRIPT_DIR}/issue-chain-space-production-cert.sh" \
    "${REMOTE_SCRIPT_DIR}/check-chain-space-production.sh" \
    "${REMOTE_SCRIPT_DIR}/setup-chain-space-production.sh"
}

write_server_config() {
  local config_file="${REMOTE_SCRIPT_DIR}/config/production-server.env"

  mkdir -p "$(dirname "${config_file}")"

  cat >"${config_file}" <<EOF
APP_NAME=${APP_NAME}
REPO_ROOT=${REMOTE_REPO_ROOT}
PROJECT_ROOT=${PROJECT_ROOT}
APP_USER=${APP_USER}
APP_GROUP=${APP_GROUP}

SERVER_NAME=${SERVER_NAME}
ACME_EMAIL=${ACME_EMAIL}
PHP_VERSION=${PHP_VERSION}
PHP_FPM_SOCKET=/run/php/php${PHP_VERSION}-fpm.sock
NODE_MAJOR=${NODE_MAJOR}
PNPM_VERSION=${PNPM_VERSION}

INSTALL_MYSQL=${INSTALL_MYSQL}
INSTALL_RABBITMQ=${INSTALL_RABBITMQ}
INSTALL_ELASTICSEARCH=${INSTALL_ELASTICSEARCH}
INSTALL_ES_IK=${INSTALL_ES_IK}
ENABLE_RABBITMQ_MANAGEMENT=${ENABLE_RABBITMQ_MANAGEMENT}
ENABLE_SWAP=${ENABLE_SWAP}
SWAP_SIZE_MB=${SWAP_SIZE_MB}

MYSQL_APP_DATABASE=${MYSQL_APP_DATABASE}
MYSQL_APP_USER=${MYSQL_APP_USER}
MYSQL_APP_PASSWORD=${MYSQL_APP_PASSWORD}
MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD}

RABBITMQ_APP_VHOST=${RABBITMQ_APP_VHOST}
RABBITMQ_APP_USER=${RABBITMQ_APP_USER}
RABBITMQ_APP_PASSWORD=${RABBITMQ_APP_PASSWORD}

QUEUE_MODE=${QUEUE_MODE}
DEFAULT_QUEUE_NAME=${DEFAULT_QUEUE_NAME}
VIDEO_QUEUE_NAME=${VIDEO_QUEUE_NAME}

NGINX_PROJECT_NAME=${NGINX_PROJECT_NAME}
NGINX_ACCESS_LOG=${NGINX_ACCESS_LOG}
NGINX_ERROR_LOG=${NGINX_ERROR_LOG}
ACME_WEBROOT=${ACME_WEBROOT}
ACME_INSTALL_DIR=${ACME_INSTALL_DIR}
SSL_CERT_DIR=${SSL_CERT_DIR}
SSL_FULLCHAIN_PATH=${SSL_FULLCHAIN_PATH}
SSL_KEY_PATH=${SSL_KEY_PATH}
ENABLE_HTTPS=${ENABLE_HTTPS}
FORCE_REISSUE_CERT=${FORCE_REISSUE_CERT}

SUPERVISOR_APP_ENV=${SUPERVISOR_APP_ENV}

SHARED_BACKEND_ENV=${PROJECT_ROOT}/shared/.env
BACKEND_ENV_TEMPLATE=${REMOTE_REPO_ROOT}/backend/.env.production.example

COPY_BACKEND_ENV_TEMPLATE=true
FORCE_COPY_ENV_TEMPLATE=${FORCE_COPY_ENV_TEMPLATE}
EOF
}

write_deploy_config() {
  local config_file="${REMOTE_SCRIPT_DIR}/config/deploy-release.production.env"

  mkdir -p "$(dirname "${config_file}")"

  cat >"${config_file}" <<EOF
PROJECT_NAME=${APP_NAME}
DEPLOY_ROOT=${PROJECT_ROOT}
BACKEND_SOURCE_DIR=/srv/chain-space/backend
FRONTEND_SOURCE_DIR=/srv/chain-space/frontend
APP_USER=${APP_USER}
APP_GROUP=${APP_GROUP}
PHP_BIN=php
COMPOSER_BIN=composer
RELEASES_TO_KEEP=5
RUN_MIGRATIONS=true
MIGRATION_STRATEGY=compatible
ALLOW_DESTRUCTIVE_MIGRATIONS=false
DESTRUCTIVE_MIGRATIONS_CONFIRMATION=
RUN_STORAGE_LINK=true
RUN_FRONTEND_BUILD=false
RUN_HEALTHCHECK=true
HEALTHCHECK_URL=https://${SERVER_NAME}/api/v1/health
RUN_ACCESS_CHECKS=true
ADMIN_ROUTE_PREFIX=admin
ADMIN_SMOKE_URL=https://${SERVER_NAME}/admin/auth/login
ADMIN_SMOKE_EXPECT_STATUSES=200
ADMIN_SMOKE_CONTAINS="Dcat Admin"
ALLOW_DIRTY_WORKTREE=false
QUEUE_MODE=${QUEUE_MODE}
SUPERVISOR_PROGRAMS="${APP_NAME}-default-worker:* ${APP_NAME}-video-processing:*"
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --server-name)
        SERVER_NAME="$2"
        shift 2
        ;;
      --project-root)
        PROJECT_ROOT="$2"
        shift 2
        ;;
      --mysql-password)
        MYSQL_APP_PASSWORD="$2"
        shift 2
        ;;
      --mysql-root-password)
        MYSQL_ROOT_PASSWORD="$2"
        shift 2
        ;;
      --rabbitmq-password)
        RABBITMQ_APP_PASSWORD="$2"
        shift 2
        ;;
      --app-user)
        APP_USER="$2"
        shift 2
        ;;
      --app-group)
        APP_GROUP="$2"
        shift 2
        ;;
      --php-version)
        PHP_VERSION="$2"
        shift 2
        ;;
      --node-major)
        NODE_MAJOR="$2"
        shift 2
        ;;
      --acme-email)
        ACME_EMAIL="$2"
        shift 2
        ;;
      --raw-base-url)
        REPO_RAW_BASE_URL="$2"
        shift 2
        ;;
      --disable-mysql)
        INSTALL_MYSQL=false
        shift
        ;;
      --disable-rabbitmq)
        INSTALL_RABBITMQ=false
        shift
        ;;
      --disable-elasticsearch)
        INSTALL_ELASTICSEARCH=false
        INSTALL_ES_IK=false
        shift
        ;;
      --disable-swap)
        ENABLE_SWAP=false
        shift
        ;;
      --disable-https)
        ENABLE_HTTPS=false
        shift
        ;;
      --force-copy-env-template)
        FORCE_COPY_ENV_TEMPLATE=true
        shift
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        die "不支持的参数: $1"
        ;;
    esac
  done
}

run_setup() {
  local config_file="${REMOTE_SCRIPT_DIR}/config/production-server.env"

  ENV_LABEL="生产环境" \
  COMMAND_HINT="bash scripts/production.sh" \
  DEPLOY_CONFIG_HINT="scripts/deploy/config/deploy-release.production.env" \
  bash "${REMOTE_SCRIPT_DIR}/setup-chain-space-production.sh" "${config_file}"
}

print_next_steps() {
  cat <<EOF

================ 远程生产环境初始化完成 ================
域名: ${SERVER_NAME}
项目目录: ${PROJECT_ROOT}
共享后端环境: ${PROJECT_ROOT}/shared/.env
证书目录: ${SSL_CERT_DIR}

生成的基础设施参数:
MySQL 数据库: ${MYSQL_APP_DATABASE}
MySQL 用户: ${MYSQL_APP_USER}
MySQL 密码: ${MYSQL_APP_PASSWORD}
RabbitMQ vhost: ${RABBITMQ_APP_VHOST}
RabbitMQ 用户: ${RABBITMQ_APP_USER}
RabbitMQ 密码: ${RABBITMQ_APP_PASSWORD}

下一步:
1. 编辑 ${PROJECT_ROOT}/shared/.env，补齐 APP_KEY、OSS、微信、支付等真实参数
2. 准备业务源码到服务器，例如 ${PROJECT_ROOT}/../ 或 /srv/chain-space
3. 在仓库内执行 bash scripts/production.sh check deploy
4. 在仓库内执行 sudo bash scripts/production.sh deploy
======================================================

EOF
}

main() {
  parse_args "$@"
  require_root
  choose_fetch_bin

  if [[ -z "${MYSQL_APP_PASSWORD}" && "${INSTALL_MYSQL}" == "true" ]]; then
    MYSQL_APP_PASSWORD="$(random_string)"
  fi

  if [[ -z "${RABBITMQ_APP_PASSWORD}" && "${INSTALL_RABBITMQ}" == "true" ]]; then
    RABBITMQ_APP_PASSWORD="$(random_string)"
  fi

  prepare_remote_workspace
  write_server_config
  write_deploy_config
  run_setup
  print_next_steps
}

main "$@"
