# 测试说明

测试环境：Apple Silicon、macOS 27.3、Swift 6.4.2、libimobiledevice 1.4.0（内置构建）、libplist 2.8.0。

## 默认自动化测试

```sh
swift test --filter ReSignTests
```

默认测试使用临时目录、合成 IPA 和 `URLProtocol` 拦截的 Apple 响应，不读取应用保存的登录会话。覆盖范围包括：

- 续签调度：待安装更新、到期判断、失败退避、连续失败暂停和自动续签开关。
- IP 直连：数值地址校验、旧设备记录兼容和地址持久化。
- 资料存储：损坏资料保留、读写往返、缓存路径逃逸校验。
- Anisette 服务地址：HTTPS 与本机 HTTP 规则。
- IPA 处理：解压、Bundle ID 重写、路径穿越、加密 Mach-O 和不支持的扩展目录。
- App Extension：多组件 Bundle ID 映射与重写、Widget 引用同步、扩展配置保留、版本同步及非法格式校验。
- App Group 兼容：团队专属映射稳定性、原共享组及已有映射复用、主应用与扩展一致性、Mach-O 单架构与 FAT 多切片兼容库注入。
- 应用图标：主图标尺寸选择、排除其他图标、旧版及 iPad 配置、缓存尺寸限制、缺失和损坏图片、缓存路径校验。
- 设备状态：USB／局域网连接类型解码和连接状态显示。
- 认证请求：客户端系统标签兼容、注册身份缓存隔离、请求头一致性、HTTP 状态与认证阶段、Apple 错误码分类。
- 会话刷新：设备、机器、本地用户、路由和客户端身份一致性校验。
- 软件更新：包内配置及二进制来源识别、候选歧义、GitHub Releases（附件匹配、Token 鉴权与凭据隔离、限额与权限错误）、AltStore 新旧格式与设备系统匹配、文件完整性与 IPA 身份校验、防降级、旧托管记录兼容和更新待安装调度。

## 显式启用的集成测试

需要枚举 USB／局域网设备时（局域网设备需先配对并在 Finder 中开启 Wi-Fi 显示）：

```sh
RESIGN_DEVICE_TEST=1 swift test --filter testNativeDeviceEnumeration
```

匿名 Anisette 注册、OTP 生成和身份复用：

```sh
RESIGN_INTEGRATION_URL="https://anisette.example.com" \
  swift test --filter testRemoteAnisetteProvisioningAndIdentityReuse
```

服务端 GSA 凭据错误探测：

```sh
RESIGN_INTEGRATION_URL="https://anisette.example.com" \
RESIGN_GSA_PROBE=1 \
  swift test --filter testGrandSlamRejectsSyntheticCredentialsAfterAcceptingAnisette
```

该测试覆盖虚构账号的凭据错误处理路径，不覆盖真实账号登录或签名。

## 真机验证

| 场景 | 状态 | 日期 |
| --- | --- | --- |
| 真实账号登录、证书与描述文件申请、IPA 重签、首次安装和启动 | 通过 | 2026-11-05 |
| Apple 认证兼容修复后的真实账号重新登录 | 通过 | 2026-11-25 |
| 重启后账号、设备和托管记录恢复 | 通过 | 2026-11-05 |
| 不同版本覆盖安装后应用数据保留 | 通过 | 2026-11-05 |
| 手机热点局域网连接 | 通过 | 2026-11-06 |
| 校园网 IP 直连：身份校验、心跳维持、IPA 传输与手动续签安装 | 通过 | 2026-11-06 |
| USB／局域网同时在线时设备去重与 USB 优先 | 通过 | 2026-11-14 |
| 无线自动续签触发与任务恢复 | 通过 | 2026-11-14 |
| 设备物理断开重连后的发现与任务恢复 | 通过 | 2026-11-14 |
| 临近到期自动续签及有效期延长 | 通过 | 2026-11-14 |
| 分享扩展多描述文件签名、首次安装、面板调用与覆盖续签 | 通过 | 2026-11-14 |
| 分享扩展 App Groups 授权及共享容器通信 | 通过 | 2026-11-14 |
| Action、WidgetKit、通知、自定义键盘、照片编辑及 Intents 等扩展的首次安装、调用与覆盖续签 | 通过 | 2026-11-15 |
| 非分享扩展的 App Groups 通信、额外能力授权及缺失权限报错 | 通过 | 2026-11-15 |
| 主应用与扩展原始版本不同的 IPA：版本同步、安装及覆盖续签 | 通过 | 2026-11-15 |
| 原共享组不可注册时的映射组注册、签名、安装、容器与 UserDefaults 共享及覆盖续签 | 通过 | 2026-11-15 |
| IP 直连到错误设备时的身份／证书不匹配拒绝路径 | 待验证 | — |
| IP 地址变化、错误地址、清除地址和重启恢复 | 待验证 | — |
| IP 直连长时间传输、心跳中断、扫描与安装互斥及退出清理 | 待验证 | — |
| 到期自动续签的失败退避与恢复 | 待验证 | — |
