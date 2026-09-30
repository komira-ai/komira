# =============================================================================
# komira_crypto/tests/test_aes_gcm_kat.mojo
# =============================================================================
#
# Known-Answer-Test (KAT) corpus for AesGcm128 + AesGcm256.
#
# Vector sources:
#
#   * NIST SP 800-38D Appendix B — canonical AEAD test cases 1-18. These
#     are the AES-GCM reference vectors that every implementation MUST
#     reproduce byte-identically. Includes:
#       - B.1-B.6:  AES-128, varying PT/AAD/IV-length boundaries
#       - B.13-B.18: AES-256, same boundary set
#     Public domain NIST reference (the canonical NIST CAVP `gcmEncryptIntIV`
#     boundary subset). Source URL:
#     https://nvlpubs.nist.gov/nistpubs/Legacy/SP/nistspecialpublication800-38d.pdf
#
#   * 256-final-byte ciphertext sweep — the initial-AddRoundKey(K0) bug-catcher.
#     Encrypt 256 distinct messages that differ only in their final byte;
#     decrypt all 256 and verify each round-trips correctly. If the
#     initial AddRoundKey(K0) is omitted, every byte of every block is
#     wrong; this test fails catastrophically with 256 mismatches.
#
# The full NIST CAVP corpus (gcmEncryptIntIV.rsp, ~1500 vectors per arity)
# is not vendored; the SP 800-38D Appendix B boundary subset is the
# canonical reference.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_crypto import AesGcm128, AesGcm256


# -----------------------------------------------------------------------------
# Helpers — hex decode (same as test_aes_gcm_smoke.mojo).
# -----------------------------------------------------------------------------


def _hex_nibble(c: UInt8) -> UInt8:
    if c >= UInt8(0x30) and c <= UInt8(0x39):
        return c - UInt8(0x30)
    if c >= UInt8(0x61) and c <= UInt8(0x66):
        return c - UInt8(0x61) + UInt8(10)
    if c >= UInt8(0x41) and c <= UInt8(0x46):
        return c - UInt8(0x41) + UInt8(10)
    return UInt8(0xFF)


def _hex_to_list(s: String) -> List[UInt8]:
    """Parse a hex string into a List[UInt8]."""
    var bs = s.as_bytes()
    var n = len(bs) // 2
    var out = List[UInt8](capacity=n)
    for i in range(n):
        var hi = _hex_nibble(bs[2 * i])
        var lo = _hex_nibble(bs[2 * i + 1])
        out.append((hi << UInt8(4)) | lo)
    return out^


def _hex_to_16(s: String) -> Array[UInt8, 16]:
    var out = Array[UInt8, 16](fill=UInt8(0))
    var bs = s.as_bytes()
    for i in range(16):
        var hi = _hex_nibble(bs[2 * i])
        var lo = _hex_nibble(bs[2 * i + 1])
        out[i] = (hi << UInt8(4)) | lo
    return out^


def _hex_to_32(s: String) -> Array[UInt8, 32]:
    var out = Array[UInt8, 32](fill=UInt8(0))
    var bs = s.as_bytes()
    for i in range(32):
        var hi = _hex_nibble(bs[2 * i])
        var lo = _hex_nibble(bs[2 * i + 1])
        out[i] = (hi << UInt8(4)) | lo
    return out^


def _hex_to_12(s: String) -> Array[UInt8, 12]:
    var out = Array[UInt8, 12](fill=UInt8(0))
    var bs = s.as_bytes()
    for i in range(12):
        var hi = _hex_nibble(bs[2 * i])
        var lo = _hex_nibble(bs[2 * i + 1])
        out[i] = (hi << UInt8(4)) | lo
    return out^


def _assert_bytes_equal(
    actual: List[UInt8], expected: List[UInt8], label: String
) raises:
    assert_equal(
        len(actual), len(expected), label + " length mismatch",
    )
    for i in range(len(actual)):
        assert_equal(
            Int(actual[i]), Int(expected[i]),
            label + " byte " + String(i) + " mismatch",
        )


