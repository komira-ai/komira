# =============================================================================
# The chunked INNER join kernel against the fused one.
#
# Both emit rows in probe-row order and, within a probe row, in chain order
# (the chunked kernel flattens each bucket in chain order), so their outputs
# must be equal row for row. The cases cross the 65,536-pair chunk boundary,
# outgrow the first output buffer (an estimate from the mean bucket length
# that a skewed key defeats), skip NULL probe keys with the hand-advanced
# cursor, and probe a builder that has no bloom filter at low occupancy.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import (
    Field,
    RecordBatch,
    RecordBatchBuilder,
    Schema,
    SchemaBuilder,
)
from komira_buffer.heap_region import HeapRegion
from komira_op_join_build.join import HashJoinBuilder
from komira_op_join_build.join_probe_null_mask import ProbeNullMask

from komira_op_fused_kernels.join_chunked_gather import assemble_inner_join_chunked
from komira_op_fused_kernels.join_fused_gather import assemble_inner_join_fused


def _col(at: ArrowType, vals: List[Int]) raises -> Column[HeapRegion]:
    var n = len(vals)
    if at == ArrowType.INT64:
        var a = PrimitiveArray[DType.int64].allocate(n)
        for i in range(n):
            a.store[1](i, SIMD[DType.int64, 1](Int64(vals[i])))
        return Column.from_primitive[DType.int64](a^)
    if at == ArrowType.INT32:
        var a = PrimitiveArray[DType.int32].allocate(n)
        for i in range(n):
            a.store[1](i, SIMD[DType.int32, 1](Int32(vals[i])))
        return Column.from_primitive[DType.int32](a^)
    if at == ArrowType.INT16:
        var a = PrimitiveArray[DType.int16].allocate(n)
        for i in range(n):
            a.store[1](i, SIMD[DType.int16, 1](Int16(vals[i])))
        return Column.from_primitive[DType.int16](a^)
    if at == ArrowType.FLOAT64:
        var a = PrimitiveArray[DType.float64].allocate(n)
        for i in range(n):
            a.store[1](i, SIMD[DType.float64, 1](Float64(vals[i])))
        return Column.from_primitive[DType.float64](a^)
    raise Error("fixture: unsupported type")


def _cell(batch: RecordBatch, c: Int, r: Int) raises -> Int:
    ref col = batch.column_at(c)
    var at = col.arrow_type
    if at == ArrowType.INT64:
        return Int(col.as_primitive[DType.int64]().get(r))
    if at == ArrowType.INT32:
        return Int(col.as_primitive[DType.int32]().get(r))
    if at == ArrowType.INT16:
        return Int(col.as_primitive[DType.int16]().get(r))
    if at == ArrowType.FLOAT64:
        return Int(col.as_primitive[DType.float64]().get(r))
    raise Error("cell: unsupported type")


def _key_array(vals: List[Int]) -> PrimitiveArray[DType.int64]:
    var a = PrimitiveArray[DType.int64].allocate(len(vals))
    for i in range(len(vals)):
        a.store[1](i, SIMD[DType.int64, 1](Int64(vals[i])))
    return a^


def _left(keys: List[Int]) raises -> RecordBatch:
    """Probe side: id INT64 (the key), a INT32 = 10*row, b INT16 = row,
    x FLOAT64 = 1000 + row. Field `a` carries metadata."""
    var n = len(keys)
    var a = List[Int]()
    var b = List[Int]()
    var x = List[Int]()
    for i in range(n):
        a.append(10 * i)
        b.append(i)
        x.append(1000 + i)
    var sb = SchemaBuilder()
    sb.add_field(Field("id", ArrowType.INT64, False))
    var fa = Field("a", ArrowType.INT32, False)
    fa.set_metadata("origin", "probe")
    sb.add_field(fa^)
    sb.add_field(Field("b", ArrowType.INT16, False))
    sb.add_field(Field("x", ArrowType.FLOAT64, False))
    var rb = RecordBatchBuilder()
    rb.add_column(_col(ArrowType.INT64, keys))
    rb.add_column(_col(ArrowType.INT32, a))
    rb.add_column(_col(ArrowType.INT16, b))
    rb.add_column(_col(ArrowType.FLOAT64, x))
    return rb.build(sb.build())


