# =============================================================================
# Tests for row_udf.mojo (the row filter / row map carriers and their
# identity) and the row builders of row_builder.mojo they read through.
#
# Fixture: a row struct with one field of each of the ten fixed-width numeric
# types, over a batch of ten columns built with NULLs at base rows 3 and 9 and
# SLICED to base rows [2, 10): logical row j is base row j + 2, so every read
# crosses a column `_offset` of 2; logical rows 1 and 7 are NULL. Each column's
# base value is a different function of the base row r (signed columns go
# negative, unsigned ones sit near their type's top), so reading a field from
# the wrong column or the wrong row changes the answer. Null slots are never
# asserted on: the row builders do not consult validity (the engine's
# `NullHandling` does), so a value read at a NULL row is not an answer.
#
# Oracles: the published FNV-1a 32-bit vectors ("" -> 0x811C9DC5, "a" ->
# 0xE40C292C, "foobar" -> 0xBF9CF968); the docstrings' identity format
# (`kind(in->out)` plus `#id` only when an id is given; a derived id is
# 10000 + fnv % 4294957295, so never below 10000 and never wrapping); and
# values worked out from the fixture's definition.
#
# What each test proves (and the defect it catches):
#   - test_fnv1a_vectors / test_row_udf_id_of: the hash on the published
#     vectors, and the id formula on a string whose hash is ABOVE the modulus
#     ("k477322", hash 4294959721 -> id 12426): dropping the modulo wraps
#     (10000 + 4294959721) mod 2^32 to 2425, below the reserved floor.
#   - test_signatures: the rendered identity strings, field by field, and that
#     an id is appended only when non-empty.
#   - test_row_projection / test_row_field_dtype: declared field order; each
#     of the ten type arms (a swapped pair such as int16/uint16 is caught).
#   - test_build_row_n_reads_offset_columns: `_build_row_n` field k from
#     column k at the offset row, for every valid row and every type.
#   - test_read_row_field: reading each field back by offset.
#   - test_row_filter_udf / test_row_filter_eval_blocks: keep_row and
#     eval_scalar agree with the predicate on every valid row; the default
#     eval[W] at W = 4 for a block fully inside, a block ending exactly at
#     n = 8 (a multiple of W), a block starting at n, and partial blocks,
#     lanes past n always False. Only W = 4 is instantiated, in this file and
#     in test_row_views: the branch classifier cannot sum copies of the
#     default body's unrolled lane loop that hold different lane counts.
#   - test_row_map_udf: ARITY, out_dtype_at for each slot, both derived
#     schemas, apply on every valid row, and the derived ids: map vs filter vs
#     an id-disambiguated map are three different ids.
#   - test_map_fn_rt_int32_float32_project_one: MapFnRT's int32 and float32
#     input arms through write_one AND project_one (slot dst_k), on the sliced
#     columns; int64/float64 project_one too.
#   - test_row_transform_bind_default_and_out_kind: RowTransform's default
#     `bind` is a no-op for a positional adapter (its read is unchanged after
#     binding to an unrelated resolver), and MapFnRT's channel is NUMERIC.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.batch_view import BatchView, batch_view_over
from komira_arrow.column_builder import ColumnBuilder
from komira_arrow.multi_column_builder import MultiColumnSink, SinkKind
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, SchemaBuilder

from komira_udf.auto_komira_schema import AutoKomiraSchema
from komira_udf.map_fn import MapFn
from komira_udf.column_resolver import ColumnResolver
from komira_udf.map_fn_rt import MapFnRT
from komira_udf.row_transform import RowTransform
from komira_udf.row_builder import _build_row_n, _read_row_field, _row_field_dtype
from komira_udf.row_udf import (
    RowFilterUdf,
    RowMapUdf,
    _fnv1a_32,
    _row_udf_id_of,
    _row_udf_signature_of,
    assert_row_udf_ids_differ,
    row_filter_udf_signature,
    row_map_udf_signature,
    row_projection,
    row_type_signature,
)
from komira_udf.schema_descriptor import (
    DT_F32,
    DT_F64,
    DT_I16,
    DT_I32,
    DT_I64,
    DT_I8,
    DT_U16,
    DT_U32,
    DT_U64,
    DT_U8,
    schema_of,
)


