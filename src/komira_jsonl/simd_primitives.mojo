# =============================================================================
# simd_primitives.mojo — JSON Stage 1 SIMD helpers (movemask + prefix-XOR +
# escape scan + offset emit + char-class tag dispatch).
# =============================================================================
#
# Hot path. This module hosts the JSON-specific SIMD primitives the
# Stage 1 structural indexer (`structural_index.mojo`) consumes. The
# primitives are PUBLIC within `komira_jsonl/` but NOT in the cross-package
# `komira_core.simd.` surface — they encode JSON-shaped semantics (16-byte
# chunk width, 16-bit movemask, 9-tag char-class table, escape state-machine)
# that would invite mis-use if generalized.
#
# Cross-arch dispatch follows the same `comptime if CompilationTarget.is_x86()`
# shape as `komira_simd.horizontal_add` (the
# `llvm.aarch64.neon.uaddv` direct intrinsic) and `komira_simd.compress`
# (AVX-512 intrinsic dispatch). On osx-arm64 the NEON path is the default; on
# x86_64 it falls through to a scalar/SWAR pattern (correctness-first; an
# AVX-512 / AVX2 arm is possible future work).
#
# Encapsulation discipline (UnsafePointer must never cross a module
# boundary): every public function below accepts SIMD values or owned
# `List[T]` mutable refs; no `UnsafePointer` in any public signature. Internal
# SIMD intrinsic calls live behind the `comptime if` dispatch only.
#
# Primitives shipped:
#   - `movemask_to_uint[W](mask)`   — bool-mask of W lanes → UInt32 bitset.
#   - `prefix_xor_u16(bits, carry_in)` — cumulative XOR of bits, threaded carry.
#   - `scan_escapes_u16(backslash_bits)` — escape-byte mask from backslash mask.
#   - `scan_chunk(chunk, mut carry)` — composite: chunk → (struct_bits, in_string_bits, quote_open_bits).
#   - `emit_offsets(structural_bits, quote_bits, chunk_start, chunk, offsets, tags)` —
#     bitset → packed structural-index entries.
#   - `tag_for_byte(b)` — char-class tag (0x01..0x09).
#
# Tag constants:
#   TAG_OPEN_BRACE   = 0x01  '{'
#   TAG_CLOSE_BRACE  = 0x02  '}'
#   TAG_OPEN_BRACKET = 0x03  '['
#   TAG_CLOSE_BRACKET= 0x04  ']'
#   TAG_COLON        = 0x05  ':'
#   TAG_COMMA        = 0x06  ','
#   TAG_QUOTE_OPEN   = 0x07  '"' (string start, in_string transition False→True)
#   TAG_QUOTE_CLOSE  = 0x08  '"' (string end,   in_string transition True→False)
#   TAG_SCALAR_START = 0x09  number / true / false / null  (NOT emitted by Stage 1;
#                                                            stage 2 derives from
#                                                            gap-after-structurals)
# =============================================================================

from std.bit import count_trailing_zeros
from std.sys.info import CompilationTarget
from std.sys.intrinsics import llvm_intrinsic

from komira_simd.horizontal_add import hadd_u8x16, hadd_widening_u8x16

# The five JSON-private SIMD helpers below delegate to the canonical
# implementations in `komira_core.simd.byte_class` (shared with the CSV
# reader). JSON consumers import from `komira_jsonl.simd_primitives`; the
# local wrappers are thin pass-throughs.
from komira_simd.byte_class.byte_mask_ops import bytemask_or as _byte_class_bytemask_or
from komira_simd.byte_class.movemask import (
    byte_eq_to_bytemask_u8x16 as _byte_class_byte_eq_to_bytemask_u8x16,
    movemask_to_uint_u8x16 as _byte_class_movemask_to_uint_u8x16,
)
from komira_simd.byte_class.prefix_xor import (
    prefix_xor_u16 as _byte_class_prefix_xor_u16,
)


# =============================================================================
# Tag constants
# =============================================================================

