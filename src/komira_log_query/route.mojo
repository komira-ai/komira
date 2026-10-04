# =============================================================================
# komira_log_query/route.mojo — THE MOUNTABLE ROUTE: match `GET /internal/logs`,
#   authorize it, read the service's own operational log, render the JSON.
# =============================================================================
#
# ── WHAT IT IS FOR ──────────────────────────────────────────────────────────
# A service that installs `ServiceLogSink` (`komira_log_index`) switches its
# log drain: before the install a bare `log.info[...]` takes the synchronous
# stderr path; after it, the same call leaves the process as an object-store
# `.split`. The sink can MIRROR to stderr as well, but stderr is neither durable
# past the instance nor searchable. Without a reader, the service's operational
# log accumulates in a bucket nothing deployed can open. THIS IS THE READER.
#
# ── ★ IT IS A ROUTE, NOT A SERVICE ──────────────────────────────────────────
# A reader of these splits needs exactly three things — the search engine, its
# object-store binding and the expression evaluator (`komira_search`,
# `komira_search_s3`, `komira_eval`) — and a service that installed the sink
# already links all three. Mounting a route costs that service nothing.
#
# A standalone search server is the right FORMAT reader and can be the wrong
# DEPLOYMENT: if it is bound to one object-store client while the service writes
# through another, bridging the two needs interop credentials. A route in the
# writing service reads through the store it already holds.
#
# ── ★★ THE AUTHORIZATION MODEL, STATED RATHER THAN ASSUMED ──────────────────
# WHO MAY READ THIS: **the operator, and nobody else.** Not a customer, not an
# org admin, not a tenant-scoped anything. The reason is structural and is not a
# policy choice this route is free to revisit:
#
#   * these are the service's OWN diagnostics, emitted from across its binary;
#   * they name OTHER tenants' org ids, run ids, project ids, resource names and
#     failure reasons, in one undifferentiated stream;
#   * and they cannot be split per tenant: a service-level record carries no
#     `org_id` and no `run_id`, so it cannot be filed into a tenant's readable
#     keyspace without inventing an attribution.
#
# A customer's genuinely run-scoped narration belongs in a DIFFERENT,
# tenant-scoped sink, read through a DIFFERENT, tenant-gated route that checks
# the caller's org against the run's own `org_id`.
# ⛔ DO NOT "unify" the two. They differ in audience, in key root, and in whether
# a record carries a tenant anchor at all.
#
# ── ⛔ FAIL-CLOSED, AND 404 FOR EVERY REFUSAL ───────────────────────────────
# THREE refusals, ONE response, byte-identical:
#
#   | condition                        | answer |
#   |----------------------------------|--------|
#   | no expected token configured     | 404    |
#   | wrong / absent presented token   | 404    |
#   | no reader wired into the service | 404    |
#
# ⚠ FAIL-CLOSED WHEN UNCONFIGURED, ON PURPOSE. A gate that ALLOWS every caller
# when its token is unset (relying on a network or ingress gate instead) can be
# a defensible trade for a verb like a reconcile tick. It is not defensible for
# a verb that returns the service's entire operational log: a route that is open
# whenever somebody forgot to configure it is open exactly when nobody is
# looking. An unconfigured deployment therefore has NO log-read surface at all.
#
# ⚠ AND 404 RATHER THAN 401/403, WHICH IS NOT PEDANTRY. A distinguishable
# refusal tells an unauthenticated caller that THIS DEPLOYMENT HAS AN
# OPERATIONAL-LOG SURFACE — the one fact an attacker learns for free from a
# fixed path. Un-addressable and un-entitled must be indistinguishable; here
# there is no id to protect, so the thing being hidden is the route itself.
#
# ⚠⚠ THE ORDER OF THE CHECKS IS LOAD-BEARING. AUTHORIZATION RUNS FIRST, THEN
# ARGUMENT VALIDITY. If an argument were validated first, then
# `GET /internal/logs` with no token would answer **400 for this service and 404
# for one without the route** — an existence oracle handed out by the very check
# meant to be non-revealing. Every unauthorized caller sees exactly one response.
#
# ⛔ NO ENV IS READ HERE. `expected_token` arrives as a `String` the caller
# already resolved, exactly as `ServiceLogSink` takes a built store rather than a
# bucket name. That is what makes the whole policy above drivable by a test with
# no process state.
#
# ⚠ THE TOKEN IS SECRET MATERIAL, SO THE CALLER MUST NOT TAKE IT FROM ARGV.
# `/proc/<pid>/cmdline` is world-readable, and the same string lands in `ps`, the
# revision spec and every deploy audit log. The caller fetches it from its secret
# store (by a name it was configured with) and passes the value here.
#
# ── ENCAPSULATION ───────────────────────────────────────────────────────────
# Value-typed: `HttpRequest` (borrowed) in, `HttpResponse` (moved) out. ZERO
# UnsafePointer crosses any boundary; no wildcard origin. NEVER raises — a store
# fault becomes a 500 that names it (this response reaches only an authorized
# operator, so the fault text is information rather than a leak).
# =============================================================================

