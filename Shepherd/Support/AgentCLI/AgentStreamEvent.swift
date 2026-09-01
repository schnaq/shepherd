import Foundation

/// What a finished agent run reported.
///
/// Claude Code's final `{"type":"result", …}` event carries these fields. When a run produces
/// no result event at all — a custom CLI that does not speak stream-json, or a process that
/// died — Shepherd synthesises one from the exit code instead.
struct AgentRunResult: Sendable, Equatable, Codable {
    /// Whether the run failed (non-zero exit, refusal, cap hit).
    var isError: Bool
    /// The agent's closing message, when it sent one.
    var resultText: String?
    /// What the run cost, in US dollars, as reported by the CLI.
    var totalCostUSD: Double?
    /// How long the run took, in milliseconds.
    var durationMS: Int?
    /// How many turns the agent used.
    var numTurns: Int?
    /// The session id, which can be handed to `--resume` later.
    var sessionID: String?
    /// The CLI's own subtype (`success`, `error_max_turns`, …), shown verbatim when present.
    var subtype: String?

    /// Creates a result.
    init(
        isError: Bool,
        resultText: String? = nil,
        totalCostUSD: Double? = nil,
        durationMS: Int? = nil,
        numTurns: Int? = nil,
        sessionID: String? = nil,
        subtype: String? = nil
    ) {
        self.isError = isError
        self.resultText = resultText
        self.totalCostUSD = totalCostUSD
        self.durationMS = durationMS
        self.numTurns = numTurns
        self.sessionID = sessionID
        self.subtype = subtype
    }
}

/// One decoded line of the agent CLI's newline-delimited JSON stream.
///
/// Decoding is deliberately **tolerant**: an unknown `type`, an unknown content block or an
/// extra field is never fatal, and a line that is not JSON at all is skipped. Claude Code's
/// stream format is versioned but additive, and Shepherd must survive a CLI update that
/// introduces an event it has never heard of.
enum AgentStreamEvent: Sendable, Equatable, Decodable {
    /// The opening `system/init` event; carries the model the CLI resolved.
    case systemInit(model: String?)
    /// A text block from the assistant.
    case assistantText(String)
    /// The agent invoked a tool.
    case toolUse(name: String)
    /// The closing result event.
    case result(AgentRunResult)
    /// A well-formed line Shepherd does not model.
    case unknown

    /// Decodes a single event, keeping the first meaningful one on a multi-block line.
    init(from decoder: any Decoder) throws {
        let line = try AgentStreamLine(from: decoder)
        self = line.events.first ?? .unknown
    }

    /// Decodes one line of the stream.
    ///
    /// One assistant message can hold several content blocks (text plus two tool calls), so a
    /// line maps to zero, one or many events.
    /// - Parameter line: One line of output, without its newline.
    /// - Returns: The events it carries; empty when the line is blank or not JSON.
    static func events(in line: String) -> [AgentStreamEvent] {
        let cleaned = ANSIText.stripped(line).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, let data = cleaned.data(using: .utf8) else { return [] }
        guard let decoded = try? JSONDecoder().decode(AgentStreamLine.self, from: data) else {
            return []
        }
        return decoded.events
    }

    /// Decodes one line of raw output.
    /// - Parameter data: The line's bytes, without its newline.
    /// - Returns: The events it carries.
    static func events(in data: Data) -> [AgentStreamEvent] {
        events(in: String(decoding: data, as: UTF8.self))
    }
}

/// The envelope shared by every line of the stream.
///
/// This is the single place that knows the wire format; ``AgentStreamEvent`` delegates to it so
/// there is only one parser to keep honest.
struct AgentStreamLine: Decodable, Sendable {
    /// The events this line expands to.
    var events: [AgentStreamEvent]

    private enum CodingKeys: String, CodingKey {
        case type
        case subtype
        case message
        case model
        case isError = "is_error"
        case result
        case totalCostUSD = "total_cost_usd"
        case durationMS = "duration_ms"
        case numTurns = "num_turns"
        case sessionID = "session_id"
    }

    private struct Message: Decodable {
        var content: [Block]?

