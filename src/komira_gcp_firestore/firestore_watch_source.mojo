# =============================================================================
# firestore_watch_source.mojo — the PRODUCTION FirestoreListenSource (the real
#   push->pull adapter over the live FirestoreListenClient).
# =============================================================================
#
# CDC-Firestore ChangeSource (the LIVE half). This is the production
# `FirestoreListenSource` the `FirestoreWatchListener[Src]` wraps in prod (the
# scripted `ScriptedListenSource` is the test double). It turns the proven-live
# `FirestoreListenClient` server-push bidi stream into the pull-shaped source the
# generic ingest loop drives:
#
#   * open_watch(after)  — dial a fresh TLS h2 stream to Firestore and open the
#                          Listen bidi. COLD START (empty `after`) opens a
#                          documents-target with NO read_time (Firestore sends
#                          the initial snapshot). RESUME (a bare read_time
#                          sequence / composite cursor) opens with
#                          `Target.read_time` = the committed watermark, so
#                          Firestore re-delivers ONLY changes AFTER it (NO
#                          full-snapshot re-read — the watermark invariant).
#   * drain()            — drive the live client's recv until a WATERMARK
#                          boundary (a resumable TargetChange carrying a
#                          read_time) OR a bounded wall, translate the buffered
#                          run into the ListenEvents `FirestoreWatchListener.poll`
#                          maps to ChangeRecords, and return them. Emits ONLY a
#                          COMPLETE watermark boundary (never a half-batch — the
#                          watermark is the atomic-commit unit).
#
# THE CROSS-POLL BUFFER + RESET + RECONNECT. The live client's low-level poll
# returns FRAGMENTS (a partial run, or a watermark plus the next snapshot's lead);
# the source accumulates them in a `WatermarkBuffer` and emits only complete
# boundaries (cross-poll continuity — no loss / no dup). On a RESET TargetChange
# the buffer DISCARDS its un-emitted fragment and re-drives from the last
# COMMITTED read_time (the durable checkpoint stays valid; idempotent apply dedups
# any re-delivery). On ANY end of the stream (END_STREAM with any status, a
# reset, a GOAWAY, a peer close) and on a failed open, the source RECONNECTS:
# re-dial + `open_after(last-committed watermark)`, bounded retries; with the
# budget used, a non-OK last end is raised. The drain loop and that rule live
# in firestore_watch_drain (`drain_listen`, offline-tested over scripted
# sessions by test_firestore_watch_drain); the watermark/RESET/continuity
# logic lives in `WatermarkBuffer` (test_firestore_watch_source). This module
# is the transport wiring: `_LiveListenSessions` dials and opens the client.
#
# ENCAPSULATION. ZERO UnsafePointer in any signature; ZERO wildcard
# origins; ZERO unsafe_from_address. The reactor + the live client are owned by
# move (the client in an `Optional`, opened per-dial); the config is owned
# String/List. The source binds the concrete public-CA TLS h2 stream type; its
# one parameter is the komira_gcp_core `GcpTokenSource` it asks for a bearer on
# EVERY dial, so a reconnect after the token's hour presents a live token. `def`-based, Mojo 1.0.0b2.
# =============================================================================

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import (
    BACKEND_EPOLL,
    BACKEND_KQUEUE,
    Reactor,
)
from komira_async.runtime.runtime import PerCoreAsyncRuntime

from std.sys.info import CompilationTarget

from komira_http_client.client import _ip_be_from_host
from komira_http_client.tls_connector import (
    build_public_ca_tls_connector,
    TlsConnector,
)
from komira_http_core.transport.kernel_tcp import KernelTcpConnector
from komira_http_core.transport.io_stream import NEGOTIATED_HTTP_2

from komira_gcp_core import GcpTokenSource

from komira_gcp_firestore.firestore_client import FixedBearer
from komira_gcp_firestore.firestore_listen_proto import ListenEvent
from komira_gcp_firestore.firestore_listen_client import FirestoreListenClient
from komira_gcp_firestore.firestore_cdc_cursor import decode_firestore_cursor
from komira_gcp_firestore.firestore_watch_drain import (
    ListenClientSlot,
    ListenDrainState,
    ListenSessions,
    drain_listen,
)
from komira_gcp_firestore.firestore_watch_listener import FirestoreListenSource


