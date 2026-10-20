## ==Hermes Install CN 项目说明==

本项目把官方 Hermes Agent 安装脚本做成三件可分发产物（Windows 命令行 exe、Windows 图形 exe、Linux/Kali 二进制），解决国内直连 GitHub 慢、卡死的问题。**官方脚本一个字节不改**，每次运行现拉最新版执行。

---

## 1、项目定位

### 1.1、解决什么问题

官方安装方式在国内的三类卡点：

- GitHub 下载"慢而不死"（PortableGit 20 分钟才 24MB 这种状态），官方镜像回退永远不触发；
- Electron 桌面版打包要从 GitHub 下工具组，直接 `TypeError: fetch failed`；
- Python/npm/Electron 的官方源在国内慢或不稳。

启动器的做法（Windows 与 Linux 同一套五阶段）：**测镜像连通性 → 选线路 → 提前安装 Python 环境 → 写加速配置 → 执行官方安装器**，进程级注入、结束自动还原，不写注册表、不动 hosts、不改系统代理。

### 1.2、三件产物

| 产物 | 文件 | 说明 |
| ---- | ---- | ---- |
| Windows 命令行版 | `dist\windows-hermes-install-cn-cli-x64.exe` | 内嵌母本 install-cn.ps1，双击或命令行均可 |
| Windows 图形版 | `dist\windows-hermes-install-cn-gui-x64.exe` | 参数上界面、日志实时滚动、底部进度条 |
| Linux/Kali 版 | `dist/linux-hermes-install-cn-x86_64` | shc 编译的单文件 ELF，源码为 `linux/install-cn.sh` |

### 1.3、固定默认行为（没有开关，脚本内部自动管理）

- **加速策略（FastGitHub 策略）**：断开 github.com（假代理 + 白名单直连）→ GitHub 下载数秒内失败 → 按官方回退顺序切 hermes-assets 官方镜像；三道护栏任一命中即**自动关闭并打印原因**：指定了 `-Proxy` 真代理、gh-proxy 探测不通、提前安装 Python 环境失败；
- **无人值守**：跳过安装期配置向导，装完用桌面版自带配置流程（要向导请直接跑官方脚本，见第 7 章）；
- **桌面图形版默认安装**；
- **版本渠道钉死 stable**：镜像 clone 时防止官方因非官方 origin 退化成跟随 main。

### 1.4、目录结构

```cmd
hermes_install_cn/
├── install-cn.ps1                 # Windows 母本（两个 exe 都内嵌它，唯一改动入口）
├── src/
│   ├── build.ps1                  # 统一编译（系统自带 csc，零工具链）
│   ├── cli/Program.cs             # 命令行版源码
│   └── gui/Program.cs             # 图形版源码
├── linux/
│   ├── install-cn.sh              # Linux 母本（bash）
│   └── upstream-install.sh        # 官方 install.sh 原件存档（仅供参照，永不执行）
├── dist/                          # 三个成品
└── README.md                      # 本文档
```

---

## 2、快速开始

### 2.1、Windows 命令行版

```powershell
# 默认：加速 + 无人值守 + 桌面版；零参数即完整安装
powershell -NoProfile -ExecutionPolicy Bypass -File C:\temp\hermes_install_cn\install-cn.ps1
```

- 双击 `dist\windows-hermes-install-cn-cli-x64.exe` 效果相同；exe 启动时会把窗口**锁定**（宽度钉 130 列、去掉拉伸边框、禁用最大化），避免安装中改窗口尺寸把进度显示拖花，退出时归还窗口样式；
- 验绿标志：`[OK] app products and hermes command ready` → `Desktop ready: …\Hermes.exe` → `Hermes Agent install complete`；
- 装完体检：`hermes doctor`（全新安装唯一 issue 应为"配置 API key"）。

### 2.2、Windows 图形版

- 双击 `dist\windows-hermes-install-cn-gui-x64.exe`；
- 界面只有三个需要决定的参数：**代理**（留空不用，例 `66.66.66.1:10808`）、**固化镜像变量到用户环境**、**只装命令行版**；其余行为按 1.3 固定；
- 日志窗两种颜色：灰白 = 标准输出，**暗黄 = 标准错误流**——注意 uv/npm 的惯例是把**进度**写进错误流，暗黄行多为正常进度，不是错误；
- 底部蓝色滑动进度条运行时出现、结束消失；失败后直接再点"开始安装"重跑，已下完的走缓存。

