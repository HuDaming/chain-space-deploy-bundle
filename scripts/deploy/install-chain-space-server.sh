#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/chain-space-deploy-common.sh"

trap 'cs_on_error "$?" "${LINENO}"' ERR

detect_supported_ubuntu() {
  cs_require_ubuntu

  case "${VERSION_ID:-}" in
    "20.04"|"22.04"|"24.04")
      UBUNTU_VERSION_ID="${VERSION_ID}"
      UBUNTU_CODENAME="${VERSION_CODENAME:-}"
      ;;
    *)
      cs_die "当前仅支持 Ubuntu 20.04 / 22.04 / 24.04，检测到 ${VERSION_ID:-unknown}"
      ;;
  esac
}

install_apt_prerequisites() {
  export DEBIAN_FRONTEND=noninteractive

  cs_log "INFO" "安装系统基础依赖"
  apt-get update
  apt-get install -y \
    apt-transport-https \
    ca-certificates \
    curl \
    ffmpeg \
    git \
    gnupg \
    jq \
    lsb-release \
    software-properties-common \
    sqlite3 \
    supervisor \
    unzip \
    zip \
    build-essential
}

ensure_timezone_and_locale() {
  cs_log "INFO" "配置时区与语言环境"
  ln -snf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
  echo "Asia/Shanghai" > /etc/timezone
  if cs_command_exists timedatectl; then
    timedatectl set-timezone Asia/Shanghai || true
  fi

  locale-gen en_US.UTF-8 zh_CN.UTF-8
  update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
}

ensure_aliases() {
  cs_log "INFO" "写入常用别名"
  cat > /etc/profile.d/chain-space-aliases.sh <<EOF
alias sudowww='sudo -H -u ${APP_USER} bash -lc'
EOF
  chmod 0644 /etc/profile.d/chain-space-aliases.sh
}

ensure_swap() {
  local swap_file="/swapfile"
  local swap_size_mb="${SWAP_SIZE_MB:-0}"

  if ! cs_bool_is_true "${ENABLE_SWAP:-false}"; then
    cs_log "INFO" "已禁用 swap 配置"
    return
  fi

  if ! [[ "${swap_size_mb}" =~ ^[0-9]+$ ]] || [[ "${swap_size_mb}" -le 0 ]]; then
    cs_die "SWAP_SIZE_MB 必须是大于 0 的整数，当前值: ${swap_size_mb}"
  fi

  if swapon --show=NAME --noheadings 2>/dev/null | grep -qx "${swap_file}"; then
    cs_log "INFO" "swapfile 已启用: ${swap_file}"
    return
  fi

  cs_log "INFO" "配置 swapfile: ${swap_file} (${swap_size_mb} MB)"

  if [[ ! -f "${swap_file}" ]]; then
    if cs_command_exists fallocate; then
      fallocate -l "${swap_size_mb}M" "${swap_file}"
    else
      dd if=/dev/zero of="${swap_file}" bs=1M count="${swap_size_mb}" status=none
    fi
  fi

  chmod 0600 "${swap_file}"
  mkswap "${swap_file}" >/dev/null
  swapon "${swap_file}"

  if ! grep -q "^${swap_file}[[:space:]]" /etc/fstab; then
    printf '%s none swap sw 0 0\n' "${swap_file}" >> /etc/fstab
  fi
}

ensure_php_repository() {
  cs_log "INFO" "配置 PHP PPA（Ubuntu 24.04 下 PHP 8.2 继续通过 Ondrej PPA 安装）"
  add-apt-repository -y ppa:ondrej/php
}

ensure_nodesource_repository() {
  cs_log "INFO" "配置 NodeSource ${NODE_MAJOR}.x 软件源"
  cs_write_gpg_keyring "https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key" "/etc/apt/keyrings/nodesource.gpg"

  cat > /etc/apt/sources.list.d/nodesource.list <<EOF
deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main
EOF
}

ensure_elastic_repository() {
  if ! cs_bool_is_true "${INSTALL_ELASTICSEARCH}"; then
    return
  fi

  cs_log "INFO" "配置 Elasticsearch 8.x 官方软件源"
  cs_write_gpg_keyring "https://artifacts.elastic.co/GPG-KEY-elasticsearch" "/etc/apt/keyrings/elasticsearch.gpg"

  cat > /etc/apt/sources.list.d/elastic-8.x.list <<EOF
deb [signed-by=/etc/apt/keyrings/elasticsearch.gpg] https://artifacts.elastic.co/packages/8.x/apt stable main
EOF
}

