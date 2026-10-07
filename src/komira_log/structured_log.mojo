# =============================================================================
# komira_log/structured_log.mojo — ONE line of JSON on stdout, for the log
# collector that is already reading stdout.
# =============================================================================
#
# WHY THIS EXISTS. A diagnosis is only useful if it can be JOINED to the
# failure it explains. Free text printed on stdout lands on a stream that is
# disjoint from the one carrying the request status, with no field in common
# but the timestamp — and a timestamp join stops being a join under
# concurrency. Diagnostics accumulated in a process-local buffer that nothing
# drains are worse: thrown away at exit, and an unbounded leak meanwhile. The
# collector is not the problem; the SHAPE of the line is.
#
# ★ THE SHAPE GOOGLE PARSES. A single-line JSON object on stdout/stderr is
# lifted into `jsonPayload`, and a specific set of keys are promoted out of it
# into the LogEntry itself (per Cloud Logging's structured-logging guide):
#
#     severity                        -> the entry's severity (an ERROR shows
#                                        up under `severity>=ERROR`, which is
#                                        the filter an operator actually types)
#     message                         -> the entry's display text
#     logging.googleapis.com/trace    -> JOINS this entry to the REQUEST entry
#     logging.googleapis.com/spanId
#     httpRequest, .../labels, .../sourceLocation, .../insertId, ...
#
# Everything else stays an ordinary `jsonPayload.<key>` and is filterable.
# Free text is none of that: it lands in `textPayload` at severity DEFAULT,
# which is why the existing `[notification-read]` lines were invisible to a
# severity filter and unjoinable to the 500 they explain.
#
# MULTI-LINE IS A DIFFERENT LOG ENTRY. The collector splits on newline, so a
# message containing one is not "a big entry", it is a broken entry followed by
# a garbage entry. `json_escape` below turns every control byte into its escape,
# which is what makes "one line" a property of the code rather than a hope.
#
# ⛔ WHAT MUST NEVER REACH HERE. In a MULTI-TENANT service a log line is
# retained, replicated and readable by a wider audience than a response body,
# so "the client already saw it" is NOT on its own a licence to log it.
# `redact_log_text` is applied to EVERY string value this module emits — not to
# the ones a caller remembers to wrap — and it is applied to keys' values, not
# just to the message, because a store error can quote a customer's email
# address back at you.
#
# ENCAPSULATION: the whole surface is value-typed — `String` /
# `Int` / `StaticString` in, `String` out (plus the one `print`). ZERO
# `UnsafePointer` crosses any boundary; no wildcard origin; no
# `unsafe_from_address`. `StructuredLogLine` is a POD value object (three
# `String`s), never stored in a byte-slab.
#
# DEPENDENCIES: none outside this package. The JSON escaper is
# ~25 lines and is written out here rather than pulled from a JSON library,
# because a log emitter that can fail to build its own line is worse than no
# log emitter, and because this keeps the structured logger free of any JSON dependency.
# =============================================================================


from komira_log.levels import (
    LEVEL_TRACE,
    LEVEL_DEBUG,
    LEVEL_INFO,
    LEVEL_WARN,
    LEVEL_ERROR,
)
from komira_log.log_write import write_log_line
from komira_trace.exporter import json_escape


# =============================================================================
# §0 — LogSeverity. The subset this repo emits.
# =============================================================================
# The full enum is DEFAULT / DEBUG / INFO / NOTICE / WARNING / ERROR /
# CRITICAL / ALERT / EMERGENCY. Anything not in it is ignored by the collector
# and the entry silently drops to DEFAULT — which is the failure mode this
# module exists to remove — so these are comptime constants, not strings a
# caller spells.

comptime SEVERITY_DEFAULT: StaticString = "DEFAULT"
comptime SEVERITY_DEBUG: StaticString = "DEBUG"
comptime SEVERITY_INFO: StaticString = "INFO"
comptime SEVERITY_WARNING: StaticString = "WARNING"
comptime SEVERITY_ERROR: StaticString = "ERROR"
comptime SEVERITY_CRITICAL: StaticString = "CRITICAL"


