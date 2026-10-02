# =============================================================================
# komira_encoding/pem.mojo -- PEM armor (RFC 7468): DER <-> textual encoding.
# =============================================================================
#
# A PEM block is base64 between two encapsulation boundaries that carry the
# same label:
#
#   -----BEGIN PRIVATE KEY-----
#   MIIEvQIBADANBgkqhkiG9w0BAQEFAASC...
#   -----END PRIVATE KEY-----
#
# This module removes and adds the armor and nothing else: it does not parse
# the DER inside, so a key reaches no parser before the one that must read it.
#
# PARSING RULES (what `pem_decode` and `pem_label` accept). Boundaries are
# line-oriented; the body follows RFC 7468 section 3 `laxtextualmsg`:
#
#   - Lines end in LF; a CR before it is ignored, so CRLF files work.
#   - Text before the first BEGIN line is ignored (RFC 7468 section 2), and so
#     is anything on the lines after the END line. Only the FIRST block is
#     read: a block of another label is refused, never skipped.
#   - A boundary stands on a line of its own, with optional spaces and tabs
#     around it: `-----BEGIN <label>-----` and `-----END <label>-----`. A
#     line whose first non-blank bytes are `-----` but that is not a
#     well-formed boundary is an error, not explanatory text.
#   - The label must match RFC 7468 section 3 `label` (printable ASCII, single
#     hyphens or spaces between label characters, none at the ends), the END
#     label must equal the BEGIN label (RFC 7468 section 2 lets a parser
#     ignore the END label; this one does not), and `pem_decode` requires the
#     label it was given.
#   - In the body, every RFC 7468 `W` byte (space, HT, LF, VT, FF, CR) is
#     ignored wherever it appears, as `laxbase64text` allows. Every other byte
#     must be base64: the remainder goes to the strict decoder of this package
#     (padding required, zero unused bits). RFC 7468 section 2 says a parser
#     SHOULD also ignore other non-base64 characters; this one does not, so a
#     legacy RFC 1421 header (`Proc-Type: 4,ENCRYPTED`) is an error.
#   - The body must not be empty: no DER value encodes to zero bytes.
#
# ERRORS name a kind (errors.mojo), the function and a byte position in the
# PEM input, and carry no input byte, not even the label found: the input is
# often a private key. A caller that needs the label asks `pem_label`.
#
# TIMING. The base64 symbols reach only the constant-time decoder, and the
# whitespace is removed without a branch on the byte. The armor scan does
# branch on line feeds and on boundary characters at the start of a line,
# so the line structure of the input (64-symbol lines in any generated
# file) is not hidden.
# =============================================================================

from .base64 import base64_encode
from .codec import SCHEME_BASE64, decode
from .constant_time import ct_eq, ct_in_range
from .errors import (
    INVALID_BOUNDARY,
    INVALID_LENGTH,
    LABEL_MISMATCH,
    encoding_error,
)


comptime PEM_LABEL_CERTIFICATE: StaticString = "CERTIFICATE"
"""RFC 7468 section 5: an X.509 certificate."""

comptime PEM_LABEL_PRIVATE_KEY: StaticString = "PRIVATE KEY"
"""RFC 7468 section 10: an unencrypted PKCS#8 PrivateKeyInfo (RFC 5208)."""

comptime PEM_LABEL_ENCRYPTED_PRIVATE_KEY: StaticString = "ENCRYPTED PRIVATE KEY"
"""RFC 7468 section 11: a PKCS#8 EncryptedPrivateKeyInfo."""

comptime PEM_LABEL_PUBLIC_KEY: StaticString = "PUBLIC KEY"
"""RFC 7468 section 13: a SubjectPublicKeyInfo."""

comptime PEM_LINE_SYMBOLS = 64
"""Base64 symbols per body line that `pem_encode` writes (RFC 7468 section 2:
generators MUST wrap at 64 characters)."""

comptime _BEGIN: StaticString = "-----BEGIN "
comptime _END: StaticString = "-----END "
comptime _DASHES: StaticString = "-----"
comptime _LF = UInt8(0x0A)
comptime _CR = UInt8(0x0D)
comptime _SP = UInt8(0x20)
comptime _HT = UInt8(0x09)
comptime _HYPHEN = UInt8(0x2D)


@fieldwise_init
struct _Line(Copyable, Movable):
    """One line of the input: `start` and `next` (the byte after its LF, or
    the input length), and the bounds of its content without the leading
    and trailing spaces, tabs and CR."""

    var start: Int
    var next: Int
    var lo: Int
    var hi: Int


