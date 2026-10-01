# =============================================================================
# test_avro_arrow_logical_round_trip.mojo — arrow.* custom-logical-type
#   round-trip: the 16 lossy Arrow types survive
#   Arrow -> Avro schema (from_arrow) -> Arrow type (to_arrow w/ override).
# =============================================================================
#
# Acceptance coverage:
#   - 17 type-lattice round-trips (one per annotation the writer emits):
#       float16, int8, int16, uint8, uint16, uint32, uint64, date64,
#       timestamp_s, timestamp_ns, time32_s, time64_ns,
#       duration_seconds, duration_millis, duration_micros, duration_nanos,
#       union_sparse (the 17th — union-backed, custom-attribute-slot carrier).
#   - codec-compatibility-guard mismatch -> silent fallback to underlying
#     primitive.
#   - unknown arrow.* annotation -> underlying primitive (forwards-compat).
#   - 3 boundary tests: physical-type-mismatch boundaries (fixed-size wrong,
#     int-vs-long swap, fixed-backed served over a primitive).
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_avro import (
    AvroSchema,
    avro_node_to_arrow_with_override,
    from_arrow_avro_type_json,
    arrow_logical_annotation,
    is_lossy_arrow_type,
)
from komira_core.arrow.arrow_types import ArrowType


def _round_trip(arrow_type: ArrowType) raises -> ArrowType:
    """Arrow type -> Avro schema JSON (from_arrow) -> parse -> Arrow type
    (to_arrow with override). The full type-lattice round-trip."""
    var json = from_arrow_avro_type_json(arrow_type, String("rt_fixed"))
    var schema = AvroSchema.parse(json)
    return avro_node_to_arrow_with_override(schema, schema.root())


def _assert_round_trip(arrow_type: ArrowType) raises:
    assert_true(
        is_lossy_arrow_type(arrow_type),
        String("expected lossy Arrow type to require arrow.* round-trip"),
    )
    var got = _round_trip(arrow_type)
    assert_true(
        got == arrow_type,
        String("arrow.* round-trip did not preserve the Arrow type"),
    )


# =============================================================================
# 16 round-trip tests (one per type).
# =============================================================================


def test_arrow_round_trip_float16() raises:
    _assert_round_trip(ArrowType.FLOAT16)


def test_arrow_round_trip_int8() raises:
    _assert_round_trip(ArrowType.INT8)


def test_arrow_round_trip_int16() raises:
    _assert_round_trip(ArrowType.INT16)


def test_arrow_round_trip_uint8() raises:
    _assert_round_trip(ArrowType.UINT8)


def test_arrow_round_trip_uint16() raises:
    _assert_round_trip(ArrowType.UINT16)


def test_arrow_round_trip_uint32() raises:
    _assert_round_trip(ArrowType.UINT32)


def test_arrow_round_trip_uint64() raises:
    _assert_round_trip(ArrowType.UINT64)


def test_arrow_round_trip_date64() raises:
    _assert_round_trip(ArrowType.DATE64)


def test_arrow_round_trip_timestamp_s() raises:
    _assert_round_trip(ArrowType.TIMESTAMP_S)


def test_arrow_round_trip_timestamp_ns() raises:
    _assert_round_trip(ArrowType.TIMESTAMP_NS)


def test_arrow_round_trip_time32_s() raises:
    _assert_round_trip(ArrowType.TIME32_S)


def test_arrow_round_trip_time64_ns() raises:
    _assert_round_trip(ArrowType.TIME64_NS)


def test_arrow_round_trip_duration_seconds() raises:
    _assert_round_trip(ArrowType.DURATION_S)


def test_arrow_round_trip_duration_millis() raises:
    _assert_round_trip(ArrowType.DURATION_MS)


def test_arrow_round_trip_duration_micros() raises:
    _assert_round_trip(ArrowType.DURATION_US)


def test_arrow_round_trip_duration_nanos() raises:
    _assert_round_trip(ArrowType.DURATION_NS)


# =============================================================================
# 17th annotation: union-backed
# arrow.union-sparse. Structurally different from the 16 primitive/fixed
# siblings — it rides on an Avro `union` via the object-form custom-attribute
# slot, and disambiguates a SPARSE union from the standard reader fallback
# (a bare non-null-collapsing union maps to UNION_DENSE).
# =============================================================================


def test_arrow_round_trip_union_sparse() raises:
    """The 17th annotation round-trips Arrow UNION_SPARSE through Avro:
    Arrow -> Avro object-form union (arrow.union-sparse) -> Arrow UNION_SPARSE.
    """
    _assert_round_trip(ArrowType.UNION_SPARSE)


def test_union_sparse_is_lossy() raises:
    """arrow.union-sparse is a recognized lossy Arrow type (17th annotation)."""
    assert_true(
        is_lossy_arrow_type(ArrowType.UNION_SPARSE),
        String("UNION_SPARSE must be a lossy Arrow type (17th annotation)"),
    )
    assert_equal(
        arrow_logical_annotation(ArrowType.UNION_SPARSE),
        String("arrow.union-sparse"),
    )


