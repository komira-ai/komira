# Control for case (c): the same check against libkomira_native_leaky.so.1,
# which links aws-lc and snappy unprefixed with no version script and no
# -Bsymbolic. The check must report interposition here, or it proves nothing.
from knative import check_interposition, load_system_openssl, system_ssl_ctx
from komira_libc.posix_io import RawWriteFd


def main() raises:
    var fd = RawWriteFd.open_truncate("knative_libc_probe.bin")
    var data = List[UInt8](length=10, fill=7)
    fd.write_bytes(Span(data))
    fd.close()
    var have = load_system_openssl()
    var ok = True
    if have:
        ok = check_interposition("libkomira_native_leaky.so.1", False) and ok
        print("INFO calling the system libssl with the leaky library first in the global scope", flush=True)
        _ = system_ssl_ctx()
    print("RESULT", "PASS" if ok else "FAIL", "(control; system openssl present:", have, ")", flush=True)
