import ArrdeckData
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// The chrome over the selected tab's page: the tab bar, the page's actions in
/// a column at the bottom right and, on a pushed screen, a back button at the
/// bottom left. There is no navigation bar on these pages. Scrolling down folds
/// the tab bar into one icon and hides the rest; a deliberate scroll up brings
/// them back (ChromeScroll decides).
@Observable @MainActor final class ChromeModel {
    @ObservationIgnored private var scroll = ChromeScroll()
    /// Only the selected tab's page counts; the others stay mounted and may
    /// still lay out.
    @ObservationIgnored private(set) var selected: AppTab?
    /// Copied from `scroll` only when it changes, so the bar and the columns
    /// are not redrawn on every frame of a scroll.
    private var scrolledOut = true
    /// Always out: VoiceOver is running, or the iPad's sidebar has the tabs.
    var pinned = false
    /// Where the tab bar's top edge is on screen; 0 without one (the iPad's
    /// sidebar). The bar's inset does not reach the pages inside the tabs'
    /// navigation stacks, so what floats over a page, and its bottom margin,
    /// measure themselves against this instead.
    var barTop: CGFloat = 0

    /// How far something whose bottom edge is at `bottom` on screen must rise
    /// to clear the tab bar.
    func lift(from bottom: CGFloat) -> CGFloat {
        barTop > 0 && !typing ? max(0, bottom - barTop) : 0
    }

    var isExpanded: Bool { pinned || scrolledOut }
    /// A page's search field has the keyboard: the tab bar and the floating
    /// buttons step aside, and the field sits right on the keyboard.
    var typing = false
    /// What floats over the page: out, and not while typing.
    var showsFloating: Bool { isExpanded && !typing }

    func select(_ tab: AppTab) {
        selected = tab
        // a quick action can switch tabs under a search field's keyboard; the
        // hidden tab's field never hears that it lost the screen
        typing = false
        reset()
    }

    /// Out again: the folded icon was tapped, or another screen appeared.
    func reset() {
        scroll.reset()
        publish()
    }

    func report(_ sample: ChromeScroll.Sample, from tab: AppTab) {
        guard tab == selected else { return }
        scroll.scrolled(to: sample)
        publish()
    }

    private func publish() {
        guard scroll.expanded != scrolledOut else { return }
        #if os(iOS)
        let animation: Animation = UIAccessibility.isReduceMotionEnabled ? .easeInOut(duration: 0.2) : .snappy(duration: 0.3)
        #else
        let animation: Animation = .snappy(duration: 0.3)
        #endif
        withAnimation(animation) { scrolledOut = scroll.expanded }
    }
}

extension EnvironmentValues {
    /// Nil outside the server shell.
    @Entry var chrome: ChromeModel?
    /// The tab whose stack this view is in; nil in a sheet, which keeps its
    /// own navigation bar with Cancel and Done.
    @Entry var chromeTab: AppTab?
    /// The page's bottom margin is already there, from a modifier further out.
    @Entry var chromeMarginApplied = false
    /// The page's search field is open at the bottom; its actions sit above it.
    @Entry var chromeSearchOpen = false
    /// A detail page's title with no navigation bar to show it: its hero card
    /// shows it instead.
    @Entry var chromeTitle: ChromeTitle?
}

struct ChromeTitle {
    let text: String
    /// Beside the title: what the navigation bar's toolbar held (Plex's
    /// watched dot).
    let accessory: AnyView
}

extension View {
    /// A sheet's stack: its pages keep their navigation bar and toolbar, and
    /// their scrolling moves nothing behind the sheet.
    func outsideChrome() -> some View {
        environment(\.chromeTab, nil).environment(\.chromeTitle, nil)
    }