comptime TAG_OPEN_BRACE: UInt8 = 0x01
comptime TAG_CLOSE_BRACE: UInt8 = 0x02
comptime TAG_OPEN_BRACKET: UInt8 = 0x03
comptime TAG_CLOSE_BRACKET: UInt8 = 0x04
comptime TAG_COLON: UInt8 = 0x05
comptime TAG_COMMA: UInt8 = 0x06
comptime TAG_QUOTE_OPEN: UInt8 = 0x07
comptime TAG_QUOTE_CLOSE: UInt8 = 0x08
comptime TAG_SCALAR_START: UInt8 = 0x09
comptime TAG_INVALID: UInt8 = 0x00


# =============================================================================
# tag_for_byte — char-class tag lookup
# =============================================================================
#
# Used by `emit_offsets` to tag the structural-character byte with its
# semantic class. For non-quote structurals the tag is fixed; for the quote
# byte (`"`), the caller passes a pre-computed `tag_quote: UInt8` argument
# (TAG_QUOTE_OPEN or TAG_QUOTE_CLOSE depending on the in_string transition).
# We do NOT branch in the hot loop on quote vs structural; that decision is
# pre-computed at the chunk level by `scan_chunk`'s output split.
#
# Implementation: 256-byte LUT indexed by byte value. Single L1d lookup per
# emit (~3 cycles) vs the 7-way if-else cascade (~7 compares + 1 branch).
# The LUT is `comptime`-constructible but Mojo currently lacks a
# clean way to compute a 256-element InlineArray at compile time without
# template explosion — we build it lazily as a stack-local 256-byte SIMD
# pattern. For the hot loop we use the table-lookup form via a stack array.


@always_inline
def tag_for_byte(b: UInt8) -> UInt8:
    """Map a structural byte to its char-class tag.

    Returns TAG_INVALID (0x00) for non-structural bytes (callers should
    not invoke this on non-structurals; the structural mask filter
    upstream guarantees only structurals reach here).

    Implementation: dense byte-comparison cascade. Mojo lowers
    this to a tight branch-prediction-friendly chain on NEON (test+csel
    for short bodies; csinc for sequential matches). For a hot inner
    loop, callers SHOULD prefer the inline `inline_tag_for_byte` shape
    used in `structural_index.mojo` which is `@always_inline` AND emits
    no `_ = ...` dead-code keepalives.
    """
    if b == UInt8(0x7B):  # '{'
        return TAG_OPEN_BRACE
    elif b == UInt8(0x7D):  # '}'
        return TAG_CLOSE_BRACE
    elif b == UInt8(0x5B):  # '['
        return TAG_OPEN_BRACKET
    elif b == UInt8(0x5D):  # ']'
        return TAG_CLOSE_BRACKET
    elif b == UInt8(0x3A):  # ':'
        return TAG_COLON
    elif b == UInt8(0x2C):  # ','
        return TAG_COMMA
    elif b == UInt8(0x22):  # '"'
        # Caller distinguishes open vs close via in_string transition;
        # we conservatively return TAG_QUOTE_OPEN here. The structural
        # emit path overrides this with the precomputed quote tag.
        return TAG_QUOTE_OPEN
    else:
        return TAG_INVALID


# =============================================================================
# movemask_to_uint — bool-mask (W lanes) → UInt32 bitset
# =============================================================================
#
# The "lane bits" SIMD LUT marks each lane with
# its bit-position weight (1, 2, 4, ..., 0x8000 for W=16). The byte-mask
# (0xFF/0x00 per lane) AND'd with the LUT, then horizontally summed via
# `hadd_widening_u8x16`, produces the UInt16 bitset. For W=16 this is the
# canonical NEON `cmeq.16b` + AND + 2× `hadd` shape (~18 SIMD insns).
#
# x86 path: when AVX-512 lands, the dedicated `llvm.x86.sse2.pmovmskb.128`
# intrinsic (or its AVX-512 `vpmovb2m k0, zmm` mask-extraction equivalent)
# replaces the LUT+hadd. For now we route through stdlib `reduce_add` which
# Mojo lowers to vpmovmskb on AVX2 (the SSE2 path is the fallback).


