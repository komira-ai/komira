# =============================================================================
# Wide-default schema inference test suite.
# =============================================================================
#
# Contract:
#   1. Inference of the 5 scalar inferable types (Int64 / Float64 /
#      Bool / NULL / String). LIST / STRUCT / MAP wide-default inference
#      raises with a recovery hint.
#   2. Type promotion (Int64 + Float64 -> Float64; String + null ->
#      String nullable; cross-family -> raises).
#   3. Round-trip: inferred-schema-read of a JSONL fixture matches the
#      original row values bit-exact (with f64 tolerance 1e-9).
#   4. Edge cases: empty input, single record, all-null column,
#      heterogeneous-type error.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Schema

from komira_jsonl.columnar_materializer import materialize_jsonl_to_batch
from komira_jsonl.schema_inference import infer_jsonl_schema


# =============================================================================
# Helpers
# =============================================================================


def _abs_f64(a: Float64, b: Float64) -> Float64:
    var d = a - b
    return d if d >= 0.0 else -d


# =============================================================================
# Test 1 — single scalar type per column (5 inferable scalar types)
# =============================================================================


def test_infer_scalar_types() raises:
    """Each of the 5 scalar inferable types is correctly inferred from
    a single-record JSONL fixture.
    Lattice: Int64 (no .), Float64 (has .), Bool, NULL, String."""
    print("T1: infer 5 scalar types from single record")

    var input = String(
        '{"i":42,"f":3.14,"b":true,"n":null,"s":"hello"}\n'
    )
    var bytes = input.as_bytes()
    var schema = infer_jsonl_schema(bytes)

    assert_equal(schema.num_columns(), 5)

    # First-seen order: i, f, b, n, s.
    assert_equal(String(schema.field_name(0)), String("i"))
    assert_true(schema.field_arrow_type(0) == ArrowType.INT64)
    assert_true(schema.field_nullable(0))

    assert_equal(String(schema.field_name(1)), String("f"))
    assert_true(schema.field_arrow_type(1) == ArrowType.FLOAT64)
    assert_true(schema.field_nullable(1))

    assert_equal(String(schema.field_name(2)), String("b"))
    assert_true(schema.field_arrow_type(2) == ArrowType.BOOL)
    assert_true(schema.field_nullable(2))

    assert_equal(String(schema.field_name(3)), String("n"))
    assert_true(schema.field_arrow_type(3) == ArrowType.NULL)
    assert_true(schema.field_nullable(3))

    assert_equal(String(schema.field_name(4)), String("s"))
    assert_true(schema.field_arrow_type(4) == ArrowType.STRING)
    assert_true(schema.field_nullable(4))

    print("  PASS")


# =============================================================================
# Test 2 — Int64 stays Int64 across records (no narrowing)
# =============================================================================


def test_infer_int64_no_narrowing() raises:
    """Even small integers stay Int64 (no narrowing pass). pandas/PyArrow parity — predictable, no overflow
    surprises."""
    print("T2: integers stay Int64 across records (no narrowing)")

    var input = String(
        '{"a":1}\n'
        + '{"a":2}\n'
        + '{"a":127}\n'
        + '{"a":32767}\n'
    )
    var bytes = input.as_bytes()
    var schema = infer_jsonl_schema(bytes)

    assert_equal(schema.num_columns(), 1)
    assert_true(schema.field_arrow_type(0) == ArrowType.INT64)

    print("  PASS")


# =============================================================================
# Test 3 — Int64 + Float64 promotes to Float64
# =============================================================================


def test_promote_int_to_float() raises:
    """When any record observes a decimal/exponent for a column, the
    column promotes to Float64. Lattice cell merge."""
    print("T3: Int64 + Float64 -> Float64 lattice promotion")

    var input = String(
        '{"x":1}\n'
        + '{"x":2.5}\n'
        + '{"x":3}\n'
    )
    var bytes = input.as_bytes()
    var schema = infer_jsonl_schema(bytes)

    assert_equal(schema.num_columns(), 1)
    assert_true(schema.field_arrow_type(0) == ArrowType.FLOAT64)

    print("  PASS")


# =============================================================================
# Test 4 — Float64 + Int64 (other order) still promotes to Float64
# =============================================================================


def test_promote_float_then_int() raises:
    """Order-independent promotion: Float64 first then Int64 still
    yields Float64."""
    print("T4: Float64 + Int64 -> Float64 (order-independent)")

    var input = String(
        '{"y":1.5}\n'
        + '{"y":2}\n'
    )
    var bytes = input.as_bytes()
    var schema = infer_jsonl_schema(bytes)

    assert_true(schema.field_arrow_type(0) == ArrowType.FLOAT64)

    print("  PASS")


