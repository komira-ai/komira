# =============================================================================
# Tests for komira_eval.row_format.RowBlock — the nested cell layout (LIST<primitive>, LIST<string>, STRUCT<flat>,
# LIST<STRUCT<flat>>).
# =============================================================================
#
# The LAYOUT SUBSTRATE only: round-trip each
# nested cell kind directly through the RowBlock per-cell API. NO row-path executor /
# ctx.materialize / SDK pipeline tree — pure RowBlock-level unit tests so the
# build stays fast (small/medium).
#
# In-scope (depth 1): LIST<primitive>, LIST<string> (var-of-var stressor),
# STRUCT<flat: i64 + string>, LIST<STRUCT<flat>>. MAP / arbitrary recursion
# are OUT OF SCOPE (readers hard-raise; these primitives never see them).
#
# Cell coverage (one or more test fns per kind):
#   1.  LIST<i64>            — write_list_primitive_cell + read_list_primitive_at
#   2.  LIST<f64>            — float bit-pattern round-trip
#   3.  LIST<i64> empty      — n_elems==0 vs NULL-list
#   4.  LIST<i64> null list  — write_list_null_cell + is_list_null
#   5.  LIST<i64> null elem  — element validity sub-bitmap
#   6.  LIST<string>         — var-of-var offset bookkeeping (HIGH-BUG-DENSITY)
#   7.  LIST<string> null elem — null element offset bookkeeping
#   8.  LIST<string> empty + null list
#   9.  STRUCT<i64,string>   — write_struct_record_cell + field readers
#   10. STRUCT null struct   — write_struct_null_cell + is_struct_null
#   11. STRUCT null field    — field-validity bit
#   12. LIST<STRUCT<flat>>   — list of struct records + null element
#   13. multi-row independence (two list cells in one block don't alias)
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_eval.row_format import (
    RowBlock,
    ColDescriptor,
    COL_FIXED,
    COL_VAR_STRING,
    DT_I64,
    DT_STRING,
    serialize_struct_record,
    struct_record_is_null,
    struct_record_field_null,
    struct_record_fixed_field,
    struct_record_string_field,
)


# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------


def _new_block(n_rows: Int) raises -> RowBlock:
    """One nested-descriptor cell per row at col_offset 0; stride = 8 bytes."""
    var rb = RowBlock.with_capacity(0, 0, 8)
    rb.reserve_rows(n_rows)
    rb.set_n_rows(n_rows)
    return rb^


def _str_bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var b = s.as_bytes()
    for i in range(len(b)):
        out.append(b[i])
    return out^


def _bytes_to_str(b: List[UInt8]) -> String:
    var out = String("")
    for i in range(len(b)):
        out += chr(Int(b[i]))
    return out


def _bools(*vals: Bool) -> List[Bool]:
    var out = List[Bool]()
    for v in vals:
        out.append(v)
    return out^


def _i64s(*vals: Int) -> List[Scalar[DType.int64]]:
    var out = List[Scalar[DType.int64]]()
    for v in vals:
        out.append(Scalar[DType.int64](v))
    return out^


def _f64s(*vals: Float64) -> List[Scalar[DType.float64]]:
    var out = List[Scalar[DType.float64]]()
    for v in vals:
        out.append(Scalar[DType.float64](v))
    return out^


def _u64s(*vals: UInt64) -> List[UInt64]:
    var out = List[UInt64]()
    for v in vals:
        out.append(v)
    return out^


# -----------------------------------------------------------------------------
# 1-5. LIST<primitive>
# -----------------------------------------------------------------------------


def test_list_i64_round_trip() raises:
    var rb = _new_block(1)
    var vals = _i64s(10, -20, 9999999999, 0)
    var nulls = _bools(False, False, False, False)
    rb.write_list_primitive_cell[DType.int64](0, 0, vals, nulls)
    assert_false(rb.is_list_null(0, 0))
    assert_equal(rb.list_len(0, 0), 4)
    var got = rb.read_list_primitive_at[DType.int64](0, 0)
    var gv = got[0].copy()
    var gn = got[1].copy()
    assert_equal(len(gv), 4)
    assert_equal(Int(gv[0]), 10)
    assert_equal(Int(gv[1]), -20)
    assert_equal(Int(gv[2]), 9999999999)
    assert_equal(Int(gv[3]), 0)
    for i in range(4):
        assert_false(gn[i])


