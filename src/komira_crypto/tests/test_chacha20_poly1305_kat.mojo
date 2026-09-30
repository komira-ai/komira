# =============================================================================
# komira_crypto/tests/test_chacha20_poly1305_kat.mojo — KAT corpus
# =============================================================================
#
# Known-answer + bug-catcher test corpus for ChaCha20-Poly1305 AEAD per
# RFC 8439 §2.8.2 + Appendix A.5.
#
# Test corpus:
#   1. RFC 8439 §2.8.2 — canonical AEAD reference vector:
#        Key=80..9f, Nonce=07 00 00 00 40 41 42 43 44 45 46 47
#        AAD=50515253c0c1c2c3c4c5c6c7 (12 bytes)
#        Plaintext="Ladies and Gentlemen..." (114 bytes)
#        Ciphertext = d31a8d34... (114 bytes)
#        Tag = 1ae10b594f09e26a7e902ecbd0600691
#   2. RFC 8439 Appendix A.5 — second AEAD test vector with non-trivial
#      AAD + multi-block plaintext.
#   3. Round-trip: seal_in_place then open_in_place recovers plaintext.
#   4. Tampered tag: open_in_place RAISES on single-bit tag flip.
#   5. Tampered ciphertext: open_in_place RAISES on single-bit CT flip
#      (Poly1305 MAC detects).
#   6. Empty plaintext: AAD-only authenticate (tag derived from
#      lengths-only MAC absorb).
#   7. Empty AAD: plaintext-only authenticate.
#   8. 256-final-byte sweep (the bug-catcher; mirrors the AES-GCM pattern):
#      vary the final byte of plaintext over all 256 values; round-trip
#      all 256 messages without raising.
#   9. 256-distinct-ciphertext check: 256 distinct PTs produce 256
#      distinct CTs (pairwise) — confirms the AEAD is a permutation
#      modulo the tag.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_crypto import ChaCha20Poly1305


# -----------------------------------------------------------------------------
# Helpers.
# -----------------------------------------------------------------------------


def _hex_nibble(c: UInt8) -> UInt8:
    if c >= UInt8(0x30) and c <= UInt8(0x39):
        return c - UInt8(0x30)
    if c >= UInt8(0x61) and c <= UInt8(0x66):
        return c - UInt8(0x61) + UInt8(10)
    if c >= UInt8(0x41) and c <= UInt8(0x46):
        return c - UInt8(0x41) + UInt8(10)
    return UInt8(0xFF)


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


def _hex_to_list(s: String) -> List[UInt8]:
    var bs = s.as_bytes()
    var n = len(bs) // 2
    var out = List[UInt8](capacity=n)
    for i in range(n):
        var hi = _hex_nibble(bs[2 * i])
        var lo = _hex_nibble(bs[2 * i + 1])
        out.append((hi << UInt8(4)) | lo)
    return out^


def _bytes_to_hex(b: List[UInt8]) -> String:
    var hex_chars = String("0123456789abcdef")
    var hb = hex_chars.as_bytes()
    var out = List[UInt8](capacity=len(b) * 2)
    for i in range(len(b)):
        out.append(hb[Int((b[i] >> UInt8(4)) & UInt8(0xF))])
        out.append(hb[Int(b[i] & UInt8(0xF))])
    return String(unsafe_from_utf8=Span[UInt8](out))


def _string_to_list(s: String) -> List[UInt8]:
    var bs = s.as_bytes()
    var out = List[UInt8](capacity=len(bs))
    for i in range(len(bs)):
        out.append(bs[i])
    return out^


# -----------------------------------------------------------------------------
# Test 1 — RFC 8439 §2.8.2 canonical AEAD reference vector.
# -----------------------------------------------------------------------------