from komira_http_core.codec.types import HttpMethod, HttpRequest, HttpResponse

from komira_log_query.hit import (
    ServiceLogHit,
    ServiceLogPage,
    ServiceLogQuery,
)
from komira_log_query.search_seam import ErasedServiceLogSearch


# =============================================================================
# §1 — the wire vocabulary. Spelled ONCE so the route, the caller's gate and the
#      tests cannot disagree about it.
# =============================================================================

comptime SERVICE_LOG_ROUTE_PATH: String = "/internal/logs"
"""The mount point. `/internal/*` is the operator / service-account prefix, so
the path itself states the audience.

⛔ NOT under a customer-facing, tenant-gated prefix that a front door proxies;
an operator-only verb sitting inside one is one copy-pasted route arm away from
being proxied too."""

comptime SERVICE_LOG_TOKEN_HEADER: String = "x-komira-log-read-token"
"""The DEDICATED header the app-level token rides. Lowercased — the H1 parser
canonicalizes header names.

⚠ NOT `Authorization`: behind PRIVATE Cloud Run ingress the front end validates
the caller's Google OIDC ID token against the service's `aud` + `run.invoker`
grant and then FORWARDS the request WITH that ID token still in `Authorization`.
By the time the app runs, `Authorization` carries the platform's token, not ours.
A distinct header is what lets BOTH auth layers coexist.

⚠ AND IT IS ITS OWN SECRET, NOT a token shared with another internal verb.
Reusing, say, a reconcile token would mean every service account that may POST a
reconcile tick may also read the whole operational log. Same custody, wildly
different blast radius."""

comptime SERVICE_LOG_QUERY_PARAM: String = "q"
"""The full-text term(s) to match against the record's `message` field.

⭐ OPTIONAL. Requiring it would encode a property of the SPLIT FORMAT, not of
log reading: the split catalog entry carries no time range at all, so for splits
a term is the only bound a reader has. The time-partitioned at-rest format
bounds by TIME, so `?since_ms=`/`?until_ms=` is the primary bound and `?q=`
narrows within it — which is exactly what a customer's own direct query over
their bucket does."""

comptime SERVICE_LOG_SINCE_PARAM: String = "since_ms"
"""Window start, UNIX epoch MILLISECONDS, INCLUSIVE. Defaults to
`until_ms - SERVICE_LOG_DEFAULT_LOOKBACK_MS`.

⚠ MILLISECONDS, NOT NANOSECONDS OR A DATE STRING. Nanoseconds because an operator
types this by hand and a 19-digit literal is a transcription error waiting to
happen; not a date string because parsing one needs a timezone policy, and the
one thing worse than an awkward parameter is a window that silently means a
different hour than the operator meant. The log index's own resolution is ONE
MILLISECOND anyway (the sink stamps `wall_ms * 1_000_000`), so a
millisecond parameter loses exactly nothing."""

comptime SERVICE_LOG_UNTIL_PARAM: String = "until_ms"
"""Window end, UNIX epoch MILLISECONDS, INCLUSIVE. Defaults to NOW — which the
CALLER supplies as `now_ns`, so this handler still reads no clock and no env and
stays drivable by a test with no process state."""

comptime SERVICE_LOG_DEFAULT_LOOKBACK_MS: Int64 = 2_592_000_000
"""30 days, the DEFAULT window when neither bound is given.

⚠ IT MATCHES THE DEFAULT LOG RETENTION, NOT A ROUND NUMBER. A log bucket whose
lifecycle rule deletes at 30 days cannot hold older records, so a default that
reached further back would scan day partitions that CANNOT contain data — cost
with no possible result. Widening this without widening retention buys nothing;
narrowing it hides records that still exist."""

comptime SERVICE_LOG_LIMIT_PARAM: String = "limit"
"""The page bound. Clamped to `[1, SERVICE_LOG_MAX_LIMIT]`."""

