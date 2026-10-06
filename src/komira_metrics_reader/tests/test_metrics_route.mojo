# komira_metrics_reader: the `GET <path>` route over ScriptedMetricsReader.
#
# Pinned, in the route's own order: the exact path match; a hook that says no,
# a hook that raises and an unwired reader give one byte-identical 404, and
# access runs before any argument check; `metric` is required; the window
# defaults to the last hour and a malformed, inverted or unrepresentable bound
# is a 400, never a default; the step, the aggregation, group-by keys and label
# matchers (both polarities, percent-decoded) reach the reader as written; an
# unknown, repeated or empty parameter name and a malformed `%` escape in a
# name are 400s naming them; the
# limits default and clamp; the reader's refusal is a 400 carrying its
# sentence and the read is never made; a fault raised by the read is a 500
# naming it; the page renders with the question asked, its series, labels and
# samples, and a non-finite value as null.

from std.testing import assert_equal, assert_false, assert_true

from komira_http_core.codec.types import HttpMethod, HttpRequest, HttpResponse
from komira_metrics_reader import (
    DenyMetricsReads,
    ErasedMetricsReader,
    METRICS_DEFAULT_LOOKBACK_MS,
    METRICS_DEFAULT_POINT_LIMIT,
    METRICS_DEFAULT_SERIES_LIMIT,
    METRICS_DEFAULT_STEP_MS,
    METRICS_MAX_POINT_LIMIT,
    METRICS_MAX_SERIES_LIMIT,
    MetricsHeaderTokenAccess,
    MetricsLabel,
    MetricsPage,
    MetricsReadAccess,
    MetricsSample,
    MetricsSeriesData,
    ScriptedMetricsReader,
    is_metrics_request,
    metrics_response,
)

comptime PATH = "/metrics/read"
comptime HEADER = "x-metrics-read-token"
comptime TOKEN = "reader-secret-0123456789"
comptime NOW_MS: Int64 = 4_000_000_000_000
comptime NOW_NS: Int64 = NOW_MS * 1_000_000


struct AllowAll(MetricsReadAccess):
    def __init__(out self):
        pass

    def allows(self, req: HttpRequest) raises -> Bool:
        return True


struct RaisingAccess(MetricsReadAccess):
    def __init__(out self):
        pass

    def allows(self, req: HttpRequest) raises -> Bool:
        raise Error("key fetch failed")


def _req(query: String) -> HttpRequest:
    var r = HttpRequest(HttpMethod.get(), String(PATH))
    r.query_string = query
    return r^


def _body(r: HttpResponse) -> String:
    return String(unsafe_from_utf8=Span(r.body))


def _run[A: MetricsReadAccess](
    mut d: ScriptedMetricsReader, query: String, access: A
) -> HttpResponse:
    var wired = Optional(ErasedMetricsReader.erase(d.share()))
    return metrics_response(wired, _req(query), access, NOW_NS)


def _ok(mut d: ScriptedMetricsReader, query: String) raises -> String:
    var r = _run(d, query, AllowAll())
    assert_equal(r.status, Int32(200), _body(r))
    return _body(r)


def _status(mut d: ScriptedMetricsReader, query: String) -> Int32:
    return _run(d, query, AllowAll()).status


def _assert_not_found(r: HttpResponse) raises:
    assert_equal(r.status, Int32(404))
    assert_equal(_body(r), String('{"error":"not found"}'))


def test_path_match() raises:
    assert_true(is_metrics_request(_req(String("")), String(PATH)))
    assert_false(is_metrics_request(_req(String("")), String("/metrics")))
    var post = HttpRequest(HttpMethod.post(), String(PATH))
    assert_false(is_metrics_request(post, String(PATH)))


def test_every_refusal_is_one_404_and_access_runs_first() raises:
    var d = ScriptedMetricsReader()
    # An inverted window: a 400 for an authorized caller, never seen by a
    # refused one.
    var bad = String("metric=m&since_ms=9&until_ms=1")
    var deny = _run(d, bad, DenyMetricsReads())
    var raising = _run(d, bad, RaisingAccess())
    var no_token = _run(d, bad, MetricsHeaderTokenAccess(String(HEADER), String(TOKEN)))
    var empty_secret = MetricsHeaderTokenAccess(String(HEADER), String(""))
    var with_header = _req(bad)
    with_header.headers[String(HEADER)] = String("")
    var none = Optional[ErasedMetricsReader](None)
    var unwired = metrics_response(none, _req(bad), AllowAll(), NOW_NS)
    _assert_not_found(deny)
    _assert_not_found(raising)
    _assert_not_found(no_token)
    _assert_not_found(unwired)
    var wired = Optional(ErasedMetricsReader.erase(d.share()))
    assert_equal(
        metrics_response(wired, with_header, empty_secret, NOW_NS).status,
        Int32(404),
    )
    assert_equal(d.read_count(), 0)
    assert_equal(d.refusal_count(), 0)
    assert_equal(_status(d, bad), Int32(400))


