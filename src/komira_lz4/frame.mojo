# =============================================================================
# komira_lz4.frame
# =============================================================================
#
# The LZ4 FRAME codec (`LZ4F_*`): magic 04 22 4D 18, a frame descriptor, a
# block list and an end mark (doc/lz4_Frame_format.md in the lz4 repository).
# This is the framing Arrow IPC calls LZ4_FRAME. It is wire-incompatible with
# the raw blocks of `codec.mojo`; the two share only the library.
#
# liblz4 is opened once per process: these entries use the same `_Global`
# handle as `codec.mojo` (`komira_lz4_codec_handle`), so a process that uses
# both framings holds one dlopen of liblz4.
#
# # Encapsulation (FFI boundary)
#
# PUBLIC SAFE API (no pointer in any signature):
#   * `lz4_frame_compress_bound(src_len) -> Int`
#   * `lz4_frame_compress_into(dst: Span[mut], src: Span) -> Int`: one frame
#     with liblz4's default preferences (NULL prefs: level 0, no checksums).
#   * `lz4_frame_decompress_into(dst: Span[mut], src: Span) -> Int`: one-shot
#     decode with a fresh decompression context.
#   * `Lz4FrameDecoder`: owns one `LZ4F_dctx` for reuse across frames (a
#     per-worker cache); `decompress_into` resets it before each frame, and
#     its destructor frees it.
# The raw pointers (the `LZ4F_dctx*`, the buffers taken from the Spans, the
# size in/out slots) stay inside this file; every `handle.call` site carries a
# `# SAFETY:` comment.
#
# # One-shot decode contract (unchanged from the codec this replaced)
#
# A decode is ONE `LZ4F_decompress` call over all of `src`. It is refused when
# liblz4 reports an error or when it leaves any of `src` unconsumed (`src`
# holds more than one frame, or `dst` is too small for what `src` decodes to).
# The caller checks the returned byte count against the decoded size it knows
# out of band (an Arrow IPC buffer records it).
# =============================================================================

from .codec import _default_lz4_codec_handle

# lz4frame.h `#define LZ4F_VERSION 100`: passed to
# LZ4F_createDecompressionContext for its ABI version check.
comptime _LZ4F_VERSION: UInt32 = 100

comptime _UntrackedBytes = UnsafePointer[UInt8, MutUntrackedOrigin]


@always_inline
def _null_bytes() -> _UntrackedBytes:
    """A NULL `UInt8` pointer, for liblz4's NULL preferences / options /
    context arguments (NULL selects the documented defaults).

    # SAFETY: `Optional[UnsafePointer[...]]` is layout-compatible with the bare
    # pointer (the non-null-pointer layout guarantee) and `None` is the all-zero
    # bit pattern, so the bitcast yields NULL without `unsafe_from_address`.
    """
    var none: Optional[_UntrackedBytes] = None
    return UnsafePointer(to=none).bitcast[_UntrackedBytes]()[]


def _lz4f_is_error(code: Int) raises -> Bool:
    """liblz4's `unsigned LZ4F_isError(LZ4F_errorCode_t code)`."""
    var handle_ptr = _default_lz4_codec_handle()
    # SAFETY: pure function of its integer argument; no pointer crosses.
    return Int(handle_ptr[].call["LZ4F_isError", Int32](code)) != 0


def _lz4f_create_dctx() raises -> _UntrackedBytes:
    """A fresh `LZ4F_dctx*` from `LZ4F_createDecompressionContext`; the caller
    frees it with `_lz4f_free_dctx` exactly once."""
    var handle_ptr = _default_lz4_codec_handle()
    var dctx = _null_bytes()
    # SAFETY: `dctx` is a local slot alive across this synchronous call;
    # liblz4 writes the new context's address into it and keeps no pointer to
    # the slot. The context itself is liblz4's allocation, owned by the caller
    # from here on.
    var rc = handle_ptr[].call["LZ4F_createDecompressionContext", Int](
        UnsafePointer(to=dctx).unsafe_origin_cast[MutUntrackedOrigin](),
        _LZ4F_VERSION,
    )
    if _lz4f_is_error(rc):
        raise Error(
            "LZ4F_createDecompressionContext failed (rc=" + String(rc) + ")"
        )
    return dctx


