# ReSign Design System

> 面向 AI Coding Agent 与开发者的 macOS 27 SwiftUI 设计规范。
> 令牌唯一事实来源：`Sources/ReSign/AppTheme.swift`
> 视图实现参考：`ReSignApp.swift`、`ContentView.swift`、`LoginView.swift`、`SettingsView.swift`、`NetworkConnectionView.swift`、`UpdateSourceView.swift`

## 1. Visual Theme & Atmosphere

- **风格定位**：原生 macOS 27 桌面工具，遵循 Apple Human Interface Guidelines 与 macOS Liquid Glass 语言（`.glassEffect`、`.buttonStyle(.glass)`、`.buttonStyle(.glassProminent)`、`GlassEffectContainer`、`.scrollEdgeEffectStyle(.soft)`、`.safeAreaBar`）。
- **气质原则**：清晰、克制、状态一目了然。优先使用系统语义色与原生材质，不引入网页风自定义主题或花哨动效。
- **外观模式**：通过 `AppAppearance` 支持三态切换（`system` 跟随系统、`light` 浅色、`dark` 深色），设置页切换时通过 `AppModel.setAppearancePreview(_:)` 实时预览，所有主窗口与 Sheet 统一应用 `.preferredColorScheme(model.effectiveAppearance.colorScheme)`。
- **界面语言**：全部面向用户文本使用简体中文，标点统一使用中文全角标点（如全角省略号 `…`、顿号 `／` 与 `、`、全角书名号/引号），技术标识（Bundle ID、URL、版本号、IP）保持原文或等宽显示。

## 2. Color Palette & Theme Tokens

### 系统语义角色

| 角色 | SwiftUI Token | 用途 |
| --- | --- | --- |
| 主强调色 | `.accentColor` / `.tint` | 活跃设备图标、运行中阶段徽章、待安装提示、主操作按钮 |
| 在线 / 成功 | `.green` | 已信任在线设备圆点、续签完成徽章 |
| 警告 / 异常 | `.orange` | 未信任设备、需要重新登录、失败状态徽章、错误信息与警告横幅 |
| 次要 / 离线 | `.secondary` / `.tertiary` | 副标题、时间戳、未连接文案、右箭头、Bundle ID |
| 卡片基底 | `.background.secondary` | 所有 `.themedCardSurface` 的底层填充 |

### ThemePalette 令牌（唯一来源：`Sources/ReSign/AppTheme.swift`）

> 以下不透明度数值由 `scripts/check-consistency.py` 与 `Sources/ReSign/AppTheme.swift` 自动核对一致。修改 `AppTheme.swift` 时必须同步更新本表。

| Token | Base | Light Opacity | Dark Opacity | 用途 |
| --- | --- | --- | --- | --- |
| `cardBorder` | `Color.primary` | `0.07` | `0.13` | 卡片描边（0.5pt） |
| `cardHighlight` | `Color.white` / `.clear` | `0.00` | `0.03` | 深色模式卡片顶层微提亮 |
| `iconBorder` | `Color.primary` | `0.08` | `0.14` | 应用图标外框（0.5pt） |
| `iconPlaceholder` | `Color.primary` | `0.05` | `0.09` | 缺失图标占位底色 |
| `pillBackground` | `Color.primary` | `0.07` | `0.12` | 活动计数胶囊等中性徽章背景 |
| `offlineIndicator` | `Color.secondary` | `0.30` | `0.45` | 离线设备状态圆点 |
| `subtlePrimaryText` | `Color.primary` | `0.80` | `0.88` | 次要容器内强调文本（如更新来源标题） |
| `glassTintOpacity` | `Double` | `0.16` | `0.24` | Sheet 顶部圆形图标玻璃着色不透明度 |
| `bannerBackground(_:)` | `tint` | `0.10` | `0.16` | `StatusBanner` 背景填充 |
| `bannerBorder(_:)` | `tint` | `0.22` | `0.32` | `StatusBanner` 描边（0.5pt） |
| `warningBackground()` | `Color.orange` | `0.08` | `0.14` | `themedWarningSurface` 警告框背景 |
| `warningBorder()` | `Color.orange` | `0.18` | `0.28` | `themedWarningSurface` 警告框描边（0.5pt） |
| `badgeBackground(_:)` | `tint` | `0.12` | `0.18` | `stageBadge` 胶囊状态背景 |

## 3. Typography & Copy Rules

- **字体族**：完全使用 macOS 系统字体（SF Pro + 苹方），不引入第三方字体。
- **字号层级**：
  - Sheet 主标题：`.title2.weight(.semibold)`（登录、设置）或 `.title3.weight(.semibold)`（带图标头的精简 Sheet，如 IP 连接、更新来源）
  - 区块标题 / 卡片应用名：`.headline`
  - 侧边栏账号名 / 卡片副信息：`.subheadline.weight(.semibold)` / `.subheadline`
  - 正文与说明提示：`.body` / `.callout`
  - 次要元数据、时间、状态徽章：`.caption` / `.caption.weight(.medium)`
  - 计数徽章与技术标识：`.caption2.weight(.medium)` / `.caption2.monospaced()`
