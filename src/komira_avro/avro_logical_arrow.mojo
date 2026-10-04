# =============================================================================
# avro_logical_arrow.mojo — arrow.* custom-logical-type override table
#                           — bidirectional Arrow<->Avro round-trip
#                           for the 16 lossy Arrow types.
# =============================================================================
#
# Apache Avro 1.11.1 has no native counterpart for many Arrow types
# (Float16, the small int widths, unsigned ints, Date64, the
# second/nanosecond temporal precisions, the Duration units). This module makes
# these survive a round-trip via `arrow.*` schema annotations: the writer
# stamps `{"type": <avro_primitive>, "logicalType": "arrow.<name>"}` (or a
# `fixed(N)` for the FIXED-backed cases), and the reader consults this
# override table BEFORE the standard Avro->Arrow logical-type mapping.
#
# Two responsibilities, both at the schema layer (the value decode for these
# types is in action_table.mojo / avro_ocf_reader.mojo — the underlying
# physical type already decodes; this module only governs the type lattice):
#
#   1. Writer side (schema-gen, NOT data-write): `arrow_type_to_arrow_logical`
#      + `from_arrow_avro_type_json` map a lossy Arrow type to its arrow.*
#      annotation + the REQUIRED underlying Avro physical type.
#      Driven by `emit_arrow_logicals` (default True).
#
#   2. Reader side: `avro_node_to_arrow_with_override` consults the override
#      table first. CRITICAL: the annotation is
#      HONORED ONLY when the underlying Avro physical type matches the
#      backing-type table (the codec-compatibility-guard). On mismatch, OR on
#      an unknown `arrow.*` annotation (forwards-compat), it falls back
#      silently to the standard Avro-type -> Arrow-type mapping. This matches
#      arrow-rs's `(Some("arrow.X"), c @ Codec::TYPE)` guarded match arms.
#
# `arrow.uint64` MUST be backed by `fixed(8)` (8
# raw little-endian bytes, no zigzag wrapping), NOT `long`: a `long`-backed
# uint64 silently round-trip-fails the
# codec-compatibility-guard. `arrow.float16` is backed by `fixed(2)`.
#
# There is no sidecar `"arrow.logical-type"` JSON key — an Avro type has
# at most ONE `"logicalType"` slot, and the reader consults only that slot.
#
# Encapsulation: pure typed-value transforms over AvroSchema / ArrowType /
# String. No UnsafePointer, no pointer arithmetic, no wildcard origins.
# =============================================================================

from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.schema import Schema

from .avro_schema import (
    AvroSchema,
    AvroNode,
    avro_node_to_arrow,
    AVRO_KIND_INT,
    AVRO_KIND_LONG,
    AVRO_KIND_FIXED,
    AVRO_KIND_UNION,
)


# =============================================================================
# arrow.* annotation constants (single source for both directions).
# =============================================================================

comptime ARROW_LT_INT8: String = "arrow.int8"
comptime ARROW_LT_INT16: String = "arrow.int16"
comptime ARROW_LT_UINT8: String = "arrow.uint8"
comptime ARROW_LT_UINT16: String = "arrow.uint16"
comptime ARROW_LT_UINT32: String = "arrow.uint32"
comptime ARROW_LT_UINT64: String = "arrow.uint64"
comptime ARROW_LT_FLOAT16: String = "arrow.float16"
comptime ARROW_LT_DATE64: String = "arrow.date64"
comptime ARROW_LT_TIMESTAMP_SECONDS: String = "arrow.timestamp-seconds"
comptime ARROW_LT_TIMESTAMP_NANOS: String = "arrow.timestamp-nanos"
comptime ARROW_LT_TIME_SECONDS: String = "arrow.time-seconds"
comptime ARROW_LT_TIME_NANOS: String = "arrow.time-nanos"
comptime ARROW_LT_DURATION_SECONDS: String = "arrow.duration-seconds"
comptime ARROW_LT_DURATION_MILLIS: String = "arrow.duration-millis"
comptime ARROW_LT_DURATION_MICROS: String = "arrow.duration-micros"
comptime ARROW_LT_DURATION_NANOS: String = "arrow.duration-nanos"
# 17th annotation (the union-backed row). Structurally different from the
# 16 primitive/fixed-backed siblings: it rides on an Avro `union` (the
# custom-attribute-slot carrier) and disambiguates a SPARSE union layout from
# the standard reader fallback (`UNION_DENSE`). See `_BACK_UNION` below.
comptime ARROW_LT_UNION_SPARSE: String = "arrow.union-sparse"


