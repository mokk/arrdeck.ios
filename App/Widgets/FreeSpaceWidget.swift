import ArrdeckGlance
import SwiftUI
import WidgetKit

struct FreeSpaceWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "dk.thrawn.arrdeck.freespace", provider: GlanceProvider()) { entry in
            FreeSpaceView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(GlanceLink.settings.url)
        }
        .configurationDisplayName("Free space")
        .description("Room left where the arrs store your library.")
        .supportedFamilies([.systemSmall, .accessoryCircular])
    }
}

struct FreeSpaceView: View {
    let entry: GlanceEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        let freshness = entry.freshness(.disk)
        if freshness == .expired || entry.snapshot?.disk == nil {
            OpenAppNote()
        } else if let snapshot = entry.snapshot, let disk = snapshot.disk {
            Group {
                if family == .accessoryCircular {
                    circular(disk, base: snapshot.byteBase)
                } else {
                    small(disk, base: snapshot.byteBase, stale: freshness == .stale)
                }
            }
            .staleness(freshness)
        }
    }

    /// A filled gauge only when a total is known: the arrs' root folders
    /// report free space alone, and a fraction of nothing would be made up.
    @ViewBuilder
    func circular(_ disk: GlanceSnapshot.Disk, base: Int) -> some View {
        let parts = GlanceFormat.bytes(disk.free, base: base).split(separator: " ")
        let label = VStack(spacing: -2) {
            Text(verbatim: String(parts.first ?? "")).font(.system(.body, design: .rounded).weight(.semibold))
            Text(verbatim: String(parts.last ?? "")).font(.caption2)
        }
        Group {
            if let used = disk.used {
                Gauge(value: 1 - used) { Image(systemName: "internaldrive") } currentValueLabel: { label }
                    .gaugeStyle(.accessoryCircularCapacity)
            } else {
                ZStack {
                    AccessoryWidgetBackground()
                    label.minimumScaleFactor(0.6)
                }
            }
        }
        .widgetAccentable()
        .accessibilityLabel(Text("\(GlanceFormat.bytes(disk.free, base: base)) free"))
    }

    func small(_ disk: GlanceSnapshot.Disk, base: Int, stale: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            WidgetHeader(title: "Free space", symbol: "internaldrive")
            Spacer(minLength: 0)
            Text(GlanceFormat.bytes(disk.free, base: base))
                .font(.system(size: 32, weight: .semibold, design: .rounded))
                .minimumScaleFactor(0.5)
                .lineLimit(1)
            if let used = disk.used {
                ProgressView(value: used)
                Text("of \(GlanceFormat.bytes(disk.total ?? 0, base: base))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if let label = disk.label, !label.isEmpty {
                Text(verbatim: label).font(.caption2).foregroundStyle(.secondary)
            }
            UpdatedNote(at: disk.at)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
