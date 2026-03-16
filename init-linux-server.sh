#!/usr/bin/env bash
set -u

SCRIPT_NAME=$(basename "$0")
SCRIPT_PATH=$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")
[[ "$SCRIPT_PATH" == /* ]] || SCRIPT_PATH="$(pwd)/${SCRIPT_PATH}"
STATE_DIR="/var/lib/server-init"
LOG_FILE="${STATE_DIR}/worker.log"
REPORT_FILE="${STATE_DIR}/report.log"
SUMMARY_FILE="${STATE_DIR}/summary.txt"
CONFIG_FILE="${STATE_DIR}/config.env"
DONE_FILE="${STATE_DIR}/done"
CONFIRM_FILE="${STATE_DIR}/confirm"
PHASE_FILE="${STATE_DIR}/phase"
PID_FILE="${STATE_DIR}/worker.pid"
HELPER_PATH="/usr/local/sbin/server-init-confirm"
MODE="launcher"
WORKER_DIR=""
DRY_RUN=0

TOTAL_STEPS=0
SUCCESS_STEPS=0
FAILED_STEPS=0
STEP_REPORT=""
LAST_ERROR_MSG=""
OS_ID=""
PKG_MGR=""
FIREWALL_TOOL=""
SSH_SERVICE="ssh"

red() { printf '\033[31m%s\033[0m\n' "$*" >&2; }
green() { printf '\033[32m%s\033[0m\n' "$*" >&2; }
yellow() { printf '\033[33m%s\033[0m\n' "$*" >&2; }
blue() { printf '\033[34m%s\033[0m\n' "$*" >&2; }
log() { printf '[INFO] %s\n' "$*" >&2; }
warn() { yellow "[WARN] $*"; }
die() { red "[ERROR] $*"; exit 1; }

usage() {
  cat <<USAGE
用法:
  sudo bash ${SCRIPT_NAME}
  sudo bash ${SCRIPT_NAME} --dry-run
  sudo bash ${SCRIPT_NAME} --worker ${STATE_DIR}
  sudo server-init-confirm

流程:
  1. 前台先执行基础初始化。
  2. 到 SSH/防火墙危险阶段前，明确提示并要求确认。
  3. 确认后切到后台继续执行；即使当前 SSH 断开，也会继续跑。
  4. 你需要用“新用户 + 新 SSH 端口”重新登录，再执行:
       sudo server-init-confirm
  5. confirm 后显示最终结果摘要，并清理脚本残留。
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --worker)
      MODE="worker"
      shift
      [[ $# -ge 1 ]] || die "--worker 需要状态目录。"
      WORKER_DIR="$1"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "未知参数: $1"
      ;;
  esac
done

require_root() {
  [[ "$EUID" -eq 0 ]] || die "请使用 root 执行。"
}

confirm_yes_no() {
  local prompt="$1"
  local default="${2:-N}"
  local ans=""
  while true; do
    if [[ "$default" =~ ^[Yy]$ ]]; then
      read -r -p "$prompt [Y/n]: " ans
      ans="${ans:-Y}"
    else
      read -r -p "$prompt [y/N]: " ans
      ans="${ans:-N}"
    fi
    case "$ans" in
      Y|y) return 0 ;;
      N|n) return 1 ;;
      *) warn "请输入 y 或 n。" ;;
    esac
  done
}

prompt_nonempty() {
  local prompt="$1"
  local value=""
  while true; do
    read -r -p "$prompt" value
    [[ -n "$value" ]] && { printf '%s' "$value"; return 0; }
    warn "输入不能为空。"
  done
}

append_report() {
  local status="$1"
  local label="$2"
  local detail="${3:-}"
  STEP_REPORT+="${status} ${label}"
  [[ -n "$detail" ]] && STEP_REPORT+=" -- ${detail}"
  STEP_REPORT+=$'\n'
}

run_step() {
  local label="$1"
  shift
  TOTAL_STEPS=$((TOTAL_STEPS + 1))
  blue "[STEP ${TOTAL_STEPS}] ${label}"
  LAST_ERROR_MSG=""
  if "$@"; then
    SUCCESS_STEPS=$((SUCCESS_STEPS + 1))
    append_report "[OK]" "$label"
    return 0
  fi
  FAILED_STEPS=$((FAILED_STEPS + 1))
  append_report "[FAIL]" "$label" "${LAST_ERROR_MSG:-执行失败}"
  warn "步骤失败，但继续执行: ${label}${LAST_ERROR_MSG:+ -- ${LAST_ERROR_MSG}}"
  return 1
}

load_report_from_file() {
  local file="$1"
  [[ -f "$file" ]] && STEP_REPORT=$(cat "$file") || STEP_REPORT=""
}

save_report_to_file() {
  local file="$1"
  printf '%s' "$STEP_REPORT" > "$file"
}

run_cmd() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '[DRY-RUN] %s\n' "$*"
    return 0
  fi
  bash -lc "$*"
}

load_os_release() {
  [[ -r /etc/os-release ]] || die "无法读取 /etc/os-release。"
  # shellcheck disable=SC1091
  source /etc/os-release
  OS_ID="${ID:-}"
  if command -v apt-get >/dev/null 2>&1; then
    PKG_MGR="apt"
    FIREWALL_TOOL="ufw"
    SSH_SERVICE="ssh"
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MGR="dnf"
    FIREWALL_TOOL="firewalld"
    SSH_SERVICE="sshd"
  elif command -v yum >/dev/null 2>&1; then
    PKG_MGR="yum"
    FIREWALL_TOOL="firewalld"
    SSH_SERVICE="sshd"
  else
    die "未识别到支持的包管理器（apt/dnf/yum）。"
  fi
}

_PKG_UPDATED=0

pkg_update_once() {
  [[ "$_PKG_UPDATED" -eq 1 ]] && return 0
  case "$PKG_MGR" in
    apt) run_cmd "apt-get update" ;;
    dnf) run_cmd "dnf makecache" ;;
    yum) run_cmd "yum makecache" ;;
    *) LAST_ERROR_MSG="不支持的包管理器"; return 1 ;;
  esac
  _PKG_UPDATED=1
}

install_pkg() {
  local pkgs=("$@")
  case "$PKG_MGR" in
    apt) DEBIAN_FRONTEND=noninteractive run_cmd "apt-get install -y ${pkgs[*]}" ;;
    dnf) run_cmd "dnf install -y ${pkgs[*]}" ;;
    yum) run_cmd "yum install -y ${pkgs[*]}" ;;
    *) LAST_ERROR_MSG="不支持的包管理器"; return 1 ;;
  esac
}

ensure_basic_tools() {
  local wanted=(curl ca-certificates openssh-server tzdata)
  pkg_update_once || return 1
  install_pkg "${wanted[@]}"
}

ensure_sudo() {
  if command -v sudo >/dev/null 2>&1; then
    log "sudo 已安装。"
    return 0
  fi
  pkg_update_once || return 1
  install_pkg sudo
}

validate_username() {
  local u="$1"
  [[ "$u" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]] || return 1
  [[ "$u" != "root" ]] || return 1
}

user_exists() { id "$1" >/dev/null 2>&1; }

create_or_update_user() {
  local username="$1"
  if user_exists "$username"; then
    log "用户 ${username} 已存在，跳过创建。"
    return 0
  fi
  run_cmd "useradd -m -s /bin/bash ${username}"
}

add_user_to_admin_group() {
  local username="$1"
  local group="sudo"
  getent group sudo >/dev/null 2>&1 || group="wheel"
  getent group "$group" >/dev/null 2>&1 || { LAST_ERROR_MSG="未找到 sudo/wheel 组"; return 1; }
  run_cmd "usermod -aG ${group} ${username}"
}

set_user_password() {
  local username="$1"
  local password="$2"
  [[ -n "$password" ]] || { LAST_ERROR_MSG="密码为空"; return 1; }
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "[DRY-RUN] 将为 ${username} 设置密码。"
    return 0
  fi
  printf '%s:%s\n' "$username" "$password" | chpasswd
}

ensure_user_ssh_dir() {
  local username="$1"
  local home_dir
  home_dir=$(getent passwd "$username" | cut -d: -f6)
  [[ -n "$home_dir" ]] || { LAST_ERROR_MSG="无法获取用户家目录"; return 1; }
  run_cmd "install -d -m 700 -o ${username} -g ${username} ${home_dir}/.ssh"
}

add_user_ssh_key() {
  local username="$1"
  local pubkey="$2"
  local home_dir auth_file
  home_dir=$(getent passwd "$username" | cut -d: -f6)
  [[ -n "$home_dir" ]] || { LAST_ERROR_MSG="无法获取用户家目录"; return 1; }
  auth_file="${home_dir}/.ssh/authorized_keys"
  ensure_user_ssh_dir "$username" || return 1
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "[DRY-RUN] 将为 ${username} 添加 SSH 公钥。"
    return 0
  fi
  touch "$auth_file"
  chmod 600 "$auth_file"
  chown "$username:$username" "$auth_file"
  grep -Fqx "$pubkey" "$auth_file" 2>/dev/null || printf '%s\n' "$pubkey" >> "$auth_file"
  chown "$username:$username" "$auth_file"
}

update_hostname_and_hosts() {
  local new_hostname="$1"
  local old_hostname
  old_hostname=$(hostnamectl --static 2>/dev/null || hostname 2>/dev/null || true)
  run_cmd "hostnamectl set-hostname ${new_hostname}" || return 1
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "[DRY-RUN] 将更新 /etc/hosts。"
    return 0
  fi
  cp -a /etc/hosts /etc/hosts.server-init.bak.$(date +%s) || true
  if grep -Eq '^127\.0\.1\.1\s+' /etc/hosts; then
    sed -i -E "s/^127\.0\.1\.1\s+.*/127.0.1.1 ${new_hostname}/" /etc/hosts
  else
    printf '127.0.1.1 %s\n' "$new_hostname" >> /etc/hosts
  fi
  if [[ -n "$old_hostname" && "$old_hostname" != "$new_hostname" ]]; then
    local escaped_old
    escaped_old=$(printf '%s' "$old_hostname" | sed 's/[.[\*^$]/\\&/g')
    sed -i "s/\b${escaped_old}\b/${new_hostname}/g" /etc/hosts || true
  fi
}

set_timezone_value() {
  local tz="$1"
  run_cmd "timedatectl set-timezone '${tz}'"
}

ensure_swap() {
  local size_mb="$1"
  [[ "$size_mb" =~ ^[0-9]+$ ]] || { LAST_ERROR_MSG="swap 大小必须为数字(MB)"; return 1; }
  [[ "$size_mb" -gt 0 ]] || { LAST_ERROR_MSG="swap 大小必须大于 0"; return 1; }
  if swapon --show | grep -q '^/swapfile'; then
    log "/swapfile 已存在并启用，跳过。"
    return 0
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "[DRY-RUN] 将创建 ${size_mb}MB 的 /swapfile。"
    return 0
  fi
  if command -v fallocate >/dev/null 2>&1; then
    fallocate -l "${size_mb}M" /swapfile || return 1
  else
    dd if=/dev/zero of=/swapfile bs=1M count="$size_mb" status=progress || return 1
  fi
  chmod 600 /swapfile || return 1
  mkswap /swapfile >/dev/null || return 1
  swapon /swapfile || return 1
  grep -q '^/swapfile ' /etc/fstab 2>/dev/null || echo '/swapfile none swap sw 0 0' >> /etc/fstab
}

install_docker_engine() {
  if command -v docker >/dev/null 2>&1; then
    log "Docker 已安装，跳过。"
    return 0
  fi
  case "$PKG_MGR" in
    apt)
      pkg_update_once || return 1
      install_pkg docker.io || return 1
      run_cmd "systemctl enable --now docker" || return 1
      ;;
    dnf|yum)
      pkg_update_once || return 1
      install_pkg docker || install_pkg docker-ce || return 1
      run_cmd "systemctl enable --now docker"
      ;;
    *)
      LAST_ERROR_MSG="不支持的包管理器"
      return 1
      ;;
  esac
}