# -----------------------------------------------------------------------------
# Fixture
# -----------------------------------------------------------------------------

comptime BASE = 12
comptime START = 2
comptime N = 8  # rows in the slice; a multiple of 4 and of 8


def _null_base(r: Int) -> Bool:
    return r == 3 or r == 9


def _valid(j: Int) -> Bool:
    return not _null_base(j + START)


@fieldwise_init
struct _AllNum(AutoKomiraSchema, Copyable, Movable):
    var f_i8: Int8
    var f_i16: Int16
    var f_i32: Int32
    var f_i64: Int64
    var f_u8: UInt8
    var f_u16: UInt16
    var f_u32: UInt32
    var f_u64: UInt64
    var f_f32: Float32
    var f_f64: Float64


# The base value of each column at base row r: the fixture's definition and
# the oracle every expected value below is computed from.
def _v_i8(r: Int) -> Int8:
    return Int8(r - 6)


def _v_i16(r: Int) -> Int16:
    return Int16(300 * r - 1000)


def _v_i32(r: Int) -> Int32:
    return Int32(r * 100000 - 70000)


def _v_i64(r: Int) -> Int64:
    return Int64(r) * 10_000_000_000 - 3


def _v_u8(r: Int) -> UInt8:
    return UInt8(250 - r)


def _v_u16(r: Int) -> UInt16:
    return UInt16(60000 + r)


def _v_u32(r: Int) -> UInt32:
    return UInt32(4_000_000_000) + UInt32(r)


def _v_u64(r: Int) -> UInt64:
    return UInt64(18_000_000_000_000_000_000) + UInt64(r)


def _v_f32(r: Int) -> Float32:
    return Float32(r) * 0.5 - 1.0


def _v_f64(r: Int) -> Float64:
    return Float64(r) * 1.5 + 0.125


def _row_at(j: Int) -> _AllNum:
    var r = j + START
    return _AllNum(
        _v_i8(r), _v_i16(r), _v_i32(r), _v_i64(r), _v_u8(r), _v_u16(r),
        _v_u32(r), _v_u64(r), _v_f32(r), _v_f64(r),
    )


def _add_col[dt: DType](mut rb: RecordBatchBuilder, vals: List[Scalar[dt]]) raises:
    var b = ColumnBuilder[dt].with_capacity(len(vals))
    for r in range(len(vals)):
        if _null_base(r):
            b.append_null()
        else:
            b.append(vals[r])
    rb.add_column(b^.materialize().slice(START, N))


def _batch() raises -> RecordBatch:
    var i8 = List[Int8]()
    var i16 = List[Int16]()
    var i32 = List[Int32]()
    var i64 = List[Int64]()
    var u8 = List[UInt8]()
    var u16 = List[UInt16]()
    var u32 = List[UInt32]()
    var u64 = List[UInt64]()
    var f32 = List[Float32]()
    var f64 = List[Float64]()
    for r in range(BASE):
        i8.append(_v_i8(r))
        i16.append(_v_i16(r))
        i32.append(_v_i32(r))
        i64.append(_v_i64(r))
        u8.append(_v_u8(r))
        u16.append(_v_u16(r))
        u32.append(_v_u32(r))
        u64.append(_v_u64(r))
        f32.append(_v_f32(r))
        f64.append(_v_f64(r))
    var rb = RecordBatchBuilder()
    _add_col[DType.int8](rb, i8)
    _add_col[DType.int16](rb, i16)
    _add_col[DType.int32](rb, i32)
    _add_col[DType.int64](rb, i64)
    _add_col[DType.uint8](rb, u8)
    _add_col[DType.uint16](rb, u16)
    _add_col[DType.uint32](rb, u32)
    _add_col[DType.uint64](rb, u64)
    _add_col[DType.float32](rb, f32)
    _add_col[DType.float64](rb, f64)
    var sb = SchemaBuilder()
    sb.add_field(Field("f_i8", DType.int8, True))
    sb.add_field(Field("f_i16", DType.int16, True))
    sb.add_field(Field("f_i32", DType.int32, True))
    sb.add_field(Field("f_i64", DType.int64, True))
    sb.add_field(Field("f_u8", DType.uint8, True))
    sb.add_field(Field("f_u16", DType.uint16, True))
    sb.add_field(Field("f_u32", DType.uint32, True))
    sb.add_field(Field("f_u64", DType.uint64, True))
    sb.add_field(Field("f_f32", DType.float32, True))
    sb.add_field(Field("f_f64", DType.float64, True))
    return rb.build(sb.build())


