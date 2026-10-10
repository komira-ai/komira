# =============================================================================
# test_join_payload_widen -- the LEAF-EXIT half of join payload narrowing
# =============================================================================
#
# Split from `test_join_payload_narrow_exec.mojo` for the 1000-line file rule.
# That file owns the NARROW half's admission ladder and its refusal codes;
# this one owns the WIDEN and the one claim shape (A) actually rests on.
#
# ⛔⛔ WHY A VALUE ASSERTION ALONE CANNOT GUARD THIS. Narrow-then-widen is the
# IDENTITY whenever the specs are true, so a lever that never armed and a
# lever that armed and worked produce byte-identical output. Every corpus
# oracle, every `bit_xor` signature and every row count in this repo is blind
# to the difference. So §A asserts the physical SOURCE TYPE it gathered from
# and §C asserts the plan actually narrowed before it measures anything.
#
# ★ §C IS THE DESIGN CLAIM. Shape (A) is recommended over shape (B) because it
# "touches no existing gather kernel": the shipped 1/2/4/8-byte typed arms
# serve a narrowed column unchanged, because each dispatches on the SOURCE
# column's own byte width and copies the SOURCE column's own `arrow_type` onto
# the output. §C gathers through a NARROWED source with the real
# `emit_gather_column_projected`, widens, and compares EVERY element against
# an ABSOLUTE oracle; §C2 compares it row-for-row against the WIDE gather. A
# stride error there is a wrong source row with a correct row count, a correct
# schema and a clean null bitmap.
# =============================================================================

from std.memory import Pointer
from std.testing import TestSuite, assert_equal, assert_true

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.runtime import PLACEMENT_FIXED, PerCoreAsyncRuntime

from komira_arrow.arrow_types import ArrowType
from komira_arrow.bitmap import Bitmap
from komira_arrow.column import Column
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_arrow.table import Table
from komira_join_assembly.compiler_join_assembly import (
    emit_gather_column_projected,
)
from komira_buffer.heap_region import HeapRegion
from komira_plan_expr.payload_narrow import PayloadNarrowSpec

from komira_dispatch_join_kernels.join_payload_narrow_exec import (
    PayloadWidenPlan,
    PNL_ADMIT,
    PNL_GATE_OFF,
    _PN_MIN_PARALLEL_ROWS,
    _tile_rows,
    narrow_build_batch,
)
from komira_dispatch_join_kernels.join_payload_widen import (
    widen_payload_table_parallel,
)


comptime I64 = DType.int64

comptime _PAR_ROWS: Int = 200_000
"""Above `_PN_MIN_PARALLEL_ROWS` (65,536), so the FORK runs. §B asserts that
condition on the constants rather than trusting this note."""


def _make_noop_sink() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


def _make_started_runtime(
    n_workers: Int,
) raises -> PerCoreAsyncRuntime[NoopSink]:
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    rt.attach_workers(n_workers, _make_noop_sink, BACKEND_MOCK)
    rt.start()
    return rt^


def _val2(i: Int) -> Int64:
    """DISTINCT over any window under 60,000 rows and never equal to `i`, so a
    kernel that wrote the row index goes red. Domain `[1000, 60999]`."""
    return Int64(1000 + (i * 37) % 60000)


def _key(i: Int) -> Int64:
    return Int64(7_000_000 + i)


def _i64_col(var v: List[Int64]) raises -> Column[HeapRegion]:
    var arr = PrimitiveArray[I64].allocate(len(v))
    for i in range(len(v)):
        arr.set(i, v[i])
    return Column.from_primitive[I64](arr^)


def _two_payload_batch(rows: Int) raises -> RecordBatch:
    var keys = List[Int64]()
    var sib = List[Int64]()
    for i in range(rows):
        keys.append(_key(i))
        sib.append(_val2(i))
    var sb = SchemaBuilder()
    sb.add_field(Field("key", ArrowType.INT64, False))
    sb.add_field(Field("sib", ArrowType.INT64, False))
    var b = RecordBatchBuilder.with_capacity(2)
    b.add_column(_i64_col(keys^))
    b.add_column(_i64_col(sib^))
    return b.build(sb.build())


