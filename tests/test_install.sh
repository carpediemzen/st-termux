#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_DIR/install.sh"

PASS_COUNT=0
FAIL_COUNT=0
TEST_ROOT="$(mktemp -d /tmp/st-termux-test.XXXXXX)"
chmod 755 "$TEST_ROOT"

cleanup() {
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  printf '[PASS] %s\n' "$1"
}

fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  printf '[FAIL] %s\n' "$1" >&2
}

assert_eq() {
  local expected="$1" actual="$2" msg="$3"
  if [[ "$expected" == "$actual" ]]; then
    pass "$msg"
  else
    fail "$msg (expected='$expected', actual='$actual')"
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" msg="$3"
  if grep -Fq -- "$needle" <<< "$haystack"; then
    pass "$msg"
  else
    fail "$msg (missing '$needle')"
  fi
}

assert_file_contains() {
  local file="$1" needle="$2" msg="$3"
  if grep -Fq -- "$needle" "$file"; then
    pass "$msg"
  else
    fail "$msg ($file missing '$needle')"
  fi
}

# 准备隔离的 mock Termux 环境；包命令按真实安装行为动态链接到 prefix/bin
setup_sandbox() {
  local case_dir="$1"
  rm -rf "$case_dir"
  mkdir -p "$case_dir"/{home,prefix/bin,prefix/etc/apt/sources.list.d,prefix/etc/termux/mirrors/chinese_mainland,sysbin,avail,logs,state}
  chmod -R 777 "$case_dir"

  cat > "$case_dir/prefix/etc/apt/sources.list.d/main.sources" <<'EOF'
Types: deb
URIs: https://packages.termux.dev/apt/termux-main
Suites: stable
Components: main
EOF

  cat > "$case_dir/prefix/etc/termux/mirrors/chinese_mainland/mirrors.tuna.tsinghua.edu.cn" <<'EOF'
WEIGHT=1
MAIN="https://mirrors.tuna.tsinghua.edu.cn/termux/apt/termux-main"
EOF

  cat > "$case_dir/prefix/etc/termux/mirrors/chinese_mainland/mirrors.sustech.edu.cn" <<'EOF'
WEIGHT=1
MAIN="https://mirrors.sustech.edu.cn/termux/apt/termux-main"
EOF

  # 构造最小纯净 sysbin，避免测试误触宿主 /usr/bin/git 或真实 curl
  local tool real_path
  for tool in bash sh awk sed grep egrep mktemp rm mv cp ln mkdir rmdir touch chmod cat ls head tail tr sort uniq wc cut date id basename dirname readlink sleep printf env; do
    if real_path=$(type -P "$tool" 2>/dev/null); then
      ln -sf "$real_path" "$case_dir/sysbin/$tool"
    fi
  done

  cat > "$case_dir/sysbin/uname" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-m" && -n "${MOCK_ARCH:-}" ]]; then
  echo "$MOCK_ARCH"
else
  /usr/bin/uname "$@"
fi
EOF

  cat > "$case_dir/sysbin/dpkg" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-s" && "${2:-}" == "nodejs" ]]; then
  [[ -f "$MOCK_STATE/pkg_nodejs_installed" ]] && exit 0 || exit 1
fi
exit 1
EOF

  # mock pkg：真实安装/卸载 avail 里的包到 prefix/bin
  cat > "$case_dir/prefix/bin/pkg" <<'EOF'
#!/usr/bin/env bash
echo "pkg $*" >> "$MOCK_LOGS/pkg.log"
cmd="${1:-}"
shift || true
if [[ "$cmd" == "--check-mirror" ]]; then
  cmd="${1:-}"
  shift || true
fi
case "$cmd" in
  update|upgrade)
    exit 0
    ;;
  install)
    for arg in "$@"; do
      case "$arg" in
        -*) continue ;;
        nodejs-lts)
          ln -sf "$MOCK_AVAIL/node24" "$PREFIX/bin/node"
          rm -f "$MOCK_STATE/pkg_nodejs_installed"
          ;;
        npm|git|nano|curl|esbuild)
          ln -sf "$MOCK_AVAIL/$arg" "$PREFIX/bin/$arg"
          ;;
      esac
    done
    exit 0
    ;;
  uninstall)
    for arg in "$@"; do
      if [[ "$arg" == "nodejs" ]]; then
        rm -f "$PREFIX/bin/node" "$MOCK_STATE/pkg_nodejs_installed"
      fi
    done
    exit 0
    ;;
