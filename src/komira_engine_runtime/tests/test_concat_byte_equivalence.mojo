# =============================================================================
# CONCAT ROUTES AGREE: the same multi-column batches through every route
# =============================================================================
#
# `concat_record_batches_column_parallel` has four ways to lay the same
# batches end to end:
#   * serial, on the caller (under 1,024 rows);
#   * one task per column (`ConcatOptions(tiling=False)`);
#   * row-range tiles (`force_tiles=True` pins 3 tiles per splittable column;
#     the rule picks the count on a large input), with STRING columns cut into
#     byte-balanced tiles, equal-row tiles (`string_bytebal=False`), or left
#     whole (`string_tiling=False`).
# They must produce the same column bytes. This file checks two things for
# every route, on a fixture with four column kinds:
#   * ORACLE: output row r equals the value regenerated from the fixture's own
#     row generator (value, validity bit, null count, DECIMAL precision and
#     scale, STRING offsets). The oracle reads the raw buffers.
#   * EQUIVALENCE: the route's data, offsets and validity bytes and its null
#     counts equal the one-task-per-column route's, byte for byte.
# Each run also asserts which route it took, read from `grain_geometry`
# (calls == 0: serial; morsels == 1: one task per column; morsels == tiles:
# row-range tiled), so a fixture that silently falls back to another route is
# a loud failure rather than two copies of the same route compared.
#
# FIXTURE: INT64 with nulls, INT32 without, DECIMAL128 (precision 12, scale 2)
# with nulls, and STRING with nulls (three rows in four empty, the rest carrying
# their row number). Batch sizes are ragged and include a zero-row and a
# one-row batch, so tile boundaries fall strictly inside batches. The total row
# count is swept over all three residues mod 3, so the 3-tile cut is exercised
# both with an even split and with a remainder. Nulls are periodic with periods
# coprime to the batch sizes, so they straddle every tile boundary.
#
# SLICED INPUTS: the columns of a batch can be windows into larger buffers
# (`_offset != 0`, validity read at `_offset + r`). The sliced fixture shifts
# each batch's window by a different amount that is not a multiple of 8, so
# the validity bits do not start on a byte boundary.
#
# DESTROY-RECREATE: the last test runs the tiled route over ten fresh pools in
# a row, torn down after each concat.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.bitmap import Bitmap
from komira_arrow.column import Column
from komira_arrow.decimal_array import Decimal128Array
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import (
    Field,
    RecordBatch,
    RecordBatchBuilder,
    SchemaBuilder,
)
from komira_arrow.string_array import StringArray
from komira_buffer.heap_region import HeapRegion
from komira_collections.slab import Slab

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.runtime import PLACEMENT_FIXED, PerCoreAsyncRuntime
from komira_async.runtime.sched_trace import SITE_CONCAT

from komira_engine_runtime.concat_options import ConcatOptions
from komira_engine_runtime.grain_geometry import (
    GRAIN_F_MORSELS,
    grain_geometry_calls,
    grain_geometry_field,
    grain_geometry_reset,
)
from komira_engine_runtime.streaming_concat_parallel import (
    concat_record_batches_column_parallel,
)


comptime _WORKERS: Int = 4
comptime _E3_WORKERS: Int = 12
"""The rule gives each of the four columns `workers // 4` tiles, so it needs a
pool wider than the column count to cut anything."""
comptime _DEC_P: Int = 12
comptime _DEC_S: Int = 2
comptime _PAD_ROW_BASE: Int = 1_000_000
"""Row ids of the rows a sliced batch hides in front of its window."""

# Route labels for `_expect_route`.
comptime _SERIAL: Int = 0
comptime _PER_COLUMN: Int = 1
comptime _TILED_3: Int = 3


def _noop_sink_factory() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


# =============================================================================
# Row generators (the oracle's source of truth)
# =============================================================================


def _a_null(g: Int) -> Bool:
    return g % 7 == 2


def _d_null(g: Int) -> Bool:
    return g % 11 == 4


def _s_null(g: Int) -> Bool:
    return g % 5 == 3


