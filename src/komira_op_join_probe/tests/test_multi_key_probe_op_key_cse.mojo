# The JOIN-KEY CSE of `MultiKeyJoinProbeOp`: an INNER composite join may emit
# its build key columns by sharing the probe key columns instead of gathering
# them. A correct share is invisible in the values, so each test checks:
#   * the counters of `komira_join_assembly.join_key_cse` as EXACT counts
#     (shared, gathered, declines): a zero alone cannot tell "refused" from
#     "never ran";
#   * the output against the no-share output (`key_cse=False`) PHYSICALLY:
#     type, length, NULL count, offset, validity and offsets presence, and the
#     raw data and offsets bytes, which differ when a share emits the wrong
#     column shape with the right values.
# The map is per key: key 0 may decline while key 1 shares (partial cases),
# and each later morsel is re-checked against the facts the first one proved
# (drift cases); a drifted morsel gathers all three build columns.
#
# Fixture: probe (pk0, pk1, pv) 8 rows, build (bk0, bk1, bv) 5 rows, keys
# (pk0, pk1) = (bk0, bk1); 6 output rows. Probe row 1 (99, 9) matches
# nothing, so a NULL put there changes no output row.

from std.memory import ArcPointer
from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_arrow.string_array import StringArray
from komira_buffer.heap_region import HeapRegion
from komira_join_assembly.join_key_cse import (
    join_key_cse_declines,
    join_key_cse_gathered_columns,
    join_key_cse_shared_bytes,
    join_key_cse_shared_columns,
    reset_join_key_cse_counters,
)
from komira_morsel.morsel import Morsel
from komira_plan_ir.logical_plan import JOIN_INNER, JOIN_LEFT

from komira_op_join_probe.join_key_extract import extract_join_key_columns_serial
from komira_op_join_probe.join_multi_key_builder import MultiKeyHashJoinBuilder
from komira_op_join_probe.multi_key_probe_op import MultiKeyJoinProbeOp


comptime _ROWS = 6
comptime NO_BITMAP = -2
comptime BITMAP_NO_NULL = -1


def _i64(values: List[Int64], bitmap: Int = NO_BITMAP) raises -> Column[HeapRegion]:
    """INT64 values; `bitmap` NO_BITMAP: no validity bitmap; BITMAP_NO_NULL:
    a bitmap and no NULL; `i >= 0`: a bitmap with row `i` NULL."""
    var arr = PrimitiveArray[DType.int64].from_list(
        values
    ) if bitmap == NO_BITMAP else PrimitiveArray[DType.int64].allocate_nullable(len(values))
    if bitmap != NO_BITMAP:
        for i in range(len(values)):
            arr._typed_ptr_mut()[i] = values[i]
        if bitmap >= 0:
            arr._set_null(bitmap)
    return Column.from_primitive[DType.int64](arr^)


def _i32(values: List[Int64]) raises -> Column[HeapRegion]:
    """The same values as INT32 (the composite extraction widens them back,
    so the join's rows are unchanged)."""
    var arr = PrimitiveArray[DType.int32].allocate(len(values))
    for i in range(len(values)):
        arr._typed_ptr_mut()[i] = Int32(Int(values[i]))
    return Column.from_primitive[DType.int32](arr^)


def _batch(
    names: List[String], types: List[ArrowType], var cols: List[Column[HeapRegion]]
) raises -> RecordBatch:
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    for i in range(len(names)):
        sb.add_field(Field(names[i], types[i], True))
    while len(cols) > 0:
        rb.add_column(cols.pop(0))
    return rb.build(sb.build())


def _bk0() -> List[Int64]:
    return [10, 20, 30, 40, 50]


def _bk1() -> List[Int64]:
    return [1, 2, 3, 4, 5]


def _pk0() -> List[Int64]:
    return [30, 99, 20, 30, 50, 10, 40, 30]


def _pk1() -> List[Int64]:
    return [3, 9, 2, 4, 5, 1, 4, 3]


def _pv() -> List[Int64]:
    return [1000, 1001, 1002, 1003, 1004, 1005, 1006, 1007]


comptime I = ArrowType.INT64


