# =============================================================================
# Tests for schema_descriptor.mojo: dtype tags, their maps to `DType` and to
# Arrow type ids, `SchemaDescriptor`'s lookups, the `schema_of` arities and
# the reflection-derived default schema.
#
# Oracles: the tag table at the top of the module (DT_I8 = 0 .. DT_DECIMAL128
# = 15), Arrow's own type ids (`ArrowType.*`), and the storage rules the
# docstrings state (DATE32 is int32 days, DATE64 and TIMESTAMP are int64).
#
# What each test proves (and the defect it catches):
#   - test_dtag_name / test_dtag_to_dtype / test_dtype_to_dtag /
#     test_dtag_to_arrow_type_id / test_dtag_of_arrow_type_id: one assertion
#     per arm, so a swapped pair of arms (I16 <-> U16, F32 <-> F64), a missing
#     arm falling to the default, or a wrong storage dtype for DATE/TIMESTAMP
#     goes red. Round trips (dtype -> tag -> dtype, tag -> arrow id -> tag)
#     pin the pairs to be each other's inverse where the docstrings say so.
#   - test_dtag_is_simd_bounds: both ends of the SIMD range (0 and 14) and one
#     past each (-1, 16), and STRING in the middle, checked at compile time
#     (see the test for why).
#   - test_schema_descriptor_lookups: hit at the first and the LAST column (a
#     loop that stops one short is caught), miss, empty schema, names_joined
#     separators for 0, 1 and 3 columns, concat order and that it leaves its
#     operands unchanged.
#   - test_schema_of_arities: every overload (1..6 and 8 columns) keeps every
#     name and tag in order, nullable True.
#   - test_derive_schema: a row struct with one field of each mapped Mojo type
#     derives those tags by field name in declared order; a field of a type
#     outside the allow-list (`Int`) derives DT_UNKNOWN, never a guess.
#
# Not pinned (see the coverage report's findings): the fall-through answers
# for tags that have no Arrow type id or no scalar DType (DT_STRING and
# DT_UNKNOWN in `dtag_to_dtype`, DT_DECIMAL128 and DT_UNKNOWN in
# `dtag_to_arrow_type_id`), `dtag_is_simd(DT_DECIMAL128)` and
# `dtag_of_arrow_type_id` of DATE32 / DECIMAL128: each is a placeholder the
# docstrings do not define, so those lines are reached with no assertion on
# the value.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_udf.schema_descriptor import (
    ColDescriptor,
    SchemaDescriptor,
    DT_UNKNOWN,
    DT_I8,
    DT_I16,
    DT_I32,
    DT_I64,
    DT_U8,
    DT_U16,
    DT_U32,
    DT_U64,
    DT_F32,
    DT_F64,
    DT_BOOL,
    DT_STRING,
    DT_DATE32,
    DT_DATE64,
    DT_TIMESTAMP,
    DT_DECIMAL128,
    dtag_name,
    dtag_to_dtype,
    dtype_to_dtag,
    dtag_to_arrow_type_id,
    dtag_of_arrow_type_id,
    dtag_is_simd,
    schema_of,
    _derive_schema,
)


def test_tag_numbering() raises:
    # The numbering is shared with another module's TYPE_* table; a renumbered
    # tag silently re-types every column that crosses between the two.
    var tags: List[Int] = [
        DT_I8, DT_I16, DT_I32, DT_I64, DT_U8, DT_U16, DT_U32, DT_U64,
        DT_F32, DT_F64, DT_BOOL, DT_STRING, DT_DATE32, DT_DATE64,
        DT_TIMESTAMP, DT_DECIMAL128,
    ]
    for i in range(len(tags)):
        assert_equal(tags[i], i)
    assert_equal(DT_UNKNOWN, -1)


