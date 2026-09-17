import ShepherdCore
import SwiftUI

/// Renders a Markdown body: headings, lists, fenced code and quotes, not only inline formatting.
///
/// It used to be one `Text` holding `AttributedString(markdown:)` with
/// `.inlineOnlyPreservingWhitespace`, which is exactly as much Markdown as that initialiser can
/// do well — bold, italics, code spans and links — and nothing above the line. Pull request
/// bodies are mostly *not* that: an agent writes "## Summary", a bulleted list of what changed
/// and a fenced block of the command it ran, and all of it arrived on screen as literal text
/// with its own syntax still in it.
///
/// So the block level is parsed first (``ShepherdCore/MarkdownDocument``) and each block is
/// rendered as itself, with the inline parser still doing the half it is good at inside each one.
struct MarkdownText: View {
    /// The Markdown source.
    let markdown: String
    /// The body font size. Headings and code are derived from it.
    var size: CGFloat = 12.5

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Indexed, because the same line can legitimately appear twice in one body — two
            // list items reading "- packages/ui: Jest green" under different headings are two
            // items, and identifying them by content would collapse them into one.
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    private var blocks: [MarkdownBlock] { MarkdownDocument.blocks(from: markdown) }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(inline(text))
                .font(.system(size: headingSize(level), weight: .semibold))
                .foregroundStyle(Theme.textStrong)
                .fixedSize(horizontal: false, vertical: true)
                // Air above a heading and none below it, so a heading reads as belonging to what
                // follows rather than floating between two sections.
                .padding(.top, 6)

        case .paragraph(let text):
            Text(inline(text))
                .font(.system(size: size))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

        case .listItem(let text, let marker, let depth):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: marker)
                    .font(.system(size: size))
                    .foregroundStyle(Theme.textMuted)
                    // A fixed width so the text of every item in a list starts on the same
                    // column, including "10." beside "9." — and monospaced digits so a numbered
                    // list does not wobble as the numbers grow.
                    .monospacedDigit()
                    .frame(minWidth: 16, alignment: .leading)
                Text(inline(text))
                    .font(.system(size: size))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, CGFloat(depth) * 16)

        case .codeBlock(let code, _):
            // Horizontally scrollable rather than wrapped: a wrapped command line is a command
            // line nobody can copy correctly, and this is the one place in a body where the
            // author's own line breaks carry meaning.
            ScrollView(.horizontal, showsIndicators: false) {
                Text(verbatim: code)
                    .font(Theme.mono(size - 0.5))
                    .foregroundStyle(Theme.text)
                    .textSelection(.enabled)
                    .padding(10)
            }
            .background(Theme.raised, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Theme.border, lineWidth: 1)
            )

        case .quote(let text):
            HStack(alignment: .top, spacing: 8) {
                Rectangle()
                    .fill(Theme.border)
                    .frame(width: 2)
                Text(inline(text))
                    .font(.system(size: size))
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .fixedSize(horizontal: false, vertical: true)

        case .rule:
            Divider().overlay(Theme.hairline)
        }
    }

    /// How much bigger a heading is than the body. Three steps for six levels, because a body
    /// that uses `#####` is not asking for a fifth distinct size — it is asking for "smaller".
    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return size + 4
        case 2: return size + 2
        case 3: return size + 1
        default: return size
        }
    }

    /// Inline Markdown within one block, which is what `AttributedString` is good at.
    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        )) ?? AttributedString(text)
    }
}