def _probe(var k0: Column[HeapRegion], k0_type: ArrowType = I) raises -> RecordBatch:
    var cols = List[Column[HeapRegion]]()
    cols.append(k0^)
    cols.append(_i64(_pk1()))
    cols.append(_i64(_pv()))
    return _batch(["pk0", "pk1", "pv"], [k0_type, I, I], cols^)


def _build(var k0: Column[HeapRegion], k0_type: ArrowType = I) raises -> RecordBatch:
    var cols = List[Column[HeapRegion]]()
    cols.append(k0^)
    cols.append(_i64(_bk1()))
    cols.append(_i64([100, 200, 300, 400, 500]))
    return _batch(["bk0", "bk1", "bv"], [k0_type, I, I], cols^)


def _out_schema(imm probe: Schema, imm build: Schema) raises -> Schema:
    var sb = SchemaBuilder()
    for i in range(probe.num_columns()):
        sb.add_field(Field("p_" + probe.field_name(i), probe.field_arrow_type(i), True))
    for i in range(build.num_columns()):
        sb.add_field(Field("b_" + build.field_name(i), build.field_arrow_type(i), True))
    return sb.build()


def _op(
    var build: RecordBatch,
    imm probe_schema: Schema,
    key_cse: Bool = True,
    op_build_keys: List[String] = ["bk0", "bk1"],
) raises -> MultiKeyJoinProbeOp:
    """The operator over a table built on (bk0, bk1); `op_build_keys` is what
    the operator is told (the CSE proves from it)."""
    var builder = MultiKeyHashJoinBuilder.build(
        extract_join_key_columns_serial(build, ["bk0", "bk1"])
    )
    var schema = _out_schema(probe_schema, build.schema)
    return MultiKeyJoinProbeOp(
        ArcPointer[MultiKeyHashJoinBuilder](builder^),
        ArcPointer[RecordBatch](build^),
        ["pk0", "pk1"],
        op_build_keys.copy(),
        ArcPointer[Schema](schema^),
        JOIN_INNER,
        key_cse=key_cse,
    )


def _counts(shared: Int, gathered: Int, declines: Int, what: String) raises:
    assert_equal(join_key_cse_shared_columns(), shared, what + ": shared")
    assert_equal(join_key_cse_gathered_columns(), gathered, what + ": gathered")
    assert_equal(join_key_cse_declines(), declines, what + ": declines")


def _same_column(imm a: RecordBatch, imm b: RecordBatch, c: Int, what: String) raises:
    ref ca = a.column_at(c)
    ref cb = b.column_at(c)
    var w = what + ": column " + String(c)
    assert_true(ca.arrow_type == cb.arrow_type, w + " type")
    assert_equal(ca._length, cb._length, w + " length")
    assert_equal(ca._null_count, cb._null_count, w + " NULL count")
    assert_equal(ca._offset, cb._offset, w + " offset")
    assert_equal(Bool(ca._validity), Bool(cb._validity), w + " validity presence")
    assert_equal(Bool(ca._offsets), Bool(cb._offsets), w + " offsets presence")
    var da = ca._data.view_ro()
    var db = cb._data.view_ro()
    assert_equal(da.len(), db.len(), w + " data bytes")
    for i in range(da.len()):
        assert_equal(da.get_typed[UInt8](i), db.get_typed[UInt8](i), w + " data byte")
    if ca._offsets:
        var oa = ca._offsets.value().view_ro()
        var ob = cb._offsets.value().view_ro()
        assert_equal(oa.len(), ob.len(), w + " offsets bytes")
        for i in range(oa.len()):
            assert_equal(oa.get_typed[UInt8](i), ob.get_typed[UInt8](i), w + " offsets byte")


def _same_batch(imm a: RecordBatch, imm b: RecordBatch, what: String) raises:
    assert_equal(a.num_rows(), b.num_rows(), what + ": rows")
    assert_equal(a.num_columns(), b.num_columns(), what + ": columns")
    for c in range(a.num_columns()):
        _same_column(a, b, c, what)


def _run(mut op: MultiKeyJoinProbeOp, var probe: RecordBatch) raises -> RecordBatch:
    var m = Morsel(probe^, 0, 0, 0)
    _ = op.execute(m)
    return m^.take_batch()


