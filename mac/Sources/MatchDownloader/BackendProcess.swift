import Foundation
import MatchCore
import Darwin

struct BackendConfiguration: Sendable {
    let root: URL
    let data: URL
    let port: Int

    init(arguments: [String] = CommandLine.arguments, environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        func argument(_ name: String) -> String? {
            guard let i = arguments.firstIndex(of: name), arguments.indices.contains(i + 1) else { return nil }
            return arguments[i + 1]
        }
        var candidate = URL(fileURLWithPath: argument("--root") ?? environment["MATCH_DOWNLOADER_ROOT"] ?? Bundle.main.bundleURL.deletingLastPathComponent().path)
        if !FileManager.default.fileExists(atPath: candidate.appendingPathComponent("app.py").path) {
            candidate = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            while candidate.path != "/", !FileManager.default.fileExists(atPath: candidate.appendingPathComponent("app.py").path) { candidate.deleteLastPathComponent() }
        }
        guard FileManager.default.fileExists(atPath: candidate.appendingPathComponent("app.py").path) else {
            throw APIError.badResponse("Keep Match Downloader.app beside app.py and .venv, then reopen it.")
        }
        root = candidate
        data = URL(fileURLWithPath: argument("--data") ?? environment["MATCH_DOWNLOADER_DATA"] ?? candidate.appendingPathComponent("library").path).standardizedFileURL
        port = Int(argument("--port") ?? environment["MATCH_DOWNLOADER_PORT"] ?? "8766") ?? 8766
        guard (1...65535).contains(port) else { throw APIError.badResponse("Use a port between 1 and 65535.") }
    }
    var client: APIClient {
        let directory = data
        return APIClient(baseURL: URL(string: "http://127.0.0.1:\(port)")!) { _ in
            guard let token = SessionToken.read(dataDirectory: directory) else {
                throw APIError.badResponse("The engine’s session token is missing. Quit the old copy and reopen Match Downloader.")
            }
            return token
        }
    }
}

/// Mac-only process ownership: never terminates a server this app merely attached to.
@MainActor
final class BackendProcess {
    /// The engine version this app needs (`API_VERSION` in app.py).
    static let engineAPI = 3
    let configuration: BackendConfiguration
    private(set) var process: Process?
    private var log: FileHandle?
    init(configuration: BackendConfiguration) { self.configuration = configuration }

    func start() async throws {
        if let health = try? await configuration.client.health() {
            try validate(health)
            // Confirm the configured library is the one served on this port before any writes.
            let library = try await configuration.client.library()
            guard URL(fileURLWithPath: library.storage).standardizedFileURL == configuration.data else {
                throw APIError.badResponse("This port belongs to another library. Choose a different port or reopen the app with that library.")
            }
            guard SessionToken.read(dataDirectory: configuration.data) != nil else {
                throw APIError.badResponse("Quit the old copy and reopen Match Downloader to create a session token.")
            }
            // An engine left finishing downloads after the last quit should stay for this session.
            _ = try? await configuration.client.quitWhenIdle(false)
            return
        }
        guard !FileManager.default.fileExists(atPath: SessionToken.fileURL(dataDirectory: configuration.data).path) else {
            throw APIError.badResponse("This library has an engine session on another port or a stale session token. Quit the other engine before reopening this library.")
        }
        try FileManager.default.createDirectory(at: configuration.data, withIntermediateDirectories: true)
        let logURL = configuration.data.appendingPathComponent("desktop.log")
        if !FileManager.default.fileExists(atPath: logURL.path) { FileManager.default.createFile(atPath: logURL.path, contents: nil) }
        log = try FileHandle(forWritingTo: logURL); try log?.seekToEnd()
        let p = Process()
        p.executableURL = configuration.root.appendingPathComponent(".venv/bin/python")
        p.arguments = [configuration.root.appendingPathComponent("app.py").path, "--port", String(configuration.port), "--no-browser"]
        p.currentDirectoryURL = configuration.root
        var env = ProcessInfo.processInfo.environment
        env["MATCH_DOWNLOADER_DATA"] = configuration.data.path
        env["MATCH_DOWNLOADER_MANAGED"] = "1"
        // Settings → General → Downloads at Once; an environment variable set by hand still wins.
        if env["MATCH_DOWNLOADER_PARALLEL"] == nil, let parallel = EngineSettings.parallel() { env["MATCH_DOWNLOADER_PARALLEL"] = String(parallel) }
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        p.environment = env; p.standardOutput = log; p.standardError = log
        try p.run(); process = p
        do {
            for _ in 0..<100 {
                try Task.checkCancellation()
                guard p.isRunning else { throw APIError.unreachable("The engine stopped. Check desktop.log in your library, then reopen the app.") }
                if let health = try? await configuration.client.health() {
                    try validate(health)
                    let library = try await configuration.client.library()
                    guard URL(fileURLWithPath: library.storage).standardizedFileURL == configuration.data else {
                        throw APIError.badResponse("Another library is using this port.")
                    }
                    if SessionToken.read(dataDirectory: configuration.data) != nil { return }
                }
                try await Task.sleep(for: .milliseconds(200))
            }
            throw APIError.unreachable("The engine took too long to start. Check desktop.log in your library.")
        } catch { stop(); throw error }
    }
    private func validate(_ health: Health) throws {
        guard health.app == "Match Downloader" else {
            throw APIError.badResponse("Another app is using this port. Quit it and reopen Match Downloader.")
        }
        guard health.api == Self.engineAPI else {
            let command = "pkill -f \"app.py --port \(configuration.port)\""
            throw APIError.badResponse("An older Match Downloader engine is still running in the background. Stop it, then reopen the app. In Terminal: \(command)")
        }
    }
    /// Quit with downloads still running: leave the engine going. It exits by itself when they finish.
    func releaseEngine() {
        process = nil
        try? log?.close(); log = nil
    }
    func stop() {
        if let p = process, p.isRunning {
            p.terminate()
            let deadline = Date().addingTimeInterval(5)
            while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        }
        process = nil
        try? log?.close(); log = nil
    }
}
