import Foundation

struct ServeEntry: Identifiable {
    let id: UUID
    let server: LaunchedServer
    var state: String
}

@MainActor
final class ServeManager: ObservableObject {
    @Published var running: [ServeEntry] = []
    @Published var starting = false
    @Published var log: [String] = []
    @Published var lastError: String?

    func append(_ line: String) {
        log.append(line)
        if log.count > 3000 { log.removeFirst(log.count - 3000) }
    }

    nonisolated func handler() -> (String) -> Void {
        { line in Task { @MainActor in self.append(line) } }
    }

    func start(spec: EngineSpec, model: LocalModel, host: String, port: Int, extraArgs: String,
               manager: EngineManager) {
        guard !starting else { return }
        if !SystemInfo.isPortFree(port) {
            lastError = "Port \(port) is already in use. Pick another port."
            return
        }
        starting = true
        lastError = nil
        append("▶ Starting \(spec.name) with \(model.displayName) on \(host):\(port)")
        manager.busy.insert(spec.id)
        Task {
            do {
                let args = extraArgs.split(separator: " ").map(String.init)
                let srv = try await EngineLauncher.launch(spec, manager: manager, model: model, host: host, port: port,
                                                          extraArgs: args, onLine: handler())
                running.append(ServeEntry(id: srv.id, server: srv, state: "Running"))
                append("✓ Ready: \(srv.openAIBase)  (model name: \(srv.requestModel))")
            } catch {
                lastError = error.localizedDescription
                append("✗ \(error.localizedDescription)")
                manager.busy.remove(spec.id)
            }
            starting = false
        }
    }

    func stop(_ entry: ServeEntry, manager: EngineManager) {
        Task {
            append("■ Stopping \(entry.server.spec.name) on port \(entry.server.port)")
            await EngineLauncher.stop(entry.server, onLine: handler())
            running.removeAll { $0.id == entry.id }
            if !running.contains(where: { $0.server.spec.id == entry.server.spec.id }) {
                manager.busy.remove(entry.server.spec.id)
            }
        }
    }

    func stopAll(manager: EngineManager) async {
        for e in running {
            await EngineLauncher.stop(e.server)
            manager.busy.remove(e.server.spec.id)
        }
        running = []
    }
}