esac
EOF

  cat > "$case_dir/avail/node24" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "-v" ]] && echo "v24.22.3"
exit 0
EOF

  cat > "$case_dir/avail/node18" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "-v" ]] && echo "v18.20.0"
exit 0
EOF

  cat > "$case_dir/avail/npm" <<'EOF'
#!/usr/bin/env bash
echo "npm $*" >> "$MOCK_LOGS/npm.log"
[[ "${1:-}" == "-v" ]] && echo "10.9.2"
exit 0
EOF

  cat > "$case_dir/avail/esbuild" <<'EOF'
#!/usr/bin/env bash
echo "0.28.2"
EOF

  cat > "$case_dir/avail/nano" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

  cat > "$case_dir/avail/curl" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
  echo "curl 8.5.0"
  exit 0
fi
out_file=""
write_fmt=""
url=""
while (( $# > 0 )); do
  case "$1" in
    -o) out_file="$2"; shift 2 ;;
    -w) write_fmt="$2"; shift 2 ;;
    --connect-timeout|--max-time) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done

code="000"
secs="9.999"
body=""

case "$url" in
  https://mirrors.tuna.tsinghua.edu.cn/*) code="200"; secs="0.045" ;;
  https://mirrors.sustech.edu.cn/*) code="200"; secs="0.180" ;;
  https://ghfast.top/*git-upload-pack*) code="200"; secs="0.020"; body="<html>fake error page</html>" ;;
  https://gh-proxy.com/*git-upload-pack*) code="200"; secs="0.090"; body="001e# service=git-upload-pack" ;;
  https://ghproxy.net/*git-upload-pack*) code="000"; secs="4.000" ;;
  https://gitclone.com/*git-upload-pack*) code="200"; secs="0.320"; body="001e# service=git-upload-pack" ;;
  https://github.com/*git-upload-pack*) code="200"; secs="0.550"; body="001e# service=git-upload-pack" ;;
  https://registry.npmmirror.com/*) code="200"; secs="0.060" ;;
  https://mirrors.cloud.tencent.com/*) code="200"; secs="0.210" ;;
  https://repo.huaweicloud.com/*) code="000"; secs="4.000" ;;
  https://registry.npmjs.org/*) code="000"; secs="4.000" ;;
esac

if [[ -n "$out_file" ]]; then
  printf '%s' "$body" > "$out_file"
fi
if [[ -n "$write_fmt" ]]; then
  printf '%s %s' "$code" "$secs"
fi
[[ "$code" == "200" ]]
EOF

  cat > "$case_dir/avail/git" <<'EOF'
#!/usr/bin/env bash
echo "git $*" >> "$MOCK_LOGS/git.log"
if [[ "${1:-}" == "--version" ]]; then
  echo "git version 2.45.0"
  exit 0
fi
args=("$@")
i=0
subcmd=""
while (( i < ${#args[@]} )); do
  case "${args[$i]}" in
    -c|-C) ((i += 2)) ;;
    -*) ((i += 1)) ;;
    *) subcmd="${args[$i]}"; break ;;
  esac
done

if [[ "$subcmd" == "clone" ]]; then
  target="${args[$((${#args[@]} - 1))]}"
  mkdir -p "$target/.git" "$target/default" "$target/data"
  echo "console.log('st');" > "$target/server.js"
  echo '{"name":"sillytavern","version":"1.19.0"}' > "$target/package.json"
  echo '#!/usr/bin/env bash' > "$target/start.sh"
  cat > "$target/default/config.yaml" <<'YAML'
listen: false
listenAddress:
  ipv4: 0.0.0.0
browserLaunch:
  enabled: true
ssl:
  enabled: false