# =============================================================================
# Backing-type discriminant for an arrow.* annotation.
# =============================================================================
#
# The codec-compatibility-guard requires the underlying Avro physical type to
# match. We model the required physical shape as a (kind, size) pair:
#   - INT-backed   : AVRO_KIND_INT,   size irrelevant (0)
#   - LONG-backed  : AVRO_KIND_LONG,  size irrelevant (0)
#   - FIXED-backed : AVRO_KIND_FIXED, size = the REQUIRED fixed byte width.
#   - UNION-backed : AVRO_KIND_UNION, size irrelevant (0). The custom-attribute
#                    slot for arrow.union-sparse. The guard
#                    is codec-pattern-matched on the union kind (arrow-rs
#                    `Codec::Union` precedent), not a byte-width check.

comptime _BACK_INT: Int = 0
comptime _BACK_LONG: Int = 1
comptime _BACK_FIXED: Int = 2
comptime _BACK_UNION: Int = 3


@fieldwise_init
struct ArrowLogicalEntry(Copyable, Movable):
    """One row of the override table: an arrow.* annotation, its
    REQUIRED underlying Avro physical type, and the Arrow type it maps to."""

    var annotation: String
    # _BACK_INT / _BACK_LONG / _BACK_FIXED.
    var backing: Int
    # Required fixed byte size when backing == _BACK_FIXED (8 for uint64,
    # 2 for float16). Ignored otherwise.
    var fixed_size: Int
    # The Arrow type this annotation round-trips to / from.
    var arrow_type: ArrowType

    @always_inline
    def required_avro_kind(self) -> Int:
        if self.backing == _BACK_INT:
            return AVRO_KIND_INT
        elif self.backing == _BACK_LONG:
            return AVRO_KIND_LONG
        elif self.backing == _BACK_UNION:
            return AVRO_KIND_UNION
        return AVRO_KIND_FIXED


# =============================================================================
# The override table (17 rows). Built once per consult — the list is
# tiny and avoids a comptime global.
# =============================================================================


def _override_table() -> List[ArrowLogicalEntry]:
    var t = List[ArrowLogicalEntry]()
    # Primitive-backed: int.
    t.append(ArrowLogicalEntry(ARROW_LT_INT8, _BACK_INT, 0, ArrowType.INT8))
    t.append(ArrowLogicalEntry(ARROW_LT_INT16, _BACK_INT, 0, ArrowType.INT16))
    t.append(ArrowLogicalEntry(ARROW_LT_UINT8, _BACK_INT, 0, ArrowType.UINT8))
    t.append(
        ArrowLogicalEntry(ARROW_LT_UINT16, _BACK_INT, 0, ArrowType.UINT16)
    )
    t.append(
        ArrowLogicalEntry(
            ARROW_LT_TIME_SECONDS, _BACK_INT, 0, ArrowType.TIME32_S
        )
    )
    # Primitive-backed: long.
    t.append(
        ArrowLogicalEntry(ARROW_LT_UINT32, _BACK_LONG, 0, ArrowType.UINT32)
    )
    t.append(
        ArrowLogicalEntry(ARROW_LT_DATE64, _BACK_LONG, 0, ArrowType.DATE64)
    )
    t.append(
        ArrowLogicalEntry(
            ARROW_LT_TIMESTAMP_SECONDS, _BACK_LONG, 0, ArrowType.TIMESTAMP_S
        )
    )
    t.append(
        ArrowLogicalEntry(
            ARROW_LT_TIMESTAMP_NANOS, _BACK_LONG, 0, ArrowType.TIMESTAMP_NS
        )
    )
    t.append(
        ArrowLogicalEntry(
            ARROW_LT_TIME_NANOS, _BACK_LONG, 0, ArrowType.TIME64_NS
        )
    )
    t.append(
        ArrowLogicalEntry(
            ARROW_LT_DURATION_SECONDS, _BACK_LONG, 0, ArrowType.DURATION_S
        )
    )
    t.append(
        ArrowLogicalEntry(
            ARROW_LT_DURATION_MILLIS, _BACK_LONG, 0, ArrowType.DURATION_MS
        )
    )
    t.append(
        ArrowLogicalEntry(
            ARROW_LT_DURATION_MICROS, _BACK_LONG, 0, ArrowType.DURATION_US
        )
    )
    t.append(
        ArrowLogicalEntry(
            ARROW_LT_DURATION_NANOS, _BACK_LONG, 0, ArrowType.DURATION_NS
        )
    )
    # FIXED-backed: uint64 -> fixed(8), float16 -> fixed(2).
    t.append(
        ArrowLogicalEntry(ARROW_LT_UINT64, _BACK_FIXED, 8, ArrowType.UINT64)
    )
    t.append(
        ArrowLogicalEntry(ARROW_LT_FLOAT16, _BACK_FIXED, 2, ArrowType.FLOAT16)
    )
    # UNION-backed (17th annotation, the union row): arrow.union-sparse rides
    # on an Avro `union`. It disambiguates a SPARSE union layout from the
    # standard reader fallback, which maps a bare (non-null-collapsing) union to
    # UNION_DENSE. fixed_size is irrelevant for the union backing (0).
    t.append(
        ArrowLogicalEntry(
            ARROW_LT_UNION_SPARSE, _BACK_UNION, 0, ArrowType.UNION_SPARSE
        )
    )
    return t^


