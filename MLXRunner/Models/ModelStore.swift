import Foundation
import AppKit

struct LocalModel: Identifiable, Hashable, Codable {
    var id: String { path }
    var path: String
    var name: String
    var repoId: String?
    var source: String
    var sizeBytes: Int64
    var modelType: String?
    var bits: Int?
    var vision: Bool
    var hasMTP: Bool
    /// Path relative to LM Studio's models folder, when the model lives there.
    var lmstudioRelPath: String?

    var sizeGB: Double { sizeBytes.gb }
    var displayName: String { repoId ?? name }
}

struct HFModel: Identifiable, Decodable, Hashable {
    let id: String
    let downloads: Int?
    let likes: Int?
    let lastModified: String?
    let pipeline_tag: String?
}

struct DownloadJob: Identifiable {
    var id: String
    var totalBytes: Int64 = 0
    var doneBytes: Int64 = 0
    var state: String = "Starting…"
    var finished = false
    var failed = false
    var fraction: Double { totalBytes > 0 ? min(1, Double(doneBytes) / Double(totalBytes)) : 0 }
}

enum ModelScanner {
    static func readConfig(_ dir: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("config.json")) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static func hasSafetensors(_ dir: URL) -> Bool {
        let items = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return items.contains { $0.hasSuffix(".safetensors") }
    }

