#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd -P)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/chain-space-deploy-common.sh"

trap 'cs_on_error "$?" "${LINENO}"' ERR

CONFIG_FILE="${1:-${SCRIPT_DIR}/config/production-server.env}"
INSTALL_SCRIPT="${SCRIPT_DIR}/install-chain-space-server.sh"
RENDER_NGINX_SCRIPT="${SCRIPT_DIR}/render-chain-space-production-nginx.sh"
RENDER_SUPERVISOR_SCRIPT="${SCRIPT_DIR}/render-chain-space-production-supervisor.sh"
ISSUE_CERT_SCRIPT="${SCRIPT_DIR}/issue-chain-space-production-cert.sh"
CHECK_SCRIPT="${SCRIPT_DIR}/check-chain-space-production.sh"
ENV_LABEL="${ENV_LABEL:-生产环境}"
COMMAND_HINT="${COMMAND_HINT:-bash scripts/production.sh}"
DEPLOY_CONFIG_HINT="${DEPLOY_CONFIG_HINT:-scripts/deploy/config/deploy-release.production.env}"

load_config() {
  cs_source_config "${CONFIG_FILE}" "生产服务器配置"

  APP_NAME="${APP_NAME:-chain-space}"
  PROJECT_ROOT="${PROJECT_ROOT:-/var/www/chain-space}"
  APP_USER="${APP_USER:-www-data}"
  APP_GROUP="${APP_GROUP:-www-data}"
  SERVER_NAME="${SERVER_NAME:-api.example.com}"
  PHP_VERSION="${PHP_VERSION:-8.2}"
  PHP_FPM_SOCKET="${PHP_FPM_SOCKET:-/run/php/php${PHP_VERSION}-fpm.sock}"
  NODE_MAJOR="${NODE_MAJOR:-20}"
  PNPM_VERSION="${PNPM_VERSION:-10.33.0}"
  INSTALL_MYSQL="${INSTALL_MYSQL:-true}"
  INSTALL_RABBITMQ="${INSTALL_RABBITMQ:-true}"
  INSTALL_ELASTICSEARCH="${INSTALL_ELASTICSEARCH:-true}"
  INSTALL_ES_IK="${INSTALL_ES_IK:-true}"
  ENABLE_RABBITMQ_MANAGEMENT="${ENABLE_RABBITMQ_MANAGEMENT:-true}"
  ENABLE_SWAP="${ENABLE_SWAP:-true}"
  SWAP_SIZE_MB="${SWAP_SIZE_MB:-2048}"
  MYSQL_APP_DATABASE="${MYSQL_APP_DATABASE:-chain_space}"
  MYSQL_APP_USER="${MYSQL_APP_USER:-chain_space}"
  MYSQL_APP_PASSWORD="${MYSQL_APP_PASSWORD:-change_me}"
  MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD:-}"
  RABBITMQ_APP_VHOST="${RABBITMQ_APP_VHOST:-/chain-space}"
  RABBITMQ_APP_USER="${RABBITMQ_APP_USER:-chain-space}"
  RABBITMQ_APP_PASSWORD="${RABBITMQ_APP_PASSWORD:-change_me}"
  QUEUE_MODE="${QUEUE_MODE:-rabbitmq-workers}"
  DEFAULT_QUEUE_NAME="${DEFAULT_QUEUE_NAME:-chain-space.default}"
  VIDEO_QUEUE_NAME="${VIDEO_QUEUE_NAME:-video-processing}"
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
  SHARED_BACKEND_ENV="${SHARED_BACKEND_ENV:-${PROJECT_ROOT}/shared/.env}"
  BACKEND_ENV_TEMPLATE="${BACKEND_ENV_TEMPLATE:-${REPO_ROOT}/backend/.env.production.example}"
  COPY_BACKEND_ENV_TEMPLATE="${COPY_BACKEND_ENV_TEMPLATE:-true}"
  FORCE_COPY_ENV_TEMPLATE="${FORCE_COPY_ENV_TEMPLATE:-false}"
}

