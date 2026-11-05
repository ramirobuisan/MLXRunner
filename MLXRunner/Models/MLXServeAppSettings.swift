import AppKit

/// What the MLX-Serve app has saved in `~/.mlx-serve`: per-model server settings in `model-settings.json`
/// (context, MTP, drafter, KV cache quantization, request defaults) and global request defaults in
/// `generation-settings.json`.
///
/// The mlx-serve binary reads both files itself, also when MLXRunner starts it with `--model`, so a model runs
/// in MLXRunner the same way as in the MLX-Serve app as long as MLXRunner doesn't override them with flags.
struct MLXServeAppSettings {
    struct Row: Hashable {
        let label: String
        let value: String
    }

    /// Server settings saved for this model folder.
    var server: [Row]
    /// Values used when a request leaves them out: the global defaults, then this model's own.
    var defaults: [Row]
    /// Something is saved for this exact model folder, not only global defaults.
    var perModel: Bool

    static let folder = Paths.home.appendingPathComponent(".mlx-serve")
    static let appBundleId = "com.dalcu.mlx-core"

    static var appIsRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: appBundleId).isEmpty
    }

    /// The settings that apply to the model at `modelPath`, or nil if the MLX-Serve app saved none.
    static func load(modelPath: String) -> MLXServeAppSettings? {
        let key = canonical(modelPath)
        let models = json("model-settings.json") ?? [:]
        let entry = models.first { canonical($0.key) == key }?.value as? [String: Any] ?? [:]

        var request: [String: (value: Any, always: Bool)] = [:]
        for (k, v) in json("generation-settings.json") ?? [:] { request[k] = unwrap(v) }
        for (k, v) in entry["generation_defaults"] as? [String: Any] ?? [:] { request[k] = unwrap(v) }

        let server = entry.keys.sorted().filter { $0 != "generation_defaults" }.map { k in
            Row(label: label(k), value: describe(k, entry[k] as Any))
        }
        let defaults = request.keys.sorted().map { k in
            let d = request[k]!
            return Row(label: k, value: describe(k, d.value) + (d.always ? " (overrides requests)" : ""))
        }
        guard !server.isEmpty || !defaults.isEmpty else { return nil }
        return MLXServeAppSettings(server: server, defaults: defaults, perModel: !entry.isEmpty)
    }

    /// One line for logs: "Context 262,144 tokens · MTP on · temperature 0.8".
    var summary: String {
        (server.map { "\($0.label) \($0.value)" } + defaults.map { "\($0.label) \($0.value)" }).joined(separator: " · ")
    }

    // MARK: - Reading

    private static func json(_ name: String) -> [String: Any]? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(name)) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// Request defaults are saved as `{"value": …, "ignore_client": true|false}`; older files may hold the bare value.
    private static func unwrap(_ v: Any) -> (value: Any, always: Bool) {
        if let d = v as? [String: Any], let value = d["value"] {
            return (value, d["ignore_client"] as? Bool ?? false)
        }
        return (v, false)
    }

    private static func label(_ key: String) -> String {
        switch key {
        case "ctx_size": return "Context"
        case "mtp": return "MTP drafting"
        case "drafter": return "Draft model"
        case "kv_quant": return "KV cache quantization"
        case "stream_experts": return "Stream experts from SSD"
        default:
            let s = key.replacingOccurrences(of: "_", with: " ")
            return s.prefix(1).uppercased() + s.dropFirst()
        }
    }

    private static func describe(_ key: String, _ v: Any) -> String {
        if let n = v as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "on" : "off" }
            let d = n.doubleValue
            if d == d.rounded(), abs(d) < 1e15 {
                let i = Int(d)
                return key == "ctx_size" ? "\(i.formatted()) tokens" : "\(i)"
            }
            return String(d)
        }
        if let s = v as? String { return s }
        if JSONSerialization.isValidJSONObject(v),
           let data = try? JSONSerialization.data(withJSONObject: v, options: [.sortedKeys]),
           let s = String(data: data, encoding: .utf8) { return s }
        return "\(v)"
    }
}
