# knative: the probe's calls into libkomira_native.so.1 (EXPERIMENT, branch
# exp/native-probe-2, never merged; see ../BUCK).
#
# Every name called here is an export of libkomira_native.so.1: aws-lc's API
# under the prefix komira_awslc_, snappy's C API renamed komira_snappy_*. The
# package carries no native code; a consumer links the shared object.
#
# Each check prints `CHECK <name> PASS|FAIL <detail>` and returns whether it
# passed. Output is flushed per line: a later crash must not lose it.
from std.ffi import OwnedDLHandle, external_call
from std.memory import UnsafePointer, alloc

comptime _O = ImmStaticOrigin
comptime _Byte = UnsafePointer[UInt8, _O]
comptime _Handle = UnsafePointer[NoneType, _O]
comptime _Raw = UnsafePointer[NoneType, MutUntrackedOrigin]

comptime RTLD_NOW: Int32 = 2
comptime RTLD_NOLOAD: Int32 = 4
comptime RTLD_GLOBAL: Int32 = 0x100


@always_inline
def _p(s: Span[UInt8, _]) -> _Byte:
    # SAFETY: the caller holds the buffer across the synchronous call; no C
    # function called in this file keeps the pointer.
    return s.unsafe_ptr().unsafe_mut_cast[False]().unsafe_origin_cast[_O]()


@always_inline
def _pm(s: Span[UInt8, _]) -> UnsafePointer[UInt8, MutUntrackedOrigin]:
    # An output buffer: a mutable pointer, so the compiler cannot assume the
    # call leaves the bytes unchanged.
    # SAFETY: the caller holds the buffer across the synchronous call.
    return s.unsafe_ptr().unsafe_mut_cast[True]().unsafe_origin_cast[MutUntrackedOrigin]()


def _nibble(c: UInt8) -> UInt8:
    if c >= UInt8(0x30) and c <= UInt8(0x39):
        return c - UInt8(0x30)
    if c >= UInt8(0x61) and c <= UInt8(0x66):
        return c - UInt8(0x61) + UInt8(10)
    return UInt8(0xFF)


