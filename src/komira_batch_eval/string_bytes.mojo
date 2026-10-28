# =============================================================================
# string_bytes: byte-level string transforms and string-column access
# =============================================================================
#
# Hex, binary and URL encodings, SQL `substring`, find and replace, padding,
# repetition, `translate` and `strpos` over UTF-8 bytes, plus the helpers that
# view a column as a `StringArray` (sharing a column reference's bytes where it
# can) and read the arguments of the n-ary string functions.
# =============================================================================

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import RecordBatch
from komira_arrow.string_array import StringArray
from komira_buffer.heap_region import HeapRegion
from komira_column_kernels.cast_null import eval_cast
from komira_column_kernels.compiler_helpers import (
    expr_resolves_to_column,
    project_column_share_eligible,
    resolve_col_index,
)
from komira_plan_expr.expr import Expr, string_fn_n_name

from .eval_column import _eval_column_expr
from .eval_dict import _materialize_dict_to_string


# ---------------------------------------------------------------------------
# the five BYTE-TRANSFORM string kernels.
# ---------------------------------------------------------------------------
#
# ⭐ ALL FIVE ARE EXACT AGAINST DuckDB v1.5.3 OVER EVERY INPUT, ASCII OR NOT,
# and that is WHY these five were chosen over the rest of the string bucket.
# They operate on the UTF-8 BYTES themselves, which is exactly what DuckDB's
# own implementations do — so there is no mapping to be missing. MEASURED:
#     hex('é')          = 'C3A9'          (the two UTF-8 bytes)
#     bin('é')          = '1100001110101001'
#     url_encode('é')   = '%C3%A9'
#     regexp_escape('é.b') = 'é\.b'       (bytes >= 0x80 are NOT escaped)
#
# ⚠ THE SELECTION ARGUMENT THAT PICKED THESE FIVE HAS SINCE BEEN SETTLED THE
# OTHER WAY, and the note is kept because it is how the string bucket is
# ordered. These were chosen ahead of `upper`/`lower` because those two
# "carry a stated Unicode divergence"; that divergence was a SILENT WRONG
# ANSWER (`upper('Ünïcodé')` = `'ÜNïCODé'`) and was closed by
# `unicode_case.mojo`, which decodes and applies DuckDB's own simple case
# mapping. `reverse` is still codepoint-defined and byte-exact here.
#
# ⚠ EVERY ONE RETURNS `List[UInt8]`, NEVER A `String`, for the reason written
# in `unicode_case.mojo`: `chr(Int(byte))` is a CODEPOINT constructor and
# doubles every byte >= 0x80. These pair with `StringArray.from_byte_lists`.


@always_inline
def _hex_digit_upper(v: Int) -> UInt8:
    """One UPPERCASE hex digit. MEASURED: DuckDB's `hex` emits `C3A9`, not
    `c3a9`, while `md5`/`sha256` emit LOWERCASE — two conventions in one
    engine, so this is not a shared helper by accident."""
    if v < 10:
        return UInt8(48 + v)      # '0'
    return UInt8(65 + (v - 10))   # 'A'


@always_inline
def _hex_digit_value(c: UInt8) -> Int:
    """The value of one hex digit, or -1. BOTH CASES ACCEPTED — measured:
    `url_decode('%c3%a9')` = 'é' in v1.5.3, so a decoder that took only
    uppercase would leave a lowercase escape as literal text."""
    if c >= 48 and c <= 57:
        return Int(c) - 48
    if c >= 97 and c <= 102:
        return Int(c) - 97 + 10
    if c >= 65 and c <= 70:
        return Int(c) - 65 + 10
    return -1


def _hex_string_bytes(s: String) -> List[UInt8]:
    """`hex(s)` / `to_hex(s)` — two UPPERCASE hex digits per UTF-8 byte.

    MEASURED v1.5.3: `hex('abc')` = '616263', `hex('')` = '', `hex('é')` =
    'C3A9', `hex('😀')` = 'F09F9880'. `to_hex` over a VARCHAR is the SAME
    function (both '616263' for 'abc'), which is why they share this op.

    ⛔ `to_hex` OVER AN INTEGER IS A DIFFERENT FUNCTION and this op is NOT it:
    `to_hex(255)` is 'FF' there, while `hex('255')` is '323535'. This engine
    binds only the VARCHAR overload; an integer argument reaches the arm's
    STRING-column check and is refused BY NAME."""
    var b = s.as_bytes()
    var n = len(b)
    var out = List[UInt8](capacity=2 * n)
    for i in range(n):
        var v = Int(b[i])
        out.append(_hex_digit_upper((v >> 4) & 0xF))
        out.append(_hex_digit_upper(v & 0xF))
    return out^


