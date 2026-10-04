# komira_log_query: the `GET /internal/logs` route over a fake `ServiceLogSearch`.
#
# What is pinned, in the route's own order: the path match; the four refusals
# (no configured token, absent token, wrong token, no reader) answer one
# byte-identical 404, and authorization runs before argument checks; the window
# defaults and bounds; the limit clamp; term decoding; the conformer-raise split
# (400 for a term-free window, 500 otherwise); the page rendering, including the
# embed-or-quote rule for `source_json`; and that the rendered body is valid
# UTF-8 JSON for any input (non-ASCII terms and blobs are copied, not re-encoded
# byte by byte; non-finite scores render as null; a bound that does not fit the
# nanosecond window is refused rather than wrapped).
#
# The fake echoes the query it received as a hit, so the window, term and limit
# the conformer saw are read back from the rendered body; no shared state.

from std.memory import ArcPointer

from komira_http_core.codec.types import HttpMethod, HttpRequest, HttpResponse
from komira_log_query import (
    ErasedServiceLogSearch,
    SERVICE_LOG_DEFAULT_LIMIT,
    SERVICE_LOG_DEFAULT_LOOKBACK_MS,
    SERVICE_LOG_MAX_LIMIT,
    SERVICE_LOG_ROUTE_PATH,
    SERVICE_LOG_TOKEN_HEADER,
    ServiceLogHit,
    ServiceLogPage,
    ServiceLogQuery,
    ServiceLogSearch,
    is_service_log_request,
    service_log_response,
)

from std.testing import assert_equal, assert_false, assert_true


comptime TOKEN = "operator-secret-0123456789"
# A "now" far from any real clock: 4e12 ms. Only arithmetic on it matters.
comptime NOW_MS: Int64 = 4_000_000_000_000
comptime NOW_NS: Int64 = NOW_MS * 1_000_000
comptime MAX_MS: Int64 = 9_223_372_036_854  # Int64.MAX // 1_000_000


def _hex_of(s: String) -> String:
    var digits = "0123456789abcdef".as_bytes()
    var b = s.as_bytes()
    var out = List[UInt8]()
    for i in range(len(b)):
        out.append(digits[Int(b[i] >> 4)])
        out.append(digits[Int(b[i] & 0xF)])
    return String(unsafe_from_utf8=out^)


def _echo_blob(q: ServiceLogQuery) -> String:
    return (
        String('{"t0":')
        + String(q.t0_ns)
        + String(',"t1":')
        + String(q.t1_ns)
        + String(',"term_hex":"')
        + _hex_of(q.term)
        + String('","limit":')
        + String(q.limit)
        + String("}")
    )


struct Fake(ServiceLogSearch, Movable, Deinitable):
    var hits: List[ServiceLogHit]
    var total: Int
    var scanned: Int
    var fail: String
    var echo: Bool

    def __init__(out self, echo: Bool = True):
        self.hits = List[ServiceLogHit]()
        self.total = 0
        self.scanned = 0
        self.fail = String("")
        self.echo = echo

    def scan(mut self, q: ServiceLogQuery) raises -> ServiceLogPage:
        if self.fail.byte_length() > 0:
            raise Error(self.fail)
        var hits = self.hits.copy()
        if self.echo:
            hits.append(ServiceLogHit(Int64(7), 0.0, _echo_blob(q)))
        return ServiceLogPage(hits^, self.total, self.scanned)


struct Counted(ServiceLogSearch, Movable, Deinitable):
    var token: ArcPointer[Int]

    def __init__(out self, var token: ArcPointer[Int]):
        self.token = token^

    def scan(mut self, q: ServiceLogQuery) raises -> ServiceLogPage:
        return ServiceLogPage()


def _req(query: String, token: String = TOKEN) -> HttpRequest:
    var r = HttpRequest(HttpMethod.get(), String(SERVICE_LOG_ROUTE_PATH))
    r.query_string = query
    if token.byte_length() > 0:
        r.headers[String(SERVICE_LOG_TOKEN_HEADER)] = token
    return r^


def _wired(var fake: Fake) -> Optional[ErasedServiceLogSearch]:
    return Optional(ErasedServiceLogSearch.erase(fake^))


