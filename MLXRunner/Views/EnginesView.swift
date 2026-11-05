import SwiftUI

struct EnginesView: View {
    @EnvironmentObject var engines: EngineManager
    @State private var selected: String?
    @State private var confirmRemove: EngineSpec?
    @AppStorage("autoUpdateEngines") private var autoUpdate = true

    /// The selected engine, or else the one currently installing.
    private var logId: String? {
        if let selected { return selected }
        return engines.specs.first { s in
            if case .working = engines.status[s.id] { return true }
            return false
        }?.id
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Engines",
                       subtitle: "Each engine installs into its own isolated Python environment under Application Support.") {
                Toggle("Auto-update", isOn: $autoUpdate)
                    .toggleStyle(.switch)
                    .help("Checks daily, installs new versions and deletes the old ones")
                Button {
                    Task { await engines.checkForUpdates(autoInstall: autoUpdate) }
                } label: {
                    if engines.isCheckingUpdates { ProgressView().controlSize(.small) } else { Text("Check for updates") }
                }
                .disabled(engines.isCheckingUpdates)
                Button("Install all") { Task { await engines.installAll() } }
                    .disabled(engines.isInstallingAll)
                    .help("Installs every Python engine that isn't installed yet")
                Button { Task { await engines.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh")
            }
            HStack(spacing: 14) {
                Label(engines.uvPath != nil ? "uv found" : "uv missing (installed automatically)",
                      systemImage: engines.uvPath != nil ? "checkmark.circle" : "exclamationmark.triangle")
                Label(engines.brewPath != nil ? "Homebrew found" : "Homebrew missing",
                      systemImage: engines.brewPath != nil ? "checkmark.circle" : "exclamationmark.triangle")
                if let d = engines.lastUpdateCheck {
                    Text("Last update check: \(d.formatted(date: .abbreviated, time: .shortened))")
                }
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 20)
            .padding(.bottom, 8)

            Divider()
            VSplitView {
                List(selection: $selected) {
                    ForEach(engines.specs) { spec in
                        EngineRow(spec: spec, onRemove: { confirmRemove = spec })
                            .tag(spec.id)
                            .padding(.vertical, 4)
                    }
                }
                .frame(minHeight: 420, idealHeight: 640)

                VStack(alignment: .leading, spacing: 0) {
                    Text(logId.flatMap { engines.spec($0)?.name }.map { "Log · \($0)" } ?? "Log (select an engine)")
                        .font(.caption.bold())
                        .padding(.horizontal, 10).padding(.vertical, 6)
                    LogView(lines: logId.flatMap { engines.logs[$0] } ?? [])
                }
                .frame(minHeight: 110, idealHeight: 160)
            }
        }
        .confirmationDialog("Remove \(confirmRemove?.name ?? "")?", isPresented: Binding(
            get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } })) {
            Button("Remove", role: .destructive) {
                if let s = confirmRemove {
                    Task {
                        if s.custom == true { await engines.removeCustom(s) } else { await engines.uninstall(s) }
                    }
                }
                confirmRemove = nil
            }
        } message: {
            Text("This deletes the engine's environment. Your models and results are kept.")
        }
    }
}

struct EngineRow: View {
    @EnvironmentObject var engines: EngineManager
    let spec: EngineSpec
    var onRemove: () -> Void

    var body: some View {
        let status = engines.status[spec.id] ?? .checking
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(spec.name).font(.headline)
                    if spec.experimental == true { Pill(text: "beta", color: .orange) }
                    if spec.custom == true { Pill(text: "custom", color: .purple) }
                    if spec.install.kind == "brew" { Pill(text: "Homebrew", color: .brown) }
                    if spec.install.kind == "external" { Pill(text: "external app", color: .gray) }
                }
                Text(spec.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                if let url = spec.repoURL {
                    Link(spec.repo, destination: url).font(.caption)
                }
            }
            Spacer()
            statusView(status)
            actions(status)
        }
    }

    @ViewBuilder
    private func statusView(_ status: EngineStatus) -> some View {
        switch status {
        case .installed:
            HStack(spacing: 6) {
                Pill(text: status.label, color: .green)
                if engines.hasUpdate(spec), let l = engines.latest[spec.id] {
                    Pill(text: "→ \(l)", color: .blue)
                }
            }
        case .working(let s):
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text(s).font(.caption) }
        case .failed:
            Pill(text: "Failed, see log", color: .red)
        case .checking:
            ProgressView().controlSize(.small)
        case .notInstalled:
            Pill(text: "Not installed")
        }
    }

    @ViewBuilder
    private func actions(_ status: EngineStatus) -> some View {
        let working: Bool = { if case .working = status { return true }; return false }()
        HStack(spacing: 6) {
            if status.isInstalled {
                if engines.hasUpdate(spec) {
                    Button("Update") { Task { await engines.install(spec, isUpdate: true) } }
                } else if spec.install.kind == "uv" {
                    Button { Task { await engines.install(spec, isUpdate: true) } } label: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                    .help("Reinstall (fresh environment; the old one is deleted after it works)")
                }
                if spec.install.kind == "uv" || (spec.install.kind == "brew" && engines.installedVersion(spec) != nil) {
                    Button(role: .destructive, action: onRemove) { Image(systemName: "trash") }
                        .help("Remove")
                }
            } else {
                Button(spec.install.kind == "external" ? "Get…" : "Install") {
                    Task { await engines.install(spec) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(working)
            }
        }
        .frame(minWidth: 110, alignment: .trailing)
    }
}
