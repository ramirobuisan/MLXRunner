import Foundation

struct BenchSettings: Codable, Equatable {
    var promptLengths: [Int] = [512, 2048, 8192]
    var genTokens = 256
    var runs = 3
    var cooldownSeconds = 5.0
    var disableThinking = true
    /// Use each model's recommended sampling (from its model card or generation_config.json) instead of greedy decoding.
    var recommendedSampling = true
    var readyTimeout = 900.0
}

/// How each benchmark request is sent.
struct RequestOptions {
    var disableThinking: Bool
    /// nil = greedy decoding (temperature 0).
    var sampling: Sampling?
}

struct BenchResult: Codable, Identifiable, Hashable {
    var id = UUID()
    var date = Date()
    var engineId: String
    var engineName: String
    var engineVersion: String
    var modelPath: String
    var modelName: String
    var modelSizeGB: Double
    var promptTokensTarget: Int
    var promptTokens: Int = 0
    var genTokens: Int = 0
    var ttftMs: Double = 0
    var promptTps: Double = 0
    var genTps: Double = 0
    var loadSec: Double = 0
    var memPeakGB: Double = 0
    var procMemGB: Double = 0
    var runs: Int = 0
    var machine: MachineInfo = SystemInfo.machine
    /// Sampling used, e.g. "temperature 0.7 · top_p 0.8"; nil for greedy runs made before this was recorded.
    var sampling: String?
    var error: String?

    var ok: Bool { error == nil }
}

/// One streamed request.
struct Sample {
    var ttft: Double          // seconds
    var genTps: Double
    var promptTps: Double
    var promptTokens: Int
    var completionTokens: Int
    var total: Double
}

enum BenchClient {
    static let corpus = """
    The harbour town woke slowly. Fishing boats knocked against the stone quay while gulls argued over \
    the night's catch, and the baker on the corner opened his shutters to let out the smell of warm bread. \
    In the old observatory above the town, an astronomer compared notes on a comet whose orbit had puzzled \
    three generations of her family. Meanwhile a railway engineer measured the expansion of steel rails in \
    the summer heat, calculating tolerances in millimetres and writing them into a worn notebook. \
    Down by the river, a cooperative of farmers debated the price of olive oil in euros per litre, the cost \
    of irrigation, and whether to plant almonds on the southern slope. A visiting chemist explained how \
    sugar caramelises at around 170 degrees Celsius, while a teacher described the water cycle to children \
    who were more interested in the dog chasing pigeons across the square. \

    """

    /// Builds a prompt of roughly `tokens` tokens (≈ 4 characters per token). The nonce defeats prompt caches.
    static func prompt(tokens: Int, nonce: String, charsPerToken: Double = 4.6) -> String {
        let targetChars = max(200, Int(Double(tokens) * charsPerToken) - 220)
        var body = ""
        var i = 1
        while body.count < targetChars {
            body += "Section \(i). " + corpus
            i += 1
        }
        body = String(body.prefix(targetChars))
        return "[Session \(nonce)]\n\(body)\n\nUsing the notes above, write a long, detailed story about this town. "
            + "Keep writing until you are told to stop."
    }

