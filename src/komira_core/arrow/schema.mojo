# =============================================================================
# Schema, Field, SchemaBuilder — Arrow-compatible metadata
# =============================================================================
#
# RecordBatch and RecordBatchBuilder have been extracted to record_batch.mojo.
# This file re-exports them for backward compatibility.
# =============================================================================

from .arrow_types import (
    ArrowType,
    decimal_format_string,
    decimal256_format_string,
    timestamp_format_string,
    union_format_string,
)
from .column import Column
from .dictionary_array import StringDictionaryArray
from .primitive_array import PrimitiveArray
from .string_array import StringArray

# Re-export RecordBatch and RecordBatchBuilder for backward compatibility
from .record_batch import RecordBatch, RecordBatchBuilder
from komira_core.dtype_sentinel import DTYPE_NONE


# =============================================================================
# Field
# =============================================================================

struct Field(Movable, Copyable, Deinitable, Writable):
    """Describes a single column in a Schema: name, data type, nullability,
    optional key-value metadata, and optional child fields for nested types.

    Fields:
        name: The column name.
        arrow_type: The Arrow logical type of the column.
        dtype: The Mojo DType for numeric columns (backward compat).
        nullable: Whether the column can contain nulls.
        _metadata_keys: Key-value metadata keys.
        _metadata_values: Key-value metadata values.
        _child_names: Child field names (for nested types).
        _child_types: Child field ArrowType type_ids.
        _child_nullables: Child field nullability flags.
    """

    var name: String
    var arrow_type: ArrowType
    var dtype: DType
    var nullable: Bool
    # precision/scale for DECIMAL128
    # fields (the source of truth; mirrors Arrow's DataType::Decimal128(p,s)).
    # Zero for non-decimal fields.  Plain Int — Field is a value type.
    # The same slots also carry DECIMAL256 (p,s)
    # — the bit-width discriminator is the `arrow_type` field itself.
    var decimal_precision: Int
    var decimal_scale: Int
    # Parameter slots for parameterized Arrow
    # types.  All default to a "no-parameter" sentinel for backward compat:
    #   * `_tz`        — IANA timezone string for Timestamp* types ("" means
    #                    "no timezone" / "wall-clock-in-UTC display hint").
    #   * `_dict_index_type` — INT8/16/32/64 + UINT* for DICTIONARY columns
    #                    (defaults to INT32 per Arrow common convention).
    #   * `_union_type_ids` — per-child type-id buffer for UNION_SPARSE /
    #                    UNION_DENSE.  Empty list for non-union fields.
    var _tz: String
    var _dict_index_type: ArrowType
    var _union_type_ids: List[Int]
    # Generic flag bits for the
    # `CArrowSchema.flags` field.  Bit-OR of any of:
    #   * ARROW_FLAG_DICTIONARY_ORDERED (1)
    #   * ARROW_FLAG_NULLABLE          (2)  — also derivable from `nullable`
    #   * ARROW_FLAG_MAP_KEYS_SORTED   (4)
    # On import we cache the raw flag word; `nullable` is the
    # backward-compatible Bool view of bit 2.  On export the C-Data path
    # OR's the slot in.
    var _flags: Int64
    var _metadata_keys: List[String]
    var _metadata_values: List[String]
    var _child_names: List[String]
    var _child_types: List[UInt8]
    var _child_nullables: List[Bool]

    def __init__(out self, name: String, arrow_type: ArrowType, nullable: Bool):
        """Create a Field with an ArrowType (preferred constructor)."""
        self.name = name
        self.arrow_type = arrow_type
        self.nullable = nullable
        self.decimal_precision = 0
        self.decimal_scale = 0
        self._tz = String("")
        self._dict_index_type = ArrowType.INT32
        self._union_type_ids = List[Int]()
        self._flags = Int64(0)
        self._metadata_keys = List[String]()
        self._metadata_values = List[String]()
        self._child_names = List[String]()
        self._child_types = List[UInt8]()
        self._child_nullables = List[Bool]()
        # Derive DType for numeric types (backward compat)
        if arrow_type == ArrowType.BOOL:
            self.dtype = DType.bool
        elif arrow_type == ArrowType.INT8:
            self.dtype = DType.int8
        elif arrow_type == ArrowType.INT16:
            self.dtype = DType.int16
        elif arrow_type == ArrowType.INT32:
            self.dtype = DType.int32
        elif arrow_type == ArrowType.INT64:
            self.dtype = DType.int64
        elif arrow_type == ArrowType.UINT8:
            self.dtype = DType.uint8
        elif arrow_type == ArrowType.UINT16:
            self.dtype = DType.uint16
        elif arrow_type == ArrowType.UINT32:
            self.dtype = DType.uint32
        elif arrow_type == ArrowType.UINT64:
            self.dtype = DType.uint64
        elif arrow_type == ArrowType.FLOAT16:
            self.dtype = DType.float16
        elif arrow_type == ArrowType.FLOAT32:
            self.dtype = DType.float32
        elif arrow_type == ArrowType.FLOAT64:
            self.dtype = DType.float64
        elif arrow_type.is_timestamp():
            self.dtype = DType.int64
        else:
            self.dtype = DTYPE_NONE

    def __init__(out self, name: String, dtype: DType, nullable: Bool):
        """Create a Field from a Mojo DType (backward-compatible constructor)."""
        self.name = name
        self.dtype = dtype
        self.nullable = nullable
        self.arrow_type = ArrowType.from_dtype(dtype)
        self.decimal_precision = 0
        self.decimal_scale = 0
        self._tz = String("")
        self._dict_index_type = ArrowType.INT32
        self._union_type_ids = List[Int]()
        self._flags = Int64(0)
        self._metadata_keys = List[String]()
        self._metadata_values = List[String]()
        self._child_names = List[String]()
        self._child_types = List[UInt8]()
        self._child_nullables = List[Bool]()

    @staticmethod
    def decimal128(name: String, precision: Int, scale: Int, nullable: Bool) raises -> Field:
        """Create a DECIMAL128 Field with the given precision and scale.

        Enforces 0 <= scale <= precision <= 38 (negative-scale decimals are
        not supported — matches DuckDB; raises otherwise).
        """
        if precision < 1 or precision > 38:
            raise Error("Field.decimal128: precision must be in [1, 38], got " + String(precision))
        if scale < 0 or scale > precision:
            raise Error("Field.decimal128: scale must be in [0, precision], got " + String(scale))
        var f = Field(name, ArrowType.DECIMAL128, nullable)
        f.decimal_precision = precision
        f.decimal_scale = scale
        return f^

    @staticmethod
    def list_of_string(name: String, nullable: Bool, item_nullable: Bool = True) -> Field:
        """Create a LIST<STRING> Field (`arrow_type == ArrowType.LIST` with a
        single STRING child named "item").  The
        result-field shape for `regexp_match` / `regexp_split_to_array` /
        `regexp_extract_all`.

        ⭐ NOW A THIN FORWARD to `Field.list_of` (below), which is the same
        two statements with the item type as a parameter.  Kept as its own
        name because three `expr_walk` arms and the plan-wire golden-bytes
        test spell it, and because STRING is the only item type any producer
        in the tree emits today."""
        return Field.list_of(name, ArrowType.STRING, nullable, item_nullable)

    @staticmethod
    def list_of(
        name: String,
        item_type: ArrowType,
        nullable: Bool,
        item_nullable: Bool = True,
    ) -> Field:
        """Create a LIST<`item_type`> Field — one child named "item".

         The generalization of `list_of_string`
        past Utf8, and the SCHEMA half of the list-cell constructor that
        `_R_LISTCTOR` (`komira_sdk/sql_fn_table.mojo`) names as the missing
        primitive for its 16 refused names (`list_value`, `list_concat`,
        `flatten`, `range`, …).  The Arrow half already exists and is already
        generic: `ListArray.to_column` carries an arbitrary child `Column`
, and `ListArray.from_int_lists` already builds LIST<Int64>.

        ⛔ THIS FUNCTION IS NON-RAISING, AND THAT IS A HARD CONSTRAINT, NOT A
        STYLE CHOICE — the same one stated on `expr_walk.walk_expr_field`,
        which is where a list-producing expression's output Field is
        inferred and which CANNOT raise because `LogicalPlan.project` and
        `.aggregate` are non-raising constructors that synthesize their
        `output_schema` through it.  So this constructor is TOTAL: it builds
        the Field it was asked for and refuses nothing.

        ⚠⚠ WHICH MEANS THE LOSS CHECK CANNOT LIVE HERE.  `Field`'s children
        are THREE PARALLEL FLAT LISTS carrying exactly
        `(name, type_id, nullable)` — `_child_names` / `_child_types` /
        `_child_nullables` — so an item type needing ANY other Field slot has
        nowhere to put it and is silently degraded by this call:
        DECIMAL128/256 lose `(precision, scale)` and become (0, 0);
        TIMESTAMP* lose `_tz` and become naive; DICTIONARY loses
        `_dict_index_type`; UNION_* lose `_union_type_ids`; and any nested
        item (LIST / STRUCT / MAP / …) loses its OWN children entirely.
        Every one of those is a plausible-looking Field carrying a wrong
        type.  ⇒ CALLERS IN A RAISING CONTEXT — a binder, above all — MUST
        gate on `Field.list_item_type_is_lossless` FIRST and refuse by name.
        """
        var f = Field(name, ArrowType.LIST, nullable)
        f.add_child("item", item_type, item_nullable)
        return f^

    @staticmethod
    def list_item_type_is_lossless(item_type: ArrowType) -> Bool:
        """True iff `Field.list_of(..., item_type, ...)` loses NOTHING.

         The companion gate for `list_of` above:
        an item type is lossless iff `(name, type_id, nullable)` — all the
        three flat child lists carry — is its COMPLETE description.

        ⭐ THIS IS AN ALLOW-LIST ON PURPOSE, AND THE POLARITY IS THE WHOLE
        POINT.  As a deny-list, every `ArrowType` added after today would
        default to LOSSLESS and be served silently with its parameters
        dropped — the fail-OPEN direction.  As an allow-list a new slot
        defaults to REFUSED, and somebody has to come back here and say why
        it is safe.  A new parameter-bearing type is exactly the case that
        would otherwise slip through.

        REFUSED, each because it needs a Field slot the child lists lack:
        TIMESTAMP* (`_tz`), DECIMAL128/256 (`decimal_precision`/`_scale`),
        DICTIONARY (`_dict_index_type`), UNION_SPARSE/DENSE
        (`_union_type_ids`), FIXED_SIZE_BINARY (byte width), and every
        nested type — LIST, LARGE_LIST, FIXED_SIZE_LIST, *_VIEW, STRUCT,
        MAP — which needs children of its own.  ⚠ TIMESTAMP* is the one that
        looks safe and is not: a naive timestamp and a tz-bearing one have
        the SAME type id and differ only in `_tz`, so admitting the family
        would answer a tz-bearing LIST as a naive one with no diagnostic.
        """
        if item_type == ArrowType.NULL:
            return True
        if item_type == ArrowType.BOOL:
            return True
        if item_type.is_integer():
            return True
        if item_type.is_floating():
            return True
        if item_type == ArrowType.STRING or item_type == ArrowType.LARGE_STRING:
            return True
        if item_type == ArrowType.BINARY or item_type == ArrowType.LARGE_BINARY:
            return True
        if item_type == ArrowType.DATE32 or item_type == ArrowType.DATE64:
            return True
        if item_type.is_time():
            return True
        if item_type.is_duration():
            return True
        if item_type.is_interval():
            return True
        return False

    @staticmethod
    def decimal256(name: String, precision: Int, scale: Int, nullable: Bool) raises -> Field:
        """Create a DECIMAL256 Field with the given precision and scale.

        Enforces 1 <= precision <= 76 and 0 <= scale <= precision (Arrow spec
        bounds for 256-bit decimal).

        """
        if precision < 1 or precision > 76:
            raise Error("Field.decimal256: precision must be in [1, 76], got " + String(precision))
        if scale < 0 or scale > precision:
            raise Error("Field.decimal256: scale must be in [0, precision], got " + String(scale))
        var f = Field(name, ArrowType.DECIMAL256, nullable)
        f.decimal_precision = precision
        f.decimal_scale = scale
        return f^

    @staticmethod
    def timestamp(name: String, arrow_type: ArrowType, timezone: String, nullable: Bool) raises -> Field:
        """Create a TIMESTAMP_* Field with the given timezone.

        `arrow_type` must be one of TIMESTAMP / TIMESTAMP_S / TIMESTAMP_MS /
        TIMESTAMP_US / TIMESTAMP_NS.  `timezone` is an IANA timezone string
        (e.g. "UTC", "America/Los_Angeles"); empty string means naive (no tz).

        """
        if not arrow_type.is_timestamp():
            raise Error("Field.timestamp: arrow_type must be a Timestamp* slot, got " + String(arrow_type))
        var f = Field(name, arrow_type, nullable)
        f._tz = timezone
        return f^

    @staticmethod
    def union(name: String, mode: ArrowType, type_ids: List[Int], nullable: Bool) raises -> Field:
        """Create a UNION_SPARSE / UNION_DENSE Field with the given child
        type-id list.  (Tier-1 round-trip only).
        """
        if mode != ArrowType.UNION_SPARSE and mode != ArrowType.UNION_DENSE:
            raise Error("Field.union: mode must be UNION_SPARSE or UNION_DENSE, got " + String(mode))
        var f = Field(name, mode, nullable)
        f._union_type_ids = type_ids.copy()
        return f^

    @staticmethod
    def dictionary(name: String, index_type: ArrowType, nullable: Bool) raises -> Field:
        """Create a DICTIONARY Field with the given index type.

        `index_type` must be a signed integer type (INT8/16/32/64) per Arrow
        spec.  Value type is carried via the (single) Field child.

        """
        if (
            index_type != ArrowType.INT8
            and index_type != ArrowType.INT16
            and index_type != ArrowType.INT32
            and index_type != ArrowType.INT64
        ):
            raise Error(
                "Field.dictionary: index_type must be INT8/16/32/64, got " + String(index_type)
            )
        var f = Field(name, ArrowType.DICTIONARY, nullable)
        f._dict_index_type = index_type
        return f^

    # --- Parameter accessors ---

    def timezone(self) -> String:
        """Timezone string for TIMESTAMP* fields (empty if naive / non-ts)."""
        return self._tz

    def dict_index_type(self) -> ArrowType:
        """Index ArrowType for a DICTIONARY field (defaults to INT32)."""
        return self._dict_index_type

    def union_type_ids(self) -> List[Int]:
        """Per-child type-id list for UNION_* fields (empty for non-union)."""
        return self._union_type_ids.copy()

    def flags(self) -> Int64:
        """Raw Arrow C Data Interface flag bitfield.

        The export path OR's this against
        `ARROW_FLAG_NULLABLE` (derived from `self.nullable`) when emitting.
        Bit-OR of any of:
            * ARROW_FLAG_DICTIONARY_ORDERED (1)
            * ARROW_FLAG_NULLABLE          (2)
            * ARROW_FLAG_MAP_KEYS_SORTED   (4)
        Defaults to 0 for newly-built Fields; only set by the C-Data import
        path or by an explicit `set_flag` call.
        """
        return self._flags

    def set_flag(mut self, flag: Int64, value: Bool):
        """Set or clear a flag bit on this Field's `_flags` slot.

        Currently used to toggle `ARROW_FLAG_DICTIONARY_ORDERED` and
        `ARROW_FLAG_MAP_KEYS_SORTED` (both pass-through).

        """
        if value:
            self._flags = self._flags | flag
        else:
            self._flags = self._flags & (~flag)

    def is_dictionary_ordered(self) -> Bool:
        """Convenience: True iff ARROW_FLAG_DICTIONARY_ORDERED (1) is set."""
        return (self._flags & Int64(1)) != 0

    def are_map_keys_sorted(self) -> Bool:
        """Convenience: True iff ARROW_FLAG_MAP_KEYS_SORTED (4) is set."""
        return (self._flags & Int64(4)) != 0

    def format_string(self) -> String:
        """Return the parameterized Arrow C Data Interface format string for
        this Field, consulting its parameter slots.

        Inverse of `parse_format_string` + the param-extractor helpers.
        Round-trip property: `parse_format_string(f.format_string())` ==
        `f.arrow_type`; `extract_*_params(f.format_string())` reproduces
        the Field's parameter slots.
        """
        var t = self.arrow_type
        if t == ArrowType.DECIMAL128:
            var p = self.decimal_precision if self.decimal_precision >= 1 else 38
            var s = self.decimal_scale if (self.decimal_scale >= 0 and self.decimal_scale <= p) else 0
            return decimal_format_string(p, s)
        elif t == ArrowType.DECIMAL256:
            var p = self.decimal_precision if self.decimal_precision >= 1 else 76
            var s = self.decimal_scale if (self.decimal_scale >= 0 and self.decimal_scale <= p) else 0
            return decimal256_format_string(p, s)
        elif t.is_timestamp():
            # Pick the unit char from the slot; suffix the tz (may be empty).
            var unit: String
            if t == ArrowType.TIMESTAMP_S:
                unit = "s"
            elif t == ArrowType.TIMESTAMP_MS:
                unit = "m"
            elif t == ArrowType.TIMESTAMP_NS:
                unit = "n"
            else:
                # TIMESTAMP (legacy alias) and TIMESTAMP_US both emit "tsu:".
                unit = "u"
            return timestamp_format_string(unit, self._tz)
        elif t == ArrowType.UNION_SPARSE or t == ArrowType.UNION_DENSE:
            return union_format_string(t, self._union_type_ids)
        elif t == ArrowType.DICTIONARY:
            # The parent schema emits the INDEX format string; the value
            # type lives on the (separately-attached) dictionary schema.
            # `_dict_index_type` defaults to INT32 for fields constructed
            # via the plain ctor — this matches PyArrow's default index.
            return self._dict_index_type.format_string()
        else:
            return t.format_string()

    # --- Per-field metadata ---

    def set_metadata(mut self, key: String, value: String):
        for i in range(len(self._metadata_keys)):
            if self._metadata_keys[i] == key:
                self._metadata_values[i] = value
                return
        self._metadata_keys.append(key)
        self._metadata_values.append(value)

    def get_metadata(self, key: String) -> Optional[String]:
        for i in range(len(self._metadata_keys)):
            if self._metadata_keys[i] == key:
                return self._metadata_values[i]
        return None

    def has_metadata(self, key: String) -> Bool:
        for i in range(len(self._metadata_keys)):
            if self._metadata_keys[i] == key:
                return True
        return False

    def metadata_count(self) -> Int:
        return len(self._metadata_keys)

    # --- Nested field children ---

    def add_child(mut self, name: String, arrow_type: ArrowType, nullable: Bool):
        self._child_names.append(name)
        self._child_types.append(arrow_type.type_id)
        self._child_nullables.append(nullable)

    def num_children(self) -> Int:
        return len(self._child_names)

    def child_name(self, index: Int) -> String:
        return self._child_names[index]

    def child_arrow_type(self, index: Int) -> ArrowType:
        return ArrowType(self._child_types[index])

    def child_nullable(self, index: Int) -> Bool:
        return self._child_nullables[index]

    def write_to[W: Writer](self, mut writer: W):
        writer.write("Field(name='", self.name, "', type=")
        writer.write(String(self.arrow_type))
        if self.nullable:
            writer.write(", nullable")
        else:
            writer.write(", non-null")
        if len(self._child_names) > 0:
            writer.write(", children=[")
            for i in range(len(self._child_names)):
                if i > 0:
                    writer.write(", ")
                writer.write(
                    "Field(name='",
                    self._child_names[i],
                    "', type=",
                    String(ArrowType(self._child_types[i])),
                )
                if self._child_nullables[i]:
                    writer.write(", nullable")
                else:
                    writer.write(", non-null")
                writer.write(")")
            writer.write("]")
        if len(self._metadata_keys) > 0:
            writer.write(", metadata={")
            for i in range(len(self._metadata_keys)):
                if i > 0:
                    writer.write(", ")
                writer.write("'", self._metadata_keys[i], "': '")
                writer.write(self._metadata_values[i], "'")
            writer.write("}")
        writer.write(")")