def _body(r: HttpResponse) -> String:
    return String(unsafe_from_utf8=r.body.copy())


def _call(query: String, var fake: Fake = Fake()) -> HttpResponse:
    var s = _wired(fake^)
    return service_log_response(s, _req(query), String(TOKEN), NOW_NS)


def _expect_echo(
    r: HttpResponse, t0_ms: Int64, t1_ms: Int64, term: String, limit: Int
) raises:
    assert_equal(r.status, Int32(200), _body(r))
    var want = (
        String('"t0":')
        + String(t0_ms * 1_000_000)
        + String(',"t1":')
        + String(t1_ms * 1_000_000)
        + String(',"term_hex":"')
        + _hex_of(term)
        + String('","limit":')
        + String(limit)
        + String("}")
    )
    assert_true(want in _body(r), _body(r) + " lacks " + want)


def _is_valid_utf8(b: List[UInt8]) -> Bool:
    var i = 0
    var n = len(b)
    while i < n:
        var c = Int(b[i])
        var need = 0
        var lo = 0x80
        if c < 0x80:
            i += 1
            continue
        elif c >= 0xC2 and c <= 0xDF:
            need = 1
        elif c >= 0xE0 and c <= 0xEF:
            need = 2
            if c == 0xE0:
                lo = 0xA0
        elif c >= 0xF0 and c <= 0xF4:
            need = 3
            if c == 0xF0:
                lo = 0x90
        else:
            return False
        if i + need >= n:
            return False
        var hi = 0xBF
        if c == 0xED:
            hi = 0x9F
        if c == 0xF4:
            hi = 0x8F
        var first = Int(b[i + 1])
        if first < lo or first > hi:
            return False
        for k in range(2, need + 1):
            var cc = Int(b[i + k])
            if cc < 0x80 or cc > 0xBF:
                return False
        i += need + 1
    return True


# -----------------------------------------------------------------------------
# Path match.
# -----------------------------------------------------------------------------
def test_path_match() raises:
    assert_true(is_service_log_request(_req(String(""))))
    var post = HttpRequest(HttpMethod.post(), String(SERVICE_LOG_ROUTE_PATH))
    assert_false(is_service_log_request(post))
    for p in ["/internal/logs/", "/internal/logs/x", "/internal/log", "/logs"]:
        var r = HttpRequest(HttpMethod.get(), String(p))
        assert_false(is_service_log_request(r), String(p))


# -----------------------------------------------------------------------------
# Refusals: one byte-identical 404, authorization before argument checks.
# -----------------------------------------------------------------------------
def _same_response(a: HttpResponse, b: HttpResponse) raises:
    assert_equal(a.status, b.status)
    assert_equal(_body(a), _body(b))
    assert_equal(a.headers[String("content-type")], b.headers[String("content-type")])
    assert_equal(
        a.headers[String("content-length")], b.headers[String("content-length")]
    )


def test_refusals_are_one_404() raises:
    var bad_args = String("since_ms=9&until_ms=1&limit=x")
    # 1. no expected token configured (even when the caller presents one).
    var s1 = _wired(Fake())
    var r1 = service_log_response(s1, _req(bad_args), String(""), NOW_NS)
    # 2. absent presented token.
    var s2 = _wired(Fake())
    var r2 = service_log_response(
        s2, _req(bad_args, String("")), String(TOKEN), NOW_NS
    )
    # 3. wrong token: a prefix, an extension, one changed byte, another case.
    var s3 = _wired(Fake())
    var wrong = List[String]()
    wrong.append(String("operator-secret-012345678"))
    wrong.append(String(TOKEN) + String("x"))
    wrong.append(String("operator-secret-0123456788"))
    wrong.append(String("OPERATOR-SECRET-0123456789"))
    # 4. the right token, but no reader wired.
    var none = Optional[ErasedServiceLogSearch](None)
    var r4 = service_log_response(none, _req(bad_args), String(TOKEN), NOW_NS)

    assert_equal(r1.status, Int32(404))
    assert_equal(_body(r1), String('{"error":"not found"}'))
    _same_response(r1, r2)
    _same_response(r1, r4)
    for i in range(len(wrong)):
        var r3 = service_log_response(
            s3, _req(bad_args, wrong[i]), String(TOKEN), NOW_NS
        )
        _same_response(r1, r3)


