import ArrdeckData
import SwiftUI

/// Renders a card's `Loadable<Block<_>>` the one way every card does: a
/// placeholder while loading, the reason when arrdeck could not be reached,
/// the reason when the service behind it is offline, an age note over stale
/// data — and the rows only once there is data to show.
struct BlockRows<Value: Sendable & Equatable, Content: View>: View {
    let state: Loadable<Block<Value>>
    @ViewBuilder let content: (Value) -> Content

    var body: some View {
        switch state {
        case .loading:
            LoadingRow()
        case let .failed(reason):
            ErrorNote(reason)
        case let .loaded(block):
            switch block {
            case let .offline(reason):
                ErrorNote("Offline — \(reason)")
            case let .stale(value, age):
                StaleNote(age: age)
                content(value)
            case let .healthy(value):
                content(value)
            }
        }
    }
}

struct LoadingRow: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Loading…").foregroundStyle(.secondary)
        }
        .font(.subheadline)
    }
}

struct ErrorNote: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.subheadline).foregroundStyle(.red)
    }
}

struct EmptyNote: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.subheadline).foregroundStyle(.secondary)
    }
}

/// A card whose latest poll failed while it still shows older data.
struct RefreshNote: View {
    let error: String?
    var body: some View {
        if let error {
            Text("Could not refresh — \(error)")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }
}

struct StaleNote: View {
    let age: TimeInterval
    var body: some View {
        Text("Service offline — showing data from \(Int((age / 60).rounded()))m ago")
            .font(.caption)
            .foregroundStyle(.orange)
    }
}

/// The PWA's state colours: blue for in-progress, green for done, orange for
/// waiting or worrying, red for broken.
enum StateColor {
    static func of(_ state: String) -> Color {
        switch state {
        case "downloading", "playing", "fetched": .blue
        case "seeding", "completed", "ok", "imported", "downloaded": .green
        case "stalled", "queued", "warning", "checking", "wanted", "paused": .orange
        case "error", "failed", "deleted": .red
        default: .secondary
        }
    }
}

struct StateBadge: View {
    let state: String
    var body: some View {
        // A badge never wraps: squeezed beside a long quality string it broke
        // into "import-ed". The text beside it truncates instead. The raw
        // state is the localisation key; service names have no translation.
        Text(String(localized: String.LocalizationValue(state)))
            .lineLimit(1)
            .fixedSize()
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
            .foregroundStyle(StateColor.of(state))
    }
}

struct ProgressBar: View {
    let value: Double
    var body: some View {
        ProgressView(value: min(1, max(0, value)))
            .tint(value >= 1 ? .green : .accentColor)
    }
}

/// Posters come as `/api/v1/poster?u=…`, relative to the profile — the backend
/// proxies them so the device never talks to the artwork CDN directly.
struct Poster: View {
    let path: String?
    let baseURL: URL
    var width: CGFloat = 44
    var cornerRadius: CGFloat = 8

    var url: URL? { path.flatMap { URL(string: $0, relativeTo: baseURL) } }

    var body: some View {
        AsyncImage(url: url) { phase in
            if let image = phase.image {
                image.resizable().aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(.quaternary)
            }
        }
        .frame(width: width, height: width * 1.5)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }
}

/// A trend at a glance, as the PWA draws it: min-to-max, no axes.
struct Sparkline: View {
    let values: [Double]

    var body: some View {
        Canvas { context, size in
            guard values.count >= 2 else { return }
            let low = values.min() ?? 0
            let span = max((values.max() ?? 0) - low, 1)
            let inset: CGFloat = 3
            var path = Path()
            for (index, value) in values.enumerated() {
                let x = size.width * CGFloat(index) / CGFloat(values.count - 1)
                let y = size.height - inset - (size.height - 2 * inset) * CGFloat((value - low) / span)
                if index == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
            }
            context.stroke(path, with: .color(.accentColor), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
        .frame(minHeight: 28)
        .accessibilityHidden(true)
    }
}

extension ToolbarItemPlacement {
    /// The bulk bar sits at the bottom on iOS; macOS has no bottom bar and
    /// only needs to compile.
    static var bulkBar: ToolbarItemPlacement {
        #if os(iOS)
        .bottomBar
        #else
        .automatic
        #endif
    }
}

extension View {
    /// Inset-grouped is the iOS card look; macOS has no such style and only
    /// needs to compile.
    func dashboardListStyle() -> some View {
        #if os(iOS)
        listStyle(.insetGrouped)
        #else
        listStyle(.inset)
        #endif
    }
}
