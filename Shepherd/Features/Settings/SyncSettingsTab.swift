import ShepherdCore
import ShepherdPersistence
import SwiftUI

/// Sweep interval, notification toggles, and settings sync across Macs (ADR 0014).
///
/// The encrypted sync belongs here rather than in its own pane because it is the same subject as
/// the rest of the page — keeping things in step — just with a different peer: the sweep keeps
/// this Mac in step with GitHub, the sections at the bottom keep it in step with the user's other
/// Macs.
struct SyncSettingsTab: View {
    @Environment(AppEnvironment.self) private var environment
    /// The encrypted settings-sync model, owned by ``SettingsView``.
    let syncModel: SettingsSyncModel
    /// The outbox rows the drain gave up on, listed one by one in the Outbox section.
    ///
    /// Fetched rather than observed, and keyed on ``SignedInSession/failedOutboxCount``, which is
    /// observed: the count is the thing that changes, and re-reading a table of tens of rows when
    /// it does is cheaper than a second `ValueObservation` on the same table. Retry and Discard
    /// re-read it themselves as well, so the list is right immediately rather than one
    /// observation hop later.
    @State private var failedRows: [OutboxItem] = []
    /// What is typed into the watched-repositories field.
    @State private var watchedRepositoryDraft = ""
    /// Why the last attempt to watch a repository did nothing.
    @State private var watchedRepositoryError: String?

    var body: some View {
        SettingsPage {
            Section(String(localized: "Inbox sweep")) {
                LabeledContent {
                    HStack(spacing: 10) {
                        Slider(value: intervalBinding, in: 1...10, step: 1)
                            .labelsHidden()
                            .frame(maxWidth: 220)
                        Text(String(localized: "\(Int(environment.settings.sweepIntervalMinutes)) min"))
                            .font(Theme.mono(.callout))
                            .foregroundStyle(.secondary)
                            .frame(width: 56, alignment: .trailing)
                    }
                } label: {
                    Text(String(localized: "Full search every"))
                    Text(String(localized: "Applies from the next sign-in."))
                }
                .help(String(
                    localized: "Notifications are polled at the interval GitHub asks for; this slider only controls the full search sweep."
                ))
            }

            Section {
                Toggle(String(localized: "A new review is requested from me"), isOn: reviewBinding)
                Toggle(String(localized: "Checks fail on a pull request I opened"), isOn: checksBinding)
                Toggle(String(localized: "A queued review could not be sent"), isOn: conflictBinding)
            } header: {
                Text(String(localized: "Notifications"))
            } footer: {
                SettingsNote(String(localized: "macOS asks for permission the first time one is posted."))
            }

            digestSection

            if let session = environment.session {
                outboxSection(session)
            }

            watchedRepositoriesSection

            hiddenPullRequestsSection

            SettingsSyncSection(model: syncModel)
        }
    }

    // MARK: - Outbox

