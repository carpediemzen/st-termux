#!/usr/bin/env bash
# st-termux: Termux 一键安装与维护 SillyTavern（酒馆）的辅助脚本
# 支持交互式菜单与非交互命令行参数双模式

set -euo pipefail

readonly SCRIPT_VERSION="1.1.0"
readonly ST_REPO_HTTPS="https://github.com/SillyTavern/SillyTavern.git"
readonly ST_MIN_NODE_MAJOR=20
readonly SELF_REPO_RAW="carpediemzen/st-termux/main/install.sh"
readonly RC_BLOCK_START="# >>> st-termux >>>"
readonly RC_BLOCK_END="# <<< st-termux <<<"
readonly AUTOSTART_BLOCK_START="# >>> st-termux-autostart >>>"
readonly AUTOSTART_BLOCK_END="# <<< st-termux-autostart <<<"

# 默认运行参数（可通过环境变量或 CLI 参数覆盖）
ST_DIR="${ST_DIR:-$HOME/SillyTavern}"
ST_BRANCH="${ST_BRANCH:-release}"
ST_NETWORK_MODE="${ST_NETWORK_MODE:-auto}" # auto | cn | official
ST_GITHUB_BASE="${ST_GITHUB_BASE:-}"
ST_NPM_REGISTRY="${ST_NPM_REGISTRY:-}"
ST_ACTION=""
ST_YES=0
ST_APPLY_PERF=""       # ""=按交互/默认处理, "1"=启用, "0"=跳过
ST_APPLY_ALIAS=""      # ""=按交互/默认处理, "1"=启用, "0"=跳过
ST_APPLY_AUTOSTART=""  # ""=按交互/默认处理, "1"=开启, "0"=关闭
ST_START_AFTER=0

# 测速结果全局状态
SELECTED_GH_BASE=""
SELECTED_NPM_REG=""
declare -a RANKED_GH_BASES=()
declare -a RANKED_NPM_REGS=()
declare -a TMP_FILES=()

# ---------------------------------------------------------------------------
# 通用日志、TTY 交互与清理
# ---------------------------------------------------------------------------

if [[ -t 1 ]] && [[ "${TERM:-dumb}" != "dumb" ]]; then
  readonly C_RESET=$'\033[0m'
  readonly C_BOLD=$'\033[1m'
  readonly C_RED=$'\033[31m'
  readonly C_GREEN=$'\033[32m'
  readonly C_YELLOW=$'\033[33m'
  readonly C_BLUE=$'\033[34m'
  readonly C_CYAN=$'\033[36m'
else
  readonly C_RESET=""
  readonly C_BOLD=""
  readonly C_RED=""
  readonly C_GREEN=""
  readonly C_YELLOW=""
  readonly C_BLUE=""
  readonly C_CYAN=""
fi

cleanup_tmp() {
  local f
  for f in "${TMP_FILES[@]:-}"; do
    if [[ -n "$f" && -e "$f" ]]; then
      rm -rf "$f" || true
    fi
  done
}
trap cleanup_tmp EXIT

make_temp_file() {
  local tmp
  tmp=$(mktemp)
  TMP_FILES+=("$tmp")
  printf '%s\n' "$tmp"
}

log_info() { printf '%s[信息]%s %s\n' "$C_CYAN" "$C_RESET" "$*"; }
log_ok() { printf '%s[完成]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
log_warn() { printf '%s[警告]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
log_err() { printf '%s[错误]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }

die() {
  log_err "$*"
  exit 1
}

# 支持从标准输入或 /dev/tty 读取交互输入，确保 curl | bash 场景也能正常交互
has_tty_input() {
  [[ -t 0 ]] || { [[ -r /dev/tty ]] && : < /dev/tty; } 2>/dev/null
}

tty_read() {
  local prompt="$1"
  local var_name="$2"
  local default_val="${3:-}"
  local input=""

  if [[ -t 0 ]]; then
    read -r -p "$prompt" input || input=""
  elif [[ -r /dev/tty ]]; then
    printf '%s' "$prompt" > /dev/tty
    read -r input < /dev/tty || input=""
  else
    input="$default_val"
  fi

  if [[ -z "$input" && -n "$default_val" ]]; then
    input="$default_val"
  fi
  printf -v "$var_name" '%s' "$input"
}

confirm_action() {
  local prompt="$1"
  local default_ans="${2:-Y}" # Y 或 N
  local reply=""

  if [[ "$ST_YES" -eq 1 ]]; then
    return 0
  fi

  if ! has_tty_input; then
    [[ "${default_ans^^}" == "Y" ]]
    return $?
  fi

  local hint="[Y/n]"
  [[ "${default_ans^^}" == "N" ]] && hint="[y/N]"

  tty_read "${prompt} ${hint}: " reply "$default_ans"
  case "${reply^^}" in
    Y|YES) return 0 ;;
    N|NO) return 1 ;;
    *) [[ "${default_ans^^}" == "Y" ]] ;;
  esac
}

# ---------------------------------------------------------------------------
# 环境检查
# ---------------------------------------------------------------------------

termux_prefix() {
  printf '%s\n' "${PREFIX:-/data/data/com.termux/files/usr}"
}

detect_arch() {
  local machine
  machine=$(uname -m 2>/dev/null || echo "unknown")
  case "$machine" in
    armv7l|armv8l|arm) printf 'arm\n' ;;
    aarch64|arm64) printf 'aarch64\n' ;;
    x86_64|amd64) printf 'x86_64\n' ;;
    i686|i386) printf 'i686\n' ;;
    *) printf '%s\n' "$machine" ;;
  esac
}

assert_termux_env() {
  # Termux 的 pkg 明确禁止在 uid=0 (root/tsu) 下执行
  if [[ "$(id -u)" -eq 0 ]]; then
    die "检测到当前为 root 用户 (uid=0)。Termux 的 pkg 禁止在 root 下运行，请先退出 root (输入 exit) 后重试。"
  fi

  local prefix
  prefix=$(termux_prefix)

  if ! command -v pkg >/dev/null 2>&1; then
    die "未找到 Termux 包管理器 'pkg'，本脚本仅适用于 Android Termux 环境。"
  fi

  if [[ ! -d "$prefix" ]]; then
    die "未找到 Termux PREFIX 目录 ($prefix)，请确认当前处于 Termux 环境中。"
  fi
}

get_node_major() {
  if ! command -v node >/dev/null 2>&1; then
    printf '0\n'
    return 0
  fi
  local ver
  ver=$(node -v 2>/dev/null || echo "v0")
  ver="${ver#v}"
  printf '%s\n' "${ver%%.*}"
}

is_st_directory() {
  local dir="$1"
  [[ -d "$dir/.git" && -f "$dir/server.js" && -f "$dir/package.json" ]]
}

# ---------------------------------------------------------------------------
# 包管理与 Termux 镜像源测速
# ---------------------------------------------------------------------------

