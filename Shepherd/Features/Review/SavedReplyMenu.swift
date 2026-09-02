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
///
/// **The "Suggested" section is an addition to this list, never a replacement of it.** When the
/// caller has worked out which replies fit the thread (`SavedReplySuggestionCoordinator`), the two
/// best ones are repeated at the top under a header and a divider — and the full list below stays
/// exactly as it was, in the user's own order, including those two. A reviewer who has learnt where
/// their sixth reply sits in the menu still finds it there, and a reviewer who ignores the section
/// loses nothing: with no suggestions the menu is byte for byte the plain list it has always been.
struct SavedReplyMenu: View {
    /// The replies to offer, in the user's own order.
    let replies: [SavedReply]
    /// The replies to repeat at the top, best first, or empty for no "Suggested" section.
    ///
    /// Ids rather than replies, because the ranking is done from vectors by a type that has no
    /// business carrying UI values around, and because an id that is no longer in ``replies`` —
    /// the reviewer deleted it in Settings while the composer was open — then drops out of the
    /// section by construction instead of showing a row that inserts nothing.
    var suggestedIDs: [SavedReply.ID] = []
    /// Called with the chosen reply's body.
    var onInsert: (String) -> Void
    /// Called shortly before the menu can be opened, so the caller can compute ``suggestedIDs``.
    ///
    /// **Why the hover and not a "menu will open" callback.** SwiftUI's `Menu` has no such
    /// callback; the content closure's evaluation is an implementation detail that also fires on
    /// unrelated state changes, so hanging an embedding off it would be both unreliable and
    /// occasionally per-keystroke. Hovering, on the other hand, is what physically has to happen
    /// before the button can be clicked, and it happens once. A reviewer who opens the menu from
    /// the keyboard without ever pointing at it gets the plain list, which is the same graceful
    /// answer as a Mac without the embedding model — "offered, never inserted" cuts both ways.
    ///
    /// Callers must make this idempotent: a pointer crossing the button three times calls it
    /// three times.
    var onWillOpen: (() -> Void)?
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
                if !suggestedReplies.isEmpty {
                    Section(String(localized: "Suggested")) {
                        ForEach(suggestedReplies) { reply in
                            Button(reply.trimmedName) { onInsert(reply.trimmedBody) }
                        }
                    }
                    Divider()
                }
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
        .onHover { isHovering in
            guard isHovering else { return }
            onWillOpen?()
        }
    }

    /// The suggested replies, in ranking order.
    ///
    /// Resolved against ``replies`` rather than trusted: an id the list no longer carries is
    /// dropped, so the section can never offer a row whose body has been deleted.
    ///
    /// `internal` rather than private so `ShepherdTests` can assert the menu's ordering without
    /// rendering it — a SwiftUI menu's rows are not inspectable, and "the suggestions lead, the
    /// full list follows" is a rule worth a test rather than a screenshot.
    var suggestedReplies: [SavedReply] {
        suggestedIDs.compactMap { id in replies.first { $0.id == id } }
    }
}
