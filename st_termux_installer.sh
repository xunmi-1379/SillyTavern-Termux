#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
#  SillyTavern Termux 一键安装 / 管理脚本
#  适用平台: Android + Termux (aarch64 / arm 32位 / x86_64)
#
#  用法:
#    bash st_termux_installer.sh              # 交互菜单（推荐）
#    bash st_termux_installer.sh --install    # 直接一键安装并启动
#    bash st_termux_installer.sh --update     # 直接更新
#    bash st_termux_installer.sh --start      # 直接启动
#    bash st_termux_installer.sh --doctor     # 环境体检
#    bash st_termux_installer.sh --uninstall  # 卸载
#
#  设计参考: 钓鱼佬的工具箱 (mc10091009/st_manager.sh)
#  本脚本仅做安装与管理，所有改动都可以通过菜单里的"卸载"还原。
# =============================================================================

# ----------------------------- 基础常量 -------------------------------------
SCRIPT_VERSION="1.0.0"
REPO_URL="https://github.com/SillyTavern/SillyTavern.git"
ST_DIR="$HOME/SillyTavern"          # 安装目录
BACKUP_DIR="$HOME/st_backups"        # 备份目录
LOG_DIR="$HOME/.st_manager"
LOG_FILE="$LOG_DIR/install.log"
SELF_PATH="$HOME/st_termux_installer.sh"
NODE_MIN_MAJOR=20                    # SillyTavern 要求 node >= 20
TAG_DISPLAY_LIMIT=10

# 颜色
if [ -t 1 ]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    BLUE='\033[0;34m'; CYAN='\033[0;36m'; PURPLE='\033[0;35m'
    BOLD='\033[1m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; PURPLE=''; BOLD=''; NC=''
fi

# ----------------------------- 输出函数 -------------------------------------
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }
step()  { echo -e "\n${CYAN}${BOLD}==> $*${NC}"; }
ok()    { echo -e "${GREEN}  ✔${NC} $*"; }
fail()  { echo -e "${RED}  ✘${NC} $*"; }

# 统一的确认提示；非交互时返回默认值
confirm() {
    local prompt="$1" default="${2:-n}" answer
    if [ ! -t 0 ]; then
        [ "$default" = "y" ]
        return
    fi
    if [ "$default" = "y" ]; then
        read -r -p "$prompt (Y/n): " answer
        answer="${answer:-y}"
    else
        read -r -p "$prompt (y/N): " answer
        answer="${answer:-n}"
    fi
    case "$answer" in [yY]|[yY][eE][sS]) return 0 ;; *) return 1 ;; esac
}

pause() {
    [ -t 0 ] && read -r -p "按回车键继续..." _ || true
}

die() { error "$*"; exit 1; }

# 记录日志（安装过程中的关键输出也进日志，方便排查）
log() {
    mkdir -p "$LOG_DIR" 2>/dev/null
    echo "[$(date '+%F %T')] $*" >> "$LOG_FILE" 2>/dev/null
}

# --------------------------- 环境 / 平台检测 ---------------------------------
detect_platform() {
    IS_TERMUX=0
    if [ -n "$TERMUX_VERSION" ] || [ -d /data/data/com.termux ]; then
        IS_TERMUX=1
    fi

    case "$(uname -m)" in
        aarch64|arm64)   ARCH="aarch64" ;;
        armv7*|armv8l)   ARCH="arm" ;;
        x86_64|amd64)    ARCH="x86_64" ;;
        i?86)            ARCH="i686" ;;
        *)               ARCH="$(uname -m)" ;;
    esac

    PKG_MIRROR=""; BRANCH_MIRROR=""; NPM_MIRROR=""
}

# ARP 版本（名词形式）>= 要求版本？
ver_ge() {
    local IFS=.
    local -a a=($1) b=($2)
    local i
    for ((i = 0; i < 3; i++)); do
        local x="${a[$i]:-0}" y="${b[$i]:-0}"
        x="${x%%[!0-9]*}"; y="${y%%[!0-9]*}"
        x="${x:-0}"; y="${y:-0}"
        if [ "$x" -gt "$y" ]; then return 0; fi
        if [ "$x" -lt "$y" ]; then return 1; fi
    done
    return 0
}

node_major_ok() {
    command -v node > /dev/null 2>&1 || return 1
    local v major
    v="$(node -v 2>/dev/null | sed 's/^v//')"
    [ -n "$v" ] || return 1
    major="${v%%.*}"
    [[ "$major" =~ ^[0-9]+$ ]] || return 1
    [ "$major" -ge "$NODE_MIN_MAJOR" ]
}

# Termux 里 pkg 也可能叫 apt；统一封装，保证非交互（-y）不出卡住
pkg_install() {
    if command -v pkg > /dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive pkg install -y "$@"
    else
        DEBIAN_FRONTEND=noninteractive apt install -y "$@"
    fi
}

