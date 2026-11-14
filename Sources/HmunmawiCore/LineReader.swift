import Foundation
import Synchronization

/// Reads a pipe on a background dispatch queue (never the main thread or Swift's task pool) and yields whole lines.
enum LineReader {
    /// The longest line kept (a poll answer with 10,000 events fits well inside).
    static let maxLineBytes = 64 * 1024 * 1024
    static func lines(from handle: FileHandle) -> AsyncStream<String> {
        AsyncStream { continuation in
            let buffer = Mutex(Data())
            handle.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                    continuation.finish()
                    return
                }
                let lines = buffer.withLock { data -> [String] in
                    data.append(chunk)
                    // One message is never this big: a sender that never ends a line can't fill memory. The
                    // partial line is dropped (its reply never matches a request, which then times out).
                    if data.count > maxLineBytes, data.firstIndex(of: 0x0A) == nil { data.removeAll(keepingCapacity: false) }
                    var lines: [String] = []
                    while let newline = data.firstIndex(of: 0x0A) {
                        lines.append(String(decoding: data[data.startIndex..<newline], as: UTF8.self))
                        data.removeSubrange(data.startIndex...newline)
                    }
                    return lines
                }
                for line in lines { continuation.yield(line) }
            }
        }
    }

    /// Reads everything until the other side closes, off the task pool.
    static func readAll(_ handle: FileHandle) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: handle.readDataToEndOfFile())
            }
        }
    }

    static func waitForExit(_ process: Process) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                process.waitUntilExit()
                continuation.resume()
            }
        }
    }
}
