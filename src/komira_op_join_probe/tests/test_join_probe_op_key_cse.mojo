# The JOIN-KEY CSE of `JoinProbeOp` (`SingleKeyCse`): an INNER output's build
# key column may share the probe key column. Checked with the exact counters
# of `komira_join_assembly.join_key_cse` (shared, gathered, declines) and,
# where it fires, physically against a gathered output of the same morsel
# (type, length, NULL count, offset, validity presence, data bytes). The
# gathered reference comes from an operator whose FIRST morsel refused the
# proof (a refusal is kept for the operator's life), run on the same second
# morsel.
#   * INNER shares (whole-morsel and resumable arms); LEFT never asks;
#   * a FLOAT64 or INT32 build key column declines (a different type);
#   * a later morsel whose key moved, whose column count changed, whose key
#     type changed (TIMESTAMP is INT64-stored) or whose key carries a bitmap
#     gathers instead.

from std.memory import ArcPointer
from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_buffer.heap_region import HeapRegion
from komira_join_assembly.join_key_cse import (
    join_key_cse_declines,
    join_key_cse_gathered_columns,
    join_key_cse_shared_columns,
    reset_join_key_cse_counters,
)
from komira_morsel.morsel import Morsel
from komira_plan_ir.logical_plan import JOIN_INNER, JOIN_LEFT

from komira_op_join_build.join import HashJoinBuilder
from komira_op_join_probe.join_probe_op import JoinProbeOp
from komira_op_join_probe.join_probe_op_state import (
    ColumnarProbeSharedState,
    build_shared_probe_state,
)


comptime I = ArrowType.INT64


def _col(t: ArrowType, vals: List[Int64], bitmap: Bool = False) raises -> Column[HeapRegion]:
    """`vals` as type `t` (INT64-stored types, INT32 or FLOAT64); `bitmap`
    adds an all-valid validity bitmap."""
    if t == ArrowType.INT32:
        var a = PrimitiveArray[DType.int32].allocate(len(vals))
        for i in range(len(vals)):
            a._typed_ptr_mut()[i] = Int32(Int(vals[i]))
        return Column.from_primitive[DType.int32](a^)
    if t == ArrowType.FLOAT64:
        var a = PrimitiveArray[DType.float64].allocate(len(vals))
        for i in range(len(vals)):
            a._typed_ptr_mut()[i] = Float64(Int(vals[i]))
        return Column.from_primitive[DType.float64](a^)
    var a = PrimitiveArray[DType.int64].allocate_nullable(
        len(vals)
    ) if bitmap else PrimitiveArray[DType.int64].allocate(len(vals))
    for i in range(len(vals)):
        a._typed_ptr_mut()[i] = vals[i]
    var c = Column.from_primitive[DType.int64](a^)
    c.arrow_type = t
    return c^


def _batch(names: List[String], types: List[ArrowType], var cols: List[Column[HeapRegion]]) raises -> RecordBatch:
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    for i in range(len(names)):
        sb.add_field(Field(names[i], types[i], True))
    while len(cols) > 0:
        rb.add_column(cols.pop(0))
    return rb.build(sb.build())


def _pk() -> List[Int64]:
    return [30, 99, 20, 30, 50]


def _pv() -> List[Int64]:
    return [1000, 1001, 1002, 1003, 1004]


def _probe(key_type: ArrowType = I, bitmap: Bool = False, moved: Bool = False, narrow: Bool = False) raises -> RecordBatch:
    """(pk, pv); `moved`: (pv, pk); `narrow`: pk only."""
    var cols = List[Column[HeapRegion]]()
    if narrow:
        cols.append(_col(key_type, _pk(), bitmap))
        return _batch(["pk"], [key_type], cols^)
    if moved:
        cols.append(_col(I, _pv()))
        cols.append(_col(key_type, _pk(), bitmap))
        return _batch(["pv", "pk"], [I, key_type], cols^)
    cols.append(_col(key_type, _pk(), bitmap))
    cols.append(_col(I, _pv()))
    return _batch(["pk", "pv"], [key_type, I], cols^)