    /// What is waiting, what is parked, and what was given up on.
    private func outboxSection(_ session: SignedInSession) -> some View {
        Section(String(localized: "Outbox")) {
            LabeledContent {
                Button(String(localized: "Sync now")) {
                    Task { await environment.syncNow() }
                }
            } label: {
                Text(session.pendingOutboxCount == 0
                    ? String(localized: "Nothing waiting to be sent.")
                    : String(localized: "\(session.pendingOutboxCount) mutations waiting to be sent."))
            }
            // A parked mutation is never retried on its own (ADR 0006), so it stays on screen
            // until someone acts on it — the alert it raised was a moment, this is the standing
            // reminder.
            if session.conflictedOutboxCount > 0 {
                Label(
                    String(localized: "\(session.conflictedOutboxCount) conflicted — needs your attention."),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(Theme.pending)
                .help(String(
                    localized: "These pull requests got new commits after the review was queued, so nothing was sent. Open each one and check your draft against the new commit."
                ))
            }
            failedOutboxGroup(session)
        }
        .task(id: session.failedOutboxCount) { await reloadFailedRows(session) }
    }

    // MARK: - Repositories swept whole

    /// The repositories the sweep reads in full, regardless of the user's relation to what is
    /// in them (ADR 0005's 2026-09-16 amendment).
    ///
    /// The five default facets are all `@me` searches, which is right for an inbox and leaves no
    /// way to follow a repository you are responsible for but never named on — the normal shape
    /// of a small team's own repositories. Each entry costs one search per sweep, so the list is
    /// capped rather than left to grow into the rate limit.
    @ViewBuilder
    private var watchedRepositoriesSection: some View {
        let watched = environment.settings.watchedRepositories
        let isFull = watched.count >= AppSettings.maximumWatchedRepositories
        Section {
            if watched.isEmpty {
                Text(String(localized: "No repositories watched."))
                    .foregroundStyle(.secondary)
            }
            ForEach(watched, id: \.fullName) { repo in
                LabeledContent {
                    Button(String(localized: "Stop watching")) {
                        environment.settings.watchedRepositories
                            .removeAll { $0.isSameRepository(as: repo) }
                    }
                } label: {
                    Text(verbatim: repo.fullName)
                        .font(Theme.mono(.callout))
                }
            }
        } header: {
            Text(String(localized: "Watched repositories"))
        } footer: {
            SettingsNote(String(localized: "Every open pull request in these reaches the inbox, under Watched."))
        }

        Section {
            LabeledContent(String(localized: "Add repository")) {
                HStack(spacing: 8) {
                    TextField(
                        String(localized: "Add repository"),
                        text: $watchedRepositoryDraft,
                        prompt: Text(String(localized: "owner/repository or a GitHub URL"))
                    )
                    .labelsHidden()
                    .onSubmit { addWatchedRepository() }
                    Button(String(localized: "Watch")) { addWatchedRepository() }
                        .disabled(watchedRepositoryDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .disabled(isFull)
            if let watchedRepositoryError {
                Text(watchedRepositoryError)
                    .font(Theme.type(.caption))
                    .foregroundStyle(Theme.failure)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } footer: {
            if isFull {
                SettingsNote(String(
                    localized: "\(AppSettings.maximumWatchedRepositories) is the maximum — each repository is one more search on every sweep."
                ))
            }
        }
    }

    /// Validates the typed repository and adds it.
    ///
    /// The rule itself is ``AppSettings/watchRepository(named:)``, shared with the inbox's add
    /// dialog so the two cannot drift apart.
    private func addWatchedRepository() {
        if let failure = environment.settings.watchRepository(named: watchedRepositoryDraft) {
            watchedRepositoryError = failure
            return
        }
        watchedRepositoryDraft = ""
        watchedRepositoryError = nil
    }

    // MARK: - Pull requests put away

    /// What the inbox has been told to stop showing, and the way back.
    ///
    /// Hiding happens in the list, one right-click at a time, and the undo for it is the toast
    /// that follows. This is where it goes once that toast is gone: without it the list would be
    /// the only irreversible thing in an app whose architecture asks for an undo instead of a
    /// confirmation. The section is omitted entirely when nothing is hidden — an empty list here
    /// would be a permanent reminder of a feature nobody used.
    @ViewBuilder
    private var hiddenPullRequestsSection: some View {
        let hidden = environment.settings.ignoredPullRequests
        if !hidden.entries.isEmpty {
            Section {
                ForEach(hidden.entries) { entry in
                    LabeledContent {
                        Button(String(localized: "Show again")) {
                            environment.settings.ignoredPullRequests.show(id: entry.id)
                        }
                    } label: {
                        Text(entry.title)
                            .lineLimit(2)
                        Text(verbatim: "\(entry.repo.fullName)#\(entry.number)")
                            .font(Theme.mono(.caption))
                    }
                }
                Button(String(localized: "Show all again")) {
                    environment.settings.ignoredPullRequests.showAll()
                }
            } header: {
                Text(String(localized: "Hidden pull requests"))
            } footer: {
                SettingsNote(String(localized: "One comes back by itself when a review is requested from you."))
            }
        }
    }

    // MARK: - Rows the outbox gave up on

    /// The failed rows, named one by one, each with Retry and Discard.
    ///
    /// The third outbox state and the only one this section can *do* anything about. A pending row
    /// needs nothing but time and a parked one needs the pull request it was queued against — but
    /// a failed row was refused in a way retrying cannot fix (a 4xx from GitHub, a port the app
    /// never wired up), so it sits in the queue for ever and the click that produced it looked as
    /// though it had worked. Retry is the user saying the obstacle is gone; Discard is them saying
    /// it never mattered.
    ///
    /// It is a group of its own rather than another line beside the conflicted count for the same
    /// reason: a count nobody can act on is a nag, and these rows are the only ones in the outbox
    /// with an action attached. The conflicted line above is deliberately untouched — a parked
    /// review is re-applied against the new commit from the pull request itself, not thrown back
    /// at GitHub from a settings window.
    @ViewBuilder
    private func failedOutboxGroup(_ session: SignedInSession) -> some View {
        if session.failedOutboxCount > 0 {
            Label(
                String(localized: "\(session.failedOutboxCount) given up on — they will not be retried."),
                systemImage: "xmark.octagon.fill"
            )
            .foregroundStyle(Theme.failure)
            .help(String(
                localized: "GitHub refused these writes, or Shepherd could not make them at all. Nothing about them changes by itself: retry one once you have fixed what stopped it, or discard it."
            ))
            ForEach(failedRows) { item in
                failedOutboxRow(item, session: session)
            }
        }
    }

    private func failedOutboxRow(_ item: OutboxItem, session: SignedInSession) -> some View {
        LabeledContent {
            HStack(spacing: 8) {
                Button(String(localized: "Retry")) {
                    Task {
                        try? await session.database.retryOutboxItem(id: item.id)
                        await reloadFailedRows(session)
                        await session.drainOutbox()
                        await reloadFailedRows(session)
                    }
                }
                Button(String(localized: "Discard")) {
                    Task {
                        try? await session.database.deleteOutboxItem(id: item.id)
                        await reloadFailedRows(session)
                    }
                }
            }
        } label: {
            Text(verbatim: "\(item.repo.fullName)#\(item.number) · \(Self.actionName(item.action))")
            Text(item.localizedLastError ?? String(localized: "No reason was recorded."))
                .textSelection(.enabled)
        }
    }

    /// Re-reads the failed rows.
    ///
    /// `@MainActor` for the reason ``ClosingIssuesCard/openOnGitHub(_:)`` is: every caller is a
    /// view body or a button's action, which is main-actor isolated already, and the session it
    /// reads the database off is a main-actor type.
    @MainActor
    private func reloadFailedRows(_ session: SignedInSession) async {
        // A read failure answers "nothing to list", which is the same answer an empty outbox
        // gives; the standing count above is the record.
        failedRows = (try? await session.database.failedOutboxItems()) ?? []
    }

    /// What one queued write would have done, in the user's words.
    ///
    /// An exhaustive switch over ``ShepherdCore/OutboxAction`` rather than its `kind`
    /// discriminator: that string is a database column and a log token ("markReadyForReview"), and
    /// a settings window is not the place to read one. A case added to the action is a compile
    /// error here, which is the point.
    ///
    /// Not `private` so `OutboxSurfacesTests` can hold it to that: every case named, no case
    /// falling back to the discriminator.
    /// - Parameter action: The queued write.
    /// - Returns: What it would have done, as a short phrase.
    static func actionName(_ action: OutboxAction) -> String {
        switch action {
        case .submitReview: return String(localized: "Submit review")
        case .replyToComment: return String(localized: "Reply")
        case .resolveThread: return String(localized: "Resolve")
        case .unresolveThread: return String(localized: "Unresolve")
        case .merge: return String(localized: "Merge")
        case .markReadyForReview: return String(localized: "Mark ready for review")
        case .addIssueComment: return String(localized: "Comment on an issue")
        case .addIssueLabel: return String(localized: "Add a label")
        case .addIssueAssignee: return String(localized: "Add an assignee")
        case .closeIssue: return String(localized: "Close an issue")
        case .reopenIssue: return String(localized: "Reopen an issue")
        case .addPullRequestComment: return String(localized: "Comment on a pull request")
        case .closePullRequest(let comment):
            return comment == nil
                ? String(localized: "Close a pull request")
                : String(localized: "Comment and close")
        }
    }

    // MARK: - Morning digest

    /// The opt-in, the time, the weekday switch, and what the digest actually reports.
    ///
    /// It sits on this pane, under the notification toggles, rather than on a pane of its own: it
    /// *is* a notification preference — a scheduled one — and the two things it reports on that
    /// are not pull requests, the outbox and its parked reviews, are counted in the section
    /// directly below. A pane of its own would be three controls in an empty room.
    ///
    /// The header's ⓘ carries the facts the user cannot check for themselves: nothing is fetched
    /// or sent when the digest is built, and a Mac that was asleep still gets its digest — once —
    /// when it wakes up on the same day.
    private var digestSection: some View {
        Section {
            Toggle(isOn: digestEnabledBinding) {
                Text(String(localized: "Send me a morning digest"))
                Text(String(localized: "One notification a day with what came in since the last."))
            }
            Group {
                DatePicker(
                    String(localized: "At"),
                    selection: digestTimeBinding,
                    displayedComponents: .hourAndMinute
                )
                .datePickerStyle(.field)
                Toggle(String(localized: "Weekdays only"), isOn: digestWeekdaysBinding)
            }
            .disabled(!environment.settings.digest.isEnabled)
        } header: {
            SettingsSectionHeader(String(localized: "Morning digest"), info: String(
                localized: "New review requests, green agent pull requests that only need an approval or a merge, your own pull requests with red CI or a change request, and reviews the outbox could not send."
            ) + "\n\n" + String(
                localized: "Built from the local database only — no GitHub call, no AI, nothing sent anywhere. If your Mac was asleep, the digest arrives when it wakes, if that is still the same day. A quiet night produces nothing."
            ))
        } footer: {
            SettingsNote(digestStatusLine)
        }
    }

    /// "No digest delivered on this Mac yet." / "Last digest 2 hours ago."
    private var digestStatusLine: String {
        guard let last = environment.settings.digestLastDeliveredAt else {
            return String(localized: "No digest delivered on this Mac yet.")
        }
        return String(localized: "Last digest \(RelativeDate.long(last)).")
    }

    private var digestEnabledBinding: Binding<Bool> {
        Binding(
            get: { environment.settings.digest.isEnabled },
            // Nothing to apply: `DigestCoordinator` reads the schedule on every tick, so the
            // next check — within a minute — sees the new value, whether it was flipped here or
            // arrived in a settings-sync document.
            set: { isOn in
                var schedule = environment.settings.digest
                schedule.isEnabled = isOn
                environment.settings.digest = schedule
            }
        )
    }

    private var digestWeekdaysBinding: Binding<Bool> {
        Binding(
            get: { environment.settings.digest.weekdaysOnly },
            set: { isOn in
                var schedule = environment.settings.digest
                schedule.weekdaysOnly = isOn
                environment.settings.digest = schedule
            }
        )
    }

    /// The hour and minute as a `Date`, which is the only shape `DatePicker` speaks.
    ///
    /// Built on *today* rather than on a bare `DateComponents`: a components-only date lands in
    /// year one, where a calendar's answers stop being interesting, and the picker shows the time
    /// either way.
    private var digestTimeBinding: Binding<Date> {
        Binding(
            get: {
                let schedule = environment.settings.digest
                let calendar = Calendar.current
                var parts = calendar.dateComponents([.year, .month, .day], from: Date())
                parts.hour = schedule.normalizedHour
                parts.minute = schedule.normalizedMinute
                parts.second = 0
                return calendar.date(from: parts) ?? Date()
            },
            set: { picked in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: picked)
                var schedule = environment.settings.digest
                schedule.hour = parts.hour ?? DigestSchedule.defaultHour
                schedule.minute = parts.minute ?? DigestSchedule.defaultMinute
                environment.settings.digest = schedule
            }
        )
    }

    private var intervalBinding: Binding<Double> {
        Binding(
            get: { environment.settings.sweepIntervalMinutes },
            set: { environment.settings.sweepIntervalMinutes = $0 }
        )
    }

    private var reviewBinding: Binding<Bool> {
        Binding(
            get: { environment.settings.notifyOnReviewRequest },
            set: { environment.settings.notifyOnReviewRequest = $0 }
        )
    }

    private var checksBinding: Binding<Bool> {
        Binding(
            get: { environment.settings.notifyOnChecksFailed },
            set: { environment.settings.notifyOnChecksFailed = $0 }
        )
    }

    private var conflictBinding: Binding<Bool> {
        Binding(
            get: { environment.settings.notifyOnDraftConflict },
            set: { environment.settings.notifyOnDraftConflict = $0 }
        )
    }
}
