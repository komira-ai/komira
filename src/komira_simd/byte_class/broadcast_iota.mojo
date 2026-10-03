# =============================================================================
# broadcast_iota.mojo — Highway Broadcast / Iota / Set constructors.
# =============================================================================
#
# Highway category: Broadcast / Iota / Set.  Vector constructors that
# produce common patterns: a broadcast scalar, a sequential 0..W-1
# vector, a per-lane-constant pattern.
#
# Highway maps:
#   - `Set(d, scalar)`    → broadcast(scalar) — one value across all
#                           lanes.  Mojo native `SIMD[T, W](value)`.
#   - `Iota(d, start)`    → [start, start+1, ..., start+W-1].
#   - `Broadcast<i>(vec)` → splat lane i across all lanes.  Useful for
#                           per-tile broadcast in byte-class scans.
#
# Encapsulation: ALL outputs are SIMD values; ALL inputs are scalars
# or SIMD values.  No pointers.
# =============================================================================


# =============================================================================
# Set / broadcast — single scalar across W lanes.
# =============================================================================

@always_inline
def broadcast[T: DType, W: Int](value: Scalar[T]) -> SIMD[T, W]:
    """Splat `value` across all W lanes.  Highway `Set(d, value)`.

    Lowers to:
      - NEON: `dup` instruction (1 cycle).
      - AVX2: `vpbroadcastb/w/d/q` (1-2 cycles).
      - AVX-512: same broadcast family.
    """
    return SIMD[T, W](value)


# =============================================================================
# Iota — sequential lane values.
# =============================================================================

@always_inline
def iota_u8[W: Int]() -> SIMD[DType.uint8, W]:
    """Return `[0, 1, 2, ..., W-1]` as a `SIMD[uint8, W]`.  Highway
    `Iota(d, 0)`.

    Comptime-constructed.  Lowers to a constant pool load on every
    target (one cache-line read).  Used by byte_find_any_of for
    per-lane index selection.
    """
    var v = SIMD[DType.uint8, W](0)
    comptime for k in range(W):
        v[k] = UInt8(k)
    return v


@always_inline
def iota_u8_offset[W: Int](start: UInt8) -> SIMD[DType.uint8, W]:
    """Return `[start, start+1, ..., start+W-1]` as `SIMD[uint8, W]`.

    `start + k` wraps mod 256 for UInt8 lanes.  Highway `Iota(d, start)`.
    """
    var v = SIMD[DType.uint8, W](0)
    comptime for k in range(W):
        v[k] = UInt8(k)
    return v + SIMD[DType.uint8, W](start)


@always_inline
def iota_u32[W: Int]() -> SIMD[DType.uint32, W]:
    """Return `[0, 1, 2, ..., W-1]` as `SIMD[uint32, W]`.  Highway
    `Iota(d, 0)` for 32-bit lanes.  Used by gather/scatter index
    construction.
    """
    var v = SIMD[DType.uint32, W](0)
    comptime for k in range(W):
        v[k] = UInt32(k)
    return v


@always_inline
def iota_u32_offset[W: Int](start: UInt32) -> SIMD[DType.uint32, W]:
    """Return `[start, start+1, ..., start+W-1]` as `SIMD[uint32, W]`."""
    var v = SIMD[DType.uint32, W](0)
    comptime for k in range(W):
        v[k] = UInt32(k)
    return v + SIMD[DType.uint32, W](start)


# =============================================================================
# Broadcast<i> — splat lane i across all lanes.
# =============================================================================
#
# Note: Mojo's stdlib does NOT expose a direct "broadcast lane i" op;
# we lower via lane-extract then broadcast.  On NEON this is `dup`
# from a vector element (single instruction); on AVX2 it's
# `vpbroadcastb ymm, xmm` after extracting the lane (~2 cycles).

@always_inline
def broadcast_lane[T: DType, W: Int, i: Int](v: SIMD[T, W]) -> SIMD[T, W]:
    """Splat lane `i` of `v` across all W lanes.  Highway `Broadcast<i>(v)`.

    Compile-time `i` parameter — caller passes the lane index as a
    comptime parameter so the load can be a single `dup` instruction.

    Common use: in a 32-byte chunk, broadcast the lane-0 byte across
    all 32 lanes to compare against a fixed needle.
    """
    comptime assert i >= 0 and i < W, "broadcast_lane index must be in 0..W-1"
    return SIMD[T, W](v[i])


# =============================================================================
# Zero / all-ones constructors.
# =============================================================================

@always_inline
def zero[T: DType, W: Int]() -> SIMD[T, W]:
    """All-zero W-lane vector.  Highway `Zero(d)`."""
    return SIMD[T, W](0)


@always_inline
def ones_u8[W: Int]() -> SIMD[DType.uint8, W]:
    """All-0xFF W-lane byte-mask vector.  Highway equivalent: byte-mask
    `True` shape (often `Not(Zero(d))` in Highway code).
    """
    return SIMD[DType.uint8, W](0xFF)
