"""The parts of `join_payload_narrow_exec` the narrow and widen round trips do
not reach: the plan's witness line and copy, the tile size, the two kernels'
refusal of a width they do not handle, the range check's lower bound at every
width and on the forked arm, an admitted column over an empty build batch, and
each operand of the serial-or-fork decision taken on its own.
"""

from std.memory import Pointer
from std.testing import assert_equal, assert_false, assert_raises, assert_true

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.runtime import PLACEMENT_FIXED, PerCoreAsyncRuntime

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, SchemaBuilder
from komira_buffer.heap_region import HeapRegion
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_plan_expr.payload_narrow import PayloadNarrowSpec

from komira_dispatch_join_kernels.join_payload_narrow_exec import (
    PN_ADMIT,
    PN_BAD_WIDTH,
    PNL_ADMIT,
    PNL_NO_COLUMN,
    PNL_RANGE_VIOLATION,
    _PN_MIN_PARALLEL_ROWS,
    PayloadWidenPlan,
    _PN_MIN_TILE_ROWS,
    _pn_narrow_range,
    _pn_widen_range,
    _tile_rows,
    narrow_build_batch,
)


comptime I64 = DType.int64


def _make_noop_sink() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


def _make_started_runtime(
    n_workers: Int,
) raises -> PerCoreAsyncRuntime[NoopSink]:
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    rt.attach_workers(n_workers, _make_noop_sink, BACKEND_MOCK)
    rt.start()
    return rt^


def _i64_col(rows: Int) raises -> Column[HeapRegion]:
    var arr = PrimitiveArray[I64].allocate(rows)
    for i in range(rows):
        arr.set(i, Int64(100 + i))
    return Column.from_primitive[I64](arr^)


def _batch(rows: Int) raises -> RecordBatch:
    var sb = SchemaBuilder()
    sb.add_field(Field("key", ArrowType.INT64, False))
    sb.add_field(Field("v", ArrowType.INT64, False))
    var b = RecordBatchBuilder.with_capacity(2)
    b.add_column(_i64_col(rows))
    b.add_column(_i64_col(rows))
    return b.build(sb.build())


def _col_of(var v: List[Int64]) raises -> Column[HeapRegion]:
    var arr = PrimitiveArray[I64].allocate(len(v))
    for i in range(len(v)):
        arr.set(i, v[i])
    return Column.from_primitive[I64](arr^)


def _batch_vw(rows: Int) raises -> RecordBatch:
    """A key and two payload columns `v` and `w`, each `100 + row`."""
    var sb = SchemaBuilder()
    sb.add_field(Field("key", ArrowType.INT64, False))
    sb.add_field(Field("v", ArrowType.INT64, False))
    sb.add_field(Field("w", ArrowType.INT64, False))
    var b = RecordBatchBuilder.with_capacity(3)
    b.add_column(_i64_col(rows))
    b.add_column(_i64_col(rows))
    b.add_column(_i64_col(rows))
    return b.build(sb.build())


def _cancelled() -> CancellationToken:
    """A token cancelled before any dispatch: `run_with_state` raises on it
    before it enqueues a task, so a fork taken over it is an error and the
    serial arm, which never dispatches, is not."""
    var t = CancellationToken.new()
    t.cancel(String("the serial arm must not fork"))
    return t^


def test_the_witness_names_the_lever_and_every_column() raises:
    """One line: the tag, the lever code, the widened count, then each named
    column with its code and bytes, in the order they were recorded.
    MUTANT: the per-column loop dropped: the `col=` fields are missing."""
    var plan = PayloadWidenPlan(UInt8(7))
    plan.out_col.append(3)
    plan.src_bytes.append(UInt8(2))
    plan.base.append(Int64(-5))
    plan.col_names.append(String("a"))
    plan.col_codes.append(UInt8(0))
    plan.col_bytes.append(UInt8(2))
    plan.col_names.append(String("b"))
    plan.col_codes.append(UInt8(4))
    plan.col_bytes.append(UInt8(1))
    assert_equal(
        plan.witness(String("t1")),
        String(
            "[paynarrow-exec] t1 lever=7 widened=1"
            " col=a:code=0:bytes=2 col=b:code=4:bytes=1"
        ),
    )
    assert_equal(
        PayloadWidenPlan().witness(String("t2")),
        String("[paynarrow-exec] t2 lever=0 widened=0"),
    )


