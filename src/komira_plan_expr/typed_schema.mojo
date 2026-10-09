# =============================================================================
# typed_schema.mojo — comptime schema descriptor for TypedDataFrame[S, ID]
# =============================================================================
#
# This module provides:
#   * `TYPE_*` column-type tag constants (Int codes) + the `TypedDType` alias.
#     `DType` (the stdlib builtin) has no `String` member, so the column-type
#     tag is a small `Int` code (`Column[name, dt: Int, fid: Int]`). Each code
#     maps to an `ArrowType` for the materialize-time validation handshake.
#   * `ColDescriptor` — `(name: String, dtype: Int, nullable: Bool)`. The name
#     field is `String`, NOT `StringLiteral` — `StringLiteral` is parametric
#     (`StringLiteral[<value>]`) in Mojo and is not a concrete struct field
#     type.
#   * `SchemaDescriptor` — a `@fieldwise_init struct` with a `List[ColDescriptor]`
#     field plus a `strict: Bool`. This is a valid comptime parameter on
#     `TypedDataFrame[S, ID]`. Comptime query helpers
#     (`contains` / `safe_dtype` / `index_of` / `dtype_of` / `names_joined` /
#     projection / concat) live on it. It relies on the synthesized
#     `__copyinit__` — a manual one writing `self.cols = other.cols.copy()`
#     errors with `'None' has no attributes`.
#   * Free comptime helpers used by `TypedDataFrame.col[name]()`'s return type:
#     `has_col` / `dtype_at` (bounds-SAFE — returns -1 if absent so the friendly
#     `comptime assert` message wins over a stdlib bounds-check error) /
#     `col_list`.
#   * `to_arrow_schema(...)` — builds the runtime `komira_arrow.schema.Schema`
#     for the materialize-time validation (NOT to feed `read_parquet`, which
#     reads the footer itself).
#   * `validate_against_footer(...)` — the subset-validation routine.
#   * `agg_output_type` — the comptime mirror of `logical_plan.mojo`'s
#     `_infer_agg_field`. CONTRACT-BOUND SECOND COPY (see the section comment
#     above the function). It has no caller: `.agg` is runtime-schema'd. It is
#     the mirror a typed-schema'd agg path would use.
#   * `select_named_schema` / `join_out_schema` / `prefixed_schema` — the LIVE
#     contract-bound `S_out` mirrors (name-form `.select[...]` / `.join` /
#     `.with_alias`); each is exercised by a test comparing the typed `S_out`
#     against the runtime schema.
#   * `infer_binary_out_type` — mirror of `_infer_expr_field`'s non-decimal
#     BinaryOp rule. Used only by `Column.__add__/etc.`'s result-type param;
#     NOT load-bearing for any typed `S_out` (computed `.select` is untyped).
#     Carries a KNOWN DIVERGENCE note re: DECIMAL128.
# =============================================================================

from komira_arrow.schema import Schema, SchemaBuilder, Field
from komira_arrow.arrow_types import ArrowType
from komira_plan_expr.agg_expr import (
    AGG_SUM, AGG_COUNT, AGG_MIN, AGG_MAX, AGG_MEAN,
    AGG_COUNT_DISTINCT, AGG_FIRST, AGG_LAST, AGG_STDDEV_SAMP, AGG_VAR_SAMP,
    AGG_COVAR_POP, AGG_COVAR_SAMP, AGG_REGR_AVGX, AGG_REGR_AVGY,
    AGG_REGR_COUNT, AGG_REGR_SXX, AGG_REGR_SXY, AGG_REGR_SYY,
    AGG_REGR_SLOPE, AGG_REGR_INTERCEPT, AGG_REGR_R2,
    AGG_CORR, AGG_MEDIAN, AGG_LARGEST_K,
    AGG_VAR_POP, AGG_STDDEV_POP, AGG_SEM,
    AGG_COUNT_IF, AGG_BOOL_AND, AGG_BOOL_OR, AGG_PRODUCT, AGG_ANY_VALUE,
    AGG_KAHAN_SUM, AGG_KAHAN_AVG,
    AGG_SKEWNESS, AGG_KURTOSIS, AGG_KURTOSIS_POP,
)


# =============================================================================
# Column-type tags (Int codes). `DType` (builtin) can't represent String, so
# the typed-column marker is a small Int. Public so user schema declarations
# can name them: `schema_of[("c", TYPE_INT64), ...]`. The `Int*Col` / `*Col`
# aliases below are the user-facing names.
# =============================================================================

comptime TYPE_UNKNOWN: Int = -1
comptime TYPE_INT8: Int = 0
comptime TYPE_INT16: Int = 1
comptime TYPE_INT32: Int = 2
comptime TYPE_INT64: Int = 3
comptime TYPE_UINT8: Int = 4
comptime TYPE_UINT16: Int = 5
comptime TYPE_UINT32: Int = 6
comptime TYPE_UINT64: Int = 7
comptime TYPE_FLOAT32: Int = 8
comptime TYPE_FLOAT64: Int = 9
comptime TYPE_BOOL: Int = 10
comptime TYPE_STRING: Int = 11
comptime TYPE_DATE32: Int = 12
comptime TYPE_DATE64: Int = 13
comptime TYPE_TIMESTAMP: Int = 14
comptime TYPE_DECIMAL128: Int = 15
# STRUCT type tag.
# A STRUCT-typed column carries `struct_fields: List[ColDescriptor]` (child
# field declarations) alongside the dtype tag. The typed-DF
# `.field[parent, name]()` chain method consults `S` at COMPTIME to resolve
# (parent, field_name) -> field_idx and emit EXPR_STRUCT_FIELD_IDX. For
# non-STRUCT columns, the `struct_fields` slot is empty.
comptime TYPE_STRUCT: Int = 16
# MAP type tag.
# A MAP-typed column carries `map_key_dtype: Int` + `map_value_dtype: Int`
# (the declared key + value types) alongside the dtype tag.  The typed-DF
# `.get[KeyType](key)` chain method consults `S` at COMPTIME to validate
# `KeyType == map_key_dtype` and resolve the value-type for the return
# Column.  For non-MAP columns, the map slots are TYPE_UNKNOWN.
comptime TYPE_MAP: Int = 17

# NOTE: the column-type tag is just `Int`. Do NOT alias the user-facing marker
# names to the builtin Mojo type names (`Int8`/`Int64`/`Float64`/...) — that
# SHADOWS the builtin types and breaks every `func: UInt8` / `n: Int` signature
# in the file (Mojo: "expected a type, not a value"). The markers therefore
# carry a distinguishing `Col` suffix: `Int64Col`, `Float64Col`, `StringCol`,
# `Date32Col`, `Decimal128Col`, ...

# User-facing column-type marker aliases (for `schema_of["c", Int64Col, ...]`
# declarations and `Column[name, T, fid]` parameters). Example:
#   ```mojo
#   from komira_sdk import schema_of, Int64Col, StringCol, Float64Col
#   comptime OrderSchema = schema_of[
#       "o_orderkey", Int64Col,
#       "o_status",   StringCol,
#       "o_total",    Float64Col,
#   ]()
#   ```
comptime Int8Col = TYPE_INT8
comptime Int16Col = TYPE_INT16
comptime Int32Col = TYPE_INT32
comptime Int64Col = TYPE_INT64
comptime UInt8Col = TYPE_UINT8
comptime UInt16Col = TYPE_UINT16
comptime UInt32Col = TYPE_UINT32
comptime UInt64Col = TYPE_UINT64
comptime Float32Col = TYPE_FLOAT32
comptime Float64Col = TYPE_FLOAT64
comptime BoolCol = TYPE_BOOL
comptime StringCol = TYPE_STRING
comptime Date32Col = TYPE_DATE32
comptime Date64Col = TYPE_DATE64
comptime TimestampCol = TYPE_TIMESTAMP
comptime Decimal128Col = TYPE_DECIMAL128
comptime StructCol = TYPE_STRUCT
comptime MapCol = TYPE_MAP


def type_name(t: Int) -> String:
    """Human-readable name for a column-type tag (for error messages)."""
    if t == TYPE_INT8: return String("Int8")
    if t == TYPE_INT16: return String("Int16")
    if t == TYPE_INT32: return String("Int32")
    if t == TYPE_INT64: return String("Int64")
    if t == TYPE_UINT8: return String("UInt8")
    if t == TYPE_UINT16: return String("UInt16")
    if t == TYPE_UINT32: return String("UInt32")
    if t == TYPE_UINT64: return String("UInt64")
    if t == TYPE_FLOAT32: return String("Float32")
    if t == TYPE_FLOAT64: return String("Float64")
    if t == TYPE_BOOL: return String("BoolCol")
    if t == TYPE_STRING: return String("StringCol")
    if t == TYPE_DATE32: return String("Date32")
    if t == TYPE_DATE64: return String("Date64")
    if t == TYPE_TIMESTAMP: return String("Timestamp")
    if t == TYPE_DECIMAL128: return String("Decimal128")
    if t == TYPE_STRUCT: return String("StructCol")
    if t == TYPE_MAP: return String("MapCol")
    return String("Unknown")


def is_numeric_type(t: Int) -> Bool:
    """True for the markers that get arithmetic operators (`+ - * /`)."""
    return (
        t == TYPE_INT8 or t == TYPE_INT16 or t == TYPE_INT32 or t == TYPE_INT64
        or t == TYPE_UINT8 or t == TYPE_UINT16 or t == TYPE_UINT32 or t == TYPE_UINT64
        or t == TYPE_FLOAT32 or t == TYPE_FLOAT64
        or t == TYPE_DATE32 or t == TYPE_DATE64 or t == TYPE_TIMESTAMP
        or t == TYPE_DECIMAL128
    )


