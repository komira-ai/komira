# =============================================================================
# firestore_watch_buffer.mojo — the CROSS-POLL WATERMARK BUFFER for the LIVE
#   Firestore Listen source.
# =============================================================================
#
# CDC-Firestore ChangeSource (the LIVE half). The offline scripted
# source (`ScriptedListenSource`) returns its canned events ONCE per drain — it
# has no cross-poll state, because the `FirestoreWatchListener.poll` collapses a
# whole drained run to ONE watermark. The LIVE `FirestoreListenClient` is
# different: it drives a long-lived h2 bidi stream and each low-level `poll` may
# return a FRAGMENT of a Listen snapshot — a partial run of DocumentChanges with
# NO terminating watermark TargetChange yet, or a watermark PLUS the leading
# events of the next snapshot. So the live source needs a CROSS-POLL BUFFER that:
#
#   * accumulates ListenEvents across multiple low-level polls;
#   * emits ONLY a COMPLETE watermark boundary (a run terminated by a resumable
#     TargetChange carrying a read_time) — never a half-batch (the watermark is
#     the atomic-commit unit; emitting a partial run would checkpoint an
#     inconsistent snapshot);
#   * on a RESET TargetChange, DISCARDS the un-emitted buffer and re-drives from
#     the last COMMITTED read_time (the durable checkpoint stays valid;
#     idempotent apply dedups any re-delivery) — a RESET must NEVER advance the
#     cursor or emit a partial batch;
#   * carries the tail (events AFTER the last watermark) forward to the next
#     drain so a split-across-polls snapshot is neither lost nor duplicated.
#
# WHY A STANDALONE, TRANSPORT-FREE STRUCT. This buffer/watermark logic is the
# load-bearing correctness the watch-source falsifiers must cover, and it must be
# testable with ZERO network. `WatermarkBuffer` operates on `List[ListenEvent]`
# ONLY — it takes the events a low-level `poll` produced and returns the events
# ready to emit — so the offline falsifier drives a `FirestoreListenClient[
# ScriptedStream]` (or hand-built ListenEvents) INTO this buffer and asserts
# cross-poll continuity / RESET-discard / zero-doc watermark WITHOUT a socket.
# The production `FirestoreListenSource` (firestore_watch_source.mojo) wires the
# real client's `poll` output into the SAME buffer.
#
# ENCAPSULATION. ZERO UnsafePointer in any signature; ZERO wildcard
# origins; ZERO unsafe_from_address. `WatermarkBuffer` holds one owned
# `List[ListenEvent]` (the pending tail) — no pointer field, no byte-slab.
# `def`-based, Mojo 1.0.0b2.
# =============================================================================

from komira_gcp_firestore.firestore_listen_proto import (
    ListenEvent,
    LE_TARGET_CHANGE,
    TCT_RESET,
)


# =============================================================================
# run_is_advancing — is an emitted watermark run GENUINE new state, or a stale
#   resume-confirmation echo?
# =============================================================================


def run_is_advancing(
    emitted: List[ListenEvent], resume_secs: Int64, resume_nanos: Int64
) -> Bool:
    """True iff `emitted` (a complete watermark run) represents GENUINE new state
    rather than a stale resume-confirmation echo.

    THE RESUME-CONFIRMATION ECHO (wire-proven). When the live source
    resumes with `open_after(T)` (T = the committed watermark), Firestore FIRST
    delivers a "consistent-snapshot-at-T" confirmation — a keepalive TargetChange
    (NO_CHANGE) echoing read_time == T carrying ZERO document changes — BEFORE the
    real post-T changes stream in on subsequent low-level polls. The
    `WatermarkBuffer` correctly emits that confirmation as a complete (zero-doc)
    run; but a drain that RETURNS on it strands the actual post-resume changes
    (which arrive on the next polls) and commits nothing. So the drain must SKIP a
    stale confirmation and keep polling.

    A run is ADVANCING iff EITHER:
      * it carries at least one document event (change / delete / remove), OR
      * its boundary read_time is STRICTLY GREATER than the resume position
        (`resume_secs.resume_nanos`) — a genuine new consistent snapshot.

    A cold start (resume_secs == 0 && resume_nanos == 0) is always advancing (the
    initial snapshot's watermark is > 0). The (secs, nanos) pair is compared
    lexicographically to avoid the Int64 overflow `seconds*1e9 + nanos` would
    risk. Defensive: a run with no boundary at all (shouldn't happen — feed only
    emits on a boundary) is treated as advancing so nothing stalls."""
    var has_doc = False
    var boundary_secs = Int64(0)
    var boundary_nanos = Int64(0)
    var have_boundary = False
    for i in range(len(emitted)):
        ref ev = emitted[i]
        if ev.kind != LE_TARGET_CHANGE:
            has_doc = True
        elif ev.has_resume_token and ev.has_read_time:
            have_boundary = True
            boundary_secs = ev.read_time_seconds
            boundary_nanos = ev.read_time_nanos
    if has_doc:
        return True
    if not have_boundary:
        return True
    if boundary_secs != resume_secs:
        return boundary_secs > resume_secs
    return boundary_nanos > resume_nanos


# =============================================================================
# WatermarkBoundary — the outcome of feeding a poll's events into the buffer.
# =============================================================================


