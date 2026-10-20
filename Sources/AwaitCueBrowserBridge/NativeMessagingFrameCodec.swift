import Foundation

/// Chromium Native Messaging 帧不满足协议约束。
public enum NativeMessagingFrameError: Error, Equatable {
    case messageTooLarge(Int)
}

/// 编码 Chromium Native Messaging 使用的四字节 little-endian 长度帧。
public enum NativeMessagingFrameCodec {
    public static let maximumMessageSize = 1_048_576

    /// 将 Codable 消息编码为一帧完整的 Native Messaging 数据。
    public static func encode<T: Encodable>(
        _ message: T,
        using encoder: JSONEncoder = JSONEncoder()
    ) throws -> Data {
        try encodePayload(encoder.encode(message))
    }

    /// 为已经编码的 JSON payload 添加长度前缀。
    public static func encodePayload(_ payload: Data) throws -> Data {
        guard payload.count <= maximumMessageSize else {
            throw NativeMessagingFrameError.messageTooLarge(payload.count)
        }
        var length = UInt32(payload.count).littleEndian
        var result = withUnsafeBytes(of: &length) { Data($0) }
        result.append(payload)
        return result
    }
}

/// 支持标准输入任意分片方式的增量 Native Messaging 解码器。
public struct NativeMessagingFrameDecoder: Sendable {
    private var buffer = Data()

    public init() {}

    /// 追加一段字节并返回当前已经完整到达的 JSON payload。
    public mutating func append<D: DataProtocol>(_ data: D) throws -> [Data] {
        buffer.append(contentsOf: data)
        var messages: [Data] = []

        while buffer.count >= 4 {
            let length = Int(
                UInt32(buffer[buffer.startIndex])
                    | UInt32(buffer[buffer.startIndex + 1]) << 8
                    | UInt32(buffer[buffer.startIndex + 2]) << 16
                    | UInt32(buffer[buffer.startIndex + 3]) << 24
            )
            guard length <= NativeMessagingFrameCodec.maximumMessageSize else {
                throw NativeMessagingFrameError.messageTooLarge(length)
            }
            guard buffer.count >= 4 + length else { break }

            let payloadStart = buffer.index(buffer.startIndex, offsetBy: 4)
            let payloadEnd = buffer.index(payloadStart, offsetBy: length)
            messages.append(buffer.subdata(in: payloadStart..<payloadEnd))

            // Native Messaging 单帧上限为 1 MiB，直接移除前缀能保持实现简单且内存有明确上界。
            buffer.removeSubrange(buffer.startIndex..<payloadEnd)
        }

        return messages
    }
}