def _bin_string_bytes(s: String) -> List[UInt8]:
    """`bin(s)` — EIGHT binary digits per UTF-8 byte, no separator and NO
    leading-zero strip.

    MEASURED v1.5.3: `bin('abc')` = '011000010110001001100011' (24 digits for
    3 bytes — the leading zero of 'a' = 0x61 is KEPT), `bin('')` = '',
    `bin('é')` = '1100001110101001'.

    ⛔ `bin` OVER AN INTEGER **DOES** STRIP LEADING ZEROS (`bin(5)` = '101')
    and is a different overload this engine does not bind. A kernel that
    stripped here would be right for the integer form and wrong for every
    string."""
    var b = s.as_bytes()
    var n = len(b)
    var out = List[UInt8](capacity=8 * n)
    for i in range(n):
        var v = Int(b[i])
        for k in range(7, -1, -1):
            out.append(UInt8(48 + ((v >> k) & 1)))
    return out^


@always_inline
def _url_unreserved(c: UInt8) -> Bool:
    """RFC 3986 unreserved: A-Z a-z 0-9 `-` `.` `_` `~`.

    ⚠ THE SET IS MEASURED, NOT QUOTED FROM THE RFC. Enumerating every printable
    ASCII byte through v1.5.3's `url_encode` and keeping the ones that came back
    unchanged gives EXACTLY `-.0-9A-Z_a-z~`. In particular `+` is ENCODED
    (`url_encode('a+b')` = 'a%2Bb'), which the form-encoding convention would
    not do."""
    return (
        (c >= 65 and c <= 90)     # A-Z
        or (c >= 97 and c <= 122)  # a-z
        or (c >= 48 and c <= 57)   # 0-9
        or c == 45                 # -
        or c == 46                 # .
        or c == 95                 # _
        or c == 126                # ~
    )


def _url_encode_bytes(s: String) -> List[UInt8]:
    """`url_encode(s)` — percent-encode every byte outside the unreserved set,
    with UPPERCASE hex digits.

    MEASURED v1.5.3: `url_encode('a b/c?d=é')` = 'a%20b%2Fc%3Fd%3D%C3%A9' —
    a space is `%20` and NOT `+`, and a non-ASCII character is encoded as its
    UTF-8 BYTES one `%XX` each, which is why this is a byte kernel."""
    var b = s.as_bytes()
    var n = len(b)
    var out = List[UInt8](capacity=n)
    for i in range(n):
        var c = b[i]
        if _url_unreserved(c):
            out.append(c)
        else:
            out.append(37)  # '%'
            out.append(_hex_digit_upper((Int(c) >> 4) & 0xF))
            out.append(_hex_digit_upper(Int(c) & 0xF))
    return out^


def _bytes_are_valid_utf8(b: List[UInt8]) -> Bool:
    """Strict UTF-8 validation: shortest form, no surrogates, max U+10FFFF.

    ⚠ LOCAL RATHER THAN IMPORTED ON PURPOSE. Four `_is_valid_utf8` helpers
    exist in this repo (`komira_git`, `komira_ivp`, `komira_aws_lambda_http`)
    and every one of them lives in a package `komira_batch_eval` does not and
    should not depend on. Twenty-five lines here is cheaper than an edge from
    the expression evaluator to an HTTP package."""
    var n = len(b)
    var i = 0
    while i < n:
        var c = Int(b[i])
        if c < 0x80:
            i += 1
            continue
        var need: Int
        var cp: Int
        if c >= 0xC2 and c <= 0xDF:
            need = 1
            cp = c & 0x1F
        elif c >= 0xE0 and c <= 0xEF:
            need = 2
            cp = c & 0x0F
        elif c >= 0xF0 and c <= 0xF4:
            need = 3
            cp = c & 0x07
        else:
            # 0x80-0xC1 (continuation or overlong two-byte lead) and 0xF5-0xFF.
            return False
        if i + need > n - 1:
            return False
        for k in range(1, need + 1):
            var cc = Int(b[i + k])
            if cc < 0x80 or cc > 0xBF:
                return False
            cp = (cp << 6) | (cc & 0x3F)
        if need == 2 and cp < 0x800:
            return False
        if need == 3 and cp < 0x10000:
            return False
        if cp > 0x10FFFF:
            return False
        if cp >= 0xD800 and cp <= 0xDFFF:
            return False
        i += need + 1
    return True


