import AwaitCueCore
import SwiftUI

struct AwaitCueSettingsView: View {
    @ObservedObject var model: AwaitCueApplicationModel
    @State private var showDeleteConfirmation = false

    var body: some View {
        TabView {
            modelSettings
                .tabItem { Label("模型", systemImage: "brain") }
            privacySettings
                .tabItem { Label("隐私", systemImage: "hand.raised") }
        }
        .padding(20)
    }

    private var modelSettings: some View {
        Form {
            TextField("Base URL", text: $model.modelBaseURL)
                .onChange(of: model.modelBaseURL) { _, _ in
                    model.confirmedAPIHostname = false
                }
            SecureField("API key", text: $model.apiKey)
            TextField("模型", text: $model.modelName)

            if let host = model.apiHostname {
                Toggle(isOn: $model.confirmedAPIHostname) {
                    Text("我确认截图和页面信息将发送到 **\(host)**，其数据保留规则由该服务提供方决定。")
                }
            } else {
                Text("请输入包含协议和 hostname 的有效 Base URL。")
                    .foregroundStyle(.red)
            }

            HStack {
                Button("测试并保存") {
                    Task { await model.testAndSaveModelConfiguration() }
                }
                .disabled(model.modelStatus == .testing)
                Button("删除配置", role: .destructive) {
                    Task { await model.deleteModelConfiguration() }
                }
                Spacer()
                connectionStatus
            }
        }
    }

    private var privacySettings: some View {
        Form {
            LabeledContent("截图与 DOM") {
                Text("仅内存处理，不落盘")
            }
            LabeledContent("屏幕录制权限") {
                if model.screenCapturePermissionGranted {
                    Label("已允许", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Button("请求权限") {
                        model.requestScreenCapturePermission()
                    }
                }
            }
            LabeledContent("遥测与崩溃上报") {
                Text("关闭")
            }
            LabeledContent("菜单栏应用退出后") {
                Text("停止全部观察与浏览器捕获")
            }
            LabeledContent("浏览器 relay") {
                Text(model.browserBridgeStatus)
            }
            Picker(
                "全局框选快捷键",
                selection: Binding(
                    get: { model.globalShortcutPreset },
                    set: { model.updateGlobalShortcut($0) }
                )
            ) {
                ForEach(GlobalShortcutPreset.allCases, id: \.self) { preset in
                    Text(preset.displayName).tag(preset)
                }
            }
            if let shortcutError = model.globalShortcutError {
                Label(shortcutError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Section("当前活动隐私排除") {
                TextField(
                    "应用 bundle ID，每行一个",
                    text: $model.excludedApplicationBundleIdentifiersText,
                    axis: .vertical
                )
                .lineLimit(2 ... 5)
                TextField(
                    "Chromium host，每行一个",
                    text: $model.excludedBrowserHostsText,
                    axis: .vertical
                )
                .lineLimit(2 ... 5)
                Text("命中规则时会在本地判定为不适合打断，不生成当前活动截图，也不请求模型。Chromium host 规则同时覆盖其子域；无法可信解析当前 host 时同样不会截图。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Divider()
            Button("删除所有本地数据…", role: .destructive) {
                showDeleteConfirmation = true
            }
            .confirmationDialog(
                "删除所有 AwaitCue 本地数据？",
                isPresented: $showDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("永久删除", role: .destructive) {
                    Task { await model.deleteAllLocalData() }
                }
            } message: {
                Text("这会删除所有 Hook、模型 API key 和待发送通知，无法撤销。")
            }
        }
    }

    @ViewBuilder
    private var connectionStatus: some View {
        switch model.modelStatus {
        case .notConfigured:
            Label("未配置", systemImage: "circle")
                .foregroundStyle(.secondary)
        case .testing:
            ProgressView("正在测试")
        case .connected:
            Label("已连接", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case let .failed(message):
            Label(message, systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
                .lineLimit(2)
        }
    }
}
