#!/usr/bin/env bash
# =============================================================================
# install-cn.sh —— Hermes Agent 国内加速安装启动器（Linux / Kali）
#
# 官方 install.sh 一个字节不改。本脚本只做四件事（与 Windows 版 install-cn.ps1 同架构）：
#   [1/5] 探测各国内镜像连通性（不通自动回退，公共镜像说挂就挂）
#   [2/5] 选择加速线路（PyPI / git 仓库镜像 / Python 本体镜像）
#   [3/5] 预热 Python：注入死代理之前，先用官方脚本自带的 uv 引脚（sha256 校验）
#         把 Python 装进 uv 托管目录 —— 安装器随后 uv python find 直接命中、跳过下载
#   [4/5] 写入用户级配置（~/.npmrc、pip.conf，持久，以后 hermes update 也走国内源）
#   [5/5] 注入加速环境（进程级，子 shell 内生效，脚本退出自动还原）并执行官方 install.sh
#
# 固定默认行为（没有开关）：
#   - 加速策略（FastGitHub 策略）：断开 GitHub → 数秒失败 → 切 hermes-assets 官方镜像；
#     三道护栏自动关闭：--proxy 指定真代理、gh-proxy 探测不通、预热 Python 失败
#   - 无人值守：默认给安装器传 --non-interactive（--interactive 可开回配置向导）
#   - 桌面图形版：默认传 --include-desktop（--no-desktop 可关）
#   - 渠道钉死 stable（镜像 clone 时防止原版退化成跟 main）
#
# 用法：
#   bash install-cn.sh                        # 默认：加速 + 无人值守 + 桌面版
#   bash install-cn.sh --no-desktop           # 只装命令行版
#   bash install-cn.sh --proxy 1.2.3.4:1080   # 走真代理（自动关加速策略）
#   bash install-cn.sh --probe-only           # 只跑探测，不安装（体检用）
#   bash install-cn.sh --persist              # 把 UV 两个镜像变量固化进 ~/.bashrc
#   其余参数原样透传给官方 install.sh（如 --channel main、--skip-browser）
#
# 断点重跑：任何一步失败直接重跑本脚本，已下完的 git/uv/Python/依赖都有缓存。
# =============================================================================
set -u

# ---------- 镜像表：换镜像只改这里（实测日期 2026-10） ----------
TUNA="https://pypi.tuna.tsinghua.edu.cn/simple"
ALIYUN="https://mirrors.aliyun.com/pypi/simple/"
NPMRC_REGISTRY="https://registry.npmmirror.com"
PBS_NPM="https://registry.npmmirror.com/-/binary/python-build-standalone"
GHPROXY_REPO="https://gh-proxy.com/https://github.com/NousResearch/hermes-agent"  # 探测用稳定路径
REPO_MIRROR="https://gh-proxy.com/https://github.com/NousResearch/hermes-agent.git"
INSTALLER_URL="https://hermes-agent.nousresearch.com/install.sh"
ELECTRON_MIRROR="https://npmmirror.com/mirrors/electron/"
BUILDER_BINARIES_MIRROR="https://registry.npmmirror.com/-/binary/electron-builder-binaries/"
DEAD_PROXY="http://hermes-cn-off.invalid:8080"   # .invalid 顶级域按 RFC 永不分配 → 必然 DNS 失败

# 与 pm/lock.json 域名清单对齐的直连白名单（没兜底的源掐了就是硬失败）
DIRECT_HOSTS="hermes-assets.nousresearch.com,gh-proxy.com,registry.npmmirror.com,cdn.npmmirror.com,npmmirror.com,pypi.tuna.tsinghua.edu.cn,mirrors.aliyun.com,nodejs.org,unofficial-builds.nodejs.org,registry.npmjs.org,files.pythonhosted.org,pypi.org,ffmpeg.martin-riedl.de,packages.termux.dev,archive.ubuntu.com,ports.ubuntu.com,hermes-agent.nousresearch.com,cdn.playwright.dev,localhost,127.0.0.1"

# ---------- 参数 ----------
PROBE_ONLY=false
MAKE_ICON=false
NO_FAST=false
INTERACTIVE=false
NO_DESKTOP=false
PERSIST=false
PROXY=""
FORWARD_ARGS=()

