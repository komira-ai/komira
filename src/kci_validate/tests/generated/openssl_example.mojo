# Written by kci: the native install check `openssl` (row 7 of docs/design/native_packaging.md).
# The owner is opened first, into the global scope, then the system OpenSSL: an owner exporting
# an unprefixed OpenSSL name would interpose on it.
from std.ffi import OwnedDLHandle, RTLD


def main() raises:
    var owner = OwnedDLHandle(String("/env/lib/libkomira_example_native.so.1"), RTLD.NOW | RTLD.GLOBAL)
    var ssl = OwnedDLHandle(String("/env/lib/libssl.so.3"), RTLD.NOW | RTLD.GLOBAL)
    var method = ssl.call["TLS_method", Int]()
    if method == 0:
        raise Error("TLS_method returned NULL")
    var ctx = ssl.call["SSL_CTX_new", Int](method)
    if ctx == 0:
        raise Error("SSL_CTX_new returned NULL")
    print("OPENSSL ok")
    _ = owner^
