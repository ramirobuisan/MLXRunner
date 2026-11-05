import SwiftUI

struct ServeView: View {
    @EnvironmentObject var engines: EngineManager
    @EnvironmentObject var models: ModelStore
    @EnvironmentObject var results: ResultsStore
    @EnvironmentObject var serve: ServeManager

    @State private var modelId: String?
    @State private var engineId: String?
    @State private var network = false
    @State private var port = "8080"
    @State private var extraArgs = ""

    private var model: LocalModel? { models.local.first { $0.id == modelId } }
    private var compatibleEngines: [EngineSpec] {
        engines.specs.filter { s in
            engines.isInstalled(s.id) && (model.map { EngineLauncher.incompatibility(s, $0) == nil } ?? true)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Serve",
                       subtitle: "Run a model as an OpenAI-compatible API for your apps, using the fastest engine from your benchmarks.") {
                EmptyView()
            }
            Divider()
            HSplitView {
                Form {
                    Section("Model and engine") {
                        Picker("Model", selection: $modelId) {
                            Text("Choose…").tag(String?.none)
                            ForEach(models.local) { m in Text("\(m.displayName) (\(m.sizeGB.fmt(1)) GB)").tag(Optional(m.id)) }
                        }
                        Picker("Engine", selection: $engineId) {
                            Text("Choose…").tag(String?.none)
                            ForEach(compatibleEngines) { s in Text(s.name).tag(Optional(s.id)) }
                        }
                        if let m = model {
                            if let best = results.bestEngine(for: m.path), let spec = engines.spec(best) {
                                HStack {
                                    Label("Fastest in your benchmarks: \(spec.name)", systemImage: "trophy.fill")
                                        .foregroundStyle(.orange)
                                    Spacer()
                                    if engineId != best { Button("Use it") { engineId = best } }
                                }
                            } else {
                                Text("No benchmark yet for this model. Run one to get a recommendation.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Section("Network") {
                        Toggle("Allow other devices on my network", isOn: $network)
                        TextField("Port", text: $port)
                        TextField("Extra engine arguments (optional)", text: $extraArgs)
                    }
                    Section {
                        Button {
                            guard let m = model, let id = engineId, let spec = engines.spec(id), let p = Int(port) else { return }
                            serve.start(spec: spec, model: m, host: network ? "0.0.0.0" : "127.0.0.1", port: p,
                                        extraArgs: extraArgs, manager: engines)
                            port = String(SystemInfo.freePort(from: p + 1))
                        } label: {
                            if serve.starting { ProgressView().controlSize(.small) } else { Label("Start server", systemImage: "play.fill") }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model == nil || engineId == nil || Int(port) == nil || serve.starting)
                        if let e = serve.lastError { Text(e).foregroundStyle(.red).font(.caption) }
                    }
                }
                .formStyle(.grouped)
                .frame(minWidth: 360, idealWidth: 420, maxWidth: 520)
                .onAppear {
                    // Preselect a benchmarked model (or the first one) so serving is one click.
                    if modelId == nil {
                        let benchmarked = Set(results.results.filter { $0.ok }.map(\.modelPath))
                        modelId = (models.local.first { benchmarked.contains($0.path) } ?? models.local.first)?.id
                    }
                }
                .onChange(of: modelId) { _, _ in
                    if let m = model, let best = results.bestEngine(for: m.path), engines.isInstalled(best) {
                        engineId = best
                    } else if let id = engineId, !compatibleEngines.contains(where: { $0.id == id }) {
                        engineId = compatibleEngines.first?.id
                    }
                }

                VSplitView {
                    runningList.frame(minHeight: 200)
                    LogView(lines: serve.log, emptyText: "Server output appears here.").frame(minHeight: 150)
                }
            }
        }
    }

    private var runningList: some View {
        List {
            if serve.running.isEmpty {
                Text("No servers running.").foregroundStyle(.secondary)
            }
            ForEach(serve.running) { entry in
                let s = entry.server
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Circle().fill(.green).frame(width: 8, height: 8)
                        Text("\(s.spec.name) · \(s.model.displayName)").font(.headline)
                        Spacer()
                        Button("Stop", role: .destructive) { serve.stop(entry, manager: engines) }
                    }
                    HStack {
                        Text(s.openAIBase).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        Button { Clipboard.copy(s.openAIBase) } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(.borderless).help("Copy base URL")
                    }
                    Text("Model name for requests: \(s.requestModel)").font(.caption).textSelection(.enabled)
                    let curl = """
                    curl \(s.openAIBase)/chat/completions -H "Content-Type: application/json" -d '{"model": "\(s.requestModel)", "messages": [{"role": "user", "content": "Hello"}]}'
                    """
                    HStack(alignment: .top) {
                        Text(curl).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                            .textSelection(.enabled).lineLimit(3)
                        Button { Clipboard.copy(curl) } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(.borderless).help("Copy test command")
                    }
                }
                .padding(.vertical, 6)
            }
        }
    }
}