def _url_decode_bytes(s: String) raises -> List[UInt8]:
    """`url_decode(s)` — decode `%XX` escapes, leave everything else verbatim.

    ⛔ THREE MEASURED FACTS THAT ARE EACH THE OPPOSITE OF THE OBVIOUS GUESS,
    v1.5.3:
      * `+` IS NOT A SPACE. `url_decode('a+b')` = 'a+b'. This is URI decoding,
        not `application/x-www-form-urlencoded` decoding, and a decoder that
        mapped `+` would be wrong on every query string that carries one.
      * A MALFORMED ESCAPE IS LEFT ALONE, NOT AN ERROR. `url_decode('a%zz')` =
        'a%zz', `url_decode('a%2')` = 'a%2', `url_decode('100%')` = '100%'.
      * AN ESCAPE THAT DECODES TO INVALID UTF-8 **RAISES**:
        `url_decode('%FF')` is `Invalid Input Error: ... decoded value is
        invalid UTF8`. That is why this helper is `raises` and why
        `_bytes_are_valid_utf8` exists — emitting the bytes anyway would put an
        invalid-UTF-8 value into a STRING column, which every downstream reader
        (Arrow C-ABI export included) is entitled to reject."""
    var b = s.as_bytes()
    var n = len(b)
    var out = List[UInt8](capacity=n)
    var i = 0
    while i < n:
        if b[i] == 37 and i + 2 < n:  # '%' with two bytes after it
            var hi = _hex_digit_value(b[i + 1])
            var lo = _hex_digit_value(b[i + 2])
            if hi >= 0 and lo >= 0:
                out.append(UInt8((hi << 4) | lo))
                i += 3
                continue
        out.append(b[i])
        i += 1
    if not _bytes_are_valid_utf8(out):
        raise Error(
            "url_decode: decoded value is invalid UTF8 (DuckDB v1.5.3 raises"
            " here too: `Invalid Input Error: Failed to decode string using"
            " URL decoding - decoded value is invalid UTF8`)"
        )
    return out^


def _reverse_codepoints_bytes(s: String) -> List[UInt8]:
    """`reverse(s)` — reverse CODEPOINT order, keeping each codepoint's own
    bytes in their original order.

    ⛔ NOT A BYTE REVERSE. Measured on DuckDB v1.5.3: `reverse('héllo')` is
    `olléh` — the two bytes of `é` stay in sequence. A byte-wise reverse would
    emit the continuation byte first and turn a valid input into INVALID
    UTF-8, which is worse than a wrong answer because the consumer cannot
    decode it at all.

    Walks the input finding codepoint STARTS (any byte outside 0x80..0xBF),
    then copies whole codepoints back-to-front. Exact against DuckDB.
    """
    var b = s.as_bytes()
    var n = len(b)
    # Codepoint start offsets, in order.
    var starts = List[Int]()
    for i in range(n):
        if (b[i] & 0xC0) != 0x80:
            starts.append(i)
    var out = List[UInt8](capacity=n)
    for k in range(len(starts) - 1, -1, -1):
        var begin = starts[k]
        var end = starts[k + 1] if k + 1 < len(starts) else n
        for j in range(begin, end):
            out.append(b[j])
    return out^


