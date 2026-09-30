# =============================================================================
# komira_crypto/tests/test_ed25519_rfc8032.mojo
# =============================================================================
#
# Known-Answer Tests for Ed25519 per RFC 8032 §7.1. Validates:
#
#   1. RFC 8032 §7.1 TEST 1   — empty message.
#   2. RFC 8032 §7.1 TEST 2   — single-byte message (0x72).
#   3. RFC 8032 §7.1 TEST 3   — two-byte message (0xaf 0x82).
#   4. RFC 8032 §7.1 TEST 1024 — 1023-byte message.
#   5. RFC 8032 §7.1 TEST SHA(abc) — 64-byte SHA-512(abc) message.
#
# For each vector, asserts:
#   (i) pubkey derivation from seed matches the RFC's expected pubkey
#   (ii) sign(seed, msg) matches the RFC's expected sig byte-for-byte
#   (iii) verify(pubkey, msg, sig) returns True
#   (iv) verify with a single bit flipped in the sig returns False
#       (tamper-rejection sanity check)
#
# Source of vectors: RFC 8032 §7.1, the canonical Ed25519 spec. The
# vectors are the exact byte sequences from the RFC; each is hex-decoded
# inline so the test is self-contained.
#
# Implementation path: tests delegate to AWS-LC's ED25519_sign /
# ED25519_verify via `komira_crypto.ed25519` → `internal.asm.ed25519_ffi`.
# Since AWS-LC IS an Ed25519 implementation, these tests are confirming
# the FFI wiring + buffer marshalling, not re-validating Ed25519 itself.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_crypto.ed25519 import (
    ed25519_sign,
    ed25519_verify,
    ed25519_pubkey_from_seed,
    ed25519_keypair_generate,
)


# -----------------------------------------------------------------------------
# Hex helpers (mirrors test_x25519_kat.mojo).
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


def _hex_to_64(s: String) -> Array[UInt8, 64]:
    var out = Array[UInt8, 64](fill=UInt8(0))
    var bs = s.as_bytes()
    for i in range(64):
        var hi = _hex_nibble(bs[2 * i])
        var lo = _hex_nibble(bs[2 * i + 1])
        out[i] = (hi << UInt8(4)) | lo
    return out^


def _hex_to_list(s: String) -> List[UInt8]:
    """Decode an arbitrary-length hex string to List[UInt8]."""
    var bs = s.as_bytes()
    var n = len(bs) // 2
    var out = List[UInt8]()
    for i in range(n):
        var hi = _hex_nibble(bs[2 * i])
        var lo = _hex_nibble(bs[2 * i + 1])
        out.append((hi << UInt8(4)) | lo)
    return out^


def _assert_bytes_eq_32(
    got: Array[UInt8, 32],
    expected: Array[UInt8, 32],
    label: String,
) raises:
    for i in range(32):
        if got[i] != expected[i]:
            print("MISMATCH at byte", i, "for", label)
            print("  got: ", Int(got[i]), "  expected: ", Int(expected[i]))
            assert_equal(Int(got[i]), Int(expected[i]), label)


def _assert_bytes_eq_64(
    got: Array[UInt8, 64],
    expected: Array[UInt8, 64],
    label: String,
) raises:
    for i in range(64):
        if got[i] != expected[i]:
            print("MISMATCH at byte", i, "for", label)
            print("  got: ", Int(got[i]), "  expected: ", Int(expected[i]))
            assert_equal(Int(got[i]), Int(expected[i]), label)


# -----------------------------------------------------------------------------
# Shared assertion helper for the per-vector test body.
# -----------------------------------------------------------------------------


