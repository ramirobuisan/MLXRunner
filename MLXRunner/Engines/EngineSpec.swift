import Foundation

struct InstallSpec: Codable, Hashable {
    /// "uv" (Python package in its own environment), "brew" (Homebrew formula) or "external" (installed by the user).
    var kind: String
    var python: String?
    var packages: [String]?
    var tap: String?
    var tapURL: String?
    var formula: String?
    var binaries: [String]?
    var url: String?
    var note: String?
}

struct EngineSpec: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var repo: String
    var summary: String
    var install: InstallSpec
    var versionPackage: String?
    /// Command template. Placeholders: {bin} {exe} {model} {modelParent} {modelName} {modelType} {host} {port} {mtpFlag}
    var command: [String]
    var env: [String: String]?
    /// Value of the "model" field sent in API requests.
    var requestModel: String?
    var visionOnly: Bool?
    var experimental: Bool?
    /// "process" (default) or "lmstudio".
    var lifecycle: String?
    /// Flags that set server-side defaults, keyed by API name: temperature, top_p, top_k, min_p,
    /// presence_penalty, repetition_penalty, max_tokens, template_args (JSON), thinking_on, thinking_off.
    var defaults: [String: String]?
    var custom: Bool?

    var repoURL: URL? { URL(string: "https://github.com/\(repo)") }
    var isLMStudio: Bool { lifecycle == "lmstudio" }

    /// Package whose version we report and compare against PyPI.
    var trackedPackage: String? {
        if let v = versionPackage { return v }
        guard let first = install.packages?.first else { return nil }
        if first.hasPrefix("git+") { return repo.split(separator: "/").last.map(String.init)?.lowercased() }
        return first
    }

    /// True when the engine is installed from a Git URL (updates are tracked by commit).
    var installsFromGit: Bool { install.packages?.contains { $0.hasPrefix("git+") } ?? false }

    static func loadBundled() -> [EngineSpec] {
        guard let url = Bundle.main.url(forResource: "engines", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let specs = try? JSONDecoder().decode([EngineSpec].self, from: data) else { return [] }
        return specs
    }

    static func loadCustom() -> [EngineSpec] {
        guard let data = try? Data(contentsOf: Paths.customEngines),
              let specs = try? JSONDecoder().decode([EngineSpec].self, from: data) else { return [] }
        return specs.map { var s = $0; s.custom = true; return s }
    }

    static func saveCustom(_ specs: [EngineSpec]) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(specs) { try? data.write(to: Paths.customEngines) }
    }
}

enum EngineStatus: Equatable {
    case checking
    case notInstalled
    case working(String)
    case installed(version: String)
    case failed(String)

    var isInstalled: Bool {
        if case .installed = self { return true }
        return false
    }

    var label: String {
        switch self {
        case .checking: return "Checking…"
        case .notInstalled: return "Not installed"
        case .working(let s): return s
        case .installed(let v): return v.isEmpty ? "Installed" : "v\(v)"
        case .failed(let e): return "Failed: \(e)"
        }
    }
}
