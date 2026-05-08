#!/usr/bin/env bash

cs_timestamp() {
  date '+%Y-%m-%d %H:%M:%S'
}

cs_log() {
  local level="$1"
  shift
  printf '[%s] [%s] %s\n' "$(cs_timestamp)" "${level}" "$*"
}

cs_die() {
  cs_log "ERROR" "$*"
  exit 1
}

cs_on_error() {
  local exit_code="$1"
  local line_no="$2"
  cs_die "脚本执行失败，退出码=${exit_code}，出错行=${line_no}"
}

cs_bool_is_true() {
  local value="${1:-false}"
  local normalized

  normalized="$(printf '%s' "${value}" | tr '[:upper:]' '[:lower:]')"
  [[ "${normalized}" == "1" || "${normalized}" == "true" || "${normalized}" == "yes" || "${normalized}" == "y" ]]
}

cs_command_exists() {
  command -v "$1" >/dev/null 2>&1
}

cs_require_command() {
  cs_command_exists "$1" || cs_die "缺少命令: $1"
}

cs_require_file() {
  local path="$1"
  local label="${2:-文件}"
  [[ -f "${path}" ]] || cs_die "${label}不存在: ${path}"
}

cs_require_root() {
  [[ "$(id -u)" -eq 0 ]] || cs_die "当前操作需要 root 权限，请使用受限运维用户通过 sudo 执行本脚本"
}

cs_run_as_user() {
  local target_user="$1"
  shift

  if [[ "$(id -un)" == "${target_user}" ]]; then
    "$@"
  elif [[ "$(id -u)" -eq 0 ]]; then
    runuser -u "${target_user}" -- "$@"
  else
    sudo -H -u "${target_user}" "$@"
  fi
}

cs_require_ubuntu() {
  [[ -f /etc/os-release ]] || cs_die "未找到 /etc/os-release，无法识别系统版本"

  # shellcheck disable=SC1091
  source /etc/os-release

  [[ "${ID:-}" == "ubuntu" ]] || cs_die "当前仅支持 Ubuntu 系统"
}

cs_random_string() {
  local length="${1:-24}"
  openssl rand -base64 48 | tr -d '\n' | tr '/+' 'ab' | cut -c1-"${length}"
}

cs_run_step() {
  local description="$1"
  local log_file="$2"
  shift 2

  mkdir -p "$(dirname "${log_file}")"
  cs_log "INFO" "开始: ${description}"

  if "$@" >>"${log_file}" 2>&1; then
    cs_log "INFO" "完成: ${description}"
    return 0
  fi

  cs_log "ERROR" "失败: ${description}"
  if [[ -s "${log_file}" ]]; then
    cs_log "ERROR" "最近日志:"
    tail -n 20 "${log_file}" || true
  fi
  return 1
}

cs_write_file() {
  local target="$1"
  local tmp_file

  tmp_file="$(mktemp)"
  cat >"${tmp_file}"
  mkdir -p "$(dirname "${target}")"
  mv "${tmp_file}" "${target}"
}

cs_write_gpg_keyring() {
  local url="$1"
  local target="$2"
  local tmp_file

  tmp_file="$(mktemp)"
  curl -fsSL "${url}" | gpg --dearmor >"${tmp_file}"
  mkdir -p "$(dirname "${target}")"
  mv "${tmp_file}" "${target}"
  chmod 0644 "${target}"
}

cs_symlink_force() {
  local source_path="$1"
  local target_path="$2"
  ln -sfn "${source_path}" "${target_path}"
}

cs_keep_latest_dirs() {
  local parent_dir="$1"
  local keep_count="$2"

  [[ -d "${parent_dir}" ]] || return 0
  [[ "${keep_count}" =~ ^[0-9]+$ ]] || cs_die "keep_count 必须是数字"

  python3 - "${parent_dir}" "${keep_count}" <<'PY'
from pathlib import Path
import shutil
import sys

parent = Path(sys.argv[1])
keep = int(sys.argv[2])

dirs = [item for item in parent.iterdir() if item.is_dir() and not item.is_symlink()]
dirs.sort(key=lambda item: item.name, reverse=True)

for item in dirs[keep:]:
    shutil.rmtree(item)
PY
}

cs_source_config() {
  local config_file="$1"
  local label="${2:-配置文件}"
  cs_require_file "${config_file}" "${label}"

  # shellcheck disable=SC1090
  source "${config_file}"
}

cs_render_file_with_vars() {
  local template_file="$1"
  local target_file="$2"
  shift 2

  [[ -f "${template_file}" ]] || cs_die "模板文件不存在: ${template_file}"

  python3 - "$template_file" "$target_file" "$@" <<'PY'
from pathlib import Path
import sys

template_path = Path(sys.argv[1])
target_path = Path(sys.argv[2])
replacements = {}

for item in sys.argv[3:]:
    key, value = item.split("=", 1)
    replacements[f"{{{{{key}}}}}"] = value

content = template_path.read_text()
for key, value in replacements.items():
    content = content.replace(key, value)

target_path.parent.mkdir(parents=True, exist_ok=True)
target_path.write_text(content)
PY
}

