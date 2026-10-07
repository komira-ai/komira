# =============================================================================
# test_firestore_value.mojo — the Firestore value-model round-trip + RowCell-map
#   FALSIFIER.
# =============================================================================
#
# THE FALSIFIERS over the value model (pure convert/map — ZERO network). The
# JSON form is the generated `Value`'s (komira_gcp_firestore_v1), read and
# written by komira_proto_codec; FsValue converts to and from it.
#
#   (1) EVERY Firestore value type round-trips through the JSON value form + maps
#       onto the RIGHT RowCell arm: stringValue/integerValue/doubleValue/
#       booleanValue/nullValue/timestampValue/bytesValue/referenceValue/
#       geoPointValue/arrayValue/mapValue — INCLUDING a NESTED array/map. FALSIFIER:
#       a mis-tagged parse or a dropped nested field fails the round-trip / the
#       RowCell arm assertion.
#   (2) THE FF-1 GUARD: a >Int64 integerValue must map to a STABLE, NON-COLLIDING
#       STRING cell carrying the canonical decimal — NOT a silently-wrapped LONG.
#       FALSIFIER: pre-guard, a 30-digit integerValue wraps to an in-range LONG,
#       so the cell is CELL_T_LONG with a corrupted value AND two distinct large
#       values can collide.
#   (3) A nested array / map / geoPoint maps to a canonical-JSON STRING cell (the
#       Iceberg primitive subset has no nested arm). FALSIFIER: a nested value that
#       tried to map to a non-string cell would drop structure.
#
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

# The cell model, from the zero-dep leaf. Was
# `komira_iceberg.iceberg_row_value` / `.iceberg_types`; same symbols, new home
# — `CELL_T_X` is what `ICE_T_X` was.
from komira_rowcell import (
    RowCell,
    CELL_T_STRING,
    CELL_T_LONG,
    CELL_T_DOUBLE,
    CELL_T_BOOLEAN,
)

from komira_gcp_firestore.firestore_value import (
    FsValue,
    FS_T_STRING,
    FS_T_INTEGER,
    FS_T_DOUBLE,
    FS_T_BOOL,
    FS_T_NULL,
    FS_T_TIMESTAMP,
    FS_T_BYTES,
    FS_T_REFERENCE,
    FS_T_GEOPOINT,
    FS_T_ARRAY,
    FS_T_MAP,
    parse_fs_fields,
    serialize_fs_value,
    fs_value_to_row_cell,
    fs_fields_to_row_cells,
    fs_value_to_v1,
    fs_value_from_v1,
    VALUE_NULL,
    VALUE_BOOLEAN,
    VALUE_INTEGER,
    VALUE_DOUBLE,
    VALUE_TIMESTAMP,
    VALUE_STRING,
    VALUE_BYTES,
    VALUE_REFERENCE,
    VALUE_GEO_POINT,
    VALUE_ARRAY,
    VALUE_MAP,
)
from komira_gcp_firestore_v1.document import Value as V1Value
from komira_proto_codec.codec import decode_json


def _parse_value(json: String) raises -> FsValue:
    """Read a single Firestore value from its JSON `{"<typeKey>": val}` form,
    as a one-field `fields` object."""
    return parse_fs_fields(String('{"v":') + json + String("}")).map_get(String("v"))


def _roundtrip(json: String) raises -> String:
    """Parse a Firestore value JSON then re-serialize it (the round-trip)."""
    return serialize_fs_value(_parse_value(json))


# =============================================================================
# (1) each scalar value type round-trips + maps to the right RowCell arm.
# =============================================================================
def test_string_value_roundtrip_and_cell() raises:
    var j = String('{"stringValue":"hello world"}')
    var v = _parse_value(j)
    assert_equal(v.type_tag, FS_T_STRING)
    assert_equal(v.as_string(), String("hello world"))
    assert_equal(_roundtrip(j), j)
    var c = fs_value_to_row_cell(v)
    assert_equal(c.type_tag, CELL_T_STRING)
    assert_equal(c.as_string(), String("hello world"))


