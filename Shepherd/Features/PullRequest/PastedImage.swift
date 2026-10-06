import AppKit
import GitHubKit
import ShepherdCore
import SwiftUI
import UniformTypeIdentifiers

/// Where an image pasted into a comment field goes: the repository GitHub scopes it to, the
/// client that uploads it, and where a failure is said.
struct ImageUploadTarget {
    let repo: RepoRef
    let github: GitHubClient
    let toasts: ToastCenter
}

extension ImageUploadTarget {
    /// The target for a pull request's fields, through the session and toasts its writes use.
    init(repo: RepoRef, actions: PullRequestActions) {
        self.init(repo: repo, github: actions.session.github, toasts: actions.toasts)
    }
}

/// ⌘V of a screenshot into a comment field, as on github.com: the image is uploaded and the field
/// gets `![name](url)` in its place.
///
/// The upload is not an outbox write (ADR 0006): it needs the network now, and what it produces
/// is text in a field rather than a change on GitHub. While it runs, the field holds a
/// placeholder, and the senders refuse to send a text that still has one
/// (``containsPendingUpload(_:)``), so a comment can never be posted with a hole where the
/// image should be.
enum PastedImage {
    /// GitHub's own limit for an image on a comment.
    static let maxBytes = 10 * 1024 * 1024

    /// What every placeholder starts with. Markdown rather than UI text, so it is not localized.
    private static let placeholderPrefix = "![Uploading "

    /// Whether the text still waits for an upload to finish.
    static func containsPendingUpload(_ text: String) -> Bool {
        text.contains(placeholderPrefix)
    }

    /// The image on the pasteboard and a name for it, or `nil` when the paste is text — which
    /// the field then pastes as it always did.
    ///
    /// A copied image file comes first, by its own name; a pasteboard that also has text (a
    /// copied file carries its name as text) is otherwise a text paste. A screenshot copied with
    /// ⌃⇧⌘4 has image data and no text.
    static func image(on pasteboard: NSPasteboard) -> (data: Data, name: String, contentType: String)? {
        if let url = (pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL])?.first,
           url.isFileURL,
           let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image),
           let data = try? Data(contentsOf: url) {
            return (data, url.lastPathComponent, type.preferredMIMEType ?? "application/octet-stream")
        }
        if pasteboard.string(forType: .string) != nil { return nil }
        if let png = pasteboard.data(forType: .png) { return (png, "Screenshot.png", "image/png") }
        guard let image = NSImage(pasteboard: pasteboard),
              let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { return nil }
        return (png, "Screenshot.png", "image/png")
    }

    /// Uploads the image and swaps its placeholder for the Markdown that shows it, or takes the
    /// placeholder out again and says why.
    @MainActor
    static func upload(
        _ image: (data: Data, name: String, contentType: String),
        into text: Binding<String>,
        target: ImageUploadTarget
    ) async {
        guard image.data.count <= maxBytes else {
            target.toasts.show(Toast(
                message: String(localized: "Images can be up to 10 MB on GitHub."),
                kind: .warning
            ))
            return
        }
        let placeholder = "\(placeholderPrefix)\(image.name)…](\(UUID().uuidString))"
        let current = text.wrappedValue
        let separator = current.isEmpty || current.hasSuffix("\n") ? "" : "\n"
        text.wrappedValue = current + separator + placeholder + "\n"
        do {
            let url = try await target.github.uploadAttachment(
                image.data,
                name: image.name,
                contentType: image.contentType,
                repo: target.repo
            )
            text.wrappedValue = text.wrappedValue.replacingOccurrences(
                of: placeholder,
                with: "![\(image.name)](\(url.absoluteString))"
            )
        } catch {
            text.wrappedValue = text.wrappedValue.replacingOccurrences(of: placeholder + "\n", with: "")
                .replacingOccurrences(of: placeholder, with: "")
            target.toasts.failure(
                error,
                context: String(localized: "Could not upload the image — attach it on GitHub instead")
            )
        }
    }
}
