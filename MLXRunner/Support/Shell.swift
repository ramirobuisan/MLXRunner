import Foundation

/// Collects process output, splits it into lines and forwards each line.
final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var textStorage = ""
    private let onLine: ((String) -> Void)?

    init(onLine: ((String) -> Void)?) {
        self.onLine = onLine
    }

    var text: String {
        lock.lock(); defer { lock.unlock() }
        return textStorage
    }

    func feed(_ data: Data) {
        guard !data.isEmpty else { return }
        var lines: [String] = []
        lock.lock()
        buffer.append(data)
        while let idx = buffer.firstIndex(where: { $0 == 10 || $0 == 13 }) {
            let lineData = buffer.subdata(in: buffer.startIndex..<idx)
            buffer.removeSubrange(buffer.startIndex...idx)
            let line = LineCollector.stripANSI(String(decoding: lineData, as: UTF8.self))
            if !line.trimmingCharacters(in: .whitespaces).isEmpty { lines.append(line) }
        }
        for l in lines { textStorage += l + "\n" }
        if textStorage.utf8.count > 400_000 { textStorage = String(textStorage.suffix(200_000)) }
        lock.unlock()
        for l in lines { onLine?(l) }
    }

    /// Removes terminal colour/cursor escape sequences.
    static func stripANSI(_ s: String) -> String {
        guard s.contains("\u{1B}") else { return s }
        return s.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
    }

    func flush() {
        lock.lock()
        let rest = buffer
        buffer.removeAll()
        lock.unlock()
        if !rest.isEmpty { feed(rest + Data([10])) }
    }
}

enum Shell {
    static let home = NSHomeDirectory()

    /// GUI apps start with a minimal PATH; add the usual developer locations.
    static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        let extra = ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin",
                     "\(home)/.local/bin", "\(home)/.lmstudio/bin", "\(home)/.cargo/bin"]
        let current = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = (extra + [current]).joined(separator: ":")
        env["PYTHONUNBUFFERED"] = "1"
        env["HF_HUB_DISABLE_TELEMETRY"] = "1"
        env["DO_NOT_TRACK"] = "1"
        env["RAPID_MLX_TELEMETRY"] = "0"
        env["TERM"] = "dumb"
        env["NO_COLOR"] = "1"
        return env
    }

    static func expand(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    static func which(_ name: String) -> String? {
        if name.hasPrefix("/") { return FileManager.default.isExecutableFile(atPath: name) ? name : nil }
        for dir in (environment["PATH"] ?? "").split(separator: ":") {
            let p = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    private static func makeProcess(_ exe: String, _ args: [String], env extra: [String: String], cwd: URL?) -> Process {
        let p = Process()
        if exe.hasPrefix("/") {
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = args
        } else {
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = [exe] + args
        }
        p.environment = environment.merging(extra) { $1 }
        if let cwd { p.currentDirectoryURL = cwd }
        p.standardInput = FileHandle.nullDevice
        return p
    }

    /// Runs a command to completion. Output lines are forwarded to `onLine` (on a background thread).
    @discardableResult
    static func run(_ exe: String, _ args: [String], env extra: [String: String] = [:], cwd: URL? = nil,
                    onLine: ((String) -> Void)? = nil) async -> (status: Int32, output: String) {
        await withCheckedContinuation { cont in
            let p = makeProcess(exe, args, env: extra, cwd: cwd)
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            let collector = LineCollector(onLine: onLine)
            pipe.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                if d.isEmpty { h.readabilityHandler = nil } else { collector.feed(d) }
            }
            p.terminationHandler = { proc in
                pipe.fileHandleForReading.readabilityHandler = nil
                let rest = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
                collector.feed(rest)
                collector.flush()
                cont.resume(returning: (proc.terminationStatus, collector.text))
            }
            do { try p.run() } catch {
                pipe.fileHandleForReading.readabilityHandler = nil
                cont.resume(returning: (-1, "Could not start \(exe): \(error.localizedDescription)"))
            }
        }
    }

    /// Runs a shell snippet with /bin/zsh -lc semantics (PATH from `environment`).
    @discardableResult
    static func sh(_ script: String, onLine: ((String) -> Void)? = nil) async -> (status: Int32, output: String) {
        await run("/bin/sh", ["-c", script], onLine: onLine)
    }

    /// Fire-and-forget command that is killed if it runs longer than `timeout` seconds.
    static func runDetached(_ exe: String, _ args: [String], timeout: TimeInterval) {
        guard let p = try? spawn(exe, args, onLine: { _ in }, onExit: { _ in }) else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            if p.isRunning { p.terminate() }
        }
    }

    /// Starts a long-running process (servers). Returns immediately.
    static func spawn(_ exe: String, _ args: [String], env extra: [String: String] = [:], cwd: URL? = nil,
                      onLine: @escaping (String) -> Void, onExit: @escaping (Int32) -> Void) throws -> Process {
        let p = makeProcess(exe, args, env: extra, cwd: cwd)
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        let collector = LineCollector(onLine: onLine)
        pipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil } else { collector.feed(d) }
        }
        p.terminationHandler = { proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            collector.flush()
            onExit(proc.terminationStatus)
        }
        try p.run()
        ProcessRegistry.shared.add(p)
        return p
    }

    /// Stops a process and all of its children: SIGTERM, then SIGKILL after a grace period.
    static func terminateTree(_ process: Process, grace: TimeInterval = 8) async {
        let pid = process.processIdentifier
        let tree = SystemInfo.processTree(pid)
        for child in tree.reversed() where child != pid { kill(child, SIGTERM) }
        if process.isRunning { process.terminate() }
        let deadline = Date().addingTimeInterval(grace)
        while process.isRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        for p in tree { kill(p, SIGKILL) }
    }
}

/// Every long-running process MLXRunner started, so they can all be stopped when the app quits.
final class ProcessRegistry: @unchecked Sendable {
    static let shared = ProcessRegistry()
    private let lock = NSLock()
    private var processes: [Process] = []

    func add(_ p: Process) {
        lock.lock(); processes.append(p); lock.unlock()
    }

    /// Synchronously terminates every live process tree (used from applicationWillTerminate).
    func killAll() {
        lock.lock(); let ps = processes.filter { $0.isRunning }; processes = []; lock.unlock()
        for p in ps {
            let tree = SystemInfo.processTree(p.processIdentifier)
            for pid in tree { kill(pid, SIGTERM) }
        }
        if !ps.isEmpty { usleep(1_500_000) }
        for p in ps where p.isRunning {
            for pid in SystemInfo.processTree(p.processIdentifier) { kill(pid, SIGKILL) }
        }
    }
}
