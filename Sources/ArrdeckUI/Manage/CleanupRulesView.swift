import ArrdeckData
import SwiftUI

/// Cleanup → Rules: the switch that lets rules delete, the rules, what is
/// leaving soon, the keep list and the run log. Anything that switches
/// deleting on, lets it delete more or deletes now asks first (the model
/// decides which); turning things off and test runs do not.
struct CleanupRulesView<Header: View>: View {
    @Bindable var model: CleanupRulesModel
    let tags: (any ManageAPI)?
    let baseURL: URL
    @ViewBuilder let header: () -> Header
    @Environment(\.confirmCenter) private var confirmCenter
    @State private var editing: EditingRule?

    struct EditingRule: Identifiable {
        let id = UUID()
        let draft: RuleDraft
    }

    var body: some View {
        List {
            header()
            switch model.rules {
            case .loading: Section { LoadingRow() }
            case let .failed(reason): Section { ErrorNote(reason) }
            case .loaded:
                switchSection
                rulesSection
                leavingSection
                keptSection
                logSection
            }
        }
        .dashboardListStyle()
        .task { await model.load() }
        .refreshable { await model.load() }
        .sheet(item: $editing, onDismiss: { model.resetPreview() }) { item in
            RuleEditorSheet(draft: item.draft, model: model, tags: tags, baseURL: baseURL) { editing = nil }
        }
        .sheet(item: Binding(get: { model.result.map(RunResult.init) }, set: { if $0 == nil { model.result = nil } })) { item in
            RunResultSheet(run: item.run) { model.result = nil }
                .presentationDetents([.medium, .large])
        }
        .alert("Action failed", isPresented: Binding(
            get: { model.error != nil && editing == nil }, set: { if !$0 { model.error = nil } }
        )) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }

    /// Runs `perform`, behind a destructive confirmation when the model says
    /// this change needs one.
    func change(_ change: CleanupRulesModel.Change, _ action: String, subject: String? = nil,
                perform: @escaping @MainActor () async -> Void) {
        if model.asks(change) {
            ask(confirmCenter, action, subject: subject, destructive: true, always: true, perform: perform)
        } else {
            Task { await perform() }
        }
    }

    // MARK: The switch

