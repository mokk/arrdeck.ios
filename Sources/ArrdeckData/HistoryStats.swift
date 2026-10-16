import ArrdeckAPI
import Foundation
import Observation

public typealias HistoryPage = Components.Schemas.HistoryPageOut
public typealias BlocklistPage = Components.Schemas.BlocklistPageOut
public typealias BlocklistItem = Components.Schemas.BlocklistItemOut

public protocol HistoryAPI: Sendable {
    func historyPage(_ page: Int) async throws -> HistoryPage
    func blocklist() async throws -> BlocklistPage
    func removeFromBlocklist(_ app: ArrApp, id: Int) async throws
    func clearBlocklist(_ app: ArrApp) async throws
}

/// The history event types worth filtering on, as the PWA's chips.
public let historyEventTypes = ["fetched", "imported", "failed", "deleted"]

/// Merged history across both arrs, paged with append; filters are local
/// because every page is already on the device.
@MainActor @Observable
public final class HistoryModel {
    public var appFilter: ArrApp?
    public var eventFilter: String?
    public private(set) var items: [HistoryItem] = []
    public private(set) var hasMore = false
    public private(set) var loading = false
    public private(set) var error: String?
    public private(set) var blocklist: Loadable<[BlocklistItem]> = .loading
    public var actionError: String?
    public private(set) var busy = false

    private let api: any HistoryAPI
    private var page = 0

    public init(api: any HistoryAPI) {
        self.api = api
    }

    public var shown: [HistoryItem] {
        items.filter { item in
            (appFilter == nil || item.app == appFilter!.rawValue)
                && (eventFilter == nil || (item.events ?? []).contains { $0._type == eventFilter })
        }
    }

    /// Which arrs have blocklist entries, for the per-arr clear buttons.
    public var blockedApps: [ArrApp] {
        ArrApp.allCases.filter { app in (blocklist.value ?? []).contains { $0.arr == app } }
    }

    public func load() async {
        page = 0
        items = []
        await loadMore()
    }

    public func loadMore() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let result = try await api.historyPage(page + 1)
            page += 1
            items = page == 1 ? result.items : items + result.items
            hasMore = result.has_more ?? false
            error = nil
        } catch {
            self.error = (error as? APIError)?.description ?? error.localizedDescription
        }
    }

    public func loadBlocklist() async {
        do {
            blocklist = .loaded(try await api.blocklist().items ?? [])
        } catch {
            if blocklist.value == nil { blocklist = .failed((error as? APIError)?.description ?? error.localizedDescription) }
        }
    }

    /// Releases arrdeck's own blocklist-and-retry sent here. Without this the
    /// list only ever grew, and a mistakenly blocked release stayed blocked.
    public func unblock(_ item: BlocklistItem) async {
        guard let app = item.arr else { return }
        await perform { try await api.removeFromBlocklist(app, id: item.id) }
        await loadBlocklist()
    }

    public func clearBlocklist(_ app: ArrApp) async {
        await perform { try await api.clearBlocklist(app) }
        await loadBlocklist()
    }

    private func perform(_ work: @Sendable () async throws -> Void) async {
        busy = true
        defer { busy = false }
        do {
            try await work()
        } catch {
            actionError = (error as? APIError)?.description ?? error.localizedDescription
        }
    }
}

// MARK: - Stats
