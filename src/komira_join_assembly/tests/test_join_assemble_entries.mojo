# =============================================================================
# test_join_assemble_entries -- the projected entry, the full assemble's index
# window, its output-schema bound and its JOIN-KEY CSE share
# =============================================================================
#
# Cases
#   A  `resolve_join_output_cols`: a probe name, a build name, a `_right`
#      collision name, and each refusal (unknown name; a `_right` name whose
#      stem is not a probe column; a `_right` name whose stem is a probe column
#      but not a build column).
#   B  `assemble_join_result_projected`: no names gives a count-only batch of
#      `len(left_indices)` rows; names from both sides gather the right rows in
#      the requested order.
#   C  `assemble_join_result_dispatch` over a NON-default index window: values
#      come from `[index_lo, index_lo + count)`, `index_count = -1` with a
#      non-zero `index_lo` means "to the end".
#   D  Each bad window is refused before any column is gathered.
#   E  The default window with a right index list ONE entry shorter than the
#      left one is refused at the first build column.
#   F  An output schema with fewer columns than the two sides stops at its
#      last column.
#   G  The JOIN-KEY CSE: a proven alias map SHARES the build key column
#      (aliasing the probe column's bytes) and the counters record the share;
#      on an outer side (right_nullable) the same map gathers instead.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_async_api.parallel_dispatch import NoDispatch
from komira_join_assembly.compiler_join_assembly import (
    assemble_join_result,
    assemble_join_result_dispatch,
    assemble_join_result_projected,
    resolve_join_output_cols,
)
from komira_join_assembly.join_key_cse import (
    join_key_cse_aliases,
    join_key_cse_gathered_columns,
    join_key_cse_shared_bytes,
    join_key_cse_shared_columns,
    reset_join_key_cse_counters,
)
from komira_plan_ir.logical_plan import JOIN_INNER


def _i64_batch(names: List[String], n: Int, mul: List[Int]) raises -> RecordBatch:
    """Column `c` holds `i * mul[c] + c` at row `i`."""
    var sb = SchemaBuilder()
    var bb = RecordBatchBuilder()
    for c in range(len(names)):
        var vals = List[Scalar[DType.int64]]()
        for i in range(n):
            vals.append(Scalar[DType.int64](i * mul[c] + c))
        sb.add_field(Field(names[c], ArrowType.INT64, False))
        bb.add_column(Column.from_primitive(PrimitiveArray[DType.int64].from_list(vals)))
    return bb.build(sb.build())


def _names(a: String, b: String) -> List[String]:
    var l = List[String]()
    l.append(a)
    l.append(b)
    return l^


def _muls(a: Int, b: Int) -> List[Int]:
    var l = List[Int]()
    l.append(a)
    l.append(b)
    return l^


def _get(ref batch: RecordBatch, c: Int, r: Int) raises -> Int:
    return Int(batch.column_at(c)._data.get_typed[Int64](r))


def _left() raises -> RecordBatch:
    return _i64_batch(_names("k", "a"), 20, _muls(1, 10))


def _right() raises -> RecordBatch:
    return _i64_batch(_names("k", "b"), 15, _muls(1, 100))


def _out4() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field(String("k"), ArrowType.INT64, False))
    sb.add_field(Field(String("a"), ArrowType.INT64, False))
    sb.add_field(Field(String("k_right"), ArrowType.INT64, False))
    sb.add_field(Field(String("b"), ArrowType.INT64, False))
    return sb.build()


def _li(n: Int) -> List[Int]:
    var l = List[Int]()
    for i in range(n):
        l.append((i * 7 + 2) % 20)
    return l^


def _ri(n: Int) -> List[Int]:
    var l = List[Int]()
    for i in range(n):
        l.append((i * 4 + 1) % 15)
    return l^


# =============================================================================
# A
# =============================================================================


def _resolve_raises(names: List[String], want: String) raises:
    var left = _left()
    var right = _right()
    var raised = False
    try:
        _ = resolve_join_output_cols(left.schema, right.schema, names)
    except e:
        raised = True
        assert_true(String(e).find(want) >= 0, "§A message: " + String(e))
    assert_true(raised, "§A must refuse " + want)


