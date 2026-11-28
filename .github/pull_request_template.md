## 变更摘要

<!-- 简述本次改动的目标与背景 -->

## 影响范围

- [ ] SwiftUI 界面 / 主题（`Sources/ReSign/*View.swift`、`AppTheme.swift`）
- [ ] 状态调度与持久化（`AppModel.swift`、`Models.swift`、`LibraryStore.swift`、`KeychainVault.swift`）
- [ ] Apple 认证与 Anisette（`AnisetteService.swift`、`RemoteAnisetteClient.swift`、`SigningService.swift`）
- [ ] IPA / App Extension / App Groups（`IPAService.swift`、`AppGroupCompatibility.swift`、`MachOLibraryInjector.swift`、`Resources/AppGroupRuntime/`）
- [ ] 软件自动更新（`IPAUpdateService.swift`）
- [ ] 设备通信与桥接（`DeviceService.swift`、`Sources/NativeBridge/`、`Vendor/MobileDevice/`）
- [ ] 构建、脚本、CI 或文档

## 验证记录

- [ ] `make lint`（一致性、令牌、版本、依赖、编码与脚本语法检查）
- [ ] `make test`（默认隔离单元测试）
- [ ] `make verify`（完整 release 构建与严格签名验证，涉及打包/资源/桥接改动时勾选）
- [ ] 显式集成测试或真机验证（如有，请补充具体场景并同步更新 `docs/TESTING.md`）

## 额外检查

- [ ] 若修改了 `Sources/ReSign/AppTheme.swift`，已同步更新 `DESIGN.md`
- [ ] 若修改了 `Vendor/` 内嵌源码，已同步更新对应 `UPSTREAM.md`
- [ ] 确认未提交任何个人 IPA、证书、描述文件、Token 或真实 `.env`
