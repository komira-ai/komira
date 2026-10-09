# =============================================================================
# schema_descriptor.mojo — comptime schema machinery for the typed UDF traits
# =============================================================================
#
# The typed `MapFn` / `FilterFn` / `AggFn` traits (map_fn.mojo /
# filter_fn.mojo / agg_fn.mojo) carry a `comptime InputSchema: SchemaDescriptor`
# (and `OutputSchema`) describing the columns they read / produce — names +
# dtype tags. The engine reads these at plan-compile to (a) resolve the
# projection map against the child schema, (b) know each het-pack element's
# concrete dtype.
#
# This mirrors `komira_sdk.typed_schema`'s `ColDescriptor` /
# `SchemaDescriptor`, but lives in `komira_udf` because the traits do
# (`komira_udf` deps only the core packages — it cannot see `komira_sdk`).
# `komira_sdk` may re-export these for the typed-DF surface.
#
# Comptime-member idioms: set a `SchemaDescriptor` trait member via
# `materialize[schema_of2((...), (...))]()` (NOT `comptime(...)` —
# `SchemaDescriptor` isn't `ImplicitlyCopyable`); iterate a comptime-bound
# `List` of non-`ImplicitlyCopyable` elements via
# `comptime for i in range(n): comptime x = list[i]`.
# =============================================================================


from komira_arrow.arrow_types import ArrowType


# =============================================================================
# Dtype tags (small `Int` codes). `DType` (stdlib builtin) has no `String`
# member, so the column dtype on a `ColDescriptor` is a small `Int`, exactly
# like `typed_schema.mojo`'s `TYPE_*`. The `DT_*` aliases are the names the
# UDF-design worked examples use.
# =============================================================================

comptime DT_UNKNOWN: Int = -1
comptime DT_I8: Int = 0
comptime DT_I16: Int = 1
comptime DT_I32: Int = 2
comptime DT_I64: Int = 3
comptime DT_U8: Int = 4
comptime DT_U16: Int = 5
comptime DT_U32: Int = 6
comptime DT_U64: Int = 7
comptime DT_F32: Int = 8
comptime DT_F64: Int = 9
comptime DT_BOOL: Int = 10
comptime DT_STRING: Int = 11
comptime DT_DATE32: Int = 12
comptime DT_DATE64: Int = 13
comptime DT_TIMESTAMP: Int = 14
# DECIMAL128 — shared numbering with `komira_sdk.typed_schema`'s
# TYPE_DECIMAL128 (== 15). A 16-byte fixed cell read as one int128 (the
# `read_fixed`/`write_fixed[int128]` seam the typed-ROW distinct/sort driver
# uses). `dtag_to_dtype(DT_DECIMAL128)` -> DType.int128 (see below).
comptime DT_DECIMAL128: Int = 15


def dtag_name(t: Int) -> String:
    """Human-readable name for a dtype tag (for error messages)."""
    if t == DT_I8: return String("Int8")
    if t == DT_I16: return String("Int16")
    if t == DT_I32: return String("Int32")
    if t == DT_I64: return String("Int64")
    if t == DT_U8: return String("UInt8")
    if t == DT_U16: return String("UInt16")
    if t == DT_U32: return String("UInt32")
    if t == DT_U64: return String("UInt64")
    if t == DT_F32: return String("Float32")
    if t == DT_F64: return String("Float64")
    if t == DT_BOOL: return String("Bool")
    if t == DT_STRING: return String("String")
    if t == DT_DATE32: return String("Date32")
    if t == DT_DATE64: return String("Date64")
    if t == DT_TIMESTAMP: return String("Timestamp")
    if t == DT_DECIMAL128: return String("Decimal128")
    return String("?")


