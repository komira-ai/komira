# =============================================================================
# Tests for komira_jsonl/columnar_materializer.mojo — JSON Stage 2 walker.
# =============================================================================
#
# Covers the flat scalar subset (INT64, BOOL, STRING columns; flat
# top-level objects; JSONL input).
#
# Coverage (inline fixtures):
#   T1  Empty input  → empty RecordBatch (0 rows).
#   T2  Single Int64 column, 3 rows.
#   T3  Mixed INT64 + STRING + BOOL, 3 rows.
#   T4  Missing-key row → null in that column.
#   T5  Explicit null value (`"x": null`) → null in that column.
#   T6  Escaped string (`"k":"a\\nb"`) → unescaped output.
#   T7  Negative integer.
#   T8  Key not in schema → silently skipped.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.schema import Schema, SchemaBuilder, Field
from komira_core.arrow.string_array import StringArray

from komira_jsonl.columnar_materializer import materialize_jsonl_to_batch
from komira_jsonl.key_dispatch import KeyTable, KeyRegistryBuilder
from komira_jsonl.value_parsers.parse_int import parse_int_i64
from komira_jsonl.value_parsers.parse_bool import parse_bool, parse_null
from komira_json_index.parse_string import (
    parse_string,
    parse_string_raw,
    parse_string_with_escapes,
)


# =============================================================================
# Helpers
# =============================================================================


def _schema_i64(name: String) -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field(name, ArrowType.INT64, True))
    return sb.build()


def _schema_i64_str_bool(n1: String, n2: String, n3: String) -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field(n1, ArrowType.INT64, True))
    sb.add_field(Field(n2, ArrowType.STRING, True))
    sb.add_field(Field(n3, ArrowType.BOOL, True))
    return sb.build()


# =============================================================================
# parse_int_i64 — direct tests
# =============================================================================


def test_parse_int_simple() raises:
    var s = String("12345")
    var b = s.as_bytes()
    assert_equal(Int(parse_int_i64(b, 0, len(b))), 12345)


def test_parse_int_negative() raises:
    var s = String("-42")
    var b = s.as_bytes()
    assert_equal(Int(parse_int_i64(b, 0, len(b))), -42)


def test_parse_int_zero() raises:
    var s = String("0")
    var b = s.as_bytes()
    assert_equal(Int(parse_int_i64(b, 0, len(b))), 0)


def test_parse_int_max() raises:
    var s = String("9223372036854775807")  # Int64.MAX
    var b = s.as_bytes()
    assert_equal(Int(parse_int_i64(b, 0, len(b))), 9223372036854775807)


def test_parse_int_min() raises:
    var s = String("-9223372036854775808")  # Int64.MIN
    var b = s.as_bytes()
    var v = parse_int_i64(b, 0, len(b))
    assert_true(v == Int64(-9223372036854775808))


def test_parse_int_overflow_raises() raises:
    var s = String("9223372036854775808")  # Int64.MAX + 1
    var b = s.as_bytes()
    var raised = False
    try:
        var _v = parse_int_i64(b, 0, len(b))
    except _:
        raised = True
    assert_true(raised)


def test_parse_int_empty_raises() raises:
    var s = String("")
    var b = s.as_bytes()
    var raised = False
    try:
        var _v = parse_int_i64(b, 0, len(b))
    except _:
        raised = True
    assert_true(raised)


def test_parse_int_garbage_raises() raises:
    var s = String("abc")
    var b = s.as_bytes()
    var raised = False
    try:
        var _v = parse_int_i64(b, 0, len(b))
    except _:
        raised = True
    assert_true(raised)


# =============================================================================
# parse_bool — direct tests
# =============================================================================


def test_parse_bool_true() raises:
    var s = String("true")
    var b = s.as_bytes()
    assert_true(parse_bool(b, 0, len(b)))


def test_parse_bool_false() raises:
    var s = String("false")
    var b = s.as_bytes()
    assert_false(parse_bool(b, 0, len(b)))


def test_parse_bool_wrong_case_raises() raises:
    var s = String("True")
    var b = s.as_bytes()
    var raised = False
    try:
        var _v = parse_bool(b, 0, len(b))
    except _:
        raised = True
    assert_true(raised)


def test_parse_bool_garbage_raises() raises:
    var s = String("yes")
    var b = s.as_bytes()
    var raised = False
    try:
        var _v = parse_bool(b, 0, len(b))
    except _:
        raised = True
    assert_true(raised)


def test_parse_null_ok() raises:
    var s = String("null")
    var b = s.as_bytes()
    parse_null(b, 0, len(b))


