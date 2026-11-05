# 开发指南

## 工具链

ReSign 是 Swift Package Manager 项目，入口为根目录 `Package.swift`。可使用 Xcode 打开该文件，也可直接使用 `swift` 命令构建。项目最低目标为 macOS 27。

构建依赖安装：

```sh
brew install libimobiledevice libplist pkgconf
```

## 构建与测试

执行完整构建：

```sh
bash scripts/build-app.sh
```

运行默认测试：

```sh
swift test --filter ReSignTests
```

需要真实网络或 USB 设备的测试通过环境变量显式启用，命令见 [docs/TESTING.md](docs/TESTING.md)。提交代码前至少运行与改动范围相关的测试；涉及认证、签名、设备安装或持久化的改动应同时记录已验证范围。

## 代码约定

- 外部输入必须在进入签名、设备传输或认证流程前完成校验，错误信息应说明失败原因和可执行的下一步。
- 认证身份、Anisette 注册状态和会话上下文必须保持一致，不为兼容性猜测做静默降级或身份切换。
- 网络、钥匙串和设备操作失败时应保留原始资料，不自动清空或重建用户状态。
- 注释只用于解释协议约束、安全要求和非显然的状态依赖，不重复代码表面行为。
- 面向用户的文本使用简体中文；日志和错误信息避免输出密码、令牌、原始认证响应或完整账号数据。

## 提交规范

提交信息使用 Conventional Commits，例如 `feat(ipa): 支持应用图标`、`fix(auth): 修复会话恢复`。常用类型为 `feat`、`fix`、`perf`、`refactor`、`test`、`docs`、`build`、`ci` 和 `deps`。发布说明会按类型自动分类，未采用此格式的提交仍会保留在“其他变更”中。

每个提交应聚焦一个明确改动，正文说明变更原因和验证范围。发布标签与产物说明见 [docs/RELEASING.md](docs/RELEASING.md)。

## 依赖管理

- 提交 `Package.swift`、`Package.resolved` 和 `Vendor/SideSign` 源文件。
- `Vendor/SideSign` 按固定提交内置，保留必要且已记录的上游修改；来源、许可证和修改说明见 [Vendor/SideSign/UPSTREAM.md](Vendor/SideSign/UPSTREAM.md)。
- 修改内置依赖时同步更新修改记录。
- 不提交 `.build`、`.app`、下载的二进制、本机动态库、真实 `.env` 或 Tunnel Token。

## 目录与数据

- 运行时资料位于 `~/Library/Application Support/io.resign.mac/`，不属于源码目录。
- Apple 登录会话、认证身份和签名私钥由应用保存到 macOS 钥匙串，不导出进 Git。
- 不提交个人 IPA、开发证书、描述文件、真实部署 Token 或含账号信息的数据。
- 自建后端的服务器状态和 Docker 卷独立管理，部署配置见 [deploy/anisette](deploy/anisette/README.md)。

## 许可证

源码遵循根目录 GPL-3.0 许可证，组件来源见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。发布二进制前需满足内嵌依赖的许可证、通知和对应源码／重新链接材料要求。
