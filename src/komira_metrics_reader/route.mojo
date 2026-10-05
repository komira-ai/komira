# =============================================================================
# komira_metrics_reader/route.mojo: THE MOUNTABLE ROUTE. Match `GET <path>`,
#   ask the service's access hook, read through the wired reader, render JSON.
# =============================================================================
#
# The shape of komira_log_query's route, for a metric:
#
#   | supplied by the service    | what it decides                               |
#   |----------------------------|-----------------------------------------------|
#   | the mount `path`           | where the route lives (`is_metrics_request`)  |
#   | a `MetricsReadAccess` hook | who may read (`access.mojo`)                  |
#   | an `ErasedMetricsReader`   | what is read (`reader.mojo`), or None         |
#   | `now_ns`                   | the end of the default window                 |
#
# This package fixes none of them and reads no env, no clock and no file.
#
# ── ⛔ ONE 404 FOR EVERY REFUSAL, AND ACCESS RUNS FIRST ─────────────────────
# A hook that says no, a hook that raises and a service with no reader wired
# all answer the same byte-identical `{"error":"not found"}`. Arguments are
# checked only after access: validating first would answer 400 on a service
# with the route and 404 on one without it, an existence oracle.
#
# ── THE STATUS OF EVERY OTHER ANSWER ────────────────────────────────────────
#   | condition                                        | answer |
#   |--------------------------------------------------|--------|
#   | a missing `metric`, a malformed or inverted bound, an unknown `agg`, a malformed number, a parameter not UTF-8 once decoded, an unknown or repeated parameter | 400 |
#   | the reader refuses the query (`MetricsReader.refusal`) | 400, its sentence |
#   | the reader raises while reading                  | 500, naming it |
#   | an answer                                        | 200    |
#
# ⚠ A PRESENT BUT MALFORMED NUMBER IS A 400, NOT A DEFAULT. A window that
# silently became the default hour answers a different question than the one
# asked, and a metric answer, unlike a log line, never looks wrong.
#
# ⚠ SO IS AN UNKNOWN OR REPEATED PARAMETER. A key that is not one of §1's
# names and not a `label.<k>` / `not_label.<k>` with a non-empty `<k>` is a
# 400 naming it: a misspelled `since_ms` ignored would be the default window
# by another road. A key given twice is a 400 naming it, rather than keeping
# one of its values.
#
# Encapsulation: `HttpRequest` borrowed in, `HttpResponse` moved out. No
# pointer. Never raises.
# =============================================================================

from komira_http_core.codec.types import HttpMethod, HttpRequest, HttpResponse

from komira_metrics_reader.access import MetricsReadAccess
from komira_metrics_reader.query import (
    MetricsAggregation,
    MetricsMatcher,
    MetricsQuery,
)
from komira_metrics_reader.reader import ErasedMetricsReader
from komira_metrics_reader.series import MetricsPage, MetricsSeriesData


# =============================================================================
# §1 — the query-string vocabulary, spelled once.
# =============================================================================

comptime METRICS_METRIC_PARAM: String = "metric"
"""The metric to read. Required."""

comptime METRICS_SINCE_PARAM: String = "since_ms"
"""Window start, UNIX epoch MILLISECONDS, inclusive. Defaults to
`until_ms - METRICS_DEFAULT_LOOKBACK_MS`."""

comptime METRICS_UNTIL_PARAM: String = "until_ms"
"""Window end, UNIX epoch MILLISECONDS, inclusive. Defaults to the caller's
`now_ns`."""

comptime METRICS_STEP_PARAM: String = "step_ms"
"""The aggregation step in milliseconds, positive. Defaults to
`METRICS_DEFAULT_STEP_MS`. A reader whose store has a coarser grain refuses
a step it cannot honour."""

comptime METRICS_AGG_PARAM: String = "agg"
"""The aggregation: `raw`, `sum`, `rate`, `mean`, `min`, `max` or `count`.
Defaults to `raw`."""

comptime METRICS_GROUP_BY_PARAM: String = "group_by"
"""Label keys to group by, comma-separated. Absent keeps every series
apart."""