def test_header_token_allows_the_exact_token() raises:
    var d = ScriptedMetricsReader()
    var access = MetricsHeaderTokenAccess(String("X-Metrics-Read-Token"), String(TOKEN))
    var r = _req(String("metric=m"))
    r.headers[String(HEADER)] = String(TOKEN)
    var wired = Optional(ErasedMetricsReader.erase(d.share()))
    assert_equal(metrics_response(wired, r, access, NOW_NS).status, Int32(200))
    var wrong = _req(String("metric=m"))
    wrong.headers[String(HEADER)] = String(TOKEN) + String("x")
    var wired2 = Optional(ErasedMetricsReader.erase(d.share()))
    assert_equal(metrics_response(wired2, wrong, access, NOW_NS).status, Int32(404))


def test_metric_is_required() raises:
    var d = ScriptedMetricsReader()
    var r = _run(d, String("agg=sum"), AllowAll())
    assert_equal(r.status, Int32(400))
    assert_true("'metric' is required" in _body(r), _body(r))
    assert_equal(_status(d, String("metric=")), Int32(400))
    assert_equal(d.read_count(), 0)


def test_defaults_reach_the_reader() raises:
    var d = ScriptedMetricsReader()
    _ = _ok(d, String("metric=run.googleapis.com%2Frequest_count"))
    var q = d.last_query()
    assert_equal(q.metric, String("run.googleapis.com/request_count"))
    assert_equal(q.end_ns, NOW_NS)
    assert_equal(q.start_ns, NOW_NS - METRICS_DEFAULT_LOOKBACK_MS * 1_000_000)
    assert_equal(q.step_ms, METRICS_DEFAULT_STEP_MS)
    assert_true(q.aggregation.is_raw())
    assert_equal(q.series_limit, METRICS_DEFAULT_SERIES_LIMIT)
    assert_equal(q.point_limit, METRICS_DEFAULT_POINT_LIMIT)
    assert_equal(len(q.matchers), 0)
    assert_equal(len(q.group_by), 0)


def test_arguments_reach_the_reader() raises:
    var d = ScriptedMetricsReader()
    _ = _ok(
        d,
        String(
            "metric=requests&since_ms=1000&until_ms=5000&step_ms=300000"
            "&agg=rate&group_by=code,route,code&label.service=api+v2"
            "&not_label.code=5%30%30&series_limit=7&point_limit=9"
        ),
    )
    var q = d.last_query()
    assert_equal(q.start_ns, Int64(1_000_000_000))
    assert_equal(q.end_ns, Int64(5_000_000_000))
    assert_equal(q.step_ms, Int64(300_000))
    assert_equal(q.aggregation.name(), String("rate"))
    assert_equal(len(q.group_by), 2)
    assert_equal(q.group_by[0], String("code"))
    assert_equal(q.group_by[1], String("route"))
    assert_equal(len(q.matchers), 2)
    assert_equal(q.matchers[0].key, String("service"))
    assert_equal(q.matchers[0].value, String("api v2"))
    assert_false(q.matchers[0].negated)
    assert_equal(q.matchers[1].key, String("code"))
    assert_equal(q.matchers[1].value, String("500"))
    assert_true(q.matchers[1].negated)
    assert_equal(q.series_limit, 7)
    assert_equal(q.point_limit, 9)
    # Well-formed multibyte UTF-8, percent-encoded, reaches the reader as text.
    _ = _ok(d, String("metric=m&label.caf%C3%A9=%E2%82%AC%F0%9F%93%88"))
    q = d.last_query()
    assert_equal(q.matchers[0].key, String("café"))
    assert_equal(q.matchers[0].value, String("€📈"))


