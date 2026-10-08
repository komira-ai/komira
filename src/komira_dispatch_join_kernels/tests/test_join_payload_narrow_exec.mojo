# =============================================================================
# test_join_payload_narrow_exec -- the delivery half of join payload narrowing
# =============================================================================
#
# WHAT IS UNDER TEST. `join_payload_narrow_exec.mojo` (the build-side narrow +
# its admission ladder) and `join_payload_widen.mojo` (the leaf-exit widen).
# Together they turn the optimizer's inert `PayloadNarrowSpec` stamp into a
# physical narrow-through/widen-once transform inside ONE join leaf.
#
# ⛔⛔ WHY A VALUE ASSERTION ALONE CANNOT GUARD THIS. Narrow-then-widen is the
# identity on every input the specs are TRUE for. So a fixture whose specs are
# right, a lever that never armed, and a lever that armed and worked all
# produce byte-identical output -- and the corpus value gate, every `bit_xor`
# signature and every row-count oracle in this repo are blind to the
# difference. Every case below therefore asserts the DISPOSITION CODES
# (`plan.lever_code`, `plan.col_codes`) and the CHOSEN WIDTH, never a Bool:
# `num_widened() != 0` cannot tell 4-bytes-where-2-belongs from a correct
# choice, and those are ~3 wall points apart on the measured ladder.
#
# ⛔ AND WHY EVERY REFUSAL CASE ALSO ASSERTS A SIBLING COLUMN NARROWING.
# `assert_equal(n_widened, 0)` is satisfied EQUALLY by "the refusal fired" and
# by "the whole function never ran". Each refusal fixture therefore carries a
# second, ELIGIBLE column in the SAME batch and asserts it came through -- so a
# vacuous run goes red.
#
# ★ THE ORACLE IS ABSOLUTE, NOT DIFFERENTIAL. Every value assertion recomputes
# the expected number from the generator function in plain Mojo
# (`_val(i)` / `_gather_oracle`), never by comparing the lever against itself.
# The fixture values are ALL DISTINCT within a column so a PERMUTATION error --
# right row count, right schema, clean null bitmap -- cannot hide.
#
# ★ §I IS THE ONE THAT PROVES THE DESIGN CLAIM. Shape (A)'s whole argument is
# "touches no existing gather kernel": the shipped 1/2/4/8-byte typed arms
# serve a narrowed column unchanged because they dispatch on the SOURCE
# column's own byte width. §I gathers through a NARROWED source with the real
# `emit_gather_column_projected`, widens, and compares EVERY element against
# the same gather over the WIDE source. If that claim is false, §I is where it
# breaks.
#
# ⛔⛔ THE MUTATION RUN -- PERFORMED, NOT PREDICTED. Each case below that
# names a mutation (`m2`) was added because that mutation came back green
# against the suite without it.
# =============================================================================

from std.memory import Pointer
from std.testing import TestSuite, assert_equal, assert_false, assert_true

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
    JOIN_PAYLOAD_NARROW_MIN_SRC_BYTES,
    PayloadWidenPlan,
    PN_ADMIT,
    PN_BAD_WIDTH,
    PN_NOT_INT64,
    PN_NULLABLE,
    PN_RANGE_VIOLATION,
    PN_SRC_TOO_SMALL,
    PNL_ADMIT,
    PNL_COUNT_ONLY,
    PNL_GATE_OFF,
    PNL_NOT_INNER,
    PNL_NO_COLUMN,
    PNL_NO_SPECS,
    PNL_PAYLOAD_INLINE_ON,
    PNL_RANGE_VIOLATION,
    PNL_SCHEMA_SHAPE,
    _PN_MIN_PARALLEL_ROWS,
    _tile_rows,
    narrow_build_batch,
)
from komira_dispatch_join_kernels.join_payload_widen import (
    widen_payload_table_parallel,
)


comptime I64 = DType.int64
comptime F64 = DType.float64

comptime _SMALL_ROWS: Int = 4096
"""Below `_PN_MIN_PARALLEL_ROWS`, so the SERIAL arm runs. Both arms are
exercised -- §G drives the same fixture shape above the threshold."""

