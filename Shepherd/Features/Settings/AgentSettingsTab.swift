import ShepherdCore
import ShepherdPersistence
import SwiftUI

/// The bundled registry (read-only) plus the user's extensions (ADR 0008).
struct AgentSettingsTab: View {
    @Environment(AppEnvironment.self) private var environment
    /// The settings model.
    let model: SettingsModel
    @State private var errorMessage: String?
    /// Why the last *Remove* did not happen, drawn under the list it failed in.
    ///
    /// Its own line rather than ``errorMessage``: that one lives in the new-entry section, under
    /// the fields *Add entry* reads, and a reviewer who pressed *Remove* in the list above would
    /// be told about it a form's height away from the row that is still there.
    @State private var removeErrorMessage: String?

    var body: some View {
        SettingsPage {
            Section {
                if let error = model.registryError {
                    Text(error)
                        .foregroundStyle(Theme.failure)
                }
                ForEach(model.bundledAgents) { entry in
                    LabeledContent {
                        Text(verbatim: entry.loginPatterns.joined(separator: ", "))
                            .font(Theme.mono(.caption))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    } label: {
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(AgentPalette.color(forAgentID: entry.id))
                                .frame(width: 8, height: 8)
                            Text(entry.displayName)
                        }
                        .fixedSize()
                    }
                }
            } header: {
                Text(String(localized: "Bundled registry"))
            } footer: {
                SettingsNote(String(localized: "An extension with the same id replaces the bundled entry."))
            }

            Section(String(localized: "Your extensions")) {
                if model.overrides.isEmpty {
                    Text(String(localized: "None yet."))
                        .foregroundStyle(.secondary)
                }
                ForEach(model.overrides) { entry in
                    LabeledContent {
                        Button(String(localized: "Remove"), role: .destructive) {
                            Task {
                                removeErrorMessage = await model.removeOverride(
                                    id: entry.id,
                                    session: environment.session
                                )
                            }
                        }
                    } label: {
                        Text(entry.displayName)
                        Text(verbatim: entry.id)
                            .font(Theme.mono(.caption))
                    }
                }

                // The Settings scene has no toast host, so a refused delete says so here or
                // nowhere — which is what it used to do (`try?`).
                if let removeErrorMessage {
                    Text(removeErrorMessage)
                        .font(Theme.type(.caption))
                        .foregroundStyle(Theme.failure)
                }
            }

            Section(String(localized: "New entry")) {
                TextField(
                    String(localized: "Id"),
                    text: idBinding,
                    prompt: Text(String(localized: "my-agent"))
                )
                TextField(
                    String(localized: "Name"),
                    text: nameBinding,
                    prompt: Text(String(localized: "My Agent"))
                )
                TextField(
                    String(localized: "Logins"),
                    text: loginsBinding,
                    prompt: Text(String(localized: "my-agent[bot], my-agent-*"))
                )
                TextField(
                    String(localized: "Branches"),
                    text: branchesBinding,
                    prompt: Text(String(localized: "my-agent/"))
                )
                TextField(
                    String(localized: "Trailers"),
                    text: trailersBinding,
                    prompt: Text(String(localized: "Co-Authored-By: My Agent"))
                )

                if let errorMessage {
                    Text(errorMessage)
                        .font(Theme.type(.caption))
                        .foregroundStyle(Theme.failure)
                }

                HStack {
                    Spacer()
                    Button(String(localized: "Add entry")) {
                        Task {
                            errorMessage = await model.addOverride(session: environment.session)
                        }
                    }
                }
            }
        }
        .task {
            await model.loadRegistry(session: environment.session)
        }
    }

    private var idBinding: Binding<String> {
        Binding(get: { model.newAgentID }, set: { model.newAgentID = $0 })
    }

    private var nameBinding: Binding<String> {
        Binding(get: { model.newAgentName }, set: { model.newAgentName = $0 })
    }

    private var loginsBinding: Binding<String> {
        Binding(get: { model.newAgentLogins }, set: { model.newAgentLogins = $0 })
    }

    private var branchesBinding: Binding<String> {
        Binding(get: { model.newAgentBranches }, set: { model.newAgentBranches = $0 })
    }

    private var trailersBinding: Binding<String> {
        Binding(get: { model.newAgentTrailers }, set: { model.newAgentTrailers = $0 })
    }
}
