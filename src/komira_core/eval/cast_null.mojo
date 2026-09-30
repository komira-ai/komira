# =============================================================================
# Cast Evaluator + Null Handling
# =============================================================================

from std.algorithm import vectorize
from std.math import isinf
from std.memory import unsafe_memcpy
from std.sys import simd_width_of

from ..arrow.primitive_array import PrimitiveArray
from ..arrow.boolean_array import BooleanArray
from ..arrow.bitmap import Bitmap, bytes_for_bits
from ..arrow.constants import SIMD_WIDTH_U8
from ..io.heap_region import HeapRegion


# =============================================================================
# Cast Evaluator
# =============================================================================


def eval_cast[
    from_dtype: DType, to_dtype: DType
](col: PrimitiveArray[from_dtype]) raises -> PrimitiveArray[to_dtype]:
    """Type conversion using SIMD .cast[target]().

    Converts each element of a PrimitiveArray[from_dtype] to to_dtype.
    Uses vectorize for SIMD-accelerated bulk conversion. The input
    validity bitmap (if any) is preserved on the output and null_count
    is recomputed — `cast(nullable_col AS ...)` keeps the null mask
    (Arrow/DuckDB semantics). Without this propagation a nullable cast
    would come back claiming all-valid (a silent wrong answer).
    """
    var result = PrimitiveArray[to_dtype].allocate(col.length)
    # Origin-tied via views captured directly INTO the kernel closure
    # (same pattern as `bitmap_and` below: view capture extends the view's
    # lifetime through the vectorize call without a `_=` keepalive). The
    # kernel re-bitcasts to Scalar[dtype] on each call; @always_inline hoists
    # this so codegen matches a raw typed pointer.
    var col_view = col.view_ro()
    var res_view = result.view_mut()
    comptime from_width = simd_width_of[from_dtype]()
    comptime to_width = simd_width_of[to_dtype]()
    comptime width = from_width if from_width < to_width else to_width

    @always_inline
    def kernel[w: Int](idx: Int) {col_view, res_view}:
        var col_ptr = col_view._unsafe_ptr().bitcast[Scalar[from_dtype]]()
        var res_ptr = res_view._unsafe_ptr().bitcast[Scalar[to_dtype]]()
        var values = col_ptr.load[width=w](idx)
        var casted = values.cast[to_dtype]()
        res_ptr.store[width=w](idx, casted)

    vectorize[width](col.length, kernel)

    # Preserve validity: cast must not drop the input null mask.
    if col.validity:
        ref src_bm = col.validity.value()
        var cloned = Bitmap.copy_slice_from(src_bm, 0, src_bm.length)
        result.null_count = cloned.null_count()
        result.validity = cloned^
    return result^


# =============================================================================
# DOUBLE -> FLOAT: THE OUT-OF-RANGE RULE
# =============================================================================
#
# ⛔ `eval_cast[float64, float32]` IS AN `fptrunc`, AND OVER A FINITE DOUBLE
# BEYOND FLOAT's RANGE IT ANSWERS +-inf WITH A SUCCESS CODE. DuckDB v1.5.3
# RAISES there:
#
#     CAST(-1e308::DOUBLE AS REAL)                   Conversion Error ... FLOAT
#     CAST(3.4028235677973362e38::DOUBLE AS REAL)    3.4028234663852886e+38
#     CAST(3.4028235677973366e38::DOUBLE AS REAL)    Conversion Error ... FLOAT
#     CAST('inf'::DOUBLE AS REAL) / -inf / nan       inf / -inf / nan
#
# ⭐ SO THE RULE IS "A FINITE INPUT WHOSE FLOAT ROUNDING IS INFINITE", NOT
# "|x| > FLT_MAX". 3.4028235677973362e38 IS above FLT_MAX and rounds DOWN to
# it, and DuckDB answers; the first double that rounds to inf is FLT_MAX plus
# half an ulp, 3.4028235677973366e38, and that is exactly where DuckDB starts
# raising. Reading the rounded value is what makes the boundary exact without
# writing the threshold down, and the three specials need no arm: an input
# that is ALREADY infinite is not "finite", and NaN rounds to NaN.
#
# ⚠ WHY THIS IS A SEPARATE KERNEL AND `eval_cast` IS UNCHANGED: `eval_cast` is
# the SHARED conversion (the implicit FLOAT32-comparison narrowing calls it
# directly), and polars / pandas-style casts answer inf here — as those
# libraries do — by saturating to +-inf BEFORE the cast, so that no finite
# value out of range ever reaches this kernel from them.
#
# TRY mode NULLs the row instead of raising: DuckDB's `TRY_CAST(1e39::DOUBLE
# AS REAL)` is NULL. The overflow nulls are UNIONed with the source nulls, the
# same shape `eval_cast_float_to_int` uses.