def is_float_type(t: Int) -> Bool:
    return t == TYPE_FLOAT32 or t == TYPE_FLOAT64


def arrow_type_of(t: Int) -> ArrowType:
    """Map a column-type tag to its `ArrowType` (for `to_arrow_schema`)."""
    if t == TYPE_INT8: return ArrowType.INT8
    if t == TYPE_INT16: return ArrowType.INT16
    if t == TYPE_INT32: return ArrowType.INT32
    if t == TYPE_INT64: return ArrowType.INT64
    if t == TYPE_UINT8: return ArrowType.UINT8
    if t == TYPE_UINT16: return ArrowType.UINT16
    if t == TYPE_UINT32: return ArrowType.UINT32
    if t == TYPE_UINT64: return ArrowType.UINT64
    if t == TYPE_FLOAT32: return ArrowType.FLOAT32
    if t == TYPE_FLOAT64: return ArrowType.FLOAT64
    if t == TYPE_BOOL: return ArrowType.BOOL
    if t == TYPE_STRING: return ArrowType.STRING
    # DATE is stored as INT32 days-since-epoch; the engine has no distinct
    # DATE arrow type wired here, so Date32 maps to INT32.
    if t == TYPE_DATE32: return ArrowType.INT32
    if t == TYPE_DATE64: return ArrowType.INT64
    if t == TYPE_TIMESTAMP: return ArrowType.INT64
    # Decimal128: a `Decimal128Col`-declared column reads a TRUE DECIMAL128
    # footer (the row-typed distinct/sort 16-byte int128 cell path). Map to
    # ArrowType.DECIMAL128 so the `validate_against_footer` handshake
    # (`want = arrow_type_of(dc.dtype)`) matches the footer's actual
    # DECIMAL128 type.
    if t == TYPE_DECIMAL128: return ArrowType.DECIMAL128
    if t == TYPE_STRUCT: return ArrowType.STRUCT
    if t == TYPE_MAP: return ArrowType.MAP
    return ArrowType.INT64


def _tag_of_arrow_type(at: ArrowType) -> Int:
    """Best-effort inverse of `arrow_type_of` for the validation handshake.

    Note: not a perfect inverse — INT32 is reported as Int32 (a footer can't
    tell us "this INT32 is logically a DATE32"), so a `Date32`-declared column
    over an INT32 footer column is treated as a match by the validation
    (which compares ArrowTypes, not tags — see `validate_against_footer`).
    This helper is only used for the human-readable footer-type name.
    """
    if at == ArrowType.INT8: return TYPE_INT8
    if at == ArrowType.INT16: return TYPE_INT16
    if at == ArrowType.INT32: return TYPE_INT32
    if at == ArrowType.INT64: return TYPE_INT64
    if at == ArrowType.UINT8: return TYPE_UINT8
    if at == ArrowType.UINT16: return TYPE_UINT16
    if at == ArrowType.UINT32: return TYPE_UINT32
    if at == ArrowType.UINT64: return TYPE_UINT64
    if at == ArrowType.FLOAT32: return TYPE_FLOAT32
    if at == ArrowType.FLOAT64: return TYPE_FLOAT64
    if at == ArrowType.BOOL: return TYPE_BOOL
    if at == ArrowType.STRING: return TYPE_STRING
    # A true DECIMAL128 footer maps back to
    # TYPE_DECIMAL128 (so the validation-handshake error string reports
    # "Decimal128", not "Unknown", and the inverse round-trips with
    # `arrow_type_of(TYPE_DECIMAL128) -> ArrowType.DECIMAL128`).
    if at == ArrowType.DECIMAL128: return TYPE_DECIMAL128
    return TYPE_UNKNOWN


# =============================================================================
# ColDescriptor / SchemaDescriptor
# =============================================================================

@fieldwise_init
struct ColDescriptor(Copyable, Movable):
    """One declared column: `(name, dtype-tag, nullable, struct_fields,
    map_key_dtype, map_value_dtype)`.

    `name` is `String` — NOT `StringLiteral` (parametric, not a concrete field
    type in Mojo).

    `struct_fields` is the slot for
    declaring STRUCT child fields. Empty `List[ColDescriptor]()` for
    non-STRUCT columns. The typed-DF `.field[parent, name]()` chain method
    consults this slot via `comptime_struct_field_index[S, parent, name]()`
    to resolve field_idx at comptime and emit EXPR_STRUCT_FIELD_IDX.

    `map_key_dtype` / `map_value_dtype` are the slots for
    declaring a MAP column's key + value types.  TYPE_UNKNOWN for non-MAP
    columns.  The typed-DF `.get[KeyType](key)` chain method consults
    these to validate `KeyType == map_key_dtype` at COMPTIME and to
    parametrize the return Column's dtype.

    NOTE: Alongside the `@fieldwise_init`-generated 6-arg constructor, the
    `_NN` / `_NS` / `_NM` factory free-fns below handle the trailing
    defaulting.
    """

    var name: String
    var dtype: Int      # one of the TYPE_* tags
    var nullable: Bool
    var struct_fields: List[ColDescriptor]
    var map_key_dtype: Int     # TYPE_UNKNOWN for non-MAP
    var map_value_dtype: Int   # TYPE_UNKNOWN for non-MAP

    # The explicit destructor breaks the non-co-inductive Deinitable check
    # on this struct's recursive self-reference. Field destructors still
    # run; ownership is unchanged.
    def __deinit__(deinit self):
        pass


