from std.ffi import external_call


def expect(ok: Bool, what: String) raises:
    if not ok:
        raise Error("test_aws_lc: " + what)


def same(a: List[UInt8], b: List[UInt8]) -> Bool:
    if len(a) != len(b):
        return False
    return external_call["memcmp", Int32](a.unsafe_ptr(), b.unsafe_ptr(), UInt64(len(a))) == 0


def main() raises:
    """Known-answer tests of aws-lc's libcrypto, called through its C API."""
    # aws-lc's own known-answer self tests (all of them, FIPS or not).
    expect(external_call["komira_awslc_BORINGSSL_self_test", Int32]() == 1, "BORINGSSL_self_test failed")
    print("BORINGSSL_self_test: ok")

    # SHA-256("abc"), FIPS 180-2 appendix B.1.
    var abc: List[UInt8] = [0x61, 0x62, 0x63]
    var digest = List[UInt8](length=32, fill=0)
    # SHA256 returns its output pointer; read as an address and ignored.
    _ = external_call["komira_awslc_SHA256", Int](abc.unsafe_ptr(), UInt64(3), digest.unsafe_ptr())
    var want_sha: List[UInt8] = [
        0xba, 0x78, 0x16, 0xbf, 0x8f, 0x01, 0xcf, 0xea, 0x41, 0x41, 0x40, 0xde,
        0x5d, 0xae, 0x22, 0x23, 0xb0, 0x03, 0x61, 0xa3, 0x96, 0x17, 0x7a, 0x9c,
        0xb4, 0x10, 0xff, 0x61, 0xf2, 0x00, 0x15, 0xad,
    ]
    expect(same(digest, want_sha), "SHA256(abc) differs from FIPS 180-2 B.1")
    print("SHA-256: ok")

    # AES-128, FIPS 197 appendix C.1.
    var key = List[UInt8](capacity=16)
    var block = List[UInt8](capacity=16)
    for i in range(16):
        key.append(UInt8(i))
        block.append(UInt8(i * 0x11))
    var aes_key = List[UInt8](length=512, fill=0)  # AES_KEY is 244 bytes
    expect(external_call["komira_awslc_AES_set_encrypt_key", Int32](key.unsafe_ptr(), UInt32(128), aes_key.unsafe_ptr()) == 0,
        "AES_set_encrypt_key failed")
    var out = List[UInt8](length=16, fill=0)
    external_call["komira_awslc_AES_encrypt", NoneType](block.unsafe_ptr(), out.unsafe_ptr(), aes_key.unsafe_ptr())
    var want_aes: List[UInt8] = [
        0x69, 0xc4, 0xe0, 0xd8, 0x6a, 0x7b, 0x04, 0x30, 0xd8, 0xcd, 0xb7, 0x80,
        0x70, 0xb4, 0xc5, 0x5a,
    ]
    expect(same(out, want_aes), "AES-128 differs from FIPS 197 C.1")
    print("AES-128: ok")

    # ChaCha20, RFC 8439 section 2.4.2 (key 00..1f, counter 1).
    var text = String("Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it.")
    var n = text.byte_length()
    var chacha_key = List[UInt8](capacity=32)
    for i in range(32):
        chacha_key.append(UInt8(i))
    var nonce: List[UInt8] = [0, 0, 0, 0, 0, 0, 0, 0x4A, 0, 0, 0, 0]
    var ct = List[UInt8](length=n, fill=0)
    external_call["komira_awslc_CRYPTO_chacha_20", NoneType](
        ct.unsafe_ptr(), text.unsafe_ptr(), UInt64(n), chacha_key.unsafe_ptr(), nonce.unsafe_ptr(), UInt32(1)
    )
    var want_chacha: List[UInt8] = [
        0x6e, 0x2e, 0x35, 0x9a, 0x25, 0x68, 0xf9, 0x80, 0x41, 0xba, 0x07, 0x28,
        0xdd, 0x0d, 0x69, 0x81, 0xe9, 0x7e, 0x7a, 0xec, 0x1d, 0x43, 0x60, 0xc2,
        0x0a, 0x27, 0xaf, 0xcc, 0xfd, 0x9f, 0xae, 0x0b, 0xf9, 0x1b, 0x65, 0xc5,
        0x52, 0x47, 0x33, 0xab, 0x8f, 0x59, 0x3d, 0xab, 0xcd, 0x62, 0xb3, 0x57,
        0x16, 0x39, 0xd6, 0x24, 0xe6, 0x51, 0x52, 0xab, 0x8f, 0x53, 0x0c, 0x35,
        0x9f, 0x08, 0x61, 0xd8, 0x07, 0xca, 0x0d, 0xbf, 0x50, 0x0d, 0x6a, 0x61,
        0x56, 0xa3, 0x8e, 0x08, 0x8a, 0x22, 0xb6, 0x5e, 0x52, 0xbc, 0x51, 0x4d,
        0x16, 0xcc, 0xf8, 0x06, 0x81, 0x8c, 0xe9, 0x1a, 0xb7, 0x79, 0x37, 0x36,
        0x5a, 0xf9, 0x0b, 0xbf, 0x74, 0xa3, 0x5b, 0xe6, 0xb4, 0x0b, 0x8e, 0xed,
        0xf2, 0x78, 0x5e, 0x42, 0x87, 0x4d,
    ]
    expect(same(ct, want_chacha), "ChaCha20 differs from RFC 8439 2.4.2")
    print("ChaCha20: ok")