struct WatermarkBuffer(Movable, Deinitable):
    """The cross-poll accumulator for the live Firestore Listen source.

    Holds the events received since the last COMPLETED watermark boundary (the
    "pending tail"). `feed(events)` appends a low-level poll's events and returns
    the events ready to emit (a COMPLETE run up to and including the LAST
    watermark TargetChange seen), keeping the tail buffered.

    THE WATERMARK BOUNDARY. A watermark is a TargetChange (typically NO_CHANGE /
    CURRENT) carrying BOTH a resume_token AND a read_time — the consistent-
    snapshot checkpoint. `FirestoreWatchListener.poll` stamps every emitted
    record with that read_time and threads the (read_time, resume_token) cursor.
    So the buffer emits a run ONLY when it is terminated by such a boundary; a
    run with no boundary yet stays pending.

    THE RESET RULE. A TargetChange of type RESET means the
    server is re-sending the snapshot from scratch (a resume-token expiry / a
    server-side reset). The un-emitted pending buffer is now STALE — it must be
    DISCARDED, NOT emitted (emitting it would checkpoint a torn snapshot). The
    RESET itself carries no committable position, so it does NOT advance the
    cursor. The live source re-drives from the last COMMITTED read_time (kept in
    the durable checkpoint); idempotent apply dedups any re-delivered record.
    `feed` drops the pending buffer up to and including the LAST RESET seen and
    returns NOTHING for that feed (unless a LATER watermark follows the RESET in
    the SAME feed, which then emits the post-RESET run).

    Layout: a plain owned-field struct (one `List[ListenEvent]`) in a plain local
    — no pointer field, no byte-slab."""

    var _pending: List[ListenEvent]

    def __init__(out self):
        self._pending = List[ListenEvent]()

    def copy(self) -> Self:
        var out = Self()
        for i in range(len(self._pending)):
            out._pending.append(self._pending[i].copy())
        return out^

    @always_inline
    def pending_len(self) -> Int:
        """The number of events currently buffered (un-emitted). A test asserts
        this is 0 after a RESET-discard and after a clean watermark emit."""
        return len(self._pending)

    def reset_all(mut self):
        """Drop the entire pending buffer (a hard reconnect / teardown). The
        live source calls this before re-opening the stream from the committed
        watermark so no stale pre-disconnect fragment leaks into the new
        session."""
        self._pending = List[ListenEvent]()

    def feed(mut self, var events: List[ListenEvent]) -> List[ListenEvent]:
        """Append a low-level poll's `events` and return the events READY TO
        EMIT (a complete run up to and including the LAST watermark boundary),
        keeping the post-watermark tail buffered.

        Steps (order matters):
          1. Append the incoming events to the pending tail.
          2. Find the index of the LAST RESET TargetChange in the pending tail.
             If any RESET is present, DISCARD everything up to and including it
             (the un-emitted pre-RESET buffer is stale). The events AFTER the
             last RESET remain (they belong to the post-RESET re-send).
          3. In what remains, find the index of the LAST watermark boundary (a
             TargetChange with resume_token AND read_time). If NONE, the run is
             incomplete — keep it all pending, emit NOTHING.
          4. Otherwise, CUT at that boundary: the events up to and including it
             are returned to emit; the events after it become the new pending
             tail (the leading edge of the next snapshot).

        A RESET that is the LAST boundary-like event (no watermark after it in
        the same feed) yields an EMPTY emit + an empty-or-post-RESET pending
        buffer: the un-emitted buffer was discarded, the cursor does NOT advance,
        and no partial batch is emitted — exactly the RESET contract."""
        for i in range(len(events)):
            self._pending.append(events[i].copy())

        # Step 2: RESET discard. Find the LAST RESET in the pending buffer.
        var last_reset = -1
        for i in range(len(self._pending)):
            ref ev = self._pending[i]
            if ev.kind == LE_TARGET_CHANGE and ev.target_change_type == TCT_RESET:
                last_reset = i
        if last_reset >= 0:
            # Discard everything up to and including the last RESET. The
            # un-emitted pre-RESET fragment is stale; only the post-RESET events
            # survive (they belong to the fresh re-send).
            var survivors = List[ListenEvent]()
            for i in range(last_reset + 1, len(self._pending)):
                survivors.append(self._pending[i].copy())
            self._pending = survivors^

        # Step 3: find the LAST watermark boundary in the surviving buffer.
        var last_wm = -1
        for i in range(len(self._pending)):
            ref ev = self._pending[i]
            if (
                ev.kind == LE_TARGET_CHANGE
                and ev.has_resume_token
                and ev.has_read_time
            ):
                last_wm = i
        if last_wm < 0:
            # No complete boundary yet — keep everything pending, emit nothing.
            return List[ListenEvent]()

        # Step 4: cut at the boundary. Emit [0 .. last_wm]; keep (last_wm ..].
        var emit = List[ListenEvent]()
        for i in range(last_wm + 1):
            emit.append(self._pending[i].copy())
        var tail = List[ListenEvent]()
        for i in range(last_wm + 1, len(self._pending)):
            tail.append(self._pending[i].copy())
        self._pending = tail^
        return emit^
