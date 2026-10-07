# =============================================================================
# test_firestore_watch_drain.mojo — the Listen drain loop and its decisions,
#   over scripted Listen sessions (no dial, no socket).
# =============================================================================
#
# `FirestoreWatchSource.drain` runs `drain_listen` over sessions that dial
# Firestore over TLS. Here the same `drain_listen` runs over
# `ScriptedSessions`, which plays a list of open outcomes and a list of polls,
# so every branch of the loop is reached offline.
#
# The rule (Firestore's SDKs restart the watch stream on every close while
# targets are listened; a per-target failure comes as a TargetChange REMOVE):
#   * a failed open and a stream end are the same thing: reconnect from the
#     committed watermark, up to the reconnect budget;
#   * with the budget used, a non-OK LAST end (a failed open included) is
#     raised as its `[grpc:N]` text; if that last end was a clean OK, the
#     drain returns an empty list (a live-but-idle drain).
#
# What each test proves, and the defect it catches:
#   * listen_drain_step / listen_end_code_after_failed_open: the decision
#     table, each row (a wrong comparison or a dropped row fails).
#   * every open fails UNAVAILABLE: three reconnects, then `[grpc:14]` raised.
#     Catches: a failed open escaping on the first attempt, or the budget
#     ending silently.
#   * a PERMISSION_DENIED end, then a good session: the drain reconnects and
#     returns the run. Catches: a per-code "permanent" stop the SDK does not
#     make.
#   * opens failing then a clean OK end: the LAST end decides, empty list.
#   * every session ends OK: empty list, no raise.
#   * a reconnect opens at the committed watermark.
#   * a stale resume confirmation is skipped; the next advancing run returns
#     and advances the committed watermark.
#   * an idle stream returns empty when the drain wall is spent; with the
#     wall disabled, the iteration cap ends it.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_grpc import GRPC_STATUS_UNKNOWN

from komira_gcp_firestore.firestore_listen_proto import (
    FsDocument,
    ListenEvent,
    LE_DOCUMENT_CHANGE,
    LE_TARGET_CHANGE,
    TCT_CURRENT,
)
from komira_gcp_firestore.firestore_value import FsValue
from komira_gcp_firestore.firestore_watch_drain import (
    LISTEN_DRAIN_RAISE,
    LISTEN_DRAIN_RECONNECT,
    LISTEN_DRAIN_RETURN_EMPTY,
    ListenDrainState,
    ListenSessions,
    drain_listen,
    listen_drain_step,
    listen_end_code_after_failed_open,
)

comptime _OPEN_OK = -1  # an open_results entry: the open succeeds
comptime _NOT_ENDED = -1  # a poll_end entry: the stream stays open


struct ScriptedSessions(ListenSessions, Movable):
    """Listen sessions played from two scripts.

    `open_results[i]` is the i-th open: `_OPEN_OK`, or the gRPC code the open
    failed with. `polls[i]` / `poll_end[i]` are the i-th poll across all
    sessions: its events, and `_NOT_ENDED` or the code the stream ended with.
    Past the poll script a poll is idle (no events, not ended). An open past
    its script raises, so a drain that reconnects more than expected fails.
    """

    var open_results: List[Int]
    var polls: List[List[ListenEvent]]
    var poll_end: List[Int]
    var opened_at_secs: List[Int64]
    var poll_calls: Int
    var _open_i: Int
    var _is_open: Bool
    var _ended: Bool
    var _end_code: Int
    var _last_end_code: Int
    var _last_end_text: String

    def __init__(out self, var open_results: List[Int]):
        self.open_results = open_results^
        self.polls = List[List[ListenEvent]]()
        self.poll_end = List[Int]()
        self.opened_at_secs = List[Int64]()
        self.poll_calls = 0
        self._open_i = 0
        self._is_open = False
        self._ended = False
        self._end_code = -1
        self._last_end_code = -1
        self._last_end_text = String("")

    def add_poll(mut self, var events: List[ListenEvent], end_code: Int):
        self.polls.append(events^)
        self.poll_end.append(end_code)

    def listen_is_open(self) -> Bool:
        return self._is_open

    def listen_open(mut self, resume_secs: Int64, resume_nanos: Int64) raises:
        if self._open_i >= len(self.open_results):
            raise Error("ScriptedSessions: an open the script did not expect")
        var r = self.open_results[self._open_i]
        self._open_i += 1
        self.opened_at_secs.append(resume_secs)
        if r == _OPEN_OK:
            self._is_open = True
            self._ended = False
            return
        self._last_end_code = listen_end_code_after_failed_open(r)
        self._last_end_text = String("[grpc:") + String(r) + "] open failed"

    def listen_poll(mut self) raises -> List[ListenEvent]:
        var i = self.poll_calls
        self.poll_calls += 1
        if i >= len(self.polls):
            self._ended = False
            return List[ListenEvent]()
        self._ended = self.poll_end[i] != _NOT_ENDED
        self._end_code = self.poll_end[i]
        return self.polls[i].copy()

    def listen_poll_ended(self) -> Bool:
        return self._ended

    def listen_close_after_end(mut self):
        self._last_end_code = self._end_code
        self._last_end_text = (
            String("[grpc:") + String(self._end_code) + "] stream ended"
        )
        self._is_open = False

    def listen_last_end_code(self) -> Int:
        return self._last_end_code

    def listen_last_end_text(self) -> String:
        return self._last_end_text


