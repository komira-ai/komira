# =============================================================================
# SIMD Arithmetic & Logical Expression Evaluators
# =============================================================================
#
# Buffer access pattern:
#   - eval_and / eval_or / eval_not read bitmaps through ByteViews
#     (`view_ro` / `view_mut` + `load_simd`) captured into vectorize closures.
#   - eval_revenue_sum, eval_filtered_revenue_sum and filtered_sum read
#     columns through `load[W]`; bitmap bytes through `read_u8_at`.
#   - eval_add / eval_sub / eval_mul / eval_div and their `_scalar` variants
#     hold origin-tied `view_ro/mut()` ByteView locals in function scope and
#     capture a typed pointer (`_unsafe_ptr()` + `bitcast[Scalar[T]]`) into
#     the `vectorize` closure by value through an explicit
#     `{var left_ptr, ...}` capture list (UnsafePointer is
#     ImplicitlyCopyable + Movable). The borrow keeps the buffer alive across
#     every closure invocation; SIMD codegen is the same as a raw pointer.
# =============================================================================

from std.algorithm import vectorize
from std.sys import simd_width_of

from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.boolean_array import BooleanArray
from komira_buffer.heap_region import HeapRegion
from komira_arrow.bitmap import Bitmap, bytes_for_bits
from komira_buffer.constants import SIMD_WIDTH_U8, SIMD_WIDTH_F64
from komira_scalar_arithmetic.int_overflow import (
    add_overflow_bits,
    sub_overflow_bits,
    top_bit_set,
    mul_screen,
    mul_screen_limit,
    add_overflows,
    sub_overflows,
    mul_overflows,
    int_overflow_message,
)


# =============================================================================
# ★ INTEGER DIVISION IS A PARTIAL FUNCTION — the guard, and why it is here
# =============================================================================
#
# An unguarded `qty / 0` over an integer column reaches
# `eval_div_scalar[int64]` and hands a zero divisor to the machine's division
# instruction, which kills the process with a signal.
#
# ⚠ THE TRAP IS ARCHITECTURE-DEPENDENT, so "it works on my machine" is not
# evidence here. x86-64 `idiv` by zero raises #DE -> SIGFPE; arm64 `sdiv` by
# zero returns 0 and does not trap. The SAME source is a process kill on every
# Linux deployment and a SILENT WRONG ANSWER on a developer mac. The guard
# below fixes both, because it never lets the machine see the zero at all.
#
# ============================== THE RULE, DERIVED =============================
#
# The rule is NOT "int64 division is special". It is a property of the dtype:
#
#     an INTEGRAL dtype has no representable answer for a zero divisor,
#     and (when signed) none for MIN / -1 either.
#
# So the guard keys on `dtype.is_integral()` / `dtype.is_signed()` at comptime
# and is therefore total over the dtype family BY CONSTRUCTION -- int8, int16,
# int32, int64, and the unsigned widths, today and on the day a new width is
# added. A hand-written ladder of dtypes is exactly the shape that leaves one
# arm trapping, so there is no ladder here.
#
# FLOAT IS DELIBERATELY UNTOUCHED. IEEE 754 division is already total and
# already agrees with the oracle, so `@parameter if dtype.is_integral()`
# compiles the guard OUT of every float kernel: zero added instructions on the
# f64 path that the benchmarks live on.
#
# ============================ THE ORACLE, MEASURED ============================
#
# DuckDB v1.5.3 gives the two failure modes DIFFERENT answers -- they are not
# one case:
#
#     select qty//z, qty%z from t;          -- z = 0      ->  NULL, NULL
#     select (-9223372036854775808)//(-1);  -- MIN / -1   ->  Out of Range Error
#
# so this file answers NULL for a zero divisor and RAISES for MIN / -1, which
# is what the oracle does. Answering NULL for the overflow would be a quieter
# divergence than the crash it replaces.
#
# ⚠ ONE DIVERGENCE IS OPEN AND DELIBERATE: DuckDB's `/` on two BIGINTs returns
# DOUBLE (7/2 = 3.5); this engine's BIN_DIV on I64 returns I64 (7/2 = 3).
# Changing the RESULT TYPE of `/` moves every arithmetic expression and is a
# separate decision from this guard. A regression test pins the truncating
# behaviour so it cannot drift unnoticed.
#
# ============================== THE COST, STATED =============================
#
# The integral path pays ONE extra streaming compare pass over the divisor
# (`_scan_int_divisor`) before dividing. It is a compare-and-reduce at ~1
# cycle/element against an integer division at ~20-40, and when it finds
# nothing -- the overwhelmingly common case -- the ORIGINAL kernel runs
# unchanged and the result carries NO validity bitmap, so nothing downstream
# sees a new null mask. A regression test asserts that.
# =============================================================================


comptime _DIV_SCAN_CLEAN: Int = 0
"""No zero divisor and no MIN/-1 overflow — run the original kernel."""

comptime _DIV_SCAN_HAS_ZERO: Int = 1
"""Some row must not be handed to a division instruction — take the guarded
path and build validity. Either a zero divisor, or a partial pair sitting on a
row that is NULL (see `_scan_int_divisor`)."""


@always_inline
def _scan_int_divisor[
    dtype: DType
](left: PrimitiveArray[dtype], right: PrimitiveArray[dtype]) raises -> Int:
    """Classify a divisor column before any division instruction runs.

    Returns `_DIV_SCAN_CLEAN` or `_DIV_SCAN_HAS_ZERO`; RAISES on a signed
    MIN / -1 pair whose BOTH OPERANDS ARE VALID, matching DuckDB v1.5.3's
    "Out of Range Error".

    ⚠ THE ORDER MATTERS AND IS NOT AN ACCIDENT: this runs to completion BEFORE
    the caller divides, so the overflow raise happens instead of the trap
    rather than after it. Checking inside the kernel would be too late — the
    faulting instruction is the one being guarded.

    ★ A NULL ROW'S PAYLOAD IS NOT AN OPERAND.
    Arrow leaves a null slot's payload unspecified, and an arithmetic result, a
    join-carried column or an Arrow-IPC input can all put a real value under a
    cleared validity bit. A NULL divisor holding -1 beside a dividend of MIN is
    therefore not a MIN / -1 division at all — the row's answer is NULL by
    null-propagation — and raising "Out of Range Error" for it kills a query
    over an overflow the engine was never asked to perform. So the RAISE is
    conditioned on both operands being VALID.

    ⚠ THE ZERO TEST IS **NOT** CONDITIONED ON VALIDITY, AND THAT ASYMMETRY IS
    THE WHOLE SAFETY ARGUMENT. `_DIV_SCAN_CLEAN` hands the column to the
    unguarded vectorized kernel, which divides EVERY row — a null one included.
    A zero payload under a null bit that this scan chose to skip would then
    reach `idiv` and trap, which is the process kill the guard exists to
    prevent. So a payload that cannot be divided still routes to the guarded
    path; only the RAISE, which is a user-visible ANSWER, asks about validity.
    Same reason a null-row (MIN, -1) pair returns `_DIV_SCAN_HAS_ZERO` instead
    of `_DIV_SCAN_CLEAN`: it must not be divided either.
    """
    var n = left.length
    var lo = left.view_ro()
    var ro = right.view_ro()
    var lp = lo._unsafe_ptr().bitcast[Scalar[dtype]]()
    var rp = ro._unsafe_ptr().bitcast[Scalar[dtype]]()
    var zero = Scalar[dtype](0)
    var found_zero = False
    # Hoisted: with no bitmap on either side every row is valid and the
    # per-row `is_null` calls are skipped entirely (the hot path is unchanged).
    var any_nullable = left.validity.__bool__() or right.validity.__bool__()
    for i in range(n):
        var b = rp.load[width=1](i)
        if b == zero:
            found_zero = True
            continue

        comptime if dtype.is_signed():
            # MIN / -1 overflows the signed range and raises #DE on x86-64,
            # the same trap as the zero divisor and a different answer.
            if b == Scalar[dtype](-1):
                if lp.load[width=1](i) == Scalar[dtype].MIN:
                    if any_nullable and (
                        left.is_null(i) or right.is_null(i)
                    ):
                        # NULL row: the answer is NULL, not an overflow — but
                        # the pair still may not reach a division instruction.
                        found_zero = True
                        continue
                    raise Error(
                        "eval_div: Out of Range Error: Overflow in division"
                        " of MIN / -1 at row "
                        + String(i)
                    )
    return _DIV_SCAN_HAS_ZERO if found_zero else _DIV_SCAN_CLEAN


