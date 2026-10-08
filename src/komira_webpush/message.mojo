# =============================================================================
# komira_webpush/message.mojo: Web Push message encryption (RFC 8291)
# =============================================================================
#
# An application server encrypts a push message for one subscription, which
# carries the user agent's P-256 public key (`ua_public`, 65-byte
# uncompressed point) and a 16-byte authentication secret:
#
#   ecdh_secret = ECDH(as_private, ua_public)
#   key_info    = "WebPush: info" || 0x00 || ua_public || as_public
#   IKM         = HKDF(salt=auth_secret, IKM=ecdh_secret, info=key_info, 32)
#
# and then writes an RFC 8188 aes128gcm body with that IKM: a fresh random
# 16-byte salt, rs 4096, keyid = as_public (65 bytes), one record with no
# padding. `as_private` is a fresh P-256 key for every message.
#
# The salt and the sender key come from a `WebPushRandomness`; the plain
# `webpush_encrypt` uses `SystemWebPushRandomness` (the system CSPRNG).
# `webpush_encrypt_with` takes any conformer, which is how a test feeds the
# RFC 8291 example its fixed salt and sender key.
#
# `webpush_decrypt` is the user agent's side: it accepts only a body with a
# 65-byte keyid and exactly one record (RFC 8291 section 4).
#
# The sender private key, the ECDH secret, the PRK and the IKM this file
# holds are overwritten with zeros after their last use and before any
# raise that follows their creation. No test observes the wipe.
# =============================================================================

from komira_crypto import (
    Hkdf,
    Sha256,
    p256_ecdh,
    system_entropy,
    zeroize_inline_array,
)
from komira_crypto.ecdsa_p256 import ecdsa_p256_generate_pubkey

from .content_coding import (
    HEADER_FIXED_SIZE,
    TAG_SIZE,
    aes128gcm_decrypt,
    aes128gcm_encrypt,
    aes128gcm_parse_header,
)


comptime PUBLIC_KEY_SIZE: Int = 65
"""An uncompressed P-256 point, 0x04 || x || y."""
comptime AUTH_SECRET_SIZE: Int = 16
"""The subscription's authentication secret (RFC 8291 section 3.2)."""
comptime RECORD_SIZE: Int = 4096
"""The rs every message is written with."""
comptime MAX_BODY_SIZE: Int = 4096
"""The payload a push service must accept (RFC 8030 section 7.2)."""
comptime MAX_PLAINTEXT_SIZE: Int = (
    MAX_BODY_SIZE - HEADER_FIXED_SIZE - PUBLIC_KEY_SIZE - 1 - TAG_SIZE
)
"""3993: a 4096-byte body less the 86-byte header, the delimiter and the tag."""


trait WebPushRandomness:
    """Where `webpush_encrypt_with` gets each message's salt and sender key.
    A conformer must return a new value on every call; a repeated salt or
    sender key is a broken encryption."""

    def salt(mut self) raises -> Array[UInt8, 16]:
        """A 16-byte salt never used before."""
        ...

    def sender_private_key(mut self) raises -> Array[UInt8, 32]:
        """A P-256 private scalar in [1, n-1], big-endian, never used
        before."""
        ...


struct SystemWebPushRandomness(WebPushRandomness):
    """The system CSPRNG (`komira_crypto.system_entropy`)."""

    def __init__(out self):
        pass

    def salt(mut self) raises -> Array[UInt8, 16]:
        var s = Array[UInt8, 16](fill=UInt8(0))
        system_entropy(Span[UInt8](s))
        return s^

    def sender_private_key(mut self) raises -> Array[UInt8, 32]:
        var source = _SystemScalarSource()
        return _draw_private_key(source)


trait _ScalarSource:
    """Where `_draw_private_key` gets its candidate scalars."""

    def fill(mut self, mut k: Array[UInt8, 32]) raises:
        """Overwrites all 32 bytes of `k` with a fresh candidate."""
        ...


struct _SystemScalarSource(_ScalarSource):
    """Candidates from the system CSPRNG."""

    def __init__(out self):
        pass

    def fill(mut self, mut k: Array[UInt8, 32]) raises:
        # AWS-LC's RAND_bytes returns 1 or aborts the process, so
        # system_entropy does not raise and `k` holds no partial draw.
        system_entropy(Span[UInt8](k))


def _draw_private_key[S: _ScalarSource](mut source: S) raises -> Array[UInt8, 32]:
    """The first of up to 8 candidates from `source` that lies in [1, n-1].

    A random 32-byte string is >= n with probability below 2^-32, so the
    system source almost never needs a second draw. A refused candidate is
    wiped before the next draw.

    Raises:
        "webpush: no valid P-256 private key in 8 draws"
    """
    var k = Array[UInt8, 32](fill=UInt8(0))
    for _ in range(8):
        source.fill(k)
        if _scalar_in_range(Span[UInt8](k)):
            return k^
        zeroize_inline_array(k)
    raise Error("webpush: no valid P-256 private key in 8 draws")


