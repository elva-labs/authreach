import AuthReachCore
import SwiftUI

/// The global-shortcut HUD: recent codes, click to copy. Kept deliberately
/// minimal — it appears mid-task in another app's context.
struct HudView: View {
    @ObservedObject var model: AppModel
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Recent codes").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("click to copy").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            if model.recent.isEmpty {
                Text("No codes yet — they appear here as they arrive.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(model.recent.prefix(8)) { entry in
                            HudRow(entry: entry) {
                                model.copyEntry(entry)
                                close()
                            }
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
        }
        .frame(width: 300)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct HudRow: View {
    let entry: OtpEntry
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(entry.code)
                    .font(.system(size: 17, weight: .semibold).monospaced())
                VStack(alignment: .leading, spacing: 0) {
                    Text(entry.service).font(.system(size: 11)).lineLimit(1)
                    Text(relativeTime(entry.receivedAt))
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                Spacer()
                if let expiry = expiryLabel(entry.expiresAt) {
                    Text(expiry.label)
                        .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(expiry.expired ? .red : expiry.urgent ? .orange : .secondary)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(hovering ? Color.primary.opacity(0.06) : .clear)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
