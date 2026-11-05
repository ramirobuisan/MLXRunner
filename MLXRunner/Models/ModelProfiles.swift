import Foundation

/// Sampling parameters, named as in the OpenAI-compatible API.
struct Sampling: Codable, Hashable {
    var temperature: Double?
    var top_p: Double?
    var top_k: Int?
    var min_p: Double?
    var presence_penalty: Double?
    var repetition_penalty: Double?

    var isEmpty: Bool { fields.isEmpty }

    /// Values of `other` win where set.
    func merged(with other: Sampling?) -> Sampling {
        guard let o = other else { return self }
        return Sampling(temperature: o.temperature ?? temperature, top_p: o.top_p ?? top_p, top_k: o.top_k ?? top_k,
                        min_p: o.min_p ?? min_p, presence_penalty: o.presence_penalty ?? presence_penalty,
                        repetition_penalty: o.repetition_penalty ?? repetition_penalty)
    }

    /// (API name, value) pairs in a stable order.
    var fields: [(String, Any)] {
        var f: [(String, Any)] = []
        if let v = temperature { f.append(("temperature", v)) }
        if let v = top_p { f.append(("top_p", v)) }
        if let v = top_k { f.append(("top_k", v)) }
        if let v = min_p { f.append(("min_p", v)) }
        if let v = presence_penalty { f.append(("presence_penalty", v)) }
        if let v = repetition_penalty { f.append(("repetition_penalty", v)) }
        return f
    }

    /// Fields every OpenAI-compatible server accepts; the others are extensions some servers reject.
    static let standardFields: Set<String> = ["temperature", "top_p", "presence_penalty"]

    var summary: String {
        fields.map { "\($0.0) \(Sampling.format($0.1))" }.joined(separator: " · ")
    }

    static func format(_ v: Any) -> String {
        if let d = v as? Double {
            return d == d.rounded() ? String(format: "%.1f", d) : String(d)
        }
        return "\(v)"
    }
}

/// What a model needs from one engine.
struct EngineHint: Codable, Hashable {
    var args: [String]?
    var minVersion: String?
    var unsupported: String?
    var note: String?

    func merged(with o: EngineHint) -> EngineHint {
        EngineHint(args: o.args ?? args, minVersion: o.minVersion ?? minVersion,
                   unsupported: o.unsupported ?? unsupported, note: o.note ?? note)
    }
}

/// Recommended settings for a family of models or one repository, taken from the model cards.
/// Bundled in `model-profiles.json`; extra profiles can go in Application Support/MLXRunner/model-profiles.json.
struct ModelProfile: Codable, Identifiable {
    var id: String
    var name: String
    /// Profiles are applied from low to high priority; later ones win.
    var priority: Int?
    /// Exact repository ids (case-insensitive).
    var repos: [String]?
    /// Substrings of the repository id or folder name (case-insensitive).
    var nameContains: [String]?
    /// `model_type` values from config.json.
    var modelTypes: [String]?
    /// Model card the settings come from.
    var source: String?
    var thinkingByDefault: Bool?
    var thinking: Sampling?
    var instruct: Sampling?
    var maxTokens: Int?
    var minMemoryGB: Double?
    /// Only these engines can run the model.
    var onlyEngines: [String]?
    var engines: [String: EngineHint]?
    var notes: [String]?

    func matches(_ m: LocalModel) -> Bool {
        let names = [m.repoId, m.name, m.lmstudioRelPath].compactMap { $0?.lowercased() }
        if let r = repos, r.contains(where: { names.contains($0.lowercased()) }) { return true }
        if let subs = nameContains, subs.contains(where: { s in names.contains { $0.contains(s.lowercased()) } }) { return true }
        if let types = modelTypes, let t = m.modelType, types.contains(t) { return true }
        return false
    }
}

struct RecipeSource: Identifiable, Hashable {
    var id: URL { url }
    var name: String
    var url: URL
}

/// Everything MLXRunner knows about running one model well: matched profiles plus the model's own files.
struct ModelRecipe {
    var profiles: [ModelProfile] = []
    /// Model card of the model itself, when its Hugging Face repo is known.
    var modelCard: URL?
    /// Docs of the base model family.
    var sources: [RecipeSource] = []
    /// The chat template has a thinking block.
    var thinks = false
    /// The chat template understands `enable_thinking`.
    var canToggleThinking = false
    var thinkingByDefault = false
    var thinking: Sampling?
    var instruct: Sampling?
    /// Sampling from the model's generation_config.json.
    var generationConfig: Sampling?
    var templateVars: Set<String> = []
    var maxTokens: Int?
    var contextLength: Int?
    var minMemoryGB: Double?
    var onlyEngines: [String]?
    var engines: [String: EngineHint] = [:]
    var notes: [String] = []

    var title: String? { profiles.last?.name }
    var hasAdvice: Bool { !profiles.isEmpty || generationConfig != nil || !notes.isEmpty }

    /// Recommended sampling for a mode; falls back to generation_config.json.
    func sampling(thinking on: Bool) -> Sampling? {
        let s = (on && thinks ? thinking : instruct) ?? thinking ?? instruct
        if let g = generationConfig { return g.merged(with: s) }
        return s
    }

