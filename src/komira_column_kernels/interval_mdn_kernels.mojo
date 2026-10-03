# =============================================================================
# INTERVAL_MONTH_DAY_NANO compute kernels — equality, hash, take, lex_lt.
# =============================================================================
#
# Compute over the
# 16-byte byte-slab IntervalMonthDayNano column.  The triple layout is
# fixed by Arrow spec:
#
#   bytes [ 0..  4)  months  Int32 LE
#   bytes [ 4..  8)  days    Int32 LE
#   bytes [ 8.. 16)  nanos   Int64 LE
#
# Comparison semantics: per the Arrow spec (Schema.fbs IntervalUnit::MONTH_DAY_NANO),
# the three components are INDEPENDENT and ordering is NOT defined — there is
# no calendar-free total order.  This module deliberately does NOT provide
# `eval_gt` / `eval_lt` kernels; only:
#
#   * `eval_eq_interval_mdn`  — componentwise equality (well-defined).
#   * `hash_interval_mdn`     — FNV-1a over the 16-byte slab (deterministic).
#   * `take_interval_mdn`     — gather selected rows by row-index list.
#   * `filter_interval_mdn`   — apply a boolean mask, producing a packed array.
#   * `lex_lt_interval_mdn`   — (months, days, nanos) lex ordering.  Used by
#     sort-merge / dedup; NOT semantically meaningful as a "time" order.
#     Documented at the call site.
# =============================================================================

from std.memory import bitcast

from komira_arrow.interval_mdn_array import (
    IntervalMonthDayNanoArray,
    INTERVAL_MDN_BYTE_WIDTH,
    INTERVAL_MDN_MONTHS_OFFSET,
    INTERVAL_MDN_DAYS_OFFSET,
    INTERVAL_MDN_NANOS_OFFSET,
)
from komira_arrow.bitmap import Bitmap
from komira_buffer.heap_region import HeapRegion


# --- equality (componentwise) -----------------------------------------------


@always_inline
def _row_triple_eq(
    a: IntervalMonthDayNanoArray[HeapRegion], ai: Int,
    b: IntervalMonthDayNanoArray[HeapRegion], bi: Int,
) raises -> Bool:
    """True iff `a[ai]` and `b[bi]` have equal (months, days, nanos)."""
    var a_base = ai * INTERVAL_MDN_BYTE_WIDTH
    var b_base = bi * INTERVAL_MDN_BYTE_WIDTH
    var am = a.data.read_i32_le_at(a_base + INTERVAL_MDN_MONTHS_OFFSET)
    var bm = b.data.read_i32_le_at(b_base + INTERVAL_MDN_MONTHS_OFFSET)
    if am != bm:
        return False
    var ad = a.data.read_i32_le_at(a_base + INTERVAL_MDN_DAYS_OFFSET)
    var bd = b.data.read_i32_le_at(b_base + INTERVAL_MDN_DAYS_OFFSET)
    if ad != bd:
        return False
    var an = a.data.read_i64_le_at(a_base + INTERVAL_MDN_NANOS_OFFSET)
    var bn = b.data.read_i64_le_at(b_base + INTERVAL_MDN_NANOS_OFFSET)
    return an == bn


def eval_eq_interval_mdn(
    a: IntervalMonthDayNanoArray[HeapRegion], b: IntervalMonthDayNanoArray[HeapRegion],
) raises -> Bitmap[HeapRegion]:
    """Per-row componentwise equality.  Returns a Bitmap with
    `result.test(i) == True` iff a[i] == b[i] AND both rows are valid
    (or both arrays have no validity bitmap).  Nulls compare unequal.
    """
    if a.length != b.length:
        raise Error(
            "eval_eq_interval_mdn: length mismatch: "
            + String(a.length) + " vs " + String(b.length)
        )
    var n = a.length
    var out = Bitmap.create(n)
    for i in range(n):
        # Null on either side -> False.
        if a.validity:
            if not a.validity.value().test(i):
                continue
        if b.validity:
            if not b.validity.value().test(i):
                continue
        if _row_triple_eq(a, i, b, i):
            out.set(i)
    return out^


