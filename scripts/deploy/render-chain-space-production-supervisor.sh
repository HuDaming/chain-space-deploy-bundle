#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

QUEUE_MODE="${QUEUE_MODE:-rabbitmq-workers}"
PROJECT_NAME="${PROJECT_NAME:-chain-space}"
APP_USER="${APP_USER:-www-data}"
APP_ENV="${APP_ENV:-production}"
APP_ROOT="${APP_ROOT:-/var/www/chain-space/current/backend}"
PHP_BIN="${PHP_BIN:-/usr/bin/php}"
SUPERVISOR_DIR="${SUPERVISOR_DIR:-/etc/supervisor/conf.d}"
DEPLOY_TEMPLATE_DIR="${DEPLOY_TEMPLATE_DIR:-$(cd -- "${SCRIPT_DIR}/../.." && pwd -P)/backend/deploy/supervisor}"
RESTART_SUPERVISOR="${RESTART_SUPERVISOR:-true}"
DEFAULT_QUEUE_NAME="${DEFAULT_QUEUE_NAME:-chain-space.default}"
VIDEO_QUEUE_NAME="${VIDEO_QUEUE_NAME:-video-processing}"

exec bash "${SCRIPT_DIR}/render-chain-space-supervisor.sh"