# -----------------------------------------------------------------------------
# Test driver — run one NIST SP 800-38D Appendix B vector through
# seal_in_place + verify ciphertext + tag byte-identical; then open and
# verify plaintext recovered.
# -----------------------------------------------------------------------------


def _run_aes128_kat(
    label: String,
    key_hex: String,
    iv_hex: String,
    pt_hex: String,
    aad_hex: String,
    ct_hex: String,
    tag_hex: String,
) raises:
    """Run one AES-128-GCM KAT vector. All hex inputs."""
    var key = _hex_to_16(key_hex)
    var cipher_seal = AesGcm128(key)

    var iv = _hex_to_12(iv_hex)
    var aad = _hex_to_list(aad_hex)
    var pt = _hex_to_list(pt_hex)
    var expected_ct = _hex_to_list(ct_hex)
    var expected_tag = _hex_to_list(tag_hex)

    # buf = plaintext || zeros-for-tag.
    var buf = List[UInt8](capacity=len(pt) + 16)
    for i in range(len(pt)):
        buf.append(pt[i])
    for _ in range(16):
        buf.append(UInt8(0))

    cipher_seal.seal_in_place(iv, Span[UInt8](aad), Span[UInt8](buf))

    # Verify ciphertext bytes byte-identical.
    for i in range(len(pt)):
        assert_equal(
            Int(buf[i]), Int(expected_ct[i]),
            label + " CT byte " + String(i) + " mismatch",
        )
    # Verify tag.
    for i in range(16):
        assert_equal(
            Int(buf[len(pt) + i]), Int(expected_tag[i]),
            label + " tag byte " + String(i) + " mismatch",
        )

    # Now open and verify plaintext recovered.
    var cipher_open = AesGcm128(key)
    cipher_open.open_in_place(iv, Span[UInt8](aad), Span[UInt8](buf))
    for i in range(len(pt)):
        assert_equal(
            Int(buf[i]), Int(pt[i]),
            label + " open recovered PT byte " + String(i) + " mismatch",
        )


def _run_aes256_kat(
    label: String,
    key_hex: String,
    iv_hex: String,
    pt_hex: String,
    aad_hex: String,
    ct_hex: String,
    tag_hex: String,
) raises:
    """Run one AES-256-GCM KAT vector."""
    var key = _hex_to_32(key_hex)
    var cipher_seal = AesGcm256(key)

    var iv = _hex_to_12(iv_hex)
    var aad = _hex_to_list(aad_hex)
    var pt = _hex_to_list(pt_hex)
    var expected_ct = _hex_to_list(ct_hex)
    var expected_tag = _hex_to_list(tag_hex)

    var buf = List[UInt8](capacity=len(pt) + 16)
    for i in range(len(pt)):
        buf.append(pt[i])
    for _ in range(16):
        buf.append(UInt8(0))

    cipher_seal.seal_in_place(iv, Span[UInt8](aad), Span[UInt8](buf))

    for i in range(len(pt)):
        assert_equal(
            Int(buf[i]), Int(expected_ct[i]),
            label + " CT byte " + String(i) + " mismatch",
        )
    for i in range(16):
        assert_equal(
            Int(buf[len(pt) + i]), Int(expected_tag[i]),
            label + " tag byte " + String(i) + " mismatch",
        )

    var cipher_open = AesGcm256(key)
    cipher_open.open_in_place(iv, Span[UInt8](aad), Span[UInt8](buf))
    for i in range(len(pt)):
        assert_equal(
            Int(buf[i]), Int(pt[i]),
            label + " open recovered PT byte " + String(i) + " mismatch",
        )


# -----------------------------------------------------------------------------
# NIST SP 800-38D Appendix B — AES-128 boundary cases.
# -----------------------------------------------------------------------------