def test_authorized_bad_window_is_400() raises:
    var r = _call(String("since_ms=9&until_ms=1"))
    assert_equal(r.status, Int32(400))
    assert_true(String("since_ms' (9) is after 'until_ms' (1)") in _body(r))


# -----------------------------------------------------------------------------
# Window, limit and term reach the conformer as stated.
# -----------------------------------------------------------------------------
def test_default_window_and_limit() raises:
    var r = _call(String(""))
    _expect_echo(
        r,
        NOW_MS - SERVICE_LOG_DEFAULT_LOOKBACK_MS,
        NOW_MS,
        String(""),
        SERVICE_LOG_DEFAULT_LIMIT,
    )


def test_explicit_inclusive_window() raises:
    _expect_echo(_call(String("since_ms=10&until_ms=20")), 10, 20, String(""), 50)
    # since == until is a one-millisecond window, not an error.
    _expect_echo(_call(String("since_ms=20&until_ms=20")), 20, 20, String(""), 50)
    # until alone moves the default since with it.
    _expect_echo(
        _call(String("until_ms=5000000000")),
        5_000_000_000 - SERVICE_LOG_DEFAULT_LOOKBACK_MS,
        5_000_000_000,
        String(""),
        50,
    )


def test_limit_clamp() raises:
    _expect_echo(_call(String("limit=7")), NOW_MS - SERVICE_LOG_DEFAULT_LOOKBACK_MS, NOW_MS, String(""), 7)
    _expect_echo(_call(String("limit=0")), NOW_MS - SERVICE_LOG_DEFAULT_LOOKBACK_MS, NOW_MS, String(""), 1)
    _expect_echo(_call(String("limit=100000")), NOW_MS - SERVICE_LOG_DEFAULT_LOOKBACK_MS, NOW_MS, String(""), SERVICE_LOG_MAX_LIMIT)
    # malformed falls back to the default, it is not an error.
    _expect_echo(_call(String("limit=-3")), NOW_MS - SERVICE_LOG_DEFAULT_LOOKBACK_MS, NOW_MS, String(""), 50)
    _expect_echo(_call(String("limit=abc")), NOW_MS - SERVICE_LOG_DEFAULT_LOOKBACK_MS, NOW_MS, String(""), 50)
    _expect_echo(_call(String("limit=")), NOW_MS - SERVICE_LOG_DEFAULT_LOOKBACK_MS, NOW_MS, String(""), 50)


def test_term_decoding() raises:
    var d = NOW_MS - SERVICE_LOG_DEFAULT_LOOKBACK_MS
    _expect_echo(_call(String("q=deploy+failed")), d, NOW_MS, String("deploy failed"), 50)
    _expect_echo(_call(String("q=deploy%20failed")), d, NOW_MS, String("deploy failed"), 50)
    _expect_echo(_call(String("q=%41b%2b")), d, NOW_MS, String("Ab+"), 50)
    # a malformed escape passes through literally.
    _expect_echo(_call(String("q=%zz%4")), d, NOW_MS, String("%zz%4"), 50)
    # the first occurrence wins; a key that is a prefix of another is not it.
    _expect_echo(_call(String("qq=no&q=yes&q=later")), d, NOW_MS, String("yes"), 50)


# -----------------------------------------------------------------------------
# Window bounds that do not fit the nanosecond window are refused, not wrapped.
# -----------------------------------------------------------------------------
def test_largest_representable_until() raises:
    _expect_echo(
        _call(String("since_ms=0&until_ms=") + String(MAX_MS)),
        0,
        MAX_MS,
        String(""),
        50,
    )


def test_until_beyond_nanosecond_range_is_400() raises:
    var r = _call(String("since_ms=0&until_ms=") + String(MAX_MS + 1))
    assert_equal(r.status, Int32(400), _body(r))
    assert_true(String("'until_ms'") in _body(r), _body(r))