def test_list_f64_round_trip() raises:
    var rb = _new_block(1)
    var vals = _f64s(3.14159, -2.71828, 0.0, 1e300)
    var nulls = _bools(False, False, False, False)
    rb.write_list_primitive_cell[DType.float64](0, 0, vals, nulls)
    var got = rb.read_list_primitive_at[DType.float64](0, 0)
    var gv = got[0].copy()
    assert_equal(len(gv), 4)
    assert_equal(gv[0], 3.14159)
    assert_equal(gv[1], -2.71828)
    assert_equal(gv[2], 0.0)
    assert_equal(gv[3], 1e300)


def test_list_i64_empty() raises:
    var rb = _new_block(1)
    var vals = List[Scalar[DType.int64]]()
    var nulls = List[Bool]()
    rb.write_list_primitive_cell[DType.int64](0, 0, vals, nulls)
    assert_false(rb.is_list_null(0, 0))  # empty != null
    assert_equal(rb.list_len(0, 0), 0)
    var got = rb.read_list_primitive_at[DType.int64](0, 0)
    assert_equal(len(got[0]), 0)


def test_list_i64_null_list() raises:
    var rb = _new_block(1)
    rb.write_list_null_cell(0, 0)
    assert_true(rb.is_list_null(0, 0))
    assert_equal(rb.list_len(0, 0), 0)
    var got = rb.read_list_primitive_at[DType.int64](0, 0)
    assert_equal(len(got[0]), 0)


def test_list_i64_null_element() raises:
    var rb = _new_block(1)
    var vals = _i64s(100, 0, 300)
    var nulls = _bools(False, True, False)  # middle element NULL
    rb.write_list_primitive_cell[DType.int64](0, 0, vals, nulls)
    var got = rb.read_list_primitive_at[DType.int64](0, 0)
    var gv = got[0].copy()
    var gn = got[1].copy()
    assert_equal(len(gv), 3)
    assert_false(gn[0])
    assert_true(gn[1])
    assert_false(gn[2])
    assert_equal(Int(gv[0]), 100)
    assert_equal(Int(gv[2]), 300)


# -----------------------------------------------------------------------------
# 6-8. LIST<string> (var-of-var — the high-bug-density offset bookkeeping)
# -----------------------------------------------------------------------------


def test_list_string_round_trip() raises:
    var rb = _new_block(1)
    var elems = List[List[UInt8]]()
    elems.append(_str_bytes("alpha"))
    elems.append(_str_bytes(""))  # empty string element (distinct from null)
    elems.append(_str_bytes("gamma-with-a-longer-payload"))
    var nulls = _bools(False, False, False)
    rb.write_list_string_cell(0, 0, elems, nulls)
    assert_false(rb.is_list_null(0, 0))
    assert_equal(rb.list_len(0, 0), 3)
    var got = rb.read_list_string_at(0, 0)
    var ge = got[0].copy()
    var gn = got[1].copy()
    assert_equal(len(ge), 3)
    assert_equal(_bytes_to_str(ge[0]), String("alpha"))
    assert_equal(_bytes_to_str(ge[1]), String(""))
    assert_equal(_bytes_to_str(ge[2]), String("gamma-with-a-longer-payload"))
    for i in range(3):
        assert_false(gn[i])


def test_list_string_null_element() raises:
    var rb = _new_block(1)
    var elems = List[List[UInt8]]()
    elems.append(_str_bytes("first"))
    elems.append(_str_bytes("ignored"))  # bytes ignored — element is NULL
    elems.append(_str_bytes("third"))
    var nulls = _bools(False, True, False)
    rb.write_list_string_cell(0, 0, elems, nulls)
    var got = rb.read_list_string_at(0, 0)
    var ge = got[0].copy()
    var gn = got[1].copy()
    assert_equal(len(ge), 3)
    assert_equal(_bytes_to_str(ge[0]), String("first"))
    assert_true(gn[1])
    assert_equal(len(ge[1]), 0)  # null element decodes to empty bytes
    assert_false(gn[2])
    assert_equal(_bytes_to_str(ge[2]), String("third"))


