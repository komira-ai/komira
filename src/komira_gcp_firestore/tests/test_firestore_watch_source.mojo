# =============================================================================
# test_firestore_watch_source.mojo — OFFLINE FALSIFIERS for the LIVE
#   Firestore Listen source's cross-poll WATERMARK BUFFER + drive-through-the-
#   real-client-over-ScriptedStream. ZERO network, ZERO sockets.
# =============================================================================
#
# CDC-Firestore ChangeSource (the LIVE half). The production
# FirestoreListenSource wraps the real FirestoreListenClient + a reactor + a
# cross-poll WatermarkBuffer. The buffer is the load-bearing correctness the
# live source adds over the scripted source: it accumulates the real client's
# per-poll fragments and emits ONLY a COMPLETE watermark boundary. That logic is
# transport-free (WatermarkBuffer operates on List[ListenEvent] only), so it is
# fully falsifiable OFFLINE.
#
# THE FALSIFIERS (the contract):
#   (1) CROSS-POLL BUFFER CONTINUITY. Events split across TWO poll windows are
#       neither lost nor duplicated: a first poll with a partial run (NO
#       terminating watermark) emits NOTHING and buffers; a second poll that
#       supplies the terminating watermark emits the WHOLE run exactly once. A
#       poll that carries a watermark PLUS leading events of the NEXT snapshot
#       emits up to the watermark and carries the leading edge forward.
#   (2) RESET DISCARDS THE UN-EMITTED BUFFER. A partial run buffered, then a
#       RESET TargetChange -> the buffer is DISCARDED, NO partial batch emitted,
#       the cursor does NOT advance; a subsequent clean re-drive (post-RESET run
#       + watermark) emits the fresh run only.
#   (3) RECONNECT re-opens with the committed read_time and resumes without
#       loss/dup: drive the REAL FirestoreListenClient over a ScriptedStream
#       whose script ENDS mid-watch (EOF) -> poll_progress surfaces ended_seen;
#       a fresh client opened `open_after(committed_read_time)` continues, and
#       the buffer across the reconnect emits each watermark run exactly once.
#   (4) A WATERMARK BOUNDARY WITH ZERO DOCUMENTS (a NO_CHANGE keepalive) emits a
#       batch that advances read_time but carries NO document record.
#
# WHY DRIVE THE REAL CLIENT (falsifier 3). The buffer falsifiers (1/2/4) feed
# hand-built ListenEvents; falsifier 3 additionally drives the REAL
# FirestoreListenClient[ScriptedStream] (the same client the live source uses)
# so the reconnect path — open_after(read_time) + poll_progress's ended_seen —
# is exercised end-to-end against synthetic server frames, with ZERO sockets.
#
# FAILS ON CURRENT CODE (pre-fix): WatermarkBuffer / open_after /
# poll_progress / encode_listen_request_documents_after did not exist -> this
# file does not COMPILE. The RESET-discard + cross-poll-continuity assertions are
# the load-bearing falsifiers (disable WatermarkBuffer.feed's RESET branch or its
# watermark-cut and they FAIL).
# =============================================================================

from std.memory import ArcPointer
from std.sys.info import CompilationTarget
from std.testing import assert_equal, assert_true, assert_false

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import (
    BACKEND_EPOLL,
    BACKEND_KQUEUE,
    Reactor,
)
from komira_async.runtime.runtime import PerCoreAsyncRuntime

from komira_http_core.codec.h2.frame import (
    SettingsEntry,
    encode_data_frame,
    encode_headers_frame,
    encode_settings_frame,
)
from komira_http_core.codec.h2.hpack import HpackEncoder, HpackHeader
from komira_http_core.transport.io_stream import NEGOTIATED_HTTP_2
from komira_http_core.transport.scripted import ScriptedStream

from komira_protobuf.writer import (
    pb_write_string_field,
    pb_write_message_field,
    pb_write_varint_field,
    pb_write_bytes_field,
)

