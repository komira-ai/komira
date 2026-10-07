# =============================================================================
# kci_logs/json_scan.mojo — the BOUNDED JSON scanner both cloud arms
#   parse their log responses with.
# =============================================================================
#
# ⛔ WHY A SHARED FILE RATHER THAN A COPY PER ARM. `run_log_tail.mojo` carries
# its own module-private copy of this loop, because the run-log half depends on
# nothing in the cloud half. A copy per cloud arm would be one too many: two
# arms deriving the same scan is how the two
# drift, and the drift is invisible because each arm's test only exercises its
# own copy. Both arms import from here.
#
# ⛔ AND THE SKIP IS WHAT MAKES EVERY ALLOW-LIST HOLD. `_skip_value` is not a
# convenience — without a correct skip an unknown key's VALUE gets re-scanned as
# if it were the next KEY, and a parser that is trying to emit three fields
# starts emitting structure it never meant to read. Every allow-listed parse in
# this package is only as sound as this function.
#
# ⛔ IT ACCUMULATES **BYTES**, NEVER `chr(Int(byte))`. `chr` maps a CODEPOINT to
# UTF-8, so each raw byte of a multi-byte character comes back out as its own
# two-byte character and the text is mojibake before any renderer sees it. That
# defect is written up on the sibling in `run_log_tail.mojo`; it is re-stated
# here because these payloads are ARBITRARY CONTAINER STDOUT and so are far more
# likely to be non-ASCII than a pipeline emitter's own lines. A `\uXXXX` is
# passed through as its literal bytes, unchanged — the conservative choice for a
# diagnostic renderer, not a validator.
#
# ⛔ AND THE VALUE IS REPAIRED TO WELL-FORMED UTF-8 BEFORE IT BECOMES A
# `String`. `json_scan_string` takes caller bytes, and a `String` holding
# ill-formed UTF-8 breaks the invariant every `String` operation relies on.
# This package never raises (an enrichment on a failure path), so an
# ill-formed sequence is REPLACED, not refused: each maximal ill-formed
# subpart becomes one U+FFFD (the Unicode Standard's recommended practice,
# §3.9 "U+FFFD Substitution of Maximal Subparts"), and the rest of the value
# survives for the operator to read.
#
# PURE. No transport, no raise, no allocation beyond the scanned value.
# def-based, Mojo 1.0.0b2.
# =============================================================================


def json_is_space(c: UInt8) -> Bool:
    return (
        c == UInt8(ord(" "))
        or c == UInt8(ord("\t"))
        or c == UInt8(ord("\n"))
        or c == UInt8(ord("\r"))
    )


def json_skip_space(b: Span[UInt8, _], i: Int) -> Int:
    var j = i
    while j < len(b) and json_is_space(b[j]):
        j += 1
    return j


def _utf8_valid_len(b: Span[UInt8, _], i: Int) -> Int:
    """Length of the well-formed UTF-8 sequence at `b[i]`, or MINUS the length
    of the maximal ill-formed subpart there (always at least one byte).

    Well-formed is RFC 3629 / Unicode Table 3-7: no stray continuation byte,
    no overlong form, no UTF-16 surrogate, nothing above U+10FFFF, no
    truncated sequence."""
    var c = b[i]
    if c < UInt8(0x80):
        return 1
    if c < UInt8(0xC2) or c > UInt8(0xF4):
        return -1
    var need: Int
    var lo = UInt8(0x80)
    var hi = UInt8(0xBF)
    if c < UInt8(0xE0):
        need = 1
    elif c < UInt8(0xF0):
        need = 2
        if c == UInt8(0xE0):
            lo = UInt8(0xA0)
        elif c == UInt8(0xED):
            hi = UInt8(0x9F)
    else:
        need = 3
        if c == UInt8(0xF0):
            lo = UInt8(0x90)
        elif c == UInt8(0xF4):
            hi = UInt8(0x8F)
    for k in range(1, need + 1):
        if i + k >= len(b):
            return -k
        var ck = b[i + k]
        var klo = lo if k == 1 else UInt8(0x80)
        var khi = hi if k == 1 else UInt8(0xBF)
        if ck < klo or ck > khi:
            return -k
    return need + 1


def _utf8_repaired(var buf: List[UInt8]) -> String:
    """`buf` as a `String`, with each maximal ill-formed UTF-8 subpart
    replaced by one U+FFFD (`EF BF BD`). Well-formed input (the common case)
    is checked in one pass and converted without a second copy."""
    var n = len(buf)
    var i = 0
    while i < n:
        if buf[i] < UInt8(0x80):
            i += 1
            continue
        var r = _utf8_valid_len(Span(buf), i)
        if r < 0:
            break
        i += r
    if i == n:
        return String(unsafe_from_utf8=Span(buf))
    var fixed = List[UInt8](capacity=n + 2)
    for k in range(i):
        fixed.append(buf[k])
    while i < n:
        var r = _utf8_valid_len(Span(buf), i)
        if r > 0:
            for k in range(i, i + r):
                fixed.append(buf[k])
            i += r
        else:
            fixed.append(UInt8(0xEF))
            fixed.append(UInt8(0xBF))
            fixed.append(UInt8(0xBD))
            i -= r
    return String(unsafe_from_utf8=Span(fixed))