def dtag_to_dtype(t: Int) -> DType:
    """Map a dtype tag to the stdlib `DType` (for `comptime OutType: DType`
    on the traits and for the het-pack `SIMD[dt, W]` instantiation).

    String / Date / Timestamp have no scalar `DType` analogue here — those
    are not legal on a vectorized UDF column anyway (string columns are
    scalar-only); the engine `comptime assert`s the column dtypes it
    feeds to `run_chunk` are SIMD-able.
    """
    if t == DT_I8: return DType.int8
    if t == DT_I16: return DType.int16
    if t == DT_I32: return DType.int32
    if t == DT_I64: return DType.int64
    if t == DT_U8: return DType.uint8
    if t == DT_U16: return DType.uint16
    if t == DT_U32: return DType.uint32
    if t == DT_U64: return DType.uint64
    if t == DT_F32: return DType.float32
    if t == DT_F64: return DType.float64
    if t == DT_BOOL: return DType.bool
    # DATE32 stored as INT32 days-since-epoch, DATE64 / TIMESTAMP as INT64.
    if t == DT_DATE32: return DType.int32
    if t == DT_DATE64: return DType.int64
    if t == DT_TIMESTAMP: return DType.int64
    # DECIMAL128 (tag 15) is a 16-byte cell read as one int128 — the
    # `read_fixed`/`write_fixed[int128]` seam the typed-row distinct/sort
    # driver uses. WITHOUT this arm, a comptime-typed DECIMAL128 key
    # (`comptime KDT = dtag_to_dtype(KB.key0_dtag())` in the typed-ROW
    # distinct/sort factory stamps) falls through to the int64 default —
    # silently truncating the 16-byte cell to an 8-byte int64 key.
    # Mirrors the row join's key-backing dtype rule (TYPE_DECIMAL128
    # -> DType.int128). The DT_* tag numbering is shared with
    # `komira_sdk.typed_schema`'s TYPE_* (DECIMAL128 == 15 in both).
    if t == DT_DECIMAL128: return DType.int128
    # STRING / UNKNOWN — no scalar DType; callers must guard.
    return DType.int64


def dtype_to_dtag(d: DType) -> Int:
    """`DType` -> `DT_*` tag — the INVERSE of `dtag_to_dtype`, and the ONE
    implementation of that direction.

    ★ IT LIVES HERE, NEXT TO ITS INVERSE, ON PURPOSE. A second copy of this
    mapping is not a duplicated function, it is a second place a dtype fact can
    be written down — the exact defect `typed_udf_sugar.mojo`'s header records
    twice (a `Scalar[DType.bool]` output deriving DT_UNKNOWN because the tag
    was derived from the Mojo TYPE in one place and from the `DType` in
    another). `typed_udf_sugar._dtag_of_dtype` now forwards here; the scalar
    UDF surface (`komira_sdk.scalar_udf`) calls it at COMPTIME to derive
    both of a UDF's tags from its own signature.

    ⚠ ALLOW-LIST, NEVER A DENY-LIST. An unmapped `DType` reports `DT_UNKNOWN`
    so the failure is local and loud, rather than taking a plausible-looking
    default — the `DT_DECIMAL128` lesson in `dtag_to_dtype` above."""
    if d == DType.int8: return DT_I8
    if d == DType.int16: return DT_I16
    if d == DType.int32: return DT_I32
    if d == DType.int64: return DT_I64
    if d == DType.uint8: return DT_U8
    if d == DType.uint16: return DT_U16
    if d == DType.uint32: return DT_U32
    if d == DType.uint64: return DT_U64
    if d == DType.float32: return DT_F32
    if d == DType.float64: return DT_F64
    if d == DType.bool: return DT_BOOL
    return DT_UNKNOWN


