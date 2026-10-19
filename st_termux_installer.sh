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
#  作者: 水仙
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
# ============================================================================
# 下载线路（用户可手动选择，也可 --source N 指定）
#   1 = 国际线路: GitHub 官方直连（速度最快，但需要开启魔法/代理）
#   2 = 国内线路: gh-proxy.com 加速（无需魔法，但很慢且容易失败）
#   3 = 国内线路: gitclone.com 镜像（上面那个不行时的备选）
#   6 = 自定义地址（--source-url 指定）
# ============================================================================
SOURCE_NAMES=(
    "国际线路 GitHub 官方（需要魔法）"
    "国内线路 gh-proxy.com"
    "国内线路 gitclone.com 镜像"
    ""
    ""
    "自定义地址"
)

# 返回第 N 个源的 git 地址
source_url() {
    local n="$1" branch="$2"
    local base="https://github.com/SillyTavern/SillyTavern.git"
    case "$n" in
        1) echo "$base" ;;
        2) echo "https://gh-proxy.com/${base}" ;;
        3) echo "https://gitclone.com/github.com/SillyTavern/SillyTavern.git" ;;
        6) echo "${CUSTOM_SOURCE_URL:-}" ;;
        *) echo "" ;;
    esac
}

# 返回第 N 个源的**压缩包**地址
source_tarball() {
    local n="$1" branch="${2:-release}"
    local tarball="https://github.com/SillyTavern/SillyTavern/archive/refs/heads/${branch}.tar.gz"
    case "$n" in
        1) echo "$tarball" ;;
        2) echo "https://gh-proxy.com/${tarball}" ;;
        3) echo "https://gitclone.com/github.com/SillyTavern/SillyTavern/archive/${branch}.tar.gz" ;;
        6) echo "${CUSTOM_SOURCE_URL:-}" ;;
        *) echo "" ;;
    esac
}

# 选择下载线路（新手向导）
choose_source() {
    local has_proxy=0
    [ -n "${https_proxy:-}" ] || [ -n "${HTTPS_PROXY:-}" ] || [ -n "${http_proxy:-}" ] || [ -n "${HTTP_PROXY:-}" ] && has_proxy=1

    echo ""
    echo -e "${CYAN}────────────────────────────────────────────────────${NC}"
    echo -e "${BOLD}  选择下载线路${NC}"
    echo -e "${CYAN}────────────────────────────────────────────────────${NC}"
    echo -e "  ${GREEN}1${NC}. 国际线路 — GitHub 官方  ${YELLOW}★ 推荐该选项，需要开启魔法${NC}"
    echo -e "     如果下载失败，可能是魔法不稳定导致。"
    echo -e "     速度最快，一般 1~3 分钟即可下载完。"
    echo ""
    echo -e "  ${GREEN}2${NC}. 国内线路 — gh-proxy 加速"
    echo -e "     下载极其缓慢，极大概率失败。"
    echo -e "     不需要魔法，但仓库约 160MB，可能要等很久甚至中途断开。"
    echo ""
    echo -e "  ${GREEN}3${NC}. 国内线路 — gitclone 镜像"
    echo -e "     和选项 2 类似，是另一个国内镜像。选项 2 不行时可以试它。"
    echo -e "${CYAN}────────────────────────────────────────────────────${NC}"
    [ "$has_proxy" -eq 1 ] && echo -e "  ${BLUE}检测到你已设置代理环境变量，选 1 应该没问题。${NC}"
    echo -e "  直接按回车 = 选 1 (国际线路)"

    local c
    while true; do
        read -r -p "  请输入 [1-3]: " c
        case "${c:-1}" in
            1) echo 1; return ;;
            2) echo 2; return ;;
            3) echo 3; return ;;
            *) warn "只能输入 1~3，请重新输入。" ;;
        esac
    done
}

# 快速探测一个地址是否可达（HEAD 请求，最多 12 秒）
probe_url() {
    local url="$1"
    [ -z "$url" ] && return 1
    local code
    code="$(curl -sIL -m 12 -o /dev/null -w "%{http_code}" "$url" 2>/dev/null)"
    case "$code" in 200|301|302) return 0 ;; *) return 1 ;; esac
}

