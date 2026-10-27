# =============================================================================
# byte_memmem.mojo — SIMD substring (needle-in-haystack) search.
# =============================================================================
#
# Highway / memchr-class "first+last byte" memmem.  byte_find_any_of finds
# any of N single needle BYTES; this module finds a fixed multi-byte NEEDLE
# (a substring) inside a haystack.  It is the SIMD analogue of glibc's
# memmem-fast / std::search / Hyperscan's literal matcher.
#
# Algorithm (the "first+last byte" SIMD filter — the standard fast memmem):
#
#   1. Broadcast `needle[0]` into one SIMD vector and `needle[len-1]` into
#      another.
#   2. Slide a W-byte window over the haystack.  At position `i`, load a
#      W-byte chunk and compare it against the broadcast `needle[0]`; load a
#      second W-byte chunk at `i + (len-1)` and compare against the broadcast
#      `needle[len-1]`.  AND the two compare-masks → a W-bit candidate
#      bitmask where bit k is set iff BOTH the first AND last needle byte
#      align at haystack offset `i + k`.
#   3. For each candidate bit, do a full byte-compare of the `len`-byte
#      needle at that offset.  The first+last filter is highly selective, so
#      the (potentially scalar) full compare runs rarely.
#   4. Tail: the final `< W` window positions (where the `i + len-1 + W` load
#      would read past the end) are handled by a scalar first-byte-fast-skip
#      loop.  No out-of-bounds SIMD load is ever issued.
#
# Why first+last (not first only): a single-byte filter (first byte only) is
# defeated by repetitive haystacks (e.g. `aaaa...` searching `aaab`) where
# the first byte matches at every position.  ANDing the last-byte compare
# collapses those to (needle_len-1)-separated candidates, so the verify step
# stays rare even on adversarial input.
#
# Encapsulation: PUBLIC API takes borrowed `Span[UInt8, _]` views for both
# haystack and needle — no UnsafePointer crosses the boundary.  The internal
# `unsafe_ptr()` + `load[width=W]` is confined to the kernel below with a
# `# SAFETY:` comment, and never escapes.
#
# Width: `comptime W = simd_width_of[DType.uint8]()` (native: NEON 16 / AVX2
# 32 / AVX-512 BW 64).  Never hardcoded above native.
#
# Validation: `find_needle` (SIMD) is bit-identical to `find_needle_scalar`
# (reference) for every input — enforced by an exhaustive + fuzz test.
# =============================================================================

from std.bit import count_trailing_zeros
from std.sys.info import simd_width_of

from komira_simd.byte_class.movemask import movemask_to_uint_u8x16, movemask_to_uint_u8x32, movemask_to_uint_u8x64


# =============================================================================
# Scalar reference — the correctness oracle and the tail/short-needle path.
# =============================================================================

@always_inline
def find_needle_scalar(haystack: Span[UInt8, _], needle: Span[UInt8, _]) -> Int:
    """Return the byte offset of the first occurrence of `needle` in
    `haystack`, or -1 if not present.

    Scalar reference: a first-byte fast-skip loop with a full byte-compare on
    a first-byte hit.  This is the correctness oracle the SIMD path is
    validated against, and the supported fallback for empty / too-long /
    1-byte-needle inputs.

    Contract:
      - `needle` empty (len 0) → returns `0` (the empty string matches at the
        start, mirroring libc memmem(h, n, 0)).
      - `len(needle) > len(haystack)` → returns -1.
    """
    var nlen = len(needle)
    var hlen = len(haystack)
    if nlen == 0:
        return 0
    if nlen > hlen:
        return -1

    var first = needle[0]
    var last_possible = hlen - nlen
    var i = 0
    while i <= last_possible:
        if haystack[i] != first:
            i += 1
            continue
        var matched = True
        for j in range(1, nlen):
            if haystack[i + j] != needle[j]:
                matched = False
                break
        if matched:
            return i
        i += 1
    return -1


# =============================================================================
# SIMD memmem — first+last byte filter.
# =============================================================================

@always_inline
def _verify_at(
    h: Span[UInt8, _], pos: Int, needle: Span[UInt8, _]
) -> Bool:
    """Full byte-compare of `needle` at `h[pos ..< pos+len(needle)]`.

    Caller guarantees `pos + len(needle) <= len(h)` (the candidate came from
    a window whose `i + needle_len - 1` load was in bounds, and the verify
    range is therefore in bounds too).
    """
    var nlen = len(needle)
    # First + last already known to match for a SIMD candidate, but the
    # scalar tail also routes here, so compare the full span for generality.
    for j in range(nlen):
        if h[pos + j] != needle[j]:
            return False
    return True


