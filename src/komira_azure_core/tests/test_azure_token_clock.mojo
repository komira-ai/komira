# AzureImdsProvider and ServicePrincipalProvider on an injected ManualClock:
# the token's expiry and the refresh margin are read on the clock the
# provider was given, never on the wall clock.
#
# Rows, for each provider: a refresh at clock reading T caches the token with
# expiry T + expires_in * 1000 exactly; with the default 300 s margin the
# token is not due one ms before `expiry - margin`, is due at that reading
# exactly, and stays due at and past expiry; a zero margin makes it due at
# expiry and not one ms before; a clock that does not move keeps the answer.
# The ManualClock starts near zero, about 1.7e12 ms before the wall clock, so
# a provider that read the wall clock for the expiry or for the check would
# fail the exact equalities and the not-due rows. The last row scans the two
# providers' sources (staged as this test's data): neither names the wall
# clock, and each reads its injected clock at the refresh and at the check.
#
# What the production clock guarantees: `SystemClock` (komira_retry) reads
# std.time.perf_counter_ns, the process's monotonic clock, which a step of
# the wall clock (settimeofday, an NTP step) does not move. The test cannot
# step the host's wall clock; it proves the providers read nothing but the
# injected clock, so the monotonic clock is the only time they see.
from std.sys.info import CompilationTarget
from std.testing import assert_equal, assert_false, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_EPOLL, BACKEND_KQUEUE, Reactor
from komira_async.runtime.runtime import PerCoreAsyncRuntime
from komira_async.runtime.runtime_trait import Runtime
from komira_azure_core import AzureImdsProvider, ServicePrincipalProvider
from komira_http_client.body import RequestBody
from komira_http_client.header_map import HeaderMap
from komira_http_client.response_body import BufferedResponseBody
from komira_http_client.service import ClientRequest, HttpService
from komira_http_client.state_machine import ClientResponse
from komira_http_core.transport.io_stream import Connector
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream
from komira_retry import ManualClock, MonotonicClock


comptime _RT = PerCoreAsyncRuntime[NoopSink]

comptime _START_MS: Int64 = 1_000
comptime _LIFETIME_MS: Int64 = 3_599_000
comptime _MARGIN_MS: Int64 = 300_000
comptime _EXPIRY_MS: Int64 = _START_MS + _LIFETIME_MS


struct AnswerService(HttpService, Movable, Deinitable):
    """Answers every call with 200 and one scripted body."""

    var body: String

    def __init__(out self, var body: String):
        self.body = body^

    def call[RT: Runtime, C: Connector, B: RequestBody](
        mut self,
        var req: ClientRequest[B],
        mut connector: C,
        mut reactor: Reactor[RT.Sink],
    ) raises -> ClientResponse[BufferedResponseBody]:
        _ = req^
        var bytes = List[UInt8]()
        bytes.extend(Span(self.body.as_bytes()))
        var resp = ClientResponse[BufferedResponseBody](
            BufferedResponseBody.from_bytes(bytes^)
        )
        resp.status = Int32(200)
        resp.reason = String("Scripted")
        resp.headers = HeaderMap()
        resp.connection_close = False
        return resp^


def _reactor() raises -> Reactor[NoopSink]:
    comptime if CompilationTarget.is_linux():
        return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL)
    return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_KQUEUE)


def _imds() -> AzureImdsProvider[ManualClock]:
    return AzureImdsProvider.with_endpoint(
        String("http://127.0.0.1:18080")
    ).with_clock(ManualClock(_START_MS))


def _sp() raises -> ServicePrincipalProvider[ManualClock]:
    return ServicePrincipalProvider.with_login_endpoint(
        String("t"),
        String("c"),
        String("s"),
        String("http"),
        String("127.0.0.1"),
        UInt16(18081),
    ).with_clock(ManualClock(_START_MS))


def _refresh_imds[K: MonotonicClock](mut p: AzureImdsProvider[K]) raises:
    var svc = AnswerService(String('{"access_token":"i","expires_in":"3599"}'))
    var conn = ScriptedConnector.with_stream(ScriptedStream.empty())
    var reactor = _reactor()
    p.refresh_with_service[AnswerService, _RT, ScriptedConnector](
        svc, conn, reactor
    )


def _refresh_sp[K: MonotonicClock](mut p: ServicePrincipalProvider[K]) raises:
    var svc = AnswerService(String('{"access_token":"s","expires_in":3599}'))
    var conn = ScriptedConnector.with_stream(ScriptedStream.empty())
    var reactor = _reactor()
    p.refresh_with_service[AnswerService, _RT, ScriptedConnector](
        svc, conn, reactor
    )