def eval_eq_interval_mdn_scalar(
    a: IntervalMonthDayNanoArray[HeapRegion],
    months: Int32, days: Int32, nanos: Int64,
) raises -> Bitmap[HeapRegion]:
    """Per-row equality of `a[i]` to a constant triple."""
    var n = a.length
    var out = Bitmap.create(n)
    for i in range(n):
        if a.validity:
            if not a.validity.value().test(i):
                continue
        var base = i * INTERVAL_MDN_BYTE_WIDTH
        var m = a.data.read_i32_le_at(base + INTERVAL_MDN_MONTHS_OFFSET)
        if m != months:
            continue
        var d = a.data.read_i32_le_at(base + INTERVAL_MDN_DAYS_OFFSET)
        if d != days:
            continue
        var nn = a.data.read_i64_le_at(base + INTERVAL_MDN_NANOS_OFFSET)
        if nn == nanos:
            out.set(i)
    return out^


# --- hash (FNV-1a 64-bit over the 16-byte slab) -----------------------------


comptime _FNV_OFFSET_64: UInt64 = 0xCBF29CE484222325
comptime _FNV_PRIME_64: UInt64 = 0x100000001B3


@always_inline
def _fnv1a_byte(h: UInt64, b: UInt8) -> UInt64:
    return (h ^ UInt64(b)) * _FNV_PRIME_64


@always_inline
def _fnv1a_u32_le(h: UInt64, v: UInt32) -> UInt64:
    var h0 = _fnv1a_byte(h, UInt8(v & 0xFF))
    var h1 = _fnv1a_byte(h0, UInt8((v >> 8) & 0xFF))
    var h2 = _fnv1a_byte(h1, UInt8((v >> 16) & 0xFF))
    return _fnv1a_byte(h2, UInt8((v >> 24) & 0xFF))


@always_inline
def _fnv1a_u64_le(h: UInt64, v: UInt64) -> UInt64:
    var h0 = _fnv1a_byte(h, UInt8(v & 0xFF))
    var h1 = _fnv1a_byte(h0, UInt8((v >> 8) & 0xFF))
    var h2 = _fnv1a_byte(h1, UInt8((v >> 16) & 0xFF))
    var h3 = _fnv1a_byte(h2, UInt8((v >> 24) & 0xFF))
    var h4 = _fnv1a_byte(h3, UInt8((v >> 32) & 0xFF))
    var h5 = _fnv1a_byte(h4, UInt8((v >> 40) & 0xFF))
    var h6 = _fnv1a_byte(h5, UInt8((v >> 48) & 0xFF))
    return _fnv1a_byte(h6, UInt8((v >> 56) & 0xFF))


@always_inline
def hash_one_interval_mdn(
    months: Int32, days: Int32, nanos: Int64,
) -> UInt64:
    """FNV-1a 64-bit hash of one (months, days, nanos) triple.

    All 16 bytes of the slab contribute — this is NOT a permutation-invariant
    combine.  Two triples that are componentwise equal hash to the same
    value; two triples that share two of three components but differ in the
    third hash to (essentially always) distinct values.

    Used by hash-table / hash-join / GROUP BY on INTERVAL_MONTH_DAY_NANO
    keys.  Equality semantics: well-defined componentwise (see
    `eval_eq_interval_mdn`).
    """
    var h = _FNV_OFFSET_64
    h = _fnv1a_u32_le(h, UInt32(months))
    h = _fnv1a_u32_le(h, UInt32(days))
    h = _fnv1a_u64_le(h, UInt64(nanos))
    return h


def hash_interval_mdn(arr: IntervalMonthDayNanoArray[HeapRegion]) raises -> List[UInt64]:
    """Hash each row of an IntervalMonthDayNanoArray[HeapRegion] to a UInt64.

    Null rows hash to 0 (consistent with the rest of the agg infra).
    """
    var n = arr.length
    var out = List[UInt64](capacity=n)
    for i in range(n):
        if arr.validity:
            if not arr.validity.value().test(i):
                out.append(UInt64(0))
                continue
        var base = i * INTERVAL_MDN_BYTE_WIDTH
        var m = arr.data.read_i32_le_at(base + INTERVAL_MDN_MONTHS_OFFSET)
        var d = arr.data.read_i32_le_at(base + INTERVAL_MDN_DAYS_OFFSET)
        var nn = arr.data.read_i64_le_at(base + INTERVAL_MDN_NANOS_OFFSET)
        out.append(hash_one_interval_mdn(m, d, nn))
    return out^


