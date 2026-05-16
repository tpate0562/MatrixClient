import Foundation
import SwiftUI

/// Lightweight syntax highlighter for Matrix code blocks. Tokenizes source by language
/// and returns an `AttributedString` whose runs carry GitHub-dark-ish foreground colours.
/// The view layer (`CodeBlockView`) wraps the result in a bordered, dark-backed box so
/// the chrome extends across the full width of the message bubble, not just behind glyphs.
///
/// Designed for chat-scale snippets, not editor-grade fidelity: hand-rolled lexer with
/// per-language keyword/type tables. Falls back to a generic C-style lexer when the
/// `language-X` class on a `<code>` block is unknown.
enum SyntaxHighlighter {

    // MARK: - Theme

    /// GitHub-dark palette. The background/foreground are used by `CodeBlockView` for
    /// the surrounding container; the individual token colours are applied directly to
    /// `AttributedString` runs.
    struct Theme {
        let background: Color
        let foreground: Color
        let keyword: Color
        let type: Color
        let string: Color
        let number: Color
        let comment: Color
        let function: Color
        let constant: Color
        let operatorSym: Color
        let attribute: Color
    }

    static let theme = Theme(
        background: Color(red: 0x0d/255.0, green: 0x11/255.0, blue: 0x17/255.0),
        foreground: Color(red: 0xe6/255.0, green: 0xed/255.0, blue: 0xf3/255.0),
        keyword:    Color(red: 0xff/255.0, green: 0x7b/255.0, blue: 0x72/255.0),
        type:       Color(red: 0xff/255.0, green: 0xa6/255.0, blue: 0x57/255.0),
        string:     Color(red: 0xa5/255.0, green: 0xd6/255.0, blue: 0xff/255.0),
        number:     Color(red: 0x79/255.0, green: 0xc0/255.0, blue: 0xff/255.0),
        comment:    Color(red: 0x8b/255.0, green: 0x94/255.0, blue: 0x9e/255.0),
        function:   Color(red: 0xd2/255.0, green: 0xa8/255.0, blue: 0xff/255.0),
        constant:   Color(red: 0x79/255.0, green: 0xc0/255.0, blue: 0xff/255.0),
        operatorSym: Color(red: 0xff/255.0, green: 0x7b/255.0, blue: 0x72/255.0),
        attribute:  Color(red: 0x79/255.0, green: 0xc0/255.0, blue: 0xff/255.0)
    )

    // MARK: - Public entry point

    /// Tokenize `code` according to `language` and return an `AttributedString` whose
    /// runs carry the appropriate foreground colour. Whitespace and unrecognized text
    /// get the theme's default foreground. The caller is responsible for the monospace
    /// font and the bordered background.
    static func highlight(code: String, language: String?) -> AttributedString {
        let langKey = (language ?? "").lowercased()
        let lang = languageMap[langKey] ?? Language.fallback
        let tokens = tokenize(code, language: lang)
        var result = AttributedString()
        result.foregroundColor = theme.foreground
        for tok in tokens {
            var part = AttributedString(tok.text)
            part.foregroundColor = tok.color ?? theme.foreground
            result.append(part)
        }
        return result
    }

    // MARK: - Tokenizer

    private struct Language {
        let keywords: Set<String>
        let types: Set<String>
        let constants: Set<String>
        let lineComments: [String]
        let blockComments: [(String, String)]
        let stringDelimiters: [Character]
        let templateStringDelimiters: [Character]   // e.g. backticks for JS, """ Swift handled separately
        let allowsTripleQuoteStrings: Bool
        let identifierStart: (Character) -> Bool
        let identifierContinue: (Character) -> Bool
        let preprocDirective: Character?            // e.g. "#" for C/C++/Obj-C, "@" attributes elsewhere
        let supportsAtAttributes: Bool              // Swift/Java/Kotlin annotations
        let regexDelimiter: Character?              // JS/Ruby/Perl style /.../
        let supportsRawStringPrefix: Bool           // r"...", b"...", f"...", rb"..."

        static let fallback = Language(
            keywords: [], types: [], constants: [],
            lineComments: ["//", "#"],
            blockComments: [("/*", "*/")],
            stringDelimiters: ["\"", "'"],
            templateStringDelimiters: ["`"],
            allowsTripleQuoteStrings: false,
            identifierStart: { $0.isLetter || $0 == "_" },
            identifierContinue: { $0.isLetter || $0.isNumber || $0 == "_" },
            preprocDirective: nil,
            supportsAtAttributes: false,
            regexDelimiter: nil,
            supportsRawStringPrefix: false
        )
    }

    private struct Tok {
        let text: String
        let color: Color?    // nil = use theme.foreground
    }

