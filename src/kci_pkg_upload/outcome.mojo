# =============================================================================
# src/kci_pkg_upload/outcome.mojo — every server answer is DATA.
# =============================================================================
#
# Each of the four registry methods returns a KIND, never a bare value, and
# every kind a server can answer is spelled here:
#
#   presence(c, expect) -> Presence    was the file there, and is it ours?
#   upload(f, names)    -> UploadOutcome
#   read_back(c)        -> ReadBack    what the registry says it holds now
#   fetch(c)            -> Fetched     the bytes the registry serves
#
# WHY NOT RAISE ON A 404, A 403 OR A 429. A read that raised on 404 would make
# ABSENT — the most ordinary answer a presence probe gets — an exception; and a
# read that came back EMPTY instead would be compared field by field against our
# identity and read as equal by vacuity. So ABSENT is a kind, AUTH_REFUSED and
# RATE_LIMITED are kinds, and anything the client cannot classify (a 5xx, a
# transport fault, a redirect it will not follow) is UNKNOWN, which the caller
# re-probes.
#
# ⛔ `raises` IS RESERVED FOR LOCAL FAULTS RAISED BEFORE ANY REQUEST IS SENT — a
# malformed coordinate, a credential that cannot serve a surface, a substrate
# with no registry arm, a published name the caller's `ApprovedNames` does not
# list. A transport raise on a MUTATING request is UNKNOWN: the
# client cannot tell whether bytes left, so it never claims either way.
#
# `detail` is for a human reading a refusal. It is a bounded excerpt of what the
# server said, WITHHELD whenever the text it would quote holds the request's
# credential in any of three SHAPES — the whole `Authorization` value, the part
# after its scheme, and for Basic the decoded password — either whole or as ANY
# run of `ECHO_WINDOW_BYTES` (16) consecutive bytes of a shape.
# `excerpt_unless_echoes` checks the WHOLE body before the excerpt is cut, so
# OUR byte bound never leaves a prefix to quote; the 16-byte runs catch a server
# that truncates the echo ITSELF (`<first 20 chars>...`). `withhold_if_echoes`
# applies the same matcher to text that is not a server body.
#
# ⚠ WHAT IS NOT HELD, and not claimed: an echo shorter than 16 bytes of a
# shape, and a re-encoding (percent-encoding, JSON escaping, another base64
# alignment) that leaves no 16-byte run of any shape intact. Such text is
# quoted. A shape shorter than 16 bytes is matched whole only.
#
# Encapsulation: owned values; no pointer, no wildcard origin.
# =============================================================================

from std.collections import Set

from komira_encoding import base64_decode

from .identity import ContentIdentity
from .wire import bytes_contain


# ── presence ────────────────────────────────────────────────────────────────
comptime PRESENCE_ABSENT: Int = 0
comptime PRESENCE_PRESENT_IDENTICAL: Int = 1
comptime PRESENCE_PRESENT_DIFFERENT: Int = 2
comptime PRESENCE_NO_COMMON_FIELD: Int = 3
comptime PRESENCE_AUTH_REFUSED: Int = 4
comptime PRESENCE_RATE_LIMITED: Int = 5
comptime PRESENCE_UNKNOWN: Int = 6

# ── read-back and fetch (the same kinds) ────────────────────────────────────
comptime READ_PRESENT: Int = 0
comptime READ_ABSENT: Int = 1
comptime READ_AUTH_REFUSED: Int = 2
comptime READ_RATE_LIMITED: Int = 3
comptime READ_UNKNOWN: Int = 4

