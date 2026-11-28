.PHONY: help lint lint-swift format test check build dmg verify hooks

help: ## 显示可用工程命令
	@grep -E '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  make %-12s %s\n", $$1, $$2}'

lint: ## 静态检查（文档/令牌/版本/依赖一致性、日志与编码卫生、脚本语法）
	@bash scripts/check.sh --static

lint-swift: ## 对 Swift 源码运行 swift-format 建议性检查（可传 FILES="path1 path2"）
	@bash scripts/check.sh --swift-lint $(FILES)

format: ## 按 .swift-format 格式化 Swift 源码（建议仅传 FILES="path1" 格式化已改动文件）
	@if [ -n "$(FILES)" ]; then \
		swift format format --configuration .swift-format --in-place $(FILES); \
	else \
		swift format format --configuration .swift-format --in-place --recursive Sources/ReSign Tests/ReSignTests; \
	fi

test: ## 运行默认隔离单元测试（与 CI 环境变量一致）
	@unset RESIGN_DEVICE_TEST RESIGN_INTEGRATION_URL RESIGN_GSA_PROBE; \
	if command -v brew >/dev/null 2>&1; then \
		export PKG_CONFIG_PATH="$$(brew --prefix)/lib/pkgconfig$${PKG_CONFIG_PATH:+:$$PKG_CONFIG_PATH}"; \
	fi; \
	swift test --filter ReSignTests

check: ## 日常质量门禁：lint + test
	@bash scripts/check.sh

build: ## 构建 release 应用包 dist/ReSign.app
	@bash scripts/build-app.sh

dmg: build ## 构建应用并打包 dist/ReSign.dmg
	@python3 scripts/package-dmg.py dist/ReSign.dmg

verify: ## CI 等价全量验证：lint + test + build + codesign 严格校验
	@bash scripts/check.sh --verify

hooks: ## 启用仓库内置 Git hooks（.githooks/）
	@git config core.hooksPath .githooks
	@chmod +x .githooks/pre-commit scripts/check.sh scripts/check-consistency.py
	@echo "Git hooks enabled (core.hooksPath=.githooks)."
