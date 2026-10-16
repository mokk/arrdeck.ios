import ArrdeckData
import SwiftUI

/// To read / reading / read on a book's page; "—" clears it.
struct ReadingSection: View {
    let bookID: Int
    let api: any ReadingAPI
    @State private var current: Reading?
    @State private var loaded = false

    var selection: Binding<ReadingStatus?> {
        Binding(get: { current?.readingStatus }, set: { status in
            Task {
                if let map = try? await api.setReading(bookID, status) { current = map[bookID] }
            }
        })
    }

    var body: some View {
        Section {
            Picker("Reading status", selection: selection) {
                Text(verbatim: "—").tag(ReadingStatus?.none)
                ForEach(ReadingStatus.allCases, id: \.self) { Text($0.label).tag(ReadingStatus?.some($0)) }
            }
            .pickerStyle(.segmented)
            if current?.readingStatus == .read, let finished = current?.finished_at {
                Text("Finished \(Format.when(Date(timeIntervalSince1970: TimeInterval(finished))))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .task {
            guard !loaded else { return }
            loaded = true
            current = (try? await api.reading())?[bookID]
        }
    }
}
