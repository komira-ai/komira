# =============================================================================
# komira_gcp_firestore/firestore_value.mojo — the Firestore document value
#   model, its RowCell mapping, and its conversion to and from the generated
#   `Value` messages.
# =============================================================================
#
# WHAT THIS IS. A Firestore document field carries a TYPED value in the REST v1
# JSON form — a single-key object naming the type:
#     {"stringValue": "..."}       string
#     {"integerValue": "123"}      int64 (a DECIMAL STRING on the wire, like the
#                                  DynamoDB N — Firestore ships int64 as a string
#                                  so JSON doubles cannot lose the low bits)
#     {"doubleValue": 3.5}         IEEE-754 double (a JSON number)
#     {"booleanValue": true}       boolean
#     {"nullValue": null}          null
#     {"timestampValue": "2026-10-01T00:00:00Z"}  RFC-3339 timestamp string
#     {"bytesValue": "aGVsbG8="}   base64 bytes
#     {"referenceValue": "projects/p/databases/d/documents/c/id"}  a doc ref
#     {"geoPointValue": {"latitude": .., "longitude": ..}}  a lat/long
#     {"arrayValue": {"values": [<value>, ...]}}  an ordered array of values
#     {"mapValue": {"fields": {name: <value>, ...}}}  a nested map of fields
# A Firestore DOCUMENT is `{"name": "...", "fields": {name: <value>, ...},
# "createTime": "...", "updateTime": "..."}` — its `fields` is a map of the above.
#
# `FsValue` is the in-memory model — a recursive tagged union covering that
# grammar. It holds no wire code: it converts to and from the generated
# `google.firestore.v1.Value` of komira_gcp_firestore_v1 (`fs_value_to_v1`,
# `fs_value_from_v1`) and of komira_gcp_firestore_listen
# (`fs_value_from_listen`), and the JSON and protobuf forms are those
# messages' own (komira_proto_codec). `serialize_fs_value` and
# `parse_fs_fields` are that JSON form, through the codec.
#
# THE RowCell MAPPING (the shared-type bridge — the SAME decision the DynamoDB
# path made, so a Firestore change feeds the Iceberg delete/append path with ZERO
# conversion). A `FsValue` maps onto the shipped `komira_rowcell.RowCell` (the
# zero-dep cell leaf — NOT `komira_iceberg`; see the import note below):
#   * stringValue     -> a STRING RowCell
#   * integerValue    -> a LONG RowCell if the decimal fits Int64, ELSE a STRING
#                        cell carrying the canonical decimal (the FF-1 / A1 fix —
#                        an over-Int64 integer must NOT silently wrap; the STRING
#                        form is lossless + stable + collision-free, exactly the
#                        DynamoDB N mapping)
#   * doubleValue     -> a DOUBLE RowCell (always lossless: it IS a Float64 on the
#                        wire)
#   * booleanValue    -> a BOOLEAN RowCell
#   * nullValue       -> a NULL RowCell (typed null; a NULL never value-equals a
#                        non-null cell regardless of declared type)
#   * timestampValue  -> a STRING RowCell (RFC-3339 string; the Iceberg primitive
#                        subset this Phase-0 path covers has no timestamp arm, so
#                        the lossless string form is stored — stable + comparable)
#   * bytesValue      -> a STRING RowCell (the base64 string verbatim — lossless)
#   * referenceValue  -> a STRING RowCell (the doc path string)
#   * geoPoint / array / map -> a STRING RowCell carrying the CANONICAL JSON
#                        serialization of the nested value. The Iceberg primitive
#                        subset has no nested/geo arm, so a nested value is stored
#                        as its serialized JSON string (exactly how the DynamoDB
#                        M/L/B path stores a nested attribute). This keeps the
#                        Iceberg writer consuming ONLY primitive cells (NOT a new
#                        RowCell arm, which would ripple into the delete-writer's
#                        equality logic).
#
# ENCAPSULATION. ZERO UnsafePointer in any signature; ZERO wildcard
# origins; ZERO unsafe_from_address. `FsValue` is a plain owned-field struct (an
# Int type tag + a String scalar arm + a `List[FsValue]` for arrays + parallel
# `List[String]`/`List[FsValue]` for map fields + a Float64 for the geo/double
# numeric arms). Recursion is via owned `List`s (no pointer). `def`-based,
# Mojo 1.0.0b2.
# =============================================================================

