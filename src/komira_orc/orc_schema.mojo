# =============================================================================
# orc_schema.mojo — ORC type tree -> Arrow type lattice + canonical form.
# =============================================================================
#
# ORC's schema is a FLAT pre-order list of Type nodes (Footer.types), where
# each node names its children by INDEX into that list (Type.subtypes). This
# module:
#   1. Lifts a parsed flat `List[OrcRawType]` into an `OrcSchema` (the same
#      flat-arena, index-link shape as the Avro reader's node tree — NO
#      recursive struct, NO UnsafePointer).
#   2. Produces a canonical-form string for the schema (round-trip equality
#      testing; mirrors Hive's `TypeDescription.toString()` notation
#      e.g. `struct<a:int,b:string>`).
#   3. Maps each ORC type to the komira_core ArrowType lattice.
#
# ORC's schema tree is structurally finite (a flat list with forward-only
# index links per the protobuf encoding), so no recursion check is needed IN
# THE RECURSIVE DECODER (unlike Avro, ORC cannot express a cyclic schema).
#
# ⚠ THAT IS A STATEMENT ABOUT CONFORMING WRITERS, NOT ABOUT ARRIVING BYTES.
# `OrcSchema.from_types` is where it becomes true: it ENFORCES `child > i` with
# an explicit raise. Validating only `0 <= child < n` would let a
# self-referential LIST node pass, reach `nested_decoder._decode_list`, and
# recurse until the stack died. Do not delete that check on the strength of
# this paragraph — this paragraph is only correct BECAUSE of that check.
#
# Encapsulation: the public API exposes only typed values (OrcSchema, String,
# ArrowType, raised errors). No UnsafePointer crosses any module boundary.
# =============================================================================

from komira_core.arrow.arrow_types import ArrowType

from .footer import OrcRawType


# =============================================================================
# ORC Type.Kind enum (orc_proto.proto). 19 kinds.
# =============================================================================

comptime ORC_KIND_BOOLEAN: Int = 0
comptime ORC_KIND_BYTE: Int = 1
comptime ORC_KIND_SHORT: Int = 2
comptime ORC_KIND_INT: Int = 3
comptime ORC_KIND_LONG: Int = 4
comptime ORC_KIND_FLOAT: Int = 5
comptime ORC_KIND_DOUBLE: Int = 6
comptime ORC_KIND_STRING: Int = 7
comptime ORC_KIND_BINARY: Int = 8
comptime ORC_KIND_TIMESTAMP: Int = 9
comptime ORC_KIND_LIST: Int = 10
comptime ORC_KIND_MAP: Int = 11
comptime ORC_KIND_STRUCT: Int = 12
comptime ORC_KIND_UNION: Int = 13
comptime ORC_KIND_DECIMAL: Int = 14
comptime ORC_KIND_DATE: Int = 15
comptime ORC_KIND_VARCHAR: Int = 16
comptime ORC_KIND_CHAR: Int = 17
comptime ORC_KIND_TIMESTAMP_INSTANT: Int = 18


