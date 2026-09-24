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
    /// Its own line rather than ``errorMessage``: that one lives at the bottom of the card, under
    /// the fields *Add entry* reads, and a reviewer who pressed *Remove* at the top of the list
    /// would be told about it a form's height away from the row that is still there.
    @State private var removeErrorMessage: String?

    var body: some View {
        SettingsPage {
            Card {
                VStack(alignment: .leading, spacing: 6) {
                    CardTitle(String(localized: "BUNDLED REGISTRY"))
                    if let error = model.registryError {
                        Text(error)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.failure)
                    }
                    ForEach(model.bundledAgents) { entry in
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(AgentPalette.color(forAgentID: entry.id))
                                .frame(width: 8, height: 8)
                            Text(entry.displayName)
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.text)
                            Spacer(minLength: 6)
                            Text(entry.loginPatterns.joined(separator: ", "))
                                .font(Theme.mono(10.5))
                                .foregroundStyle(Theme.textMuted)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                    Text(String(
                        localized: "Bundled entries ship with Shepherd. Add your own below — an entry with the same id replaces the bundled one."
                    ))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            Card {
                VStack(alignment: .leading, spacing: 8) {
                    CardTitle(String(localized: "YOUR EXTENSIONS"))
                    if model.overrides.isEmpty {
                        Text(String(localized: "None yet."))
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textMuted)
                    }
                    ForEach(model.overrides) { entry in
                        HStack(spacing: 8) {
                            Text(entry.displayName)
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.text)
                            Text(entry.id)
                                .font(Theme.mono(10.5))
                                .foregroundStyle(Theme.textMuted)
                            Spacer(minLength: 6)
                            Button(String(localized: "Remove")) {
                                Task {
                                    removeErrorMessage = await model.removeOverride(
                                        id: entry.id,
                                        session: environment.session
                                    )
                                }
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.failure)
                        }
                    }

                    // The Settings scene has no toast host, so a refused delete says so here or
                    // nowhere — which is what it used to do (`try?`).
                    if let removeErrorMessage {
                        Text(removeErrorMessage)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.failure)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Divider().overlay(Theme.hairline)

                    Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                        GridRow {
                            Text(String(localized: "Id"))
                            TextField("my-agent", text: idBinding)
                        }
                        GridRow {
                            Text(String(localized: "Name"))
                            TextField("My Agent", text: nameBinding)
                        }
                        GridRow {
                            Text(String(localized: "Logins"))
                            TextField("my-agent[bot], my-agent-*", text: loginsBinding)
                        }
                        GridRow {
                            Text(String(localized: "Branches"))
                            TextField("my-agent/", text: branchesBinding)
                        }
                        GridRow {
                            Text(String(localized: "Trailers"))
                            TextField("Co-Authored-By: My Agent", text: trailersBinding)
                        }
                    }
                    .font(.system(size: 12))
                    .textFieldStyle(.roundedBorder)

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.failure)
                    }

                    Button(String(localized: "Add entry")) {
                        Task {
                            errorMessage = await model.addOverride(session: environment.session)
                        }
                    }
                    .buttonStyle(SecondaryButtonStyle(height: 28))
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

