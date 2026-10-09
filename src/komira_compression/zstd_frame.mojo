# =============================================================================
# zstd_frame.mojo: zstd frames, through libzstd's one-shot API
# =============================================================================
#
# FFI-BOUNDARY: libzstd, through the process-lifetime handle of
# codec_libraries.mojo. Stateless one-shot calls: libzstd keeps no pointer
# past a call and owns no memory a caller sees.
#
#   size_t ZSTD_compress(void* dst, size_t dstCapacity,
#                        const void* src, size_t srcSize, int level);
#   size_t ZSTD_decompress(void* dst, size_t dstCapacity,
#                          const void* src, size_t srcSize);
#   size_t ZSTD_compressBound(size_t srcSize);
#   unsigned long long ZSTD_getFrameContentSize(const void* src,
#                                               size_t srcSize);
#   unsigned ZSTD_isError(size_t code);
#
# Public entries (Span in, caller-owned Span out, bytes written back; no
# pointer in a signature):
#   * `zstd_compress_bound(src_len) -> Int`
#   * `zstd_compress_into(dst, src, level) -> Int`
#   * `zstd_decompress_into(dst, src) -> Int`
#   * `zstd_frame_content_size(src) -> UInt64`, with the two sentinels
#     `ZSTD_CONTENTSIZE_UNKNOWN` and `ZSTD_CONTENTSIZE_ERROR`
#   * `ZSTD_DEFAULT_LEVEL` (3, libzstd's own default)
#
# These pass libzstd's answers through: `zstd_decompress_into` of an empty
# `src` returns 0 (libzstd decodes zero frames to zero bytes), and the frame
# content size is the frame header's claim, unchecked. A caller with a policy
# (refuse empty input, bound a declared size) applies it around the call.
# =============================================================================

from komira_compression.codec_libraries import _zstd_handle


comptime ZSTD_DEFAULT_LEVEL: Int32 = 3
# ZSTD_getFrameContentSize's sentinels: (unsigned long long)-1 and -2.
comptime ZSTD_CONTENTSIZE_UNKNOWN: UInt64 = 0xFFFFFFFFFFFFFFFF
comptime ZSTD_CONTENTSIZE_ERROR: UInt64 = 0xFFFFFFFFFFFFFFFE


@always_inline
def _src_ptr(
    s: Span[UInt8, _], ref scratch: InlineArray[UInt8, 1]
) -> UnsafePointer[UInt8, MutUntrackedOrigin]:
    """The address libzstd reads `s` from: the Span's own, or `scratch` when
    `s` is empty (an empty Span may carry a null pointer)."""
    # SAFETY: used only for the synchronous call it is built for; the Span's
    # origin, or the caller's `scratch` local, keeps the bytes alive across
    # it. libzstd only reads through it.
    if len(s) == 0:
        return (
            scratch.unsafe_ptr()
            .unsafe_mut_cast[True]()
            .unsafe_origin_cast[MutUntrackedOrigin]()
        )
    return (
        s.unsafe_ptr()
        .unsafe_mut_cast[True]()
        .unsafe_origin_cast[MutUntrackedOrigin]()
    )


@always_inline
def _dst_ptr[
    dori: MutOrigin
](
    s: Span[UInt8, dori], ref scratch: InlineArray[UInt8, 1]
) -> UnsafePointer[UInt8, MutUntrackedOrigin]:
    """The address libzstd writes `s` at: the Span's own, or `scratch` when
    `s` is empty (libzstd is then told it has 0 bytes, so it writes none)."""
    # SAFETY: as `_src_ptr`; libzstd writes at most the capacity passed
    # alongside, which is `len(s)`.
    if len(s) == 0:
        return (
            scratch.unsafe_ptr()
            .unsafe_mut_cast[True]()
            .unsafe_origin_cast[MutUntrackedOrigin]()
        )
    return s.unsafe_ptr().unsafe_origin_cast[MutUntrackedOrigin]()


def zstd_compress_bound(src_len: Int) raises -> Int:
    """The largest frame `zstd_compress_into` makes from `src_len` bytes
    (libzstd's `ZSTD_compressBound`)."""
    if src_len < 0:
        raise Error("zstd_compress_bound: negative src_len " + String(src_len))
    var handle_ptr = _zstd_handle()
    # SAFETY: a pure function of its integer argument; no pointer crosses.
    return handle_ptr[].call["ZSTD_compressBound", Int](src_len)