@always_inline
def _write_orc_kind_name[W: Writer](mut writer: W, kind: Int):
    """WRITE what `orc_kind_name` returns. ⚠ THIS WRITES; IT DOES NOT RETURN.

    The arms live here so no string constant is ever SELECTED and
    returned. A literal-returning ladder lowers to two parallel
    (pointer, length) constant arrays whose two call-site references
    an `--emit shared-lib` link binds INDEPENDENTLY; a shared library can
    bind such a pair CROSSED and crash the host process that loaded it."""
    if kind == ORC_KIND_BOOLEAN:
        writer.write(String("boolean"))
        return
    elif kind == ORC_KIND_BYTE:
        writer.write(String("tinyint"))
        return
    elif kind == ORC_KIND_SHORT:
        writer.write(String("smallint"))
        return
    elif kind == ORC_KIND_INT:
        writer.write(String("int"))
        return
    elif kind == ORC_KIND_LONG:
        writer.write(String("bigint"))
        return
    elif kind == ORC_KIND_FLOAT:
        writer.write(String("float"))
        return
    elif kind == ORC_KIND_DOUBLE:
        writer.write(String("double"))
        return
    elif kind == ORC_KIND_STRING:
        writer.write(String("string"))
        return
    elif kind == ORC_KIND_BINARY:
        writer.write(String("binary"))
        return
    elif kind == ORC_KIND_TIMESTAMP:
        writer.write(String("timestamp"))
        return
    elif kind == ORC_KIND_LIST:
        writer.write(String("array"))
        return
    elif kind == ORC_KIND_MAP:
        writer.write(String("map"))
        return
    elif kind == ORC_KIND_STRUCT:
        writer.write(String("struct"))
        return
    elif kind == ORC_KIND_UNION:
        writer.write(String("uniontype"))
        return
    elif kind == ORC_KIND_DECIMAL:
        writer.write(String("decimal"))
        return
    elif kind == ORC_KIND_DATE:
        writer.write(String("date"))
        return
    elif kind == ORC_KIND_VARCHAR:
        writer.write(String("varchar"))
        return
    elif kind == ORC_KIND_CHAR:
        writer.write(String("char"))
        return
    elif kind == ORC_KIND_TIMESTAMP_INSTANT:
        writer.write(String("timestamp with local time zone"))
        return
    writer.write(String("unknown"))
    return


@always_inline
def orc_kind_name(kind: Int) -> String:
    """Canonical Hive-notation type-name for an ORC Type.Kind.

    Compound types (struct/list/map/union/decimal/varchar/char) get their
    parameters appended by the canonical-form emitter; this returns the bare
    kind keyword.
    """
    var out = String()
    _write_orc_kind_name(out, kind)
    return out^


# =============================================================================
# OrcSchemaError tags.
# =============================================================================

comptime ORC_ERR_MALFORMED_PROTOBUF: Int = 0
comptime ORC_ERR_UNKNOWN_TYPE: Int = 1
comptime ORC_ERR_DECIMAL_PRECISION_TOO_LARGE: Int = 2
comptime ORC_ERR_EMPTY_SCHEMA: Int = 3
comptime ORC_ERR_BAD_CHILD_INDEX: Int = 4


# =============================================================================
# OrcSchema — the lifted ORC type tree.
#
# Storage IS the flat `List[OrcRawType]` from Footer.types (index 0 is the
# root). Children are integer indices into `nodes` (Type.subtypes). This is
# the same flat-arena, index-link shape as the Avro reader's node tree.
# =============================================================================


