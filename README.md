# ReSign

ReSign 是使用 SwiftUI 编写的 macOS iOS 应用签名与自动续签工具。登录 Apple 开发者账号并导入 IPA 后，应用会在启动、Mac 唤醒和设备重新连接时检查临近到期的托管应用，并通过 USB 或局域网重新签名和安装。

## 功能

- 单 Apple 账号与开发团队，支持 GSA 登录和设备／短信双重认证。
- 通过 USB 或局域网连接已配对设备；自动发现不可用时可直接填写 IP，双通道在线时优先使用 USB。
- 导入普通 IPA，保存独立的安装源和稳定的签名 Bundle ID。
- 从 IPA 提取并缓存主应用图标，缺失或无法解码时使用占位图。
- 申请开发证书、注册设备和 App ID、获取及更新描述文件。
- 使用 SideSign／CodeSignKit 重签，并通过 AFC／Installation Proxy 安装或覆盖更新。
- 默认在剩余不足 48 小时时续签，可在 12～72 小时内调整。
- 启动、设备连接恢复、Mac 唤醒和定时任务均可触发续签检查。
- 关闭窗口后通过菜单栏继续运行，可配置登录 Mac 时启动。
- 账号会话、签名私钥和 Anisette 身份保存在 macOS 钥匙串，不保存 Apple 账号密码。

## 环境要求

- macOS 27+
- 支持 Swift 6 的 Xcode
- Homebrew
- `libplist`、`libusbmuxd`、`libimobiledevice-glue`、`openssl@4`、`pkgconf`
- 构建时使用 Python 3；应用运行时不需要 Python
- Anisette v3 服务。macOS 27 上旧式本机 AOSKit 认证不可用，项目不内置认证服务

安装构建依赖：

```sh
brew install libplist libusbmuxd libimobiledevice-glue openssl@4 pkgconf
```

## 构建

```sh
bash scripts/build-app.sh
```

也可以双击 `build.command`。脚本会解析固定版本的 Swift 依赖、执行 release 构建、收集运行所需动态库，并生成 `dist/ReSign.app`。默认使用 ad-hoc 签名；如需指定 macOS 代码签名身份：

```sh
RESIGN_CODESIGN_IDENTITY="Developer ID Application: Example" bash scripts/build-app.sh
```

这里的 Mac 应用签名与为 iOS IPA 申请的开发证书相互独立。

构建后可生成 DMG 安装镜像：

```sh
python3 scripts/package-dmg.py dist/ReSign.dmg
```

打开 DMG，将 `ReSign.app` 拖入“应用程序”即可安装。CI 构建产物和 Release 中的应用附件均使用 DMG 格式。

## 使用

1. 打开 `dist/ReSign.app`，连接并解锁 iPhone／iPad，按设备提示信任 Mac。
2. 在设置中填写 Anisette v3 服务根地址，登录 Apple 账号并选择开发团队。
3. 在设备列表中选择设备，导入可重签的普通 IPA。
4. 首次运行安装后的应用时，按 iOS 提示完成信任和开发者模式设置。
5. 保持 ReSign 在菜单栏运行；设备在线且应用临近到期时会自动处理。

### 局域网连接