### 2.3、Linux / Kali

```bash
# 方式一：源脚本（可讲解可改）
bash install-cn.sh

# 方式二：单文件二进制
chmod +x linux-hermes-install-cn-x86_64
./linux-hermes-install-cn-x86_64

# 只体检不安装：7 站连通性测试 + 选线结果
./linux-hermes-install-cn-x86_64 --probe-only
```

装完三步走：

```bash
source ~/.zshrc        # 或新开终端——PATH 已由安装器写入
hermes doctor          # 体检，预期唯一 issue = 配置 API key
hermes desktop         # 启动桌面版（首次会注册应用菜单项）
```

- 装完成功后启动器会**自动生成桌面图标** `/root/Desktop/hermes-desktop.desktop`（图标跟随官方菜单条目的主题图标 `hermes`）；首次双击若提示"不受信任"，右键 → 允许启动；
- **root 启动桌面版**：Chromium 对 root 强制要求 `--no-sandbox`（crbug 638180），官方把是否降级留作显式选择，本启动器替 root 定下：图标的 Exec 内联 `ELECTRON_DISABLE_SANDBOX=1`，并同步写入 `~/.zshrc / ~/.zprofile / ~/.profile / ~/.xsessionrc` 四处；非 root 用户不注入，保持官方沙箱机制；
- 已装完的机器补图标（不重装）：

```bash
./linux-hermes-install-cn-x86_64 --make-desktop-icon
```

---

## 3、参数说明

### 3.1、Windows（3 个）

| 参数 | 作用 |
| ---- | ---- |
| `-Persist` | setx 固化 UV 两个镜像变量到用户环境（新窗口生效，以后 hermes update 也走国内源） |
| `-Proxy ip:端口` | 走真代理，如 `-Proxy 66.66.66.1:10808`（会自动关闭加速策略） |
| `-NoDesktop` | 默认装桌面图形版；加此参数只装命令行版 |

已删除的历史参数（旧课件/旧命令里出现会直接报"参数不存在"）：`-SkipProbe`、`-SkipWarmup`、`-SkipBrowser`、`-Channel`、`-FastGitHub`、`-NonInteractive`、`-PyMirror`——前四个场景如今全是默认行为，无需再传。

### 3.2、Linux（8 个 + 透传）

| 参数 | 作用 |
| ---- | ---- |
| `--probe-only` | 只跑镜像站连通性测试与选线，不下载不安装不写配置（体检用） |
| `--make-desktop-icon` | 给已装完的机器生成/修复桌面图标，立即退出 |
| `--no-fast` | 关闭加速策略（不断 GitHub） |
| `--proxy ip:端口` | 走真代理（自动关闭加速策略） |
| `--no-desktop` | 只装命令行版 |
| `--interactive` | 安装期走配置向导（默认无人值守） |
| `--persist` | UV 两个镜像变量固化进 `~/.bashrc`（幂等追加） |
| `-h / --help` | 帮助 |

其余参数原样透传官方 `install.sh`（如 `--channel main`、`--skip-browser`）。

---

## 4、安装流程五阶段

### 4.1、阶段一览（Windows 启动器，Linux 同款）

| 阶段 | 做什么 | 关键点 |
| ---- | ---- | ---- |
| [1/5] 下载镜像站连通性测试 | 对 7 个目标逐个测连通（清华 PyPI、阿里 PyPI 备选、npm 淘宝、gh-proxy、npmmirror 的 Python PBS、hermes-assets 官方兜底、安装器本体） | 正常几秒；单站超时上限 8 秒，失败自动回退直连；**安装器本体不可达会直接中断** |
| [2/5] 选择加速线路 | 按测试结果决定 PyPI 用谁、clone 走不走 gh-proxy、Python 本体镜像选谁 | 探测结果决定加速策略开不开 |
| [3/5] 提前安装 Python 环境 | 从官方安装器源码现读 uv 下载地址与 sha256（不写死版本），校验下载 uv，再用镜像把 Python 装进 uv 托管目录 | **仅加速开启时执行**；失败自动关闭加速策略继续装，绝不中断 |
| [4/5] 写入加速配置 | 进程级环境变量（本轮生效）+ 用户级持久文件：`~/.npmrc`、pip.ini、`~/.config/pip/pip.conf` | 持久层保证以后 `hermes update` 也走国内源 |
| [5/5] 执行官方安装器 | 注入加速环境后执行官方 install.ps1 / install.sh，结束还原现场 | 官方零改动；Linux 版执行完成功还会生成桌面图标 |