# ── upload ──────────────────────────────────────────────────────────────────
# CREATED           2xx. ⚠ PyPI also answers 200 to an IDENTICAL duplicate, so
#                   CREATED means "the registry holds these bytes now", not
#                   "this request wrote them"; the caller's read-back decides.
# DUPLICATE_REFUSED the registry refused because the file name exists (PyPI 400
#                   "File already exists", a 409). Becomes a CONFLICT only
#                   after a read-back differs.
# CONFLICT          never produced by a client classification; the caller's
#                   verdict after a read-back MISMATCH. Spelled here so there
#                   is one vocabulary.
# BURNED            the file name belonged to a DELETED file and can never be
#                   reused (PyPI). Presence reads ABSENT for these, so this is
#                   an upload-time answer.
# AUTH_REFUSED      401 / 403.
# RATE_LIMITED      429.
# WINDOW_CLOSED     PyPI refuses new files on a release older than its window.
# UNKNOWN           the transport raised, a 5xx, or no classifiable answer.
# REJECTED          the registry definitively refused the request for a reason
#                   none of the above names (a malformed form, a wrong
#                   endpoint, an unfollowed redirect). Nothing was stored; a
#                   re-run of the same bytes gets the same answer. Kept apart
#                   from UNKNOWN because a definitive refusal filed as UNKNOWN
#                   would be re-probed as though it might have landed.
comptime UPLOAD_CREATED: Int = 0
comptime UPLOAD_DUPLICATE_REFUSED: Int = 1
comptime UPLOAD_CONFLICT: Int = 2
comptime UPLOAD_BURNED: Int = 3
comptime UPLOAD_AUTH_REFUSED: Int = 4
comptime UPLOAD_RATE_LIMITED: Int = 5
comptime UPLOAD_WINDOW_CLOSED: Int = 6
comptime UPLOAD_UNKNOWN: Int = 7
comptime UPLOAD_REJECTED: Int = 8


def presence_kind_name(kind: Int) -> String:
    if kind == PRESENCE_ABSENT:
        return String("ABSENT")
    if kind == PRESENCE_PRESENT_IDENTICAL:
        return String("PRESENT_IDENTICAL")
    if kind == PRESENCE_PRESENT_DIFFERENT:
        return String("PRESENT_DIFFERENT")
    if kind == PRESENCE_NO_COMMON_FIELD:
        return String("NO_COMMON_FIELD")
    if kind == PRESENCE_AUTH_REFUSED:
        return String("AUTH_REFUSED")
    if kind == PRESENCE_RATE_LIMITED:
        return String("RATE_LIMITED")
    if kind == PRESENCE_UNKNOWN:
        return String("UNKNOWN")
    return String("PRESENCE(") + String(kind) + String(")")


def read_kind_name(kind: Int) -> String:
    if kind == READ_PRESENT:
        return String("PRESENT")
    if kind == READ_ABSENT:
        return String("ABSENT")
    if kind == READ_AUTH_REFUSED:
        return String("AUTH_REFUSED")
    if kind == READ_RATE_LIMITED:
        return String("RATE_LIMITED")
    if kind == READ_UNKNOWN:
        return String("UNKNOWN")
    return String("READ(") + String(kind) + String(")")


def upload_kind_name(kind: Int) -> String:
    if kind == UPLOAD_CREATED:
        return String("CREATED")
    if kind == UPLOAD_DUPLICATE_REFUSED:
        return String("DUPLICATE_REFUSED")
    if kind == UPLOAD_CONFLICT:
        return String("CONFLICT")
    if kind == UPLOAD_BURNED:
        return String("BURNED")
    if kind == UPLOAD_AUTH_REFUSED:
        return String("AUTH_REFUSED")
    if kind == UPLOAD_RATE_LIMITED:
        return String("RATE_LIMITED")
    if kind == UPLOAD_WINDOW_CLOSED:
        return String("WINDOW_CLOSED")
    if kind == UPLOAD_UNKNOWN:
        return String("UNKNOWN")
    if kind == UPLOAD_REJECTED:
        return String("REJECTED")
    return String("UPLOAD(") + String(kind) + String(")")