def _run_kat(
    seed: Array[UInt8, 32],
    expected_pubkey: Array[UInt8, 32],
    msg: List[UInt8],
    expected_sig: Array[UInt8, 64],
    label: String,
) raises:
    """Run all four KAT assertions for one RFC 8032 §7.1 test vector."""
    # (i) pubkey derivation matches RFC expectation
    var seed_span = Span[UInt8, origin_of(seed)](seed)
    var got_pubkey = ed25519_pubkey_from_seed(seed_span)
    _assert_bytes_eq_32(got_pubkey, expected_pubkey, label + " — pubkey from seed")

    # (ii) sign produces byte-identical RFC-expected signature
    # (Ed25519 is deterministic by construction per RFC 8032 §5.1.6)
    var msg_span = Span[UInt8, origin_of(msg)](msg)
    var got_sig = ed25519_sign(seed_span, msg_span)
    _assert_bytes_eq_64(got_sig, expected_sig, label + " — deterministic sign")

    # (iii) verify returns True on the valid signature
    var pubkey_span = Span[UInt8, origin_of(expected_pubkey)](expected_pubkey)
    var sig_span = Span[UInt8, origin_of(got_sig)](got_sig)
    var ok = ed25519_verify(pubkey_span, msg_span, sig_span)
    assert_true(ok, label + " — verify(valid) returns True")

    # (iv) flip a bit in the sig, verify returns False
    var tampered_sig = Array[UInt8, 64](fill=UInt8(0))
    for i in range(64):
        tampered_sig[i] = got_sig[i]
    tampered_sig[63] = tampered_sig[63] ^ UInt8(0x01)
    var tampered_span = Span[UInt8, origin_of(tampered_sig)](tampered_sig)
    var ok_tamper = ed25519_verify(pubkey_span, msg_span, tampered_span)
    assert_false(ok_tamper, label + " — verify(tampered) returns False")


# -----------------------------------------------------------------------------
# Test 1: RFC 8032 §7.1 TEST 1 — empty message.
# -----------------------------------------------------------------------------


def test_rfc8032_test_1_empty_message() raises:
    """RFC 8032 §7.1 TEST 1: empty message."""
    var seed = _hex_to_32(
        "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60"
    )
    var pubkey = _hex_to_32(
        "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a"
    )
    var msg = List[UInt8]()  # empty
    var sig = _hex_to_64(
        "e5564300c360ac729086e2cc806e828a"
        "84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46b"
        "d25bf5f0595bbe24655141438e7a100b"
    )
    _run_kat(seed, pubkey, msg, sig, "RFC 8032 §7.1 TEST 1 (empty)")


# -----------------------------------------------------------------------------
# Test 2: RFC 8032 §7.1 TEST 2 — single-byte message.
# -----------------------------------------------------------------------------


def test_rfc8032_test_2_single_byte() raises:
    """RFC 8032 §7.1 TEST 2: single-byte message 0x72."""
    var seed = _hex_to_32(
        "4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb"
    )
    var pubkey = _hex_to_32(
        "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c"
    )
    var msg = List[UInt8]()
    msg.append(UInt8(0x72))
    var sig = _hex_to_64(
        "92a009a9f0d4cab8720e820b5f642540"
        "a2b27b5416503f8fb3762223ebdb69da085ac1e43e15996e458f3613d0f11d8c"
        "387b2eaeb4302aeeb00d291612bb0c00"
    )
    _run_kat(seed, pubkey, msg, sig, "RFC 8032 §7.1 TEST 2 (1 byte)")


# -----------------------------------------------------------------------------
# Test 3: RFC 8032 §7.1 TEST 3 — two-byte message.
# -----------------------------------------------------------------------------


def test_rfc8032_test_3_two_bytes() raises:
    """RFC 8032 §7.1 TEST 3: two-byte message 0xaf 0x82."""
    var seed = _hex_to_32(
        "c5aa8df43f9f837bedb7442f31dcb7b166d38535076f094b85ce3a2e0b4458f7"
    )
    var pubkey = _hex_to_32(
        "fc51cd8e6218a1a38da47ed00230f0580816ed13ba3303ac5deb911548908025"
    )
    var msg = List[UInt8]()
    msg.append(UInt8(0xaf))
    msg.append(UInt8(0x82))
    var sig = _hex_to_64(
        "6291d657deec24024827e69c3abe01a3"
        "0ce548a284743a445e3680d7db5ac3ac18ff9b538d16f290ae67f760984dc659"
        "4a7c15e9716ed28dc027beceea1ec40a"
    )
    _run_kat(seed, pubkey, msg, sig, "RFC 8032 §7.1 TEST 3 (2 bytes)")


# -----------------------------------------------------------------------------
# Test 4: RFC 8032 §7.1 TEST 1024 — 1023-byte message.
# -----------------------------------------------------------------------------


