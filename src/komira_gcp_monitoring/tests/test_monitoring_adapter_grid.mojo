# The adapter (time_series_list.mojo) over whole grids, each fixture
# through every checker it reaches, with its exact expected answer.
#
# What is pinned, and what each part would catch:
#   * The project: every ASCII byte and a 2-, 3- and 4-byte UTF-8
#     character, alone and first, inside and last of a three-piece project, against the set a project id or number is spelled
#     in (a-z, 0-9, `-`, `.`, `:`). A range bound moved by one, a dropped
#     alternative, or a loop that skips the first or last byte fails here.
#   * The label key: the same characters in the same four positions, bare
#     and after `resource.`, through `label_key_refusal`,
#     `filter_label_selector` and `group_by_field` (the exact refusal
#     sentence, and the exact `metric.labels.<k>` / `resource.labels.<k>`
#     and `metric.label.<k>` / `resource.label.<k>` spellings), plus the
#     prefix edge cases (`resource`, `resource.`, `resource..a`,
#     `Resource.a`, `resource.resource.a`).
#   * Quoting: every string of length 0..2 over a plain byte, `"`, `\`
#     and a two-byte letter, each escaped by one backslash.
#   * The filter: 0..2 matchers, plain and negated, metric and resource
#     labels, the exact text; a refused key at index 0 and at index 1; an
#     empty metric type refused before any matcher is read.
#   * The request: a whole-object comparison over every field of the
#     generated ListTimeSeriesRequest (name, filter, both interval ends to
#     the nanosecond, the aggregation's presence, period, aligner, reducer
#     and group-by fields, no secondary aggregation, no order, view FULL,
#     page size and token) for accepted requests across the aligners and
#     reducers the reader sends; every refusal by its exact sentence, at
#     each boundary (period 59/60/61, -60, 1 and -1 unaligned, group-by
#     fields 1 and 2, page size -1/0/1/100000/100001, a one-byte aligner or
#     reducer); and the order of the refusals, by fixtures that break one
#     check and every later one, so moving a later check earlier fails.
#   * Time: 0, 1 ns, a second minus 1 ns, a second, a second plus 1 ns,
#     -1 and the least Int64, both ways.

from std.testing import assert_equal, assert_false, assert_true

from komira_gcp_monitoring import (
    TimeSeriesListRequest,
    filter_label_selector,
    group_by_field,
    label_key_refusal,
    list_time_series_request,
    monitoring_filter,
    ns_of_timestamp,
    quote_filter_string,
    time_series_list_name,
    timestamp_of_ns,
)
from komira_gcp_monitoring_client.metric_service import ListTimeSeriesRequest
from komira_metrics_reader import MetricsMatcher
from komira_wkt import Timestamp

comptime _NS = Int64(1_000_000_000)
comptime _T = Int64(1789207200) * _NS  # 2026-09-12T10:00:00Z
comptime _PROJECT_BYTES = "abcdefghijklmnopqrstuvwxyz0123456789-.:"
comptime _KEY_BYTES = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_"
comptime _PROJECT_REFUSED = "ListTimeSeries: the project holds a byte a project id never does"


def _in(set: String, c: UInt8) -> Bool:
    var b = set.as_bytes()
    for i in range(len(b)):
        if b[i] == c:
            return True
    return False


def _str(var bytes: List[UInt8]) -> String:
    return String(unsafe_from_utf8=Span(bytes))


def _pieces() -> List[String]:
    """Every ASCII byte 0..127 as a one-byte string, then a two-, a three-
    and a four-byte UTF-8 character (a String is UTF-8, so a lone byte
    0x80..0xFF is not one)."""
    var out = List[String]()
    for v in range(128):
        var b = List[UInt8]()
        b.append(UInt8(v))
        out.append(_str(b^))
    out.append(String("é"))
    out.append(String("€"))
    out.append(String("😀"))
    return out^


def _accepted(piece: String, set: String) -> Bool:
    var b = piece.as_bytes()
    return len(b) == 1 and _in(set, b[0])


def _shapes(piece: String) -> List[String]:
    """`piece` alone, first, inside and last of a three-piece string."""
    var out = List[String]()
    out.append(piece.copy())
    out.append(piece + "ab")
    out.append(String("a") + piece + "b")
    out.append(String("ab") + piece)
    return out^