current_sshd_value() {
  local key="$1"
  local default="${2:-}"
  if command -v sshd >/dev/null 2>&1; then
    sshd -T 2>/dev/null | awk -v k="$(echo "$key" | tr '[:upper:]' '[:lower:]')" '$1==k {print $2; exit}' || true
  else
    printf '%s\n' "$default"
  fi
}

ensure_ssh_include() {
  if grep -Eq '^\s*Include\s+/etc/ssh/sshd_config\.d/\*\.conf' /etc/ssh/sshd_config 2>/dev/null; then
    mkdir -p /etc/ssh/sshd_config.d
    return 0
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "[DRY-RUN] 将在 /etc/ssh/sshd_config 中追加 Include。"
    return 0
  fi
  mkdir -p /etc/ssh/sshd_config.d || return 1
  printf '\nInclude /etc/ssh/sshd_config.d/*.conf\n' >> /etc/ssh/sshd_config || return 1
}

write_ssh_override() {
  local port="$1"
  local password_auth="$2"
  local root_login="$3"
  ensure_ssh_include || { LAST_ERROR_MSG="无法准备 sshd_config.d"; return 1; }
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "[DRY-RUN] 将写入 SSH 覆盖配置: Port=${port}, PasswordAuthentication=${password_auth}, PermitRootLogin=${root_login}"
    return 0
  fi
  cat > /etc/ssh/sshd_config.d/99-server-init.conf <<CONF
Port ${port}
PasswordAuthentication ${password_auth}
PubkeyAuthentication yes
PermitRootLogin ${root_login}
CONF
}

