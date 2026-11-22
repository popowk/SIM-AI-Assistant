import Foundation

/// All disk events are sanitized before they are written. OSLog is a secondary sink in the UI target.
public final class LogStore {
    public let directory: URL
    private let manager: FileManager
    private let lock = NSLock()
    public let maxAgeDays: Int
    public let maxTotalBytes: Int64

    public init(directory: URL, maxAgeDays: Int = 14, maxTotalBytes: Int64 = 50 * 1024 * 1024,
                manager: FileManager = .default) throws {
        self.directory = directory; self.maxAgeDays = maxAgeDays
        self.maxTotalBytes = maxTotalBytes; self.manager = manager
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        try prune()
    }

    @discardableResult
    public func append(_ event: DiagnosticEvent) throws -> DiagnosticEvent {
        let safe = event.sanitized()
        lock.lock(); defer { lock.unlock() }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(safe)
        data.append(0x0A)
        let name = "events-\(Self.dayFormatter.string(from: safe.timestamp)).jsonl"
        let file = directory.appendingPathComponent(name)
        if manager.fileExists(atPath: file.path) {
            let stream = try FileHandle(forWritingTo: file)
            defer { try? stream.close() }
            try stream.seekToEnd()
            try stream.write(contentsOf: data)
        } else {
            try data.write(to: file, options: .atomic)
        }
        try pruneUnlocked()
        return safe
    }

    public func readRecent(limit: Int = 200) throws -> [DiagnosticEvent] {
        lock.lock(); defer { lock.unlock() }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let urls = try logFiles().sorted { $0.lastPathComponent > $1.lastPathComponent }
        var collected: [DiagnosticEvent] = []
        for file in urls {
            let text = try String(contentsOf: file, encoding: .utf8)
            for line in text.split(separator: "\n").reversed() {
                if let event = try? decoder.decode(DiagnosticEvent.self, from: Data(line.utf8)) {
                    collected.append(event.sanitized())
                }
                if collected.count >= limit { return collected }
            }
        }
        return collected
    }

    public func readAllSafeLines() throws -> String {
        lock.lock(); defer { lock.unlock() }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        var result = ""
        for url in try logFiles().sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") {
                guard let decoded = try? decoder.decode(DiagnosticEvent.self, from: Data(line.utf8)),
                      let data = try? encoder.encode(decoded.sanitized()),
                      let string = String(data: data, encoding: .utf8) else { continue }
                result += string + "\n"
            }
        }
        return result
    }

    public func prune(referenceDate: Date = Date()) throws {
        lock.lock(); defer { lock.unlock() }
        try pruneUnlocked(referenceDate: referenceDate)
    }

    private func pruneUnlocked(referenceDate: Date = Date()) throws {
        let threshold = referenceDate.addingTimeInterval(-Double(maxAgeDays) * 86_400)
        for file in try logFiles() {
            let attrs = try manager.attributesOfItem(atPath: file.path)
            if let modified = attrs[.modificationDate] as? Date, modified < threshold {
                try manager.removeItem(at: file)
            }
        }
        let files = try logFiles().sorted {
            let first = (try? manager.attributesOfItem(atPath: $0.path)[.modificationDate] as? Date) ?? .distantPast
            let second = (try? manager.attributesOfItem(atPath: $1.path)[.modificationDate] as? Date) ?? .distantPast
            return first < second
        }
        var total: Int64 = 0
        for file in files {
            let size = (try manager.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
            total += size
        }
        for file in files where total > maxTotalBytes {
            let size = (try manager.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
            try manager.removeItem(at: file)
            total -= size
        }
    }

    private func logFiles() throws -> [URL] {
        try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
            .filter { $0.lastPathComponent.hasPrefix("events-") && $0.pathExtension == "jsonl" }
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}