from komira_gcp_firestore.firestore_listen_proto import (
    ListenEvent,
    FsDocument,
    LE_TARGET_CHANGE,
    LE_DOCUMENT_CHANGE,
    TCT_NO_CHANGE,
    TCT_RESET,
)

# google.firestore.v1 / google.protobuf field numbers, for building the
# server's side of the wire independently of the generated messages.
comptime DC_DOCUMENT = 1  # DocumentChange.document
comptime DOC_NAME = 1  # Document.name
comptime DOC_FIELDS = 2  # Document.fields (map entries)
comptime FMAP_ENTRY_KEY = 1  # map entry key
comptime FMAP_ENTRY_VALUE = 2  # map entry value
comptime FV_STRING_VALUE = 17  # Value.string_value
comptime LRESP_DOCUMENT_CHANGE = 3  # ListenResponse.document_change
comptime LRESP_TARGET_CHANGE = 2  # ListenResponse.target_change
comptime TC_TARGET_CHANGE_TYPE = 1  # TargetChange.target_change_type
comptime TC_RESUME_TOKEN = 4  # TargetChange.resume_token
comptime TC_READ_TIME = 6  # TargetChange.read_time
comptime FTS_SECONDS = 1  # Timestamp.seconds
comptime FTS_NANOS = 2  # Timestamp.nanos
from komira_gcp_firestore.firestore_value import FsValue
from komira_gcp_firestore.firestore_watch_buffer import (
    WatermarkBuffer,
    run_is_advancing,
)
from komira_gcp_firestore.firestore_listen_client import (
    FirestoreListenClient,
    encode_grpc_envelope,
)


# -----------------------------------------------------------------------------
# Hand-built ListenEvent fixtures (buffer falsifiers 1/2/4).
# -----------------------------------------------------------------------------


def _doc_change(doc_id: String) -> ListenEvent:
    var keys = List[String]()
    var vals = List[FsValue]()
    keys.append(String("title"))
    vals.append(FsValue.string(String("t-") + doc_id))
    var fields = FsValue.map_of(keys^, vals^)
    var name = String("projects/p/databases/d/documents/coll/") + doc_id
    return ListenEvent(LE_DOCUMENT_CHANGE, -1, FsDocument(name^, fields^), True)


def _watermark(token_byte: Int, seconds: Int64, nanos: Int64) -> ListenEvent:
    """A resumable TargetChange(NO_CHANGE) carrying a resume_token + read_time
    (the CDC checkpoint boundary)."""
    var tok = List[UInt8]()
    tok.append(UInt8(token_byte))
    return ListenEvent(
        LE_TARGET_CHANGE, TCT_NO_CHANGE,
        FsDocument(String(""), FsValue.map_of(List[String](), List[FsValue]())),
        False, tok^, True, seconds, nanos, True,
    )


def _reset_tc() -> ListenEvent:
    """A TargetChange(RESET) — NO resume_token / read_time (a reset carries no
    committable position)."""
    return ListenEvent(
        LE_TARGET_CHANGE, TCT_RESET,
        FsDocument(String(""), FsValue.map_of(List[String](), List[FsValue]())),
        False,
    )


def _count_docs(events: List[ListenEvent]) -> Int:
    var c = 0
    for i in range(len(events)):
        if events[i].kind == LE_DOCUMENT_CHANGE:
            c += 1
    return c


def _last_watermark_secs(events: List[ListenEvent]) -> Int64:
    var s = Int64(-1)
    for i in range(len(events)):
        ref ev = events[i]
        if (
            ev.kind == LE_TARGET_CHANGE
            and ev.has_resume_token
            and ev.has_read_time
        ):
            s = ev.read_time_seconds
    return s


