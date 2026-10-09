# =============================================================================
# test_typed_schema_descriptor.mojo: SchemaDescriptor and the comptime schema
# helpers of typed_schema, run on runtime descriptors.
#
# The helpers are written to be folded at comptime, but every one of them is
# an ordinary function too: each test here calls the function on a runtime
# descriptor (so the code that runs is the code measured) and, where a
# comptime wrapper exists, also through the wrapper on a comptime schema, and
# checks the value worked out by hand from the docstring's contract.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_plan_expr.typed_schema import (
    TYPE_UNKNOWN, TYPE_INT8, TYPE_INT16, TYPE_INT32, TYPE_INT64,
    TYPE_UINT64, TYPE_FLOAT64, TYPE_BOOL, TYPE_STRING, TYPE_DATE32,
    TYPE_DECIMAL128, TYPE_STRUCT, TYPE_MAP,
    Int64Col, Float64Col,
    ColDescriptor, SchemaDescriptor,
    _NN, _NS, _NM,
    schema_of,
    has_col, dtype_at, col_list,
    _safe_struct_field_index, comptime_struct_field_index,
    _safe_struct_child_dtype, comptime_struct_child_dtype,
    _struct_field_names_joined, struct_field_list,
    _safe_map_key_dtype, comptime_map_key_dtype,
    _safe_map_value_dtype, comptime_map_value_dtype,
)


def _col(n: String, d: Int, nullable: Bool) -> ColDescriptor:
    return ColDescriptor(n, d, nullable, List[ColDescriptor](), TYPE_UNKNOWN, TYPE_UNKNOWN)


def _flat() -> SchemaDescriptor:
    """Four columns of four widths: INT8 (1 byte), INT32 (4), DECIMAL128 (16),
    STRING (8); `price` nullable, the others not; strict."""
    var c: List[ColDescriptor] = [
        _col("tiny", TYPE_INT8, False),
        _col("qty", TYPE_INT32, False),
        _col("price", TYPE_DECIMAL128, True),
        _col("note", TYPE_STRING, False),
    ]
    return SchemaDescriptor(c^, True)


def _nested() -> SchemaDescriptor:
    """An id, a STRUCT `addr {street: STRING, zip: INT32}` and a MAP
    `tags<STRING, INT64>`."""
    var kids: List[ColDescriptor] = [_NN("street", TYPE_STRING), _NN("zip", TYPE_INT32)]
    var c: List[ColDescriptor] = [
        _NN("id", TYPE_INT64),
        _NS("addr", kids^),
        _NM("tags", TYPE_STRING, TYPE_INT64),
    ]
    return SchemaDescriptor(c^, False)


# Names of 24 bytes and more: `col_list` joins names with `String +=` at
# comptime, which the interpreter cannot do on an inline (short) String (the
# CAVEAT in `select_named_schema`).
comptime LONG = schema_of[
    "customer_account_identifier", Int64Col,
    "customer_account_balance_amt", Float64Col,
]()

comptime NESTED = SchemaDescriptor([
    _NN(String("id"), TYPE_INT64),
    _NS(String("addr"), [_NN(String("street"), TYPE_STRING), _NN(String("zip"), TYPE_INT32)]),
    _NM(String("tags"), TYPE_STRING, TYPE_INT64),
], False)


def test_factories_fill_the_defaulted_slots() raises:
    """`_NN` is a non-null leaf with no children and no map types; `_NS` a
    non-null STRUCT holding the children given; `_NM` a non-null MAP with the
    key and value types given and no children."""
    var n = _NN("a", TYPE_FLOAT64)
    assert_equal(n.name, "a")
    assert_equal(n.dtype, TYPE_FLOAT64)
    assert_false(n.nullable)
    assert_equal(len(n.struct_fields), 0)
    assert_equal(n.map_key_dtype, TYPE_UNKNOWN)
    assert_equal(n.map_value_dtype, TYPE_UNKNOWN)
    var s = _nested()
    assert_equal(s.cols[1].dtype, TYPE_STRUCT)
    assert_false(s.cols[1].nullable)
    assert_equal(len(s.cols[1].struct_fields), 2)
    assert_equal(s.cols[1].struct_fields[1].name, "zip")
    assert_equal(s.cols[1].map_key_dtype, TYPE_UNKNOWN)
    assert_equal(s.cols[2].dtype, TYPE_MAP)
    assert_false(s.cols[2].nullable)
    assert_equal(len(s.cols[2].struct_fields), 0)
    assert_equal(s.cols[2].map_key_dtype, TYPE_STRING)
    assert_equal(s.cols[2].map_value_dtype, TYPE_INT64)


