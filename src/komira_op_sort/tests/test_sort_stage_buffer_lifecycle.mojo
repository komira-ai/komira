# =============================================================================
# SortBuffer lifecycle: a failed restore changes nothing, discard releases the
# chunks, NULL input is refused, combine order, bookkeeping values
# =============================================================================
#
# A one-key buffer (INT16 key, so the drain takes the merge sort over the
# `order` permutation) with an INT64 row-id payload. The id makes the order of
# rows that tie on the key visible.
# =============================================================================

from std.ffi import external_call
from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.batch_view import BatchView
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import (
    Field,
    RecordBatch,
    RecordBatchBuilder,
    SchemaBuilder,
)
from komira_arrow.string_array import StringArray
from komira_engine_runtime.spill.local_disk import LocalDiskSpillStorage
from komira_libc.posix import _read_env
from komira_op_sort.sort_stage import Stage_Sort
from komira_op_sort.sort_stage_buffer import SortBuffer, SortKeyBlock
from komira_op_sort.sort_stage_columns import SortKeyColumn_Typed
from komira_op_sort.sort_stage_payloads import PayloadCol_Typed
from komira_op_sort.sort_stage_string_key import SortKeyColumn_String

comptime _K = SortKeyColumn_Typed[DType.int16, 0]
comptime _KB = SortKeyBlock[_K]
comptime _P = PayloadCol_Typed[DType.int64, 1]
comptime _Buf = SortBuffer[_KB, _P]


def _root(tag: String) raises -> String:
    var d = _read_env("TEST_TMPDIR")
    if d.byte_length() == 0:
        d = _read_env("TMPDIR")
    if d.byte_length() == 0:
        raise Error("neither TEST_TMPDIR nor TMPDIR is set")
    var pid = external_call["getpid", Int32]()
    return d + String("/spill-life-") + String(Int(pid)) + String("-") + tag


def _batch(keys: List[Int16], first_id: Int) raises -> RecordBatch:
    var ids = List[Int64]()
    for i in range(len(keys)):
        ids.append(Int64(first_id + i))
    var sb = SchemaBuilder()
    sb.add_field(Field("k", DType.int16, True))
    sb.add_field(Field("id", DType.int64, True))
    var rbb = RecordBatchBuilder.with_capacity(2)
    rbb.add_column(
        Column.from_primitive[DType.int16](PrimitiveArray[DType.int16].from_list(keys))
    )
    rbb.add_column(
        Column.from_primitive[DType.int64](PrimitiveArray[DType.int64].from_list(ids^))
    )
    return rbb.build(sb.build())


def _feed(mut buf: _Buf, batch: RecordBatch) raises:
    var bv = BatchView(batch)
    for r in range(bv.n_rows()):
        buf.feed_row[origin_of(batch)](bv, r)


def _drained_ids(buf: _Buf) raises -> List[Int]:
    var out = buf.drain_to_record_batch()
    var rb = out.take()
    var bv = BatchView(rb)
    var ids = List[Int]()
    for i in range(bv.n_rows()):
        ids.append(Int(bv.col_scalar_nonraising[DType.int64](1, i)))
    return ids^


def _assert_ids(got: List[Int], want: List[Int], what: String) raises:
    assert_equal(len(got), len(want), what + ": row count")
    for i in range(len(want)):
        assert_equal(got[i], want[i], what + ": id at " + String(i))


# =============================================================================
# Failed restore
# =============================================================================