def zstd_compress_into[
    dori: MutOrigin
](dst: Span[UInt8, dori], src: Span[UInt8, _], level: Int32) raises -> Int:
    """Compress `src` as one zstd frame at `level` into `dst`; return the
    bytes written. libzstd refuses a `dst` too small for the frame it makes;
    `zstd_compress_bound(len(src))` bytes are always enough.

    Raises `ZSTD_compress failed (result=R, input_len=N, output_cap=C)`.
    """
    var src_size = len(src)
    var dst_capacity = len(dst)
    var src_scratch = InlineArray[UInt8, 1](fill=UInt8(0))
    var dst_scratch = InlineArray[UInt8, 1](fill=UInt8(0))
    var handle_ptr = _zstd_handle()
    # SAFETY: libzstd reads `src_size` bytes at the source address and writes
    # at most `dst_capacity` (= `len(dst)`) bytes at the destination address;
    # both buffers are alive across this synchronous call and libzstd keeps
    # neither pointer.
    var result = handle_ptr[].call["ZSTD_compress", Int](
        _dst_ptr(dst, dst_scratch),
        dst_capacity,
        _src_ptr(src, src_scratch),
        src_size,
        level,
    )
    # `unsigned ZSTD_isError(size_t)`: declared UInt32, so the unspecified
    # upper half of the 64-bit return register is not read.
    if handle_ptr[].call["ZSTD_isError", UInt32](result) != 0:
        raise Error(
            "ZSTD_compress failed (result=" + String(result)
            + ", input_len=" + String(src_size)
            + ", output_cap=" + String(dst_capacity) + ")"
        )
    if result > dst_capacity:
        raise Error(
            "ZSTD_compress reported " + String(result)
            + " bytes written into a " + String(dst_capacity) + "-byte buffer"
        )
    return result


def zstd_decompress_into[
    dori: MutOrigin
](dst: Span[UInt8, dori], src: Span[UInt8, _]) raises -> Int:
    """Decode the zstd frames in `src` (one or more, back to back) into
    `dst`; return the bytes written. `len(dst)` is the capacity: libzstd
    writes no byte past it and refuses frames that decode to more, as it
    refuses a corrupt or truncated frame. An empty `src` decodes to 0 bytes.

    Raises `ZSTD_decompress failed (result=R, input_len=N, output_cap=C)`.
    """
    var src_size = len(src)
    var dst_capacity = len(dst)
    var src_scratch = InlineArray[UInt8, 1](fill=UInt8(0))
    var dst_scratch = InlineArray[UInt8, 1](fill=UInt8(0))
    var handle_ptr = _zstd_handle()
    # SAFETY: libzstd reads `src_size` bytes at the source address and writes
    # at most `dst_capacity` (= `len(dst)`) bytes at the destination address;
    # both buffers are alive across this synchronous call and libzstd keeps
    # neither pointer.
    var result = handle_ptr[].call["ZSTD_decompress", Int](
        _dst_ptr(dst, dst_scratch),
        dst_capacity,
        _src_ptr(src, src_scratch),
        src_size,
    )
    if handle_ptr[].call["ZSTD_isError", UInt32](result) != 0:
        raise Error(
            "ZSTD_decompress failed (result=" + String(result)
            + ", input_len=" + String(src_size)
            + ", output_cap=" + String(dst_capacity) + ")"
        )
    if result > dst_capacity:
        raise Error(
            "ZSTD_decompress reported " + String(result)
            + " bytes written into a " + String(dst_capacity) + "-byte buffer"
        )
    return result


def zstd_frame_content_size(src: Span[UInt8, _]) raises -> UInt64:
    """The decoded size the first zstd frame header in `src` declares, or
    `ZSTD_CONTENTSIZE_UNKNOWN` (the header omits it) or
    `ZSTD_CONTENTSIZE_ERROR` (no valid header). The claim is the stream's,
    unchecked: a caller that allocates it bounds it first."""
    var src_scratch = InlineArray[UInt8, 1](fill=UInt8(0))
    var handle_ptr = _zstd_handle()
    # SAFETY: libzstd reads at most `len(src)` bytes at the source address,
    # alive across this synchronous call, and keeps no pointer.
    return handle_ptr[].call["ZSTD_getFrameContentSize", UInt64](
        _src_ptr(src, src_scratch), len(src)
    )
