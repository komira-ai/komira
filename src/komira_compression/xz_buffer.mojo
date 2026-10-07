# =============================================================================
# xz_buffer.mojo: .xz streams, through liblzma's single-call buffer API
# =============================================================================
#
# FFI-BOUNDARY: liblzma, through the process-lifetime handle of
# codec_libraries.mojo. Single-call encode and decode with the NULL allocator
# (liblzma's malloc and free): liblzma keeps no pointer past a call and owns
# no memory a caller sees.
#
#   lzma_ret lzma_easy_buffer_encode(uint32_t preset, lzma_check check,
#                                    const lzma_allocator* allocator,
#                                    const uint8_t* in, size_t in_size,
#                                    uint8_t* out, size_t* out_pos,
#                                    size_t out_size);
#   lzma_ret lzma_stream_buffer_decode(uint64_t* memlimit, uint32_t flags,
#                                      const lzma_allocator* allocator,
#                                      const uint8_t* in, size_t* in_pos,
#                                      size_t in_size, uint8_t* out,
#                                      size_t* out_pos, size_t out_size);
#
# Both return LZMA_OK (0), LZMA_BUF_ERROR (10) when the output space ran out
# (or, decoding, the input ended first: liblzma does not tell the two apart),
# or another code.
#
# Public entries (no pointer in a signature):
#   * `xz_compress_into(dst, src, preset, check) -> Int`
#   * `xz_decompress_into(dst, src, memlimit) -> Optional[Int]`: None on
#     LZMA_BUF_ERROR (a caller grows and retries)
#   * `XZ_PRESET_DEFAULT` (6), `XZ_CHECK_CRC64` (4), `XZ_DEFAULT_MEMLIMIT`
#     (16 GiB)
# =============================================================================

from komira_compression.codec_libraries import _lzma_handle


comptime XZ_PRESET_DEFAULT: UInt32 = 6
comptime XZ_CHECK_CRC64: Int32 = 4
comptime XZ_DEFAULT_MEMLIMIT: UInt64 = 1 << 34

comptime _LZMA_OK: Int32 = 0
comptime _LZMA_BUF_ERROR: Int32 = 10


@always_inline
def _ptr(
    s: Span[UInt8, _], ref scratch: InlineArray[UInt8, 1]
) -> UnsafePointer[UInt8, MutUntrackedOrigin]:
    """The address liblzma uses for `s`: the Span's own, or `scratch` when
    `s` is empty (an empty Span may carry a null pointer)."""
    # SAFETY: used only for the synchronous call it is built for; the Span's
    # origin, or the caller's `scratch` local, keeps the bytes alive across
    # it. liblzma writes only through an output address, and at most the
    # size passed alongside it.
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
def _null_allocator() -> UnsafePointer[UInt8, MutUntrackedOrigin]:
    """NULL, liblzma's "use malloc and free" allocator argument.

    # SAFETY: `Optional[UnsafePointer[...]]` is layout-compatible with the
    # bare pointer and `None` is the all-zero bit pattern, so the bitcast is
    # NULL without an address made from an integer. liblzma never
    # dereferences it.
    """
    var none: Optional[UnsafePointer[UInt8, MutUntrackedOrigin]] = None
    return UnsafePointer(to=none).bitcast[
        UnsafePointer[UInt8, MutUntrackedOrigin]
    ]()[]


def xz_compress_into[
    dori: MutOrigin
](
    dst: Span[UInt8, dori], src: Span[UInt8, _], preset: UInt32, check: Int32
) raises -> Int:
    """Compress `src` as one .xz stream into `dst` with liblzma's `preset`
    and integrity `check`; return the bytes written.

    Raises `lzma_easy_buffer_encode failed (rc=R, input_len=N,
    output_cap=C)`; LZMA_BUF_ERROR (10) means `dst` was too small.
    """
    var n = len(src)
    var cap = len(dst)
    var src_scratch = InlineArray[UInt8, 1](fill=UInt8(0))
    var dst_scratch = InlineArray[UInt8, 1](fill=UInt8(0))
    var out_pos = UInt64(0)
    var handle_ptr = _lzma_handle()
    # SAFETY: liblzma reads `n` bytes at the source address and writes at
    # most `cap` (= `len(dst)`) bytes at the destination address, advancing
    # `out_pos`, a stack local. All are alive across this synchronous call;
    # liblzma keeps none of the pointers.
    var rc = handle_ptr[].call["lzma_easy_buffer_encode", Int32](
        preset,
        check,
        _null_allocator(),
        _ptr(src, src_scratch),
        UInt64(n),
        _ptr(dst, dst_scratch),
        UnsafePointer(to=out_pos).unsafe_origin_cast[MutUntrackedOrigin](),
        UInt64(cap),
    )
    if rc != _LZMA_OK:
        raise Error(
            "lzma_easy_buffer_encode failed (rc=" + String(Int(rc))
            + ", input_len=" + String(n) + ", output_cap=" + String(cap) + ")"
        )
    return Int(out_pos)


def xz_decompress_into[
    dori: MutOrigin
](
    dst: Span[UInt8, dori], src: Span[UInt8, _], memlimit: UInt64
) raises -> Optional[Int]:
    """Decode the .xz stream `src` into `dst`, with at most `memlimit` bytes
    of decoder memory; return the bytes written, or None on LZMA_BUF_ERROR
    (the stream decodes to more than `len(dst)`, or `src` ends before the
    stream does). liblzma writes no byte past `len(dst)`.

    Raises `lzma_stream_buffer_decode failed (rc=R, input_len=N,
    output_cap=C)` for any other failure (a corrupt stream, a memory limit
    too low).
    """
    var n = len(src)
    var cap = len(dst)
    var src_scratch = InlineArray[UInt8, 1](fill=UInt8(0))
    var dst_scratch = InlineArray[UInt8, 1](fill=UInt8(0))
    var limit = memlimit
    var in_pos = UInt64(0)
    var out_pos = UInt64(0)
    var handle_ptr = _lzma_handle()
    # SAFETY: liblzma reads at most `n` bytes at the source address and
    # writes at most `cap` (= `len(dst)`) bytes at the destination address,
    # updating `limit`, `in_pos` and `out_pos`, stack locals. All are alive
    # across this synchronous call; liblzma keeps none of the pointers.
    var rc = handle_ptr[].call["lzma_stream_buffer_decode", Int32](
        UnsafePointer(to=limit).unsafe_origin_cast[MutUntrackedOrigin](),
        UInt32(0),  # flags
        _null_allocator(),
        _ptr(src, src_scratch),
        UnsafePointer(to=in_pos).unsafe_origin_cast[MutUntrackedOrigin](),
        UInt64(n),
        _ptr(dst, dst_scratch),
        UnsafePointer(to=out_pos).unsafe_origin_cast[MutUntrackedOrigin](),
        UInt64(cap),
    )
    # Read back after the call so the three slots stay live across it: a
    # local whose last use is taking its address may have its storage reused
    # before liblzma reads it.
    _ = limit
    _ = in_pos
    if rc == _LZMA_OK:
        return Int(out_pos)
    if rc == _LZMA_BUF_ERROR:
        return None
    raise Error(
        "lzma_stream_buffer_decode failed (rc=" + String(Int(rc))
        + ", input_len=" + String(n) + ", output_cap=" + String(cap) + ")"
    )