@always_inline
def _all_null_like[
    dtype: DType
](length: Int) -> PrimitiveArray[dtype]:
    """An all-NULL result of `length` rows. No division is performed at all.

    Used when the divisor is a zero SCALAR: every row's answer is NULL, so
    there is nothing to compute and nothing to trap on.
    """
    var out = PrimitiveArray[dtype].allocate_nullable(length)
    ref bm = out.validity.value()
    for i in range(length):
        bm.clear(i)
    out.null_count = length
    return out^


# =============================================================================
# ⛔ INTEGER `+ - *` RAISE ON OVERFLOW — the checked column kernels
# =============================================================================
#
# Storing `a + b` straight from a SIMD register would return an INT64
# `MAX + 1` as MIN — a SILENT wrong answer. DuckDB 1.5.3 raises
# `Out of Range Error: Overflow in addition of INT64 (...)!` and that is what
# every INTEGRAL dtype does here; the predicates and the sentence live ONCE,
# in `int_overflow.mojo`.
#
# ★ IT STAYS VECTORIZED, AND THAT IS THE WHOLE DESIGN. The loop below is the plain
# `a + b` store plus ONE extra lane-wise expression OR-ed into a SIMD
# accumulator — `(a ^ r) & (b ^ r)` for add, `(a ^ b) & (a ^ r)` for sub — and
# the accumulator's top bit is tested ONCE per column, after the loop. No branch
# in the loop, no per-row compare. `*` has no cheap exact lane-wise test at 64
# bits, so it keeps a lane-wise MAX of the Float64 product's magnitude (a
# SCREEN: below `mul_screen_limit` it cannot have overflowed) and only a column
# that trips the screen is re-walked with the exact 128-bit product. Against a
# LITERAL every op is monotone in the column, so `_int_arith_cs` keeps only the
# column's min / max and checks the two extremes EXACTLY.
#
# ⚠ THE COST (10M rows): float unchanged; int64 col-col `a*b + c` ~+10%,
# col-literal `a + 7` ~+16%, and the worst case that still answers — every
# product in [2^62, 2^63), re-walked in 128 bits — ~2.5x.
#
# ★ A NULL ROW'S PAYLOAD IS NOT AN OPERAND (the `_scan_int_divisor` rule, one
# screen up). The fast loop computes every row, NULL or not — a NULL slot holds
# whatever an upstream kernel left there — so a tripped accumulator is only a
# SUSPICION. `_raise_first_overflow_*` re-walks the column, skips a row that is
# NULL on either side, and raises for the FIRST VALID row that really
# overflowed, naming its operands the way DuckDB does. If every overflowing row
# is NULL there is no raise: the wrapped payload sits under a cleared validity
# bit, which the caller's `clone_array_validity` merge already provides.
#
# FLOAT IS UNTOUCHED: `comptime if dtype.is_integral()` routes around this
# block, so the f64 kernels are byte-for-byte the vectorize bodies below.
# =============================================================================


comptime _ARITH_ADD: Int = 0
comptime _ARITH_SUB: Int = 1
comptime _ARITH_MUL: Int = 2


@always_inline
def _arith_word(op: Int) -> String:
    if op == _ARITH_ADD:
        return "addition"
    if op == _ARITH_SUB:
        return "subtraction"
    return "multiplication"


@always_inline
def _arith_sym(op: Int) -> String:
    if op == _ARITH_ADD:
        return "+"
    if op == _ARITH_SUB:
        return "-"
    return "*"


@always_inline
def _row_overflows[dtype: DType, op: Int](a: Scalar[dtype], b: Scalar[dtype]) -> Bool:
    comptime if op == _ARITH_ADD:
        return add_overflows[dtype](a, b)
    elif op == _ARITH_SUB:
        return sub_overflows[dtype](a, b)
    else:
        return mul_overflows[dtype](a, b)


def _raise_first_overflow_cc[
    dtype: DType, op: Int
](left: PrimitiveArray[dtype], right: PrimitiveArray[dtype]) raises:
    """The exact re-walk behind a tripped accumulator (col vs col). RAISES for
    the first row whose operands are BOTH valid and whose result overflowed;
    returns if there is none (every suspect row was NULL, or the MUL screen was
    conservative)."""
    var n = left.length
    # SAFETY: origin-tied read views held for the whole loop; the typed
    # pointers never leave this function.
    var lv = left.view_ro()
    var rv = right.view_ro()
    var lp = lv._unsafe_ptr().bitcast[Scalar[dtype]]()
    var rp = rv._unsafe_ptr().bitcast[Scalar[dtype]]()
    var any_nullable = left.validity.__bool__() or right.validity.__bool__()
    for i in range(n):
        if any_nullable and (left.is_null(i) or right.is_null(i)):
            continue
        var a = lp.load[width=1](i)
        var b = rp.load[width=1](i)
        if _row_overflows[dtype, op](a, b):
            raise Error(
                int_overflow_message[dtype](_arith_word(op), a, _arith_sym(op), b)
            )


def _raise_first_overflow_cs[
    dtype: DType, op: Int, scalar_left: Bool
](col: PrimitiveArray[dtype], scalar: Scalar[dtype]) raises:
    """The col-vs-LITERAL twin of `_raise_first_overflow_cc`. `scalar_left`
    says which side of the operator the literal stands on (it matters for `-`
    and for the operand order in the message)."""
    var n = col.length
    # SAFETY: as `_raise_first_overflow_cc`.
    var cv = col.view_ro()
    var cp = cv._unsafe_ptr().bitcast[Scalar[dtype]]()
    var nullable = col.validity.__bool__()
    for i in range(n):
        if nullable and col.is_null(i):
            continue
        var a: Scalar[dtype]
        var b: Scalar[dtype]
        comptime if scalar_left:
            a = scalar
            b = cp.load[width=1](i)
        else:
            a = cp.load[width=1](i)
            b = scalar
        if _row_overflows[dtype, op](a, b):
            raise Error(
                int_overflow_message[dtype](_arith_word(op), a, _arith_sym(op), b)
            )