def eval_cast_f64_to_f32_checked(
    col: PrimitiveArray[DType.float64], try_mode: Bool
) raises -> PrimitiveArray[DType.float32]:
    """DOUBLE -> FLOAT with DuckDB's out-of-range rule: a FINITE input whose
    float32 rounding is +-inf RAISES `Conversion Error` (or, in `try_mode`, is
    NULL). Every other value — including +-inf and NaN — is the plain
    round-to-nearest `fptrunc` of `eval_cast`, which this calls first."""
    var result = eval_cast[DType.float64, DType.float32](col)
    var overflow_rows = List[Int]()
    for i in range(col.length):
        if col.is_null(i):
            continue
        if not isinf(result.get(i)):
            continue
        var v = col.get(i)
        if isinf(v):
            continue
        if try_mode:
            overflow_rows.append(i)
            continue
        raise Error(
            String("Conversion Error: Type DOUBLE with value ")
            + String(v)
            + " can't be cast because the value is out of range for the"
            + " destination type FLOAT"
        )
    if len(overflow_rows) > 0:
        # ⛔ UNION, NOT REPLACE — see `eval_cast_float_to_int`.
        if not result.validity:
            result.validity = Bitmap.create_all_valid(col.length)
        for j in range(len(overflow_rows)):
            result.set(overflow_rows[j], Scalar[DType.float32](0))
            result.validity.value().clear(overflow_rows[j])
        result.null_count = result.validity.value().null_count()
    return result^


# =============================================================================
# FLOAT -> INTEGER CAST: THE ROUNDING RULE
# =============================================================================
#
# ⛔⛔ `eval_cast` ABOVE IS **NOT** THE FLOAT -> INTEGER CAST, AND USING IT AS ONE
# ANSWERS A WRONG NUMBER WITH A SUCCESS CODE. Its SIMD `.cast[to]()` lowers to
# LLVM `fptosi`, which TRUNCATES TOWARD ZERO. DuckDB v1.5.3 ROUNDS HALF TO EVEN.
# Over a real DOUBLE **column** (see the trap below), `CAST(x AS BIGINT)`:
#
#     x     -3.5  -2.5  -1.5  -0.5   0.5   1.5   2.5   3.5   4.5   2.4   2.6
#     duck    -4    -2    -2     0     0     2     2     4     4     2     3
#     trunc   -3    -2    -1     0     0     1     2     3     4     2     2
#              ^           ^           ^     ^           ^
#              `-- the five cells where a truncating cast is simply wrong.
#
# ⚠⚠ THE TRAP THAT MAKES THIS EASY TO "VERIFY" BACKWARDS. A bare
# `SELECT CAST(2.5 AS BIGINT)` in DuckDB
# answers **3**, not 2 — because `2.5` is a **DECIMAL(2,1)** literal, not a
# DOUBLE (`SELECT typeof(2.5)`), and DECIMAL -> BIGINT rounds half AWAY FROM
# ZERO. Only `CAST(CAST(2.5 AS DOUBLE) AS BIGINT)` or a DOUBLE column asks the
# question this kernel answers. A check written the short way concludes
# half-away-from-zero and ships 2.5 -> 3.
#
# ⚠ AND IT IS NOT THE SAME RULE AS SQL `round()`, WHICH IS ALSO IN THIS LIBRARY.
# `numeric_unary._apply_float` calls libm `round` — HALF AWAY FROM ZERO — and is
# correct, because DuckDB's `round(2.5)` IS 3. `CAST(2.5::DOUBLE AS BIGINT)` is
# 2. Two rules, two kernels, and neither may be "unified" with the other.
#
# ⚠ WHY SIMD `__round__` AND NOT libm `nearbyint`: Mojo's `round` follows
# PYTHON's, which is half-to-even by definition, so the semantics are a language
# contract rather than a runtime condition — where `nearbyint`/`rint` read the
# CURRENT FP ROUNDING MODE and would silently become a different function if
# anything ever called `fesetround`. It also vectorises, which a libm call per
# lane does not. ⭐ It is equal to libm `nearbyint` on the boundary values
# (both signs, ties and non-ties, -0.0, 1e17), and `round_half_to_even` test
# cases pin it, so a future change to Mojo's `round` goes RED.
#
# ⛔ AND IT IS THE OPPOSITE OF THE LIBRARY'S OTHER ROUNDING CALL FOR THE SAME
# REASON: `numeric_unary._apply_float` reaches for libm `round` PRECISELY
# BECAUSE Mojo's built-in `round` is half-to-even and SQL `round()` must not be.