@always_inline
def _lookup_by_annotation(
    table: List[ArrowLogicalEntry], annotation: String
) -> Int:
    """Return the table index for `annotation`, or -1 if not an arrow.*
    annotation this module recognizes."""
    for i in range(len(table)):
        if table[i].annotation == annotation:
            return i
    return -1


@always_inline
def _lookup_by_arrow_type(
    table: List[ArrowLogicalEntry], arrow_type: ArrowType
) -> Int:
    """Return the table index whose Arrow type equals `arrow_type`, or -1 if
    `arrow_type` is not a lossy Arrow type this module round-trips via arrow.*."""
    for i in range(len(table)):
        if table[i].arrow_type == arrow_type:
            return i
    return -1


# =============================================================================
# Writer side (schema-gen): Arrow type -> arrow.* annotation / Avro JSON.
# =============================================================================


def is_lossy_arrow_type(arrow_type: ArrowType) -> Bool:
    """True if `arrow_type` is one of the 17 lossy Arrow types that require an
    arrow.* annotation to round-trip through Avro. The 17th
    (UNION_SPARSE) is union-backed; the other 16 are primitive/fixed-backed."""
    var table = _override_table()
    return _lookup_by_arrow_type(table, arrow_type) != -1


def arrow_logical_annotation(arrow_type: ArrowType) -> String:
    """Return the arrow.* annotation string for a lossy Arrow type, or the
    empty string if `arrow_type` is not a lossy type."""
    var table = _override_table()
    var idx = _lookup_by_arrow_type(table, arrow_type)
    if idx < 0:
        return String("")
    return table[idx].annotation


