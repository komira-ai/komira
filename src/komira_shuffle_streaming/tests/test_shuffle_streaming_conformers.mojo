# =============================================================================
# komira_shuffle_streaming/tests/test_shuffle_streaming_conformers.mojo
#   ShuffleWriteSink + ShuffleReadSource conformers — the segment-cut streaming
#   round-trip (multi-segment streaming).
# =============================================================================
#
# WHAT THESE TESTS PIN — a segment cut is a TYPE boundary: segment N's output is
# a `ShuffleWriteSink` (a StreamingMorselSink); segment N+1's input is a
# `ShuffleReadSource` (a StreamingMorselSource). Both wrap the PROVEN per-epoch
# shuffle free fns (sink_shuffle_write / seal_step / read_shuffle_partition
# in komira_shuffle) — epoch == step_id; the namespace is per-step-keyed.
#
# A producer drives ShuffleWriteSink through the 2PC lifecycle (consume ->
# pre_commit -> commit) to write + seal epoch e0, then e1; a ShuffleReadSource
# reads e0 then e1 back via poll_next. The four assertions:
#   (a) DATA ROUND-TRIPS per epoch (the values the sink consumed reappear, by
#       value, across the read of every partition of that epoch).
#   (b) reading an UNSEALED epoch returns IDLE (not Item, not Closed) — THE
#       load-bearing per-epoch gate (the fail-before/pass-after assertion).
#   (c) backlog() reports the correct epoch-lag (latest_sealed - cursor).
#   (d) seek(EpochCursor) replays from a given epoch (re-reads the SAME sealed
#       data deterministically).
#
# DETERMINISM: a single-process LocalFs scratch root (mirrors the continuous-
# epoch seal harness), no network, no threads — a step only advances when the
# test drives it. Single producer (producer_id=0) per the MVP shape.
# =============================================================================

from std.time import perf_counter_ns

from std.testing import assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Schema

from komira_objectstore.local_fs_conditional_store import (
    LocalFsConditionalStore,
)
from komira_objectstore.path import Path

from komira_morsel.morsel import Morsel
from komira_morsel.streaming_sink import StepId
from komira_morsel.streaming_source import StreamPoll

from komira_shuffle_streaming.shuffle_streaming_sink import ShuffleWriteSink
from komira_shuffle_streaming.shuffle_streaming_source import ShuffleReadSource, EpochCursor
from std.os import abort
from komira_runtime_paths import test_tmpdir


# ---------------------------------------------------------------------------
# ⚠ $TEST_TMPDIR (through `test_tmpdir()`), NOT A HARD-CODED `/tmp` PATH.
#
# The same test may run in more than one action at a time on one machine. A
# fixed `/tmp` path is shared by every one of those executions; the runner's
# `TEST_TMPDIR` is private to each run, which is what makes them disjoint.
# `test_tmpdir()` raises when it is unset; the test aborts rather than fall
# back to `/tmp`.
# ---------------------------------------------------------------------------
def _scratch_dir() -> String:
    """The directory THIS execution may write scratch files into."""
    try:
        return test_tmpdir()
    except e:
        abort(String("no scratch directory: ") + String(e))


# -----------------------------------------------------------------------------
# Scratch root + cleanup (the LocalFs harness shape, mirrors the seal test).
# -----------------------------------------------------------------------------
def _scratch_root(tag: String) -> String:
    var t = UInt64(perf_counter_ns())
    return (_scratch_dir() + String("/komira_shuffle_stream_")) + tag + String("_") + String(t)


def _cleanup(root: String):
    try:
        var store = LocalFsConditionalStore(root.copy())
        var res = store.list_with_delimiter(Path.parse(String("")))
        for i in range(len(res.objects)):
            store.delete(Path.parse(res.objects[i].location))
        _ = store^
    except:
        pass