# THE CELL MODEL COMES FROM `komira_rowcell`, A ZERO-DEP LEAF, so a Firestore
# consumer does not take a table format or a query engine into its build.
# `CELL_T_STRING` is the cell's STRING discriminant.
from komira_rowcell.row_cell import (
    RowCell,
    make_string_cell,
    make_long_cell,
    make_double_cell,
    make_boolean_cell,
    make_null_cell,
    CELL_T_STRING,
)

from komira_encoding import base64_decode, base64_encode
from komira_json import write_json_string
from komira_proto_codec.codec import decode_json, encode_json
from komira_wkt import NullValue, Timestamp

from komira_gcp_firestore_v1.document import (
    ArrayValue as V1ArrayValue,
    Function as V1Function,
    MapValue as V1MapValue,
    Pipeline as V1Pipeline,
    Value as V1Value,
)
from komira_gcp_firestore_v1.latlng import LatLng as V1LatLng
from komira_gcp_firestore_listen.document import Value as LValue


# =============================================================================
# §0 — the FsValue type tags.
# =============================================================================
comptime FS_T_STRING: Int = 0     # {"stringValue": "..."}
comptime FS_T_INTEGER: Int = 1    # {"integerValue": "123"} (decimal string wire)
comptime FS_T_DOUBLE: Int = 2     # {"doubleValue": 3.5}
comptime FS_T_BOOL: Int = 3       # {"booleanValue": true}
comptime FS_T_NULL: Int = 4       # {"nullValue": null}
comptime FS_T_TIMESTAMP: Int = 5  # {"timestampValue": "...Z"}
comptime FS_T_BYTES: Int = 6      # {"bytesValue": "base64"}
comptime FS_T_REFERENCE: Int = 7  # {"referenceValue": "projects/.../id"}
comptime FS_T_GEOPOINT: Int = 8   # {"geoPointValue": {"latitude":..,..}}
comptime FS_T_ARRAY: Int = 9      # {"arrayValue": {"values": [...]}}
comptime FS_T_MAP: Int = 10       # {"mapValue": {"fields": {...}}}


# =============================================================================
# §1 — FsValue — the recursive Firestore value model.
# =============================================================================


