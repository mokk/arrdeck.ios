import ActivityKit
import ArrdeckGlance
import SwiftUI
import WidgetKit

/// The Live Activity the app starts while it is open and something is
/// downloading. Nothing updates it once the app is suspended (that would need
/// push), so the time of the last update is always visible, and past the
/// stale date the system sets it says plainly that the numbers are old.
struct DownloadsActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DownloadsActivityAttributes.self) { context in
            LockScreenView(state: context.state, stale: context.isStale)
                .padding(14)
                .activityBackgroundTint(nil)
                .widgetURL(GlanceLink.activity.url)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label {
                        Text(verbatim: "\(state.count)")
                    } icon: {
                        Image(systemName: "arrow.down.circle.fill")
                    }
                    .font(.headline)
                    .foregroundStyle(.tint)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(GlanceFormat.speed(state.speed, base: state.byteBase))
                        .font(.headline)
                        .monospacedDigit()
                }
                DynamicIslandExpandedRegion(.center) {
                    if let lead = state.lead { Text(lead).font(.subheadline).lineLimit(1) }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        if let progress = state.progress { ProgressView(value: progress) }
                        StatusLine(state: state, stale: context.isStale)
                    }
                }
            } compactLeading: {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(.tint)
            } compactTrailing: {
                if let progress = state.progress {
                    Text(GlanceFormat.percent(progress)).monospacedDigit()
                } else {
                    Text(verbatim: "\(state.count)")
                }
            } minimal: {
                if let progress = state.progress {
                    Gauge(value: progress) { Image(systemName: "arrow.down") }
                        .gaugeStyle(.accessoryCircularCapacity)
                        .tint(.accentColor)
                } else {
                    Image(systemName: "arrow.down.circle.fill").foregroundStyle(.tint)
                }
            }
            .widgetURL(GlanceLink.activity.url)
        }
    }
}

private struct LockScreenView: View {
    let state: DownloadsActivityState
    let stale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Label {
                    Text("Downloading: \(state.count)")
                } icon: {
                    Image(systemName: "arrow.down.circle.fill").foregroundStyle(.tint)
                }
                .font(.headline)
                Spacer()
                Text(GlanceFormat.speed(state.speed, base: state.byteBase))
                    .font(.headline)
                    .monospacedDigit()
            }
            if let lead = state.lead {
                Text(lead).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            if let progress = state.progress { ProgressView(value: progress) }
            StatusLine(state: state, stale: stale)
        }
        .opacity(stale ? 0.6 : 1)
    }
}

/// When it was last updated, and either when it should be done or, once
/// stale, that only opening the app brings it up to date.
private struct StatusLine: View {
    let state: DownloadsActivityState
    let stale: Bool

    var body: some View {
        HStack {
            Text("Updated \(Text(state.updatedAt, style: .time))")
            Spacer()
            if stale {
                Text("Open arrdeck to update")
            } else if let eta = state.eta {
                Text("Done by \(Text(GlanceFormat.finish(eta, from: state.updatedAt), style: .time))")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}
