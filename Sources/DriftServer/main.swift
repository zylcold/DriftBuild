import DriftCore
import Foundation
import Darwin
import ArgumentParser
import Vapor

extension ServerInfo: Content {}
extension PairingRequest: Content {}
extension PairingCreatedResponse: Content {}
extension PairingStatusResponse: Content {}
extension BuildRequest: Content {}
extension BuildCreatedResponse: Content {}
extension JobRecord: Content {}
extension LogChunkResponse: Content {}
extension CancelResponse: Content {}
extension ErrorResponse: Content {}

struct TokenRecord: Codable {
    var id: String
    var clientName: String
    var tokenHash: String
    var createdAt: Date
    var revokedAt: Date?
}

struct PairingRecord: Codable {
    var id: String
    var code: String
    var clientName: String
    var tokenHash: String
    var status: PairingStatus
    var expiresAt: Date
    var createdAt: Date
}

final class ServerStateStore {
    let root: URL
    let serverName: String
    let serverURL: String
    private let lock = NSLock()

    init(root: URL, serverName: String, serverURL: String) throws {
        self.root = root
        self.serverName = serverName
        self.serverURL = normalizeURL(serverURL)
        try FileManager.default.createDirectory(at: authDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: jobsDirectory, withIntermediateDirectories: true)
    }

    var authDirectory: URL { root.appendingPathComponent("auth", isDirectory: true) }
    var jobsDirectory: URL { root.appendingPathComponent("jobs", isDirectory: true) }
    private var tokensFile: URL { authDirectory.appendingPathComponent("clients.json") }
    private var pairingsFile: URL { authDirectory.appendingPathComponent("pairings.json") }

    func jobDirectory(_ jobId: String) -> URL {
        jobsDirectory.appendingPathComponent(jobId, isDirectory: true)
    }

    func outputDirectory(_ jobId: String) -> URL {
        jobDirectory(jobId).appendingPathComponent("output", isDirectory: true)
    }

    func logURL(_ jobId: String) -> URL {
        jobDirectory(jobId).appendingPathComponent("build.log")
    }

    func artifactURL(_ jobId: String) -> URL {
        jobDirectory(jobId).appendingPathComponent("result.zip")
    }

    func createPairing(_ request: PairingRequest, autoApprove: Bool) throws -> PairingCreatedResponse {
        try locked {
            var pairings = try loadPairings()
            let now = Date()
            pairings.removeAll { $0.status == .pending && $0.expiresAt <= now }
            let record = PairingRecord(
                id: "pair_" + TokenHasher.randomString(length: 16),
                code: TokenHasher.randomCode(),
                clientName: request.clientName,
                tokenHash: request.tokenHash,
                status: autoApprove ? .approved : .pending,
                expiresAt: now.addingTimeInterval(300),
                createdAt: now
            )
            pairings.append(record)
            try savePairings(pairings)
            if autoApprove {
                try insertToken(clientName: record.clientName, tokenHash: record.tokenHash, now: now)
            }
            print("Pairing request \(record.id) code=\(record.code) client=\(record.clientName)")
            return PairingCreatedResponse(pairingId: record.id, pairingCode: record.code, expiresIn: 300)
        }
    }

    func pairingStatus(id: String) throws -> PairingStatusResponse {
        try locked {
            var pairings = try loadPairings()
            guard let index = pairings.firstIndex(where: { $0.id == id }) else {
                throw Abort(.notFound, reason: "Pairing not found")
            }
            if pairings[index].status == .pending && pairings[index].expiresAt <= Date() {
                pairings[index].status = .expired
                try savePairings(pairings)
            }
            let status = pairings[index].status
            return PairingStatusResponse(
                status: status,
                serverName: status == .approved ? serverName : nil,
                serverURL: status == .approved ? serverURL : nil
            )
        }
    }

    func approve(code: String) throws -> TokenRecord {
        try locked {
            var pairings = try loadPairings()
            guard let index = pairings.firstIndex(where: { $0.code == code || $0.id == code }) else {
                throw RuntimeServerError("Pairing code not found")
            }
            guard pairings[index].expiresAt > Date() else {
                pairings[index].status = .expired
                try savePairings(pairings)
                throw RuntimeServerError("Pairing code expired")
            }
            pairings[index].status = .approved
            let token = try insertToken(clientName: pairings[index].clientName, tokenHash: pairings[index].tokenHash, now: Date())
            try savePairings(pairings)
            return token
        }
    }

