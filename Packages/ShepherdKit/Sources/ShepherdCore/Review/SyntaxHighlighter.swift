/// What a run of source text is, for colouring. The absence of a span means plain text.
///
/// Deliberately coarse — eight kinds, not a TextMate scope tree — because the renderers map each
/// to one colour pair and a reviewer reads a diff, not a theme. The app owns the palette.
public enum SyntaxKind: UInt8, Sendable, Hashable {
    /// A reserved word, a `#` directive, a Markdown heading or list marker.
    case keyword
    /// A known type name, or a capitalised identifier where the language capitalises types.
    case type
    /// A string literal, a template, a Markdown code span or fenced block.
    case string
    /// A line or block comment.
    case comment
    /// A number, a char literal, or a constant such as `true`, `nil` or `None`.
    case literal
    /// A JSON or TOML key, a YAML key, a `$variable`, a Clojure/Ruby `:keyword`, a link target.
    case property
    /// An `@attribute`, a Rust `#[…]`, Clojure `^meta`, a YAML anchor or tag.
    case annotation
    /// An XML or HTML tag.
    case tag
}

/// One coloured run inside a line, as UTF-8 byte offsets into that line's text.
///
/// Bytes rather than `String.Index`, because both consumers — the renderer's `AttributedString`
/// and ``IntraLineDiff``'s change ranges — then cut the line at the same offsets with no index
/// conversion. Every boundary lands on an ASCII byte or on the line's end (identifiers swallow
/// whole runs of non-ASCII bytes), so a range never cuts through a scalar.
public struct SyntaxSpan: Sendable, Hashable {
    /// What the run is.
    public var kind: SyntaxKind
    /// The run's UTF-8 byte range within the line.
    public var range: Range<Int>

    /// Creates a span.
    /// - Parameters:
    ///   - kind: What the run is.
    ///   - range: The run's UTF-8 byte range within the line.
    public init(_ kind: SyntaxKind, _ range: Range<Int>) {
        self.kind = kind
        self.range = range
    }
}

/// What a line leaves open for the next one: the only cross-line memory the tokenizer has.
public enum SyntaxState: Sendable, Hashable {
    /// Nothing open; the next line starts fresh.
    case normal
    /// Inside a block comment; `depth` counts nesting where the language nests (Swift, Rust).
    case blockComment(depth: Int)
    /// A string that may span lines: a triple-quoted one, a backtick template, or a plain quote in
    /// a language where strings span lines (shell, Clojure).
    case string(quote: UInt8, triple: Bool)
    /// Inside a Markdown fenced code block.
    case fence
}

/// A line-at-a-time tokenizer: keywords, types, strings, comments, numbers per language family.
///
/// Not a parser and not trying to be one: it is what makes a diff *readable*, at a cost a phone
/// pays without noticing (about 0.3–0.5 µs a row on an M4). It is our own code rather than
/// Monaco's Monarch grammars because those only exist inside the 3 MB web bundle, and rather than
/// swift-syntax or tree-sitter because either is a new dependency covering a fraction of the
/// languages. Pure stdlib, so the Linux leg tests it — the native list on the Mac and the iPhone
/// companion (ADR 0044) both render from it.
///
/// Families: Swift, TypeScript/JavaScript, Go, Rust, the C-like group (Kotlin, Java, C#, C, C++,
/// Objective-C, PHP, CSS, GraphQL), Python, Ruby, shell and Dockerfile, Clojure, JSON, TOML, SQL,
/// plus three special modes for YAML, Markdown and XML/HTML.
///
/// Known, accepted gaps: regex literals in JS, Rust raw strings, YAML block scalars, Swift raw
/// strings `#"…"#`, and languages nested inside a Markdown fence (the fence body is one string).
public enum SyntaxHighlighter {
    /// Longer lines get no spans: a minified or generated line is read by nobody, and colouring
    /// it only costs time.
    static let maxLineBytes = 2_000