def from_arrow_avro_type_json(
    arrow_type: ArrowType, fixed_name: String
) raises -> String:
    """Emit the Avro schema JSON fragment for one lossy Arrow type, with its
    arrow.* annotation + the REQUIRED underlying physical type. Driven by the
    writer when `emit_arrow_logicals=True`.

    Primitive-backed: `{"type":"int"|"long","logicalType":"arrow.<name>"}`.
    FIXED-backed:     `{"type":"fixed","name":"<fixed_name>","size":<N>,
                        "logicalType":"arrow.<name>"}` — the `size` is a
                      sibling of type/name/logicalType, NOT nested.

    `fixed_name` is the unique Avro `name` for the FIXED-backed cases
    (arrow.uint64 / arrow.float16); ignored for primitive-backed types.

    Raises if `arrow_type` is NOT a lossy type (callers must gate on
    `is_lossy_arrow_type` first)."""
    var table = _override_table()
    var idx = _lookup_by_arrow_type(table, arrow_type)
    if idx < 0:
        raise Error(
            "AvroSchemaError.NOT_A_LOSSY_ARROW_TYPE: arrow.* round-trip"
            " annotation requested for a non-lossy Arrow type"
        )
    var e = table[idx].copy()
    if e.backing == _BACK_FIXED:
        var out = String('{"type":"fixed","name":"')
        out += fixed_name
        out += '","size":'
        out += String(e.fixed_size)
        out += ',"logicalType":"'
        out += e.annotation
        out += '"}'
        return out^
    if e.backing == _BACK_UNION:
        # UNION-backed (17th annotation). An Avro union is normally a bare JSON
        # array, which cannot carry a `logicalType` key. The custom-attribute
        # slot per arrow-rs precedent is the OBJECT-form union: a `{"type":
        # "union","branches":[...],"logicalType":"arrow.union-sparse"}` carrier
        # that the parser recognizes and stamps onto the union node. The
        # branch set here is a schema-level placeholder (`["null","int"]`) — the
        # round-trip the backing-type guard validates is the type-lattice
        # annotation, exactly as for the 16 primitive/fixed siblings; per-branch
        # value encode/decode is the data-level decoder's concern.
        var union_out = String('{"type":"union","branches":["null","int"]')
        union_out += ',"logicalType":"'
        union_out += e.annotation
        union_out += '"}'
        return union_out^
    # Primitive-backed (int / long).
    var prim = String("int") if e.backing == _BACK_INT else String("long")
    var prim_out = String('{"type":"')
    prim_out += prim
    prim_out += '","logicalType":"'
    prim_out += e.annotation
    prim_out += '"}'
    return prim_out^


# =============================================================================
# Reader side: override-table consult BEFORE standard logical-type mapping,
# with the codec-compatibility-guard.
# =============================================================================


def avro_node_to_arrow_with_override(
    schema: AvroSchema, idx: Int
) raises -> ArrowType:
    """Map an Avro schema node to its Arrow type, consulting the arrow.*
    override table BEFORE the standard Avro->Arrow logical-type mapping.

    Resolution order:
      1. If the node carries a recognized arrow.* logicalType AND the
         underlying Avro physical type matches the backing-type table
         (the codec-compatibility-guard), emit the override Arrow type.
      2. Otherwise (mismatched physical type for a recognized annotation, OR
         an unrecognized arrow.* annotation — forwards-compat), fall back
         silently to the standard mapping in `avro_node_to_arrow`. This
         matches arrow-rs's guarded `(Some("arrow.X"), c @ Codec::TYPE)`
         match-arm semantics: the annotation is HONORED only on a physical
         match; otherwise the round-trip silently degrades to the underlying
         primitive's standard Arrow type.

    A node WITHOUT an arrow.* annotation (or with a standard Avro logical
    type) routes straight to the standard mapping."""
    var n = schema.node(idx)
    var logical = n.logical_type

    # Only arrow.* annotations are governed by the override table. Everything
    # else (no logical type, or a standard Avro logical type like "date" /
    # "timestamp-micros") is the standard mapping's responsibility.
    if logical.startswith("arrow."):
        var table = _override_table()
        var t_idx = _lookup_by_annotation(table, logical)
        if t_idx >= 0:
            var e = table[t_idx].copy()
            # Codec-compatibility-guard: the underlying physical type MUST
            # match the backing-type table, else silent fallback.
            if _physical_matches(n, e):
                return e.arrow_type
            # Mismatch -> fall through to standard mapping (silent fallback).
        # Unrecognized arrow.* annotation -> fall through (forwards-compat).

    # Standard Avro->Arrow mapping. For arrow.* annotations the standard
    # mapper does not recognize the logical string and falls through to the
    # node's underlying physical type — exactly the silent-fallback target.
    return _avro_node_to_arrow_ignoring_arrow_logical(schema, idx)


