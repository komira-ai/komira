# =============================================================================
# Tests for the nested value parsers: parse_list, parse_struct, parse_map.
# =============================================================================
#
# Coverage (inline fixtures):
#   parse_list_one_value (Tier 2 nested):
#     - Empty array `[]` → 0 child elements.
#     - Single Int64 element `[42]` → 1 child element, value 42.
#     - Multi-element Int64 `[1, 2, 3]` → 3 child elements.
#     - List<String> `["a", "b"]` → 2 string elements.
#     - Null element `[1, null, 3]` → 3 child elements, middle null.
#     - Nested list `[[1]]` → raises (single-level nesting only).
#     - Depth > 20 limit raises.
#
#   parse_struct_one_value (Tier 2 nested):
#     - Empty struct `{}` → all fields null.
#     - All-fields-present `{"a": 1, "b": "x"}` → both populated.
#     - Partial-fields-missing `{"a": 1}` → b is null.
#     - Out-of-order fields `{"b": "y", "a": 2}` → still correct.
#
#   parse_map_one_value (Tier 2 nested):
#     - Empty map `{}` → 0 entries.
#     - Single entry `{"k": 1}` → 1 entry.
#     - Multi-entry `{"k1": 1, "k2": 2}` → 2 entries.
#
#   Materializer-level end-to-end:
#     - LIST<INT64> column with 3 rows.
#     - STRUCT<INT64, STRING> column with 2 rows.
#     - MAP<STRING, INT64> column with 2 rows.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.schema import Schema, SchemaBuilder, Field

from komira_jsonl.columnar_materializer import materialize_jsonl_to_batch
from komira_jsonl.structural_index import build_structural_index
from komira_jsonl.value_parsers.parse_list import parse_list_one_value
from komira_jsonl.value_parsers.parse_struct import parse_struct_one_value
from komira_jsonl.value_parsers.parse_map import parse_map_one_value


# =============================================================================
# parse_list_one_value — direct tests
# =============================================================================
#
# Each test builds a StructuralIndex over a fragment containing one JSON
# array, sets tape_pos to the OPEN_BRACKET (offset 0), and validates the
# child-accumulator state after the parse.


def test_list_empty() raises:
    var s = String("[]")
    var b = s.as_bytes()
    var idx = build_structural_index(b)
    var int_vals = List[Int64]()
    var float_vals = List[Float64]()
    var bool_vals = List[Bool]()
    var str_vals = List[String]()
    var date_vals = List[Int32]()
    var nulls = List[Bool]()
    var pos: Int = 0
    var n = parse_list_one_value(
        b, idx, pos, ArrowType.INT64,
        int_vals, float_vals, bool_vals, str_vals, date_vals, nulls, 0,
    )
    assert_equal(Int(n), 0)
    assert_equal(len(int_vals), 0)
    assert_equal(len(nulls), 0)


def test_list_single_int() raises:
    var s = String("[42]")
    var b = s.as_bytes()
    var idx = build_structural_index(b)
    var int_vals = List[Int64]()
    var float_vals = List[Float64]()
    var bool_vals = List[Bool]()
    var str_vals = List[String]()
    var date_vals = List[Int32]()
    var nulls = List[Bool]()
    var pos: Int = 0
    var n = parse_list_one_value(
        b, idx, pos, ArrowType.INT64,
        int_vals, float_vals, bool_vals, str_vals, date_vals, nulls, 0,
    )
    assert_equal(Int(n), 1)
    assert_equal(len(int_vals), 1)
    assert_equal(Int(int_vals[0]), 42)
    assert_false(nulls[0])


def test_list_multi_int() raises:
    var s = String("[1, 2, 3]")
    var b = s.as_bytes()
    var idx = build_structural_index(b)
    var int_vals = List[Int64]()
    var float_vals = List[Float64]()
    var bool_vals = List[Bool]()
    var str_vals = List[String]()
    var date_vals = List[Int32]()
    var nulls = List[Bool]()
    var pos: Int = 0
    var n = parse_list_one_value(
        b, idx, pos, ArrowType.INT64,
        int_vals, float_vals, bool_vals, str_vals, date_vals, nulls, 0,
    )
    assert_equal(Int(n), 3)
    assert_equal(len(int_vals), 3)
    assert_equal(Int(int_vals[0]), 1)
    assert_equal(Int(int_vals[1]), 2)
    assert_equal(Int(int_vals[2]), 3)


