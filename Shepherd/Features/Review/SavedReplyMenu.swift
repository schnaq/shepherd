import ShepherdCore
import SwiftUI

/// The little "insert a saved reply" button that sits next to every comment field.
///
/// **Why a menu and not the ⌘K palette.** The palette is a full-screen overlay with its own focused
/// search field (`CommandPaletteView`), and every composer in the review screen is a sheet or a
/// popover; opening the palette from one would take the focus away from the very field the text has
/// to land in, and there is no way for a palette row to know which of the three fields was focused
/// a moment ago. A palette command would therefore have to *guess* a target, which is the one thing
/// a text-inserting command must not do. The menu is attached to the field it writes into, so it can
/// never insert into the wrong one, and it is also the discoverable placement: the button is visible
/// while the user is typing, rather than behind a shortcut they have to know about.
///
/// Insertion appends after a blank line rather than at the caret — see
/// ``ShepherdCore/SavedReply/inserting(_:into:)`` for why SwiftUI leaves no honest alternative.
struct SavedReplyMenu: View {
    /// The replies to offer, in the user's own order.
    let replies: [SavedReply]
    /// Called with the chosen reply's body.
    var onInsert: (String) -> Void
    /// The control's height, so it lines up with the buttons beside it.
    var height: CGFloat = 24

    var body: some View {
        Menu {
            if replies.isEmpty {
                // A disabled row rather than an empty menu: an empty menu looks broken, and this
                // says where the list comes from.
                Button(String(localized: "No saved replies — add them in Settings → Replies")) {}
                    .disabled(true)
            } else {
                ForEach(replies) { reply in
                    Button(reply.trimmedName) { onInsert(reply.trimmedBody) }
                }
            }
        } label: {
            Image(systemName: "text.badge.plus")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(height: height)
        .help(String(localized: "Insert a saved reply"))
        .accessibilityLabel(String(localized: "Insert a saved reply"))
    }
}
