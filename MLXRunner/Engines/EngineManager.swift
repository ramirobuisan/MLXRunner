import Foundation
import AppKit

enum HTTP {
    static func json(_ url: URL, token: String? = nil, timeout: TimeInterval = 30) async throws -> Any {
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.setValue("MLXRunner/0.1", forHTTPHeaderField: "User-Agent")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let h = resp as? HTTPURLResponse, !(200..<300).contains(h.statusCode) {
            throw NSError(domain: "HTTP", code: h.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \(h.statusCode) from \(url.host ?? "")"])
        }
        return try JSONSerialization.jsonObject(with: data)
    }
}

@MainActor
final class EngineManager: ObservableObject {
    @Published var specs: [EngineSpec] = []
    @Published var status: [String: EngineStatus] = [:]
    /// Latest version (PyPI / Homebrew) or short commit (Git installs) available upstream.
    @Published var latest: [String: String] = [:]
    @Published var logs: [String: [String]] = [:]
    @Published var uvPath: String?
    @Published var brewPath: String?
    @Published var lastUpdateCheck: Date?
    @Published var isCheckingUpdates = false
    @Published var isInstallingAll = false

    /// Engines currently used by a benchmark or a server; they are never updated or removed while busy.
    var busy: Set<String> = []
    private var timer: Timer?

    init() {
        reloadSpecs()
        lastUpdateCheck = UserDefaults.standard.object(forKey: "lastEngineUpdateCheck") as? Date
    }

    func reloadSpecs() {
        specs = EngineSpec.loadBundled() + EngineSpec.loadCustom()
    }

    func spec(_ id: String) -> EngineSpec? { specs.first { $0.id == id } }

    func isInstalled(_ id: String) -> Bool { status[id]?.isInstalled ?? false }

    // MARK: - Paths

    func engineDir(_ spec: EngineSpec) -> URL { Paths.engines.appendingPathComponent(spec.id, isDirectory: true) }

