# =============================================================================
# lzo1x_decompress.mojo — LZO1X block decompressor (native Mojo, no FFI).
# =============================================================================
#
# # Why this file exists — the GPL, not the format
#
# ORC's `CompressionKind.LZO` is deprecated by the spec but still appears in
# customer files, so READING it is real capability we decline to lose. The
# reference implementation, **liblzo2**, is **GPL-2.0-or-later** (dual-licensed: GPLv2+ for free use, or a paid
# commercial licence). A binary that dlopens it raises a licensing question
# this project does not want to carry.
#
# The LZO1X **wire format** carries no such encumbrance — only that particular
# implementation of it does. So the codec's read half is re-implemented here
# from the published format description, and the codec's write half is GONE
# (see `orc_codec.compress_stream`, which refuses CompressionKind.LZO by
# name): we would never CHOOSE to emit a codec the ORC spec itself marks
# deprecated when zlib / snappy / lz4 / zstd are all better and all supported.
# Apache's own `orc-cpp` agrees — pyarrow 24 answers `Unknown CompressionKind:
# LZO` to a write request while still reading LZO files.
#
# This is NOT a port of liblzo2. It is written from the format description,
# and its structure differs from the reference in the one way that matters:
# the reference is a web of `goto`s across two nested `for(;;)` loops, which
# Mojo has no spelling for, so the same control-flow graph is expressed as the
# explicit five-state machine below.
#
# # SAFE, not fast-and-loose
#
# liblzo2's `lzo1x_decompress` is the **non-safe** decoder: it performs NO
# bounds checks and is documented as usable only on data you trust, while
# every byte an ORC reader sees comes from a file it did not write. A
# "retry with a doubled output buffer on any non-zero status" loop around it
# assumes a clean error return, which is precisely what the non-safe decoder
# does not promise on malformed input — it can scribble past the destination
# and never report anything. This decoder implements the SAFE variant's
# discipline instead: every input read is length-checked, every output write is
# limit-checked, and every back-reference is checked against the start of the
# block (the "lookbehind" check). A corrupt chunk raises; it never reads or
# writes out of bounds.
#
# # The format (LZO1X, as decoded)
#
# A block is a sequence of instructions. Each is a control byte, optionally
# followed by a length extension and/or offset bytes:
#
#   * LITERAL RUN   control < 16 at an instruction boundary. Copies `t + 3`
#                   bytes verbatim from the input. `t == 0` selects the
#                   zero-run length extension (below).
#   * M1  control 0..15 in match position — a 2-byte match, distance 1..1024.
#                   Reachable only right after a 1..3 byte trailing literal run.
#   * M2  control >= 64 — a 3..8 byte match, distance 1..2048.
#   * M3  control 32..63 — a 3..33 byte match (extendable), distance 1..16384.
#   * M4  control 16..31 — a 3..9 byte match (extendable), distance
#                   16384..49151. `distance == 0` is the END-OF-STREAM marker,
#                   canonically the three bytes `11 00 00`.
#   * The FIRST-LITERAL-RUN form: a control byte < 16 read immediately after a
#                   literal run is a 3-byte match whose distance base is
#                   `1 + 2048` rather than `1`. This is the one opcode whose
#                   distance base differs from its bit pattern's usual meaning,
#                   so a decoder that misses it is silently wrong by exactly
#                   2048 bytes. Only `lzo1x_999` emits it; this package's LZO1X
#                   tests carry a golden vector for it.
#   * ZERO-RUN LENGTH EXTENSION: a length field of 0 means "add 255 for every
#                   following zero byte, then add the base plus the first
#                   non-zero byte".
#   * After every match, the low 2 bits of the SECOND-TO-LAST consumed input
#                   byte give a 0..3 byte trailing literal run.
#
# # Encapsulation
#
# There is no `UnsafePointer` in this file at all — not in the signature and
# not in the body. Input is a borrowed `Span[UInt8, _]`; output is appended to
# a caller-owned `List[UInt8]`; every read and write goes through an index. The
# scratch buffer is a plain `List[UInt8]`, so the decoder holds no pointer
# across the reallocation that growing it performs.
# =============================================================================


# The distance base for M2 and for the first-literal-run form (LZO's
# `M2_MAX_OFFSET`). Load-bearing: the first-literal-run form's base is
# `1 + LZO1X_M2_MAX_OFFSET`, M2's is 1.
comptime LZO1X_M2_MAX_OFFSET: Int = 0x0800