@always_inline
def round_half_to_even[dt: DType, w: Int](x: SIMD[dt, w]) -> SIMD[dt, w]:
    """Nearest integral value, ties to the EVEN neighbour. Float in, float out.

    ⭐ THE SINGLE DEFINITION OF THE FLOAT -> INTEGER CAST ROUNDING RULE. Every
    door that converts a float to an integer under a CAST calls this. A rule
    spelled separately at each door (`Int(x)`, `.cast[int64]()`) truncates, and a
    shared definition exists to stop that.
    """
    return x.__round__()


@always_inline
def _cast_sql_type_name[dt: DType]() -> StaticString:
    """The SQL spelling of a cast operand's type, for the refusal sentence.

    ⚠ NOT `String(dt)`. The customer wrote `BIGINT` / `DOUBLE`; a message that
    says `int64` / `float64` is naming an internal representation at somebody who
    wrote ordinary SQL (for example `unsupported EXPR_CAST from float32 to
    int64`). DuckDB v1.5.3's own sentence uses
    `DOUBLE` / `FLOAT` for the source and `INT64` / `INT32` for the destination —
    note it does NOT say `BIGINT` on the destination half — and this reproduces
    that asymmetry rather than tidying it, so the two engines' messages can be
    compared cell for cell.
    """
    comptime if dt == DType.float64:
        return "DOUBLE"
    elif dt == DType.float32:
        return "FLOAT"
    elif dt == DType.int64:
        return "INT64"
    elif dt == DType.int32:
        return "INT32"
    elif dt == DType.int16:
        return "INT16"
    elif dt == DType.int8:
        return "INT8"
    else:
        return "UNKNOWN"


