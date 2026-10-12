# =============================================================================
# ⛔ INTEGER `+ - *` IS A PARTIAL FUNCTION — the ONE overflow predicate, and the
#    ONE sentence every route raises with.
# =============================================================================
#
# `SELECT a + b` over an INT64 column holding 9223372036854775807 must not
# answer -9223372036854775808. Adding into a 64-bit register with a bare `+`
# WRAPS (two's complement), and a wrapped total is a plausible number no
# consumer can tell from a real one — the most severe class of silent wrong
# answer.
#
# ============================== THE ORACLES, MEASURED =========================
#
#   DuckDB 1.5.3   RAISES, naming the operation, the type and both operands:
#                  `Out of Range Error: Overflow in addition of INT64
#                   (9223372036854775807 + 1)!` — and the same sentence shape for
#                  subtraction / multiplication and INT8..INT64 / UINT8..UINT64.
#   polars 1.44.2  WRAPS silently (a+b, a-b, a*b, -a, sum, cum_sum, group sum).
#   pandas 3.0.6   WRAPS silently, numpy int64 AND the nullable Int64 alike, no
#                  warning.
#
# The SQL frontend and the untyped Mojo API answer like DuckDB, so they RAISE.
# The pandas- and polars-style frontends answer like their library where they
# can and REFUSE BY NAME where they cannot — and a wrapping mode is a thing
# this engine does not have, so there the same raise IS the named refusal: an
# error, never a different number.
#
# ============================== THE PREDICATES ================================
#
# ★ ADD / SUB ARE TESTS ON THE WRAPPED RESULT, NOT RANGE PRECHECKS. Signed
#   `a + b` overflowed iff both addends share a sign the sum does not:
#   `(a ^ r) & (b ^ r)` has its SIGN BIT set on exactly that case. Signed
#   `a - b` overflowed iff `(a ^ b) & (a ^ r)` has it set. The unsigned twins
#   are the carry / borrow out of the top bit. Three ALU ops, SIMD-friendly, and
#   the bits can be OR-accumulated across a whole column and tested ONCE — which
#   is what keeps the checked column kernels in `arithmetic.mojo` vectorized.
#   Same shape as `komira_engine_operators/int_sum_overflow.i64_add_overflows`,
#   the integer-`sum()` predicate, which this generalises over every width.
#
# ★ MUL IS EXACT BY WIDENING (a 128-bit product in 256 bits, a 64-bit one in
#   128, a <=32-bit one in 64; 256-bit operands, with nothing wider, test by
#   dividing the wrapped product back). The column kernels do not widen every
#   lane: they SCREEN with a Float64 product and widen only when the screen
#   says "maybe" (see
#   `mul_screen_limit`).
#
# ⛔ `is_int_overflow_error` EXISTS FOR ONE KIND OF CALLER: a route that turns a
#   raise into a DECLINE (`compute_project._eval_computed_column` swallows every
#   raise of its walker and falls back). An overflow is not "this route cannot
#   evaluate the shape" — no route can, because the value does not exist — so
#   such a caller re-raises it instead of declining into a fallback that would
#   either answer the wrapped number or refuse under a different name.
# =============================================================================

from std.sys import bit_width_of


comptime INT_OVERFLOW_ERROR_PREFIX = "Out of Range Error: Overflow in "
"""The stem every integer-overflow refusal in this engine starts with —
DuckDB 1.5.3's own words. `eval_div`'s MIN / -1 refusal shares it."""


def int_type_name[dtype: DType]() -> String:
    """DuckDB's physical-type spelling in an overflow message (`INT64`, not
    `BIGINT`) — measured: `Overflow in addition of INT64 (...)`,
    `... of UINT32 (...)`, `... of INT8 (...)`."""
    comptime if dtype == DType.int64:
        return "INT64"
    elif dtype == DType.int32:
        return "INT32"
    elif dtype == DType.int16:
        return "INT16"
    elif dtype == DType.int8:
        return "INT8"
    elif dtype == DType.uint64:
        return "UINT64"
    elif dtype == DType.uint32:
        return "UINT32"
    elif dtype == DType.uint16:
        return "UINT16"
    elif dtype == DType.uint8:
        return "UINT8"
    else:
        return String(dtype)


