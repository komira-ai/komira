# Case (a)/(b): komira_libc (a real komira .mojoc) and knative call into
# libkomira_native.so.1; aws-lc, snappy and a komira shim, with known answers.
from knative import check_aead, check_s2n, check_sha256, check_snappy
from komira_libc.posix_io import RawWriteFd


def check_libc() raises -> Bool:
    var fd = RawWriteFd.open_truncate("knative_libc_probe.bin")
    var data = List[UInt8](length=1000, fill=7)
    fd.write_bytes(Span(data))
    var end = fd.seek_to_end()
    fd.fsync()
    fd.close()
    var ok = end == 1000
    print("CHECK komira_libc_rawwritefd", "PASS" if ok else "FAIL", "komira_openat_creat, komira_write_bytes, komira_lseek_end, komira_fsync; size", end, flush=True)
    return ok


def main() raises:
    var ok = check_sha256()
    ok = check_aead() and ok
    ok = check_snappy() and ok
    ok = check_s2n() and ok
    ok = check_libc() and ok
    print("RESULT", "PASS" if ok else "FAIL", flush=True)
