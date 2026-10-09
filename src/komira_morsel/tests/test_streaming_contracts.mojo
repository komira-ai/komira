# =============================================================================
# Streaming source and sink contracts: StreamPoll, BacklogReading,
# StreamSourceCaps, the trait defaults, StepId, CommitToken, SinkClass.
# =============================================================================
#
# What these tests prove (oracles from the docstrings of
# `streaming_source.mojo` and `streaming_sink.mojo`):
#
#   * Each `StreamPoll` constructor yields its own status, and exactly one of
#     the four `is_*` predicates is true for it; `Item` carries the morsel it
#     was built with (`take_item` gives that morsel back), `Watermark` carries
#     its timestamp, and the other states carry timestamp 0.
#   * `Idle` and `Closed` are distinct: a scripted source that goes idle and
#     then gets more data keeps being pollable, which the batch
#     `Optional[Morsel]` cannot express.
#   * `BacklogReading` clamps a budget of 0 or below to 1 and keeps 1 or above
#     as given; the default budget is 1.
#   * `StreamSourceCaps` defaults every capability to False and sets each one
#     on its own.
#   * The `StreamingMorselSource` defaults: `backlog()` is `None` and
#     `consumer_epoch_cursor()` is `Int64.MAX`; an override replaces both.
#   * `StepId` equality is by `seq`; `CommitToken` keeps its step and handle
#     (handle 0 by default).
#   * `SinkClass` tags: each constructor gives its own tag, exactly one of
#     the three `is_*` predicates is true, the default is at-least-once, and
#     only idempotent and transactional qualify for exactly-once.
#   * A sink conformer driven through the documented step lifecycle
#     (consume, pre_commit, commit; restore_from then commit; abort) is
#     callable through the trait, generic over `StreamingMorselSink`.
#
# Single-threaded: the step driver polls one source and drives one sink in
# program order.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_buffer.byte_buffer import ByteBuffer
from komira_morsel.morsel import Morsel
from komira_morsel.streaming_sink import (
    SINK_CLASS_AT_LEAST_ONCE,
    SINK_CLASS_IDEMPOTENT,
    SINK_CLASS_TRANSACTIONAL,
    CommitToken,
    SinkClass,
    StepId,
    StreamingMorselSink,
)
from komira_morsel.streaming_source import (
    STREAM_POLL_CLOSED,
    STREAM_POLL_IDLE,
    STREAM_POLL_ITEM,
    STREAM_POLL_WATERMARK,
    BacklogReading,
    CheckpointSerializable,
    StreamPoll,
    StreamSourceCaps,
    StreamingMorselSource,
)


# -----------------------------------------------------------------------------
# A source position: an Int64 offset as 8 little-endian bytes.
# -----------------------------------------------------------------------------


@fieldwise_init
struct OffsetPos(CheckpointSerializable):
    var offset: Int64

    def to_checkpoint_bytes(self) raises -> ByteBuffer:
        var b = List[UInt8]()
        var v = UInt64(self.offset)
        for i in range(8):
            b.append(UInt8((v >> UInt64(8 * i)) & 0xFF))
        return ByteBuffer(b^)

    @staticmethod
    def from_checkpoint_bytes(var bytes: ByteBuffer) raises -> Self:
        return OffsetPos(offset=bytes.read_i64_le())


comptime _W = UInt8(9)
"""Script byte: emit a watermark (timestamp = 1000 + cursor)."""


struct ScriptedSource(StreamingMorselSource):
    """Plays a test-controlled script of poll states. Item morsels carry
    `morsel_id = cursor`. Keeps the trait's `backlog` and
    `consumer_epoch_cursor` defaults."""

    comptime Position = OffsetPos
    var script: List[UInt8]
    var cursor: Int

    def __init__(out self, var script: List[UInt8]):
        self.script = script^
        self.cursor = 0

    def poll_next(mut self, worker_id: Int) raises -> StreamPoll:
        if self.cursor >= len(self.script):
            return StreamPoll.closed()
        var c = self.cursor
        var s = self.script[c]
        self.cursor += 1
        if s == STREAM_POLL_ITEM:
            return StreamPoll.item(Morsel.empty(c, worker_id))
        if s == STREAM_POLL_IDLE:
            return StreamPoll.idle()
        if s == _W:
            return StreamPoll.watermark(Int64(1000 + c))
        return StreamPoll.closed()

    def current_position(self) -> OffsetPos:
        return OffsetPos(offset=Int64(self.cursor))

    def seek(mut self, var pos: OffsetPos) raises:
        self.cursor = Int(pos.offset)

    def capabilities(self) -> StreamSourceCaps:
        return StreamSourceCaps(is_unbounded=True, replayable=True)