@fieldwise_init
struct SchemaDescriptor(Copyable, Movable):
    """A comptime-constructible schema: a flat `List[ColDescriptor]` + a strict
    flag. Valid as a comptime parameter on `TypedDataFrame[S, ID]` (a struct
    with a `List[ColDescriptor]` field works).

    Rely on the synthesized `__copyinit__`/`__moveinit__`. A *manual*
    `__copyinit__` errors with `'None' has no attributes`. `ImplicitlyCopyable` conformance fails because
    `List[ColDescriptor]` isn't `ImplicitlyCopyable` — that's fine:
    `materialize[...]()` handles the comptime→runtime path and the
    synthesized `.copy()` handles explicit copies.
    """

    var cols: List[ColDescriptor]
    var strict: Bool

    # --- comptime query helpers ---

    def num_cols(self) -> Int:
        return len(self.cols)

    def contains(self, name: String) -> Bool:
        for i in range(len(self.cols)):
            if self.cols[i].name == name:
                return True
        return False

    def safe_dtype(self, name: String) -> Int:
        """Bounds-SAFE lookup: returns -1 (TYPE_UNKNOWN) if absent. This is the
        one the `.col[name]()` return-type helper uses."""
        for i in range(len(self.cols)):
            if self.cols[i].name == name:
                return self.cols[i].dtype
        return TYPE_UNKNOWN

    def dtype_of(self, name: String) -> Int:
        """Asserts present. Use only after a `contains()` guard."""
        for i in range(len(self.cols)):
            if self.cols[i].name == name:
                return self.cols[i].dtype
        # Falls through to a constant rather than indexing past the end —
        # callers must guard with `contains()` first.
        return TYPE_UNKNOWN

    def nullable_of(self, name: String) -> Bool:
        for i in range(len(self.cols)):
            if self.cols[i].name == name:
                return self.cols[i].nullable
        return False

    def index_of(self, name: String) -> Int:
        for i in range(len(self.cols)):
            if self.cols[i].name == name:
                return i
        return -1

    # --- packed fixed-row layout helpers ---
    # These compute the packed fixed-row image of this schema (the layout a
    # typed-ROW RowBlock terminal uses). Kept as METHODS so callers fold them
    # via `comptime(S.row_col_offset(name))` (the same idiom `dtype_at` uses for
    # `S.safe_dtype`) — iterating `self.cols` inside a method that is comptime-
    # folded avoids the "List[ColDescriptor] not ImplicitlyCopyable" runtime
    # materialization error.

    @staticmethod
    def row_fixed_width_of_tag(tag: Int) -> Int:
        """Fixed-cell byte width of a column-type tag in the packed RowBlock
        fixed region. STRING (var) occupies an 8-byte (offset,length) descriptor
        cell; DECIMAL128 is 16; BOOL is 1 (unpacked byte); DATE32 → 4 (i32);
        DATE64 / TIMESTAMP → 8 (i64). 0 for un-addressable nested tags."""
        if tag == TYPE_INT8 or tag == TYPE_UINT8 or tag == TYPE_BOOL:
            return 1
        if tag == TYPE_INT16 or tag == TYPE_UINT16:
            return 2
        if (
            tag == TYPE_INT32 or tag == TYPE_UINT32 or tag == TYPE_FLOAT32
            or tag == TYPE_DATE32
        ):
            return 4
        if (
            tag == TYPE_INT64 or tag == TYPE_UINT64 or tag == TYPE_FLOAT64
            or tag == TYPE_DATE64 or tag == TYPE_TIMESTAMP
        ):
            return 8
        if tag == TYPE_STRING:
            return 8
        if tag == TYPE_DECIMAL128:
            return 16
        return 0

    def row_col_offset(self, name: String) -> Int:
        """Byte offset of column `name`'s fixed cell within the packed fixed-row
        image (sum of fixed widths of the columns declared before `name`). No
        validity-bitmap prefix (the typed-ROW terminal is a dense cell image).
        Returns the running total if `name` is absent (callers assert presence
        first)."""
        var off = 0
        for i in range(len(self.cols)):
            if self.cols[i].name == name:
                return off
            off += Self.row_fixed_width_of_tag(self.cols[i].dtype)
        return off

    def row_fixed_stride(self) -> Int:
        """Packed fixed-row stride (sum of every column's fixed cell width)."""
        var stride = 0
        for i in range(len(self.cols)):
            stride += Self.row_fixed_width_of_tag(self.cols[i].dtype)
        return stride

    def row_col_offset_by_index(self, idx: Int) -> Int:
        """Byte offset of column INDEX `idx`'s fixed cell within the packed
        fixed-row image (sum of fixed widths of columns 0..idx-1). The index
        sibling of `row_col_offset(name)` — the typed-ROW dispatch uses it to
        fold a `ConcreteKeyBlockSpec`'s base-schema
        key column index (`c0`) into the GROUP BY key's byte offset in the
        scan-schema RowBlock, where the typed-ROW grouped-agg segment reads the
        key cell. Returns the running total if `idx` is out of range (callers
        carry a comptime-valid index)."""
        var off = 0
        for i in range(len(self.cols)):
            if i == idx:
                return off
            off += Self.row_fixed_width_of_tag(self.cols[i].dtype)
        return off

    def names_joined(self) -> String:
        """Comma-separated column names (for the typo error message)."""
        var s = String("")
        for i in range(len(self.cols)):
            if i > 0:
                s += ", "
            s += self.cols[i].name
        return s

    def project1(self, n0: String, d0: Int) -> SchemaDescriptor:
        var c: List[ColDescriptor] = [ColDescriptor(n0, d0, False, List[ColDescriptor](), TYPE_UNKNOWN, TYPE_UNKNOWN)]
        return SchemaDescriptor(c^, False)

    def append_col(self, name: String, dtype: Int) -> SchemaDescriptor:
        var c = self.cols.copy()
        c.append(ColDescriptor(name, dtype, False, List[ColDescriptor](), TYPE_UNKNOWN, TYPE_UNKNOWN))
        return SchemaDescriptor(c^, self.strict)

    def concat(self, other: SchemaDescriptor) -> SchemaDescriptor:
        var c = self.cols.copy()
        for i in range(len(other.cols)):
            c.append(other.cols[i].copy())
        return SchemaDescriptor(c^, self.strict)

    def to_arrow_schema(self) raises -> Schema:
        """Build the runtime Arrow Schema for the validation handshake.

        STRUCT columns also emit their child fields onto the runtime Field's
        `_child_*` slots (Field.add_child propagates name + arrow_type +
        nullable; per-child metadata like tz/decimal-p/s is not propagated).

        MAP columns emit two direct children onto Field._child_* slots
        ("key", "value") with their declared types.  This matches the
        convention in `logical_plan.mojo` `_infer_expr_field` MAP_GET arm (parent_field.child_at(1) is the
        value Field).
        """
        var sb = SchemaBuilder()
        for i in range(len(self.cols)):
            var f = Field(
                self.cols[i].name,
                arrow_type_of(self.cols[i].dtype),
                self.cols[i].nullable,
            )
            # Propagate STRUCT children onto Field._child_* slots
            # so the schema-side _infer_expr_field can resolve struct-field
            # projections through the Field tree.
            if self.cols[i].dtype == TYPE_STRUCT:
                for j in range(len(self.cols[i].struct_fields)):
                    f.add_child(
                        self.cols[i].struct_fields[j].name,
                        arrow_type_of(self.cols[i].struct_fields[j].dtype),
                        self.cols[i].struct_fields[j].nullable,
                    )
            elif self.cols[i].dtype == TYPE_MAP:
                # Emit key + value as 2 direct children of the
                # MAP Field.  Schema-side flat-children convention (see
                # logical_plan.mojo MAP_GET schema arm).
                f.add_child(
                    String("key"),
                    arrow_type_of(self.cols[i].map_key_dtype),
                    False,
                )
                f.add_child(
                    String("value"),
                    arrow_type_of(self.cols[i].map_value_dtype),
                    True,
                )
            sb.add_field(f^)
        return sb.build()


# =============================================================================
# Free comptime helpers — used by `TypedDataFrame.col[name]()` etc.
# =============================================================================

    # The explicit destructor breaks the non-co-inductive Deinitable check
    # on this struct's recursive self-reference. Field destructors still
    # run; ownership is unchanged.
    def __deinit__(deinit self):
        pass

def has_col[S: SchemaDescriptor, name: StringLiteral]() -> Bool:
    return comptime(S.contains(String(name)))


def dtype_at[S: SchemaDescriptor, name: StringLiteral]() -> Int:
    """Return-type helper for `.col[name]()`. Bounds-SAFE:
    returns -1 if absent, so the friendly `comptime assert` in the method body
    wins over a stdlib bounds-check error."""
    return comptime(S.safe_dtype(String(name)))


def col_list[S: SchemaDescriptor]() -> String:
    return comptime(S.names_joined())


# =============================================================================
# STRUCT comptime helpers
# =============================================================================
# `comptime_struct_field_index[S, parent, name]()` resolves the field index
# of a STRUCT column's child at COMPTIME, used by
# `TypedDataFrame.field[parent, name]()` to emit `EXPR_STRUCT_FIELD_IDX`.
# Returns -1 if (a) `parent` isn't in `S`, (b) `parent` isn't STRUCT-typed,
# or (c) `name` isn't a child of `parent` — bounds-SAFE so the friendly
# `comptime assert` in the caller wins over a stdlib bounds-check error.

def _safe_struct_field_index(s: SchemaDescriptor, parent: String, name: String) -> Int:
    """Bounds-SAFE struct-field index lookup. Returns -1 if anything fails."""
    for i in range(len(s.cols)):
        if s.cols[i].name == parent:
            if s.cols[i].dtype != TYPE_STRUCT:
                return -1
            for j in range(len(s.cols[i].struct_fields)):
                if s.cols[i].struct_fields[j].name == name:
                    return j
            return -1
    return -1


def comptime_struct_field_index[S: SchemaDescriptor, parent: StringLiteral, name: StringLiteral]() -> Int:
    """Comptime resolve: index of struct-child `name` in column `parent` of S.
    Returns -1 on any failure (column absent, not STRUCT, child absent)."""
    return comptime(_safe_struct_field_index(S, String(parent), String(name)))


def _safe_struct_child_dtype(s: SchemaDescriptor, parent: String, name: String) -> Int:
    """Bounds-SAFE: dtype tag of a struct child. -1 (TYPE_UNKNOWN) on miss."""
    for i in range(len(s.cols)):
        if s.cols[i].name == parent:
            if s.cols[i].dtype != TYPE_STRUCT:
                return TYPE_UNKNOWN
            for j in range(len(s.cols[i].struct_fields)):
                if s.cols[i].struct_fields[j].name == name:
                    return s.cols[i].struct_fields[j].dtype
            return TYPE_UNKNOWN
    return TYPE_UNKNOWN


def comptime_struct_child_dtype[S: SchemaDescriptor, parent: StringLiteral, name: StringLiteral]() -> Int:
    """Comptime resolve: dtype tag of a struct-child, for the chain method's
    return-type parametrization."""
    return comptime(_safe_struct_child_dtype(S, String(parent), String(name)))


def _struct_field_names_joined(s: SchemaDescriptor, parent: String) -> String:
    """Comma-joined names of the struct children of `parent` (for the friendly
    typo error message). Empty string if `parent` isn't in S / isn't STRUCT.

    Mojo idiom: use `out = out + X` (reassign-with-fresh-alloc)
    rather than `out += X` (in-place memcpy). `String.__iadd__` is not
    comptime-evaluatable; `String.__add__` is.
    """
    for i in range(len(s.cols)):
        if s.cols[i].name == parent:
            if s.cols[i].dtype != TYPE_STRUCT:
                return String("<not a STRUCT column>")
            var children = s.cols[i].struct_fields.copy()
            var out = String("")
            for j in range(len(children)):
                if j > 0:
                    out = out + String(", ")
                var nm = children[j].name
                out = out + nm
            return out
    return String("<no such column>")


def struct_field_list[S: SchemaDescriptor, parent: StringLiteral]() -> String:
    """Comma-joined struct-child names of column `parent` in S (comptime)."""
    return comptime(_struct_field_names_joined(S, String(parent)))


# =============================================================================
# MAP comptime helpers
# =============================================================================
# `comptime_map_key_dtype[S, parent]()` returns the declared key dtype tag
# of MAP column `parent` in `S`.  `comptime_map_value_dtype[S, parent]()`
# returns the value dtype tag.  Both return TYPE_UNKNOWN if `parent`
# doesn't exist or isn't MAP-typed — bounds-SAFE so the comptime asserts
# in the caller fire with a clear message (mirrors gotcha #5 pattern).
# The typed-DF `.get[KeyType](key)` chain method uses these to validate
# `KeyType == comptime_map_key_dtype[S, parent]()` at COMPTIME.

def _safe_map_key_dtype(s: SchemaDescriptor, parent: String) -> Int:
    """Bounds-SAFE: return MAP column `parent`'s key dtype tag; TYPE_UNKNOWN
    if `parent` isn't in `s` / isn't MAP."""
    for i in range(len(s.cols)):
        if s.cols[i].name == parent:
            if s.cols[i].dtype != TYPE_MAP:
                return TYPE_UNKNOWN
            return s.cols[i].map_key_dtype
    return TYPE_UNKNOWN