# --- take (gather by row-index list) ----------------------------------------


def take_interval_mdn(
    src: IntervalMonthDayNanoArray[HeapRegion], indices: List[Int],
) raises -> IntervalMonthDayNanoArray[HeapRegion]:
    """Gather rows from `src` into a new array at the given indices.

    Mechanical 16-byte byte-slab copy per index — no per-component
    interpretation needed.  Validity tracked: any source-null row
    becomes a null row in the output.
    """
    var n_out = len(indices)
    # Always preserve a validity bitmap if the source has one or any
    # selected row was null — the caller can drop it post-hoc.
    var has_src_validity = Bool(src.validity)
    var out: IntervalMonthDayNanoArray[HeapRegion]
    if has_src_validity:
        out = IntervalMonthDayNanoArray.allocate_nullable(n_out)
    else:
        out = IntervalMonthDayNanoArray.allocate(n_out)
    for r in range(n_out):
        var src_idx = indices[r]
        if src_idx < 0 or src_idx >= src.length:
            raise Error(
                "take_interval_mdn: index " + String(src_idx)
                + " out of range [0, " + String(src.length) + ")"
            )
        # Copy 16 bytes from src[src_idx*16..+16) to out[r*16..+16).
        var src_off = src_idx * INTERVAL_MDN_BYTE_WIDTH
        var dst_off = r * INTERVAL_MDN_BYTE_WIDTH
        # Two i64-LE word copies preserve the (m, d, nanos) layout
        # without per-component interpretation.
        var lo = src.data.read_i64_le_at(src_off)
        var hi = src.data.read_i64_le_at(src_off + 8)
        out.data.write_i64_le_at(dst_off, lo)
        out.data.write_i64_le_at(dst_off + 8, hi)
        # Validity follow-through.
        if has_src_validity:
            if not src.validity.value().test(src_idx):
                out.set_null(r)
    return out^


# --- filter (apply a boolean mask) ------------------------------------------


def filter_interval_mdn(
    src: IntervalMonthDayNanoArray[HeapRegion], mask: Bitmap[HeapRegion],
) raises -> IntervalMonthDayNanoArray[HeapRegion]:
    """Select rows where `mask.test(i) == True`.  Equivalent to
    `take_interval_mdn(src, [i for i in range(n) if mask.test(i)])` but
    avoids the intermediate index list."""
    if mask.length != src.length:
        raise Error(
            "filter_interval_mdn: mask length " + String(mask.length)
            + " != source length " + String(src.length)
        )
    var indices = List[Int]()
    for i in range(src.length):
        if mask.test(i):
            indices.append(i)
    return take_interval_mdn(src, indices)


# --- lex_lt (deterministic order — NOT a calendar order) --------------------


@always_inline
def lex_lt_one_interval_mdn(
    am: Int32, ad: Int32, an: Int64,
    bm: Int32, bd: Int32, bn: Int64,
) -> Bool:
    """(months, days, nanos) lexicographic less-than.

    WARNING — NOT SEMANTICALLY MEANINGFUL as a time order: (1 month, 0 days,
    0 ns) vs (0 months, 31 days, 0 ns) — the lex order says the first is
    greater, but those intervals are not comparable as durations without
    a calendar.  Use this only for deterministic sort-merge / dedup tie-
    breaks where a stable but arbitrary order is required.  Arrow spec
    (Schema.fbs IntervalUnit::MONTH_DAY_NANO) leaves ordering undefined;
    this function does NOT claim spec compliance for ordering semantics.
    """
    if am != bm:
        return am < bm
    if ad != bd:
        return ad < bd
    return an < bn


