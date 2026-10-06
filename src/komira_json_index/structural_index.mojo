# =============================================================================
# structural_index.mojo — JSON Stage 1 structural-token indexer (hot path).
# =============================================================================
#
# Turns a JSON byte stream into a packed
# structural-token index that Stage 2 consumes to drive the
# columnar materializer.
#
# Public surface:
#   - `struct StructuralIndex` — two parallel `List`s (`offsets`, `tags`)
#     identifying byte positions of structural characters.
#   - `fn build_structural_index(bytes: Span[UInt8, _]) raises -> StructuralIndex`
#     — Stage 1 driver. Reads `bytes` in 16-byte SIMD chunks, threads
#     `in_string` + `escape_carry` state across chunks, emits one
#     (offset, tag) pair per structural character.
#
# Algorithm:
#   1. Reserve output `List`s with conservative estimate (~30% of input).
#   2. For each 16-byte chunk:
#        chunk = load 16 bytes
#        (structural_bits, in_string_bits, quote_bits) = scan_chunk(chunk,
#                                                                    in_string,
#                                                                    escape_carry)
#        emit_offsets(structural_bits, quote_bits, in_string_bits,
#                     chunk_start, chunk, offsets, tags)
#   3. Tail handling (< 16 bytes): zero-pad into a SIMD chunk and run the
#      same path with offsets >= input length filtered out.
#   4. If `in_string` is True at EOF, raise (unterminated string).
#
# Throughput target: ≥ 1.5 GB/s single-threaded on a recent Apple-silicon
# core (stretch: ≥ 2.0 GB/s).
#
# Encapsulation discipline:
#   - Public surface accepts `Span[UInt8, _]` (origin-poly view, NOT raw
#     pointer). Caller controls the buffer's lifetime.
#   - Internal SIMD load uses `bytes.unsafe_ptr() + i`.load[width=16](0)
#     pattern — the same shape as `decode.split_lines`.
#     The pointer is extracted INSIDE this module only; never crosses
#     the public-API boundary.
# =============================================================================

from std.bit import count_trailing_zeros

from komira_json_index.input_limits import check_structural_index_input_size
from komira_json_index.simd_primitives import (
    scan_chunk,
    emit_offsets,
    tag_for_byte,
    TAG_QUOTE_OPEN,
    TAG_QUOTE_CLOSE,
)


# =============================================================================
# StructuralIndex — Stage 1 output container
# =============================================================================


@fieldwise_init
struct StructuralIndex(Copyable, Movable):
    """Packed structural-token index produced by Stage 1.

    `offsets[k]` is the byte position in the input where the k-th
    structural character occurs.
    `tags[k]` is the char-class tag (one of TAG_OPEN_BRACE..TAG_QUOTE_CLOSE
    from `simd_primitives.mojo`).

    The two lists are always the same length and indexed in lock-step.

    Stage 2 consumes this via a state-machine walk; the
    fast-path indexer for `json_extract` treats it as a
    flat tape.
    """

    var offsets: List[UInt32]
    var tags: List[UInt8]

    @always_inline
    def size(self) -> Int:
        return len(self.offsets)


# =============================================================================
# JsonlPartitions — per-worker (lo, hi, index) carrier for inferrer→materializer
# =============================================================================
#
# Lives here (not in
# `schema_inference.mojo`) because both the inferrer and the materializer
# need to import it; placing it in `schema_inference.mojo` would
# introduce a `columnar_materializer → schema_inference` import that
# would cycle against the existing
# `schema_inference → columnar_materializer._compute_jsonl_line_ranges`
# import. `structural_index.mojo` is the leaf of the JSON module DAG.


@fieldwise_init
struct JsonlPartitions(Movable):
    """Per-partition (lo, hi, structural-index) trio carried from the
    parallel inferrer to the parallel materializer to eliminate the
    redundant structural-index SIMD scan.

    Fields:
        los:      per-partition lo (inclusive) byte offsets, length=k.
        his:      per-partition hi (exclusive) byte offsets, length=k.
        indices:  per-partition pre-built StructuralIndex, length=k.

    `k` is the worker count. The lists are always parallel (same
    length, indexed by tid). Empty when serial-fallback was taken
    (the caller must detect `len(indices) == 0`).

    Encapsulation: all fields are Movable + Copyable (List[Int] /
    List[StructuralIndex]); no UnsafePointer, no wildcard origins. The
    bounds carried are `\n`-aligned (`_compute_jsonl_line_ranges`
    contract), so the materializer can safely reuse them.

    Memory: ~5 bytes per structural-token × ~N/30 tokens per partition
    = ~10-15% of input file size per partition × k workers (a 2.7 GB
    file over 10 workers → ~500 MB peak). Indices are
    consumed (moved-from) at the end of materialize.
    """

    var los: List[Int]
    var his: List[Int]
    var indices: List[StructuralIndex]


# =============================================================================
# build_structural_index — Stage 1 driver
# =============================================================================