    /// What a hunk most likely starts inside, since the lines before it are not in the patch.
    ///
    /// The first delimiter the hunk shows decides: a block-comment closer before any opener, or a
    /// Swift/Kotlin `"""` standing at the start of its line with text after it (where only a
    /// closer can stand), means the hunk began inside one. A bare `"""` is an opener only when
    /// the line before it ends an expression head (`=`, `(`, `,`, `:`, `[`). Without this, that
    /// closer reads as an opener and the rest of the hunk is coloured inside-out.
    ///
    /// A heuristic with a known blind spot: a hunk that starts inside a Python docstring, a Go
    /// backtick string or a JS template is not detected and starts at ``SyntaxState/normal``.
    /// - Parameters:
    ///   - lines: The hunk's lines, without their diff markers.
    ///   - language: The file's language.
    /// - Returns: The state to tokenize the hunk's first line in.
    public static func initialState(forHunk lines: some Sequence<String>, language: SourceLanguage) -> SyntaxState {
        guard let g = Grammar.all[language], g.mode == .code else { return .normal }
        let closesTriple = g.triple.contains(q2) && g.apostrophe == .none || language == .kotlin
        var previousLast: UInt8 = 0  // last non-blank byte of the line before
        for line in lines {
            var text = line
            let verdict: (found: Bool, state: SyntaxState, last: UInt8) = text.withUTF8 { b in
                let last = b.last { $0 != space && $0 != tab } ?? 0
                var i = 0
                // The quote byte a string is open on: a `*/` inside one (`"<br\s*/?>"`, a glob
                // like `'**/*.ts'`) is not a comment closer. Any of the grammar's quotes counts.
                var openQuote: UInt8?
                let lead = b.prefix { $0 == space || $0 == tab }.count
                while i + 1 < b.count {
                    if closesTriple, i + 2 < b.count, b[i] == q2, b[i + 1] == q2, b[i + 2] == q2 {
                        guard i == lead else { return (true, .normal, last) }  // `x = """` opens
                        // Only a closer may have text after it (`""")`, `""",`). A bare `"""`
                        // is either; it opens when the line before it ends an expression head.
                        if i + 3 < b.count { return (true, .string(quote: q2, triple: true), last) }
                        let opensAfter = Array("=(,:[".utf8).contains(previousLast)
                        return (true, opensAfter ? .normal : .string(quote: q2, triple: true), last)
                    }
                    let c = b[i]
                    if let quote = openQuote {
                        if c == quote { openQuote = nil }
                    } else if g.quotes.contains(c) || (c == q1 && g.apostrophe == .string) {
                        openQuote = c
                    }
                    if c == backslash {
                        i += 2
                        continue
                    }
                    let inQuote = openQuote != nil
                    if !inQuote, !g.blockOpen.isEmpty, c == UInt8(ascii: "*"), b[i + 1] == UInt8(ascii: "/") {
                        return (true, .blockComment(depth: 1), last)
                    }
                    if !inQuote, !g.blockOpen.isEmpty, c == UInt8(ascii: "/"), b[i + 1] == UInt8(ascii: "*") {
                        return (true, .normal, last)
                    }
                    i += 1
                }
                return (false, .normal, last)
            }
            if verdict.found { return verdict.state }
            previousLast = verdict.last
        }
        return .normal
    }

    /// Tokenizes one line, given what the previous line left open.
    ///
    /// Call it once per line in order, threading `state` through, so a comment or string opened on
    /// one line colours the next. Plain-text languages and lines over the length cap return no
    /// spans and leave `state` alone.
    /// - Parameters:
    ///   - line: The line's text, without its diff marker or newline.
    ///   - language: The file's language.
    ///   - state: What the previous line left open; updated to what this line leaves open.
    /// - Returns: The coloured runs, in order and non-overlapping.
    public static func tokenize(_ line: String, language: SourceLanguage, state: inout SyntaxState) -> [SyntaxSpan] {
        guard let grammar = Grammar.all[language], line.utf8.count <= maxLineBytes else { return [] }
        var text = line
        return text.withUTF8 { bytes in
            var lexer = Lexer(b: bytes, g: grammar)
            switch grammar.mode {
            case .code: lexer.code(state: &state)
            case .yaml: lexer.yaml()
            case .markdown: lexer.markdown(state: &state)
            case .xml: lexer.xml(state: &state)
            }
            return lexer.spans
        }
    }
}

// MARK: - Grammars

private struct Grammar: Sendable {
    enum Mode: Sendable { case code, yaml, markdown, xml }
    enum CharQuote: Sendable { case string, charLiteral, none }

    var mode: Mode = .code
    var lineComments: [[UInt8]] = []
    /// `#` opens a comment only at the start of a line or after whitespace (shell, YAML, TOML).
    var hashNeedsSpace = false
    var blockOpen: [UInt8] = []
    var blockClose: [UInt8] = []
    var blockNests = false
    var quotes: [UInt8] = [q2]
    var apostrophe: CharQuote = .string
    var multilineQuotes: Set<UInt8> = []
    var triple: Set<UInt8> = []
    /// Opener of code inside a string (`\(` in Swift, `${` in JS templates and Kotlin).
    var interpolation: [UInt8] = []
    /// Only strings with this quote interpolate (JS: backticks); `nil` means all.
    var interpolationQuote: UInt8?
    var keywords: Set<String> = []
    var constants: Set<String> = []
    var types: Set<String> = []
    var capitalizedIsType = true
    var caseInsensitive = false
    var annotationPrefix: UInt8?
    /// `#ident` is a directive (`#if`, `#include`, `#available`).
    var hashDirective = false
    /// Rust's `#[…]` attributes.
    var hashBracketAttribute = false
    var variablePrefix: UInt8?
    /// Clojure/Ruby `:keyword` → property.
    var colonKeyword = false
    var extraIdent: Set<UInt8> = []
    /// A string immediately followed by `:` is a key (JSON).
    var stringKeys = false
    /// An identifier immediately followed by `=` at line start is a key (TOML).
    var bareKeys = false
    /// Clojure `\c` characters.
    var backslashChar = false