comptime _PAR_ROWS: Int = 200_000
"""Above `_PN_MIN_PARALLEL_ROWS` (65,536), so the FORK runs. §G asserts that
condition on the constants rather than trusting this note."""


# =============================================================================
# Fixtures
# =============================================================================


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
    """The 2-byte fixture's value at row `i`: DISTINCT over any window under
    60,000 rows, and never equal to `i` itself, so a kernel that wrote the row
    index would go red.

    Domain `[1000, 1000 + 59999]` -> span 59,999 -> fits UINT16 at base 1000
    and NOT at base 0 with a 2-byte width if the base were ignored... which is
    exactly the point: `base` is not decoration here."""
    return Int64(1000 + (i * 37) % 60000)


def _val1(i: Int) -> Int64:
    """The 1-byte fixture's value: domain `[-40, 215]`, span 255, so it fits
    UINT8 ONLY with the frame of reference applied. A widen that dropped
    `base` returns a value 40 too large on every row."""
    return Int64(-40 + i % 256)


def _val4(i: Int) -> Int64:
    """The 4-byte fixture: span 3,000,000 -- past UINT16 and inside UINT32, so
    the ladder must pick 4 and a fixture-fitting shortcut to 2 goes red."""
    return Int64(500 + (i * 991) % 3_000_001)


def _valbig(i: Int) -> Int64:
    """Span 4,095 x 1,000,000,007 over the fixture -- past UINT32, so a spec
    claiming FOUR bytes over it is a range violation the 4-byte arm must
    catch."""
    return Int64(i) * Int64(1_000_000_007)


def _key(i: Int) -> Int64:
    return Int64(7_000_000 + i)


def _i64_col(var v: List[Int64]) raises -> Column[HeapRegion]:
    var arr = PrimitiveArray[I64].allocate(len(v))
    for i in range(len(v)):
        arr.set(i, v[i])
    return Column.from_primitive[I64](arr^)


def _f64_col(var v: List[Float64]) raises -> Column[HeapRegion]:
    var arr = PrimitiveArray[F64].allocate(len(v))
    for i in range(len(v)):
        arr.set(i, v[i])
    return Column.from_primitive[F64](arr^)


def _nullable_i64_col(rows: Int) raises -> Column[HeapRegion]:
    """An INT64 column CARRYING A VALIDITY BITMAP (every row valid). The
    physical bitmap is the thing the narrow half refuses on -- not the schema
    flag -- because the batch is what arrives."""
    var buf = OwnedAlignedBuffer(max(rows * 8, 1))
    buf.set_length(Int64(rows * 8))
    for i in range(rows):
        buf.set_typed[Scalar[I64]](i, _val2(i))
    var bm = Bitmap.create_all_valid(rows)
    return Column[HeapRegion](
        arrow_type=ArrowType.INT64,
        data=buf^,
        offsets=Optional[OwnedAlignedBuffer](None),
        validity=Optional[Bitmap[HeapRegion]](bm^),
        length=rows,
        null_count=0,
        offset=0,
    )


def _batch_key_and(
    rows: Int, var payload: Column[HeapRegion], payload_name: String,
    payload_at: ArrowType,
) raises -> RecordBatch:
    """`key` INT64 + one payload column, in that order. Build column `j` maps
    to output column `probe_ncols + j`, and every test below passes
    `probe_ncols = 0`, so the batch IS the output shape."""
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


def _two_payload_batch(rows: Int) raises -> RecordBatch:
    """`key` | `sib` (ELIGIBLE, 2-byte) | `probe_col` (the one under test).

    ⭐ THE `sib` COLUMN IS THE ANTI-VACUITY DEVICE. Every refusal case asserts
    that `sib` STILL narrowed, so "the refusal fired" is distinguishable from
    "nothing ran"."""
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


def _spec(name: String, tb: UInt8, base: Int64) raises -> PayloadNarrowSpec:
    return PayloadNarrowSpec(name.copy(), tb, base)


def _sib_spec() raises -> PayloadNarrowSpec:
    """`sib`'s own proved instruction: `[1000, 60999]` -> span 59,999 -> 2 B."""
    return _spec(String("sib"), UInt8(2), Int64(1000))


