# Safari Web Extension 可行性评估

## 结论

可以做，并且产品方向已经确定为：**Safari 与 Chromium 的 Browser Target 全部只读取页面内容，不使用截图。**

Safari 支持应承诺：

- 绑定具体 Safari 标签页；
- 读取选区附近的 DOM、文本、ARIA 和状态 class；
- 后台标签页在页面内容变化时继续产出 DOM 证据；
- 将 Target、Condition Hook 和 Delay Hook 接入现有 macOS 菜单栏应用；
- Canvas、纯图片或只靠颜色表达且没有可读语义的区域明确返回 `no_semantic_content`，Condition 保持 `uncertain`。

Browser Target 没有视觉兜底，也不会自动切换标签页或截取窗口来猜测状态。普通 macOS App Target 和 Appropriate to Interrupt 判断仍可使用只驻留内存的窗口截图；这两条证据路径必须保持分离。[Assessing your Safari web extension’s browser compatibility](https://developer.apple.com/documentation/safariservices/assessing-your-safari-web-extension-s-browser-compatibility)

## 为什么不是从零重写

Apple 提供 Safari Web Extension，并明确支持把现有 Chrome、Firefox 或 Edge WebExtension 打包为 Safari 扩展。当前工具会生成 Xcode project、macOS containing app 和 Safari web extension target；转换后仍可继续维护原始 WebExtension 资源。[Packaging a web extension for Safari](https://developer.apple.com/documentation/safariservices/packaging-a-web-extension-for-safari)

现有 `BrowserExtension/src` 约 1,300 行。按职责划分：

| 部分 | 复用判断 | 说明 |
| --- | --- | --- |
| `protocol.ts` | 高 | 消息 schema、结构化错误和 request ID 可共用，仅需增加 Safari transport 身份。 |
| `domEvidence.ts`、`region.ts` | 高 | DOM、ARIA、状态 class、选区坐标与证据限流基本不依赖浏览器。 |
| `content.ts` | 较高 | 内容脚本消息和 DOM 观察可复用，但要改为跨浏览器 API wrapper，并验证 Safari 的注入时机。 |
| `browserSelection.ts` | 中高 | tab/window 匹配算法可复用，坐标系需要在 Safari 实机回归。 |
| `background.ts` | 中低 | 业务流程可复用，但 native messaging、权限、生命周期和 API 差异需要拆出 Safari 实现。 |
| 浏览器像素捕获模块 | 已删除 | DOM-only 决策后不再存在任何浏览器截图或视频帧路径。 |
| `AwaitCueNativeHost` | 不直接复用 | Safari 的 native messaging 不是 Chrome 的外部 Native Messaging Host 模式。可复用消息协议与本地 relay 思路，但不能复用安装 manifest 和 stdio host 启动方式。 |

比较稳妥的代码组织是保留一份 DOM、选区、协议和证据生成代码，再为 Chromium 与 Safari 分别维护薄的 background/native transport。不要复制出两套会逐渐漂移的 Condition 判断逻辑。

## Safari 与 macOS 应用如何通信

Safari Web Extension 由三个隔离部分组成：containing macOS app、浏览器中的 JavaScript/WebExtension 资源、以及负责原生消息的 native app extension。Apple 建议通过 native messaging 传事件，通过 App Group 共享需要持久化的数据。[Messaging between the app and JavaScript in a Safari web extension](https://developer.apple.com/documentation/safariservices/messaging-between-the-app-and-javascript-in-a-safari-web-extension)

具体到 AwaitCue：

1. 现有 `AwaitCue.app` 应成为 containing app，不建议让用户额外安装第二个“Safari 助手”应用。
2. Safari background script 使用 `browser.runtime.sendNativeMessage` / `connectNative` 与 native app extension 通信。
3. native app extension 再把结构化事件转给正在运行的 AwaitCue 菜单栏进程；这一段可复用现有 loopback relay 的认证、限长和 request ID 设计，但 descriptor 应放入 App Group，而不是 Chrome 的 Native Messaging manifest。
4. AwaitCue 向 Safari 发命令时使用 Apple 提供的 containing app → JavaScript 消息路径，并继续执行 `ready → ping → pong` 双向确认。
5. 页面 content script 不能直接向 native app extension 发 native message；它应先把 DOM 证据发给 background script，再由 background 转发。这是 Apple 文档明确的边界。[Messaging between the app and JavaScript in a Safari web extension](https://developer.apple.com/documentation/safariservices/messaging-between-the-app-and-javascript-in-a-safari-web-extension)

App Group、native app extension sandbox、Developer ID provisioning 和主应用的现有非 App Store 签名方式仍需要真实签名验证。这是 Safari 方案中最大的 macOS 工程风险，不应把 unsigned/ad-hoc `.appex` 构建或 mock 当作完成。

## 权限和安装体验

Safari Web Extension 必须作为 app extension 被包含和签名。用户安装 app 后，仍需要在 Safari 设置中启用扩展并授予网站访问权限；普通应用不能替用户静默打开全部网站权限。Apple 的运行文档把 Safari Settings 中启用扩展列为必要步骤。[Running your Safari web extension](https://developer.apple.com/documentation/safariservices/running-your-safari-web-extension)

AwaitCue 可以做到：

- 设置页检测 Safari 是否安装；
- 显示 Safari 扩展是否启用（可用系统提供的 extension state API 时）；
- 一键打开 Safari 扩展设置；
- 按 host 展示“未授权 / 仅本次 / 已允许”状态和清晰引导；
- 在全局框选命中 Safari 但缺权限时，直接展示具体修复动作，而不是超时后报“浏览器没有响应”。

AwaitCue 不能做到：

- 静默替用户启用 Safari 扩展；
- 静默授予所有网站访问权限；
- 在 Safari 未允许页面访问时读取该页面的 DOM。

## 构建与分发

当前仓库以 Swift Package 和自定义 `build-app.sh` 生成应用；Safari app extension 需要 Xcode target。因此需要增加一个 Xcode project/workspace，继续把现有 Swift Package 模块作为依赖，而不是把业务代码搬回 Xcode project。

Apple 支持两种 macOS 分发方式：

- Mac App Store / App Store Connect；
- Developer ID 签名并公证后，在 Mac App Store 外直接下载。

后一种与 AwaitCue 已确认的“Developer ID 签名、公证、直接下载”路线一致。[Distributing your Safari web extension](https://developer.apple.com/documentation/safariservices/distributing-your-safari-web-extension)

发布前仍需要 Apple Developer Program、extension 与 containing app 的签名/provisioning、隐私说明和公证。Safari 的发布不依赖 Chrome Web Store，但若以后进入 Mac App Store，则是另一套 App Store Connect 审核流程。

本机已经完成 Xcode 26.3 首次初始化，`safari-web-extension-packager` 可成功生成 macOS 工程，DOM-only manifest 不再产生不兼容 key warning。当前 Xcode target 可以生成并嵌入 `AwaitCueSafariExtension.appex`；这证明构建结构成立，但不等于 Developer ID/App Group、Safari 启用、网站权限或实际选区坐标已经通过真实用户链路。

## 测试方案

Safari 组件应沿用当前“用户可见行为优先”的测试边界：

1. **共享 JavaScript 单元测试**：协议、DOM 证据、选区坐标、mutation 限流和证据大小；同一组 corpus 同时跑 Chromium 与 Safari adapter。
2. **native app extension 测试**：真实 `NSExtensionContext` 消息编码、App Group descriptor、认证、超时和多 profile/request 关联。
3. **macOS AppKit E2E**：设置页引导、Safari 状态、权限缺失错误、全局框选后创建窗口、关闭重开。
4. **真实 Safari E2E**：加载签名测试扩展，打开固定网页，框选区域，验证具体 tab/host/DOM 证据进入创建窗口；再覆盖标签页后台、关闭、替换和 host 权限撤销。
5. **证据不足测试**：Canvas、纯图片和无语义区域必须产生 `no_semantic_content` 并保持 `uncertain`，不得生成图片请求或伪装成 `notMatched`。
6. **分发 smoke**：对 Developer ID 签名、公证后的 app 做干净用户安装、Safari 启用和升级测试。

Safari 26 引入了 WebDriver 加载与卸载 WebExtension 的命令，可用于较新系统上的真实自动化；macOS 14 / Safari 17 的最低兼容验证仍需保留签名构建和实机 smoke。[WebKit Features in Safari 26.0](https://webkit.org/blog/17333/webkit-features-in-safari-26-0/)

## 推荐实施顺序与工作量

| 阶段 | 交付物 | 粗略工作量 |
| --- | --- | --- |
| 1. 兼容性原型 | packager、Safari target、native ping/pong、读取固定页 DOM | 已完成结构验证 |
| 2. DOM 型 Condition Hook | 精确 tab 绑定、选区 DOM、mutation、Target Unavailable、权限错误 | 3–5 天 |
| 3. 集成现有 macOS App | 同一 containing app、设置引导、App Group/relay、真实框选 | 3–5 天 |
| 4. DOM-only 回归 | `no_semantic_content`、后台 mutation、多 Profile、worker 冷启动 | 2–4 天 |
| 5. E2E 与发布 | Safari 自动化、Developer ID/App Group、签名、公证、升级和隐私材料 | 3–5 天 |

这些阶段有依赖关系，应按顺序做。真实验收必须覆盖 Safari worker 冷启动/休眠、网站权限撤销、多个 Profile、标签页关闭或导航、通知聚焦，以及 Developer ID 签名后的 App Group descriptor。结构构建通过不能替代这些验证。

## 推荐产品决定

Safari 与 Chromium 使用同一 Browser Target 证据契约：DOM、文本、ARIA、语义状态 class、表单/进度属性和相对坐标。证据足够时正常判断；页面没有可读语义时明确 `uncertain`。这不会改变 Hook、Target、Condition、Satisfied 或 Appropriate to Interrupt 的定义，也不会形成两个浏览器能力不同、难以解释的截图分支。
