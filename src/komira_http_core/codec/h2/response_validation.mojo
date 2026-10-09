"""RFC 9113 response-message validation — the rules a CLIENT must apply to a
decoded HTTP/2 response header block.

WHY THIS MODULE EXISTS. A client that walks the decoded response header list,
pulls `:status` by string compare, and appends everything else verbatim into
the per-stream caller-visible slot validates nothing, so every
rule RFC 9113 §8.1.1 makes a *stream error* is accepted and handed to the
caller — and two of them become SILENT WRONG ANSWERS rather than errors:

  * `:status: 0200` delivered as 200 and `:status: 2oo` as 2, from a
    digit loop that breaks on the first non-digit and keeps the partial value;
  * a TRAILER block re-entering the same `:status` branch REWRITES the status
    of a response whose body was already delivered — a 500 becomes a 200.

⛔ THIS FILE IS PURE, AND DELIBERATELY SO. It decides nothing about frames,
streams, flow control or refusal *scope*; it answers one question — "is this
decoded block a well-formed response head / trailer section, and if not, which
rule did it break" — over data the caller already owns. The refusal itself
(RST_STREAM, the per-stream marker, whether extraction is still allowed) is the
client driver's business, which is what keeps this testable without a
connection.

★ THE REASON IS A CODE, NOT A STRING, because it is stored on
`H2ClientStream`, which is POD/Copyable by construction. A String field
there would force a conn-level slab + free-list for a value only ever read once,
at the raise site. `h2_malformed_reason_text` renders it there.

Spec index — every rule below names the clause it encodes:
  §8.1.1   a malformed response is a stream error of type PROTOCOL_ERROR
  §8.1     trailers MUST NOT include pseudo-header fields
  §8.2.1   field names are lowercase tokens; values carry no NUL/LF/CR
  §8.2.2   connection-specific fields are forbidden; `te` only as "trailers"
  §8.3     pseudo-headers come first, appear once, and must be defined
  §8.3.2   `:status` is exactly three ASCII DIGITs, and it is REQUIRED
  RFC 9110 §15     a status code is in 100..599
  RFC 9110 §8.6    content-length is 1*DIGIT
  RFC 9110 §15.2   a 1xx is a separate, interim message
"""

from komira_http_core.codec.h2.hpack import HpackHeader


# =============================================================================
# §1 — Reason codes. 0 is the only "well-formed" value.
# =============================================================================

comptime H2_MALFORMED_OK: UInt16 = 0
comptime H2_MALFORMED_NO_STATUS: UInt16 = 1
comptime H2_MALFORMED_BAD_STATUS: UInt16 = 2
comptime H2_MALFORMED_UNDEFINED_PSEUDO: UInt16 = 3
comptime H2_MALFORMED_PSEUDO_AFTER_REGULAR: UInt16 = 4
comptime H2_MALFORMED_DUPLICATE_PSEUDO: UInt16 = 5
comptime H2_MALFORMED_BAD_FIELD_NAME: UInt16 = 6
comptime H2_MALFORMED_BAD_FIELD_VALUE: UInt16 = 7
comptime H2_MALFORMED_CONNECTION_SPECIFIC: UInt16 = 8
comptime H2_MALFORMED_BAD_TE: UInt16 = 9
comptime H2_MALFORMED_BAD_CONTENT_LENGTH: UInt16 = 10
comptime H2_MALFORMED_CONFLICTING_CONTENT_LENGTH: UInt16 = 11
comptime H2_MALFORMED_CONTENT_LENGTH_MISMATCH: UInt16 = 12
comptime H2_MALFORMED_DATA_BEFORE_HEAD: UInt16 = 13
comptime H2_MALFORMED_PSEUDO_IN_TRAILER: UInt16 = 14
comptime H2_MALFORMED_TRAILER_NOT_END_STREAM: UInt16 = 15


