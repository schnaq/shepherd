import GitHubKit
import ShepherdCore
import SwiftUI

/// Settings → Sync → "Sync across Macs" (ADR 0014).
///
/// The whole feature in one place: where the bucket is, who may write to it, what protects the
/// contents, and three buttons. Everything is behind an enable toggle that is off on a fresh
/// install, so a user who never wants this never sees a field they have to reason about.
///
/// Several sections from one view, so the pane's `Form` groups them like any other. The task, the
/// download observation and the confirmation dialog hang off the first section — the only one
/// that is always there — because a modifier on the whole would be copied onto every section.
///
/// The one thing that cannot be undone — a lost passphrase is lost data — stays on the page as the
/// passphrase section's footer, because there is no recovery path by design and a user has to
/// learn that *before* they upload, not after.
struct SettingsSyncSection: View {
    @Environment(AppEnvironment.self) private var environment
    /// The sync model, owned by ``SettingsView`` so the fields survive a pane switch.
    let model: SettingsSyncModel

    @State private var saveError: String?
    @State private var isConfirmingDownload = false

    var body: some View {
        Section {
            Toggle(isOn: enabledBinding) {
                Text(String(localized: "Keep settings in an S3-compatible bucket"))
                Text(String(localized: "Encrypted on this Mac; the bucket only ever sees ciphertext."))
            }
        } header: {
            SettingsSectionHeader(String(localized: "Sync across Macs"), info: String(
                localized: "Your settings and your secrets are encrypted on this Mac with a passphrase you choose, then stored as one object in a bucket you own. The bucket operator — and anyone who can read the bucket — sees ciphertext only."
            ))
        }
        .task {
            model.load(context: environment.settingsSyncContext())
        }
        .onChange(of: model.pendingDownload) { _, pending in
            isConfirmingDownload = pending != nil
        }
        .confirmationDialog(
            String(localized: "Overwrite this Mac's settings?"),
            isPresented: $isConfirmingDownload
        ) {
            Button(String(localized: "Overwrite settings"), role: .destructive) {
                Task { await applyDownload() }
            }
            Button(String(localized: "Cancel"), role: .cancel) { model.cancelDownload() }
        } message: {
            Text(downloadPrompt)
        }

        if environment.settings.settingsSyncEnabled {
            bucketSection
            credentialSection
            passphraseSection
            actionSection
        }
    }

    // MARK: - Where the object lives

