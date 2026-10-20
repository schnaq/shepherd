#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The two system services shared code reaches for — pasteboard and browser — behind one name,
/// so a file shared with the iPhone target needs no `#if` of its own (ADR 0044).
///
/// Only what a shared file actually calls lives here. A Mac-only file keeps talking to AppKit
/// directly; routing it through this type would buy nothing and hide which code is shared.
@MainActor
enum PlatformServices {
    /// Replaces the general pasteboard's contents with plain text.
    /// - Parameter string: The text to copy.
    static func copyToPasteboard(_ string: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #else
        UIPasteboard.general.string = string
        #endif
    }

    /// Opens a URL in the default browser, or in the app that claims it.
    /// - Parameter url: The page to open.
    static func open(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }
}
