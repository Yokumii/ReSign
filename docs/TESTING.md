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
- 应用图标：主图标尺寸选择、排除其他图标、旧版及 iPad 配置、缓存尺寸限制、缺失和损坏图片、缓存路径校验。
- 设备状态：USB／局域网连接类型解码和连接状态显示。
- 认证请求：提供方请求头保持一致、令牌拒绝不切换身份、错误报告认证阶段。
- 会话刷新：设备、机器、本地用户、路由和客户端身份一致性校验。

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
| 重启后账号、设备和托管记录恢复 | 通过 | 2026-11-05 |
| 不同版本覆盖安装后应用数据保留 | 通过 | 2026-11-05 |
| 手机热点局域网连接 | 通过 | 2026-11-06 |
| 校园网 IP 直连：身份校验、心跳维持、IPA 传输与手动续签安装 | 通过 | 2026-11-06 |
| IP 直连到错误设备时的身份／证书不匹配拒绝路径 | 待验证 | — |
| IP 地址变化、错误地址、清除地址和重启恢复 | 待验证 | — |
| IP 直连长时间传输、心跳中断、扫描与安装互斥及退出清理 | 待验证 | — |
| USB／局域网同时在线时设备去重与 USB 优先 | 待验证 | — |
| 无线自动续签触发与任务恢复 | 待验证 | — |
| 设备物理断开重连后的发现与任务恢复 | 待验证 | — |
| 临近到期自动续签及有效期延长 | 待验证 | — |
| 到期自动续签的失败退避与恢复 | 待验证 | — |
