# =============================================================================
# orc_logical_arrow.mojo — arrow.orc.* extension metadata + ACID schema
# detection.
# =============================================================================
#
# Two responsibilities, both at the schema layer (the value decode is in
# nested_decoder.mojo / column_decoder.mojo):
#
#   1. arrow.orc.* extension-metadata round-trip. ORC type attributes that
#      have no first-class Arrow type are preserved as Arrow Field metadata
#      under the `arrow.orc.*` key prefix. There are 10 keys:
#        varchar_max_length / char_length / union_mode / original_tz /
#        time_unit / duration_unit / interval_kind / fixed_size /
#        fixed_list_size / map_keys_sorted
#      The reader stamps the ones derivable from the ORC type tree:
#        - VARCHAR(N)  -> arrow.orc.varchar_max_length = N
#        - CHAR(N)     -> arrow.orc.char_length = N
#        - UNION       -> arrow.orc.union_mode = "dense" (default; "sparse" only
#                         if the writer stamped it — preserved on round-trip)
#        - MAP         -> arrow.orc.map_keys_sorted = "false" (ORC has no
#                         counterpart flag; preserved if a writer set it)
#      The other keys (time/duration/interval/fixed_size/original_tz) ride the
#      reverse (Arrow->ORC) mapping and are stamped by the writer; the reader
#      restores them from ORC type attributes once the writer emits them. The
#      KEYS are defined here so both directions share one source.
#
#   2. ACID schema detection + default-suppress. A Hive ACID file's root
#      STRUCT is EXACTLY [operation, originalTransaction, bucket, rowId,
#      currentTransaction, row] with `row` a STRUCT of the user's real columns.
#        - detect the 6-column ACID shape on Footer.types[0];
#        - by default SUPPRESS the 5 metadata columns + LIFT the `row.*` STRUCT
#          so the Arrow user sees only the inner data columns;
#        - `with_acid_columns=True` exposes all 6 columns (raw `bucket` Int32 —
#          the Hive BucketCodec packed layout is NOT decoded here).
#      The row.* lift MUST preserve per-leaf arrow.orc.* metadata (readers of
#      the lifted columns depend on it) — the lift is a structural reparent of
#      the `row` STRUCT's children to the top level, never a metadata strip.
#
# Encapsulation: pure typed-value transforms over OrcSchema / Field / String.
# No UnsafePointer, no pointer arithmetic.
# =============================================================================

from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.schema import Field

from .orc_schema import (
    OrcSchema,
    ORC_KIND_VARCHAR,
    ORC_KIND_CHAR,
    ORC_KIND_UNION,
    ORC_KIND_MAP,
    ORC_KIND_STRUCT,
)


# =============================================================================
# arrow.orc.* metadata key constants (single source for both directions).
# =============================================================================

comptime ARROW_ORC_VARCHAR_MAX_LENGTH: String = "arrow.orc.varchar_max_length"
comptime ARROW_ORC_CHAR_LENGTH: String = "arrow.orc.char_length"
comptime ARROW_ORC_UNION_MODE: String = "arrow.orc.union_mode"
comptime ARROW_ORC_ORIGINAL_TZ: String = "arrow.orc.original_tz"
comptime ARROW_ORC_TIME_UNIT: String = "arrow.orc.time_unit"
comptime ARROW_ORC_DURATION_UNIT: String = "arrow.orc.duration_unit"
comptime ARROW_ORC_INTERVAL_KIND: String = "arrow.orc.interval_kind"
comptime ARROW_ORC_FIXED_SIZE: String = "arrow.orc.fixed_size"
comptime ARROW_ORC_FIXED_LIST_SIZE: String = "arrow.orc.fixed_list_size"
comptime ARROW_ORC_MAP_KEYS_SORTED: String = "arrow.orc.map_keys_sorted"


# =============================================================================
# Stamp arrow.orc.* metadata onto an Arrow Field for one ORC schema node.
# =============================================================================


def stamp_arrow_orc_metadata(
    mut field: Field, schema: OrcSchema, node_idx: Int
) raises:
    """Stamp the arrow.orc.* extension metadata derivable from ORC type node
    `node_idx` onto `field`. Idempotent (set_metadata overwrites by key)."""
    var node = schema.node(node_idx)
    var kind = node.kind

    if kind == ORC_KIND_VARCHAR:
        field.set_metadata(
            ARROW_ORC_VARCHAR_MAX_LENGTH, String(node.maximum_length)
        )
    elif kind == ORC_KIND_CHAR:
        field.set_metadata(ARROW_ORC_CHAR_LENGTH, String(node.maximum_length))
    elif kind == ORC_KIND_UNION:
        # Default Arrow mapping of an ORC union is Dense. The reader records
        # the mode explicitly so a round-trip preserves it; a writer that
        # emitted `sparse` would have stamped that attribute.
        if not field.has_metadata(ARROW_ORC_UNION_MODE):
            field.set_metadata(ARROW_ORC_UNION_MODE, String("dense"))
    elif kind == ORC_KIND_MAP:
        if not field.has_metadata(ARROW_ORC_MAP_KEYS_SORTED):
            field.set_metadata(ARROW_ORC_MAP_KEYS_SORTED, String("false"))