    /// Built once: a grammar's word sets are not something to rebuild per line.
    static let all: [SourceLanguage: Grammar] = Dictionary(
        uniqueKeysWithValues: SourceLanguage.allCases.compactMap { l in of(l).map { (l, $0) } })

    static func words(_ s: String) -> Set<String> { Set(s.split(separator: " ").map(String.init)) }

    static func of(_ language: SourceLanguage) -> Grammar? {
        var g = Grammar()
        switch language {
        case .plaintext: return nil
        case .swift:
            g.lineComments = [Array("//".utf8)]
            g.blockOpen = Array("/*".utf8)
            g.blockClose = Array("*/".utf8)
            g.blockNests = true
            g.apostrophe = .none
            g.triple = [q2]
            g.interpolation = Array("\\(".utf8)
            g.annotationPrefix = at
            g.hashDirective = true
            g.keywords = words("actor any as associatedtype async await break case catch class consume continue convenience default defer deinit didSet do dynamic else enum extension fallthrough fileprivate final for func get guard if import in indirect infix init inout internal is isolated lazy let mutating nonisolated nonmutating open operator optional override package postfix precedencegroup prefix private protocol public repeat required rethrows return set some static struct subscript super switch throw throws try typealias unowned var weak where while willSet Self self sending borrowing consuming")
            g.constants = words("true false nil")
        case .typescript, .javascript:
            g.lineComments = [Array("//".utf8)]
            g.blockOpen = Array("/*".utf8)
            g.blockClose = Array("*/".utf8)
            g.quotes = [q2, q1, bt]
            g.multilineQuotes = [bt]
            g.interpolation = Array("${".utf8)
            g.interpolationQuote = bt
            g.annotationPrefix = at
            g.extraIdent = [dollar]
            g.keywords = words("abstract as async await break case catch class const constructor continue debugger declare default delete do else enum export extends finally for from function get if implements import in infer instanceof interface is keyof let namespace new of private protected public readonly return satisfies set static super switch this throw try type typeof var void while with yield")
            g.constants = words("true false null undefined NaN Infinity")
            g.types = words("string number boolean any unknown never object symbol bigint void")
        case .go:
            g.lineComments = [Array("//".utf8)]
            g.blockOpen = Array("/*".utf8)
            g.blockClose = Array("*/".utf8)
            g.quotes = [q2, bt]
            g.multilineQuotes = [bt]
            g.apostrophe = .charLiteral
            g.keywords = words("break case chan const continue default defer else fallthrough for func go goto if import interface map package range return select struct switch type var")
            g.constants = words("true false nil iota")
            g.types = words("bool byte complex64 complex128 error float32 float64 int int8 int16 int32 int64 rune string uint uint8 uint16 uint32 uint64 uintptr any")
            g.capitalizedIsType = false  // Go capitalises every export, not just types
        case .rust:
            g.lineComments = [Array("//".utf8)]
            g.blockOpen = Array("/*".utf8)
            g.blockClose = Array("*/".utf8)
            g.blockNests = true
            g.apostrophe = .charLiteral
            g.multilineQuotes = [q2]
            g.hashBracketAttribute = true
            g.keywords = words("as async await break const continue crate dyn else enum extern fn for if impl in let loop match mod move mut pub ref return self Self static struct super trait type unsafe use where while macro_rules")
            g.constants = words("true false None Some Ok Err")
            g.types = words("i8 i16 i32 i64 i128 isize u8 u16 u32 u64 u128 usize f32 f64 bool char str")
        case .kotlin, .java, .csharp, .c, .cpp, .objectiveC, .php, .css, .graphql:
            g.lineComments = [Array("//".utf8)]
            g.blockOpen = Array("/*".utf8)
            g.blockClose = Array("*/".utf8)
            g.apostrophe = language == .php || language == .css ? .string : .charLiteral
            g.annotationPrefix = at
            g.hashDirective = [.c, .cpp, .objectiveC, .csharp].contains(language)
            if language == .kotlin {
                g.triple = [q2]
                g.interpolation = Array("${".utf8)
            }
            if language == .php {
                g.variablePrefix = dollar
                g.lineComments.append([hash])
            }
            if language == .css {
                g.extraIdent = [dash]
                g.capitalizedIsType = false
            }
            if language == .graphql {
                g.lineComments = [[hash]]
                g.blockOpen = []
                g.triple = [q2]
            }
            g.keywords = words("abstract break case catch class const continue default do else enum extends final finally for fun function if implements import in interface internal is new object override package private protected public return sealed static struct super switch this throw throws try typedef union using val var void when while namespace query mutation fragment on type input scalar extends include define ifndef endif")
            g.constants = words("true false null nil NULL YES NO")
            g.types = words("int long short char float double bool boolean byte unsigned signed string String")
        case .python:
            g.lineComments = [[hash]]
            g.quotes = [q2, q1]
            g.triple = [q2, q1]
            g.annotationPrefix = at
            g.keywords = words("and as assert async await break class continue def del elif else except finally for from global if import in is lambda match case nonlocal not or pass raise return try while with yield")
            g.constants = words("True False None")
            g.types = words("int str float bool bytes list dict set tuple object type")
        case .ruby:
            g.lineComments = [[hash]]
            g.quotes = [q2, q1]
            g.colonKeyword = true
            g.annotationPrefix = at
            g.keywords = words("alias and begin break case class def defined do else elsif end ensure for if in module next not or redo rescue retry return self super then undef unless until when while yield require attr_reader attr_accessor")
            g.constants = words("true false nil")
        case .shell, .dockerfile:
            g.lineComments = [[hash]]
            g.hashNeedsSpace = true
            g.quotes = [q2, q1, bt]
            g.multilineQuotes = [q2, q1, bt]
            g.variablePrefix = dollar
            g.capitalizedIsType = false
            g.extraIdent = [dash]
            g.keywords = words("if then else elif fi for while until do done case esac in function select return local export readonly declare set unset shift exit break continue source trap eval exec FROM RUN CMD COPY ADD ENV ARG WORKDIR ENTRYPOINT EXPOSE USER LABEL VOLUME")
            g.constants = words("true false")
        case .clojure:
            g.lineComments = [[semicolon]]
            g.quotes = [q2]
            g.multilineQuotes = [q2]
            g.apostrophe = .none
            g.colonKeyword = true
            g.backslashChar = true
            g.annotationPrefix = caret
            g.extraIdent = Set("-?!*+<>=/.&%'".utf8)
            g.keywords = words("def defn defn- defmacro defmulti defmethod defprotocol defrecord deftype defonce fn fn* let letfn if if-let if-not when when-let when-not when-some cond condp case do loop recur ns require import use try catch finally throw quote var -> ->> some-> some->> cond-> as-> doto for doseq dotimes binding with-open reify proxy extend-protocol extend-type new set! comment")
            g.constants = words("nil true false")
        case .json:
            g.lineComments = [Array("//".utf8)]
            g.blockOpen = Array("/*".utf8)
            g.blockClose = Array("*/".utf8)
            g.apostrophe = .none
            g.stringKeys = true
            g.capitalizedIsType = false
            g.constants = words("true false null")
        case .toml:
            g.lineComments = [[hash]]
            g.hashNeedsSpace = true
            g.quotes = [q2, q1]
            g.triple = [q2, q1]
            g.bareKeys = true
            g.capitalizedIsType = false
            g.extraIdent = [dash]
            g.constants = words("true false inf nan")
        case .sql:
            g.lineComments = [Array("--".utf8)]
            g.blockOpen = Array("/*".utf8)
            g.blockClose = Array("*/".utf8)
            g.quotes = [q1, q2]
            g.caseInsensitive = true
            g.capitalizedIsType = false
            g.keywords = words("select from where and or not insert into values update set delete create table index view drop alter add column primary key foreign references join left right inner outer on as group by order having limit offset union all distinct case when then else end is in like between exists default unique if begin commit rollback transaction with returning")
            g.constants = words("null true false")
            g.types = words("integer int text real blob varchar boolean timestamp date numeric")
        case .yaml:
            g.mode = .yaml
            g.lineComments = [[hash]]
            g.hashNeedsSpace = true
            g.constants = words("true false null yes no on off ~ True False Null")
        case .markdown: g.mode = .markdown
        case .xml, .html: g.mode = .xml
        }
        return g
    }
}