def _int_arith_cc[
    dtype: DType, op: Int
](left: PrimitiveArray[dtype], right: PrimitiveArray[dtype]) raises -> PrimitiveArray[dtype]:
    """Checked `left (op) right` for an INTEGRAL dtype, column vs column."""
    var n = left.length
    var result = PrimitiveArray[dtype].allocate(n)
    # SAFETY: origin-tied views held in function scope keep all three buffers
    # alive across both loops; the typed pointers are internal to this function.
    var lv = left.view_ro()
    var rv = right.view_ro()
    var ov = result.view_mut()
    var lp = lv._unsafe_ptr().bitcast[Scalar[dtype]]()
    var rp = rv._unsafe_ptr().bitcast[Scalar[dtype]]()
    var op_ = ov._unsafe_ptr().bitcast[Scalar[dtype]]()
    # 4x the native width: the loop carries the accumulator (a dependency a
    # plain `vectorize` body does not have), and a 4-register-wide logical vector
    # lets LLVM keep four independent chains in flight. It measured faster than
    # both 1x and 8x.
    comptime W = simd_width_of[dtype]() * 4
    var bits = SIMD[dtype, W](0)
    var screen = SIMD[DType.float64, W](0.0)
    var i = 0
    var vend = n - (n % W)
    while i < vend:
        var a = lp.load[width=W](i)
        var b = rp.load[width=W](i)
        comptime if op == _ARITH_ADD:
            var r = a + b
            op_.store[width=W](i, r)
            bits |= add_overflow_bits[dtype, W](a, b, r)
        elif op == _ARITH_SUB:
            var r = a - b
            op_.store[width=W](i, r)
            bits |= sub_overflow_bits[dtype, W](a, b, r)
        else:
            op_.store[width=W](i, a * b)
            screen = max(screen, mul_screen[dtype, W](a, b))
        i += W
    var tail_bits = Scalar[dtype](0)
    var tail_screen = Float64(0.0)
    while i < n:
        var a = lp.load[width=1](i)
        var b = rp.load[width=1](i)
        comptime if op == _ARITH_ADD:
            var r = a + b
            op_.store[width=1](i, r)
            tail_bits |= add_overflow_bits[dtype, 1](a, b, r)
        elif op == _ARITH_SUB:
            var r = a - b
            op_.store[width=1](i, r)
            tail_bits |= sub_overflow_bits[dtype, 1](a, b, r)
        else:
            op_.store[width=1](i, a * b)
            tail_screen = max(tail_screen, mul_screen[dtype, 1](a, b)[0])
        i += 1
    var suspect: Bool
    comptime if op == _ARITH_MUL:
        suspect = (
            max(screen.reduce_max(), tail_screen) >= mul_screen_limit[dtype]()
        )
    else:
        suspect = top_bit_set[dtype](bits.reduce_or() | tail_bits)
    if suspect:
        _raise_first_overflow_cc[dtype, op](left, right)
    return result^


def _int_arith_cs[
    dtype: DType, op: Int, scalar_left: Bool
](col: PrimitiveArray[dtype], scalar: Scalar[dtype]) raises -> PrimitiveArray[dtype]:
    """Checked `col (op) scalar` (or `scalar (op) col` when `scalar_left`) for
    an INTEGRAL dtype. The literal is broadcast in a register.

    ★ THE CHECK IS THE COLUMN'S RANGE, NOT A PER-LANE PREDICATE. With one
    operand a constant, `x + s`, `x - s`, `s - x` and `x * s` are each MONOTONE
    in `x`, so the result's extremes sit at the column's own MIN and MAX. The
    loop keeps a lane-wise min and max of the column (two independent ops per
    vector, no dependency on the result) and the two extremes are checked
    EXACTLY after it (`_row_overflows`, 128-bit for `*`). A trip is re-walked
    row by row, NULLs skipped, like the col-vs-col kernel.
    """
    var n = col.length
    var result = PrimitiveArray[dtype].allocate(n)
    if n == 0:
        return result^
    # SAFETY: as `_int_arith_cc`.
    var cv = col.view_ro()
    var ov = result.view_mut()
    var cp = cv._unsafe_ptr().bitcast[Scalar[dtype]]()
    var op_ = ov._unsafe_ptr().bitcast[Scalar[dtype]]()
    # 4x the native width, as `_int_arith_cc`.
    comptime W = simd_width_of[dtype]() * 4
    var sv = SIMD[dtype, W](scalar)
    var first = cp.load[width=1](0)
    var vmin = SIMD[dtype, W](first)
    var vmax = SIMD[dtype, W](first)
    var i = 0
    var vend = n - (n % W)
    while i < vend:
        var x = cp.load[width=W](i)
        vmin = min(vmin, x)
        vmax = max(vmax, x)
        comptime if op == _ARITH_ADD:
            op_.store[width=W](i, x + sv)
        elif op == _ARITH_SUB:
            comptime if scalar_left:
                op_.store[width=W](i, sv - x)
            else:
                op_.store[width=W](i, x - sv)
        else:
            op_.store[width=W](i, x * sv)
        i += W
    var cmin = vmin.reduce_min()
    var cmax = vmax.reduce_max()
    while i < n:
        var x = cp.load[width=1](i)
        cmin = min(cmin, x)
        cmax = max(cmax, x)
        comptime if op == _ARITH_ADD:
            op_.store[width=1](i, x + scalar)
        elif op == _ARITH_SUB:
            comptime if scalar_left:
                op_.store[width=1](i, scalar - x)
            else:
                op_.store[width=1](i, x - scalar)
        else:
            op_.store[width=1](i, x * scalar)
        i += 1
    var suspect: Bool
    comptime if scalar_left:
        suspect = _row_overflows[dtype, op](scalar, cmin) or _row_overflows[
            dtype, op
        ](scalar, cmax)
    else:
        suspect = _row_overflows[dtype, op](cmin, scalar) or _row_overflows[
            dtype, op
        ](cmax, scalar)
    if suspect:
        _raise_first_overflow_cs[dtype, op, scalar_left](col, scalar)
    return result^


# =============================================================================
# Column vs Column
# =============================================================================


def eval_add[dtype: DType](left: PrimitiveArray[dtype], right: PrimitiveArray[dtype]) raises -> PrimitiveArray[dtype]:
    """Element-wise addition: left + right.

    RAISES `Out of Range Error: Overflow in ...` on an INTEGRAL overflow (see the
    checked-kernel block above). FLOAT is IEEE.
    """
    comptime if dtype.is_integral():
        return _int_arith_cc[dtype, _ARITH_ADD](left, right)

    var result = PrimitiveArray[dtype].allocate(left.length)

    # PERF-CRITICAL: origin-tied `view_ro/mut() + _unsafe_ptr() +
    # bitcast[Scalar[T]]` typed pointers. `*_view` ByteView locals
    # held in function scope so the borrow keeps the underlying buffer
    # alive across every `vectorize` closure invocation (the closure
    # captures the typed pointer by value, preserving SIMD codegen).
    var left_view = left.view_ro()
    var right_view = right.view_ro()
    var res_view = result.view_mut()
    var left_ptr = left_view._unsafe_ptr().bitcast[Scalar[dtype]]()
    var right_ptr = right_view._unsafe_ptr().bitcast[Scalar[dtype]]()
    var res_ptr = res_view._unsafe_ptr().bitcast[Scalar[dtype]]()
    comptime width = simd_width_of[dtype]()

    @always_inline
    def kernel[w: Int](idx: Int) {var left_ptr, var right_ptr, var res_ptr}:
        var a = left_ptr.load[width=w](idx)
        var b = right_ptr.load[width=w](idx)
        res_ptr.store[width=w](idx, a + b)

    vectorize[width](left.length, kernel)
    return result^


