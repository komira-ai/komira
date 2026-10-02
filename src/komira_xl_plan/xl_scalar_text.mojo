# =============================================================================
# xl_scalar_text.mojo — ★ THE EXCEL TEXT SCALAR KERNELS.
# =============================================================================
#
# ⚠⚠ THE CASE AXIS IS THE WHOLE POINT OF THIS FAMILY AND IT DIVIDES IT:
#
#     FIND    case-SENSITIVE     — Excel's exact-match search
#     SEARCH  case-INSENSITIVE   — Excel's forgiving search
#     EXACT   case-SENSITIVE     — the only text COMPARISON that is
#
# and Excel's ordinary `=` on text is case-INSENSITIVE, which is why
# `EXACT` exists at all. A shared "compare two strings" helper would collapse
# three deliberately different functions into one, silently.
#
# ⚠ BYTE-LEVEL, ASCII == CODEPOINT, exactly as `fn_scalar_core`'s LEFT/RIGHT/
# MID already are. Multibyte-correct positions are the same w2 refinement those
# carry and it is stated in the same place rather than being a new caveat.
#
# Encapsulation rule : values only. No `UnsafePointer`, no wildcard
# origins.
# =============================================================================

from komira_core.plan.excel_error_code import XL_ERR_NA, XL_ERR_VALUE

from .formula_value import FormulaValue


def _text(imm args: List[FormulaValue], i: Int) -> FormulaValue:
    """Argument `i` coerced to TEXT, or the error that stops the call. One
    spelling so the dominance order cannot differ between kernels."""
    if args[i].is_error():
        return args[i].copy()
    return args[i].coerce_text()


def _num(imm args: List[FormulaValue], i: Int) -> FormulaValue:
    if args[i].is_error():
        return args[i].copy()
    return args[i].coerce_number()


# =============================================================================
# ★★ CHARACTER INDEXING — ONE DEFINITION, BECAUSE EXCEL COUNTS CHARACTERS
#    (2026-09-14).
# =============================================================================
#
# ⚠ AND AN ASCII FIXTURE CANNOT SEE ANY OF IT. For ASCII the byte index and
# the character index are the SAME NUMBER, which is why a text family with a
# per-function assertion for every member carried this for its whole life.
#
# ⇒ ONE definition, here, used by every position-taking text kernel in BOTH
# packages. A UTF-8 lead byte is any byte that is not `10xxxxxx`, so the
# character starts are derivable without decoding.
# =============================================================================
@always_inline
def _is_lead(b: UInt8) -> Bool:
    return (b & UInt8(0xC0)) != UInt8(0x80)


def xl_char_starts(s: String) -> List[Int]:
    """The BYTE offset of every CHARACTER start, with a final SENTINEL equal to
    the byte length — so `len(result) - 1` is the character count and
    `result[i]..result[i+1]` is character `i`'s bytes.

    ⚠ THE SENTINEL IS LOAD-BEARING: without it the last character has no end
    offset and every slicing caller needs a special case for it."""
    var bs = s.as_bytes()
    var out = List[Int]()
    for k in range(len(bs)):
        if _is_lead(bs[k]):
            out.append(k)
    out.append(len(bs))
    return out^


def xl_char_count(s: String) -> Int:
    """The number of CHARACTERS — what Excel's `LEN` returns."""
    return len(xl_char_starts(s)) - 1


def xl_substr_chars(s: String, start0: Int, n: Int) -> String:
    """`n` CHARACTERS from the 0-based CHARACTER index `start0`, clamped at
    both ends.

    ⛔ IT CANNOT SPLIT A CHARACTER, which is the property the byte version did
    not have: every result is valid UTF-8 by construction, and a request that
    runs off either end shortens rather than corrupting."""
    if n <= 0:
        return String("")
    var st = xl_char_starts(s)
    var total = len(st) - 1
    var a = start0
    if a < 0:
        a = 0
    if a >= total:
        return String("")
    var b = a + n
    if b > total:
        b = total
    var bs = s.as_bytes()
    var out = List[UInt8]()
    for k in range(st[a], st[b]):
        out.append(bs[k])
    return String(StringSlice(unsafe_from_utf8=Span(out)))


def xl_chars(s: String) -> List[String]:
    """The CHARACTERS of `s`, one `String` each — the representation the
    search kernels compare over, so that a position is a CHARACTER position
    and a case fold cannot shift one."""
    var st = xl_char_starts(s)
    var bs = s.as_bytes()
    var out = List[String]()
    for i in range(len(st) - 1):
        var buf = List[UInt8]()
        for k in range(st[i], st[i + 1]):
            buf.append(bs[k])
        out.append(String(StringSlice(unsafe_from_utf8=Span(buf))))
    return out^