# ----------------------------- 依赖安装 -------------------------------------
install_termux_deps() {
    if [ "$IS_TERMUX" -ne 1 ]; then
        warn "当前不在 Termux 中，跳过 Termux 软件包安装。"
        warn "如果你在普通 Linux 上，请自行安装 git/nodejs(>=20)/npm。"
        return 0
    fi

    if [ "$(id -u)" = "0" ]; then
        die "检测到 root 用户。请以普通用户身份运行（Termux 默认如此），root 会导致权限错乱。"
    fi

    step "1/4 检查并安装系统依赖(会自动确认)"

    # 首次运行建议换源（国内网络连官方源经常卡）
    if [ -z "$PKG_MIRROR" ] && [ -t 0 ] && ! grep -q "mirrors.tuna\|mirrors.ustc\|mirrors.bfsu" "$PREFIX/etc/apt/sources.list" 2>/dev/null; then
        if confirm "检测到使用 Termux 官方源。国内网络建议换成中科大/清华镜像，要现在换吗？" n; then
            if command -v termux-change-repo > /dev/null 2>&1; then
                warn "termux-change-repo 是交互界面，请选择 [Mirror group] 后选镜像，完成后回到本脚本。"
                termux-change-repo || true
            else
                set_termux_mirror
            fi
        fi
    fi

    info "正在更新软件包索引 (pkg update)..."
    if ! DEBIAN_FRONTEND=noninteractive pkg update -y; then
        warn "pkg update 失败。可能是镜像源不可用或网络被墙。"
        if confirm "是否自动切换到国内镜像源(中科大)后重试？" y; then
            set_termux_mirror
            DEBIAN_FRONTEND=noninteractive pkg update -y || die "更新索引仍然失败，请检查网络后重试。"
        else
            die "无法更新软件包索引。"
        fi
    fi

    # 检查核心包；缺哪个装哪个，比无脑 pkg upgrade 更快、更不容易出问题
    local need=()
    command -v git  > /dev/null 2>&1 || need+=(git)
    command -v node > /dev/null 2>&1 || need+=(nodejs-lts)
    command -v npm  > /dev/null 2>&1 || need+=(nodejs-lts)

    # 32 位 ARM 需要额外的 esbuild（Termux 无法从 npm 下载 arm 预编译包）
    if [ "$ARCH" = "arm" ] && ! command -v esbuild > /dev/null 2>&1; then
        need+=(esbuild)
    fi

    # 辅助工具：进程/端口排查(psmisc=pgrep/fuser, procps=ps, lsof=端口占用)
    command -v pgrep  > /dev/null 2>&1 || need+=(psmisc)
    command -v fuser  > /dev/null 2>&1 || need+=(psmisc)
    command -v lsof   > /dev/null 2>&1 || need+=(lsof)

    # 去重
    if [ ${#need[@]} -gt 0 ]; then
        local -a uniq=()
        local p s dup
        for p in "${need[@]}"; do
            dup=0
            for s in "${uniq[@]}"; do [ "$s" = "$p" ] && dup=1; done
            [ $dup -eq 0 ] && uniq+=("$p")
        done
        info "需要安装: ${uniq[*]}"
        pkg_install "${uniq[@]}" || warn "部分软件包安装失败，继续尝试。"
    else
        ok "系统软件包已齐全。"
    fi

    # 显式指定了镜像源时，npm 也用同一个（可选）
    if [ -n "$NPM_MIRROR" ]; then
        if command -v npm > /dev/null 2>&1; then
            npm config set registry "$NPM_MIRROR" > /dev/null 2>&1 && ok "npm 源已设置: $NPM_MIRROR"
        fi
    fi

    hash -r 2>/dev/null || true
}

set_termux_mirror() {
    local f="$PREFIX/etc/apt/sources.list"
    [ -f "$f" ] || { warn "找不到 $f，跳过换源。"; return 1; }
    cp "$f" "${f}.bak.$(date +%s)" 2>/dev/null
    local m="${PKG_MIRROR:-https://mirrors.ustc.edu.cn/termux/termux-main}"
    if echo "$m" | grep -q "termux-main"; then
        echo "deb $m stable main" > "$f"
    else
        echo "deb $m/termux-main stable main" > "$f"
    fi
    ok "已切换软件源为: $m （原文件已备份）"
}

ensure_node_version() {
    step "检查 Node.js 版本 (SillyTavern 要求 >= ${NODE_MIN_MAJOR})"

    if ! command -v node > /dev/null 2>&1; then
        info "未检测到 Node.js，正在安装 nodejs-lts..."
        pkg_install nodejs-lts || true
        hash -r 2>/dev/null || true
    fi

    if node_major_ok; then
        ok "Node.js $(node -v)，npm $(npm -v 2>/dev/null)"
        return 0
    fi

    warn "当前 Node.js 版本 ($(node -v 2>/dev/null || echo 未安装)) 不满足要求。"
    info "正在升级 nodejs-lts..."
    if command -v pkg > /dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive pkg upgrade -y nodejs-lts || pkg_install nodejs-lts || true
        # 卸载旧 nodejs 包，避免两个包互相打架
        if [ "$(command -v node)" = "$PREFIX/bin/node" ]; then
            DEBIAN_FRONTEND=noninteractive pkg uninstall -y nodejs > /dev/null 2>&1 || true
        fi
        hash -r 2>/dev/null || true
    fi

    if node_major_ok; then
        ok "已升级到 Node.js $(node -v)"
        return 0
    fi

    error "Node.js 仍然不是 >= ${NODE_MIN_MAJOR} 版本。"
    echo -e "  请手动执行: ${GREEN}pkg update && pkg upgrade nodejs-lts${NC}"
    echo -e "  注意: termux 的官方源是唯一可靠的升级途径，别用 nvm/n 在 Termux 里折腾。"
    return 1
}

# ----------------------------- 代码拉取 -------------------------------------
# GitHub 直连失败时的常见加速前缀（国内网络）
GH_PROXIES=(
    "https://ghfast.top/"
    "https://gh-proxy.com/"
    "https://ghproxy.net/"
)

# 依次尝试: 用户指定镜像 -> 官方 -> 各加速前缀。返回 0 表示成功。
clone_repo() {
    local dest="$1" branch="${2:-release}"
    local -a urls=()
    [ -n "$BRANCH_MIRROR" ] && urls+=("$BRANCH_MIRROR")
    urls+=("$REPO_URL")
    local p
    for p in "${GH_PROXIES[@]}"; do urls+=("${p}${REPO_URL}"); done

    local url
    for url in "${urls[@]}"; do
        info "正在克隆 ($branch): $url"
        rm -rf "$dest"
        if git -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=60 \
               clone -b "$branch" --depth 1 "$url" "$dest" 2>&1 | tee -a "$LOG_FILE" | tail -n 15; then
            if [ -d "$dest/.git" ]; then
                ok "克隆成功。"
                return 0
            fi
        fi
        warn "该地址失败，尝试下一个... (Ctrl+C 可中止)"
    done
    rm -rf "$dest"
    return 1
}

# ----------------------------- 版本选择 -------------------------------------
list_tags() {
    git -C "$ST_DIR" tag --sort=-creatordate 2>/dev/null | head -n "$TAG_DISPLAY_LIMIT"
}

choose_branch() {
    # 输出: release / staging / tag:<name>
    local tags=()
    mapfile -t tags < <(list_tags)
    local n=${#tags[@]} i

    echo -e "\n请选择版本:"
    echo -e "  ${GREEN}1${NC}. release 分支 ${YELLOW}(推荐，稳定版)${NC}"
    echo -e "  ${GREEN}2${NC}. staging 分支 (体验最新功能，可能不稳定)"
    if [ "$n" -gt 0 ]; then
        echo -e "  ${GREEN}3${NC}. 指定 Tag 版本 (回退到旧版)"
        echo "最近的 Tag:"
        for ((i = 0; i < n; i++)); do printf "     %2d) %s\n" $((i + 1)) "${tags[$i]}"; done
    fi
    read -r -p "请输入 [1-2]: " c
    case "${c:-1}" in
        2) echo "staging" ;;
        3)
            if [ "$n" -eq 0 ]; then echo "release"; return; fi
            read -r -p "输入序号或完整 Tag: " t
            if [[ "$t" =~ ^[0-9]+$ ]] && [ "$t" -ge 1 ] && [ "$t" -le "$n" ]; then
                echo "tag:${tags[$((t - 1))]}"
            elif [ -n "$t" ]; then
                echo "tag:$t"
            else
                echo "release"
            fi
            ;;
        *) echo "release" ;;
    esac
}