1. 首次通过 USB 连接 iPhone／iPad，解锁设备并信任这台 Mac。
2. 在 Finder 侧边栏选择设备，打开“通用”，勾选“接入 Wi-Fi 时显示此 [设备]”，点击“应用”。参见 [Apple 的 Wi-Fi 连接说明](https://support.apple.com/zh-cn/guide/mac-help/mchlada1d602/mac)。
3. 确认设备与 Mac 位于同一局域网，拔掉 USB，在 ReSign 中点击“扫描设备”，也可等待下一轮自动扫描（每轮扫描完成后间隔 10 秒）。
4. 设备状态显示“局域网已连接”后，即可导入、安装和自动续签；同时连接 USB 时优先使用 USB。

普通局域网中，ReSign 使用系统发现的已配对网络设备，无需手动填写 IP。仅接入同一局域网不足以连接，必须先完成上述配对和 Finder 设置。如 macOS 提示局域网访问权限，请允许 ReSign 访问；若未发现设备，请确认 Finder 中可以无线看到设备，并排除访客网络或无线客户端隔离。网络中断会使当前安装失败，恢复连接后可重新续签。

### 校园网等组播受限网络

如果设备之间可以通过 IP 通信，但 Finder 无法无线发现设备，可绕过自动发现：

1. 先通过 USB 配对设备、开启 Finder 的 Wi-Fi 显示，并让 ReSign 保存设备记录。
2. 在设备“设置 → Wi-Fi → 当前网络 ⓘ”中查看 IP 地址。
3. 在 ReSign 中选中该设备，点击工具栏“通过 IP 连接”，填写 IPv4 或可路由的 IPv6 地址，保存后自动连接；也可右键设备进入。
4. 拔掉 USB 后，状态显示“IP 直连已连接”即可使用此通道安装和续签。连接失败时界面会显示原因。

地址保存到设备记录中，重启后继续使用。USB 始终优先；已通过自动发现连通的设备无需再次尝试手动地址。IP 变化后需手动更新；留空保存可清除地址、恢复自动发现。暂不支持主机名、端口、带作用域的 IPv6 链路本地地址或整段网络扫描。

IP 直连必须使用已有 USB 配对，连接时校验设备身份及配对证书，并在连接期间维护无线心跳会话。安装期间暂停设备扫描，避免干扰正在使用的无线连接。它只绕过发现，不绕过网络访问控制；配对、心跳、文件传输和安装服务端口都必须可达。设备通信使用内置固定版本的 libimobiledevice 动态库，构建方式及本地修改见 [Vendor/MobileDevice/UPSTREAM.md](Vendor/MobileDevice/UPSTREAM.md)。

远程 Anisette 服务只参与 Anisette 身份注册和 OTP 生成，Apple 账号认证请求由客户端直接发送给 Apple。服务地址必须使用 HTTPS；明文 HTTP 仅允许 `localhost`、`127.0.0.1` 和 `::1`。

## 项目结构

| 路径 | 内容 |
| --- | --- |
| `Sources/ReSign/` | SwiftUI 界面、资料管理、签名与续签流程 |
| `Sources/NativeBridge/`、`Vendor/MobileDevice/` | 设备通信及本机认证桥接 |
| `Tests/` | 单元测试与显式启用的集成测试 |
| `Resources/` | 应用包配置 |
| `Vendor/` | 内置依赖源码、版本记录和许可证 |
| `scripts/`、`build.command` | 本机构建、依赖打包和发布脚本 |
| `.github/workflows/` | CI 与标签发布工作流 |
| `deploy/anisette/` | Anisette v3 服务与 Cloudflare Tunnel 部署模板 |
| `docs/` | 测试、发布流程与后续计划 |
| `dist/` | 本地生成的应用包和发布附件，不纳入 Git |

开发约定见 [CONTRIBUTING.md](CONTRIBUTING.md)，测试说明见 [docs/TESTING.md](docs/TESTING.md)，发布流程见 [docs/RELEASING.md](docs/RELEASING.md)，后续事项见 [docs/ROADMAP.md](docs/ROADMAP.md)。

## 运行时数据

资料保存在 `~/Library/Application Support/io.resign.mac/`：

- `library.json`：设备、托管应用、有效期、失败次数和设置。
- `IPAs/`：导入的 IPA 副本。
- `Work/`：签名操作的临时工作区。
- `Icons/`：从 IPA 提取的应用图标缓存。
- `Anisette/`：认证提供方路由缓存；ADI 身份和密钥保存在钥匙串。

资料以原子写入方式保存；写入失败时不会更新内存状态。停止托管只删除本地记录和 IPA 副本，不卸载设备上的应用。退出账号会删除登录会话，但保留已有签名证书，供同一团队再次登录后复用。

## 测试

```sh
swift test --filter ReSignTests
```

默认测试不访问真实 Apple 账号或外部 Anisette 服务。匿名 Anisette 集成测试和服务端 GSA 探测测试需要显式设置环境变量，具体命令和覆盖范围见 [docs/TESTING.md](docs/TESTING.md)。

## 已知限制

- 仅支持普通 IPA；不处理 App Extension、Watch 子应用、App Clip、符号链接、特殊文件或 FairPlay 加密的 IPA。
- 仅支持单 Apple 账号，未实现插件注入、App Store 应用和多账号。
- 局域网连接依赖设备与 Mac 已配对且 Finder 已启用 Wi-Fi 显示；自动连接还需系统能够发现设备。手机热点局域网连接、校园网 IP 直连和手动续签安装已完成真机验证；临近到期自动续签、心跳异常和断线恢复仍待验证。
- 应用退出或 Mac 关机后无法续签；设备需可通信，Apple 服务需可用。
- 令牌过期或再次要求双重认证时，需要用户重新登录。
- 工具为导入的应用生成自己的稳定 Bundle ID，不接管其他工具安装的应用，也不迁移其应用数据。
- Anisette 后端兼容性取决于 Apple 当前认证服务和后端版本，升级后应使用真实账号完成登录和签名验证。

## 版本与发布

当前版本为 1.0.0，版本号以 `Resources/Info.plist` 为唯一来源。推送 `v主版本.次版本.修订版本` 标签后，GitHub Actions 会运行测试、构建 arm64 应用、打包源码和依赖，并创建 Draft Release。签名、运行器和附件说明见 [docs/RELEASING.md](docs/RELEASING.md)。

## 许可证

项目以 GPL-3.0 分发。组件来源和许可证见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
