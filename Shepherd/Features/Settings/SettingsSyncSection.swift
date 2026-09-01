import GitHubKit
import ShepherdCore
import SwiftUI

/// Settings → Sync → "Sync across Macs (encrypted)" (ADR 0014).
///
/// The whole feature in one place: where the bucket is, who may write to it, what protects the
/// contents, and three buttons. Everything is behind an enable toggle that is off on a fresh
/// install, so a user who never wants this never sees a field they have to reason about.
///
/// The section is deliberately wordy about the one thing that cannot be undone — a lost
/// passphrase is lost data — because there is no recovery path by design and a user has to learn
/// that *before* they upload, not after.
struct SettingsSyncSection: View {
    @Environment(AppEnvironment.self) private var environment
    /// The sync model, owned by the tab so the fields survive a tab switch.
    let model: SettingsSyncModel

    @State private var saveError: String?
    @State private var isConfirmingDownload = false

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                CardTitle(String(localized: "SYNC ACROSS MACS (ENCRYPTED)"))
                Toggle(String(localized: "Keep settings in an S3-compatible bucket"), isOn: enabledBinding)
                Text(String(
                    localized: "Your settings and your secrets are encrypted on this Mac with a passphrase you choose, then stored as one object in a bucket you own. The bucket operator — and anyone who can read the bucket — sees ciphertext only."
                ))
                .font(.system(size: 11))
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)

                if environment.settings.settingsSyncEnabled {
                    Divider().overlay(Theme.hairline)
                    bucketFields
                    Divider().overlay(Theme.hairline)
                    credentialFields
                    Divider().overlay(Theme.hairline)
                    passphraseFields
                    Divider().overlay(Theme.hairline)
                    actions
                    status
                }
            }
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
    }

    // MARK: - Where the object lives

    @ViewBuilder
    private var bucketFields: some View {
        LabeledField(
            label: String(localized: "Endpoint"),
            placeholder: "https://object.storage.eu01.onstackit.cloud",
            text: endpointBinding
        )
        LabeledField(
            label: String(localized: "Bucket"),
            placeholder: "my-shepherd-settings",
            text: bucketBinding
        )
        LabeledField(
            label: String(localized: "Region"),
            placeholder: "eu01",
            text: regionBinding
        )
        LabeledField(
            label: String(localized: "Prefix"),
            placeholder: S3ObjectLocation.defaultPrefix,
            text: prefixBinding
        )
        HStack(spacing: 8) {
            Text(String(localized: "Addressing"))
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 74, alignment: .leading)
            Picker(String(localized: "Addressing"), selection: addressingBinding) {
                ForEach(S3AddressingStyle.allCases) { style in
                    Text(style.title).tag(style)
                }
            }
            .labelsHidden()
        }
        if let location = environment.settings.settingsSyncLocation, let url = location.url {
            Text(url.absoluteString)
                .font(Theme.mono(10.5))
                .foregroundStyle(Theme.textMuted)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
        } else if let problem = configurationProblem {
            Label(problem, systemImage: "exclamationmark.triangle")
                .font(.system(size: 11))
                .foregroundStyle(Theme.pending)
                .fixedSize(horizontal: false, vertical: true)
        }
        Text(String(
            localized: "Path style works with every S3-compatible provider and is the safe default. https only: the object carries your tokens, so plain HTTP is refused even on this machine."
        ))
        .font(.system(size: 11))
        .foregroundStyle(Theme.textMuted)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Who may write to it

    @ViewBuilder
    private var credentialFields: some View {
        LabeledField(
            label: String(localized: "Key id"),
            placeholder: "…",
            text: accessKeyBinding
        )
        HStack(spacing: 8) {
            Text(String(localized: "Secret"))
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 74, alignment: .leading)
            SecureField(String(localized: "secret access key"), text: secretKeyBinding)
                .textFieldStyle(.roundedBorder)
        }
        HStack(spacing: 8) {
            Button(String(localized: "Save keys")) {
                saveError = model.saveCredentials(context: environment.settingsSyncContext())
            }
            .buttonStyle(SecondaryButtonStyle(height: 28))
            if model.hasStoredCredentials {
                Text(String(localized: "Access keys are stored in your Keychain."))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textMuted)
            }
        }
        if let saveError {
            Text(saveError)
                .font(.system(size: 11))
                .foregroundStyle(Theme.failure)
        }
        Text(String(
            localized: "These only need read and write access to this one object. The keys never leave your Keychain and are used to sign requests, not sent as data."
        ))
        .font(.system(size: 11))
        .foregroundStyle(Theme.textMuted)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - What protects the contents

    @ViewBuilder
    private var passphraseFields: some View {
        HStack(spacing: 8) {
            Text(String(localized: "Passphrase"))
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 74, alignment: .leading)
            SecureField(String(localized: "at least 12 characters"), text: passphraseBinding)
                .textFieldStyle(.roundedBorder)
        }
        Toggle(String(localized: "Remember passphrase in Keychain"), isOn: rememberBinding)
            .toggleStyle(.checkbox)
        Text(String(
            localized: "The passphrase is never uploaded and never written to preferences. It is what turns into the encryption key, so if you lose it the object in the bucket is unreadable — there is no recovery and no reset. Use the same passphrase on every Mac."
        ))
        .font(.system(size: 11))
        .foregroundStyle(Theme.textMuted)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Actions

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 8) {
            Button(String(localized: "Upload settings")) {
                let context = environment.settingsSyncContext()
                Task { await model.upload(context: context) }
            }
            .buttonStyle(SecondaryButtonStyle(height: 28))
            .disabled(!canAct)

            Button(String(localized: "Download settings")) {
                let context = environment.settingsSyncContext()
                Task { await model.prepareDownload(context: context) }
            }
            .buttonStyle(SecondaryButtonStyle(height: 28))
            .disabled(!canAct)

            Button(String(localized: "Check remote")) {
                let context = environment.settingsSyncContext()
                Task { await model.checkRemote(context: context) }
            }
            .buttonStyle(SecondaryButtonStyle(height: 28))
            .disabled(environment.settings.settingsSyncLocation == nil
                || model.state == .running)

            if model.state == .running {
                ProgressView().controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        AsyncActionStatusLine(state: model.state)
        if let line = historyLine {
            Text(line)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textMuted)
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