struct FsValue(Copyable, Movable, Deinitable):
    """A Firestore document value (recursive tagged union).

    Field layout (arms selected by `type_tag`):
      var type_tag: Int             — one of FS_T_*
      var scalar: String            — stringValue / integerValue (decimal string)
                                      / bytesValue (base64) / referenceValue /
                                      timestampValue / booleanValue ("true"/
                                      "false") / nullValue ("") arm payload
      var num_a: Float64            — doubleValue, and geoPoint latitude
      var num_b: Float64            — geoPoint longitude (unused by other arms)
      var list_items: List[FsValue] — arrayValue's `values`
      var map_keys: List[String]    — mapValue field-name order (parallel to
                                      map_values)
      var map_values: List[FsValue] — mapValue field values (parallel to map_keys)

    Layout: a plain owned-field struct. All heap fields are plain `List`/`String`
    (no pointer field, no wildcard origin). It lives only in plain `List`s, never
    a byte-slab."""

    var type_tag: Int
    var scalar: String
    var num_a: Float64
    var num_b: Float64
    var list_items: List[FsValue]
    var map_keys: List[String]
    var map_values: List[FsValue]

    def __init__(
        out self,
        type_tag: Int,
        var scalar: String,
        num_a: Float64,
        num_b: Float64,
        var list_items: List[FsValue],
        var map_keys: List[String],
        var map_values: List[FsValue],
    ):
        self.type_tag = type_tag
        self.scalar = scalar^
        self.num_a = num_a
        self.num_b = num_b
        self.list_items = list_items^
        self.map_keys = map_keys^
        self.map_values = map_values^

    def copy(self) -> Self:
        var items = List[FsValue]()
        for i in range(len(self.list_items)):
            items.append(self.list_items[i].copy())
        var keys = List[String]()
        for i in range(len(self.map_keys)):
            keys.append(String(self.map_keys[i]))
        var vals = List[FsValue]()
        for i in range(len(self.map_values)):
            vals.append(self.map_values[i].copy())
        return Self(
            self.type_tag,
            String(self.scalar),
            self.num_a,
            self.num_b,
            items^,
            keys^,
            vals^,
        )

    # ----- typed constructors -----------------------------------------------
    @staticmethod
    def string(var v: String) -> FsValue:
        return FsValue(
            FS_T_STRING, v^, Float64(0), Float64(0),
            List[FsValue](), List[String](), List[FsValue](),
        )

    @staticmethod
    def integer(var decimal: String) -> FsValue:
        return FsValue(
            FS_T_INTEGER, decimal^, Float64(0), Float64(0),
            List[FsValue](), List[String](), List[FsValue](),
        )

    @staticmethod
    def double(v: Float64) -> FsValue:
        return FsValue(
            FS_T_DOUBLE, String(""), v, Float64(0),
            List[FsValue](), List[String](), List[FsValue](),
        )

    @staticmethod
    def boolean(v: Bool) -> FsValue:
        return FsValue(
            FS_T_BOOL,
            String("true") if v else String("false"),
            Float64(0), Float64(0),
            List[FsValue](), List[String](), List[FsValue](),
        )

    @staticmethod
    def null() -> FsValue:
        return FsValue(
            FS_T_NULL, String(""), Float64(0), Float64(0),
            List[FsValue](), List[String](), List[FsValue](),
        )

    @staticmethod
    def timestamp(var v: String) -> FsValue:
        return FsValue(
            FS_T_TIMESTAMP, v^, Float64(0), Float64(0),
            List[FsValue](), List[String](), List[FsValue](),
        )

    @staticmethod
    def bytes(var base64: String) -> FsValue:
        return FsValue(
            FS_T_BYTES, base64^, Float64(0), Float64(0),
            List[FsValue](), List[String](), List[FsValue](),
        )

    @staticmethod
    def reference(var path: String) -> FsValue:
        return FsValue(
            FS_T_REFERENCE, path^, Float64(0), Float64(0),
            List[FsValue](), List[String](), List[FsValue](),
        )

    @staticmethod
    def geo_point(latitude: Float64, longitude: Float64) -> FsValue:
        return FsValue(
            FS_T_GEOPOINT, String(""), latitude, longitude,
            List[FsValue](), List[String](), List[FsValue](),
        )

    @staticmethod
    def array_of(var items: List[FsValue]) -> FsValue:
        return FsValue(
            FS_T_ARRAY, String(""), Float64(0), Float64(0),
            items^, List[String](), List[FsValue](),
        )

    @staticmethod
    def map_of(var keys: List[String], var values: List[FsValue]) -> FsValue:
        return FsValue(
            FS_T_MAP, String(""), Float64(0), Float64(0),
            List[FsValue](), keys^, values^,
        )

    # ----- typed accessors ---------------------------------------------------
    @always_inline
    def is_null(self) -> Bool:
        return self.type_tag == FS_T_NULL

    def as_string(self) -> String:
        """The scalar payload (string / integer-decimal / bytes / reference /
        timestamp / boolean string form)."""
        return String(self.scalar)

    def map_get(self, key: String) raises -> FsValue:
        """Look up a value in a mapValue by field name. Raises if not present or
        not a map."""
        if self.type_tag != FS_T_MAP:
            raise Error("FsValue.map_get: not a map")
        for i in range(len(self.map_keys)):
            if self.map_keys[i] == key:
                return self.map_values[i].copy()
        raise Error(String("FsValue.map_get: key not found: ") + key)

    def map_has(self, key: String) -> Bool:
        if self.type_tag != FS_T_MAP:
            return False
        for i in range(len(self.map_keys)):
            if self.map_keys[i] == key:
                return True
        return False