cs_acquire_lock() {
  local lock_file="$1"
  local description="${2:-当前操作}"

  cs_require_command flock
  mkdir -p "$(dirname "${lock_file}")"

  # Keep the file descriptor open for the lifetime of the script so the lock
  # is released automatically on exit.
  exec 9>"${lock_file}"
  if ! flock -n 9; then
    cs_die "${description}正在执行中，请稍后再试: ${lock_file}"
  fi
}

cs_each_list_item() {
  local callback="$1"
  local items="$2"
  shift 2 || true

  local -a _cs_items=()
  local item
  local old_ifs="${IFS}"
  IFS=' '
  read -r -a _cs_items <<<"${items}"
  IFS="${old_ifs}"

  for item in "${_cs_items[@]}"; do
    [[ -n "${item}" ]] || continue
    "${callback}" "${item}" "$@"
  done
}

cs_supervisor_reread_update() {
  cs_require_command supervisorctl
  supervisorctl reread
  supervisorctl update
}

cs_restart_supervisor_programs() {
  local programs="$1"
  local assert_running="${2:-true}"
  local program

  _cs_restart_one_supervisor_program() {
    local program_name="$1"
    local should_assert="$2"
    supervisorctl restart "${program_name}"
    if cs_bool_is_true "${should_assert}"; then
      cs_assert_supervisor_running "${program_name}"
    fi
  }

  cs_each_list_item _cs_restart_one_supervisor_program "${programs}" "${assert_running}"
}

cs_run_json_healthcheck() {
  local healthcheck_url="$1"
  local expected_status="${2:-up}"
  local response_json
  local health_status

  cs_require_command curl
  response_json="$(curl --fail --silent --show-error "${healthcheck_url}")"

  if cs_command_exists jq; then
    printf '%s\n' "${response_json}" | jq .
  fi

  health_status="$(
    RESPONSE_JSON="${response_json}" python3 -c '
import json
import os

payload = json.loads(os.environ.get("RESPONSE_JSON", "{}") or "{}")
print(payload.get("data", {}).get("status", "unknown"))
'
  )"

  [[ "${health_status}" == "${expected_status}" ]] || cs_die "健康检查未通过，期望状态=${expected_status}，当前状态=${health_status}"
}

cs_check_http_endpoint() {
  local url="$1"
  local expected_statuses="${2:-200}"
  local contains_text="${3:-}"
  local body_file
  local headers_file
  local http_code
  local expected_regex

  cs_require_command curl

  body_file="$(mktemp)"
  headers_file="$(mktemp)"
  trap 'rm -f "${body_file:-}" "${headers_file:-}"' RETURN

  http_code="$(
    curl \
      --silent \
      --show-error \
      --location \
      --max-redirs 5 \
      --dump-header "${headers_file}" \
      --output "${body_file}" \
      --write-out '%{http_code}' \
      "${url}"
  )"

  expected_regex="$(printf '%s' "${expected_statuses}" | tr ',' ' ' | xargs printf '%s|' | sed 's/|$//')"
  if [[ ! "${http_code}" =~ ^(${expected_regex})$ ]]; then
    cs_log "ERROR" "HTTP 检查失败: ${url}"
    cs_log "ERROR" "期望状态码: ${expected_statuses}，实际状态码: ${http_code}"
    cs_log "ERROR" "响应头:"
    sed -n '1,40p' "${headers_file}" >&2 || true
    cs_log "ERROR" "响应体预览:"
    sed -n '1,80p' "${body_file}" >&2 || true
    return 1
  fi

  if [[ -n "${contains_text}" ]] && ! grep -Fq "${contains_text}" "${body_file}"; then
    cs_log "ERROR" "HTTP 检查失败: ${url}"
    cs_log "ERROR" "响应体未包含预期文本: ${contains_text}"
    cs_log "ERROR" "响应体预览:"
    sed -n '1,80p' "${body_file}" >&2 || true
    return 1
  fi

  cs_log "INFO" "HTTP 检查通过: ${url} [${http_code}]"
}

cs_assert_supervisor_running() {
  local program="$1"
  local status_output

  status_output="$(supervisorctl status "${program}")" \
    || cs_die "无法获取 Supervisor 进程状态: ${program}"

  python3 -c '
import sys

program = sys.argv[1]
lines = [line.strip() for line in sys.stdin.read().splitlines() if line.strip()]
if not lines:
    print(f"未找到 Supervisor 进程: {program}", file=sys.stderr)
    raise SystemExit(1)

invalid = [line for line in lines if " RUNNING " not in f" {line} "]
if invalid:
    print(f"Supervisor 进程未全部运行: {program}", file=sys.stderr)
    for line in invalid:
        print(line, file=sys.stderr)
    raise SystemExit(1)
' "${program}" <<<"${status_output}"
}
