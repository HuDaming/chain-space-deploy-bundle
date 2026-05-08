#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/chain-space-deploy-common.sh"

trap 'cs_on_error "$?" "${LINENO}"' ERR

CONFIG_FILE="${CONFIG_FILE:-${SCRIPT_DIR}/config/deploy-release.production.env}"
DEPLOY_SCRIPT="${SCRIPT_DIR}/deploy-chain-space-release.sh"
CHECK_SCRIPT="${SCRIPT_DIR}/check-chain-space-production.sh"
SERVER_CONFIG_FILE="${SERVER_CONFIG_FILE:-${SCRIPT_DIR}/config/production-server.env}"
ENV_LABEL="${ENV_LABEL:-生产环境}"

load_config() {
  cs_source_config "${CONFIG_FILE}" "生产发布配置"
  cs_require_file "${DEPLOY_SCRIPT}" "发布脚本"
  cs_require_file "${CHECK_SCRIPT}" "生产预检脚本"
}

validate_config() {
  : "${DEPLOY_ROOT:?DEPLOY_ROOT 未配置}"
  : "${BACKEND_SOURCE_DIR:?BACKEND_SOURCE_DIR 未配置}"
  : "${APP_USER:?APP_USER 未配置}"
  : "${APP_GROUP:?APP_GROUP 未配置}"
  : "${QUEUE_MODE:?QUEUE_MODE 未配置}"
}

run_precheck() {
  SERVER_CONFIG_FILE="${SERVER_CONFIG_FILE}" \
  DEPLOY_CONFIG_FILE="${CONFIG_FILE}" \
  CHECK_MODE=deploy \
  bash "${CHECK_SCRIPT}"
}

main() {
  load_config
  validate_config

  cs_log "INFO" "使用${ENV_LABEL}发布配置: ${CONFIG_FILE}"
  run_precheck
  export PROJECT_NAME DEPLOY_ROOT BACKEND_SOURCE_DIR FRONTEND_SOURCE_DIR APP_USER APP_GROUP
  export PHP_BIN COMPOSER_BIN RELEASES_TO_KEEP RUN_MIGRATIONS MIGRATION_STRATEGY
  export ALLOW_DESTRUCTIVE_MIGRATIONS DESTRUCTIVE_MIGRATIONS_CONFIRMATION
  export RUN_STORAGE_LINK RUN_FRONTEND_BUILD RUN_HEALTHCHECK HEALTHCHECK_URL
  export RUN_ACCESS_CHECKS ADMIN_ROUTE_PREFIX ADMIN_SMOKE_URL ADMIN_SMOKE_EXPECT_STATUSES ADMIN_SMOKE_CONTAINS
  export QUEUE_MODE SUPERVISOR_PROGRAMS ALLOW_DIRTY_WORKTREE
  export SKIP_GIT_METADATA SOURCE_REVISION_OVERRIDE SOURCE_BRANCH_OVERRIDE

  bash "${DEPLOY_SCRIPT}" "$@"
}

main "$@"
