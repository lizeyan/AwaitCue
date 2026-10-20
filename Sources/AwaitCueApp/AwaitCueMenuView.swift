import AwaitCueCore
import SwiftUI

struct AwaitCueMenuView: View {
    @ObservedObject var model: AwaitCueApplicationModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            if let error = model.startupError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .font(.caption)
            }
            hookList
            Divider()
            footer
        }
        .padding(14)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("AwaitCue")
                    .font(.headline)
                Text("When it’s ready—and you are too.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(model.hooks.count)")
                .monospacedDigit()
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.quaternary, in: Capsule())
        }
    }

    @ViewBuilder
    private var hookList: some View {
        if model.hooks.isEmpty {
            ContentUnavailableView(
                "当前没有 Hook",
                systemImage: "circle.dotted",
                description: Text("全局框选与浏览器连接完成后，正在观察的 Hook 会显示在这里。")
            )
            .frame(minHeight: 150)
        } else {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(model.hooks, id: \.id) { hook in
                        hookRow(hook)
                    }
                }
            }
            .frame(maxHeight: 360)
        }
    }

    private func hookRow(_ hook: Hook) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(hook.title)
                    .font(.body.weight(.medium))
                Spacer()
                Text(stateLabel(hook.state))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let reason = hook.blockReason {
                Label(blockLabel(reason), systemImage: "pause.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            HStack {
                if hook.state == .notified {
                    Button("稍后提醒") { Task { await model.snooze(hook) } }
                    Button("完成") { Task { await model.complete(hook) } }
                }
                Spacer()
                Button("取消", role: .destructive) { Task { await model.cancel(hook) } }
                    .buttonStyle(.borderless)
            }
            .font(.caption)
        }
        .padding(10)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
    }

    private var footer: some View {
        HStack {
            Button("新建 Hook…") {}
                .disabled(true)
                .help("全局矩形框选将在 ScreenCaptureKit smoke test 通过后启用。")
            Spacer()
            Button("设置…") { model.openSettings() }
            Button("退出") { model.quit() }
        }
    }

    private func stateLabel(_ state: HookState) -> String {
        switch state {
        case .draft: "草稿"
        case .observing: "观察中"
        case .waitingMinimum: "等待最短时间"
        case .waitingInterruptible: "等待合适时机"
        case .notified: "已通知"
        case .targetUnavailable: "目标不可用"
        case .completed: "已完成"
        case .cancelled: "已取消"
        }
    }

    private func blockLabel(_ reason: HookBlockReason) -> String {
        switch reason {
        case .modelUnavailable: "模型不可用"
        case .targetMinimized: "目标窗口已最小化"
        case .browserExtensionDisconnected: "浏览器扩展未连接"
        case .capturePermissionMissing: "缺少屏幕录制权限"
        case .notificationPermissionMissing: "缺少通知权限"
        }
    }
}
