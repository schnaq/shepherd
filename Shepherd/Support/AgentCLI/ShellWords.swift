import Foundation

/// Splits a command template into argv elements the way a POSIX shell would — without ever
/// running one.
///
/// ADR 0011 allows a *configurable command template* for agent CLIs other than Claude Code.
/// A template is a convenience for the user, never a shell: Shepherd splits it here and hands
/// the resulting array straight to `Process`. Nothing is ever passed to `sh -c`, and the prompt
/// is substituted **after** splitting, so a prompt containing quotes, semicolons or newlines
/// stays exactly one argv element and cannot become another command.
enum ShellWords {
    /// Why a template could not be split.
    enum Failure: LocalizedError, Equatable {
        /// A quote was opened and never closed.
        case unterminatedQuote(String)
        /// The template ends in a dangling backslash.
        case trailingBackslash

        var errorDescription: String? {
            switch self {
            case .unterminatedQuote(let quote):
                return String(localized: "The command template has an unterminated \(quote) quote.")
            case .trailingBackslash:
                return String(localized: "The command template ends with a stray backslash.")
            }
        }
    }

    /// Splits a command line into argv elements.
    ///
    /// Supported: whitespace separation, `'single quotes'` (everything literal),
    /// `"double quotes"` (backslash escapes `"`, `\`, `$` and `` ` `` only, as in a real shell),
    /// and backslash escapes outside quotes. Everything else — globbing, variable expansion,
    /// pipes, redirection — is deliberately *not* interpreted: those characters end up as
    /// literal argument text.
    /// - Parameter input: The template.
    /// - Returns: The argv elements, in order.
    /// - Throws: ``Failure`` when a quote or escape is left open.
    static func split(_ input: String) throws -> [String] {
        enum Mode { case plain, single, double }

        let characters = Array(input)
        var words: [String] = []
        var current = ""
        var isOpen = false
        var mode = Mode.plain
        var index = 0

        while index < characters.count {
            let character = characters[index]
            switch mode {
            case .plain:
                if character == "\\" {
                    guard index + 1 < characters.count else { throw Failure.trailingBackslash }
                    current.append(characters[index + 1])
                    isOpen = true
                    index += 1
                } else if character == "'" {
                    mode = .single
                    isOpen = true
                } else if character == "\"" {
                    mode = .double
                    isOpen = true
                } else if character.isWhitespace {
                    if isOpen {
                        words.append(current)
                        current = ""
                        isOpen = false
                    }
                } else {
                    current.append(character)
                    isOpen = true
                }
            case .single:
                if character == "'" {
                    mode = .plain
                } else {
                    current.append(character)
                }
            case .double:
                if character == "\\", index + 1 < characters.count,
                   ["\"", "\\", "$", "`"].contains(characters[index + 1]) {
                    current.append(characters[index + 1])
                    index += 1
                } else if character == "\"" {
                    mode = .plain
                } else {
                    current.append(character)
                }
            }
            index += 1
        }

        switch mode {
        case .single: throw Failure.unterminatedQuote("'")
        case .double: throw Failure.unterminatedQuote("\"")
        case .plain: break
        }
        if isOpen { words.append(current) }
        return words
    }
}