def _same(a: _AllNum, b: _AllNum, where: String) raises:
    assert_equal(a.f_i8, b.f_i8, where + " f_i8")
    assert_equal(a.f_i16, b.f_i16, where + " f_i16")
    assert_equal(a.f_i32, b.f_i32, where + " f_i32")
    assert_equal(a.f_i64, b.f_i64, where + " f_i64")
    assert_equal(a.f_u8, b.f_u8, where + " f_u8")
    assert_equal(a.f_u16, b.f_u16, where + " f_u16")
    assert_equal(a.f_u32, b.f_u32, where + " f_u32")
    assert_equal(a.f_u64, b.f_u64, where + " f_u64")
    assert_equal(a.f_f32, b.f_f32, where + " f_f32")
    assert_equal(a.f_f64, b.f_f64, where + " f_f64")


# -----------------------------------------------------------------------------
# Identity: hash, id, signatures
# -----------------------------------------------------------------------------


def test_fnv1a_vectors() raises:
    assert_equal(_fnv1a_32(StringSlice("")), UInt32(0x811C9DC5))
    assert_equal(_fnv1a_32(StringSlice("a")), UInt32(0xE40C292C))
    assert_equal(_fnv1a_32(StringSlice("foobar")), UInt32(0xBF9CF968))


def test_row_udf_id_of() raises:
    # 10000 + 0x811C9DC5 (below the modulus, so unchanged by it).
    assert_equal(_row_udf_id_of(String("")), UInt32(10000) + UInt32(0x811C9DC5))
    assert_equal(_row_udf_id_of(String("a")), UInt32(10000) + UInt32(0xE40C292C))
    # A hash above the modulus 4294957295: 4294959721 - 4294957295 = 2426.
    assert_equal(_fnv1a_32(StringSlice("k477322")), UInt32(4294959721))
    assert_equal(_row_udf_id_of(String("k477322")), UInt32(12426))


def test_signatures() raises:
    var s = row_type_signature[_AllNum]()
    assert_true(
        s.endswith(
            "_AllNum{f_i8:int8,f_i16:int16,f_i32:int32,f_i64:int64,"
            "f_u8:uint8,f_u16:uint16,f_u32:uint32,f_u64:uint64,"
            "f_f32:float32,f_f64:float64}"
        ),
        s,
    )
    var one = row_type_signature[_Folded]()
    assert_true(one.endswith("_Folded{a:int64,b:float64,c:uint64,d:int64}"), one)

    assert_equal(
        _row_udf_signature_of(String("k"), String("I"), String("O"), String("")),
        "k(I->O)",
    )
    assert_equal(
        _row_udf_signature_of(String("k"), String("I"), String("O"), String("x")),
        "k(I->O)#x",
    )
    assert_equal(
        row_map_udf_signature[_AllNum, _Folded, ""](),
        "rowmap(" + s + "->" + one + ")",
    )
    assert_equal(
        row_map_udf_signature[_AllNum, _Folded, "v2"](),
        "rowmap(" + s + "->" + one + ")#v2",
    )
    assert_equal(
        row_filter_udf_signature[_AllNum, ""](), "rowfilter(" + s + "->bool)"
    )
    assert_equal(
        row_filter_udf_signature[_AllNum, "p"](), "rowfilter(" + s + "->bool)#p"
    )