def lex_lt_interval_mdn(
    a: IntervalMonthDayNanoArray[HeapRegion], b: IntervalMonthDayNanoArray[HeapRegion],
) raises -> Bitmap[HeapRegion]:
    """Per-row (months, days, nanos) lex less-than.  Useful for stable
    sort-merge keys; see `lex_lt_one_interval_mdn` for the caveat that
    this order is NOT calendar-meaningful."""
    if a.length != b.length:
        raise Error(
            "lex_lt_interval_mdn: length mismatch: "
            + String(a.length) + " vs " + String(b.length)
        )
    var n = a.length
    var out = Bitmap.create(n)
    for i in range(n):
        if a.validity:
            if not a.validity.value().test(i):
                continue
        if b.validity:
            if not b.validity.value().test(i):
                continue
        var a_base = i * INTERVAL_MDN_BYTE_WIDTH
        var b_base = i * INTERVAL_MDN_BYTE_WIDTH
        var am = a.data.read_i32_le_at(a_base + INTERVAL_MDN_MONTHS_OFFSET)
        var bm = b.data.read_i32_le_at(b_base + INTERVAL_MDN_MONTHS_OFFSET)
        var ad = a.data.read_i32_le_at(a_base + INTERVAL_MDN_DAYS_OFFSET)
        var bd = b.data.read_i32_le_at(b_base + INTERVAL_MDN_DAYS_OFFSET)
        var an = a.data.read_i64_le_at(a_base + INTERVAL_MDN_NANOS_OFFSET)
        var bn = b.data.read_i64_le_at(b_base + INTERVAL_MDN_NANOS_OFFSET)
        if lex_lt_one_interval_mdn(am, ad, an, bm, bd, bn):
            out.set(i)
    return out^


# --- componentwise arithmetic (add / sub) -----------------------------------
#
# Per the Arrow spec
# (Schema.fbs IntervalUnit::MONTH_DAY_NANO): "Each field is independent
# (e.g. there is no constraint that nanoseconds have the same sign as
# days or that the quantity of nanoseconds represents less than a day's
# worth of time)."  Therefore add/sub apply COMPONENTWISE — no carry
# between fields, no calendar resolution.
#
# Overflow handling is per-field:
#   * months_out = a.months + b.months  — wraps on Int32 (silent two's-
#     complement wrap, matching Arrow / DuckDB / DataFusion behavior).
#   * days_out   = a.days   + b.days    — wraps on Int32 (same).
#   * nanos_out  = a.nanos  + b.nanos   — wraps on Int64 (same).
#
# This is the well-defined componentwise behavior; calendar-aware
# Timestamp + Interval arithmetic (which DOES require carry from days into
# months via the day-count of each month, plus tz-aware DST rules) is not
# implemented here.
#
# Validity: result row is valid iff BOTH input rows are valid (standard
# "AND-the-validity-bitmaps" semantics, mirroring numeric add).


@always_inline
def _row_add(
    a: IntervalMonthDayNanoArray[HeapRegion], ai: Int,
    b: IntervalMonthDayNanoArray[HeapRegion], bi: Int,
) raises -> Tuple[Int32, Int32, Int64]:
    """Componentwise add of a[ai] + b[bi]; per-field Int32/Int64 wrap."""
    var a_base = ai * INTERVAL_MDN_BYTE_WIDTH
    var b_base = bi * INTERVAL_MDN_BYTE_WIDTH
    var am = a.data.read_i32_le_at(a_base + INTERVAL_MDN_MONTHS_OFFSET)
    var bm = b.data.read_i32_le_at(b_base + INTERVAL_MDN_MONTHS_OFFSET)
    var ad = a.data.read_i32_le_at(a_base + INTERVAL_MDN_DAYS_OFFSET)
    var bd = b.data.read_i32_le_at(b_base + INTERVAL_MDN_DAYS_OFFSET)
    var an = a.data.read_i64_le_at(a_base + INTERVAL_MDN_NANOS_OFFSET)
    var bn = b.data.read_i64_le_at(b_base + INTERVAL_MDN_NANOS_OFFSET)
    # Silent two's-complement wrap on the native add — matches Arrow spec
    # (independent fields, no overflow signaling).
    return (am + bm, ad + bd, an + bn)