// MARK: - Bytes

fileprivate let q2 = UInt8(ascii: "\""), q1 = UInt8(ascii: "'"), bt = UInt8(ascii: "`"), at = UInt8(ascii: "@")
fileprivate let hash = UInt8(ascii: "#"), dollar = UInt8(ascii: "$"), dash = UInt8(ascii: "-"), caret = UInt8(ascii: "^")
fileprivate let semicolon = UInt8(ascii: ";"), colon = UInt8(ascii: ":"), backslash = UInt8(ascii: "\\")
fileprivate let space = UInt8(ascii: " "), tab = UInt8(ascii: "\t"), lt = UInt8(ascii: "<"), gt = UInt8(ascii: ">")

extension SyntaxHighlighter {
    /// A space, a tab or a stray `\r`: what both the tokenizer and ``IntraLineDiff`` skip.
    @inline(__always) static func isSpace(_ c: UInt8) -> Bool { c == space || c == tab || c == 13 }

    /// A byte of an identifier: ASCII letters, digits, `_`, and every non-ASCII byte, so a word
    /// swallows whole multibyte scalars and no range built from it cuts one.
    @inline(__always) static func isWordByte(_ c: UInt8) -> Bool {
        (c | 0x20) &- 97 < 26 || c &- 48 < 10 || c == 95 || c >= 0x80
    }
}