    func tokens() throws -> [TokenRecord] {
        try locked { try loadTokens() }
    }

    func revoke(clientId: String) throws -> TokenRecord {
        try locked {
            var tokens = try loadTokens()
            guard let index = tokens.firstIndex(where: { $0.id == clientId || $0.clientName == clientId }) else {
                throw RuntimeServerError("Client not found")
            }
            tokens[index].revokedAt = Date()
            try saveTokens(tokens)
            return tokens[index]
        }
    }

    func isAuthorized(token: String) throws -> Bool {
        let hash = TokenHasher.hash(token)
        return try locked {
            try loadTokens().contains { $0.tokenHash == hash && $0.revokedAt == nil }
        }
    }

    func createJob(_ request: BuildRequest) throws -> JobRecord {
        try locked {
            let id = Self.makeJobId()
            let job = JobRecord(id: id, request: request, status: .queued, stage: "queued")
            try FileManager.default.createDirectory(at: jobDirectory(id), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: logURL(id).path, contents: nil)
            try saveJob(job)
            return job
        }
    }

    func job(id: String) throws -> JobRecord {
        try locked {
            try JSONFile.load(JobRecord.self, from: jobDirectory(id).appendingPathComponent("state.json"), default: missingJob(id))
        }
    }

    @discardableResult
    func mutateJob(id: String, _ update: (inout JobRecord) -> Void) throws -> JobRecord {
        try locked {
            var job = try JSONFile.load(JobRecord.self, from: jobDirectory(id).appendingPathComponent("state.json"), default: missingJob(id))
            update(&job)
            try saveJob(job)
            return job
        }
    }

    func readLog(jobId: String, offset: UInt64) throws -> LogChunkResponse {
        try locked {
            try LogReader.readChunk(url: logURL(jobId), offset: offset)
        }
    }

    func appendLog(jobId: String, _ text: String) {
        appendLogData(jobId: jobId, Data(text.utf8))
    }

    func appendLogData(jobId: String, _ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        do {
            let url = logURL(jobId)
            try DriftPaths.ensureParentDirectory(for: url)
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            print("log write failed: \(error)")
        }
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func loadTokens() throws -> [TokenRecord] {
        try JSONFile.load([TokenRecord].self, from: tokensFile, default: [])
    }

    private func saveTokens(_ tokens: [TokenRecord]) throws {
        try JSONFile.save(tokens, to: tokensFile)
    }

    private func loadPairings() throws -> [PairingRecord] {
        try JSONFile.load([PairingRecord].self, from: pairingsFile, default: [])
    }

    private func savePairings(_ pairings: [PairingRecord]) throws {
        try JSONFile.save(pairings, to: pairingsFile)
    }

    private func insertToken(clientName: String, tokenHash: String, now: Date) throws -> TokenRecord {
        var tokens = try loadTokens()
        if let existing = tokens.first(where: { $0.tokenHash == tokenHash && $0.revokedAt == nil }) {
            return existing
        }
        let token = TokenRecord(id: "client_" + TokenHasher.randomString(length: 12), clientName: clientName, tokenHash: tokenHash, createdAt: now, revokedAt: nil)
        tokens.append(token)
        try saveTokens(tokens)
        return token
    }

    private func saveJob(_ job: JobRecord) throws {
        try JSONFile.save(job, to: jobDirectory(job.id).appendingPathComponent("state.json"))
    }

    private func missingJob(_ id: String) -> JobRecord {
        JobRecord(
            id: id,
            request: BuildRequest(repo: "", branch: "", commit: nil, workspace: nil, project: nil, scheme: ""),
            status: .failed,
            stage: "missing",
            errorMessage: "Job not found"
        )
    }

    private static func makeJobId() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter.string(from: Date()) + "_" + TokenHasher.randomString(length: 6).lowercased()
    }
}

struct RuntimeServerError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

enum BuildRunError: Error, CustomStringConvertible {
    case message(String)
    case commandFailed(String, Int32)
    case timeout(String)
    case canceled

    var description: String {
        switch self {
        case .message(let message):
            return message
        case .commandFailed(let command, let code):
            return "\(command) exited with code \(code)"
        case .timeout(let command):
            return "\(command) timed out"
        case .canceled:
            return "Build canceled"
        }
    }
}

struct CommandResult {
    var exitCode: Int32
    var timedOut: Bool
    var canceled: Bool
}

struct AgentBuildCommand {
    var executable: String
    var arguments: [String]
    var loggedArguments: [String]