# =============================================================================
# (1) CROSS-POLL BUFFER CONTINUITY.
# =============================================================================
def test_cross_poll_continuity() raises:
    print("  test_cross_poll_continuity...")
    var buf = WatermarkBuffer()

    # Poll #1: a PARTIAL run — two DocumentChanges, NO terminating watermark.
    # The buffer emits NOTHING and keeps both events pending.
    var p1 = List[ListenEvent]()
    p1.append(_doc_change(String("a")))
    p1.append(_doc_change(String("b")))
    var e1 = buf.feed(p1^)
    assert_equal(len(e1), 0, "partial run (no watermark) emits nothing")
    assert_equal(buf.pending_len(), 2, "both events buffered across the poll")

    # Poll #2: the terminating watermark arrives -> the WHOLE run (a, b + the
    # watermark) is emitted exactly ONCE, and the buffer drains to empty.
    var p2 = List[ListenEvent]()
    p2.append(_watermark(0xA1, Int64(1_800_000_000), Int64(0)))
    var e2 = buf.feed(p2^)
    assert_equal(_count_docs(e2), 2, "both split docs emitted exactly once")
    assert_equal(
        _last_watermark_secs(e2), Int64(1_800_000_000),
        "the emitted run terminates at the watermark read_time",
    )
    assert_equal(buf.pending_len(), 0, "buffer drained after the watermark emit")

    # Poll #3: a watermark PLUS the LEADING edge of the next snapshot (doc c
    # after the watermark). Emit up to the watermark; carry c forward.
    var p3 = List[ListenEvent]()
    p3.append(_doc_change(String("x")))
    p3.append(_watermark(0xA2, Int64(1_800_000_100), Int64(0)))
    p3.append(_doc_change(String("c")))  # leading edge of the NEXT snapshot
    var e3 = buf.feed(p3^)
    assert_equal(_count_docs(e3), 1, "only x emitted (up to the watermark)")
    assert_equal(buf.pending_len(), 1, "c carried forward as the next snapshot's lead")

    # Poll #4: the next watermark completes c's snapshot -> c emitted, no dup of x.
    var p4 = List[ListenEvent]()
    p4.append(_watermark(0xA3, Int64(1_800_000_200), Int64(0)))
    var e4 = buf.feed(p4^)
    assert_equal(_count_docs(e4), 1, "c emitted exactly once (no dup / no loss)")
    assert_equal(buf.pending_len(), 0, "buffer drained")
    print("    OK")


# =============================================================================
# (2) RESET DISCARDS THE UN-EMITTED BUFFER (does NOT advance cursor / emit
#     partial), then re-drives cleanly.
# =============================================================================
def test_reset_discards_unemitted_buffer() raises:
    print("  test_reset_discards_unemitted_buffer...")
    var buf = WatermarkBuffer()

    # Poll #1: a partial run buffered (no watermark).
    var p1 = List[ListenEvent]()
    p1.append(_doc_change(String("stale1")))
    p1.append(_doc_change(String("stale2")))
    var e1 = buf.feed(p1^)
    assert_equal(len(e1), 0, "partial run buffered")
    assert_equal(buf.pending_len(), 2, "two stale events pending")

    # Poll #2: a RESET TargetChange arrives. The un-emitted stale buffer MUST be
    # DISCARDED — NO partial batch emitted, cursor does NOT advance.
    var p2 = List[ListenEvent]()
    p2.append(_reset_tc())
    var e2 = buf.feed(p2^)
    assert_equal(len(e2), 0, "RESET emits NOTHING (no partial batch)")
    assert_equal(buf.pending_len(), 0, "the un-emitted stale buffer is DISCARDED")

    # Poll #3: a clean re-drive after the RESET — fresh run + watermark. Only the
    # POST-RESET run is emitted; the discarded stale docs are gone.
    var p3 = List[ListenEvent]()
    p3.append(_doc_change(String("fresh1")))
    p3.append(_watermark(0xB1, Int64(1_800_000_500), Int64(0)))
    var e3 = buf.feed(p3^)
    assert_equal(_count_docs(e3), 1, "only the post-RESET fresh run emits")
    # The stale docs must NOT appear.
    var saw_stale = False
    for i in range(len(e3)):
        if e3[i].kind == LE_DOCUMENT_CHANGE:
            var nm = e3[i].document.name
            if nm.find(String("stale")) >= 0:
                saw_stale = True
    assert_false(saw_stale, "discarded stale docs do NOT resurface")
    print("    OK")


