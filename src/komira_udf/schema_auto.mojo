# =============================================================================
# schema_auto.mojo — reflection-driven SchemaDescriptor derivation
# =============================================================================
#
# `auto_schema[T]()` walks `reflect[T]()` and produces a `SchemaDescriptor`
# (column names + dtype tags) for any `@fieldwise_init` row struct whose
# fields are scalar Mojo types.
#
# For example, LineItemRow{price:F64, qty:I64, disc:F64} yields the expected
# 3-column schema.
#
# Edge dtypes (Date32, Decimal128, Timestamp, list, struct) are NOT auto-
# derivable because the Mojo type system doesn't carry the disambiguating
# metadata (e.g. precision/scale on Int128, calendar interpretation on
# Int32). For these, the user provides a `@staticmethod fn __schema__()`
# on T. `auto_schema` returns
# `DT_UNKNOWN` for unrecognized types and the caller MUST follow up with
# the override path. The `comptime constrained[]` in `auto_schema` enforces
# this — auto-derivation of an unsupported field is a compile error.
#
# Mojo idioms:
#   - `reflect[T]()` returns `Reflected[T]` with `field_count()`,
#     `field_names() -> List[StaticString]`, `field_types() -> TypeList`.
#   - `comptime for i in range(r.field_count())` iterates a comptime range.
#   - `r.field_names()[i]` returns `StaticString` -> wrap in `String(...)`
#     for runtime use.
#   - `r.field_types()[i]` is an AnyType-erased element usable as a T param
#     for `(ts[i] == Float64)`.
#   - `comptime if/elif/else` cascades on `(T1 == T2)` are valid.
# =============================================================================


from komira_udf.schema_descriptor import (
    SchemaDescriptor,
    ColDescriptor,
    DT_F32,
    DT_F64,
    DT_I8,
    DT_I16,
    DT_I32,
    DT_I64,
    DT_U8,
    DT_U16,
    DT_U32,
    DT_U64,
    DT_BOOL,
    DT_STRING,
    DT_UNKNOWN,
)


def dtype_tag_for_type[T: AnyType]() -> Int:
    """Map a Mojo scalar type to its `DT_*` dtype tag.

    Comptime-only. Returns `DT_UNKNOWN` for types that cannot be uniquely
    identified from the bare Mojo type (Date32, Timestamp, Decimal128,
    nested types). Callers `comptime constrained[tag != DT_UNKNOWN, ...]()`
    or fall back to user-defined `__schema__()`.

    Add new dtypes here as the SimdOf typed-accessor surface grows.
    """
    comptime if (T == Float64):
        return DT_F64
    elif (T == Float32):
        return DT_F32
    elif (T == Int64):
        return DT_I64
    elif (T == Int32):
        return DT_I32
    elif (T == Int16):
        return DT_I16
    elif (T == Int8):
        return DT_I8
    elif (T == UInt64):
        return DT_U64
    elif (T == UInt32):
        return DT_U32
    elif (T == UInt16):
        return DT_U16
    elif (T == UInt8):
        return DT_U8
    elif (T == Bool):
        return DT_BOOL
    elif (T == String):
        return DT_STRING
    return DT_UNKNOWN


def auto_schema[
    RowT: AnyType & Copyable & Movable
]() -> SchemaDescriptor:
    """Derive a `SchemaDescriptor` from `RowT`'s fields via reflection.

    Field names come from `reflect[RowT]().field_names()`; dtype tags
    come from `dtype_tag_for_type[FieldT]()`. Nullable defaults to True
    (the engine's runtime check at first batch refines this against the
    parent DataFrame's actual schema).

    Compile-fails (via `constrained[]`) if any field's Mojo type maps to
    `DT_UNKNOWN` — the user must either change the field's Mojo type to
    a supported scalar OR provide a `@staticmethod fn __schema__()` on
    RowT. Detection of `__schema__` overrides
    is at the engine boundary.

    Example:

        @fieldwise_init
        struct LineItemRow(Copyable, Movable):
            var price: Float64
            var qty: Int64
            var disc: Float64

        comptime s = auto_schema[LineItemRow]()
        # s.cols = [
        #   ColDescriptor("price", DT_F64, True),
        #   ColDescriptor("qty",   DT_I64, True),
        #   ColDescriptor("disc",  DT_F64, True),
        # ]
    """
    comptime r = reflect[RowT]
    var cols = List[ColDescriptor]()
    comptime ts = r.field_types()
    comptime for i in range(r.field_count()):
        comptime nm = String(r.field_names()[i])
        comptime tag = dtype_tag_for_type[ts[i]]()
        comptime assert tag != DT_UNKNOWN, ("auto_schema: unsupported scalar dtype for field. Use Mechanism B (RowT.__schema__()) or change the field's Mojo type.")
        cols.append(ColDescriptor(nm, tag, True))
    return SchemaDescriptor(cols^)