def test_integer_value_roundtrip_and_cell() raises:
    var j = String('{"integerValue":"42"}')
    var v = _parse_value(j)
    assert_equal(v.type_tag, FS_T_INTEGER)
    assert_equal(v.as_string(), String("42"))
    assert_equal(_roundtrip(j), j)
    var c = fs_value_to_row_cell(v)
    assert_equal(c.type_tag, CELL_T_LONG)
    assert_equal(c.as_long(), Int64(42))
    # A negative integer.
    var vn = _parse_value(String('{"integerValue":"-7"}'))
    var cn = fs_value_to_row_cell(vn)
    assert_equal(cn.type_tag, CELL_T_LONG)
    assert_equal(cn.as_long(), Int64(-7))


def test_double_value_roundtrip_and_cell() raises:
    var v = _parse_value(String('{"doubleValue":3.5}'))
    assert_equal(v.type_tag, FS_T_DOUBLE)
    var c = fs_value_to_row_cell(v)
    assert_equal(c.type_tag, CELL_T_DOUBLE)
    assert_true(c.as_double() > 3.4 and c.as_double() < 3.6)


def test_boolean_value_roundtrip_and_cell() raises:
    var jt = String('{"booleanValue":true}')
    var vt = _parse_value(jt)
    assert_equal(vt.type_tag, FS_T_BOOL)
    assert_equal(_roundtrip(jt), jt)
    var ct = fs_value_to_row_cell(vt)
    assert_equal(ct.type_tag, CELL_T_BOOLEAN)
    assert_true(ct.as_long() == Int64(1))
    var vf = _parse_value(String('{"booleanValue":false}'))
    var cf = fs_value_to_row_cell(vf)
    assert_equal(cf.type_tag, CELL_T_BOOLEAN)
    assert_true(cf.as_long() == Int64(0))


def test_null_value_roundtrip_and_cell() raises:
    var j = String('{"nullValue":null}')
    var v = _parse_value(j)
    assert_equal(v.type_tag, FS_T_NULL)
    assert_true(v.is_null())
    assert_equal(_roundtrip(j), j)
    var c = fs_value_to_row_cell(v)
    assert_true(c.is_null())
    # A null cell never value-equals a non-null cell.
    var non_null = fs_value_to_row_cell(_parse_value(String('{"stringValue":""}')))
    assert_false(c.equals(non_null))


def test_timestamp_value_roundtrip_and_cell() raises:
    var j = String('{"timestampValue":"2026-10-01T00:00:00Z"}')
    var v = _parse_value(j)
    assert_equal(v.type_tag, FS_T_TIMESTAMP)
    assert_equal(_roundtrip(j), j)
    var c = fs_value_to_row_cell(v)
    assert_equal(c.type_tag, CELL_T_STRING)
    assert_equal(c.as_string(), String("2026-10-01T00:00:00Z"))


def test_bytes_value_roundtrip_and_cell() raises:
    var j = String('{"bytesValue":"aGVsbG8="}')
    var v = _parse_value(j)
    assert_equal(v.type_tag, FS_T_BYTES)
    assert_equal(_roundtrip(j), j)
    var c = fs_value_to_row_cell(v)
    assert_equal(c.type_tag, CELL_T_STRING)
    assert_equal(c.as_string(), String("aGVsbG8="))


def test_reference_value_roundtrip_and_cell() raises:
    var path = String("projects/p/databases/(default)/documents/users/alice")
    var j = String('{"referenceValue":"') + path + String('"}')
    var v = _parse_value(j)
    assert_equal(v.type_tag, FS_T_REFERENCE)
    assert_equal(_roundtrip(j), j)
    var c = fs_value_to_row_cell(v)
    assert_equal(c.type_tag, CELL_T_STRING)
    assert_equal(c.as_string(), path)


def test_geopoint_value_roundtrip_and_cell() raises:
    var v = _parse_value(
        String('{"geoPointValue":{"latitude":37.42,"longitude":-122.08}}')
    )
    assert_equal(v.type_tag, FS_T_GEOPOINT)
    assert_true(v.num_a > 37.41 and v.num_a < 37.43)
    assert_true(v.num_b > -122.09 and v.num_b < -122.07)
    # A geoPoint has no primitive Iceberg arm -> a canonical-JSON STRING cell.
    var c = fs_value_to_row_cell(v)
    assert_equal(c.type_tag, CELL_T_STRING)
    assert_true(_contains(c.as_string(), String("geoPointValue")))
    assert_true(_contains(c.as_string(), String("latitude")))