def test_failed_restore_leaves_buffer_unchanged_and_retryable() raises:
    var storage = LocalDiskSpillStorage.with_unlimited(_root("failed"))
    var buf = _Buf.make_empty(8)
    _feed(buf, _batch([2, 1, 2], 0))
    _ = buf.spill_to_storage(storage)
    _feed(buf, _batch([1, 2, 1], 3))
    _ = buf.spill_to_storage(storage)
    _feed(buf, _batch([2, 1], 6))
    var chunks = buf.spilled_chunk_ids()
    assert_equal(len(chunks), 2, "two chunks outstanding")

    # The second chunk disappears behind the buffer's back.
    storage.release_chunk(chunks[1])

    var raised = False
    try:
        buf.restore_from_storage(storage)
    except:
        raised = True
    assert_true(raised, "restore of a missing chunk raises")
    assert_equal(buf.size(), 2, "no partial append from the first chunk")
    assert_true(buf.can_spill(), "failed restore clears the restoring state")
    var after = buf.spilled_chunk_ids()
    assert_equal(len(after), 2, "chunk list unchanged")
    assert_true(after[0] == chunks[0] and after[1] == chunks[1], "same ids")
    assert_equal(storage.num_live_chunks(), 1, "first chunk still on disk")

    var raised_again = False
    try:
        buf.restore_from_storage(storage)
    except:
        raised_again = True
    assert_true(raised_again, "retry raises while the chunk is missing")
    assert_equal(buf.size(), 2, "retry left the buffer unchanged")

    # Discard releases what is left; the resident rows stay and sort.
    buf.discard_spilled(storage)
    assert_equal(len(buf.spilled_chunk_ids()), 0, "chunk list empty")
    assert_equal(storage.num_live_chunks(), 0, "chunks released")
    assert_equal(buf.size(), 2, "resident rows kept")
    _assert_ids(_drained_ids(buf), [7, 6], "resident rows")
    storage.cleanup()


def test_discard_releases_outstanding_chunks() raises:
    var storage = LocalDiskSpillStorage.with_unlimited(_root("discard"))
    var buf = _Buf.make_empty(8)
    _feed(buf, _batch([3, 1], 0))
    _ = buf.spill_to_storage(storage)
    _feed(buf, _batch([2], 2))
    _ = buf.spill_to_storage(storage)
    assert_equal(storage.num_live_chunks(), 2, "two chunks live")
    buf.discard_spilled(storage)
    assert_equal(storage.num_live_chunks(), 0, "discard released both")
    assert_equal(len(buf.spilled_chunk_ids()), 0, "ledger empty")
    # Nothing left to restore: a restore is a no-op and the buffer is empty.
    buf.restore_from_storage(storage)
    assert_equal(buf.size(), 0, "discarded rows are gone")
    storage.cleanup()


# =============================================================================
# NULL input
# =============================================================================


def _expect_refusal(mut buf: _Buf, batch: RecordBatch, reason: String) raises:
    var bv = BatchView(batch)
    var msg = String("")
    try:
        buf.feed_row[origin_of(batch)](bv, 0)
    except e:
        msg = String(e)
    assert_true(
        reason in msg, "refusal names the column; got: '" + msg + "'"
    )
    assert_equal(buf.size(), 0, "refused row leaves the buffer empty")


def test_null_sort_key_is_refused() raises:
    var keys = PrimitiveArray[DType.int16].allocate_nullable(2)
    keys.set(0, 5)
    keys.set(1, 6)
    keys._set_null(0)
    var ids = PrimitiveArray[DType.int64].from_list([Int64(0), Int64(1)])
    var sb = SchemaBuilder()
    sb.add_field(Field("k", DType.int16, True))
    sb.add_field(Field("id", DType.int64, True))
    var rbb = RecordBatchBuilder.with_capacity(2)
    rbb.add_column(Column.from_primitive[DType.int16](keys^))
    rbb.add_column(Column.from_primitive[DType.int64](ids^))
    var batch = rbb.build(sb.build())
    var buf = _Buf.make_empty(4)
    _expect_refusal(buf, batch, "NULL in sort key k0")
    # The valid row of the same batch is accepted afterwards.
    var bv = BatchView(batch)
    buf.feed_row[origin_of(batch)](bv, 1)
    assert_equal(buf.size(), 1, "a valid row is fed after a refusal")


