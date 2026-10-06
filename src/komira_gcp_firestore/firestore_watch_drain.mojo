# =============================================================================
# firestore_watch_drain.mojo — the Listen drain loop, over any source of
#   Listen sessions, and the decision it makes when a session ends.
# =============================================================================
#
# `FirestoreWatchSource.drain` (firestore_watch_source.mojo) runs
# `drain_listen` over sessions that dial Firestore over TLS. The loop lives
# here, generic over `ListenSessions`, so a test runs the SAME loop over
# scripted sessions with no socket (tests/test_firestore_watch_drain.mojo).
#
# THE END-OF-SESSION RULE. Firestore's own SDKs restart the watch stream on
# every close while targets are listened (firebase-js-sdk remote_store.ts
# `onWatchStreamClose`), with backoff; a failure of one target arrives as a
# TargetChange REMOVE carrying a cause, not as the stream's status. So:
#   * a failed open and a stream end are one thing: reconnect from the
#     committed watermark, up to the reconnect budget;
#   * with the budget used, a non-OK LAST end (a failed open included) is
#     raised as its `[grpc:N] ...` text, so the watch does not go idle with
#     the server's reason thrown away;
#   * with the budget used and a clean OK last end, the drain returns an
#     empty list (a live-but-idle drain; the pass-based loop re-opens next
#     pass), as it did before the status was read.
# This loop does not back off between reconnects.
# =============================================================================

from komira_clock import now_ns as _mono_now_ns

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import Reactor
from komira_async.runtime.runtime import PerCoreAsyncRuntime
from komira_http_core.transport.io_stream import IoStream

from komira_grpc import GRPC_STATUS_UNKNOWN

from komira_gcp_firestore.firestore_listen_client import FirestoreListenClient
from komira_gcp_firestore.firestore_listen_proto import ListenEvent
from komira_gcp_firestore.firestore_watch_buffer import (
    WatermarkBuffer,
    run_is_advancing,
)

comptime LISTEN_DRAIN_RECONNECT: Int = 0
"""`listen_drain_step`: open a new session."""
comptime LISTEN_DRAIN_RAISE: Int = 1
"""`listen_drain_step`: raise the last end's status."""
comptime LISTEN_DRAIN_RETURN_EMPTY: Int = 2
"""`listen_drain_step`: return an empty list (idle drain)."""

comptime _DRAIN_MAX_ITERATIONS: Int = 1_000_000


def listen_drain_step(
    reconnects_used: Int, max_reconnects: Int, last_end_code: Int
) -> Int:
    """What the drain does with no open session.

    `last_end_code` is the gRPC status of the last session end or failed open
    (-1 if there was none). Below the budget: reconnect. At it: raise a
    non-OK last end, else return empty."""
    if reconnects_used < max_reconnects:
        return LISTEN_DRAIN_RECONNECT
    if last_end_code > 0:
        return LISTEN_DRAIN_RAISE
    return LISTEN_DRAIN_RETURN_EMPTY


def listen_end_code_after_failed_open(client_terminal_code: Int) -> Int:
    """The end code a failed `FirestoreListenClient.open` leaves: the status
    the client recorded before it raised, or UNKNOWN if it raised without one
    (a stall before the response head)."""
    if client_terminal_code < 0:
        return Int(GRPC_STATUS_UNKNOWN)
    return client_terminal_code


trait ListenSessions:
    """Where `drain_listen` gets Listen sessions from: one at a time."""

    def listen_is_open(self) -> Bool:
        """A session is open (opened, and not closed after an end)."""
        ...

    def listen_open(mut self, resume_secs: Int64, resume_nanos: Int64) raises:
        """Open a session after the watermark (0, 0 cold-starts). A failure
        the Listen RPC answered leaves no session open and records the end
        (`listen_last_end_code` / `_text`); it does not raise. Raising is for
        a failure to reach the RPC at all (a dial, a token)."""
        ...

    def listen_poll(mut self) raises -> List[ListenEvent]:
        """One low-level poll of the open session."""
        ...

    def listen_poll_ended(self) -> Bool:
        """The last poll saw the session end."""
        ...

    def listen_close_after_end(mut self):
        """Record the ended session's status as the last end; close it."""
        ...

    def listen_last_end_code(self) -> Int:
        """The gRPC status of the last end or failed open; -1 if none."""
        ...

    def listen_last_end_text(self) -> String:
        """`[grpc:N] ...` for the last end or failed open."""
        ...


struct ListenDrainState(Movable):
    """The drain's own state across drains: the cross-poll watermark buffer
    and the committed watermark (the reconnect / resume position)."""

    var buffer: WatermarkBuffer
    var committed_secs: Int64
    var committed_nanos: Int64

    def __init__(out self):
        self.buffer = WatermarkBuffer()
        self.committed_secs = Int64(0)
        self.committed_nanos = Int64(0)

    def reset(mut self, secs: Int64, nanos: Int64):
        """A new watch from this watermark: drop any buffered fragment."""
        self.buffer.reset_all()
        self.committed_secs = secs
        self.committed_nanos = nanos

    def advance_committed(mut self, emitted: List[ListenEvent]):
        """Advance the committed watermark to the LAST watermark boundary in
        `emitted` (the reconnect / next-resume position)."""
        for i in range(len(emitted)):
            ref ev = emitted[i]
            if ev.has_resume_token and ev.has_read_time:
                self.committed_secs = ev.read_time_seconds
                self.committed_nanos = ev.read_time_nanos