@inline(__always) private func isDigit(_ c: UInt8) -> Bool { c &- 48 < 10 }
// Unqualified forwarders for the lexer below, which uses them on nearly every byte.
@inline(__always) private func isSpace(_ c: UInt8) -> Bool { SyntaxHighlighter.isSpace(c) }
@inline(__always) private func isWordByte(_ c: UInt8) -> Bool { SyntaxHighlighter.isWordByte(c) }

// MARK: - Lexer

private struct Lexer {
    let b: UnsafeBufferPointer<UInt8>
    let g: Grammar
    var spans: [SyntaxSpan] = []

    init(b: UnsafeBufferPointer<UInt8>, g: Grammar) { self.b = b; self.g = g }

    var n: Int { b.count }

    mutating func emit(_ kind: SyntaxKind, _ from: Int, _ to: Int) {
        guard to > from else { return }
        // Adjacent runs of one kind merge, so a renderer appends fewer pieces.
        if let last = spans.last, last.kind == kind, last.range.upperBound == from {
            spans[spans.count - 1].range = last.range.lowerBound..<to
        } else {
            spans.append(SyntaxSpan(kind, from..<to))
        }
    }

    func matches(_ seq: [UInt8], at i: Int) -> Bool {
        guard !seq.isEmpty, i + seq.count <= n else { return false }
        for k in 0..<seq.count where b[i + k] != seq[k] { return false }
        return true
    }

    func isIdentByte(_ c: UInt8) -> Bool { isWordByte(c) || g.extraIdent.contains(c) }

    func word(_ from: Int, _ to: Int) -> String {
        // ≤ 15 bytes is a small string: no heap allocation for the keyword lookup.
        String(decoding: UnsafeBufferPointer(rebasing: b[from..<to]), as: UTF8.self)
    }

    // MARK: Code

    mutating func code(state: inout SyntaxState) {
        var i = 0
        switch state {
        case .normal, .fence: break
        case .blockComment(let depth):
            i = blockComment(from: 0, depth: depth, state: &state)
        case .string(let quote, let triple):
            i = string(from: 0, quote: quote, triple: triple, bodyStart: 0, state: &state)
        }
        if state == .normal { scanCode(from: i, to: n, state: &state) }
    }

    func firstIndex(of seq: [UInt8]) -> Int? {
        guard !seq.isEmpty, n >= seq.count else { return nil }
        for i in 0...(n - seq.count) where matches(seq, at: i) { return i }
        return nil
    }


    /// The body of `code`: everything between `from` and `to` in the normal state.
    mutating func scanCode(from: Int, to: Int, state: inout SyntaxState) {
        var i = from
        var lineStart = true  // only whitespace so far
        while i < to {
            let c = b[i]
            if isSpace(c) { i += 1; continue }
            defer { lineStart = false }

            // Comments.
            if !g.blockOpen.isEmpty, matches(g.blockOpen, at: i) {
                i = blockComment(from: i, depth: 0, state: &state)
                if state != .normal { return }
                continue
            }
            if g.lineComments.contains(where: { matches($0, at: i) }),
                !(g.hashNeedsSpace && c == hash && i > 0 && !isSpace(b[i - 1]))
            {
                emit(.comment, i, to)
                return
            }
            // Strings.
            if g.quotes.contains(c) || (c == q1 && g.apostrophe == .string) {
                i = keyOrString(at: i, to: to, state: &state)
                if state != .normal { return }
                continue
            }
            if c == q1 && g.apostrophe == .charLiteral, let end = charLiteral(at: i, to: to) {
                emit(.literal, i, end); i = end; continue
            }
            // Numbers: a digit not glued to an identifier.
            if isDigit(c) {
                var j = i + 1
                while j < to, isWordByte(b[j]) || (b[j] == UInt8(ascii: ".") && j + 1 < to && isDigit(b[j + 1])) { j += 1 }
                emit(.literal, i, j); i = j; continue
            }
            // Prefixed forms.
            if c == hash, g.hashBracketAttribute, i + 1 < to, b[i + 1] == UInt8(ascii: "[") || b[i + 1] == UInt8(ascii: "!") {
                var j = i + 1
                while j < to, b[j] != UInt8(ascii: "]") { j += 1 }
                emit(.annotation, i, min(to, j + 1)); i = min(to, j + 1); continue
            }
            if (c == hash && g.hashDirective) || (c == g.annotationPrefix) || (c == g.variablePrefix) || (c == colon && g.colonKeyword) {
                var j = i + 1
                if c == g.variablePrefix, j < to, b[j] == UInt8(ascii: "{") {
                    while j < to, b[j] != UInt8(ascii: "}") { j += 1 }
                    emit(.property, i, min(to, j + 1)); i = min(to, j + 1); continue
                }
                if c == caret, j < to, b[j] == colon { j += 1 }
                if c == colon, j < to, b[j] == colon { j += 1 }  // ::namespaced
                while j < to, isIdentByte(b[j]) { j += 1 }
                if j > i + 1 {
                    let kind: SyntaxKind =
                        c == hash ? .keyword : c == g.variablePrefix ? .property : c == colon ? .property : .annotation
                    emit(kind, i, j); i = j; continue
                }
                // `$1`, `$?`, `$@` in shell.
                if c == g.variablePrefix, j < to, !isSpace(b[j]) { emit(.property, i, j + 1); i = j + 1; continue }
            }
            if c == backslash, g.backslashChar, i + 1 < to {
                var j = i + 2
                while j < to, isWordByte(b[j]) { j += 1 }
                emit(.literal, i, j); i = j; continue
            }
            // Identifiers.
            if isWordByte(c) || g.extraIdent.contains(c) {
                var j = i + 1
                while j < to, isIdentByte(b[j]) { j += 1 }
                classify(i, j, lineStart: lineStart, to: to)
                i = j; continue
            }
            i += 1
        }
    }