def _a_val(g: Int) -> Int64:
    return Int64(g * 3 + 1)


def _b_val(g: Int) -> Int32:
    return Int32(g * 5 - 1)


def _d_val(g: Int) -> Int:
    """The unscaled DECIMAL value: 1.37 at row 0, 2.37 at row 1, ..."""
    return g * 100 + 37


def _s_val(g: Int) -> String:
    if (g * 7919) % 4 != 1:
        return String("")
    var s = String("s") + String(g)
    for _k in range(g % 9):
        s += "-x"
    return s^


def _ragged_sizes(residue: Int) -> List[Int]:
    """Ragged batch sizes (a zero-row and a one-row batch included) whose total
    is `residue` modulo 3 and above the 1,024-row parallel floor."""
    var sizes: List[Int] = [1500, 1, 0, 2999, 17, 4096, 2048, 1203]
    var total = 0
    for i in range(len(sizes)):
        total += sizes[i]
    var tail = 1
    while (total + tail) % 3 != residue:
        tail += 1
    sizes.append(tail)
    return sizes^


def _total(imm sizes: List[Int]) -> Int:
    var t = 0
    for i in range(len(sizes)):
        t += sizes[i]
    return t


# =============================================================================
# Fixture builders
# =============================================================================


def _window(mut c: Column[HeapRegion], pad: Int, n: Int):
    """Make `c` a window of `n` rows starting `pad` rows into its buffers."""
    c._offset = pad
    c._length = n
    var nulls = 0
    if c._validity:
        for i in range(n):
            if not c._validity.value().test(pad + i):
                nulls += 1
    c._null_count = nulls


def _batch(base: Int, n: Int, pad: Int) raises -> RecordBatch:
    """Rows [base, base + n) of the fixture. With `pad > 0` every column holds
    `pad` extra rows in front and is windowed past them."""
    var ids = List[Int]()
    for j in range(pad):
        ids.append(_PAD_ROW_BASE + j)
    for j in range(n):
        ids.append(base + j)
    var m = len(ids)

    var a = PrimitiveArray[DType.int64].allocate(m)
    var ap = a._typed_ptr_mut()
    var av = Bitmap.create_all_valid(m)
    var a_nulls = 0
    for j in range(m):
        (ap + j)[] = _a_val(ids[j])
        if _a_null(ids[j]):
            av.clear(j)
            a_nulls += 1
    a.validity = Optional[Bitmap[HeapRegion]](av^)
    a.null_count = a_nulls
    var a_col = Column.from_primitive[DType.int64](a^)

    var b = PrimitiveArray[DType.int32].allocate(m)
    var bp = b._typed_ptr_mut()
    for j in range(m):
        (bp + j)[] = _b_val(ids[j])
    var b_col = Column.from_primitive[DType.int32](b^)

    var d = Decimal128Array[HeapRegion].allocate_nullable(m, _DEC_P, _DEC_S)
    for j in range(m):
        if _d_null(ids[j]):
            d.set_null(j)
        else:
            d.set_i128(j, SIMD[DType.int128, 1](_d_val(ids[j])))
    var d_col = Column.from_decimal128(d)

    var strs = List[String](capacity=m)
    var valid = List[Bool](capacity=m)
    for j in range(m):
        if _s_null(ids[j]):
            strs.append(String(""))
            valid.append(False)
        else:
            strs.append(_s_val(ids[j]))
            valid.append(True)
    var s_col = Column.from_string(
        StringArray.from_strings_with_validity(strs, valid)
    )

    if pad > 0:
        _window(a_col, pad, n)
        _window(b_col, pad, n)
        _window(d_col, pad, n)
        _window(s_col, pad, n)

    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT64, True))
    sb.add_field(Field("b", ArrowType.INT32, False))
    sb.add_field(Field("d", ArrowType.DECIMAL128, True))
    sb.add_field(Field("s", ArrowType.STRING, True))
    var rb = RecordBatchBuilder()
    rb.add_column(a_col^)
    rb.add_column(b_col^)
    rb.add_column(d_col^)
    rb.add_column(s_col^)
    return rb.build(sb.build())