# 使用 git 的部分克隆（直接下载 .git 包，再检出文件）。
# 注意: 实测在加速代理上不可靠（拉 blob 时会 invalid index-pack），
# 仅作为最后的兜底手段，默认不启用。
git_partial_clone() {
    local gurl="$1" dest="$2" branch="$3"
    rm -rf "$dest"
    mkdir -p "$dest" || return 1

    (
        set -e
        cd "$dest" || exit 1
        git init -q
        git remote add origin "$gurl"
        # 只取该分支的最新提交，不下载无关历史
        git -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=90 \
            fetch --depth 1 --filter=blob:none origin "$branch"
        git checkout -q -b "$branch" FETCH_HEAD
    ) 2>&1 | tee -a "$LOG_FILE" | tail -n 12

    [ -f "$dest/server.js" ] && [ -d "$dest/.git" ] && return 0
    return 1
}

# 用压缩包方式安装（git 走不通时的兜底，不依赖 .git）
install_from_tarball() {
    local dest="$1" branch="${2:-release}" n="$3"
    local url
    url="$(source_tarball "$n" "$branch")"
    [ -z "$url" ] && return 1

    # 体积约 160MB 压缩包，给足时间；看门狗监视“是否还在增长”，而不是总时长
    local tmp="$dest.tar.gz" attempt=0 last_size=-1 stall=0 limit="${TARBALL_STALL_SECONDS:-180}"
    info "下载 SillyTavern 源码包（约 160MB）。国内网络通常几分钟，"
    info "如果很慢会自动续传，${YELLOW}请保持屏幕常亮${NC}。"
    rm -f "$tmp"

    while [ "$attempt" -lt 8 ]; do
        attempt=$((attempt + 1))
        # 后台下载，前台每 5 秒检查一次文件是否还在增长
        curl -fL -C - --connect-timeout 20 --speed-limit 512 --speed-time 120 \
             -o "$tmp" "$url" >> "$LOG_FILE" 2>&1 &
        local cpid=$!
        last_size=-1; stall=0
        while kill -0 "$cpid" 2>/dev/null; do
            sleep 5
            local cur
            cur="$(stat -c %s "$tmp" 2>/dev/null || echo 0)"
            if [ "$cur" -le "${last_size:-0}" ]; then
                stall=$((stall + 5))
                if [ "$stall" -ge "$limit" ]; then
                    warn "超过 ${limit} 秒没有进展，重新连接..."
                    kill "$cpid" 2>/dev/null
                    break
                fi
            else
                stall=0
                last_size="$cur"
                printf "\r  已下载 %.1f MB ..." "$(awk "BEGIN{print $cur/1048576}")"
            fi
        done
        printf "\r"

        if [ "$(stat -c %s "$tmp" 2>/dev/null || echo 0)" -gt "${last_size:-0}" ] 2>/dev/null; then
            break   # 可能是正常结束
        fi
        warn "下载中断（第 $attempt 次），正在续传..."
        sleep 2
    done

    # 校验：必须是完整的 gzip
    if [ ! -s "$tmp" ] || ! gzip -t "$tmp" 2>/dev/null; then
        error "压缩包不完整或下载失败: $(du -h "$tmp" 2>/dev/null | cut -f1)"
        rm -f "$tmp"
        return 1
    fi
    ok "压缩包下载完成 ($(du -h "$tmp" | cut -f1))"

    rm -rf "$dest" "$dest.unpack"
    mkdir -p "$dest.unpack"
    if ! tar -xzf "$tmp" -C "$dest.unpack" 2>/dev/null; then
        rm -rf "$dest.unpack" "$tmp"
        return 1
    fi
    local inner
    inner="$(ls -d "$dest.unpack"/*/ 2>/dev/null | head -n 1)"
    [ -n "$inner" ] || { rm -rf "$dest.unpack" "$tmp"; return 1; }
    mv "$inner" "$dest" 2>/dev/null
    rm -rf "$dest.unpack" "$tmp"
    [ -f "$dest/server.js" ] && [ -f "$dest/package.json" ] || return 1
    ok "源码校验通过 (server.js / package.json 齐全)。"
    ok "压缩包下载完成（此方式不含 .git，菜单里的「更新 / 切换版本」功能会受限）。"
    return 0
}

