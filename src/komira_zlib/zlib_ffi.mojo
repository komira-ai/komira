# =============================================================================
# komira_zlib/zlib_ffi.mojo
# =============================================================================
#
# Deflate and inflate — FFI wrappers over libz's `deflateInit2_` /
# `deflate(Z_FINISH)` / `deflateEnd` / `deflateBound` / `inflateInit2_` /
# `inflate` / `inflateEnd` / `zlibVersion` symbols.
#
# # Why FFI
#
# A pure-Mojo deflate that emits each token's Huffman code immediately loses
# to libz on compressible data: libz's `deflate_fast` defers Huffman emission
# to end-of-block via a tally buffer (`s->sym_buf`, the `_tr_tally` macro in
# deflate.c). Closing that gap natively would mean re-implementing the tally
# buffer or dynamic-Huffman tree construction. Delegating to libz meets the
# performance bar deterministically, because libz IS the reference.
#
# # Approach: runtime dlopen via OwnedDLHandle
#
# The same pattern as the other compression-codec FFI shims: the library is
# RUNTIME-loaded with OwnedDLHandle (`libz.dylib` / `libz.so.1` from the
# environment), so there is no static archive to link and no build-toolchain
# wiring for consumers.
#
# # API
#
# Span in, caller-owned Span out, bytes written back:
#
#   def zlib_deflate_into(dst, src, level: Int32, window_bits: Int32) -> Int
#   def zlib_inflate_into(dst, src, window_bits=ZLIB_WINDOW_BITS_AUTO) -> Int
#   def zlib_inflate_once(dst, src, window_bits) -> ZlibInflateOutcome
#   def zlib_compress_bound(src_len: Int, window_bits: Int32) -> Int
#   def zlib_skip_stream(src, window_bits=ZLIB_WINDOW_BITS_AUTO) -> Int
#
# libz's API is stateful: `deflateInit2_` (with a version + sizeof handshake)
# → `deflate(Z_FINISH)` → `deflateEnd`, and the same shape for inflate. Each
# entry hides that lifecycle in one call: it allocates a 112-byte z_stream
# scratch buffer, sets the four I/O fields at known offsets, drives the libz
# calls, reads the totals, and frees the stream.
#
# `window_bits` selects the framing per libz convention (the
# `ZLIB_WINDOW_BITS_*` constants below):
#   * 15 (max)        : zlib wrapper (RFC 1950 — Adler-32 trailer)
#   * -15 (negative)  : raw deflate (RFC 1951 — no header/trailer)
#   * 15 + 16 = 31    : gzip wrapper (RFC 1952 — CRC-32 trailer)
#   * 15 + 32 = 47    : inflate only — zlib or gzip, whichever the stream has
#
# # OwnedDLHandle singleton (process-lifetime, ~220us first-call cost)
#
# Process-lifetime libz handle via the stdlib `_Global` runtime slot (dlopen
# once, init-once, cross-compile-unit-coherent). No env var and no
# `unsafe_from_address`.
#
# # Encapsulation discipline
#
# Public API: the Span entries at the bottom of the file (`zlib_inflate_into`,
# `zlib_inflate_once`, `zlib_deflate_into`, `zlib_compress_bound`,
# `zlib_skip_stream`). No public
# signature holds a raw pointer.
# Internal FFI (underscore-prefixed: private to this module by convention; the
# compiler does not enforce it):
#   * The `_zlib_*_ffi` entries take UnsafePointer with CALLER-CHOSEN origins
#     (Origin / MutOrigin generic params), NOT wildcards; only the Span
#     entries call them, with pointers taken from their Spans.
#   * The handle singleton is a stdlib `_Global` slot; `get_or_create_ptr()`
#     returns `MutUntrackedOrigin` into process-lifetime static storage (no env
#     var, no `unsafe_from_address`) — the documented FFI-BOUNDARY carve-out.
#   * Caller pointers are cast to an untracked origin ONLY at the
#     `handle.call[...]` site. The cast is local to the call body.
#   * The z_stream scratch buffer is allocated, used, and freed inside the
#     function — never escapes. `init_zero` zeroes the 112-byte region
#     (sets zalloc/zfree/opaque to NULL so libz uses its default allocator).
#   * ZERO `unsafe_from_address=Int(...)`.
#   * ZERO `take_pointee`.
#   * ZERO ArcPointer.
#   * Every `external_call` / `handle.call` site carries a multi-line
#     `# SAFETY:` comment.
# =============================================================================

from std.ffi import OwnedDLHandle, _Global
from std.memory import alloc, unsafe_memset
from std.os import abort
from std.sys.info import CompilationTarget


# -----------------------------------------------------------------------------
# Per-OS soname. Both branches type-check on
# every host; comptime if elides the non-host branch at codegen.
# -----------------------------------------------------------------------------

comptime _LIBZ: StaticString = (
    "libz.dylib" if CompilationTarget.is_macos() else "libz.so.1"
)

# -----------------------------------------------------------------------------
# libz constants (zlib.h)
# -----------------------------------------------------------------------------

comptime _Z_OK: Int32 = 0
comptime _Z_STREAM_END: Int32 = 1
comptime _Z_FINISH: Int32 = 4
comptime _Z_DEFLATED: Int32 = 8           # compression method (only valid value)
comptime _Z_DEFAULT_STRATEGY: Int32 = 0
comptime _Z_DEFAULT_MEM_LEVEL: Int32 = 8  # libz default