def eval_cast_float_to_int[
    from_dtype: DType, to_dtype: DType
](col: PrimitiveArray[from_dtype], try_mode: Bool = False) raises -> PrimitiveArray[to_dtype]:
    """A FLOAT array -> an INTEGER array, rounding HALF TO EVEN (DuckDB parity),
    REFUSING a value the destination width cannot hold.

    ⚠ THE ROUNDING HAPPENS IN THE SOURCE WIDTH, NOT IN FLOAT64, and it does not
    need to widen: `round_half_to_even` is generic over the float dtype, and a
    float32 at or below 2^24 rounds to an integer float32 represents exactly
    while one above 2^24 is ALREADY an integer. Verified equal to the
    float64-widened answer over the f32 boundary set.

    ★ THE OVERFLOW GUARD — WHAT IT REPLACES AND WHY IT IS SHAPED THIS WAY.

    ⛔ THE DEFECT IT PREVENTS: an unguarded `fptosi` answers every one of
    `CAST(1e308 AS BIGINT)`, `CAST(-1e308 AS BIGINT)`, `CAST(nan AS BIGINT)` and
    `CAST(1e30::FLOAT AS BIGINT)` with **-9223372036854775808** on x86 — one
    plausible finite integer, with a success code, for four completely different
    inputs including a NaN. `CAST(3e9 AS INTEGER)` answers -2147483648. DuckDB
    v1.5.3 raises a `Conversion Error` for all five.

    ⭐ THE ACCEPT WINDOW IS `v >= -2^(N-1) and v < +2^(N-1)`, ON THE RAW VALUE.
    Both bounds are EXACT in float32 and float64 alike (they are powers of two),
    so the comparison is not itself a rounding. Three consequences, each
    measured on the `duckdb` v1.5.3 CLI rather than reasoned:

      * ⛔⛔ CHECKED BEFORE ROUNDING, WHICH IS NOT THE OBVIOUS ORDER.
        `CAST(-2147483648.4::DOUBLE AS INTEGER)` RAISES in DuckDB even though it
        ROUNDS to INT32_MIN, which fits. A guard that rounds first and then
        range-checks accepts it and diverges. A regression test pins it.
      * The upper bound is 2^(N-1), NOT the destination's MAX. `2147483647.4`
        is answered (-> 2147483647); `2147483648.0` raises. Note this makes
        INT64_MAX itself un-castable FROM a double: `9223372036854775807::DOUBLE`
        IS 2^63, so `CAST(9223372036854775807::DOUBLE AS BIGINT)` raises in
        DuckDB too — a cell that looks like a bug in either engine and is not.
      * NaN, +Inf and -Inf need NO arm. Every comparison against NaN is false, so
        NaN fails `v >= lo`; the infinities fail one side each. DuckDB likewise
        reports them through the same "out of range" sentence rather than a
        special one.

    ⚠ THE ONE ROUNDING OVERSHOOT, AND IT IS A DECIDED ANSWER RATHER THAN A
    MEASURED RULE. A value inside the window can still round OUT of it: for
    f64 -> i32, `2147483647.5` passes (`< 2^31`) and rounds half-to-even UP to
    2147483648. DuckDB v1.5.3 answers `2147483647` on arm64 and would answer
    INT32_MIN on x86 — that is ARM's saturating `fcvtzs` showing through a
    `static_cast` its source leaves undefined, and the x86 half of it is exactly
    what an unclamped kernel prints on linux x86. So this CLAMPS:
    the answer is 2147483647 on every platform, matching DuckDB on arm64. (The
    overshoot is unreachable for every other instantiation — the representable
    floats adjacent to 2^63, and to 2^31 in float32, are spaced far wider than
    0.5, so no `.5` exists there to round.)

    ⚠ TRY MODE IS THE OTHER HALF AND IT IS NOT OPTIONAL. `TRY_CAST(1e308 AS
    BIGINT)` is NULL in DuckDB wherever `CAST` raises. `try_mode=True` nulls the
    offending row instead of raising, and the null is carried by a REAL validity
    bitmap: an output that declared itself non-nullable while producing NULLs is
    read downstream as a licence to allocate no bitmap, and the value reaching a
    customer is then a garbage NUMBER.
    ⛔ The overflow nulls are UNIONed with the source nulls — `null_count` is
    recomputed FROM the merged bitmap rather than added up — because a kernel
    that overwrites one set with the other loses a class of null silently.
    """
    var result = PrimitiveArray[to_dtype].allocate(col.length)

    # The window. Both bounds exact: `Scalar[to].MIN` is -2^(N-1), and its
    # negation +2^(N-1) is the first value the width CANNOT hold.
    var lo = Scalar[to_dtype].MIN.cast[from_dtype]()
    var hi = -lo
    var to_min = Scalar[to_dtype].MIN
    var to_max = Scalar[to_dtype].MAX

    # TRY-mode overflow rows, collected so the bitmap work happens once. Empty
    # on every strict call and on every TRY call that overflows nothing, so the
    # shape of the output is unchanged for both.
    var overflow_rows = List[Int]()

    for i in range(col.length):
        if col.is_null(i):
            result.set(i, Scalar[to_dtype](0))
            continue
        var v = col.get(i)
        # ⛔ WRITTEN AS `not (in range)`, NOT AS `v < lo or v >= hi`. The two are
        # NOT equivalent for NaN: NaN fails the first (every comparison is
        # false, so the negation is true -> refused) and would PASS the second
        # (both disjuncts false), shipping whatever `fptosi(NaN)` happens to be.
        if not (Bool(v >= lo) and Bool(v < hi)):
            if try_mode:
                result.set(i, Scalar[to_dtype](0))
                overflow_rows.append(i)
                continue
            raise Error(
                String("Conversion Error: Type ")
                + String(_cast_sql_type_name[from_dtype]())
                + " with value "
                + String(v)
                + " can't be cast because the value is out of range for the"
                + " destination type "
                + String(_cast_sql_type_name[to_dtype]())
            )
        var rounded = round_half_to_even[from_dtype, 1](v)
        # The rounding overshoot, clamped. See the docstring: reachable only for
        # f64 -> i32 at exactly 2147483647.5.
        if Bool(rounded >= hi):
            result.set(i, to_max)
        elif Bool(rounded < lo):
            result.set(i, to_min)
        else:
            result.set(i, Scalar[to_dtype](rounded.cast[to_dtype]()))
    # Preserve validity: a cast must not drop the input null mask (a nullable
    # cast coming back all-valid is a silent-wrong).
    #
    # ⛔⛔ `col.offset`, NOT `0` — AND **NOT** WHAT `eval_cast` ABOVE DOES. That
    # kernel copies `(src_bm, 0, src_bm.length)`, which reads the validity plane
    # from BIT 0 while `view_ro()` rebases its DATA plane onto the offset: on a
    # sliced array the two planes are misaligned by exactly `offset` bits. This
    # loop indexes with `col.get(i)` / `col.is_null(i)`, BOTH OFFSET-AWARE, so
    # copying from bit 0 here would reintroduce that misalignment against
    # offset-aware data — the defect `test_arith_cast_offset_validity` covers.
    # The shared `clone_array_validity` copies
    # (`copy_slice_from(src_bm, src.offset, src.length)`), but `eval_cast`'s
    # inline copy of the same logic does not. ⚠ `eval_cast` IS OFFSET-BLIND and
    # is NOT fixed here — a separate defect with its own reachability argument.
    # Do not "make this consistent with eval_cast".
    if col.validity:
        ref src_bm = col.validity.value()
        var cloned = Bitmap.copy_slice_from(src_bm, col.offset, col.length)
        result.null_count = cloned.null_count()
        result.validity = cloned^
    if len(overflow_rows) > 0:
        # ⛔ UNION, NOT REPLACE. If the source carried nulls the bitmap cloned
        # above already holds them; clearing into it adds the overflow rows.
        # If it did not, an all-valid bitmap is created so the TRY nulls have
        # somewhere to live — the output is nullable BECAUSE it produced nulls,
        # which is the invariant `Field.nullable` is read against downstream.
        if not result.validity:
            result.validity = Bitmap.create_all_valid(col.length)
        for j in range(len(overflow_rows)):
            result.validity.value().clear(overflow_rows[j])
        # Recomputed from the merged bitmap. Adding the two counts would
        # double-count nothing here (a source-null row never reaches the range
        # check) but would silently start lying the day that changes.
        result.null_count = result.validity.value().null_count()
    return result^