    /// A page in a tab's stack: no navigation bar, its scrolling folds the
    /// chrome, and a pushed one gets the back button. Apply it to the page's
    /// scroll view; a page whose scroll view sits further in passes
    /// `reportsScroll: false` and puts `reportsChromeScroll()` on that.
    /// `title`, when given, goes to the page's hero card (DetailHero) with
    /// `accessory` beside it.
    func chromePage<Accessory: View>(title: String? = nil, reportsScroll: Bool = true,
                                     @ViewBuilder accessory: () -> Accessory = { EmptyView() }) -> some View {
        modifier(ChromePage(reportsScroll: reportsScroll,
                            title: title.map { ChromeTitle(text: $0, accessory: AnyView(accessory())) }))
    }

    /// Folds the chrome as this scroll view scrolls, while it is on screen in
    /// the selected tab. Needs iOS 18; before that the chrome stays out.
    func reportsChromeScroll(_ enabled: Bool = true) -> some View {
        modifier(OptionalScrollReporter(enabled: enabled))
    }

    /// A margin the tab bar's height under the page's last row, so it scrolls
    /// clear of the bar and the buttons floating over the page instead of
    /// stopping right against them. Only in a tab's stack, and only once
    /// however many times it is applied; padding rather than a content margin,
    /// so a horizontal row of posters inside the page does not grow too.
    func chromeBottomMargin() -> some View {
        modifier(ChromeBottomMargin())
    }

    /// The page's filter field. In a tab's stack a field pinned at the
    /// bottom, opened by the page's own magnifier (`isPresented`), within reach
    /// of the thumb and in sight of the results while scrolling; `accessory`
    /// sits in the field. In a sheet, the system's search bar.
    func chromeSearch<Accessory: View>(text: Binding<String>, isPresented: Binding<Bool>, prompt: Text,
                                       @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() }) -> some View {
        modifier(ChromeSearch(text: text, isPresented: isPresented, prompt: prompt, accessory: accessory))
    }

    /// The page's actions: a column of glass circles at the bottom right in a
    /// tab's stack, the toolbar in a sheet or when not `floating` (a page
    /// that still has its navigation bar). The last one sits nearest the thumb.
    func chromeActions<Actions: View>(floating: Bool = true, @ViewBuilder _ actions: @escaping () -> Actions) -> some View {
        modifier(ChromeActions(floating: floating, actions: actions))
    }
}

private struct ChromePage: ViewModifier {
    let reportsScroll: Bool
    let title: ChromeTitle?
    @Environment(\.chrome) private var chrome
    @Environment(\.chromeTab) private var tab
    /// True on a screen pushed over the stack's first one.
    @Environment(\.isPresented) private var pushed
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if let chrome, let tab {
            content
                .environment(\.chromeTitle, title)
                #if os(iOS)
                .toolbar(.hidden, for: .navigationBar)
                #endif
                .reportsChromeScroll(reportsScroll)
                .floatingAboveBar(alignment: .bottomLeading) {
                    if pushed, chrome.showsFloating {
                        Button { dismiss() } label: {
                            Label("Back", systemImage: "chevron.backward")
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(ChromeCircleStyle())
                        .accessibilityIdentifier("chrome-back")
                        .padding(.leading, ChromeMetrics.edge)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .leading)))
                    }
                }
                // a screen pushed or popped starts with everything out
                .onAppear { if chrome.selected == tab { chrome.reset() } }
        } else {
            content
        }
    }
}

private struct OptionalScrollReporter: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled { content.modifier(ChromeScrollReporter()) } else { content }
    }
}

private struct ChromeBottomMargin: ViewModifier {
    @Environment(\.chrome) private var chrome
    @Environment(\.chromeTab) private var tab
    @Environment(\.chromeMarginApplied) private var applied
    /// The page's bottom edge on screen.
    @State private var bottom: CGFloat = 0

    func body(content: Content) -> some View {
        if let chrome, tab != nil, !applied {
            content
                .environment(\.chromeMarginApplied, true)
                .safeAreaPadding(.bottom, chrome.lift(from: bottom) + ChromeMetrics.circle)
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { bottom = $0 }
        } else {
            content
        }
    }
}

