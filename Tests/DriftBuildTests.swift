import DriftCore
import XCTest

final class DriftBuildTests: XCTestCase {
    func testTokenHashIsStableAndNotPlaintext() {
        let token = "dbt_test_token"
        let hash = TokenHasher.hash(token)
        XCTAssertEqual(hash, TokenHasher.hash(token))
        XCTAssertNotEqual(hash, token)
        XCTAssertEqual(hash.count, 64)
    }

    func testRepoValidation() {
        XCTAssertTrue(RepoValidator.isValid("git@example.com:ios/App.git"))
        XCTAssertTrue(RepoValidator.isValid("https://example.com/ios/App.git"))
        XCTAssertTrue(RepoValidator.isValid("ssh://git@example.com/ios/App.git"))
        XCTAssertFalse(RepoValidator.isValid("not a url"))
        XCTAssertFalse(RepoValidator.isValid("file:///tmp/App.git"))
    }

    func testJobRecordCodable() throws {
        let request = BuildRequest(
            repo: "git@example.com:ios/App.git",
            branch: "main",
            commit: "abc123",
            workspace: nil,
            project: nil,
            scheme: "App"
        )
        let job = JobRecord(id: "job_1", request: request, status: .queued)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(job)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(JobRecord.self, from: data)
        XCTAssertEqual(decoded.id, "job_1")
        XCTAssertEqual(decoded.status, .queued)
        XCTAssertEqual(decoded.request.scheme, "App")
    }

    func testLogOffsetRead() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DriftBuildTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let log = directory.appendingPathComponent("build.log")
        try "hello\nworld\n".write(to: log, atomically: true, encoding: .utf8)
        let first = try LogReader.readChunk(url: log, offset: 0, maxBytes: 6)
        XCTAssertEqual(first.text, "hello\n")
        XCTAssertEqual(first.nextOffset, 6)
        let second = try LogReader.readChunk(url: log, offset: first.nextOffset, maxBytes: 64)
        XCTAssertEqual(second.text, "world\n")
        XCTAssertTrue(second.eof)
    }

    func testRepoHashLength() {
        XCTAssertEqual(RepoHasher.shortHash("https://example.com/repo.git").count, 12)
    }
}