ensure_rabbitmq_repository() {
  local apt_arch

  if ! cs_bool_is_true "${INSTALL_RABBITMQ}"; then
    return
  fi

  cs_log "INFO" "配置 RabbitMQ 官方 apt 软件源"
  apt_arch="$(dpkg --print-architecture)"
  cs_write_gpg_keyring \
    "https://keys.openpgp.org/vks/v1/by-fingerprint/0A9AF2115F4687BD29803A206B73A36E6026DFCA" \
    "/usr/share/keyrings/com.rabbitmq.team.gpg"

  cat > /etc/apt/sources.list.d/rabbitmq.list <<EOF
deb [arch=${apt_arch} signed-by=/usr/share/keyrings/com.rabbitmq.team.gpg] https://deb1.rabbitmq.com/rabbitmq-erlang/ubuntu/${UBUNTU_CODENAME} ${UBUNTU_CODENAME} main
deb [arch=${apt_arch} signed-by=/usr/share/keyrings/com.rabbitmq.team.gpg] https://deb2.rabbitmq.com/rabbitmq-erlang/ubuntu/${UBUNTU_CODENAME} ${UBUNTU_CODENAME} main
deb [arch=${apt_arch} signed-by=/usr/share/keyrings/com.rabbitmq.team.gpg] https://deb1.rabbitmq.com/rabbitmq-server/ubuntu/${UBUNTU_CODENAME} ${UBUNTU_CODENAME} main
deb [arch=${apt_arch} signed-by=/usr/share/keyrings/com.rabbitmq.team.gpg] https://deb2.rabbitmq.com/rabbitmq-server/ubuntu/${UBUNTU_CODENAME} ${UBUNTU_CODENAME} main
EOF
}

assert_php_version_supported() {
  if [[ "${UBUNTU_VERSION_ID}" == "24.04" && "${PHP_VERSION}" != "8.2" ]]; then
    cs_log "WARN" "Ubuntu 24.04 当前推荐 PHP 8.2，以保持与仓库现有 Laravel 11 / 发布脚本基线一致"
  fi
}

install_main_packages() {
  local packages=(
    composer
    nginx
    nodejs
    php${PHP_VERSION}
    php${PHP_VERSION}-amqp
    php${PHP_VERSION}-bcmath
    php${PHP_VERSION}-cli
    php${PHP_VERSION}-curl
    php${PHP_VERSION}-fpm
    php${PHP_VERSION}-gd
    php${PHP_VERSION}-intl
    php${PHP_VERSION}-mbstring
    php${PHP_VERSION}-mysql
    php${PHP_VERSION}-opcache
    php${PHP_VERSION}-readline
    php${PHP_VERSION}-redis
    php${PHP_VERSION}-sqlite3
    php${PHP_VERSION}-xml
    php${PHP_VERSION}-zip
    redis-server
  )

  if cs_bool_is_true "${INSTALL_MYSQL}"; then
    packages+=(mysql-server)
  fi

  if cs_bool_is_true "${INSTALL_RABBITMQ}"; then
    packages+=(rabbitmq-server)
  fi

  if cs_bool_is_true "${INSTALL_ELASTICSEARCH}"; then
    packages+=(elasticsearch)
  fi

  cs_log "INFO" "安装主运行依赖"
  apt-get update
  apt-get install -y "${packages[@]}"
}

configure_php() {
  local cli_ini="/etc/php/${PHP_VERSION}/cli/php.ini"
  local fpm_ini="/etc/php/${PHP_VERSION}/fpm/php.ini"

  cs_log "INFO" "配置 PHP ${PHP_VERSION}"
  sed -i 's/^memory_limit = .*/memory_limit = 512M/' "${cli_ini}" "${fpm_ini}"
  sed -i 's/^upload_max_filesize = .*/upload_max_filesize = 64M/' "${cli_ini}" "${fpm_ini}"
  sed -i 's/^post_max_size = .*/post_max_size = 64M/' "${cli_ini}" "${fpm_ini}"
  sed -i 's/^;*date.timezone =.*/date.timezone = Asia\/Shanghai/' "${cli_ini}" "${fpm_ini}"

  systemctl enable "php${PHP_VERSION}-fpm"
  systemctl restart "php${PHP_VERSION}-fpm"
}

configure_node() {
  cs_log "INFO" "配置 Node.js 工具链"
  corepack enable
  corepack prepare "pnpm@${PNPM_VERSION}" --activate

  if cs_command_exists yarn; then
    cs_log "INFO" "检测到 yarn 已存在，跳过全局安装"
    return
  fi

  npm install -g yarn
}