def test_row_projection() raises:
    var p = row_projection[_AllNum]()
    var want: List[String] = [
        "f_i8", "f_i16", "f_i32", "f_i64", "f_u8", "f_u16", "f_u32", "f_u64",
        "f_f32", "f_f64",
    ]
    assert_equal(len(p), len(want))
    for k in range(len(want)):
        assert_equal(p[k], want[k])


def test_row_field_dtype() raises:
    assert_equal(_row_field_dtype[Int8](), DType.int8)
    assert_equal(_row_field_dtype[Int16](), DType.int16)
    assert_equal(_row_field_dtype[Int32](), DType.int32)
    assert_equal(_row_field_dtype[Int64](), DType.int64)
    assert_equal(_row_field_dtype[UInt8](), DType.uint8)
    assert_equal(_row_field_dtype[UInt16](), DType.uint16)
    assert_equal(_row_field_dtype[UInt32](), DType.uint32)
    assert_equal(_row_field_dtype[UInt64](), DType.uint64)
    assert_equal(_row_field_dtype[Float32](), DType.float32)
    assert_equal(_row_field_dtype[Float64](), DType.float64)


# -----------------------------------------------------------------------------
# Row builders
# -----------------------------------------------------------------------------


def test_build_row_n_reads_offset_columns() raises:
    var batch = _batch()
    assert_equal(batch.num_rows(), N)
    var view = batch_view_over(batch)
    var checked = 0
    for j in range(N):
        if not _valid(j):
            continue
        var got = _build_row_n[_AllNum, origin_of(batch)](view, j)
        _same(got, _row_at(j), String("row ") + String(j))
        checked += 1
    assert_equal(checked, 6)


def test_read_row_field() raises:
    var o = _row_at(4)
    assert_equal(_read_row_field[_AllNum, 0, DType.int8](o), _v_i8(6))
    assert_equal(_read_row_field[_AllNum, 1, DType.int16](o), _v_i16(6))
    assert_equal(_read_row_field[_AllNum, 2, DType.int32](o), _v_i32(6))
    assert_equal(_read_row_field[_AllNum, 3, DType.int64](o), _v_i64(6))
    assert_equal(_read_row_field[_AllNum, 4, DType.uint8](o), _v_u8(6))
    assert_equal(_read_row_field[_AllNum, 5, DType.uint16](o), _v_u16(6))
    assert_equal(_read_row_field[_AllNum, 6, DType.uint32](o), _v_u32(6))
    assert_equal(_read_row_field[_AllNum, 7, DType.uint64](o), _v_u64(6))
    assert_equal(_read_row_field[_AllNum, 8, DType.float32](o), _v_f32(6))
    assert_equal(_read_row_field[_AllNum, 9, DType.float64](o), _v_f64(6))


# -----------------------------------------------------------------------------
# RowFilterUdf
# -----------------------------------------------------------------------------


def _keep(r: _AllNum) -> Bool:
    """Keep when i8 >= 0 (base row >= 6) and u64 is odd (base row odd)."""
    return r.f_i8 >= 0 and r.f_u64 % 2 == 1


def _want_keep(j: Int) -> Bool:
    var r = j + START
    return r >= 6 and r % 2 == 1


def test_row_filter_udf() raises:
    var batch = _batch()
    var view = batch_view_over(batch)
    var f = RowFilterUdf[_keep]()
    var kept = 0
    for j in range(N):
        if not _valid(j):
            continue
        assert_equal(f.keep_row(_row_at(j)), _want_keep(j), String("keep_row ") + String(j))
        var e = f.eval_scalar(view, j)
        assert_equal(e, _want_keep(j), String("eval_scalar ") + String(j))
        if e:
            kept += 1
    # Valid base rows are 2, 4, 5, 6, 7, 8: only 7 is >= 6 and odd.
    assert_equal(kept, 1)
    var schema = materialize[RowFilterUdf[_keep].InputSchema]()
    assert_equal(schema.num_cols(), 10)
    assert_equal(schema.cols[9].name, "f_f64")
    assert_equal(schema.cols[9].dtype, DT_F64)