# =============================================================================
# §0b — komira_log level -> Google severity. ⭐ THE TRAP IS `WARN`.
# =============================================================================
#
# `komira_log`'s level vocabulary is TRACE / DEBUG / INFO / **WARN** / ERROR.
# Google's is DEFAULT / DEBUG / INFO / NOTICE / **WARNING** / ERROR / CRITICAL /
# ALERT / EMERGENCY. Two of those five names do NOT survive a straight copy:
#
#   * there is no `TRACE`  — it must land as `DEBUG`
#   * there is no `WARN`   — it must land as `WARNING`
#
# ⛔ SO `level_name(level)` IS NOT A SEVERITY, AND USING IT AS ONE REPRODUCES
# THE EXACT BUG THIS FUNCTION EXISTS TO CLOSE, IN A FORM THAT LOOKS FIXED.
# Per §0 above: a severity string outside Google's enum is ignored and the entry
# silently drops to DEFAULT. A `"severity":"WARN"` line is therefore INVISIBLE
# to `severity>=WARNING` while looking, in the source, exactly like a line that
# works. Pinned BY NAME by
# `komira_log`'s severity tests.
#
# ⛔ THE ARGUMENT IS A RAW `UInt8` (the level word), compared against the
# constants authored in `komira_log.levels` (`LEVEL_TRACE=0 .. LEVEL_ERROR=4`,
# `LEVEL_OFF=5`). `test_log_json_severity` pins both the constants' values and
# every mapping with literal numbers, so a renumbering of `levels.mojo` cannot
# silently re-point every severity by one.


def gcp_severity_for_level(level: UInt8) -> StaticString:
    """Map a `komira_log` level word (`komira_log.levels`) to the Cloud
    Logging severity string Google actually promotes.

    An unrecognised level — including the `LEVEL_OFF` threshold sentinel, which
    is never a RECORD level — returns `DEFAULT`, which is a legal member of the
    enum and is exactly where the collector would have put the entry anyway. It
    is never `"?"`: an out-of-enum string is the failure mode, not a diagnostic.
    """
    if level == LEVEL_TRACE:  # Google has no TRACE.
        return SEVERITY_DEBUG
    elif level == LEVEL_DEBUG:
        return SEVERITY_DEBUG
    elif level == LEVEL_INFO:
        return SEVERITY_INFO
    elif level == LEVEL_WARN:  # -> "WARNING", NOT "WARN".
        return SEVERITY_WARNING
    elif level == LEVEL_ERROR:
        return SEVERITY_ERROR
    return SEVERITY_DEFAULT


# =============================================================================
# §0c — which layout should a logger render?
# =============================================================================
#
# The CALLER decides, from two facts it was given at startup: an explicit
# format selector (a command-line flag, empty when not supplied) and whether
# the process runs on a deployed platform (a flag the deployer sets). This
# module reads neither from the environment; it only combines them, so the
# selection is a pure function a test can drive with any pair of values.


def log_format_is_json(log_format: String, on_deployed_platform: Bool) -> Bool:
    """Which layout the process's loggers should render: JSON (True) or the
    human text line (False).

    1. `log_format == "json"` (case-insensitive) -> True
    2. `log_format == "text"` (case-insensitive) -> False
    3. anything else, INCLUDING empty (not supplied) and malformed ->
       `on_deployed_platform`.

    ⛔ (3) deliberately does NOT refuse a malformed value, and the exception is
    stated rather than hidden. Refusing malformed configuration is argued from
    a binary that would otherwise proceed with a value nobody supplied; its
    remedy is to exit before the first mutation. A LOGGER cannot take that
    remedy — refusing to start over a typo in a log-FORMAT selector would
    convert a cosmetic misconfiguration into a total outage, and the process
    that would report the refusal is the one being refused. So a malformed
    value neither crashes NOR silently selects json: it falls through to the
    platform answer, which is the same answer the operator would have got had
    they not tried to set it at all."""
    if log_format.byte_length() > 0:
        var lc = _lower_ascii(log_format)
        if lc == String("json"):
            return True
        if lc == String("text"):
            return False
    return on_deployed_platform


comptime LOG_TEXT_CAP: Int = 2048
"""The per-value byte cap. A store error can carry a multi-kilobyte URL (a
missing-index refusal can hold hundreds of bytes of base64 alone), and an
unbounded value turns one bad request into a log-volume incident. 2 KiB holds
a typical diagnostic with room to spare."""

comptime REDACTED: StaticString = "<redacted>"
comptime REDACTED_EMAIL: StaticString = "<email>"
comptime TRUNCATED_SUFFIX: StaticString = "…[truncated]"