def _sql_substring_bytes(s: String, start: Int, length: Int) -> List[UInt8]:
    """SQL `substring(s, start, length)` — 1-based `start`, `length`
    CHARACTERS, returning the selected bytes VERBATIM.

    ⛔ THIS REPLACED A KERNEL WITH THREE SEPARATE WRONG ANSWERS, ALL OF THEM
    SILENT, ALL MEASURED AGAINST DuckDB v1.5.3. Do not "simplify" any of the
    three back:

    1. **A NEGATIVE `start` COUNTS FROM THE END OF THE STRING**, it is not
       "counted against `length`". The old kernel's own docstring claimed the
       PostgreSQL rule and claimed it MATCHED DuckDB; it does not.
       `substring('hello', -1)` is `o` in DuckDB and was `hello` here;
       `substring('hello', -1, 4)` is `o` there and was `he` here. The rule is
       `begin0 = nchars + start` for `start < 0` and `begin0 = start - 1`
       otherwise — which keeps `start == 0` on the "counted against length"
       branch, where DuckDB does put it (`substring('hello',0,2)` = `h`,
       `substring('hello',0)` = `hello`). Two rules in one function, and the
       boundary between them is at 0, not at 1.

    2. **INDICES ARE CHARACTERS, NOT BYTES.** `substring('héllo', 2, 2)` is
       `él` in DuckDB; byte indexing answers `é` alone (the two bytes of one
       codepoint). Every fixture in the TPC-H corpus is single-byte, which is
       why this survived — and `Straße` is in the plan-matrix text zoo, which
       is where it stops surviving.

    3. **`chr(Int(byte))` IS A CODEPOINT CONSTRUCTOR AND THE OLD LOOP USED
       IT.** `out += chr(Int(b[j]))` re-encodes every byte >= 0x80 as its own
       two-byte UTF-8 sequence, so slicing non-ASCII text did not merely
       mis-index it, it CORRUPTED and lengthened it. Returning `List[UInt8]`
       and pairing with `StringArray.from_byte_lists` is the byte-faithful
       companion — the same pairing the `EXPR_STRING_FN` arm already uses and
       documents.

    ⚠ `length < 0` IS AN INTERNAL SENTINEL **FAMILY** AND IS **NOT** DuckDB'S
    NEGATIVE-LENGTH SEMANTICS. `-1` means "to end of string"; `-k` for k >= 2
    means "to end, dropping k-1 trailing CHARACTERS", which is what
    `left(s, NEGATIVE)` desugars to (see the `end0` branch below for the
    arithmetic and the reason). DuckDB reads a negative length as a window
    extending BACKWARD from `start` (`substring('hello',3,-1)` = `e`), which is
    a DIFFERENT function of the same field. The SQL binder REFUSES a negative
    length literal by name, so no user spelling reaches this branch; a binder
    that ever stops refusing must supply the backward-window rule first, under
    a spelling that is not this one.
    """
    var b = s.as_bytes()
    var nbytes = len(b)

    # Codepoint START offsets, plus a sentinel at `nbytes` so the exclusive
    # end of the LAST character is addressable without a special case. A
    # continuation byte is `0b10xxxxxx` (0x80..0xBF); anything else starts a
    # character. Same test as `_utf8_char_count`, so the two cannot disagree
    # about how many characters a string has.
    var starts = List[Int](capacity=nbytes + 1)
    for i in range(nbytes):
        if (b[i] & 0xC0) != 0x80:
            starts.append(i)
    var nchars = len(starts)
    starts.append(nbytes)

    var begin0: Int
    if start >= 0:
        begin0 = start - 1
    else:
        begin0 = nchars + start
    var end0: Int
    if length < 0:
        # ⛔ THE NEGATIVE-`length` SENTINEL IS A **FAMILY**, NOT A SINGLE
        # VALUE, AND THE ARITHMETIC IS EXACT AT EVERY MEMBER.
        #
        #     length == -1  ->  end0 = nchars          "to end of string"
        #     length == -2  ->  end0 = nchars - 1      "to end, drop 1 char"
        #     length == -k  ->  end0 = nchars - (k-1)
        #
        # `nchars + length + 1` is one expression covering all of them, and at
        # `length == -1` it is `nchars` — BYTE-IDENTICAL to what this line did
        # before, so no existing two-argument `substring(s, start)` moves.
        #
        # ⭐ WHY THE FAMILY EXISTS: `left(s, -n)`. DuckDB
        # v1.5.3's `left('abc', -1)` is `'ab'` — "all but the LAST |n|
        # characters" — which is `substring(s, 1, nchars - n)`, a RUNTIME
        # length the plan-time `length` field cannot carry as a positive
        # number. It can carry the SHORTFALL, and `nchars` is right here. That
        # is the missing primitive the old binder refusal named, supplied at
        # the one place that knows `nchars`. `right(s, -n)` never needed it —
        # "all but the first |n|" is `substring(s, 1 - n)`, a constant START —
        # which is exactly why the pair was asymmetric.
        #
        # ⛔⛔ THIS IS STILL **NOT** DuckDB'S NEGATIVE-LENGTH SEMANTICS, AND THE
        # SQL BINDER MUST KEEP REFUSING A NEGATIVE `length` LITERAL. DuckDB
        # reads `substring('hello',3,-1)` as a window extending BACKWARD from
        # `start` and answers `'e'`; this encoding would answer `'he'`. The
        # only producers of `length < -1` are the `left(s, NEGATIVE)` desugar
        # in `sql_binder._bind_left_right` and a plan decoded off the wire that
        # one built. A binder that ever stops refusing the literal must supply
        # the backward-window rule FIRST — and must then give it a spelling
        # that is not this one.
        end0 = nchars + length + 1
    else:
        end0 = begin0 + length
    var from_c = begin0 if begin0 > 0 else 0
    if end0 > nchars:
        end0 = nchars
    if from_c > nchars:
        from_c = nchars
    var out = List[UInt8]()
    if end0 <= from_c:
        return out^
    var b0 = starts[from_c]
    var b1 = starts[end0]
    for j in range(b0, b1):
        out.append(b[j])
    return out^


# =============================================================================
# the MULTI-ARGUMENT string kernels
# =============================================================================
#
# ⛔ EVERY KERNEL HERE RETURNS `List[UInt8]`, NOT `String`, AND THE CALLER
# PAIRS IT WITH `StringArray.from_byte_lists`. `chr(Int(byte))` is a CODEPOINT
# constructor: a byte >= 0x80 comes back as its two-byte UTF-8 ENCODING, so
# every non-ASCII value is silently corrupted AND doubled in length.
# `StringArray.from_strings` routes through `String` and inherits it. That trap
# has bitten TWICE in this file — `upper` and `substring`, the second one
# with the `upper` kernel's warning about it ONE
# SCREEN UP. It does not get a third. (That warning now lives in
# `unicode_case.mojo`, where the `upper`/`lower` kernels moved .)
#
# ⚠ AND THE ORACLE HALF OF THE SAME TRAP: do NOT validate any of these against
# a Python `str` method. Python, this engine and DuckDB give three different
# answers on `Straße`, and the Python one stays green over an ASCII fixture
# while being wrong. The corpus cells use the non-ASCII fixture variant.