    static func make(agent: BuildAgent, source: URL, output: URL, request: BuildRequest) -> AgentBuildCommand {
        let prompt = makePrompt(source: source, output: output, request: request)
        switch agent {
        case .codex:
            return AgentBuildCommand(
                executable: "codex",
                arguments: ["exec", "--sandbox", "workspace-write", "--color", "never", prompt],
                loggedArguments: ["exec", "--sandbox", "workspace-write", "--color", "never", "<driftbuild-agent-prompt>"]
            )
        case .claude:
            return AgentBuildCommand(
                executable: "claude",
                arguments: ["-p", "--permission-mode", "bypassPermissions", prompt],
                loggedArguments: ["-p", "--permission-mode", "bypassPermissions", "<driftbuild-agent-prompt>"]
            )
        case .opencode:
            return AgentBuildCommand(
                executable: "opencode",
                arguments: ["run", prompt],
                loggedArguments: ["run", "<driftbuild-agent-prompt>"]
            )
        }
    }

    private static func makePrompt(source: URL, output: URL, request: BuildRequest) -> String {
        var lines = [
            "You are running inside a DriftBuild job on a macOS build machine.",
            "Build the checked-out iOS repository at \(source.path).",
            "Use the existing project files and produce an iOS Simulator build.",
            "Scheme: \(request.scheme)",
            "Configuration: \(request.configuration)",
            "Use CODE_SIGNING_ALLOWED=NO and do not archive or export an IPA.",
            "Install repository dependencies when needed, including CocoaPods if a Podfile exists.",
            "Write all useful progress and errors to stdout/stderr so DriftBuild can stream logs.",
            "Do not ask for interactive confirmation."
        ]
        if let workspace = request.workspace, !workspace.isEmpty {
            lines.append("Preferred workspace: \(workspace)")
        }
        if let project = request.project, !project.isEmpty {
            lines.append("Preferred project: \(project)")
        }
        if request.includeXcresult {
            lines.append("If you invoke xcodebuild, write the result bundle to \(output.appendingPathComponent("Build.xcresult", isDirectory: true).path).")
        }
        lines.append("Finish with a non-zero exit code if the build cannot be completed.")
        return lines.joined(separator: "\n")
    }
}

final class ProcessRunner {
    func run(
        executable: String,
        arguments: [String],
        workingDirectory: URL?,
        timeout: TimeInterval,
        onStart: @escaping (Process) -> Void,
        onOutput: @escaping (Data) -> Void,
        shouldCancel: @escaping () -> Bool
    ) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                onOutput(data)
            }
        }

        try process.run()
        onStart(process)

        let startedAt = Date()
        var timedOut = false
        var canceled = false
        while process.isRunning {
            if shouldCancel() {
                canceled = true
                process.terminate()
                break
            }
            if Date().timeIntervalSince(startedAt) > timeout {
                timedOut = true
                process.terminate()
                break
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        process.waitUntilExit()
        pipe.fileHandleForReading.readabilityHandler = nil
        let remaining = pipe.fileHandleForReading.readDataToEndOfFile()
        if !remaining.isEmpty {
            onOutput(remaining)
        }
        return CommandResult(exitCode: process.terminationStatus, timedOut: timedOut, canceled: canceled)
    }
}

final class BuildWorker {
    private let store: ServerStateStore
    private let runner = ProcessRunner()
    private let lock = NSLock()
    private var activeProcesses: [String: Process] = [:]
    private var canceledJobs: Set<String> = []

    init(store: ServerStateStore) {
        self.store = store
    }

    func cancel(jobId: String) {
        lock.lock()
        canceledJobs.insert(jobId)
        let process = activeProcesses[jobId]
        lock.unlock()
        process?.terminate()
    }