def test_dtag_name() raises:
    var want: List[String] = [
        "Int8", "Int16", "Int32", "Int64", "UInt8", "UInt16", "UInt32",
        "UInt64", "Float32", "Float64", "Bool", "String", "Date32", "Date64",
        "Timestamp", "Decimal128",
    ]
    for t in range(len(want)):
        assert_equal(dtag_name(t), want[t], String("dtag_name ") + String(t))
    assert_equal(dtag_name(DT_UNKNOWN), "?")
    assert_equal(dtag_name(16), "?")


def test_dtag_to_dtype() raises:
    assert_equal(dtag_to_dtype(DT_I8), DType.int8)
    assert_equal(dtag_to_dtype(DT_I16), DType.int16)
    assert_equal(dtag_to_dtype(DT_I32), DType.int32)
    assert_equal(dtag_to_dtype(DT_I64), DType.int64)
    assert_equal(dtag_to_dtype(DT_U8), DType.uint8)
    assert_equal(dtag_to_dtype(DT_U16), DType.uint16)
    assert_equal(dtag_to_dtype(DT_U32), DType.uint32)
    assert_equal(dtag_to_dtype(DT_U64), DType.uint64)
    assert_equal(dtag_to_dtype(DT_F32), DType.float32)
    assert_equal(dtag_to_dtype(DT_F64), DType.float64)
    assert_equal(dtag_to_dtype(DT_BOOL), DType.bool)
    # Storage dtypes: Date32 is int32 days, Date64 and Timestamp are int64.
    assert_equal(dtag_to_dtype(DT_DATE32), DType.int32)
    assert_equal(dtag_to_dtype(DT_DATE64), DType.int64)
    assert_equal(dtag_to_dtype(DT_TIMESTAMP), DType.int64)
    # A Decimal128 cell is 16 bytes: an int128 read, never an int64 one.
    assert_equal(dtag_to_dtype(DT_DECIMAL128), DType.int128)
    # STRING has no scalar DType; the docstring says callers must guard.
    # The value returned is a placeholder, reached here but not pinned.
    _ = dtag_to_dtype(DT_STRING)


def test_dtype_to_dtag() raises:
    var dts: List[DType] = [
        DType.int8, DType.int16, DType.int32, DType.int64, DType.uint8,
        DType.uint16, DType.uint32, DType.uint64, DType.float32,
        DType.float64, DType.bool,
    ]
    for i in range(len(dts)):
        # The tag of the i-th dtype is i, and the round trip is the identity.
        assert_equal(dtype_to_dtag(dts[i]), i, String("dtype_to_dtag ") + String(i))
        assert_equal(dtag_to_dtype(dtype_to_dtag(dts[i])), dts[i])
    # Allow-list: a dtype with no tag reports DT_UNKNOWN, not a neighbour.
    assert_equal(dtype_to_dtag(DType.float16), DT_UNKNOWN)
    assert_equal(dtype_to_dtag(DType.uint128), DT_UNKNOWN)


def test_dtag_to_arrow_type_id() raises:
    assert_equal(dtag_to_arrow_type_id(DT_I8), ArrowType.INT8.type_id)
    assert_equal(dtag_to_arrow_type_id(DT_I16), ArrowType.INT16.type_id)
    assert_equal(dtag_to_arrow_type_id(DT_I32), ArrowType.INT32.type_id)
    assert_equal(dtag_to_arrow_type_id(DT_I64), ArrowType.INT64.type_id)
    assert_equal(dtag_to_arrow_type_id(DT_U8), ArrowType.UINT8.type_id)
    assert_equal(dtag_to_arrow_type_id(DT_U16), ArrowType.UINT16.type_id)
    assert_equal(dtag_to_arrow_type_id(DT_U32), ArrowType.UINT32.type_id)
    assert_equal(dtag_to_arrow_type_id(DT_U64), ArrowType.UINT64.type_id)
    assert_equal(dtag_to_arrow_type_id(DT_F32), ArrowType.FLOAT32.type_id)
    assert_equal(dtag_to_arrow_type_id(DT_F64), ArrowType.FLOAT64.type_id)
    assert_equal(dtag_to_arrow_type_id(DT_BOOL), ArrowType.BOOL.type_id)
    assert_equal(dtag_to_arrow_type_id(DT_STRING), ArrowType.STRING.type_id)
    # These pin the CURRENT physical mapping (DATE32 -> INT32 days, DATE64 /
    # TIMESTAMP -> INT64), not a missing Arrow type: Arrow DATE32 exists and
    # the CSV reader emits it. komira#974 would map these tags to Arrow's own
    # date / timestamp ids and change these three rows.
    assert_equal(dtag_to_arrow_type_id(DT_DATE32), ArrowType.INT32.type_id)
    assert_equal(dtag_to_arrow_type_id(DT_DATE64), ArrowType.INT64.type_id)
    assert_equal(dtag_to_arrow_type_id(DT_TIMESTAMP), ArrowType.INT64.type_id)
    # No defined answer for a tag with no Arrow id (finding: DECIMAL128 also
    # falls here); reached, not pinned.
    _ = dtag_to_arrow_type_id(DT_UNKNOWN)