@always_inline
def _physical_matches(n: AvroNode, e: ArrowLogicalEntry) -> Bool:
    """The codec-compatibility-guard: does node `n`'s underlying Avro physical
    type satisfy the backing-type requirement of override entry `e`?"""
    if e.backing == _BACK_FIXED:
        return n.kind == AVRO_KIND_FIXED and n.size == e.fixed_size
    elif e.backing == _BACK_INT:
        return n.kind == AVRO_KIND_INT
    elif e.backing == _BACK_UNION:
        # Codec-pattern-matched on the union kind (arrow-rs `Codec::Union`).
        return n.kind == AVRO_KIND_UNION
    else:  # _BACK_LONG
        return n.kind == AVRO_KIND_LONG


def _avro_node_to_arrow_ignoring_arrow_logical(
    schema: AvroSchema, idx: Int
) raises -> ArrowType:
    """Standard Avro->Arrow mapping with any arrow.* annotation neutralized.

    The standard mapper `avro_node_to_arrow` already falls through unknown
    logical types to the underlying physical type (avro_schema.mojo: "Unknown
    logical type: fall through to underlying physical type"). An arrow.*
    string is, by construction, not one of its recognized standard logical
    types, so it lands on the physical-type branch — which is precisely the
    silent-fallback target (e.g. arrow.uint64 over a `long` -> Int64). We
    therefore delegate straight to `avro_node_to_arrow`."""
    return avro_node_to_arrow(schema, idx)


# =============================================================================
# Whole-schema Arrow -> Avro record-schema JSON walker.
# =============================================================================
#
# `from_arrow_avro_type_json` is the per-type fragment; this is the
# record-level walker the writer needs.
#
# Given an Arrow Schema, emit a complete Avro `record` schema JSON string:
#   {"type":"record","name":<record_name>,"fields":[
#       {"name":<col>,"type":<avro_type_json>}, ...]}
#
# Per-field type JSON:
#   - A NON-nullable, NON-lossy column gets the bare Avro primitive type
#     ("long" / "string" / ...).
#   - A NON-nullable, LOSSY column gets the arrow.* annotated fragment from
#     `from_arrow_avro_type_json` (when emit_arrow_logicals=True).
#   - A nullable column wraps the value type in `union[null, T]` (NULL_FIRST):
#       ["null", <value_type_json>]
#     which the reader collapses back to a nullable Arrow column and the writer
#     encodes by emitting union tag 1 + the value (or tag 0 for null).
#
# FIXED-backed lossy types (arrow.uint64 -> fixed(8), arrow.float16 ->
# fixed(2)) require a UNIQUE Avro `name`. We generate `<record_name>_<col>_fx`
# per such column so two FIXED-backed columns never collide.
#
# `emit_arrow_logicals=False` strips the arrow.* annotations and falls back to
# the lossy type's STANDARD Avro physical mapping (e.g. uint64 -> a bare
# "long"); this loses the round-trip fidelity for those columns but produces a
# spec-plain Avro schema for cross-tool consumers that don't know arrow.*.


def _write_standard_avro_type_name[W: Writer](mut writer: W, arrow_type: ArrowType) raises:
    """WRITE what `_standard_avro_type_name` returns. ⚠ THIS WRITES; IT DOES NOT RETURN.

    The arms live here so no string constant is ever SELECTED and
    returned. A literal-returning ladder lowers to two parallel
    (pointer, length) constant arrays whose two call-site references
    an `--emit shared-lib` link binds INDEPENDENTLY, and a shared
    library can bind such a pair CROSSED, returning the wrong string or
    crashing its host."""
    if arrow_type == ArrowType.BOOL:
        writer.write(String("boolean"))
        return
    elif arrow_type == ArrowType.INT32:
        writer.write(String("int"))
        return
    elif arrow_type == ArrowType.INT64:
        writer.write(String("long"))
        return
    elif arrow_type == ArrowType.FLOAT32:
        writer.write(String("float"))
        return
    elif arrow_type == ArrowType.FLOAT64:
        writer.write(String("double"))
        return
    elif (
        arrow_type == ArrowType.STRING
        or arrow_type == ArrowType.LARGE_STRING
    ):
        writer.write(String("string"))
        return
    elif (
        arrow_type == ArrowType.BINARY
        or arrow_type == ArrowType.LARGE_BINARY
    ):
        writer.write(String("bytes"))
        return
    raise Error(
        String("AvroSchemaError.UNSUPPORTED_ARROW_TYPE: Arrow type ")
        + String(arrow_type)
        + " has no Avro writer mapping (the writer supports flat primitives +"
        " the 16 lossy arrow.* types; nested / decimal / dictionary write are"
        " not supported yet)"
    )