struct LaggingSource(StreamingMorselSource):
    """Overrides both optional methods."""

    comptime Position = OffsetPos
    var head: Int64
    var drained: Int64

    def __init__(out self, head: Int64, drained: Int64):
        self.head = head
        self.drained = drained

    def poll_next(mut self, worker_id: Int) raises -> StreamPoll:
        return StreamPoll.idle()

    def current_position(self) -> OffsetPos:
        return OffsetPos(offset=self.drained)

    def seek(mut self, var pos: OffsetPos) raises:
        self.drained = pos.offset

    def capabilities(self) -> StreamSourceCaps:
        return StreamSourceCaps()

    def backlog(mut self) raises -> Optional[BacklogReading]:
        return BacklogReading(self.head - self.drained, Int64(4))

    def consumer_epoch_cursor(self) -> Int64:
        return self.drained


def _status_word[S: StreamingMorselSource](mut src: S) raises -> String:
    """Poll once; one letter per state, the morsel id or timestamp after it."""
    var p = src.poll_next(0)
    var n = 0
    if p.is_item():
        n += 1
    if p.is_idle():
        n += 1
    if p.is_watermark():
        n += 1
    if p.is_closed():
        n += 1
    if n != 1:
        raise Error("expected exactly one is_* true, got " + String(n))
    if p.is_item():
        var m = p.take_item()
        return "I" + String(m.morsel_id)
    if p.is_idle():
        return "D"
    if p.is_watermark():
        return "W" + String(p.watermark_ts())
    return "C"


def test_poll_constructors_and_predicates() raises:
    var it = StreamPoll.item(Morsel.empty(42, 3))
    assert_equal(it.status, STREAM_POLL_ITEM)
    assert_true(it.is_item())
    assert_false(it.is_idle())
    assert_false(it.is_watermark())
    assert_false(it.is_closed())
    assert_equal(it.watermark_ts(), Int64(0))
    var m = it.take_item()
    assert_equal(m.morsel_id, 42)
    assert_equal(m.partition_id, 3)
    # The payload moved out: the slot is empty now.
    assert_false(Bool(it._item))

    var idle = StreamPoll.idle()
    assert_equal(idle.status, STREAM_POLL_IDLE)
    assert_false(idle.is_item())
    assert_true(idle.is_idle())
    assert_false(idle.is_watermark())
    assert_false(idle.is_closed())
    assert_false(Bool(idle._item))
    assert_equal(idle.watermark_ts(), Int64(0))

    var wm = StreamPoll.watermark(Int64(-7))
    assert_equal(wm.status, STREAM_POLL_WATERMARK)
    assert_false(wm.is_item())
    assert_false(wm.is_idle())
    assert_true(wm.is_watermark())
    assert_false(wm.is_closed())
    assert_false(Bool(wm._item))
    assert_equal(wm.watermark_ts(), Int64(-7))

    var cl = StreamPoll.closed()
    assert_equal(cl.status, STREAM_POLL_CLOSED)
    assert_false(cl.is_item())
    assert_false(cl.is_idle())
    assert_false(cl.is_watermark())
    assert_true(cl.is_closed())
    assert_false(Bool(cl._item))
    assert_equal(cl.watermark_ts(), Int64(0))

    # The four tags are the documented values 0..3.
    assert_equal(Int(STREAM_POLL_ITEM), 0)
    assert_equal(Int(STREAM_POLL_IDLE), 1)
    assert_equal(Int(STREAM_POLL_WATERMARK), 2)
    assert_equal(Int(STREAM_POLL_CLOSED), 3)