# =============================================================================
# §2 — the RowCell mapping.
# =============================================================================

    # PORT(1.0.0): explicit destructor breaks the non-co-inductive
    # Deinitable check on this struct's recursive self-reference.
    # Field destructors still run (verified); ownership unchanged.
    def __deinit__(deinit self):
        pass


def fs_value_to_row_cell(v: FsValue) raises -> RowCell:
    """Map ONE FsValue onto a RowCell (the shared Iceberg cell model). See the
    module header for the mapping table. The over-Int64 integerValue -> STRING
    cell (FF-1) and the nested array/map/geoPoint -> canonical-JSON STRING cell
    are the load-bearing rules."""
    var t = v.type_tag
    if t == FS_T_STRING:
        return make_string_cell(String(v.scalar))
    elif t == FS_T_INTEGER:
        # Firestore integerValue is an int64 shipped as a DECIMAL STRING on the
        # wire (JSON doubles cannot carry the full 64-bit range without loss). The
        # value is always in Int64 range in a WELL-FORMED Firestore document — BUT
        # the FF-1 / A1 lesson is to NEVER silently wrap: a malformed / adversarial
        # over-Int64 decimal must map to a lossless, collision-free cell, NOT a
        # wrapped LONG. So:
        #   * an integral that FITS Int64 -> a LONG cell (the normal case);
        #   * an integral that OVERFLOWS Int64 -> a STRING cell carrying the exact
        #     canonical decimal string (lossless + stable + collision-free —
        #     because these cells drive equality-delete key matching by RowCell
        #     value-equality, a wrapped value could COLLIDE with a different key
        #     and mask the wrong row).
        var iv = _try_parse_int64(v.scalar)
        if iv:
            return make_long_cell(iv.value())
        return make_string_cell(String(v.scalar))
    elif t == FS_T_DOUBLE:
        # doubleValue is a JSON number already parsed to Float64. It is always
        # representable as a Float64 (that IS its wire form), so a DOUBLE cell is
        # always lossless here — there is no >Int64 analogue for doubleValue.
        return make_double_cell(v.num_a)
    elif t == FS_T_BOOL:
        return make_boolean_cell(v.scalar == "true")
    elif t == FS_T_NULL:
        # Typed null — the declared type is unknown from the wire; a NULL cell
        # never value-equals a non-null cell regardless of type. Use STRING.
        return make_null_cell(CELL_T_STRING)
    elif t == FS_T_TIMESTAMP:
        # RFC-3339 string — lossless + comparable as a STRING cell (the Phase-0
        # Iceberg primitive subset has no timestamp arm).
        return make_string_cell(String(v.scalar))
    elif t == FS_T_BYTES:
        # base64 string verbatim — lossless STRING cell.
        return make_string_cell(String(v.scalar))
    elif t == FS_T_REFERENCE:
        # The document path string — lossless STRING cell.
        return make_string_cell(String(v.scalar))
    else:
        # geoPoint / array / map — no primitive Iceberg arm. Serialize to the
        # canonical JSON string form and store as a STRING cell.
        return make_string_cell(serialize_fs_value(v))


def fs_fields_to_row_cells(
    fields: FsValue, column_names: List[String]
) raises -> List[RowCell]:
    """Project a Firestore document's `fields` (a mapValue) onto a row of
    RowCells in `column_names` order. A column absent from the fields -> a NULL
    string cell (schema-evolution's add-column null-fill shape). RAISES if
    `fields` is not a map."""
    if fields.type_tag != FS_T_MAP:
        raise Error("fs_fields_to_row_cells: fields is not a map")
    var out = List[RowCell]()
    for i in range(len(column_names)):
        var name = column_names[i]
        if fields.map_has(name):
            out.append(fs_value_to_row_cell(fields.map_get(name)))
        else:
            out.append(make_null_cell(CELL_T_STRING))
    return out^