validate_inputs() {
  cs_require_root
  cs_require_file "${INSTALL_SCRIPT}" "安装脚本"
  cs_require_file "${RENDER_NGINX_SCRIPT}" "生产 Nginx 渲染脚本"
  cs_require_file "${RENDER_SUPERVISOR_SCRIPT}" "生产 Supervisor 渲染脚本"
  cs_require_file "${ISSUE_CERT_SCRIPT}" "生产 HTTPS 证书脚本"
  cs_require_file "${CHECK_SCRIPT}" "生产预检脚本"

  if cs_bool_is_true "${COPY_BACKEND_ENV_TEMPLATE}"; then
    [[ -f "${BACKEND_ENV_TEMPLATE}" ]] || cs_die "后端环境模板不存在: ${BACKEND_ENV_TEMPLATE}"
  fi
}

copy_template_if_needed() {
  local source_file="$1"
  local target_file="$2"
  local enabled="$3"

  if ! cs_bool_is_true "${enabled}"; then
    return
  fi

  mkdir -p "$(dirname "${target_file}")"

  if [[ -f "${target_file}" ]] && ! cs_bool_is_true "${FORCE_COPY_ENV_TEMPLATE}"; then
    cs_log "INFO" "环境文件已存在，跳过覆盖: ${target_file}"
    return
  fi

  cp "${source_file}" "${target_file}"
  chown "${APP_USER}:${APP_GROUP}" "${target_file}"
  chmod 0640 "${target_file}"
  cs_log "INFO" "已写入环境模板: ${target_file}"
}

install_server_stack() {
  APP_NAME="${APP_NAME}" \
  PROJECT_ROOT="${PROJECT_ROOT}" \
  APP_USER="${APP_USER}" \
  APP_GROUP="${APP_GROUP}" \
  PHP_VERSION="${PHP_VERSION}" \
  NODE_MAJOR="${NODE_MAJOR}" \
  PNPM_VERSION="${PNPM_VERSION}" \
  INSTALL_MYSQL="${INSTALL_MYSQL}" \
  INSTALL_RABBITMQ="${INSTALL_RABBITMQ}" \
  INSTALL_ELASTICSEARCH="${INSTALL_ELASTICSEARCH}" \
  INSTALL_ES_IK="${INSTALL_ES_IK}" \
  ENABLE_RABBITMQ_MANAGEMENT="${ENABLE_RABBITMQ_MANAGEMENT}" \
  ENABLE_SWAP="${ENABLE_SWAP}" \
  SWAP_SIZE_MB="${SWAP_SIZE_MB}" \
  MYSQL_APP_DATABASE="${MYSQL_APP_DATABASE}" \
  MYSQL_APP_USER="${MYSQL_APP_USER}" \
  MYSQL_APP_PASSWORD="${MYSQL_APP_PASSWORD}" \
  MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD}" \
  RABBITMQ_APP_VHOST="${RABBITMQ_APP_VHOST}" \
  RABBITMQ_APP_USER="${RABBITMQ_APP_USER}" \
  RABBITMQ_APP_PASSWORD="${RABBITMQ_APP_PASSWORD}" \
  bash "${INSTALL_SCRIPT}"
}

run_precheck() {
  SERVER_CONFIG_FILE="${CONFIG_FILE}" \
  CHECK_MODE=setup \
  bash "${CHECK_SCRIPT}"
}

prepare_shared_env_template() {
  copy_template_if_needed "${BACKEND_ENV_TEMPLATE}" "${SHARED_BACKEND_ENV}" "${COPY_BACKEND_ENV_TEMPLATE}"
}

render_http_nginx() {
  PROJECT_NAME="${NGINX_PROJECT_NAME}" \
  SERVER_NAME="${SERVER_NAME}" \
  BACKEND_ROOT="${PROJECT_ROOT}/current/backend" \
  PHP_FPM_SOCKET="${PHP_FPM_SOCKET}" \
  ACCESS_LOG="${NGINX_ACCESS_LOG}" \
  ERROR_LOG="${NGINX_ERROR_LOG}" \
  ACME_WEBROOT="${ACME_WEBROOT}" \
  SSL_FULLCHAIN_PATH="${SSL_FULLCHAIN_PATH}" \
  SSL_KEY_PATH="${SSL_KEY_PATH}" \
  NGINX_MODE=http \
  bash "${RENDER_NGINX_SCRIPT}"
}