# =============================================================================
# Test 5 — Null promotion: null + T -> T (nullable=True)
# =============================================================================


def test_null_promotion_then_concrete() raises:
    """A column whose first observation is null then sees a concrete
    type promotes to that type (with nullable=True since we have
    observed at least one null)."""
    print("T5: null + Int64 -> Int64 (nullable=True)")

    var input = String(
        '{"a":null}\n'
        + '{"a":7}\n'
    )
    var bytes = input.as_bytes()
    var schema = infer_jsonl_schema(bytes)

    assert_true(schema.field_arrow_type(0) == ArrowType.INT64)
    assert_true(schema.field_nullable(0))

    print("  PASS")


# =============================================================================
# Test 6 — concrete + null lattice symmetry: T + null -> T
# =============================================================================


def test_concrete_then_null() raises:
    """The reverse case: column starts as Int64 then sees a null. The
    lattice cell stays Int64."""
    print("T6: Int64 + null -> Int64 (nullable=True)")

    var input = String(
        '{"a":42}\n'
        + '{"a":null}\n'
    )
    var bytes = input.as_bytes()
    var schema = infer_jsonl_schema(bytes)

    assert_true(schema.field_arrow_type(0) == ArrowType.INT64)
    assert_true(schema.field_nullable(0))

    print("  PASS")


# =============================================================================
# Test 7 — all-null column stays NULL Arrow type
# =============================================================================


def test_all_null_column() raises:
    """A column with no observed non-null values retains ArrowType.NULL
    (lattice bottom). The materializer can materialize NULL columns as
    all-null Arrow arrays."""
    print("T7: all-null column stays NULL")

    var input = String(
        '{"k":null}\n'
        + '{"k":null}\n'
    )
    var bytes = input.as_bytes()
    var schema = infer_jsonl_schema(bytes)

    assert_true(schema.field_arrow_type(0) == ArrowType.NULL)
    assert_true(schema.field_nullable(0))

    print("  PASS")


# =============================================================================
# Test 8 — first-seen-key insertion order is preserved
# =============================================================================


def test_first_seen_key_order() raises:
    """Columns appear in the Schema in the order they were first seen
    across records, NOT alphabetically. New keys in later records get
    appended at the end."""
    print("T8: first-seen-key insertion order preserved")

    var input = String(
        '{"z":1,"a":"hi"}\n'
        + '{"a":"bye","z":2,"m":true}\n'
        + '{"m":false}\n'
    )
    var bytes = input.as_bytes()
    var schema = infer_jsonl_schema(bytes)

    assert_equal(schema.num_columns(), 3)
    assert_equal(String(schema.field_name(0)), String("z"))
    assert_equal(String(schema.field_name(1)), String("a"))
    assert_equal(String(schema.field_name(2)), String("m"))

    assert_true(schema.field_arrow_type(0) == ArrowType.INT64)
    assert_true(schema.field_arrow_type(1) == ArrowType.STRING)
    assert_true(schema.field_arrow_type(2) == ArrowType.BOOL)

    print("  PASS")


# =============================================================================
# Test 9 — heterogeneous types raise (cross-family conflict)
# =============================================================================


def test_heterogeneous_types_raises() raises:
    """A column observing both String and Int64 across records is a
    cross-family conflict; inference raises with a recovery hint."""
    print("T9: cross-family (Int64 + String) raises")

    var input = String(
        '{"col":1}\n'
        + '{"col":"text"}\n'
    )
    var bytes = input.as_bytes()
    var raised = False
    var msg = String("")
    try:
        var _s = infer_jsonl_schema(bytes)
        _ = _s^
    except e:
        raised = True
        msg = String(e)
    assert_true(raised)
    # Message mentions the offending column + types + recovery hint.
    assert_true(msg.find("'col'") >= 0)
    assert_true(msg.find("ctx.read_json_batch") >= 0)

    print("  PASS")


# =============================================================================
# Test 10 — nested values (object) raise with recovery hint
# =============================================================================