@always_inline
def _row_sub(
    a: IntervalMonthDayNanoArray[HeapRegion], ai: Int,
    b: IntervalMonthDayNanoArray[HeapRegion], bi: Int,
) raises -> Tuple[Int32, Int32, Int64]:
    """Componentwise sub of a[ai] - b[bi]; per-field Int32/Int64 wrap."""
    var a_base = ai * INTERVAL_MDN_BYTE_WIDTH
    var b_base = bi * INTERVAL_MDN_BYTE_WIDTH
    var am = a.data.read_i32_le_at(a_base + INTERVAL_MDN_MONTHS_OFFSET)
    var bm = b.data.read_i32_le_at(b_base + INTERVAL_MDN_MONTHS_OFFSET)
    var ad = a.data.read_i32_le_at(a_base + INTERVAL_MDN_DAYS_OFFSET)
    var bd = b.data.read_i32_le_at(b_base + INTERVAL_MDN_DAYS_OFFSET)
    var an = a.data.read_i64_le_at(a_base + INTERVAL_MDN_NANOS_OFFSET)
    var bn = b.data.read_i64_le_at(b_base + INTERVAL_MDN_NANOS_OFFSET)
    return (am - bm, ad - bd, an - bn)


def _scalar_add_interval_mdn(
    a: IntervalMonthDayNanoArray[HeapRegion], b: IntervalMonthDayNanoArray[HeapRegion],
) raises -> IntervalMonthDayNanoArray[HeapRegion]:
    """Scalar reference implementation of componentwise add.

    Kept as a private symbol so that a SIMD parity test can compare SIMD
    output byte-for-byte to a known-correct baseline.  Do NOT call from
    production code — use the public `add_interval_mdn` which dispatches
    to the SIMD path."""
    if a.length != b.length:
        raise Error(
            "add_interval_mdn: length mismatch: "
            + String(a.length) + " vs " + String(b.length)
        )
    var n = a.length
    var has_nulls = Bool(a.validity) or Bool(b.validity)
    var out: IntervalMonthDayNanoArray[HeapRegion]
    if has_nulls:
        out = IntervalMonthDayNanoArray.allocate_nullable(n)
    else:
        out = IntervalMonthDayNanoArray.allocate(n)
    for i in range(n):
        # Null propagation: NULL ⊕ anything == NULL.
        var a_null = False
        if a.validity:
            a_null = not a.validity.value().test(i)
        var b_null = False
        if b.validity:
            b_null = not b.validity.value().test(i)
        if a_null or b_null:
            if has_nulls:
                out.set_null(i)
            continue
        var t = _row_add(a, i, b, i)
        # Use the byte-slab writer directly so we don't pay set_triple's
        # validity bookkeeping per row (we just allocated all-valid).
        var dst_base = i * INTERVAL_MDN_BYTE_WIDTH
        out.data.write_i32_le_at(dst_base + INTERVAL_MDN_MONTHS_OFFSET, t[0])
        out.data.write_i32_le_at(dst_base + INTERVAL_MDN_DAYS_OFFSET, t[1])
        out.data.write_i64_le_at(dst_base + INTERVAL_MDN_NANOS_OFFSET, t[2])
    return out^


def _scalar_sub_interval_mdn(
    a: IntervalMonthDayNanoArray[HeapRegion], b: IntervalMonthDayNanoArray[HeapRegion],
) raises -> IntervalMonthDayNanoArray[HeapRegion]:
    """Scalar reference implementation of componentwise sub.  Parity
    oracle for the SIMD parity test; not for production use."""
    if a.length != b.length:
        raise Error(
            "sub_interval_mdn: length mismatch: "
            + String(a.length) + " vs " + String(b.length)
        )
    var n = a.length
    var has_nulls = Bool(a.validity) or Bool(b.validity)
    var out: IntervalMonthDayNanoArray[HeapRegion]
    if has_nulls:
        out = IntervalMonthDayNanoArray.allocate_nullable(n)
    else:
        out = IntervalMonthDayNanoArray.allocate(n)
    for i in range(n):
        var a_null = False
        if a.validity:
            a_null = not a.validity.value().test(i)
        var b_null = False
        if b.validity:
            b_null = not b.validity.value().test(i)
        if a_null or b_null:
            if has_nulls:
                out.set_null(i)
            continue
        var t = _row_sub(a, i, b, i)
        var dst_base = i * INTERVAL_MDN_BYTE_WIDTH
        out.data.write_i32_le_at(dst_base + INTERVAL_MDN_MONTHS_OFFSET, t[0])
        out.data.write_i32_le_at(dst_base + INTERVAL_MDN_DAYS_OFFSET, t[1])
        out.data.write_i64_le_at(dst_base + INTERVAL_MDN_NANOS_OFFSET, t[2])
    return out^