def test_since_beyond_nanosecond_range_is_400() raises:
    var big = String(MAX_MS + 1)
    var r = _call(String("since_ms=") + big + String("&until_ms=") + big)
    assert_equal(r.status, Int32(400), _body(r))
    assert_true(String("'since_ms'") in _body(r), _body(r))


def test_overflowing_digits_are_malformed() raises:
    # 2^64 + 1: a wrapping parser reads 1. It is malformed, so the default holds.
    _expect_echo(
        _call(String("since_ms=18446744073709551617")),
        NOW_MS - SERVICE_LOG_DEFAULT_LOOKBACK_MS,
        NOW_MS,
        String(""),
        50,
    )
    _expect_echo(
        _call(String("limit=18446744073709551623")),
        NOW_MS - SERVICE_LOG_DEFAULT_LOOKBACK_MS,
        NOW_MS,
        String(""),
        50,
    )


# -----------------------------------------------------------------------------
# A conformer that raises.
# -----------------------------------------------------------------------------
def test_conformer_raise_split() raises:
    var f1 = Fake()
    f1.fail = String("needs a term on this format")
    var r1 = _call(String(""), f1^)
    assert_equal(r1.status, Int32(400))
    assert_true(String("needs a term on this format") in _body(r1), _body(r1))
    var f2 = Fake()
    f2.fail = String("bucket said no")
    var r2 = _call(String("q=x"), f2^)
    assert_equal(r2.status, Int32(500))
    assert_equal(
        _body(r2), String('{"error":"log index read failed: bucket said no"}')
    )


# -----------------------------------------------------------------------------
# Page rendering.
# -----------------------------------------------------------------------------
def test_empty_page_renders_every_count() raises:
    var f = Fake(echo=False)
    var r = _call(String("since_ms=1&until_ms=2&limit=3&q=a%22b"), f^)
    assert_equal(r.status, Int32(200))
    assert_equal(
        _body(r),
        String(
            '{"index":"logs","q":"a\\"b","since_ms":1,"until_ms":2,"limit":3,'
            '"total":0,"scanned":0,"returned":0,"hits":[]}'
        ),
    )
    assert_equal(r.headers[String("content-type")], String("application/json"))
    assert_equal(r.headers[String("content-length")], String(len(r.body)))


def _render_one(blob: String, score: Float64 = 1.5) raises -> String:
    var f = Fake(echo=False)
    f.hits.append(ServiceLogHit(Int64(42), score, blob))
    f.total = 9
    f.scanned = 2
    var r = _call(String("since_ms=1&until_ms=2"), f^)
    assert_equal(r.status, Int32(200))
    assert_true(_is_valid_utf8(r.body), "response body is not UTF-8")
    var body = _body(r)
    assert_true(
        String('"total":9,"scanned":2,"returned":1,"hits":[') in body, body
    )
    return body


def _embedded(blob: String) raises -> Bool:
    var body = _render_one(blob)
    return (String('"source":') + blob + String("}]}")) in body


def test_source_embed_or_quote() raises:
    # embedded verbatim: one well-formed object, whitespace around allowed.
    for ok in [
        '{}',
        '{"a":1}',
        ' {"message":"x","args":{"k":[1,2.5e-3,true,false,null,"s"]}} ',
        '{"u":"\\u00e9\\n","n":-0.0}',
        '{"m":"café — ok"}',
    ]:
        assert_true(_embedded(String(ok)), String(ok))
    # quoted: everything else, including every malformed object.
    for bad in [
        '{"message":"half a li',
        '{"a":1',
        '{"a":1} x',
        '{"a":01}',
        '{"a":1,}',
        '{"a" 1}',
        '{"a":"\\u12"}',
        '{"a":"\\q"}',
        '{"a":"tab\there"}',
        '[1,2]',
        '"str"',
        '',
        'nul',
    ]:
        assert_false(_embedded(String(bad)), String(bad))