    /// Where the recommended sampling comes from.
    var samplingSource: String {
        if thinking != nil || instruct != nil { return profiles.last { $0.thinking != nil || $0.instruct != nil }?.name ?? "model card" }
        return generationConfig != nil ? "generation_config.json" : ""
    }

    func engineArgs(_ engineId: String) -> [String] { engines[engineId]?.args ?? [] }

    /// Why this model can't run on an engine, or nil.
    func incompatibility(engineId: String, engineName: String, version: String?) -> String? {
        if let only = onlyEngines, !only.contains(engineId) {
            return only.isEmpty ? "none of the engines MLXRunner installs can run this model"
                                : "this model only runs on \(only.joined(separator: ", "))"
        }
        guard let hint = engines[engineId] else { return nil }
        if let why = hint.unsupported { return why }
        if let min = hint.minVersion, let v = version, !v.isEmpty, VersionCompare.isOlder(v, than: min) {
            return "\(engineName) \(v) is too old for this model (needs \(min) or newer); update it in Engines"
        }
        return nil
    }
}

enum VersionCompare {
    static func numbers(_ s: String) -> [Int] {
        let digits = s.split { !$0.isNumber && $0 != "." }.first.map(String.init) ?? ""
        return digits.split(separator: ".").compactMap { Int($0) }
    }

    static func isOlder(_ a: String, than b: String) -> Bool {
        let x = numbers(a), y = numbers(b)
        guard !x.isEmpty, !y.isEmpty else { return false }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p < q }
        }
        return false
    }
}

@MainActor
final class ModelProfiles {
    static let shared = ModelProfiles()

    private(set) var profiles: [ModelProfile] = []
    private var cache: [String: ModelRecipe] = [:]

    static var customURL: URL { Paths.appSupport.appendingPathComponent("model-profiles.json") }

    init() { reload() }