def test_list_strings() raises:
    var s = String("[\"a\", \"b\"]")
    var b = s.as_bytes()
    var idx = build_structural_index(b)
    var int_vals = List[Int64]()
    var float_vals = List[Float64]()
    var bool_vals = List[Bool]()
    var str_vals = List[String]()
    var date_vals = List[Int32]()
    var nulls = List[Bool]()
    var pos: Int = 0
    var n = parse_list_one_value(
        b, idx, pos, ArrowType.STRING,
        int_vals, float_vals, bool_vals, str_vals, date_vals, nulls, 0,
    )
    assert_equal(Int(n), 2)
    assert_equal(len(str_vals), 2)
    assert_equal(str_vals[0], String("a"))
    assert_equal(str_vals[1], String("b"))


def test_list_with_null() raises:
    var s = String("[1, null, 3]")
    var b = s.as_bytes()
    var idx = build_structural_index(b)
    var int_vals = List[Int64]()
    var float_vals = List[Float64]()
    var bool_vals = List[Bool]()
    var str_vals = List[String]()
    var date_vals = List[Int32]()
    var nulls = List[Bool]()
    var pos: Int = 0
    var n = parse_list_one_value(
        b, idx, pos, ArrowType.INT64,
        int_vals, float_vals, bool_vals, str_vals, date_vals, nulls, 0,
    )
    assert_equal(Int(n), 3)
    assert_equal(len(nulls), 3)
    assert_false(nulls[0])
    assert_true(nulls[1])
    assert_false(nulls[2])
    assert_equal(Int(int_vals[0]), 1)
    assert_equal(Int(int_vals[2]), 3)


def test_list_nested_raises() raises:
    """Single-level nesting only — nested LIST in LIST should raise."""
    var s = String("[[1]]")
    var b = s.as_bytes()
    var idx = build_structural_index(b)
    var int_vals = List[Int64]()
    var float_vals = List[Float64]()
    var bool_vals = List[Bool]()
    var str_vals = List[String]()
    var date_vals = List[Int32]()
    var nulls = List[Bool]()
    var pos: Int = 0
    var raised = False
    try:
        _ = parse_list_one_value(
            b, idx, pos, ArrowType.INT64,
            int_vals, float_vals, bool_vals, str_vals, date_vals, nulls, 0,
        )
    except:
        raised = True
    assert_true(raised)


def test_list_depth_limit_raises() raises:
    """Depth > DEPTH_LIMIT (20) should raise at runtime."""
    var s = String("[]")
    var b = s.as_bytes()
    var idx = build_structural_index(b)
    var int_vals = List[Int64]()
    var float_vals = List[Float64]()
    var bool_vals = List[Bool]()
    var str_vals = List[String]()
    var date_vals = List[Int32]()
    var nulls = List[Bool]()
    var pos: Int = 0
    var raised = False
    try:
        _ = parse_list_one_value(
            b, idx, pos, ArrowType.INT64,
            int_vals, float_vals, bool_vals, str_vals, date_vals, nulls, 21,
        )
    except:
        raised = True
    assert_true(raised)


def test_list_floats() raises:
    var s = String("[1.5, 2.5]")
    var b = s.as_bytes()
    var idx = build_structural_index(b)
    var int_vals = List[Int64]()
    var float_vals = List[Float64]()
    var bool_vals = List[Bool]()
    var str_vals = List[String]()
    var date_vals = List[Int32]()
    var nulls = List[Bool]()
    var pos: Int = 0
    var n = parse_list_one_value(
        b, idx, pos, ArrowType.FLOAT64,
        int_vals, float_vals, bool_vals, str_vals, date_vals, nulls, 0,
    )
    assert_equal(Int(n), 2)
    assert_equal(len(float_vals), 2)
    assert_true(float_vals[0] == 1.5)
    assert_true(float_vals[1] == 2.5)