    func run(jobId: String) {
        var finalStatus: JobStatus = .failed
        var finalExitCode: Int32?
        var finalError: String?

        do {
            let initial = try store.job(id: jobId)
            guard initial.status != .canceled else {
                finalStatus = .canceled
                throw BuildRunError.canceled
            }

            try transition(jobId, status: .preparing, stage: "preparing") { job in
                job.startedAt = Date()
            }
            try prepareDirectories(jobId: jobId)

            let request = try store.job(id: jobId).request
            let jobDir = store.jobDirectory(jobId)
            let source = jobDir.appendingPathComponent("source", isDirectory: true)
            let output = store.outputDirectory(jobId)

            try transition(jobId, status: .fetching, stage: "fetching")
            try runCommand(jobId: jobId, executable: requireExecutable("git"), arguments: ["clone", "--recursive", request.repo, source.path], workingDirectory: nil, timeout: 1800)
            try runCommand(jobId: jobId, executable: requireExecutable("git"), arguments: ["checkout", request.branch], workingDirectory: source, timeout: 300)
            if let commit = request.commit, !commit.isEmpty {
                try runCommand(jobId: jobId, executable: requireExecutable("git"), arguments: ["reset", "--hard", commit], workingDirectory: source, timeout: 300)
            }
            try runCommand(jobId: jobId, executable: requireExecutable("git"), arguments: ["submodule", "update", "--init", "--recursive"], workingDirectory: source, timeout: 1800)

            if let agent = request.agent {
                try transition(jobId, status: .installingDependencies, stage: "agent dependency handling")
                try transition(jobId, status: .building, stage: "agent build (\(agent.rawValue))")
                try runAgentBuild(jobId: jobId, agent: agent, source: source, output: output, request: request)
            } else {
                try transition(jobId, status: .installingDependencies, stage: "installing dependencies")
                if FileManager.default.fileExists(atPath: source.appendingPathComponent("Podfile").path) {
                    try runCommand(jobId: jobId, executable: requireExecutable("pod"), arguments: ["install"], workingDirectory: source, timeout: 1800)
                } else {
                    store.appendLog(jobId: jobId, "[drift] Podfile not found; letting xcodebuild resolve Swift packages.\n")
                }

                try transition(jobId, status: .building, stage: "building")
                try runXcodeBuild(jobId: jobId, source: source, output: output, jobDir: jobDir, request: request)
            }

            finalStatus = .success
            finalExitCode = 0
        } catch BuildRunError.timeout(let command) {
            finalStatus = .timeout
            finalError = command
        } catch BuildRunError.canceled {
            finalStatus = .canceled
            finalError = "Canceled"
        } catch BuildRunError.commandFailed(let command, let code) {
            finalStatus = .failed
            finalExitCode = code
            finalError = command
        } catch {
            finalStatus = .failed
            finalError = String(describing: error)
        }

        do {
            if finalStatus != .canceled {
                try transition(jobId, status: .packaging, stage: "packaging")
            }
            try package(jobId: jobId, finalStatus: finalStatus, exitCode: finalExitCode, errorMessage: finalError)
        } catch {
            store.appendLog(jobId: jobId, "[drift] artifact packaging failed: \(error)\n")
        }

        let artifactReady = FileManager.default.fileExists(atPath: store.artifactURL(jobId).path)
        try? store.mutateJob(id: jobId) { job in
            job.status = finalStatus
            job.stage = finalStatus.rawValue
            job.exitCode = finalExitCode
            job.finishedAt = Date()
            job.artifactReady = artifactReady
            job.errorMessage = finalError
        }
        clear(jobId: jobId)
    }

    private func prepareDirectories(jobId: String) throws {
        let jobDir = store.jobDirectory(jobId)
        let source = jobDir.appendingPathComponent("source", isDirectory: true)
        let output = store.outputDirectory(jobId)
        if FileManager.default.fileExists(atPath: source.path) {
            try FileManager.default.removeItem(at: source)
        }
        if FileManager.default.fileExists(atPath: output.path) {
            try FileManager.default.removeItem(at: output)
        }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    }

    private func transition(_ jobId: String, status: JobStatus, stage: String, mutate: ((inout JobRecord) -> Void)? = nil) throws {
        try store.mutateJob(id: jobId) { job in
            job.status = status
            job.stage = stage
            mutate?(&job)
        }
        store.appendLog(jobId: jobId, "[drift] \(stage)\n")
    }

    private func runXcodeBuild(jobId: String, source: URL, output: URL, jobDir: URL, request: BuildRequest) throws {
        let containerArguments = try resolveXcodeContainer(source: source, request: request)
        var arguments = ["clean", "build"]
        arguments.append(contentsOf: containerArguments)
        arguments.append(contentsOf: [
            "-scheme", request.scheme,
            "-configuration", request.configuration,
            "-sdk", "iphonesimulator",
            "-destination", "generic/platform=iOS Simulator",
            "-derivedDataPath", jobDir.appendingPathComponent("DerivedData", isDirectory: true).path,
            "CODE_SIGNING_ALLOWED=NO"
        ])
        if request.includeXcresult {
            arguments.append(contentsOf: ["-resultBundlePath", output.appendingPathComponent("Build.xcresult", isDirectory: true).path])
        }
        try runCommand(
            jobId: jobId,
            executable: requireExecutable("xcodebuild"),
            arguments: arguments,
            workingDirectory: source,
            timeout: TimeInterval(request.timeoutSeconds)
        )
    }