    var switchSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { model.enabled },
                set: { on in
                    change(.cleanup(on: on), String(localized: "Turn on automatic cleanup"),
                           subject: String(localized: "Switched-on rules start marking titles at the next run. They are deleted after their grace period unless you keep them.")) {
                        await model.setCleanup(on: on)
                    }
                }
            )) {
                Text("Automatic cleanup").font(.subheadline.weight(.semibold))
            }
            .tint(Color.danger)
            .disabled(model.saving)
            VStack(alignment: .leading, spacing: 6) {
                Text("When on, the rules below are checked once a day. A title that matches is marked as leaving, shown in Plex in a “Leaving soon” collection, and announced by a push notification (the Cleanup event). When its grace period is over it is checked again with fresh data, and only if it still matches are its files deleted through Radarr or Sonarr, which also keep it off their import lists.")
                Text("Never touched: anything added in the last 30 days, anything with an open request, and anything you keep. If Plex, Radarr, Sonarr or Overseerr can't be reached, the day's run is skipped, and no run deletes more than the limit below.")
                Text(model.enabled
                     ? "On. Turning it off releases everything that is leaving."
                     : "Off, as it starts: nothing is marked or deleted, whatever the rules say. Previews and test runs still work.")
                    .fontWeight(.semibold)
                    .foregroundStyle(model.enabled ? Color.danger : Color.primary)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Picker("Deletes at most", selection: Binding(
                get: { model.maxDeletions },
                set: { limit in
                    change(.limit(limit), String(localized: "Allow \(limit) deletions per run"),
                           subject: String(localized: "Each run may delete more titles.")) {
                        await model.setLimit(limit)
                    }
                }
            )) {
                ForEach(model.limitChoices, id: \.self) { Text("\($0) per run").tag($0) }
            }
            .disabled(model.saving)
            HStack {
                Button("Test run") { Task { await model.run(dry: true) } }
                    .buttonStyle(.bordered)
                if model.enabled {
                    Button("Run now", role: .destructive) {
                        change(.run(dry: false), String(localized: "Run now"),
                               subject: String(localized: "Titles whose date has passed, and that still match, are deleted now.")) {
                            await model.run(dry: false)
                        }
                    }
                    .buttonStyle(.bordered)
                    .tint(Color.danger)
                }
                Spacer()
                if model.running { ProgressView().controlSize(.small) }
            }
            .disabled(model.running)
        } header: {
            Text("Automatic cleanup")
        } footer: {
            Text("A test run shows what a run would do now and changes nothing.")
        }
    }

    // MARK: Rules

    var rulesSection: some View {
        Section {
            let drafts = model.drafts
            if drafts.isEmpty { EmptyNote(String(localized: "No rules yet. A new rule starts switched off.")) }
            ForEach(drafts, id: \.id) { draft in
                HStack(spacing: 10) {
                    Button { editing = EditingRule(draft: draft) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(draft.title) · \(draft.kind.label)").font(.subheadline.weight(.medium)).lineLimit(1)
                            Text("\(draft.summary) · \(draft.graceDays) d grace").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Toggle(isOn: Binding(
                        get: { draft.enabled },
                        set: { on in
                            change(.rule(on: on), String(localized: "Switch the rule on"),
                                   subject: String(localized: "\(draft.title): what it matches is marked at the next run and deleted \(draft.graceDays) days later, unless it stops matching or you keep it.")) {
                                await model.setRule(draft.id, on: on)
                            }
                        }
                    )) { Text(draft.title) }
                    .labelsHidden()
                    .tint(Color.danger)
                    .disabled(model.saving)
                }
            }
            Button { editing = EditingRule(draft: RuleDraft()) } label: { Label("Add rule", systemImage: "plus") }
                .disabled(!model.canAddRule)
        } header: {
            Text("Rules")
        } footer: {
            if !model.canAddRule { Text("A server keeps at most \(RuleDraft.maxRules) rules.") }
        }
    }

    // MARK: Leaving soon

    var leavingSection: some View {
        Section("Leaving soon") {
            switch model.leaving {
            case .loading: LoadingRow()
            case let .failed(reason): ErrorNote(reason)
            case let .loaded(items):
                if items.isEmpty { EmptyNote(String(localized: "Nothing is leaving.")) }
                ForEach(items, id: \.key) { item in
                    HStack(spacing: 10) {
                        NavigationLink(value: item.ref) {
                            HStack(spacing: 10) {
                                Poster(path: item.poster, baseURL: baseURL, width: 34, cornerRadius: 5, title: item.title ?? "")
                                VStack(alignment: .leading, spacing: 2) {
                                    Text([item.title ?? "", item.year.map(String.init) ?? ""].filter { !$0.isEmpty }.joined(separator: " "))
                                        .font(.subheadline.weight(.medium)).lineLimit(1)
                                    Text("\(CleanupWords.countdown(item.leave_at)) · \(Format.bytes(item.size ?? 0))")
                                        .font(.caption.weight(.semibold)).foregroundStyle(Color.danger)
                                    Text(([item.rule_name ?? ""] + (item.reasons ?? []).map(CleanupWords.reason)).filter { !$0.isEmpty }.joined(separator: " · "))
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                        Button("Keep") {
                            Task { await model.keep(item.cleanupKind, id: item.id, title: item.title ?? "", year: item.year) }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(model.keeping.contains(item.key))
                        .accessibilityLabel(Text("Keep \(item.title ?? "")"))
                    }
                }
            }
        }
    }

    // MARK: Keep list

    var keptSection: some View {
        Section {
            switch model.kept {
            case .loading: LoadingRow()
            case let .failed(reason): ErrorNote(reason)
            case let .loaded(items):
                if items.isEmpty { EmptyNote(String(localized: "Nothing kept.")) }
                ForEach(items, id: \.key) { item in
                    HStack {
                        Text([item.label, item.year.map(String.init) ?? ""].filter { !$0.isEmpty }.joined(separator: " "))
                            .font(.subheadline).lineLimit(1)
                        Spacer()
                        Button {
                            change(.unkeep, String(localized: "Take off the keep list"), subject: item.label) {
                                await model.unkeep(item)
                            }
                        } label: { Image(systemName: "xmark.circle") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .disabled(model.keeping.contains(item.key))
                        .accessibilityLabel(Text("Take \(item.label) off the keep list"))
                    }
                }
                if !items.isEmpty {
                    Button("Clear the keep list", role: .destructive) {
                        change(.clearKept, String(localized: "Clear the keep list"),
                               subject: String(localized: "The rules may match these titles again.")) {
                            await model.clearKept()
                        }
                    }
                }
            }
        } header: {
            Text("Keep list")
        } footer: {
            Text("No rule will match these again.")
        }
    }

    // MARK: Run log

    var logSection: some View {
        Section("Run log") {
            switch model.log {
            case .loading: LoadingRow()
            case let .failed(reason): ErrorNote(reason)
            case let .loaded(runs):
                if runs.isEmpty { EmptyNote(String(localized: "No runs yet.")) }
                ForEach(Array(runs.enumerated()), id: \.offset) { _, run in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(Date(timeIntervalSince1970: TimeInterval(run.ts)).formatted(date: .abbreviated, time: .shortened)) · \(CleanupWords.trigger(run.trigger))")
                            .font(.caption.weight(.semibold))
                        RunSummary(run: run, expanded: false)
                    }
                }
            }
        }
    }
}

private struct RunResult: Identifiable {
    let run: CleanupRun
    var id: Int { run.ts }
}

/// What a run did, by group; the sheet after a run opens every group.
struct RunSummary: View {
    let run: CleanupRun
    let expanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let skipped = run.skipped {
                Text(CleanupWords.skipped(skipped)).foregroundStyle(Color.danger)
            } else if run.didNothing {
                Text("Nothing to do.").foregroundStyle(.secondary)
            }
            ForEach(Array(run.groups.enumerated()), id: \.offset) { _, group in
                Group {
                    if expanded {
                        Text(group.label).fontWeight(.semibold)
                        titles(group.items)
                    } else {
                        DisclosureGroup(group.label) { titles(group.items) }
                    }
                }
            }
            if let deferred = run.deferred, deferred > 0 {
                Text("\(deferred) due, waiting for the next run (limit per run)").foregroundStyle(.secondary)
            }
            ForEach(Array((run.errors ?? []).enumerated()), id: \.offset) { _, error in
                Text(error).foregroundStyle(Color.danger)
            }
        }
        .font(.caption)
    }

    func titles(_ items: [CleanupLogTitle]) -> some View {
        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
            Text(line(item)).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    func line(_ item: CleanupLogTitle) -> String {
        var parts = [[item.title ?? "", item.year.map(String.init) ?? ""].filter { !$0.isEmpty }.joined(separator: " ")]
        parts.append(Format.bytes(item.size ?? 0))
        if let reason = item.reason { parts.append(CleanupWords.released(reason)) }
        return parts.joined(separator: " · ")
    }
}

struct RunResultSheet: View {
    let run: CleanupRun
    let done: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    RunSummary(run: run, expanded: true)
                } header: {
                    if run.dry_run == true { Text("Test run — nothing was changed") }
                } footer: {
                    Text(Date(timeIntervalSince1970: TimeInterval(run.ts)).formatted(date: .abbreviated, time: .standard))
                }
            }
            .themedList()
            .navigationTitle(run.dry_run == true ? "Test run" : "Run")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done", action: done) } }
        }
        .outsideChrome()
    }
}