# -----------------------------------------------------------------------------
# A 2-column (key, value) Int64 morsel builder (the windowed-agg delta shape:
# group_key + count). col0 = key (partitioned on); col1 = value (round-tripped).
# -----------------------------------------------------------------------------
def _make_kv_morsel(
    keys: List[Int64], values: List[Int64], morsel_id: Int
) raises -> Morsel:
    var n = len(keys)
    if n != len(values):
        raise Error("_make_kv_morsel: keys / values length mismatch")
    var schema = Schema(
        names=[String("key"), String("value")],
        arrow_types=[ArrowType.INT64.type_id, ArrowType.INT64.type_id],
        dtypes=[DType.int64, DType.int64],
        nullables=[False, False],
    )
    var k_arr = PrimitiveArray[DType.int64].allocate(n)
    var v_arr = PrimitiveArray[DType.int64].allocate(n)
    for i in range(n):
        k_arr.set(i, keys[i])
        v_arr.set(i, values[i])
    var k_col = Column.from_primitive[DType.int64](k_arr^)
    var v_col = Column.from_primitive[DType.int64](v_arr^)
    return Morsel(
        RecordBatch.from_typed_columns_2(schema^, k_col^, v_col^), morsel_id, 0
    )


# Drive one epoch through the sink: consume one (keys, values) morsel, then the
# 2PC step boundary (pre_commit -> commit, which writes + seals the epoch).
def _write_and_seal_epoch_via_sink(
    mut sink: ShuffleWriteSink[LocalFsConditionalStore],
    keys: List[Int64],
    values: List[Int64],
    step_seq: UInt64,
) raises:
    sink.consume(0, _make_kv_morsel(keys.copy(), values.copy(), Int(step_seq)))
    var step = StepId(step_seq)
    _ = sink.pre_commit(step)
    sink.commit(step)


# Read EVERY partition of an epoch via the source's poll_next ONCE per partition
# (the source advances its cursor per Item) — collect the union of values seen.
# Drives R distinct sources (one per partition) so each reads its own pid.
def _read_epoch_values_all_partitions(
    store: LocalFsConditionalStore,
    sid: Int64,
    epoch: Int64,
    r: Int64,
    n_prod: Int,
) raises -> List[Int64]:
    var producers = List[Int64]()
    for pi in range(n_prod):
        producers.append(Int64(pi))
    var out = List[Int64]()
    for p in range(Int(r)):
        var src = ShuffleReadSource[LocalFsConditionalStore](
            store.clone(),
            sid,
            Int64(p),
            r,
            producers.copy(),
            epoch,  # start at the target epoch
            4,
        )
        var poll = src.poll_next(0)
        assert_true(
            poll.is_item(),
            "partition read of a SEALED epoch returns Item (not Idle/Closed)",
        )
        var morsel = poll.take_item()
        var batch = morsel^.take_batch()
        var nrows = batch.num_rows()
        for ri in range(nrows):
            out.append(Int64(batch.column_value(0, ri)))
        _ = batch^
        _ = src^
    return out^


def _value_in(haystack: List[Int64], needle: Int64) -> Bool:
    for i in range(len(haystack)):
        if haystack[i] == needle:
            return True
    return False


