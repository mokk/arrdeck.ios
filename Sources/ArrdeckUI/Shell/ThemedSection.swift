import SwiftUI

/// SwiftUI's Section, with the palette's card colour behind each row.
///
/// Declared in this module, so every `Section { … }` here resolves to it
/// rather than to SwiftUI's; a row background set on the List itself does not
/// reach the rows, and threading it through 150 sections by hand would drift.
/// Under arrdeck's own colours it is SwiftUI's section, unchanged.
struct Section<Parent: View, Content: View, Footer: View>: View {
    let content: Content
    let header: Parent
    let footer: Footer
    @Environment(\.themedRowBackground) private var themed

    var body: some View {
        SwiftUI.Section {
            if themed {
                content.listRowBackground(Color.card)
            } else {
                content
            }
        } header: {
            header
        } footer: {
            footer
        }
    }
}

extension Section {
    init(@ViewBuilder content: () -> Content, @ViewBuilder header: () -> Parent, @ViewBuilder footer: () -> Footer) {
        self.content = content()
        self.header = header()
        self.footer = footer()
    }
}

extension Section where Footer == EmptyView {
    init(@ViewBuilder content: () -> Content, @ViewBuilder header: () -> Parent) {
        self.init(content: content, header: header, footer: { EmptyView() })
    }
}

extension Section where Parent == EmptyView {
    init(@ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        self.init(content: content, header: { EmptyView() }, footer: footer)
    }
}

extension Section where Parent == EmptyView, Footer == EmptyView {
    init(@ViewBuilder content: () -> Content) {
        self.init(content: content, header: { EmptyView() }, footer: { EmptyView() })
    }
}

extension Section where Parent == Text, Footer == EmptyView {
    init(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.init(content: content, header: { Text(title) }, footer: { EmptyView() })
    }

    @_disfavoredOverload
    init<S: StringProtocol>(_ title: S, @ViewBuilder content: () -> Content) {
        self.init(content: content, header: { Text(title) }, footer: { EmptyView() })
    }
}