def _find_bytes(hay: Span[UInt8, _], needle: Span[UInt8, _], from_byte: Int) -> Int:
    """Byte offset of the first occurrence of `needle` in `hay` at or after
    `from_byte`, or `-1`.

    ⭐ BYTE-WISE SEARCH IS EXACT OVER UTF-8, and that is a property of the
    encoding rather than an approximation: every byte of a multi-byte sequence
    is >= 0x80 and every continuation byte is 0x80..0xBF, so a WELL-FORMED
    needle cannot match starting inside a codepoint. No decode is needed, and
    a decode would be slower and no more correct.

    An EMPTY needle answers `from_byte` — "found, at the current position" —
    which is what makes `strpos(s,'')` = 1. Callers that would loop on that
    (`replace`) must special-case an empty needle BEFORE calling.
    """
    var hn = len(hay)
    var nn = len(needle)
    if nn == 0:
        return from_byte if from_byte <= hn else hn
    if nn > hn:
        return -1
    var last = hn - nn
    for i in range(from_byte, last + 1):
        var ok = True
        for j in range(nn):
            if hay[i + j] != needle[j]:
                ok = False
                break
        if ok:
            return i
    return -1


def _replace_bytes(s: String, source: String, target: String) -> List[UInt8]:
    """`replace(s, source, target)` — DuckDB v1.5.3 semantics, measured.

    ⚠ NON-OVERLAPPING, LEFT TO RIGHT: the scan resumes AFTER the bytes a match
    consumed. `replace('aaa','aa','b')` = `'ba'`, which is neither `'b'` nor
    `'bb'` — the two answers a greedy or a restart-at-i+1 loop produce.

    ⚠ AN EMPTY `source` MATCHES NOTHING and the input comes back unchanged
    (`replace('abc','','X')` = `'abc'`). Without this guard `_find_bytes`
    answers "found here" at every position and the loop either never advances
    or emits `'XaXbXcX'`.

    Byte-wise, which is EXACT rather than approximate — see `_find_bytes`.
    Measured: `replace('Straße','ß','ss')` = `'Strasse'`.
    """
    var b = s.as_bytes()
    var src = source.as_bytes()
    var tgt = target.as_bytes()
    var out = List[UInt8]()
    if len(src) == 0:
        for i in range(len(b)):
            out.append(b[i])
        return out^
    var i = 0
    var n = len(b)
    while i < n:
        var hit = _find_bytes(b, src, i)
        if hit < 0:
            break
        for j in range(i, hit):
            out.append(b[j])
        for j in range(len(tgt)):
            out.append(tgt[j])
        i = hit + len(src)
    for j in range(i, n):
        out.append(b[j])
    return out^


def _utf8_char_starts(b: Span[UInt8, _]) -> List[Int]:
    """Byte offsets of every codepoint START in `b`, plus a `len(b)` sentinel.

    The sentinel makes the exclusive end of the LAST character addressable
    with no special case, exactly as `_sql_substring_bytes` does it — and it
    uses the SAME continuation-byte test (`(byte & 0xC0) != 0x80`) as
    `_utf8_char_count`, so the two can never disagree about how many
    characters a string has.
    """
    var n = len(b)
    var starts = List[Int](capacity=n + 1)
    for i in range(n):
        if (b[i] & 0xC0) != 0x80:
            starts.append(i)
    starts.append(n)
    return starts^


def _pad_bytes(
    s: String, count: Int, pad: String, on_left: Bool
) raises -> List[UInt8]:
    """`lpad` / `rpad` — DuckDB v1.5.3 semantics, all four corners measured.

    ⛔ CHARACTERS, NOT BYTES, ON BOTH SIDES. `lpad('é',4,'ß')` = `'ßßßé'`: four
    CHARACTERS out of a 2-byte input and a 2-byte pad. A byte-wise version
    returns a different string and can split a codepoint, turning valid input
    into invalid UTF-8.

    ⚠ IT TRUNCATES. `count` below the input's length is not a no-op — it takes
    the FIRST `count` characters, for BOTH `lpad` and `rpad`
    (`rpad('abc',2,'x')` = `'ab'`, NOT `'bc'`). `count <= 0` gives `''`.

    ⛔⛔ AND THE CONDITIONAL RAISE, WHICH IS THE PART THAT IS WRONG IN BOTH
    DIRECTIONS IF GUESSED. An empty `pad` RAISES — DuckDB says `Invalid Input
    Error: Insufficient padding in LPAD.` — but ONLY when padding is actually
    needed. Measured:
        lpad('abc',4,'')  RAISES     lpad('abc',3,'')  = 'abc'
        lpad('abc',2,'')  = 'ab'     lpad('',0,'')     = ''
    So the guard is `count > nchars and pad is empty`, never `pad is empty`
    alone (which would refuse three working calls) and never nothing at all
    (which would return the input unpadded, silently disagreeing).

    The pad CYCLES from its own first character: `lpad('abc',6,'xy')` =
    `'xyxabc'` — x, y, x.
    """
    var b = s.as_bytes()
    var starts = _utf8_char_starts(b)
    var nchars = len(starts) - 1

    if count <= 0:
        return List[UInt8]()

    if count <= nchars:
        # TRUNCATION — the first `count` characters, both directions.
        var cut = List[UInt8](capacity=starts[count])
        for j in range(starts[count]):
            cut.append(b[j])
        return cut^

    var pb = pad.as_bytes()
    if len(pb) == 0:
        raise Error(
            "Invalid Input Error: Insufficient padding in "
            + (String("LPAD") if on_left else String("RPAD"))
            + "."
        )
    var pstarts = _utf8_char_starts(pb)
    var pchars = len(pstarts) - 1

    var need = count - nchars
    var fill = List[UInt8]()
    for k in range(need):
        var c = k % pchars
        for j in range(pstarts[c], pstarts[c + 1]):
            fill.append(pb[j])

    var out = List[UInt8](capacity=len(fill) + len(b))
    if on_left:
        for j in range(len(fill)):
            out.append(fill[j])
        for j in range(len(b)):
            out.append(b[j])
    else:
        for j in range(len(b)):
            out.append(b[j])
        for j in range(len(fill)):
            out.append(fill[j])
    return out^


