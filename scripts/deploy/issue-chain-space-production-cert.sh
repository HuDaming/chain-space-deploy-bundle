#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/chain-space-deploy-common.sh"

trap 'cs_on_error "$?" "${LINENO}"' ERR

SERVER_NAME="${SERVER_NAME:-api.example.com}"
ACME_EMAIL="${ACME_EMAIL:-ops@example.com}"
ACME_WEBROOT="${ACME_WEBROOT:-/var/www/chain-space/acme}"
ACME_INSTALL_DIR="${ACME_INSTALL_DIR:-/root/.acme.sh}"
SSL_CERT_DIR="${SSL_CERT_DIR:-/etc/ssl/chain-space}"
SSL_FULLCHAIN_PATH="${SSL_FULLCHAIN_PATH:-${SSL_CERT_DIR}/fullchain.cer}"
SSL_KEY_PATH="${SSL_KEY_PATH:-${SSL_CERT_DIR}/${SERVER_NAME}.key}"
FORCE_REISSUE_CERT="${FORCE_REISSUE_CERT:-false}"
LOG_FILE="${LOG_FILE:-/var/log/chain-space/issue-production-cert.log}"

ensure_acme_installed() {
  if [[ -x "${ACME_INSTALL_DIR}/acme.sh" ]]; then
    return
  fi

  cs_require_command curl
  cs_require_command sh
  cs_log "INFO" "安装 acme.sh"
  curl -fsSL https://get.acme.sh | sh -s email="${ACME_EMAIL}"
}

issue_certificate() {
  local acme_cmd=("${ACME_INSTALL_DIR}/acme.sh")

  mkdir -p "${ACME_WEBROOT}" "${SSL_CERT_DIR}"

  if cs_bool_is_true "${FORCE_REISSUE_CERT}"; then
    "${acme_cmd[@]}" --remove -d "${SERVER_NAME}" >/dev/null 2>&1 || true
  fi

  "${acme_cmd[@]}" --set-default-ca --server letsencrypt
  "${acme_cmd[@]}" --issue -d "${SERVER_NAME}" -w "${ACME_WEBROOT}" --keylength ec-256
  "${acme_cmd[@]}" --install-cert -d "${SERVER_NAME}" --ecc \
    --fullchain-file "${SSL_FULLCHAIN_PATH}" \
    --key-file "${SSL_KEY_PATH}" \
    --reloadcmd "systemctl reload nginx"

  chmod 0644 "${SSL_FULLCHAIN_PATH}"
  chmod 0600 "${SSL_KEY_PATH}"
}

main() {
  cs_require_root
  cs_require_command nginx
  cs_require_command openssl

  cs_run_step "安装 acme.sh" "${LOG_FILE}" ensure_acme_installed
  cs_run_step "签发并安装 HTTPS 证书" "${LOG_FILE}" issue_certificate

  cat <<EOF

================ HTTPS 证书签发完成 ================
域名: ${SERVER_NAME}
ACME 邮箱: ${ACME_EMAIL}
ACME Webroot: ${ACME_WEBROOT}
证书文件: ${SSL_FULLCHAIN_PATH}
私钥文件: ${SSL_KEY_PATH}
===============================================

EOF
}

main "$@"
