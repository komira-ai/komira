# =============================================================================
# komira_log_query/route.mojo: THE MOUNTABLE ROUTE. Match `GET <path>`, ask the
#   service's access hook, read the log through the wired conformer, render JSON.
# =============================================================================
#
# ── WHAT IT IS FOR ──────────────────────────────────────────────────────────
# A service whose log is written to an object store needs a way to read it back.
# This route is that reader, mounted in the service itself: the service already
# holds the store client its log is written through, so a reader there needs no
# second set of credentials and no second process.
#
# ── WHAT THE EMBEDDING SERVICE SUPPLIES ─────────────────────────────────────
#   | supplied by the service      | what it decides                              |
#   |------------------------------|----------------------------------------------|
#   | the mount `path`             | where the route lives (`is_service_log_request`) |
#   | a `LogReadAccess` hook       | who may read (`access.mojo`)                  |
#   | an `ErasedServiceLogSearch`  | what is read (`search_seam.mojo`), or None    |
#   | `now_ns`                     | the end of the default window                 |
#
# This package fixes none of the four, and reads no env, no clock and no file:
# every branch below is drivable by a test that passes different values.
#
# ── ⛔ ONE 404 FOR EVERY REFUSAL ────────────────────────────────────────────
#   | condition                              | answer |
#   |----------------------------------------|--------|
#   | the hook answers no                    | 404    |
#   | the hook raises                        | 404    |
#   | no reader wired into the service       | 404    |
#
# All three are byte-identical, and identical to the `{"error":"not found"}` a
# service answers for a path it does not serve. A distinguishable 401/403 would
# tell an unauthenticated caller that THIS service has a log-read surface; here
# the thing being hidden is the route itself.
#
# ⚠⚠ THE ORDER OF THE CHECKS IS LOAD-BEARING. ACCESS RUNS FIRST, THEN ARGUMENT
# VALIDITY. If an argument were validated first, an unauthenticated
# `GET <path>?since_ms=9&until_ms=1` would answer 400 on a service with the
# route and 404 on one without it: an existence oracle handed out by the very
# check meant to be non-revealing. Every refused caller sees exactly one
# response.
#
# ── ENCAPSULATION ───────────────────────────────────────────────────────────
# Value-typed: `HttpRequest` (borrowed) in, `HttpResponse` (moved) out. ZERO
# UnsafePointer crosses any boundary; no wildcard origin. NEVER raises: a store
# fault becomes a 500 that names it (it reaches only a caller the hook let
# through, so the fault text is information rather than a leak).
# =============================================================================

from komira_http_core.codec.types import HttpMethod, HttpRequest, HttpResponse

from komira_log_query.access import LogReadAccess
from komira_log_query.hit import (
    ServiceLogHit,
    ServiceLogPage,
    ServiceLogQuery,
)
from komira_log_query.search_seam import ErasedServiceLogSearch


# =============================================================================
# §1 — the query-string vocabulary. Spelled ONCE so the route and the tests
#      cannot disagree about it. The PATH is not here: the service chooses it.
# =============================================================================

comptime SERVICE_LOG_QUERY_PARAM: String = "q"
"""The full-text term(s) to match against the record's `message` field.

⭐ OPTIONAL. Requiring it would encode a property of one at-rest layout, not of
log reading: a layout whose catalog carries no time range can bound a read only
by a term, while a time-partitioned layout bounds it by TIME. So
`?since_ms=`/`?until_ms=` is the primary bound and `?q=` narrows within it."""

comptime SERVICE_LOG_SINCE_PARAM: String = "since_ms"
"""Window start, UNIX epoch MILLISECONDS, INCLUSIVE. Defaults to
`until_ms - SERVICE_LOG_DEFAULT_LOOKBACK_MS`.

⚠ MILLISECONDS, NOT NANOSECONDS OR A DATE STRING. Nanoseconds because a person
types this by hand and a 19-digit literal is a transcription error waiting to
happen; not a date string because parsing one needs a timezone policy, and the
one thing worse than an awkward parameter is a window that silently means a
different hour than the reader meant. A log written from a millisecond wall
clock has no finer resolution anyway, so a millisecond parameter loses
nothing."""

comptime SERVICE_LOG_UNTIL_PARAM: String = "until_ms"
"""Window end, UNIX epoch MILLISECONDS, INCLUSIVE. Defaults to NOW — which the
CALLER supplies as `now_ns`, so this handler still reads no clock and no env and
stays drivable by a test with no process state."""

