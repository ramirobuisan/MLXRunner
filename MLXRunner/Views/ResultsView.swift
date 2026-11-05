import SwiftUI
import Charts
import AppKit
import UniformTypeIdentifiers

struct ResultsView: View {
    @EnvironmentObject var results: ResultsStore
    @State private var confirmClear = false
    @AppStorage("wGen") private var wGen = 0.5
    @AppStorage("wPrompt") private var wPrompt = 0.25
    @AppStorage("wTTFT") private var wTTFT = 0.15
    @AppStorage("wMem") private var wMem = 0.10

    var body: some View {
        let summaries = results.summaries(weights: ScoreWeights(gen: wGen, prompt: wPrompt, ttft: wTTFT, memory: wMem))
        VStack(spacing: 0) {
            PageHeader(title: "Results",
                       subtitle: "Best engine per model. Score = \(Int(wGen * 100)) % generation speed, \(Int(wPrompt * 100)) % prompt speed, \(Int(wTTFT * 100)) % TTFT, \(Int(wMem * 100)) % memory (change in Settings).") {
                Button { exportCSV() } label: { Label("Export CSV", systemImage: "square.and.arrow.up") }
                    .disabled(results.results.isEmpty)
                Button(role: .destructive) { confirmClear = true } label: { Image(systemName: "trash") }
                    .disabled(results.results.isEmpty)
                    .help("Clear all results")
            }
            Divider()
            if summaries.isEmpty {
                ContentUnavailableView("No results yet", systemImage: "trophy",
                                       description: Text("Run a benchmark to see which engine is fastest for each model."))
            } else {
                ScrollView {
                    LazyVStack(spacing: 16) {
                        ForEach(summaries) { s in ModelResultCard(summary: s) }
                    }
                    .padding(20)
                }
            }
        }
        .confirmationDialog("Delete all benchmark results?", isPresented: $confirmClear) {
            Button("Delete all", role: .destructive) { results.clear() }
        }
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "mlxrunner-results.csv"
        if panel.runModal() == .OK, let url = panel.url {
            try? results.csv().write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

struct ModelResultCard: View {
    @EnvironmentObject var results: ResultsStore
    let summary: ModelSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(summary.modelName).font(.title3.bold())
                    Text(summary.modelPath).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                if let best = summary.best {
                    Label("Best: \(best.engineName)", systemImage: "trophy.fill")
                        .font(.headline)
                        .foregroundStyle(.orange)
                }
            }
            HStack(spacing: 8) {
                if let e = summary.fastestGen { Pill(text: "Fastest generation: \(e.engineName) · \(e.genTps.fmt(1)) tok/s", color: .blue) }
                if let e = summary.fastestPrompt { Pill(text: "Fastest prompt: \(e.engineName) · \(e.promptTps.fmt(0)) tok/s", color: .teal) }
                if let e = summary.lowestTTFT { Pill(text: "Lowest TTFT: \(e.engineName) · \(e.ttftMs.fmt(0)) ms", color: .indigo) }
                if let e = summary.lowestMemory { Pill(text: "Least memory: \(e.engineName) · \(e.memGB.fmt(1)) GB", color: .green) }
            }

            if !summary.scores.isEmpty {
                Chart(summary.scores) { s in
                    BarMark(x: .value("Generation tok/s", s.genTps), y: .value("Engine", s.engineName))
                        .foregroundStyle(s.engineId == summary.best?.engineId ? Color.orange : Color.accentColor.opacity(0.7))
                        .annotation(position: .trailing) {
                            Text(s.genTps.fmt(1)).font(.caption2).foregroundStyle(.secondary)
                        }
                }
                .chartXAxisLabel("Generation speed (tokens/s, average over prompt lengths)")
                .frame(height: CGFloat(36 * summary.scores.count + 40))

                Grid(alignment: .trailing, horizontalSpacing: 18, verticalSpacing: 6) {
                    GridRow {
                        Text("#").gridColumnAlignment(.leading)
                        Text("Engine").gridColumnAlignment(.leading)
                        Text("Score"); Text("Gen tok/s"); Text("Prompt tok/s"); Text("TTFT"); Text("Memory"); Text("Load")
                    }
                    .font(.caption.bold()).foregroundStyle(.secondary)
                    Divider()
                    ForEach(Array(summary.scores.enumerated()), id: \.element.id) { i, s in
                        GridRow {
                            Text("\(i + 1)")
                            Text(s.engineName).fontWeight(i == 0 ? .bold : .regular)
                            Text(s.score.fmt(0))
                            Text(s.genTps.fmt(1))
                            Text(s.promptTps.fmt(0))
                            Text("\(s.ttftMs.fmt(0)) ms")
                            Text("\(s.memGB.fmt(1)) GB")
                            Text("\(s.loadSec.fmt(1)) s")
                        }
                        .monospacedDigit()
                    }
                }
            }

            DisclosureGroup("Details per prompt length (\(summary.rows.count) rows)") {
                Grid(alignment: .trailing, horizontalSpacing: 16, verticalSpacing: 4) {
                    GridRow {
                        Text("Engine").gridColumnAlignment(.leading)
                        Text("Version"); Text("Prompt"); Text("Output"); Text("TTFT"); Text("Prompt tok/s"); Text("Gen tok/s"); Text("Mem"); Text("Date")
                    }
                    .font(.caption.bold()).foregroundStyle(.secondary)
                    ForEach(summary.rows) { r in
                        GridRow {
                            Text(r.engineName)
                            Text(r.engineVersion)
                            Text("\(r.promptTokens)")
                            Text("\(r.genTokens)")
                            Text("\(r.ttftMs.fmt(0)) ms")
                            Text(r.promptTps.fmt(0))
                            Text(r.genTps.fmt(1))
                            Text("\(r.memPeakGB.fmt(1)) GB")
                            Text(r.date.formatted(date: .numeric, time: .shortened))
                        }
                        .font(.caption).monospacedDigit()
                    }
                }
                .padding(.top, 6)
            }
            if !summary.errors.isEmpty {
                DisclosureGroup("Failures (\(summary.errors.count))") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(summary.errors) { r in
                            Text("\(r.engineName): \(r.error ?? "")").font(.caption).foregroundStyle(.red).textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            HStack {
                Spacer()
                Button("Delete results for this model", role: .destructive) { results.remove(modelPath: summary.modelPath) }
                    .controlSize(.small)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.15)))
    }
}