    static func size(of dir: URL) -> Int64 {
        var total: Int64 = 0
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { return 0 }
        for case let u as URL in e {
            let r = u.resolvingSymlinksInPath()
            if let v = try? r.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), v.isRegularFile == true {
                total += Int64(v.fileSize ?? 0)
            }
        }
        return total
    }

    static func isLanguageModel(_ cfg: [String: Any]) -> Bool {
        let type = (cfg["model_type"] as? String ?? "").lowercased()
        let blocked = ["whisper", "t5", "umt5", "clip", "vit", "bert", "m2m_100", "wan", "siglip", "sam"]
        if blocked.contains(where: { type == $0 || type.hasPrefix($0 + "_") }) { return false }
        return cfg["num_hidden_layers"] != nil || cfg["text_config"] != nil || cfg["n_layer"] != nil
    }

    static func looksMLX(_ cfg: [String: Any], hint: String) -> Bool {
        if cfg["quantization"] != nil { return true }
        let h = hint.lowercased()
        return h.contains("mlx") || h.hasPrefix("mlx-community") || h.hasPrefix("lmstudio-community")
    }

    static func makeModel(dir: URL, name: String, repoId: String?, source: String, lmRel: String?,
                          requireMLXHint: Bool) -> LocalModel? {
        guard let cfg = readConfig(dir), hasSafetensors(dir), isLanguageModel(cfg) else { return nil }
        if requireMLXHint && !looksMLX(cfg, hint: repoId ?? name) { return nil }
        let quant = (cfg["quantization"] as? [String: Any]) ?? (cfg["quantization_config"] as? [String: Any])
        let bits = quant?["bits"] as? Int
        let textCfg = cfg["text_config"] as? [String: Any]
        let mtpLayers = (cfg["num_nextn_predict_layers"] as? Int) ?? (cfg["mtp_num_hidden_layers"] as? Int)
            ?? (textCfg?["mtp_num_hidden_layers"] as? Int) ?? 0
        let hasMTPDir = FileManager.default.fileExists(atPath: dir.appendingPathComponent("mtp").path)
        return LocalModel(path: dir.path, name: name, repoId: repoId, source: source,
                          sizeBytes: size(of: dir), modelType: cfg["model_type"] as? String, bits: bits,
                          vision: cfg["vision_config"] != nil, hasMTP: mtpLayers > 0 || hasMTPDir,
                          lmstudioRelPath: lmRel)
    }

    /// Finds model folders up to `depth` levels below `root`.
    static func scanTree(root: URL, source: String, depth: Int, isLMStudio: Bool = false) -> [LocalModel] {
        var found: [LocalModel] = []
        func walk(_ dir: URL, _ level: Int) {
            if let m = makeModel(dir: dir, name: dir.lastPathComponent, repoId: repoId(root: root, dir: dir),
                                 source: source, lmRel: isLMStudio ? relPath(root: root, dir: dir) : nil,
                                 requireMLXHint: false) {
                found.append(m)
                return
            }
            guard level < depth else { return }
            let subs = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                                                                      options: [.skipsHiddenFiles])) ?? []
            for s in subs where (try? s.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                walk(s, level + 1)
            }
        }
        walk(root, 0)
        return found
    }

    static func relPath(root: URL, dir: URL) -> String {
        let r = root.standardizedFileURL.path
        let d = dir.standardizedFileURL.path
        return d.hasPrefix(r) ? String(d.dropFirst(r.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")) : d
    }

    static func repoId(root: URL, dir: URL) -> String? {
        let rel = relPath(root: root, dir: dir)
        let parts = rel.split(separator: "/")
        return parts.count == 2 ? rel : nil
    }

    static func scanHFCache() -> [LocalModel] {
        let hub = Paths.huggingFaceHub
        let repos = (try? FileManager.default.contentsOfDirectory(atPath: hub.path)) ?? []
        var found: [LocalModel] = []
        for r in repos where r.hasPrefix("models--") {
            let repoId = r.dropFirst("models--".count).replacingOccurrences(of: "--", with: "/")
            let snaps = hub.appendingPathComponent(r).appendingPathComponent("snapshots")
            let items = (try? FileManager.default.contentsOfDirectory(at: snaps, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            let newest = items.max { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da < db
            }
            if let snap = newest, let m = makeModel(dir: snap, name: String(repoId.split(separator: "/").last ?? ""),
                                                    repoId: repoId, source: "Hugging Face cache", lmRel: nil,
                                                    requireMLXHint: true) {
                found.append(m)
            }
        }
        return found
    }

    static func scanAll() -> [LocalModel] {
        var all: [LocalModel] = []
        all += scanTree(root: Paths.modelsDir, source: "MLXRunner", depth: 3)
        all += scanHFCache()
        all += scanTree(root: Paths.lmStudioModels, source: "LM Studio", depth: 3, isLMStudio: true)
        all += scanTree(root: Paths.mlxServeModels, source: "mlx-serve", depth: 3)
        var seen = Set<String>()
        return all.filter { seen.insert(URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path).inserted }
            .sorted { $0.displayName.lowercased() < $1.displayName.lowercased() }
    }
}

@MainActor
final class ModelStore: ObservableObject {
    @Published var local: [LocalModel] = []
    @Published var isScanning = false
    @Published var searchResults: [HFModel] = []
    @Published var isSearching = false
    @Published var searchError: String?
    @Published var repoSizes: [String: Int64] = [:]
    @Published var downloads: [String: DownloadJob] = [:]
    private var downloaders: [String: HFDownloader] = [:]
    private var downloadTasks: [String: Task<Void, Never>] = [:]

    func scan() {
        isScanning = true
        ModelProfiles.shared.reload()   // model files may have changed
        Task.detached(priority: .userInitiated) {
            let found = ModelScanner.scanAll()
            await MainActor.run {
                self.local = found
                self.isScanning = false
            }
        }
    }

    func search(_ query: String, author: String?) async {
        isSearching = true
        searchError = nil
        defer { isSearching = false }
        var comps = URLComponents(string: "https://huggingface.co/api/models")!
        var items = [URLQueryItem(name: "filter", value: "mlx"),
                     URLQueryItem(name: "sort", value: "downloads"),
                     URLQueryItem(name: "direction", value: "-1"),
                     URLQueryItem(name: "limit", value: "80")]
        if !query.isEmpty { items.append(URLQueryItem(name: "search", value: query)) }
        if let author, !author.isEmpty { items.append(URLQueryItem(name: "author", value: author)) }
        comps.queryItems = items
        do {
            var req = URLRequest(url: comps.url!)
            if let t = Paths.huggingFaceToken { req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
            let (data, _) = try await URLSession.shared.data(for: req)
            searchResults = try JSONDecoder().decode([HFModel].self, from: data)
        } catch {
            searchError = error.localizedDescription
            searchResults = []
        }
    }

    nonisolated static func fileList(_ repo: String) async throws -> [(path: String, size: Int64)] {
        let url = URL(string: "https://huggingface.co/api/models/\(repo)/tree/main?recursive=true")!
        guard let arr = try await HTTP.json(url, token: Paths.huggingFaceToken) as? [[String: Any]] else { return [] }
        return arr.compactMap { item in
            guard item["type"] as? String == "file", let p = item["path"] as? String else { return nil }
            let lfs = item["lfs"] as? [String: Any]
            let size = (lfs?["size"] as? NSNumber)?.int64Value ?? (item["size"] as? NSNumber)?.int64Value ?? 0
            return (p, size)
        }
    }

    func loadSize(_ repo: String) async {
        guard repoSizes[repo] == nil else { return }
        if let files = try? await ModelStore.fileList(repo) {
            repoSizes[repo] = files.reduce(0) { $0 + $1.size }
        }
    }

    func isDownloaded(_ repo: String) -> Bool {
        local.contains { $0.repoId == repo }
    }

    func download(_ repo: String) {
        guard downloadTasks[repo] == nil else { return }
        downloads[repo] = DownloadJob(id: repo)
        let dest = Paths.modelsDir.appendingPathComponent(repo, isDirectory: true)
        let downloader = HFDownloader()
        downloaders[repo] = downloader
        downloadTasks[repo] = Task {
            do {
                let files = try await ModelStore.fileList(repo)
                let total = files.reduce(Int64(0)) { $0 + $1.size }
                downloads[repo]?.totalBytes = total
                var done: Int64 = 0
                for (i, f) in files.enumerated() {
                    try Task.checkCancellation()
                    let target = dest.appendingPathComponent(f.path)
                    if let attrs = try? FileManager.default.attributesOfItem(atPath: target.path),
                       (attrs[.size] as? NSNumber)?.int64Value == f.size, f.size > 0 {
                        done += f.size
                        downloads[repo]?.doneBytes = done
                        continue
                    }
                    downloads[repo]?.state = "File \(i + 1)/\(files.count): \(f.path)"
                    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    let encoded = f.path.split(separator: "/").map {
                        String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0)
                    }.joined(separator: "/")
                    let url = URL(string: "https://huggingface.co/\(repo)/resolve/main/\(encoded)")!
                    let base = done
                    try await downloader.download(url, to: target, token: Paths.huggingFaceToken) { written in
                        Task { @MainActor in self.downloads[repo]?.doneBytes = base + written }
                    }
                    done += f.size
                    downloads[repo]?.doneBytes = done
                }
                downloads[repo]?.state = "Done · \(total.gb.fmt(2)) GB"
                downloads[repo]?.finished = true
                scan()
            } catch is CancellationError {
                downloads[repo]?.state = "Cancelled (resume by downloading again)"
                downloads[repo]?.failed = true
            } catch {
                downloads[repo]?.state = "Failed: \(error.localizedDescription)"
                downloads[repo]?.failed = true
            }
            downloadTasks[repo] = nil
            downloaders[repo] = nil
        }
    }

    func cancelDownload(_ repo: String) {
        downloaders[repo]?.cancel()
        downloadTasks[repo]?.cancel()
    }

    func delete(_ model: LocalModel) {
        guard model.source == "MLXRunner" else { return }
        try? FileManager.default.trashItem(at: URL(fileURLWithPath: model.path), resultingItemURL: nil)
        scan()
    }

    func reveal(_ model: LocalModel) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: model.path)])
    }
}