def _name_or_error(project: String) -> String:
    try:
        return time_series_list_name(project)
    except e:
        return String("ERR ") + String(e)


def test_project_every_character_every_position() raises:
    assert_equal(_name_or_error(String("")), String("ERR ListTimeSeries: the project is empty"))
    var pieces = _pieces()
    for v in range(len(pieces)):
        var ok = _accepted(pieces[v], String(_PROJECT_BYTES))
        var shapes = _shapes(pieces[v])
        for s in range(len(shapes)):
            var want = (
                String("projects/") + shapes[s]
            ) if ok else String("ERR ") + String(_PROJECT_REFUSED)
            assert_equal(_name_or_error(shapes[s]), want, String("piece ") + String(v))


def _refused_sentence(key: String) -> String:
    return (
        String("the label key '")
        + key
        + "' is not a plain identifier (letters, digits, '_'), optionally"
        + " after 'resource.'"
    )


def _selector_or_error(key: String) -> String:
    try:
        return filter_label_selector(key)
    except e:
        return String("ERR ") + String(e)


def _group_or_error(key: String) -> String:
    try:
        return group_by_field(key)
    except e:
        return String("ERR ") + String(e)


def _check_key(key: String, accepted: Bool, resource_k: String) raises:
    """`key` through all three checkers. `resource_k` is the resource label
    the key names, or "" for a metric label."""
    if not accepted:
        var why = _refused_sentence(key)
        assert_equal(label_key_refusal(key), why, key)
        assert_equal(_selector_or_error(key), String("ERR ") + why, key)
        assert_equal(_group_or_error(key), String("ERR ") + why, key)
        return
    assert_equal(label_key_refusal(key), String(""), key)
    if resource_k.byte_length() > 0:
        assert_equal(_selector_or_error(key), String("resource.labels.") + resource_k)
        assert_equal(_group_or_error(key), String("resource.label.") + resource_k)
    else:
        assert_equal(_selector_or_error(key), String("metric.labels.") + key)
        assert_equal(_group_or_error(key), String("metric.label.") + key)


def test_label_key_every_character_every_position() raises:
    var pieces = _pieces()
    for v in range(len(pieces)):
        var ok = _accepted(pieces[v], String(_KEY_BYTES))
        var shapes = _shapes(pieces[v])
        for s in range(len(shapes)):
            _check_key(shapes[s], ok, String(""))
            var rk = String("resource.") + shapes[s]
            _check_key(rk, ok, shapes[s] if ok else String(""))


def test_label_key_prefix_edges() raises:
    _check_key(String(""), False, String(""))
    _check_key(String("resource"), True, String(""))
    _check_key(String("resource_zone"), True, String(""))
    _check_key(String("resource."), False, String(""))
    _check_key(String("resource..a"), False, String(""))
    _check_key(String("Resource.a"), False, String(""))
    _check_key(String("resource.resource.a"), False, String(""))
    _check_key(String("xresource.a"), False, String(""))
    _check_key(String("resource.a"), True, String("a"))
    _check_key(String("resource.ab"), True, String("ab"))
    _check_key(String("resource.resource"), True, String("resource"))


def _escaped(piece: String) -> String:
    if piece == '"':
        return String('\\"')
    if piece == "\\":
        return String("\\\\")
    return piece.copy()


def test_quote_every_string_of_length_0_to_2() raises:
    var alphabet: List[String] = [String("a"), String('"'), String("\\"), String("é")]
    assert_equal(quote_filter_string(String("")), String('""'))
    for i in range(len(alphabet)):
        assert_equal(
            quote_filter_string(alphabet[i]),
            String('"') + _escaped(alphabet[i]) + '"',
        )
        for j in range(len(alphabet)):
            var pair = alphabet[i].copy()
            pair += alphabet[j]
            assert_equal(
                quote_filter_string(pair),
                String('"') + _escaped(alphabet[i]) + _escaped(alphabet[j]) + '"',
            )


def _filter_or_error(metric: String, m: List[MetricsMatcher]) -> String:
    try:
        return monitoring_filter(metric, m)
    except e:
        return String("ERR ") + String(e)