    mutating func classify(_ i: Int, _ j: Int, lineStart: Bool, to: Int) {
        if g.bareKeys, lineStart {
            var k = j
            while k < to, isSpace(b[k]) { k += 1 }
            if k < to, b[k] == UInt8(ascii: "=") { emit(.property, i, j); return }
        }
        let w = g.caseInsensitive ? word(i, j).lowercased() : word(i, j)
        if g.keywords.contains(w) { emit(.keyword, i, j) }
        else if g.constants.contains(w) { emit(.literal, i, j) }
        else if g.types.contains(w) { emit(.type, i, j) }
        else if g.capitalizedIsType, b[i] &- 65 < 26 { emit(.type, i, j) }
    }

    /// A Rust/C/Go char literal: `'x'`, `'\n'`, `'\u{1F600}'`, `'ä'` — and nothing else, so a
    /// Rust lifetime `'a` stays plain instead of opening a string that eats the line.
    func charLiteral(at i: Int, to: Int) -> Int? {
        let limit = min(to, i + 12)
        var j = i + 1
        if j < limit, b[j] == backslash { j += 2 } else {
            // One character: a single ASCII byte or one multibyte scalar.
            guard j < limit else { return nil }
            j += b[j] < 0x80 ? 1 : (b[j] >= 0xF0 ? 4 : b[j] >= 0xE0 ? 3 : 2)
            return j < to && b[j] == q1 ? j + 1 : nil
        }
        while j < limit, b[j] != q1 { j += 1 }
        return j < limit ? j + 1 : nil
    }

    /// A string at `i`, or a JSON key when the grammar has those. Returns where scanning resumes.
    mutating func keyOrString(at i: Int, to: Int, state: inout SyntaxState) -> Int {
        let quote = b[i]
        let triple = g.triple.contains(quote) && i + 2 < to && b[i + 1] == quote && b[i + 2] == quote
        let before = spans.count
        let end = string(from: i, quote: quote, triple: triple, bodyStart: i + (triple ? 3 : 1), state: &state)
        if g.stringKeys, state == .normal {
            var k = end
            while k < to, isSpace(b[k]) { k += 1 }
            if k < to, b[k] == colon {
                spans.removeSubrange(before...)
                emit(.property, i, end)
            }
        }
        return end
    }

