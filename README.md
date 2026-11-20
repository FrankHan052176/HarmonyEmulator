# HarmonyEmulator

基于 **Linux 6.6 + 开源 QEMU (`arm64_virt`)** 驱动的 **HarmonyOS 7 (`7.0.0.107`)** 模拟器与独立管控服务 **`HarmonyEmulatorDashboard`**，支持 **macOS arm64 (Apple Silicon HVF)** 与 **Linux arm64 (KVM)** 双平台一键部署，自带实时交互 Web 控制台与标准 **MCP (Streamable HTTP)** 接口，可直接接入 **Fancy / Claude / Cursor** 等 AI 编程代理进行自动化真机级调试。

---

## 核心特性

- **双平台硬件虚拟化**：macOS arm64 自动启用 Apple **HVF**，Linux arm64 自动启用 **KVM**，冷启动约 11 秒直达 HarmonyOS 7.0.0.107 桌面（支持预置跳过 OOBE 镜像与稀疏快速克隆）。
- **像素级清晰图形栈**：定制 `virtio-gpu` DRM/KMS 合成器（`native/display/`）+ 8 字节线性步幅对齐 `buffer_vdi`（彻底消除奇数宽度如 `153×153` 桌面图标斜切）+ SwiftShader Vulkan OHOS ICD 包装层（`native/vulkan/`）。
- **真二层桥接以太网（零 NAT）**：
  - 机内独立拉起 `dhcp_client`（SA `1126`）+ `EthernetManager` + `NetConnManager` + `VpnManager` + `/dev/net/tun`。
  - 宿主机侧：macOS 通过 `socket_vmnet --vmnet-mode=bridged` 桥接物理网卡（如 `en0`），Linux 通过 `br0` + `qemu-bridge-helper` 桥接物理网卡；`hdc` 管理通道独立走 `hdc0`（`restrict=on` 本机回环转发，无默认路由、无 NAT）。
- **AppGallery 标准化隐私放行**：内置可热切换的 `@kit.AppGalleryKit` `privacyManager` 代理（`native/framework/privacymanager_napi_qemu.c`），默认放行自签名调试应用（如 RustDesk/Resk），也可在控制台或 MCP 一键切换为未同意态用于回归测试。
- **私有开发者 PKI 一键签名安装**：拖放或指定本地 `.hap` 文件，自动调用 `hap-sign-tool.jar` 签名并通过 `hdc install -r` 安装拉起。
- **独立 `HarmonyEmulatorDashboard` + MCP**：纯 Go 标准库零外部依赖编译，提供实时 MJPEG 画面（点击=Tap、拖拽=Swipe）、物理按键与文字输入、HiLog / HDC Shell / 窗口树 / 网络 / 崩溃日志面板，以及 `/mcp` 8 个标准工具。

---

## 一键部署（拉完代码即可直接跑）

`./install.sh` 会自动完成全部环境与镜像准备，无需手动拷贝镜像：
1. 自动检查并安装 `qemu-system-aarch64` 等依赖；
2. 自动从本仓库 **GitHub Release (`v0.1.0`)** 下载：
   - 对应平台的预编译 `harmony-emulator-dashboard-{darwin,linux}-arm64` 二进制（约 7 MB）；
   - 自研内核、initramfs、512 MiB `qemu_overlay.img` 与配套自签测试 PKI（`hmos7-boot-overlay-arm64.tar.gz`，仅 62 MB）；
3. 自动调用 `scripts/fetch-donor.sh` 从华为官方公开 OTA CDN 拉取 Pura 70 Pro+ `7.0.0.107` 固件包并仅提取校验所需的 5 个只读分区（`system` / `vendor` / `sys_prod` / `chip_prod` / `cust`，逐一校验 SHA-256；如本机已有 `update_full_base.zip` 可传 `--donor-zip <路径>`，如本机已有现成镜像目录可传 `--images-from <路径>`）。
4. 首次启动实例时自动创建并格式化 4 GiB 稀疏 `userdata.img`（自动持久化，之后每次启动约 11 秒进入桌面）。

### macOS arm64（Apple Silicon）