def test_copy_is_deep_and_keeps_every_field() raises:
    """A copy carries every list and the lever code, and appending to the copy
    leaves the original alone.
    MUTANT: `copy` that leaves `col_bytes` empty."""
    var plan = PayloadWidenPlan(UInt8(3))
    plan.out_col.append(1)
    plan.src_bytes.append(UInt8(4))
    plan.base.append(Int64(9))
    plan.col_names.append(String("x"))
    plan.col_codes.append(UInt8(6))
    plan.col_bytes.append(UInt8(4))
    var c = plan.copy()
    assert_equal(Int(c.lever_code), 3)
    assert_equal(c.out_col[0], 1)
    assert_equal(Int(c.src_bytes[0]), 4)
    assert_equal(c.base[0], Int64(9))
    assert_equal(c.col_names[0], String("x"))
    assert_equal(Int(c.col_codes[0]), 6)
    assert_equal(Int(c.col_bytes[0]), 4)
    c.out_col.append(2)
    assert_equal(plan.num_widened(), 1)
    assert_equal(c.num_widened(), 2)


def test_tile_rows() raises:
    """One worker (or none) takes the whole range as one tile, and an empty
    range one row; a pool takes a quarter-per-worker share, never below the
    tile floor.
    MUTANT: `if want < _PN_MIN_TILE_ROWS` dropped: 100 rows on 4 workers
    tile at 7."""
    assert_equal(_tile_rows(0, 1), 1)
    assert_equal(_tile_rows(0, 0), 1)
    assert_equal(_tile_rows(10, 1), 10)
    assert_equal(_tile_rows(10, 0), 10)
    assert_equal(_tile_rows(100, 4), _PN_MIN_TILE_ROWS)
    assert_equal(_tile_rows(0, 8), _PN_MIN_TILE_ROWS)
    # 524,288 rows over 4 workers x 4 tiles: 32,768 per tile, over the floor.
    assert_equal(_tile_rows(524_288, 4), 32_768)
    # A remainder rounds the tile up, so 16 tiles still cover every row.
    assert_equal(_tile_rows(524_289, 4), 32_769)


def test_the_narrow_kernel_refuses_a_width_it_does_not_write() raises:
    """Widths 3 and 8 are refusals (False) and write nothing.
    MUTANT: the final `return False` changed to `return True`."""
    var src = _i64_col(4)
    for w in range(2):
        var width = UInt8(3) if w == 0 else UInt8(8)
        var dst = OwnedAlignedBuffer(32)
        dst.set_length(Int64(32))
        for i in range(4):
            dst.set_typed[Scalar[I64]](i, Int64(-7))
        assert_false(_pn_narrow_range(src, Int64(0), width, 0, 4, dst))
        for i in range(4):
            assert_equal(dst.get_typed[Scalar[I64]](i), Int64(-7))


def test_the_widen_kernel_raises_on_a_width_it_does_not_read() raises:
    """A source width other than 1, 2 or 4 raises, naming the width.
    MUTANT: the raise replaced by a silent `return`."""
    var src = _i64_col(4)
    var dst = OwnedAlignedBuffer(32)
    dst.set_length(Int64(32))
    with assert_raises(contains="widen asked for source width 8"):
        _pn_widen_range(src, Int64(0), UInt8(8), 0, 4, dst)


def test_an_admitted_column_over_no_rows_narrows_nothing() raises:
    """An empty build batch with a spec the ladder admits (the size floor
    bypassed): nothing to narrow, so the lever reports no column, the plan is
    the identity, and the batch comes back with its INT64 schema. The column
    still shows as admitted in the witness lists.
    MUTANT: `or rows == 0` dropped: the empty column is narrowed to UINT16
    and the plan widens one column."""
    var rt = _make_started_runtime(2)
    ref disp = rt.dispatcher()
    var specs = List[PayloadNarrowSpec]()
    specs.append(PayloadNarrowSpec(String("v"), UInt8(2), Int64(100)))
    var nb = narrow_build_batch(
        _batch(0), specs, 0, PNL_ADMIT, True,
        Pointer(to=disp), CancellationToken.never(), 2,
    )
    var plan = nb.plan.copy()
    var out = nb.take_batch()
    _ = nb^
    rt.shutdown()
    assert_equal(Int(plan.lever_code), Int(PNL_NO_COLUMN))
    assert_equal(plan.num_widened(), 0)
    assert_equal(len(plan.col_codes), 1)
    assert_equal(Int(plan.col_codes[0]), Int(PN_ADMIT))
    assert_equal(out.num_rows(), 0)
    assert_true(out.column_at(1).arrow_type == ArrowType.INT64)
    assert_true(out.schema.field_arrow_type(1) == ArrowType.INT64)


