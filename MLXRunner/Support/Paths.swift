import Foundation

enum Paths {
    static let home = URL(fileURLWithPath: NSHomeDirectory())

    static var appSupport: URL {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MLXRunner", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    static var engines: URL {
        let u = appSupport.appendingPathComponent("Engines", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    static var results: URL { appSupport.appendingPathComponent("results.json") }
    static var customEngines: URL { appSupport.appendingPathComponent("custom-engines.json") }

    static var defaultModels: URL { home.appendingPathComponent("MLXRunner/Models", isDirectory: true) }

    static var modelsDir: URL {
        if let s = UserDefaults.standard.string(forKey: "modelsDir"), !s.isEmpty {
            return URL(fileURLWithPath: Shell.expand(s), isDirectory: true)
        }
        return defaultModels
    }

    static var huggingFaceHub: URL {
        if let hf = ProcessInfo.processInfo.environment["HF_HUB_CACHE"] { return URL(fileURLWithPath: hf) }
        if let hf = ProcessInfo.processInfo.environment["HF_HOME"] {
            return URL(fileURLWithPath: hf).appendingPathComponent("hub")
        }
        return home.appendingPathComponent(".cache/huggingface/hub")
    }

    static var lmStudioModels: URL { home.appendingPathComponent(".lmstudio/models") }
    static var mlxServeModels: URL { home.appendingPathComponent(".mlx-serve/models") }

    static var huggingFaceToken: String? {
        if let t = UserDefaults.standard.string(forKey: "hfToken"), !t.isEmpty { return t }
        let f = home.appendingPathComponent(".cache/huggingface/token")
        if let t = try? String(contentsOf: f, encoding: .utf8) {
            let s = t.trimmingCharacters(in: .whitespacesAndNewlines)
            return s.isEmpty ? nil : s
        }
        return nil
    }
}

extension Double {
    func fmt(_ digits: Int = 1) -> String { String(format: "%.\(digits)f", self) }
}

extension Int64 {
    var gb: Double { Double(self) / 1_000_000_000 }
}

extension String {
    /// The path with the home folder shown as `~`, for display.
    var tildePath: String { (self as NSString).abbreviatingWithTildeInPath }
}