def comptime_map_key_dtype[S: SchemaDescriptor, parent: StringLiteral]() -> Int:
    """Comptime resolve: dtype tag of MAP column `parent`'s key in S."""
    return comptime(_safe_map_key_dtype(S, String(parent)))


def _safe_map_value_dtype(s: SchemaDescriptor, parent: String) -> Int:
    """Bounds-SAFE: return MAP column `parent`'s value dtype tag; TYPE_UNKNOWN
    if `parent` isn't in `s` / isn't MAP."""
    for i in range(len(s.cols)):
        if s.cols[i].name == parent:
            if s.cols[i].dtype != TYPE_MAP:
                return TYPE_UNKNOWN
            return s.cols[i].map_value_dtype
    return TYPE_UNKNOWN


def comptime_map_value_dtype[S: SchemaDescriptor, parent: StringLiteral]() -> Int:
    """Comptime resolve: dtype tag of MAP column `parent`'s value in S.
    Used as the return-type parametrization for the typed `.get[K](key)`
    chain method."""
    return comptime(_safe_map_value_dtype(S, String(parent)))


def prefixed_schema[S: SchemaDescriptor, alias_name: StringLiteral]() -> SchemaDescriptor:
    """Comptime mirror of `DataFrame.with_alias("<alias>")`'s output schema.

    Every column name becomes `<alias>.<orig>`, type + nullability unchanged.
    (Reciprocal of `dataframe_alias.with_alias_impl`.)"""
    return materialize[_build_prefixed_schema(S, String(alias_name) + String("."))]()


def _build_prefixed_schema(s: SchemaDescriptor, prefix: String) -> SchemaDescriptor:
    var cols = List[ColDescriptor]()
    for i in range(len(s.cols)):
        cols.append(ColDescriptor(prefix + s.cols[i].name, s.cols[i].dtype, s.cols[i].nullable, s.cols[i].struct_fields.copy(), s.cols[i].map_key_dtype, s.cols[i].map_value_dtype))
    return SchemaDescriptor(cols^, s.strict)


# =============================================================================
# `schema_of[...]` — comptime schema constructors. Heterogeneous variadics
# don't exist in Mojo, so these are arity-overloaded over the column
# count. Each column is a `(name: StringLiteral, dtype: Int)`
# 2-tuple; nullable defaults to False. A 16-arity ceiling matches the runtime
# surface (with_columns/agg overloads).
#
# The body builds a `SchemaDescriptor([ColDescriptor(...), ...], strict)`
# literal — since the `n_i: StringLiteral` / `d_i: Int` params are comptime,
# the whole expression is comptime-evaluable; `materialize[...]()` lifts the
# resulting (non-`ImplicitlyCopyable`) `SchemaDescriptor` to a value usable in
# both `comptime X = schema_of[...]()` bindings and as a `TypedDataFrame[S, ID]`
# comptime parameter.
#
# `_NN` (not-nullable) helper to keep the literals short.
# =============================================================================

def _NN(n: String, d: Int) -> ColDescriptor:
    return ColDescriptor(n, d, False, List[ColDescriptor](), TYPE_UNKNOWN, TYPE_UNKNOWN)


def _NS(n: String, var struct_fields: List[ColDescriptor]) -> ColDescriptor:
    """STRUCT-column descriptor: name + child fields.
    Helper for declaring a STRUCT-typed column in a comptime schema. `struct_fields` is the list of
    child column descriptors; each child can itself be a STRUCT (nested
    structs work — recursion via `_NS` on the children too)."""
    return ColDescriptor(n, TYPE_STRUCT, False, struct_fields^, TYPE_UNKNOWN, TYPE_UNKNOWN)


def _NM(n: String, key_dtype: Int, value_dtype: Int) -> ColDescriptor:
    """MAP-column descriptor: name + key dtype + value dtype.
    Helper for declaring a MAP-typed column in a comptime schema.  `key_dtype` and `value_dtype`
    are the TYPE_* tags of the Map's key + value (e.g.
    `_NM("metadata", TYPE_STRING, TYPE_STRING)`).  The typed-DF
    `.get[KeyType](key)` chain method validates `KeyType ==
    comptime_map_key_dtype[S, parent]()` at COMPTIME."""
    return ColDescriptor(n, TYPE_MAP, False, List[ColDescriptor](), key_dtype, value_dtype)


def schema_of[
    n0: StringLiteral, d0: Int,
]() -> SchemaDescriptor:
    """Build a comptime `SchemaDescriptor` from alternating `name, TypeCol` pairs.
    Bind it to a `comptime` and pass as the `S` param of `read_parquet_typed[S,
    ID]` / `assume_schema[S, ID]`. The type markers are the `*Col` aliases
    (`Int64Col`, `Float64Col`, `StringCol`, `Date32Col`, `Decimal128Col`, ...).
    Arity-overloaded 1..16 keys.

    Examples:
        ```mojo
        from komira_sdk import schema_of, Int64Col, Float64Col, StringCol
        comptime LSchema = schema_of[
            "lk", Int64Col,
            "lv", Float64Col,
        ]()
        var tdf = read_parquet_typed[LSchema, 1](ctx, "l.parquet")
        ```
    """
    return materialize[SchemaDescriptor([_NN(String(n0), d0)], False)]()


def schema_of[
    n0: StringLiteral, d0: Int, n1: StringLiteral, d1: Int,
]() -> SchemaDescriptor:
    """2-key `schema_of` — see the 1-key overload for the full `Examples:` block
    and the `*Col` marker roster.

    Examples:
        ```mojo
        from komira_sdk import schema_of, Int64Col, Float64Col
        comptime S = schema_of["lk", Int64Col, "lv", Float64Col]()
        ```
    """
    return materialize[SchemaDescriptor([_NN(String(n0), d0), _NN(String(n1), d1)], False)]()


def schema_of[
    n0: StringLiteral, d0: Int, n1: StringLiteral, d1: Int, n2: StringLiteral, d2: Int,
]() -> SchemaDescriptor:
    return materialize[SchemaDescriptor([
        _NN(String(n0), d0), _NN(String(n1), d1), _NN(String(n2), d2),
    ], False)]()


def schema_of[
    n0: StringLiteral, d0: Int, n1: StringLiteral, d1: Int, n2: StringLiteral, d2: Int,
    n3: StringLiteral, d3: Int,
]() -> SchemaDescriptor:
    return materialize[SchemaDescriptor([
        _NN(String(n0), d0), _NN(String(n1), d1), _NN(String(n2), d2), _NN(String(n3), d3),
    ], False)]()


def schema_of[
    n0: StringLiteral, d0: Int, n1: StringLiteral, d1: Int, n2: StringLiteral, d2: Int,
    n3: StringLiteral, d3: Int, n4: StringLiteral, d4: Int,
]() -> SchemaDescriptor:
    return materialize[SchemaDescriptor([
        _NN(String(n0), d0), _NN(String(n1), d1), _NN(String(n2), d2), _NN(String(n3), d3),
        _NN(String(n4), d4),
    ], False)]()


def schema_of[
    n0: StringLiteral, d0: Int, n1: StringLiteral, d1: Int, n2: StringLiteral, d2: Int,
    n3: StringLiteral, d3: Int, n4: StringLiteral, d4: Int, n5: StringLiteral, d5: Int,
]() -> SchemaDescriptor:
    return materialize[SchemaDescriptor([
        _NN(String(n0), d0), _NN(String(n1), d1), _NN(String(n2), d2), _NN(String(n3), d3),
        _NN(String(n4), d4), _NN(String(n5), d5),
    ], False)]()


def schema_of[
    n0: StringLiteral, d0: Int, n1: StringLiteral, d1: Int, n2: StringLiteral, d2: Int,
    n3: StringLiteral, d3: Int, n4: StringLiteral, d4: Int, n5: StringLiteral, d5: Int,
    n6: StringLiteral, d6: Int,
]() -> SchemaDescriptor:
    return materialize[SchemaDescriptor([
        _NN(String(n0), d0), _NN(String(n1), d1), _NN(String(n2), d2), _NN(String(n3), d3),
        _NN(String(n4), d4), _NN(String(n5), d5), _NN(String(n6), d6),
    ], False)]()


def schema_of[
    n0: StringLiteral, d0: Int, n1: StringLiteral, d1: Int, n2: StringLiteral, d2: Int,
    n3: StringLiteral, d3: Int, n4: StringLiteral, d4: Int, n5: StringLiteral, d5: Int,
    n6: StringLiteral, d6: Int, n7: StringLiteral, d7: Int,
]() -> SchemaDescriptor:
    return materialize[SchemaDescriptor([
        _NN(String(n0), d0), _NN(String(n1), d1), _NN(String(n2), d2), _NN(String(n3), d3),
        _NN(String(n4), d4), _NN(String(n5), d5), _NN(String(n6), d6), _NN(String(n7), d7),
    ], False)]()


def schema_of[
    n0: StringLiteral, d0: Int, n1: StringLiteral, d1: Int, n2: StringLiteral, d2: Int,
    n3: StringLiteral, d3: Int, n4: StringLiteral, d4: Int, n5: StringLiteral, d5: Int,
    n6: StringLiteral, d6: Int, n7: StringLiteral, d7: Int, n8: StringLiteral, d8: Int,
]() -> SchemaDescriptor:
    return materialize[SchemaDescriptor([
        _NN(String(n0), d0), _NN(String(n1), d1), _NN(String(n2), d2), _NN(String(n3), d3),
        _NN(String(n4), d4), _NN(String(n5), d5), _NN(String(n6), d6), _NN(String(n7), d7),
        _NN(String(n8), d8),
    ], False)]()