private struct ChromeScrollReporter: ViewModifier {
    @Environment(\.chrome) private var chrome
    @Environment(\.chromeTab) private var tab
    /// A page with another pushed over it stays mounted and can still lay out
    /// (a reload); only the one on screen counts.
    @State private var onScreen = false

    func body(content: Content) -> some View {
        if let chrome, let tab {
            if #available(iOS 18, macOS 15, *) {
                content.chromeBottomMargin().onScrollGeometryChange(for: ChromeScroll.Sample.self) { geometry in
                    let insets = geometry.contentInsets
                    return ChromeScroll.Sample(
                        offset: geometry.contentOffset.y + insets.top,
                        maxOffset: geometry.contentSize.height + insets.top + insets.bottom - geometry.containerSize.height,
                        contentHeight: geometry.contentSize.height
                    )
                } action: { _, sample in
                    if onScreen { chrome.report(sample, from: tab) }
                }
                .onAppear { onScreen = true }
                .onDisappear { onScreen = false }
            } else {
                content.chromeBottomMargin()
            }
        } else {
            content
        }
    }
}

private struct ChromeActions<Actions: View>: ViewModifier {
    let floating: Bool
    @ViewBuilder let actions: () -> Actions
    @Environment(\.chromeSearchOpen) private var searchOpen
    @Environment(\.chrome) private var chrome
    @Environment(\.chromeTab) private var tab
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if let chrome, tab != nil, floating {
            content.floatingAboveBar(alignment: .bottomTrailing) {
                if chrome.showsFloating {
                    VStack(spacing: 10) { actions() }
                        .labelStyle(.iconOnly)
                        .buttonStyle(ChromeCircleStyle())
                        .menuStyle(.button)
                        .padding(.trailing, ChromeMetrics.edge)
                        // above the search field while it is open
                        .padding(.bottom, searchOpen ? ChromeMetrics.circle + 10 : 0)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .trailing)))
                }
            }
        } else {
            content.toolbar {
                ToolbarItemGroup(placement: .primaryAction) { actions() }
            }
        }
    }
}

extension View {
    /// Floats `content` at the bottom of the page, just above the tab bar.
    func floatingAboveBar<Floating: View>(alignment: Alignment,
                                          @ViewBuilder _ content: @escaping () -> Floating) -> some View {
        modifier(FloatingAboveBar(alignment: alignment, floating: content))
    }
}

/// Hangs from a zero-height inset at the page's bottom, so it adds nothing to
/// the page's scrolling, and rises by however much the tab bar covers there.
/// Its own accessibility container, so the page's identifier does not replace
/// the buttons' own.
private struct FloatingAboveBar<Floating: View>: ViewModifier {
    let alignment: Alignment
    @ViewBuilder let floating: () -> Floating
    @Environment(\.chrome) private var chrome
    @State private var bottom: CGFloat = 0

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: 0)
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { bottom = $0 }
                .overlay(alignment: alignment) {
                    // aligned by its bottom to the zero height, it rises above it
                    floating()
                        .padding(.bottom, (chrome?.lift(from: bottom) ?? 0) + ChromeMetrics.aboveBar)
                }
                .accessibilityElement(children: .contain)
        }
    }
}

/// The status bar's area, fading the page out under the clock: with no
/// navigation bar nothing else separates them.
struct StatusBarScrim: View {
    var body: some View {
        // 14pt under the status bar, and the background grows up under it to
        // the screen's edge: no need to know how tall the status bar is
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: 14)
            .background(alignment: .bottom) {
                LinearGradient(stops: [.init(color: Color.grouped, location: 0),
                                       .init(color: Color.grouped.opacity(0.9), location: 0.6),
                                       .init(color: Color.grouped.opacity(0), location: 1)],
                               startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea(edges: .top)
            }
            .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

#if os(iOS)
/// The swipe back from the edge, and on iOS 26 from anywhere on the page,
/// which UIKit turns off with the navigation bar hidden: allowed whenever
/// there is a screen to go back to.
extension UINavigationController: @retroactive UIGestureRecognizerDelegate {
    override open func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
        if #available(iOS 26, *) {
            interactiveContentPopGestureRecognizer?.delegate = self
        }
    }

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        viewControllers.count > 1
    }
}
#endif