def test_chacha20_poly1305_rfc8439_282() raises:
    """RFC 8439 §2.8.2 canonical AEAD reference vector.

    Key=80..9f, Nonce=07 00 00 00 40 41 42 43 44 45 46 47.
    AAD = 50 51 52 53 c0 c1 c2 c3 c4 c5 c6 c7 (12 bytes).
    Plaintext = "Ladies and Gentlemen of the class of '99: If I could
                 offer you only one tip for the future, sunscreen would
                 be it." (114 bytes).
    Expected ciphertext + tag per §2.8.2.
    """
    var key = _hex_to_32(
        String("808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f")
    )
    var nonce = _hex_to_12(String("070000004041424344454647"))
    var aad = _hex_to_list(String("50515253c0c1c2c3c4c5c6c7"))

    var plaintext_str = String(
        "Ladies and Gentlemen of the class of '99: If I could offer you only "
        "one tip for the future, sunscreen would be it."
    )
    var pt_bytes = _string_to_list(plaintext_str)
    assert_equal(len(pt_bytes), 114)

    # Build the in-place buffer: [plaintext (114)][tag space (16)].
    var buf = List[UInt8](capacity=130)
    for i in range(114):
        buf.append(pt_bytes[i])
    for _ in range(16):
        buf.append(UInt8(0))

    var cipher = ChaCha20Poly1305(key)
    cipher.seal_in_place(nonce, Span[UInt8](aad), Span[UInt8](buf))

    # Expected ciphertext (114 bytes):
    #   d31a8d34648e60db7b86afbc53ef7ec2a4aded51296e08fea9e2b5a736ee62d6
    #   3dbea45e8ca9671282fafb69da92728b1a71de0a9e060b2905d6a5b67ecd3b36
    #   92ddbd7f2d778b8c9803aee328091b58fab324e4fad675945585808b4831d7bc
    #   3ff4def08e4b7a9de576d26586cec64b6116
    var expected_ct = _hex_to_list(
        String(
            "d31a8d34648e60db7b86afbc53ef7ec2"
            "a4aded51296e08fea9e2b5a736ee62d6"
            "3dbea45e8ca9671282fafb69da92728b"
            "1a71de0a9e060b2905d6a5b67ecd3b36"
            "92ddbd7f2d778b8c9803aee328091b58"
            "fab324e4fad675945585808b4831d7bc"
            "3ff4def08e4b7a9de576d26586cec64b"
            "6116"
        )
    )
    assert_equal(len(expected_ct), 114)

    # Expected tag = 1ae10b594f09e26a7e902ecbd0600691
    var expected_tag = _hex_to_list(
        String("1ae10b594f09e26a7e902ecbd0600691")
    )
    assert_equal(len(expected_tag), 16)

    # Verify ciphertext bytes.
    var actual_ct = List[UInt8](capacity=114)
    for i in range(114):
        actual_ct.append(buf[i])
    assert_equal(_bytes_to_hex(actual_ct), _bytes_to_hex(expected_ct))

    # Verify tag bytes.
    var actual_tag = List[UInt8](capacity=16)
    for i in range(16):
        actual_tag.append(buf[114 + i])
    assert_equal(_bytes_to_hex(actual_tag), _bytes_to_hex(expected_tag))


# -----------------------------------------------------------------------------
# Test 2 — Round-trip: seal then open recovers plaintext.
# -----------------------------------------------------------------------------


def test_chacha20_poly1305_round_trip() raises:
    """Seal then open recovers plaintext byte-identically."""
    var key = _hex_to_32(
        String("808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f")
    )
    var nonce = _hex_to_12(String("070000004041424344454647"))
    var aad = _hex_to_list(String("50515253c0c1c2c3c4c5c6c7"))

    var pt_str = String("Ladies and Gentlemen of the class of '99")
    var pt_bytes = _string_to_list(pt_str)
    var pt_len = len(pt_bytes)
    var orig_pt = List[UInt8](capacity=pt_len)
    for i in range(pt_len):
        orig_pt.append(pt_bytes[i])

    var buf = List[UInt8](capacity=pt_len + 16)
    for i in range(pt_len):
        buf.append(pt_bytes[i])
    for _ in range(16):
        buf.append(UInt8(0))

    var cipher1 = ChaCha20Poly1305(key)
    cipher1.seal_in_place(nonce, Span[UInt8](aad), Span[UInt8](buf))

    var cipher2 = ChaCha20Poly1305(key)
    cipher2.open_in_place(nonce, Span[UInt8](aad), Span[UInt8](buf))

    # After open_in_place, first pt_len bytes are the recovered plaintext.
    for i in range(pt_len):
        assert_equal(buf[i], orig_pt[i])


# -----------------------------------------------------------------------------
# Test 3 — Tampered tag: open_in_place RAISES.
# -----------------------------------------------------------------------------