validate_sshd_config() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "[DRY-RUN] 将执行 sshd -t 校验配置。"
    return 0
  fi
  command -v sshd >/dev/null 2>&1 || { LAST_ERROR_MSG="未找到 sshd"; return 1; }
  sshd -t || { LAST_ERROR_MSG="sshd 配置校验失败"; return 1; }
}

restart_ssh_service() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "[DRY-RUN] 将重启 ${SSH_SERVICE} 服务。"
    return 0
  fi
  if systemctl list-unit-files | grep -q '^ssh\.service'; then SSH_SERVICE="ssh"
  elif systemctl list-unit-files | grep -q '^sshd\.service'; then SSH_SERVICE="sshd"
  fi
  systemctl restart "$SSH_SERVICE" || { LAST_ERROR_MSG="重启 ${SSH_SERVICE} 失败"; return 1; }
}

open_firewall_ports() {
  local old_port="$1"
  local new_port="$2"
  case "$FIREWALL_TOOL" in
    ufw)
      command -v ufw >/dev/null 2>&1 || { pkg_update_once || return 1; install_pkg ufw || return 1; }
      run_cmd "ufw allow ${old_port}/tcp" || return 1
      run_cmd "ufw allow ${new_port}/tcp" || return 1
      run_cmd "ufw allow 80/tcp" || return 1
      run_cmd "ufw allow 443/tcp" || return 1
      run_cmd "ufw --force enable" || return 1
      ;;
    firewalld)
      command -v firewall-cmd >/dev/null 2>&1 || { pkg_update_once || return 1; install_pkg firewalld || return 1; }
      run_cmd "systemctl enable --now firewalld" || return 1
      run_cmd "firewall-cmd --permanent --add-port=${old_port}/tcp" || return 1
      run_cmd "firewall-cmd --permanent --add-port=${new_port}/tcp" || return 1
      run_cmd "firewall-cmd --permanent --add-service=http" || return 1
      run_cmd "firewall-cmd --permanent --add-service=https" || return 1
      run_cmd "firewall-cmd --reload" || return 1
      ;;
    *)
      LAST_ERROR_MSG="不支持的防火墙类型"
      return 1
      ;;
  esac
}