# =============================================================================
# §1 — json_escape — the property that makes "one line" true.
# =============================================================================
# The escaper is `komira_trace.exporter.json_escape`, the one definition: it
# escapes `"` and `\\`, every byte below 0x20, and copies every other byte
# (including each byte of a multi-byte UTF-8 sequence) through unchanged.
# This module and the span-line formatter must escape identically, so there
# is one body, below this package.


# =============================================================================
# §2 — redact_log_text — the compliance boundary, applied to EVERY value.
# =============================================================================
# Three named rules, in this order. Each one closes a shape that is REACHABLE
# from an ordinary error message — none of them is speculative hardening:
#
#   1. BEARER / BASIC credentials. `Authorization: Bearer <jwt>` reaches an
#      error string whenever a transport echoes the request it failed to make.
#   2. KEYED SECRETS (`token=`, `password=`, `secret=`, `api_key=`, ...). The
#      same echo, in query-string / kv form.
#   3. EMAIL ADDRESSES. A uniqueness-violation message from a store quotes the
#      offending value — `Key (email)=(alice@customer.example) already exists`
#      is a real Postgres shape, and any route that manages mail addresses is
#      an email surface end to end.
#
# ⚠ THIS IS A FLOOR, NOT A PROOF. A denylist cannot be complete, and claiming
# otherwise is how a debugging aid becomes a compliance incident. The load-
# bearing discipline is upstream and structural: this module's callers pass the
# error's OWN message and the response status — never a request body, never a
# header map, never a store row. See `LoggingMiddleware.after`, which logs the
# response body only for 5xx and only through here.

def _secret_keys() -> List[String]:
    """The credential-ish key names rule 2 looks for, lower-cased.

    A function rather than a `comptime` list: a `List[String]` is not
    `ImplicitlyCopyable`, so it cannot be materialized from comptime to
    runtime. Built once per `_redact_keyed_secrets` call, which runs only on
    the 5xx path."""
    return [
        String("authorization"),
        String("password"),
        String("passwd"),
        String("secret"),
        String("token"),
        String("api_key"),
        String("apikey"),
        String("access_key"),
        String("private_key"),
        String("credential"),
        String("cookie"),
        String("session_id"),
        String("client_secret"),
        String("refresh_token"),
        String("id_token"),
    ]


def _is_value_delim(c: UInt8) -> Bool:
    """A byte that ENDS a value token: whitespace, or one of the punctuation
    marks that closes a field in a query string / JSON fragment / prose."""
    return (
        c == UInt8(32)
        or c < UInt8(32)
        or c == UInt8(38)  # &
        or c == UInt8(44)  # ,
        or c == UInt8(34)  # "
        or c == UInt8(39)  # '
        or c == UInt8(41)  # )
        or c == UInt8(59)  # ;
        or c == UInt8(125)  # }
        or c == UInt8(93)  # ]
    )


def _lower_ascii(s: String) -> String:
    """Lower-case A-Z **IN PLACE, BYTE FOR BYTE**, leaving every other byte
    untouched.

    ⛔ THE BYTE-PARALLEL PROPERTY IS LOAD-BEARING, NOT COSMETIC.
    `_redact_keyed_secrets` takes every index against this shadow and applies it
    to the ORIGINAL, and its own comment asserts the shadow "is byte-parallel to
    the original because `_lower_ascii` only ever rewrites A-Z in place". A
    pass-through arm spelled `out += String(chr(Int(c)))` would break that:
    `chr` maps a CODE POINT to its UTF-8 ENCODING, so every byte >= 0x80 would
    become TWO, the shadow would grow, and every subsequent index into the
    original would be off by the drift. On a 5xx body carrying any non-ASCII
    byte before a credential, the redaction would cut at the wrong offset: it
    could leave part of a secret in, or eat text that is not one, silently.
    Same `chr(Int(byte))` class as `json_escape` above."""
    var out = String("")
    var b = s.as_bytes()
    var n = len(b)
    var i = 0
    while i < n:
        var c = b[i]
        if c >= UInt8(65) and c <= UInt8(90):
            out += String(chr(Int(c) + 32))
            i = i + 1
        else:
            # BYTE-EXACT run copy of everything that is not an upper-case
            # ASCII letter. One byte in, one byte out.
            var run_start = i
            while i < n:
                var rc = b[i]
                if rc >= UInt8(65) and rc <= UInt8(90):
                    break
                i = i + 1
            out += String(StringSlice(unsafe_from_utf8=b[run_start:i]))
    return out^


