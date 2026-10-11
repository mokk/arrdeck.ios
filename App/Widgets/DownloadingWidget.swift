import ArrdeckGlance
import SwiftUI
import WidgetKit

struct DownloadingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "dk.thrawn.arrdeck.downloading", provider: GlanceProvider()) { entry in
            DownloadingView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(GlanceLink.activity.url)
        }
        .configurationDisplayName("Downloading")
        .description("What the torrent clients are downloading, as of arrdeck's last refresh.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryCircular])
    }
}

struct DownloadingView: View {
    let entry: GlanceEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        let freshness = entry.freshness(.downloads)
        if freshness == .expired || entry.snapshot?.downloads == nil {
            OpenAppNote()
        } else if let snapshot = entry.snapshot, let downloads = snapshot.downloads {
            content(downloads, base: snapshot.byteBase, stale: freshness == .stale)
                .staleness(freshness)
        }
    }

    @ViewBuilder
    func content(_ downloads: GlanceSnapshot.Downloads, base: Int, stale: Bool) -> some View {
        switch family {
        case .accessoryCircular: circular(downloads)
        case .accessoryRectangular: rectangular(downloads, base: base)
        case .systemMedium: medium(downloads, base: base, stale: stale)
        default: small(downloads, base: base, stale: stale)
        }
    }

    func circular(_ downloads: GlanceSnapshot.Downloads) -> some View {
        Group {
            if downloads.count == 0 {
                ZStack {
                    AccessoryWidgetBackground()
                    Image(systemName: "checkmark").font(.title3.weight(.semibold))
                }
            } else {
                Gauge(value: downloads.progress ?? 0) {
                    Image(systemName: "arrow.down")
                } currentValueLabel: {
                    Text(verbatim: "\(downloads.count)")
                }
                .gaugeStyle(.accessoryCircularCapacity)
            }
        }
        .widgetAccentable()
        .accessibilityLabel(downloads.count == 0 ? Text("Nothing downloading") : Text("Downloading: \(downloads.count)"))
    }

    func rectangular(_ downloads: GlanceSnapshot.Downloads, base: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if downloads.count == 0 {
                Label("Nothing downloading", systemImage: "checkmark.circle").font(.headline).widgetAccentable()
                UpdatedNote(at: downloads.at)
            } else {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.down.circle.fill")
                    Text(verbatim: "\(downloads.count) · \(GlanceFormat.speed(downloads.speed, base: base))")
                }
                .font(.headline)
                .widgetAccentable()
                if let lead = downloads.top.first { Text(lead.name).font(.caption).lineLimit(1) }
                if let progress = downloads.progress { ProgressView(value: progress) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func small(_ downloads: GlanceSnapshot.Downloads, base: Int, stale: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            WidgetHeader(title: "Downloading", symbol: "arrow.down.circle")
            Spacer(minLength: 0)
            if downloads.count == 0 {
                Text("Nothing downloading").font(.headline)
            } else {
                Text(verbatim: "\(downloads.count)")
                    .font(.system(size: 40, weight: .semibold, design: .rounded))
                    .minimumScaleFactor(0.6)
                Text(GlanceFormat.speed(downloads.speed, base: base))
                    .font(.subheadline.weight(.medium))
                    .monospacedDigit()
                if let progress = downloads.progress { ProgressView(value: progress) }
            }
            footer(downloads, stale: stale)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    func medium(_ downloads: GlanceSnapshot.Downloads, base: Int, stale: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                WidgetHeader(title: "Downloading", symbol: "arrow.down.circle")
                Spacer()
                if downloads.count > 0 {
                    Text(verbatim: "\(downloads.count) · \(GlanceFormat.speed(downloads.speed, base: base))")
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                }
            }
            if downloads.count == 0 {
                Spacer(minLength: 0)
                Text("Nothing downloading").font(.headline)
                Spacer(minLength: 0)
            } else {
                ForEach(downloads.top, id: \.self) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(item.name).font(.caption.weight(.medium)).lineLimit(1)
                            Spacer(minLength: 4)
                            Text(GlanceFormat.percent(item.progress)).font(.caption2).monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        ProgressView(value: item.progress)
                    }
                }
                if downloads.count > downloads.top.count {
                    Text("\(downloads.count - downloads.top.count) more")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            footer(downloads, stale: stale)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The time always: these numbers are only as current as the app's last refresh.
    @ViewBuilder
    func footer(_ downloads: GlanceSnapshot.Downloads, stale: Bool) -> some View {
        if !stale, downloads.count > 0, let eta = downloads.eta {
            Text("Done by \(Text(GlanceFormat.finish(eta, from: downloads.at), style: .time))")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else {
            UpdatedNote(at: downloads.at)
        }
    }
}