def drain_listen[
    T: ListenSessions
](
    mut sessions: T,
    mut state: ListenDrainState,
    drain_wall_us: Int64,
    max_reconnects: Int,
) raises -> List[ListenEvent]:
    """Poll sessions until a COMPLETE advancing watermark run emits (returned,
    and committed), or the drain wall elapses (empty), reconnecting on every
    end by `listen_drain_step`. `drain_wall_us` <= 0 disables the wall; an
    iteration cap still ends the drain.

    WHY THE DRAIN LOOPS ACROSS LOW-LEVEL POLLS. Firestore pushes a snapshot
    as a sequence of DATA frames (a TargetChange ADD, each DocumentChange,
    then a CURRENT carrying the read_time + resume_token). A poll returns as
    soon as any bytes land, so one poll is usually a fragment; the
    `WatermarkBuffer` holds it and the drain keeps polling until the run is
    complete.

    THE RESUME CONFIRMATION. A resume after T first delivers a watermark
    echoing read_time == T with no documents. Returning on it would strand
    the real changes, so only an ADVANCING run (`run_is_advancing`) returns.
    """
    var reconnects = 0
    var iters = 0
    var wall_start_ns = Int64(_mono_now_ns())
    var wall_budget_ns = drain_wall_us * Int64(1000)
    var resume_secs = state.committed_secs
    var resume_nanos = state.committed_nanos
    while iters < _DRAIN_MAX_ITERATIONS:
        iters += 1
        if not sessions.listen_is_open():
            var step = listen_drain_step(
                reconnects, max_reconnects, sessions.listen_last_end_code()
            )
            if step == LISTEN_DRAIN_RAISE:
                raise Error(
                    "FirestoreWatchSource.drain: the Listen stream did not stay"
                    " open after "
                    + String(reconnects)
                    + " reconnects; the last end: "
                    + sessions.listen_last_end_text()
                )
            if step == LISTEN_DRAIN_RETURN_EMPTY:
                return List[ListenEvent]()
            reconnects += 1
            state.buffer.reset_all()
            sessions.listen_open(state.committed_secs, state.committed_nanos)
            continue

        var events = sessions.listen_poll()
        var ended = sessions.listen_poll_ended()
        var emitted = state.buffer.feed(events^)
        if len(emitted) > 0:
            if run_is_advancing(emitted, resume_secs, resume_nanos):
                state.advance_committed(emitted)
                return emitted^
            # A stale resume confirmation: keep polling.
        if ended:
            sessions.listen_close_after_end()
            continue
        if wall_budget_ns > Int64(0):
            var elapsed = Int64(_mono_now_ns()) - wall_start_ns
            if elapsed > wall_budget_ns:
                return List[ListenEvent]()
    return List[ListenEvent]()


comptime _SlotRuntime = PerCoreAsyncRuntime[NoopSink]


struct ListenClientSlot[St: IoStream](Movable):
    """The session half of a `ListenSessions` that holds no dial: the open
    `FirestoreListenClient` (if any) and the last end. The live source dials
    a TLS stream and hands the client here (`adopt_and_open`); a test hands
    in a client over a `ScriptedStream`, so everything after the dial runs
    offline.

    Fields: `_client` (None between sessions), `_last_end_code` (-1: none
    yet), `_last_end_text` (`[grpc:N] ...`)."""

    var _client: Optional[FirestoreListenClient[Self.St]]
    var _last_end_code: Int
    var _last_end_text: String

    def __init__(out self):
        self._client = None
        self._last_end_code = -1
        self._last_end_text = String("")

    def adopt_and_open(
        mut self,
        var client: FirestoreListenClient[Self.St],
        mut reactor: Reactor[NoopSink],
        database: String,
        var document_names: List[String],
        target_id: Int,
        resume_secs: Int64,
        resume_nanos: Int64,
    ):
        """Open `client` (cold when the watermark is 0, else after it) and keep
        it. If `open` raises, the session failed: record that as the last end
        (`listen_end_code_after_failed_open`) and keep no client."""
        try:
            if resume_secs == Int64(0) and resume_nanos == Int64(0):
                client.open[_SlotRuntime](
                    reactor, database, document_names^, target_id
                )
            else:
                client.open_after[_SlotRuntime](
                    reactor, database, document_names^, target_id,
                    resume_secs, resume_nanos,
                )
        except e:
            self._last_end_code = listen_end_code_after_failed_open(
                client.terminal_code()
            )
            self._last_end_text = String(e)
            return
        self._client = Optional(client^)

    def is_open(self) -> Bool:
        return self._client.__bool__()

    def poll(
        mut self, mut reactor: Reactor[NoopSink], max_wall_us: Int64
    ) raises -> List[ListenEvent]:
        """One low-level poll of the open client (the caller checks
        `is_open` first)."""
        ref client = self._client.value()
        return client.poll_progress[_SlotRuntime](
            reactor, max_wall_us=max_wall_us
        )

    def poll_ended(self) -> Bool:
        """The last poll saw the end (no client counts as ended)."""
        if not self._client.__bool__():
            return True
        return self._client.value().last_poll_ended()

    def close_after_end(mut self):
        """Keep the ended client's terminal status as the last end; drop it."""
        if self._client.__bool__():
            self._last_end_code = self._client.value().terminal_code()
            self._last_end_text = self._client.value().terminal_error_text()
        self._client = None

    def last_end_code(self) -> Int:
        return self._last_end_code

    def last_end_text(self) -> String:
        return self._last_end_text
