# =============================================================================
# comparisons.mojo — Highway Comparisons category (Eq / Ne / Lt / Le / Gt / Ge).
# =============================================================================
#
# Highway category: Comparisons.  Lane-parallel comparison operators
# returning `SIMD[bool, W]` mask vectors.
#
# In Mojo, `SIMD[T, W>1]` does NOT define infix
# comparison operators — `a > b` fails with `"Strict inequality is only
# defined for Scalars; did you mean to use SIMD.gt(...)?"`.  The
# canonical fix is the method form (`SIMD.gt` / `.lt` / `.ge` / `.le`
# / `.eq` / `.ne`).  These wrappers expose the comparisons under the
# Highway naming taxonomy so byte-class scan code can be ported directly.
#
# Per-DType coverage:
#   - byte_eq / _ne / _lt / _le / _gt / _ge for UInt8 lanes at
#     W=16/32/64 (CSV byte-class scan + JSON quote-region detection).
#   - int_eq / _ne / _lt / _le / _gt / _ge for Int8/16/32/64 at
#     architecture-native W (e.g. SIMD[int64, 8] on AVX-512).
#   - uint_*  for UInt16/32/64 lanes (column-pruning + decode paths).
#   - float_eq / _lt / _le / _gt / _ge for Float32/64 lanes (filter
#     predicate compilation).  NOTE: float_ne is provided but caller
#     should be aware of NaN!=NaN semantics.
#
# Architecture lowering: native Mojo SIMD methods lower directly to
# the architecture compare instruction:
#   - NEON: `cmeq.16b` / `cmlt.16b` / `cmgt.16b` / ...
#   - AVX2/AVX-512 BW: `vpcmpeqb` / `vpcmpgtb` / `vpcmpb` / ...
# These are 1-cycle instructions on every supported target.
#
# Encapsulation: ALL public functions take SIMD values and return
# `SIMD[bool, W]`.  No raw pointers, no wildcard origins.
# =============================================================================


# =============================================================================
# Byte (UInt8) comparisons — the CSV + JSON byte-class scan substrate.
# =============================================================================

@always_inline
def byte_eq[W: Int](
    a: SIMD[DType.uint8, W], b: SIMD[DType.uint8, W]
) -> SIMD[DType.bool, W]:
    """Lane-parallel `a == b` for UInt8 lanes.  Highway `Eq(a, b)`."""
    return a.eq(b)


@always_inline
def byte_ne[W: Int](
    a: SIMD[DType.uint8, W], b: SIMD[DType.uint8, W]
) -> SIMD[DType.bool, W]:
    """Lane-parallel `a != b` for UInt8 lanes.  Highway `Ne(a, b)`."""
    return a.ne(b)


@always_inline
def byte_lt[W: Int](
    a: SIMD[DType.uint8, W], b: SIMD[DType.uint8, W]
) -> SIMD[DType.bool, W]:
    """Lane-parallel `a < b` for UInt8 lanes (unsigned).  Highway
    `Lt(a, b)`."""
    return SIMD.lt(a, b)


@always_inline
def byte_le[W: Int](
    a: SIMD[DType.uint8, W], b: SIMD[DType.uint8, W]
) -> SIMD[DType.bool, W]:
    """Lane-parallel `a <= b` for UInt8 lanes (unsigned).  Highway
    `Le(a, b)`."""
    return SIMD.le(a, b)


@always_inline
def byte_gt[W: Int](
    a: SIMD[DType.uint8, W], b: SIMD[DType.uint8, W]
) -> SIMD[DType.bool, W]:
    """Lane-parallel `a > b` for UInt8 lanes (unsigned).  Highway
    `Gt(a, b)`."""
    return SIMD.gt(a, b)


@always_inline
def byte_ge[W: Int](
    a: SIMD[DType.uint8, W], b: SIMD[DType.uint8, W]
) -> SIMD[DType.bool, W]:
    """Lane-parallel `a >= b` for UInt8 lanes (unsigned).  Highway
    `Ge(a, b)`."""
    return SIMD.ge(a, b)


