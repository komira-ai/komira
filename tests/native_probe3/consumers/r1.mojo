# Probe 3's program for R1, R2, B1, R1-MISS, IR1, IR2 and ONE: komira_crypto's
# and komira_http_core's Mojo API over the owners' shared libraries.
#   SHA-256 and AES-256-GCM known answers (komira_crypto -> aws-lc);
#   tls_init (s2n init, and komira_async's komira_ignore_sigpipe: the
#   Mojo-to-C edge no DT_NEEDED carries);
#   a full TLS 1.3 handshake, client against server over a socketpair, with
#   the client verifying the server's chain against the test root.
# Arguments: `ir` prints whether the system OpenSSL is already loaded (ORDER:
# preloaded = before ours), loads it RTLD_GLOBAL (a no-op when preloaded) and
# checks no interposition; `one`
# checks that aws-lc is one copy, reached from crypto and from http_core.
# The certificates are read from the working directory.
from std.ffi import external_call
from std.pathlib import Path
from std.sys import argv

from komira_crypto import AesGcm256, sha256
from komira_http_core.tls import (
    TLS_OUTCOME_DONE,
    TLS_OUTCOME_ERROR,
    TLS_VERSION_TLS13,
    TlsConfig,
    TlsConnection,
    tls_init,
)
from p3dl import (
    LIBCRYPTO,
    RTLD_NOLOAD,
    RTLD_NOW,
    check_no_interposition,
    dlopen,
    dlsym,
    file_of,
    hooks_unbound,
    load_system_openssl,
    system_ssl_ctx,
)
from p3util import from_hex, hex_of, report, same


def check_sha256() -> Bool:
    var d = sha256(String("abc").as_bytes())
    var got = List[UInt8]()
    for i in range(32):
        got.append(d[i])
    var want = from_hex("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    return report("crypto_sha256_abc", same(Span(got), Span(want)), "komira_crypto.sha256; got " + hex_of(Span(got)))


def check_aead() raises -> Bool:
    """AES-256-GCM, the GCM spec's test case 14: zero key, zero nonce, 16 zero bytes."""
    var key = Array[UInt8, 32](fill=0)
    var nonce = Array[UInt8, 12](fill=0)
    var aead = AesGcm256(key)
    var buf = List[UInt8](length=32, fill=0)
    var aad = List[UInt8]()
    aead.seal_in_place(nonce, Span(aad), Span(buf))
    var want = from_hex("cea7403d4d606b6e074ec5d3baf39d18d0d1c8a799996bf0265b98b5d48ab919")
    return report("crypto_aes256gcm_seal", same(Span(buf), Span(want)), "komira_crypto.AesGcm256; got " + hex_of(Span(buf)))


def _socketpair() raises -> Tuple[Int32, Int32]:
    var sv = List[Int32](length=2, fill=Int32(-1))
    var rc = external_call["socketpair", Int32](Int32(1), Int32(1), Int32(0), sv.unsafe_ptr())
    _ = len(sv)  # keep-alive past the call
    if rc != Int32(0):
        raise Error("socketpair() returned " + String(Int(rc)))
    return (sv[0], sv[1])


def _close(fd: Int32):
    _ = external_call["close", Int32](fd)


def check_tls13() raises -> Bool:
    var server_config = TlsConfig()
    server_config.load_cert(Path("leaf_cert.pem").read_text(), Path("leaf_key.pem").read_text())
    server_config.set_cipher_preferences(String("default_tls13"))
    var client_config = TlsConfig()
    client_config.wipe_trust()
    client_config.add_trust_pem(Path("root_ca.pem").read_text())
    client_config.set_cipher_preferences(String("default_tls13"))
    var fds = _socketpair()
    _ = external_call["komira_fcntl_set_nonblock", Int32](fds[0])
    _ = external_call["komira_fcntl_set_nonblock", Int32](fds[1])
    var ok: Bool
    var detail: String
    try:
        var server = TlsConnection(server_config)
        server.bind_fd(fds[0])
        var client = TlsConnection.new_client(client_config)
        client.bind_fd(fds[1])
        client.set_server_name(String("localhost"))
        var s_done = False
        var c_done = False
        var err = False
        for _ in range(64):
            if not s_done:
                var o = server.handshake()
                err = err or o == TLS_OUTCOME_ERROR
                s_done = o == TLS_OUTCOME_DONE
            if not c_done:
                var o = client.handshake()
                err = err or o == TLS_OUTCOME_ERROR
                c_done = o == TLS_OUTCOME_DONE
            if err or (s_done and c_done):
                break
        var version = client.negotiated_tls_version()
        ok = s_done and c_done and not err and version == TLS_VERSION_TLS13
        detail = "server done " + String(s_done) + ", client done " + String(c_done) + ", error " + String(err) + ", version " + String(version)
        _ = server^
        _ = client^
    finally:
        _close(fds[0])
        _close(fds[1])
    _ = server_config^
    _ = client_config^
    return report("http_core_tls13_handshake", ok, detail)


def check_one() raises -> Bool:
    """Aws-lc is one copy: komira_awslc_SHA256 looked up from crypto's library,
    from http_core's (which searches its DT_NEEDED) and from the global scope is
    one address, in libkomira_crypto_native.so.1."""
    var hc = dlopen("libkomira_crypto_native.so.1", RTLD_NOW | RTLD_NOLOAD)
    var hh = dlopen("libkomira_http_core_native.so.1", RTLD_NOW | RTLD_NOLOAD)
    var a_c = dlsym(hc, "komira_awslc_SHA256") if hc != 0 else 0
    var a_h = dlsym(hh, "komira_awslc_SHA256") if hh != 0 else 0
    var a_g = dlsym(0, "komira_awslc_SHA256")
    var f = file_of(a_c)
    var ok = a_c != 0 and a_c == a_h and a_c == a_g and f.endswith("/libkomira_crypto_native.so.1")
    return report(
        "one_awslc",
        ok,
        "from crypto " + hex(a_c) + " " + f + "; from http_core " + hex(a_h) + " " + file_of(a_h) + "; global " + hex(a_g) + " " + file_of(a_g),
    )


def main() raises:
    var ir = False
    var one = False
    var args = argv()
    for i in range(len(args)):
        if String(args[i]) == "ir":
            ir = True
        if String(args[i]) == "one":
            one = True
    var ok = True
    if ir:
        # The order: whether the system libcrypto is already in the process
        # before main (preloaded) or arrives only through the dlopen below.
        var before = dlopen(LIBCRYPTO, RTLD_NOW | RTLD_NOLOAD) != 0
        print("ORDER system_openssl", "before" if before else "after", "the komira libraries", flush=True)
        ok = load_system_openssl() and ok
    ok = check_sha256() and ok
    ok = check_aead() and ok
    tls_init()
    _ = report("http_core_tls_init", True, "tls_init returned (s2n_init, komira_ignore_sigpipe)")
    ok = check_tls13() and ok
    if ir:
        ok = check_no_interposition() and ok
        ok = system_ssl_ctx() and ok
    if ir or one:
        ok = hooks_unbound("ir" if ir else "one") and ok
    if one:
        ok = check_one() and ok
    print("RESULT", "PASS" if ok else "FAIL", flush=True)