def _check_block[
    W: Int, bo: Origin[mut=False]
](mut f: RowFilterUdf[_keep], view: BatchView[bo], i: Int) raises:
    var m = f.eval[W](view, i)
    for lane in range(W):
        var j = i + lane
        var where = String("W=") + String(W) + " i=" + String(i) + " lane " + String(lane)
        if j >= N:
            assert_false(m[lane], where + " past n")
        elif _valid(j):
            assert_equal(m[lane], _want_keep(j), where)


def test_row_filter_eval_blocks() raises:
    var batch = _batch()
    var view = batch_view_over(batch)
    var f = RowFilterUdf[_keep]()
    _check_block[4](f, view, 0)
    _check_block[4](f, view, 4)  # ends exactly at n = 8
    _check_block[4](f, view, 6)  # partial: lanes 2, 3 past n
    _check_block[4](f, view, 8)  # starts at n: every lane False
    _check_block[4](f, view, 5)  # partial, starting off a block boundary
    # The kept row (j = 5) is set in its block, and nothing else among the
    # valid rows.
    var m = f.eval[4](view, 4)
    # Lane 0 is row 4 (base row 6: valid, even, so not kept); lane 2 is row
    # 6 (base row 8, even); lane 3 is row 7, the NULL base row 9 (not
    # asserted: the row builders do not consult validity).
    assert_false(m[0])
    assert_true(m[1])
    assert_false(m[2])


# -----------------------------------------------------------------------------
# RowMapUdf
# -----------------------------------------------------------------------------


@fieldwise_init
struct _Folded(AutoKomiraSchema, Copyable, Movable):
    var a: Int64
    var b: Float64
    var c: UInt64
    var d: Int64


def _fold(r: _AllNum) -> _Folded:
    return _Folded(
        Int64(r.f_i8) + Int64(r.f_i16) + Int64(r.f_i32),
        Float64(r.f_f32) + r.f_f64,
        UInt64(r.f_u8) + UInt64(r.f_u16) + UInt64(r.f_u32) + r.f_u64,
        r.f_i64,
    )


def _fold_again(r: _AllNum) -> _Folded:
    return _Folded(0, 0.0, 0, 0)