def _batch_key_and(
    rows: Int, var payload: Column[HeapRegion], payload_name: String,
    payload_at: ArrowType,
) raises -> RecordBatch:
    var keys = List[Int64]()
    for i in range(rows):
        keys.append(_key(i))
    var sb = SchemaBuilder()
    sb.add_field(Field("key", ArrowType.INT64, False))
    sb.add_field(Field(payload_name, payload_at, False))
    var b = RecordBatchBuilder.with_capacity(2)
    b.add_column(_i64_col(keys^))
    b.add_column(payload^)
    return b.build(sb.build())


def _spec(name: String, tb: UInt8, base: Int64) raises -> PayloadNarrowSpec:
    return PayloadNarrowSpec(name.copy(), tb, base)


def _wide_schema_of(imm b: RecordBatch) raises -> Schema:
    return b.schema.copy()



# =============================================================================
# §E -- the WIDEN over a MULTI-CHUNK table with UNEVEN chunk sizes
# =============================================================================


def test_e_widen_multichunk_uneven() raises:
    """Three chunks of DIFFERENT sizes, widened as one table.

    ⛔ UNEVEN ON PURPOSE. Equal-sized chunks make a rebuild that PERMUTED the
    chunk order indistinguishable from a correct one on every count-based
    check, and the per-element oracle below keys on the GLOBAL row index, so
    equal sizes would let a swap of chunks 0 and 1 still line up. Uneven sizes
    plus a global oracle catch it.

    ⚠ The leaf reaches BOTH shapes in production: segmented output
    returns ~6,511 chunks on a high-cardinality join, and the deferred/concat arms
    return exactly ONE 100M-row chunk. §E covers the many-chunk shape; §A
    covers the one-chunk shape."""
    var sizes = List[Int]()
    sizes.append(3)
    sizes.append(5000)
    sizes.append(1777)
    var total = 0
    for i in range(len(sizes)):
        total += sizes[i]

    var sb_n = SchemaBuilder()
    sb_n.add_field(Field("key", ArrowType.INT64, False))
    sb_n.add_field(Field("v", ArrowType.UINT16, False))
    var sb_w = SchemaBuilder()
    sb_w.add_field(Field("key", ArrowType.INT64, False))
    sb_w.add_field(Field("v", ArrowType.INT64, False))
    var narrow_schema = sb_n.build()
    var wide_schema = sb_w.build()

    var base = Int64(1000)
    var chunks = List[RecordBatch]()
    var g = 0
    for k in range(len(sizes)):
        var n = sizes[k]
        var keys = List[Int64]()
        var buf = OwnedAlignedBuffer(max(n * 2, 1))
        buf.set_length(Int64(n * 2))
        for r in range(n):
            keys.append(_key(g + r))
            buf.set_typed[Scalar[DType.uint16]](
                r, UInt16(_val2(g + r) - base)
            )
        var b = RecordBatchBuilder.with_capacity(2)
        b.add_column(_i64_col(keys^))
        b.add_column(
            Column[HeapRegion](
                arrow_type=ArrowType.UINT16,
                data=buf^,
                offsets=Optional[OwnedAlignedBuffer](None),
                validity=Optional[Bitmap[HeapRegion]](None),
                length=n,
                null_count=0,
                offset=0,
            )
        )
        chunks.append(b.build(narrow_schema.copy()))
        g += n
    var t = Table.from_chunks(chunks^, narrow_schema.copy())

    var plan = PayloadWidenPlan(PNL_ADMIT)
    plan.out_col.append(1)
    plan.src_bytes.append(UInt8(2))
    plan.base.append(base)

    var rt = _make_started_runtime(4)
    ref disp = rt.dispatcher()
    var out = widen_payload_table_parallel(
        t^, plan, wide_schema, Pointer(to=disp),
        CancellationToken.never(), 4,
    )
    assert_equal(out.num_chunks(), len(sizes), "§E chunk count")
    assert_equal(out.num_rows(), total, "§E row count")
    assert_equal(
        Int(out.schema().field_arrow_type(1).type_id),
        Int(ArrowType.INT64.type_id),
        "§E schema type",
    )
    var gg = 0
    for k in range(len(sizes)):
        ref ch = out.chunks()[k]
        assert_equal(
            ch.num_rows(), sizes[k],
            "§E chunk " + String(k) + " CHANGED SIZE -- the chunk boundaries"
            " are the caller's, not ours",
        )
        var vc = ch.column_at(1).as_primitive[I64]()
        var kc = ch.column_at(0).as_primitive[I64]()
        for r in range(sizes[k]):
            assert_equal(
                vc.get(r), _val2(gg + r),
                "§E v[" + String(k) + "][" + String(r) + "]",
            )
            assert_equal(
                kc.get(r), _key(gg + r),
                "§E key[" + String(k) + "][" + String(r) + "]",
            )
        gg += sizes[k]
    _ = out^
    rt.shutdown()