def build_structural_index(bytes: Span[UInt8, _]) raises -> StructuralIndex:
    """Build the Stage 1 structural-token index for a JSON byte stream.

    `bytes` is the contiguous input buffer. The caller is responsible for
    providing a +16 byte tail guard (zero-padded) for safe over-read on
    the final SIMD load; alternatively this driver does the right thing
    even without the guard by copying the tail into a stack-local
    zero-padded buffer.

    Returns a `StructuralIndex` whose `offsets` are byte positions and
    `tags` are char-class IDs (see `simd_primitives.mojo`).

    Raises if the input has an unterminated string (carry-out from the
    final chunk is True). Other syntax errors (mismatched braces,
    missing colons) are NOT detected here — that is Stage 2's job.
    """
    var n = len(bytes)
    # HOSTILE-INPUT CEILING (ASSERT=none hardening). `offsets` is
    # a List[UInt32]; past 2^32 input bytes the offset emits WRAP and
    # the tape stops being strictly monotone. Every downstream range
    # (`bytes[key_start:key_end]`, `push_bytes(bytes[v_start+1:v_end])`, ...)
    # derives its bounds from that monotonicity, so a wrapped offset produces
    # a NEGATIVE-LENGTH Span — a silent memcpy with a wrapped count, which no
    # stdlib bounds check catches even at ASSERT=safe. ONE compare, at the
    # boundary, before a single byte is scanned or allocated.
    check_structural_index_input_size(n)
    # Pre-size both Lists to the upper bound; we'll resize down to exact
    # at the end. This eliminates per-emit List.append bounds-check +
    # realloc overhead — the kernel scan runs at ~2 GB/s standalone, but
    # List.append per emit drops the end-to-end driver to ~0.5 GB/s
    # without pre-sizing.
    #
    # An estimate of `(n // 2) + 32` is NOT an upper bound: for
    # structural-dense JSONL like `{"a":N,"v":2N}\n` the structural density
    # is 9/17 = 52.9% — a 1501-byte input has 783 tokens against an
    # estimate of 782, a one-byte buffer overrun that corrupts scalar
    # offsets at the file tail. Per JSON grammar the true upper bound is `n` (every byte
    # could be structural: e.g. `[[[[...]]]]`), so use `n + 32` for
    # safety. The over-allocation is bounded: a 4 MiB chunk wastes
    # ~4 MiB extra capacity at peak, which is dropped at the resize-to-
    # exact step.
    var est_size = n + 32
    var offsets = List[UInt32](capacity=est_size)
    var tags = List[UInt8](capacity=est_size)
    offsets.resize(unsafe_uninit_length=est_size)
    tags.resize(unsafe_uninit_length=est_size)

    # SAFETY: raw pointers into the pre-sized List storage. We track the
    # cursor `w` manually and resize the Lists down to `w` at the end.
    # The capacity-reservation above guarantees w < est_size always
    # (capped at `n + 32`; the worst case is every byte structural,
    # bounded by `n`). Pointers live INSIDE this module only — never
    # cross the public API.
    var off_ptr = offsets.unsafe_ptr()
    var tag_ptr = tags.unsafe_ptr()
    var w: Int = 0

    var in_string: Bool = False
    var escape_carry: Bool = False

    var i: Int = 0
    var base_ptr = bytes.unsafe_ptr()

    # Hot SIMD loop: 16-byte chunks. Inlined emit avoids
    # the List.append cost (~6.5M list ops on 10MB; 2× slowdown vs raw).
    while i + 16 <= n:
        var chunk = (base_ptr + i).load[width=16](0)
        var result = scan_chunk(chunk, in_string, escape_carry)
        var structural_bits = result[0]
        var in_string_bits = result[1]
        var quote_bits = result[2]

        # Inline emit: walk merged bitset via ctz.
        var merged = (structural_bits | quote_bits) & UInt32(0xFFFF)
        var bits = merged
        while bits != 0:
            var k = Int(count_trailing_zeros(bits))
            off_ptr[w] = UInt32(i) + UInt32(k)
            # Tag derivation: quote vs non-quote dispatch.
            if (quote_bits >> UInt32(k)) & UInt32(0x1) != 0:
                # Quote bit at k; open vs close from in_string state.
                if (in_string_bits >> UInt32(k)) & UInt32(0x1) != 0:
                    tag_ptr[w] = TAG_QUOTE_OPEN
                else:
                    tag_ptr[w] = TAG_QUOTE_CLOSE
            else:
                tag_ptr[w] = tag_for_byte(chunk[k])
            w += 1
            bits &= bits - UInt32(1)

        i += 16

    # Tail handling: < 16 bytes left.
    var remaining = n - i
    if remaining > 0:
        var pad = SIMD[DType.uint8, 16](0)
        var t = 0
        while t < remaining:
            pad[t] = bytes[i + t]
            t += 1
        var result = scan_chunk(pad, in_string, escape_carry)
        var structural_bits = result[0]
        var in_string_bits = result[1]
        var quote_bits = result[2]
        var valid_mask: UInt32
        if remaining >= 16:
            valid_mask = UInt32(0xFFFF)
        else:
            valid_mask = (UInt32(1) << UInt32(remaining)) - UInt32(1)
        var merged = (
            (structural_bits | quote_bits) & valid_mask & UInt32(0xFFFF)
        )
        var bits = merged
        while bits != 0:
            var k = Int(count_trailing_zeros(bits))
            off_ptr[w] = UInt32(i) + UInt32(k)
            if (quote_bits >> UInt32(k)) & UInt32(0x1) != 0:
                if (in_string_bits >> UInt32(k)) & UInt32(0x1) != 0:
                    tag_ptr[w] = TAG_QUOTE_OPEN
                else:
                    tag_ptr[w] = TAG_QUOTE_CLOSE
            else:
                tag_ptr[w] = tag_for_byte(pad[k])
            w += 1
            bits &= bits - UInt32(1)

    # Truncate to the actual emit count.
    offsets.resize(unsafe_uninit_length=w)
    tags.resize(unsafe_uninit_length=w)

    # Unterminated string at EOF?
    if in_string:
        raise Error("JSON parse error: unterminated string at end of input")

    return StructuralIndex(offsets=offsets^, tags=tags^)