# --- SIMD-accelerated componentwise arithmetic ------------------------------
#
# Hand-staged SIMD over the 16-byte AoS row layout.  The challenge: a single
# 16-byte row contains TWO independent i32 lanes (months, days) AND one i64
# lane (nanos), so no single uniform SIMD width gives correct wrap semantics
# for all three.
#
# Strategy J — dual-view + blend per 4-row (64-byte) chunk:
#   1. Add the chunk as `SIMD[Int32, 16]` — correct per-i32-lane wrap for
#      months / days lanes (0, 1, 4, 5, 8, 9, 12, 13).
#   2. Add the same chunk as `SIMD[Int64, 8]` — correct per-i64-lane wrap
#      for nanos lanes (1, 3, 5, 7 in i64-view = lanes 2,3 / 6,7 / 10,11
#      / 14,15 when bitcast back to i32x16).
#   3. Bitcast the i64 result to i32x16 and BLEND: keep i32 result for
#      lanes 0,1,4,5,8,9,12,13; keep bitcast-i64 result for lanes
#      2,3,6,7,10,11,14,15.
#   4. Store the blended i32x16 back at the same byte offset.
#
# Modern LLVM coalesces the two loads at the same address into one memory
# op.  The blend is `.select(mask, i32_result, i64_result_as_i32)` with a
# comptime-known mask.
#
# Validity handling: SIMD pass writes to every byte unconditionally
# (garbage-byte arithmetic on NULL rows is harmless — integer wrap is
# total).  After the SIMD pass, walk the validity bitmaps and set out's
# validity to `a.validity AND b.validity`.


comptime _SIMD_W_ROWS: Int = 4
"""Rows per SIMD chunk (4 rows = 64 bytes; SIMD[Int32, 16] + SIMD[Int64, 8])."""

comptime _SIMD_CHUNK_BYTES: Int = _SIMD_W_ROWS * INTERVAL_MDN_BYTE_WIDTH


@always_inline
def _build_blend_mask() -> SIMD[DType.bool, 16]:
    """Lane-mask for Strategy J blend.

    True at lanes 0, 1, 4, 5, 8, 9, 12, 13 — the months/days slots that
    take their value from the i32-add result.
    False at lanes 2, 3, 6, 7, 10, 11, 14, 15 — the nanos slots that
    take their value from the bitcast-i64-add result.

    Compile-time-known per `@always_inline`; LLVM materializes as a
    constant vector.
    """
    return SIMD[DType.bool, 16](
        True, True, False, False,
        True, True, False, False,
        True, True, False, False,
        True, True, False, False,
    )


@always_inline
def _validity_and(
    a: IntervalMonthDayNanoArray[HeapRegion],
    b: IntervalMonthDayNanoArray[HeapRegion],
    mut out: IntervalMonthDayNanoArray[HeapRegion],
) raises:
    """Set out.validity[i] = a.validity[i] AND b.validity[i] for all i.

    Called AFTER the SIMD arithmetic pass to mark NULL rows.  No-op when
    neither input has a validity bitmap (out has no bitmap either —
    standard non-nullable shape).
    """
    var has_a = Bool(a.validity)
    var has_b = Bool(b.validity)
    if not has_a and not has_b:
        return  # neither input nullable -> out non-nullable
    var n = a.length
    for i in range(n):
        var valid = True
        if has_a:
            if not a.validity.value().test(i):
                valid = False
        if has_b and valid:
            if not b.validity.value().test(i):
                valid = False
        if not valid:
            # set_null updates out.null_count internally.
            out.set_null(i)