checkout_branch() {
    local target="$1"

    if [ -d "$ST_DIR/.git" ]; then
        git -C "$ST_DIR" fetch --depth 1 origin 2>/dev/null || git -C "$ST_DIR" fetch origin 2>/dev/null || true
    fi

    case "$target" in
        tag:*)
            local t="${target#tag:}"
            if git -C "$ST_DIR" fetch --depth 1 origin "refs/tags/$t:refs/tags/$t" 2>/dev/null || \
               git -C "$ST_DIR" fetch --tags 2>/dev/null; then
                git -C "$ST_DIR" checkout -q "tags/$t" 2>/dev/null && return 0
            fi
            warn "切换 Tag $t 失败，回退 release 分支。"
            git -C "$ST_DIR" checkout -q -B release origin/release
            ;;
        staging)
            git -C "$ST_DIR" checkout -q -B staging origin/staging 2>/dev/null || \
            git -C "$ST_DIR" checkout -q -B main origin/main
            ;;
        *)
            git -C "$ST_DIR" checkout -q -B release origin/release 2>/dev/null || \
            git -C "$ST_DIR" checkout -q -B main origin/main
            ;;
    esac
}

# ----------------------------- 依赖安装(npm) --------------------------------
npm_install_deps() {
    step "安装 npm 依赖 (这一步最慢，请耐心等待，20~40 分钟也正常)"

    [ -d "$ST_DIR" ] || die "安装目录不存在: $ST_DIR"
    cd "$ST_DIR" || die "无法进入 $ST_DIR"

    if [ -n "$NPM_MIRROR" ]; then
        npm config set registry "$NPM_MIRROR" > /dev/null 2>&1
    fi

    [ -f package.json ] || die "没有找到 package.json，目录可能不完整。"

    # 与官方 start.sh 保持一致，但更省内存
    info "正在执行 npm install ..."
    local st
    set -o pipefail
    DEBIAN_FRONTEND=noninteractive NODE_ENV=production npm install \
        --no-audit --no-fund --no-progress --omit=dev 2>&1 | tee -a "$LOG_FILE" | tail -n 20
    st=$?
    set +o pipefail

    if [ "$st" -ne 0 ]; then
        warn "npm install 失败 (退出码 $st)。"
        # 内存不足是最常见原因，给出明确提示
        if grep -qi "heap out of memory\|ENOMEM\|Killed" "$LOG_FILE" 2>/dev/null; then
            error "看起来是手机内存不足导致 npm 被杀。"
            echo -e "  建议: 关掉其他后台APP后重试；或设置 ${GREEN}NODE_OPTIONS=--max-old-space-size=1024${NC} 再运行。"
        fi
        return 1
    fi

    [ -d node_modules ] || { error "node_modules 未生成，依赖安装失败。"; return 1; }
    ok "依赖安装完成。"
    return 0
}

