import SwiftUI

/// The signed-out screen: device flow first, personal access token as the fallback (ADR 0004).
struct SignInView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var model = SignInModel()
    @FocusState private var isTokenFieldFocused: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                header
                if let grant = model.grant {
                    deviceCodeCard(userCode: grant.userCode)
                } else {
                    deviceFlowCard
                }
                separator
                tokenCard
                if let message = model.errorMessage {
                    errorBanner(message)
                }
                footnote
            }
            .frame(maxWidth: 460)
            .padding(.horizontal, 32)
            .padding(.vertical, 44)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.background)
    }

    // MARK: - Sections

    private var header: some View {
        VStack(spacing: 8) {
            ShepherdMark(size: 34)
            Text(String(localized: "Shepherd"))
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Theme.textStrong)
            Text(String(localized: "One review inbox for everything your agents open."))
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(.bottom, 4)
    }

    private var deviceFlowCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                CardTitle(String(localized: "SIGN IN WITH GITHUB"))
                Text(String(
                    localized: "Shepherd shows a short code, you approve it on github.com. No password, no client secret."
                ))
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

                Button {
                    model.startDeviceFlow(environment: environment)
                } label: {
                    HStack(spacing: 6) {
                        if model.step == .awaitingDeviceApproval {
                            ProgressView().controlSize(.small)
                        }
                        Text(String(localized: "Continue with device flow"))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!model.isDeviceFlowConfigured || model.isBusy)

                if !model.isDeviceFlowConfigured {
                    Text(String(
                        localized: "This build has no GitHub App client ID (Shepherd/Support/AppConfig.swift is empty), so device flow is off. Use a personal access token below."
                    ))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func deviceCodeCard(userCode: String) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                CardTitle(String(localized: "ENTER THIS CODE ON GITHUB"))
                Text(userCode)
                    .font(Theme.mono(30, weight: .semibold))
                    .foregroundStyle(Theme.textStrong)
                    .kerning(3)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Theme.control, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .textSelection(.enabled)

                HStack(spacing: 8) {
                    Button {
                        model.openVerificationPage()
                    } label: {
                        Text(String(localized: "Open github.com/login/device"))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PrimaryButtonStyle())

                    Button {
                        model.copyUserCode()
                    } label: {
                        Label(
                            model.didCopyCode
                                ? String(localized: "Copied")
                                : String(localized: "Copy"),
                            systemImage: model.didCopyCode ? "checkmark" : "doc.on.doc"
                        )
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }

                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(String(localized: "Waiting for you to approve…"))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Button(String(localized: "Cancel")) {
                        model.cancelDeviceFlow()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.accentText)
                }
            }
        }
    }

    private var separator: some View {
        HStack(spacing: 10) {
            Rectangle().fill(Theme.border).frame(height: 1)
            Text(String(localized: "or"))
                .font(.system(size: 11))
                .foregroundStyle(Theme.textMuted)
            Rectangle().fill(Theme.border).frame(height: 1)
        }
    }

    private var tokenCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                CardTitle(String(localized: "PERSONAL ACCESS TOKEN"))
                Text(String(
                    localized: "A fine-grained token with “Pull requests: Read & write”. Stored in your Keychain, never on disk."
                ))
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

                SecureField(String(localized: "github_pat_…"), text: $model.patText)
                    .textFieldStyle(.plain)
                    .font(Theme.mono(12))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Theme.control, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Theme.controlBorder, lineWidth: 1)
                    )
                    .focused($isTokenFieldFocused)
                    .onSubmit {
                        model.submitPersonalAccessToken(environment: environment)
                    }

                Button {
                    model.submitPersonalAccessToken(environment: environment)
                } label: {
                    HStack(spacing: 6) {
                        if model.step == .verifying {
                            ProgressView().controlSize(.small)
                        }
                        Text(String(localized: "Sign in with token"))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(model.isBusy || model.patText.isEmpty)
            }
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 12))
                .foregroundStyle(Theme.failure)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            Theme.failure.opacity(0.10),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
    }

    private var footnote: some View {
        Text(String(
            localized: "Shepherd talks to github.com only — plus the AI endpoint you configure yourself. Everything it downloads stays on this Mac."
        ))
        .font(.system(size: 11))
        .foregroundStyle(Theme.textMuted)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// The little shepherd's crook mark from the mockups.
struct ShepherdMark: View {
    /// The mark's edge length.
    var size: CGFloat = 16

    var body: some View {
        Image(systemName: "hare")
            .font(.system(size: size * 0.8, weight: .regular))
            .foregroundStyle(Theme.agent)
            .accessibilityHidden(true)
    }
}