# =============================================================================
# Null Handling Functions
# =============================================================================


def bitmap_and(left: Bitmap[HeapRegion], right: Bitmap[HeapRegion]) -> Bitmap[HeapRegion]:
    """AND two validity bitmaps using SIMD-vectorized byte-wise AND.

    Result is null if EITHER input is null (bit=0 in either bitmap).
    Both bitmaps must have the same `length`. The returned Bitmap owns its
    buffer; callers do not manage any raw pointers.

    Pointers are extracted from `left` and `right` only inside this function
    body — Mojo's borrow checker keeps the input Bitmaps alive for the
    duration of the call, so the closure's captured pointers are valid.
    """
    var length = left.length
    var bitmap_bytes = bytes_for_bits(length)
    var result = Bitmap.create(length)
    if bitmap_bytes == 0:
        return result^

    # SAFETY: left/right/result are live for the entire function body.
    # The vectorize closure only runs synchronously below, so the captured
    # views are valid for the call. No pointers escape.
    # ByteView captures (universal codegen via @always_inline +
    # load_simd / store_simd).
    var left_view = left.buffer.view_ro()
    var right_view = right.buffer.view_ro()
    comptime width = SIMD_WIDTH_U8

    @always_inline
    def kernel[w: Int](idx: Int) {left_view, right_view, mut result}:
        var l = left_view.load_simd[DType.uint8, w](idx)
        var r = right_view.load_simd[DType.uint8, w](idx)
        result.buffer.view_mut().store_simd[DType.uint8, w](idx, l & r)

    vectorize[width](bitmap_bytes, kernel)
    result.buffer.set_length(bitmap_bytes)

    return result^