def schema_of[
    n0: StringLiteral, d0: Int, n1: StringLiteral, d1: Int, n2: StringLiteral, d2: Int,
    n3: StringLiteral, d3: Int, n4: StringLiteral, d4: Int, n5: StringLiteral, d5: Int,
    n6: StringLiteral, d6: Int, n7: StringLiteral, d7: Int, n8: StringLiteral, d8: Int,
    n9: StringLiteral, d9: Int,
]() -> SchemaDescriptor:
    return materialize[SchemaDescriptor([
        _NN(String(n0), d0), _NN(String(n1), d1), _NN(String(n2), d2), _NN(String(n3), d3),
        _NN(String(n4), d4), _NN(String(n5), d5), _NN(String(n6), d6), _NN(String(n7), d7),
        _NN(String(n8), d8), _NN(String(n9), d9),
    ], False)]()


def schema_of[
    n0: StringLiteral, d0: Int, n1: StringLiteral, d1: Int, n2: StringLiteral, d2: Int,
    n3: StringLiteral, d3: Int, n4: StringLiteral, d4: Int, n5: StringLiteral, d5: Int,
    n6: StringLiteral, d6: Int, n7: StringLiteral, d7: Int, n8: StringLiteral, d8: Int,
    n9: StringLiteral, d9: Int, n10: StringLiteral, d10: Int,
]() -> SchemaDescriptor:
    return materialize[SchemaDescriptor([
        _NN(String(n0), d0), _NN(String(n1), d1), _NN(String(n2), d2), _NN(String(n3), d3),
        _NN(String(n4), d4), _NN(String(n5), d5), _NN(String(n6), d6), _NN(String(n7), d7),
        _NN(String(n8), d8), _NN(String(n9), d9), _NN(String(n10), d10),
    ], False)]()


def schema_of[
    n0: StringLiteral, d0: Int, n1: StringLiteral, d1: Int, n2: StringLiteral, d2: Int,
    n3: StringLiteral, d3: Int, n4: StringLiteral, d4: Int, n5: StringLiteral, d5: Int,
    n6: StringLiteral, d6: Int, n7: StringLiteral, d7: Int, n8: StringLiteral, d8: Int,
    n9: StringLiteral, d9: Int, n10: StringLiteral, d10: Int, n11: StringLiteral, d11: Int,
]() -> SchemaDescriptor:
    return materialize[SchemaDescriptor([
        _NN(String(n0), d0), _NN(String(n1), d1), _NN(String(n2), d2), _NN(String(n3), d3),
        _NN(String(n4), d4), _NN(String(n5), d5), _NN(String(n6), d6), _NN(String(n7), d7),
        _NN(String(n8), d8), _NN(String(n9), d9), _NN(String(n10), d10), _NN(String(n11), d11),
    ], False)]()


def schema_of[
    n0: StringLiteral, d0: Int, n1: StringLiteral, d1: Int, n2: StringLiteral, d2: Int,
    n3: StringLiteral, d3: Int, n4: StringLiteral, d4: Int, n5: StringLiteral, d5: Int,
    n6: StringLiteral, d6: Int, n7: StringLiteral, d7: Int, n8: StringLiteral, d8: Int,
    n9: StringLiteral, d9: Int, n10: StringLiteral, d10: Int, n11: StringLiteral, d11: Int,
    n12: StringLiteral, d12: Int,
]() -> SchemaDescriptor:
    return materialize[SchemaDescriptor([
        _NN(String(n0), d0), _NN(String(n1), d1), _NN(String(n2), d2), _NN(String(n3), d3),
        _NN(String(n4), d4), _NN(String(n5), d5), _NN(String(n6), d6), _NN(String(n7), d7),
        _NN(String(n8), d8), _NN(String(n9), d9), _NN(String(n10), d10), _NN(String(n11), d11),
        _NN(String(n12), d12),
    ], False)]()


def schema_of[
    n0: StringLiteral, d0: Int, n1: StringLiteral, d1: Int, n2: StringLiteral, d2: Int,
    n3: StringLiteral, d3: Int, n4: StringLiteral, d4: Int, n5: StringLiteral, d5: Int,
    n6: StringLiteral, d6: Int, n7: StringLiteral, d7: Int, n8: StringLiteral, d8: Int,
    n9: StringLiteral, d9: Int, n10: StringLiteral, d10: Int, n11: StringLiteral, d11: Int,
    n12: StringLiteral, d12: Int, n13: StringLiteral, d13: Int,
]() -> SchemaDescriptor:
    return materialize[SchemaDescriptor([
        _NN(String(n0), d0), _NN(String(n1), d1), _NN(String(n2), d2), _NN(String(n3), d3),
        _NN(String(n4), d4), _NN(String(n5), d5), _NN(String(n6), d6), _NN(String(n7), d7),
        _NN(String(n8), d8), _NN(String(n9), d9), _NN(String(n10), d10), _NN(String(n11), d11),
        _NN(String(n12), d12), _NN(String(n13), d13),
    ], False)]()


def schema_of[
    n0: StringLiteral, d0: Int, n1: StringLiteral, d1: Int, n2: StringLiteral, d2: Int,
    n3: StringLiteral, d3: Int, n4: StringLiteral, d4: Int, n5: StringLiteral, d5: Int,
    n6: StringLiteral, d6: Int, n7: StringLiteral, d7: Int, n8: StringLiteral, d8: Int,
    n9: StringLiteral, d9: Int, n10: StringLiteral, d10: Int, n11: StringLiteral, d11: Int,
    n12: StringLiteral, d12: Int, n13: StringLiteral, d13: Int, n14: StringLiteral, d14: Int,
]() -> SchemaDescriptor:
    return materialize[SchemaDescriptor([
        _NN(String(n0), d0), _NN(String(n1), d1), _NN(String(n2), d2), _NN(String(n3), d3),
        _NN(String(n4), d4), _NN(String(n5), d5), _NN(String(n6), d6), _NN(String(n7), d7),
        _NN(String(n8), d8), _NN(String(n9), d9), _NN(String(n10), d10), _NN(String(n11), d11),
        _NN(String(n12), d12), _NN(String(n13), d13), _NN(String(n14), d14),
    ], False)]()


def schema_of[
    n0: StringLiteral, d0: Int, n1: StringLiteral, d1: Int, n2: StringLiteral, d2: Int,
    n3: StringLiteral, d3: Int, n4: StringLiteral, d4: Int, n5: StringLiteral, d5: Int,
    n6: StringLiteral, d6: Int, n7: StringLiteral, d7: Int, n8: StringLiteral, d8: Int,
    n9: StringLiteral, d9: Int, n10: StringLiteral, d10: Int, n11: StringLiteral, d11: Int,
    n12: StringLiteral, d12: Int, n13: StringLiteral, d13: Int, n14: StringLiteral, d14: Int,
    n15: StringLiteral, d15: Int,
]() -> SchemaDescriptor:
    return materialize[SchemaDescriptor([
        _NN(String(n0), d0), _NN(String(n1), d1), _NN(String(n2), d2), _NN(String(n3), d3),
        _NN(String(n4), d4), _NN(String(n5), d5), _NN(String(n6), d6), _NN(String(n7), d7),
        _NN(String(n8), d8), _NN(String(n9), d9), _NN(String(n10), d10), _NN(String(n11), d11),
        _NN(String(n12), d12), _NN(String(n13), d13), _NN(String(n14), d14), _NN(String(n15), d15),
    ], False)]()


# =============================================================================
# `schema_of_strict[...]` — strict (rejects-extras) variant of `schema_of[...]`.
# Mirror of
# `schema_of` byte-for-byte except the `SchemaDescriptor`'s `strict: Bool`
# flag flips to `True` (vs `False` for `schema_of`). The validator at
# `validate_against_footer` (above) reads `descriptor.strict` directly: when
# True, it adds an extras-scan that raises if the footer / batch carries any
# column NOT in the declared schema. The validation pipeline
# (`_check_declared_against_plan[S]` → `validate_against_footer(materialize
# [S](), ...)`) lifts the `strict` field through `materialize[S]()`, so the
# flag rides through every entry point (`read_parquet[S, ID]`,
# `from_record_batch[S, ID]`, `assume_schema[S, ID]`,
# `TypedDataFrame.from_untyped`) unchanged.
#
# Usage: `comptime MySchema = schema_of_strict["col_a", Int64Col, ...]()`.
# Then `read_parquet[MySchema, 1](path)` etc. rejects any file column not
# declared in MySchema with a `ParquetSchemaMismatch: extra column "..."`
# error at construction time.
# =============================================================================

def schema_of_strict[
    n0: StringLiteral, d0: Int,
]() -> SchemaDescriptor:
    return materialize[SchemaDescriptor([_NN(String(n0), d0)], True)]()


def schema_of_strict[
    n0: StringLiteral, d0: Int, n1: StringLiteral, d1: Int,
]() -> SchemaDescriptor:
    return materialize[SchemaDescriptor([_NN(String(n0), d0), _NN(String(n1), d1)], True)]()


def schema_of_strict[
    n0: StringLiteral, d0: Int, n1: StringLiteral, d1: Int, n2: StringLiteral, d2: Int,
]() -> SchemaDescriptor:
    return materialize[SchemaDescriptor([
        _NN(String(n0), d0), _NN(String(n1), d1), _NN(String(n2), d2),
    ], True)]()


