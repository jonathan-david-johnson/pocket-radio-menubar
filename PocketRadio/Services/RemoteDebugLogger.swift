import Foundation
import Combine

@MainActor
final class RemoteDebugLogger: ObservableObject {
    static let shared = RemoteDebugLogger()

    private let fileURL: URL
    private let maxLines = 500

    @Published private(set) var lines: [String] = []

    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("PocketRadio", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("remote_debug.log")
        loadFromDisk()
    }

    func log(_ message: String) {
        let ts = formatter.string(from: Date())
        let line = "[\(ts)] \(message)"
        lines.append(line)
        if lines.count > maxLines {
            lines.removeFirst(lines.count - maxLines)
        }
        appendToDisk(line)
    }

    func clear() {
        lines = []
        try? "".write(to: fileURL, atomically: true, encoding: .utf8)
    }

    private func loadFromDisk() {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        let loaded = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        lines = Array(loaded.suffix(maxLines))
    }

    private func appendToDisk(_ line: String) {
        guard let data = (line + "\n").data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: fileURL.path) {
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            }
        } else {
            try? data.write(to: fileURL)
        }
    }
}