# =============================================================================# =============================================================================
# §3 — the conversion to and from the generated `Value` messages.
# =============================================================================
#
# FsValue keeps each scalar as the REST JSON form spells it (an int64 as its
# decimal string, bytes as base64, a timestamp as RFC 3339), so a value read
# over REST or over the Listen stream is the same FsValue. A Value arm FsValue
# has no tag for (`fieldReferenceValue`, `variableReferenceValue`,
# `functionValue`, `pipelineValue`: pipeline expressions, never stored in a
# document) is refused by name, and so is a Value with no arm set.


# The generated `Value`'s `value_type` oneof arms (`_oneof0_case`, in the
# order the proto declares them). test_firestore_value pins each against the
# generated decoder, so a reordering bump of the pinned protos fails a test.
comptime VALUE_NULL = 1
"""`Value.value_type`: `null_value`."""
comptime VALUE_BOOLEAN = 2
"""`Value.value_type`: `boolean_value`."""
comptime VALUE_INTEGER = 3
"""`Value.value_type`: `integer_value`."""
comptime VALUE_DOUBLE = 4
"""`Value.value_type`: `double_value`."""
comptime VALUE_TIMESTAMP = 5
"""`Value.value_type`: `timestamp_value`."""
comptime VALUE_STRING = 6
"""`Value.value_type`: `string_value`."""
comptime VALUE_BYTES = 7
"""`Value.value_type`: `bytes_value`."""
comptime VALUE_REFERENCE = 8
"""`Value.value_type`: `reference_value`."""
comptime VALUE_GEO_POINT = 9
"""`Value.value_type`: `geo_point_value`."""
comptime VALUE_ARRAY = 10
"""`Value.value_type`: `array_value`."""
comptime VALUE_MAP = 11
"""`Value.value_type`: `map_value`."""


def _v1_value(arm: Int) -> V1Value:
    return V1Value(
        arm, None, None, None, None, None, None, None, None, None,
        List[V1ArrayValue](), List[V1MapValue](), None, None,
        List[V1Function](), List[V1Pipeline](),
    )


def fs_value_to_v1(v: FsValue) raises -> V1Value:
    """The generated (REST) `Value` for `v`. Raises on an integer that is not
    an Int64 decimal, a timestamp that is not RFC 3339, or bytes that are not
    base64."""
    var t = v.type_tag
    if t == FS_T_NULL:
        var out = _v1_value(VALUE_NULL)
        out.null_value = NullValue(0)
        return out^
    elif t == FS_T_BOOL:
        var out = _v1_value(VALUE_BOOLEAN)
        out.boolean_value = v.scalar == "true"
        return out^
    elif t == FS_T_INTEGER:
        var iv = _try_parse_int64(v.scalar)
        if not iv:
            raise Error(
                "FsValue: integerValue is not an Int64 decimal ("
                + String(v.scalar.byte_length())
                + " bytes)"
            )
        var out = _v1_value(VALUE_INTEGER)
        out.integer_value = iv.value()
        return out^
    elif t == FS_T_DOUBLE:
        var out = _v1_value(VALUE_DOUBLE)
        out.double_value = v.num_a
        return out^
    elif t == FS_T_TIMESTAMP:
        var out = _v1_value(VALUE_TIMESTAMP)
        out.timestamp_value = Timestamp.from_proto3_json(v.scalar)
        return out^
    elif t == FS_T_STRING:
        var out = _v1_value(VALUE_STRING)
        out.string_value = v.scalar.copy()
        return out^
    elif t == FS_T_BYTES:
        var out = _v1_value(VALUE_BYTES)
        out.bytes_value = base64_decode(v.scalar)
        return out^
    elif t == FS_T_REFERENCE:
        var out = _v1_value(VALUE_REFERENCE)
        out.reference_value = v.scalar.copy()
        return out^
    elif t == FS_T_GEOPOINT:
        var out = _v1_value(VALUE_GEO_POINT)
        out.geo_point_value = V1LatLng(v.num_a, v.num_b)
        return out^
    elif t == FS_T_ARRAY:
        var items = List[V1Value]()
        for i in range(len(v.list_items)):
            items.append(fs_value_to_v1(v.list_items[i]))
        var out = _v1_value(VALUE_ARRAY)
        out.array_value.append(V1ArrayValue(items^))
        return out^
    elif t == FS_T_MAP:
        var out = _v1_value(VALUE_MAP)
        out.map_value.append(V1MapValue(fs_fields_to_v1(v)))
        return out^
    raise Error("FsValue: unknown type tag " + String(t))