comptime SERVICE_LOG_DEFAULT_LIMIT: Int = 50
"""What an operator gets for `?q=x` with no `limit`. A screenful."""

comptime SERVICE_LOG_MAX_LIMIT: Int = 500
"""The CEILING, clamped rather than refused.

⚠ IT IS A MEMORY BOUND, NOT A COURTESY. Each hit carries the record's whole
`_source` blob, and this runs inside a service instance sized for HTTP, not for
a log query. A refusal would be more honest but would also make the obvious
`?limit=100000` a failed page instead of a big one, and an operator debugging an
outage should not have to bisect a limit."""


# =============================================================================
# §2 — the path match.
# =============================================================================


def is_service_log_request(req: HttpRequest) -> Bool:
    """True iff this is `GET /internal/logs`.

    EXACT path match and GET only. A prefix match would put every
    `/internal/logs/<anything>` on this handler — a surface with no purpose and
    one more thing for a future reader to reason about.

    ⛔ THIS FUNCTION IS NOT A GATE. It answers "is this that path", nothing more;
    a caller that mounts it without calling `service_log_response` — which owns
    every refusal in §3 — has mounted an unauthenticated log dump."""
    return (
        req.method == HttpMethod.get()
        and req.path == SERVICE_LOG_ROUTE_PATH
    )


# =============================================================================
# §3 — the handler. ⭐ THE ONE PLACE THE POLICY IN THE HEADER IS ENFORCED.
# =============================================================================


def service_log_response(
    mut search: Optional[ErasedServiceLogSearch],
    req: HttpRequest,
    expected_token: String,
    now_ns: Int64,
) -> HttpResponse:
    """Authorize, resolve the window, read, render. NEVER raises.

    `search` is the service's wired reader — `None` for a service that never
    configured a log sink, which is INDISTINGUISHABLE from unauthorized by
    construction (see the header's refusal table).

    `expected_token` is the operator secret the caller resolved. EMPTY means the
    route is DISABLED, not that everything is allowed.

    ⚠ `now_ns` IS A PARAMETER, NOT A CLOCK READ. It anchors the default window's
    upper bound. The same division of duty as `expected_token`: this handler
    touches NO process state — no env, no clock — which is what makes every
    branch below drivable by a test that just passes different numbers. A
    `time.now()` call here would make the default-window behaviour untestable
    except by luck.

    ⚠ THE ARGUMENT CHECKS RUN AFTER THE AUTH CHECKS. See the header — inverting
    them turns this route into an existence oracle."""

    # ---- (1) AUTHORIZATION. Three conditions, one byte-identical answer. ----
    if expected_token.byte_length() == 0:
        return _not_found()
    var presented = _token_from_request(req)
    if presented.byte_length() == 0:
        return _not_found()
    if not _const_time_eq(presented, expected_token):
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

    var until_ms = _query_param_i64(
        req.query_string,
        SERVICE_LOG_UNTIL_PARAM,
        now_ns // Int64(1_000_000),
    )
    var since_ms = _query_param_i64(
        req.query_string,
        SERVICE_LOG_SINCE_PARAM,
        until_ms - SERVICE_LOG_DEFAULT_LOOKBACK_MS,
    )
    # ⛔ AN INVERTED WINDOW IS REFUSED, NEVER NORMALISED. Swapping the bounds for
    # the caller would answer a different question than the one asked and look
    # like it worked; returning an empty page would read as "nothing was logged".
    var beyond = _beyond_ns_window(SERVICE_LOG_SINCE_PARAM, since_ms)
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

    var limit = Int(
        _query_param_i64(
            req.query_string,
            SERVICE_LOG_LIMIT_PARAM,
            Int64(SERVICE_LOG_DEFAULT_LIMIT),
        )
    )
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
        # server fault: it is an honest statement that THIS deployment's at-rest
        # format cannot bound a read by time alone, and the fix is an argument
        # the caller can supply (`?q=`). A 500 would send an operator hunting a
        # bucket outage that is not happening.
        #
        # ⚠ The discriminator is `has_term()`, NOT the message text. Keying on a
        # substring of an error would silently reclassify the day a conformer
        # rewords itself, and would misclassify a genuine store fault on a
        # term-free query as a client error — so the branch is on what the
        # REQUEST was, which cannot drift.
        # ⚠⚠ A KNOWN RESIDUAL, STATED RATHER THAN LEFT TO BE REDISCOVERED. A
        # TERMED query over an ABSURDLY WIDE window is reported as a 500, and it
        # is really a client error. `TelemetryLogSearch` refuses a span over
        # `TELEMETRY_MAX_DAYS_PER_SCAN` (400 days) rather than clamping it, and
        # that refusal arrives here as a raise indistinguishable from a store
        # fault. The message it carries is fully diagnostic — it names the span,
        # the ceiling, and why a clamp would be worse — so an operator is not
        # stuck; only the status code is wrong.
        #
        # ⛔ NOT FIXED WITH A SECOND CEILING HERE, DELIBERATELY. This package is
        # a clean leaf on komira_http and cannot import the
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
                    "this deployment's log index cannot answer a time-range"
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
    # ⭐ THE WINDOW IS RENDERED, ALWAYS, INCLUDING WHEN IT WAS DEFAULTED. An
    # operator who omits both bounds gets a 30-day window; without these two
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
    produce a MALFORMED response, because malformed JSON is the one failure an
    operator's tooling reports as "the reader is broken" rather than "the data
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
    on komira_http alone."""
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
    rather than taken from `komira_handler_kit`: a dispatcher that mounts this
    route need not link that package, and adding it to reuse eight lines would
    grow a closure to save none."""
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
    """`{"error": "..."}`, matching the shape every other route on this service
    emits."""
    return _json_response(
        String('{"error":"') + _json_escape(message) + String('"}'), status
    )