def _right(keys: List[Int]) raises -> RecordBatch:
    """Build side: id INT64 (the key), c INT64 = 7*row + 1, d INT32 = -row."""
    var n = len(keys)
    var c = List[Int]()
    var d = List[Int]()
    for i in range(n):
        c.append(7 * i + 1)
        d.append(-i)
    var sb = SchemaBuilder()
    sb.add_field(Field("id", ArrowType.INT64, False))
    sb.add_field(Field("c", ArrowType.INT64, False))
    sb.add_field(Field("d", ArrowType.INT32, False))
    var rb = RecordBatchBuilder()
    rb.add_column(_col(ArrowType.INT64, keys))
    rb.add_column(_col(ArrowType.INT64, c))
    rb.add_column(_col(ArrowType.INT32, d))
    return rb.build(sb.build())


def _out_schema() -> Schema:
    """All seven columns, the right key renamed `id_right`."""
    var sb = SchemaBuilder()
    sb.add_field(Field("id", ArrowType.INT64, False))
    sb.add_field(Field("a", ArrowType.INT32, False))
    sb.add_field(Field("b", ArrowType.INT16, False))
    sb.add_field(Field("x", ArrowType.FLOAT64, False))
    sb.add_field(Field("id_right", ArrowType.INT64, False))
    sb.add_field(Field("c", ArrowType.INT64, False))
    sb.add_field(Field("d", ArrowType.INT32, False))
    return sb.build()


def _dup_keys(n: Int, modulus: Int) -> List[Int]:
    var k = List[Int]()
    for i in range(n):
        k.append(i % modulus)
    return k^


def _assert_full_equals_reference(
    got: RecordBatch,
    left: RecordBatch,
    right: RecordBatch,
    jb: HashJoinBuilder,
    probe: PrimitiveArray[DType.int64],
) raises:
    var pairs = jb.probe_inner(probe)
    var n = len(pairs[0])
    assert_equal(got.num_rows(), n)
    assert_equal(got.num_columns(), left.num_columns() + right.num_columns())
    for r in range(n):
        var b = pairs[0][r]
        var p = pairs[1][r]
        for c in range(left.num_columns()):
            assert_equal(_cell(got, c, r), _cell(left, c, p), "left cell")
        for c in range(right.num_columns()):
            assert_equal(
                _cell(got, left.num_columns() + c, r), _cell(right, c, b), "right cell"
            )


def _nullable_keys(vals: List[Int], null_rows: List[Int]) -> PrimitiveArray[DType.int64]:
    var a = PrimitiveArray[DType.int64].allocate_nullable(len(vals))
    for i in range(len(vals)):
        a.store[1](i, SIMD[DType.int64, 1](Int64(vals[i])))
    for i in range(len(null_rows)):
        a._set_null(null_rows[i])
    return a^


def _with_null_cell(batch: RecordBatch, col: Int, row: Int) raises -> RecordBatch:
    """`batch` with cell (`row`, `col`) of an INT64 or INT32 column NULL."""
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    for c in range(batch.num_columns()):
        var f = batch.schema.field_at(c)
        if c == col:
            f.nullable = True
            ref src = batch.column_at(c)
            if src.arrow_type == ArrowType.INT64:
                var a = PrimitiveArray[DType.int64].allocate_nullable(batch.num_rows())
                for r in range(batch.num_rows()):
                    a.store[1](r, src.as_primitive[DType.int64]().get(r))
                a._set_null(row)
                rb.add_column(Column.from_primitive[DType.int64](a^))
            else:
                var a = PrimitiveArray[DType.int32].allocate_nullable(batch.num_rows())
                for r in range(batch.num_rows()):
                    a.store[1](r, src.as_primitive[DType.int32]().get(r))
                a._set_null(row)
                rb.add_column(Column.from_primitive[DType.int32](a^))
        else:
            rb.add_column(batch.column_at(c).slice(0, batch.num_rows()))
        sb.add_field(f^)
    return rb.build(sb.build())


def _assert_same(a: RecordBatch, b: RecordBatch) raises:
    assert_equal(a.num_rows(), b.num_rows())
    assert_equal(a.num_columns(), b.num_columns())
    for c in range(a.num_columns()):
        assert_equal(a.schema.field_name(c), b.schema.field_name(c))
        assert_true(a.schema.field_arrow_type(c) == b.schema.field_arrow_type(c))
        for r in range(a.num_rows()):
            assert_equal(_cell(a, c, r), _cell(b, c, r))