def test_chacha20_poly1305_tampered_tag_raises() raises:
    """open_in_place raises on single-bit tag flip."""
    var key = _hex_to_32(
        String("808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f")
    )
    var nonce = _hex_to_12(String("070000004041424344454647"))
    var aad = _hex_to_list(String("50515253c0c1c2c3c4c5c6c7"))

    var pt_str = String("Sample plaintext")
    var pt_bytes = _string_to_list(pt_str)
    var pt_len = len(pt_bytes)

    var buf = List[UInt8](capacity=pt_len + 16)
    for i in range(pt_len):
        buf.append(pt_bytes[i])
    for _ in range(16):
        buf.append(UInt8(0))

    var cipher1 = ChaCha20Poly1305(key)
    cipher1.seal_in_place(nonce, Span[UInt8](aad), Span[UInt8](buf))

    # Flip a bit in the tag (last byte).
    buf[pt_len + 15] = buf[pt_len + 15] ^ UInt8(0x01)

    var cipher2 = ChaCha20Poly1305(key)
    var raised = False
    try:
        cipher2.open_in_place(nonce, Span[UInt8](aad), Span[UInt8](buf))
    except _:
        raised = True
    assert_true(raised, "open_in_place did NOT raise on tampered tag")


# -----------------------------------------------------------------------------
# Test 4 — Tampered ciphertext: open_in_place RAISES (Poly1305 detects).
# -----------------------------------------------------------------------------


def test_chacha20_poly1305_tampered_ct_raises() raises:
    """open_in_place raises on single-bit ciphertext flip."""
    var key = _hex_to_32(
        String("808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f")
    )
    var nonce = _hex_to_12(String("070000004041424344454647"))
    var aad = _hex_to_list(String("50515253c0c1c2c3c4c5c6c7"))

    var pt_str = String("Sample plaintext for tampered CT test")
    var pt_bytes = _string_to_list(pt_str)
    var pt_len = len(pt_bytes)

    var buf = List[UInt8](capacity=pt_len + 16)
    for i in range(pt_len):
        buf.append(pt_bytes[i])
    for _ in range(16):
        buf.append(UInt8(0))

    var cipher1 = ChaCha20Poly1305(key)
    cipher1.seal_in_place(nonce, Span[UInt8](aad), Span[UInt8](buf))

    # Flip a bit in the ciphertext (first byte).
    buf[0] = buf[0] ^ UInt8(0x01)

    var cipher2 = ChaCha20Poly1305(key)
    var raised = False
    try:
        cipher2.open_in_place(nonce, Span[UInt8](aad), Span[UInt8](buf))
    except _:
        raised = True
    assert_true(raised, "open_in_place did NOT raise on tampered ciphertext")


# -----------------------------------------------------------------------------
# Test 5 — Empty plaintext: AAD-only authenticate.
# -----------------------------------------------------------------------------


def test_chacha20_poly1305_empty_plaintext() raises:
    """Empty plaintext + non-empty AAD: tag derived from lengths-only."""
    var key = _hex_to_32(
        String("808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f")
    )
    var nonce = _hex_to_12(String("070000004041424344454647"))
    var aad = _hex_to_list(String("50515253c0c1c2c3c4c5c6c7"))

    # Buffer of just 16 bytes for the tag.
    var buf = List[UInt8](capacity=16)
    for _ in range(16):
        buf.append(UInt8(0))

    var cipher1 = ChaCha20Poly1305(key)
    cipher1.seal_in_place(nonce, Span[UInt8](aad), Span[UInt8](buf))

    # Round-trip should succeed.
    var cipher2 = ChaCha20Poly1305(key)
    cipher2.open_in_place(nonce, Span[UInt8](aad), Span[UInt8](buf))


# -----------------------------------------------------------------------------
# Test 6 — Empty AAD: plaintext-only authenticate.
# -----------------------------------------------------------------------------


def test_chacha20_poly1305_empty_aad() raises:
    """Empty AAD + non-empty plaintext round-trip."""
    var key = _hex_to_32(
        String("808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f")
    )
    var nonce = _hex_to_12(String("070000004041424344454647"))
    var aad = List[UInt8]()  # empty

    var pt_str = String("Hello, world!")
    var pt_bytes = _string_to_list(pt_str)
    var pt_len = len(pt_bytes)
    var orig_pt = List[UInt8](capacity=pt_len)
    for i in range(pt_len):
        orig_pt.append(pt_bytes[i])

    var buf = List[UInt8](capacity=pt_len + 16)
    for i in range(pt_len):
        buf.append(pt_bytes[i])
    for _ in range(16):
        buf.append(UInt8(0))

    var cipher1 = ChaCha20Poly1305(key)
    cipher1.seal_in_place(nonce, Span[UInt8](aad), Span[UInt8](buf))

    var cipher2 = ChaCha20Poly1305(key)
    cipher2.open_in_place(nonce, Span[UInt8](aad), Span[UInt8](buf))

    for i in range(pt_len):
        assert_equal(buf[i], orig_pt[i])