def schema_of_strict[
    n0: StringLiteral, d0: Int, n1: StringLiteral, d1: Int, n2: StringLiteral, d2: Int,
    n3: StringLiteral, d3: Int,
]() -> SchemaDescriptor:
    return materialize[SchemaDescriptor([
        _NN(String(n0), d0), _NN(String(n1), d1), _NN(String(n2), d2), _NN(String(n3), d3),
    ], True)]()


def schema_of_strict[
    n0: StringLiteral, d0: Int, n1: StringLiteral, d1: Int, n2: StringLiteral, d2: Int,
    n3: StringLiteral, d3: Int, n4: StringLiteral, d4: Int,
]() -> SchemaDescriptor:
    return materialize[SchemaDescriptor([
        _NN(String(n0), d0), _NN(String(n1), d1), _NN(String(n2), d2), _NN(String(n3), d3),
        _NN(String(n4), d4),
    ], True)]()


def schema_of_strict[
    n0: StringLiteral, d0: Int, n1: StringLiteral, d1: Int, n2: StringLiteral, d2: Int,
    n3: StringLiteral, d3: Int, n4: StringLiteral, d4: Int, n5: StringLiteral, d5: Int,
]() -> SchemaDescriptor:
    return materialize[SchemaDescriptor([
        _NN(String(n0), d0), _NN(String(n1), d1), _NN(String(n2), d2), _NN(String(n3), d3),
        _NN(String(n4), d4), _NN(String(n5), d5),
    ], True)]()


def schema_of_strict[
    n0: StringLiteral, d0: Int, n1: StringLiteral, d1: Int, n2: StringLiteral, d2: Int,
    n3: StringLiteral, d3: Int, n4: StringLiteral, d4: Int, n5: StringLiteral, d5: Int,
    n6: StringLiteral, d6: Int,
]() -> SchemaDescriptor:
    return materialize[SchemaDescriptor([
        _NN(String(n0), d0), _NN(String(n1), d1), _NN(String(n2), d2), _NN(String(n3), d3),
        _NN(String(n4), d4), _NN(String(n5), d5), _NN(String(n6), d6),
    ], True)]()


def schema_of_strict[
    n0: StringLiteral, d0: Int, n1: StringLiteral, d1: Int, n2: StringLiteral, d2: Int,
    n3: StringLiteral, d3: Int, n4: StringLiteral, d4: Int, n5: StringLiteral, d5: Int,
    n6: StringLiteral, d6: Int, n7: StringLiteral, d7: Int,
]() -> SchemaDescriptor:
    return materialize[SchemaDescriptor([
        _NN(String(n0), d0), _NN(String(n1), d1), _NN(String(n2), d2), _NN(String(n3), d3),
        _NN(String(n4), d4), _NN(String(n5), d5), _NN(String(n6), d6), _NN(String(n7), d7),
    ], True)]()


def schema_of_strict[
    n0: StringLiteral, d0: Int, n1: StringLiteral, d1: Int, n2: StringLiteral, d2: Int,
    n3: StringLiteral, d3: Int, n4: StringLiteral, d4: Int, n5: StringLiteral, d5: Int,
    n6: StringLiteral, d6: Int, n7: StringLiteral, d7: Int, n8: StringLiteral, d8: Int,
    n9: StringLiteral, d9: Int,
]() -> SchemaDescriptor:
    return materialize[SchemaDescriptor([
        _NN(String(n0), d0), _NN(String(n1), d1), _NN(String(n2), d2), _NN(String(n3), d3),
        _NN(String(n4), d4), _NN(String(n5), d5), _NN(String(n6), d6), _NN(String(n7), d7),
        _NN(String(n8), d8), _NN(String(n9), d9),
    ], True)]()


def schema_of_strict[
    n0: StringLiteral, d0: Int, n1: StringLiteral, d1: Int, n2: StringLiteral, d2: Int,
    n3: StringLiteral, d3: Int, n4: StringLiteral, d4: Int, n5: StringLiteral, d5: Int,
    n6: StringLiteral, d6: Int, n7: StringLiteral, d7: Int, n8: StringLiteral, d8: Int,
    n9: StringLiteral, d9: Int, n10: StringLiteral, d10: Int, n11: StringLiteral, d11: Int,
]() -> SchemaDescriptor:
    return materialize[SchemaDescriptor([
        _NN(String(n0), d0), _NN(String(n1), d1), _NN(String(n2), d2), _NN(String(n3), d3),
        _NN(String(n4), d4), _NN(String(n5), d5), _NN(String(n6), d6), _NN(String(n7), d7),
        _NN(String(n8), d8), _NN(String(n9), d9), _NN(String(n10), d10), _NN(String(n11), d11),
    ], True)]()


def schema_of_strict[
    n0: StringLiteral, d0: Int, n1: StringLiteral, d1: Int, n2: StringLiteral, d2: Int,
    n3: StringLiteral, d3: Int, n4: StringLiteral, d4: Int, n5: StringLiteral, d5: Int,
    n6: StringLiteral, d6: Int, n7: StringLiteral, d7: Int, n8: StringLiteral, d8: Int,
    n9: StringLiteral, d9: Int, n10: StringLiteral, d10: Int, n11: StringLiteral, d11: Int,
    n12: StringLiteral, d12: Int, n13: StringLiteral, d13: Int, n14: StringLiteral, d14: Int,
    n15: StringLiteral, d15: Int,
]() -> SchemaDescriptor:
    return materialize[SchemaDescriptor([
        _NN(String(n0), d0), _NN(String(n1), d1), _NN(String(n2), d2), _NN(String(n3), d3),
        _NN(String(n4), d4), _NN(String(n5), d5), _NN(String(n6), d6), _NN(String(n7), d7),
        _NN(String(n8), d8), _NN(String(n9), d9), _NN(String(n10), d10), _NN(String(n11), d11),
        _NN(String(n12), d12), _NN(String(n13), d13), _NN(String(n14), d14), _NN(String(n15), d15),
    ], True)]()


# =============================================================================
# Brand-safe materialize.
# =============================================================================
# `materialize[S]()` lifts a comptime `SchemaDescriptor` to a runtime value, but
# the runtime `String` name buffers it produces are NOT always stable. For a
# brand built via `var cols: List[ColDescriptor]; cols.append(...)` (the
# `select_named_schema` / `join_out_schema` shape) — or a `schema_of` brand that
# reaches `materialize` again through a DEEPLY-NESTED generic instantiation (the
# `_rechain` -> `from_record_batch[S_out]` -> `_check_declared_against_plan[S_out]`
# join-chain path) — `len(d.cols)` reads fine but `d.cols[i].name` SIGSEGVs at
# runtime (for example in `validate_against_footer` reading
# `descriptor.cols`). This is the SAME stale-buffer trap the
# `_typed_partition_udf_out_schema` / `_typed_agg_udf_out_schema` helpers already
# work around by RECONSTRUCTING every name through `String(...)`.
#
# `materialize_schema_safe[S]()` is the chokepoint fix: it rebuilds a fresh
# runtime `SchemaDescriptor` by folding each column's `name` (and any nested
# struct-field name) through the `String(...)` ctor at COMPTIME — exactly the way
# `schema_of[...]`'s `_NN(String(n0), ...)` folds its literal bytes — so the
# resulting descriptor's String buffers are freshly-heap-allocated and stable
# regardless of how `S` was constructed. The dtype / nullable / map-dtype fields
# are plain `Int`/`Bool` PODs (no heap), so a direct comptime read is safe.
# =============================================================================

def _rebuild_coldescriptor_safe(c: ColDescriptor) -> ColDescriptor:
    """Rebuild ONE ColDescriptor with its `name` (and any nested struct-field
    names) reconstructed through `String(...)` — folding the bytes into fresh
    heap buffers. Recursion handles nested STRUCT children. Runs at COMPTIME
    (called from the comptime `_rebuild_schema_safe` fold), so the `c.name` read
    touches the interpreter-addressable comptime bytes, NOT a stale runtime
    buffer."""
    var children = List[ColDescriptor]()
    for j in range(len(c.struct_fields)):
        children.append(_rebuild_coldescriptor_safe(c.struct_fields[j]))
    return ColDescriptor(
        String(c.name), c.dtype, c.nullable, children^,
        c.map_key_dtype, c.map_value_dtype,
    )


def _rebuild_schema_safe(s: SchemaDescriptor) -> SchemaDescriptor:
    """COMPTIME rebuild of a `SchemaDescriptor` with every name `String(...)`-
    reconstructed. Modeled on `_build_prefixed_schema` (which likewise reads
    `s.cols[i].name` at comptime and works). The whole-descriptor literal this
    returns is then lifted ONCE via `materialize[_rebuild_schema_safe(S)]()` —
    the same `materialize[SchemaDescriptor([literal], ...)]()` shape `schema_of`
    uses, which DOES re-materialize cleanly (vs the `var-cols`-built or
    deeply-instantiated brand, which does not)."""
    var cols = List[ColDescriptor]()
    for i in range(len(s.cols)):
        cols.append(_rebuild_coldescriptor_safe(s.cols[i]))
    return SchemaDescriptor(cols^, s.strict)