def test_union_sparse_emits_union_backing() raises:
    """arrow.union-sparse is union-backed: the emitted JSON is the object-form
    union carrier ({"type":"union",...,"logicalType":"arrow.union-sparse"})."""
    var json = from_arrow_avro_type_json(
        ArrowType.UNION_SPARSE, String("us")
    )
    assert_true(
        json.find('"type":"union"') >= 0,
        String("arrow.union-sparse must be union-backed (object-form union)"),
    )
    assert_true(
        json.find('"logicalType":"arrow.union-sparse"') >= 0,
        String("arrow.union-sparse annotation missing from emitted JSON"),
    )


def test_union_sparse_distinct_from_union_dense() raises:
    """Without the arrow.union-sparse annotation, a bare (non-null-collapsing)
    union maps to UNION_DENSE. The annotation is what selects UNION_SPARSE —
    the two layouts are disambiguated only by the custom-attribute slot."""
    # Bare array-form union with 2 non-null branches -> standard fallback.
    var dense_schema = AvroSchema.parse(String('["int","string"]'))
    var dense_got = avro_node_to_arrow_with_override(
        dense_schema, dense_schema.root()
    )
    assert_true(
        dense_got == ArrowType.UNION_DENSE,
        String("bare 2-non-null-branch union must map to UNION_DENSE"),
    )
    # Object-form union WITH the annotation -> UNION_SPARSE.
    var sparse_got = _round_trip(ArrowType.UNION_SPARSE)
    assert_true(
        sparse_got == ArrowType.UNION_SPARSE,
        String("annotated object-form union must map to UNION_SPARSE"),
    )


# =============================================================================
# Backing-type assertions: emitted JSON carries the REQUIRED
# underlying physical type. These guard the backing types (uint64 must
# be fixed(8), NOT long; float16 must be fixed(2)).
# =============================================================================


def test_uint64_emits_fixed_8_backing() raises:
    """F1: arrow.uint64 MUST be backed by fixed(8), not long."""
    var json = from_arrow_avro_type_json(ArrowType.UINT64, String("u64"))
    assert_true(
        json.find('"type":"fixed"') >= 0,
        String("arrow.uint64 must be fixed-backed"),
    )
    assert_true(
        json.find('"size":8') >= 0, String("arrow.uint64 fixed size must be 8")
    )
    assert_true(
        json.find('"logicalType":"arrow.uint64"') >= 0,
        String("arrow.uint64 annotation missing"),
    )


def test_float16_emits_fixed_2_backing() raises:
    """arrow.float16 MUST be backed by fixed(2)."""
    var json = from_arrow_avro_type_json(ArrowType.FLOAT16, String("f16"))
    assert_true(
        json.find('"type":"fixed"') >= 0,
        String("arrow.float16 must be fixed-backed"),
    )
    assert_true(
        json.find('"size":2') >= 0,
        String("arrow.float16 fixed size must be 2"),
    )


def test_uint32_emits_long_backing() raises:
    """arrow.uint32 is long-backed (NOT int)."""
    var json = from_arrow_avro_type_json(ArrowType.UINT32, String(""))
    assert_true(
        json.find('"type":"long"') >= 0,
        String("arrow.uint32 must be long-backed"),
    )
    assert_true(
        json.find('"logicalType":"arrow.uint32"') >= 0,
        String("arrow.uint32 annotation missing"),
    )


def test_int8_emits_int_backing() raises:
    """arrow.int8 is int-backed."""
    var json = from_arrow_avro_type_json(ArrowType.INT8, String(""))
    assert_true(
        json.find('"type":"int"') >= 0,
        String("arrow.int8 must be int-backed"),
    )


# =============================================================================
# Fallback tests.
# =============================================================================


def test_arrow_codec_compatibility_guard_mismatch_fallback() raises:
    """Codec-compatibility-guard mismatch -> silent fallback to underlying
    primitive. An arrow.uint64 annotation served over a `long` (NOT the
    required fixed(8)) must NOT yield UInt64 — the guard fails and we fall
    back to the standard Avro `long` -> Int64 mapping."""
    var json = String('{"type":"long","logicalType":"arrow.uint64"}')
    var schema = AvroSchema.parse(json)
    var got = avro_node_to_arrow_with_override(schema, schema.root())
    # Guard fails (long != fixed(8)) -> standard `long` -> Int64.
    assert_true(
        got == ArrowType.INT64,
        String(
            "guard mismatch must fall back to the underlying primitive (Int64)"
        ),
    )
    assert_false(
        got == ArrowType.UINT64,
        String("guard mismatch must NOT honor the arrow.uint64 annotation"),
    )


