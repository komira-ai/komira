# The system OpenSSL beside libkomira_native.so.1, for the run test's
# interposition cases (native_run.sh, IR1 and IR2): load it RTLD_GLOBAL, call
# it, and look up names in our library, in it and in the global scope.
#
# dlopen and dlsym are called through a handle on libc, not external_call:
# the standard library declares them itself, and a second declaration fails
# to lower. A handle and an address are Ints; RTLD_DEFAULT (the global scope)
# is 0.
from std.ffi import OwnedDLHandle
from native_util import from_hex, report, same

comptime RTLD_NOW: Int32 = 2
comptime RTLD_NOLOAD: Int32 = 4
comptime RTLD_GLOBAL: Int32 = 0x100


def dlopen(name: String, flags: Int32) raises -> Int:
    var libc = OwnedDLHandle("libc.so.6")
    var n = name
    var h = libc.call["dlopen", Int](n.as_c_string_slice().unsafe_ptr(), flags)
    _ = n.byte_length()  # keep-alive past the call
    return h


def dlsym(handle: Int, name: String) raises -> Int:
    var libc = OwnedDLHandle("libc.so.6")
    var n = name
    var p = libc.call["dlsym", Int](handle, n.as_c_string_slice().unsafe_ptr())
    _ = n.byte_length()  # keep-alive past the call
    return p


comptime LIBCRYPTO = "libcrypto.so.3"
comptime LIBSSL = "libssl.so.3"


def load_system_openssl() raises -> Bool:
    """Loads the system libcrypto.so.3 and libssl.so.3 RTLD_GLOBAL and calls its SHA256.

    False (and a FAIL line) when either cannot be loaded: a case that cannot
    load them proves nothing about them, so it fails rather than passes.
    """
    var hc = dlopen(LIBCRYPTO, RTLD_NOW | RTLD_GLOBAL)
    var hs = dlopen(LIBSSL, RTLD_NOW | RTLD_GLOBAL)
    if hc == 0 or hs == 0:
        return report("system_openssl_loaded", False, "dlopen(" + LIBCRYPTO + ") " + hex(hc) + ", dlopen(" + LIBSSL + ") " + hex(hs) + ": the worker has no system OpenSSL")
    _ = report("system_openssl_loaded", True, LIBCRYPTO + " handle " + hex(hc) + ", " + LIBSSL + " handle " + hex(hs))
    var crypto = OwnedDLHandle(LIBCRYPTO)
    var msg = String("abc")
    var out = List[UInt8](length=32, fill=0)
    _ = crypto.call["SHA256", Int](msg.as_c_string_slice().unsafe_ptr(), UInt(3), out.unsafe_ptr())
    _ = msg.byte_length()  # keep-alive past the call
    var want = from_hex("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    return report("system_sha256_abc", same(Span(out), Span(want)), "the system libcrypto's SHA256")


def check_no_interposition() raises -> Bool:
    """For each name: ours = dlsym(our library), global = dlsym(RTLD_DEFAULT), system = dlsym(libcrypto).

    Safe: ours is 0 (we export none of them) and global == system.
    """
    var hm = dlopen("libkomira_native.so.1", RTLD_NOW | RTLD_NOLOAD)
    if hm == 0:
        return report("no_interposition", False, "libkomira_native.so.1 is not loaded in this process")
    var hc = dlopen(LIBCRYPTO, RTLD_NOW | RTLD_NOLOAD)
    var names = List[String]()
    names.append("SHA256")
    names.append("EVP_sha256")
    names.append("EVP_AEAD_CTX_seal")
    names.append("RAND_bytes")
    names.append("snappy_compress")
    names.append("s2n_init")
    var safe = True
    for i in range(len(names)):
        var ours = dlsym(hm, names[i])
        var glob = dlsym(0, names[i])
        var system = dlsym(hc, names[i]) if hc != 0 else 0
        var ok = ours == 0 and glob == system
        safe = safe and ok
        print("INFO", names[i], "ours", hex(ours), "global", hex(glob), "system", hex(system), "ok" if ok else "INTERPOSED", flush=True)
    var ours_sha = dlsym(hm, "komira_awslc_SHA256")
    safe = safe and ours_sha != 0
    return report("no_interposition", safe, "our library exports komira_awslc_SHA256 at " + hex(ours_sha) + " and none of the unprefixed names")


def system_ssl_ctx() raises -> Bool:
    """The system libssl's SSL_CTX_new: its libcrypto calls resolve through the global scope."""
    var ssl = OwnedDLHandle(LIBSSL)
    var method = ssl.call["TLS_method", Int]()
    var ctx = ssl.call["SSL_CTX_new", Int](method)
    if ctx != 0:
        ssl.call["SSL_CTX_free", NoneType](ctx)
    return report("system_ssl_ctx_new", ctx != 0, "SSL_CTX_new(TLS_method()) with our library in the process")