@always_inline
def movemask_to_uint_u8x16(byte_mask: SIMD[DType.uint8, 16]) -> UInt32:
    """Bool-mask (16 lanes, each lane 0xFF or 0x00) → UInt16 bitset
    extended into a UInt32 for downstream OR-merge.

    Bit k of the result is 1 iff `byte_mask[k] == 0xFF`.

    Implemented by `komira_simd.byte_class.movemask.
    movemask_to_uint_u8x16`; this local wrapper is a thin pass-through.

    NEON lowering (about 1.9× faster than a per-lane shift-and-OR
    form): `cmeq.16b` (already done by caller) + `and.16b` + 2× stdlib
    8-lane reduce_add (which lowers to `addv b0, v.8b`).
    """
    return _byte_class_movemask_to_uint_u8x16(byte_mask)


# =============================================================================
# scan_escapes_u16 — backslash-bits → escaped-byte mask
# =============================================================================
#
# Canonical simdjson recipe (§3.2 of the simdjson paper).
# Given a 16-bit `backslash_bits` mask (bit k = 1 iff chunk[k] == '\\'):
#
#   1. Compute `following = backslash_bits << 1` — each backslash flags the
#      following byte as a candidate escape target.
#   2. Mask out runs of consecutive backslashes: a run of N backslashes
#      escapes ceil(N/2) following bytes. The mask is computed via
#      `even_starts = backslash_bits & ~(backslash_bits << 1)` then OR-chain.
#
# For Stage 1 our specific need is "which bytes are ESCAPED" so we can
# AND-NOT them from the quote mask. The full chain:
#
#   escaped_bits = ((backslash_bits & ~prev_backslash_carry) << 1) ^ carry_out
#
# Simplification for Stage 1: an "escaped" byte is one that follows an
# odd-length run of backslashes ending at position k. Per simdjson's
# implementation (`stage1_find_marks.h` line ~150), the trick is:
#
#   - Find run-starts: `starts = b & ~(b << 1)`     (bit set where a run begins)
#   - Find odd-length runs: examine each start and walk until run-end.
#
# For a clean 16-bit shift-based pure-arithmetic formulation we use the
# 64-bit-style "follows odd-length run" recipe, scaled to 16 bits:
#
#   1. start = b & ~(b << 1)         (run-start positions)
#   2. end   = b & ~(b >> 1)         (run-end positions)
#   3. odd_end_runs = run-by-run; tag end positions where popcount(run) is odd.
#   4. follow_odd_run = (odd_end_positions << 1)
#
# This is sequential at the 16-bit level. A clean implementation walks
# the bits via ctz iteration (cheap; we already use this in `emit_offsets`).
# For carry across chunks we thread a `prev_backslash_carry: Bool` field —
# the high bit of the prior chunk's backslash mask.


