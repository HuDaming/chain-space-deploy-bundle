#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/chain-space-deploy-common.sh"

trap 'cs_on_error "$?" "${LINENO}"' ERR

SERVER_CONFIG_FILE="${SERVER_CONFIG_FILE:-${SCRIPT_DIR}/config/production-server.env}"
DEPLOY_CONFIG_FILE="${DEPLOY_CONFIG_FILE:-${SCRIPT_DIR}/config/deploy-release.production.env}"
CHECK_MODE="${CHECK_MODE:-all}"
CURRENT_HOST_OS="$(uname -s 2>/dev/null || echo unknown)"
HOST_UBUNTU_VERSION=""
FAILURES=0

declare -a PASS_ITEMS=()
declare -a BLOCKING_ITEMS=()
declare -a WARNING_ITEMS=()

warn() {
  cs_log "WARN" "$*"
  WARNING_ITEMS+=("$*")
}

fail() {
  cs_log "WARN" "$*"
  BLOCKING_ITEMS+=("$*")
  FAILURES=$((FAILURES + 1))
}

pass() {
  cs_log "INFO" "$1"
  PASS_ITEMS+=("$1")
}

check_semver_ge() {
  local label="$1"
  local current="$2"
  local expected="$3"

  if [[ -z "${current}" ]]; then
    fail "${label}版本识别失败"
    return
  fi

  if dpkg --compare-versions "${current}" ge "${expected}"; then
    pass "${label}版本符合要求: ${current} >= ${expected}"
  else
    fail "${label}版本不符合要求: ${current} < ${expected}"
  fi
}

check_major_minor_prefix() {
  local label="$1"
  local current="$2"
  local expected_prefix="$3"

  if [[ -z "${current}" ]]; then
    fail "${label}版本识别失败"
    return
  fi

  if [[ "${current}" == "${expected_prefix}"* ]]; then
    pass "${label}版本符合要求: ${current}"
  else
    fail "${label}版本不符合要求: ${current}，期望前缀 ${expected_prefix}"
  fi
}

check_non_placeholder() {
  local label="$1"
  local value="$2"

  if [[ -z "${value}" ]]; then
    fail "${label}为空"
    return
  fi

  case "${value}" in
    change_me|example.com|api.example.com|ops@example.com|https://api.example.com/api/v1/health|https://api.example.com/admin/auth/login)
      fail "${label}仍是占位值: ${value}"
      ;;
    *)
      pass "${label}已配置"
      ;;
  esac
}

detect_host_ubuntu_version() {
  if [[ "${CURRENT_HOST_OS}" != "Linux" || ! -f /etc/os-release ]]; then
    return
  fi

  # shellcheck disable=SC1091
  source /etc/os-release
  if [[ "${ID:-}" == "ubuntu" ]]; then
    HOST_UBUNTU_VERSION="${VERSION_ID:-}"
  fi
}

load_configs() {
  cs_source_config "${SERVER_CONFIG_FILE}" "生产服务器配置"
  cs_source_config "${DEPLOY_CONFIG_FILE}" "生产发布配置"

  APP_NAME="${APP_NAME:-chain-space}"
  PROJECT_ROOT="${PROJECT_ROOT:-/var/www/chain-space}"
  SERVER_NAME="${SERVER_NAME:-api.example.com}"
  PHP_VERSION="${PHP_VERSION:-8.2}"
  PHP_FPM_SOCKET="${PHP_FPM_SOCKET:-/run/php/php8.2-fpm.sock}"
  MYSQL_APP_DATABASE="${MYSQL_APP_DATABASE:-}"
  MYSQL_APP_USER="${MYSQL_APP_USER:-}"
  MYSQL_APP_PASSWORD="${MYSQL_APP_PASSWORD:-}"
  RABBITMQ_APP_VHOST="${RABBITMQ_APP_VHOST:-}"
  RABBITMQ_APP_USER="${RABBITMQ_APP_USER:-}"
  RABBITMQ_APP_PASSWORD="${RABBITMQ_APP_PASSWORD:-}"
  QUEUE_MODE="${QUEUE_MODE:-rabbitmq-workers}"
  SHARED_BACKEND_ENV="${SHARED_BACKEND_ENV:-${PROJECT_ROOT}/shared/.env}"
  ACME_EMAIL="${ACME_EMAIL:-ops@example.com}"
  SSL_CERT_DIR="${SSL_CERT_DIR:-/etc/ssl/chain-space}"
  SSL_FULLCHAIN_PATH="${SSL_FULLCHAIN_PATH:-${SSL_CERT_DIR}/fullchain.cer}"
  SSL_KEY_PATH="${SSL_KEY_PATH:-${SSL_CERT_DIR}/${SERVER_NAME}.key}"
  ENABLE_HTTPS="${ENABLE_HTTPS:-true}"

  PROJECT_NAME="${PROJECT_NAME:-chain-space}"
  DEPLOY_ROOT="${DEPLOY_ROOT:-/var/www/chain-space}"
  BACKEND_SOURCE_DIR="${BACKEND_SOURCE_DIR:-}"
  RUN_FRONTEND_BUILD="${RUN_FRONTEND_BUILD:-false}"
  HEALTHCHECK_URL="${HEALTHCHECK_URL:-}"
  ADMIN_SMOKE_URL="${ADMIN_SMOKE_URL:-}"
  ADMIN_SMOKE_EXPECT_STATUSES="${ADMIN_SMOKE_EXPECT_STATUSES:-200}"
}