def test_a_bad_argument_is_a_400_never_a_default() raises:
    var d = ScriptedMetricsReader()
    for query in [
        "metric=m&since_ms=abc",
        "metric=m&until_ms=-5",
        "metric=m&until_ms=",
        "metric=m&since_ms=10&until_ms=9",
        "metric=m&until_ms=9223372036855",
        "metric=m&since_ms=99999999999999999999999",
        "metric=m&step_ms=0",
        "metric=m&step_ms=1.5",
        "metric=m&agg=p99",
        "metric=m&label.=x",
        "metric=m&series_limit=ten",
        "metric=m&point_limit=-1",
        "metric=m&label.k=%FF",
        "metric=m&label.%C3=v",
        "metric=%ED%A0%80",
    ]:
        var r = _run(d, String(query), AllowAll())
        assert_equal(r.status, Int32(400), String(query) + " -> " + _body(r))
    assert_equal(d.read_count(), 0)
    assert_equal(d.refusal_count(), 0)


def test_an_unknown_or_repeated_parameter_is_a_400_naming_it() raises:
    # A misspelled bound must not silently become the default window, and a
    # repeated parameter must not silently keep one of its values.
    var d = ScriptedMetricsReader()
    var queries: List[String] = [
        "metric=m&sinse_ms=5",
        "metric=m&lable.code=500",
        "metric=m&bogus=1",
        "metric=m&since_ms=1&since_ms=2",
        "metric=m&metric=n",
        "metric=m&label.k=a&label.k=b",
        "metric=m&not_label.k=a&not_label.k=b",
        "metric=m&not_label.=x",
    ]
    var names: List[String] = [
        "sinse_ms",
        "lable.code",
        "bogus",
        "since_ms",
        "metric",
        "label.k",
        "not_label.k",
        "not_label.",
    ]
    for i in range(len(queries)):
        var query = queries[i].copy()
        var name = names[i].copy()
        var r = _run(d, query, AllowAll())
        assert_equal(r.status, Int32(400), query + " -> " + _body(r))
        assert_true(
            String("'") + name + String("'") in _body(r),
            query + " -> " + _body(r),
        )
    assert_equal(d.read_count(), 0)
    assert_equal(d.refusal_count(), 0)
    # A label and a not_label on the same key are two matchers, not a repeat.
    _ = _ok(d, String("metric=m&label.k=a&not_label.k=b"))
    assert_equal(len(d.last_query().matchers), 2)


def test_an_empty_name_or_a_malformed_name_escape_is_a_400_naming_it() raises:
    # A segment `=v` names no parameter: skipped, it would drop a value the
    # caller sent (most often a key lost to a bad edit), so it is refused,
    # quoting the segment. A parameter NAME with a `%` that is not followed
    # by two hex digits is refused, quoting the name as written: read as a
    # literal `%`, `label.a%2` would match a label the caller never named.
    var d = ScriptedMetricsReader()
    var queries: List[String] = [
        "metric=m&=v",
        "=v&metric=m",
        "metric=m&=",
        "metric=m&label.a%2=x",
        "metric=m&not_label.a%zz=x",
        "metric=m&label.a%=x",
        "metric=m&label.%g1b=x",
    ]
    var quoted: List[String] = [
        "'=v'",
        "'=v'",
        "'='",
        "'label.a%2'",
        "'not_label.a%zz'",
        "'label.a%'",
        "'label.%g1b'",
    ]
    var problem: List[String] = [
        "empty parameter name",
        "empty parameter name",
        "empty parameter name",
        "malformed percent escape",
        "malformed percent escape",
        "malformed percent escape",
        "malformed percent escape",
    ]
    for i in range(len(queries)):
        var query = queries[i].copy()
        var r = _run(d, query, AllowAll())
        assert_equal(r.status, Int32(400), query + " -> " + _body(r))
        assert_true(quoted[i] in _body(r), query + " -> " + _body(r))
        assert_true(problem[i] in _body(r), query + " -> " + _body(r))
    assert_equal(d.read_count(), 0)
    assert_equal(d.refusal_count(), 0)
    # Not refused: an empty segment (no `=`) is no parameter; an escaped `%`
    # in a label name is a label name; a VALUE keeps a stray `%` literally
    # (the documented decoding, unchanged here); any other non-empty UTF-8
    # label name, spaces and dots included, is the writer's to have used.
    _ = _ok(d, String("metric=m&&label.a%25=x&"))
    var q = d.last_query()
    assert_equal(len(q.matchers), 1)
    assert_equal(q.matchers[0].key, String("a%"))
    _ = _ok(d, String("metric=m&label.k=5%"))
    assert_equal(d.last_query().matchers[0].value, String("5%"))
    _ = _ok(d, String("metric=m&label.http.route=%2F&not_label.Service+Name=x"))
    q = d.last_query()
    assert_equal(q.matchers[0].key, String("http.route"))
    assert_equal(q.matchers[1].key, String("Service Name"))