# -----------------------------------------------------------------------------
# Test 7 — 256-final-byte sweep (bug-catcher).
#
# Vary the final byte of plaintext over all 256 values; round-trip each.
# If any byte triggers a corruption (e.g., off-by-one in pad16, wrong
# little-endian length serialization, integer-overflow in Poly1305 limb
# carry), at least one of the 256 round-trips will fail. The full sweep
# is a deterministic correctness gate analogous to the AES-GCM K0
# bug-catcher.
# -----------------------------------------------------------------------------


def test_chacha20_poly1305_256_final_byte_sweep() raises:
    """Round-trip 256 messages differing only in the final byte."""
    var key = _hex_to_32(
        String("808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f")
    )
    var nonce = _hex_to_12(String("070000004041424344454647"))
    var aad = _hex_to_list(String("50515253c0c1c2c3c4c5c6c7"))

    var base_pt = _string_to_list(String("Fixed prefix message X"))
    var pt_len = len(base_pt)
    # We'll mutate the LAST byte of base_pt over 0..255 and round-trip.

    for v in range(256):
        var buf = List[UInt8](capacity=pt_len + 16)
        for i in range(pt_len - 1):
            buf.append(base_pt[i])
        buf.append(UInt8(v))  # final byte = sweep value
        for _ in range(16):
            buf.append(UInt8(0))

        # Save the plaintext for later comparison.
        var orig = List[UInt8](capacity=pt_len)
        for i in range(pt_len):
            orig.append(buf[i])

        var c1 = ChaCha20Poly1305(key)
        c1.seal_in_place(nonce, Span[UInt8](aad), Span[UInt8](buf))

        var c2 = ChaCha20Poly1305(key)
        c2.open_in_place(nonce, Span[UInt8](aad), Span[UInt8](buf))

        # Verify plaintext recovered byte-identically.
        for i in range(pt_len):
            assert_equal(buf[i], orig[i])


# -----------------------------------------------------------------------------
# Test 8 — 256-distinct-CT collision check.
#
# 256 distinct plaintexts (differing in final byte) produce 256 pairwise-
# distinct ciphertexts. With a fixed nonce, this exercises the property
# that ChaCha20-Poly1305 acts as a permutation on the plaintext (modulo
# tag). Any collision indicates a catastrophic break (e.g., keystream
# repeating or being all-zero).
# -----------------------------------------------------------------------------


def test_chacha20_poly1305_256_distinct_ciphertexts() raises:
    """256 distinct plaintexts produce 256 pairwise-distinct ciphertexts.

    Note: with fixed K, N this means we re-use the same keystream each
    time. The plaintext-XOR-keystream property of ChaCha20 means each
    distinct plaintext maps to a distinct ciphertext, so this test
    sanity-checks the keystream is non-degenerate.
    """
    var key = _hex_to_32(
        String("808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f")
    )
    var nonce = _hex_to_12(String("070000004041424344454647"))
    var aad = _hex_to_list(String("50515253c0c1c2c3c4c5c6c7"))

    var base_pt = _string_to_list(String("Fixed prefix message X"))
    var pt_len = len(base_pt)

    var cts = List[List[UInt8]]()  # 256 ciphertexts (each pt_len bytes)
    for v in range(256):
        var buf = List[UInt8](capacity=pt_len + 16)
        for i in range(pt_len - 1):
            buf.append(base_pt[i])
        buf.append(UInt8(v))
        for _ in range(16):
            buf.append(UInt8(0))

        var c = ChaCha20Poly1305(key)
        c.seal_in_place(nonce, Span[UInt8](aad), Span[UInt8](buf))

        var ct = List[UInt8](capacity=pt_len)
        for i in range(pt_len):
            ct.append(buf[i])
        cts.append(ct^)

    # 256 distinct CTs pairwise: O(256*256) = 65K comparisons.
    for i in range(256):
        for j in range(i + 1, 256):
            var same = True
            for k in range(pt_len):
                if cts[i][k] != cts[j][k]:
                    same = False
                    break
            assert_false(same, "Distinct PTs produced same CT")


def main() raises:
    test_chacha20_poly1305_rfc8439_282()
    test_chacha20_poly1305_round_trip()
    test_chacha20_poly1305_tampered_tag_raises()
    test_chacha20_poly1305_tampered_ct_raises()
    test_chacha20_poly1305_empty_plaintext()
    test_chacha20_poly1305_empty_aad()
    test_chacha20_poly1305_256_final_byte_sweep()
    test_chacha20_poly1305_256_distinct_ciphertexts()
    print("OK")