def test_an_eight_byte_spec_is_a_bad_width() raises:
    """A spec asking for 8 bytes is refused as a bad width (the ladder admits
    only 1, 2 and 4), so the not-narrower rung after it never sees one.
    MUTANT: `sp.target_bytes != PAYLOAD_NARROW_4B` dropped from the width
    test: a 4-byte spec is refused too (the round-trip tests go red)."""
    var rt = _make_started_runtime(2)
    ref disp = rt.dispatcher()
    var specs = List[PayloadNarrowSpec]()
    specs.append(PayloadNarrowSpec(String("v"), UInt8(8), Int64(0)))
    var nb = narrow_build_batch(
        _batch(16), specs, 0, PNL_ADMIT, True,
        Pointer(to=disp), CancellationToken.never(), 2,
    )
    var plan = nb.plan.copy()
    _ = nb^
    rt.shutdown()
    assert_equal(Int(plan.lever_code), Int(PNL_NO_COLUMN))
    assert_equal(Int(plan.col_codes[0]), Int(PN_BAD_WIDTH))
    assert_equal(Int(plan.col_bytes[0]), 8)


def test_the_narrow_kernel_refuses_a_value_below_its_base() raises:
    """At each width a value one below `base` is a violation (False), and the
    same rows without it narrow (True) to `v - base`.
    MUTANT: `delta < 0 or` dropped from the range check (planted at all three
    widths at once): -1 wraps to the width's maximum and the kernel returns
    True, so each width's assertion goes red on its own."""
    var widths = List[UInt8]()
    widths.append(UInt8(1))
    widths.append(UInt8(2))
    widths.append(UInt8(4))
    for wi in range(3):
        var w = widths[wi]
        var tag = String("width ") + String(Int(w))
        var bad = List[Int64]()
        bad.append(Int64(1000))
        bad.append(Int64(1001))
        bad.append(Int64(999))
        bad.append(Int64(1002))
        var dst = OwnedAlignedBuffer(4 * Int(w))
        dst.set_length(Int64(4 * Int(w)))
        assert_false(
            _pn_narrow_range(_col_of(bad^), Int64(1000), w, 0, 4, dst),
            tag + ": a value below the base must be a violation",
        )
        var good = List[Int64]()
        good.append(Int64(1000))
        good.append(Int64(1001))
        good.append(Int64(1003))
        good.append(Int64(1002))
        var dst2 = OwnedAlignedBuffer(4 * Int(w))
        dst2.set_length(Int64(4 * Int(w)))
        assert_true(
            _pn_narrow_range(_col_of(good^), Int64(1000), w, 0, 4, dst2),
            tag + ": values at and above the base narrow",
        )
        var stored: Int
        if w == UInt8(1):
            stored = Int(dst2.get_typed[Scalar[DType.uint8]](2))
        elif w == UInt8(2):
            stored = Int(dst2.get_typed[Scalar[DType.uint16]](2))
        else:
            stored = Int(dst2.get_typed[Scalar[DType.uint32]](2))
        assert_equal(stored, 3, tag + ": stored v - base")


