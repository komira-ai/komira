# =============================================================================
# komira_crypto/tests/test_small_edges.mojo
#
# Edge cases of small helpers no other welded test reaches:
#   * AES-GCM and ChaCha20-Poly1305 refuse a buffer shorter than the tag
#     (15 bytes) on seal and open; 16 bytes (empty plaintext) round-trips;
#   * HKDF-Expand of 0 bytes writes nothing and of 1 byte writes OKM[0] of
#     RFC 5869 A.1 (through Hkdf and through hkdf_expand_ffi directly);
#     HKDF-Expand-Label refuses a 256-byte context and a 65536-byte output,
#     and lets 255 / 65535 through to the next check;
#   * streaming HMAC fed empty and one-byte updates equals RFC 4231 case 2;
#   * RAND_bytes and the DRBG wrapper with empty and one-byte requests, and
#     the DRBG's block count across the 64-byte boundary;
#   * hex_upper's digit and letter arms; the root store's hex nibble decoder
#     on both cases and the bytes just outside each range;
#   * p256_ecdh_shared_x's own peer-length refusal.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_crypto.aes_gcm import AesGcm128
from komira_crypto.chacha20_poly1305 import ChaCha20Poly1305
from komira_crypto.hkdf import Hkdf
from komira_crypto.hash import Sha256
from komira_crypto.hmac_streaming import Hmac
from komira_crypto.rng import ChaCha20Drbg
from komira_crypto.hex import hex_upper
from komira_crypto.cert.root_store_data import _hex_nibble
from komira_crypto.internal.asm.hkdf_ffi import hkdf_expand_ffi
from komira_crypto.internal.asm.rng_ffi import rand_bytes_ffi
from komira_crypto.internal.asm.p256_ecdh_ffi import p256_ecdh_shared_x


def _hex(s: String) -> List[UInt8]:
    var b = s.as_bytes()
    var out = List[UInt8]()
    for i in range(0, len(b), 2):
        var hi = Int(b[i])
        var lo = Int(b[i + 1])
        hi = hi - 48 if hi < 58 else hi - 87
        lo = lo - 48 if lo < 58 else lo - 87
        out.append(UInt8(hi * 16 + lo))
    return out^


def _l(n: Int, v: Int) -> List[UInt8]:
    var out = List[UInt8]()
    for _ in range(n):
        out.append(UInt8(v))
    return out^


# -----------------------------------------------------------------------------
# AEAD buffers shorter than the tag
# -----------------------------------------------------------------------------


def test_aes_gcm_short_buffer() raises:
    var cipher = AesGcm128(Array[UInt8, 16](fill=UInt8(7)))
    var nonce = Array[UInt8, 12](fill=UInt8(1))
    var aad = _l(3, 9)
    var short = _l(15, 0)
    var e = String("no error")
    try:
        cipher.seal_in_place(nonce, Span(aad), Span(short))
    except err:
        e = String(err)
    assert_true(e.find("AesGcm.seal_in_place: buffer too small") >= 0, "seal: " + e)
    e = String("no error")
    try:
        cipher.open_in_place(nonce, Span(aad), Span(short))
    except err:
        e = String(err)
    assert_true(e.find("AesGcm.open_in_place: buffer too small") >= 0, "open: " + e)
    var tag_only = _l(16, 0)
    cipher.seal_in_place(nonce, Span(aad), Span(tag_only))
    cipher.open_in_place(nonce, Span(aad), Span(tag_only))


def test_chacha_short_buffer() raises:
    var cipher = ChaCha20Poly1305(Array[UInt8, 32](fill=UInt8(7)))
    var nonce = Array[UInt8, 12](fill=UInt8(1))
    var aad = _l(3, 9)
    var short = _l(15, 0)
    var e = String("no error")
    try:
        cipher.seal_in_place(nonce, Span(aad), Span(short))
    except err:
        e = String(err)
    assert_true(e.find("ChaCha20Poly1305.seal_in_place: buffer too small") >= 0, "seal: " + e)
    e = String("no error")
    try:
        cipher.open_in_place(nonce, Span(aad), Span(short))
    except err:
        e = String(err)
    assert_true(e.find("ChaCha20Poly1305.open_in_place: buffer too small") >= 0, "open: " + e)
    var tag_only = _l(16, 0)
    cipher.seal_in_place(nonce, Span(aad), Span(tag_only))
    cipher.open_in_place(nonce, Span(aad), Span(tag_only))


# -----------------------------------------------------------------------------
# HKDF
# -----------------------------------------------------------------------------


def _prk() -> List[UInt8]:
    return _hex("077709362c2e32df0ddc3f0dc47bba6390b6c73bb50f9c3122ec844ad7c2b3e5")


def _info() -> List[UInt8]:
    return _hex("f0f1f2f3f4f5f6f7f8f9")


def test_hkdf_expand_zero_and_one_byte() raises:
    var prk = _prk()
    var info = _info()
    var none = List[UInt8]()
    Hkdf[Sha256].expand(Span(prk), Span(info), Span(none))
    assert_equal(len(none), 0, "nothing written")
    var one = _l(1, 0)
    Hkdf[Sha256].expand(Span(prk), Span(info), Span(one))
    assert_equal(Int(one[0]), 0x3C, "OKM[0] of RFC 5869 A.1")
    var none2 = List[UInt8]()
    hkdf_expand_ffi[32](Span(prk), Span(info), Span(none2))
    var one2 = _l(1, 0)
    hkdf_expand_ffi[32](Span(prk), Span(info), Span(one2))
    assert_equal(Int(one2[0]), 0x3C, "OKM[0] via the FFI")