def dtag_to_arrow_type_id(t: Int) -> UInt8:
    """Map a dtype tag to the `ArrowType.type_id` `UdfData` stores
    (`input_columns` / `output_columns` are `(name, ArrowType-code)`).

    Mirrors `typed_schema.mojo`'s `arrow_type_of`: DATE32->INT32 days,
    DATE64/TIMESTAMP->INT64: the physical storage id, not Arrow's own
    date / timestamp ids (komira#974).
    """
    if t == DT_I8: return ArrowType.INT8.type_id
    if t == DT_I16: return ArrowType.INT16.type_id
    if t == DT_I32: return ArrowType.INT32.type_id
    if t == DT_I64: return ArrowType.INT64.type_id
    if t == DT_U8: return ArrowType.UINT8.type_id
    if t == DT_U16: return ArrowType.UINT16.type_id
    if t == DT_U32: return ArrowType.UINT32.type_id
    if t == DT_U64: return ArrowType.UINT64.type_id
    if t == DT_F32: return ArrowType.FLOAT32.type_id
    if t == DT_F64: return ArrowType.FLOAT64.type_id
    if t == DT_BOOL: return ArrowType.BOOL.type_id
    if t == DT_STRING: return ArrowType.STRING.type_id
    if t == DT_DATE32: return ArrowType.INT32.type_id
    if t == DT_DATE64: return ArrowType.INT64.type_id
    if t == DT_TIMESTAMP: return ArrowType.INT64.type_id
    return ArrowType.INT64.type_id


def dtag_of_arrow_type_id(tid: UInt8) -> Int:
    """Best-effort inverse of `dtag_to_arrow_type_id` — used at
    materialize-time to compare a `UdfData.input_columns` dtype code against
    the child schema's actual `ArrowType`. INT32 reports as Int32 (a footer
    can't distinguish a logical DATE32); the materialize-time check compares
    `ArrowType` codes, not tags, so a Date32-declared column over an INT32
    column is treated as a match.
    """
    if tid == ArrowType.INT8.type_id: return DT_I8
    if tid == ArrowType.INT16.type_id: return DT_I16
    if tid == ArrowType.INT32.type_id: return DT_I32
    if tid == ArrowType.INT64.type_id: return DT_I64
    if tid == ArrowType.UINT8.type_id: return DT_U8
    if tid == ArrowType.UINT16.type_id: return DT_U16
    if tid == ArrowType.UINT32.type_id: return DT_U32
    if tid == ArrowType.UINT64.type_id: return DT_U64
    if tid == ArrowType.FLOAT32.type_id: return DT_F32
    if tid == ArrowType.FLOAT64.type_id: return DT_F64
    if tid == ArrowType.BOOL.type_id: return DT_BOOL
    if tid == ArrowType.STRING.type_id: return DT_STRING
    return DT_UNKNOWN


def dtag_is_simd(t: Int) -> Bool:
    """True if the dtype tag has a scalar `DType` (i.e. is legal on a
    vectorized-UDF column). String / Unknown are not."""
    return t >= DT_I8 and t <= DT_TIMESTAMP and t != DT_STRING


# =============================================================================
# ColDescriptor / SchemaDescriptor — mirrors komira_sdk.typed_schema.
# `name` is `String`, NOT `StringLiteral` (parametric in 1.0.0b1). Rely on the synthesized `__copyinit__` (a manual one errors
# `'None' has no attributes`). `ImplicitlyCopyable`
# conformance fails because `List[ColDescriptor]` isn't — that's fine,
# `materialize[...]()` handles the comptime->runtime path.
# =============================================================================

@fieldwise_init
struct ColDescriptor(Copyable, Movable):
    """One declared column: `(name, dtype-tag, nullable)`."""

    var name: String
    var dtype: Int      # one of the DT_* tags
    var nullable: Bool


