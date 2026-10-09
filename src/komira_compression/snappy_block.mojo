# =============================================================================
# snappy_block.mojo: the raw snappy block, through the snappy C API
# =============================================================================
#
# FFI-BOUNDARY: the snappy C API (snappy-c.h), statically linked from
# //third_party/snappy and declared here with `external_call`; inside
# komira_compression this is the one module that declares those symbols
# (komira_avro, komira_orc and komira_parquet_codec still declare their own
# until they move onto this module). snappy keeps no pointer past a call and
# owns no memory a caller sees.
#
#   snappy_status snappy_compress(const char* input, size_t input_length,
#                                 char* compressed, size_t* compressed_length);
#   snappy_status snappy_uncompress(const char* compressed,
#                                   size_t compressed_length,
#                                   char* uncompressed,
#                                   size_t* uncompressed_length);
#   snappy_status snappy_uncompressed_length(const char* compressed,
#                                            size_t compressed_length,
#                                            size_t* result);
#
# `snappy_status` is 0 (SNAPPY_OK), 1 (SNAPPY_INVALID_INPUT) or 2
# (SNAPPY_BUFFER_TOO_SMALL).
#
# Public entries (Span in, caller-owned Span out, bytes written back; no
# pointer in a signature):
#   * `snappy_max_compressed_length(input_len) -> Int`
#   * `snappy_compress_into(dst, src) -> Int`
#   * `snappy_uncompress_into(dst, src) -> Int`
#   * `snappy_uncompressed_length(src) -> Int`
#
# `snappy_uncompress_into` hands snappy `len(dst)` as the capacity, so it
# never writes past the end of `dst`, however small, and refuses a block that
# declares more (status 2). A caller that sizes `dst` at exactly the decoded
# length gets every byte and nothing past it.
# =============================================================================

from std.ffi import external_call


comptime _SNAPPY_OK: Int32 = 0


@always_inline
def _src_ptr(
    s: Span[UInt8, _], ref scratch: InlineArray[UInt8, 1]
) -> UnsafePointer[UInt8, MutUntrackedOrigin]:
    """The address snappy reads `s` from: the Span's own, or `scratch` when
    `s` is empty (an empty Span may carry a null pointer)."""
    # SAFETY: the pointer is used only for the synchronous call it is built
    # for; the Span's origin, or the caller's `scratch` local, keeps the bytes
    # alive across it. snappy only reads through it.
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
    """The address snappy writes `s` at: the Span's own, or `scratch` when `s`
    is empty (snappy is then told it has 0 bytes, so it writes none)."""
    # SAFETY: as `_src_ptr`; snappy writes at most the capacity the caller
    # passes alongside, which is `len(s)`.
    if len(s) == 0:
        return (
            scratch.unsafe_ptr()
            .unsafe_mut_cast[True]()
            .unsafe_origin_cast[MutUntrackedOrigin]()
        )
    return s.unsafe_ptr().unsafe_origin_cast[MutUntrackedOrigin]()


def snappy_max_compressed_length(input_len: Int) -> Int:
    """The largest block `snappy_compress_into` makes from `input_len` bytes:
    32 + input_len + input_len / 6 (snappy's `MaxCompressedLength`)."""
    return 32 + input_len + input_len // 6


def snappy_compress_into[
    dori: MutOrigin
](dst: Span[UInt8, dori], src: Span[UInt8, _]) raises -> Int:
    """Compress `src` as one raw snappy block into `dst`; return the bytes
    written. `dst` must hold `snappy_max_compressed_length(len(src))` bytes:
    snappy refuses a smaller one (status 2). An empty `src` is the one-byte
    block 0x00.

    Raises `snappy_compress failed (status=S, input_len=N, output_cap=C)`.
    """
    var input_len = len(src)
    var output_cap = len(dst)
    var src_scratch = InlineArray[UInt8, 1](fill=UInt8(0))
    var dst_scratch = InlineArray[UInt8, 1](fill=UInt8(0))
    var size = UInt64(output_cap)
    # SAFETY: snappy reads `input_len` bytes at the source address and writes
    # at most `size` (= `len(dst)`) bytes at the destination address, then
    # stores the count written in `size`, a stack local. Every buffer is alive
    # across this synchronous call; snappy keeps none of the pointers.
    var status = external_call[
        "komira_snappy_compress",
        Int32,
        UnsafePointer[UInt8, MutUntrackedOrigin],
        UInt64,
        UnsafePointer[UInt8, MutUntrackedOrigin],
        UnsafePointer[UInt64, MutUntrackedOrigin],
    ](
        _src_ptr(src, src_scratch),
        UInt64(input_len),
        _dst_ptr(dst, dst_scratch),
        UnsafePointer(to=size).unsafe_origin_cast[MutUntrackedOrigin](),
    )
    if status != _SNAPPY_OK:
        raise Error(
            "snappy_compress failed (status=" + String(Int(status))
            + ", input_len=" + String(input_len)
            + ", output_cap=" + String(output_cap) + ")"
        )
    var written = Int(size)
    if written > output_cap:
        raise Error(
            "snappy_compress reported " + String(written)
            + " bytes written into a " + String(output_cap) + "-byte buffer"
        )
    return written