@fieldwise_init
struct _Block(Copyable, Movable):
    """Where the first block's parts are, as byte offsets into the input."""

    var label_lo: Int
    var label_hi: Int
    var body_lo: Int
    var body_hi: Int


def _line_at(b: Span[UInt8, _], start: Int) -> _Line:
    var n = len(b)
    var e = start
    while e < n and b[e] != _LF:
        e += 1
    var nxt = e + 1 if e < n else n
    var lo = start
    while lo < e and (b[lo] == _SP or b[lo] == _HT):
        lo += 1
    var hi = e
    while hi > lo and (b[hi - 1] == _SP or b[hi - 1] == _HT or b[hi - 1] == _CR):
        hi -= 1
    return _Line(start, nxt, lo, hi)


def _has_at(b: Span[UInt8, _], at: Int, end: Int, s: StaticString) -> Bool:
    var p = s.as_bytes()
    if end - at < len(p):
        return False
    for i in range(len(p)):
        if b[at + i] != p[i]:
            return False
    return True


def _is_label_char(c: UInt8) -> Bool:
    """RFC 7468 `labelchar`: %x21-2C / %x2E-7E (printable, not `-`)."""
    return c >= UInt8(0x21) and c <= UInt8(0x7E) and c != _HYPHEN


def _valid_label(b: Span[UInt8, _], lo: Int, hi: Int) -> Bool:
    """RFC 7468 `label = [ labelchar *( ["-" / SP] labelchar ) ]`."""
    if lo == hi:
        return True
    if not _is_label_char(b[lo]) or not _is_label_char(b[hi - 1]):
        return False
    for i in range(lo + 1, hi - 1):
        var c = b[i]
        if c == _HYPHEN or c == _SP:
            if not _is_label_char(b[i + 1]):
                return False
        elif not _is_label_char(c):
            return False
    return True


def _boundary_label(
    b: Span[UInt8, _], line: _Line, prefix: StaticString, function: StaticString
) raises -> Tuple[Int, Int]:
    """The label bounds of the boundary `line`, which starts with `prefix`."""
    var lo = line.lo + len(prefix.as_bytes())
    var hi = line.hi - len(_DASHES.as_bytes())
    if hi < lo or not _has_at(b, hi, line.hi, _DASHES) or not _valid_label(
        b, lo, hi
    ):
        raise encoding_error(
            INVALID_BOUNDARY,
            function,
            "malformed encapsulation boundary",
            line.lo,
        )
    return (lo, hi)


def _find_block(b: Span[UInt8, _], function: StaticString) raises -> _Block:
    """The first block of `b`, its boundaries checked and its END label
    matched against its BEGIN label."""
    var n = len(b)
    var pos = 0
    while True:
        if pos >= n:
            raise encoding_error(
                INVALID_BOUNDARY, function, "no BEGIN line", n
            )
        var line = _line_at(b, pos)
        pos = line.next
        if _has_at(b, line.lo, line.hi, _BEGIN):
            var lab = _boundary_label(b, line, _BEGIN, function)
            var body_lo = pos
            while True:
                if pos >= n:
                    raise encoding_error(
                        INVALID_BOUNDARY, function, "block has no END line", n
                    )
                var inner = _line_at(b, pos)
                if _has_at(b, inner.lo, inner.hi, _DASHES):
                    if not _has_at(b, inner.lo, inner.hi, _END):
                        raise encoding_error(
                            INVALID_BOUNDARY,
                            function,
                            "block has no END line",
                            inner.lo,
                        )
                    var end = _boundary_label(b, inner, _END, function)
                    var same = (end[1] - end[0]) == (lab[1] - lab[0])
                    if same:
                        for i in range(lab[1] - lab[0]):
                            if b[lab[0] + i] != b[end[0] + i]:
                                same = False
                                break
                    if not same:
                        raise encoding_error(
                            INVALID_BOUNDARY,
                            function,
                            "END label differs from BEGIN label",
                            inner.lo,
                        )
                    return _Block(lab[0], lab[1], body_lo, inner.start)
                pos = inner.next
        elif _has_at(b, line.lo, line.hi, _DASHES) and _has_at(
            b, line.lo, line.hi, _END
        ):
            raise encoding_error(
                INVALID_BOUNDARY, function, "END line before any BEGIN", line.lo
            )


def _position_of(msg: String) -> Int:
    """The position at the end of a komira_encoding error message."""
    var key = String(" at position ")
    var at = msg.rfind(key)
    if at < 0:
        return -1
    try:
        return atol(String(msg[byte=at + key.byte_length() :]))
    except:
        return -1


