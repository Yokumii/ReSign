# ReSign Repository Guidelines

面向所有 AI Coding Agent 与开发者的项目操作手册。架构细节见 `docs/ARCHITECTURE.md`，界面与视觉规范见 `DESIGN.md`。

## Project Structure & Module Organization

- `Sources/ReSign/`：macOS 27+ SwiftUI 主应用（`ReSignApp`、`AppModel` 状态中枢、SwiftUI 视图、签名/认证/IPA/更新/设备服务、Mach-O 注入器、`AppTheme`）。
- `Sources/NativeBridge/`：C / Objective-C 桥接层（`Devices.c`、`NetworkHeartbeat.c`、`Anisette.m`、`include/NativeBridge.h`），向上暴露 `rs_*` C 接口给 Swift；调用方负责用 `rs_free` 释放返回指针。
- `Resources/`：`Info.plist`（**版本号唯一来源**）、应用图标与 `AppGroupRuntime/`（独立编译的 iOS `ReSignAppGroups.framework` 源码，用于 App Groups 重定向）。
- `Tests/ReSignTests/`：默认隔离运行的单元测试，使用临时目录、合成 IPA 与 `URLProtocol` 桩响应，不访问真实账号或设备；集成测试通过环境变量显式开启。
- `Vendor/`：按固定提交内置的上游源码（`Vendor/SideSign/`、`Vendor/MobileDevice/`）。**严禁随手格式化或未登记即修改**；任何改动必须同步更新对应的 `UPSTREAM.md`。
- `scripts/`、`build.command`：构建、依赖打包、许可证收集、DMG/Release 生成与一致性校验脚本；`Makefile` 汇总常用入口。
- `docs/`：架构（`ARCHITECTURE.md`）、测试（`TESTING.md`）、发布流程（`RELEASING.md`）、后续计划（`ROADMAP.md`）和版本补充说明（`docs/releases/<version>.md`）。
- `deploy/anisette/`：Anisette v3 与 Cloudflare Tunnel 部署模板（不提交真实 `.env` 或 Token）。
- `dist/`、`.build/`、`.swiftpm/`：本地构建产物，均不纳入 Git。

## Setup, Build, and Verification Commands

最低环境：Apple Silicon (`arm64`)、macOS 27+、包含 iPhoneOS SDK 的完整 Xcode（Swift 6 工具链）、Homebrew 与 Python 3。

```sh
# 1. 安装原生依赖（首次）
brew install libplist libusbmuxd libimobiledevice-glue openssl@4 pkgconf

# 2. 启用仓库内置 pre-commit 钩子（首次）
make hooks

# 3. 常用开发与验证命令
make lint        # 静态检查：文档/令牌/版本/依赖一致性 + Python/Shell 语法 + 日志与编码卫生
make test        # 运行默认单元测试（自动清除集成测试环境变量，与 CI 一致）
make check       # lint + test（日常改动的最小完成门槛）
make build       # 完整 release 构建并生成 dist/ReSign.app（含 iOS ReSignAppGroups.framework）
make dmg         # 构建并生成 dist/ReSign.dmg
make verify      # CI 等价全量验证：lint + test + build + codesign --verify --deep --strict
make format      # 使用 .swift-format 格式化 Sources/ReSign 与 Tests/ReSignTests（建议仅格式化改动文件）
```

定向测试与显式集成测试：

```sh
swift test --filter ReSignTests/<TestClassName>
RESIGN_DEVICE_TEST=1 swift test --filter testNativeDeviceEnumeration
RESIGN_INTEGRATION_URL="https://anisette.example.com" swift test --filter testRemoteAnisetteProvisioningAndIdentityReuse
RESIGN_INTEGRATION_URL="https://anisette.example.com" RESIGN_GSA_PROBE=1 swift test --filter testGrandSlamRejectsSyntheticCredentialsAfterAcceptingAnisette
```

## Local Development Notes

- `swift build` / `swift test` 编译 `NativeBridge` 与 `Vendor/MobileDevice` 时需要 Homebrew `pkg-config` 路径；若手动调用 `swift` 报缺库，先执行 `export PKG_CONFIG_PATH="$(brew --prefix)/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"`。
- 完整应用运行（尤其是涉及 App Groups 重映射）依赖 `scripts/build-app.sh` 编译并内嵌 `ReSignAppGroups.framework`；单独 `swift run` 缺少 `.app` bundle 资源，不要以 `swift run` 替代 `make build` 验证打包行为。
- 涉及 Swift 格式化时优先对**已修改文件**执行 `swift format format --in-place <file>`，不要对未改动文件或 `Vendor/` 做全仓重排，避免无关 diff 噪音。
- 运行时数据位于 `~/Library/Application Support/io.resign.mac/`，钥匙串服务名为 `io.resign.mac`；测试必须使用临时目录与独立钥匙串或桩实现，绝不污染本机真实资料。

## Coding Style & Naming Conventions

- 遵循 `.editorconfig` 与 `.swift-format`：UTF-8、LF 换行、4 空格缩进（YAML/JSON 为 2 空格）。
- 外部输入（IPA 压缩包、Mach-O、Plist、IP 地址、更新源 URL、Anisette 地址、GitHub Token）必须在进入认证、签名或设备传输前完成校验。
- 面向用户的文案与错误提示使用**简体中文**，错误消息必须写明失败原因和可执行的下一步（通过 `ReSignError` 抛出）。
- 日志统一走 `AppModel.record(_:)`；**禁止**在 `Sources/ReSign/` 中新增裸 `print(`、`debugPrint(` 或 `NSLog(`，且任何日志/报错都不得输出密码、Token、原始认证响应或完整账号数据。
- 注释仅用于解释协议约束、安全边界与非显然状态依赖，不复述代码字面逻辑。