def test_null_payload_is_refused() raises:
    var ids = PrimitiveArray[DType.int64].allocate_nullable(1)
    ids.set(0, 9)
    ids._set_null(0)
    var keys = PrimitiveArray[DType.int16].from_list([Int16(1)])
    var sb = SchemaBuilder()
    sb.add_field(Field("k", DType.int16, True))
    sb.add_field(Field("id", DType.int64, True))
    var rbb = RecordBatchBuilder.with_capacity(2)
    rbb.add_column(Column.from_primitive[DType.int16](keys^))
    rbb.add_column(Column.from_primitive[DType.int64](ids^))
    var batch = rbb.build(sb.build())
    var buf = _Buf.make_empty(4)
    _expect_refusal(buf, batch, "NULL in payload p0")


def test_null_string_key_through_stage_sort_is_refused() raises:
    comptime KS = SortKeyBlock[SortKeyColumn_String[0]]
    comptime PS = PayloadCol_Typed[DType.int64, 1]
    var sa = StringArray.from_strings_with_validity(
        ["b", "", "a"], [True, False, True]
    )
    var ids = PrimitiveArray[DType.int64].from_list(
        [Int64(0), Int64(1), Int64(2)]
    )
    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.STRING, True))
    sb.add_field(Field("id", DType.int64, True))
    var rbb = RecordBatchBuilder.with_capacity(2)
    rbb.add_column(Column.from_string(sa^))
    rbb.add_column(Column.from_primitive[DType.int64](ids^))
    var batch = rbb.build(sb.build())

    var osb = SchemaBuilder()
    osb.add_field(Field("k0", ArrowType.STRING, True))
    osb.add_field(Field("p0", DType.int64, True))
    var stage = Stage_Sort[KS, PS](
        SortBuffer[KS, PS].make_empty(4), osb.build()
    )
    var bv = BatchView(batch)
    var msg = String("")
    try:
        _ = stage.process_batch(bv)
    except e:
        msg = String(e)
    assert_true("NULL in sort key k0" in msg, "got: '" + msg + "'")
    # Rows before the null row were accepted; the null row and after were not.
    assert_equal(stage.buffer.size(), 1, "rows before the NULL are buffered")


# =============================================================================
# combine, bookkeeping
# =============================================================================


def test_combine_appends_other_after_self_in_order() raises:
    var a = _Buf.make_empty(4)
    _feed(a, _batch([2, 1, 2], 0))
    var b = _Buf.make_empty(4)
    _feed(b, _batch([1, 2, 1], 3))
    a.combine(b^)
    assert_equal(a.size(), 6, "combined size")
    # The merge sort over `order` (INT16 key): ties keep self-then-other order.
    _assert_ids(_drained_ids(a), [1, 3, 5, 0, 2, 4], "combined drain")
    var order = a.sorted_order()
    var want: List[Int] = [1, 3, 5, 0, 2, 4]
    _assert_ids(order, want, "combined sorted_order")


def test_combine_bumps_age_ticks() raises:
    var a = _Buf.make_empty(4)
    _feed(a, _batch([2, 1], 0))
    var before = a.age_ticks()
    assert_equal(before, UInt64(2), "feed bumps once per row")
    var b = _Buf.make_empty(4)
    _feed(b, _batch([1, 2, 1], 2))
    a.combine(b^)
    assert_equal(a.age_ticks(), before + UInt64(3), "combine bumps per row")


def test_memory_usage_bytes_is_the_documented_estimate() raises:
    var buf = _Buf.make_empty(4)
    assert_equal(buf.memory_usage_bytes(), Int64(0), "empty")
    _feed(buf, _batch([2, 1, 2], 0))
    # Per row: 2 columns (one key, one payload) at 8 bytes, plus the Int index.
    assert_equal(buf.memory_usage_bytes(), Int64(3 * (2 * 8 + 8)), "3 rows")


def test_can_spill_across_states() raises:
    var storage = LocalDiskSpillStorage.with_unlimited(_root("canspill"))
    var buf = _Buf.make_empty(4)
    assert_true(buf.can_spill(), "fresh")
    _feed(buf, _batch([1], 0))
    _ = buf.spill_to_storage(storage)
    assert_true(buf.can_spill(), "after a spill")
    buf.restore_from_storage(storage)
    assert_true(buf.can_spill(), "after a restore")
    storage.cleanup()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
