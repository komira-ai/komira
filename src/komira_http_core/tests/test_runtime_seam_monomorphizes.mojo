# =============================================================================
# src/komira_http_core/tests/test_runtime_seam_monomorphizes.mojo
# =============================================================================
#
# The runtime seam monomorphizes — no trampoline.
#
# An objdump tripwire over a self-contained probe proves this property in
# isolation (no indirect calls in the disassembly). THIS test is the in-tree
# form: it materializes the EXACT shape the HTTP client
# uses — `HttpClient[RT: Runtime]` parametric — against the REAL
# `PerCoreAsyncRuntime[NoopSink]` conformer, with `Connector` methods
# recovering `RT.Sink` via the trait method-level parameterization.
#
# What this test verifies SEMANTICALLY (the binary-level no-vtable
# property is the disassembly probe's responsibility):
#
#   1. A struct `HttpClient[RT: Runtime, C: Connector]` parametric over
#      BOTH the runtime AND the connector compiles.
#   2. The trait method `connector.connect[RT](...)` accepts `RT.Sink`-
#      typed reactors without type contortion.
#   3. `comptime if Self.RT.RUNTIME_MODEL == MODEL_SHARE_NOTHING_PER_CORE`
#      branches at COMPILE TIME (dead-branch elimination).
#   4. `Self.RT.TASKS_ARE_THREAD_PINNED` is readable.
#
# Test failure modes that would catch a regression:
#   * If the trait method's `[RT: Runtime]` parameter shape regresses
#     (e.g. Mojo demands a different syntax for trait associated-type
#     access), this file fails to compile.
#   * If the dispatch falls back to vtable, the test still passes
#     (semantic correctness preserved); the OBJDUMP tripwire catches the
#     perf regression.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK, Reactor
from komira_async.runtime.runtime import (
    PLACEMENT_FIXED,
    PerCoreAsyncRuntime,
)
from komira_async.runtime.runtime_trait import (
    MODEL_SHARE_NOTHING_PER_CORE,
    MODEL_WORK_STEALING,
    Runtime,
)
from komira_http_core.transport.io_stream import (
    Connector,
    StreamIo,
    TRANSPORT_KIND_KERNEL_TCP,
)
from komira_http_core.transport.scripted import (
    ScriptedConnector,
    ScriptedStream,
)


# =============================================================================
# HttpClient[RT, C] — the shape this test exists to validate.
# =============================================================================
#
# Doubly-parametric: `[RT: Runtime, C: Connector]`. Mirrors what+
# will land for real. The body exercises:
#   * Self.RT.Sink in the reactor type.
#   * Self.RT.RUNTIME_MODEL in a comptime-if.
#   * Self.RT.TASKS_ARE_THREAD_PINNED read.
#   * Self.C.Stream as the dial return type.

@fieldwise_init
struct HttpClient[RT: Runtime, C: Connector](
    Movable, Deinitable
):
    """The HTTP client shape, doubly parametric."""
    var _connector: Self.C
    var _placeholder: UInt8

    @staticmethod
    def pool_strategy() -> UInt8:
        """ — connection pool selection by runtime model.
        comptime-if dead-branch elimination."""
        comptime if Self.RT.RUNTIME_MODEL == MODEL_SHARE_NOTHING_PER_CORE:
            return UInt8(11)  # PerCorePool
        else:
            return UInt8(22)  # SharedPool

    @staticmethod
    def affinity_pinned() -> Bool:
        """ — connection affinity logic. Reads the comptime
        TASKS_ARE_THREAD_PINNED member."""
        return Self.RT.TASKS_ARE_THREAD_PINNED

    def dial(
        mut self, mut reactor: Reactor[Self.RT.Sink],
        ip_be: UInt32, port: UInt16,
    ) raises -> Self.C.Stream:
        """The full path: connector.connect[RT] through the trait,
        recovering RT.Sink for the Reactor type. The conformer's body
        unwraps Self.RT.Sink and forwards to TcpStream.connect (real)
        or returns the armed mock stream (scripted)."""
        return self._connector.connect[Self.RT](
            reactor=reactor, ip_be=ip_be, port=port,
        )


# =============================================================================
# Tests
# =============================================================================


def test_pool_strategy_per_core_returns_11() raises:
    """Acceptance (a) gate (1): comptime-if branches at compile time
    against PerCoreAsync."""
    var s = HttpClient[
        PerCoreAsyncRuntime[NoopSink], ScriptedConnector,
    ].pool_strategy()
    assert_equal(Int(s), 11)


def test_affinity_pinned_per_core_returns_true() raises:
    """Acceptance (a) gate (1) cont: TASKS_ARE_THREAD_PINNED reads
    correctly for PerCoreAsync (True)."""
    var p = HttpClient[
        PerCoreAsyncRuntime[NoopSink], ScriptedConnector,
    ].affinity_pinned()
    assert_true(p)


def test_dial_path_with_per_core_and_scripted() raises:
    """Acceptance (a) gate (2): HttpClient[PerCoreAsyncRuntime[NoopSink],
    ScriptedConnector].dial(...) runs through:
      * connector.connect[RT] via the trait method
      * Self.RT.Sink recovered as NoopSink (the reactor's Sink type)
      * Returns a Self.C.Stream = ScriptedStream
    The full trait dispatch path executes without indirection or
    type contortion.
    """
    var stream = ScriptedStream.empty()
    var connector = ScriptedConnector.with_stream(stream^)
    var hc = HttpClient[
        PerCoreAsyncRuntime[NoopSink], ScriptedConnector,
    ](
        _connector=connector^,
        _placeholder=UInt8(0),
    )
    var reactor = Reactor[NoopSink](
        NoopSink(_placeholder=UInt8(0)), BACKEND_MOCK,
    )
    var s = hc.dial(reactor=reactor, ip_be=UInt32(0), port=UInt16(80))

    # Verify the dialed stream is usable through the trait surface.
    var buf = Array[UInt8, 4](fill=UInt8(0))
    var dst = Span[UInt8](buf)
    var r = s.try_read[PerCoreAsyncRuntime[NoopSink]](
        reactor=reactor, dst=dst,
    )
    assert_true(r.is_eof())  # Empty script.


def test_connector_transport_kind_through_client_path() raises:
    """The transport-kind static fact reaches through the doubly-
    parametric client: HttpClient[RT, C]._connector.transport_kind()."""
    var connector = ScriptedConnector()
    var hc = HttpClient[
        PerCoreAsyncRuntime[NoopSink], ScriptedConnector,
    ](
        _connector=connector^,
        _placeholder=UInt8(0),
    )
    assert_equal(
        Int(hc._connector.transport_kind()),
        Int(TRANSPORT_KIND_KERNEL_TCP),
    )


def main() raises:
    test_pool_strategy_per_core_returns_11()
    test_affinity_pinned_per_core_returns_true()
    test_dial_path_with_per_core_and_scripted()
    test_connector_transport_kind_through_client_path()