def _lower_chars(imm cs: List[String]) -> List[String]:
    """Each character lower-cased INDIVIDUALLY.

    ⚠ NOT `s.lower()` ON THE WHOLE STRING, and the difference is a position
    bug. A full case fold can change a string's LENGTH (`"İ"` lower-folds to
    two code points), so folding the haystack as one string and then reporting
    a position measured in the FOLDED string reports a position that does not
    exist in the INPUT. Folding per character keeps the index 1:1."""
    var out = List[String]()
    for i in range(len(cs)):
        out.append(cs[i].lower())
    return out^


# =============================================================================
# Case
# =============================================================================
def xl_upper(imm args: List[FormulaValue]) raises -> FormulaValue:
    var t = _text(args, 0)
    if t.is_error():
        return t^
    return FormulaValue.text_val(t.text.upper())


def xl_lower(imm args: List[FormulaValue]) raises -> FormulaValue:
    var t = _text(args, 0)
    if t.is_error():
        return t^
    return FormulaValue.text_val(t.text.lower())


def _is_letter_cp(cp: Int) -> Bool:
    """Is this code point a LETTER, for `PROPER`'s word-boundary rule?

    ⚠ THE RANGES ARE EXPLICIT AND THEIR LIMIT IS STATED RATHER THAN IMPLIED.
    Latin-1 letters, Latin Extended-A/B, Greek and Cyrillic are letters here;
    ⛔ every OTHER non-ASCII code point is NOT, which is deliberate and is the
    residual. U+2019 (the typographic apostrophe) must stay a boundary so that
    `o'neil` and `o’neil` agree, and a blanket "anything >= 0x80 is a letter"
    rule breaks exactly that. A full Unicode general-category table is the
    complete answer and this tree has none; what is here is a bounded
    improvement with its boundary written down —, which enumerates the scripts this
    range list classifies NON-LETTER."""
    if cp >= 0x41 and cp <= 0x5A:
        return True
    if cp >= 0x61 and cp <= 0x7A:
        return True
    if cp < 0x80:
        return False
    # Latin-1 Supplement letters: 0xC0..0xFF except the two MATH signs.
    if cp >= 0xC0 and cp <= 0xFF:
        return cp != 0xD7 and cp != 0xF7
    if cp == 0xAA or cp == 0xB5 or cp == 0xBA:
        return True
    # Latin Extended-A and Extended-B.
    if cp >= 0x100 and cp <= 0x24F:
        return True
    # Greek and Coptic, then Cyrillic (+ its supplement).
    if cp >= 0x370 and cp <= 0x3FF:
        return cp != 0x374 and cp != 0x375 and cp != 0x37E and cp != 0x387
    if cp >= 0x400 and cp <= 0x52F:
        return True
    return False