# =============================================================================
# (2) NESTED array + map round-trip; nested -> canonical-JSON STRING cell.
# =============================================================================
def test_array_value_nested_roundtrip_and_cell() raises:
    # arrayValue of [string, integer, nested map].
    var j = String(
        '{"arrayValue":{"values":['
        + '{"stringValue":"a"},'
        + '{"integerValue":"1"},'
        + '{"mapValue":{"fields":{"k":{"booleanValue":true}}}}'
        + "]}}"
    )
    var v = _parse_value(j)
    assert_equal(v.type_tag, FS_T_ARRAY)
    assert_equal(len(v.list_items), 3)
    assert_equal(v.list_items[0].type_tag, FS_T_STRING)
    assert_equal(v.list_items[1].type_tag, FS_T_INTEGER)
    assert_equal(v.list_items[2].type_tag, FS_T_MAP)
    # Round-trips byte-for-byte (insertion order preserved).
    assert_equal(_roundtrip(j), j)
    # Maps to a canonical-JSON STRING cell carrying the full nested structure.
    var c = fs_value_to_row_cell(v)
    assert_equal(c.type_tag, CELL_T_STRING)
    assert_true(_contains(c.as_string(), String("arrayValue")))
    assert_true(_contains(c.as_string(), String("booleanValue")))


def test_map_value_nested_roundtrip_and_cell() raises:
    # A mapValue with a nested array inside.
    var j = String(
        '{"mapValue":{"fields":{'
        + '"name":{"stringValue":"bob"},'
        + '"tags":{"arrayValue":{"values":[{"stringValue":"x"},{"stringValue":"y"}]}}'
        + "}}}"
    )
    var v = _parse_value(j)
    assert_equal(v.type_tag, FS_T_MAP)
    assert_true(v.map_has(String("name")))
    assert_true(v.map_has(String("tags")))
    assert_equal(v.map_get(String("name")).as_string(), String("bob"))
    assert_equal(v.map_get(String("tags")).type_tag, FS_T_ARRAY)
    assert_equal(len(v.map_get(String("tags")).list_items), 2)
    assert_equal(_roundtrip(j), j)
    var c = fs_value_to_row_cell(v)
    assert_equal(c.type_tag, CELL_T_STRING)
    assert_true(_contains(c.as_string(), String("mapValue")))
    assert_true(_contains(c.as_string(), String("bob")))


# =============================================================================
# (3) THE FF-1 GUARD — a >Int64 integerValue maps to a STABLE STRING cell, NOT a
#     silently-wrapped LONG. RED if it wraps.
# =============================================================================
def test_over_int64_integer_value_no_wrap() raises:
    """A 30-digit integerValue maps to a STRING cell carrying the exact canonical
    decimal string (NOT a wrapped LONG). The same value maps to the same cell.

    FAILS ON CURRENT CODE (if the guard is absent): a naive v*10+d accumulation
    wraps a 30-digit value to an in-range negative LONG — the digits are LOST and
    the cell is CELL_T_LONG."""
    var big = String("123456789012345678901234567890")  # 30 digits
    var v = FsValue.integer(big.copy())
    var c = fs_value_to_row_cell(v)
    # It must NOT be a LONG cell holding a wrapped value — the value is preserved.
    assert_equal(c.type_tag, CELL_T_STRING)
    assert_equal(c.as_string(), big)
    # Stability: the same logical value maps to the same cell every time.
    var c2 = fs_value_to_row_cell(v)
    assert_true(c.equals(c2), msg="same large integerValue must map to an equal cell")


def test_over_int64_integers_never_collide() raises:
    """Two distinct >Int64 integerValues produce DISTINCT, non-equal cells (a
    wrap would collide two distinct keys -> masks the wrong Iceberg row)."""
    var a = fs_value_to_row_cell(
        FsValue.integer(String("123456789012345678901234567890"))
    )
    var b = fs_value_to_row_cell(
        FsValue.integer(String("123456789012345678901234567891"))
    )
    assert_false(a.equals(b), msg="two distinct over-Int64 integers MUST NOT collide")