def int_overflow_message[
    dtype: DType
](op_word: String, a: Scalar[dtype], sym: String, b: Scalar[dtype]) -> String:
    """`Out of Range Error: Overflow in addition of INT64 (9223372036854775807 + 1)!`
    — byte-for-byte DuckDB 1.5.3's sentence for the same operands."""
    return (
        INT_OVERFLOW_ERROR_PREFIX
        + op_word
        + " of "
        + int_type_name[dtype]()
        + " ("
        + String(a)
        + " "
        + sym
        + " "
        + String(b)
        + ")!"
    )


def is_int_overflow_error(msg: String) -> Bool:
    """True iff `msg` is an integer-overflow refusal (see the header: a route
    that declines on a raise must re-raise THIS one)."""
    return INT_OVERFLOW_ERROR_PREFIX in msg


# -----------------------------------------------------------------------------
# Lane-wise overflow bits — the TOP bit of the result is the verdict.
# -----------------------------------------------------------------------------


@always_inline
def add_overflow_bits[
    dtype: DType, w: Int
](a: SIMD[dtype, w], b: SIMD[dtype, w], r: SIMD[dtype, w]) -> SIMD[dtype, w]:
    """`r` is the WRAPPED `a + b`. The top bit of each lane is set iff that
    lane's addition left `dtype`'s range."""
    comptime if dtype.is_signed():
        return (a ^ r) & (b ^ r)
    else:
        # carry out of the top bit
        return (a & b) | ((a | b) & ~r)


@always_inline
def sub_overflow_bits[
    dtype: DType, w: Int
](a: SIMD[dtype, w], b: SIMD[dtype, w], r: SIMD[dtype, w]) -> SIMD[dtype, w]:
    """`r` is the WRAPPED `a - b`. Top bit set iff the subtraction overflowed."""
    comptime if dtype.is_signed():
        return (a ^ b) & (a ^ r)
    else:
        # borrow out of the top bit
        return (~a & b) | (~(a ^ b) & r)


@always_inline
def top_bit_set[dtype: DType](bits: Scalar[dtype]) -> Bool:
    """True iff the top (sign) bit of `bits` is set — the reduction of an
    OR-accumulated `add_overflow_bits` / `sub_overflow_bits`."""
    comptime shift = bit_width_of[dtype]() - 1
    return (bits >> Scalar[dtype](shift)) & Scalar[dtype](1) != Scalar[dtype](0)


def mul_screen_limit[dtype: DType]() -> Float64:
    """A product whose Float64 magnitude is BELOW this cannot have overflowed.

    For widths up to 32 bits the Float64 product of two operands is exact far
    past the limit (|a*b| <= 2^64 needs only 53 significant bits at the limit's
    scale), so the limit IS the type's bound. For 64-bit operands each
    conversion and the product round (relative error <= 3 * 2^-53), so the limit
    backs off one binade — 2^62 for INT64, 2^63 for UINT64 — and everything at
    or above it is re-checked EXACTLY. The screen can only say "maybe", never
    "no" when the answer is yes.
    """
    comptime bits = bit_width_of[dtype]()
    comptime if dtype.is_signed():
        comptime if bits >= 64:
            return Float64(4611686018427387904.0)  # 2^62
        else:
            return Float64(1 << (bits - 1))
    else:
        comptime if bits >= 64:
            return Float64(9223372036854775808.0)  # 2^63
        else:
            return Float64(1 << bits)


@always_inline
def mul_screen[
    dtype: DType, w: Int
](a: SIMD[dtype, w], b: SIMD[dtype, w]) -> SIMD[DType.float64, w]:
    """|a * b| in Float64 — compared against `mul_screen_limit`."""
    return abs(a.cast[DType.float64]() * b.cast[DType.float64]())


# -----------------------------------------------------------------------------
# Exact scalar predicates + checked scalar ops (the row-at-a-time routes).
# -----------------------------------------------------------------------------