def eval_gt_nullable[
    dtype: DType
](col: PrimitiveArray[dtype], threshold: Scalar[dtype]) -> BooleanArray:
    """Null-propagating greater-than: column > scalar.

    If input row is null, output row is null (not false).
    If input has no validity bitmap, behaves identically to eval_gt.

    Returns a BooleanArray with optional validity bitmap propagated from input.
    """
    # Evaluate comparison into a temporary byte-per-element buffer.
    var temp = PrimitiveArray[DType.bool].allocate(col.length)

    # Same `view_{ro,mut}` + kernel-internal bitcast pattern as `eval_cast`
    # above (keeps the view captured directly into the vectorize closure
    # to extend its lifetime through the call without a `_=` keepalive).
    var col_view = col.view_ro()
    var res_view = temp.view_mut()
    comptime width = simd_width_of[dtype]()

    @always_inline
    def kernel[w: Int](idx: Int) {var col_view, var res_view, var threshold}:
        var col_ptr = col_view._unsafe_ptr().bitcast[Scalar[dtype]]()
        var res_ptr = res_view._unsafe_ptr().bitcast[Scalar[DType.bool]]()
        var values = col_ptr.load[width=w](idx)
        var mask = values.gt(SIMD[dtype, w](threshold))
        res_ptr.store[width=w](idx, mask)

    vectorize[width](col.length, kernel)

    # Pack bool bytes into bitmap — 8 bytes at a time for direct byte packing.
    # Views + read_u8_at / write_u8_at.
    var data_bm = Bitmap.create(col.length)
    var raw_view = temp.data.view_ro()
    var bm_view = data_bm.buffer.view_mut()
    var full_bytes = col.length >> 3
    for byte_idx in range(full_bytes):
        var base = byte_idx << 3
        var byte_val = UInt8(0)
        if Int(raw_view.read_u8_at(base + 0)) != 0:
            byte_val = byte_val | UInt8(1)
        if Int(raw_view.read_u8_at(base + 1)) != 0:
            byte_val = byte_val | UInt8(2)
        if Int(raw_view.read_u8_at(base + 2)) != 0:
            byte_val = byte_val | UInt8(4)
        if Int(raw_view.read_u8_at(base + 3)) != 0:
            byte_val = byte_val | UInt8(8)
        if Int(raw_view.read_u8_at(base + 4)) != 0:
            byte_val = byte_val | UInt8(16)
        if Int(raw_view.read_u8_at(base + 5)) != 0:
            byte_val = byte_val | UInt8(32)
        if Int(raw_view.read_u8_at(base + 6)) != 0:
            byte_val = byte_val | UInt8(64)
        if Int(raw_view.read_u8_at(base + 7)) != 0:
            byte_val = byte_val | UInt8(128)
        bm_view.write_u8_at(byte_idx, byte_val)
    # Handle remaining bits (< 8)
    var remaining = col.length & 7
    if remaining > 0:
        var base = full_bytes << 3
        var byte_val = UInt8(0)
        for bit in range(remaining):
            if Int(raw_view.read_u8_at(base + bit)) != 0:
                byte_val = byte_val | (UInt8(1) << UInt8(bit))
        bm_view.write_u8_at(full_bytes, byte_val)

    var result = BooleanArray.from_bitmap(data_bm^)

    # Propagate nulls: if the input has a validity bitmap, the output inherits it.
    # `MmapAlignedBuffer.copy_from_view` (memcpy under the hood).
    if col.validity:
        var bm = Bitmap.create_all_valid(col.length)
        var bitmap_bytes = bytes_for_bits(col.length)
        if bitmap_bytes > 0:
            bm.buffer.copy_from_view(
                col.validity.value().buffer.view_range_ro(0, bitmap_bytes)
            )
        result.validity = bm^
        result.null_count = col.null_count

    return result^