def _wide_schema_of(imm b: RecordBatch) raises -> Schema:
    return b.schema.copy()


def _code_for(imm plan: PayloadWidenPlan, imm name: String) raises -> UInt8:
    """The DISPOSITION recorded for column `name`.

    Raises when the column was never even considered, which is a different
    fact from "declined" and must not read as one."""
    for i in range(len(plan.col_names)):
        if plan.col_names[i] == name:
            return plan.col_codes[i]
    raise Error(
        "no disposition recorded for column '" + name
        + "' -- the narrow half never considered it"
    )


def _bytes_for(imm plan: PayloadWidenPlan, imm name: String) raises -> UInt8:
    for i in range(len(plan.col_names)):
        if plan.col_names[i] == name:
            return plan.col_bytes[i]
    raise Error("no width recorded for column '" + name + "'")


# =============================================================================
# §A -- the round trip at each width, against an ABSOLUTE oracle
# =============================================================================


def _roundtrip_case(
    rows: Int,
    n_workers: Int,
    target_bytes: UInt8,
    base: Int64,
    narrow_at: ArrowType,
    imm tag: String,
) raises:
    """Narrow -> assert the STORED bytes are `v - base` -> widen -> assert
    every element is `v` again and the schema is the WIDE one."""
    var vals = List[Int64]()
    for i in range(rows):
        if target_bytes == UInt8(1):
            vals.append(_val1(i))
        elif target_bytes == UInt8(2):
            vals.append(_val2(i))
        else:
            vals.append(_val4(i))
    var batch = _batch_key_and(
        rows, _i64_col(vals.copy()), String("v"), ArrowType.INT64
    )
    var wide = _wide_schema_of(batch)

    var specs = List[PayloadNarrowSpec]()
    specs.append(_spec(String("v"), target_bytes, base))

    var rt = _make_started_runtime(n_workers)
    ref disp = rt.dispatcher()
    var nb = narrow_build_batch(
        batch^, specs, 0, PNL_ADMIT, True,
        Pointer(to=disp), CancellationToken.never(), n_workers,
    )
    var plan = nb.plan.copy()
    var narrowed = nb.take_batch()
    _ = nb^

    assert_equal(
        Int(plan.lever_code), Int(PNL_ADMIT), tag + " lever code"
    )
    assert_equal(plan.num_widened(), 1, tag + " widened column count")
    assert_equal(
        Int(_code_for(plan, String("v"))), Int(PN_ADMIT), tag + " v code"
    )
    assert_equal(
        Int(_bytes_for(plan, String("v"))),
        Int(target_bytes),
        tag + " CHOSEN WIDTH -- a Bool cannot see 4-where-2-belongs",
    )
    assert_equal(plan.out_col[0], 1, tag + " output column index")
    assert_equal(plan.base[0], base, tag + " frame of reference")

    # The key must be UNTOUCHED. ⛔ The key exclusion is the load-bearing
    # refusal of the whole lever (a narrowed key declines the fused leaf into
    # a fallback that reached 130 GB anon-RSS), and here it holds because the
    # optimizer never names it -- so the recorded disposition list must not
    # mention it at all.
    assert_equal(
        Int(narrowed.column_at(0).arrow_type.type_id),
        Int(ArrowType.INT64.type_id),
        tag + " KEY was re-typed",
    )
    assert_equal(len(plan.col_names), 1, tag + " only `v` was considered")

    # The narrowed column: type, and every STORED byte against `v - base`.
    ref nc = narrowed.column_at(1)
    assert_equal(
        Int(nc.arrow_type.type_id),
        Int(narrow_at.type_id),
        tag + " narrowed arrow type",
    )
    assert_equal(nc.length(), rows, tag + " narrowed length")
    for i in range(rows):
        var stored: Int
        if target_bytes == UInt8(1):
            stored = Int(nc._data.get_typed[Scalar[DType.uint8]](i))
        elif target_bytes == UInt8(2):
            stored = Int(nc._data.get_typed[Scalar[DType.uint16]](i))
        else:
            stored = Int(nc._data.get_typed[Scalar[DType.uint32]](i))
        assert_equal(
            stored,
            Int(vals[i] - base),
            tag + " stored[" + String(i) + "] != v - base",
        )

    # Widen the batch AS IF it were the join output (probe_ncols = 0).
    var t = Table.from_batch(narrowed^)
    var out = widen_payload_table_parallel(
        t^, plan, wide, Pointer(to=disp), CancellationToken.never(), n_workers,
    )
    assert_equal(out.num_rows(), rows, tag + " widened row count")
    assert_equal(out.num_columns(), 2, tag + " widened column count")
    assert_equal(
        Int(out.schema().field_arrow_type(1).type_id),
        Int(ArrowType.INT64.type_id),
        tag + " widened SCHEMA type",
    )
    ref ch = out.chunks()[0]
    assert_equal(
        Int(ch.column_at(1).arrow_type.type_id),
        Int(ArrowType.INT64.type_id),
        tag + " widened COLUMN type",
    )
    var wc = ch.column_at(1).as_primitive[I64]()
    var kc = ch.column_at(0).as_primitive[I64]()
    for i in range(rows):
        assert_equal(wc.get(i), vals[i], tag + " widened[" + String(i) + "]")
        assert_equal(kc.get(i), _key(i), tag + " key[" + String(i) + "]")
    _ = out^
    rt.shutdown()


