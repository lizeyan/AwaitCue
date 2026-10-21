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