def test_nested_object_raises() raises:
    """Nested JSON object values surface a clear
    inference-not-supported error (no recursive Struct inference)."""
    print("T10: nested object value raises")

    var input = String(
        '{"x":{"a":1}}\n'
    )
    var bytes = input.as_bytes()
    var raised = False
    var msg = String("")
    try:
        var _s = infer_jsonl_schema(bytes)
        _ = _s^
    except e:
        raised = True
        msg = String(e)
    assert_true(raised)
    assert_true(msg.find("ctx.read_json_batch") >= 0)

    print("  PASS")


# =============================================================================
# Test 11 — nested values (array) raise with recovery hint
# =============================================================================


def test_nested_array_raises() raises:
    """Same as T10, but for JSON arrays."""
    print("T11: nested array value raises")

    var input = String(
        '{"tags":["a","b"]}\n'
    )
    var bytes = input.as_bytes()
    var raised = False
    try:
        var _s = infer_jsonl_schema(bytes)
        _ = _s^
    except _:
        raised = True
    assert_true(raised)

    print("  PASS")


# =============================================================================
# Test 12 — empty input yields empty Schema
# =============================================================================


def test_empty_input() raises:
    """Empty byte stream yields an empty Schema (0 columns)."""
    print("T12: empty input -> empty Schema")

    var input = String("")
    var bytes = input.as_bytes()
    var schema = infer_jsonl_schema(bytes)
    assert_equal(schema.num_columns(), 0)

    print("  PASS")


# =============================================================================
# Test 13 — single record with all 4 concrete scalar types
# =============================================================================


def test_single_record_concrete_scalars() raises:
    """One record with one Int64 + one Float64 + one Bool + one String
    yields the expected 4-column schema."""
    print("T13: single record, 4 concrete scalar columns")

    var input = String('{"i":1,"f":2.5,"b":false,"s":"x"}\n')
    var bytes = input.as_bytes()
    var schema = infer_jsonl_schema(bytes)
    assert_equal(schema.num_columns(), 4)
    assert_true(schema.field_arrow_type(0) == ArrowType.INT64)
    assert_true(schema.field_arrow_type(1) == ArrowType.FLOAT64)
    assert_true(schema.field_arrow_type(2) == ArrowType.BOOL)
    assert_true(schema.field_arrow_type(3) == ArrowType.STRING)

    print("  PASS")


# =============================================================================
# Test 14 — end-to-end: infer + materialize matches expected row values
# =============================================================================


def test_e2e_infer_materialize() raises:
    """End-to-end exercise: infer schema, materialize, assert values.
    This is the canonical `ctx.read_json(path)` flow minus the file I/O.
    """
    print("T14: end-to-end infer + materialize -> assert row values")

    var input = String(
        '{"id":1,"price":9.99,"name":"alice","active":true}\n'
        + '{"id":2,"price":-3.5,"name":"bob","active":false}\n'
        + '{"id":3,"price":0.01,"name":null,"active":true}\n'
    )
    var bytes = input.as_bytes()
    var schema = infer_jsonl_schema(bytes)

    # Confirm the inferred Schema is sane.
    assert_equal(schema.num_columns(), 4)
    assert_true(schema.field_arrow_type(0) == ArrowType.INT64)
    assert_true(schema.field_arrow_type(1) == ArrowType.FLOAT64)
    assert_true(schema.field_arrow_type(2) == ArrowType.STRING)
    assert_true(schema.field_arrow_type(3) == ArrowType.BOOL)

    var batch = materialize_jsonl_to_batch(bytes, schema^)
    assert_equal(batch._num_rows, 3)
    assert_equal(batch.num_columns(), 4)

    # --- INT64 id ---
    ref id_col = batch.column_at(0)
    var id_arr = id_col.as_primitive[DType.int64]()
    assert_equal(Int(id_arr.get(0)), 1)
    assert_equal(Int(id_arr.get(1)), 2)
    assert_equal(Int(id_arr.get(2)), 3)

    # --- FLOAT64 price ---
    ref price_col = batch.column_at(1)
    var price_arr = price_col.as_primitive[DType.float64]()
    assert_true(_abs_f64(Float64(price_arr.get(0)), 9.99) < 1e-9)
    assert_true(_abs_f64(Float64(price_arr.get(1)), -3.5) < 1e-9)
    assert_true(_abs_f64(Float64(price_arr.get(2)), 0.01) < 1e-9)

    # --- STRING name (row 2 is null) ---
    ref name_col = batch.column_at(2)
    var name_arr = name_col.as_string()
    assert_equal(name_arr.get(0), String("alice"))
    assert_equal(name_arr.get(1), String("bob"))
    assert_true(name_arr.is_null(2))

    print("  PASS")