# The "z_stream" struct on 64-bit ABIs is 112 bytes (verified empirically on
# macOS arm64 + linux-x86_64). libz's deflateInit2_ requires the stream_size
# argument to match sizeof(z_stream) exactly (Z_VERSION_ERROR = -6 otherwise).
# We allocate the exact 112-byte region and zero-fill; libz then uses its
# default allocator (NULL zalloc/zfree). The field offsets this file uses are
# listed in `_z_stream_set_in_out` and `_z_stream_total_in`.
comptime _Z_STREAM_BYTES: Int = 112

# `_zlib_skip_stream_ffi` scratch: output is discarded, so this is a pure
# throughput/round-count tradeoff and NOT a correctness bound. 64 KiB keeps the
# resident cost of skipping an arbitrarily large entry constant.
comptime _SKIP_SCRATCH_BYTES: Int = 64 * 1024
# A compression bomb ceiling for the skip loop: 262144 rounds x 64 KiB = 16 GiB
# of decompressed output. Far above any legitimate single git object; low enough
# that a malicious stream cannot spin forever.
comptime _SKIP_MAX_ROUNDS: Int = 262144
# Returned by `inflate` when it can make no progress (no input consumed and no
# output produced). Benign mid-stream when we have just re-pointed avail_out; the
# skip loop treats it as "keep going" and relies on the avail_in==0 truncation
# check to terminate.
comptime _Z_BUF_ERROR: Int32 = -5


# -----------------------------------------------------------------------------
# Process-lifetime OwnedDLHandle singleton via the stdlib `_Global` runtime slot.
#
# `_Global[name, init_fn]` provides a name-keyed, process-global, init-once,
# cross-compile-unit-coherent slot managed by the KGEN runtime, so the handle
# needs no env var, no address round-trip and no wildcard-origin pointer. The
# distinct `_Global` name keeps this libz handle independent of any other
# library's libz singleton.
# -----------------------------------------------------------------------------


def _init_zlib_ffi_handle() -> OwnedDLHandle:
    """`_Global` init_fn: dlopen libz exactly once per process (KGEN-serialized).

    SAFETY: `_Global`'s init_fn must be non-raising. The OwnedDLHandle ctor
    raises only when the pinned dylib is unresolvable (a fatal provisioning
    error), so we `abort`: an unloadable libz cannot serve any later call.
    """
    try:
        return OwnedDLHandle(_LIBZ)
    except e:
        abort("libz dlopen failed (komira_zlib FFI handle init)")


comptime _ZLIB_FFI_GLOBAL = _Global[
    "komira_zlib_ffi_handle", _init_zlib_ffi_handle
]


@always_inline
def _default_zlib_ffi_handle() raises -> UnsafePointer[
    OwnedDLHandle, MutUntrackedOrigin
]:
    """Return the process-lifetime libz handle slot (init-once via `_Global`).

    SAFETY: FFI carve-out. Targets KGEN-runtime-managed static storage
    (process-lifetime); `MutUntrackedOrigin` is the stdlib `_Global` API's own
    return type, confined to this FFI helper. No env var, no `unsafe_from_address`.
    """
    return _ZLIB_FFI_GLOBAL.get_or_create_ptr()


# -----------------------------------------------------------------------------
# z_stream scratch helpers — minimal field setters.
# -----------------------------------------------------------------------------


@always_inline
def _z_stream_init_zero(z: UnsafePointer[UInt8, MutUntrackedOrigin]):
    """Zero-fill the 112-byte z_stream area. Sets zalloc/zfree/opaque to
    NULL so libz uses its default allocator.
    """
    unsafe_memset(z, UInt8(0), _Z_STREAM_BYTES)


@always_inline
def _z_stream_set_in_out(
    z: UnsafePointer[UInt8, MutUntrackedOrigin],
    src: UnsafePointer[UInt8, MutUntrackedOrigin],
    src_len: Int,
    dst: UnsafePointer[UInt8, MutUntrackedOrigin],
    dst_cap: Int,
):
    """Set next_in/avail_in/next_out/avail_out at z_stream offsets 0/8/24/32.

    z_stream layout (LP64, empirically verified):
      offset  0, size 8: next_in   (const unsigned char*)
      offset  8, size 4: avail_in  (unsigned int)
      offset 24, size 8: next_out  (unsigned char*)
      offset 32, size 4: avail_out (unsigned int)
    total_out lives at offset 40 (read post-deflate via _z_stream_total_out).
    """
    var nin_words = z.bitcast[UInt64]()
    nin_words[0] = UInt64(Int(src))
    var av_in = (z + 8).bitcast[UInt32]()
    av_in[0] = UInt32(src_len)
    var nout_words = (z + 24).bitcast[UInt64]()
    nout_words[0] = UInt64(Int(dst))
    var av_out = (z + 32).bitcast[UInt32]()
    av_out[0] = UInt32(dst_cap)


@always_inline
def _z_stream_set_avail_in(z: UnsafePointer[UInt8, MutUntrackedOrigin], n: Int):
    """Set avail_in @ offset 8 (UInt32) without moving next_in."""
    (z + 8).bitcast[UInt32]()[0] = UInt32(n)