while [ $# -gt 0 ]; do
    case "$1" in
        --probe-only)          PROBE_ONLY=true; shift ;;
        --make-desktop-icon)   MAKE_ICON=true; shift ;;
        --no-fast)      NO_FAST=true; shift ;;
        --interactive)  INTERACTIVE=true; shift ;;
        --no-desktop)   NO_DESKTOP=true; shift ;;
        --persist)      PERSIST=true; shift ;;
        --proxy)        PROXY="${2:-}"; shift 2 ;;
        --proxy=*)      PROXY="${1#*=}"; shift ;;
        -h|--help)
            cat <<'HELP'
Hermes Agent 国内加速安装启动器（Linux / Kali）

  bash install-cn.sh                # 默认：加速 + 无人值守 + 桌面版
  bash install-cn.sh --no-desktop   # 只装命令行版
  bash install-cn.sh --interactive  # 安装期走配置向导（默认无人值守）
  bash install-cn.sh --proxy ip:port  # 走真代理（自动关加速策略）
  bash install-cn.sh --no-fast      # 不断 GitHub
  bash install-cn.sh --probe-only   # 只探测不安装（体检）
  bash install-cn.sh --persist      # UV 镜像变量固化进 ~/.bashrc
  其余参数原样透传官方 install.sh（--channel main、--skip-browser 等）
HELP
            exit 0 ;;
        *) FORWARD_ARGS+=("$1"); shift ;;
    esac
done

say()  { printf '  %s\n' "$*"; }
head1(){ printf '\n[%s] %s\n' "$1" "$2"; }

# ---------- 桌面快捷图标（root 专用降级已焊进 Exec；非 root 走官方沙箱机制） ----------
make_desktop_icon() {
    local desk hermes_bin exec_line icon_name
    if command -v xdg-user-dir >/dev/null 2>&1; then
        desk="$(xdg-user-dir DESKTOP 2>/dev/null || true)"
    fi
    [ -n "$desk" ] || desk="$HOME/Desktop"
    mkdir -p "$desk" 2>/dev/null || { say "[!!] 桌面目录不可创建：$desk"; return 1; }
    hermes_bin="$HOME/.local/bin/hermes"
    [ -x "$hermes_bin" ] || say "    提示：$hermes_bin 还不存在（装完才有），图标先就位"
    # 图标跟随官方菜单条目（其 Icon= 主题名由官方注册进 hicolor 树）；缺失则回退 hermes
    icon_name="hermes"
    local official="$HOME/.local/share/applications/com.nousresearch.hermes.desktop"
    if [ -f "$official" ]; then
        local _oi
        _oi="$(grep -m1 '^Icon=' "$official" 2>/dev/null | cut -d= -f2-)"
        [ -n "$_oi" ] && icon_name="$_oi"
    fi
    if [ "$(id -u)" = "0" ]; then
        # Chromium 对 root 只认 --no-sandbox（crbug 638180）；官方把这决定留给人，
        # 这里替 root 显式定下：Exec 内联环境 → 无论会话环境是否带开关都能启动
        exec_line="Exec=/bin/sh -c \"ELECTRON_DISABLE_SANDBOX=1 exec $hermes_bin desktop --skip-build\""
    else
        exec_line="Exec=/bin/sh -c \"exec $hermes_bin desktop --skip-build\""
    fi
    cat > "$desk/hermes-desktop.desktop" <<EOF_ICON
[Desktop Entry]
Name=Hermes Agent
Comment=Hermes Agent Desktop（国内加速安装）
Type=Application
Terminal=false
Categories=Development;
Icon=$icon_name
StartupWMClass=com.nousresearch.hermes
$exec_line
EOF_ICON
    chmod +x "$desk/hermes-desktop.desktop" 2>/dev/null || true
    say "    桌面图标 → $desk/hermes-desktop.desktop"
    if [ "$(id -u)" = "0" ]; then
        # root 四路会话环境：终端 hermes desktop 与应用菜单项全部生效
        local rc
        for rc in "$HOME/.zshrc" "$HOME/.zprofile" "$HOME/.profile" "$HOME/.xsessionrc"; do
            touch "$rc" 2>/dev/null || continue
            grep -q 'ELECTRON_DISABLE_SANDBOX' "$rc" 2>/dev/null || {
                printf '\n# hermes desktop as root: Chromium requires --no-sandbox for root (crbug 638180)\nexport ELECTRON_DISABLE_SANDBOX=1\n' >> "$rc"
            }
        done
        say "    root 开关已写入 ~/.zshrc ~/.zprofile ~/.profile ~/.xsessionrc（终端/菜单直启同享）"
        say "    提示：首次双击图标若提示“不受信任”，右键 → 允许启动"
    fi
}

