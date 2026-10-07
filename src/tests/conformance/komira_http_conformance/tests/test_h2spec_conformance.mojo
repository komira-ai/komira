# =============================================================================
# test_h2spec_conformance.mojo -- komira_http_server against h2spec
# =============================================================================
#
# One real `HttpServer` on 127.0.0.1 (an ephemeral port), holding the fixture
# leaf with ALPN `[h2, http/1.1]` and routes `GET /` and `POST /`, is stepped
# on one thread. On another, the pinned h2spec binary (third_party/h2spec,
# staged as this test's data) runs its whole suite, strict cases included
# (`-S`), against it over TLS (`-t -k`: the server's HTTP/2 is reached only
# through ALPN h2, it has no cleartext h2), writing a JUnit report into
# TEST_TMPDIR. Then one h2 GET through komira_http_client, verifying the
# certificate, on a fresh connection.
#
# The suite supplies every case; this file only starts the server, runs the
# tool and reads its report. It then requires:
#   1. h2spec ran to completion: it exited by itself (0 when every case
#      passed, 1 when one failed), within its deadline, and wrote a report;
#   2. the report and h2spec's own stdout summary agree on the totals, the
#      run reported exactly the pinned suite's cases (_H2SPEC_CASES), and more
#      than 100 of them ran rather than being skipped, so a vacuous run or a
#      misread report fails;
#   3. the shrink-only allowlist gate (allowlist.mojo) passes against
#      h2spec_allowlist.txt: every failed or skipped case is listed with a
#      reason, and no listed case passes;
#   4. the server is still serving after the suite: the GET answers 200 with
#      the h2 serve loop's body, over h2 (the client dialed its h2 pool).
#
# Defects it catches: any h2 framing, HPACK, stream-state, flow-control or
# error-handling regression h2spec has a case for (a newly failing case is
# not on the list), a case that stops running because the server stopped
# advertising what it needs (a new skip), a server that dies or wedges under
# hostile frames (the process aborts, h2spec cannot dial, or the GET fails),
# and a fix nobody recorded (the case passes, so its allowlist line is stale).
#
# Every case's outcome is printed, so the log of a red run is the evidence.
# =============================================================================

from std.pathlib import Path
from std.testing import assert_equal, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_http_client.body import EmptyBody
from komira_http_client.client import HttpClient, build_get_request
from komira_http_client.header_map import HeaderMap
from komira_http_client.tls_connector import TlsConnector
from komira_http_client.url import Url
from komira_http_core.codec import HttpMethod
from komira_http_core.tls import tls_init
from komira_http_core.transport.kernel_tcp import KernelTcpConnector
from komira_http_server.routing import Router
from komira_http_server.server import HttpServer, HttpServerConfig
from komira_runtime_paths import data_path, test_tmpdir
from komira_supervisor import ChildSpec

from komira_http_conformance import (
    CASE_FAILED,
    CASE_PASSED,
    ChildOutcome,
    ClientLeg,
    client_tls_connector,
    count,
    gate,
    parse_junit,
    parse_summary,
    run_child,
    serve_while,
    server_tls_config,
)

comptime _Rt = BlockingRuntime[NoopSink]
comptime _ALLOWLIST = "src/tests/conformance/komira_http_conformance/h2spec_allowlist.txt"
# h2spec's per-case timeout, in seconds: how long a case waits for the
# server's answer before it fails. h2spec's default is 2; a passing case needs
# a TLS handshake and the answer of a server stepped by one thread on a shared
# worker, so 5 leaves room for a slow worker without hiding a hang.
comptime _CASE_TIMEOUT_S = 5
# The whole suite's budget, under the remote action's 600 s limit. A green run
# takes seconds. A run in which most cases wait out their timeout (147 x 5 s)
# does not fit: it is stopped here and the test is red, which is right, since
# such a run means the server stopped answering.
comptime _SUITE_DEADLINE_S = 400
comptime _SERVE_DEADLINE_S = 480
comptime _REQUEST_TIMEOUT_US = 10_000_000
# The number of cases of the pinned suite (third_party/h2spec, v2.6.0, run
# with -S). A new pin changes it; the gate refuses any other count.
comptime _H2SPEC_CASES = 147
# Cases that must actually run (pass or fail), however many the allowlist
# excuses as skips.
comptime _MIN_RUN_CASES = 100


def _text(bytes: List[UInt8]) -> String:
    var s = String()
    for b in bytes:
        s += chr(Int(b))
    return s^


