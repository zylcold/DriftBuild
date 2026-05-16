import ArgumentParser
import DriftCore
import Foundation

struct Serve: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Run the HTTP build server.")

    @Option(help: "HTTP bind host.")
    var host: String = "0.0.0.0"

    @Option(help: "HTTP bind port.")
    var port: Int = 8000

    @Option(help: "Persistent data directory.")
    var dataDir: String?

    @Option(help: "Server display name.")
    var name: String?

    @Option(help: "Public URL advertised to clients.")
    var publicURL: String?

    @Option(help: "Maximum concurrent builds.")
    var concurrency: Int = 1

    @Flag(help: "Automatically approve pairing requests. Intended only for local demos.")
    var autoApprovePairing = false

    func run() throws {
        try runServer(
            host: host,
            port: port,
            dataDir: dataDir,
            name: name,
            publicURL: publicURL,
            concurrency: concurrency,
            autoApprovePairing: autoApprovePairing
        )
    }
}

struct Approve: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Approve a pending pairing code.")

    @Option(help: "Pairing code or pairing id.")
    var code: String

    @Option(help: "Persistent data directory.")
    var dataDir: String?

    func run() throws {
        let store = try ServerStateStore(root: dataDir.map(expandPath) ?? DriftPaths.defaultServerRoot, serverName: "drift-server", serverURL: "")
        let token = try store.approve(code: code)
        print("Approved \(token.clientName) as \(token.id).")
    }
}

struct Clients: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List paired clients.")

    @Option(help: "Persistent data directory.")
    var dataDir: String?

    func run() throws {
        let store = try ServerStateStore(root: dataDir.map(expandPath) ?? DriftPaths.defaultServerRoot, serverName: "drift-server", serverURL: "")
        let tokens = try store.tokens()
        if tokens.isEmpty {
            print("No clients.")
            return
        }
        for token in tokens {
            let status = token.revokedAt == nil ? "active" : "revoked"
            print("\(token.id) \(token.clientName) \(status) hash=\(token.tokenHash.prefix(12))")
        }
    }
}

struct Revoke: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Revoke a paired client.")

    @Option(help: "Client id or client name.")
    var clientId: String

    @Option(help: "Persistent data directory.")
    var dataDir: String?

    func run() throws {
        let store = try ServerStateStore(root: dataDir.map(expandPath) ?? DriftPaths.defaultServerRoot, serverName: "drift-server", serverURL: "")
        let token = try store.revoke(clientId: clientId)
        print("Revoked \(token.clientName) (\(token.id)).")
    }
}

struct Version: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Print server version.")

    func run() {
        print(DriftVersion.current)
    }
}