def test_rfc8032_test_1024_long_message() raises:
    """RFC 8032 §7.1 TEST 1024: 1023-byte message (exercises chunked SHA-512 path).

    The full 1023-byte message is the concatenated test vector from RFC
    8032 §7.1 TEST 1024 (verbatim hex).
    """
    var seed = _hex_to_32(
        "f5e5767cf153319517630f226876b86c8160cc583bc013744c6bf255f5cc0ee5"
    )
    var pubkey = _hex_to_32(
        "278117fc144c72340f67d0f2316e8386ceffbf2b2428c9c51fef7c597f1d426e"
    )
    # 1023-byte msg from RFC 8032 §7.1 TEST 1024.
    var msg = _hex_to_list(
        "08b8b2b733424243760fe426a4b54908"
        "632110a66c2f6591eabd3345e3e4eb98fa6e264bf09efe12ee50f8f54e9f77b1"
        "e355f6c50544e23fb1433ddf73be84d879de7c0046dc4996d9e773f4bc9efe57"
        "38829adb26c81b37c93a1b270b20329d658675fc6ea534e0810a4432826bf58c"
        "941efb65d57a338bbd2e26640f89ffbc1a858efcb8550ee3a5e1998bd177e93a"
        "7363c344fe6b199ee5d02e82d522c4feba15452f80288a821a579116ec6dad2b"
        "3b310da903401aa62100ab5d1a36553e06203b33890cc9b832f79ef80560ccb9"
        "a39ce767967ed628c6ad573cb116dbefefd75499da96bd68a8a97b928a8bbc10"
        "3b6621fcde2beca1231d206be6cd9ec7aff6f6c94fcd7204ed3455c68c83f4a4"
        "1da4af2b74ef5c53f1d8ac70bdcb7ed185ce81bd84359d44254d95629e9855a9"
        "4a7c1958d1f8ada5d0532ed8a5aa3fb2d17ba70eb6248e594e1a2297acbbb39d"
        "502f1a8c6eb6f1ce22b3de1a1f40cc24554119a831a9aad6079cad88425de6bd"
        "e1a9187ebb6092cf67bf2b13fd65f27088d78b7e883c8759d2c4f5c65adb7553"
        "878ad575f9fad878e80a0c9ba63bcbcc2732e69485bbc9c90bfbd62481d9089b"
        "eccf80cfe2df16a2cf65bd92dd597b0707e0917af48bbb75fed413d238f5555a"
        "7a569d80c3414a8d0859dc65a46128bab27af87a71314f318c782b23ebfe808b"
        "82b0ce26401d2e22f04d83d1255dc51addd3b75a2b1ae0784504df543af8969b"
        "e3ea7082ff7fc9888c144da2af58429ec96031dbcad3dad9af0dcbaaaf268cb8"
        "fcffead94f3c7ca495e056a9b47acdb751fb73e666c6c655ade8297297d07ad1"
        "ba5e43f1bca32301651339e22904cc8c42f58c30c04aafdb038dda0847dd988d"
        "cda6f3bfd15c4b4c4525004aa06eeff8ca61783aacec57fb3d1f92b0fe2fd1a8"
        "5f6724517b65e614ad6808d6f6ee34dff7310fdc82aebfd904b01e1dc54b2927"
        "094b2db68d6f903b68401adebf5a7e08d78ff4ef5d63653a65040cf9bfd4aca7"
        "984a74d37145986780fc0b16ac451649de6188a7dbdf191f64b5fc5e2ab47b57"
        "f7f7276cd419c17a3ca8e1b939ae49e488acba6b965610b5480109c8b17b80e1"
        "b7b750dfc7598d5d5011fd2dcc5600a32ef5b52a1ecc820e308aa342721aac09"
        "43bf6686b64b2579376504ccc493d97e6aed3fb0f9cd71a43dd497f01f17c0e2"
        "cb3797aa2a2f256656168e6c496afc5fb93246f6b1116398a346f1a641f3b041"
        "e989f7914f90cc2c7fff357876e506b50d334ba77c225bc307ba537152f3f161"
        "0e4eafe595f6d9d90d11faa933a15ef1369546868a7f3a45a96768d40fd9d034"
        "12c091c6315cf4fde7cb68606937380db2eaaa707b4c4185c32eddcdd306705e"
        "4dc1ffc872eeee475a64dfac86aba41c0618983f8741c5ef68d3a101e8a3b8ca"
        "c60c905c15fc910840b94c00a0b9d0"
    )
    var sig = _hex_to_64(
        "0aab4c900501b3e24d7cdf4663326a3a"
        "87df5e4843b2cbdb67cbf6e460fec350aa5371b1508f9f4528ecea23c436d94b"
        "5e8fcd4f681e30a6ac00a9704a188a03"
    )
    _run_kat(seed, pubkey, msg, sig, "RFC 8032 §7.1 TEST 1024 (1023 bytes)")


