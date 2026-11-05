# ReSign

ReSign 是使用 SwiftUI 编写的 macOS iOS 应用签名与自动续签工具。登录 Apple 开发者账号并导入 IPA 后，应用会在启动、Mac 唤醒和设备重新连接时检查临近到期的托管应用，并通过 USB 重新签名和安装。

## 功能

- 单 Apple 账号与开发团队，支持 GSA 登录和设备／短信双重认证。
- 通过 USB 发现设备，并保存历史设备名称和 UDID。
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
- `libimobiledevice`、`libplist`、`pkgconf`
- 构建时使用 Python 3；应用运行时不需要 Python
- Anisette v3 服务。macOS 27 上旧式本机 AOSKit 认证不可用，项目不内置认证服务

安装构建依赖：

```sh
brew install libimobiledevice libplist pkgconf
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

远程 Anisette 服务只参与 Anisette 身份注册和 OTP 生成，Apple 账号认证请求由客户端直接发送给 Apple。服务地址必须使用 HTTPS；明文 HTTP 仅允许 `localhost`、`127.0.0.1` 和 `::1`。

## 项目结构

| 路径 | 内容 |
| --- | --- |
| `Sources/ReSign/` | SwiftUI 界面、资料管理、签名与续签流程 |
| `Sources/NativeBridge/`、`Sources/CMobileDevice/` | 设备通信及本机认证桥接 |
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
- 仅支持单 Apple 账号，未实现 Wi-Fi 安装、插件注入、App Store 应用和多账号。
- 应用退出或 Mac 关机后无法续签；设备需可通信，Apple 服务需可用。
- 令牌过期或再次要求双重认证时，需要用户重新登录。
- 工具为导入的应用生成自己的稳定 Bundle ID，不接管其他工具安装的应用，也不迁移其应用数据。
- Anisette 后端兼容性取决于 Apple 当前认证服务和后端版本，升级后应使用真实账号完成登录和签名验证。

## 版本与发布

当前版本为 1.0.0，版本号以 `Resources/Info.plist` 为唯一来源。推送 `v主版本.次版本.修订版本` 标签后，GitHub Actions 会运行测试、构建 arm64 应用、打包源码和依赖，并创建 Draft Release。签名、运行器和附件说明见 [docs/RELEASING.md](docs/RELEASING.md)。

## 许可证

项目以 GPL-3.0 分发。组件来源和许可证见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