def test_parse_null_garbage_raises() raises:
    var s = String("nil")
    var b = s.as_bytes()
    var raised = False
    try:
        parse_null(b, 0, len(b))
    except _:
        raised = True
    assert_true(raised)


# =============================================================================
# parse_string — direct tests
# =============================================================================


def test_parse_string_raw() raises:
    var s = String("hello")
    var b = s.as_bytes()
    var out = parse_string_raw(b, 0, len(b))
    assert_equal(out, String("hello"))


def test_parse_string_escapes_newline() raises:
    var s = String("a\\nb")  # raw 4 bytes: a \ n b
    var b = s.as_bytes()
    var out = parse_string_with_escapes(b, 0, len(b))
    # Output should be "a\nb" (3 bytes: a, LF, b).
    assert_equal(len(out.as_bytes()), 3)
    assert_equal(out.as_bytes()[0], UInt8(0x61))  # a
    assert_equal(out.as_bytes()[1], UInt8(0x0A))  # \n
    assert_equal(out.as_bytes()[2], UInt8(0x62))  # b


def test_parse_string_escapes_quote() raises:
    var s = String("a\\\"b")  # raw 4 bytes: a \ " b
    var b = s.as_bytes()
    var out = parse_string_with_escapes(b, 0, len(b))
    assert_equal(len(out.as_bytes()), 3)
    assert_equal(out.as_bytes()[1], UInt8(0x22))  # "


# =============================================================================
# KeyTable — direct tests
# =============================================================================


def test_keytable_lookup_present() raises:
    var names = List[String]()
    names.append(String("foo"))
    names.append(String("bar"))
    names.append(String("baz"))
    var kt = KeyTable.from_field_names(names^)
    var k = String("bar")
    var bs = k.as_bytes()
    assert_equal(kt.lookup(bs), 1)


def test_keytable_lookup_absent() raises:
    var names = List[String]()
    names.append(String("foo"))
    names.append(String("bar"))
    var kt = KeyTable.from_field_names(names^)
    var k = String("qux")
    var bs = k.as_bytes()
    assert_equal(kt.lookup(bs), -1)


def test_keytable_lookup_length_distinguishes() raises:
    var names = List[String]()
    names.append(String("a"))
    names.append(String("ab"))
    names.append(String("abc"))
    var kt = KeyTable.from_field_names(names^)
    var k1 = String("a")
    assert_equal(kt.lookup(k1.as_bytes()), 0)
    var k2 = String("ab")
    assert_equal(kt.lookup(k2.as_bytes()), 1)
    var k3 = String("abc")
    assert_equal(kt.lookup(k3.as_bytes()), 2)


# =============================================================================
# KeyTable hash arm + KeyRegistryBuilder
# =============================================================================
#
# At K >= 8, KeyTable switches to FNV-1a hash + open-addressing. These tests
# exercise the hash arm by using >=8 field names. Also tests
# KeyRegistryBuilder — the dynamic-K key registry used by the schema
# inferrer (`_infer_partial_into`) for per-record lookup-or-insert by byte
# span (no per-call String allocation on the hit path).


def test_keytable_hash_arm_lookup_lineitem_shape() raises:
    """K=16 fields (TPC-H lineitem shape) → hash arm. Every key resolves
    to its insertion index; absent keys return -1."""
    var names = List[String]()
    names.append(String("l_orderkey"))
    names.append(String("l_partkey"))
    names.append(String("l_suppkey"))
    names.append(String("l_linenumber"))
    names.append(String("l_quantity"))
    names.append(String("l_extendedprice"))
    names.append(String("l_discount"))
    names.append(String("l_tax"))
    names.append(String("l_returnflag"))
    names.append(String("l_linestatus"))
    names.append(String("l_shipdate"))
    names.append(String("l_commitdate"))
    names.append(String("l_receiptdate"))
    names.append(String("l_shipinstruct"))
    names.append(String("l_shipmode"))
    names.append(String("l_comment"))
    var kt = KeyTable.from_field_names(names^)
    # Sanity: K=16 should activate hash arm.
    assert_equal(kt.size(), 16)
    # Look up each key by its byte span — must return its insertion idx.
    var k0 = String("l_orderkey")
    assert_equal(kt.lookup(k0.as_bytes()), 0)
    var k8 = String("l_returnflag")
    assert_equal(kt.lookup(k8.as_bytes()), 8)
    var k15 = String("l_comment")
    assert_equal(kt.lookup(k15.as_bytes()), 15)
    # Absent key returns -1.
    var absent = String("l_does_not_exist")
    assert_equal(kt.lookup(absent.as_bytes()), -1)
    # Empty span returns -1 (not in schema, FNV(empty) is well-defined).
    var empty = String("")
    assert_equal(kt.lookup(empty.as_bytes()), -1)


