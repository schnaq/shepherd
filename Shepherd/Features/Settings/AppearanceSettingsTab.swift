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
    /// The language picked here; written straight to the defaults, read by the next launch.
    @State private var language = AppLanguage.current

    var body: some View {
        @Bindable var settings = environment.settings
        SettingsPage {
            Section {
                Picker(String(localized: "Appearance"), selection: appearanceBinding) {
                    ForEach(AppearanceSetting.allCases) { setting in
                        Text(setting.title).tag(setting)
                    }
                }
                .pickerStyle(.segmented)
                Picker(String(localized: "Language"), selection: $language) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.title).tag(language)
                    }
                }
                .onChange(of: language) { _, newValue in newValue.apply() }
                if language != AppLanguage.atLaunch {
                    LabeledContent(String(localized: "Applies after Shepherd restarts.")) {
                        Button(String(localized: "Restart Now")) { AppLanguage.relaunch() }
                    }
                    .foregroundStyle(.secondary)
                }
                // Nothing to apply: `MenuBarExtra(isInserted:)` in `ShepherdApp` reads this setting,
                // so the item appears and disappears with the toggle.
                Toggle(isOn: $settings.showsMenuBarExtra) {
                    Text(String(localized: "Show in menu bar"))
                    Text(String(localized: "How many reviews are waiting, and a short list of them."))
                }
            }

            Section(String(localized: "Review screen")) {
                // Nothing to apply: the setting is read once, by the next review to open. A review
                // already on screen keeps the tab it opened on, which is the same once-only rule the
                // reviewer's own click on the picker obeys (ADR 0026's amendment).
                Toggle(isOn: $settings.opensAgentPullRequestsOnConversation) {
                    Text(String(localized: "Open agent pull requests on Conversation"))
                    Text(String(localized: "The diff is one keystroke away (t)."))
                }
            }

            Section(String(localized: "Diff viewer")) {
                Picker(selection: $settings.diffRenderer) {
                    ForEach(DiffRenderer.allCases) { renderer in
                        Text(renderer.title).tag(renderer)
                    }
                } label: {
                    Text(String(localized: "Diff renderer"))
                    Text(String(localized: "Automatic uses the line list while VoiceOver is running."))
                }
                LabeledContent(String(localized: "Font size")) {
                    HStack(spacing: 10) {
                        Slider(value: $settings.diffFontSize, in: 10...18, step: 1)
                            .labelsHidden()
                            .frame(maxWidth: 220)
                        Text("\(Int(settings.diffFontSize)) pt")
                            .font(Theme.mono(.callout))
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                Toggle(String(localized: "Wrap long lines"), isOn: $settings.diffWrapsLines)
                Toggle(
                    String(localized: "Show diffs inline instead of side by side"),
                    isOn: $settings.diffUsesInlineMode
                )
            }
        }
    }

    /// Hand-written rather than `$settings.appearance`, because the setter also has to apply the
    /// choice to the running app's windows.
    private var appearanceBinding: Binding<AppearanceSetting> {
        Binding(
            get: { environment.settings.appearance },
            set: {
                environment.settings.appearance = $0
                environment.applyAppearance()
            }
        )
    }
}
