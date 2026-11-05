import SwiftUI

struct GitHubRepo: Identifiable, Decodable, Hashable {
    let id: Int
    let full_name: String
    let html_url: String
    let description: String?
    let stargazers_count: Int
    let pushed_at: String?
    let language: String?
}

private struct SearchResponse: Decodable { let items: [GitHubRepo] }

struct DiscoverView: View {
    @EnvironmentObject var engines: EngineManager
    @State private var repos: [GitHubRepo] = []
    @State private var loading = false
    @State private var error: String?
    @State private var adding: EngineSpec?
    @State private var hideKnown = false

    private let queries = [
        "mlx server in:name,description,topics",
        "mlx inference in:name,description,topics",
        "mlx openai-compatible in:name,description,readme",
        "topic:mlx llm serving",
    ]

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Discover",
                       subtitle: "Finds MLX inference engines on GitHub. Add a new one as a custom engine to benchmark it.") {
                Toggle("Hide supported", isOn: $hideKnown).toggleStyle(.switch)
                Button {
                    Task { await search() }
                } label: {
                    if loading { ProgressView().controlSize(.small) } else { Label("Search GitHub", systemImage: "magnifyingglass") }
                }
                .disabled(loading)
                Button("Add custom engine…") { adding = blankSpec(name: "my-engine", repo: "owner/repo") }
            }
            Divider()
            List {
                if let error { Text(error).foregroundStyle(.red) }
                ForEach(repos.filter { !hideKnown || !isKnown($0) }) { r in
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Link(r.full_name, destination: URL(string: r.html_url)!).font(.headline)
                                if isKnown(r) { Pill(text: "Supported", color: .green) }
                                if let l = r.language { Pill(text: l) }
                            }
                            Text(r.description ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            if let p = r.pushed_at { Text("Updated \(String(p.prefix(10)))").font(.caption2).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        Label("\(r.stargazers_count)", systemImage: "star.fill").font(.caption).foregroundStyle(.yellow)
                        if !isKnown(r) {
                            Button("Add…") {
                                adding = blankSpec(name: String(r.full_name.split(separator: "/").last ?? ""), repo: r.full_name)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .overlay {
                if repos.isEmpty && !loading {
                    ContentUnavailableView("Search GitHub for MLX engines", systemImage: "sparkle.magnifyingglass",
                                           description: Text("Results are sorted by stars."))
                }
            }
        }
        .sheet(item: $adding) { spec in
            CustomEngineSheet(spec: spec) { engines.addCustom($0) }
        }
    }

    private func isKnown(_ r: GitHubRepo) -> Bool {
        engines.specs.contains { $0.repo.lowercased() == r.full_name.lowercased() }
    }

    private func blankSpec(name: String, repo: String) -> EngineSpec {
        let id = name.lowercased().replacingOccurrences(of: " ", with: "-")
        return EngineSpec(id: id, name: name, repo: repo, summary: "Custom engine from \(repo)",
                          install: InstallSpec(kind: "uv", python: "3.12", packages: ["git+https://github.com/\(repo)"]),
                          versionPackage: nil,
                          command: ["{bin}/\(id)", "--model", "{model}", "--host", "{host}", "--port", "{port}"],
                          env: nil, requestModel: "{model}", visionOnly: nil, experimental: true, lifecycle: nil, custom: true)
    }

    private func search() async {
        loading = true
        error = nil
        defer { loading = false }
        var seen = Set<Int>()
        var all: [GitHubRepo] = []
        for q in queries {
            var c = URLComponents(string: "https://api.github.com/search/repositories")!
            c.queryItems = [URLQueryItem(name: "q", value: q), URLQueryItem(name: "sort", value: "stars"),
                            URLQueryItem(name: "order", value: "desc"), URLQueryItem(name: "per_page", value: "50")]
            var req = URLRequest(url: c.url!)
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            req.setValue("MLXRunner/0.1", forHTTPHeaderField: "User-Agent")
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                if let h = resp as? HTTPURLResponse, h.statusCode == 403 {
                    error = "GitHub rate limit reached (10 searches per minute without login). Try again in a minute."
                    break
                }
                let r = try JSONDecoder().decode(SearchResponse.self, from: data)
                for item in r.items where seen.insert(item.id).inserted { all.append(item) }
            } catch {
                self.error = error.localizedDescription
            }
        }
        repos = all.sorted { $0.stargazers_count > $1.stargazers_count }
    }
}

struct CustomEngineSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var spec: EngineSpec
    var onSave: (EngineSpec) -> Void
    @State private var packages = ""
    @State private var command = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Custom engine").font(.title2.bold())
            Text("MLXRunner installs the packages into a fresh environment, starts the command, and talks to it with the OpenAI API at /v1/chat/completions. Check the project's README for the right command.")
                .font(.caption).foregroundStyle(.secondary)
            Form {
                TextField("ID", text: $spec.id)
                TextField("Name", text: $spec.name)
                TextField("GitHub repo", text: $spec.repo)
                TextField("pip packages (space separated)", text: $packages)
                TextField("Python version", text: Binding(get: { spec.install.python ?? "3.12" }, set: { spec.install.python = $0 }))
                TextField("Server command", text: $command, axis: .vertical)
                TextField("Model name sent in requests", text: Binding(get: { spec.requestModel ?? "{model}" }, set: { spec.requestModel = $0 }))
                Toggle("Vision models only", isOn: Binding(get: { spec.visionOnly ?? false }, set: { spec.visionOnly = $0 }))
            }
            Text("Placeholders: {bin} engine's bin folder · {model} model folder · {modelParent} · {modelName} · {host} · {port}")
                .font(.caption2).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add engine") {
                    spec.install.packages = packages.split(separator: " ").map(String.init)
                    spec.command = command.split(separator: " ").map(String.init)
                    onSave(spec)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(spec.id.isEmpty || packages.isEmpty || command.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 620)
        .onAppear {
            packages = (spec.install.packages ?? []).joined(separator: " ")
            command = spec.command.joined(separator: " ")
        }
    }
}