def test_e2_empty_plan_is_the_identity() raises:
    """The arm EVERY declined join takes. It must not fork, must not rebuild
    the schema, and must return the same rows."""
    var batch = _two_payload_batch(64)
    var wide = _wide_schema_of(batch)
    var t = Table.from_batch(batch^)
    var rt = _make_started_runtime(2)
    ref disp = rt.dispatcher()
    var out = widen_payload_table_parallel(
        t^, PayloadWidenPlan(PNL_GATE_OFF), wide, Pointer(to=disp),
        CancellationToken.never(), 2,
    )
    assert_equal(out.num_rows(), 64, "§E2 row count")
    assert_equal(out.num_columns(), 2, "§E2 column count")
    var sc = out.chunks()[0].column_at(1).as_primitive[I64]()
    for i in range(64):
        assert_equal(sc.get(i), _val2(i), "§E2 value[" + String(i) + "]")
    _ = out^
    rt.shutdown()


# =============================================================================
# §F -- the two arms of each dispatch agree, and the grid is NOT vacuous
# =============================================================================


def test_f_serial_and_forked_arms_agree() raises:
    """The same fixture through `num_workers=1` (serial) and `num_workers=8`
    (forked) must produce IDENTICAL stored bytes and identical widened values.

    ⚠ ASSERTED AGAINST AN ABSOLUTE ORACLE ON BOTH ARMS, not against each
    other: two arms that are both wrong the same way agree perfectly."""
    var rows = _PAR_ROWS
    assert_true(
        rows >= _PN_MIN_PARALLEL_ROWS,
        "§F the fixture is below the fork threshold -- the 'forked' arm runs"
        " the serial code and this comparison is vacuous",
    )
    assert_true(
        _tile_rows(rows, 8) < rows,
        "§F the tiling produced ONE tile -- the fork has nothing to spread"
        " and the disjointness contract is untested",
    )

    var vals = List[Int64]()
    for i in range(rows):
        vals.append(_val2(i))

    for wi in range(2):
        var nw = 1 if wi == 0 else 8
        var batch = _batch_key_and(
            rows, _i64_col(vals.copy()), String("v"), ArrowType.INT64
        )
        var wide = _wide_schema_of(batch)
        var specs = List[PayloadNarrowSpec]()
        specs.append(_spec(String("v"), UInt8(2), Int64(1000)))
        var rt = _make_started_runtime(8)
        ref disp = rt.dispatcher()
        var nb = narrow_build_batch(
            batch^, specs, 0, PNL_ADMIT, True,
            Pointer(to=disp), CancellationToken.never(), nw,
        )
        var plan = nb.plan.copy()
        var narrowed = nb.take_batch()
        _ = nb^
        var tag = String("§F nw=") + String(nw)
        assert_equal(plan.num_widened(), 1, tag + " widened count")
        ref nc = narrowed.column_at(1)
        for i in range(rows):
            assert_equal(
                Int(nc._data.get_typed[Scalar[DType.uint16]](i)),
                Int(vals[i] - Int64(1000)),
                tag + " stored[" + String(i) + "]",
            )
        var t = Table.from_batch(narrowed^)
        var out = widen_payload_table_parallel(
            t^, plan, wide, Pointer(to=disp),
            CancellationToken.never(), nw,
        )
        var wc = out.chunks()[0].column_at(1).as_primitive[I64]()
        for i in range(rows):
            assert_equal(wc.get(i), vals[i], tag + " widened[" + String(i) + "]")
        _ = out^
        rt.shutdown()


