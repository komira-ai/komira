# =============================================================================
# komira_crypto/internal/asm/base64_ffi.mojo
# =============================================================================
#
# base64 encode/decode (standard + URL-safe + no-pad variants) via
# AWS-LC's EVP_EncodeBlock + EVP_DecodeBlock.
#
# Backs the base64 surface of base64.mojo.
#
# # Symbols used
#
#   * EVP_EncodeBlock(dst, src, src_len) -> Int  (returns bytes written)
#   * EVP_DecodeBlock(dst, src, src_len) -> Int  (returns bytes written, or -1 on error)
#
# # C signatures (from AWS-LC's include/openssl/base64.h)
#
#   int EVP_EncodeBlock(uint8_t *dst, const uint8_t *src, size_t src_len);
#   int EVP_DecodeBlock(uint8_t *dst, const uint8_t *src, size_t src_len);
#
# # URL-safe + no-pad handling
#
# AWS-LC's EVP_EncodeBlock/EVP_DecodeBlock only support the STANDARD
# alphabet (+/ for chars 62/63, with trailing = padding). URL-safe
# (-_ for chars 62/63) and no-pad variants are handled by thin Mojo
# pre/post-translation passes around the core FFI calls. This is the
# established RFC 7515 §2 / RFC 4648 §5 reference approach.
#
# # Encapsulation discipline
#
#   * ZERO UnsafePointer in public sigs (functions return String).
#   * Standard alphabet uses FFI; URL-safe routes through standard FFI
#     + Mojo translate-and-strip-padding pass (~30 LOC each direction).
#   * Encoder/decoder dst-size formulas per RFC 4648 §4: encoded len
#     = `4 * ceil(src_len / 3)`; decoded len = `3 * (src_len / 4) -
#     padding`.
# =============================================================================

from std.ffi import external_call
from std.memory import UnsafePointer


# -----------------------------------------------------------------------------
# The package's FFI origin (FFI-BOUNDARY).
#
# Mojo 1.0.0b2 removed the `UnsafePointer[T]()` null constructor and
# `Boolable`/`__bool__` (non-null-by-design; see
# the Mojo non-null-pointer proposal). A wildcard origin such as
# `MutExternalOrigin` is banned; this uses `StaticConstantOrigin`,
# a CONCRETE (non-wildcard) origin valid for the FFI ABI boundary whose
# lifetime is not expressible in Mojo's origin system. Opaque AWS-LC heap
# handles are passed BY VALUE to `external_call` and never written through
# Mojo-side, so an immutable static origin is sound. Data-buffer pointers
# (Span/InlineArray/scalar out-params) carry the same origin; the SAFETY
# contract is that the caller holds the buffer's real origin in scope across
# the synchronous external_call (AWS-LC retains no pointer past the call).
# -----------------------------------------------------------------------------
comptime _FFI_ORIGIN = ImmStaticOrigin
comptime _FfiHandle = UnsafePointer[NoneType, _FFI_ORIGIN]
comptime _FfiByte = UnsafePointer[UInt8, _FFI_ORIGIN]


@always_inline
def _ffi_null() -> _FfiHandle:
    """A raw NULL opaque-handle (stands in for the removed `UnsafePointer[T]()`
    null ctor) for pre-declared-then-reassigned handle locals and explicit
    C-NULL arguments.

    # SAFETY: `Optional[UnsafePointer[...]]` is layout-compatible with the
    # bare pointer (the Mojo non-null-pointer proposal), and `None`
    # is the all-zero (NULL) bit pattern. We reinterpret an `Optional`-None
    # slot to obtain a raw NULL handle WITHOUT the removed null ctor and
    # WITHOUT the banned `unsafe_from_address=Int(0)`. Downstream sites
    # detect NULL via `Int(h) == 0` and AWS-LC free fns are NULL-safe.
    """
    var none: Optional[_FfiHandle] = None
    return UnsafePointer(to=none).bitcast[_FfiHandle]()[]



@always_inline
def _span_ptr_mut(s: Span[UInt8, _]) -> _FfiByte:
    """Coerce a `Span[UInt8, _]` to an FFI byte pointer (_FFI_ORIGIN)."""
    return (
        s.unsafe_ptr()
        .unsafe_mut_cast[False]()
        .unsafe_origin_cast[_FFI_ORIGIN]()
    )


# -----------------------------------------------------------------------------
# Standard base64 encode (RFC 4648 §4) — padded with =
# -----------------------------------------------------------------------------