def test_list_bools() raises:
    var s = String("[true, false, true]")
    var b = s.as_bytes()
    var idx = build_structural_index(b)
    var int_vals = List[Int64]()
    var float_vals = List[Float64]()
    var bool_vals = List[Bool]()
    var str_vals = List[String]()
    var date_vals = List[Int32]()
    var nulls = List[Bool]()
    var pos: Int = 0
    var n = parse_list_one_value(
        b, idx, pos, ArrowType.BOOL,
        int_vals, float_vals, bool_vals, str_vals, date_vals, nulls, 0,
    )
    assert_equal(Int(n), 3)
    assert_equal(len(bool_vals), 3)
    assert_true(bool_vals[0])
    assert_false(bool_vals[1])
    assert_true(bool_vals[2])


# =============================================================================
# parse_struct_one_value — direct tests
# =============================================================================


def _make_struct_int_string_names() -> List[String]:
    var names = List[String]()
    names.append(String("a"))
    names.append(String("b"))
    return names^


def _make_struct_int_string_ats() -> List[ArrowType]:
    var ats = List[ArrowType]()
    ats.append(ArrowType.INT64)
    ats.append(ArrowType.STRING)
    return ats^


def test_struct_empty() raises:
    """Empty struct {} → both child fields become null."""
    var s = String("{}")
    var b = s.as_bytes()
    var idx = build_structural_index(b)
    var names = _make_struct_int_string_names()
    var ats = _make_struct_int_string_ats()
    var c_int = List[List[Int64]]()
    c_int.append(List[Int64]())
    c_int.append(List[Int64]())
    var c_float = List[List[Float64]]()
    c_float.append(List[Float64]())
    c_float.append(List[Float64]())
    var c_bool = List[List[Bool]]()
    c_bool.append(List[Bool]())
    c_bool.append(List[Bool]())
    var c_str = List[List[String]]()
    c_str.append(List[String]())
    c_str.append(List[String]())
    var c_date = List[List[Int32]]()
    c_date.append(List[Int32]())
    c_date.append(List[Int32]())
    var c_nulls = List[List[Bool]]()
    c_nulls.append(List[Bool]())
    c_nulls.append(List[Bool]())
    var pos: Int = 0
    var matched = parse_struct_one_value(
        b, idx, pos, names, ats,
        c_int, c_float, c_bool, c_str, c_date, c_nulls, 0,
    )
    assert_false(matched)
    assert_equal(len(c_int[0]), 1)
    assert_equal(len(c_str[1]), 1)
    assert_true(c_nulls[0][0])
    assert_true(c_nulls[1][0])


def test_struct_all_fields_present() raises:
    var s = String("{\"a\": 7, \"b\": \"hi\"}")
    var b = s.as_bytes()
    var idx = build_structural_index(b)
    var names = _make_struct_int_string_names()
    var ats = _make_struct_int_string_ats()
    var c_int = List[List[Int64]]()
    c_int.append(List[Int64]())
    c_int.append(List[Int64]())
    var c_float = List[List[Float64]]()
    c_float.append(List[Float64]())
    c_float.append(List[Float64]())
    var c_bool = List[List[Bool]]()
    c_bool.append(List[Bool]())
    c_bool.append(List[Bool]())
    var c_str = List[List[String]]()
    c_str.append(List[String]())
    c_str.append(List[String]())
    var c_date = List[List[Int32]]()
    c_date.append(List[Int32]())
    c_date.append(List[Int32]())
    var c_nulls = List[List[Bool]]()
    c_nulls.append(List[Bool]())
    c_nulls.append(List[Bool]())
    var pos: Int = 0
    var matched = parse_struct_one_value(
        b, idx, pos, names, ats,
        c_int, c_float, c_bool, c_str, c_date, c_nulls, 0,
    )
    assert_true(matched)
    assert_equal(Int(c_int[0][0]), 7)
    assert_equal(c_str[1][0], String("hi"))
    assert_false(c_nulls[0][0])
    assert_false(c_nulls[1][0])