def test_a_resolve_join_output_cols() raises:
    var left = _left()
    var right = _right()
    var names = List[String]()
    names.append(String("a"))
    names.append(String("b"))
    names.append(String("k_right"))
    names.append(String("k"))
    var r = resolve_join_output_cols(left.schema, right.schema, names)
    var sides = r[0].copy()
    var idx = r[1].copy()
    assert_equal(len(sides), 4, "§A one entry per name")
    assert_equal(Int(sides[0]), 0, "§A a is probe")
    assert_equal(idx[0], 1, "§A a index")
    assert_equal(Int(sides[1]), 1, "§A b is build")
    assert_equal(idx[1], 1, "§A b index")
    assert_equal(Int(sides[2]), 1, "§A k_right is build")
    assert_equal(idx[2], 0, "§A k_right index")
    assert_equal(Int(sides[3]), 0, "§A k prefers the probe side")
    assert_equal(idx[3], 0, "§A k index")

    var unknown = List[String]()
    unknown.append(String("zz"))
    _resolve_raises(unknown, "'zz' not found")
    # `b` is a build column but NOT a probe column: no collision, no suffix.
    var no_collision = List[String]()
    no_collision.append(String("b_right"))
    _resolve_raises(no_collision, "'b_right' not found")
    # `a` collides with nothing on the build side.
    var not_on_build = List[String]()
    not_on_build.append(String("a_right"))
    _resolve_raises(not_on_build, "'a_right' not found")


# =============================================================================
# B
# =============================================================================


def test_b_projected_entry() raises:
    var left = _left()
    var right = _right()
    var li = _li(9)
    var ri = _ri(9)
    var none = List[String]()
    var empty = assemble_join_result_projected(left, right, li, ri, none)
    assert_equal(empty.num_columns(), 0, "§B no names, no columns")
    assert_equal(empty.num_rows(), 9, "§B count-only batch keeps the row count")

    var names = List[String]()
    names.append(String("b"))
    names.append(String("a"))
    names.append(String("k_right"))
    var out = assemble_join_result_projected(left, right, li, ri, names)
    assert_equal(out.num_columns(), 3, "§B three columns")
    assert_equal(out.num_rows(), 9, "§B rows")
    assert_equal(out.schema.field_name(0), String("b"), "§B order kept")
    assert_equal(out.schema.field_name(2), String("k_right"), "§B name kept")
    for i in range(9):
        assert_equal(_get(out, 0, i), ri[i] * 100 + 1, "§B b")
        assert_equal(_get(out, 1, i), li[i] * 10 + 1, "§B a")
        assert_equal(_get(out, 2, i), ri[i], "§B k_right")


# =============================================================================
# C / D / E / F
# =============================================================================


def _windowed(
    ref left: RecordBatch,
    ref right: RecordBatch,
    li: List[Int],
    ri: List[Int],
    lo: Int,
    cnt: Int,
) raises -> RecordBatch:
    var nd = NoDispatch()
    comptime o = origin_of(nd)
    return assemble_join_result_dispatch[False, NoDispatch, o](
        left, right, li, ri, _out4(), Optional[Pointer[NoDispatch, o]](None),
        False, False, lo, cnt,
    )


def test_c_index_window_reads_the_window() raises:
    var left = _left()
    var right = _right()
    var li = _li(12)
    var ri = _ri(12)
    var out = _windowed(left, right, li, ri, 4, 5)
    assert_equal(out.num_rows(), 5, "§C count rows")
    for i in range(5):
        assert_equal(_get(out, 1, i), li[4 + i] * 10 + 1, "§C left value")
        assert_equal(_get(out, 3, i), ri[4 + i] * 100 + 1, "§C right value")
    var tail = _windowed(left, right, li, ri, 9, -1)
    assert_equal(tail.num_rows(), 3, "§C -1 count runs to the end")
    for i in range(3):
        assert_equal(_get(tail, 0, i), li[9 + i], "§C tail left key")
        assert_equal(_get(tail, 2, i), ri[9 + i], "§C tail right key")


def _window_refused(li: List[Int], ri: List[Int], lo: Int, cnt: Int) raises:
    var left = _left()
    var right = _right()
    var raised = False
    try:
        _ = _windowed(left, right, li, ri, lo, cnt)
    except e:
        raised = True
        assert_true(
            String(e).find("is outside the index lists") >= 0,
            "§D message: " + String(e),
        )
    assert_true(
        raised, "§D window lo=" + String(lo) + " count=" + String(cnt) + " must raise"
    )