def _repeat_bytes(s: String, count: Int, max_bytes: Int) raises -> List[UInt8]:
    """`repeat(s, count)` — `count <= 0` gives `''` (measured at 0 and -1).

    ⚠ THE ONE MEMBER WHOSE OUTPUT SIZE IS SET BY A DATA VALUE. DuckDB types
    `count` as BIGINT, so `repeat('ab', 2147483647)` is a legal call asking for
    4 GB, and this runs inside a morsel worker where an OOM takes the PROCESS
    and a raise takes one query. The ceiling is checked BEFORE any allocation
    and is a REFUSAL, not a clamp — a clamp returns a string that differs from
    DuckDB with nothing saying so.
    """
    if count <= 0:
        return List[UInt8]()
    var b = s.as_bytes()
    var unit = len(b)
    if unit == 0:
        return List[UInt8]()
    if count > max_bytes // unit:
        raise Error(
            "PipelineCompiler: repeat() would produce "
            + String(count * unit)
            + " bytes for one row, over the "
            + String(max_bytes)
            + "-byte per-row ceiling (STRING_FN_N_REPEAT_MAX_BYTES)"
        )
    var out = List[UInt8](capacity=unit * count)
    for _ in range(count):
        for j in range(unit):
            out.append(b[j])
    return out^


def _codepoint_starts(b: Span[UInt8, _]) -> List[Int]:
    """Byte offsets at which each CODEPOINT of `b` begins, in order.

    A UTF-8 continuation byte is `10xxxxxx`, so a codepoint STARTS at any byte
    whose top two bits are not `10` — the same test `_reverse_codepoints_bytes`
    uses. Shared by the character-based members of the string families."""
    var starts = List[Int]()
    for i in range(len(b)):
        if (b[i] & 0xC0) != 0x80:
            starts.append(i)
    return starts^


def _translate_chars(
    subject: String, from_set: String, to_set: String
) -> List[UInt8]:
    """`translate(s, from, to)` — per-CHARACTER substitution.

    ⛔⛔ CHARACTERS, NOT BYTES, AND THIS IS THE ONLY MEMBER OF ITS TAG THAT IS.
    `_levenshtein_bytes`, `_damerau_levenshtein_bytes` and `_hamming_bytes` are
    byte-based on the same `EXPR_STRING_FN_N`. MEASURED on DuckDB v1.5.3:
    `translate('héllo','é','e')` = 'hello'. A byte-wise kernel would match the
    lead byte C3 of `é` against nothing useful and could strand the trailing
    A9 — emitting INVALID UTF-8 into a STRING column, which the Arrow C-ABI
    export is entitled to reject. That is worse than a wrong answer.

    The four measured rules, each the opposite of a plausible guess:
      * a SHORTER `to` DELETES: `translate('abcd','abc','xy')` = 'xyd'
      * a LONGER `to` ignores the extra: `translate('abc','a','xyz')` = 'xbc'
      * a DUPLICATE in `from` takes the FIRST: `translate('abc','aa','xy')` =
        'xbc'
      * the pairing is per CODEPOINT on BOTH sides:
        `translate('Straße','ß','ss')` = 'Strase' — the two-character `to`
        contributes only its first character to the one-character `from`

    An empty `from` is the identity; an empty `to` deletes every matched
    character. Both measured."""
    var sb = subject.as_bytes()
    var fb = from_set.as_bytes()
    var tb = to_set.as_bytes()
    var f_starts = _codepoint_starts(fb)
    var t_starts = _codepoint_starts(tb)
    var s_starts = _codepoint_starts(sb)

    var out = List[UInt8](capacity=len(sb))
    for si in range(len(s_starts)):
        var s_begin = s_starts[si]
        var s_end = len(sb) if si + 1 == len(s_starts) else s_starts[si + 1]
        var s_len = s_end - s_begin

        # ⚠ FIRST match wins — that is the duplicate rule, not an optimization.
        var hit = -1
        for fi in range(len(f_starts)):
            var f_begin = f_starts[fi]
            var f_end = (
                len(fb) if fi + 1 == len(f_starts) else f_starts[fi + 1]
            )
            if f_end - f_begin != s_len:
                continue
            var same = True
            for k in range(s_len):
                if sb[s_begin + k] != fb[f_begin + k]:
                    same = False
                    break
            if same:
                hit = fi
                break

        if hit < 0:
            # Not in `from` — copy the whole codepoint through verbatim.
            for k in range(s_len):
                out.append(sb[s_begin + k])
            continue
        if hit >= len(t_starts):
            # ⛔ NO PARTNER IN `to` -> DELETE. Padding with a space or with the
            # last character of `to` are both plausible and both wrong.
            continue
        var t_begin = t_starts[hit]
        var t_end = (
            len(tb) if hit + 1 == len(t_starts) else t_starts[hit + 1]
        )
        for k in range(t_begin, t_end):
            out.append(tb[k])
    return out^