# =============================================================================
# Signed integer comparisons (Int8/16/32/64).
# =============================================================================

@always_inline
def int_eq[T: DType, W: Int](
    a: SIMD[T, W], b: SIMD[T, W]
) -> SIMD[DType.bool, W]:
    """Lane-parallel `a == b` for signed integer lanes.  Highway `Eq(a, b)`."""
    return a.eq(b)


@always_inline
def int_ne[T: DType, W: Int](
    a: SIMD[T, W], b: SIMD[T, W]
) -> SIMD[DType.bool, W]:
    """Lane-parallel `a != b` for signed integer lanes.  Highway `Ne(a, b)`."""
    return a.ne(b)


@always_inline
def int_lt[T: DType, W: Int](
    a: SIMD[T, W], b: SIMD[T, W]
) -> SIMD[DType.bool, W]:
    """Lane-parallel `a < b` for signed integer lanes.  Highway `Lt(a, b)`."""
    return SIMD.lt(a, b)


@always_inline
def int_le[T: DType, W: Int](
    a: SIMD[T, W], b: SIMD[T, W]
) -> SIMD[DType.bool, W]:
    """Lane-parallel `a <= b` for signed integer lanes.  Highway `Le(a, b)`."""
    return SIMD.le(a, b)


@always_inline
def int_gt[T: DType, W: Int](
    a: SIMD[T, W], b: SIMD[T, W]
) -> SIMD[DType.bool, W]:
    """Lane-parallel `a > b` for signed integer lanes.  Highway `Gt(a, b)`."""
    return SIMD.gt(a, b)


@always_inline
def int_ge[T: DType, W: Int](
    a: SIMD[T, W], b: SIMD[T, W]
) -> SIMD[DType.bool, W]:
    """Lane-parallel `a >= b` for signed integer lanes.  Highway `Ge(a, b)`."""
    return SIMD.ge(a, b)


# =============================================================================
# Float comparisons (Float32/64).
# =============================================================================
#
# IEEE-754 ordered comparisons.  `float_ne` returns True for NaN!=NaN
# (per IEEE-754; differs from Highway's `Ne` which also returns True
# for NaN inputs — consistent with the IEEE standard).

@always_inline
def float_eq[T: DType, W: Int](
    a: SIMD[T, W], b: SIMD[T, W]
) -> SIMD[DType.bool, W]:
    """Lane-parallel `a == b` for float lanes (Highway `Eq`).

    NaN-vs-anything returns False per IEEE-754."""
    return a.eq(b)


@always_inline
def float_ne[T: DType, W: Int](
    a: SIMD[T, W], b: SIMD[T, W]
) -> SIMD[DType.bool, W]:
    """Lane-parallel `a != b` for float lanes (Highway `Ne`).

    NaN-vs-anything returns True per IEEE-754."""
    return a.ne(b)


@always_inline
def float_lt[T: DType, W: Int](
    a: SIMD[T, W], b: SIMD[T, W]
) -> SIMD[DType.bool, W]:
    """Lane-parallel `a < b` for float lanes (Highway `Lt`)."""
    return SIMD.lt(a, b)


@always_inline
def float_le[T: DType, W: Int](
    a: SIMD[T, W], b: SIMD[T, W]
) -> SIMD[DType.bool, W]:
    """Lane-parallel `a <= b` for float lanes (Highway `Le`)."""
    return SIMD.le(a, b)


@always_inline
def float_gt[T: DType, W: Int](
    a: SIMD[T, W], b: SIMD[T, W]
) -> SIMD[DType.bool, W]:
    """Lane-parallel `a > b` for float lanes (Highway `Gt`)."""
    return SIMD.gt(a, b)


@always_inline
def float_ge[T: DType, W: Int](
    a: SIMD[T, W], b: SIMD[T, W]
) -> SIMD[DType.bool, W]:
    """Lane-parallel `a >= b` for float lanes (Highway `Ge`)."""
    return SIMD.ge(a, b)