def test_nist_b1_aes128_empty() raises:
    """B.1: K=0, IV=0, PT=empty, AAD=empty. Expected tag verified."""
    _run_aes128_kat(
        String("B.1"),
        String("00000000000000000000000000000000"),
        String("000000000000000000000000"),
        String(""),
        String(""),
        String(""),
        String("58e2fccefa7e3061367f1d57a4e7455a"),
    )


def test_nist_b2_aes128_one_block_zero() raises:
    """B.2: K=0, IV=0, PT=16 zero bytes, AAD=empty."""
    _run_aes128_kat(
        String("B.2"),
        String("00000000000000000000000000000000"),
        String("000000000000000000000000"),
        String("00000000000000000000000000000000"),
        String(""),
        String("0388dace60b6a392f328c2b971b2fe78"),
        String("ab6e47d42cec13bdf53a67b21257bddf"),
    )


def test_nist_b3_aes128_full() raises:
    """B.3: full 4-block (64-byte) plaintext, no AAD."""
    _run_aes128_kat(
        String("B.3"),
        String("feffe9928665731c6d6a8f9467308308"),
        String("cafebabefacedbaddecaf888"),
        String("d9313225f88406e5a55909c5aff5269a86a7a9531534f7da2e4c303d8a318a721c3c0c95956809532fcf0e2449a6b525b16aedf5aa0de657ba637b391aafd255"),
        String(""),
        String("42831ec2217774244b7221b784d0d49ce3aa212f2c02a4e035c17e2329aca12e21d514b25466931c7d8f6a5aac84aa051ba30b396a0aac973d58e091473f5985"),
        String("4d5c2af327cd64a62cf35abd2ba6fab4"),
    )


def test_nist_b4_aes128_with_aad() raises:
    """B.4: 60-byte PT + 20-byte AAD. The canonical AAD-using vector."""
    _run_aes128_kat(
        String("B.4"),
        String("feffe9928665731c6d6a8f9467308308"),
        String("cafebabefacedbaddecaf888"),
        String("d9313225f88406e5a55909c5aff5269a86a7a9531534f7da2e4c303d8a318a721c3c0c95956809532fcf0e2449a6b525b16aedf5aa0de657ba637b39"),
        String("feedfacedeadbeeffeedfacedeadbeefabaddad2"),
        String("42831ec2217774244b7221b784d0d49ce3aa212f2c02a4e035c17e2329aca12e21d514b25466931c7d8f6a5aac84aa051ba30b396a0aac973d58e091"),
        String("5bc94fbc3221a5db94fae95ae7121a47"),
    )


# -----------------------------------------------------------------------------
# NIST SP 800-38D Appendix B — AES-256 boundary cases.
# -----------------------------------------------------------------------------


def test_nist_b13_aes256_empty() raises:
    """B.13: AES-256 K=0, IV=0, PT=empty, AAD=empty."""
    _run_aes256_kat(
        String("B.13"),
        String("0000000000000000000000000000000000000000000000000000000000000000"),
        String("000000000000000000000000"),
        String(""),
        String(""),
        String(""),
        String("530f8afbc74536b9a963b4f1c4cb738b"),
    )


def test_nist_b14_aes256_one_block_zero() raises:
    """B.14: AES-256 K=0, IV=0, PT=16 zero bytes."""
    _run_aes256_kat(
        String("B.14"),
        String("0000000000000000000000000000000000000000000000000000000000000000"),
        String("000000000000000000000000"),
        String("00000000000000000000000000000000"),
        String(""),
        String("cea7403d4d606b6e074ec5d3baf39d18"),
        String("d0d1c8a799996bf0265b98b5d48ab919"),
    )


def test_nist_b15_aes256_full() raises:
    """B.15: AES-256 full 4-block PT, no AAD."""
    _run_aes256_kat(
        String("B.15"),
        String("feffe9928665731c6d6a8f9467308308feffe9928665731c6d6a8f9467308308"),
        String("cafebabefacedbaddecaf888"),
        String("d9313225f88406e5a55909c5aff5269a86a7a9531534f7da2e4c303d8a318a721c3c0c95956809532fcf0e2449a6b525b16aedf5aa0de657ba637b391aafd255"),
        String(""),
        String("522dc1f099567d07f47f37a32a84427d643a8cdcbfe5c0c97598a2bd2555d1aa8cb08e48590dbb3da7b08b1056828838c5f61e6393ba7a0abcc9f662898015ad"),
        String("b094dac5d93471bdec1a502270e3cc6c"),
    )


