# ReSign {version}

原生 macOS 的 iOS 应用签名、USB 安装与自动续签工具。

## 下载与安装

- 应用包：`{app_archive}`。
- 支持 Apple Silicon Mac，最低 macOS {minimum_macos}。
- 该构建使用 ad-hoc 签名，未使用 Developer ID，也未经过 Apple 公证。首次打开时如被 Gatekeeper 阻止，请在 Finder 中右键应用并选择“打开”。
- 需要自行配置可用的 Anisette v3 服务；发布包不包含账号、证书或 Tunnel Token。
- 使用 `SHA256SUMS` 校验下载的附件。

## 源码与许可证

附件包含项目源码、依赖源码、第三方许可证、`BUILD-INFO.json` 和校验文件。项目采用 GPL-3.0；组件来源和重新构建说明见 `THIRD_PARTY_NOTICES.md` 与 `docs/RELEASING.md`。