# The concrete stream type of a public-CA TLS h2 dial.
comptime _LiveStream = TlsConnector[KernelTcpConnector].Stream
comptime _LiveRuntime = PerCoreAsyncRuntime[NoopSink]

# The per-target id the single-collection watch uses (single synthetic segment).
comptime _WATCH_TARGET_ID: Int = 1

# Bounded reconnect retries per drain before surfacing an error (a supervisor
# re-invokes the whole binary; each pass is crash-safe from the committed table).
comptime _MAX_RECONNECTS: Int = 3


def _make_live_reactor() raises -> Reactor[NoopSink]:
    comptime if CompilationTarget.is_linux():
        return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL)
    return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_KQUEUE)


struct _LiveListenSessions[S: GcpTokenSource](ListenSessions, Movable):
    """Listen sessions over a fresh public-CA TLS h2 dial each.

    Fields (all encapsulated; NO UnsafePointer, NO wildcard):
      _reactor        — the reactor driving the h2 recv.
      _slot           — the open Listen client and the last end
                        (`ListenClientSlot`, which holds everything after the
                        dial and is tested offline).
      _host           — firestore.googleapis.com (the SNI + :authority).
      _db_resource    — projects/{p}/databases/{d} (the routing prefix +
                        database field).
      _doc_resources  — the FULL document resource names to watch.
      _tokens         — the token source, asked for the bearer on EVERY dial
                        (open and each reconnect). A `FixedBearer` (the
                        default type; pass `FixedBearer(token)`) reuses one
                        token; a komira_gcp_core `CachingTokenSource`
                        refetches one that is about to expire, so a stream
                        that outlives its token reconnects with a live one.
      _poll_wall_us   — the per-low-level-poll wall budget.

    Only `listen_open`'s dial (token, TLS connect, ALPN) is here; every other
    method forwards to the slot.
    """

    var _reactor: Reactor[NoopSink]
    var _slot: ListenClientSlot[_LiveStream]
    var _host: String
    var _db_resource: String
    var _doc_resources: List[String]
    var _tokens: Self.S
    var _poll_wall_us: Int64

    def __init__(
        out self,
        var host: String,
        var db_resource: String,
        var doc_resources: List[String],
        var tokens: Self.S,
        poll_wall_us: Int64,
    ) raises:
        self._reactor = _make_live_reactor()
        self._slot = ListenClientSlot[_LiveStream]()
        self._host = host^
        self._db_resource = db_resource^
        self._doc_resources = doc_resources^
        self._tokens = tokens^
        self._poll_wall_us = poll_wall_us

    def dial_bearer(mut self) raises -> String:
        """The bearer for the NEXT dial: the token source is asked every time,
        never a token held from construction."""
        return self._tokens.access_token()

    def listen_is_open(self) -> Bool:
        return self._slot.is_open()

    def listen_open(mut self, resume_secs: Int64, resume_nanos: Int64) raises:
        """Dial a fresh public-CA TLS h2 stream and open the Listen bidi on it
        (`ListenClientSlot.adopt_and_open`: cold when resume_secs/nanos are
        0, else after that read_time). The bearer is fetched FIRST, so a token
        failure opens no socket. A token, dial or ALPN failure raises; a
        failure the Listen RPC answered is the slot's last end."""
        var bearer = self.dial_bearer()
        var connector = build_public_ca_tls_connector(
            String(self._host), alpn_h2=True
        )
        var ip_be = _ip_be_from_host(self._host, UInt16(443))
        var stream = connector.connect[_LiveRuntime](
            self._reactor, ip_be, UInt16(443)
        )
        if stream.negotiated_protocol() != NEGOTIATED_HTTP_2:
            raise Error(
                "FirestoreWatchSource: Firestore did NOT negotiate h2 via ALPN"
                " (server-push bidi requires h2)"
            )
        var client = FirestoreListenClient[_LiveStream](
            stream^, String(self._host), bearer^
        )
        var docs = List[String]()
        for i in range(len(self._doc_resources)):
            docs.append(String(self._doc_resources[i]))
        self._slot.adopt_and_open(
            client^, self._reactor, String(self._db_resource), docs^,
            _WATCH_TARGET_ID, resume_secs, resume_nanos,
        )

    def listen_poll(mut self) raises -> List[ListenEvent]:
        return self._slot.poll(self._reactor, self._poll_wall_us)

    def listen_poll_ended(self) -> Bool:
        return self._slot.poll_ended()

    def listen_close_after_end(mut self):
        self._slot.close_after_end()

    def listen_last_end_code(self) -> Int:
        return self._slot.last_end_code()

    def listen_last_end_text(self) -> String:
        return self._slot.last_end_text()


