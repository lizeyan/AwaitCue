import AwaitCueCore

/// 创建 Hook 表单的可替换展示边界，避免框选状态依赖具体 AppKit 窗口。
@MainActor
public protocol HookCreationPresenting: AnyObject {
    func present()
    func dismiss()
    func presentFailure(message: String)
}

/// 保证 pending target 与创建窗口按固定顺序一起变化。
@MainActor
public final class HookCreationPresentationCoordinator {
    private weak var presenter: (any HookCreationPresenting)?

    public init() {}

    public func attach(_ presenter: any HookCreationPresenting) {
        self.presenter = presenter
    }

    /// 先保存目标，确保窗口出现时表单能立即读取完整内容。
    public func selectionCompleted(
        _ target: HookTarget,
        storeTarget: (HookTarget) -> Void
    ) {
        storeTarget(target)
        presenter?.present()
    }

    /// 已经存在未完成创建时，不允许新框选覆盖它。
    public func presentExisting() {
        presenter?.present()
    }

    /// Target 无法可靠建立时立即展示原因，不能要求用户事后打开菜单寻找错误。
    public func selectionFailed(message: String) {
        presenter?.presentFailure(message: message)
    }

    /// 先清理业务状态，再关闭承载表单的窗口。
    public func finish(clearTarget: () -> Void) {
        clearTarget()
        presenter?.dismiss()
    }
}
