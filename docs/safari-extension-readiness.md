# Safari Web Extension readiness

本文记录 **AwaitCue for Safari** 的构建、权限、真实验收和发布状态。Safari 扩展嵌入现有 `AwaitCue.app`；它不是第二个需要用户安装的辅助 App。

## 当前状态

| 项目 | 状态 | 证据 / 剩余工作 |
| --- | --- | --- |
| DOM-only 页面证据 | Ready | Safari 与 Chromium 共用页面文字、ARIA、状态 class、坐标、fingerprint 和 evidence availability 逻辑；不包含浏览器图片字段。 |
| Safari manifest | Ready | Manifest V3；`nativeMessaging`、`storage` 与 HTTP/HTTPS host access；不声明 `tabCapture` 或 `offscreen`。 |
| Safari packager | Ready | Xcode packager 对当前构建不再报告 unsupported manifest key。 |
| Native message codec | Ready | Swift 测试拒绝 `image`、`imageDataURL`、`screenshot`、`pixels`，并执行 24 KiB 上限。 |
| `.appex` 构建 | Ready | `Scripts/build-safari-extension.sh` 生成 macOS 14+ universal `.appex`。 |
| Containing app embedding | Ready | `Scripts/build-app.sh` 将 `.appex` 放入 `AwaitCue.app/Contents/PlugIns/`。 |
| 本地插件注册 | Ready | `pluginkit` 可识别 `org.awaitcue.AwaitCue.SafariExtension` 和 `com.apple.Safari.web-extension`。 |
| Safari 启用与网站权限 | 需要用户操作 | 用户必须在 Safari 设置中启用扩展并授权网站访问；AwaitCue 不能静默完成。 |
| 真实 Safari Target E2E | Manual gate | 需要启用扩展后验证全局框选、具体 tab、DOM evidence、后台 mutation、关闭/导航和权限撤销。 |
| Developer ID / App Group | External blocker | 发布脚本已强制校验并嵌入 containing app 与 extension 两份 Developer ID provisioning profile；仍需 Apple Developer Team 中注册 App Group、创建 profiles、提供证书并做真实进程验证。 |

## 产品能力

Safari Browser Target 只读取用户选区内的：

- 页面文字和相对坐标；
- ARIA、role、title、alt、value、max；
- `data-state`、`data-status` 和有限状态 class；
- 当前 tab URL、host、title；
- 用于抑制重复模型调用的 evidence fingerprint。

它不读取浏览器截图、tab 视频、canvas pixels 或图片 pixels。纯 Canvas、纯图片或缺少可读语义的区域返回 `availability: insufficient` / `no_semantic_content`，应用把它展示为“页面内容不足”并按 uncertain 处理。

## 架构

```text
Safari content script
        ↓ runtime message
Safari background
        ↓ native messaging
AwaitCueSafariExtension.appex
        ↓ authenticated loopback relay
AwaitCue.app
        ↓ user-configured Responses API endpoint
Decision model
```

Containing app 与 native extension 仅通过 `group.org.awaitcue.shared` 共享 `native-bridge.json`。该文件只包含本机 loopback port 和短期随机 token，不包含 URL、DOM、Condition、截图或模型请求。

AwaitCue 发给 Safari 的命令使用 `SFSafariApplication.dispatchMessage`；Safari 返回的事件通过 native extension 进入现有 relay。两条方向都必须完成 `ready → ping → pong`，不能把单向连接误报为可用。
当正式签名或 provisioning 不含 App Group 时，设置页会明确显示“App Group 不可用”，不会把它误报成普通的“等待扩展连接”。

## 构建和自动化验证

```bash
npm --prefix BrowserExtension ci
npm --prefix SafariExtension test
npm --prefix BrowserExtension run build:safari

swift test --filter AwaitCueSafariBridgeTests
CONFIGURATION=debug ./Scripts/build-safari-extension.sh
./Scripts/build-app.sh

test -x dist/AwaitCue.app/Contents/PlugIns/AwaitCueSafariExtension.appex/Contents/MacOS/AwaitCueSafariExtension
plutil -lint dist/AwaitCue.app/Contents/PlugIns/AwaitCueSafariExtension.appex/Contents/Info.plist
```

Required CI runs the shared TypeScript coverage gate, Safari adapter behavior tests, Swift Safari bridge tests, unsigned Xcode `.appex` build, and complete app-bundle embedding check. CI cannot grant Safari website permission, so it must not claim that a mock or unsigned build replaced the manual real-browser gate.

## 本机真实验收

1. 构建并以 Development 或 Developer ID identity 签名完整 `AwaitCue.app`。
2. 启动 AwaitCue，在设置的“浏览器”页点击“打开扩展设置”。
3. 在 Safari 设置中启用 **AwaitCue for Safari**，并允许测试 host。
4. 打开固定测试页，通过全局快捷键框选 DOM 状态区域。
5. 验证创建窗口显示具体 Safari tab、host 和正确 DOM evidence，且没有图片证据。
6. 将 tab 切到后台，修改测试页文字或状态 class，验证 evidence 继续更新。
7. 关闭 tab、导航离开原 URL、撤销 host 权限，分别验证 Target Unavailable 或明确权限错误。
8. 对普通窗口、全屏、隐藏工具栏、不同缩放和多显示器校准 Safari viewport 坐标。

第 8 项未通过前，不能宣称 Safari 全局框选已达到 Chromium 的精确坐标质量。

## 签名与分发

正式站外分发按从内到外的顺序签名：

1. `AwaitCueNativeHost`；
2. `AwaitCueSafariExtension.appex`，带 Safari extension/App Group entitlements；
3. `AwaitCue.app`，带相同 App Group entitlement；
4. 验证完整 bundle；
5. 创建 DMG 并提交 Apple notarization。

不要以 `codesign --deep` 代替明确的嵌套代码签名。发布前还要在 Apple Developer portal 创建 `group.org.awaitcue.shared`，为 containing app 和 Safari extension 配置匹配的 Developer ID provisioning。

GitHub Release workflow 还需要以下 secrets：

- `APPLE_DEVELOPER_ID_P12_BASE64`、`APPLE_DEVELOPER_ID_P12_PASSWORD`、`APPLE_DEVELOPER_IDENTITY`；
- `APPLE_APP_PROVISIONING_PROFILE_BASE64`，对应 `org.awaitcue.AwaitCue`；
- `APPLE_SAFARI_EXTENSION_PROVISIONING_PROFILE_BASE64`，对应 `org.awaitcue.AwaitCue.SafariExtension`；
- `APPLE_NOTARY_KEY_BASE64`、`APPLE_NOTARY_KEY_ID`、`APPLE_NOTARY_ISSUER_ID`；
- `APPLE_KEYCHAIN_PASSWORD`。

`package-release.sh` 会解码并验证两份 profile 的 bundle identifier 与 `group.org.awaitcue.shared`，嵌入 bundle 后再逐层签名；缺少或不匹配时发布直接失败，不能生成看似签名成功、运行时却无法访问 App Group 的 DMG。