struct _SuiteThenGet(ClientLeg):
    """h2spec's suite, then one verified h2 GET. Each step records what it saw
    instead of raising, so the GET runs even when h2spec failed."""

    var port: UInt16
    var report_path: String
    var suite: Optional[ChildOutcome]
    var suite_error: String
    var status: Int32
    var body: String
    var h2_dials: Int
    var get_error: String

    def __init__(out self, port: UInt16, var report_path: String):
        self.port = port
        self.report_path = report_path^
        self.suite = None
        self.suite_error = String("")
        self.status = Int32(-1)
        self.body = String("")
        self.h2_dials = -1
        self.get_error = String("")

    def run(mut self) raises:
        try:
            var spec = ChildSpec(data_path(String("h2spec")))
            spec.with_arg(String("-h"))
            spec.with_arg(String("127.0.0.1"))
            spec.with_arg(String("-p"))
            spec.with_arg(String(Int(self.port)))
            spec.with_arg(String("-t"))
            spec.with_arg(String("-k"))
            spec.with_arg(String("-S"))
            spec.with_arg(String("-o"))
            spec.with_arg(String(_CASE_TIMEOUT_S))
            spec.with_arg(String("-j"))
            spec.with_arg(self.report_path)
            self.suite = run_child(spec, _SUITE_DEADLINE_S)
        except e:
            self.suite_error = String(e)
        try:
            var client = HttpClient[
                TlsConnector[KernelTcpConnector]
            ].with_request_timeout_us(client_tls_connector(), _REQUEST_TIMEOUT_US)
            var rt = _Rt.new(NoopSink(_placeholder=UInt8(0)))
            ref reactor = rt.reactor()
            var req = build_get_request(
                Url.https(String("127.0.0.1"), self.port, String("/")), HeaderMap()
            )
            var resp = client.send_buffered[_Rt, EmptyBody](req^, reactor)
            self.status = resp.status
            self.body = _text(resp.body.take_bytes())
            self.h2_dials = client.h2_pool_dials_total()
        except e:
            self.get_error = String(e)


def _tail(s: String, n: Int) -> String:
    var b = s.byte_length()
    if b <= n:
        return s
    return "..." + String(s[byte = b - n :])


def test_h2spec_suite_against_http_server() raises:
    var router = Router()
    router.add(HttpMethod.get(), "/", 0)
    router.add(HttpMethod.post(), "/", 0)
    var server = HttpServer(
        config=HttpServerConfig.default_ephemeral(),
        router=router^,
        tls_config=server_tls_config(),
    )
    var port = server.local_port()
    var leg = _SuiteThenGet(port, test_tmpdir() + "/h2spec_report.xml")
    serve_while(server, leg, _SERVE_DEADLINE_S)

    # 1. h2spec ran to completion and wrote its report.
    if leg.suite_error != "":
        raise Error("h2spec did not start: " + leg.suite_error)
    ref suite = leg.suite.value()
    print("h2spec " + suite.describe())
    if suite.timed_out or suite.exit.signal >= Int32(0) or suite.exit.exit_code > Int32(1):
        raise Error(
            "h2spec did not run to completion (" + suite.describe() + ")\nstdout: "
            + _tail(suite.stdout, 4000) + "\nstderr: " + _tail(suite.stderr, 2000)
        )
    if not Path(leg.report_path).exists():
        raise Error(
            "h2spec wrote no report (" + suite.describe() + ")\nstdout: "
            + _tail(suite.stdout, 4000) + "\nstderr: " + _tail(suite.stderr, 2000)
        )

    # 2. The report and the stdout summary agree, and the run is not vacuous.
    var results = parse_junit(Path(leg.report_path).read_text())
    for ref r in results:
        var mark: String
        if r.outcome == CASE_PASSED:
            mark = String("pass")
        elif r.outcome == CASE_FAILED:
            mark = String("FAIL")
        else:
            mark = String("skip")
        print("  " + mark + " " + r.id + " " + r.desc)
        if r.outcome == CASE_FAILED:
            print("       " + r.detail.replace("\n", " | "))
    var from_report = count(results)
    var from_stdout = parse_summary(suite.stdout)
    print("h2spec summary: " + from_stdout.describe())
    for line in suite.stdout.split("\n"):
        if String(line).find("Finished in ") >= 0:
            print("h2spec " + String(String(line).strip()))
    if from_report != from_stdout:
        raise Error(
            "the JUnit report (" + from_report.describe()
            + ") disagrees with h2spec's summary (" + from_stdout.describe() + ")"
        )
    assert_equal(
        Int(suite.exit.exit_code), 1 if from_report.failed > 0 else 0,
        "h2spec's exit status agrees with its failures",
    )
    assert_true(
        from_report.passed + from_report.failed > _MIN_RUN_CASES,
        "h2spec ran (did not skip) more than 100 cases",
    )

    # 3. The shrink-only allowlist gate, which also requires exactly the
    # pinned suite's cases.
    var problems = gate(results, Path(String(_ALLOWLIST)).read_text(), _H2SPEC_CASES)
    if len(problems) > 0:
        var msg = String("h2spec conformance gate: ") + String(len(problems)) + " problem(s)"
        for ref p in problems:
            msg += "\n  " + p
        raise Error(msg)

    # 4. The server still serves h2 after the suite.
    if leg.get_error != "":
        raise Error("the h2 GET after the suite failed: " + leg.get_error)
    assert_equal(leg.h2_dials, 1, "the GET after the suite went over h2")
    assert_equal(Int(leg.status), 200, "status of the GET after the suite")
    assert_equal(leg.body, String("Hello from HTTP/2!"), "the h2 serve loop answered")
    print("  test_h2spec_suite_against_http_server PASS")


def main() raises:
    tls_init()
    test_h2spec_suite_against_http_server()
    print("PASS komira_http_conformance h2spec")