ensure_deps_installed() {
    [ -d "$ST_DIR/node_modules" ] && return 0
    warn "检测到 node_modules 缺失，需要安装依赖。"
    npm_install_deps || die "依赖安装失败，请稍后在菜单中选 [5] 重装依赖。"
}

# ----------------------------- 配置生成 -------------------------------------
# 从现有 config.yaml 读出某个顶层 key 的值
config_get() {
    local key="$1" f="$ST_DIR/config.yaml"
    [ -f "$f" ] || return 1
    awk -v k="$key" '
        $0 ~ "^"k":" {
            sub("^"k":[ \t]*", "");
            gsub(/["'"'"']/, "");
            print; exit
        }' "$f"
}

config_set() {
    local key="$1" value="$2" f="$ST_DIR/config.yaml"
    [ -f "$f" ] || return 1
    if grep -q "^${key}:" "$f"; then
        sed -i "s|^${key}:.*|${key}: ${value}|" "$f"
    else
        printf '%s: %s\n' "$key" "$value" >> "$f"
    fi
}

# 缩进感知的 YAML 块定位器（供 yaml_set_leaf / yaml_add_key 使用）
# 思路: 找到顶层 "parent:" 行，块范围是其后所有缩进更深的行
YAML_AWK_LIB='
function indent_of(s,   i, n, c) {
    n = 0
    for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (c == " ") { n = n + 1 }
        else if (c == "\t") { n = n + 4 }
        else { break }
    }
    return n
}
# 生成 n 个空格的缩进前缀（不用 substr，避免长参数 bug）
function pad(n,   x, k) {
    x = ""
    for (k = 0; k < n; k++) { x = x " " }
    return x
}
function is_blank(s) { return (s ~ /^[ \t]*$/) }
function block_end(start, base,   j, ind) {
    for (j = (start + 1); j <= N; j++) {
        if (is_blank(L[j])) { continue }
        ind = indent_of(L[j])
        if (ind <= base) { return (j - 1); }
    }
    return N;
}
'

# 修改 parent 块下 key 的值；没有就插到块末尾（缩进感知，保留用户已有设置）
yaml_set_leaf() {
    local f="$1" parent="$2" key="$3" val="$4"
    [ -f "$f" ] || return 1
    awk -v parent="$parent" -v key="$key" -v val="$val" "$YAML_AWK_LIB$(cat <<'AWK'
{ L[NR] = $0 } END {
    N = NR; ps = 0; res_n = 0
    for (i = 1; i <= N; i++)
        if (L[i] ~ ("^" parent ":[ \t]*$")) { ps = i; break }
    if (ps == 0) {
        for (i = 1; i <= N; i++) { R[++res_n] = L[i] }
        R[++res_n] = parent ":"
        R[++res_n] = "  " key ": " val
        for (i = 1; i <= res_n; i++) { print R[i] }
        exit
    }
    pe = block_end(ps, 0)
    child = indent_of(L[ps]) + 2
    for (j = (ps + 1); j <= pe; j++)
        if (!is_blank(L[j])) { child = indent_of(L[j]); break }
    pre = pad(child)
    kpos = -1
    for (j = (ps + 1); j <= pe; j++)
        if (indent_of(L[j]) == child && L[j] ~ ("^[ \t]+" key ":")) { kpos = j; break }
    for (i = 1; i <= N; i++) {
        if (i == kpos) { R[++res_n] = pre key ": " val }
        else if (kpos < 0 && i == (pe + 1)) { R[++res_n] = pre key ": " val; R[++res_n] = L[i] }
        else { R[++res_n] = L[i] }
    }
    if (kpos < 0 && pe == N) { R[++res_n] = pre key ": " val }
    for (i = 1; i <= res_n; i++) { print R[i] }
}
AWK
)" "$f" > "$f.tmp.$$" && mv "$f.tmp.$$" "$f"
}

# 在 parent 块下补个键(仅当不存在)
yaml_add_key() {
    local f="$1" parent="$2" key="$3" val="$4"
    [ -f "$f" ] || return 1
    awk -v parent="$parent" -v key="$key" -v val="$val" "$YAML_AWK_LIB$(cat <<'AWK'
{ L[NR] = $0 } END {
    N = NR; ps = 0; res_n = 0
    for (i = 1; i <= N; i++)
        if (L[i] ~ ("^" parent ":[ \t]*$")) { ps = i; break }
    if (ps == 0) {
        for (i = 1; i <= N; i++) { R[++res_n] = L[i] }
        R[++res_n] = parent ":"
        R[++res_n] = "  " key ": " val
        for (i = 1; i <= res_n; i++) { print R[i] }
        exit
    }
    pe = block_end(ps, 0)
    child = indent_of(L[ps]) + 2
    for (j = (ps + 1); j <= pe; j++)
        if (!is_blank(L[j])) { child = indent_of(L[j]); break }
    exists = 0
    for (j = (ps + 1); j <= pe; j++)
        if (indent_of(L[j]) == child && L[j] ~ ("^[ \t]+" key ":")) { exists = 1 }
    if (exists) { for (i = 1; i <= N; i++) { print L[i] }; exit }
    for (i = 1; i <= N; i++) {
        if (i == (pe + 1)) { R[++res_n] = pad(child) key ": " val }
        R[++res_n] = L[i]
    }
    if (pe == N) { R[++res_n] = pad(child) key ": " val }
    for (i = 1; i <= res_n; i++) { print R[i] }
}
AWK
)" "$f" > "$f.tmp.$$" && mv "$f.tmp.$$" "$f"
}