def _p256_order() -> Array[UInt8, 32]:
    """The P-256 group order n, 32 big-endian bytes (FIPS 186-4 D.1.2.3)."""
    var words: List[UInt32] = [
        0xFFFFFFFF, 0x00000000, 0xFFFFFFFF, 0xFFFFFFFF,
        0xBCE6FAAD, 0xA7179E84, 0xF3B9CAC2, 0xFC632551,
    ]
    var n = Array[UInt8, 32](fill=UInt8(0))
    for w in range(8):
        for b in range(4):
            n[4 * w + b] = UInt8((words[w] >> UInt32(24 - 8 * b)) & 0xFF)
    return n^


def _scalar_in_range(k: Span[UInt8, _]) -> Bool:
    """Whether a 32-byte big-endian scalar lies in [1, n-1]. No branch
    depends on the scalar's bytes."""
    var n = _p256_order()
    var borrow = 0
    var any_bits = 0
    for j in range(32):
        var i = 31 - j
        var diff = Int(k[i]) - Int(n[i]) - borrow
        borrow = (diff >> 8) & 1
        any_bits = any_bits | Int(k[i])
    # k - n borrows out of the top byte exactly when k < n.
    return borrow == 1 and any_bits != 0


def p256_public_key(private_key: Span[UInt8, _]) raises -> Array[UInt8, 65]:
    """The uncompressed public point 0x04 || x || y of a P-256 private key.

    Raises:
        "webpush: private key must be 32 bytes, got <n>"
        "webpush: private key is not in [1, n-1]"
        "webpush: P-256 public key derivation failed"
    """
    if len(private_key) != 32:
        raise Error(
            "webpush: private key must be 32 bytes, got "
            + String(len(private_key))
        )
    if not _scalar_in_range(private_key):
        raise Error("webpush: private key is not in [1, n-1]")
    return _uncompressed_point(ecdsa_p256_generate_pubkey(private_key))


def _uncompressed_point(xy: Array[UInt8, 64]) raises -> Array[UInt8, 65]:
    """0x04 || x || y from the x || y `ecdsa_p256_generate_pubkey` returns.

    That function returns all zeros when AWS-LC fails, which for a scalar
    in [1, n-1] means an allocation failed; (0, 0) is not a point of P-256
    (it would need b = 0), so a derived key is never all zeros.

    Raises:
        "webpush: P-256 public key derivation failed"
    """
    var any_bits = UInt8(0)
    for i in range(64):
        any_bits = any_bits | xy[i]
    if any_bits == UInt8(0):
        raise Error("webpush: P-256 public key derivation failed")
    var out = Array[UInt8, 65](fill=UInt8(0))
    out[0] = UInt8(0x04)
    for i in range(64):
        out[1 + i] = xy[i]
    return out^


def webpush_ikm(
    ecdh_secret: Span[UInt8, _],
    auth_secret: Span[UInt8, _],
    ua_public: Span[UInt8, _],
    as_public: Span[UInt8, _],
) raises -> Array[UInt8, 32]:
    """RFC 8291 section 3.3: the IKM of the aes128gcm content coding.

    Raises:
        "webpush: auth secret must be 16 bytes, got <n>"
        "webpush: user agent public key must be 65 bytes, got <n>"
        "webpush: application server public key must be 65 bytes, got <n>"
    """
    if len(auth_secret) != AUTH_SECRET_SIZE:
        raise Error(
            "webpush: auth secret must be 16 bytes, got "
            + String(len(auth_secret))
        )
    if len(ua_public) != PUBLIC_KEY_SIZE:
        raise Error(
            "webpush: user agent public key must be 65 bytes, got "
            + String(len(ua_public))
        )
    if len(as_public) != PUBLIC_KEY_SIZE:
        raise Error(
            "webpush: application server public key must be 65 bytes, got "
            + String(len(as_public))
        )
    var label = StaticString("WebPush: info").as_bytes()
    var key_info = List[UInt8](capacity=len(label) + 1 + 2 * PUBLIC_KEY_SIZE)
    for i in range(len(label)):
        key_info.append(label[i])
    key_info.append(UInt8(0x00))
    for i in range(PUBLIC_KEY_SIZE):
        key_info.append(ua_public[i])
    for i in range(PUBLIC_KEY_SIZE):
        key_info.append(as_public[i])
    var prk = Hkdf[Sha256].extract(auth_secret, ecdh_secret)
    var ikm = Array[UInt8, 32](fill=UInt8(0))
    # Hkdf.expand raises only for an output over 255 * 32 bytes, before it
    # writes any byte, so `ikm` holds no key material if it raises.
    try:
        Hkdf[Sha256].expand(
            Span[UInt8](prk), Span[UInt8](key_info), Span[UInt8](ikm)
        )
    finally:
        zeroize_inline_array(prk)
    return ikm^