def eval_sub[dtype: DType](left: PrimitiveArray[dtype], right: PrimitiveArray[dtype]) raises -> PrimitiveArray[dtype]:
    """Element-wise subtraction: left - right.

    RAISES `Out of Range Error: Overflow in ...` on an INTEGRAL overflow (see the
    checked-kernel block above). FLOAT is IEEE.
    """
    comptime if dtype.is_integral():
        return _int_arith_cc[dtype, _ARITH_SUB](left, right)

    var result = PrimitiveArray[dtype].allocate(left.length)

    # PERF-CRITICAL: origin-tied typed pointers (see eval_add).
    # `*_view` ByteView locals
    # held in function scope so the borrow keeps the underlying buffer
    # alive across every `vectorize` closure invocation (the closure
    # captures the typed pointer by value, preserving SIMD codegen).
    var left_view = left.view_ro()
    var right_view = right.view_ro()
    var res_view = result.view_mut()
    var left_ptr = left_view._unsafe_ptr().bitcast[Scalar[dtype]]()
    var right_ptr = right_view._unsafe_ptr().bitcast[Scalar[dtype]]()
    var res_ptr = res_view._unsafe_ptr().bitcast[Scalar[dtype]]()
    comptime width = simd_width_of[dtype]()

    @always_inline
    def kernel[w: Int](idx: Int) {var left_ptr, var right_ptr, var res_ptr}:
        var a = left_ptr.load[width=w](idx)
        var b = right_ptr.load[width=w](idx)
        res_ptr.store[width=w](idx, a - b)

    vectorize[width](left.length, kernel)
    return result^


def eval_mul[dtype: DType](left: PrimitiveArray[dtype], right: PrimitiveArray[dtype]) raises -> PrimitiveArray[dtype]:
    """Element-wise multiplication: left * right.

    RAISES `Out of Range Error: Overflow in ...` on an INTEGRAL overflow (see the
    checked-kernel block above). FLOAT is IEEE.
    """
    comptime if dtype.is_integral():
        return _int_arith_cc[dtype, _ARITH_MUL](left, right)

    var result = PrimitiveArray[dtype].allocate(left.length)

    # PERF-CRITICAL: origin-tied typed pointers (see eval_add).
    # `*_view` ByteView locals
    # held in function scope so the borrow keeps the underlying buffer
    # alive across every `vectorize` closure invocation (the closure
    # captures the typed pointer by value, preserving SIMD codegen).
    var left_view = left.view_ro()
    var right_view = right.view_ro()
    var res_view = result.view_mut()
    var left_ptr = left_view._unsafe_ptr().bitcast[Scalar[dtype]]()
    var right_ptr = right_view._unsafe_ptr().bitcast[Scalar[dtype]]()
    var res_ptr = res_view._unsafe_ptr().bitcast[Scalar[dtype]]()
    comptime width = simd_width_of[dtype]()

    @always_inline
    def kernel[w: Int](idx: Int) {var left_ptr, var right_ptr, var res_ptr}:
        var a = left_ptr.load[width=w](idx)
        var b = right_ptr.load[width=w](idx)
        res_ptr.store[width=w](idx, a * b)

    vectorize[width](left.length, kernel)
    return result^


def eval_div[dtype: DType](left: PrimitiveArray[dtype], right: PrimitiveArray[dtype]) raises -> PrimitiveArray[dtype]:
    """Element-wise division: left / right.

    TOTAL on every dtype. For an INTEGRAL dtype a zero
    divisor yields NULL in that row (DuckDB v1.5.3 `//` semantics) and a
    signed MIN / -1 raises; the divisor is never handed to the machine's
    division instruction, so nothing traps. FLOAT keeps IEEE 754 +-inf / NaN
    and is not touched. See the guard block at the top of this file.
    """

    comptime if dtype.is_integral():
        # Runs BEFORE any division. Raises on MIN / -1.
        if _scan_int_divisor[dtype](left, right) == _DIV_SCAN_HAS_ZERO:
            return _eval_div_int_guarded[dtype](left, right)
        # CLEAN: fall through to the original kernel, byte-for-byte, with no
        # validity bitmap manufactured. This is the hot path.

    var result = PrimitiveArray[dtype].allocate(left.length)

    # PERF-CRITICAL: origin-tied typed pointers (see eval_add).
    # `*_view` ByteView locals
    # held in function scope so the borrow keeps the underlying buffer
    # alive across every `vectorize` closure invocation (the closure
    # captures the typed pointer by value, preserving SIMD codegen).
    var left_view = left.view_ro()
    var right_view = right.view_ro()
    var res_view = result.view_mut()
    var left_ptr = left_view._unsafe_ptr().bitcast[Scalar[dtype]]()
    var right_ptr = right_view._unsafe_ptr().bitcast[Scalar[dtype]]()
    var res_ptr = res_view._unsafe_ptr().bitcast[Scalar[dtype]]()
    comptime width = simd_width_of[dtype]()

    @always_inline
    def kernel[w: Int](idx: Int) {var left_ptr, var right_ptr, var res_ptr}:
        var a = left_ptr.load[width=w](idx)
        var b = right_ptr.load[width=w](idx)
        res_ptr.store[width=w](idx, a / b)

    vectorize[width](left.length, kernel)
    return result^


@always_inline
def _eval_div_int_guarded[
    dtype: DType
](left: PrimitiveArray[dtype], right: PrimitiveArray[dtype]) -> PrimitiveArray[dtype]:
    """`left / right` for an INTEGRAL dtype whose divisor contains a zero.

    Per-ROW, never per-column: rows with a non-zero divisor keep their real
    quotient and stay VALID. A whole-column bail-out would satisfy every
    zero-divisor assertion while deleting the good answers beside them, which
    is why `test_eval_div_colcol_i64_mixed_divisor_nulls_only_zero_rows`
    asserts position by position rather than counting nulls.

    Reached only from `eval_div` AFTER `_scan_int_divisor` has cleared the
    MIN / -1 overflow for every row whose operands are BOTH VALID.

    ★ A NULL ROW IS NOT DIVIDED AT ALL. Its answer
    is NULL by null-propagation — `clone_array_validity` would merge the input
    validity in afterwards regardless — so computing a quotient from a null
    slot's unspecified payload buys nothing, and one such payload pair is a
    TRAP: `_scan_int_divisor` deliberately routes a null-row (MIN, -1) here
    instead of raising, which is only safe because this loop does not divide
    it. Skipping the row is therefore load-bearing, not an optimisation.
    """
    var n = left.length
    var result = PrimitiveArray[dtype].allocate_nullable(n)
    # SAFETY: origin-tied views held in function scope keep all three buffers
    # alive across the loop; the typed pointers are internal to this function
    # and never cross a module boundary.
    var lo = left.view_ro()
    var ro = right.view_ro()
    var res_view = result.view_mut()
    var lp = lo._unsafe_ptr().bitcast[Scalar[dtype]]()
    var rp = ro._unsafe_ptr().bitcast[Scalar[dtype]]()
    var res_ptr = res_view._unsafe_ptr().bitcast[Scalar[dtype]]()
    var zero = Scalar[dtype](0)
    var nulls = 0
    # Hoisted: with no bitmap on either side the per-row validity test is
    # skipped entirely and this loop does no validity work.
    var any_nullable = left.validity.__bool__() or right.validity.__bool__()
    ref bm = result.validity.value()
    for i in range(n):
        if any_nullable:
            var l_null = False
            var r_null = False
            try:
                l_null = left.is_null(i)
                r_null = right.is_null(i)
            except:
                # `is_null` only raises out-of-range, and `i` is in [0, n).
                l_null = False
                r_null = False
            if l_null or r_null:
                bm.clear(i)
                nulls += 1
                continue
        var b = rp.load[width=1](i)
        if b == zero:
            # The value is left at its allocated zero; the NULL is the answer.
            bm.clear(i)
            nulls += 1
        else:
            res_ptr.store[width=1](i, lp.load[width=1](i) / b)
    result.null_count = nulls
    return result^


# =============================================================================
# Column vs Scalar
# =============================================================================