def from_hex(s: String) -> List[UInt8]:
    var bs = s.as_bytes()
    var out = List[UInt8](capacity=len(bs) // 2)
    for i in range(len(bs) // 2):
        out.append((_nibble(bs[2 * i]) << UInt8(4)) | _nibble(bs[2 * i + 1]))
    return out^


def bytes_of(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var src = s.as_bytes()
    for i in range(len(src)):
        out.append(src[i])
    return out^


def _hexd(v: Int) -> String:
    if v < 10:
        return chr(0x30 + v)
    return chr(0x61 + v - 10)


def hex_of(b: Span[UInt8, _]) -> String:
    var out = String()
    for i in range(len(b)):
        out += _hexd(Int(b[i]) >> 4)
        out += _hexd(Int(b[i]) & 0xF)
    return out^


def _same(a: Span[UInt8, _], b: Span[UInt8, _]) -> Bool:
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i] != b[i]:
            return False
    return True


def _report(name: String, ok: Bool, detail: String) -> Bool:
    print("CHECK", name, "PASS" if ok else "FAIL", detail, flush=True)
    return ok


def sha256(data: Span[UInt8, _]) -> List[UInt8]:
    var out = List[UInt8](length=32, fill=0)
    _ = external_call["komira_awslc_SHA256", _Byte](
        _p(data), UInt(len(data)), _pm(Span(out))
    )
    return out^


def check_sha256() -> Bool:
    """FIPS 180-2 example: SHA-256("abc")."""
    var msg = bytes_of("abc")
    var got = sha256(Span(msg))
    var want = from_hex("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    return _report("awslc_sha256_abc", _same(Span(got), Span(want)), "komira_awslc_SHA256")


def check_aead() raises -> Bool:
    """AES-256-GCM seal, GCM spec test case 14: zero key, zero nonce, 16 zero bytes."""
    var key = List[UInt8](length=32, fill=0)
    var nonce = List[UInt8](length=12, fill=0)
    var pt = List[UInt8](length=16, fill=0)
    var ad = List[UInt8](length=1, fill=0)
    var aead = external_call["komira_awslc_EVP_aead_aes_256_gcm", _Handle]()
    var ctx = external_call["komira_awslc_EVP_AEAD_CTX_new", _Handle, _Handle, _Byte, UInt, UInt](
        aead, _p(Span(key)), UInt(32), UInt(16)
    )
    if Int(ctx) == 0:
        return _report("awslc_aes256gcm_seal", False, "EVP_AEAD_CTX_new returned NULL")
    var out = List[UInt8](length=32, fill=0)
    # Out-parameters live on the heap (komira_compression's pattern): C
    # writes them, so they must not be values the compiler may keep in registers.
    var out_len = alloc[UInt](1)
    out_len[0] = UInt(0)
    # SAFETY: every buffer outlives the synchronous call; aws-lc keeps none.
    var rc = external_call["komira_awslc_EVP_AEAD_CTX_seal", Int32](
        ctx,
        _pm(Span(out)),
        out_len,
        UInt(32),
        _p(Span(nonce)),
        UInt(12),
        _p(Span(pt)),
        UInt(16),
        _p(Span(ad)),
        UInt(0),
    )
    external_call["komira_awslc_EVP_AEAD_CTX_free", NoneType, _Handle](ctx)
    # Keep the inputs alive past the calls: _p erases their origin, so
    # without a later use Mojo may destroy them before C reads them.
    _ = len(key) + len(nonce) + len(pt) + len(ad)
    var sealed_len = out_len[0]
    out_len.free()
    var want = from_hex("cea7403d4d606b6e074ec5d3baf39d18d0d1c8a799996bf0265b98b5d48ab919")
    var ok = rc == 1 and sealed_len == UInt(32) and _same(Span(out), Span(want))
    return _report(
        "awslc_aes256gcm_seal",
        ok,
        "komira_awslc_EVP_AEAD_CTX_seal, GCM test case 14; rc " + String(rc) + " len " + String(Int(sealed_len)) + " got " + hex_of(Span(out)),
    )


def _snappy_compress(src: Span[UInt8, _], mut dst: List[UInt8]) -> Int:
    """Compress into dst (its length is the capacity); returns the length, or -1."""
    var n = alloc[UInt](1)
    n[0] = UInt(len(dst))
    # SAFETY: src and dst outlive the synchronous call; snappy keeps neither.
    var rc = external_call["komira_snappy_compress", Int32](_p(src), UInt(len(src)), _pm(Span(dst)), n)
    var got = Int(n[0])
    n.free()
    _ = len(src) + len(dst)  # keep-alive, as in check_aead
    return got if rc == 0 else -1


def check_snappy() -> Bool:
    """snappy_compress("abc") is varint 3, a literal tag, "abc"; then a round trip."""
    var small = bytes_of("abc")
    var c1 = List[UInt8](length=64, fill=0)
    var c1_len = _snappy_compress(Span(small), c1)
    var want = from_hex("0308616263")
    _ = len(small)  # keep-alive, as in check_aead
    var kat = c1_len == 5 and _same(Span(c1)[0:5], Span(want))
    _ = _report("snappy_compress_abc", kat, "komira_snappy_compress; length " + String(c1_len))

    var big = List[UInt8](capacity=4096)
    for i in range(4096):
        big.append(UInt8(0x61 + (i % 7)))
    var comp = List[UInt8](length=8192, fill=0)
    var comp_len = _snappy_compress(Span(big), comp)
    var ulen = alloc[UInt](1)
    ulen[0] = UInt(0)
    # SAFETY: as in _snappy_compress.
    var rc3 = external_call["komira_snappy_uncompressed_length", Int32](_p(Span(comp)), UInt(comp_len), ulen)
    var back = List[UInt8](length=4096, fill=0)
    var back_len = alloc[UInt](1)
    back_len[0] = UInt(4096)
    # SAFETY: as in _snappy_compress.
    var rc4 = external_call["komira_snappy_uncompress", Int32](_p(Span(comp)), UInt(comp_len), _pm(Span(back)), back_len)
    var rt = comp_len > 0 and comp_len < 4096 and rc3 == 0 and Int(ulen[0]) == 4096 and rc4 == 0 and Int(
        back_len[0]
    ) == 4096 and _same(Span(back), Span(big))
    ulen.free()
    back_len.free()
    _ = len(comp) + len(back) + len(big)  # keep-alive, as in check_aead
    var rt_ok = _report(
        "snappy_roundtrip_4096",
        rt,
        "compressed to " + String(comp_len) + " bytes; uncompressed_length rc " + String(rc3) + " uncompress rc " + String(rc4) + " first bytes back " + hex_of(Span(back)[0:8]) + " in " + hex_of(Span(big)[0:8]),
    )
    return kat and rt_ok


def check_s2n() raises -> Bool:
    """s2n-tls through the shared object: init, a config with TLS 1.3 preferences, a client connection."""
    var rc_init = external_call["komira_s2n_init", Int32]()
    var cfg = external_call["komira_s2n_config_new", _Raw]()
    var pref = String("default_tls13")
    # SAFETY: `pref` owns the NUL-terminated buffer past the synchronous call;
    # s2n looks the name up and keeps no pointer to it.
    var rc_pref = external_call["komira_s2n_config_set_cipher_preferences", Int32](
        cfg, pref.as_c_string_slice().unsafe_ptr()
    )
    _ = pref.byte_length()
    var conn = external_call["komira_s2n_connection_new", _Raw](Int32(1))  # S2N_CLIENT
    var rc_set = external_call["komira_s2n_connection_set_config", Int32](conn, cfg)
    var rc_cfree = external_call["komira_s2n_connection_free", Int32](conn)
    var rc_free = external_call["komira_s2n_config_free", Int32](cfg)
    var ok = rc_init == 0 and Int(cfg) != 0 and rc_pref == 0 and Int(conn) != 0 and rc_set == 0 and rc_cfree == 0 and rc_free == 0
    return _report(
        "s2n_config_and_connection",
        ok,
        "komira_s2n_init " + String(rc_init) + ", set_cipher_preferences(default_tls13) " + String(rc_pref) + ", connection_set_config " + String(rc_set),
    )


# ---- interposition ------------------------------------------------------------


def _null_raw() -> _Raw:
    """RTLD_DEFAULT (a NULL handle), without the banned address constructor.

    SAFETY: Optional[UnsafePointer] is layout-compatible with the pointer and
    None is the all-zero pattern (komira_crypto's _ffi_null does the same).
    """
    var none: Optional[_Raw] = None
    return UnsafePointer(to=none).bitcast[_Raw]()[]


# dlopen and dlsym are called through a handle on libc, not external_call: the
# standard library's OwnedDLHandle declares them itself, and a second
# declaration from this module fails to lower ("existing function with
# conflicting signature").
def _dlopen(name: String, flags: Int32) raises -> _Raw:
    var libc = OwnedDLHandle("libc.so.6")
    var n = name
    # SAFETY: `n` owns the NUL-terminated buffer past the synchronous call.
    var h = libc.call["dlopen", _Raw](n.as_c_string_slice().unsafe_ptr(), flags)
    _ = n.byte_length()
    return h


def _dlsym(handle: _Raw, name: String) raises -> Int:
    var libc = OwnedDLHandle("libc.so.6")
    var n = name
    # SAFETY: as in _dlopen. A NULL handle is RTLD_DEFAULT (the global scope).
    var p = libc.call["dlsym", _Raw](handle, n.as_c_string_slice().unsafe_ptr())
    _ = n.byte_length()
    return Int(p)


def load_system_openssl() raises -> Bool:
    """dlopen the system libcrypto.so.3 and libssl.so.3 RTLD_GLOBAL and call into each.

    Returns False (and says so) when the worker has no libcrypto.so.3.
    """
    var before = _dlopen("libcrypto.so.3", RTLD_NOW | RTLD_NOLOAD)
    print("INFO libcrypto.so.3 already loaded before dlopen:", Int(before) != 0, flush=True)
    var hc = _dlopen("libcrypto.so.3", RTLD_NOW | RTLD_GLOBAL)
    if Int(hc) == 0:
        print("INFO SYSTEM_LIBCRYPTO absent: dlopen(libcrypto.so.3) failed", flush=True)
        return False
    var hs = _dlopen("libssl.so.3", RTLD_NOW | RTLD_GLOBAL)
    print("INFO system libcrypto.so.3 handle", hex(Int(hc)), "libssl.so.3 handle", hex(Int(hs)), flush=True)
    var crypto = OwnedDLHandle("libcrypto.so.3")
    var ver = crypto.call["OpenSSL_version_num", UInt]()
    _ = _report("system_openssl_version_num", ver >= UInt(0x30000000), "OpenSSL_version_num=" + hex(Int(ver)))
    var msg = bytes_of("abc")
    var out = List[UInt8](length=32, fill=0)
    _ = crypto.call["SHA256", _Byte](_p(Span(msg)), UInt(3), _pm(Span(out)))
    _ = len(msg)  # keep-alive, as in check_aead
    var want = from_hex("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    _ = _report("system_sha256_abc", _same(Span(out), Span(want)), "system libcrypto SHA256")
    return True


def check_interposition(our_soname: String, expect_safe: Bool) raises -> Bool:
    """Whether the global scope still resolves OpenSSL names to the system library.

    For each name: G = dlsym(RTLD_DEFAULT), S = dlsym(system libcrypto), M =
    dlsym(our library). Safe means G == S and M == 0 (we export none of them).
    The leaky control library exports them and comes first in the global scope,
    so there G == M != S.
    """
    var hc = _dlopen("libcrypto.so.3", RTLD_NOW | RTLD_NOLOAD)
    var hm = _dlopen(our_soname, RTLD_NOW | RTLD_NOLOAD)
    print("INFO our library", our_soname, "handle", hex(Int(hm)), flush=True)
    var names = List[String]()
    names.append("SHA256")
    names.append("EVP_sha256")
    names.append("EVP_AEAD_CTX_seal")
    names.append("RAND_bytes")
    names.append("snappy_compress")
    var safe = True
    for i in range(len(names)):
        var g = _dlsym(_null_raw(), names[i])
        var s = _dlsym(hc, names[i]) if Int(hc) != 0 else 0
        var m = _dlsym(hm, names[i]) if Int(hm) != 0 else 0
        var ok = m == 0 and g == s
        safe = safe and ok
        print(
            "INFO",
            names[i],
            "global",
            hex(g),
            "system",
            hex(s),
            "ours",
            hex(m),
            "->",
            "not interposed" if ok else "INTERPOSED-OR-LEAKED",
            flush=True,
        )
    var k = _dlsym(_null_raw(), "komira_awslc_SHA256")
    print("INFO komira_awslc_SHA256 in global scope:", hex(k), flush=True)
    return _report(
        "interposition_" + ("safe" if expect_safe else "control_leaks"),
        safe == expect_safe,
        "global scope " + ("safe" if safe else "interposed"),
    )


def system_ssl_ctx() raises -> Bool:
    """Make and free an SSL_CTX in the system libssl: its libcrypto calls go through the global scope."""
    var ssl = OwnedDLHandle("libssl.so.3")
    var method = ssl.call["TLS_method", Int]()
    var ctx = ssl.call["SSL_CTX_new", Int](method)
    var ok = ctx != 0
    if ok:
        ssl.call["SSL_CTX_free", NoneType](ctx)
    return _report("system_ssl_ctx_new", ok, "SSL_CTX_new(TLS_method())")
