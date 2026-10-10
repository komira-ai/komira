# =============================================================================
# tests/test_shuffle_streaming_direct.mojo
#   Direct tests for every branch of komira_shuffle_streaming the conformer
#   round-trip test does not reach: the codec's truncation raise, the sink's
#   abort / restore / empty-step commit / observability, and the source's
#   Closed state, error propagation, constructor clamps, backlog probe cap,
#   capabilities and EpochCursor codec.
# =============================================================================
#
# Each test names the defect it catches. Single-process LocalFs scratch root
# under the runner's TEST_TMPDIR, no network, no threads.
# =============================================================================

from std.time import perf_counter_ns

from std.testing import assert_equal, assert_false, assert_raises, assert_true

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
from komira_morsel.streaming_sink import CommitToken, StepId

from komira_shuffle_streaming.shuffle_streaming_codec import (
    decode_value_payload,
    encode_key_bytes,
    encode_value_payload,
)
from komira_shuffle_streaming.shuffle_streaming_sink import ShuffleWriteSink
from komira_shuffle_streaming.shuffle_streaming_source import (
    EpochCursor,
    ShuffleReadSource,
)
from komira_runtime_paths import test_tmpdir


comptime _Store = LocalFsConditionalStore
comptime _R = Int64(4)


def _scratch_root(tag: String) raises -> String:
    var t = UInt64(perf_counter_ns())
    return (
        test_tmpdir() + String("/komira_shuffle_direct_") + tag + String("_")
        + String(t)
    )


def _cleanup(root: String):
    try:
        var store = LocalFsConditionalStore(root.copy())
        var res = store.list_with_delimiter(Path.parse(String("")))
        for i in range(len(res.objects)):
            store.delete(Path.parse(res.objects[i].location))
        _ = store^
    except:
        pass


def _kv_morsel(base: Int, n: Int) raises -> Morsel:
    """`n` rows: key = base + i, value = 10 * (base + i)."""
    var schema = Schema(
        names=[String("key"), String("value")],
        arrow_types=[ArrowType.INT64.type_id, ArrowType.INT64.type_id],
        dtypes=[DType.int64, DType.int64],
        nullables=[False, False],
    )
    var k_arr = PrimitiveArray[DType.int64].allocate(n)
    var v_arr = PrimitiveArray[DType.int64].allocate(n)
    for i in range(n):
        k_arr.set(i, Int64(base + i))
        v_arr.set(i, Int64(10 * (base + i)))
    var k_col = Column.from_primitive[DType.int64](k_arr^)
    var v_col = Column.from_primitive[DType.int64](v_arr^)
    return Morsel(
        RecordBatch.from_typed_columns_2(schema^, k_col^, v_col^), base, 0
    )


def _one_producer() -> List[Int64]:
    var p = List[Int64]()
    p.append(Int64(0))
    return p^


def _seal_epochs(mut sink: ShuffleWriteSink[_Store], count: Int) raises:
    """Write and seal `count` epochs of 4 rows each through the 2PC path."""
    for e in range(count):
        var seq = UInt64(Int(sink.current_epoch()))
        sink.consume(0, _kv_morsel(100 * (e + 1), 4))
        _ = sink.pre_commit(StepId(seq))
        sink.commit(StepId(seq))


def _rows_in_epoch(store: _Store, sid: Int64, epoch: Int64) raises -> Int:
    """Total rows across every partition of a sealed epoch."""
    var total = 0
    for p in range(Int(_R)):
        var src = ShuffleReadSource[_Store](
            store.clone(), sid, Int64(p), _R, _one_producer(), epoch, 4
        )
        var poll = src.poll_next(0)
        assert_true(poll.is_item(), "a sealed epoch reads as Item")
        var m = poll.take_item()
        total += m^.take_batch().num_rows()
        _ = src^
    return total


# -----------------------------------------------------------------------------
# Codec. Catches: a byte-order swap, a sign-losing conversion, and a truncation
# check that accepts a short payload (or rejects a full one).
# -----------------------------------------------------------------------------
def test_codec_le_bytes_and_truncation() raises:
    var k = encode_key_bytes(Int64(0x0102030405060708))
    assert_equal(len(k), 8, "a key encodes to 8 bytes")
    for i in range(8):
        assert_equal(Int(k[i]), 8 - i, "key bytes are little-endian")
    var neg = encode_value_payload(Int64(-2))
    assert_equal(Int(neg[0]), 0xFE, "-2 low byte is 0xFE (two's complement)")
    assert_equal(Int(neg[7]), 0xFF, "-2 high byte is 0xFF")

    var values = List[Int64]()
    values.append(Int64(0))
    values.append(Int64(-1))
    values.append(Int64(9223372036854775807))
    values.append(Int64(-9223372036854775807) - Int64(1))
    for i in range(len(values)):
        assert_equal(
            decode_value_payload(encode_value_payload(values[i])),
            values[i],
            "value round-trips through the payload codec",
        )

    var short = encode_value_payload(Int64(5))
    _ = short.pop()
    with assert_raises(contains="payload too short"):
        _ = decode_value_payload(short)
    # Extra trailing bytes are ignored: only the first 8 are read.
    var longer = encode_value_payload(Int64(77))
    longer.append(UInt8(0xAA))
    assert_equal(decode_value_payload(longer), Int64(77), "first 8 bytes decode")


