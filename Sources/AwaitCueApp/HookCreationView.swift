import AwaitCueCore
import SwiftUI

struct HookCreationView: View {
    static let expandedSelectionWarning = "浏览器侧栏使页面读取范围横向扩大，可能包含原框选区域左右相邻的页面内容。请确认模型理解只对应目标状态；内容冲突时应显示“当前无法确定”。"

    private enum HookKind: String, CaseIterable, Identifiable {
        case condition = "条件满足时"
        case delay = "至少等待一段时间"

        var id: Self { self }
    }

    @ObservedObject var model: AwaitCueApplicationModel
    @State private var kind: HookKind = .condition
    @State private var title = ""
    @State private var conditionText = ""
    @State private var minimumDelay: TimeInterval = 300
    @State private var isCreating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("创建 Hook")
                .font(.title2.weight(.semibold))
            targetSummary

            Picker("类型", selection: $kind) {
                ForEach(HookKind.allCases) { kind in
                    Text(kind.rawValue)
                        .tag(kind)
                        .accessibilityIdentifier(
                            kind == .condition
                                ? "awaitcue.hook.kind.condition"
                                : "awaitcue.hook.kind.delay"
                        )
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("awaitcue.hook.kind")

            TextField("通知标题", text: $title)
                .accessibilityIdentifier("awaitcue.hook.title")
            if kind == .condition {
                TextField("例如：编译成功或失败时", text: $conditionText, axis: .vertical)
                    .lineLimit(3 ... 6)
                    .accessibilityIdentifier("awaitcue.hook.condition")
                if showsExpandedSelectionWarning {
                    Label(Self.expandedSelectionWarning, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("awaitcue.hook.expanded-selection-warning")
                }
                if model.modelStatus != .connected {
                    Label("条件 Hook 需要先在设置中测试并保存支持图片输入的决策模型。", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                conditionAnalysisStatus
                conditionPreview
            } else {
                Picker("最短等待", selection: $minimumDelay) {
                    Text("5 分钟").tag(TimeInterval(300))
                    Text("15 分钟").tag(TimeInterval(900))
                    Text("30 分钟").tag(TimeInterval(1_800))
                    Text("1 小时").tag(TimeInterval(3_600))
                }
                .accessibilityIdentifier("awaitcue.hook.minimum-wait")
            }

            HStack {
                Button("取消", role: .cancel) { model.dismissPendingTarget() }
                    .accessibilityIdentifier("awaitcue.hook.cancel")
                Spacer()
                if isCreating || model.isPreparingCondition { ProgressView() }
                if kind == .condition, model.conditionPreview == nil {
                    Button("分析当前状态") {
                        Task { await model.prepareCondition(conditionText) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canAnalyze || model.isPreparingCondition)
                    .accessibilityIdentifier("awaitcue.hook.analyze")
                } else {
                    Button(kind == .condition ? "确认并创建" : "创建") {
                        Task { await create() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canCreate || isCreating)
                    .accessibilityIdentifier("awaitcue.hook.create")
                }
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear {
            if title.isEmpty { title = defaultTitle }
        }
        .onChange(of: conditionText) { _, _ in
            model.clearConditionPreview()
        }
    }

    private var targetSummary: some View {
        GroupBox("目标") {
            HStack {
                Image(systemName: targetIcon)
                Text(defaultTitle)
                    .accessibilityIdentifier("awaitcue.hook.target-title")
                Spacer()
            }
            .padding(.vertical, 4)
        }
        .accessibilityIdentifier("awaitcue.hook.target-summary")
    }

    private var canCreate: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (kind == .delay
                || (!conditionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && model.modelStatus == .connected
                    && model.conditionPreview != nil))
    }

    private var canAnalyze: Bool {
        !conditionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && model.modelStatus == .connected
    }

    private var defaultTitle: String {
        guard let target = model.pendingTarget else { return "选中的目标" }
        switch target {
        case let .window(window):
            return window.initialTitle.isEmpty ? window.applicationBundleIdentifier : window.initialTitle
        case let .browser(browser):
            return browser.initialTitle.isEmpty ? browser.host : browser.initialTitle
        }
    }

    private var targetIcon: String {
        if case .browser = model.pendingTarget { return "globe" }
        return "macwindow"
    }

    var showsExpandedSelectionWarning: Bool {
        guard case let .browser(browser) = model.pendingTarget else { return false }
        return browser.selectionRegionExpanded
    }

    @MainActor
    private func create() async {
        isCreating = true
        defer { isCreating = false }
        switch kind {
        case .condition:
            guard let prepared = model.conditionPreview else { return }
            _ = await model.createConditionHook(
                title: title,
                conditionText: conditionText,
                prepared: prepared
            )
        case .delay:
            _ = await model.createDelayHook(title: title, minimumDelay: minimumDelay)
        }
    }

    @ViewBuilder
    private var conditionAnalysisStatus: some View {
        if model.isPreparingCondition {
            Label(preparingConditionLabel, systemImage: "sparkles")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if let error = model.conditionPreparationError {
            Label("分析失败：\(error)", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var preparingConditionLabel: String {
        if case .browser = model.pendingTarget {
            return "正在分析框选页面内容…"
        }
        return "正在分析框选截图…"
    }

    @ViewBuilder
    private var conditionPreview: some View {
        if let preview = model.conditionPreview {
            GroupBox("分析结果") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("满足以下提醒条件时通知：")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(preview.confirmedSummary)
                        .accessibilityIdentifier("awaitcue.hook.condition-summary")
                    Divider()
                    Text("当前判断")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Label(decisionLabel(preview.currentDecision), systemImage: decisionIcon(preview.currentDecision))
                            .accessibilityIdentifier("awaitcue.hook.current-decision")
                        Spacer()
                        Text("判断置信度 \(Int(preview.confidence * 100))%")
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("awaitcue.hook.decision-confidence")
                    }
                    .font(.caption)
                    if preview.currentDecision == .matched {
                        Text("当前已经满足。创建后仍会执行第二次稳定确认，不会立即通知。")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .accessibilityIdentifier("awaitcue.hook.decision-explanation")
                    } else if preview.currentDecision == .notMatched {
                        Text("当前证据明确显示提醒条件尚未满足；创建后会继续观察。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("awaitcue.hook.decision-explanation")
                    } else if preview.currentDecision == .uncertain {
                        Text("当前证据不足或相互冲突；这不表示提醒条件已经满足。可以调整条件，或重新框选更明确的区域。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("awaitcue.hook.decision-explanation")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }
        }
    }

    private func decisionLabel(_ decision: ConditionDecision) -> String {
        switch decision {
        case .matched: "当前已满足"
        case .notMatched: "当前未满足"
        case .uncertain: "当前无法确定"
        }
    }

    private func decisionIcon(_ decision: ConditionDecision) -> String {
        switch decision {
        case .matched: "checkmark.circle"
        case .notMatched: "clock"
        case .uncertain: "questionmark.circle"
        }
    }
}