    /// Scans a string body from `bodyStart`; the span starts at `from` (the quote, or 0 when the
    /// string was carried in from the previous line). Leaves `state` set when it runs off the line.
    mutating func string(from: Int, quote: UInt8, triple: Bool, bodyStart: Int, state: inout SyntaxState) -> Int {
        var start = from
        var j = bodyStart
        let interpolates = !g.interpolation.isEmpty && (g.interpolationQuote == nil || g.interpolationQuote == quote)
        while j < n {
            let c = b[j]
            if c == backslash, !(interpolates && matches(g.interpolation, at: j)) {
                j += 2; continue
            }
            if interpolates, matches(g.interpolation, at: j), let close = closingBracket(after: j + g.interpolation.count) {
                emit(.string, start, j + g.interpolation.count)
                // A lexer that ends at the closing bracket: a comment or string left open inside
                // (`"\(a /* )"`) would otherwise run to the end of the line, past spans still to
                // come, and break the in-order, non-overlapping promise renderers rely on.
                var inner = SyntaxState.normal
                var sub = Lexer(b: UnsafeBufferPointer(rebasing: b[..<close]), g: g)
                sub.scanCode(from: j + g.interpolation.count, to: close, state: &inner)
                for span in sub.spans { emit(span.kind, span.range.lowerBound, span.range.upperBound) }
                start = close; j = close + 1; continue
            }
            if c == g.variablePrefix, quote == q2, j + 1 < n, isWordByte(b[j + 1]) || b[j + 1] == UInt8(ascii: "{") {
                emit(.string, start, j)
                var k = j + 1
                if b[k] == UInt8(ascii: "{") { while k < n, b[k] != UInt8(ascii: "}") { k += 1 }; k = min(n, k + 1) }
                else { while k < n, isWordByte(b[k]) { k += 1 } }
                emit(.property, j, k); start = k; j = k; continue
            }
            if c == quote {
                if !triple { emit(.string, start, j + 1); state = .normal; return j + 1 }
                if j + 2 < n, b[j + 1] == quote, b[j + 2] == quote { emit(.string, start, j + 3); state = .normal; return j + 3 }
            }
            j += 1
        }
        emit(.string, start, n)
        state = triple || g.multilineQuotes.contains(quote) ? .string(quote: quote, triple: triple) : .normal
        return n
    }

    /// The `)` or `}` that closes an interpolation opened just before `from`, skipping nested
    /// strings, so `"\(flag ? "a" : "b")"` stays one string.
    func closingBracket(after from: Int) -> Int? {
        var depth = 0
        var j = from
        while j < n {
            let c = b[j]
            if c == q2 || c == q1 || c == bt {
                j += 1
                while j < n, b[j] != c { j += b[j] == backslash ? 2 : 1 }
            } else if c == UInt8(ascii: "(") || c == UInt8(ascii: "{") { depth += 1 }
            else if c == UInt8(ascii: ")") || c == UInt8(ascii: "}") {
                if depth == 0 { return j }
                depth -= 1
            }
            j += 1
        }
        return nil
    }

    mutating func blockComment(from: Int, depth: Int, state: inout SyntaxState) -> Int {
        var d = depth
        var j = from
        if state == .normal { j += g.blockOpen.count; d = 1 }
        if d == 0 { d = 1 }
        while j < n {
            if matches(g.blockClose, at: j) {
                d -= 1; j += g.blockClose.count
                if d == 0 || !g.blockNests { emit(.comment, from, j); state = .normal; return j }
                continue
            }
            if g.blockNests, matches(g.blockOpen, at: j) { d += 1; j += g.blockOpen.count; continue }
            j += 1
        }
        emit(.comment, from, n)
        state = .blockComment(depth: d)
        return n
    }

    // MARK: YAML

    /// `key:` → property, then a value: quoted string, number, constant, `&anchor`/`*alias`/`!tag`,
    /// and a `#` comment only after whitespace — so `description: don't` never opens a string.
    mutating func yaml() {
        var i = 0
        while i < n, isSpace(b[i]) { i += 1 }
        if i < n, b[i] == dash, i + 1 == n || isSpace(b[i + 1]) {
            emit(.keyword, i, i + 1); i += 1
            while i < n, isSpace(b[i]) { i += 1 }
        }
        if i < n, b[i] == hash { emit(.comment, i, n); return }
        if matches(Array("---".utf8), at: i) { emit(.comment, i, n); return }
        // A key: an unquoted run up to `: ` / `:` at end, or a quoted key.
        var k = i
        if k < n, b[k] == q2 || b[k] == q1 {
            let q = b[k]; k += 1
            while k < n, b[k] != q { k += 1 }
            k = min(n, k + 1)
        } else {
            while k < n, b[k] != colon, b[k] != hash, !(b[k] == space && k + 1 < n && b[k + 1] == hash) { k += 1 }
        }
        if k < n, b[k] == colon, k + 1 == n || isSpace(b[k + 1]), k > i {
            emit(.property, i, k)
            i = k + 1
        }
        while i < n, isSpace(b[i]) { i += 1 }
        guard i < n else { return }
        let c = b[i]
        if c == q2 || c == q1 {
            var j = i + 1
            while j < n, b[j] != c { j += (c == q2 && b[j] == backslash) ? 2 : 1 }
            emit(.string, i, min(n, j + 1)); i = min(n, j + 1)
        } else if c == UInt8(ascii: "&") || c == UInt8(ascii: "*") || c == UInt8(ascii: "!") {
            var j = i + 1
            while j < n, !isSpace(b[j]) { j += 1 }
            emit(.annotation, i, j); i = j
        } else if c == UInt8(ascii: "|") || c == gt {
            emit(.keyword, i, i + 1); i += 1
        } else {
            // A scalar to the comment or the end: a literal if it is one, plain otherwise.
            var j = i
            while j < n, !(b[j] == hash && isSpace(b[j - 1])) { j += 1 }
            var e = j
            while e > i, isSpace(b[e - 1]) { e -= 1 }
            let w = word(i, e)
            if g.constants.contains(w) || Double(w) != nil { emit(.literal, i, e) }
            i = j
        }
        // Whatever follows: a trailing comment.
        while i < n {
            if b[i] == hash, i == 0 || isSpace(b[i - 1]) { emit(.comment, i, n); return }
            i += 1
        }
    }