def test_keytable_hash_arm_collision_correctness() raises:
    """Even when FNV-1a happens to collide, the length+memcmp tiebreak
    ensures the right key wins. We can't easily construct a collision
    against FNV-1a deterministically without a search, but we CAN verify
    no false hits for similar-shaped keys (a/b/c prefix)."""
    var names = List[String]()
    names.append(String("alpha"))
    names.append(String("beta"))
    names.append(String("gamma"))
    names.append(String("delta"))
    names.append(String("epsilon"))
    names.append(String("zeta"))
    names.append(String("eta"))
    names.append(String("theta"))
    names.append(String("iota"))
    var kt = KeyTable.from_field_names(names^)
    var k0 = String("alpha")
    assert_equal(kt.lookup(k0.as_bytes()), 0)
    var k3 = String("delta")
    assert_equal(kt.lookup(k3.as_bytes()), 3)
    # A key absent from the schema with a similar shape: ensure -1.
    var almost = String("alpah")  # transposed letters
    assert_equal(kt.lookup(almost.as_bytes()), -1)


def test_keyregistrybuilder_first_seen_insertion_order() raises:
    """First-seen keys must be inserted in walk order so the inferrer's
    output Schema preserves source order. Repeated lookups return the
    same index."""
    var b = KeyRegistryBuilder()
    var k1 = String("foo")
    assert_equal(b.lookup_or_insert_bytes(k1.as_bytes()), 0)
    var k2 = String("bar")
    assert_equal(b.lookup_or_insert_bytes(k2.as_bytes()), 1)
    var k3 = String("baz")
    assert_equal(b.lookup_or_insert_bytes(k3.as_bytes()), 2)
    # Re-lookups stay stable.
    var k1a = String("foo")
    assert_equal(b.lookup_or_insert_bytes(k1a.as_bytes()), 0)
    var k2a = String("bar")
    assert_equal(b.lookup_or_insert_bytes(k2a.as_bytes()), 1)
    assert_equal(b.size(), 3)


def test_keyregistrybuilder_grows_past_initial_capacity() raises:
    """Initial capacity 16 → with load factor 0.5 → ~8 keys triggers
    rehash. Verify correctness across the boundary (insert 32 keys)."""
    var b = KeyRegistryBuilder()
    var i = 0
    while i < 32:
        var k = String("k") + String(i)
        var idx = b.lookup_or_insert_bytes(k.as_bytes())
        assert_equal(idx, i)
        i = i + 1
    # Re-lookup each at its expected index after multiple rehashes.
    assert_equal(b.size(), 32)
    var k0 = String("k0")
    assert_equal(b.lookup_or_insert_bytes(k0.as_bytes()), 0)
    var k15 = String("k15")
    assert_equal(b.lookup_or_insert_bytes(k15.as_bytes()), 15)
    var k31 = String("k31")
    assert_equal(b.lookup_or_insert_bytes(k31.as_bytes()), 31)


def test_keyregistrybuilder_into_names_preserves_order() raises:
    """into_names() returns the keys in first-seen-insert order so the
    SchemaBuilder downstream produces a schema with the right field
    ordering."""
    var b = KeyRegistryBuilder()
    var k1 = String("zulu")
    _ = b.lookup_or_insert_bytes(k1.as_bytes())
    var k2 = String("alpha")
    _ = b.lookup_or_insert_bytes(k2.as_bytes())
    var k3 = String("mike")
    _ = b.lookup_or_insert_bytes(k3.as_bytes())
    var names = b^.into_names()
    assert_equal(len(names), 3)
    assert_equal(names[0], String("zulu"))
    assert_equal(names[1], String("alpha"))
    assert_equal(names[2], String("mike"))


# =============================================================================
# End-to-end materializer — INT64
# =============================================================================


def test_materialize_single_int_col_3_rows() raises:
    var input = String('{"x":1}\n{"x":2}\n{"x":3}\n')
    var bytes = input.as_bytes()
    var schema = _schema_i64(String("x"))
    var batch = materialize_jsonl_to_batch(bytes, schema^)
    assert_equal(batch._num_rows, 3)
    assert_equal(batch.num_columns(), 1)


def test_materialize_negative_int() raises:
    var input = String('{"x":-42}\n{"x":-1}\n')
    var bytes = input.as_bytes()
    var schema = _schema_i64(String("x"))
    var batch = materialize_jsonl_to_batch(bytes, schema^)
    assert_equal(batch._num_rows, 2)