def h2_malformed_reason_text(code: UInt16) -> String:
    """Render a reason code for an error message. Every arm names the clause
    it encodes so a production raise is diagnosable without this file."""
    if code == H2_MALFORMED_NO_STATUS:
        return String(
            "no :status pseudo-header (RFC 9113 §8.3.2 — a response MUST"
            " carry exactly one)"
        )
    if code == H2_MALFORMED_BAD_STATUS:
        return String(
            ":status is not exactly three ASCII digits (RFC 9113 §8.3.2)"
            " or not in 100..599 (RFC 9110 §15)"
        )
    if code == H2_MALFORMED_UNDEFINED_PSEUDO:
        return String(
            "an undefined or request-only pseudo-header in a response"
            " (RFC 9113 §8.3 — a response defines only :status)"
        )
    if code == H2_MALFORMED_PSEUDO_AFTER_REGULAR:
        return String(
            "a pseudo-header after a regular field (RFC 9113 §8.3 — all"
            " pseudo-header fields MUST appear before all regular fields)"
        )
    if code == H2_MALFORMED_DUPLICATE_PSEUDO:
        return String(
            "a repeated pseudo-header (RFC 9113 §8.3 — it MUST NOT appear"
            " more than once)"
        )
    if code == H2_MALFORMED_BAD_FIELD_NAME:
        return String(
            "a field name that is empty, uppercase, or carries a"
            " non-token octet (RFC 9113 §8.2.1)"
        )
    if code == H2_MALFORMED_BAD_FIELD_VALUE:
        return String(
            "a field value carrying NUL, LF or CR (RFC 9113 §8.2.1 — the"
            " h2->h1 response-splitting gadget)"
        )
    if code == H2_MALFORMED_CONNECTION_SPECIFIC:
        return String(
            "a connection-specific field (RFC 9113 §8.2.2 — connection,"
            " keep-alive, proxy-connection, transfer-encoding, upgrade)"
        )
    if code == H2_MALFORMED_BAD_TE:
        return String(
            "a 'te' field whose value is not exactly \"trailers\""
            " (RFC 9113 §8.2.2 — the one carve-out, and it is exact)"
        )
    if code == H2_MALFORMED_BAD_CONTENT_LENGTH:
        return String(
            "a content-length that is not 1*DIGIT (RFC 9110 §8.6 — a sign,"
            " a space or an empty value is not a digit)"
        )
    if code == H2_MALFORMED_CONFLICTING_CONTENT_LENGTH:
        return String(
            "two content-length fields carrying different values"
            " (RFC 9110 §8.6)"
        )
    if code == H2_MALFORMED_CONTENT_LENGTH_MISMATCH:
        return String(
            "content-length does not equal the sum of the DATA frame"
            " payload lengths (RFC 9113 §8.1.1)"
        )
    if code == H2_MALFORMED_DATA_BEFORE_HEAD:
        return String(
            "DATA on a stream that has not carried a final response head"
            " (RFC 9113 §8.1 — there is no message for it to belong to)"
        )
    if code == H2_MALFORMED_PSEUDO_IN_TRAILER:
        return String(
            "a pseudo-header in a trailer section (RFC 9113 §8.1 —"
            " trailers MUST NOT include pseudo-header fields)"
        )
    if code == H2_MALFORMED_TRAILER_NOT_END_STREAM:
        return String(
            "a trailer section that does not end the stream (RFC 9113 §8.1"
            " — the trailer section is the last thing on a stream)"
        )
    return String("an unclassified malformed-response condition")


# =============================================================================
# §2 — The verdict. POD: no String, no allocation, safe to keep on a POD stream.
# =============================================================================


struct H2BlockVerdict(Copyable, ImplicitlyCopyable, Movable, Deinitable):
    """The result of validating ONE decoded header block.

    Fields:
      reason_code    — `H2_MALFORMED_OK` (0) iff the block is well-formed.
      status         — the parsed `:status`, or -1 for a block that carries
                       none (a trailer section, or a malformed head).
      content_length — the declared content-length, or -1 if absent.
    """

    var reason_code: UInt16
    var status: Int
    var content_length: Int64

    def __init__(out self):
        self.reason_code = H2_MALFORMED_OK
        self.status = -1
        self.content_length = Int64(-1)

    def __init__(
        out self, reason_code: UInt16, status: Int, content_length: Int64,
    ):
        self.reason_code = reason_code
        self.status = status
        self.content_length = content_length

    def is_malformed(self) -> Bool:
        return self.reason_code != H2_MALFORMED_OK