# =============================================================================
# Test 15 — round-trip: infer + materialize + emit JSONL + re-infer
# =============================================================================


def test_round_trip_infer_emit_reinfer() raises:
    """Round-trip the inferred schema:
       infer(s1) → materialize(b1) → write_jsonl(b1) → infer(b2) ==
       infer(s1) (schema-level) AND b2 row values match b1 row values
       within tolerance.
    Tier 1 primitives (Int64 / Float64-finite / String / Bool)."""
    print("T15: round-trip infer + materialize + re-infer schema-equal")

    var input = String(
        '{"id":10,"score":1.25,"label":"a","ok":true}\n'
        + '{"id":20,"score":-2.5,"label":"b","ok":false}\n'
    )
    var bytes = input.as_bytes()
    var schema1 = infer_jsonl_schema(bytes)
    var batch1 = materialize_jsonl_to_batch(bytes, schema1^)

    # Emit JSONL bytes from batch1.
    from komira_jsonl.json_writer import write_batch_jsonl_direct
    var out_bytes = List[UInt8]()
    write_batch_jsonl_direct(out_bytes, batch1)

    # Re-infer from the emitted JSONL bytes.
    var schema2 = infer_jsonl_schema(out_bytes)

    # Schema-level equality.
    assert_equal(schema2.num_columns(), 4)
    assert_equal(String(schema2.field_name(0)), String("id"))
    assert_true(schema2.field_arrow_type(0) == ArrowType.INT64)
    assert_equal(String(schema2.field_name(1)), String("score"))
    assert_true(schema2.field_arrow_type(1) == ArrowType.FLOAT64)
    assert_equal(String(schema2.field_name(2)), String("label"))
    assert_true(schema2.field_arrow_type(2) == ArrowType.STRING)
    assert_equal(String(schema2.field_name(3)), String("ok"))
    assert_true(schema2.field_arrow_type(3) == ArrowType.BOOL)

    # Re-materialize from the emitted bytes; row values should match.
    var batch2 = materialize_jsonl_to_batch(out_bytes, schema2^)
    assert_equal(batch2._num_rows, 2)

    var id1 = batch1.column_at(0).as_primitive[DType.int64]()
    var id2 = batch2.column_at(0).as_primitive[DType.int64]()
    assert_equal(Int(id1.get(0)), Int(id2.get(0)))
    assert_equal(Int(id1.get(1)), Int(id2.get(1)))

    var sc1 = batch1.column_at(1).as_primitive[DType.float64]()
    var sc2 = batch2.column_at(1).as_primitive[DType.float64]()
    assert_true(_abs_f64(Float64(sc1.get(0)), Float64(sc2.get(0))) < 1e-9)
    assert_true(_abs_f64(Float64(sc1.get(1)), Float64(sc2.get(1))) < 1e-9)

    var l1 = batch1.column_at(2).as_string()
    var l2 = batch2.column_at(2).as_string()
    assert_equal(l1.get(0), l2.get(0))
    assert_equal(l1.get(1), l2.get(1))

    print("  PASS")


# =============================================================================
# Test 16 — Bool + Int64 cross-family raises
# =============================================================================


def test_bool_int_cross_family_raises() raises:
    """Bool and Int64 are different families per the lattice — inference raises
    on the conflict. Recovery hint points at ctx.read_json_batch."""
    print("T16: Bool + Int64 cross-family raises")

    var input = String(
        '{"flag":true}\n'
        + '{"flag":1}\n'
    )
    var bytes = input.as_bytes()
    var raised = False
    var msg = String("")
    try:
        var _s = infer_jsonl_schema(bytes)
        _ = _s^
    except e:
        raised = True
        msg = String(e)
    assert_true(raised)
    assert_true(msg.find("'flag'") >= 0)

    print("  PASS")


# =============================================================================
# Driver
# =============================================================================


def main() raises:
    print("test_schema_inference — wide-default inference suite")
    test_infer_scalar_types()
    test_infer_int64_no_narrowing()
    test_promote_int_to_float()
    test_promote_float_then_int()
    test_null_promotion_then_concrete()
    test_concrete_then_null()
    test_all_null_column()
    test_first_seen_key_order()
    test_heterogeneous_types_raises()
    test_nested_object_raises()
    test_nested_array_raises()
    test_empty_input()
    test_single_record_concrete_scalars()
    test_e2e_infer_materialize()
    test_round_trip_infer_emit_reinfer()
    test_bool_int_cross_family_raises()
    print("\nALL 16 TESTS PASSED")