setup_config() {
    step "初始化配置文件 config.yaml"
    local f="$ST_DIR/config.yaml"
    local def="$ST_DIR/default/config.yaml"

    if [ -f "$f" ]; then
        ok "已存在 config.yaml，保留你的原有配置(不会覆盖)。"
    else
        if [ -f "$def" ]; then
            cp "$def" "$f"
        elif [ -f "$ST_DIR/default/config.yaml" ]; then
            cp "$ST_DIR/default/config.yaml" "$f"
        else
            printf 'port: 8000\nlisten: false\nlistenAddress:\n' > "$f"
        fi
        ok "已从默认模板生成 config.yaml。"
    fi

    # 移动端性能建议（官方 Termux 文档推荐），只在首次初始化时问一次
    if [ -f "$ST_DIR/.st_manager_configured" ]; then
        return 0
    fi

    if confirm "是否套用[安卓性能优化配置]？(延迟加载角色、关闭磁盘缓存、关闭聊天自动备份)" y; then
        yaml_add_key "$f" performance lazyLoadCharacters true
        yaml_add_key "$f" performance useDiskCache false
        yaml_add_key "$f" backups enabled false
        yaml_set_leaf "$f" backups enabled false
        if ! grep -q "^backups:" "$f"; then
            warn "未能自动写入 backups 配置，可在菜单 [4] 后手动编辑 config.yaml。"
        fi
        ok "已套用安卓性能优化配置 (已有的个人设置不会被覆盖)。"
    fi

    # 手机默认只允许本机访问；需要局域网访问再手动改
    if [ "$(config_get listen 2>/dev/null)" != "true" ]; then
        if confirm "是否允许局域网访问？(手机上的其他设备可以连，不需要就选 n)" n; then
            config_set listen true
            config_set listenAddress 0.0.0.0
            ok "已开启局域网访问 (0.0.0.0)。"
            warn "局域网访问务必开启账号密码/白名单，勿暴露到公网。"
        fi
    fi

    touch "$ST_DIR/.st_manager_configured"
}

get_port() {
    local p
    p="$(config_get port 2>/dev/null)"
    [[ "$p" =~ ^[0-9]+$ ]] && echo "$p" || echo "8000"
}

port_owner_pids() {
    local port="$1" pids=""
    if command -v fuser > /dev/null 2>&1; then
        pids="$(fuser "$port/tcp" 2>/dev/null)"
    fi
    if [ -z "$pids" ] && command -v lsof > /dev/null 2>&1; then
        pids="$(lsof -t -i ":$port" 2>/dev/null)"
    fi
    if [ -z "$pids" ] && command -v pgrep > /dev/null 2>&1; then
        pids="$(pgrep -f "node .*server\.js" 2>/dev/null)"
    fi
    echo "$pids" | tr '\n' ' ' | tr -s ' '
}

# ----------------------------- 核心安装流程 ---------------------------------
do_install() {
    local auto_start="${1:-ask}"
    log "start install, arch=$ARCH termux=$IS_TERMUX"

    detect_platform
    install_termux_deps
    ensure_node_version || die "Node.js 版本不满足要求，安装中止。"

    if [ -d "$ST_DIR" ]; then
        warn "安装目录已存在: $ST_DIR"
        if [ -f "$ST_DIR/server.js" ]; then
            info "检测到已有 SillyTavern，转为『修复/重装依赖』模式，不会删除你的角色卡和聊天记录。"
            ensure_deps_installed || return 1
            setup_config
            ok "现有安装已修复完成。"
            [ "$auto_start" != "no" ] && start_st
            return 0
        fi
        if confirm "目录存在但不是有效的 SillyTavern，是否清空重装？(会删除 $ST_DIR)" n; then
            rm -rf "$ST_DIR"
        else
            info "已取消。"
            return 1
        fi
    fi

    step "2/4 获取 SillyTavern 代码"
    local target="release"
    if [ -t 0 ]; then
        target="$(choose_branch)"
    else
        info "非交互模式，使用 release 分支。"
    fi

    local branch="release"
    [ "$target" = "staging" ] && branch="staging"

    if ! clone_repo "$ST_DIR" "$branch"; then
        error "克隆失败。可能是 GitHub 被墙或网络不稳。"
        echo -e "  解决办法(任选其一):"
        echo -e "    ${GREEN}1)${NC} 手动换源后重试: 主菜单 [8] 切换软件源/镜像"
        echo -e "    ${GREEN}2)${NC} 用代理: export https_proxy=http://127.0.0.1:7890 后再运行"
        echo -e "    ${GREEN}3)${NC} 直接改 hosts/使用加速器 (如 ghproxy)"
        return 1
    fi
    ok "代码获取完成。"
    git -C "$ST_DIR" fetch --tags > /dev/null 2>&1 || true

    if [[ "$target" == tag:* ]]; then
        checkout_branch "$target" && ok "已切换到 Tag ${target#tag:}"
    elif [ "$target" = "staging" ]; then
        checkout_branch staging && ok "已切换到 staging 分支。"
    fi

    step "3/4 安装依赖"
    npm_install_deps || {
        error "依赖安装失败。常见原因: 内存不足 / 网络超时 / 32 位设备缺 esbuild。"
        echo -e "  排查建议: 主菜单 [6] 环境体检，或 [5] 重装依赖。"
        return 1
    }

    step "4/4 初始化配置与快捷命令"
    setup_config
    install_alias
    ok "安装完成！"
    log "install ok"

    if [ "$auto_start" = "restart" ]; then
        start_st
    elif [ "$auto_start" != "no" ]; then
        if [ "$auto_start" = "yes" ] || confirm "现在启动 SillyTavern 吗？" y; then
            start_st
        fi
    fi
    return 0
}