@always_inline
def _z_stream_set_avail_out(z: UnsafePointer[UInt8, MutUntrackedOrigin], n: Int):
    """Set avail_out @ offset 32 (UInt32) without moving next_out."""
    (z + 32).bitcast[UInt32]()[0] = UInt32(n)


@always_inline
def _z_stream_total_out(z: UnsafePointer[UInt8, MutUntrackedOrigin]) -> Int:
    """Read total_out @ offset 40 (UInt64)."""
    return Int((z + 40).bitcast[UInt64]()[0])


@always_inline
def _z_stream_total_in(z: UnsafePointer[UInt8, MutUntrackedOrigin]) -> Int:
    """Read total_in @ offset 16 (UInt64).

    z_stream layout continues from `_z_stream_set_in_out`:
      offset  8, size 4: avail_in
      offset 12, size 4: (padding to the 8-byte alignment of total_in)
      offset 16, size 8: total_in  (uLong — bytes CONSUMED from next_in)

    total_in is the field a stream SCANNER needs and total_out cannot supply: to
    find where one deflate stream ends and the next begins in a concatenated
    container (a git packfile), you must know how much INPUT the stream ate."""
    return Int((z + 16).bitcast[UInt64]()[0])


@always_inline
def _z_stream_avail_in(z: UnsafePointer[UInt8, MutUntrackedOrigin]) -> Int:
    """Read avail_in @ offset 8 (UInt32) — input bytes still UNREAD. Zero after a
    non-Z_STREAM_END `inflate` means the stream is truncated: there is nothing
    left to feed it, so no further round can make progress."""
    return Int((z + 8).bitcast[UInt32]()[0])


@always_inline
def _z_stream_set_out(
    z: UnsafePointer[UInt8, MutUntrackedOrigin],
    dst: UnsafePointer[UInt8, MutUntrackedOrigin],
    dst_cap: Int,
):
    """Re-point next_out/avail_out (offsets 24/32) WITHOUT touching next_in /
    avail_in, so a bounded scratch buffer can be reused across `inflate` calls
    while the input cursor keeps advancing."""
    var nout_words = (z + 24).bitcast[UInt64]()
    nout_words[0] = UInt64(Int(dst))
    var av_out = (z + 32).bitcast[UInt32]()
    av_out[0] = UInt32(dst_cap)


# -----------------------------------------------------------------------------
# Private FFI wrappers — one-shot libz calls the Span entries delegate to.
# -----------------------------------------------------------------------------


def _zlib_deflate_ffi[
    sori: Origin, dori: MutOrigin
](
    dst: UnsafePointer[UInt8, dori],
    dst_capacity: Int,
    src: UnsafePointer[UInt8, sori],
    src_size: Int,
    level: Int32,
    window_bits: Int32,
    slice: Int,
) raises -> Int:
    """Deflate all of `src` as one stream via libz's `deflateInit2_` /
    `deflate` / `deflateEnd`. Returns total bytes written to dst.

    libz's `avail_in` / `avail_out` are 32-bit `uInt`, so the input and the
    output are offered at most `slice` bytes at a time (`_UINT_MAX` in
    production), topped up whenever libz has used them up, with `Z_FINISH` once
    the last input slice is offered. This is the loop of libz's own `compress2`;
    the stream is the same bytes however it is sliced, and any length works.

    `window_bits` selects framing per zlib.h convention:
        15 (max)       : zlib wrapper (RFC 1950 — Adler-32 trailer)
       -15 (negative)  : raw deflate (RFC 1951 — no header/trailer)
       15 + 16 = 31    : gzip wrapper (RFC 1952 — CRC-32 trailer)

    `window_bits` is the framing selector a codec maps from its own
    container choice.

    SAFETY: libz reads exactly `src_size` bytes from `src` and writes up to
    `dst_capacity` bytes to `dst` (it never reads or writes past the
    `avail_in` / `avail_out` this loop offers, which sum to those sizes). Both
    buffers are caller-owned for the duration of this synchronous call; libz
    retains no pointer past `deflateEnd`. The handle is a
    process-lifetime singleton (never freed). Origins are cast to
    an untracked origin ONLY at the call site.
    """
    var handle_ptr = _default_zlib_ffi_handle()

    # Fetch zlib version string — `deflateInit2_` validates that the caller
    # compiled against a compatible zlib ABI (Z_VERSION_ERROR = -6 otherwise).
    var version = handle_ptr[].call[
        "zlibVersion", UnsafePointer[UInt8, MutUntrackedOrigin]
    ]()

    # Allocate the opaque z_stream scratch buffer (112 bytes, zero-init).
    # SAFETY: `strm` is freed via `deflateEnd` + alloc.free() before return.
    var strm = alloc[UInt8](_Z_STREAM_BYTES)
    _z_stream_init_zero(strm)
    # Cursors only: the loop below offers the bytes in slices.
    _z_stream_set_in_out(
        strm,
        src.unsafe_mut_cast[True]().unsafe_origin_cast[MutUntrackedOrigin](),
        0,
        dst.unsafe_origin_cast[MutUntrackedOrigin](),
        0,
    )

    # deflateInit2_(stream, level, method=Z_DEFLATED, windowBits,
    #               memLevel=8, strategy=Z_DEFAULT_STRATEGY,
    #               version, sizeof(z_stream))
    var init_rc = handle_ptr[].call["deflateInit2_", Int32](
        strm, level, _Z_DEFLATED, window_bits, _Z_DEFAULT_MEM_LEVEL,
        _Z_DEFAULT_STRATEGY, version, Int32(_Z_STREAM_BYTES),
    )
    if Int(init_rc) != Int(_Z_OK):
        strm.free()
        raise Error(
            "libz deflateInit2_ failed (rc=" + String(Int(init_rc))
            + ", level=" + String(Int(level))
            + ", window_bits=" + String(Int(window_bits)) + ")"
        )

    var left_in = src_size
    var left_out = dst_capacity
    var rc = _Z_OK
    while True:
        if _z_stream_avail_out(strm) == 0:
            var take = min(left_out, slice)
            _z_stream_set_avail_out(strm, take)
            left_out -= take
        if _z_stream_avail_in(strm) == 0:
            var take = min(left_in, slice)
            _z_stream_set_avail_in(strm, take)
            left_in -= take
        # Z_FINISH once no input is left to offer; Z_OK means progress was
        # made and the loop goes on, anything else ends it (Z_STREAM_END:
        # done; Z_BUF_ERROR: the output space ran out).
        var flush = _Z_FINISH if left_in == 0 else _Z_NO_FLUSH
        rc = handle_ptr[].call["deflate", Int32](strm, flush)
        if Int(rc) != Int(_Z_OK):
            break
    if Int(rc) != Int(_Z_STREAM_END):
        _ = handle_ptr[].call["deflateEnd", Int32](strm)
        strm.free()
        raise Error(
            "libz deflate(Z_FINISH) failed (rc=" + String(Int(rc))
            + ", input_len=" + String(src_size)
            + ", output_cap=" + String(dst_capacity) + ")"
        )

    var written = _z_stream_total_out(strm)
    var _end_rc = handle_ptr[].call["deflateEnd", Int32](strm)
    strm.free()
    return written