### 4.2、断点重跑原则

任何一步失败，**直接重跑同一条命令**：已下完的 git/uv/Python/依赖/桌面产物全在缓存里，不会重下（实测三轮 10054/10061/111 换源重试后正常走完均属设计内噪音）。

---

## 5、常见问题

### 5.1、看到 `retrying in 1s (attempt 2/4)` 之类的网络重试

- 正常噪音：某候选源不通，脚本自动换源重试（1s/2s/4s 退避）；
- attempt 打光只代表**该地址**放弃，通常会切下一个源继续；
- 真正的失败长这样：`[X] dependency install failed` / `products … failed (exit 1)`——此时按 4.2 重跑。

### 5.2、products 阶段报 `TypeError: fetch failed`（exit 1）

- 病根：electron-builder 的工具组（7zip/icons/winCodeSign 等）默认从 GitHub 下 `electron-builder-binaries`；
- 修法（官方源码 `electronGet.js getBinariesMirrorUrl()` 认这个变量，npmmirror 镜像 2026-10 实测 200）：

```powershell
# Windows：设置后重跑
setx ELECTRON_BUILDER_BINARIES_MIRROR https://registry.npmmirror.com/-/binary/electron-builder-binaries/
```

- 本项目启动器已默认注入该变量，正常不会遇到；直接跑官方脚本的人需要手动设。

### 5.3、npm / Electron 下载卡住

- 确认用户层 `~/.npmrc`（Linux）或 `%USERPROFILE%\.npmrc`（Windows）存在三键：`registry`、`electron_mirror`、`disturl`；
- ⚠️ **写错层 = 白写**：`%APPDATA%\npm\etc\npmrc` 是独立 Node 安装的全局层，安装器自带的 npm 读不到（2026-10 实测踩坑）。npm 四层配置（内置 → 用户 → 项目 → 全局）里**只有用户层每个 npm 都读**。

### 5.4、Kali 桌面版 root 启动 FATAL

- 现象：`Running as root without --no-sandbox is not supported`；
- 原因：官方对 root **故意不自动降级**（源码注释：root 无沙箱必须是显式选择）；
- 修法：`ELECTRON_DISABLE_SANDBOX=1 hermes desktop`，或直接用本启动器生成的桌面图标（已内联该开关），必要时 `--make-desktop-icon` 重新生成。

### 5.5、exe 启动报 `Exception.ToString() 失败`（历史缺陷，已修）

- 曾因 P/Invoke 把 `GetConsoleWindow` 误挂到 user32（它在 kernel32）导致启动即崩；
- 现行产物已修；如再遇到，先用自检确认产物完整性（见 6.1），自检绿而运行崩再报问题。

---

## 6、编译与二次开发

### 6.1、Windows exe（系统自带 csc，零工具链）

```powershell
# 全部编译（或加 -Only cli / -Only gui 只编一个）
powershell -NoProfile -ExecutionPolicy Bypass -File C:\temp\hermes_install_cn\src\build.ps1

# 自检：只解包内嵌脚本并打印 sha256，不触发安装
C:\temp\hermes_install_cn\dist\windows-hermes-install-cn-cli-x64.exe --selftest
```

- **母本唯一**：两个 exe 都在编译期把 `install-cn.ps1` 内嵌进去（csc `/resource`），改了 ps1 必须重编，否则 exe 跑的还是旧脚本；
- 自检输出的 sha256 应与母本一致（当前母本指纹：`662d223058507157f6a171cc6313abb04b7bcf942d0e49d9463b6c1a059e338e`）；
- ⚠️ **编码坑**：`.ps1`、`.cs` 含中文必须存成 **UTF-8 带 BOM**——PS5.1 和 csc 按 GBK 读无 BOM 文件会解析爆炸。

### 6.2、Linux ELF（Kali 上用 shc 编译）

```bash
# 语法检查
bash -n install-cn.sh

# shc 不认 #!/usr/bin/env bash 间接写法：编译副本换成直 shebang
sed '1s|.*|#!/bin/bash|' install-cn.sh > install-bin.sh

# Kali root 登录 shell 是 zsh，shc 只认 sh/bash 族：显式指定
SHELL=/bin/bash shc -r -f install-bin.sh -o linux-hermes-install-cn-x86_64

# 产物自跑（安全段）
./linux-hermes-install-cn-x86_64 --probe-only
```

