import Foundation
import Testing
@testable import AwaitCueApp

@Suite("本机 benchmark 解锁恢复")
struct UserSessionUnlockWaiterTests {
    @Test("即使系统解锁通知丢失也会通过轮询继续")
    func waitsUntilSessionActuallyUnlocks() async {
        let state = UnlockState(sequence: [false, false, true])
        let waiter = UserSessionUnlockWaiter(
            isUnlocked: { await state.next() },
            sleep: { await state.recordSleep() }
        )

        await waiter.waitUntilUnlocked()

        #expect(await state.checkCount == 3)
        #expect(await state.sleepCount == 2)
    }

    @Test("任务取消后停止轮询")
    func cancellationStopsWaiting() async {
        let state = UnlockState(sequence: [false, false, false])
        let task = Task {
            let waiter = UserSessionUnlockWaiter(
                isUnlocked: { await state.next() },
                sleep: {
                    await state.recordSleep()
                    throw CancellationError()
                }
            )
            await waiter.waitUntilUnlocked()
        }

        await task.value
        #expect(await state.checkCount == 1)
        #expect(await state.sleepCount == 1)
    }
}

private actor UnlockState {
    private var sequence: [Bool]
    private(set) var checkCount = 0
    private(set) var sleepCount = 0

    init(sequence: [Bool]) {
        self.sequence = sequence
    }

    func next() -> Bool {
        checkCount += 1
        return sequence.isEmpty ? false : sequence.removeFirst()
    }

    func recordSleep() {
        sleepCount += 1
    }
}