- **等宽与可选中**：
  - 活动时间戳必须使用 `.monospacedDigit()` 保持纵向对齐。
  - Bundle ID（`.caption2.monospaced()`）、错误消息与活动记录必须加 `.textSelection(.enabled)`，便于用户复制排障。
- **文案约定**：
  - 触发弹窗或次级流程的按钮以全角省略号结尾（如 `设置…`、`通过 IP 连接…`、`更新来源…`）。
  - 错误提示同时说明原因与可执行操作，避免裸露英文系统错误码或堆栈。

## 4. Component Stylings

### Card & Warning Surfaces（定义于 `AppTheme.swift`）

- **标准卡片**：`.themedCardSurface(cornerRadius: ..., palette: palette)`
  - 组合 `cardHighlight` + `.background.secondary` + `0.5pt` `cardBorder` 连续圆角（`.continuous`）。
  - 常用圆角：应用卡片 `18`、活动日志卡片 `16`、登录页内嵌分组 `14`、当前团队提示 `12`。
- **警告容器**：`.themedWarningSurface(cornerRadius: ..., palette: palette)`
  - 组合 `warningBackground()` + `0.5pt` `warningBorder()` 连续圆角。
  - 常用圆角：登录页错误框 `12`、应用卡片错误框 `10`。

### Liquid Glass Buttons & Interactive Containers

- **主操作按钮**：`.buttonStyle(.glassProminent)` + `.buttonBorderShape(.capsule)`（工具栏主按钮 `导入 IPA` 除外，工具栏直接使用 `.buttonStyle(.glassProminent)`）。
- **次要操作按钮**：`.buttonStyle(.glass)` + `.buttonBorderShape(.capsule)`。
- **相邻玻璃按钮分组**：两个及以上横向相邻的玻璃按钮必须包裹在 `GlassEffectContainer(spacing: 8)` 中。
- **交互式卡片/入口按钮**：使用 `.buttonStyle(.plain)` + `.contentShape(RoundedRectangle(...))` + `.glassEffect(.regular.interactive(), in: RoundedRectangle(...))`（如侧边栏底部账号栏、登录页开发团队选择行）。
- **圆形图标菜单按钮**：应用卡片“更多操作”使用 `24×24` 圆形 `.glassEffect(.regular.interactive(), in: Circle())` + `.menuStyle(.borderlessButton)` + `.menuIndicator(.hidden)` + `.accessibilityLabel(...)`。

### Status Indicators & Badges

- **状态横幅（`StatusBanner`）**：连续圆角 `14`，内边距 `horizontal: 16, vertical: 12`，`palette.bannerBackground(tint)` + `0.5pt` `bannerBorder(tint)`，右侧可选 `.controlSize(.small)` 胶囊玻璃动作按钮。
- **阶段徽章（`stageBadge`）**：胶囊形状（`Capsule()`），内边距 `horizontal: 8, vertical: 3`，背景 `palette.badgeBackground(stageColor)`；处于 `.authentication` / `.provisioning` / `.signing` / `.installing` 时前缀 `ProgressView().controlSize(.mini)`。
- **设备在线圆点**：`7×7` `Circle()`，信任在线为 `.green`，未信任为 `.orange`，离线为 `palette.offlineIndicator`。
- **应用图标容器**：`48×48`，连续圆角 `11`，`0.5pt` `palette.iconBorder` 描边，缺失图标时显示 `palette.iconPlaceholder` + `app.dashed`（`22pt` medium），设置 `.accessibilityHidden(true)`。

### Sheets & Forms

- 设置类/配置类 Sheet（`SettingsView`、`NetworkConnectionView`、`UpdateSourceView`）统一采用：
  - `Form { ... }.formStyle(.grouped).scrollEdgeEffectStyle(.soft, for: .vertical)`
  - `.safeAreaBar(edge: .top)` 承载标题栏（可配 `40×40` 圆形 `.glassEffect(.regular.tint(.accentColor.opacity(palette.glassTintOpacity)), in: Circle())` 图标）
  - `.safeAreaBar(edge: .bottom)` 承载错误提示与操作按钮栏
- 登录 Sheet（`LoginView`）采用紧凑 `VStack` 布局（`padding(26)`，`48×48` 圆形玻璃图标），并在登录进行中或待选团队时设置 `.interactiveDismissDisabled(...)`。

## 5. Layout, Window & Spacing Scale

### 窗口与 Sheet 尺寸

| 界面 | 尺寸约束 |
| --- | --- |
| 主窗口（`Window("ReSign", id: "main")`） | `minWidth: 920, minHeight: 640`，`defaultSize(width: 1080, height: 740)`，`.windowToolbarStyle(.unified)` |
| 侧边栏（`NavigationSplitView`） | `min: 230, ideal: 256, max: 300`，`.listStyle(.sidebar)` |
| `LoginView` | `width: 520`（高度自适应） |
| `NetworkConnectionView` | `width: 500, height: 360` |
| `UpdateSourceView` | `width: 570, height: 470` |
| `SettingsView` | `width: 570, height: 700` |

