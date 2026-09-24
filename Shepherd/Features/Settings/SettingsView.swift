import ShepherdCore
import ShepherdPersistence
import SwiftUI

/// The Settings window: Account, Sync, Replies, Agents, Intelligence, Delegation, Automation,
/// Appearance — a sidebar on the left, the chosen pane on the right, the way System Settings is
/// laid out.
///
/// The one presentation of settings there is — the `Settings` scene behind ⌘, — and every in-app
/// way in goes through ``AppEnvironment/showSettings(_:)`` to reach it.
///
/// A sidebar rather than the `TabView` this once was: eight panes never fit across the top of the
/// window, and macOS draws tab labels that do not fit on top of one another — worse in German.
/// A `NavigationSplitView` rather than a hand-drawn rail, so the sidebar, its selection, the
/// pane's title in the title bar and the window's resizing all behave as on the rest of the
/// system. Each pane is a grouped `Form` (``SettingsPage``) for the same reason.
///
/// Replies sits between Sync and the AI cluster because it is the one pane about the review path
/// itself. Webhooks have their own pane (Automation) rather than a section under Sync: Sync keeps
/// the local cache in step with GitHub, Automation is what Shepherd tells the outside world.
struct SettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var model = SettingsModel()
    /// The encrypted settings-sync model (ADR 0014). Owned here rather than by the section so
    /// the passphrase and key fields survive a pane switch within one Settings window.
    @State private var syncModel = SettingsSyncModel()

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            pane
                .navigationTitle(environment.settingsTab.settingsTitle)
        }
        // A minimum rather than a fixed size, so the window can be dragged larger — the panes are
        // grouped forms that reflow and scroll. The minimum keeps the longest German row labels
        // on one line beside their controls.
        .frame(minWidth: 720, minHeight: 480)
    }

    /// The pane list.
    ///
    /// Driven by ``SettingsDeepLinkTab/allCases`` rather than by eight literal rows: the enum is
    /// already the list of panes — it is what a deep link names.
    ///
    /// Which pane is showing is ``AppEnvironment/settingsTab``, not state of this view, which is
    /// what lets the inbox rail's gear, the fleet's empty state and `shepherd://settings/<tab>`
    /// (ADR 0013) land on one — including when this window is *already* open.
    private var sidebar: some View {
        List(SettingsDeepLinkTab.allCases, id: \.self, selection: selection) { tab in
            Label(tab.settingsTitle, systemImage: tab.settingsSymbol)
        }
        .listStyle(.sidebar)
    }

    /// `List` selects through an optional; the environment always has a pane. A deselect (a click
    /// into the empty space under the last row) keeps the pane that was showing.
    private var selection: Binding<SettingsDeepLinkTab?> {
        Binding(
            get: { environment.settingsTab },
            set: { if let tab = $0 { environment.settingsTab = tab } }
        )
    }

    /// The chosen pane.
    @ViewBuilder
    private var pane: some View {
        switch environment.settingsTab {
        case .account:
            AccountSettingsTab()
        case .sync:
            SyncSettingsTab(syncModel: syncModel)
        case .replies:
            RepliesSettingsTab()
        case .agents:
            AgentSettingsTab(model: model)
        case .intelligence:
            IntelligenceSettingsTab(model: model)
        case .delegation:
            DelegationSettingsTab()
        case .automation:
            AutomationSettingsTab(model: model)
        case .appearance:
            AppearanceSettingsTab()
        }
    }
}

/// How a settings pane names itself in the rail.
///
/// An extension in the app target rather than properties on the enum itself:
/// ``SettingsDeepLinkTab`` lives in `ShepherdCore`, which has to keep building on Linux and has
/// no business knowing about SF Symbols.
extension SettingsDeepLinkTab {
    /// The rail label.
    var settingsTitle: String {
        switch self {
        case .account: return String(localized: "Account")
        case .sync: return String(localized: "Sync")
        case .replies: return String(localized: "Replies")
        case .agents: return String(localized: "Agents")
        case .intelligence: return String(localized: "Intelligence")
        case .delegation: return String(localized: "Delegation")
        case .automation: return String(localized: "Automation")
        case .appearance: return String(localized: "Appearance")
        }
    }

