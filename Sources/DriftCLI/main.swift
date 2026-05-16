import ArgumentParser
import DriftCore
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Darwin

struct RuntimeError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

struct PairedServer: Codable {
    var name: String
    var url: String
    var token: String
    var pairedAt: Date
    var lastUsedAt: Date
}

struct CLIConfig: Codable {
    var defaultServer: String?
    var servers: [PairedServer]

    static let empty = CLIConfig(defaultServer: nil, servers: [])

    mutating func upsert(_ server: PairedServer) {
        servers.removeAll { $0.name == server.name || $0.url == server.url }
        servers.append(server)
        defaultServer = server.name
    }

    mutating func remove(_ name: String) {
        servers.removeAll { $0.name == name || $0.url == name }
        if defaultServer == name {
            defaultServer = servers.first?.name
        }
    }

    func resolve(_ selector: String?) throws -> PairedServer {
        let key = selector ?? defaultServer
        guard let key else {
            throw RuntimeError("No paired server. Run `drift pair` first.")
        }
        if let found = servers.first(where: { $0.name == key || $0.url == normalizeURL(key) }) {
            return found
        }
        throw RuntimeError("No paired server matches \(key). Run `drift servers` to inspect configured servers.")
    }
}

enum ConfigStore {
    static func load() throws -> CLIConfig {
        try JSONFile.load(CLIConfig.self, from: DriftPaths.cliConfig, default: .empty)
    }

    static func save(_ config: CLIConfig) throws {
        try JSONFile.save(config, to: DriftPaths.cliConfig)
    }
}

struct EmptyBody: Encodable {}

final class DriftHTTPClient {
    let baseURL: URL

    init(serverURL: String) throws {
        guard let url = URL(string: normalizeURL(serverURL) + "/") else {
            throw RuntimeError("Invalid server URL: \(serverURL)")
        }
        self.baseURL = url
    }

    func get<T: Decodable>(_ path: String, token: String? = nil) async throws -> T {
        var request = URLRequest(url: try makeURL(path))
        request.httpMethod = "GET"
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return try await send(request)
    }

    func post<B: Encodable, T: Decodable>(_ path: String, body: B, token: String? = nil) async throws -> T {
        var request = URLRequest(url: try makeURL(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        request.httpBody = try encoder.encode(body)
        return try await send(request)
    }

    func download(_ path: String, token: String, outputDirectory: URL, fileName: String) async throws -> URL {
        var request = URLRequest(url: try makeURL(path))
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (temporary, response) = try await URLSession.shared.download(for: request)
        try validate(response: response, data: nil)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let target = outputDirectory.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
        try FileManager.default.moveItem(at: temporary, to: target)
        return target
    }

    private func makeURL(_ path: String) throws -> URL {
        guard let url = URL(string: path.trimmedPathPrefix(), relativeTo: baseURL)?.absoluteURL else {
            throw RuntimeError("Invalid request path: \(path)")
        }
        return url
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: data)
    }

    private func validate(response: URLResponse, data: Data?) throws {
        guard let http = response as? HTTPURLResponse else {
            throw RuntimeError("Invalid HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            if let data, let error = try? JSONDecoder().decode(ErrorResponse.self, from: data) {
                throw RuntimeError("HTTP \(http.statusCode): \(error.error)")
            }
            let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            throw RuntimeError("HTTP \(http.statusCode): \(text)")
        }
    }
}

final class BonjourBrowser: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    private var browser: NetServiceBrowser?
    private var services: [NetService] = []
    private var results: [ServerInfo] = []

    func discover(timeout: TimeInterval) -> [ServerInfo] {
        let browser = NetServiceBrowser()
        self.browser = browser
        browser.delegate = self
        browser.searchForServices(ofType: DriftVersion.bonjourType, inDomain: "local.")

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: min(Date().addingTimeInterval(0.1), deadline))
        }
        browser.stop()
        return results
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        services.append(service)
        service.delegate = self
        service.resolve(withTimeout: 2)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        let txt = sender.txtRecordData().map(NetService.dictionary(fromTXTRecord:)) ?? [:]
        func text(_ key: String) -> String? {
            txt[key].flatMap { String(data: $0, encoding: .utf8) }
        }

        let host = sender.hostName ?? text("host") ?? sender.name
        let port = sender.port
        guard port > 0 else { return }
        let url = text("url") ?? "http://\(host):\(port)"
        let info = ServerInfo(
            id: text("id") ?? url,
            name: text("name") ?? sender.name,
            host: host,
            port: port,
            url: normalizeURL(url),
            version: text("version") ?? "unknown",
            xcode: text("xcode") ?? "unknown",
            maxJobs: Int(text("maxJobs") ?? "1") ?? 1
        )
        if !results.contains(where: { $0.url == info.url }) {
            results.append(info)
        }
    }
}

