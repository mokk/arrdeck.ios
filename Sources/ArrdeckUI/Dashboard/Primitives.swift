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
        Text(text).font(.subheadline).foregroundStyle(Color.danger)
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
                .foregroundStyle(Color.warning)
        }
    }
}

struct StaleNote: View {
    let age: TimeInterval
    var body: some View {
        Text("Service offline — showing data from \(Int((age / 60).rounded()))m ago")
            .font(.caption)
            .foregroundStyle(Color.warning)
    }
}

/// The PWA's state colours: blue for in-progress, green for done, orange for
/// waiting or worrying, red for broken.
enum StateColor {
    @MainActor static func of(_ state: String) -> Color {
        switch state {
        case "downloading", "playing", "fetched": Color.accent
        case "seeding", "completed", "ok", "imported", "downloaded": Color.success
        case "stalled", "queued", "warning", "checking", "wanted", "paused": Color.warning
        case "error", "failed", "deleted": Color.danger
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
            .tint(value >= 1 ? Color.success : Color.accent)
    }
}

/// Posters come as absolute addresses: the artwork CDN's, or a service's own
/// copy with its key in the query, since the image loader cannot send a header.
struct Poster: View {
    let path: String?
    var width: CGFloat = 44
    var cornerRadius: CGFloat = 8
    /// When set, a missing or broken cover becomes a coloured tile carrying
    /// the title, instead of a grey box that reads as "still loading".
    var title: String?
    var subtitle: String?
    /// Album covers and artist pictures are square, not a film poster's 2:3.
    var square = false

    var url: URL? { path.flatMap { URL(string: $0) } }

    var body: some View {
        AsyncImage(url: url) { phase in
            if let image = phase.image {
                image.resizable().aspectRatio(contentMode: .fill)
            } else if let title, url == nil || phase.error != nil {
                CoverPlaceholder(title: title, subtitle: subtitle, compact: width < 60)
            } else {
                Rectangle().fill(.quaternary)
            }
        }
        .frame(width: width, height: square ? width : width * 1.5)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }
}

struct CoverPlaceholder: View {
    let title: String
    let subtitle: String?
    let compact: Bool

    /// A stable hue per title, so a book keeps its colour between launches.
    var hue: Double {
        Double(title.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 360 }) / 360
    }

    var body: some View {
        ZStack(alignment: compact ? .center : .bottomLeading) {
            LinearGradient(colors: [Color(hue: hue, saturation: 0.45, brightness: 0.6),
                                    Color(hue: hue, saturation: 0.5, brightness: 0.28)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            if compact {
                Text(title.prefix(1).uppercased()).font(.headline.bold())
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.caption.bold()).lineLimit(4)
                    if let subtitle { Text(subtitle).font(.caption2).opacity(0.8).lineLimit(1) }
                }
                .padding(8)
            }
        }
        .foregroundStyle(.white)
        .accessibilityHidden(true)
    }
}

/// The floating bar select mode puts above the tab bar. A `.bottomBar`
/// toolbar item would render behind the tabs inside a TabView.
struct BulkBarChrome<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @Environment(\.chrome) private var chrome
    /// Its bottom edge on screen: the tab bar's inset does not reach a page
    /// in a tab's stack, so it rises above the bar by itself.
    @State private var bottom: CGFloat = 0

    var body: some View {
        HStack(spacing: 12) { content() }
            .font(.subheadline)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar, in: Capsule())
            .padding(.horizontal, 16)
            .padding(.bottom, 6 + (chrome?.lift(from: bottom) ?? 0))
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { bottom = $0 }
    }
}

extension View {
    /// Inset-grouped is the iOS card look; macOS has no such style and only
    /// needs to compile.
    /// In a tab's stack it also ends with the margin above the tab bar.
    func dashboardListStyle() -> some View {
        #if os(iOS)
        listStyle(.insetGrouped).themedList().chromeBottomMargin()
        #else
        listStyle(.inset).themedList().chromeBottomMargin()
        #endif
    }
}