def _doc_change() -> ListenEvent:
    return ListenEvent(
        LE_DOCUMENT_CHANGE,
        -1,
        FsDocument(
            String("projects/p/databases/d/documents/c/x"),
            FsValue.map_of(List[String](), List[FsValue]()),
        ),
        True,
    )


def _watermark(secs: Int64) -> ListenEvent:
    var token = List[UInt8]()
    token.append(UInt8(7))
    return ListenEvent(
        LE_TARGET_CHANGE,
        TCT_CURRENT,
        FsDocument(String(""), FsValue.map_of(List[String](), List[FsValue]())),
        False,
        token^,
        True,
        secs,
        Int64(0),
        True,
    )


def _run() -> List[ListenEvent]:
    """A complete advancing run: one change and its watermark at t=10."""
    var r = List[ListenEvent]()
    r.append(_doc_change())
    r.append(_watermark(Int64(10)))
    return r^


def _drain(
    mut s: ScriptedSessions,
    mut st: ListenDrainState,
    drain_wall_us: Int64 = 50_000,
) raises -> List[ListenEvent]:
    return drain_listen(s, st, drain_wall_us=drain_wall_us, max_reconnects=3)


def test_drain_step_table() raises:
    assert_equal(listen_drain_step(0, 3, -1), LISTEN_DRAIN_RECONNECT)
    assert_equal(listen_drain_step(2, 3, 14), LISTEN_DRAIN_RECONNECT)
    assert_equal(listen_drain_step(3, 3, 14), LISTEN_DRAIN_RAISE)
    assert_equal(listen_drain_step(3, 3, 7), LISTEN_DRAIN_RAISE)
    assert_equal(listen_drain_step(3, 3, 1), LISTEN_DRAIN_RAISE)
    assert_equal(listen_drain_step(3, 3, 0), LISTEN_DRAIN_RETURN_EMPTY)
    # No end recorded at all (a drain before any open): nothing to raise.
    assert_equal(listen_drain_step(3, 3, -1), LISTEN_DRAIN_RETURN_EMPTY)
    assert_equal(listen_drain_step(0, 0, 14), LISTEN_DRAIN_RAISE)


def test_failed_open_code() raises:
    # The client recorded a status before raising: that status.
    assert_equal(listen_end_code_after_failed_open(14), 14)
    assert_equal(listen_end_code_after_failed_open(3), 3)
    # It raised with none (a stall before the head): UNKNOWN.
    assert_equal(
        listen_end_code_after_failed_open(-1), Int(GRPC_STATUS_UNKNOWN)
    )


def test_every_open_failing_raises_the_last_status() raises:
    var opens = List[Int]()
    for _ in range(3):
        opens.append(14)
    var s = ScriptedSessions(opens^)
    var st = ListenDrainState()
    var err = String("")
    try:
        _ = _drain(s, st)
    except e:
        err = String(e)
    assert_true(String("[grpc:14] open failed") in err, err)
    assert_equal(len(s.opened_at_secs), 3)


def test_a_permission_denied_end_reconnects() raises:
    var opens = List[Int]()
    opens.append(_OPEN_OK)
    opens.append(_OPEN_OK)
    var s = ScriptedSessions(opens^)
    s.add_poll(List[ListenEvent](), 7)  # first session ends PERMISSION_DENIED
    s.add_poll(_run(), _NOT_ENDED)
    var st = ListenDrainState()
    var got = _drain(s, st)
    assert_equal(len(got), 2)
    assert_equal(len(s.opened_at_secs), 2)
    assert_equal(st.committed_secs, Int64(10))