def test_a_value_below_the_base_on_the_forked_arm_discards_the_narrowing() raises:
    """Above the fork threshold, one row one below the base in a middle tile
    is a range violation: nothing is widened and the column comes back INT64
    with its value.
    MUTANT: `delta < 0 or` dropped from the 2-byte range check: the lever
    reports ADMIT and the column comes back UINT16."""
    var rows = 131_072
    var bad_row = rows // 2 + 7
    var v = List[Int64]()
    for i in range(rows):
        v.append(Int64(1000 + (i % 50_000)))
    v[bad_row] = Int64(999)
    var sb = SchemaBuilder()
    sb.add_field(Field("key", ArrowType.INT64, False))
    sb.add_field(Field("v", ArrowType.INT64, False))
    var b = RecordBatchBuilder.with_capacity(2)
    b.add_column(_i64_col(rows))
    b.add_column(_col_of(v^))
    var specs = List[PayloadNarrowSpec]()
    specs.append(PayloadNarrowSpec(String("v"), UInt8(2), Int64(1000)))
    var rt = _make_started_runtime(4)
    ref disp = rt.dispatcher()
    var nb = narrow_build_batch(
        b.build(sb.build()), specs, 0, PNL_ADMIT, True,
        Pointer(to=disp), CancellationToken.never(), 4,
    )
    var plan = nb.plan.copy()
    var out = nb.take_batch()
    _ = nb^
    rt.shutdown()
    assert_equal(Int(plan.lever_code), Int(PNL_RANGE_VIOLATION))
    assert_equal(plan.num_widened(), 0)
    assert_true(out.column_at(1).arrow_type == ArrowType.INT64)
    var pc = out.column_at(1).as_primitive[I64]()
    assert_equal(pc.get(bad_row), Int64(999))
    assert_equal(pc.get(0), Int64(1000))


def _narrow_two_serially(rows: Int, num_workers: Int) raises:
    """Two admitted 2-byte columns over a cancelled token. Only the serial
    arm can succeed, so a narrowed result proves the fork was not taken."""
    var specs = List[PayloadNarrowSpec]()
    specs.append(PayloadNarrowSpec(String("v"), UInt8(2), Int64(100)))
    specs.append(PayloadNarrowSpec(String("w"), UInt8(2), Int64(100)))
    var rt = _make_started_runtime(num_workers)
    ref disp = rt.dispatcher()
    var nb = narrow_build_batch(
        _batch_vw(rows), specs, 0, PNL_ADMIT, True,
        Pointer(to=disp), _cancelled(), num_workers,
    )
    var plan = nb.plan.copy()
    var out = nb.take_batch()
    _ = nb^
    rt.shutdown()
    assert_equal(Int(plan.lever_code), Int(PNL_ADMIT))
    assert_equal(plan.num_widened(), 2)
    assert_true(out.column_at(1).arrow_type == ArrowType.UINT16)
    assert_true(out.column_at(2).arrow_type == ArrowType.UINT16)
    assert_equal(
        Int(out.column_at(2)._data.get_typed[Scalar[DType.uint16]](rows - 1)),
        rows - 1,
    )


def test_one_worker_narrows_serially_above_the_fork_threshold() raises:
    """`num_workers` 1 over 65,536 rows: the row test alone would fork (two
    columns, two tasks), so only `num_workers < 2` keeps the arm serial.
    MUTANT: `num_workers < 2 or` dropped: the fork runs over the cancelled
    token and raises."""
    _narrow_two_serially(_PN_MIN_PARALLEL_ROWS, 1)


def test_few_rows_narrow_serially_on_a_pool() raises:
    """1,000 rows on four workers: one tile per column, two tasks, so only
    `rows < _PN_MIN_PARALLEL_ROWS` keeps the arm serial.
    MUTANT: `rows < _PN_MIN_PARALLEL_ROWS or` dropped: the fork runs over the
    cancelled token and raises."""
    _narrow_two_serially(1000, 4)


def main() raises:
    test_the_witness_names_the_lever_and_every_column()
    test_copy_is_deep_and_keeps_every_field()
    test_tile_rows()
    test_the_narrow_kernel_refuses_a_width_it_does_not_write()
    test_the_widen_kernel_raises_on_a_width_it_does_not_read()
    test_an_admitted_column_over_no_rows_narrows_nothing()
    test_an_eight_byte_spec_is_a_bad_width()
    test_the_narrow_kernel_refuses_a_value_below_its_base()
    test_a_value_below_the_base_on_the_forked_arm_discards_the_narrowing()
    test_one_worker_narrows_serially_above_the_fork_threshold()
    test_few_rows_narrow_serially_on_a_pool()
    print("All 11 narrow edge tests passed.")
