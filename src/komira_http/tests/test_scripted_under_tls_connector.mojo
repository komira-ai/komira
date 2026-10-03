"""`TlsConnector[ScriptedConnector]` — the composition the scripted module's own
docstring names as THE TLS test composition ("tests that exercise TLS use
`TlsConnector[ScriptedConnector]` composition").
`tests/test_L2_tls_connector_construction.mojo` builds only
`TlsConnector[KernelTcpConnector]`.

⭐ THE CLAIM UNDER TEST, and it is a claim THREE production files make — one
of them the TRAIT DEFINITION, which makes it an interface obligation and not a
comment:

  * `io_stream.mojo` (`IoStream.fd`, THE TRAIT): "Conformers that have no
    kernel fd (e.g., ScriptedStream) return -1; CONSUMERS THAT DEPEND ON A REAL
    FD (TlsConnector) GRACEFULLY ERROR ON -1."
  * `scripted.mojo` (`ScriptedStream.fd`): "Consumers that DEPEND on a real fd
    (e.g., TlsConnector binding s2n to the fd) GRACEFULLY DETECT -1 AND ERROR."
  * `tls_connector.mojo` (`TlsConnector._extract_fd`): "the TLS layer
    gracefully handles -1 (s2n's `bind_fd` on -1 RAISES AN ERROR, which
    surfaces as a `TlsConnector.connect` raise)."

⚠ THE THIRD SENTENCE IS NOT TRUE OF s2n. `TlsConnection.bind_fd` forwards
straight to `s2n_connection_set_fd`, which STORES whatever integer it is
handed — `bind_fd(-1)` SUCCEEDS. Without a check the dial still raises, but
later and from a different place, inside `s2n_negotiate`, as

    s2n_errno=67108864, msg='underlying I/O operation failed, check system
    errno', last_handshake_msg='CLIENT_HELLO'

i.e. the `write(2)` on fd -1 returning EBADF — a message that names neither
the condition nor the connector and reads as a network fault on a path that
touched no network. So `_extract_fd` REFUSES `fd < 0` by name, BEFORE
`TlsConnection.new_client`, so a dial with no descriptor never allocates an s2n
connection it is going to throw away.

The assertions below therefore cover BOTH halves. PROMPTNESS is still the
load-bearing one — a dial that spends the 30 s
`_HANDSHAKE_DEADLINE_DEFAULT_US` budget before raising is a request that does
not fail fast,
occupies its slot, and 504s at the platform ceiling — but the MECHANISM is
asserted too, because "it happened to raise from somewhere" is a property that
can silently stop holding.

"""

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK, Reactor
from komira_async.runtime.runtime import PerCoreAsyncRuntime
from komira_clock import now_ns

from komira_http.client.tls_connector import TlsConnector
from komira_http.tls import TlsConfig, tls_init
from komira_http.transport.io_stream import TRANSPORT_KIND_KERNEL_TCP
from komira_http.transport.scripted import ScriptedConnector, ScriptedStream

from std.testing import assert_equal, assert_true


# The dial must fail in well under the 30 s `_HANDSHAKE_DEADLINE_DEFAULT_US`.
# 5 s is generous by two orders of magnitude for a path that does zero network
# I/O, and small enough that burning the handshake budget cannot pass.
comptime _PROMPT_FAILURE_BUDGET_US: Int = 5_000_000


def _mock_reactor() raises -> Reactor[NoopSink]:
    return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_MOCK)


def _scripted_under_tls() raises -> TlsConnector[ScriptedConnector]:
    """Build the composition. `tls_init()` is process-wide and idempotent."""
    tls_init()
    var under = ScriptedConnector.with_stream(ScriptedStream.empty())
    return TlsConnector[ScriptedConnector].over(TlsConfig(), under^)