def _run(
    lk: List[Int], rk: List[Int], nobi: Bool, fused: Bool, bloom: Bool
) raises -> Int:
    var left = _left(lk)
    var right = _right(rk)
    var probe = _key_array(lk)
    var jb = HashJoinBuilder.build(
        _key_array(rk), build_bloom=bloom, nobi=nobi, fused=fused
    )
    var chunked = assemble_inner_join_chunked(
        left, right, jb, probe, _out_schema(), ProbeNullMask(probe, probe.length)
    )
    var fused_out = assemble_inner_join_fused(
        left, right, jb, probe, _out_schema(), ProbeNullMask(probe, probe.length)
    )
    _assert_same(chunked, fused_out)
    return chunked.num_rows()


def test_chunked_equals_fused_on_every_layout() raises:
    var lk = _dup_keys(500, 13)
    var rk = _dup_keys(48, 12)
    # 12 of 13 probe keys match 4 build rows each.
    var expect = 0
    for i in range(500):
        if i % 13 < 12:
            expect += 4
    assert_equal(_run(lk, rk, False, False, True), expect)
    assert_equal(_run(lk, rk, True, False, True), expect)
    assert_equal(_run(lk, rk, False, True, True), expect)
    assert_equal(_run(lk, rk, True, True, True), expect)


def test_chunked_crosses_chunks_and_regrows() raises:
    """Build key 0 has 50 rows, keys 1..49 one each: the mean bucket length
    is about 2, so the first buffer holds about 2 rows per probe row. Every
    probe row has key 0 and matches 50: 2,000 probe rows give 100,000 rows,
    past one 65,536-pair chunk and several buffer doublings."""
    var rk = List[Int]()
    for _ in range(50):
        rk.append(0)
    for k in range(1, 50):
        rk.append(k)
    var lk = List[Int]()
    for _ in range(2000):
        lk.append(0)
    assert_equal(_run(lk, rk, True, True, True), 100_000)


def test_chunked_without_bloom_at_low_occupancy() raises:
    """5 distinct build keys in a much larger table: occupancy is low, so the
    bloom would be consulted, but the builder has none (its placeholder has a
    NULL buffer). The kernel must not read it."""
    var rk = _dup_keys(20, 5)
    var lk = _dup_keys(100, 7)
    var expect = 0
    for i in range(100):
        if i % 7 < 5:
            expect += 4
    assert_equal(_run(lk, rk, True, True, False), expect)


def test_chunked_null_probe_keys_match_nothing() raises:
    """NULL probe keys (value 0, a real build key) emit nothing, and each one
    advances the cursor: a NULL in every row of the input still ends."""
    var lk = _dup_keys(30, 3)
    var left = _left(lk)
    var right = _right([0, 1, 2])
    var nulls = List[Int]()
    for i in range(0, 30, 2):
        nulls.append(i)
    var probe = _nullable_keys(lk, nulls)
    var jb = HashJoinBuilder.build(_key_array([0, 1, 2]))
    var got = assemble_inner_join_chunked(
        left, right, jb, probe, _out_schema(), ProbeNullMask(probe, probe.length)
    )
    assert_equal(got.num_rows(), 15)
    for r in range(15):
        assert_equal(_cell(got, 2, r), 2 * r + 1)  # probe row 2r + 1
    var all_null = List[Int]()
    for i in range(30):
        all_null.append(i)
    var probe2 = _nullable_keys(lk, all_null)
    var out2 = assemble_inner_join_chunked(
        left, right, jb, probe2, _out_schema(), ProbeNullMask(probe2, probe2.length)
    )
    assert_equal(out2.num_rows(), 0)
    assert_equal(out2.num_columns(), 7)


def test_chunked_no_match_and_empty_probe() raises:
    assert_equal(_run([1, 2, 3], [7, 8], True, True, True), 0)
    assert_equal(_run(List[Int](), [7, 8], True, True, True), 0)


def test_chunked_raises_on_a_null_cell() raises:
    var left = _with_null_cell(_left([1, 2]), 0, 1)
    var right = _right([1, 2])
    var probe = _key_array([1, 2])
    var jb = HashJoinBuilder.build(_key_array([1, 2]))
    var raised = False
    try:
        _ = assemble_inner_join_chunked(
            left, right, jb, probe, _out_schema(), ProbeNullMask(probe, probe.length)
        )
    except e:
        raised = True
        assert_true("'id'" in String(e), String(e))
    assert_true(raised, "a NULL cell was copied as a value")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