def test_struct_partial_fields() raises:
    """{"a": 5} — b is absent → should be null in the b accumulator."""
    var s = String("{\"a\": 5}")
    var b = s.as_bytes()
    var idx = build_structural_index(b)
    var names = _make_struct_int_string_names()
    var ats = _make_struct_int_string_ats()
    var c_int = List[List[Int64]]()
    c_int.append(List[Int64]())
    c_int.append(List[Int64]())
    var c_float = List[List[Float64]]()
    c_float.append(List[Float64]())
    c_float.append(List[Float64]())
    var c_bool = List[List[Bool]]()
    c_bool.append(List[Bool]())
    c_bool.append(List[Bool]())
    var c_str = List[List[String]]()
    c_str.append(List[String]())
    c_str.append(List[String]())
    var c_date = List[List[Int32]]()
    c_date.append(List[Int32]())
    c_date.append(List[Int32]())
    var c_nulls = List[List[Bool]]()
    c_nulls.append(List[Bool]())
    c_nulls.append(List[Bool]())
    var pos: Int = 0
    var matched = parse_struct_one_value(
        b, idx, pos, names, ats,
        c_int, c_float, c_bool, c_str, c_date, c_nulls, 0,
    )
    assert_true(matched)
    assert_equal(Int(c_int[0][0]), 5)
    assert_false(c_nulls[0][0])
    assert_true(c_nulls[1][0])


def test_struct_out_of_order() raises:
    """{"b": "y", "a": 2} — JSON keys may appear in any order."""
    var s = String("{\"b\": \"y\", \"a\": 2}")
    var b = s.as_bytes()
    var idx = build_structural_index(b)
    var names = _make_struct_int_string_names()
    var ats = _make_struct_int_string_ats()
    var c_int = List[List[Int64]]()
    c_int.append(List[Int64]())
    c_int.append(List[Int64]())
    var c_float = List[List[Float64]]()
    c_float.append(List[Float64]())
    c_float.append(List[Float64]())
    var c_bool = List[List[Bool]]()
    c_bool.append(List[Bool]())
    c_bool.append(List[Bool]())
    var c_str = List[List[String]]()
    c_str.append(List[String]())
    c_str.append(List[String]())
    var c_date = List[List[Int32]]()
    c_date.append(List[Int32]())
    c_date.append(List[Int32]())
    var c_nulls = List[List[Bool]]()
    c_nulls.append(List[Bool]())
    c_nulls.append(List[Bool]())
    var pos: Int = 0
    var matched = parse_struct_one_value(
        b, idx, pos, names, ats,
        c_int, c_float, c_bool, c_str, c_date, c_nulls, 0,
    )
    assert_true(matched)
    assert_equal(Int(c_int[0][0]), 2)
    assert_equal(c_str[1][0], String("y"))


def test_struct_depth_limit_raises() raises:
    var s = String("{}")
    var b = s.as_bytes()
    var idx = build_structural_index(b)
    var names = _make_struct_int_string_names()
    var ats = _make_struct_int_string_ats()
    var c_int = List[List[Int64]]()
    c_int.append(List[Int64]())
    c_int.append(List[Int64]())
    var c_float = List[List[Float64]]()
    c_float.append(List[Float64]())
    c_float.append(List[Float64]())
    var c_bool = List[List[Bool]]()
    c_bool.append(List[Bool]())
    c_bool.append(List[Bool]())
    var c_str = List[List[String]]()
    c_str.append(List[String]())
    c_str.append(List[String]())
    var c_date = List[List[Int32]]()
    c_date.append(List[Int32]())
    c_date.append(List[Int32]())
    var c_nulls = List[List[Bool]]()
    c_nulls.append(List[Bool]())
    c_nulls.append(List[Bool]())
    var pos: Int = 0
    var raised = False
    try:
        _ = parse_struct_one_value(
            b, idx, pos, names, ats,
            c_int, c_float, c_bool, c_str, c_date, c_nulls, 21,
        )
    except:
        raised = True
    assert_true(raised)


# =============================================================================
# parse_map_one_value — direct tests
# =============================================================================


def test_map_empty() raises:
    var s = String("{}")
    var b = s.as_bytes()
    var idx = build_structural_index(b)
    var keys = List[String]()
    var v_int = List[Int64]()
    var v_float = List[Float64]()
    var v_bool = List[Bool]()
    var v_str = List[String]()
    var v_date = List[Int32]()
    var v_nulls = List[Bool]()
    var pos: Int = 0
    var n = parse_map_one_value(
        b, idx, pos, ArrowType.INT64,
        keys, v_int, v_float, v_bool, v_str, v_date, v_nulls, 0,
    )
    assert_equal(Int(n), 0)
    assert_equal(len(keys), 0)
    assert_equal(len(v_int), 0)