close_old_firewall_port() {
  local old_port="$1"
  local new_port="$2"
  [[ "$old_port" == "$new_port" ]] && return 0
  case "$FIREWALL_TOOL" in
    ufw)
      run_cmd "printf 'y\n' | ufw delete allow ${old_port}/tcp" || return 1
      ;;
    firewalld)
      run_cmd "firewall-cmd --permanent --remove-port=${old_port}/tcp" || return 1
      run_cmd "firewall-cmd --reload" || return 1
      ;;
  esac
}

rollback_network_and_ssh() {
  local old_port="$1"
  run_step "回退 SSH 端口与 root 密码登录" write_ssh_override "$old_port" yes yes
  run_step "校验回退后的 SSH 配置" validate_sshd_config
  run_step "应用回退后的 SSH 服务" restart_ssh_service
  case "$FIREWALL_TOOL" in
    ufw)
      run_step "回退时禁用 UFW" run_cmd "ufw --force disable"
      ;;
    firewalld)
      run_step "回退时禁用 firewalld" run_cmd "systemctl disable --now firewalld"
      ;;
  esac
}

install_confirm_helper() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "[DRY-RUN] 将安装 ${HELPER_PATH}。"
    return 0
  fi
  cat > "$HELPER_PATH" <<'CONFIRM'