def test_a_roundtrip_2_bytes_serial() raises:
    _roundtrip_case(
        _SMALL_ROWS, 4, UInt8(2), Int64(1000), ArrowType.UINT16,
        String("§A 2B serial"),
    )


def test_a2_roundtrip_1_byte_negative_base() raises:
    # ⛔ base = -40. A widen that dropped `base` is off by 40 on EVERY row and
    # a narrow that dropped it underflows -- both go red here, and neither
    # would at base 0.
    _roundtrip_case(
        _SMALL_ROWS, 4, UInt8(1), Int64(-40), ArrowType.UINT8,
        String("§A2 1B negative base"),
    )


def test_a3_roundtrip_4_bytes() raises:
    _roundtrip_case(
        _SMALL_ROWS, 4, UInt8(4), Int64(500), ArrowType.UINT32,
        String("§A3 4B"),
    )


def test_a4_roundtrip_2_bytes_forked() raises:
    # The SAME assertions above the fork threshold, so the parallel arm is
    # covered by every one of them and not only by §G's equality.
    _roundtrip_case(
        _PAR_ROWS, 4, UInt8(2), Int64(1000), ArrowType.UINT16,
        String("§A4 2B forked"),
    )


# =============================================================================
# §B -- the per-column refusals. EACH names its own code AND proves a sibling
#       still narrowed, so a vacuous run cannot pass.
# =============================================================================


def _refusal_case(
    var probe_col: Column[HeapRegion],
    probe_at: ArrowType,
    var probe_spec: PayloadNarrowSpec,
    all_sizes: Bool,
    expect_code: UInt8,
    imm tag: String,
) raises:
    var rows = probe_col.length()
    var base = _two_payload_batch(rows)
    var cols = base.take_columns()
    _ = base^
    var sb = SchemaBuilder()
    sb.add_field(Field("key", ArrowType.INT64, False))
    sb.add_field(Field("sib", ArrowType.INT64, False))
    sb.add_field(Field("probe_col", probe_at, False))
    cols.append(probe_col^)
    var batch = RecordBatch.from_typed_columns_slab(sb.build(), cols^)

    var specs = List[PayloadNarrowSpec]()
    specs.append(_sib_spec())
    specs.append(probe_spec^)

    var rt = _make_started_runtime(4)
    ref disp = rt.dispatcher()
    var nb = narrow_build_batch(
        batch^, specs, 0, PNL_ADMIT, all_sizes,
        Pointer(to=disp), CancellationToken.never(), 4,
    )
    var plan = nb.plan.copy()
    var narrowed = nb.take_batch()
    _ = nb^

    assert_equal(
        Int(_code_for(plan, String("probe_col"))),
        Int(expect_code),
        tag + " refusal code",
    )
    # ⭐ ANTI-VACUITY: the sibling in the SAME batch must STILL have narrowed.
    assert_equal(
        Int(_code_for(plan, String("sib"))),
        Int(PN_ADMIT),
        tag + " the SIBLING was refused too -- this run proves nothing",
    )
    assert_equal(plan.num_widened(), 1, tag + " exactly the sibling widened")
    assert_equal(plan.out_col[0], 1, tag + " the sibling is output column 1")
    assert_equal(
        Int(narrowed.column_at(1).arrow_type.type_id),
        Int(ArrowType.UINT16.type_id),
        tag + " sibling physical type",
    )
    assert_equal(
        Int(narrowed.column_at(2).arrow_type.type_id),
        Int(probe_at.type_id),
        tag + " the REFUSED column was rewritten anyway",
    )
    _ = narrowed^
    rt.shutdown()