def _label_err(context_len: Int, out_len: Int) -> String:
    var secret = _l(32, 1)
    var ctx = _l(context_len, 2)
    var dst = _l(out_len, 0)
    try:
        Hkdf[Sha256].hkdf_expand_label(Span(secret), String("key"), Span(ctx), Span(dst))
    except e:
        return String(e)
    return String("no error")


def test_hkdf_expand_label_limits() raises:
    assert_equal(_label_err(255, 32), String("no error"), "255-byte context")
    var e = _label_err(256, 32)
    assert_true(e.find("context exceeds 255 bytes") >= 0, "256-byte context: " + e)
    e = _label_err(0, 65536)
    assert_true(e.find("output length exceeds u16 limit") >= 0, "65536 bytes: " + e)
    # 65535 passes the u16 check and is refused by HKDF-Expand's 255 * HashLen.
    e = _label_err(0, 65535)
    assert_true(e.find("exceeds 255 * HashLen") >= 0, "65535 bytes: " + e)


# -----------------------------------------------------------------------------
# HMAC with empty updates
# -----------------------------------------------------------------------------


def test_hmac_empty_and_one_byte_updates() raises:
    var key = String("Jefe").as_bytes()
    var mac = Hmac[Sha256](key)
    var empty = List[UInt8]()
    mac.update(Span(empty))
    mac.update(String("w").as_bytes())
    mac.update(Span(empty))
    mac.update(String("hat do ya want for nothing?").as_bytes())
    var out = _l(32, 0)
    mac.finalize_into(Span(out))
    var want = _hex("5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843")
    for i in range(32):
        assert_equal(Int(out[i]), Int(want[i]), "RFC 4231 case 2 byte " + String(i))


# -----------------------------------------------------------------------------
# RNG
# -----------------------------------------------------------------------------


def test_rand_bytes_empty_and_one_byte() raises:
    var empty = List[UInt8]()
    rand_bytes_ffi(Span(empty))
    # 64 one-byte requests all zero has probability 2^-512.
    var acc = UInt8(0)
    for _ in range(64):
        var one = _l(1, 0)
        rand_bytes_ffi(Span(one))
        acc |= one[0]
    assert_true(acc != 0, "one-byte requests are filled")


def test_drbg_block_count() raises:
    var d = ChaCha20Drbg()
    var empty = List[UInt8]()
    d.next(Span(empty))
    assert_equal(Int(d.blocks_produced()), 0, "empty request counts no block")
    var one = _l(1, 0)
    d.next(Span(one))
    assert_equal(Int(d.blocks_produced()), 1, "one byte is one block")
    var b64 = _l(64, 0)
    d.next(Span(b64))
    assert_equal(Int(d.blocks_produced()), 2, "64 bytes is one block")
    var b65 = _l(65, 0)
    d.next(Span(b65))
    assert_equal(Int(d.blocks_produced()), 4, "65 bytes is two blocks")


# -----------------------------------------------------------------------------
# Hex
# -----------------------------------------------------------------------------


def test_hex_upper_digits_and_letters() raises:
    var v = _hex("09af50ff00")
    assert_equal(hex_upper(Span(v)), String("09AF50FF00"), "upper hex")


def _nibble(c: String) -> Int:
    try:
        return Int(_hex_nibble(c.as_bytes()[0]))
    except:
        return -1


def test_root_store_hex_nibble() raises:
    assert_equal(_nibble("0"), 0, "0")
    assert_equal(_nibble("9"), 9, "9")
    assert_equal(_nibble("a"), 10, "a")
    assert_equal(_nibble("f"), 15, "f")
    assert_equal(_nibble("A"), 10, "A")
    assert_equal(_nibble("F"), 15, "F")
    assert_equal(_nibble("/"), -1, "below 0")
    assert_equal(_nibble(":"), -1, "above 9")
    assert_equal(_nibble("`"), -1, "below a")
    assert_equal(_nibble("g"), -1, "above f")
    assert_equal(_nibble("@"), -1, "below A")
    assert_equal(_nibble("G"), -1, "above F")


# -----------------------------------------------------------------------------
# P-256 ECDH FFI
# -----------------------------------------------------------------------------


def test_ecdh_ffi_peer_length() raises:
    var priv = _l(32, 0x22)
    var z = Array[UInt8, 32](fill=UInt8(0))
    for n in range(64, 67, 2):
        var peer = _l(n, 4)
        var e = String("no error")
        try:
            p256_ecdh_shared_x(Span(priv), Span(peer), z)
        except err:
            e = String(err)
        assert_true(
            e.find("peer public key must be 65 bytes, got " + String(n)) >= 0,
            String(n) + "-byte peer: " + e,
        )


def main() raises:
    test_aes_gcm_short_buffer()
    test_chacha_short_buffer()
    test_hkdf_expand_zero_and_one_byte()
    test_hkdf_expand_label_limits()
    test_hmac_empty_and_one_byte_updates()
    test_rand_bytes_empty_and_one_byte()
    test_drbg_block_count()
    test_hex_upper_digits_and_letters()
    test_root_store_hex_nibble()
    test_ecdh_ffi_peer_length()
    print("test_small_edges: 10 tests PASS")
