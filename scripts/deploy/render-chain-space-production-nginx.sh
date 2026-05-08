#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd -P)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/chain-space-deploy-common.sh"

trap 'cs_on_error "$?" "${LINENO}"' ERR

PROJECT_NAME="${PROJECT_NAME:-chain-space}"
SERVER_NAME="${SERVER_NAME:-api.example.com}"
BACKEND_ROOT="${BACKEND_ROOT:-/var/www/chain-space/current/backend}"
PHP_FPM_SOCKET="${PHP_FPM_SOCKET:-/run/php/php8.2-fpm.sock}"
CLIENT_MAX_BODY_SIZE="${CLIENT_MAX_BODY_SIZE:-64m}"
ACCESS_LOG="${ACCESS_LOG:-/var/log/nginx/${PROJECT_NAME}.access.log}"
ERROR_LOG="${ERROR_LOG:-/var/log/nginx/${PROJECT_NAME}.error.log}"
ACME_WEBROOT="${ACME_WEBROOT:-/var/www/chain-space/acme}"
SSL_FULLCHAIN_PATH="${SSL_FULLCHAIN_PATH:-/etc/ssl/chain-space/fullchain.cer}"
SSL_KEY_PATH="${SSL_KEY_PATH:-/etc/ssl/chain-space/${SERVER_NAME}.key}"
NGINX_MODE="${NGINX_MODE:-http}"
HTTP_TEMPLATE_FILE="${HTTP_TEMPLATE_FILE:-${SCRIPT_DIR}/templates/chain-space-production-http.conf.example}"
HTTPS_TEMPLATE_FILE="${HTTPS_TEMPLATE_FILE:-${SCRIPT_DIR}/templates/chain-space-production-https.conf.example}"
OUTPUT_FILE="${OUTPUT_FILE:-/etc/nginx/sites-available/${PROJECT_NAME}.conf}"
ENABLE_SITE="${ENABLE_SITE:-true}"
TEST_NGINX="${TEST_NGINX:-true}"
RESTART_NGINX="${RESTART_NGINX:-true}"

select_template() {
  case "${NGINX_MODE}" in
    http)
      printf '%s\n' "${HTTP_TEMPLATE_FILE}"
      ;;
    https)
      printf '%s\n' "${HTTPS_TEMPLATE_FILE}"
      ;;
    *)
      cs_die "不支持的 NGINX_MODE: ${NGINX_MODE}，可选值: http / https"
      ;;
  esac
}

main() {
  local template_file=""

  cs_require_root
  cs_require_command python3

  template_file="$(select_template)"
  cs_require_file "${template_file}" "Nginx 模板文件"

  mkdir -p "${ACME_WEBROOT}" "$(dirname "${OUTPUT_FILE}")"

  if [[ "${NGINX_MODE}" == "https" ]]; then
    [[ -f "${SSL_FULLCHAIN_PATH}" ]] || cs_die "缺少证书文件: ${SSL_FULLCHAIN_PATH}"
    [[ -f "${SSL_KEY_PATH}" ]] || cs_die "缺少证书私钥文件: ${SSL_KEY_PATH}"
  fi

  cs_log "INFO" "渲染生产 Nginx 配置: mode=${NGINX_MODE}"
  cs_render_file_with_vars \
    "${template_file}" \
    "${OUTPUT_FILE}" \
    "server_name=${SERVER_NAME}" \
    "backend_root=${BACKEND_ROOT}" \
    "php_fpm_socket=${PHP_FPM_SOCKET}" \
    "client_max_body_size=${CLIENT_MAX_BODY_SIZE}" \
    "access_log=${ACCESS_LOG}" \
    "error_log=${ERROR_LOG}" \
    "acme_webroot=${ACME_WEBROOT}" \
    "ssl_fullchain_path=${SSL_FULLCHAIN_PATH}" \
    "ssl_key_path=${SSL_KEY_PATH}"

  if cs_bool_is_true "${ENABLE_SITE}"; then
    ln -sfn "${OUTPUT_FILE}" "/etc/nginx/sites-enabled/${PROJECT_NAME}.conf"
  fi

  if cs_bool_is_true "${TEST_NGINX}"; then
    nginx -t
  fi

  if cs_bool_is_true "${RESTART_NGINX}"; then
    systemctl restart nginx
  fi

  cat <<EOF

================ 生产 Nginx 配置完成 ================
模式: ${NGINX_MODE}
模板文件: ${template_file}
输出文件: ${OUTPUT_FILE}
站点域名: ${SERVER_NAME}
后端目录: ${BACKEND_ROOT}
ACME Webroot: ${ACME_WEBROOT}
证书文件: ${SSL_FULLCHAIN_PATH}
私钥文件: ${SSL_KEY_PATH}
=====================================================

EOF
}

main "$@"