def test_tls_connector_composes_over_the_scripted_connector() raises:
    """The composition CONSTRUCTS. Trivial, and it is the half that had no
    referent: a docstring naming a type composition nothing instantiates is a
    claim about code that has never been compiled."""
    print("  test_tls_connector_composes_over_the_scripted_connector...")
    var connector = _scripted_under_tls()
    assert_true(connector.is_tls(), "a TLS decorator reports TLS")
    assert_equal(
        Int(connector.transport_kind()),
        Int(TRANSPORT_KIND_KERNEL_TCP),
        "transport_kind DELEGATES to the underlying scripted connector — the"
        " codec layer above must not be able to tell the mock from a socket",
    )
    print("    OK")


def test_the_dial_host_push_fills_an_unpinned_sni_on_the_composition(
) raises:
    """`TlsConnector.set_dial_host` fills in the SNI of an UNPINNED connector,
    asserted here on the composition over the real mock.

    ⚠ SCOPE, STATED BECAUSE THE OBVIOUS STRONGER CLAIM IS NOT MADE: this does
    NOT assert that the push was FORWARDED to the underlying
    `ScriptedConnector`. `TlsConnector` exposes no accessor for its underlying
    connector, so `ScriptedConnector.dial_host_at` — which exists exactly to
    make that assertable — is unreachable from here. Asserting the forward
    needs a `underlying()` borrow on `TlsConnector` that does not exist; that
    is a real residual, not a thing this test quietly covers."""
    print("  test_the_dial_host_push_fills_an_unpinned_sni_on_the_composition...")
    var connector = _scripted_under_tls()
    connector.set_dial_host(String("bucket-a.example.com"))
    assert_equal(
        connector.server_name(), String("bucket-a.example.com"),
        "an UNPINNED TlsConnector takes its SNI from the push",
    )
    assert_true(
        not connector.sni_is_pinned(),
        "and the push must not PIN it — a pinned connector is immune to the"
        " next request's host",
    )
    print("    OK")