def _zlib_compress_bound_ffi(src_size: Int, window_bits: Int32) raises -> Int:
    """Libz `deflateBound` — maximum possible compressed size after a
    `deflateInit2_(...)` with the given `window_bits`.

    Per zlib.h docs, deflateBound requires a stream initialized with the
    target compression parameters (the bound depends on memLevel/windowBits/
    strategy). We do the init/bound/end round-trip rather than computing the
    bound in-Mojo, so the bound is exactly what libz's own deflate will use.

    For window_bits selecting RAW/ZLIB/GZIP, the difference is the header/
    trailer overhead: gzip is +18 bytes vs raw, zlib is +6 vs raw.

    SAFETY: stream allocated, used in two sequential calls
    (deflateInit2_ + deflateBound + deflateEnd), then freed before return.
    """
    var handle_ptr = _default_zlib_ffi_handle()

    var version = handle_ptr[].call[
        "zlibVersion", UnsafePointer[UInt8, MutUntrackedOrigin]
    ]()

    var strm = alloc[UInt8](_Z_STREAM_BYTES)
    _z_stream_init_zero(strm)

    # Use level 6 (libz default) for the bound; the bound is conservative
    # enough that level variance doesn't matter — we want the max-possible
    # output, which deflateBound computes from memLevel/windowBits alone.
    var init_rc = handle_ptr[].call["deflateInit2_", Int32](
        strm, Int32(6), _Z_DEFLATED, window_bits, _Z_DEFAULT_MEM_LEVEL,
        _Z_DEFAULT_STRATEGY, version, Int32(_Z_STREAM_BYTES),
    )
    if Int(init_rc) != Int(_Z_OK):
        strm.free()
        raise Error(
            "libz deflateInit2_ (for bound) failed (rc="
            + String(Int(init_rc)) + ")"
        )

    var bound = handle_ptr[].call["deflateBound", Int64](
        strm, Int64(src_size)
    )
    var _end_rc = handle_ptr[].call["deflateEnd", Int32](strm)
    strm.free()
    return Int(bound)


# -----------------------------------------------------------------------------
# Inflate side. The shim mirrors the deflate side: one-shot inflateInit2_ /
# inflate(Z_NO_FLUSH) / inflateEnd lifecycle via the same OwnedDLHandle
# singleton.
# -----------------------------------------------------------------------------


comptime _Z_NO_FLUSH: Int32 = 0
# windowBits = 15 (max) + 32 (auto-detect gzip vs zlib vs raw deflate).
# This is what a Parquet column decode path needs — Parquet files in the wild
# use any of the three framings.
comptime _WBITS_AUTO: Int32 = 15 + 32


@always_inline
def _z_stream_avail_out(z: UnsafePointer[UInt8, MutUntrackedOrigin]) -> Int:
    """Read avail_out @ offset 32 (UInt32) — output space still UNWRITTEN. Zero
    after a non-Z_STREAM_END `inflate` means the output buffer filled up."""
    return Int((z + 32).bitcast[UInt32]()[0])


@fieldwise_init
struct ZlibInflateOutcome(Copyable, Movable):
    """What one `inflate(Z_NO_FLUSH)` call left behind: libz's return code, the
    bytes it wrote, the input it left unread and the output space it left
    unwritten."""

    var rc: Int32
    var written: Int
    var unread: Int
    var unwritten: Int