    func reload() {
        var all: [ModelProfile] = []
        if let url = Bundle.main.url(forResource: "model-profiles", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let list = try? JSONDecoder().decode([ModelProfile].self, from: data) {
            all += list
        }
        if let data = try? Data(contentsOf: Self.customURL),
           let list = try? JSONDecoder().decode([ModelProfile].self, from: data) {
            // Custom profiles win over bundled ones with the same priority.
            all += list.map { var p = $0; p.priority = ($0.priority ?? 0) + 1; return p }
        }
        profiles = all
        cache = [:]
    }

    func recipe(for model: LocalModel) -> ModelRecipe {
        if let r = cache[model.path] { return r }
        let r = build(model)
        cache[model.path] = r
        return r
    }

    private func build(_ m: LocalModel) -> ModelRecipe {
        var r = ModelRecipe()
        let dir = URL(fileURLWithPath: m.path)
        if let repo = m.repoId { r.modelCard = URL(string: "https://huggingface.co/\(repo)") }

        // 1. The model's own files.
        let cfg = ModelScanner.readConfig(dir) ?? [:]
        let text = cfg["text_config"] as? [String: Any] ?? [:]
        func cfgValue(_ k: String) -> Any? { text[k] ?? cfg[k] }
        if let n = (cfgValue("max_position_embeddings") as? NSNumber)?.intValue { r.contextLength = n }
        let rope = (cfgValue("rope_scaling") as? [String: Any]) ?? (cfgValue("rope_parameters") as? [String: Any])
        if let rope, (rope["rope_type"] as? String ?? rope["type"] as? String) == "yarn" {
            let factor = (rope["factor"] as? NSNumber)?.doubleValue ?? 0
            let native = (rope["original_max_position_embeddings"] as? NSNumber)?.intValue ?? 0
            r.notes.append("Long context is switched on with static YaRN (factor \(Sampling.format(factor)) over \(native.formatted()) native tokens). "
                           + "Qwen advises YaRN only when prompts are longer than the native context, because it can lower quality on short prompts.")
        }
        let quant = (cfg["quantization"] as? [String: Any]) ?? (cfg["quantization_config"] as? [String: Any])
        if let mode = quant?["mode"] as? String, ["mxfp8", "mxfp4", "nvfp4"].contains(mode) {
            r.notes.append("Quantized with \(mode), which needs a recent MLX. Engines with an older MLX fail to load it; update them in Engines.")
        }
        // What the files themselves rule out; profiles can't widen it.
        var fileOnly: [String]?
        if FileManager.default.fileExists(atPath: dir.appendingPathComponent("ngram_table.bin").path) {
            fileOnly = ["mlx-serve"]
            r.notes.append("This is an mlx-serve pack (its n-gram table is in ngram_table.bin), so only mlx-serve can run it.")
        }
        if (quant?["bits"] as? NSNumber)?.intValue == 1 {
            fileOnly = []
            r.notes.append("Its weights are 1-bit, which needs PrismML's MLX fork with 1-bit kernels. The engines MLXRunner installs use standard MLX and can't run it.")
        }
        if FileManager.default.fileExists(atPath: dir.appendingPathComponent("mtplx_runtime.json").path) {
            r.notes.append("Tuned for MTPLX: MTPLX reads its MTP depth and sampler from mtplx_runtime.json, so it needs no extra flags. Other engines run it without that speed-up.")
        }
        if m.hasMTP {
            r.notes.append("Has a multi-token prediction (MTP) head: MTPLX and mlx-serve use it to generate faster.")
        }
        r.generationConfig = Self.generationConfig(dir)
        let template = Self.chatTemplate(dir)
        r.thinks = template.contains("<think>")
        let known = ["enable_thinking", "preserve_thinking", "reasoning_effort", "thinking_budget"]
        r.templateVars = Set(known.filter { template.contains($0) })
        r.canToggleThinking = r.templateVars.contains("enable_thinking")
        r.thinkingByDefault = r.thinks && !template.contains("enable_thinking is defined and enable_thinking is true")
        if r.templateVars.contains("thinking_budget") {
            r.notes.append("Its chat template accepts thinking_budget in chat_template_kwargs to cap the number of thinking tokens.")
        }

        // 2. Profiles from the model cards, generic first.
        let matched = profiles.filter { $0.matches(m) }.sorted { ($0.priority ?? 0) < ($1.priority ?? 0) }
        r.profiles = matched
        var profileNotes: [String] = []
        for p in matched {
            if let t = p.thinkingByDefault { r.thinkingByDefault = t }
            if let s = p.thinking { r.thinking = (r.thinking ?? Sampling()).merged(with: s) }
            if let s = p.instruct { r.instruct = (r.instruct ?? Sampling()).merged(with: s) }
            if let v = p.maxTokens { r.maxTokens = v }
            if let v = p.minMemoryGB { r.minMemoryGB = v }
            if let v = p.onlyEngines { r.onlyEngines = v }
            for (id, hint) in p.engines ?? [:] { r.engines[id] = (r.engines[id] ?? EngineHint()).merged(with: hint) }
            if let src = p.source, let url = URL(string: src), url != r.modelCard,
               !r.sources.contains(where: { $0.url == url }) {
                r.sources.append(RecipeSource(name: p.name, url: url))
            }
            profileNotes += p.notes ?? []
        }
        if let f = fileOnly { r.onlyEngines = r.onlyEngines.map { only in only.filter { f.contains($0) } } ?? f }
        r.notes = profileNotes + r.notes
        if let need = r.minMemoryGB, SystemInfo.machine.ramGB < need {
            r.notes.insert("This Mac has \(SystemInfo.machine.ramGB.fmt(0)) GB of memory; this model needs at least \(need.fmt(0)) GB.", at: 0)
        }
        return r
    }

    static func generationConfig(_ dir: URL) -> Sampling? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("generation_config.json")),
              let g = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func d(_ k: String) -> Double? { (g[k] as? NSNumber)?.doubleValue }
        let s = Sampling(temperature: d("temperature"), top_p: d("top_p"), top_k: (g["top_k"] as? NSNumber)?.intValue,
                         min_p: d("min_p"), presence_penalty: d("presence_penalty"),
                         repetition_penalty: d("repetition_penalty"))
        return s.isEmpty ? nil : s
    }

    static func chatTemplate(_ dir: URL) -> String {
        if let t = try? String(contentsOf: dir.appendingPathComponent("chat_template.jinja"), encoding: .utf8) { return t }
        if let data = try? Data(contentsOf: dir.appendingPathComponent("chat_template.json")),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let t = obj["chat_template"] as? String { return t }
        if let data = try? Data(contentsOf: dir.appendingPathComponent("tokenizer_config.json")),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let t = obj["chat_template"] as? String { return t }
            if let list = obj["chat_template"] as? [[String: Any]] {
                return list.compactMap { $0["template"] as? String }.joined(separator: "\n")
            }
        }
        return ""
    }
}

extension EngineSpec {
    /// Arguments that set this engine's defaults for requests that leave them out.
    /// Uses the engine's `defaults` map: keys are API names (temperature, top_p, …, max_tokens,
    /// template_args, thinking_on, thinking_off); values are the engine's flags.
    func defaultArgs(sampling: Sampling?, maxTokens: Int?, thinking: Bool?, templateArgs: [String: Any]) -> [String] {
        guard let map = defaults else { return [] }
        var args: [String] = []
        func flag(_ key: String, _ value: String?) {
            guard let f = map[key] else { return }
            args += f.split(separator: " ").map(String.init)
            if let v = value { args.append(v) }
        }
        for (k, v) in sampling?.fields ?? [] { flag(k, Sampling.format(v)) }
        if let n = maxTokens { flag("max_tokens", String(n)) }
        if !templateArgs.isEmpty, map["template_args"] != nil,
           let data = try? JSONSerialization.data(withJSONObject: templateArgs, options: [.sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            flag("template_args", json)
        } else if let t = thinking {
            // Engines without a template-args flag may have a thinking switch instead.
            flag(t ? "thinking_on" : "thinking_off", nil)
        }
        return args
    }
}
