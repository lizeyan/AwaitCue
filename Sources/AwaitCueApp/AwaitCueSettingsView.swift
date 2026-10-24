import AwaitCueCore
import SwiftUI

struct AwaitCueSettingsView: View {
    private enum SettingsSection: String, CaseIterable, Identifiable {
        case model
        case browser
        case privacy

        var id: Self { self }

        var title: String {
            switch self {
            case .model: "模型"
            case .browser: "浏览器"
            case .privacy: "隐私"
            }
        }

        var subtitle: String {
            switch self {
            case .model: "连接 OpenAI Responses API 兼容的图片模型。"
            case .browser: "安装并检查 Chrome、Edge、Arc 或 Chromium 扩展。"
            case .privacy: "管理本地截图权限、浏览器连接和排除规则。"
            }
        }

        var systemImage: String {
            switch self {
            case .model: "brain"
            case .browser: "puzzlepiece.extension"
            case .privacy: "hand.raised"
            }
        }
    }

    @ObservedObject var model: AwaitCueApplicationModel
    @State private var showDeleteConfirmation = false
    @State private var selectedSection: SettingsSection = .model

    var body: some View {
        HStack(spacing: 0) {
            List(SettingsSection.allCases, selection: $selectedSection) { section in
                Label(section.title, systemImage: section.systemImage)
                    .tag(section)
            }
            .listStyle(.sidebar)
            .frame(width: 170)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text(selectedSection.title)
                    .font(.title2.weight(.semibold))
                Text(selectedSection.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Divider()
                    .padding(.top, 10)

                switch selectedSection {
                case .model:
                    modelSettings
                case .browser:
                    browserSettings
                case .privacy:
                    privacySettings
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 720, minHeight: 520)
    }

    private var browserSettings: some View {
        Form {
            Section("连接状态") {
                LabeledContent("Native relay") {
                    Text(model.browserBridgeStatus)
                }
            }

            Section {
                Button("下载最新扩展包…") {
                    model.openBrowserExtensionDownload()
                }
                ForEach(BrowserExtensionFamily.allCases, id: \.self) { family in
                    LabeledContent(family.displayName) {
                        if model.isBrowserInstalled(family) {
                            Button("打开扩展管理") {
                                model.openBrowserExtensionManagement(family)
                            }
                        } else {
                            Text("未安装")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("安装与管理")
            } footer: {
                Text("Chrome Web Store 版本发布前，请从 GitHub Release 下载扩展包，并在目标浏览器的扩展管理页启用开发者模式后加载。Chrome、Edge、Arc 和 Chromium 使用同一扩展构建。")
            }

            if let error = model.setupActionError {
                Section("操作失败") {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var modelSettings: some View {
        Form {
            Section {
                TextField("Base URL", text: $model.modelBaseURL)
                    .font(.system(.body, design: .monospaced))
                    .accessibilityHint("可填写服务 Base URL，也可填写完整的 /responses 地址。")
                    .onChange(of: model.modelBaseURL) { _, _ in
                        model.confirmedAPIHostname = false
                    }
                SecureField("API Key", text: $model.apiKey)
                TextField("模型", text: $model.modelName)
            } header: {
                Text("模型服务")
            } footer: {
                Text("可填写服务 Base URL，也可直接填写完整的 /responses 地址。")
            }

            Section("数据发送确认") {
                if let host = model.apiHostname {
                    Toggle(isOn: $model.confirmedAPIHostname) {
                        Text("我确认截图和页面信息将发送到 **\(host)**，其数据保留规则由该服务提供方决定。")
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text("请输入包含协议和 hostname 的有效 Base URL。")
                        .foregroundStyle(.red)
                }
            }

            Section("连接状态") {
                connectionStatus
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section {
                HStack {
                    Button("删除配置", role: .destructive) {
                        Task { await model.deleteModelConfiguration() }
                    }
                    Spacer()
                    Button("测试并保存") {
                        Task { await model.testAndSaveModelConfiguration() }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.modelStatus == .testing)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var privacySettings: some View {
        Form {
            LabeledContent("截图与 DOM") {
                Text("仅内存处理，不落盘")
            }
            LabeledContent("屏幕录制权限") {
                HStack {
                    if model.screenCapturePermissionGranted {
                        Label("已允许", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Button("请求权限") {
                            model.requestScreenCapturePermission()
                        }
                    }
                    Button("打开系统设置") {
                        model.openSystemSettings(.screenRecording)
                    }
                }
            }
            LabeledContent("通知权限") {
                Button("打开系统设置") {
                    model.openSystemSettings(.notifications)
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
                .font(.system(.body, design: .monospaced))
                .lineLimit(2 ... 5)
                TextField(
                    "Chromium host，每行一个",
                    text: $model.excludedBrowserHostsText,
                    axis: .vertical
                )
                .font(.system(.body, design: .monospaced))
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
            if let error = model.setupActionError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
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
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
