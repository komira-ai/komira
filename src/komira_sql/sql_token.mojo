# =============================================================================
# komira_sql/sql_token.mojo
#   Hand-written tokenizer for the ANALYTICAL SQL frontend.
# =============================================================================
#
# Tokenizes a SQL string into a flat `List[Token]`. This is the front of the
# recursive-descent parser (`sql_parser.mojo`). It is SEPARATE from the OLTP
# `komira_pgsql/sql_lexer.mojo` (that one targets a transactional Postgres
# face and builds no LogicalPlan). The analytical grammar adds float literals,
# arithmetic operators, and treats aggregate/keyword words as lower-folded
# identifiers that the parser classifies (DuckDB-ish case-insensitive dialect).
#
# POD-of-owned: a Token is a UInt8 tag + a String + an Int64 + a Float64. No
# UnsafePointer, no wildcard origins; stored in a plain `List[Token]`.
# =============================================================================


# Token kinds.
comptime TK_EOF: UInt8 = 0
comptime TK_IDENT: UInt8 = 1  # identifier (lower-folded) — incl. keywords/agg names
comptime TK_INT: UInt8 = 2  # integer literal (value in int_val)
comptime TK_FLOAT: UInt8 = 3  # float literal (value in float_val)
comptime TK_STRING: UInt8 = 4  # single-quoted string literal (text)
comptime TK_LPAREN: UInt8 = 5  # (
comptime TK_RPAREN: UInt8 = 6  # )
comptime TK_COMMA: UInt8 = 7  # ,
comptime TK_SEMI: UInt8 = 8  # ;
comptime TK_STAR: UInt8 = 9  # *
comptime TK_DOT: UInt8 = 10  # .
comptime TK_PLUS: UInt8 = 11  # +
comptime TK_MINUS: UInt8 = 12  # -
comptime TK_SLASH: UInt8 = 13  # /
comptime TK_EQ: UInt8 = 14  # =
comptime TK_NE: UInt8 = 15  # <> or !=
comptime TK_LT: UInt8 = 16  # <
comptime TK_LE: UInt8 = 17  # <=
comptime TK_GT: UInt8 = 18  # >
comptime TK_GE: UInt8 = 19  # >=
comptime TK_DCOLON: UInt8 = 20  # :: — the POSTFIX cast operator (2026-09-14)
comptime TK_DSLASH: UInt8 = 21  # // — DuckDB's INTEGER division (2026-09-24)
comptime TK_PERCENT: UInt8 = 22  # %  — DuckDB's modulo, `mod()` (2026-09-24)
"""⭐ THE LEXER HAD NO `:` TOKEN AT ALL, WHICH IS WHY `x::BIGINT` DIED HERE.

`test_sql_cast_e2e.py`'s header records the absence as THREE independent
frontend facts, and this is the first of them: the operator ladder below ended
at `!`, so `x::BIGINT` raised `unexpected character ':'` from the TOKENIZER —
before any grammar could have had an opinion. A `::` arm alone is not a cast;
`_parse_unary` binds it as a POSTFIX operator and the binder lowers it, and the
three had to move together or the layer that refuses just moves one file over.

⚠ A LONE `:` IS STILL REFUSED, AND ITS MESSAGE NOW NAMES THE OPERATOR IT IS
ONE CHARACTER SHORT OF. `:` has no meaning in this dialect (no named
parameters, no array slices), so keeping it a refusal is correct; what would be
wrong is refusing it with the SAME sentence as before, which said the character
is unexpected when the only unexpected thing is that there is one of it."""