struct Presence(Copyable, Movable, Deinitable):
    """The presence probe's answer. `observed` is what the registry exposed
    (meaningful for the three PRESENT_* / NO_COMMON_FIELD kinds). `status` is
    the HTTP status of the answer that decided, 0 when none (a transport
    fault).

    Layout: Ints and owned values. No pointer field."""

    var kind: Int
    var status: Int
    var observed: ContentIdentity
    var detail: String

    def __init__(
        out self,
        kind: Int,
        status: Int,
        var observed: ContentIdentity,
        var detail: String,
    ):
        self.kind = kind
        self.status = status
        self.observed = observed^
        self.detail = detail^


struct ReadBack(Copyable, Movable, Deinitable):
    """What the registry says it holds. `observed` is meaningful only when
    `kind == READ_PRESENT`.

    Layout: Ints and owned values. No pointer field."""

    var kind: Int
    var status: Int
    var observed: ContentIdentity
    var detail: String

    def __init__(
        out self,
        kind: Int,
        status: Int,
        var observed: ContentIdentity,
        var detail: String,
    ):
        self.kind = kind
        self.status = status
        self.observed = observed^
        self.detail = detail^


struct Fetched(Movable, Deinitable):
    """The bytes the registry serves for a file. `bytes` is meaningful only
    when `kind == READ_PRESENT`; the caller hashes them — a fetch never
    vouches for its own content.

    Layout: Ints and owned values. No pointer field."""

    var kind: Int
    var status: Int
    var bytes: List[UInt8]
    var detail: String

    def __init__(
        out self,
        kind: Int,
        status: Int,
        var bytes: List[UInt8],
        var detail: String,
    ):
        self.kind = kind
        self.status = status
        self.bytes = bytes^
        self.detail = detail^


struct UploadOutcome(Copyable, Movable, Deinitable):
    """The upload's answer. `detail` is withheld when it would quote the
    request's credential (see the file header for exactly what is held).

    Layout: Ints and owned values. No pointer field."""

    var kind: Int
    var status: Int
    var detail: String

    def __init__(out self, kind: Int, status: Int, var detail: String):
        self.kind = kind
        self.status = status
        self.detail = detail^


# The longest server excerpt a `detail` quotes. An error page can be large, and
# a detail is read by a human in a refusal line.
comptime DETAIL_EXCERPT_BYTES: Int = 400

# The shortest run of a credential shape whose appearance withholds a detail.
# A server that truncates its echo of a token keeps a PREFIX of it; any run
# this long of any shape is treated as the credential. Shorter runs are
# quoted: 16 bytes of a random token is 96+ bits, and a shorter bound starts
# withholding ordinary text (every PyPI API token begins `pypi-`).
comptime ECHO_WINDOW_BYTES: Int = 16

comptime _WITHHELD_ECHO: String = (
    "the registry's answer was withheld: it echoed the request's credential"
)


def _bounded_excerpt(body: List[UInt8]) -> String:
    """A bounded, printable excerpt of a response body: bytes outside
    printable ASCII become `?`, newlines become spaces.

    ⛔ PRIVATE ON PURPOSE. A bounded excerpt can CUT a credential the server
    echoed, and a check for the whole secret in the cut text then finds
    nothing and quotes its prefix. Every caller that quotes a server body goes
    through `excerpt_unless_echoes`, which checks the WHOLE body first."""
    var out = String("")
    var n = len(body)
    if n > DETAIL_EXCERPT_BYTES:
        n = DETAIL_EXCERPT_BYTES
    for i in range(n):
        var c = body[i]
        if c == UInt8(10) or c == UInt8(13) or c == UInt8(9):
            out += String(" ")
        elif c >= UInt8(32) and c < UInt8(127):
            out += chr(Int(c))
        else:
            out += String("?")
    if len(body) > DETAIL_EXCERPT_BYTES:
        out += String("...")
    return out^