def _batches(imm sizes: List[Int], sliced: Bool) raises -> Slab[RecordBatch]:
    var out = Slab[RecordBatch].create(len(sizes))
    var base = 0
    for i in range(len(sizes)):
        var pad = ((i * 5 + 3) % 11 + 1) if sliced else 0
        out.append(_batch(base, sizes[i], pad))
        base += sizes[i]
    return out^


def _drive(
    var batches: Slab[RecordBatch],
    options: ConcatOptions,
    workers: Int = _WORKERS,
) raises -> RecordBatch:
    var runtime = PerCoreAsyncRuntime[NoopSink](
        num_workers=workers,
        sink_factory=_noop_sink_factory,
        backend=BACKEND_MOCK,
        placement=PLACEMENT_FIXED,
    )
    var ct = CancellationToken.new()
    ref disp = runtime.dispatcher()
    var out = concat_record_batches_column_parallel(
        batches^, disp, ct^, options
    )
    _ = runtime^
    return out^


# =============================================================================
# Assertions
# =============================================================================


def _expect_route(label: String, route: Int) raises:
    """The concat took the route the test meant to compare."""
    var calls = grain_geometry_calls(SITE_CONCAT)
    if route == _SERIAL:
        if calls != 0:
            raise Error(label + ": expected the serial route (no fork), got "
                        + String(calls) + " fork(s)")
        return
    if calls != 1:
        raise Error(label + ": expected one fork at SITE_CONCAT, got "
                    + String(calls))
    var morsels = grain_geometry_field(SITE_CONCAT, GRAIN_F_MORSELS)
    if route == _PER_COLUMN and morsels != 1:
        raise Error(label + ": expected the one-task-per-column fan (1), got "
                    + String(morsels) + " tile(s)")
    if route == _TILED_3 and morsels != 3:
        raise Error(label + ": expected 3 tiles per column, got "
                    + String(morsels))


def _assert_offsets_sane(label: String, imm c: Column[HeapRegion]) raises:
    ref offs = c._offsets.value()
    assert_equal(Int(offs.get_typed[Int32](0)), 0, label + ": offsets[0]")
    for r in range(c._length):
        var lo = Int(offs.get_typed[Int32](r))
        var hi = Int(offs.get_typed[Int32](r + 1))
        if hi < lo:
            raise Error(label + ": offsets decrease at row " + String(r))


def _string_at(imm c: Column[HeapRegion], r: Int) raises -> String:
    ref offs = c._offsets.value()
    var s = Int(offs.get_typed[Int32](r))
    var e = Int(offs.get_typed[Int32](r + 1))
    var bytes = List[UInt8](capacity=e - s)
    for i in range(s, e):
        bytes.append(c._data.read_u8_at(i))
    return String(StringSlice(unsafe_from_utf8=Span(bytes)))