def webpush_encrypt_with[R: WebPushRandomness](
    mut randomness: R,
    ua_public: Span[UInt8, _],
    auth_secret: Span[UInt8, _],
    plaintext: Span[UInt8, _],
) raises -> List[UInt8]:
    """Encrypts `plaintext` for one subscription with the salt and sender key
    `randomness` returns.

    Returns:
        The aes128gcm request body (header with keyid = as_public, then one
        record).

    Raises:
        "webpush: plaintext is <n> bytes, more than the 3993 a push
         message holds"
        every refusal of `webpush_ikm` and of `komira_crypto.p256_ecdh` for
        `ua_public` (a point off the curve, a wrong encoding).
    """
    if len(plaintext) > MAX_PLAINTEXT_SIZE:
        raise Error(
            "webpush: plaintext is "
            + String(len(plaintext))
            + " bytes, more than the 3993 a push message holds"
        )
    if len(auth_secret) != AUTH_SECRET_SIZE:
        raise Error(
            "webpush: auth secret must be 16 bytes, got "
            + String(len(auth_secret))
        )
    # Each secret is wiped on the raise path as well as after its last use.
    var as_private = randomness.sender_private_key()
    var as_public = Array[UInt8, 65](fill=UInt8(0))
    var ecdh_secret = Array[UInt8, 32](fill=UInt8(0))
    try:
        as_public = p256_public_key(Span[UInt8](as_private))
        ecdh_secret = p256_ecdh(Span[UInt8](as_private), ua_public)
    except e:
        zeroize_inline_array(as_private)
        raise e^
    zeroize_inline_array(as_private)
    var ikm = Array[UInt8, 32](fill=UInt8(0))
    try:
        ikm = webpush_ikm(
            Span[UInt8](ecdh_secret),
            auth_secret,
            ua_public,
            Span[UInt8](as_public),
        )
    finally:
        zeroize_inline_array(ecdh_secret)
    try:
        var salt = randomness.salt()
        var body = aes128gcm_encrypt(
            Span[UInt8](ikm),
            Span[UInt8](salt),
            Span[UInt8](as_public),
            RECORD_SIZE,
            plaintext,
        )
        zeroize_inline_array(ikm)
        return body^
    except e:
        zeroize_inline_array(ikm)
        raise e^


def webpush_encrypt(
    ua_public: Span[UInt8, _],
    auth_secret: Span[UInt8, _],
    plaintext: Span[UInt8, _],
) raises -> List[UInt8]:
    """`webpush_encrypt_with` over the system CSPRNG: a fresh salt and a
    fresh sender key for every message."""
    var randomness = SystemWebPushRandomness()
    return webpush_encrypt_with(randomness, ua_public, auth_secret, plaintext)


def webpush_decrypt(
    ua_private: Span[UInt8, _],
    ua_public: Span[UInt8, _],
    auth_secret: Span[UInt8, _],
    body: Span[UInt8, _],
) raises -> List[UInt8]:
    """The user agent's side: decrypts a push message body.

    Raises:
        "webpush: user agent public key is not the key of the private key"
        "webpush: keyid must be the 65-byte sender public key, got <n> bytes"
        "webpush: body holds more than one record"
        every refusal of `p256_public_key`, `webpush_ikm`,
        `komira_crypto.p256_ecdh` (for the keyid) and
        `aes128gcm_decrypt`.
    """
    var derived = p256_public_key(ua_private)
    if len(ua_public) != PUBLIC_KEY_SIZE:
        raise Error(
            "webpush: user agent public key must be 65 bytes, got "
            + String(len(ua_public))
        )
    for i in range(PUBLIC_KEY_SIZE):
        if derived[i] != ua_public[i]:
            raise Error(
                "webpush: user agent public key is not the key of the"
                " private key"
            )
    var header = aes128gcm_parse_header(body)
    if len(header.keyid) != PUBLIC_KEY_SIZE:
        raise Error(
            "webpush: keyid must be the 65-byte sender public key, got "
            + String(len(header.keyid))
            + " bytes"
        )
    if len(body) - header.records_offset > header.rs:
        raise Error("webpush: body holds more than one record")
    var ecdh_secret = p256_ecdh(ua_private, Span[UInt8](header.keyid))
    var ikm = Array[UInt8, 32](fill=UInt8(0))
    try:
        ikm = webpush_ikm(
            Span[UInt8](ecdh_secret),
            auth_secret,
            ua_public,
            Span[UInt8](header.keyid),
        )
    except e:
        zeroize_inline_array(ecdh_secret)
        raise e^
    zeroize_inline_array(ecdh_secret)
    try:
        var plaintext = aes128gcm_decrypt(Span[UInt8](ikm), body)
        zeroize_inline_array(ikm)
        return plaintext^
    except e:
        zeroize_inline_array(ikm)
        raise e^