def fs_fields_to_v1(fields: FsValue) raises -> Dict[String, V1Value]:
    """A document's `fields` (an FS_T_MAP FsValue) as the generated map."""
    if fields.type_tag != FS_T_MAP:
        raise Error("fs_fields_to_v1: fields is not a map")
    var out = Dict[String, V1Value]()
    for i in range(len(fields.map_keys)):
        out[fields.map_keys[i].copy()] = fs_value_to_v1(fields.map_values[i])
    return out^


def _unsupported_arm(arm: Int) -> Error:
    if arm == 0:
        return Error("Firestore Value: no arm is set")
    return Error(
        "Firestore Value: arm "
        + String(arm)
        + " (a pipeline expression) has no FsValue form"
    )


def fs_value_from_v1(v: V1Value) raises -> FsValue:
    """The FsValue of a generated (REST) `Value`."""
    var c = v._oneof0_case
    if c == VALUE_NULL:
        return FsValue.null()
    elif c == VALUE_BOOLEAN:
        return FsValue.boolean(v.boolean_value.value())
    elif c == VALUE_INTEGER:
        return FsValue.integer(String(v.integer_value.value()))
    elif c == VALUE_DOUBLE:
        return FsValue.double(v.double_value.value())
    elif c == VALUE_TIMESTAMP:
        return FsValue.timestamp(v.timestamp_value.value().to_proto3_json())
    elif c == VALUE_STRING:
        return FsValue.string(v.string_value.value().copy())
    elif c == VALUE_BYTES:
        return FsValue.bytes(base64_encode(Span(v.bytes_value.value())))
    elif c == VALUE_REFERENCE:
        return FsValue.reference(v.reference_value.value().copy())
    elif c == VALUE_GEO_POINT:
        var g = v.geo_point_value.value().copy()
        return FsValue.geo_point(g.latitude, g.longitude)
    elif c == VALUE_ARRAY:
        var items = List[FsValue]()
        if len(v.array_value) > 0:
            for i in range(len(v.array_value[0].values)):
                items.append(fs_value_from_v1(v.array_value[0].values[i]))
        return FsValue.array_of(items^)
    elif c == VALUE_MAP:
        if len(v.map_value) == 0:
            return FsValue.map_of(List[String](), List[FsValue]())
        return fs_fields_from_v1(v.map_value[0].fields)
    raise _unsupported_arm(c)


def fs_fields_from_v1(fields: Dict[String, V1Value]) raises -> FsValue:
    """The FS_T_MAP FsValue of a generated `fields` map, in its order."""
    var keys = List[String]()
    var vals = List[FsValue]()
    for e in fields.items():
        keys.append(e.key.copy())
        vals.append(fs_value_from_v1(e.value))
    return FsValue.map_of(keys^, vals^)