enum UDPDiscovery {
    static func discover(timeout: TimeInterval) -> [ServerInfo] {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return [] }
        defer { close(fd) }

        var enabled: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &enabled, socklen_t(MemoryLayout<Int32>.size))

        var receiveTimeout = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &receiveTimeout, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(DriftVersion.udpPort).bigEndian
        address.sin_addr.s_addr = inet_addr("255.255.255.255")

        let payload = Array(DriftVersion.udpProbe.utf8)
        payload.withUnsafeBytes { rawBuffer in
            withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                    _ = sendto(fd, rawBuffer.baseAddress, rawBuffer.count, 0, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }

        let deadline = Date().addingTimeInterval(timeout)
        var results: [ServerInfo] = []
        while Date() < deadline {
            var from = sockaddr_in()
            var fromLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            var buffer = [UInt8](repeating: 0, count: 4096)
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                withUnsafeMutablePointer(to: &from) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                        recvfrom(fd, rawBuffer.baseAddress, rawBuffer.count, 0, socketAddress, &fromLength)
                    }
                }
            }
            guard count > 0 else { break }
            let data = Data(buffer.prefix(count))
            if let info = try? JSONDecoder().decode(ServerInfo.self, from: data), !results.contains(where: { $0.url == info.url }) {
                results.append(info)
            }
        }
        return results
    }
}

enum DiscoveryService {
    static func discover(timeout: TimeInterval) -> [ServerInfo] {
        let bonjour = BonjourBrowser().discover(timeout: min(timeout, 3))
        if !bonjour.isEmpty {
            return bonjour
        }
        return UDPDiscovery.discover(timeout: timeout)
    }
}

@main
struct Drift: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "drift",
        abstract: "LAN remote iOS build CLI.",
        version: DriftVersion.current,
        subcommands: [
            Discover.self,
            Pair.self,
            Submit.self,
            Status.self,
            Logs.self,
            Artifact.self,
            Cancel.self,
            Servers.self,
            Version.self
        ]
    )
}

struct Discover: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Discover drift-server instances on the LAN.")

    @Option(help: "Discovery timeout in seconds.")
    var timeout: Double = 3

    @Flag(name: .long, help: "Emit JSON.")
    var json = false

    func run() async throws {
        let servers = DiscoveryService.discover(timeout: timeout)
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(data: try encoder.encode(servers), encoding: .utf8) ?? "[]")
            return
        }
        if servers.isEmpty {
            print("No drift-server found. Use `drift pair --server http://host:8000` if discovery is blocked.")
            return
        }
        print(row(["NAME", "HOST", "PORT", "VERSION", "XCODE"], widths: [24, 24, 6, 12, 0]))
        for server in servers {
            print(row([server.name, server.host, String(server.port), server.version, server.xcode], widths: [24, 24, 6, 12, 0]))
        }
    }
}