# 用某条线路获取代码
#   国际线路(1): 优先 git clone（有魔法时最快，且带 .git 方便以后更新）
#   国内线路(2/3): 优先压缩包（git 传输大仓库容易 invalid index-pack）
try_source() {
    local n="$1" dest="$2" branch="$3" label="$4"
    local gurl turl
    gurl="$(source_url "$n" "$branch")"
    turl="$(source_tarball "$n" "$branch")"

    if [ "$n" -eq 1 ]; then
        if try_git_clone "$gurl" "$dest" "$branch" "$label"; then ok "[$label] 下载完成。"; return 0; fi
        warn "[$label] git 方式失败，改用压缩包再试一次..."
        if try_tarball "$turl" "$dest" "$branch" "$n" "$label"; then return 0; fi
    else
        if try_tarball "$turl" "$dest" "$branch" "$n" "$label"; then return 0; fi
        warn "[$label] 压缩包方式失败，改用 git 再试一次..."
        if try_git_clone "$gurl" "$dest" "$branch" "$label"; then ok "[$label] 下载完成。"; return 0; fi
    fi

    rm -rf "$dest"
    return 1
}

# git clone 方式
try_git_clone() {
    local gurl="$1" dest="$2" branch="$3" label="$4"
    [ -n "$gurl" ] || return 1
    info "[$label] 正在 git clone..."
    rm -rf "$dest"
    timeout "${CLONE_TIMEOUT:-300}" git -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=60 \
        clone -b "$branch" --depth 1 "$gurl" "$dest" 2>&1 | tee -a "$LOG_FILE" | tail -n 12
    [ -d "$dest/.git" ] && [ -f "$dest/server.js" ]
}

# 压缩包方式
try_tarball() {
    local turl="$1" dest="$2" branch="$3" n="$4" label="$5"
    [ -n "$turl" ] || return 1
    install_from_tarball "$dest" "$branch" "$n"
}