    private static func tokenize(_ code: String, language lang: Language) -> [Tok] {
        var tokens: [Tok] = []
        var buffer = ""
        let chars = Array(code)
        var i = 0
        let n = chars.count

        func flush() {
            if !buffer.isEmpty {
                tokens.append(Tok(text: buffer, color: nil))
                buffer = ""
            }
        }

        while i < n {
            let c = chars[i]

            // Line comments
            var matchedLineComment = false
            for marker in lang.lineComments {
                if startsWith(chars, at: i, marker) {
                    flush()
                    var end = i
                    while end < n && chars[end] != "\n" { end += 1 }
                    tokens.append(Tok(text: String(chars[i..<end]), color: theme.comment))
                    i = end
                    matchedLineComment = true
                    break
                }
            }
            if matchedLineComment { continue }

            // Block comments
            var matchedBlockComment = false
            for (openMark, closeMark) in lang.blockComments {
                if startsWith(chars, at: i, openMark) {
                    flush()
                    let scanStart = i + openMark.count
                    var end = scanStart
                    while end < n && !startsWith(chars, at: end, closeMark) {
                        end += 1
                    }
                    let final = min(end + closeMark.count, n)
                    tokens.append(Tok(text: String(chars[i..<final]), color: theme.comment))
                    i = final
                    matchedBlockComment = true
                    break
                }
            }
            if matchedBlockComment { continue }

            // Triple-quoted strings (Swift, Python)
            if lang.allowsTripleQuoteStrings, startsWith(chars, at: i, "\"\"\"") {
                flush()
                let end = scanTripleQuote(chars: chars, from: i + 3)
                tokens.append(Tok(text: String(chars[i..<end]), color: theme.string))
                i = end
                continue
            }

            // Raw / prefixed strings: r"...", f"...", b"...", rb"...", u"...", br"..."
            if lang.supportsRawStringPrefix,
               c.isLetter,
               let consumed = scanPrefixedString(chars: chars, at: i, lang: lang) {
                flush()
                tokens.append(Tok(text: String(chars[i..<consumed]), color: theme.string))
                i = consumed
                continue
            }

            // Strings
            if lang.stringDelimiters.contains(c) {
                flush()
                let end = scanString(chars: chars, from: i + 1, quote: c)
                tokens.append(Tok(text: String(chars[i..<end]), color: theme.string))
                i = end
                continue
            }
            if lang.templateStringDelimiters.contains(c) {
                flush()
                let end = scanString(chars: chars, from: i + 1, quote: c)
                tokens.append(Tok(text: String(chars[i..<end]), color: theme.string))
                i = end
                continue
            }

            // Preprocessor / shebang: include the directive name
            if let prep = lang.preprocDirective, c == prep,
               i == 0 || chars[i - 1] == "\n" || isOnlyWhitespaceBefore(chars, at: i) {
                flush()
                var end = i + 1
                while end < n && chars[end].isLetter { end += 1 }
                tokens.append(Tok(text: String(chars[i..<end]), color: theme.keyword))
                i = end
                continue
            }

            // @-attributes / annotations (Swift, Java, Kotlin, Python decorators)
            if lang.supportsAtAttributes, c == "@" {
                flush()
                var end = i + 1
                while end < n, lang.identifierContinue(chars[end]) || chars[end] == "." {
                    end += 1
                }
                if end > i + 1 {
                    tokens.append(Tok(text: String(chars[i..<end]), color: theme.attribute))
                    i = end
                    continue
                }
            }

            // Numbers
            if c.isNumber {
                flush()
                let end = scanNumber(chars: chars, from: i)
                tokens.append(Tok(text: String(chars[i..<end]), color: theme.number))
                i = end
                continue
            }
            if c == "." && i + 1 < n && chars[i + 1].isNumber {
                flush()
                let end = scanNumber(chars: chars, from: i)
                tokens.append(Tok(text: String(chars[i..<end]), color: theme.number))
                i = end
                continue
            }

            // Identifiers
            if lang.identifierStart(c) {
                flush()
                var end = i + 1
                while end < n && lang.identifierContinue(chars[end]) { end += 1 }
                let word = String(chars[i..<end])

                let color: Color?
                if lang.keywords.contains(word) {
                    color = theme.keyword
                } else if lang.types.contains(word) {
                    color = theme.type
                } else if lang.constants.contains(word) {
                    color = theme.constant
                } else if isLikelyType(word) {
                    color = theme.type
                } else {
                    // Function call heuristic: identifier directly followed by (
                    var look = end
                    while look < n && (chars[look] == " " || chars[look] == "\t") { look += 1 }
                    if look < n && chars[look] == "(" {
                        color = theme.function
                    } else {
                        color = nil
                    }
                }
                tokens.append(Tok(text: word, color: color))
                i = end
                continue
            }

            // Operators / punctuation — color a small set so colons/braces don't drown the palette
            if "+-*/%=<>!&|^~?".contains(c) {
                flush()
                tokens.append(Tok(text: String(c), color: theme.operatorSym))
                i += 1
                continue
            }

            buffer.append(c)
            i += 1
        }
        flush()
        return tokens
    }

    // MARK: - Scanner helpers

    private static func startsWith(_ chars: [Character], at i: Int, _ s: String) -> Bool {
        let sChars = Array(s)
        if i + sChars.count > chars.count { return false }
        for k in 0..<sChars.count where chars[i + k] != sChars[k] {
            return false
        }
        return true
    }

    private static func scanString(chars: [Character], from start: Int, quote: Character) -> Int {
        var i = start
        let n = chars.count
        while i < n {
            let c = chars[i]
            if c == "\\" {
                i += 2
                continue
            }
            if c == quote {
                return i + 1
            }
            if c == "\n" && quote != "`" {
                return i
            }
            i += 1
        }
        return n
    }

    private static func scanTripleQuote(chars: [Character], from start: Int) -> Int {
        var i = start
        let n = chars.count
        while i < n {
            if chars[i] == "\\" { i += 2; continue }
            if startsWith(chars, at: i, "\"\"\"") {
                return i + 3
            }
            i += 1
        }
        return n
    }

    private static func scanPrefixedString(chars: [Character], at i: Int, lang: Language) -> Int? {
        let n = chars.count
        var p = i
        // up to 2 prefix letters
        var prefLen = 0
        while p < n && chars[p].isLetter && prefLen < 2 {
            p += 1
            prefLen += 1
        }
        guard p < n, prefLen > 0 else { return nil }
        let q = chars[p]
        guard lang.stringDelimiters.contains(q) else { return nil }
        return scanString(chars: chars, from: p + 1, quote: q)
    }