def fs_value_from_listen(v: LValue) raises -> FsValue:
    """The FsValue of a `Value` decoded off the Listen stream
    (komira_gcp_firestore_listen): the same arms as `fs_value_from_v1`."""
    var c = v._oneof0_case
    if c == VALUE_NULL:
        return FsValue.null()
    elif c == VALUE_BOOLEAN:
        return FsValue.boolean(v.boolean_value.value())
    elif c == VALUE_INTEGER:
        return FsValue.integer(String(v.integer_value.value()))
    elif c == VALUE_DOUBLE:
        return FsValue.double(v.double_value.value())
    elif c == VALUE_TIMESTAMP:
        return FsValue.timestamp(v.timestamp_value.value().to_proto3_json())
    elif c == VALUE_STRING:
        return FsValue.string(v.string_value.value().copy())
    elif c == VALUE_BYTES:
        return FsValue.bytes(base64_encode(Span(v.bytes_value.value())))
    elif c == VALUE_REFERENCE:
        return FsValue.reference(v.reference_value.value().copy())
    elif c == VALUE_GEO_POINT:
        var g = v.geo_point_value.value().copy()
        return FsValue.geo_point(g.latitude, g.longitude)
    elif c == VALUE_ARRAY:
        var items = List[FsValue]()
        if len(v.array_value) > 0:
            for i in range(len(v.array_value[0].values)):
                items.append(fs_value_from_listen(v.array_value[0].values[i]))
        return FsValue.array_of(items^)
    elif c == VALUE_MAP:
        if len(v.map_value) == 0:
            return FsValue.map_of(List[String](), List[FsValue]())
        return fs_fields_from_listen(v.map_value[0].fields)
    raise _unsupported_arm(c)


def fs_fields_from_listen(fields: Dict[String, LValue]) raises -> FsValue:
    """The FS_T_MAP FsValue of a Listen document's `fields` map."""
    var keys = List[String]()
    var vals = List[FsValue]()
    for e in fields.items():
        keys.append(e.key.copy())
        vals.append(fs_value_from_listen(e.value))
    return FsValue.map_of(keys^, vals^)


# =============================================================================
# §4 — the JSON form, through the generated messages.
# =============================================================================


def serialize_fs_value(v: FsValue) raises -> String:
    """`v` in the Firestore REST JSON value form (`{"stringValue":"x"}`), as
    komira_proto_codec writes the generated `Value`."""
    return encode_json(fs_value_to_v1(v))


def parse_fs_fields(json: String) raises -> FsValue:
    """A Firestore `fields` JSON object (`{"name": <value>, ...}`) as an
    FS_T_MAP FsValue, read strictly by komira_proto_codec as a `MapValue`."""
    var m = decode_json[V1MapValue](String('{"fields":') + json + String("}"))
    return fs_fields_from_v1(m.fields)


# =============================================================================
# §5 — small helpers.
# =============================================================================
# Int64 range must NOT wrap silently; the caller routes an overflow to a lossless
# STRING cell.


def _try_parse_int64(s: String) -> Optional[Int64]:
    """Parse an integral decimal into an Int64, returning `None` (NOT a wrapped
    value) if it OVERFLOWS the Int64 range or is not an integral decimal.
    Accumulation runs in the NEGATIVE domain ([-2^63, 0]) so the full magnitude
    of Int64 MIN (which exceeds Int64 MAX by one) is representable and the +/-
    boundaries are both handled losslessly.

    Returns None for the empty / sign-only / non-digit / fractional cases too —
    the caller routes those to a STRING cell, never a wrapped LONG."""
    var sb = s.as_bytes()
    if len(sb) == 0:
        return None
    var neg = False
    var i = 0
    if sb[0] == UInt8(ord("-")):
        neg = True
        i = 1
    if i >= len(sb):
        return None  # a bare "-" is not a number
    var acc = Int64(0)
    comptime INT64_MIN = Int64(-9223372036854775808)
    while i < len(sb):
        var c = sb[i]
        if c < UInt8(ord("0")) or c > UInt8(ord("9")):
            return None  # non-digit (incl. '.'/'e') -> not an integral Int64
        var d = Int64(Int(c) - ord("0"))
        # Overflow check for `acc = acc*10 - d` staying >= INT64_MIN.
        if acc < INT64_MIN // Int64(10):
            return None
        acc = acc * Int64(10)
        if acc < INT64_MIN + d:
            return None
        acc = acc - d
        i += 1
    if neg:
        return acc
    # Positive: negate. acc == INT64_MIN cannot be negated (no positive twin).
    if acc == INT64_MIN:
        return None
    return -acc


def fs_json_quote(s: String) -> String:
    """`s` as a JSON string literal (komira_json's escaping), for a caller
    that writes a structured-query JSON text by hand."""
    var buf = List[UInt8]()
    write_json_string(buf, s)
    return String(unsafe_from_utf8=Span(buf))