start_st() {
    [ -d "$ST_DIR/server.js" ] || [ -f "$ST_DIR/server.js" ] || { error "SillyTavern 未安装，请先安装。"; pause; return 1; }

    local port pids
    port="$(get_port)"
    pids="$(port_owner_pids "$port")"
    if [ -n "$pids" ]; then
        warn "端口 $port 已被占用 (PID: $pids)。"
        if confirm "是否结束这些进程后再启动？" y; then
            local pid
            for pid in $pids; do kill "$pid" 2>/dev/null; done
            sleep 2
            for pid in $(port_owner_pids "$port"); do kill -9 "$pid" 2>/dev/null; done
        fi
    fi

    ensure_deps_installed || return 1

    echo -e "\n${CYAN}--------------------------------------------------${NC}"
    echo -e "${BOLD} SillyTavern 启动中${NC}"
    echo -e " 访问地址: ${GREEN}http://127.0.0.1:${port}${NC}"
    echo -e " 手机浏览器打开上面地址即可使用；按 ${YELLOW}Ctrl+C${NC} 停止服务。"
    echo -e "${CYAN}--------------------------------------------------${NC}\n"

    cd "$ST_DIR" || return 1
    [ -f start.sh ] && exec bash start.sh "$@" || exec node server.js "$@"
}

# ----------------------------- 更新 / 回退 ----------------------------------
do_update() {
    [ -f "$ST_DIR/server.js" ] || die "SillyTavern 未安装，请先安装。"
    log "update"

    local cur
    cur="$(git -C "$ST_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null)"
    info "当前分支/版本: $cur @ $(git -C "$ST_DIR" rev-parse --short HEAD 2>/dev/null)"
    git -C "$ST_DIR" tag --sort=-creatordate 2>/dev/null | head -n 1 | sed 's/^/最新 Tag: /'

    if confirm "更新前是否先备份数据？(强烈建议)" y; then
        backup_data
    fi

    step "拉取更新"
    if ! git -C "$ST_DIR" pull --rebase --autostash; then
        warn "git pull 失败，尝试强制同步 origin/$cur ..."
        if ! git -C "$ST_DIR" fetch --all --tags; then
            die "无法连接远程仓库，请检查网络/代理。"
        fi
        if ! git -C "$ST_DIR" reset --hard "origin/$cur"; then
            error "更新失败。可能是本地有未提交的改动(通常无需在意，选 [4] 可切换版本)。"
            return 1
        fi
    fi
    ok "代码已更新。"

    step "更新依赖"
    if [ -f package-lock.json ] && [ -d node_modules ]; then
        info "使用 npm install 更新(与官方 start.sh 一致)..."
    fi
    npm_install_deps || { error "依赖更新失败，可稍后用 [5] 重装依赖。"; return 1; }
    ok "更新完成。"
    log "update ok"
}

do_switch_version() {
    [ -f "$ST_DIR/server.js" ] || die "SillyTavern 未安装，请先安装。"
    git -C "$ST_DIR" fetch --all --tags > /dev/null 2>&1 || true

    echo "1. 切换到 release 分支 (推荐)"
    echo "2. 切换到 staging 分支"
    echo "3. 切换到指定 Tag"
    echo "4. 查看最近提交"
    read -r -p "请选择 [1-4]: " c
    local target=""
    case "$c" in
        1) target="release" ;;
        2) target="staging" ;;
        3)
            list_tags
            read -r -p "输入 Tag (例如 1.13.4): " t
            [ -n "$t" ] && target="tag:$t" || return 1
            ;;
        4) git -C "$ST_DIR" log -n 15 --oneline; return 0 ;;
        *) return 1 ;;
    esac

    confirm "切换版本前备份数据？" y && backup_data
    if checkout_branch "$target"; then
        ok "已切换到 $target，正在重新安装依赖..."
        npm_install_deps || warn "依赖安装未成功，可稍后用 [5] 重装。"
    else
        error "切换失败。"
    fi
}

# ----------------------------- 备份 / 恢复 ----------------------------------
backup_data() {
    [ -d "$ST_DIR" ] || { error "SillyTavern 未安装，无法备份。"; return 1; }
    mkdir -p "$BACKUP_DIR"
    local file="$BACKUP_DIR/st_backup_$(date +%Y%m%d_%H%M%S).tar.gz"
    local items=(data)
    [ -f "$ST_DIR/config.yaml" ] && items+=(config.yaml)
    [ -f "$ST_DIR/secrets.json" ] && items+=(secrets.json)
    [ -d "$ST_DIR/public/scripts/extensions/third-party" ] && items+=(public/scripts/extensions/third-party)

    info "正在备份: ${items[*]} (不含 node_modules，体积小很多)"
    if tar -czf "$file" -C "$ST_DIR" "${items[@]}" 2>/dev/null; then
        ok "备份成功: $file ($(du -h "$file" 2>/dev/null | cut -f1))"
    else
        error "备份失败。"
        return 1
    fi
}