    private static func scanNumber(chars: [Character], from start: Int) -> Int {
        var i = start
        let n = chars.count
        // 0x, 0b, 0o prefixes
        if chars[i] == "0", i + 1 < n {
            let next = chars[i + 1]
            if next == "x" || next == "X" {
                i += 2
                while i < n, isHexDigit(chars[i]) || chars[i] == "_" { i += 1 }
                return i
            }
            if next == "b" || next == "B" || next == "o" || next == "O" {
                i += 2
                while i < n, chars[i].isNumber || chars[i] == "_" { i += 1 }
                return i
            }
        }
        while i < n, chars[i].isNumber || chars[i] == "_" { i += 1 }
        if i < n, chars[i] == "." {
            i += 1
            while i < n, chars[i].isNumber || chars[i] == "_" { i += 1 }
        }
        if i < n, chars[i] == "e" || chars[i] == "E" {
            i += 1
            if i < n, chars[i] == "+" || chars[i] == "-" { i += 1 }
            while i < n, chars[i].isNumber { i += 1 }
        }
        // Type suffixes: L, U, f, ll, u8, i32 etc — consume a short trailing letter run
        var suffix = 0
        while i < n, (chars[i].isLetter || chars[i].isNumber) && suffix < 3 {
            i += 1
            suffix += 1
        }
        return i
    }

    private static func isHexDigit(_ c: Character) -> Bool {
        c.isNumber || ("a"..."f").contains(c) || ("A"..."F").contains(c)
    }

    private static func isOnlyWhitespaceBefore(_ chars: [Character], at i: Int) -> Bool {
        var k = i - 1
        while k >= 0 {
            if chars[k] == "\n" { return true }
            if chars[k] != " " && chars[k] != "\t" { return false }
            k -= 1
        }
        return true
    }

    /// Heuristic: identifiers beginning with an uppercase letter and containing a lowercase
    /// letter look like type names (UpperCamelCase). Catches user-defined types in C-family
    /// languages without listing them all.
    private static func isLikelyType(_ word: String) -> Bool {
        guard let first = word.first, first.isUppercase else { return false }
        guard word.count > 1 else { return false }
        // SCREAMING_SNAKE_CASE → constant, not type
        if word.allSatisfy({ $0.isUppercase || $0.isNumber || $0 == "_" }) { return false }
        return word.contains(where: { $0.isLowercase })
    }

    // MARK: - Language definitions

    private static let cIdent: (Character) -> Bool = { $0.isLetter || $0 == "_" }
    private static let cIdentCont: (Character) -> Bool = { $0.isLetter || $0.isNumber || $0 == "_" }

    private static let swift = Language(
        keywords: [
            "associatedtype","class","deinit","enum","extension","fileprivate","func","import",
            "init","inout","internal","let","open","operator","private","protocol","public",
            "rethrows","static","struct","subscript","typealias","var",
            "break","case","continue","default","defer","do","else","fallthrough","for","guard",
            "if","in","repeat","return","switch","where","while",
            "as","catch","false","is","nil","super","self","Self","throw","throws","true","try",
            "async","await","actor","any","some","mutating","nonmutating","convenience","required",
            "override","final","lazy","weak","unowned","optional","indirect","dynamic","unsafe"
        ],
        types: [
            "Int","Int8","Int16","Int32","Int64","UInt","UInt8","UInt16","UInt32","UInt64",
            "Float","Double","Bool","String","Character","Array","Dictionary","Set","Optional",
            "Result","Any","AnyObject","Void","Never","Error","URL","Data","Date","UUID",
            "Range","ClosedRange","Substring","StaticString",
            "View","Text","Image","Button","HStack","VStack","ZStack","List","NavigationView",
            "NavigationStack","ScrollView","Color","Font"
        ],
        constants: ["true","false","nil"],
        lineComments: ["//"],
        blockComments: [("/*", "*/")],
        stringDelimiters: ["\""],
        templateStringDelimiters: [],
        allowsTripleQuoteStrings: true,
        identifierStart: cIdent,
        identifierContinue: cIdentCont,
        preprocDirective: nil,
        supportsAtAttributes: true,
        regexDelimiter: nil,
        supportsRawStringPrefix: false
    )

    private static let python = Language(
        keywords: [
            "False","None","True","and","as","assert","async","await","break","class","continue",
            "def","del","elif","else","except","finally","for","from","global","if","import","in",
            "is","lambda","nonlocal","not","or","pass","raise","return","try","while","with","yield",
            "match","case"
        ],
        types: [
            "int","float","str","bool","bytes","list","dict","set","tuple","frozenset","object",
            "complex","range","type","Any","Optional","List","Dict","Tuple","Set","Union","Callable",
            "Iterator","Iterable","Sequence","Mapping","Generator"
        ],
        constants: ["True","False","None","self","cls","NotImplemented","Ellipsis"],
        lineComments: ["#"],
        blockComments: [],
        stringDelimiters: ["\"", "'"],
        templateStringDelimiters: [],
        allowsTripleQuoteStrings: true,
        identifierStart: cIdent,
        identifierContinue: cIdentCont,
        preprocDirective: nil,
        supportsAtAttributes: true,
        regexDelimiter: nil,
        supportsRawStringPrefix: true
    )

    private static let javascript = Language(
        keywords: [
            "abstract","await","async","break","case","catch","class","const","continue","debugger",
            "default","delete","do","else","enum","export","extends","finally","for","from","function",
            "get","if","implements","import","in","instanceof","interface","let","new","of","package",
            "private","protected","public","return","set","static","super","switch","this","throw",
            "try","typeof","var","void","while","with","yield","as","readonly","keyof","type","declare",
            "namespace","module"
        ],
        types: [
            "boolean","number","string","object","symbol","bigint","undefined","null","any","unknown",
            "never","void","Array","Promise","Map","Set","WeakMap","WeakSet","Date","RegExp","Error",
            "JSON","Math","Object","Function","Number","String","Boolean","Symbol","BigInt"
        ],
        constants: ["true","false","null","undefined","NaN","Infinity","this","arguments"],
        lineComments: ["//"],
        blockComments: [("/*", "*/")],
        stringDelimiters: ["\"", "'"],
        templateStringDelimiters: ["`"],
        allowsTripleQuoteStrings: false,
        identifierStart: { $0.isLetter || $0 == "_" || $0 == "$" },
        identifierContinue: { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "$" },
        preprocDirective: nil,
        supportsAtAttributes: true,
        regexDelimiter: "/",
        supportsRawStringPrefix: false
    )