# The five nodes of the reference decoder's control-flow graph. See the header:
# the reference reaches these with `goto`, which Mojo has no spelling for.
#   TOP               -> MATCH, or a literal run then FIRST_LITERAL_RUN
#   FIRST_LITERAL_RUN -> MATCH, or the 3-byte far-M2 form then MATCH_DONE
#   MATCH             -> MATCH_DONE, or end-of-stream
#   MATCH_DONE        -> TOP, or MATCH_NEXT
#   MATCH_NEXT        -> MATCH
comptime _LZO_S_TOP: Int = 0
comptime _LZO_S_FIRST_LITERAL_RUN: Int = 1
comptime _LZO_S_MATCH: Int = 2
comptime _LZO_S_MATCH_DONE: Int = 3
comptime _LZO_S_MATCH_NEXT: Int = 4

# An LZO1X block is never shorter than its own end-of-stream marker.
comptime _LZO_MIN_BLOCK_LEN: Int = 3

# Floor for the scratch buffer's first allocation, so a handful of input bytes
# does not pay a `compressionBlockSize` allocation (ORC emits many small
# streams per stripe).
comptime _LZO_MIN_SCRATCH: Int = 1024


@always_inline
def _lzo_need_in(ip: Int, n: Int, n_in: Int) raises:
    """Refuse a read of `n` bytes at `ip` that would run past the block end."""
    if ip + n > n_in:
        raise Error(
            String("Lzo1xError.INPUT_OVERRUN: instruction at offset ")
            + String(ip)
            + " needs "
            + String(n)
            + " more byte(s) but the block ends at "
            + String(n_in)
            + " (truncated or corrupt LZO1X block)"
        )


@always_inline
def _lzo_grow(mut dst: List[UInt8], need: Int, limit: Int) raises:
    """Ensure `dst` can be indexed up to `need - 1`, refusing to pass `limit`.

    The buffer grows geometrically, so a block whose real expansion exceeds the
    writer-advertised hint costs a few reallocations rather than a failure —
    the same outcome as a retry-and-double loop, but with the ceiling enforced
    BEFORE the allocation instead of after it.
    """
    if need > limit:
        raise Error(
            String("Lzo1xError.OUTPUT_OVERRUN: block expands past the ")
            + String(limit)
            + "-byte output limit (a malformed length or an unbounded"
            " back-reference chain)"
        )
    if need > len(dst):
        var grown = len(dst) * 2
        if grown < need:
            grown = need
        if grown > limit:
            grown = limit
        dst.resize(unsafe_uninit_length=grown)


@always_inline
def _lzo_extended_length(
    src: Span[UInt8, _], mut ip: Int, base: Int, limit: Int, n_in: Int
) raises -> Int:
    """Read LZO's zero-run length extension: 255 per following zero byte, then
    `base` plus the first non-zero byte. `limit` bounds the accumulator so a
    long run of zeros cannot spin building a length no output could hold."""
    var acc = 0
    _lzo_need_in(ip, 1, n_in)
    while Int(src[ip]) == 0:
        acc += 255
        ip += 1
        if acc > limit:
            raise Error(
                String("Lzo1xError.BAD_LENGTH: zero-run length extension at")
                + " offset "
                + String(ip)
                + " reached "
                + String(acc)
                + ", past the "
                + String(limit)
                + "-byte output limit"
            )
        _lzo_need_in(ip, 1, n_in)
    acc += base + Int(src[ip])
    ip += 1
    return acc


@always_inline
def _lzo_copy_literals(
    src: Span[UInt8, _],
    ip: Int,
    mut dst: List[UInt8],
    op: Int,
    n: Int,
) raises:
    """Copy `n` verbatim input bytes to `dst[op:]`. Caller has already checked
    both bounds (`_lzo_need_in` / `_lzo_grow`)."""
    for i in range(n):
        dst[op + i] = src[ip + i]


@always_inline
def _lzo_copy_match(mut dst: List[UInt8], m: Int, op: Int, n: Int):
    """Copy `n` bytes from `dst[m:]` to `dst[op:]`, BYTE-SEQUENTIALLY.

    The sequential order is load-bearing, not a missed vectorization: LZO
    back-references may overlap the output cursor (a distance-1 match is the
    run-length encoding of one byte), so byte `i` of the copy must observe the
    write of byte `i - 1`. A bulk `memcpy` — or reading the source bytes into
    temporaries before writing any of them — decodes such a match to garbage.
    """
    for i in range(n):
        var b = dst[m + i]
        dst[op + i] = b


