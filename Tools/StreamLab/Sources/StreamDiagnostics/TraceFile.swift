import Darwin
import Foundation

/// Single serial caller. Exclusive creation protects existing captures; mode 0600
/// prevents other local users from reading listening history. No audio is stored.
public final class TraceWriter {
    public static let defaultByteLimit = 32 * 1024 * 1024
    private let handle: FileHandle
    private let byteLimit: Int
    private var byteCount = 0
    private var reducer = TraceReducer()
    private var isClosed = false

    public init(url: URL, byteLimit: Int = defaultByteLimit) throws {
        guard url.isFileURL, byteLimit > 0 else { throw TraceError.invalid("file URL and positive limit required") }
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o600)) } ?? -1
        }
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        self.handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        self.byteLimit = byteLimit
    }

    public func append(_ event: TraceEvent) throws {
        guard !isClosed else { throw TraceError.invalid("writer closed") }
        var next = reducer
        try next.apply(event)
        var data = try TraceJSON.encoder().encode(event)
        data.append(0x0A)
        guard data.count <= byteLimit - byteCount else { throw TraceError.limitExceeded }
        try handle.write(contentsOf: data)
        byteCount += data.count
        reducer = next
    }

    public func close() throws {
        guard !isClosed else { return }
        isClosed = true
        defer { try? handle.close() }
        try handle.synchronize()
    }
}

public enum TraceReader {
    public static func read(url: URL, byteLimit: Int = TraceWriter.defaultByteLimit) throws -> [TraceEvent] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        // Bound the actual read, not only a stat that could race a growing file.
        guard byteLimit > 0, byteLimit < Int.max else { throw TraceError.limitExceeded }
        let data = try handle.read(upToCount: byteLimit + 1) ?? Data()
        guard data.count <= byteLimit else { throw TraceError.limitExceeded }
        guard data.last == 0x0A else { throw TraceError.invalid("missing final newline; possibly truncated") }
        let events = try data.split(separator: 0x0A, omittingEmptySubsequences: false).dropLast().enumerated().map { index, line in
            do { return try TraceJSON.decoder().decode(TraceEvent.self, from: Data(line)) }
            catch { throw TraceError.invalid("invalid JSON event at line \(index + 1)") }
        }
        _ = try TraceReplay.snapshots(events)
        return events
    }
}
