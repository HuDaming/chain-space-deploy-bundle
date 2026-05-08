#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd -P)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/chain-space-deploy-common.sh"

trap 'cs_on_error "$?" "${LINENO}"' ERR

QUEUE_MODE="${QUEUE_MODE:-rabbitmq-workers}"
PROJECT_NAME="${PROJECT_NAME:-chain-space}"
APP_USER="${APP_USER:-www-data}"
APP_ENV="${APP_ENV:-production}"
APP_ROOT="${APP_ROOT:-/var/www/chain-space/current/backend}"
PHP_BIN="${PHP_BIN:-/usr/bin/php}"
SUPERVISOR_DIR="${SUPERVISOR_DIR:-/etc/supervisor/conf.d}"
DEPLOY_TEMPLATE_DIR="${DEPLOY_TEMPLATE_DIR:-${REPO_ROOT}/backend/deploy/supervisor}"
RESTART_SUPERVISOR="${RESTART_SUPERVISOR:-true}"
DEFAULT_QUEUE_NAME="${DEFAULT_QUEUE_NAME:-chain-space.default}"
VIDEO_QUEUE_NAME="${VIDEO_QUEUE_NAME:-video-processing}"

render_template() {
  local template_file="$1"
  local output_file="$2"
  shift 2

  cs_render_file_with_vars "${template_file}" "${output_file}" "$@"
}

render_rabbitmq_workers() {
  render_template \
    "${DEPLOY_TEMPLATE_DIR}/default-worker.conf.example" \
    "${SUPERVISOR_DIR}/chain-space-default-worker.conf" \
    "php_bin=${PHP_BIN}" \
    "app_root=${APP_ROOT}" \
    "app_user=${APP_USER}" \
    "app_env=${APP_ENV}" \
    "queue_connection=rabbitmq" \
    "queue_name=${DEFAULT_QUEUE_NAME}" \
    "stdout_logfile=${APP_ROOT}/storage/logs/supervisor-default-worker.log"

  render_template \
    "${DEPLOY_TEMPLATE_DIR}/video-processing.conf.example" \
    "${SUPERVISOR_DIR}/chain-space-video-processing.conf" \
    "php_bin=${PHP_BIN}" \
    "app_root=${APP_ROOT}" \
    "app_user=${APP_USER}" \
    "app_env=${APP_ENV}" \
    "queue_connection=rabbitmq" \
    "queue_name=${VIDEO_QUEUE_NAME}" \
    "stdout_logfile=${APP_ROOT}/storage/logs/supervisor-video-processing.log"
}

render_horizon_stack() {
  render_template \
    "${DEPLOY_TEMPLATE_DIR}/horizon.conf.example" \
    "${SUPERVISOR_DIR}/chain-space-horizon.conf" \
    "php_bin=${PHP_BIN}" \
    "app_root=${APP_ROOT}" \
    "app_user=${APP_USER}" \
    "app_env=${APP_ENV}" \
    "stdout_logfile=${APP_ROOT}/storage/logs/supervisor-horizon.log"

  render_template \
    "${DEPLOY_TEMPLATE_DIR}/scheduler.conf.example" \
    "${SUPERVISOR_DIR}/chain-space-scheduler.conf" \
    "php_bin=${PHP_BIN}" \
    "app_root=${APP_ROOT}" \
    "app_user=${APP_USER}" \
    "app_env=${APP_ENV}" \
    "stdout_logfile=${APP_ROOT}/storage/logs/supervisor-scheduler.log"
}

disable_unused_programs() {
  local file_name
  for file_name in chain-space-default-worker.conf chain-space-video-processing.conf chain-space-horizon.conf chain-space-scheduler.conf; do
    if [[ -f "${SUPERVISOR_DIR}/${file_name}" ]]; then
      rm -f "${SUPERVISOR_DIR:?}/${file_name}"
    fi
  done
}

reload_supervisor() {
  if ! cs_bool_is_true "${RESTART_SUPERVISOR}"; then
    return
  fi

  supervisorctl reread
  supervisorctl update
}

main() {
  cs_require_root
  cs_require_command supervisorctl
  cs_require_command python3

  mkdir -p "${SUPERVISOR_DIR}"
  disable_unused_programs

  case "${QUEUE_MODE}" in
    rabbitmq-workers)
      render_rabbitmq_workers
      ;;
    horizon)
      render_horizon_stack
      ;;
    *)
      cs_die "不支持的 QUEUE_MODE: ${QUEUE_MODE}"
      ;;
  esac

  reload_supervisor

  cat <<EOF

================ Supervisor 配置完成 ================
队列模式: ${QUEUE_MODE}
输出目录: ${SUPERVISOR_DIR}
应用目录: ${APP_ROOT}
用户: ${APP_USER}
=====================================================

EOF
}

main "$@"