# -----------------------------------------------------------------------------
# Sink observability, defaults, and the empty morsel. Catches: a constructor
# that ignores `start_epoch` or `shuffle_id`, a consume that buffers rows of an
# empty morsel, and a sink class other than transactional.
# -----------------------------------------------------------------------------
def test_sink_observability_and_class() raises:
    var root = _scratch_root(String("obs"))
    var store = LocalFsConditionalStore(root.copy())
    var sink = ShuffleWriteSink[_Store](store.clone(), Int64(8100), _R)
    assert_equal(sink.shuffle_id(), Int64(8100), "shuffle_id is kept")
    assert_equal(sink.current_epoch(), Int64(0), "default start epoch is 0")
    assert_equal(sink.buffered_rows(), 0, "a new sink buffers nothing")
    var cls = sink.sink_class()
    assert_true(cls.is_transactional(), "the sink is transactional (2PC)")
    assert_true(cls.qualifies_for_exactly_once(), "and qualifies for EO")

    var sink5 = ShuffleWriteSink[_Store](
        store.clone(), Int64(8101), _R, Int64(0), 0, 1, Int64(5)
    )
    assert_equal(sink5.current_epoch(), Int64(5), "start_epoch is the epoch")
    sink5.consume(0, _kv_morsel(1, 3))
    assert_equal(sink5.buffered_rows(), 3, "consume buffers each row")
    sink5.consume(0, _kv_morsel(9, 0))
    assert_equal(sink5.buffered_rows(), 3, "an empty morsel adds no row")
    var tok = sink5.pre_commit(StepId(UInt64(42)))
    assert_equal(tok.step.seq, UInt64(42), "the token carries the step")
    assert_equal(tok.txn_handle, UInt64(5), "the token's handle is the epoch")
    sink5.commit(StepId(UInt64(42)))
    assert_equal(sink5.current_epoch(), Int64(6), "commit advances the epoch")
    assert_equal(sink5.buffered_rows(), 0, "commit clears the buffer")
    assert_equal(_rows_in_epoch(store, Int64(8101), Int64(5)), 3, "e5 holds 3")
    _ = sink5^
    _ = sink^
    _ = store^
    _cleanup(root)


# -----------------------------------------------------------------------------
# abort, then a commit with no pre_commit. Catches: an abort that keeps the
# buffered rows (the epoch would hold 4 rows), an abort that advances the epoch,
# and a commit that skips writing the producer's `.seg` on an empty step (the
# seal would raise for a missing producer).
# -----------------------------------------------------------------------------
def test_sink_abort_then_empty_commit() raises:
    var root = _scratch_root(String("abort"))
    var store = LocalFsConditionalStore(root.copy())
    var sid = Int64(8200)
    var sink = ShuffleWriteSink[_Store](store.clone(), sid, _R)
    sink.consume(0, _kv_morsel(1, 4))
    assert_equal(sink.buffered_rows(), 4, "4 rows buffered")
    sink.abort(StepId(UInt64(0)))
    assert_equal(sink.buffered_rows(), 0, "abort discards the buffer")
    assert_equal(sink.current_epoch(), Int64(0), "abort keeps the epoch")
    # No pre_commit: commit must write the empty `.seg` itself, then seal.
    sink.commit(StepId(UInt64(0)))
    assert_equal(sink.current_epoch(), Int64(1), "the empty step sealed")
    assert_equal(_rows_in_epoch(store, sid, Int64(0)), 0, "e0 is sealed, empty")

    _ = sink^
    _ = store^
    _cleanup(root)