backups:
  chat:
    enabled: true
performance:
  lazyLoadCharacters: false
  useDiskCache: true
YAML
  exit 0
fi

if [[ "$subcmd" == "--version" ]]; then
  echo "git version 2.45.0"
  exit 0
fi
if [[ "$subcmd" == "remote" && "${args[$((i+1))]:-}" == "get-url" ]]; then
  echo "https://github.com/SillyTavern/SillyTavern.git"
  exit 0
fi
if [[ "$subcmd" == "rev-parse" ]]; then
  if [[ "$*" == *"--abbrev-ref"* ]]; then
    echo "${MOCK_BRANCH:-release}"
  else
    echo "abc1234"
  fi
  exit 0
fi
exit 0
EOF

  chmod +x "$case_dir/prefix/bin/pkg" "$case_dir/sysbin/"* "$case_dir/avail/"*
}

run_as_nobody() {
  local case_dir="$1"
  shift
  su -s /bin/bash nobody -c "
    export HOME='$case_dir/home'
    export PREFIX='$case_dir/prefix'
    export PATH='$case_dir/prefix/bin:$case_dir/sysbin'
    export MOCK_LOGS='$case_dir/logs'
    export MOCK_STATE='$case_dir/state'
    export MOCK_AVAIL='$case_dir/avail'
    export MOCK_ARCH='${MOCK_ARCH:-aarch64}'
    export MOCK_BRANCH='${MOCK_BRANCH:-release}'
    $*
  "
}

echo "=== 1. 静态与 CLI 基础检查 ==="
bash -n "$SCRIPT" && pass "bash -n 语法检查" || fail "bash -n 语法检查"
shellcheck -s bash "$SCRIPT" && pass "shellcheck -s bash 严格检查" || fail "shellcheck 检查"

help_out=$(bash "$SCRIPT" --help)
assert_contains "$help_out" "st-termux v" "--help 输出版本头部"
ver_out=$(bash "$SCRIPT" --version)
assert_contains "$ver_out" "st-termux " "--version 输出版本号"

if bash "$SCRIPT" --unknown-flag >/dev/null 2>&1; then
  fail "未知参数应返回非零退出码"
else
  pass "未知参数返回非零退出码"
fi

echo "=== 2. root 与非 Termux 拦截检查 ==="
if root_out=$(bash "$SCRIPT" install -y 2>&1); then
  fail "root 用户运行 install 应被拒绝"
else
  assert_contains "$root_out" "root" "root 用户拦截提示清晰"
fi

c_notermux="$TEST_ROOT/notermux"
setup_sandbox "$c_notermux"
if nt_out=$(su -s /bin/bash nobody -c "export HOME='$c_notermux/home' PREFIX='$c_notermux/missing' PATH='/usr/bin:/bin'; bash '$SCRIPT' install -y" 2>&1); then
  fail "缺少 pkg 与 PREFIX 应拒绝执行"
else
  assert_contains "$nt_out" "pkg" "非 Termux 环境拦截提示清晰"
fi

echo "=== 3. 完整首次安装闭环（空环境起装 curl/git/nano/nodejs-lts/npm） ==="
c1="$TEST_ROOT/case1"
setup_sandbox "$c1"
# 预先给基础 curl，模拟 Termux 初始带 curl 但缺 git/nano/node/npm
ln -sf "$c1/avail/curl" "$c1/prefix/bin/curl"

run_as_nobody "$c1" "bash '$SCRIPT' install -y"

assert_eq "$c1/prefix/etc/termux/mirrors/chinese_mainland/mirrors.tuna.tsinghua.edu.cn" \
  "$(readlink "$c1/prefix/etc/termux/chosen_mirrors")" \
  "Termux chosen_mirrors 指向测速最快的清华镜像"

pkg_log=$(cat "$c1/logs/pkg.log")
assert_contains "$pkg_log" "install -y git nano nodejs-lts" "首次安装 git nano nodejs-lts"
assert_contains "$pkg_log" "install -y npm" "缺失 npm 时自动补装 npm 包"