def test_lookups_hit_and_miss() raises:
    """Each name lookup returns the declared slot for a present column and
    its documented miss value for an absent one: contains False, safe_dtype
    and dtype_of UNKNOWN (-1), nullable_of False, index_of -1. The column
    looked up is not the first, so a lookup that stops at column 0 fails."""
    var s = _flat()
    assert_equal(s.num_cols(), 4)
    assert_true(s.contains("note"))
    assert_false(s.contains("nope"))
    assert_equal(s.safe_dtype("price"), TYPE_DECIMAL128)
    assert_equal(s.safe_dtype("nope"), TYPE_UNKNOWN)
    assert_equal(s.dtype_of("qty"), TYPE_INT32)
    assert_equal(s.dtype_of("nope"), TYPE_UNKNOWN)
    assert_true(s.nullable_of("price"))
    assert_false(s.nullable_of("qty"))
    assert_false(s.nullable_of("nope"))
    assert_equal(s.index_of("tiny"), 0)
    assert_equal(s.index_of("note"), 3)
    assert_equal(s.index_of("nope"), -1)


def test_row_layout_offsets_and_stride() raises:
    """Packed fixed-row image of INT8 | INT32 | DECIMAL128 | STRING: cells of
    1, 4, 16 and 8 bytes, so offsets 0, 1, 5, 21 and stride 29. An absent
    name and an index past the end both give the running total (29)."""
    var s = _flat()
    assert_equal(s.row_col_offset("tiny"), 0)
    assert_equal(s.row_col_offset("qty"), 1)
    assert_equal(s.row_col_offset("price"), 5)
    assert_equal(s.row_col_offset("note"), 21)
    assert_equal(s.row_col_offset("nope"), 29)
    assert_equal(s.row_fixed_stride(), 29)
    assert_equal(s.row_col_offset_by_index(0), 0)
    assert_equal(s.row_col_offset_by_index(1), 1)
    assert_equal(s.row_col_offset_by_index(2), 5)
    assert_equal(s.row_col_offset_by_index(3), 21)
    assert_equal(s.row_col_offset_by_index(4), 29)
    var empty = SchemaDescriptor(List[ColDescriptor](), False)
    assert_equal(empty.row_fixed_stride(), 0)


def test_names_joined() raises:
    """Comma-space separated, in declaration order, no trailing separator;
    empty for no column."""
    assert_equal(_flat().names_joined(), "tiny, qty, price, note")
    assert_equal(SchemaDescriptor(List[ColDescriptor](), False).names_joined(), "")


def test_project1_append_col_concat() raises:
    """`project1` is a single non-null column, never strict; `append_col`
    adds a non-null column at the end and keeps `strict`; `concat` is self's
    columns then other's (children and map types carried) with self's
    `strict`. None of them changes self."""
    var s = _flat()
    var p = s.project1("only", TYPE_UINT64)
    assert_equal(p.num_cols(), 1)
    assert_equal(p.cols[0].name, "only")
    assert_equal(p.cols[0].dtype, TYPE_UINT64)
    assert_false(p.cols[0].nullable)
    assert_false(p.strict)

    var a = s.append_col("flag", TYPE_BOOL)
    assert_equal(a.num_cols(), 5)
    assert_equal(a.names_joined(), "tiny, qty, price, note, flag")
    assert_equal(a.cols[4].dtype, TYPE_BOOL)
    assert_false(a.cols[4].nullable)
    assert_true(a.strict)
    assert_equal(s.num_cols(), 4)

    var c = s.concat(_nested())
    assert_equal(c.names_joined(), "tiny, qty, price, note, id, addr, tags")
    assert_true(c.strict)
    assert_equal(len(c.cols[5].struct_fields), 2)
    assert_equal(c.cols[6].map_value_dtype, TYPE_INT64)
    var c2 = _nested().concat(s)
    assert_false(c2.strict)
    assert_true(c2.cols[5].nullable)


def test_to_arrow_schema_flat() raises:
    """One field per column, in order, with the column's Arrow type and
    nullability, and no child for a leaf."""
    var sch = _flat().to_arrow_schema()
    assert_equal(sch.num_columns(), 4)
    assert_equal(sch.field_name(0), "tiny")
    assert_true(sch.field_arrow_type(0) == ArrowType.INT8)
    assert_true(sch.field_arrow_type(2) == ArrowType.DECIMAL128)
    assert_true(sch.field_nullable(2))
    assert_false(sch.field_nullable(3))
    assert_equal(sch.field_num_children(0), 0)
    assert_equal(sch.field_num_children(3), 0)


def test_to_arrow_schema_struct_and_map_children() raises:
    """A STRUCT field carries its children (name, Arrow type, nullability);
    a MAP field carries exactly `key` (non-null) and `value` (nullable) of
    its declared types; a leaf beside them none."""
    var kids: List[ColDescriptor] = [
        _col("street", TYPE_STRING, True), _col("zip", TYPE_DATE32, False),
    ]
    var c: List[ColDescriptor] = [
        _NN("id", TYPE_INT64),
        _NS("addr", kids^),
        _NM("tags", TYPE_STRING, TYPE_INT16),
    ]
    var sch = SchemaDescriptor(c^, False).to_arrow_schema()
    assert_equal(sch.num_columns(), 3)
    assert_equal(sch.field_num_children(0), 0)
    assert_true(sch.field_arrow_type(1) == ArrowType.STRUCT)
    assert_equal(sch.field_num_children(1), 2)
    assert_equal(sch.field_child_name(1, 0), "street")
    assert_true(sch.field_child_arrow_type(1, 0) == ArrowType.STRING)
    assert_true(sch.field_child_nullable(1, 0))
    assert_equal(sch.field_child_name(1, 1), "zip")
    assert_true(sch.field_child_arrow_type(1, 1) == ArrowType.INT32)
    assert_false(sch.field_child_nullable(1, 1))
    assert_true(sch.field_arrow_type(2) == ArrowType.MAP)
    assert_equal(sch.field_num_children(2), 2)
    assert_equal(sch.field_child_name(2, 0), "key")
    assert_true(sch.field_child_arrow_type(2, 0) == ArrowType.STRING)
    assert_false(sch.field_child_nullable(2, 0))
    assert_equal(sch.field_child_name(2, 1), "value")
    assert_true(sch.field_child_arrow_type(2, 1) == ArrowType.INT16)
    assert_true(sch.field_child_nullable(2, 1))