def eval_is_null[
    dtype: DType
](col: PrimitiveArray[dtype]) -> BooleanArray:
    """Returns True where input is null, False where valid.

    Never produces nulls itself (output has no validity bitmap).
    If input has no validity bitmap, all outputs are False.

    Optimized: bitwise NOT of the validity bitmap using SIMD, with
    trailing bits cleared to avoid phantom True values.
    """
    var result = BooleanArray.allocate(col.length)

    if not col.validity:
        return result^

    # Result = ~validity. SIMD NOT over the bitmap bytes.
    # ByteView captures + load_simd / store_simd.
    var num_bytes = bytes_for_bits(col.length)
    var src_view = col.validity.value().buffer.view_ro()
    comptime width = SIMD_WIDTH_U8

    @always_inline
    def kernel[w: Int](idx: Int) {src_view, mut result}:
        var v = src_view.load_simd[DType.uint8, w](idx)
        result.data.buffer.view_mut().store_simd[DType.uint8, w](idx, ~v)

    vectorize[width](num_bytes, kernel)

    # Clear trailing bits in the last byte beyond `length` bits.
    var trailing = col.length & 7
    if trailing > 0 and num_bytes > 0:
        var mask = UInt8((1 << trailing) - 1)
        var cur = result.data.buffer.read_u8_at(num_bytes - 1)
        result.data.buffer.write_u8_at(num_bytes - 1, cur & mask)

    return result^


def eval_is_not_null[
    dtype: DType
](col: PrimitiveArray[dtype]) -> BooleanArray:
    """Returns True where input is valid, False where null.

    Inverse of eval_is_null. Never produces nulls itself.
    If input has no validity bitmap, all outputs are True.

    Optimized: for all-valid, uses Bitmap.create_all_valid (memset 0xFF).
    For nullable, the result is a direct COPY of the validity bitmap.
    """
    if not col.validity:
        # All valid — create_all_valid uses memset(0xFF) internally.
        var bm = Bitmap.create_all_valid(col.length)
        return BooleanArray.from_bitmap(bm^)

    # Result IS the validity bitmap — just memcpy.
    # Via `copy_from_view`.
    var num_bytes = bytes_for_bits(col.length)
    var bm = Bitmap.create(col.length)
    if num_bytes > 0:
        bm.buffer.copy_from_view(
            col.validity.value().buffer.view_range_ro(0, num_bytes)
        )
        bm.buffer.set_length(num_bytes)


    return BooleanArray.from_bitmap(bm^)