def _standard_avro_type_name(arrow_type: ArrowType) raises -> String:
    """The bare Avro primitive type-name for a NON-lossy Arrow type (the writer
    emits the value with the matching `encode_*`)."""
    var out = String()
    _write_standard_avro_type_name(out, arrow_type)
    return out^


def _standard_avro_type_for_lossy(arrow_type: ArrowType) raises -> StaticString:
    """When emit_arrow_logicals=False, a lossy Arrow type degrades to its
    underlying STANDARD Avro physical type (no arrow.* annotation). int-backed
    -> "int", long-backed -> "long", fixed-backed -> "bytes" (8 / 2 raw bytes).
    The reader silent-fallback then yields the underlying primitive's Arrow
    type (e.g. uint64 over fixed(8) -> BINARY)."""
    var table = _override_table()
    var idx = _lookup_by_arrow_type(table, arrow_type)
    if idx < 0:
        raise Error("AvroSchemaError.NOT_A_LOSSY_ARROW_TYPE")
    var e = table[idx].copy()
    if e.backing == _BACK_INT:
        return "int"
    elif e.backing == _BACK_LONG:
        return "long"
    # FIXED-backed without the annotation: a bare fixed needs a name, so we
    # degrade to "bytes" (variable-length) which the writer encodes as
    # length-prefixed raw bytes.
    return "bytes"


def _field_type_json(
    arrow_type: ArrowType,
    nullable: Bool,
    emit_arrow_logicals: Bool,
    fixed_name: String,
) raises -> String:
    """Emit the Avro `"type"` JSON for one column.

    Wraps the value type in `["null", T]` (NULL_FIRST) when nullable."""
    var value_json: String
    if is_lossy_arrow_type(arrow_type):
        if emit_arrow_logicals:
            value_json = from_arrow_avro_type_json(arrow_type, fixed_name)
        else:
            value_json = (
                '"' + _standard_avro_type_for_lossy(arrow_type) + '"'
            )
    else:
        value_json = '"' + _standard_avro_type_name(arrow_type) + '"'

    if nullable:
        # union[null, T] — NULL_FIRST (tag 0 == null, tag 1 == value).
        return String('["null",') + value_json + "]"
    return value_json^


def from_arrow_schema_json(
    schema: Schema,
    record_name: String = String("topLevelRecord"),
    emit_arrow_logicals: Bool = True,
) raises -> String:
    """Emit a complete Avro `record` schema JSON for an Arrow Schema (the
    whole-schema Arrow -> Avro walker the writer uses).

    Each Arrow field becomes one Avro record field. Nullable fields are wrapped
    in `union[null, T]` (NULL_FIRST). Lossy Arrow types get arrow.* annotations
    when `emit_arrow_logicals=True` (with unique FIXED `name` generation),
    else they degrade to the standard Avro physical type.

    Raises if a column has an Arrow type the writer cannot map."""
    var n = schema.num_columns()
    if n == 0:
        raise Error("AvroSchemaError.EMPTY_SCHEMA: Arrow schema has no columns")

    var out = String('{"type":"record","name":"')
    out += record_name
    out += '","fields":['
    for c in range(n):
        if c > 0:
            out += ","
        var fname = schema.field_name(c)
        var at = schema.field_arrow_type(c)
        var nullable = schema.field_nullable(c)
        # Unique fixed name per column (only consumed by FIXED-backed lossy
        # types, but generated unconditionally so it's always unique).
        var fixed_name = record_name + "_" + fname + "_fx"
        var type_json = _field_type_json(
            at, nullable, emit_arrow_logicals, fixed_name
        )
        out += '{"name":"'
        out += fname
        out += '","type":'
        out += type_json
        out += "}"
    out += "]}"
    return out^