def test_comptime_column_helpers() raises:
    """`has_col`, `dtype_at` (UNKNOWN when absent) and `col_list` on a
    comptime schema."""
    assert_true(has_col[LONG, "customer_account_balance_amt"]())
    assert_false(has_col[LONG, "customer_account_missing_col"]())
    assert_equal(dtype_at[LONG, "customer_account_balance_amt"](), TYPE_FLOAT64)
    assert_equal(dtype_at[LONG, "customer_account_missing_col"](), TYPE_UNKNOWN)
    assert_equal(
        col_list[LONG](),
        "customer_account_identifier, customer_account_balance_amt",
    )


def test_struct_field_index_every_outcome() raises:
    """The child's index when present (1 for the second child), else -1 for
    each failure the docstring names: column absent, column not STRUCT,
    child absent."""
    var s = _nested()
    assert_equal(_safe_struct_field_index(s, "addr", "street"), 0)
    assert_equal(_safe_struct_field_index(s, "addr", "zip"), 1)
    assert_equal(_safe_struct_field_index(s, "nope", "zip"), -1)
    assert_equal(_safe_struct_field_index(s, "id", "zip"), -1)
    assert_equal(_safe_struct_field_index(s, "addr", "city"), -1)
    assert_equal(comptime_struct_field_index[NESTED, "addr", "zip"](), 1)
    assert_equal(comptime_struct_field_index[NESTED, "tags", "zip"](), -1)


def test_struct_child_dtype_every_outcome() raises:
    var s = _nested()
    assert_equal(_safe_struct_child_dtype(s, "addr", "street"), TYPE_STRING)
    assert_equal(_safe_struct_child_dtype(s, "addr", "zip"), TYPE_INT32)
    assert_equal(_safe_struct_child_dtype(s, "nope", "zip"), TYPE_UNKNOWN)
    assert_equal(_safe_struct_child_dtype(s, "tags", "zip"), TYPE_UNKNOWN)
    assert_equal(_safe_struct_child_dtype(s, "addr", "city"), TYPE_UNKNOWN)
    assert_equal(comptime_struct_child_dtype[NESTED, "addr", "zip"](), TYPE_INT32)
    assert_equal(comptime_struct_child_dtype[NESTED, "addr", "city"](), TYPE_UNKNOWN)


def test_struct_field_names_joined_every_outcome() raises:
    """The children's names comma-space joined, or the two documented
    placeholders for a non-STRUCT column and an absent one; a STRUCT with no
    child joins to the empty string."""
    var s = _nested()
    assert_equal(_struct_field_names_joined(s, "addr"), "street, zip")
    assert_equal(_struct_field_names_joined(s, "id"), "<not a STRUCT column>")
    assert_equal(_struct_field_names_joined(s, "nope"), "<no such column>")
    var c: List[ColDescriptor] = [_NS("hollow", List[ColDescriptor]())]
    assert_equal(_struct_field_names_joined(SchemaDescriptor(c^, False), "hollow"), "")
    assert_equal(struct_field_list[NESTED, "addr"](), "street, zip")
    assert_equal(struct_field_list[NESTED, "tags"](), "<not a STRUCT column>")


def test_map_key_and_value_dtype_every_outcome() raises:
    """The MAP column's declared key and value types; UNKNOWN for a column
    that is not a MAP and for an absent one. The MAP is the last column, so a
    lookup that stops early misses it."""
    var s = _nested()
    assert_equal(_safe_map_key_dtype(s, "tags"), TYPE_STRING)
    assert_equal(_safe_map_key_dtype(s, "addr"), TYPE_UNKNOWN)
    assert_equal(_safe_map_key_dtype(s, "nope"), TYPE_UNKNOWN)
    assert_equal(_safe_map_value_dtype(s, "tags"), TYPE_INT64)
    assert_equal(_safe_map_value_dtype(s, "id"), TYPE_UNKNOWN)
    assert_equal(_safe_map_value_dtype(s, "nope"), TYPE_UNKNOWN)
    assert_equal(comptime_map_key_dtype[NESTED, "tags"](), TYPE_STRING)
    assert_equal(comptime_map_value_dtype[NESTED, "tags"](), TYPE_INT64)
    assert_equal(comptime_map_value_dtype[NESTED, "addr"](), TYPE_UNKNOWN)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