# =============================================================================
# TEST 1 — DATA ROUND-TRIPS per epoch + IDLE-on-unsealed (the load-bearing gate).
#
# Write+seal e0 and e1 through the sink, then read each back through sources:
#   (a) every value the sink consumed for an epoch reappears across the read of
#       that epoch's partitions (the round-trip is correctness-transparent), and
#       e1's values are DISTINCT from e0's (no cross-epoch bleed).
#   (b) THE GATE: a source poll of an UNSEALED epoch e2 (written-but-not-sealed)
#       returns IDLE — not Item (would under-read an open epoch), not Closed
#       (would latch EOF on a live stream). Then sealing e2 makes the next poll
#       an Item. This is the fail-before/pass-after assertion.
# =============================================================================
def test_round_trip_and_idle_on_unsealed() raises:
    print("[test_round_trip_and_idle_on_unsealed] starting...")
    var root = _scratch_root(String("rt"))
    var store = LocalFsConditionalStore(root.copy())
    var sid = Int64(7000)
    var r = Int64(4)

    var sink = ShuffleWriteSink[LocalFsConditionalStore](
        store.clone(), sid, r, Int64(0), 0, 1, Int64(0)
    )

    # ---- epoch e0: keys 10..13, values 100..103. ----
    var e0_keys = List[Int64]()
    var e0_vals = List[Int64]()
    for i in range(4):
        e0_keys.append(Int64(10 + i))
        e0_vals.append(Int64(100 + i))
    _write_and_seal_epoch_via_sink(sink, e0_keys, e0_vals, UInt64(0))
    assert_equal(
        sink.current_epoch(), Int64(1), "sink advanced to epoch 1 after seal e0"
    )

    # ---- epoch e1: keys 20..23, values 200..203 (DISTINCT from e0). ----
    var e1_keys = List[Int64]()
    var e1_vals = List[Int64]()
    for i in range(4):
        e1_keys.append(Int64(20 + i))
        e1_vals.append(Int64(200 + i))
    _write_and_seal_epoch_via_sink(sink, e1_keys, e1_vals, UInt64(1))
    assert_equal(
        sink.current_epoch(), Int64(2), "sink advanced to epoch 2 after seal e1"
    )

    # (a) DATA ROUND-TRIPS per epoch.
    var e0_read = _read_epoch_values_all_partitions(store, sid, Int64(0), r, 1)
    var e1_read = _read_epoch_values_all_partitions(store, sid, Int64(1), r, 1)
    assert_equal(
        len(e0_read), 4, "epoch e0 round-trips all 4 values across partitions"
    )
    assert_equal(
        len(e1_read), 4, "epoch e1 round-trips all 4 values across partitions"
    )
    for i in range(4):
        assert_true(
            _value_in(e0_read, e0_vals[i]),
            "e0 value " + String(e0_vals[i]) + " round-trips",
        )
        assert_true(
            _value_in(e1_read, e1_vals[i]),
            "e1 value " + String(e1_vals[i]) + " round-trips",
        )
        # cross-epoch isolation: e0's values are NOT in e1's read (distinct sets)
        assert_false(
            _value_in(e1_read, e0_vals[i]),
            "e0 value " + String(e0_vals[i]) + " does NOT bleed into e1",
        )

    # ---- epoch e2: WRITE the producer's `.seg` but DO NOT seal (pre_commit only).
    var e2_keys = List[Int64]()
    var e2_vals = List[Int64]()
    for i in range(4):
        e2_keys.append(Int64(30 + i))
        e2_vals.append(Int64(300 + i))
    sink.consume(0, _make_kv_morsel(e2_keys.copy(), e2_vals.copy(), 2))
    _ = sink.pre_commit(StepId(UInt64(2)))  # writes `.seg`, NO seal

    # (b) THE GATE: a source at epoch e2 returns IDLE (e2 is unsealed). Reverts
    # if poll_next mapped the seal-absence raise to Item (under-read of an open
    # epoch) or to Closed (false EOF) instead of Idle.
    var producers = List[Int64]()
    producers.append(Int64(0))
    var src = ShuffleReadSource[LocalFsConditionalStore](
        store.clone(), sid, Int64(0), r, producers.copy(), Int64(2), 3
    )
    var idle_poll = src.poll_next(0)
    assert_false(
        idle_poll.is_item(),
        "poll of UNSEALED epoch e2 is NOT an Item (no under-read of an open"
        " epoch)",
    )
    assert_false(
        idle_poll.is_closed(),
        "poll of UNSEALED epoch e2 is NOT Closed (a live stream is not EOF)",
    )
    assert_true(
        idle_poll.is_idle(),
        "poll of UNSEALED epoch e2 returns IDLE (the per-epoch block-on-absence"
        " gate — the load-bearing fail-before/pass-after assertion)",
    )
    # The cursor did NOT advance on Idle (it re-polls the same epoch).
    assert_equal(
        src.cursor_epoch(),
        Int64(2),
        "cursor stays at e2 on Idle (re-poll the same epoch)",
    )

    # ---- now SEAL e2 -> the same source's next poll is an Item. ----
    sink.commit(StepId(UInt64(2)))
    assert_equal(sink.current_epoch(), Int64(3), "sink advanced past sealed e2")
    var item_poll = src.poll_next(0)
    assert_true(
        item_poll.is_item(),
        "after e2 is SEALED, the source poll returns Item (the withheld seal was"
        " the only thing gating it)",
    )
    assert_equal(
        src.cursor_epoch(),
        Int64(3),
        "cursor advanced past e2 on the Item",
    )
    _ = src^
    _ = sink^
    _ = store^
    _cleanup(root)
    print("[test_round_trip_and_idle_on_unsealed] PASS")


