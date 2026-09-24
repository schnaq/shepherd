import ShepherdCore
import SwiftUI

/// Dark, light or system, the diff viewer's chrome, whether the menu-bar quick inbox is inserted,
/// and which tab a review opens on.
///
/// The menu-bar toggle lives here rather than on its own tab or under Sync: it decides whether a
/// piece of Shepherd's chrome is on screen, which is the question this tab answers — and the
/// synced document keeps it in `appearance` for the same reason. The review-screen toggle is here
/// on the same argument: "which half of the screen do I land on" is a question about what is in
/// front of the reviewer, not about how a review is submitted.
struct AppearanceSettingsTab: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        SettingsPage {
            Section {
                Picker(String(localized: "Appearance"), selection: appearanceBinding) {
                    ForEach(AppearanceSetting.allCases) { setting in
                        Text(setting.title).tag(setting)
                    }
                }
                .pickerStyle(.segmented)
                Toggle(isOn: menuBarBinding) {
                    Text(String(localized: "Show in menu bar"))
                    Text(String(localized: "How many reviews are waiting, and a short list of them."))
                }
            }

            Section(String(localized: "Review screen")) {
                Toggle(isOn: conversationFirstBinding) {
                    Text(String(localized: "Open agent pull requests on Conversation"))
                    Text(String(localized: "The diff is one keystroke away (t)."))
                }
            }

            Section(String(localized: "Diff viewer")) {
                Picker(selection: diffRendererBinding) {
                    ForEach(DiffRenderer.allCases) { renderer in
                        Text(renderer.title).tag(renderer)
                    }
                } label: {
                    Text(String(localized: "Diff renderer"))
                    Text(String(localized: "Automatic uses the line list while VoiceOver is running."))
                }
                LabeledContent(String(localized: "Font size")) {
                    HStack(spacing: 10) {
                        Slider(value: fontBinding, in: 10...18, step: 1)
                            .labelsHidden()
                            .frame(maxWidth: 220)
                        Text("\(Int(environment.settings.diffFontSize)) pt")
                            .font(Theme.mono(.callout))
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                Toggle(String(localized: "Wrap long lines"), isOn: wrapBinding)
                Toggle(String(localized: "Show diffs inline instead of side by side"), isOn: inlineBinding)
            }
        }
    }

    private var appearanceBinding: Binding<AppearanceSetting> {
        Binding(
            get: { environment.settings.appearance },
            set: {
                environment.settings.appearance = $0
                environment.applyAppearance()
            }
        )
    }

    private var menuBarBinding: Binding<Bool> {
        Binding(
            get: { environment.settings.showsMenuBarExtra },
            // Nothing to apply: `MenuBarExtra(isInserted:)` in `ShepherdApp` reads this setting,
            // so the item appears and disappears with the toggle.
            set: { environment.settings.showsMenuBarExtra = $0 }
        )
    }

    private var conversationFirstBinding: Binding<Bool> {
        Binding(
            get: { environment.settings.opensAgentPullRequestsOnConversation },
            // Nothing to apply: the setting is read once, by the next review to open. A review
            // already on screen keeps the tab it opened on, which is the same once-only rule the
            // reviewer's own click on the picker obeys (ADR 0026's amendment).
            set: { environment.settings.opensAgentPullRequestsOnConversation = $0 }
        )
    }

    private var fontBinding: Binding<Double> {
        Binding(
            get: { environment.settings.diffFontSize },
            set: { environment.settings.diffFontSize = $0 }
        )
    }

    private var wrapBinding: Binding<Bool> {
        Binding(
            get: { environment.settings.diffWrapsLines },
            set: { environment.settings.diffWrapsLines = $0 }
        )
    }

    private var inlineBinding: Binding<Bool> {
        Binding(
            get: { environment.settings.diffUsesInlineMode },
            set: { environment.settings.diffUsesInlineMode = $0 }
        )
    }

    private var diffRendererBinding: Binding<DiffRenderer> {
        Binding(
            get: { environment.settings.diffRenderer },
            set: { environment.settings.diffRenderer = $0 }
        )
    }
}

