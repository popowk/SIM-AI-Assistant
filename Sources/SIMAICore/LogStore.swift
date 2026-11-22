import Foundation

/// All disk events are sanitized before they are written. OSLog is a secondary sink in the UI target.

public enum LogCleanupError: Error {
    case invalidRetentionDays
}

public struct LogCleanupSummary: Equatable {
    public let fileCount: Int
    public let totalBytes: Int64

    public init(fileCount: Int, totalBytes: Int64) {
        self.fileCount = fileCount
        self.totalBytes = totalBytes
    }
}

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


    /// Only removes events-YYYYMMDD.jsonl files strictly older than the cutoff UTC day.
    /// Today and the requested retention window are always preserved.
    public func previewCleanup(olderThanDays days: Int, referenceDate: Date = Date()) throws -> LogCleanupSummary {
        guard (1...3650).contains(days) else { throw LogCleanupError.invalidRetentionDays }
        lock.lock(); defer { lock.unlock() }
        let files = try cleanupCandidates(days: days, referenceDate: referenceDate)
        return try summarize(files)
    }

    public func cleanup(olderThanDays days: Int, referenceDate: Date = Date()) throws -> LogCleanupSummary {
        guard (1...3650).contains(days) else { throw LogCleanupError.invalidRetentionDays }
        lock.lock(); defer { lock.unlock() }
        let files = try cleanupCandidates(days: days, referenceDate: referenceDate)
        let summary = try summarize(files)
        for file in files {
            try manager.removeItem(at: file)
        }
        return summary
    }


    /// Wipes ALL of this application's local JSONL diagnostic days, including today.
    /// Does not and cannot remove entries from macOS unified OSLog.
    public func previewAllLogs() throws -> LogCleanupSummary {
        lock.lock(); defer { lock.unlock() }
        return try summarize(try managedEventFiles())
    }

    public func clearAllLogs() throws -> LogCleanupSummary {
        lock.lock(); defer { lock.unlock() }
        let files = try managedEventFiles()
        let summary = try summarize(files)
        for file in files {
            try manager.removeItem(at: file)
        }
        return summary
    }

    private func managedEventFiles() throws -> [URL] {
        try logFiles().filter { file in
            let stem = file.deletingPathExtension().lastPathComponent
            guard stem.hasPrefix("events-") else { return false }
            let day = stem.dropFirst("events-".count)
            return day.count == 8 && day.allSatisfy { $0.isASCII && $0.isNumber }
        }
    }

    private func summarize(_ files: [URL]) throws -> LogCleanupSummary {
        var bytes: Int64 = 0
        for file in files {
            let attributes = try manager.attributesOfItem(atPath: file.path)
            bytes += (attributes[.size] as? NSNumber)?.int64Value ?? 0
        }
        return LogCleanupSummary(fileCount: files.count, totalBytes: bytes)
    }

    private func cleanupCandidates(days: Int, referenceDate: Date) throws -> [URL] {
        // Log filenames are UTC calendar days. Deliberately keep the cutoff day too,
        // avoiding deletion of a currently-written file and incomplete calendar days.
        let cutoff = Self.dayFormatter.string(from:
            referenceDate.addingTimeInterval(-Double(days) * 86_400))
        return try logFiles().filter { file in
            let stem = file.deletingPathExtension().lastPathComponent
            guard stem.hasPrefix("events-") else { return false }
            let day = String(stem.dropFirst("events-".count))
            return day.count == 8 && day.allSatisfy { $0.isASCII && $0.isNumber } && day < cutoff
        }
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
