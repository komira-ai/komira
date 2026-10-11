# =============================================================================
# The fused INNER join kernels against an index-pair reference.
#
# The reference is the serial `HashJoinBuilder.probe_inner` pairs gathered
# cell by cell; it walks the same chains in the same order, so the fused
# output must equal it row for row. The inputs mix 8-, 4- and 2-byte columns
# (the typed and the memcpy copy arms), duplicate keys on both sides (so the
# output outgrows its first buffer and is re-grown), sliced columns (a
# non-zero column offset) and every chain-entry layout of the builder.
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

from komira_op_fused_kernels.join_fused_gather import (
    assemble_inner_join_fused,
    assemble_inner_join_fused_projected,
)


# -----------------------------------------------------------------------------
# Fixtures
# -----------------------------------------------------------------------------


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


# -----------------------------------------------------------------------------
# assemble_inner_join_fused
# -----------------------------------------------------------------------------


def _run_full(nobi: Bool, fused: Bool, bloom: Bool) raises:
    # 300 probe rows over 12 keys, 60 build rows over 10 keys: 6 build rows
    # per matching key, so 1500 output rows from a first buffer of 60.
    var lk = _dup_keys(300, 12)
    var rk = _dup_keys(60, 10)
    var left = _left(lk)
    var right = _right(rk)
    var probe = _key_array(lk)
    var jb = HashJoinBuilder.build(
        _key_array(rk), build_bloom=bloom, nobi=nobi, fused=fused
    )
    var got = assemble_inner_join_fused(
        left, right, jb, probe, _out_schema(), ProbeNullMask(probe, probe.length)
    )
    assert_equal(got.num_rows(), 250 * 6)
    _assert_full_equals_reference(got, left, right, jb, probe)


def test_full_split_layout() raises:
    _run_full(False, False, True)


def test_full_fused_nobi_layout() raises:
    _run_full(True, True, True)


def test_full_mixed_layouts_without_bloom() raises:
    _run_full(True, False, False)
    _run_full(False, True, False)


def test_full_names_types_and_metadata() raises:
    var left = _left([1, 2, 3, 2])
    var right = _right([2, 3, 3, 9])
    var probe = _key_array([1, 2, 3, 2])
    var jb = HashJoinBuilder.build(_key_array([2, 3, 3, 9]))
    var got = assemble_inner_join_fused(
        left, right, jb, probe, _out_schema(), ProbeNullMask(probe, probe.length)
    )
    # Probe 1 matches nothing, probe 2 (rows 1, 3) matches build row 0, probe
    # 3 (row 2) matches build rows 1 and 2.
    assert_equal(got.num_rows(), 4)
    var names: List[String] = ["id", "a", "b", "x", "id_right", "c", "d"]
    for c in range(7):
        assert_equal(got.schema.field_name(c), names[c])
    assert_true(got.schema.field_arrow_type(2) == ArrowType.INT16)
    assert_true(got.schema.field_arrow_type(3) == ArrowType.FLOAT64)
    var md = got.schema.field_at(1).get_metadata("origin")
    assert_true(Bool(md))
    assert_equal(md.value(), "probe")
    # Rows in probe-row order.
    assert_equal(_cell(got, 0, 0), 2)
    assert_equal(_cell(got, 1, 0), 10)
    assert_equal(_cell(got, 5, 0), 1)
    var c_of_probe2 = _cell(got, 5, 1) + _cell(got, 5, 2)
    assert_equal(c_of_probe2, (7 * 1 + 1) + (7 * 2 + 1))
    assert_equal(_cell(got, 0, 3), 2)
    assert_equal(_cell(got, 1, 3), 30)
    assert_equal(_cell(got, 3, 3), 1003)


def test_full_output_width_capped_by_schema() raises:
    """The output has min(left + right columns, output schema) columns."""
    var left = _left([5, 6])
    var right = _right([6])
    var probe = _key_array([5, 6])
    var jb = HashJoinBuilder.build(_key_array([6]))
    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.INT64, False))
    sb.add_field(Field("a2", ArrowType.INT32, False))
    var got = assemble_inner_join_fused(
        left, right, jb, probe, sb.build(), ProbeNullMask(probe, probe.length)
    )
    assert_equal(got.num_columns(), 2)
    assert_equal(got.num_rows(), 1)
    assert_equal(got.schema.field_name(0), "k")
    assert_equal(_cell(got, 1, 0), 10)


def test_full_no_match_is_empty() raises:
    var left = _left([1, 2])
    var right = _right([3, 4])
    var probe = _key_array([1, 2])
    var jb = HashJoinBuilder.build(_key_array([3, 4]))
    var got = assemble_inner_join_fused(
        left, right, jb, probe, _out_schema(), ProbeNullMask(probe, probe.length)
    )
    assert_equal(got.num_rows(), 0)
    assert_equal(got.num_columns(), 7)
    assert_true(got.schema.field_arrow_type(6) == ArrowType.INT32)