def materialize_schema_safe[S: SchemaDescriptor]() -> SchemaDescriptor:
    """Brand-safe `materialize[S]()`: rebuild a fresh runtime `SchemaDescriptor`
    whose `String` name buffers are stable regardless of how `S` was built.

    The rebuild (`_rebuild_schema_safe`) runs entirely at COMPTIME — reading
    `S.cols[i].name` where the interpreter CAN address the bytes — and folds each
    name through `String(...)`. The result is a `SchemaDescriptor([literal])` that
    `materialize[...]()` lifts the SAME way `schema_of[...]` does (the shape that
    re-materializes cleanly). The downstream `.cols[i].name` read can no longer
    touch a stale/unreadable buffer."""
    return materialize[_rebuild_schema_safe(S)]()


def validate_brand_against_footer[S: SchemaDescriptor](
    footer: Schema, source_label: String,
) raises:
    """Parametric entry to `validate_against_footer` that lifts the comptime
    brand `S` through the BRAND-SAFE `materialize_schema_safe[S]()` rather
    than the raw `materialize[S]()`. Every typed-surface validation
    site (`_check_declared_against_plan`, `validate_typed_against_schema`,
    `from_record_batch`/`_rechain`) routes here so a `schema_of` /
    `select_named_schema` / `join_out_schema` brand reaching a deeply-nested
    generic instantiation no longer crashes on the `.cols[i].name` read."""
    validate_against_footer(materialize_schema_safe[S](), footer, source_label)


# =============================================================================
# Materialize-time validation handshake (declare-a-subset).
# =============================================================================

def validate_against_footer(
    descriptor: SchemaDescriptor,
    footer: Schema,
    source_label: String,
) raises:
    """Validate a declared (subset) schema against the actual file/batch
    schema. For each *declared* column: it must exist in `footer` and its
    ArrowType must match exactly (no widening). Extra footer
    columns are NOT an error unless `descriptor.strict`. Raises a
    `ParquetSchemaMismatch`-prefixed `Error` listing every problem.
    """
    var problems = String("")
    var nproblems = 0
    for i in range(len(descriptor.cols)):
        var dc = descriptor.cols[i].copy()
        var fidx = -1
        for j in range(footer.num_columns()):
            if footer.field_name(j) == dc.name:
                fidx = j
                break
        if fidx < 0:
            if nproblems > 0:
                problems += "\n"
            problems += "    - column \"" + dc.name + "\": declared but not present in the file"
            nproblems += 1
            continue
        var want = arrow_type_of(dc.dtype)
        var have = footer.field_arrow_type(fidx)
        if want != have:
            if nproblems > 0:
                problems += "\n"
            problems += (
                "    - column \"" + dc.name + "\": declared " + type_name(dc.dtype)
                + ", footer has " + type_name(_tag_of_arrow_type(have))
            )
            nproblems += 1
    if descriptor.strict:
        for j in range(footer.num_columns()):
            var fn_name = footer.field_name(j)
            if not descriptor.contains(fn_name):
                if nproblems > 0:
                    problems += "\n"
                problems += "    - extra column \"" + fn_name + "\": file column not in the (strict) declared schema"
                nproblems += 1
    if nproblems > 0:
        raise Error(
            "ParquetSchemaMismatch: declared schema for \"" + source_label
            + "\" does not satisfy the actual schema:\n" + problems
            + "\n  (file has " + String(footer.num_columns()) + " columns; you declared "
            + String(len(descriptor.cols))
            + " — declaring a subset is allowed, so extra file columns are not"
            + " flagged unless schema_of_strict[...] was used.)"
        )


# =============================================================================
# `agg_output_type` — comptime mirror of `LogicalPlan._infer_agg_field`.
# =============================================================================
# CONTRACT-BOUND SECOND COPY.
# This MUST stay byte-for-byte in lockstep with `logical_plan.mojo`'s
# `_infer_agg_field` output-type logic (search `_infer_agg_field` there).
#
# CALLER STATUS:
#   * NO CALLER. `.agg(*aggs: AggExpr)` returns a plain `DataFrame` with a
#     runtime-resolved schema (no comptime `S_out`), so nothing in the typed
#     surface consults this. It is the contract-bound mirror a
#     typed-schema'd agg path would use (including the unsigned-SUM rule).
#   * The typed-S_out drift test asserts the RUNTIME Aggregate plan's
#     `output_schema` directly (SUM(Int64)->Int64, COUNT(*)->Int64); it does
#     NOT call `agg_output_type`. When a comptime-schema'd agg path exists,
#     that test must also compare the comptime `S_out` against the runtime
#     side (as it does for the live `select_named_schema` / `join_out_schema`
#     / `prefixed_schema` mirrors).
#   * RECIPROCAL POINTER: `logical_plan.mojo`'s `_infer_agg_field` carries a
#     comment pointing back here.
#
#   SUM(int*)    -> Int64        COUNT(*) / COUNT(x) -> Int64
#   SUM(uint*)   -> UInt64       MEAN(_) / AVG(_)    -> Float64
#   SUM(float*)  -> Float64      COUNT_DISTINCT(_)   -> Int64
#   SUM(dec128)  -> Decimal128   STDDEV_SAMP / CORR  -> Float64
#   MIN/MAX(T)   -> T            MEDIAN              -> Float64
#   FIRST/LAST(T)-> T            LARGEST_K           -> Float64 (only consumer
#                                                     largest2(v3))

def _is_unsigned_int_type(t: Int) -> Bool:
    return t == TYPE_UINT8 or t == TYPE_UINT16 or t == TYPE_UINT32 or t == TYPE_UINT64


def agg_output_type(func: UInt8, child_type: Int) -> Int:
    """Comptime mirror of `_infer_agg_field`'s type rule. `child_type` is the
    declared type tag of the agg's input column, or TYPE_UNKNOWN for COUNT(*).

    No caller — see the module-section comment above. It is the
    contract-bound mirror a typed-schema'd agg path would use."""
    if func == AGG_COUNT:
        return TYPE_INT64
    if func == AGG_COUNT_DISTINCT:
        return TYPE_INT64
    if func == AGG_SUM:
        # Mirrors `_infer_agg_field`'s SUM promotion: INT8/INT16/INT32 -> INT64; UINT8/UINT16/UINT32 -> UINT64;
        # FLOAT32 -> FLOAT64; INT64/UINT64/FLOAT64/DECIMAL128 stay as-is.
        if is_float_type(child_type):
            return TYPE_FLOAT64
        if child_type == TYPE_DECIMAL128:
            return TYPE_DECIMAL128
        if child_type == TYPE_UINT64:
            return TYPE_UINT64
        if _is_unsigned_int_type(child_type):
            return TYPE_UINT64
        # signed int (incl. the date-as-int tags, which are int32/int64) and
        # the TYPE_UNKNOWN fallback collapse to INT64 — matching the runtime's
        # `int8/16/32 -> int64; int64 stays` and the `ArrowType.NULL` fallback
        # the engine then validates against.
        return TYPE_INT64
    if func == AGG_MEAN:
        return TYPE_FLOAT64
    if func == AGG_STDDEV_SAMP:
        return TYPE_FLOAT64
    if func == AGG_VAR_SAMP:
        return TYPE_FLOAT64
    # The POPULATION-FINALIZE family, always
    # FLOAT64 for the same reason the sample pair above is: the finalize is a
    # division of `m2`, never a passthrough of the input cell.
    if func == AGG_VAR_POP:
        return TYPE_FLOAT64
    if func == AGG_STDDEV_POP:
        return TYPE_FLOAT64
    if func == AGG_SEM:
        return TYPE_FLOAT64
    # The MONOID-FOLD family. `product` is FLOAT64 even over an INT64 input
    # (DuckDB's rule); `count_if` is an
    # INT64 tally; the two boolean folds are BOOLEAN.
    if func == AGG_PRODUCT:
        return TYPE_FLOAT64
    if func == AGG_COUNT_IF:
        return TYPE_INT64
    if func == AGG_BOOL_AND or func == AGG_BOOL_OR:
        return TYPE_BOOL
    if func == AGG_CORR:
        return TYPE_FLOAT64
    if func == AGG_MEDIAN:
        return TYPE_FLOAT64
    if func == AGG_LARGEST_K:
        return TYPE_FLOAT64
    # The BIVARIATE family. THIS IS THE
    # CONTRACT-BOUND COMPTIME MIRROR of `logical_plan._infer_agg_field`, so the
    # split has to be the same one: `regr_count` is INT64 (a count is never
    # NULL) and the other ten are always FLOAT64 whatever the inputs were.
    if func == AGG_REGR_COUNT:
        return TYPE_INT64
    if (
        func == AGG_COVAR_POP
        or func == AGG_COVAR_SAMP
        or func == AGG_REGR_AVGX
        or func == AGG_REGR_AVGY
        or func == AGG_REGR_SXX
        or func == AGG_REGR_SXY
        or func == AGG_REGR_SYY
        or func == AGG_REGR_SLOPE
        or func == AGG_REGR_INTERCEPT
        or func == AGG_REGR_R2
        # The COMPENSATED sums and the HIGHER-MOMENT trio. ALWAYS FLOAT64,
        # NEVER the input's type: DuckDB's only signature for each is
        # `(DOUBLE) -> DOUBLE`, so `typeof(fsum(i))` over a BIGINT column is
        # DOUBLE. Letting `fsum` fall
        # through to the `return child_type` tail below would give it an INT64
        # output cell over an int column and truncate the answer the
        # compensation exists to preserve.
        or func == AGG_KAHAN_SUM
        or func == AGG_KAHAN_AVG
        or func == AGG_SKEWNESS
        or func == AGG_KURTOSIS
        or func == AGG_KURTOSIS_POP
    ):
        return TYPE_FLOAT64
    # `AGG_ANY_VALUE` joins the two pick tags.
    # It is a DIFFERENT statistic from `AGG_FIRST` (first NON-NULL vs first
    # ROW) but the same OUTPUT-TYPE rule — a pick returns the input's type.
    if (
        func == AGG_MIN
        or func == AGG_MAX
        or func == AGG_FIRST
        or func == AGG_LAST
        or func == AGG_ANY_VALUE
    ):
        return child_type
    return child_type