restore_data() {
    [ -d "$ST_DIR" ] || { error "请先安装 SillyTavern。"; return 1; }
    shopt -s nullglob
    local files=("$BACKUP_DIR"/*.tar.gz "$HOME"/*.tar.gz "$HOME"/*.tgz)
    shopt -u nullglob
    [ ${#files[@]} -gt 0 ] || { warn "没有找到备份文件。"; return 1; }

    local idx=1 bk
    for bk in "${files[@]}"; do echo "  $idx) $(basename "$bk")  [$bk]"; ((idx++)); done
    read -r -p "选择要恢复的备份序号: " c
    [[ "$c" =~ ^[0-9]+$ ]] && [ "$c" -ge 1 ] && [ "$c" -le "${#files[@]}" ] || { error "无效选择。"; return 1; }
    local sel="${files[$((c - 1))]}"

    warn "恢复会覆盖当前 data / config.yaml 等文件！"
    confirm "确认继续？" n || { info "已取消。"; return 1; }
    confirm "再次确认：恢复前会先自动备份当前数据，继续？" y || return 1
    backup_data > /dev/null 2>&1 || true

    if tar -xzf "$sel" -C "$ST_DIR"; then
        ok "恢复完成，请重启 SillyTavern。"
    else
        error "恢复失败，文件可能已损坏。"
    fi
}

# ----------------------------- 健康检查 -------------------------------------
doctor() {
    step "环境体检"
    echo "  平台      : $([ "$IS_TERMUX" -eq 1 ] && echo Termux || echo 非Termux) / $ARCH"
    [ -n "$PREFIX" ] && echo "  PREFIX    : $PREFIX"
    echo "  安装目录  : $ST_DIR $([ -d "$ST_DIR" ] && echo '[存在]' || echo '[未安装]')"
    command -v node > /dev/null 2>&1 && echo "  node      : $(node -v) $(node_major_ok && echo "${GREEN}OK${NC}" || echo "${RED}需要 >= ${NODE_MIN_MAJOR}${NC}")" || echo "  node      : ${RED}未安装${NC}"
    command -v npm  > /dev/null 2>&1 && echo "  npm       : $(npm -v)" || echo "  npm       : ${RED}未安装${NC}"
    command -v git  > /dev/null 2>&1 && echo "  git       : $(git --version)" || echo "  git       : ${RED}未安装${NC}"
    if [ "$ARCH" = "arm" ]; then
        command -v esbuild > /dev/null 2>&1 && echo "  esbuild   : OK (32位设备必需)" || echo "  esbuild   : ${RED}缺失，32位设备请 pkg install esbuild${NC}"
    fi

    if [ -d "$ST_DIR" ]; then
        local port pids
        port="$(get_port)"
        pids="$(port_owner_pids "$port")"
        echo "  端口      : $port $([ -n "$pids" ] && echo "${YELLOW}被占用 PID:$pids${NC}" || echo "空闲")"
        [ -d "$ST_DIR/node_modules" ] && echo "  依赖      : 已安装 ($(du -sh "$ST_DIR/node_modules" 2>/dev/null | cut -f1))" || echo "  依赖      : ${RED}未安装${NC}"
        [ -f "$ST_DIR/config.yaml" ] && echo "  配置文件  : OK" || echo "  配置文件  : ${RED}缺失${NC}"
        if [ -d "$ST_DIR/data" ]; then
            echo "  数据目录  : $(du -sh "$ST_DIR/data" 2>/dev/null | cut -f1)"
        fi
        [ -d "$ST_DIR/.git" ] && echo "  当前版本  : $(git -C "$ST_DIR" describe --tags --always 2>/dev/null) ($(git -C "$ST_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null))"
    fi

    echo "  磁盘剩余  : $(df -h "$HOME" 2>/dev/null | awk 'NR==2{print $4" / "$2}')"
    echo "  日志文件  : $LOG_FILE"

    if [ -f "$ST_DIR/server.js" ] && ! [ -d "$ST_DIR/node_modules" ]; then
        warn "检测到代码已拉取但依赖缺失，运行主菜单 [5] 即可修复。"
    fi
    if ! node_major_ok; then
        warn "Node.js 版本不足会导致启动直接报错，请先运行主菜单 [2]。"
    fi
}

# ----------------------------- 快捷命令 / 自启 -------------------------------
install_alias() {
    local rc="$HOME/.bashrc"
    local marker="# >>> st-toolbox alias >>>"
    grep -q "$marker" "$rc" 2>/dev/null && return 0
    {
        echo ""
        echo "$marker"
        echo "alias st='cd \"\$HOME/SillyTavern\" && bash start.sh'"
        echo "alias stu='cd \"\$HOME/SillyTavern\" && git pull --rebase --autostash && npm install --omit=dev'"
        echo "alias stm='bash \"\$HOME/st_termux_installer.sh\"'"
        echo "# <<< st-toolbox alias <<<"
    } >> "$rc"
    ok "已添加快捷命令: st(启动) / stu(更新) / stm(打开本脚本)"
}

install_self() {
    # 支持 bash <(curl ...) 运行；把自己复制到 HOME 便于下次直接 stm
    local src="${BASH_SOURCE[0]}"
    [ "$src" = "$SELF_PATH" ] && return 0
    if [ -f "$src" ] && [ -r "$src" ] && case "$src" in /proc/*|/dev/fd/*) false;; *) true;; esac; then
        cp "$src" "$SELF_PATH" 2>/dev/null && chmod +x "$SELF_PATH" 2>/dev/null && \
            info "脚本已保存到 $SELF_PATH (以后可直接运行 bash ~/st_termux_installer.sh)"
    fi
}

# ----------------------------- 卸载 -----------------------------------------
do_uninstall() {
    warn "即将卸载 SillyTavern。"
    confirm "确认继续？" n || { info "已取消。"; return 1; }

    if [ -d "$ST_DIR/data" ]; then
        if confirm "卸载前是否备份 data (角色卡/聊天记录)？" y; then
            backup_data
        fi
    fi
    rm -rf "$ST_DIR" && ok "已删除 $ST_DIR"
    sed -i '/>>> st-toolbox alias >>>/,/<<< st-toolbox alias <<</d' "$HOME/.bashrc" 2>/dev/null
    ok "已清理快捷命令。备份文件保留在 $BACKUP_DIR"
}

# ----------------------------- 主菜单 ---------------------------------------
main_menu() {
    while true; do
        clear 2>/dev/null || true
        local env_state node_state port
        if command -v node > /dev/null 2>&1; then
            node_state="$(node -v)"
            node_major_ok || node_state="${RED}${node_state} (需>=${NODE_MIN_MAJOR})${NC}"
        else
            node_state="${RED}未安装${NC}"
        fi
        if [ -f "$ST_DIR/server.js" ]; then env_state="${GREEN}已安装${NC}"; else env_state="${YELLOW}未安装${NC}"; fi
        port="$(get_port)"

        echo -e "${CYAN}====================================================${NC}"
        echo -e "${BOLD}${PURPLE}  SillyTavern Termux 一键安装/管理工具${NC}  ${YELLOW}v${SCRIPT_VERSION}${NC}"
        echo -e "${CYAN}====================================================${NC}"
        echo -e " SillyTavern : $env_state    Node: $node_state"
        echo -e " 目录        : ${CYAN}$ST_DIR${NC}  端口: ${CYAN}$port${NC}"
        echo -e "${CYAN}----------------------------------------------------${NC}"
        echo -e " ${GREEN}1${NC}. 启动 SillyTavern"
        echo -e " ${GREEN}2${NC}. ${BOLD}一键安装${NC} (装依赖+装ST+初始化+启动)"
        echo -e " ${GREEN}3${NC}. 更新 SillyTavern"
        echo -e " ${GREEN}4${NC}. 切换版本 (release/staging/Tag 回退)"
        echo -e " ${GREEN}5${NC}. 重装依赖 (修复 npm 报错)"
        echo -e " ${GREEN}6${NC}. 环境体检 (doctor)"
        echo -e " ${GREEN}7${NC}. 备份 / 恢复数据"
        echo -e " ${GREEN}8${NC}. 修改端口 / 网络设置"
        echo -e " ${GREEN}9${NC}. 卸载 SillyTavern"
        echo -e " ${GREEN}0${NC}. 退出"
        echo -e "${CYAN}====================================================${NC}"
        read -r -p " 请输入选项 [0-9]: " opt

        case "$opt" in
            1) start_st; break ;;
            2) do_install ask; pause ;;
            3) do_update; pause ;;
            4) do_switch_version; pause ;;
            5) npm_install_deps; pause ;;
            6) doctor; pause ;;
            7)
                echo "1. 备份数据  2. 恢复数据  3. 返回"
                read -r -p "请选择 [1-3]: " c
                case "$c" in 1) backup_data ;; 2) restore_data ;; esac
                pause
                ;;
            8)
                echo "1. 修改端口  2. 开启/关闭局域网访问  3. 返回"
                read -r -p "请选择 [1-3]: " c
                case "$c" in
                    1)
                        read -r -p "新端口 (当前 $port): " np
                        if [[ "$np" =~ ^[0-9]+$ ]] && [ "$np" -ge 1 ] && [ "$np" -le 65535 ]; then
                            config_set port "$np" && ok "端口已改为 $np"
                        else
                            error "无效端口。"
                        fi
                        ;;
                    2)
                        local cur
                        cur="$(config_get listen)"
                        if [ "$cur" = "true" ]; then
                            config_set listen false; ok "已关闭局域网访问。"
                        else
                            config_set listen true
                            [ -z "$(config_get listenAddress)" ] && sed -i "s|^listenAddress:.*|listenAddress: 0.0.0.0|" "$ST_DIR/config.yaml"
                            ok "已开启局域网访问 (0.0.0.0)。"
                        fi
                        ;;
                esac
                pause
                ;;
            9) do_uninstall; pause ;;
            0) exit 0 ;;
            *) error "无效选项"; sleep 1 ;;
        esac
    done
}

# ----------------------------- 入口 -----------------------------------------
main() {
    detect_platform
    mkdir -p "$LOG_DIR" 2>/dev/null

    case "${1:-}" in
        --install|-i) do_install "${2:-ask}" ;;
        --update|-u)  do_update ;;
        --start|-s)   shift; start_st "$@" ;;
        --doctor|-d)  doctor ;;
        --backup)     backup_data ;;
        --uninstall)  do_uninstall ;;
        --pkg-mirror) PKG_MIRROR="$2"; shift; install_termux_deps; ;;
        --npm-mirror) NPM_MIRROR="$2"; shift ;;
        --git-mirror) BRANCH_MIRROR="$2"; shift ;;
        --help|-h)
            awk 'NR>2 && /^# =====/ {exit} NR>2' "$0" | sed 's/^# \{0,1\}//'
            ;;
        "") install_self; main_menu ;;
        *) error "未知参数: $1"; echo "使用 --help 查看用法。"; exit 1 ;;
    esac
}

main "$@"