def test_full_reads_sliced_columns_at_their_offset() raises:
    """Columns sliced from a larger column (offset 3) are read from their
    first logical row, for the typed and the memcpy arms alike."""
    var big = _left([9, 9, 9, 1, 2, 3])
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    for c in range(big.num_columns()):
        sb.add_field(big.schema.field_at(c))
        rb.add_column(big.column_at(c).slice(3, 3))
    var left = rb.build(sb.build())
    var right = _right([3, 1])
    var probe = _key_array([1, 2, 3])
    var jb = HashJoinBuilder.build(_key_array([3, 1]))
    var got = assemble_inner_join_fused(
        left, right, jb, probe, _out_schema(), ProbeNullMask(probe, probe.length)
    )
    assert_equal(got.num_rows(), 2)
    # Probe row 0 (key 1) is source row 3: a = 30, b = 3, x = 1003.
    assert_equal(_cell(got, 0, 0), 1)
    assert_equal(_cell(got, 1, 0), 30)
    assert_equal(_cell(got, 2, 0), 3)
    assert_equal(_cell(got, 3, 0), 1003)
    assert_equal(_cell(got, 5, 0), 8)
    # Probe row 2 (key 3) is source row 5.
    assert_equal(_cell(got, 1, 1), 50)
    assert_equal(_cell(got, 2, 1), 5)
    assert_equal(_cell(got, 5, 1), 1)


def _nullable_keys(vals: List[Int], null_rows: List[Int]) -> PrimitiveArray[DType.int64]:
    var a = PrimitiveArray[DType.int64].allocate_nullable(len(vals))
    for i in range(len(vals)):
        a.store[1](i, SIMD[DType.int64, 1](Int64(vals[i])))
    for i in range(len(null_rows)):
        a._set_null(null_rows[i])
    return a^


def test_full_null_probe_key_matches_nothing() raises:
    """A NULL probe key (its value 0, a real build key) emits no row."""
    var left = _left([0, 1, 0, 1])
    var right = _right([0, 1])
    var probe = _nullable_keys([0, 1, 0, 1], [0, 3])
    var jb = HashJoinBuilder.build(_key_array([0, 1]))
    var got = assemble_inner_join_fused(
        left, right, jb, probe, _out_schema(), ProbeNullMask(probe, probe.length)
    )
    assert_equal(got.num_rows(), 2)
    assert_equal(_cell(got, 2, 0), 1)  # probe row 1
    assert_equal(_cell(got, 2, 1), 2)  # probe row 2


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


def test_full_raises_on_a_null_cell() raises:
    """A NULL payload cell cannot be carried (the output has no validity), so
    the kernel raises instead of emitting the value under the NULL."""
    var left = _with_null_cell(_left([1, 2]), 1, 0)
    var right = _right([1, 2])
    var probe = _key_array([1, 2])
    var jb = HashJoinBuilder.build(_key_array([1, 2]))
    var raised = False
    try:
        _ = assemble_inner_join_fused(
            left, right, jb, probe, _out_schema(), ProbeNullMask(probe, probe.length)
        )
    except e:
        raised = True
        assert_true("'a'" in String(e), String(e))
    assert_true(raised, "a NULL payload cell was copied as a value")

    var right2 = _with_null_cell(_right([1, 2]), 2, 1)
    var raised2 = False
    try:
        _ = assemble_inner_join_fused(
            _left([1, 2]), right2, jb, probe, _out_schema(),
            ProbeNullMask(probe, probe.length),
        )
    except e:
        raised2 = True
        assert_true("'d'" in String(e), String(e))
    assert_true(raised2, "a NULL build-side cell was copied as a value")


# -----------------------------------------------------------------------------
# assemble_inner_join_fused_projected
# -----------------------------------------------------------------------------


def test_projected_selects_in_requested_order() raises:
    var lk = _dup_keys(200, 9)
    var rk = _dup_keys(40, 8)
    var left = _left(lk)
    var right = _right(rk)
    var probe = _key_array(lk)
    var jb = HashJoinBuilder.build(_key_array(rk))
    var names: List[String] = ["c", "b", "id_right", "x", "d"]
    var got = assemble_inner_join_fused_projected(
        left, right, jb, probe, names, left, right, True,
        ProbeNullMask(probe, probe.length),
    )
    var pairs = jb.probe_inner(probe)
    assert_equal(got.num_columns(), 5)
    assert_equal(got.num_rows(), len(pairs[0]))
    for c in range(5):
        assert_equal(got.schema.field_name(c), names[c])
    for r in range(got.num_rows()):
        var b = pairs[0][r]
        var p = pairs[1][r]
        assert_equal(_cell(got, 0, r), _cell(right, 1, b))
        assert_equal(_cell(got, 1, r), _cell(left, 2, p))
        assert_equal(_cell(got, 2, r), _cell(right, 0, b))
        assert_equal(_cell(got, 3, r), _cell(left, 3, p))
        assert_equal(_cell(got, 4, r), _cell(right, 2, b))


