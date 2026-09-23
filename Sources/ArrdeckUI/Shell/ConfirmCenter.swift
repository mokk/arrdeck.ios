import ArrdeckData
import SwiftUI

/// One "are you sure?" for the whole app, governed by Settings → Display:
/// ask before every action, only before deleting, or never. Actions go
/// through `run`, which performs them straight away when the policy does not
/// ask, and otherwise holds them until the dialog at the root answers.
@MainActor @Observable
final class ConfirmCenter {
    struct Pending: Identifiable {
        let id = UUID()
        let action: String
        let subject: String?
        let destructive: Bool
        let perform: @MainActor () async -> Void
    }

    var pending: Pending?

    func run(_ action: String, subject: String? = nil, destructive: Bool = false,
             perform: @escaping @MainActor () async -> Void) {
        let policy = UserDefaults.standard.pref(DisplayKeys.confirm, default: ConfirmPolicy.deletes)
        if policy.asks(destructive: destructive) {
            pending = Pending(action: action, subject: subject, destructive: destructive, perform: perform)
        } else {
            Task { await perform() }
        }
    }
}

extension EnvironmentValues {
    /// Nil outside the server shell; `ask` then simply performs.
    @Entry var confirmCenter: ConfirmCenter?
}

extension View {
    /// Where the dialog is shown: the root of the tab shell.
    func confirmDialog(_ center: ConfirmCenter) -> some View {
        environment(\.confirmCenter, center)
            .confirmationDialog(
                Text(verbatim: center.pending.map { "\($0.action)?" } ?? ""),
                isPresented: Binding(get: { center.pending != nil }, set: { if !$0 { center.pending = nil } }),
                titleVisibility: .visible,
                presenting: center.pending
            ) { pending in
                Button(pending.action, role: pending.destructive ? .destructive : nil) {
                    Task { await pending.perform() }
                }
                Button("Cancel", role: .cancel) {}
            } message: { pending in
                if let subject = pending.subject { Text(subject) }
            }
    }
}

/// Runs an action through the confirm center when there is one.
@MainActor
func ask(_ center: ConfirmCenter?, _ action: String, subject: String? = nil, destructive: Bool = false,
         perform: @escaping @MainActor () async -> Void) {
    if let center {
        center.run(action, subject: subject, destructive: destructive, perform: perform)
    } else {
        Task { await perform() }
    }
}