# --make-desktop-icon：给已装完的机器补图标（不探测、不安装）
if [ "$MAKE_ICON" = true ]; then
    head1 "0/0" "生成桌面快捷图标"
    make_desktop_icon || true
    exit 0
fi

# ---------- [1/5] 镜像连通性测试 ----------
head1 "1/5" "下载镜像站连通性测试（约数秒）"
probe() {  # $1=名称 $2=url → 置 UP_* 变量，返回0/1
    local code
    code=$(curl -sL -r 0-0 -o /dev/null -w '%{http_code}' -m 8 "$2" 2>/dev/null || echo 000)
    case "$code" in 2*|3*) say "[OK] $1"; return 0 ;; esac
    say "[!!] $1 不可用（HTTP $code），自动回退直连"
    return 1
}

UP_TUNA=false;   probe "PyPI 清华"          "$TUNA/"           && UP_TUNA=true
UP_ALI=false;    probe "PyPI 阿里（备选）"   "$ALIYUN"          && UP_ALI=true
UP_NPM=false;    probe "npm 淘宝"            "$NPMRC_REGISTRY/" && UP_NPM=true
UP_GHP=false;    probe "GitHub 代理 gh-proxy" "$GHPROXY_REPO"   && UP_GHP=true
UP_PBS=false;    probe "Python PBS npmmirror" "$PBS_NPM/"       && UP_PBS=true
UP_OFFICIAL=false
probe "官方安装器本体" "$INSTALLER_URL" && UP_OFFICIAL=true

if [ "$UP_OFFICIAL" != true ]; then
    echo "官方安装器地址访问不了，检查网络后重跑（本脚本未做任何改动）" >&2
    exit 1
fi

# ---------- [2/5] 选择加速线路 ----------
head1 "2/5" "选择加速线路"
PYPI="$TUNA"; [ "$UP_TUNA" = true ] || { PYPI="$ALIYUN"; [ "$UP_ALI" = true ] || PYPI=""; }
REPO_URL=""; [ "$UP_GHP" = true ] && REPO_URL="$REPO_MIRROR"
PBS_URL=""; if [ "$UP_PBS" = true ]; then PBS_URL="$PBS_NPM"; elif [ "$UP_GHP" = true ]; then PBS_URL="https://gh-proxy.com/https://github.com/astral-sh/python-build-standalone/releases/download"; fi

# --probe-only：探测与选线完成即止（不下载、不预热、不写配置、不安装）
if [ "$PROBE_ONLY" = true ]; then
    echo ""
    echo "  选线结果：PyPI=${PYPI:-官方直连}  clone=${REPO_URL:-官方直连}  Python本体=${PBS_URL:-官方直连}"
    say "--probe-only：探测与选线完成，未执行安装"
    exit 0
fi

# ---------- 下载官方 install.sh 到临时目录（顺带当官方可达性硬闸门） ----------
TMPD="$HOME/.cache/hermes-install-cn"
mkdir -p "$TMPD"
INSTALL_SH="$TMPD/upstream-install.sh"
say "    取官方 install.sh → $INSTALL_SH"
if ! curl -fsSL -m 120 "$INSTALLER_URL" -o "$INSTALL_SH.new"; then
    echo "下载官方 install.sh 失败" >&2; exit 1
fi
grep -q "Hermes Agent bootstrap" "$INSTALL_SH.new" || { echo "install.sh 内容异常" >&2; exit 1; }
mv -f "$INSTALL_SH.new" "$INSTALL_SH"