    private func runAgentBuild(jobId: String, agent: BuildAgent, source: URL, output: URL, request: BuildRequest) throws {
        let command = AgentBuildCommand.make(agent: agent, source: source, output: output, request: request)
        store.appendLog(jobId: jobId, "[drift] delegating build to \(agent.rawValue)\n")
        try runCommand(
            jobId: jobId,
            executable: requireExecutable(command.executable),
            arguments: command.arguments,
            workingDirectory: source,
            timeout: TimeInterval(request.timeoutSeconds),
            loggedArguments: command.loggedArguments
        )
    }

    private func runCommand(jobId: String, executable: String, arguments: [String], workingDirectory: URL?, timeout: TimeInterval, loggedArguments: [String]? = nil) throws {
        let commandName = URL(fileURLWithPath: executable).lastPathComponent
        store.appendLog(jobId: jobId, "$ \(commandName) \((loggedArguments ?? arguments).joined(separator: " "))\n")
        let result = try runner.run(
            executable: executable,
            arguments: arguments,
            workingDirectory: workingDirectory,
            timeout: timeout,
            onStart: { [weak self] process in self?.setActive(process, jobId: jobId) },
            onOutput: { [weak self] data in self?.store.appendLogData(jobId: jobId, data) },
            shouldCancel: { [weak self] in self?.isCanceled(jobId: jobId) ?? false }
        )
        clearActive(jobId: jobId)
        if result.canceled {
            throw BuildRunError.canceled
        }
        if result.timedOut {
            throw BuildRunError.timeout(commandName)
        }
        if result.exitCode != 0 {
            throw BuildRunError.commandFailed(commandName, result.exitCode)
        }
    }

    private func resolveXcodeContainer(source: URL, request: BuildRequest) throws -> [String] {
        if let workspace = request.workspace, !workspace.isEmpty {
            return ["-workspace", source.appendingPathComponent(workspace).path]
        }
        if let project = request.project, !project.isEmpty {
            return ["-project", source.appendingPathComponent(project).path]
        }
        let entries = try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
        let workspaces = entries.filter { $0.pathExtension == "xcworkspace" }
        if workspaces.count == 1 {
            return ["-workspace", workspaces[0].path]
        }
        let projects = entries.filter { $0.pathExtension == "xcodeproj" }
        if projects.count == 1 {
            return ["-project", projects[0].path]
        }
        if workspaces.isEmpty && projects.isEmpty {
            throw BuildRunError.message("No .xcworkspace or .xcodeproj found at repository root")
        }
        throw BuildRunError.message("Multiple Xcode containers found; pass --workspace or --project")
    }