def test_list_string_empty_and_null() raises:
    var rb = _new_block(2)
    # Row 0: empty list of strings.
    var empty = List[List[UInt8]]()
    var enulls = List[Bool]()
    rb.write_list_string_cell(0, 0, empty, enulls)
    # Row 1: NULL list.
    rb.write_list_null_cell(1, 0)
    assert_false(rb.is_list_null(0, 0))
    assert_equal(rb.list_len(0, 0), 0)
    assert_true(rb.is_list_null(1, 0))
    var got0 = rb.read_list_string_at(0, 0)
    assert_equal(len(got0[0]), 0)


# -----------------------------------------------------------------------------
# 9-11. STRUCT<flat: i64 + string>
# -----------------------------------------------------------------------------


def _struct_fields() -> List[ColDescriptor]:
    var f = List[ColDescriptor]()
    f.append(ColDescriptor(COL_FIXED, DT_I64, 8, 0))
    f.append(ColDescriptor(COL_VAR_STRING, DT_STRING, 8, 0))
    return f^


def test_struct_flat_round_trip() raises:
    var rb = _new_block(1)
    var fields = _struct_fields()
    var fixed_vals = _u64s(RowBlock.pack_fixed_field[DType.int64](42))
    var var_vals = List[List[UInt8]]()
    var_vals.append(_str_bytes("widget"))
    var field_nulls = _bools(False, False)
    rb.write_struct_record_cell(0, 0, fields, fixed_vals, var_vals, field_nulls)
    assert_false(rb.is_struct_null(0, 0))
    assert_false(rb.is_struct_field_null(0, 0, 0))
    assert_false(rb.is_struct_field_null(0, 0, 1))
    var fid = rb.read_struct_fixed_field[DType.int64](0, 0, fields, 0)
    assert_equal(Int(fid), 42)
    var name = rb.read_struct_string_field(0, 0, fields, 1)
    assert_equal(_bytes_to_str(name), String("widget"))


def test_struct_null() raises:
    var rb = _new_block(1)
    rb.write_struct_null_cell(0, 0)
    assert_true(rb.is_struct_null(0, 0))


def test_struct_null_field() raises:
    var rb = _new_block(1)
    var fields = _struct_fields()
    # i64 field present, string field NULL.
    var fixed_vals = _u64s(RowBlock.pack_fixed_field[DType.int64](-7))
    var var_vals = List[List[UInt8]]()
    var_vals.append(_str_bytes("ignored"))
    var field_nulls = _bools(False, True)
    rb.write_struct_record_cell(0, 0, fields, fixed_vals, var_vals, field_nulls)
    assert_false(rb.is_struct_null(0, 0))
    assert_false(rb.is_struct_field_null(0, 0, 0))
    assert_true(rb.is_struct_field_null(0, 0, 1))
    var fid = rb.read_struct_fixed_field[DType.int64](0, 0, fields, 0)
    assert_equal(Int(fid), -7)
    var name = rb.read_struct_string_field(0, 0, fields, 1)
    assert_equal(len(name), 0)  # null string field decodes to empty bytes


# -----------------------------------------------------------------------------
# 12. LIST<STRUCT<flat>>
# -----------------------------------------------------------------------------