def test_the_last_end_decides() raises:
    var opens = List[Int]()
    opens.append(14)
    opens.append(14)
    opens.append(_OPEN_OK)
    var s = ScriptedSessions(opens^)
    s.add_poll(List[ListenEvent](), 0)  # the one open session ends OK
    var st = ListenDrainState()
    var got = _drain(s, st)
    assert_equal(len(got), 0)
    assert_equal(len(s.opened_at_secs), 3)


def test_clean_ends_return_empty() raises:
    var opens = List[Int]()
    for _ in range(3):
        opens.append(_OPEN_OK)
    var s = ScriptedSessions(opens^)
    for _ in range(3):
        s.add_poll(List[ListenEvent](), 0)
    var st = ListenDrainState()
    var got = _drain(s, st)
    assert_equal(len(got), 0)
    assert_equal(len(s.opened_at_secs), 3)


def test_a_non_ok_last_end_after_streams_raises() raises:
    var opens = List[Int]()
    for _ in range(3):
        opens.append(_OPEN_OK)
    var s = ScriptedSessions(opens^)
    s.add_poll(List[ListenEvent](), 0)
    s.add_poll(List[ListenEvent](), 0)
    s.add_poll(List[ListenEvent](), 13)
    var st = ListenDrainState()
    var err = String("")
    try:
        _ = _drain(s, st)
    except e:
        err = String(e)
    assert_true(String("[grpc:13] stream ended") in err, err)
    assert_true(String("3 reconnects") in err, err)


def test_reconnect_opens_at_the_committed_watermark() raises:
    var opens = List[Int]()
    opens.append(_OPEN_OK)
    var s = ScriptedSessions(opens^)
    s.add_poll(_run_at(Int64(20)), _NOT_ENDED)
    var st = ListenDrainState()
    st.reset(Int64(5), Int64(0))
    var got = _drain(s, st)
    assert_equal(len(got), 2)
    assert_equal(s.opened_at_secs[0], Int64(5))
    assert_equal(st.committed_secs, Int64(20))


def _run_at(secs: Int64) -> List[ListenEvent]:
    var r = List[ListenEvent]()
    r.append(_doc_change())
    r.append(_watermark(secs))
    return r^


def test_a_stale_confirmation_is_skipped() raises:
    var opens = List[Int]()
    opens.append(_OPEN_OK)
    var s = ScriptedSessions(opens^)
    var stale = List[ListenEvent]()
    stale.append(_watermark(Int64(5)))  # echoes the resume point, no docs
    s.add_poll(stale^, _NOT_ENDED)
    s.add_poll(_run_at(Int64(6)), _NOT_ENDED)
    var st = ListenDrainState()
    st.reset(Int64(5), Int64(0))
    var got = _drain(s, st)
    assert_equal(len(got), 2)
    assert_equal(s.poll_calls, 2)
    assert_equal(st.committed_secs, Int64(6))


def test_an_idle_stream_returns_at_the_wall() raises:
    var opens = List[Int]()
    opens.append(_OPEN_OK)
    var s = ScriptedSessions(opens^)
    var st = ListenDrainState()
    var got = _drain(s, st, drain_wall_us=20_000)
    assert_equal(len(got), 0)
    assert_true(s.poll_calls > 1)


def test_the_iteration_cap_ends_an_unbounded_drain() raises:
    var opens = List[Int]()
    opens.append(_OPEN_OK)
    var s = ScriptedSessions(opens^)
    var st = ListenDrainState()
    var got = _drain(s, st, drain_wall_us=0)  # no wall
    assert_equal(len(got), 0)
    assert_true(s.poll_calls >= 999_999)


def main() raises:
    print("test_firestore_watch_drain")
    test_drain_step_table()
    test_failed_open_code()
    test_every_open_failing_raises_the_last_status()
    test_a_permission_denied_end_reconnects()
    test_the_last_end_decides()
    test_clean_ends_return_empty()
    test_a_non_ok_last_end_after_streams_raises()
    test_reconnect_opens_at_the_committed_watermark()
    test_a_stale_confirmation_is_skipped()
    test_an_idle_stream_returns_at_the_wall()
    test_the_iteration_cap_ends_an_unbounded_drain()
    print("ALL PASS")