# =============================================================================
# ACID schema detection.
# =============================================================================

comptime _ACID_OPERATION: Int = 0
comptime _ACID_ORIGINAL_TXN: Int = 1
comptime _ACID_BUCKET: Int = 2
comptime _ACID_ROW_ID: Int = 3
comptime _ACID_CURRENT_TXN: Int = 4
comptime _ACID_ROW: Int = 5


def is_acid_schema(schema: OrcSchema) raises -> Bool:
    """Detect the Hive ACID 6-column wrapper on the root STRUCT.

    The root must be a STRUCT whose first 6 field names are exactly
    [operation, originalTransaction, bucket, rowId, currentTransaction, row],
    with `row` a nested STRUCT (the user's data). The integer-typed metadata
    columns are checked by name only (Hive writers are consistent here)."""
    var root = schema.node(0)
    if root.kind != ORC_KIND_STRUCT:
        return False
    if len(root.subtypes) != 6 or len(root.field_names) != 6:
        return False
    if root.field_names[_ACID_OPERATION] != "operation":
        return False
    if root.field_names[_ACID_ORIGINAL_TXN] != "originalTransaction":
        return False
    if root.field_names[_ACID_BUCKET] != "bucket":
        return False
    if root.field_names[_ACID_ROW_ID] != "rowId":
        return False
    if root.field_names[_ACID_CURRENT_TXN] != "currentTransaction":
        return False
    if root.field_names[_ACID_ROW] != "row":
        return False
    # The `row` field must itself be a STRUCT (the user's data wrapper).
    var row_node = schema.node(root.subtypes[_ACID_ROW])
    if row_node.kind != ORC_KIND_STRUCT:
        return False
    return True


def acid_row_struct_index(schema: OrcSchema) raises -> Int:
    """Return the schema-tree index of the ACID `row` STRUCT (field 5)."""
    var root = schema.node(0)
    return root.subtypes[_ACID_ROW]


# =============================================================================
# ACID output-column plan: the list of (schema_node_idx, output_name) that the
# Arrow output should carry, honoring with_acid_columns.
# =============================================================================


@fieldwise_init
struct AcidOutputColumns(Copyable, Movable):
    """Resolved top-level output columns for an ACID file: parallel
    (schema-node-index, output-name) lists."""

    var node_idxs: List[Int]
    var names: List[String]


def acid_output_columns(
    schema: OrcSchema, with_acid_columns: Bool
) raises -> AcidOutputColumns:
    """Compute the top-level output columns for an ACID file.

    Default (with_acid_columns=False): LIFT the `row` STRUCT's children to the
    top level — the Arrow user sees only the inner data columns. The 5
    metadata columns (operation / originalTransaction / bucket / rowId /
    currentTransaction) are suppressed.

    Opt-in (with_acid_columns=True): expose ALL 6 ACID columns (operation,
    originalTransaction, bucket [raw Int32 — BucketCodec NOT decoded], rowId,
    currentTransaction, row [the full nested STRUCT]).

    The row.* lift is a pure structural reparent: each lifted child keeps its
    own schema node index, so per-leaf arrow.orc.* metadata (stamped from that
    index) is preserved (readers of the lifted columns depend on this)."""
    var root = schema.node(0)
    var idxs = List[Int]()
    var names = List[String]()

    if with_acid_columns:
        for i in range(len(root.subtypes)):
            idxs.append(root.subtypes[i])
            names.append(root.field_names[i])
        return AcidOutputColumns(idxs^, names^)

    # Default: lift the `row` STRUCT's direct children to the top level.
    var row_idx = root.subtypes[_ACID_ROW]
    var row_node = schema.node(row_idx)
    for i in range(len(row_node.subtypes)):
        idxs.append(row_node.subtypes[i])
        if i < len(row_node.field_names):
            names.append(row_node.field_names[i])
        else:
            names.append(String("_col") + String(i))
    return AcidOutputColumns(idxs^, names^)