struct Pair: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Pair this CLI with a drift-server.")

    @Option(help: "Server URL. If omitted, LAN discovery is used.")
    var server: String?

    @Option(help: "Client display name.")
    var name: String?

    @Option(help: "Polling timeout in seconds.")
    var timeout: Int = 300

    func run() async throws {
        let serverURL = try selectServerURL()
        let client = try DriftHTTPClient(serverURL: serverURL)
        let token = TokenHasher.randomToken()
        let clientName = name ?? Host.current().localizedName ?? "drift-cli"
        let request = PairingRequest(clientName: clientName, tokenHash: TokenHasher.hash(token))
        let created: PairingCreatedResponse = try await client.post("/api/auth/pairings", body: request)

        print("Pairing code: \(created.pairingCode)")
        print("Approve it on the build Mac:")
        print("  drift-server approve --code \(created.pairingCode)")

        let deadline = Date().addingTimeInterval(TimeInterval(timeout))
        while Date() < deadline {
            let status: PairingStatusResponse = try await client.get("/api/auth/pairings/\(created.pairingId)")
            switch status.status {
            case .approved:
                var config = try ConfigStore.load()
                let paired = PairedServer(
                    name: status.serverName ?? URL(string: normalizeURL(serverURL))?.host ?? "drift-server",
                    url: normalizeURL(status.serverURL ?? serverURL),
                    token: token,
                    pairedAt: Date(),
                    lastUsedAt: Date()
                )
                config.upsert(paired)
                try ConfigStore.save(config)
                print("Paired with \(paired.name) at \(paired.url).")
                return
            case .rejected:
                throw RuntimeError("Pairing rejected.")
            case .expired:
                throw RuntimeError("Pairing expired.")
            case .pending:
                try await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        throw RuntimeError("Pairing timed out.")
    }

    private func selectServerURL() throws -> String {
        if let server {
            return normalizeURL(server)
        }
        let servers = DiscoveryService.discover(timeout: 3)
        guard !servers.isEmpty else {
            throw RuntimeError("No drift-server found. Pass --server http://host:8000.")
        }
        if servers.count == 1 {
            return servers[0].url
        }
        for (index, server) in servers.enumerated() {
            print("[\(index + 1)] \(server.name) \(server.url) \(server.xcode)")
        }
        print("Select server: ", terminator: "")
        guard let input = readLine(), let selected = Int(input), servers.indices.contains(selected - 1) else {
            throw RuntimeError("Invalid selection.")
        }
        return servers[selected - 1].url
    }
}

struct Submit: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Submit a remote iOS simulator build.")

    @Option(help: "Paired server name or URL.")
    var server: String?

    @Option(help: "Git repository URL.")
    var repo: String

    @Option(help: "Git branch.")
    var branch: String

    @Option(help: "Git commit SHA.")
    var commit: String?

    @Option(help: "Explicit .xcworkspace path relative to repo root.")
    var workspace: String?

    @Option(help: "Explicit .xcodeproj path relative to repo root.")
    var project: String?

    @Option(help: "Xcode scheme.")
    var scheme: String

    @Option(help: "Build configuration.")
    var configuration: String = "Debug"

    @Flag(help: "Include Build.xcresult in result.zip.")
    var includeXcresult = false

    @Option(help: "Build timeout in seconds.")
    var timeout: Int = 3600

    @Flag(help: "Wait for completion and stream logs.")
    var wait = false

    @Flag(help: "Download result.zip when the job completes. Implies --wait.")
    var download = false

    @Option(help: "Output directory for artifacts.")
    var output: String = "./remote-build-output"

    func run() async throws {
        guard RepoValidator.isValid(repo) else {
            throw RuntimeError("Invalid repo URL. Use https://, ssh://, git://, or git@host:path.git.")
        }
        let paired = try ConfigStore.load().resolve(server)
        let client = try DriftHTTPClient(serverURL: paired.url)
        let request = BuildRequest(
            repo: repo,
            branch: branch,
            commit: commit,
            workspace: workspace,
            project: project,
            scheme: scheme,
            configuration: configuration,
            includeXcresult: includeXcresult,
            timeoutSeconds: timeout
        )
        let response: BuildCreatedResponse = try await client.post("/api/builds", body: request, token: paired.token)
        print("Job \(response.jobId) queued.")
        if wait || download {
            try await FollowHelper.follow(
                client: client,
                jobId: response.jobId,
                token: paired.token,
                download: download,
                output: URL(fileURLWithPath: output, isDirectory: true)
            )
        }
    }
}

struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show a build job status.")

    @Option(help: "Paired server name or URL.")
    var server: String?

    @Option(help: "Build job id.")
    var jobId: String

    func run() async throws {
        let paired = try ConfigStore.load().resolve(server)
        let client = try DriftHTTPClient(serverURL: paired.url)
        let job: JobRecord = try await client.get("/api/builds/\(jobId)", token: paired.token)
        print("\(job.id) \(job.status.rawValue) stage=\(job.stage) artifact=\(job.artifactReady)")
        if let message = job.errorMessage {
            print(message)
        }
    }
}

struct Logs: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Read build logs.")

    @Option(help: "Paired server name or URL.")
    var server: String?

    @Option(help: "Build job id.")
    var jobId: String

    @Flag(help: "Follow until the job reaches a terminal state.")
    var follow = false

    func run() async throws {
        let paired = try ConfigStore.load().resolve(server)
        let client = try DriftHTTPClient(serverURL: paired.url)
        var offset: UInt64 = 0
        while true {
            let chunk: LogChunkResponse = try await client.get("/api/builds/\(jobId)/logs?offset=\(offset)", token: paired.token)
            if !chunk.text.isEmpty {
                print(chunk.text, terminator: "")
            }
            offset = chunk.nextOffset
            if !follow {
                return
            }
            let job: JobRecord = try await client.get("/api/builds/\(jobId)", token: paired.token)
            if job.status.isTerminal && chunk.eof {
                return
            }
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }
}