issue_https_cert() {
  if ! cs_bool_is_true "${ENABLE_HTTPS}"; then
    cs_log "INFO" "已禁用 HTTPS 证书签发"
    return
  fi

  SERVER_NAME="${SERVER_NAME}" \
  ACME_EMAIL="${ACME_EMAIL}" \
  ACME_WEBROOT="${ACME_WEBROOT}" \
  ACME_INSTALL_DIR="${ACME_INSTALL_DIR}" \
  SSL_CERT_DIR="${SSL_CERT_DIR}" \
  SSL_FULLCHAIN_PATH="${SSL_FULLCHAIN_PATH}" \
  SSL_KEY_PATH="${SSL_KEY_PATH}" \
  FORCE_REISSUE_CERT="${FORCE_REISSUE_CERT}" \
  bash "${ISSUE_CERT_SCRIPT}"
}

render_https_nginx() {
  if ! cs_bool_is_true "${ENABLE_HTTPS}"; then
    return
  fi

  PROJECT_NAME="${NGINX_PROJECT_NAME}" \
  SERVER_NAME="${SERVER_NAME}" \
  BACKEND_ROOT="${PROJECT_ROOT}/current/backend" \
  PHP_FPM_SOCKET="${PHP_FPM_SOCKET}" \
  ACCESS_LOG="${NGINX_ACCESS_LOG}" \
  ERROR_LOG="${NGINX_ERROR_LOG}" \
  ACME_WEBROOT="${ACME_WEBROOT}" \
  SSL_FULLCHAIN_PATH="${SSL_FULLCHAIN_PATH}" \
  SSL_KEY_PATH="${SSL_KEY_PATH}" \
  NGINX_MODE=https \
  bash "${RENDER_NGINX_SCRIPT}"
}

render_supervisor_config() {
  local restart_supervisor="true"

  if [[ ! -f "${PROJECT_ROOT}/current/backend/artisan" ]]; then
    restart_supervisor="false"
    cs_log "WARN" "当前尚未发布代码，仅生成 Supervisor 配置，暂不执行 reread/update"
  fi

  QUEUE_MODE="${QUEUE_MODE}" \
  PROJECT_NAME="${NGINX_PROJECT_NAME}" \
  APP_USER="${APP_USER}" \
  APP_ENV="${SUPERVISOR_APP_ENV}" \
  APP_ROOT="${PROJECT_ROOT}/current/backend" \
  PHP_BIN="/usr/bin/php" \
  DEFAULT_QUEUE_NAME="${DEFAULT_QUEUE_NAME}" \
  VIDEO_QUEUE_NAME="${VIDEO_QUEUE_NAME}" \
  RESTART_SUPERVISOR="${restart_supervisor}" \
  bash "${RENDER_SUPERVISOR_SCRIPT}"
}

print_summary() {
  cat <<EOF

================ ${ENV_LABEL}初始化完成 ================
配置文件: ${CONFIG_FILE}
部署目录: ${PROJECT_ROOT}
Nginx 域名: ${SERVER_NAME}
HTTPS: ${ENABLE_HTTPS}
队列模式: ${QUEUE_MODE}
后端环境文件: ${SHARED_BACKEND_ENV}
证书文件: ${SSL_FULLCHAIN_PATH}
私钥文件: ${SSL_KEY_PATH}

下一步:
1. 编辑 ${SHARED_BACKEND_ENV}，填写 APP_KEY、数据库、OSS、微信、支付等真实参数
2. 编辑 ${DEPLOY_CONFIG_HINT}，确认源码目录、健康检查地址、后台检测地址
3. 执行 ${COMMAND_HINT} check deploy
4. 执行 ${COMMAND_HINT} deploy 完成首发
5. 首发后执行 ${COMMAND_HINT} check all 做全量复核
========================================================

EOF
}

main() {
  load_config
  validate_inputs
  cs_log "INFO" "开始初始化${ENV_LABEL}"
  run_precheck
  install_server_stack
  render_http_nginx
  issue_https_cert
  render_https_nginx
  render_supervisor_config
  prepare_shared_env_template
  print_summary
}

main "$@"