    /// The leading SF Symbol.
    var settingsSymbol: String {
        switch self {
        case .account: return "person.crop.circle"
        case .sync: return "arrow.clockwise"
        case .replies: return "text.badge.plus"
        case .agents: return "cpu"
        case .intelligence: return "sparkles"
        // `terminal`, because delegation runs a CLI — and because the symbol this once used,
        // `arrow.uturn.backward.badge.clock`, draws nothing at all.
        case .delegation: return "terminal"
        case .automation: return "bolt.horizontal"
        case .appearance: return "paintbrush"
        }
    }
}

// MARK: - Shared chrome

/// The container every settings pane uses: a grouped `Form`, as in System Settings.
///
/// Each group of a pane is a `Section` with a short title; a row is a control with its label on
/// the left (`Toggle`, `Picker`, `LabeledContent`), and at most one short line of help under it
/// (``SettingsNote``). A detail that needs more than that goes into an ``InfoButton`` rather than
/// onto the page.
struct SettingsPage<Content: View>: View {
    /// The pane's sections.
    @ViewBuilder var content: Content

    var body: some View {
        Form {
            content
        }
        .formStyle(.grouped)
    }
}

/// The one line of help under a settings row or at the foot of a section.
///
/// Secondary and a size down, like the subtitles System Settings puts under a row, and allowed to
/// wrap — it is a sentence, not a label.
struct SettingsNote: View {
    private let text: String

    /// Creates a note.
    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(Theme.type(.caption))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The ⓘ beside a settings row that opens the longer explanation in a popover.
///
/// For the detail a row needs but most readers do not: what exactly leaves the Mac, which
/// fallback applies, why a default is what it is. Keeping it one click away is what lets the row
/// itself stay one line.
struct InfoButton: View {
    private let text: String
    @State private var isShowing = false

    /// Creates the button.
    /// - Parameter text: The explanation, one or more short paragraphs separated by blank lines.
    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Button {
            isShowing.toggle()
        } label: {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(Text(String(localized: "More information")))
        .popover(isPresented: $isShowing, arrowEdge: .trailing) {
            Text(text)
                .font(Theme.type(.callout))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 320, alignment: .leading)
                .padding(14)
        }
    }
}

/// A section header with an ⓘ beside its title, for the sections whose story is longer than one
/// subtitle can carry.
///
/// Pulled out once here rather than left as the per-tab helper it started as: nearly every tab
/// needed exactly this shape, and a header retyped at each call site cannot be told apart from
/// one defined once and reused — until one of the copies drifts.
struct SettingsSectionHeader: View {
    /// The header's title.
    private let title: String
    /// The explanation behind the ⓘ.
    private let info: String

    /// Creates the header.
    /// - Parameters:
    ///   - title: The header's title.
    ///   - info: The explanation behind the ⓘ.
    init(_ title: String, info: String) {
        self.title = title
        self.info = info
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
            InfoButton(info)
        }
    }
}

/// A form row's control half: the current value beside a stepper that edits it, for the caller's
/// own `LabeledContent(title) { StepperValue(...) }`.
///
/// The value is read back out of the binding rather than passed separately, so the number on
/// screen cannot drift from the one the stepper is editing. Shared across tabs rather than a
/// per-tab twin: every settings row that is "a number with a stepper" wants the same two widgets
/// in the same order — only the font differs, for a row that sits among smaller text.
struct StepperValue: View {
    /// The value the stepper edits and the row displays.
    let value: Binding<Int>
    /// The permitted range.
    let range: ClosedRange<Int>
    /// The font the current value is drawn in.
    var font: Font = Theme.mono(.body)

    var body: some View {
        HStack(spacing: 6) {
            Text(verbatim: "\(value.wrappedValue)")
                .font(font)
                .monospacedDigit()
            Stepper(value: value, in: range) {
                Text(verbatim: "\(value.wrappedValue)")
            }
            .labelsHidden()
        }
    }
}