def _strpos_chars(hay: String, needle: String) -> Int:
    """`strpos(hay, needle)` — 1-BASED CHARACTER position, `0` if absent.

    ⛔ NOT AN INDEX AND NOT A BYTE OFFSET. Measured on DuckDB v1.5.3:
    `strpos('Straße','e')` = **6**, where the byte offset is 7 — so the search
    may be byte-wise (it is, and exactly so: see `_find_bytes`) but the RESULT
    must be converted to a character count.

    `strpos('abc','z')` = 0, `strpos('','a')` = 0, and an EMPTY needle is found
    at 1 even in an empty haystack (`strpos('','')` = 1) — which falls out of
    `_find_bytes` answering `from_byte` for an empty needle rather than being a
    special case here.
    """
    var b = hay.as_bytes()
    var nd = needle.as_bytes()
    var hit = _find_bytes(b, nd, 0)
    if hit < 0:
        return 0
    var chars = 0
    for i in range(hit):
        if (b[i] & 0xC0) != 0x80:
            chars += 1
    return chars + 1


def string_array_of(col: Column[HeapRegion]) raises -> StringArray[HeapRegion]:
    """`col.as_string`'s VALUES, without its copy when the column allows it.

    `Column.as_string` memcpy's the offsets, data and validity buffers into
    a fresh `StringArray`; `Column.share_as_string` Arc-shares them instead
    and reads byte-identically wherever `can_share_as_string` holds (plain
    STRING, offsets present, `_offset == 0` — the only case `as_string`
    accepts, since it refuses a sliced column). Anywhere else this IS
    `as_string`.

    WHY: on ClickBench `cbq27` every string predicate and string function
    copied the whole `url` column just to hand a read-only kernel something to
    walk — two of the five full `url` copies that dominated the query's CPU.

    ## THE ALIASING ARGUMENT (stated, because it is NOT `from_string_shared`'s)

    `from_string_shared` is sound because it CONSUMES its input: no second
    handle survives the call. This function borrows `col`, so the batch column
    and the returned array are two live handles on the same bytes. That is
    sound only if NO holder of the returned array can write through it, and
    `StringArray` having no `mut self` method is NOT enough on its own: its
    public `offsets` / `data` / `validity` fields are `SharedAlignedBuffer` /
    `Bitmap`, which DO have writers (`write_*_at`, `set_typed`, `zero`,
    `view_mut`, `Bitmap.set` / `clear`). The argument is therefore
    per-consumer, and every consumer is enumerated:

      * WHO HOLDS IT MUTABLY: only the caller's own `var`. Every caller in
        `eval_column` / `eval_predicate` does exactly one
        thing to it besides passing it on — `try_share_string_col_ref`
        REPLACES its own `validity` handle with `None` (drops a share; writes
        no byte).
      * WHO READS IT: the kernels it is passed to all take it by `read`
        (`eval_string_{eq,ne,gt,lt,ge,le,contains,starts_with,ends_with,like}`,
        `eval_regexp_*`, `cast_string_to_{int64,int32,float64,float32}`), or
        the caller reads it through `is_null` / `get` / `get_span` /
        `get_length`. Every buffer writer needs a MUTABLE borrow of the buffer
        (`mut self`, or `ref [origin] self` with `mut=True`), which a `read`
        borrow cannot supply, and `as_view` is origin-parametric, so a view
        taken through `read` is immutable. `StringArray` is not `Copyable`,
        and no consumer re-`share`s a field, so no consumer can mint a
        mutable handle either.
      * WHAT ESCAPES: nothing that aliases. Every kernel builds its output
        fresh (`from_strings` / builders / `Bitmap.create*`), and
        `_apply_validity` COPIES the input bitmap into a new one.
      * LIFETIME: Arc-managed, not scoped. The returned array holds its own
        refcount on every buffer (and the `_mmap_keepalive` cookie), so it is
        valid however long a caller keeps it; the batch column may drop first.
      * LENGTHS: the shared `data` buffer may be LONGER than `offsets[length]`
        where `as_string`'s copy is exactly that long. No consumer reads a
        buffer's own length: they bound by `data_length` (set identically by
        both paths) or by per-row offsets.

    A new call site must re-run this enumeration for ITS consumers. Anywhere
    that cannot be shown read-only keeps calling `as_string`.
    """
    if col.can_share_as_string():
        return col.share_as_string()
    return col.as_string()


