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
                Toggle(String(localized: "A queued write was parked or not sent"), isOn: conflictBinding)
            } header: {
                Text(String(localized: "Notifications"))
            } footer: {
                SettingsNote(String(localized: "macOS asks for permission the first time one is posted."))
            }

            digestSection

            if let session = environment.session {
                outboxSection(session)
            }

            mergeSeriesSection

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
            unsentWritesGroup(session)
        }
    }

    // MARK: - Merge series

    /// The running merge series, each with Cancel (ADR 0041). Omitted when none runs, like the
    /// hidden pull requests below: an empty list would advertise a feature from a settings pane.
    @ViewBuilder
    private var mergeSeriesSection: some View {
        let running = environment.mergeSeries.runningSeries
        if !running.isEmpty {
            Section {
                ForEach(running) { series in
                    LabeledContent {
                        Button(String(localized: "Cancel")) {
                            environment.cancelMergeSeries(series.id)
                        }
                        .help(String(localized: "Stop the series. A merge already queued still goes out."))
                    } label: {
                        Text(verbatim: series.repository.fullName)
                            .font(Theme.mono(.callout))
                        Text(Self.progress(of: series))
                    }
                }
            } header: {
                SettingsSectionHeader(String(localized: "Merge series"), info: String(
                    localized: "Started with “Merge one after another…” on ticked pull requests. Shepherd merges each repository's list in order, waits for the checks, brings a branch that fell behind up to date, and skips what cannot be merged. Series live on this Mac only."
                ))
            }
        }
    }

    /// "2 of 5 merged · #42 Bump the client", for one series' row.
    static func progress(of series: MergeSeries) -> String {
        let merged = String(localized: "\(series.mergedCount) of \(series.entries.count) merged")
        guard let active = series.activeEntry else { return merged }
        return "\(merged) · #\(active.number) \(active.title)"
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

    // MARK: - Rows that will not go out by themselves

    /// The parked and the failed rows, named one by one with their actions — the same rows, in
    /// the same row view, as the toolbar's unsent list (ADR 0006's 2026-10-29 amendment).
    ///
    /// Both kinds sit in the queue until somebody decides: a failed row was refused in a way
    /// retrying cannot fix (Retry once the obstacle is gone, or Discard), a parked one was written
    /// against a commit that is no longer the head (Send anyway for a review, or Discard; Open to
    /// look at the new commits first). The amendment of 2026-09-03 left parked rows without
    /// buttons, and that is what kept a parked write — and its pull request — around for ever.
    @ViewBuilder
    private func unsentWritesGroup(_ session: SignedInSession) -> some View {
        if session.conflictedOutboxCount > 0 {
            Label(
                String(localized: "\(session.conflictedOutboxCount) parked — the target changed after the write was queued."),
                systemImage: "exclamationmark.triangle.fill"
            )
            .foregroundStyle(Theme.pending)
        }
        if session.failedOutboxCount > 0 {
            Label(
                String(localized: "\(session.failedOutboxCount) not sent — they will not be retried."),
                systemImage: "xmark.octagon.fill"
            )
            .foregroundStyle(Theme.failure)
            .help(String(
                localized: "GitHub refused these writes, or Shepherd could not make them at all. Nothing about them changes by itself: retry one once you have fixed what stopped it, or discard it."
            ))
        }
        ForEach(session.unsentWrites) { item in
            UnsentWriteRow(item: item, session: session)
        }
    }

    /// What one queued write would have done, in the user's words.
    ///
    /// A forwarder to ``ShepherdCore/OutboxAction/localizedName``, which the phone shares.
    ///
    /// Not `private` so `OutboxSurfacesTests` can hold it to that: every case named, no case
    /// falling back to the discriminator.
    /// - Parameter action: The queued write.
    /// - Returns: What it would have done, as a short phrase.
    static func actionName(_ action: OutboxAction) -> String { action.localizedName }

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