def test_int64_boundary_max_and_overflow() raises:
    """Int64 MAX (19 digits) fits -> LONG cell; MAX+1 overflows -> STRING cell."""
    var at_max = fs_value_to_row_cell(
        _parse_value(String('{"integerValue":"9223372036854775807"}'))
    )
    assert_equal(at_max.type_tag, CELL_T_LONG)
    assert_equal(at_max.as_long(), Int64(9223372036854775807))
    var over = fs_value_to_row_cell(
        FsValue.integer(String("9223372036854775808"))  # MAX+1
    )
    assert_equal(over.type_tag, CELL_T_STRING)
    assert_equal(over.as_string(), String("9223372036854775808"))
    # Int64 MIN fits; MIN-1 overflows to a STRING cell.
    var at_min = fs_value_to_row_cell(
        _parse_value(String('{"integerValue":"-9223372036854775808"}'))
    )
    assert_equal(at_min.type_tag, CELL_T_LONG)
    assert_equal(at_min.as_long(), Int64(-9223372036854775808))
    var under = fs_value_to_row_cell(
        FsValue.integer(String("-9223372036854775809"))
    )
    assert_equal(under.type_tag, CELL_T_STRING)
    assert_equal(under.as_string(), String("-9223372036854775809"))


# =============================================================================
# (4) a full document `fields` object -> positional RowCells in column order,
#     null-filling an absent column.
# =============================================================================
def test_document_fields_to_row_cells() raises:
    """A document `fields` map projects onto a positional row of RowCells in the
    caller's column order; an absent column null-fills."""
    var fields_json = String(
        "{"
        + '"id":{"integerValue":"7"},'
        + '"name":{"stringValue":"carol"}'
        + "}"
    )
    var fields = parse_fs_fields(fields_json)
    var cols = List[String]()
    cols.append(String("id"))
    cols.append(String("name"))
    cols.append(String("score"))  # absent from the doc -> null-fill
    var cells = fs_fields_to_row_cells(fields, cols)
    assert_equal(len(cells), 3)
    assert_equal(cells[0].type_tag, CELL_T_LONG)
    assert_equal(cells[0].as_long(), Int64(7))
    assert_equal(cells[1].type_tag, CELL_T_STRING)
    assert_equal(cells[1].as_string(), String("carol"))
    assert_true(cells[2].is_null())
    # The `fields` object re-serializes as a map value (order preserved).
    assert_equal(
        serialize_fs_value(fields),
        String('{"mapValue":{"fields":') + fields_json + String("}}"),
    )


# =============================================================================
# (5) the generated Value, both ways: an integer beyond Int64 is never sent
#     wrapped and never read wrapped; a pipeline-only arm has no FsValue.
# =============================================================================
def test_over_int64_integer_is_refused_on_the_wire() raises:
    var refused = False
    try:
        _ = fs_value_to_v1(FsValue.integer(String("9223372036854775808")))
    except e:
        refused = True
        assert_true(_contains(String(e), String("not an Int64")))
        # The value itself is not quoted.
        assert_false(_contains(String(e), String("9223372036854775808")))
    assert_true(refused, msg="an over-Int64 integerValue must not be sent wrapped")
    var read_refused = False
    try:
        _ = _parse_value(String('{"integerValue":"9223372036854775808"}'))
    except:
        read_refused = True
    assert_true(read_refused, msg="an over-Int64 integerValue must not be read wrapped")


def test_every_arm_converts_both_ways() raises:
    var values = List[String]()
    values.append(String('{"nullValue":null}'))
    values.append(String('{"booleanValue":false}'))
    values.append(String('{"integerValue":"-9223372036854775808"}'))
    values.append(String('{"doubleValue":-0.5}'))
    values.append(String('{"timestampValue":"2026-10-01T00:00:00.123456Z"}'))
    values.append(String('{"stringValue":"x"}'))
    values.append(String('{"bytesValue":"AP8="}'))
    values.append(String('{"referenceValue":"projects/p/databases/d/documents/c/x"}'))
    values.append(String('{"geoPointValue":{"latitude":1.5,"longitude":-2.25}}'))
    values.append(String('{"arrayValue":{"values":[{"nullValue":null}]}}'))
    values.append(String('{"mapValue":{"fields":{"k":{"stringValue":"v"}}}}'))
    for i in range(len(values)):
        var v = _parse_value(values[i])
        assert_equal(serialize_fs_value(v), values[i])
        assert_equal(serialize_fs_value(fs_value_from_v1(fs_value_to_v1(v))), values[i])