comptime METRICS_LABEL_PREFIX: String = "label."
"""`label.<key>=<value>`: the series' label `key` equals `value`."""

comptime METRICS_NOT_LABEL_PREFIX: String = "not_label."
"""`not_label.<key>=<value>`: the series' label `key` is not `value`."""

comptime METRICS_SERIES_LIMIT_PARAM: String = "series_limit"
comptime METRICS_POINT_LIMIT_PARAM: String = "point_limit"

comptime METRICS_DEFAULT_LOOKBACK_MS: Int64 = 3_600_000
"""One hour, the default window: what a reader of a dashboard panel asks
for first, and a bounded read on any store."""

comptime METRICS_DEFAULT_STEP_MS: Int64 = 60_000
"""One minute, the finest step both cloud metric services keep for
standard-resolution data."""

comptime METRICS_DEFAULT_SERIES_LIMIT: Int = 100
comptime METRICS_MAX_SERIES_LIMIT: Int = 1000
comptime METRICS_DEFAULT_POINT_LIMIT: Int = 1440
"""One day at the default step."""
comptime METRICS_MAX_POINT_LIMIT: Int = 100_000
"""The ceilings are clamped, not refused: they bound memory on a service
instance sized for HTTP, and `truncated` in the answer says when they cut."""


# =============================================================================
# §2 — the path match.
# =============================================================================


def is_metrics_request(req: HttpRequest, path: String) -> Bool:
    """True iff this is `GET <path>`, an exact match. Not a gate: a service
    that mounts it without `metrics_response`, which owns every refusal, has
    mounted an unauthenticated read."""
    return req.method == HttpMethod.get() and req.path == path


# =============================================================================
# §3 — the handler.
# =============================================================================


def metrics_response[
    A: MetricsReadAccess
](
    mut reader: Optional[ErasedMetricsReader],
    req: HttpRequest,
    access: A,
    now_ns: Int64,
) -> HttpResponse:
    """Ask the hook, check the arguments, ask the reader for a refusal, read,
    render. Never raises. `now_ns` is a parameter, not a clock read."""

    # ---- (1) ACCESS. Three conditions, one byte-identical answer. ----
    var allowed = False
    try:
        allowed = access.allows(req)
    except:
        allowed = False
    if not allowed:
        return _not_found()
    if not reader:
        return _not_found()

    # ---- (2) ARGUMENTS. Only an authorized caller sees a 400. ----
    var params = _decoded_params(req.query_string)
    var built = _query_from(params, now_ns)
    if built.error.byte_length() > 0:
        return _error_json(Int32(400), built.error)
    var q = built.query.copy()

    # ---- (3) THE READER'S OWN REFUSAL: a limit of its store, the caller's
    # to work around, so a 400 carrying the reader's sentence. ----
    var why = reader.value().refusal(q)
    if why.byte_length() > 0:
        return _error_json(
            Int32(400), String("this metrics reader cannot answer: ") + why
        )

    # ---- (4) THE READ. A fault is surfaced, never folded to an empty page:
    # "the provider is unreachable" and "no points in the window" are the
    # same empty answer and different problems. ----
    var page: MetricsPage
    try:
        page = reader.value().read(q)
    except e:
        return _error_json(
            Int32(500), String("metrics read failed: ") + String(e)
        )
    return _json_response(_render_page(q, page), Int32(200))


# =============================================================================
# §4 — building the query from the parameters.
# =============================================================================


@fieldwise_init
struct _Built(Movable):
    var query: MetricsQuery
    var error: String


def _refused(var why: String) -> _Built:
    return _Built(
        MetricsQuery(
            Int64(0),
            Int64(0),
            String(""),
            List[MetricsMatcher](),
            MetricsAggregation.raw(),
            Int64(0),
            List[String](),
            0,
            0,
        ),
        why^,
    )


comptime _MAX_WINDOW_MS: Int64 = 9_223_372_036_854
"""The last millisecond whose nanosecond value fits an Int64."""