read_env_value() {
  local env_file="$1"
  local key="$2"

  python3 - "${env_file}" "${key}" <<'PY'
from pathlib import Path
import sys

env_path = Path(sys.argv[1])
key = sys.argv[2]

if not env_path.exists():
    raise SystemExit(0)

for line in env_path.read_text().splitlines():
    if not line or line.lstrip().startswith("#") or "=" not in line:
        continue
    current_key, current_value = line.split("=", 1)
    if current_key == key:
        print(current_value.strip())
        raise SystemExit(0)
PY
}

check_required_configs() {
  cs_require_file "${SERVER_CONFIG_FILE}" "生产服务器配置"
  cs_require_file "${DEPLOY_CONFIG_FILE}" "生产发布配置"

  check_non_placeholder "SERVER_NAME" "${SERVER_NAME}"
  check_non_placeholder "PHP_VERSION" "${PHP_VERSION}"
  check_non_placeholder "MYSQL_APP_DATABASE" "${MYSQL_APP_DATABASE}"
  check_non_placeholder "MYSQL_APP_USER" "${MYSQL_APP_USER}"
  check_non_placeholder "MYSQL_APP_PASSWORD" "${MYSQL_APP_PASSWORD}"
  check_non_placeholder "RABBITMQ_APP_VHOST" "${RABBITMQ_APP_VHOST}"
  check_non_placeholder "RABBITMQ_APP_USER" "${RABBITMQ_APP_USER}"
  check_non_placeholder "RABBITMQ_APP_PASSWORD" "${RABBITMQ_APP_PASSWORD}"
  check_non_placeholder "HEALTHCHECK_URL" "${HEALTHCHECK_URL}"
  check_non_placeholder "ADMIN_SMOKE_URL" "${ADMIN_SMOKE_URL}"

  if [[ "${QUEUE_MODE}" == "rabbitmq-workers" ]]; then
    pass "QUEUE_MODE 符合首版基线: ${QUEUE_MODE}"
  else
    fail "QUEUE_MODE 必须为 rabbitmq-workers，当前为 ${QUEUE_MODE}"
  fi

  if cs_bool_is_true "${RUN_FRONTEND_BUILD}"; then
    fail "RUN_FRONTEND_BUILD 必须为 false，本次生产首版不托管 H5"
  else
    pass "RUN_FRONTEND_BUILD 已关闭"
  fi
}

check_dns_resolution() {
  if python3 - "${SERVER_NAME}" <<'PY'
import socket
import sys

try:
    socket.gethostbyname(sys.argv[1])
except OSError:
    raise SystemExit(1)
PY
  then
    pass "SERVER_NAME 域名解析正常: ${SERVER_NAME}"
  else
    fail "SERVER_NAME 域名解析失败: ${SERVER_NAME}"
  fi
}