def test_map_single_entry() raises:
    var s = String("{\"k\": 1}")
    var b = s.as_bytes()
    var idx = build_structural_index(b)
    var keys = List[String]()
    var v_int = List[Int64]()
    var v_float = List[Float64]()
    var v_bool = List[Bool]()
    var v_str = List[String]()
    var v_date = List[Int32]()
    var v_nulls = List[Bool]()
    var pos: Int = 0
    var n = parse_map_one_value(
        b, idx, pos, ArrowType.INT64,
        keys, v_int, v_float, v_bool, v_str, v_date, v_nulls, 0,
    )
    assert_equal(Int(n), 1)
    assert_equal(len(keys), 1)
    assert_equal(keys[0], String("k"))
    assert_equal(Int(v_int[0]), 1)
    assert_false(v_nulls[0])


def test_map_multi_entry() raises:
    var s = String("{\"k1\": 1, \"k2\": 2, \"k3\": 3}")
    var b = s.as_bytes()
    var idx = build_structural_index(b)
    var keys = List[String]()
    var v_int = List[Int64]()
    var v_float = List[Float64]()
    var v_bool = List[Bool]()
    var v_str = List[String]()
    var v_date = List[Int32]()
    var v_nulls = List[Bool]()
    var pos: Int = 0
    var n = parse_map_one_value(
        b, idx, pos, ArrowType.INT64,
        keys, v_int, v_float, v_bool, v_str, v_date, v_nulls, 0,
    )
    assert_equal(Int(n), 3)
    assert_equal(len(keys), 3)
    assert_equal(keys[0], String("k1"))
    assert_equal(keys[1], String("k2"))
    assert_equal(keys[2], String("k3"))
    assert_equal(Int(v_int[0]), 1)
    assert_equal(Int(v_int[1]), 2)
    assert_equal(Int(v_int[2]), 3)


def test_map_string_values() raises:
    var s = String("{\"a\": \"x\", \"b\": \"y\"}")
    var b = s.as_bytes()
    var idx = build_structural_index(b)
    var keys = List[String]()
    var v_int = List[Int64]()
    var v_float = List[Float64]()
    var v_bool = List[Bool]()
    var v_str = List[String]()
    var v_date = List[Int32]()
    var v_nulls = List[Bool]()
    var pos: Int = 0
    var n = parse_map_one_value(
        b, idx, pos, ArrowType.STRING,
        keys, v_int, v_float, v_bool, v_str, v_date, v_nulls, 0,
    )
    assert_equal(Int(n), 2)
    assert_equal(keys[0], String("a"))
    assert_equal(v_str[0], String("x"))
    assert_equal(keys[1], String("b"))
    assert_equal(v_str[1], String("y"))


def test_map_with_null_value() raises:
    var s = String("{\"k\": null}")
    var b = s.as_bytes()
    var idx = build_structural_index(b)
    var keys = List[String]()
    var v_int = List[Int64]()
    var v_float = List[Float64]()
    var v_bool = List[Bool]()
    var v_str = List[String]()
    var v_date = List[Int32]()
    var v_nulls = List[Bool]()
    var pos: Int = 0
    var n = parse_map_one_value(
        b, idx, pos, ArrowType.INT64,
        keys, v_int, v_float, v_bool, v_str, v_date, v_nulls, 0,
    )
    assert_equal(Int(n), 1)
    assert_equal(keys[0], String("k"))
    assert_true(v_nulls[0])


def test_map_depth_limit_raises() raises:
    var s = String("{}")
    var b = s.as_bytes()
    var idx = build_structural_index(b)
    var keys = List[String]()
    var v_int = List[Int64]()
    var v_float = List[Float64]()
    var v_bool = List[Bool]()
    var v_str = List[String]()
    var v_date = List[Int32]()
    var v_nulls = List[Bool]()
    var pos: Int = 0
    var raised = False
    try:
        _ = parse_map_one_value(
            b, idx, pos, ArrowType.INT64,
            keys, v_int, v_float, v_bool, v_str, v_date, v_nulls, 21,
        )
    except:
        raised = True
    assert_true(raised)


# =============================================================================
# Materializer end-to-end — LIST / STRUCT / MAP columns
# =============================================================================