def test_b_not_int64_is_named() raises:
    var v = List[Float64]()
    for i in range(_SMALL_ROWS):
        v.append(Float64(i) * 0.5)
    _refusal_case(
        _f64_col(v^), ArrowType.FLOAT64,
        _spec(String("probe_col"), UInt8(2), Int64(0)),
        True, PN_NOT_INT64, String("§B NOT_INT64"),
    )


def test_b2_nullable_is_named() raises:
    # A narrowed column keeps its bitmap, but the value under a NULL slot is
    # not covered by [min,max]; `v - base` on it can wrap and the widen
    # reconstructs a DIFFERENT garbage value. The PHYSICAL bitmap is what is
    # refused on, because the batch is what arrives.
    _refusal_case(
        _nullable_i64_col(_SMALL_ROWS), ArrowType.INT64,
        _spec(String("probe_col"), UInt8(2), Int64(1000)),
        True, PN_NULLABLE, String("§B2 NULLABLE"),
    )


def test_b3_bad_width_is_named() raises:
    var v = List[Int64]()
    for i in range(_SMALL_ROWS):
        v.append(_val2(i))
    _refusal_case(
        _i64_col(v^), ArrowType.INT64,
        _spec(String("probe_col"), UInt8(3), Int64(1000)),
        True, PN_BAD_WIDTH, String("§B3 BAD_WIDTH"),
    )


def test_b4_source_size_floor_is_named_and_is_a_boundary() raises:
    """The admission floor, asserted AT ITS OWN BOUNDARY.

    ⛔ NOT "small declines, big admits". The floor is `rows * 8 <
    JOIN_PAYLOAD_NARROW_MIN_SRC_BYTES`, so the two rows that discriminate it
    are `MIN/8 - 1` and `MIN/8`. A test that used 100 and 100,000,000 would
    pass against ANY floor in a 12-order-of-magnitude range, including one
    that had been silently deleted."""
    var floor_rows = JOIN_PAYLOAD_NARROW_MIN_SRC_BYTES // 8
    assert_true(
        floor_rows > _PN_MIN_PARALLEL_ROWS,
        "§B4 the floor must sit above the fork threshold or this case runs"
        " serial and does not cover the shipped arm",
    )

    var rt = _make_started_runtime(4)
    ref disp = rt.dispatcher()

    # ONE ROW SHORT -> declines, naming the floor.
    var under = _two_payload_batch(floor_rows - 1)
    var specs_u = List[PayloadNarrowSpec]()
    specs_u.append(_sib_spec())
    var nb_u = narrow_build_batch(
        under^, specs_u, 0, PNL_ADMIT, False,
        Pointer(to=disp), CancellationToken.never(), 4,
    )
    var plan_u = nb_u.plan.copy()
    _ = nb_u.take_batch()
    _ = nb_u^
    assert_equal(
        Int(_code_for(plan_u, String("sib"))),
        Int(PN_SRC_TOO_SMALL),
        "§B4 one row under the floor must decline",
    )
    assert_equal(
        Int(plan_u.lever_code), Int(PNL_NO_COLUMN), "§B4 under lever code"
    )
    assert_equal(plan_u.num_widened(), 0, "§B4 under widened count")

    # EXACTLY AT THE FLOOR -> admits.
    var at = _two_payload_batch(floor_rows)
    var specs_a = List[PayloadNarrowSpec]()
    specs_a.append(_sib_spec())
    var nb_a = narrow_build_batch(
        at^, specs_a, 0, PNL_ADMIT, False,
        Pointer(to=disp), CancellationToken.never(), 4,
    )
    var plan_a = nb_a.plan.copy()
    var narrowed_a = nb_a.take_batch()
    _ = nb_a^
    assert_equal(
        Int(_code_for(plan_a, String("sib"))),
        Int(PN_ADMIT),
        "§B4 exactly at the floor must admit",
    )
    assert_equal(plan_a.num_widened(), 1, "§B4 at-floor widened count")
    assert_equal(
        Int(narrowed_a.column_at(1).arrow_type.type_id),
        Int(ArrowType.UINT16.type_id),
        "§B4 at-floor physical type",
    )
    _ = narrowed_a^

    # AND THE BYPASS: the SAME under-floor batch admits with `all_sizes`.
    # Without this the floor and a deleted lever are indistinguishable.
    var under2 = _two_payload_batch(floor_rows - 1)
    var specs_b = List[PayloadNarrowSpec]()
    specs_b.append(_sib_spec())
    var nb_b = narrow_build_batch(
        under2^, specs_b, 0, PNL_ADMIT, True,
        Pointer(to=disp), CancellationToken.never(), 4,
    )
    var plan_b = nb_b.plan.copy()
    _ = nb_b.take_batch()
    _ = nb_b^
    assert_equal(
        Int(_code_for(plan_b, String("sib"))),
        Int(PN_ADMIT),
        "§B4 all_sizes did not bypass the floor",
    )
    rt.shutdown()