```bash
git clone https://github.com/FrankHan052176/HarmonyEmulator.git
cd HarmonyEmulator

# 1. 一键部署（自动拉取二进制、启动镜像、预置数据分区与 5 个固件分区）
./install.sh

# 2. （推荐，仅执行一次）开启 en0 真二层桥接以太网（零 NAT）
sudo ./scripts/setup-bridged-macos.sh

# 3. 启动独立 Web 控制台与 MCP 服务（或执行 ./scripts/install-service.sh 注册常驻服务）
./bin/harmony-emulator-dashboard --listen 127.0.0.1:18555
```

### Linux arm64（Ubuntu / Debian / Fedora / Arch）

```bash
git clone https://github.com/FrankHan052176/HarmonyEmulator.git
cd HarmonyEmulator

# 1. 一键部署（自动安装 QEMU/KVM 依赖并拉取全部运行时镜像）
./install.sh

# 2. 授予当前用户 /dev/kvm 权限（首次需重新登录生效）
sudo usermod -aG kvm "$USER"

# 3. （推荐，仅执行一次）配置 br0 真二层桥接以太网（零 NAT）
sudo ./scripts/setup-bridged-linux.sh

# 4. 启动独立 Web 控制台与 MCP 服务（或执行 ./scripts/install-service.sh 注册 systemd 服务）
./bin/harmony-emulator-dashboard --listen 127.0.0.1:18555
```

---

## `hdc` 与签名工具 `hap-sign-tool.jar` 获取与放置说明

运行模拟器本身不需要任何专有工具，但与机内通信、执行 Shell、安装 `.hap` 依赖 **`hdc`**，自动签名未签名 `.hap` 依赖 **`hap-sign-tool.jar` + `UnsgnedDebugProfileTemplate.json`**（以及 Java 17+）。

### 1. 工具来源（华为官方 Command Line Tools / DevEco Studio / OpenHarmony SDK）

- **方式 A（推荐，官方命令行工具包）**：
  前往华为开发者联盟下载对应平台的 **Command Line Tools for HarmonyOS**（Mac ARM64 版或 Linux ARM64/x86_64 版；也可直接从本机已安装的 **DevEco Studio** 内置 SDK 中提取）。解压后工具位于：
  ```text
  command-line-tools/sdk/default/openharmony/toolchains/
  ├── hdc                                   # 按平台区分（macOS arm64 与 Linux arm64 需各自匹配）
  └── lib/
      ├── hap-sign-tool.jar                 # 纯 Java 包，macOS / Linux / Windows 全平台完全共用！
      └── UnsgnedDebugProfileTemplate.json  # 纯文本模板，全平台完全共用！
  ```