def _list_int_schema(col_name: String) -> Schema:
    var sb = SchemaBuilder()
    var f = Field(col_name, ArrowType.LIST, True)
    f.add_child(String("item"), ArrowType.INT64, True)
    sb.add_field(f)
    return sb.build()


def _struct_int_string_schema(col_name: String) -> Schema:
    var sb = SchemaBuilder()
    var f = Field(col_name, ArrowType.STRUCT, True)
    f.add_child(String("a"), ArrowType.INT64, True)
    f.add_child(String("b"), ArrowType.STRING, True)
    sb.add_field(f)
    return sb.build()


def _map_string_int_schema(col_name: String) -> Schema:
    var sb = SchemaBuilder()
    var f = Field(col_name, ArrowType.MAP, True)
    f.add_child(String("value"), ArrowType.INT64, True)
    sb.add_field(f)
    return sb.build()


def test_materialize_list_int_column() raises:
    """LIST<INT64> column with 3 rows: [[1,2,3], [], [10]]."""
    var json = String("{\"xs\": [1, 2, 3]}\n{\"xs\": []}\n{\"xs\": [10]}\n")
    var b = json.as_bytes()
    var schema = _list_int_schema(String("xs"))
    var batch = materialize_jsonl_to_batch(b, schema^)
    assert_equal(batch._num_rows, 3)
    assert_equal(batch.num_columns(), 1)
    # The LIST column should be present; we just exercise the build path.


def test_materialize_struct_column() raises:
    """STRUCT<a: INT64, b: STRING> column with 2 rows."""
    var json = String("{\"s\": {\"a\": 1, \"b\": \"x\"}}\n{\"s\": {\"a\": 2, \"b\": \"y\"}}\n")
    var b = json.as_bytes()
    var schema = _struct_int_string_schema(String("s"))
    var batch = materialize_jsonl_to_batch(b, schema^)
    assert_equal(batch._num_rows, 2)
    assert_equal(batch.num_columns(), 1)


def test_materialize_map_column() raises:
    """MAP<STRING, INT64> column with 2 rows."""
    var json = String("{\"m\": {\"a\": 1, \"b\": 2}}\n{\"m\": {\"c\": 3}}\n")
    var b = json.as_bytes()
    var schema = _map_string_int_schema(String("m"))
    var batch = materialize_jsonl_to_batch(b, schema^)
    assert_equal(batch._num_rows, 2)
    assert_equal(batch.num_columns(), 1)


def test_materialize_list_null_row() raises:
    """LIST<INT64> column with one null row."""
    var json = String("{\"xs\": [1]}\n{\"xs\": null}\n{\"xs\": [2, 3]}\n")
    var b = json.as_bytes()
    var schema = _list_int_schema(String("xs"))
    var batch = materialize_jsonl_to_batch(b, schema^)
    assert_equal(batch._num_rows, 3)


def test_materialize_list_missing_row() raises:
    """LIST<INT64> column: row 2 has the key absent → null."""
    var json = String("{\"xs\": [1]}\n{\"other\": 99}\n{\"xs\": [2]}\n")
    var b = json.as_bytes()
    var schema = _list_int_schema(String("xs"))
    var batch = materialize_jsonl_to_batch(b, schema^)
    assert_equal(batch._num_rows, 3)


# =============================================================================
# Driver
# =============================================================================


def main() raises:
    print("test_nested_parsers — nested parsers suite")

    # parse_list_one_value
    test_list_empty()
    test_list_single_int()
    test_list_multi_int()
    test_list_strings()
    test_list_with_null()
    test_list_nested_raises()
    test_list_depth_limit_raises()
    test_list_floats()
    test_list_bools()

    # parse_struct_one_value
    test_struct_empty()
    test_struct_all_fields_present()
    test_struct_partial_fields()
    test_struct_out_of_order()
    test_struct_depth_limit_raises()

    # parse_map_one_value
    test_map_empty()
    test_map_single_entry()
    test_map_multi_entry()
    test_map_string_values()
    test_map_with_null_value()
    test_map_depth_limit_raises()

    # Materializer end-to-end
    test_materialize_list_int_column()
    test_materialize_struct_column()
    test_materialize_map_column()
    test_materialize_list_null_row()
    test_materialize_list_missing_row()

    print("test_nested_parsers — all tests PASSED")