    private static let c = Language(
        keywords: [
            "auto","break","case","char","const","continue","default","do","double","else","enum",
            "extern","float","for","goto","if","inline","int","long","register","restrict","return",
            "short","signed","sizeof","static","struct","switch","typedef","union","unsigned",
            "void","volatile","while","_Bool","_Complex","_Imaginary"
        ],
        types: [
            "size_t","ssize_t","ptrdiff_t","intptr_t","uintptr_t","int8_t","int16_t","int32_t",
            "int64_t","uint8_t","uint16_t","uint32_t","uint64_t","FILE","NULL","bool","wchar_t"
        ],
        constants: ["NULL","true","false","TRUE","FALSE"],
        lineComments: ["//"],
        blockComments: [("/*", "*/")],
        stringDelimiters: ["\"", "'"],
        templateStringDelimiters: [],
        allowsTripleQuoteStrings: false,
        identifierStart: cIdent,
        identifierContinue: cIdentCont,
        preprocDirective: "#",
        supportsAtAttributes: false,
        regexDelimiter: nil,
        supportsRawStringPrefix: false
    )

    private static let cpp = Language(
        keywords: c.keywords.union([
            "alignas","alignof","and","and_eq","asm","bitand","bitor","bool","catch","class","compl",
            "concept","const_cast","constexpr","consteval","constinit","co_await","co_return","co_yield",
            "decltype","delete","dynamic_cast","explicit","export","false","friend","mutable","namespace",
            "new","noexcept","not","not_eq","nullptr","operator","or","or_eq","private","protected",
            "public","reinterpret_cast","requires","static_assert","static_cast","template","this","thread_local",
            "throw","true","try","typeid","typename","using","virtual","wchar_t","xor","xor_eq"
        ]),
        types: c.types.union(["string","wstring","vector","map","unordered_map","set","unordered_set",
                              "array","pair","tuple","unique_ptr","shared_ptr","weak_ptr","optional",
                              "variant","function","span","string_view"]),
        constants: c.constants.union(["nullptr"]),
        lineComments: c.lineComments,
        blockComments: c.blockComments,
        stringDelimiters: c.stringDelimiters,
        templateStringDelimiters: [],
        allowsTripleQuoteStrings: false,
        identifierStart: cIdent,
        identifierContinue: cIdentCont,
        preprocDirective: "#",
        supportsAtAttributes: false,
        regexDelimiter: nil,
        supportsRawStringPrefix: false
    )

    private static let objc = Language(
        keywords: c.keywords.union([
            "@interface","@implementation","@end","@protocol","@property","@synthesize","@dynamic",
            "@class","@selector","@encode","@synchronized","@autoreleasepool","@try","@catch",
            "@finally","@throw","@public","@private","@protected","@package","self","super","nil",
            "YES","NO","id","SEL","BOOL","IMP","Class","Method","Ivar","Protocol","instancetype",
            "in","out","inout","bycopy","byref","oneway","__weak","__strong","__unsafe_unretained",
            "__block","__bridge","atomic","nonatomic","strong","weak","copy","assign","retain",
            "readonly","readwrite","getter","setter","nullable","nonnull"
        ]),
        types: c.types.union(["NSString","NSArray","NSDictionary","NSNumber","NSObject","NSError",
                              "NSData","NSDate","NSURL","NSMutableArray","NSMutableDictionary",
                              "NSMutableString","NSSet","NSMutableSet","NSIndexSet","NSValue",
                              "UIView","UIViewController","UIButton","UILabel","UIImage","UIColor",
                              "CGRect","CGPoint","CGSize","CGFloat"]),
        constants: ["YES","NO","nil","Nil","NULL","TRUE","FALSE"],
        lineComments: c.lineComments,
        blockComments: c.blockComments,
        stringDelimiters: c.stringDelimiters,
        templateStringDelimiters: [],
        allowsTripleQuoteStrings: false,
        identifierStart: cIdent,
        identifierContinue: cIdentCont,
        preprocDirective: "#",
        supportsAtAttributes: true,
        regexDelimiter: nil,
        supportsRawStringPrefix: false
    )

    private static let java = Language(
        keywords: [
            "abstract","assert","boolean","break","byte","case","catch","char","class","const",
            "continue","default","do","double","else","enum","extends","final","finally","float",
            "for","goto","if","implements","import","instanceof","int","interface","long","native",
            "new","package","private","protected","public","return","short","static","strictfp",
            "super","switch","synchronized","this","throw","throws","transient","try","void",
            "volatile","while","var","record","sealed","permits","yield","non-sealed"
        ],
        types: [
            "String","Integer","Long","Short","Byte","Double","Float","Boolean","Character",
            "Object","Number","List","ArrayList","Map","HashMap","Set","HashSet","Collection",
            "Iterator","Iterable","Optional","Stream","Function","Predicate","Consumer","Supplier"
        ],
        constants: ["true","false","null"],
        lineComments: ["//"],
        blockComments: [("/*", "*/")],
        stringDelimiters: ["\"", "'"],
        templateStringDelimiters: [],
        allowsTripleQuoteStrings: true,
        identifierStart: cIdent,
        identifierContinue: cIdentCont,
        preprocDirective: nil,
        supportsAtAttributes: true,
        regexDelimiter: nil,
        supportsRawStringPrefix: false
    )