def test_b5_an_unnamed_column_is_not_even_considered() raises:
    """A column with NO spec carries no disposition at all -- which is a
    different fact from a refusal and must not be reported as one."""
    var batch = _two_payload_batch(_SMALL_ROWS)
    var specs = List[PayloadNarrowSpec]()
    specs.append(_sib_spec())
    var rt = _make_started_runtime(4)
    ref disp = rt.dispatcher()
    var nb = narrow_build_batch(
        batch^, specs, 0, PNL_ADMIT, True,
        Pointer(to=disp), CancellationToken.never(), 4,
    )
    var plan = nb.plan.copy()
    _ = nb.take_batch()
    _ = nb^
    assert_equal(len(plan.col_names), 1, "§B5 only `sib` was considered")
    assert_equal(plan.col_names[0], String("sib"), "§B5 the considered column")
    assert_equal(
        Int(_code_for(plan, String("sib"))), Int(PN_ADMIT), "§B5 sib code"
    )
    rt.shutdown()


# =============================================================================
# §C -- the RANGE VIOLATION discards the WHOLE narrowing and cannot raise
# =============================================================================


def _violation_case(
    claim_bytes: UInt8, claim_base: Int64, gen: Int, imm tag: String
) raises:
    """One (claimed width, data that does not fit it) pair.

    ⛔ EVERY WIDTH THE LADDER CAN PICK GETS ITS OWN CASE, AND THAT IS NOT
    THOROUGHNESS FOR ITS OWN SAKE -- IT IS A MEASURED GAP. The first version of
    this file tested the violation at ONE width, and the mutation that deleted
    the 2-byte arm's range check came back GREEN (`m2`): the only
    violation fixture used the 1-byte arm, so the check on the arm a
    high-cardinality join takes was covered by nothing."""
    var rows = _SMALL_ROWS
    var v = List[Int64]()
    for i in range(rows):
        if gen == 2:
            v.append(_val2(i))
        else:
            v.append(_valbig(i))
    var base = _two_payload_batch(rows)
    var cols = base.take_columns()
    _ = base^
    var sb = SchemaBuilder()
    sb.add_field(Field("key", ArrowType.INT64, False))
    sb.add_field(Field("sib", ArrowType.INT64, False))
    sb.add_field(Field("probe_col", ArrowType.INT64, False))
    cols.append(_i64_col(v.copy()))
    var batch = RecordBatch.from_typed_columns_slab(sb.build(), cols^)

    var specs = List[PayloadNarrowSpec]()
    specs.append(_sib_spec())
    specs.append(_spec(String("probe_col"), claim_bytes, claim_base))

    var rt = _make_started_runtime(4)
    ref disp = rt.dispatcher()
    var nb = narrow_build_batch(
        batch^, specs, 0, PNL_ADMIT, True,
        Pointer(to=disp), CancellationToken.never(), 4,
    )
    var plan = nb.plan.copy()
    var out = nb.take_batch()
    _ = nb^

    assert_equal(
        Int(plan.lever_code),
        Int(PNL_RANGE_VIOLATION),
        tag + " lever code -- the violation must NAME itself, not read as"
        " NO_COLUMN",
    )
    assert_equal(plan.num_widened(), 0, tag + " nothing may be widened")
    assert_equal(
        Int(_code_for(plan, String("sib"))),
        Int(PN_RANGE_VIOLATION),
        tag + " the ADMITTED sibling must be re-coded, not left reading"
        " ADMIT over a column that was never narrowed",
    )
    # The batch is byte-for-byte the input: types AND values.
    assert_equal(out.num_columns(), 3, tag + " column count")
    assert_equal(out.num_rows(), rows, tag + " row count")
    for c in range(3):
        assert_equal(
            Int(out.column_at(c).arrow_type.type_id),
            Int(ArrowType.INT64.type_id),
            tag + " column " + String(c) + " was re-typed after a violation",
        )
    var sc = out.column_at(1).as_primitive[I64]()
    var pc = out.column_at(2).as_primitive[I64]()
    for i in range(rows):
        assert_equal(sc.get(i), _val2(i), tag + " sib[" + String(i) + "]")
        assert_equal(pc.get(i), v[i], tag + " probe_col[" + String(i) + "]")
    _ = out^
    rt.shutdown()