def eval_add_scalar[dtype: DType](col: PrimitiveArray[dtype], scalar: Scalar[dtype]) raises -> PrimitiveArray[dtype]:
    """Column + scalar: adds a scalar value to every element.

    RAISES `Out of Range Error: Overflow in ...` on an INTEGRAL overflow. FLOAT is
    IEEE.
    """
    comptime if dtype.is_integral():
        return _int_arith_cs[dtype, _ARITH_ADD, False](col, scalar)

    var result = PrimitiveArray[dtype].allocate(col.length)

    # PERF-CRITICAL: origin-tied typed pointers (see eval_add).
    # `*_view` ByteView locals
    # held in function scope so the borrow keeps the underlying buffer
    # alive across every `vectorize` closure invocation (the closure
    # captures the typed pointer by value, preserving SIMD codegen).
    var col_view = col.view_ro()
    var res_view = result.view_mut()
    var col_ptr = col_view._unsafe_ptr().bitcast[Scalar[dtype]]()
    var res_ptr = res_view._unsafe_ptr().bitcast[Scalar[dtype]]()
    comptime width = simd_width_of[dtype]()

    @always_inline
    def kernel[w: Int](idx: Int) {var col_ptr, var res_ptr, var scalar}:
        var values = col_ptr.load[width=w](idx)
        res_ptr.store[width=w](idx, values + SIMD[dtype, w](scalar))

    vectorize[width](col.length, kernel)
    return result^


def eval_mul_scalar[dtype: DType](col: PrimitiveArray[dtype], scalar: Scalar[dtype]) raises -> PrimitiveArray[dtype]:
    """Column * scalar: multiplies every element by a scalar value.

    RAISES `Out of Range Error: Overflow in ...` on an INTEGRAL overflow. FLOAT is
    IEEE.
    """
    comptime if dtype.is_integral():
        return _int_arith_cs[dtype, _ARITH_MUL, False](col, scalar)

    var result = PrimitiveArray[dtype].allocate(col.length)

    # PERF-CRITICAL: origin-tied typed pointers (see eval_add).
    # `*_view` ByteView locals
    # held in function scope so the borrow keeps the underlying buffer
    # alive across every `vectorize` closure invocation (the closure
    # captures the typed pointer by value, preserving SIMD codegen).
    var col_view = col.view_ro()
    var res_view = result.view_mut()
    var col_ptr = col_view._unsafe_ptr().bitcast[Scalar[dtype]]()
    var res_ptr = res_view._unsafe_ptr().bitcast[Scalar[dtype]]()
    comptime width = simd_width_of[dtype]()

    @always_inline
    def kernel[w: Int](idx: Int) {var col_ptr, var res_ptr, var scalar}:
        var values = col_ptr.load[width=w](idx)
        res_ptr.store[width=w](idx, values * SIMD[dtype, w](scalar))

    vectorize[width](col.length, kernel)
    return result^


def eval_sub_scalar[dtype: DType](col: PrimitiveArray[dtype], scalar: Scalar[dtype]) raises -> PrimitiveArray[dtype]:
    """Column - scalar: subtracts a scalar value from every element.

    RAISES `Out of Range Error: Overflow in ...` on an INTEGRAL overflow. FLOAT is
    IEEE.
    """
    comptime if dtype.is_integral():
        return _int_arith_cs[dtype, _ARITH_SUB, False](col, scalar)

    var result = PrimitiveArray[dtype].allocate(col.length)

    # PERF-CRITICAL: origin-tied typed pointers (see eval_add).
    # `*_view` ByteView locals
    # held in function scope so the borrow keeps the underlying buffer
    # alive across every `vectorize` closure invocation (the closure
    # captures the typed pointer by value, preserving SIMD codegen).
    var col_view = col.view_ro()
    var res_view = result.view_mut()
    var col_ptr = col_view._unsafe_ptr().bitcast[Scalar[dtype]]()
    var res_ptr = res_view._unsafe_ptr().bitcast[Scalar[dtype]]()
    comptime width = simd_width_of[dtype]()

    @always_inline
    def kernel[w: Int](idx: Int) {var col_ptr, var res_ptr, var scalar}:
        var values = col_ptr.load[width=w](idx)
        res_ptr.store[width=w](idx, values - SIMD[dtype, w](scalar))

    vectorize[width](col.length, kernel)
    return result^


def eval_rsub_scalar[dtype: DType](scalar: Scalar[dtype], col: PrimitiveArray[dtype]) raises -> PrimitiveArray[dtype]:
    """Scalar - column: the LITERAL-on-the-left subtraction, `100 - v`.

    ⚠ WHY THIS IS A KERNEL AND NOT `-(col - scalar)`.
    The two are the same number only while nothing overflows and nothing is a
    signed zero, and neither holds at the edge:
      * INT64: `-1 - MAX` is MIN, a VALID answer — but `MAX - (-1)` overflows,
        so the rewrite would RAISE where DuckDB answers.
      * FLOAT64: `1.0 - 1.0` is +0.0 — `-(1.0 - 1.0)` is -0.0, a different bit
        pattern for the same query.

    RAISES `Out of Range Error: Overflow in subtraction of ...` on an INTEGRAL
    overflow. The result carries NO validity; the caller clones the column's.
    """
    comptime if dtype.is_integral():
        return _int_arith_cs[dtype, _ARITH_SUB, True](col, scalar)

    var result = PrimitiveArray[dtype].allocate(col.length)
    # SAFETY: origin-tied views held in function scope keep both buffers alive
    # across every `vectorize` closure invocation (same shape as eval_sub_scalar).
    var col_view = col.view_ro()
    var res_view = result.view_mut()
    var col_ptr = col_view._unsafe_ptr().bitcast[Scalar[dtype]]()
    var res_ptr = res_view._unsafe_ptr().bitcast[Scalar[dtype]]()
    comptime width = simd_width_of[dtype]()

    @always_inline
    def kernel[w: Int](idx: Int) {var col_ptr, var res_ptr, var scalar}:
        var values = col_ptr.load[width=w](idx)
        res_ptr.store[width=w](idx, SIMD[dtype, w](scalar) - values)

    vectorize[width](col.length, kernel)
    return result^