comptime SERVICE_LOG_DEFAULT_LOOKBACK_MS: Int64 = 2_592_000_000
"""30 days, the DEFAULT window when neither bound is given.

A log bucket whose lifecycle rule deletes at 30 days cannot hold older records,
so a default that reached further back would scan partitions that cannot
contain data. A caller wanting older records passes `since_ms`."""

comptime SERVICE_LOG_LIMIT_PARAM: String = "limit"
"""The page bound. Clamped to `[1, SERVICE_LOG_MAX_LIMIT]`."""

comptime SERVICE_LOG_DEFAULT_LIMIT: Int = 50
"""What a reader gets for `?q=x` with no `limit`. A screenful."""

comptime SERVICE_LOG_MAX_LIMIT: Int = 500
"""The CEILING, clamped rather than refused.

⚠ IT IS A MEMORY BOUND, NOT A COURTESY. Each hit carries the record's whole
`_source` blob, and this runs inside a service instance sized for HTTP, not for
a log query. A refusal would be more honest but would also make the obvious
`?limit=100000` a failed page instead of a big one, and a reader debugging an
outage should not have to bisect a limit."""


# =============================================================================
# §2 — the path match.
# =============================================================================


def is_service_log_request(req: HttpRequest, path: String) -> Bool:
    """True iff this is `GET <path>`, with `path` the mount point the service
    chose.

    EXACT path match and GET only. A prefix match would put every
    `<path>/<anything>` on this handler, a surface with no purpose.

    ⛔ THIS FUNCTION IS NOT A GATE. It answers "is this that path", nothing more;
    a caller that mounts it without calling `service_log_response`, which owns
    every refusal in §3, has mounted an unauthenticated log dump."""
    return req.method == HttpMethod.get() and req.path == path


# =============================================================================
# §3 — the handler. ⭐ THE ONE PLACE THE POLICY IN THE HEADER IS ENFORCED.
# =============================================================================