# =============================================================================
# TEST 2 — backlog() reports the epoch-lag (the micro-batch governor input).
#
# Seal epochs e0, e1, e2 (the producer mints 3 sealed epochs ahead). A source
# whose cursor is at e0 must report backlog.outstanding == 3 (e0, e1, e2 sealed,
# none consumed). After consuming e0 (poll_next Item), the cursor is at e1 and
# backlog == 2. A source at the head (cursor == latest_sealed + 1) reports 0.
# =============================================================================
def test_backlog_reports_epoch_lag() raises:
    print("[test_backlog_reports_epoch_lag] starting...")
    var root = _scratch_root(String("backlog"))
    var store = LocalFsConditionalStore(root.copy())
    var sid = Int64(7100)
    var r = Int64(4)

    var sink = ShuffleWriteSink[LocalFsConditionalStore](
        store.clone(), sid, r, Int64(0), 0, 1, Int64(0)
    )
    # Mint 3 sealed epochs e0, e1, e2.
    for e in range(3):
        var keys = List[Int64]()
        var vals = List[Int64]()
        for i in range(4):
            keys.append(Int64(e * 100 + i))
            vals.append(Int64(e * 1000 + i))
        _write_and_seal_epoch_via_sink(sink, keys, vals, UInt64(e))

    var producers = List[Int64]()
    producers.append(Int64(0))
    var src = ShuffleReadSource[LocalFsConditionalStore](
        store.clone(), sid, Int64(0), r, producers.copy(), Int64(0), 3
    )

    # cursor at e0, sealed {e0, e1, e2} -> lag 3.
    var bl0 = src.backlog()
    assert_true(bl0.__bool__(), "shuffle-read source reports a backlog reading")
    assert_equal(
        bl0.value().outstanding,
        Int64(3),
        "backlog at cursor e0 with {e0,e1,e2} sealed == 3 epochs of lag",
    )
    assert_equal(
        bl0.value().budget,
        Int64(1),
        "backlog budget == 1 (one epoch per step is the steady-state target)",
    )

    # Consume e0 -> cursor advances to e1 -> lag 2.
    var p0 = src.poll_next(0)
    assert_true(p0.is_item(), "poll consumes e0")
    var _m0 = p0.take_item()
    _ = _m0^
    var bl1 = src.backlog()
    assert_equal(
        bl1.value().outstanding,
        Int64(2),
        "backlog after consuming e0 (cursor e1) == 2 epochs of lag",
    )

    # A source at the head (cursor past the latest sealed) reports 0.
    var src_head = ShuffleReadSource[LocalFsConditionalStore](
        store.clone(), sid, Int64(0), r, producers.copy(), Int64(3), 3
    )
    var bl_head = src_head.backlog()
    assert_equal(
        bl_head.value().outstanding,
        Int64(0),
        "backlog at the head (cursor e3, nothing sealed >= e3) == 0",
    )
    _ = src_head^
    _ = src^
    _ = sink^
    _ = store^
    _cleanup(root)
    print("[test_backlog_reports_epoch_lag] PASS")


