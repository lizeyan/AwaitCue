import Darwin
import Foundation
import Testing
@testable import AwaitCueBrowserBridge

@Suite("文件描述符分片读取")
struct FileDescriptorChunkReaderTests {
    @Test("小消息无需等待写端关闭即可返回")
    func returnsAvailableBytesWithoutWaitingForEOF() throws {
        var descriptors = [Int32](repeating: -1, count: 2)
        #expect(pipe(&descriptors) == 0)
        let reader = FileDescriptorChunkReader(fileDescriptor: descriptors[0])
        let result = ReaderResultBox()
        let completed = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
            result.store(Result { try reader.readChunk(maximumCount: 65_536) })
            completed.signal()
        }

        let payload = Data(#"{"type":"ping"}"#.utf8)
        let written = payload.withUnsafeBytes { bytes in
            Darwin.write(descriptors[1], bytes.baseAddress, bytes.count)
        }
        #expect(written == payload.count)

        let completion = completed.wait(timeout: .now() + .seconds(1))
        if completion == .timedOut {
            // 保留写端本应不影响“已有少量数据立即返回”；超时后关闭它，只用于回收被旧实现阻塞的测试线程。
            Darwin.close(descriptors[1])
            _ = completed.wait(timeout: .now() + .seconds(2))
        } else {
            Darwin.close(descriptors[1])
        }
        Darwin.close(descriptors[0])

        #expect(completion == .success)
        #expect(try result.load()?.get() == payload)
    }

    @Test("写端关闭后返回 EOF")
    func returnsNilAfterWriterCloses() throws {
        var descriptors = [Int32](repeating: -1, count: 2)
        #expect(pipe(&descriptors) == 0)
        let reader = FileDescriptorChunkReader(fileDescriptor: descriptors[0])
        Darwin.close(descriptors[1])

        #expect(try reader.readChunk(maximumCount: 64) == nil)
        Darwin.close(descriptors[0])
    }

    @Test("无效文件描述符保留 POSIX 读取错误")
    func throwsForInvalidDescriptor() {
        // “关闭后数字 FD 不会立刻复用”不是 POSIX 保证；并行测试必须使用稳定无效的 -1。
        let reader = FileDescriptorChunkReader(fileDescriptor: -1)

        do {
            _ = try reader.readChunk(maximumCount: 64)
            Issue.record("关闭的文件描述符不应读取成功")
        } catch let error as NSError {
            #expect(error.domain == NSPOSIXErrorDomain)
            #expect(error.code == Int(EBADF))
        }
    }
}

@Suite("文件描述符完整写入")
struct FileDescriptorChunkWriterTests {
    @Test("短帧无需关闭描述符即可立即抵达读端")
    func writesCompleteFrameWithoutWaitingForClose() throws {
        var descriptors = [Int32](repeating: -1, count: 2)
        #expect(pipe(&descriptors) == 0)
        let writer = FileDescriptorChunkWriter(fileDescriptor: descriptors[1])
        let payload = Data(#"{"type":"resolveSelection"}"#.utf8)

        try writer.write(payload)

        var buffer = [UInt8](repeating: 0, count: 128)
        let count = Darwin.read(descriptors[0], &buffer, buffer.count)
        #expect(count == payload.count)
        #expect(Data(buffer.prefix(count)) == payload)
        Darwin.close(descriptors[0])
        Darwin.close(descriptors[1])
    }

    @Test("无效写端保留 POSIX 错误")
    func invalidDescriptorThrows() {
        // 固定无效值不会被其他并发测试重新分配，仍直接验证 writer 暴露 EBADF 的契约。
        let writer = FileDescriptorChunkWriter(fileDescriptor: -1)

        do {
            try writer.write(Data([1]))
            Issue.record("无效文件描述符不应写入成功")
        } catch let error as NSError {
            #expect(error.domain == NSPOSIXErrorDomain)
            #expect(error.code == Int(EBADF))
        }
    }
}

private final class ReaderResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Data?, any Error>?

    func store(_ result: Result<Data?, any Error>) {
        lock.withLock {
            self.result = result
        }
    }

    func load() -> Result<Data?, any Error>? {
        lock.withLock { result }
    }
}
