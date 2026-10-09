import ArrdeckData
import SwiftUI

/// A floating Liquid Glass capsule of icons. Our own rather than the system
/// TabView's bar: that one folds a sixth tab into "More" on iPhone, and popping
/// a screen pushed in the sixth tab landed there instead of on the tab's root.
/// The names stay as accessibility labels, since only the icons show.
struct AppTabBar: View {
    let tabs: [AppTab]
    @Binding var selected: AppTab
    var badges: [AppTab: Int] = [:]
    /// The tab that was already showing was tapped again.
    var reselect: (AppTab) -> Void = { _ in }
    @Namespace private var selection

    var body: some View {
        HStack(spacing: 0) {
            ForEach(tabs, id: \.self) { tab in
                Button {
                    if selected == tab {
                        reselect(tab)
                    } else {
                        withAnimation(.snappy(duration: 0.25)) { selected = tab }
                    }
                } label: {
                    Image(systemName: tab.symbol)
                        .font(.system(size: 19, weight: .medium))
                        .symbolVariant(selected == tab ? .fill : .none)
                        .foregroundStyle(selected == tab ? Color.accent : Color.primary)
                        .overlay(alignment: .topTrailing) { badge(tab) }
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background {
                            // the selected tab's pill, sliding between tabs
                            if selected == tab {
                                Capsule().fill(Color.accent.opacity(0.14))
                                    .padding(.vertical, 5)
                                    .matchedGeometryEffect(id: "selected", in: selection)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.label)
                .accessibilityIdentifier("tab-\(tab.rawValue)")
                .accessibilityAddTraits(selected == tab ? [.isSelected] : [])
            }
        }
        .padding(.horizontal, 5)
        .liquidGlassCapsule()
        .padding(.horizontal, 20)
        .padding(.bottom, 2)
    }

    @ViewBuilder func badge(_ tab: AppTab) -> some View {
        if let count = badges[tab], count > 0 {
            Text(count > 99 ? "99+" : String(count))
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(Color.accent, in: Capsule())
                .offset(x: 11, y: -7)
                .accessibilityLabel("\(count) new")
        }
    }
}

extension View {
    /// Liquid Glass where the OS has it (26 and later); a material capsule
    /// with a soft shadow before that.
    @ViewBuilder func liquidGlassCapsule() -> some View {
        if #available(iOS 26, macOS 26, *) {
            glassEffect(.regular.interactive(), in: .capsule)
        } else {
            background(.regularMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        }
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