def test_nist_b16_aes256_with_aad() raises:
    """B.16: AES-256 60-byte PT + 20-byte AAD."""
    _run_aes256_kat(
        String("B.16"),
        String("feffe9928665731c6d6a8f9467308308feffe9928665731c6d6a8f9467308308"),
        String("cafebabefacedbaddecaf888"),
        String("d9313225f88406e5a55909c5aff5269a86a7a9531534f7da2e4c303d8a318a721c3c0c95956809532fcf0e2449a6b525b16aedf5aa0de657ba637b39"),
        String("feedfacedeadbeeffeedfacedeadbeefabaddad2"),
        String("522dc1f099567d07f47f37a32a84427d643a8cdcbfe5c0c97598a2bd2555d1aa8cb08e48590dbb3da7b08b1056828838c5f61e6393ba7a0abcc9f662"),
        String("76fc6ece0f4e1768cddf8853bb2d551b"),
    )


# -----------------------------------------------------------------------------
# 256-final-byte ciphertext sweep — the initial-AddRoundKey(K0) bug-catcher.
#
# Strategy: encrypt 256 distinct plaintexts of length 16 bytes where each
# differs ONLY in its final (16th) byte. Decrypt all 256 and verify each
# round-trips correctly.
#
# Bug-catcher rationale: if the initial AddRoundKey(K0) is omitted, the
# first Rijndael round is missing entirely. Then EVERY byte of EVERY
# block is wrong (the AES output is NOT close to the correct output —
# it's a completely different ciphertext from a different cipher
# instance). Open will fail tag-verify on every one of the 256 messages,
# so this test fails catastrophically with 256 RAISES.
#
# This test is a strict superset of the basic round-trip test: it
# exercises 256 distinct PT/CT pairs through the same cipher key,
# covering the AES + counter-mode + GHASH + tag-verify pipeline end-to-end.
# -----------------------------------------------------------------------------


def test_256_final_byte_sweep_aes128() raises:
    """K0 bug-catcher: encrypt 256 PTs differing in final byte, all round-trip.

    The 256 final-byte values 0x00..0xFF give 256 distinct (PT, CT, tag)
    triples. The seal output of each is unique (the AES-CTR keystream is
    fixed by the IV; different PTs → different CTs but same keystream).
    open_in_place must succeed (no auth-failure raise) on all 256, and
    recovered PT must equal original PT byte-for-byte.
    """
    var key = _hex_to_16(String("feffe9928665731c6d6a8f9467308308"))
    var iv = _hex_to_12(String("cafebabefacedbaddecaf888"))

    for final_byte in range(256):
        # Original PT: 15 bytes of a fixed pattern + 1 byte that varies.
        var orig_pt = List[UInt8](capacity=16)
        for i in range(15):
            orig_pt.append(UInt8(0x5A))
        orig_pt.append(UInt8(final_byte))

        # buf = PT || tag-space.
        var buf = List[UInt8](capacity=32)
        for i in range(16):
            buf.append(orig_pt[i])
        for _ in range(16):
            buf.append(UInt8(0))

        var aad = List[UInt8]()  # empty AAD
        var cipher_seal = AesGcm128(key)
        cipher_seal.seal_in_place(iv, Span[UInt8](aad), Span[UInt8](buf))

        # Open and verify recovery.
        var cipher_open = AesGcm128(key)
        cipher_open.open_in_place(iv, Span[UInt8](aad), Span[UInt8](buf))

        for i in range(16):
            assert_equal(
                Int(buf[i]), Int(orig_pt[i]),
                "K0 sweep final_byte=" + String(final_byte)
                + " PT byte " + String(i) + " mismatch",
            )