    private func package(jobId: String, finalStatus: JobStatus, exitCode: Int32?, errorMessage: String?) throws {
        let output = store.outputDirectory(jobId)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let logURL = store.logURL(jobId)
        let copiedLog = output.appendingPathComponent("build.log")
        if FileManager.default.fileExists(atPath: copiedLog.path) {
            try FileManager.default.removeItem(at: copiedLog)
        }
        if FileManager.default.fileExists(atPath: logURL.path) {
            try FileManager.default.copyItem(at: logURL, to: copiedLog)
        } else {
            FileManager.default.createFile(atPath: copiedLog.path, contents: nil)
        }

        var job = try store.job(id: jobId)
        job.status = finalStatus
        job.exitCode = exitCode
        job.finishedAt = Date()
        job.errorMessage = errorMessage
        try JSONFile.save(job, to: output.appendingPathComponent("meta.json"))

        let logText = (try? String(contentsOf: copiedLog)) ?? ""
        let lines = logText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let errors = lines.filter { line in
            let lower = line.lowercased()
            return lower.contains("error:") || lower.contains("fatal error:") || lower.contains("build failed") || lower.contains("linker command failed")
        }
        let warnings = lines.filter { $0.lowercased().contains("warning:") }
        try errors.joined(separator: "\n").write(to: output.appendingPathComponent("errors.txt"), atomically: true, encoding: .utf8)
        try warnings.joined(separator: "\n").write(to: output.appendingPathComponent("warnings.txt"), atomically: true, encoding: .utf8)

        let summary = """
        DriftBuild summary
        jobId: \(job.id)
        status: \(finalStatus.rawValue)
        repo: \(job.request.repo)
        branch: \(job.request.branch)
        commit: \(job.request.commit ?? "")
        scheme: \(job.request.scheme)
        configuration: \(job.request.configuration)
        exitCode: \(exitCode.map { String($0) } ?? "")
        error: \(errorMessage ?? "")

        errors:
        \(errors.prefix(50).joined(separator: "\n"))

        warnings:
        \(warnings.prefix(50).joined(separator: "\n"))
        """
        try summary.write(to: output.appendingPathComponent("summary.txt"), atomically: true, encoding: .utf8)

        let artifact = store.artifactURL(jobId)
        if FileManager.default.fileExists(atPath: artifact.path) {
            try FileManager.default.removeItem(at: artifact)
        }
        let parent = output.deletingLastPathComponent()
        let ditto = findExecutable("ditto") ?? "/usr/bin/ditto"
        let result = try runner.run(
            executable: ditto,
            arguments: ["-c", "-k", "--sequesterRsrc", "--keepParent", output.lastPathComponent, artifact.path],
            workingDirectory: parent,
            timeout: 300,
            onStart: { _ in },
            onOutput: { [weak self] data in self?.store.appendLogData(jobId: jobId, data) },
            shouldCancel: { false }
        )
        if result.exitCode != 0 {
            let zip = findExecutable("zip") ?? "/usr/bin/zip"
            let fallback = try runner.run(
                executable: zip,
                arguments: ["-qry", artifact.path, output.lastPathComponent],
                workingDirectory: parent,
                timeout: 300,
                onStart: { _ in },
                onOutput: { [weak self] data in self?.store.appendLogData(jobId: jobId, data) },
                shouldCancel: { false }
            )
            guard fallback.exitCode == 0 else {
                throw BuildRunError.commandFailed("zip", fallback.exitCode)
            }
        }
    }

    private func setActive(_ process: Process, jobId: String) {
        lock.lock()
        activeProcesses[jobId] = process
        lock.unlock()
    }

    private func clearActive(jobId: String) {
        lock.lock()
        activeProcesses.removeValue(forKey: jobId)
        lock.unlock()
    }

    private func clear(jobId: String) {
        lock.lock()
        activeProcesses.removeValue(forKey: jobId)
        canceledJobs.remove(jobId)
        lock.unlock()
    }

    private func isCanceled(jobId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return canceledJobs.contains(jobId)
    }
}

final class BuildQueue {
    private let maxConcurrent: Int
    private let store: ServerStateStore
    private let worker: BuildWorker
    private let lock = NSLock()
    private var pending: [String] = []
    private var running: [String: BuildRequest] = [:]

    init(maxConcurrent: Int, store: ServerStateStore, worker: BuildWorker) {
        self.maxConcurrent = max(1, maxConcurrent)
        self.store = store
        self.worker = worker
    }

    func enqueue(_ job: JobRecord) {
        lock.lock()
        pending.append(job.id)
        lock.unlock()
        drain()
    }

    func cancel(jobId: String) throws -> JobRecord {
        var wasPending = false
        var wasRunning = false
        lock.lock()
        if let index = pending.firstIndex(of: jobId) {
            pending.remove(at: index)
            wasPending = true
        }
        wasRunning = running[jobId] != nil
        lock.unlock()

        if wasRunning {
            worker.cancel(jobId: jobId)
        }
        if wasPending || wasRunning {
            return try store.mutateJob(id: jobId) { job in
                job.status = .canceled
                job.stage = "canceled"
                job.finishedAt = Date()
            }
        }
        return try store.job(id: jobId)
    }

    private func drain() {
        while true {
            var selected: String?
            lock.lock()
            if running.count < maxConcurrent {
                let runningRepos = Set(running.values.map(\.repo))
                if let index = pending.firstIndex(where: { id in
                    guard let job = try? store.job(id: id) else { return false }
                    return !runningRepos.contains(job.request.repo)
                }) {
                    selected = pending.remove(at: index)
                    if let selected, let job = try? store.job(id: selected) {
                        running[selected] = job.request
                    }
                }
            }
            lock.unlock()

            guard let jobId = selected else { return }
            Task.detached { [weak self] in
                self?.worker.run(jobId: jobId)
                self?.finish(jobId: jobId)
            }
        }
    }

    private func finish(jobId: String) {
        lock.lock()
        running.removeValue(forKey: jobId)
        lock.unlock()
        drain()
    }
}