def test_idle_is_not_closed() raises:
    # item, idle, idle, watermark, item, then the script ends -> closed for
    # every later poll.
    var src = ScriptedSource(
        [STREAM_POLL_ITEM, STREAM_POLL_IDLE, STREAM_POLL_IDLE, _W, STREAM_POLL_ITEM]
    )
    var got = String("")
    for _ in range(7):
        got += _status_word(src) + " "
    assert_equal(got, "I0 D D W1003 I4 C C ")


def test_seek_replays_from_a_checkpointed_position() raises:
    var src = ScriptedSource([STREAM_POLL_ITEM, STREAM_POLL_ITEM, STREAM_POLL_ITEM])
    _ = _status_word(src)
    var pos = src.current_position()
    assert_equal(pos.offset, Int64(1))
    var bytes = pos.to_checkpoint_bytes()
    assert_equal(bytes.length(), 8)
    _ = _status_word(src)
    _ = _status_word(src)
    src.seek(OffsetPos.from_checkpoint_bytes(bytes^))
    assert_equal(_status_word(src), "I1")
    assert_equal(_status_word(src), "I2")
    assert_equal(_status_word(src), "C")


def test_source_defaults_and_overrides() raises:
    var s = ScriptedSource(List[UInt8]())
    assert_false(Bool(s.backlog()))
    assert_equal(s.consumer_epoch_cursor(), Int64.MAX)
    var caps = s.capabilities()
    assert_true(caps.is_unbounded)
    assert_true(caps.replayable)
    assert_false(caps.emits_watermark)
    assert_false(caps.exactly_once_capable)

    var lag = LaggingSource(Int64(10), Int64(3))
    var b = lag.backlog()
    assert_true(Bool(b))
    assert_equal(b.value().outstanding, Int64(7))
    assert_equal(b.value().budget, Int64(4))
    assert_equal(lag.consumer_epoch_cursor(), Int64(3))
    assert_equal(_status_word(lag), "D")


def test_backlog_budget_clamp() raises:
    assert_equal(BacklogReading(Int64(5)).budget, Int64(1))
    assert_equal(BacklogReading(Int64(5), Int64(0)).budget, Int64(1))
    assert_equal(BacklogReading(Int64(5), Int64(-3)).budget, Int64(1))
    assert_equal(BacklogReading(Int64(5), Int64(1)).budget, Int64(1))
    assert_equal(BacklogReading(Int64(5), Int64(2)).budget, Int64(2))
    assert_equal(BacklogReading(Int64(5), Int64.MAX).budget, Int64.MAX)
    # `outstanding` is carried unchanged, also when 0.
    assert_equal(BacklogReading(Int64(0), Int64(8)).outstanding, Int64(0))


def test_stream_source_caps() raises:
    var d = StreamSourceCaps()
    assert_false(d.is_unbounded)
    assert_false(d.replayable)
    assert_false(d.emits_watermark)
    assert_false(d.exactly_once_capable)
    var a = StreamSourceCaps(is_unbounded=True)
    assert_true(a.is_unbounded)
    assert_false(a.replayable or a.emits_watermark or a.exactly_once_capable)
    var b = StreamSourceCaps(replayable=True)
    assert_true(b.replayable)
    assert_false(b.is_unbounded or b.emits_watermark or b.exactly_once_capable)
    var c = StreamSourceCaps(emits_watermark=True)
    assert_true(c.emits_watermark)
    assert_false(c.is_unbounded or c.replayable or c.exactly_once_capable)
    var e = StreamSourceCaps(exactly_once_capable=True)
    assert_true(e.exactly_once_capable)
    assert_false(e.is_unbounded or e.replayable or e.emits_watermark)


# -----------------------------------------------------------------------------
# Sink side
# -----------------------------------------------------------------------------


def test_step_id_equality() raises:
    assert_equal(StepId().seq, UInt64(0))
    assert_true(StepId(3) == StepId(3))
    assert_false(StepId(3) == StepId(4))
    assert_true(StepId(3) != StepId(4))
    assert_false(StepId(3) != StepId(3))
    assert_true(StepId(0) == StepId())


