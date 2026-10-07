# The run test's interposition case (native_run.sh, case IR1): the system
# libcrypto.so.3 and libssl.so.3 are loaded RTLD_GLOBAL and called first, so
# their OpenSSL names are in the process's global scope. Then:
#   - libkomira_native.so.1 must export none of those names (nor snappy's or
#     s2n-tls's own), and the global scope must resolve each to the system
#     library, not to ours;
#   - our calls must still give the known answers (they bind inside our
#     library: -Bsymbolic and the prefix);
#   - the system libssl must still make an SSL_CTX (its libcrypto calls go
#     through the global scope; the unprefixed control of the probe that
#     designed this crashed here).
# A worker without libcrypto.so.3 runs only our calls, and says so.
from std.ffi import OwnedDLHandle
from native_checks import check_aead, check_s2n, check_sha256, check_snappy, from_hex, report, same

comptime RTLD_NOW: Int32 = 2
comptime RTLD_NOLOAD: Int32 = 4
comptime RTLD_GLOBAL: Int32 = 0x100


# dlopen and dlsym through a handle on libc, not external_call: the standard
# library declares them itself, and a second declaration fails to lower. A
# handle and an address are Ints; RTLD_DEFAULT (the global scope) is 0.
def _dlopen(name: String, flags: Int32) raises -> Int:
    var libc = OwnedDLHandle("libc.so.6")
    var n = name
    var h = libc.call["dlopen", Int](n.as_c_string_slice().unsafe_ptr(), flags)
    _ = n.byte_length()  # keep-alive past the call
    return h


def _dlsym(handle: Int, name: String) raises -> Int:
    var libc = OwnedDLHandle("libc.so.6")
    var n = name
    var p = libc.call["dlsym", Int](handle, n.as_c_string_slice().unsafe_ptr())
    _ = n.byte_length()  # keep-alive past the call
    return p


def load_system_openssl() raises -> Bool:
    var hc = _dlopen("libcrypto.so.3", RTLD_NOW | RTLD_GLOBAL)
    if hc == 0:
        print("INFO the worker has no libcrypto.so.3: only our calls run", flush=True)
        return False
    var hs = _dlopen("libssl.so.3", RTLD_NOW | RTLD_GLOBAL)
    print("INFO system libcrypto.so.3 handle", hex(hc), "libssl.so.3 handle", hex(hs), flush=True)
    var crypto = OwnedDLHandle("libcrypto.so.3")
    var msg = String("abc")
    var out = List[UInt8](length=32, fill=0)
    _ = crypto.call["SHA256", Int](msg.as_c_string_slice().unsafe_ptr(), UInt(3), out.unsafe_ptr())
    _ = msg.byte_length()  # keep-alive past the call
    var want = from_hex("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    _ = report("system_sha256_abc", same(Span(out), Span(want)), "the system libcrypto's SHA256, called first")
    return True


def check_no_interposition() raises -> Bool:
    """For each name: ours = dlsym(our library), global = dlsym(RTLD_DEFAULT), system = dlsym(libcrypto).

    Safe: ours is 0 (we export none of them) and global == system.
    """
    var hm = _dlopen("libkomira_native.so.1", RTLD_NOW | RTLD_NOLOAD)
    if hm == 0:
        return report("no_interposition", False, "libkomira_native.so.1 is not loaded in this process")
    var hc = _dlopen("libcrypto.so.3", RTLD_NOW | RTLD_NOLOAD)
    var names = List[String]()
    names.append("SHA256")
    names.append("EVP_sha256")
    names.append("EVP_AEAD_CTX_seal")
    names.append("RAND_bytes")
    names.append("snappy_compress")
    names.append("s2n_init")
    var safe = True
    for i in range(len(names)):
        var ours = _dlsym(hm, names[i])
        var glob = _dlsym(0, names[i])
        var system = _dlsym(hc, names[i]) if hc != 0 else 0
        var ok = ours == 0 and glob == system
        safe = safe and ok
        print("INFO", names[i], "ours", hex(ours), "global", hex(glob), "system", hex(system), "ok" if ok else "INTERPOSED", flush=True)
    var ours_sha = _dlsym(hm, "komira_awslc_SHA256")
    safe = safe and ours_sha != 0
    return report("no_interposition", safe, "our library exports komira_awslc_SHA256 at " + hex(ours_sha) + " and none of the unprefixed names")


def system_ssl_ctx() raises -> Bool:
    var ssl = OwnedDLHandle("libssl.so.3")
    var method = ssl.call["TLS_method", Int]()
    var ctx = ssl.call["SSL_CTX_new", Int](method)
    if ctx != 0:
        ssl.call["SSL_CTX_free", NoneType](ctx)
    return report("system_ssl_ctx_new", ctx != 0, "the system libssl's SSL_CTX_new(TLS_method()), after our library loaded")


def main() raises:
    var have = load_system_openssl()
    var ok = check_no_interposition()
    ok = check_sha256() and ok
    ok = check_aead() and ok
    ok = check_snappy() and ok
    ok = check_s2n() and ok
    if have:
        ok = system_ssl_ctx() and ok
    print("RESULT", "PASS" if ok else "FAIL", "(system openssl present:", have, ")", flush=True)
