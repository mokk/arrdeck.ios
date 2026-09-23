import ArrdeckData
import SwiftUI

/// The full-width bottom bar. The system tab bar on iOS 26 is a floating
/// capsule with no switch to change that, so the chrome is ours; the
/// TabView underneath still keeps each tab's navigation stack alive.
struct AppTabBar: View {
    let tabs: [AppTab]
    @Binding var selected: AppTab

    var body: some View {
        HStack(spacing: 0) {
            ForEach(tabs, id: \.self) { tab in
                Button {
                    selected = tab
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 21, weight: .regular))
                            .symbolVariant(selected == tab ? .fill : .none)
                        Text(tab.label).font(.system(size: 10, weight: selected == tab ? .semibold : .regular))
                    }
                    .foregroundStyle(selected == tab ? Color.accentColor : Color.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("tab-\(tab.rawValue)")
                .accessibilityAddTraits(selected == tab ? [.isSelected] : [])
            }
        }
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

extension View {
    /// Hides the system tab bar under our own; macOS has none to hide.
    func hiddenSystemTabBar() -> some View {
        #if os(iOS)
        toolbar(.hidden, for: .tabBar)
        #else
        self
        #endif
    }
}