def _assert_matches_generator(
    label: String, imm out: RecordBatch, total: Int
) raises:
    assert_equal(out.num_rows(), total, label + ": rows")
    assert_equal(out.num_columns(), 4, label + ": columns")

    ref a = out.column_at(0)
    ref b = out.column_at(1)
    ref d = out.column_at(2)
    ref s = out.column_at(3)
    assert_true(d.arrow_type == ArrowType.DECIMAL128, label + ": d type")
    assert_equal(d._decimal_p, _DEC_P, label + ": decimal precision")
    assert_equal(d._decimal_s, _DEC_S, label + ": decimal scale")
    _assert_offsets_sane(label + " s", s)

    var a_nulls = 0
    var d_nulls = 0
    var s_nulls = 0
    var s_bytes = 0
    for r in range(total):
        if _a_null(r):
            a_nulls += 1
            assert_true(
                not a._validity.value().test(r),
                label + ": a row " + String(r) + " must be NULL",
            )
        else:
            assert_true(
                a._validity.value().test(r),
                label + ": a row " + String(r) + " must be valid",
            )
            assert_equal(
                Int(a._data.get_typed[Int64](r)), Int(_a_val(r)),
                label + ": a row " + String(r),
            )
        assert_equal(
            Int(b._data.get_typed[Int32](r)), Int(_b_val(r)),
            label + ": b row " + String(r),
        )
        if _d_null(r):
            d_nulls += 1
            assert_true(
                not d._validity.value().test(r),
                label + ": d row " + String(r) + " must be NULL",
            )
        else:
            assert_true(
                d._validity.value().test(r),
                label + ": d row " + String(r) + " must be valid",
            )
            assert_true(
                d._data.read_i128_le_at(r * 16)
                == SIMD[DType.int128, 1](_d_val(r)),
                label + ": d row " + String(r),
            )
        if _s_null(r):
            s_nulls += 1
            assert_true(
                not s._validity.value().test(r),
                label + ": s row " + String(r) + " must be NULL",
            )
        else:
            assert_true(
                s._validity.value().test(r),
                label + ": s row " + String(r) + " must be valid",
            )
            assert_equal(
                _string_at(s, r), _s_val(r), label + ": s row " + String(r)
            )
            s_bytes += _s_val(r).byte_length()
    assert_equal(
        Int(s._offsets.value().get_typed[Int32](total)), s_bytes,
        label + ": s payload length",
    )
    assert_equal(a._null_count, a_nulls, label + ": a null count")
    assert_equal(b._null_count, 0, label + ": b null count")
    assert_equal(d._null_count, d_nulls, label + ": d null count")
    assert_equal(s._null_count, s_nulls, label + ": s null count")


def _assert_same_bytes(
    label: String, imm x: RecordBatch, imm y: RecordBatch
) raises:
    """`x` and `y` agree on every column's data, offsets and validity bytes,
    null count, length, type and decimal metadata."""
    assert_equal(x.num_rows(), y.num_rows(), label + ": rows")
    assert_equal(x.num_columns(), y.num_columns(), label + ": columns")
    for ci in range(x.num_columns()):
        ref p = x.column_at(ci)
        ref q = y.column_at(ci)
        var tag = label + " column " + String(ci)
        assert_true(p.arrow_type == q.arrow_type, tag + ": type")
        assert_equal(p._length, q._length, tag + ": length")
        assert_equal(p._null_count, q._null_count, tag + ": null count")
        assert_equal(p._decimal_p, q._decimal_p, tag + ": decimal precision")
        assert_equal(p._decimal_s, q._decimal_s, tag + ": decimal scale")
        var n = p._length
        var data_bytes: Int
        if p.arrow_type == ArrowType.STRING:
            assert_true(Bool(p._offsets) and Bool(q._offsets), tag + ": offsets")
            for i in range(n + 1):
                assert_equal(
                    Int(p._offsets.value().get_typed[Int32](i)),
                    Int(q._offsets.value().get_typed[Int32](i)),
                    tag + ": offset " + String(i),
                )
            data_bytes = Int(p._offsets.value().get_typed[Int32](n))
        elif p.arrow_type == ArrowType.INT64:
            data_bytes = n * 8
        elif p.arrow_type == ArrowType.INT32:
            data_bytes = n * 4
        else:
            data_bytes = n * 16
        for i in range(data_bytes):
            if p._data.read_u8_at(i) != q._data.read_u8_at(i):
                raise Error(tag + ": data byte " + String(i) + " differs")
        assert_equal(Bool(p._validity), Bool(q._validity), tag + ": has validity")
        if p._validity:
            for i in range((n + 7) >> 3):
                if (
                    p._validity.value().buffer.read_u8_at(i)
                    != q._validity.value().buffer.read_u8_at(i)
                ):
                    raise Error(tag + ": validity byte " + String(i) + " differs")