### 间距与圆角阶梯

| 类别 | 常用值 | 场景 |
| --- | --- | --- |
| 页面外边距 | `horizontal: 26, vertical: 22` | 主详情页 `ScrollView` 内容 |
| Sheet 顶部/底部栏内边距 | `horizontal: 22`（顶 `top: 18, bottom: 10`，底 `vertical: 14`） | `.safeAreaBar` 头部与底部按钮栏 |
| 区块间距 | `22` / `20` | 主详情区块间、登录页主纵向间距 |
| 卡片内边距与间距 | `padding(18)` / 卡片间 `14` | `AppCard` 及卡片列表 |
| 控件组间距 | `8` / `10` / `12` / `14` | 玻璃按钮组 `8`、横向图标+文案 `10~14` |
| 连续圆角（`.continuous`） | `18` / `16` / `14` / `12` / `11` / `10` | 应用卡片 `18`、活动/账号栏 `16`、横幅/内嵌卡片 `14`、提示框 `12`、图标 `11`、警告条 `10` |

## 6. Interaction, Guard States & Shortcuts

- **任务互斥禁用**：当 `model.isBusy`、`model.isScanning`、`model.isLoggingIn`、`model.isCheckingUpdates` 或 `model.startupError != nil` 时，按对应操作的互斥边界禁用按钮与菜单项，并在非标准按钮（如 `.buttonStyle(.plain)` 玻璃入口）上配合 `.opacity(0.45~0.55)` 给出清晰视觉反馈。
- **键盘快捷键**：
  - 打开设置：`⌘,`（`CommandGroup(replacing: .appSettings)`）
  - Sheet 主确认按钮：`.keyboardShortcut(.defaultAction)`
  - Sheet 取消/关闭按钮：`.keyboardShortcut(.cancelAction)`
- **空状态与阻断态**：使用原生 `ContentUnavailableView`，明确说明前置步骤与主行动按钮。
- **常驻菜单栏**：`MenuBarExtra("ReSign", ...)` 在繁忙态切换图标为 `arrow.triangle.2.circlepath`，空闲态为 `signature`，禁止在繁忙/登录中退出应用。

## 7. Do's and Don'ts

### Do

- 所有浅色/深色自定义透明度和边框一律从 `ThemePalette(colorScheme: colorScheme)` 读取，不直接在视图里写死 `Color.black.opacity(...)` 或 RGB 十六进制色值。
- 新增 Sheet 时必须在挂载点传入 `.preferredColorScheme(model.effectiveAppearance.colorScheme)`，保证外观设置与实时预览一致生效。
- 复用 `.themedCardSurface`、`.themedWarningSurface` 与 `GlassEffectContainer(spacing: 8)`。
- 所有圆角统一使用 `RoundedRectangle(cornerRadius: ..., style: .continuous)`。
- 面向用户的错误信息和可复制技术字段使用 `.textSelection(.enabled)`。

### Don't

- 不要为自定义卡片引入硬编码背景色或重阴影（依赖 `.background.secondary` 与 `0.5pt` 描边维持原生层次）。
- 不要在未包装 `GlassEffectContainer` 的情况下并排堆叠多个 `.glass` 按钮。
- 不要在视图层直接执行磁盘/网络/钥匙串 I/O；统一通过 `AppModel` 入口触发并维护互斥状态。
- 不要绕过 `AppModel` 的繁忙状态守卫允许用户在签名/扫描过程中触发冲突写操作。
- 不要引入第三方 UI 框架或非系统字体。

## 8. Agent UI Quick Reference

| 需求 | 选用模式 |
| --- | --- |
| 展示托管应用或日志面板 | `.themedCardSurface(cornerRadius: 18 或 16, palette: palette)` |
| 展示表单/卡片内错误信息 | `.themedWarningSurface(cornerRadius: 12 或 10, palette: palette)` + `.foregroundStyle(.orange)` |
| 详情页顶部全局状态提示 | `StatusBanner(text:symbol:tint:actionTitle:...)` |
| 配置型弹窗（表单 + 底部保存/取消） | `Form { ... }.formStyle(.grouped)` + `.safeAreaBar(edge: .top)` + `.safeAreaBar(edge: .bottom)` |
| 底部按钮组 | `GlassEffectContainer(spacing: 8)` + `.glass`（取消）+ `.glassProminent`（确认）+ `.buttonBorderShape(.capsule)` |
| 列表空态或启动错误 | `ContentUnavailableView` |

### 标准配置 Sheet 骨架

```swift
Form {
    Section("分组标题") {
        // 原生控件 + .font(.caption).foregroundStyle(.secondary) 说明
    }
}
.formStyle(.grouped)
.scrollEdgeEffectStyle(.soft, for: .vertical)
.safeAreaBar(edge: .top) {
    // 标题栏（horizontal: 22, top: 18, bottom: 10）
}
.safeAreaBar(edge: .bottom) {
    // 错误提示 + GlassEffectContainer(spacing: 8) 取消/确认胶囊按钮
}
.frame(width: 570, height: 470)
```