# 用用户选定的线路下载代码。
# 重要: 只尝试选中的那一条线路，失败就停下并提示，不会偷偷换成别的线路。
clone_repo() {
    local dest="$1" branch="${2:-release}"
    local n="${FORCE_SOURCE:-1}"
    local label="${SOURCE_NAMES[$((n - 1))]:-源$n}"

    local gurl turl
    gurl="$(source_url "$n" "$branch")"
    turl="$(source_tarball "$n" "$branch")"

    if [ -z "$gurl" ] && [ -z "$turl" ]; then
        error "线路 $n 没有可用的下载地址。"
        return 1
    fi

    # 国内线路先探测一下，避免用户干等
    if [ "$n" -ne 1 ] && [ -n "$turl" ] && ! probe_url "$turl"; then
        warn "[$label] 该线路当前不可达。"
    fi

    if try_source "$n" "$dest" "$branch" "$label"; then
        return 0
    fi

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

    echo ""
    echo -e "${CYAN}────────────────────────────────────────────────────${NC}"
    echo -e "${BOLD}  选择要安装的版本${NC}"
    echo -e "${CYAN}────────────────────────────────────────────────────${NC}"
    echo -e "  ${GREEN}1${NC}. release 分支  ${YELLOW}★ 推荐新手选这个${NC}"
    echo -e "     说明: SillyTavern 官方的「稳定版」。功能是所有版本里最稳定的，"
    echo -e "           经过开发者测试后才发布，出问题最少。"
    echo -e "     适合: 想直接用、不想折腾、怕出 bug 的人。"
    echo ""
    echo -e "  ${GREEN}2${NC}. staging 分支"
    echo -e "     说明: 官方的「测试版」。新功能会先出现在这里，但可能带 bug，"
    echo -e "           有时会启动报错或插件不兼容。"
    echo -e "     适合: 想尝鲜最新功能、并且能自己看报错排查的人。"
    echo -e "     ${YELLOW}不建议新手选。${NC}"
    if [ "$n" -gt 0 ]; then
        echo ""
        echo -e "  ${GREEN}3${NC}. 指定 Tag 版本 (回退到某个固定版本)"
        echo -e "     说明: 装一个确切的历史版本号，比如升到新版出问题后回退。"
        echo -e "     最近的 Tag:"
        for ((i = 0; i < n; i++)); do printf "        %2d) %s\n" $((i + 1)) "${tags[$i]}"; done
    fi
    echo -e "${CYAN}────────────────────────────────────────────────────${NC}"
    echo -e "  直接按回车 = 选 1 (release 稳定版)"

    local max_opt=2
    [ "$n" -gt 0 ] && max_opt=3

    local c
    while true; do
        read -r -p "  请输入 [1-${max_opt}]: " c
        c="${c:-1}"
        case "$c" in
            1) echo "release"; return ;;
            2) echo "staging"; return ;;
            3)
                if [ "$n" -eq 0 ]; then
                    warn "没有可用的 Tag，改用 release 稳定版。"
                    echo "release"
                    return
                fi
                read -r -p "  输入序号(1-${n})或完整 Tag 号: " t
                if [[ "$t" =~ ^[0-9]+$ ]] && [ "$t" -ge 1 ] && [ "$t" -le "$n" ]; then
                    echo "tag:${tags[$((t - 1))]}"
                elif [ -n "$t" ]; then
                    echo "tag:$t"
                else
                    echo "release"
                fi
                return
                ;;
            *)
                warn "只能输入 1~${max_opt}，请重新输入。"
                ;;
        esac
    done
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

    # 先选下载线路（交互模式下），再选版本
    if [ -t 0 ] && [ -z "${FORCE_SOURCE:-}" ]; then
        FORCE_SOURCE="$(choose_source)"
    fi
    FORCE_SOURCE="${FORCE_SOURCE:-1}"

    local target="release"
    if [ -t 0 ]; then
        target="$(choose_branch)"
    else
        info "非交互模式，使用 release 分支。"
    fi

    local branch="release"
    [ "$target" = "staging" ] && branch="staging"

    if ! clone_repo "$ST_DIR" "$branch"; then
        local ln="${SOURCE_NAMES[$((FORCE_SOURCE - 1))]:-线路$FORCE_SOURCE}"
        error "下载失败（线路: $ln）。"
        echo -e ""
        if [ "$FORCE_SOURCE" -eq 1 ]; then
            echo -e "${YELLOW}  你选择的是国际线路，需要开启魔法。${NC}"
            echo -e "  如果已经开了魔法，${YELLOW}下载失败通常是魔法不稳定导致的${NC}，请检查："
            echo -e "    ${GREEN}1)${NC} 魔法是否真的在生效（浏览器能打开 github.com 吗）"
            echo -e "    ${GREEN}2)${NC} 换个节点再试，或不稳定时改用国内线路"
            echo -e "    ${GREEN}3)${NC} Termux 里没有自动代理，需要手动设置:"
            echo -e "       ${CYAN}export https_proxy=http://127.0.0.1:7890${NC}  (端口换成你魔法的本地端口)"
            echo -e "       然后重新运行脚本"
            echo -e ""
            echo -e "    ${BLUE}不想开魔法${NC}: 重新运行脚本，线路选 ${GREEN}2${NC}（国内线路，但很慢且容易失败）"
        else
            echo -e "${YELLOW}  你选择的是国内线路（无需魔法，但下载极其缓慢，容易失败）。${NC}"
            echo -e "    ${GREEN}1)${NC} 重新运行脚本再试一次，网络状态会变"
            echo -e "    ${GREEN}2)${NC} 换另一条国内线路（2 或 3）"
            echo -e "    ${GREEN}3)${NC} 有魔法的话，选 ${GREEN}1${NC} 会快很多"
        fi
        echo -e ""
        echo -e "  ${BLUE}详细日志${NC}: $LOG_FILE"
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

    step "4/4 初始化配置与开机自启"
    setup_config

    # 自启是默认行为，不需要用户额外选择
    install_self
    install_alias
    ok "安装完成！"
    log "install ok"

    echo ""
    echo -e "${GREEN}────────────────────────────────────────────────${NC}"
    echo -e "${BOLD} 使用说明（建议看完）${NC}"
    echo -e "${GREEN}────────────────────────────────────────────────${NC}"
    echo -e "  1. 以后${YELLOW}打开 Termux 会直接进入本菜单${NC}，不用再敲长命令"
    echo -e "  2. 启动酒馆: 菜单选 1 ，或直接敲 ${GREEN}st${NC}"
    echo -e "  3. 打开酒馆网页: 手机浏览器访问 ${CYAN}http://127.0.0.1:$(get_port)${NC}"
    echo -e "  4. 关闭酒馆: 在运行中的界面按 ${YELLOW}Ctrl+C${NC}（先按 CTRL 再按 C）"
    echo -e "  5. 如果不想要开机菜单，菜单里选 9 卸载，或执行 ${CYAN}stm --no-autostart${NC}"
    echo -e "${GREEN}────────────────────────────────────────────────${NC}"

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