def _zlib_inflate_once[
    sori: Origin, dori: MutOrigin
](
    dst: UnsafePointer[UInt8, dori],
    dst_capacity: Int,
    src: UnsafePointer[UInt8, sori],
    src_size: Int,
    window_bits: Int32,
) raises -> ZlibInflateOutcome:
    """One `inflateInit2_` / `inflate(Z_NO_FLUSH)` / `inflateEnd` round, with
    the `inflate` return code handed back rather than judged. Raises only when
    `inflateInit2_` fails.

    SAFETY: libz's `inflate(Z_NO_FLUSH)` reads up to `src_size` bytes from
    `src` and writes up to `dst_capacity` bytes to `dst`. Both buffers are
    caller-owned for the synchronous call; libz retains no pointer past
    `inflateEnd`. The handle is a process-lifetime singleton (never freed).
    Origins are cast to an untracked origin ONLY at the call site (same
    pattern as the deflate side of this file).
    """
    var handle_ptr = _default_zlib_ffi_handle()

    # Fetch zlib version string for the inflateInit2_ ABI handshake.
    var version = handle_ptr[].call[
        "zlibVersion", UnsafePointer[UInt8, MutUntrackedOrigin]
    ]()

    # Allocate the opaque z_stream scratch buffer (112 bytes, zero-init).
    # SAFETY: `strm` is freed via `inflateEnd` + alloc.free() before return.
    var strm = alloc[UInt8](_Z_STREAM_BYTES)
    _z_stream_init_zero(strm)
    _z_stream_set_in_out(
        strm,
        src.unsafe_mut_cast[True]().unsafe_origin_cast[MutUntrackedOrigin](),
        src_size,
        dst.unsafe_origin_cast[MutUntrackedOrigin](),
        dst_capacity,
    )

    var init_rc = handle_ptr[].call["inflateInit2_", Int32](
        strm, window_bits, version, Int32(_Z_STREAM_BYTES),
    )
    if Int(init_rc) != Int(_Z_OK):
        strm.free()
        raise Error(
            "libz inflateInit2_ failed (rc=" + String(Int(init_rc))
            + ", window_bits=" + String(Int(window_bits)) + ")"
        )

    var rc = handle_ptr[].call["inflate", Int32](strm, _Z_NO_FLUSH)
    # total_out at offset 40 (read via _z_stream_total_out).
    var written = _z_stream_total_out(strm)
    var unread = _z_stream_avail_in(strm)
    var unwritten = _z_stream_avail_out(strm)
    var _end_rc = handle_ptr[].call["inflateEnd", Int32](strm)
    strm.free()
    return ZlibInflateOutcome(rc, written, unread, unwritten)


# -----------------------------------------------------------------------------
# _zlib_skip_stream_ffi — how many INPUT bytes does one deflate stream occupy?
# -----------------------------------------------------------------------------