# -----------------------------------------------------------------------------
# Test 5: RFC 8032 §7.1 TEST SHA(abc) — 64-byte SHA-512(abc) message.
# -----------------------------------------------------------------------------


def test_rfc8032_test_sha_abc() raises:
    """RFC 8032 §7.1 TEST SHA(abc): 64-byte SHA-512(abc) message."""
    var seed = _hex_to_32(
        "833fe62409237b9d62ec77587520911e9a759cec1d19755b7da901b96dca3d42"
    )
    var pubkey = _hex_to_32(
        "ec172b93ad5e563bf4932c70e1245034c35467ef2efd4d64ebf819683467e2bf"
    )
    var msg = _hex_to_list(
        "ddaf35a193617abacc417349ae204131"
        "12e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd"
        "454d4423643ce80e2a9ac94fa54ca49f"
    )
    var sig = _hex_to_64(
        "dc2a4459e7369633a52b1bf277839a00"
        "201009a3efbf3ecb69bea2186c26b58909351fc9ac90b3ecfdfbc7c66431e030"
        "3dca179c138ac17ad9bef1177331a704"
    )
    _run_kat(seed, pubkey, msg, sig, "RFC 8032 §7.1 TEST SHA(abc) (64 bytes)")


# -----------------------------------------------------------------------------
# Test 6: keypair_generate produces a self-consistent (seed, pubkey) pair.
#
# Not from the RFC — this is a smoke test on the CSPRNG path. We verify
# that the generated keypair satisfies pubkey == pubkey_from_seed(seed)
# (round-trip property), and that sign+verify with the generated pair
# is internally consistent.
# -----------------------------------------------------------------------------


def test_keypair_generate_roundtrip() raises:
    """Generated keypair satisfies pubkey == pubkey_from_seed(seed) and
    sign/verify with that pair is internally consistent."""
    var pair = ed25519_keypair_generate()
    var seed = pair[0].copy()
    var pubkey = pair[1].copy()

    # (a) Round-trip: pubkey must match deterministic derivation from seed
    var seed_span = Span[UInt8, origin_of(seed)](seed)
    var derived = ed25519_pubkey_from_seed(seed_span)
    _assert_bytes_eq_32(
        derived, pubkey, "generated pubkey == pubkey_from_seed(seed)"
    )

    # (b) sign/verify smoke test
    var msg = List[UInt8]()
    for i in range(64):
        msg.append(UInt8(i))
    var msg_span = Span[UInt8, origin_of(msg)](msg)
    var sig = ed25519_sign(seed_span, msg_span)
    var pubkey_span = Span[UInt8, origin_of(pubkey)](pubkey)
    var sig_span = Span[UInt8, origin_of(sig)](sig)
    var ok = ed25519_verify(pubkey_span, msg_span, sig_span)
    assert_true(ok, "generated keypair sign/verify round-trip")


def main() raises:
    print("== test_ed25519_rfc8032 ==")
    test_rfc8032_test_1_empty_message()
    print("  RFC 8032 §7.1 TEST 1 (empty)              PASS")
    test_rfc8032_test_2_single_byte()
    print("  RFC 8032 §7.1 TEST 2 (1 byte)             PASS")
    test_rfc8032_test_3_two_bytes()
    print("  RFC 8032 §7.1 TEST 3 (2 bytes)            PASS")
    test_rfc8032_test_1024_long_message()
    print("  RFC 8032 §7.1 TEST 1024 (1023 bytes)      PASS")
    test_rfc8032_test_sha_abc()
    print("  RFC 8032 §7.1 TEST SHA(abc) (64 bytes)    PASS")
    test_keypair_generate_roundtrip()
    print("  ed25519_keypair_generate round-trip       PASS")
    print("ALL 6 Ed25519 RFC 8032 tests PASS")