def _lz4f_free_dctx(dctx: _UntrackedBytes):
    """Release a context from `_lz4f_create_dctx`. Null is a no-op."""
    if Int(dctx) == 0:
        return
    try:
        var handle_ptr = _default_lz4_codec_handle()
        # SAFETY: `dctx` came from LZ4F_createDecompressionContext and is freed
        # here once (its owner forgets it). The return code is 0 for a
        # well-formed context and carries nothing a destructor can act on.
        _ = handle_ptr[].call["LZ4F_freeDecompressionContext", Int](dctx)
    except:
        # The handle accessor raises only before liblz4 was ever opened, and a
        # context cannot exist then.
        pass


def _lz4f_decode_once[
    dori: MutOrigin
](
    dctx: _UntrackedBytes,
    dst: Span[UInt8, dori],
    src: Span[UInt8, _],
    reset: Bool,
) raises -> Int:
    """One `LZ4F_decompress` call over all of `src` into `dst` (see the
    one-shot contract in the header); returns the bytes written."""
    var n = len(src)
    var cap = len(dst)
    var handle_ptr = _default_lz4_codec_handle()
    if reset:
        # SAFETY: `dctx` is a live context its owner lent for this call.
        # LZ4F_resetDecompressionContext returns void; the Int return type is
        # declared only to satisfy `call` and is discarded.
        _ = handle_ptr[].call["LZ4F_resetDecompressionContext", Int](dctx)
    # LZ4F_decompress reads `*dstSizePtr` / `*srcSizePtr` as capacities and
    # writes back the bytes produced / consumed.
    var dst_size = cap
    var src_size = n
    var scratch = InlineArray[UInt8, 1](fill=UInt8(0))
    var dst_ptr = scratch.unsafe_ptr().unsafe_origin_cast[MutUntrackedOrigin]()
    if cap > 0:
        dst_ptr = dst.unsafe_ptr().unsafe_origin_cast[MutUntrackedOrigin]()
    # SAFETY: `dst` holds `cap` writable bytes (or, when empty, the local
    # one-byte `scratch` stands in with capacity 0) and `src` holds `n`
    # readable bytes; both are alive across this synchronous call through
    # their Span origins, as are the two local size slots. liblz4 writes at
    # most `dst_size` bytes, reads at most `src_size`, and keeps no pointer
    # to any of them past the call (the context holds only its own state).
    var result = handle_ptr[].call["LZ4F_decompress", Int](
        dctx,
        dst_ptr,
        UnsafePointer(to=dst_size).unsafe_origin_cast[MutUntrackedOrigin](),
        src.unsafe_ptr()
        .unsafe_mut_cast[True]()
        .unsafe_origin_cast[MutUntrackedOrigin](),
        UnsafePointer(to=src_size).unsafe_origin_cast[MutUntrackedOrigin](),
        _null_bytes(),
    )
    if _lz4f_is_error(result):
        raise Error(
            "LZ4F_decompress failed (result=" + String(result) + ", n="
            + String(n) + ", written=" + String(dst_size) + ")"
        )
    if dst_size > cap:
        raise Error(
            "LZ4F_decompress reported " + String(dst_size)
            + " bytes written into a " + String(cap) + "-byte buffer"
        )
    if src_size != n:
        raise Error(
            "incomplete decode (consumed=" + String(src_size) + " of "
            + String(n) + " bytes; only one-shot decode is supported, not"
            " multi-call streaming)"
        )
    return dst_size


# =============================================================================
# PUBLIC API
# =============================================================================


def lz4_frame_compress_bound(src_len: Int) raises -> Int:
    """The largest frame `lz4_frame_compress_into` can produce from `src_len`
    bytes (liblz4's `LZ4F_compressFrameBound` with default preferences)."""
    if src_len < 0:
        raise Error(
            "lz4_frame_compress_bound: negative src_len " + String(src_len)
        )
    var handle_ptr = _default_lz4_codec_handle()
    # SAFETY: NULL prefs selects the defaults; no buffer crosses.
    return handle_ptr[].call["LZ4F_compressFrameBound", Int](
        src_len, _null_bytes()
    )