def _zlib_skip_stream_ffi[
    sori: Origin
](
    src: UnsafePointer[UInt8, sori],
    src_size: Int,
    window_bits: Int32 = _WBITS_AUTO,
) raises -> Int:
    """Run the deflate stream at `src` to its end and return the number of INPUT
    bytes it consumed. The decompressed output is DISCARDED.

    This is the primitive for scanning a container of CONCATENATED deflate
    streams whose members are not length-prefixed — a git PACKFILE being the
    motivating case: each entry is `<varint header><optional base ref><deflate
    stream>`, and the only way to reach entry i+1 is to run entry i's stream to
    Z_STREAM_END and ask how much input it ate.

    ★ MEMORY IS BOUNDED AND INDEPENDENT OF THE DECOMPRESSED SIZE. Output goes
    into a fixed `_SKIP_SCRATCH_BYTES` scratch buffer that is re-pointed on every
    iteration, so skipping a 1 GiB blob entry costs 64 KiB resident, not 1 GiB.
    `_zlib_inflate_once` cannot serve this role: it is one-shot and needs a `dst`
    at least as large as the decompressed payload, which on a push path is the
    exact resident-memory cost the scan exists to avoid.

    Returns `total_in` at Z_STREAM_END. Raises if the stream is truncated
    (input exhausted before Z_STREAM_END) or corrupt.

    SAFETY: `src` is caller-owned for the synchronous call; `scratch` is a local
    allocation freed before every return path. libz retains no pointer past
    `inflateEnd`. Origins are cast to an untracked origin only at the call site —
    the same pattern as `_zlib_inflate_once` above.
    """
    var handle_ptr = _default_zlib_ffi_handle()
    var version = handle_ptr[].call[
        "zlibVersion", UnsafePointer[UInt8, MutUntrackedOrigin]
    ]()

    var scratch = alloc[UInt8](_SKIP_SCRATCH_BYTES)
    var strm = alloc[UInt8](_Z_STREAM_BYTES)
    _z_stream_init_zero(strm)
    _z_stream_set_in_out(
        strm,
        src.unsafe_mut_cast[True]().unsafe_origin_cast[MutUntrackedOrigin](),
        src_size,
        scratch,
        _SKIP_SCRATCH_BYTES,
    )

    var init_rc = handle_ptr[].call["inflateInit2_", Int32](
        strm, window_bits, version, Int32(_Z_STREAM_BYTES),
    )
    if Int(init_rc) != Int(_Z_OK):
        strm.free()
        scratch.free()
        raise Error(
            "libz inflateInit2_ failed in skip (rc=" + String(Int(init_rc))
            + ", window_bits=" + String(Int(window_bits)) + ")"
        )

    var rc: Int32
    var guard = 0
    while True:
        # Re-point the output at the scratch head each round: we are throwing
        # the bytes away, so the same 64 KiB serves the whole stream.
        _z_stream_set_out(strm, scratch, _SKIP_SCRATCH_BYTES)
        rc = handle_ptr[].call["inflate", Int32](strm, _Z_NO_FLUSH)
        if Int(rc) == Int(_Z_STREAM_END):
            break
        if Int(rc) != Int(_Z_OK) and Int(rc) != Int(_Z_BUF_ERROR):
            var consumed_err = _z_stream_total_in(strm)
            _ = handle_ptr[].call["inflateEnd", Int32](strm)
            strm.free()
            scratch.free()
            raise Error(
                "libz inflate failed in skip (rc=" + String(Int(rc))
                + ", input_len=" + String(src_size)
                + ", consumed=" + String(consumed_err) + ")"
            )
        # Z_OK / Z_BUF_ERROR with the input EXHAUSTED means the stream is
        # TRUNCATED: nothing is left to feed it, so no further round can make
        # progress. (avail_out hitting 0 with input remaining is the normal case
        # and is handled by re-pointing the scratch at the top of the loop.)
        if _z_stream_avail_in(strm) == 0:
            _ = handle_ptr[].call["inflateEnd", Int32](strm)
            strm.free()
            scratch.free()
            raise Error(
                "libz inflate: truncated deflate stream in skip (input_len="
                + String(src_size) + ")"
            )
        guard += 1
        if guard > _SKIP_MAX_ROUNDS:
            _ = handle_ptr[].call["inflateEnd", Int32](strm)
            strm.free()
            scratch.free()
            raise Error(
                "libz inflate: skip exceeded " + String(_SKIP_MAX_ROUNDS)
                + " rounds (" + String(_SKIP_MAX_ROUNDS * _SKIP_SCRATCH_BYTES)
                + " decompressed bytes) — refusing a runaway stream"
            )

    var consumed = _z_stream_total_in(strm)
    _ = handle_ptr[].call["inflateEnd", Int32](strm)
    strm.free()
    scratch.free()
    return consumed


# =============================================================================
# PUBLIC API — SAFE (Span in, Span out; ZERO raw pointer in any signature).
#
# The raw pointers are taken from the Spans here, inside this module, for the
# one synchronous libz call; the Span origins are concrete, so the buffers are
# alive for the whole call. libz counts in `uInt` (32 bits): `zlib_deflate_into`
# feeds any length in 32-bit slices (compress2's own loop); inflate and
# `zlib_skip_stream` refuse a source past 4 GiB and offer a larger
# destination as 4 GiB.
# =============================================================================

# `window_bits` framing selectors (zlib.h).
# zlib wrapper (RFC 1950, Adler-32 trailer).
comptime ZLIB_WINDOW_BITS_ZLIB: Int32 = 15
# Raw deflate (RFC 1951, no header or trailer).
comptime ZLIB_WINDOW_BITS_RAW: Int32 = -15
# gzip wrapper (RFC 1952, CRC-32 trailer).
comptime ZLIB_WINDOW_BITS_GZIP: Int32 = 15 + 16
# Inflate only: accept a zlib or a gzip wrapper, whichever the stream has. The
# default of `zlib_inflate_into`, and load-bearing for Parquet interop: writers
# (parquet-mr, DuckDB, pyarrow, Spark) disagree on which framing they emit for
# the GZIP codec id.
comptime ZLIB_WINDOW_BITS_AUTO: Int32 = _WBITS_AUTO
# libz's default compression level.
comptime ZLIB_LEVEL_DEFAULT: Int32 = 6

comptime _UINT_MAX: Int = 4294967295


def zlib_compress_bound(src_len: Int, window_bits: Int32) raises -> Int:
    """The largest stream `zlib_deflate_into` can produce from `src_len` bytes
    under `window_bits` framing (libz's `deflateBound`)."""
    if src_len < 0:
        raise Error("zlib_compress_bound: negative src_len " + String(src_len))
    return _zlib_compress_bound_ffi(src_len, window_bits)


def zlib_deflate_into[
    dori: MutOrigin
](
    dst: Span[UInt8, dori],
    src: Span[UInt8, _],
    level: Int32,
    window_bits: Int32,
) raises -> Int:
    """Compress all of `src` into `dst` as ONE stream framed by `window_bits`
    (`ZLIB_WINDOW_BITS_ZLIB` / `_RAW` / `_GZIP`); return the bytes written.

    `dst` must hold at least `zlib_compress_bound(len(src), window_bits)` bytes;
    a smaller one is refused before libz is called. An empty `src` is a valid
    stream of no bytes (for gzip, 20 bytes: header, an empty final block,
    trailer). Any length works: libz is fed in 32-bit slices.
    """
    return _zlib_deflate_into_sliced(dst, src, level, window_bits, _UINT_MAX)