def test_row_map_udf() raises:
    comptime M = RowMapUdf[_fold]
    assert_equal(M.ARITY, 4)
    assert_equal(M.out_dtype_at[0](), DType.int64)
    assert_equal(M.out_dtype_at[1](), DType.float64)
    assert_equal(M.out_dtype_at[2](), DType.uint64)
    assert_equal(M.out_dtype_at[3](), DType.int64)
    var ins = materialize[M.InputSchema]()
    assert_equal(ins.num_cols(), 10)
    assert_equal(ins.cols[0].dtype, DT_I8)
    assert_equal(ins.cols[1].dtype, DT_I16)
    assert_equal(ins.cols[2].dtype, DT_I32)
    assert_equal(ins.cols[3].dtype, DT_I64)
    assert_equal(ins.cols[4].dtype, DT_U8)
    assert_equal(ins.cols[5].dtype, DT_U16)
    assert_equal(ins.cols[6].dtype, DT_U32)
    assert_equal(ins.cols[7].dtype, DT_U64)
    assert_equal(ins.cols[8].dtype, DT_F32)
    var outs = materialize[M.OutputSchema]()
    assert_equal(outs.names_joined(), "a, b, c, d")
    assert_equal(outs.cols[2].dtype, DT_U64)

    var batch = _batch()
    var view = batch_view_over(batch)
    var m = M()
    for j in range(N):
        if not _valid(j):
            continue
        var r = j + START
        var got = m.apply(view, j)
        var where = String("apply row ") + String(j)
        assert_equal(got.a, Int64(r - 6) + Int64(300 * r - 1000) + Int64(r * 100000 - 70000), where)
        assert_equal(got.b, Float64(Float32(r) * 0.5 - 1.0) + (Float64(r) * 1.5 + 0.125), where)
        assert_equal(
            got.c,
            UInt64(250 - r) + UInt64(60000 + r) + UInt64(4_000_000_000 + r)
            + UInt64(18_000_000_000_000_000_000) + UInt64(r),
            where,
        )
        assert_equal(got.d, Int64(r) * 10_000_000_000 - 3, where)

    # Identity: map, filter and an id-disambiguated map over the same rows.
    comptime Mx = RowMapUdf[_fold_again, "again"]
    comptime F = RowFilterUdf[_keep]
    assert_equal(M.UDF_SIGNATURE, row_map_udf_signature[_AllNum, _Folded, ""]())
    assert_equal(M.UDF_ID, _row_udf_id_of(M.UDF_SIGNATURE))
    assert_equal(F.UDF_ID, _row_udf_id_of(F.UDF_SIGNATURE))
    assert_equal(Mx.UDF_ID, _row_udf_id_of(Mx.UDF_SIGNATURE))
    assert_true(M.UDF_ID != F.UDF_ID)
    assert_true(M.UDF_ID != Mx.UDF_ID)
    assert_true(M.UDF_ID >= 10000 and F.UDF_ID >= 10000 and Mx.UDF_ID >= 10000)
    assert_row_udf_ids_differ[M.UDF_ID, Mx.UDF_ID, "map vs map#again"]()
    assert_row_udf_ids_differ[M.UDF_ID, F.UDF_ID, "map vs filter"]()
    # Two different functions over the same row types and no id collide,
    # which is exactly what the guard refuses at compile time.
    assert_equal(RowMapUdf[_fold_again].UDF_ID, M.UDF_ID)


# -----------------------------------------------------------------------------
# MapFnRT int32 / float32 arms and project_one
# -----------------------------------------------------------------------------


@fieldwise_init
struct _SlotSink(Movable, MultiColumnSink):
    """Records the slot and value of the last append (as Float64)."""

    var slot: Int
    var value: Float64

    def append_at[k: Int, DT: DType](mut self, value: Scalar[DT]):
        self.slot = k
        self.value = value.cast[DType.float64]()


@fieldwise_init
struct _RowI32(Copyable, Movable):
    var v: Int32


@fieldwise_init
struct _RowF32(Copyable, Movable):
    var v: Float32


@fieldwise_init
struct _RowI64(Copyable, Movable):
    var v: Int64


@fieldwise_init
struct _RowF64(Copyable, Movable):
    var v: Float64


@fieldwise_init
struct _NegI32(MapFn):
    comptime InRow = _RowI32
    comptime InputSchema = schema_of["f_i32", DT_I32]()
    comptime OutputSchema = schema_of["o", DT_I32]()
    comptime OutType = DType.int32
    comptime UDF_ID = UInt32(7_300)

    def run_row(mut self, row: _RowI32) -> Int32:
        return -row.v


@fieldwise_init
struct _TwiceF32(MapFn):
    comptime InRow = _RowF32
    comptime InputSchema = schema_of["f_f32", DT_F32]()
    comptime OutputSchema = schema_of["o", DT_F32]()
    comptime OutType = DType.float32
    comptime UDF_ID = UInt32(7_301)

    def run_row(mut self, row: _RowF32) -> Float32:
        return row.v * 2


@fieldwise_init
struct _IncI64(MapFn):
    comptime InRow = _RowI64
    comptime InputSchema = schema_of["f_i64", DT_I64]()
    comptime OutputSchema = schema_of["o", DT_I64]()
    comptime OutType = DType.int64
    comptime UDF_ID = UInt32(7_302)

    def run_row(mut self, row: _RowI64) -> Int64:
        return row.v + 1