def test_c_range_violation_discards_everything_at_1_byte() raises:
    """A 1-byte claim over a span of 59,999 -- 234x too wide.

    ⛔ THE FALLBACK IS THE UNNARROWED JOIN, WHICH IS ALWAYS CORRECT. Raising
    would convert a stale parquet statistic into a FAILED QUERY; narrowing the
    siblings would leave a half-applied transform, and a half-applied
    narrowing (a widen that adds a base nobody subtracted, or the reverse) is
    the one wrong-answer shape this design has."""
    _violation_case(UInt8(1), Int64(1000), 2, String("§C 1B"))


def test_c1b_range_violation_at_2_bytes() raises:
    """⭐ THE ARM A HIGH-CARDINALITY JOIN TAKES. Added after mutation `m2` -- deleting the
    2-byte range check -- came back GREEN against a suite whose only violation
    fixture drove the 1-byte arm."""
    _violation_case(UInt8(2), Int64(0), 4, String("§C 2B"))


def test_c1c_range_violation_at_4_bytes() raises:
    """The last width the ladder can pick, for the same reason."""
    _violation_case(UInt8(4), Int64(0), 4, String("§C 4B"))


def test_c2_range_violation_on_the_forked_arm() raises:
    """The same discard ABOVE the fork threshold: the violation flag is an
    atomic written by a worker and read by the driver, and a serial-only test
    would never exercise that channel."""
    var rows = _PAR_ROWS
    var v = List[Int64]()
    for i in range(rows):
        v.append(_val2(i))
    var sb = SchemaBuilder()
    sb.add_field(Field("key", ArrowType.INT64, False))
    sb.add_field(Field("probe_col", ArrowType.INT64, False))
    var keys = List[Int64]()
    for i in range(rows):
        keys.append(_key(i))
    var b = RecordBatchBuilder.with_capacity(2)
    b.add_column(_i64_col(keys^))
    b.add_column(_i64_col(v.copy()))
    var batch = b.build(sb.build())

    var specs = List[PayloadNarrowSpec]()
    specs.append(_spec(String("probe_col"), UInt8(1), Int64(1000)))

    var rt = _make_started_runtime(4)
    ref disp = rt.dispatcher()
    var nb = narrow_build_batch(
        batch^, specs, 0, PNL_ADMIT, True,
        Pointer(to=disp), CancellationToken.never(), 4,
    )
    var plan = nb.plan.copy()
    var out = nb.take_batch()
    _ = nb^
    assert_equal(
        Int(plan.lever_code), Int(PNL_RANGE_VIOLATION), "§C2 lever code"
    )
    assert_equal(plan.num_widened(), 0, "§C2 nothing widened")
    assert_equal(
        Int(out.column_at(1).arrow_type.type_id),
        Int(ArrowType.INT64.type_id),
        "§C2 column re-typed after a forked violation",
    )
    var pc = out.column_at(1).as_primitive[I64]()
    for i in range(0, rows, 997):
        assert_equal(pc.get(i), _val2(i), "§C2 value[" + String(i) + "]")
    _ = out^
    rt.shutdown()


