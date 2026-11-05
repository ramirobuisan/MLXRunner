import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        ProcessRegistry.shared.killAll()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct MLXRunnerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var engines = EngineManager()
    @StateObject private var models = ModelStore()
    @StateObject private var results = ResultsStore()
    @StateObject private var runner = BenchmarkRunner()
    @StateObject private var serve = ServeManager()

    var body: some Scene {
        WindowGroup("MLXRunner") {
            ContentView()
                .environmentObject(engines)
                .environmentObject(models)
                .environmentObject(results)
                .environmentObject(runner)
                .environmentObject(serve)
                .frame(minWidth: 1100, minHeight: 720)
                .task {
                    models.scan()
                    await engines.refresh()
                    engines.startAutoUpdates()
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Settings {
            SettingsView()
                .environmentObject(engines)
                .environmentObject(models)
        }
    }
}

enum SidebarItem: String, CaseIterable, Identifiable {
    case engines = "Engines"
    case models = "Models"
    case benchmark = "Benchmark"
    case results = "Results"
    case serve = "Serve"
    case discover = "Discover"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .engines: return "shippingbox"
        case .models: return "square.stack.3d.down.right"
        case .benchmark: return "speedometer"
        case .results: return "trophy"
        case .serve: return "server.rack"
        case .discover: return "sparkle.magnifyingglass"
        }
    }
}

struct ContentView: View {
    @State private var selection: SidebarItem? = .engines
    @EnvironmentObject var runner: BenchmarkRunner
    @EnvironmentObject var serve: ServeManager

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $selection) { item in
                HStack {
                    Label(item.rawValue, systemImage: item.icon)
                    Spacer()
                    if item == .benchmark && runner.isRunning {
                        ProgressView().controlSize(.small)
                    }
                    if item == .serve && !serve.running.isEmpty {
                        Text("\(serve.running.count)")
                            .font(.caption2.bold())
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(Color.green.opacity(0.25)))
                    }
                }
                .tag(item)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
            .safeAreaInset(edge: .bottom) { MachineBadge().padding(12) }
        } detail: {
            switch selection ?? .engines {
            case .engines: EnginesView()
            case .models: ModelsView()
            case .benchmark: BenchmarkView()
            case .results: ResultsView()
            case .serve: ServeView()
            case .discover: DiscoverView()
            }
        }
    }
}

struct MachineBadge: View {
    var body: some View {
        let m = SystemInfo.machine
        VStack(alignment: .leading, spacing: 2) {
            Label(m.chip, systemImage: "cpu").font(.caption.bold())
            Text("\(m.ramGB.fmt(0)) GB unified memory").font(.caption2).foregroundStyle(.secondary)
            Text(m.os).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