def test_imds_expiry_and_margin_on_the_injected_clock() raises:
    var p = _imds()
    assert_true(p.is_expired_or_near_expiry(), "no token yet: due")
    _refresh_imds(p)
    assert_equal(p.cached_expiry_ms(), _EXPIRY_MS)
    assert_equal(p.credential().expiry_ms, _EXPIRY_MS)
    # Just fetched, the clock not moved: not due, and asking again does not
    # change the answer.
    assert_false(p.is_expired_or_near_expiry(), "fresh token at the fetch")
    assert_false(p.is_expired_or_near_expiry(), "fresh token, asked twice")
    p.clock().now = _EXPIRY_MS - _MARGIN_MS - 1
    assert_false(p.is_expired_or_near_expiry(), "one ms before the margin")
    p.clock().now = _EXPIRY_MS - _MARGIN_MS
    assert_true(p.is_expired_or_near_expiry(), "exactly at the margin")
    p.clock().now = _EXPIRY_MS
    assert_true(p.is_expired_or_near_expiry(), "at expiry")
    p.clock().now = _EXPIRY_MS + 1
    assert_true(p.is_expired_or_near_expiry(), "past expiry")


def test_sp_expiry_and_margin_on_the_injected_clock() raises:
    var p = _sp()
    assert_true(p.is_expired_or_near_expiry(), "no token yet: due")
    _refresh_sp(p)
    assert_equal(p.cached_expiry_ms(), _EXPIRY_MS)
    assert_equal(p.credential().expiry_ms, _EXPIRY_MS)
    assert_false(p.is_expired_or_near_expiry(), "fresh token at the fetch")
    assert_false(p.is_expired_or_near_expiry(), "fresh token, asked twice")
    p.clock().now = _EXPIRY_MS - _MARGIN_MS - 1
    assert_false(p.is_expired_or_near_expiry(), "one ms before the margin")
    p.clock().now = _EXPIRY_MS - _MARGIN_MS
    assert_true(p.is_expired_or_near_expiry(), "exactly at the margin")
    p.clock().now = _EXPIRY_MS
    assert_true(p.is_expired_or_near_expiry(), "at expiry")
    p.clock().now = _EXPIRY_MS + 1
    assert_true(p.is_expired_or_near_expiry(), "past expiry")


def test_zero_margin_is_due_at_expiry() raises:
    var p = _imds()
    p.refresh_margin_seconds = 0
    _refresh_imds(p)
    p.clock().now = _EXPIRY_MS - 1
    assert_false(p.is_expired_or_near_expiry(), "imds: one ms before expiry")
    p.clock().now = _EXPIRY_MS
    assert_true(p.is_expired_or_near_expiry(), "imds: at expiry")
    var s = _sp()
    s.refresh_margin_seconds = 0
    _refresh_sp(s)
    s.clock().now = _EXPIRY_MS - 1
    assert_false(s.is_expired_or_near_expiry(), "sp: one ms before expiry")
    s.clock().now = _EXPIRY_MS
    assert_true(s.is_expired_or_near_expiry(), "sp: at expiry")


def test_a_later_refresh_reads_the_clock_again() raises:
    # A second refresh after the clock moved caches an expiry from the new
    # reading, so the margin moves with it.
    var p = _imds()
    _refresh_imds(p)
    p.clock().now = _EXPIRY_MS - _MARGIN_MS
    assert_true(p.is_expired_or_near_expiry())
    _refresh_imds(p)
    assert_equal(p.cached_expiry_ms(), _EXPIRY_MS - _MARGIN_MS + _LIFETIME_MS)
    assert_false(p.is_expired_or_near_expiry())


def _count(hay: String, needle: String) -> Int:
    var n = 0
    var at = hay.find(needle)
    while at >= 0:
        n += 1
        at = hay.find(needle, at + needle.byte_length())
    return n


def _read(name: String) raises -> String:
    with open(String("src/") + name, "r") as f:
        return f.read()


def test_the_providers_read_no_wall_clock() raises:
    var files: List[String] = [
        "creds_managed_identity.mojo",
        "creds_service_principal.mojo",
    ]
    for i in range(len(files)):
        var text = _read(files[i])
        assert_equal(_count(text, "now_unix_ms"), 0, files[i] + " reads the wall clock")
        assert_equal(_count(text, "komira_clock"), 0, files[i] + " imports komira_clock")
        # Not vacuous: the file is the provider, and reads its injected
        # clock at the refresh and at the check.
        assert_equal(
            _count(text, "self._clock.now_ms()"), 2, files[i] + " clock reads"
        )
        assert_true(text.byte_length() > 5000, files[i] + " is staged whole")


def main() raises:
    test_imds_expiry_and_margin_on_the_injected_clock()
    test_sp_expiry_and_margin_on_the_injected_clock()
    test_zero_margin_is_due_at_expiry()
    test_a_later_refresh_reads_the_clock_again()
    test_the_providers_read_no_wall_clock()
    print("OK")