def _verdict_malformed(code: UInt16) -> H2BlockVerdict:
    return H2BlockVerdict(reason_code=code, status=-1, content_length=Int64(-1))


# =============================================================================
# §3 — Octet-level predicates (RFC 9110 §5.6.2 / RFC 9113 §8.2.1).
# =============================================================================


def h2_is_lowercase_tchar(c: Int) -> Bool:
    """RFC 9110 §5.6.2 `tchar`, MINUS uppercase ALPHA.

    RFC 9113 §8.2.1: "field names MUST be converted to lowercase when
    constructing an HTTP/2 message" and a message carrying an uppercase name
    "MUST be treated as malformed" — so on the h2 wire the token alphabet is
    the h1 one with A-Z removed, not the h1 one compared case-insensitively.
    """
    if c >= Int(ord("a")) and c <= Int(ord("z")):
        return True
    if c >= Int(ord("0")) and c <= Int(ord("9")):
        return True
    # The punctuation half of `tchar`: "!#$%&'*+-.^_`|~"
    return (
        c == Int(ord("!"))
        or c == Int(ord("#"))
        or c == Int(ord("$"))
        or c == Int(ord("%"))
        or c == Int(ord("&"))
        or c == Int(ord("'"))
        or c == Int(ord("*"))
        or c == Int(ord("+"))
        or c == Int(ord("-"))
        or c == Int(ord("."))
        or c == Int(ord("^"))
        or c == Int(ord("_"))
        or c == Int(ord("`"))
        or c == Int(ord("|"))
        or c == Int(ord("~"))
    )


def h2_field_name_is_valid(ref name: String) -> Bool:
    """RFC 9113 §8.2.1 — a REGULAR field name is a non-empty lowercase token.

    Rejects the empty name, any uppercase letter, SP, any control octet, and
    ':' anywhere (a leading ':' is a pseudo-header and is classified by the
    caller before this is reached; a ':' elsewhere is simply not a token
    octet).
    """
    var b = name.as_bytes()
    var n = len(b)
    if n == 0:
        return False
    var i = 0
    while i < n:
        if not h2_is_lowercase_tchar(Int(b[i])):
            return False
        i = i + 1
    return True


def h2_field_value_is_valid(ref value: String) -> Bool:
    """RFC 9113 §8.2.1 — "A field value MUST NOT contain the zero value
    (ASCII NUL, 0x00), line feed (ASCII LF, 0x0a), or carriage return
    (ASCII CR, 0x0d)."

    ⚠ SCOPE, STATED ON PURPOSE. §8.2.1 also forbids a value that STARTS or
    ENDS with SP/HTAB. That clause is NOT enforced here: it is the one rule in
    this file whose violation is common in the wild from otherwise-benign
    origins (an h1->h2 translator that forgets to strip OWS), it carries none
    of the response-splitting danger the three octets above carry, and
    refusing it would convert working traffic into a stream error. Add it only
    with a test that says what it is protecting.
    """
    var b = value.as_bytes()
    var n = len(b)
    var i = 0
    while i < n:
        var c = Int(b[i])
        if c == 0 or c == 0x0A or c == 0x0D:
            return False
        i = i + 1
    return True


def h2_is_pseudo_name(ref name: String) -> Bool:
    """True iff the field name's FIRST octet is ':' — the wire definition of
    a pseudo-header (RFC 9113 §8.3)."""
    var b = name.as_bytes()
    if len(b) == 0:
        return False
    return Int(b[0]) == Int(ord(":"))