@always_inline
def _simd_add_chunk(
    a: IntervalMonthDayNanoArray[HeapRegion],
    b: IntervalMonthDayNanoArray[HeapRegion],
    mut out: IntervalMonthDayNanoArray[HeapRegion],
    chunk_byte_offset: Int,
) raises:
    """Add one 4-row chunk via dual-view + blend.

    Pre: `chunk_byte_offset + 64 <= each array's byte capacity`.

    Performance note: each operand is loaded ONCE as SIMD[Int32, 16];
    the Int64 view is derived via in-register bitcast (zero memory ops).
    This is the minimum-load-count shape — 2 loads + 1 store per chunk
    + 2 adds + 1 blend.  Modern LLVM lowers the i32-add and i64-add
    operations to the same set of native instructions on most ISAs.
    """
    var a_i32 = a.data.load_simd[DType.int32, 16](chunk_byte_offset)
    var b_i32 = b.data.load_simd[DType.int32, 16](chunk_byte_offset)
    var sum_i32 = a_i32 + b_i32

    # In-register bitcast: same 64-byte payload as two different SIMD
    # vector views.  Zero memory ops.  The i64 add uses LLVM's natural
    # 64-bit lane semantics — full carry within each lane.
    var a_i64 = bitcast[DType.int64, width=8](a_i32)
    var b_i64 = bitcast[DType.int64, width=8](b_i32)
    var sum_i64 = a_i64 + b_i64

    var sum_i64_as_i32 = bitcast[DType.int32, width=16](sum_i64)
    var blended = _build_blend_mask().select(sum_i32, sum_i64_as_i32)
    out.data.store_simd[DType.int32, 16](chunk_byte_offset, blended)


@always_inline
def _simd_sub_chunk(
    a: IntervalMonthDayNanoArray[HeapRegion],
    b: IntervalMonthDayNanoArray[HeapRegion],
    mut out: IntervalMonthDayNanoArray[HeapRegion],
    chunk_byte_offset: Int,
) raises:
    """Sub one 4-row chunk via dual-view + blend.  See `_simd_add_chunk`
    for the load-count rationale."""
    var a_i32 = a.data.load_simd[DType.int32, 16](chunk_byte_offset)
    var b_i32 = b.data.load_simd[DType.int32, 16](chunk_byte_offset)
    var sum_i32 = a_i32 - b_i32

    var a_i64 = bitcast[DType.int64, width=8](a_i32)
    var b_i64 = bitcast[DType.int64, width=8](b_i32)
    var sum_i64 = a_i64 - b_i64

    var sum_i64_as_i32 = bitcast[DType.int32, width=16](sum_i64)
    var blended = _build_blend_mask().select(sum_i32, sum_i64_as_i32)
    out.data.store_simd[DType.int32, 16](chunk_byte_offset, blended)


@always_inline
def _scalar_add_row(
    a: IntervalMonthDayNanoArray[HeapRegion],
    b: IntervalMonthDayNanoArray[HeapRegion],
    mut out: IntervalMonthDayNanoArray[HeapRegion],
    i: Int,
) raises:
    """Add a single row; used for tail rows after the SIMD chunk loop."""
    var t = _row_add(a, i, b, i)
    var dst_base = i * INTERVAL_MDN_BYTE_WIDTH
    out.data.write_i32_le_at(dst_base + INTERVAL_MDN_MONTHS_OFFSET, t[0])
    out.data.write_i32_le_at(dst_base + INTERVAL_MDN_DAYS_OFFSET, t[1])
    out.data.write_i64_le_at(dst_base + INTERVAL_MDN_NANOS_OFFSET, t[2])


@always_inline
def _scalar_sub_row(
    a: IntervalMonthDayNanoArray[HeapRegion],
    b: IntervalMonthDayNanoArray[HeapRegion],
    mut out: IntervalMonthDayNanoArray[HeapRegion],
    i: Int,
) raises:
    """Sub a single row; used for tail rows after the SIMD chunk loop."""
    var t = _row_sub(a, i, b, i)
    var dst_base = i * INTERVAL_MDN_BYTE_WIDTH
    out.data.write_i32_le_at(dst_base + INTERVAL_MDN_MONTHS_OFFSET, t[0])
    out.data.write_i32_le_at(dst_base + INTERVAL_MDN_DAYS_OFFSET, t[1])
    out.data.write_i64_le_at(dst_base + INTERVAL_MDN_NANOS_OFFSET, t[2])