struct Artifact: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Download a job artifact.")

    @Option(help: "Paired server name or URL.")
    var server: String?

    @Option(help: "Build job id.")
    var jobId: String

    @Option(help: "Output directory.")
    var output: String = "./remote-build-output"

    func run() async throws {
        let paired = try ConfigStore.load().resolve(server)
        let client = try DriftHTTPClient(serverURL: paired.url)
        let url = try await client.download(
            "/api/builds/\(jobId)/artifact",
            token: paired.token,
            outputDirectory: URL(fileURLWithPath: output, isDirectory: true).appendingPathComponent(jobId, isDirectory: true),
            fileName: "result.zip"
        )
        print("Downloaded \(url.path)")
    }
}

struct Cancel: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Cancel a queued or running job.")

    @Option(help: "Paired server name or URL.")
    var server: String?

    @Option(help: "Build job id.")
    var jobId: String

    func run() async throws {
        let paired = try ConfigStore.load().resolve(server)
        let client = try DriftHTTPClient(serverURL: paired.url)
        let response: CancelResponse = try await client.post("/api/builds/\(jobId)/cancel", body: EmptyBody(), token: paired.token)
        print("\(response.jobId) \(response.status.rawValue)")
    }
}

struct Servers: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List or edit paired servers.")

    @Option(name: .long, help: "Set the default server by name.")
    var setDefault: String?

    @Option(name: .long, help: "Remove a paired server by name.")
    var remove: String?

    func run() throws {
        var config = try ConfigStore.load()
        if let remove {
            config.remove(remove)
            try ConfigStore.save(config)
            print("Removed \(remove).")
            return
        }
        if let setDefault {
            guard config.servers.contains(where: { $0.name == setDefault }) else {
                throw RuntimeError("Unknown server \(setDefault).")
            }
            config.defaultServer = setDefault
            try ConfigStore.save(config)
            print("Default server set to \(setDefault).")
            return
        }
        if config.servers.isEmpty {
            print("No paired servers.")
            return
        }
        for server in config.servers {
            let marker = config.defaultServer == server.name ? "*" : " "
            print("\(marker) \(server.name) \(server.url)")
        }
    }
}

struct Version: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Print CLI version.")

    func run() {
        print(DriftVersion.current)
    }
}

enum FollowHelper {
    static func follow(client: DriftHTTPClient, jobId: String, token: String, download: Bool, output: URL) async throws {
        var offset: UInt64 = 0
        var lastStatus: JobStatus?
        while true {
            let chunk: LogChunkResponse = try await client.get("/api/builds/\(jobId)/logs?offset=\(offset)", token: token)
            if !chunk.text.isEmpty {
                print(chunk.text, terminator: "")
            }
            offset = chunk.nextOffset

            let job: JobRecord = try await client.get("/api/builds/\(jobId)", token: token)
            if lastStatus != job.status {
                print("\n[drift] \(job.status.rawValue)")
                lastStatus = job.status
            }
            if job.status.isTerminal {
                if download && job.artifactReady {
                    let artifact = try await client.download(
                        "/api/builds/\(jobId)/artifact",
                        token: token,
                        outputDirectory: output.appendingPathComponent(jobId, isDirectory: true),
                        fileName: "result.zip"
                    )
                    print("[drift] downloaded \(artifact.path)")
                }
                if job.status == .success {
                    return
                }
                throw RuntimeError("Remote build finished with status \(job.status.rawValue).")
            }
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }
}

func normalizeURL(_ value: String) -> String {
    var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
    while text.hasSuffix("/") {
        text.removeLast()
    }
    return text
}

extension String {
    func trimmedPathPrefix() -> String {
        var value = self
        while value.hasPrefix("/") {
            value.removeFirst()
        }
        return value
    }
}

func row(_ values: [String], widths: [Int]) -> String {
    zip(values, widths).map { value, width in
        guard width > 0, value.count < width else { return value }
        return value + String(repeating: " ", count: width - value.count)
    }.joined(separator: " ")
}