def h2_te_value_is_trailers(ref value: String) -> Bool:
    """RFC 9113 §8.2.2's ONE carve-out: `te` MAY appear, and then "MUST NOT
    contain any value other than \"trailers\"".

    ⚠ COMPARED CASE-INSENSITIVELY, AND THAT IS NOT LAXITY. "trailers" is a
    t-codings token (RFC 9110 §10.1.4) and HTTP tokens are case-insensitive,
    so `TE: Trailers` is the same field as `te: trailers`. An exact byte
    compare here would refuse a legal response — turning a conformance rule
    into an outage — and it is what Go's `http2` and hyper both avoid by
    folding case at exactly this comparison.
    """
    var b = value.as_bytes()
    var n = len(b)
    if n != 8:
        return False
    var want = String("trailers").as_bytes()
    var i = 0
    while i < n:
        var c = Int(b[i])
        if c >= Int(ord("A")) and c <= Int(ord("Z")):
            c = c + 32
        if c != Int(want[i]):
            return False
        i = i + 1
    return True


def h2_is_connection_specific_field(ref name: String) -> Bool:
    """RFC 9113 §8.2.2's list, verbatim. `te` is NOT here: it is the one
    field that MAY appear, and only with the value "trailers", so it is a
    value check rather than a name ban."""
    return (
        name == String("connection")
        or name == String("keep-alive")
        or name == String("proxy-connection")
        or name == String("transfer-encoding")
        or name == String("upgrade")
    )


# =============================================================================
# §4 — Value parsers.
# =============================================================================


def h2_status_code_of(ref value: String) -> Int:
    """RFC 9113 §8.3.2 — `:status` is exactly 3 DIGIT, and RFC 9110 §15
    defines status codes in 100..599. Returns -1 for anything else (000..099
    and 600..999 included).

    ⛔ THE -1 IS THE WHOLE POINT. The loop this replaces broke on the first
    non-digit and KEPT the partial accumulator, so "2oo" became 2 and "0200"
    became 200 — a plausible-looking number the caller could not tell from a
    real one.
    """
    var b = value.as_bytes()
    if len(b) != 3:
        return -1
    var v = 0
    var i = 0
    while i < 3:
        var c = Int(b[i])
        if c < Int(ord("0")) or c > Int(ord("9")):
            return -1
        v = v * 10 + (c - Int(ord("0")))
        i = i + 1
    if v < 100 or v > 599:
        return -1
    return v


def h2_content_length_of(ref value: String) -> Int64:
    """RFC 9110 §8.6 — content-length is 1*DIGIT. Returns -1 for an empty
    value, a sign, embedded space, or a run long enough to overflow Int64
    (18 digits is the widest that cannot)."""
    var b = value.as_bytes()
    var n = len(b)
    if n == 0 or n > 18:
        return Int64(-1)
    var v = Int64(0)
    var i = 0
    while i < n:
        var c = Int(b[i])
        if c < Int(ord("0")) or c > Int(ord("9")):
            return Int64(-1)
        v = v * Int64(10) + Int64(c - Int(ord("0")))
        i = i + 1
    return v


def h2_status_has_no_content(status: Int, request_was_head: Bool) -> Bool:
    """RFC 9113 §8.1.1's carve-out from the content-length check, which it
    delegates to RFC 9110 §6.4.1: a 1xx, a 204, a 304, or the response to a
    HEAD request "is defined as having no content" and MAY carry a non-zero
    content-length with zero DATA frames.

    ⚠ WITHOUT THE `request_was_head` ARM EVERY HEAD RESPONSE BECOMES A STREAM
    ERROR — a HEAD reply states the content-length the GET would have had and
    sends no body, which is precisely the shape the mismatch rule refuses.
    """
    if request_was_head:
        return True
    if status >= 100 and status <= 199:
        return True
    return status == 204 or status == 304


def h2_status_is_informational(status: Int) -> Bool:
    """RFC 9110 §15.2 — a 1xx is an INTERIM response: a separate message that
    is followed by the final one on the same stream. Its fields are not the
    final response's fields."""
    return status >= 100 and status <= 199


# =============================================================================
# §5 — Block validators.
# =============================================================================