def test_materialize_int_with_null() raises:
    var input = String('{"x":1}\n{"x":null}\n{"x":3}\n')
    var bytes = input.as_bytes()
    var schema = _schema_i64(String("x"))
    var batch = materialize_jsonl_to_batch(bytes, schema^)
    assert_equal(batch._num_rows, 3)
    # Null fidelity: explicit `null` must set the validity bit.
    assert_equal(
        batch.column_at(0).null_count(), 1,
        "explicit null Int64 must produce 1 null, not collapse to 0",
    )
    assert_true(
        batch.column_as_primitive_int64(0).is_null(1),
        "row index 1 (explicit null) must be null",
    )


def test_materialize_int_missing_key_becomes_null() raises:
    var input = String('{"x":1}\n{}\n{"x":3}\n')
    var bytes = input.as_bytes()
    var schema = _schema_i64(String("x"))
    var batch = materialize_jsonl_to_batch(bytes, schema^)
    assert_equal(batch._num_rows, 3)
    # Null fidelity: a missing key must set the validity bit.
    assert_equal(
        batch.column_at(0).null_count(), 1,
        "missing-key Int64 row must produce 1 null, not collapse to 0",
    )
    assert_true(
        batch.column_as_primitive_int64(0).is_null(1),
        "row index 1 (missing key) must be null",
    )


# =============================================================================
# End-to-end — mixed INT64 + STRING + BOOL
# =============================================================================


def test_materialize_mixed_3_cols() raises:
    var input = String('{"id":1,"name":"alice","active":true}\n{"id":2,"name":"bob","active":false}\n')
    var bytes = input.as_bytes()
    var schema = _schema_i64_str_bool(String("id"), String("name"), String("active"))
    var batch = materialize_jsonl_to_batch(bytes, schema^)
    assert_equal(batch._num_rows, 2)
    assert_equal(batch.num_columns(), 3)


def test_materialize_extra_key_skipped() raises:
    """Keys in input not in schema must be silently skipped."""
    var input = String('{"id":1,"name":"alice","unused":42}\n{"id":2,"name":"bob","extra":"x"}\n')
    var bytes = input.as_bytes()
    var sb = SchemaBuilder()
    sb.add_field(Field(String("id"), ArrowType.INT64, True))
    sb.add_field(Field(String("name"), ArrowType.STRING, True))
    var schema = sb.build()
    var batch = materialize_jsonl_to_batch(bytes, schema^)
    assert_equal(batch._num_rows, 2)
    assert_equal(batch.num_columns(), 2)


def test_materialize_empty_input() raises:
    var input = String("")
    var bytes = input.as_bytes()
    var schema = _schema_i64(String("x"))
    var batch = materialize_jsonl_to_batch(bytes, schema^)
    assert_equal(batch._num_rows, 0)
    assert_equal(batch.num_columns(), 1)


# =============================================================================
# Driver
# =============================================================================


def main() raises:
    print("test_columnar_materializer — Stage 2 walker suite")

    # parse_int direct
    test_parse_int_simple()
    test_parse_int_negative()
    test_parse_int_zero()
    test_parse_int_max()
    test_parse_int_min()
    test_parse_int_overflow_raises()
    test_parse_int_empty_raises()
    test_parse_int_garbage_raises()

    # parse_bool / parse_null direct
    test_parse_bool_true()
    test_parse_bool_false()
    test_parse_bool_wrong_case_raises()
    test_parse_bool_garbage_raises()
    test_parse_null_ok()
    test_parse_null_garbage_raises()

    # parse_string direct
    test_parse_string_raw()
    test_parse_string_escapes_newline()
    test_parse_string_escapes_quote()

    # KeyTable direct (cmp-cascade arm)
    test_keytable_lookup_present()
    test_keytable_lookup_absent()
    test_keytable_lookup_length_distinguishes()

    # KeyTable hash arm + KeyRegistryBuilder 
    test_keytable_hash_arm_lookup_lineitem_shape()
    test_keytable_hash_arm_collision_correctness()
    test_keyregistrybuilder_first_seen_insertion_order()
    test_keyregistrybuilder_grows_past_initial_capacity()
    test_keyregistrybuilder_into_names_preserves_order()

    # End-to-end INT64
    test_materialize_single_int_col_3_rows()
    test_materialize_negative_int()
    test_materialize_int_with_null()
    test_materialize_int_missing_key_becomes_null()

    # End-to-end mixed
    test_materialize_mixed_3_cols()
    test_materialize_extra_key_skipped()
    test_materialize_empty_input()

    print("test_columnar_materializer — all tests PASSED")