# =============================================================================
# §G -- ★ THE DESIGN CLAIM: the SHIPPED gather kernel serves a narrowed source
# =============================================================================


def _gather_indices(n: Int, src_rows: Int) raises -> List[Int]:
    """A genuine SCRAMBLE with REPEATS -- a join's fan-out emits a build row
    more than once, and an ascending no-repeat index would let a kernel that
    ignored the index pass."""
    var idx = List[Int]()
    for i in range(n):
        idx.append((i * 7919 + 13) % src_rows)
    return idx^


def test_g_gather_through_a_narrowed_source_then_widen() raises:
    """Shape (A)'s whole argument, tested end to end.

    Gather from the NARROWED build column with the SHIPPED
    `emit_gather_column_projected`, widen the result, and compare EVERY
    element to the same gather over the WIDE column. If the typed 2-byte arm
    read the source at the wrong stride -- a wrong source row with a correct
    row count, correct schema and
    clean null bitmap -- this is where it shows."""
    var src_rows = 4096
    var out_rows = 9000
    var base = Int64(1000)

    var vals = List[Int64]()
    for i in range(src_rows):
        vals.append(_val2(i))
    var batch = _batch_key_and(
        src_rows, _i64_col(vals.copy()), String("v"), ArrowType.INT64
    )
    var wide_batch_schema = _wide_schema_of(batch)

    var specs = List[PayloadNarrowSpec]()
    specs.append(_spec(String("v"), UInt8(2), base))
    var rt = _make_started_runtime(4)
    ref disp = rt.dispatcher()
    var nb = narrow_build_batch(
        batch^, specs, 0, PNL_ADMIT, True,
        Pointer(to=disp), CancellationToken.never(), 4,
    )
    var plan = nb.plan.copy()
    var narrowed = nb.take_batch()
    _ = nb^
    assert_equal(plan.num_widened(), 1, "§G the fixture did not narrow")
    assert_equal(
        Int(narrowed.column_at(1).arrow_type.type_id),
        Int(ArrowType.UINT16.type_id),
        "§G the gather source is not actually narrow",
    )

    var idx = _gather_indices(out_rows, src_rows)

    # Gather column 1 THROUGH the narrow representation, with the shipped
    # kernel and no argument this lever invented.
    var gb = RecordBatchBuilder.with_capacity(1)
    var gsb = SchemaBuilder()
    emit_gather_column_projected(
        narrowed, 1, String("v"), False, idx, out_rows, gb, gsb
    )
    var gathered = gb.build(gsb.build())
    assert_equal(gathered.num_rows(), out_rows, "§G gathered row count")
    assert_equal(
        Int(gathered.column_at(0).arrow_type.type_id),
        Int(ArrowType.UINT16.type_id),
        "§G the gather did NOT carry the source's narrow type through --"
        " shape (A) depends on exactly that",
    )

    # Widen the gathered result.
    var out_wide_sb = SchemaBuilder()
    out_wide_sb.add_field(Field("v", ArrowType.INT64, False))
    var gplan = PayloadWidenPlan(PNL_ADMIT)
    gplan.out_col.append(0)
    gplan.src_bytes.append(UInt8(2))
    gplan.base.append(base)
    var out = widen_payload_table_parallel(
        Table.from_batch(gathered^), gplan, out_wide_sb.build(),
        Pointer(to=disp), CancellationToken.never(), 4,
    )
    var wc = out.chunks()[0].column_at(0).as_primitive[I64]()
    for i in range(out_rows):
        assert_equal(
            wc.get(i),
            vals[idx[i]],
            "§G narrow-gather-widen[" + String(i) + "] != the ABSOLUTE oracle"
            " src[idx[i]]",
        )
    _ = out^
    _ = narrowed^
    _ = wide_batch_schema^
    rt.shutdown()


