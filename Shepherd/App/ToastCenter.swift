import Foundation
import Observation
import SwiftUI

/// A transient message shown along the bottom edge of the window.
///
/// `docs/ARCHITECTURE.md` asks for "undo toast instead of confirm dialogs wherever the action
/// is reversible" — and, just as importantly, errors are surfaced here rather than printed.
struct Toast: Identifiable, Sendable {
    /// How the toast is tinted.
    ///
    /// `Equatable` so a test can assert which tint a write's outcome earned: a parked write and a
    /// refused one say different things *and* look different, and the second half is as much a
    /// part of the message as the first.
    enum Kind: Sendable, Equatable {
        /// Something worked.
        case success
        /// Something needs attention but is not fatal.
        case warning
        /// Something failed.
        case failure
        /// Neutral information.
        case info
    }

    /// The toast's identity.
    let id = UUID()
    /// The message.
    var message: String
    /// The tint.
    var kind: Kind = .info
    /// An optional trailing button ("Undo", "Retry", …).
    var actionTitle: String?
    /// What the trailing button does.
    var action: (@MainActor @Sendable () -> Void)?
    /// How long the toast stays on screen.
    var duration: TimeInterval = 4
}

/// Owns the toast queue for one window.
@MainActor
@Observable
final class ToastCenter {
    /// The toasts currently on screen, newest last.
    private(set) var toasts: [Toast] = []

    /// Creates an empty centre.
    init() {}

    /// Shows a toast and schedules its dismissal.
    /// - Parameter toast: The toast to show.
    func show(_ toast: Toast) {
        toasts.append(toast)
        let id = toast.id
        let duration = toast.duration
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            self?.dismiss(id)
        }
    }

    /// Shows a plain informational message.
    /// - Parameter message: The text.
    func info(_ message: String) {
        show(Toast(message: message, kind: .info))
    }

    /// Shows a success message.
    /// - Parameter message: The text.
    func success(_ message: String) {
        show(Toast(message: message, kind: .success))
    }

    /// Surfaces an error. Errors are never printed to the console (project rule).
    ///
    /// The words come from ``Swift/Error/userFacingDescription``, the app's one rule for turning
    /// a failure into a sentence — so a toast, a settings card and an inline composer report the
    /// same error the same way.
    /// - Parameters:
    ///   - error: The failure.
    ///   - context: A short prefix describing what was being attempted.
    func failure(_ error: any Error, context: String? = nil) {
        let description = error.userFacingDescription
        let message = context.map { "\($0): \(description)" } ?? description
        show(Toast(message: message, kind: .failure, duration: 8))
    }

    /// Removes a toast early.
    /// - Parameter id: The toast's identity.
    func dismiss(_ id: UUID) {
        toasts.removeAll { $0.id == id }
    }
}

/// The stack of toasts, overlaid on the window's bottom edge.
///
/// Bottom *centre* rather than the corner, and ``RootView/toastAlignment`` says why.
struct ToastStackView: View {
    /// The centre to render.
    let center: ToastCenter

    var body: some View {
        // Centred with the stack's own alignment, to match where ``RootView`` places it: two
        // toasts of different widths right-aligned against each other under a centred anchor
        // read as one of them being indented.
        VStack(alignment: .center, spacing: 8) {
            ForEach(center.toasts) { toast in
                toastRow(toast)
            }
        }
        .padding(16)
        .animation(.snappy(duration: 0.18), value: center.toasts.count)
    }

    private func toastRow(_ toast: Toast) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(color(for: toast.kind))
                .frame(width: 7, height: 7)
            Text(toast.message)
                .font(.system(size: 12))
                .foregroundStyle(Theme.text)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle = toast.actionTitle, let action = toast.action {
                Button(actionTitle) {
                    action()
                    center.dismiss(toast.id)
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.accentText)
            }
            Button {
                center.dismiss(toast.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.textMuted)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(String(localized: "Dismiss")))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: 420, alignment: .leading)
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Theme.border, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func color(for kind: Toast.Kind) -> Color {
        switch kind {
        case .success: return Theme.success
        case .warning: return Theme.pending
        case .failure: return Theme.failure
        case .info: return Theme.accent
        }
    }
}