    // MARK: Markdown

    mutating func markdown(state: inout SyntaxState) {
        var i = 0
        while i < n, isSpace(b[i]) { i += 1 }
        let fence = matches(Array("```".utf8), at: i) || matches(Array("~~~".utf8), at: i)
        if state == .fence {
            if fence { emit(.comment, 0, n); state = .normal } else { emit(.string, 0, n) }
            return
        }
        if case .blockComment = state {
            if let close = firstIndex(of: Array("-->".utf8)) { emit(.comment, 0, close + 3); state = .normal; i = close + 3 }
            else { emit(.comment, 0, n); return }
        }
        if fence { emit(.comment, i, n); state = .fence; return }
        if i < n, b[i] == hash {
            var j = i
            while j < n, b[j] == hash { j += 1 }
            if j - i <= 6, j == n || b[j] == space { emit(.keyword, i, n); return }
        }
        if i < n, b[i] == gt { emit(.comment, i, n); return }
        // List markers: `-`, `*`, `+`, `1.`.
        if i + 1 < n, b[i] == dash || b[i] == UInt8(ascii: "*") || b[i] == UInt8(ascii: "+"), b[i + 1] == space {
            emit(.keyword, i, i + 1); i += 1
        } else {
            var j = i
            while j < n, isDigit(b[j]) { j += 1 }
            if j > i, j + 1 < n, b[j] == UInt8(ascii: "."), b[j + 1] == space { emit(.keyword, i, j + 1); i = j + 1 }
        }
        // Inline: `code`, [text](url), <!-- comment -->. Apostrophes are prose, never strings.
        while i < n {
            let c = b[i]
            if c == bt {
                var j = i + 1
                while j < n, b[j] != bt { j += 1 }
                if j < n { emit(.string, i, j + 1); i = j + 1; continue }
            } else if c == UInt8(ascii: "]"), i + 1 < n, b[i + 1] == UInt8(ascii: "(") {
                var j = i + 2
                while j < n, b[j] != UInt8(ascii: ")") { j += 1 }
                emit(.property, i + 1, min(n, j + 1)); i = min(n, j + 1); continue
            } else if c == lt, matches(Array("<!--".utf8), at: i) {
                if let close = firstIndex(of: Array("-->".utf8)), close > i { emit(.comment, i, close + 3); i = close + 3; continue }
                emit(.comment, i, n); state = .blockComment(depth: 1); return
            }
            i += 1
        }
    }

    // MARK: XML / HTML

    mutating func xml(state: inout SyntaxState) {
        var i = 0
        if case .blockComment = state {
            guard let close = firstIndex(of: Array("-->".utf8)) else { emit(.comment, 0, n); return }
            emit(.comment, 0, close + 3); state = .normal; i = close + 3
        }
        var inTag = false
        while i < n {
            let c = b[i]
            if c == lt, matches(Array("<!--".utf8), at: i) {
                var j = i + 4
                while j < n, !matches(Array("-->".utf8), at: j) { j += 1 }
                if j < n { emit(.comment, i, j + 3); i = j + 3; continue }
                emit(.comment, i, n); state = .blockComment(depth: 1); return
            }
            if c == lt {
                var j = i + 1
                if j < n, b[j] == UInt8(ascii: "/") || b[j] == UInt8(ascii: "?") || b[j] == UInt8(ascii: "!") { j += 1 }
                while j < n, isWordByte(b[j]) || b[j] == dash || b[j] == colon || b[j] == UInt8(ascii: ".") { j += 1 }
                emit(.tag, i, j); i = j; inTag = true; continue
            }
            if inTag {
                if c == gt || (c == UInt8(ascii: "/") && i + 1 < n && b[i + 1] == gt) {
                    let e = c == gt ? i + 1 : i + 2
                    emit(.tag, i, e); i = e; inTag = false; continue
                }
                if c == q2 || c == q1 {
                    var j = i + 1
                    while j < n, b[j] != c { j += 1 }
                    emit(.string, i, min(n, j + 1)); i = min(n, j + 1); continue
                }
                if isWordByte(c) {
                    var j = i + 1
                    while j < n, isWordByte(b[j]) || b[j] == dash || b[j] == colon { j += 1 }
                    emit(.property, i, j); i = j; continue
                }
            }
            i += 1
        }
    }
}