def _decode_body(
    b: Span[UInt8, _], lo: Int, hi: Int, function: StaticString
) raises -> List[UInt8]:
    """Strict base64 of `b[lo:hi]` with every RFC 7468 `W` byte removed.
    A decode error is re-raised with its position in `b`."""
    var n = hi - lo
    # Compaction without a branch on the byte: every byte is written, and the
    # write index advances by one only for a byte that is kept. `at[k]` is
    # where the k-th kept byte came from, for error positions.
    var body = List[UInt8](length=n + 1, fill=0)
    var at = List[Int](length=n + 1, fill=hi)
    var k = 0
    for i in range(lo, hi):
        var x = UInt32(b[i])
        var w = ct_in_range(x, 0x09, 0x0D) | ct_eq(x, 0x20)
        body[k] = b[i]
        at[k] = i
        k += Int(1 - (w & 1))
    at[k] = hi
    if k == 0:
        raise encoding_error(
            INVALID_LENGTH, function, "block body is empty", hi
        )
    try:
        return decode(SCHEME_BASE64, Span(body)[:k], True, False, function)
    except e:
        var msg = String(e)
        var p = _position_of(msg)
        if p < 0 or p > k:
            raise e^
        var key = String(" at position ")
        var head = String(msg[byte=: msg.rfind(key)])
        raise Error(head + key + String(at[p]))


def pem_label(pem: Span[UInt8, _]) raises -> String:
    """The label of the first PEM block in `pem` (`PRIVATE KEY` for
    `-----BEGIN PRIVATE KEY-----`), once its BEGIN and END lines are found
    well-formed and matching. The body is not decoded.

    Raises `InvalidBoundary` if there is no such block."""
    var b = _find_block(pem, "pem_label")
    var out = List[UInt8](capacity=b.label_hi - b.label_lo)
    for i in range(b.label_lo, b.label_hi):
        out.append(pem[i])
    # SAFETY of the conversion: a valid label is printable ASCII.
    return String(unsafe_from_utf8=Span(out))


def pem_label(pem: String) raises -> String:
    """`pem_label` over the bytes of `pem`."""
    return pem_label(pem.as_bytes())


def pem_decode(pem: Span[UInt8, _], label: String) raises -> List[UInt8]:
    """The DER bytes of the first PEM block in `pem`, which must be labelled
    `label`. A block of another label is refused, not skipped: a file whose
    first block is a CERTIFICATE is refused when a PRIVATE KEY is asked for.

    Raises `InvalidBoundary` (no BEGIN line, a malformed boundary, no END
    line, an END label that differs), `LabelMismatch` (the block's label is
    not `label`), `InvalidLength` (an empty body), or a base64 error of this
    package, each with a position in `pem`. No message carries an input
    byte."""
    var b = _find_block(pem, "pem_decode")
    var want = label.as_bytes()
    var same = (b.label_hi - b.label_lo) == len(want)
    if same:
        for i in range(len(want)):
            if pem[b.label_lo + i] != want[i]:
                same = False
                break
    if not same:
        raise encoding_error(
            LABEL_MISMATCH,
            "pem_decode",
            "block label is not the one asked for",
            b.label_lo,
        )
    return _decode_body(pem, b.body_lo, b.body_hi, "pem_decode")


def pem_decode(pem: String, label: String) raises -> List[UInt8]:
    """`pem_decode` over the bytes of `pem`."""
    return pem_decode(pem.as_bytes(), label)


def pem_encode(label: String, der: Span[UInt8, _]) raises -> String:
    """The PEM block of `der` under `label`: the BEGIN line, the base64 body
    in lines of `PEM_LINE_SYMBOLS` symbols, the END line, each ending in LF
    (RFC 7468 section 2 generator rules). `pem_decode(pem_encode(l, d), l)`
    is `d`.

    Raises `InvalidBoundary` if `label` is not an RFC 7468 label, and
    `InvalidLength` if `der` is empty (`pem_decode` refuses an empty body)."""
    var lb = label.as_bytes()
    if not _valid_label(lb, 0, len(lb)):
        raise encoding_error(
            INVALID_BOUNDARY, "pem_encode", "label is not an RFC 7468 label", 0
        )
    if len(der) == 0:
        raise encoding_error(INVALID_LENGTH, "pem_encode", "der is empty", 0)
    var body = base64_encode(der)
    var sym = body.as_bytes()
    var out = String(_BEGIN) + label + String(_DASHES) + "\n"
    var i = 0
    while i < len(sym):
        var j = min(i + PEM_LINE_SYMBOLS, len(sym))
        out += String(StringSlice(unsafe_from_utf8=sym[i:j])) + "\n"
        i = j
    out += String(_END) + label + String(_DASHES) + "\n"
    return out^