def _i64_at(imm b: RecordBatch, c: Int, r: Int) raises -> Int64:
    return b.column_at(c).as_primitive[DType.int64]().get(r)


def test_both_keys_share_and_the_output_is_physically_the_gather() raises:
    """Both INT64 keys share (2 columns, 6 rows x 8 bytes each); off, all 3
    build columns are gathered; the two outputs are physically identical, and
    each row's probe keys equal its build keys."""
    reset_join_key_cse_counters()
    var off_op = _op(_build(_i64(_bk0())), _probe(_i64(_pk0())).schema, key_cse=False)
    var off = _run(off_op, _probe(_i64(_pk0())))
    _counts(0, 3, 0, "off")
    reset_join_key_cse_counters()
    var on_op = _op(_build(_i64(_bk0())), _probe(_i64(_pk0())).schema)
    var on = _run(on_op, _probe(_i64(_pk0())))
    _counts(2, 1, 0, "on")
    assert_equal(join_key_cse_shared_bytes(), _ROWS * 8 * 2, "shared bytes")
    assert_equal(on.num_rows(), _ROWS, "rows")
    _same_batch(on, off, "on vs off")
    for r in range(_ROWS):
        assert_equal(_i64_at(on, 0, r), _i64_at(on, 3, r), "key 0 agrees")
        assert_equal(_i64_at(on, 1, r), _i64_at(on, 4, r), "key 1 agrees")
    assert_false(Bool(on.column_at(3)._validity), "a shared key grew a bitmap")


def test_string_key_shares_its_offsets_byte_for_byte() raises:
    """Key 0 STRING, key 1 INT64: both share, and the shared STRING column's
    offsets are the bytes the gather rebuilds."""
    var bs: List[String] = ["alpha", "bravo", "charlie", "delta", "echo"]
    var ps: List[String] = [
        "charlie", "zulu", "bravo", "charlie", "echo", "alpha", "delta", "charlie"
    ]
    var S = ArrowType.STRING
    reset_join_key_cse_counters()
    var off_op = _op(
        _build(Column.from_string(StringArray.from_strings(bs)), S),
        _probe(Column.from_string(StringArray.from_strings(ps)), S).schema,
        key_cse=False,
    )
    var off = _run(off_op, _probe(Column.from_string(StringArray.from_strings(ps)), S))
    _counts(0, 3, 0, "STRING off")
    reset_join_key_cse_counters()
    var on_op = _op(
        _build(Column.from_string(StringArray.from_strings(bs)), S),
        _probe(Column.from_string(StringArray.from_strings(ps)), S).schema,
    )
    var on = _run(on_op, _probe(Column.from_string(StringArray.from_strings(ps)), S))
    _counts(2, 1, 0, "STRING on")
    assert_equal(on.num_rows(), _ROWS, "rows")
    _same_batch(on, off, "STRING on vs off")


def _partial(var build: RecordBatch, var probe: RecordBatch, what: String) raises:
    """Key 0 declines, key 1 shares: exactly 1 shared, 2 gathered, 1 decline,
    the join's 6 rows, and the shared key 1 equal to the probe's."""
    reset_join_key_cse_counters()
    var op = _op(build^, probe.schema)
    var out = _run(op, probe^)
    _counts(1, 2, 1, what)
    assert_equal(out.num_rows(), _ROWS, what + ": rows")
    assert_false(Bool(out.column_at(4)._validity), what + ": shared bitmap")
    for r in range(_ROWS):
        assert_equal(_i64_at(out, 1, r), _i64_at(out, 4, r), what + ": key 1")


def test_partial_probe_bitmap_shape() raises:
    """Key 0's probe column has a bitmap (no NULL), its build column none."""
    _partial(_build(_i64(_bk0())), _probe(_i64(_pk0(), BITMAP_NO_NULL)), "bitmap shape")


def test_partial_probe_null() raises:
    """Both key 0 columns have a bitmap; the probe's holds a NULL (row 1)."""
    _partial(
        _build(_i64(_bk0(), BITMAP_NO_NULL)), _probe(_i64(_pk0(), 1)), "probe NULL"
    )