check_runtime_versions() {
  local php_version_output=""
  local mysql_version_output=""
  local redis_version_output=""
  local rabbitmq_version_output=""
  local es_version_output=""
  local ffmpeg_version_output=""
  local normalized=""

  if [[ "${CURRENT_HOST_OS}" != "Linux" ]]; then
    warn "当前不是 Linux 主机，跳过服务器运行时版本检查"
    return
  fi

  if [[ "${HOST_UBUNTU_VERSION:-}" != "24.04" ]]; then
    fail "当前服务器不是 Ubuntu 24.04，检测到 ${HOST_UBUNTU_VERSION:-unknown}"
    return
  fi

  pass "Ubuntu 版本符合要求: 24.04"

  php_version_output="$(php -r 'echo PHP_MAJOR_VERSION,".",PHP_MINOR_VERSION,".",PHP_RELEASE_VERSION;' 2>/dev/null || true)"
  check_major_minor_prefix "PHP" "${php_version_output}" "8.2"

  if cs_command_exists mysql; then
    mysql_version_output="$(mysql --version 2>/dev/null | sed -E 's/.*Distrib ([0-9]+\.[0-9]+\.[0-9]+).*/\1/' | head -n 1)"
    check_major_minor_prefix "MySQL" "${mysql_version_output}" "8.0"
  else
    fail "未检测到 mysql 命令"
  fi

  if cs_command_exists redis-server; then
    redis_version_output="$(redis-server --version 2>/dev/null | sed -E 's/.*v=([0-9]+\.[0-9]+\.[0-9]+).*/\1/' | head -n 1)"
    check_major_minor_prefix "Redis" "${redis_version_output}" "7.0"
  else
    fail "未检测到 redis-server 命令"
  fi

  if cs_command_exists rabbitmqctl; then
    rabbitmq_version_output="$(rabbitmqctl version 2>/dev/null | tr -d '\r' | head -n 1)"
    check_major_minor_prefix "RabbitMQ" "${rabbitmq_version_output}" "3.13"

    if [[ -f /etc/apt/sources.list.d/rabbitmq.list ]] && grep -Eq 'deb[[:space:]].*deb[12]\.rabbitmq\.com/.*/rabbitmq-server/ubuntu/' /etc/apt/sources.list.d/rabbitmq.list; then
      pass "RabbitMQ 官方 apt 仓库存在"
    else
      fail "未检测到 RabbitMQ 官方 apt 仓库"
    fi
  else
    fail "未检测到 rabbitmqctl 命令"
  fi

  if [[ -x /usr/share/elasticsearch/bin/elasticsearch ]]; then
    es_version_output="$(dpkg-query -W -f='${Version}\n' elasticsearch 2>/dev/null | head -n 1 | cut -d: -f2 | cut -d- -f1)"
    check_semver_ge "Elasticsearch" "${es_version_output}" "8.18.0"
  else
    fail "未检测到 Elasticsearch 可执行文件"
  fi

  if cs_command_exists ffmpeg; then
    ffmpeg_version_output="$(ffmpeg -version 2>/dev/null | sed -n '1s/^ffmpeg version //p' | awk '{print $1}' | head -n 1)"
    normalized="${ffmpeg_version_output#n}"
    check_major_minor_prefix "ffmpeg" "${normalized}" "6.1"
  else
    fail "未检测到 ffmpeg 命令"
  fi
}

check_service_active_if_installed() {
  local service_name="$1"
  local label="$2"

  if [[ "${CURRENT_HOST_OS}" != "Linux" ]]; then
    warn "当前不是 Linux 主机，跳过服务检查: ${label}"
    return
  fi

  if ! cs_command_exists systemctl; then
    warn "当前环境缺少 systemctl，跳过服务检查: ${label}"
    return
  fi

  if systemctl is-active --quiet "${service_name}"; then
    pass "服务运行正常: ${label} (${service_name})"
  else
    fail "服务未运行: ${label} (${service_name})"
  fi
}

check_setup_targets() {
  [[ -d "${PROJECT_ROOT}" ]] && pass "PROJECT_ROOT 存在: ${PROJECT_ROOT}" || warn "PROJECT_ROOT 尚不存在，setup 将创建: ${PROJECT_ROOT}"
  check_dns_resolution
}