def _zlib_deflate_into_sliced[
    dori: MutOrigin
](
    dst: Span[UInt8, dori],
    src: Span[UInt8, _],
    level: Int32,
    window_bits: Int32,
    slice: Int,
) raises -> Int:
    """`zlib_deflate_into` with the libz slice size as a parameter, so a test
    can cross many slice boundaries without a 4 GiB buffer. Private by
    convention: production passes `_UINT_MAX`."""
    if slice <= 0 or slice > _UINT_MAX:
        raise Error("zlib_deflate_into: bad slice " + String(slice))
    var n = len(src)
    var need = zlib_compress_bound(n, window_bits)
    if len(dst) < need:
        raise Error(
            "zlib_deflate_into: destination holds " + String(len(dst))
            + " bytes, below zlib_compress_bound(" + String(n) + ", "
            + String(Int(window_bits)) + ") = " + String(need)
        )
    var cap = len(dst)
    # SAFETY: `dst` holds `cap > 0` writable bytes and `src` holds `n` readable
    # bytes, both kept alive by their Span origins for this synchronous call;
    # libz writes at most `cap` bytes, reads exactly `n` (a null `next_in` is
    # accepted when `avail_in == 0`), and keeps neither pointer past
    # `deflateEnd`.
    var written = _zlib_deflate_ffi(
        dst.unsafe_ptr(), cap, src.unsafe_ptr(), n, level, window_bits, slice
    )
    if written > cap:
        raise Error(
            "zlib_deflate_into: libz reported " + String(written)
            + " bytes written into a " + String(cap) + "-byte buffer"
        )
    return written


def zlib_inflate_into[
    dori: MutOrigin
](
    dst: Span[UInt8, dori],
    src: Span[UInt8, _],
    window_bits: Int32 = ZLIB_WINDOW_BITS_AUTO,
) raises -> Int:
    """Decompress the stream at the start of `src` into `dst`; return the bytes
    written. The stream must END inside `src` and its output must fit in `dst`:

      * output past `len(dst)` is refused (libz never writes past it),
      * a source that ends before the stream does is refused (truncated),
      * a corrupt stream, or one whose check value (Adler-32 / CRC-32) does not
        match, is refused,
      * an empty `src` is refused (no stream is zero bytes long).

    Bytes in `src` after the end of the first stream are not read; a gzip file
    of several members decodes its first member only.
    """
    var n = len(src)
    if n == 0:
        raise Error("zlib_inflate_into: empty source (no stream is empty)")
    if n > _UINT_MAX:
        raise Error(
            "zlib_inflate_into: source of " + String(n)
            + " bytes exceeds libz's 32-bit length"
        )
    var cap = min(len(dst), _UINT_MAX)
    var outcome: ZlibInflateOutcome
    if cap == 0:
        # libz refuses a null `next_out` even with `avail_out == 0`, and an
        # empty Span may carry one: offer a real one-byte buffer, capacity 0.
        var scratch = InlineArray[UInt8, 1](fill=UInt8(0))
        # SAFETY: `scratch` and `src` are alive across this synchronous call
        # (local stack / the Span's concrete origin); libz writes 0 bytes and
        # reads at most `n` from `src`.
        outcome = _zlib_inflate_once(
            scratch.unsafe_ptr(), 0, src.unsafe_ptr(), n, window_bits
        )
    else:
        # SAFETY: `dst` holds `len(dst) >= cap` writable bytes and `src` holds
        # `n` readable bytes, both kept alive by their Span origins for this
        # synchronous call; libz writes at most `cap` bytes, reads at most `n`,
        # and keeps neither pointer past `inflateEnd`.
        outcome = _zlib_inflate_once(
            dst.unsafe_ptr(), cap, src.unsafe_ptr(), n, window_bits
        )
    if outcome.written > cap:
        raise Error(
            "zlib_inflate_into: libz reported " + String(outcome.written)
            + " bytes written into a " + String(cap) + "-byte buffer"
        )
    if Int(outcome.rc) == Int(_Z_STREAM_END):
        return outcome.written
    if Int(outcome.rc) == Int(_Z_OK) or Int(outcome.rc) == Int(_Z_BUF_ERROR):
        # Input left unread means libz stopped for want of output space.
        if outcome.unread > 0 and outcome.unwritten == 0:
            raise Error(
                "zlib_inflate_into: the stream decodes to more than the "
                + String(len(dst)) + "-byte destination"
            )
        # Output full AND input used up: libz may have pulled the last input
        # bytes into its bit buffer before the output filled (raw deflate has
        # no trailer to leave unread), or the source may end right where the
        # output did (a missing trailer). Both stop libz in the same state.
        if outcome.unwritten == 0:
            raise Error(
                "zlib_inflate_into: the output filled the " + String(len(dst))
                + "-byte destination before the stream ended (it decodes to"
                " more than that, or the " + String(n)
                + "-byte source is truncated)"
            )
        raise Error(
            "zlib_inflate_into: truncated stream (the " + String(n)
            + "-byte source ends before the stream does)"
        )
    raise Error(
        "zlib_inflate_into: corrupt stream (libz inflate rc="
        + String(Int(outcome.rc)) + ", window_bits="
        + String(Int(window_bits)) + ")"
    )


