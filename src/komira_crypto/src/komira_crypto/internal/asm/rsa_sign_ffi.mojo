# =============================================================================
# komira_crypto/internal/asm/rsa_sign_ffi.mojo
# =============================================================================
#
# RSA-SHA256 signing (PKCS#1 v1.5) via AWS-LC's EVP_DigestSign API.
#
# Backs `rsa_sha256_sign` in rsa.mojo; e.g. a GCS OAuth2 service-account
# JWT is signed through it.
#
# # Symbols used
#
#   * CBS_init / EVP_parse_private_key(cbs) -> EVP_PKEY* (any PKCS#8 type)
#   * EVP_PKEY_id(pkey) -> int (refuses a key that is not EVP_PKEY_RSA)
#   * EVP_PKEY_free(pkey)
#   * EVP_MD_CTX_new / EVP_MD_CTX_free (reused from sha256_ffi shape)
#   * EVP_DigestSignInit(ctx, pctx, type, engine, pkey) -> int
#   * EVP_DigestSign(ctx, sig, &sig_len, data, data_len) -> int (one-shot)
#   * EVP_sha256 (reused from sha256_ffi)
#
# # PKCS#8 DER input
#
# GCS service-account private keys are PKCS#8 DER (typically PEM-encoded
# in the JSON service-account file; the caller is expected to PEM-decode
# before passing to this function). EVP_parse_private_key parses a PKCS#8
# PrivateKeyInfo of any key type, so the key type is checked after the
# parse: a key that is not RSA is refused.
#
# # Encapsulation discipline
#
#   * ZERO UnsafePointer in public sigs (function returns List[UInt8]).
#   * Opaque AWS-LC handles (EVP_PKEY*, EVP_MD_CTX*) held via
#     _FfiHandle — FFI-OPAQUE-HANDLE
#     carve-out (precedent: rsa_ffi.mojo, p256_ffi.mojo).
#   * Manual try-style cleanup via if-not-null free at the end (no
#     try/finally in Mojo; equivalent shape via guarded free).
# =============================================================================

from std.ffi import external_call
from std.memory import UnsafePointer

from komira_crypto.internal.asm.sha256_ffi import _evp_sha256


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


# AWS-LC's EVP_PKEY_RSA constant (matches OpenSSL).
comptime EVP_PKEY_RSA: Int = 6


# -----------------------------------------------------------------------------
# rsa_sha256_sign_ffi — RSA-SHA256 PKCS#1 v1.5 sign via AWS-LC.
#
# Input: PKCS#8 DER private key bytes + message bytes.
# Output: RSA signature bytes (signature length == RSA modulus length;
#         256 bytes for RSA-2048, 384 for RSA-3072, 512 for RSA-4096).
# -----------------------------------------------------------------------------