def test_dtag_of_arrow_type_id() raises:
    # Each of the twelve tags with its own Arrow id round-trips.
    for t in range(DT_STRING + 1):
        assert_equal(
            dtag_of_arrow_type_id(dtag_to_arrow_type_id(t)),
            t,
            String("arrow id round trip for tag ") + String(t),
        )
    # Arrow types no tag stands for report DT_UNKNOWN.
    assert_equal(dtag_of_arrow_type_id(ArrowType.BINARY.type_id), DT_UNKNOWN)
    assert_equal(dtag_of_arrow_type_id(ArrowType.LIST.type_id), DT_UNKNOWN)
    assert_equal(dtag_of_arrow_type_id(ArrowType.FLOAT16.type_id), DT_UNKNOWN)


def test_dtag_is_simd_bounds() raises:
    # Evaluated at compile time on purpose: compiled into the test,
    # `dtag_is_simd`'s returned `and` chain is a shape the branch classifier
    # refuses (komira-ai/komira#872), which would leave this library's branch
    # records unbuilt. A wrong answer here is still a red build.
    comptime assert not dtag_is_simd(DT_UNKNOWN)
    comptime assert dtag_is_simd(DT_I8)
    comptime assert dtag_is_simd(DT_BOOL)
    comptime assert not dtag_is_simd(DT_STRING)
    comptime assert dtag_is_simd(DT_DATE32)
    comptime assert dtag_is_simd(DT_TIMESTAMP)
    comptime assert not dtag_is_simd(16)
    comptime assert not dtag_is_simd(-2)


def _three() -> SchemaDescriptor:
    return SchemaDescriptor([
        ColDescriptor("a", DT_I64, True),
        ColDescriptor("b", DT_F64, False),
        ColDescriptor("c", DT_STRING, True),
    ])


def test_schema_descriptor_lookups() raises:
    var s = _three()
    assert_equal(s.num_cols(), 3)
    assert_true(s.contains("a"))
    assert_true(s.contains("c"))
    assert_false(s.contains("d"))
    assert_false(s.contains(""))
    assert_equal(s.safe_dtype("a"), DT_I64)
    assert_equal(s.safe_dtype("c"), DT_STRING)
    assert_equal(s.safe_dtype("zz"), DT_UNKNOWN)
    assert_equal(s.index_of("a"), 0)
    assert_equal(s.index_of("b"), 1)
    assert_equal(s.index_of("c"), 2)
    assert_equal(s.index_of("A"), -1)
    assert_equal(s.names_joined(), "a, b, c")

    var empty = SchemaDescriptor(List[ColDescriptor]())
    assert_equal(empty.num_cols(), 0)
    assert_false(empty.contains("a"))
    assert_equal(empty.safe_dtype("a"), DT_UNKNOWN)
    assert_equal(empty.index_of("a"), -1)
    assert_equal(empty.names_joined(), "")

    var one = SchemaDescriptor([ColDescriptor("x", DT_BOOL, True)])
    assert_equal(one.names_joined(), "x")

    # A duplicate name resolves to its FIRST column.
    var dup = SchemaDescriptor([
        ColDescriptor("k", DT_I32, True),
        ColDescriptor("k", DT_F32, True),
    ])
    assert_equal(dup.index_of("k"), 0)
    assert_equal(dup.safe_dtype("k"), DT_I32)


