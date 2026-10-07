# The run test's program (native_run.sh, cases R1 and B1): aws-lc, snappy,
# s2n-tls and a komira C shim (komira_libc's, through the real komira_libc
# package), each called through libkomira_native.so.1, with known answers.
from komira_libc.posix_io import RawWriteFd
from native_checks import check_aead, check_s2n, check_sha256, check_snappy, report


def check_libc() raises -> Bool:
    """The komira_libc RawWriteFd: komira_openat_creat, komira_write_bytes, komira_lseek_end, komira_fsync."""
    var fd = RawWriteFd.open_truncate("native_run_libc.bin")
    var data = List[UInt8](length=1000, fill=7)
    fd.write_bytes(Span(data))
    var end = fd.seek_to_end()
    fd.fsync()
    fd.close()
    return report("komira_libc_rawwritefd", end == 1000, "a 1000-byte write, then seek to the end: " + String(end))


def main() raises:
    var ok = check_sha256()
    ok = check_aead() and ok
    ok = check_snappy() and ok
    ok = check_s2n() and ok
    ok = check_libc() and ok
    print("RESULT", "PASS" if ok else "FAIL", flush=True)
