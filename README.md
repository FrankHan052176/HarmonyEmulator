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

## 目录结构

```text
HarmonyEmulator/
├── install.sh                       # macOS arm64 / Linux arm64 一键部署脚本
├── Makefile                         # 构建、测试、体检、打包快捷命令
├── dashboard/                       # 独立 Go 服务 HarmonyEmulatorDashboard（Web UI + REST + MCP）
├── scripts/
│   ├── run-hmos7.sh                 # 跨平台 QEMU arm64_virt 启动器
│   ├── sign-hap.sh                  # 跨平台 .hap 自动签名脚本
│   ├── setup-bridged-macos.sh       # macOS 一键开启 en0 真二层桥接（socket_vmnet）
│   ├── setup-bridged-linux.sh       # Linux arm64 一键开启 br0 真二层桥接（qemu-bridge-helper）
│   ├── install-service.sh           # 安装 macOS launchd / Linux systemd 常驻服务
│   ├── doctor.sh                    # 全链路环境、镜像、网络与 MCP 体检
│   └── package-runtime.sh           # 打包可迁移离线发行包（含 SHA256SUMS）
├── native/                          # 定制 C/C++ 组件源码（display / vulkan / framework）
├── build/                           # 镜像构建脚本（initramfs / overlay / native 交叉编译 / 信任库合并）
├── images/                          # （本地运行时镜像，不纳入 Git）
├── signing/                         # （本地自签 PKI，不纳入 Git，由 build-m2-native.sh 生成）
└── tools/                           # （可选放置本机 hdc 与 hap-sign-tool.jar，不纳入 Git）
```

---

## 运行时镜像与工具准备

由于镜像包含设备固件分区且体积较大，本仓库仅托管源码与自动化脚本，不包含二进制镜像和华为 SDK 专有工具。运行前需准备好以下文件：

1. **运行时镜像**（放入 `images/` 目录，或通过 `./install.sh --images-from <目录或压缩包>` 导入）：
   ```text
   images/
   ├── kernel/Image                 # 打过 OHOS binder / access_token_id / selinux 补丁的 Linux 6.6 内核
   ├── initramfs.cpio.gz            # 包含 m1-init.sh 及 kstate.ko / hwlog.ko / ashmem.ko
   ├── qemu_overlay.img             # 512 MiB ext4 覆盖分区（由 build/build-overlay-m2.sh 构建）
   ├── userdata-provisioned.img     # （可选）已跳过 OOBE 的预置数据分区
   └── donor/
       ├── system.img
       ├── vendor.img
       ├── sys_prod.img
       ├── chip_prod.img
       └── cust.img
   ```
2. **HarmonyOS 工具**：
   - 将对应平台（macOS arm64 / Linux arm64）的 `hdc` 加入 `PATH`、放到 `tools/hdc`，或设置环境变量 `HMOS7_HDC=/path/to/hdc`（也支持自动识别 `OHOS_SDK_HOME` / `DEVECO_SDK_HOME`）。
   - 若需自动签名安装未签名 `.hap`，需安装 Java 17+，并设置 `OHOS_SDK_HOME`/`DEVECO_SDK_HOME`（或将 `hap-sign-tool.jar` 与 `UnsgnedDebugProfileTemplate.json` 放到 `tools/signing/`），同时将私有 PKI 放到 `signing/`。

---

## 一键部署

### macOS arm64（Apple Silicon）

```bash
# 1. 一键安装依赖、编译/部署二进制并体检（如已有镜像目录可加 --images-from）
./install.sh --images-from /path/to/images

# 2. （推荐，仅执行一次）开启 en0 真二层桥接以太网（零 NAT）
sudo ./scripts/setup-bridged-macos.sh

# 3. （可选）注册为 macOS LaunchAgent 常驻后台服务
./scripts/install-service.sh --listen 127.0.0.1:18555
```

### Linux arm64（Ubuntu / Debian / Fedora / Arch）

```bash
# 1. 一键安装 QEMU/KVM/Java 等依赖并部署二进制
./install.sh --images-from /path/to/images

# 2. 授予当前用户 /dev/kvm 访问权限（首次需重新登录生效）
sudo usermod -aG kvm "$USER"

# 3. （推荐，仅执行一次）配置 br0 真二层桥接以太网（零 NAT）
sudo ./scripts/setup-bridged-linux.sh

# 4. （可选）注册为 systemd 常驻服务（加 --system 可注册为系统级服务）
./scripts/install-service.sh --listen 127.0.0.1:18555
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