def snappy_uncompress_into[
    dori: MutOrigin
](dst: Span[UInt8, dori], src: Span[UInt8, _]) raises -> Int:
    """Decode the raw snappy block `src` into `dst`; return the bytes written.
    `len(dst)` is the capacity: snappy writes no byte past it. A block that
    declares more than `len(dst)` bytes is refused (status 2), a malformed
    one with status 1.

    Raises `snappy_uncompress failed (status=S, input_len=N, output_cap=C)`.
    An empty `src` is malformed (status 1): every block starts with its
    length.
    """
    var input_len = len(src)
    var output_cap = len(dst)
    var src_scratch = InlineArray[UInt8, 1](fill=UInt8(0))
    var dst_scratch = InlineArray[UInt8, 1](fill=UInt8(0))
    var size = UInt64(output_cap)
    # SAFETY: snappy reads `input_len` bytes at the source address and writes
    # at most `size` (= `len(dst)`) bytes at the destination address, then
    # stores the decoded length in `size`, a stack local. Every buffer is
    # alive across this synchronous call; snappy keeps none of the pointers.
    var status = external_call[
        "komira_snappy_uncompress",
        Int32,
        UnsafePointer[UInt8, MutUntrackedOrigin],
        UInt64,
        UnsafePointer[UInt8, MutUntrackedOrigin],
        UnsafePointer[UInt64, MutUntrackedOrigin],
    ](
        _src_ptr(src, src_scratch),
        UInt64(input_len),
        _dst_ptr(dst, dst_scratch),
        UnsafePointer(to=size).unsafe_origin_cast[MutUntrackedOrigin](),
    )
    if status != _SNAPPY_OK:
        raise Error(
            "snappy_uncompress failed (status=" + String(Int(status))
            + ", input_len=" + String(input_len)
            + ", output_cap=" + String(output_cap) + ")"
        )
    var written = Int(size)
    if written > output_cap:
        raise Error(
            "snappy_uncompress reported " + String(written)
            + " bytes written into a " + String(output_cap) + "-byte buffer"
        )
    return written


def snappy_uncompressed_length(src: Span[UInt8, _]) raises -> Int:
    """The decoded length the raw snappy block `src` declares in its
    preamble. Not checked against the block: a caller that allocates it
    bounds it first.

    Raises `snappy_uncompressed_length failed (status=S, input_len=N)` for a
    preamble snappy cannot parse (an empty `src` among them).
    """
    var input_len = len(src)
    var src_scratch = InlineArray[UInt8, 1](fill=UInt8(0))
    var result = UInt64(0)
    # SAFETY: snappy reads at most `input_len` bytes at the source address
    # and stores the declared length in `result`, a stack local. Both are
    # alive across this synchronous call; snappy keeps neither pointer.
    var status = external_call[
        "komira_snappy_uncompressed_length",
        Int32,
        UnsafePointer[UInt8, MutUntrackedOrigin],
        UInt64,
        UnsafePointer[UInt64, MutUntrackedOrigin],
    ](
        _src_ptr(src, src_scratch),
        UInt64(input_len),
        UnsafePointer(to=result).unsafe_origin_cast[MutUntrackedOrigin](),
    )
    if status != _SNAPPY_OK:
        raise Error(
            "snappy_uncompressed_length failed (status="
            + String(Int(status)) + ", input_len=" + String(input_len) + ")"
        )
    return Int(result)