def test_reset_then_watermark_in_same_feed() raises:
    """A RESET followed by a fresh run + watermark IN THE SAME feed: the pre-RESET
    stale buffer is discarded; the post-RESET run (terminated by the watermark)
    emits. This proves the RESET-discard is applied BEFORE the watermark cut."""
    print("  test_reset_then_watermark_in_same_feed...")
    var buf = WatermarkBuffer()

    var p1 = List[ListenEvent]()
    p1.append(_doc_change(String("stale")))
    _ = buf.feed(p1^)
    assert_equal(buf.pending_len(), 1, "one stale event pending")

    var p2 = List[ListenEvent]()
    p2.append(_reset_tc())
    p2.append(_doc_change(String("fresh")))
    p2.append(_watermark(0xC1, Int64(1_800_000_600), Int64(0)))
    var e2 = buf.feed(p2^)
    assert_equal(_count_docs(e2), 1, "only the post-RESET fresh doc emits")
    var saw_stale = False
    for i in range(len(e2)):
        if (
            e2[i].kind == LE_DOCUMENT_CHANGE
            and e2[i].document.name.find(String("stale")) >= 0
        ):
            saw_stale = True
    assert_false(saw_stale, "the pre-RESET stale doc is discarded, not emitted")
    assert_equal(buf.pending_len(), 0, "buffer drained after the post-RESET watermark")
    print("    OK")


# =============================================================================
# (4) A WATERMARK WITH ZERO DOCUMENTS (a NO_CHANGE keepalive) advances read_time
#     without emitting a document record.
# =============================================================================
def test_zero_doc_watermark_advances_without_record() raises:
    print("  test_zero_doc_watermark_advances_without_record...")
    var buf = WatermarkBuffer()

    # A pure keepalive watermark: a resumable TargetChange with NO preceding docs.
    var p1 = List[ListenEvent]()
    p1.append(_watermark(0xD1, Int64(1_800_000_700), Int64(999)))
    var e1 = buf.feed(p1^)
    # The batch is emitted (it carries the watermark boundary) but has ZERO docs.
    assert_equal(_count_docs(e1), 0, "keepalive watermark carries no document")
    assert_equal(
        _last_watermark_secs(e1), Int64(1_800_000_700),
        "the keepalive advances read_time",
    )
    assert_true(len(e1) >= 1, "the watermark boundary event is present in the emit")
    assert_equal(buf.pending_len(), 0, "buffer drained")
    print("    OK")


# =============================================================================
# (3) RECONNECT: drive the REAL FirestoreListenClient over a ScriptedStream that
#     ENDS mid-watch (EOF) -> poll_progress surfaces ended_seen; a fresh client
#     open_after(committed_read_time) continues; the buffer across the reconnect
#     emits each watermark run exactly once (no loss / no dup).
# =============================================================================


def _make_reactor() raises -> Reactor[NoopSink]:
    comptime if CompilationTarget.is_linux():
        return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL)
    return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_KQUEUE)


def _value_string(v: String) -> List[UInt8]:
    var out = List[UInt8]()
    pb_write_string_field(out, FV_STRING_VALUE, v)
    return out^


def _build_document(name: String, title: String) -> List[UInt8]:
    var val = _value_string(title)
    var entry = List[UInt8]()
    pb_write_string_field(entry, FMAP_ENTRY_KEY, String("title"))
    pb_write_message_field(entry, FMAP_ENTRY_VALUE, val)
    var doc = List[UInt8]()
    pb_write_string_field(doc, DOC_NAME, name)
    pb_write_message_field(doc, DOC_FIELDS, entry)
    return doc^