# ----------------------------- 开头提醒 -------------------------------------
show_welcome() {
    local installed=0
    [ -f "$ST_DIR/server.js" ] && installed=1

    echo -e "${CYAN}====================================================${NC}"
    echo -e "${BOLD}${PURPLE}  SillyTavern Termux 一键安装/管理工具${NC}  ${YELLOW}v${SCRIPT_VERSION}${NC}"
    echo -e "${CYAN}====================================================${NC}"
    if [ "$installed" -eq 0 ]; then
        echo -e "  ${YELLOW}当前状态: 还没安装 SillyTavern${NC}"
        echo -e "  ${GREEN}下一步: 在下面菜单输入 2 ，会自动开始安装${NC}"
        echo -e ""
        echo -e "  ${BLUE}小提示${NC}"
        echo -e "  · 安装时下载依赖要 15~40 分钟，${YELLOW}别锁屏、别切后台${NC}"
        echo -e "  · 所有提问直接按回车 = 用推荐项，也能装上"
        echo -e "  · 装好后任何时候敲 ${GREEN}stm${NC} 都能回到这个菜单"
    else
        echo -e "  ${GREEN}当前状态: SillyTavern 已安装${NC}"
        echo -e "  想启动就输入 ${GREEN}1${NC}，想更新输入 ${GREEN}3${NC}"
    fi
    echo -e "${CYAN}====================================================${NC}"
}

# ----------------------------- 快捷命令 / 自启 -------------------------------
# .bashrc 里的标记块（自启 + 快捷命令）
AUTOSTART_BEGIN="# >>> st-toolbox autostart >>>"
AUTOSTART_END="# <<< st-toolbox autostart <<<"

has_autostart() {
    grep -q "^${AUTOSTART_BEGIN}" "$HOME/.bashrc" 2>/dev/null
}

# 安装/更新自启块：每次打开 Termux 自动进入脚本菜单（默认行为）
enable_autostart() {
    local rc="$HOME/.bashrc"
    touch "$rc" 2>/dev/null

    # 先删掉旧的标记块，避免重复（重复会导致要退出两次）
    disable_autostart_quiet
    # 清掉此前第三方脚本（如 violet.sh / st-menu.sh）残留的自启行，
    # 那些脚本被删掉后会在每次启动时报错。
    clean_legacy_autostart

    install_self

    {
        echo ""
        echo "$AUTOSTART_BEGIN"
        echo "# 打开 Termux 自动进入 SillyTavern 管理菜单"
        echo 'if [ -f "$HOME/st_termux_installer.sh" ] && [ -z "$ST_MENU_NOLOOP" ]; then'
        echo '    bash "$HOME/st_termux_installer.sh"'
        echo "fi"
        echo ""
        echo "# 快捷命令"
        echo "alias st='cd \"\$HOME/SillyTavern\" && bash start.sh'"
        echo "alias stu='cd \"\$HOME/SillyTavern\" && git pull --rebase --autostash && npm install --omit=dev'"
        echo "alias stm='bash \"\$HOME/st_termux_installer.sh\"'"
        echo "alias stoff='ST_MENU_NOLOOP=1 bash -c \"true\"'"
        echo "$AUTOSTART_END"
    } >> "$rc"

    # Termux 登录时读的是 .bash_profile，要确保它加载 .bashrc
    ensure_bash_profile
    fix_broken_bashrc
    return 0
}

