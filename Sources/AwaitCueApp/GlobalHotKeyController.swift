import Carbon.HIToolbox
import Foundation

/// 使用 Carbon 注册不依赖 Accessibility 权限的系统级快捷键。
@MainActor
final class GlobalHotKeyController {
    private var eventHandler: EventHandlerRef?
    private var hotKey: EventHotKeyRef?
    private let action: @MainActor () -> Void

    /// 默认注册 Command-Shift-Space；系统只把按下事件交给 AwaitCue，不记录其他键盘输入。
    init(action: @escaping @MainActor () -> Void) throws {
        self.action = action
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: OSType(kEventHotKeyPressed)
        )
        let userData = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return OSStatus(eventNotHandledErr) }
                let controller = Unmanaged<GlobalHotKeyController>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
                Task { @MainActor in controller.action() }
                return noErr
            },
            1,
            &eventType,
            userData,
            &eventHandler
        )
        guard installStatus == noErr else {
            throw GlobalHotKeyError.installFailed(installStatus)
        }

        let identifier = EventHotKeyID(signature: Self.signature, id: 1)
        let registerStatus = RegisterEventHotKey(
            UInt32(kVK_Space),
            UInt32(cmdKey | shiftKey),
            identifier,
            GetApplicationEventTarget(),
            0,
            &hotKey
        )
        guard registerStatus == noErr else {
            if let eventHandler { RemoveEventHandler(eventHandler) }
            throw GlobalHotKeyError.registrationFailed(registerStatus)
        }
    }

    /// 显式注销系统资源；Swift 6 的 deinit 不能安全访问这些非 Sendable Carbon 指针。
    func stop() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
        hotKey = nil
        eventHandler = nil
    }

    private static let signature: OSType = {
        Array("AWCQ".utf8).reduce(0) { ($0 << 8) | OSType($1) }
    }()
}

enum GlobalHotKeyError: Error {
    case installFailed(OSStatus)
    case registrationFailed(OSStatus)
}