def _redact_keyed_secrets(text: String) -> String:
    """Rule 1 + 2: replace the VALUE that follows a credential-ish key (or a
    `Bearer` / `Basic` scheme word) with `<redacted>`, keeping the key so the
    reader still learns WHICH credential was involved.

    Matching is case-insensitive on a lower-cased shadow of the input, and every
    index is taken against that shadow — which is byte-parallel to the original
    because `_lower_ascii` only ever rewrites A-Z in place."""
    var keys = _secret_keys()
    var lower = _lower_ascii(text)
    var src = text.as_bytes()
    var low = lower.as_bytes()
    var n = len(src)

    var out = String("")
    var i = 0
    while i < n:
        var matched_len = 0
        # `Bearer ` / `Basic ` — the scheme word IS the key.
        if _match_at(low, i, String("bearer ")):
            matched_len = 7
        elif _match_at(low, i, String("basic ")):
            matched_len = 6
        else:
            for k in range(len(keys)):
                ref key = keys[k]
                if _match_at(low, i, key):
                    # Only a real key=value / key: value binding counts; a bare
                    # mention of the word "token" in prose must not eat the rest
                    # of the sentence.
                    var j = i + len(key.as_bytes())
                    while j < n and src[j] == UInt8(32):
                        j = j + 1
                    if j < n and (src[j] == UInt8(61) or src[j] == UInt8(58)):
                        j = j + 1
                        while j < n and src[j] == UInt8(32):
                            j = j + 1
                        matched_len = j - i
                    break
        if matched_len > 0:
            # Emit the key + separator verbatim, then swallow the value token.
            for c in range(i, i + matched_len):
                out += String(chr(Int(src[c])))
            var v = i + matched_len
            var vs = v
            while v < n and not _is_value_delim(src[v]):
                v = v + 1
            if v > vs:
                # ★ THE VALUE OF `authorization` IS TWO TOKENS, NOT ONE, and
                # redacting only the first is worse than redacting nothing: it
                # LOOKS redacted while leaving the credential in place. Caught
                # by `test_redacts_bearer_and_keyed_secrets` — the first cut
                # turned `authorization: Bearer eyJhbGciOi.J9.sig` into
                # `authorization: <redacted> eyJhbGciOi.J9.sig`, because the
                # `authorization` key matched at an earlier index than the
                # `Bearer ` rule and ate the SCHEME as its value.
                #
                # So: a value token that IS an auth scheme word is kept (it is
                # not secret, and knowing WHICH scheme failed is half the
                # diagnosis) and the token after it is redacted instead.
                var tok = _lower_ascii(
                    String(StringSlice(unsafe_from_utf8=src[vs:v]))
                )
                if _is_auth_scheme(tok):
                    out += String(StringSlice(unsafe_from_utf8=src[vs:v]))
                    while v < n and src[v] == UInt8(32):
                        out += String(" ")
                        v = v + 1
                    var vs2 = v
                    while v < n and not _is_value_delim(src[v]):
                        v = v + 1
                    if v > vs2:
                        out += String(REDACTED)
                else:
                    out += String(REDACTED)
            i = v
            continue
        out += String(chr(Int(src[i])))
        i = i + 1
    return out^


def _is_auth_scheme(lower_token: String) -> Bool:
    """An RFC 7235 auth-scheme word. Not a secret; the token AFTER it is."""
    return (
        lower_token == String("bearer")
        or lower_token == String("basic")
        or lower_token == String("digest")
        or lower_token == String("negotiate")
    )


def _match_at[o: Origin[mut=False]](
    hay: Span[UInt8, o], at: Int, needle: String
) -> Bool:
    var nb = needle.as_bytes()
    var m = len(nb)
    if at + m > len(hay):
        return False
    for k in range(m):
        if hay[at + k] != nb[k]:
            return False
    return True


def _is_email_local(c: UInt8) -> Bool:
    """A byte legal in the local part / domain of an address, restricted to the
    set that cannot swallow surrounding prose."""
    if c >= UInt8(48) and c <= UInt8(57):
        return True
    if c >= UInt8(65) and c <= UInt8(90):
        return True
    if c >= UInt8(97) and c <= UInt8(122):
        return True
    return (
        c == UInt8(46)  # .
        or c == UInt8(95)  # _
        or c == UInt8(45)  # -
        or c == UInt8(43)  # +
    )