def _not_found() -> HttpResponse:
    """⭐ THE ONE REFUSAL. Every unauthorized, unconfigured and unwired case
    returns THIS — byte-identical, so no caller can tell them apart. See the
    header's refusal table.

    The body matches the dispatcher's own catch-all `_error_json(404, "not
    found")` so that a service WITHOUT this route mounted and a service WITH it
    but refusing are indistinguishable on the wire, not merely equal in status."""
    return _error_json(Int32(404), String("not found"))


# =============================================================================
# §5 — request parsing helpers.
# =============================================================================


def _token_from_request(req: HttpRequest) -> String:
    """The RAW app-level token off `SERVICE_LOG_TOKEN_HEADER` (NO `Bearer `
    scheme prefix — see the constant). "" when absent. Non-raising."""
    var maybe = req.headers.get(SERVICE_LOG_TOKEN_HEADER)
    if not maybe:
        return String("")
    return maybe.value()


def _const_time_eq(a: String, b: String) -> Bool:
    """A length-checked, branch-uniform compare for the token (no early exit on
    the first mismatched byte). Not a hardware-constant-time primitive — it is
    spelled here so this package stays a clean leaf — but it removes the
    trivially-obvious early-return timing signal."""
    var ab = a.as_bytes()
    var bb = b.as_bytes()
    if len(ab) != len(bb):
        return False
    var diff = UInt8(0)
    for i in range(len(ab)):
        diff = diff | (ab[i] ^ bb[i])
    return diff == UInt8(0)


def _query_param_decoded(query_string: String, key: String) -> String:
    """`key`'s value out of a `k=v&k=v` query string (NO leading '?', the
    `HttpRequest.query_string` shape), PERCENT- AND PLUS-DECODED. "" when absent
    or empty.

    ⚠ IT DECODES, AND A TENANCY PARSER DELIBERATELY DOES NOT. A parser whose
    consumer is `?org=<uuid>`, an AUTHORIZATION input, must refuse to decode: a
    half-understood value must fail the uuid parse and be refused rather than
    silently reinterpreted. This parameter is the opposite kind of input: a
    SEARCH TERM, which is handed to an analyzer and can match nothing worse than
    the wrong records. An operator searching for `deploy failed` types a space,
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


def _query_param_i64(
    query_string: String, key: String, default: Int64
) -> Int64:
    """`key`'s value as an Int64, or `default` when absent / empty /
    non-numeric. Spelled here so this package stays a clean leaf. A malformed
    value, including one with more digits than an Int64 holds, falls back to
    the default rather than erroring the request."""
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
                var any_digit = False
                var ok = True
                for j in range(eq + 1, seg_end):
                    var c = qb[j]
                    if c >= UInt8(ord("0")) and c <= UInt8(ord("9")):
                        var d = Int64(Int(c) - ord("0"))
                        # More digits than an Int64 holds is malformed: a
                        # wrapping parse would read 2^64 + 1 as 1.
                        if val > (_I64_MAX - d) // Int64(10):
                            ok = False
                            break
                        val = val * Int64(10) + d
                        any_digit = True
                    else:
                        ok = False
                        break
                if ok and any_digit:
                    return val
                return default
        i = seg_end + 1
    return default
