# =============================================================================
# literal_domain — is an INT64 plan literal representable at a column's PHYSICAL
# integer width?
# =============================================================================
#
# `ScalarValue.int_val` is an Int64 and every integer literal the plan wire can
# carry arrives in it. The executor's narrow arms read it at the COLUMN's width.
# Reading it with `Int32(Int(lit_val.int_val))` is not a check — it is a
# TRUNCATION TO THE LOW 32 BITS: `x = 4294967296` would execute as `x = 0`,
# select the wrong rows, and raise nothing.
#
# ============================== THE RULE, DERIVED =============================
#
#     A comparison, a membership probe, or an arithmetic op between a value of
#     physical type T and a literal L must be evaluated in a domain that
#     CONTAINS BOTH OPERANDS.
#
# So when L is not exactly representable in T the narrow arm may not be used:
# the operation WIDENS to the literal's own domain (int64). It never narrows the
# literal. Callers ask `int_literal_fits[dtype]` and take the widened path when
# the answer is False.
#
# `int_literal_fits` is a ROUND TRIP THROUGH THE TYPE, not a table of bounds. A
# hand-written `v > 2147483647 or v < -2147483648` ladder is exactly the shape
# that leaves one width wrong on the day a width is added. The round
# trip is total over the integral family by construction: instantiate it at
# int8, int16, int32, int64 or any unsigned width and it needs no new constant.
#
# ⚠ WHAT IT IS NOT. It answers "is this value exactly representable", NOT "is
# this comparison satisfiable". A caller that wants the second must widen and
# ask the kernel; there is no clamping here, because clamping is WRONG for `=`
# and `<>` (2^32 clamped to INT32_MAX makes `x = INT32_MAX` true for a row the
# real predicate excludes).
# =============================================================================


@always_inline
def int_literal_fits[dtype: DType](v: Int64) -> Bool:
    """True iff the INT64 literal `v` is EXACTLY representable in `dtype`.

    Parameters:
        dtype: The column's physical integer DType.

    Args:
        v: The literal, at the width the plan wire carries it.

    Returns:
        True when narrowing `v` to `dtype` loses nothing — i.e. when the narrow
        kernel arm may be used. False means the caller must WIDEN the operation
        (see this module's header); it does NOT mean the literal is invalid.
    """
    comptime if not dtype.is_integral():
        # A non-integral dtype has no integer domain to be in. Answering False
        # routes such a caller to its WIDE path, which is the safe direction —
        # this function must never hand a float arm a narrowing licence.
        return False

    comptime if dtype == DType.int64:
        # The literal's own width — the round trip below is the identity, but
        # spelling it out keeps the hot INT64 arm free of any conversion.
        return True

    comptime if not dtype.is_signed():
        # THE ONE CASE THE ROUND TRIP CANNOT SEE ON ITS OWN: two's complement
        # makes `-1 -> UInt64 -> Int64` land back on -1, so a negative literal
        # would report as fitting an unsigned domain it is not in. The sign is
        # asked separately; the magnitude still goes through the round trip.
        if v < 0:
            return False

    return Scalar[DType.int64](v).cast[dtype]().cast[DType.int64]() == v