def test_commit_token() raises:
    var t = CommitToken(StepId(9))
    assert_equal(t.step.seq, UInt64(9))
    assert_equal(t.txn_handle, UInt64(0))
    var u = CommitToken(StepId(2), UInt64(77))
    assert_equal(u.step.seq, UInt64(2))
    assert_equal(u.txn_handle, UInt64(77))


def _class_word(c: SinkClass) raises -> String:
    var n = Int(c.is_idempotent()) + Int(c.is_transactional()) + Int(
        c.is_at_least_once()
    )
    if n != 1:
        raise Error("expected exactly one is_* true, got " + String(n))
    var w = String("I") if c.is_idempotent() else (
        String("T") if c.is_transactional() else String("A")
    )
    return w + ("+EO" if c.qualifies_for_exactly_once() else "-EO")


def test_sink_class() raises:
    assert_equal(Int(SINK_CLASS_IDEMPOTENT), 0)
    assert_equal(Int(SINK_CLASS_TRANSACTIONAL), 1)
    assert_equal(Int(SINK_CLASS_AT_LEAST_ONCE), 2)
    assert_equal(SinkClass().tag, SINK_CLASS_AT_LEAST_ONCE)
    assert_equal(SinkClass.idempotent().tag, SINK_CLASS_IDEMPOTENT)
    assert_equal(SinkClass.transactional().tag, SINK_CLASS_TRANSACTIONAL)
    assert_equal(SinkClass.at_least_once().tag, SINK_CLASS_AT_LEAST_ONCE)
    assert_equal(_class_word(SinkClass.idempotent()), "I+EO")
    assert_equal(_class_word(SinkClass.transactional()), "T+EO")
    assert_equal(_class_word(SinkClass.at_least_once()), "A-EO")
    assert_equal(_class_word(SinkClass()), "A-EO")
    # A tag outside the three: no predicate holds and it does not qualify.
    var odd = SinkClass(UInt8(7))
    assert_false(odd.is_idempotent() or odd.is_transactional())
    assert_false(odd.is_at_least_once())
    assert_false(odd.qualifies_for_exactly_once())


struct LogSink(StreamingMorselSink):
    var log: List[String]
    var pending: Int

    def __init__(out self):
        self.log = List[String]()
        self.pending = 0

    def consume(mut self, worker_id: Int, var delta_morsel: Morsel) raises:
        self.pending += 1
        self.log.append("c" + String(delta_morsel.morsel_id))

    def pre_commit(mut self, step: StepId) raises -> CommitToken:
        self.log.append("p" + String(step.seq))
        return CommitToken(step, UInt64(self.pending))

    def commit(mut self, step: StepId) raises:
        self.log.append("C" + String(step.seq))
        self.pending = 0

    def abort(mut self, step: StepId) raises:
        self.log.append("A" + String(step.seq))
        self.pending = 0

    def restore_from(mut self, var token: CommitToken) raises:
        self.log.append("r" + String(token.step.seq) + "/" + String(token.txn_handle))
        self.pending = Int(token.txn_handle)

    def sink_class(self) -> SinkClass:
        return SinkClass.transactional()


def _drive_step[K: StreamingMorselSink](mut sink: K, n: UInt64, rows: Int) raises -> CommitToken:
    for i in range(rows):
        sink.consume(0, Morsel.empty(i, 0))
    var tok = sink.pre_commit(StepId(n))
    sink.commit(StepId(n))
    return tok


def test_sink_step_lifecycle() raises:
    var sink = LogSink()
    var t1 = _drive_step(sink, 1, 2)
    assert_equal(t1.step.seq, UInt64(1))
    assert_equal(t1.txn_handle, UInt64(2))
    # Crash between phase 1 and 2: restore from the token, then commit.
    sink.consume(0, Morsel.empty(5, 0))
    var t2 = sink.pre_commit(StepId(2))
    var fresh = LogSink()
    fresh.restore_from(t2)
    fresh.commit(StepId(2))
    sink.abort(StepId(3))
    assert_equal(String(",").join(sink.log), "c0,c1,p1,C1,c5,p2,A3")
    assert_equal(String(",").join(fresh.log), "r2/1,C2")
    assert_true(sink.sink_class().qualifies_for_exactly_once())


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