# =============================================================================
# SchemaBuilder — flexible schema construction without fixed arity
# =============================================================================

struct SchemaBuilder(Movable):
    """Incrementally builds a Schema by adding fields one at a time."""

    var _names: List[String]
    var _arrow_types: List[UInt8]
    var _dtypes: List[DType]
    var _nullables: List[Bool]
    # DECIMAL128-CORRECTNESS: per-field decimal precision/scale (0 = not a
    # decimal field).  Also carries DECIMAL256 (p,s) per Phase B.
    var _dec_precisions: List[UInt8]
    var _dec_scales: List[Int8]
    # Per-field parameter slots for Timestamp
    # tz, Dictionary index type, and Union type-ids.  Parallel lists; same
    # length as `_names`.  Defaults are "no-parameter": empty tz, INT32 dict
    # index, empty union type-ids.
    var _field_tzs: List[String]
    var _field_dict_index_types: List[UInt8]
    var _field_union_type_ids: List[List[Int]]
    # Parallel list of raw flag bitfields per
    # field.  See `Field._flags` for the bit definitions.  Defaults to 0.
    var _field_flags: List[Int64]
    # Per-Field kv-metadata.  Two parallel
    # List[List[String]] of the same length as `_names`; an empty inner
    # list means "no metadata on this field".  These are distinct from the
    # schema-level `_metadata_keys/_values` (which live on Schema itself,
    # not per-Field), and feed the `CArrowSchema.metadata` slot on export.
    var _field_metadata_keys: List[List[String]]
    var _field_metadata_values: List[List[String]]
    # Per-field
    # child descriptors for nested types (STRUCT). Parallel to `_names`
    # — populated from the source Field's `_child_*` slots by `add_field`,
    # round-tripped into the built Schema's parallel slots, and consumed
    # by `Schema.field_at` to reconstruct a Field carrying its children.
    var _field_child_names: List[List[String]]
    var _field_child_types: List[List[UInt8]]
    var _field_child_nullables: List[List[Bool]]

    def __init__(out self):
        self._names = List[String]()
        self._arrow_types = List[UInt8]()
        self._dtypes = List[DType]()
        self._nullables = List[Bool]()
        self._dec_precisions = List[UInt8]()
        self._dec_scales = List[Int8]()
        self._field_tzs = List[String]()
        self._field_dict_index_types = List[UInt8]()
        self._field_union_type_ids = List[List[Int]]()
        self._field_flags = List[Int64]()
        self._field_metadata_keys = List[List[String]]()
        self._field_metadata_values = List[List[String]]()
        self._field_child_names = List[List[String]]()
        self._field_child_types = List[List[UInt8]]()
        self._field_child_nullables = List[List[Bool]]()

    def add_field(mut self, field: Field):
        self._names.append(field.name)
        self._arrow_types.append(field.arrow_type.type_id)
        self._dtypes.append(field.dtype)
        self._nullables.append(field.nullable)
        self._dec_precisions.append(UInt8(field.decimal_precision))
        self._dec_scales.append(Int8(field.decimal_scale))
        self._field_tzs.append(field._tz)
        self._field_dict_index_types.append(field._dict_index_type.type_id)
        self._field_union_type_ids.append(field._union_type_ids.copy())
        self._field_flags.append(field._flags)
        # Capture per-field metadata.
        self._field_metadata_keys.append(field._metadata_keys.copy())
        self._field_metadata_values.append(field._metadata_values.copy())
        # Phase X1a: capture per-field nested-children.
        self._field_child_names.append(field._child_names.copy())
        self._field_child_types.append(field._child_types.copy())
        self._field_child_nullables.append(field._child_nullables.copy())

    def build(mut self) -> Schema:
        """Build a Schema from accumulated fields. Uses swap-then-move to
        avoid "destroyed out of the middle" issues with `var self`.

        After this call, self is left with empty lists (valid for destructor).
        Cold path only -- called once per query plan node.
        """
        var names = self._names^
        self._names = List[String]()
        var arrow_types = self._arrow_types^
        self._arrow_types = List[UInt8]()
        var dtypes = self._dtypes^
        self._dtypes = List[DType]()
        var nullables = self._nullables^
        self._nullables = List[Bool]()
        var dec_p = self._dec_precisions^
        self._dec_precisions = List[UInt8]()
        var dec_s = self._dec_scales^
        self._dec_scales = List[Int8]()
        var tzs = self._field_tzs^
        self._field_tzs = List[String]()
        var dict_idx = self._field_dict_index_types^
        self._field_dict_index_types = List[UInt8]()
        var uts = self._field_union_type_ids^
        self._field_union_type_ids = List[List[Int]]()
        var flags = self._field_flags^
        self._field_flags = List[Int64]()
        var fm_keys = self._field_metadata_keys^
        self._field_metadata_keys = List[List[String]]()
        var fm_values = self._field_metadata_values^
        self._field_metadata_values = List[List[String]]()
        var ch_names = self._field_child_names^
        self._field_child_names = List[List[String]]()
        var ch_types = self._field_child_types^
        self._field_child_types = List[List[UInt8]]()
        var ch_nulls = self._field_child_nullables^
        self._field_child_nullables = List[List[Bool]]()
        return Schema(
            names^, arrow_types^, dtypes^, nullables^, dec_p^, dec_s^,
            tzs^, dict_idx^, uts^, flags^, fm_keys^, fm_values^,
            ch_names^, ch_types^, ch_nulls^,
        )