def rsa_sha256_sign_ffi(
    pkcs8_der_key: Span[UInt8, _], message: Span[UInt8, _]
) raises -> List[UInt8]:
    """RSA-SHA256 sign `message` with a PKCS#8-DER private key.

    Implements GCP OAuth2 JWT signing per RFC 7519. The signing-input
    is the dot-separated `base64url(header).base64url(claims)` blob;
    the output signature is appended as base64url to form the final JWT.

    Internally:
      1. Parse PKCS#8 DER -> EVP_PKEY via EVP_parse_private_key, then
         refuse the key unless EVP_PKEY_id says it is EVP_PKEY_RSA.
      2. EVP_DigestSignInit with EVP_sha256() and the parsed EVP_PKEY
         (defaults to PKCS#1 v1.5 padding for RSA, which matches GCP's
         RS256 algorithm per RFC 7518 §3.3).
      3. EVP_DigestSign (one-shot) to produce the signature.
      4. Free EVP_MD_CTX + EVP_PKEY.

    Raises on parse failure, on a key that is not RSA (EC, Ed25519,
    RSA-PSS), on sign failure, or on OOM.
    """
    var pkey: _FfiHandle
    var ctx: _FfiHandle
    var success = False
    var result = List[UInt8]()

    # Step 1: parse the DER private key into EVP_PKEY via AWS-LC's robust
    # `EVP_parse_private_key(CBS*)`.
    #
    # WHY NOT d2i_PrivateKey(EVP_PKEY_RSA, ...): AWS-LC's OpenSSL-compat
    # `d2i_PrivateKey` with an explicit `type=EVP_PKEY_RSA` routes to the legacy
    # `old_priv_decode` -> `RSA_parse_private_key`, which expects a bare PKCS#1
    # `RSAPrivateKey` and is NOT fail-closed on a PKCS#8 `PrivateKeyInfo`
    # wrapper — it SIGSEGVs in `CBS_get_asn1` on a wrong-form (or even a valid
    # PKCS#1) DER under v1.39.0. The canonical AWS-LC API is
    # `EVP_parse_private_key`, which parses a PKCS#8 `PrivateKeyInfo` DER for
    # ANY key type (RSA / EC / Ed25519) and returns NULL (no crash) on failure.
    # This is the form GCS service-account keys arrive in (PEM-decoded PKCS#8)
    # AND the form a DKIM signer's stored key arrives in; both parse here.
    #
    # CBS is `struct { const uint8_t *data; size_t len; }` (16 bytes on 64-bit).
    # We model it as a 2-slot UInt array (ptr-as-uint, len) and initialize it via
    # `CBS_init(CBS*, const uint8_t*, size_t)`.
    #
    # SAFETY: CBS_init stores the (data, len) pair into the stack `cbs` struct;
    # EVP_parse_private_key reads up to `len` bytes from `data`. On success
    # returns EVP_PKEY* (we own + must free); on any malformed-DER failure
    # returns NULL. The `pkcs8_der_key` span stays alive across the call (it is a
    # borrowed argument of this function).
    var key_data_ptr = _span_ptr_mut(pkcs8_der_key)
    var cbs = Array[UInt, 2](fill=UInt(0))
    var cbs_ptr = UnsafePointer(to=cbs).unsafe_mut_cast[False]().unsafe_origin_cast[
        _FFI_ORIGIN
    ]().bitcast[NoneType]()
    external_call[
        "komira_awslc_CBS_init",
        NoneType,
        _FfiHandle,  # CBS*
        _FfiByte,     # const uint8_t* data
        UInt,                                         # size_t len
    ](cbs_ptr, key_data_ptr, UInt(len(pkcs8_der_key)))
    pkey = external_call[
        "komira_awslc_EVP_parse_private_key",
        _FfiHandle,
        _FfiHandle,  # CBS*
    ](cbs_ptr)
    if Int(pkey) == 0:
        raise Error(
            "rsa_sha256_sign_ffi: EVP_parse_private_key failed (bad DER key)"
        )
    # EVP_parse_private_key accepts any PKCS#8 key type; EVP_DigestSign would
    # then make an ECDSA signature with an EC key. Refuse anything not RSA.
    # SAFETY: EVP_PKEY_id reads the type of the EVP_PKEY parsed above, which
    # we own until the EVP_PKEY_free below; it retains nothing.
    var key_type = external_call[
        "komira_awslc_EVP_PKEY_id", Int32, _FfiHandle
    ](pkey)
    if Int(key_type) != EVP_PKEY_RSA:
        external_call[
            "komira_awslc_EVP_PKEY_free",
            NoneType,
            _FfiHandle,
        ](pkey)
        raise Error("rsa_sha256_sign_ffi: the key is not an RSA key")

    # Step 2: allocate EVP_MD_CTX + EVP_DigestSignInit.
    # SAFETY: EVP_MD_CTX_new allocates heap; we own + must free.
    ctx = external_call[
        "komira_awslc_EVP_MD_CTX_new", _FfiHandle
    ]()
    if Int(ctx) == 0:
        # Free pkey before raising.
        external_call[
            "komira_awslc_EVP_PKEY_free",
            NoneType,
            _FfiHandle,
        ](pkey)  # cov: unreachable an allocation failure
        raise Error("rsa_sha256_sign_ffi: EVP_MD_CTX_new returned NULL (OOM)")  # cov: unreachable see the line above

    # SAFETY: EVP_DigestSignInit configures ctx for RSA-SHA256 signing.
    # pctx (out arg for EVP_PKEY_CTX*) = NULL (we don't need it).
    # engine = NULL.
    var md = _evp_sha256()
    var rc_init = external_call[
        "komira_awslc_EVP_DigestSignInit",
        Int,
        _FfiHandle,  # ctx
        _FfiHandle,  # pctx (out)
        _FfiHandle,  # type
        _FfiHandle,  # engine
        _FfiHandle,  # pkey
    ](
        ctx,
        _ffi_null(),
        md,
        _ffi_null(),
        pkey,
    )
    if rc_init != 1:
        # Free both before raising.
        external_call[
            "komira_awslc_EVP_MD_CTX_free",
            NoneType,
            _FfiHandle,
        ](ctx)  # cov: unreachable an allocation failure: the key is RSA (checked above) and SHA-256 is an RSA digest
        external_call[
            "komira_awslc_EVP_PKEY_free",
            NoneType,
            _FfiHandle,
        ](pkey)  # cov: unreachable see the line above
        raise Error("rsa_sha256_sign_ffi: EVP_DigestSignInit failed")  # cov: unreachable see the line above

    # Step 3: one-shot EVP_DigestSign.
    # First call with sig=NULL: returns required sig buffer size.
    # Second call with allocated buf: emits the signature.
    var sig_len = UInt(0)
    var msg_ptr = _span_ptr_mut(message)
    # SAFETY: EVP_DigestSign with sig=NULL writes the required buffer
    # size to *sig_len.
    var rc_size = external_call[
        "komira_awslc_EVP_DigestSign",
        Int,
        _FfiHandle,  # ctx
        _FfiByte,     # sig (NULL → size query)
        UnsafePointer[UInt, _FFI_ORIGIN],      # sig_len (in/out)
        _FfiByte,     # data
        UInt,                                         # data_len
    ](
        ctx,
        _ffi_null().bitcast[UInt8](),  # sig = NULL (size query)
        UnsafePointer(to=sig_len).unsafe_mut_cast[False]().unsafe_origin_cast[_FFI_ORIGIN](),
        msg_ptr,
        UInt(len(message)),
    )
    if rc_size != 1:
        external_call[
            "komira_awslc_EVP_MD_CTX_free",
            NoneType,
            _FfiHandle,
        ](ctx)  # cov: unreachable a NULL-buffer EVP_DigestSign only reports the maximum signature size; it fails for no key EVP_DigestSignInit accepted
        external_call[
            "komira_awslc_EVP_PKEY_free",
            NoneType,
            _FfiHandle,
        ](pkey)  # cov: unreachable see the line above
        raise Error("rsa_sha256_sign_ffi: EVP_DigestSign size-query failed")  # cov: unreachable see the line above

    # Allocate signature buffer + emit.
    var sig_buf = List[UInt8](capacity=Int(sig_len))
    for _ in range(Int(sig_len)):
        sig_buf.append(0)
    var sig_ptr = (
        sig_buf.unsafe_ptr()
        .unsafe_mut_cast[False]()
        .unsafe_origin_cast[_FFI_ORIGIN]()
    )
    # SAFETY: EVP_DigestSign writes sig_len bytes to sig_ptr, may write
    # back a smaller actual length to *sig_len if the signature is
    # shorter than the buffer (rare for RSA — sig is always == modulus
    # length).
    var rc_sign = external_call[
        "komira_awslc_EVP_DigestSign",
        Int,
        _FfiHandle,
        _FfiByte,
        UnsafePointer[UInt, _FFI_ORIGIN],
        _FfiByte,
        UInt,
    ](
        ctx,
        sig_ptr,
        UnsafePointer(to=sig_len).unsafe_mut_cast[False]().unsafe_origin_cast[_FFI_ORIGIN](),
        msg_ptr,
        UInt(len(message)),
    )
    if rc_sign == 1:
        # Truncate to actual length.
        var actual = Int(sig_len)
        for i in range(actual):
            result.append(sig_buf[i])
        success = True

    # Cleanup (always).
    external_call[
        "komira_awslc_EVP_MD_CTX_free",
        NoneType,
        _FfiHandle,
    ](ctx)
    external_call[
        "komira_awslc_EVP_PKEY_free",
        NoneType,
        _FfiHandle,
    ](pkey)

    if not success:
        raise Error("rsa_sha256_sign_ffi: EVP_DigestSign final emit failed")

    return result^