def _resp_document_change(name: String, title: String) -> List[UInt8]:
    var doc = _build_document(name, title)
    var dc = List[UInt8]()
    pb_write_message_field(dc, DC_DOCUMENT, doc)
    var resp = List[UInt8]()
    pb_write_message_field(resp, LRESP_DOCUMENT_CHANGE, dc)
    return resp^


def _resp_watermark(token_byte: Int, seconds: Int64, nanos: Int64) -> List[UInt8]:
    var ts = List[UInt8]()
    pb_write_varint_field(ts, FTS_SECONDS, UInt64(seconds))
    pb_write_varint_field(ts, FTS_NANOS, UInt64(nanos))
    var tok = List[UInt8]()
    tok.append(UInt8(token_byte))
    var tc = List[UInt8]()
    pb_write_varint_field(tc, TC_TARGET_CHANGE_TYPE, UInt64(TCT_NO_CHANGE))
    pb_write_bytes_field(tc, TC_RESUME_TOKEN, tok)
    pb_write_message_field(tc, TC_READ_TIME, ts)
    var resp = List[UInt8]()
    pb_write_message_field(resp, LRESP_TARGET_CHANGE, tc)
    return resp^


def _server_head(sid: UInt32, mut bytes: List[UInt8]) raises:
    var entries = List[SettingsEntry]()
    encode_settings_frame(entries^, bytes)
    var hpack = HpackEncoder(max_table_size=4096)
    var hdrs = List[HpackHeader]()
    hdrs.append(HpackHeader(String(":status"), String("200")))
    hdrs.append(HpackHeader(String("content-type"), String("application/grpc")))
    var block = hpack.encode_block(hdrs^)
    encode_headers_frame(sid, block^, end_stream=False, end_headers=True, out=bytes)


def _emit_message(sid: UInt32, var msg: List[UInt8], mut bytes: List[UInt8]) raises:
    var env = encode_grpc_envelope(msg^)
    encode_data_frame(sid, env^, end_stream=False, out=bytes)


def _drive_client_until_end(
    mut client: FirestoreListenClient[ScriptedStream],
    mut reactor: Reactor[NoopSink],
    mut buf: WatermarkBuffer,
) raises -> List[List[ListenEvent]]:
    """Poll the client until it reports ended_seen; feed each poll's events into
    the buffer; collect every emitted watermark batch. Returns the list of
    emitted batches (each a complete watermark run)."""
    var batches = List[List[ListenEvent]]()
    var polls = 0
    while polls < 500:
        polls += 1
        var events = client.poll_progress[PerCoreAsyncRuntime[NoopSink]](
            reactor, max_wall_us=1_000_000
        )
        var ended = client.last_poll_ended()
        var emitted = buf.feed(events^)
        if len(emitted) > 0:
            batches.append(emitted^)
        if ended:
            break
    return batches^