def eval_div_scalar[dtype: DType](col: PrimitiveArray[dtype], scalar: Scalar[dtype]) raises -> PrimitiveArray[dtype]:
    """Column / scalar: divides every element by a scalar value.

    ★ THIS IS THE FUNCTION `=qty / 0` REACHES. A serialized plan's PROJECT of
    `col / <int literal>` lands in `_eval_binary_col_scalar`'s INT64/INT32 arm,
    which calls exactly this. Unguarded, it would execute `idiv` with a zero
    divisor and the process would die.

    TOTAL on every dtype: for an INTEGRAL dtype a zero
    divisor yields an all-NULL column with NO division performed, and a signed
    MIN / -1 raises. FLOAT keeps IEEE 754 and is untouched.
    """

    comptime if dtype.is_integral():
        if scalar == Scalar[dtype](0):
            # Every row's answer is NULL. Nothing is divided, so nothing traps.
            return _all_null_like[dtype](col.length)

        comptime if dtype.is_signed():
            if scalar == Scalar[dtype](-1):
                # MIN / -1 overflows. Only rows holding MIN are affected, so
                # the column must be inspected before dividing.
                #
                # ★ A NULL ROW'S PAYLOAD IS NOT AN OPERAND. Same
                # rule as `_scan_int_divisor`: a MIN sitting under a cleared
                # validity bit is not a division the engine was asked to
                # perform, so it must not raise — but it must not reach `idiv`
                # either, so it takes the per-row guarded loop below.
                var probe = col.view_ro()
                var pp = probe._unsafe_ptr().bitcast[Scalar[dtype]]()
                var nullable = col.validity.__bool__()
                var min_at_null_row = False
                for i in range(col.length):
                    if pp.load[width=1](i) == Scalar[dtype].MIN:
                        if nullable and col.is_null(i):
                            min_at_null_row = True
                            continue
                        raise Error(
                            "eval_div_scalar: Out of Range Error: Overflow in"
                            " division of MIN / -1 at row "
                            + String(i)
                        )
                if min_at_null_row:
                    var guarded = PrimitiveArray[dtype].allocate_nullable(
                        col.length
                    )
                    var gv = guarded.view_mut()
                    var gp = gv._unsafe_ptr().bitcast[Scalar[dtype]]()
                    var gnulls = 0
                    ref gbm = guarded.validity.value()
                    for i in range(col.length):
                        if col.is_null(i):
                            gbm.clear(i)
                            gnulls += 1
                        else:
                            gp.store[width=1](
                                i, pp.load[width=1](i) / scalar
                            )
                    guarded.null_count = gnulls
                    return guarded^

    var result = PrimitiveArray[dtype].allocate(col.length)

    # PERF-CRITICAL: origin-tied typed pointers (see eval_add).
    # `*_view` ByteView locals
    # held in function scope so the borrow keeps the underlying buffer
    # alive across every `vectorize` closure invocation (the closure
    # captures the typed pointer by value, preserving SIMD codegen).
    var col_view = col.view_ro()
    var res_view = result.view_mut()
    var col_ptr = col_view._unsafe_ptr().bitcast[Scalar[dtype]]()
    var res_ptr = res_view._unsafe_ptr().bitcast[Scalar[dtype]]()
    comptime width = simd_width_of[dtype]()

    @always_inline
    def kernel[w: Int](idx: Int) {var col_ptr, var res_ptr, var scalar}:
        var values = col_ptr.load[width=w](idx)
        res_ptr.store[width=w](idx, values / SIMD[dtype, w](scalar))

    vectorize[width](col.length, kernel)
    return result^


# =============================================================================
# Boolean Logical Evaluators (bit-packed BooleanArray) — SIMD-widened
#
# SQL/Arrow three-valued (Kleene) logic:
#   false AND null  = false   (not null)   |  true  OR null  = true   (not null)
#   true  AND null  = null                 |  false OR null  = null
#   null  AND null  = null                 |  null  OR null  = null
#   NOT null = null
# The data overlay stays SIMD; the validity merge runs ONLY when an input
# actually has a validity bitmap (the rare nullable-boolean case). The
# all-valid fast path adds zero cost on the hot path.  References: Arrow-rs
# `arrow-arith/src/boolean.rs` `and_kleene`/`or_kleene`; DuckDB
# `execute_conjunction.cpp` ternary conjunction. (Arrow-rs `compute::and`/`or`
# is the *non*-Kleene variant and is not what SQL needs.)
# =============================================================================


@always_inline
def _validity_byte(arr: BooleanArray, byte_idx: Int) -> UInt8:
    """Read validity byte `byte_idx` for `arr`; 0xFF when `arr` is all-valid."""
    if arr.validity:
        return arr.validity.value().buffer.read_u8_at(byte_idx)
    return UInt8(0xFF)


@always_inline
def _trailing_mask(length: Int) -> UInt8:
    """Mask of valid bits in the final byte of a `length`-bit bitmap (0 → full)."""
    var trailing = length & 7
    if trailing == 0:
        return UInt8(0xFF)
    return UInt8((1 << trailing) - 1)


def _finish_kleene_result(
    var result: BooleanArray,
    var validity: Bitmap[HeapRegion],
    num_bytes: Int,
    length: Int,
) -> BooleanArray:
    """Attach `validity` to `result`, mask trailing bits on both data and
    validity, recompute null_count, and return."""
    if num_bytes > 0:
        var tmask = _trailing_mask(length)
        # Mask data trailing bits (canonical zeros past `length`).
        var d = result.data.buffer.read_u8_at(num_bytes - 1)
        result.data.buffer.write_u8_at(num_bytes - 1, d & tmask)
        var v = validity.buffer.read_u8_at(num_bytes - 1)
        validity.buffer.write_u8_at(num_bytes - 1, v & tmask)
    var nc = validity.null_count()
    result.validity = validity^
    result.null_count = nc
    return result^


def eval_and(left: BooleanArray, right: BooleanArray) -> BooleanArray:
    """Element-wise logical AND on bit-packed BooleanArrays (Kleene-correct).

    Uses SIMD to process multiple bitmap bytes at once (e.g., 16 bytes =
    128 booleans per operation on ARM NEON). When either input carries a
    validity bitmap the result is computed per three-valued logic:
    `false AND null = false`, `true AND null = null`, `null AND null = null`.

    Bitmaps are read through ByteView captures
    (`view_ro` / `view_mut`). ByteView is `ImplicitlyCopyable, Movable`
    so it can be captured by value into `vectorize`'s capture-list closure.
    `load_simd[T, w](byte_offset)` and `store_simd` inline at @always_inline
    so no per-iter call overhead. PERF-CRITICAL: SIMD bitmap AND.
    """
    var length = left.length
    var result = BooleanArray.allocate(length)
    var num_bytes = bytes_for_bits(length)
    var left_view = left.data.buffer.view_ro()
    var right_view = right.data.buffer.view_ro()
    comptime width = SIMD_WIDTH_U8

    @always_inline
    def kernel[w: Int](idx: Int) {left_view, right_view, mut result}:
        var l = left_view.load_simd[DType.uint8, w](idx)
        var r = right_view.load_simd[DType.uint8, w](idx)
        result.data.buffer.view_mut().store_simd[DType.uint8, w](idx, l & r)

    vectorize[width](num_bytes, kernel)

    # Fast path: no validity on either input → non-nullable result.
    if not left.validity and not right.validity:
        return result^

    # Kleene AND validity:  rv = (lv & ~ld) | (rv & ~rd) | (lv & rv)
    # (result is determined when EITHER side is a known false, OR both known).
    var vbm = Bitmap.create(length)
    for b in range(num_bytes):
        var lv = _validity_byte(left, b)
        var rv = _validity_byte(right, b)
        var ld = left.data.buffer.read_u8_at(b)
        var rd = right.data.buffer.read_u8_at(b)
        var result_valid = (lv & ~ld) | (rv & ~rd) | (lv & rv)
        vbm.buffer.write_u8_at(b, result_valid)
    vbm.buffer.set_length(num_bytes)

    return _finish_kleene_result(result^, vbm^, num_bytes, length)


def eval_or(left: BooleanArray, right: BooleanArray) -> BooleanArray:
    """Element-wise logical OR on bit-packed BooleanArrays (Kleene-correct).

    Uses SIMD to process multiple bitmap bytes at once. When either input
    carries a validity bitmap the result is computed per three-valued
    logic: `true OR null = true`, `false OR null = null`, `null OR null = null`.

    Buffer access: see eval_and above.
    """
    var length = left.length
    var result = BooleanArray.allocate(length)
    var num_bytes = bytes_for_bits(length)
    var left_view = left.data.buffer.view_ro()
    var right_view = right.data.buffer.view_ro()
    comptime width = SIMD_WIDTH_U8

    @always_inline
    def kernel[w: Int](idx: Int) {left_view, right_view, mut result}:
        var l = left_view.load_simd[DType.uint8, w](idx)
        var r = right_view.load_simd[DType.uint8, w](idx)
        result.data.buffer.view_mut().store_simd[DType.uint8, w](idx, l | r)

    vectorize[width](num_bytes, kernel)

    # Fast path: no validity on either input → non-nullable result.
    if not left.validity and not right.validity:
        return result^

    # Kleene OR validity:  rv = (lv & ld) | (rv & rd) | (lv & rv)
    # (result is determined when EITHER side is a known true, OR both known).
    var vbm = Bitmap.create(length)
    for b in range(num_bytes):
        var lv = _validity_byte(left, b)
        var rv = _validity_byte(right, b)
        var ld = left.data.buffer.read_u8_at(b)
        var rd = right.data.buffer.read_u8_at(b)
        var result_valid = (lv & ld) | (rv & rd) | (lv & rv)
        vbm.buffer.write_u8_at(b, result_valid)
    vbm.buffer.set_length(num_bytes)

    return _finish_kleene_result(result^, vbm^, num_bytes, length)


