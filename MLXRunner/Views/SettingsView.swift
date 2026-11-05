import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject var models: ModelStore
    @AppStorage("modelsDir") private var modelsDir = ""
    @AppStorage("hfToken") private var hfToken = ""
    @AppStorage("autoUpdateEngines") private var autoUpdate = true
    @AppStorage("wGen") private var wGen = 0.5
    @AppStorage("wPrompt") private var wPrompt = 0.25
    @AppStorage("wTTFT") private var wTTFT = 0.15
    @AppStorage("wMem") private var wMem = 0.10

    var body: some View {
        Form {
            Section("Models") {
                HStack {
                    TextField("Download folder", text: $modelsDir, prompt: Text(Paths.defaultModels.path))
                    Button("Choose…") {
                        let p = NSOpenPanel()
                        p.canChooseDirectories = true
                        p.canChooseFiles = false
                        p.canCreateDirectories = true
                        if p.runModal() == .OK, let u = p.url { modelsDir = u.path; models.scan() }
                    }
                }
                Text("MLXRunner also finds models in the Hugging Face cache, LM Studio and mlx-serve folders.")
                    .font(.caption).foregroundStyle(.secondary)
                SecureField("Hugging Face token (only for gated models)", text: $hfToken)
            }
            Section("Engines") {
                Toggle("Keep engines up to date automatically", isOn: $autoUpdate)
                Text("Checks once a day. New versions install side by side; the old version is deleted only after the new one works.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Ranking weights") {
                weight("Generation speed", $wGen)
                weight("Prompt processing speed", $wPrompt)
                weight("Time to first token", $wTTFT)
                weight("Memory use", $wMem)
                Button("Reset to defaults") { wGen = 0.5; wPrompt = 0.25; wTTFT = 0.15; wMem = 0.10 }
            }
            Section("Data") {
                Button("Open MLXRunner data folder") { NSWorkspace.shared.open(Paths.appSupport) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 560)
    }

    private func weight(_ label: String, _ value: Binding<Double>) -> some View {
        HStack {
            Text(label).frame(width: 190, alignment: .leading)
            Slider(value: value, in: 0...1, step: 0.05)
            Text("\(Int(value.wrappedValue * 100)) %").monospacedDigit().frame(width: 44, alignment: .trailing)
        }
    }
}
