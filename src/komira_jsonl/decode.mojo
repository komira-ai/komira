# =============================================================================
# decode — JSONL reader + SIMD structural-char key-scan
# =============================================================================
#
# Public surface:
#
#   - `fn parse_record[T: JsonCompatible](s: String) raises -> T`
#       — parse one JSON object string into `T`. Delegates to
#       `T.from_json(s)`, which the conformer writes as a reflect-driven
#       name+type cascade with hand-keyed value construction.
#
#   - `fn split_lines(bytes: Span[UInt8, _]) -> List[String]`
#       — split a JSONL byte stream into per-line String records. The
#       NEON path uses `hadd_u8x16` (the `uaddv` intrinsic, in
#       `komira_simd.horizontal_add`) for the byte-mask scan. x86_64
#       uses the stdlib reduction (correct, not separately tuned).
#
# This module holds only the trait-level `parse_record[T]` and the SIMD
# line splitter; the columnar reader lives in `columnar_materializer`.
#
# Encapsulation discipline: no UnsafePointer in
# any public signature. Spans accepted are origin-poly; line strings are
# owned heap-allocated; the SIMD scan uses `unsafe_ptr()` only at the
# `load[width=16]` boundary inside the inner loop (sound — the source
# Span outlives every iteration; no cross-module pointer pass).
# =============================================================================

from std.sys.info import CompilationTarget

from komira_simd.horizontal_add import hadd_u8x16

from komira_jsonl.json_compatible import JsonCompatible


# =============================================================================
# parse_record — trait-level parser
# =============================================================================


def parse_record[T: JsonCompatible](s: String) raises -> T:
    """Parse one JSON-object String into a fresh `T`.

    Delegates to the conformer's `T.from_json(s)` static method. The
    conformer body is the source of truth for per-field parsing.

    Unknown keys in `s` -> ignored by `from_json`. Missing required keys
    -> `from_json` raises. Type mismatches -> raises.
    """
    return T.from_json(s)


# =============================================================================
# SIMD structural-char detection
# =============================================================================
#
# Returns a byte-mask: bytes set to non-zero (0xFF) at positions where the
# input is `\n`. The line-splitter calls this in a hot loop and emits
# one String per newline-bounded slice.
#
# The `llvm.aarch64.neon.uaddv` direct intrinsic for the 16-byte SIMD
# reduce is faster than the generic reduction on the key-scan inner loop.
# The `hadd_u8x16` primitive in `komira_simd.horizontal_add` wraps
# it; we consume it
# directly. NEON arm: `cmeq.16b` + `hadd_u8x16` is the hot kernel; x86_64
# arm: stdlib `reduce_add()` fallback (correct, not yet empirically
# tuned).


@always_inline
def _byte_mask_eq_newline_u8x16(chunk: SIMD[DType.uint8, 16]) -> UInt8:
    """Return a non-zero u8 if ANY of the 16 lanes in `chunk` equals
    `\\n` (0x0A); zero otherwise.

    Lowering on NEON:
      - `chunk.eq(0x0A_x16)` -> `cmeq.16b` -> per-lane 0xFF mask.
      - `.select(ones, zeros)` -> ensures the 0xFF/0x00 shape that
        `hadd_u8x16` expects (`uaddv` on a 0/0xFF
        mask is the 16-byte popcount approximation that the JSON
        kernel needs).
      - `hadd_u8x16` -> `uaddv b0, v.16b` single instruction.
    """
    var ones = SIMD[DType.uint8, 16](0xFF)
    var zeros = SIMD[DType.uint8, 16](0x00)
    var nl = SIMD[DType.uint8, 16](0x0A)
    var hit = chunk.eq(nl).select(ones, zeros)
    return hadd_u8x16(hit)


def _line_text(bytes: Span[UInt8, _], start: Int, end: Int) raises -> String:
    """`bytes[start:end]` as a String, byte for byte; refused when the line
    is not UTF-8 (RFC 8259 section 8.1), which a String must be."""
    try:
        return String(StringSlice(from_utf8=bytes[start:end]))
    except:
        raise Error(
            "split_lines: the line at byte " + String(start) + " is not UTF-8"
        )


def split_lines(bytes: Span[UInt8, _]) raises -> List[String]:
    """Split a JSONL byte stream into per-line String records.

    Newline-delimited: each `\\n` ends a record. Trailing `\\n` on the
    final line is allowed (yyjson / DuckDB convention) — produces N
    records, not N+1. Empty lines are skipped (treat as record
    separator).

    SIMD hot path: 16-byte chunks via `hadd_u8x16` reduce on
    `chunk == 0x0A` mask. If the chunk has ANY newline, scan it
    byte-by-byte to find the exact position; emit one or more lines.
    If the chunk has NO newline (hadd == 0), skip the entire 16-byte
    block (extend the current record's slice).

    NEON: `cmeq.16b` + `uaddv` = 2 instructions per chunk for the fast
    path. x86_64: stdlib fallback via the same primitive interface.

    Returns: owned List of per-line Strings (each line is the JSON
    object without the trailing newline), byte for byte. Raises when a
    line is not UTF-8.
    """
    var out = List[String]()
    var n = len(bytes)
    if n == 0:
        return out^

    var line_start: Int = 0
    var i: Int = 0

    # SIMD-hot path: 16-byte chunks.
    while i + 16 <= n:
        # Load 16 bytes from the span. Origin-poly bytes; the load takes
        # the inner pointer for SIMD lowering. The
        # `(ptr + i).load[width=16](0)` form is the idiom for offset SIMD
        # reads.
        var chunk = (bytes.unsafe_ptr() + i).load[width=16](0)
        var mask = _byte_mask_eq_newline_u8x16(chunk)
        if mask == UInt8(0):
            # No newline in this chunk; skip ahead.
            i += 16
            continue
        # Newline somewhere in this chunk — fall through to scalar to
        # find the exact position(s).
        var stop = i + 16
        while i < stop:
            if bytes[i] == UInt8(0x0A):
                # Emit [line_start, i).
                if i > line_start:
                    out.append(_line_text(bytes, line_start, i))
                line_start = i + 1
            i += 1

    # Scalar tail (< 16 bytes left).
    while i < n:
        if bytes[i] == UInt8(0x0A):
            if i > line_start:
                out.append(_line_text(bytes, line_start, i))
            line_start = i + 1
        i += 1

    # Final record without trailing newline?
    if line_start < n:
        out.append(_line_text(bytes, line_start, n))

    return out^


def parse_jsonl[T: JsonCompatible](bytes: Span[UInt8, _]) raises -> List[T]:
    """Parse a whole-JSONL byte stream into `List[T]`.

    Each line is decoded via `T.from_json`. SIMD line-split via
    `split_lines` (NEON `uaddv` path). Empty lines are skipped.
    """
    var lines = split_lines(bytes)
    var out = List[T]()
    out.reserve(len(lines))
    var nl = len(lines)
    for i in range(nl):
        var s = lines[i]
        if s.byte_length() == 0:
            continue  # cov: unreachable split_lines never returns an empty line
        out.append(T.from_json(s))
    return out^