def xl_proper(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`PROPER(text)` — the first letter of each WORD upper-cased, every other
    letter lower-cased.

    ⚠ A WORD BOUNDARY IS ANY NON-LETTER, NOT JUST A SPACE. Excel's PROPER
    capitalises after a digit or punctuation too, so `PROPER("o'neil")` is
    `O'Neil` and `PROPER("2nd place")` is `2Nd Place` — the second looks wrong
    and IS what Excel returns. Implementing "after a space" instead would
    disagree with Excel on exactly the inputs a user notices.

    ⚠ AND THE LETTER TEST IS NOT ASCII — see `_is_letter_cp`, which carries the
    measured defect an ASCII test produced and the exact limit of its
    replacement."""
    var t = _text(args, 0)
    if t.is_error():
        return t^
    var out = String("")
    var start_of_word = True
    for cp in t.text.codepoints():
        var ch = String(cp)
        if _is_letter_cp(Int(cp)):
            if start_of_word:
                out += ch.upper()
            else:
                out += ch.lower()
            start_of_word = False
        else:
            out += ch
            start_of_word = True
    return FormulaValue.text_val(out^)


# =============================================================================
# Search
# =============================================================================
def _find_chars(imm hay: List[String], imm needle: List[String], start0: Int) -> Int:
    """The 0-based CHARACTER index of `needle` in `hay` at or after `start0`,
    or -1. LITERAL — no wildcard meaning.

    ⚠ AN EMPTY NEEDLE MATCHES AT `start0`, which is Excel's behaviour
    (`FIND("", "abc", 2)` is 2) and not a degenerate case to guard against."""
    var n = len(hay)
    var m = len(needle)
    if start0 < 0 or start0 > n:
        return -1
    if m == 0:
        return start0
    var i = start0
    while i + m <= n:
        var ok = True
        for k in range(m):
            if hay[i + k] != needle[k]:
                ok = False
                break
        if ok:
            return i
        i += 1
    return -1


# =============================================================================
# ★★ THE WILDCARD MATCHER — `*`, `?` AND `~`, WHICH `SEARCH` HAS AND `FIND`
#    DOES NOT.
# =============================================================================
#
# ⛔ THIS FILE USED TO SAY THE DIVERGENCE WAS "WRITTEN DOWN RATHER THAN
# RESOLVED": `SEARCH` searched for the LITERAL characters, so `SEARCH("a*c",
# "abc")` was `#VALUE!` where Excel answers 1, and the census row carried the
# admission. It is resolved now, and the oracle row that carried
# `xl_agrees = N` for it is graded against EXCEL.
#
# ⚠ `~` IS AN ESCAPE AND ONLY BEFORE `*`, `?` OR `~`. `SEARCH("~*","a*b")` is
# 2 — the literal asterisk — while `SEARCH("*","a*b")` is 1, because a bare
# `*` matches the empty string at the first position. A kernel that treated
# `~` as a general escape (or that ignored it) gets one of those two wrong.
#
# ⛔ AND `FIND` MUST NOT GAIN THIS. Excel's FIND is literal; the pair exists so
# a sheet can ask for a literal `*`. Sharing one matcher between them is the
# obvious "simplification" and it deletes a function.
# =============================================================================
def _wild_compile(
    imm needle: List[String], mut toks: List[String], mut lit: List[Bool]
):
    """Split `needle` into tokens + a per-token "this is a LITERAL character"
    flag. Only `~*`, `~?` and `~~` consume the tilde; a tilde before anything
    else is itself, which is Excel's rule."""
    var i = 0
    while i < len(needle):
        var c = needle[i]
        if c == String("~") and i + 1 < len(needle):
            var nxt = needle[i + 1]
            if nxt == String("*") or nxt == String("?") or nxt == String("~"):
                toks.append(nxt)
                lit.append(True)
                i += 2
                continue
        toks.append(c)
        lit.append(False)
        i += 1


def _wild_match_at(
    imm h: List[String], hi0: Int, imm p: List[String], imm plit: List[Bool]
) -> Bool:
    """Does the compiled pattern match `h` STARTING AT `hi0`? The pattern need
    not consume the whole haystack — `SEARCH` reports a start position, not an
    equality.

    ⚠ THE BACKTRACK IS THE `*` STAR STATE, and the loop terminates because
    every iteration either advances the pattern cursor or advances the
    remembered star position, neither of which can move backwards."""
    var hi = hi0
    var pi = 0
    var star_p = -1
    var star_h = -1
    while True:
        if pi == len(p):
            return True
        var c = p[pi]
        var esc = plit[pi]
        if not esc and c == String("*"):
            star_p = pi
            star_h = hi
            pi += 1
            continue
        if hi < len(h) and (
            (not esc and c == String("?")) or c == h[hi]
        ):
            pi += 1
            hi += 1
            continue
        if star_p >= 0 and star_h < len(h):
            star_h += 1
            hi = star_h
            pi = star_p + 1
            continue
        return False


def _wild_find(
    imm hay: List[String], imm needle: List[String], start0: Int
) -> Int:
    """The 0-based CHARACTER index of the FIRST position at or after `start0`
    where the wildcard pattern matches, or -1.

    ⚠ WITH NO WILDCARD IN THE PATTERN THIS IS EXACTLY `_find_chars`, so
    `SEARCH` runs ONE code path and the literal case is not a second
    implementation that could drift from it."""
    var toks = List[String]()
    var lit = List[Bool]()
    _wild_compile(needle, toks, lit)
    var n = len(hay)
    if start0 < 0 or start0 > n:
        return -1
    var i = start0
    while i <= n:
        if _wild_match_at(hay, i, toks, lit):
            return i
        i += 1
    return -1


def _start_arg(imm args: List[FormulaValue], i: Int) -> FormulaValue:
    """The optional 1-based `start_num` (default 1). `start_num < 1` is
    `#VALUE!` in Excel, not a clamp to the beginning."""
    if len(args) <= i:
        return FormulaValue.number(1.0)
    var v = _num(args, i)
    if v.is_error():
        return v^
    if v.num < 1.0:
        return FormulaValue.error(XL_ERR_VALUE)
    return v^


def xl_find(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`FIND(find_text, within_text, [start_num])` — CASE-SENSITIVE, 1-based,
    and LITERAL: no wildcard meaning, which is the half of the pair that lets a
    sheet search for a real `*`.

    Not found is `#VALUE!`, NOT 0 and NOT `#N/A`: Excel's "no match" for the
    text-search pair is `#VALUE!`, which `IFERROR` is the idiomatic wrapper
    for.

    ⚠ THE POSITION IS A CHARACTER POSITION. `FIND("v","naïve")` is 4, not the
    byte offset 5 — see the character-indexing banner above."""
    var needle = _text(args, 0)
    if needle.is_error():
        return needle^
    var hay = _text(args, 1)
    if hay.is_error():
        return hay^
    var start = _start_arg(args, 2)
    if start.is_error():
        return start^
    var at = _find_chars(
        xl_chars(hay.text), xl_chars(needle.text), Int(start.num) - 1
    )
    if at < 0:
        return FormulaValue.error(XL_ERR_VALUE)
    return FormulaValue.number(Float64(at + 1))


def xl_search(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`SEARCH(find_text, within_text, [start_num])` — CASE-INSENSITIVE,
    1-based, and WILDCARD-AWARE (`*`, `?`, escaped by `~`).

    ⭐ THE TWO WAYS IT DIFFERS FROM `FIND` ARE BOTH LIVE HERE, and each has a
    cell: case (`SEARCH("b","aBc")` is 2 where `FIND("b","aBc")` refuses) and
    wildcards (`SEARCH("a*c","abc")` is 1 where `FIND("a*c","abc")` refuses).
    A kernel sharing FIND's comparator passes neither; a kernel sharing FIND's
    literal scan passes the first and not the second."""
    var needle = _text(args, 0)
    if needle.is_error():
        return needle^
    var hay = _text(args, 1)
    if hay.is_error():
        return hay^
    var start = _start_arg(args, 2)
    if start.is_error():
        return start^
    var at = _wild_find(
        _lower_chars(xl_chars(hay.text)),
        _lower_chars(xl_chars(needle.text)),
        Int(start.num) - 1,
    )
    if at < 0:
        return FormulaValue.error(XL_ERR_VALUE)
    return FormulaValue.number(Float64(at + 1))


# =============================================================================
# REPLACE / EXACT / VALUE
# =============================================================================
def xl_replace(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`REPLACE(old_text, start_num, num_chars, new_text)` — replace by
    POSITION.

    ⚠ NOT `SUBSTITUTE`, WHICH REPLACES BY CONTENT. The pair is one of Excel's
    genuine near-duplicates and picking the wrong one is a silent wrong string.
    `start_num < 1` or `num_chars < 0` is `#VALUE!`.

    ⚠ `start_num` AND `num_chars` COUNT CHARACTERS. `REPLACE("naïve",3,1,"i")`
    is `"naive"`; a byte-indexed kernel removes one byte of the 2-byte `ï` and
    returns a string that is not valid UTF-8."""
    var t = _text(args, 0)
    if t.is_error():
        return t^
    var st = _num(args, 1)
    if st.is_error():
        return st^
    if st.num < 1.0:
        return FormulaValue.error(XL_ERR_VALUE)
    var nc = _num(args, 2)
    if nc.is_error():
        return nc^
    if nc.num < 0.0:
        return FormulaValue.error(XL_ERR_VALUE)
    var new = _text(args, 3)
    if new.is_error():
        return new^

    var total = xl_char_count(t.text)
    var a = Int(st.num) - 1
    if a > total:
        a = total
    var b = a + Int(nc.num)
    if b > total:
        b = total
    # ⚠ CHARACTER slices, not byte slices — `REPLACE("naïve",3,1,"i")` has to
    # take out the whole 2-byte `ï` and not its lead byte.
    var out = xl_substr_chars(t.text, 0, a)
    out += new.text
    out += xl_substr_chars(t.text, b, total - b)
    return FormulaValue.text_val(out^)


def xl_exact(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`EXACT(text1, text2)` — CASE-SENSITIVE equality, returning a LOGICAL.

    ★ IT EXISTS BECAUSE EXCEL'S `=` ON TEXT IS CASE-INSENSITIVE. `"a"="A"` is
    TRUE in a sheet; `EXACT("a","A")` is FALSE. A kernel that compared
    case-insensitively here would make the function a synonym for `=` and
    delete the only way a sheet can ask the question."""
    var a = _text(args, 0)
    if a.is_error():
        return a^
    var b = _text(args, 1)
    if b.is_error():
        return b^
    return FormulaValue.logical_val(a.text == b.text)


def xl_value(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`VALUE(text)` — text to number; non-numeric text is `#VALUE!`.

    ⚠ BLANK IS 0 AND NOT AN ERROR, which falls out of `coerce_number` and is
    Excel's answer for an empty cell. An empty STRING is `#VALUE!` — the
    distinction `FormulaValue`'s BLANK member exists to carry."""
    if args[0].is_error():
        return args[0].copy()
    return args[0].coerce_number()


# =============================================================================
# ★★ THE TEXT WAVE — REPT / CHAR / CODE / CLEAN / T / N.
#
# ⚠ FOUR OF THE SIX ARE INVISIBLE-CENSUS NAMES: they were in neither
# `xl_function_table`'s rows nor `xl_absent_common_names`, so a caller could
# not learn that this engine did not have them.
# =============================================================================
comptime _REPT_MAX_CHARS: Int = 32767
"""Excel's own cell text limit. `REPT` past it is `#VALUE!` in Excel, and the
refusal is what keeps a `REPT("x", 1e9)` from being an allocation rather than
an error."""


def xl_rept(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`REPT(text, number_times)` — the text repeated.

    ⚠ `number_times` IS TRUNCATED, NOT ROUNDED: `REPT("ab", 2.9)` is "abab".
    Zero gives the EMPTY STRING (not an error, and not the text once), and a
    NEGATIVE count is `#VALUE!`.

    ⛔ AND THE LENGTH CEILING IS A REFUSAL, NOT A CLAMP. Excel's cell text
    limit is 32,767 characters and `REPT` past it is `#VALUE!`. A clamp would
    return a TRUNCATED string that looks like a successful answer; the refusal
    is also what stops `REPT("x", 1e9)` from being an allocation instead of an
    error."""
    var t = _text(args, 0)
    if t.is_error():
        return t^
    var n = _num(args, 1)
    if n.is_error():
        return n^
    if n.num < 0.0:
        return FormulaValue.error(XL_ERR_VALUE)
    var count = Int(n.num)  # truncates toward zero for a non-negative value
    # ⚠ THE CEILING IS 32,767 **CHARACTERS**, which is what Excel's cell text
    # limit counts. A byte ceiling refuses a legal formula over non-ASCII text.
    var unit = xl_char_count(t.text)
    if unit * count > _REPT_MAX_CHARS:
        return FormulaValue.error(XL_ERR_VALUE)
    var out = String("")
    for _ in range(count):
        out += t.text
    return FormulaValue.text_val(out^)


def xl_char(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`CHAR(number)` — the character for a code point.

    ⛔⛔ THE RANGE IS **1..127 ONLY**, AND THE REFUSAL ABOVE IT IS THE WHOLE
    DESIGN DECISION IN THIS FUNCTION. Excel's `CHAR` maps 128..255 through the
    machine's ANSI code page — Windows-1252 on a Western Windows box, MacRoman
    historically, something else under another locale — so `CHAR(128)` is "€"
    for most users and is NOT U+0080. This engine's strings are UTF-8 and have
    no code page, so returning the Unicode scalar for 128..255 would give a
    plausible WRONG character for 27 of those 128 codes and a right one for the
    rest, with nothing to distinguish them.

    ⇒ `#VALUE!` above 127, which is a REFUSAL where Excel answers. That is a
    divergence and it is stated in the row; it is the safe direction, because
    the alternative is a confident wrong glyph. `CHAR(0)` is `#VALUE!` in Excel
    too."""
    var n = _num(args, 0)
    if n.is_error():
        return n^
    var code = Int(n.num)
    if code < 1 or code > 127:
        return FormulaValue.error(XL_ERR_VALUE)
    var out = List[UInt8]()
    out.append(UInt8(code))
    return FormulaValue.text_val(String(StringSlice(unsafe_from_utf8=Span(out))))


def xl_code(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`CODE(text)` — the code of the FIRST character.

    ⚠ IT RETURNS THE UNICODE SCALAR VALUE, and for the ASCII range that is
    byte-identical to what Excel returns. Above 127 Excel returns an ANSI
    CODE-PAGE byte (0..255) where this returns a code point that can exceed
    255 — the same code-page divergence `CHAR` refuses on, in the direction
    where a refusal is not available (`CODE` must return a number). Stated
    rather than resolved.

    An EMPTY text is `#VALUE!`, which is Excel's answer."""
    var t = _text(args, 0)
    if t.is_error():
        return t^
    for cp in t.text.codepoints():
        return FormulaValue.number(Float64(Int(cp)))
    return FormulaValue.error(XL_ERR_VALUE)


def xl_clean(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`CLEAN(text)` — strip the non-printable ASCII controls, 0..31.

    ⚠ IT IS NOT `TRIM`. `TRIM` collapses SPACES; `CLEAN` removes CONTROL
    CHARACTERS and leaves every space exactly where it was. Reaching for the
    wrong one gives a string that looks cleaned and is not.

    ⚠ AND IT IS THE 0..31 RANGE ONLY, WHICH IS EXCEL'S CLASSIC DEFINITION:
    DEL (127) and the C1 controls SURVIVE. Removing them would be the more
    useful function and would not be `CLEAN`."""
    var t = _text(args, 0)
    if t.is_error():
        return t^
    var bs = t.text.as_bytes()
    var out = List[UInt8]()
    for k in range(len(bs)):
        if bs[k] >= UInt8(32):
            out.append(bs[k])
    return FormulaValue.text_val(String(StringSlice(unsafe_from_utf8=Span(out))))


def xl_t(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`T(value)` — the value if it is TEXT, the empty string otherwise.

    ⛔ IT DOES NOT COERCE, AND THAT IS THE ENTIRE FUNCTION. `T(123)` is `""`,
    NOT `"123"` — a kernel built on `coerce_text` returns "123" and is wrong on
    every non-text input, which is the only kind of input anybody passes it.

    ⚠ AN ERROR PASSES THROUGH AS ITSELF, so `T` is registered `ERRH_MANUAL`."""
    if args[0].is_error():
        return args[0].copy()
    if args[0].is_text():
        return args[0].copy()
    return FormulaValue.text_val(String(""))


def xl_n(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`N(value)` — the numeric reading of a value, Excel's own table.

    ⛔ `N("7")` IS **0**, NOT 7 — and that is where it differs from
    `coerce_number`, which parses numeric text because Excel's ARITHMETIC
    context does (`"3"+2` is 5). `N` is not an arithmetic context: every TEXT
    value, numeric-looking or not, is 0. A kernel that forwarded to
    `coerce_number` gets the one input anybody tests wrong AND turns
    non-numeric text into `#VALUE!` where Excel says 0.

    NUMBER -> itself; TRUE -> 1; FALSE -> 0; BLANK -> 0; TEXT -> 0; an ERROR
    passes through, so this is `ERRH_MANUAL`."""
    if args[0].is_error():
        return args[0].copy()
    if args[0].is_number():
        return args[0].copy()
    if args[0].is_logical():
        return FormulaValue.number(1.0 if args[0].logical else 0.0)
    return FormulaValue.number(0.0)


# =============================================================================
# ★★ THE TEXT TRANCHE — CONCATENATE, and the UNICODE counterparts
#    of the CHAR / CODE pair above.
# =============================================================================

def xl_concatenate(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`CONCATENATE(text1, [text2], ...)` — the LEGACY spelling of `CONCAT`.

    ⚠ IT IS AN ALIAS ON THIS SURFACE AND THAT IS A MEASURED STATEMENT, NOT A
    SHRUG. In Excel the two differ in ONE way: `CONCAT` accepts a RANGE and
    `CONCATENATE` does not. The scalar door has no range value at all —
    `FormulaValue` carries number / text / logical / blank / error and nothing
    array-shaped — so the difference is not expressible here, and a separate
    kernel would be the same bytes under a second name. ⛔ IF AN ARRAY VALUE
    EVER LANDS IN `FormulaValue`, THIS ROW MUST STOP FORWARDING: `CONCATENATE`
    then has to REFUSE the range that `CONCAT` accepts.

    ⚠ THE DISCRIMINATING INPUTS ARE THE COERCING ONES, and they separate this
    from the two functions it gets confused with: `CONCATENATE(1, 2)` is the
    TEXT `"12"`, where an arithmetic kernel answers 3, and it inserts NO
    separator, where a `TEXTJOIN`-shaped kernel would.

    ⚠ ARITY IS 1..255. Excel requires `text1`; a zero-argument call is a
    different formula and is refused by the descriptor's window."""
    var out = String("")
    for i in range(len(args)):
        if args[i].is_error():
            return args[i].copy()
        var t = args[i].coerce_text()
        if t.is_error():
            return t^
        out += t.text
    return FormulaValue.text_val(out)


def _encode_utf8(cp: Int) -> List[UInt8]:
    """One Unicode scalar as UTF-8 bytes. Spelled out rather than taken from a
    helper because `xl_char` above already builds a `String` from a byte list
    the same way, and the two are the only places in this file that construct
    text from a code point."""
    var out = List[UInt8]()
    if cp < 0x80:
        out.append(UInt8(cp))
        return out^
    if cp < 0x800:
        out.append(UInt8(0xC0 | (cp >> 6)))
        out.append(UInt8(0x80 | (cp & 0x3F)))
        return out^
    if cp < 0x10000:
        out.append(UInt8(0xE0 | (cp >> 12)))
        out.append(UInt8(0x80 | ((cp >> 6) & 0x3F)))
        out.append(UInt8(0x80 | (cp & 0x3F)))
        return out^
    out.append(UInt8(0xF0 | (cp >> 18)))
    out.append(UInt8(0x80 | ((cp >> 12) & 0x3F)))
    out.append(UInt8(0x80 | ((cp >> 6) & 0x3F)))
    out.append(UInt8(0x80 | (cp & 0x3F)))
    return out^


def xl_unichar(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`UNICHAR(number)` — the character for a UNICODE code point.

    ⭐⭐ THIS IS THE FUNCTION `CHAR` COULD NOT BE, AND THE PAIR IS THE POINT.
    `xl_char` REFUSES everything above 127 (`#VALUE!`) because Excel's `CHAR`
    maps 128..255 through the machine's ANSI code page, which this engine has
    not got — so returning a Unicode scalar there would be a plausible WRONG
    glyph for 27 of those 128 codes. `UNICHAR` has no such problem: its
    argument IS a Unicode code point BY DEFINITION, on every platform, so the
    full range is answerable and nothing is being guessed.

    ⇒ `UNICHAR(8364)` is `"€"` and `CHAR(8364)` is `#VALUE!`. A `UNICHAR` row
    wired to the `CHAR` kernel answers `#VALUE!` there and passes any
    ASCII-only fixture, since `UNICHAR(65)` and `CHAR(65)` are both `"A"`.

    ⚠ THE REFUSALS ARE TWO DIFFERENT ERRORS AND EXCEL MEANS BOTH: zero (and,
    here, any negative) is `#VALUE!`; a value that is not a legal Unicode
    scalar — above U+10FFFF, or a lone SURROGATE in D800..DFFF — is `#N/A`.
    The surrogate case is the one a naive encoder gets wrong: it produces
    CESU-8 bytes that are not valid UTF-8 and that travel as a corrupt
    string."""
    var n = _num(args, 0)
    if n.is_error():
        return n^
    var cp = Int(n.num)
    if cp <= 0:
        return FormulaValue.error(XL_ERR_VALUE)
    if cp > 0x10FFFF:
        return FormulaValue.error(XL_ERR_NA)
    if cp >= 0xD800 and cp <= 0xDFFF:
        return FormulaValue.error(XL_ERR_NA)
    var bytes = _encode_utf8(cp)
    return FormulaValue.text_val(String(StringSlice(unsafe_from_utf8=Span(bytes))))


def xl_unicode(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`UNICODE(text)` — the Unicode code point of the FIRST character.

    ⛔⛔ ON THIS ENGINE THIS IS THE SAME NUMBER `CODE` RETURNS, AND SAYING SO IS
    THE WHOLE VALUE OF THE ROW. `xl_code`'s own docstring records the
    divergence: Excel's `CODE` returns an ANSI CODE-PAGE byte (0..255) and this
    engine's returns a code point, because it has no code page. So on a Western
    Windows box `CODE("€")` is 128 and `UNICODE("€")` is 8364, while HERE both
    are 8364 — `UNICODE` is right and `CODE` is the one that diverges.

    ⇒ THE PAIR IS DELIBERATELY NOT A DISCRIMINATING ONE HERE, and pretending
    otherwise would be the defect this effort exists to stop. What the row
    buys is the census: a caller asking `komira_xl_functions` for `UNICODE`
    now gets YES with this sentence attached, instead of nothing at all. The
    discriminating cell for this family is `UNICHAR(8364)` against
    `CHAR(8364)`, which really do differ.

    An EMPTY text is `#VALUE!`, which is Excel's answer."""
    var t = _text(args, 0)
    if t.is_error():
        return t^
    for cp in t.text.codepoints():
        return FormulaValue.number(Float64(Int(cp)))
    return FormulaValue.error(XL_ERR_VALUE)


# =============================================================================
# ★★ THE TEXT+LOOKUP TRANCHE — TEXTBEFORE / TEXTAFTER / VALUETOTEXT.
# =============================================================================
#
# ⚠ ALL THREE TAKE POSITIONS OR RENDER VALUES, so all three are written against
# the CHARACTER helpers above rather than against bytes. `TEXTBEFORE("naïve",
# "ï")` is `"na"`; a byte implementation of the same search happens to agree
# here (UTF-8 is self-synchronising, so a valid needle cannot match off a
# boundary) and then disagrees the moment an INDEX is reported, which is why
# the family is kept on one representation instead of two.
# =============================================================================
def _flag_arg(imm args: List[FormulaValue], i: Int) -> FormulaValue:
    """An optional 0/1 mode flag, default 0. Anything else is `#VALUE!` —
    Excel refuses rather than treating "not 1" as 0, and a clamp here would
    make `match_mode=2` silently case-sensitive."""
    if len(args) <= i:
        return FormulaValue.number(0.0)
    var v = _num(args, i)
    if v.is_error():
        return v^
    var n = Int(v.num)
    if Float64(n) != v.num or (n != 0 and n != 1):
        return FormulaValue.error(XL_ERR_VALUE)
    return FormulaValue.number(Float64(n))


def _text_ba(imm args: List[FormulaValue], before: Bool) raises -> FormulaValue:
    """The shared body of `TEXTBEFORE` and `TEXTAFTER`.

    `(text, delimiter, [instance_num=1], [match_mode=0], [match_end=0],
      [if_not_found])`

    ⭐ FOUR THINGS A PLAUSIBLE-BUT-WRONG KERNEL GETS WRONG, each with a cell:
      * `instance_num` NEGATIVE counts occurrences FROM THE END, so
        `TEXTBEFORE("a-b-c","-",-1)` is `"a-b"` and not `"a"`;
      * `match_mode = 1` is CASE-INSENSITIVE, so `TEXTBEFORE("aXbXc","x",1,1)`
        is `"a"` where the default refuses;
      * `match_end = 1` makes the END OF THE TEXT count as an occurrence, so
        `TEXTBEFORE("a-b","-",2,0,1)` is the whole `"a-b"`;
      * a delimiter that is not there is `#N/A` — NOT the empty string and NOT
        the whole text — unless `if_not_found` is supplied.

    ⚠ `instance_num = 0` IS `#VALUE!`. Excel has no zeroth occurrence, and a
    kernel that treated 0 as 1 answers a formula that should have refused.

    ⛔ AN EMPTY DELIMITER IS THIS ENGINE'S OWN CONTRACT AND IS NOT GRADED
    AGAINST EXCEL: it is treated as NOT FOUND, so the call takes the
    `if_not_found` path (`#N/A` by default). Excel's published description
    does not state a rule for it, and inventing one — "matches at the start",
    say — would return a confident empty string for a formula whose meaning is
    undefined. See `_textba_note`."""
    var t = _text(args, 0)
    if t.is_error():
        return t^
    var d = _text(args, 1)
    if d.is_error():
        return d^

    var inst = 1
    if len(args) > 2:
        var iv = _num(args, 2)
        if iv.is_error():
            return iv^
        inst = Int(iv.num)
        if inst == 0:
            return FormulaValue.error(XL_ERR_VALUE)
    var mode = _flag_arg(args, 3)
    if mode.is_error():
        return mode^
    var mend = _flag_arg(args, 4)
    if mend.is_error():
        return mend^

    var hc = xl_chars(t.text)
    var dc = xl_chars(d.text)
    var cmp_h = _lower_chars(hc) if mode.num == 1.0 else hc.copy()
    var cmp_d = _lower_chars(dc) if mode.num == 1.0 else dc.copy()

    # Every occurrence, left to right and NON-OVERLAPPING, as a (start, width)
    # pair. `match_end` appends the ZERO-WIDTH occurrence at the very end.
    var starts = List[Int]()
    var widths = List[Int]()
    if len(cmp_d) > 0:
        var i = 0
        while i + len(cmp_d) <= len(cmp_h):
            var at = _find_chars(cmp_h, cmp_d, i)
            if at < 0:
                break
            starts.append(at)
            widths.append(len(cmp_d))
            i = at + len(cmp_d)
    if mend.num == 1.0:
        starts.append(len(hc))
        widths.append(0)

    var pick = -1
    if inst > 0:
        if inst <= len(starts):
            pick = inst - 1
    else:
        if -inst <= len(starts):
            pick = len(starts) + inst
    if pick < 0:
        if len(args) > 5:
            if args[5].is_error():
                return args[5].copy()
            return args[5].copy()
        return FormulaValue.error(XL_ERR_NA)

    var at = starts[pick]
    if before:
        return FormulaValue.text_val(xl_substr_chars(t.text, 0, at))
    var after0 = at + widths[pick]
    return FormulaValue.text_val(
        xl_substr_chars(t.text, after0, len(hc) - after0)
    )


def xl_textbefore(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`TEXTBEFORE(text, delimiter, [instance], [match_mode], [match_end],
    [if_not_found])` — the text BEFORE the chosen occurrence. See `_text_ba`."""
    return _text_ba(args, True)


def xl_textafter(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`TEXTAFTER(text, delimiter, [instance], [match_mode], [match_end],
    [if_not_found])` — the text AFTER the chosen occurrence. See `_text_ba`.

    ⭐ THE PAIR IS THE DISCRIMINATOR FOR EITHER OF THEM. `TEXTBEFORE` and
    `TEXTAFTER` over the same input partition it around the delimiter, so a
    kernel wired to the wrong one of the two answers the OTHER HALF of the
    string — a well-formed result, never an error."""
    return _text_ba(args, False)


def xl_valuetotext(imm args: List[FormulaValue]) raises -> FormulaValue:
    """`VALUETOTEXT(value, [format])` — a value rendered as text.

    ⭐ `format` IS THE WHOLE FUNCTION AND IT IS NOT A COSMETIC FLAG:
      * `0` CONCISE (the default) is what a cell displays — `VALUETOTEXT("a")`
        is `a`;
      * `1` STRICT quotes TEXT and leaves everything else alone —
        `VALUETOTEXT("a",1)` is `"a"` WITH the quote characters, and
        `VALUETOTEXT(1.5,1)` is still `1.5`.
    A kernel that forwarded to `coerce_text` for both answers `a` twice and
    passes every concise cell.

    ⚠ AN INTERNAL QUOTE IS DOUBLED in strict form, which is the rule that
    makes the output re-readable: `VALUETOTEXT("a""b",1)` round-trips.

    ⚠ A `format` OTHER THAN 0 OR 1 IS `#VALUE!`, not a fallback to concise.
    ."""
    var fmt = _flag_arg(args, 1)
    if fmt.is_error():
        return fmt^
    if fmt.num == 0.0:
        var c = args[0].coerce_text()
        if c.is_error():
            return c^
        return c^
    if not args[0].is_text():
        var c2 = args[0].coerce_text()
        if c2.is_error():
            return c2^
        return c2^
    var out = String('"')
    var cs = xl_chars(args[0].text)
    for i in range(len(cs)):
        out += cs[i]
        if cs[i] == String('"'):
            out += String('"')
    out += String('"')
    return FormulaValue.text_val(out^)
