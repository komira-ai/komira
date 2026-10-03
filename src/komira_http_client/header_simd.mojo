# =============================================================================
# src/komira_http_client/header_simd.mojo
#   Hand-staged SIMD primitives for HeaderMap byte-pipeline.
# =============================================================================
# Mojo does not autovectorize these loops, so the SIMD code is written by
# hand.
#
# Mojo 1.0.0b1's autovectorizer does NOT fire on unit-stride byte loops
# (a known compiler limitation). This
# module hand-stages SIMD for the HeaderMap byte-copy + case-fold hot
# paths via explicit `SIMD[DType.uint8, 16]` load/store. On linux-x86_64
# (SSE2/AVX2 always available) `chunk=16` lowers to `movdqu xmm`.
#
# Three primitives:
#   _simd_bulk_copy[chunk]      — byte-identical chunk copy.
#   _simd_case_fold_copy[chunk] — chunk copy + ASCII upper→lower fold.
#   _simd_ci_eq[chunk]          — case-insensitive byte equality compare.
#
# Encapsulation discipline:
#   * `UnsafePointer` is INTERNAL to this module. Callers use
#     `Span[UInt8, _]` adapters (`bulk_copy_span` / `case_fold_copy_span`).
#   * All origin parameters are concrete (no wildcard).
#   * No `unsafe_from_address`. No `take_pointee`. No `ArcPointer`.
#   * Helpers replace scalar List.append loops at HeaderMap call sites;
#     no additive parallel API.
# =============================================================================



# =============================================================================
# §1 — Constants.
# =============================================================================

# 16 = SSE2 native UInt8 lane count, also the smallest AVX register that
# SIMD-byte-compare instructions lower to (pcmpgtb xmm). Larger widths
# (32 = AVX2 ymm) emulate to two 16-byte ops with no throughput gain at
# the typical header-name/value size (10-30 bytes).
comptime SIMD_CHUNK_BYTES: Int = 16

comptime _UPPER_A_MINUS_1: UInt8 = 0x40  # 'A' - 1 = 0x40
comptime _UPPER_Z_PLUS_1:  UInt8 = 0x5B  # 'Z' + 1 = 0x5B
comptime _CASE_DELTA:      UInt8 = 0x20  # 'a' - 'A'


# =============================================================================
# §2 — Primitive 1: bulk byte copy.
# =============================================================================