struct TokenAuthMiddleware: AsyncMiddleware {
    let store: ServerStateStore

    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        guard let token = request.headers.bearerAuthorization?.token else {
            throw Abort(.unauthorized, reason: "Missing bearer token")
        }
        guard try store.isAuthorized(token: token) else {
            throw Abort(.unauthorized, reason: "Invalid bearer token")
        }
        return try await next.respond(to: request)
    }
}

func configureRoutes(app: Application, store: ServerStateStore, queue: BuildQueue, serverInfo: ServerInfo, autoApprovePairing: Bool) throws {
    let api = app.grouped("api")
    api.get("health") { _ -> ServerInfo in
        serverInfo
    }
    api.post("auth", "pairings") { request async throws -> PairingCreatedResponse in
        let body = try request.content.decode(PairingRequest.self)
        return try store.createPairing(body, autoApprove: autoApprovePairing)
    }
    api.get("auth", "pairings", ":id") { request async throws -> PairingStatusResponse in
        guard let id = request.parameters.get("id") else {
            throw Abort(.badRequest, reason: "Missing pairing id")
        }
        return try store.pairingStatus(id: id)
    }

    let protected = api.grouped(TokenAuthMiddleware(store: store))
    protected.post("builds") { request async throws -> BuildCreatedResponse in
        let body = try request.content.decode(BuildRequest.self)
        guard RepoValidator.isValid(body.repo) else {
            throw Abort(.badRequest, reason: "Invalid repo URL")
        }
        guard !body.scheme.isEmpty else {
            throw Abort(.badRequest, reason: "scheme is required")
        }
        let job = try store.createJob(body)
        queue.enqueue(job)
        return BuildCreatedResponse(jobId: job.id, status: job.status)
    }
    protected.get("builds", ":id") { request async throws -> JobRecord in
        guard let id = request.parameters.get("id") else {
            throw Abort(.badRequest, reason: "Missing job id")
        }
        return try store.job(id: id)
    }
    protected.get("builds", ":id", "logs") { request async throws -> LogChunkResponse in
        guard let id = request.parameters.get("id") else {
            throw Abort(.badRequest, reason: "Missing job id")
        }
        let offset = (try? request.query.get(UInt64.self, at: "offset")) ?? 0
        return try store.readLog(jobId: id, offset: offset)
    }
    protected.get("builds", ":id", "artifact") { request async throws -> Response in
        guard let id = request.parameters.get("id") else {
            throw Abort(.badRequest, reason: "Missing job id")
        }
        let url = store.artifactURL(id)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw Abort(.notFound, reason: "Artifact not ready")
        }
        let response = request.fileio.streamFile(at: url.path)
        response.headers.contentType = HTTPMediaType(type: "application", subType: "zip")
        return response
    }
    protected.post("builds", ":id", "cancel") { request async throws -> CancelResponse in
        guard let id = request.parameters.get("id") else {
            throw Abort(.badRequest, reason: "Missing job id")
        }
        let job = try queue.cancel(jobId: id)
        return CancelResponse(jobId: job.id, status: job.status)
    }
    protected.delete("builds", ":id") { request async throws -> CancelResponse in
        guard let id = request.parameters.get("id") else {
            throw Abort(.badRequest, reason: "Missing job id")
        }
        let job = try queue.cancel(jobId: id)
        return CancelResponse(jobId: job.id, status: job.status)
    }
}

final class BonjourPublisher {
    private let info: ServerInfo
    private var service: NetService?

    init(info: ServerInfo) {
        self.info = info
    }

    func start() {
        let service = NetService(domain: "local.", type: DriftVersion.bonjourType, name: "DriftBuild-\(info.name)", port: Int32(info.port))
        let txt: [String: Data] = [
            "id": Data(info.id.utf8),
            "name": Data(info.name.utf8),
            "host": Data(info.host.utf8),
            "url": Data(info.url.utf8),
            "version": Data(info.version.utf8),
            "xcode": Data(info.xcode.utf8),
            "maxJobs": Data(String(info.maxJobs).utf8)
        ]
        service.setTXTRecord(NetService.data(fromTXTRecord: txt))
        service.publish()
        self.service = service
    }
}

final class UDPDiscoveryResponder {
    private let info: ServerInfo
    private let queue = DispatchQueue(label: "driftbuild.udp.discovery")
    private var fd: Int32 = -1

    init(info: ServerInfo) {
        self.info = info
    }

    func start() {
        queue.async { [weak self] in
            self?.run()
        }
    }