## Testing Guidelines

- 任何代码改动提交前至少运行 `make check`（或定向测试 + `make lint`）。
- 修改以下敏感域时必须补充或更新对应测试，并在 `docs/TESTING.md` 中更新验证记录：
  - 认证与 Anisette：`AuthenticationRequestTests.swift`
  - IPA / App Extension：`IPAExtensionTests.swift`
  - App Group 映射与 Mach-O 注入：`AppGroupCompatibilityTests.swift`
  - 软件更新源与版本校验：`IPAUpdateTests.swift`
  - IP 直连与地址校验：`NetworkConnectionTests.swift`
  - 续签调度、资料存储、图标与设备状态：`ReSignTests.swift`
- 涉及真实设备通信、签名安装或 Apple 认证链路的改动，需记录真机验证结果；未完成真机验证的事项登记到 `docs/ROADMAP.md` 与 `docs/TESTING.md`。

## Development Workflow

- **分支命名**：`feature/...`、`fix/...`、`refactor/...`、`test/...`、`docs/...`、`chore/...`。
- **提交规范（Conventional Commits）**：`<type>(<scope>): <简明中文摘要>`。`scripts/generate-release-notes.py` 依赖前缀自动分类：
  - `feat`（新增功能）、`fix`（问题修复）、`perf`（性能优化）、`refactor`（代码重构）、`test`（测试）、`docs`（文档）、`build` / `ci` / `deps`（构建与发布）；破坏性变更在类型后加 `!` 或在正文写 `BREAKING CHANGE:`。
- 每个提交聚焦一个明确目标，正文说明改动原因与验证范围，不混入无关的依赖锁定或格式噪音。

## Release & Versioning

- `Resources/Info.plist` 的 `CFBundleShortVersionString` 是版本号唯一来源；发布标签必须严格为 `v<major>.<minor>.<patch>`。
- 发布新版本时同步检查：`Resources/Info.plist`、`README.md` 版本声明、`docs/releases/<version>.md` 补充说明。
- 正式发布由推送 `v*` 标签触发 `.github/workflows/release.yml` 创建 Draft Release，使用 ad-hoc 签名且不公证；严禁覆盖已公开 Release。

## Design Reference

- 任何 SwiftUI 视图、样式或交互修改前先阅读 `DESIGN.md`。
- 浅色/深色视觉令牌的唯一事实来源为 `Sources/ReSign/AppTheme.swift`（`ThemePalette`、`themedCardSurface`、`themedWarningSurface`）；修改 `AppTheme.swift` 时必须同步更新 `DESIGN.md`，并由 `scripts/check-consistency.py` 校验一致。

## Critical Invariants & Security Notes

- **认证与身份一致性**：Anisette 注册身份、客户端系统标签（`<Mac OS X;`）、路由信息（`X-Apple-I-MD-RINFO`）与登录会话上下文（`AppSettings.authenticationContext`）必须严格一致；**禁止**为兼容猜测做静默降级（如 v3 降级 v1、Windows ↔ Mac 切换或回退首张描述文件）。
- **失败保底原则**：网络、钥匙串、签名、设备通信或更新检查失败时，必须保留原有本地资料与上一份 IPA，不得自动清空或重建用户状态；`library.json` 必须原子写入，写盘失败不更新内存态。
- **状态互斥**：`AppModel` 为 `@MainActor` 单一状态源，导入、扫描、登录、更新检查与签名安装由 `isBusy` / `isScanning` / `isLoggingIn` / `isCheckingUpdates` 保护，签名与安装跨设备串行执行，避免与设备扫描并发冲突。
- **二进制与路径安全**：IPA 解压拒绝路径穿越、符号链接、特殊文件与 FairPlay 加密 Mach-O；缓存文件名校验不得逃逸目录；更新源仅允许不含凭据的 HTTPS，GitHub Token 仅向 `https://api.github.com` 发送且重定向跨主机时剥离 `Authorization`。
- **凭据与构建物隔离**：绝不提交 `*.ipa`、`*.p12`、`*.key`、`*.pem`、`*.mobileprovision`、真实 `.env`、Tunnel Token 或个人账号数据。
- **内嵌依赖治理**：修改 `Vendor/SideSign/` 或 `Vendor/MobileDevice/` 必须更新其 `UPSTREAM.md`；升级 `AnisetteKit` 或二进制依赖必须同步检查 `Package.resolved`、`scripts/binary-sources.json` 与 `THIRD_PARTY_NOTICES.md`。

## Automated Checks & Git Hooks

- `scripts/check-consistency.py`：校验 `CLAUDE.md -> AGENTS.md` 软链接、`DESIGN.md` 与 `AppTheme.swift` 令牌一致、`Info.plist` 与 `README.md` / `docs/releases/` 版本一致、固定依赖版本一致、UTF-8/LF、禁止裸打印语句与禁止跟踪敏感文件。
- `scripts/check.sh`：统一本地与 CI 入口（`--static` / 默认 / `--verify`）。
- `.githooks/pre-commit`：通过 `make hooks` 启用，在提交前拦截敏感文件与构建产物，并对暂存的 Python/Shell 脚本、一致性敏感文件及 Swift 文件执行快速检查。
