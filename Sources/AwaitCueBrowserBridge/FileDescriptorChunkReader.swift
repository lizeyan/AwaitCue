import Darwin
import Foundation

/// 从一个已经打开的文件描述符读取任意当前可用字节，供 Native Messaging 流式解码。
public struct FileDescriptorChunkReader: Sendable {
    private let fileDescriptor: Int32

    public init(fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
    }

    /// 最多读取 maximumCount 字节；对端关闭时返回 nil。
    public func readChunk(maximumCount: Int) throws -> Data? {
        precondition(maximumCount > 0)
        var buffer = [UInt8](repeating: 0, count: maximumCount)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(fileDescriptor, bytes.baseAddress, bytes.count)
            }
            if count > 0 {
                return Data(buffer.prefix(count))
            }
            if count == 0 {
                return nil
            }
            // 信号中断不代表 pipe 已损坏；直接重试可避免 Chrome 的短消息被误报成 host 失败。
            if errno == EINTR {
                continue
            }
            // NSError 可以原样保留未来系统可能新增的 errno，不需要把未知值改写成另一个错误。
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }
}

/// 把一条 Native Messaging frame 完整写入已经打开的文件描述符，不经过 Foundation 缓冲层。
public struct FileDescriptorChunkWriter: Sendable {
    private let fileDescriptor: Int32

    public init(fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
    }

    /// POSIX write 允许短写；循环到全部字节抵达，避免 Chrome 收到半条 JSON frame 后长期等待。
    public func write(_ data: Data) throws {
        guard !data.isEmpty else { return }
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(
                    fileDescriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if written > 0 {
                    offset += written
                    continue
                }
                if written < 0, errno == EINTR {
                    continue
                }
                let code = written == 0 ? EIO : errno
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
            }
        }
    }
}
