import SwiftUI

/// The signed-out screen on the iPhone: the device flow first, a personal access token as the
/// fallback (ADR 0004), on the Mac's own ``SignInModel``.
///
/// **System browser, not `ASWebAuthenticationSession`.** The model already copies the user code
/// and opens `github.com/login/device` the moment GitHub issues it (`PlatformServices.open`, Safari
/// on the phone), which is the Mac's "one tap, not three". The device flow has no redirect back to
/// the app, so an authentication session would only ever end with the user's Cancel, and v1 ships
/// no URL type to return through anyway (ADR 0044). While Safari is in front the app is suspended
/// and the poll simply sleeps; it carries on when the scene is active again, and the code stays on
/// screen in case the tab was closed.
///
/// Errors appear inline under the action, never as an alert. The success haptic is the root
/// view's (``PhoneEnvironment/signInCount``): this view is gone by the time the session opens.
struct PhoneSignInView: View {
    @Environment(PhoneEnvironment.self) private var environment
    @State private var model = SignInModel()
    @State private var isTokenExpanded = false
    @FocusState private var isTokenFieldFocused: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .largeTitle) private var markSize: CGFloat = 76
    /// One column for the three promise glyphs, so their texts line up whatever each symbol's width.
    @ScaledMetric(relativeTo: .body) private var promiseIconWidth: CGFloat = 28

    var body: some View {
        ScrollView {
            VStack(spacing: 32) {
                header
                if let grant = model.grant {
                    deviceCodeCard(userCode: grant.userCode)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                } else {
                    promises
                    if pinsButtonInline { signInButton }
                }
                if let message = model.errorMessage {
                    errorLine(message)
                }
                tokenSection
            }
            .padding(.horizontal, 24)
            .padding(.top, 48)
            .padding(.bottom, 24)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
            .animation(.snappy, value: model.grant?.userCode)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.background)
        // Pinned to the bottom edge, with the system's scroll-edge effect under it, at ordinary
        // sizes. At the accessibility sizes the button and its footnote are taller than half the
        // screen, so they scroll with the rest instead of covering it.
        .safeAreaBar(edge: .bottom) {
            if model.grant == nil, !pinsButtonInline {
                signInButton
            }
        }
        .sensoryFeedback(.selection, trigger: model.didCopyCode) { _, copied in copied }
        .sensoryFeedback(.error, trigger: model.errorMessage) { _, message in message != nil }
        .onAppear {
            // A build without a client ID has only the token path; open it rather than leave a
            // disabled button as the only thing on screen.
            if !model.isDeviceFlowConfigured { isTokenExpanded = true }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 14) {
            Image(systemName: "hare.fill")
                .font(Theme.type(.largeTitle, weight: .semibold))
                .foregroundStyle(Theme.agent)
                .frame(width: markSize, height: markSize)
                .background(
                    Theme.agent.opacity(0.14),
                    in: RoundedRectangle(cornerRadius: markSize * 0.28, style: .continuous)
                )
                .accessibilityHidden(true)
            VStack(spacing: 8) {
                Text(String(localized: "Shepherd"))
                    .font(Theme.type(.largeTitle, weight: .bold))
                    .foregroundStyle(Theme.textStrong)
                Text(String(localized: "One review inbox for everything your agents open."))
                    .font(Theme.type(.body))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
        }
    }

    /// What signing in gets you, in three lines — the screen is otherwise one button.
    private var promises: some View {
        VStack(alignment: .leading, spacing: 18) {
            promise(
                systemImage: "tray.full",
                text: String(localized: "Every pull request that waits for you, in one list.")
            )
            promise(
                systemImage: "checkmark.bubble",
                text: String(localized: "Approve, comment and merge. Offline, it all goes out once you're back.")
            )
            promise(
                systemImage: "lock.shield",
                text: String(localized: "Your token stays in the Keychain, your data on this iPhone.")
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func promise(systemImage: String, text: String) -> some View {
        Label {
            Text(text)
                .font(Theme.type(.subheadline))
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage)
                .font(Theme.type(.body, weight: .medium))
                .foregroundStyle(Theme.accent)
                .frame(width: promiseIconWidth)
        }
    }

    // MARK: - Device flow

    /// Whether the sign-in button scrolls with the content rather than pinning to the bottom.
    private var pinsButtonInline: Bool { dynamicTypeSize.isAccessibilitySize }

    private var signInButton: some View {
        VStack(spacing: 10) {
            Button {
                model.startDeviceFlow(environment: environment)
            } label: {
                HStack(spacing: 8) {
                    if model.step == .awaitingDeviceApproval {
                        ProgressView()
                    }
                    Label(String(localized: "Sign in with GitHub"), systemImage: "person.badge.key.fill")
                }
                .font(Theme.type(.headline))
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .tint(Theme.accent)
            .controlSize(.extraLarge)
            .disabled(!model.isDeviceFlowConfigured || model.isBusy)
            Text(String(localized: "Shepherd copies a short code and opens GitHub. Paste it there, approve, and come back."))
                .font(Theme.type(.footnote))
                .foregroundStyle(Theme.textMuted)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, pinsButtonInline ? 0 : 24)
        .padding(.bottom, pinsButtonInline ? 0 : 8)
        .frame(maxWidth: 520)
    }

    private func deviceCodeCard(userCode: String) -> some View {
        VStack(spacing: 18) {
            Text(String(localized: "ENTER THIS CODE ON GITHUB"))
                .font(Theme.type(.caption, weight: .semibold))
                .kerning(0.6)
                .foregroundStyle(Theme.textMuted)
            Text(verbatim: userCode)
                .font(Theme.mono(.largeTitle, weight: .semibold))
                .kerning(4)
                .foregroundStyle(Theme.textStrong)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .textSelection(.enabled)
                // Spelled out, so VoiceOver reads "A B C D" rather than trying a word.
                .accessibilityLabel(Text(verbatim: userCode.map(String.init).joined(separator: " ")))
            VStack(spacing: 10) {
                Button {
                    model.openVerificationPage()
                } label: {
                    Label(String(localized: "Open GitHub"), systemImage: "safari")
                        .font(Theme.type(.headline))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .tint(Theme.accent)
                .controlSize(.large)
                Button {
                    model.copyUserCode()
                } label: {
                    Label(
                        model.didCopyCode ? String(localized: "Copied") : String(localized: "Copy"),
                        systemImage: model.didCopyCode ? "checkmark" : "doc.on.doc"
                    )
                    .font(Theme.type(.headline))
                    .frame(maxWidth: .infinity)
                    .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            Divider().overlay(Theme.hairline)
            HStack(spacing: 10) {
                ProgressView()
                Text(String(localized: "Waiting for you to approve…"))
                    .font(Theme.type(.subheadline))
                    .foregroundStyle(Theme.textSecondary)
                Spacer(minLength: 8)
                Button(String(localized: "Cancel")) {
                    model.cancelDeviceFlow()
                }
                .font(Theme.type(.subheadline, weight: .semibold))
                .tint(Theme.accentText)
            }
        }
        .padding(20)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Personal access token

    private var tokenSection: some View {
        DisclosureGroup(isExpanded: $isTokenExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                Text(String(
                    localized: "A fine-grained token with “Pull requests: Read & write”. Stored in your Keychain, never on disk."
                ))
                .font(Theme.type(.footnote))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                SecureField(String(localized: "github_pat_…"), text: $model.patText)
                    .font(Theme.mono(.body))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(.password)
                    .submitLabel(.go)
                    .focused($isTokenFieldFocused)
                    .onSubmit { model.submitPersonalAccessToken(environment: environment) }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(Theme.control, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                Button {
                    isTokenFieldFocused = false
                    model.submitPersonalAccessToken(environment: environment)
                } label: {
                    HStack(spacing: 8) {
                        if model.step == .verifying {
                            ProgressView()
                        }
                        Text(String(localized: "Sign in with token"))
                    }
                    .font(Theme.type(.headline))
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(model.isBusy || model.patText.isEmpty)
            }
            .padding(.top, 12)
        } label: {
            Text(String(localized: "Use a personal access token"))
                .font(Theme.type(.subheadline, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
        }
        .tint(Theme.textSecondary)
        .padding(.horizontal, 4)
    }

    // MARK: - Errors

    private func errorLine(_ message: String) -> some View {
        Label {
            Text(message)
                .font(Theme.type(.footnote))
                .foregroundStyle(Theme.failure)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(Theme.type(.footnote))
                .foregroundStyle(Theme.failure)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