def test_filter_grid() raises:
    var none = List[MetricsMatcher]()
    assert_equal(_filter_or_error(String("m"), none), String('metric.type = "m"'))
    assert_equal(_filter_or_error(String('a"b'), none), String('metric.type = "a\\"b"'))
    assert_equal(
        _filter_or_error(String(""), none),
        String("ERR ListTimeSeries: the metric type is empty"),
    )
    var one = List[MetricsMatcher]()
    one.append(MetricsMatcher.neq(String("resource.zone"), String("x\\y")))
    assert_equal(
        _filter_or_error(String("m"), one),
        String('metric.type = "m" AND resource.labels.zone != "x\\\\y"'),
    )
    var two = List[MetricsMatcher]()
    two.append(MetricsMatcher.eq(String("code"), String("200")))
    two.append(MetricsMatcher.eq(String("resource.region"), String("r")))
    assert_equal(
        _filter_or_error(String("m"), two),
        String('metric.type = "m" AND metric.labels.code = "200" AND resource.labels.region = "r"'),
    )
    var neg_two = List[MetricsMatcher]()
    neg_two.append(MetricsMatcher.neq(String("code"), String("")))
    neg_two.append(MetricsMatcher.neq(String("code"), String("5")))
    assert_equal(
        _filter_or_error(String("m"), neg_two),
        String('metric.type = "m" AND metric.labels.code != "" AND metric.labels.code != "5"'),
    )
    var bad_first = List[MetricsMatcher]()
    bad_first.append(MetricsMatcher.eq(String("a-b"), String("1")))
    bad_first.append(MetricsMatcher.eq(String("ok"), String("1")))
    assert_equal(
        _filter_or_error(String("m"), bad_first),
        String("ERR ") + _refused_sentence(String("a-b")),
    )
    var bad_second = List[MetricsMatcher]()
    bad_second.append(MetricsMatcher.eq(String("ok"), String("1")))
    bad_second.append(MetricsMatcher.eq(String("c d"), String("1")))
    assert_equal(
        _filter_or_error(String("m"), bad_second),
        String("ERR ") + _refused_sentence(String("c d")),
    )
    # The empty metric type is refused before a bad matcher is read.
    assert_equal(
        _filter_or_error(String(""), bad_first),
        String("ERR ListTimeSeries: the metric type is empty"),
    )


def test_times_both_ways() raises:
    var cases: List[Int64] = [Int64(0), Int64(1), _NS - 1, _NS, _NS + 1, _T + 7]
    var secs: List[Int64] = [Int64(0), Int64(0), Int64(0), Int64(1), Int64(1), Int64(1789207200)]
    var nanos: List[Int32] = [Int32(0), Int32(1), Int32(999_999_999), Int32(0), Int32(1), Int32(7)]
    for i in range(len(cases)):
        var t = timestamp_of_ns(cases[i])
        assert_equal(t.seconds, secs[i])
        assert_equal(t.nanos, nanos[i])
        assert_equal(ns_of_timestamp(Timestamp(secs[i], nanos[i])), cases[i])
    var refused: List[Int64] = [Int64(-1), -_NS, Int64(-9223372036854775807) - 1]
    for i in range(len(refused)):
        try:
            _ = timestamp_of_ns(refused[i])
            raise Error("sent a time before 1970")
        except e:
            assert_equal(String(e), String("a time before 1970 is not sent"))


# ── the request ─────────────────────────────────────────────────────────────


def _req(
    aligner: String = "",
    period_s: Int = 0,
    reducer: String = "",
    var groups: List[String] = List[String](),
    page_size: Int = 1000,
    token: String = "",
    start_ns: Int64 = _T + 1,
    end_ns: Int64 = _T + 2 * _NS + 5,
) -> TimeSeriesListRequest:
    return TimeSeriesListRequest(
        String("demo-project"),
        String('metric.type = "m"'),
        start_ns,
        end_ns,
        period_s,
        aligner.copy(),
        reducer.copy(),
        groups^,
        page_size,
        token.copy(),
    )


def _try(req: TimeSeriesListRequest) -> String:
    """"" when `req` is accepted, else its refusal."""
    try:
        _ = list_time_series_request(req)
        return String("")
    except e:
        return String(e)