check_deploy_targets() {
  [[ -d "${BACKEND_SOURCE_DIR}" ]] && pass "BACKEND_SOURCE_DIR 存在: ${BACKEND_SOURCE_DIR}" || fail "BACKEND_SOURCE_DIR 不存在: ${BACKEND_SOURCE_DIR}"
  [[ -f "${SHARED_BACKEND_ENV}" ]] && pass "共享后端环境文件存在: ${SHARED_BACKEND_ENV}" || fail "共享后端环境文件不存在: ${SHARED_BACKEND_ENV}"

  if [[ -f "${SHARED_BACKEND_ENV}" ]]; then
    [[ "$(read_env_value "${SHARED_BACKEND_ENV}" "APP_URL")" == "https://${SERVER_NAME}" ]] \
      && pass "共享环境 APP_URL 已对齐 https://${SERVER_NAME}" \
      || fail "共享环境 APP_URL 未对齐 https://${SERVER_NAME}"

    [[ "$(read_env_value "${SHARED_BACKEND_ENV}" "ADMIN_HTTPS")" == "true" ]] \
      && pass "共享环境 ADMIN_HTTPS 已配置为 true" \
      || fail "共享环境 ADMIN_HTTPS 未配置为 true"

    [[ "$(read_env_value "${SHARED_BACKEND_ENV}" "QUEUE_CONNECTION")" == "rabbitmq" ]] \
      && pass "共享环境 QUEUE_CONNECTION 已配置为 rabbitmq" \
      || fail "共享环境 QUEUE_CONNECTION 未配置为 rabbitmq"

    [[ "$(read_env_value "${SHARED_BACKEND_ENV}" "VIDEO_PROCESSING_FFMPEG_BINARY")" == "/usr/bin/ffmpeg" ]] \
      && pass "共享环境 VIDEO_PROCESSING_FFMPEG_BINARY 已对齐 /usr/bin/ffmpeg" \
      || fail "共享环境 VIDEO_PROCESSING_FFMPEG_BINARY 未对齐 /usr/bin/ffmpeg"

    [[ "$(read_env_value "${SHARED_BACKEND_ENV}" "ELASTICSEARCH_HOSTS")" == "http://127.0.0.1:9200" ]] \
      && pass "共享环境 ELASTICSEARCH_HOSTS 已对齐本机单节点" \
      || fail "共享环境 ELASTICSEARCH_HOSTS 未对齐 http://127.0.0.1:9200"

    [[ "$(read_env_value "${SHARED_BACKEND_ENV}" "FILESYSTEM_DISK")" == "oss" ]] \
      && pass "共享环境 FILESYSTEM_DISK 已配置为 oss" \
      || fail "共享环境 FILESYSTEM_DISK 未配置为 oss"
  fi

  if cs_bool_is_true "${ENABLE_HTTPS}"; then
    [[ -f "${SSL_FULLCHAIN_PATH}" ]] && pass "HTTPS 证书存在: ${SSL_FULLCHAIN_PATH}" || fail "HTTPS 证书不存在: ${SSL_FULLCHAIN_PATH}"
    [[ -f "${SSL_KEY_PATH}" ]] && pass "HTTPS 私钥存在: ${SSL_KEY_PATH}" || fail "HTTPS 私钥不存在: ${SSL_KEY_PATH}"
  fi
}

check_access_targets() {
  if ! curl --silent --show-error --fail "${HEALTHCHECK_URL}" >/dev/null; then
    fail "健康检查地址不可访问: ${HEALTHCHECK_URL}"
  else
    pass "健康检查地址可访问: ${HEALTHCHECK_URL}"
  fi

  if cs_check_http_endpoint "${ADMIN_SMOKE_URL}" "${ADMIN_SMOKE_EXPECT_STATUSES}" "Dcat Admin" >/dev/null 2>&1; then
    pass "后台登录页可访问: ${ADMIN_SMOKE_URL}"
  else
    fail "后台登录页不可访问或内容不匹配: ${ADMIN_SMOKE_URL}"
  fi
}

check_nginx_config() {
  local site_conf="/etc/nginx/sites-available/${PROJECT_NAME}.conf"

  if [[ -f "${site_conf}" ]]; then
    pass "Nginx 站点配置存在: ${site_conf}"
    if nginx -t >/dev/null 2>&1; then
      pass "Nginx 配置测试通过"
    else
      fail "Nginx 配置测试失败"
    fi
  else
    warn "Nginx 站点配置尚未生成: ${site_conf}"
  fi
}

print_summary() {
  cat <<EOF

================ 生产部署检查结果 ================
检查模式: ${CHECK_MODE}
通过项: ${#PASS_ITEMS[@]}
告警项: ${#WARNING_ITEMS[@]}
阻断项: ${#BLOCKING_ITEMS[@]}
==================================================

EOF
}

main() {
  detect_host_ubuntu_version
  load_configs
  check_required_configs

  case "${CHECK_MODE}" in
    setup)
      check_setup_targets
      ;;
    deploy)
      check_setup_targets
      check_runtime_versions
      check_service_active_if_installed "php${PHP_VERSION}-fpm" "PHP-FPM"
      check_service_active_if_installed "nginx" "Nginx"
      check_service_active_if_installed "redis-server" "Redis"
      check_service_active_if_installed "rabbitmq-server" "RabbitMQ"
      check_service_active_if_installed "elasticsearch" "Elasticsearch"
      check_deploy_targets
      check_nginx_config
      ;;
    all)
      check_setup_targets
      check_runtime_versions
      check_service_active_if_installed "php${PHP_VERSION}-fpm" "PHP-FPM"
      check_service_active_if_installed "nginx" "Nginx"
      check_service_active_if_installed "redis-server" "Redis"
      check_service_active_if_installed "rabbitmq-server" "RabbitMQ"
      check_service_active_if_installed "elasticsearch" "Elasticsearch"
      check_deploy_targets
      check_nginx_config
      check_access_targets
      ;;
    *)
      cs_die "不支持的 CHECK_MODE: ${CHECK_MODE}，可选值: setup / deploy / all"
      ;;
  esac

  print_summary

  if (( FAILURES > 0 )); then
    cs_die "生产部署检查未通过，阻断项数量: ${FAILURES}"
  fi
}

main "$@"