def _redact_emails(text: String) -> String:
    """Rule 3: replace `local@domain.tld` with `<email>`.

    Requires a dot in the domain, so a bare `@handle` or an `a@b` fragment of a
    hostname is left alone. The domain is NOT retained: on a single-tenant
    deployment the domain IS the customer."""
    var b = text.as_bytes()
    var n = len(b)
    var out = String("")
    var i = 0
    while i < n:
        if b[i] == UInt8(64) and i > 0:  # @
            # Walk back over the local part.
            var s = i
            while s > 0 and _is_email_local(b[s - 1]):
                s = s - 1
            # Walk forward over the domain.
            var e = i + 1
            var saw_dot = False
            while e < n and _is_email_local(b[e]):
                if b[e] == UInt8(46):
                    saw_dot = True
                e = e + 1
            # Trim a trailing '.' that belongs to the sentence, not the domain.
            while e > i + 1 and b[e - 1] == UInt8(46):
                e = e - 1
            if s < i and saw_dot and e > i + 1:
                # Drop the local part already emitted into `out`.
                var keep = len(out.as_bytes()) - (i - s)
                if keep < 0:
                    keep = 0
                # MOJO-1.0.0 refuses a self-assignment whose argument still
                # borrows the destination. The temp materialises the prefix
                # before `out` is overwritten.
                var _kept = String(
                    StringSlice(unsafe_from_utf8=out.as_bytes()[:keep])
                )
                out = _kept^
                out += String(REDACTED_EMAIL)
                i = e
                continue
        out += String(chr(Int(b[i])))
        i = i + 1
    return out^


def _truncate_utf8(text: String, cap: Int) -> String:
    """Cap `text` at `cap` bytes WITHOUT splitting a UTF-8 code point (a split
    would emit invalid UTF-8 into a JSON string, and an invalid line is a
    dropped line). Backs off over continuation bytes (0b10xxxxxx)."""
    var b = text.as_bytes()
    var n = len(b)
    if n <= cap:
        return String(text)
    var end = cap
    while end > 0 and (b[end] & UInt8(192)) == UInt8(128):
        end = end - 1
    return (
        String(StringSlice(unsafe_from_utf8=b[:end])) + String(TRUNCATED_SUFFIX)
    )


def redact_log_text(text: String, cap: Int = LOG_TEXT_CAP) -> String:
    """Apply every redaction rule, then cap. THE order matters: redact first so
    a secret cannot be preserved by sitting past the cap boundary in a value
    that a later change lengthens."""
    var scrubbed = _redact_emails(_redact_keyed_secrets(text))
    return _truncate_utf8(scrubbed^, cap)


# =============================================================================
# §3 — trace correlation. The field that turns two streams into one.
# =============================================================================
comptime TRACE_HEADER: StaticString = "x-cloud-trace-context"


def trace_id_from_header(header_value: String) -> String:
    """The TRACE_ID out of `X-Cloud-Trace-Context: TRACE_ID/SPAN_ID;o=1`.

    Returns "" for an absent or unrecognisable header — a missing correlation
    id must degrade to a line WITHOUT one, never to no line."""
    var b = header_value.as_bytes()
    var n = len(b)
    var e = 0
    while e < n and b[e] != UInt8(47) and b[e] != UInt8(59) and b[e] != UInt8(32):
        e = e + 1
    if e == 0:
        return String("")
    return String(StringSlice(unsafe_from_utf8=b[:e]))


def qualified_trace(trace_id: String, project: String) -> String:
    """`projects/<project>/traces/<TRACE_ID>` — the ONLY form Logs Explorer
    joins on — or "" when either the trace id or the project is empty.

    The project id is supplied by the caller (configured at startup); the
    platform does not always make one available. When it is empty this
    returns "", the canonical field is OMITTED rather than emitted malformed,
    and the caller still emits a plain `trace_id` field — which an operator
    joins with `jsonPayload.trace_id="<id>"` against the request entry's own
    trace. A degraded join is stated; a wrong `logging.googleapis.com/trace`
    value would be silently ignored by the collector and look like the feature
    works."""
    if trace_id.byte_length() == 0:
        return String("")
    if project.byte_length() == 0:
        return String("")
    var out = String("projects/")
    out += project
    out += String("/traces/")
    out += String(trace_id)
    return out^


# =============================================================================
# §4 — StructuredLogLine — build one, render it, emit it.
# =============================================================================
# `render()` and `emit()` are SEPARATE on purpose: `render()` is a pure function
# of the builder's state, so a test can assert the EXACT bytes the process
# writes without capturing stdout. A logger whose output is only observable by
# running the server is a logger nobody writes a falsifier for.