struct FirestoreWatchSource[S: GcpTokenSource = FixedBearer](
    FirestoreListenSource, Movable, Deinitable
):
    """The production `FirestoreListenSource` — the real push->pull adapter over
    a live `FirestoreListenClient`.

    `open_watch` dials + opens the Listen bidi; `drain` runs `drain_listen`
    (firestore_watch_drain), which drives the recv until a watermark boundary,
    handling RESET-discard and reconnects.

    Fields (all encapsulated; NO UnsafePointer, NO wildcard):
      _sessions       — the live sessions (reactor, client, config, token
                        source, last end).
      _state          — the cross-poll watermark buffer and the committed
                        watermark (the reconnect / resume point; 0 == cold).
      _drain_wall_us  — the overall drain wall budget (a drain returns after this
                        even without a watermark — a live-but-idle poll).

    Layout: a plain owned-field struct — the reactor + client own their heap via
    OwnedPointer/List internally; no wildcard-origin field, no byte-slab here."""

    var _sessions: _LiveListenSessions[Self.S]
    var _state: ListenDrainState
    var _drain_wall_us: Int64

    def __init__(
        out self,
        var host: String,
        var db_resource: String,
        var doc_resources: List[String],
        var tokens: Self.S,
        poll_wall_us: Int64 = 5_000_000,
        drain_wall_us: Int64 = 30_000_000,
    ) raises:
        self._sessions = _LiveListenSessions[Self.S](
            host^, db_resource^, doc_resources^, tokens^, poll_wall_us
        )
        self._state = ListenDrainState()
        self._drain_wall_us = drain_wall_us

    # ----- FirestoreListenSource trait --------------------------------------
    def open_watch(mut self, after: String) raises:
        """Dial a fresh TLS h2 stream to Firestore and open the Listen bidi.

        `after` is the composite/bare cursor (an empty String cold-starts). A
        resume decodes the committed read_time and opens with `Target.read_time`
        = that watermark (Firestore re-delivers ONLY changes after it — NO
        full-snapshot re-read). The buffer is reset so no stale pre-open fragment
        leaks into the new session. A failure the Listen RPC answers is not
        raised here: it is the last end, and `drain` reconnects from it."""
        var cur = decode_firestore_cursor(after)
        if cur.has_position:
            self._state.reset(cur.read_time_seconds, cur.read_time_nanos)
        else:
            self._state.reset(Int64(0), Int64(0))
        self._sessions.listen_open(
            self._state.committed_secs, self._state.committed_nanos
        )

    def drain(mut self) raises -> List[ListenEvent]:
        """The ListenEvents of one COMPLETE advancing watermark run (or empty on
        an idle drain); never a half-batch. See `drain_listen` for the loop and
        the end-of-session rule."""
        return drain_listen(
            self._sessions,
            self._state,
            drain_wall_us=self._drain_wall_us,
            max_reconnects=_MAX_RECONNECTS,
        )

    # ----- internals --------------------------------------------------------
    def dial_bearer(mut self) raises -> String:
        """The bearer for the NEXT dial: the token source is asked every time,
        never a token held from construction. Each dial calls this once; it is
        public so a test can observe it without a network."""
        return self._sessions.dial_bearer()

    def tokens(mut self) -> ref [self._sessions._tokens] Self.S:
        """Borrow the token source (a test reads its fetch count)."""
        return self._sessions._tokens
