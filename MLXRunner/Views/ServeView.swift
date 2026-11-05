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
    @State private var thinkingMode = true
    @State private var applyDefaults = true
    @State private var likeMLXServeApp = true
    /// The last model and engine started here, preselected next time.
    @AppStorage("serve.modelPath") private var lastModelPath = ""
    @AppStorage("serve.engineId") private var lastEngineId = ""

    private var model: LocalModel? { models.local.first { $0.id == modelId } }
    private var recipe: ModelRecipe? { model.map { ModelProfiles.shared.recipe(for: $0) } }
    /// What the MLX-Serve app saved for this model, when mlx-serve is the engine.
    private var mlxServeApp: MLXServeAppSettings? {
        guard engineId == "mlx-serve", let m = model else { return nil }
        return MLXServeAppSettings.load(modelPath: m.path)
    }
    /// mlx-serve runs with the MLX-Serve app's own settings and MLXRunner adds no defaults on top.
    private var runsLikeMLXServeApp: Bool { likeMLXServeApp && mlxServeApp != nil }
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
                    if let a = mlxServeApp {
                        mlxServeAppSection(a)
                    }
                    if let m = model, let r = recipe, r.hasAdvice {
                        recommendedSection(m, r)
                    }
                    Section("Network") {
                        Toggle("Allow other devices on my network", isOn: $network)
                        TextField("Port", text: $port)
                        TextField("Extra engine arguments (optional)", text: $extraArgs)
                    }
                    Section {
                        Button {
                            guard let m = model, let id = engineId, let spec = engines.spec(id), let p = Int(port) else { return }
                            let plan = requestPlan(spec)
                            lastModelPath = m.path
                            lastEngineId = id
                            serve.start(spec: spec, model: m, host: network ? "0.0.0.0" : "127.0.0.1", port: p,
                                        extraArgs: extraArgs, defaultArgs: plan.defaultArgs, requestExtras: plan.extras,
                                        manager: engines)
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
                    // Preselect the last served model, else a benchmarked one (or the first), so serving is one click.
                    if modelId == nil {
                        let benchmarked = Set(results.results.filter { $0.ok }.map(\.modelPath))
                        modelId = (models.local.first { $0.path == lastModelPath }
                                   ?? models.local.first { benchmarked.contains($0.path) }
                                   ?? models.local.first)?.id
                    }
                }
                .onChange(of: modelId) { _, _ in
                    thinkingMode = recipe?.thinkingByDefault ?? true
                    if model?.path == lastModelPath, compatibleEngines.contains(where: { $0.id == lastEngineId }) {
                        engineId = lastEngineId
                    } else if let m = model, let best = results.bestEngine(for: m.path), engines.isInstalled(best) {
                        engineId = best
                    } else if engineId.map({ id in !compatibleEngines.contains { $0.id == id } }) ?? true {
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
                    curl \(s.openAIBase)/chat/completions -H "Content-Type: application/json" -d '{"model": "\(s.requestModel)", "messages": [{"role": "user", "content": "Hello"}]\(entry.requestExtras)}'
                    """
                    HStack(alignment: .top) {
                        Text(curl).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                            .textSelection(.enabled).lineLimit(6)
                        Button { Clipboard.copy(curl) } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(.borderless).help("Copy test command")
                    }
                }
                .padding(.vertical, 6)
            }
        }
    }

    // MARK: - Recommended settings

    @ViewBuilder
    private func recommendedSection(_ m: LocalModel, _ r: ModelRecipe) -> some View {
        Section {
            if r.canToggleThinking {
                Picker("Mode", selection: $thinkingMode) {
                    Text("Thinking").tag(true)
                    Text("No thinking").tag(false)
                }
                .pickerStyle(.segmented)
            }
            if let s = r.sampling(thinking: thinkingMode), !s.isEmpty {
                LabeledContent("Sampling") { Text(s.summary).font(.caption).textSelection(.enabled) }
            }
            if let n = r.maxTokens {
                LabeledContent("Output length") { Text("up to \(n.formatted()) tokens").font(.caption) }
            }
            if runsLikeMLXServeApp {
                Text("Not applied: the server uses your MLX-Serve app settings above. Send these values in a request to use them for that request.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Toggle("Make these the server's defaults", isOn: $applyDefaults)
            }
            if applyDefaults, !runsLikeMLXServeApp, let id = engineId, let spec = engines.spec(id) {
                let plan = requestPlan(spec)
                if plan.defaultArgs.isEmpty {
                    Text("\(spec.name) can't set default sampling, so send these values with each request (see the example request).")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Starts \(spec.name) with \(plan.defaultArgs.joined(separator: " "))")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            if let id = engineId, let note = r.engines[id]?.note {
                Label(note, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
            RecipeNotes(recipe: r)
            RecipeLinks(recipe: r)
        } header: {
            Text(r.title.map { "Recommended settings (\($0))" } ?? "Recommended settings")
        }
    }

    // MARK: - MLX-Serve app settings

    @ViewBuilder
    private func mlxServeAppSection(_ a: MLXServeAppSettings) -> some View {
        Section {
            Toggle("Run it like the MLX-Serve app", isOn: $likeMLXServeApp)
            Text(likeMLXServeApp
                 ? "mlx-serve reads these from ~/.mlx-serve itself, so the model runs exactly as in the MLX-Serve app. MLXRunner adds no sampling or length flags."
                 : "mlx-serve still uses the server settings, but the recommended sampling and output length below replace your request defaults.")
                .font(.caption).foregroundStyle(.secondary)
            if !a.server.isEmpty { settingsGrid("Server", a.server) }
            if !a.defaults.isEmpty { settingsGrid("When a request leaves them out", a.defaults) }
            if !a.perModel {
                Text("Nothing is saved for this model in the MLX-Serve app, only global defaults.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if MLXServeAppSettings.appIsRunning {
                Label("The MLX-Serve app is open. If it has this model loaded, unload it there or quit the app first: two copies need twice the memory.",
                      systemImage: "memorychip")
                    .font(.caption).foregroundStyle(.orange)
            }
        } header: {
            Text("Your MLX-Serve app settings")
        }
    }

    private func settingsGrid(_ title: String, _ rows: [MLXServeAppSettings.Row]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.bold()).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                ForEach(rows, id: \.self) { row in
                    GridRow {
                        Text(row.label).foregroundStyle(.secondary)
                        Text(row.value).textSelection(.enabled)
                    }
                }
            }
            .font(.caption)
        }
    }

    /// Server flags and example-request fields for the chosen model, mode and engine.
    private func requestPlan(_ spec: EngineSpec) -> (defaultArgs: [String], extras: String) {
        guard let r = recipe, !runsLikeMLXServeApp else { return ([], "") }
        let sampling = r.sampling(thinking: thinkingMode)
        var templateArgs: [String: Any] = [:]
        if r.canToggleThinking { templateArgs["enable_thinking"] = thinkingMode }
        let args = applyDefaults
            ? spec.defaultArgs(sampling: sampling, maxTokens: r.maxTokens,
                               thinking: r.canToggleThinking ? thinkingMode : nil, templateArgs: templateArgs)
            : []
        var extras = ""
        for (k, v) in sampling?.fields ?? [] { extras += ", \"\(k)\": \(Sampling.format(v))" }
        if r.canToggleThinking && thinkingMode != r.thinkingByDefault {
            extras += ", \"chat_template_kwargs\": {\"enable_thinking\": \(thinkingMode)}"
        }
        return (args, extras)
    }
}
