import SwiftUI
import AppKit

struct PageHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title2.bold())
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 8) { trailing() }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}

struct Pill: View {
    let text: String
    var color: Color = .secondary

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.16)))
            .foregroundStyle(color)
    }
}

struct LogView: View {
    let lines: [String]
    var emptyText = "No output yet."

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if lines.isEmpty {
                        Text(emptyText).foregroundStyle(.secondary)
                    }
                    ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                        Text(line)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(i)
                    }
                }
                .padding(10)
            }
            .background(Color(nsColor: .textBackgroundColor).opacity(0.6))
            .overlay(alignment: .topTrailing) {
                if !lines.isEmpty {
                    Button { Clipboard.copy(lines.joined(separator: "\n")) } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless)
                        .help("Copy log")
                        .padding(8)
                }
            }
            .onChange(of: lines.count) { _, n in
                if n > 0 { proxy.scrollTo(n - 1, anchor: .bottom) }
            }
        }
    }
}

enum Clipboard {
    static func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

/// Fits-in-RAM hint for a model of the given size.
struct FitBadge: View {
    let sizeGB: Double

    var body: some View {
        let ram = SystemInfo.machine.ramGB
        if sizeGB <= 0 {
            EmptyView()
        } else if sizeGB < ram * 0.6 {
            Pill(text: "Fits", color: .green)
        } else if sizeGB < ram * 0.8 {
            Pill(text: "Tight", color: .orange)
        } else {
            Pill(text: "Too big", color: .red)
        }
    }
}
