import SwiftUI

struct ModelsView: View {
    @State private var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Models",
                       subtitle: "MLX models on this Mac, and a downloader for Hugging Face (mlx-community, lmstudio-community…).") {
                Picker("", selection: $tab) {
                    Text("On this Mac").tag(0)
                    Text("Download").tag(1)
                }
                .pickerStyle(.segmented)
                .frame(width: 240)
            }
            Divider()
            if tab == 0 { LocalModelsView() } else { HFDownloadView() }
        }
    }
}

struct LocalModelsView: View {
    @EnvironmentObject var models: ModelStore
    @State private var selection: LocalModel.ID?

    var body: some View {
        VStack(spacing: 0) {
            Table(models.local, selection: $selection) {
                TableColumn("Model") { m in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(m.displayName).fontWeight(.medium)
                        Text(m.path.tildePath).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
                .width(min: 280, ideal: 420)
                TableColumn("Source") { m in Text(m.source) }.width(min: 90, ideal: 120)
                TableColumn("Size") { m in Text("\(m.sizeGB.fmt(1)) GB").monospacedDigit() }.width(70)
                TableColumn("Quant") { m in Text(m.bits.map { "\($0)-bit" } ?? "–") }.width(60)
                TableColumn("Type") { m in Text(m.modelType ?? "–") }.width(min: 80, ideal: 110)
                TableColumn("Features") { m in
                    HStack(spacing: 4) {
                        if m.vision { Pill(text: "vision", color: .purple) }
                        if m.hasMTP { Pill(text: "MTP", color: .blue) }
                    }
                }
                .width(min: 90, ideal: 110)
            }
            .contextMenu(forSelectionType: LocalModel.ID.self) { ids in
                if let id = ids.first, let m = models.local.first(where: { $0.id == id }) {
                    Button("Show in Finder") { models.reveal(m) }
                    Button("Copy path") { Clipboard.copy(m.path) }
                    if m.source == "MLXRunner" {
                        Divider()
                        Button("Move to Trash", role: .destructive) { models.delete(m) }
                    }
                }
            }
            Divider()
            HStack {
                Text("\(models.local.count) models · \(models.local.reduce(0) { $0 + $1.sizeGB }.fmt(0)) GB · Downloads go to \(Paths.modelsDir.path.tildePath)")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if models.isScanning { ProgressView().controlSize(.small) }
                Button("Rescan") { models.scan() }
            }
            .padding(10)
        }
    }
}

struct HFDownloadView: View {
    @EnvironmentObject var models: ModelStore
    @State private var query = ""
    @State private var author = "mlx-community"
    @State private var selected: String?
    @State private var manualRepo = ""
    @AppStorage("hfLLMOnly") private var llmOnly = true

    private static let llmTags: Set<String> = ["text-generation", "image-text-to-text", "any-to-any", "text2text-generation", "conversational"]
    private var visibleResults: [HFModel] {
        llmOnly ? models.searchResults.filter { $0.pipeline_tag.map { Self.llmTags.contains($0) } ?? true } : models.searchResults
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Search models (e.g. qwen3 8b 4bit)", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await models.search(query, author: author) } }
                Picker("Publisher", selection: $author) {
                    Text("mlx-community").tag("mlx-community")
                    Text("lmstudio-community").tag("lmstudio-community")
                    Text("Any (MLX tag)").tag("")
                }
                .frame(width: 260)
                Toggle("Chat models only", isOn: $llmOnly)
                Button("Search") { Task { await models.search(query, author: author) } }
                    .keyboardShortcut(.defaultAction)
                if models.isSearching { ProgressView().controlSize(.small) }
            }
            .padding(12)

            HSplitView {
                List(visibleResults, selection: $selected) { m in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(m.id).fontWeight(.medium)
                            HStack(spacing: 10) {
                                Label("\(m.downloads ?? 0)", systemImage: "arrow.down.circle")
                                Label("\(m.likes ?? 0)", systemImage: "heart")
                                if let p = m.pipeline_tag { Text(p) }
                            }
                            .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if models.isDownloaded(m.id) { Pill(text: "Downloaded", color: .green) }
                    }
                    .tag(m.id)
                }
                .overlay {
                    if visibleResults.isEmpty && !models.isSearching {
                        Text(models.searchError ?? "Search Hugging Face for MLX models.")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(minWidth: 380)

                detail
                    .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }

            if !models.downloads.isEmpty {
                Divider()
                DownloadsList()
                    .frame(maxHeight: 180)
            }
        }
        .task {
            if models.searchResults.isEmpty { await models.search("", author: author) }
        }
        .onChange(of: selected) { _, id in
            if let id { Task { await models.loadSize(id) } }
        }
    }

    @ViewBuilder
    private var detail: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let id = selected {
                Text(id).font(.title3.bold()).textSelection(.enabled)
                if let size = models.repoSizes[id] {
                    HStack {
                        Text("Download size: \(size.gb.fmt(2)) GB")
                        FitBadge(sizeGB: size.gb)
                    }
                    Text("Your Mac has \(SystemInfo.machine.ramGB.fmt(0)) GB of unified memory. A model needs roughly its file size plus 10–30 % for context.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    HStack { ProgressView().controlSize(.small); Text("Getting size…") }
                }
                HStack {
                    Button {
                        models.download(id)
                    } label: {
                        Label(models.isDownloaded(id) ? "Download again / repair" : "Download", systemImage: "arrow.down.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(models.downloads[id].map { !$0.finished && !$0.failed } ?? false)
                    Link("Open on Hugging Face", destination: URL(string: "https://huggingface.co/\(id)")!)
                }
            } else {
                Text("Select a model to see its size and download it.").foregroundStyle(.secondary)
            }
            Divider()
            Text("Or download any repo by name").font(.headline)
            HStack {
                TextField("org/model, e.g. mlx-community/Qwen3-8B-4bit", text: $manualRepo)
                    .textFieldStyle(.roundedBorder)
                Button("Download") {
                    let r = manualRepo.trimmingCharacters(in: .whitespaces)
                    if r.contains("/") { models.download(r) }
                }
            }
            Spacer()
        }
        .padding(16)
    }
}

struct DownloadsList: View {
    @EnvironmentObject var models: ModelStore

    var body: some View {
        List {
            ForEach(models.downloads.values.sorted { $0.id < $1.id }) { job in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(job.id).fontWeight(.medium)
                        ProgressView(value: job.fraction)
                            .tint(job.failed ? .red : (job.finished ? .green : .accentColor))
                        Text("\(job.doneBytes.gb.fmt(2)) / \(job.totalBytes.gb.fmt(2)) GB · \(job.state)")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if !job.finished && !job.failed {
                        Button("Cancel") { models.cancelDownload(job.id) }
                    } else if job.failed {
                        Button("Retry") { models.download(job.id) }
                    }
                }
            }
        }
    }
}
