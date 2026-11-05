import Foundation

/// A running OpenAI-compatible server started by MLXRunner.
final class LaunchedServer: Identifiable, @unchecked Sendable {
    let id = UUID()
    let spec: EngineSpec
    let model: LocalModel
    let host: String
    let port: Int
    let requestModel: String
    let process: Process?
    let lmsIdentifier: String?
    /// True when MLXRunner started LM Studio's server (so it stops it again afterwards).
    let lmsStartedServer: Bool
    let startedAt = Date()

    init(spec: EngineSpec, model: LocalModel, host: String, port: Int, requestModel: String,
         process: Process?, lmsIdentifier: String?, lmsStartedServer: Bool = false) {
        self.spec = spec; self.model = model; self.host = host; self.port = port
        self.requestModel = requestModel; self.process = process; self.lmsIdentifier = lmsIdentifier
        self.lmsStartedServer = lmsStartedServer
    }

    /// Base URL to reach the server from this Mac.
    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }
    var openAIBase: String { "http://\(host == "0.0.0.0" ? "localhost" : host):\(port)/v1" }
    var pid: pid_t? { process?.processIdentifier }
    var isAlive: Bool { process?.isRunning ?? true }
}

enum LaunchError: LocalizedError {
    case notInstalled(String)
    case unsupported(String)
    case exited(String)
    case timeout(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled(let s): return "\(s) is not installed"
        case .unsupported(let s): return s
        case .exited(let s): return "Server exited: \(s)"
        case .timeout(let s): return "Server did not become ready: \(s)"
        }
    }
}

@MainActor
enum EngineLauncher {
    /// Why an engine can't run a model, or nil when it can.
    static func incompatibility(_ spec: EngineSpec, _ model: LocalModel) -> String? {
        if spec.visionOnly == true && !model.vision { return "\(spec.name) only runs vision models" }
        if spec.isLMStudio && model.lmstudioRelPath == nil {
            return "LM Studio can only run models inside ~/.lmstudio/models"
        }
        return nil
    }

    static func variables(_ spec: EngineSpec, exe: String, bin: String, model: LocalModel,
                          host: String, port: Int) -> [String: String] {
        let url = URL(fileURLWithPath: model.path)
        return [
            "{bin}": bin, "{exe}": exe, "{model}": model.path,
            "{modelParent}": url.deletingLastPathComponent().path,
            "{modelName}": url.lastPathComponent,
            "{repoId}": model.repoId ?? url.lastPathComponent,
            "{modelType}": model.vision ? "multimodal" : "lm",
            "{mtpFlag}": model.hasMTP ? "" : "--no-mtp",
            "{host}": host, "{port}": String(port),
        ]
    }

    static func substitute(_ s: String, _ vars: [String: String]) -> String {
        vars.reduce(s) { $0.replacingOccurrences(of: $1.key, with: $1.value) }
    }

    static func launch(_ spec: EngineSpec, manager: EngineManager, model: LocalModel, host: String = "127.0.0.1",
                       port: Int, extraArgs: [String] = [], readyTimeout: TimeInterval = 900,
                       onLine: @escaping (String) -> Void) async throws -> LaunchedServer {
        if let why = incompatibility(spec, model) { throw LaunchError.unsupported(why) }
        guard let exe = manager.executable(spec) else { throw LaunchError.notInstalled(spec.name) }
        let vars = variables(spec, exe: exe, bin: manager.binDir(spec) ?? "", model: model, host: host, port: port)

        if spec.isLMStudio {
            return try await launchLMStudio(spec, lms: exe, model: model, host: host, port: port, onLine: onLine)
        }

        var parts = spec.command.map { substitute($0, vars) }.filter { !$0.isEmpty }
        parts += extraArgs
        let program = parts.removeFirst()
        var env: [String: String] = [:]
        if spec.install.kind == "uv", let bin = manager.binDir(spec) {
            // Behave like an activated virtualenv: some servers pip-install extras at startup.
            env["VIRTUAL_ENV"] = URL(fileURLWithPath: bin).deletingLastPathComponent().path
            env["PATH"] = bin + ":" + (Shell.environment["PATH"] ?? "")
        }
        for (k, v) in spec.env ?? [:] { env[k] = substitute(v, vars) }
        onLine("$ \(program) \(parts.joined(separator: " "))")

        let exitBox = ExitBox()
        // Run from a writable working folder: some servers write logs/caches relative to the cwd.
        let workDir = Paths.appSupport.appendingPathComponent("Run/\(spec.id)", isDirectory: true)
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        let process = try Shell.spawn(program, parts, env: env, cwd: workDir, onLine: { line in
            exitBox.append(line)
            onLine(line)
        }, onExit: { code in exitBox.code = code })

        let server = LaunchedServer(spec: spec, model: model, host: host, port: port,
                                    requestModel: substitute(spec.requestModel ?? "{model}", vars),
                                    process: process, lmsIdentifier: nil)
        do {
            try await waitReady(server, timeout: readyTimeout, exitBox: exitBox)
        } catch {
            await Shell.terminateTree(process, grace: 3)
            throw error
        }
        return server
    }