    private static let kotlin = Language(
        keywords: [
            "as","break","class","continue","do","else","false","for","fun","if","in","interface",
            "is","null","object","package","return","super","this","throw","true","try","typealias",
            "typeof","val","var","when","while","by","catch","constructor","delegate","dynamic",
            "field","file","finally","get","import","init","param","property","receiver","set",
            "setparam","value","where","actual","abstract","annotation","companion","const","crossinline",
            "data","enum","expect","external","final","infix","inline","inner","internal","lateinit",
            "noinline","open","operator","out","override","private","protected","public","reified",
            "sealed","suspend","tailrec","vararg"
        ],
        types: [
            "Int","Long","Short","Byte","Double","Float","Boolean","Char","String","Any","Unit",
            "Nothing","List","MutableList","Map","MutableMap","Set","MutableSet","Array","Pair","Triple",
            "Sequence","Iterable","Iterator","Collection","ArrayList","HashMap","HashSet"
        ],
        constants: ["true","false","null"],
        lineComments: ["//"],
        blockComments: [("/*", "*/")],
        stringDelimiters: ["\"", "'"],
        templateStringDelimiters: [],
        allowsTripleQuoteStrings: true,
        identifierStart: cIdent,
        identifierContinue: cIdentCont,
        preprocDirective: nil,
        supportsAtAttributes: true,
        regexDelimiter: nil,
        supportsRawStringPrefix: false
    )

    private static let go = Language(
        keywords: [
            "break","case","chan","const","continue","default","defer","else","fallthrough","for",
            "func","go","goto","if","import","interface","map","package","range","return","select",
            "struct","switch","type","var"
        ],
        types: [
            "bool","byte","complex64","complex128","error","float32","float64","int","int8","int16",
            "int32","int64","rune","string","uint","uint8","uint16","uint32","uint64","uintptr",
            "any","comparable"
        ],
        constants: ["true","false","iota","nil"],
        lineComments: ["//"],
        blockComments: [("/*", "*/")],
        stringDelimiters: ["\"", "'", "`"],
        templateStringDelimiters: [],
        allowsTripleQuoteStrings: false,
        identifierStart: cIdent,
        identifierContinue: cIdentCont,
        preprocDirective: nil,
        supportsAtAttributes: false,
        regexDelimiter: nil,
        supportsRawStringPrefix: false
    )

    private static let rust = Language(
        keywords: [
            "as","async","await","break","const","continue","crate","dyn","else","enum","extern","false",
            "fn","for","if","impl","in","let","loop","match","mod","move","mut","pub","ref","return",
            "self","Self","static","struct","super","trait","true","type","unsafe","use","where","while",
            "abstract","become","box","do","final","macro","override","priv","try","typeof","unsized",
            "virtual","yield","union"
        ],
        types: [
            "bool","char","str","String","i8","i16","i32","i64","i128","isize","u8","u16","u32","u64",
            "u128","usize","f32","f64","Vec","Box","Option","Result","Rc","Arc","Cell","RefCell","Mutex",
            "HashMap","HashSet","BTreeMap","BTreeSet","Cow","Path","PathBuf","Iterator","Future"
        ],
        constants: ["true","false","None","Some","Ok","Err"],
        lineComments: ["//"],
        blockComments: [("/*", "*/")],
        stringDelimiters: ["\"", "'"],
        templateStringDelimiters: [],
        allowsTripleQuoteStrings: false,
        identifierStart: cIdent,
        identifierContinue: cIdentCont,
        preprocDirective: nil,
        supportsAtAttributes: true,
        regexDelimiter: nil,
        supportsRawStringPrefix: true
    )

    private static let ruby = Language(
        keywords: [
            "BEGIN","END","alias","and","begin","break","case","class","def","defined?","do","else",
            "elsif","end","ensure","false","for","if","in","module","next","nil","not","or","redo",
            "rescue","retry","return","self","super","then","true","undef","unless","until","when",
            "while","yield","require","require_relative","include","extend","attr_accessor","attr_reader",
            "attr_writer","private","protected","public","lambda","proc"
        ],
        types: [
            "Integer","Float","String","Symbol","Array","Hash","Range","Regexp","Proc","Lambda","Class",
            "Module","Object","BasicObject","TrueClass","FalseClass","NilClass","Numeric","Comparable",
            "Enumerable","IO","File"
        ],
        constants: ["true","false","nil","self"],
        lineComments: ["#"],
        blockComments: [("=begin", "=end")],
        stringDelimiters: ["\"", "'"],
        templateStringDelimiters: [],
        allowsTripleQuoteStrings: false,
        identifierStart: { $0.isLetter || $0 == "_" || $0 == "@" || $0 == "$" },
        identifierContinue: { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "?" || $0 == "!" },
        preprocDirective: nil,
        supportsAtAttributes: false,
        regexDelimiter: "/",
        supportsRawStringPrefix: false
    )

    private static let php = Language(
        keywords: [
            "abstract","and","array","as","break","callable","case","catch","class","clone","const",
            "continue","declare","default","die","do","echo","else","elseif","empty","enddeclare",
            "endfor","endforeach","endif","endswitch","endwhile","enum","eval","exit","extends","final",
            "finally","fn","for","foreach","function","global","goto","if","implements","include",
            "include_once","instanceof","insteadof","interface","isset","list","match","namespace",
            "new","or","print","private","protected","public","readonly","require","require_once",
            "return","self","static","switch","throw","trait","try","unset","use","var","while","xor",
            "yield","parent","this"
        ],
        types: [
            "int","integer","float","double","string","bool","boolean","array","object","mixed","void",
            "null","resource","callable","iterable","never","self","static","parent","true","false"
        ],
        constants: ["true","false","null","TRUE","FALSE","NULL"],
        lineComments: ["//", "#"],
        blockComments: [("/*", "*/")],
        stringDelimiters: ["\"", "'"],
        templateStringDelimiters: [],
        allowsTripleQuoteStrings: false,
        identifierStart: { $0.isLetter || $0 == "_" || $0 == "$" },
        identifierContinue: { $0.isLetter || $0.isNumber || $0 == "_" },
        preprocDirective: nil,
        supportsAtAttributes: true,
        regexDelimiter: nil,
        supportsRawStringPrefix: false
    )

