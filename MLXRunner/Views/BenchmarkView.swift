import SwiftUI

struct BenchmarkView: View {
    @EnvironmentObject var engines: EngineManager
    @EnvironmentObject var models: ModelStore
    @EnvironmentObject var results: ResultsStore
    @EnvironmentObject var runner: BenchmarkRunner

    private let lengthOptions = [128, 512, 2048, 8192, 32768]

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Benchmark",
                       subtitle: "Runs every selected engine on every selected model with identical prompts, one at a time.") {
                if runner.isRunning {
                    Button(role: .destructive) { runner.cancel() } label: { Label("Stop", systemImage: "stop.fill") }
                } else {
                    Button {
                        let ms = models.local.filter { runner.selectedModels.contains($0.id) }
                        let es = engines.specs.filter { runner.selectedEngines.contains($0.id) }
                        runner.start(models: ms, engines: es, settings: runner.settings, manager: engines, store: results)
                    } label: {
                        Label("Run benchmark", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(runner.selectedModels.isEmpty || runner.selectedEngines.isEmpty || runner.settings.promptLengths.isEmpty)
                }
            }
            if runner.isRunning || runner.progress > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: runner.progress)
                    Text(runner.step).font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20).padding(.bottom, 8)
            }
            Divider()
            HSplitView {
                config.frame(minWidth: 340, idealWidth: 380, maxWidth: 460)
                VSplitView {
                    LogView(lines: runner.log, emptyText: "Pick models and engines, then press Run benchmark.")
                        .frame(minHeight: 200)
                    LiveResultsTable(rows: runner.live)
                        .frame(minHeight: 160)
                }
            }
        }
        .onAppear {
            if runner.selectedEngines.isEmpty {
                runner.selectedEngines = Set(engines.specs.filter { engines.isInstalled($0.id) }.map(\.id))
            }
        }
    }

    private var config: some View {
        Form {
            Section("Models") {
                if models.local.isEmpty {
                    Text("No MLX models found. Download one in Models.").foregroundStyle(.secondary)
                }
                ForEach(models.local) { m in
                    Toggle(isOn: binding(for: m.id, in: $runner.selectedModels)) {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(m.displayName).lineLimit(1)
                                Text("\(m.sizeGB.fmt(1)) GB · \(m.source)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if m.vision { Pill(text: "vision", color: .purple) }
                            FitBadge(sizeGB: m.sizeGB)
                        }
                    }
                }
            }
            Section("Engines") {
                ForEach(engines.specs) { s in
                    let installed = engines.isInstalled(s.id)
                    Toggle(isOn: binding(for: s.id, in: $runner.selectedEngines)) {
                        HStack {
                            Text(s.name)
                            if !installed { Text("not installed").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    .disabled(!installed)
                }
            }
            Section("Workload") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Prompt lengths (tokens)")
                    HStack {
                        ForEach(lengthOptions, id: \.self) { n in
                            Toggle(n >= 1024 ? "\(n / 1024)k" : "\(n)", isOn: Binding(
                                get: { runner.settings.promptLengths.contains(n) },
                                set: { on in
                                    if on { runner.settings.promptLengths.append(n) } else { runner.settings.promptLengths.removeAll { $0 == n } }
                                    runner.settings.promptLengths.sort()
                                }))
                            .toggleStyle(.button)
                        }
                    }
                }
                Stepper("Output tokens: \(runner.settings.genTokens)", value: $runner.settings.genTokens, in: 32...4096, step: 32)
                Stepper("Measured runs: \(runner.settings.runs) (median)", value: $runner.settings.runs, in: 1...10)
                Stepper("Cool-down between engines: \(Int(runner.settings.cooldownSeconds)) s",
                        value: $runner.settings.cooldownSeconds, in: 0...120, step: 5)
                Toggle("Disable thinking (reasoning models)", isOn: $runner.settings.disableThinking)
            }
            Section {
                Text("Close other heavy apps and keep the Mac on power for stable numbers. Only one engine runs at a time; each gets one warm-up request before measuring.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func binding(for id: String, in set: Binding<Set<String>>) -> Binding<Bool> {
        Binding(get: { set.wrappedValue.contains(id) },
                set: { on in if on { set.wrappedValue.insert(id) } else { set.wrappedValue.remove(id) } })
    }
}

struct LiveResultsTable: View {
    let rows: [BenchResult]

    var body: some View {
        Table(rows) {
            TableColumn("Engine") { r in Text(r.engineName) }
            TableColumn("Model") { r in Text(r.modelName).lineLimit(1) }
            TableColumn("Prompt") { r in Text(r.promptTokensTarget > 0 ? "\(r.promptTokens) tok" : "–").monospacedDigit() }
                .width(80)
            TableColumn("TTFT") { r in Text(r.ok ? "\(r.ttftMs.fmt(0)) ms" : "–").monospacedDigit() }.width(80)
            TableColumn("Prompt tok/s") { r in Text(r.ok ? r.promptTps.fmt(0) : "–").monospacedDigit() }.width(90)
            TableColumn("Gen tok/s") { r in
                Text(r.ok ? r.genTps.fmt(1) : "–").monospacedDigit().fontWeight(.semibold)
            }
            .width(80)
            TableColumn("Memory") { r in Text(r.ok ? "\(r.memPeakGB.fmt(1)) GB" : "–").monospacedDigit() }.width(80)
            TableColumn("Status") { r in
                if let e = r.error { Text(e).foregroundStyle(.red).lineLimit(1).help(e) } else { Text("✓") }
            }
        }
    }
}
