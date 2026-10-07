"""The parts of `join_payload_narrow_exec` the narrow and widen round trips do
not reach: the plan's witness line and copy, the tile size, the two kernels'
refusal of a width they do not handle, and an admitted column over an empty
build batch.
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


def main() raises:
    test_the_witness_names_the_lever_and_every_column()
    test_copy_is_deep_and_keeps_every_field()
    test_tile_rows()
    test_the_narrow_kernel_refuses_a_width_it_does_not_write()
    test_the_widen_kernel_raises_on_a_width_it_does_not_read()
    test_an_admitted_column_over_no_rows_narrows_nothing()
    test_an_eight_byte_spec_is_a_bad_width()
    print("All 7 narrow edge tests passed.")