@fieldwise_init
struct OrcSchema(Copyable, Movable):
    """Parsed ORC type tree (Footer.types pre-order list). Frozen after build.
    """

    var nodes: List[OrcRawType]

    @staticmethod
    def from_types(types: List[OrcRawType]) raises -> OrcSchema:
        """Build an OrcSchema from a parsed `Footer.types` list.

        Validates that the list is non-empty and that every `subtypes` index is
        both IN RANGE and STRICTLY FORWARD (`child > i`).

        ⚠ THE FORWARD CHECK IS WHAT MAKES THE TREE FINITE.

        ORC's flat type list is "structurally finite (a flat list with
        FORWARD-ONLY index links per the protobuf encoding)" only for what a
        conforming WRITER emits, not for what arrives — and
        `decode_column_subtree` recurses on that claim.

        `types = [STRUCT{subtypes:[1]}, LIST{subtypes:[1]}]` passes an
        in-range-only validation, routes to the nested path via
        `_schema_needs_nested_path`, and then
        `_decode_list -> decode_column_subtree -> _decode_list` recurses until
        the stack dies — re-gathering and re-DECOMPRESSING every stream on each
        frame, so it is an amplification as well as a crash.

        Enforcing `child > i` here makes the recursion structurally
        terminating for every consumer, at ONE pass over the type list at parse
        time — strictly cheaper than a depth counter or a visited-set threaded
        through the recursive decoder, and it cannot be forgotten by a future
        recursive walker. The ORC spec does not permit cyclic types, so this
        rejects nothing a conforming writer can produce.
        """
        if len(types) == 0:
            raise Error("OrcSchemaError.EMPTY_SCHEMA: Footer.types is empty")
        var n = len(types)
        for i in range(n):
            var node = types[i].copy()
            for j in range(len(node.subtypes)):
                var child = node.subtypes[j]
                if child < 0 or child >= n:
                    raise Error(
                        String(
                            "OrcSchemaError.BAD_CHILD_INDEX: node "
                        )
                        + String(i)
                        + " references child "
                        + String(child)
                        + " out of range [0, "
                        + String(n)
                        + ")"
                    )
                if child <= i:
                    raise Error(
                        String("OrcSchemaError.CYCLIC_TYPE_TREE: node ")
                        + String(i)
                        + " references child "
                        + String(child)
                        + ", which is not strictly forward — ORC's type list is"
                        " a pre-order flat tree with forward-only links, and a"
                        " backward or self link makes the tree cyclic (an"
                        " unbounded recursive decode)"
                    )
        return OrcSchema(types.copy())

    @always_inline
    def node_count(self) -> Int:
        return len(self.nodes)

    @always_inline
    def root_kind(self) raises -> Int:
        if len(self.nodes) == 0:
            raise Error("OrcSchemaError.EMPTY_SCHEMA")
        return self.nodes[0].kind

    def node(self, idx: Int) raises -> OrcRawType:
        if idx < 0 or idx >= len(self.nodes):
            raise Error("OrcSchemaError.BAD_CHILD_INDEX")
        return self.nodes[idx].copy()

    # -------------------------------------------------------------------------
    # Canonical form — Hive TypeDescription notation, rooted at node 0.
    # -------------------------------------------------------------------------

    def canonical_form(self) raises -> String:
        """Produce the canonical Hive-notation type string for this schema.

        Examples:
          - `struct<l_orderkey:bigint,l_comment:string>`
          - `array<int>`
          - `map<string,bigint>`
          - `decimal(18,4)`
          - `uniontype<int,string>`
          - `varchar(40)` / `char(10)`

        Stable across re-parse (used for round-trip equality testing).
        """
        var out = String("")
        self._emit_canonical(0, out)
        return out^

    def _emit_canonical(self, idx: Int, mut out: String) raises:
        var n = self.nodes[idx].copy()
        var kind = n.kind

        if kind == ORC_KIND_STRUCT:
            out += "struct<"
            for i in range(len(n.subtypes)):
                if i > 0:
                    out += ","
                # Field name : child type. STRUCT always has parallel
                # field_names; defensively fall back if the writer omitted them.
                if i < len(n.field_names):
                    out += n.field_names[i]
                else:
                    out += "_col"
                    out += String(i)
                out += ":"
                self._emit_canonical(n.subtypes[i], out)
            out += ">"
            return

        if kind == ORC_KIND_LIST:
            out += "array<"
            if len(n.subtypes) >= 1:
                self._emit_canonical(n.subtypes[0], out)
            out += ">"
            return

        if kind == ORC_KIND_MAP:
            out += "map<"
            if len(n.subtypes) >= 2:
                self._emit_canonical(n.subtypes[0], out)
                out += ","
                self._emit_canonical(n.subtypes[1], out)
            out += ">"
            return

        if kind == ORC_KIND_UNION:
            out += "uniontype<"
            for i in range(len(n.subtypes)):
                if i > 0:
                    out += ","
                self._emit_canonical(n.subtypes[i], out)
            out += ">"
            return

        if kind == ORC_KIND_DECIMAL:
            out += "decimal("
            out += String(n.precision)
            out += ","
            out += String(n.scale)
            out += ")"
            return

        if kind == ORC_KIND_VARCHAR:
            out += "varchar("
            out += String(n.maximum_length)
            out += ")"
            return

        if kind == ORC_KIND_CHAR:
            out += "char("
            out += String(n.maximum_length)
            out += ")"
            return

        # All primitives: the bare kind keyword.
        out += orc_kind_name(kind)


