# The run test's case IR2 (native_run.sh): the order a host process (a Python
# interpreter, say) would give. The system libcrypto.so.3 and libssl.so.3 are
# loaded RTLD_GLOBAL and called first; then libkomira_native.so.1 is dlopened
# by path (RTLD_GLOBAL, the harder case: its exports join the global scope)
# and called through the handle. The program links nothing of ours: its
# argument is the library's path.
#   - our calls must give the known answers: -Bsymbolic and the prefix keep
#     every reference inside our library from binding to the system's;
#   - our library must export none of OpenSSL's, snappy's or s2n-tls's names;
#   - the system libssl must still make an SSL_CTX.
# A worker without the system OpenSSL FAILS the case.
from std.ffi import OwnedDLHandle
from std.sys import argv
from native_openssl import RTLD_GLOBAL, RTLD_NOW, check_no_interposition, dlopen, load_system_openssl, system_ssl_ctx
from native_util import bytes_of, from_hex, hex_of, report, same


def _library_path() raises -> String:
    var args = argv()
    for i in range(len(args)):
        var a = String(args[i])
        if a.endswith("/libkomira_native.so.1"):
            return a
    raise Error("no argument is a path to libkomira_native.so.1")


def main() raises:
    var ok = load_system_openssl()
    var path = _library_path()
    var h = dlopen(path, RTLD_NOW | RTLD_GLOBAL)
    if h == 0:
        _ = report("dlopen_ours", False, "dlopen(" + path + ") failed")
        print("RESULT FAIL", flush=True)
        return
    _ = report("dlopen_ours", True, "libkomira_native.so.1 dlopened after the system OpenSSL")
    var ours = OwnedDLHandle(path)

    var msg = bytes_of("abc")
    var out = List[UInt8](length=32, fill=0)
    _ = ours.call["komira_awslc_SHA256", Int](msg.unsafe_ptr(), UInt(len(msg)), out.unsafe_ptr())
    _ = len(msg)  # keep-alive past the call
    var want = from_hex("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    ok = report("awslc_sha256_abc", same(Span(out), Span(want)), "komira_awslc_SHA256 through dlopen; got " + hex_of(Span(out))) and ok

    var c = List[UInt8](length=64, fill=0)
    var n = List[UInt](length=1, fill=UInt(64))
    var rc = ours.call["komira_snappy_compress", Int32](msg.unsafe_ptr(), UInt(len(msg)), c.unsafe_ptr(), n.unsafe_ptr())
    _ = len(msg)  # keep-alive past the call
    var kat = rc == 0 and Int(n[0]) == 5 and same(Span(c)[0:5], Span(from_hex("0308616263")))
    ok = report("snappy_compress_abc", kat, "komira_snappy_compress through dlopen; rc " + String(rc)) and ok

    var rc_init = ours.call["komira_s2n_init", Int32]()
    var cfg = ours.call["komira_s2n_config_new", Int]()
    var rc_free = ours.call["komira_s2n_config_free", Int32](cfg)
    ok = report("s2n_init_config", rc_init == 0 and cfg != 0 and rc_free == 0, "komira_s2n_init " + String(rc_init) + ", config_new " + hex(cfg)) and ok

    ok = check_no_interposition() and ok
    ok = system_ssl_ctx() and ok
    print("RESULT", "PASS" if ok else "FAIL", flush=True)