# ★ OPERATOR SPELLINGS (2026-09-24). Four
# operators DuckDB v1.5.3 has and this lexer refused as an "unexpected
# character" — a syntax error that named nothing. Each is ONE more token; what
# each MEANS is the parser's and the binder's (`sql_parser._parse_op` /
# `_parse_pow` / `_parse_unary`, `sql_bind_ops._bind_sql_operator`).
comptime TK_CARET: UInt8 = 23  # ^  — power, `pow()` (DOUBLE); binds tighter than `*`
comptime TK_CARET_AT: UInt8 = 24  # ^@ — starts-with, `starts_with()`
comptime TK_AT: UInt8 = 25  # @  — PREFIX absolute value, `abs()`
comptime TK_DPIPE: UInt8 = 26  # || — string concatenation (NULL-PROPAGATING)
# ★ THE POSTGRES-STYLE PATTERN OPERATORS (2026-09-24). DuckDB v1.5.3
# answers `s ~~ 'a%'` (LIKE), `!~~` (NOT LIKE), `~~*` (ILIKE), `!~~*` (NOT
# ILIKE) — they are the NAMES it prints for the keyword forms — and `s ~ 'a.*'`
# / `!~` (regexp_full_match, exactly SIMILAR TO). This lexer refused every one
# as "unexpected character '~'". ONE token for the LIKE family, its flavour in
# `int_val`: 0 `~~`, 1 `!~~`, 2 `~~*`, 3 `!~~*`.
comptime TK_LIKE_SYM: UInt8 = 27  # ~~ / !~~ / ~~* / !~~*
comptime TK_TILDE: UInt8 = 28  # ~  — infix regexp_full_match; PREFIX is DuckDB's bitwise NOT (refused)
comptime TK_NTILDE: UInt8 = 29  # !~ — NOT regexp_full_match


@fieldwise_init
struct Token(Copyable, Movable, Deinitable):
    """One lexed token. POD-of-owned.

    Field layout:
      var kind: UInt8
      var text: String       — identifier (lower-folded) / string-literal value.
      var int_val: Int64     — live for TK_INT. For a literal PAST Int64.MAX
                               `text` holds its decimal digits and `int_val`
                               the wrapped bits (see `tokenize`).
      var float_val: Float64 — live for TK_FLOAT.
    """

    var kind: UInt8
    var text: String
    var int_val: Int64
    var float_val: Float64


@always_inline
def _is_space(c: UInt8) -> Bool:
    return c == UInt8(ord(" ")) or c == UInt8(ord("\t")) or c == UInt8(ord("\n")) or c == UInt8(ord("\r"))


@always_inline
def _is_digit(c: UInt8) -> Bool:
    return c >= UInt8(ord("0")) and c <= UInt8(ord("9"))


@always_inline
def _is_alpha(c: UInt8) -> Bool:
    return (
        (c >= UInt8(ord("a")) and c <= UInt8(ord("z")))
        or (c >= UInt8(ord("A")) and c <= UInt8(ord("Z")))
        or c == UInt8(ord("_"))
    )


@always_inline
def _is_ident(c: UInt8) -> Bool:
    return _is_alpha(c) or _is_digit(c)