def test_unknown_arrow_annotation_fallback() raises:
    """Unknown arrow.* annotation -> underlying primitive (forwards-compat).
    An annotation this package does not recognize (a future arrow.* type) must
    fall back to the underlying physical type's standard Arrow mapping."""
    var json = String(
        '{"type":"long","logicalType":"arrow.future-type-v99"}'
    )
    var schema = AvroSchema.parse(json)
    var got = avro_node_to_arrow_with_override(schema, schema.root())
    assert_true(
        got == ArrowType.INT64,
        String(
            "unknown arrow.* annotation must fall back to underlying primitive"
        ),
    )


# =============================================================================
# 3 boundary tests: physical-type-mismatch boundaries.
# =============================================================================


def test_boundary_fixed_size_mismatch_fallback() raises:
    """Boundary: arrow.uint64 served over fixed(4) (wrong size) -> guard fails
    -> fall back to the standard fixed -> Binary mapping (NOT UInt64)."""
    var json = String(
        '{"type":"fixed","name":"wrong","size":4,"logicalType":"arrow.uint64"}'
    )
    var schema = AvroSchema.parse(json)
    var got = avro_node_to_arrow_with_override(schema, schema.root())
    assert_false(
        got == ArrowType.UINT64,
        String("fixed(4) must NOT satisfy the arrow.uint64 fixed(8) guard"),
    )
    assert_true(
        got == ArrowType.BINARY,
        String("fixed of wrong size falls back to standard fixed -> Binary"),
    )


def test_boundary_int_backed_served_over_long_fallback() raises:
    """Boundary: arrow.int8 (REQUIRES int) served over `long` -> guard fails
    -> fall back to the standard `long` -> Int64 mapping (NOT Int8)."""
    var json = String('{"type":"long","logicalType":"arrow.int8"}')
    var schema = AvroSchema.parse(json)
    var got = avro_node_to_arrow_with_override(schema, schema.root())
    assert_false(
        got == ArrowType.INT8,
        String("int-backed arrow.int8 must NOT honor a long underlying"),
    )
    assert_true(
        got == ArrowType.INT64,
        String("guard mismatch -> standard long -> Int64"),
    )


def test_boundary_float16_served_over_int_fallback() raises:
    """Boundary: arrow.float16 (REQUIRES fixed(2)) served over `int` -> guard
    fails -> fall back to the standard `int` -> Int32 mapping (NOT Float16)."""
    var json = String('{"type":"int","logicalType":"arrow.float16"}')
    var schema = AvroSchema.parse(json)
    var got = avro_node_to_arrow_with_override(schema, schema.root())
    assert_false(
        got == ArrowType.FLOAT16,
        String("fixed(2)-backed arrow.float16 must NOT honor an int underlying"),
    )
    assert_true(
        got == ArrowType.INT32,
        String("guard mismatch -> standard int -> Int32"),
    )


# =============================================================================
# Sanity: a recognized annotation over the CORRECT physical type honors it
# (the positive of the guard, complementing the negative fallback tests).
# =============================================================================


def test_annotation_helper_consistency() raises:
    """arrow_logical_annotation must return the annotation that round-trips."""
    assert_equal(
        arrow_logical_annotation(ArrowType.UINT64), String("arrow.uint64")
    )
    assert_equal(
        arrow_logical_annotation(ArrowType.FLOAT16), String("arrow.float16")
    )
    # A non-lossy Arrow type yields the empty string.
    assert_equal(arrow_logical_annotation(ArrowType.INT64), String(""))
    assert_false(is_lossy_arrow_type(ArrowType.INT64))


def main() raises:
    test_arrow_round_trip_float16()
    test_arrow_round_trip_int8()
    test_arrow_round_trip_int16()
    test_arrow_round_trip_uint8()
    test_arrow_round_trip_uint16()
    test_arrow_round_trip_uint32()
    test_arrow_round_trip_uint64()
    test_arrow_round_trip_date64()
    test_arrow_round_trip_timestamp_s()
    test_arrow_round_trip_timestamp_ns()
    test_arrow_round_trip_time32_s()
    test_arrow_round_trip_time64_ns()
    test_arrow_round_trip_duration_seconds()
    test_arrow_round_trip_duration_millis()
    test_arrow_round_trip_duration_micros()
    test_arrow_round_trip_duration_nanos()
    test_arrow_round_trip_union_sparse()
    test_union_sparse_is_lossy()
    test_union_sparse_emits_union_backing()
    test_union_sparse_distinct_from_union_dense()
    test_uint64_emits_fixed_8_backing()
    test_float16_emits_fixed_2_backing()
    test_uint32_emits_long_backing()
    test_int8_emits_int_backing()
    test_arrow_codec_compatibility_guard_mismatch_fallback()
    test_unknown_arrow_annotation_fallback()
    test_boundary_fixed_size_mismatch_fallback()
    test_boundary_int_backed_served_over_long_fallback()
    test_boundary_float16_served_over_int_fallback()
    test_annotation_helper_consistency()
    print("test_avro_arrow_logical_round_trip: ALL PASS")