- **方式 B（开源源码自编译）**：
  `hdc` 对应 OpenHarmony 开源仓库 [`developtools_hdc`](https://gitee.com/openharmony/developtools_hdc)，`hap-sign-tool.jar` 对应 [`developtools_hapsigner`](https://gitee.com/openharmony/developtools_hapsigner)（Apache-2.0，可直接自行编译出 `Linux arm64` 版 `hdc` 或 `hap-sign-tool.jar`）。

> **关于跨平台共用**：`hap-sign-tool.jar` 和 `UnsgnedDebugProfileTemplate.json` 是纯 Java / JSON 文件，**macOS arm64 与 Linux arm64 可以直接拷贝共用同一份**，只需宿主机安装 Java 17+（`brew install openjdk` 或 `apt install openjdk-17-jre-headless`）。只有 `hdc` 是原生可执行文件，需要分别使用对应操作系统的版本。

### 2. 如何放进项目（任选其一，自动按优先级识别）

#### 方式 1：直接放到项目 `tools/` 目录（最省心，免配环境变量）

```bash
mkdir -p tools/signing

# 1) 放入当前平台对应的 hdc（macOS arm64 放 mac 版，Linux arm64 放 linux 版）
cp /path/to/sdk/default/openharmony/toolchains/hdc tools/hdc
chmod +x tools/hdc

# 2) 放入全平台共用的签名 jar 与模板（从任意已装 SDK 的机器拷贝一份即可）
cp /path/to/sdk/default/openharmony/toolchains/lib/hap-sign-tool.jar tools/signing/
cp /path/to/sdk/default/openharmony/toolchains/lib/UnsgnedDebugProfileTemplate.json tools/signing/
```

#### 方式 2：通过环境变量指向已有 SDK（无需复制文件）

```bash
# 指向 Command Line Tools 的 sdk 目录（自动同时识别 hdc 与 hap-sign-tool.jar）
export DEVECO_SDK_HOME="/path/to/command-line-tools/sdk"

# 或分别指定：
export OHOS_SDK_HOME="/path/to/sdk/default"
export HMOS7_HDC="/path/to/hdc"
```

放好后执行体检脚本确认全部绿灯：

```bash
./scripts/doctor.sh
```

---

## 目录结构

```text
HarmonyEmulator/
├── install.sh                       # macOS arm64 / Linux arm64 一键部署脚本
├── Makefile                         # 构建、测试、体检、打包快捷命令
├── dashboard/                       # 独立 Go 服务 HarmonyEmulatorDashboard（Web UI + REST + MCP）
├── scripts/
│   ├── run-hmos7.sh                 # 跨平台 QEMU arm64_virt 启动器
│   ├── fetch-donor.sh               # 自动从华为官方 CDN 拉取并解包校验 5 个固件分区
│   ├── sign-hap.sh                  # 跨平台 .hap 自动签名脚本
│   ├── setup-bridged-macos.sh       # macOS 一键开启 en0 真二层桥接（socket_vmnet）
│   ├── setup-bridged-linux.sh       # Linux arm64 一键开启 br0 真二层桥接（qemu-bridge-helper）
│   ├── install-service.sh           # 安装 macOS launchd / Linux systemd 常驻服务
│   ├── doctor.sh                    # 全链路环境、镜像、网络与 MCP 体检
│   └── package-runtime.sh           # 打包可迁移离线发行包（含 SHA256SUMS）
├── native/                          # 定制 C/C++ 组件源码（display / vulkan / framework）
├── build/                           # 镜像构建脚本（initramfs / overlay / native 交叉编译 / 信任库合并）
├── images/                          # 运行时镜像目录（由 install.sh 自动拉取，不纳入 Git）
├── signing/                         # 自签测试 PKI（由 install.sh 自动拉取，不纳入 Git）
└── tools/                           # 可选放置本机 hdc 与 hap-sign-tool.jar（不纳入 Git）
```

---

## 使用 Web 控制台与 MCP 接入

启动后直接访问：

- **Web 控制台**：`http://127.0.0.1:18555`
- **MCP 端点（Streamable HTTP）**：`http://127.0.0.1:18555/mcp`

在 **Fancy / Claude / Cursor** 的 MCP 配置中加入：

```json
{
  "mcpServers": {
    "harmony_emulator": {
      "type": "http",
      "url": "http://127.0.0.1:18555/mcp"
    }
  }
}
```

### 暴露的 MCP 工具清单

| 工具名 | 说明 |
| --- | --- |
| `ohos_status` | 查看宿主机架构、虚拟化加速、桥接就绪状态、运行中/已保存实例及端口 |
| `ohos_launch` | 启动或复用模拟器实例（支持 `reset`、`display`、`net_mode`、`peer`、`memory_mb`、`smp`） |
| `ohos_stop` | 同步文件系统、断开 `hdc` 并优雅停止单个或全部实例 |
| `ohos_observe` | 只读观测系统状态：`status` / `windows` / `hilog` / `faultlogs` / `bundles` / `network` |
| `ohos_screenshot` | 通过 QEMU QMP（或 `snapshot_display`）抓取 1080×2340 实时截图并落盘返回路径与 URL |
| `ohos_act` | 交互控制：`tap` / `swipe` / `key` / `text` / `launch_app` / `stop_app` / `wake` / `shell` |
| `ohos_install` | 自动使用私有 PKI 签名并安装 `.hap`（支持安装后自动拉起） |
| `ohos_privacy` | 查询或热切换 AppGallery 标准化隐私自动同意开关 |

---

## 常用命令与打包迁移

```bash
make test          # 运行 HarmonyEmulatorDashboard 单元测试
make build-all     # 交叉编译 darwin/arm64 与 linux/arm64 二进制到 dist/
make doctor        # 检查 QEMU / HVF|KVM / 桥接网络 / hdc / 镜像 / Dashboard 状态
make run           # 前台启动 HarmonyEmulatorDashboard
make package-kit   # 打包代码 + 双平台预编译二进制（不含大镜像）
make package-full  # 打包完整离线部署包（自动稀疏压缩并生成 SHA256SUMS）
```