    static func measure(base: URL, model: String, prompt: String, maxTokens: Int,
                        options: RequestOptions, extras: inout Bool, loadingTimeout: TimeInterval = 900) async throws -> Sample {
        // Servers that load the model in the background answer 503 until it is ready: wait and retry.
        let deadline = Date().addingTimeInterval(loadingTimeout)
        while true {
            do {
                return try await measureOnce(base: base, model: model, prompt: prompt, maxTokens: maxTokens,
                                             options: options, extras: &extras)
            } catch let e as NSError where e.domain == "HTTP" && e.code == 503 && Date() < deadline {
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private static func measureOnce(base: URL, model: String, prompt: String, maxTokens: Int,
                                    options: RequestOptions, extras: inout Bool) async throws -> Sample {
        do {
            return try await request(base: base, model: model, prompt: prompt, maxTokens: maxTokens,
                                     options: options, extras: extras)
        } catch let e as NSError where extras && e.domain == "HTTP" && (400..<500).contains(e.code) {
            // Some servers reject unknown fields; retry once with a plain OpenAI request.
            extras = false
            return try await request(base: base, model: model, prompt: prompt, maxTokens: maxTokens,
                                     options: options, extras: false)
        }
    }

    private static func request(base: URL, model: String, prompt: String, maxTokens: Int,
                                options: RequestOptions, extras: Bool) async throws -> Sample {
        var req = URLRequest(url: base.appendingPathComponent("v1/chat/completions"), timeoutInterval: 900)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer mlxrunner", forHTTPHeaderField: "Authorization")
        var body: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": prompt]],
            "max_tokens": maxTokens,
            "temperature": 0,
            "stream": true,
            "stream_options": ["include_usage": true],
        ]
        // Recommended sampling: standard OpenAI fields always, extensions (top_k, min_p, …) only while accepted.
        for (k, v) in options.sampling?.fields ?? [] where extras || Sampling.standardFields.contains(k) {
            body[k] = v
        }
        if extras {
            body["ignore_eos"] = true
            body["min_tokens"] = maxTokens
            if options.disableThinking { body["chat_template_kwargs"] = ["enable_thinking": false] }
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let start = Date()
        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        if let h = resp as? HTTPURLResponse, h.statusCode != 200 {
            var text = ""
            for try await line in bytes.lines { text += line; if text.count > 600 { break } }
            throw NSError(domain: "HTTP", code: h.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \(h.statusCode): \(text.prefix(400))"])
        }
        var first: Date?
        var last: Date?
        var chunks = 0
        var promptTokens: Int?
        var completionTokens: Int?
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let usage = obj["usage"] as? [String: Any] {
                if let p = (usage["prompt_tokens"] as? NSNumber)?.intValue, p > 0 { promptTokens = p }
                if let c = (usage["completion_tokens"] as? NSNumber)?.intValue, c > 0 { completionTokens = c }
            }
            if let choices = obj["choices"] as? [[String: Any]], let c = choices.first {
                let delta = (c["delta"] as? [String: Any]) ?? [:]
                let text = (delta["content"] as? String ?? "") + (delta["reasoning_content"] as? String ?? "")
                    + (delta["reasoning"] as? String ?? "") + (c["text"] as? String ?? "")
                if !text.isEmpty {
                    let now = Date()
                    if first == nil { first = now }
                    last = now
                    chunks += 1
                }
            }
        }
        guard let f = first, let l = last else {
            throw NSError(domain: "Bench", code: 0, userInfo: [NSLocalizedDescriptionKey: "Server returned no tokens"])
        }
        let ttft = f.timeIntervalSince(start)
        let produced = completionTokens ?? chunks
        let decodeTime = l.timeIntervalSince(f)
        let genTps = decodeTime > 0 && produced > 1 ? Double(produced - 1) / decodeTime : 0
        let pt = promptTokens ?? prompt.count / 4
        return Sample(ttft: ttft, genTps: genTps, promptTps: ttft > 0 ? Double(pt) / ttft : 0,
                      promptTokens: pt, completionTokens: produced, total: l.timeIntervalSince(start))
    }

    static func median(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return 0 }
        let s = xs.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }
}

@MainActor
final class BenchmarkRunner: ObservableObject {
    @Published var isRunning = false
    @Published var log: [String] = []
    @Published var step = ""
    @Published var progress: Double = 0
    @Published var live: [BenchResult] = []
    // Selections live here so they survive switching tabs.
    @Published var selectedModels: Set<String> = []
    @Published var selectedEngines: Set<String> = []
    @Published var settings = BenchSettings()

    private var task: Task<Void, Never>?
    private var server: LaunchedServer?

    func append(_ line: String) {
        log.append(line)
        if log.count > 4000 { log.removeFirst(log.count - 4000) }
    }

    nonisolated func lineHandler() -> (String) -> Void {
        { line in Task { @MainActor in self.append("  │ " + line) } }
    }

    func start(models: [LocalModel], engines: [EngineSpec], settings: BenchSettings,
               manager: EngineManager, store: ResultsStore) {
        guard !isRunning else { return }
        isRunning = true
        live = []
        log = []
        progress = 0
        task = Task {
            await run(models: models, engines: engines, settings: settings, manager: manager, store: store)
            isRunning = false
            step = Task.isCancelled ? "Stopped" : "Finished"
        }
    }

    func cancel() {
        task?.cancel()
        append("Stopping…")
    }

    private func run(models: [LocalModel], engines: [EngineSpec], settings: BenchSettings,
                     manager: EngineManager, store: ResultsStore) async {
        let pairs = models.flatMap { m in engines.map { (m, $0) } }
        append("MLXRunner benchmark · \(SystemInfo.machine.chip) · \(SystemInfo.machine.ramGB.fmt(0)) GB RAM")
        append("Prompt lengths \(settings.promptLengths) · \(settings.genTokens) output tokens · \(settings.runs) runs (median)")
        for (index, (model, spec)) in pairs.enumerated() {
            if Task.isCancelled { break }
            progress = Double(index) / Double(max(1, pairs.count))
            step = "\(spec.name) · \(model.displayName)"
            append("")
            append("▶ \(spec.name) on \(model.displayName) (\(model.sizeGB.fmt(1)) GB)")
            if let why = EngineLauncher.incompatibility(spec, model, manager: manager) {
                append("  skipped: \(why)")
                continue
            }
            await benchOne(model: model, spec: spec, settings: settings, manager: manager, store: store)
            if index < pairs.count - 1 && !Task.isCancelled {
                append("  cooling down \(Int(settings.cooldownSeconds)) s")
                try? await Task.sleep(nanoseconds: UInt64(settings.cooldownSeconds * 1_000_000_000))
            }
        }
        progress = 1
    }

    private func benchOne(model: LocalModel, spec: EngineSpec, settings: BenchSettings,
                          manager: EngineManager, store: ResultsStore) async {
        var version = ""
        if case .installed(let v) = manager.status[spec.id] { version = v }
        let recipe = ModelProfiles.shared.recipe(for: model)
        let sampling = settings.recommendedSampling ? recipe.sampling(thinking: !settings.disableThinking) : nil
        let options = RequestOptions(disableThinking: settings.disableThinking, sampling: sampling)
        let samplingText = sampling.map { $0.summary } ?? "greedy (temperature 0)"
        func base(_ target: Int) -> BenchResult {
            var r = BenchResult(engineId: spec.id, engineName: spec.name, engineVersion: version, modelPath: model.path,
                                modelName: model.displayName, modelSizeGB: model.sizeGB, promptTokensTarget: target)
            r.sampling = samplingText
            return r
        }
        guard manager.isInstalled(spec.id) else {
            append("  skipped: not installed")
            return
        }
        manager.busy.insert(spec.id)
        defer { manager.busy.remove(spec.id) }

        let monitor = MemoryMonitor()
        let t0 = Date()
        let port = SystemInfo.freePort(from: 18_100)
        do {
            let srv = try await EngineLauncher.launch(spec, manager: manager, model: model, port: port,
                                                      readyTimeout: settings.readyTimeout, onLine: lineHandler())
            server = srv
            monitor.start(pid: srv.pid)
            append("  server up on :\(srv.port) after \(Date().timeIntervalSince(t0).fmt(1)) s, warming up…")
            append("  sampling: \(samplingText)\(sampling != nil && !recipe.samplingSource.isEmpty ? " (\(recipe.samplingSource))" : "")")
            if spec.id == "mlx-serve", let app = MLXServeAppSettings.load(modelPath: model.path), app.perModel {
                append("  mlx-serve also uses your MLX-Serve app settings for this model: \(app.summary)")
            }
            var extras = true
            // Warm-up with a ~1k token prompt; also calibrates characters per token for this tokenizer.
            let warmPrompt = BenchClient.prompt(tokens: 1024, nonce: UUID().uuidString)
            let warm = try await BenchClient.measure(base: srv.baseURL, model: srv.requestModel, prompt: warmPrompt,
                                                     maxTokens: 16, options: options, extras: &extras)
            var cpt = 4.6
            if warm.promptTokens > 100 {
                cpt = min(6, max(2.5, Double(warmPrompt.count) / Double(warm.promptTokens - 20)))
            }
            let loadSec = Date().timeIntervalSince(t0) - warm.total + warm.ttft
            append("  ready in \(loadSec.fmt(1)) s (launch → first token)")

            for target in settings.promptLengths {
                if Task.isCancelled { break }
                var samples: [Sample] = []
                var failure: String?
                for r in 0..<settings.runs {
                    if Task.isCancelled { break }
                    do {
                        let s = try await BenchClient.measure(
                            base: srv.baseURL, model: srv.requestModel,
                            prompt: BenchClient.prompt(tokens: target, nonce: UUID().uuidString, charsPerToken: cpt),
                            maxTokens: settings.genTokens, options: options, extras: &extras)
                        samples.append(s)
                        append("  \(target) tok · run \(r + 1): TTFT \((s.ttft * 1000).fmt(0)) ms · prompt \(s.promptTps.fmt(0)) tok/s · gen \(s.genTps.fmt(1)) tok/s (\(s.completionTokens) tok)")
                    } catch {
                        failure = error.localizedDescription
                        append("  \(target) tok · run \(r + 1) failed: \(error.localizedDescription)")
                        break
                    }
                }
                if Task.isCancelled && samples.count < settings.runs { break }   // don't record partial runs
                let mem = monitor.snapshot()
                var res = base(target)
                if samples.isEmpty {
                    res.error = failure ?? "cancelled"
                } else {
                    res.runs = samples.count
                    res.ttftMs = BenchClient.median(samples.map { $0.ttft }) * 1000
                    res.genTps = BenchClient.median(samples.map { $0.genTps })
                    res.promptTps = BenchClient.median(samples.map { $0.promptTps })
                    res.promptTokens = Int(BenchClient.median(samples.map { Double($0.promptTokens) }))
                    res.genTokens = Int(BenchClient.median(samples.map { Double($0.completionTokens) }))
                    res.loadSec = loadSec
                    res.memPeakGB = mem.systemDeltaGB
                    res.procMemGB = mem.processGB
                }
                live.append(res)
                store.add(res)
            }
        } catch where Task.isCancelled {
            append("  cancelled")
        } catch {
            append("  ✗ \(error.localizedDescription)")
            var res = base(0)
            res.error = error.localizedDescription
            live.append(res)
            store.add(res)
        }
        monitor.stop()
        if let srv = server {
            append("  stopping server")
            await EngineLauncher.stop(srv, onLine: lineHandler())
            server = nil
        }
    }
}