#!/usr/bin/env bash
set -u
STATE_DIR="/var/lib/server-init"
DONE_FILE="${STATE_DIR}/done"
SUMMARY_FILE="${STATE_DIR}/summary.txt"
CONFIRM_FILE="${STATE_DIR}/confirm"
HELPER_PATH="/usr/local/sbin/server-init-confirm"

[[ "$EUID" -eq 0 ]] || { echo "请使用 sudo 执行。"; exit 1; }
[[ -d "$STATE_DIR" ]] || { echo "未找到待确认任务。"; exit 1; }

touch "$CONFIRM_FILE"
echo "已写入 confirm，等待后台任务完成..."

for _ in $(seq 1 180); do
  if [[ -f "$DONE_FILE" ]]; then
    [[ -f "$SUMMARY_FILE" ]] && cat "$SUMMARY_FILE"
    rm -rf "$STATE_DIR"
    (sleep 1; rm -f "$HELPER_PATH") >/dev/null 2>&1 &
    exit 0
  fi
  sleep 1
done

echo "后台任务仍在收尾，稍后可查看: ${SUMMARY_FILE} 或 ${STATE_DIR}/worker.log"
exit 0
CONFIRM
  chmod 755 "$HELPER_PATH"
}

write_config_file() {
  local file="$1"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "[DRY-RUN] 将写入 worker 配置 ${file}。"
    return 0
  fi
  cat > "$file" <<CFG
NEW_USER=$(printf '%q' "$NEW_USER")
NEW_HOSTNAME=$(printf '%q' "$NEW_HOSTNAME")
TIMEZONE_VALUE=$(printf '%q' "$TIMEZONE_VALUE")
TARGET_SSH_PORT=$(printf '%q' "$TARGET_SSH_PORT")
OLD_SSH_PORT=$(printf '%q' "$OLD_SSH_PORT")
DESIRED_PASSWORD_AUTH=$(printf '%q' "$DESIRED_PASSWORD_AUTH")
FIREWALL_TOOL=$(printf '%q' "$FIREWALL_TOOL")
SSH_SERVICE=$(printf '%q' "$SSH_SERVICE")
CONFIRM_TIMEOUT=$(printf '%q' "$CONFIRM_TIMEOUT")
CFG
}

start_background_worker() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "[DRY-RUN] 将启动后台 worker。"
    return 0
  fi
  if command -v systemd-run >/dev/null 2>&1 && command -v systemctl >/dev/null 2>&1; then
    systemd-run --unit server-init-worker --description "server init worker" /bin/bash "$SCRIPT_PATH" --worker "$STATE_DIR" >/dev/null 2>&1 || true
    sleep 1
    if ! systemctl is-active --quiet server-init-worker 2>/dev/null && [[ ! -f "$PID_FILE" ]]; then
      warn "systemd-run 启动 worker 可能失败，尝试 nohup 后台方式。"
      nohup /bin/bash "$SCRIPT_PATH" --worker "$STATE_DIR" >/dev/null 2>&1 < /dev/null &
      disown || true
    fi
  else
    if command -v setsid >/dev/null 2>&1; then
      nohup setsid /bin/bash "$SCRIPT_PATH" --worker "$STATE_DIR" >/dev/null 2>&1 < /dev/null &
    else
      nohup /bin/bash "$SCRIPT_PATH" --worker "$STATE_DIR" >/dev/null 2>&1 < /dev/null &
    fi
    disown || true
  fi
}

