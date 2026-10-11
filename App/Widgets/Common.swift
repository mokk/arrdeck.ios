import ArrdeckGlance
import SwiftUI
import WidgetKit

/// What every widget shows in place of numbers it cannot vouch for: none
/// written yet, no shared container, or too old to mean anything.
struct OpenAppNote: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "arrow.clockwise").font(.title3.weight(.semibold))
            }
            .accessibilityLabel(Text("Open arrdeck to load"))
        case .accessoryRectangular, .accessoryInline:
            Label("Open arrdeck to load", systemImage: "arrow.clockwise")
                .font(.headline)
                .widgetAccentable()
        default:
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: "arrow.clockwise.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.tint)
                Text("Open arrdeck to load")
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
    }
}

/// The section's title with its symbol, as the top line of a home-screen widget.
struct WidgetHeader: View {
    let title: LocalizedStringKey
    let symbol: String

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tint)
            .lineLimit(1)
    }
}

/// "Updated 14:05" — on show once a section is stale, so old numbers read as old.
struct UpdatedNote: View {
    let at: Date

    var body: some View {
        Text("Updated \(Text(at, style: .time))")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

extension View {
    /// Stale numbers stay legible but recede.
    func staleness(_ freshness: Freshness) -> some View {
        opacity(freshness == .stale ? 0.55 : 1)
    }
}