def lzo1x_decompress(
    src: Span[UInt8, _],
    size_hint: Int,
    size_limit: Int,
    mut out: List[UInt8],
) raises:
    """Decompress ONE LZO1X block, appending the result to `out`.

    Args:
        src: The complete compressed block, ending with its end-of-stream
             marker. Untrusted: every read is bounds-checked.
        size_hint: The expected decompressed size (ORC passes the PostScript
             `compressionBlockSize`). Sizes the first scratch allocation only —
             a block that expands past it is decoded correctly, just with a
             reallocation.
        size_limit: The hard ceiling on this block's decompressed size.
             Exceeding it raises rather than allocating.
        out: Receives the decompressed bytes, appended. Existing contents are
             untouched, and back-references cannot reach into them: each ORC
             chunk is an independent LZO1X block.
    """
    var n_in = len(src)
    if n_in < _LZO_MIN_BLOCK_LEN:
        raise Error(
            String("Lzo1xError.TRUNCATED: block is ")
            + String(n_in)
            + " byte(s); the shortest valid LZO1X block is the 3-byte"
            " end-of-stream marker"
        )
    if size_limit < _LZO_MIN_SCRATCH:
        raise Error(
            String("Lzo1xError.BAD_LIMIT: output limit ")
            + String(size_limit)
            + " is below the "
            + String(_LZO_MIN_SCRATCH)
            + "-byte floor"
        )

    # First scratch allocation: the writer's hint, but never more than a
    # generous multiple of the compressed length (ORC stripes hold many small
    # streams, and each would otherwise pay a full compressionBlockSize).
    var scratch = size_hint if size_hint > 0 else size_limit
    var by_input = n_in * 8
    if by_input < scratch:
        scratch = by_input
    if scratch < _LZO_MIN_SCRATCH:
        scratch = _LZO_MIN_SCRATCH
    if scratch > size_limit:
        scratch = size_limit
    var dst = List[UInt8](unsafe_uninit_length=scratch)

    var ip = 0  # read cursor into `src`
    var op = 0  # write cursor into `dst`
    var t = 0  # the current instruction's length/state field
    var state = _LZO_S_TOP

    # Start of block. A first byte above 17 encodes an opening literal run of
    # `first - 17` bytes directly; 1..3 of them means the block opens mid-match
    # (the trailing-literal state), which is why this can enter MATCH_NEXT.
    if Int(src[0]) > 17:
        t = Int(src[0]) - 17
        ip = 1
        if t < 4:
            state = _LZO_S_MATCH_NEXT
        else:
            _lzo_need_in(ip, t, n_in)
            _lzo_grow(dst, op + t, size_limit)
            _lzo_copy_literals(src, ip, dst, op, t)
            op += t
            ip += t
            state = _LZO_S_FIRST_LITERAL_RUN

    while True:
        if state == _LZO_S_TOP:
            _lzo_need_in(ip, 1, n_in)
            t = Int(src[ip])
            ip += 1
            if t >= 16:
                state = _LZO_S_MATCH
                continue
            if t == 0:
                t = _lzo_extended_length(src, ip, 15, size_limit, n_in)
            var run = t + 3
            _lzo_need_in(ip, run, n_in)
            _lzo_grow(dst, op + run, size_limit)
            _lzo_copy_literals(src, ip, dst, op, run)
            op += run
            ip += run
            state = _LZO_S_FIRST_LITERAL_RUN

        elif state == _LZO_S_FIRST_LITERAL_RUN:
            _lzo_need_in(ip, 1, n_in)
            t = Int(src[ip])
            ip += 1
            if t >= 16:
                state = _LZO_S_MATCH
                continue
            # The far-M2 form: 3 bytes, distance base 1 + M2_MAX_OFFSET.
            _lzo_need_in(ip, 1, n_in)
            var m = (
                op
                - (1 + LZO1X_M2_MAX_OFFSET)
                - (t >> 2)
                - (Int(src[ip]) << 2)
            )
            ip += 1
            if m < 0:
                raise Error(
                    String("Lzo1xError.LOOKBEHIND_OVERRUN: first-literal-run")
                    + " match at output offset "
                    + String(op)
                    + " points "
                    + String(-m)
                    + " byte(s) before the start of the block"
                )
            _lzo_grow(dst, op + 3, size_limit)
            _lzo_copy_match(dst, m, op, 3)
            op += 3
            state = _LZO_S_MATCH_DONE

        elif state == _LZO_S_MATCH:
            # Declared without an initializer on purpose: all four arms below
            # assign it, and a placeholder would be a dead store.
            var m: Int
            if t >= 64:
                # M2: length 3..8, distance 1..2048.
                _lzo_need_in(ip, 1, n_in)
                m = op - 1 - ((t >> 2) & 7) - (Int(src[ip]) << 3)
                ip += 1
                t = (t >> 5) - 1
            elif t >= 32:
                # M3: length 3..33 (extendable), distance 1..16384.
                t = t & 31
                if t == 0:
                    t = _lzo_extended_length(src, ip, 31, size_limit, n_in)
                _lzo_need_in(ip, 2, n_in)
                m = op - 1 - ((Int(src[ip]) >> 2) + (Int(src[ip + 1]) << 6))
                ip += 2
            elif t >= 16:
                # M4: length 3..9 (extendable), distance 16384..49151. Bit 3 of
                # the control byte is the distance's high bit, and it is read
                # BEFORE the length extension, which is why this arm computes
                # `m` in two steps around the extension read.
                m = op - ((t & 8) << 11)
                t = t & 7
                if t == 0:
                    t = _lzo_extended_length(src, ip, 7, size_limit, n_in)
                _lzo_need_in(ip, 2, n_in)
                m -= (Int(src[ip]) >> 2) + (Int(src[ip + 1]) << 6)
                ip += 2
                if m == op:
                    # Distance 0 in an M4 is the end-of-stream marker, NOT a
                    # match. Canonically the three bytes `11 00 00`.
                    break
                m -= 0x4000
            else:
                # M1: exactly 2 bytes, distance 1..1024. Only reachable via a
                # trailing literal run, and only `lzo1x_999` emits it.
                _lzo_need_in(ip, 1, n_in)
                m = op - 1 - (t >> 2) - (Int(src[ip]) << 2)
                ip += 1
                if m < 0:
                    raise Error(
                        String("Lzo1xError.LOOKBEHIND_OVERRUN: M1 match at")
                        + " output offset "
                        + String(op)
                        + " points "
                        + String(-m)
                        + " byte(s) before the start of the block"
                    )
                _lzo_grow(dst, op + 2, size_limit)
                _lzo_copy_match(dst, m, op, 2)
                op += 2
                state = _LZO_S_MATCH_DONE
                continue
            # Shared tail of M2 / M3 / M4: copy `t + 2` bytes from `m`.
            if m < 0:
                raise Error(
                    String("Lzo1xError.LOOKBEHIND_OVERRUN: match at output")
                    + " offset "
                    + String(op)
                    + " points "
                    + String(-m)
                    + " byte(s) before the start of the block"
                )
            var run = t + 2
            _lzo_grow(dst, op + run, size_limit)
            _lzo_copy_match(dst, m, op, run)
            op += run
            state = _LZO_S_MATCH_DONE

        elif state == _LZO_S_MATCH_DONE:
            # The trailing-literal count lives in the low 2 bits of the
            # SECOND-TO-LAST consumed byte — the control byte for the one-offset
            # -byte forms, the first offset byte for the two-offset-byte ones.
            if ip < 2:
                raise Error(
                    String("Lzo1xError.CORRUPT: match completed after only ")
                    + String(ip)
                    + " input byte(s)"
                )
            t = Int(src[ip - 2]) & 3
            if t == 0:
                state = _LZO_S_TOP
            else:
                state = _LZO_S_MATCH_NEXT

        else:  # _LZO_S_MATCH_NEXT — a 1..3 byte literal run, then a match.
            _lzo_need_in(ip, t, n_in)
            _lzo_grow(dst, op + t, size_limit)
            _lzo_copy_literals(src, ip, dst, op, t)
            op += t
            ip += t
            _lzo_need_in(ip, 1, n_in)
            t = Int(src[ip])
            ip += 1
            state = _LZO_S_MATCH

    # The end-of-stream marker must be the last thing in the block. Trailing
    # bytes mean we mis-parsed (or the producer framed the chunk wrong); either
    # way the output cannot be trusted, so this is an error and not a warning.
    if ip != n_in:
        raise Error(
            String("Lzo1xError.INPUT_NOT_CONSUMED: ")
            + String(n_in - ip)
            + " byte(s) follow the end-of-stream marker at offset "
            + String(ip)
        )
    out.extend(Span(dst)[0:op])