def h2_validate_response_head(
    ref headers: List[HpackHeader],
) -> H2BlockVerdict:
    """Validate a decoded RESPONSE HEAD block (the first, or an interim 1xx).

    Returns a verdict whose `status` and `content_length` the caller applies
    ONLY when `is_malformed()` is False.
    """
    var seen_regular = False
    var seen_status = False
    var status = -1
    var content_length = Int64(-1)
    var n = len(headers)
    var i = 0
    while i < n:
        ref name = headers[i].name
        ref value = headers[i].value
        if not h2_field_value_is_valid(value):
            return _verdict_malformed(H2_MALFORMED_BAD_FIELD_VALUE)
        if h2_is_pseudo_name(name):
            # RFC 9113 §8.3 — order first: a pseudo AFTER a regular field is
            # malformed whatever the pseudo is.
            if seen_regular:
                return _verdict_malformed(
                    H2_MALFORMED_PSEUDO_AFTER_REGULAR
                )
            if name != String(":status"):
                # Every other pseudo — a request pseudo (:method, :path,
                # :scheme, :authority) or an undefined one (:test) — is the
                # same violation: a response defines exactly one.
                return _verdict_malformed(H2_MALFORMED_UNDEFINED_PSEUDO)
            if seen_status:
                return _verdict_malformed(H2_MALFORMED_DUPLICATE_PSEUDO)
            status = h2_status_code_of(value)
            if status < 0:
                return _verdict_malformed(H2_MALFORMED_BAD_STATUS)
            seen_status = True
        else:
            seen_regular = True
            if not h2_field_name_is_valid(name):
                return _verdict_malformed(H2_MALFORMED_BAD_FIELD_NAME)
            if h2_is_connection_specific_field(name):
                return _verdict_malformed(H2_MALFORMED_CONNECTION_SPECIFIC)
            if name == String("te") and not h2_te_value_is_trailers(value):
                return _verdict_malformed(H2_MALFORMED_BAD_TE)
            if name == String("content-length"):
                var cl = h2_content_length_of(value)
                if cl < Int64(0):
                    return _verdict_malformed(
                        H2_MALFORMED_BAD_CONTENT_LENGTH
                    )
                if content_length >= Int64(0) and content_length != cl:
                    return _verdict_malformed(
                        H2_MALFORMED_CONFLICTING_CONTENT_LENGTH
                    )
                content_length = cl
        i = i + 1
    if not seen_status:
        return _verdict_malformed(H2_MALFORMED_NO_STATUS)
    return H2BlockVerdict(
        reason_code=H2_MALFORMED_OK,
        status=status,
        content_length=content_length,
    )


def h2_validate_response_trailers(
    ref headers: List[HpackHeader],
) -> H2BlockVerdict:
    """Validate a decoded TRAILER section (RFC 9113 §8.1).

    Two differences from a head block, and only two: NO pseudo-header may
    appear at all (not even `:status` — the rule that let a trailer rewrite an
    already-delivered status), and there is no `:status` to require. §8.2.1's
    field-name / field-value rules and §8.2.2's connection-specific ban and
    `te` value rule apply unchanged; the RFC grants trailers no relaxation
    of any of them.
    """
    var n = len(headers)
    var i = 0
    while i < n:
        ref name = headers[i].name
        ref value = headers[i].value
        if h2_is_pseudo_name(name):
            return _verdict_malformed(H2_MALFORMED_PSEUDO_IN_TRAILER)
        if not h2_field_value_is_valid(value):
            return _verdict_malformed(H2_MALFORMED_BAD_FIELD_VALUE)
        if not h2_field_name_is_valid(name):
            return _verdict_malformed(H2_MALFORMED_BAD_FIELD_NAME)
        if h2_is_connection_specific_field(name):
            return _verdict_malformed(H2_MALFORMED_CONNECTION_SPECIFIC)
        if name == String("te") and not h2_te_value_is_trailers(value):
            return _verdict_malformed(H2_MALFORMED_BAD_TE)
        i = i + 1
    return H2BlockVerdict()
