import Foundation
import Testing
@testable import AwaitCueBrowserBridge

@Suite("Native Messaging 帧协议")
struct NativeMessagingFrameCodecTests {
    @Test("编码使用四字节 little-endian 长度前缀")
    func encodesLittleEndianLengthPrefix() throws {
        let message = TestMessage(type: "ping", value: 7)

        let frame = try NativeMessagingFrameCodec.encode(message)
        let payload = frame.dropFirst(4)

        #expect(Array(frame.prefix(4)) == [25, 0, 0, 0])
        #expect(try JSONDecoder().decode(TestMessage.self, from: payload) == message)
    }

    @Test("解码器等待完整帧后才返回消息")
    func decoderHandlesPartialFrames() throws {
        let frame = try NativeMessagingFrameCodec.encode(TestMessage(type: "ready", value: 1))
        var decoder = NativeMessagingFrameDecoder()

        #expect(try decoder.append(frame.prefix(3)).isEmpty)
        #expect(try decoder.append(frame.dropFirst(3).prefix(5)).isEmpty)
        let messages = try decoder.append(frame.dropFirst(8))

        #expect(messages.count == 1)
        #expect(try JSONDecoder().decode(TestMessage.self, from: messages[0]) == TestMessage(type: "ready", value: 1))
    }

    @Test("一次输入可以解码多个连续帧")
    func decoderHandlesMultipleFrames() throws {
        let first = try NativeMessagingFrameCodec.encode(TestMessage(type: "one", value: 1))
        let second = try NativeMessagingFrameCodec.encode(TestMessage(type: "two", value: 2))
        var decoder = NativeMessagingFrameDecoder()

        let messages = try decoder.append(first + second)

        #expect(messages.count == 2)
        #expect(try JSONDecoder().decode(TestMessage.self, from: messages[1]).type == "two")
    }

    @Test("拒绝超过 Chromium Native Messaging 上限的消息")
    func rejectsOversizedMessages() throws {
        let payload = Data(repeating: 0, count: NativeMessagingFrameCodec.maximumMessageSize + 1)
        #expect(throws: NativeMessagingFrameError.messageTooLarge(payload.count)) {
            try NativeMessagingFrameCodec.encodePayload(payload)
        }

        var length = UInt32(NativeMessagingFrameCodec.maximumMessageSize + 1).littleEndian
        let prefix = withUnsafeBytes(of: &length) { Data($0) }
        var decoder = NativeMessagingFrameDecoder()
        #expect(throws: NativeMessagingFrameError.messageTooLarge(Int(length))) {
            try decoder.append(prefix)
        }
    }
}

private struct TestMessage: Codable, Equatable {
    let type: String
    let value: Int
}