# =============================================================================
# `infer_binary_out_type` — comptime mirror of `_infer_expr_field`'s BinaryOp
# rule. CALLER STATUS: used ONLY by `Column.__add__/__sub__/__mul__/__truediv__`
# in `typed_column.mojo` to compute the *result `Column`'s `dtype` param*. That
# `dtype` reaches a typed `S_out` ONLY if a *typed* computed-`.select` projects
# the result column — and computed `.select` is UNTYPED (`.select(*exprs: Expr)`
# returns a plain `DataFrame`; `.with_columns(*exprs)` likewise). So this mirror
# is NOT load-bearing for any typed `S_out` — it is the mirror a typed
# computed-`.select` would use. (Name-form `.select[...]` copies col
# descriptors verbatim — it does NOT call this.)
# =============================================================================
# CONTRACT-BOUND SECOND COPY. `_infer_expr_field` (search `EXPR_BINARY_OP`
# in logical_plan.mojo) declares a non-decimal BinaryOp's output Field type as
# the LEFT operand's arrow_type — UNCONDITIONALLY (no width-promotion, no
# float-promotion even for `/`). We mirror that exactly.
#
#   Int8  + Int16 -> Int8     (left wins — NOT Int16; matches the runtime)
#   Float64 / Int64 -> Float64 (left wins)
#   Int32 / Int32 -> Int32    (left wins; NOT Float64 — matches the runtime)
#
# KNOWN DIVERGENCE — DECIMAL128. The RUNTIME `_infer_expr_field`'s
# `EXPR_BINARY_OP` arm has a decimal sub-arm: if EITHER operand is DECIMAL128 ->
# the result is DECIMAL128 (carrying the wider decimal's (p,s)), or FLOAT64 if
# EITHER operand is FLOAT64. This mirror does NOT replicate that — it returns
# `left_tag` unconditionally — so e.g. `dec128 + float64` would mirror as
# `Decimal128` (runtime: FLOAT64) and `int64 + dec128` as `Int64` (runtime:
# DECIMAL128). This is NOT live (computed `.select` is untyped, so a
# wrong tag can't produce a lying typed `S_out`). MUST be re-derived (add the
# decimal sub-arm here, byte-faithful to the runtime) when BOTH a typed
# computed-`.select` AND `Decimal128Col` arith land on the typed surface.

def infer_binary_out_type(left_tag: Int, right_tag: Int) -> Int:
    """Output column-type tag for a `Column op Column` binary expr. Mirrors
    `_infer_expr_field`'s non-decimal `EXPR_BINARY_OP` rule: the LEFT operand's
    type wins, unconditionally. `right_tag` is unused — kept in the
    signature so the DECIMAL128 sub-arm (see the KNOWN DIVERGENCE note above)
    stays a single-call-site edit here when typed computed-`.select` ships."""
    if left_tag == TYPE_UNKNOWN:
        return TYPE_UNKNOWN
    return left_tag



# =============================================================================
# `select_named_schema[S, *names]()` — comptime projection-result schema for
# `TypedDataFrame.select["a", "b", ...]()` (the name-form). For each name in
# the pack: comptime-asserts the name exists in `S` (friendly typo message),
# then appends `(name, S.dtype_of(name), S.nullable_of(name))` in pack order.
# Single homogeneous comptime variadic — NOT arity-overloaded. Iteration uses
# the index form (`comptime for i in range(len(names)): comptime nm =
# String(names[i])`) — the iterator-protocol form is RED on `StaticString`
# packs.
# =============================================================================

def select_named_schema[S: SchemaDescriptor, *names: StaticString]() -> SchemaDescriptor:
    # Build a runtime `var cols` (the `materialize[S.method(...)]()` wrap lifts
    # each comptime lookup), then return the `SchemaDescriptor`. Used in a
    # return-type position (`TypedDataFrame.select`), so this is comptime-folded.
    #
    # CAVEAT: do NOT `materialize[<this result>]()` at a use site
    # — a `var-cols`-built `SchemaDescriptor` does not re-materialize cleanly
    # (its runtime `List` is unreadable past `len()`), unlike the
    # `materialize[SchemaDescriptor([literal], ...)]()`-built ones (`schema_of` /
    # `prefixed_schema`). Iterate the comptime `S` field-by-field via the
    # `comptime(...)` accessors (`S.num_cols()`, `S.cols[i].name`, etc.) instead.
    #
    # CAVEAT: the `comptime assert` typo-message uses
    # `col_list[S]()` (= `comptime(S.names_joined())`), which iterates `S`'s
    # column-name `String`s and concatenates them. The comptime interpreter
    # fails (`interpreting memcpy can't get dst memory`) on `String +=` of an
    # SSO-INLINED `String` operand — so schemas should not use 1–~7-char column
    # names (`LineitemSchema`-style ≥ ~8 chars is heap-allocated and fine). This
    # affects every `.col` / `.group_by` / `.sort` typo-message too — it's a
    # general declared-schema constraint, not specific to this helper.
    var cols = List[ColDescriptor]()
    comptime for i in range(len(names)):
        comptime nm = String(names[i])
        comptime assert S.contains(nm), "TypedDataFrame.select: no column '" + nm + "' in schema. Have: " + col_list[S]()
        cols.append(ColDescriptor(nm, materialize[S.safe_dtype(nm)](), materialize[S.nullable_of(nm)](), List[ColDescriptor](), TYPE_UNKNOWN, TYPE_UNKNOWN))
    return SchemaDescriptor(cols^, materialize[S.strict]())


# =============================================================================
# `join_out_schema` — comptime mirror of `LogicalPlan.join`'s output-schema
# construction (logical_plan.mojo, the `def join` builder).
# =============================================================================
# CONTRACT-BOUND SECOND COPY (the fiddliest of the three S_out mirrors). The runtime rule (verified by reading `def join`):
#   * left columns: always included, name and type as-is (nullability below).
#   * right columns: included ONLY when `join_type` is not SEMI and not ANTI.
#       - if a right column's NAME collides with any left column name, its name
#         becomes `<name> + "_right"` (the bare `_right` suffix — NOT `right.`,
#         NOT a counter; check `def join` if this ever changes).
#       - type copied as-is.
#   * nullability: the NULL-supplying side of an outer join is forced
#     nullable — the right columns of a LEFT join, the left columns of a RIGHT
#     join, both sides of a FULL join (an unmatched row is NULL there). Every
#     other column keeps its flag. `def join` does the same.
#   * CROSS join: left ++ right (no key columns; same collision rule).
# Nullability is pinned by `tests/test_expr_render_value_identity.mojo`
# (`test_typed_join_mirror_marks_the_null_supplying_side`). RECIPROCAL POINTER:
# `def join` carries a comment back here.
#
# `join_type` here is the runtime UInt8 tag (logical_plan.JOIN_*). SEMI = 4,
# ANTI = 5 — the only two that drop the right side.

def _join_drops_right(join_type: Int) -> Bool:
    # JOIN_SEMI == 4, JOIN_ANTI == 5 (see logical_plan.mojo). Kept as plain Ints
    # here so this module stays free of a logical_plan import (module-cycle
    # hygiene — typed_schema is upstream of everything).
    return join_type == 4 or join_type == 5


def join_out_schema(left: SchemaDescriptor, right: SchemaDescriptor, join_type: Int) -> SchemaDescriptor:
    """Comptime mirror of `LogicalPlan.join`'s output schema. `join_type` is the
    runtime `logical_plan.JOIN_*` tag (INNER=0, LEFT=1, RIGHT=2, FULL=3,
    SEMI=4, ANTI=5, CROSS=6)."""
    var cols = List[ColDescriptor]()
    # RIGHT = 2, FULL = 3 null the left side; LEFT = 1, FULL = 3 the right.
    var left_nulls = join_type == 2 or join_type == 3
    var right_nulls = join_type == 1 or join_type == 3
    for i in range(len(left.cols)):
        var lc = left.cols[i].copy()
        if left_nulls:
            lc.nullable = True
        cols.append(lc^)
    if not _join_drops_right(join_type):
        for i in range(len(right.cols)):
            var rname = right.cols[i].name
            var collides = False
            for j in range(len(left.cols)):
                if left.cols[j].name == rname:
                    collides = True
                    break
            var final_name = rname + "_right" if collides else rname.copy()
            cols.append(ColDescriptor(final_name^, right.cols[i].dtype, right.cols[i].nullable or right_nulls, right.cols[i].struct_fields.copy(), right.cols[i].map_key_dtype, right.cols[i].map_value_dtype))
    return SchemaDescriptor(cols^, False)


def join_schema_of[L: SchemaDescriptor, R: SchemaDescriptor, jt: Int]() -> SchemaDescriptor:
    """Parametric wrapper around `join_out_schema` for use in a return type
    (`materialize` lifts the non-ImplicitlyCopyable `SchemaDescriptor`)."""
    return materialize[join_out_schema(L, R, jt)]()