private struct ChromeSearch<Accessory: View>: ViewModifier {
    @Binding var text: String
    @Binding var isPresented: Bool
    let prompt: Text
    @ViewBuilder let accessory: () -> Accessory
    @Environment(\.chrome) private var chrome
    @Environment(\.chromeTab) private var tab
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        if let chrome, tab != nil {
            content
                .environment(\.chromeSearchOpen, isPresented)
                .scrollDismissesKeyboard(.immediately)
                .floatingAboveBar(alignment: .bottom) {
                    if isPresented, chrome.showsFloating || focused {
                        field
                            .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)))
                    }
                }
                .onChange(of: isPresented) { _, open in focused = open }
                .onChange(of: focused) { _, focused in
                    withAnimation(.snappy(duration: 0.25)) { chrome.typing = focused }
                }
                // another tab or screen took over with the keyboard up
                .onDisappear { if focused { chrome.typing = false } }
        } else {
            content.searchable(text: $text, prompt: prompt)
        }
    }

    var field: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(text: $text, prompt: prompt) { prompt }
                .focused($focused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .accessibilityIdentifier("chrome-search-field")
            accessory()
                .labelStyle(.iconOnly)
            Button {
                text = ""
                focused = false
                isPresented = false
            } label: {
                Label("Close search", systemImage: "xmark.circle.fill")
            }
            .labelStyle(.iconOnly)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("chrome-search-close")
        }
        .font(.body)
        .padding(.horizontal, 18)
        .frame(height: ChromeMetrics.circle)
        .liquidGlass(Capsule())
        .padding(.horizontal, ChromeMetrics.edge)
        .frame(maxWidth: .infinity)
    }
}

/// A page's title at the top of its content, for a page that is not a List
/// and has no hero card to carry it (a person, Subtitles); it scrolls away
/// with the page. Nothing outside a tab's stack, where the navigation bar
/// still shows the title.
struct PageHeading: View {
    let title: String
    var horizontal: CGFloat = .pageMargin
    @Environment(\.chromeTab) private var tab

    var body: some View {
        if tab != nil {
            Text(title)
                .font(.largeTitle.bold())
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, horizontal)
                .padding(.top, 4)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("page-title")
        }
    }
}

/// A page's title as the first row of its List, in place of the navigation
/// bar's: the pages inside Settings, where the tab bar only shows the gear.
/// It scrolls away with the page. Nothing outside a tab's stack, where the
/// bar still shows the title.
struct ListPageHeading: View {
    let title: String
    @Environment(\.chromeTab) private var tab

    var body: some View {
        if tab != nil {
            Section {
            } header: {
                Text(title)
                    .font(.largeTitle.bold())
                    // the colour itself: `.primary` here is the header's dimmed one
                    .foregroundStyle(Color.primary)
                    .textCase(nil)
                    .lineLimit(2)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("page-title")
            }
        }
    }
}

enum ChromeMetrics {
    /// From the screen's side, as the tab bar.
    static let edge: CGFloat = 20
    /// Between the tab bar and what floats above it.
    static let aboveBar: CGFloat = 12
    static let circle: CGFloat = 50

    /// What a column of `count` actions and the tab bar take at the bottom
    /// of a page, for what else runs down its side (the letter strip).
    static func column(_ count: Int) -> CGFloat {
        CGFloat(count) * circle + CGFloat(max(count - 1, 0)) * 10 + aboveBar + circle + 16
    }
}

/// A glass circle holding one icon, the size of the tab bar's height. Takes
/// the tint (Throttle turns orange) and dims while disabled.
struct ChromeCircleStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 19, weight: .medium))
            .foregroundStyle(.tint)
            .opacity(isEnabled ? 1 : 0.4)
            .frame(width: ChromeMetrics.circle, height: ChromeMetrics.circle)
            .contentShape(Circle())
            .liquidGlass(Circle())
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}