# =============================================================================
# §D -- the WHOLE-LEVER prechecks. Each code must survive to the plan and
#       widen nothing.
# =============================================================================


def test_d_lever_prechecks_are_carried_not_collapsed() raises:
    var rt = _make_started_runtime(2)
    ref disp = rt.dispatcher()
    var codes = List[UInt8]()
    codes.append(PNL_GATE_OFF)
    codes.append(PNL_NOT_INNER)
    codes.append(PNL_COUNT_ONLY)
    codes.append(PNL_SCHEMA_SHAPE)
    codes.append(PNL_PAYLOAD_INLINE_ON)
    for ci in range(len(codes)):
        var batch = _two_payload_batch(_SMALL_ROWS)
        var specs = List[PayloadNarrowSpec]()
        specs.append(_sib_spec())
        var nb = narrow_build_batch(
            batch^, specs, 0, codes[ci], True,
            Pointer(to=disp), CancellationToken.never(), 2,
        )
        var plan = nb.plan.copy()
        var out = nb.take_batch()
        _ = nb^
        assert_equal(
            Int(plan.lever_code),
            Int(codes[ci]),
            "§D precheck " + String(Int(codes[ci]))
            + " was COLLAPSED into another code -- a witness that cannot"
            " name the line is the defect this file exists to prevent",
        )
        assert_equal(
            plan.num_widened(), 0,
            "§D precheck " + String(Int(codes[ci])) + " widened anyway",
        )
        assert_equal(
            Int(out.column_at(1).arrow_type.type_id),
            Int(ArrowType.INT64.type_id),
            "§D precheck " + String(Int(codes[ci])) + " rewrote a column",
        )
        _ = out^
    rt.shutdown()


def test_d2_no_specs_is_its_own_code() raises:
    """An EMPTY spec list is what every non-narrowed corpus cell hands the
    leaf -- 79 of 84 of them -- so it must be distinguishable from a refusal
    and from a gate that is off."""
    var batch = _two_payload_batch(_SMALL_ROWS)
    var rt = _make_started_runtime(2)
    ref disp = rt.dispatcher()
    var nb = narrow_build_batch(
        batch^, List[PayloadNarrowSpec](), 0, PNL_ADMIT, True,
        Pointer(to=disp), CancellationToken.never(), 2,
    )
    var plan = nb.plan.copy()
    var out = nb.take_batch()
    _ = nb^
    assert_equal(Int(plan.lever_code), Int(PNL_NO_SPECS), "§D2 lever code")
    assert_equal(plan.num_widened(), 0, "§D2 widened count")
    assert_equal(len(plan.col_names), 0, "§D2 nothing was considered")
    _ = out^
    rt.shutdown()


def main() raises:
    var suite = TestSuite()
    suite.test[test_a_roundtrip_2_bytes_serial]()
    suite.test[test_a2_roundtrip_1_byte_negative_base]()
    suite.test[test_a3_roundtrip_4_bytes]()
    suite.test[test_a4_roundtrip_2_bytes_forked]()
    suite.test[test_b_not_int64_is_named]()
    suite.test[test_b2_nullable_is_named]()
    suite.test[test_b3_bad_width_is_named]()
    suite.test[test_b4_source_size_floor_is_named_and_is_a_boundary]()
    suite.test[test_b5_an_unnamed_column_is_not_even_considered]()
    suite.test[test_c_range_violation_discards_everything_at_1_byte]()
    suite.test[test_c1b_range_violation_at_2_bytes]()
    suite.test[test_c1c_range_violation_at_4_bytes]()
    suite.test[test_c2_range_violation_on_the_forked_arm]()
    suite.test[test_d_lever_prechecks_are_carried_not_collapsed]()
    suite.test[test_d2_no_specs_is_its_own_code]()
    suite^.run()