# -----------------------------------------------------------------------------
# restore_from re-drives the token's epoch. Catches: a restore that ignores the
# token (the re-drive would land in epoch 1), one that keeps buffered rows, and
# a re-drive that duplicates rows (the producer and the seal must collapse it).
# -----------------------------------------------------------------------------
def test_sink_restore_from_redrives_epoch() raises:
    var root = _scratch_root(String("restore"))
    var store = LocalFsConditionalStore(root.copy())
    var sid = Int64(8300)
    var sink = ShuffleWriteSink[_Store](store.clone(), sid, _R)
    sink.consume(0, _kv_morsel(1, 4))
    var tok = sink.pre_commit(StepId(UInt64(0)))
    sink.commit(StepId(UInt64(0)))
    assert_equal(sink.current_epoch(), Int64(1), "e0 sealed")

    sink.consume(0, _kv_morsel(50, 2))
    sink.restore_from(tok^)
    assert_equal(sink.current_epoch(), Int64(0), "restore sets the epoch")
    assert_equal(sink.buffered_rows(), 0, "restore clears the buffer")
    # Replay the same delta into the recovered epoch.
    sink.consume(0, _kv_morsel(1, 4))
    _ = sink.pre_commit(StepId(UInt64(0)))
    sink.commit(StepId(UInt64(0)))
    assert_equal(sink.current_epoch(), Int64(1), "the re-drive advances again")
    assert_equal(_rows_in_epoch(store, sid, Int64(0)), 4, "no duplicate rows")

    sink.restore_from(CommitToken(StepId(UInt64(9)), UInt64(7)))
    assert_equal(sink.current_epoch(), Int64(7), "epoch = token.txn_handle")
    _ = sink^
    _ = store^
    _cleanup(root)


# -----------------------------------------------------------------------------
# mark_closed and seek. Catches: a poll that ignores the closed flag, and a
# seek that leaves the source closed (a recovery seek must reopen it).
# -----------------------------------------------------------------------------
def test_source_closed_then_seek_reopens() raises:
    var root = _scratch_root(String("closed"))
    var store = LocalFsConditionalStore(root.copy())
    var sid = Int64(8400)
    var sink = ShuffleWriteSink[_Store](store.clone(), sid, _R)
    _seal_epochs(sink, 1)
    var src = ShuffleReadSource[_Store](
        store.clone(), sid, Int64(0), _R, _one_producer()
    )
    src.mark_closed()
    var p = src.poll_next(0)
    assert_true(p.is_closed(), "a closed source polls Closed")
    assert_false(p.is_idle(), "Closed is not Idle")
    assert_equal(src.cursor_epoch(), Int64(0), "Closed does not advance")
    src.seek(EpochCursor(Int64(0)))
    var q = src.poll_next(0)
    assert_true(q.is_item(), "seek reopens the source; e0 reads as Item")
    _ = src^
    _ = sink^
    _ = store^
    _cleanup(root)


# -----------------------------------------------------------------------------
# Errors that are not seal absence propagate. Catches: a poll or a backlog
# probe that maps every raise to Idle / not-sealed (a torn producer set or a
# bad partition id would then stall the stream silently).
# -----------------------------------------------------------------------------
def test_source_real_errors_propagate() raises:
    var root = _scratch_root(String("errors"))
    var store = LocalFsConditionalStore(root.copy())
    var sid = Int64(8500)
    var sink = ShuffleWriteSink[_Store](store.clone(), sid, _R)
    _seal_epochs(sink, 1)

    var bad_pid = ShuffleReadSource[_Store](
        store.clone(), sid, _R, _R, _one_producer()
    )
    with assert_raises(contains="out of range"):
        _ = bad_pid.poll_next(0)
    assert_equal(bad_pid.cursor_epoch(), Int64(0), "an error does not advance")

    var two = List[Int64]()
    two.append(Int64(0))
    two.append(Int64(1))
    var torn = ShuffleReadSource[_Store](
        store.clone(), sid, Int64(0), _R, two.copy()
    )
    with assert_raises(contains="committed"):
        _ = torn.poll_next(0)
    with assert_raises(contains="committed"):
        _ = torn.backlog()
    _ = torn^
    _ = bad_pid^
    _ = sink^
    _ = store^
    _cleanup(root)