def test_projected_flipped_build_side() raises:
    """The table is built on the LEFT and the right side probes it
    (`probe_is_left=False`): left columns are read at the build row, right
    columns at the probe row, and names still resolve against left/right."""
    var lk: List[Int] = [4, 5, 6]
    var rk: List[Int] = [6, 4, 4, 7]
    var left = _left(lk)
    var right = _right(rk)
    var jb = HashJoinBuilder.build(_key_array(lk))
    var probe = _key_array(rk)
    var names: List[String] = ["a", "c", "id"]
    var got = assemble_inner_join_fused_projected(
        right, left, jb, probe, names, left, right, False,
        ProbeNullMask(probe, probe.length),
    )
    var md = got.schema.field_at(0).get_metadata("origin")
    assert_true(Bool(md))
    # Probe (right) rows 0, 1, 2 match left rows 2, 0, 0; right row 3 none.
    assert_equal(got.num_rows(), 3)
    assert_equal(_cell(got, 0, 0), 20)
    assert_equal(_cell(got, 1, 0), 1)
    assert_equal(_cell(got, 2, 0), 6)
    assert_equal(_cell(got, 0, 1), 0)
    assert_equal(_cell(got, 1, 1), 8)
    assert_equal(_cell(got, 0, 2), 0)
    assert_equal(_cell(got, 1, 2), 15)
    assert_equal(_cell(got, 2, 2), 4)


def test_projected_no_columns_counts_matches() raises:
    """With no output names the result is the match count alone (what an
    ungrouped count(*) over the join reads), NULL probe keys excluded."""
    var lk: List[Int] = [0, 1, 1, 2, 0]
    var left = _left(lk)
    var right = _right([0, 1, 1])
    var probe = _nullable_keys(lk, [4])
    var jb = HashJoinBuilder.build(_key_array([0, 1, 1]))
    var got = assemble_inner_join_fused_projected(
        left, right, jb, probe, List[String](), left, right, True,
        ProbeNullMask(probe, probe.length),
    )
    # Row 0 matches 1, rows 1 and 2 match 2 each, row 3 none, row 4 is NULL.
    assert_equal(got.num_rows(), 5)
    assert_equal(got.num_columns(), 0)


def test_projected_null_probe_key_matches_nothing() raises:
    var left = _left([0, 0, 3])
    var right = _right([0, 3])
    var probe = _nullable_keys([0, 0, 3], [1])
    var jb = HashJoinBuilder.build(_key_array([0, 3]))
    var names: List[String] = ["b", "c"]
    var got = assemble_inner_join_fused_projected(
        left, right, jb, probe, names, left, right, True,
        ProbeNullMask(probe, probe.length),
    )
    assert_equal(got.num_rows(), 2)
    assert_equal(_cell(got, 0, 0), 0)
    assert_equal(_cell(got, 0, 1), 2)


def test_projected_raises_only_on_a_selected_null_column() raises:
    var left = _with_null_cell(_left([1, 2]), 1, 1)
    var right = _right([1, 2])
    var probe = _key_array([1, 2])
    var jb = HashJoinBuilder.build(_key_array([1, 2]))
    # `a` holds the NULL but is not selected: no raise, both rows got.
    var names: List[String] = ["b", "c"]
    var got = assemble_inner_join_fused_projected(
        left, right, jb, probe, names, left, right, True,
        ProbeNullMask(probe, probe.length),
    )
    assert_equal(got.num_rows(), 2)
    var with_a: List[String] = ["a", "c"]
    var raised = False
    try:
        _ = assemble_inner_join_fused_projected(
            left, right, jb, probe, with_a, left, right, True,
            ProbeNullMask(probe, probe.length),
        )
    except e:
        raised = True
        assert_true("'a'" in String(e), String(e))
    assert_true(raised, "a selected NULL cell was copied as a value")


def test_projected_unknown_name_raises() raises:
    var left = _left([1])
    var right = _right([1])
    var probe = _key_array([1])
    var jb = HashJoinBuilder.build(_key_array([1]))
    var names: List[String] = ["nope"]
    var raised = False
    try:
        _ = assemble_inner_join_fused_projected(
            left, right, jb, probe, names, left, right, True,
            ProbeNullMask(probe, probe.length),
        )
    except:
        raised = True
    assert_true(raised)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