write_summary() {
  local outcome="$1"
  local extra="$2"
  {
    echo "================ 最终结果 ================"
    echo "结果: ${outcome}"
    echo "成功步骤: ${SUCCESS_STEPS}"
    echo "失败步骤: ${FAILED_STEPS}"
    echo "-----------------------------------------"
    printf '%s' "$STEP_REPORT"
    if [[ -n "$extra" ]]; then
      echo "-----------------------------------------"
      echo "$extra"
    fi
  } > "$SUMMARY_FILE"
  touch "$DONE_FILE"
}

wait_for_confirm() {
  local timeout="$1"
  local elapsed=0
  echo "waiting_confirm" > "$PHASE_FILE"
  log "已进入确认等待阶段，最多等待 ${timeout} 秒。"
  while (( elapsed < timeout )); do
    [[ -f "$CONFIRM_FILE" ]] && return 0
    sleep 2
    elapsed=$((elapsed + 2))
  done
  return 1
}

worker_main() {
  require_root
  STATE_DIR="$WORKER_DIR"
  LOG_FILE="${STATE_DIR}/worker.log"
  REPORT_FILE="${STATE_DIR}/report.log"
  SUMMARY_FILE="${STATE_DIR}/summary.txt"
  CONFIG_FILE="${STATE_DIR}/config.env"
  DONE_FILE="${STATE_DIR}/done"
  CONFIRM_FILE="${STATE_DIR}/confirm"
  PHASE_FILE="${STATE_DIR}/phase"
  PID_FILE="${STATE_DIR}/worker.pid"

  mkdir -p "$STATE_DIR"
  exec >> "$LOG_FILE" 2>&1
  echo "[$(date '+%F %T')] worker started"
  echo $$ > "$PID_FILE"

  [[ -f "$CONFIG_FILE" ]] || die "缺少配置文件: ${CONFIG_FILE}"
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"

  load_os_release
  load_report_from_file "$REPORT_FILE"

  echo "switching_ssh" > "$PHASE_FILE"
  run_step "放行旧/新 SSH 端口与 Web 端口并启用防火墙" open_firewall_ports "$OLD_SSH_PORT" "$TARGET_SSH_PORT"
  run_step "写入过渡 SSH 配置（新端口，临时允许 root 密码登录）" write_ssh_override "$TARGET_SSH_PORT" yes yes
  run_step "校验过渡 SSH 配置" validate_sshd_config
  run_step "应用过渡 SSH 配置" restart_ssh_service

  cat <<MSG
====================================================
危险阶段已执行完成。
如果你当前 SSH 断开，这是正常现象之一。
请使用“新用户 + 新 SSH 端口 ${TARGET_SSH_PORT}”重新登录。
登录成功后执行：
  sudo server-init-confirm
若 ${CONFIRM_TIMEOUT} 秒内没有 confirm，将执行简化回退：
  1) SSH 端口改回 ${OLD_SSH_PORT}
  2) 允许 root 密码登录
  3) Ubuntu/Debian 上直接 ufw disable
====================================================
MSG

  if wait_for_confirm "$CONFIRM_TIMEOUT"; then
    echo "finalizing" > "$PHASE_FILE"
    run_step "写入最终 SSH 配置（新端口，按你的设置保留/关闭密码登录，root 禁止密码登录）" write_ssh_override "$TARGET_SSH_PORT" "$DESIRED_PASSWORD_AUTH" prohibit-password
    run_step "校验最终 SSH 配置" validate_sshd_config
    run_step "应用最终 SSH 配置" restart_ssh_service
    run_step "移除旧 SSH 端口防火墙规则" close_old_firewall_port "$OLD_SSH_PORT" "$TARGET_SSH_PORT"
    save_report_to_file "$REPORT_FILE"
    write_summary "成功" "已收到 confirm。后台任务已完成；确认脚本会负责清理残留。"
  else
    echo "rollback" > "$PHASE_FILE"
    rollback_network_and_ssh "$OLD_SSH_PORT"
    save_report_to_file "$REPORT_FILE"
    write_summary "已回退" "在 ${CONFIRM_TIMEOUT} 秒内未收到 confirm，已执行回退：SSH 端口恢复、允许 root 密码登录；UFW/firewalld 已按回退逻辑处理。"
  fi
}

