# SideSign 上游记录

- 来源：https://github.com/SideStore/SideSign
- 固定提交：`752d1ef602aa792a432ffa1e71646dc1ecf7363c`
- 上游声明许可证：GNU GPL-3.0，见其 README 与本项目 LICENSE。
- 保留原作者和文件头。

本地修改：

1. 仅声明 macOS library 目标；移除上游 CLI 和测试目标，固定核心依赖提交。
2. `Sources/Logging.swift`：默认禁用 debug 输出，避免认证错误路径将原始响应写入控制台。
3. `Sources/Anisette/RemoteAnisetteDataProvider.swift`：v3 identifier 按协议使用原始 UUID 字节的 Base64；禁用根路径 v1 降级。
4. `Sources/CodeSigning/CodeSignerAPI.swift`：找不到精确 Bundle ID 对应描述文件时返回缺失错误，不使用第一个描述文件兜底。
5. `Sources/Constants.swift` 与 `Sources/DeveloperPortal/Authentication.swift`：将实际收到的 `-20970`（账户信息不正确）归类为凭据错误，避免把它当成未知服务错误。
6. `Sources/DeveloperPortal/Authentication.swift`：请求的 User-Agent 跟随传入的 Anisette 身份；未知 Apple 错误携带握手／密码／签名令牌阶段。注册、密码登录和令牌申请使用同一提供方身份，不做 Windows → Mac 声明切换或自动重试。
7. `Sources/Models/AppBundle.swift`、`Sources/CodeSigning/CodeSignerAPI.swift`：统一读取 Mach-O 中的签名权限；签名时校验 App Groups 是否已获描述文件授权，仅写入应用请求的共享组。
8. `Sources/CodeSigning/CodeSignerAPI.swift`：扩展权限仅匹配对应扩展目录或可执行文件路径；优先识别内嵌 framework 与 dylib，避免依赖库继承扩展权限。
9. `Sources/CodeSigning/CodeSignerAPI.swift`：扩展请求的额外权限若未出现在描述文件中，明确报错并提示配置对应 App ID 的能力，避免重签时静默丢弃扩展权限。
10. `Sources/CodeSigning/CodeSignerAPI.swift`：接受显式 App Group 映射，按映射后的组名校验描述文件和写入签名权限，同步处理以原 App Group 命名的钥匙串访问组；未传映射时保留原有库行为。
11. `Sources/DeveloperPortal/Authentication.swift`：认证响应错误包含阶段、HTTP 状态及内容类型；非 2xx 响应按失败处理，Apple 结构化错误保留原有分类。

未修改 SRP、令牌解密算法或代码签名格式实现。认证请求行为由 `Tests/ReSignTests/AuthenticationRequestTests.swift` 覆盖；真实账号与真机验证状态见 [docs/TESTING.md](../../docs/TESTING.md)。

依赖提交来自该提交附带的 `Package.resolved`：

| 依赖 | 固定版本／提交 |
| --- | --- |
| swift-crypto | 4.3.1 |
| swift-asn1 | 1.6.0（CodeSignKit 的依赖） |
| CodeSignKit | d0c67710fda9a2646b9e829cb2cf443892728371 |
| GSACryptoKit | eae2590eaf17fe98ce9c76b3ec2bd42b780eb123 |
| libdeflate | da6c7dae03b78dc71af973664575e4209786fbfe |
| AnisetteKit | db8b41022697b6c19be8a5f01a1ce834145a2a26 |