# 清理旧脚本留下的自启（它们会在启动时刷报错）
clean_legacy_autostart() {
    local rc="$HOME/.bashrc"
    [ -f "$rc" ] || return 0
    local before after
    before=$(md5sum "$rc" 2>/dev/null | cut -d' ' -f1)
    # 只删“调用这些脚本”的行，以及其注释标题；不动其他内容
    sed -i "/violet\.sh/d" "$rc" 2>/dev/null
    sed -i "/st-menu\.sh/d" "$rc" 2>/dev/null
    sed -i "/Violet SillyTavern 管理面板自启动/d" "$rc" 2>/dev/null
    after=$(md5sum "$rc" 2>/dev/null | cut -d' ' -f1)
    [ "$before" != "$after" ] && info "已清理旧脚本残留的自启配置。"
    return 0
}

# 修复被误删而残留的孤立语句（此前的清理命令可能留下孤立的 fi/if），
# 这类残行会让 .bashrc 报语法错误，进而导致自启失效。
# 注意: 这里只删“孤立的语句行”，绝不能碰标记块，否则会把刚写好的自启删掉。
fix_broken_bashrc() {
    local rc="$HOME/.bashrc"
    [ -f "$rc" ] || return 0
    bash -n "$rc" 2>/dev/null && return 0     # 语法正常就不用管

    local tmp="$rc.stfix.$$"
    awk -v b="$AUTOSTART_BEGIN" -v e="$AUTOSTART_END" '
        # 标记块原样保留，一个字都不改
        $0 == b { inblk = 1 }
        inblk  { print; if ($0 == e) inblk = 0; next }
        # 块外：丢掉完全孤立的语句行（没有配对的 if）
        /^[ \t]*(fi|else|then)[ \t]*$/ { next }
        { print }
    ' "$rc" > "$tmp" 2>/dev/null && mv "$tmp" "$rc"

    bash -n "$rc" 2>/dev/null && \
        ok "检测到 ~/.bashrc 有语法残留，已自动修复。" || \
        warn "~/.bashrc 仍有语法问题，可手动执行: nano ~/.bashrc"
}

ensure_bash_profile() {
    local p="$HOME/.bash_profile"
    touch "$p" 2>/dev/null
    if ! grep -q '\.bashrc' "$p" 2>/dev/null; then
        {
            echo ''
            echo '# 加载 .bashrc（Termux 登录时默认不读 .bashrc）'
            echo 'if [ -f "$HOME/.bashrc" ]; then'
            echo '    . "$HOME/.bashrc"'
            echo 'fi'
        } >> "$p"
        ok "已配置 ~/.bash_profile 加载 .bashrc"
    fi
}

disable_autostart_quiet() {
    local rc="$HOME/.bashrc"
    [ -f "$rc" ] || return 0
    # 删除标记块 + 顺手清掉旧版本可能残留的自启行
    sed -i "/^${AUTOSTART_BEGIN}$/,/^${AUTOSTART_END}$/d" "$rc" 2>/dev/null
    sed -i '/# BEGIN ANGLER_TOOLBOX_AUTOSTART/,/# END ANGLER_TOOLBOX_AUTOSTART/d' "$rc" 2>/dev/null
}

disable_autostart() {
    if has_autostart; then
        disable_autostart_quiet
        ok "已关闭「打开 Termux 自动进入菜单」"
    else
        info "当前没有开启自启。"
    fi
}