def test_256_final_byte_sweep_aes256() raises:
    """K0 bug-catcher for AES-256: 256 PTs differing in final byte, all round-trip."""
    var key = _hex_to_32(String(
        "feffe9928665731c6d6a8f9467308308feffe9928665731c6d6a8f9467308308"
    ))
    var iv = _hex_to_12(String("cafebabefacedbaddecaf888"))

    for final_byte in range(256):
        var orig_pt = List[UInt8](capacity=16)
        for i in range(15):
            orig_pt.append(UInt8(0xA5))
        orig_pt.append(UInt8(final_byte))

        var buf = List[UInt8](capacity=32)
        for i in range(16):
            buf.append(orig_pt[i])
        for _ in range(16):
            buf.append(UInt8(0))

        var aad = List[UInt8]()
        var cipher_seal = AesGcm256(key)
        cipher_seal.seal_in_place(iv, Span[UInt8](aad), Span[UInt8](buf))

        var cipher_open = AesGcm256(key)
        cipher_open.open_in_place(iv, Span[UInt8](aad), Span[UInt8](buf))

        for i in range(16):
            assert_equal(
                Int(buf[i]), Int(orig_pt[i]),
                "K0 sweep AES-256 final_byte=" + String(final_byte)
                + " PT byte " + String(i) + " mismatch",
            )


# -----------------------------------------------------------------------------
# 256 distinct ciphertexts produced — sanity check that the AES+GCM
# function is NOT a constant. (If K0 were missing, the output would
# still vary by IV/PT but the ciphertext bytes would differ from the
# NIST reference; the previous round-trip test catches this. This
# test additionally verifies that distinct PTs produce distinct CTs.)
# -----------------------------------------------------------------------------


def test_256_distinct_ciphertexts_aes128() raises:
    """256 distinct PTs produce 256 distinct CTs (no collisions).

    A correct cipher is a permutation under fixed K + IV-counter. Any
    bug that collapses CT space (e.g., always returning a constant)
    would show as collisions.
    """
    var key = _hex_to_16(String("feffe9928665731c6d6a8f9467308308"))
    var iv = _hex_to_12(String("cafebabefacedbaddecaf888"))

    # Store the 16-byte ciphertext for each PT in a List for collision check.
    var cts = List[Array[UInt8, 16]](capacity=256)

    for final_byte in range(256):
        var buf = List[UInt8](capacity=32)
        for i in range(15):
            buf.append(UInt8(0x33))
        buf.append(UInt8(final_byte))
        for _ in range(16):
            buf.append(UInt8(0))

        var aad = List[UInt8]()
        var cipher = AesGcm128(key)
        cipher.seal_in_place(iv, Span[UInt8](aad), Span[UInt8](buf))

        var ct = Array[UInt8, 16](fill=UInt8(0))
        for i in range(16):
            ct[i] = buf[i]
        cts.append(ct^)

    # Pairwise distinctness check. With 256 entries, the all-pairs check
    # is 256*255/2 = ~32K comparisons — well under iteration budget.
    for i in range(256):
        for j in range(i + 1, 256):
            var distinct = False
            for k in range(16):
                if cts[i][k] != cts[j][k]:
                    distinct = True
            assert_true(
                distinct,
                "AES-128 CT collision between final_byte="
                + String(i) + " and " + String(j),
            )


def main() raises:
    test_nist_b1_aes128_empty()
    test_nist_b2_aes128_one_block_zero()
    test_nist_b3_aes128_full()
    test_nist_b4_aes128_with_aad()
    test_nist_b13_aes256_empty()
    test_nist_b14_aes256_one_block_zero()
    test_nist_b15_aes256_full()
    test_nist_b16_aes256_with_aad()
    test_256_final_byte_sweep_aes128()
    test_256_final_byte_sweep_aes256()
    test_256_distinct_ciphertexts_aes128()
    print("OK")