def json_scan_string(b: Span[UInt8, _], i: Int, mut out: String) -> Int:
    """Read a JSON string starting AT its opening quote, writing the UNESCAPED
    value into `out`. Returns the index after the closing quote, or -1 when
    unterminated.

    ⛔ IT ACCUMULATES **BYTES**, NEVER `chr(Int(byte))`. `chr` maps a CODEPOINT to
    UTF-8, so each raw byte of a multi-byte character would come back out as its
    own two-byte character and the text would be mojibake before any renderer saw
    it. That defect is written up on this scanner's sibling in `run_log_tail.mojo`
    and is re-stated here because this is a SECOND copy of the same loop, on a
    path whose payloads are far more likely to be non-ASCII (arbitrary container
    stdout). A `\\uXXXX` is passed through as its literal bytes, unchanged — the
    conservative choice for a diagnostic renderer.

    ⛔ THE VALUE IS WELL-FORMED UTF-8 WHATEVER `b` HOLDS: each maximal
    ill-formed subpart becomes one U+FFFD (module header). Each escape arm
    appends ASCII or the raw byte that followed the backslash (which may be
    ill-formed, e.g. 0xFF); the repair runs once over the whole accumulated
    buffer, so whatever an escape appends is repaired in sequence with the
    bytes around it."""
    out = String()
    if i >= len(b) or b[i] != UInt8(ord('"')):
        return -1
    var buf = List[UInt8]()
    var j = i + 1
    while j < len(b):
        var c = b[j]
        if c == UInt8(ord('"')):
            out = _utf8_repaired(buf^)
            return j + 1
        if c == UInt8(ord("\\")):
            if j + 1 >= len(b):
                return -1
            var e = b[j + 1]
            if e == UInt8(ord("n")):
                buf.append(UInt8(0x0A))
            elif e == UInt8(ord("r")):
                buf.append(UInt8(0x0D))
            elif e == UInt8(ord("t")):
                buf.append(UInt8(0x09))
            else:
                buf.append(e)
            j += 2
            continue
        buf.append(c)
        j += 1
    return -1


def json_scan_number(b: Span[UInt8, _], i: Int, mut out: Int) -> Int:
    """Read a bare JSON integer at `i` into `out`. Returns the index just after
    it, or -1 when there is no digit there.

    Fractions and exponents are NOT decoded — a `.` simply ends the integer part
    and the caller's `json_skip_value` is what would handle the remainder. Every
    number either arm reads is an integer by the provider's own schema
    (CloudWatch epoch-millis), so a float here means the body is not the shape
    this parser was told it is, and truncating is the conservative answer for a
    diagnostic renderer."""
    out = 0
    var j = i
    var neg = False
    if j < len(b) and b[j] == UInt8(ord("-")):
        neg = True
        j += 1
    var start = j
    var v = 0
    while j < len(b) and b[j] >= UInt8(ord("0")) and b[j] <= UInt8(ord("9")):
        v = v * 10 + Int(b[j] - UInt8(ord("0")))
        j += 1
    if j == start:
        return -1
    out = -v if neg else v
    return j


def json_skip_value(b: Span[UInt8, _], i: Int) -> Int:
    """Skip ONE JSON value at `i` — the NOT-allow-listed branch. Returns the
    index after it, or -1 if it cannot be skipped. Nested objects/arrays are
    skipped by depth, tracking string state so a brace inside a string does not
    count. ⛔ This function is what makes the allow-list hold: without a correct
    skip, an unknown key's value would be re-scanned as if it were the next key
    and the parser would leak structure it never intended to read."""
    var j = json_skip_space(b, i)
    if j >= len(b):
        return -1
    var c = b[j]
    if c == UInt8(ord('"')):
        var scratch = String()
        return json_scan_string(b, j, scratch)
    if c == UInt8(ord("{")) or c == UInt8(ord("[")):
        var depth = 0
        while j < len(b):
            var d = b[j]
            if d == UInt8(ord('"')):
                var scratch2 = String()
                var nx = json_scan_string(b, j, scratch2)
                if nx < 0:
                    return -1
                j = nx
                continue
            if d == UInt8(ord("{")) or d == UInt8(ord("[")):
                depth += 1
            elif d == UInt8(ord("}")) or d == UInt8(ord("]")):
                depth -= 1
                if depth == 0:
                    return j + 1
            j += 1
        return -1
    while j < len(b):
        var d = b[j]
        if (
            d == UInt8(ord(","))
            or d == UInt8(ord("}"))
            or d == UInt8(ord("]"))
            or json_is_space(d)
        ):
            return j
        j += 1
    return j