def try_share_string_col_ref(
    child: Expr, batch: RecordBatch
) raises -> Optional[StringArray[HeapRegion]]:
    """A zero-copy `StringArray` over the batch column a string-valued CHILD
    names, or `None`, in which case the caller keeps its copying path.

    It stands in for `_eval_column_expr(child).as_string`, which for a column
    reference is `copy_column(...)` then `as_string`: TWO full copies of the
    column (cbq27's C-colref and C-strfn, 7.4% + 6.2% of its CPU).

    It answers only where that pair is provably equal to one Arc share:

      * `child` is a bare column reference (`expr_resolves_to_column`);
      * the column is plain STRING and `can_share_as_string` holds;
      * `project_column_share_eligible` holds (`_offset == 0`,
        `_length == batch.num_rows`, `offsets[0] == 0`), the gate under
        which `copy_column` is a straight copy, not a rebase or a truncation.

    ⚠ ONE NORMALISATION IS MIRRORED, NOT SKIPPED. `copy_column` DROPS an
    all-valid bitmap (`_null_count == 0`, its Path 2), and the string kernels
    branch on the PRESENCE of a bitmap (`EXPR_STRING_FN`'s INT arm allocates a
    nullable output when one is there). The share keeps the source's bitmap,
    so it is dropped here on the same `null_count == 0` test `copy_column`
    trusts. Without this the values would agree and the output's validity
    LAYOUT would not.

    A DICTIONARY child is not served here: `_materialize_dict_to_string`
    builds a fresh array either way, so there is no copy to remove.

    ALIASING: the result is a borrowed-column share and carries
    `string_array_of`'s obligation (see its enumerated argument). The callers
    — `_sfnn_string_arg`'s consumers and the SUBSTRING / STRING_FN arms — read
    it through `is_null` / `get` / `get_span` / `get_length` only.
    """
    if not expr_resolves_to_column(child):
        return None
    var ci = resolve_col_index(child, batch.schema)
    ref col = batch.column_at(ci)
    if col.arrow_type != ArrowType.STRING or not col.can_share_as_string():
        return None
    if not project_column_share_eligible(batch, ci):
        return None
    var sa = col.share_as_string()
    if sa.null_count == 0:
        sa.validity = None
    return sa^


def _sfnn_string_arg(
    expr: Expr, i: Int, batch: RecordBatch
) raises -> StringArray[HeapRegion]:
    """Evaluate argument `i` of an `EXPR_STRING_FN_N` node to a `StringArray`.

    The DICTIONARY -> STRING materialization is here rather than repeated at
    each of the four call sites, and it is the same
    `_materialize_dict_to_string` fallback the `EXPR_STRING_FN` arm uses — a
    dictionary-encoded column reaching a string kernel is the ordinary case
    for a low-cardinality parquet column, not an exception.

    ⚠ FORWARD-DECLARED AGAINST `_eval_column_expr`, WHICH IS DEFINED BELOW AND
    CALLS BACK INTO THIS. That mutual recursion is how a nested argument
    (`concat(upper(a), b)`) works at all; it is the same shape the CASE and
    predicate evaluators already have with this module.
    """
    var shared = try_share_string_col_ref(expr.string_fn_n_arg_ref(i), batch)
    if shared:
        return shared.take()
    var col = _eval_column_expr(expr.string_fn_n_arg_ref(i), batch)
    var at = col.arrow_type
    if at == ArrowType.DICTIONARY:
        return _materialize_dict_to_string(col)
    if at != ArrowType.STRING:
        raise Error(
            "PipelineCompiler: "
            + string_fn_n_name(expr.string_fn_n_op())
            + "() argument " + String(i + 1)
            + " must be a STRING or DICTIONARY column, got " + String(at)
        )
    return string_array_of(col)


def _sfnn_count_arg(
    expr: Expr, i: Int, op: UInt8, batch: RecordBatch
) raises -> PrimitiveArray[DType.int64]:
    """Evaluate argument `i` of an `EXPR_STRING_FN_N` node to an INT64 count.

    ⚠ INT32 IS WIDENED THROUGH `eval_cast`, WHICH IS VALIDITY-PRESERVING. A
    hand-written widen loop drops the null mask and the count then reads as
    whatever the dead bytes held — `clone_array_validity`'s docstring names
    that exact failure, and this file already carries four arms that had it.

    Anything that is not INT32/INT64 is REFUSED BY NAME. DuckDB would coerce a
    DECIMAL here; this engine does not, and a refusal is never a wrong value.
    """
    var col = _eval_column_expr(expr.string_fn_n_arg_ref(i), batch)
    var at = col.arrow_type
    if at == ArrowType.INT64:
        return col.as_primitive[DType.int64]()
    if at == ArrowType.INT32:
        return eval_cast[DType.int32, DType.int64](
            col.as_primitive[DType.int32]()
        )
    raise Error(
        "PipelineCompiler: "
        + string_fn_n_name(op)
        + "() argument " + String(i + 1)
        + " must be an INT32/INT64 count, got " + String(at)
    )