def _secrets_of(authorization: String) -> List[String]:
    """Every shape in which a server could echo `authorization`: the whole
    value; the part after the scheme (a bearer token, or the base64 blob of a
    Basic pair); and, for Basic, the decoded PASSWORD. A shape shorter than 4
    bytes is dropped — it would match ordinary text, and no real credential
    is that short."""
    var secrets = List[String]()
    if authorization.byte_length() == 0:
        return secrets^
    secrets.append(authorization.copy())
    var sp = authorization.find(String(" "))
    if sp >= 0 and sp + 1 < authorization.byte_length():
        var cred = String(authorization[byte = sp + 1 :])
        secrets.append(cred.copy())
        if authorization.startswith(String("Basic ")):
            try:
                var raw = base64_decode(cred)
                var pair = String("")
                for j in range(len(raw)):
                    if raw[j] >= UInt8(128):
                        pair = String("")
                        break
                    pair += chr(Int(raw[j]))
                var colon = pair.find(String(":"))
                if colon >= 0 and colon + 1 < pair.byte_length():
                    secrets.append(String(pair[byte = colon + 1 :]))
            except:
                pass
    var out = List[String]()
    for i in range(len(secrets)):
        if secrets[i].byte_length() >= 4:
            out.append(secrets[i].copy())
    return out^


def _all_ascii(b: Span[UInt8, _]) -> Bool:
    for i in range(len(b)):
        if b[i] >= UInt8(128):
            return False
    return True


def echoes_credential(hay: Span[UInt8, _], authorization: String) -> Bool:
    """True when `hay` holds a credential shape of `authorization` (see
    `_secrets_of`) WHOLE, or any `ECHO_WINDOW_BYTES`-long run of one.

    A shape shorter than the window, or one with a non-ASCII byte, is matched
    whole. Every other shape contributes all of its windows to one set, and
    `hay` is scanned once: O(len(hay)) set probes, however long the token."""
    var secrets = _secrets_of(authorization)
    var windows = Set[String]()
    for i in range(len(secrets)):
        var sb = secrets[i].as_bytes()
        var n = len(sb)
        if n < ECHO_WINDOW_BYTES or not _all_ascii(sb):
            if bytes_contain(hay, secrets[i]):
                return True
            continue
        for j in range(n - ECHO_WINDOW_BYTES + 1):
            windows.add(String(unsafe_from_utf8=sb[j : j + ECHO_WINDOW_BYTES]))
    if len(windows) == 0:
        return False
    # A window holding a non-ASCII byte cannot equal an (ASCII) shape window,
    # and must not be decoded: count them across the sliding window.
    var non_ascii = 0
    for k in range(len(hay)):
        if hay[k] >= UInt8(128):
            non_ascii += 1
        if k >= ECHO_WINDOW_BYTES and hay[k - ECHO_WINDOW_BYTES] >= UInt8(128):
            non_ascii -= 1
        if k + 1 < ECHO_WINDOW_BYTES or non_ascii > 0:
            continue
        var start = k + 1 - ECHO_WINDOW_BYTES
        if String(unsafe_from_utf8=hay[start : k + 1]) in windows:
            return True
    return False


def excerpt_unless_echoes(body: List[UInt8], authorization: String) -> String:
    """A bounded excerpt of a server body for a `detail`, or a statement that
    it was withheld when the body echoes the request's credential ANYWHERE
    (`echoes_credential`) — including past the excerpt's bound, where an
    excerpt would hold only a prefix of the echo and a check of the excerpt
    alone would miss it. `authorization` EMPTY = the request carried no
    credential."""
    if echoes_credential(Span(body), authorization):
        return String(_WITHHELD_ECHO)
    return _bounded_excerpt(body)


def withhold_if_echoes(var detail: String, authorization: String) -> String:
    """`detail`, unless it echoes the credential (`echoes_credential`) —
    then a statement that it was withheld.

    For text that is NOT a bounded excerpt of a server body — a transport
    fault's message, a composed refusal. A server body goes through
    `excerpt_unless_echoes`, which checks the body before it is cut. A detail
    is quoted in refusals that reach a terminal and a log, so an echo that
    slipped past would publish the token."""
    if echoes_credential(detail.as_bytes(), authorization):
        return String(_WITHHELD_ECHO)
    return detail^