    private static func launchLMStudio(_ spec: EngineSpec, lms: String, model: LocalModel, host: String, port: Int,
                                       onLine: @escaping (String) -> Void) async throws -> LaunchedServer {
        let rel = model.lmstudioRelPath ?? model.path
        // Resolve LM Studio's model key for this folder.
        var key = rel
        let ls = await Shell.run(lms, ["ls", "--json"])
        if let start = ls.output.firstIndex(of: "["),
           let data = String(ls.output[start...]).data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            func norm(_ s: String) -> String {
                (s.split(separator: "/").last.map(String.init) ?? s).lowercased()
            }
            let relName = norm(rel)
            let exact = arr.first { ($0["path"] as? String) == rel || ($0["indexedModelIdentifier"] as? String) == rel }
            // LM Studio sometimes indexes a folder under a shorter catalog name (e.g. qwen/qwen3-vl-30b).
            let fuzzy = arr.first { e in
                guard e["format"] as? String != "gguf", let p = e["path"] as? String else { return false }
                let n = norm(p)
                return !n.isEmpty && (relName.hasPrefix(n) || n.hasPrefix(relName))
            }
            if let k = (exact ?? fuzzy)?["modelKey"] as? String { key = k }
        }
        // LM Studio has a single server. Reuse it if it is running; otherwise start it on its usual port
        // (no --port flag, so the user's LM Studio settings are left untouched) and stop it afterwards.
        func serverPort() async -> Int? {
            let st = await Shell.run(lms, ["server", "status", "--json"])
            guard let start = st.output.firstIndex(of: "{"),
                  let data = String(st.output[start...]).data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  obj["running"] as? Bool == true else { return nil }
            return (obj["port"] as? NSNumber)?.intValue
        }
        var lmsPort = await serverPort()
        let startedServer = lmsPort == nil
        if startedServer {
            onLine("$ lms server start")
            await Shell.run(lms, ["server", "start"], onLine: onLine)
            lmsPort = await serverPort()
        }
        guard let activePort = lmsPort else { throw LaunchError.exited("LM Studio server did not start") }
        let ident = "mlxrunner-\(UUID().uuidString.prefix(6).lowercased())"
        onLine("$ lms load \(key) --identifier \(ident) -y")
        // `lms load` redraws a progress spinner many times per second; only forward real messages.
        let r = await Shell.run(lms, ["load", key, "--identifier", ident, "-y"], onLine: { line in
            if !line.hasPrefix("Loading ") { onLine(line) }
        })
        if r.status != 0 {
            if startedServer { await Shell.run(lms, ["server", "stop"]) }
            throw LaunchError.exited("lms load failed (exit \(r.status))")
        }
        let server = LaunchedServer(spec: spec, model: model, host: "127.0.0.1", port: activePort, requestModel: ident,
                                    process: nil, lmsIdentifier: ident, lmsStartedServer: startedServer)
        try await waitReady(server, timeout: 120, exitBox: ExitBox())
        return server
    }

    /// Waits until the HTTP server answers. Any HTTP response counts: some servers load the model lazily
    /// on the first request, which the benchmark measures as load time.
    static func waitReady(_ server: LaunchedServer, timeout: TimeInterval, exitBox: ExitBox) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        let url = server.baseURL.appendingPathComponent("v1/models")
        while Date() < deadline {
            try Task.checkCancellation()
            if let code = exitBox.code {
                throw LaunchError.exited("exit code \(code). Last output:\n\(exitBox.tail)")
            }
            var req = URLRequest(url: url, timeoutInterval: 2)
            req.httpMethod = "GET"
            if let (_, resp) = try? await URLSession.shared.data(for: req), resp is HTTPURLResponse {
                return
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw LaunchError.timeout("no answer on port \(server.port) after \(Int(timeout)) s")
    }

    static func stop(_ server: LaunchedServer, onLine: ((String) -> Void)? = nil) async {
        if let ident = server.lmsIdentifier, let lms = Shell.which("lms") {
            await Shell.run(lms, ["unload", ident], onLine: onLine)
            if server.lmsStartedServer { await Shell.run(lms, ["server", "stop"], onLine: onLine) }
        }
        if let p = server.process {
            await Shell.terminateTree(p)
        }
    }
}

/// Tracks a spawned process' exit code and last lines of output.
final class ExitBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _code: Int32?
    private var lines: [String] = []

    var code: Int32? {
        get { lock.lock(); defer { lock.unlock() }; return _code }
        set { lock.lock(); _code = newValue; lock.unlock() }
    }

    func append(_ line: String) {
        lock.lock()
        lines.append(line)
        if lines.count > 30 { lines.removeFirst(lines.count - 30) }
        lock.unlock()
    }

    var tail: String {
        lock.lock(); defer { lock.unlock() }
        return lines.suffix(12).joined(separator: "\n")
    }
}