def eval_not(col: BooleanArray) -> BooleanArray:
    """Element-wise logical NOT on bit-packed BooleanArray (Kleene-correct).

    Uses SIMD to process multiple bitmap bytes at once. Clears trailing
    bits in the last byte to avoid phantom True values. `NOT null = null` —
    the input validity bitmap (if any) is preserved on the output.

    ⚠ THE VALIDITY COPY IS NOT ENOUGH; COPYING ONLY IT IS A WRONG ANSWER.
    `~v` sets the data bit of every UNKNOWN row, and the consumer
    that actually selects rows — `filter_to_indices`
    (`komira_column_kernels/comparison.mojo`) — walks the DATA bitmap 64 bits
    at a time and never reads validity. So `NOT (x = '')` over a NULL row would
    come back SELECTED. SQL says `NOT UNKNOWN` is UNKNOWN and a WHERE over UNKNOWN
    does not match, so the row must be excluded under the comparison AND under
    its negation; it is not a row that flips sides.

    The engine-wide encoding, which `eval_and` / `eval_or` honour
    (their Kleene validity is derived from data bits that are 0 on the unknown
    side) and which this function honours too:

        A row whose value is UNKNOWN carries DATA BIT 0.
        The validity bitmap says WHY it is 0 — unknown, not false.

    That is what makes the answer survive a data-only consumer without asking
    every such consumer to learn 3VL. A regression test guards it.

    Buffer access: see eval_and above. The trailing-bit clear uses
    `read_u8_at` / `write_u8_at` (one byte each).
    """
    var length = col.length
    var result = BooleanArray.allocate(length)
    var num_bytes = bytes_for_bits(length)
    var col_view = col.data.buffer.view_ro()
    comptime width = SIMD_WIDTH_U8

    @always_inline
    def kernel[w: Int](idx: Int) {col_view, mut result}:
        var v = col_view.load_simd[DType.uint8, w](idx)
        result.data.buffer.view_mut().store_simd[DType.uint8, w](idx, ~v)

    vectorize[width](num_bytes, kernel)

    # Clear trailing bits in the last byte beyond `length` bits.
    var trailing = length & 7
    if trailing > 0 and num_bytes > 0:
        var mask = UInt8((1 << trailing) - 1)
        var cur = result.data.buffer.read_u8_at(num_bytes - 1)
        result.data.buffer.write_u8_at(num_bytes - 1, cur & mask)

    # NOT null = null: propagate the input validity bitmap unchanged.
    if col.validity:
        var vbm = Bitmap.create(length)
        if num_bytes > 0:
            vbm.buffer.copy_from_view(col.validity.value().buffer.view_range_ro(0, num_bytes))
            vbm.buffer.set_length(num_bytes)

        # ...AND re-clear the data bit of every UNKNOWN row. `~v` just set it.
        # See the docstring: data bit 0 is how UNKNOWN reaches a consumer that
        # reads data only, and `filter_to_indices` is exactly that consumer.
        for b in range(num_bytes):
            var d = result.data.buffer.read_u8_at(b)
            result.data.buffer.write_u8_at(b, d & vbm.buffer.read_u8_at(b))

        result.validity = vbm^
        result.null_count = col.null_count
    return result^


# =============================================================================
# Fused Revenue Computation — single-pass price*(1-discount) with sum
# =============================================================================


def eval_revenue_sum(
    price: PrimitiveArray[DType.float64],
    discount: PrimitiveArray[DType.float64],
) -> Float64:
    """Compute sum(price * (1 - discount)) in a SINGLE pass.

    Fuses subtraction, multiplication, and reduction. No intermediate arrays.
    Uses SIMD for vectorized computation.

    Args:
        price: The extended price column.
        discount: The discount column (values typically in [0.0, 0.10]).

    Returns:
        The sum of price[i] * (1.0 - discount[i]) for all i.
    """
    var length = price.length
    comptime width = SIMD_WIDTH_F64

    var simd_acc = SIMD[DType.float64, width](0)
    var one_vec = SIMD[DType.float64, width](1.0)

    # Process SIMD-width chunks
    var full_chunks = length // width
    for i in range(full_chunks):
        var idx = i * width
        var p = price.load[width](idx)
        var d = discount.load[width](idx)
        var one_minus_d = one_vec - d
        simd_acc += p * one_minus_d

    # Reduce SIMD accumulator to scalar via tree-reduction.
    # PERF-CRITICAL: SIMD.reduce_add() emits a single horizontal-add
    # (ARM NEON FADDP / x86 hadd tree) instead of a serialized lane-loop
    # which the compiler cannot fuse without -ffast-math. FP rounding order
    # differs from sequential add — callers must use ULP-bounded comparisons.
    var total = Float64(simd_acc.reduce_add())

    # Handle tail elements
    var tail_start = full_chunks * width
    for i in range(tail_start, length):
        var p = Float64(price.load[1](i))
        var d = Float64(discount.load[1](i))
        total += p * (1.0 - d)

    return total