def lz4_frame_compress_into[
    dori: MutOrigin
](dst: Span[UInt8, dori], src: Span[UInt8, _]) raises -> Int:
    """Encode all of `src` as ONE LZ4 frame into `dst`; return the bytes
    written.

    Default preferences (liblz4's NULL prefs: compression level 0, 64 KiB
    linked blocks, no checksums, no content size). `dst` must hold at least
    `lz4_frame_compress_bound(len(src))` bytes; a smaller one is refused before
    liblz4 is called. An empty `src` is a valid frame (header and end mark).
    """
    var n = len(src)
    var need = lz4_frame_compress_bound(n)
    var cap = len(dst)
    if cap < need:
        raise Error(
            "lz4_frame_compress_into: destination holds " + String(cap)
            + " bytes, below lz4_frame_compress_bound(" + String(n) + ") = "
            + String(need)
        )
    var handle_ptr = _default_lz4_codec_handle()
    # SAFETY: `dst` holds `cap >= need > 0` writable bytes and `src` holds `n`
    # readable bytes, both alive across this synchronous call through their
    # Span origins; liblz4 writes at most `cap`, reads exactly `n` and keeps
    # neither pointer. NULL prefs selects the defaults.
    var written = handle_ptr[].call["LZ4F_compressFrame", Int](
        dst.unsafe_ptr().unsafe_origin_cast[MutUntrackedOrigin](),
        cap,
        src.unsafe_ptr()
        .unsafe_mut_cast[True]()
        .unsafe_origin_cast[MutUntrackedOrigin](),
        n,
        _null_bytes(),
    )
    if _lz4f_is_error(written):
        raise Error(
            "lz4_frame_compress_into: LZ4F_compressFrame failed (result="
            + String(written) + ", n=" + String(n) + ", dst_capacity="
            + String(cap) + ")"
        )
    if written > cap:
        raise Error(
            "lz4_frame_compress_into: liblz4 reported " + String(written)
            + " bytes written into a " + String(cap) + "-byte buffer"
        )
    return written


def lz4_frame_decompress_into[
    dori: MutOrigin
](dst: Span[UInt8, dori], src: Span[UInt8, _]) raises -> Int:
    """Decode the LZ4 frame `src` into `dst` with a fresh context; return the
    bytes written. One-shot: see the contract in this file's header."""
    var decoder = Lz4FrameDecoder()
    try:
        # A fresh context needs no reset. `_decode` borrows `decoder`, so the
        # context outlives the call (a bare `decoder._dctx` argument would let
        # the decoder, and with it the context, be destroyed first).
        return decoder._decode(dst, src, reset=False)
    except e:
        raise Error("lz4_frame_decompress_into: " + String(e))


struct Lz4FrameDecoder(Movable):
    """One LZ4 frame decompression context (`LZ4F_dctx`), reused across frames.

    Creating a context costs an allocation of a few KB; a worker that decodes
    many frames keeps one of these instead. `decompress_into` resets the
    context before each frame, so a frame that failed half way leaves no state
    behind. The destructor frees the context.
    """

    var _dctx: UnsafePointer[UInt8, MutUntrackedOrigin]

    def __init__(out self) raises:
        self._dctx = _lz4f_create_dctx()

    def decompress_into[
        dori: MutOrigin
    ](mut self, dst: Span[UInt8, dori], src: Span[UInt8, _]) raises -> Int:
        """Reset the context, then decode the LZ4 frame `src` into `dst`;
        return the bytes written. One-shot: see the contract in this file's
        header."""
        try:
            return self._decode(dst, src, reset=True)
        except e:
            raise Error("Lz4FrameDecoder.decompress_into: " + String(e))

    def _decode[
        dori: MutOrigin
    ](
        mut self, dst: Span[UInt8, dori], src: Span[UInt8, _], reset: Bool
    ) raises -> Int:
        # SAFETY: `self` is borrowed for the whole call, so `self._dctx` is a
        # live context until `_lz4f_decode_once` returns.
        return _lz4f_decode_once(self._dctx, dst, src, reset)

    def __deinit__(deinit self):
        _lz4f_free_dctx(self._dctx)