def _encode_bytes_std_ffi(data: Span[UInt8, _]) -> List[UInt8]:
    """Standard base64 encode (raw byte form) via AWS-LC's EVP_EncodeBlock.

    Returns the encoded bytes as List[UInt8] (callers route through a
    chr-append loop for String construction; Mojo 1.0.0b1 has no
    String(bytes=...) ctor).
    """
    if len(data) == 0:
        return List[UInt8]()

    # Encoded length: 4 * ceil(src_len / 3) base64 chars. EVP_EncodeBlock
    # ALSO writes a TRAILING NUL past those chars (AWS-LC base64.h:
    # "writes the result to |dst| with a trailing NUL"; its return value
    # is the char count WITHOUT the NUL). The dst buffer MUST therefore be
    # sized out_len + 1 — sizing it to out_len overflows the List by 1
    # byte on EVERY encode, clobbering the adjacent allocator freelist
    # node in that size class — small encodes (e.g. a 24-byte SCRAM nonce
    # or 32-byte proof) then poison the small-String size classes, and a
    # later String build pops the poisoned node and crashes). We allocate the
    # NUL slot, write into it, then surface only the first out_len bytes.
    var out_len = 4 * ((len(data) + 2) // 3)
    var buf_cap = out_len + 1  # +1 for EVP_EncodeBlock's trailing NUL
    var buf = List[UInt8](capacity=buf_cap)
    for _ in range(buf_cap):
        buf.append(0)

    # SAFETY: EVP_EncodeBlock writes exactly out_len base64 chars PLUS a
    # trailing NUL (out_len + 1 == buf_cap bytes total) to dst_ptr. Reads
    # src_len bytes from src_ptr. Both buffers caller-owned for the
    # synchronous call; the dst is sized to hold the NUL.
    var dst_ptr = (
        buf.unsafe_ptr()
        .unsafe_mut_cast[False]()
        .unsafe_origin_cast[_FFI_ORIGIN]()
    )
    var src_ptr = _span_ptr_mut(data)
    var written = external_call[
        "EVP_EncodeBlock",
        Int,
        _FfiByte,  # dst
        _FfiByte,  # src
        UInt,                                       # src_len
    ](dst_ptr, src_ptr, UInt(len(data)))
    debug_assert(written == out_len, "EVP_EncodeBlock: written != expected")

    # Surface only the out_len base64 chars (drop EVP_EncodeBlock's trailing
    # NUL at index out_len). Build a fresh exact-length List rather than
    # shrinking `buf` in place — mirrors the decode path's truncation idiom.
    var result = List[UInt8](capacity=out_len)
    for i in range(out_len):
        result.append(buf[i])
    return result^


@always_inline
def _bytes_to_string(b: List[UInt8]) -> String:
    """Convert ASCII-guaranteed byte sequence to String via chr-append."""
    var out = String()
    for i in range(len(b)):
        out += chr(Int(b[i]))
    return out^


def base64_encode_std_ffi(data: Span[UInt8, _]) -> String:
    """Standard base64 encode via AWS-LC's EVP_EncodeBlock.

    Output uses the standard alphabet `+/` for chars 62/63 and `=` padding.
    """
    return _bytes_to_string(_encode_bytes_std_ffi(data))


def base64_encode_url_ffi(data: Span[UInt8, _], padded: Bool) -> String:
    """URL-safe base64 encode (RFC 4648 §5).

    `padded=True`: keep trailing `=` padding (rare; canonical form is
    no-pad per RFC 7515).
    `padded=False`: strip trailing `=` padding (the canonical JWT
    base64url form).

    Implementation: call standard base64 (EVP_EncodeBlock), then
    translate `+/` -> `-_` and optionally strip trailing `=`.
    """
    var b = _encode_bytes_std_ffi(data)
    # Translate alphabet 62/63 in place.
    var out = List[UInt8](capacity=len(b))
    for i in range(len(b)):
        var c = b[i]
        if c == UInt8(ord("+")):
            out.append(UInt8(ord("-")))
        elif c == UInt8(ord("/")):
            out.append(UInt8(ord("_")))
        else:
            out.append(c)
    # Optionally strip trailing `=` padding.
    if not padded:
        var n = len(out)
        while n > 0 and out[n - 1] == UInt8(ord("=")):
            n -= 1
        if n < len(out):
            var truncated = List[UInt8](capacity=n)
            for i in range(n):
                truncated.append(out[i])
            return _bytes_to_string(truncated^)
    return _bytes_to_string(out^)


# -----------------------------------------------------------------------------
# Standard base64 decode — uses standard alphabet only, padded input.
# -----------------------------------------------------------------------------


def _decode_bytes_std_ffi(src_bytes: Span[UInt8, _]) raises -> List[UInt8]:
    """Standard base64 decode (raw byte input form) via AWS-LC.

    Internal helper; takes a Span[UInt8, _] so callers (URL-safe variant)
    don't have to round-trip through String.
    """
    if len(src_bytes) == 0:
        return List[UInt8]()
    if len(src_bytes) % 4 != 0:
        raise Error("base64_decode_std_ffi: input length not a multiple of 4")

    # Validate the standard-alphabet BEFORE calling EVP_DecodeBlock. AWS-LC's
    # EVP_DecodeBlock is LENIENT — on an invalid char it does NOT reliably
    # return -1, and can return a `written` larger than the 3*(n/4) buffer
    # holds, which would index past `dst` below (an out-of-bounds read /
    # heap-safety hazard). A strict alphabet pre-check makes bad input raise
    # cleanly (RFC 4648 §3.3 "reject") and guarantees `written <= max_out`.
    var nbytes = len(src_bytes)
    var seen_pad = False
    for i in range(nbytes):
        var c = src_bytes[i]
        var is_alpha = (
            (c >= UInt8(ord("A")) and c <= UInt8(ord("Z")))
            or (c >= UInt8(ord("a")) and c <= UInt8(ord("z")))
            or (c >= UInt8(ord("0")) and c <= UInt8(ord("9")))
            or c == UInt8(ord("+"))
            or c == UInt8(ord("/"))
        )
        if c == UInt8(ord("=")):
            # Padding only valid in the final 1-2 positions.
            if i < nbytes - 2:
                raise Error("base64_decode_std_ffi: misplaced '=' padding")
            seen_pad = True
        elif is_alpha:
            if seen_pad:
                raise Error("base64_decode_std_ffi: data after '=' padding")
        else:
            raise Error("base64_decode_std_ffi: invalid base64 character")

    # Allocate dst with max-possible output size: 3 * (src_len / 4).
    # EVP_DecodeBlock writes 3 bytes per 4-char input block; padding is
    # handled by post-pass length adjustment.
    var max_out = 3 * (len(src_bytes) // 4)
    var dst = List[UInt8](capacity=max_out)
    for _ in range(max_out):
        dst.append(0)

    # SAFETY: EVP_DecodeBlock writes up to max_out bytes to dst_ptr;
    # reads src_len bytes from src_ptr. Returns bytes written on
    # success, -1 on bad alphabet. Both buffers caller-owned.
    var dst_ptr = (
        dst.unsafe_ptr()
        .unsafe_mut_cast[False]()
        .unsafe_origin_cast[_FFI_ORIGIN]()
    )
    var src_ptr = _span_ptr_mut(src_bytes)
    var written = external_call[
        "EVP_DecodeBlock",
        Int,
        _FfiByte,
        _FfiByte,
        UInt,
    ](dst_ptr, src_ptr, UInt(len(src_bytes)))
    if written < 0:
        raise Error("base64_decode_std_ffi: EVP_DecodeBlock failed (bad alphabet)")

    # EVP_DecodeBlock returns the FULL block-aligned length without
    # accounting for trailing `=` padding. Adjust by counting padding
    # chars in the input and subtracting.
    var pad = 0
    var n = len(src_bytes)
    if n >= 1 and src_bytes[n - 1] == UInt8(ord("=")):
        pad += 1
    if n >= 2 and src_bytes[n - 2] == UInt8(ord("=")):
        pad += 1
    var actual = Int(written) - pad
    # Defensive clamp: `actual` can never legitimately exceed max_out (the
    # allocated dst length). Clamp so a surprising `written` cannot index
    # past `dst` (heap-safety belt-and-suspenders alongside the alphabet
    # pre-check above).
    if actual < 0:
        actual = 0
    elif actual > max_out:
        actual = max_out

    # Truncate dst to actual length.
    var result = List[UInt8](capacity=actual)
    for i in range(actual):
        result.append(dst[i])
    return result^


def base64_decode_std_ffi(s: String) raises -> List[UInt8]:
    """Standard base64 decode via AWS-LC's EVP_DecodeBlock.

    Input MUST be padded to a multiple of 4 with `=` characters per
    RFC 4648 §4.
    """
    return _decode_bytes_std_ffi(s.as_bytes())


def base64_decode_url_ffi(s: String) raises -> List[UInt8]:
    """URL-safe base64 decode (RFC 4648 §5 + RFC 7515 §2).

    Accepts both padded and no-pad input. Translates `-_` to `+/`,
    re-pads to a multiple of 4 with `=`, then routes through
    the byte-level decoder.
    """
    var src_bytes = s.as_bytes()
    if len(src_bytes) == 0:
        return List[UInt8]()

    # Translate URL alphabet -> standard alphabet.
    var translated = List[UInt8](capacity=len(src_bytes) + 4)
    for i in range(len(src_bytes)):
        var c = src_bytes[i]
        if c == UInt8(ord("-")):
            translated.append(UInt8(ord("+")))
        elif c == UInt8(ord("_")):
            translated.append(UInt8(ord("/")))
        else:
            translated.append(c)

    # Re-pad to a multiple of 4 with `=`.
    var pad_needed = (4 - (len(translated) % 4)) % 4
    if pad_needed == 3:
        # RFC 4648: input length must be 2, 3, or 0 (mod 4); length-1
        # (mod 4) is not a valid base64 length.
        raise Error("base64_decode_url_ffi: invalid input length (mod 4 == 1)")
    for _ in range(pad_needed):
        translated.append(UInt8(ord("=")))

    # Now route through byte-level decoder.
    return _decode_bytes_std_ffi(Span[UInt8](translated))