configure_nginx() {
  cs_log "INFO" "启用 Nginx"
  systemctl enable nginx
  systemctl restart nginx
}

configure_mysql() {
  if ! cs_bool_is_true "${INSTALL_MYSQL}"; then
    return
  fi

  cs_log "INFO" "配置 MySQL"
  systemctl enable mysql
  systemctl restart mysql

  if [[ -n "${MYSQL_ROOT_PASSWORD}" ]]; then
    mysql -uroot <<SQL
ALTER USER 'root'@'localhost' IDENTIFIED WITH caching_sha2_password BY '${MYSQL_ROOT_PASSWORD}';
FLUSH PRIVILEGES;
SQL
  fi

  mysql -uroot${MYSQL_ROOT_PASSWORD:+ -p${MYSQL_ROOT_PASSWORD}} <<SQL
CREATE DATABASE IF NOT EXISTS \`${MYSQL_APP_DATABASE}\`
  CHARACTER SET utf8mb4
  COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${MYSQL_APP_USER}'@'%' IDENTIFIED BY '${MYSQL_APP_PASSWORD}';
ALTER USER '${MYSQL_APP_USER}'@'%' IDENTIFIED BY '${MYSQL_APP_PASSWORD}';
GRANT ALL PRIVILEGES ON \`${MYSQL_APP_DATABASE}\`.* TO '${MYSQL_APP_USER}'@'%';
FLUSH PRIVILEGES;
SQL
}

configure_redis() {
  cs_log "INFO" "配置 Redis"
  if grep -q '^supervised ' /etc/redis/redis.conf; then
    sed -i 's/^supervised .*/supervised systemd/' /etc/redis/redis.conf
  else
    printf '\nsupervised systemd\n' >> /etc/redis/redis.conf
  fi
  sed -i 's/^bind .*/bind 127.0.0.1 ::1/' /etc/redis/redis.conf
  sed -i 's/^protected-mode .*/protected-mode yes/' /etc/redis/redis.conf
  systemctl enable redis-server
  systemctl restart redis-server
}

configure_rabbitmq() {
  if ! cs_bool_is_true "${INSTALL_RABBITMQ}"; then
    return
  fi

  cs_log "INFO" "配置 RabbitMQ"
  systemctl enable rabbitmq-server
  systemctl restart rabbitmq-server

  if cs_bool_is_true "${ENABLE_RABBITMQ_MANAGEMENT}"; then
    rabbitmq-plugins enable --offline rabbitmq_management
    systemctl restart rabbitmq-server
  fi

  rabbitmqctl add_vhost "${RABBITMQ_APP_VHOST}" 2>/dev/null || true
  rabbitmqctl add_user "${RABBITMQ_APP_USER}" "${RABBITMQ_APP_PASSWORD}" 2>/dev/null || true
  rabbitmqctl change_password "${RABBITMQ_APP_USER}" "${RABBITMQ_APP_PASSWORD}"
  rabbitmqctl set_permissions -p "${RABBITMQ_APP_VHOST}" "${RABBITMQ_APP_USER}" ".*" ".*" ".*"
  rabbitmqctl set_user_tags "${RABBITMQ_APP_USER}" management
}

rabbitmq_repo_configured() {
  [[ -f /etc/apt/sources.list.d/rabbitmq.list ]] || return 1
  grep -Eq 'deb[[:space:]].*deb[12]\.rabbitmq\.com/.*/rabbitmq-server/ubuntu/' /etc/apt/sources.list.d/rabbitmq.list
}

rabbitmq_version() {
  rabbitmqctl version 2>/dev/null | tr -d '\r'
}

installed_es_version() {
  dpkg-query -W -f='${Version}\n' elasticsearch | head -n 1 | cut -d: -f2 | cut -d- -f1
}

assert_elasticsearch_version_support() {
  local es_version

  if ! cs_bool_is_true "${INSTALL_ELASTICSEARCH}"; then
    return
  fi

  es_version="$(installed_es_version)"
  if [[ -z "${es_version}" ]]; then
    cs_die "未能识别已安装的 Elasticsearch 版本"
  fi

  if [[ "${UBUNTU_VERSION_ID}" == "24.04" ]] && ! dpkg --compare-versions "${es_version}" ge "8.18.0"; then
    cs_die "Ubuntu 24.04 仅允许 Elasticsearch >= 8.18，当前安装版本为 ${es_version}"
  fi
}

install_es_ik_plugin() {
  if ! cs_bool_is_true "${INSTALL_ELASTICSEARCH}" || ! cs_bool_is_true "${INSTALL_ES_IK}"; then
    return
  fi

  if [[ -d /usr/share/elasticsearch/plugins/analysis-ik ]]; then
    cs_log "INFO" "IK 分词器已存在，跳过安装"
    return
  fi

  local es_version
  es_version="$(installed_es_version)"

  cs_log "INFO" "安装 Elasticsearch IK 分词插件 ${es_version}"
  systemctl stop elasticsearch
  /usr/share/elasticsearch/bin/elasticsearch-plugin install --batch \
    "https://github.com/medcl/elasticsearch-analysis-ik/releases/download/v${es_version}/elasticsearch-analysis-ik-${es_version}.zip"
}

configure_elasticsearch() {
  if ! cs_bool_is_true "${INSTALL_ELASTICSEARCH}"; then
    return
  fi

  cs_log "INFO" "配置 Elasticsearch 单节点模式"
  mkdir -p /etc/elasticsearch/jvm.options.d
  cat > /etc/elasticsearch/elasticsearch.yml <<EOF
cluster.name: ${APP_NAME}
node.name: $(hostname -s)
path.data: /var/lib/elasticsearch
path.logs: /var/log/elasticsearch
network.host: 127.0.0.1
http.port: 9200
discovery.type: single-node
xpack.security.enabled: false
xpack.security.enrollment.enabled: false
EOF

  cat > /etc/elasticsearch/jvm.options.d/${APP_NAME}.options <<EOF
-Xms${ES_HEAP_SIZE}
-Xmx${ES_HEAP_SIZE}
EOF

  install_es_ik_plugin

  systemctl daemon-reload
  systemctl enable elasticsearch
  systemctl restart elasticsearch
}

prepare_directories() {
  cs_log "INFO" "准备项目目录"
  mkdir -p "${PROJECT_ROOT}"/{backend,frontend,releases,shared}
  mkdir -p "${PROJECT_ROOT}/shared/storage/logs"
  mkdir -p "${PROJECT_ROOT}/shared/storage/app"
  mkdir -p "${PROJECT_ROOT}/shared/storage/framework/"{cache,sessions,views}
  mkdir -p "${PROJECT_ROOT}/shared/public"
  chown -R "${APP_USER}:${APP_GROUP}" "${PROJECT_ROOT}"
}

verify_installation() {
  cs_log "INFO" "输出安装结果"
  printf 'PHP: %s\n' "$(php -v | head -n 1)"
  printf 'Composer: %s\n' "$(composer --version)"
  printf 'Node.js: %s\n' "$(node --version)"
  printf 'npm: %s\n' "$(npm --version)"
  printf 'pnpm: %s\n' "$(pnpm --version)"
  printf 'Nginx: %s\n' "$(nginx -v 2>&1)"
  printf 'Redis: %s\n' "$(redis-server --version | head -n 1)"

  if cs_bool_is_true "${INSTALL_MYSQL}"; then
    printf 'MySQL: %s\n' "$(mysql --version)"
  fi

  if cs_bool_is_true "${INSTALL_RABBITMQ}"; then
    if rabbitmq_repo_configured; then
      printf 'RabbitMQ Repo: official\n'
    else
      printf 'RabbitMQ Repo: unknown\n'
    fi
    printf 'RabbitMQ: %s\n' "$(rabbitmq_version)"
  fi

  if cs_bool_is_true "${INSTALL_ELASTICSEARCH}"; then
    printf 'Elasticsearch: %s\n' "$(/usr/share/elasticsearch/bin/elasticsearch --version)"
  fi

  printf 'ffmpeg: %s\n' "$(ffmpeg -version | head -n 1)"
}

print_summary() {
  cat <<EOF

================ 安装完成 ================
项目目录: ${PROJECT_ROOT}
PHP 版本: ${PHP_VERSION}
Node 主版本: ${NODE_MAJOR}
pnpm 版本: ${PNPM_VERSION}
APP 用户: ${APP_USER}:${APP_GROUP}
Ubuntu 版本: ${UBUNTU_VERSION_ID}

MySQL 数据库: ${MYSQL_APP_DATABASE}
MySQL 用户: ${MYSQL_APP_USER}
MySQL 密码: ${MYSQL_APP_PASSWORD}
MySQL root 密码: ${MYSQL_ROOT_PASSWORD:-<保持系统默认 socket 登录>}

RabbitMQ vhost: ${RABBITMQ_APP_VHOST}
RabbitMQ 用户: ${RABBITMQ_APP_USER}
RabbitMQ 密码: ${RABBITMQ_APP_PASSWORD}

Elasticsearch: $(cs_bool_is_true "${INSTALL_ELASTICSEARCH}" && echo "已安装，监听 127.0.0.1:9200" || echo "未安装")
IK 分词器: $(cs_bool_is_true "${INSTALL_ES_IK}" && echo "已尝试安装" || echo "未安装")
RabbitMQ 软件源: $(cs_bool_is_true "${INSTALL_RABBITMQ}" && echo "官方 apt 仓库" || echo "未安装")
ffmpeg 来源: Ubuntu ${UBUNTU_VERSION_ID} 系统包

后续建议:
1. 将共享环境文件放到 ${PROJECT_ROOT}/shared/.env，并按 backend/.env.example 补齐 OSS、微信、RabbitMQ、Elasticsearch 等变量
2. 如需构建前端，将 H5 环境文件放到 ${PROJECT_ROOT}/shared/frontend.env
3. 使用版本化发布脚本部署代码到 ${PROJECT_ROOT}/releases 并切换 ${PROJECT_ROOT}/current
4. 使用 Supervisor 常驻 RabbitMQ worker 或 Horizon + Scheduler
5. 为 Nginx 单独补充站点配置并指向 ${PROJECT_ROOT}/current/backend/public
6. 执行 GET /api/v1/health 验证 ffmpeg / queue / oss / elasticsearch 状态
==========================================

EOF
}

main() {
  cs_require_root
  detect_supported_ubuntu

  APP_NAME="${APP_NAME:-chain-space}"
  PROJECT_ROOT="${PROJECT_ROOT:-/var/www/chain-space}"
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
  MYSQL_APP_DATABASE="${MYSQL_APP_DATABASE:-chain_space}"
  MYSQL_APP_USER="${MYSQL_APP_USER:-chain_space}"
  MYSQL_APP_PASSWORD="${MYSQL_APP_PASSWORD:-$(cs_random_string)}"
  MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD:-}"
  RABBITMQ_APP_VHOST="${RABBITMQ_APP_VHOST:-/chain-space}"
  RABBITMQ_APP_USER="${RABBITMQ_APP_USER:-chain-space}"
  RABBITMQ_APP_PASSWORD="${RABBITMQ_APP_PASSWORD:-$(cs_random_string)}"
  ES_HEAP_SIZE="${ES_HEAP_SIZE:-1g}"
  LOG_FILE="${LOG_FILE:-/var/log/chain-space/install-server.log}"

  cs_log "INFO" "开始安装适配 ${APP_NAME} 的服务器运行环境"
  cs_log "INFO" "检测到 Ubuntu ${UBUNTU_VERSION_ID} (${UBUNTU_CODENAME})"
  assert_php_version_supported

  cs_run_step "安装系统基础依赖" "${LOG_FILE}" install_apt_prerequisites
  cs_run_step "配置时区与语言环境" "${LOG_FILE}" ensure_timezone_and_locale
  cs_run_step "写入常用别名" "${LOG_FILE}" ensure_aliases
  cs_run_step "配置 swap" "${LOG_FILE}" ensure_swap
  cs_run_step "配置 PHP 软件源" "${LOG_FILE}" ensure_php_repository
  cs_run_step "配置 Node.js 软件源" "${LOG_FILE}" ensure_nodesource_repository
  cs_run_step "配置 RabbitMQ 软件源" "${LOG_FILE}" ensure_rabbitmq_repository
  cs_run_step "配置 Elasticsearch 软件源" "${LOG_FILE}" ensure_elastic_repository
  cs_run_step "安装主运行依赖" "${LOG_FILE}" install_main_packages
  cs_run_step "配置 PHP" "${LOG_FILE}" configure_php
  cs_run_step "配置 Node.js 工具链" "${LOG_FILE}" configure_node
  cs_run_step "启动 Nginx" "${LOG_FILE}" configure_nginx
  cs_run_step "配置 MySQL" "${LOG_FILE}" configure_mysql
  cs_run_step "配置 Redis" "${LOG_FILE}" configure_redis
  cs_run_step "配置 RabbitMQ" "${LOG_FILE}" configure_rabbitmq
  cs_run_step "配置 Elasticsearch" "${LOG_FILE}" configure_elasticsearch
  cs_run_step "校验 Elasticsearch 版本支持" "${LOG_FILE}" assert_elasticsearch_version_support
  cs_run_step "准备项目目录" "${LOG_FILE}" prepare_directories
  cs_run_step "校验安装结果" "${LOG_FILE}" verify_installation
  print_summary
}

main "$@"