struct StructuredLogLine(Movable, Deinitable):
    """One Cloud-Logging-shaped JSON object, built field by field.

    Every string value goes through `redact_log_text` on the way in — including
    the message, including the route. That is deliberate: a redaction a caller
    has to remember is a redaction that will be forgotten at the fifth call
    site."""

    var _severity: String
    var _message: String
    var _fields: String
    var _cap: Int

    def __init__(
        out self,
        severity: StaticString,
        var message: String,
        cap: Int = LOG_TEXT_CAP,
    ):
        self._severity = String(severity)
        self._cap = cap
        self._message = redact_log_text(message^, cap)
        self._fields = String("")

    def with_str(mut self, key: StaticString, value: String):
        """Add a string field. An EMPTY value is dropped, not emitted as "": an
        absent field reads as absent, whereas an empty one reads as "we looked
        and there was nothing there", and those are different claims."""
        if value.byte_length() == 0:
            return
        self._fields += String(',"')
        self._fields += String(key)
        self._fields += String('":"')
        self._fields += json_escape(redact_log_text(value, self._cap))
        self._fields += String('"')

    def with_int(mut self, key: StaticString, value: Int):
        self._fields += String(',"')
        self._fields += String(key)
        self._fields += String('":')
        self._fields += String(value)

    def render(self) -> String:
        """The exact single line this builder emits, newline excluded."""
        var out = String('{"severity":"')
        out += String(self._severity)
        out += String('","message":"')
        out += json_escape(self._message)
        out += String('"')
        out += self._fields
        out += String("}")
        return out^

    def emit(self):
        """Write the line + a newline to stdout with ONE unbuffered `write(2)`,
        where the platform's log collector is already reading. One write == one
        entry."""
        emit_structured_line(self.render())


# =============================================================================
# §5 — the emitter. ⛔ NOT `print`, AND THE REASON IS THE SUBJECT MATTER.
# =============================================================================


def emit_structured_line(var line: String):
    """Write `line` + a newline to fd 1 with ONE unbuffered `write(2)`.

    ⚠ NOT `print`. `print` goes through a userspace buffer; when stdout is a
    PIPE — which it always is under a container log collector — that buffer is
    BLOCK-buffered, not line-buffered. A container that is SIGKILLed (the norm
    on a crash, an OOM, or a revision replace) takes the buffer with it, and
    the line describing WHY is exactly the line lost. A diagnostic that
    survives only a graceful exit is not a diagnostic for the crashing case.
    Every caller of `StructuredLogLine.emit` gets this for free.

    ⛔ THE LOOP IS `log_write.write_log_line`, NOT A COPY OF IT. A
    hand-transcribed `write(2)` loop would re-introduce three defects that
    module already handles and that a small test target cannot see: `errno`
    is only valid when `n < 0` and only adjacent to the call; the shim's fd
    argument must go in as `Int32` and never `Int(fd)`, or the link dies with
    "existing function with conflicting signature" the first time this lands
    in a closure that already has another declaration of it; and EAGAIN is 11
    on Linux but 35 on Darwin.

    ⭐ AND THE JSON LAYOUT RAISES THE STAKES ON A PARTIAL WRITE. While these
    lines were free text, a short write produced a DAMAGED line the collector
    still kept and a human could still read. Now that a line is a JSON object,
    a short write produces an UNPARSEABLE line the collector DROPS — the entry
    does not arrive at all. That is why `LineWrite` distinguishes `truncated()`
    from `lost()` with a byte count: "40 of 120" and "119 of 120" are the same
    English word and very different evidence.

    ⚠ THE OUTCOME IS DELIBERATELY DISCARDED HERE. A `LineWrite` is only
    worth returning if something AGGREGATES it, and that aggregation belongs
    where every sink can share it (`LogWriteLosses`), not in a second counter
    at this one call site. What this function owes is that the write is
    UNBUFFERED and ATOMIC.

    One `write` per line keeps the line atomic: writes under `PIPE_BUF` are not
    interleaved by the kernel, so two threads emitting concurrently cannot
    splice half of one JSON object into the other. The newline is concatenated
    into the SAME String before the call for exactly that reason.

    It never raises — the same choice `komira_libc.fd_write_all` names
    in its header: a logger breaks rather than raises because *losing a
    diagnostic beats wedging the process*, and a logger that can raise into a
    serve loop turns a logged fault into a dropped connection."""
    var payload = line^
    payload += String("\n")
    _ = write_log_line(Int32(1), payload)