@always_inline
def scan_escapes_u16(
    backslash_bits: UInt32, mut prev_was_escape_target: Bool
) -> UInt32:
    """Return a 16-bit mask of bytes that are ESCAPED (i.e. follow an
    odd-length run of backslashes).

    `backslash_bits` is the lower 16 bits; bits >= 16 are ignored.

    `prev_was_escape_target` is mutated: True iff the high bit of the
    output mask (bit 16, i.e. carry into next chunk) flags the next
    chunk's first byte as escaped. Threaded across chunks.

    Algorithm: identify each maximal run of consecutive backslashes,
    compute its parity. If parity is odd, the byte FOLLOWING the run-end
    is escaped (consumed by the trailing backslash). Even-parity runs
    produce no escape (every byte in the run is itself escaped by the
    prior backslash, ending in a "balanced" pair).

    Implementation: bit-walk via ctz to find run starts; advance to
    run end; emit escape-mark at run_end + 1 if run length is odd.
    """
    var b: UInt32 = backslash_bits & UInt32(0xFFFF)
    var escaped: UInt32 = 0

    # Handle carry from previous chunk: if the prior chunk ended on an
    # odd run of backslashes whose escape target falls in THIS chunk
    # (i.e. at bit 0), set escaped bit 0 here.
    #
    # ⚠ The carry MUST be CONSUMED here, not merely read. A flag that is
    # only ever set True (at the carry-out branch below) and never cleared
    # lets ONE trailing backslash at a 16-byte chunk boundary latch it for
    # the remainder of the buffer: byte 0 of EVERY later chunk is treated as
    # escaped, a `"` at any offset 16k is dropped from
    # `unescaped_quote_bits`, the prefix-XOR `in_string` state desyncs, and
    # the structural index emits string-INTERIOR bytes as structural tokens
    # for the rest of the input — silently wrong column data from a one-byte
    # input, with no error raised. `scan_chunk` (the only caller) does not
    # reset the flag between chunks.
    # Consuming it here makes the primitive self-consistent: the flag means
    # "carry pending INTO this chunk" on entry and "carry pending OUT of this
    # chunk" on exit.
    if prev_was_escape_target:
        escaped |= UInt32(0x1)
        prev_was_escape_target = False

    var bits = b
    while bits != 0:
        # Find start of next run.
        var start = Int(count_trailing_zeros(bits))
        # Find end of run: starting at `start`, count consecutive 1s.
        var run_len: Int = 0
        var probe = bits >> UInt32(start)
        while probe & UInt32(0x1) != 0:
            run_len += 1
            probe >>= UInt32(1)
        # Odd-length run? Then bit (start + run_len) is escaped.
        if run_len % 2 == 1:
            var esc_pos = start + run_len
            if esc_pos < 16:
                escaped |= UInt32(0x1) << UInt32(esc_pos)
            else:
                # Carry into next chunk.
                prev_was_escape_target = True
        # Mask out this run from `bits` to advance the loop.
        var run_mask = ((UInt32(0x1) << UInt32(run_len)) - 1) << UInt32(start)
        bits &= ~run_mask

    # On exit `prev_was_escape_target` holds the CARRY-OUT: True iff this
    # chunk ended on an odd-length backslash run whose escape target is byte 0
    # of the NEXT chunk. It was cleared on entry (above) if a carry-in was
    # consumed, and is set True only by the `esc_pos >= 16` branch — so the
    # caller neither can nor needs to reset it between chunks.
    return escaped


# =============================================================================
# prefix_xor_u16 — cumulative XOR of bits with carry
# =============================================================================
#
# For an unescaped-quote bitmask, the
# "in_string" state at byte k is `carry_in XOR (sum of unescaped quotes
# from byte 0 to byte k inclusive) mod 2`. The cumulative-XOR pattern
# is the canonical simdjson §3.2 mechanism.
#
# The PMULL64 path (NEON) is single-instruction:
#
#   pmull.1q result, bits, 0xFFFFFFFFFFFFFFFF
#
# multiplied by all-ones gives the prefix-XOR. On 16-bit values this is
# 1 cycle. For the 16-bit-at-a-time JSON kernel we can also use the
# scalar shift-XOR fallback (8 ops on UInt16):
#
#   t = bits ^ (bits << 1)
#   t ^= t << 2
#   t ^= t << 4
#   t ^= t << 8        (no need for << 16 since UInt16 caps at 16 bits)
#
# Adding the carry: if carry_in is True, XOR all bits >= 0 with 1 — i.e.
# flip every bit (`t ^= 0xFFFF`). The new carry_out is the high bit of t.


@always_inline
def prefix_xor_u16(bits: UInt32, mut carry: Bool) -> UInt32:
    """Cumulative-XOR of the lower 16 bits of `bits`, with carry_in
    threaded via `carry`. Sets `carry` to the resulting high-bit value
    (carry_out).

    Result bit k = `carry_in XOR (bits[0] XOR bits[1] XOR ... XOR bits[k])`.

    Implemented by `komira_simd.byte_class.prefix_xor.
    prefix_xor_u16`; this local wrapper is a thin pass-through.
    """
    return _byte_class_prefix_xor_u16(bits, carry)


