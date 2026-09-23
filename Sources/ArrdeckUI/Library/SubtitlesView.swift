import ArrdeckData
import SwiftUI

/// One title's subtitles as Bazarr sees them: what is on disk as badges, a
/// "Get <language>" per missing one that asks Bazarr to search and download.
struct SubtitleTracksView: View {
    let subtitles: TitleSubtitles
    let busy: Bool
    let get: (String) -> Void

    var body: some View {
        if subtitles.tracked != true {
            EmptyNote(String(localized: "Bazarr does not track this title"))
        } else if !subtitles.hasLanguages {
            EmptyNote(String(localized: "No subtitle languages wanted"))
        } else {
            FlowRow {
                ForEach(subtitles.present ?? [], id: \.self) { track in
                    StateBadge(state: "\(track.language)\(track.hi == true ? " HI" : "")\(track.forced == true ? " F" : "") ✓")
                }
                ForEach(subtitles.missing ?? [], id: \.self) { track in
                    Button(String(localized: "Get \(track.language)")) { get(track.code) }
                        .buttonStyle(.bordered).controlSize(.small)
                        .disabled(busy)
                }
            }
        }
    }
}

/// Wrapping row of small items.
struct FlowRow<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        if #available(iOS 16.0, macOS 13.0, *) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) { content() }
                VStack(alignment: .leading, spacing: 6) { content() }
            }
        } else {
            HStack(spacing: 6) { content() }
        }
    }
}