/// Downloads one file at a time with progress, using URLSession download tasks.
final class HFDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var session: URLSession!
    private var continuation: CheckedContinuation<Void, Error>?
    private var destination: URL?
    private var progress: ((Int64) -> Void)?
    private var current: URLSessionDownloadTask?

    override init() {
        super.init()
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 120
        cfg.timeoutIntervalForResource = 60 * 60 * 24
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }

    func download(_ url: URL, to dest: URL, token: String?, progress: @escaping (Int64) -> Void) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            lock.lock()
            continuation = cont
            destination = dest
            self.progress = progress
            var req = URLRequest(url: url)
            req.setValue("MLXRunner/0.1", forHTTPHeaderField: "User-Agent")
            if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            let task = session.downloadTask(with: req)
            current = task
            lock.unlock()
            task.resume()
        }
    }

    func cancel() {
        lock.lock(); let t = current; lock.unlock()
        t?.cancel()
    }

    private func finish(_ error: Error?) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        if let error { c?.resume(throwing: error) } else { c?.resume() }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        lock.lock(); let p = progress; lock.unlock()
        p?(totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let h = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(h.statusCode) {
            let msg = h.statusCode == 401 || h.statusCode == 403
                ? "HTTP \(h.statusCode): this model needs a Hugging Face token (Settings)"
                : "HTTP \(h.statusCode)"
            finish(NSError(domain: "HF", code: h.statusCode, userInfo: [NSLocalizedDescriptionKey: msg]))
            return
        }
        lock.lock(); let dest = destination; lock.unlock()
        guard let dest else { finish(nil); return }
        do {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: location, to: dest)
            finish(nil)
        } catch {
            finish(error)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(error) }
    }
}