# =============================================================================
# (5) DRAIN MUST LOOP ACROSS LOW-LEVEL POLLS UNTIL A WATERMARK EMITS.
#
# This is the falsifier for a LIVE `appended=0` bug (wire-proven
#). Firestore pushes the initial snapshot as a SEQUENCE of h2 DATA
# frames — `TargetChange ADD`, then `DocumentChange`(s), then a terminating
# `TargetChange CURRENT` carrying read_time+resume_token (the watermark). Each
# low-level `poll` (`drive_h2_recv_until_progress`) returns as soon as ANY new
# body bytes land, so the FIRST poll yields only a FRAGMENT with NO watermark;
# the WatermarkBuffer correctly buffers it and emits nothing. The source's
# `drain()` MUST then keep polling until the watermark arrives before it can
# emit a complete run.
#
# FAILS ON PRE-FIX CODE: the old `FirestoreWatchSource.drain()` returned
# immediately after the first non-emitting poll (the "idle poll" early return),
# stranding the buffered fragment and committing NOTHING (`appended=0`). This
# test proves (a) a chunked snapshot genuinely delivers a fragment on the first
# poll [emit==0], and (b) a drain-style LOOP over subsequent polls emits the
# COMPLETE run exactly once — so a drain that stops after one poll is wrong.
# =============================================================================
def test_drain_must_loop_across_polls_for_watermark() raises:
    print("  test_drain_must_loop_across_polls_for_watermark...")
    var reactor = _make_reactor()
    var sid = UInt32(1)

    # A whole snapshot: head + doc a + doc b + a CURRENT watermark, all in one
    # script. Chunked reads (small max_read_per_call) force the client's
    # per-poll recv-drive to return a FRAGMENT before the watermark frame lands.
    var s = List[UInt8]()
    _server_head(sid, s)
    _emit_message(sid, _resp_document_change(
        String("projects/p/databases/d/documents/coll/a"), String("A")), s)
    _emit_message(sid, _resp_document_change(
        String("projects/p/databases/d/documents/coll/b"), String("B")), s)
    _emit_message(sid, _resp_watermark(0x55, Int64(1_800_009_000), Int64(0)), s)

    var stream = ScriptedStream.from_read_script(s^)
    stream.set_negotiated_protocol(NEGOTIATED_HTTP_2)
    # A small per-read clamp so the snapshot arrives across several polls (the
    # live fragmentation shape). 48 bytes/read splits the head + each frame.
    stream.set_max_read_per_call(48)
    var docs = List[String]()
    docs.append(String("projects/p/databases/d/documents/coll/a"))
    docs.append(String("projects/p/databases/d/documents/coll/b"))
    var client = FirestoreListenClient[ScriptedStream](
        stream^, String("firestore.googleapis.com"), String("tok")
    )
    client.open[PerCoreAsyncRuntime[NoopSink]](
        reactor, String("projects/p/databases/d"), docs, 9
    )
    assert_equal(Int(client.status()), 200)

    var buf = WatermarkBuffer()

    # (a) ONE poll: the first recv-drive returns a fragment with NO watermark
    # boundary yet -> the buffer emits NOTHING. This is EXACTLY what a
    # single-poll drain would return (empty => appended=0 — the bug).
    var first = client.poll_progress[PerCoreAsyncRuntime[NoopSink]](
        reactor, max_wall_us=1_000_000
    )
    var first_emit = buf.feed(first^)
    assert_equal(
        len(first_emit), 0,
        "the FIRST poll is a fragment (no watermark yet) — a single-poll drain"
        " would emit nothing (appended=0)",
    )

    # (b) A drain-style LOOP over subsequent polls: keep polling until the
    # buffer emits a complete run. The watermark arrives on a later poll and the
    # whole run (a, b + boundary) emits exactly once.
    var emitted = List[ListenEvent]()
    var polls = 0
    while polls < 500 and len(emitted) == 0:
        polls += 1
        var ev = client.poll_progress[PerCoreAsyncRuntime[NoopSink]](
            reactor, max_wall_us=1_000_000
        )
        var ended = client.last_poll_ended()
        emitted = buf.feed(ev^)
        if ended and len(emitted) == 0:
            break
    assert_equal(
        _count_docs(emitted), 2,
        "looping the drain across polls emits BOTH docs exactly once",
    )
    assert_equal(
        _last_watermark_secs(emitted), Int64(1_800_009_000),
        "the emitted run terminates at the CURRENT watermark read_time",
    )
    assert_equal(buf.pending_len(), 0, "buffer drained after the watermark emit")
    print("    OK")