# =============================================================================
# scan_chunk — composite chunk scanner
# =============================================================================
#
# Produces, for a 16-byte chunk:
#   - `structural_bits`: bytes that are non-quote structurals AND not in
#     string. UInt16 bitset.
#   - `in_string_bits`: cumulative in_string mask for this chunk. UInt16.
#   - `quote_open_bits`: bytes that are unescaped quotes (any quote,
#     open or close). Caller distinguishes via in_string transition.
#
# Caller threads `prev_in_string` (Bool) + `prev_escape_carry` (Bool)
# across chunks.


@always_inline
def _byte_eq_u8x16_to_bytemask(
    chunk: SIMD[DType.uint8, 16], target: UInt8
) -> SIMD[DType.uint8, 16]:
    """chunk[k] == target → 0xFF, else 0x00.

    Implemented by `komira_simd.byte_class.movemask.
    byte_eq_to_bytemask_u8x16`; thin pass-through.
    """
    return _byte_class_byte_eq_to_bytemask_u8x16(chunk, target)


@always_inline
def _bytemask_or(
    a: SIMD[DType.uint8, 16], b: SIMD[DType.uint8, 16]
) -> SIMD[DType.uint8, 16]:
    """OR two byte-masks (each lane 0xFF or 0x00). Equivalent to
    `a | b` since both lanes are 0xFF/0x00 in shape.

    Implemented by `komira_simd.byte_class.byte_mask_ops.
    bytemask_or[16]`; thin pass-through.
    """
    return _byte_class_bytemask_or[16](a, b)


def scan_chunk(
    chunk: SIMD[DType.uint8, 16],
    mut prev_in_string: Bool,
    mut prev_escape_carry: Bool,
) -> Tuple[UInt32, UInt32, UInt32]:
    """Scan one 16-byte chunk; return `(structural_bits, in_string_bits,
    quote_bits)`. Each is a UInt32 with the lower 16 bits valid.

    `structural_bits[k]` = 1 iff `chunk[k]` is one of `{}[]:,` AND chunk[k]
    is NOT inside a string.

    `in_string_bits[k]` = 1 iff `chunk[k]` is INSIDE a string (between an
    unescaped open quote and its matching close quote).

    `quote_bits[k]` = 1 iff `chunk[k] == '"' AND chunk[k]` is not escaped.

    `prev_in_string` is mutated to the in_string state at chunk end
    (carry_out for the next chunk).
    `prev_escape_carry` is mutated to the escape carry for next chunk.
    """
    # 1. Structural byte detection (5 cmeq.16b + 4 OR-reduce on NEON).
    var m_obrace = _byte_eq_u8x16_to_bytemask(chunk, UInt8(0x7B))  # '{'
    var m_cbrace = _byte_eq_u8x16_to_bytemask(chunk, UInt8(0x7D))  # '}'
    var m_obrack = _byte_eq_u8x16_to_bytemask(chunk, UInt8(0x5B))  # '['
    var m_cbrack = _byte_eq_u8x16_to_bytemask(chunk, UInt8(0x5D))  # ']'
    var m_colon = _byte_eq_u8x16_to_bytemask(chunk, UInt8(0x3A))  # ':'
    var m_comma = _byte_eq_u8x16_to_bytemask(chunk, UInt8(0x2C))  # ','
    var m_struct_raw = _bytemask_or(
        _bytemask_or(_bytemask_or(m_obrace, m_cbrace), _bytemask_or(m_obrack, m_cbrack)),
        _bytemask_or(m_colon, m_comma),
    )
    var struct_bits_raw = movemask_to_uint_u8x16(m_struct_raw)

    # 2. Quote + backslash detection.
    var m_quote = _byte_eq_u8x16_to_bytemask(chunk, UInt8(0x22))  # '"'
    var m_backslash = _byte_eq_u8x16_to_bytemask(chunk, UInt8(0x5C))  # '\\'
    var quote_bits_raw = movemask_to_uint_u8x16(m_quote)
    var backslash_bits = movemask_to_uint_u8x16(m_backslash)

    # 3. Escape scan: which bytes are escaped by an odd-length backslash run?
    var escaped_bits = scan_escapes_u16(backslash_bits, prev_escape_carry)

    # 4. Unescaped quotes only — actual string boundaries.
    var unescaped_quote_bits = quote_bits_raw & ~escaped_bits & UInt32(0xFFFF)

    # 5. Prefix-XOR of unescaped_quote_bits gives in_string state.
    var in_string_bits = prefix_xor_u16(unescaped_quote_bits, prev_in_string)
    # prev_in_string mutated to carry_out by prefix_xor_u16.

    # 6. Structural chars are non-quote structurals AND NOT in-string.
    var structural_bits = struct_bits_raw & ~in_string_bits & UInt32(0xFFFF)

    return Tuple[UInt32, UInt32, UInt32](
        structural_bits, in_string_bits, unescaped_quote_bits
    )