@fieldwise_init
struct SchemaDescriptor(Copyable, Movable):
    """A comptime-constructible schema: a flat `List[ColDescriptor]`. Valid as
    a comptime trait member (a struct with a `List[ColDescriptor]` field
    works)."""

    var cols: List[ColDescriptor]

    def num_cols(self) -> Int:
        return len(self.cols)

    def contains(self, name: String) -> Bool:
        for i in range(len(self.cols)):
            if self.cols[i].name == name:
                return True
        return False

    def safe_dtype(self, name: String) -> Int:
        for i in range(len(self.cols)):
            if self.cols[i].name == name:
                return self.cols[i].dtype
        return DT_UNKNOWN

    def index_of(self, name: String) -> Int:
        for i in range(len(self.cols)):
            if self.cols[i].name == name:
                return i
        return -1

    def names_joined(self) -> String:
        var s = String("")
        for i in range(len(self.cols)):
            if i > 0:
                s += ", "
            s += self.cols[i].name
        return s

    def concat(self, other: SchemaDescriptor) -> SchemaDescriptor:
        var c = self.cols.copy()
        for i in range(len(other.cols)):
            c.append(other.cols[i].copy())
        return SchemaDescriptor(c^)


# =============================================================================
# `schema_of[...]` — comptime schema constructors. Heterogeneous variadics
# don't exist in Mojo 1.0.0b1, so these are arity-overloaded over the column
# count (same shape as `typed_schema.mojo`'s `schema_of[...]`).
# Each column is a `(n_i: StringLiteral, d_i: Int)` comptime-param PAIR — the
# whole expression is comptime-evaluable; `materialize[...]()` lifts the
# (non-`ImplicitlyCopyable`) `SchemaDescriptor` to a value usable in both
# `comptime X = schema_of[...]()` bindings and as a trait member. Used by a
# conformer:
#   comptime InputSchema  = schema_of["l_extendedprice", DT_F64, "l_discount", DT_F64]()
#   comptime OutputSchema = schema_of["l_disc_price", DT_F64]()
#
# `_NN` (nullable) helper to keep the literals short — the engine derives the
# real per-column nullability from the child schema at materialize-time; the
# descriptor's nullable flag is not load-bearing for a UDF's InputSchema.
# =============================================================================

def _NN(n: String, d: Int) -> ColDescriptor:
    return ColDescriptor(n, d, True)


def schema_of[
    n0: StringLiteral, d0: Int,
]() -> SchemaDescriptor:
    return materialize[SchemaDescriptor([_NN(String(n0), d0)])]()


def schema_of[
    n0: StringLiteral, d0: Int, n1: StringLiteral, d1: Int,
]() -> SchemaDescriptor:
    return materialize[SchemaDescriptor([_NN(String(n0), d0), _NN(String(n1), d1)])]()


def schema_of[
    n0: StringLiteral, d0: Int, n1: StringLiteral, d1: Int, n2: StringLiteral, d2: Int,
]() -> SchemaDescriptor:
    return materialize[SchemaDescriptor([
        _NN(String(n0), d0), _NN(String(n1), d1), _NN(String(n2), d2),
    ])]()


def schema_of[
    n0: StringLiteral, d0: Int, n1: StringLiteral, d1: Int, n2: StringLiteral, d2: Int,
    n3: StringLiteral, d3: Int,
]() -> SchemaDescriptor:
    return materialize[SchemaDescriptor([
        _NN(String(n0), d0), _NN(String(n1), d1), _NN(String(n2), d2), _NN(String(n3), d3),
    ])]()


def schema_of[
    n0: StringLiteral, d0: Int, n1: StringLiteral, d1: Int, n2: StringLiteral, d2: Int,
    n3: StringLiteral, d3: Int, n4: StringLiteral, d4: Int,
]() -> SchemaDescriptor:
    return materialize[SchemaDescriptor([
        _NN(String(n0), d0), _NN(String(n1), d1), _NN(String(n2), d2), _NN(String(n3), d3),
        _NN(String(n4), d4),
    ])]()


def schema_of[
    n0: StringLiteral, d0: Int, n1: StringLiteral, d1: Int, n2: StringLiteral, d2: Int,
    n3: StringLiteral, d3: Int, n4: StringLiteral, d4: Int, n5: StringLiteral, d5: Int,
]() -> SchemaDescriptor:
    return materialize[SchemaDescriptor([
        _NN(String(n0), d0), _NN(String(n1), d1), _NN(String(n2), d2), _NN(String(n3), d3),
        _NN(String(n4), d4), _NN(String(n5), d5),
    ])]()