# =============================================================================
# Schema
# =============================================================================

struct Schema(Movable, Copyable, Deinitable, Writable):
    """An ordered list of Fields that describes the structure of a RecordBatch.

    Backed by List[T] for each field attribute. No UnsafePointer management
    required -- Lists handle allocation and destruction automatically. This
    is safe because Schema is a cold-path structure (created once per query
    plan node, not per row).
    """

    var _names: List[String]
    var _arrow_types: List[UInt8]
    var _dtypes: List[DType]
    var _nullables: List[Bool]
    # DECIMAL128-CORRECTNESS: per-field decimal (precision, scale).  Always
    # the same length as `_names` (zero-filled for non-decimal fields).
    # Also carries DECIMAL256 (p,s) per Phase B.
    var _dec_precisions: List[UInt8]
    var _dec_scales: List[Int8]
    # Parameter slots for Timestamp tz,
    # Dictionary index type, and Union type-ids.  Parallel lists; same length
    # as `_names`.  Defaults are "no-parameter": empty tz, INT32 dict index,
    # empty union type-ids.
    var _field_tzs: List[String]
    var _field_dict_index_types: List[UInt8]
    var _field_union_type_ids: List[List[Int]]
    # Parallel list of `CArrowSchema.flags`
    # bit-OR'd state per field.  Zero for fields without explicit flag bits
    # (the export path always OR's `ARROW_FLAG_NULLABLE` from `nullable`).
    var _field_flags: List[Int64]
    # Parallel list of per-Field metadata
    # kv-lists.  Each entry is a List[String] of keys and a parallel
    # List[String] of values for ONE field; the outer lists are the same
    # length as `_names`.  Distinct from Schema-level
    # `_metadata_keys/_values` (which describe the table as a whole, not
    # individual columns).
    var _field_metadata_keys: List[List[String]]
    var _field_metadata_values: List[List[String]]
    # Per-field child
    # descriptors for nested types (STRUCT today; future MAP/LIST/UNION on
    # the same shape). Parallel to `_names` — each entry is a parallel list
    # of (child_name, child_arrow_type_id, child_nullable). Empty entries
    # for non-nested fields. Populated by `SchemaBuilder.add_field` from
    # the source Field's `_child_*` slots. Consumed by `Schema.field_at`
    # to round-trip the children back into the reconstructed Field.
    var _field_child_names: List[List[String]]
    var _field_child_types: List[List[UInt8]]
    var _field_child_nullables: List[List[Bool]]
    var _metadata_keys: List[String]
    var _metadata_values: List[String]

    def __init__(out self):
        self._names = List[String]()
        self._arrow_types = List[UInt8]()
        self._dtypes = List[DType]()
        self._nullables = List[Bool]()
        self._dec_precisions = List[UInt8]()
        self._dec_scales = List[Int8]()
        self._field_tzs = List[String]()
        self._field_dict_index_types = List[UInt8]()
        self._field_union_type_ids = List[List[Int]]()
        self._field_flags = List[Int64]()
        self._field_metadata_keys = List[List[String]]()
        self._field_metadata_values = List[List[String]]()
        self._field_child_names = List[List[String]]()
        self._field_child_types = List[List[UInt8]]()
        self._field_child_nullables = List[List[Bool]]()
        self._metadata_keys = List[String]()
        self._metadata_values = List[String]()

    def __init__(
        out self,
        var names: List[String],
        var arrow_types: List[UInt8],
        var dtypes: List[DType],
        var nullables: List[Bool],
    ):
        """Construct a Schema from pre-built Lists.  Backward-compatible
        constructor — no decimal metadata or Phase B/C params (zero-fills)."""
        var n = len(names)
        self._names = names^
        self._arrow_types = arrow_types^
        self._dtypes = dtypes^
        self._nullables = nullables^
        self._dec_precisions = List[UInt8]()
        self._dec_scales = List[Int8]()
        self._field_tzs = List[String]()
        self._field_dict_index_types = List[UInt8]()
        self._field_union_type_ids = List[List[Int]]()
        self._field_flags = List[Int64]()
        self._field_metadata_keys = List[List[String]]()
        self._field_metadata_values = List[List[String]]()
        self._field_child_names = List[List[String]]()
        self._field_child_types = List[List[UInt8]]()
        self._field_child_nullables = List[List[Bool]]()
        for _ in range(n):
            self._dec_precisions.append(UInt8(0))
            self._dec_scales.append(Int8(0))
            self._field_tzs.append(String(""))
            self._field_dict_index_types.append(ArrowType.INT32.type_id)
            self._field_union_type_ids.append(List[Int]())
            self._field_flags.append(Int64(0))
            self._field_metadata_keys.append(List[String]())
            self._field_metadata_values.append(List[String]())
            self._field_child_names.append(List[String]())
            self._field_child_types.append(List[UInt8]())
            self._field_child_nullables.append(List[Bool]())
        self._metadata_keys = List[String]()
        self._metadata_values = List[String]()

    def __init__(
        out self,
        var names: List[String],
        var arrow_types: List[UInt8],
        var dtypes: List[DType],
        var nullables: List[Bool],
        var dec_precisions: List[UInt8],
        var dec_scales: List[Int8],
    ):
        """Construct a Schema from pre-built Lists incl. decimal (p,s).
        Backward-compatible (no Phase B/C params — zero-fills them)."""
        var n = len(names)
        self._names = names^
        self._arrow_types = arrow_types^
        self._dtypes = dtypes^
        self._nullables = nullables^
        self._dec_precisions = dec_precisions^
        self._dec_scales = dec_scales^
        self._field_tzs = List[String]()
        self._field_dict_index_types = List[UInt8]()
        self._field_union_type_ids = List[List[Int]]()
        self._field_flags = List[Int64]()
        self._field_metadata_keys = List[List[String]]()
        self._field_metadata_values = List[List[String]]()
        self._field_child_names = List[List[String]]()
        self._field_child_types = List[List[UInt8]]()
        self._field_child_nullables = List[List[Bool]]()
        for _ in range(n):
            self._field_tzs.append(String(""))
            self._field_dict_index_types.append(ArrowType.INT32.type_id)
            self._field_union_type_ids.append(List[Int]())
            self._field_flags.append(Int64(0))
            self._field_metadata_keys.append(List[String]())
            self._field_metadata_values.append(List[String]())
            self._field_child_names.append(List[String]())
            self._field_child_types.append(List[UInt8]())
            self._field_child_nullables.append(List[Bool]())
        self._metadata_keys = List[String]()
        self._metadata_values = List[String]()

    def __init__(
        out self,
        var names: List[String],
        var arrow_types: List[UInt8],
        var dtypes: List[DType],
        var nullables: List[Bool],
        var dec_precisions: List[UInt8],
        var dec_scales: List[Int8],
        var field_tzs: List[String],
        var field_dict_index_types: List[UInt8],
        var field_union_type_ids: List[List[Int]],
    ):
        """Construct a Schema from pre-built Lists including full Phase B
        parameter slots.  Backward-compatible (no Phase C flags/per-field
        metadata — zero-fills)."""
        var n = len(names)
        self._names = names^
        self._arrow_types = arrow_types^
        self._dtypes = dtypes^
        self._nullables = nullables^
        self._dec_precisions = dec_precisions^
        self._dec_scales = dec_scales^
        self._field_tzs = field_tzs^
        self._field_dict_index_types = field_dict_index_types^
        self._field_union_type_ids = field_union_type_ids^
        self._field_flags = List[Int64]()
        self._field_metadata_keys = List[List[String]]()
        self._field_metadata_values = List[List[String]]()
        self._field_child_names = List[List[String]]()
        self._field_child_types = List[List[UInt8]]()
        self._field_child_nullables = List[List[Bool]]()
        for _ in range(n):
            self._field_flags.append(Int64(0))
            self._field_metadata_keys.append(List[String]())
            self._field_metadata_values.append(List[String]())
            self._field_child_names.append(List[String]())
            self._field_child_types.append(List[UInt8]())
            self._field_child_nullables.append(List[Bool]())
        self._metadata_keys = List[String]()
        self._metadata_values = List[String]()

    def __init__(
        out self,
        var names: List[String],
        var arrow_types: List[UInt8],
        var dtypes: List[DType],
        var nullables: List[Bool],
        var dec_precisions: List[UInt8],
        var dec_scales: List[Int8],
        var field_tzs: List[String],
        var field_dict_index_types: List[UInt8],
        var field_union_type_ids: List[List[Int]],
        var field_flags: List[Int64],
    ):
        """Construct a Schema from pre-built Lists including raw flag
        bitfields.  Backward-compatible (no per-field metadata — zero-fills)."""
        var n = len(names)
        self._names = names^
        self._arrow_types = arrow_types^
        self._dtypes = dtypes^
        self._nullables = nullables^
        self._dec_precisions = dec_precisions^
        self._dec_scales = dec_scales^
        self._field_tzs = field_tzs^
        self._field_dict_index_types = field_dict_index_types^
        self._field_union_type_ids = field_union_type_ids^
        self._field_flags = field_flags^
        self._field_metadata_keys = List[List[String]]()
        self._field_metadata_values = List[List[String]]()
        self._field_child_names = List[List[String]]()
        self._field_child_types = List[List[UInt8]]()
        self._field_child_nullables = List[List[Bool]]()
        for _ in range(n):
            self._field_metadata_keys.append(List[String]())
            self._field_metadata_values.append(List[String]())
            self._field_child_names.append(List[String]())
            self._field_child_types.append(List[UInt8]())
            self._field_child_nullables.append(List[Bool]())
        self._metadata_keys = List[String]()
        self._metadata_values = List[String]()

    def __init__(
        out self,
        var names: List[String],
        var arrow_types: List[UInt8],
        var dtypes: List[DType],
        var nullables: List[Bool],
        var dec_precisions: List[UInt8],
        var dec_scales: List[Int8],
        var field_tzs: List[String],
        var field_dict_index_types: List[UInt8],
        var field_union_type_ids: List[List[Int]],
        var field_flags: List[Int64],
        var field_metadata_keys: List[List[String]],
        var field_metadata_values: List[List[String]],
    ):
        """Construct a Schema from pre-built Lists including full Phase B + C
        parameter slots (incl. raw flag bitfields AND per-field kv-metadata).
        Used by `SchemaBuilder.build`.  """
        self._names = names^
        self._arrow_types = arrow_types^
        self._dtypes = dtypes^
        self._nullables = nullables^
        self._dec_precisions = dec_precisions^
        self._dec_scales = dec_scales^
        self._field_tzs = field_tzs^
        self._field_dict_index_types = field_dict_index_types^
        self._field_union_type_ids = field_union_type_ids^
        self._field_flags = field_flags^
        self._field_metadata_keys = field_metadata_keys^
        self._field_metadata_values = field_metadata_values^
        self._field_child_names = List[List[String]]()
        self._field_child_types = List[List[UInt8]]()
        self._field_child_nullables = List[List[Bool]]()
        var n = len(self._names)
        for _ in range(n):
            self._field_child_names.append(List[String]())
            self._field_child_types.append(List[UInt8]())
            self._field_child_nullables.append(List[Bool]())
        self._metadata_keys = List[String]()
        self._metadata_values = List[String]()

    def __init__(
        out self,
        var names: List[String],
        var arrow_types: List[UInt8],
        var dtypes: List[DType],
        var nullables: List[Bool],
        var dec_precisions: List[UInt8],
        var dec_scales: List[Int8],
        var field_tzs: List[String],
        var field_dict_index_types: List[UInt8],
        var field_union_type_ids: List[List[Int]],
        var field_flags: List[Int64],
        var field_metadata_keys: List[List[String]],
        var field_metadata_values: List[List[String]],
        var field_child_names: List[List[String]],
        var field_child_types: List[List[UInt8]],
        var field_child_nullables: List[List[Bool]],
    ):
        """Full constructor with
        per-field nested-child slots (parallel `_child_*` lists).  Used by
        `SchemaBuilder.build`."""
        self._names = names^
        self._arrow_types = arrow_types^
        self._dtypes = dtypes^
        self._nullables = nullables^
        self._dec_precisions = dec_precisions^
        self._dec_scales = dec_scales^
        self._field_tzs = field_tzs^
        self._field_dict_index_types = field_dict_index_types^
        self._field_union_type_ids = field_union_type_ids^
        self._field_flags = field_flags^
        self._field_metadata_keys = field_metadata_keys^
        self._field_metadata_values = field_metadata_values^
        self._field_child_names = field_child_names^
        self._field_child_types = field_child_types^
        self._field_child_nullables = field_child_nullables^
        self._metadata_keys = List[String]()
        self._metadata_values = List[String]()

    # __del__ is compiler-synthesized (all fields are List[T] with auto cleanup).

    @staticmethod
    def from_fields_1(f0: Field) -> Schema:
        var sb = SchemaBuilder()
        sb.add_field(f0)
        return sb.build()

    @staticmethod
    def from_fields_2(f0: Field, f1: Field) -> Schema:
        var sb = SchemaBuilder()
        sb.add_field(f0)
        sb.add_field(f1)
        return sb.build()

    @staticmethod
    def from_fields_3(f0: Field, f1: Field, f2: Field) -> Schema:
        var sb = SchemaBuilder()
        sb.add_field(f0)
        sb.add_field(f1)
        sb.add_field(f2)
        return sb.build()

    def num_columns(self) -> Int:
        return len(self._names)

    def field_name(self, index: Int) -> String:
        return self._names[index]

    def names_are(self, names: List[String]) -> Bool:
        """True iff this schema's field names are exactly `names`, in order.

        Compares in place. `field_name(i) == x` copies each name out before
        it compares, which is one String copy per column per call. The
        per-chunk check in `materialize_plan_chunked._projection_is_a_relabel`
        is why this exists."""
        if len(self._names) != len(names):
            return False
        for i in range(len(names)):
            if self._names[i] != names[i]:
                return False
        return True

    def set_field_name(mut self, index: Int, var name: String) raises:
        """Rename field `index` IN PLACE.

        Only the name changes. Every other slot of that field (type, dtype,
        nullability, decimal (p, s), tz, dictionary index type, union type ids,
        flags, per-field metadata, nested children) is left as it is, and so is
        the schema-level metadata. That is the difference from rebuilding the
        schema with `SchemaBuilder`: a rebuild allocates every parallel list
        again, and it drops the schema-level metadata.

        Raises when `index` is out of range. It does not quietly do nothing,
        because a rename that silently misses leaves a result carrying the
        wrong column name."""
        if index < 0 or index >= len(self._names):
            raise Error(
                "Schema.set_field_name: index "
                + String(index)
                + " is out of range for a "
                + String(len(self._names))
                + "-field schema"
            )
        self._names[index] = name^

    def field_arrow_type(self, index: Int) -> ArrowType:
        return ArrowType(self._arrow_types[index])

    def field_dtype(self, index: Int) -> DType:
        return self._dtypes[index]

    def field_nullable(self, index: Int) -> Bool:
        return self._nullables[index]

    def field_decimal_precision(self, index: Int) -> Int:
        """Decimal precision for field `index` (0 if not a decimal field)."""
        if index < 0 or index >= len(self._dec_precisions):
            return 0
        return Int(self._dec_precisions[index])

    def field_decimal_scale(self, index: Int) -> Int:
        """Decimal scale for field `index` (0 if not a decimal field)."""
        if index < 0 or index >= len(self._dec_scales):
            return 0
        return Int(self._dec_scales[index])

    def field_tz(self, index: Int) -> String:
        """Timezone string for field `index` ("" if not a Timestamp* field).
        """
        if index < 0 or index >= len(self._field_tzs):
            return String("")
        return self._field_tzs[index]

    def field_dict_index_type(self, index: Int) -> ArrowType:
        """Dictionary index ArrowType for field `index` (INT32 default).
        """
        if index < 0 or index >= len(self._field_dict_index_types):
            return ArrowType.INT32
        return ArrowType(self._field_dict_index_types[index])

    def field_union_type_ids(self, index: Int) -> List[Int]:
        """Per-child union type-ids for field `index` (empty for non-union).
        """
        if index < 0 or index >= len(self._field_union_type_ids):
            return List[Int]()
        return self._field_union_type_ids[index].copy()

    def field_flags(self, index: Int) -> Int64:
        """Raw `CArrowSchema.flags` bitfield for field `index`.
        Zero if not set; bits are
        ARROW_FLAG_DICTIONARY_ORDERED (1), ARROW_FLAG_NULLABLE (2),
        ARROW_FLAG_MAP_KEYS_SORTED (4)."""
        if index < 0 or index >= len(self._field_flags):
            return Int64(0)
        return self._field_flags[index]

    def field_metadata_keys(self, index: Int) -> List[String]:
        """Per-Field kv-metadata keys for field `index` (empty list if none).
        """
        if index < 0 or index >= len(self._field_metadata_keys):
            return List[String]()
        return self._field_metadata_keys[index].copy()

    def field_metadata_values(self, index: Int) -> List[String]:
        """Per-Field kv-metadata values for field `index` (empty list if none).
        """
        if index < 0 or index >= len(self._field_metadata_values):
            return List[String]()
        return self._field_metadata_values[index].copy()

    def field_at(self, index: Int) raises -> Field:
        """Reconstruct the Field at `index` (incl. decimal precision/scale,
        Phase B parameter slots, Phase C flag bitfield + per-field kv
        metadata, and Phase X1a nested-children for STRUCT/MAP/LIST)."""
        var f = Field(self._names[index], ArrowType(self._arrow_types[index]), self._nullables[index])
        # ⚠ THE ARROW CTOR DERIVES `dtype`; THIS SCHEMA STORED THE REAL ONE.
        # `_dtypes` is filled by `SchemaBuilder.add_field` from the Field the
        # caller handed over, and `field_dtype()` / `get_field_dtype()` return
        # it — re-deriving from `arrow_type` instead would make
        # `field_at(i).dtype` and `field_dtype(i)` DISAGREE for any Field whose
        # two were not already consistent (`ArrowType.from_dtype` folds every
        # non-fixed-width DType onto NULL, and `dtype` is a public `var` anyone
        # may set). Restoring it here is what makes the wire's
        # `WireField.dtype_code` OBSERVABLE: `_schema_to_wire` reads its Fields
        # from this method (pinned by the every-wire-slot-can-be-wrong test).
        f.dtype = self._dtypes[index]
        f.decimal_precision = self.field_decimal_precision(index)
        f.decimal_scale = self.field_decimal_scale(index)
        f._tz = self.field_tz(index)
        f._dict_index_type = self.field_dict_index_type(index)
        f._union_type_ids = self.field_union_type_ids(index)
        f._flags = self.field_flags(index)
        if index >= 0 and index < len(self._field_metadata_keys):
            f._metadata_keys = self._field_metadata_keys[index].copy()
        if index >= 0 and index < len(self._field_metadata_values):
            f._metadata_values = self._field_metadata_values[index].copy()
        # Round-trip nested children.
        if index >= 0 and index < len(self._field_child_names):
            f._child_names = self._field_child_names[index].copy()
            f._child_types = self._field_child_types[index].copy()
            f._child_nullables = self._field_child_nullables[index].copy()
        return f^

    def field_at_unchecked(self, index: Int) -> Field:
        """Non-raising sibling of `field_at`. Same metadata-preserving
        clone, but the caller asserts `0 <= index < num_columns()` (no
        bounds-check).
        added so non-raising callers (e.g. `MorselSource.output_schema`
        trait conformers) can still preserve Phase B/C metadata.
        Also round-trips nested
        children."""
        var f = Field(self._names[index], ArrowType(self._arrow_types[index]), self._nullables[index])
        # ⚠ THE ARROW CTOR DERIVES `dtype`; THIS SCHEMA STORED THE REAL ONE.
        # `_dtypes` is filled by `SchemaBuilder.add_field` from the Field the
        # caller handed over, and `field_dtype()` / `get_field_dtype()` return
        # it — re-deriving from `arrow_type` instead would make
        # `field_at(i).dtype` and `field_dtype(i)` DISAGREE for any Field whose
        # two were not already consistent (`ArrowType.from_dtype` folds every
        # non-fixed-width DType onto NULL, and `dtype` is a public `var` anyone
        # may set). Restoring it here is what makes the wire's
        # `WireField.dtype_code` OBSERVABLE: `_schema_to_wire` reads its Fields
        # from this method (pinned by the every-wire-slot-can-be-wrong test).
        f.dtype = self._dtypes[index]
        f.decimal_precision = self.field_decimal_precision(index)
        f.decimal_scale = self.field_decimal_scale(index)
        f._tz = self.field_tz(index)
        f._dict_index_type = self.field_dict_index_type(index)
        f._union_type_ids = self.field_union_type_ids(index)
        f._flags = self.field_flags(index)
        if index >= 0 and index < len(self._field_metadata_keys):
            f._metadata_keys = self._field_metadata_keys[index].copy()
        if index >= 0 and index < len(self._field_metadata_values):
            f._metadata_values = self._field_metadata_values[index].copy()
        if index >= 0 and index < len(self._field_child_names):
            f._child_names = self._field_child_names[index].copy()
            f._child_types = self._field_child_types[index].copy()
            f._child_nullables = self._field_child_nullables[index].copy()
        return f^

    def field_num_children(self, index: Int) -> Int:
        """Number of nested children
        for the field at `index`. Zero for non-nested fields."""
        if index >= 0 and index < len(self._field_child_names):
            return len(self._field_child_names[index])
        return 0

    def field_child_name(self, field_index: Int, child_index: Int) -> String:
        """Name of the nested child
        at `(field_index, child_index)`. Caller asserts both are in range."""
        return self._field_child_names[field_index][child_index]

    def field_child_arrow_type(self, field_index: Int, child_index: Int) -> ArrowType:
        """ArrowType of the nested
        child at `(field_index, child_index)`."""
        return ArrowType(self._field_child_types[field_index][child_index])

    def field_child_nullable(self, field_index: Int, child_index: Int) -> Bool:
        """Nullable bit of the nested
        child at `(field_index, child_index)`."""
        return self._field_child_nullables[field_index][child_index]

    def get_field_name(self, name: String) raises -> String:
        for i in range(len(self._names)):
            if self._names[i] == name:
                return self._names[i]
        raise Error("Schema.get_field: no field named '" + name + "'")

    def get_field_dtype(self, name: String) raises -> DType:
        for i in range(len(self._names)):
            if self._names[i] == name:
                return self._dtypes[i]
        raise Error("Schema.get_field_dtype: no field named '" + name + "'")

    def get_field_arrow_type(self, name: String) raises -> ArrowType:
        for i in range(len(self._names)):
            if self._names[i] == name:
                return ArrowType(self._arrow_types[i])
        raise Error("Schema.get_field_arrow_type: no field named '" + name + "'")

    def get_field_nullable(self, name: String) raises -> Bool:
        for i in range(len(self._names)):
            if self._names[i] == name:
                return self._nullables[i]
        raise Error("Schema.get_field_nullable: no field named '" + name + "'")

    def column_index(self, name: String) raises -> Int:
        for i in range(len(self._names)):
            if self._names[i] == name:
                return i
        raise Error("Schema.column_index: no field named '" + name + "'")

    # --- Metadata ---

    def set_metadata(mut self, key: String, value: String):
        for i in range(len(self._metadata_keys)):
            if self._metadata_keys[i] == key:
                self._metadata_values[i] = value
                return
        self._metadata_keys.append(key)
        self._metadata_values.append(value)

    def get_metadata(self, key: String) -> Optional[String]:
        for i in range(len(self._metadata_keys)):
            if self._metadata_keys[i] == key:
                return self._metadata_values[i]
        return None

    def has_metadata(self, key: String) -> Bool:
        for i in range(len(self._metadata_keys)):
            if self._metadata_keys[i] == key:
                return True
        return False

    def metadata_count(self) -> Int:
        return len(self._metadata_keys)

    # --- Hardware-profile support ---

    def row_width_bytes(self) -> Int:
        """Estimated row width in bytes for this schema.

        Used by the hardware profile to compute optimal morsel sizes that
        keep the morsel resident in L1d (agg path) or L2 (general path).

        Fixed-width types use their byte width. Variable-width types
        (Utf8, Binary, LargeUtf8, LargeBinary) use an estimate of 32 bytes
        (which covers ~90th percentile of string lengths in ETL workloads).
        Dictionary-encoded columns are costed at their average-string width
        (32B) -- the physical index width is smaller but the decoded value
        stream dominates downstream operators' working set.

        Mirrors the `arrow::datatypes::DataType` -> byte-width mapping
        arm-for-arm, with the multiple `TIMESTAMP_*`
        ArrowType constants all mapping to 8 bytes (backed by int64).
        Returns `max(1, sum)` so an empty schema does not yield 0.
        """
        var total: Int = 0
        for i in range(len(self._arrow_types)):
            var t = ArrowType(self._arrow_types[i])
            if t == ArrowType.BOOL:
                total += 1
            elif t == ArrowType.INT8 or t == ArrowType.UINT8:
                total += 1
            elif t == ArrowType.INT16 or t == ArrowType.UINT16:
                total += 2
            elif (
                t == ArrowType.INT32
                or t == ArrowType.UINT32
                or t == ArrowType.FLOAT32
                or t == ArrowType.DATE32
            ):
                total += 4
            elif (
                t == ArrowType.INT64
                or t == ArrowType.UINT64
                or t == ArrowType.FLOAT64
                or t == ArrowType.DATE64
                or t == ArrowType.TIMESTAMP
                or t == ArrowType.TIMESTAMP_S
                or t == ArrowType.TIMESTAMP_MS
                or t == ArrowType.TIMESTAMP_US
                or t == ArrowType.TIMESTAMP_NS
            ):
                total += 8
            elif t == ArrowType.DECIMAL128:
                total += 16
            elif t == ArrowType.DECIMAL256:
                # 256-bit decimal = 32 bytes LE.
                total += 32
            elif (
                t == ArrowType.STRING
                or t == ArrowType.BINARY
                or t == ArrowType.LARGE_STRING
                or t == ArrowType.LARGE_BINARY
                or t == ArrowType.DICTIONARY
            ):
                total += 32
            elif t == ArrowType.FLOAT16:
                total += 2
            elif (
                t == ArrowType.TIME32_S
                or t == ArrowType.TIME32_MS
                or t == ArrowType.INTERVAL_YEAR_MONTH
            ):
                #
                # Time32 = int32 (4B); IntervalYearMonth = int32 (4B).
                total += 4
            elif (
                t == ArrowType.TIME64_US
                or t == ArrowType.TIME64_NS
                or t == ArrowType.DURATION_S
                or t == ArrowType.DURATION_MS
                or t == ArrowType.DURATION_US
                or t == ArrowType.DURATION_NS
                or t == ArrowType.INTERVAL_DAY_TIME
            ):
                #
                # Time64* / Duration* = int64 (8B);
                # IntervalDayTime = 2× int32 = 8B.
                total += 8
            elif t == ArrowType.INTERVAL_MONTH_DAY_NANO:
                # IntervalMonthDayNano = 16B
                # (int32 months + int32 days + int64 nanos = 16 bytes).
                total += 16
            elif t == ArrowType.UNION_SPARSE or t == ArrowType.UNION_DENSE:
                # Union row width is
                # not a single fixed value (a sparse union has N children
                # all of fixed width, with one int8 type-id buffer; a dense
                # union has a single int32 offset + variable children).
                # Return 8 bytes as a conservative estimate — equivalent to
                # the prior fall-through default; documented sentinel.
                total += 8
            else:
                # NULL / LIST / STRUCT / MAP or unknown -- a conservative
                # default of 8 bytes per field.
                total += 8
        if total < 1:
            return 1
        return total

    def write_to[W: Writer](self, mut writer: W):
        writer.write("Schema(")
        for i in range(len(self._names)):
            if i > 0:
                writer.write(", ")
            writer.write("Field(name='", self._names[i], "', type=")
            writer.write(String(ArrowType(self._arrow_types[i])))
            if self._nullables[i]:
                writer.write(", nullable")
            else:
                writer.write(", non-null")
            writer.write(")")
        if len(self._metadata_keys) > 0:
            writer.write(", metadata={")
            for i in range(len(self._metadata_keys)):
                if i > 0:
                    writer.write(", ")
                writer.write("'", self._metadata_keys[i], "': '")
                writer.write(self._metadata_values[i], "'")
            writer.write("}")
        writer.write(")")