toggle_autostart() {
    if has_autostart; then
        disable_autostart
    else
        enable_autostart
    fi
}

install_alias() {
    # 默认开启自启（每次运行都会校正一次，顺手修复被改坏的 .bashrc）
    enable_autostart > /dev/null 2>&1
    ok "已设置：打开 Termux 自动进入菜单（快捷命令 st / stu / stm）"
}

install_self() {
    # 支持 bash <(curl ...) 运行；把自己复制到 HOME 便于下次直接用
    local src="${BASH_SOURCE[0]}"
    [ "$src" = "$SELF_PATH" ] && return 0
    if [ -f "$src" ] && [ -r "$src" ] && case "$src" in /proc/*|/dev/fd/*) false;; *) true;; esac; then
        cp "$src" "$SELF_PATH" 2>/dev/null && chmod +x "$SELF_PATH" 2>/dev/null && \
            info "脚本已保存到 $SELF_PATH"
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
    sed -i "/^${AUTOSTART_BEGIN}$/,/^${AUTOSTART_END}$/d" "$HOME/.bashrc" 2>/dev/null
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

        echo -e "${CYAN}----------------------------------------------------${NC}"
        echo -e " SillyTavern : $env_state    Node: $node_state"
        echo -e " 目录        : ${CYAN}$ST_DIR${NC}  端口: ${CYAN}$port${NC}"
        echo -e " 开机自启    : $(autostart_state)"
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
        echo -e " ${GREEN}12${NC}. 开机自启 (打开 Termux 自动进菜单)"
        echo -e " ${GREEN}0${NC}. 退出"
        echo -e "${CYAN}====================================================${NC}"
        read -r -p " 请输入选项 [0-9/12]: " opt

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
            12) toggle_autostart; pause ;;
            0) exit 0 ;;
            *) error "无效选项"; sleep 1 ;;
        esac
    done
}

autostart_state() {
    if has_autostart; then
        echo -e "${GREEN}已开启${NC}"
    else
        echo -e "${RED}未开启${NC}"
    fi
}

# ----------------------------- 入口 -----------------------------------------
main() {
    detect_platform
    mkdir -p "$LOG_DIR" 2>/dev/null

    # 先解析可选参数（下载源）
    while [ $# -gt 0 ]; do
        case "$1" in
            --source)      FORCE_SOURCE="${2:-}"; shift 2 ;;
            --source-url)  CUSTOM_SOURCE_URL="${2:-}"; FORCE_SOURCE=6; shift 2 ;;
            *)             break ;;
        esac
    done

    case "${1:-}" in
        --install|-i) install_self; do_install "${2:-ask}" ;;
        --update|-u)  do_update ;;
        --start|-s)   shift; start_st "$@" ;;
        --doctor|-d)  doctor ;;
        --backup)     backup_data ;;
        --uninstall)  do_uninstall ;;
        --autostart)  enable_autostart ;;
        --no-autostart) disable_autostart ;;
        --sources)
            echo "可用的下载线路:"
            printf "  1. 国际线路 GitHub 官方（需要魔法，速度最快）\n"
            printf "  2. 国内线路 gh-proxy.com（无需魔法，很慢，容易失败）\n"
            printf "  3. 国内线路 gitclone.com 镜像（同上，备选）\n"
            echo ""
            echo "用法举例: bash st_termux_installer.sh --source 2"
            ;;
        --pkg-mirror) PKG_MIRROR="$2"; shift; install_termux_deps; ;;
        --npm-mirror) NPM_MIRROR="$2"; shift ;;
        --git-mirror) BRANCH_MIRROR="$2"; shift ;;
        --help|-h)
            awk 'NR>2 && /^# =====/ {exit} NR>2' "$0" | sed 's/^# \{0,1\}//'
            ;;
        "")
            install_self
            if [ -z "$ST_MENU_NOLOOP" ]; then
                show_welcome
            fi
            main_menu
            ;;
        *) error "未知参数: $1"; echo "使用 --help 查看用法。"; exit 1 ;;
    esac
}

main "$@"
