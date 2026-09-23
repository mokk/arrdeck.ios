import ArrdeckData
import SwiftUI

/// "Request" while it waits for approval, "Requested" once approved and not
/// yet here.
struct RequestBadge: View {
    let request: RequestState?

    var body: some View {
        if let request {
            let pending = request.status == 1
            Text(pending ? "Request" : "Requested")
                .font(.system(size: 10, weight: .bold))
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(pending ? Color.warning : Color.accent, in: RoundedRectangle(cornerRadius: 4))
                .foregroundStyle(pending ? Color.black : Color.white)
                .accessibilityLabel(Text("Requested by \(request.requested_by ?? "")"))
        }
    }
}

/// On a title's page: who asked for it, with approve and decline while the
/// request waits. Renders nothing when there is no open request.
struct RequestBannerSection: View {
    let api: any LibraryAPI
    let movieTMDB: Int?
    let showTVDB: Int?
    @State private var request: RequestState?
    @State private var busy = false

    var body: some View {
        Group {
            if let request {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(request.status == 1 ? "Requested, waiting for approval" : "Requested and approved, not here yet")
                            .font(.subheadline.weight(.medium))
                        Text("Requested by \(request.requested_by ?? "?")").font(.caption).foregroundStyle(.secondary)
                        if request.status == 1, let dashboard = api as? any DashboardAPI {
                            HStack {
                                Button("Approve") { act(dashboard, request, .approve) }.buttonStyle(.borderedProminent)
                                Button("Decline") { act(dashboard, request, .decline) }.buttonStyle(.bordered)
                            }
                            .disabled(busy)
                        }
                    }
                }
            }
        }
        .task { await load() }
    }

    func load() async {
        guard let source = api as? any RequestsMapAPI, let map = try? await source.requestMap() else { return }
        request = RequestLookup.find(map, movieTMDB: movieTMDB, showTVDB: showTVDB)
    }

    func act(_ dashboard: any DashboardAPI, _ request: RequestState, _ action: RequestAction) {
        busy = true
        Task {
            try? await dashboard.act(on: request.request_id, action)
            busy = false
            await load()
        }
    }
}