def add_interval_mdn(
    a: IntervalMonthDayNanoArray[HeapRegion], b: IntervalMonthDayNanoArray[HeapRegion],
) raises -> IntervalMonthDayNanoArray[HeapRegion]:
    """Componentwise add: out[i] = (a[i].months + b[i].months,
    a[i].days + b[i].days, a[i].nanos + b[i].nanos).

    Per-field Int32 / Int64 wrap (matches Arrow spec — independent fields,
    no overflow signaling).  Result row is NULL iff either input row is NULL
    (standard validity-AND semantics).

    SIMD-accelerated via Strategy J (dual-view + blend per 4-row chunk).
    Short arrays (< 4 rows) take the scalar fast path; tail rows after
    the chunk loop also go scalar.  See `_scalar_add_interval_mdn` for
    the parity-oracle baseline used by the SIMD parity tests."""
    if a.length != b.length:
        raise Error(
            "add_interval_mdn: length mismatch: "
            + String(a.length) + " vs " + String(b.length)
        )
    var n = a.length
    if n < _SIMD_W_ROWS:
        return _scalar_add_interval_mdn(a, b)
    var has_nulls = Bool(a.validity) or Bool(b.validity)
    var out: IntervalMonthDayNanoArray[HeapRegion]
    if has_nulls:
        out = IntervalMonthDayNanoArray.allocate_nullable(n)
    else:
        out = IntervalMonthDayNanoArray.allocate(n)

    # SIMD main loop — process 4 rows (64 bytes) per iteration.
    var n_simd_rows = (n // _SIMD_W_ROWS) * _SIMD_W_ROWS
    var chunk = 0
    while chunk < n_simd_rows:
        _simd_add_chunk(a, b, out, chunk * INTERVAL_MDN_BYTE_WIDTH)
        chunk += _SIMD_W_ROWS

    # Scalar tail — at most 3 rows left.
    var i = n_simd_rows
    while i < n:
        _scalar_add_row(a, b, out, i)
        i += 1

    # Validity AND post-pass — overwrites garbage-byte arithmetic on
    # NULL rows with their NULL marker.  No-op when both inputs are
    # non-nullable.
    _validity_and(a, b, out)
    return out^


def sub_interval_mdn(
    a: IntervalMonthDayNanoArray[HeapRegion], b: IntervalMonthDayNanoArray[HeapRegion],
) raises -> IntervalMonthDayNanoArray[HeapRegion]:
    """Componentwise sub: out[i] = (a[i].months - b[i].months,
    a[i].days - b[i].days, a[i].nanos - b[i].nanos).

    Per-field Int32 / Int64 wrap.  Validity: NULL iff either input is NULL.

    SIMD-accelerated via Strategy J (dual-view + blend per 4-row chunk);
    see `add_interval_mdn` for the dispatch pattern."""
    if a.length != b.length:
        raise Error(
            "sub_interval_mdn: length mismatch: "
            + String(a.length) + " vs " + String(b.length)
        )
    var n = a.length
    if n < _SIMD_W_ROWS:
        return _scalar_sub_interval_mdn(a, b)
    var has_nulls = Bool(a.validity) or Bool(b.validity)
    var out: IntervalMonthDayNanoArray[HeapRegion]
    if has_nulls:
        out = IntervalMonthDayNanoArray.allocate_nullable(n)
    else:
        out = IntervalMonthDayNanoArray.allocate(n)

    var n_simd_rows = (n // _SIMD_W_ROWS) * _SIMD_W_ROWS
    var chunk = 0
    while chunk < n_simd_rows:
        _simd_sub_chunk(a, b, out, chunk * INTERVAL_MDN_BYTE_WIDTH)
        chunk += _SIMD_W_ROWS

    var i = n_simd_rows
    while i < n:
        _scalar_sub_row(a, b, out, i)
        i += 1

    _validity_and(a, b, out)
    return out^