def eval_filtered_revenue_sum(
    price: PrimitiveArray[DType.float64],
    discount: PrimitiveArray[DType.float64],
    mask: BooleanArray,
) -> Float64:
    """Compute sum(price * (1 - discount)) WHERE mask is True in a SINGLE pass.

    Fuses filter check, subtraction, multiplication, and reduction.
    No intermediate arrays. Processes bitmap bytes to skip groups of 8 zeros.

    Args:
        price: The extended price column.
        discount: The discount column.
        mask: A BooleanArray indicating which rows to include.

    Returns:
        The sum of price[i] * (1.0 - discount[i]) for all i where mask[i] is True.
    """
    # Columns are read through `load[W]`; the mask buffer through view_ro.
    var bm_view = mask.data.buffer.view_ro()
    var length = price.length
    comptime width = SIMD_WIDTH_F64
    # NOTE: This function's byte loop assumes `width <= 8` (each bitmap byte
    # spans `8 // width` SIMD chunks). Float64 native width is 2 on NEON /
    # 4 on AVX2 / 8 on AVX-512 — all <= 8 — so this is safe today. If this
    # function is ever generalized to a wider dtype (e.g. float32 on
    # AVX-512 has width=16), mirror the comptime-symmetric @parameter if
    # design used in `filtered_sum` below. The empty `for chunk in
    # range(8 // 16)` loop would otherwise silently return 0.

    var total = Float64(0.0)

    # Process 8 elements per bitmap byte
    var full_bytes = length >> 3
    for byte_idx in range(full_bytes):
        var byte_val = bm_view.read_u8_at(byte_idx)
        if byte_val == 0:
            continue
        var elem_idx = byte_idx << 3

        if byte_val == UInt8(0xFF):
            # All 8 bits set — SIMD fast path
            # Process with SIMD width (e.g., 2 for float64 on ARM = 4 iterations)
            for chunk in range(8 // width):
                var idx = elem_idx + chunk * width
                var p = price.load[width](idx)
                var d = discount.load[width](idx)
                var one_vec = SIMD[DType.float64, width](1.0)
                var revenue = p * (one_vec - d)
                # PERF-CRITICAL: tree-reduction (FADDP) over lane-serial sum.
                total += Float64(revenue.reduce_add())
        else:
            # Sparse — check each bit (unrolled for performance)
            if byte_val & UInt8(1) != 0:
                total += Float64(price.load[1](elem_idx)) * (1.0 - Float64(discount.load[1](elem_idx)))
            if byte_val & UInt8(2) != 0:
                total += Float64(price.load[1](elem_idx + 1)) * (1.0 - Float64(discount.load[1](elem_idx + 1)))
            if byte_val & UInt8(4) != 0:
                total += Float64(price.load[1](elem_idx + 2)) * (1.0 - Float64(discount.load[1](elem_idx + 2)))
            if byte_val & UInt8(8) != 0:
                total += Float64(price.load[1](elem_idx + 3)) * (1.0 - Float64(discount.load[1](elem_idx + 3)))
            if byte_val & UInt8(16) != 0:
                total += Float64(price.load[1](elem_idx + 4)) * (1.0 - Float64(discount.load[1](elem_idx + 4)))
            if byte_val & UInt8(32) != 0:
                total += Float64(price.load[1](elem_idx + 5)) * (1.0 - Float64(discount.load[1](elem_idx + 5)))
            if byte_val & UInt8(64) != 0:
                total += Float64(price.load[1](elem_idx + 6)) * (1.0 - Float64(discount.load[1](elem_idx + 6)))
            if byte_val & UInt8(128) != 0:
                total += Float64(price.load[1](elem_idx + 7)) * (1.0 - Float64(discount.load[1](elem_idx + 7)))

    # Handle remaining elements
    var remaining = length & 7
    if remaining > 0:
        var elem_idx = full_bytes << 3
        var byte_val = bm_view.read_u8_at(full_bytes)
        for bit in range(remaining):
            if byte_val & (UInt8(1) << UInt8(bit)) != 0:
                var p = Float64(price.load[1](elem_idx + bit))
                var d = Float64(discount.load[1](elem_idx + bit))
                total += p * (1.0 - d)

    return total


# =============================================================================
# Filtered Aggregation — fused filter + sum (SIMD-vectorized)
# =============================================================================


def filtered_sum[dtype: DType](col: PrimitiveArray[dtype], mask: BooleanArray) -> Scalar[dtype]:
    """Sum elements of col where mask bit is set.

    Uses SIMD: loads values unconditionally at SIMD width, builds a mask
    from the bitmap byte, uses select() to zero out masked values, then
    accumulates. Falls back to scalar for tail elements.

    Args:
        col: The column to sum over.
        mask: A BooleanArray indicating which elements to include.

    Returns:
        The sum of col[i] for all i where mask[i] is True.
    """
    # The column is read through `col.load[W]`; the mask buffer through view_ro.
    #
    # SIMD-width-symmetric design:
    # The native SIMD width can be wider than 8 lanes (e.g. AVX-512 int32 has
    # `simd_width_of[int32]() = 16`). The bitmap stores 8 mask bits per byte,
    # so we need a comptime branch:
    #   * width <  8 (NEON i32=4, NEON i64=2, NEON i16=8 etc): each bitmap
    #     byte maps to (8 // width) SIMD chunks.
    #   * width >= 8 (AVX-512 i32=16, AVX-512 i64=8): each SIMD chunk
    #     spans (width // 8) bitmap bytes.
    # A single shape `for chunk in range(8 // width)` would produce an EMPTY
    # loop on AVX-512 i32 (8 // 16 = 0), silently returning 0.
    var total = Scalar[dtype](0)
    var bm_view = mask.data.buffer.view_ro()
    var length = col.length
    comptime width = simd_width_of[dtype]()

    comptime if width < 8:
        # `width` divides 8 (native widths are 1, 2, 4 for sub-byte cases).
        # Each bitmap byte spans (8 // width) SIMD chunks.
        var full_bytes = length >> 3
        for byte_idx in range(full_bytes):
            var byte_val = bm_view.read_u8_at(byte_idx)
            if byte_val == 0:
                continue
            var elem_idx = byte_idx << 3
            if byte_val == UInt8(0xFF):
                # All 8 bits set — unconditional SIMD sum.
                for chunk in range(8 // width):
                    var idx = elem_idx + chunk * width
                    var vals = col.load[width](idx)
                    # PERF-CRITICAL: tree-reduction (FADDP) over lane-serial sum.
                    total += vals.reduce_add()
            else:
                # Partial byte — SIMD select gated on bitmap bits.
                for chunk in range(8 // width):
                    var idx = elem_idx + chunk * width
                    var vals = col.load[width](idx)
                    var bit_offset = chunk * width
                    var simd_mask = SIMD[DType.bool, width](fill=False)
                    for lane in range(width):
                        simd_mask[lane] = (byte_val & (UInt8(1) << UInt8(bit_offset + lane))) != 0
                    var zero = SIMD[dtype, width](0)
                    var masked_vals = simd_mask.select(vals, zero)
                    # PERF-CRITICAL: tree-reduction over lane-serial sum.
                    total += masked_vals.reduce_add()

        # Tail: residual elements not covered by the byte loop (< 8 elements).
        var remaining = length & 7
        if remaining > 0:
            var elem_idx = full_bytes << 3
            var byte_val = bm_view.read_u8_at(full_bytes)
            for bit in range(remaining):
                if byte_val & (UInt8(1) << UInt8(bit)) != 0:
                    total += col.load[1](elem_idx + bit)
    else:
        # width >= 8 ⇒ width is a multiple of 8 (8, 16, 32 — only powers of
        # two that arise on supported targets; width == 4 takes the < 8
        # branch). Each SIMD chunk spans `width / 8` consecutive bitmap
        # bytes; one SIMD load + one masked reduce per chunk.
        comptime bytes_per_chunk = width // 8
        var num_full_chunks = length // width
        for chunk_idx in range(num_full_chunks):
            var elem_idx = chunk_idx * width
            # Pre-scan the (bytes_per_chunk) bitmap bytes for this chunk to
            # decide between skip / all-set / partial fast paths.
            var any_set = False
            var all_set = True
            comptime for b in range(bytes_per_chunk):
                var bv = bm_view.read_u8_at(chunk_idx * bytes_per_chunk + b)
                if bv != 0:
                    any_set = True
                if bv != UInt8(0xFF):
                    all_set = False
            if not any_set:
                continue
            var vals = col.load[width](elem_idx)
            if all_set:
                # PERF-CRITICAL: tree-reduction over lane-serial sum.
                total += vals.reduce_add()
            else:
                # Build the per-lane SIMD mask from bytes_per_chunk bytes.
                var simd_mask = SIMD[DType.bool, width](fill=False)
                comptime for b in range(bytes_per_chunk):
                    var bv = bm_view.read_u8_at(chunk_idx * bytes_per_chunk + b)
                    for lane in range(8):
                        simd_mask[b * 8 + lane] = (bv & (UInt8(1) << UInt8(lane))) != 0
                var zero = SIMD[dtype, width](0)
                var masked_vals = simd_mask.select(vals, zero)
                # PERF-CRITICAL: tree-reduction over lane-serial sum.
                total += masked_vals.reduce_add()

        # Tail: residual elements [num_full_chunks * width, length). The
        # standard `length & 7` mask is INSUFFICIENT here — when
        # bytes_per_chunk > 1 the residual can be up to `width - 1` elements.
        var num_processed = num_full_chunks * width
        var i = num_processed
        while i < length:
            var byte_idx = i >> 3
            var bit = i & 7
            var byte_val = bm_view.read_u8_at(byte_idx)
            if byte_val & (UInt8(1) << UInt8(bit)) != 0:
                total += col.load[1](i)
            i += 1

    return total