# =============================================================================
# TEST 3 — seek(EpochCursor) replays from a given epoch.
#
# Seal e0, e1. A source consumes e0 then e1 (cursor at e2). seek(EpochCursor(0))
# rewinds to e0 -> the next poll re-reads e0's SAME values (deterministic replay
# over the immutable sealed `.seg`). The position round-trips through bytes
# (current_position -> to_checkpoint_bytes -> from_checkpoint_bytes == identity).
# =============================================================================
def test_seek_replays_from_epoch() raises:
    print("[test_seek_replays_from_epoch] starting...")
    var root = _scratch_root(String("seek"))
    var store = LocalFsConditionalStore(root.copy())
    var sid = Int64(7200)
    var r = Int64(4)

    var sink = ShuffleWriteSink[LocalFsConditionalStore](
        store.clone(), sid, r, Int64(0), 0, 1, Int64(0)
    )
    # e0 values 100..103; e1 values 200..203.
    var e0_keys = List[Int64]()
    var e0_vals = List[Int64]()
    for i in range(4):
        e0_keys.append(Int64(10 + i))
        e0_vals.append(Int64(100 + i))
    _write_and_seal_epoch_via_sink(sink, e0_keys, e0_vals, UInt64(0))
    var e1_keys = List[Int64]()
    var e1_vals = List[Int64]()
    for i in range(4):
        e1_keys.append(Int64(20 + i))
        e1_vals.append(Int64(200 + i))
    _write_and_seal_epoch_via_sink(sink, e1_keys, e1_vals, UInt64(1))

    var producers = List[Int64]()
    producers.append(Int64(0))
    var src = ShuffleReadSource[LocalFsConditionalStore](
        store.clone(), sid, Int64(0), r, producers.copy(), Int64(0), 4
    )

    # Consume e0 then e1 (cursor advances to e2). Collect e0's first-read values.
    var first_read = List[Int64]()
    var p0 = src.poll_next(0)
    assert_true(p0.is_item(), "first poll reads e0")
    var m0 = p0.take_item()
    var b0 = m0^.take_batch()
    for ri in range(b0.num_rows()):
        first_read.append(Int64(b0.column_value(0, ri)))
    _ = b0^
    var p1 = src.poll_next(0)
    assert_true(p1.is_item(), "second poll reads e1")
    var m1 = p1.take_item()
    _ = m1^
    assert_equal(src.cursor_epoch(), Int64(2), "cursor at e2 after e0,e1")

    # Position round-trips through bytes (the checkpoint codec identity).
    var pos = src.current_position()
    assert_equal(pos.epoch, Int64(2), "current_position is the cursor epoch")
    var bytes = pos.to_checkpoint_bytes()
    var pos2 = EpochCursor.from_checkpoint_bytes(bytes^)
    assert_equal(
        pos2.epoch, Int64(2), "EpochCursor round-trips through 8 LE bytes"
    )

    # seek back to e0 -> re-read the SAME e0 values (deterministic replay).
    src.seek(EpochCursor(Int64(0)))
    assert_equal(src.cursor_epoch(), Int64(0), "seek rewound the cursor to e0")
    var replay_read = List[Int64]()
    var pr = src.poll_next(0)
    assert_true(pr.is_item(), "post-seek poll re-reads e0")
    var mr = pr.take_item()
    var br = mr^.take_batch()
    for ri in range(br.num_rows()):
        replay_read.append(Int64(br.column_value(0, ri)))
    _ = br^

    # The replay read is byte-identical to the first read of e0 (same sealed
    # `.seg`, immutable -> deterministic replay).
    assert_equal(
        len(replay_read),
        len(first_read),
        "seek replay reads the same row count for e0",
    )
    for i in range(len(first_read)):
        assert_true(
            _value_in(replay_read, first_read[i]),
            "seek replay re-reads e0 value " + String(first_read[i]),
        )
    _ = src^
    _ = sink^
    _ = store^
    _cleanup(root)
    print("[test_seek_replays_from_epoch] PASS")


def main() raises:
    test_round_trip_and_idle_on_unsealed()
    test_backlog_reports_epoch_lag()
    test_seek_replays_from_epoch()
    print(
        "[test_shuffle_streaming_conformers] all conformer round-trip / idle /"
        " backlog / seek tests PASS"
    )