        private enum CodingKeys: String, CodingKey { case content }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            // `content` is an array of blocks in every version that matters; some builds send a
            // bare string for plain text. Both shapes are accepted, anything else is ignored.
            if let blocks = (try? container.decodeIfPresent([Block].self, forKey: .content))
                .flatMap({ $0 }) {
                content = blocks
            } else if let text = (try? container.decodeIfPresent(String.self, forKey: .content))
                .flatMap({ $0 }) {
                content = [Block(type: "text", text: text, name: nil)]
            } else {
                content = nil
            }
        }
    }

    private struct Block: Decodable {
        var type: String?
        var text: String?
        var name: String?

        init(type: String?, text: String?, name: String?) {
            self.type = type
            self.text = text
            self.name = name
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            type = (try? container.decodeIfPresent(String.self, forKey: .type)).flatMap { $0 }
            text = (try? container.decodeIfPresent(String.self, forKey: .text)).flatMap { $0 }
            name = (try? container.decodeIfPresent(String.self, forKey: .name)).flatMap { $0 }
        }

        private enum CodingKeys: String, CodingKey { case type, text, name }
    }

    init(from decoder: any Decoder) throws {
        guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
            events = [.unknown]
            return
        }
        let type = (try? container.decodeIfPresent(String.self, forKey: .type)).flatMap { $0 }
        let subtype = (try? container.decodeIfPresent(String.self, forKey: .subtype)).flatMap { $0 }

        switch type {
        case "system":
            // Only `init` is modelled; later system subtypes fall through as unknown rather
            // than being mistaken for a fresh start.
            guard subtype == nil || subtype == "init" else {
                events = [.unknown]
                return
            }
            let model = (try? container.decodeIfPresent(String.self, forKey: .model)).flatMap { $0 }
            events = [.systemInit(model: model)]

        case "assistant":
            let message = (try? container.decodeIfPresent(Message.self, forKey: .message))
                .flatMap { $0 }
            var found: [AgentStreamEvent] = []
            for block in message?.content ?? [] {
                switch block.type {
                case "text":
                    let text = (block.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { found.append(.assistantText(text)) }
                case "tool_use":
                    if let name = block.name, !name.isEmpty { found.append(.toolUse(name: name)) }
                default:
                    break
                }
            }
            events = found.isEmpty ? [.unknown] : found

        case "result":
            let isError = (try? container.decodeIfPresent(Bool.self, forKey: .isError))
                .flatMap { $0 } ?? (subtype != "success")
            events = [
                .result(
                    AgentRunResult(
                        isError: isError,
                        resultText: (try? container.decodeIfPresent(String.self, forKey: .result))
                            .flatMap { $0 },
                        totalCostUSD: Self.double(container, .totalCostUSD),
                        durationMS: Self.int(container, .durationMS),
                        numTurns: Self.int(container, .numTurns),
                        sessionID: (try? container.decodeIfPresent(String.self, forKey: .sessionID))
                            .flatMap { $0 },
                        subtype: subtype
                    )
                )
            ]

        default:
            events = [.unknown]
        }
    }

    /// Reads a number that may have been written as an integer or a floating-point value.
    private static func double(
        _ container: KeyedDecodingContainer<CodingKeys>,
        _ key: CodingKeys
    ) -> Double? {
        if let value = (try? container.decodeIfPresent(Double.self, forKey: key)).flatMap({ $0 }) {
            return value
        }
        if let value = (try? container.decodeIfPresent(Int.self, forKey: key)).flatMap({ $0 }) {
            return Double(value)
        }
        return nil
    }

    /// Reads an integer that may have been written as a floating-point value.
    private static func int(
        _ container: KeyedDecodingContainer<CodingKeys>,
        _ key: CodingKeys
    ) -> Int? {
        if let value = (try? container.decodeIfPresent(Int.self, forKey: key)).flatMap({ $0 }) {
            return value
        }
        if let value = (try? container.decodeIfPresent(Double.self, forKey: key)).flatMap({ $0 }),
           value.isFinite, abs(value) < 1e15 {
            return Int(value)
        }
        return nil
    }
}

/// Removes terminal escape sequences from CLI output.
///
/// The stream is meant to be pure JSON, but a CLI that thinks it is talking to a terminal (or
/// one that prints a coloured warning before the first event) would otherwise break the decoder
/// for the whole run. Stripping is defensive and cheap.
enum ANSIText {
    /// Strips CSI (`ESC [ … final`) and OSC (`ESC ] … BEL`/`ESC \`) sequences.
    /// - Parameter input: Raw output.
    /// - Returns: The text without escape sequences.
    static func stripped(_ input: String) -> String {
        guard input.utf8.contains(0x1B) else { return input }
        var output = ""
        output.reserveCapacity(input.count)
        let characters = Array(input)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            guard character == "\u{1B}", index + 1 < characters.count else {
                if character != "\u{1B}" { output.append(character) }
                index += 1
                continue
            }
            let next = characters[index + 1]
            if next == "[" {
                var cursor = index + 2
                while cursor < characters.count,
                      !("\u{40}"..."\u{7E}").contains(characters[cursor]) {
                    cursor += 1
                }
                index = min(cursor + 1, characters.count)
            } else if next == "]" {
                var cursor = index + 2
                while cursor < characters.count {
                    if characters[cursor] == "\u{07}" {
                        cursor += 1
                        break
                    }
                    if characters[cursor] == "\u{1B}", cursor + 1 < characters.count,
                       characters[cursor + 1] == "\\" {
                        cursor += 2
                        break
                    }
                    cursor += 1
                }
                index = cursor
            } else {
                index += 2
            }
        }
        return output
    }
}
