import ShepherdCore
import SwiftUI

/// The menu-bar item itself: the inbox symbol, plus how many pull requests are waiting.
///
/// A view rather than a value computed in ``ShepherdApp``'s scene body on purpose: reading
/// ``SignedInSession/inboxRows`` *inside* a view body is what puts the badge on the observation
/// graph, so a sweep that lands while every window is closed still updates the menu bar.
struct MenuBarInboxLabel: View {
    /// The signed-in session, or `nil` while signed out.
    let session: SignedInSession?

    /// The symbol: the same one the "Needs my review" row wears in the rail
    /// (``SmartView/systemImage``), because it stands for the same list.
    static let symbolName = "tray.and.arrow.down"

    var body: some View {
        // `MenuBarExtra` renders text and symbols in its label, so a `Label` is what produces
        // "symbol + number"; with nothing waiting the number is dropped rather than shown as a
        // zero, which leaves a plain, quiet icon.
        if let badge = MenuBarQuickInbox.badgeText(count: count) {
            Label(badge, systemImage: Self.symbolName)
                .accessibilityLabel(
                    Text(String(localized: "Shepherd — \(count) waiting for your review"))
                )
        } else {
            Image(systemName: Self.symbolName)
                .accessibilityLabel(Text(String(localized: "Shepherd — nothing to review")))
        }
    }

    private var count: Int {
        guard let session else { return 0 }
        return MenuBarQuickInbox.count(in: session.inboxRows)
    }
}