@always_inline
def _simd_bulk_copy_ptr[
    chunk: Int,
    src_o: Origin[mut=False],
    dst_o: Origin[mut=True],
](
    src: UnsafePointer[UInt8, src_o],
    dst: UnsafePointer[UInt8, dst_o],
    n: Int,
):
    """PERF-CRITICAL: SIMD chunk-copy `n` bytes from `src` to `dst`.

    Loop body emits two `movdqu xmm` instructions per 16-byte iteration
    on linux-x86_64 (SSE2/AVX2). Scalar tail handles `n % chunk` bytes.

    SAFETY: caller guarantees `src + n` and `dst + n` are in-bounds for
    the respective allocations. This is the PRIVATE pointer-taking
    form; the public Span-based wrapper (`bulk_copy_span`) is the API
    surface.

    Pattern: unit-stride elementwise.
    """
    var i = 0
    var simd_end = (n // chunk) * chunk
    while i < simd_end:
        var v = src.load[width=chunk](i)
        dst.store[width=chunk](i, v)
        i += chunk
    while i < n:
        dst[i] = src[i]
        i += 1


@always_inline
def bulk_copy_span[
    src_o: Origin[mut=False],
    dst_o: Origin[mut=True],
](
    src: Span[UInt8, src_o],
    dst: Span[UInt8, dst_o],
):
    """Public API: SIMD chunk-copy `len(src)` bytes into `dst`.

    Requires len(dst) >= len(src). Returns silently — caller pre-checked.
    Pattern: unit-stride chunk copy.
    """
    var n = len(src)
    _simd_bulk_copy_ptr[SIMD_CHUNK_BYTES, src_o, dst_o](
        src.unsafe_ptr(), dst.unsafe_ptr(), n,
    )


# =============================================================================
# §3 — Primitive 2: ASCII case-fold copy (A..Z -> a..z).
# =============================================================================


@always_inline
def _simd_case_fold_copy_ptr[
    chunk: Int,
    src_o: Origin[mut=False],
    dst_o: Origin[mut=True],
](
    src: UnsafePointer[UInt8, src_o],
    dst: UnsafePointer[UInt8, dst_o],
    n: Int,
):
    """PERF-CRITICAL: SIMD chunk-copy with ASCII upper→lower case-fold.

    For each byte `b`:
      - if 0x41 <= b <= 0x5A: write b + 0x20.
      - else: write b unchanged.

    Implemented branchless via SIMD lane-compare + select. Expected
    asm (linux-x86_64): `movdqu xmm0, [src]` ; `pcmpgtb` (twice for
    lower/upper bound) ; `pand` (mask intersect) ; `pand` (mask the
    delta) ; `paddb xmm0, ...` ; `movdqu [dst], xmm0`.

    SAFETY: same as `_simd_bulk_copy_ptr`.

    Pattern: branchless mask plus chunk copy.
    """
    var i = 0
    var simd_end = (n // chunk) * chunk
    var lower_bound = SIMD[DType.uint8, chunk](_UPPER_A_MINUS_1)
    var upper_bound = SIMD[DType.uint8, chunk](_UPPER_Z_PLUS_1)
    var delta_vec   = SIMD[DType.uint8, chunk](_CASE_DELTA)
    var zero_vec    = SIMD[DType.uint8, chunk](UInt8(0))
    while i < simd_end:
        var v = src.load[width=chunk](i)
        # Mask: lane True iff 'A' <= v[i] <= 'Z' (i.e. 0x40 < v < 0x5B).
        # Note: SIMD comparison returns SIMD[DType.bool, chunk]; bitwise
        # `&` on bool-SIMD lowers to `pand xmm`.
        var gt_low = v.gt(lower_bound)
        var lt_high = v.lt(upper_bound)
        var is_upper = gt_low & lt_high
        # Branchless fold: add 0x20 where mask is True, else add 0.
        var fold = is_upper.select(delta_vec, zero_vec)
        var folded = v + fold
        dst.store[width=chunk](i, folded)
        i += chunk
    while i < n:
        var b = src[i]
        if b >= UInt8(0x41) and b <= UInt8(0x5A):
            dst[i] = b + UInt8(0x20)
        else:
            dst[i] = b
        i += 1


@always_inline
def case_fold_copy_span[
    src_o: Origin[mut=False],
    dst_o: Origin[mut=True],
](
    src: Span[UInt8, src_o],
    dst: Span[UInt8, dst_o],
):
    """Public API: SIMD chunk-copy `len(src)` bytes into `dst` with
    ASCII upper-to-lower case fold."""
    var n = len(src)
    _simd_case_fold_copy_ptr[SIMD_CHUNK_BYTES, src_o, dst_o](
        src.unsafe_ptr(), dst.unsafe_ptr(), n,
    )


# =============================================================================
# §4 — Primitive 3: case-insensitive byte equality.
# =============================================================================


@always_inline
def _simd_ci_eq_ptr[
    chunk: Int,
    a_o: Origin[mut=False],
    b_o: Origin[mut=False],
](
    a: UnsafePointer[UInt8, a_o],
    b: UnsafePointer[UInt8, b_o],
    n: Int,
) -> Bool:
    """PERF-CRITICAL: case-insensitive byte equality of `a` and `b` over
    `n` bytes. `b` is assumed already lowercased (caller invariant —
    typically a static lowercase header-name constant).

    Returns True iff for every i in [0, n): lower(a[i]) == b[i].

    Expected asm: `movdqu xmm0, [a]` ; `movdqu xmm1, [b]` ; `pcmpgtb`
    (case-fold mask) ; `pand` (delta mask) ; `paddb` (fold a) ;
    `pcmpeqb xmm0, xmm1` ; `pmovmskb eax, xmm0` ; `cmp eax, 0xFFFF`
    ; `jne early_exit`. Per 16-byte chunk.

    Early exit on first mismatch via reduce_or short-circuit.

    SAFETY: caller guarantees both pointers cover >= n bytes.

    Pattern: branchless mask, in lockstep with a scalar fallback.
    """
    var i = 0
    var simd_end = (n // chunk) * chunk
    var lower_bound = SIMD[DType.uint8, chunk](_UPPER_A_MINUS_1)
    var upper_bound = SIMD[DType.uint8, chunk](_UPPER_Z_PLUS_1)
    var delta_vec   = SIMD[DType.uint8, chunk](_CASE_DELTA)
    var zero_vec    = SIMD[DType.uint8, chunk](UInt8(0))
    while i < simd_end:
        var av = a.load[width=chunk](i)
        var bv = b.load[width=chunk](i)
        var gt_low = av.gt(lower_bound)
        var lt_high = av.lt(upper_bound)
        var is_upper = gt_low & lt_high
        var fold = is_upper.select(delta_vec, zero_vec)
        var av_lower = av + fold
        var diff = av_lower.ne(bv)
        if diff.reduce_or():
            return False
        i += chunk
    while i < n:
        var ac = a[i]
        if ac >= UInt8(0x41) and ac <= UInt8(0x5A):
            ac = ac + UInt8(0x20)
        if ac != b[i]:
            return False
        i += 1
    return True


@always_inline
def ci_eq_span[
    a_o: Origin[mut=False],
    b_o: Origin[mut=False],
](
    a: Span[UInt8, a_o],
    b_already_lower: Span[UInt8, b_o],
) -> Bool:
    """Public API: case-insensitive byte equality. `b_already_lower`
    is assumed lowercased by the caller (static constant or pre-
    canonicalized buffer). Returns False if lengths differ."""
    if len(a) != len(b_already_lower):
        return False
    return _simd_ci_eq_ptr[SIMD_CHUNK_BYTES, a_o, b_o](
        a.unsafe_ptr(), b_already_lower.unsafe_ptr(), len(a),
    )