def test_a_pipeline_arm_and_an_empty_value_are_refused() raises:
    var field_ref = decode_json[V1Value](String('{"fieldReferenceValue":"a.b"}'))
    var refused = False
    try:
        _ = fs_value_from_v1(field_ref)
    except e:
        refused = True
        assert_true(_contains(String(e), String("pipeline")))
    assert_true(refused)
    var empty = decode_json[V1Value](String("{}"))
    refused = False
    try:
        _ = fs_value_from_v1(empty)
    except e:
        refused = True
        assert_true(_contains(String(e), String("no arm")))
    assert_true(refused)


# ---- a tiny substring helper (no general search dep) ----
def _contains(haystack: String, needle: String) -> Bool:
    var hb = haystack.as_bytes()
    var nb = needle.as_bytes()
    if len(nb) == 0 or len(nb) > len(hb):
        return len(nb) == 0
    for s in range(0, len(hb) - len(nb) + 1):
        var ok = True
        for j in range(len(nb)):
            if hb[s + j] != nb[j]:
                ok = False
                break
        if ok:
            return True
    return False


def test_value_arm_constants_are_the_generated_decoders() raises:
    """Each `VALUE_*` is the generated decoder's arm number for that JSON
    key, so a reordering proto bump fails here."""
    var keys = List[String]()
    var arms = List[Int]()
    keys.append(String('{"nullValue":null}'))
    arms.append(VALUE_NULL)
    keys.append(String('{"booleanValue":true}'))
    arms.append(VALUE_BOOLEAN)
    keys.append(String('{"integerValue":"1"}'))
    arms.append(VALUE_INTEGER)
    keys.append(String('{"doubleValue":1.5}'))
    arms.append(VALUE_DOUBLE)
    keys.append(String('{"timestampValue":"2026-10-01T00:00:00Z"}'))
    arms.append(VALUE_TIMESTAMP)
    keys.append(String('{"stringValue":"s"}'))
    arms.append(VALUE_STRING)
    keys.append(String('{"bytesValue":"AA=="}'))
    arms.append(VALUE_BYTES)
    keys.append(String('{"referenceValue":"r"}'))
    arms.append(VALUE_REFERENCE)
    keys.append(String('{"geoPointValue":{"latitude":1,"longitude":2}}'))
    arms.append(VALUE_GEO_POINT)
    keys.append(String('{"arrayValue":{}}'))
    arms.append(VALUE_ARRAY)
    keys.append(String('{"mapValue":{}}'))
    arms.append(VALUE_MAP)
    for i in range(len(keys)):
        assert_equal(decode_json[V1Value](keys[i])._oneof0_case, arms[i], keys[i])


def main() raises:
    test_string_value_roundtrip_and_cell()
    test_integer_value_roundtrip_and_cell()
    test_double_value_roundtrip_and_cell()
    test_boolean_value_roundtrip_and_cell()
    test_null_value_roundtrip_and_cell()
    test_timestamp_value_roundtrip_and_cell()
    test_bytes_value_roundtrip_and_cell()
    test_reference_value_roundtrip_and_cell()
    test_geopoint_value_roundtrip_and_cell()
    test_array_value_nested_roundtrip_and_cell()
    test_map_value_nested_roundtrip_and_cell()
    test_over_int64_integer_value_no_wrap()
    test_over_int64_integers_never_collide()
    test_int64_boundary_max_and_overflow()
    test_document_fields_to_row_cells()
    test_over_int64_integer_is_refused_on_the_wire()
    test_every_arm_converts_both_ways()
    test_a_pipeline_arm_and_an_empty_value_are_refused()
    test_value_arm_constants_are_the_generated_decoders()
    print("test_firestore_value: ALL PASS")