# =============================================================================
# (6) RESUME-CONFIRMATION ECHO MUST NOT TERMINATE THE DRAIN.
#
# The falsifier for a LIVE STEP-2 `appended=0` resume bug (wire-proven
#). When the live source resumes with `open_after(T)`, Firestore
# FIRST delivers a "consistent-snapshot-at-T" confirmation — a keepalive
# TargetChange(NO_CHANGE) echoing read_time == T carrying ZERO document changes
# — BEFORE the real post-T changes stream in on subsequent low-level polls. The
# WatermarkBuffer correctly emits that confirmation as a complete (zero-doc)
# run; but a drain that RETURNS on it strands the actual post-resume changes
# (which arrive next) and commits nothing. `run_is_advancing` is the predicate
# the drain uses to SKIP the stale confirmation and keep polling.
#
# FAILS ON PRE-FIX CODE: the drain returned on ANY complete watermark run,
# including the stale resume-confirmation echo -> STEP 2 committed 0 (the modify
# + delete were never captured). This pins the exact wire shapes observed live.
# =============================================================================
def test_resume_confirmation_echo_is_not_advancing() raises:
    print("  test_resume_confirmation_echo_is_not_advancing...")
    var resume_secs = Int64(1_800_174_790)
    var resume_nanos = Int64(148_844_000)

    # (a) The stale resume-confirmation echo: a zero-doc NO_CHANGE watermark
    # echoing read_time == the resume position. NOT advancing -> the drain must
    # skip it and keep polling (the exact STEP-2-poll-1 wire shape).
    var echo = List[ListenEvent]()
    echo.append(_watermark(0xAA, resume_secs, resume_nanos))
    assert_false(
        run_is_advancing(echo, resume_secs, resume_nanos),
        "a zero-doc watermark echoing the resume read_time is NOT advancing",
    )

    # (b) A run carrying a document change (the real post-resume change) IS
    # advancing even if its boundary read_time were somehow == the resume point.
    var with_doc = List[ListenEvent]()
    with_doc.append(_doc_change(String("alpha")))
    with_doc.append(_watermark(0xBB, resume_secs, resume_nanos))
    assert_true(
        run_is_advancing(with_doc, resume_secs, resume_nanos),
        "a run carrying a document change IS advancing (the real change)",
    )

    # (c) A later zero-doc keepalive whose boundary read_time is STRICTLY GREATER
    # than the resume position IS advancing (a genuine new consistent snapshot).
    var later = List[ListenEvent]()
    later.append(_watermark(0xCC, resume_secs, resume_nanos + Int64(1)))
    assert_true(
        run_is_advancing(later, resume_secs, resume_nanos),
        "a later (strictly-greater read_time) keepalive IS advancing",
    )
    var later_secs = List[ListenEvent]()
    later_secs.append(_watermark(0xCD, resume_secs + Int64(1), Int64(0)))
    assert_true(
        run_is_advancing(later_secs, resume_secs, resume_nanos),
        "a later-seconds keepalive IS advancing (lexicographic secs.nanos)",
    )

    # (d) COLD START (resume 0.0): the initial snapshot's watermark is > 0 -> a
    # zero-doc watermark at a real read_time is advancing (never suppressed).
    var cold = List[ListenEvent]()
    cold.append(_watermark(0xDD, Int64(1_800_000_000), Int64(0)))
    assert_true(
        run_is_advancing(cold, Int64(0), Int64(0)),
        "cold start: the initial watermark is advancing (resume position 0.0)",
    )
    print("    OK")


