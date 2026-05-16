import Foundation

public enum DriftVersion {
    public static let current = "0.1.0"
    public static let bonjourType = "_driftbuild._tcp."
    public static let udpPort = 37987
    public static let udpProbe = "DRIFTBUILD_DISCOVER"
}

public struct ServerInfo: Codable, Hashable {
    public var id: String
    public var name: String
    public var host: String
    public var port: Int
    public var url: String
    public var version: String
    public var xcode: String
    public var maxJobs: Int

    public init(id: String, name: String, host: String, port: Int, url: String, version: String, xcode: String, maxJobs: Int) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.url = url
        self.version = version
        self.xcode = xcode
        self.maxJobs = maxJobs
    }
}

public struct PairingRequest: Codable {
    public var clientName: String
    public var tokenHash: String

    public init(clientName: String, tokenHash: String) {
        self.clientName = clientName
        self.tokenHash = tokenHash
    }
}

public struct PairingCreatedResponse: Codable {
    public var pairingId: String
    public var pairingCode: String
    public var expiresIn: Int

    public init(pairingId: String, pairingCode: String, expiresIn: Int) {
        self.pairingId = pairingId
        self.pairingCode = pairingCode
        self.expiresIn = expiresIn
    }
}

public enum PairingStatus: String, Codable {
    case pending
    case approved
    case rejected
    case expired
}

public struct PairingStatusResponse: Codable {
    public var status: PairingStatus
    public var serverName: String?
    public var serverURL: String?

    public init(status: PairingStatus, serverName: String? = nil, serverURL: String? = nil) {
        self.status = status
        self.serverName = serverName
        self.serverURL = serverURL
    }
}

public struct BuildRequest: Codable, Hashable {
    public var repo: String
    public var branch: String
    public var commit: String?
    public var workspace: String?
    public var project: String?
    public var scheme: String
    public var configuration: String
    public var includeXcresult: Bool
    public var timeoutSeconds: Int

    public init(
        repo: String,
        branch: String,
        commit: String?,
        workspace: String?,
        project: String?,
        scheme: String,
        configuration: String = "Debug",
        includeXcresult: Bool = false,
        timeoutSeconds: Int = 3600
    ) {
        self.repo = repo
        self.branch = branch
        self.commit = commit
        self.workspace = workspace
        self.project = project
        self.scheme = scheme
        self.configuration = configuration
        self.includeXcresult = includeXcresult
        self.timeoutSeconds = timeoutSeconds
    }
}

public enum JobStatus: String, Codable {
    case queued
    case preparing
    case fetching
    case installingDependencies
    case building
    case packaging
    case success
    case failed
    case timeout
    case canceled

    public var isTerminal: Bool {
        switch self {
        case .success, .failed, .timeout, .canceled:
            return true
        default:
            return false
        }
    }
}

public struct JobRecord: Codable, Identifiable {
    public var id: String
    public var request: BuildRequest
    public var status: JobStatus
    public var stage: String
    public var createdAt: Date
    public var startedAt: Date?
    public var finishedAt: Date?
    public var exitCode: Int32?
    public var artifactReady: Bool
    public var errorMessage: String?

    public init(
        id: String,
        request: BuildRequest,
        status: JobStatus,
        stage: String = "queued",
        createdAt: Date = Date(),
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        exitCode: Int32? = nil,
        artifactReady: Bool = false,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.request = request
        self.status = status
        self.stage = stage
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.exitCode = exitCode
        self.artifactReady = artifactReady
        self.errorMessage = errorMessage
    }
}

public struct BuildCreatedResponse: Codable {
    public var jobId: String
    public var status: JobStatus

    public init(jobId: String, status: JobStatus) {
        self.jobId = jobId
        self.status = status
    }
}

public struct LogChunkResponse: Codable {
    public var offset: UInt64
    public var nextOffset: UInt64
    public var text: String
    public var eof: Bool

    public init(offset: UInt64, nextOffset: UInt64, text: String, eof: Bool) {
        self.offset = offset
        self.nextOffset = nextOffset
        self.text = text
        self.eof = eof
    }
}

public struct CancelResponse: Codable {
    public var jobId: String
    public var status: JobStatus

    public init(jobId: String, status: JobStatus) {
        self.jobId = jobId
        self.status = status
    }
}

public struct ErrorResponse: Codable {
    public var error: String

    public init(_ error: String) {
        self.error = error
    }
}
