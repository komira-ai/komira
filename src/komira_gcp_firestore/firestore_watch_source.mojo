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
# any re-delivery). On a stream disconnect (END_STREAM / peer close), the source
# RECONNECTS: re-dial + `open_after(last-committed watermark)`, bounded retries.
# All the watermark/RESET/continuity logic lives in `WatermarkBuffer` (offline-
# tested by test_firestore_watch_source); this module is the transport wiring
# around it.
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

from komira_clock import now_ns as _mono_now_ns
from komira_gcp_core import GcpTokenSource

from komira_gcp_firestore.firestore_client import FixedBearer
from komira_gcp_firestore.firestore_listen_proto import ListenEvent
from komira_gcp_firestore.firestore_listen_client import FirestoreListenClient
from komira_gcp_firestore.firestore_cdc_cursor import decode_firestore_cursor
from komira_gcp_firestore.firestore_watch_buffer import (
    WatermarkBuffer,
    run_is_advancing,
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


struct FirestoreWatchSource[S: GcpTokenSource = FixedBearer](
    FirestoreListenSource, Movable, Deinitable
):
    """The production `FirestoreListenSource` — the real push->pull adapter over
    a live `FirestoreListenClient`.

    Owns the reactor + config + a `WatermarkBuffer` + the live client (in an
    `Optional`, dialed per open). `open_watch` dials + opens the Listen bidi;
    `drain` drives the recv until a watermark boundary, handling RESET-discard +
    reconnect internally.

    Fields (all encapsulated; NO UnsafePointer, NO wildcard):
      _reactor        — the per-source reactor driving the h2 recv.
      _client         — the live Listen client (None until open_watch dials).
      _buffer         — the cross-poll watermark accumulator.
      _host           — firestore.googleapis.com (the SNI + :authority).
      _db_resource    — projects/{p}/databases/{d} (the routing prefix + database
                        field).
      _doc_resources  — the FULL document resource names to watch.
      _tokens         — the token source, asked for the bearer on EVERY dial
                        (open and each reconnect). A `FixedBearer` (the
                        default type; pass `FixedBearer(token)`) reuses one
                        token; a
                        komira_gcp_core `CachingTokenSource` refetches one that
                        is about to expire, so a stream that outlives its token
                        reconnects with a live one.
      _committed_secs — the last-committed watermark read_time (the reconnect /
                        cold-vs-resume resume point). 0 == cold start.
      _committed_nanos — the last-committed watermark read_time nanos.
      _poll_wall_us   — the per-low-level-poll wall budget.
      _drain_wall_us  — the overall drain wall budget (a drain returns after this
                        even without a watermark — a live-but-idle poll).

    Layout: a plain owned-field struct — the reactor + client own their heap via
    OwnedPointer/List internally; no wildcard-origin field, no byte-slab here."""

    var _reactor: Reactor[NoopSink]
    var _client: Optional[FirestoreListenClient[_LiveStream]]
    var _buffer: WatermarkBuffer
    var _host: String
    var _db_resource: String
    var _doc_resources: List[String]
    var _tokens: Self.S
    var _committed_secs: Int64
    var _committed_nanos: Int64
    var _poll_wall_us: Int64
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
        self._reactor = _make_live_reactor()
        self._client = None
        self._buffer = WatermarkBuffer()
        self._host = host^
        self._db_resource = db_resource^
        self._doc_resources = doc_resources^
        self._tokens = tokens^
        self._committed_secs = Int64(0)
        self._committed_nanos = Int64(0)
        self._poll_wall_us = poll_wall_us
        self._drain_wall_us = drain_wall_us

    # ----- FirestoreListenSource trait --------------------------------------
    def open_watch(mut self, after: String) raises:
        """Dial a fresh TLS h2 stream to Firestore and open the Listen bidi.

        `after` is the composite/bare cursor (an empty String cold-starts). A
        resume decodes the committed read_time and opens with `Target.read_time`
        = that watermark (Firestore re-delivers ONLY changes after it — NO
        full-snapshot re-read). The buffer is reset so no stale pre-open fragment
        leaks into the new session."""
        var cur = decode_firestore_cursor(after)
        if cur.has_position:
            self._committed_secs = cur.read_time_seconds
            self._committed_nanos = cur.read_time_nanos
        else:
            self._committed_secs = Int64(0)
            self._committed_nanos = Int64(0)
        self._buffer.reset_all()
        self._dial_and_open(self._committed_secs, self._committed_nanos)

    def drain(mut self) raises -> List[ListenEvent]:
        """Drive the live client's recv until a WATERMARK boundary emits (a
        complete watermark run) OR the overall drain wall budget elapses (a
        live-but-idle drain returns an empty list). Handles RESET-discard (via
        the buffer) + reconnect (re-dial + open_after the committed watermark)
        internally.

        Returns the ListenEvents forming a COMPLETE watermark run (or empty on an
        idle drain). Never a half-batch.

        WHY THE DRAIN MUST LOOP ACROSS MULTIPLE LOW-LEVEL POLLS (root cause of
        a live `appended=0` bug, wire-proven). Firestore
        pushes the initial snapshot as a SEQUENCE of h2 DATA frames — a leading
        `TargetChange ADD`, then each `DocumentChange`, then a terminating
        `TargetChange CURRENT` carrying the read_time + resume_token (the
        watermark). Each low-level `poll` (`drive_h2_recv_until_progress`)
        returns as soon as ANY new body bytes land, so the FIRST poll typically
        yields only `[ADD, DocumentChange]` — a FRAGMENT with NO watermark. The
        `WatermarkBuffer` correctly buffers it and emits nothing; the drain MUST
        then keep polling (within `_drain_wall_us`) to receive the rest of the
        snapshot + the CURRENT watermark before it can emit a complete run.
        Returning after the first non-emitting poll (the pre-fix behavior)
        stranded the buffered fragment and committed NOTHING. The drain wall is
        the terminator: a genuinely idle live watch (no snapshot within the
        budget) returns empty, and the pass-based loop simply re-polls next
        pass."""
        var reconnects = 0
        var iters = 0
        # A generous per-drain iteration cap (each iteration is one low-level
        # poll bounded by _poll_wall_us). The overall drain wall budget is the
        # real terminator; this cap is a wedge safety net.
        var max_iters = 1_000_000
        var wall_start_ns = Int64(_mono_now_ns())
        var wall_budget_ns = self._drain_wall_us * Int64(1000)
        # The RESUME position this drain opened at (set by open_watch). A resume
        # `open_after(T)` first delivers a "consistent-snapshot-at-T" confirmation
        # — a keepalive watermark that echoes read_time == T carrying ZERO
        # document changes — BEFORE the actual post-T changes stream in. That
        # stale-confirmation run must NOT terminate the drain (it produces no
        # commit; returning on it strands the real changes on the next polls).
        var resume_secs = self._committed_secs
        var resume_nanos = self._committed_nanos
        while iters < max_iters:
            iters += 1
            if not self._client.__bool__():
                # No open stream — reconnect from the committed watermark.
                if reconnects >= _MAX_RECONNECTS:
                    raise Error(
                        "FirestoreWatchSource.drain: exceeded reconnect budget"
                        " with no open stream"
                    )
                reconnects += 1
                self._buffer.reset_all()
                self._dial_and_open(self._committed_secs, self._committed_nanos)

            var events = self._poll_client()
            var ended = self._client_ended()
            var emitted = self._buffer.feed(events^)
            if len(emitted) > 0:
                # A complete watermark run. But on a RESUME, Firestore first
                # delivers a stale "snapshot-at-resume-point" confirmation — a
                # watermark echoing read_time == the resume position with ZERO
                # document changes — before the real post-resume changes stream
                # in. Returning on that stale confirmation strands the actual
                # changes (they arrive on the NEXT low-level polls) and commits
                # nothing. Only RETURN on an ADVANCING run: one that carries at
                # least one document change, OR whose boundary read_time is
                # strictly greater than the resume position. A stale confirmation
                # (no docs, boundary read_time <= resume position) is dropped and
                # the drain keeps polling for the genuine changes.
                if run_is_advancing(emitted, resume_secs, resume_nanos):
                    self._advance_committed(emitted)
                    return emitted^
                # Stale resume-confirmation: keep polling (fall through to the
                # wall-budget check below).
            if ended:
                # The stream dropped without a complete run this drain. Force a
                # reconnect on the next loop iteration (bounded).
                self._client = None
                if reconnects >= _MAX_RECONNECTS:
                    # No more reconnects — return empty (a live-but-idle drain);
                    # the generic loop re-derives + re-opens next pass.
                    return List[ListenEvent]()
                continue
            # No emit + not ended: a partial fragment (the snapshot is still
            # streaming) OR a genuinely idle poll. KEEP POLLING until a complete
            # watermark boundary emits or the DRAIN WALL budget elapses — the
            # rest of the snapshot (more DocumentChanges + the CURRENT watermark)
            # arrives on subsequent low-level polls. Only when the wall is spent
            # with no complete run do we return empty (a live-but-idle drain);
            # the pass-based loop re-polls from the same point next pass.
            if wall_budget_ns > Int64(0):
                var elapsed = Int64(_mono_now_ns()) - wall_start_ns
                if elapsed > wall_budget_ns:
                    return List[ListenEvent]()
            continue
        return List[ListenEvent]()

    # ----- internals --------------------------------------------------------
    def dial_bearer(mut self) raises -> String:
        """The bearer for the NEXT dial: the token source is asked every time,
        never a token held from construction. `_dial_and_open` calls this once
        per dial; it is public so a test can observe it without a network."""
        return self._tokens.access_token()

    def tokens(mut self) -> ref [self._tokens] Self.S:
        """Borrow the token source (a test reads its fetch count)."""
        return self._tokens

    def _dial_and_open(mut self, resume_secs: Int64, resume_nanos: Int64) raises:
        """Dial a fresh public-CA TLS h2 stream + open the Listen bidi (cold when
        resume_secs/nanos are 0, else resume after that read_time). The bearer
        is fetched FIRST, so a token failure opens no socket."""
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
        if resume_secs == Int64(0) and resume_nanos == Int64(0):
            client.open[_LiveRuntime](
                self._reactor, String(self._db_resource), docs^, _WATCH_TARGET_ID
            )
        else:
            client.open_after[_LiveRuntime](
                self._reactor, String(self._db_resource), docs^,
                _WATCH_TARGET_ID, resume_secs, resume_nanos,
            )
        var status = Int(client.status())
        if status != 200:
            raise Error(
                "FirestoreWatchSource: Listen returned :status "
                + String(status)
                + " (expected 200 — check token scope / project / database)"
            )
        self._client = Optional(client^)

    def _poll_client(mut self) raises -> List[ListenEvent]:
        """Drive one low-level poll of the open client (records the disconnect
        flag on the client for `_client_ended`)."""
        ref client = self._client.value()
        return client.poll_progress[_LiveRuntime](
            self._reactor, max_wall_us=self._poll_wall_us
        )

    def _client_ended(self) -> Bool:
        """True iff the most recent poll observed the server closing the stream.
        """
        if not self._client.__bool__():
            return True
        return self._client.value().last_poll_ended()

    def _advance_committed(mut self, emitted: List[ListenEvent]):
        """Advance the committed watermark to the LAST watermark boundary in
        `emitted` (the reconnect / next-resume position)."""
        for i in range(len(emitted)):
            ref ev = emitted[i]
            if ev.has_resume_token and ev.has_read_time:
                self._committed_secs = ev.read_time_seconds
                self._committed_nanos = ev.read_time_nanos
