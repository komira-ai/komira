# =============================================================================
# kci_bundle/tokenizer.mojo — the textproto tokenizer.
# =============================================================================
#
# The bounded lexer for the AppBundle textproto authoring surface
# The grammar is small and CLOSED — message
# blocks `{}`, `field: value` scalars, repeated `field { }` blocks, enums by name,
# oneof arms, and `#` comments — so a hand-written byte lexer is the right shape.
#
# POSITION-CARRYING BY DESIGN. Every `Token` carries its 1-based `line`/`col` AND
# its raw byte span (`start`/`end`) in the source. The line/col feed the precise,
# self-correctable parse errors that are the LLM self-correction surface
# ("line 12: unknown field 'imge' …"); the byte span feeds the comment-preserving
# PATCHER (`patch.mojo`), which splices new bytes over a token's raw span while
# leaving every other byte — including `#` comments — untouched. The tokenizer is
# therefore shared between the parser and the patcher.
#
# ENCAPSULATION: pure value structs + a `List[Token]` return. No UnsafePointer, no
# wildcard origin; not a byte-slab element. ASCII byte predicates throughout.
# ⚠ STRING LITERALS accumulate RAW BYTES, not `chr(Int(b))` codepoints — see the
# note at the string-literal scan for the round-trip corruption that caused.
# Mojo 1.0.0b2.
# =============================================================================



# ─── Token kinds ─────────────────────────────────────────────────────────────
comptime TOK_IDENT: Int = 0  # a bare identifier: a field name OR an enum value
comptime TOK_STRING: Int = 1  # a quoted string literal (text = unescaped body)
comptime TOK_NUMBER: Int = 2  # a numeric literal (text = the raw digits, incl. '-')
comptime TOK_LBRACE: Int = 3  # '{'
comptime TOK_RBRACE: Int = 4  # '}'
comptime TOK_COLON: Int = 5  # ':'
comptime TOK_EOF: Int = 6  # end-of-input sentinel


def _tok_kind_name(kind: Int) -> StaticString:
    """A human label for a token kind (for parse-error prose)."""
    if kind == TOK_IDENT:
        return "identifier"
    if kind == TOK_STRING:
        return "string"
    if kind == TOK_NUMBER:
        return "number"
    if kind == TOK_LBRACE:
        return "'{'"
    if kind == TOK_RBRACE:
        return "'}'"
    if kind == TOK_COLON:
        return "':'"
    return "end-of-input"


struct Token(Copyable, Movable, Deinitable):
    """One lexical token. `text` carries the semantic value (an identifier/enum
    name, an UNESCAPED string body, or the raw number digits). `start`/`end` are
    the RAW byte span in the source — for a string that span INCLUDES the quotes,
    so the patcher can replace the whole literal. `line`/`col` are 1-based, at
    the token's first byte."""

    var kind: Int
    var text: String
    var line: Int
    var col: Int
    var start: Int  # byte offset of the first byte (inclusive)
    var end: Int  # byte offset one past the last byte (exclusive)

    def __init__(
        out self,
        kind: Int,
        var text: String,
        line: Int,
        col: Int,
        start: Int,
        end: Int,
    ):
        self.kind = kind
        self.text = text^
        self.line = line
        self.col = col
        self.start = start
        self.end = end

    def copy(self) -> Self:
        return Token(
            self.kind, String(self.text), self.line, self.col, self.start, self.end
        )


# ─── ASCII byte predicates ───────────────────────────────────────────────────
def _is_space(c: UInt8) -> Bool:
    return c == UInt8(ord(" ")) or c == UInt8(ord("\t")) or c == UInt8(ord("\r")) or c == UInt8(ord("\n"))


def _is_digit(c: UInt8) -> Bool:
    return c >= UInt8(ord("0")) and c <= UInt8(ord("9"))


def _is_alpha(c: UInt8) -> Bool:
    return (c >= UInt8(ord("a")) and c <= UInt8(ord("z"))) or (c >= UInt8(ord("A")) and c <= UInt8(ord("Z")))


def _is_ident_start(c: UInt8) -> Bool:
    return _is_alpha(c) or c == UInt8(ord("_"))


def _is_ident_char(c: UInt8) -> Bool:
    return _is_alpha(c) or _is_digit(c) or c == UInt8(ord("_"))