def test_concat() raises:
    var left = _three()
    var right = SchemaDescriptor([
        ColDescriptor("d", DT_U8, False),
        ColDescriptor("e", DT_DATE32, True),
    ])
    var both = left.concat(right)
    assert_equal(both.num_cols(), 5)
    assert_equal(both.names_joined(), "a, b, c, d, e")
    assert_equal(both.safe_dtype("e"), DT_DATE32)
    assert_false(both.cols[3].nullable)
    assert_true(both.cols[4].nullable)
    assert_false(both.cols[1].nullable)
    # The operands are unchanged.
    assert_equal(left.num_cols(), 3)
    assert_equal(right.num_cols(), 2)
    var none = left.concat(SchemaDescriptor(List[ColDescriptor]()))
    assert_equal(none.names_joined(), "a, b, c")


def _check(s: SchemaDescriptor, names: List[String], tags: List[Int]) raises:
    assert_equal(s.num_cols(), len(names))
    for i in range(len(names)):
        assert_equal(s.cols[i].name, names[i])
        assert_equal(s.cols[i].dtype, tags[i])
        assert_true(s.cols[i].nullable)


def test_schema_of_arities() raises:
    _check(schema_of["a", DT_I8](), ["a"], [DT_I8])
    _check(schema_of["a", DT_I8, "b", DT_I16](), ["a", "b"], [DT_I8, DT_I16])
    _check(
        schema_of["a", DT_I8, "b", DT_I16, "c", DT_I32](),
        ["a", "b", "c"],
        [DT_I8, DT_I16, DT_I32],
    )
    _check(
        schema_of["a", DT_I8, "b", DT_I16, "c", DT_I32, "d", DT_I64](),
        ["a", "b", "c", "d"],
        [DT_I8, DT_I16, DT_I32, DT_I64],
    )
    _check(
        schema_of["a", DT_I8, "b", DT_I16, "c", DT_I32, "d", DT_I64, "e", DT_U8](),
        ["a", "b", "c", "d", "e"],
        [DT_I8, DT_I16, DT_I32, DT_I64, DT_U8],
    )
    _check(
        schema_of[
            "a", DT_I8, "b", DT_I16, "c", DT_I32, "d", DT_I64, "e", DT_U8,
            "f", DT_U16,
        ](),
        ["a", "b", "c", "d", "e", "f"],
        [DT_I8, DT_I16, DT_I32, DT_I64, DT_U8, DT_U16],
    )
    _check(
        schema_of[
            "a", DT_I8, "b", DT_I16, "c", DT_I32, "d", DT_I64, "e", DT_U8,
            "f", DT_U16, "g", DT_U32, "h", DT_U64,
        ](),
        ["a", "b", "c", "d", "e", "f", "g", "h"],
        [DT_I8, DT_I16, DT_I32, DT_I64, DT_U8, DT_U16, DT_U32, DT_U64],
    )


@fieldwise_init
struct _EveryType(Copyable, Movable):
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
    var f_bool: Bool
    var f_str: String
    var f_int: Int


def test_derive_schema() raises:
    var s = _derive_schema[_EveryType]()
    _check(
        s,
        [
            "f_i8", "f_i16", "f_i32", "f_i64", "f_u8", "f_u16", "f_u32",
            "f_u64", "f_f32", "f_f64", "f_bool", "f_str", "f_int",
        ],
        [
            DT_I8, DT_I16, DT_I32, DT_I64, DT_U8, DT_U16, DT_U32, DT_U64,
            DT_F32, DT_F64, DT_BOOL, DT_STRING, DT_UNKNOWN,
        ],
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