    private static let sql = Language(
        keywords: [
            "SELECT","FROM","WHERE","INSERT","INTO","VALUES","UPDATE","SET","DELETE","CREATE","TABLE",
            "ALTER","DROP","INDEX","VIEW","TRIGGER","PROCEDURE","FUNCTION","AS","ON","JOIN","INNER",
            "LEFT","RIGHT","FULL","OUTER","CROSS","UNION","ALL","GROUP","BY","HAVING","ORDER","ASC",
            "DESC","LIMIT","OFFSET","DISTINCT","AND","OR","NOT","IN","BETWEEN","LIKE","ILIKE","IS",
            "NULL","TRUE","FALSE","CASE","WHEN","THEN","ELSE","END","IF","EXISTS","COUNT","SUM","AVG",
            "MIN","MAX","CAST","CONVERT","COALESCE","NULLIF","RETURNING","WITH","RECURSIVE","PRIMARY",
            "KEY","FOREIGN","REFERENCES","UNIQUE","CHECK","DEFAULT","CONSTRAINT","BEGIN","COMMIT",
            "ROLLBACK","TRANSACTION","SAVEPOINT","GRANT","REVOKE","USE","DATABASE","SCHEMA",
            "select","from","where","insert","into","values","update","set","delete","create","table",
            "alter","drop","index","view","as","on","join","inner","left","right","outer","union",
            "group","by","having","order","limit","offset","distinct","and","or","not","in","between",
            "like","is","null","case","when","then","else","end","exists","with"
        ],
        types: [
            "INT","INTEGER","BIGINT","SMALLINT","TINYINT","DECIMAL","NUMERIC","FLOAT","DOUBLE","REAL",
            "VARCHAR","CHAR","TEXT","NVARCHAR","NCHAR","NTEXT","DATE","TIME","DATETIME","TIMESTAMP",
            "BOOLEAN","BOOL","BLOB","BYTEA","JSON","JSONB","UUID","SERIAL","BIGSERIAL",
            "int","integer","bigint","decimal","numeric","float","double","real","varchar","char","text",
            "date","time","datetime","timestamp","boolean","bool","blob","json","uuid","serial"
        ],
        constants: ["TRUE","FALSE","NULL","true","false","null"],
        lineComments: ["--"],
        blockComments: [("/*", "*/")],
        stringDelimiters: ["'", "\""],
        templateStringDelimiters: [],
        allowsTripleQuoteStrings: false,
        identifierStart: cIdent,
        identifierContinue: cIdentCont,
        preprocDirective: nil,
        supportsAtAttributes: false,
        regexDelimiter: nil,
        supportsRawStringPrefix: false
    )

    private static let shell = Language(
        keywords: [
            "if","then","else","elif","fi","case","esac","for","while","until","do","done","function",
            "return","in","select","time","break","continue","exit","export","local","readonly","unset",
            "declare","typeset","alias","unalias","source","eval","exec","trap","set","shift","getopts",
            "echo","printf","read","cd","pwd","pushd","popd","test"
        ],
        types: [],
        constants: ["true","false"],
        lineComments: ["#"],
        blockComments: [],
        stringDelimiters: ["\"", "'"],
        templateStringDelimiters: ["`"],
        allowsTripleQuoteStrings: false,
        identifierStart: { $0.isLetter || $0 == "_" || $0 == "$" },
        identifierContinue: { $0.isLetter || $0.isNumber || $0 == "_" },
        preprocDirective: nil,
        supportsAtAttributes: false,
        regexDelimiter: nil,
        supportsRawStringPrefix: false
    )

    private static let haskell = Language(
        keywords: [
            "case","class","data","default","deriving","do","else","foreign","if","import","in","infix",
            "infixl","infixr","instance","let","module","newtype","of","then","type","where","_","as",
            "hiding","qualified"
        ],
        types: [
            "Int","Integer","Float","Double","Char","String","Bool","Maybe","Either","IO","Ord","Eq",
            "Show","Read","Num","Functor","Applicative","Monad","Foldable","Traversable","Word","Word8",
            "Word16","Word32","Word64"
        ],
        constants: ["True","False","Nothing","Just","Left","Right","LT","EQ","GT","otherwise"],
        lineComments: ["--"],
        blockComments: [("{-", "-}")],
        stringDelimiters: ["\""],
        templateStringDelimiters: [],
        allowsTripleQuoteStrings: false,
        identifierStart: { $0.isLetter || $0 == "_" },
        identifierContinue: { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "'" },
        preprocDirective: nil,
        supportsAtAttributes: false,
        regexDelimiter: nil,
        supportsRawStringPrefix: false
    )

    private static let json = Language(
        keywords: [],
        types: [],
        constants: ["true","false","null"],
        lineComments: [],
        blockComments: [],
        stringDelimiters: ["\""],
        templateStringDelimiters: [],
        allowsTripleQuoteStrings: false,
        identifierStart: cIdent,
        identifierContinue: cIdentCont,
        preprocDirective: nil,
        supportsAtAttributes: false,
        regexDelimiter: nil,
        supportsRawStringPrefix: false
    )