def zlib_inflate_once[
    dori: MutOrigin
](
    dst: Span[UInt8, dori], src: Span[UInt8, _], window_bits: Int32
) raises -> ZlibInflateOutcome:
    """One `inflate(Z_NO_FLUSH)` call over all of `src` into `dst`, with what
    libz left behind handed back unjudged: its return code (`rc`, zlib.h:
    0 Z_OK, 1 Z_STREAM_END, -3 Z_DATA_ERROR, -5 Z_BUF_ERROR, ...), the bytes
    written, the input left unread and the output space left unwritten. For a
    caller whose policy on a full destination or a short source differs from
    `zlib_inflate_into`'s (a grow-and-retry loop). libz writes no byte past
    `len(dst)`; a destination past 4 GiB is offered as 4 GiB - 1 bytes (libz
    counts in 32 bits). Raises when `inflateInit2_` fails or `src` is past
    4 GiB.
    """
    var n = len(src)
    if n > _UINT_MAX:
        raise Error(
            "zlib_inflate_once: source of " + String(n)
            + " bytes exceeds libz's 32-bit length"
        )
    var cap = min(len(dst), _UINT_MAX)
    var src_scratch = InlineArray[UInt8, 1](fill=UInt8(0))
    var dst_scratch = InlineArray[UInt8, 1](fill=UInt8(0))
    if n == 0 and cap == 0:
        # SAFETY: both locals are alive across this synchronous call; libz
        # reads 0 bytes and writes 0 bytes.
        return _zlib_inflate_once(
            dst_scratch.unsafe_ptr(), 0, src_scratch.unsafe_ptr(), 0,
            window_bits,
        )
    if n == 0:
        # SAFETY: `dst` holds `cap` writable bytes (its Span origin keeps them
        # alive) and the local `src_scratch` stands in for the empty source;
        # libz reads 0 bytes and writes at most `cap`.
        return _zlib_inflate_once(
            dst.unsafe_ptr(), cap, src_scratch.unsafe_ptr(), 0, window_bits
        )
    if cap == 0:
        # SAFETY: libz refuses a null `next_out` even with `avail_out == 0`,
        # and an empty Span may carry one: the local `dst_scratch` stands in,
        # with capacity 0. `src` holds `n` readable bytes.
        return _zlib_inflate_once(
            dst_scratch.unsafe_ptr(), 0, src.unsafe_ptr(), n, window_bits
        )
    # SAFETY: `dst` holds `cap` writable bytes and `src` `n` readable bytes,
    # both kept alive by their Span origins for this synchronous call; libz
    # writes at most `cap`, reads at most `n`, and keeps neither pointer past
    # `inflateEnd`.
    return _zlib_inflate_once(
        dst.unsafe_ptr(), cap, src.unsafe_ptr(), n, window_bits
    )


def zlib_skip_stream(
    src: Span[UInt8, _], window_bits: Int32 = ZLIB_WINDOW_BITS_AUTO
) raises -> Int:
    """The number of bytes the stream at the start of `src` occupies (decoded
    and discarded, in constant memory). For walking concatenated streams that
    carry no length prefix: the next stream starts at the returned offset.
    Raises on an empty, truncated or corrupt stream."""
    var n = len(src)
    if n == 0:
        raise Error("zlib_skip_stream: empty source (no stream is empty)")
    if n > _UINT_MAX:
        raise Error(
            "zlib_skip_stream: source of " + String(n)
            + " bytes exceeds libz's 32-bit length"
        )
    # SAFETY: `src` holds `n` readable bytes, kept alive by its Span origin for
    # this synchronous call; libz reads at most `n` and keeps no pointer past
    # `inflateEnd`.
    var consumed = _zlib_skip_stream_ffi(src.unsafe_ptr(), n, window_bits)
    if consumed > n:
        raise Error(
            "zlib_skip_stream: libz reported " + String(consumed)
            + " bytes consumed from a " + String(n) + "-byte source"
        )
    return consumed


# libz's `crc32` takes a 32-bit `uInt` length: feed it at most 1 GiB per call,
# so a buffer larger than 4 GiB cannot wrap the length and yield a valid-looking
# but wrong checksum. CRC-32 is incremental, so chunking is exact.
comptime _CRC_CHUNK: Int = 1 << 30


def zlib_crc32(data: Span[UInt8, _], crc: UInt32 = 0) raises -> UInt32:
    """The CRC-32 of RFC 1952 (the gzip trailer's checksum) of `data`,
    continuing from `crc` (0 to start; pass a previous result to extend it over
    the next piece). libz's `crc32`."""
    var handle_ptr = _default_zlib_ffi_handle()
    var acc = UInt64(crc)
    var off = 0
    var n = len(data)
    while off < n:
        var take = min(_CRC_CHUNK, n - off)
        # SAFETY: `data` holds `n` readable bytes, alive across this
        # synchronous call through its Span origin; libz reads exactly `take`
        # bytes from `off` (in bounds: `off + take <= n`) and keeps no pointer.
        acc = handle_ptr[].call["crc32", UInt64](
            acc,
            (data.unsafe_ptr() + off)
            .unsafe_mut_cast[True]()
            .unsafe_origin_cast[MutUntrackedOrigin](),
            UInt32(take),
        )
        off += take
    return UInt32(acc & 0xFFFFFFFF)
