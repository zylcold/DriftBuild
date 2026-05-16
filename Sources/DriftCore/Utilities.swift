import CryptoKit
import Foundation

public enum DriftPaths {
    public static var cliConfig: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".driftbuild", isDirectory: true)
            .appendingPathComponent("config.json")
    }

    public static var defaultServerRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("ios-build-server", isDirectory: true)
    }

    public static func ensureParentDirectory(for file: URL) throws {
        let directory = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}

public enum TokenHasher {
    public static func hash(_ token: String) -> String {
        let digest = SHA256.hash(data: Data(token.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func randomToken() -> String {
        "dbt_" + randomString(length: 40)
    }

    public static func randomCode() -> String {
        String(format: "%06d", Int.random(in: 0...999_999))
    }

    public static func randomString(length: Int) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        return String((0..<length).map { _ in alphabet.randomElement()! })
    }
}

public enum RepoValidator {
    public static func isValid(_ repo: String) -> Bool {
        if repo.range(of: #"^git@[A-Za-z0-9._-]+:[A-Za-z0-9._/\-]+(\.git)?$"#, options: .regularExpression) != nil {
            return true
        }
        guard let url = URL(string: repo), let scheme = url.scheme?.lowercased(), url.host != nil else {
            return false
        }
        return ["https", "http", "ssh", "git"].contains(scheme)
    }
}

public enum RepoHasher {
    public static func shortHash(_ value: String, length: Int = 12) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(length).description
    }
}

public enum JSONFile {
    public static func load<T: Decodable>(_ type: T.Type, from url: URL, default defaultValue: T) throws -> T {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return defaultValue
        }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: data)
    }

    public static func save<T: Encodable>(_ value: T, to url: URL) throws {
        try DriftPaths.ensureParentDirectory(for: url)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        try data.write(to: url, options: [.atomic])
    }
}

public enum LogReader {
    public static func readChunk(url: URL, offset: UInt64, maxBytes: Int = 64 * 1024) throws -> LogChunkResponse {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return LogChunkResponse(offset: offset, nextOffset: offset, text: "", eof: true)
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let start = min(offset, fileSize)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: start)
        let data = try handle.read(upToCount: maxBytes) ?? Data()
        let next = start + UInt64(data.count)
        return LogChunkResponse(
            offset: start,
            nextOffset: next,
            text: String(decoding: data, as: UTF8.self),
            eof: next >= fileSize
        )
    }
}

public enum DateFormatting {
    public static func isoString(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
