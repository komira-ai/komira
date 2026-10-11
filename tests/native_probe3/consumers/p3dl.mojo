# The loader, as probe 3's programs ask it: dlopen and dlsym called through a
# handle on libc (the standard library declares them itself; a second
# external_call declaration fails to lower), and which loaded file holds an
# address, read from /proc/self/maps (no pointer is formed from an integer).
# A handle and an address are Ints; RTLD_DEFAULT (the global scope) is 0.
from std.ffi import OwnedDLHandle
from std.pathlib import Path
from p3util import from_hex, report, same

comptime RTLD_NOW: Int32 = 2
comptime RTLD_NOLOAD: Int32 = 4
comptime RTLD_GLOBAL: Int32 = 0x100

comptime LIBCRYPTO = "libcrypto.so.3"
comptime LIBSSL = "libssl.so.3"

def _hooks() -> List[String]:
    """aws-lc's four allocator hooks, weak undefined in komira_crypto's library."""
    var h = List[String]()
    h.append("komira_awslc_OPENSSL_memory_alloc")
    h.append("komira_awslc_OPENSSL_memory_free")
    h.append("komira_awslc_OPENSSL_memory_get_size")
    h.append("komira_awslc_OPENSSL_memory_realloc")
    return h^


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


def _hexval(s: String) -> Int:
    var v = 0
    var b = s.as_bytes()
    for i in range(len(b)):
        var c = Int(b[i])
        if c >= 0x30 and c <= 0x39:
            v = v * 16 + (c - 0x30)
        elif c >= 0x61 and c <= 0x66:
            v = v * 16 + (c - 0x61 + 10)
        else:
            break
    return v


def file_of(addr: Int) raises -> String:
    """The path of the mapping holding `addr` in /proc/self/maps, or "(none)"."""
    if addr == 0:
        return "(null)"
    var maps = Path("/proc/self/maps").read_text()
    var lines = maps.split("\n")
    for i in range(len(lines)):
        var fields = String(lines[i]).split(" ")
        if len(fields) < 1:
            continue
        var range_ = String(fields[0]).split("-")
        if len(range_) != 2:
            continue
        var lo = _hexval(String(range_[0]))
        var hi = _hexval(String(range_[1]))
        if addr >= lo and addr < hi:
            var path = String(fields[len(fields) - 1])
            if not path.startswith("/"):
                return "(anonymous)"
            return path
    return "(none)"


def hooks_unbound(where: String) raises -> Bool:
    """No object of the process defines aws-lc's allocator hooks: the global
    scope and komira_crypto's library (with its dependencies) resolve none."""
    var hc = dlopen("libkomira_crypto_native.so.1", RTLD_NOW | RTLD_NOLOAD)
    var ok = hc != 0
    var detail = String("crypto handle ") + hex(hc)
    var hooks = _hooks()
    for i in range(len(hooks)):
        var g = dlsym(0, hooks[i])
        var c = dlsym(hc, hooks[i]) if hc != 0 else 0
        ok = ok and g == 0 and c == 0
        detail += String(", ") + hooks[i] + " global " + hex(g) + " crypto " + hex(c)
    return report("hooks_unbound_" + where, ok, detail)


def load_system_openssl() raises -> Bool:
    """The system libcrypto.so.3 and libssl.so.3, RTLD_GLOBAL, and its SHA256.

    False when either cannot be loaded: a case that cannot load them proves
    nothing about them, so it fails rather than passes.
    """
    var hc = dlopen(LIBCRYPTO, RTLD_NOW | RTLD_GLOBAL)
    var hs = dlopen(LIBSSL, RTLD_NOW | RTLD_GLOBAL)
    if hc == 0 or hs == 0:
        return report("system_openssl_loaded", False, "dlopen(" + LIBCRYPTO + ") " + hex(hc) + ", dlopen(" + LIBSSL + ") " + hex(hs) + ": the worker has no system OpenSSL")
    _ = report("system_openssl_loaded", True, LIBCRYPTO + " from " + file_of(dlsym(hc, "SHA256")))
    var crypto = OwnedDLHandle(LIBCRYPTO)
    var msg = String("abc")
    var out = List[UInt8](length=32, fill=0)
    _ = crypto.call["SHA256", Int](msg.as_c_string_slice().unsafe_ptr(), UInt(3), out.unsafe_ptr())
    _ = msg.byte_length()  # keep-alive past the call
    var want = from_hex("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    return report("system_sha256_abc", same(Span(out), Span(want)), "the system libcrypto's SHA256")


def check_no_interposition() raises -> Bool:
    """For each unprefixed name: no komira library defines it, and the global
    scope's definition is the system library's."""
    var hc = dlopen(LIBCRYPTO, RTLD_NOW | RTLD_NOLOAD)
    var ours = List[String]()
    ours.append("libkomira_crypto_native.so.1")
    ours.append("libkomira_http_core_native.so.1")
    ours.append("libkomira_compression_native.so.1")
    var names = List[String]()
    names.append("SHA256")
    names.append("EVP_sha256")
    names.append("EVP_AEAD_CTX_seal")
    names.append("RAND_bytes")
    names.append("OPENSSL_malloc")
    names.append("snappy_compress")
    names.append("s2n_init")
    var safe = hc != 0
    for i in range(len(names)):
        var glob = dlsym(0, names[i])
        var system = dlsym(hc, names[i]) if hc != 0 else 0
        var ok = glob == system
        for j in range(len(ours)):
            var h = dlopen(ours[j], RTLD_NOW | RTLD_NOLOAD)
            if h == 0:
                # Not in the process (a built program drops an owner it does
                # not reference): it can interpose on nothing. crypto and
                # http_core are required below.
                if j < 2:
                    ok = False
                    print("INFO", ours[j], "is not loaded", flush=True)
                continue
            var a = dlsym(h, names[i])
            # dlsym on a handle also searches the library's dependencies: an
            # address in a komira file is ours; one in the system's is not.
            if a != 0 and file_of(a).find("komira") >= 0:
                ok = False
                print("INFO", names[i], "defined by", file_of(a), flush=True)
        safe = safe and ok
        print("INFO", names[i], "global", file_of(glob), "ok" if ok else "INTERPOSED", flush=True)
    return report("no_interposition", safe, "no komira library defines an unprefixed OpenSSL, snappy or s2n name; the global scope's is the system's")


def system_ssl_ctx() raises -> Bool:
    """The system libssl's SSL_CTX_new: its libcrypto calls resolve to the system's."""
    var ssl = OwnedDLHandle(LIBSSL)
    var method = ssl.call["TLS_method", Int]()
    var ctx = ssl.call["SSL_CTX_new", Int](method)
    if ctx != 0:
        ssl.call["SSL_CTX_free", NoneType](ctx)
    return report("system_ssl_ctx_new", ctx != 0, "SSL_CTX_new(TLS_method()) with the komira libraries in the process")