def service_log_response[
    A: LogReadAccess
](
    mut search: Optional[ErasedServiceLogSearch],
    req: HttpRequest,
    access: A,
    now_ns: Int64,
) -> HttpResponse:
    """Ask the hook, resolve the window, read, render. NEVER raises.

    `search` is the service's wired reader: `None` for a service that never
    configured one, which is INDISTINGUISHABLE from a refusal by construction
    (see the header's refusal table).

    `access` decides who may read. It is required: pass `DenyLogReads()` while
    the service has no policy. Its "no" and its raise are the same 404.

    ⚠ `now_ns` IS A PARAMETER, NOT A CLOCK READ. It anchors the default window's
    upper bound, so the default-window behaviour is testable by passing a
    number rather than by luck.

    ⚠ THE ARGUMENT CHECKS RUN AFTER THE ACCESS CHECK. See the header: inverting
    them turns this route into an existence oracle."""

    # ---- (1) ACCESS. Three conditions, one byte-identical answer. ----
    var allowed = False
    try:
        allowed = access.allows(req)
    except:
        allowed = False
    if not allowed:
        return _not_found()
    if not search:
        return _not_found()

    # ---- (2) ARGUMENT VALIDITY. Only an AUTHORIZED caller ever sees a 400. ----
    #
    # ⭐ `?q=` IS OPTIONAL. The bound is the WINDOW. See
    # `SERVICE_LOG_QUERY_PARAM` — requiring a term would encode a property of
    # one at-rest format (a catalog entry with no time range) into the HTTP
    # surface every reader has to satisfy. An empty term means "everything in
    # the window".
    var q = _query_param_decoded(req.query_string, SERVICE_LOG_QUERY_PARAM)

    var until_p = _query_param_i64(req.query_string, SERVICE_LOG_UNTIL_PARAM)
    var since_p = _query_param_i64(req.query_string, SERVICE_LOG_SINCE_PARAM)
    var until_ms = until_p.or_default(now_ns // Int64(1_000_000))
    var since_ms = since_p.or_default(
        until_ms - SERVICE_LOG_DEFAULT_LOOKBACK_MS
    )
    # ⛔ AN INVERTED WINDOW IS REFUSED, NEVER NORMALISED. Swapping the bounds for
    # the caller would answer a different question than the one asked and look
    # like it worked; returning an empty page would read as "nothing was logged".
    # A bound with more digits than an Int64 holds is beyond the window too: it
    # is refused like the smaller beyond-the-window value, never defaulted.
    var beyond = Optional[String](None)
    if since_p.overflow:
        beyond = _overflows_ns_window(SERVICE_LOG_SINCE_PARAM)
    if not beyond:
        beyond = _beyond_ns_window(SERVICE_LOG_SINCE_PARAM, since_ms)
    if not beyond and until_p.overflow:
        beyond = _overflows_ns_window(SERVICE_LOG_UNTIL_PARAM)
    if not beyond:
        beyond = _beyond_ns_window(SERVICE_LOG_UNTIL_PARAM, until_ms)
    if beyond:
        return _error_json(Int32(400), beyond.value())
    if since_ms > until_ms:
        return _error_json(
            Int32(400),
            String("'")
            + SERVICE_LOG_SINCE_PARAM
            + String("' (")
            + String(since_ms)
            + String(") is after '")
            + SERVICE_LOG_UNTIL_PARAM
            + String("' (")
            + String(until_ms)
            + String(
                "). The window is INCLUSIVE at both ends and is not reordered"
                " for you: a silently swapped window answers a different"
                " question than the one asked."
            ),
        )

    # A limit with more digits than an Int64 holds is clamped to the ceiling,
    # as every other value above it is; a malformed one takes the default.
    var limit_p = _query_param_i64(req.query_string, SERVICE_LOG_LIMIT_PARAM)
    var limit = SERVICE_LOG_MAX_LIMIT
    if not limit_p.overflow:
        var raw = limit_p.or_default(Int64(SERVICE_LOG_DEFAULT_LIMIT))
        limit = Int(min(raw, Int64(SERVICE_LOG_MAX_LIMIT)))
    if limit < 1:
        limit = 1
    if limit > SERVICE_LOG_MAX_LIMIT:
        limit = SERVICE_LOG_MAX_LIMIT

    var query = ServiceLogQuery(
        since_ms * Int64(1_000_000),
        until_ms * Int64(1_000_000),
        q.copy(),
        limit,
    )

    # ---- (3) THE READ. A store fault is surfaced, never folded to an empty
    # page: "the bucket is unreachable" and "nothing matched" are the same
    # zero-hit answer and completely different problems. ----
    var page: ServiceLogPage
    try:
        page = search.value().scan(query)
    except e:
        # ⭐ A TERM-FREE QUERY THAT THE WIRED CONFORMER CANNOT ANSWER IS A 400,
        # NOT A 500, AND IT CARRIES THE CONFORMER'S OWN SENTENCE. It is not a
        # server fault: it is an honest statement that THIS service's at-rest
        # layout cannot bound a read by time alone, and the fix is an argument
        # the caller can supply (`?q=`). A 500 would send a reader hunting a
        # bucket outage that is not happening.
        #
        # ⚠ The discriminator is `has_term()`, NOT the message text. Keying on a
        # substring of an error would silently reclassify the day a conformer
        # rewords itself, and would misclassify a genuine store fault on a
        # term-free query as a client error — so the branch is on what the
        # REQUEST was, which cannot drift.
        # ⚠⚠ A KNOWN RESIDUAL, STATED RATHER THAN LEFT TO BE REDISCOVERED. A
        # TERMED query over an ABSURDLY WIDE window is reported as a 500, and it
        # is really a client error. A conformer that refuses a span wider than
        # its own ceiling (rather than clamping it) can only say so by raising,
        # and that raise arrives here indistinguishable from a store fault. Its
        # message names the span and the ceiling, so the reader is not stuck;
        # only the status code is wrong.
        #
        # ⛔ NOT FIXED WITH A SECOND CEILING HERE, DELIBERATELY. This package is
        # a clean leaf on komira_http_core and cannot import a
        # conformer's constant, so a route-side ceiling would be a RE-SPELLING
        # that can drift — tighter and it refuses queries the reader would have
        # served, looser and the gap is exactly this 500 again. ⛔ AND NOT FIXED
        # BY MATCHING THE ERROR TEXT: that is the same substring-keying this
        # branch's own comment forbids. The honest fix is a typed refusal on the
        # seam (a `ServiceLogRefusal` a conformer returns instead of raising),
        # which is a seam change and belongs in its own slice.
        if not query.has_term():
            return _error_json(
                Int32(400),
                String(
                    "this service's log index cannot answer a time-range"
                    " query with no '"
                )
                + SERVICE_LOG_QUERY_PARAM
                + String("' term: ")
                + String(e),
            )
        return _error_json(
            Int32(500),
            String("log index read failed: ") + String(e),
        )

    return _json_response(
        _render_page(q, limit, since_ms, until_ms, page), Int32(200)
    )


# =============================================================================
# §4 — the JSON rendering.
# =============================================================================


comptime _MAX_WINDOW_MS: Int64 = 9_223_372_036_854
"""The last millisecond whose nanosecond value fits an Int64 (`Int64.MAX //
1_000_000`). The window reaches the conformer in NANOSECONDS, so a larger bound
would wrap to a negative time: a different window from the one asked for."""


def _beyond_ns_window(param: String, ms: Int64) -> Optional[String]:
    """The 400 message for a bound that cannot be expressed in nanoseconds, or
    None when it fits. Refused rather than clamped or wrapped, for the same
    reason the window is not reordered: either would answer a different
    question than the one asked."""
    if ms <= _MAX_WINDOW_MS:
        return None
    return Optional(
        String("'")
        + param
        + String("' (")
        + String(ms)
        + String(") is beyond the last millisecond a nanosecond window can hold (")
        + String(_MAX_WINDOW_MS)
        + String("). A bound that does not fit is refused, not wrapped.")
    )


def _overflows_ns_window(param: String) -> String:
    """The 400 message for a bound with more digits than an Int64 holds. The
    value is not echoed: its length is unbounded."""
    return (
        String("'")
        + param
        + String(
            "' has more digits than an Int64 holds, so it is beyond the last"
            " millisecond a nanosecond window can hold ("
        )
        + String(_MAX_WINDOW_MS)
        + String("). A bound that does not fit is refused, not wrapped.")
    )


def _render_page(
    q: String,
    limit: Int,
    since_ms: Int64,
    until_ms: Int64,
    page: ServiceLogPage,
) -> String:
    """Render one page as `application/json`.

    ⚠ `total` AND `scanned` ARE RENDERED ALWAYS, INCLUDING ON AN EMPTY PAGE, and
    that is the whole reason they exist (`hit.mojo`): without `total` a truncated
    page reads as a complete one, and without `scanned` "the index is empty"
    reads exactly like "your term did not match"."""
    var out = String('{"index":"logs","q":"')
    out += _json_escape(q)
    # ⭐ THE WINDOW IS RENDERED, ALWAYS, INCLUDING WHEN IT WAS DEFAULTED. A
    # reader who omits both bounds gets a 30-day window; without these two
    # fields an empty page would be indistinguishable from "your records are
    # older than the window I silently chose for you".
    out += String('","since_ms":')
    out += String(since_ms)
    out += String(',"until_ms":')
    out += String(until_ms)
    out += String(',"limit":')
    out += String(limit)
    out += String(',"total":')
    out += String(page.total_matches)
    out += String(',"scanned":')
    out += String(page.sources_scanned)
    out += String(',"returned":')
    out += String(len(page.hits))
    out += String(',"hits":[')
    for i in range(len(page.hits)):
        if i > 0:
            out += String(",")
        out += _render_hit(page.hits[i])
    out += String("]}")
    return out^


def _render_hit(hit: ServiceLogHit) -> String:
    """One hit: `{"timestamp_ns":N,"score":F,"source":<blob>}`.

    ⭐ THE EMBED-OR-QUOTE RULE. `source_json` is CONTRACTUALLY a JSON object and
    is embedded VERBATIM when it really is one, so a consumer gets structure
    rather than a string it has to parse twice. But a blob that is not an object
    — a format change, a truncated write, a conformer bug — must not be able to
    produce a MALFORMED response, because malformed JSON is the one failure a
    reader's tooling reports as "the reader is broken" rather than "the data
    is odd". So a non-object blob is emitted as a JSON STRING instead. Both
    shapes are valid JSON, and the string shape IS the signal that something
    below changed.

    ⛔⛔ A FIRST-BYTE `{` CHECK IS NOT SUFFICIENT. A TRUNCATED write — the
    single most likely corruption of a blob that is built by string
    concatenation — starts with `{` too, and embedding it would emit a response
    like `{"...","source":{"message":"half a li` : the route's own stated
    invariant, violated by the check meant to enforce it. `{` is a one-byte
    prefix, and every malformed blob this rule exists to contain starts with it.

    ⭐ THE CHECK IS FULL **SYNTACTIC** VALIDATION (`_is_json_object`) — the
    blob must be exactly one balanced, well-formed RFC-8259 object with nothing
    but whitespace after it. ⛔ IT IS STILL NOT A PARSE, and the distinction is
    the one `hit.mojo` cares about: it validates GRAMMAR and builds no value, so
    it knows nothing about `message`, `level`, `timestamp` or any other field of
    the at-rest record. A future layout can change every key and this function is
    unaffected; it can only ever change what a MALFORMED blob renders as."""
    var out = String('{"timestamp_ns":')
    out += String(hit.timestamp_ns)
    out += String(',"score":')
    if _is_finite(hit.score):
        out += String(hit.score)
    else:
        # NaN and +/-Inf have no JSON spelling (RFC 8259 section 6); `nan` or
        # `inf` in the body would be the malformed response the embed-or-quote
        # rule exists to prevent.
        out += String("null")
    out += String(',"source":')
    if _is_json_object(hit.source_json):
        out += hit.source_json
    else:
        out += String('"')
        out += _json_escape(hit.source_json)
        out += String('"')
    out += String("}")
    return out^


# ---------------------------------------------------------------------------
# §4a — the JSON GRAMMAR validator behind the embed-or-quote rule.
#
# ⛔ A VALIDATOR, NOT A PARSER. It walks RFC-8259 syntax and builds NO value, so
# this package still knows nothing about the at-rest record's field names — the
# decoupling `hit.mojo` exists to preserve. What it guarantees is the one thing
# `_render_hit` promises: an embedded blob cannot make the response malformed.
#
# ITERATIVE, with an explicit container stack rather than recursion, so a
# deeply-nested blob costs heap instead of C stack and the depth bound is a
# number rather than a crash.
# ---------------------------------------------------------------------------

def _is_finite(v: Float64) -> Bool:
    """False for NaN and +/-Inf: `v - v` is NaN for both and 0 otherwise."""
    return (v - v) == Float64(0)


comptime _JSON_MAX_DEPTH: Int = 64
"""Nesting ceiling. A blob deeper than this is treated as NOT an object and gets
quoted — the safe direction. The log `_source` blob is two levels (the record,
plus a nested `args`), so 64 is far above anything the format produces and is
here to bound a hostile or corrupt input, not a real one."""

comptime _JS_OBJ_START: Int = 0
comptime _JS_OBJ_KEY: Int = 1
comptime _JS_OBJ_COLON: Int = 2
comptime _JS_VALUE: Int = 3
comptime _JS_ARR_START: Int = 4
comptime _JS_AFTER_VALUE: Int = 5


def _is_ws(c: UInt8) -> Bool:
    return (
        c == UInt8(ord(" "))
        or c == UInt8(ord("\t"))
        or c == UInt8(ord("\n"))
        or c == UInt8(ord("\r"))
    )


def _skip_ws(b: Span[UInt8, _], i: Int) -> Int:
    var k = i
    while k < len(b) and _is_ws(b[k]):
        k += 1
    return k


def _is_hex(c: UInt8) -> Bool:
    return (
        (c >= UInt8(ord("0")) and c <= UInt8(ord("9")))
        or (c >= UInt8(ord("a")) and c <= UInt8(ord("f")))
        or (c >= UInt8(ord("A")) and c <= UInt8(ord("F")))
    )


def _is_digit(c: UInt8) -> Bool:
    return c >= UInt8(ord("0")) and c <= UInt8(ord("9"))


def _scan_string(b: Span[UInt8, _], i: Int) -> Int:
    """`b[i]` must be `"`. Returns the index AFTER the closing quote, or -1.

    ⚠ AN UNTERMINATED STRING IS THE TRUNCATION CASE and must return -1: it is
    exactly what a half-written blob ends with, and a first-byte `{` check
    would let it through."""
    var n = len(b)
    if i >= n or b[i] != UInt8(ord('"')):
        return -1
    var k = i + 1
    while k < n:
        var c = b[k]
        if c == UInt8(ord('"')):
            return k + 1
        if c == UInt8(ord("\\")):
            if k + 1 >= n:
                return -1
            var e = b[k + 1]
            if e == UInt8(ord("u")):
                if k + 5 >= n:
                    return -1
                for h in range(k + 2, k + 6):
                    if not _is_hex(b[h]):
                        return -1
                k += 6
                continue
            if not (
                e == UInt8(ord('"'))
                or e == UInt8(ord("\\"))
                or e == UInt8(ord("/"))
                or e == UInt8(ord("b"))
                or e == UInt8(ord("f"))
                or e == UInt8(ord("n"))
                or e == UInt8(ord("r"))
                or e == UInt8(ord("t"))
            ):
                return -1
            k += 2
            continue
        if c < UInt8(0x20):
            return -1  # a raw control byte is invalid inside a JSON string
        k += 1
    return -1  # unterminated


def _scan_number(b: Span[UInt8, _], i: Int) -> Int:
    """A JSON number at `b[i]`. Returns the index after it, or -1."""
    var n = len(b)
    var k = i
    if k < n and b[k] == UInt8(ord("-")):
        k += 1
    if k >= n:
        return -1
    if b[k] == UInt8(ord("0")):
        k += 1
    elif _is_digit(b[k]):
        while k < n and _is_digit(b[k]):
            k += 1
    else:
        return -1
    if k < n and b[k] == UInt8(ord(".")):
        k += 1
        if k >= n or not _is_digit(b[k]):
            return -1
        while k < n and _is_digit(b[k]):
            k += 1
    if k < n and (b[k] == UInt8(ord("e")) or b[k] == UInt8(ord("E"))):
        k += 1
        if k < n and (b[k] == UInt8(ord("+")) or b[k] == UInt8(ord("-"))):
            k += 1
        if k >= n or not _is_digit(b[k]):
            return -1
        while k < n and _is_digit(b[k]):
            k += 1
    return k


def _scan_literal(b: Span[UInt8, _], i: Int, word: String) -> Int:
    var w = word.as_bytes()
    if i + len(w) > len(b):
        return -1
    for j in range(len(w)):
        if b[i + j] != w[j]:
            return -1
    return i + len(w)


def _scan_scalar(b: Span[UInt8, _], i: Int) -> Int:
    """A non-container JSON value. Returns the index after it, or -1."""
    if i >= len(b):
        return -1
    var c = b[i]
    if c == UInt8(ord('"')):
        return _scan_string(b, i)
    if c == UInt8(ord("t")):
        return _scan_literal(b, i, String("true"))
    if c == UInt8(ord("f")):
        return _scan_literal(b, i, String("false"))
    if c == UInt8(ord("n")):
        return _scan_literal(b, i, String("null"))
    return _scan_number(b, i)


def _is_json_object(s: String) -> Bool:
    """True iff `s` is EXACTLY ONE well-formed JSON object, with nothing but
    whitespace before and after it.

    ⛔ The `{` first byte is necessary and NOT sufficient — see `_render_hit`.
    Every rejection here means the blob gets rendered as a quoted JSON string,
    which is valid JSON and is the visible signal that something below the seam
    produced something it should not have."""
    var b = s.as_bytes()
    var n = len(b)
    var i = _skip_ws(b, 0)
    if i >= n or b[i] != UInt8(ord("{")):
        return False

    var stack = List[UInt8]()
    stack.append(UInt8(ord("{")))
    i += 1
    var state = _JS_OBJ_START

    while len(stack) > 0:
        if len(stack) > _JSON_MAX_DEPTH:
            return False
        i = _skip_ws(b, i)
        if i >= n:
            return False  # ran out of input mid-structure: the truncation case
        var c = b[i]

        if state == _JS_OBJ_START or state == _JS_OBJ_KEY:
            if state == _JS_OBJ_START and c == UInt8(ord("}")):
                _ = stack.pop()
                i += 1
                state = _JS_AFTER_VALUE
                continue
            var k = _scan_string(b, i)
            if k < 0:
                return False
            i = k
            state = _JS_OBJ_COLON
        elif state == _JS_OBJ_COLON:
            if c != UInt8(ord(":")):
                return False
            i += 1
            state = _JS_VALUE
        elif state == _JS_ARR_START:
            if c == UInt8(ord("]")):
                _ = stack.pop()
                i += 1
                state = _JS_AFTER_VALUE
                continue
            state = _JS_VALUE
            continue  # re-dispatch on the SAME byte, which starts a value
        elif state == _JS_VALUE:
            if c == UInt8(ord("{")):
                stack.append(UInt8(ord("{")))
                i += 1
                state = _JS_OBJ_START
            elif c == UInt8(ord("[")):
                stack.append(UInt8(ord("[")))
                i += 1
                state = _JS_ARR_START
            else:
                var k2 = _scan_scalar(b, i)
                if k2 < 0:
                    return False
                i = k2
                state = _JS_AFTER_VALUE
        else:  # _JS_AFTER_VALUE
            var top = stack[len(stack) - 1]
            if top == UInt8(ord("{")):
                if c == UInt8(ord(",")):
                    i += 1
                    state = _JS_OBJ_KEY
                elif c == UInt8(ord("}")):
                    _ = stack.pop()
                    i += 1
                else:
                    return False
            else:
                if c == UInt8(ord(",")):
                    i += 1
                    state = _JS_VALUE
                elif c == UInt8(ord("]")):
                    _ = stack.pop()
                    i += 1
                else:
                    return False

    # Exactly ONE value: only whitespace may follow the closing brace. A blob of
    # `{}{}` is two objects concatenated and embedding it would be malformed.
    return _skip_ws(b, i) >= n


def _json_escape(s: String) -> String:
    """Minimal RFC-8259 string escaping (`"`, `\\`, the three named controls, and
    `\\u00XX` for the rest of C0). Hand-rolled so this package stays a clean leaf
    on komira_http_core alone."""
    var b = s.as_bytes()
    var out = List[UInt8]()
    var i = 0
    var n = len(b)
    while i < n:
        var c = Int(b[i])
        if c == ord('"'):
            _append_str(out, '\\"')
        elif c == ord("\\"):
            _append_str(out, "\\\\")
        elif c == ord("\n"):
            _append_str(out, "\\n")
        elif c == ord("\r"):
            _append_str(out, "\\r")
        elif c == ord("\t"):
            _append_str(out, "\\t")
        elif c < 0x20:
            var hb = "0123456789abcdef".as_bytes()
            _append_str(out, "\\u00")
            out.append(hb[(c >> 4) & 0xF])
            out.append(hb[c & 0xF])
        elif c < 0x80:
            out.append(b[i])
        else:
            # A multi-byte sequence is copied byte for byte when it is
            # well-formed UTF-8. Appending each byte as a code point (`chr`)
            # would re-encode it: "\u00e9" (c3 a9) would become c3 83 c2 a9.
            # A byte that starts no well-formed sequence (a percent-decoded
            # %FF, a lone continuation byte) becomes U+FFFD, so the body stays
            # valid UTF-8, which RFC 8259 requires of JSON.
            var k = _utf8_seq_len(b, i)
            if k == 0:
                _append_str(out, "\\ufffd")
            else:
                for j in range(k):
                    out.append(b[i + j])
                i += k
                continue
        i += 1
    return String(unsafe_from_utf8=out^)


def _append_str(mut out: List[UInt8], s: String):
    var sb = s.as_bytes()
    for i in range(len(sb)):
        out.append(sb[i])


def _utf8_seq_len(b: Span[UInt8, _], i: Int) -> Int:
    """The length of the well-formed UTF-8 sequence (RFC 3629 section 4)
    starting at `b[i]`, a byte >= 0x80; 0 when none starts there (a
    continuation byte, an overlong lead, a surrogate, past U+10FFFF, or a
    sequence cut short by the end of `b`)."""
    var n = len(b)
    var c = Int(b[i])
    var need = 0
    var lo = 0x80
    var hi = 0xBF
    if c >= 0xC2 and c <= 0xDF:
        need = 1
    elif c >= 0xE0 and c <= 0xEF:
        need = 2
        if c == 0xE0:
            lo = 0xA0
        elif c == 0xED:
            hi = 0x9F
    elif c >= 0xF0 and c <= 0xF4:
        need = 3
        if c == 0xF0:
            lo = 0x90
        elif c == 0xF4:
            hi = 0x8F
    else:
        return 0
    if i + need >= n:
        return 0
    var c1 = Int(b[i + 1])
    if c1 < lo or c1 > hi:
        return 0
    for k in range(2, need + 1):
        var ck = Int(b[i + k])
        if ck < 0x80 or ck > 0xBF:
            return 0
    return need + 1


def _json_response(var body: String, status: Int32) -> HttpResponse:
    """An `application/json` response with an accurate `content-length`. Inlined
    so a service that mounts this route needs no HTTP helper package beyond
    komira_http_core."""
    var r = HttpResponse(status=status)
    r.headers[String("content-type")] = String("application/json")
    var bytes_ref = body.as_bytes()
    var n = len(bytes_ref)
    var i = 0
    while i < n:
        r.body.append(bytes_ref[i])
        i = i + 1
    r.headers[String("content-length")] = String(n)
    return r^


def _error_json(status: Int32, var message: String) -> HttpResponse:
    """`{"error": "..."}`."""
    return _json_response(
        String('{"error":"') + _json_escape(message) + String('"}'), status
    )


def _not_found() -> HttpResponse:
    """⭐ THE ONE REFUSAL. Every refused and unwired case returns THIS,
    byte-identical, so no caller can tell them apart. See the header's refusal
    table.

    A service that wants a refused request to look exactly like an unserved
    path answers its own unknown paths with this same body,
    `{"error":"not found"}`."""
    return _error_json(Int32(404), String("not found"))


# =============================================================================
# §5 — request parsing helpers.
# =============================================================================


def _query_param_decoded(query_string: String, key: String) -> String:
    """`key`'s value out of a `k=v&k=v` query string (NO leading '?', the
    `HttpRequest.query_string` shape), PERCENT- AND PLUS-DECODED. "" when absent
    or empty.

    ⚠ IT DECODES, ON PURPOSE. A parser whose value feeds an AUTHORIZATION
    decision should refuse to decode, so a half-understood value is refused
    rather than silently reinterpreted. This parameter is the opposite kind of
    input: a SEARCH TERM, which is handed to an analyzer and can match nothing
    worse than the wrong records. A reader searching for `deploy failed` types
    a space,
    and a non-decoding parser would silently search for the single token
    `deploy%20failed` and answer "no matches" — indistinguishable from a real
    absence, which is exactly the failure this whole route exists to end.

    A malformed `%` escape is passed through as a literal `%` rather than
    refused: the value reaches an analyzer, not a decision."""
    var qb = query_string.as_bytes()
    var kb = key.as_bytes()
    var n = len(qb)
    var i = 0
    while i < n:
        var seg_end = i
        while seg_end < n and qb[seg_end] != UInt8(ord("&")):
            seg_end += 1
        var eq = i
        while eq < seg_end and qb[eq] != UInt8(ord("=")):
            eq += 1
        var klen = eq - i
        if klen == len(kb):
            var matched = True
            for j in range(klen):
                if qb[i + j] != kb[j]:
                    matched = False
                    break
            if matched and eq < seg_end:
                var out = List[UInt8]()
                var j = eq + 1
                while j < seg_end:
                    var c = qb[j]
                    if c == UInt8(ord("+")):
                        out.append(UInt8(ord(" ")))
                        j += 1
                    elif c == UInt8(ord("%")) and j + 2 < seg_end:
                        var hi = _hex_val(qb[j + 1])
                        var lo = _hex_val(qb[j + 2])
                        if hi >= 0 and lo >= 0:
                            out.append(UInt8(hi * 16 + lo))
                            j += 3
                        else:
                            out.append(c)
                            j += 1
                    else:
                        out.append(c)
                        j += 1
                if len(out) == 0:
                    return String("")
                return String(unsafe_from_utf8=out)
        i = seg_end + 1
    return String("")


def _hex_val(c: UInt8) -> Int:
    """One hex digit -> 0..15, or -1 when `c` is not a hex digit."""
    if c >= UInt8(ord("0")) and c <= UInt8(ord("9")):
        return Int(c) - ord("0")
    if c >= UInt8(ord("a")) and c <= UInt8(ord("f")):
        return Int(c) - ord("a") + 10
    if c >= UInt8(ord("A")) and c <= UInt8(ord("F")):
        return Int(c) - ord("A") + 10
    return -1


comptime _I64_MAX: Int64 = 9_223_372_036_854_775_807


@fieldwise_init
struct _I64Param(Copyable, Movable):
    """One numeric query parameter as read: its value, or that it was absent or
    malformed, or that it was all digits and more of them than an Int64
    holds."""

    var value: Int64
    var present: Bool
    var overflow: Bool

    def or_default(self, default: Int64) -> Int64:
        if self.present:
            return self.value
        return default


def _query_param_i64(query_string: String, key: String) -> _I64Param:
    """`key`'s value as an Int64. Absent, empty or non-numeric is not
    `present`, and the caller takes its default. A value of digits only with
    more of them than an Int64 holds is `overflow`, not malformed: it is a
    number larger than any the caller accepts, and each caller treats it as
    it treats its largest value. Spelled here so this package stays a clean
    leaf."""
    var qb = query_string.as_bytes()
    var kb = key.as_bytes()
    var n = len(qb)
    var i = 0
    while i < n:
        var seg_end = i
        while seg_end < n and qb[seg_end] != UInt8(ord("&")):
            seg_end += 1
        var eq = i
        while eq < seg_end and qb[eq] != UInt8(ord("=")):
            eq += 1
        var klen = eq - i
        if klen == len(kb):
            var matched = True
            for j in range(klen):
                if qb[i + j] != kb[j]:
                    matched = False
                    break
            if matched and eq < seg_end:
                var val = Int64(0)
                var overflow = False
                if eq + 1 == seg_end:
                    return _I64Param(Int64(0), False, False)
                for j in range(eq + 1, seg_end):
                    var c = qb[j]
                    if c < UInt8(ord("0")) or c > UInt8(ord("9")):
                        return _I64Param(Int64(0), False, False)
                    if overflow:
                        continue
                    var d = Int64(Int(c) - ord("0"))
                    # A wrapping parse would read 2^64 + 1 as 1.
                    if val > (_I64_MAX - d) // Int64(10):
                        overflow = True
                    else:
                        val = val * Int64(10) + d
                if overflow:
                    return _I64Param(_I64_MAX, False, True)
                return _I64Param(val, True, False)
        i = seg_end + 1
    return _I64Param(Int64(0), False, False)
