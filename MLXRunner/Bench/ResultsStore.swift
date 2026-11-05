import Foundation

struct EngineScore: Identifiable, Hashable {
    var id: String { engineId }
    var engineId: String
    var engineName: String
    var genTps: Double
    var promptTps: Double
    var ttftMs: Double
    var memGB: Double
    var loadSec: Double
    var score: Double = 0
}

struct ModelSummary: Identifiable {
    var id: String { modelPath }
    var modelPath: String
    var modelName: String
    var scores: [EngineScore]     // sorted best first
    var rows: [BenchResult]       // latest successful row per engine and prompt length
    var errors: [BenchResult]

    var best: EngineScore? { scores.first }
    var fastestGen: EngineScore? { scores.max { $0.genTps < $1.genTps } }
    var fastestPrompt: EngineScore? { scores.max { $0.promptTps < $1.promptTps } }
    var lowestTTFT: EngineScore? { scores.filter { $0.ttftMs > 0 }.min { $0.ttftMs < $1.ttftMs } }
    var lowestMemory: EngineScore? { scores.filter { $0.memGB > 0 }.min { $0.memGB < $1.memGB } }
}

struct ScoreWeights {
    var gen: Double
    var prompt: Double
    var ttft: Double
    var memory: Double

    static var current: ScoreWeights {
        let d = UserDefaults.standard
        func v(_ k: String, _ def: Double) -> Double { d.object(forKey: k) as? Double ?? def }
        return ScoreWeights(gen: v("wGen", 0.5), prompt: v("wPrompt", 0.25), ttft: v("wTTFT", 0.15), memory: v("wMem", 0.10))
    }
}

@MainActor
final class ResultsStore: ObservableObject {
    @Published private(set) var results: [BenchResult] = []

    init() { load() }

    private var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted]
        return e
    }

    func load() {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: Paths.results), let r = try? d.decode([BenchResult].self, from: data) {
            results = r
        }
    }

    func save() {
        if let data = try? encoder.encode(results) { try? data.write(to: Paths.results, options: .atomic) }
    }

    func add(_ r: BenchResult) {
        results.append(r)
        save()
    }

    func clear() {
        results = []
        save()
    }

    func remove(modelPath: String) {
        results.removeAll { $0.modelPath == modelPath }
        save()
    }

    /// Latest result for every (model, engine, prompt length).
    var latest: [BenchResult] {
        var map: [String: BenchResult] = [:]
        for r in results {
            let key = "\(r.modelPath)|\(r.engineId)|\(r.promptTokensTarget)"
            if let old = map[key], old.date > r.date { continue }
            map[key] = r
        }
        return Array(map.values)
    }

    func summaries(weights: ScoreWeights = .current) -> [ModelSummary] {
        let rows = latest
        let byModel = Dictionary(grouping: rows, by: { $0.modelPath })
        return byModel.map { path, rs in
            let ok = rs.filter { $0.ok }
            // Hide failures that a later successful run of the same engine superseded.
            let errors = rs.filter { e in
                !e.ok && !rs.contains { $0.ok && $0.engineId == e.engineId && $0.date > e.date }
            }
            let byEngine = Dictionary(grouping: ok, by: { $0.engineId })
            var scores: [EngineScore] = byEngine.map { id, er in
                func avg(_ f: (BenchResult) -> Double) -> Double { er.map(f).reduce(0, +) / Double(er.count) }
                return EngineScore(engineId: id, engineName: er[0].engineName, genTps: avg { $0.genTps },
                                   promptTps: avg { $0.promptTps }, ttftMs: avg { $0.ttftMs },
                                   memGB: er.map { $0.memPeakGB }.max() ?? 0, loadSec: avg { $0.loadSec })
            }
            let maxGen = scores.map { $0.genTps }.max() ?? 1
            let maxPrompt = scores.map { $0.promptTps }.max() ?? 1
            let minTTFT = scores.map { $0.ttftMs }.filter { $0 > 0 }.min() ?? 1
            let minMem = scores.map { $0.memGB }.filter { $0 > 0.05 }.min() ?? 1
            let wsum = max(0.0001, weights.gen + weights.prompt + weights.ttft + weights.memory)
            for i in scores.indices {
                let s = scores[i]
                var total = 0.0
                total += weights.gen * (maxGen > 0 ? s.genTps / maxGen : 0)
                total += weights.prompt * (maxPrompt > 0 ? s.promptTps / maxPrompt : 0)
                total += weights.ttft * (s.ttftMs > 0 ? minTTFT / s.ttftMs : 0)
                total += weights.memory * (s.memGB > 0.05 ? min(1, minMem / s.memGB) : 1)
                scores[i].score = total / wsum * 100
            }
            scores.sort { $0.score > $1.score }
            let name = rs.first?.modelName ?? URL(fileURLWithPath: path).lastPathComponent
            return ModelSummary(modelPath: path, modelName: name, scores: scores,
                                rows: ok.sorted { ($0.promptTokensTarget, $0.engineName) < ($1.promptTokensTarget, $1.engineName) },
                                errors: errors)
        }
        .sorted { $0.modelName.lowercased() < $1.modelName.lowercased() }
    }

    /// Best engine id for a model path, used by the Serve tab.
    func bestEngine(for modelPath: String) -> String? {
        summaries().first { $0.modelPath == modelPath }?.best?.engineId
    }

    func csv() -> String {
        var lines = ["date,chip,ram_gb,engine,engine_version,model,model_size_gb,prompt_target,prompt_tokens,gen_tokens,ttft_ms,prompt_tps,gen_tps,load_s,mem_peak_gb,process_mem_gb,runs,sampling,error"]
        let f = ISO8601DateFormatter()
        for r in results.sorted(by: { $0.date < $1.date }) {
            let fields: [String] = [
                f.string(from: r.date), r.machine.chip, r.machine.ramGB.fmt(0), r.engineName, r.engineVersion,
                r.modelName, r.modelSizeGB.fmt(2), String(r.promptTokensTarget), String(r.promptTokens),
                String(r.genTokens), r.ttftMs.fmt(1), r.promptTps.fmt(1), r.genTps.fmt(2), r.loadSec.fmt(1),
                r.memPeakGB.fmt(2), r.procMemGB.fmt(2), String(r.runs), r.sampling ?? "", r.error ?? "",
            ]
            lines.append(fields.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }.joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