run_pkg_upgrade() {
  local -a dpkg_opts=(
    -o "Dpkg::Options::=--force-confdef"
    -o "Dpkg::Options::=--force-confold"
  )
  log_info "正在同步软件包索引..."
  pkg update || die "pkg update 失败，请检查网络连接或执行 termux-change-repo 更换镜像源。"
  log_info "正在非交互升级已有软件包（保留已有配置）..."
  pkg upgrade -y "${dpkg_opts[@]}" || log_warn "部分软件包升级未成功，继续安装核心依赖..."
}

ensure_curl_installed() {
  if command -v curl >/dev/null 2>&1; then
    return 0
  fi
  log_info "未检测到 curl，正在先安装 curl 以便进行网络测速..."
  if ! { pkg update && pkg install -y curl; }; then
    die "安装 curl 失败，请先确认 Termux 软件源可用。"
  fi
}

# 解析 Termux 镜像文件中的 MAIN URL
read_mirror_main_url() {
  local mirror_file="$1"
  local main_url=""
  main_url=$(grep -m1 -E '^[[:space:]]*MAIN=' "$mirror_file" 2>/dev/null | sed -E 's/^[^=]+=["'\'']?([^"'\''[:space:]]+)["'\'']?/\1/' || true)
  printf '%s\n' "${main_url%/}"
}

get_current_termux_uri() {
  local prefix
  prefix=$(termux_prefix)
  local main_sources="$prefix/etc/apt/sources.list.d/main.sources"
  local legacy_list="$prefix/etc/apt/sources.list"

  if [[ -f "$main_sources" ]]; then
    grep -m1 -E '^[[:space:]]*URIs:' "$main_sources" 2>/dev/null | grep -oE 'https?://[^[:space:]]+' || true
  elif [[ -f "$legacy_list" ]]; then
    grep -m1 -E '^[[:space:]]*deb[[:space:]]+' "$legacy_list" 2>/dev/null | grep -oE 'https?://[^[:space:]]+' || true
  fi
}

is_official_termux_uri() {
  local uri="$1"
  [[ -z "$uri" || "$uri" == *"packages.termux.dev"* || "$uri" == *"packages-cf.termux.dev"* || "$uri" == *"termux.org"* ]]
}

setup_termux_mirror() {
  if [[ "$ST_NETWORK_MODE" == "official" ]]; then
    log_info "网络策略为官方源，跳过 Termux 国内源切换。"
    return 0
  fi

  local prefix
  prefix=$(termux_prefix)
  local cn_dir="$prefix/etc/termux/mirrors/chinese_mainland"
  local chosen_link="$prefix/etc/termux/chosen_mirrors"
  local current_uri
  current_uri=$(get_current_termux_uri)

  log_info "当前 Termux APT 源: ${current_uri:-未知}"

  if [[ ! -d "$cn_dir" ]]; then
    if is_official_termux_uri "$current_uri"; then
      log_warn "未找到本地国内镜像目录 ($cn_dir)，如需换源请稍后运行 termux-change-repo。"
    fi
    return 0
  fi

  # 如果当前已经在用中国大陆镜像，且不是强制切换，则只做提示
  local current_target=""
  if [[ -L "$chosen_link" ]]; then
    current_target=$(readlink -f "$chosen_link" 2>/dev/null || true)
  fi

  if [[ -n "$current_target" && "$current_target" == *"/chinese_mainland"* ]] && ! is_official_termux_uri "$current_uri"; then
    log_ok "Termux 已使用国内镜像，跳过更换。"
    return 0
  fi

  if ! confirm_action "检测到当前 Termux 软件源可能为海外默认源，是否测速并切换到最快的中国大陆镜像？" "Y"; then
    return 0
  fi

  if ! command -v curl >/dev/null 2>&1; then
    log_info "直接将 Termux 镜像组切换为 chinese_mainland..."
    rm -f "$chosen_link"
    ln -s "$cn_dir" "$chosen_link"
    pkg --check-mirror update 2>/dev/null || pkg update
    return 0
  fi

  log_info "正在测速 Termux 中国大陆官方收录镜像..."
  local best_file=""
  local best_url=""
  local best_ms=999999
  local mf url metric code secs ms

  for mf in "$cn_dir"/*; do
    [[ -f "$mf" ]] || continue
    [[ "$mf" == *.dpkg-old || "$mf" == *.dpkg-new || "$mf" == *~ ]] && continue
    url=$(read_mirror_main_url "$mf")
    [[ -n "$url" ]] || continue

    metric=$(curl -fsSL -o /dev/null -w '%{http_code} %{time_total}' \
      --connect-timeout 3 --max-time 5 "${url}/dists/stable/Release" 2>/dev/null || echo "000 9.999")
    code="${metric%% *}"
    secs="${metric##* }"
    if [[ "$code" == "200" ]]; then
      ms=$(awk -v s="$secs" 'BEGIN { printf "%d", s * 1000 }' 2>/dev/null || echo "")
      if [[ "$ms" =~ ^[0-9]+$ ]]; then
        printf '  %s✔%s %-42s %sms\n' "$C_GREEN" "$C_RESET" "$url" "$ms"
        if (( ms < best_ms )); then
          best_ms="$ms"
          best_file="$mf"
          best_url="$url"
        fi
        continue
      fi
    fi
    printf '  %s✘%s %-42s (不可用)\n' "$C_YELLOW" "$C_RESET" "$url"
  done

  if [[ -n "$best_file" ]]; then
    log_ok "选定最快 Termux 镜像: $best_url (${best_ms}ms)"
    if [[ -e "$chosen_link" || -L "$chosen_link" ]]; then
      cp -P "$chosen_link" "${chosen_link}.bak" 2>/dev/null || true
      rm -rf "$chosen_link"
    fi
    ln -s "$best_file" "$chosen_link"
    pkg --check-mirror update 2>/dev/null || pkg update
  else
    log_warn "国内镜像测速均未连通，回退切换到镜像组 chinese_mainland 让 pkg 自行挑选。"
    rm -rf "$chosen_link"
    ln -s "$cn_dir" "$chosen_link"
    pkg --check-mirror update 2>/dev/null || pkg update || true
  fi
}

# ---------------------------------------------------------------------------
# GitHub 与 npm 网络测速
# ---------------------------------------------------------------------------

# 注意：仅采用实际返回 git-upload-pack 协议头的节点，避免代理返回 HTML 错误页导致误判
probe_github_base() {
  local base="$1"
  local probe_url="${base}SillyTavern/SillyTavern.git/info/refs?service=git-upload-pack"
  local tmp_out metric code secs

  tmp_out=$(make_temp_file)
  metric=$(curl -fsSL -o "$tmp_out" -w '%{http_code} %{time_total}' \
    --connect-timeout 4 --max-time 6 "$probe_url" 2>/dev/null || echo "000 9.999")
  code="${metric%% *}"
  secs="${metric##* }"

  if [[ "$code" == "200" ]] && tr -d '\0' < "$tmp_out" | head -c 128 | grep -q 'service=git-upload-pack'; then
    awk -v s="$secs" 'BEGIN { printf "%d", s * 1000 }'
    return 0
  fi
  return 1
}

select_github_channel() {
  RANKED_GH_BASES=()

  if [[ -n "$ST_GITHUB_BASE" ]]; then
    local normalized="${ST_GITHUB_BASE%/}/"
    SELECTED_GH_BASE="$normalized"
    RANKED_GH_BASES=("$normalized" "https://github.com/")
    log_info "使用指定 GitHub 通道: $SELECTED_GH_BASE"
    return 0
  fi

  if [[ "$ST_NETWORK_MODE" == "official" ]]; then
    SELECTED_GH_BASE="https://github.com/"
    RANKED_GH_BASES=("https://github.com/")
    log_info "使用 GitHub 官方直连通道。"
    return 0
  fi

  ensure_curl_installed
  log_info "正在测速 GitHub 仓库拉取通道..."

  local -a candidates=(
    "ghfast.top|https://ghfast.top/https://github.com/"
    "gh-proxy.com|https://gh-proxy.com/https://github.com/"
    "ghproxy.net|https://ghproxy.net/https://github.com/"
    "gitclone.com|https://gitclone.com/github.com/"
    "GitHub直连|https://github.com/"
  )

  local -a results=()
  local entry name base ms
  for entry in "${candidates[@]}"; do
    name="${entry%%|*}"
    base="${entry#*|}"
    if ms=$(probe_github_base "$base"); then
      printf '  %s✔%s %-16s %sms (%s)\n' "$C_GREEN" "$C_RESET" "$name" "$ms" "$base"
      results+=("$(printf '%06d|%s' "$ms" "$base")")
    else
      printf '  %s✘%s %-16s (超时或未返回有效 Git 协议头)\n' "$C_YELLOW" "$C_RESET" "$name"
    fi
  done

  if (( ${#results[@]} > 0 )); then
    local sorted line
    sorted=$(printf '%s\n' "${results[@]}" | sort -n)
    while IFS= read -r line; do
      [[ -n "$line" ]] && RANKED_GH_BASES+=("${line#*|}")
    done <<< "$sorted"
    SELECTED_GH_BASE="${RANKED_GH_BASES[0]}"
    log_ok "优先选择 GitHub 通道: $SELECTED_GH_BASE"
  else
    log_warn "所有预设测速节点均未响应，将回退使用 GitHub 直连。"
    SELECTED_GH_BASE="https://github.com/"
    RANKED_GH_BASES=("https://github.com/")
  fi
}

select_npm_registry() {
  RANKED_NPM_REGS=()

  if [[ -n "$ST_NPM_REGISTRY" ]]; then
    SELECTED_NPM_REG="$ST_NPM_REGISTRY"
    RANKED_NPM_REGS=("$ST_NPM_REGISTRY" "https://registry.npmjs.org")
    log_info "使用指定 npm 源: $SELECTED_NPM_REG"
    return 0
  fi

  if [[ "$ST_NETWORK_MODE" == "official" ]]; then
    SELECTED_NPM_REG="https://registry.npmjs.org"
    RANKED_NPM_REGS=("https://registry.npmjs.org")
    log_info "使用 npm 官方源: $SELECTED_NPM_REG"
    return 0
  fi

  ensure_curl_installed
  log_info "正在测速 npm 软件源..."

  local -a candidates=(
    "npmmirror(淘宝)|https://registry.npmmirror.com"
    "腾讯云镜像|https://mirrors.cloud.tencent.com/npm"
    "华为云镜像|https://repo.huaweicloud.com/repository/npm"
    "npm官方源|https://registry.npmjs.org"
  )

  local -a results=()
  local entry name reg metric code secs ms
  for entry in "${candidates[@]}"; do
    name="${entry%%|*}"
    reg="${entry#*|}"
    metric=$(curl -fsSL -o /dev/null -w '%{http_code} %{time_total}' \
      --connect-timeout 3 --max-time 5 "${reg}/-/ping" 2>/dev/null || echo "000 9.999")
    code="${metric%% *}"
    secs="${metric##* }"
    if [[ "$code" == "200" ]]; then
      ms=$(awk -v s="$secs" 'BEGIN { printf "%d", s * 1000 }' 2>/dev/null || echo "")
      if [[ "$ms" =~ ^[0-9]+$ ]]; then
        printf '  %s✔%s %-16s %sms (%s)\n' "$C_GREEN" "$C_RESET" "$name" "$ms" "$reg"
        results+=("$(printf '%06d|%s' "$ms" "$reg")")
        continue
      fi
    fi
    printf '  %s✘%s %-16s (不可用)\n' "$C_YELLOW" "$C_RESET" "$name"
  done

  if (( ${#results[@]} > 0 )); then
    local sorted line
    sorted=$(printf '%s\n' "${results[@]}" | sort -n)
    while IFS= read -r line; do
      [[ -n "$line" ]] && RANKED_NPM_REGS+=("${line#*|}")
    done <<< "$sorted"
    SELECTED_NPM_REG="${RANKED_NPM_REGS[0]}"
    log_ok "优先选择 npm 源: $SELECTED_NPM_REG"
  else
    log_warn "npm 源测速均未连通，默认回退 npmmirror。"
    SELECTED_NPM_REG="https://registry.npmmirror.com"
    RANKED_NPM_REGS=("https://registry.npmmirror.com" "https://registry.npmjs.org")
  fi
}

# ---------------------------------------------------------------------------
# 运行环境依赖安装（git / nodejs-lts / npm / nano / 32位 esbuild）
# ---------------------------------------------------------------------------

install_runtime_dependencies() {
  local arch
  arch=$(detect_arch)
  local -a packages=()

  command -v git >/dev/null 2>&1 || packages+=("git")
  command -v curl >/dev/null 2>&1 || packages+=("curl")
  command -v nano >/dev/null 2>&1 || packages+=("nano")

  # 32 位 ARM 需要 Termux 官方提供的原生 esbuild
  if [[ "$arch" == "arm" ]] && ! command -v esbuild >/dev/null 2>&1; then
    packages+=("esbuild")
  fi

  local node_major
  node_major=$(get_node_major)
  if (( node_major == 0 )); then
    packages+=("nodejs-lts")
  elif (( node_major < ST_MIN_NODE_MAJOR )); then
    log_warn "当前 Node.js 主版本为 v${node_major}，SillyTavern 要求 >= v${ST_MIN_NODE_MAJOR}。"
    # Termux 中 nodejs 与 nodejs-lts 互斥，若旧版包是 nodejs 需先卸载避免冲突
    if dpkg -s nodejs >/dev/null 2>&1; then
      log_info "正在移除旧版 nodejs 包以便切换至 nodejs-lts..."
      pkg uninstall -y nodejs || die "卸载旧版 nodejs 失败，请手动处理后重试。"
    fi
    packages+=("nodejs-lts")
  else
    log_ok "检测到 Node.js $(node -v)，满足 >= v${ST_MIN_NODE_MAJOR} 要求。"
  fi

  if (( ${#packages[@]} > 0 )); then
    log_info "正在安装基础依赖: ${packages[*]}"
    pkg install -y "${packages[@]}" || die "安装基础依赖失败: ${packages[*]}"
  fi

  # Termux 新版 nodejs-lts (> 24.13.0) 将 npm 拆分为了单独的 RECOMMENDS 包
  if ! command -v npm >/dev/null 2>&1; then
    log_info "未检测到 npm（新版 Termux Node 已拆分 npm 包），正在补装 npm..."
    pkg install -y npm || die "安装 npm 失败。"
  fi

  log_ok "环境就绪: git=$(git --version | awk '{print $3}'), node=$(node -v), npm=$(npm -v)"
}

# ---------------------------------------------------------------------------
# SillyTavern 克隆、更新与 npm 依赖安装
# ---------------------------------------------------------------------------

git_with_base() {
  local base="$1"
  shift
  if [[ -z "$base" || "$base" == "https://github.com/" ]]; then
    git "$@"
  else
    git -c "url.${base}.insteadOf=https://github.com/" "$@"
  fi
}

clone_sillytavern() {
  local target_dir="$1"
  local branch="$2"

  mkdir -p "$(dirname "$target_dir")"
  if (( ${#RANKED_GH_BASES[@]} == 0 )); then
    select_github_channel
  fi

  local base
  for base in "${RANKED_GH_BASES[@]}"; do
    log_info "正在浅克隆 SillyTavern ($branch 分支) [通道: $base]..."
    rm -rf "$target_dir"
    if git_with_base "$base" clone --depth 1 --branch "$branch" --single-branch "$ST_REPO_HTTPS" "$target_dir"; then
      log_ok "SillyTavern 克隆成功: $target_dir"
      return 0
    fi
    log_warn "通过 $base 克隆失败，尝试下一个可用通道..."
    rm -rf "$target_dir"
  done

  die "所有 GitHub 通道均克隆失败，请检查网络或使用 --github-proxy 指定代理。"
}

update_sillytavern_repo() {
  local target_dir="$1"
  local branch="$2"

  is_st_directory "$target_dir" || die "目录 $target_dir 不是有效的 SillyTavern 仓库。"

  if (( ${#RANKED_GH_BASES[@]} == 0 )); then
    select_github_channel
  fi

  # 保持仓库 origin 为干净的官方地址，防止临时加速域名失效后锁死后续更新
  local current_origin
  current_origin=$(git -C "$target_dir" remote get-url origin 2>/dev/null || true)
  if [[ -n "$current_origin" && "$current_origin" != "$ST_REPO_HTTPS" && "$current_origin" == *"SillyTavern/SillyTavern"* ]]; then
    git -C "$target_dir" remote set-url origin "$ST_REPO_HTTPS"
  fi

  local current_branch
  current_branch=$(git -C "$target_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")

  local base
  for base in "${RANKED_GH_BASES[@]}"; do
    log_info "正在拉取更新 ($branch 分支) [通道: $base]..."
    if [[ "$current_branch" != "$branch" ]]; then
      # 单分支浅克隆切换分支前需更新远程引用范围
      if git_with_base "$base" -C "$target_dir" remote set-branches origin "$branch" \
        && git_with_base "$base" -C "$target_dir" fetch --depth 1 origin "$branch" \
        && git -C "$target_dir" checkout -B "$branch" "origin/$branch"; then
        log_ok "已切换并更新至 $branch 分支。"
        return 0
      fi
    else
      if git_with_base "$base" -C "$target_dir" pull --rebase --autostash; then
        log_ok "SillyTavern 仓库已是最新状态。"
        return 0
      fi
    fi
    log_warn "通过 $base 更新失败，尝试下一个通道..."
  done

  die "仓库更新失败，请检查本地修改冲突或网络连接。"
}

install_st_node_modules() {
  local target_dir="$1"
  is_st_directory "$target_dir" || die "无效的 SillyTavern 目录: $target_dir"

  if (( ${#RANKED_NPM_REGS[@]} == 0 )); then
    select_npm_registry
  fi

  local reg
  for reg in "${RANKED_NPM_REGS[@]}"; do
    log_info "正在安装/校验 Node 依赖 [npm 源: $reg]..."
    if (
      cd "$target_dir"
      NODE_ENV=production npm --registry="$reg" install \
        --no-save --no-audit --no-fund --loglevel=error --no-progress --omit=dev --ignore-scripts
    ); then
      log_ok "SillyTavern Node 依赖安装完成。"
      return 0
    fi
    log_warn "使用 npm 源 $reg 安装失败，尝试下一个可用源..."
  done

  die "Node 依赖安装失败，请检查网络或手动执行 npm install。"
}

# ---------------------------------------------------------------------------
# config.yaml 与 Termux 环境补全
# ---------------------------------------------------------------------------

ensure_config_file() {
  local target_dir="$1"
  local cfg="$target_dir/config.yaml"
  local def_cfg="$target_dir/default/config.yaml"

  if [[ -f "$cfg" ]]; then
    return 0
  fi
  if [[ -f "$def_cfg" ]]; then
    cp "$def_cfg" "$cfg"
    log_ok "已从 default/config.yaml 生成初始配置文件。"
    return 0
  fi
  die "未找到 config.yaml 且缺少模板 default/config.yaml。"
}

# 在指定 YAML 一级/顶层区块内安全修改键值，避免全局 sed 误改其他同名 enabled 字段
yaml_set_in_section() {
  local file="$1"
  local section="$2" # 空字符串表示顶层键
  local key="$3"
  local value="$4"
  local tmp_file
  tmp_file=$(make_temp_file)

  if awk -v sec="$section" -v k="$key" -v v="$value" '
    BEGIN { in_sec = 0; updated = 0 }
    {
      if (sec == "") {
        if ($0 ~ "^" k ":[[:space:]]*") {
          print k ": " v
          updated = 1
          next
        }
        print
        next
      }

      if ($0 ~ "^" sec ":[[:space:]]*(#.*)?$") {
        in_sec = 1
        print
        next
      }
      if (in_sec && $0 ~ "^[A-Za-z0-9_-]+:") {
        in_sec = 0
      }

      if (in_sec && $0 ~ "^[[:space:]]+" k ":[[:space:]]*") {
        match($0, /^[[:space:]]+/)
        indent = substr($0, RSTART, RLENGTH)
        print indent k ": " v
        updated = 1
        next
      }
      print
    }
    END { exit (updated ? 0 : 2) }
  ' "$file" > "$tmp_file"; then
    mv "$tmp_file" "$file"
    return 0
  else
    return 1
  fi
}

backup_config_file() {
  local cfg="$1"
  local bak
  bak="${cfg}.bak.$(date +%Y%m%d%H%M%S)"
  cp "$cfg" "$bak"
  log_info "已备份原配置到: $bak"
}

apply_android_performance_preset() {
  local target_dir="$1"
  ensure_config_file "$target_dir"
  local cfg="$target_dir/config.yaml"

  backup_config_file "$cfg"

  local ok_count=0
  if yaml_set_in_section "$cfg" "performance" "lazyLoadCharacters" "true"; then
    ((ok_count += 1))
  else
    log_warn "未在 performance 区块找到 lazyLoadCharacters"
  fi
  if yaml_set_in_section "$cfg" "performance" "useDiskCache" "false"; then
    ((ok_count += 1))
  else
    log_warn "未在 performance 区块找到 useDiskCache"
  fi
  if yaml_set_in_section "$cfg" "browserLaunch" "enabled" "false"; then
    ((ok_count += 1))
  else
    log_warn "未在 browserLaunch 区块找到 enabled"
  fi

  if (( ok_count > 0 )); then
    log_ok "已应用安卓优化预设：懒加载角色卡、关闭磁盘缓存、禁用桌面自动弹浏览器。"
  else
    log_warn "未匹配到可更新的性能字段，请手动检查 $cfg。"
  fi
}

toggle_lan_listen() {
  local target_dir="$1"
  local mode="$2" # true | false
  ensure_config_file "$target_dir"
  local cfg="$target_dir/config.yaml"

  backup_config_file "$cfg"
  yaml_set_in_section "$cfg" "" "listen" "$mode" || die "修改 listen 失败，请检查 $cfg 格式。"

  if [[ "$mode" == "true" ]]; then
    log_ok "已开启局域网监听 (listen: true)。"
    log_warn "安全提醒：若要从其他设备访问，请在 $cfg 中将访问设备 IP 加入 whitelist，或关闭 whitelistMode 后务必开启 basicAuthMode 并修改默认用户名密码！"
  else
    log_ok "已恢复仅本机访问 (listen: false)。"
  fi
}

self_install_cli() {
  local bin_dir="$HOME/.local/bin"
  local bin_path="$bin_dir/st-termux"
  mkdir -p "$bin_dir"

  local src_script="${BASH_SOURCE[0]:-}"
  if [[ -n "$src_script" && -f "$src_script" ]]; then
    local abs_src abs_dst
    abs_src=$(readlink -f "$src_script" 2>/dev/null || printf '%s' "$src_script")
    abs_dst=$(readlink -f "$bin_path" 2>/dev/null || printf '%s' "$bin_path")
    if [[ "$abs_src" != "$abs_dst" ]]; then
      cp "$src_script" "$bin_path"
      chmod +x "$bin_path"
      log_ok "已保存管理脚本到: $bin_path"
    fi
    return 0
  fi

  # 通过 curl | bash 启动时，尝试用同一套加速通道缓存脚本本身以便后续输入 stmenu 调出菜单
  if command -v curl >/dev/null 2>&1; then
    local -a raw_urls=("https://raw.githubusercontent.com/${SELF_REPO_RAW}")
    if [[ "$ST_NETWORK_MODE" != "official" ]]; then
      raw_urls=(
        "https://ghfast.top/https://raw.githubusercontent.com/${SELF_REPO_RAW}"
        "https://gh-proxy.com/https://raw.githubusercontent.com/${SELF_REPO_RAW}"
        "https://raw.githubusercontent.com/${SELF_REPO_RAW}"
      )
    fi
    local u tmp_dl
    tmp_dl=$(make_temp_file)
    for u in "${raw_urls[@]}"; do
      if curl -fsSL --connect-timeout 4 --max-time 8 "$u" -o "$tmp_dl" 2>/dev/null \
        && grep -q 'SCRIPT_VERSION=' "$tmp_dl"; then
        mv "$tmp_dl" "$bin_path"
        chmod +x "$bin_path"
        log_ok "已保存管理脚本到: $bin_path"
        return 0
      fi
    done
  fi
  return 1
}

detect_shell_rc_files() {
  local mode="${1:-active}" # active=写入目标 | all=全部存在的 rc
  local -a files=()

  if [[ "$mode" == "all" ]]; then
    [[ -f "$HOME/.bashrc" ]] && files+=("$HOME/.bashrc")
    [[ -f "$HOME/.zshrc" ]] && files+=("$HOME/.zshrc")
    if (( ${#files[@]} == 0 )); then
      files+=("$HOME/.bashrc")
    fi
    printf '%s\n' "${files[@]}"
    return 0
  fi

  local shell_name
  shell_name=$(basename "${SHELL:-bash}")
  if [[ "$shell_name" == "zsh" || -f "$HOME/.zshrc" ]]; then
    files+=("$HOME/.zshrc")
  fi
  if [[ "$shell_name" == "bash" || -f "$HOME/.bashrc" || ${#files[@]} -eq 0 ]]; then
    files+=("$HOME/.bashrc")
  fi
  printf '%s\n' "${files[@]}"
}

remove_rc_block() {
  local rc_file="$1"
  local start_mark="$2"
  local end_mark="$3"
  [[ -f "$rc_file" ]] || return 0

  local tmp_rc
  tmp_rc=$(make_temp_file)
  awk -v s="$start_mark" -v e="$end_mark" '
    $0 == s { skip = 1; next }
    $0 == e { skip = 0; next }
    !skip { lines[++n] = $0 }
    END {
      while (n > 0 && lines[n] ~ /^[[:space:]]*$/) n--
      for (i = 1; i <= n; i++) print lines[i]
    }
  ' "$rc_file" > "$tmp_rc"
  mv "$tmp_rc" "$rc_file"
}

inject_shell_shortcuts() {
  local target_dir="$1"
  local has_stmenu=0
  if self_install_cli; then
    has_stmenu=1
  fi

  local -a rc_files=()
  local line
  while IFS= read -r line; do
    [[ -n "$line" ]] && rc_files+=("$line")
  done < <(detect_shell_rc_files active)

  local block
  block="${RC_BLOCK_START}
case \":\$PATH:\" in *\":\$HOME/.local/bin:\"*) ;; *) export PATH=\"\$HOME/.local/bin:\$PATH\" ;; esac
alias st='cd \"${target_dir}\" && bash start.sh'"
  if (( has_stmenu == 1 )); then
    block="${block}
alias stup='st-termux update -d \"${target_dir}\"'
alias stmenu='st-termux -d \"${target_dir}\"'"
  else
    block="${block}
alias stup='cd \"${target_dir}\" && git pull --rebase --autostash'"
  fi
  block="${block}
${RC_BLOCK_END}"

  local rc
  for rc in "${rc_files[@]}"; do
    [[ -f "$rc" ]] || touch "$rc"
    remove_rc_block "$rc" "$RC_BLOCK_START" "$RC_BLOCK_END"
    printf '\n%s\n' "$block" >> "$rc"
    log_ok "已写入快捷指令到 $rc (st 启动 / stup 更新${has_stmenu:+ / stmenu 菜单})"
  done
}

is_autostart_enabled() {
  local rc
  while IFS= read -r rc; do
    if [[ -f "$rc" ]] && grep -Fq -- "$AUTOSTART_BLOCK_START" "$rc"; then
      return 0
    fi
  done < <(detect_shell_rc_files all)
  return 1
}

enable_termux_autostart() {
  local target_dir="$1"
  if ! self_install_cli; then
    die "无法将管理脚本缓存到 ~/.local/bin/st-termux，暂不能配置自启动。"
  fi

  local -a rc_files=()
  local line
  while IFS= read -r line; do
    [[ -n "$line" ]] && rc_files+=("$line")
  done < <(detect_shell_rc_files active)

  local block
  block="${AUTOSTART_BLOCK_START}
case \$- in
  *i*)
    if [[ -z \"\${ST_NO_AUTOSTART:-}\" && -z \"\${ST_AUTOSTART_ACTIVE:-}\" && -f \"${target_dir}/start.sh\" ]]; then
      ST_AUTOSTART_ACTIVE=1
      export ST_AUTOSTART_ACTIVE
      if [[ -x \"\$HOME/.local/bin/st-termux\" ]]; then
        \"\$HOME/.local/bin/st-termux\" autostart -d \"${target_dir}\" || true
      fi
    fi
    ;;
esac
${AUTOSTART_BLOCK_END}"

  local rc
  for rc in "${rc_files[@]}"; do
    [[ -f "$rc" ]] || touch "$rc"
    remove_rc_block "$rc" "$AUTOSTART_BLOCK_START" "$AUTOSTART_BLOCK_END"
    printf '\n%s\n' "$block" >> "$rc"
    log_ok "已开启打开 Termux 默认自启动 (写入: $rc)"
  done
  log_info "提示：启动后按 Ctrl+C 可停止酒馆并返回终端；输入 stmenu 可随时在设置中关闭自启动。"
}

disable_termux_autostart() {
  local rc removed=0
  while IFS= read -r rc; do
    if [[ -f "$rc" ]] && grep -Fq -- "$AUTOSTART_BLOCK_START" "$rc"; then
      remove_rc_block "$rc" "$AUTOSTART_BLOCK_START" "$AUTOSTART_BLOCK_END"
      log_ok "已从 $rc 关闭 Termux 默认自启动。"
      removed=1
    fi
  done < <(detect_shell_rc_files all)

  if (( removed == 0 )); then
    log_info "当前未开启 Termux 默认自启动，无需更改。"
  fi
}

get_st_port() {
  local target_dir="$1"
  local cfg="$target_dir/config.yaml"
  [[ -f "$cfg" ]] || cfg="$target_dir/default/config.yaml"
  local port="8000"
  if [[ -f "$cfg" ]]; then
    local parsed
    parsed=$(awk -F: '/^port:[[:space:]]*[0-9]+/ { gsub(/[^0-9]/, "", $2); print $2; exit }' "$cfg" 2>/dev/null || true)
    [[ "$parsed" =~ ^[0-9]+$ ]] && port="$parsed"
  fi
  printf '%s\n' "$port"
}

is_sillytavern_running() {
  local target_dir="$1"
  local port
  port=$(get_st_port "$target_dir")

  if command -v node >/dev/null 2>&1; then
    if node -e "const n=require('net'),s=n.connect({host:'127.0.0.1',port:Number(process.argv[1])},()=>{s.destroy();process.exit(0)});s.setTimeout(250,()=>{s.destroy();process.exit(1)});s.on('error',()=>process.exit(1));" "$port" >/dev/null 2>&1; then
      return 0
    fi
  fi
  return 1
}

# ---------------------------------------------------------------------------
# 业务动作编排
# ---------------------------------------------------------------------------

action_install() {
  assert_termux_env
  log_info "开始准备 Termux SillyTavern 运行环境..."
  log_info "安装目录: $ST_DIR | 分支: $ST_BRANCH | 网络策略: $ST_NETWORK_MODE"

  setup_termux_mirror
  run_pkg_upgrade
  install_runtime_dependencies

  select_github_channel
  select_npm_registry

  if [[ -d "$ST_DIR" ]] && [[ -n "$(ls -A "$ST_DIR" 2>/dev/null || true)" ]]; then
    if is_st_directory "$ST_DIR"; then
      log_warn "检测到已有 SillyTavern 目录 ($ST_DIR)，将执行安全更新（保留 data/ 与 config.yaml）。"
      update_sillytavern_repo "$ST_DIR" "$ST_BRANCH"
    else
      die "目标目录 $ST_DIR 已存在且非空，但不是 SillyTavern 仓库！为保护数据已中止，请使用 -d 指定其他目录。"
    fi
  else
    clone_sillytavern "$ST_DIR" "$ST_BRANCH"
  fi

  install_st_node_modules "$ST_DIR"

  if [[ "$ST_APPLY_PERF" == "1" ]] || { [[ -z "$ST_APPLY_PERF" ]] && confirm_action "是否应用安卓低内存/省空间推荐配置 (config.yaml)？" "Y"; }; then
    apply_android_performance_preset "$ST_DIR"
  fi

  if [[ "$ST_APPLY_ALIAS" == "1" ]] || { [[ -z "$ST_APPLY_ALIAS" ]] && confirm_action "是否写入快捷命令 st / stup / stmenu 到 shell 配置？" "Y"; }; then
    inject_shell_shortcuts "$ST_DIR"
  fi

  if [[ "$ST_APPLY_AUTOSTART" == "1" ]] || { [[ -z "$ST_APPLY_AUTOSTART" ]] && confirm_action "是否开启打开 Termux 时默认自动启动 SillyTavern（可在设置里随时关闭）？" "Y"; }; then
    enable_termux_autostart "$ST_DIR"
  elif [[ "$ST_APPLY_AUTOSTART" == "0" ]]; then
    disable_termux_autostart
  fi

  echo
  log_ok "SillyTavern 安装与环境补全全部完成！"
  printf '  启动命令: %scd "%s" && bash start.sh%s\n' "$C_BOLD" "$ST_DIR" "$C_RESET"
  printf '  默认地址: %shttp://127.0.0.1:8000%s\n' "$C_BOLD" "$C_RESET"
  if command -v termux-wake-lock >/dev/null 2>&1; then
    printf '  防杀提示: 如需后台长期挂机，可先运行 %stermux-wake-lock%s 获取唤醒锁。\n' "$C_CYAN" "$C_RESET"
  fi

  if [[ "$ST_START_AFTER" -eq 1 ]] || { has_tty_input && [[ "$ST_YES" -eq 0 ]] && confirm_action "是否立即启动 SillyTavern？" "N"; }; then
    action_start
  fi
}

action_update() {
  assert_termux_env
  ensure_curl_installed
  is_st_directory "$ST_DIR" || die "未在 $ST_DIR 找到 SillyTavern，请先执行安装或用 -d 指定正确目录。"

  select_github_channel
  select_npm_registry
  update_sillytavern_repo "$ST_DIR" "$ST_BRANCH"
  install_st_node_modules "$ST_DIR"
  log_ok "SillyTavern 更新完毕！"
}

action_start() {
  is_st_directory "$ST_DIR" || die "未在 $ST_DIR 找到 SillyTavern，请先安装。"
  if command -v termux-wake-lock >/dev/null 2>&1; then
    termux-wake-lock 2>/dev/null || true
    log_info "已尝试请求 Termux 唤醒锁 (termux-wake-lock) 以减少息屏断流。"
  fi
  log_info "正在启动 SillyTavern..."
  cd "$ST_DIR"
  exec bash start.sh
}

action_autostart() {
  is_st_directory "$ST_DIR" || return 0
  if is_sillytavern_running "$ST_DIR"; then
    local port
    port=$(get_st_port "$ST_DIR")
    log_info "检测到 SillyTavern 已在端口 $port 运行，跳过重复自启动（输入 stmenu 可打开设置）。"
    return 0
  fi

  if command -v termux-wake-lock >/dev/null 2>&1; then
    termux-wake-lock 2>/dev/null || true
  fi
  log_info "正在自动启动 SillyTavern（按 Ctrl+C 可停止并回到终端；可在 stmenu -> 设置 中关闭自启动）..."
  # 不用 exec，便于按 Ctrl+C 停止后保留 Termux 命令行继续操作
  (
    cd "$ST_DIR"
    bash start.sh
  ) || true
}

action_doctor() {
  local prefix arch node_ver npm_ver git_ver curl_ver uri issues=0
  prefix=$(termux_prefix)
  arch=$(detect_arch)

  echo "================ st-termux 环境诊断 ================"
  printf '脚本版本     : %s\n' "$SCRIPT_VERSION"
  printf '当前用户     : %s (uid=%s)\n' "$(id -un 2>/dev/null || echo unknown)" "$(id -u)"
  if [[ "$(id -u)" -eq 0 ]]; then
    printf '  %s✘ 警告: root 环境下无法使用 Termux pkg%s\n' "$C_RED" "$C_RESET"
    ((issues += 1))
  fi
  printf 'Termux PREFIX: %s (%s)\n' "$prefix" "$([[ -d "$prefix" ]] && echo 存在 || echo 缺失)"
  command -v pkg >/dev/null 2>&1 || { printf '  %s✘ 缺少 pkg 命令%s\n' "$C_RED" "$C_RESET"; ((issues += 1)); }
  printf '设备架构     : %s (uname=%s)\n' "$arch" "$(uname -m)"

  uri=$(get_current_termux_uri)
  printf 'Termux APT源 : %s\n' "${uri:-未读取到}"

  node_ver=$(node -v 2>/dev/null || echo "未安装")
  npm_ver=$(npm -v 2>/dev/null || echo "未安装")
  git_ver=$(git --version 2>/dev/null | awk '{print $3}' || echo "未安装")
  curl_ver=$(curl --version 2>/dev/null | awk 'NR==1{print $2}' || echo "未安装")
  printf 'git          : %s\n' "$git_ver"
  printf 'curl         : %s\n' "$curl_ver"
  printf 'Node.js      : %s (要求 >= v%s)\n' "$node_ver" "$ST_MIN_NODE_MAJOR"
  printf 'npm          : %s\n' "$npm_ver"
  if [[ "$arch" == "arm" ]]; then
    printf 'esbuild(32位): %s\n' "$(command -v esbuild >/dev/null 2>&1 && echo 已安装 || echo 未安装-建议补装)"
  fi

  if (( $(get_node_major) < ST_MIN_NODE_MAJOR )); then
    printf '  %s✘ Node.js 未安装或版本低于 v%s%s\n' "$C_RED" "$ST_MIN_NODE_MAJOR" "$C_RESET"
    ((issues += 1))
  fi
  [[ "$npm_ver" == "未安装" ]] && { printf '  %s✘ 缺少 npm%s\n' "$C_RED" "$C_RESET"; ((issues += 1)); }

  if is_st_directory "$ST_DIR"; then
    local st_branch st_rev modules_ok="未安装"
    st_branch=$(git -C "$ST_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?")
    st_rev=$(git -C "$ST_DIR" rev-parse --short HEAD 2>/dev/null || echo "?")
    [[ -d "$ST_DIR/node_modules" ]] && modules_ok="已存在"
    printf 'SillyTavern  : 已安装 (%s @ %s, %s)\n' "$ST_DIR" "$st_branch" "$st_rev"
    printf 'node_modules : %s\n' "$modules_ok"
    printf 'config.yaml  : %s\n' "$([[ -f "$ST_DIR/config.yaml" ]] && echo 已生成 || echo 尚未生成)"
  else
    printf 'SillyTavern  : 未在 %s 检测到有效安装\n' "$ST_DIR"
  fi
  printf '打开默认启动 : %s\n' "$(is_autostart_enabled && echo 已开启 || echo 已关闭)"
  echo "===================================================="
  if (( issues > 0 )); then
    log_warn "发现 $issues 项环境问题，可通过一键安装/环境补全自动修复。"
    return 1
  fi
  log_ok "基础运行环境检查通过。"
}

action_mirror() {
  assert_termux_env
  ensure_curl_installed
  setup_termux_mirror
  select_github_channel
  select_npm_registry
}

action_config_menu() {
  # 允许命令行直接开关自启动：st-termux config --autostart / --no-autostart
  if [[ "$ST_APPLY_AUTOSTART" == "1" ]]; then
    is_st_directory "$ST_DIR" || die "未在 $ST_DIR 找到 SillyTavern，请先安装。"
    enable_termux_autostart "$ST_DIR"
    return 0
  elif [[ "$ST_APPLY_AUTOSTART" == "0" ]]; then
    disable_termux_autostart
    return 0
  fi

  is_st_directory "$ST_DIR" || die "未在 $ST_DIR 找到 SillyTavern，请先安装。"
  while true; do
    local autostart_label="已关闭"
    if is_autostart_enabled; then
      autostart_label="已开启"
    fi
    echo
    printf '%s--- 设置与快捷命令 (%s) ---%s\n' "$C_BOLD" "$ST_DIR" "$C_RESET"
    echo "1) 切换打开 Termux 默认启动 (当前: ${autostart_label})"
    echo "2) 应用安卓低内存与性能预设 (lazyLoadCharacters/关闭磁盘缓存/禁弹浏览器)"
    echo "3) 写入/刷新 shell 快捷命令 (st / stup / stmenu)"
    echo "4) 开启局域网访问 (listen: true)"
    echo "5) 关闭局域网访问 (listen: false)"
    echo "0) 返回"
    local choice=""
    tty_read "请选择 [0-5]: " choice "0"
    case "$choice" in
      1)
        if is_autostart_enabled; then
          disable_termux_autostart
        else
          enable_termux_autostart "$ST_DIR"
        fi
        ;;
      2) apply_android_performance_preset "$ST_DIR" ;;
      3) inject_shell_shortcuts "$ST_DIR" ;;
      4) toggle_lan_listen "$ST_DIR" "true" ;;
      5) toggle_lan_listen "$ST_DIR" "false" ;;
      0) break ;;
      *) log_warn "无效选项: $choice" ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# 交互主菜单与 CLI 参数解析
# ---------------------------------------------------------------------------

show_help() {
  cat <<EOF
st-termux v${SCRIPT_VERSION} - Termux 快速安装与维护 SillyTavern（酒馆）工具

用法:
  bash install.sh [命令] [选项]
  无命令参数运行将进入中文交互菜单。

命令:
  install, --install    一键安装/修复 SillyTavern 并补全运行环境
  update,  --update     安全更新 SillyTavern 与依赖（保留 data/ 与 config.yaml）
  start,   --start      启动 SillyTavern
  doctor,  --doctor     运行 Termux 与酒馆环境自检
  mirror,  --mirror     测速并配置 Termux / GitHub / npm 加速源
  config,  --config     打开设置（自启动开关、性能预设、快捷命令、局域网）

选项:
  -d, --dir <路径>          SillyTavern 安装目录 (默认: \$HOME/SillyTavern)
  -b, --branch <分支>       指定分支 release 或 staging (默认: release)
  --network <auto|cn|official>
                            网络策略：auto/cn 优先测速国内源，official 用官方源
  --github-proxy <前缀URL>  自定义 GitHub 代理前缀 (例: https://ghfast.top/https://github.com/)
  --npm-registry <URL>      自定义 npm 源 URL
  --perf / --no-perf        强制开启或跳过安卓 config.yaml 性能预设
  --alias / --no-alias      强制开启或跳过写入 shell 快捷指令
  --autostart / --no-autostart
                            开启或关闭打开 Termux 默认启动（可配合 install / config）
  --start-after             安装完成后立即启动酒馆
  -y, --yes                 非交互模式，自动确认所有推荐步骤
  -h, --help                显示此帮助信息
  --version                 显示脚本版本号
EOF
}

parse_args() {
  while (( $# > 0 )); do
    case "$1" in
      install|--install) ST_ACTION="install"; shift ;;
      update|--update) ST_ACTION="update"; shift ;;
      start|--start) ST_ACTION="start"; shift ;;
      autostart) ST_ACTION="autostart"; shift ;;
      doctor|--doctor) ST_ACTION="doctor"; shift ;;
      mirror|--mirror) ST_ACTION="mirror"; shift ;;
      config|--config) ST_ACTION="config"; shift ;;
      -d|--dir)
        [[ -n "${2:-}" ]] || die "选项 $1 需要指定目录路径。"
        ST_DIR="$2"
        shift 2
        ;;
      -b|--branch)
        [[ -n "${2:-}" ]] || die "选项 $1 需要指定分支名。"
        [[ "$2" == "release" || "$2" == "staging" ]] || die "不支持的分支 '$2'，请使用 release 或 staging。"
        ST_BRANCH="$2"
        shift 2
        ;;
      --network)
        [[ -n "${2:-}" ]] || die "选项 $1 需要指定 auto、cn 或 official。"
        case "$2" in
          auto|cn|official) ST_NETWORK_MODE="$2" ;;
          *) die "无效网络策略 '$2'，可选值为 auto、cn、official。" ;;
        esac
        shift 2
        ;;
      --github-proxy)
        [[ -n "${2:-}" ]] || die "选项 $1 需要指定代理前缀。"
        ST_GITHUB_BASE="$2"
        shift 2
        ;;
      --npm-registry)
        [[ -n "${2:-}" ]] || die "选项 $1 需要指定 npm 源地址。"
        ST_NPM_REGISTRY="$2"
        shift 2
        ;;
      --perf) ST_APPLY_PERF="1"; shift ;;
      --no-perf) ST_APPLY_PERF="0"; shift ;;
      --alias) ST_APPLY_ALIAS="1"; shift ;;
      --no-alias) ST_APPLY_ALIAS="0"; shift ;;
      --autostart) ST_APPLY_AUTOSTART="1"; shift ;;
      --no-autostart) ST_APPLY_AUTOSTART="0"; shift ;;
      --start-after) ST_START_AFTER=1; shift ;;
      -y|--yes) ST_YES=1; shift ;;
      -h|--help) show_help; exit 0 ;;
      --version) printf 'st-termux %s\n' "$SCRIPT_VERSION"; exit 0 ;;
      *) die "未知参数: $1（使用 --help 查看用法）" ;;
    esac
  done
}

interactive_menu() {
  if ! has_tty_input; then
    die "当前没有可用的交互终端，请传入子命令运行（例如: bash install.sh install -y）。"
  fi

  while true; do
    echo
    printf '%s=========================================%s\n' "$C_BLUE" "$C_RESET"
    printf '   %sSillyTavern Termux 一键助手 v%s%s\n' "$C_BOLD" "$SCRIPT_VERSION" "$C_RESET"
    printf '   目录: %s | 分支: %s\n' "$ST_DIR" "$ST_BRANCH"
    printf '%s=========================================%s\n' "$C_BLUE" "$C_RESET"
    echo " 1) 一键安装 / 补全环境与依赖"
    echo " 2) 安全更新 SillyTavern (保留数据与配置)"
    echo " 3) 启动 SillyTavern"
    echo " 4) 环境诊断与状态检查"
    echo " 5) 网络测速与切换国内镜像 (pkg/GitHub/npm)"
    echo " 6) 设置 (自启动开关 / 性能预设 / 快捷命令 / 局域网)"
    echo " 7) 切换目标分支 (当前: $ST_BRANCH)"
    echo " 0) 退出"

    local choice=""
    tty_read "请输入选项 [0-7]: " choice "0"
    case "$choice" in
      1) action_install ;;
      2) action_update ;;
      3) action_start ;;
      4) action_doctor || true ;;
      5) action_mirror ;;
      6) action_config_menu ;;
      7)
        if [[ "$ST_BRANCH" == "release" ]]; then
          ST_BRANCH="staging"
        else
          ST_BRANCH="release"
        fi
        log_ok "已切换目标分支为: $ST_BRANCH"
        ;;
      0) exit 0 ;;
      *) log_warn "无效选项: $choice" ;;
    esac
  done
}

main() {
  parse_args "$@"
  case "$ST_ACTION" in
    install) action_install ;;
    update) action_update ;;
    start) action_start ;;
    autostart) action_autostart ;;
    doctor) action_doctor ;;
    mirror) action_mirror ;;
    config) action_config_menu ;;
    "") interactive_menu ;;
  esac
}

main "$@"