# -----------------------------------------------------------------------------
# Constructor clamps and the backlog probe cap. Catches: a park count of 0
# passed through (a sealed epoch would read as Idle), a probe cap of 0 passed
# through (backlog would read 0 with epochs sealed), and a probe loop that
# ignores its cap.
# -----------------------------------------------------------------------------
def test_source_clamps_and_probe_cap() raises:
    var root = _scratch_root(String("clamp"))
    var store = LocalFsConditionalStore(root.copy())
    var sid = Int64(8600)
    var sink = ShuffleWriteSink[_Store](store.clone(), sid, _R)
    _seal_epochs(sink, 3)

    var zero_park = ShuffleReadSource[_Store](
        store.clone(), sid, Int64(0), _R, _one_producer(), Int64(0), 0
    )
    assert_true(zero_park.poll_next(0).is_item(), "park 0 is clamped to 1")
    var neg_park = ShuffleReadSource[_Store](
        store.clone(), sid, Int64(0), _R, _one_producer(), Int64(0), -3
    )
    assert_true(neg_park.poll_next(0).is_item(), "a negative park is clamped")

    var cap0 = ShuffleReadSource[_Store](
        store.clone(), sid, Int64(0), _R, _one_producer(), Int64(0), 2, 0
    )
    assert_equal(cap0.backlog().value().outstanding, Int64(1), "cap 0 -> 1")
    var cap2 = ShuffleReadSource[_Store](
        store.clone(), sid, Int64(0), _R, _one_producer(), Int64(0), 2, 2
    )
    assert_equal(cap2.backlog().value().outstanding, Int64(2), "cap 2 stops")
    var dflt = ShuffleReadSource[_Store](
        store.clone(), sid, Int64(0), _R, _one_producer()
    )
    assert_equal(dflt.backlog().value().outstanding, Int64(3), "default cap")
    var ahead = ShuffleReadSource[_Store](
        store.clone(), sid, Int64(0), _R, _one_producer(), Int64(9)
    )
    assert_equal(ahead.backlog().value().outstanding, Int64(0), "none ahead")
    _ = ahead^
    _ = dflt^
    _ = cap2^
    _ = cap0^
    _ = neg_park^
    _ = zero_park^
    _ = sink^
    _ = store^
    _cleanup(root)


# -----------------------------------------------------------------------------
# Capabilities, observability, the Item morsel's ids and the EpochCursor codec.
# Catches: a wrong capability bit, a consumer cursor that is not the read
# position (the retention floor would reclaim an unread epoch), a morsel that
# loses its epoch / partition ids, and a byte-order or sign error in the
# checkpoint codec.
# -----------------------------------------------------------------------------
def test_source_caps_observability_and_cursor_codec() raises:
    var root = _scratch_root(String("caps"))
    var store = LocalFsConditionalStore(root.copy())
    var sid = Int64(8700)
    var sink = ShuffleWriteSink[_Store](store.clone(), sid, _R)
    _seal_epochs(sink, 2)

    var pid = Int64(-1)
    for p in range(Int(_R)):
        var probe = ShuffleReadSource[_Store](
            store.clone(), sid, Int64(p), _R, _one_producer(), Int64(1)
        )
        var poll = probe.poll_next(0)
        var m = poll.take_item()
        if m.batch.num_rows() > 0:
            pid = Int64(p)
            assert_equal(m.morsel_id, 1, "the morsel id is the epoch")
            assert_equal(m.partition_id, p, "the morsel carries the pid")
        _ = m^
        _ = probe^
    assert_true(pid >= Int64(0), "some partition of e1 holds rows")

    var src = ShuffleReadSource[_Store](
        store.clone(), sid, Int64(3), _R, _one_producer()
    )
    var caps = src.capabilities()
    assert_true(caps.is_unbounded, "unbounded")
    assert_true(caps.replayable, "replayable")
    assert_false(caps.emits_watermark, "no watermark")
    assert_true(caps.exactly_once_capable, "exactly-once capable")
    assert_equal(src.partition_id(), Int64(3), "partition_id is kept")
    assert_equal(src.consumer_epoch_cursor(), Int64(0), "cursor floor at e0")
    var p0 = src.poll_next(0)
    assert_true(p0.is_item(), "e0 reads")
    assert_equal(src.consumer_epoch_cursor(), Int64(1), "floor follows reads")
    assert_equal(src.current_position().epoch, Int64(1), "position = cursor")

    assert_equal(EpochCursor().epoch, Int64(0), "the default cursor is e0")
    var c = EpochCursor(Int64(0x0102030405060708))
    assert_equal(c.copy().epoch, c.epoch, "copy keeps the epoch")
    var buf = c.to_checkpoint_bytes()
    assert_equal(buf.length(), 8, "the cursor is 8 bytes")
    for i in range(8):
        assert_equal(Int(buf.read_byte()), 8 - i, "cursor bytes are LE")
    var neg = EpochCursor(Int64(-5))
    var back = EpochCursor.from_checkpoint_bytes(neg.to_checkpoint_bytes())
    assert_equal(back.epoch, Int64(-5), "a negative epoch round-trips")
    _ = src^
    _ = sink^
    _ = store^
    _cleanup(root)


def main() raises:
    test_codec_le_bytes_and_truncation()
    test_sink_observability_and_class()
    test_sink_abort_then_empty_commit()
    test_sink_restore_from_redrives_epoch()
    test_source_closed_then_seek_reopens()
    test_source_real_errors_propagate()
    test_source_clamps_and_probe_cap()
    test_source_caps_observability_and_cursor_codec()
    print("[test_shuffle_streaming_direct] PASS")