    private static let yaml = Language(
        keywords: [],
        types: [],
        constants: ["true","false","null","True","False","Null","TRUE","FALSE","NULL","yes","no","Yes","No","YES","NO","~"],
        lineComments: ["#"],
        blockComments: [],
        stringDelimiters: ["\"", "'"],
        templateStringDelimiters: [],
        allowsTripleQuoteStrings: false,
        identifierStart: cIdent,
        identifierContinue: cIdentCont,
        preprocDirective: nil,
        supportsAtAttributes: false,
        regexDelimiter: nil,
        supportsRawStringPrefix: false
    )

    private static let css = Language(
        keywords: [
            "important","inherit","initial","unset","revert","auto","none","normal","bold","italic",
            "underline","center","left","right","top","bottom","middle","baseline","block","inline",
            "flex","grid","absolute","relative","fixed","sticky","static","hidden","visible","scroll",
            "pointer","default","solid","dashed","dotted","double"
        ],
        types: [],
        constants: [],
        lineComments: [],
        blockComments: [("/*", "*/")],
        stringDelimiters: ["\"", "'"],
        templateStringDelimiters: [],
        allowsTripleQuoteStrings: false,
        identifierStart: { $0.isLetter || $0 == "_" || $0 == "-" || $0 == "." || $0 == "#" || $0 == "@" },
        identifierContinue: { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" },
        preprocDirective: nil,
        supportsAtAttributes: true,
        regexDelimiter: nil,
        supportsRawStringPrefix: false
    )

    private static let html = Language(
        keywords: [],
        types: [
            "html","head","body","div","span","p","a","img","ul","ol","li","table","thead","tbody",
            "tr","td","th","form","input","button","select","option","textarea","label","header",
            "footer","nav","main","section","article","aside","h1","h2","h3","h4","h5","h6","script",
            "style","link","meta","title","br","hr","strong","em","b","i","u","code","pre","blockquote"
        ],
        constants: [],
        lineComments: [],
        blockComments: [("<!--", "-->")],
        stringDelimiters: ["\"", "'"],
        templateStringDelimiters: [],
        allowsTripleQuoteStrings: false,
        identifierStart: { $0.isLetter || $0 == "_" || $0 == "<" || $0 == "/" },
        identifierContinue: { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ">" || $0 == "/" },
        preprocDirective: nil,
        supportsAtAttributes: false,
        regexDelimiter: nil,
        supportsRawStringPrefix: false
    )

    private static let csharp = Language(
        keywords: [
            "abstract","as","async","await","base","bool","break","byte","case","catch","char",
            "checked","class","const","continue","decimal","default","delegate","do","double","else",
            "enum","event","explicit","extern","false","finally","fixed","float","for","foreach","goto",
            "if","implicit","in","int","interface","internal","is","lock","long","namespace","new","null",
            "object","operator","out","override","params","private","protected","public","readonly","ref",
            "return","sbyte","sealed","short","sizeof","stackalloc","static","string","struct","switch",
            "this","throw","true","try","typeof","uint","ulong","unchecked","unsafe","ushort","using",
            "virtual","void","volatile","while","var","dynamic","record","init","with","required","nint","nuint"
        ],
        types: [
            "String","Int32","Int64","Boolean","Double","Single","Decimal","Object","List","Dictionary",
            "HashSet","IEnumerable","IList","IDictionary","Task","Action","Func","Predicate","Span",
            "ReadOnlySpan","Memory","ReadOnlyMemory","Nullable","Tuple","ValueTuple"
        ],
        constants: ["true","false","null","this","base","value"],
        lineComments: ["//"],
        blockComments: [("/*", "*/")],
        stringDelimiters: ["\"", "'"],
        templateStringDelimiters: [],
        allowsTripleQuoteStrings: true,
        identifierStart: cIdent,
        identifierContinue: cIdentCont,
        preprocDirective: "#",
        supportsAtAttributes: true,
        regexDelimiter: nil,
        supportsRawStringPrefix: true
    )

    private static let lua = Language(
        keywords: [
            "and","break","do","else","elseif","end","false","for","function","goto","if","in",
            "local","nil","not","or","repeat","return","then","true","until","while"
        ],
        types: [],
        constants: ["true","false","nil","_G","_ENV","self"],
        lineComments: ["--"],
        blockComments: [("--[[", "]]")],
        stringDelimiters: ["\"", "'"],
        templateStringDelimiters: [],
        allowsTripleQuoteStrings: false,
        identifierStart: cIdent,
        identifierContinue: cIdentCont,
        preprocDirective: nil,
        supportsAtAttributes: false,
        regexDelimiter: nil,
        supportsRawStringPrefix: false
    )

    private static let dart = Language(
        keywords: [
            "abstract","as","assert","async","await","break","case","catch","class","const","continue",
            "covariant","default","deferred","do","dynamic","else","enum","export","extends","extension",
            "external","factory","false","final","finally","for","Function","get","hide","if","implements",
            "import","in","interface","is","late","library","mixin","new","null","on","operator","part",
            "rethrow","return","sealed","set","show","static","super","switch","sync","this","throw",
            "true","try","typedef","var","void","when","while","with","yield"
        ],
        types: [
            "int","double","num","String","bool","List","Map","Set","Iterable","Future","Stream","Object",
            "Symbol","Type","Null","Never","Record","dynamic","void","Function"
        ],
        constants: ["true","false","null","this"],
        lineComments: ["//"],
        blockComments: [("/*", "*/")],
        stringDelimiters: ["\"", "'"],
        templateStringDelimiters: [],
        allowsTripleQuoteStrings: true,
        identifierStart: cIdent,
        identifierContinue: cIdentCont,
        preprocDirective: nil,
        supportsAtAttributes: true,
        regexDelimiter: nil,
        supportsRawStringPrefix: true
    )

    private static let scala = Language(
        keywords: [
            "abstract","case","catch","class","def","do","else","extends","false","final","finally",
            "for","forSome","given","if","implicit","import","lazy","match","new","null","object",
            "override","package","private","protected","return","sealed","super","this","throw","trait",
            "try","true","type","val","var","while","with","yield","using","then","enum","export"
        ],
        types: [
            "Int","Long","Short","Byte","Double","Float","Boolean","Char","String","Unit","Any","AnyRef",
            "AnyVal","Nothing","Null","Option","Some","None","Either","Left","Right","List","Seq","Map",
            "Set","Vector","Array","Tuple","Future","Try","Success","Failure"
        ],
        constants: ["true","false","null"],
        lineComments: ["//"],
        blockComments: [("/*", "*/")],
        stringDelimiters: ["\"", "'"],
        templateStringDelimiters: [],
        allowsTripleQuoteStrings: true,
        identifierStart: cIdent,
        identifierContinue: cIdentCont,
        preprocDirective: nil,
        supportsAtAttributes: true,
        regexDelimiter: nil,
        supportsRawStringPrefix: false
    )

    private static let elixir = Language(
        keywords: [
            "def","defp","defmodule","defstruct","defprotocol","defimpl","defmacro","defmacrop",
            "defguard","defguardp","defexception","do","end","fn","if","unless","else","case","cond",
            "when","with","for","try","rescue","catch","after","raise","throw","import","alias","require",
            "use","quote","unquote","__MODULE__","__DIR__","__ENV__","__CALLER__","and","or","not","in"
        ],
        types: [],
        constants: ["true","false","nil",":ok",":error",":noreply",":reply",":stop"],
        lineComments: ["#"],
        blockComments: [],
        stringDelimiters: ["\"", "'"],
        templateStringDelimiters: [],
        allowsTripleQuoteStrings: true,
        identifierStart: { $0.isLetter || $0 == "_" || $0 == "@" || $0 == ":" },
        identifierContinue: { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "?" || $0 == "!" },
        preprocDirective: nil,
        supportsAtAttributes: true,
        regexDelimiter: nil,
        supportsRawStringPrefix: false
    )

    private static let perl = Language(
        keywords: [
            "use","require","my","our","local","sub","return","if","elsif","else","unless","while",
            "until","for","foreach","do","next","last","redo","package","BEGIN","END","eval","die","warn",
            "print","printf","say","chomp","chop","split","join","keys","values","push","pop","shift",
            "unshift","grep","map","sort","reverse","wantarray","defined","undef","ref","scalar","exists",
            "delete","each","qw","qr","q","qq"
        ],
        types: [],
        constants: ["__FILE__","__LINE__","__PACKAGE__","__DATA__","__END__","STDIN","STDOUT","STDERR"],
        lineComments: ["#"],
        blockComments: [],
        stringDelimiters: ["\"", "'"],
        templateStringDelimiters: ["`"],
        allowsTripleQuoteStrings: false,
        identifierStart: { $0.isLetter || $0 == "_" || $0 == "$" || $0 == "@" || $0 == "%" },
        identifierContinue: { $0.isLetter || $0.isNumber || $0 == "_" },
        preprocDirective: nil,
        supportsAtAttributes: false,
        regexDelimiter: "/",
        supportsRawStringPrefix: false
    )

    private static let r = Language(
        keywords: [
            "if","else","for","while","repeat","function","return","break","next","in","NULL","NA",
            "NA_integer_","NA_real_","NA_character_","NA_complex_","TRUE","FALSE","Inf","NaN","T","F"
        ],
        types: [
            "numeric","integer","double","character","logical","complex","raw","list","vector",
            "matrix","array","data.frame","factor"
        ],
        constants: ["TRUE","FALSE","NULL","NA","Inf","NaN","T","F"],
        lineComments: ["#"],
        blockComments: [],
        stringDelimiters: ["\"", "'"],
        templateStringDelimiters: [],
        allowsTripleQuoteStrings: false,
        identifierStart: { $0.isLetter || $0 == "_" || $0 == "." },
        identifierContinue: { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." },
        preprocDirective: nil,
        supportsAtAttributes: false,
        regexDelimiter: nil,
        supportsRawStringPrefix: false
    )

    // MARK: - Language lookup table

    /// Maps `language-X` class values (Matrix HTML uses these via highlight.js conventions)
    /// to internal language definitions. Includes common aliases (`js` → JavaScript, `sh` → shell, etc).
    private static let languageMap: [String: Language] = [
        "swift": swift,
        "python": python, "py": python,
        "javascript": javascript, "js": javascript, "jsx": javascript,
        "typescript": javascript, "ts": javascript, "tsx": javascript,
        "c": c, "h": c,
        "cpp": cpp, "c++": cpp, "cxx": cpp, "cc": cpp, "hpp": cpp,
        "objectivec": objc, "objective-c": objc, "objc": objc, "m": objc, "mm": objc,
        "java": java,
        "kotlin": kotlin, "kt": kotlin, "kts": kotlin,
        "go": go, "golang": go,
        "rust": rust, "rs": rust,
        "ruby": ruby, "rb": ruby,
        "php": php,
        "sql": sql, "postgresql": sql, "postgres": sql, "mysql": sql, "sqlite": sql, "plsql": sql,
        "bash": shell, "sh": shell, "shell": shell, "zsh": shell, "fish": shell,
        "haskell": haskell, "hs": haskell,
        "json": json,
        "yaml": yaml, "yml": yaml,
        "css": css, "scss": css, "sass": css, "less": css,
        "html": html, "xml": html, "svg": html, "xhtml": html, "vue": html,
        "csharp": csharp, "cs": csharp, "c#": csharp,
        "lua": lua,
        "dart": dart,
        "scala": scala, "sc": scala,
        "elixir": elixir, "ex": elixir, "exs": elixir,
        "perl": perl, "pl": perl,
        "r": r, "rscript": r
    ]
}