git_log=$(cat "$c1/logs/git.log")
assert_contains "$git_log" "url.https://gh-proxy.com/https://github.com/.insteadOf=https://github.com/" \
  "过滤掉返回 HTML 假 200 的 ghfast，选用真正返回 pkt-line 的 gh-proxy"
assert_contains "$git_log" "clone --depth 1 --branch release --single-branch" \
  "使用浅克隆 release 分支"

npm_log=$(cat "$c1/logs/npm.log")
assert_contains "$npm_log" "--registry=https://registry.npmmirror.com" "选用最快 npmmirror 源"
assert_contains "$npm_log" "--omit=dev --ignore-scripts" "与官方 start.sh 对齐生产依赖安装参数"

cfg="$c1/home/SillyTavern/config.yaml"
assert_file_contains "$cfg" "  lazyLoadCharacters: true" "config.yaml 开启 lazyLoadCharacters"
assert_file_contains "$cfg" "  useDiskCache: false" "config.yaml 关闭 useDiskCache"
assert_file_contains "$cfg" "  enabled: false" "config.yaml 关闭 browserLaunch.enabled"

ssl_enabled=$(awk '/^ssl:/{f=1;next} /^[a-z]+:/{f=0} f && /enabled:/{print $2}' "$cfg")
chat_enabled=$(awk '/^backups:/{f=1;next} /^[a-z]+:/{f=0} f && /enabled:/{print $2}' "$cfg")
assert_eq "false" "$ssl_enabled" "ssl.enabled 保持 false 不受影响"
assert_eq "true" "$chat_enabled" "backups.chat.enabled 保持 true 不受影响"

assert_file_contains "$c1/home/.bashrc" "alias st='cd \"$c1/home/SillyTavern\" && bash start.sh'" "bashrc 写入 st 别名"
assert_file_contains "$c1/home/.bashrc" "alias stup='st-termux update" "bashrc 写入 stup 更新别名"
[[ -x "$c1/home/.local/bin/st-termux" ]] && pass "CLI 脚本缓存到 ~/.local/bin/st-termux 且可执行" || fail "st-termux 未就位"

echo "=== 4. 重复安装幂等性、用户数据保护与分支切换更新 ==="
echo "user_secret_card" > "$c1/home/SillyTavern/data/card.json"
echo "# custom comment" >> "$cfg"
run_as_nobody "$c1" "bash '$SCRIPT' install -y --no-perf"

assert_file_contains "$c1/home/SillyTavern/data/card.json" "user_secret_card" "重装/更新保留 data/ 用户数据"
assert_file_contains "$cfg" "# custom comment" "指定 --no-perf 时保留用户 config.yaml"
block_count=$(grep -c '# >>> st-termux >>>' "$c1/home/.bashrc")
assert_eq "1" "$block_count" "重复运行后 bashrc 快捷指令块不重复"

: > "$c1/logs/git.log"
run_as_nobody "$c1" "bash '$SCRIPT' update -b staging -y"
git_upd_log=$(cat "$c1/logs/git.log")
assert_contains "$git_upd_log" "remote set-branches origin staging" "浅克隆切换分支时先更新 remote set-branches"
assert_contains "$git_upd_log" "fetch --depth 1 origin staging" "浅克隆切换分支拉取目标分支"

echo "=== 5. 非空非酒馆目录保护 ==="
mkdir -p "$c1/home/OccupiedDir"
echo "keep me" > "$c1/home/OccupiedDir/important.txt"
if run_as_nobody "$c1" "bash '$SCRIPT' install -y -d '$c1/home/OccupiedDir'" >/dev/null 2>&1; then
  fail "非酒馆非空目录应拒绝安装"
else
  assert_file_contains "$c1/home/OccupiedDir/important.txt" "keep me" "非酒馆非空目录拒绝覆盖且文件完好"
fi

