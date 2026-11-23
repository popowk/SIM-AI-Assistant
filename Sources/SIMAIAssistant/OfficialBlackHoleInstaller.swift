#if os(macOS)
import Foundation
import CryptoKit

/// Installers are NEVER bundled or mirrored in this app.
/// Download only unmodified official upstream packages at user request,
/// verify their exact published Homebrew Cask SHA-256, then open the
/// macOS Installer UI for user-admin authorization.
enum OfficialBlackHoleInstaller {
    enum Failure: Error {
        case unsupportedChannels
        case invalidResponse
        case oversizedFile
        case checksumMismatch
    }

    struct Package {
        let channels: Int
        let version: String
        let sha256: String

        var filename: String { "BlackHole\(channels)ch-\(version).pkg" }
        var url: URL {
            URL(string: "https://existential.audio/downloads/\(filename)")!
        }
    }

    // Version 0.7.1, Homebrew/homebrew-cask Casks/b/blackhole-{2,16}ch.rb.
    // Update URL and checksum together; do not disable verification.
    static func descriptor(for channels: Int) throws -> Package {
        switch channels {
        case 2:
            return Package(channels: 2, version: "0.7.1",
                sha256: "57b540f27a3e29c37e310e01bee0fdfab76733087e47f997ef9dccf851400dcf")
        case 16:
            return Package(channels: 16, version: "0.7.1",
                sha256: "57254e2f76cd40db7f3f715238b1a2cb2bd08819d38abf4087f2944f71a3641a")
        default:
            throw Failure.unsupportedChannels
        }
    }

    static func prepareOfficialInstaller(channels: Int) async throws -> URL {
        let package = try descriptor(for: channels)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        configuration.httpMaximumConnectionsPerHost = 1
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        // Let URLSession use its own private temporary file rather than
        // caching an unverified package into Application Support.
        let (temporary, response) = try await session.download(from: package.url)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              http.url?.scheme?.lowercased() == "https" else {
            throw Failure.invalidResponse
        }

        let metadata = try FileManager.default.attributesOfItem(atPath: temporary.path)
        guard let count = metadata[.size] as? NSNumber,
              count.int64Value > 4096,
              count.int64Value < 30_000_000 else { throw Failure.oversizedFile }

        let data = try Data(contentsOf: temporary, options: .mappedIfSafe)
        let checksum = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard checksum == package.sha256 else { throw Failure.checksumMismatch }

        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                             in: .userDomainMask)[0]
            .appendingPathComponent("SIM-AI-Assistant", isDirectory: true)
            .appendingPathComponent("OfficialDriverDownloads", isDirectory: true)
        try FileManager.default.createDirectory(at: base,
                                                 withIntermediateDirectories: true)
        let destination = base.appendingPathComponent(package.filename)

        // A prior download is not trusted until its bytes are rechecked.
        // Replacing a file is safe because this is the app's own directory,
        // never a system driver installation path.
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: temporary, to: destination)
        return destination
    }
}
#endif