- ⚠️ **`-r` 必须带**：不带 `-r` 的产物会把**编译机 `/bin/bash` 的文件属性（inode/size/mtime 等）折进加密密钥**（shc 的 `key_with_file` 机制），拿到 bash 版本不同的机器上就解密失败——屏幕上吐一串乱码后 exit 1。`-r` 跳过文件属性绑定，任意 Kali 可跑（2026-10 实测：Kali 2025.3 与 2026.2 交叉验证，不带 `-r` 在异版本 bash 上乱码、带 `-r` 两版均正常）。
- ⚠️ 别在中文 Windows 的记事本里编辑 `.sh`（换行/编码会被毁），改脚本在 Kali 上改；
- shc 产物运行时会把脚本解密到 `/tmp` 执行（机制使然），目标机 `/tmp` 需可写。

---

## 7、与官方的关系

### 7.1、零改动原则

- 每次运行**现拉最新官方脚本**（Windows 拉 install.ps1、Linux 拉 install.sh），做内容校验后执行；本项目只在外层包加速逻辑；
- 官方认的环境变量就是我们注入的通道，均有源码出处：

| 环境变量 | 作用 | 出处 |
| ---- | ---- | ---- |
| `HERMES_INSTALL_CHANNEL` | 钉 stable，绕过镜像 origin 检查 | install.ps1 / install.sh |
| `HERMES_REPO_URL` | clone 走 gh-proxy 镜像 | install.ps1 / install.sh |
| `UV_DEFAULT_INDEX`、`UV_PYTHON_INSTALL_MIRROR` | uv 的 PyPI/Python 本体镜像 | uv 自身读取 |
| `ELECTRON_BUILDER_BINARIES_MIRROR` | electron-builder 工具组走 npmmirror | app-builder-lib electronGet.js |
| `ELECTRON_MIRROR` | electron 本体镜像 | @electron/get |
| `ELECTRON_DISABLE_SANDBOX` | root 下桌面版显式开 --no-sandbox | hermes_cli/main_desktop.py |

### 7.2、官方图形安装器 Hermes-Setup.exe 是什么

- Tauri 实现的约 8MB 在线安装器，本体字符串原话：**signed installer that drives scripts/install.ps1**——它就是同一份 install.ps1 的图形驱动（`-Manifest` 读 stage 表逐段执行、自带脚本缓存）；
- **脚本路径本身就能完成含桌面版在内的全量安装**（2026-10 Windows 实测：从零到桌面快捷方式全绿），图形版与脚本不是二选一。

### 7.3、upstream-install.sh 的用途

| 文件 | 谁在用 |
| ---- | ---- |
| `linux/upstream-install.sh` | **纯参照、永不执行**：设计加速脚本的依据（uv 引脚格式、参数清单、环境变量语义），官方更新时 `diff` 它做回归检查 |
| 运行时下载到 `~/.cache/hermes-install-cn/upstream-install.sh` | **执行用**：每次现拉最新版（顺带当官方可达性硬闸门），预热段从这份最新版里现读 uv 引脚 |

---

## 8、验收记录（截至 2026-10-19）

- **Windows 冷启动全量**（全新快照 + 零参数）：全绿 exit 0，双快捷方式（开始菜单 + 桌面），`hermes doctor` 唯一 issue = 配置 API key；
- **命令行 exe**：编译通过，`--selftest` 内嵌指纹与母本一致；
- **图形 exe**：编译通过，自检指纹一致；进度条/窗口锁定/日志双色显示实测可用；
- **Kali 全量**：镜像站连通性测试 7 站全过、uv 引脚提取 `PIN_EXTRACT_OK`、官方安装器 exit 0、doctor 与 Windows 同签名、菜单项 `com.nousresearch.hermes.desktop` 注册、`linux-unpacked` 打包就位、桌面图标带官方主题图标；
- **实测可用的国内镜像（2026-10）**：gh-proxy.com、pypi.tuna.tsinghua.edu.cn、registry.npmmirror.com（含 electron-builder-binaries 与 python-build-standalone 子镜像）、hermes-assets.nousresearch.com 官方兜底。