def schema_of[
    n0: StringLiteral, d0: Int, n1: StringLiteral, d1: Int, n2: StringLiteral, d2: Int,
    n3: StringLiteral, d3: Int, n4: StringLiteral, d4: Int, n5: StringLiteral, d5: Int,
    n6: StringLiteral, d6: Int, n7: StringLiteral, d7: Int,
]() -> SchemaDescriptor:
    return materialize[SchemaDescriptor([
        _NN(String(n0), d0), _NN(String(n1), d1), _NN(String(n2), d2), _NN(String(n3), d3),
        _NN(String(n4), d4), _NN(String(n5), d5), _NN(String(n6), d6), _NN(String(n7), d7),
    ])]()


# =============================================================================
# Comptime reflection helpers for trait-default schema
# derivation. Mojo's `reflect[T]()` exposes field count, names, and types at
# comptime — enough to derive a `SchemaDescriptor` from a
# `@fieldwise_init`-shaped row struct.
#
# The new user-facing UDF traits (`FilterFn` / `MapFn` / `AggFn`) carry a
# trait-default `comptime InputSchema: SchemaDescriptor =
# _derive_schema[Self.InRow]()` — the trait default fires per-conformer,
# so the same trait surface produces a 1-col schema for a
# 1-field row struct and a 4-col schema for a 4-field row struct.
# =============================================================================


def _dtag_for[T: AnyType]() -> Int:
    """Map a Mojo type `T` to its `DT_*` integer tag. Used by
    `_derive_schema[T]()` to bridge from comptime field-type reflection to
    the existing dtype-tag dispatch.

    Mojo 1.0.0b1 has no `_type_hash[T]()`; this is the equivalent
    type-discrimination primitive for the bounded `DT_*` universe. Add a
    `(T == U)` arm for any new type you want to expose to the
    auto-derivation path.
    """
    comptime if (T == Int8):       return DT_I8
    elif (T == Int16):             return DT_I16
    elif (T == Int32):             return DT_I32
    elif (T == Int64):             return DT_I64
    elif (T == UInt8):             return DT_U8
    elif (T == UInt16):            return DT_U16
    elif (T == UInt32):            return DT_U32
    elif (T == UInt64):            return DT_U64
    elif (T == Float32):           return DT_F32
    elif (T == Float64):           return DT_F64
    elif (T == Bool):              return DT_BOOL
    elif (T == String):            return DT_STRING
    else:                                     return DT_UNKNOWN


def _derive_schema[T: AnyType & Copyable & Movable]() -> SchemaDescriptor:
    """Auto-derive a `SchemaDescriptor` from `T`'s `@fieldwise_init`-exposed
    fields via comptime reflection. Used as the trait-default value for
    `comptime InputSchema` on the user-facing UDF traits — eliminates the
    boilerplate `comptime InputSchema = schema_of["name", DT_X, ...]()`
    that every conformer used to declare manually.

    The trait default fires per-conformer, multi-field rows
    materialize correct N-column schemas, explicit-literal overrides still
    win when a conformer declares `comptime InputSchema = ...` directly.

    For a field whose Mojo type isn't in the `_dtag_for[T]()` arm list,
    the column's dtype is `DT_UNKNOWN` and downstream `dtag_is_simd` /
    `dtag_to_dtype` guards will raise — the failure is local, not silent.
    """
    comptime r = reflect[T]
    var cols = List[ColDescriptor]()
    comptime ts = r.field_types()
    comptime for i in range(r.field_count()):
        comptime nm = String(r.field_names()[i])
        comptime tag = _dtag_for[ts[i]]()
        cols.append(_NN(nm, tag))
    return SchemaDescriptor(cols^)