    /// Each install goes into a fresh "env-<timestamp>" folder; current.txt points at the active one.
    func currentEnvDir(_ spec: EngineSpec) -> URL? {
        let marker = engineDir(spec).appendingPathComponent("current.txt")
        guard let name = try? String(contentsOf: marker, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        let dir = engineDir(spec).appendingPathComponent(name, isDirectory: true)
        return FileManager.default.fileExists(atPath: dir.path) ? dir : nil
    }

    func binDir(_ spec: EngineSpec) -> String? { currentEnvDir(spec)?.appendingPathComponent("bin").path }

    func executable(_ spec: EngineSpec) -> String? {
        if spec.install.kind == "uv" {
            guard let bin = binDir(spec) else { return nil }
            let path = (spec.command.first ?? "").replacingOccurrences(of: "{bin}", with: bin)
            return FileManager.default.isExecutableFile(atPath: path) ? path : nil
        }
        for b in spec.install.binaries ?? [] {
            let p = Shell.expand(b)
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        if let f = spec.install.formula, let w = Shell.which(f) { return w }
        return nil
    }

    // MARK: - Logging

    func log(_ id: String, _ line: String) {
        var l = logs[id, default: []]
        l.append(line)
        if l.count > 3000 { l.removeFirst(l.count - 3000) }
        logs[id] = l
    }

    nonisolated func logger(_ id: String) -> (String) -> Void {
        { line in Task { @MainActor in self.log(id, line) } }
    }

    // MARK: - Status

    func refresh() async {
        uvPath = Shell.which("uv")
        brewPath = Shell.which("brew")
        for s in specs where status[s.id] == nil { status[s.id] = .checking }
        for s in specs {
            if case .working = status[s.id] { continue }
            status[s.id] = await detect(s)
        }
    }

    func detect(_ spec: EngineSpec) async -> EngineStatus {
        guard let exe = executable(spec) else { return .notInstalled }
        switch spec.install.kind {
        case "uv":
            guard let bin = binDir(spec), let pkg = spec.trackedPackage else { return .installed(version: "") }
            let r = await Shell.run("\(bin)/python", ["-c",
                "import importlib.metadata as m; print(m.version('\(pkg)'))"])
            let v = r.status == 0 ? r.output.trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: "\n").last ?? "" : ""
            return .installed(version: v)
        case "brew":
            if let brew = brewPath, let f = spec.install.formula {
                let r = await Shell.run(brew, ["list", "--versions", f])
                let parts = r.output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
                if r.status == 0, parts.count >= 2 { return .installed(version: String(parts.last!)) }
            }
            // Installed some other way (e.g. a release binary): ask the binary itself.
            let r = await Shell.run(exe, ["--version"])
            if let range = r.output.range(of: #"\d+\.\d+(\.\d+)?"#, options: .regularExpression) {
                return .installed(version: String(r.output[range]))
            }
            return .installed(version: "")
        default:
            return .installed(version: "")
        }
    }

    func installedVersion(_ spec: EngineSpec) -> String? {
        if spec.installsFromGit {
            let f = engineDir(spec).appendingPathComponent("git-sha.txt")
            return (try? String(contentsOf: f, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if case .installed(let v) = status[spec.id], !v.isEmpty { return v }
        return nil
    }

    func hasUpdate(_ spec: EngineSpec) -> Bool {
        guard let latest = latest[spec.id], let current = installedVersion(spec) else { return false }
        return latest != current
    }

    // MARK: - Install / update / remove

    private func ensureUV(_ id: String) async -> String? {
        if let uv = Shell.which("uv") { uvPath = uv; return uv }
        log(id, "uv not found, installing it…")
        if let brew = Shell.which("brew") {
            await Shell.run(brew, ["install", "uv"], onLine: logger(id))
        } else {
            await Shell.sh("curl -LsSf https://astral.sh/uv/install.sh | sh", onLine: logger(id))
        }
        uvPath = Shell.which("uv")
        return uvPath
    }

    @discardableResult
    func install(_ spec: EngineSpec, isUpdate: Bool = false) async -> Bool {
        let id = spec.id
        if case .working = status[id] { return false }   // already installing
        if busy.contains(id) {
            log(id, "Engine is in use (benchmark or server running). Try again when it stops.")
            return false
        }
        let previous = status[id]
        status[id] = .working(isUpdate ? "Updating…" : "Installing…")
        log(id, "── \(isUpdate ? "Updating" : "Installing") \(spec.name) · \(Date().formatted()) ──")

        switch spec.install.kind {
        case "uv":
            guard let uv = await ensureUV(id) else {
                status[id] = .failed("uv is missing")
                log(id, "Could not install uv. Install it from https://docs.astral.sh/uv/ and retry.")
                return false
            }
            let fm = FileManager.default
            try? fm.createDirectory(at: engineDir(spec), withIntermediateDirectories: true)
            let stamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "").replacingOccurrences(of: "-", with: "")
            let name = "env-\(stamp)"
            let dir = engineDir(spec).appendingPathComponent(name, isDirectory: true)
            let python = spec.install.python ?? "3.12"
            var r = await Shell.run(uv, ["venv", "--python", python, dir.path], onLine: logger(id))
            if r.status == 0 {
                var args = ["pip", "install", "--python", dir.appendingPathComponent("bin/python").path, "--upgrade"]
                if let c = Bundle.main.url(forResource: "constraints", withExtension: "txt") {
                    args += ["--constraint", c.path]
                }
                r = await Shell.run(uv, args + (spec.install.packages ?? []), onLine: logger(id))
            }
            guard r.status == 0 else {
                try? fm.removeItem(at: dir)
                status[id] = isUpdate ? (previous ?? .notInstalled) : .failed("install error, see log")
                log(id, "✗ Failed (exit \(r.status)). \(isUpdate ? "Kept the previous version." : "")")
                return false
            }
            if spec.installsFromGit, let sha = await latestGitCommit(spec) {
                try? sha.write(to: engineDir(spec).appendingPathComponent("git-sha.txt"), atomically: true, encoding: .utf8)
            }
            try? name.write(to: engineDir(spec).appendingPathComponent("current.txt"), atomically: true, encoding: .utf8)
            // Delete every older environment of this engine.
            let items = (try? fm.contentsOfDirectory(at: engineDir(spec), includingPropertiesForKeys: nil)) ?? []
            for item in items where item.lastPathComponent.hasPrefix("env-") && item.lastPathComponent != name {
                try? fm.removeItem(at: item)
                log(id, "Removed old version \(item.lastPathComponent)")
            }
            // Free disk space from old downloads; don't wait on it (it blocks while other uv processes run).
            Shell.runDetached(uv, ["cache", "prune"], timeout: 120)

        case "brew":
            guard let brew = Shell.which("brew") else {
                status[id] = .failed("Homebrew missing")
                log(id, "Homebrew is required for this engine: https://brew.sh")
                return false
            }
            if let tap = spec.install.tap {
                var args = ["tap", tap]
                if let u = spec.install.tapURL { args.append(u) }
                await Shell.run(brew, args, onLine: logger(id))
                await Shell.run(brew, ["trust", tap], onLine: logger(id))
            }
            let formula = spec.install.formula ?? spec.id
            let r = await Shell.run(brew, [isUpdate ? "upgrade" : "install", formula], onLine: logger(id))
            await Shell.run(brew, ["cleanup", formula], onLine: logger(id))
            if r.status != 0 && executable(spec) == nil {
                status[id] = .failed("brew error, see log")
                return false
            }

        default:
            if let u = spec.install.url, let url = URL(string: u) { NSWorkspace.shared.open(url) }
            log(id, spec.install.note ?? "Install this engine manually, then click Refresh.")
        }
        status[id] = await detect(spec)
        log(id, "✓ \(status[id]?.label ?? "")")
        return status[id]?.isInstalled ?? false
    }

    func uninstall(_ spec: EngineSpec) async {
        let id = spec.id
        guard !busy.contains(id) else { log(id, "Engine is in use."); return }
        switch spec.install.kind {
        case "uv":
            try? FileManager.default.removeItem(at: engineDir(spec))
            log(id, "Removed \(engineDir(spec).path)")
        case "brew":
            if let brew = Shell.which("brew"), let f = spec.install.formula {
                await Shell.run(brew, ["uninstall", f], onLine: logger(id))
            }
        default:
            log(id, "This engine is managed outside MLXRunner. Remove it from its own app.")
        }
        status[id] = await detect(spec)
    }

    // MARK: - Updates

    func latestGitCommit(_ spec: EngineSpec) async -> String? {
        guard let url = URL(string: "https://api.github.com/repos/\(spec.repo)/commits?per_page=1"),
              let arr = try? await HTTP.json(url) as? [[String: Any]],
              let sha = arr.first?["sha"] as? String else { return nil }
        return String(sha.prefix(7))
    }

    func latestVersion(_ spec: EngineSpec) async -> String? {
        switch spec.install.kind {
        case "uv":
            if spec.installsFromGit { return await latestGitCommit(spec) }
            guard let pkg = spec.trackedPackage,
                  let url = URL(string: "https://pypi.org/pypi/\(pkg)/json"),
                  let obj = try? await HTTP.json(url) as? [String: Any],
                  let info = obj["info"] as? [String: Any] else { return nil }
            return info["version"] as? String
        case "brew":
            guard let brew = Shell.which("brew"), let f = spec.install.formula else { return nil }
            let r = await Shell.run(brew, ["info", "--json=v2", f])
            guard r.status == 0,
                  let start = r.output.firstIndex(of: "{"),
                  let data = String(r.output[start...]).data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let formulae = obj["formulae"] as? [[String: Any]],
                  let versions = formulae.first?["versions"] as? [String: Any] else { return nil }
            return versions["stable"] as? String
        default:
            return nil
        }
    }

    /// Checks every installed engine; with autoInstall, installs newer versions and deletes the old ones.
    func checkForUpdates(autoInstall: Bool) async {
        guard !isCheckingUpdates else { return }
        isCheckingUpdates = true
        defer { isCheckingUpdates = false }
        for s in specs where isInstalled(s.id) {
            if let v = await latestVersion(s) { latest[s.id] = v }
        }
        lastUpdateCheck = Date()
        UserDefaults.standard.set(lastUpdateCheck, forKey: "lastEngineUpdateCheck")
        guard autoInstall else { return }
        for s in specs where hasUpdate(s) && !busy.contains(s.id) {
            log(s.id, "Update available: \(installedVersion(s) ?? "?") → \(latest[s.id] ?? "?")")
            await install(s, isUpdate: true)
        }
    }

    var autoUpdateEnabled: Bool {
        UserDefaults.standard.object(forKey: "autoUpdateEngines") as? Bool ?? true
    }

    /// Runs at launch and then hourly; does real work at most once every 24 h.
    func startAutoUpdates() {
        Task { await maybeAutoUpdate() }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.maybeAutoUpdate() }
        }
    }

    private func maybeAutoUpdate() async {
        guard autoUpdateEnabled else { return }
        if let last = lastUpdateCheck, Date().timeIntervalSince(last) < 24 * 3600 { return }
        await checkForUpdates(autoInstall: true)
    }

    func installAll() async {
        guard !isInstallingAll else { return }
        isInstallingAll = true
        defer { isInstallingAll = false }
        for s in specs where !isInstalled(s.id) && s.install.kind == "uv" {
            await install(s)
        }
    }

    // MARK: - Custom engines

    func addCustom(_ spec: EngineSpec) {
        var custom = EngineSpec.loadCustom().filter { $0.id != spec.id }
        var s = spec
        s.custom = true
        custom.append(s)
        EngineSpec.saveCustom(custom)
        reloadSpecs()
        status[s.id] = .notInstalled
    }

    func removeCustom(_ spec: EngineSpec) async {
        await uninstall(spec)
        EngineSpec.saveCustom(EngineSpec.loadCustom().filter { $0.id != spec.id })
        reloadSpecs()
        status[spec.id] = nil
    }
}