    private func run() {
        fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return }
        var enabled: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &enabled, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(DriftVersion.udpPort).bigEndian
        address.sin_addr.s_addr = INADDR_ANY
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                bind(fd, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { return }

        while true {
            var from = sockaddr_in()
            var fromLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            var buffer = [UInt8](repeating: 0, count: 1024)
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                withUnsafeMutablePointer(to: &from) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                        recvfrom(fd, rawBuffer.baseAddress, rawBuffer.count, 0, socketAddress, &fromLength)
                    }
                }
            }
            guard count > 0 else { continue }
            let message = String(decoding: buffer.prefix(count), as: UTF8.self)
            guard message == DriftVersion.udpProbe, let data = try? JSONEncoder().encode(info) else { continue }
            data.withUnsafeBytes { rawBuffer in
                withUnsafePointer(to: &from) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                        _ = sendto(fd, rawBuffer.baseAddress, rawBuffer.count, 0, socketAddress, fromLength)
                    }
                }
            }
        }
    }

    deinit {
        if fd >= 0 {
            close(fd)
        }
    }
}

func runServer(
    host: String,
    port: Int,
    dataDir: String?,
    name: String?,
    publicURL: String?,
    concurrency: Int,
    autoApprovePairing: Bool
) throws {
    var environment = try Environment.detect()
    let app = Application(environment)
    defer { app.shutdown() }

    let serverName = name ?? Host.current().localizedName ?? "drift-server"
    let advertisedHost = host == "0.0.0.0" ? (Host.current().localizedName ?? "localhost") : host
    let advertisedURL = normalizeURL(publicURL ?? "http://\(advertisedHost):\(port)")
    let root = dataDir.map(expandPath) ?? DriftPaths.defaultServerRoot
    let store = try ServerStateStore(root: root, serverName: serverName, serverURL: advertisedURL)
    let worker = BuildWorker(store: store)
    let queue = BuildQueue(maxConcurrent: concurrency, store: store, worker: worker)
    let serverInfo = ServerInfo(
        id: RepoHasher.shortHash(advertisedURL),
        name: serverName,
        host: advertisedHost,
        port: port,
        url: advertisedURL,
        version: DriftVersion.current,
        xcode: xcodeVersion(),
        maxJobs: max(1, concurrency)
    )

    app.http.server.configuration.hostname = host
    app.http.server.configuration.port = port
    try configureRoutes(app: app, store: store, queue: queue, serverInfo: serverInfo, autoApprovePairing: autoApprovePairing)

    let bonjour = BonjourPublisher(info: serverInfo)
    let udp = UDPDiscoveryResponder(info: serverInfo)
    bonjour.start()
    udp.start()

    print("drift-server \(DriftVersion.current) listening on \(host):\(port)")
    print("data: \(root.path)")
    try app.run()
    _ = bonjour
    _ = udp
}

func findExecutable(_ name: String) -> String? {
    let pathDirectories = (ProcessInfo.processInfo.environment["PATH"] ?? "")
        .split(separator: ":")
        .map(String.init)
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let fallbackDirectories = [
        "/Applications/Codex.app/Contents/Resources",
        "\(home)/.opencode/bin",
        "\(home)/.local/bin",
        "\(home)/.npm-global/bin",
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin"
    ]
    var seen = Set<String>()
    for directory in pathDirectories + fallbackDirectories where seen.insert(directory).inserted {
        let path = "\(directory)/\(name)"
        if FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
    }
    return nil
}

func requireExecutable(_ name: String) throws -> String {
    if let path = findExecutable(name) {
        return path
    }
    throw BuildRunError.message("\(name) not found in PATH or DriftBuild's fallback executable directories")
}

func expandPath(_ path: String) -> URL {
    if path == "~" {
        return FileManager.default.homeDirectoryForCurrentUser
    }
    if path.hasPrefix("~/") {
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(String(path.dropFirst(2)))
    }
    return URL(fileURLWithPath: path, isDirectory: true)
}

func normalizeURL(_ value: String) -> String {
    var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
    while text.hasSuffix("/") {
        text.removeLast()
    }
    return text
}

func xcodeVersion() -> String {
    guard let xcodebuild = findExecutable("xcodebuild") else {
        return "xcodebuild not found"
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: xcodebuild)
    process.arguments = ["-version"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do {
        try process.run()
        process.waitUntilExit()
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return text.split(separator: "\n").first.map(String.init) ?? "unknown"
    } catch {
        return "xcodebuild not available"
    }
}

DriftServerCommand.main()
