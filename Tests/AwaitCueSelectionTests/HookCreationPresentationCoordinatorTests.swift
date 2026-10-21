import AwaitCueCore
import Testing
@testable import AwaitCueSelection

@MainActor
@Suite("Hook 创建窗口编排")
struct HookCreationPresentationCoordinatorTests {
    @Test("框选成功后先保存目标再展示表单")
    func selectionCompletionStoresThenPresents() {
        let presenter = PresenterSpy()
        let coordinator = HookCreationPresentationCoordinator()
        coordinator.attach(presenter)
        var storedTarget: HookTarget?

        coordinator.selectionCompleted(fixtureTarget) { target in
            storedTarget = target
            presenter.events.append("store")
        }

        #expect(storedTarget == fixtureTarget)
        #expect(presenter.events == ["store", "present"])
    }

    @Test("已有未完成创建时只把原窗口带到前台")
    func existingCreationIsPresentedAgain() {
        let presenter = PresenterSpy()
        let coordinator = HookCreationPresentationCoordinator()
        coordinator.attach(presenter)

        coordinator.presentExisting()

        #expect(presenter.events == ["present"])
    }

    @Test("取消或创建成功时先清状态再关闭窗口")
    func finishClearsThenDismisses() {
        let presenter = PresenterSpy()
        let coordinator = HookCreationPresentationCoordinator()
        coordinator.attach(presenter)

        coordinator.finish {
            presenter.events.append("clear")
        }

        #expect(presenter.events == ["clear", "dismiss"])
    }

    private var fixtureTarget: HookTarget {
        .window(
            WindowTarget(
                applicationBundleIdentifier: "com.example.Editor",
                windowIdentifier: 7,
                initialTitle: "Build",
                normalizedRegion: NormalizedRegion(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
            )
        )
    }
}

@MainActor
private final class PresenterSpy: HookCreationPresenting {
    var events: [String] = []

    func present() {
        events.append("present")
    }

    func dismiss() {
        events.append("dismiss")
    }
}