def test_limits_clamp() raises:
    var d = ScriptedMetricsReader()
    _ = _ok(d, String("metric=m&series_limit=0&point_limit=99999999999999999999"))
    assert_equal(d.last_query().series_limit, 1)
    assert_equal(d.last_query().point_limit, METRICS_MAX_POINT_LIMIT)
    _ = _ok(d, String("metric=m&series_limit=5000"))
    assert_equal(d.last_query().series_limit, METRICS_MAX_SERIES_LIMIT)


def test_reader_refusal_is_a_400_and_no_read() raises:
    var d = ScriptedMetricsReader()
    d.refuse(String("CloudWatch cannot group by a label"))
    var r = _run(d, String("metric=m&group_by=code"), AllowAll())
    assert_equal(r.status, Int32(400))
    assert_equal(
        _body(r),
        String(
            '{"error":"this metrics reader cannot answer: CloudWatch cannot'
            ' group by a label"}'
        ),
    )
    assert_equal(d.refusal_count(), 1)
    assert_equal(d.read_count(), 0)


def test_a_read_fault_is_a_500_naming_it() raises:
    var d = ScriptedMetricsReader()
    d.fail(String('GetMetricData failed: HTTP 403 "AccessDenied"'))
    var r = _run(d, String("metric=m"), AllowAll())
    assert_equal(r.status, Int32(500))
    assert_equal(
        _body(r),
        String(
            '{"error":"metrics read failed: GetMetricData failed: HTTP 403'
            ' \\"AccessDenied\\""}'
        ),
    )


def test_page_rendering() raises:
    var d = ScriptedMetricsReader()
    var s = MetricsSeriesData.named(String('req"s'))
    s.labels.append(MetricsLabel(String("code"), String("200")))
    s.labels.append(MetricsLabel(String("route"), String("/café")))
    s.samples.append(MetricsSample(Int64(60_000_000_000), 1.5))
    s.samples.append(MetricsSample(Int64(120_000_000_000), Float64(0) / Float64(0)))
    var series = List[MetricsSeriesData]()
    series.append(s^)
    series.append(MetricsSeriesData.named(String("empty")))
    d.answer(MetricsPage(series^, True, 4))
    var body = _ok(d, String("metric=m&since_ms=0&until_ms=120000&agg=sum&step_ms=60000"))
    assert_equal(
        body,
        String(
            '{"metric":"m","agg":"sum","since_ms":0,"until_ms":120000,'
            '"step_ms":60000,"series_limit":100,"point_limit":1440,'
            '"returned":2,"truncated":true,"scanned":4,"series":['
            '{"metric":"req\\"s","labels":{"code":"200","route":"/café"},'
            '"samples":[[60000000000,1.5],[120000000000,null]]},'
            '{"metric":"empty","labels":{},"samples":[]}]}'
        ),
    )


def test_empty_answer_renders_complete() raises:
    var d = ScriptedMetricsReader()
    var body = _ok(d, String("metric=m&since_ms=5&until_ms=5"))
    assert_true('"returned":0,"truncated":false,"scanned":0,"series":[]' in body, body)


def main() raises:
    test_path_match()
    test_every_refusal_is_one_404_and_access_runs_first()
    test_header_token_allows_the_exact_token()
    test_metric_is_required()
    test_defaults_reach_the_reader()
    test_arguments_reach_the_reader()
    test_a_bad_argument_is_a_400_never_a_default()
    test_an_unknown_or_repeated_parameter_is_a_400_naming_it()
    test_an_empty_name_or_a_malformed_name_escape_is_a_400_naming_it()
    test_limits_clamp()
    test_reader_refusal_is_a_400_and_no_read()
    test_a_read_fault_is_a_500_naming_it()
    test_page_rendering()
    test_empty_answer_renders_complete()
    print("OK")