echo "=== 6. 32 位 ARM + 旧版 Node v18 自动升级与 esbuild 补全 ==="
c2="$TEST_ROOT/case2"
setup_sandbox "$c2"
ln -sf "$c2/avail/curl" "$c2/prefix/bin/curl"
ln -sf "$c2/avail/git" "$c2/prefix/bin/git"
ln -sf "$c2/avail/nano" "$c2/prefix/bin/nano"
ln -sf "$c2/avail/node18" "$c2/prefix/bin/node"
touch "$c2/state/pkg_nodejs_installed"

MOCK_ARCH=armv7l run_as_nobody "$c2" "bash '$SCRIPT' install -y --network official --no-perf --no-alias"

pkg_log2=$(cat "$c2/logs/pkg.log")
assert_contains "$pkg_log2" "uninstall -y nodejs" "检测到旧版 nodejs v18 时自动卸载"
assert_contains "$pkg_log2" "install -y esbuild nodejs-lts" "32位 ARM 自动补装 esbuild 与 nodejs-lts"

echo "=== 7. YAML 顶层 listen 切换与 doctor 诊断验证 ==="
doc_out=$(run_as_nobody "$c1" "bash '$SCRIPT' doctor")
assert_contains "$doc_out" "基础运行环境检查通过" "已安装环境 doctor 通过"

# 在子 shell 中加载函数（去掉末尾 main "$@"）直接验证 toggle_lan_listen 精确修改顶层 listen
lan_out=$(su -s /bin/bash nobody -c "
  export HOME='$c1/home' PREFIX='$c1/prefix'
  bash -c '
    set -euo pipefail
    source <(sed \"\\\$d\" \"$SCRIPT\")
    toggle_lan_listen \"$c1/home/SillyTavern\" true
  '
")
assert_contains "$lan_out" "listen: true" "toggle_lan_listen 输出开启提示"
assert_file_contains "$cfg" "listen: true" "config.yaml 顶层 listen 已改为 true"
assert_file_contains "$cfg" "  ipv4: 0.0.0.0" "listenAddress 子字段未被破坏"
ls "$c1/home/SillyTavern"/config.yaml.bak.* >/dev/null 2>&1 && pass "修改配置前生成了 .bak 备份" || fail "未生成配置备份"

echo "=== 8. 无 TTY 交互拦截与 Git 通道故障自动顺延 ==="
if notty_out=$(bash "$SCRIPT" </dev/null 2>&1); then
  fail "无 TTY 且无参数时应退出提示"
else
  assert_contains "$notty_out" "传入子命令" "无 TTY 且无参数时提示使用子命令"
fi

c3="$TEST_ROOT/case3"
setup_sandbox "$c3"
ln -sf "$c3/avail/curl" "$c3/prefix/bin/curl"
cat > "$c3/avail/git" <<'EOF'
#!/usr/bin/env bash
echo "git $*" >> "$MOCK_LOGS/git.log"
if [[ "${1:-}" == "--version" ]]; then
  echo "git version 2.45.0"
  exit 0
fi
if [[ "$*" == *"gh-proxy.com"* && "$*" == *"clone"* ]]; then
  # 模拟第一顺位代理 clone 阶段中断，触发自动顺延第二顺位 gitclone.com
  exit 128
fi
if [[ "$*" == *"clone"* ]]; then
  target="${@: -1}"
  mkdir -p "$target/.git" "$target/default"
  echo "console.log('st');" > "$target/server.js"
  echo '{"name":"sillytavern"}' > "$target/package.json"
  echo '#!/usr/bin/env bash' > "$target/start.sh"
  echo 'listen: false' > "$target/default/config.yaml"
  exit 0
fi
exit 0
EOF
chmod +x "$c3/avail/git"
run_as_nobody "$c3" "bash '$SCRIPT' install -y --no-perf --no-alias"
git_failover_log=$(cat "$c3/logs/git.log")
assert_contains "$git_failover_log" "gh-proxy.com" "先尝试第一顺位 gh-proxy"
assert_contains "$git_failover_log" "gitclone.com" "gh-proxy clone 失败后自动顺延第二顺位 gitclone.com"

echo "----------------------------------------"
printf '测试汇总: PASS=%d FAIL=%d\n' "$PASS_COUNT" "$FAIL_COUNT"
(( FAIL_COUNT == 0 ))