@always_inline
def add_overflows[dtype: DType](a: Scalar[dtype], b: Scalar[dtype]) -> Bool:
    comptime if not dtype.is_integral():
        return False
    else:
        return top_bit_set[dtype](add_overflow_bits[dtype, 1](a, b, a + b))


@always_inline
def sub_overflows[dtype: DType](a: Scalar[dtype], b: Scalar[dtype]) -> Bool:
    comptime if not dtype.is_integral():
        return False
    else:
        return top_bit_set[dtype](sub_overflow_bits[dtype, 1](a, b, a - b))


@always_inline
def _mul_overflows_by_division[dtype: DType](a: Scalar[dtype], b: Scalar[dtype]) -> Bool:
    """EXACT for a width with no wider integer type (256 bits): the wrapped
    product divided back by `a` returns `b` iff nothing wrapped. MIN * -1 is
    tested first: its quotient MIN / -1 is itself an overflow."""
    if a == Scalar[dtype](0):
        return False
    comptime if dtype.is_signed():
        if a == Scalar[dtype](-1):
            return b == Scalar[dtype].MIN
    return (a * b) / a != b


@always_inline
def mul_overflows[dtype: DType](a: Scalar[dtype], b: Scalar[dtype]) -> Bool:
    """EXACT: the product in twice the width, compared against the range.
    ⛔ 128-bit operands widen to 256 bits, not 128 (2^100 * 2^100 read as no
    overflow); 256-bit ones have no wider type and test by division."""
    comptime if not dtype.is_integral():
        return False
    else:
        comptime bits = bit_width_of[dtype]()
        comptime if bits > 128:
            return _mul_overflows_by_division[dtype](a, b)
        elif dtype.is_signed():
            comptime if bits == 128:
                var p = a.cast[DType.int256]() * b.cast[DType.int256]()
                return p > Scalar[dtype].MAX.cast[DType.int256]() or p < Scalar[
                    dtype
                ].MIN.cast[DType.int256]()
            elif bits >= 64:
                var p = a.cast[DType.int128]() * b.cast[DType.int128]()
                return p > Scalar[dtype].MAX.cast[DType.int128]() or p < Scalar[
                    dtype
                ].MIN.cast[DType.int128]()
            else:
                var p = a.cast[DType.int64]() * b.cast[DType.int64]()
                return p > Scalar[dtype].MAX.cast[DType.int64]() or p < Scalar[
                    dtype
                ].MIN.cast[DType.int64]()
        else:
            comptime if bits == 128:
                var p = a.cast[DType.uint256]() * b.cast[DType.uint256]()
                return p > Scalar[dtype].MAX.cast[DType.uint256]()
            elif bits >= 64:
                var p = a.cast[DType.uint128]() * b.cast[DType.uint128]()
                return p > Scalar[dtype].MAX.cast[DType.uint128]()
            else:
                var p = a.cast[DType.uint64]() * b.cast[DType.uint64]()
                return p > Scalar[dtype].MAX.cast[DType.uint64]()


def checked_add[dtype: DType](a: Scalar[dtype], b: Scalar[dtype]) raises -> Scalar[dtype]:
    """`a + b`, RAISING DuckDB's sentence where an integral sum leaves the type.
    A float sum is IEEE and never raises."""
    comptime if dtype.is_integral():
        if add_overflows[dtype](a, b):
            raise Error(int_overflow_message[dtype]("addition", a, "+", b))
    return a + b


def checked_sub[dtype: DType](a: Scalar[dtype], b: Scalar[dtype]) raises -> Scalar[dtype]:
    """`a - b`, RAISING where an integral difference leaves the type."""
    comptime if dtype.is_integral():
        if sub_overflows[dtype](a, b):
            raise Error(int_overflow_message[dtype]("subtraction", a, "-", b))
    return a - b


def checked_mul[dtype: DType](a: Scalar[dtype], b: Scalar[dtype]) raises -> Scalar[dtype]:
    """`a * b`, RAISING where an integral product leaves the type."""
    comptime if dtype.is_integral():
        if mul_overflows[dtype](a, b):
            raise Error(
                int_overflow_message[dtype]("multiplication", a, "*", b)
            )
    return a * b