def _check_all_routes(label: String, imm sizes: List[Int], sliced: Bool) raises:
    var total = _total(sizes)

    grain_geometry_reset()
    var whole = _drive(_batches(sizes, sliced), ConcatOptions(tiling=False))
    _expect_route(label + " per-column", _PER_COLUMN)
    _assert_matches_generator(label + " per-column", whole, total)

    grain_geometry_reset()
    var forced = _drive(_batches(sizes, sliced), ConcatOptions(force_tiles=True))
    _expect_route(label + " forced tiles", _TILED_3)
    _assert_matches_generator(label + " forced tiles", forced, total)
    _assert_same_bytes(label + " forced tiles vs per-column", forced, whole)

    # STRING columns on the whole-column task inside the tiled fork.
    grain_geometry_reset()
    var str_whole = _drive(
        _batches(sizes, sliced),
        ConcatOptions(force_tiles=True, string_tiling=False),
    )
    _expect_route(label + " forced tiles, whole strings", _TILED_3)
    _assert_matches_generator(label + " forced tiles, whole strings", str_whole, total)
    _assert_same_bytes(label + " whole strings vs per-column", str_whole, whole)

    # STRING tiles cut at equal row counts instead of equal bytes.
    grain_geometry_reset()
    var equal_rows = _drive(
        _batches(sizes, sliced),
        ConcatOptions(force_tiles=True, string_bytebal=False),
    )
    _expect_route(label + " forced tiles, equal rows", _TILED_3)
    _assert_matches_generator(label + " forced tiles, equal rows", equal_rows, total)
    _assert_same_bytes(label + " equal rows vs per-column", equal_rows, whole)


# =============================================================================
# Tests
# =============================================================================


def test_e1_every_route_matches_the_oracle_and_each_other() raises:
    for residue in range(3):
        _check_all_routes(
            String("e1 residue ") + String(residue), _ragged_sizes(residue), False
        )


def test_e2_sliced_inputs_on_every_route() raises:
    for residue in range(3):
        _check_all_routes(
            String("e2 sliced residue ") + String(residue),
            _ragged_sizes(residue),
            True,
        )


def test_e3_the_rule_tiles_a_large_input_like_the_other_routes() raises:
    """Above the tiling row floor the default options tile without a forced
    count; the tiles then equal the per-column route's bytes."""
    var sizes: List[Int] = [
        30011, 1, 0, 47000, 17, 4096, 25003, 18000, 12347, 6007,
    ]
    var total = _total(sizes)
    assert_true(total >= 131_072, "e3 fixture must clear the tiling row floor")

    grain_geometry_reset()
    var whole = _drive(
        _batches(sizes, False), ConcatOptions(tiling=False), _E3_WORKERS
    )
    _expect_route(String("e3 per-column"), _PER_COLUMN)
    _assert_matches_generator(String("e3 per-column"), whole, total)

    grain_geometry_reset()
    var tiled = _drive(_batches(sizes, False), ConcatOptions(), _E3_WORKERS)
    assert_equal(grain_geometry_calls(SITE_CONCAT), 1, "e3: one fork")
    assert_true(
        grain_geometry_field(SITE_CONCAT, GRAIN_F_MORSELS) >= 2,
        "e3: the rule must cut the columns into tiles",
    )
    _assert_matches_generator(String("e3 rule tiles"), tiled, total)
    _assert_same_bytes(String("e3 rule tiles vs per-column"), tiled, whole)


def test_e4_under_the_parallel_floor_stays_serial_and_matches() raises:
    var sizes: List[Int] = [300, 1, 0, 211, 17, 64]
    var total = _total(sizes)
    assert_true(total < 1024, "e4 fixture must stay under the parallel floor")
    for sliced in range(2):
        grain_geometry_reset()
        var out = _drive(_batches(sizes, sliced == 1), ConcatOptions())
        _expect_route(String("e4 serial"), _SERIAL)
        _assert_matches_generator(
            String("e4 serial sliced=") + String(sliced), out, total
        )


def test_e5_tiled_destroy_recreate_soak() raises:
    """Ten fresh pools in a row, each torn down after one forced-tile concat of
    the multi-column fixture, residues and slicing varied per iteration."""
    for it in range(10):
        var label = String("e5 iteration ") + String(it)
        var sizes = _ragged_sizes(it % 3)
        grain_geometry_reset()
        var out = _drive(
            _batches(sizes, it % 2 == 1), ConcatOptions(force_tiles=True)
        )
        _expect_route(label, _TILED_3)
        _assert_matches_generator(label, out, _total(sizes))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