def test_reconnect_resumes_without_loss_or_dup() raises:
    print("  test_reconnect_resumes_without_loss_or_dup...")
    var reactor = _make_reactor()
    var sid = UInt32(1)

    # ---- SESSION 1: server head + doc a + watermark T1, then EOF (script ends).
    var s1 = List[UInt8]()
    _server_head(sid, s1)
    _emit_message(sid, _resp_document_change(
        String("projects/p/databases/d/documents/coll/a"), String("A")), s1)
    _emit_message(sid, _resp_watermark(0x01, Int64(1_800_000_000), Int64(0)), s1)
    # (script ends here -> the ScriptedStream returns EOF -> ended_seen)

    var stream1 = ScriptedStream.from_read_script(s1^)
    stream1.set_negotiated_protocol(NEGOTIATED_HTTP_2)
    stream1.set_max_read_per_call(4096)
    var docs = List[String]()
    docs.append(String("projects/p/databases/d/documents/coll/a"))
    var client1 = FirestoreListenClient[ScriptedStream](
        stream1^, String("firestore.googleapis.com"), String("tok")
    )
    client1.open[PerCoreAsyncRuntime[NoopSink]](
        reactor, String("projects/p/databases/d"), docs, 7
    )
    assert_equal(Int(client1.status()), 200)

    var buf = WatermarkBuffer()
    var batches1 = _drive_client_until_end(client1, reactor, buf)
    # Session 1 emitted the T1 watermark run carrying doc a exactly once.
    var docs_seen_1 = 0
    var committed_secs = Int64(0)
    for i in range(len(batches1)):
        docs_seen_1 += _count_docs(batches1[i])
        var s = _last_watermark_secs(batches1[i])
        if s > committed_secs:
            committed_secs = s
    assert_equal(docs_seen_1, 1, "session 1 emitted doc a exactly once")
    assert_equal(committed_secs, Int64(1_800_000_000), "committed watermark T1")
    assert_equal(buf.pending_len(), 0, "no partial fragment left after the EOF")

    # ---- RECONNECT (SESSION 2): re-open AFTER the committed watermark T1 via
    # open_after(read_time). The server re-sends only changes after T1: doc b +
    # watermark T2. The buffer emits b exactly once (a is NOT re-emitted — the
    # resume boundary excludes it; here the fresh session simply does not carry a).
    var s2 = List[UInt8]()
    _server_head(sid, s2)
    _emit_message(sid, _resp_document_change(
        String("projects/p/databases/d/documents/coll/b"), String("B")), s2)
    _emit_message(sid, _resp_watermark(0x02, Int64(1_800_000_100), Int64(0)), s2)

    var stream2 = ScriptedStream.from_read_script(s2^)
    stream2.set_negotiated_protocol(NEGOTIATED_HTTP_2)
    stream2.set_max_read_per_call(4096)
    var client2 = FirestoreListenClient[ScriptedStream](
        stream2^, String("firestore.googleapis.com"), String("tok")
    )
    # RESUME after the committed watermark T1 (the crash-safe read_time).
    client2.open_after[PerCoreAsyncRuntime[NoopSink]](
        reactor, String("projects/p/databases/d"), docs, 7,
        committed_secs, Int64(0),
    )
    assert_equal(Int(client2.status()), 200)

    var batches2 = _drive_client_until_end(client2, reactor, buf)
    var docs_seen_2 = 0
    var committed_secs_2 = committed_secs
    for i in range(len(batches2)):
        docs_seen_2 += _count_docs(batches2[i])
        var s = _last_watermark_secs(batches2[i])
        if s > committed_secs_2:
            committed_secs_2 = s
    assert_equal(docs_seen_2, 1, "session 2 (resume) emitted doc b exactly once")
    assert_equal(committed_secs_2, Int64(1_800_000_100), "advanced to watermark T2")
    print("    OK")


def main() raises:
    print("test_firestore_watch_source (live source cross-poll buffer +"
          " reconnect, offline)")
    test_cross_poll_continuity()
    test_reset_discards_unemitted_buffer()
    test_reset_then_watermark_in_same_feed()
    test_zero_doc_watermark_advances_without_record()
    test_drain_must_loop_across_polls_for_watermark()
    test_resume_confirmation_echo_is_not_advancing()
    test_reconnect_resumes_without_loss_or_dup()
    print("ALL PASS")