@fieldwise_init
struct _HalfF64(MapFn):
    comptime InRow = _RowF64
    comptime InputSchema = schema_of["f_f64", DT_F64]()
    comptime OutputSchema = schema_of["o", DT_F64]()
    comptime OutType = DType.float64
    comptime UDF_ID = UInt32(7_303)

    def run_row(mut self, row: _RowF64) -> Float64:
        return row.v / 2


def test_map_fn_rt_int32_float32_project_one() raises:
    var batch = _batch()
    var view = batch_view_over(batch)
    var neg = MapFnRT[_NegI32, 2](_NegI32())
    var twice = MapFnRT[_TwiceF32, 8](_TwiceF32())
    var inc = MapFnRT[_IncI64, 3](_IncI64())
    var half = MapFnRT[_HalfF64, 9](_HalfF64())
    assert_equal(MapFnRT[_NegI32, 2].dtype_at[0](), DType.int32)
    assert_equal(MapFnRT[_TwiceF32, 8].dtype_at[0](), DType.float32)
    for j in range(N):
        if not _valid(j):
            continue
        var r = j + START
        var where = String(" row ") + String(j)
        var s = _SlotSink(-1, 0.0)
        neg.write_one(view, j, s)
        assert_equal(s.slot, 0, "i32 write_one slot" + where)
        assert_equal(s.value, Float64(-_v_i32(r)), "i32 write_one" + where)
        neg.project_one[origin_of(batch), 3, _SlotSink](view, j, s)
        assert_equal(s.slot, 3, "i32 project_one slot" + where)
        assert_equal(s.value, Float64(-_v_i32(r)), "i32 project_one" + where)
        twice.write_one(view, j, s)
        assert_equal(s.slot, 0, "f32 write_one slot" + where)
        assert_equal(s.value, Float64(_v_f32(r) * 2), "f32 write_one" + where)
        twice.project_one[origin_of(batch), 1, _SlotSink](view, j, s)
        assert_equal(s.slot, 1, "f32 project_one slot" + where)
        assert_equal(s.value, Float64(_v_f32(r) * 2), "f32 project_one" + where)
        inc.project_one[origin_of(batch), 2, _SlotSink](view, j, s)
        assert_equal(s.slot, 2, "i64 project_one slot" + where)
        assert_equal(s.value, Float64(_v_i64(r) + 1), "i64 project_one" + where)
        half.project_one[origin_of(batch), 5, _SlotSink](view, j, s)
        assert_equal(s.slot, 5, "f64 project_one slot" + where)
        assert_equal(s.value, _v_f64(r) / 2, "f64 project_one" + where)


def _bind_then_write[
    R: RowTransform, bo: Origin[mut=False]
](mut r: R, resolver: ColumnResolver, view: BatchView[bo], i: Int, mut s: _SlotSink) raises:
    """Through the RowTransform trait only: bind, then write one row."""
    r.bind(resolver)
    r.write_one(view, i, s)


def test_row_transform_bind_default_and_out_kind() raises:
    # MapFnRT has no name-keyed leaves: it inherits RowTransform's no-op
    # `bind`, so binding against ANY resolver (here one naming none of the
    # batch's columns) leaves its positional read unchanged.
    var batch = _batch()
    var view = batch_view_over(batch)
    var neg = MapFnRT[_NegI32, 2](_NegI32())
    var s = _SlotSink(-1, 0.0)
    _bind_then_write(neg, ColumnResolver(), view, 0, s)
    assert_equal(s.value, Float64(-_v_i32(START)))
    assert_equal(s.slot, 0)
    # A MapFn returns a Scalar, so the adapter's channel is always NUMERIC.
    assert_true(MapFnRT[_NegI32, 2].out_kind_at[0]() == SinkKind.NUMERIC)
    assert_true(MapFnRT[_TwiceF32, 8].out_kind_at[0]() != SinkKind.STRING)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
