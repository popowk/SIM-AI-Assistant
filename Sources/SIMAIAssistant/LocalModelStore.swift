#if os(macOS)
import Foundation
import CryptoKit

/// Model weights are deliberately not bundled. The pinned revision and build-time
/// checksums are shared with the ASR fixture test. No network access occurs on load.
enum LocalModelStore {
    static let revision = "204ad334e2e683fd295359930cc16fc0432a23ac"
    static let names = ["encoder-epoch-99-avg-1.int8.onnx", "decoder-epoch-99-avg-1.int8.onnx",
                        "joiner-epoch-99-avg-1.int8.onnx", "tokens.txt"]
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SIM-AI-Assistant/Models", isDirectory: true)
            .appendingPathComponent(revision, isDirectory: true)
    }
    enum ModelError: Error { case manifest, checksum, download }
    private static func manifest() throws -> [String: String] {
        guard let root = Bundle.main.resourceURL else { throw ModelError.manifest }
        let url = root.appendingPathComponent("LocalReception/model-sha256.txt")
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        var result: [String: String] = [:]
        for line in lines {
            let fields = line.split(whereSeparator: { $0.isWhitespace })
            if fields.count == 2 { result[String(fields[1])] = String(fields[0]).lowercased() }
        }
        guard names.allSatisfy({ result[$0]?.count == 64 }) else { throw ModelError.manifest }
        return result
    }
    private static func checksum(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard !data.isEmpty else { throw ModelError.checksum }
        return SHA256.hash(data: data).map { String(format: "%02x", Int($0)) }.joined()
    }
    static var filesPresent: Bool {
        names.allSatisfy { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }
    }
    static func validate() -> Bool {
        guard let hashes = try? manifest() else { return false }
        return names.allSatisfy { (try? checksum(directory.appendingPathComponent($0))) == hashes[$0] }
    }
    static func download() async throws {
        if validate() { return }
        let hashes = try manifest()
        let fm = FileManager.default
        let parent = directory.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let stage = parent.appendingPathComponent(".download-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: stage) }
        let base = URL(string: "https://huggingface.co/csukuangfj/sherpa-onnx-streaming-zipformer-zh-14M-2023-02-23/resolve/" + revision)!
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 600
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        for name in names {
            try Task.checkCancellation()
            let (tmp, response) = try await session.download(from: base.appendingPathComponent(name))
            defer { try? fm.removeItem(at: tmp) }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  http.url?.scheme == "https", try checksum(tmp) == hashes[name] else { throw ModelError.checksum }
            try fm.moveItem(at: tmp, to: stage.appendingPathComponent(name))
        }
        if fm.fileExists(atPath: directory.path) {
            _ = try fm.replaceItemAt(directory, withItemAt: stage)
        } else {
            try fm.moveItem(at: stage, to: directory)
        }
        guard validate() else { throw ModelError.checksum }
    }
}
#endif
