# AwaitCue Safari Web Extension prototype

这个目录是 macOS Safari 的 DOM-only 原型资源。它不是第二个产品 App；正式集成时，现有 `AwaitCue.app` 必须作为 containing app，并嵌入一个 Safari Web Extension target。

## 已固定的行为

- Safari Target 只发送 DOM 文本、ARIA、状态 class、URL、标题、坐标和 fingerprint。
- `image`、`imageDataURL`、`screenshot`、`pixels` 在 JavaScript 和 Swift native bridge 两层都会被拒绝。
- `ready → ping → pong`、request ID、installation ID 与 Chromium 保持相同语义。
- 标签页关闭或离开原 URL 后发送 `targetUnavailable`，不会自动绑定其他标签页。
- 纯 Canvas、纯图片或没有可读语义的区域返回空页面内容，由模型决定为 `uncertain`；没有截图兜底。

## 目录

- `Resources/`：Safari Web Extension manifest、background、content 与 DOM-only 协议。
- `NativeHandler/`：`NSExtensionRequestHandling` 入口、App Group entitlement 和 relay adapter。
- `tests/`：Node 行为测试。
- `tests/SafariBridgeCodecSmoke.swift`：在 root `Package.swift` 接入新 target 前可独立编译的 Swift smoke。

共享 Swift interface 位于：

- `Sources/AwaitCueSafariBridge/`
- `Tests/AwaitCueSafariBridgeTests/`

## 本地验证

```bash
cd SafariExtension
npm test
node --check Resources/background.js
node --check Resources/content.js

cd ..
swiftc -parse-as-library \
  Sources/AwaitCueSafariBridge/SafariBridgeMessageCodec.swift \
  Sources/AwaitCueSafariBridge/SafariNativeMessageBridge.swift \
  SafariExtension/tests/SafariBridgeCodecSmoke.swift \
  -o /tmp/awaitcue-safari-bridge-smoke
/tmp/awaitcue-safari-bridge-smoke
```

对 native handler 做 typecheck：

```bash
bin_path="$(swift build --show-bin-path)"
module_dir="$(mktemp -d "${TMPDIR:-/tmp}/awaitcue-safari-modules.XXXXXX")"
swiftc -parse-as-library -emit-module \
  -module-name AwaitCueSafariBridge \
  Sources/AwaitCueSafariBridge/*.swift \
  -framework SafariServices \
  -emit-module-path "${module_dir}/AwaitCueSafariBridge.swiftmodule"
swiftc -typecheck \
  -I "${bin_path}/Modules" \
  -I "${module_dir}" \
  -framework SafariServices \
  SafariExtension/NativeHandler/*.swift
```

## Xcode 集成点

正式工程需要完成以下接线，不能只把 `Resources` 复制进 App bundle：

1. 增加 `AwaitCueSafariBridge` Swift target，依赖 `AwaitCueBrowserBridge` 与 `SafariServices`。
2. 在 containing app 和 Safari native extension 上配置同一个 App Group：`group.org.awaitcue.shared`。
3. 主应用把 `native-bridge.json` 写入 App Group container；Safari native extension 从同一位置读取。
4. 增加 `org.awaitcue.AwaitCue.SafariExtension` app-extension target，principal class 使用 `SafariWebExtensionHandler`。
5. containing app 通过 `SafariExtensionCommandDispatcher` 向 JavaScript 发送命令。
6. 归档后验证 `.appex` 已嵌入 `AwaitCue.app/Contents/PlugIns/`，且主应用、extension 和 App Group entitlement 使用同一 Team provisioning。

当前本机已成功运行 `xcodebuild -runFirstLaunch`，但 Xcode 26.3 的 `safari-web-extension-packager` 仍返回：

```text
A required plugin failed to load. Please ensure system content is up-to-date — try running 'xcodebuild -runFirstLaunch'.
```

因此当前只提交可独立验证的代码骨架，不手写或伪造一个未经 Xcode 验证的 `.xcodeproj`。恢复 packager 后，应先用它生成临时工程核对 target、Info.plist 和 manifest warning，再把验证过的设置迁入 AwaitCue containing app 工程。

## 未完成的真实验证

- Safari 全局框选坐标到 viewport region 的换算目前是原型估算，必须在普通窗口、全屏、隐藏工具栏和不同缩放下做真实 E2E 校准。
- Safari 网站访问权限撤销后的具体错误映射。
- Developer ID provisioning、App Group、签名、公证和干净用户安装。
- Safari 17 最低版本以及当前 Safari 的真实 tab 后台 DOM mutation。