# =============================================================================
# emit_offsets — bitset → packed structural-index entries
# =============================================================================
#
# ctz-iterate pattern. For each set bit in the input
# bitset, append `chunk_start + bit_index` to `out_offsets` and the
# corresponding tag to `out_tags`.
#
# Two bitsets are walked here: `structural_bits` (non-quote structurals)
# and `quote_bits` with explicit open/close tag derivation from
# `in_string_bits` transitions. We merge both into a single sorted-by-bit
# walk so that the output is offset-sorted.


@always_inline
def _tag_for_quote(bit_pos: Int, in_string_bits: UInt32) -> UInt8:
    """For a quote bit at position `bit_pos`, determine if it's an
    opening quote (in_string_bits goes False→True at this position) or
    a closing quote (True→False).

    A quote IS the transition itself: in_string_bits[bit_pos] is True
    AFTER the open-quote and BEFORE the close-quote. So:
      - If in_string_bits[bit_pos] == 1: this is an OPEN quote (we just
        entered a string).
      - If in_string_bits[bit_pos] == 0: this is a CLOSE quote (we just
        left a string).
    """
    var in_string_at = (in_string_bits >> UInt32(bit_pos)) & UInt32(0x1)
    if in_string_at == UInt32(1):
        return TAG_QUOTE_OPEN
    else:
        return TAG_QUOTE_CLOSE


def emit_offsets(
    structural_bits: UInt32,
    quote_bits: UInt32,
    in_string_bits: UInt32,
    chunk_start: UInt32,
    chunk: SIMD[DType.uint8, 16],
    mut out_offsets: List[UInt32],
    mut out_tags: List[UInt8],
):
    """Walk `structural_bits | quote_bits` and append one entry per set
    bit to `out_offsets` / `out_tags`. Bits are emitted in ascending
    offset order (ctz-iterate).

    For each bit position `i`:
      - If `i` is set in `quote_bits`: emit quote tag derived from
        in_string_bits[i].
      - Else if `i` is set in `structural_bits`: emit char-class tag
        from chunk[i] via `tag_for_byte`.
    """
    var merged: UInt32 = (structural_bits | quote_bits) & UInt32(0xFFFF)
    var bits = merged
    while bits != 0:
        var i = Int(count_trailing_zeros(bits))
        var off = chunk_start + UInt32(i)
        var tag: UInt8
        if (quote_bits >> UInt32(i)) & UInt32(0x1) != 0:
            tag = _tag_for_quote(i, in_string_bits)
        else:
            tag = tag_for_byte(chunk[i])
        out_offsets.append(off)
        out_tags.append(tag)
        # Clear the lowest set bit.
        bits &= bits - UInt32(1)
