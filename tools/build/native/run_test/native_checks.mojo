# The calls the run test of libkomira_native.so.1 makes through it (README.md,
# "One shared library"; native_run.sh runs the programs that import this).
#
# Every name called here is an export of libkomira_native.so.1: aws-lc's API
# as komira_awslc_*, s2n-tls's as komira_s2n_*, snappy's C API as
# komira_snappy_*. A handle C returns is held as an Int (a pointer-sized
# integer, passed back the same way), so no pointer type is named.
#
# Each check prints `CHECK <name> PASS|FAIL <detail>` and returns whether it
# passed. Output is flushed per line: a later crash must not lose it.
from std.ffi import external_call
from native_util import bytes_of, from_hex, hex_of, report, same


def check_sha256() -> Bool:
    """FIPS 180-2's example: SHA-256("abc")."""
    var msg = bytes_of("abc")
    var out = List[UInt8](length=32, fill=0)
    _ = external_call["komira_awslc_SHA256", Int](msg.unsafe_ptr(), UInt(len(msg)), out.unsafe_ptr())
    # Keep the input alive past the call: the pointer does not.
    _ = len(msg)
    var want = from_hex("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    return report("awslc_sha256_abc", same(Span(out), Span(want)), "komira_awslc_SHA256; got " + hex_of(Span(out)))


def check_aead() -> Bool:
    """AES-256-GCM seal, the GCM spec's test case 14: zero key, zero nonce, 16 zero bytes."""
    var key = List[UInt8](length=32, fill=0)
    var nonce = List[UInt8](length=12, fill=0)
    var pt = List[UInt8](length=16, fill=0)
    var ad = List[UInt8](length=1, fill=0)  # no additional data: its length below is 0
    var aead = external_call["komira_awslc_EVP_aead_aes_256_gcm", Int]()
    var ctx = external_call["komira_awslc_EVP_AEAD_CTX_new", Int](aead, key.unsafe_ptr(), UInt(32), UInt(16))
    if ctx == 0:
        return report("awslc_aes256gcm_seal", False, "komira_awslc_EVP_AEAD_CTX_new returned NULL")
    var out = List[UInt8](length=32, fill=0)
    var out_len = List[UInt](length=1, fill=UInt(0))
    var rc = external_call["komira_awslc_EVP_AEAD_CTX_seal", Int32](
        ctx,
        out.unsafe_ptr(),
        out_len.unsafe_ptr(),
        UInt(32),
        nonce.unsafe_ptr(),
        UInt(12),
        pt.unsafe_ptr(),
        UInt(16),
        ad.unsafe_ptr(),
        UInt(0),
    )
    external_call["komira_awslc_EVP_AEAD_CTX_free", NoneType](ctx)
    _ = len(key) + len(nonce) + len(pt) + len(ad)  # keep-alive, as in check_sha256
    var want = from_hex("cea7403d4d606b6e074ec5d3baf39d18d0d1c8a799996bf0265b98b5d48ab919")
    var ok = rc == 1 and out_len[0] == UInt(32) and same(Span(out), Span(want))
    return report(
        "awslc_aes256gcm_seal",
        ok,
        "komira_awslc_EVP_AEAD_CTX_seal; rc " + String(rc) + " len " + String(Int(out_len[0])) + " got " + hex_of(Span(out)),
    )


def _snappy_compress(src: Span[UInt8, _], mut dst: List[UInt8]) -> Int:
    """Compresses into dst (its length is the capacity); the length, or -1."""
    var n = List[UInt](length=1, fill=UInt(len(dst)))
    var rc = external_call["komira_snappy_compress", Int32](src.unsafe_ptr(), UInt(len(src)), dst.unsafe_ptr(), n.unsafe_ptr())
    _ = len(src)  # keep-alive
    return Int(n[0]) if rc == 0 else -1


def check_snappy() -> Bool:
    """The compression of "abc" is varint 3, a literal tag, "abc"; then a 4096-byte round trip."""
    var small = bytes_of("abc")
    var c1 = List[UInt8](length=64, fill=0)
    var c1_len = _snappy_compress(Span(small), c1)
    var want = from_hex("0308616263")
    var kat = c1_len == 5 and same(Span(c1)[0:5], Span(want))
    _ = report("snappy_compress_abc", kat, "komira_snappy_compress; length " + String(c1_len))

    var big = List[UInt8](capacity=4096)
    for i in range(4096):
        big.append(UInt8(0x61 + (i % 7)))
    var comp = List[UInt8](length=8192, fill=0)
    var comp_len = _snappy_compress(Span(big), comp)
    var ulen = List[UInt](length=1, fill=UInt(0))
    var rc_len = external_call["komira_snappy_uncompressed_length", Int32](comp.unsafe_ptr(), UInt(comp_len), ulen.unsafe_ptr())
    var back = List[UInt8](length=4096, fill=0)
    var back_len = List[UInt](length=1, fill=UInt(4096))
    var rc_un = external_call["komira_snappy_uncompress", Int32](comp.unsafe_ptr(), UInt(comp_len), back.unsafe_ptr(), back_len.unsafe_ptr())
    _ = len(comp)  # keep-alive
    var rt = comp_len > 0 and comp_len < 4096 and rc_len == 0 and Int(ulen[0]) == 4096 and rc_un == 0
    rt = rt and Int(back_len[0]) == 4096 and same(Span(back), Span(big))
    var rt_ok = report(
        "snappy_roundtrip_4096",
        rt,
        "compressed to " + String(comp_len) + " bytes; uncompressed_length rc " + String(rc_len) + ", uncompress rc " + String(rc_un),
    )
    return kat and rt_ok


def check_s2n() -> Bool:
    """The s2n-tls calls: init, a config with the TLS 1.3 preferences, a client connection using it."""
    var rc_init = external_call["komira_s2n_init", Int32]()
    var cfg = external_call["komira_s2n_config_new", Int]()
    var pref = String("default_tls13")
    var rc_pref = external_call["komira_s2n_config_set_cipher_preferences", Int32](cfg, pref.as_c_string_slice().unsafe_ptr())
    _ = pref.byte_length()  # keep-alive: s2n reads the name during the call only
    var conn = external_call["komira_s2n_connection_new", Int](Int32(1))  # S2N_CLIENT
    var rc_set = external_call["komira_s2n_connection_set_config", Int32](conn, cfg)
    var rc_cfree = external_call["komira_s2n_connection_free", Int32](conn)
    var rc_free = external_call["komira_s2n_config_free", Int32](cfg)
    var ok = rc_init == 0 and cfg != 0 and rc_pref == 0 and conn != 0 and rc_set == 0 and rc_cfree == 0 and rc_free == 0
    return report(
        "s2n_config_and_connection",
        ok,
        "komira_s2n_init " + String(rc_init) + ", set_cipher_preferences(default_tls13) " + String(rc_pref) + ", connection_set_config " + String(rc_set),
    )
