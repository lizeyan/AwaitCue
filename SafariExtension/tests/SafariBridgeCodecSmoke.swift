import Foundation

@main
struct SafariBridgeCodecSmoke {
    static func main() async throws {
        let input = Data(#"""
        {
            "type":"evidenceChanged",
            "extensionInstallationID":"installation-1",
            "evidence":{
                "hookID":"hook-1",
                "text":"deployment completed",
                "aria":["status success"],
                "stateClasses":["status-success"],
                "fingerprint":"dom-fingerprint"
            }
        }
        """#.utf8)
        let output = try SafariBridgeMessageCodec.makeRelayPayload(
            messageData: input,
            profileIdentifier: "profile-1"
        )
        let object = try require(
            JSONSerialization.jsonObject(with: output) as? [String: Any]
        )
        precondition(object["browserBundleIdentifier"] as? String == "com.apple.Safari")
        precondition(object["safariProfileIdentifier"] as? String == "profile-1")

        let forbidden = Data(#"{"type":"evidenceChanged","imageDataURL":"data:image/png;base64,AA=="}"#.utf8)
        do {
            _ = try SafariBridgeMessageCodec.makeRelayPayload(
                messageData: forbidden,
                profileIdentifier: nil
            )
            preconditionFailure("Safari bridge must reject image payloads")
        } catch SafariBridgeMessageError.imagePayloadForbidden {
            // 预期行为：浏览器 Target 永远不能退回截图证据。
        }

        let sender = SmokeRelaySender()
        let bridge = SafariNativeMessageBridge(sender: sender)
        let reply = await bridge.handle(
            messageData: input,
            profileIdentifier: "profile-1"
        )
        precondition(reply == .accepted)
        let forwardedCount = await sender.count
        precondition(forwardedCount == 1)
    }

    private static func require<T>(_ value: T?) throws -> T {
        guard let value else { throw SmokeError.missingValue }
        return value
    }
}

private actor SmokeRelaySender: SafariRelayPayloadSending {
    private(set) var count = 0

    func send(_ payload: Data) async throws {
        precondition(!payload.isEmpty)
        count += 1
    }
}

private enum SmokeError: Error {
    case missingValue
}