/// One rule: what it looks at, its conditions, its grace period, and what it
/// would take right now. Saving never switches it on or off — that is the
/// list's own, confirmed, step.
struct RuleEditorSheet: View {
    @State var draft: RuleDraft
    let model: CleanupRulesModel
    let tags: (any ManageAPI)?
    let baseURL: URL
    let done: () -> Void
    /// The sheet asks its own questions: the shell's dialog cannot show over it.
    @State private var confirmCenter = ConfirmCenter()
    @State private var tagList: [LibraryTag] = []
    @State private var failure: String?

    static let previewShown = 30

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Looks at", selection: Binding(get: { draft.kind }, set: { draft.setKind($0) })) {
                        ForEach(CleanupKind.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    TextField("Name", text: $draft.name, prompt: Text("e.g. Watched long ago"))
                }
                conditionsSection
                if !tagList.isEmpty {
                    tagSection(with: false)
                    tagSection(with: true)
                }
                Section {
                    Picker("Grace period", selection: $draft.graceDays) {
                        ForEach(Array(Set(RuleDraft.graceChoices + [draft.graceDays])).sorted(), id: \.self) {
                            Text("\($0) days").tag($0)
                        }
                    }
                } footer: {
                    Text("At least 3 days. Titles stay in “Leaving soon” this long before they go.")
                }
                previewSection
                if !draft.isNew {
                    Section {
                        Button("Delete rule", role: .destructive) {
                            ask(confirmCenter, String(localized: "Delete rule"),
                                subject: String(localized: "\(draft.title): what it marked is released at the next run."),
                                destructive: true, always: true) {
                                if await model.delete(draft.id) { done() } else { takeFailure() }
                            }
                        }
                    }
                }
            }
            .themedList()
            .navigationTitle(draft.isNew ? "New rule" : "Edit rule")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: done) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).disabled(!draft.canSave || model.saving)
                }
            }
            .task(id: draft.probe) {
                // only what decides the matches, a moment after the last edit
                if draft.probe != nil {
                    try? await Task.sleep(for: .milliseconds(700))
                    guard !Task.isCancelled else { return }
                }
                await model.updatePreview(draft)
            }
            .task(id: draft.kind) {
                tagList = (try? await tags?.tags(draft.kind.app)) ?? []
            }
            .alert("Action failed", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("OK") { failure = nil }
            } message: { Text(failure ?? "") }
            .confirmDialog(confirmCenter)
        }
        .outsideChrome()
    }

    var conditionsSection: some View {
        Section {
            ForEach(RuleDraft.Number.allCases, id: \.self) { number in
                Toggle(number.label, isOn: Binding(get: { draft.value(number) != nil }, set: { draft.tick(number, $0) }))
                if let value = draft.value(number) {
                    Picker(number.label, selection: Binding(get: { value }, set: { draft.set(number, $0) })) {
                        ForEach(Array(Set(number.choices + [value])).sorted(), id: \.self) { Text(number.format($0)).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
            }
            Toggle("Unmonitored", isOn: $draft.unmonitored)
        } header: {
            Text("Conditions")
        } footer: {
            Text("A title must meet every condition that is ticked.")
        }
    }

    func tagSection(with: Bool) -> some View {
        Section(with ? "Only with these tags" : "Not with these tags") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: 6)], alignment: .leading, spacing: 6) {
                ForEach(tagList, id: \.id) { tag in
                    let on = draft.has(tag: tag.id, with: with)
                    Button { draft.toggle(tag: tag.id, with: with) } label: {
                        Text(tag.label)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(on ? Color.accent.opacity(0.15) : Color.secondary.opacity(0.12), in: Capsule())
                            .foregroundStyle(on ? Color.accent : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
        }
    }

    var previewSection: some View {
        Section {
            switch model.preview {
            case .idle, .loading:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Asking Plex and the libraries…").foregroundStyle(.secondary)
                }
                .font(.subheadline)
            case .needsCondition:
                EmptyNote(String(localized: "Tick at least one condition — a rule without any matches nothing."))
            case let .failed(reason):
                ErrorNote(reason)
            case let .loaded(preview):
                let matches = preview.matches ?? []
                if let held = CleanupWords.held(preview.held?.additionalProperties ?? [:]) {
                    Text("Held back: \(held)").font(.caption).foregroundStyle(.secondary)
                }
                if matches.isEmpty {
                    EmptyNote(String(localized: "Nothing matches right now."))
                } else {
                    Text(matches.count == 1
                         ? "1 title · \(Format.bytes(preview.total_size ?? 0))"
                         : "\(matches.count) titles · \(Format.bytes(preview.total_size ?? 0))")
                        .font(.subheadline.weight(.semibold))
                    ForEach(matches.prefix(Self.previewShown), id: \.key) { match in
                        matchRow(match)
                    }
                    if matches.count > Self.previewShown {
                        Text("…and \(matches.count - Self.previewShown) more").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Would leave if it ran now")
        }
    }

    func matchRow(_ match: CleanupMatch) -> some View {
        HStack(spacing: 10) {
            Poster(path: match.poster, baseURL: baseURL, width: 30, cornerRadius: 4, title: match.title ?? "")
            VStack(alignment: .leading, spacing: 2) {
                Text([match.title ?? "", match.year.map(String.init) ?? ""].filter { !$0.isEmpty }.joined(separator: " "))
                    .font(.subheadline).lineLimit(1)
                Text(([Format.bytes(match.size ?? 0)]
                      + (match.leave_at.map { [CleanupWords.countdown($0)] } ?? [])
                      + (match.reasons ?? []).map(CleanupWords.reason)).joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            // keeping from the preview protects a title before any rule marks it
            Button("Keep") {
                Task {
                    await model.keep(match.cleanupKind, id: match.id, title: match.title ?? "", year: match.year)
                    if model.error != nil { takeFailure() } else { await model.updatePreview(draft) }
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(model.keeping.contains(match.key))
            .accessibilityLabel(Text("Keep \(match.title ?? "")"))
        }
    }

    func save() {
        let draft = draft
        let perform: @MainActor () async -> Void = {
            if await model.save(draft) { done() } else { takeFailure() }
        }
        if model.asks(.save(enabled: draft.enabled)) {
            ask(confirmCenter, String(localized: "Save rule"),
                subject: String(localized: "\(draft.title) is switched on: the change applies from the next run."),
                destructive: true, always: true, perform: perform)
        } else {
            Task { await perform() }
        }
    }

    /// Errors show in the sheet; the screen behind it cannot present them.
    func takeFailure() {
        failure = model.error
        model.error = nil
    }
}