    private var bucketSection: some View {
        Section {
            TextField(
                String(localized: "Endpoint"),
                text: endpointBinding,
                prompt: Text(verbatim: "https://object.storage.eu01.onstackit.cloud")
            )
            TextField(
                String(localized: "Bucket"),
                text: bucketBinding,
                prompt: Text(verbatim: "my-shepherd-settings")
            )
            TextField(
                String(localized: "Region"),
                text: regionBinding,
                prompt: Text(verbatim: "eu01")
            )
            TextField(
                String(localized: "Prefix"),
                text: prefixBinding,
                prompt: Text(verbatim: S3ObjectLocation.defaultPrefix)
            )
            Picker(selection: addressingBinding) {
                ForEach(S3AddressingStyle.allCases) { style in
                    Text(style.title).tag(style)
                }
            } label: {
                Text(String(localized: "Addressing"))
                Text(String(localized: "Path style works with every provider."))
            }
            if let location = environment.settings.settingsSyncLocation, let url = location.url {
                Text(verbatim: url.absoluteString)
                    .font(Theme.mono(.caption))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else if let problem = configurationProblem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(Theme.type(.caption))
                    .foregroundStyle(Theme.pending)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text(String(localized: "Bucket"))
        } footer: {
            SettingsNote(String(localized: "HTTPS only: the object carries your tokens."))
        }
    }

    // MARK: - Who may write to it

    private var credentialSection: some View {
        Section {
            TextField(
                String(localized: "Key id"),
                text: accessKeyBinding,
                prompt: Text(verbatim: "…")
            )
            SecureField(
                String(localized: "Secret"),
                text: secretKeyBinding,
                prompt: Text(String(localized: "secret access key"))
            )
            LabeledContent {
                Button(String(localized: "Save keys")) {
                    saveError = model.saveCredentials(context: environment.settingsSyncContext())
                }
            } label: {
                if model.hasStoredCredentials {
                    Text(String(localized: "Access keys are stored in your Keychain."))
                } else {
                    Text(String(localized: "Access keys are not saved yet."))
                }
            }
            if let saveError {
                Text(saveError)
                    .font(Theme.type(.caption))
                    .foregroundStyle(Theme.failure)
            }
        } header: {
            Text(String(localized: "Access keys"))
        } footer: {
            SettingsNote(String(localized: "Read and write on this one object is enough. Keys never leave your Keychain."))
        }
    }

    // MARK: - What protects the contents

    private var passphraseSection: some View {
        Section {
            SecureField(
                String(localized: "Passphrase"),
                text: passphraseBinding,
                prompt: Text(String(localized: "at least 12 characters"))
            )
            Toggle(String(localized: "Remember passphrase in Keychain"), isOn: rememberBinding)
        } header: {
            SettingsSectionHeader(String(localized: "Passphrase"), info: String(
                localized: "The passphrase is never uploaded and never written to preferences. It becomes the encryption key, so without it the object in the bucket cannot be read."
            ))
        } footer: {
            SettingsNote(String(localized: "If you lose it, there is no recovery. Use the same one on every Mac."))
        }
    }

    // MARK: - Actions

    private var actionSection: some View {
        Section {
            HStack(spacing: 8) {
                if model.state == .running {
                    ProgressView().controlSize(.small)
                }
                Spacer(minLength: 0)
                Button(String(localized: "Check remote")) {
                    let context = environment.settingsSyncContext()
                    Task { await model.checkRemote(context: context) }
                }
                .disabled(environment.settings.settingsSyncLocation == nil
                    || model.state == .running)

                Button(String(localized: "Download settings")) {
                    let context = environment.settingsSyncContext()
                    Task { await model.prepareDownload(context: context) }
                }
                .disabled(!canAct)

                Button(String(localized: "Upload settings")) {
                    let context = environment.settingsSyncContext()
                    Task { await model.upload(context: context) }
                }
                .disabled(!canAct)
            }
            if model.state.hasResult {
                AsyncActionStatusLine(state: model.state)
            }
        } footer: {
            if let line = historyLine {
                SettingsNote(line)
            }
        }
    }

    // MARK: - Derived state

    /// Whether upload and download have everything they need.
    private var canAct: Bool {
        environment.settings.settingsSyncLocation != nil
            && model.hasStoredCredentials
            && !model.passphraseField.isEmpty
            && model.state != .running
    }

    /// What is wrong with the bucket fields, once the user has started filling them in.
    private var configurationProblem: String? {
        let settings = environment.settings
        let typedAnything = ![
            settings.settingsSyncEndpoint,
            settings.settingsSyncBucket,
            settings.settingsSyncRegion,
        ].allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard typedAnything else { return nil }
        do {
            _ = try S3ObjectLocation.resolve(
                endpointText: settings.settingsSyncEndpoint,
                bucket: settings.settingsSyncBucket,
                region: settings.settingsSyncRegion,
                prefix: settings.settingsSyncKeyPrefix,
                addressing: settings.settingsSyncAddressing
            )
            return nil
        } catch {
            return SettingsSyncModel.message(for: error)
        }
    }

    /// The "last upload / last download" line, when this Mac has done either.
    private var historyLine: String? {
        let settings = environment.settings
        var parts: [String] = []
        if let uploaded = settings.settingsSyncLastUploadAt {
            parts.append(String(localized: "Last upload from this Mac: \(GitHubTimestamp.string(from: uploaded))"))
        }
        if let downloaded = settings.settingsSyncLastDownloadAt {
            parts.append(String(localized: "last applied: \(GitHubTimestamp.string(from: downloaded))"))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// What the confirmation dialog says about the box it is asking permission to open.
    private var downloadPrompt: String {
        guard let pending = model.pendingDownload else {
            return String(localized: "This replaces the settings on this Mac.")
        }
        let stamp = GitHubTimestamp.string(from: pending.createdAt)
        return String(
            localized: "These settings were written by \(pending.deviceName) at \(stamp) and carry \(pending.secretCount) secrets. Applying them overwrites the settings on this Mac, including the keys in your Keychain. Local data, drafts and the outbox are untouched."
        )
    }

    private func applyDownload() async {
        let context = environment.settingsSyncContext()
        let outcome = await model.confirmDownload(context: context)
        guard outcome != nil else { return }
        // The two things that cache settings rather than reading them live.
        environment.applyAppearance()
        environment.refreshIntelligence()
    }

    // MARK: - Bindings

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { environment.settings.settingsSyncEnabled },
            set: { environment.settings.settingsSyncEnabled = $0 }
        )
    }

    private var endpointBinding: Binding<String> {
        Binding(
            get: { environment.settings.settingsSyncEndpoint },
            set: { environment.settings.settingsSyncEndpoint = $0 }
        )
    }

    private var bucketBinding: Binding<String> {
        Binding(
            get: { environment.settings.settingsSyncBucket },
            set: { environment.settings.settingsSyncBucket = $0 }
        )
    }

    private var regionBinding: Binding<String> {
        Binding(
            get: { environment.settings.settingsSyncRegion },
            set: { environment.settings.settingsSyncRegion = $0 }
        )
    }

    private var prefixBinding: Binding<String> {
        Binding(
            get: { environment.settings.settingsSyncKeyPrefix },
            set: { environment.settings.settingsSyncKeyPrefix = $0 }
        )
    }

    private var addressingBinding: Binding<S3AddressingStyle> {
        Binding(
            get: { environment.settings.settingsSyncAddressing },
            set: { environment.settings.settingsSyncAddressing = $0 }
        )
    }

    private var accessKeyBinding: Binding<String> {
        Binding(get: { model.accessKeyIDField }, set: { model.accessKeyIDField = $0 })
    }

    private var secretKeyBinding: Binding<String> {
        Binding(get: { model.secretAccessKeyField }, set: { model.secretAccessKeyField = $0 })
    }

    private var passphraseBinding: Binding<String> {
        Binding(get: { model.passphraseField }, set: { model.passphraseField = $0 })
    }

    private var rememberBinding: Binding<Bool> {
        Binding(
            get: { environment.settings.settingsSyncRemembersPassphrase },
            set: { isOn in
                environment.settings.settingsSyncRemembersPassphrase = isOn
                // Unticking it has to *delete* the stored passphrase, not merely stop writing
                // one — otherwise "don't remember this" would leave yesterday's copy behind.
                model.savePassphrase(context: environment.settingsSyncContext())
            }
        )
    }
}
