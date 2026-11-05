# 发布流程

## 版本与构建要求

- 版本号唯一来源是 Resources/Info.plist 的 CFBundleShortVersionString，标签必须为 v主版本.次版本.修订版本。
- 当前发布目标为 Apple Silicon arm64、macOS 27.0+。
- GitHub Actions 构建使用 xcode-27 运行器。仓库必须允许使用该运行器标签，并允许 Release 作业写入仓库内容。
- 应用使用 ad-hoc 签名，不导入 Developer ID 证书，也不执行 Apple 公证。发布说明和 BUILD-INFO.json 必须明确记录签名状态。
- 工作流中的第三方 Actions 固定到完整提交，构建作业只有仓库读取权限。
## CI

`.github/workflows/ci.yml` 在推送到 main、向 main 发起 Pull Request 或手动触发时运行：

1. 检查运行器、Xcode、Swift 和 Homebrew 依赖。
2. 运行默认测试。USB、外部 Anisette 和 GSA 探测测试保持跳过。
3. 执行 release 构建并验证应用签名。
4. 上传 ZIP 构建产物，保留 14 天。

建议在 GitHub 分支保护中将 Test and build (macOS 27, arm64) 设为必需检查。

## Release

推送版本标签会触发 `.github/workflows/release.yml`：

```sh
git tag -a v1.0.0 -m "ReSign 1.0.0"
git push origin v1.0.0
```

流程分为两个作业：

1. build：校验标签与 Info.plist 版本一致，运行测试和 release 构建，生成应用包、源码包、依赖源码包、构建信息和 SHA-256 校验文件。
2. release：下载同一次运行的构建产物，校验哈希，根据 Git 提交生成发布说明，并创建 Draft Release。

在 GitHub Release 页面检查附件和发布说明后手动发布。重新运行同一标签可以更新 Draft Release；已公开的 Release 不允许覆盖，后续修改应使用新版本号和新标签。

## 发布说明

发布说明由以下内容组成：

1. `docs/RELEASE_TEMPLATE.md`：通用下载、系统要求、签名和许可证说明。
2. `docs/releases/<版本>.md`：可选的版本补充。`1.0.0` 使用该文件记录功能和验证范围。
3. `scripts/generate-release-notes.py`：从上一个版本标签到当前标签的非合并提交生成分类摘要。

提交信息使用 Conventional Commits：

```text
feat(ipa): 显示真实应用图标
fix(auth): 修复会话恢复失败
test(storage): 覆盖损坏资料读取
docs: 更新发布说明
```

| 提交前缀 | 发布说明分组 |
| --- | --- |
| `feat` | 新增功能 |
| `fix` | 问题修复 |
| `perf` | 性能优化 |
| `refactor` | 代码重构 |
| `test` | 测试 |
| `docs` | 文档 |
| `build`、`ci`、`deps` | 构建与发布 |
| 其他 | 其他变更 |

提交类型后带叹号，或正文包含 `BREAKING CHANGE:` 的提交，归入不兼容变更。不符合格式的提交仍会保留在其他变更中。

## 发布附件

| 文件 | 内容 |
| --- | --- |
| `ReSign-<版本>-macos-arm64.zip` | ad-hoc 签名、未公证的应用包 |
| `ReSign-<版本>-source.tar.gz` | 标签对应的项目源码 |
| `ReSign-<版本>-dependencies.tar.gz` | Swift Package 源码、Homebrew 源码归档、Unicorn 源码、许可证和构建元数据 |
| `BUILD-INFO.json` | 提交、版本、架构、工具链、源码下载地址及哈希 |
| `SHA256SUMS` | 所有附件的 SHA-256 |

发布脚本要求工作区干净、标签指向当前提交，并校验锁定依赖版本。构建信息记录实际运行器与工具链版本；Homebrew 软件包会滚动更新，因此不承诺逐字节可复现构建。

## 本地验证

```sh
swift test --filter ReSignTests
bash scripts/build-app.sh
```

在干净且已打标签的提交上，可以使用与工作流相同的打包脚本：

```sh
RELEASE_TAG=v1.0.0 python3 scripts/package-release.py
```

应用签名、依赖许可证收集和发布打包逻辑分别位于 `scripts/build-app.sh`、`scripts/collect-notices.py` 和 `scripts/package-release.py`。
