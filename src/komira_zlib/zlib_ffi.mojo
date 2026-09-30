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
# Stateful three-call FFI — libz's deflate API requires explicit
# `deflateInit2_` (with version+sizeof handshake) → `deflate(Z_FINISH)` →
# `deflateEnd` lifecycle. This wrapper hides the lifecycle inside a single
# function that allocates a 112-byte z_stream scratch buffer, sets the
# four I/O fields at known offsets, drives the three libz calls, reads
# total_out, and returns.
#
#   fn zlib_deflate_ffi(
#       dst: UnsafePointer[UInt8, dori],
#       dst_capacity: Int,
#       src: UnsafePointer[UInt8, sori],
#       src_size: Int,
#       level: Int32,         # 1..9 (0 = stored blocks via Z_STORED_STRATEGY)
#       window_bits: Int32,   # -15 = raw deflate / 15 = zlib / 31 = gzip
#   ) raises -> Int
#
#   fn zlib_compress_bound_ffi(src_size: Int, window_bits: Int32) raises -> Int
#
# The `window_bits` parameter selects framing per libz convention:
#   * windowBits = 15 (max)        : zlib wrapper (RFC 1950 — Adler-32 trailer)
#   * windowBits = -15 (negative)  : raw deflate (RFC 1951 — no header/trailer)
#   * windowBits = 15 + 16 = 31    : gzip wrapper (RFC 1952 — CRC-32 trailer)
#
# # OwnedDLHandle singleton (process-lifetime, ~220us first-call cost)
#
# Process-lifetime libz handle via the stdlib `_Global` runtime slot (dlopen
# once, init-once, cross-compile-unit-coherent). No env var and no
# `unsafe_from_address`.
#
# # Encapsulation discipline
#
# Public API:
#   * `zlib_deflate_ffi` accepts UnsafePointer with CALLER-CHOSEN origins
#     (Origin / MutOrigin generic params), NOT wildcards, so callers can pass
#     their own buffers without signature changes.
# Internal FFI:
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

# `zlib_skip_stream_ffi` scratch: output is discarded, so this is a pure
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
# Public FFI wrappers — one-shot calls a codec can delegate to directly.
# -----------------------------------------------------------------------------


def zlib_deflate_ffi[
    sori: Origin, dori: MutOrigin
](
    dst: UnsafePointer[UInt8, dori],
    dst_capacity: Int,
    src: UnsafePointer[UInt8, sori],
    src_size: Int,
    level: Int32,
    window_bits: Int32,
) raises -> Int:
    """One-shot deflate via libz's `deflateInit2_` / `deflate(Z_FINISH)` /
    `deflateEnd`. Returns total bytes written to dst.

    `window_bits` selects framing per zlib.h convention:
        15 (max)       : zlib wrapper (RFC 1950 — Adler-32 trailer)
       -15 (negative)  : raw deflate (RFC 1951 — no header/trailer)
       15 + 16 = 31    : gzip wrapper (RFC 1952 — CRC-32 trailer)

    `window_bits` is the framing selector a codec maps from its own
    container choice.

    SAFETY: libz's `deflate(Z_FINISH)` reads exactly `src_size` bytes from
    `src` and writes up to `dst_capacity` bytes to `dst`. Both buffers are
    caller-owned for the duration of this synchronous call; libz retains no
    pointer past the call (Z_FINISH drives the algorithm to completion in
    one call, then deflateEnd releases the internal state). The handle is a
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
    _z_stream_set_in_out(
        strm,
        src.unsafe_mut_cast[True]().unsafe_origin_cast[MutUntrackedOrigin](),
        src_size,
        dst.unsafe_origin_cast[MutUntrackedOrigin](),
        dst_capacity,
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

    # deflate(z, Z_FINISH) drives to completion in one call.
    var rc = handle_ptr[].call["deflate", Int32](strm, _Z_FINISH)
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


def zlib_compress_bound_ffi(src_size: Int, window_bits: Int32) raises -> Int:
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


def zlib_inflate_ffi[
    sori: Origin, dori: MutOrigin
](
    dst: UnsafePointer[UInt8, dori],
    dst_capacity: Int,
    src: UnsafePointer[UInt8, sori],
    src_size: Int,
    window_bits: Int32 = _WBITS_AUTO,
) raises -> Int:
    """One-shot inflate via libz's `inflateInit2_` / `inflate(Z_NO_FLUSH)` /
    `inflateEnd`. Returns total bytes written to dst.

    `window_bits` defaults to `15 + 32` which gives libz auto-detection
    of gzip / zlib / raw-deflate framing — load-bearing for Parquet
    interop where parquet-mr, DuckDB, pyarrow, and Spark all disagree on
    which framing they emit for the "GZIP" codec id.

    Explicit values:
        15 (max)       : zlib wrapper only (RFC 1950 — Adler-32 trailer)
       -15 (negative)  : raw deflate only (RFC 1951 — no header/trailer)
       15 + 16 = 31    : gzip wrapper only (RFC 1952 — CRC-32 trailer)
       15 + 32 = 47    : zlib + gzip auto-detect (default; what callers want)

    SAFETY: libz's `inflate(Z_NO_FLUSH)` reads up to `src_size` bytes from
    `src` and writes up to `dst_capacity` bytes to `dst`. Both buffers are
    caller-owned for the synchronous call; libz retains no pointer past
    the call (Z_NO_FLUSH followed by inflateEnd drives one-shot decode to
    completion). The handle is a process-lifetime singleton (never freed).
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
    var _end_rc = handle_ptr[].call["inflateEnd", Int32](strm)
    strm.free()

    # inflate may return Z_OK (more input needed) OR Z_STREAM_END (done).
    # For one-shot Parquet pages we expect Z_STREAM_END; Z_OK with non-zero
    # written is also acceptable (caller passed enough data) but every
    # other rc is an error.
    if Int(rc) != Int(_Z_OK) and Int(rc) != Int(_Z_STREAM_END):
        raise Error(
            "libz inflate failed (rc=" + String(Int(rc))
            + ", input_len=" + String(src_size)
            + ", output_cap=" + String(dst_capacity)
            + ", window_bits=" + String(Int(window_bits)) + ")"
        )
    return written


# -----------------------------------------------------------------------------
# zlib_skip_stream_ffi — how many INPUT bytes does one deflate stream occupy?
# -----------------------------------------------------------------------------


def zlib_skip_stream_ffi[
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
    `zlib_inflate_ffi` cannot serve this role: it is one-shot and needs a `dst`
    at least as large as the decompressed payload, which on a push path is the
    exact resident-memory cost the scan exists to avoid.

    Returns `total_in` at Z_STREAM_END. Raises if the stream is truncated
    (input exhausted before Z_STREAM_END) or corrupt.

    SAFETY: `src` is caller-owned for the synchronous call; `scratch` is a local
    allocation freed before every return path. libz retains no pointer past
    `inflateEnd`. Origins are cast to an untracked origin only at the call site —
    the same pattern as `zlib_inflate_ffi` above.
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