def test_source_depth_ceiling() raises:
    var deep64 = String("")
    var deep65 = String("")
    for _ in range(64):
        deep64 += '{"a":'
    deep65 = deep64 + '{"a":'
    deep64 += "1"
    deep65 += "1"
    for _ in range(64):
        deep64 += "}"
        deep65 += "}"
    deep65 += "}"
    assert_true(_embedded(deep64))
    assert_false(_embedded(deep65))


def test_quoted_source_is_escaped_exactly() raises:
    var body = _render_one(String('{"message":"a\\b\t"'))
    assert_true(
        String('"source":"{\\"message\\":\\"a\\\\b\\t\\""}') in body, body
    )
    var ctl = List[UInt8]()
    ctl.append(UInt8(0x01))
    ctl.append(UInt8(0x1F))
    var body2 = _render_one(String(unsafe_from_utf8=ctl^))
    assert_true(String('"source":"\\u0001\\u001f"') in body2, body2)


def test_hit_fields() raises:
    var body = _render_one(String('{"m":1}'))
    assert_true(
        String('{"timestamp_ns":42,"score":1.5,"source":{"m":1}}') in body, body
    )


# -----------------------------------------------------------------------------
# The rendered body is valid UTF-8 JSON for any input.
# -----------------------------------------------------------------------------
def test_non_ascii_term_is_not_double_encoded() raises:
    var d = NOW_MS - SERVICE_LOG_DEFAULT_LOOKBACK_MS
    var r = _call(String("q=%C3%A9t%C3%A9+%E2%80%94"))
    _expect_echo(r, d, NOW_MS, String("été —"), 50)
    assert_true(_is_valid_utf8(r.body))
    assert_true(String('"q":"été —"') in _body(r), _body(r))


def test_non_ascii_quoted_source_is_not_double_encoded() raises:
    var body = _render_one(String('{"message":"café'))
    assert_true(
        String('"source":"{\\"message\\":\\"café"') in body, body
    )


def test_invalid_utf8_term_renders_replacement() raises:
    # %FF and a lone continuation byte decode to bytes that are not UTF-8.
    var r = _call(String("q=a%FFb%80c"))
    assert_equal(r.status, Int32(200))
    assert_true(_is_valid_utf8(r.body), "response body is not UTF-8")
    assert_true(String('"q":"a\\ufffdb\\ufffdc"') in _body(r), _body(r))


def test_non_finite_score_renders_null() raises:
    var nan = Float64(0.0) / Float64(0.0)
    var inf = Float64(1.0) / Float64(0.0)
    for s in [nan, inf, -inf]:
        var body = _render_one(String('{"m":1}'), s)
        assert_true(String('"score":null,') in body, body)


# -----------------------------------------------------------------------------
# The erased facade owns its conformer exactly once.
# -----------------------------------------------------------------------------
def _erase_scan_drop(token: ArcPointer[Int]) raises:
    var e = ErasedServiceLogSearch.erase(Counted(token.copy()))
    assert_equal(Int(token.count()), 2)
    var page = e.scan(ServiceLogQuery(Int64(0), Int64(1), String(""), 1))
    assert_equal(page.sources_scanned, 0)


def test_erased_facade_drops_conformer_once() raises:
    var token = ArcPointer[Int](5)
    _erase_scan_drop(token)
    assert_equal(Int(token.count()), 1)
    assert_equal(token[], 5)


def main() raises:
    test_path_match()
    test_refusals_are_one_404()
    test_authorized_bad_window_is_400()
    test_default_window_and_limit()
    test_explicit_inclusive_window()
    test_limit_clamp()
    test_term_decoding()
    test_largest_representable_until()
    test_until_beyond_nanosecond_range_is_400()
    test_since_beyond_nanosecond_range_is_400()
    test_overflowing_digits_are_malformed()
    test_conformer_raise_split()
    test_empty_page_renders_every_count()
    test_source_embed_or_quote()
    test_source_depth_ceiling()
    test_quoted_source_is_escaped_exactly()
    test_hit_fields()
    test_non_ascii_term_is_not_double_encoded()
    test_non_ascii_quoted_source_is_not_double_encoded()
    test_invalid_utf8_term_renders_replacement()
    test_non_finite_score_renders_null()
    test_erased_facade_drops_conformer_once()
    print("test_service_log_route: OK")