def test_a_scripted_dial_under_tls_fails_and_fails_PROMPTLY() raises:
    """⭐ THE ONE THAT MATTERS. `ScriptedStream.fd()` is -1. `connect` must not
    return a stream whose s2n connection is bound to a descriptor that is not
    one — and, far more importantly, it must not spend the 30 s handshake
    budget discovering that.

    ⚠ IF THIS TEST EVER STARTS TAKING SECONDS, the finding is not "the test is
    slow": it is that a dial with no usable descriptor is being PARKED ON
    rather than rejected."""
    print("  test_a_scripted_dial_under_tls_fails_and_fails_PROMPTLY...")
    var connector = _scripted_under_tls()
    var reactor = _mock_reactor()
    connector.set_server_name_for_next_connect(String("example.test"))

    var t0 = Int(now_ns() // UInt64(1000))
    var raised = False
    var detail = String()
    try:
        var _s = connector.connect[PerCoreAsyncRuntime[NoopSink]](
            reactor=reactor, ip_be=UInt32(0), port=UInt16(443),
        )
    except e:
        raised = True
        detail = String(e)
    var elapsed_us = Int(now_ns() // UInt64(1000)) - t0

    assert_true(
        raised,
        "a TLS dial over a stream with NO kernel fd must RAISE; returning a"
        " TlsClientStream here hands s2n a -1 descriptor and defers the"
        " failure to the first read",
    )
    assert_true(
        elapsed_us < _PROMPT_FAILURE_BUDGET_US,
        "the dial took "
        + String(elapsed_us)
        + " us to fail. A handshake with no usable descriptor must fail FAST,"
        " not burn the 30 s _HANDSHAKE_DEADLINE_DEFAULT_US — a request that"
        " does not fail fast occupies its slot and 504s at the platform"
        " ceiling, which is a production service's shape",
    )
    print("    OK — failed in", elapsed_us, "us:", detail)


def test_the_fdless_refusal_NAMES_THE_CONDITION_not_a_stray_s2n_errno(
) raises:
    """⭐ THE MECHANISM, not just the outcome. The `IoStream.fd` TRAIT docstring
    obliges "consumers that depend on a real fd (TlsConnector) gracefully error
    on -1". This asserts that obligation is actually IMPLEMENTED, by checking
    the raise names the CONDITION.

    WHY THE MESSAGE IS THE ASSERTION AND NOT AN INCIDENTAL. Before the fix the
    dial failed with

        s2n_errno=67108864, msg='underlying I/O operation failed, check system
        errno', debug='.../s2n_io.c:28', last_handshake_msg='CLIENT_HELLO'

    which names neither the fd nor the connector, and reads as a socket/network
    fault on a path that performed no network I/O. This file's own sibling
    `_handshake_deadline_error` exists because a message that said "handshake
    exceeded 256 iterations" cost an evening for exactly that reason. A
    diagnostic that points at the wrong subsystem is the defect; "it raised"
    is not the bar."""
    print("  test_the_fdless_refusal_NAMES_THE_CONDITION_not_a_stray_s2n_errno...")
    var connector = _scripted_under_tls()
    var reactor = _mock_reactor()
    connector.set_server_name_for_next_connect(String("example.test"))

    var detail = String()
    var raised = False
    try:
        var _s = connector.connect[PerCoreAsyncRuntime[NoopSink]](
            reactor=reactor, ip_be=UInt32(0), port=UInt16(443),
        )
    except e:
        raised = True
        detail = String(e)

    assert_true(raised, "a TLS dial over an fd-less stream must RAISE")
    assert_true(
        String("fd=-1") in detail,
        "the refusal must carry the OFFENDING VALUE. Got: " + detail,
    )
    assert_true(
        String("no kernel descriptor") in detail,
        "the refusal must name the CONDITION, so a reader is not sent to look"
        " at the network. Got: " + detail,
    )
    assert_true(
        String("s2n_errno") not in detail,
        "and it must be REFUSED BEFORE s2n is involved at all — an s2n errno"
        " in this message means the -1 reached the handshake and the guard did"
        " not fire. Got: " + detail,
    )
    print("    OK —", detail)


def test_an_armed_connect_fault_propagates_through_the_tls_decorator(
) raises:
    """The new connect-fault vocabulary must COMPOSE with the decorator: a
    refusal armed on the UNDERLYING scripted connector has to surface through
    `TlsConnector.connect`, which is the only way a TLS-dialling client's
    connect-failure handling is testable with zero sockets.

    This also pins the ORDER: the underlying dial is attempted BEFORE any s2n
    object is built, so a refused TCP dial never allocates a TLS connection."""
    print("  test_an_armed_connect_fault_propagates_through_the_tls_decorator...")
    tls_init()
    var under = ScriptedConnector.with_stream(ScriptedStream.empty())
    under.arm_connect_error(Int64(111))  # ECONNREFUSED
    var connector = TlsConnector[ScriptedConnector].over(TlsConfig(), under^)
    var reactor = _mock_reactor()
    connector.set_server_name_for_next_connect(String("example.test"))

    var detail = String()
    var raised = False
    try:
        var _s = connector.connect[PerCoreAsyncRuntime[NoopSink]](
            reactor=reactor, ip_be=UInt32(0), port=UInt16(443),
        )
    except e:
        raised = True
        detail = String(e)
    assert_true(raised)
    assert_true(
        String("CONNECT_FAILED") in detail,
        "the UNDERLYING dial's refusal must reach the caller unmangled; got: "
        + detail,
    )
    assert_true(
        String("111") in detail, "carrying the errno it was armed with",
    )
    print("    OK —", detail)


def main() raises:
    test_tls_connector_composes_over_the_scripted_connector()
    test_the_dial_host_push_fills_an_unpinned_sni_on_the_composition()
    test_a_scripted_dial_under_tls_fails_and_fails_PROMPTLY()
    test_the_fdless_refusal_NAMES_THE_CONDITION_not_a_stray_s2n_errno()
    test_an_armed_connect_fault_propagates_through_the_tls_decorator()
    print("PASS test_scripted_under_tls_connector")
