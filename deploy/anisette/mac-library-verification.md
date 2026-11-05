# Mac ADI 库校验记录

校验日期：2026-11-05。

- 镜像：`ghcr.io/fdkevin0/anisette-server-rs@sha256:ed0d022626510c5f9c51fd7129755d5e40bfb341f4e3f895ed857404798e438d`
- 上游提交：`6a4b0fbb9e83e43e1011aa636b73c06050ede14d`
- 目标文件：`/assets/CoreADI-26.x86_64`
- 架构与版本：x86_64，macOS 26.7.1（25G241），`com.apple.adid`
- 上游声明的下载来源：`https://sharebin.eu/files/CoreADI.x86_64`（非 Apple 官方域名）
- 文件大小：3,677,696 字节
- SHA-256：`4b6b320f08edcf5d65ed1141399b76a8d9323fee2045c577c5d2f30f35a5dae1`
- 签名证书链：macOS Software Signing → Apple Code Signing Certification Authority → Apple Root CA
- CDHash：`3fcf4f77c21cef8e19143ac3cd6375dcc711cd91`

签名校验命令：

```sh
codesign --verify --strict -R '=anchor apple' CoreADI-26.review
```

校验退出码为 0。文件未随本仓库分发；哈希和签名验证确认镜像内文件与上游固定记录一致，运行时兼容性仍由实际认证流程验证。

来源：

- [anisette-server-rs](https://github.com/fdkevin0/anisette-server-rs)
- [macos-26.json](https://github.com/fdkevin0/anisette-server-rs/blob/6a4b0fbb9e83e43e1011aa636b73c06050ede14d/assets/manifests/macos-26.json)