# ─── The tokenizer ───────────────────────────────────────────────────────────
def tokenize(src: String) raises -> List[Token]:
    """Tokenize a textproto `src` into a `List[Token]` ending with a `TOK_EOF`
    sentinel. `#` comments run to end-of-line and are dropped (their bytes stay
    in `src`, so the patcher still preserves them). Raises a position-carrying
    `Error` on an unterminated string or an unexpected byte."""
    var b = src.as_bytes()
    var n = len(b)
    var i = 0
    var line = 1
    var col = 1
    var out = List[Token]()

    while i < n:
        var c = b[i]

        # Whitespace — advance, tracking line/col.
        if _is_space(c):
            if c == UInt8(ord("\n")):
                line += 1
                col = 1
            else:
                col += 1
            i += 1
            continue

        # '#' comment — skip to end-of-line (the bytes remain in src).
        if c == UInt8(ord("#")):
            while i < n and b[i] != UInt8(ord("\n")):
                i += 1
                col += 1
            continue

        # Punctuation.
        if c == UInt8(ord("{")):
            out.append(Token(TOK_LBRACE, String("{"), line, col, i, i + 1))
            i += 1
            col += 1
            continue
        if c == UInt8(ord("}")):
            out.append(Token(TOK_RBRACE, String("}"), line, col, i, i + 1))
            i += 1
            col += 1
            continue
        if c == UInt8(ord(":")):
            out.append(Token(TOK_COLON, String(":"), line, col, i, i + 1))
            i += 1
            col += 1
            continue

        # String literal: "..." or '...' with a small closed escape set.
        if c == UInt8(ord('"')) or c == UInt8(ord("'")):
            var quote = c
            var start = i
            var start_col = col
            var start_line = line
            i += 1
            col += 1
            # ⛔ THE `chr(Int(byte))` TRAP — WHY THIS ACCUMULATES BYTES, NOT
            # CODEPOINTS. `s += chr(Int(ch))` maps a byte >= 0x80 to the Unicode
            # CODE POINT of that value, which re-encodes as TWO UTF-8 bytes. So
            # every non-ASCII character in a bundle string grew on each pass:
            # an em-dash (E2 80 94) came out of the tokenizer as six bytes, the
            # emitter's `quote()` inflated those six to twelve, and a
            # parse->emit round trip DOUBLED the length of every such string
            # while turning it into mojibake. A bundle whose prose carries
            # em-dashes would not emit a fixpoint, and a patch — which splices
            # emitted bytes back over the file — would CORRUPT the document it
            # edited, a little more each time.
            #
            # The fix is the byte-faithful idiom: accumulate raw bytes and build
            # the String over the UTF-8 span at the end. Nothing in the escape set is multi-byte, so a
            # byte loop stays correct for the grammar.
            var sbuf = List[UInt8]()
            var closed = False
            while i < n:
                var ch = b[i]
                if ch == UInt8(ord("\\")) and i + 1 < n:
                    var esc = b[i + 1]
                    if esc == UInt8(ord("n")):
                        sbuf.append(UInt8(ord("\n")))
                    elif esc == UInt8(ord("t")):
                        sbuf.append(UInt8(ord("\t")))
                    elif esc == UInt8(ord("r")):
                        sbuf.append(UInt8(ord("\r")))
                    elif esc == UInt8(ord('"')):
                        sbuf.append(UInt8(ord('"')))
                    elif esc == UInt8(ord("'")):
                        sbuf.append(UInt8(ord("'")))
                    elif esc == UInt8(ord("\\")):
                        sbuf.append(UInt8(ord("\\")))
                    else:
                        # Unknown escape — pass the escaped byte through verbatim.
                        sbuf.append(esc)
                    i += 2
                    col += 2
                    continue
                if ch == quote:
                    i += 1
                    col += 1
                    closed = True
                    break
                if ch == UInt8(ord("\n")):
                    line += 1
                    col = 1
                else:
                    col += 1
                sbuf.append(ch)
                i += 1
            if not closed:
                raise Error(
                    String("line ")
                    + String(start_line)
                    + String(", col ")
                    + String(start_col)
                    + String(": unterminated string literal")
                )
            var s = String(StringSlice(unsafe_from_utf8=Span[UInt8](sbuf)))
            out.append(Token(TOK_STRING, s^, start_line, start_col, start, i))
            continue

        # Number: an optional leading '-' then digits.
        if _is_digit(c) or (c == UInt8(ord("-")) and i + 1 < n and _is_digit(b[i + 1])):
            var start = i
            var start_col = col
            if c == UInt8(ord("-")):
                i += 1
                col += 1
            while i < n and _is_digit(b[i]):
                i += 1
                col += 1
            var num = String("")
            for j in range(start, i):
                num += chr(Int(b[j]))
            out.append(Token(TOK_NUMBER, num^, line, start_col, start, i))
            continue

        # Identifier / enum value.
        if _is_ident_start(c):
            var start = i
            var start_col = col
            while i < n and _is_ident_char(b[i]):
                i += 1
                col += 1
            var word = String("")
            for j in range(start, i):
                word += chr(Int(b[j]))
            out.append(Token(TOK_IDENT, word^, line, start_col, start, i))
            continue

        # Anything else is a lexical error.
        raise Error(
            String("line ")
            + String(line)
            + String(", col ")
            + String(col)
            + String(": unexpected character '")
            + chr(Int(c))
            + String("'")
        )

    out.append(Token(TOK_EOF, String(""), line, col, n, n))
    return out^