/// The quick inbox: the top pull requests waiting for the user, and the three things worth doing
/// from a menu bar.
///
/// It has no sync, no fetch and no selection of its own. Everything it shows comes from
/// ``SignedInSession/inboxRows`` — the session's observation of the same table the inbox reads
/// (ADR 0006) — and every action it offers is a call into ``AppEnvironment``: the same
/// `openReview`, the same `syncNow`, the same inbox route a `shepherd://` link takes.
struct MenuBarInboxView: View {
    @Environment(AppEnvironment.self) private var environment
    /// Used for one case only: the window is gone because the user closed it, and AppKit has
    /// nothing left to bring forward (``AppEnvironment/activateMainWindow()``).
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // Derived once per render and handed down: the menu is only rendered while it is open,
        // and both the list and the footer's "n more…" have to be talking about the same cut.
        let menu = quickInbox
        VStack(alignment: .leading, spacing: 0) {
            header(menu)
            Divider().overlay(Theme.hairline)
            if let menu {
                rows(for: menu)
            } else {
                signedOut
            }
            Divider().overlay(Theme.hairline)
            footer(menu)
        }
        .frame(width: 360)
        .background(Theme.panel)
        .tint(Theme.accent)
    }

    /// What the menu shows, or `nil` while signed out.
    private var quickInbox: MenuBarQuickInbox? {
        guard let session = environment.session else { return nil }
        return MenuBarQuickInbox.make(from: session.inboxRows)
    }

    /// Whether a sweep has come back since this session started.
    ///
    /// Signed out the answer is `false`, which never reaches a caller: the headline this gates is
    /// only drawn once there is a session to have an inbox at all.
    private var hasCompletedFirstSweep: Bool {
        environment.session?.hasCompletedFirstSweep ?? false
    }

    /// The headline over an empty quick inbox.
    ///
    /// The same distinction `InboxListView` draws, because it is the same ambiguity: this menu is
    /// often the first thing somebody opens after signing in, and until a sweep has come back
    /// "Nothing to review" is not a finding but a question nobody has asked yet. Only the headline
    /// changes — the line under it is true either way — so the menu gains no sentence of its own
    /// to keep in step with the inbox's.
    private var emptyHeadline: String {
        hasCompletedFirstSweep
            ? String(localized: "Nothing to review")
            : String(localized: "Checking your repositories…")
    }

    // MARK: - Header

    private func header(_ quickInbox: MenuBarQuickInbox?) -> some View {
        HStack(spacing: 8) {
            Text(String(localized: "Needs my review"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textStrong)
            Spacer(minLength: 4)
            if let quickInbox {
                Text("\(quickInbox.total)")
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textMuted)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
    }

    // MARK: - Content

    @ViewBuilder
    private func rows(for quickInbox: MenuBarQuickInbox) -> some View {
        if quickInbox.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text(emptyHeadline)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                Text(String(localized: "New review requests show up here on their own."))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textMuted)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(quickInbox.rows) { row in
                    MenuBarInboxRow(row: row) { openReview(prID: row.id) }
                }
            }
            .padding(.vertical, 4)
        }
    }

    /// Signed out there is exactly one useful thing to say, and one button that acts on it.
    private var signedOut: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "Not signed in"))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
            Text(String(
                localized: "Sign in with GitHub in the main window and your review requests appear here."
            ))
            .font(.system(size: 11))
            .foregroundStyle(Theme.textMuted)
            .fixedSize(horizontal: false, vertical: true)
            Button(String(localized: "Sign in…")) {
                revealMainWindow()
            }
            .buttonStyle(SecondaryButtonStyle(height: 26))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Footer

    private func footer(_ quickInbox: MenuBarQuickInbox?) -> some View {
        HStack(spacing: 8) {
            Button(String(localized: "Open Shepherd")) {
                revealMainWindow()
            }
            .buttonStyle(SecondaryButtonStyle(height: 26))

            Button(String(localized: "Sync now")) {
                Task { await environment.syncNow() }
            }
            .buttonStyle(SecondaryButtonStyle(height: 26))
            .disabled(environment.session == nil || environment.session?.isSyncing == true)
            .help(String(localized: "Run a sweep now (⌘R in the main window)"))

            Spacer(minLength: 4)

            if let overflow = quickInbox?.overflow, overflow > 0 {
                Button(String(localized: "\(overflow) more…")) { openInbox() }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(Theme.accentText)
                .help(String(localized: "Open the full inbox on “Needs my review”"))
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
    }

    // MARK: - Actions

    /// Opens a pull request in the main window.
    ///
    /// ``AppEnvironment/openReview(prID:composing:)`` and nothing else: the menu bar is another
    /// way to *ask*, not another way to navigate, so a row here lands on the same screen as a
    /// double-clicked inbox row, a ⌘K result and a `shepherd://pr/…` link.
    /// - Parameter prID: The pull request's node id.
    private func openReview(prID: String) {
        environment.openReview(prID: prID)
        revealMainWindow()
    }

    /// Shows the full inbox on "Needs my review" — the footer's "n more…".
    ///
    /// Runs the ``DeepLink/inbox(filter:)`` route rather than reaching into the inbox's rail
    /// state, which is the path `shepherd://inbox?filter=needs-my-review` takes (ADR 0013). No
    /// URL is built: the link *value* is the internal navigation API.
    private func openInbox() {
        environment.open(.inbox(filter: .needsMyReview))
        revealMainWindow()
    }

    /// Brings the main window forward, and reopens it when the user has closed it.
    private func revealMainWindow() {
        guard !environment.activateMainWindow() else { return }
        openWindow(id: ShepherdScene.mainWindow)
    }
}

/// One quick-inbox row: the same information an inbox row leads with, in a menu's width.
///
/// CI dot, `repo#number`, title, provenance chip — dropped from ``InboxRowView`` are the diff
/// counts, the timestamp and the status chip, which are the parts a reader only wants once they
/// are actually triaging.
struct MenuBarInboxRow: View {
    /// The pull request.
    let row: PullRequestSummary
    /// Opens it in the main window.
    let onOpen: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 8) {
                CheckDotView(state: row.checkRollup?.state, size: 7)
                Text(verbatim: "\(row.repo.name) #\(row.number)")
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.textMuted)
                    .layoutPriority(1)
                Text(row.title)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                ProvenanceChip(actor: row.author, size: 10)
                    .layoutPriority(1)
            }
            .padding(.horizontal, 12)
            .frame(height: 28)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isHovering ? Theme.selection : Color.clear,
                in: RoundedRectangle(cornerRadius: 5, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .onHover { isHovering = $0 }
        .accessibilityLabel(
            Text(
                SpokenRow.sentence([
                    CheckDotView.spokenState(row.checkRollup?.state),
                    "\(row.slug): \(row.title)",
                    ProvenanceChip.spokenProvenance(of: row.author),
                ])
            )
        )
    }
}