# ---------- 加速策略判定（三道护栏） ----------
FAST_ON=true
FAST_WHY=""
if [ "$NO_FAST" = true ]; then
    FAST_ON=false; FAST_WHY="--no-fast 显式关闭"
elif [ -n "$PROXY" ]; then
    FAST_ON=false; FAST_WHY="已指定 --proxy，走代理即可，加速策略自动关闭"
elif [ "$UP_GHP" != true ]; then
    FAST_ON=false; FAST_WHY="gh-proxy 镜像探测不通，断 GitHub 会连 clone 一起断，加速策略自动关闭"
fi

# ---------- [3/5] 预热 Python（仅加速策略开启时需要；失败自动降级，绝不中断） ----------
head1 "3/5" "提前安装 Python 环境（此阶段不注入代理；装好后安装器会跳过该步）"
WARM_STATE="未执行（加速策略关闭时安装器自己走镜像下载，无此问题）"
if [ "$FAST_ON" = true ]; then
    # 平台选行：与官方 uv_bootstrap_pin() 同款 target key
    ARCH="$(uname -m)"; OS="$(uname -s)"
    KEY=""
    if [ "$OS" = "Linux" ]; then
        case "$ARCH" in
            x86_64)  KEY="linux-x64" ;;
            aarch64) KEY="linux-arm64" ;;
        esac
        if command -v ldd >/dev/null 2>&1 && ldd --version 2>&1 | grep -qi musl; then KEY="$KEY-musl"; fi
    elif [ "$OS" = "Darwin" ]; then
        case "$ARCH" in
            x86_64)  KEY="darwin-x64" ;;
            arm64)   KEY="darwin-arm64" ;;
        esac
    fi
    if [ -z "$KEY" ]; then
        say "[!!] 未知平台 $OS-$ARCH，跳过预热（交给安装器自行处理）"
    else
        # 从官方脚本现读引脚（不写死版本，永远与安装器钉的 uv 一致）
        # 注意 case 标签是 linux-x64) 无引号：按 "KEY)" 精确锚定整行
        BLOCK="$(awk -v k="$KEY" 'index($0, k")") && !f {f=1} f{print} f&&/;;/{exit}' "$INSTALL_SH")"
        UV_MIRROR="$(printf '%s\n' "$BLOCK" | grep -o 'UV_PIN_MIRROR="[^"]*"' | head -1 | cut -d'"' -f2)"
        UV_SHA="$(printf '%s\n' "$BLOCK" | grep -o 'UV_PIN_SHA256="[^"]*"' | head -1 | cut -d'"' -f2)"
        if [ -z "$UV_MIRROR" ] || [ -z "$UV_SHA" ]; then
            say "[!!] 没在 install.sh 里找到 $KEY 的 uv 引脚，跳过预热"
        else
            UVD="$TMPD/uv"; UV_TAR="$TMPD/uv.tar.gz"
            mkdir -p "$UVD"
            if [ ! -x "$UVD/uv" ]; then
                say "    取 uv：$UV_MIRROR"
                if curl -fsSL -m 300 "$UV_MIRROR" -o "$UV_TAR" && \
                   [ "$(sha256sum "$UV_TAR" | cut -d' ' -f1)" = "$UV_SHA" ]; then
                    tar -xzf "$UV_TAR" -C "$UVD" || true
                    # 官方同款定位（install.sh:415）：tarball 是嵌套目录
                    # uv-x86_64-unknown-linux-gnu/uv，不是平铺在根，必须 find 再挪平
                    _uvbin="$(find "$UVD" -mindepth 1 -maxdepth 3 -name uv -type f 2>/dev/null | head -n1)"
                    if [ -n "$_uvbin" ] && [ "$_uvbin" != "$UVD/uv" ]; then
                        mv -f "$_uvbin" "$UVD/uv"
                        _uvx="$(dirname "$_uvbin")/uvx"
                        [ -f "$_uvx" ] && mv -f "$_uvx" "$UVD/uvx"
                    fi
                    chmod +x "$UVD/uv" 2>/dev/null || true
                    [ -x "$UVD/uv" ] || say "[!!] uv 解包后未找到可执行文件"
                    [ -x "$UVD/uv" ] && say "    uv 校验通过"
                else
                    say "[!!] uv 下载/校验失败"
                fi
            fi
            if [ -x "$UVD/uv" ]; then
                if [ -n "$PBS_URL" ]; then export UV_PYTHON_INSTALL_MIRROR="$PBS_URL"; fi
                if "$UVD/uv" python install --no-bin --no-registry "3.14"; then
                    WARM_STATE="完成：安装器检测到已有 Python，跳过该步下载"
                    say "[OK] Python 环境已装好，安装器将跳过该步"
                else
                    WARM_STATE="失败：已自动关闭加速策略，改普通直连安装"
                    FAST_ON=false; FAST_WHY="预热 Python 失败，已自动关闭加速策略保证安装能走完"
                    say "[!!] Python 环境安装失败 → 已关闭加速策略，改普通直连安装"
                fi
                unset UV_PYTHON_INSTALL_MIRROR
            else
                WARM_STATE="失败：uv 未就绪，已自动关闭加速策略"
                FAST_ON=false; FAST_WHY="预热 uv 不可用，已自动关闭加速策略"
            fi
        fi
    fi
fi

# ---------- [4/5] 写入加速配置（用户级文件，持久） ----------
head1 "4/5" "写入加速配置"
export HERMES_INSTALL_CHANNEL="stable"     # 钉死：镜像 clone 时防止原版退化成跟 main
[ -n "$REPO_URL" ] && export HERMES_REPO_URL="$REPO_URL"
[ -n "$PYPI" ]     && export UV_DEFAULT_INDEX="$PYPI"
[ -n "$PBS_URL" ]  && export UV_PYTHON_INSTALL_MIRROR="$PBS_URL"
say "    HERMES_INSTALL_CHANNEL = stable（钉死，绕过镜像 origin 检查）"
[ -n "$REPO_URL" ] && say "    HERMES_REPO_URL       = gh-proxy 镜像"
[ -n "$PYPI" ]     && say "    UV_DEFAULT_INDEX      = $PYPI"
[ -n "$PBS_URL" ]  && say "    UV_PYTHON_INSTALL_MIRROR = $PBS_URL"
[ -z "$PYPI" ] && say "    警告：PyPI 镜像全挂，依赖将直连官方源"

# 用户级 ~/.npmrc（合并：这三键以本脚本为准，其余行保留）
NPMRC="$HOME/.npmrc"
if [ -f "$NPMRC" ]; then
    grep -vE '^\s*(registry|electron_mirror|disturl)=' "$NPMRC" > "$NPMRC.keep" || true
    mv -f "$NPMRC.keep" "$NPMRC"
fi
{
    [ -f "$NPMRC" ] && cat "$NPMRC"
    echo "registry=$NPMRC_REGISTRY"
    echo "electron_mirror=$ELECTRON_MIRROR"
    echo "disturl=https://npmmirror.com/mirrors/node/"
} > "$NPMRC.new" && mv -f "$NPMRC.new" "$NPMRC"
say "    已写入/更新 $NPMRC（registry/electron_mirror/disturl）"

# 用户级 pip 配置
PIP_CONF_DIR="$HOME/.config/pip"
mkdir -p "$PIP_CONF_DIR"
PIP_CONF="$PIP_CONF_DIR/pip.conf"
if [ -f "$PIP_CONF" ] && grep -q 'index-url' "$PIP_CONF" 2>/dev/null; then
    say "    pip.conf 已有源配置，不覆盖"
elif [ -n "$PYPI" ]; then
    printf '[global]\nindex-url = %s\n' "$PYPI" > "$PIP_CONF"
    say "    已写入 $PIP_CONF"
fi

# --persist：把两个 UV 变量固化进 ~/.bashrc（幂等追加）
if [ "$PERSIST" = true ]; then
    BLOCK_MARK="# hermes-install-cn mirrors"
    touch "$HOME/.bashrc"
    grep -qF "$BLOCK_MARK" "$HOME/.bashrc" 2>/dev/null || {
        {
            echo ""
            echo "$BLOCK_MARK"
            [ -n "$PYPI" ]   && echo "export UV_DEFAULT_INDEX=\"$PYPI\""
            [ -n "$PBS_URL" ] && echo "export UV_PYTHON_INSTALL_MIRROR=\"$PBS_URL\""
        } >> "$HOME/.bashrc"
        say "    --persist：已固化进 ~/.bashrc（新开终端生效）"
    }
fi

# ---------- 安装走向总览 ----------
echo ""
echo "  本次安装走向："
[ -n "$PYPI" ] && echo "    Python 依赖   $PYPI" || echo "    Python 依赖   官方 PyPI（镜像全挂）"
echo "    源码 clone    ${REPO_URL:-官方直连 GitHub}"
[ -n "$PBS_URL" ] && echo "    Python 本体   $PBS_URL" || echo "    Python 本体   官方直连（慢/易超时）"
echo "    npm / Electron 用户 ~/.npmrc → registry.npmmirror.com（已写入）"
if [ "$FAST_ON" = true ]; then
    echo "    GitHub 策略   已断开：GitHub 下载数秒内失败 → 秒切 hermes-assets（白名单域名直连）"
else
    echo "    GitHub 策略   未开启：$FAST_WHY"
fi
echo "    Python 环境   $WARM_STATE"
echo "    桌面图形版    $([ "$NO_DESKTOP" = true ] && echo '跳过（--no-desktop）' || echo '安装（默认）')"
echo "    交互模式      $([ "$INTERACTIVE" = true ] && echo '安装期配置向导（--interactive）' || echo '无人值守（默认），装完用桌面版自带配置')"
echo ""
echo "  提示：装完跑 hermes doctor；中途失败直接重跑本脚本，已下完的在缓存里不重下。"

if [ "$PROBE_ONLY" = true ]; then
    echo ""
    say "--probe-only：探测与选线完成，未执行安装"
    exit 0
fi

# ---------- [5/5] 执行官方安装器（子 shell：所有导出随子进程退出自动还原） ----------
head1 "5/5" "执行官方安装器"
(
    set -u
    # 真代理模式：全量代理变量（含小写），加速策略本来就是关的
    if [ -n "$PROXY" ]; then
        case "$PROXY" in *://*) PURL="$PROXY" ;; *) PURL="http://$PROXY" ;; esac
        export HTTP_PROXY="$PURL" HTTPS_PROXY="$PURL" ALL_PROXY="$PURL"
        export http_proxy="$PURL" https_proxy="$PURL" all_proxy="$PURL"
        say "    代理已启用：$PURL"
    fi
    # 加速模式：死代理只挂 ALL_PROXY + 白名单（git/curl/python 认；无兜底源直连）
    if [ "$FAST_ON" = true ]; then
        export ALL_PROXY="$DEAD_PROXY" all_proxy="$DEAD_PROXY"
        export NO_PROXY="$DIRECT_HOSTS" no_proxy="$DIRECT_HOSTS"
        say "    [-加速策略已注入] ALL_PROXY 死代理：GitHub 秒失败 → 切 hermes-assets；白名单直连"
    fi
    # electron-builder 工具组国内直连（官方 electronGet.js 认这个变量）
    export ELECTRON_BUILDER_BINARIES_MIRROR="$BUILDER_BINARIES_MIRROR"
    export ELECTRON_MIRROR="$ELECTRON_MIRROR"

    INSTALLER_ARGS=()
    [ "$NO_DESKTOP" = true ]   || INSTALLER_ARGS+=("--include-desktop")
    [ "$INTERACTIVE" = true ]  || INSTALLER_ARGS+=("--non-interactive")
    bash "$INSTALL_SH" ${INSTALLER_ARGS[@]+"${INSTALLER_ARGS[@]}"} ${FORWARD_ARGS[@]+"${FORWARD_ARGS[@]}"}
    exit $?
)
RC=$?
echo ""
if [ $RC -eq 0 ]; then
    echo ""
    say "生成桌面快捷图标："
    make_desktop_icon || true
    say "有图形会话即可双击桌面 Hermes 图标启动；或新开终端跑 hermes desktop。"
    echo ""
    say "启动器执行完毕（exit 0）。运行 hermes doctor 体检。"
else
    say "启动器执行完毕（exit $RC）。按上面的失败环节排查后重跑本脚本即可（缓存增量）。"
fi
exit $RC
