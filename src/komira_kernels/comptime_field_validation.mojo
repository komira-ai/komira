# =============================================================================
# comptime_field_validation.mojo — comptime guards for SimdOf typed accessors
# =============================================================================
#
# Comptime-only assertions that a struct field at index `i` matches a given
# `DType`. Used by `simd_of.mojo`'s typed get/set accessors so that a typo
# (`get_f64[2]()` on a struct whose field 2 is `Int64`) becomes a compile
# error rather than a silent wrong-dtype byte read.
#
# Pure comptime — zero runtime cost. The `constrained[]` calls compile out
# entirely on success and emit a compile error on failure with the message
# string included.
#
# Mojo idioms:
#   - `from sys.intrinsics import _type_is_eq` is the canonical type-equality
#     predicate for AnyType-erased types (Reflected.field_types() returns
#     `TypeList`, an `AnyType`-erased element list).
#   - `constrained[bool, "msg"]()` works in 1.0.0b1.
#   - `comptime if/elif/else` cascades on `DType` values are valid (DType
#     supports `==` at comptime).
# =============================================================================



def _dtype_matches[FieldT: AnyType, dt: DType]() -> Bool:
    """True iff the Mojo scalar type FieldT corresponds to the DType `dt`.

    Comptime-callable. Used by `comptime_field_validation` and the
    `SimdOf` typed accessor cascade. Add new dtypes here as the
    SimdOf accessor surface grows.
    """
    comptime if dt == DType.float64:
        return (FieldT == Float64)
    elif dt == DType.float32:
        return (FieldT == Float32)
    elif dt == DType.int64:
        return (FieldT == Int64)
    elif dt == DType.int32:
        return (FieldT == Int32)
    elif dt == DType.int16:
        return (FieldT == Int16)
    elif dt == DType.int8:
        return (FieldT == Int8)
    elif dt == DType.uint64:
        return (FieldT == UInt64)
    elif dt == DType.uint32:
        return (FieldT == UInt32)
    elif dt == DType.uint16:
        return (FieldT == UInt16)
    elif dt == DType.uint8:
        return (FieldT == UInt8)
    elif dt == DType.bool:
        return (FieldT == Bool)
    return False


def comptime_field_validation[
    T: AnyType & Copyable & Movable, i: Int, expected: DType
]():
    """Assert at comptime that:
      1. `i` is in `[0, reflect[T]().field_count())`.
      2. The Mojo type at field index `i` of T matches `expected`.

    Failure emits a compile-time error including the message string.
    Pure comptime — zero runtime cost on success (the asserts compile
    out entirely).

    Used by SimdOf's typed accessors (e.g. `get_f64[i]()` calls
    `comptime_field_validation[Self.T, i, DType.float64]()`) so that
    a wrong-dtype read fails at compile, not silently misreads bytes.

    Example:

        @fieldwise_init
        struct LineItemRow(Copyable, Movable):
            var price: Float64
            var qty: Int64
            var disc: Float64

        # OK — field 0 is Float64
        comptime_field_validation[LineItemRow, 0, DType.float64]()

        # Compile error — field 1 is Int64, not Float64
        # comptime_field_validation[LineItemRow, 1, DType.float64]()
    """
    comptime r = reflect[T]
    comptime assert i >= 0 and i < r.field_count(), ("comptime_field_validation: field index out of range for T")
    comptime ts = r.field_types()
    comptime assert _dtype_matches[ts[i], expected](), ("comptime_field_validation: field dtype mismatch (T's field at i is not the expected DType)")