def test_list_struct_round_trip() raises:
    var rb = _new_block(1)
    var fields = _struct_fields()
    # Build three struct-record elements; element 1 is a NULL struct.
    var records = List[List[UInt8]]()
    var elem_nulls = List[Bool]()

    # Element 0: {id=1, name="aaa"}
    var fv0 = _u64s(RowBlock.pack_fixed_field[DType.int64](1))
    var vv0 = List[List[UInt8]]()
    vv0.append(_str_bytes("aaa"))
    var fn0 = _bools(False, False)
    records.append(serialize_struct_record(fields, fv0, vv0, fn0, False))
    elem_nulls.append(False)

    # Element 1: NULL struct.
    var fvN = List[UInt64]()
    var vvN = List[List[UInt8]]()
    var fnN = List[Bool]()
    records.append(serialize_struct_record(fields, fvN, vvN, fnN, True))
    elem_nulls.append(True)

    # Element 2: {id=333, name="cccc"}
    var fv2 = _u64s(RowBlock.pack_fixed_field[DType.int64](333))
    var vv2 = List[List[UInt8]]()
    vv2.append(_str_bytes("cccc"))
    var fn2 = _bools(False, False)
    records.append(serialize_struct_record(fields, fv2, vv2, fn2, False))
    elem_nulls.append(False)

    rb.write_list_struct_cell(0, 0, fields, records, elem_nulls)
    assert_equal(rb.list_len(0, 0), 3)

    var got = rb.read_list_struct_at(0, 0)
    var recs = got[0].copy()
    var rnulls = got[1].copy()
    assert_equal(len(recs), 3)

    # Element 0.
    assert_false(rnulls[0])
    assert_false(struct_record_is_null(Span(recs[0])))
    assert_false(struct_record_field_null(Span(recs[0]), 0))
    var id0 = struct_record_fixed_field[DType.int64](Span(recs[0]), fields, 0)
    assert_equal(Int(id0), 1)
    var name0 = struct_record_string_field(Span(recs[0]), fields, 1)
    assert_equal(_bytes_to_str(name0), String("aaa"))

    # Element 1 — NULL element (list-level validity bit).
    assert_true(rnulls[1])

    # Element 2.
    assert_false(rnulls[2])
    assert_false(struct_record_is_null(Span(recs[2])))
    var id2 = struct_record_fixed_field[DType.int64](Span(recs[2]), fields, 0)
    assert_equal(Int(id2), 333)
    var name2 = struct_record_string_field(Span(recs[2]), fields, 1)
    assert_equal(_bytes_to_str(name2), String("cccc"))


# -----------------------------------------------------------------------------
# 13. multi-row independence — two nested cells in one block must not alias
# -----------------------------------------------------------------------------


def test_multi_row_list_independence() raises:
    var rb = _new_block(3)
    var v0 = _i64s(1, 2)
    var n0 = _bools(False, False)
    rb.write_list_primitive_cell[DType.int64](0, 0, v0, n0)

    var v1 = _i64s(7, 8, 9, 10, 11)
    var n1 = _bools(False, False, True, False, False)
    rb.write_list_primitive_cell[DType.int64](1, 0, v1, n1)

    var v2 = List[Scalar[DType.int64]]()
    var n2 = List[Bool]()
    rb.write_list_primitive_cell[DType.int64](2, 0, v2, n2)

    assert_equal(rb.list_len(0, 0), 2)
    assert_equal(rb.list_len(1, 0), 5)
    assert_equal(rb.list_len(2, 0), 0)

    var g0 = rb.read_list_primitive_at[DType.int64](0, 0)
    assert_equal(Int(g0[0][0]), 1)
    assert_equal(Int(g0[0][1]), 2)

    var g1 = rb.read_list_primitive_at[DType.int64](1, 0)
    assert_equal(len(g1[0]), 5)
    assert_equal(Int(g1[0][0]), 7)
    assert_equal(Int(g1[0][4]), 11)
    assert_true(g1[1][2])  # element 2 of row 1 is NULL


def main() raises:
    var s = TestSuite()
    s.test[test_list_i64_round_trip]()
    s.test[test_list_f64_round_trip]()
    s.test[test_list_i64_empty]()
    s.test[test_list_i64_null_list]()
    s.test[test_list_i64_null_element]()
    s.test[test_list_string_round_trip]()
    s.test[test_list_string_null_element]()
    s.test[test_list_string_empty_and_null]()
    s.test[test_struct_flat_round_trip]()
    s.test[test_struct_null]()
    s.test[test_struct_null_field]()
    s.test[test_list_struct_round_trip]()
    s.test[test_multi_row_list_independence]()
    s^.run()
