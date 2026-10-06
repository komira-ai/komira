# Case (c): the system libcrypto.so.3 and libssl.so.3 are dlopened RTLD_GLOBAL
# and called first; then the global scope is checked for leaked OpenSSL or
# snappy names, our functions are called, and the system libssl makes an
# SSL_CTX (its libcrypto calls resolve through the global scope).
from knative import check_aead, check_s2n, check_interposition, check_sha256, check_snappy, load_system_openssl, system_ssl_ctx


def main() raises:
    var have = load_system_openssl()
    var ok = True
    if have:
        ok = check_interposition("libkomira_native.so.1", True) and ok
    ok = check_sha256() and ok
    ok = check_aead() and ok
    ok = check_snappy() and ok
    ok = check_s2n() and ok
    if have:
        ok = system_ssl_ctx() and ok
    print("RESULT", "PASS" if ok else "FAIL", "(system openssl present:", have, ")", flush=True)