def test_g2_the_narrow_gather_matches_the_wide_gather_row_for_row() raises:
    """The differential twin of §G: the SAME index over the WIDE source, so a
    fixture that happened to be symmetric under a stride error cannot hide."""
    var src_rows = 4096
    var out_rows = 9000
    var base = Int64(1000)

    var vals = List[Int64]()
    for i in range(src_rows):
        vals.append(_val2(i))
    var idx = _gather_indices(out_rows, src_rows)

    var wide_batch = _batch_key_and(
        src_rows, _i64_col(vals.copy()), String("v"), ArrowType.INT64
    )
    var wb = RecordBatchBuilder.with_capacity(1)
    var wsb = SchemaBuilder()
    emit_gather_column_projected(
        wide_batch, 1, String("v"), False, idx, out_rows, wb, wsb
    )
    var wide_gathered = wb.build(wsb.build())
    var wide_vals = wide_gathered.column_at(0).as_primitive[I64]()

    var narrow_batch = _batch_key_and(
        src_rows, _i64_col(vals.copy()), String("v"), ArrowType.INT64
    )
    var specs = List[PayloadNarrowSpec]()
    specs.append(_spec(String("v"), UInt8(2), base))
    var rt = _make_started_runtime(4)
    ref disp = rt.dispatcher()
    var nb = narrow_build_batch(
        narrow_batch^, specs, 0, PNL_ADMIT, True,
        Pointer(to=disp), CancellationToken.never(), 4,
    )
    var plan = nb.plan.copy()
    var narrowed = nb.take_batch()
    _ = nb^
    var nb2 = RecordBatchBuilder.with_capacity(1)
    var nsb = SchemaBuilder()
    emit_gather_column_projected(
        narrowed, 1, String("v"), False, idx, out_rows, nb2, nsb
    )
    var narrow_gathered = nb2.build(nsb.build())
    var osb = SchemaBuilder()
    osb.add_field(Field("v", ArrowType.INT64, False))
    var gplan = PayloadWidenPlan(PNL_ADMIT)
    gplan.out_col.append(0)
    gplan.src_bytes.append(UInt8(2))
    gplan.base.append(base)
    var out = widen_payload_table_parallel(
        Table.from_batch(narrow_gathered^), gplan, osb.build(),
        Pointer(to=disp), CancellationToken.never(), 4,
    )
    var narrow_widened = out.chunks()[0].column_at(0).as_primitive[I64]()
    for i in range(out_rows):
        assert_equal(
            narrow_widened.get(i),
            wide_vals.get(i),
            "§G2 narrow path != wide path at row " + String(i),
        )
    _ = out^
    _ = wide_gathered^
    _ = narrowed^
    rt.shutdown()



def main() raises:
    var suite = TestSuite()
    suite.test[test_e_widen_multichunk_uneven]()
    suite.test[test_e2_empty_plan_is_the_identity]()
    suite.test[test_f_serial_and_forked_arms_agree]()
    suite.test[test_g_gather_through_a_narrowed_source_then_widen]()
    suite.test[test_g2_the_narrow_gather_matches_the_wide_gather_row_for_row]()
    suite^.run()