def _op(join_type: UInt8, build_key_type: ArrowType = I, slot: Bool = False) raises -> JoinProbeOp:
    var bk: List[Int64] = [10, 20, 30, 40, 50]
    var cols = List[Column[HeapRegion]]()
    cols.append(_col(build_key_type, bk))
    cols.append(_col(I, [100, 200, 300, 400, 500]))
    var build = _batch(["bk", "bv"], [build_key_type, I], cols^)
    var sb = SchemaBuilder()
    sb.add_field(Field("pk", I, True))
    sb.add_field(Field("pv", I, True))
    sb.add_field(Field("bk", build_key_type, True))
    sb.add_field(Field("bv", I, True))
    var shared = Optional[ArcPointer[ColumnarProbeSharedState]](None)
    if slot:
        shared = build_shared_probe_state(1)
    return JoinProbeOp(
        ArcPointer[HashJoinBuilder](HashJoinBuilder.build(PrimitiveArray[DType.int64].from_list(bk))),
        ArcPointer[RecordBatch](build^),
        "pk", "bk",
        ArcPointer[Schema](sb.build()),
        join_type,
        shared=shared^,
        local_id=0 if slot else -1,
    )


def _run(mut op: JoinProbeOp, var probe: RecordBatch) raises -> RecordBatch:
    var m = Morsel(probe^, 0, 0, 0)
    _ = op.execute(m)
    return m^.take_batch()


def _counts(shared: Int, gathered: Int, declines: Int, what: String) raises:
    assert_equal(join_key_cse_shared_columns(), shared, what + ": shared")
    assert_equal(join_key_cse_gathered_columns(), gathered, what + ": gathered")
    assert_equal(join_key_cse_declines(), declines, what + ": declines")


def _same(imm a: RecordBatch, imm b: RecordBatch, what: String) raises:
    assert_equal(a.num_rows(), b.num_rows(), what + ": rows")
    assert_equal(a.num_columns(), b.num_columns(), what + ": columns")
    for c in range(a.num_columns()):
        ref ca = a.column_at(c)
        ref cb = b.column_at(c)
        assert_true(ca.arrow_type == cb.arrow_type, what + ": type")
        assert_equal(ca._length, cb._length, what + ": length")
        assert_equal(ca._null_count, cb._null_count, what + ": NULL count")
        assert_equal(ca._offset, cb._offset, what + ": offset")
        assert_equal(Bool(ca._validity), Bool(cb._validity), what + ": validity")
        var da = ca._data.view_ro()
        var db = cb._data.view_ro()
        assert_equal(da.len(), db.len(), what + ": data bytes")
        for i in range(da.len()):
            assert_equal(da.get_typed[UInt8](i), db.get_typed[UInt8](i), what + ": byte")


def _gathered_reference() raises -> RecordBatch:
    """An operator whose first morsel's key carries a bitmap refuses for good;
    its output of a plain morsel is the gathered one."""
    var op = _op(JOIN_INNER)
    _ = _run(op, _probe(bitmap=True))
    return _run(op, _probe())


def test_inner_shares_and_matches_the_gather() raises:
    var ref_out = _gathered_reference()
    for slot in [False, True]:
        reset_join_key_cse_counters()
        var op = _op(JOIN_INNER, slot=slot)
        var out = _run(op, _probe())
        _counts(1, 1, 0, "INNER shares the key")
        _same(out, ref_out, "shared vs gathered")
        var pk = out.column_at(0).as_primitive[DType.int64]()
        var bk = out.column_at(2).as_primitive[DType.int64]()
        for r in range(out.num_rows()):
            assert_equal(pk.get(r), bk.get(r), "keys agree")


def test_left_never_asks() raises:
    reset_join_key_cse_counters()
    var op = _op(JOIN_LEFT)
    var out = _run(op, _probe())
    _counts(0, 2, 0, "LEFT: gathered, never asked")
    assert_equal(out.num_rows(), 5, "LEFT rows")


def test_a_build_key_of_another_type_declines() raises:
    for t in [ArrowType.FLOAT64, ArrowType.INT32]:
        reset_join_key_cse_counters()
        var op = _op(JOIN_INNER, build_key_type=t)
        var out = _run(op, _probe())
        _counts(0, 2, 1, "build key type")
        assert_equal(out.num_rows(), 4, "the join is unaffected")


def _drift(var second: RecordBatch, what: String) raises:
    """The first morsel proves (1 shared, 1 gathered); `second` gathers both
    build columns and still joins its 4 rows."""
    reset_join_key_cse_counters()
    var op = _op(JOIN_INNER)
    _ = _run(op, _probe())
    _counts(1, 1, 0, what + ": the first morsel proves")
    var out = _run(op, second^)
    _counts(1, 3, 0, what + ": the second gathers")
    assert_equal(out.num_rows(), 4, what + ": rows")


def test_drift_cases() raises:
    _drift(_probe(moved=True), "key moved")
    _drift(_probe(narrow=True), "column count")
    _drift(_probe(key_type=ArrowType.TIMESTAMP_US), "key type")
    _drift(_probe(bitmap=True), "bitmap presence")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