def _query_from(params: List[_Param], now_ns: Int64) -> _Built:
    # Every decoded key and value is text from here on (a reader quotes it
    # into a filter or a JSON body), so bytes that are not UTF-8 are refused
    # here, naming the parameter, rather than passed down.
    for i in range(len(params)):
        if not _is_utf8(params[i].key) or not _is_utf8(params[i].value):
            return _refused(
                String("the query parameter '")
                + params[i].key
                + String("' is not UTF-8 once percent-decoded")
            )

    # Every key is one of the documented names or a `label.<k>` /
    # `not_label.<k>` matcher, and appears once. Anything else is refused,
    # naming it: an unknown key is most often a misspelled one, and ignoring
    # it would answer the default it was meant to replace; a repeated key
    # has no one value to keep.
    for i in range(len(params)):
        var k = params[i].key.copy()
        if k.startswith(METRICS_LABEL_PREFIX) or k.startswith(
            METRICS_NOT_LABEL_PREFIX
        ):
            var plen = METRICS_LABEL_PREFIX.byte_length()
            if k.startswith(METRICS_NOT_LABEL_PREFIX):
                plen = METRICS_NOT_LABEL_PREFIX.byte_length()
            if k.byte_length() == plen:
                return _refused(
                    String("a label matcher '")
                    + k
                    + String("' names no label key")
                )
        elif not _is_known_param(k):
            return _refused(
                String("unknown query parameter '")
                + k
                + String("'. The parameters are ")
                + _known_params_sentence()
            )
        for j in range(i):
            if params[j].key == k:
                return _refused(
                    String("the query parameter '")
                    + k
                    + String("' is given more than once; give it once")
                )

    var metric = _param(params, METRICS_METRIC_PARAM)
    if not metric or metric.value().byte_length() == 0:
        return _refused(
            String("'")
            + METRICS_METRIC_PARAM
            + String("' is required: name the metric to read")
        )

    var until_n = _number(params, METRICS_UNTIL_PARAM)
    if until_n.error.byte_length() > 0:
        return _refused(until_n.error)
    var since_n = _number(params, METRICS_SINCE_PARAM)
    if since_n.error.byte_length() > 0:
        return _refused(since_n.error)
    var until_ms = until_n.or_default(now_ns // Int64(1_000_000))
    var since_ms = since_n.or_default(until_ms - METRICS_DEFAULT_LOOKBACK_MS)
    if until_n.overflow or until_ms > _MAX_WINDOW_MS:
        return _refused(_beyond(METRICS_UNTIL_PARAM))
    if since_n.overflow or since_ms > _MAX_WINDOW_MS:
        return _refused(_beyond(METRICS_SINCE_PARAM))
    if since_ms < Int64(0):
        since_ms = Int64(0)
    if since_ms > until_ms:
        return _refused(
            String("'")
            + METRICS_SINCE_PARAM
            + String("' (")
            + String(since_ms)
            + String(") is after '")
            + METRICS_UNTIL_PARAM
            + String("' (")
            + String(until_ms)
            + String(
                "). The window is inclusive at both ends and is not reordered"
                " for you."
            )
        )

    var step_n = _number(params, METRICS_STEP_PARAM)
    if step_n.error.byte_length() > 0:
        return _refused(step_n.error)
    if step_n.overflow:
        return _refused(
            String("'") + METRICS_STEP_PARAM + String("' is too large")
        )
    var step_ms = step_n.or_default(METRICS_DEFAULT_STEP_MS)
    if step_ms < Int64(1):
        return _refused(
            String("'") + METRICS_STEP_PARAM + String("' must be positive")
        )

    var agg = MetricsAggregation.raw()
    var agg_p = _param(params, METRICS_AGG_PARAM)
    if agg_p:
        var parsed = MetricsAggregation.from_name(agg_p.value())
        if not parsed:
            return _refused(
                String("'")
                + METRICS_AGG_PARAM
                + String("' must be one of raw, sum, rate, mean, min, max,")
                + String(" count; got '")
                + agg_p.value()
                + String("'")
            )
        agg = parsed.value()

    var group_by = List[String]()
    var gb = _param(params, METRICS_GROUP_BY_PARAM)
    if gb:
        for part in gb.value().split(","):
            var key = String(part)
            if key.byte_length() > 0 and not _contains(group_by, key):
                group_by.append(key^)

    var matchers = List[MetricsMatcher]()
    for i in range(len(params)):
        var k = params[i].key.copy()
        var negated = False
        var label = String("")
        if k.startswith(METRICS_LABEL_PREFIX):
            label = String(k[byte = METRICS_LABEL_PREFIX.byte_length() :])
        elif k.startswith(METRICS_NOT_LABEL_PREFIX):
            label = String(k[byte = METRICS_NOT_LABEL_PREFIX.byte_length() :])
            negated = True
        else:
            continue
        matchers.append(
            MetricsMatcher(label^, params[i].value.copy(), negated)
        )

    var series_limit = _clamped(
        params,
        METRICS_SERIES_LIMIT_PARAM,
        METRICS_DEFAULT_SERIES_LIMIT,
        METRICS_MAX_SERIES_LIMIT,
    )
    if series_limit < 0:
        return _refused(_malformed(METRICS_SERIES_LIMIT_PARAM))
    var point_limit = _clamped(
        params,
        METRICS_POINT_LIMIT_PARAM,
        METRICS_DEFAULT_POINT_LIMIT,
        METRICS_MAX_POINT_LIMIT,
    )
    if point_limit < 0:
        return _refused(_malformed(METRICS_POINT_LIMIT_PARAM))

    return _Built(
        MetricsQuery(
            since_ms * Int64(1_000_000),
            until_ms * Int64(1_000_000),
            metric.value(),
            matchers^,
            agg,
            step_ms,
            group_by^,
            series_limit,
            point_limit,
        ),
        String(""),
    )


def _known_params() -> List[String]:
    return [
        METRICS_METRIC_PARAM,
        METRICS_SINCE_PARAM,
        METRICS_UNTIL_PARAM,
        METRICS_STEP_PARAM,
        METRICS_AGG_PARAM,
        METRICS_GROUP_BY_PARAM,
        METRICS_SERIES_LIMIT_PARAM,
        METRICS_POINT_LIMIT_PARAM,
    ]


def _is_known_param(key: String) -> Bool:
    return _contains(_known_params(), key)


def _known_params_sentence() -> String:
    var known = _known_params()
    var out = String("")
    for i in range(len(known)):
        out += known[i]
        out += String(", ")
    out += METRICS_LABEL_PREFIX + String("<key> and ")
    out += METRICS_NOT_LABEL_PREFIX + String("<key>")
    return out^


def _contains(xs: List[String], x: String) -> Bool:
    for i in range(len(xs)):
        if xs[i] == x:
            return True
    return False


def _beyond(param: String) -> String:
    return (
        String("'")
        + param
        + String(
            "' is beyond the last millisecond a nanosecond window can hold ("
        )
        + String(_MAX_WINDOW_MS)
        + String("). A bound that does not fit is refused, not wrapped.")
    )


def _malformed(param: String) -> String:
    return (
        String("'")
        + param
        + String("' must be a non-negative whole number of digits")
    )


def _clamped(
    params: List[_Param], key: String, default: Int, ceiling: Int
) -> Int:
    """The limit `key` clamped to [1, ceiling], `default` when absent, or -1
    when present and malformed."""
    var n = _number(params, key)
    if n.error.byte_length() > 0:
        return -1
    if n.overflow:
        return ceiling
    var v = n.or_default(Int64(default))
    if v < Int64(1):
        return 1
    if v > Int64(ceiling):
        return ceiling
    return Int(v)


# =============================================================================
# §5 — rendering.
# =============================================================================


def _render_page(q: MetricsQuery, page: MetricsPage) -> String:
    """`application/json`. The window, the step, the aggregation and the two
    limits are rendered always, defaulted or not, so an empty answer can be
    read against the question that was actually asked."""
    var out = String('{"metric":"')
    out += _json_escape(q.metric)
    out += String('","agg":"')
    out += q.aggregation.name()
    out += String('","since_ms":')
    out += String(q.start_ns // Int64(1_000_000))
    out += String(',"until_ms":')
    out += String(q.end_ns // Int64(1_000_000))
    out += String(',"step_ms":')
    out += String(q.step_ms)
    out += String(',"series_limit":')
    out += String(q.series_limit)
    out += String(',"point_limit":')
    out += String(q.point_limit)
    out += String(',"returned":')
    out += String(len(page.series))
    out += String(',"truncated":')
    out += String("true") if page.truncated else String("false")
    out += String(',"scanned":')
    out += String(page.sources_scanned)
    out += String(',"series":[')
    for i in range(len(page.series)):
        if i > 0:
            out += String(",")
        out += _render_series(page.series[i])
    out += String("]}")
    return out^


def _render_series(s: MetricsSeriesData) -> String:
    """`{"metric":M,"labels":{k:v,...},"samples":[[time_ns,value],...]}`. A
    non-finite value has no JSON spelling and renders as null."""
    var out = String('{"metric":"')
    out += _json_escape(s.metric)
    out += String('","labels":{')
    for i in range(len(s.labels)):
        if i > 0:
            out += String(",")
        out += String('"')
        out += _json_escape(s.labels[i].key)
        out += String('":"')
        out += _json_escape(s.labels[i].value)
        out += String('"')
    out += String('},"samples":[')
    for i in range(len(s.samples)):
        if i > 0:
            out += String(",")
        out += String("[")
        out += String(s.samples[i].time_ns)
        out += String(",")
        var v = s.samples[i].value
        if (v - v) == Float64(0):
            out += String(v)
        else:
            out += String("null")
        out += String("]")
    out += String("]}")
    return out^


def _json_escape(s: String) -> String:
    """RFC 8259 string escaping. Well-formed UTF-8 is copied byte for byte; a
    byte that starts no well-formed sequence becomes U+FFFD, so the body stays
    valid UTF-8."""
    var b = s.as_bytes()
    var out = List[UInt8]()
    var i = 0
    var n = len(b)
    while i < n:
        var c = Int(b[i])
        if c == ord('"'):
            _append(out, '\\"')
        elif c == ord("\\"):
            _append(out, "\\\\")
        elif c == ord("\n"):
            _append(out, "\\n")
        elif c == ord("\r"):
            _append(out, "\\r")
        elif c == ord("\t"):
            _append(out, "\\t")
        elif c < 0x20:
            var hb = "0123456789abcdef".as_bytes()
            _append(out, "\\u00")
            out.append(hb[(c >> 4) & 0xF])
            out.append(hb[c & 0xF])
        elif c < 0x80:
            out.append(b[i])
        else:
            var k = _utf8_seq_len(b, i)
            if k == 0:
                _append(out, "\\ufffd")
            else:
                for j in range(k):
                    out.append(b[i + j])
                i += k
                continue
        i += 1
    return String(unsafe_from_utf8=out^)


def _append(mut out: List[UInt8], s: String):
    var sb = s.as_bytes()
    for i in range(len(sb)):
        out.append(sb[i])


def _utf8_seq_len(b: Span[UInt8, _], i: Int) -> Int:
    """The length of the well-formed UTF-8 sequence at `b[i]` (a byte >= 0x80),
    or 0 when none starts there."""
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


def _is_utf8(s: String) -> Bool:
    """True iff every byte of `s` belongs to a well-formed UTF-8 sequence."""
    var b = s.as_bytes()
    var i = 0
    while i < len(b):
        if Int(b[i]) < 0x80:
            i += 1
            continue
        var k = _utf8_seq_len(b, i)
        if k == 0:
            return False
        i += k
    return True


def _json_response(var body: String, status: Int32) -> HttpResponse:
    var r = HttpResponse(status=status)
    r.headers[String("content-type")] = String("application/json")
    var bytes_ref = body.as_bytes()
    var n = len(bytes_ref)
    for i in range(n):
        r.body.append(bytes_ref[i])
    r.headers[String("content-length")] = String(n)
    return r^


def _error_json(status: Int32, var message: String) -> HttpResponse:
    return _json_response(
        String('{"error":"') + _json_escape(message) + String('"}'), status
    )


def _not_found() -> HttpResponse:
    """The one refusal, byte-identical for every refused and unwired case."""
    return _error_json(Int32(404), String("not found"))


# =============================================================================
# §6 — request parsing.
# =============================================================================


@fieldwise_init
struct _Param(Copyable, Movable):
    """One `key=value` of the query string, both percent- and plus-decoded."""

    var key: String
    var value: String


def _decoded_params(query_string: String) -> List[_Param]:
    """Every `key=value` segment of `query_string` (no leading `?`), decoded.
    A segment with no `=` has an empty value. A malformed `%` escape is kept
    as a literal `%`."""
    var out = List[_Param]()
    var qb = query_string.as_bytes()
    var n = len(qb)
    var i = 0
    while i < n:
        var seg_end = i
        while seg_end < n and qb[seg_end] != UInt8(ord("&")):
            seg_end += 1
        var eq = i
        while eq < seg_end and qb[eq] != UInt8(ord("=")):
            eq += 1
        if eq > i:
            var key = _decode(qb, i, eq)
            var value = String("")
            if eq < seg_end:
                value = _decode(qb, eq + 1, seg_end)
            out.append(_Param(key^, value^))
        i = seg_end + 1
    return out^


def _decode(b: Span[UInt8, _], start: Int, end: Int) -> String:
    var out = List[UInt8]()
    var j = start
    while j < end:
        var c = b[j]
        if c == UInt8(ord("+")):
            out.append(UInt8(ord(" ")))
            j += 1
        elif c == UInt8(ord("%")) and j + 2 < end:
            var hi = _hex_val(b[j + 1])
            var lo = _hex_val(b[j + 2])
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
    # Not yet checked: `_query_from` refuses a key or value that is not
    # UTF-8 (`_is_utf8`) before anything reads it as text.
    return String(unsafe_from_utf8=out^)


def _hex_val(c: UInt8) -> Int:
    if c >= UInt8(ord("0")) and c <= UInt8(ord("9")):
        return Int(c) - ord("0")
    if c >= UInt8(ord("a")) and c <= UInt8(ord("f")):
        return Int(c) - ord("a") + 10
    if c >= UInt8(ord("A")) and c <= UInt8(ord("F")):
        return Int(c) - ord("A") + 10
    return -1


def _param(params: List[_Param], key: String) -> Optional[String]:
    """The first value of `key`, or None when absent."""
    for i in range(len(params)):
        if params[i].key == key:
            return Optional(params[i].value.copy())
    return None


comptime _I64_MAX: Int64 = 9_223_372_036_854_775_807


@fieldwise_init
struct _Number(Copyable, Movable):
    """One numeric parameter: its value when `present`, `overflow` when it is
    all digits and more than an Int64 holds, and `error` (a 400 sentence) when
    it is present and not a whole number."""

    var value: Int64
    var present: Bool
    var overflow: Bool
    var error: String

    def or_default(self, default: Int64) -> Int64:
        if self.present:
            return self.value
        return default


def _number(params: List[_Param], key: String) -> _Number:
    var p = _param(params, key)
    if not p:
        return _Number(Int64(0), False, False, String(""))
    var text = p.value()
    var b = text.as_bytes()
    if len(b) == 0:
        return _Number(Int64(0), False, False, _malformed(key))
    var val = Int64(0)
    for j in range(len(b)):
        var c = b[j]
        if c < UInt8(ord("0")) or c > UInt8(ord("9")):
            return _Number(Int64(0), False, False, _malformed(key))
        var d = Int64(Int(c) - ord("0"))
        if val > (_I64_MAX - d) // Int64(10):
            return _Number(_I64_MAX, False, True, String(""))
        val = val * Int64(10) + d
    return _Number(val, True, False, String(""))