launcher_main() {
  require_root
  load_os_release

  if [[ -d "$STATE_DIR" ]]; then
    die "检测到残留状态目录 ${STATE_DIR}。请先确认是否已有任务在跑，或手动删除后再试。"
  fi

  CURRENT_HOSTNAME=$(hostnamectl --static 2>/dev/null || hostname)
  CURRENT_TIMEZONE=$(timedatectl show --property=Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo UTC)
  OLD_SSH_PORT=$(current_sshd_value Port 22)
  CURRENT_PASSWORD_AUTH=$(current_sshd_value PasswordAuthentication yes)

  while true; do
    NEW_USER=$(prompt_nonempty "请输入要创建/配置的普通用户名: ")
    validate_username "$NEW_USER" && break
    warn "用户名不合法，请重试。"
  done

  USER_PASSWORD=""
  USER_PUBKEY=""
  while true; do
    if confirm_yes_no "是否为 ${NEW_USER} 设置密码？" "Y"; then
      while true; do
        read -r -s -p "请输入 ${NEW_USER} 的密码: " p1; echo
        read -r -s -p "请再次输入密码: " p2; echo
        [[ "$p1" == "$p2" ]] || { warn "两次密码不一致，请重试。"; continue; }
        [[ -n "$p1" ]] || { warn "密码不能为空。"; continue; }
        USER_PASSWORD="$p1"
        break
      done
    fi

    if confirm_yes_no "是否为 ${NEW_USER} 添加 SSH 公钥？" "Y"; then
      USER_PUBKEY=$(prompt_nonempty "请输入完整 SSH 公钥: ")
    fi

    if [[ -n "$USER_PASSWORD" || -n "$USER_PUBKEY" ]]; then
      break
    fi
    warn "密码和公钥至少要配置一个。请重新选择。"
  done

  read -r -p "请输入新的主机名 [默认 ${CURRENT_HOSTNAME}]: " NEW_HOSTNAME
  NEW_HOSTNAME="${NEW_HOSTNAME:-$CURRENT_HOSTNAME}"

  read -r -p "请输入时区 [默认 ${CURRENT_TIMEZONE}]: " TIMEZONE_VALUE
  TIMEZONE_VALUE="${TIMEZONE_VALUE:-$CURRENT_TIMEZONE}"

  while true; do
    read -r -p "请输入新的 SSH 端口 [默认 ${OLD_SSH_PORT}]: " TARGET_SSH_PORT
    TARGET_SSH_PORT="${TARGET_SSH_PORT:-$OLD_SSH_PORT}"
    if [[ "$TARGET_SSH_PORT" =~ ^[0-9]+$ ]] && (( TARGET_SSH_PORT >= 1 && TARGET_SSH_PORT <= 65535 )); then
      break
    fi
    warn "SSH 端口必须是 1-65535 之间的整数。"
  done

  if confirm_yes_no "普通用户是否继续允许 SSH 密码登录？" "$([[ "$CURRENT_PASSWORD_AUTH" == yes ]] && echo Y || echo N)"; then
    DESIRED_PASSWORD_AUTH="yes"
  else
    DESIRED_PASSWORD_AUTH="no"
  fi

  if confirm_yes_no "是否配置 swap？" "N"; then
    while true; do
      read -r -p "请输入 swap 大小（MB）: " SWAP_SIZE_MB
      if [[ "$SWAP_SIZE_MB" =~ ^[0-9]+$ ]] && (( SWAP_SIZE_MB > 0 )); then
        break
      fi
      warn "swap 大小必须是大于 0 的整数（MB）。"
    done
  else
    SWAP_SIZE_MB=""
  fi

  if confirm_yes_no "是否安装 Docker？" "N"; then
    INSTALL_DOCKER="yes"
  else
    INSTALL_DOCKER="no"
  fi

  CONFIRM_TIMEOUT=600

  echo
  blue "即将执行基础初始化步骤："
  cat <<PLAN
  - 检查并安装 sudo / 基础组件
  - 创建或配置普通用户并加入管理员组
  - 设置密码 / 公钥
  - 修改主机名和 hosts
  - 修改时区
  - ${SWAP_SIZE_MB:+配置 ${SWAP_SIZE_MB}MB swap}${SWAP_SIZE_MB:-未配置 swap}
  - $( [[ "$INSTALL_DOCKER" == yes ]] && echo 安装\ Docker || echo 不安装\ Docker )
PLAN
  echo
  confirm_yes_no "确认开始执行基础初始化？" "Y" || die "已取消。"

  run_step "安装基础组件" ensure_basic_tools
  run_step "安装 sudo（如果缺失）" ensure_sudo
  run_step "创建/确认普通用户" create_or_update_user "$NEW_USER"
  run_step "授予普通用户管理员权限" add_user_to_admin_group "$NEW_USER"
  [[ -n "$USER_PASSWORD" ]] && run_step "设置普通用户密码" set_user_password "$NEW_USER" "$USER_PASSWORD"
  [[ -n "$USER_PUBKEY" ]] && run_step "配置普通用户 SSH 公钥" add_user_ssh_key "$NEW_USER" "$USER_PUBKEY"
  run_step "修改主机名并更新 hosts" update_hostname_and_hosts "$NEW_HOSTNAME"
  run_step "修改时区" set_timezone_value "$TIMEZONE_VALUE"
  [[ -n "$SWAP_SIZE_MB" ]] && run_step "配置 swap" ensure_swap "$SWAP_SIZE_MB"
  [[ "$INSTALL_DOCKER" == yes ]] && run_step "安装 Docker" install_docker_engine

  echo
  blue "基础初始化已完成。当前汇总：成功 ${SUCCESS_STEPS} 步，失败 ${FAILED_STEPS} 步。"
  printf '%s\n' "$STEP_REPORT"

  cat <<WARNBLOCK
====================================================
下面要进入 SSH / 防火墙危险阶段：
  1) 启用防火墙并放行旧 SSH 端口 ${OLD_SSH_PORT}、新 SSH 端口 ${TARGET_SSH_PORT}、80、443
  2) 把 SSH 切到新端口 ${TARGET_SSH_PORT}
  3) 这一段即使当前 SSH 断开，后台任务也会继续执行
  4) 你需要用“新用户 + 新 SSH 端口”重新登录，然后执行：
       sudo server-init-confirm
  5) 如果 ${CONFIRM_TIMEOUT} 秒内没有 confirm，将执行简化回退：
       - SSH 端口改回 ${OLD_SSH_PORT}
       - 允许 root 密码登录
       - UFW 直接 disable（firewalld 则直接停用）
====================================================
WARNBLOCK

  confirm_yes_no "确认进入 SSH / 防火墙危险阶段？" "N" || {
    blue "你选择了不进入危险阶段。本次脚本在基础初始化完成后结束。"
    exit 0
  }

  if [[ "$DRY_RUN" -eq 0 ]]; then
    mkdir -p "$STATE_DIR"
    save_report_to_file "$REPORT_FILE"
  fi
  write_config_file "$CONFIG_FILE"
  install_confirm_helper
  start_background_worker

  cat <<NEXT

后台任务已启动。
从现在开始，即使当前 SSH 会话断开，脚本也会继续执行。

请做这两件事：
1. 不要急着关闭当前终端；先新开一个终端窗口
2. 使用新用户 ${NEW_USER} 和 SSH 端口 ${TARGET_SSH_PORT} 登录
3. 登录成功后执行：
     sudo server-init-confirm

后台日志位置：
  ${LOG_FILE}

如果 10 分钟内没有 confirm，脚本会自动执行简化回退。
NEXT
}

require_root
if [[ "$MODE" == "worker" ]]; then
  worker_main
else
  launcher_main
fi