def tokenize(sql: String) raises -> List[Token]:
    """Tokenize `sql` into a `List[Token]` ending with a TK_EOF sentinel.

    Raises a clean `Error` (never a crash) on an unterminated string literal or
    an unexpected character. Unquoted identifiers are lower-folded (DuckDB-ish
    case-insensitive dialect); keywords and aggregate names are ordinary
    identifiers the parser classifies by (lower-cased) text.
    """
    var src = sql.as_bytes()
    var n = len(src)
    var i = 0
    var out = List[Token]()
    while i < n:
        var c = src[i]
        if _is_space(c):
            i += 1
            continue
        # line comment: -- to end of line
        if c == UInt8(ord("-")) and i + 1 < n and src[i + 1] == UInt8(ord("-")):
            while i < n and src[i] != UInt8(ord("\n")):
                i += 1
            continue
        # numeric literal: INT or FLOAT (`digits [ . digits ]`). A leading '-'
        # is NOT fused here — the parser handles unary minus, so `1-1` and
        # `-x` both tokenize cleanly. Digits are accumulated manually (no
        # atol/atof dependency) so the tokenizer is self-contained.
        if _is_digit(c):
            var int_part: Int64 = 0
            # ⛔ AN INTEGER PAST BIGINT MAY NOT WRAP.
            # `int_part * 10 + d` in Int64 wrapped silently, so
            # `18446744073709551615` lexed as -1 and
            # `WHERE u64 = 18446744073709551615` compared against -1 and
            # selected NO row (DuckDB 1.5.3 types that literal HUGEINT and
            # answers). A literal past Int64.MAX now also carries its DIGITS in
            # `text` -- the binder serves it only where its exact value is
            # read, and refuses it by name everywhere else. `int_val` keeps the
            # wrapped bits, which is exactly `Int64.MIN` for
            # `9223372036854775808`, the one out-of-range magnitude a unary
            # minus makes legal (`-9223372036854775808` is BIGINT's minimum).
            var digits_start = i
            var past_i64 = False
            while i < n and _is_digit(src[i]):
                var dig = Int64(Int(src[i]) - Int(ord("0")))
                if not past_i64 and (
                    int_part > Int64.MAX // 10
                    or (int_part == Int64.MAX // 10 and dig > Int64.MAX % 10)
                ):
                    past_i64 = True
                int_part = int_part * 10 + dig
                i += 1
            if i < n and src[i] == UInt8(ord(".")) and i + 1 < n and _is_digit(src[i + 1]):
                # The integer part of a DOUBLE literal is read in Float64 when
                # it is past Int64 -- `int_part` holds wrapped bits there.
                var ipf = Float64(int_part)
                if past_i64:
                    ipf = Float64(0.0)
                    for j in range(digits_start, i):
                        ipf = ipf * 10.0 + Float64(Int(src[j]) - Int(ord("0")))
                i += 1  # consume '.'
                var frac: Float64 = 0.0
                var scale: Float64 = 1.0
                while i < n and _is_digit(src[i]):
                    frac = frac * 10.0 + Float64(Int(src[i]) - Int(ord("0")))
                    scale = scale * 10.0
                    i += 1
                var fval = ipf + frac / scale
                out.append(Token(TK_FLOAT, String(""), Int64(0), fval))
            elif past_i64:
                # ASCII digits only, so each byte IS its codepoint here.
                var digits = String("")
                for j in range(digits_start, i):
                    digits += chr(Int(src[j]))
                out.append(Token(TK_INT, digits^, int_part, Float64(0.0)))
            else:
                out.append(Token(TK_INT, String(""), int_part, Float64(0.0)))
            continue
        # string literal: '...'  with '' as an embedded single quote.
        #
        # ⛔⛔ ACCUMULATED AS **BYTES**, NEVER `chr(Int(src[i]))`. That idiom is
        # a CODEPOINT constructor, so every byte >= 0x80 came back as its
        # two-byte UTF-8 encoding and EVERY non-ASCII SQL string literal
        # reached the binder as mojibake — `'ß'` (C3 9F) arrived as `Ã\u009f`
        # (C3 83 C2 9F). Nothing raised; the literal simply matched nothing.
        # MEASURED against DuckDB v1.5.3: `strpos('Straße','ß')` is 5 there and
        # was 0 here. Regression test:
        # `test_sql_a_NON_ASCII_STRING_LITERAL_survives_the_lexer`, whose every
        # result is an INT or a BOOL so that it isolates THIS site from the
        # regexp string BUILDER, which carried the identical bug.
        #
        # ⚠ THE IDENTIFIER SCANNER BELOW STILL USES `chr(Int(...))` AND THAT IS
        # SAFE, not an oversight: `_is_ident` accepts only `[A-Za-z0-9_]`, so
        # no byte it collects can be >= 0x80. The unexpected-character error
        # message does too, and can still render a stray high byte as
        # mojibake — in an ERROR STRING, never in a value.
        if c == UInt8(ord("'")):
            i += 1
            var sbytes = List[UInt8]()
            var closed = False
            while i < n:
                if src[i] == UInt8(ord("'")):
                    if i + 1 < n and src[i + 1] == UInt8(ord("'")):
                        sbytes.append(UInt8(ord("'")))
                        i += 2
                        continue
                    i += 1
                    closed = True
                    break
                sbytes.append(src[i])
                i += 1
            if not closed:
                raise Error("SQL syntax error: unterminated string literal")
            out.append(
                Token(
                    TK_STRING,
                    String(StringSlice(unsafe_from_utf8=Span[UInt8](sbytes))),
                    Int64(0),
                    Float64(0.0),
                )
            )
            continue
        # identifier (or keyword / agg name) — lower-folded.
        if _is_alpha(c):
            var start = i
            while i < n and _is_ident(src[i]):
                i += 1
            var word = String("")
            for j in range(start, i):
                word += chr(Int(src[j]))
            out.append(Token(TK_IDENT, word.lower(), Int64(0), Float64(0.0)))
            continue
        # operators + punctuation
        if c == UInt8(ord("(")):
            out.append(Token(TK_LPAREN, String(""), Int64(0), Float64(0.0))); i += 1; continue
        if c == UInt8(ord(")")):
            out.append(Token(TK_RPAREN, String(""), Int64(0), Float64(0.0))); i += 1; continue
        if c == UInt8(ord(",")):
            out.append(Token(TK_COMMA, String(""), Int64(0), Float64(0.0))); i += 1; continue
        if c == UInt8(ord(";")):
            out.append(Token(TK_SEMI, String(""), Int64(0), Float64(0.0))); i += 1; continue
        if c == UInt8(ord("*")):
            out.append(Token(TK_STAR, String(""), Int64(0), Float64(0.0))); i += 1; continue
        if c == UInt8(ord(".")):
            out.append(Token(TK_DOT, String(""), Int64(0), Float64(0.0))); i += 1; continue
        if c == UInt8(ord("+")):
            out.append(Token(TK_PLUS, String(""), Int64(0), Float64(0.0))); i += 1; continue
        if c == UInt8(ord("-")):
            out.append(Token(TK_MINUS, String(""), Int64(0), Float64(0.0))); i += 1; continue
        # `/` is DuckDB's TRUE division and `//` its INTEGER division — two
        # operators, so two tokens. `//` is lexed greedily, which is also what
        # DuckDB does: `7 / / 2` is a syntax error there (MEASURED v1.5.3), so
        # `//` is never two slashes that happen to be adjacent.
        if c == UInt8(ord("/")):
            if i + 1 < n and src[i + 1] == UInt8(ord("/")):
                out.append(Token(TK_DSLASH, String(""), Int64(0), Float64(0.0))); i += 2; continue
            out.append(Token(TK_SLASH, String(""), Int64(0), Float64(0.0))); i += 1; continue
        # `%` OUTSIDE a string literal is the modulo operator (a LIKE pattern's
        # `%` is inside quotes and never reaches this ladder).
        if c == UInt8(ord("%")):
            out.append(Token(TK_PERCENT, String(""), Int64(0), Float64(0.0))); i += 1; continue
        if c == UInt8(ord("=")):
            out.append(Token(TK_EQ, String(""), Int64(0), Float64(0.0))); i += 1; continue
        if c == UInt8(ord("<")):
            if i + 1 < n and src[i + 1] == UInt8(ord("=")):
                out.append(Token(TK_LE, String(""), Int64(0), Float64(0.0))); i += 2; continue
            if i + 1 < n and src[i + 1] == UInt8(ord(">")):
                out.append(Token(TK_NE, String(""), Int64(0), Float64(0.0))); i += 2; continue
            out.append(Token(TK_LT, String(""), Int64(0), Float64(0.0))); i += 1; continue
        if c == UInt8(ord(">")):
            if i + 1 < n and src[i + 1] == UInt8(ord("=")):
                out.append(Token(TK_GE, String(""), Int64(0), Float64(0.0))); i += 2; continue
            out.append(Token(TK_GT, String(""), Int64(0), Float64(0.0))); i += 1; continue
        # `^` is power and `^@` starts-with — two operators, lexed greedily as
        # DuckDB does (`'ab' ^@ 'a'` is TRUE there; `2 ^ 3` is 8.0).
        if c == UInt8(ord("^")):
            if i + 1 < n and src[i + 1] == UInt8(ord("@")):
                out.append(Token(TK_CARET_AT, String(""), Int64(0), Float64(0.0))); i += 2; continue
            out.append(Token(TK_CARET, String(""), Int64(0), Float64(0.0))); i += 1; continue
        if c == UInt8(ord("@")):
            out.append(Token(TK_AT, String(""), Int64(0), Float64(0.0))); i += 1; continue
        # `||` is concatenation. ⚠ A LONE `|` IS DuckDB's BITWISE OR (`5 | 3` =
        # 7, MEASURED v1.5.3), which this engine has no operator for — so it is
        # refused NAMING that operator, not as an unexpected character.
        if c == UInt8(ord("|")):
            if i + 1 < n and src[i + 1] == UInt8(ord("|")):
                out.append(Token(TK_DPIPE, String(""), Int64(0), Float64(0.0))); i += 2; continue
            raise Error(
                "SQL not supported: the bitwise OR operator `|` (DuckDB answers"
                " `5 | 3` = 7). This engine has no bitwise operator; `||` is"
                " string concatenation, which is a different operator"
            )
        if c == UInt8(ord("~")):
            if i + 1 < n and src[i + 1] == UInt8(ord("~")):
                if i + 2 < n and src[i + 2] == UInt8(ord("*")):
                    out.append(Token(TK_LIKE_SYM, String(""), Int64(2), Float64(0.0))); i += 3; continue
                out.append(Token(TK_LIKE_SYM, String(""), Int64(0), Float64(0.0))); i += 2; continue
            out.append(Token(TK_TILDE, String(""), Int64(0), Float64(0.0))); i += 1; continue
        if c == UInt8(ord("!")):
            if i + 1 < n and src[i + 1] == UInt8(ord("=")):
                out.append(Token(TK_NE, String(""), Int64(0), Float64(0.0))); i += 2; continue
            if i + 1 < n and src[i + 1] == UInt8(ord("~")):
                if i + 2 < n and src[i + 2] == UInt8(ord("~")):
                    if i + 3 < n and src[i + 3] == UInt8(ord("*")):
                        out.append(Token(TK_LIKE_SYM, String(""), Int64(3), Float64(0.0))); i += 4; continue
                    out.append(Token(TK_LIKE_SYM, String(""), Int64(1), Float64(0.0))); i += 3; continue
                out.append(Token(TK_NTILDE, String(""), Int64(0), Float64(0.0))); i += 2; continue
            raise Error("SQL syntax error: unexpected character '!'")
        # `::` — the POSTFIX cast operator. TWO characters, and a LONE `:` is
        # still a refusal: this dialect has no named parameters and no slice
        # syntax, so a single colon is a typo for `::` far more often than it
        # is anything else, and the message says so rather than repeating the
        # generic unexpected-character sentence.
        if c == UInt8(ord(":")):
            if i + 1 < n and src[i + 1] == UInt8(ord(":")):
                out.append(Token(TK_DCOLON, String(""), Int64(0), Float64(0.0))); i += 2; continue
            raise Error(
                "SQL syntax error: unexpected character ':' — a single colon has"
                " no meaning in this dialect; the cast operator is '::', as in"
                " `x::BIGINT`"
            )
        raise Error("SQL syntax error: unexpected character '" + chr(Int(c)) + "'")
    out.append(Token(TK_EOF, String(""), Int64(0), Float64(0.0)))
    return out^