# =============================================================================
# ORC -> Arrow type lattice.
#
# Returns the Arrow type for ONE node by index. Compound types map to their
# Arrow nested-type tag (the caller descends into children for child types).
# Lossless for every primitive + nested type this package supports.
#
# Epoch / encoding nuances (the decode-side rebase lives in the decoders):
#   - DATE       -> Date32 (days since the Unix epoch).
#   - TIMESTAMP  -> Timestamp[ns, tz=None]   (the wire epoch is 1 January 2015
#                   UTC; the decoder rebases).
#   - TIMESTAMP_INSTANT -> Timestamp[ns, "UTC"].
#   - DECIMAL    -> Decimal128(p, s) for p <= 38; reject p > 38 (ORC v1 cap).
#   - VARCHAR(N) / CHAR(N) -> Utf8 (the N constraint round-trips via Arrow
#                   Field metadata arrow.orc.varchar_max_length / char_length,
#                   stamped by orc_logical_arrow — this maps the base type only).
# =============================================================================

comptime ORC_DECIMAL_MAX_PRECISION: Int = 38


def orc_node_to_arrow(schema: OrcSchema, idx: Int) raises -> ArrowType:
    """Map ORC type-tree node `idx` to its Arrow logical type."""
    var n = schema.node(idx)
    var kind = n.kind

    if kind == ORC_KIND_BOOLEAN:
        return ArrowType.BOOL
    elif kind == ORC_KIND_BYTE:
        return ArrowType.INT8
    elif kind == ORC_KIND_SHORT:
        return ArrowType.INT16
    elif kind == ORC_KIND_INT:
        return ArrowType.INT32
    elif kind == ORC_KIND_LONG:
        return ArrowType.INT64
    elif kind == ORC_KIND_FLOAT:
        return ArrowType.FLOAT32
    elif kind == ORC_KIND_DOUBLE:
        return ArrowType.FLOAT64
    elif kind == ORC_KIND_STRING:
        return ArrowType.STRING
    elif kind == ORC_KIND_BINARY:
        return ArrowType.BINARY
    elif kind == ORC_KIND_TIMESTAMP:
        return ArrowType.TIMESTAMP_NS
    elif kind == ORC_KIND_TIMESTAMP_INSTANT:
        return ArrowType.TIMESTAMP_NS
    elif kind == ORC_KIND_DATE:
        return ArrowType.DATE32
    elif kind == ORC_KIND_VARCHAR:
        return ArrowType.STRING
    elif kind == ORC_KIND_CHAR:
        return ArrowType.STRING
    elif kind == ORC_KIND_DECIMAL:
        if n.precision > ORC_DECIMAL_MAX_PRECISION:
            raise Error(
                String(
                    "OrcSchemaError.DECIMAL_PRECISION_TOO_LARGE: precision "
                )
                + String(n.precision)
                + " exceeds ORC v1 cap of "
                + String(ORC_DECIMAL_MAX_PRECISION)
            )
        return ArrowType.DECIMAL128
    elif kind == ORC_KIND_STRUCT:
        return ArrowType.STRUCT
    elif kind == ORC_KIND_LIST:
        return ArrowType.LIST
    elif kind == ORC_KIND_MAP:
        return ArrowType.MAP
    elif kind == ORC_KIND_UNION:
        # ORC UNION is tagged-dense on the wire. Default Arrow mapping is
        # Dense Union; `arrow.orc.union_mode=sparse` flips it.
        return ArrowType.UNION_DENSE

    raise Error(
        String("OrcSchemaError.UNKNOWN_TYPE: ORC Type.Kind ")
        + String(kind)
        + " in orc_node_to_arrow"
    )
