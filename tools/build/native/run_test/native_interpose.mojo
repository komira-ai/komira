# The run test's case IR1 (native_run.sh): the program links
# libkomira_native.so.1 (`-lkomira_native`), so the loader loads ours at
# start; then the system libcrypto.so.3 and libssl.so.3 are dlopened
# RTLD_GLOBAL and called, putting their OpenSSL names in the global scope.
#   - our library must export none of those names (nor snappy's or
#     s2n-tls's own), and the global scope must resolve each to the system's;
#   - our calls must still give the known answers;
#   - the system libssl must still make an SSL_CTX (its libcrypto calls go
#     through the global scope; an unprefixed library exporting OpenSSL's
#     names, loaded first, crashes here).
# A worker without the system OpenSSL FAILS the case: it would prove nothing.
from native_checks import check_aead, check_s2n, check_sha256, check_snappy
from native_openssl import check_no_interposition, load_system_openssl, system_ssl_ctx


def main() raises:
    var ok = load_system_openssl()
    ok = check_no_interposition() and ok
    ok = check_sha256() and ok
    ok = check_aead() and ok
    ok = check_snappy() and ok
    ok = check_s2n() and ok
    ok = system_ssl_ctx() and ok
    print("RESULT", "PASS" if ok else "FAIL", flush=True)