def _check_ts(got: Optional[Timestamp], ns: Int64) raises:
    assert_true(Bool(got))
    assert_equal(got.value().seconds, ns // _NS)
    assert_equal(got.value().nanos, Int32(ns % _NS))


def _check_request(
    r: ListTimeSeriesRequest,
    req: TimeSeriesListRequest,
    aggregated: Bool,
    aligner: Int,
    reducer: Int,
) raises:
    """Every field of the generated request against `req`, the aggregation
    present iff `aggregated`, with the aligner and reducer numbers given."""
    assert_equal(r.name, String("projects/") + req.project)
    assert_equal(r.filter, req.filter)
    assert_true(Bool(r.interval))
    _check_ts(r.interval.value().start_time, req.start_ns)
    _check_ts(r.interval.value().end_time, req.end_ns)
    assert_equal(Bool(r.aggregation), aggregated)
    if aggregated:
        ref a = r.aggregation.value()
        assert_true(Bool(a.alignment_period))
        assert_equal(a.alignment_period.value().seconds, Int64(req.alignment_period_s))
        assert_equal(a.alignment_period.value().nanos, Int32(0))
        assert_equal(a.per_series_aligner.number(), aligner)
        assert_equal(a.cross_series_reducer.number(), reducer)
        assert_equal(len(a.group_by_fields), len(req.group_by_fields))
        for i in range(len(req.group_by_fields)):
            assert_equal(a.group_by_fields[i], req.group_by_fields[i])
    assert_false(Bool(r.secondary_aggregation))
    assert_equal(r.order_by, String(""))
    assert_equal(r.view.number(), 0)
    assert_equal(r.page_size, Int32(req.page_size))
    assert_equal(r.page_token, req.page_token)


def test_accepted_requests_whole() raises:
    var raw = _req(page_size=1)
    _check_request(list_time_series_request(raw), raw, False, 0, 0)
    var at_zero = _req(start_ns=Int64(0), end_ns=Int64(0), page_size=100000, token="t/=")
    _check_request(list_time_series_request(at_zero), at_zero, False, 0, 0)
    var summed = _req("ALIGN_SUM", 60)
    _check_request(list_time_series_request(summed), summed, True, 14, 0)
    var g1: List[String] = [String("metric.label.code")]
    var mean = _req("ALIGN_MEAN", 61, "REDUCE_MEAN", g1^)
    _check_request(list_time_series_request(mean), mean, True, 12, 1)
    var g2: List[String] = [String("metric.label.code"), String("resource.label.zone")]
    var counted = _req("ALIGN_COUNT", 3600, "REDUCE_MAX", g2^, 7, "next")
    _check_request(list_time_series_request(counted), counted, True, 13, 3)
    var g3: List[String] = [String("resource.label.zone")]
    var lowest = _req("ALIGN_MIN", 120, "REDUCE_MIN", g3^)
    _check_request(list_time_series_request(lowest), lowest, True, 10, 2)
    # Reduced with no group-by field: every series into one.
    var highest = _req("ALIGN_MAX", 300, "REDUCE_SUM")
    _check_request(list_time_series_request(highest), highest, True, 11, 4)
    var rate = _req("ALIGN_RATE", 60, "REDUCE_SUM")
    _check_request(list_time_series_request(rate), rate, True, 2, 4)


def test_refusals_at_each_boundary() raises:
    var at_least = String(" s; it must be at least 60 s")
    assert_equal(_try(_req("ALIGN_SUM", 59)), String("ListTimeSeries: an alignment period of 59") + at_least)
    assert_equal(_try(_req("ALIGN_SUM", 0)), String("ListTimeSeries: an alignment period of 0") + at_least)
    assert_equal(_try(_req("ALIGN_SUM", -60)), String("ListTimeSeries: an alignment period of -60") + at_least)
    assert_equal(_try(_req("ALIGN_SUM", 60)), String(""))
    assert_equal(_try(_req("ALIGN_SUM", 61)), String(""))
    var no_aligner = String("ListTimeSeries: an alignment period with no aligner")
    assert_equal(_try(_req("", 1)), no_aligner)
    assert_equal(_try(_req("", -1)), no_aligner)
    assert_equal(_try(_req("", 60)), no_aligner)
    assert_equal(_try(_req("", 0)), String(""))
    var needs_aligner = String("ListTimeSeries: a cross-series reducer needs an aligner")
    assert_equal(_try(_req("", 0, "REDUCE_SUM")), needs_aligner)
    assert_equal(_try(_req("", 0, "Y")), needs_aligner)
    var needs_reducer = String("ListTimeSeries: group-by fields need a cross-series reducer")
    var g1: List[String] = [String("metric.label.a")]
    assert_equal(_try(_req("ALIGN_SUM", 60, "", g1^)), needs_reducer)
    var g2: List[String] = [String("metric.label.a"), String("metric.label.b")]
    assert_equal(_try(_req("ALIGN_SUM", 60, "", g2^)), needs_reducer)
    var g0: List[String] = [String("metric.label.a")]
    assert_equal(_try(_req("", 0, "", g0^)), needs_reducer)
    assert_equal(
        _try(_req("X", 60)),
        String("ListTimeSeries: the aligner X is not declared in the pinned protos"),
    )
    assert_equal(
        _try(_req("align_sum", 60)),
        String("ListTimeSeries: the aligner align_sum is not declared in the pinned protos"),
    )
    assert_equal(
        _try(_req("ALIGN_SUM", 60, "Y")),
        String("ListTimeSeries: the reducer Y is not declared in the pinned protos"),
    )
    var pages: List[Int] = [-1, 0, 1, 100000, 100001]
    var page_ok: List[Bool] = [False, False, True, True, False]
    for i in range(len(pages)):
        var want = String("") if page_ok[i] else (
            String("ListTimeSeries: a page size of ")
            + String(pages[i])
            + " is outside [1, 100000]"
        )
        assert_equal(_try(_req(page_size=pages[i])), want)
    var before = String("a time before 1970 is not sent")
    assert_equal(_try(_req(start_ns=Int64(-1))), before)
    assert_equal(_try(_req(end_ns=Int64(-1))), before)
    var empty_filter = _req()
    empty_filter.filter = String("")
    assert_equal(
        _try(empty_filter),
        String("ListTimeSeries: the filter is empty; it must name one metric type"),
    )
    var one_byte_filter = _req()
    one_byte_filter.filter = String("m")
    assert_equal(_try(one_byte_filter), String(""))


def _broken_from(k: Int) -> TimeSeriesListRequest:
    """A request breaking check `k` (1 filter, 2 project, 3 short period,
    4 period with no aligner, 5 reducer with no aligner, 6 group-by with no
    reducer, 7 unknown aligner, 8 unknown reducer, 9 page size, 10 time)
    and every later check it can break alongside."""
    var groups: List[String] = [String("metric.label.a")]
    var aligner = String("ALIGN_SUM")
    var period = 60
    var reducer = String("REDUCE_SUM")
    if k <= 3:
        aligner = String("ALIGN_X")
        period = 30
        reducer = String("REDUCE_X")
    elif k == 4:
        aligner = String("")
        period = 30
        reducer = String("REDUCE_X")
    elif k == 5:
        aligner = String("")
        period = 0
        reducer = String("REDUCE_X")
    elif k == 6:
        aligner = String("ALIGN_X")
        reducer = String("")
    elif k == 7:
        aligner = String("ALIGN_X")
        reducer = String("REDUCE_X")
    elif k == 8:
        reducer = String("REDUCE_X")
    var r = _req(aligner, period, reducer, groups^, 0 if k <= 9 else 1000)
    r.start_ns = Int64(-1)
    if k == 1:
        r.filter = String("")
    if k <= 2:
        r.project = String("Bad/")
    return r^


def test_refusal_order() raises:
    var want: List[String] = [
        String("ListTimeSeries: the filter is empty; it must name one metric type"),
        String(_PROJECT_REFUSED),
        String("ListTimeSeries: an alignment period of 30 s; it must be at least 60 s"),
        String("ListTimeSeries: an alignment period with no aligner"),
        String("ListTimeSeries: a cross-series reducer needs an aligner"),
        String("ListTimeSeries: group-by fields need a cross-series reducer"),
        String("ListTimeSeries: the aligner ALIGN_X is not declared in the pinned protos"),
        String("ListTimeSeries: the reducer REDUCE_X is not declared in the pinned protos"),
        String("ListTimeSeries: a page size of 0 is outside [1, 100000]"),
        String("a time before 1970 is not sent"),
    ]
    for k in range(1, 11):
        assert_equal(_try(_broken_from(k)), want[k - 1], String("check ") + String(k))


def main() raises:
    test_project_every_character_every_position()
    test_label_key_every_character_every_position()
    test_label_key_prefix_edges()
    test_quote_every_string_of_length_0_to_2()
    test_filter_grid()
    test_times_both_ways()
    test_accepted_requests_whole()
    test_refusals_at_each_boundary()
    test_refusal_order()
    print("OK")
