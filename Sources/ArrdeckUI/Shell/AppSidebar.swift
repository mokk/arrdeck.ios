import ArrdeckData
import SwiftUI

/// The tabs down the side on an iPad at regular width, in the capsule's order
/// with the same badges. Buttons rather than a List selection: tapping the
/// row that is already selected never reaches a selection binding, and that
/// tap is what returns a tab to its first screen.
struct AppSidebar: View {
    let title: String
    let tabs: [AppTab]
    let selected: AppTab
    var badges: [AppTab: Int] = [:]
    let tap: (AppTab) -> Void
    /// The signature's end once it is close: its strip sits under the tabs
    /// here, where on a phone it floats above the capsule.
    var expiry: Date?

    /// Narrow enough that an 11-inch iPad in portrait still gets four posters
    /// across beside it; at 300 the grid dropped to three oversized ones.
    static let width: CGFloat = 260

    var body: some View {
        // its own stack only for the heading on the toolbar's line; nothing is pushed here
        NavigationStack {
            List {
                ForEach(tabs, id: \.self) { tab in
                    Button { tap(tab) } label: {
                        Label(tab.label, systemImage: tab.symbol)
                            .symbolVariant(selected == tab ? .fill : .none)
                            .foregroundStyle(selected == tab ? Color.accent : Color.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .badge(badges[tab] ?? 0)
                    .listRowBackground(
                        // the capsule's selected pill, as a sidebar row
                        selected == tab ? RoundedRectangle(cornerRadius: 10).fill(Color.accent.opacity(0.14)) : nil
                    )
                    .accessibilityIdentifier("tab-\(tab.rawValue)")
                    .accessibilityAddTraits(selected == tab ? [.isSelected] : [])
                }
            }
            .listStyle(.sidebar)
            .navigationTitle(title)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let expiry { ExpiryStrip(expiry: expiry).padding(.bottom, 8) }
            }
        }
        .frame(width: Self.width)
    }
}
