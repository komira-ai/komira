# =============================================================================
# bzip2_buffer.mojo: bzip2 streams, through libbz2's buffer-to-buffer API
# =============================================================================
#
# FFI-BOUNDARY: libbz2, through the process-lifetime handle of
# codec_libraries.mojo. One-shot calls: libbz2 keeps no pointer past a call
# and owns no memory a caller sees.
#
#   int BZ2_bzBuffToBuffCompress(char* dest, unsigned* destLen,
#                                char* source, unsigned sourceLen,
#                                int blockSize100k, int verbosity,
#                                int workFactor);
#   int BZ2_bzBuffToBuffDecompress(char* dest, unsigned* destLen,
#                                  char* source, unsigned sourceLen,
#                                  int small, int verbosity);
#
# Both return BZ_OK (0), BZ_OUTBUFF_FULL (-8) when `dest` is too small, or
# another negative code. Lengths are C `unsigned` (32 bits): a source past
# 4 GiB is refused here before libbz2 is called, and a larger destination is
# offered as 4 GiB - 1 bytes (a smaller capacity than the buffer is always
# safe).
#
# Public entries (no pointer in a signature):
#   * `bzip2_compress_into(dst, src, block_size_100k, work_factor) -> Int`
#   * `bzip2_decompress_into(dst, src) -> Optional[Int]`: None when the
#     stream decodes to more than `len(dst)` (a caller grows and retries)
#   * `BZIP2_DEFAULT_BLOCK_SIZE_100K` (9), `BZIP2_DEFAULT_WORK_FACTOR` (0)
# =============================================================================

from komira_compression.codec_libraries import _bz2_handle


comptime BZIP2_DEFAULT_BLOCK_SIZE_100K: Int32 = 9
comptime BZIP2_DEFAULT_WORK_FACTOR: Int32 = 0

comptime _BZ_OK: Int32 = 0
comptime _BZ_OUTBUFF_FULL: Int32 = -8
comptime _UINT_MAX: Int = 4294967295


@always_inline
def _ptr(
    s: Span[UInt8, _], ref scratch: InlineArray[UInt8, 1]
) -> UnsafePointer[UInt8, MutUntrackedOrigin]:
    """The address libbz2 uses for `s`: the Span's own, or `scratch` when `s`
    is empty (an empty Span may carry a null pointer)."""
    # SAFETY: used only for the synchronous call it is built for; the Span's
    # origin, or the caller's `scratch` local, keeps the bytes alive across
    # it. libbz2 writes only through a destination address, and at most the
    # length passed alongside it.
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


def _check_source(what: StaticString, src_len: Int) raises:
    if src_len > _UINT_MAX:
        raise Error(
            String(what) + ": a source of " + String(src_len)
            + " bytes is past libbz2's 32-bit length"
        )


def bzip2_compress_into[
    dori: MutOrigin
](
    dst: Span[UInt8, dori],
    src: Span[UInt8, _],
    block_size_100k: Int32,
    work_factor: Int32,
) raises -> Int:
    """Compress `src` as one bzip2 stream into `dst`; return the bytes
    written. `len(src) + len(src) / 100 + 600` bytes are always enough
    (libbz2's documented bound).

    Raises `BZ2_bzBuffToBuffCompress failed (rc=R, input_len=N,
    output_cap=C)`.
    """
    var n = len(src)
    var cap = min(len(dst), _UINT_MAX)
    _check_source("bzip2_compress_into", n)
    var src_scratch = InlineArray[UInt8, 1](fill=UInt8(0))
    var dst_scratch = InlineArray[UInt8, 1](fill=UInt8(0))
    var dest_len = UInt32(cap)
    var handle_ptr = _bz2_handle()
    # SAFETY: libbz2 reads `n` bytes at the source address and writes at most
    # `dest_len` (<= `len(dst)`) bytes at the destination address, then stores
    # the count written in `dest_len`, a stack local. All are alive across
    # this synchronous call; libbz2 keeps none of the pointers.
    var rc = handle_ptr[].call["BZ2_bzBuffToBuffCompress", Int32](
        _ptr(dst, dst_scratch),
        UnsafePointer(to=dest_len).unsafe_origin_cast[MutUntrackedOrigin](),
        _ptr(src, src_scratch),
        UInt32(n),
        block_size_100k,
        Int32(0),  # verbosity
        work_factor,
    )
    if rc != _BZ_OK:
        raise Error(
            "BZ2_bzBuffToBuffCompress failed (rc=" + String(Int(rc))
            + ", input_len=" + String(n) + ", output_cap=" + String(cap) + ")"
        )
    return Int(dest_len)


def bzip2_decompress_into[
    dori: MutOrigin
](dst: Span[UInt8, dori], src: Span[UInt8, _]) raises -> Optional[Int]:
    """Decode the bzip2 stream `src` into `dst`; return the bytes written, or
    None when it decodes to more than `len(dst)` (BZ_OUTBUFF_FULL; libbz2
    writes no byte past `len(dst)`).

    Raises `BZ2_bzBuffToBuffDecompress failed (rc=R, input_len=N,
    output_cap=C)` for a corrupt or truncated stream.
    """
    var n = len(src)
    var cap = min(len(dst), _UINT_MAX)
    _check_source("bzip2_decompress_into", n)
    var src_scratch = InlineArray[UInt8, 1](fill=UInt8(0))
    var dst_scratch = InlineArray[UInt8, 1](fill=UInt8(0))
    var dest_len = UInt32(cap)
    var handle_ptr = _bz2_handle()
    # SAFETY: as `bzip2_compress_into`: libbz2 reads `n` bytes, writes at
    # most `dest_len` (<= `len(dst)`) and stores the count in the stack local `dest_len`.
    var rc = handle_ptr[].call["BZ2_bzBuffToBuffDecompress", Int32](
        _ptr(dst, dst_scratch),
        UnsafePointer(to=dest_len).unsafe_origin_cast[MutUntrackedOrigin](),
        _ptr(src, src_scratch),
        UInt32(n),
        Int32(0),  # small = 0: the faster decoder, which uses more memory
        Int32(0),  # verbosity
    )
    if rc == _BZ_OK:
        return Int(dest_len)
    if rc == _BZ_OUTBUFF_FULL:
        return None
    raise Error(
        "BZ2_bzBuffToBuffDecompress failed (rc=" + String(Int(rc))
        + ", input_len=" + String(n) + ", output_cap=" + String(cap) + ")"
    )