def test_d_bad_windows_are_refused() raises:
    var li = _li(10)
    var ri = _ri(10)
    _window_refused(li, ri, -1, 2)
    _window_refused(li, ri, 2, -2)
    _window_refused(li, ri, 6, 5)
    var short_r = _ri(7)
    _window_refused(li, short_r, 6, 2)
    # The last in-bounds window on both lists is accepted.
    var left = _left()
    var right = _right()
    var ok = _windowed(left, right, li, short_r, 5, 2)
    assert_equal(ok.num_rows(), 2, "§D window ending at len(right) is accepted")


def test_e_short_right_list_on_the_default_window() raises:
    var left = _left()
    var right = _right()
    # ONE entry short: the boundary, so an off-by-one in the check survives
    # nowhere.
    var li = _li(10)
    var ri = _ri(9)
    var raised = False
    try:
        _ = assemble_join_result(left, right, li, ri, _out4())
    except e:
        raised = True
        assert_true(
            String(e).find("must be GATHERED but the right index list holds only 9") >= 0,
            "§E message: " + String(e),
        )
    assert_true(raised, "§E a short right list must raise")


def test_f_output_schema_bounds_the_build_columns() raises:
    var left = _left()
    var right = _right()
    var li = _li(8)
    var ri = _ri(8)
    var sb = SchemaBuilder()
    sb.add_field(Field(String("k"), ArrowType.INT64, False))
    sb.add_field(Field(String("a"), ArrowType.INT64, False))
    sb.add_field(Field(String("k_right"), ArrowType.INT64, False))
    var out = assemble_join_result(left, right, li, ri, sb.build())
    assert_equal(out.num_columns(), 3, "§F stops at the schema's last column")
    for i in range(8):
        assert_equal(_get(out, 2, i), ri[i], "§F k_right")


# =============================================================================
# G
# =============================================================================


def test_g_join_key_cse_shares_the_key_column() raises:
    var left = _left()
    var right = _right()
    # An equi-join on k: matched rows carry equal keys on both sides.
    var li = List[Int]()
    var ri = List[Int]()
    for i in range(12):
        li.append(i)
        ri.append(i)
    var lk = List[String]()
    lk.append(String("k"))
    var rk = List[String]()
    rk.append(String("k"))
    var amap = join_key_cse_aliases(left, right, lk, rk, JOIN_INNER)
    assert_equal(amap.alias_of(0), 0, "§G build k aliases probe k")

    reset_join_key_cse_counters()
    var out = assemble_join_result(left, right, li, ri, _out4(), key_alias_of_right=amap^)
    assert_equal(out.num_columns(), 4, "§G four columns")
    assert_equal(join_key_cse_shared_columns(), 1, "§G one column shared")
    assert_equal(join_key_cse_shared_bytes(), 12 * 8, "§G shared bytes")
    assert_equal(join_key_cse_gathered_columns(), 1, "§G one build column gathered")
    assert_equal(out.schema.field_name(2), String("k_right"), "§G name from schema")
    assert_false(out.schema.field_at(2).nullable, "§G not nullable")
    for i in range(12):
        assert_equal(_get(out, 2, i), i, "§G shared key value")
        assert_equal(_get(out, 3, i), i * 100 + 1, "§G gathered b")

    # Outer side: the same proven map must NOT be used.
    var amap2 = join_key_cse_aliases(left, right, lk, rk, JOIN_INNER)
    reset_join_key_cse_counters()
    var out2 = assemble_join_result(
        left, right, li, ri, _out4(), right_nullable=True, key_alias_of_right=amap2^
    )
    assert_equal(join_key_cse_shared_columns(), 0, "§G outer side shares nothing")
    assert_equal(join_key_cse_gathered_columns(), 2, "§G outer side gathers both")
    for i in range(12):
        assert_equal(_get(out2, 2, i), i, "§G gathered key value")


def main() raises:
    var suite = TestSuite()
    suite.test[test_a_resolve_join_output_cols]()
    suite.test[test_b_projected_entry]()
    suite.test[test_c_index_window_reads_the_window]()
    suite.test[test_d_bad_windows_are_refused]()
    suite.test[test_e_short_right_list_on_the_default_window]()
    suite.test[test_f_output_schema_bounds_the_build_columns]()
    suite.test[test_g_join_key_cse_shares_the_key_column]()
    suite^.run()