def find_needle(haystack: Span[UInt8, _], needle: Span[UInt8, _]) -> Int:
    """Return the byte offset of the first occurrence of `needle` in
    `haystack`, or -1 if not present.

    SIMD "first+last byte" filter (the standard fast memmem).  Bit-identical
    to `find_needle_scalar` for every input (validated by the property test);
    this is the production path.

    Contract (matches `find_needle_scalar`):
      - `needle` empty → 0.
      - `len(needle) > len(haystack)` → -1.

    Encapsulation: `haystack`/`needle` are borrowed Span views.  The internal
    `unsafe_ptr()` + `load[width=W]` below are confined to this function for
    the candidate-filter loads and never escape.
    """
    var nlen = len(needle)
    var hlen = len(haystack)
    if nlen == 0:
        return 0
    if nlen > hlen:
        return -1
    # A 1-byte needle has no distinct "last" byte to filter on; the scalar
    # first-byte-skip IS already the optimal kernel (it degenerates to a
    # find-byte scan).  Route it to the scalar reference.
    if nlen == 1:
        return find_needle_scalar(haystack, needle)

    comptime W = simd_width_of[DType.uint8]()

    var first = needle[0]
    var last = needle[nlen - 1]
    # `last_possible` is the highest start offset where the full needle fits.
    var last_possible = hlen - nlen

    # The SIMD window at start `i` issues a W-wide load at `i` AND at
    # `i + nlen - 1`.  The second load reads bytes `[i+nlen-1 ..< i+nlen-1+W]`,
    # so it stays in bounds iff `i + nlen - 1 + W <= hlen`, i.e.
    # `i <= hlen - nlen - (W - 1)` == `last_possible - (W - 1)`.
    var simd_last_start = last_possible - (W - 1)

    # SAFETY: `hp` reads only via `load[width=W]` at offsets `i` and
    # `i + nlen - 1`, both proven `+ W <= hlen` by `i <= simd_last_start`
    # above; and via the scalar `_verify_at` whose range is bounded by
    # `pos + nlen <= hlen`.  The pointer never escapes this function.
    var hp = haystack.unsafe_ptr()

    var first_vec = SIMD[DType.uint8, W](first)
    var last_vec = SIMD[DType.uint8, W](last)

    var i = 0
    while i <= simd_last_start:
        var block_first = hp.load[width=W](i)
        var block_last = hp.load[width=W](i + nlen - 1)
        # Candidate bitmask: bit k set iff first byte matches at i+k AND last
        # byte matches at (i+nlen-1)+k == start (i+k) + nlen - 1.
        var eq_first = block_first.eq(first_vec)
        var eq_last = block_last.eq(last_vec)
        var cand = eq_first & eq_last

        var bits = _movemask_w[W](cand)
        while bits != 0:
            var k = Int(count_trailing_zeros(bits))
            var pos = i + k
            # pos <= simd_last_start + (W-1) == last_possible, so the full
            # needle fits; verify the interior bytes (first+last pre-matched).
            if _verify_at(haystack, pos, needle):
                return pos
            bits = bits & (bits - UInt64(1))
        i += W

    # Scalar tail: positions `simd_last_start + 1 .. last_possible` (< W of
    # them) where a W-wide load at `i + nlen - 1` would read past the end.
    if i < 0:
        i = 0
    while i <= last_possible:
        if haystack[i] == first:
            if _verify_at(haystack, i, needle):
                return i
        i += 1
    return -1


# =============================================================================
# Width-generic movemask + ctz helpers.
# =============================================================================
#
# The candidate bool-vector is `SIMD[bool, W]`; we pack it to a scalar bitmask
# and ctz-iterate the set bits.  W is comptime so the right movemask width is
# selected at instantiation via a `@parameter if` ladder.

@always_inline
def _movemask_w[W: Int](cand: SIMD[DType.bool, W]) -> UInt64:
    """Pack a W-lane bool candidate mask into a scalar bitmask (bit k = lane
    k).  W ∈ {16, 32, 64} (native uint8 widths)."""
    var bm = cand.select(SIMD[DType.uint8, W](0xFF), SIMD[DType.uint8, W](0x00))

    comptime if W == 16:
        return UInt64(movemask_to_uint_u8x16(bm.slice[16, offset=0]()))
    elif W == 32:
        return UInt64(movemask_to_uint_u8x32(bm.slice[32, offset=0]()))
    else:
        # W == 64 (AVX-512 BW). Any other (non-power-of-2-byte) width is not
        # a native uint8 SIMD width, so this branch only instantiates at 64.
        return movemask_to_uint_u8x64(bm.slice[64, offset=0]())