def test_partial_int32_build_key() raises:
    """Key 0's build column is INT32: the same rows join, the types differ."""
    _partial(_build(_i32(_bk0()), ArrowType.INT32), _probe(_i64(_pk0())), "INT32 build key")


def _drift(var build: RecordBatch, var first: RecordBatch, var second: RecordBatch, what: String) raises:
    """`first` proves the map (2 shared, 1 gathered); `second` must share
    nothing and gather all 3 build columns, and still join its 6 rows."""
    reset_join_key_cse_counters()
    var op = _op(build^, first.schema)
    var a = _run(op, first^)
    assert_equal(join_key_cse_shared_columns(), 2, what + ": the first morsel proves")
    assert_equal(join_key_cse_gathered_columns(), 1, what + ": the first morsel proves")
    assert_equal(a.num_rows(), _ROWS, what + ": first rows")
    var b = _run(op, second^)
    _counts(2, 4, 0, what + ": the second morsel")
    assert_equal(b.num_rows(), _ROWS, what + ": second rows")


def test_drift_key_column_moved() raises:
    """The second morsel has the same columns in another order (pk0 moves
    from index 0 to 2); count, types and bitmaps unchanged."""
    var cols = List[Column[HeapRegion]]()
    cols.append(_i64(_pv()))
    cols.append(_i64(_pk1()))
    cols.append(_i64(_pk0()))
    _drift(
        _build(_i64(_bk0())), _probe(_i64(_pk0())),
        _batch(["pv", "pk1", "pk0"], [I, I, I], cols^), "key moved",
    )


def test_drift_column_count() raises:
    """The second morsel drops the trailing payload column."""
    var cols = List[Column[HeapRegion]]()
    cols.append(_i64(_pk0()))
    cols.append(_i64(_pk1()))
    _drift(
        _build(_i64(_bk0())), _probe(_i64(_pk0())),
        _batch(["pk0", "pk1"], [I, I], cols^), "column count",
    )


def test_drift_bitmap_presence() raises:
    """The second morsel's key 0 carries a bitmap (no NULL); the first's had
    none."""
    _drift(
        _build(_i64(_bk0())), _probe(_i64(_pk0())),
        _probe(_i64(_pk0(), BITMAP_NO_NULL)), "bitmap presence",
    )


def test_drift_null_count() raises:
    """Both morsels' key 0 carry a bitmap; the second holds a NULL."""
    _drift(
        _build(_i64(_bk0(), BITMAP_NO_NULL)), _probe(_i64(_pk0(), BITMAP_NO_NULL)),
        _probe(_i64(_pk0(), 1)), "NULL count",
    )


def test_drift_key_type() raises:
    """The second morsel's key 0 is INT32."""
    _drift(
        _build(_i64(_bk0())), _probe(_i64(_pk0())),
        _probe(_i32(_pk0()), ArrowType.INT32), "key type",
    )


def test_key_count_mismatch_is_not_a_decline() raises:
    """An operator told one build key for two probe keys never asks for the
    share: nothing shared, and NO decline counted (it was never asked)."""
    reset_join_key_cse_counters()
    var op = _op(_build(_i64(_bk0())), _probe(_i64(_pk0())).schema, op_build_keys=["bk0"])
    var out = _run(op, _probe(_i64(_pk0())))
    _counts(0, 3, 0, "one build key")
    assert_equal(out.num_rows(), _ROWS, "the join is unaffected")


def test_non_inner_is_refused_at_construction() raises:
    var build = _build(_i64(_bk0()))
    var builder = MultiKeyHashJoinBuilder.build(
        extract_join_key_columns_serial(build, ["bk0", "bk1"])
    )
    var schema = _out_schema(_probe(_i64(_pk0())).schema, build.schema)
    var raised = False
    try:
        var op = MultiKeyJoinProbeOp(
            ArcPointer[MultiKeyHashJoinBuilder](builder^),
            ArcPointer[RecordBatch](build^),
            ["pk0", "pk1"],
            ["bk0", "bk1"],
            ArcPointer[Schema](schema^),
            JOIN_LEFT,
        )
        _ = op^
    except:
        raised = True
    assert_true(raised, "JOIN_LEFT must be refused")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
