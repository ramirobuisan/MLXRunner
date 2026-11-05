import SwiftUI

/// Recommended settings for one model: sampling, thinking, context, engine requirements and notes.
struct ModelRecipeView: View {
    let model: LocalModel
    let recipe: ModelRecipe
    @EnvironmentObject var engines: EngineManager

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.displayName).font(.headline)
                if let t = recipe.title { Text("Settings from the \(t) model card").font(.caption).foregroundStyle(.secondary) }
            }
            RecipeFacts(recipe: recipe)
            if let app = MLXServeAppSettings.load(modelPath: model.path), app.perModel {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Saved in your MLX-Serve app").font(.caption.bold()).foregroundStyle(.secondary)
                    Text(app.summary).font(.caption).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Text("mlx-serve uses these in MLXRunner too.").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let only = recipe.onlyEngines {
                Label(only.isEmpty ? "None of the engines in MLXRunner can run it"
                                   : "Runs only on \(only.compactMap { engines.spec($0)?.name ?? $0 }.joined(separator: ", "))",
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            // Only engines that can run the model.
            let hintIds = recipe.engines.keys.sorted().filter { recipe.onlyEngines?.contains($0) ?? true }
            if !hintIds.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Per engine").font(.caption.bold()).foregroundStyle(.secondary)
                    ForEach(hintIds, id: \.self) { id in
                        let h = recipe.engines[id] ?? EngineHint()
                        let name = engines.spec(id)?.name ?? id
                        VStack(alignment: .leading, spacing: 1) {
                            if let v = h.minVersion { Text("\(name): needs \(v) or newer").font(.caption) }
                            if let a = h.args, !a.isEmpty {
                                Text("\(name): MLXRunner adds \(a.joined(separator: " "))").font(.caption)
                            }
                            if let n = h.note { Text("\(name): \(n)").font(.caption) }
                        }
                    }
                }
            }
            RecipeNotes(recipe: recipe)
            RecipeLinks(recipe: recipe)
        }
        .padding(14)
        .frame(width: 480, alignment: .leading)
        // The popover inherits the table cell's one-line limit; let every line wrap.
        .lineLimit(nil)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Sampling, thinking, output length and context.
struct RecipeFacts: View {
    let recipe: ModelRecipe

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
            if recipe.thinks {
                row("Thinking", recipe.canToggleThinking
                    ? (recipe.thinkingByDefault ? "on by default, can be turned off" : "off by default, can be turned on")
                    : "always on")
                if let s = recipe.sampling(thinking: true), !s.isEmpty { row("Sampling, thinking", s.summary) }
                if recipe.canToggleThinking, let s = recipe.sampling(thinking: false), !s.isEmpty {
                    row("Sampling, no thinking", s.summary)
                }
            } else if let s = recipe.sampling(thinking: false), !s.isEmpty {
                row("Sampling", s.summary)
            }
            if let n = recipe.maxTokens { row("Output length", "up to \(n.formatted()) tokens") }
            if let c = recipe.contextLength { row("Context", "\(c.formatted()) tokens") }
            if let g = recipe.minMemoryGB { row("Memory", "at least \(g.fmt(0)) GB") }
        }
        .font(.caption)
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.leading)
            Text(value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct RecipeNotes: View {
    let recipe: ModelRecipe

    var body: some View {
        if !recipe.notes.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(recipe.notes, id: \.self) { n in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "info.circle").foregroundStyle(.secondary)
                        Text(n).fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.caption)
                }
            }
        }
    }
}

struct RecipeLinks: View {
    let recipe: ModelRecipe

    var body: some View {
        HStack(spacing: 12) {
            if let card = recipe.modelCard { Link("Model card", destination: card) }
            ForEach(recipe.sources) { s in Link("\(s.name) docs", destination: s.url) }
        }
        .font(.caption)
    }
}
