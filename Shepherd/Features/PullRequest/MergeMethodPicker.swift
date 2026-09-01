import GitHubKit
import SwiftUI

/// The merge-method radio group, shared by the merge sheet and the bulk-triage dialog.
///
/// Both sheets write straight through to ``AppSettings/defaultMergeMethod`` rather than keeping a
/// local choice, so the next merge dialog — single or bulk — opens on the method that was used
/// last (ADR 0015). That shared write is the reason this is one view: two copies could quietly
/// come to offer different methods, and the user would have no way to tell which sheet had
/// changed the remembered one.
struct MergeMethodPicker: View {
    /// Where the remembered merge method lives.
    let settings: AppSettings

    var body: some View {
        Picker(String(localized: "Method"), selection: methodBinding) {
            Text(String(localized: "Merge commit")).tag(MergeMethod.merge)
            Text(String(localized: "Squash and merge")).tag(MergeMethod.squash)
            Text(String(localized: "Rebase and merge")).tag(MergeMethod.rebase)
        }
        .pickerStyle(.radioGroup)
    }

    private var methodBinding: Binding<MergeMethod> {
        Binding(
            get: { settings.defaultMergeMethod },
            set: { settings.defaultMergeMethod = $0 }
        )
    }
}
